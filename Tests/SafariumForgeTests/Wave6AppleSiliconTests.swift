import AVFoundation
import CoreGraphics
import CoreText
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import Metal
import SafariumContainers
import SafariumCore
@testable import SafariumForgeCore
import XCTest

private final class TestLockedStorage<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ initial: Value) { self.storage = initial }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.withLock { body(&storage) }
    }
}

final class Wave6AppleSiliconTests: XCTestCase {
    private static let testColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let testBitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

    private func makeShortAPFSDir(_ prefix: String) throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        chmod(dir.path, 0o700)
        return dir
    }

    private func makeBGRA(width: Int, height: Int, draw: (CGContext) -> Void) throws -> CVPixelBuffer {
        let pb = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else {
            throw SafariumError.snapshot("missing BGRA base")
        }
        let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: Self.testColorSpace,
            bitmapInfo: Self.testBitmapInfo
        )!
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        draw(ctx)
        return pb
    }

    private func makeSolidBGRA(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8 = 255) throws -> CVPixelBuffer {
        let pb = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            let row = base.advanced(by: y * bpr)
            for x in 0..<width {
                let off = x * 4
                row[off] = b
                row[off + 1] = g
                row[off + 2] = r
                row[off + 3] = a
            }
        }
        return pb
    }

    private func readPixel(_ pb: CVPixelBuffer, x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let off = y * bpr + x * 4
        return (base[off], base[off + 1], base[off + 2], base[off + 3])
    }

    private func writeClosedGOPSegment(
        url: URL,
        width: Int = 160,
        height: Int = 120,
        fps: Int = 30,
        frames: Int = 15,
        colorAtFrame: (Int) -> (CGFloat, CGFloat, CGFloat)
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let sink = try AVAssetWriterSink(
            url: url,
            width: width,
            height: height,
            fps: fps,
            codec: .h264,
            bitrate: 1_500_000,
            pixelFormat: .nv12Left,
            profile: .lowRamClosedGOP
        )
        for f in 0..<frames {
            let c = colorAtFrame(f)
            let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: Self.testColorSpace,
                bitmapInfo: Self.testBitmapInfo
            )!
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1.0))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            try await sink.append(Snapshot(cgImage: ctx.makeImage()!))
        }
        try await sink.finish()
    }

    private func drawThaiScene(width: Int, height: Int, text: String = "ทดสอบ ปิ๊ก EP30") throws -> CVPixelBuffer {
        try makeBGRA(width: width, height: height) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0.10, green: 0.18, blue: 0.30, alpha: 1.0))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.35, blue: 0.18, alpha: 1.0))
            ctx.fill(CGRect(x: width / 8, y: height / 6, width: width / 4, height: height / 6))
            let font = CTFontCreateWithName("Thonburi-Bold" as CFString, CGFloat(max(20, height / 14)), nil)
            let attr = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            ] as CFDictionary
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attr)!)
            ctx.textPosition = CGPoint(x: CGFloat(width) * 0.12, y: CGFloat(height) * 0.52)
            CTLineDraw(line, ctx)
        }
    }

    // MARK: - 1. ForgeTimeExprParser Comparison & Equality Functions

    func testTimeExprParserComparisonAndEqualityFunctions() throws {
        let ctx = ForgeExprContext(t: 2.0, frame: 60, fps: 30, duration: 5.0)

        XCTAssertEqual(try ForgeTimeExprParser.compile("lt(t, 2.5)").evaluate(ctx), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try ForgeTimeExprParser.compile("lt(t, 2.0)").evaluate(ctx), 0.0, accuracy: 1e-9)
        XCTAssertEqual(try ForgeTimeExprParser.compile("lte(t, 2.0)").evaluate(ctx), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try ForgeTimeExprParser.compile("lte(t, 1.9)").evaluate(ctx), 0.0, accuracy: 1e-9)

        XCTAssertEqual(try ForgeTimeExprParser.compile("gt(t, 1.5)").evaluate(ctx), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try ForgeTimeExprParser.compile("gt(t, 2.0)").evaluate(ctx), 0.0, accuracy: 1e-9)
        XCTAssertEqual(try ForgeTimeExprParser.compile("gte(t, 2.0)").evaluate(ctx), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try ForgeTimeExprParser.compile("gte(t, 2.1)").evaluate(ctx), 0.0, accuracy: 1e-9)

        XCTAssertEqual(try ForgeTimeExprParser.compile("eq(t, 2.0)").evaluate(ctx), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try ForgeTimeExprParser.compile("eq(0.1 + 0.2, 0.3)").evaluate(ctx), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try ForgeTimeExprParser.compile("eq(t, 2.01)").evaluate(ctx), 0.0, accuracy: 1e-9)

        // Composed with existing if / between / easeInOut and boundary/arity edge cases
        XCTAssertEqual(
            try ForgeTimeExprParser.compile("if(lt(t, 3.0), between(frame, 50, 70) * easeInOut(0.5), 99)").evaluate(ctx),
            0.5,
            accuracy: 1e-6
        )
        XCTAssertEqual(
            try ForgeTimeExprParser.compile("if(gte(t, 2.0), eq(fps, 30) * 42, 0)").evaluate(ctx),
            42.0,
            accuracy: 1e-9
        )
        XCTAssertEqual(try ForgeTimeExprParser.compile("lt(-5, -2)").evaluate(ctx), 1.0, accuracy: 1e-9)
        XCTAssertEqual(try ForgeTimeExprParser.compile("lt(1)").evaluate(ctx), 0.0, accuracy: 1e-9)
    }

    // MARK: - 2. Metal RGBA16F tmix, K.grief, and DoubleBufferedMetalPipeline

    func testMetalTMixRGBA16FArbitraryWeights() throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let engine = try ForgeMetalFilterEngine(bakeArchive: false)
        let w = 64, h = 64
        let f0 = try makeSolidBGRA(width: w, height: h, r: 200, g: 0, b: 0)
        let f1 = try makeSolidBGRA(width: w, height: h, r: 0, g: 200, b: 0)
        let f2 = try makeSolidBGRA(width: w, height: h, r: 0, g: 0, b: 200)
        let dst = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: w, height: h, pixelFormat: .bgra)

        // Normalized arbitrary weight window [2, 1, 1] -> [0.5, 0.25, 0.25] => (100, 50, 50)
        try engine.applyTMix(frames: [f0, f1, f2], weights: [2.0, 1.0, 1.0], normalizeWeights: true, into: dst)
        let px = readPixel(dst, x: 16, y: 16)
        XCTAssertEqual(Int(px.r), 100, accuracy: 2)
        XCTAssertEqual(Int(px.g), 50, accuracy: 2)
        XCTAssertEqual(Int(px.b), 50, accuracy: 2)
        XCTAssertEqual(Int(px.a), 255, accuracy: 2)

        // Default uniform weights across 4 frames
        let f3 = try makeSolidBGRA(width: w, height: h, r: 200, g: 200, b: 200)
        try engine.applyTMix(frames: [f0, f1, f2, f3], into: dst)
        let pxUniform = readPixel(dst, x: 32, y: 32)
        XCTAssertEqual(Int(pxUniform.r), 100, accuracy: 2)
        XCTAssertEqual(Int(pxUniform.g), 100, accuracy: 2)
        XCTAssertEqual(Int(pxUniform.b), 100, accuracy: 2)

        // Unnormalized signed RGBA16F window [1.5, -0.5] on (120, 40, 40) & (80, 0, 0) => (140, 60, 60)
        let fA = try makeSolidBGRA(width: w, height: h, r: 120, g: 40, b: 40)
        let fB = try makeSolidBGRA(width: w, height: h, r: 80, g: 0, b: 0)
        try engine.applyTMix(frames: [fA, fB], weights: [1.5, -0.5], normalizeWeights: false, into: dst)
        let pxSigned = readPixel(dst, x: 8, y: 8)
        XCTAssertEqual(Int(pxSigned.r), 140, accuracy: 2)
        XCTAssertEqual(Int(pxSigned.g), 60, accuracy: 2)
        XCTAssertEqual(Int(pxSigned.b), 60, accuracy: 2)

        // Mismatched weights count must throw SafariumError
        XCTAssertThrowsError(try engine.applyTMix(frames: [f0, f1], weights: [1.0], into: dst))
    }

    func testMetalKGriefUnifiedPassOpticalFlowTemporalAndHUDShield() throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let engine = try ForgeMetalFilterEngine(bakeArchive: false)
        let w = 64, h = 64

        // Vibrant orange-red current frame
        let curr = try makeSolidBGRA(width: w, height: h, r: 230, g: 80, b: 30)
        // Previous frame has a shifted bright patch at x=16..32, and flow points (+8, 0) from prev -> curr
        let prev = try makeBGRA(width: w, height: h) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 230.0 / 255.0, green: 80.0 / 255.0, blue: 30.0 / 255.0, alpha: 1.0))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        // Optical flow RG32F pixel buffer (zero flow)
        var flowPBOpt: CVPixelBuffer?
        let flowAttrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_TwoComponent32Float, flowAttrs as CFDictionary, &flowPBOpt),
            kCVReturnSuccess
        )
        let flowPB = try XCTUnwrap(flowPBOpt)
        CVPixelBufferLockBaseAddress(flowPB, [])
        memset(CVPixelBufferGetBaseAddress(flowPB)!, 0, CVPixelBufferGetBytesPerRow(flowPB) * h)
        CVPixelBufferUnlockBaseAddress(flowPB, [])

        // Crisp 1x HUD badge in bottom-right corner only (transparent elsewhere)
        let hud = try makeBGRA(width: w, height: h) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.9, blue: 0.2, alpha: 1.0))
            ctx.fill(CGRect(x: 40, y: 40, width: 20, height: 20))
        }
        let dst = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: w, height: h, pixelFormat: .bgra)

        try engine.applyKGrief(
            currPB: curr,
            prevPB: prev,
            flowPB: flowPB,
            hudOverlayPB: hud,
            config: .griefOn,
            into: dst
        )

        // Background region (10, 10) must be desaturated (near-neutral gray) and slightly darkened (~0.92x)
        let bgPx = readPixel(dst, x: 10, y: 10)
        let chromaSpan = max(Int(bgPx.r), max(Int(bgPx.g), Int(bgPx.b))) - min(Int(bgPx.r), min(Int(bgPx.g), Int(bgPx.b)))
        XCTAssertLessThan(chromaSpan, 30, "K.grief must desaturate world pixels (sat=0.10): \(bgPx)")
        XCTAssertGreaterThan(Int(bgPx.r), 60)
        XCTAssertLessThan(Int(bgPx.r), 140)

        // HUD region (50, 14 in CG inverted coords -> or y=10..20, wait: CGContext origin is bottom-left!)
        // In CGContext, rect (40, 40, 20, 20) is top-right in CG bottom-left coords -> y = h - 50 = 14 in CVPixelBuffer top-down coords.
        let hudPx = readPixel(dst, x: 50, y: 14)
        XCTAssertGreaterThan(Int(hudPx.g), 200, "1x HUD overlay must stay vibrant over K.grief: \(hudPx)")
        XCTAssertLessThan(Int(hudPx.r), 50)

        // Optical-flow warping check: prev has bright white block at x=8..16, curr has black at x=24..32 with flow dx=+16
        let prevFlowTest = try makeBGRA(width: w, height: h) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 8, y: 20, width: 8, height: 16))
        }
        let currFlowTest = try makeSolidBGRA(width: w, height: h, r: 220, g: 220, b: 220)
        CVPixelBufferLockBaseAddress(flowPB, [])
        let fBase = CVPixelBufferGetBaseAddress(flowPB)!.assumingMemoryBound(to: Float.self)
        let fFloatsPerRow = CVPixelBufferGetBytesPerRow(flowPB) / MemoryLayout<Float>.size
        for y in 0..<h {
            for x in 0..<w {
                fBase[y * fFloatsPerRow + x * 2] = 16.0 // prev is shifted left by 16px
                fBase[y * fFloatsPerRow + x * 2 + 1] = 0.0
            }
        }
        CVPixelBufferUnlockBaseAddress(flowPB, [])
        try engine.applyKGrief(
            currPB: currFlowTest,
            prevPB: prevFlowTest,
            flowPB: flowPB,
            config: ForgeKGriefConfig(saturation: 1.0, brightness: 1.0, temporalBlend: 0.5, motionRejection: 0.5, flowScale: 1.0),
            into: dst
        )
        let warpedPx = readPixel(dst, x: 26, y: 36)
        let unwarpedPx = readPixel(dst, x: 10, y: 36)
        XCTAssertGreaterThan(Int(warpedPx.r), Int(unwarpedPx.r) + 30, "optical flow should warp prev white block to x=26")
    }

    func testDoubleBufferedMetalPipelineOverlapsAndDeliversOrderedFrames() throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let engine = try ForgeMetalFilterEngine(bakeArchive: false)
        let w = 128, h = 128
        let total = 16
        let delivered = TestLockedStorage<(indices: [Int], reds: [UInt8])>(([], []))

        let pipeline = try DoubleBufferedMetalPipeline(
            engine: engine,
            width: w,
            height: h,
            slotCount: 2
        ) { frameIndex, pb in
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            let r = base[2] // BGRA
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            delivered.withLock {
                $0.indices.append(frameIndex)
                $0.reds.append(r)
            }
        }

        for i in 0..<total {
            try pipeline.submitFrame(index: i) { cmd, dstTex in
                let redNorm = Float(i * 15) / 255.0
                try engine.encodeSolidFill(colorRGBA: SIMD4<Float>(redNorm, 0.2, 0.4, 1.0), into: dstTex, commandBuffer: cmd)
            }
        }
        try pipeline.finish()

        let snapshot = delivered.withLock { $0 }
        XCTAssertEqual(pipeline.framesSubmitted, total)
        XCTAssertEqual(pipeline.framesCompleted, total)
        XCTAssertEqual(snapshot.indices, Array(0..<total))
        for i in 0..<total {
            XCTAssertEqual(Int(snapshot.reds[i]), i * 15, accuracy: 2)
        }

        // Triple-buffered (slotCount: 3) check
        let tripleDelivered = TestLockedStorage<[Int]>([])
        let triple = try DoubleBufferedMetalPipeline(engine: engine, width: 64, height: 64, slotCount: 3) { idx, _ in
            tripleDelivered.withLock { $0.append(idx) }
        }
        XCTAssertEqual(triple.slotCount, 3)
        for i in 0..<9 {
            try triple.submitFrame(index: i) { cmd, tex in
                try engine.encodeSolidFill(colorRGBA: SIMD4<Float>(0.5, 0.5, 0.5, 1.0), into: tex, commandBuffer: cmd)
            }
        }
        try triple.finish()
        XCTAssertEqual(tripleDelivered.withLock { $0 }, Array(0..<9))
    }

    // MARK: - 3. Apple-Silicon LLSR Opt-In + MetalFX Fallback + SafariumPQ 1x Safeguard

    func testLLSRUpscalerOptInFallbackAndSafariumPQ1xSafeguard() throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let engine = try ForgeMetalFilterEngine(bakeArchive: false)
        let upscaler = try ForgeLLSRUpscaler(engine: engine)

        // Check capability query doesn't crash on any Apple Silicon macOS
        _ = ForgeLLSRUpscaler.isHardwareLLSRSupported()
        _ = ForgeLLSRUpscaler.supportedScaleFactors(frameWidth: 540, frameHeight: 960)

        // 1. Crisp 1x reference with Thai text + 0.5x degraded background + 1x Thai overlay shield
        let ref1x = try drawThaiScene(width: 640, height: 640, text: "ทดสอบ ปิ๊ก")
        let lowResBG = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: 320, height: 320, pixelFormat: .bgra)
        try engine.applyGeom(srcPB: ref1x, into: lowResBG)

        let thaiOverlay1x = try makeBGRA(width: 640, height: 640) { ctx in
            let font = CTFontCreateWithName("Thonburi-Bold" as CFString, 45, nil)
            let attr = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            ] as CFDictionary
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "ทดสอบ ปิ๊ก" as CFString, attr)!)
            ctx.textPosition = CGPoint(x: 640.0 * 0.12, y: 640.0 * 0.52)
            CTLineDraw(line, ctx)
        }

        // 2. Opt-in disabled -> strict 1x passthrough
        let optOutRes = try upscaler.upscale(
            lowResPB: lowResBG,
            targetWidth: 640,
            targetHeight: 640,
            reference1xPB: ref1x,
            policy: ForgeLLSRPolicy(enabled: false)
        )
        XCTAssertTrue(optOutRes.didFallbackTo1x)
        XCTAssertEqual(optOutRes.backend, "1x_passthrough")

        // 3. Forced MetalFX fallback with 1x Thai overlay shield -> must pass SafariumPQ and keep dimensions 640x640
        let metalFXRes = try upscaler.upscale(
            lowResPB: lowResBG,
            targetWidth: 640,
            targetHeight: 640,
            reference1xPB: ref1x,
            overlay1xPB: thaiOverlay1x,
            policy: ForgeLLSRPolicy(enabled: true, minPQScore: 80.0, minMSSSIM: 0.90, maxDeltaE00P95: 5.0, checkThaiOCR: false),
            forceFallbackMetalFX: true
        )
        XCTAssertTrue(metalFXRes.usedMetalFXFallback)
        XCTAssertFalse(metalFXRes.didFallbackTo1x)
        XCTAssertEqual(CVPixelBufferGetWidth(metalFXRes.outputPB), 640)
        XCTAssertEqual(CVPixelBufferGetHeight(metalFXRes.outputPB), 640)

        // 4. Live LLSR (or MetalFX fallback if hardware rejects dimensions) at 540x960 -> 1080x1920 with transparent 1x Thai overlay
        let bg540 = try makeSolidBGRA(width: 540, height: 960, r: 32, g: 72, b: 140)
        let thaiOverlay1080 = try makeBGRA(width: 1080, height: 1920) { ctx in
            let font = CTFontCreateWithName("Thonburi-Bold" as CFString, 72, nil)
            let attr = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
            ] as CFDictionary
            let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "ทดสอบ ปิ๊ก" as CFString, attr)!)
            ctx.textPosition = CGPoint(x: 1080.0 * 0.12, y: 1920.0 * 0.52)
            CTLineDraw(line, ctx)
        }
        let liveRes = try upscaler.upscale(
            lowResPB: bg540,
            targetWidth: 1080,
            targetHeight: 1920,
            reference1xPB: nil,
            overlay1xPB: thaiOverlay1080,
            policy: ForgeLLSRPolicy(enabled: true)
        )
        XCTAssertEqual(CVPixelBufferGetWidth(liveRes.outputPB), 1080)
        XCTAssertEqual(CVPixelBufferGetHeight(liveRes.outputPB), 1920)
        XCTAssertTrue(liveRes.usedLLSR || liveRes.usedMetalFXFallback)
        let bgCorner1080 = readPixel(liveRes.outputPB, x: 20, y: 20)
        XCTAssertEqual(Int(bgCorner1080.b), 140, accuracy: 8)

        // 5. SafariumPQ 1x safeguard: severely blurred low-res input (160x160) with impossible threshold -> must fall back to crisp 1x reference!
        let tinyBlurry = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: 160, height: 160, pixelFormat: .bgra)
        try engine.applyGeom(srcPB: ref1x, into: tinyBlurry)
        let safeguardRes = try upscaler.upscale(
            lowResPB: tinyBlurry,
            targetWidth: 640,
            targetHeight: 640,
            reference1xPB: ref1x,
            policy: ForgeLLSRPolicy(enabled: true, minPQScore: 99.5, minMSSSIM: 0.999, maxDeltaE00P95: 0.2, checkThaiOCR: true, expectedThaiText: "ทดสอบ")
        )
        XCTAssertTrue(safeguardRes.didFallbackTo1x)
        XCTAssertEqual(safeguardRes.backend, "1x_safeguard_fallback")
        XCTAssertTrue(safeguardRes.outputPB === ref1x)
    }

    // MARK: - 4. Bounded Animated WebP / HEICS Pixel Budget Helper

    func testAnimatedImageBudgetRejectsRunawayFramePixelCount() throws {
        // Within 16 MiB budget: 10 frames x 320x240 x 4 B = 3,072,000 B
        let est = try enforceAnimatedImageBudget(frameCount: 10, width: 320, height: 240, maxBytes: 16 * 1024 * 1024)
        XCTAssertEqual(est, Int64(10 * 320 * 240 * 4))

        // Runaway 600 frames at 1080x1920 (~4.97 GB) exceeds 256 MiB budget -> throws SafariumError
        do {
            _ = try enforceAnimatedImageBudget(frameCount: 600, width: 1080, height: 1920, maxBytes: 256 * 1024 * 1024)
            XCTFail("Expected SafariumError on excessive animated image pixel budget")
        } catch let err as SafariumError {
            let env = SafariumStructuredErrorEnvelope.from(err, tool: "safarium-forge")
            XCTAssertEqual(env.error.code, .E_THERMAL_OR_MEM)
        }

        // Integer overflow protection
        XCTAssertThrowsError(try enforceAnimatedImageBudget(frameCount: Int.max, width: 1920, height: 1080, maxBytes: 256 * 1024 * 1024))

        // Incremental streaming budget collector rejects on overflow frame
        let collector = try ForgeBoundedAnimatedFrameBudget(maxBytes: 1024 * 1024)
        _ = try collector.recordFrame(width: 512, height: 256) // 524,288 B
        _ = try collector.recordFrame(width: 512, height: 256) // 1,048,576 B (exact fit)
        XCTAssertThrowsError(try collector.recordFrame(width: 512, height: 256)) // > 1 MiB -> throws!
    }

    // MARK: - 5. Closed-GOP APFS clonefile Incremental Scene Cache + Lossless Stitch + memflush

    func testIncrementalCacheAPFSClonefileStitchAndCorruptRejection() async throws {
        let dir = try makeShortAPFSDir("w6ic")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cacheRoot = dir.appendingPathComponent("scene-cache", isDirectory: true)
        let seg1 = dir.appendingPathComponent("scene1.mp4")
        let seg2 = dir.appendingPathComponent("scene2.mp4")
        let seg2V2 = dir.appendingPathComponent("scene2_v2.mp4")

        try await writeClosedGOPSegment(url: seg1, frames: 15) { f in (0.85, Double(f) / 20.0, 0.15) }
        try await writeClosedGOPSegment(url: seg2, frames: 15) { f in (0.15, 0.55, Double(f + 2) / 20.0) }

        let spec1 = ForgeSceneSpec(sceneId: "scene-1", inputs: ["bg1.png"], opsHash: "ops-v1", durationSeconds: 0.5, fps: 30, width: 160, height: 120, codec: "h264")
        let spec2 = ForgeSceneSpec(sceneId: "scene-2", inputs: ["bg2.png"], opsHash: "ops-v1", durationSeconds: 0.5, fps: 30, width: 160, height: 120, codec: "h264")
        let key1 = ForgeIncrementalCache.cacheKey(for: spec1)
        let key2 = ForgeIncrementalCache.cacheKey(for: spec2)
        XCTAssertEqual(key1.count, 64)
        XCTAssertNotEqual(key1, key2)

        let st1 = try ForgeIncrementalCache.storeScene(key: key1, segmentURL: seg1, spec: spec1, cacheRoot: cacheRoot)
        let st2 = try ForgeIncrementalCache.storeScene(key: key2, segmentURL: seg2, spec: spec2, cacheRoot: cacheRoot)
        XCTAssertTrue(st1.usedClonefile)
        XCTAssertTrue(st2.usedClonefile)

        // Inject ._ AppleDouble file to ensure cacheStats ignores it
        try Data("junk".utf8).write(to: cacheRoot.appendingPathComponent("._deadbeef.mp4"))
        let stats1 = try ForgeIncrementalCache.cacheStats(cacheRoot: cacheRoot)
        XCTAssertEqual(stats1.entryCount, 2)
        XCTAssertTrue(stats1.isAPFS)
        XCTAssertTrue(stats1.supportsClonefile)

        let stitchedV1 = dir.appendingPathComponent("final_v1.mp4")
        let stitchRep1 = try await ClosedGOPSegmentStitcher.splice(segments: [seg1, seg2], outputURL: stitchedV1, overwrite: true)
        XCTAssertTrue(stitchRep1.stsdUniform)
        XCTAssertEqual(stitchRep1.outputVideoPacketCount, 30)
        XCTAssertEqual(stitchRep1.durationSeconds, 1.0, accuracy: 0.08)

        // Single-segment CoW passthrough splice check
        let singleOut = dir.appendingPathComponent("single_passthrough.mp4")
        let singleRep = try await ClosedGOPSegmentStitcher.splice(segments: [seg1], outputURL: singleOut, overwrite: true)
        XCTAssertEqual(singleRep.segmentCount, 1)
        XCTAssertEqual(singleRep.outputVideoPacketCount, 15)
        XCTAssertTrue(singleRep.usedClonefileSingleSegment)

        // Modify ONLY scene 2 -> scene 1 MUST hit APFS cache & clonefile, scene 2 MUST miss
        var spec2V2 = spec2
        spec2V2.opsHash = "ops-v2"
        let key2V2 = ForgeIncrementalCache.cacheKey(for: spec2V2)
        XCTAssertNotEqual(key2, key2V2)

        let restored1 = dir.appendingPathComponent("restored_scene1.mp4")
        let hit1 = try ForgeIncrementalCache.lookupScene(key: key1, destinationURL: restored1, cacheRoot: cacheRoot, overwrite: true)
        XCTAssertTrue(hit1.hit)
        XCTAssertTrue(hit1.usedClonefile)

        let miss2 = try ForgeIncrementalCache.lookupScene(key: key2V2, destinationURL: nil, cacheRoot: cacheRoot)
        XCTAssertFalse(miss2.hit)

        try await writeClosedGOPSegment(url: seg2V2, frames: 15) { f in (0.20, 0.85, Double(f) / 20.0) }
        _ = try ForgeIncrementalCache.storeScene(key: key2V2, segmentURL: seg2V2, spec: spec2V2, cacheRoot: cacheRoot)

        let stitchedV2 = dir.appendingPathComponent("final_v2.mp4")
        let stitchRep2 = try await ClosedGOPSegmentStitcher.splice(segments: [restored1, seg2V2], outputURL: stitchedV2, overwrite: true)
        XCTAssertEqual(stitchRep2.outputVideoPacketCount, 30)
        XCTAssertEqual(stitchRep2.durationSeconds, 1.0, accuracy: 0.08)

        // Lossless verification: first 15 video packet SHA-256 hashes match scene 1 identically
        let pSeg1 = try await PacketProbe.inspect(url: seg1, includeAudioPackets: false)
        let pOut2 = try await PacketProbe.inspect(url: stitchedV2, includeAudioPackets: false)
        let seg1V = try XCTUnwrap(pSeg1.tracks.first(where: { $0.mediaType == "vide" }))
        let out2V = try XCTUnwrap(pOut2.tracks.first(where: { $0.mediaType == "vide" }))
        XCTAssertEqual(out2V.packetCount, 30)
        XCTAssertEqual(Array(out2V.packets.prefix(15).map(\.sha256)), seg1V.packets.map(\.sha256))

        // Corrupt & empty segment rejection
        let emptyURL = dir.appendingPathComponent("empty.mp4")
        try Data().write(to: emptyURL)
        XCTAssertThrowsError(try ForgeIncrementalCache.storeScene(key: String(repeating: "a", count: 64), segmentURL: emptyURL, cacheRoot: cacheRoot))

        let corruptURL = dir.appendingPathComponent("corrupt.mp4")
        try Data("not-a-valid-mp4-stream".utf8).write(to: corruptURL)
        XCTAssertThrowsError(try ForgeIncrementalCache.storeScene(key: String(repeating: "b", count: 64), segmentURL: corruptURL, cacheRoot: cacheRoot))

        // Corrupting cached segment on disk must be strictly rejected on lookup
        let cachedKey1File = cacheRoot.appendingPathComponent("\(key1).mp4")
        try Data("corrupted-after-store".utf8).write(to: cachedKey1File)
        XCTAssertThrowsError(try ForgeIncrementalCache.lookupScene(key: key1, destinationURL: nil, cacheRoot: cacheRoot))

        // ExFAT cache root rejection (when SAFARIUM_TEST_EXFAT_PATH points to an ExFAT mount)
        if let exfatPath = ProcessInfo.processInfo.environment["SAFARIUM_TEST_EXFAT_PATH"],
           !exfatPath.isEmpty,
           FileManager.default.fileExists(atPath: exfatPath) {
            let mainCaps = try APFSAutoStage.inspectVolume(at: URL(fileURLWithPath: exfatPath))
            if !mainCaps.isAPFS {
                let badRoot = URL(fileURLWithPath: "\(exfatPath)/.test-invalid-cache-\(UUID().uuidString.prefix(8))", isDirectory: true)
                XCTAssertThrowsError(try ForgeIncrementalCache.validateAPFSCacheRoot(badRoot))
            }
        }

        // LRU eviction test
        let pruneReport = try ForgeIncrementalCache.pruneLRU(cacheRoot: cacheRoot, maxBytes: 1)
        XCTAssertEqual(pruneReport.remainingEntries, 0)

        // Memflush runs cleanly on Apple Silicon
        safariumMemFlush()
        XCTAssertGreaterThan(SafariumRuntimeTelemetry.currentFootprintMB(), 0.0)
    }

    // MARK: - 6. Opt-In Adaptive Multi-WebKit Pool & Pressure Scale-Down & Child Cleanup

    func testAdaptiveWebKitPoolDefaultSingleWorkerPressureScaleDownAndCleanup() async throws {
        let dir = try makeShortAPFSDir("w6pool")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Default requestedWorkers MUST strictly be 1
        let defaultCfg = ForgeAdaptivePoolConfig(totalFrames: 60)
        XCTAssertEqual(defaultCfg.requestedWorkers, 1)
        XCTAssertEqual(defaultCfg.budgetMB, 700.0, accuracy: 1e-6)
        XCTAssertEqual(defaultCfg.maxWorkersCeiling, 4)

        let outSingle = dir.appendingPathComponent("pool_single.mp4")
        let poolSingle = try ForgeAdaptiveWebKitPool(config: ForgeAdaptivePoolConfig(totalFrames: 30, fps: 30, chunkFrames: 15))
        let repSingle = try await poolSingle.runChunks(
            finalOutputURL: outSingle,
            stagingDirectory: dir.appendingPathComponent("stage1", isDirectory: true),
            overwrite: true
        ) { chunk, _, segURL in
            try await self.writeClosedGOPSegment(url: segURL, width: 128, height: 96, fps: chunk.fps, frames: chunk.frameCount) { f in
                (Double(chunk.startFrame + f) / 40.0, 0.4, 0.7)
            }
        }
        XCTAssertEqual(repSingle.telemetry.peakWorkersUsed, 1)
        XCTAssertEqual(repSingle.telemetry.chunksCompleted, 2)
        let pSingle = try await PacketProbe.inspect(url: outSingle, includeAudioPackets: false)
        XCTAssertEqual(pSingle.tracks.first(where: { $0.mediaType == "vide" })?.packetCount, 30)

        // 2. Opt-in multi-worker scales up while footprint < 0.72*budget, then scales down to 1 under synthetic pressure / thermal trip
        let sampleCounter = TestLockedStorage<Int>(0)
        let pressureCfg = ForgeAdaptivePoolConfig(
            requestedWorkers: 4,
            budgetMB: 700.0,
            maxWorkersCeiling: 4,
            totalFrames: 90,
            fps: 30,
            chunkFrames: 15
        )
        let poolPressure = try ForgeAdaptiveWebKitPool(config: pressureCfg) { _ in
            let idx = sampleCounter.withLock { c -> Int in
                c += 1
                return c
            }
            if idx <= 3 {
                // Healthy -> allows scale up to 2..3
                return ForgePoolSample(footprintMB: 210.0, thermalState: .nominal)
            } else {
                // Approaches >= 0.85 * 700 (595 MB) + thermal .serious -> forces immediate scale down to 1
                return ForgePoolSample(footprintMB: 625.0, thermalState: .serious)
            }
        }

        let outPressure = dir.appendingPathComponent("pool_pressure.mp4")
        let repPressure = try await poolPressure.runChunks(
            finalOutputURL: outPressure,
            stagingDirectory: dir.appendingPathComponent("stage2", isDirectory: true),
            overwrite: true
        ) { chunk, _, segURL in
            try await Task.sleep(nanoseconds: 25_000_000)
            try await self.writeClosedGOPSegment(url: segURL, width: 128, height: 96, fps: chunk.fps, frames: chunk.frameCount) { f in
                (0.2, Double(chunk.startFrame + f) / 100.0, 0.8)
            }
        }
        XCTAssertGreaterThanOrEqual(repPressure.telemetry.peakWorkersUsed, 2)
        XCTAssertGreaterThanOrEqual(repPressure.telemetry.scaleDownEvents, 1)
        XCTAssertGreaterThanOrEqual(repPressure.telemetry.thermalTrips, 1)
        XCTAssertEqual(repPressure.telemetry.chunksCompleted, 6)
        let pPress = try await PacketProbe.inspect(url: outPressure, includeAudioPackets: false)
        XCTAssertEqual(pPress.tracks.first(where: { $0.mediaType == "vide" })?.packetCount, 90)

        // 3. Guaranteed child cleanup on error/throw (no orphaned process!)
        let failPool = try ForgeAdaptiveWebKitPool(config: ForgeAdaptivePoolConfig(requestedWorkers: 2, totalFrames: 30, fps: 30, chunkFrames: 15))
        let childProc = Process()
        childProc.executableURL = URL(fileURLWithPath: "/bin/sleep")
        childProc.arguments = ["30"]
        do {
            _ = try await failPool.runChunks(
                finalOutputURL: dir.appendingPathComponent("should_not_exist.mp4"),
                stagingDirectory: dir.appendingPathComponent("stage_fail", isDirectory: true),
                overwrite: true
            ) { chunk, _, _ in
                if chunk.index == 0 {
                    try childProc.run()
                    failPool.trackChildProcess(childProc)
                    throw SafariumError.invalidState("synthetic worker failure")
                }
            }
            XCTFail("Expected pool error")
        } catch {
            // Expected
        }
        XCTAssertFalse(childProc.isRunning, "Child process must be terminated on throw with no orphans")
    }
}
