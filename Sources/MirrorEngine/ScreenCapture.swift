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

func adaptiveBackpressureThreshold(rttMs: Double) -> Int {
    max(2, min(6, Int(120.0 / max(rttMs, 1.0))))
}

let TRIVIAL_DELTA_THRESHOLD = 512

// MARK: - Screen Capture

class ScreenCapture: NSObject {
    let tcpServer: TCPServer
    let wsServer: WebSocketServer?
    let ciContext: CIContext
    let targetDisplayID: CGDirectDisplayID

    // CGDisplayStream runtime handles
    private var cgHandle: UnsafeMutableRawPointer?       // dlopen handle
    private(set) var displayStream: OpaquePointer?         // retained stream ref

    // EXPERIMENT: Send raw BGRA (4 bytes/pixel) instead of greyscale (1 byte/pixel).
    // Hypothesis: Mac-side greyscale conversion loses pixel richness that the DC-1's
    // RLCD panel could render better if the GPU shader handles luminance conversion.
    var currentFrame: UnsafeMutablePointer<UInt8>?
    var previousFrame: UnsafeMutablePointer<UInt8>?
    var deltaBuffer: UnsafeMutablePointer<UInt8>?
    var compressedBuffer: UnsafeMutablePointer<CChar>?
    var frameBufferSize: Int = 0  // pixelCount * 4 (BGRA)
    /// Atomic flag to prevent handleFrame() from accessing deallocated buffers during stop().
    /// Set before CGDisplayStreamStop, checked at top of handleFrame().
    private var isStopped: Bool = false
    private let stoppedLock = NSLock()
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

    init(tcpServer: TCPServer, wsServer: WebSocketServer?, targetDisplayID: CGDirectDisplayID, width: Int, height: Int) {
        self.tcpServer = tcpServer
        self.wsServer = wsServer
        self.targetDisplayID = targetDisplayID
        self.expectedWidth = width
        self.expectedHeight = height
        self.ciContext = CIContext(options: [.useSoftwareRenderer: false])
        super.init()
    }

    func start() async throws {
        isStopped = false

        // Pre-check screen recording permission
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureError.permissionDenied
        }

        frameWidth = expectedWidth
        frameHeight = expectedHeight
        pixelCount = frameWidth * frameHeight
        frameBufferSize = pixelCount * 4  // BGRA: 4 bytes per pixel

        currentFrame = .allocate(capacity: frameBufferSize)
        previousFrame = .allocate(capacity: frameBufferSize)
        deltaBuffer = .allocate(capacity: frameBufferSize)
        let maxCompressed = LZ4_compressBound(Int32(frameBufferSize))
        compressedBuffer = .allocate(capacity: Int(maxCompressed))
        previousFrame!.initialize(repeating: 0, count: frameBufferSize)

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
        // Set stopped flag BEFORE stopping the stream — prevents in-flight
        // handleFrame() callbacks from accessing buffers we're about to deallocate.
        stoppedLock.lock()
        isStopped = true
        stoppedLock.unlock()

        stopStream()
        // Let any in-flight callbacks on captureQueue drain before releasing
        try? await Task.sleep(for: .milliseconds(100))
        releaseStream()

