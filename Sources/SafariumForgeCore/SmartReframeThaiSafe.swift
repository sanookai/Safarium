import Accelerate
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import SafariumCore
import Vision

// MARK: - Wave 15B: Thai-Safe Smart Auto-Reframe v2

/// Supported target aspect ratios for Thai-Safe Smart Auto-Reframe.
public enum ReframeTargetAspect: String, Codable, Sendable, CaseIterable {
    case vertical9x16 = "9:16"
    case square1x1 = "1:1"
    case portrait4x5 = "4:5"

    /// Width / Height aspect ratio.
    public var ratio: Double {
        switch self {
        case .vertical9x16: return 9.0 / 16.0
        case .square1x1: return 1.0
        case .portrait4x5: return 4.0 / 5.0
        }
    }
}

/// Configuration for `SmartReframeThaiSafe`.
public struct SmartReframeConfig: Codable, Sendable {
    public var aspect: ReframeTargetAspect
    public var outputWidth: Int?
    public var outputHeight: Int?
    public var protectThaiText: Bool
    public var protectFaces: Bool
    public var safeMarginRatio: Double
    public var smoothingAlpha: Double
    public var maxPanPixelsPerSecond: Double
    public var analysisStrideFrames: Int
    public var bitrate: Int?

    public init(
        aspect: ReframeTargetAspect = .vertical9x16,
        outputWidth: Int? = nil,
        outputHeight: Int? = nil,
        protectThaiText: Bool = true,
        protectFaces: Bool = true,
        safeMarginRatio: Double = 0.06,
        smoothingAlpha: Double = 0.18,
        maxPanPixelsPerSecond: Double = 360.0,
        analysisStrideFrames: Int = 5,
        bitrate: Int? = nil
    ) {
        self.aspect = aspect
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.protectThaiText = protectThaiText
        self.protectFaces = protectFaces
        self.safeMarginRatio = safeMarginRatio
        self.smoothingAlpha = smoothingAlpha
        self.maxPanPixelsPerSecond = maxPanPixelsPerSecond
        self.analysisStrideFrames = analysisStrideFrames
        self.bitrate = bitrate
    }
}

/// Single smoothed crop keyframe along the reframed camera path (top-left source pixel space).
public struct ReframeKeyframe: Codable, Sendable, Equatable {
    public let frameIndex: Int
    public let timeSeconds: Double
    public let cropX: Double
    public let cropY: Double
    public let cropWidth: Double
    public let cropHeight: Double
    public let faceCount: Int
    public let textBoxCount: Int
    public let textProtected: Bool

    public init(
        frameIndex: Int,
        timeSeconds: Double,
        cropX: Double,
        cropY: Double,
        cropWidth: Double,
        cropHeight: Double,
        faceCount: Int,
        textBoxCount: Int,
        textProtected: Bool
    ) {
        self.frameIndex = frameIndex
        self.timeSeconds = timeSeconds
        self.cropX = cropX
        self.cropY = cropY
        self.cropWidth = cropWidth
        self.cropHeight = cropHeight
        self.faceCount = faceCount
        self.textBoxCount = textBoxCount
        self.textProtected = textProtected
    }
}

/// Summary telemetry produced by `SmartReframeThaiSafe.reframe`.
public struct SmartReframeReport: Codable, Sendable {
    public let inputPath: String
    public let outputPath: String
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let outputWidth: Int
    public let outputHeight: Int
    public let framesProcessed: Int
    public let keyframes: [ReframeKeyframe]
    public let textBoxesDetected: Int
    public let textClippingAvoidedCount: Int
    public let maxPanVelocityPxPerSec: Double
    public let elapsedMs: Double

    public init(
        inputPath: String,
        outputPath: String,
        sourceWidth: Int,
        sourceHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        framesProcessed: Int,
        keyframes: [ReframeKeyframe],
        textBoxesDetected: Int,
        textClippingAvoidedCount: Int,
        maxPanVelocityPxPerSec: Double,
        elapsedMs: Double
    ) {
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.framesProcessed = framesProcessed
        self.keyframes = keyframes
        self.textBoxesDetected = textBoxesDetected
        self.textClippingAvoidedCount = textClippingAvoidedCount
        self.maxPanVelocityPxPerSec = maxPanVelocityPxPerSec
        self.elapsedMs = elapsedMs
    }
}

/// Thai-Safe Smart Auto-Reframe v2 engine using 100% native Apple Silicon frameworks
/// (`AVFoundation`, `Vision`, `CoreImage`, `Accelerate`, `Metal`).
public enum SmartReframeThaiSafe {

    // MARK: - Internal Analysis Types

    private struct RawSampledFrame: Sendable {
        let frameIndex: Int
        let timeSeconds: Double
        let rawCropX: Double
        let rawCropY: Double
        let cropWidth: Double
        let cropHeight: Double
        let faceCount: Int
        let textBoxCount: Int
        let textProtected: Bool
    }

    private struct DetailedAnalysis: Sendable {
        let sourceWidth: Int
        let sourceHeight: Int
        let outputWidth: Int
        let outputHeight: Int
        let cropWidth: Double
        let cropHeight: Double
        let fps: Double
        let keyframes: [ReframeKeyframe]
        let textBoxesDetected: Int
        let textClippingAvoidedCount: Int
        let maxPanVelocityPxPerSec: Double
    }

    private struct VideoGeometry: Sendable {
        let naturalWidth: Int
        let naturalHeight: Int
        let sourceWidth: Int
        let sourceHeight: Int
        let cropWidth: Double
        let cropHeight: Double
        let outputWidth: Int
        let outputHeight: Int
        let fps: Double
        let preferredTransform: CGAffineTransform
        let isIdentityTransform: Bool
    }

