import Accelerate
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Vision

// MARK: - Wave 13A: SPEC Perceptual Video Analyzer

/// Classification of the transition / motion regime at the start of a shot.
public enum SceneCutType: String, Codable, Sendable, CaseIterable {
    case steady
    case hardCut
    case fade
    case flash
    case pan
    case uiTransition
}

/// Per-shot perceptual & signal-complexity telemetry produced by `SPECAnalyzer`.
public struct SPECShotMetrics: Codable, Sendable, Equatable {
    public let shotIndex: Int
    public let startFrame: Int
    public let endFrame: Int
    public let startSeconds: Double
    public let endSeconds: Double
    public let cutType: SceneCutType
    public let spatialComplexity: Double
    public let temporalComplexity: Double
    public let motionMagnitude: Double
    public let noiseSigma: Double
    public let grainProbability: Double
    public let textMaskRatio: Double
    public let faceMaskRatio: Double
    public let chromaEdgeComplexity: Double
    public let hdrHeadroom: Double
    public let bandingRisk: Double

    public init(
        shotIndex: Int,
        startFrame: Int,
        endFrame: Int,
        startSeconds: Double,
        endSeconds: Double,
        cutType: SceneCutType,
        spatialComplexity: Double,
        temporalComplexity: Double,
        motionMagnitude: Double,
        noiseSigma: Double,
        grainProbability: Double,
        textMaskRatio: Double,
        faceMaskRatio: Double,
        chromaEdgeComplexity: Double,
        hdrHeadroom: Double,
        bandingRisk: Double
    ) {
        self.shotIndex = shotIndex
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.cutType = cutType
        self.spatialComplexity = SPECAnalyzer.clamp01(spatialComplexity)
        self.temporalComplexity = SPECAnalyzer.clamp01(temporalComplexity)
        self.motionMagnitude = SPECAnalyzer.clamp01(motionMagnitude)
        self.noiseSigma = SPECAnalyzer.clamp01(noiseSigma)
        self.grainProbability = SPECAnalyzer.clamp01(grainProbability)
        self.textMaskRatio = SPECAnalyzer.clamp01(textMaskRatio)
        self.faceMaskRatio = SPECAnalyzer.clamp01(faceMaskRatio)
        self.chromaEdgeComplexity = SPECAnalyzer.clamp01(chromaEdgeComplexity)
        self.hdrHeadroom = max(1.0, hdrHeadroom)
        self.bandingRisk = SPECAnalyzer.clamp01(bandingRisk)
    }
}

/// Persistent JSON sidecar capturing a single SPEC analysis pass for reuse across
/// closed-loop tuning, multi-rung HLS ladders, and re-encodes.
public struct SPECAnalysisSidecar: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let sourcePath: String
    public let width: Int
    public let height: Int
    public let fps: Double
    public let durationSeconds: Double
    public let totalFrames: Int
    public let isHDRSource: Bool
    public let analysisElapsedMs: Double
    public let shots: [SPECShotMetrics]

    public init(
        schemaVersion: Int = 1,
        sourcePath: String,
        width: Int,
        height: Int,
        fps: Double,
        durationSeconds: Double,
        totalFrames: Int,
        isHDRSource: Bool,
        analysisElapsedMs: Double,
        shots: [SPECShotMetrics]
    ) {
        self.schemaVersion = schemaVersion
        self.sourcePath = sourcePath
        self.width = width
        self.height = height
        self.fps = fps
        self.durationSeconds = durationSeconds
        self.totalFrames = totalFrames
        self.isHDRSource = isHDRSource
        self.analysisElapsedMs = analysisElapsedMs
        self.shots = shots
    }

    /// Saves this analysis sidecar as pretty-printed, deterministic JSON.
    public func save(to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    /// Loads a previously saved SPEC analysis sidecar from disk.
    public static func load(from url: URL) throws -> SPECAnalysisSidecar {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(SPECAnalysisSidecar.self, from: data)
    }
}

/// Native Apple Silicon perceptual content & scene-transition analyzer (Wave 13A).
/// Uses `AVAssetReader` + fast subsampled luma/chroma signal estimators + native `Vision`
/// (`VNDetectTextRectanglesRequest` & `VNDetectFaceRectanglesRequest`) with zero external dependencies.
public final class SPECAnalyzer: @unchecked Sendable {

