// ScreenCapture.swift — CPU-only screen capture with vImage SIMD + LZ4 delta.
//
// Captures the virtual display via CGDisplayStream (loaded at runtime via dlsym
// to bypass macOS 15 SDK deprecation), converts BGRA to greyscale using vImage
// SIMD, optionally sharpens with Laplacian convolution, applies contrast LUT,
// then LZ4 compresses (keyframe or XOR delta). Zero GPU usage.

import Foundation
import Darwin
import IOSurface
import CoreImage
import QuartzCore
import Accelerate
import CLZ4

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

// MARK: - CGDisplayStream dlsym types

// CGDisplayStream C functions are deprecated in macOS 15 SDK but still exist at
// runtime. We load them via dlsym to avoid compile-time deprecation errors.
private typealias CGDisplayStreamCreateFn = @convention(c) (
    UInt32, Int, Int, Int32, CFDictionary?, DispatchQueue,
    @escaping @convention(block) (Int32, UInt64, IOSurfaceRef?, OpaquePointer?) -> Void
) -> OpaquePointer?
private typealias CGDisplayStreamStartFn = @convention(c) (OpaquePointer) -> Int32
private typealias CGDisplayStreamStopFn = @convention(c) (OpaquePointer) -> Int32

// MARK: - Screen Capture

class ScreenCapture: NSObject {
    let tcpServer: TCPServer
    let wsServer: WebSocketServer
    let ciContext: CIContext
    let targetDisplayID: CGDirectDisplayID

    // CGDisplayStream runtime handles
    private var cgHandle: UnsafeMutableRawPointer?       // dlopen handle
    private var displayStream: OpaquePointer?            // retained stream ref

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
    var frameSequence: UInt32 = 0
    var skippedFrames: Int = 0
    var forceNextKeyframe: Bool = false
    var lastStatTime: Date = Date()
    var convertTimeSum: Double = 0
    var compressTimeSum: Double = 0
    var statFrames: Int = 0
    var lastCompressedSize: Int = 0

    // Jitter tracking: measures interval variance between callbacks
    var lastCallbackTime: Double = 0
    var jitterSamples: [Double] = []
    let jitterWindowSize = 150

