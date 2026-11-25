import Accelerate
import CoreVideo
import Foundation

/// High-throughput Apple Silicon SIMD image and color operations via Accelerate (vImage).
/// Excludes `vImageScale_ARGB8888` Lanczos5 (failed Gate 3 fidelity check vs CoreImage).
public enum SafariumAccelerate {
    /// Premultiplied BGRA8888 alpha-over blend (`dst = src over dst`) in-place on `dst`.
    public static func premultipliedAlphaBlendBGRA(
        src: UnsafeRawPointer,
        srcBytesPerRow: Int,
        dst: UnsafeMutableRawPointer,
        dstBytesPerRow: Int,
        width: Int,
        height: Int
    ) throws {
        guard width > 0, height > 0 else {
            throw SafariumError.encode("invalid blend dimensions \(width)x\(height)")
        }
        let minRow = width * 4
        guard srcBytesPerRow >= minRow, dstBytesPerRow >= minRow else {
            throw SafariumError.encode("blend row stride smaller than \(minRow) bytes")
        }
        var srcBuf = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: src),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: srcBytesPerRow
        )
        var dstBuf = vImage_Buffer(
            data: dst,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: dstBytesPerRow
        )
        let err = vImagePremultipliedAlphaBlend_BGRA8888(&srcBuf, &dstBuf, &dstBuf, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else {
            throw SafariumError.encode("vImagePremultipliedAlphaBlend_BGRA8888 failed (\(err))")
        }
    }

    /// Creates a reusable BT.709 video-range BGRA8888 -> NV12 (`420v`) conversion descriptor.
    public static func makeBT709NV12Info() throws -> vImage_ARGBToYpCbCr {
        var convInfo = vImage_ARGBToYpCbCr()
        var range = vImage_YpCbCrPixelRange(
            Yp_bias: 16, CbCr_bias: 128,
            YpRangeMax: 235, CbCrRangeMax: 240,
            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16
        )
        let err = vImageConvert_ARGBToYpCbCr_GenerateConversion(
            kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2,
            &range, &convInfo,
            kvImageARGB8888, kvImage420Yp8_CbCr8,
            vImage_Flags(kvImageNoFlags)
        )
        guard err == kvImageNoError else {
            throw SafariumError.encode("vImageConvert_ARGBToYpCbCr_GenerateConversion failed (\(err))")
        }
        return convInfo
    }

    /// Converts BGRA8888 pixel data into an NV12 (`420v`) `CVPixelBuffer` and attaches BT.709 color metadata.
    public static func convertBGRAToNV12BT709(
        bgra: UnsafeRawPointer,
        bgraBytesPerRow: Int,
        into pb: CVPixelBuffer,
        width: Int,
        height: Int,
        info: inout vImage_ARGBToYpCbCr
    ) throws {
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
            throw SafariumError.encode("NV12 requires positive even dimensions, got \(width)x\(height)")
        }
        guard bgraBytesPerRow >= width * 4 else {
            throw SafariumError.encode("NV12 source stride \(bgraBytesPerRow) < \(width * 4)")
        }
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetWidth(pb) == width,
              CVPixelBufferGetHeight(pb) == height else {
            throw SafariumError.encode("destination CVPixelBuffer is not \(width)x\(height) 420v")
        }
        guard CVPixelBufferLockBaseAddress(pb, []) == kCVReturnSuccess else {
            throw SafariumError.encode("cannot lock NV12 pixel buffer")
        }
        defer { _ = CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let yPtr = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let uvPtr = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else {
            throw SafariumError.encode("missing NV12 planes")
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        var permute: [UInt8] = [3, 2, 1, 0] // BGRA -> ARGB
        var srcBuf = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: bgra),
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: bgraBytesPerRow
        )
        var dstY = vImage_Buffer(
            data: yPtr,
            height: vImagePixelCount(height),
            width: vImagePixelCount(width),
            rowBytes: yStride
        )
        var dstCbCr = vImage_Buffer(
            data: uvPtr,
            height: vImagePixelCount(height / 2),
            width: vImagePixelCount(width / 2),
            rowBytes: uvStride
        )
        let err = vImageConvert_ARGB8888To420Yp8_CbCr8(
            &srcBuf, &dstY, &dstCbCr, &info, &permute, vImage_Flags(kvImageNoFlags)
        )
        guard err == kvImageNoError else {
            throw SafariumError.encode("vImageConvert_ARGB8888To420Yp8_CbCr8 failed (\(err))")
        }
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    @inline(__always)
    private static func processNV12LeftBand(
        srcBase: UnsafePointer<UInt8>,
        srcStride: Int,
        yBase: UnsafeMutablePointer<UInt8>,
        yStride: Int,
        uvBase: UnsafeMutablePointer<UInt8>,
        uvStride: Int,
        width: Int,
        yStart: Int,
        bandRows: Int
    ) {
        // Exact Q16 fixed-point BT.709 TV-range (Y: 16..235, Cb/Cr: 16..240)
        let halfW = width >> 1
        let evenRows = bandRows & ~1
        for localY in stride(from: 0, to: evenRows, by: 2) {
            let absY = yStart + localY
            let r0 = srcBase.advanced(by: localY * srcStride)
            let r1 = srcBase.advanced(by: (localY + 1) * srcStride)
            let yOut0 = yBase.advanced(by: absY * yStride)
            let yOut1 = yBase.advanced(by: (absY + 1) * yStride)
            let uvOut = uvBase.advanced(by: (absY >> 1) * uvStride)

            for j in 0..<halfW {
                let x0 = j << 1
                let off0 = x0 << 2
                let off1 = off0 + 4
                let offPrev = (j > 0) ? (off0 - 4) : off0

                let b00 = Int32(r0[off0]); let g00 = Int32(r0[off0 + 1]); let r00 = Int32(r0[off0 + 2])
                let b01 = Int32(r0[off1]); let g01 = Int32(r0[off1 + 1]); let r01 = Int32(r0[off1 + 2])
                let b10 = Int32(r1[off0]); let g10 = Int32(r1[off0 + 1]); let r10 = Int32(r1[off0 + 2])
                let b11 = Int32(r1[off1]); let g11 = Int32(r1[off1 + 1]); let r11 = Int32(r1[off1 + 2])
                let b0m = Int32(r0[offPrev]); let g0m = Int32(r0[offPrev + 1]); let r0m = Int32(r0[offPrev + 2])
                let b1m = Int32(r1[offPrev]); let g1m = Int32(r1[offPrev + 1]); let r1m = Int32(r1[offPrev + 2])

                let y00 = (11966 * r00 + 40254 * g00 + 4064 * b00 + 1081344) >> 16
                let y01 = (11966 * r01 + 40254 * g01 + 4064 * b01 + 1081344) >> 16
                let y10 = (11966 * r10 + 40254 * g10 + 4064 * b10 + 1081344) >> 16
                let y11 = (11966 * r11 + 40254 * g11 + 4064 * b11 + 1081344) >> 16

                yOut0[x0] = UInt8(clamping: max(16, min(235, y00)))
                yOut0[x0 + 1] = UInt8(clamping: max(16, min(235, y01)))
                yOut1[x0] = UInt8(clamping: max(16, min(235, y10)))
                yOut1[x0 + 1] = UInt8(clamping: max(16, min(235, y11)))

                // Left-cosited 4:2:0 filtering: [1, 2, 1]/4 horizontal centered at even column x0 × [1, 1]/2 vertical.
                let rL = (r0m + 2 * r00 + r01 + r1m + 2 * r10 + r11 + 4) >> 3
                let gL = (g0m + 2 * g00 + g01 + g1m + 2 * g10 + g11 + 4) >> 3
                let bL = (b0m + 2 * b00 + b01 + b1m + 2 * b10 + b11 + 4) >> 3

                let cb = (-6596 * rL - 22189 * gL + 28785 * bL + 8421376) >> 16
                let cr = (28784 * rL - 26145 * gL - 2639 * bL + 8421376) >> 16
                uvOut[x0] = UInt8(clamping: max(16, min(240, cb)))
                uvOut[x0 + 1] = UInt8(clamping: max(16, min(240, cr)))
            }
        }
    }

    private static func withLockedNV12LeftPlanes(
        pb: CVPixelBuffer,
        width: Int,
        height: Int,
        _ body: (_ yBase: UnsafeMutablePointer<UInt8>, _ yStride: Int, _ uvBase: UnsafeMutablePointer<UInt8>, _ uvStride: Int) throws -> Void
    ) throws {
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
            throw SafariumError.encode("NV12 requires positive even dimensions, got \(width)x\(height)")
        }
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
              CVPixelBufferGetWidth(pb) == width,
              CVPixelBufferGetHeight(pb) == height else {
            throw SafariumError.encode("destination CVPixelBuffer is not \(width)x\(height) 420v")
        }
        guard CVPixelBufferLockBaseAddress(pb, []) == kCVReturnSuccess else {
            throw SafariumError.encode("cannot lock NV12 pixel buffer")
        }
        defer { _ = CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt8.self),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt8.self) else {
            throw SafariumError.encode("missing NV12 planes")
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        try body(yBase, yStride, uvBase, uvStride)

        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferChromaLocationBottomFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)
    }

    /// Matrix-only Left-sited BT.709 (1-1-1 + Left chroma siting) 256-row banded raw BGRA8 -> 420v NV12.
    public static func convertRawBGRAToNV12BT709Left(
        bgra: UnsafeRawPointer,
        bgraBytesPerRow: Int,
        into pb: CVPixelBuffer,
        width: Int,
        height: Int
    ) throws {
        guard bgraBytesPerRow >= width * 4 else {
            throw SafariumError.encode("BGRA row stride \(bgraBytesPerRow) smaller than \(width * 4)")
        }
        try withLockedNV12LeftPlanes(pb: pb, width: width, height: height) { yBase, yStride, uvBase, uvStride in
            let bandHeight = 256
            let u8 = bgra.assumingMemoryBound(to: UInt8.self)
            for y0 in stride(from: 0, to: height, by: bandHeight) {
                let bh = min(bandHeight, height - y0)
                processNV12LeftBand(
                    srcBase: u8.advanced(by: y0 * bgraBytesPerRow),
                    srcStride: bgraBytesPerRow,
                    yBase: yBase, yStride: yStride,
                    uvBase: uvBase, uvStride: uvStride,
                    width: width, yStart: y0, bandRows: bh
                )
            }
        }
    }

    /// Matrix-only Left-sited BT.709 (1-1-1 + Left chroma siting) 256-row banded BGRA8 -> 420v NV12.
    /// Preserves source sRGB tone without CoreVideo's `gamma = 1/1.961` darkening warp (`Fix A`).
    public static func convertBGRAToNV12BT709LeftBanded(
        snapshot: Snapshot,
        scratchBand: CGContext?,
        into pb: CVPixelBuffer,
        width: Int,
        height: Int
    ) throws {
        try withLockedNV12LeftPlanes(pb: pb, width: width, height: height) { yBase, yStride, uvBase, uvStride in
            let bandHeight = 256
            let didBorrow = snapshot.borrowCanonicalBGRABytes(width: width, height: height) { srcPtr, srcStride in
                let u8 = srcPtr.assumingMemoryBound(to: UInt8.self)
                for y0 in stride(from: 0, to: height, by: bandHeight) {
                    let bh = min(bandHeight, height - y0)
                    processNV12LeftBand(
                        srcBase: u8.advanced(by: y0 * srcStride),
                        srcStride: srcStride,
                        yBase: yBase, yStride: yStride,
                        uvBase: uvBase, uvStride: uvStride,
                        width: width, yStart: y0, bandRows: bh
                    )
                }
                return true
            } ?? false

            if !didBorrow {
                guard let ctx = scratchBand, let bandPtr = ctx.data else {
                    throw SafariumError.encode("missing 256-row scratch CGContext for non-canonical frame")
                }
                let bandRowsCap = ctx.height & ~1
                guard bandRowsCap >= 2, bandRowsCap >= min(bandHeight, height), ctx.width >= width, ctx.bytesPerRow >= width * 4 else {
                    throw SafariumError.encode("scratch CGContext too small or odd for \(width)x\(height) banded conversion")
                }
                let u8 = bandPtr.assumingMemoryBound(to: UInt8.self)
                let bandStride = ctx.bytesPerRow
                for y0 in stride(from: 0, to: height, by: bandRowsCap) {
                    let bh = min(bandRowsCap, height - y0)
                    ctx.saveGState()
                    ctx.setBlendMode(.copy)
                    ctx.draw(snapshot.cgImage, in: CGRect(x: 0, y: ctx.height - height + y0, width: width, height: height))
                    ctx.restoreGState()
                    processNV12LeftBand(
                        srcBase: u8,
                        srcStride: bandStride,
                        yBase: yBase, yStride: yStride,
                        uvBase: uvBase, uvStride: uvStride,
                        width: width, yStart: y0, bandRows: bh
                    )
                }
            }
        }
    }
}

