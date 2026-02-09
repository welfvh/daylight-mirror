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
import IOKit.graphics

// MARK: - Configuration

let TCP_PORT: UInt16 = 8888
let WS_PORT: UInt16 = 8890
let HTTP_PORT: UInt16 = 8891
let TARGET_FPS: Int = 30
let JPEG_QUALITY: CGFloat = 0.8
let KEYFRAME_INTERVAL: Int = 30

// Resolution presets (all 4:3, matching Daylight DC-1 aspect ratio)
public enum DisplayResolution: String, CaseIterable, Identifiable {
    case comfortable = "1024x768"   // Larger UI, easy on the eyes
    case balanced    = "1280x960"   // Good balance of size and sharpness
    case sharp       = "1600x1200"  // Maximum sharpness, smaller UI

    public var id: String { rawValue }
    public var width: UInt { switch self { case .comfortable: 1024; case .balanced: 1280; case .sharp: 1600 } }
    public var height: UInt { switch self { case .comfortable: 768; case .balanced: 960; case .sharp: 1200 } }
    public var label: String { switch self { case .comfortable: "Comfortable"; case .balanced: "Balanced"; case .sharp: "Sharp" } }
}

// Protocol constants
let MAGIC_FRAME: [UInt8] = [0xDA, 0x7E]
let MAGIC_CMD: [UInt8] = [0xDA, 0x7F]
let FLAG_KEYFRAME: UInt8 = 0x01
let CMD_BRIGHTNESS: UInt8 = 0x01
let CMD_WARMTH: UInt8 = 0x02
let CMD_BACKLIGHT_TOGGLE: UInt8 = 0x03
let CMD_RESOLUTION: UInt8 = 0x04

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

    /// Launch the Daylight Mirror Android app on the connected device.
    static func launchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["adb", "shell", "am", "start", "-n",
                             "com.daylight.mirror/.MirrorActivity"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        print("[ADB] Launched Daylight Mirror on device")
    }
}

// MARK: - Mac Brightness Control

/// Controls the Mac's built-in display brightness via IOKit.
/// Used to auto-dim the Mac when the Daylight is connected (no point lighting both screens).
struct MacBrightness {
    static func get() -> Float? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
              IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            var brightness: Float = 0
            let err = IODisplayGetFloatParameter(service, 0,
                      kIODisplayBrightnessKey as CFString, &brightness)
            IOObjectRelease(service)
            if err == kIOReturnSuccess { return brightness }
            service = IOIteratorNext(iterator)
        }
        return nil
    }

    static func set(_ value: Float) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
              IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            IODisplaySetFloatParameter(service, 0,
                kIODisplayBrightnessKey as CFString, value)
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }
}

// MARK: - Virtual Display Manager

/// Creates a non-HiDPI virtual display at the given resolution and mirrors the Mac's
/// built-in display to it. Uses CGVirtualDisplay private API (same as BetterDisplay, DeskPad).
/// The virtual display disappears when this object is deallocated.
class VirtualDisplayManager {
    let virtualDisplay: CGVirtualDisplay
    let displayID: CGDirectDisplayID
    let width: UInt
    let height: UInt