        if let cg = cgHandle {
            dlclose(cg)
            cgHandle = nil
        }
        currentFrame?.deallocate(); currentFrame = nil
        previousFrame?.deallocate(); previousFrame = nil
        deltaBuffer?.deallocate(); deltaBuffer = nil
        compressedBuffer?.deallocate(); compressedBuffer = nil
    }

    /// Stop the CGDisplayStream without releasing buffers.
    private func stopStream() {
        guard let stream = displayStream else { return }
        if let cg = cgHandle, let stopSym = dlsym(cg, "CGDisplayStreamStop") {
            let stopFn = unsafeBitCast(stopSym, to: CGDisplayStreamStopFn.self)
            _ = stopFn(stream)
        }
    }

    /// Release the retained CGDisplayStream CFTypeRef.
    private func releaseStream() {
        guard let stream = displayStream else { return }
        let cfStream = Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(stream))
        cfStream.release()
        displayStream = nil
    }

    /// Restart the CGDisplayStream after a display sleep/wake cycle (clamshell mode).
    /// Tears down the old stream and creates a new one targeting the same display,
    /// keeping all buffers and state intact. Forces a keyframe on the next frame.
    func restartStream() async {
        NSLog("[Capture] Restarting CGDisplayStream for display %d...", targetDisplayID)

        // Stop old stream
        stoppedLock.lock()
        isStopped = true
        stoppedLock.unlock()

        stopStream()
        try? await Task.sleep(for: .milliseconds(200))
        releaseStream()

        // Reset frame state for clean restart
        stoppedLock.lock()
        isStopped = false
        stoppedLock.unlock()
        forceNextKeyframe = true
        frameCount = 0
        lastCallbackTime = 0

        // Re-create stream using existing cgHandle (CoreGraphics dylib)
        guard let cg = cgHandle else {
            // Re-open CoreGraphics if handle was lost
            guard let newCg = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else {
                NSLog("[Capture] FATAL: Failed to dlopen CoreGraphics on restart")
                return
            }
            cgHandle = newCg
            return await restartStream()  // retry with new handle
        }

        guard let createSym = dlsym(cg, "CGDisplayStreamCreateWithDispatchQueue"),
              let startSym = dlsym(cg, "CGDisplayStreamStart") else {
            NSLog("[Capture] FATAL: Failed to resolve CGDisplayStream symbols on restart")
            return
        }

        let createFn = unsafeBitCast(createSym, to: CGDisplayStreamCreateFn.self)
        let startFn = unsafeBitCast(startSym, to: CGDisplayStreamStartFn.self)

        let properties: NSDictionary = [
            "kCGDisplayStreamMinimumFrameTime": NSNumber(value: 1.0 / Double(TARGET_FPS)),
            "kCGDisplayStreamShowCursor": kCFBooleanTrue as Any
        ]

        let captureQueue = DispatchQueue(label: "capture", qos: .userInteractive)
        let pixelFormat: Int32 = 1111970369  // kCVPixelFormatType_32BGRA

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
            NSLog("[Capture] Failed to create new CGDisplayStream — display %d may be unavailable", targetDisplayID)
            return
        }

        displayStream = stream
        let cfStream = Unmanaged<CFTypeRef>.fromOpaque(UnsafeRawPointer(stream))
        _ = cfStream.retain()

        let result = startFn(stream)
        if result == 0 {
            NSLog("[Capture] CGDisplayStream restarted successfully for display %d", targetDisplayID)
        } else {
            NSLog("[Capture] CGDisplayStreamStart failed on restart with code %d", result)
        }
    }

    // MARK: - Frame callback

    private func handleFrame(status: Int32, surface: IOSurfaceRef?) {
        // Status codes:
        // 0 = FrameComplete, 1 = FrameIdle, 2 = FrameBlank, 3 = Stopped
        guard status == 0, let surface = surface else { return }

        // Check stopped flag to avoid accessing deallocated buffers (#49)
        stoppedLock.lock()
        let shouldStop = isStopped
        stoppedLock.unlock()
        guard !shouldStop else { return }

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

        // Log actual IOSurface dimensions on first frame
        if frameCount == 0 {
            let surfW = IOSurfaceGetWidth(surface)
            let surfH = IOSurfaceGetHeight(surface)
            let surfBPP = IOSurfaceGetBytesPerElement(surface)
            NSLog("[Capture] EXPERIMENT: raw BGRA mode — no greyscale conversion")
            NSLog("[Capture] IOSurface: %dx%d, %d bpp, rowBytes=%d (expected %dx%d)",
                  surfW, surfH, surfBPP, rowBytes, frameWidth, frameHeight)
        }

        // Copy raw BGRA directly — no greyscale conversion, no sharpen, no LUT.
        // The Android GPU shader will handle luminance conversion.
        let srcPtr = baseAddress.assumingMemoryBound(to: UInt8.self)
        let expectedRowBytes = frameWidth * 4
        if rowBytes == expectedRowBytes {
            // Contiguous — single memcpy
            memcpy(currentFrame!, srcPtr, frameBufferSize)
        } else {
            // IOSurface may have padding per row — copy row by row
            for y in 0..<frameHeight {
                memcpy(currentFrame! + y * expectedRowBytes, srcPtr + y * rowBytes, expectedRowBytes)
            }
        }

        let t1 = CACurrentMediaTime()

        // Drop frames when Android can't keep up — send only the latest
        let inflight = tcpServer.inflightFrames
        let isScheduledKeyframe = (frameCount % KEYFRAME_INTERVAL == 0)

        let rtt = tcpServer.latencyStats?.rttAvgMs ?? 15.0
        let adaptiveThreshold = adaptiveBackpressureThreshold(rttMs: rtt)
        if inflight > adaptiveThreshold && !isScheduledKeyframe {
            skippedFrames += 1
            forceNextKeyframe = true
            let temp = previousFrame
            previousFrame = currentFrame
            currentFrame = temp

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
                currentFrame!, compressedBuffer!, Int32(frameBufferSize),
                LZ4_compressBound(Int32(frameBufferSize))
            )
            let payload = Data(bytes: compressedBuffer!, count: Int(compressedSize))
            tcpServer.broadcast(payload: payload, isKeyframe: true, sequenceNumber: seq)
            lastCompressedSize = Int(compressedSize)
        } else {
            for i in 0..<frameBufferSize {
                deltaBuffer![i] = currentFrame![i] ^ previousFrame![i]
            }
            let compressedSize = LZ4_compress_default(
                deltaBuffer!, compressedBuffer!, Int32(frameBufferSize),
                LZ4_compressBound(Int32(frameBufferSize))
            )
            if compressedSize < TRIVIAL_DELTA_THRESHOLD {
                skippedFrames += 1
                frameSequence &-= 1
            } else {
                let payload = Data(bytes: compressedBuffer!, count: Int(compressedSize))
                tcpServer.broadcast(payload: payload, isKeyframe: false, sequenceNumber: seq)
            }
            lastCompressedSize = Int(compressedSize)
        }

        let temp = previousFrame
        previousFrame = currentFrame
        currentFrame = temp

        let t2 = CACurrentMediaTime()

        if wsServer?.hasClients == true {
            let ciImage = CIImage(ioSurface: unsafeBitCast(surface, to: IOSurface.self))
            let grayImage = ciImage.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.0])
            if let jpegData = ciContext.jpegRepresentation(
                of: grayImage,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: JPEG_QUALITY]
            ) {
                wsServer?.broadcast(jpegData)
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
