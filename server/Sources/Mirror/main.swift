// Daylight Mirror — ScreenCaptureKit + raw TCP for minimum-latency screen mirroring.
//
// Pipeline (zero GPU):
//   ScreenCaptureKit BGRA → vImage SIMD greyscale (~0.2ms)
//   → XOR delta vs previous frame (~0.1ms)
//   → LZ4 compress (~0.3ms)
//   → Raw TCP with length-prefix framing
//
// The Android native app (NDK) receives, LZ4 decompresses, applies delta,
// and writes directly to ANativeWindow — no Java decode, no browser.
//
// Protocol: [0xDA 0x7E] [flags:1B] [length:4B LE] [LZ4 payload]
//   flags bit 0: 1=keyframe (full frame), 0=delta (XOR with previous)
//
// Also serves a WebSocket+HTML fallback for Chrome-based viewing.

import Foundation
import ScreenCaptureKit
import CoreImage
import CoreMedia
import Network
import Accelerate
import CLZ4
import CVirtualDisplay
import AppKit  // For NSEvent global key monitoring

// MARK: - Configuration

let PORT: UInt16 = 8888          // Raw TCP for native app
let WS_PORT: UInt16 = 8890      // WebSocket for Chrome fallback
let HTTP_PORT: UInt16 = 8891    // HTML page for Chrome fallback
let TARGET_FPS: Int = 30
let JPEG_QUALITY: CGFloat = 0.8 // For WebSocket fallback only
let KEYFRAME_INTERVAL: Int = 30 // Send a full keyframe every N frames

// Virtual display resolution (matches Daylight DC-1 aspect ratio)
let DISPLAY_W: UInt = 1280
let DISPLAY_H: UInt = 960

// Protocol constants
let MAGIC_FRAME: [UInt8] = [0xDA, 0x7E]   // Frame packet
let MAGIC_CMD: [UInt8] = [0xDA, 0x7F]     // Command packet
let FLAG_KEYFRAME: UInt8 = 0x01
let CMD_BRIGHTNESS: UInt8 = 0x01          // [0xDA 0x7F] [0x01] [value 0-255]
let CMD_WARMTH: UInt8 = 0x02              // [0xDA 0x7F] [0x02] [value 0-255] (maps to 0-1023 amber_rate)
let CMD_BACKLIGHT_TOGGLE: UInt8 = 0x03    // [0xDA 0x7F] [0x03] [0x00]

// Step per keypress
let BRIGHTNESS_STEP: Int = 15      // 0-255 range, ~17 steps full range
let WARMTH_STEP: Int = 20          // 0-240 amber_rate, ~12 steps full range

// MARK: - Virtual Display (replaces BetterDisplay)

/// Creates a 1280x960 non-HiDPI virtual display and mirrors the Mac's built-in
/// display to it. The virtual display lives as long as this object is retained.
/// When the server exits, the virtual display disappears automatically.
class VirtualDisplayManager {
    let virtualDisplay: CGVirtualDisplay
    let displayID: CGDirectDisplayID

    init() {
        // Create virtual display descriptor
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "Daylight DC-1"
        descriptor.maxPixelsWide = UInt32(DISPLAY_W)
        descriptor.maxPixelsHigh = UInt32(DISPLAY_H)
        // Physical size at ~100 PPI (just needs to be plausible)
        descriptor.sizeInMillimeters = CGSize(
            width: 25.4 * Double(DISPLAY_W) / 100.0,
            height: 25.4 * Double(DISPLAY_H) / 100.0
        )
        descriptor.productID = 0xDA7E  // "DAYE" — Daylight
        descriptor.vendorID = 0xDA7E
        descriptor.serialNum = 0x0001

        virtualDisplay = CGVirtualDisplay(descriptor: descriptor)
        displayID = virtualDisplay.displayID
        print("Virtual display created: ID \(displayID)")

        // Configure as non-HiDPI with a single mode
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0  // Non-HiDPI: 1280x960 real pixels
        settings.modes = [
            CGVirtualDisplayMode(width: DISPLAY_W, height: DISPLAY_H, refreshRate: 60)
        ]

        guard virtualDisplay.apply(settings) else {
            print("WARNING: Failed to apply virtual display settings")
            return
        }
        print("Virtual display configured: \(DISPLAY_W)x\(DISPLAY_H) non-HiDPI @ 60Hz")
    }