    init(width: UInt, height: UInt) {
        self.width = width
        self.height = height

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "Daylight DC-1"
        descriptor.maxPixelsWide = UInt32(width)
        descriptor.maxPixelsHigh = UInt32(height)
        descriptor.sizeInMillimeters = CGSize(
            width: 25.4 * Double(width) / 100.0,
            height: 25.4 * Double(height) / 100.0
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
            CGVirtualDisplayMode(width: width, height: height, refreshRate: 60)
        ]

        guard virtualDisplay.apply(settings) else {
            print("WARNING: Failed to apply virtual display settings")
            return
        }
        print("Virtual display configured: \(width)x\(height) non-HiDPI @ 60Hz")
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
    var frameWidth: UInt16 = 1024 {
        didSet { lock.lock(); lastKeyframeData = nil; lock.unlock() }
    }
    var frameHeight: UInt16 = 768 {
        didSet { lock.lock(); lastKeyframeData = nil; lock.unlock() }
    }

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

            // Tell client our frame dimensions before sending any frames
            self.sendResolution(to: conn)

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

    /// Send resolution command to a specific client: [DA 7F] [04] [w:2 LE] [h:2 LE]
    func sendResolution(to conn: NWConnection) {
        var packet = Data(capacity: 7)
        packet.append(contentsOf: MAGIC_CMD)
        packet.append(CMD_RESOLUTION)
        var w = frameWidth.littleEndian
        var h = frameHeight.littleEndian
        packet.append(Data(bytes: &w, count: 2))
        packet.append(Data(bytes: &h, count: 2))
        conn.send(content: packet, completion: .contentProcessed { _ in })
        print("[TCP] Sent resolution: \(self.frameWidth)x\(self.frameHeight)")
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

    init(port: UInt16, width: UInt, height: UInt) throws {
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
        canvas.width=\(width);canvas.height=\(height);
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

    let expectedWidth: Int
    let expectedHeight: Int

    init(tcpServer: TCPServer, wsServer: WebSocketServer, targetDisplayID: CGDirectDisplayID, width: Int, height: Int) {
        self.tcpServer = tcpServer
        self.wsServer = wsServer
        self.targetDisplayID = targetDisplayID
        self.expectedWidth = width
        self.expectedHeight = height
        self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let display = content.displays.first(where: {
            $0.displayID == targetDisplayID
        }) ?? content.displays.first(where: {
            $0.width == expectedWidth && $0.height == expectedHeight
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
    var keyMonitor: Any?
    var systemMonitor: Any?

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
                // Effective range is 0-255 (device accepts 0-1023 but caps effect at 255)
                self.currentWarmth = min(val, 255)
                self.onWarmthChanged?(self.currentWarmth)
                print("[Display] Daylight warmth: \(self.currentWarmth)/255")
            }
        }

        // NSEvent monitors for keyboard shortcuts (no TCC code-signing issues)
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains(.control), let self = self else { return }
            switch event.keyCode {
            case 122: self.adjustBrightness(by: -BRIGHTNESS_STEP)  // Ctrl+F1
            case 120: self.adjustBrightness(by: BRIGHTNESS_STEP)   // Ctrl+F2
            case 109: self.toggleBacklight()                       // Ctrl+F10
            case 103: self.adjustWarmth(by: -WARMTH_STEP)          // Ctrl+F11
            case 111: self.adjustWarmth(by: WARMTH_STEP)           // Ctrl+F12
            default: break
            }
        }

        systemMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard event.subtype.rawValue == 8, let self = self else { return }
            let data1 = event.data1
            let keyCode = (data1 & 0xFFFF0000) >> 16
            let keyDown = ((data1 & 0xFF00) >> 8) == 0xA
            guard keyDown && event.modifierFlags.contains(.control) else { return }
            switch keyCode {
            case 3: self.adjustBrightness(by: -BRIGHTNESS_STEP)  // Ctrl+F1 media
            case 2: self.adjustBrightness(by: BRIGHTNESS_STEP)   // Ctrl+F2 media
            case 7: self.toggleBacklight()                       // Ctrl+F10 media
            case 1: self.adjustWarmth(by: -WARMTH_STEP)          // Ctrl+F11 media
            case 0: self.adjustWarmth(by: WARMTH_STEP)           // Ctrl+F12 media
            default: break
            }
        }

        print("[Display] Ctrl+F1/F2: brightness | Ctrl+F10: backlight toggle | Ctrl+F11/F12: warmth")
    }

    func stop() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        if let m = systemMonitor { NSEvent.removeMonitor(m); systemMonitor = nil }
    }

    /// Step brightness using the same quadratic curve as the slider.
    /// Steps happen in slider-space (0–1) so they're tiny at low brightness, bigger at high.
    func adjustBrightness(by delta: Int) {
        let pos = sqrt(Double(currentBrightness) / 255.0)
        let step = 0.05 * Double(delta > 0 ? 1 : -1)
        let newPos = max(0, min(1, pos + step))
        currentBrightness = Self.brightnessFromSliderPos(newPos)
        savedBrightness = max(currentBrightness, 1)
        backlightOn = currentBrightness > 0
        tcpServer.sendCommand(CMD_BRIGHTNESS, value: UInt8(currentBrightness))
        onBrightnessChanged?(currentBrightness)
        onBacklightChanged?(backlightOn)
        print("[Display] Brightness -> \(currentBrightness)/255")
    }

    func setBrightness(_ value: Int) {
        currentBrightness = max(0, min(255, value))
        savedBrightness = max(currentBrightness, 1)
        backlightOn = currentBrightness > 0
        tcpServer.sendCommand(CMD_BRIGHTNESS, value: UInt8(currentBrightness))
        onBrightnessChanged?(currentBrightness)
        onBacklightChanged?(backlightOn)
    }

    /// Quadratic curve with widened landing zone at the low end.
    /// Shared with MirrorEngine.brightnessFromSliderPos (public API for the slider).
    static func brightnessFromSliderPos(_ pos: Double) -> Int {
        MirrorEngine.brightnessFromSliderPos(pos)
    }

