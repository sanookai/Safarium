import Accelerate
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// MARK: - Wave 15A: Native CAMBI & Perceptual Video Quality Metrics (Zero-FFmpeg)

/// Structured output of the native multiscale Contrast-Aware Banding Index (`NativeCAMBI`).
public struct NativeCAMBIResult: Codable, Sendable, Equatable {
    /// Multiscale banding score (`0.0` = banding-free, higher = more visible banding).
    public let cambiScore: Double
    /// Individual banding scores per pyramid scale (`[1x, 2x, 4x]`).
    public let scaleScores: [Double]
    /// Highest single-tile banding score observed across evaluated tiles.
    public let worstTileScore: Double
    /// Fraction of evaluated `1x` tiles exhibiting visible banding (`0.0...1.0`).
    public let bandedAreaRatio: Double
    /// Evaluated frame width in pixels.
    public let width: Int
    /// Evaluated frame height in pixels.
    public let height: Int

    public init(
        cambiScore: Double,
        scaleScores: [Double],
        worstTileScore: Double,
        bandedAreaRatio: Double,
        width: Int,
        height: Int
    ) {
        self.cambiScore = cambiScore
        self.scaleScores = scaleScores
        self.worstTileScore = worstTileScore
        self.bandedAreaRatio = bandedAreaRatio
        self.width = width
        self.height = height
    }
}

/// Authentic Netflix CAMBI-inspired multiscale banding detector implemented 100% natively in Swift.
///
/// Operates on 10-bit luma (`0...1023`), cleanly widening 8-bit luma via `v << 2` so 8-bit
/// quantization stairs appear as authentic 4-code 10-bit banding steps. Across `1x`, `2x`, and `4x`
/// box-downsampled pyramid scales, it masks out strong edges and high-frequency dither/texture,
/// evaluates localized `16x16` contour histograms for small contrast steps (`c_values`) weighted by
/// Weber/Barten dark-tone visibility, pools the worst 10% of tiles per scale, and aggregates with
/// multiscale weights `[1.0, 0.5, 0.25]`.
public enum NativeCAMBI {
    private static let scaleWeights: [Double] = [1.0, 0.5, 0.25]
    private static let windowSize: Int = 16
    private static let windowStride: Int = 8
    private static let maxEdgeGradient10Bit: Int = 20
    private static let maxBandingStep10Bit: Int = 8
    private static let tileVisibleThreshold: Double = 0.75

    /// Measures banding directly on a `CVPixelBuffer` (supports P010, NV12, BGRA8, RGBA8, ARGB8, and RGBA16F).
    public static func measure(pixelBuffer: CVPixelBuffer) -> NativeCAMBIResult {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width >= 16, height >= 16 else {
            return NativeCAMBIResult(
                cambiScore: 0.0,
                scaleScores: [0.0, 0.0, 0.0],
                worstTileScore: 0.0,
                bandedAreaRatio: 0.0,
                width: width,
                height: height
            )
        }

        let (luma, bitDepth) = extractLuma10Or8(from: pixelBuffer)
        return measureLuma(luma, width: width, height: height, bitDepth: bitDepth)
    }

    /// Measures banding on a planar luma buffer.
    ///
    /// - Parameters:
    ///   - luma: Row-major luma samples (`width * height` elements).
    ///   - width: Frame width in pixels.
    ///   - height: Frame height in pixels.
    ///   - bitDepth: Sample bit depth (`8` widens `v << 2` into 10-bit; `10` uses values in `0...1023`;
    ///     `12` shifts `v >> 2`).
    public static func measureLuma(
        _ luma: [UInt16],
        width: Int,
        height: Int,
        bitDepth: Int = 10
    ) -> NativeCAMBIResult {
        let expectedCount = width * height
        guard width >= 16, height >= 16, luma.count >= expectedCount else {
            return NativeCAMBIResult(
                cambiScore: 0.0,
                scaleScores: [0.0, 0.0, 0.0],
                worstTileScore: 0.0,
                bandedAreaRatio: 0.0,
                width: width,
                height: height
            )
        }

        // Normalize into 10-bit domain [0...1023]
        var normalizedPlane = [UInt16](repeating: 0, count: expectedCount)
        if bitDepth <= 8 {
            for i in 0..<expectedCount {
                let clamped = min(UInt16(255), luma[i])
                normalizedPlane[i] = clamped &<< 2
            }
        } else if bitDepth == 10 {
            for i in 0..<expectedCount {
                normalizedPlane[i] = min(UInt16(1023), luma[i])
            }
        } else {
            let shift = max(0, bitDepth - 10)
            for i in 0..<expectedCount {
                let shifted = luma[i] &>> shift
                normalizedPlane[i] = min(UInt16(1023), shifted)
            }
        }

        // Authentic CAMBI 2x2 sliding anti-dithering filter: preserves flat-plateau quantization
        // steps while integrating high-frequency spatial dither into smooth 10-bit levels.
        var currentPlane = antiDitheringFilter2x2(plane: normalizedPlane, width: width, height: height)

        var currentW = width
        var currentH = height
        var scaleScores: [Double] = []
        scaleScores.reserveCapacity(scaleWeights.count)
        var worstTile: Double = 0.0
        var baseBandedAreaRatio: Double = 0.0

        var hist = [Int](repeating: 0, count: 1024)

        for scaleIdx in 0..<scaleWeights.count {
            if currentW < windowSize || currentH < windowSize {
                scaleScores.append(0.0)
                continue
            }

            let eval = evaluateScale(
                plane: currentPlane,
                width: currentW,
                height: currentH,
                histogramScratch: &hist
            )
            scaleScores.append(eval.pooledScore)
            if eval.maxTileScore > worstTile {
                worstTile = eval.maxTileScore
            }
            if scaleIdx == 0 {
                baseBandedAreaRatio = eval.bandedAreaRatio
            }

            if scaleIdx + 1 < scaleWeights.count {
                let nextW = currentW / 2
                let nextH = currentH / 2
                if nextW >= windowSize && nextH >= windowSize {
                    currentPlane = downsample2x2Box(plane: currentPlane, width: currentW, height: currentH)
                    currentW = nextW
                    currentH = nextH
                } else {
                    currentW = nextW
                    currentH = nextH
                }
            }
        }

        while scaleScores.count < scaleWeights.count {
            scaleScores.append(0.0)
        }

        let s0 = scaleScores[0] * scaleWeights[0]
        let s1 = scaleScores[1] * scaleWeights[1]
        let s2 = scaleScores[2] * scaleWeights[2]
        let totalScore = s0 + s1 + s2

        return NativeCAMBIResult(
            cambiScore: totalScore,
            scaleScores: scaleScores,
            worstTileScore: worstTile,
            bandedAreaRatio: baseBandedAreaRatio,
            width: width,
            height: height
        )
    }