    /// Mirror the Mac's built-in display to our virtual display.
    /// The built-in display will show 4:3 letterboxed content.
    func mirrorBuiltInDisplay() {
        // Find built-in display
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(32, &displayIDs, &displayCount)

        var builtInID: CGDirectDisplayID?
        for i in 0..<Int(displayCount) {
            if CGDisplayIsBuiltin(displayIDs[i]) != 0 {
                builtInID = displayIDs[i]
                break
            }
        }

        guard let masterID = builtInID else {
            print("WARNING: No built-in display found, skipping mirror setup")
            return
        }

        // Configure mirroring: built-in mirrors our virtual display
        var configRef: CGDisplayConfigRef?
        let beginErr = CGBeginDisplayConfiguration(&configRef)
        guard beginErr == .success, let config = configRef else {
            print("WARNING: Failed to begin display configuration: \(beginErr)")
            return
        }

        // Make the built-in display mirror the virtual display
        // (virtual display becomes the "master" / source of truth)
        let mirrorErr = CGConfigureDisplayMirrorOfDisplay(config, masterID, displayID)
        guard mirrorErr == .success else {
            print("WARNING: Failed to configure mirror: \(mirrorErr)")
            CGCancelDisplayConfiguration(config)
            return
        }

        // Apply for this session only — reverts when process exits
        let completeErr = CGCompleteDisplayConfiguration(config, .forSession)
        guard completeErr == .success else {
            print("WARNING: Failed to complete mirror configuration: \(completeErr)")
            return
        }

        print("Mirroring: built-in display \(masterID) → virtual display \(displayID)")
    }
}

// MARK: - Raw TCP Server (for native Android app)