    func adjustWarmth(by delta: Int) {
        currentWarmth = max(0, min(255, currentWarmth + delta))
        // Warmth goes via adb shell — screen_brightness_amber_rate is a Daylight-protected
        // setting that only the shell user can write, not a regular Android app.
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
        print("[Display] Warmth -> \(currentWarmth)/255")
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

// MARK: - Update Checker

/// Checks GitHub releases for a newer version on launch. Non-blocking, fire-and-forget.
struct UpdateChecker {
    static let repo = "welfvh/daylight-mirror"

    struct Release {
        let version: String
        let url: String
    }

    static func check(currentVersion: String) async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let htmlURL = json["html_url"] as? String else {
            return nil
        }

        // Strip leading "v" for comparison (e.g. "v1.1.0" → "1.1.0")
        let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        if isNewer(remote: remoteVersion, local: currentVersion) {
            return Release(version: remoteVersion, url: htmlURL)
        }
        return nil
    }

    /// Simple semver comparison: returns true if remote > local
    private static func isNewer(remote: String, local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}

// MARK: - Mirror Engine

public class MirrorEngine: ObservableObject {
    public static let appVersion = "1.0.0"

    @Published public var status: MirrorStatus = .idle
    @Published public var fps: Double = 0
    @Published public var bandwidth: Double = 0
    @Published public var brightness: Int = 128
    @Published public var warmth: Int = 128
    @Published public var backlightOn: Bool = true
    @Published public var adbConnected: Bool = false
    @Published public var clientCount: Int = 0
    @Published public var totalFrames: Int = 0
    @Published public var updateVersion: String? = nil
    @Published public var updateURL: String? = nil
    @Published public var resolution: DisplayResolution {
        didSet { UserDefaults.standard.set(resolution.rawValue, forKey: "resolution") }
    }

    private var displayManager: VirtualDisplayManager?
    private var tcpServer: TCPServer?
    private var wsServer: WebSocketServer?
    private var httpServer: HTTPServer?
    private var capture: ScreenCapture?
    private var displayController: DisplayController?
    private var savedMacBrightness: Float?   // Mac brightness before auto-dim

    public init() {
        let saved = UserDefaults.standard.string(forKey: "resolution") ?? ""
        self.resolution = DisplayResolution(rawValue: saved) ?? .comfortable
        NSLog("[MirrorEngine] init, resolution: %@", resolution.rawValue)

        // Check for updates in the background
        Task { @MainActor in
            if let release = await UpdateChecker.check(currentVersion: Self.appVersion) {
                self.updateVersion = release.version
                self.updateURL = release.url
                NSLog("[Update] New version available: %@", release.version)
            }
        }
    }

    private var globalKeyMonitor: Any?
    private var globalSystemMonitor: Any?

    /// Call once after init, from the main thread, to register Ctrl+F8 global hotkey.
    public func setupGlobalShortcut() {
        NSLog("[Global] Setting up Ctrl+F8 hotkey via NSEvent monitors...")

        // Monitor regular key events (Ctrl+F8 = keyCode 100)
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains(.control) && event.keyCode == 100 {
                NSLog("[Global] Ctrl+F8 pressed — toggling")
                self?.toggleMirror()
            }
        }

        // Monitor system-defined events (F8 as media key = play/pause)
        globalSystemMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard event.subtype.rawValue == 8 else { return }
            let data1 = event.data1
            let keyCode = (data1 & 0xFFFF0000) >> 16
            let keyDown = ((data1 & 0xFF00) >> 8) == 0xA
            let ctrl = event.modifierFlags.contains(.control)
            if keyDown && ctrl && keyCode == 16 {
                NSLog("[Global] Ctrl+F8 media key — toggling")
                self?.toggleMirror()
            }
        }

        NSLog("[Global] Ctrl+F8 hotkey registered (key=%@, system=%@)",
              globalKeyMonitor != nil ? "yes" : "no",
              globalSystemMonitor != nil ? "yes" : "no")
    }

    /// Toggle mirror on/off from keyboard shortcut
    private func toggleMirror() {
        DispatchQueue.main.async {
            if self.status == .running {
                self.stop()
            } else if self.status == .idle {
                Task { @MainActor in
                    await self.start()
                }
            }
        }
    }

    // MARK: - Permission & Device Checks

    /// Check if Screen Recording permission is granted.
    public static func hasScreenRecordingPermission() -> Bool {
        return CGPreflightScreenCaptureAccess()
    }

    /// Prompt the user for Screen Recording permission (opens System Settings).
    public static func requestScreenRecordingPermission() {
        CGRequestScreenCaptureAccess()
    }