    // MARK: - Internal Multiscale CAMBI Core

    private struct ScaleEvalResult {
        let pooledScore: Double
        let maxTileScore: Double
        let bandedAreaRatio: Double
    }

    private static func evaluateScale(
        plane: [UInt16],
        width: Int,
        height: Int,
        histogramScratch: inout [Int]
    ) -> ScaleEvalResult {
        // Build flat/monotonic mask: 1 = candidate flat or clean monotonic contour pixel,
        // 0 = strong edge, heavy texture, or high-frequency oscillatory dither/grain.
        let count = width * height
        var flatMask = [UInt8](repeating: 0, count: count)

        for y in 1..<(height - 1) {
            let row = y * width
            let rowUp = (y - 1) * width
            let rowDn = (y + 1) * width
            for x in 1..<(width - 1) {
                let idx = row + x
                let c = Int(plane[idx])
                let l = Int(plane[idx - 1])
                let r = Int(plane[idx + 1])
                let u = Int(plane[rowUp + x])
                let d = Int(plane[rowDn + x])

                let dx = abs(r - l)
                let dy = abs(d - u)
                let grad = max(dx, dy)
                if grad > maxEdgeGradient10Bit {
                    continue
                }

                // Also reject diagonal strong edges (e.g. crisp text/UI outlines)
                let ul = Int(plane[rowUp + x - 1])
                let ur = Int(plane[rowUp + x + 1])
                let dl = Int(plane[rowDn + x - 1])
                let dr = Int(plane[rowDn + x + 1])
                let maxDiag = max(abs(dr - ul), abs(dl - ur))
                if maxDiag > maxEdgeGradient10Bit {
                    continue
                }

                // Reject high-frequency non-monotonic dither / checkerboard spikes:
                // A true banding plateau or monotonic band step is monotonic along both axes.
                let oscH = (c > l && c > r) || (c < l && c < r)
                let oscV = (c > u && c > d) || (c < u && c < d)
                if oscH || oscV {
                    // Allow tiny 1-code jitter only if 2-sided delta is <= 1; reject >= 2-code dither spikes
                    let spikeH = min(abs(c - l), abs(c - r))
                    let spikeV = min(abs(c - u), abs(c - d))
                    if spikeH >= 2 || spikeV >= 2 {
                        continue
                    }
                }

                flatMask[idx] = 1
            }
        }

        var tileScores: [Double] = []
        let estTilesX = max(1, (width - windowSize) / windowStride + 1)
        let estTilesY = max(1, (height - windowSize) / windowStride + 1)
        tileScores.reserveCapacity(estTilesX * estTilesY)

        let totalWindowPixels = Double(windowSize * windowSize)
        var maxTileScore: Double = 0.0
        var visibleBandedTiles: Int = 0

        var y0 = 0
        while y0 + windowSize <= height {
            var x0 = 0
            while x0 + windowSize <= width {
                let score = scoreWindow(
                    plane: plane,
                    flatMask: flatMask,
                    width: width,
                    x0: x0,
                    y0: y0,
                    totalWindowPixels: totalWindowPixels,
                    hist: &histogramScratch
                )
                tileScores.append(score)
                if score > maxTileScore {
                    maxTileScore = score
                }
                if score >= tileVisibleThreshold {
                    visibleBandedTiles += 1
                }
                x0 += windowStride
            }
            y0 += windowStride
        }

        guard !tileScores.isEmpty else {
            return ScaleEvalResult(pooledScore: 0.0, maxTileScore: 0.0, bandedAreaRatio: 0.0)
        }

        // Top-10% spatial pooling (authentic CAMBI pooling focuses on worst visible regions)
        tileScores.sort(by: >)
        let topCount = max(1, Int(ceil(Double(tileScores.count) * 0.10)))
        var topSum: Double = 0.0
        for i in 0..<topCount {
            topSum += tileScores[i]
        }
        let pooled = topSum / Double(topCount)
        let bandedRatio = Double(visibleBandedTiles) / Double(tileScores.count)

        return ScaleEvalResult(
            pooledScore: pooled,
            maxTileScore: maxTileScore,
            bandedAreaRatio: bandedRatio
        )
    }

