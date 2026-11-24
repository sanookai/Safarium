import Accelerate
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct FrameExtractReport: Codable, Sendable {
    public let inputPath: String
    public let outputDir: String
    public let format: String
    public let frameCount: Int
    public let files: [String]
    public let width: Int
    public let height: Int
    public let wallMs: Double
}

public struct GrayRawExtractReport: Codable, Sendable {
    public let inputPath: String
    public let outputPath: String
    public let fps: Double
    public let width: Int
    public let height: Int
    public let frameCount: Int
    public let bytesWritten: Int
    public let wallMs: Double
}

public enum FrameExtractor {
    private static func resolveOutputDimensions(
        naturalWidth: Int,
        naturalHeight: Int,
        width: Int?,
        height: Int?
    ) throws -> (Int, Int) {
        let w: Int
        let h: Int
        switch (width, height) {
        case (.some(let reqW), .some(let reqH)):
            w = reqW
            h = reqH
        case (.some(let reqW), .none):
            w = reqW
            let scaledH = Double(reqW) * Double(max(1, naturalHeight)) / Double(max(1, naturalWidth))
            h = max(2, Int(scaledH.rounded()) & ~1)
        case (.none, .some(let reqH)):
            h = reqH
            let scaledW = Double(reqH) * Double(max(1, naturalWidth)) / Double(max(1, naturalHeight))
            w = max(2, Int(scaledW.rounded()) & ~1)
        case (.none, .none):
            w = max(2, naturalWidth)
            h = max(2, naturalHeight)
        }
        guard (2...8192).contains(w), (2...8192).contains(h) else {
            throw SafariumError.invalidState("extracted frame dimensions out of bounds (2...8192): \(w)x\(h)")
        }
        return (w, h)
    }

    private static func normalizedFormat(_ format: String) throws -> (ext: String, utType: UTType) {
        switch format.lowercased() {
        case "jpg", "jpeg":
            return ("jpg", .jpeg)
        case "png":
            return ("png", .png)
        default:
            throw SafariumError.invalidState("unsupported image format '\(format)' (expected jpg|png)")
        }
    }

