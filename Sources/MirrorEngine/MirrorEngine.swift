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

// Image processing for e-ink/greyscale displays.
// macOS font smoothing produces subpixel-antialiased text that looks fuzzy when
// converted to greyscale. Two independent post-processing knobs counteract this:
//   sharpenAmount (0.0-3.0): spatial sharpening via Laplacian kernel
//   contrastAmount (1.0-2.0): linear contrast stretch around midpoint

// Resolution presets matching Daylight DC-1's native 1600x1200 panel.
// Landscape presets are 4:3. Portrait presets are 3:4 (1200x1600 native).
// Cozy variants use HiDPI (2x): macOS renders at half logical points with full backing
// pixels — big UI, full native sharpness. Other presets are non-HiDPI 1:1 pixel modes.
public enum DisplayResolution: String, CaseIterable, Identifiable {
    // Landscape (4:3)
    case cozy        = "800x600"    // HiDPI 2x: 800x600pt → 1600x1200px — large UI, native sharpness
    case comfortable = "1024x768"   // Larger UI, easy on the eyes
    case balanced    = "1280x960"   // Good balance of size and sharpness
    case sharp       = "1600x1200"  // Maximum sharpness, smaller UI (1:1 native)
    // Portrait (3:4)
    case portraitCozy     = "600x800"    // HiDPI 2x: 600x800pt → 1200x1600px — large UI, native sharpness
    case portraitBalanced = "960x1280"   // Good balance of size and sharpness
    case portraitSharp    = "1200x1600"  // Maximum sharpness, smaller UI (1:1 native)

    public var id: String { rawValue }
    /// Pixel dimensions captured by SCStream and sent to the Daylight.
    public var width: UInt {
        switch self {
        case .cozy: 1600; case .comfortable: 1024; case .balanced: 1280; case .sharp: 1600
        case .portraitCozy: 1200; case .portraitBalanced: 960; case .portraitSharp: 1200
        }
    }
    public var height: UInt {
        switch self {
        case .cozy: 1200; case .comfortable: 768; case .balanced: 960; case .sharp: 1200
        case .portraitCozy: 1600; case .portraitBalanced: 1280; case .portraitSharp: 1600
        }
    }
    public var label: String {
        switch self {
        case .cozy: "Cozy"; case .comfortable: "Comfortable"; case .balanced: "Balanced"; case .sharp: "Sharp"
        case .portraitCozy: "Portrait Cozy"; case .portraitBalanced: "Portrait Balanced"; case .portraitSharp: "Portrait Sharp"
        }
    }
    /// Whether the virtual display uses HiDPI (2x) scaling.
    public var isHiDPI: Bool { switch self { case .cozy, .portraitCozy: true; default: false } }
    /// Whether this is a portrait (vertical) orientation preset.
    public var isPortrait: Bool {
        switch self {
        case .portraitCozy, .portraitBalanced, .portraitSharp: true
        default: false
        }
    }
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
    case waitingForDevice
    case starting
    case running
    case stopping
    case error(String)
}

// MARK: - ADB Bridge