    private static func scoreWindow(
        plane: [UInt16],
        flatMask: [UInt8],
        width: Int,
        x0: Int,
        y0: Int,
        totalWindowPixels: Double,
        hist: inout [Int]
    ) -> Double {
        var validCount = 0
        var minV = 1023
        var maxV = 0
        var contourTransitions = 0
        var totalValidPairs = 0

        let yEnd = y0 + windowSize
        let xEnd = x0 + windowSize

        for y in y0..<yEnd {
            let row = y * width
            for x in x0..<xEnd {
                let idx = row + x
                if flatMask[idx] == 0 {
                    continue
                }
                let v = Int(plane[idx])
                hist[v] += 1
                validCount += 1
                if v < minV { minV = v }
                if v > maxV { maxV = v }

                if x + 1 < xEnd && flatMask[idx + 1] != 0 {
                    totalValidPairs += 1
                    let d = abs(v - Int(plane[idx + 1]))
                    if d >= 1 && d <= maxBandingStep10Bit {
                        contourTransitions += 1
                    }
                }
                if y + 1 < yEnd && flatMask[idx + width] != 0 {
                    totalValidPairs += 1
                    let d = abs(v - Int(plane[idx + width]))
                    if d >= 1 && d <= maxBandingStep10Bit {
                        contourTransitions += 1
                    }
                }
            }
        }

        // Clean up touched histogram range before returning
        defer {
            if minV <= maxV {
                for v in minV...maxV {
                    hist[v] = 0
                }
            }
        }

        let validFraction = Double(validCount) / totalWindowPixels
        // Require a substantial flat/monotonic region (excludes edges, text, heavy grain, dither)
        guard validFraction >= 0.35, minV < maxV, contourTransitions > 0, totalValidPairs > 0 else {
            return 0.0
        }

        // Reject steep ramps spanning a wide dynamic range inside one 16x16 window
        let range = maxV - minV
        if range > 64 {
            return 0.0
        }

        // Count distinct populated levels and evaluate quantized step pairs (c_values = 1...8 in 10-bit)
        let invValid = 1.0 / Double(validCount)
        var rawScore: Double = 0.0

        for v in minV..<maxV {
            let countA = hist[v]
            if countA == 0 {
                continue
            }
            let pA = Double(countA) * invValid
            let maxStep = min(maxBandingStep10Bit, maxV - v)
            let visibility = lumaVisibilityWeight(luma10: v)

            for step in 1...maxStep {
                let countB = hist[v + step]
                if countB == 0 {
                    continue
                }

                // Check whether intermediate levels between v and v+step are absent (quantization gap!)
                var gapWeight: Double = 1.0
                if step >= 2 {
                    var gapCount = 0
                    for mid in (v + 1)..<(v + step) {
                        gapCount += hist[mid]
                    }
                    let pairCount = countA + countB
                    let gapRatio = Double(gapCount) / Double(max(1, pairCount))
                    if gapRatio >= 0.25 {
                        continue
                    }
                    gapWeight = 1.0 - (gapRatio * 4.0)
                }

                let pB = Double(countB) * invValid
                // Bimodal plateau product peaks at 0.25 when two flat bands split the window 50/50
                let bimodal = 4.0 * pA * pB
                let stepVis = stepContrastVisibility(step10: step)
                let contrib = bimodal * stepVis * visibility * gapWeight
                rawScore += contrib
            }
        }

        // Weight by flat-region dominance, presence of spatial step boundaries, and plateau coherence
        // (true 1D band contours have low transition fraction across flat plateaus, unlike high-frequency dither).
        let boundaryDensity = min(1.0, Double(contourTransitions) / Double(windowSize))
        let transitionFraction = Double(contourTransitions) / Double(totalValidPairs)
        let plateauCoherence = max(0.0, min(1.0, (0.30 - transitionFraction) / 0.14))
        let flatDominance = validFraction * validFraction
        let tileScore = rawScore * flatDominance * boundaryDensity * plateauCoherence * 12.0
        return tileScore
    }

    private static func stepContrastVisibility(step10: Int) -> Double {
        switch step10 {
        case 1: return 0.14
        case 2: return 0.55
        case 3: return 1.00
        case 4: return 1.65
        case 5...8: return 2.10
        default: return 0.0
        }
    }

    private static func lumaVisibilityWeight(luma10: Int) -> Double {
        // Dark-to-mid luminance banding is perceptually much more visible than bright highlights
        let excess = max(0.0, Double(luma10 - 128) / 512.0)
        return 1.0 / (1.0 + excess)
    }

