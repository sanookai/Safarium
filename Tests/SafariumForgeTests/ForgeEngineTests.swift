import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import ImageIO
import Metal
import SafariumContainers
import SafariumCore
@testable import SafariumForgeCore
import XCTest

final class ForgeEngineTests: XCTestCase {
    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safarium-forge-test-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
            space: Snapshot.colorSpace,
            bitmapInfo: Snapshot.bitmapInfo
        )!
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        draw(ctx)
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

    private func renderThaiReferenceCG(width: Int = 1080, height: Int = 1920) -> CGImage {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: Snapshot.colorSpace, bitmapInfo: Snapshot.bitmapInfo
        )!
        ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.14, blue: 0.25, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let patches: [(CGFloat, CGFloat, CGFloat)] = [(0.9, 0.2, 0.2), (0.2, 0.85, 0.3), (0.95, 0.8, 0.15), (0.8, 0.25, 0.85)]
        for (i, rgb) in patches.enumerated() {
            ctx.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
            ctx.fill(CGRect(x: 80 + i * 230, y: 260, width: 190, height: 200))
        }
        let font = CTFontCreateWithName("Thonburi-Bold" as CFString, 72, nil)
        let attr = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ] as CFDictionary
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "ทดสอบ SafariumPQ ปิ๊ก" as CFString, attr)!)
        ctx.textPosition = CGPoint(x: 70, y: height / 2)
        CTLineDraw(line, ctx)
        return ctx.makeImage()!
    }

    private func writeTestWAV(
        url: URL,
        durationSeconds: Double,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        sampleAt: (_ frame: Int, _ ch: Int) -> Float
    ) throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)!
        let total = AVAudioFrameCount((durationSeconds * sampleRate).rounded())
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: total)!
        buf.frameLength = total
        for ch in 0..<channels {
            let p = buf.floatChannelData![ch]
            for i in 0..<Int(total) {
                p[i] = max(-1.0, min(1.0, sampleAt(i, ch)))
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try f.write(from: buf)
    }

    private func writeTestVideo(
        url: URL,
        width: Int = 320,
        height: Int = 180,
        fps: Int = 30,
        frames: Int = 30,
        draw: (CGContext, Int) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let sink = try AVAssetWriterSink(
            url: url, width: width, height: height, fps: fps,
            codec: .h264, bitrate: 1_500_000, pixelFormat: .nv12Left, profile: .lowRamClosedGOP
        )
        for i in 0..<frames {
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: Snapshot.colorSpace, bitmapInfo: Snapshot.bitmapInfo
            )!
            draw(ctx, i)
            try await sink.append(Snapshot(cgImage: ctx.makeImage()!))
        }
        try await sink.finish()
    }

    // MARK: - 1. ForgeRecipeValidator Tests (Even Dims, BT.709 Left, 1x Thai/HTML Shield)

    func testRecipeValidatorEnforcesEvenDimsColorimetryAnd1xThaiShield() throws {
        // Odd YUV dimensions rejected
        let oddRecipe = ForgeRecipe(
            inputs: [ForgeInputSpec(id: "bg", kind: .video, path: "/tmp/in.mp4")],
            timeline: ForgeTimelineSpec(fps: 30, width: 1081, height: 1920),
            output: ForgeOutputSpec(path: "/tmp/out.mp4", videoCodec: "h264", pixelFormat: "420v")
        )
        XCTAssertThrowsError(try ForgeRecipeValidator.validate(oddRecipe))

        // Invalid colorimetry (1-13-1 / bt601) rejected
        let badColor = ForgeRecipe(
            inputs: [ForgeInputSpec(id: "bg", kind: .video, path: "/tmp/in.mp4")],
            timeline: ForgeTimelineSpec(fps: 30, width: 1080, height: 1920),
            output: ForgeOutputSpec(path: "/tmp/out.mp4", videoCodec: "h264", colorimetry: "1-13-1")
        )
        XCTAssertThrowsError(try ForgeRecipeValidator.validate(badColor))

        // Segmented HLS fMP4 with tx3g rejected (-11875 guard)
        let badHLS = ForgeRecipe(
            inputs: [ForgeInputSpec(id: "bg", kind: .video, path: "/tmp/in.mp4")],
            timeline: ForgeTimelineSpec(fps: 30, width: 1080, height: 1920),
            output: ForgeOutputSpec(
                path: "/tmp/out.mp4",
                container: "fmp4_hls",
                subtitles: ForgeSubtitleOutputSpec(path: "/tmp/sub.srt", format: "tx3g", lang: "tha")
            )
        )
        XCTAssertThrowsError(try ForgeRecipeValidator.validate(badHLS))

        // 1x Thai/HTML Shield: autoReframe AFTER htmlOverlay MUST fail
        let badShield = ForgeRecipe(
            inputs: [
                ForgeInputSpec(id: "bg", kind: .video, path: "/tmp/in.mp4"),
                ForgeInputSpec(id: "hud", kind: .htmlOverlay, path: "/tmp/hud.html"),
            ],
            timeline: ForgeTimelineSpec(fps: 30, width: 1080, height: 1920),
            videoOps: [
                ForgeVideoOp(id: "comp", op: .overlay, base: "bg", over: "hud"),
                ForgeVideoOp(id: "scaledAfter", op: .autoReframe, input: "comp", aspect: "9:16"),
            ],
            output: ForgeOutputSpec(path: "/tmp/out.mp4")
        )
        XCTAssertThrowsError(try ForgeRecipeValidator.validate(badShield))

        // Valid 1x Thai/HTML Shield: autoReframe BEFORE overlay(over: hud) and splitMetalFX(overlay1xIn: hud)
        let goodShield = ForgeRecipe(
            inputs: [
                ForgeInputSpec(id: "bg", kind: .video, path: "/tmp/in.mp4"),
                ForgeInputSpec(id: "hud", kind: .htmlOverlay, path: "/tmp/hud.html", modeCDirtyHold: true),
            ],
            timeline: ForgeTimelineSpec(fps: 30, width: 1080, height: 1920),
            videoOps: [
                ForgeVideoOp(id: "reframed", op: .autoReframe, input: "bg", aspect: "9:16"),
                ForgeVideoOp(id: "graded", op: .colorGrade, input: "reframed", contrast: 1.05),
                ForgeVideoOp(id: "final", op: .overlay, base: "graded", over: "hud", x: "0", y: "0", opacity: "min(1.0, t/0.4)"),
            ],
            output: ForgeOutputSpec(path: "/tmp/out.mp4", videoCodec: "hevc", pixelFormat: "420v", colorimetry: "bt709_left_1_1_1")
        )
        let plan = try ForgeRecipeValidator.validate(goodShield)
        XCTAssertEqual(plan.orderedVideoOps.map(\.id), ["reframed", "graded", "final"])
        XCTAssertTrue(plan.htmlInputIDs.contains("hud"))
    }

    // MARK: - 2. APFSAutoStage Tests

    func testAPFSAutoStageInspectsVolumesClonesAndPublishesSafely() throws {
        let dir = try makeTempDir("apfs")
        defer { try? FileManager.default.removeItem(at: dir) }

        let apfsCaps = try APFSAutoStage.inspectVolume(at: dir)
        XCTAssertTrue(apfsCaps.isAPFS)
        XCTAssertTrue(apfsCaps.supportsClonefile)
        XCTAssertTrue(apfsCaps.supportsRenameExcl)

        // Optional ExFAT mount check when SAFARIUM_TEST_EXFAT_PATH is provided
        if let exfatPath = ProcessInfo.processInfo.environment["SAFARIUM_TEST_EXFAT_PATH"],
           !exfatPath.isEmpty,
           FileManager.default.fileExists(atPath: exfatPath) {
            let exfatCaps = try APFSAutoStage.inspectVolume(at: URL(fileURLWithPath: exfatPath))
            XCTAssertFalse(exfatCaps.isAPFS)
            XCTAssertFalse(exfatCaps.supportsClonefile)
            XCTAssertFalse(exfatCaps.supportsRenameExcl)
            XCTAssertTrue(exfatCaps.noPermissions)
        }

        let outURL = dir.appendingPathComponent("final.bin")
        let session = try APFSAutoStage.makeSession(for: outURL, overwrite: false)
        defer { session.cleanup() }
        XCTAssertTrue(session.stageVolume.supportsClonefile)

        let srcFile = dir.appendingPathComponent("source.bin")
        let payload = Data((0..<16384).map { UInt8($0 & 0xFF) })
        try payload.write(to: srcFile)

        let cloned = try session.stageCopyOrClone(from: srcFile, named: "cloned.bin")
        XCTAssertTrue(cloned.usedClonefile)
        try session.commit(stagedFile: cloned.url, overwrite: false)
        XCTAssertEqual(try Data(contentsOf: outURL), payload)

        // overwrite=false must protect existing output
        let second = session.fileURL("second.bin")
        try Data([1, 2, 3]).write(to: second)
        XCTAssertThrowsError(try session.commit(stagedFile: second, overwrite: false))
        XCTAssertEqual(try Data(contentsOf: outURL), payload)
    }

    // MARK: - 3. ForgeMetalFilters Tests

    func testTimeExprParserCubeLUTAndLRU() throws {
        let ctx = ForgeExprContext(t: 2.0, frame: 60, fps: 30, duration: 5.0, canvasWidth: 1080, canvasHeight: 1920, overlayWidth: 200, overlayHeight: 100)
        XCTAssertEqual(try ForgeTimeExprParser.compile("W - w - 40").evaluate(ctx), 840.0, accuracy: 1e-6)
        XCTAssertEqual(try ForgeTimeExprParser.compile("between(t, 1.0, 3.0)").evaluate(ctx), 1.0, accuracy: 1e-6)
        XCTAssertEqual(try ForgeTimeExprParser.compile("between(t, 3.0, 4.0)").evaluate(ctx), 0.0, accuracy: 1e-6)
        XCTAssertEqual(try ForgeTimeExprParser.compile("min(1.0, t / 4.0)").evaluate(ctx), 0.5, accuracy: 1e-6)
        XCTAssertEqual(try ForgeTimeExprParser.compile("t >= 2.0 ? 10 + 5 * 2 : 0").evaluate(ctx), 20.0, accuracy: 1e-6)

        // .cube 3D LUT (2x2x2 identity)
        let cubeText = """
        TITLE "Identity2"
        LUT_3D_SIZE 2
        0.0 0.0 0.0
        1.0 0.0 0.0
        0.0 1.0 0.0
        1.0 1.0 0.0
        0.0 0.0 1.0
        1.0 0.0 1.0
        0.0 1.0 1.0
        1.0 1.0 1.0
        """
        let lut = try ForgeCubeLUT.parse(string: cubeText)
        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.entriesRGBA.count, 32)

        // LRU <= 4 capacity
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let engine = try ForgeMetalFilterEngine(bakeArchive: false)
        let lru = ForgeTextureLRU(capacity: 4)
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 8, height: 8, mipmapped: false)
        for i in 1...5 {
            lru.insert("k\(i)", texture: engine.device.makeTexture(descriptor: td)!)
        }
        XCTAssertEqual(lru.count, 4)
        XCTAssertNil(lru.get("k1"))
        XCTAssertNotNil(lru.get("k5"))
    }

    func testMetalFiltersAllShadersAndWave2Bridge() throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let engine = try ForgeMetalFilterEngine(bakeArchive: false)
        let w = 128, h = 128

        let srcGreen = try makeBGRA(width: w, height: h) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 0.0, green: 0.95, blue: 0.0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 32, y: 32, width: 64, height: 64))
        }
        let dst = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: w, height: h, pixelFormat: .bgra)

        // ChromaKey + despill + disk erode
        try engine.applyChromaKey(srcPB: srcGreen, into: dst, keyRGB: SIMD3<Float>(0, 1, 0), similarity: 0.18, smoothness: 0.08, despillStrength: 0.9, erodeRadius: 1)
        let bgCorner = readPixel(dst, x: 4, y: 4)
        let fgCenter = readPixel(dst, x: 64, y: 64)
        XCTAssertLessThan(bgCorner.a, 10)
        XCTAssertGreaterThan(fgCenter.a, 240)
        XCTAssertGreaterThan(fgCenter.r, 180)

        // ColorGrade grayscale
        try engine.applyColorGrade(srcPB: srcGreen, into: dst, grayscale: 1.0)
        let grayPx = readPixel(dst, x: 64, y: 64)
        XCTAssertLessThan(abs(Int(grayPx.r) - Int(grayPx.g)), 3)
        XCTAssertLessThan(abs(Int(grayPx.g) - Int(grayPx.b)), 3)

        // Blur, Vignette, Grain, KenBurns, Geom, Deinterlace, Xfade, Stack
        try engine.applyGaussianBlur(srcPB: srcGreen, into: dst, sigma: 2.0)
        try engine.applyVignette(srcPB: srcGreen, into: dst, intensity: 0.6)
        try engine.applyGrain(srcPB: srcGreen, into: dst, amount: 0.05, frameSeed: 7)
        try engine.applyKenBurns(srcPB: srcGreen, into: dst, centerNorm: SIMD2<Float>(0.5, 0.5), zoom: 1.5)
        try engine.applyGeom(srcPB: srcGreen, into: dst, hflip: true, vflip: false)
        try engine.applyDeinterlace(prevPB: srcGreen, currPB: srcGreen, nextPB: srcGreen, into: dst, fieldOrder: .topFirst)
        try engine.applyXfade(pbA: srcGreen, pbB: srcGreen, into: dst, progress: 0.5, transition: .wipeLeft)
        try engine.applyStack(inputs: [srcGreen, srcGreen], into: dst, horizontal: true, padding: 4)

        // Wave2MetalEffects bridge (paperCutout & Split MetalFX + 1x Thai shield)
        try engine.applyWave2Effect(.paperCutout, srcPB: srcGreen, into: dst)
        let halfBG = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: 64, height: 64, pixelFormat: .bgra)
        try engine.applyGeom(srcPB: srcGreen, into: halfBG)
        try engine.applySplitMetalFX(backgroundLowResPB: halfBG, overlay1xPB: dst, into: dst)
    }

    // MARK: - 4. ForgeANE Tests (SafariumPQ + AutoReframe + PersonMatte)

    func testSafariumPQDiscriminatesBlurColorShiftAndThaiCorruption() throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let pq = try SafariumPQEngine()
        let refCG = renderThaiReferenceCG(width: 540, height: 960)
        let ciCtx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])
        let ciRef = CIImage(cgImage: refCG)

        // Identical
        let repId = try pq.evaluatePair(referenceCG: refCG, candidateCG: refCG, checkThaiOCR: true, expectedThaiText: "ทดสอบ")
        XCTAssertTrue(repId.passed)
        XCTAssertGreaterThan(repId.score0To100, 99.0)
        XCTAssertGreaterThan(repId.msSSIM, 0.999)
        XCTAssertEqual(repId.deltaE00P95, 0.0, accuracy: 0.01)
        XCTAssertTrue(repId.thaiOCROK)

        // ColorShift (+8% brightness / saturation -> fails dE00 p95 <= 2.0)
        let shiftCI = ciRef.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: 0.08,
            kCIInputContrastKey: 1.08,
            kCIInputSaturationKey: 1.15,
        ])
        let shiftCG = ciCtx.createCGImage(shiftCI, from: ciRef.extent)!
        let repColor = try pq.evaluatePair(referenceCG: refCG, candidateCG: shiftCG)
        XCTAssertGreaterThan(repColor.deltaE00P95, 2.0)
        XCTAssertFalse(repColor.passed)

        // Corrupt Thai text region (erases Thai word -> catches via ANE FeaturePrint & Thai OCR!)
        let corruptCtx = CGContext(
            data: nil, width: 540, height: 960, bitsPerComponent: 8, bytesPerRow: 540 * 4,
            space: Snapshot.colorSpace, bitmapInfo: Snapshot.bitmapInfo
        )!
        corruptCtx.draw(refCG, in: CGRect(x: 0, y: 0, width: 540, height: 960))
        corruptCtx.setFillColor(CGColor(srgbRed: 0.08, green: 0.14, blue: 0.25, alpha: 1))
        corruptCtx.fill(CGRect(x: 60, y: 440, width: 420, height: 120))
        let corruptCG = corruptCtx.makeImage()!
        let repThai = try pq.evaluatePair(referenceCG: refCG, candidateCG: corruptCG, checkThaiOCR: true, expectedThaiText: "ทดสอบ")
        XCTAssertGreaterThan(repThai.aneFeatureDistance, 0.1)
        XCTAssertFalse(repThai.thaiOCROK)
        XCTAssertFalse(repThai.passed)
    }

    func testAutoReframeAndPersonMatteVideo() async throws {
        let dir = try makeTempDir("ane-vid")
        defer { try? FileManager.default.removeItem(at: dir) }

        let src16x9 = dir.appendingPathComponent("src_16x9.mp4")
        try await writeTestVideo(url: src16x9, width: 320, height: 180, fps: 15, frames: 15) { ctx, idx in
            // Scene cut halfway through at frame 8
            if idx < 8 {
                ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.15, blue: 0.25, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
                ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.4, blue: 0.2, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: 30 + idx * 5, y: 40, width: 70, height: 90))
            } else {
                ctx.setFillColor(CGColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
                ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.5, blue: 0.9, alpha: 1))
                ctx.fillEllipse(in: CGRect(x: 200, y: 40, width: 70, height: 90))
            }
        }

        let reframed = dir.appendingPathComponent("reframed_9x16.mp4")
        let refRep = try await ForgeAutoReframe.reframeVideo(
            inputURL: src16x9, aspect: "9:16", outputHeight: 320, outputURL: reframed, overwrite: false
        )
        XCTAssertEqual(refRep.frames, 15)
        XCTAssertGreaterThanOrEqual(refRep.sceneCuts, 1)
        XCTAssertEqual(refRep.outputWidth, 180)
        XCTAssertEqual(refRep.outputHeight, 320)

        let matteOut = dir.appendingPathComponent("matte_mask.mp4")
        let matteRep = try await ForgePersonMatte.matteVideo(
            inputURL: src16x9, mode: .personFast, temporalEMA: 0.35,
            codec: .h264, maskOnly: true, maxFrames: 5, outputURL: matteOut, overwrite: false
        )
        XCTAssertEqual(matteRep.frames, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: matteOut.path))
    }

    // MARK: - 5. ForgeAudioDSP Tests

    func testAudioDSPEQSynthAcrossfadeTwoCursorSilenceTrimAndWaveform() async throws {
        let dir = try makeTempDir("audiodsp")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Procedural synth -> WAV
        let synthURL = dir.appendingPathComponent("pad.wav")
        let synthRep = try await ForgeProceduralSynth.renderToFile(
            spec: ForgeAudioSynthSpec(waveform: "amPad", carrierFrequenciesHz: [110, 220], modulationHz: 0.5, amplitude: 0.3, durationSeconds: 1.0),
            outputURL: synthURL
        )
        XCTAssertEqual(synthRep.durationSeconds, 1.0, accuracy: 0.02)

        // Two-cursor silenceTrim on [0.5s silence, 0.5s tone, 0.5s silence] -> ~0.6s active!
        let paddedURL = dir.appendingPathComponent("padded.wav")
        try writeTestWAV(url: paddedURL, durationSeconds: 1.5) { frame, _ in
            let t = Double(frame) / 48_000.0
            if t >= 0.5 && t < 1.0 {
                return Float(0.35 * sin(2.0 * .pi * 440.0 * t))
            }
            return 0.0
        }
        let trimmedURL = dir.appendingPathComponent("trimmed.wav")
        let trimRep = try await ForgeAudioDSP.silenceTrim(inputURL: paddedURL, outputURL: trimmedURL, thresholdDB: -36.0, paddingSeconds: 0.02)
        XCTAssertEqual(trimRep.mode, "two_cursor_O4096")
        XCTAssertLessThan(trimRep.trimmedDurationSeconds, 0.7)
        XCTAssertGreaterThan(trimRep.trimmedDurationSeconds, 0.45)

        // acrossfade
        let xfadeURL = dir.appendingPathComponent("xfade.wav")
        let xfRep = try await ForgeAudioDSP.crossfadeAudio(firstURL: synthURL, secondURL: trimmedURL, durationSeconds: 0.2, outputURL: xfadeURL)
        XCTAssertEqual(xfRep.durationSeconds, synthRep.durationSeconds + trimRep.trimmedDurationSeconds - 0.2, accuracy: 0.03)

        // Waveform bins 60..600
        let wf = try await ForgeAudioDSP.extractWaveform(inputURL: paddedURL, bins: 120)
        XCTAssertEqual(wf.binCount, 120)
        XCTAssertEqual(wf.peaks.count, 120)
        XCTAssertLessThan(wf.peaks[5], 0.01)
        XCTAssertGreaterThan(wf.peaks[60], 0.2)

        // vDSP_biquadD HPF + Loudnorm + PeakLimiter
        let eqOut = dir.appendingPathComponent("eq_norm.m4a")
        let procRep = try await ForgeAudioDSP.processAudio(
            inputURL: synthURL,
            outputURL: eqOut,
            eqSections: [ForgeBiquadSection(mode: .highpass, freqHz: 80.0)],
            compressorThresholdDB: -18.0,
            normalizeLUFS: -16.0,
            peakCeilingDBTP: -1.05
        )
        XCTAssertNotNil(procRep.integratedLUFS)
        if let tp = procRep.truePeakDBTP {
            XCTAssertLessThanOrEqual(tp, -0.8)
        }
    }

    // MARK: - 6. ForgeSheetAndQA & Dual PipeEncode Tests

    func testContactSheetComparisonStripQAAndDualPipeEncode() async throws {
        let dir = try makeTempDir("sheet-pipe")
        defer { try? FileManager.default.removeItem(at: dir) }

        let vidA = dir.appendingPathComponent("a.mp4")
        try await writeTestVideo(url: vidA, width: 160, height: 120, fps: 15, frames: 12) { ctx, idx in
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: CGFloat(idx) / 12.0, blue: 0.7, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        }

        let sheetURL = dir.appendingPathComponent("sheet.jpg")
        let manURL = dir.appendingPathComponent("sheet.json")
        let sheetRep = try await ForgeSheetAndQA.generateContactSheet(
            inputURL: vidA,
            outputURL: sheetURL,
            manifestURL: manURL,
            config: ForgeContactSheetConfig(cols: 3, rows: 2, tileWidth: 80, padding: 6, bgColorHex: "#1E293B", sampling: .everyFrames(2)),
            overwrite: false
        )
        XCTAssertEqual(sheetRep.tileCount, 6)
        XCTAssertEqual(sheetRep.width, 3 * 80 + 4 * 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manURL.path))

        let stripURL = dir.appendingPathComponent("strip.png")
        let stripRep = try await ForgeSheetAndQA.makeComparisonStrip(referenceURL: vidA, candidateURL: vidA, outputURL: stripURL, samples: 3)
        XCTAssertEqual(stripRep.tileCount, 6)

        let qaRep = try await ForgeSheetAndQA.runQA(inputURL: vidA, referenceURL: vidA)
        XCTAssertTrue(qaRep.passed)
        XCTAssertEqual(qaRep.nativeQA.totalVideoFrames, 12)

        // Single-pass Dual PipeEncode: ProRes 4444 alpha .mov + H.264 .mp4 tee
        let w = 96, h = 64
        var rgbaFrame = Data(count: w * h * 4)
        rgbaFrame.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<w {
                    let off = (y * w + x) * 4
                    p[off] = 240
                    p[off + 1] = 60
                    p[off + 2] = 40
                    p[off + 3] = (x < w / 2) ? 255 : 0
                }
            }
        }
        var sent = 0
        let priMOV = dir.appendingPathComponent("alpha.mov")
        let secMP4 = dir.appendingPathComponent("comp.mp4")
        let pipeRep = try await ForgeSheetAndQA.pipeEncodeChunkSource(
            nextFrameData: { _ in
                if sent >= 6 { return nil }
                sent += 1
                return rgbaFrame
            },
            primaryOutputURL: priMOV,
            config: ForgePipeEncodeConfig(
                width: w, height: h, fps: 15, inputPixelFormat: .rgba,
                primaryCodec: .proRes4444, primaryPixelFormat: .bgra,
                secondaryOutputURL: secMP4, secondaryCodec: .h264, secondaryBackgroundHex: "#102030"
            )
        )
        XCTAssertEqual(pipeRep.frames, 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: priMOV.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secMP4.path))
    }

    // MARK: - 7. ForgeGraphExecutor End-to-End DAG Tests (WKWebView Mode C + Metal + AudioDSP + SafariumContainers + SafariumPQ)

    func testGraphExecutorEndToEndVideoHTMLThaiAudioDSPAndSafariumPQ() async throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let dir = try makeTempDir("graph-e2e")
        defer { try? FileManager.default.removeItem(at: dir) }

        let bgURL = dir.appendingPathComponent("bg.mp4")
        try await writeTestVideo(url: bgURL, width: 320, height: 240, fps: 15, frames: 12) { ctx, idx in
            ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.25 + 0.03 * CGFloat(idx), blue: 0.55, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 240))
            ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.6, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 30, y: 40, width: 80, height: 80))
        }

        // Write identity 2x2x2 .cube LUT
        let lutURL = dir.appendingPathComponent("id.cube")
        try """
        LUT_3D_SIZE 2
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """.write(to: lutURL, atomically: true, encoding: .utf8)

        // Static Thai HTML overlay for Mode C dirty-hold reuse
        let htmlURL = dir.appendingPathComponent("hud.html")
        try """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;width:320px;height:240px;background:transparent;overflow:hidden;font-family:-apple-system,"Thonburi",sans-serif;}
        .badge{position:absolute;left:24px;bottom:20px;padding:8px 16px;border-radius:8px;background:rgba(15,23,42,0.88);color:#fff;font-size:24px;font-weight:700;}
        </style></head><body><div class="badge">ทดสอบภาษาไทย</div></body></html>
        """.write(to: htmlURL, atomically: true, encoding: .utf8)

        let outURL = dir.appendingPathComponent("final.mp4")
        let recipe = ForgeRecipe(
            inputs: [
                ForgeInputSpec(id: "bg", kind: .video, path: bgURL.path),
                ForgeInputSpec(id: "lut", kind: .lut3d, path: lutURL.path),
                ForgeInputSpec(id: "hud", kind: .htmlOverlay, path: htmlURL.path, width: 320, height: 240, modeCDirtyHold: true),
                ForgeInputSpec(
                    id: "tone",
                    kind: .synthAudio,
                    synth: ForgeAudioSynthSpec(waveform: "sine", frequencyHz: 440, amplitude: 0.25, durationSeconds: 1.0)
                ),
            ],
            timeline: ForgeTimelineSpec(fps: 15, width: 320, height: 240, frameCount: 10),
            videoOps: [
                ForgeVideoOp(id: "lutted", op: .lut3d, input: "bg", lut: "lut", intensity: 0.9),
                ForgeVideoOp(id: "graded", op: .colorGrade, input: "lutted", contrast: 1.02),
                ForgeVideoOp(id: "final_v", op: .overlay, base: "graded", over: "hud", x: "0", y: "0", opacity: "1.0"),
            ],
            audioOps: [
                ForgeAudioOp(id: "hpf", op: .biquadEQ, input: "tone", eqMode: "highpass", freqHz: 80.0),
                ForgeAudioOp(id: "master_a", op: .loudnorm, input: "hpf", targetLUFS: -16.0, peakCeilingDBTP: -1.05),
            ],
            qaOps: ForgeQASpec(
                safariumPQMin: 90.0,
                maxDeltaE00P95: 2.0,
                referenceVideoPath: nil,
                thaiOCRLangs: ["th-TH"],
                faultChecks: ["black", "freeze", "silence"],
                failOnQA: true
            ),
            output: ForgeOutputSpec(
                path: outURL.path,
                videoCodec: "h264",
                pixelFormat: "420v",
                colorimetry: "bt709_left_1_1_1",
                closedGOP: true,
                overwrite: false
            )
        )

        let report = try await ForgeGraphExecutor.execute(recipe: recipe)
        XCTAssertEqual(report.framesRendered, 10)
        XCTAssertEqual(report.htmlFramesCaptured, 1)
        XCTAssertEqual(report.htmlFramesReusedDirtyHold, 9)
        XCTAssertTrue(report.qaReport?.passed ?? false)
        XCTAssertGreaterThan(report.primaryBytes, 1000)

        let probe = try await PacketProbe.inspect(url: outURL)
        XCTAssertTrue(probe.playable)
        XCTAssertTrue(probe.tracks.contains { $0.mediaType == "vide" })
        XCTAssertTrue(probe.tracks.contains { $0.mediaType == "soun" })

        // Self-compare via SafariumPQ including Thai OCR check on rendered output!
        let pqSelf = try await SafariumPQ.compareVideos(
            referenceURL: outURL, candidateURL: outURL, maxSamples: 3, checkThaiOCR: true, expectedThaiText: "ทดสอบ"
        )
        XCTAssertTrue(pqSelf.passed)
        XCTAssertTrue(pqSelf.thaiOCROK)
        XCTAssertGreaterThan(pqSelf.score0To100, 99.0)
    }

    func testGraphExecutorMKVDemuxDualTeeAndFileFMP4TX3G() async throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let dir = try makeTempDir("graph-mkv-fmp4")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcMP4 = dir.appendingPathComponent("src.mp4")
        try await writeTestVideo(url: srcMP4, width: 160, height: 120, fps: 15, frames: 18) { ctx, idx in
            ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.4 + 0.03 * CGFloat(idx), blue: 0.65, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        }
        let mkvURL = dir.appendingPathComponent("in.mkv")
        _ = try await EBMLMatroskaCodec.muxFromMP4OrMOV(inputURL: srcMP4, outputURL: mkvURL, docType: "matroska", overwrite: true)

        let srtURL = dir.appendingPathComponent("subs.srt")
        try "1\n00:00:00,000 --> 00:00:00,900\nทดสอบซับไทย fMP4\n".write(to: srtURL, atomically: true, encoding: .utf8)

        let fmp4Out = dir.appendingPathComponent("out_fmp4.mp4")
        let secMOV = dir.appendingPathComponent("out_prores.mov")
        let recipe = ForgeRecipe(
            inputs: [
                ForgeInputSpec(id: "v_mkv", kind: .video, path: mkvURL.path, demux: "mkv"),
                ForgeInputSpec(id: "subs", kind: .subtitles, path: srtURL.path, lang: "tha"),
            ],
            timeline: ForgeTimelineSpec(fps: 15, width: 160, height: 120, frameCount: 18),
            videoOps: [
                ForgeVideoOp(id: "graded", op: .colorGrade, input: "v_mkv", saturation: 1.05),
            ],
            output: ForgeOutputSpec(
                path: fmp4Out.path,
                secondaryPath: secMOV.path,
                secondaryCodec: "prores4444",
                videoCodec: "h264",
                pixelFormat: "420v",
                subtitles: ForgeSubtitleOutputSpec(input: "subs", format: "tx3g", lang: "tha"),
                fragmentIntervalSeconds: 0.4,
                overwrite: false
            )
        )

        let rep = try await ForgeGraphExecutor.execute(recipe: recipe)
        XCTAssertEqual(rep.framesRendered, 18)
        XCTAssertNotNil(rep.secondaryBytes)

        let fmp4Probe = try await PacketProbe.inspect(url: fmp4Out)
        XCTAssertTrue(fmp4Probe.playable)
        XCTAssertTrue(fmp4Probe.tracks.contains { $0.mediaType == "sbtl" })
        let bytes = try Data(contentsOf: fmp4Out)
        XCTAssertNotNil(bytes.range(of: Data("moof".utf8)))
    }

    func testGraphExecutorWebPTSRawPipeSplitMetalFXAndAudioMixSidechain() async throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let dir = try makeTempDir("graph-webp-ts-raw")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Animated WebP output via ForgeGraphExecutor + rawPipe + kenBurns + markerTexture
        let w = 64, h = 64
        var rgbFrame = Data(count: w * h * 3)
        rgbFrame.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<(w * h) {
                p[i * 3] = 200
                p[i * 3 + 1] = 80
                p[i * 3 + 2] = 40
            }
        }
        let webpOut = dir.appendingPathComponent("anim.webp")
        let webpRecipe = ForgeRecipe(
            inputs: [
                ForgeInputSpec(id: "pipe", kind: .rawPipe, width: w, height: h, fps: 10, pixelFormat: "rgb24"),
            ],
            timeline: ForgeTimelineSpec(fps: 10, width: w, height: h, frameCount: 3),
            videoOps: [
                ForgeVideoOp(id: "kb", op: .kenBurns, input: "pipe", width: w, height: h, zoomStart: 1.0, zoomEnd: 1.15),
                ForgeVideoOp(id: "mrk", op: .markerTexture, input: "kb"),
            ],
            output: ForgeOutputSpec(path: webpOut.path, container: "webp", videoCodec: "h264", pixelFormat: "bgra")
        )
        let webpRep = try await ForgeGraphExecutor.execute(recipe: webpRecipe) { _, _, _ in rgbFrame }
        XCTAssertEqual(webpRep.framesRendered, 3)
        let webpSrc = try XCTUnwrap(CGImageSourceCreateWithURL(webpOut as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(webpSrc), 3)

        // 2. MPEG-TS output + sidechainDuck + splitMetalFX (1x Thai Shield)
        let bgURL = dir.appendingPathComponent("bg_ts.mp4")
        try await writeTestVideo(url: bgURL, width: 160, height: 120, fps: 15, frames: 10) { ctx, idx in
            ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.2 + 0.05 * CGFloat(idx), blue: 0.4, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
        }
        let hudURL = dir.appendingPathComponent("hud_1x.html")
        try """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;width:160px;height:120px;background:transparent;font-family:"Thonburi",sans-serif;color:#fff;}
        </style></head><body><div style="padding:12px;font-size:18px;">ปิ๊ก</div></body></html>
        """.write(to: hudURL, atomically: true, encoding: .utf8)

        let tsOut = dir.appendingPathComponent("stream.ts")
        let tsRecipe = ForgeRecipe(
            inputs: [
                ForgeInputSpec(id: "bg", kind: .video, path: bgURL.path),
                ForgeInputSpec(id: "hud", kind: .htmlOverlay, path: hudURL.path, width: 160, height: 120, modeCDirtyHold: true),
                ForgeInputSpec(id: "vox", kind: .synthAudio, synth: ForgeAudioSynthSpec(waveform: "sine", frequencyHz: 600, amplitude: 0.3, durationSeconds: 0.8)),
                ForgeInputSpec(id: "bed", kind: .synthAudio, synth: ForgeAudioSynthSpec(waveform: "pinkNoise", amplitude: 0.15, durationSeconds: 0.8)),
            ],
            timeline: ForgeTimelineSpec(fps: 15, width: 160, height: 120, frameCount: 10),
            videoOps: [
                ForgeVideoOp(id: "halfBG", op: .geom, input: "bg", width: 80, height: 60),
                ForgeVideoOp(id: "splitOut", op: .splitMetalFX, lowResIn: "halfBG", overlay1xIn: "hud"),
            ],
            audioOps: [
                ForgeAudioOp(id: "ducked", op: .sidechainDuck, carrier: "bed", sidechain: "vox", thresholdDB: -30, duckDB: -12),
                ForgeAudioOp(id: "mixed", op: .mix, tracks: ["vox", "ducked"], normalizeLUFS: -16.0, peakCeilingDBTP: -1.05),
            ],
            output: ForgeOutputSpec(path: tsOut.path, container: "ts", videoCodec: "h264", pixelFormat: "420v")
        )
        let tsRep = try await ForgeGraphExecutor.execute(recipe: tsRecipe)
        XCTAssertEqual(tsRep.framesRendered, 10)
        let tsInspect = try MPEGTSCodec.inspect(url: tsOut)
        XCTAssertEqual(tsInspect.crcErrors, 0)
        XCTAssertTrue(tsInspect.tracks.contains { $0.kind == .video })
        XCTAssertTrue(tsInspect.tracks.contains { $0.kind == .audio })

        // Verify splitMetalFX rejects htmlOverlay inside lowResIn (1x Thai Shield)
        var badSplit = tsRecipe
        badSplit.videoOps = [
            ForgeVideoOp(id: "badSplit", op: .splitMetalFX, lowResIn: "hud", overlay1xIn: "bg"),
        ]
        XCTAssertThrowsError(try ForgeRecipeValidator.validate(badSplit))
    }
}