struct ADBBridge {
    /// Resolved path to the adb binary. Checks bundled copy first, then PATH.
    private static let resolvedADBPath: String? = {
        // 1. Bundled adb inside the .app bundle (Resources/adb)
        if let bundled = Bundle.main.resourcePath.map({ $0 + "/adb" }),
           FileManager.default.isExecutableFile(atPath: bundled) {
            print("[ADB] Using bundled adb: \(bundled)")
            return bundled
        }
        // 2. Fallback: find adb on PATH (e.g. Homebrew install)
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "adb"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0,
           let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            print("[ADB] Using system adb: \(path)")
            return path
        }
        print("[ADB] No adb binary found (checked bundle + PATH)")
        return nil
    }()

    /// Create a Process configured to run adb with the given arguments.
    private static func makeADBProcess(_ arguments: [String]) -> Process? {
        guard let adbPath = resolvedADBPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = arguments
        return process
    }

    static func isAvailable() -> Bool {
        return resolvedADBPath != nil
    }

    static func connectedDevice() -> String? {
        let pipe = Pipe()
        guard let process = makeADBProcess(["devices"]) else { return nil }
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
        guard let process = makeADBProcess(["reverse", "tcp:\(port)", "tcp:\(port)"]) else { return false }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    @discardableResult
    static func removeReverseTunnel(port: UInt16) -> Bool {
        guard let process = makeADBProcess(["reverse", "--remove", "tcp:\(port)"]) else { return false }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func querySystemSetting(_ setting: String) -> Int? {
        let pipe = Pipe()
        guard let process = makeADBProcess(["shell", "settings", "get", "system", setting]) else { return nil }
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
        guard let process = makeADBProcess(["shell", "settings", "put", "system", setting, "\(value)"]) else { return }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    /// Check if the companion Android app is installed on the connected device.
    static func isAppInstalled() -> Bool {
        let pipe = Pipe()
        guard let process = makeADBProcess(["shell", "pm", "list", "packages", "com.daylight.mirror"]) else { return false }
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.contains("package:com.daylight.mirror")
    }

    /// Install the bundled APK onto the connected device.
    /// Returns nil on success, or an error message on failure.
    static func installBundledAPK() -> String? {
        guard let resourcePath = Bundle.main.resourcePath else {
            return "No resource path in bundle"
        }
        let apkPath = resourcePath + "/app-debug.apk"
        guard FileManager.default.fileExists(atPath: apkPath) else {
            return "No bundled APK found"
        }
        let pipe = Pipe()
        guard let process = makeADBProcess(["install", "-r", apkPath]) else {
            return "ADB not available"
        }
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            return "Install failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        print("[ADB] Installed bundled APK successfully")
        return nil
    }

    /// Launch the Daylight Mirror Android app on the connected device.
    static func launchApp() {
        guard let process = makeADBProcess(["shell", "am", "start", "-n",
                             "com.daylight.mirror/.MirrorActivity"]) else { return }
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

/// Creates a virtual display at the given resolution and mirrors the Mac's built-in
/// display to it. Uses CGVirtualDisplay private API (same as BetterDisplay, DeskPad).
/// With hiDPI=true, macOS renders at 2x — e.g. 1600x1200 pixels at 800x600 logical points.
/// The virtual display disappears when this object is deallocated.
class VirtualDisplayManager {
    let virtualDisplay: CGVirtualDisplay
    let displayID: CGDirectDisplayID
    let width: UInt
    let height: UInt

    init(width: UInt, height: UInt, hiDPI: Bool = false) {
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
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = [
            CGVirtualDisplayMode(width: width, height: height, refreshRate: 60)
        ]

        guard virtualDisplay.apply(settings) else {
            print("WARNING: Failed to apply virtual display settings")
            return
        }
        let modeLabel = hiDPI ? "HiDPI (\(width/2)x\(height/2)pt @ 2x)" : "non-HiDPI"
        print("Virtual display configured: \(width)x\(height) \(modeLabel) @ 60Hz")
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
                    // Add to connections and notify only when truly ready
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
                    } else {
                        print("[TCP] No cached keyframe yet — client will get next broadcast keyframe")
                    }

                    self.receiveLoop(conn)
                case .failed, .cancelled:
                    self.lock.lock()
                    self.connections.removeAll { $0 === conn }
                    let count = self.connections.count
                    self.lock.unlock()
                    self.onClientCountChanged?(count)
                    print("[TCP] Client disconnected (\(state))")
                default: break
                }
            }
            conn.start(queue: self.queue)
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

// MARK: - Compositor Pacer (dirty pixel trick to force frame delivery)

/// Forces the macOS compositor to continuously redraw by toggling a 1x1 pixel
/// window between two nearly-identical colors at 30Hz. Without this, SCStream
/// only delivers ~13fps for mirrored virtual displays because WindowServer
/// considers static content "clean" and skips recompositing.
///
/// The pixel toggles between #000000 and #010000 (1/255 red channel diff) —
/// completely imperceptible on any display, especially e-ink. Positioned at
/// (0, maxY-1) to hide under the menu bar.
///
/// Uses CADisplayLink (macOS 14+) for vsync-aligned timing. The 4x4 dirty
/// region forces WindowServer to recomposite the target display every frame.
///
/// IMPORTANT: The dirty-pixel window must live on the virtual display's
/// NSScreen, not NSScreen.main. If the window is on the built-in display,
/// only that display's compositor sees dirty regions — the virtual display
/// compositor stays idle and SCStream delivers frames at ~13 FPS.
class CompositorPacer {
    private var window: NSWindow?
    private var displayLink: CADisplayLink?
    private var timer: DispatchSourceTimer?
    private var toggle = false
    private let targetDisplayID: CGDirectDisplayID
    private var tickCount: UInt64 = 0

    init(targetDisplayID: CGDirectDisplayID) {
        self.targetDisplayID = targetDisplayID
    }

    func start() {
        DispatchQueue.main.async { [weak self] in
            self?.startOnMain()
        }
    }

    /// Find the NSScreen matching a CGDirectDisplayID.
    private func screenForDisplay(_ displayID: CGDirectDisplayID) -> NSScreen? {
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               screenNumber == displayID {
                return screen
            }
        }
        return nil
    }

    private func startOnMain() {
        // Find the virtual display's NSScreen; fall back to main
        let targetScreen = screenForDisplay(targetDisplayID)
        let screen = targetScreen ?? NSScreen.main
        let onVirtual = targetScreen != nil

        // 4x4 dirty region — above any per-pixel compositing threshold
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 4, height: 4),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.backgroundColor = NSColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Position at top-left corner of the target screen
        if let s = screen {
            window.setFrameOrigin(NSPoint(x: s.frame.minX, y: s.frame.maxY - 4))
        }
        window.orderFrontRegardless()
        self.window = window

        // Use CADisplayLink from the target screen for vsync-aligned ticking.
        // If virtual display has no NSScreen (mirror mode), use a timer at 30Hz.
        if let targetScreen = targetScreen {
            let dl = targetScreen.displayLink(target: self, selector: #selector(tick))
            dl.preferredFrameRateRange = CAFrameRateRange(
                minimum: 30, maximum: 60, preferred: 30
            )
            dl.add(to: .main, forMode: .common)
            self.displayLink = dl
            print("[Pacer] Started on virtual display \(targetDisplayID) (CADisplayLink, 4x4)")
        } else {
            // Fallback: DispatchSourceTimer at ~30Hz
            let t = DispatchSource.makeTimerSource(queue: .main)
            t.schedule(deadline: .now(), repeating: .milliseconds(33))
            t.setEventHandler { [weak self] in
                self?.timerTick()
            }
            t.resume()
            self.timer = t
            print("[Pacer] Started on main screen (timer fallback, 4x4) — virtual display \(targetDisplayID) has no NSScreen")
        }

        print("[Pacer] Target display: \(targetDisplayID), on virtual screen: \(onVirtual)")
    }

    @objc private func tick(_ link: CADisplayLink) {
        performToggle()
    }

    private func timerTick() {
        performToggle()
    }

    private func performToggle() {
        toggle.toggle()
        window?.backgroundColor = toggle
            ? NSColor(red: 0, green: 0, blue: 0, alpha: 1)
            : NSColor(red: 1.0 / 255.0, green: 0, blue: 0, alpha: 1)
        tickCount += 1
        if tickCount % 150 == 0 {
            print("[Pacer] \(tickCount) ticks (~\(tickCount / 30)s)")
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.displayLink?.invalidate()
            self?.displayLink = nil
            self?.timer?.cancel()
            self?.timer = nil
            self?.window?.close()
            self?.window = nil
            print("[Pacer] Compositor pacer stopped")
        }
    }
}

// MARK: - Screen Capture Errors

enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case contentEnumerationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission not granted. Open System Settings > Privacy & Security > Screen Recording and enable Daylight Mirror, then restart the app."
        case .contentEnumerationFailed(let underlying):
            return "Could not access screen content (permission may be pending). Grant Screen Recording in System Settings and retry. (\(underlying.localizedDescription))"
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
    var sharpenTemp: UnsafeMutablePointer<UInt8>?  // Pre-sharpen greyscale buffer
    var contrastLUT: [UInt8] = Array(0...255)       // Precomputed contrast LUT
    var lastContrastAmount: Double = 1.0           // Tracks when to rebuild LUT
    var sharpenAmount: Double = 1.0                // 0=none, 1=mild, 2=strong, 3=max
    var contrastAmount: Double = 1.0               // 1.0=off, >1=enhanced
    var frameWidth: Int = 0
    var frameHeight: Int = 0
    var pixelCount: Int = 0

    var frameCount: Int = 0
    var lastStatTime: Date = Date()
    var convertTimeSum: Double = 0
    var compressTimeSum: Double = 0
    var statFrames: Int = 0
    var lastCompressedSize: Int = 0

    /// Callback: (fps, bandwidthMB, frameSizeKB, totalFrames, greyMs, compressMs)
    var onStats: ((Double, Double, Int, Int, Double, Double) -> Void)?

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
        // Pre-check screen recording permission to avoid opaque SCStream crashes
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureError.permissionDenied
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureError.contentEnumerationFailed(error)
        }

        guard let display = content.displays.first(where: {
            $0.displayID == targetDisplayID
        }) ?? content.displays.first(where: {
            // Match by pixel OR logical dimensions (HiDPI reports logical size)
            ($0.width == expectedWidth && $0.height == expectedHeight) ||
            ($0.width == expectedWidth / 2 && $0.height == expectedHeight / 2)
        }) ?? content.displays.first else {
            print("No display found!")
            return
        }

        // Use expected (pixel) dimensions, not display.width/height which are logical
        // points. For HiDPI, display.width = 800 but we need 1600 actual pixels.
        frameWidth = expectedWidth
        frameHeight = expectedHeight
        pixelCount = frameWidth * frameHeight

        currentGray = .allocate(capacity: pixelCount)
        previousGray = .allocate(capacity: pixelCount)
        deltaBuffer = .allocate(capacity: pixelCount)
        sharpenTemp = .allocate(capacity: pixelCount)
        let maxCompressed = LZ4_compressBound(Int32(pixelCount))
        compressedBuffer = .allocate(capacity: Int(maxCompressed))
        previousGray!.initialize(repeating: 0, count: pixelCount)

        print("Capturing display: \(expectedWidth)x\(expectedHeight) pixels (logical: \(display.width)x\(display.height), ID: \(display.displayID))")

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
        sharpenTemp?.deallocate(); sharpenTemp = nil
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

        var matrix: [Int16] = [29, 150, 77, 0]
        let greyDivisor: Int32 = 256
        var preBias: [Int16] = [0, 0, 0, 0]

        let sharpAmt = sharpenAmount
        let contrastAmt = contrastAmount

        if sharpAmt > 0.01 {
            // Greyscale → sharpenTemp, then Laplacian convolve → currentGray
            // Kernel: [0, -a, 0; -a, 1+4a, -a; 0, -a, 0] with divisor to allow fractional a.
            // Use divisor=4 for 0.25 step granularity.
            var preSharpenBuffer = vImage_Buffer(
                data: sharpenTemp!, height: vImagePixelCount(frameHeight),
                width: vImagePixelCount(frameWidth), rowBytes: frameWidth
            )
            vImageMatrixMultiply_ARGB8888ToPlanar8(
                &srcBuffer, &preSharpenBuffer, &matrix, greyDivisor, &preBias, 0,
                vImage_Flags(kvImageNoFlags)
            )
            var dstBuffer = vImage_Buffer(
                data: currentGray!, height: vImagePixelCount(frameHeight),
                width: vImagePixelCount(frameWidth), rowBytes: frameWidth
            )
            let a = Int16(sharpAmt * 4)  // scale by divisor=4
            let center = 4 + 4 * a       // (1 + 4*amount) * divisor = 4 + 4*a
            var kernel: [Int16] = [0, -a, 0, -a, center, -a, 0, -a, 0]
            vImageConvolve_Planar8(
                &preSharpenBuffer, &dstBuffer, nil, 0, 0,
                &kernel, 3, 3, 4, 0, vImage_Flags(kvImageEdgeExtend)
            )
        } else {
            // No sharpening — greyscale directly into currentGray
            var dstBuffer = vImage_Buffer(
                data: currentGray!, height: vImagePixelCount(frameHeight),
                width: vImagePixelCount(frameWidth), rowBytes: frameWidth
            )
            vImageMatrixMultiply_ARGB8888ToPlanar8(
                &srcBuffer, &dstBuffer, &matrix, greyDivisor, &preBias, 0,
                vImage_Flags(kvImageNoFlags)
            )
        }

        // Contrast enhancement (independent of sharpening).
        // LUT rebuilt lazily on capture thread to avoid data race with main thread.
        if contrastAmt > 1.01 {
            if contrastAmt != lastContrastAmount {
                contrastLUT = (0..<256).map { i in
                    UInt8(max(0, min(255, Int(128.0 + contrastAmt * (Double(i) - 128.0)))))
                }
                lastContrastAmount = contrastAmt
            }
            let lut = contrastLUT
            for i in 0..<pixelCount { currentGray![i] = lut[Int(currentGray![i])] }
        }

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
            onStats?(fps, bw, lastCompressedSize / 1024, frameCount, avgConvert, avgCompress)

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

// MARK: - Control Socket (IPC for CLI commands to the running engine)

/// Unix domain socket server at /tmp/daylight-mirror.sock for CLI control.
/// Accepts newline-terminated text commands, dispatches to MirrorEngine on the
/// main queue, returns a response, and closes. Runs inside whichever process
/// owns the engine (GUI app or CLI daemon).
public class ControlSocket {
    public static let socketPath = "/tmp/daylight-mirror.sock"

    private let engine: MirrorEngine
    private var fd: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    public init(engine: MirrorEngine) {
        self.engine = engine
    }

    public func start() {
        // Clean up stale socket from previous crash
        unlink(Self.socketPath)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { print("[Socket] Failed to create socket"); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLen = MemoryLayout.size(ofValue: addr.sun_path)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            Self.socketPath.withCString { src in
                memcpy(ptr, src, min(strlen(src) + 1, pathLen))
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            print("[Socket] Failed to bind: \(String(cString: strerror(errno)))")
            close(fd); fd = -1; return
        }

        guard listen(fd, 5) == 0 else {
            print("[Socket] Failed to listen: \(String(cString: strerror(errno)))")
            close(fd); fd = -1; return
        }

        // Async accept via GCD — same pattern as DispatchSource signal handlers
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            unlink(Self.socketPath)
        }
        source.resume()
        acceptSource = source

        print("[Socket] Control socket listening at \(Self.socketPath)")
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        fd = -1
    }

    private func acceptConnection() {
        let clientFD = accept(fd, nil, nil)
        guard clientFD >= 0 else { return }

        // Read one newline-terminated command (up to 256 bytes)
        var buffer = [CChar](repeating: 0, count: 256)
        let bytesRead = recv(clientFD, &buffer, buffer.count - 1, 0)
        guard bytesRead > 0 else { close(clientFD); return }

        let rawCommand = String(cString: buffer)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Dispatch to main queue where the engine lives (@MainActor)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { close(clientFD); return }
            let response = self.handleCommand(rawCommand)
            _ = (response + "\n").withCString { ptr in
                send(clientFD, ptr, strlen(ptr), 0)
            }
            close(clientFD)
        }
    }

    /// Parse and execute a control command. Returns the response string.
    private func handleCommand(_ raw: String) -> String {
        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts.first?.uppercased() ?? ""
        let arg = parts.count > 1 ? parts[1] : nil

        switch verb {
        case "BRIGHTNESS":
            if let arg = arg, let value = Int(arg) {
                let clamped = max(0, min(255, value))
                engine.setBrightness(clamped)
                return "OK \(clamped)"
            } else {
                return "OK \(engine.brightness)"
            }

        case "WARMTH":
            if let arg = arg, let value = Int(arg) {
                let clamped = max(0, min(255, value))
                engine.setWarmth(clamped)
                return "OK \(clamped)"
            } else {
                return "OK \(engine.warmth)"
            }

        case "BACKLIGHT":
            let action = arg?.lowercased() ?? ""
            switch action {
            case "on":
                if !engine.backlightOn { engine.toggleBacklight() }
                return "OK on"
            case "off":
                if engine.backlightOn { engine.toggleBacklight() }
                return "OK off"
            case "toggle":
                engine.toggleBacklight()
                return "OK \(engine.backlightOn ? "on" : "off")"
            default:
                return "OK \(engine.backlightOn ? "on" : "off")"
            }

        case "RESOLUTION":
            if let arg = arg {
                // Accept preset names ("sharp", "portrait-cozy"), raw values ("1600x1200"),
                // and hyphenated/spaced variants of multi-word labels.
                let normalizedArg = arg.lowercased().replacingOccurrences(of: "-", with: " ")
                let preset = DisplayResolution.allCases.first {
                    $0.rawValue == arg || $0.label.lowercased() == normalizedArg
                }
                guard let newRes = preset else {
                    let valid = DisplayResolution.allCases.map { $0.label.lowercased().replacingOccurrences(of: " ", with: "-") }.joined(separator: ", ")
                    return "ERR unknown resolution (valid: \(valid))"
                }
                if newRes == engine.resolution {
                    return "OK \(newRes.label.lowercased()) (no change)"
                }
                engine.resolution = newRes
                // Auto-restart if running, matching GUI behavior
                if engine.status == .running {
                    engine.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        Task { @MainActor in await self.engine.start() }
                    }
                    return "OK \(newRes.label.lowercased()) (restarting)"
                }
                return "OK \(newRes.label.lowercased())"
            } else {
                return "OK \(engine.resolution.label.lowercased())"
            }

        case "RESTART":
            if engine.status == .running {
                engine.stop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    Task { @MainActor in await self.engine.start() }
                }
                return "OK restarting"
            } else {
                return "ERR not running"
            }

        case "START":
            if engine.status == .running {
                return "OK already running"
            }
            if engine.status == .starting {
                return "OK already starting"
            }
            Task { @MainActor in await self.engine.start() }
            return "OK starting"

        case "STOP":
            if engine.status == .idle {
                return "OK already idle"
            }
            engine.stop()
            return "OK stopping"

        case "STATUS":
            let s: String
            switch engine.status {
            case .idle: s = "idle"
            case .waitingForDevice: s = "waiting_for_device"
            case .starting: s = "starting"
            case .running: s = "running"
            case .stopping: s = "stopping"
            case .error(let msg): s = "error: \(msg)"
            }
            return "OK \(s)"

        case "RECONNECT":
            if engine.status == .running {
                engine.reconnect()
                return "OK reconnecting"
            } else {
                return "ERR not running"
            }

        case "SHARPEN":
            if let arg = parts.dropFirst().first {
                guard let val = Double(arg), val >= 0, val <= 3.0 else {
                    return "ERR value must be 0.0-3.0 (0=none, 1=mild, 2=strong)"
                }
                engine.sharpenAmount = val
                return "OK \(String(format: "%.1f", val))"
            } else {
                return "OK \(String(format: "%.1f", engine.sharpenAmount))"
            }

        case "CONTRAST":
            if let arg = parts.dropFirst().first {
                guard let val = Double(arg), val >= 1.0, val <= 2.0 else {
                    return "ERR value must be 1.0-2.0 (1.0=off, 1.5=moderate, 2.0=high)"
                }
                engine.contrastAmount = val
                return "OK \(String(format: "%.1f", val))"
            } else {
                return "OK \(String(format: "%.1f", engine.contrastAmount))"
            }

        case "FONTSMOOTHING":
            if let arg = parts.dropFirst().first?.lowercased() {
                switch arg {
                case "on":
                    engine.setFontSmoothing(enabled: true)
                    engine.fontSmoothingDisabled = false
                    return "OK on"
                case "off":
                    engine.setFontSmoothing(enabled: false)
                    engine.fontSmoothingDisabled = true
                    return "OK off"
                default:
                    return "ERR use on or off"
                }
            } else {
                return "OK \(engine.fontSmoothingDisabled ? "off" : "on")"
            }

        default:
            return "ERR unknown command"
        }
    }
}