/// Stateful streaming ITU-R BS.1770-4 K-weighted loudness (two-stage 400 ms `-70 LUFS`/`-10 LU` gating),
/// RMS, and 4x oversampled 48-tap Kaiser polyphase true-peak meter via Accelerate (`vDSP`).
public final class LoudnessMeter {
    public let sampleRate: Double
    public let channels: Int
    public private(set) var processedFrames: Int64 = 0
    public private(set) var peakLinear: Float = 0
    public private(set) var truePeakLinear: Float = 0

    private static let blockCapacity = 4096
    private let setup: vDSP_biquad_Setup
    private var delays: [[Float]]
    private var scratch: [Float]
    private var history: [[Float]]
    private let hopFrames: Int
    private var hopSumSq: [Double]
    private var hopAccumFrames: Int = 0
    private var subblockRing: [[Double]] = []
    private var gatingBlockPowers: [Double] = []
    private var shortTermBlockPowers: [Double] = []
    private let polyTaps: [[Float]]
    private var convScratch: [Float]
    private var convInputScratch: [Float]
    private var ungatedSumSq: Double = 0
    private var unweightedSumSq: Double = 0

    public init(sampleRate: Double = 48_000, channels: Int = 1) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw SafariumError.encode("invalid sampleRate \(sampleRate)")
        }
        guard (1...2).contains(channels) else {
            throw SafariumError.encode("LoudnessMeter supports 1 or 2 channels, got \(channels)")
        }
        self.sampleRate = sampleRate
        self.channels = channels
        let coeffs = Self.kWeightingCoefficients(sampleRate: sampleRate)
        guard let bqSetup = vDSP_biquad_CreateSetup(coeffs, 2) else {
            throw SafariumError.encode("vDSP_biquad_CreateSetup failed")
        }
        self.setup = bqSetup
        self.delays = Array(repeating: [Float](repeating: 0, count: 6), count: channels)
        self.scratch = [Float](repeating: 0, count: Self.blockCapacity)
        self.history = Array(repeating: [Float](repeating: 0, count: 11), count: channels)
        self.hopFrames = max(1, Int((sampleRate * 0.1).rounded()))
        self.hopSumSq = [Double](repeating: 0, count: channels)
        self.polyTaps = Self.build48TapPolyphaseBranches(beta: 6.5, cutoff: 0.93)
        self.convScratch = [Float](repeating: 0, count: Self.blockCapacity)
        self.convInputScratch = [Float](repeating: 0, count: Self.blockCapacity + 11)
    }

    deinit {
        vDSP_biquad_DestroySetup(setup)
    }

    public var rms: Double {
        guard processedFrames > 0 else { return 0 }
        return sqrt(unweightedSumSq / Double(processedFrames * Int64(channels)))
    }

    public var samplePeakDBFS: Double {
        peakLinear > 0 ? 20.0 * log10(Double(peakLinear)) : -.infinity
    }

    public var truePeakDBTP: Double {
        truePeakLinear > 0 ? 20.0 * log10(Double(truePeakLinear)) : -.infinity
    }

    /// Raw (ungated) integrated K-weighted loudness across processed frames.
    public var ungatedLUFS: Double {
        guard processedFrames > 0, ungatedSumSq > 0 else { return -.infinity }
        return -0.691 + 10.0 * log10(ungatedSumSq / Double(processedFrames))
    }

    /// Alias preserving backward compatibility with callers expecting ungated loudness on `.lufs`.
    public var lufs: Double { ungatedLUFS }

    public var gatingMemoryBytes: Int {
        gatingBlockPowers.count * MemoryLayout<Double>.size
    }

    /// ITU-R BS.1770-4 gated integrated loudness (two-stage `-70 LUFS` / `-10 LU` 400 ms gating;
    /// falls back to `ungatedLUFS` for streams shorter than one 400 ms block).
    public var gatedLUFS: Double {
        guard !gatingBlockPowers.isEmpty else { return ungatedLUFS }
        let absThresholdPower = pow(10.0, (-70.0 + 0.691) / 10.0)
        var absSum = 0.0
        var absCount = 0
        for z in gatingBlockPowers where z > absThresholdPower {
            absSum += z
            absCount += 1
        }
        guard absCount > 0 else { return -.infinity }
        let absMean = absSum / Double(absCount)
        let relThresholdLUFS = -0.691 + 10.0 * log10(absMean) - 10.0
        let relThresholdPower = pow(10.0, (relThresholdLUFS + 0.691) / 10.0)

        var relSum = 0.0
        var relCount = 0
        for z in gatingBlockPowers where z > relThresholdPower {
            relSum += z
            relCount += 1
        }
        guard relCount > 0 else { return -.infinity }
        return -0.691 + 10.0 * log10(relSum / Double(relCount))
    }

    /// EBU R128 / Tech 3342 loudness range (`LRA`, in LU) across 3.0 s short-term blocks (`100 ms` steps).
    public var loudnessRangeLU: Double {
        guard !shortTermBlockPowers.isEmpty else { return 0.0 }
        let absThresholdPower = pow(10.0, (-70.0 + 0.691) / 10.0)
        var absSum = 0.0
        var absCount = 0
        for z in shortTermBlockPowers where z > absThresholdPower {
            absSum += z
            absCount += 1
        }
        guard absCount > 0 else { return 0.0 }
        let absMean = absSum / Double(absCount)
        let relThresholdLUFS = -0.691 + 10.0 * log10(absMean) - 20.0
        let relThresholdPower = pow(10.0, (relThresholdLUFS + 0.691) / 10.0)

        var gatedLUFSValues: [Double] = []
        gatedLUFSValues.reserveCapacity(absCount)
        for z in shortTermBlockPowers where z > relThresholdPower {
            gatedLUFSValues.append(-0.691 + 10.0 * log10(z))
        }
        guard gatedLUFSValues.count >= 2 else { return 0.0 }
        gatedLUFSValues.sort()
        let p10 = Self.interpolatedQuantile(sorted: gatedLUFSValues, fraction: 0.10)
        let p95 = Self.interpolatedQuantile(sorted: gatedLUFSValues, fraction: 0.95)
        return max(0.0, p95 - p10)
    }

    private static func interpolatedQuantile(sorted: [Double], fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0.0 }
        if sorted.count == 1 { return sorted[0] }
        let pos = fraction * Double(sorted.count - 1)
        let lo = max(0, min(sorted.count - 1, Int(floor(pos))))
        let hi = max(0, min(sorted.count - 1, Int(ceil(pos))))
        if lo == hi { return sorted[lo] }
        return sorted[lo] + (pos - Double(lo)) * (sorted[hi] - sorted[lo])
    }

    public func reset() {
        processedFrames = 0
        peakLinear = 0
        truePeakLinear = 0
        ungatedSumSq = 0
        unweightedSumSq = 0
        hopAccumFrames = 0
        subblockRing.removeAll(keepingCapacity: true)
        gatingBlockPowers.removeAll(keepingCapacity: true)
        shortTermBlockPowers.removeAll(keepingCapacity: true)
        for i in hopSumSq.indices { hopSumSq[i] = 0 }
        for i in delays.indices {
            for j in delays[i].indices { delays[i][j] = 0 }
        }
        for i in history.indices {
            for j in history[i].indices { history[i][j] = 0 }
        }
    }

    public func processMonoBlock(_ samples: UnsafeBufferPointer<Float>) {
        precondition(channels == 1, "processMonoBlock requires channels == 1")
        guard samples.baseAddress != nil, !samples.isEmpty else { return }
        processInterleaved(samples)
    }

    public func processInterleaved(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, !samples.isEmpty else { return }
        let frameCount = samples.count / channels
        guard frameCount > 0 else { return }

        var blkPeak: Float = 0
        vDSP_maxmgv(base, 1, &blkPeak, vDSP_Length(frameCount * channels))
        if blkPeak > peakLinear { peakLinear = blkPeak }
        if blkPeak > truePeakLinear { truePeakLinear = blkPeak }

        var offset = 0
        while offset < frameCount {
            let maxStep = min(Self.blockCapacity, hopFrames - hopAccumFrames)
            let take = min(maxStep, frameCount - offset)
            processStep(base: base, frameOffset: offset, take: take)
            offset += take
        }
        processedFrames += Int64(frameCount)
    }

    private func processStep(base: UnsafePointer<Float>, frameOffset: Int, take: Int) {
        var blockSq: Float = 0
        vDSP_svesq(base.advanced(by: frameOffset * channels), 1, &blockSq, vDSP_Length(take * channels))
        unweightedSumSq += Double(blockSq)

        for ch in 0..<channels {
            for h in 0..<11 { convInputScratch[h] = history[ch][h] }
            let chPtr = base.advanced(by: frameOffset * channels + ch)
            for i in 0..<take { convInputScratch[11 + i] = chPtr[i * channels] }
            for phaseIdx in 0..<3 {
                polyTaps[phaseIdx].withUnsafeBufferPointer { fPtr in
                    convInputScratch.withUnsafeBufferPointer { aPtr in
                        convScratch.withUnsafeMutableBufferPointer { cPtr in
                            vDSP_conv(aPtr.baseAddress!, 1, fPtr.baseAddress!, 1, cPtr.baseAddress!, 1, vDSP_Length(take), 12)
                            var pMax: Float = 0
                            vDSP_maxmgv(cPtr.baseAddress!, 1, &pMax, vDSP_Length(take))
                            if pMax > truePeakLinear { truePeakLinear = pMax }
                        }
                    }
                }
            }
            if take >= 11 {
                for h in 0..<11 { history[ch][h] = convInputScratch[11 + take - 11 + h] }
            } else {
                for h in 0..<(11 - take) { history[ch][h] = history[ch][h + take] }
                for h in 0..<take { history[ch][11 - take + h] = convInputScratch[11 + h] }
            }
        }

        for ch in 0..<channels {
            let ptr = base.advanced(by: frameOffset * channels + ch)
            delays[ch].withUnsafeMutableBufferPointer { delayBuf in
                scratch.withUnsafeMutableBufferPointer { outBuf in
                    vDSP_biquad(setup, delayBuf.baseAddress!, ptr, vDSP_Stride(channels), outBuf.baseAddress!, 1, vDSP_Length(take))
                    var segSq: Float = 0
                    vDSP_svesq(outBuf.baseAddress!, 1, &segSq, vDSP_Length(take))
                    ungatedSumSq += Double(segSq)
                    hopSumSq[ch] += Double(segSq)
                }
            }
        }

        hopAccumFrames += take
        if hopAccumFrames == hopFrames {
            let blockMeans = hopSumSq.map { $0 / Double(hopFrames) }
            subblockRing.append(blockMeans)
            if subblockRing.count > 30 { subblockRing.removeFirst() }
            if subblockRing.count >= 4 {
                let startIdx = subblockRing.count - 4
                var z = 0.0
                for ch in 0..<channels {
                    var sum4 = 0.0
                    for k in startIdx..<subblockRing.count { sum4 += subblockRing[k][ch] }
                    z += sum4 * 0.25
                }
                gatingBlockPowers.append(z)
            }
            if subblockRing.count == 30 {
                var z3 = 0.0
                for ch in 0..<channels {
                    var sum30 = 0.0
                    for k in 0..<30 { sum30 += subblockRing[k][ch] }
                    z3 += sum30 / 30.0
                }
                shortTermBlockPowers.append(z3)
            }
            for ch in 0..<channels { hopSumSq[ch] = 0 }
            hopAccumFrames = 0
        }
    }

    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let halfX = x * 0.5
        for k in 1...25 {
            term *= (halfX / Double(k)) * (halfX / Double(k))
            sum += term
            if term < 1e-16 * sum { break }
        }
        return sum
    }

    private static func build48TapPolyphaseBranches(beta: Double, cutoff: Double = 0.93) -> [[Float]] {
        let halfLen = 5.5
        let i0Beta = besselI0(beta)
        var branches: [[Float]] = []
        for p in 1...3 {
            let frac = Double(p) / 4.0
            var taps = [Double](repeating: 0, count: 12)
            var sum = 0.0
            for k in 0..<12 {
                let dist = (Double(k) - 5.0) - frac
                let x = cutoff * dist
                let sincVal = abs(x) < 1e-12 ? 1.0 : sin(.pi * x) / (.pi * x)
                let normPos = dist / (halfLen + 0.5)
                let arg = max(0.0, 1.0 - normPos * normPos)
                let win = besselI0(beta * sqrt(arg)) / i0Beta
                let v = sincVal * win
                taps[k] = v
                sum += v
            }
            branches.append(taps.map { Float($0 / sum) })
        }
        return branches
    }

    private static func kWeightingCoefficients(sampleRate fs: Double) -> [Double] {
        if abs(fs - 48_000.0) < 0.5 {
            // Exact ITU-R BS.1770-4 reference coefficients at 48 kHz
            return [
                1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585,
                1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621,
            ]
        }
        // Bilinear transform per ITU-R BS.1770-4 for arbitrary sample rates
        let f0Pre = 1681.974450955533
        let gDb = 3.999843853973347
        let qPre = 0.7071752369554196
        let kPre = tan(.pi * f0Pre / fs)
        let vh = pow(10.0, gDb / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        let a0Pre = 1.0 + kPre / qPre + kPre * kPre
        let b0Pre = (vh + vb * kPre / qPre + kPre * kPre) / a0Pre
        let b1Pre = 2.0 * (kPre * kPre - vh) / a0Pre
        let b2Pre = (vh - vb * kPre / qPre + kPre * kPre) / a0Pre
        let a1Pre = 2.0 * (kPre * kPre - 1.0) / a0Pre
        let a2Pre = (1.0 - kPre / qPre + kPre * kPre) / a0Pre

        let f0Rlb = 38.13547087602444
        let qRlb = 0.5003270373238773
        let kRlb = tan(.pi * f0Rlb / fs)
        let a0Rlb = 1.0 + kRlb / qRlb + kRlb * kRlb
        let b0Rlb = 1.0 / a0Rlb
        let b1Rlb = -2.0 / a0Rlb
        let b2Rlb = 1.0 / a0Rlb
        let a1Rlb = 2.0 * (kRlb * kRlb - 1.0) / a0Rlb
        let a2Rlb = (1.0 - kRlb / qRlb + kRlb * kRlb) / a0Rlb

        return [b0Pre, b1Pre, b2Pre, a1Pre, a2Pre, b0Rlb, b1Rlb, b2Rlb, a1Rlb, a2Rlb]
    }
}
