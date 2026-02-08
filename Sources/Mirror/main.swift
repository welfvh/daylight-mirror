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

// MARK: - Configuration

let PORT: UInt16 = 8888          // Raw TCP for native app
let WS_PORT: UInt16 = 8890      // WebSocket for Chrome fallback
let HTTP_PORT: UInt16 = 8891    // HTML page for Chrome fallback
let TARGET_FPS: Int = 30
let JPEG_QUALITY: CGFloat = 0.8 // For WebSocket fallback only
let KEYFRAME_INTERVAL: Int = 30 // Send a full keyframe every N frames

// Protocol constants
let MAGIC: [UInt8] = [0xDA, 0x7E]
let FLAG_KEYFRAME: UInt8 = 0x01

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
        header.append(contentsOf: MAGIC)
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

    init(tcpServer: TCPServer, wsServer: WebSocketServer) {
        self.tcpServer = tcpServer
        self.wsServer = wsServer
        self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
        super.init()
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let display = content.displays.first(where: {
            $0.width == 1280 || $0.width == 1600
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

let tcpServer = try TCPServer(port: PORT)
tcpServer.start()

let wsServer = try WebSocketServer(port: WS_PORT)
wsServer.start()

let httpServer = try HTTPServer(port: HTTP_PORT)
httpServer.start()

let capture = ScreenCapture(tcpServer: tcpServer, wsServer: wsServer)

Task {
    do {
        try await capture.start()
    } catch {
        print("Capture error: \(error)")
    }
}

print("Daylight Mirror v4 — vImage + LZ4 delta, zero GPU")
print("Native TCP:  tcp://localhost:\(PORT)")
print("WS fallback: ws://localhost:\(WS_PORT)")
print("HTML page:   http://localhost:\(HTTP_PORT)")

RunLoop.main.run()