    private static func antiDitheringFilter2x2(plane: [UInt16], width: Int, height: Int) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            let y1 = min(height - 1, y + 1)
            let row0 = y * width
            let row1 = y1 * width
            for x in 0..<width {
                let x1 = min(width - 1, x + 1)
                let a = Int(plane[row0 + x])
                let b = Int(plane[row0 + x1])
                let c = Int(plane[row1 + x])
                let d = Int(plane[row1 + x1])
                let avg = (a + b + c + d + 2) >> 2
                out[row0 + x] = UInt16(avg)
            }
        }
        return out
    }

    private static func downsample2x2Box(plane: [UInt16], width: Int, height: Int) -> [UInt16] {
        let outW = width / 2
        let outH = height / 2
        var out = [UInt16](repeating: 0, count: outW * outH)
        for oy in 0..<outH {
            let sy0 = (oy * 2) * width
            let sy1 = sy0 + width
            let outRow = oy * outW
            for ox in 0..<outW {
                let sx = ox * 2
                let a = Int(plane[sy0 + sx])
                let b = Int(plane[sy0 + sx + 1])
                let c = Int(plane[sy1 + sx])
                let d = Int(plane[sy1 + sx + 1])
                let avg = (a + b + c + d + 2) >> 2
                out[outRow + ox] = UInt16(avg)
            }
        }
        return out
    }

    // MARK: - Pixel Buffer Luma Extraction

    internal static func extractLuma10Or8(from pixelBuffer: CVPixelBuffer) -> ([UInt16], Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let total = width * height

        // 10-bit bi-planar YCbCr (P010 / x420 / xf20 / x422 / x444)
        if format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || format == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
                return ([UInt16](repeating: 0, count: total), 10)
            }
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let strideU16 = bpr / MemoryLayout<UInt16>.stride
            let ptr = base.assumingMemoryBound(to: UInt16.self)
            var out = [UInt16](repeating: 0, count: total)
            for y in 0..<height {
                let srcRow = y * strideU16
                let dstRow = y * width
                for x in 0..<width {
                    out[dstRow + x] = ptr[srcRow + x] &>> 6
                }
            }
            return (out, 10)
        }

        // 8-bit bi-planar YCbCr (NV12 / 420v / 420f)
        if format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
                return ([UInt16](repeating: 0, count: total), 8)
            }
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            var out = [UInt16](repeating: 0, count: total)
            for y in 0..<height {
                let srcRow = y * bpr
                let dstRow = y * width
                for x in 0..<width {
                    out[dstRow + x] = UInt16(ptr[srcRow + x])
                }
            }
            return (out, 8)
        }

        // 8-bit BGRA / RGBA / ARGB
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return ([UInt16](repeating: 0, count: total), 10)
        }
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)

        if format == kCVPixelFormatType_64RGBAHalf {
            let ptr = base.assumingMemoryBound(to: UInt16.self)
            let strideU16 = bpr / 2
            var out = [UInt16](repeating: 0, count: total)
            for y in 0..<height {
                let srcRow = y * strideU16
                let dstRow = y * width
                for x in 0..<width {
                    let r = Double(Float16(bitPattern: ptr[srcRow + x * 4 + 0]))
                    let g = Double(Float16(bitPattern: ptr[srcRow + x * 4 + 1]))
                    let b = Double(Float16(bitPattern: ptr[srcRow + x * 4 + 2]))
                    let lumaF = max(0.0, min(1.0, 0.2126 * r + 0.7152 * g + 0.0722 * b))
                    out[dstRow + x] = UInt16((lumaF * 1023.0).rounded())
                }
            }
            return (out, 10)
        }

        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt16](repeating: 0, count: total)
        let isRGBA = (format == kCVPixelFormatType_32RGBA)
        let isARGB = (format == kCVPixelFormatType_32ARGB)

        for y in 0..<height {
            let srcRow = y * bpr
            let dstRow = y * width
            for x in 0..<width {
                let off = srcRow + x * 4
                let r: Double
                let g: Double
                let b: Double
                if isRGBA {
                    r = Double(ptr[off + 0])
                    g = Double(ptr[off + 1])
                    b = Double(ptr[off + 2])
                } else if isARGB {
                    r = Double(ptr[off + 1])
                    g = Double(ptr[off + 2])
                    b = Double(ptr[off + 3])
                } else {
                    // BGRA default
                    b = Double(ptr[off + 0])
                    g = Double(ptr[off + 1])
                    r = Double(ptr[off + 2])
                }
                // Map 8-bit RGB luma cleanly into 10-bit via * 4.0 so grayscale levels g map to exact 4*g
                let luma8 = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let luma10 = max(0.0, min(1023.0, (luma8 * 4.0).rounded()))
                out[dstRow + x] = UInt16(luma10)
            }
        }
        return (out, 10)
    }
}

// MARK: - Full-Reference & Video Perceptual Evaluation

/// Aggregate perceptual quality & banding report across sampled video frames.
public struct NativePerceptualReport: Codable, Sendable, Equatable {
    public let framesSampled: Int
    public let meanCAMBI: Double
    public let p95CAMBI: Double
    public let sourceMeanCAMBI: Double?
    public let cambiDelta: Double?
    /// Overall perceptual score in `0.0...100.0` (higher is better).
    public let perceptualScore: Double
    /// Edge gradient retention ratio in `0.0...1.0` (`1.0` = sharp edges fully preserved).
    public let edgeSharpnessRetention: Double
    /// Excess halo/overshoot ringing penalty around sharp edges (`0.0` = no ringing).
    public let ringingPenalty: Double

    public init(
        framesSampled: Int,
        meanCAMBI: Double,
        p95CAMBI: Double,
        sourceMeanCAMBI: Double?,
        cambiDelta: Double?,
        perceptualScore: Double,
        edgeSharpnessRetention: Double,
        ringingPenalty: Double
    ) {
        self.framesSampled = framesSampled
        self.meanCAMBI = meanCAMBI
        self.p95CAMBI = p95CAMBI
        self.sourceMeanCAMBI = sourceMeanCAMBI
        self.cambiDelta = cambiDelta
        self.perceptualScore = perceptualScore
        self.edgeSharpnessRetention = edgeSharpnessRetention
        self.ringingPenalty = ringingPenalty
    }
}