class TCPServer {
    let listener: NWListener
    var connections: [NWConnection] = []
    let queue = DispatchQueue(label: "tcp-server")
    let lock = NSLock()
    // Cached last keyframe — sent immediately to new clients (eliminates black flash)
    var lastKeyframeData: Data?

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        let tcpOptions = params.defaultProtocolStack.transportProtocol as! NWProtocolTCP.Options
        tcpOptions.noDelay = true  // Disable Nagle's algorithm for minimum latency
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                print("TCP server on tcp://localhost:\(PORT)")
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            // Set TCP_NODELAY via connection options
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[TCP] Native client connected")
                case .failed, .cancelled:
                    self.lock.lock()
                    self.connections.removeAll { $0 === conn }
                    self.lock.unlock()
                    print("[TCP] Native client disconnected")
                default: break
                }
            }
            conn.start(queue: self.queue)
            self.lock.lock()
            self.connections.append(conn)
            // Send cached keyframe immediately so client doesn't show black
            let cachedKeyframe = self.lastKeyframeData
            self.lock.unlock()

            if let kf = cachedKeyframe {
                conn.send(content: kf, completion: .contentProcessed { _ in })
                print("[TCP] Sent cached keyframe to new client (\(kf.count) bytes)")
            }

            // Keep reading (client might send acks or commands)
            self.receiveLoop(conn)
        }

        listener.start(queue: queue)
    }

    func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, _, error in
            if error != nil { return }
            self?.receiveLoop(conn)
        }
    }

    /// Send a frame with the binary protocol header
    func broadcast(payload: Data, isKeyframe: Bool) {
        // Build header: [magic:2][flags:1][length:4LE]
        var header = Data(capacity: 7)
        header.append(contentsOf: MAGIC_FRAME)
        header.append(isKeyframe ? FLAG_KEYFRAME : 0)
        var len = UInt32(payload.count).littleEndian
        header.append(Data(bytes: &len, count: 4))

        var frame = header
        frame.append(payload)

        lock.lock()
        // Cache keyframes for instant delivery to new clients
        if isKeyframe {
            lastKeyframeData = frame
        }
        let conns = connections
        lock.unlock()

        for conn in conns {
            conn.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

    /// Send a command to all connected clients: [0xDA 0x7F] [cmd] [value]
    func sendCommand(_ cmd: UInt8, value: UInt8) {
        var packet = Data(capacity: 4)
        packet.append(contentsOf: MAGIC_CMD)
        packet.append(cmd)
        packet.append(value)

        lock.lock()
        let conns = connections
        lock.unlock()

        for conn in conns {
            conn.send(content: packet, completion: .contentProcessed { _ in })
        }
    }
}

// MARK: - Brightness Controller (Ctrl+F1/F2 → Daylight brightness)

/// Intercepts Ctrl+function key events for Daylight display control:
///   Ctrl+F1/F2:   Brightness down/up
///   Ctrl+F10:     Toggle backlight on/off
///   Ctrl+F11/F12: Warmth (amber) down/up
/// Uses CGEvent tap to catch both regular keyDown and NX_SYSDEFINED media key events.
/// Requires Accessibility permission (System Settings → Privacy → Accessibility).
class DisplayController {
    let tcpServer: TCPServer
    var currentBrightness: Int = 128
    var currentWarmth: Int = 128       // Maps to 0-1023 amber_rate on device
    var backlightOn: Bool = true
    var savedBrightness: Int = 128     // Saved brightness for toggle restore

    init(tcpServer: TCPServer) {
        self.tcpServer = tcpServer
    }

    func start() {
        // Query current values from device via adb (one-time)
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }

            // Brightness (0-255)
            if let val = self.queryAdb("screen_brightness") {
                self.currentBrightness = val
                self.savedBrightness = val
                print("[Display] Daylight brightness: \(val)/255")
            }

            // Amber rate: effective range 0-240
            if let val = self.queryAdb("screen_brightness_amber_rate") {
                self.currentWarmth = min(val, 255)
                print("[Display] Daylight warmth: \(self.currentWarmth)/255")
            }
        }

        // CGEvent tap for keyboard events
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << 14)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let controller = Unmanaged<DisplayController>.fromOpaque(refcon!).takeUnretainedValue()

                // Regular keyDown with Ctrl modifier
                if type == .keyDown && event.flags.contains(.maskControl) {
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    switch keyCode {
                    case 122: // F1 — brightness down
                        controller.adjustBrightness(by: -BRIGHTNESS_STEP)
                        return nil
                    case 120: // F2 — brightness up
                        controller.adjustBrightness(by: BRIGHTNESS_STEP)
                        return nil
                    case 109: // F10 — toggle backlight
                        controller.toggleBacklight()
                        return nil
                    case 103: // F11 — warmth down (cooler)
                        controller.adjustWarmth(by: -WARMTH_STEP)
                        return nil
                    case 111: // F12 — warmth up (warmer)
                        controller.adjustWarmth(by: WARMTH_STEP)
                        return nil
                    default: break
                    }
                }

                // NX_SYSDEFINED (media/brightness special keys)
                if type.rawValue == 14 {
                    let nsEvent = NSEvent(cgEvent: event)
                    if nsEvent?.subtype.rawValue == 8 {
                        let data1 = nsEvent!.data1
                        let keyCode = (data1 & 0xFFFF0000) >> 16
                        let keyDown = ((data1 & 0xFF00) >> 8) == 0xA
                        let ctrl = event.flags.contains(.maskControl)

                        if ctrl && keyDown {
                            switch keyCode {
                            case 3:  // NX_KEYTYPE_BRIGHTNESS_DOWN → brightness down
                                controller.adjustBrightness(by: -BRIGHTNESS_STEP)
                                return nil
                            case 2:  // NX_KEYTYPE_BRIGHTNESS_UP → brightness up
                                controller.adjustBrightness(by: BRIGHTNESS_STEP)
                                return nil
                            case 7:  // NX_KEYTYPE_MUTE → toggle backlight
                                controller.toggleBacklight()
                                return nil
                            case 1:  // NX_KEYTYPE_SOUND_DOWN → warmth down (cooler)
                                controller.adjustWarmth(by: -WARMTH_STEP)
                                return nil
                            case 0:  // NX_KEYTYPE_SOUND_UP → warmth up (warmer)
                                controller.adjustWarmth(by: WARMTH_STEP)
                                return nil
                            default: break
                            }
                        }
                    }
                }

                return Unmanaged.passRetained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[Display] WARNING: Could not create event tap.")
            print("[Display] Grant Accessibility permission: System Settings → Privacy & Security → Accessibility")
            print("[Display] Then restart the server.")
            return
        }

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("[Display] Ctrl+F1/F2: brightness | Ctrl+F10: backlight toggle | Ctrl+F11/F12: warmth")
    }

    private func queryAdb(_ setting: String) -> Int? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["adb", "shell", "settings", "get", "system", setting]
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let str = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
            return Int(str)
        }
        return nil
    }

    func adjustBrightness(by delta: Int) {
        currentBrightness = max(0, min(255, currentBrightness + delta))
        savedBrightness = currentBrightness
        backlightOn = currentBrightness > 0
        tcpServer.sendCommand(CMD_BRIGHTNESS, value: UInt8(currentBrightness))
        print("[Display] Brightness → \(currentBrightness)/255")
    }

    func adjustWarmth(by delta: Int) {
        // Effective range is 0-255 amber_rate
        currentWarmth = max(0, min(255, currentWarmth + delta))
        let amberRate = currentWarmth
        // Set amber_rate directly via adb — the Android app can't write this protected setting
        DispatchQueue.global().async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["adb", "shell", "settings", "put", "system", "screen_brightness_amber_rate", "\(amberRate)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
        print("[Display] Warmth → \(currentWarmth)/255 (amber_rate=\(amberRate))")
    }

    func toggleBacklight() {
        if backlightOn {
            savedBrightness = max(currentBrightness, 1)  // Don't save 0
            currentBrightness = 0
            backlightOn = false
            tcpServer.sendCommand(CMD_BRIGHTNESS, value: 0)
            print("[Display] Backlight OFF")
        } else {
            currentBrightness = savedBrightness
            backlightOn = true
            tcpServer.sendCommand(CMD_BRIGHTNESS, value: UInt8(currentBrightness))
            print("[Display] Backlight ON → \(currentBrightness)/255")
        }
    }
}