// MARK: - USB Device Monitor (ADB polling)

/// Polls `adb devices` every 2 seconds to detect USB connect/disconnect.
/// Calls onDeviceConnected/onDeviceDisconnected on the main queue when state changes.
class USBDeviceMonitor {
    private var timer: DispatchSourceTimer?
    private var wasConnected = false
    var onDeviceConnected: (() -> Void)?
    var onDeviceDisconnected: (() -> Void)?

    func start() {
        guard ADBBridge.isAvailable() else {
            print("[USB] No adb available — device monitoring disabled")
            return
        }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: .seconds(2))
        t.setEventHandler { [weak self] in
            guard let self = self else { return }
            let connected = ADBBridge.connectedDevice() != nil
            if connected && !self.wasConnected {
                self.wasConnected = true
                print("[USB] Device connected")
                DispatchQueue.main.async { self.onDeviceConnected?() }
            } else if !connected && self.wasConnected {
                self.wasConnected = false
                print("[USB] Device disconnected")
                DispatchQueue.main.async { self.onDeviceDisconnected?() }
            }
        }
        t.resume()
        timer = t
        print("[USB] Device monitoring started (polling adb every 2s)")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    var isDeviceConnected: Bool { wasConnected }
}

// MARK: - Mirror Engine

public class MirrorEngine: ObservableObject {
    // RELEASE: Bump this BEFORE creating a GitHub release. Also upload both
    // DaylightMirror-vX.Y.dmg (versioned) and DaylightMirror.dmg (stable name for Gumroad link)
    // to the release. Update Homebrew cask in welfvh/homebrew-tap with new version + sha256.
    public static let appVersion = "1.3.0"

