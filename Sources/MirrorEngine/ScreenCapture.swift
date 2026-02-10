// ScreenCapture.swift — CPU-only screen capture with vImage SIMD greyscale + LZ4 delta compression.

import Foundation
import ScreenCaptureKit
import CoreImage
import CoreMedia
import Accelerate
import CLZ4

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
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

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