// MARK: - WebSocket Server (Chrome fallback)

class WebSocketServer {
    let listener: NWListener
    var connections: [NWConnection] = []
    let queue = DispatchQueue(label: "ws-server")
    let lock = NSLock()

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                print("WebSocket server on ws://localhost:\(WS_PORT)")
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: print("[WS] Chrome client connected")
                case .failed, .cancelled:
                    self.lock.lock()
                    self.connections.removeAll { $0 === conn }
                    self.lock.unlock()
                    print("[WS] Chrome client disconnected")
                default: break
                }
            }
            conn.start(queue: self.queue)
            self.lock.lock()
            self.connections.append(conn)
            self.lock.unlock()
            self.receiveLoop(conn)
        }

        listener.start(queue: queue)
    }

    func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] _, _, _, error in
            if error != nil { return }
            self?.receiveLoop(conn)
        }
    }

    func broadcast(_ data: Data) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        lock.lock()
        let conns = connections
        lock.unlock()
        for conn in conns {
            conn.send(content: data, contentContext: context, isComplete: true,
                      completion: .contentProcessed { _ in })
        }
    }

    var hasClients: Bool {
        lock.lock()
        let count = connections.count
        lock.unlock()
        return count > 0
    }
}

// MARK: - HTTP Server (serves HTML page for Chrome fallback)

class HTTPServer {
    let listener: NWListener
    let queue = DispatchQueue(label: "http-server")
    let htmlPage: Data

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

        let html = """
        <!DOCTYPE html><html>
        <head><meta name="viewport" content="width=device-width,initial-scale=1,user-scalable=no">
        <style>*{margin:0;padding:0;overflow:hidden}
        body{background:#000;width:100vw;height:100vh;touch-action:none}
        canvas{width:100vw;height:100vh;display:block;image-rendering:pixelated}</style></head>
        <body><canvas id="c"></canvas><script>
        const canvas=document.getElementById('c');
        const ctx=canvas.getContext('2d');
        canvas.width=\(1280);canvas.height=\(960);
        const ws=new WebSocket('ws://localhost:\(WS_PORT)');
        ws.binaryType='arraybuffer';
        let latestFrame=null,pending=false;
        ws.onmessage=async(e)=>{
          const blob=new Blob([e.data],{type:'image/jpeg'});
          const bmp=await createImageBitmap(blob);
          if(latestFrame)latestFrame.close();
          latestFrame=bmp;
          if(!pending){pending=true;requestAnimationFrame(render);}
        };
        function render(){
          if(latestFrame){ctx.drawImage(latestFrame,0,0,canvas.width,canvas.height);latestFrame.close();latestFrame=null;}
          pending=false;
        }
        document.body.addEventListener('click',()=>{document.documentElement.requestFullscreen().catch(()=>{});});
        </script></body></html>
        """
        htmlPage = Data(html.utf8)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                print("HTTP server on http://localhost:\(HTTP_PORT)")
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: self!.queue)
            self?.handleConnection(conn)
        }
        listener.start(queue: queue)
    }

    func handleConnection(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self = self, let data = data else { conn.cancel(); return }
            let request = String(data: data, encoding: .utf8) ?? ""
            if request.contains("GET") {
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(self.htmlPage.count)\r\nConnection: close\r\n\r\n"
                var responseData = Data(response.utf8)
                responseData.append(self.htmlPage)
                conn.send(content: responseData, completion: .contentProcessed { _ in conn.cancel() })
            } else { conn.cancel() }
        }
    }
}