    private static func orientedDimensions(for track: AVAssetTrack) async throws -> (Int, Int) {
        let natSize = try await track.load(.naturalSize)
        let tx = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: natSize).applying(tx)
        return (max(2, Int(abs(rect.width).rounded())), max(2, Int(abs(rect.height).rounded())))
    }

    private static func scaleIfNeeded(_ image: CGImage, targetWidth: Int, targetHeight: Int) throws -> CGImage {
        if image.width == targetWidth && image.height == targetHeight {
            return image
        }
        guard let ctx = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: Snapshot.colorSpace,
            bitmapInfo: Snapshot.bitmapInfo
        ) else {
            throw SafariumError.encode("cannot allocate CGContext for frame scaling \(targetWidth)x\(targetHeight)")
        }
        ctx.interpolationQuality = .high
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = ctx.makeImage() else {
            throw SafariumError.encode("CGContext.makeImage failed while scaling frame")
        }
        return scaled
    }

    private static func writeImage(
        _ image: CGImage,
        to targetURL: URL,
        utType: UTType,
        jpegQuality: Double,
        overwrite: Bool
    ) throws {
        let staging = try SafeFilePublisher.Staging(beside: targetURL)
        defer { staging.cleanup() }
        let ext = utType == .png ? "png" : "jpg"
        let tempURL = staging.fileURL("frame.\(ext)")
        guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, utType.identifier as CFString, 1, nil) else {
            throw SafariumError.encode("cannot create \(ext.uppercased()) destination for \(targetURL.lastPathComponent)")
        }
        let props: CFDictionary? = (utType == .jpeg)
            ? ([kCGImageDestinationLossyCompressionQuality: max(0.05, min(1.0, jpegQuality))] as CFDictionary)
            : nil
        CGImageDestinationAddImage(dest, image, props)
        guard CGImageDestinationFinalize(dest) else {
            throw SafariumError.encode("CGImageDestinationFinalize failed for \(targetURL.lastPathComponent)")
        }
        try SafeFilePublisher.publish(tempURL: tempURL, to: targetURL, overwrite: overwrite)
    }

    public static func extractAtTimestamps(
        url: URL,
        times: [Double],
        outDir: URL,
        width: Int? = nil,
        height: Int? = nil,
        format: String = "jpg",
        jpegQuality: Double = 0.90,
        overwrite: Bool = false
    ) async throws -> FrameExtractReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SafariumError.invalidState("extract-frames input does not exist: \(url.path)")
        }
        guard !times.isEmpty else {
            throw SafariumError.invalidState("extract-frames requires at least one timestamp")
        }
        for t in times {
            guard t.isFinite, t >= 0 else {
                throw SafariumError.invalidState("invalid timestamp \(t); expected finite >= 0")
            }
        }
        let (ext, utType) = try normalizedFormat(format)

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let vt = try await asset.loadTracks(withMediaType: .video).first else {
            throw SafariumError.invalidState("extract-frames input has no video track: \(url.path)")
        }
        let (natW, natH) = try await orientedDimensions(for: vt)
        let (outW, outH) = try resolveOutputDimensions(naturalWidth: natW, naturalHeight: natH, width: width, height: height)

        let durSec = CMTimeGetSeconds(try await asset.load(.duration))
        guard durSec.isFinite, durSec > 0 else {
            throw SafariumError.invalidState("extract-frames input has non-positive duration")
        }

        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var names: [String] = []
        names.reserveCapacity(times.count)
        for idx in 0..<times.count {
            let name = String(format: "f%04d.%@", idx + 1, ext)
            try SafeFilePublisher.preflight(outputURL: outDir.appendingPathComponent(name), overwrite: overwrite)
            names.append(name)
        }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero

        let maxSec = max(0.0, durSec - 0.001)
        for (idx, reqSec) in times.enumerated() {
            let clampedSec = min(reqSec, maxSec)
            let targetTime = CMTime(seconds: clampedSec, preferredTimescale: 600_000)
            let cgImg = try await gen.image(at: targetTime).image
            let finalImg = try scaleIfNeeded(cgImg, targetWidth: outW, targetHeight: outH)
            try writeImage(
                finalImg,
                to: outDir.appendingPathComponent(names[idx]),
                utType: utType,
                jpegQuality: jpegQuality,
                overwrite: overwrite
            )
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return FrameExtractReport(
            inputPath: url.path,
            outputDir: outDir.path,
            format: ext,
            frameCount: names.count,
            files: names,
            width: outW,
            height: outH,
            wallMs: elapsedMs
        )
    }

    public static func extractEvery(
        url: URL,
        everySeconds: Double,
        outDir: URL,
        width: Int? = nil,
        height: Int? = nil,
        format: String = "jpg",
        jpegQuality: Double = 0.88,
        overwrite: Bool = false
    ) async throws -> FrameExtractReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SafariumError.invalidState("extract-frames input does not exist: \(url.path)")
        }
        guard everySeconds.isFinite, everySeconds > 0 else {
            throw SafariumError.invalidState("--every must be finite and > 0")
        }
        let (ext, utType) = try normalizedFormat(format)

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let vt = try await asset.loadTracks(withMediaType: .video).first else {
            throw SafariumError.invalidState("extract-frames input has no video track: \(url.path)")
        }
        let (natW, natH) = try await orientedDimensions(for: vt)
        let prefTx = try await vt.load(.preferredTransform)
        let (outW, outH) = try resolveOutputDimensions(naturalWidth: natW, naturalHeight: natH, width: width, height: height)

        let durSec = CMTimeGetSeconds(try await asset.load(.duration))
        guard durSec.isFinite, durSec > 0 else {
            throw SafariumError.invalidState("extract-frames input has non-positive duration")
        }

        // Mid-interval sampling matches `fps=1/<every>`: k * every + every / 2.
        var targetTimes: [Double] = []
        var stepIdx = 0
        while true {
            let t = (Double(stepIdx) + 0.5) * everySeconds
            if t >= durSec { break }
            targetTimes.append(t)
            stepIdx += 1
        }
        if targetTimes.isEmpty {
            targetTimes.append(max(0.0, durSec * 0.5))
        }

        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var names: [String] = []
        names.reserveCapacity(targetTimes.count)
        for idx in 0..<targetTimes.count {
            let name = String(format: "f%04d.%@", idx + 1, ext)
            try SafeFilePublisher.preflight(outputURL: outDir.appendingPathComponent(name), overwrite: overwrite)
            names.append(name)
        }

        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: vt, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else {
            throw SafariumError.encode("extract-frames reader failed: \(reader.error?.localizedDescription ?? "?")")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let ciCtx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [
            .workingColorSpace: Snapshot.colorSpace,
            .outputColorSpace: Snapshot.colorSpace,
            .cacheIntermediates: false,
        ])

        var nextIdx = 0
        var lastCG: CGImage?
        while nextIdx < targetTimes.count {
            guard let sb = autoreleasepool(invoking: { out.copyNextSampleBuffer() }) else {
                break
            }
            if sb.numSamples == 0 { continue }
            let ptsSec = CMTimeGetSeconds(sb.presentationTimeStamp)
            guard let pb = sb.imageBuffer else { continue }

            // Capture frame as CGImage only when at least one target time falls on or before this sample.
            if ptsSec + 1e-6 >= targetTimes[nextIdx] || nextIdx == 0 {
                let converted: CGImage? = autoreleasepool {
                    let ciImg = SafariumSequentialVideoReader.orientedCIImage(from: pb, transform: prefTx)
                    guard let cg = ciCtx.createCGImage(ciImg, from: ciImg.extent, format: .BGRA8, colorSpace: Snapshot.colorSpace) else {
                        return nil
                    }
                    return try? scaleIfNeeded(cg, targetWidth: outW, targetHeight: outH)
                }
                if let converted {
                    lastCG = converted
                }
            }

            while nextIdx < targetTimes.count && ptsSec + 1e-6 >= targetTimes[nextIdx], let imgToWrite = lastCG {
                try writeImage(
                    imgToWrite,
                    to: outDir.appendingPathComponent(names[nextIdx]),
                    utType: utType,
                    jpegQuality: jpegQuality,
                    overwrite: overwrite
                )
                nextIdx += 1
            }
        }
        if reader.status == .failed {
            throw SafariumError.encode("extract-frames read failed: \(reader.error?.localizedDescription ?? "?")")
        }
        while nextIdx < targetTimes.count, let imgToWrite = lastCG {
            try writeImage(
                imgToWrite,
                to: outDir.appendingPathComponent(names[nextIdx]),
                utType: utType,
                jpegQuality: jpegQuality,
                overwrite: overwrite
            )
            nextIdx += 1
        }
        guard nextIdx > 0 else {
            throw SafariumError.invalidState("extract-frames yielded 0 frames from \(url.lastPathComponent)")
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return FrameExtractReport(
            inputPath: url.path,
            outputDir: outDir.path,
            format: ext,
            frameCount: nextIdx,
            files: Array(names.prefix(nextIdx)),
            width: outW,
            height: outH,
            wallMs: elapsedMs
        )
    }

    public static func extractGrayRaw(
        url: URL,
        fps: Double,
        width: Int,
        height: Int,
        outputURL: URL,
        overwrite: Bool = false
    ) async throws -> GrayRawExtractReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SafariumError.invalidState("extract-frames input does not exist: \(url.path)")
        }
        guard fps.isFinite, fps > 0, fps <= 120.0 else {
            throw SafariumError.invalidState("--fps must be in (0, 120]")
        }
        guard (2...8192).contains(width), (2...8192).contains(height) else {
            throw SafariumError.invalidState("gray-raw width/height must be in 2...8192")
        }
        try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let vt = try await asset.loadTracks(withMediaType: .video).first else {
            throw SafariumError.invalidState("extract-frames input has no video track: \(url.path)")
        }
        let prefTx = try await vt.load(.preferredTransform)
        let isIdentityTx = abs(prefTx.a - 1) < 0.01 && abs(prefTx.b) < 0.01 && abs(prefTx.c) < 0.01 && abs(prefTx.d - 1) < 0.01
        let rotCtx: CIContext? = isIdentityTx ? nil : (SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false]))
        let grayColorSpace = CGColorSpaceCreateDeviceGray()

        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: vt, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        guard reader.startReading() else {
            throw SafariumError.encode("gray-raw reader failed: \(reader.error?.localizedDescription ?? "?")")
        }
        defer { if reader.status == .reading { reader.cancelReading() } }

        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }
        let tempURL = staging.fileURL("gray.raw")
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempURL)
        var closedHandle = false
        defer { if !closedHandle { try? handle.close() } }

        let frameBytes = width * height
        var dstPlane = [UInt8](repeating: 0, count: frameBytes)
        var hasLast = false
        let stepSec = 1.0 / fps
        var nextTargetSec = 0.0
        var writtenFrames = 0

        while let sb = autoreleasepool(invoking: { out.copyNextSampleBuffer() }) {
            if sb.numSamples == 0 { continue }
            guard let pb = sb.imageBuffer else { continue }
            let ptsSec = CMTimeGetSeconds(sb.presentationTimeStamp)
            if hasLast && ptsSec + 1e-6 < nextTargetSec {
                continue
            }
            var scaledOK = false
            if isIdentityTx {
                guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { continue }
                if let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
                    let srcW = CVPixelBufferGetWidthOfPlane(pb, 0)
                    let srcH = CVPixelBufferGetHeightOfPlane(pb, 0)
                    let srcStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                    var srcBuf = vImage_Buffer(
                        data: base,
                        height: vImagePixelCount(srcH),
                        width: vImagePixelCount(srcW),
                        rowBytes: srcStride
                    )
                    let err = dstPlane.withUnsafeMutableBytes { dstRaw -> vImage_Error in
                        var dstBuf = vImage_Buffer(
                            data: dstRaw.baseAddress!,
                            height: vImagePixelCount(height),
                            width: vImagePixelCount(width),
                            rowBytes: width
                        )
                        return vImageScale_Planar8(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageHighQualityResampling))
                    }
                    if err == kvImageNoError {
                        scaledOK = true
                        hasLast = true
                    }
                }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            } else if let rotCtx {
                autoreleasepool {
                    let ciImg = SafariumSequentialVideoReader.orientedCIImage(from: pb, transform: prefTx)
                    let sx = CGFloat(width) / max(1.0, ciImg.extent.width)
                    let sy = CGFloat(height) / max(1.0, ciImg.extent.height)
                    let scaled = ciImg.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                    let originZero = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.origin.x, y: -scaled.extent.origin.y))
                    dstPlane.withUnsafeMutableBytes { dstRaw in
                        rotCtx.render(
                            originZero,
                            toBitmap: dstRaw.baseAddress!,
                            rowBytes: width,
                            bounds: CGRect(x: 0, y: 0, width: width, height: height),
                            format: .L8,
                            colorSpace: grayColorSpace
                        )
                    }
                    scaledOK = true
                    hasLast = true
                }
            }
            guard scaledOK else {
                throw SafariumError.encode("gray-raw scaling failed while extracting frames")
            }

            if ptsSec + 1e-6 >= nextTargetSec {
                let chunkData = Data(dstPlane)
                while ptsSec + 1e-6 >= nextTargetSec {
                    try handle.write(contentsOf: chunkData)
                    writtenFrames += 1
                    nextTargetSec += stepSec
                }
            }
        }
        if reader.status == .failed {
            throw SafariumError.encode("gray-raw read failed: \(reader.error?.localizedDescription ?? "?")")
        }
        guard writtenFrames > 0 else {
            throw SafariumError.invalidState("gray-raw yielded 0 frames from \(url.lastPathComponent)")
        }

        try handle.close()
        closedHandle = true
        try SafeFilePublisher.publish(tempURL: tempURL, to: outputURL, overwrite: overwrite)

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return GrayRawExtractReport(
            inputPath: url.path,
            outputPath: outputURL.path,
            fps: fps,
            width: width,
            height: height,
            frameCount: writtenFrames,
            bytesWritten: writtenFrames * frameBytes,
            wallMs: elapsedMs
        )
    }
}