    // MARK: - Public API

    /// Analyzes sampled frames of `inputURL` via Vision face, saliency, and Thai/English OCR
    /// (with high-contrast horizontal text-band fallback) and returns a velocity-bounded,
    /// damped-spring smoothed crop keyframe path.
    public static func analyzeCropPath(
        inputURL: URL,
        config: SmartReframeConfig = SmartReframeConfig()
    ) async throws -> [ReframeKeyframe] {
        let detailed = try await analyzeDetailed(inputURL: inputURL, config: config)
        return detailed.keyframes
    }

    /// Reframes `inputURL` to `outputURL` using Thai-safe subject & text protection,
    /// smooth camera pan dynamics, CoreImage crop+scale, and native AVAssetWriter MP4 export
    /// while preserving the audio track if present.
    public static func reframe(
        inputURL: URL,
        outputURL: URL,
        config: SmartReframeConfig = SmartReframeConfig()
    ) async throws -> SmartReframeReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(inputURL)

        let analysis = try await analyzeDetailed(inputURL: inputURL, config: config)
        let asset = AVURLAsset(url: inputURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw SafariumError.invalidState("SmartReframeThaiSafe: no video track in \(inputURL.lastPathComponent)")
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first

        let geometry = try await resolveGeometry(videoTrack: videoTrack, config: config)
        let audioParams = try await resolveAudioParams(audioTrack: audioTrack)

        let parentDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let tempURL = parentDir.appendingPathComponent(".reframe-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let framesProcessed = try await renderAndExport(
            asset: asset,
            videoTrack: videoTrack,
            audioTrack: audioTrack,
            audioParams: audioParams,
            geometry: geometry,
            keyframes: analysis.keyframes,
            bitrate: config.bitrate,
            outputURL: tempURL
        )

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: outputURL)

        let t1 = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = Double(t1 - t0) / 1_000_000.0

