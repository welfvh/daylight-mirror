// MirrorEngine.swift — Core engine for Daylight Mirror.
//
// Orchestrates: virtual display creation, screen capture, TCP/WS/HTTP servers,
// display controls (brightness, warmth, backlight), and adb bridge.
//
// Used by both the CLI (`daylight-mirror`) and the menu bar app (`DaylightMirror`).
// All heavy lifting is zero-GPU: vImage SIMD greyscale + LZ4 delta compression.

import Foundation
import ScreenCaptureKit
import CoreImage
import CoreMedia
import Network
import Accelerate
import CLZ4
import CVirtualDisplay
import AppKit

// MARK: - Configuration

let TCP_PORT: UInt16 = 8888
let WS_PORT: UInt16 = 8890
let HTTP_PORT: UInt16 = 8891
let TARGET_FPS: Int = 30
let JPEG_QUALITY: CGFloat = 0.8
let KEYFRAME_INTERVAL: Int = 30

let DISPLAY_W: UInt = 1280
let DISPLAY_H: UInt = 960

// Protocol constants
let MAGIC_FRAME: [UInt8] = [0xDA, 0x7E]
let MAGIC_CMD: [UInt8] = [0xDA, 0x7F]
let FLAG_KEYFRAME: UInt8 = 0x01
let CMD_BRIGHTNESS: UInt8 = 0x01
let CMD_WARMTH: UInt8 = 0x02
let CMD_BACKLIGHT_TOGGLE: UInt8 = 0x03

let BRIGHTNESS_STEP: Int = 15
let WARMTH_STEP: Int = 20

// MARK: - Status

public enum MirrorStatus: Equatable {
    case idle
    case starting
    case running
    case stopping
    case error(String)
}

// MARK: - ADB Bridge