    @Published public var status: MirrorStatus = .idle
    @Published public var fps: Double = 0
    @Published public var bandwidth: Double = 0
    @Published public var brightness: Int = 128
    @Published public var warmth: Int = 128
    @Published public var backlightOn: Bool = true
    @Published public var adbConnected: Bool = false
    @Published public var apkInstallStatus: String = ""  // Empty = idle, "Installing..." = in progress, "Installed" = done, or error
    @Published public var clientCount: Int = 0
    @Published public var totalFrames: Int = 0
    @Published public var frameSizeKB: Int = 0
    @Published public var greyMs: Double = 0      // Greyscale + sharpen time per frame
    @Published public var compressMs: Double = 0   // LZ4 delta compress time per frame
    @Published public var sharpenAmount: Double = 1.0 {
        didSet {
            capture?.sharpenAmount = sharpenAmount
            UserDefaults.standard.set(sharpenAmount, forKey: "sharpenAmount")
        }
    }
    @Published public var contrastAmount: Double = 1.0 {
        didSet {
            capture?.contrastAmount = contrastAmount
            UserDefaults.standard.set(contrastAmount, forKey: "contrastAmount")
        }
    }
    @Published public var fontSmoothingDisabled: Bool = false
    @Published public var deviceDetected: Bool = false
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
    private var compositorPacer: CompositorPacer?
    private var controlSocket: ControlSocket?
    private var usbMonitor: USBDeviceMonitor?
    private var savedMacBrightness: Float?   // Mac brightness before auto-dim
    /// When true, auto-start/stop mirroring based on USB device state.
    @Published public var autoMirrorEnabled: Bool = true {
        didSet { UserDefaults.standard.set(autoMirrorEnabled, forKey: "autoMirrorEnabled") }
    }