        return SmartReframeReport(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            sourceWidth: analysis.sourceWidth,
            sourceHeight: analysis.sourceHeight,
            outputWidth: analysis.outputWidth,
            outputHeight: analysis.outputHeight,
            framesProcessed: framesProcessed,
            keyframes: analysis.keyframes,
            textBoxesDetected: analysis.textBoxesDetected,
            textClippingAvoidedCount: analysis.textClippingAvoidedCount,
            maxPanVelocityPxPerSec: analysis.maxPanVelocityPxPerSec,
            elapsedMs: elapsedMs
        )
    }

    // MARK: - Geometry & Helpers

    private static func evenDimension(_ value: Int) -> Int {
        let clamped = max(2, value)
        return clamped & ~1
    }

    private static func clamp(_ value: Double, min lo: Double, max hi: Double) -> Double {
        if !value.isFinite { return lo }
        if value < lo { return lo }
        if value > hi { return hi }
        return value
    }

    private static func resolveGeometry(
        videoTrack: AVAssetTrack,
        config: SmartReframeConfig
    ) async throws -> VideoGeometry {
        let natSize = try await videoTrack.load(.naturalSize)
        let prefTx = try await videoTrack.load(.preferredTransform)
        let nomFPS = Double(try await videoTrack.load(.nominalFrameRate))
        let fps = (nomFPS.isFinite && nomFPS > 0.1) ? nomFPS : 30.0

        let natW = max(2, Int(abs(natSize.width).rounded()))
        let natH = max(2, Int(abs(natSize.height).rounded()))
        let uprightRect = CGRect(origin: .zero, size: natSize).applying(prefTx)
        let srcW = max(2, Int(abs(uprightRect.width).rounded()))
        let srcH = max(2, Int(abs(uprightRect.height).rounded()))

        let srcWDouble = Double(srcW)
        let srcHDouble = Double(srcH)
        let srcAspect = srcWDouble / max(1.0, srcHDouble)
        let targetAspect = config.aspect.ratio

        let cropW: Double
        let cropH: Double
        if targetAspect < srcAspect {
            cropH = srcHDouble
            let computedW = (srcHDouble * targetAspect).rounded()
            cropW = clamp(computedW, min: 2.0, max: srcWDouble)
        } else {
            cropW = srcWDouble
            let computedH = (srcWDouble / targetAspect).rounded()
            cropH = clamp(computedH, min: 2.0, max: srcHDouble)
        }

        let outW: Int
        let outH: Int
        if let reqW = config.outputWidth, let reqH = config.outputHeight {
            outW = evenDimension(reqW)
            outH = evenDimension(reqH)
        } else if let reqH = config.outputHeight {
            outH = evenDimension(reqH)
            let wScaled = Int((Double(outH) * targetAspect).rounded())
            outW = evenDimension(wScaled)
        } else if let reqW = config.outputWidth {
            outW = evenDimension(reqW)
            let hScaled = Int((Double(outW) / targetAspect).rounded())
            outH = evenDimension(hScaled)
        } else {
            outH = evenDimension(Int(cropH.rounded()))
            let wScaled = Int((Double(outH) * targetAspect).rounded())
            outW = evenDimension(wScaled)
        }

        let isIdentity = prefTx.isIdentity
        return VideoGeometry(
            naturalWidth: natW,
            naturalHeight: natH,
            sourceWidth: srcW,
            sourceHeight: srcH,
            cropWidth: cropW,
            cropHeight: cropH,
            outputWidth: outW,
            outputHeight: outH,
            fps: fps,
            preferredTransform: prefTx,
            isIdentityTransform: isIdentity
        )
    }

    private struct AudioStreamParams: Sendable {
        let sampleRate: Double
        let channels: Int
    }

    private static func resolveAudioParams(audioTrack: AVAssetTrack?) async throws -> AudioStreamParams? {
        guard let track = audioTrack else { return nil }
        let descs = try await track.load(.formatDescriptions)
        var sampleRate = 48_000.0
        var channels = 2
        if let first = descs.first,
           let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(first) {
            let asbd = asbdPtr.pointee
            if asbd.mSampleRate >= 8_000.0 && asbd.mSampleRate <= 192_000.0 {
                sampleRate = asbd.mSampleRate
            }
            if asbd.mChannelsPerFrame >= 1 && asbd.mChannelsPerFrame <= 8 {
                channels = Int(asbd.mChannelsPerFrame)
            }
        }
        return AudioStreamParams(sampleRate: sampleRate, channels: channels)
    }

    // MARK: - Analysis Pipeline

    private static func analyzeDetailed(
        inputURL: URL,
        config: SmartReframeConfig
    ) async throws -> DetailedAnalysis {
        try SafeFilePublisher.assertRegularReadableFile(inputURL)
        let asset = AVURLAsset(url: inputURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw SafariumError.invalidState("SmartReframeThaiSafe: no video track in \(inputURL.lastPathComponent)")
        }

        let geometry = try await resolveGeometry(videoTrack: videoTrack, config: config)
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else {
            throw SafariumError.encode("SmartReframeThaiSafe: cannot add video reader output")
        }
        reader.add(trackOutput)
        guard reader.startReading() else {
            let msg = reader.error?.localizedDescription ?? "unknown"
            throw SafariumError.encode("SmartReframeThaiSafe: reader failed to start: \(msg)")
        }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }

        let ciContext = makeCIContext()
        let strideFrames = max(1, config.analysisStrideFrames)
        let srcW = geometry.sourceWidth
        let srcH = geometry.sourceHeight
        let cropW = geometry.cropWidth
        let cropH = geometry.cropHeight

        var rawSamples: [RawSampledFrame] = []
        var totalTextBoxesDetected = 0
        var totalTextClippingAvoided = 0
        var frameIndex = 0
        var lastFrameIndex = 0
        var lastTimeSeconds = 0.0
        var lastSampledFrameIndex = -1
        var lastPixelBuffer: CVPixelBuffer?

        while let sb = autoreleasepool(invoking: { trackOutput.copyNextSampleBuffer() }) {
            if CMSampleBufferGetNumSamples(sb) == 0 { continue }
            guard let rawPB = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            let timeSec = pts.isNumeric ? max(0.0, CMTimeGetSeconds(pts)) : (Double(frameIndex) / geometry.fps)

            lastFrameIndex = frameIndex
            lastTimeSeconds = timeSec
            lastPixelBuffer = rawPB

            if frameIndex == 0 || (frameIndex % strideFrames == 0) {
                let uprightPB = makeUprightPixelBufferIfNeeded(
                    rawPB: rawPB,
                    geometry: geometry,
                    ciContext: ciContext
                )
                let detection = analyzeSingleFrame(
                    pixelBuffer: uprightPB,
                    srcW: srcW,
                    srcH: srcH,
                    cropW: cropW,
                    cropH: cropH,
                    config: config
                )
                totalTextBoxesDetected += detection.textBoxCount
                if detection.textProtected {
                    totalTextClippingAvoided += 1
                }
                rawSamples.append(RawSampledFrame(
                    frameIndex: frameIndex,
                    timeSeconds: timeSec,
                    rawCropX: detection.cropX,
                    rawCropY: detection.cropY,
                    cropWidth: cropW,
                    cropHeight: cropH,
                    faceCount: detection.faceCount,
                    textBoxCount: detection.textBoxCount,
                    textProtected: detection.textProtected
                ))
                lastSampledFrameIndex = frameIndex
            }
            frameIndex += 1
        }

        // Ensure final frame is also represented if not already sampled
        if let tailPB = lastPixelBuffer, lastFrameIndex > lastSampledFrameIndex {
            let uprightPB = makeUprightPixelBufferIfNeeded(
                rawPB: tailPB,
                geometry: geometry,
                ciContext: ciContext
            )
            let detection = analyzeSingleFrame(
                pixelBuffer: uprightPB,
                srcW: srcW,
                srcH: srcH,
                cropW: cropW,
                cropH: cropH,
                config: config
            )
            totalTextBoxesDetected += detection.textBoxCount
            if detection.textProtected {
                totalTextClippingAvoided += 1
            }
            rawSamples.append(RawSampledFrame(
                frameIndex: lastFrameIndex,
                timeSeconds: lastTimeSeconds,
                rawCropX: detection.cropX,
                rawCropY: detection.cropY,
                cropWidth: cropW,
                cropHeight: cropH,
                faceCount: detection.faceCount,
                textBoxCount: detection.textBoxCount,
                textProtected: detection.textProtected
            ))
        }

        guard !rawSamples.isEmpty else {
            throw SafariumError.invalidState("SmartReframeThaiSafe: zero decodable video frames in \(inputURL.lastPathComponent)")
        }

        let smoothed = smoothKeyframes(
            rawSamples: rawSamples,
            srcW: Double(srcW),
            srcH: Double(srcH),
            config: config
        )

        return DetailedAnalysis(
            sourceWidth: srcW,
            sourceHeight: srcH,
            outputWidth: geometry.outputWidth,
            outputHeight: geometry.outputHeight,
            cropWidth: cropW,
            cropHeight: cropH,
            fps: geometry.fps,
            keyframes: smoothed.keyframes,
            textBoxesDetected: totalTextBoxesDetected,
            textClippingAvoidedCount: totalTextClippingAvoided,
            maxPanVelocityPxPerSec: smoothed.maxVelocity
        )
    }

    private struct FrameDetectionResult: Sendable {
        let cropX: Double
        let cropY: Double
        let faceCount: Int
        let textBoxCount: Int
        let textProtected: Bool
    }

    private static func analyzeSingleFrame(
        pixelBuffer: CVPixelBuffer,
        srcW: Int,
        srcH: Int,
        cropW: Double,
        cropH: Double,
        config: SmartReframeConfig
    ) -> FrameDetectionResult {
        let srcWD = Double(srcW)
        let srcHD = Double(srcH)

        var requests: [VNRequest] = []
        let faceReq = VNDetectFaceRectanglesRequest()
        let saliencyReq = VNGenerateAttentionBasedSaliencyImageRequest()
        let textReq = VNRecognizeTextRequest()

        if config.protectFaces {
            requests.append(faceReq)
        }
        requests.append(saliencyReq)
        if config.protectThaiText {
            textReq.recognitionLevel = .fast
            textReq.usesLanguageCorrection = false
            textReq.recognitionLanguages = ["th-TH", "en-US"]
            textReq.minimumTextHeight = 0.02
            requests.append(textReq)
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform(requests)

        // Convert Vision bottom-left normalized rects to top-left pixel rects
        var faceRects: [CGRect] = []
        if config.protectFaces, let faces = faceReq.results {
            for f in faces {
                faceRects.append(visionBoxToTopLeftPixels(f.boundingBox, srcW: srcWD, srcH: srcHD))
            }
        }

        var saliencyBox: CGRect?
        if let sal = saliencyReq.results?.first, let objects = sal.salientObjects, !objects.isEmpty {
            let best = objects.max(by: { $0.confidence < $1.confidence }) ?? objects[0]
            saliencyBox = visionBoxToTopLeftPixels(best.boundingBox, srcW: srcWD, srcH: srcHD)
        }

        var textBoxes: [CGRect] = []
        if config.protectThaiText {
            if let observations = textReq.results, !observations.isEmpty {
                for obs in observations {
                    let rect = visionBoxToTopLeftPixels(obs.boundingBox, srcW: srcWD, srcH: srcHD)
                    if rect.width >= 8.0 && rect.height >= 4.0 {
                        textBoxes.append(rect)
                    }
                }
            }
            if textBoxes.isEmpty {
                textBoxes = detectHighContrastTextBands(pixelBuffer: pixelBuffer)
            }
        }

        // Compute base desired center from faces -> saliency -> bright subject centroid -> frame center
        var targetCX = srcWD * 0.5
        var targetCY = srcHD * 0.5

        if !faceRects.isEmpty {
            var unionRect = faceRects[0]
            for rect in faceRects.dropFirst() {
                unionRect = unionRect.union(rect)
            }
            targetCX = Double(unionRect.midX)
            targetCY = Double(unionRect.midY)
        } else if let salRect = saliencyBox {
            targetCX = Double(salRect.midX)
            targetCY = Double(salRect.midY)
        } else if let brightCenter = detectBrightSubjectCentroid(pixelBuffer: pixelBuffer) {
            targetCX = Double(brightCenter.x)
            targetCY = Double(brightCenter.y)
        }

        let maxCropX = max(0.0, srcWD - cropW)
        let maxCropY = max(0.0, srcHD - cropH)
        var cropX = clamp(targetCX - cropW * 0.5, min: 0.0, max: maxCropX)
        var cropY = clamp(targetCY - cropH * 0.5, min: 0.0, max: maxCropY)

        // Thai-safe text protection: adjust crop minimally so text boxes (including Thai
        // supra-/sub-baseline diacritics & tone marks) stay inside the safe crop margin.
        var textProtected = false
        if config.protectThaiText && !textBoxes.isEmpty {
            let marginRatio = clamp(config.safeMarginRatio, min: 0.0, max: 0.25)
            let marginX = cropW * marginRatio
            let marginY = cropH * marginRatio

            let expandedBoxes: [CGRect] = textBoxes.map { box in
                let thaiTopPad = Double(box.height) * 0.18
                let thaiBotPad = Double(box.height) * 0.15
                let minX = clamp(Double(box.minX), min: 0.0, max: srcWD)
                let maxX = clamp(Double(box.maxX), min: 0.0, max: srcWD)
                let minY = clamp(Double(box.minY) - thaiTopPad, min: 0.0, max: srcHD)
                let maxY = clamp(Double(box.maxY) + thaiBotPad, min: 0.0, max: srcHD)
                return CGRect(x: minX, y: minY, width: max(1.0, maxX - minX), height: max(1.0, maxY - minY))
            }

            // Pick union of text boxes that can physically fit inside the crop window,
            // or fall back to the text box closest to the subject center.
            var fittingUnion: CGRect?
            for box in expandedBoxes {
                let candidate = fittingUnion.map { $0.union(box) } ?? box
                let fitsWidth = Double(candidate.width) + 2.0 * marginX <= cropW
                let fitsHeight = Double(candidate.height) + 2.0 * marginY <= cropH
                if fitsWidth && fitsHeight {
                    fittingUnion = candidate
                }
            }

            let protectedTarget: CGRect
            if let unionRect = fittingUnion {
                protectedTarget = unionRect
            } else {
                let closest = expandedBoxes.min(by: { a, b in
                    let da = hypot(Double(a.midX) - targetCX, Double(a.midY) - targetCY)
                    let db = hypot(Double(b.midX) - targetCX, Double(b.midY) - targetCY)
                    return da < db
                }) ?? expandedBoxes[0]
                protectedTarget = closest
            }

            let origCropX = cropX
            let origCropY = cropY

            let reqMinX = Double(protectedTarget.minX) - marginX
            let reqMaxX = Double(protectedTarget.maxX) + marginX
            let boxSpanX = reqMaxX - reqMinX

            if boxSpanX <= cropW {
                if cropX > reqMinX {
                    cropX = clamp(reqMinX, min: 0.0, max: maxCropX)
                } else if (cropX + cropW) < reqMaxX {
                    cropX = clamp(reqMaxX - cropW, min: 0.0, max: maxCropX)
                }
            } else {
                // Wide text banner: pull crop center toward text horizontal center so core caption stays legible
                let textCenterX = Double(protectedTarget.midX)
                let blendedCX = 0.65 * textCenterX + 0.35 * targetCX
                cropX = clamp(blendedCX - cropW * 0.5, min: 0.0, max: maxCropX)
            }

            let reqMinY = Double(protectedTarget.minY) - marginY
            let reqMaxY = Double(protectedTarget.maxY) + marginY
            let boxSpanY = reqMaxY - reqMinY

            if maxCropY > 0.5 {
                if boxSpanY <= cropH {
                    if cropY > reqMinY {
                        cropY = clamp(reqMinY, min: 0.0, max: maxCropY)
                    } else if (cropY + cropH) < reqMaxY {
                        cropY = clamp(reqMaxY - cropH, min: 0.0, max: maxCropY)
                    }
                } else {
                    let textCenterY = Double(protectedTarget.midY)
                    let blendedCY = 0.65 * textCenterY + 0.35 * targetCY
                    cropY = clamp(blendedCY - cropH * 0.5, min: 0.0, max: maxCropY)
                }
            }

            let movedDist = hypot(cropX - origCropX, cropY - origCropY)
            if movedDist > 0.5 {
                textProtected = true
            }
        }

        return FrameDetectionResult(
            cropX: cropX,
            cropY: cropY,
            faceCount: faceRects.count,
            textBoxCount: textBoxes.count,
            textProtected: textProtected
        )
    }

    private static func visionBoxToTopLeftPixels(
        _ box: CGRect,
        srcW: Double,
        srcH: Double
    ) -> CGRect {
        let px = Double(box.minX) * srcW
        let py = (1.0 - Double(box.maxY)) * srcH
        let pw = Double(box.width) * srcW
        let ph = Double(box.height) * srcH
        return CGRect(x: px, y: py, width: max(0.0, pw), height: max(0.0, ph))
    }

    /// Fallback high-contrast horizontal text-band detector when Vision OCR returns empty
    /// (for example on stylized synthetic banners or small crisp captions).
    private static func detectHighContrastTextBands(pixelBuffer: CVPixelBuffer) -> [CGRect] {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return []
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard w >= 32, h >= 32, let rawBase = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return []
        }
        let base = rawBase.assumingMemoryBound(to: UInt8.self)

        // Compute per-row horizontal high-contrast transition counts & X bounds
        var rowTransitions = [Int](repeating: 0, count: h)
        var rowMinX = [Int](repeating: w, count: h)
        var rowMaxX = [Int](repeating: 0, count: h)

        let stepX = 2
        let edgeThreshold = 42

        for y in 0..<h {
            let rowPtr = base.advanced(by: y * bpr)
            var prevLuma = Int(rowPtr[1])
            var transitions = 0
            var minX = w
            var maxX = 0

            var x = stepX
            while x < w {
                let off = x * 4
                let b = Int(rowPtr[off])
                let g = Int(rowPtr[off + 1])
                let r = Int(rowPtr[off + 2])
                let luma = (r * 77 + g * 150 + b * 29) >> 8
                if abs(luma - prevLuma) >= edgeThreshold {
                    transitions += 1
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                }
                prevLuma = luma
                x += stepX
            }
            rowTransitions[y] = transitions
            rowMinX[y] = minX
            rowMaxX[y] = maxX
        }

        // A text row has many horizontal sharp transitions (letters/glyphs) within a horizontal band
        let minTransitions = max(6, w / 80)
        var results: [CGRect] = []
        var y = 0
        while y < h {
            if rowTransitions[y] >= minTransitions {
                let startY = y
                var endY = y
                var bandMinX = rowMinX[y]
                var bandMaxX = rowMaxX[y]
                var gap = 0
                y += 1
                while y < h {
                    if rowTransitions[y] >= minTransitions {
                        endY = y
                        if rowMinX[y] < bandMinX { bandMinX = rowMinX[y] }
                        if rowMaxX[y] > bandMaxX { bandMaxX = rowMaxX[y] }
                        gap = 0
                    } else {
                        gap += 1
                        if gap > 4 { break }
                    }
                    y += 1
                }
                let bandH = endY - startY + 1
                let bandW = bandMaxX - bandMinX
                let maxTextBandH = max(16, Int(Double(h) * 0.28))
                if bandH >= 6 && bandH <= maxTextBandH && bandW >= 16 {
                    results.append(CGRect(
                        x: Double(bandMinX),
                        y: Double(startY),
                        width: Double(bandW),
                        height: Double(bandH)
                    ))
                }
            } else {
                y += 1
            }
        }

        return results
    }

    /// Fallback bright/high-contrast subject centroid when both face and Vision saliency are absent.
    private static func detectBrightSubjectCentroid(pixelBuffer: CVPixelBuffer) -> CGPoint? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard w >= 16, h >= 16, let rawBase = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }
        let base = rawBase.assumingMemoryBound(to: UInt8.self)
        let step = 4

        var sumLuma = 0.0
        var count = 0.0
        var y = 0
        while y < h {
            let rowPtr = base.advanced(by: y * bpr)
            var x = 0
            while x < w {
                let off = x * 4
                let luma = 0.0722 * Double(rowPtr[off]) + 0.7152 * Double(rowPtr[off + 1]) + 0.2126 * Double(rowPtr[off + 2])
                sumLuma += luma
                count += 1.0
                x += step
            }
            y += step
        }
        guard count > 0 else { return nil }
        let meanLuma = sumLuma / count

        var weightSum = 0.0
        var wxSum = 0.0
        var wySum = 0.0
        y = 0
        while y < h {
            let rowPtr = base.advanced(by: y * bpr)
            var x = 0
            while x < w {
                let off = x * 4
                let luma = 0.0722 * Double(rowPtr[off]) + 0.7152 * Double(rowPtr[off + 1]) + 0.2126 * Double(rowPtr[off + 2])
                let delta = abs(luma - meanLuma)
                if delta > 25.0 {
                    let wt = delta * delta
                    weightSum += wt
                    wxSum += wt * Double(x)
                    wySum += wt * Double(y)
                }
                x += step
            }
            y += step
        }

        guard weightSum > 1e-3 else { return nil }
        return CGPoint(x: wxSum / weightSum, y: wySum / weightSum)
    }

    // MARK: - Damped Spring + Velocity-Bounded Smoothing

    private struct SmoothedResult: Sendable {
        let keyframes: [ReframeKeyframe]
        let maxVelocity: Double
    }

    private static func smoothKeyframes(
        rawSamples: [RawSampledFrame],
        srcW: Double,
        srcH: Double,
        config: SmartReframeConfig
    ) -> SmoothedResult {
        guard let first = rawSamples.first else {
            return SmoothedResult(keyframes: [], maxVelocity: 0.0)
        }

        let alpha = clamp(config.smoothingAlpha, min: 0.02, max: 1.0)
        let maxSpeed = max(10.0, config.maxPanPixelsPerSecond)
        let maxCropX = max(0.0, srcW - first.cropWidth)
        let maxCropY = max(0.0, srcH - first.cropHeight)

        // Spring stiffness and near-critical damping derived from smoothingAlpha
        let omega = 2.0 + alpha * 14.0
        let stiffness = omega * omega
        let damping = 2.0 * omega * 0.92

        var curX = clamp(first.rawCropX, min: 0.0, max: maxCropX)
        var curY = clamp(first.rawCropY, min: 0.0, max: maxCropY)
        var velX = 0.0
        var velY = 0.0
        var prevTime = first.timeSeconds
        var maxObservedVel = 0.0

        var out: [ReframeKeyframe] = []
        out.reserveCapacity(rawSamples.count)

        out.append(ReframeKeyframe(
            frameIndex: first.frameIndex,
            timeSeconds: first.timeSeconds,
            cropX: curX,
            cropY: curY,
            cropWidth: first.cropWidth,
            cropHeight: first.cropHeight,
            faceCount: first.faceCount,
            textBoxCount: first.textBoxCount,
            textProtected: first.textProtected
        ))

        for sample in rawSamples.dropFirst() {
            let dtRaw = sample.timeSeconds - prevTime
            let dt = max(1.0 / 120.0, dtRaw)
            let subSteps = max(1, min(16, Int((dt / 0.02).rounded(.up))))
            let subDt = dt / Double(subSteps)

            let startX = curX
            let startY = curY
            let targetX = clamp(sample.rawCropX, min: 0.0, max: maxCropX)
            let targetY = clamp(sample.rawCropY, min: 0.0, max: maxCropY)

            for _ in 0..<subSteps {
                let errX = targetX - curX
                let errY = targetY - curY
                let accX = stiffness * errX - damping * velX
                let accY = stiffness * errY - damping * velY
                velX += accX * subDt
                velY += accY * subDt

                let speed = hypot(velX, velY)
                if speed > maxSpeed {
                    let scale = maxSpeed / speed
                    velX *= scale
                    velY *= scale
                }

                // Blend spring step with EMA responsiveness
                let stepX = velX * subDt
                let stepY = velY * subDt
                curX = clamp(curX + stepX, min: 0.0, max: maxCropX)
                curY = clamp(curY + stepY, min: 0.0, max: maxCropY)
            }

            // Hard velocity clamp across the interval so realized pan speed never exceeds maxPanPixelsPerSecond
            let dx = curX - startX
            let dy = curY - startY
            let dist = hypot(dx, dy)
            let maxDist = maxSpeed * dt
            if dist > maxDist && dist > 1e-9 {
                let scale = maxDist / dist
                curX = clamp(startX + dx * scale, min: 0.0, max: maxCropX)
                curY = clamp(startY + dy * scale, min: 0.0, max: maxCropY)
                velX = (curX - startX) / dt
                velY = (curY - startY) / dt
            }

            let realizedDist = hypot(curX - startX, curY - startY)
            let realizedVel = realizedDist / dt
            if realizedVel > maxObservedVel {
                maxObservedVel = realizedVel
            }

            out.append(ReframeKeyframe(
                frameIndex: sample.frameIndex,
                timeSeconds: sample.timeSeconds,
                cropX: curX,
                cropY: curY,
                cropWidth: sample.cropWidth,
                cropHeight: sample.cropHeight,
                faceCount: sample.faceCount,
                textBoxCount: sample.textBoxCount,
                textProtected: sample.textProtected
            ))
            prevTime = sample.timeSeconds
        }

        return SmoothedResult(keyframes: out, maxVelocity: maxObservedVel)
    }

    private static func interpolatedCrop(
        frameIndex: Int,
        keyframes: [ReframeKeyframe]
    ) -> CGRect {
        guard let first = keyframes.first else {
            return CGRect(x: 0, y: 0, width: 2, height: 2)
        }
        if frameIndex <= first.frameIndex || keyframes.count == 1 {
            return CGRect(x: first.cropX, y: first.cropY, width: first.cropWidth, height: first.cropHeight)
        }
        if let last = keyframes.last, frameIndex >= last.frameIndex {
            return CGRect(x: last.cropX, y: last.cropY, width: last.cropWidth, height: last.cropHeight)
        }

        // Binary search for surrounding keyframes
        var lo = 0
        var hi = keyframes.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) / 2
            if keyframes[mid].frameIndex <= frameIndex {
                lo = mid
            } else {
                hi = mid
            }
        }
        let k0 = keyframes[lo]
        let k1 = keyframes[hi]
        let span = max(1, k1.frameIndex - k0.frameIndex)
        let t = Double(frameIndex - k0.frameIndex) / Double(span)
        let x = k0.cropX + (k1.cropX - k0.cropX) * t
        let y = k0.cropY + (k1.cropY - k0.cropY) * t
        return CGRect(x: x, y: y, width: k0.cropWidth, height: k0.cropHeight)
    }

    // MARK: - CoreImage Upright Helper

    private static func makeCIContext() -> CIContext {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }

    private static func uprightCIImage(
        from pixelBuffer: CVPixelBuffer,
        geometry: VideoGeometry
    ) -> CIImage {
        let base = CIImage(cvPixelBuffer: pixelBuffer)
        if geometry.isIdentityTransform {
            return base
        }
        let transformed = base.transformed(by: geometry.preferredTransform)
        let ext = transformed.extent
        let shift = CGAffineTransform(translationX: -ext.origin.x, y: -ext.origin.y)
        return transformed.transformed(by: shift)
    }

    private static func makeUprightPixelBufferIfNeeded(
        rawPB: CVPixelBuffer,
        geometry: VideoGeometry,
        ciContext: CIContext
    ) -> CVPixelBuffer {
        if geometry.isIdentityTransform {
            return rawPB
        }
        var outPB: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let st = CVPixelBufferCreate(
            kCFAllocatorDefault,
            geometry.sourceWidth,
            geometry.sourceHeight,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &outPB
        )
        guard st == kCVReturnSuccess, let dst = outPB else {
            return rawPB
        }
        let img = uprightCIImage(from: rawPB, geometry: geometry)
        let bounds = CGRect(x: 0, y: 0, width: geometry.sourceWidth, height: geometry.sourceHeight)
        ciContext.render(img, to: dst, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
        return dst
    }

    // MARK: - Render & Export (Video + Preserved Audio)

    private static func defaultBitrate(width: Int, height: Int, fps: Double) -> Int {
        let pixelsPerSec = Double(width * height) * max(15.0, fps)
        let bits = pixelsPerSec * 0.14
        return max(1_200_000, min(25_000_000, Int(bits.rounded())))
    }

    private static func renderAndExport(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?,
        audioParams: AudioStreamParams?,
        geometry: VideoGeometry,
        keyframes: [ReframeKeyframe],
        bitrate: Int?,
        outputURL: URL
    ) async throws -> Int {
        let reader = try AVAssetReader(asset: asset)

        let videoReadSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoReadSettings)
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw SafariumError.encode("SmartReframeThaiSafe: cannot add video reader output")
        }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let aTrack = audioTrack, let aParams = audioParams {
            let audioReadSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: aParams.sampleRate,
                AVNumberOfChannelsKey: aParams.channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: audioReadSettings)
            aOut.alwaysCopiesSampleData = false
            if reader.canAdd(aOut) {
                reader.add(aOut)
                audioOutput = aOut
            }
        }

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let targetBitrate = bitrate ?? defaultBitrate(
            width: geometry.outputWidth,
            height: geometry.outputHeight,
            fps: geometry.fps
        )
        let videoWriteSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: geometry.outputWidth,
            AVVideoHeightKey: geometry.outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: targetBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoWriteSettings)
        videoInput.expectsMediaDataInRealTime = false

        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: geometry.outputWidth,
            kCVPixelBufferHeightKey as String: geometry.outputHeight,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: adaptorAttrs
        )
        guard writer.canAdd(videoInput) else {
            throw SafariumError.encode("SmartReframeThaiSafe: cannot add video writer input")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil, let aParams = audioParams {
            let audioWriteSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: aParams.sampleRate,
                AVNumberOfChannelsKey: aParams.channels,
                AVEncoderBitRateKey: aParams.channels == 1 ? 96_000 : 160_000,
            ]
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioWriteSettings)
            aIn.expectsMediaDataInRealTime = false
            if writer.canAdd(aIn) {
                writer.add(aIn)
                audioInput = aIn
            }
        }

        guard reader.startReading() else {
            let msg = reader.error?.localizedDescription ?? "unknown"
            throw SafariumError.encode("SmartReframeThaiSafe: reader start failed: \(msg)")
        }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }

        guard writer.startWriting() else {
            let msg = writer.error?.localizedDescription ?? "unknown"
            throw SafariumError.encode("SmartReframeThaiSafe: writer start failed: \(msg)")
        }

        let framesProcessed = try pumpInterleavedReframe(
            reader: reader,
            videoOutput: videoOutput,
            audioOutput: audioOutput,
            writer: writer,
            videoInput: videoInput,
            adaptor: adaptor,
            audioInput: audioInput,
            geometry: geometry,
            keyframes: keyframes
        )

        await writer.finishWriting()
        guard writer.status == .completed else {
            let msg = writer.error?.localizedDescription ?? "status=\(writer.status.rawValue)"
            throw SafariumError.encode("SmartReframeThaiSafe: writer finish failed: \(msg)")
        }

        return framesProcessed
    }

    private static func pumpInterleavedReframe(
        reader: AVAssetReader,
        videoOutput: AVAssetReaderTrackOutput,
        audioOutput: AVAssetReaderTrackOutput?,
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        audioInput: AVAssetWriterInput?,
        geometry: VideoGeometry,
        keyframes: [ReframeKeyframe]
    ) throws -> Int {
        let ciContext = makeCIContext()
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let outW = geometry.outputWidth
        let outH = geometry.outputHeight
        let srcHD = Double(geometry.sourceHeight)
        let outBounds = CGRect(x: 0, y: 0, width: outW, height: outH)

        var nextVideoSB = autoreleasepool { videoOutput.copyNextSampleBuffer() }
        var nextAudioSB = (audioOutput != nil && audioInput != nil)
            ? autoreleasepool { audioOutput?.copyNextSampleBuffer() }
            : nil

        var sessionStart = CMTime.zero
        if let vSB = nextVideoSB {
            let vPTS = CMSampleBufferGetPresentationTimeStamp(vSB)
            if vPTS.isNumeric { sessionStart = vPTS }
        }
        if let aSB = nextAudioSB {
            let aPTS = CMSampleBufferGetPresentationTimeStamp(aSB)
            if aPTS.isNumeric && CMTimeCompare(aPTS, sessionStart) < 0 {
                sessionStart = aPTS
            }
        }
        writer.startSession(atSourceTime: sessionStart)

        var frameIndex = 0
        var framesWritten = 0
        var videoMarkedFinished = false
        var audioMarkedFinished = (audioInput == nil || audioOutput == nil)
        if nextVideoSB == nil {
            videoInput.markAsFinished()
            videoMarkedFinished = true
        }
        if nextAudioSB == nil && !audioMarkedFinished {
            audioInput?.markAsFinished()
            audioMarkedFinished = true
        }

        while nextVideoSB != nil || nextAudioSB != nil {
            if writer.status != .writing {
                let msg = writer.error?.localizedDescription ?? "writer stopped unexpectedly"
                throw SafariumError.encode("SmartReframeThaiSafe: \(msg)")
            }

            let vReady = (nextVideoSB != nil) && videoInput.isReadyForMoreMediaData
            let aReady = (nextAudioSB != nil) && (audioInput?.isReadyForMoreMediaData ?? false)

            if !vReady && !aReady {
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }

            let pushVideo: Bool
            if vReady && aReady, let vSB = nextVideoSB, let aSB = nextAudioSB {
                let vTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(vSB))
                let aTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(aSB))
                pushVideo = vTime <= aTime
            } else {
                pushVideo = vReady
            }

            if pushVideo, let vSB = nextVideoSB {
                if CMSampleBufferGetNumSamples(vSB) > 0, let srcPB = CMSampleBufferGetImageBuffer(vSB) {
                    let pts = CMSampleBufferGetPresentationTimeStamp(vSB)
                    let cropTopLeft = interpolatedCrop(frameIndex: frameIndex, keyframes: keyframes)

                    var dstPBOpt: CVPixelBuffer?
                    if let pool = adaptor.pixelBufferPool {
                        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dstPBOpt)
                    } else {
                        let attrs: [CFString: Any] = [
                            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
                            kCVPixelBufferMetalCompatibilityKey: true,
                        ]
                        CVPixelBufferCreate(
                            kCFAllocatorDefault,
                            outW,
                            outH,
                            kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary,
                            &dstPBOpt
                        )
                    }
                    guard let dstPB = dstPBOpt else {
                        throw SafariumError.encode("SmartReframeThaiSafe: failed to allocate output CVPixelBuffer")
                    }

                    autoreleasepool {
                        let upright = uprightCIImage(from: srcPB, geometry: geometry)
                        let ciY = max(0.0, srcHD - Double(cropTopLeft.origin.y) - Double(cropTopLeft.height))
                        let ciCropRect = CGRect(
                            x: Double(cropTopLeft.origin.x),
                            y: ciY,
                            width: Double(cropTopLeft.width),
                            height: Double(cropTopLeft.height)
                        )
                        let cropped = upright.cropped(to: ciCropRect)
                        let toOrigin = CGAffineTransform(
                            translationX: -ciCropRect.origin.x,
                            y: -ciCropRect.origin.y
                        )
                        let scaleX = Double(outW) / max(1.0, Double(ciCropRect.width))
                        let scaleY = Double(outH) / max(1.0, Double(ciCropRect.height))
                        let scaleTx = CGAffineTransform(scaleX: scaleX, y: scaleY)
                        let combinedTx = toOrigin.concatenating(scaleTx)
                        let scaled = cropped.transformed(by: combinedTx).cropped(to: outBounds)
                        ciContext.render(scaled, to: dstPB, bounds: outBounds, colorSpace: colorSpace)
                    }

                    if adaptor.append(dstPB, withPresentationTime: pts) {
                        framesWritten += 1
                    }
                    frameIndex += 1
                }
                nextVideoSB = autoreleasepool { videoOutput.copyNextSampleBuffer() }
                if nextVideoSB == nil && !videoMarkedFinished {
                    videoInput.markAsFinished()
                    videoMarkedFinished = true
                }
            } else if let aSB = nextAudioSB, let aIn = audioInput, let aOut = audioOutput {
                _ = aIn.append(aSB)
                nextAudioSB = autoreleasepool { aOut.copyNextSampleBuffer() }
                if nextAudioSB == nil && !audioMarkedFinished {
                    aIn.markAsFinished()
                    audioMarkedFinished = true
                }
            } else {
                break
            }
        }

        if !videoMarkedFinished {
            videoInput.markAsFinished()
        }
        if !audioMarkedFinished {
            audioInput?.markAsFinished()
        }

        if reader.status == .failed {
            let msg = reader.error?.localizedDescription ?? "reader failed"
            throw SafariumError.encode("SmartReframeThaiSafe: \(msg)")
        }

        return framesWritten
    }
}
