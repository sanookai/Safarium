import Accelerate
import CoreVideo
import Foundation
import SafariumCore
import XCTest

final class AccelerateTests: XCTestCase {
    func testPremultipliedAlphaBlendMatchesScalarZeroDiff() throws {
        let w = 64, h = 48
        let strideBytes = w * 4
        var src = [UInt8](repeating: 0, count: h * strideBytes)
        var dstAccel = [UInt8](repeating: 0, count: h * strideBytes)
        var dstScalar = [UInt8](repeating: 0, count: h * strideBytes)

        for y in 0..<h {
            for x in 0..<w {
                let o = y * strideBytes + x * 4
                let a: UInt8 = (x < w / 3) ? 0 : ((x < 2 * w / 3) ? 128 : 255)
                src[o] = UInt8((Int(a) * ((x * 5) & 0xFF)) / 255)
                src[o + 1] = UInt8((Int(a) * ((y * 7) & 0xFF)) / 255)
                src[o + 2] = a
                src[o + 3] = a
                dstAccel[o] = 35; dstAccel[o + 1] = 80; dstAccel[o + 2] = 140; dstAccel[o + 3] = 255
                dstScalar[o] = 35; dstScalar[o + 1] = 80; dstScalar[o + 2] = 140; dstScalar[o + 3] = 255
            }
        }

        try src.withUnsafeBytes { sRaw in
            try dstAccel.withUnsafeMutableBytes { dRaw in
                try SafariumAccelerate.premultipliedAlphaBlendBGRA(
                    src: sRaw.baseAddress!, srcBytesPerRow: strideBytes,
                    dst: dRaw.baseAddress!, dstBytesPerRow: strideBytes,
                    width: w, height: h
                )
            }
        }

        for i in stride(from: 0, to: dstScalar.count, by: 4) {
            let a = Int(src[i + 3])
            let invA = 255 - a
            dstScalar[i] = UInt8(min(255, Int(src[i]) + (Int(dstScalar[i]) * invA + 127) / 255))
            dstScalar[i + 1] = UInt8(min(255, Int(src[i + 1]) + (Int(dstScalar[i + 1]) * invA + 127) / 255))
            dstScalar[i + 2] = UInt8(min(255, Int(src[i + 2]) + (Int(dstScalar[i + 2]) * invA + 127) / 255))
            dstScalar[i + 3] = UInt8(min(255, a + (Int(dstScalar[i + 3]) * invA + 127) / 255))
        }

        var maxDiff = 0
        for i in 0..<dstAccel.count {
            maxDiff = max(maxDiff, abs(Int(dstAccel[i]) - Int(dstScalar[i])))
        }
        XCTAssertLessThanOrEqual(maxDiff, 1)
    }