/// Native macOS perceptual metrics combining XYB multiscale SSIM, edge sharpness retention,
/// halo/ringing detection, and `NativeCAMBI` banding evaluation.
public enum NativePerceptualMetrics {

    /// Evaluates a candidate `CVPixelBuffer` against a reference `CVPixelBuffer`.
    public static func evaluateFrame(
        reference: CVPixelBuffer,
        candidate: CVPixelBuffer
    ) -> (
        cambi: NativeCAMBIResult,
        perceptualScore: Double,
        sharpnessRetention: Double,
        ringingPenalty: Double
    ) {
        let candCAMBI = NativeCAMBI.measure(pixelBuffer: candidate)
        let refCAMBI = NativeCAMBI.measure(pixelBuffer: reference)

        let refW = CVPixelBufferGetWidth(reference)
        let refH = CVPixelBufferGetHeight(reference)
        let candW = CVPixelBufferGetWidth(candidate)
        let candH = CVPixelBufferGetHeight(candidate)
        let evalW = min(refW, candW)
        let evalH = min(refH, candH)

        guard evalW >= 8, evalH >= 8 else {
            return (candCAMBI, 100.0, 1.0, 0.0)
        }

        let refXYB = extractXYBPlanes(from: reference, targetWidth: evalW, targetHeight: evalH)
        let candXYB = extractXYBPlanes(from: candidate, targetWidth: evalW, targetHeight: evalH)

        // Multiscale structural similarity on perceptual XYB opponent channels
        let ssimY = multiScaleSSIM(refXYB.y, candXYB.y, width: evalW, height: evalH)
        let ssimX = singleScaleSSIM(refXYB.x, candXYB.x, width: evalW, height: evalH, c1: 1e-4, c2: 9e-4)
        let ssimB = singleScaleSSIM(refXYB.b, candXYB.b, width: evalW, height: evalH, c1: 1e-4, c2: 9e-4)
        let xybSSIM = 0.72 * ssimY + 0.14 * ssimX + 0.14 * ssimB

        // Edge sharpness retention & ringing/halo overshoot penalty on luma
        let (sharpnessRetention, ringingPenalty) = evaluateEdgeFidelity(
            refLuma: refXYB.luma,
            candLuma: candXYB.luma,
            width: evalW,
            height: evalH
        )

        // Combine XYB structural fidelity, banding regression, sharpness loss, and ringing
        let baseQuality = max(0.0, min(100.0, pow(max(0.0, xybSSIM), 0.75) * 100.0))
        let addedBanding = max(0.0, candCAMBI.cambiScore - refCAMBI.cambiScore)
        let bandingPenalty = min(25.0, addedBanding * 1.5)
        let sharpnessPenalty = max(0.0, (1.0 - sharpnessRetention) * 18.0)
        let clampedRinging = min(20.0, ringingPenalty)
        let finalScore = max(0.0, min(100.0, baseQuality - bandingPenalty - sharpnessPenalty - clampedRinging))

        return (
            cambi: candCAMBI,
            perceptualScore: finalScore,
            sharpnessRetention: sharpnessRetention,
            ringingPenalty: ringingPenalty
        )
    }

    /// Evaluates a video file (with optional full-reference comparison) natively via `AVAssetReader`.
    public static func evaluateVideo(
        url: URL,
        referenceURL: URL? = nil,
        maxSamples: Int = 16
    ) async throws -> NativePerceptualReport {
        let sampleLimit = max(1, maxSamples)
        let candFrames = try await readSampledFrames(from: url, maxSamples: sampleLimit)
        guard !candFrames.isEmpty else {
            throw SafariumError.encode("NativePerceptualMetrics: no readable video frames in \(url.path)")
        }

        if let refURL = referenceURL {
            let refFrames = try await readSampledFrames(from: refURL, maxSamples: candFrames.count)
            let pairCount = min(candFrames.count, refFrames.count)
            guard pairCount > 0 else {
                throw SafariumError.encode("NativePerceptualMetrics: no readable reference frames in \(refURL.path)")
            }

            var candCAMBIs: [Double] = []
            var refCAMBIs: [Double] = []
            var scores: [Double] = []
            var sharpnesses: [Double] = []
            var ringings: [Double] = []
            candCAMBIs.reserveCapacity(pairCount)
            refCAMBIs.reserveCapacity(pairCount)

            for i in 0..<pairCount {
                let refPB = refFrames[i]
                let candPB = candFrames[i]
                let refC = NativeCAMBI.measure(pixelBuffer: refPB)
                let eval = evaluateFrame(reference: refPB, candidate: candPB)
                refCAMBIs.append(refC.cambiScore)
                candCAMBIs.append(eval.cambi.cambiScore)
                scores.append(eval.perceptualScore)
                sharpnesses.append(eval.sharpnessRetention)
                ringings.append(eval.ringingPenalty)
            }

            let meanC = meanOf(candCAMBIs)
            let p95C = percentile(candCAMBIs, p: 0.95)
            let meanRefC = meanOf(refCAMBIs)
            let delta = meanC - meanRefC
            let meanScore = meanOf(scores)
            let meanSharp = meanOf(sharpnesses)
            let meanRing = meanOf(ringings)

            return NativePerceptualReport(
                framesSampled: pairCount,
                meanCAMBI: meanC,
                p95CAMBI: p95C,
                sourceMeanCAMBI: meanRefC,
                cambiDelta: delta,
                perceptualScore: meanScore,
                edgeSharpnessRetention: meanSharp,
                ringingPenalty: meanRing
            )
        } else {
            var candCAMBIs: [Double] = []
            candCAMBIs.reserveCapacity(candFrames.count)
            for pb in candFrames {
                let c = NativeCAMBI.measure(pixelBuffer: pb)
                candCAMBIs.append(c.cambiScore)
            }
            let meanC = meanOf(candCAMBIs)
            let p95C = percentile(candCAMBIs, p: 0.95)
            let nrScore = max(0.0, min(100.0, 100.0 - meanC * 2.5))

            return NativePerceptualReport(
                framesSampled: candFrames.count,
                meanCAMBI: meanC,
                p95CAMBI: p95C,
                sourceMeanCAMBI: nil,
                cambiDelta: nil,
                perceptualScore: nrScore,
                edgeSharpnessRetention: 1.0,
                ringingPenalty: 0.0
            )
        }
    }