// MARK: - Screen Capture (CPU-only: vImage SIMD + LZ4 delta)

class ScreenCapture: NSObject, SCStreamOutput {
    let tcpServer: TCPServer
    let wsServer: WebSocketServer
    let ciContext: CIContext  // Only used for WebSocket JPEG fallback
    let targetDisplayID: CGDirectDisplayID
    var stream: SCStream?

    // Frame buffers for delta encoding
    var currentGray: UnsafeMutablePointer<UInt8>?
    var previousGray: UnsafeMutablePointer<UInt8>?
    var deltaBuffer: UnsafeMutablePointer<UInt8>?
    var compressedBuffer: UnsafeMutablePointer<CChar>?
    var frameWidth: Int = 0
    var frameHeight: Int = 0
    var pixelCount: Int = 0

    // Stats
    var frameCount: Int = 0
    var lastStatTime: Date = Date()
    var convertTimeSum: Double = 0
    var compressTimeSum: Double = 0
    var statFrames: Int = 0
    var lastCompressedSize: Int = 0

    init(tcpServer: TCPServer, wsServer: WebSocketServer, targetDisplayID: CGDirectDisplayID) {
        self.tcpServer = tcpServer
        self.wsServer = wsServer
        self.targetDisplayID = targetDisplayID
        self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // Find our virtual display by ID
        guard let display = content.displays.first(where: {
            $0.displayID == targetDisplayID
        }) ?? content.displays.first(where: {
            $0.width == Int(DISPLAY_W) && $0.height == Int(DISPLAY_H)
        }) ?? content.displays.first else {
            print("No display found!")
            return
        }

        frameWidth = Int(display.width)
        frameHeight = Int(display.height)
        pixelCount = frameWidth * frameHeight

        // Allocate frame buffers
        currentGray = .allocate(capacity: pixelCount)
        previousGray = .allocate(capacity: pixelCount)
        deltaBuffer = .allocate(capacity: pixelCount)
        // LZ4 worst case: input size + overhead
        let maxCompressed = LZ4_compressBound(Int32(pixelCount))
        compressedBuffer = .allocate(capacity: Int(maxCompressed))

        // Zero out previous frame (first frame will be a keyframe)
        previousGray!.initialize(repeating: 0, count: pixelCount)

        print("Capturing display: \(display.width)x\(display.height) (ID: \(display.displayID))")

        let config = SCStreamConfiguration()
        config.width = frameWidth
        config.height = frameHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(TARGET_FPS))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 3
        config.showsCursor = true

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        stream = SCStream(filter: filter, configuration: config, delegate: nil)

        let captureQueue = DispatchQueue(label: "capture", qos: .userInteractive)
        try stream!.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await stream!.startCapture()

        lastStatTime = Date()
        print("Capture started at \(TARGET_FPS)fps — vImage + LZ4 delta (zero GPU)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let t0 = CACurrentMediaTime()

        // --- Step 1: vImage BGRA → Greyscale (CPU SIMD, ~0.2ms) ---
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)!
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var srcBuffer = vImage_Buffer(
            data: baseAddress,
            height: vImagePixelCount(frameHeight),
            width: vImagePixelCount(frameWidth),
            rowBytes: rowBytes
        )
        var dstBuffer = vImage_Buffer(
            data: currentGray!,
            height: vImagePixelCount(frameHeight),
            width: vImagePixelCount(frameWidth),
            rowBytes: frameWidth
        )

        // BT.601 luminance from BGRA channel order: [B=29, G=150, R=77, A=0] / 256
        var matrix: [Int16] = [29, 150, 77, 0]
        let divisor: Int32 = 256
        var preBias: [Int16] = [0, 0, 0, 0]

        vImageMatrixMultiply_ARGB8888ToPlanar8(
            &srcBuffer, &dstBuffer,
            &matrix, divisor,
            &preBias, 0,
            vImage_Flags(kvImageNoFlags)
        )

        let t1 = CACurrentMediaTime()

        // --- Step 2: Delta encode (XOR with previous frame, ~0.1ms) ---
        let isKeyframe = (frameCount % KEYFRAME_INTERVAL == 0)