    func testConvertBGRAToNV12BT709ProducesTaggedPlanes() throws {
        let w = 64, h = 64
        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                // Top half pure red, bottom half neutral mid-gray
                if y < h / 2 {
                    bgra[o] = 0; bgra[o + 1] = 0; bgra[o + 2] = 255; bgra[o + 3] = 255
                } else {
                    bgra[o] = 128; bgra[o + 1] = 128; bgra[o + 2] = 128; bgra[o + 3] = 255
                }
            }
        }

        var pbOpt: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary,
            &pbOpt
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        let pb = try XCTUnwrap(pbOpt)

        var info = try SafariumAccelerate.makeBT709NV12Info()
        try bgra.withUnsafeBytes { raw in
            try SafariumAccelerate.convertBGRAToNV12BT709(
                bgra: raw.baseAddress!, bgraBytesPerRow: w * 4,
                into: pb, width: w, height: h, info: &info
            )
        }

        let prim = CVBufferCopyAttachment(pb, kCVImageBufferColorPrimariesKey, nil) as? String
        let trans = CVBufferCopyAttachment(pb, kCVImageBufferTransferFunctionKey, nil) as? String
        let mtx = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil) as? String
        XCTAssertEqual(prim, kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        XCTAssertEqual(trans, kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        XCTAssertEqual(mtx, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let yPtr = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let uvPtr = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)

        // BT.709 red: Y ~ 63 (16 + 0.2126*219), Cb ~ 102, Cr ~ 240
        let redY = Int(yPtr[2 * yStride + 4])
        let redCb = Int(uvPtr[1 * uvStride + 4])
        let redCr = Int(uvPtr[1 * uvStride + 5])
        XCTAssertEqual(redY, 63, accuracy: 2)
        XCTAssertEqual(redCb, 102, accuracy: 3)
        XCTAssertEqual(redCr, 240, accuracy: 2)

        // Neutral gray: Cb ~ 128, Cr ~ 128
        let grayCb = Int(uvPtr[(h / 4 + 4) * uvStride + 4])
        let grayCr = Int(uvPtr[(h / 4 + 4) * uvStride + 5])
        XCTAssertEqual(grayCb, 128, accuracy: 2)
        XCTAssertEqual(grayCr, 128, accuracy: 2)
    }

    func testLoudnessMeterStatefulAcrossUnevenBlocksMatchesSinglePassAndScalar() throws {
        let sampleCount = 48_000
        var samples = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            samples[i] = 0.35 * sinf(2.0 * .pi * 997.0 * Float(i) / 48_000.0)
        }

        let singlePass = try LoudnessMeter(sampleRate: 48_000, channels: 1)
        samples.withUnsafeBufferPointer { singlePass.processMonoBlock($0) }

        let chunked = try LoudnessMeter(sampleRate: 48_000, channels: 1)
        let unevenSizes = [137, 512, 4096, 17, 1023, 3001]
        var offset = 0
        var sizeIdx = 0
        while offset < sampleCount {
            let take = min(unevenSizes[sizeIdx % unevenSizes.count], sampleCount - offset)
            samples.withUnsafeBufferPointer { ptr in
                let slice = UnsafeBufferPointer(start: ptr.baseAddress! + offset, count: take)
                chunked.processMonoBlock(slice)
            }
            offset += take
            sizeIdx += 1
        }

        XCTAssertEqual(chunked.processedFrames, Int64(sampleCount))
        XCTAssertEqual(chunked.rms, singlePass.rms, accuracy: 1e-6)
        XCTAssertEqual(chunked.lufs, singlePass.lufs, accuracy: 1e-4)
        XCTAssertEqual(chunked.peakLinear, singlePass.peakLinear, accuracy: 1e-6)

        // Independent unweighted RMS & ITU-R BS.1770 scalar reference check
        let c: [Double] = [
            1.53512485958697, -2.69169618940638, 1.19839281085285, -1.69065929318241, 0.73248077421585,
            1.0, -2.0, 1.0, -1.99004745483398, 0.99007225036621,
        ]
        var z1a = 0.0, z2a = 0.0, z1b = 0.0, z2b = 0.0, sumSq = 0.0, unweightedSumSq = 0.0
        for x0 in samples {
            let x = Double(x0)
            unweightedSumSq += x * x
            let y1 = c[0] * x + z1a
            z1a = c[1] * x - c[3] * y1 + z2a
            z2a = c[2] * x - c[4] * y1
            let y2 = c[5] * y1 + z1b
            z1b = c[6] * y1 - c[8] * y2 + z2b
            z2b = c[7] * y1 - c[9] * y2
            sumSq += y2 * y2
        }
        let scalarUnweightedRMS = sqrt(unweightedSumSq / Double(sampleCount))
        let scalarLUFS = -0.691 + 10.0 * log10(sumSq / Double(sampleCount))
        XCTAssertEqual(chunked.rms, scalarUnweightedRMS, accuracy: 1e-5)
        XCTAssertEqual(chunked.lufs, scalarLUFS, accuracy: 1e-4)

        // Stereo interleaved consistency
        var stereo = [Float](repeating: 0, count: sampleCount * 2)
        for i in 0..<sampleCount {
            stereo[i * 2] = samples[i]
            stereo[i * 2 + 1] = samples[i]
        }
        let stereoMeter = try LoudnessMeter(sampleRate: 48_000, channels: 2)
        stereo.withUnsafeBufferPointer { stereoMeter.processInterleaved($0) }
        XCTAssertEqual(stereoMeter.processedFrames, Int64(sampleCount))
        XCTAssertEqual(stereoMeter.rms, singlePass.rms, accuracy: 1e-5)
        XCTAssertEqual(stereoMeter.lufs, singlePass.lufs + 10.0 * log10(2.0), accuracy: 1e-4)
    }

    func testLoudnessMeterEmptyInput() throws {
        let meter = try LoudnessMeter(sampleRate: 48_000, channels: 1)
        XCTAssertEqual(meter.processedFrames, 0)
        XCTAssertEqual(meter.peakLinear, 0)
        XCTAssertEqual(meter.rms, 0)
        XCTAssertEqual(meter.lufs, -.infinity)
        XCTAssertEqual(meter.gatedLUFS, -.infinity)
        meter.reset()
        XCTAssertEqual(meter.lufs, -.infinity)
        XCTAssertEqual(meter.gatedLUFS, -.infinity)
        XCTAssertEqual(meter.truePeakLinear, 0)
        XCTAssertEqual(meter.gatingMemoryBytes, 0)
    }

    func testLoudnessMeterGatedBS1770And4xTruePeak() throws {
        let fs = 48_000.0
        let meter = try LoudnessMeter(sampleRate: fs, channels: 1)
        // 5s of 1 kHz 0 dBFS sine followed by 3s digital silence -> ungated drops ~2 dB, gated stays ~ -3.134 LUFS
        var blk = [Float](repeating: 0, count: 4096)
        let activeFrames = Int(5.0 * fs)
        var pos = 0
        while pos < activeFrames {
            let take = min(blk.count, activeFrames - pos)
            for i in 0..<take {
                blk[i] = sinf(Float(2.0 * .pi * 1000.0 * Double(pos + i) / fs))
            }
            blk.withUnsafeBufferPointer {
                meter.processInterleaved(UnsafeBufferPointer(start: $0.baseAddress, count: take))
            }
            pos += take
        }
        let pureSineLUFS = meter.gatedLUFS
        XCTAssertEqual(pureSineLUFS, -3.01, accuracy: 0.05)

        let silentFrames = Int(3.0 * fs)
        blk = [Float](repeating: 0, count: 4096)
        var sPos = 0
        while sPos < silentFrames {
            let take = min(blk.count, silentFrames - sPos)
            blk.withUnsafeBufferPointer {
                meter.processInterleaved(UnsafeBufferPointer(start: $0.baseAddress, count: take))
            }
            sPos += take
        }
        XCTAssertEqual(meter.gatedLUFS, -3.134, accuracy: 0.06)
        XCTAssertGreaterThan(meter.gatedLUFS - meter.ungatedLUFS, 1.5)
        XCTAssertGreaterThan(meter.gatingMemoryBytes, 0)

        // Reset must clear gating history and peak
        meter.reset()
        XCTAssertEqual(meter.gatingMemoryBytes, 0)
        XCTAssertEqual(meter.truePeakLinear, 0)

        // 12 kHz (fs/4) sine shifted by pi/4: sample peak is -3.01 dBFS, analytic true peak is 0.00 dBTP
        let tpMeter = try LoudnessMeter(sampleRate: fs, channels: 1)
        var tpBuf = [Float](repeating: 0, count: 48_000)
        for i in 0..<tpBuf.count {
            tpBuf[i] = Float(sin(2.0 * .pi * 0.25 * Double(i) + .pi / 4.0))
        }
        tpBuf.withUnsafeBufferPointer { tpMeter.processMonoBlock($0) }
        XCTAssertEqual(tpMeter.samplePeakDBFS, -3.01, accuracy: 0.05)
        XCTAssertEqual(tpMeter.truePeakDBTP, 0.0, accuracy: 0.15)
    }

    func testConvertBGRAToNV12BT709LeftBandedTagsAndMultiBandNeutralGray() throws {
        // 300 rows exercises both 256-row band + trailing 44-row partial band and scratch fallback
        let w = 64, h = 300
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: sRGB, bitmapInfo: bitmapInfo)!
        // Top band y=0..255 (CG y=44..300): neutral gray (128, 128, 128); bottom partial band: pure green (0, 255, 0)
        ctx.setFillColor(red: 128.0 / 255.0, green: 128.0 / 255.0, blue: 128.0 / 255.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 44, width: w, height: 256))
        ctx.setFillColor(red: 0.0, green: 1.0, blue: 0.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: 44))
        let snap = Snapshot(cgImage: ctx.makeImage()!)

        let scratch = CGContext(data: nil, width: w, height: 256, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: sRGB, bitmapInfo: bitmapInfo)
        var pbOpt: CVPixelBuffer?
        let st = CVPixelBufferCreate(
            kCFAllocatorDefault, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary,
            &pbOpt
        )
        XCTAssertEqual(st, kCVReturnSuccess)
        let pb = try XCTUnwrap(pbOpt)

        try SafariumAccelerate.convertBGRAToNV12BT709LeftBanded(
            snapshot: snap, scratchBand: scratch, into: pb, width: w, height: h
        )

        XCTAssertEqual(
            CVBufferCopyAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, nil) as? String,
            kCVImageBufferChromaLocation_Left as String
        )
        XCTAssertEqual(
            CVBufferCopyAttachment(pb, kCVImageBufferColorPrimariesKey, nil) as? String,
            kCVImageBufferColorPrimaries_ITU_R_709_2 as String
        )

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let yPtr = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        // Top band row 10: gray 128 -> Y = 126 (matrix-only, no 1/1.961 darkening to 116)
        XCTAssertEqual(Int(yPtr[10 * yStride + 8]), 126, accuracy: 1)
        // Bottom trailing band row 280: green (0,255,0) -> Y = 16 + round(0.7152 * 219) = 173
        XCTAssertEqual(Int(yPtr[280 * yStride + 8]), 173, accuracy: 2)
    }
}