    public init() {
        let saved = UserDefaults.standard.string(forKey: "resolution") ?? ""
        self.resolution = DisplayResolution(rawValue: saved) ?? .comfortable
        let savedSharpen = UserDefaults.standard.double(forKey: "sharpenAmount")
        self.sharpenAmount = savedSharpen > 0 ? savedSharpen : 1.0
        let savedContrast = UserDefaults.standard.double(forKey: "contrastAmount")
        self.contrastAmount = savedContrast > 0 ? savedContrast : 1.0
        if UserDefaults.standard.object(forKey: "autoMirrorEnabled") != nil {
            self.autoMirrorEnabled = UserDefaults.standard.bool(forKey: "autoMirrorEnabled")
        }
        NSLog("[MirrorEngine] init, resolution: %@, sharpen: %.1f, contrast: %.1f",
              resolution.rawValue, sharpenAmount, contrastAmount)

        // Control socket — always listening so CLI can send START/STOP/etc.
        // Started after init completes (self is fully initialized).
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let sock = ControlSocket(engine: self)
            sock.start()
            self.controlSocket = sock
        }

        // USB device monitoring — auto-detect DC-1 connect/disconnect
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let monitor = USBDeviceMonitor()
            monitor.onDeviceConnected = { [weak self] in
                guard let self = self else { return }
                self.deviceDetected = true
                if self.autoMirrorEnabled && self.status == .idle {
                    NSLog("[USB] Device connected — auto-starting mirror")
                    Task { @MainActor in await self.start() }
                } else if self.autoMirrorEnabled && self.status == .waitingForDevice {
                    NSLog("[USB] Device connected — starting mirror")
                    self.status = .idle  // Reset from waiting state
                    Task { @MainActor in await self.start() }
                } else if self.status == .running {
                    NSLog("[USB] Device reconnected — re-establishing tunnel")
                    self.reconnect()
                }
            }
            monitor.onDeviceDisconnected = { [weak self] in
                guard let self = self else { return }
                self.deviceDetected = false
                if self.autoMirrorEnabled && self.status == .running {
                    NSLog("[USB] Device disconnected — stopping mirror")
                    self.stop()
                    self.status = .waitingForDevice
                }
            }
            monitor.start()
            self.usbMonitor = monitor
            // Set initial device state
            self.deviceDetected = monitor.isDeviceConnected
        }

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
            } else if self.status == .idle || self.status == .waitingForDevice {
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

        // Disable font smoothing for cleaner greyscale rendering on e-ink
        if fontSmoothingDisabled {
            setFontSmoothing(enabled: false)
        }

        // Check Screen Recording permission before attempting capture
        if !Self.hasScreenRecordingPermission() {
            Self.requestScreenRecordingPermission()
            status = .error("Grant Screen Recording permission in System Settings, then retry")
            return
        }

        status = .starting

        // 1. Check for ADB device (but don't set up tunnel yet — server must be listening first)
        let hasADBDevice = ADBBridge.isAvailable() && ADBBridge.connectedDevice() != nil
        if hasADBDevice {
            print("ADB device: \(ADBBridge.connectedDevice()!)")
        } else {
            print("No ADB device (mirror will wait for TCP connection)")
        }

        // 2. Virtual display at selected resolution
        let w = resolution.width
        let h = resolution.height
        displayManager = VirtualDisplayManager(width: w, height: h, hiDPI: resolution.isHiDPI)
        try? await Task.sleep(for: .seconds(1))

        // 3. Mirroring
        displayManager?.mirrorBuiltInDisplay()
        try? await Task.sleep(for: .seconds(1))

        // 3b. Compositor pacer — forces SCStream to deliver 30fps instead of ~13fps.
        // Dirty-pixel window must be on the VIRTUAL display's screen to trigger its compositor.
        let pacer = CompositorPacer(targetDisplayID: displayManager!.displayID)
        pacer.start()
        compositorPacer = pacer

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

        // 4b. ADB tunnel + auto-install APK + launch (AFTER server is listening)
        if hasADBDevice {
            // Auto-install bundled APK if the companion app isn't on the device yet
            if !ADBBridge.isAppInstalled() {
                apkInstallStatus = "Installing companion app..."
                print("[ADB] Companion app not found, installing bundled APK...")
                if let error = ADBBridge.installBundledAPK() {
                    apkInstallStatus = "APK install failed: \(error)"
                    print("[ADB] APK install error: \(error)")
                } else {
                    apkInstallStatus = "Installed"
                    print("[ADB] Companion app installed")
                }
            }

            let tunnelOK = ADBBridge.setupReverseTunnel(port: TCP_PORT)
            if tunnelOK {
                print("[ADB] Reverse tunnel tcp:\(TCP_PORT) established")
                ADBBridge.launchApp()
                adbConnected = true
                apkInstallStatus = ""  // Clear status on success
            } else {
                print("[ADB] WARNING: Reverse tunnel failed — DC-1 cannot reach Mac on port \(TCP_PORT)")
                adbConnected = false
            }
        } else {
            adbConnected = false
        }

        // 5. Capture
        let cap = ScreenCapture(
            tcpServer: tcpServer!, wsServer: wsServer!,
            targetDisplayID: displayManager!.displayID,
            width: Int(w), height: Int(h)
        )
        cap.sharpenAmount = sharpenAmount
        cap.contrastAmount = contrastAmount
        cap.onStats = { [weak self] fps, bw, frameKB, total, grey, compress in
            DispatchQueue.main.async {
                self?.fps = fps
                self?.bandwidth = bw
                self?.totalFrames = total
                self?.frameSizeKB = frameKB
                self?.greyMs = grey
                self?.compressMs = compress
            }
        }
        capture = cap

        do {
            try await cap.start()
        } catch let error as ScreenCaptureError {
            status = .error(error.localizedDescription)
            compositorPacer?.stop(); compositorPacer = nil
            tcpServer?.stop(); wsServer?.stop(); httpServer?.stop()
            tcpServer = nil; wsServer = nil; httpServer = nil
            displayManager = nil
            return
        } catch {
            status = .error("Capture failed: \(error.localizedDescription)")
            compositorPacer?.stop(); compositorPacer = nil
            tcpServer?.stop(); wsServer?.stop(); httpServer?.stop()
            tcpServer = nil; wsServer = nil; httpServer = nil
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
        guard status == .running || status == .waitingForDevice else { return }
        if status == .waitingForDevice { status = .idle; return }
        DispatchQueue.main.async { self.status = .stopping }

        // Restore Mac brightness before tearing down
        if let saved = savedMacBrightness {
            MacBrightness.set(saved)
            savedMacBrightness = nil
            print("[Mac] Brightness restored to \(saved)")
        }

        Task {
            // Stop in reverse order (control socket stays alive — it's engine-lifetime)
            displayController?.stop()
            displayController = nil

            compositorPacer?.stop()
            compositorPacer = nil

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

            // Restore font smoothing when mirror stops
            if self.fontSmoothingDisabled {
                self.setFontSmoothing(enabled: true)
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
            let tunnelOK = ADBBridge.setupReverseTunnel(port: TCP_PORT)
            if tunnelOK {
                print("[ADB] Reverse tunnel re-established")
                ADBBridge.launchApp()
                await MainActor.run { self.adbConnected = true }
                print("[MirrorEngine] Reconnect done — tunnel + app relaunched")
            } else {
                print("[ADB] WARNING: Reverse tunnel failed on reconnect")
                await MainActor.run { self.adbConnected = false }
            }
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

    /// Disable macOS font smoothing (subpixel AA). Dramatically improves text clarity
    /// on greyscale displays like the Daylight DC-1. Restored when mirror stops.
    public func setFontSmoothing(enabled: Bool) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        if enabled {
            task.arguments = ["delete", "-g", "AppleFontSmoothing"]
        } else {
            task.arguments = ["write", "-g", "AppleFontSmoothing", "-int", "0"]
        }
        try? task.run()
        task.waitUntilExit()
        fontSmoothingDisabled = !enabled
        print("[Engine] Font smoothing \(enabled ? "enabled" : "disabled")")
    }
}