    /// Callback: (fps, bandwidthMB, frameSizeKB, totalFrames, greyMs, compressMs, jitterMs)
    var onStats: ((Double, Double, Int, Int, Double, Double, Double, Int) -> Void)?

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
        // Pre-check screen recording permission
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureError.permissionDenied
        }

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

        print("Capturing display: \(expectedWidth)x\(expectedHeight) pixels (ID: \(targetDisplayID))")

        // Load CGDisplayStream functions via dlsym
        guard let cg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else {
            throw ScreenCaptureError.contentEnumerationFailed(
                NSError(domain: "ScreenCapture", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to dlopen CoreGraphics"]))
        }
        cgHandle = cg

        guard let createSym = dlsym(cg, "CGDisplayStreamCreateWithDispatchQueue"),
              let startSym = dlsym(cg, "CGDisplayStreamStart"),
              let stopSym = dlsym(cg, "CGDisplayStreamStop") else {
            throw ScreenCaptureError.contentEnumerationFailed(
                NSError(domain: "ScreenCapture", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to resolve CGDisplayStream symbols"]))
        }
        // Suppress unused variable warning — stopSym is resolved here to fail fast,
        // but the actual stop function is loaded again in stop() for lifetime safety.
        _ = stopSym

        let createFn = unsafeBitCast(createSym, to: CGDisplayStreamCreateFn.self)
        let startFn = unsafeBitCast(startSym, to: CGDisplayStreamStartFn.self)

        // CGDisplayStream configuration
        let properties: NSDictionary = [
            "kCGDisplayStreamMinimumFrameTime": NSNumber(value: 1.0 / Double(TARGET_FPS)),
            "kCGDisplayStreamShowCursor": kCFBooleanTrue as Any
        ]

        let captureQueue = DispatchQueue(label: "capture", qos: .userInteractive)
        let pixelFormat: Int32 = 1111970369  // kCVPixelFormatType_32BGRA (0x42475241)

        // Create the display stream
        guard let stream = createFn(
            targetDisplayID,
            frameWidth,
            frameHeight,
            pixelFormat,
            properties as CFDictionary,
            captureQueue,
            { [weak self] (status: Int32, _: UInt64, surface: IOSurfaceRef?, _: OpaquePointer?) in
                self?.handleFrame(status: status, surface: surface)
            }
        ) else {
            throw ScreenCaptureError.contentEnumerationFailed(
                NSError(domain: "ScreenCapture", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "CGDisplayStreamCreateWithDispatchQueue returned nil"]))
        }

        // Retain the stream reference — without this it gets deallocated
        displayStream = stream
        let cfStream = Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(stream))
        _ = cfStream.retain()

        // Start capture
        let result = startFn(stream)
        guard result == 0 else {
            throw ScreenCaptureError.contentEnumerationFailed(
                NSError(domain: "ScreenCapture", code: Int(result),
                        userInfo: [NSLocalizedDescriptionKey: "CGDisplayStreamStart failed with code \(result)"]))
        }

        lastStatTime = Date()
        print("Capture started at \(TARGET_FPS)fps -- CGDisplayStream + vImage + LZ4 delta (zero GPU)")
    }

    func stop() async {
        if let stream = displayStream {
            // Load stop function
            if let cg = cgHandle, let stopSym = dlsym(cg, "CGDisplayStreamStop") {
                let stopFn = unsafeBitCast(stopSym, to: CGDisplayStreamStopFn.self)
                _ = stopFn(stream)
            }
            // Release the retained CFTypeRef
            let cfStream = Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(stream))
            cfStream.release()
            displayStream = nil
        }
        if let cg = cgHandle {
            dlclose(cg)
            cgHandle = nil
        }
        currentGray?.deallocate(); currentGray = nil
        previousGray?.deallocate(); previousGray = nil
        deltaBuffer?.deallocate(); deltaBuffer = nil
        sharpenTemp?.deallocate(); sharpenTemp = nil
        compressedBuffer?.deallocate(); compressedBuffer = nil
    }

    // MARK: - Frame callback

    private func handleFrame(status: Int32, surface: IOSurfaceRef?) {
        // Status codes:
        // 0 = FrameComplete, 1 = FrameIdle, 2 = FrameBlank, 3 = Stopped
        guard status == 0, let surface = surface else { return }

        let t0 = CACurrentMediaTime()

        if lastCallbackTime > 0 {
            let interval = (t0 - lastCallbackTime) * 1000.0
            let expectedInterval = 1000.0 / Double(TARGET_FPS)
            let jitter = abs(interval - expectedInterval)
            jitterSamples.append(jitter)
            if jitterSamples.count > jitterWindowSize {
                jitterSamples.removeFirst(jitterSamples.count - jitterWindowSize)
            }
        }
        lastCallbackTime = t0

        IOSurfaceLock(surface, .readOnly, nil)
        let baseAddress = IOSurfaceGetBaseAddress(surface)
        let rowBytes = IOSurfaceGetBytesPerRow(surface)

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

        // Drop frames when Android can't keep up — send only the latest
        let inflight = tcpServer.inflightFrames
        let isScheduledKeyframe = (frameCount % KEYFRAME_INTERVAL == 0)

        let rtt = tcpServer.latencyStats?.rttAvgMs ?? 15.0
        let adaptiveThreshold = max(2, min(6, Int(120.0 / max(rtt, 1.0))))
        if inflight > adaptiveThreshold && !isScheduledKeyframe {
            skippedFrames += 1
            forceNextKeyframe = true
            // Still swap buffers so currentGray stays fresh for next delta base
            let temp = previousGray
            previousGray = currentGray
            currentGray = temp

            IOSurfaceUnlock(surface, .readOnly, nil)
            frameCount += 1
            return
        }

        let isKeyframe = isScheduledKeyframe || forceNextKeyframe
        if forceNextKeyframe { forceNextKeyframe = false }
        let seq = frameSequence
        frameSequence &+= 1

        if isKeyframe {
            let compressedSize = LZ4_compress_default(
                currentGray!, compressedBuffer!, Int32(pixelCount),
                LZ4_compressBound(Int32(pixelCount))
            )
            let payload = Data(bytes: compressedBuffer!, count: Int(compressedSize))
            tcpServer.broadcast(payload: payload, isKeyframe: true, sequenceNumber: seq)
            lastCompressedSize = Int(compressedSize)
        } else {
            for i in 0..<pixelCount {
                deltaBuffer![i] = currentGray![i] ^ previousGray![i]
            }
            let compressedSize = LZ4_compress_default(
                deltaBuffer!, compressedBuffer!, Int32(pixelCount),
                LZ4_compressBound(Int32(pixelCount))
            )
            // Skip trivial deltas — screen barely changed, Android already has the frame
            if compressedSize < 512 {
                skippedFrames += 1
                frameSequence &-= 1  // reclaim sequence number
            } else {
                let payload = Data(bytes: compressedBuffer!, count: Int(compressedSize))
                tcpServer.broadcast(payload: payload, isKeyframe: false, sequenceNumber: seq)
            }
            lastCompressedSize = Int(compressedSize)
        }

        let temp = previousGray
        previousGray = currentGray
        currentGray = temp

        let t2 = CACurrentMediaTime()

        if wsServer.hasClients {
            let ciImage = CIImage(ioSurface: unsafeBitCast(surface, to: IOSurface.self))
            let grayImage = ciImage.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
            if let jpegData = ciContext.jpegRepresentation(
                of: grayImage,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: JPEG_QUALITY]
            ) {
                wsServer.broadcast(jpegData)
            }
        }

        IOSurfaceUnlock(surface, .readOnly, nil)

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
            let avgJitter = jitterSamples.isEmpty ? 0.0 : jitterSamples.reduce(0, +) / Double(jitterSamples.count)

            print(String(format: "FPS: %.1f | gray: %.1fms | lz4+delta: %.1fms | jitter: %.1fms | frame: %dKB | ~%.1fMB/s | total: %d | skipped: %d",
                         fps, avgConvert, avgCompress, avgJitter, lastCompressedSize / 1024, bw, frameCount, skippedFrames))
            onStats?(fps, bw, lastCompressedSize / 1024, frameCount, avgConvert, avgCompress, avgJitter, skippedFrames)

            statFrames = 0
            convertTimeSum = 0
            compressTimeSum = 0
            lastStatTime = now
        }
    }
}
