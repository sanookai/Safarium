import CoreVideo
import Foundation
import Metal
import SafariumCore
import XCTest

/// Wave 12A — Metal Chroma Fidelity Pipeline tests.
/// Verifies zero-copy IOSurface NV12/P010 conversion, luma-guided edge-aware chroma filtering,
/// temporal IGN dithering stability, and exact masked CIEDE2000 fidelity on harsh chroma-stress patterns.
final class Wave12ChromaFidelityTests: XCTestCase {

    // MARK: - Helpers

    private func makeIOSurfacePixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) throws -> CVPixelBuffer {
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attrs as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let pixelBuffer = pb else {
            throw NSError(domain: "Wave12ChromaFidelityTests", code: Int(status))
        }
        return pixelBuffer
    }

    /// Synthesizes a harsh 320x240 chroma-stress frame:
    /// - Top band (y 0..<80): smooth dark blue -> black gradient (banding stress)
    /// - Middle band (y 80..<176): crisp saturated red/cyan thin strokes & text-like glyph grid on dark bg (edge-bleed stress)
    /// - Bottom band (y 176..<240): warm skin-tone gradient + saturated color patches
    private func synthesizeChromaStressFrame(
        width: Int = 320,
        height: Int = 240
    ) throws -> (bgra: CVPixelBuffer, textMask: [UInt8]) {
        let pb = try makeIOSurfacePixelBuffer(
            width: width,
            height: height,
            pixelFormat: kCVPixelFormatType_32BGRA
        )
        var textMask = [UInt8](repeating: 0, count: width * height)

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else {
            throw NSError(domain: "Wave12ChromaFidelityTests", code: -1)
        }
        let stride = CVPixelBufferGetBytesPerRow(pb)

        @inline(__always)
        func putPixel(_ x: Int, _ y: Int, r: UInt8, g: UInt8, b: UInt8) {
            let off = y * stride + x * 4
            base[off]     = b
            base[off + 1] = g
            base[off + 2] = r
            base[off + 3] = 255
        }

        // 1. Top band (0..<80): smooth dark blue -> black gradient (banding test).
        for y in 0..<80 {
            let fy = Double(y) / 79.0
            for x in 0..<width {
                let fx = Double(x) / Double(width - 1)
                let t = max(0.0, min(1.0, 1.0 - (0.65 * fx + 0.35 * fy)))
                let r = UInt8((4.0 * t).rounded())
                let g = UInt8((14.0 * t).rounded())
                let b = UInt8((64.0 * t).rounded())
                putPixel(x, y, r: r, g: g, b: b)
            }
        }

        // 2. Middle band (80..<176): dark backdrop + crisp saturated red & cyan thin strokes / glyph grid.
        for y in 80..<176 {
            for x in 0..<width {
                putPixel(x, y, r: 14, g: 16, b: 22)
            }
        }

        // Draw 4 crisp red & cyan text-like glyphs (2px thin strokes, mixing even and odd alignments
        // to stress both intra-block and inter-block chroma boundaries).
        let glyphCols = 4
        let cellW = 54
        let startX = 63
        for idx in 0..<glyphCols {
            let gx = startX + idx * cellW
            let gy = 101
            let isRed = (idx % 2 == 0)
            let cr: UInt8 = isRed ? 235 : 22
            let cg: UInt8 = isRed ? 24  : 224
            let cb: UInt8 = isRed ? 24  : 236

            for dy in 0..<18 {
                for dx in 0..<10 {
                    let isVerticalStem = (dx == 0 || dx == 1 || dx == 8 || dx == 9)
                    let isTopOrMidBar  = (dy == 0 || dy == 1 || dy == 8 || dy == 9)
                    let isBottomBar    = (idx % 2 == 1) && (dy == 16 || dy == 17)
                    if isVerticalStem || isTopOrMidBar || isBottomBar {
                        let px = gx + dx
                        let py = gy + dy
                        putPixel(px, py, r: cr, g: cg, b: cb)
                        // Mark stroke and 1px halo in textMask to catch edge bleed too.
                        for hy in max(80, py - 1)...min(175, py + 1) {
                            for hx in max(0, px - 1)...min(width - 1, px + 1) {
                                textMask[hy * width + hx] = 1
                            }
                        }
                    }
                }
            }
        }

        // Crisp 2px horizontal red & cyan thin strokes (odd-aligned and even-aligned).
        for x in 100..<220 {
            for y in 141..<143 {
                putPixel(x, y, r: 235, g: 24, b: 24)
                textMask[y * width + x] = 1
            }
            for y in 152..<154 {
                putPixel(x, y, r: 22, g: 224, b: 236)
                textMask[y * width + x] = 1
            }
        }

        // 3. Bottom band (176..<240): warm skin-tone gradient with smooth transition from backdrop.
        for y in 176..<height {
            let fy = Double(y - 176) / Double(height - 177)
            let blend = min(1.0, Double(y - 176) / 6.0)
            for x in 0..<width {
                let fx = Double(x) / Double(width - 1)
                let skinR = 216.0 - 44.0 * fx - 10.0 * fy
                let skinG = 166.0 - 46.0 * fx - 10.0 * fy
                let skinB = 136.0 - 42.0 * fx - 8.0 * fy
                let r = UInt8((14.0 * (1.0 - blend) + skinR * blend).rounded())
                let g = UInt8((16.0 * (1.0 - blend) + skinG * blend).rounded())
                let b = UInt8((22.0 * (1.0 - blend) + skinB * blend).rounded())
                putPixel(x, y, r: r, g: g, b: b)
            }
        }

        return (pb, textMask)
    }

    // MARK: - Tests

    func testP010LumaGuidedEdgeAwareChromaFidelity() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal GPU device available on this host")
        }

        let pipeline = try MetalChromaPipeline()
        let (srcBGRA, textMask) = try synthesizeChromaStressFrame()

        let p010Edge = try makeIOSurfacePixelBuffer(
            width: 320,
            height: 240,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        let reconEdge = try makeIOSurfacePixelBuffer(
            width: 320,
            height: 240,
            pixelFormat: kCVPixelFormatType_32BGRA
        )

        let edgeConfig = ChromaConversionConfig(
            bitDepth: 10,
            siting: .coSited,
            filterMode: .lumaGuidedEdgeAware,
            ditherMode: .temporalInterleavedGradient,
            isBT2020: false,
            fullRange: false,
            frameIndex: 0
        )
        try pipeline.convertBGRAtoYUV(src: srcBGRA, dst: p010Edge, config: edgeConfig)
        try pipeline.reconstructYUVtoBGRA(srcYUV: p010Edge, dstBGRA: reconEdge, config: edgeConfig)

        let edgeReport = try MetalChromaPipeline.measureMaskedDeltaE00(
            referenceBGRA: srcBGRA,
            candidateBGRA: reconEdge,
            textMask: textMask
        )

        // Compare against naive box-average baseline.
        let p010Box = try makeIOSurfacePixelBuffer(
            width: 320,
            height: 240,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        let reconBox = try makeIOSurfacePixelBuffer(
            width: 320,
            height: 240,
            pixelFormat: kCVPixelFormatType_32BGRA
        )
        let boxConfig = ChromaConversionConfig(
            bitDepth: 10,
            siting: .coSited,
            filterMode: .boxAverage,
            ditherMode: .none,
            isBT2020: false,
            fullRange: false,
            frameIndex: 0
        )
        try pipeline.convertBGRAtoYUV(src: srcBGRA, dst: p010Box, config: boxConfig)
        try pipeline.reconstructYUVtoBGRA(srcYUV: p010Box, dstBGRA: reconBox, config: boxConfig)

        let boxReport = try MetalChromaPipeline.measureMaskedDeltaE00(
            referenceBGRA: srcBGRA,
            candidateBGRA: reconBox,
            textMask: textMask
        )

        print(String(
            format: "[Wave12A P010] EdgeAware mean=%.4f p95=%.4f p99=%.4f satEdgeP95=%.4f textP95=%.4f | Box mean=%.4f p95=%.4f satEdgeP95=%.4f textP95=%.4f",
            edgeReport.meanDeltaE00, edgeReport.p95DeltaE00, edgeReport.p99DeltaE00,
            edgeReport.saturatedEdgeP95DeltaE00, edgeReport.textRegionP95DeltaE00,
            boxReport.meanDeltaE00, boxReport.p95DeltaE00,
            boxReport.saturatedEdgeP95DeltaE00, boxReport.textRegionP95DeltaE00
        ))

        XCTAssertLessThan(edgeReport.meanDeltaE00, 1.0, "P010 meanDeltaE00 should be < 1.0")
        XCTAssertLessThanOrEqual(edgeReport.p95DeltaE00, 2.0, "P010 p95DeltaE00 should be <= 2.0")
        XCTAssertLessThanOrEqual(
            edgeReport.saturatedEdgeP95DeltaE00,
            boxReport.saturatedEdgeP95DeltaE00,
            "Luma-guided edge-aware chroma must be strictly better or equal on saturated edges vs box-average"
        )
        XCTAssertLessThanOrEqual(
            edgeReport.meanDeltaE00,
            boxReport.meanDeltaE00 + 0.05,
            "Edge-aware mode must not degrade global meanDeltaE00"
        )
    }

    func testNV12EightBitChromaFidelityAndMetadata() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal GPU device available on this host")
        }

        let pipeline = try MetalChromaPipeline()
        let (srcBGRA, textMask) = try synthesizeChromaStressFrame()

        let nv12 = try makeIOSurfacePixelBuffer(
            width: 320,
            height: 240,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        )
        let recon = try makeIOSurfacePixelBuffer(
            width: 320,
            height: 240,
            pixelFormat: kCVPixelFormatType_32BGRA
        )

        let config = ChromaConversionConfig(
            bitDepth: 8,
            siting: .coSited,
            filterMode: .lumaGuidedEdgeAware,
            ditherMode: .temporalInterleavedGradient,
            isBT2020: false,
            fullRange: false,
            frameIndex: 1
        )
        try pipeline.convertBGRAtoYUV(src: srcBGRA, dst: nv12, config: config)
        try pipeline.reconstructYUVtoBGRA(srcYUV: nv12, dstBGRA: recon, config: config)

        // Verify BT.709 + Left co-sited CVBuffer attachments were applied.
        let primaries = CVBufferCopyAttachment(nv12, kCVImageBufferColorPrimariesKey, nil) as? String
        let chromaLoc = CVBufferCopyAttachment(nv12, kCVImageBufferChromaLocationTopFieldKey, nil) as? String
        XCTAssertEqual(primaries, kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        XCTAssertEqual(chromaLoc, kCVImageBufferChromaLocation_Left as String)

        let report = try MetalChromaPipeline.measureMaskedDeltaE00(
            referenceBGRA: srcBGRA,
            candidateBGRA: recon,
            textMask: textMask
        )
        print(String(
            format: "[Wave12A NV12] mean=%.4f p95=%.4f p99=%.4f satEdgeP95=%.4f textP95=%.4f",
            report.meanDeltaE00, report.p95DeltaE00, report.p99DeltaE00,
            report.saturatedEdgeP95DeltaE00, report.textRegionP95DeltaE00
        ))

        XCTAssertLessThan(report.meanDeltaE00, 1.0, "NV12 meanDeltaE00 should be < 1.0")
        XCTAssertLessThanOrEqual(report.p95DeltaE00, 2.0, "NV12 p95DeltaE00 should be <= 2.0")
    }

    func testTemporalInterleavedGradientDitherStability() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal GPU device available on this host")
        }

        let pipeline = try MetalChromaPipeline()
        let (srcBGRA, _) = try synthesizeChromaStressFrame()

        // Test 4 identical frames across frameIndex = 0, 1, 2, 3 for BOTH P010 and NV12.
        for (bitDepth, yuvFmt) in [
            (10, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
            (8,  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        ] {
            var reconstructed: [CVPixelBuffer] = []
            for frameIdx: UInt32 in 0..<4 {
                let yuv = try makeIOSurfacePixelBuffer(width: 320, height: 240, pixelFormat: yuvFmt)
                let outBGRA = try makeIOSurfacePixelBuffer(width: 320, height: 240, pixelFormat: kCVPixelFormatType_32BGRA)
                let cfg = ChromaConversionConfig(
                    bitDepth: bitDepth,
                    siting: .coSited,
                    filterMode: .lumaGuidedEdgeAware,
                    ditherMode: .temporalInterleavedGradient,
                    isBT2020: false,
                    fullRange: false,
                    frameIndex: frameIdx
                )
                try pipeline.convertBGRAtoYUV(src: srcBGRA, dst: yuv, config: cfg)
                try pipeline.reconstructYUVtoBGRA(srcYUV: yuv, dstBGRA: outBGRA, config: cfg)
                reconstructed.append(outBGRA)
            }

            let flicker = try MetalChromaPipeline.measureTemporalFlicker(framesBGRA: reconstructed)
            print(String(format: "[Wave12A Temporal IGN %dbit] maxTemporalFlicker=%.6f (limit=%.6f)", bitDepth, flicker, 2.0 / 255.0))
            XCTAssertLessThanOrEqual(
                flicker,
                2.0 / 255.0 + 1e-9,
                "Temporal IGN dithering flicker (\(bitDepth)-bit) must stay <= 2/255"
            )
        }
    }

    func testCenterSitedBT2020AndBayer4x4Modes() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal GPU device available on this host")
        }

        let pipeline = try MetalChromaPipeline()
        let (srcBGRA, textMask) = try synthesizeChromaStressFrame()

        let p010Full = try makeIOSurfacePixelBuffer(
            width: 320,
            height: 240,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        )
        let recon = try makeIOSurfacePixelBuffer(
            width: 320,
            height: 240,
            pixelFormat: kCVPixelFormatType_32BGRA
        )

        let cfg = ChromaConversionConfig(
            bitDepth: 10,
            siting: .centerSited,
            filterMode: .lumaGuidedEdgeAware,
            ditherMode: .bayer4x4,
            isBT2020: true,
            fullRange: true,
            frameIndex: 2
        )
        try pipeline.convertBGRAtoYUV(src: srcBGRA, dst: p010Full, config: cfg)
        try pipeline.reconstructYUVtoBGRA(srcYUV: p010Full, dstBGRA: recon, config: cfg)

        let primaries = CVBufferCopyAttachment(p010Full, kCVImageBufferColorPrimariesKey, nil) as? String
        let chromaLoc = CVBufferCopyAttachment(p010Full, kCVImageBufferChromaLocationTopFieldKey, nil) as? String
        XCTAssertEqual(primaries, kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        XCTAssertEqual(chromaLoc, kCVImageBufferChromaLocation_Center as String)

        let report = try MetalChromaPipeline.measureMaskedDeltaE00(
            referenceBGRA: srcBGRA,
            candidateBGRA: recon,
            textMask: textMask
        )
        XCTAssertLessThan(report.meanDeltaE00, 1.0)
        XCTAssertLessThanOrEqual(report.p95DeltaE00, 2.0)
    }
}