        if isKeyframe {
            // Keyframe: compress current frame directly (no XOR)
            let compressedSize = LZ4_compress_default(
                currentGray!, compressedBuffer!, Int32(pixelCount),
                LZ4_compressBound(Int32(pixelCount))
            )
            let payload = Data(bytes: compressedBuffer!, count: Int(compressedSize))
            tcpServer.broadcast(payload: payload, isKeyframe: true)
            lastCompressedSize = Int(compressedSize)
        } else {
            // Delta: XOR current with previous, then compress
            for i in 0..<pixelCount {
                deltaBuffer![i] = currentGray![i] ^ previousGray![i]
            }
            let compressedSize = LZ4_compress_default(
                deltaBuffer!, compressedBuffer!, Int32(pixelCount),
                LZ4_compressBound(Int32(pixelCount))
            )
            let payload = Data(bytes: compressedBuffer!, count: Int(compressedSize))
            tcpServer.broadcast(payload: payload, isKeyframe: false)
            lastCompressedSize = Int(compressedSize)
        }

        // Swap: current becomes previous for next frame
        let temp = previousGray
        previousGray = currentGray
        currentGray = temp

        let t2 = CACurrentMediaTime()

        // --- Step 3: WebSocket JPEG fallback (only if Chrome clients connected) ---
        if wsServer.hasClients {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let grayImage = ciImage.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
            if let jpegData = ciContext.jpegRepresentation(
                of: grayImage,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: JPEG_QUALITY]
            ) {
                wsServer.broadcast(jpegData)
            }
        }

        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        // Stats
        frameCount += 1
        statFrames += 1
        convertTimeSum += (t1 - t0) * 1000
        compressTimeSum += (t2 - t1) * 1000

        let now = Date()
        if now.timeIntervalSince(lastStatTime) >= 5.0 {
            let fps = Double(statFrames) / now.timeIntervalSince(lastStatTime)
            let avgConvert = statFrames > 0 ? convertTimeSum / Double(statFrames) : 0
            let avgCompress = statFrames > 0 ? compressTimeSum / Double(statFrames) : 0
            let bw = Double(lastCompressedSize) * fps / 1024 / 1024
            let kf = (frameCount % KEYFRAME_INTERVAL == 0) ? " [KF]" : ""
            print(String(format: "FPS: %.1f | gray: %.1fms | lz4+delta: %.1fms | frame: %dKB | ~%.1fMB/s | total: %d%@",
                         fps, avgConvert, avgCompress, lastCompressedSize / 1024, bw, frameCount, kf))
            statFrames = 0
            convertTimeSum = 0
            compressTimeSum = 0
            lastStatTime = now
        }
    }
}

// MARK: - Main

setbuf(stdout, nil)

print("Daylight Mirror v5 — virtual display + vImage + LZ4 delta, zero GPU")
print("---")

// Step 1: Create virtual display (replaces BetterDisplay)
let displayManager = VirtualDisplayManager()

// Give macOS a moment to register the new display
Thread.sleep(forTimeInterval: 1.0)

// Step 2: Set up mirroring (built-in display mirrors our virtual display)
displayManager.mirrorBuiltInDisplay()

// Give mirroring a moment to take effect
Thread.sleep(forTimeInterval: 1.0)

// Step 3: Start servers
let tcpServer = try TCPServer(port: PORT)
tcpServer.start()

let wsServer = try WebSocketServer(port: WS_PORT)
wsServer.start()

let httpServer = try HTTPServer(port: HTTP_PORT)
httpServer.start()

// Step 4: Start screen capture targeting our virtual display
let capture = ScreenCapture(tcpServer: tcpServer, wsServer: wsServer, targetDisplayID: displayManager.displayID)

Task {
    do {
        try await capture.start()
    } catch {
        print("Capture error: \(error)")
    }
}

// Step 5: Start brightness controller (Ctrl+F1/F2)
let brightnessController = DisplayController(tcpServer: tcpServer)
brightnessController.start()

print("---")
print("Native TCP:  tcp://localhost:\(PORT)")
print("WS fallback: ws://localhost:\(WS_PORT)")
print("HTML page:   http://localhost:\(HTTP_PORT)")
print("Virtual display \(displayManager.displayID): \(DISPLAY_W)x\(DISPLAY_H)")
print("Ctrl+F1/F2:  Daylight brightness")
print("Ctrl+C to stop (virtual display will disappear automatically)")

// Handle clean exit — unmirror before virtual display is deallocated
signal(SIGINT) { _ in
    print("\nShutting down...")
    exit(0)
}

RunLoop.main.run()