    /// Check if Accessibility permission is granted (needed for global keyboard shortcuts).
    public static func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Prompt for Accessibility permission with the system dialog.
    public static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Check if adb is installed.
    public static func hasADB() -> Bool {
        return ADBBridge.isAvailable()
    }

    /// Check if a Daylight device is connected via USB.
    public static func hasDevice() -> Bool {
        return ADBBridge.connectedDevice() != nil
    }

    /// Whether the onboarding setup has been completed.
    public static var setupCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: "setupCompleted") }
        set { UserDefaults.standard.set(newValue, forKey: "setupCompleted") }
    }

    /// Whether all required permissions are granted.
    public static var allPermissionsGranted: Bool {
        hasScreenRecordingPermission() && hasAccessibilityPermission()
    }

    @MainActor
    public func start() async {
        guard status == .idle || status != .starting else { return }

        // Check Screen Recording permission before attempting capture
        if !Self.hasScreenRecordingPermission() {
            Self.requestScreenRecordingPermission()
            status = .error("Grant Screen Recording permission in System Settings, then retry")
            return
        }

        status = .starting

        // 1. ADB — optional (mirror works over WiFi too)
        if ADBBridge.isAvailable(), let device = ADBBridge.connectedDevice() {
            print("ADB device: \(device)")
            ADBBridge.setupReverseTunnel(port: TCP_PORT)
            ADBBridge.launchApp()
            adbConnected = true
        } else {
            print("No ADB device (mirror will wait for TCP connection)")
            adbConnected = false
        }

        // 2. Virtual display at selected resolution
        let w = resolution.width
        let h = resolution.height
        displayManager = VirtualDisplayManager(width: w, height: h)
        try? await Task.sleep(for: .seconds(1))

        // 3. Mirroring
        displayManager?.mirrorBuiltInDisplay()
        try? await Task.sleep(for: .seconds(1))

        // 4. Servers
        do {
            let tcp = try TCPServer(port: TCP_PORT)
            tcp.frameWidth = UInt16(w)
            tcp.frameHeight = UInt16(h)
            tcp.onClientCountChanged = { [weak self] count in
                DispatchQueue.main.async {
                    let wasConnected = (self?.clientCount ?? 0) > 0
                    self?.clientCount = count

                    // Auto-dim Mac when Daylight connects, restore when it disconnects
                    if count > 0 && !wasConnected {
                        if let current = MacBrightness.get() {
                            self?.savedMacBrightness = current
                            MacBrightness.set(0)
                            print("[Mac] Auto-dimmed (was \(current))")
                        }
                    } else if count == 0 && wasConnected {
                        if let saved = self?.savedMacBrightness {
                            MacBrightness.set(saved)
                            self?.savedMacBrightness = nil
                            print("[Mac] Brightness restored to \(saved)")
                        }
                    }
                }
            }
            tcp.start()
            tcpServer = tcp

            let ws = try WebSocketServer(port: WS_PORT)
            ws.start()
            wsServer = ws

            let http = try HTTPServer(port: HTTP_PORT, width: w, height: h)
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
            targetDisplayID: displayManager!.displayID,
            width: Int(w), height: Int(h)
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
        print("Virtual display \(displayManager!.displayID): \(w)x\(h)")
    }

    public func stop() {
        guard status == .running else { return }
        DispatchQueue.main.async { self.status = .stopping }

        // Restore Mac brightness before tearing down
        if let saved = savedMacBrightness {
            MacBrightness.set(saved)
            savedMacBrightness = nil
            print("[Mac] Brightness restored to \(saved)")
        }

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

    /// Lightweight reconnect: re-establish ADB tunnel and relaunch the Android app
    /// without tearing down the virtual display, capture, or servers.
    public func reconnect() {
        guard status == .running else { return }
        print("[MirrorEngine] Reconnecting ADB...")
        Task.detached {
            ADBBridge.setupReverseTunnel(port: TCP_PORT)
            ADBBridge.launchApp()
            await MainActor.run { self.adbConnected = true }
            print("[MirrorEngine] Reconnect done — tunnel + app relaunched")
        }
    }

    /// Quadratic curve with widened landing zone at the low end.
    ///   pos 0.00–0.03 → off (0)
    ///   pos 0.03–0.08 → minimum (1)  — ~5% of slider travel
    ///   pos 0.08–1.00 → quadratic ramp (2–255)
    public static func brightnessFromSliderPos(_ pos: Double) -> Int {
        if pos < 0.03 { return 0 }
        let raw = pos * pos * 255.0
        if raw < 1.5 { return 1 }
        return min(255, Int(raw))
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