    // MARK: - AVAssetReader Video Frame Sampler

    private static func readSampledFrames(from url: URL, maxSamples: Int) async throws -> [CVPixelBuffer] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SafariumError.invalidState("Video file not found: \(url.path)")
        }

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw SafariumError.encode("No video track found in \(url.path)")
        }

        let duration = try await asset.load(.duration)
        let nominalFPS = Double(try await videoTrack.load(.nominalFrameRate))
        let estFrames = max(1, Int((CMTimeGetSeconds(duration) * max(1.0, nominalFPS)).rounded()))
        let stride = max(1, estFrames / maxSamples)

        // Preserve 10-bit precision for 10-bit sources; otherwise decode to P010 (lossless 8->10 widening)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw SafariumError.encode("Cannot attach AVAssetReaderTrackOutput for \(url.path)")
        }
        reader.add(output)

        guard reader.startReading() else {
            let msg = reader.error?.localizedDescription ?? "unknown AVAssetReader error"
            throw SafariumError.encode("AVAssetReader failed for \(url.path): \(msg)")
        }

        var frames: [CVPixelBuffer] = []
        frames.reserveCapacity(maxSamples)
        var frameIdx = 0

        while let sample = output.copyNextSampleBuffer() {
            if frameIdx % stride == 0, let pb = CMSampleBufferGetImageBuffer(sample) {
                frames.append(pb)
                if frames.count >= maxSamples {
                    break
                }
            }
            frameIdx += 1
        }

        if reader.status == .reading {
            reader.cancelReading()
        }
        return frames
    }

    // MARK: - XYB Opponent Extraction & Structural Metrics

    private struct XYBPlanes {
        let x: [Float]
        let y: [Float]
        let b: [Float]
        let luma: [Float]
    }

    private static func extractXYBPlanes(
        from pixelBuffer: CVPixelBuffer,
        targetWidth: Int,
        targetHeight: Int
    ) -> XYBPlanes {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let count = targetWidth * targetHeight

        var xPlane = [Float](repeating: 0, count: count)
        var yPlane = [Float](repeating: 0, count: count)
        var bPlane = [Float](repeating: 0, count: count)
        var lumaPlane = [Float](repeating: 0, count: count)

        let isP010 = (format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        let isNV12 = (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let isFullRange = (format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)

        let yBaseP010 = isP010 ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt16.self) : nil
        let uvBaseP010 = isP010 ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt16.self) : nil
        let yStrideP010 = isP010 ? (CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) / 2) : 0
        let uvStrideP010 = isP010 ? (CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) / 2) : 0

        let yBaseNV12 = isNV12 ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self) : nil
        let uvBaseNV12 = isNV12 ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self) : nil
        let yStrideNV12 = isNV12 ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) : 0
        let uvStrideNV12 = isNV12 ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) : 0

        let rgbBase = (!isP010 && !isNV12) ? CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) : nil
        let rgbBpr = (!isP010 && !isNV12) ? CVPixelBufferGetBytesPerRow(pixelBuffer) : 0
        let isRGBA = (format == kCVPixelFormatType_32RGBA)
        let isARGB = (format == kCVPixelFormatType_32ARGB)

        for dy in 0..<targetHeight {
            let sy = min(srcH - 1, (dy * srcH) / targetHeight)
            let dstRow = dy * targetWidth
            for dx in 0..<targetWidth {
                let sx = min(srcW - 1, (dx * srcW) / targetWidth)
                let r: Float
                let g: Float
                let b: Float

                if let yp = yBaseP010, let uvp = uvBaseP010 {
                    let yRaw = Float(yp[sy * yStrideP010 + sx] &>> 6)
                    let cy = sy >> 1
                    let cx = (sx >> 1) * 2
                    let cbRaw = Float(uvp[cy * uvStrideP010 + cx] &>> 6)
                    let crRaw = Float(uvp[cy * uvStrideP010 + cx + 1] &>> 6)

                    let yN: Float = isFullRange ? (yRaw / 1023.0) : ((yRaw - 64.0) / 876.0)
                    let cbN: Float = isFullRange ? ((cbRaw - 512.0) / 1023.0) : ((cbRaw - 512.0) / 896.0)
                    let crN: Float = isFullRange ? ((crRaw - 512.0) / 1023.0) : ((crRaw - 512.0) / 896.0)

                    // BT.709 YCbCr -> RGB
                    r = max(0.0, min(1.0, yN + 1.5748 * crN))
                    g = max(0.0, min(1.0, yN - 0.1873 * cbN - 0.4681 * crN))
                    b = max(0.0, min(1.0, yN + 1.8556 * cbN))
                } else if let yp = yBaseNV12, let uvp = uvBaseNV12 {
                    let yRaw = Float(yp[sy * yStrideNV12 + sx])
                    let cy = sy >> 1
                    let cx = (sx >> 1) * 2
                    let cbRaw = Float(uvp[cy * uvStrideNV12 + cx])
                    let crRaw = Float(uvp[cy * uvStrideNV12 + cx + 1])

                    let yN: Float = isFullRange ? (yRaw / 255.0) : ((yRaw - 16.0) / 219.0)
                    let cbN: Float = isFullRange ? ((cbRaw - 128.0) / 255.0) : ((cbRaw - 128.0) / 224.0)
                    let crN: Float = isFullRange ? ((crRaw - 128.0) / 255.0) : ((crRaw - 128.0) / 224.0)

                    r = max(0.0, min(1.0, yN + 1.5748 * crN))
                    g = max(0.0, min(1.0, yN - 0.1873 * cbN - 0.4681 * crN))
                    b = max(0.0, min(1.0, yN + 1.8556 * cbN))
                } else if let rp = rgbBase {
                    let off = sy * rgbBpr + sx * 4
                    if isRGBA {
                        r = Float(rp[off + 0]) / 255.0
                        g = Float(rp[off + 1]) / 255.0
                        b = Float(rp[off + 2]) / 255.0
                    } else if isARGB {
                        r = Float(rp[off + 1]) / 255.0
                        g = Float(rp[off + 2]) / 255.0
                        b = Float(rp[off + 3]) / 255.0
                    } else {
                        b = Float(rp[off + 0]) / 255.0
                        g = Float(rp[off + 1]) / 255.0
                        r = Float(rp[off + 2]) / 255.0
                    }
                } else {
                    r = 0; g = 0; b = 0
                }

                // Approximate sRGB -> linear -> Opsin/XYB perceptual opponent space
                let rLin = r * r
                let gLin = g * g
                let bLin = b * b
                let bias: Float = 0.0037930732552754493
                let lVal = cbrtf(0.30 * rLin + 0.622 * gLin + 0.078 * bLin + bias)
                let mVal = cbrtf(0.23 * rLin + 0.692 * gLin + 0.078 * bLin + bias)
                let sVal = cbrtf(0.24342268924547819 * rLin + 0.20476744424496821 * gLin + 0.55180986650955360 * bLin + bias)

                let idx = dstRow + dx
                xPlane[idx] = 0.5 * (lVal - mVal)
                yPlane[idx] = 0.5 * (lVal + mVal)
                bPlane[idx] = sVal - 0.5 * (lVal + mVal)
                lumaPlane[idx] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }

        return XYBPlanes(x: xPlane, y: yPlane, b: bPlane, luma: lumaPlane)
    }

    private static func multiScaleSSIM(_ a: [Float], _ b: [Float], width: Int, height: Int) -> Double {
        let weights: [Double] = [0.50, 0.32, 0.18]
        var curA = a
        var curB = b
        var curW = width
        var curH = height
        var weightedSum: Double = 0.0
        var totalWeight: Double = 0.0

        for w in weights {
            if curW < 8 || curH < 8 {
                break
            }
            let s = singleScaleSSIM(curA, curB, width: curW, height: curH, c1: 0.0001, c2: 0.0009)
            weightedSum += s * w
            totalWeight += w

            let nextW = curW / 2
            let nextH = curH / 2
            if nextW >= 8 && nextH >= 8 {
                curA = downsampleFloat2x2(curA, width: curW, height: curH)
                curB = downsampleFloat2x2(curB, width: curW, height: curH)
                curW = nextW
                curH = nextH
            } else {
                break
            }
        }

        guard totalWeight > 0.0 else { return 1.0 }
        return max(0.0, min(1.0, weightedSum / totalWeight))
    }

    private static func singleScaleSSIM(
        _ a: [Float],
        _ b: [Float],
        width: Int,
        height: Int,
        c1: Double,
        c2: Double
    ) -> Double {
        let block = 8
        let invN = 1.0 / Double(block * block)
        var ssimSum: Double = 0.0
        var blocks: Int = 0

        var y0 = 0
        while y0 + block <= height {
            var x0 = 0
            while x0 + block <= width {
                var sumA: Double = 0.0
                var sumB: Double = 0.0
                var sumAA: Double = 0.0
                var sumBB: Double = 0.0
                var sumAB: Double = 0.0

                for dy in 0..<block {
                    let row = (y0 + dy) * width + x0
                    for dx in 0..<block {
                        let va = Double(a[row + dx])
                        let vb = Double(b[row + dx])
                        sumA += va
                        sumB += vb
                        sumAA += va * va
                        sumBB += vb * vb
                        sumAB += va * vb
                    }
                }

                let muA = sumA * invN
                let muB = sumB * invN
                let varA = max(0.0, sumAA * invN - muA * muA)
                let varB = max(0.0, sumBB * invN - muB * muB)
                let covAB = sumAB * invN - muA * muB

                let num1 = 2.0 * muA * muB + c1
                let num2 = 2.0 * covAB + c2
                let den1 = muA * muA + muB * muB + c1
                let den2 = varA + varB + c2
                let ssim = (num1 * num2) / max(1e-12, den1 * den2)

                ssimSum += max(0.0, min(1.0, ssim))
                blocks += 1
                x0 += block
            }
            y0 += block
        }

        guard blocks > 0 else { return 1.0 }
        return ssimSum / Double(blocks)
    }

    private static func downsampleFloat2x2(_ plane: [Float], width: Int, height: Int) -> [Float] {
        let outW = width / 2
        let outH = height / 2
        var out = [Float](repeating: 0, count: outW * outH)
        for oy in 0..<outH {
            let r0 = (oy * 2) * width
            let r1 = r0 + width
            let dstRow = oy * outW
            for ox in 0..<outW {
                let sx = ox * 2
                let sum = plane[r0 + sx] + plane[r0 + sx + 1] + plane[r1 + sx] + plane[r1 + sx + 1]
                out[dstRow + ox] = sum * 0.25
            }
        }
        return out
    }

    private static func evaluateEdgeFidelity(
        refLuma: [Float],
        candLuma: [Float],
        width: Int,
        height: Int
    ) -> (sharpnessRetention: Double, ringingPenalty: Double) {
        guard width >= 5, height >= 5 else {
            return (1.0, 0.0)
        }

        let count = width * height
        var refGrad = [Float](repeating: 0, count: count)
        var candGrad = [Float](repeating: 0, count: count)

        for y in 1..<(height - 1) {
            let rUp = (y - 1) * width
            let rMid = y * width
            let rDn = (y + 1) * width
            for x in 1..<(width - 1) {
                let rgx = (refLuma[rUp + x + 1] + 2.0 * refLuma[rMid + x + 1] + refLuma[rDn + x + 1])
                    - (refLuma[rUp + x - 1] + 2.0 * refLuma[rMid + x - 1] + refLuma[rDn + x - 1])
                let rgy = (refLuma[rDn + x - 1] + 2.0 * refLuma[rDn + x] + refLuma[rDn + x + 1])
                    - (refLuma[rUp + x - 1] + 2.0 * refLuma[rUp + x] + refLuma[rUp + x + 1])
                refGrad[rMid + x] = hypotf(rgx, rgy) * 0.25

                let cgx = (candLuma[rUp + x + 1] + 2.0 * candLuma[rMid + x + 1] + candLuma[rDn + x + 1])
                    - (candLuma[rUp + x - 1] + 2.0 * candLuma[rMid + x - 1] + candLuma[rDn + x - 1])
                let cgy = (candLuma[rDn + x - 1] + 2.0 * candLuma[rDn + x] + candLuma[rDn + x + 1])
                    - (candLuma[rUp + x - 1] + 2.0 * candLuma[rUp + x] + candLuma[rUp + x + 1])
                candGrad[rMid + x] = hypotf(cgx, cgy) * 0.25
            }
        }

        let edgeThreshold: Float = 0.08
        let flatThreshold: Float = 0.025
        var refEdgeSum: Double = 0.0
        var candEdgeSum: Double = 0.0
        var edgePixels: Int = 0

        var ringingExcessSum: Double = 0.0
        var haloPixels: Int = 0

        for y in 2..<(height - 2) {
            let row = y * width
            for x in 2..<(width - 2) {
                let idx = row + x
                let rg = refGrad[idx]
                let cg = candGrad[idx]

                if rg >= edgeThreshold {
                    refEdgeSum += Double(rg)
                    candEdgeSum += Double(cg)
                    edgePixels += 1
                } else if rg <= flatThreshold {
                    // Check if within 2 pixels of a strong reference edge (halo/ringing zone)
                    let nearEdge = refGrad[idx - 2] >= edgeThreshold
                        || refGrad[idx + 2] >= edgeThreshold
                        || refGrad[idx - 2 * width] >= edgeThreshold
                        || refGrad[idx + 2 * width] >= edgeThreshold
                    if nearEdge {
                        haloPixels += 1
                        let excessGrad = max(0.0, Double(cg - rg) - 0.01)
                        let excessAmp = max(0.0, abs(Double(candLuma[idx] - refLuma[idx])) - 0.012)
                        ringingExcessSum += (excessGrad + excessAmp)
                    }
                }
            }
        }

        let retention: Double
        if edgePixels > 0 && refEdgeSum > 1e-6 {
            let ratio = candEdgeSum / refEdgeSum
            retention = max(0.0, min(1.0, ratio))
        } else {
            retention = 1.0
        }

        let ringing: Double
        if haloPixels > 0 {
            ringing = (ringingExcessSum / Double(haloPixels)) * 100.0
        } else {
            ringing = 0.0
        }

        return (retention, ringing)
    }

    private static func meanOf(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.0 }
        var s: Double = 0.0
        for v in values { s += v }
        return s / Double(values.count)
    }

    private static func percentile(_ values: [Double], p: Double) -> Double {
        guard !values.isEmpty else { return 0.0 }
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * p)) - 1))
        return sorted[idx]
    }
}