    private struct SampledFrameRecord: Sendable {
        let frameIndex: Int
        let ptsSeconds: Double
        let meanY: Double
        let p99Y: Double
        let spatialComplexity: Double
        let temporalMAD: Double
        let histDiff: Double
        let motionMagnitude: Double
        let panScore: Double
        let noiseSigma: Double
        let grainProbability: Double
        let chromaEdgeComplexity: Double
        let bandingRisk: Double
        var textMaskRatio: Double
        var faceMaskRatio: Double
        var visionSampled: Bool
        let thumb: [Float]      // 32x18 normalized luma thumbnail for flash / cut verification
        let histogram: [Double] // 32-bin normalized luma histogram
    }

    private struct VisionMaskResult: Sendable {
        let textMaskRatio: Double
        let faceMaskRatio: Double
    }

    private static let thumbWidth = 32
    private static let thumbHeight = 18
    private static let histBins = 32

    @inline(__always)
    static func clamp01(_ v: Double) -> Double {
        if !v.isFinite { return 0.0 }
        return min(1.0, max(0.0, v))
    }

    /// Analyzes a video file once and produces a reusable `SPECAnalysisSidecar`.
    public static func analyze(
        inputURL: URL,
        enableVisionMasks: Bool = true,
        maxSampleFrames: Int = 240
    ) async throws -> SPECAnalysisSidecar {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(inputURL)

        let asset = AVURLAsset(url: inputURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        ])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw SafariumError.invalidState("SPECAnalyzer: no video track in \(inputURL.lastPathComponent)")
        }

        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let transformed = naturalSize.applying(preferredTransform)
        let width = max(2, Int(abs(transformed.width).rounded()))
        let height = max(2, Int(abs(transformed.height).rounded()))

        let nominalFPS = Double(try await track.load(.nominalFrameRate))
        let fps = (nominalFPS.isFinite && nominalFPS > 0.1) ? nominalFPS : 30.0
        let duration = try await asset.load(.duration)
        let durationSeconds = max(0.001, duration.isNumeric ? duration.seconds : 0.001)

        // Inspect track format description for HDR characteristics.
        let formatDescriptions = try await track.load(.formatDescriptions)
        let isHDRSource = detectHDR(formatDescriptions: formatDescriptions)

        let estimatedFrames = max(1, Int((durationSeconds * fps).rounded()))
        let cappedMax = max(16, maxSampleFrames)
        let frameStep = max(1, Int((Double(estimatedFrames) / Double(cappedMax)).rounded(.up)))

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else {
            throw SafariumError.encode("SPECAnalyzer: AVAssetReader cannot add video track output")
        }
        reader.add(trackOutput)
        guard reader.startReading() else {
            throw SafariumError.encode(
                "SPECAnalyzer: AVAssetReader failed to start: \(reader.error?.localizedDescription ?? "unknown")"
            )
        }

        // Choose spatial subsampling stride so analysis grid stays <= ~320x240 for high speed.
        let stepX = max(1, width / 320)
        let stepY = max(1, height / 240)
        let strideStep = max(stepX, stepY)

        var records: [SampledFrameRecord] = []
        records.reserveCapacity(min(estimatedFrames, cappedMax + 8))

        var prevGridY: [Float] = []
        var prevGridW = 0
        var prevGridH = 0
        var prevProjX: [Float] = []
        var prevProjY: [Float] = []
        var prevHist: [Double] = []
        var totalFramesRead = 0
        var lastVisionPTS = -10.0

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            let currentIndex = totalFramesRead
            totalFramesRead += 1

            if frameStep > 1 && (currentIndex % frameStep != 0) {
                continue
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }
            let ptsTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let ptsSeconds = ptsTime.isNumeric ? max(0.0, ptsTime.seconds) : (Double(currentIndex) / fps)

            let analysis = analyzePixelBuffer(
                pixelBuffer,
                strideStep: strideStep,
                prevGridY: prevGridY,
                prevGridW: prevGridW,
                prevGridH: prevGridH,
                prevProjX: prevProjX,
                prevProjY: prevProjY,
                prevHist: prevHist
            )

            prevGridY = analysis.gridY
            prevGridW = analysis.gridW
            prevGridH = analysis.gridH
            prevProjX = analysis.projX
            prevProjY = analysis.projY
            prevHist = analysis.histogram

            var textRatio = 0.0
            var faceRatio = 0.0
            var ranVision = false

            if enableVisionMasks {
                let isFirst = records.isEmpty
                let timeElapsed = (ptsSeconds - lastVisionPTS) >= 0.85
                let sceneJump = analysis.temporalMAD >= 18.0 || analysis.histDiff >= 0.22
                if isFirst || timeElapsed || sceneJump {
                    let visionRes = runVisionMasks(on: pixelBuffer)
                    textRatio = visionRes.textMaskRatio
                    faceRatio = visionRes.faceMaskRatio
                    ranVision = true
                    lastVisionPTS = ptsSeconds
                }
            }

            records.append(SampledFrameRecord(
                frameIndex: currentIndex,
                ptsSeconds: ptsSeconds,
                meanY: analysis.meanY,
                p99Y: analysis.p99Y,
                spatialComplexity: analysis.spatialComplexity,
                temporalMAD: analysis.temporalMAD,
                histDiff: analysis.histDiff,
                motionMagnitude: analysis.motionMagnitude,
                panScore: analysis.panScore,
                noiseSigma: analysis.noiseSigma,
                grainProbability: analysis.grainProbability,
                chromaEdgeComplexity: analysis.chromaEdgeComplexity,
                bandingRisk: analysis.bandingRisk,
                textMaskRatio: textRatio,
                faceMaskRatio: faceRatio,
                visionSampled: ranVision,
                thumb: analysis.thumb,
                histogram: analysis.histogram
            ))
        }

        if reader.status == .failed {
            throw SafariumError.encode(
                "SPECAnalyzer: AVAssetReader failed: \(reader.error?.localizedDescription ?? "unknown")"
            )
        }

        guard !records.isEmpty else {
            throw SafariumError.invalidState("SPECAnalyzer: zero decodable video frames in \(inputURL.lastPathComponent)")
        }

        let actualTotalFrames = max(totalFramesRead, records.count)
        let actualDuration = max(durationSeconds, Double(actualTotalFrames) / fps)
        let shots = segmentAndClassifyShots(
            records: records,
            totalFrames: actualTotalFrames,
            fps: fps,
            durationSeconds: actualDuration,
            isHDRSource: isHDRSource
        )

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0
        return SPECAnalysisSidecar(
            schemaVersion: 1,
            sourcePath: inputURL.path,
            width: width,
            height: height,
            fps: fps,
            durationSeconds: actualDuration,
            totalFrames: actualTotalFrames,
            isHDRSource: isHDRSource,
            analysisElapsedMs: elapsedMs,
            shots: shots
        )
    }

    // MARK: - HDR Track Detection

    private static func detectHDR(formatDescriptions: [CMFormatDescription]) -> Bool {
        for desc in formatDescriptions {
            guard let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any] else { continue }
            if let transfer = ext[kCVImageBufferTransferFunctionKey as String] as? String {
                if transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
                    || transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) {
                    return true
                }
            }
            if let primaries = ext[kCVImageBufferColorPrimariesKey as String] as? String,
               primaries == (kCVImageBufferColorPrimaries_ITU_R_2020 as String) {
                return true
            }
        }
        return false
    }

    // MARK: - Per-Frame Signal Metrics

    private struct FrameAnalysisOutput {
        let gridY: [Float]
        let gridW: Int
        let gridH: Int
        let projX: [Float]
        let projY: [Float]
        let histogram: [Double]
        let thumb: [Float]
        let meanY: Double
        let p99Y: Double
        let spatialComplexity: Double
        let temporalMAD: Double
        let histDiff: Double
        let motionMagnitude: Double
        let panScore: Double
        let noiseSigma: Double
        let grainProbability: Double
        let chromaEdgeComplexity: Double
        let bandingRisk: Double
    }

    private static func analyzePixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        strideStep: Int,
        prevGridY: [Float],
        prevGridW: Int,
        prevGridH: Int,
        prevProjX: [Float],
        prevProjY: [Float],
        prevHist: [Double]
    ) -> FrameAnalysisOutput {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let basePtr = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self),
              width > 0, height > 0 else {
            return FrameAnalysisOutput(
                gridY: [], gridW: 0, gridH: 0, projX: [], projY: [],
                histogram: [Double](repeating: 0, count: histBins),
                thumb: [Float](repeating: 0, count: thumbWidth * thumbHeight),
                meanY: 0, p99Y: 0, spatialComplexity: 0, temporalMAD: 0, histDiff: 0,
                motionMagnitude: 0, panScore: 0, noiseSigma: 0, grainProbability: 0,
                chromaEdgeComplexity: 0, bandingRisk: 0
            )
        }

        let step = max(1, strideStep)
        let gw = max(4, (width + step - 1) / step)
        let gh = max(4, (height + step - 1) / step)
        let count = gw * gh

        var gridY = [Float](repeating: 0, count: count)
        var gridCb = [Float](repeating: 0, count: count)
        var gridCr = [Float](repeating: 0, count: count)
        var projX = [Float](repeating: 0, count: gw)
        var projY = [Float](repeating: 0, count: gh)
        var histCounts = [Int](repeating: 0, count: histBins)
        var luma256Counts = [Int](repeating: 0, count: 256)

        var sumY: Double = 0.0

        for gy in 0..<gh {
            let sy = min(height - 1, gy * step)
            let rowPtr = basePtr.advanced(by: sy * bytesPerRow)
            var rowSumY: Float = 0
            let rowBase = gy * gw

            for gx in 0..<gw {
                let sx = min(width - 1, gx * step)
                let off = sx * 4
                let b = Float(rowPtr[off])
                let g = Float(rowPtr[off + 1])
                let r = Float(rowPtr[off + 2])

                // BT.709 luminance & centered chroma
                let yVal = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let cbVal = (b - yVal) * 0.5389
                let crVal = (r - yVal) * 0.6350

                let idx = rowBase + gx
                gridY[idx] = yVal
                gridCb[idx] = cbVal
                gridCr[idx] = crVal
                projX[gx] += yVal
                rowSumY += yVal
                sumY += Double(yVal)

                let yInt = min(255, max(0, Int(yVal)))
                luma256Counts[yInt] += 1
                histCounts[min(histBins - 1, yInt >> 3)] += 1
            }
            projY[gy] = rowSumY / Float(gw)
        }
        let invGH = 1.0 / Float(gh)
        for gx in 0..<gw {
            projX[gx] *= invGH
        }

        let meanY = sumY / Double(count)
        let invCount = 1.0 / Double(count)
        var histogram = [Double](repeating: 0, count: histBins)
        for b in 0..<histBins {
            histogram[b] = Double(histCounts[b]) * invCount
        }

        // 99th percentile luma
        let targetP99 = Int(Double(count) * 0.99)
        var accumP99 = 0
        var p99Y = 255.0
        for level in 0..<256 {
            accumP99 += luma256Counts[level]
            if accumP99 >= targetP99 {
                p99Y = Double(level)
                break
            }
        }

        // Build 32x18 thumbnail for robust flash / scene-cut comparison
        var thumb = [Float](repeating: 0, count: thumbWidth * thumbHeight)
        for ty in 0..<thumbHeight {
            let gy = min(gh - 1, (ty * gh) / thumbHeight)
            let rowBase = gy * gw
            let tBase = ty * thumbWidth
            for tx in 0..<thumbWidth {
                let gx = min(gw - 1, (tx * gw) / thumbWidth)
                thumb[tBase + tx] = gridY[rowBase + gx]
            }
        }

        // Spatial gradient, Immerkaer 3x3 noise Laplacian, chroma-edge density, banding risk, grain stats
        var spatialGradSum: Double = 0
        var chromaEdgeHits = 0
        var darkSmoothGradientHits = 0
        var interiorCount = 0

        // Histogram of 3x3 Immerkaer Laplacian magnitudes (bucketed 0...255) for exact O(N) median
        var lapHist = [Int](repeating: 0, count: 256)
        var lapSumMidtone: Double = 0
        var lapCountMidtone = 0
        var lapSumShadow: Double = 0
        var lapCountShadow = 0
        var chromaLapSum: Double = 0

        for gy in 1..<(gh - 1) {
            let rowPrev = (gy - 1) * gw
            let rowCurr = gy * gw
            let rowNext = (gy + 1) * gw

            for gx in 1..<(gw - 1) {
                let idx = rowCurr + gx
                let yC = gridY[idx]
                let yL = gridY[idx - 1]
                let yR = gridY[idx + 1]
                let yU = gridY[rowPrev + gx]
                let yD = gridY[rowNext + gx]

                let gxY = abs(yR - yL)
                let gyY = abs(yD - yU)
                let gradY = Double(gxY + gyY) * 0.5
                spatialGradSum += gradY

                // Dark smooth gradient -> banding risk
                if yC < 85.0 && gradY >= 0.45 && gradY <= 12.0 {
                    darkSmoothGradientHits += 1
                }

                // Saturated chroma-edge complexity: sharp luma edge co-located with steep Cb/Cr edge
                let cbL = gridCb[idx - 1]
                let cbR = gridCb[idx + 1]
                let cbU = gridCb[rowPrev + gx]
                let cbD = gridCb[rowNext + gx]
                let crL = gridCr[idx - 1]
                let crR = gridCr[idx + 1]
                let crU = gridCr[rowPrev + gx]
                let crD = gridCr[rowNext + gx]

                let chromaGrad = Double(abs(cbR - cbL) + abs(cbD - cbU) + abs(crR - crL) + abs(crD - crU))
                let sat = Double(abs(gridCb[idx]) + abs(gridCr[idx]))
                if (gradY > 18.0 && chromaGrad > 24.0 && sat > 22.0) || (chromaGrad > 48.0 && gradY > 10.0) {
                    chromaEdgeHits += 1
                }

                // Immerkaer (1996) 3x3 noise-isolation Laplacian:
                // [ 1 -2  1 ]
                // [-2  4 -2 ]
                // [ 1 -2  1 ]
                // Vanishes identically on linear ramps and straight horizontal/vertical edges!
                let yUL = gridY[rowPrev + gx - 1]
                let yUR = gridY[rowPrev + gx + 1]
                let yDL = gridY[rowNext + gx - 1]
                let yDR = gridY[rowNext + gx + 1]
                let lapRaw = (yUL - 2.0 * yU + yUR)
                    + (-2.0 * yL + 4.0 * yC - 2.0 * yR)
                    + (yDL - 2.0 * yD + yDR)
                let lapAbs = Double(abs(lapRaw))
                let lapBin = min(255, Int((lapAbs * 0.5).rounded()))
                lapHist[lapBin] += 1

                if yC >= 45.0 && yC <= 210.0 {
                    lapSumMidtone += lapAbs
                    lapCountMidtone += 1
                } else if yC < 45.0 {
                    lapSumShadow += lapAbs
                    lapCountShadow += 1
                }

                let cbLap = abs(cbL + cbR + cbU + cbD - 4.0 * gridCb[idx])
                let crLap = abs(crL + crR + crU + crD - 4.0 * gridCr[idx])
                chromaLapSum += Double(cbLap + crLap) * 0.5

                interiorCount += 1
            }
        }

        let denom = Double(max(1, interiorCount))
        let spatialComplexity = clamp01((spatialGradSum / denom) / 38.0)
        let chromaEdgeComplexity = clamp01((Double(chromaEdgeHits) / denom) / 0.045)
        let bandingRisk = clamp01((Double(darkSmoothGradientHits) / denom) / 0.30)

        // Exact median of Immerkaer Laplacian via 256-bin histogram
        let medianTarget = interiorCount / 2
        var medianAccum = 0
        var medianBin = 0
        for b in 0..<256 {
            medianAccum += lapHist[b]
            if medianAccum >= medianTarget {
                medianBin = b
                break
            }
        }
        // Recover unscaled median |L| (stored at 0.5x scale) and convert via robust MAD factor
        let medianLap = Double(medianBin) * 2.0
        let sigmaEst = 1.4826 * (medianLap / 6.0)
        let noiseSigma = clamp01(sigmaEst / 20.0)

        // Organic film grain probability:
        // Grain is strongest in midtones with dominant luma HF vs chroma HF;
        // low-light sensor noise has strong shadow noise and/or strong chroma noise.
        let midNoise = lapCountMidtone > 0 ? (lapSumMidtone / Double(lapCountMidtone)) : 0.0
        let shadowNoise = lapCountShadow > 0 ? (lapSumShadow / Double(lapCountShadow)) : 0.0
        let meanChromaLap = chromaLapSum / denom
        var grainProbability = 0.0
        if noiseSigma > 0.10 {
            let lumaToChroma = midNoise / max(1.0, meanChromaLap * 1.4)
            let midToShadow = midNoise / max(1.0, shadowNoise + 2.0)
            let lumaDominance = clamp01((lumaToChroma - 1.1) / 2.2)
            let midtoneFactor = clamp01((midToShadow - 0.85) / 1.5)
            let strengthFactor = clamp01((noiseSigma - 0.10) / 0.35)
            grainProbability = clamp01(strengthFactor * (0.60 * lumaDominance + 0.40 * midtoneFactor))
        }

        // Temporal MAD, histogram diff, and coarse translational pan detection
        var temporalMAD = 0.0
        var histDiff = 0.0
        var motionMagnitude = 0.0
        var panScore = 0.0

        if prevGridW == gw && prevGridH == gh && prevGridY.count == count {
            var diffSum: Float = 0
            for i in 0..<count {
                diffSum += abs(gridY[i] - prevGridY[i])
            }
            temporalMAD = Double(diffSum) / Double(count)

            var hDiff = 0.0
            for b in 0..<histBins {
                hDiff += abs(histogram[b] - prevHist[b])
            }
            histDiff = 0.5 * hDiff

            let (dx, err0X, errBestX) = best1DShift(curr: projX, prev: prevProjX, maxShift: min(12, gw / 6))
            let (dy, err0Y, errBestY) = best1DShift(curr: projY, prev: prevProjY, maxShift: min(12, gh / 6))
            let shiftMag = Double(abs(dx) + abs(dy))
            let improveX = err0X > 0.5 ? max(0.0, (err0X - errBestX) / err0X) : 0.0
            let improveY = err0Y > 0.5 ? max(0.0, (err0Y - errBestY) / err0Y) : 0.0
            let bestImprove = max(improveX, improveY)

            if shiftMag >= 1.0 && bestImprove > 0.30 && temporalMAD > 2.5 && histDiff < 0.20 {
                panScore = clamp01(bestImprove * min(1.0, shiftMag / 4.0))
            }

            let madNorm = clamp01(temporalMAD / 42.0)
            let shiftNorm = clamp01(shiftMag / 10.0)
            motionMagnitude = clamp01(max(madNorm, 0.5 * madNorm + 0.5 * shiftNorm))
        }

        return FrameAnalysisOutput(
            gridY: gridY,
            gridW: gw,
            gridH: gh,
            projX: projX,
            projY: projY,
            histogram: histogram,
            thumb: thumb,
            meanY: meanY,
            p99Y: p99Y,
            spatialComplexity: spatialComplexity,
            temporalMAD: temporalMAD,
            histDiff: histDiff,
            motionMagnitude: motionMagnitude,
            panScore: panScore,
            noiseSigma: noiseSigma,
            grainProbability: grainProbability,
            chromaEdgeComplexity: chromaEdgeComplexity,
            bandingRisk: bandingRisk
        )
    }

    private static func best1DShift(
        curr: [Float],
        prev: [Float],
        maxShift: Int
    ) -> (bestShift: Int, zeroError: Double, bestError: Double) {
        let n = curr.count
        guard n >= 12, prev.count == n, maxShift >= 1 else {
            return (0, 0, 0)
        }
        let margin = maxShift
        let span = n - 2 * margin
        guard span >= 4 else { return (0, 0, 0) }

        func evalShift(_ shift: Int) -> Double {
            var sum: Float = 0
            for i in margin..<(n - margin) {
                sum += abs(curr[i] - prev[i - shift])
            }
            return Double(sum) / Double(span)
        }

        let zeroErr = evalShift(0)
        var bestShift = 0
        var bestErr = zeroErr
        for s in -maxShift...maxShift where s != 0 {
            let err = evalShift(s)
            if err < bestErr {
                bestErr = err
                bestShift = s
            }
        }
        return (bestShift, zeroErr, bestErr)
    }

    // MARK: - Native Apple Vision Text & Face Masking

    private static func runVisionMasks(on pixelBuffer: CVPixelBuffer) -> VisionMaskResult {
        autoreleasepool {
            let textReq = VNDetectTextRectanglesRequest()
            textReq.reportCharacterBoxes = false
            let faceReq = VNDetectFaceRectanglesRequest()

            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            do {
                try handler.perform([textReq, faceReq])
            } catch {
                return VisionMaskResult(textMaskRatio: 0.0, faceMaskRatio: 0.0)
            }

            var textArea = 0.0
            if let textObs = textReq.results {
                for obs in textObs {
                    let box = obs.boundingBox
                    textArea += Double(max(0, box.width) * max(0, box.height))
                }
            }

            var faceArea = 0.0
            if let faceObs = faceReq.results {
                for obs in faceObs {
                    let box = obs.boundingBox
                    faceArea += Double(max(0, box.width) * max(0, box.height))
                }
            }

            return VisionMaskResult(
                textMaskRatio: clamp01(textArea),
                faceMaskRatio: clamp01(faceArea)
            )
        }
    }

    // MARK: - Scene Cut & Transition Classification

    private static func thumbMAD(_ a: [Float], _ b: [Float]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n {
            sum += abs(a[i] - b[i])
        }
        return Double(sum) / Double(n)
    }

    private static func histogramL1(_ a: [Double], _ b: [Double]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var sum = 0.0
        for i in 0..<n {
            sum += abs(a[i] - b[i])
        }
        return 0.5 * sum
    }

    private struct RawSegment {
        let startIdx: Int
        let endIdx: Int
        let cutType: SceneCutType
    }

    private static func segmentAndClassifyShots(
        records: [SampledFrameRecord],
        totalFrames: Int,
        fps: Double,
        durationSeconds: Double,
        isHDRSource: Bool
    ) -> [SPECShotMetrics] {
        let n = records.count
        if n == 1 {
            return [
                buildShotMetrics(
                    shotIndex: 0,
                    slice: records[0...0],
                    nextStartFrame: totalFrames,
                    cutType: .steady,
                    fps: fps,
                    durationSeconds: durationSeconds,
                    isHDRSource: isHDRSource
                )
            ]
        }

        // Step 1: Identify transient 1–2 frame flashes before hard cuts.
        // A flash spikes strongly relative to frame i-1, and frame i+1 (or i+2) returns closely to i-1.
        var flashSpans: [Int: Int] = [:] // startIndex -> endIndex (inclusive)
        var i = 1
        while i < n - 1 {
            let prev = records[i - 1]
            let curr = records[i]
            let jumpMAD = thumbMAD(prev.thumb, curr.thumb)
            let jumpHist = histogramL1(prev.histogram, curr.histogram)
            let jumpLuma = abs(curr.meanY - prev.meanY)

            let isSpike = (jumpMAD >= 26.0 || jumpHist >= 0.26 || jumpLuma >= 38.0)
            if isSpike {
                // Check 1-frame flash return (i+1 matches i-1)
                let next1 = records[i + 1]
                let ret1MAD = thumbMAD(prev.thumb, next1.thumb)
                let ret1Hist = histogramL1(prev.histogram, next1.histogram)
                if ret1MAD < 14.0 && ret1Hist < 0.18 {
                    flashSpans[i] = i
                    i += 2
                    continue
                }
                // Check 2-frame flash return (i+2 matches i-1)
                if i + 2 < n {
                    let next2 = records[i + 2]
                    let ret2MAD = thumbMAD(prev.thumb, next2.thumb)
                    let ret2Hist = histogramL1(prev.histogram, next2.histogram)
                    if ret2MAD < 14.0 && ret2Hist < 0.18 {
                        flashSpans[i] = i + 1
                        i += 3
                        continue
                    }
                }
            }
            i += 1
        }

        // Step 2: Walk frames to create contiguous segments (hardCut, uiTransition, flash, fade, steady, pan).
        var segments: [RawSegment] = []
        var segStart = 0
        var segCutType: SceneCutType = .steady
        var lastNonFlashCutIdx = 0
        let minCutGap = 8

        var idx = 1
        while idx < n {
            // Transient flash span
            if let flashEnd = flashSpans[idx] {
                if segStart <= idx - 1 {
                    segments.append(RawSegment(startIdx: segStart, endIdx: idx - 1, cutType: segCutType))
                }
                segments.append(RawSegment(startIdx: idx, endIdx: flashEnd, cutType: .flash))
                segStart = flashEnd + 1
                segCutType = .steady
                idx = flashEnd + 1
                continue
            }

            let prev = records[idx - 1]
            let curr = records[idx]
            let pairMAD = curr.temporalMAD
            let pairHist = curr.histDiff
            let meanDiff = abs(curr.meanY - prev.meanY)

            // Require BOTH pixel change and global distribution / mean shift (or strong sharp step)
            // so high-motion noisy blocks do not fragment into spurious 1-frame cuts.
            let isPersistentJump = (pairMAD >= 22.0 && pairHist >= 0.24)
                || (pairHist >= 0.34 && pairMAD >= 14.0)
                || (meanDiff >= 32.0 && pairMAD >= 20.0)

            if isPersistentJump && (idx - lastNonFlashCutIdx) >= minCutGap {
                // Distinguish .uiTransition (static-to-static high-text / sharp chroma-edge jump) vs .hardCut
                let preStatic = (idx >= 2) ? (records[idx - 1].temporalMAD < 4.0) : true
                let postStatic = (idx + 1 < n) ? (records[idx + 1].temporalMAD < 4.0) : true
                let hasUI = (curr.textMaskRatio > 0.04 || prev.textMaskRatio > 0.04
                             || curr.chromaEdgeComplexity > 0.35 || prev.chromaEdgeComplexity > 0.35)
                let nextCutType: SceneCutType = (preStatic && postStatic && hasUI) ? .uiTransition : .hardCut

                if segStart <= idx - 1 {
                    segments.append(RawSegment(startIdx: segStart, endIdx: idx - 1, cutType: segCutType))
                }
                segStart = idx
                segCutType = nextCutType
                lastNonFlashCutIdx = idx
            }

            idx += 1
        }

        if segStart < n {
            segments.append(RawSegment(startIdx: segStart, endIdx: n - 1, cutType: segCutType))
        }

        // Step 3: Refine `.steady` segments to detect monotonic `.fade` or coherent `.pan`.
        var finalShots: [SPECShotMetrics] = []
        finalShots.reserveCapacity(segments.count)

        for (sIdx, seg) in segments.enumerated() {
            let slice = records[seg.startIdx...seg.endIdx]
            var refinedType = seg.cutType

            if refinedType == .steady && slice.count >= 5 {
                if isMonotonicFade(slice) {
                    refinedType = .fade
                } else {
                    let meanPan = slice.reduce(0.0) { $0 + $1.panScore } / Double(slice.count)
                    if meanPan >= 0.42 {
                        refinedType = .pan
                    }
                }
            }

            let nextStartFrame: Int
            if sIdx + 1 < segments.count {
                nextStartFrame = records[segments[sIdx + 1].startIdx].frameIndex
            } else {
                nextStartFrame = totalFrames
            }

            finalShots.append(buildShotMetrics(
                shotIndex: sIdx,
                slice: slice,
                nextStartFrame: nextStartFrame,
                cutType: refinedType,
                fps: fps,
                durationSeconds: durationSeconds,
                isHDRSource: isHDRSource
            ))
        }

        return finalShots
    }

    private static func isMonotonicFade(_ slice: ArraySlice<SampledFrameRecord>) -> Bool {
        let items = Array(slice)
        guard items.count >= 5 else { return false }
        let totalDelta = items.last!.meanY - items.first!.meanY
        guard abs(totalDelta) >= 24.0 else { return false }

        let expectedSign: Double = totalDelta > 0 ? 1.0 : -1.0
        var consistentSteps = 0
        let totalSteps = items.count - 1
        for k in 1..<items.count {
            let step = items[k].meanY - items[k - 1].meanY
            if step * expectedSign >= -0.5 && abs(step) < 22.0 {
                consistentSteps += 1
            }
        }
        return Double(consistentSteps) / Double(totalSteps) >= 0.85
    }

    private static func buildShotMetrics(
        shotIndex: Int,
        slice: ArraySlice<SampledFrameRecord>,
        nextStartFrame: Int,
        cutType: SceneCutType,
        fps: Double,
        durationSeconds: Double,
        isHDRSource: Bool
    ) -> SPECShotMetrics {
        let items = Array(slice)
        let firstRec = items.first!
        let startFrame = firstRec.frameIndex
        let endFrame = max(startFrame, nextStartFrame - 1)
        let startSeconds = firstRec.ptsSeconds
        let endSeconds = min(durationSeconds, max(startSeconds + (1.0 / fps), Double(endFrame + 1) / fps))

        let countD = Double(items.count)
        let spatial = items.reduce(0.0) { $0 + $1.spatialComplexity } / countD

        // For temporal complexity & motion within a shot, skip the cut boundary frame itself
        // when the shot has >= 2 frames so the cut jump does not falsely inflate shot motion!
        let intraItems: [SampledFrameRecord] = items.count > 1 ? Array(items.dropFirst()) : items
        let intraCount = Double(intraItems.count)
        let temporal = clamp01((intraItems.reduce(0.0) { $0 + $1.temporalMAD } / intraCount) / 42.0)
        let motion = intraItems.reduce(0.0) { $0 + $1.motionMagnitude } / intraCount

        let noise = items.reduce(0.0) { $0 + $1.noiseSigma } / countD
        let grain = items.reduce(0.0) { $0 + $1.grainProbability } / countD
        let chromaEdge = items.reduce(0.0) { $0 + $1.chromaEdgeComplexity } / countD
        let banding = items.reduce(0.0) { $0 + $1.bandingRisk } / countD

        let visionFrames = items.filter { $0.visionSampled }
        let textRatio: Double
        let faceRatio: Double
        if !visionFrames.isEmpty {
            textRatio = visionFrames.map(\.textMaskRatio).max() ?? 0.0
            faceRatio = visionFrames.map(\.faceMaskRatio).max() ?? 0.0
        } else {
            textRatio = 0.0
            faceRatio = 0.0
        }

        let peakY = items.map(\.p99Y).max() ?? 0.0
        let hdrHeadroom = isHDRSource ? max(1.0, 1.0 + 3.0 * (peakY / 255.0)) : 1.0

        return SPECShotMetrics(
            shotIndex: shotIndex,
            startFrame: startFrame,
            endFrame: endFrame,
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            cutType: cutType,
            spatialComplexity: spatial,
            temporalComplexity: temporal,
            motionMagnitude: motion,
            noiseSigma: noise,
            grainProbability: grain,
            textMaskRatio: textRatio,
            faceMaskRatio: faceRatio,
            chromaEdgeComplexity: chromaEdge,
            hdrHeadroom: hdrHeadroom,
            bandingRisk: banding
        )
    }
}
