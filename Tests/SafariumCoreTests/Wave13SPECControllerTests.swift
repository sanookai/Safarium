import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import SafariumCore
import XCTest

/// Wave 13 — SPEC (Safarium Perceptual Encoding Controller) end-to-end test suite.
/// Covers:
///   - 13A: `SPECAnalyzer` (hard-cut vs transient flash detection, spatial/temporal/noise/chromaEdge/banding metrics, Vision masks, JSON sidecar round-trip)
///   - 13B: `AdaptiveDenoiseController` (LookAhead conflict guards, text/chroma protection, grain preservation, adaptive low-light denoise, flash-skip IDR policy)
///   - 13C: `SPECController` (dry-run `plan`, `explain`, per-title convex-hull HLS ladder without upscaling, and real closed-loop VideoToolbox proxy optimization + final playable encode)
final class Wave13SPECControllerTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf-wave13-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Synthesizes a 3-second (90-frame @ 30fps) 320x180 multi-shot test video using native `AVAssetWriterSink`:
    /// - Shot 0 (frames 0..<30): static dark smooth gradient + crisp saturated red/white text-like bars
    /// - Shot 1 (frames 30..<60): hard-cut high-motion noisy block pattern
    /// - Shot 2 (frames 60..<90): steady midtone scene with a 1-frame bright white flash at frame 75
    private func synthesizeMultiShotClip(
        at url: URL,
        width: Int = 320,
        height: Int = 180,
        fps: Int = 30
    ) async throws {
        let sink = try AVAssetWriterSink(
            url: url,
            width: width,
            height: height,
            fps: fps,
            codec: .hevc10,
            bitrate: 4_500_000,
            pixelFormat: .p010,
            profile: .baseline
        )

        let totalFrames = fps * 3 // 90 frames
        let strideBytes = width * 4
        var bgra = [UInt8](repeating: 0, count: height * strideBytes)

        // Deterministic xorshift32 for reproducible noisy shot
        var rng: UInt32 = 0x5EED_1337
        @inline(__always)
        func nextByte() -> UInt8 {
            rng ^= rng << 13
            rng ^= rng >> 17
            rng ^= rng << 5
            return UInt8(rng & 0xFF)
        }

        for f in 0..<totalFrames {
            if f < 30 {
                // Shot 0: static dark smooth gradient (banding risk) + crisp saturated red & white text-like bars
                for y in 0..<height {
                    let rowOff = y * strideBytes
                    let gy = (y * 28) / max(1, height)
                    for x in 0..<width {
                        let gx = (x * 36) / max(1, width)
                        let baseV = min(72, 10 + gx + gy)
                        let off = rowOff + x * 4
                        bgra[off + 0] = UInt8(min(255, baseV + 18)) // B
                        bgra[off + 1] = UInt8(min(255, baseV + 4))  // G
                        bgra[off + 2] = UInt8(baseV)                // R
                        bgra[off + 3] = 255
                    }
                }
                // Draw crisp saturated red & white horizontal/vertical glyph-like bars in middle band
                for barRow in 0..<5 {
                    let yStart = 50 + barRow * 16
                    let isRed = (barRow % 2 == 0)
                    for y in yStart..<min(height, yStart + 6) {
                        let rowOff = y * strideBytes
                        for x in 24..<(width - 24) {
                            // Segment into crisp glyph-width strokes
                            if ((x / 6) % 3) != 2 {
                                let off = rowOff + x * 4
                                if isRed {
                                    bgra[off + 0] = 16
                                    bgra[off + 1] = 16
                                    bgra[off + 2] = 248
                                } else {
                                    bgra[off + 0] = 248
                                    bgra[off + 1] = 248
                                    bgra[off + 2] = 248
                                }
                                bgra[off + 3] = 255
                            }
                        }
                    }
                }
            } else if f < 60 {
                // Shot 1: hard-cut high-motion noisy block pattern
                let localF = f - 30
                let shiftX = localF * 13
                let shiftY = localF * 7
                for y in 0..<height {
                    let rowOff = y * strideBytes
                    let by = ((y + shiftY) / 16) % 2
                    for x in 0..<width {
                        let bx = ((x + shiftX) / 16) % 2
                        let bright = (bx ^ by) == 0
                        let n1 = Int(nextByte()) - 128
                        let n2 = Int(nextByte()) - 128
                        let n3 = Int(nextByte()) - 128
                        let baseR = bright ? 195 : 75
                        let baseG = bright ? 170 : 95
                        let baseB = bright ? 110 : 185
                        let off = rowOff + x * 4
                        bgra[off + 0] = UInt8(max(0, min(255, baseB + n1 / 2)))
                        bgra[off + 1] = UInt8(max(0, min(255, baseG + n2 / 2)))
                        bgra[off + 2] = UInt8(max(0, min(255, baseR + n3 / 2)))
                        bgra[off + 3] = 255
                    }
                }
            } else if f == 75 {
                // Shot 2 transient 1-frame bright white flash!
                for y in 0..<height {
                    let rowOff = y * strideBytes
                    for x in 0..<width {
                        let off = rowOff + x * 4
                        bgra[off + 0] = 250
                        bgra[off + 1] = 250
                        bgra[off + 2] = 250
                        bgra[off + 3] = 255
                    }
                }
            } else {
                // Shot 2: steady calm teal/amber split scene (identical before & after frame 75)
                for y in 0..<height {
                    let rowOff = y * strideBytes
                    let upper = y < (height / 2)
                    for x in 0..<width {
                        let off = rowOff + x * 4
                        if upper {
                            bgra[off + 0] = 145
                            bgra[off + 1] = 125
                            bgra[off + 2] = 70
                        } else {
                            bgra[off + 0] = 65
                            bgra[off + 1] = 135
                            bgra[off + 2] = 150
                        }
                        bgra[off + 3] = 255
                    }
                }
            }

            try await sink.append { pb in
                CVPixelBufferLockBaseAddress(pb, [])
                defer { CVPixelBufferUnlockBaseAddress(pb, []) }
                guard let dst = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else {
                    throw SafariumError.encode("null pixel buffer in test synthesizer")
                }
                let dstStride = CVPixelBufferGetBytesPerRow(pb)
                bgra.withUnsafeBufferPointer { srcBuf in
                    guard let srcBase = srcBuf.baseAddress else { return }
                    for row in 0..<height {
                        memcpy(dst.advanced(by: row * dstStride), srcBase.advanced(by: row * strideBytes), strideBytes)
                    }
                }
            }
        }

        try await sink.finish()
    }

    // MARK: - Test 1: Wave 13A SPECAnalyzer & Sidecar Persistence

    func testSPECAnalyzerDetectsHardCutFlashMetricsAndSidecarRoundTrip() async throws {
        let dir = try makeTempDir("analyzer")
        defer { try? FileManager.default.removeItem(at: dir) }

        let clipURL = dir.appendingPathComponent("multishot.mp4")
        try await synthesizeMultiShotClip(at: clipURL)

        let sidecar = try await SPECAnalyzer.analyze(
            inputURL: clipURL,
            enableVisionMasks: true,
            maxSampleFrames: 240
        )

        XCTAssertEqual(sidecar.schemaVersion, 1)
        XCTAssertEqual(sidecar.width, 320)
        XCTAssertEqual(sidecar.height, 180)
        XCTAssertGreaterThanOrEqual(sidecar.totalFrames, 85)
        XCTAssertGreaterThan(sidecar.durationSeconds, 2.5)
        XCTAssertGreaterThan(sidecar.analysisElapsedMs, 0.0)
        XCTAssertGreaterThanOrEqual(sidecar.shots.count, 3, "Expected multi-shot segmentation")

        // Verify hard cut and flash are both detected and distinguished!
        let hardCuts = sidecar.shots.filter { $0.cutType == .hardCut }
        let flashes = sidecar.shots.filter { $0.cutType == .flash }
        XCTAssertGreaterThanOrEqual(hardCuts.count, 1, "Expected at least one .hardCut transition (shots=\(sidecar.shots.map { ($0.startFrame, $0.endFrame, $0.cutType) }))")
        XCTAssertGreaterThanOrEqual(flashes.count, 1, "Expected 1-frame white flash at frame 75 to be classified as .flash (shots=\(sidecar.shots.map { ($0.startFrame, $0.endFrame, $0.cutType) }))")
        if let flashShot = flashes.first {
            XCTAssertTrue((73...77).contains(flashShot.startFrame), "Flash should align near frame 75, got \(flashShot.startFrame)")
        }

        // Verify Shot 0 (static dark gradient + red/white bars) vs Shot 1 (noisy moving blocks)
        let shot0 = try XCTUnwrap(sidecar.shots.first)
        let noisyShot = try XCTUnwrap(
            sidecar.shots.first(where: { $0.startFrame >= 25 && $0.startFrame <= 40 && $0.cutType != .flash })
        )

        XCTAssertLessThan(shot0.temporalComplexity, 0.10, "Static Shot 0 should have low temporal complexity")
        XCTAssertGreaterThan(shot0.chromaEdgeComplexity, 0.20, "Red/white bars on dark bg should register high chromaEdgeComplexity")
        XCTAssertGreaterThan(shot0.bandingRisk, 0.15, "Dark smooth gradient should register bandingRisk")

        XCTAssertGreaterThan(noisyShot.temporalComplexity, shot0.temporalComplexity + 0.15, "Noisy moving Shot 1 must have much higher temporal complexity than Shot 0")
        XCTAssertGreaterThan(noisyShot.spatialComplexity, shot0.spatialComplexity, "Noisy Shot 1 should have higher spatial complexity")
        XCTAssertGreaterThan(noisyShot.noiseSigma, 0.25, "Noisy Shot 1 should register elevated noiseSigma (got \(noisyShot.noiseSigma))")
        XCTAssertGreaterThan(noisyShot.motionMagnitude, 0.20, "Moving Shot 1 should register motionMagnitude")

        // Verify all metrics are well-bounded
        for shot in sidecar.shots {
            XCTAssertGreaterThanOrEqual(shot.hdrHeadroom, 1.0)
            XCTAssertTrue((0.0...1.0).contains(shot.spatialComplexity))
            XCTAssertTrue((0.0...1.0).contains(shot.temporalComplexity))
            XCTAssertTrue((0.0...1.0).contains(shot.noiseSigma))
            XCTAssertTrue((0.0...1.0).contains(shot.chromaEdgeComplexity))
            XCTAssertTrue((0.0...1.0).contains(shot.bandingRisk))
        }

        // Verify sidecar JSON save & load round-trip
        let sidecarURL = dir.appendingPathComponent("sidecar/analysis.spec.json")
        try sidecar.save(to: sidecarURL)
        let reloaded = try SPECAnalysisSidecar.load(from: sidecarURL)
        XCTAssertEqual(reloaded, sidecar)
    }

    // MARK: - Test 2: Wave 13B AdaptiveDenoiseController

    func testAdaptiveDenoiseControllerLookAheadProtectionAndIDRPolicy() {
        // LookAhead API conflict safety rules
        XCTAssertEqual(AdaptiveDenoiseController.resolveLookAhead(mode: .liveUltraLowLatency, useTwoPass: false), 0)
        XCTAssertNil(AdaptiveDenoiseController.resolveLookAhead(mode: .vodQuality, useTwoPass: true))
        XCTAssertNil(AdaptiveDenoiseController.resolveLookAhead(mode: .twoPass, useTwoPass: false))
        XCTAssertEqual(AdaptiveDenoiseController.resolveLookAhead(mode: .liveQuality, useTwoPass: false), 2)
        XCTAssertEqual(AdaptiveDenoiseController.resolveLookAhead(mode: .vodQuality, useTwoPass: false), 16)
        XCTAssertEqual(AdaptiveDenoiseController.resolveLookAhead(mode: .screenContent, useTwoPass: false), 16)
        XCTAssertEqual(AdaptiveDenoiseController.resolveLookAhead(mode: .animation, useTwoPass: false), 8)

        let shots: [SPECShotMetrics] = [
            // Shot 0: sharp UI text + chroma edge (must protect text, cap denoise <= 0.05, boost bitrate)
            SPECShotMetrics(
                shotIndex: 0, startFrame: 0, endFrame: 29, startSeconds: 0.0, endSeconds: 1.0,
                cutType: .steady, spatialComplexity: 0.35, temporalComplexity: 0.02, motionMagnitude: 0.02,
                noiseSigma: 0.35, grainProbability: 0.05, textMaskRatio: 0.22, faceMaskRatio: 0.0,
                chromaEdgeComplexity: 0.65, hdrHeadroom: 1.0, bandingRisk: 0.20
            ),
            // Shot 1: hard-cut noisy low-light shot (must force IDR, apply adaptive denoise 0.20..0.60)
            SPECShotMetrics(
                shotIndex: 1, startFrame: 30, endFrame: 59, startSeconds: 1.0, endSeconds: 2.0,
                cutType: .hardCut, spatialComplexity: 0.45, temporalComplexity: 0.25, motionMagnitude: 0.25,
                noiseSigma: 0.60, grainProbability: 0.10, textMaskRatio: 0.0, faceMaskRatio: 0.0,
                chromaEdgeComplexity: 0.12, hdrHeadroom: 1.0, bandingRisk: 0.10
            ),
            // Shot 2: film-grain cinema shot (must disable denoise, preserveGrain = true, boost bitrate)
            SPECShotMetrics(
                shotIndex: 2, startFrame: 60, endFrame: 89, startSeconds: 2.0, endSeconds: 3.0,
                cutType: .uiTransition, spatialComplexity: 0.50, temporalComplexity: 0.18, motionMagnitude: 0.18,
                noiseSigma: 0.48, grainProbability: 0.78, textMaskRatio: 0.0, faceMaskRatio: 0.0,
                chromaEdgeComplexity: 0.10, hdrHeadroom: 1.0, bandingRisk: 0.15
            ),
            // Shot 3: transient 1-frame flash (must NOT force IDR!)
            SPECShotMetrics(
                shotIndex: 3, startFrame: 90, endFrame: 90, startSeconds: 3.0, endSeconds: 3.033,
                cutType: .flash, spatialComplexity: 0.05, temporalComplexity: 0.90, motionMagnitude: 0.50,
                noiseSigma: 0.02, grainProbability: 0.0, textMaskRatio: 0.0, faceMaskRatio: 0.0,
                chromaEdgeComplexity: 0.0, hdrHeadroom: 1.0, bandingRisk: 0.0
            ),
        ]

        let vodPolicies = AdaptiveDenoiseController.decide(
            shots: shots,
            protectText: true,
            protectFaces: true,
            preserveGrain: false,
            bandingSensitive: true,
            latencyMode: .vodQuality,
            useTwoPass: false
        )
        XCTAssertEqual(vodPolicies.count, 4)

        // Shot 0: text/chroma protection
        XCTAssertLessThanOrEqual(vodPolicies[0].denoiseStrength, 0.05)
        XCTAssertGreaterThanOrEqual(vodPolicies[0].recommendedBitrateMultiplier, 1.15)
        XCTAssertTrue(vodPolicies[0].reasons.contains("Protected sharp text/UI chroma edges"))
        XCTAssertEqual(vodPolicies[0].lookAheadFrames, 16)

        // Shot 1: adaptive denoise + hard-cut IDR
        XCTAssertGreaterThanOrEqual(vodPolicies[1].denoiseStrength, 0.20)
        XCTAssertLessThanOrEqual(vodPolicies[1].denoiseStrength, 0.60)
        XCTAssertFalse(vodPolicies[1].preserveGrain)
        XCTAssertTrue(vodPolicies[1].forceIDRAtStart)
        XCTAssertTrue(vodPolicies[1].reasons.contains("Applied adaptive temporal denoise for low-light noise"))

        // Shot 2: film grain preservation + uiTransition IDR
        XCTAssertEqual(vodPolicies[2].denoiseStrength, 0.0)
        XCTAssertTrue(vodPolicies[2].preserveGrain)
        XCTAssertGreaterThanOrEqual(vodPolicies[2].recommendedBitrateMultiplier, 1.10)
        XCTAssertTrue(vodPolicies[2].forceIDRAtStart)

        // Shot 3: flash skips forced IDR
        XCTAssertFalse(vodPolicies[3].forceIDRAtStart)

        // Two-pass mode strictly disables LookAhead
        let twoPassPolicies = AdaptiveDenoiseController.decide(
            shots: shots,
            latencyMode: .vodQuality,
            useTwoPass: true
        )
        for pol in twoPassPolicies {
            XCTAssertNil(pol.lookAheadFrames, "2-pass must disable LookAhead to avoid VTMultiPassStorage conflict")
        }
    }

    // MARK: - Test 3: Wave 13C Plan, Explain & Per-Title HLS Ladder

    func testSPECPlanExplainAndPerTitleHLSLadder() async throws {
        let dir = try makeTempDir("plan-ladder")
        defer { try? FileManager.default.removeItem(at: dir) }

        let clipURL = dir.appendingPathComponent("multishot.mp4")
        try await synthesizeMultiShotClip(at: clipURL)
        let sidecar = try await SPECAnalyzer.analyze(inputURL: clipURL, enableVisionMasks: true)

        let contract = SPECQualityContract(
            targetVMAF: 95.0,
            targetMSSSIM: 0.99,
            maxDeltaE00P95: 2.5,
            protectText: true,
            protectFaces: true,
            preserveGrain: false,
            bandingSensitive: true,
            codec: .hevc10
        )

        let plan = try await SPECController.plan(inputURL: clipURL, contract: contract, sidecar: sidecar)
        XCTAssertEqual(plan.codec, VideoCodec.hevc10.rawValue)
        XCTAssertEqual(plan.shots, sidecar.shots.count)
        XCTAssertGreaterThan(plan.expectedMbps, 0.1)
        XCTAssertFalse(plan.forcedIDRFrames.isEmpty, "Hard cut shots should produce forced IDR frames")

        // Ensure flash frame is NOT in forcedIDRFrames
        if let flashShot = sidecar.shots.first(where: { $0.cutType == .flash }) {
            XCTAssertFalse(
                plan.forcedIDRFrames.contains(flashShot.startFrame),
                "Flash frame \(flashShot.startFrame) must not be in forcedIDRFrames"
            )
        }

        let explanations = SPECController.explain(plan: plan)
        XCTAssertGreaterThanOrEqual(explanations.count, plan.shots + 2)
        XCTAssertTrue(explanations.first?.contains("SPEC Plan:") == true)

        // Per-title HLS ladder comparison: static 1080p slides vs high-motion 1080p sports
        let slidesSidecar = SPECAnalysisSidecar(
            sourcePath: "/synthetic/slides_1080p.mp4",
            width: 1920,
            height: 1080,
            fps: 30.0,
            durationSeconds: 30.0,
            totalFrames: 900,
            isHDRSource: false,
            analysisElapsedMs: 12.0,
            shots: [
                SPECShotMetrics(
                    shotIndex: 0, startFrame: 0, endFrame: 899, startSeconds: 0, endSeconds: 30,
                    cutType: .steady, spatialComplexity: 0.22, temporalComplexity: 0.01, motionMagnitude: 0.01,
                    noiseSigma: 0.01, grainProbability: 0.0, textMaskRatio: 0.30, faceMaskRatio: 0.0,
                    chromaEdgeComplexity: 0.40, hdrHeadroom: 1.0, bandingRisk: 0.10
                )
            ]
        )

        let sportsSidecar = SPECAnalysisSidecar(
            sourcePath: "/synthetic/sports_1080p.mp4",
            width: 1920,
            height: 1080,
            fps: 30.0,
            durationSeconds: 30.0,
            totalFrames: 900,
            isHDRSource: false,
            analysisElapsedMs: 15.0,
            shots: [
                SPECShotMetrics(
                    shotIndex: 0, startFrame: 0, endFrame: 899, startSeconds: 0, endSeconds: 30,
                    cutType: .steady, spatialComplexity: 0.78, temporalComplexity: 0.65, motionMagnitude: 0.72,
                    noiseSigma: 0.32, grainProbability: 0.55, textMaskRatio: 0.0, faceMaskRatio: 0.02,
                    chromaEdgeComplexity: 0.15, hdrHeadroom: 1.0, bandingRisk: 0.10
                )
            ]
        )

        let slidesLadder = SPECController.planPerTitleHLSLadder(sidecar: slidesSidecar, maxRungs: 4)
        let sportsLadder = SPECController.planPerTitleHLSLadder(sidecar: sportsSidecar, maxRungs: 4)

        XCTAssertTrue(slidesLadder.analysisReused)
        XCTAssertTrue(sportsLadder.analysisReused)
        XCTAssertGreaterThanOrEqual(slidesLadder.rungs.count, 2)
        XCTAssertGreaterThanOrEqual(sportsLadder.rungs.count, 2)
        XCTAssertLessThanOrEqual(slidesLadder.rungs.count, 4)
        XCTAssertLessThanOrEqual(sportsLadder.rungs.count, 4)

        // Never upscale above source resolution
        for rung in slidesLadder.rungs {
            XCTAssertLessThanOrEqual(rung.width, 1920)
            XCTAssertLessThanOrEqual(rung.height, 1080)
        }
        for rung in sportsLadder.rungs {
            XCTAssertLessThanOrEqual(rung.width, 1920)
            XCTAssertLessThanOrEqual(rung.height, 1080)
        }

        // Slides top-rung bitrate MUST be strictly lower than high-motion sports top-rung bitrate!
        let slidesTopBR = try XCTUnwrap(slidesLadder.rungs.last?.bitrate)
        let sportsTopBR = try XCTUnwrap(sportsLadder.rungs.last?.bitrate)
        XCTAssertLessThan(
            slidesTopBR,
            sportsTopBR,
            "Slides ladder top bitrate (\(slidesTopBR)) must be lower than high-motion sports (\(sportsTopBR))"
        )

        // Also check small 320x180 source never upscales
        let smallLadder = SPECController.planPerTitleHLSLadder(sidecar: sidecar, maxRungs: 4)
        XCTAssertFalse(smallLadder.rungs.isEmpty)
        for rung in smallLadder.rungs {
            XCTAssertLessThanOrEqual(rung.width, sidecar.width)
            XCTAssertLessThanOrEqual(rung.height, sidecar.height)
        }
    }

    // MARK: - Test 4: Wave 13C End-to-End Closed-Loop Quality-Target Encode

    func testSPECClosedLoopEncodeEndToEnd() async throws {
        let dir = try makeTempDir("closed-loop")
        defer { try? FileManager.default.removeItem(at: dir) }

        let inputURL = dir.appendingPathComponent("input_3s.mp4")
        let outputURL = dir.appendingPathComponent("output_spec_hevc10.mp4")
        try await synthesizeMultiShotClip(at: inputURL)

        let contract = SPECQualityContract(
            targetVMAF: 94.0,
            targetMSSSIM: 0.96,
            maxDeltaE00P95: 4.5,
            protectText: true,
            protectFaces: true,
            preserveGrain: false,
            bandingSensitive: true,
            hdrPolicy: .preserve,
            intent: "balanced_delivery",
            codec: .hevc10
        )

        let report = try await SPECController.encodeWithClosedLoop(
            inputURL: inputURL,
            outputURL: outputURL,
            contract: contract,
            maxProxyIterations: 3
        )

        // Verify proxy optimization ran and measured real metrics
        XCTAssertGreaterThanOrEqual(report.proxyIterations.count, 1)
        XCTAssertLessThanOrEqual(report.proxyIterations.count, 3)
        for iter in report.proxyIterations {
            XCTAssertGreaterThan(iter.encodedBytes, 0)
            XCTAssertGreaterThan(iter.measuredMSSSIM, 0.5)
            XCTAssertLessThanOrEqual(iter.measuredMSSSIM, 1.0)
            XCTAssertGreaterThanOrEqual(iter.measuredDeltaE00P95, 0.0)
            XCTAssertTrue(iter.measuredDeltaE00P95.isFinite)
        }

        // Verify final output metrics & report fields
        XCTAssertEqual(report.finalOutputPath, outputURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertGreaterThan(report.finalBytes, 1_000)
        XCTAssertGreaterThan(report.finalBitrateMbps, 0.01)
        XCTAssertGreaterThan(report.elapsedSeconds, 0.0)
        XCTAssertGreaterThan(report.measuredMSSSIM, 0.85)
        XCTAssertLessThanOrEqual(report.measuredMSSSIM, 1.0)
        XCTAssertGreaterThanOrEqual(report.measuredDeltaE00P95, 0.0)
        XCTAssertFalse(report.explanations.isEmpty)

        // Verify final MP4 is valid, playable, and decodable via AVFoundation
        let outAsset = AVURLAsset(url: outputURL)
        let videoTracks = try await outAsset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)
        let outDur = try await outAsset.load(.duration)
        XCTAssertGreaterThan(outDur.seconds, 2.5)

        let track = try XCTUnwrap(videoTracks.first)
        let reader = try AVAssetReader(asset: outAsset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(out)
        XCTAssertTrue(reader.startReading())
        var decodedCount = 0
        while out.copyNextSampleBuffer() != nil {
            decodedCount += 1
        }
        XCTAssertGreaterThanOrEqual(decodedCount, 80, "Final output should decode full 3s frame sequence")
    }
}