struct ADBBridge {
    static func isAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "adb"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func connectedDevice() -> String? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["adb", "devices"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t")
            if parts.count >= 2 && parts[1] == "device" {
                return String(parts[0])
            }
        }
        return nil
    }

    @discardableResult
    static func setupReverseTunnel(port: UInt16) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["adb", "reverse", "tcp:\(port)", "tcp:\(port)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @discardableResult
    static func removeReverseTunnel(port: UInt16) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["adb", "reverse", "--remove", "tcp:\(port)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func querySystemSetting(_ setting: String) -> Int? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["adb", "shell", "settings", "get", "system", setting]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        if let str = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            return Int(str)
        }
        return nil
    }

    static func setSystemSetting(_ setting: String, value: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["adb", "shell", "settings", "put", "system", setting, "\(value)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

// MARK: - Virtual Display Manager

/// Creates a 1280x960 non-HiDPI virtual display and mirrors the Mac's built-in
/// display to it. Uses CGVirtualDisplay private API (same as BetterDisplay, DeskPad).
/// The virtual display disappears when this object is deallocated.
class VirtualDisplayManager {
    let virtualDisplay: CGVirtualDisplay
    let displayID: CGDirectDisplayID

    init() {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "Daylight DC-1"
        descriptor.maxPixelsWide = UInt32(DISPLAY_W)
        descriptor.maxPixelsHigh = UInt32(DISPLAY_H)
        descriptor.sizeInMillimeters = CGSize(
            width: 25.4 * Double(DISPLAY_W) / 100.0,
            height: 25.4 * Double(DISPLAY_H) / 100.0
        )
        descriptor.productID = 0xDA7E
        descriptor.vendorID = 0xDA7E
        descriptor.serialNum = 0x0001

        virtualDisplay = CGVirtualDisplay(descriptor: descriptor)
        displayID = virtualDisplay.displayID
        print("Virtual display created: ID \(displayID)")

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [
            CGVirtualDisplayMode(width: DISPLAY_W, height: DISPLAY_H, refreshRate: 60)
        ]

        guard virtualDisplay.apply(settings) else {
            print("WARNING: Failed to apply virtual display settings")
            return
        }
        print("Virtual display configured: \(DISPLAY_W)x\(DISPLAY_H) non-HiDPI @ 60Hz")
    }

    func mirrorBuiltInDisplay() {
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
            print("WARNING: No built-in display found")
            return
        }

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let config = configRef else {
            print("WARNING: Failed to begin display configuration")
            return
        }

        guard CGConfigureDisplayMirrorOfDisplay(config, masterID, displayID) == .success else {
            print("WARNING: Failed to configure mirror")
            CGCancelDisplayConfiguration(config)
            return
        }

        guard CGCompleteDisplayConfiguration(config, .forSession) == .success else {
            print("WARNING: Failed to complete mirror configuration")
            return
        }

        print("Mirroring: built-in display \(masterID) -> virtual display \(displayID)")
    }
}

// MARK: - TCP Server

class TCPServer {
    let listener: NWListener
    var connections: [NWConnection] = []
    let queue = DispatchQueue(label: "tcp-server")
    let lock = NSLock()
    var lastKeyframeData: Data?
    var onClientCountChanged: ((Int) -> Void)?

    init(port: UInt16) throws {
        let params = NWParameters.tcp
        let tcpOptions = params.defaultProtocolStack.transportProtocol as! NWProtocolTCP.Options
        tcpOptions.noDelay = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                print("TCP server on tcp://localhost:\(TCP_PORT)")
            }
        }

        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[TCP] Client connected")
                case .failed, .cancelled:
                    self.lock.lock()
                    self.connections.removeAll { $0 === conn }
                    let count = self.connections.count
                    self.lock.unlock()
                    self.onClientCountChanged?(count)
                    print("[TCP] Client disconnected")
                default: break
                }
            }
            conn.start(queue: self.queue)
            self.lock.lock()
            self.connections.append(conn)
            let count = self.connections.count
            let cachedKeyframe = self.lastKeyframeData
            self.lock.unlock()
            self.onClientCountChanged?(count)

            if let kf = cachedKeyframe {
                conn.send(content: kf, completion: .contentProcessed { _ in })
                print("[TCP] Sent cached keyframe (\(kf.count) bytes)")
            }

            self.receiveLoop(conn)
        }

        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        lock.lock()
        for conn in connections { conn.cancel() }
        connections.removeAll()
        lock.unlock()
    }

    func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, _, error in
            if error != nil { return }
            self?.receiveLoop(conn)
        }
    }

    func broadcast(payload: Data, isKeyframe: Bool) {
        var header = Data(capacity: 7)
        header.append(contentsOf: MAGIC_FRAME)
        header.append(isKeyframe ? FLAG_KEYFRAME : 0)
        var len = UInt32(payload.count).littleEndian
        header.append(Data(bytes: &len, count: 4))

        var frame = header
        frame.append(payload)

        lock.lock()
        if isKeyframe { lastKeyframeData = frame }
        let conns = connections
        lock.unlock()

        for conn in conns {
            conn.send(content: frame, completion: .contentProcessed { _ in })
        }
    }

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
                case .ready: print("[WS] Client connected")
                case .failed, .cancelled:
                    self.lock.lock()
                    self.connections.removeAll { $0 === conn }
                    self.lock.unlock()
                    print("[WS] Client disconnected")
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

    func stop() {
        listener.cancel()
        lock.lock()
        for conn in connections { conn.cancel() }
        connections.removeAll()
        lock.unlock()
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

// MARK: - HTTP Server (serves HTML viewer for Chrome fallback)

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
        canvas.width=\(DISPLAY_W);canvas.height=\(DISPLAY_H);
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

    func stop() {
        listener.cancel()
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
    let ciContext: CIContext
    let targetDisplayID: CGDirectDisplayID
    var stream: SCStream?

    var currentGray: UnsafeMutablePointer<UInt8>?
    var previousGray: UnsafeMutablePointer<UInt8>?
    var deltaBuffer: UnsafeMutablePointer<UInt8>?
    var compressedBuffer: UnsafeMutablePointer<CChar>?
    var frameWidth: Int = 0
    var frameHeight: Int = 0
    var pixelCount: Int = 0

    var frameCount: Int = 0
    var lastStatTime: Date = Date()
    var convertTimeSum: Double = 0
    var compressTimeSum: Double = 0
    var statFrames: Int = 0
    var lastCompressedSize: Int = 0

    /// Callback: (fps, bandwidthMB, frameSizeKB, totalFrames)
    var onStats: ((Double, Double, Int, Int) -> Void)?

    init(tcpServer: TCPServer, wsServer: WebSocketServer, targetDisplayID: CGDirectDisplayID) {
        self.tcpServer = tcpServer
        self.wsServer = wsServer
        self.targetDisplayID = targetDisplayID
        self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

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

        currentGray = .allocate(capacity: pixelCount)
        previousGray = .allocate(capacity: pixelCount)
        deltaBuffer = .allocate(capacity: pixelCount)
        let maxCompressed = LZ4_compressBound(Int32(pixelCount))
        compressedBuffer = .allocate(capacity: Int(maxCompressed))
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
        print("Capture started at \(TARGET_FPS)fps -- vImage + LZ4 delta (zero GPU)")
    }

    func stop() async {
        if let stream = stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        currentGray?.deallocate(); currentGray = nil
        previousGray?.deallocate(); previousGray = nil
        deltaBuffer?.deallocate(); deltaBuffer = nil
        compressedBuffer?.deallocate(); compressedBuffer = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let t0 = CACurrentMediaTime()

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

        let isKeyframe = (frameCount % KEYFRAME_INTERVAL == 0)

        if isKeyframe {
            let compressedSize = LZ4_compress_default(
                currentGray!, compressedBuffer!, Int32(pixelCount),
                LZ4_compressBound(Int32(pixelCount))
            )
            let payload = Data(bytes: compressedBuffer!, count: Int(compressedSize))
            tcpServer.broadcast(payload: payload, isKeyframe: true)
            lastCompressedSize = Int(compressedSize)
        } else {
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

        let temp = previousGray
        previousGray = currentGray
        currentGray = temp

        let t2 = CACurrentMediaTime()

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

            print(String(format: "FPS: %.1f | gray: %.1fms | lz4+delta: %.1fms | frame: %dKB | ~%.1fMB/s | total: %d",
                         fps, avgConvert, avgCompress, lastCompressedSize / 1024, bw, frameCount))
            onStats?(fps, bw, lastCompressedSize / 1024, frameCount)

            statFrames = 0
            convertTimeSum = 0
            compressTimeSum = 0
            lastStatTime = now
        }
    }
}

// MARK: - Display Controller (keyboard controls for Daylight hardware)

/// Intercepts Ctrl+function key events for Daylight display control:
///   Ctrl+F1/F2:   Brightness down/up
///   Ctrl+F10:     Toggle backlight on/off
///   Ctrl+F11/F12: Warmth (amber) down/up
class DisplayController {
    let tcpServer: TCPServer
    var currentBrightness: Int = 128
    var currentWarmth: Int = 128
    var backlightOn: Bool = true
    var savedBrightness: Int = 128
    var eventTap: CFMachPort?

    var onBrightnessChanged: ((Int) -> Void)?
    var onWarmthChanged: ((Int) -> Void)?
    var onBacklightChanged: ((Bool) -> Void)?

    init(tcpServer: TCPServer) {
        self.tcpServer = tcpServer
    }

    func start() {
        // Query current values from device
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            if let val = ADBBridge.querySystemSetting("screen_brightness") {
                self.currentBrightness = val
                self.savedBrightness = val
                self.onBrightnessChanged?(val)
                print("[Display] Daylight brightness: \(val)/255")
            }
            if let val = ADBBridge.querySystemSetting("screen_brightness_amber_rate") {
                self.currentWarmth = min(val, 255)
                self.onWarmthChanged?(self.currentWarmth)
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
                    case 122: controller.adjustBrightness(by: -BRIGHTNESS_STEP); return nil
                    case 120: controller.adjustBrightness(by: BRIGHTNESS_STEP); return nil
                    case 109: controller.toggleBacklight(); return nil
                    case 103: controller.adjustWarmth(by: -WARMTH_STEP); return nil
                    case 111: controller.adjustWarmth(by: WARMTH_STEP); return nil
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
                            case 3: controller.adjustBrightness(by: -BRIGHTNESS_STEP); return nil
                            case 2: controller.adjustBrightness(by: BRIGHTNESS_STEP); return nil
                            case 7: controller.toggleBacklight(); return nil
                            case 1: controller.adjustWarmth(by: -WARMTH_STEP); return nil
                            case 0: controller.adjustWarmth(by: WARMTH_STEP); return nil
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
            print("[Display] Grant Accessibility: System Settings -> Privacy & Security -> Accessibility")
            return
        }

        self.eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("[Display] Ctrl+F1/F2: brightness | Ctrl+F10: backlight toggle | Ctrl+F11/F12: warmth")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    func adjustBrightness(by delta: Int) {
        currentBrightness = max(0, min(255, currentBrightness + delta))
        savedBrightness = currentBrightness
        backlightOn = currentBrightness > 0
        tcpServer.sendCommand(CMD_BRIGHTNESS, value: UInt8(currentBrightness))
        onBrightnessChanged?(currentBrightness)
        onBacklightChanged?(backlightOn)
        print("[Display] Brightness -> \(currentBrightness)/255")
    }

    func setBrightness(_ value: Int) {
        currentBrightness = max(0, min(255, value))
        savedBrightness = currentBrightness
        backlightOn = currentBrightness > 0
        tcpServer.sendCommand(CMD_BRIGHTNESS, value: UInt8(currentBrightness))
        onBrightnessChanged?(currentBrightness)
        onBacklightChanged?(backlightOn)
    }

    func adjustWarmth(by delta: Int) {
        currentWarmth = max(0, min(255, currentWarmth + delta))
        DispatchQueue.global().async { [warmth = currentWarmth] in
            ADBBridge.setSystemSetting("screen_brightness_amber_rate", value: warmth)
        }
        onWarmthChanged?(currentWarmth)
        print("[Display] Warmth -> \(currentWarmth)/255")
    }

    func setWarmth(_ value: Int) {
        currentWarmth = max(0, min(255, value))
        DispatchQueue.global().async { [warmth = currentWarmth] in
            ADBBridge.setSystemSetting("screen_brightness_amber_rate", value: warmth)
        }
        onWarmthChanged?(currentWarmth)
    }

    func toggleBacklight() {
        if backlightOn {
            savedBrightness = max(currentBrightness, 1)
            currentBrightness = 0
            backlightOn = false
            tcpServer.sendCommand(CMD_BRIGHTNESS, value: 0)
            onBrightnessChanged?(0)
            onBacklightChanged?(false)
            print("[Display] Backlight OFF")
        } else {
            currentBrightness = savedBrightness
            backlightOn = true
            tcpServer.sendCommand(CMD_BRIGHTNESS, value: UInt8(currentBrightness))
            onBrightnessChanged?(currentBrightness)
            onBacklightChanged?(true)
            print("[Display] Backlight ON -> \(currentBrightness)/255")
        }
    }
}

// MARK: - Mirror Engine

public class MirrorEngine: ObservableObject {
    @Published public var status: MirrorStatus = .idle
    @Published public var fps: Double = 0
    @Published public var bandwidth: Double = 0
    @Published public var brightness: Int = 128
    @Published public var warmth: Int = 128
    @Published public var backlightOn: Bool = true
    @Published public var adbConnected: Bool = false
    @Published public var clientCount: Int = 0
    @Published public var totalFrames: Int = 0

    private var displayManager: VirtualDisplayManager?
    private var tcpServer: TCPServer?
    private var wsServer: WebSocketServer?
    private var httpServer: HTTPServer?
    private var capture: ScreenCapture?
    private var displayController: DisplayController?

    public init() {}

    @MainActor
    public func start() async {
        guard status == .idle || status != .starting else { return }
        status = .starting

        // 1. ADB — optional (mirror works over WiFi too)
        if ADBBridge.isAvailable(), let device = ADBBridge.connectedDevice() {
            print("ADB device: \(device)")
            ADBBridge.setupReverseTunnel(port: TCP_PORT)
            adbConnected = true
        } else {
            print("No ADB device (mirror will wait for TCP connection)")
            adbConnected = false
        }

        // 2. Virtual display
        displayManager = VirtualDisplayManager()
        try? await Task.sleep(for: .seconds(1))

        // 3. Mirroring
        displayManager?.mirrorBuiltInDisplay()
        try? await Task.sleep(for: .seconds(1))

        // 4. Servers
        do {
            let tcp = try TCPServer(port: TCP_PORT)
            tcp.onClientCountChanged = { [weak self] count in
                DispatchQueue.main.async { self?.clientCount = count }
            }
            tcp.start()
            tcpServer = tcp

            let ws = try WebSocketServer(port: WS_PORT)
            ws.start()
            wsServer = ws

            let http = try HTTPServer(port: HTTP_PORT)
            http.start()
            httpServer = http
        } catch {
            status = .error("Server failed: \(error.localizedDescription)")
            displayManager = nil
            return
        }

        // 5. Capture
        let cap = ScreenCapture(
            tcpServer: tcpServer!, wsServer: wsServer!,
            targetDisplayID: displayManager!.displayID
        )
        cap.onStats = { [weak self] fps, bw, _, total in
            DispatchQueue.main.async {
                self?.fps = fps
                self?.bandwidth = bw
                self?.totalFrames = total
            }
        }
        capture = cap

        do {
            try await cap.start()
        } catch {
            status = .error("Capture failed: \(error.localizedDescription)")
            tcpServer?.stop(); wsServer?.stop(); httpServer?.stop()
            displayManager = nil
            return
        }

        // 6. Display controller (keyboard shortcuts)
        let dc = DisplayController(tcpServer: tcpServer!)
        dc.onBrightnessChanged = { [weak self] val in
            DispatchQueue.main.async { self?.brightness = val }
        }
        dc.onWarmthChanged = { [weak self] val in
            DispatchQueue.main.async { self?.warmth = val }
        }
        dc.onBacklightChanged = { [weak self] on in
            DispatchQueue.main.async { self?.backlightOn = on }
        }
        dc.start()
        displayController = dc

        // Sync initial values
        brightness = dc.currentBrightness
        warmth = dc.currentWarmth
        backlightOn = dc.backlightOn

        status = .running

        print("---")
        print("Native TCP:  tcp://localhost:\(TCP_PORT)")
        print("WS fallback: ws://localhost:\(WS_PORT)")
        print("HTML page:   http://localhost:\(HTTP_PORT)")
        print("Virtual display \(displayManager!.displayID): \(DISPLAY_W)x\(DISPLAY_H)")
    }

    public func stop() {
        guard status == .running else { return }
        DispatchQueue.main.async { self.status = .stopping }

        Task {
            // Stop in reverse order
            displayController?.stop()
            displayController = nil

            await capture?.stop()
            capture = nil

            tcpServer?.stop()
            wsServer?.stop()
            httpServer?.stop()
            tcpServer = nil
            wsServer = nil
            httpServer = nil

            // Virtual display disappears on dealloc, mirroring reverts
            displayManager = nil

            if adbConnected {
                ADBBridge.removeReverseTunnel(port: TCP_PORT)
            }

            await MainActor.run {
                status = .idle
                fps = 0
                bandwidth = 0
                clientCount = 0
                totalFrames = 0
                adbConnected = false
            }

            print("Mirror stopped")
        }
    }

    public func setBrightness(_ value: Int) {
        displayController?.setBrightness(value)
        brightness = max(0, min(255, value))
        backlightOn = brightness > 0
    }

    public func setWarmth(_ value: Int) {
        displayController?.setWarmth(value)
        warmth = max(0, min(255, value))
    }

    public func toggleBacklight() {
        displayController?.toggleBacklight()
        if let dc = displayController {
            brightness = dc.currentBrightness
            backlightOn = dc.backlightOn
        }
    }
}
