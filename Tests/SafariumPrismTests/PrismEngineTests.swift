import AVFoundation
import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import ImageIO
import SafariumCore
import SafariumForgeCore
@testable import SafariumPrism
import Vision
import XCTest

final class PrismEngineTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        try super.tearDownWithError()
    }

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safarium-prism-test-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    // MARK: - Test 0: Stub & Capabilities

    func testStubAndCapabilitiesReport() async throws {
        XCTAssertEqual(SafariumPrismModuleInfo.version, "1.0.0")
        XCTAssertEqual(SafariumPrismModuleInfo.schema, "safarium-prism/scene-v1")

        let caps = try await PrismHybridEngine.inspectCapabilities()
        XCTAssertEqual(caps.schema, "safarium-prism/scene-v1")
        let hasBlender = FileManager.default.isExecutableFile(atPath: "/Applications/Blender.app/Contents/MacOS/Blender")
        XCTAssertEqual(caps.blenderAvailable, hasBlender, "Capabilities blenderAvailable mismatch")
        if !AppleMacOSBackend.current.isRunningInVM {
            XCTAssertTrue(caps.blenderAvailable, "Expected Blender 5.2.2 LTS at /Applications/Blender.app")
        }
        XCTAssertTrue(caps.workerScriptValid, "Expected valid prism-blender-worker.py")
        XCTAssertTrue(caps.webkitWebGL2Available, "Expected headless WKWebView WebGL2 support")
        XCTAssertEqual(caps.metalfxAvailable, PrismMetalFXVerifier.isSupported(), "Capabilities metalfxAvailable mismatch")
        XCTAssertTrue(caps.taskpolicyAvailable, "Expected /usr/sbin/taskpolicy")
    }

    // MARK: - Test 1: Coordinate & Portrait AUTO Camera Math

    func testCameraAndCoordinateMathRoundTripIncludingPortraitAutoTrap() throws {
        struct CaseSpec {
            let posB: PrismVec3
            let eulerB: (Double, Double, Double)
            let lensMM: Double
            let sensorW: Double
            let sensorH: Double
            let fit: PrismSensorFit
            let width: Int
            let height: Int
            let shiftX: Double
            let shiftY: Double
        }

        let cases: [CaseSpec] = [
            CaseSpec(posB: PrismVec3(x: 0.0, y: -5.2, z: 2.1), eulerB: (1.1, -0.2, 0.4), lensMM: 35.0, sensorW: 36.0, sensorH: 24.0, fit: .auto, width: 1080, height: 1920, shiftX: 0.0, shiftY: 0.0),
            CaseSpec(posB: PrismVec3(x: 3.4, y: -2.8, z: 1.9), eulerB: (0.95, 0.15, -0.7), lensMM: 50.0, sensorW: 36.0, sensorH: 24.0, fit: .auto, width: 1920, height: 1080, shiftX: 0.05, shiftY: -0.03),
            CaseSpec(posB: PrismVec3(x: -2.1, y: 4.3, z: 3.2), eulerB: (2.2, 0.4, 2.5), lensMM: 24.0, sensorW: 36.0, sensorH: 24.0, fit: .horizontal, width: 1080, height: 1920, shiftX: -0.1, shiftY: 0.04),
            CaseSpec(posB: PrismVec3(x: 1.5, y: -6.0, z: 0.5), eulerB: (1.4, -0.1, 0.1), lensMM: 36.0, sensorW: 36.0, sensorH: 24.0, fit: .vertical, width: 1080, height: 1920, shiftX: 0.13, shiftY: -0.07),
            CaseSpec(posB: PrismVec3(x: 0.0, y: -7.6, z: 5.1), eulerB: (1.0, 0.0, 0.0), lensMM: 36.0, sensorW: 36.0, sensorH: 24.0, fit: .vertical, width: 1080, height: 1080, shiftX: 0.0, shiftY: 0.0),
        ]

        var maxAbsErr = 0.0
        for c in cases {
            let qB = PrismCameraTransform.eulerXYZToQuat(rx: c.eulerB.0, ry: c.eulerB.1, rz: c.eulerB.2)
            let pT = PrismCameraTransform.blenderPointToThree(c.posB)
            let qT = PrismCameraTransform.blenderQuatToThree(qB)
            let (fovY, aspect) = PrismCameraTransform.blenderToThreeFOVYDeg(
                lensMM: c.lensMM,
                sensorWidthMM: c.sensorW,
                sensorHeightMM: c.sensorH,
                sensorFit: c.fit,
                width: c.width,
                height: c.height
            )

            let pB2 = PrismCameraTransform.threePointToBlender(pT)
            let qB2 = PrismCameraTransform.threeQuatToBlender(qT)
            let eul2 = PrismCameraTransform.quatToEulerXYZ(qB2)
            let qB2FromEul = PrismCameraTransform.eulerXYZToQuat(rx: eul2.rx, ry: eul2.ry, rz: eul2.rz)
            let lens2 = PrismCameraTransform.threeFOVYDegToBlenderLensMM(
                fovYDeg: fovY,
                sensorWidthMM: c.sensorW,
                sensorHeightMM: c.sensorH,
                sensorFit: c.fit,
                width: c.width,
                height: c.height
            )

            let errP = max(abs(c.posB.x - pB2.x), max(abs(c.posB.y - pB2.y), abs(c.posB.z - pB2.z)))
            let errQ = Self.quatError(qB, qB2)
            let errE = Self.quatError(qB, qB2FromEul)
            let errL = abs(c.lensMM - lens2)
            maxAbsErr = max(maxAbsErr, errP, errQ, errE, errL)

            XCTAssertGreaterThan(aspect, 0.0)
            let camIR = PrismCameraIR.fromBlender(
                name: "TestCam",
                positionBlender: c.posB,
                quaternionBlender: qB,
                lensMM: c.lensMM,
                sensorWidthMM: c.sensorW,
                sensorHeightMM: c.sensorH,
                sensorFit: c.fit,
                width: c.width,
                height: c.height,
                shiftX: c.shiftX,
                shiftY: c.shiftY
            )
            XCTAssertEqual(camIR.positionThree, pT)
            XCTAssertLessThan(Self.quatError(camIR.quaternionBlender, qB), 1e-12)
        }
        XCTAssertLessThan(maxAbsErr, 1e-6)

        // Explicit Portrait AUTO Trap check:
        // At 1080x1920 with 36x24 sensor and 35mm lens, AUTO fits sensor_width=36mm vertically -> ~54.432 deg (NOT 37.849 deg!).
        let (portraitAutoFovY, portraitAspect) = PrismCameraTransform.blenderToThreeFOVYDeg(
            lensMM: 35.0,
            sensorWidthMM: 36.0,
            sensorHeightMM: 24.0,
            sensorFit: .auto,
            width: 1080,
            height: 1920
        )
        XCTAssertEqual(portraitAspect, 1080.0 / 1920.0, accuracy: 1e-9)
        XCTAssertEqual(portraitAutoFovY, 54.432223, accuracy: 0.001)
        XCTAssertGreaterThan(abs(portraitAutoFovY - 37.849), 15.0)

        // Test shift_x / shift_y NDC shift direction and scaling (verified against Blender 5.2 world_to_camera_view)
        let cam0 = PrismCameraIR.fromBlender(
            positionBlender: PrismVec3(x: 0, y: -5, z: 0),
            quaternionBlender: PrismCameraTransform.eulerXYZToQuat(rx: .pi / 2, ry: 0, rz: 0),
            lensMM: 35, sensorWidthMM: 36, sensorHeightMM: 24, sensorFit: .auto,
            width: 1080, height: 1920, shiftX: 0, shiftY: 0
        )
        let camShifted = PrismCameraIR.fromBlender(
            positionBlender: PrismVec3(x: 0, y: -5, z: 0),
            quaternionBlender: PrismCameraTransform.eulerXYZToQuat(rx: .pi / 2, ry: 0, rz: 0),
            lensMM: 35, sensorWidthMM: 36, sensorHeightMM: 24, sensorFit: .auto,
            width: 1080, height: 1920, shiftX: 0.13, shiftY: -0.07
        )
        let originThree = PrismVec3(x: 0, y: 0, z: 0)
        let ndc0 = PrismCameraTransform.projectPointToNDC(worldPointThree: originThree, camera: cam0)
        let ndcS = PrismCameraTransform.projectPointToNDC(worldPointThree: originThree, camera: camShifted)
        XCTAssertEqual(ndcS.ndcX - ndc0.ndcX, -2.0 * 0.13 / (1080.0 / 1920.0), accuracy: 1e-6)
        XCTAssertEqual(ndcS.ndcY - ndc0.ndcY, -2.0 * (-0.07), accuracy: 1e-6)

        // Test Timeline cuts & deterministic SceneIR SHA-256
        let timeline = PrismTimelineIR(fps: 30, frameStart: 1, frameEnd: 60, durationSeconds: 2.0, cuts: [0.5, 1.25])
        XCTAssertTrue(timeline.hasCutBetween(0.45, 0.55))
        XCTAssertFalse(timeline.hasCutBetween(0.55, 0.80))

        let ir = PrismSceneIR(
            sceneName: "Hero",
            engine: "BLENDER_EEVEE",
            frame: 1,
            camera: cam0,
            timeline: timeline,
            anchors: [PrismCameraTransform.projectPointToAnchor(name: "Origin", worldPointThree: originThree, camera: cam0)]
        )
        let h1 = try ir.deterministicSHA256()
        let h2 = try ir.deterministicSHA256()
        XCTAssertEqual(h1, h2)
        XCTAssertEqual(h1.count, 64)
        XCTAssertTrue(ir.anchors[0].visible)
    }

    // MARK: - Test 2: HID Anti-Lag Governor

    func testHIDAntiLagGovernorPacingAndThermalDecisions() async throws {
        // 1. Live macOS telemetry provider sanity check
        let liveSnapshot = PrismLiveTelemetryProvider().capture(childPID: nil)
        XCTAssertGreaterThan(liveSnapshot.selfFootprintBytes, 0)
        XCTAssertTrue(liveSnapshot.hidIdleSeconds.isFinite)
        XCTAssertGreaterThanOrEqual(liveSnapshot.hidIdleSeconds, 0.0)

        // 2. Injectable mock tests (<50ms total)
        var currentSnap = PrismTelemetrySnapshot(
            hidIdleSeconds: 0.25,
            hidListenAccessOK: true,
            thermalState: .nominal,
            isLowPowerMode: false,
            selfFootprintBytes: 64 * 1024 * 1024,
            childFootprintBytes: nil
        )
        let mock = PrismClosureTelemetryProvider { _ in currentSnap }
        let config = PrismAntiLagConfig(
            enabled: true,
            pauseWindowSeconds: 1.5,
            activeHIDSleepMs: 12,
            seriousThermalSleepMs: 14,
            criticalThermalSleepMs: 18,
            applyDarwinBackground: false,
            useTaskpolicyForChild: false
        )
        let gov = PrismAntiLagGovernor(config: config, telemetryProvider: mock)

        // Case A: Active user HID (< 1.5s) -> adaptive pause & Darwin BG
        let dActive = try await gov.paceStep(childPID: nil)
        XCTAssertTrue(dActive.shouldYield)
        XCTAssertEqual(dActive.sleepMs, 12)
        XCTAssertTrue(dActive.useDarwinBG)

        // Case B: User idle (>= 1.5s) -> full speed, 0ms sleep
        currentSnap = PrismTelemetrySnapshot(
            hidIdleSeconds: 4.5,
            hidListenAccessOK: true,
            thermalState: .nominal,
            isLowPowerMode: false,
            selfFootprintBytes: 64 * 1024 * 1024,
            childFootprintBytes: nil
        )
        let dIdle = try await gov.paceStep(childPID: nil)
        XCTAssertFalse(dIdle.shouldYield)
        XCTAssertEqual(dIdle.sleepMs, 0)
        XCTAssertFalse(dIdle.useDarwinBG)

        // Case C: Critical thermal state -> cooldown pause even when user idle
        currentSnap = PrismTelemetrySnapshot(
            hidIdleSeconds: 12.0,
            hidListenAccessOK: true,
            thermalState: .critical,
            isLowPowerMode: false,
            selfFootprintBytes: 64 * 1024 * 1024,
            childFootprintBytes: nil
        )
        let dCrit = try await gov.paceStep(childPID: nil)
        XCTAssertTrue(dCrit.shouldYield)
        XCTAssertEqual(dCrit.sleepMs, 18)
        XCTAssertTrue(dCrit.useDarwinBG)

        XCTAssertEqual(gov.stats.stepsEvaluated, 3)
        XCTAssertEqual(gov.stats.hidPauseEvents, 1)
        XCTAssertEqual(gov.stats.thermalCooldownEvents, 1)
        XCTAssertEqual(gov.stats.totalYieldMs, 30)
    }

    // MARK: - Test 3: Windowless WebKit3D Offline GLB Preview & Instant Stills

    @MainActor
    func testWebKit3DOfflineGLBPreviewAndInstantStills() async throws {
        let dir = try makeTempDir("glb-preview")
        let glbURL = dir.appendingPathComponent("cube.glb")
        try Self.writeMinimalCubeGLB(to: glbURL)

        let stillsDir = dir.appendingPathComponent("stills", isDirectory: true)
        let sheetURL = dir.appendingPathComponent("contact_sheet.jpg")

        let report = try await PrismHybridEngine.previewStills(
            inputURL: glbURL,
            outputDir: stillsDir,
            contactSheetURL: sheetURL,
            tier: .webkitGLB,
            width: 540,
            height: 960,
            angles: [0.0, 55.0, 120.0],
            cols: 3,
            rows: 1,
            tileWidth: 270,
            overwrite: true
        )

        XCTAssertEqual(report.tierUsed, "webkitGLB")
        XCTAssertEqual(report.stillsCaptured, 3)
        XCTAssertEqual(report.stillPaths.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sheetURL.path))
        XCTAssertGreaterThan(report.peakFootprintBytes, 0)

        var frameHashes: Set<Data> = []
        for path in report.stillPaths {
            let url = URL(fileURLWithPath: path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
            let cg = try Self.loadCGImage(from: url)
            XCTAssertEqual(cg.width, 540)
            XCTAssertEqual(cg.height, 960)
            let stats = Self.imageRGBStats(cg)
            XCTAssertGreaterThan(stats.meanRGB, 5.0, "GLB still must not be blank/black")
            XCTAssertGreaterThan(stats.stddevRGB, 2.0, "GLB still must have rendered geometry shading")
            frameHashes.insert(Snapshot(cgImage: cg).bgra())
        }
        XCTAssertEqual(frameHashes.count, 3, "Rotating camera angles must produce 3 distinct stills")

        let sheetCG = try Self.loadCGImage(from: sheetURL)
        XCTAssertGreaterThan(sheetCG.width, 800)
        XCTAssertGreaterThan(sheetCG.height, 400)
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .prohibited)
    }

    // MARK: - Test 4: Warm Blender Bridge Sync, Apply Delta & Zero-PNG MMAP

    func testWarmBlenderBridgeSyncApplyDeltaAndZeroPNGMMAP() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/Applications/Blender.app/Contents/MacOS/Blender"),
            "Blender.app not installed on Cloud CI VM"
        )
        let dir = try makeTempDir("warm-blender")
        let blendURL = dir.appendingPathComponent("hero.blend")
        try Self.createTestBlendScene(at: blendURL, width: 540, height: 960)

        let glbURL = dir.appendingPathComponent("hero.glb")
        let irURL = dir.appendingPathComponent("hero_ir.json")

        let bridge = try PrismWarmBlenderBridge()
        var workerPID: Int32 = 0
        do {
            try await bridge.start()
            workerPID = try await bridge.ping()
            XCTAssertGreaterThan(workerPID, 0)

            let loaded = try await bridge.loadBlend(
                url: blendURL,
                engine: .eevee,
                width: 540,
                height: 960,
                samples: 8,
                filmTransparent: false
            )
            XCTAssertEqual(loaded.width, 540)
            XCTAssertEqual(loaded.height, 960)
            XCTAssertEqual(loaded.engine, "BLENDER_EEVEE")

            let ir = try await bridge.exportGLBAndIR(
                glbURL: glbURL,
                irURL: irURL,
                frame: 1,
                exportAnimations: true,
                overwrite: true
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: glbURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: irURL.path))
            XCTAssertEqual(ir.schema, "safarium-prism/scene-v1")
            // Verify Portrait AUTO trap is resolved in exported IR (~54.432 deg for 35mm on 540x960)
            XCTAssertEqual(ir.camera.fovYDeg, 54.432223, accuracy: 0.05)

            let f1 = try await bridge.renderFrameToSHM(frame: 1, method: .bmpMmap)
            XCTAssertEqual(f1.info.width, 540)
            XCTAssertEqual(f1.info.height, 960)
            XCTAssertGreaterThan(f1.info.meanRGB, 5.0)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(f1.pixelBuffer), kCVPixelFormatType_32BGRA)

            let delta = PrismBlenderDelta(
                frame: 10,
                cameraPositionDeltaBlender: PrismVec3(x: 0.6, y: 0.2, z: 0.3),
                lensMM: 52.0
            )
            let f2 = try await bridge.renderFrameToSHM(frame: 10, method: .bmpMmap, delta: delta)
            XCTAssertEqual(f2.info.width, 540)
            XCTAssertEqual(f2.info.height, 960)
            XCTAssertGreaterThan(f2.info.meanRGB, 5.0)
            XCTAssertNotEqual(f1.info.sha256Prefix, f2.info.sha256Prefix)

            await bridge.shutdown()
        } catch {
            await bridge.shutdown()
            throw error
        }

        // Verify zero PNGs in tempDir
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertFalse(files.contains { $0.lowercased().hasSuffix(".png") }, "Zero PNG files should be left in scratch dir")

        // Verify child worker reaped cleanly
        if workerPID > 0 {
            XCTAssertNotEqual(Darwin.kill(workerPID, 0), 0, "Blender worker pid \(workerPID) must have exited after shutdown")
        }
    }

    // MARK: - Test 5: MetalFX Auto-Verify & Forced 1x Fallback

    @MainActor
    func testAutoVerifyMetalFXAndForcedFallback() async throws {
        try XCTSkipUnless(
            PrismMetalFXVerifier.isSupported() && AppleMacOSBackend.current.supportsANE,
            "MetalFX spatial scaler / Vision OCR requires MetalFX GPU and physical Apple Silicon ANE"
        )
        let dir = try makeTempDir("metalfx-autoverify")
        let glbURL = dir.appendingPathComponent("smooth.glb")
        try Self.writeMinimalCubeGLB(to: glbURL)

        let host = try await PrismWebKit3D(width: 1080, height: 1920, transparent: false)
        defer { host.close() }
        try await host.loadBuiltinGLB(glbURL: glbURL)
        _ = try await host.renderGLBAngle(25.0)
        let pbSmooth1x = try await host.snapshotPixelBuffer()

        try await host.resize(width: 724, height: 1286)
        _ = try await host.renderGLBAngle(25.0)
        let pbSmoothLow = try await host.snapshotPixelBuffer()

        let verifier = try PrismMetalFXVerifier()
        let smoothPolicy = PrismQualityPolicy(
            useMetalFX: true,
            scaleFactor: 0.67,
            autoVerifyMetalFX: true,
            minPQScore: 85.0,
            minMSSSIM: 0.97,
            maxDeltaE00P95: 2.0,
            checkThaiOCR: false
        )
        let smoothResult = try verifier.evaluateAndUpscale(
            lowResPB: pbSmoothLow,
            reference1xPB: pbSmooth1x,
            policy: smoothPolicy
        )
        XCTAssertFalse(smoothResult.didFallbackTo1x, "Smooth 3D should pass SafariumPQ MetalFX gate: \(smoothResult.pqReport.notes)")
        XCTAssertTrue(smoothResult.pqReport.passed)
        XCTAssertGreaterThanOrEqual(smoothResult.pqReport.score0To100, 85.0)

        // Forced fallback on 1px high-frequency grid + 24pt Thai text
        let pbGrid1x = try Self.makeHighFreqGridWithThai(width: 1080, height: 1920)
        let pbGridLow = try Self.makeHighFreqGridWithThai(width: 724, height: 1286)
        let strictPolicy = PrismQualityPolicy(
            useMetalFX: true,
            scaleFactor: 0.67,
            autoVerifyMetalFX: true,
            minPQScore: 85.0,
            minMSSSIM: 0.97,
            maxDeltaE00P95: 2.0,
            checkThaiOCR: true,
            expectedThaiText: nil
        )
        let gridResult = try verifier.evaluateAndUpscale(
            lowResPB: pbGridLow,
            reference1xPB: pbGrid1x,
            policy: strictPolicy
        )
        XCTAssertTrue(gridResult.didFallbackTo1x, "1px grid + 24pt Thai must trigger automatic 1x fallback")
        XCTAssertFalse(gridResult.pqReport.passed)
        XCTAssertFalse(gridResult.pqReport.notes.isEmpty)
        XCTAssertEqual(CVPixelBufferGetWidth(gridResult.outputPB), 1080)
        XCTAssertEqual(CVPixelBufferGetHeight(gridResult.outputPB), 1920)
    }

    // MARK: - Test 6: Two-Engine Zero-Copy Hybrid Composite + Dual Tee

    @MainActor
    func testTwoEngineZeroCopyHybridCompositeAndDualTee() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/Applications/Blender.app/Contents/MacOS/Blender")
                && SafariumMetalContext.shared != nil
                && AppleMacOSBackend.current.supportsANE,
            "Hybrid Blender+WebKit test requires Blender.app, Metal GPU, and physical ANE"
        )
        let dir = try makeTempDir("hybrid-composite")
        let blendURL = dir.appendingPathComponent("hero.blend")
        try Self.createTestBlendScene(at: blendURL, width: 540, height: 960)

        let bgHTMLURL = dir.appendingPathComponent("bg_three.html")
        try Self.writeWebGL3DBackgroundHTML(to: bgHTMLURL)

        let hudHTMLURL = dir.appendingPathComponent("hud_thai.html")
        try Self.writeThaiOverlayHTML(to: hudHTMLURL, text: "สวัสดี ซาฟาเรียม")

        let primaryMP4 = dir.appendingPathComponent("composite.mp4")
        let secondaryMOV = dir.appendingPathComponent("composite_prores.mov")

        let report = try await PrismHybridEngine.compositeHybrid(
            blendURL: blendURL,
            backgroundHTMLURL: bgHTMLURL,
            backgroundGLBURL: nil,
            overlayHTMLURL: hudHTMLURL,
            outputURL: primaryMP4,
            secondaryMOVURL: secondaryMOV,
            primaryCodec: .h264,
            secondaryCodec: .proRes4444,
            width: 540,
            height: 960,
            fps: 30,
            startFrame: 1,
            frames: 4,
            blenderEngine: .eevee,
            samples: 8,
            shmMethod: .bmpMmap,
            qualityPolicy: PrismQualityPolicy(useMetalFX: false, autoVerifyMetalFX: false),
            governorConfig: PrismAntiLagConfig(enabled: false),
            overwrite: true
        )

        XCTAssertEqual(report.frames, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: primaryMP4.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondaryMOV.path))
        XCTAssertGreaterThan(report.primaryBytes, 0)
        XCTAssertGreaterThan(report.secondaryBytes ?? 0, 0)

        let mp4Probe = try await PacketProbe.inspect(url: primaryMP4)
        XCTAssertTrue(mp4Probe.playable)
        let mp4Track = try XCTUnwrap(mp4Probe.tracks.first { $0.mediaType == "vide" })
        XCTAssertEqual(mp4Track.packetCount, 4)
        XCTAssertEqual(mp4Track.formats.first?.codec, "avc1")

        let movProbe = try await PacketProbe.inspect(url: secondaryMOV)
        XCTAssertTrue(movProbe.playable)
        let movTrack = try XCTUnwrap(movProbe.tracks.first { $0.mediaType == "vide" })
        XCTAssertEqual(movTrack.packetCount, 4)
        XCTAssertEqual(movTrack.formats.first?.codec, "ap4h")

        // Verify Thai HUD 1x text survived composite cleanly via Vision OCR on decoded frame 0
        let reader = try await SafariumSequentialVideoReader(url: primaryMP4, loop: false, pixelFormat: kCVPixelFormatType_32BGRA)
        defer { reader.close() }
        let pb0 = try XCTUnwrap(try reader.pixelBuffer(at: 0.0))
        let ocrText = try Self.recognizeThaiText(in: pb0)
        XCTAssertTrue(ocrText.contains("สวัสดี") || ocrText.contains("ซาฟาเรียม"), "Expected crisp Thai HUD text in composite output, got: '\(ocrText)'")

        // Ensure no stray PNGs
        let files = (try? FileManager.default.subpathsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertFalse(files.contains { $0.lowercased().hasSuffix(".png") })
    }

    // MARK: - Test 7: End-to-End syncFromBlender, renderWeb3D (Auto-Verify Fallback + Anchors), and renderBlenderAdaptive (gpu_offscreen)

    @MainActor
    func testSyncRenderWeb3DFallbackAndBlenderAdaptiveGPUOffscreen() async throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/Applications/Blender.app/Contents/MacOS/Blender")
                && PrismMetalFXVerifier.isSupported(),
            "Blender+MetalFX E2E test requires Blender.app and MetalFX GPU"
        )
        let dir = try makeTempDir("e2e-render")

        // 1. syncFromBlender standalone entrypoint
        let blendURL = dir.appendingPathComponent("scene.blend")
        try Self.createTestBlendScene(at: blendURL, width: 540, height: 960)
        let glbURL = dir.appendingPathComponent("synced.glb")
        let irURL = dir.appendingPathComponent("synced_ir.json")
        let syncRes = try await PrismHybridEngine.syncFromBlender(
            blendURL: blendURL,
            outputGLBURL: glbURL,
            outputIRURL: irURL,
            frame: 1,
            overwrite: true
        )
        XCTAssertGreaterThan(syncRes.glbBytes, 0)
        XCTAssertEqual(syncRes.irSHA256.count, 64)
        XCTAssertEqual(syncRes.camera.fovYDeg, 54.432223, accuracy: 0.05)

        // 2. renderWeb3D on a 1px high-freq grid + window.READY + window.render(t) + window.__anchors
        let gridHTML = dir.appendingPathComponent("grid.html")
        try Self.writeHighFreqGridHTML(to: gridHTML)

        // Also verify PrismWebKit3D readPageAnchors directly
        let anchorHost = try await PrismWebKit3D(width: 540, height: 960)
        try await anchorHost.loadHTMLFile(gridHTML)
        try await anchorHost.seekHTML(timeSeconds: 0.2)
        let anchors = try await anchorHost.readPageAnchors()
        anchorHost.close()
        XCTAssertEqual(anchors.count, 1)
        XCTAssertEqual(anchors.first?.name, "center")
        XCTAssertTrue(anchors.first?.visible == true)

        let webMP4 = dir.appendingPathComponent("web_grid.mp4")
        let webRep = try await PrismHybridEngine.renderWeb3D(
            htmlURL: gridHTML,
            outputURL: webMP4,
            width: 540,
            height: 960,
            fps: 30,
            frames: 3,
            qualityPolicy: PrismQualityPolicy(
                useMetalFX: true,
                scaleFactor: 0.67,
                autoVerifyMetalFX: true,
                minPQScore: 85.0,
                minMSSSIM: 0.97,
                maxDeltaE00P95: 2.0
            ),
            governorConfig: PrismAntiLagConfig(enabled: false),
            overwrite: true
        )
        XCTAssertTrue(webRep.usedMetalFX)
        XCTAssertTrue(webRep.didFallbackTo1x, "1px grid HTML must trigger automatic 1x fallback in renderWeb3D")
        XCTAssertEqual(webRep.fallbackFrame, 0)
        XCTAssertEqual(webRep.frames, 3)
        let webProbe = try await PacketProbe.inspect(url: webMP4)
        XCTAssertTrue(webProbe.playable)
        XCTAssertEqual(webProbe.tracks.first(where: { $0.mediaType == "vide" })?.packetCount, 3)

        // 3. renderBlenderAdaptive using gpu_offscreen SHM path
        let blenderMP4 = dir.appendingPathComponent("blender_gpu.mp4")
        let blRep = try await PrismHybridEngine.renderBlenderAdaptive(
            blendURL: blendURL,
            outputURL: blenderMP4,
            irURL: irURL,
            engine: .eevee,
            shmMethod: .gpuOffscreen,
            samples: 8,
            width: 540,
            height: 960,
            fps: 30,
            startFrame: 1,
            frames: 3,
            qualityPolicy: PrismQualityPolicy(useMetalFX: false),
            governorConfig: PrismAntiLagConfig(enabled: false),
            overwrite: true
        )
        XCTAssertEqual(blRep.frames, 3)
        XCTAssertGreaterThan(blRep.primaryBytes, 0)
        let blProbe = try await PacketProbe.inspect(url: blenderMP4)
        XCTAssertTrue(blProbe.playable)
        XCTAssertEqual(blProbe.tracks.first(where: { $0.mediaType == "vide" })?.packetCount, 3)
    }

    // MARK: - Test Helpers

    private static func quatError(_ a: PrismQuaternion, _ b: PrismQuaternion) -> Double {
        let d1 = max(abs(a.w - b.w), max(abs(a.x - b.x), max(abs(a.y - b.y), abs(a.z - b.z))))
        let d2 = max(abs(a.w + b.w), max(abs(a.x + b.x), max(abs(a.y + b.y), abs(a.z + b.z))))
        return min(d1, d2)
    }

    private static func loadCGImage(from url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw SafariumError.snapshot("failed to load CGImage at \(url.path)")
        }
        return cg
    }

    private static func imageRGBStats(_ cg: CGImage) -> (meanRGB: Double, stddevRGB: Double) {
        let snap = Snapshot(cgImage: cg)
        let data = snap.bgra()
        var sum = 0.0
        var sumSq = 0.0
        let count = cg.width * cg.height * 3
        data.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: data.count, by: 4) {
                for c in 0..<3 {
                    let v = Double(ptr[i + c])
                    sum += v
                    sumSq += v * v
                }
            }
        }
        let mean = sum / Double(max(1, count))
        let variance = max(0.0, (sumSq / Double(max(1, count))) - mean * mean)
        return (mean, sqrt(variance))
    }

    private static func recognizeThaiText(in pb: CVPixelBuffer) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["th-TH", "en-US"]
        req.usesLanguageCorrection = false
        try VNImageRequestHandler(cvPixelBuffer: pb, options: [:]).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    private static func makeHighFreqGridWithThai(width: Int, height: Int) throws -> CVPixelBuffer {
        let pb = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { throw SafariumError.snapshot("no base") }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        guard let ctx = CGContext(
            data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: stride,
            space: Snapshot.colorSpace, bitmapInfo: Snapshot.bitmapInfo
        ) else { throw SafariumError.snapshot("no CGContext") }
        ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.11, blue: 0.17, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let scale = CGFloat(width) / 1080.0
        ctx.setStrokeColor(CGColor(srgbRed: 0.25, green: 0.78, blue: 0.95, alpha: 0.95))
        ctx.setLineWidth(max(1.0, 1.5 * scale))
        let stepX = Int(max(8.0, (24.0 * scale).rounded()))
        for i in Swift.stride(from: 0, to: width, by: stepX) {
            ctx.move(to: CGPoint(x: i, y: 0))
            ctx.addLine(to: CGPoint(x: width / 2 + (i - width / 2) / 4, y: height / 2))
            ctx.strokePath()
        }
        let stepY = Int(max(6.0, (20.0 * scale).rounded()))
        for j in Swift.stride(from: 0, to: height / 2, by: stepY) {
            ctx.move(to: CGPoint(x: 0, y: j))
            ctx.addLine(to: CGPoint(x: width, y: j))
            ctx.strokePath()
        }

        ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.05, blue: 0.09, alpha: 0.95))
        ctx.fill(CGRect(x: 80 * scale, y: CGFloat(height) - 360 * scale, width: 920 * scale, height: 180 * scale))
        let font = CTFontCreateWithName("Thonburi" as CFString, 26.0 * scale, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        ]
        let s1 = NSAttributedString(string: "ปี่ ปี้ ปิ๊ ปิ๋ · กำ ก่า ก้า ก๊า ก๋า · นนทบุรี 24pt", attributes: attrs)
        ctx.textPosition = CGPoint(x: 110 * scale, y: CGFloat(height) - 255 * scale)
        CTLineDraw(CTLineCreateWithAttributedString(s1), ctx)
        return pb
    }

    private static func writeWebGL3DBackgroundHTML(to url: URL) throws {
        let html = """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><style>html,body{margin:0;padding:0;overflow:hidden;background:#0a1930;}canvas{width:100vw;height:100vh;display:block;}</style></head>
        <body>
        <canvas id="c" width="540" height="960"></canvas>
        <script>
        (() => {
          const c = document.getElementById('c');
          const gl = c.getContext('webgl2', { preserveDrawingBuffer: true });
          const vs = `#version 300 es
          in vec2 p; out vec2 vUV;
          void main(){ vUV = p*0.5+0.5; gl_Position = vec4(p,0,1); }`;
          const fs = `#version 300 es
          precision highp float; in vec2 vUV; uniform float uT; out vec4 o;
          void main(){
            float wave = 0.5 + 0.5 * sin(vUV.x * 6.28 + uT * 4.0);
            o = vec4(0.08 + 0.12*wave, 0.22 + 0.25*vUV.y, 0.45 + 0.30*wave, 1.0);
          }`;
          const sh = (t,s) => { const x=gl.createShader(t); gl.shaderSource(x,s); gl.compileShader(x); return x; };
          const p = gl.createProgram();
          gl.attachShader(p, sh(gl.VERTEX_SHADER, vs));
          gl.attachShader(p, sh(gl.FRAGMENT_SHADER, fs));
          gl.linkProgram(p); gl.useProgram(p);
          const b = gl.createBuffer(); gl.bindBuffer(gl.ARRAY_BUFFER, b);
          gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1, 1,-1, -1,1, 1,1]), gl.STATIC_DRAW);
          gl.enableVertexAttribArray(0); gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
          const uT = gl.getUniformLocation(p, 'uT');
          window.render = (t) => {
            gl.viewport(0, 0, c.width, c.height);
            gl.uniform1f(uT, t || 0);
            gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
            gl.finish();
          };
          window.READY = true;
          window.render(0);
        })();
        </script>
        </body>
        </html>
        """
        try html.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeHighFreqGridHTML(to url: URL) throws {
        let html = """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><style>html,body{margin:0;padding:0;overflow:hidden;background:#0e1522;}canvas{width:100vw;height:100vh;display:block;}</style></head>
        <body>
        <canvas id="c" width="540" height="960"></canvas>
        <script>
        (() => {
          const c = document.getElementById('c');
          const ctx = c.getContext('2d');
          window.setResolution = (w, h) => { c.width = w; c.height = h; };
          window.render = (t) => {
            const w = c.width, h = c.height;
            ctx.fillStyle = '#0f172a';
            ctx.fillRect(0, 0, w, h);
            ctx.strokeStyle = '#38bdf8';
            ctx.lineWidth = 1;
            const step = Math.max(4, Math.round(10 * (w / 540)));
            const shift = ((t || 0) * 10) % step;
            for (let x = shift; x < w; x += step) {
              ctx.beginPath(); ctx.moveTo(x, 0); ctx.lineTo(w / 2 + (x - w / 2) * 0.25, h * 0.65); ctx.stroke();
            }
            for (let y = 0; y < h; y += step) {
              ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke();
            }
            window.__anchors = [{ name: 'center', pixelX: w * 0.5, pixelY: h * 0.5, visible: true }];
          };
          window.READY = true;
          window.render(0);
        })();
        </script>
        </body>
        </html>
        """
        try html.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func writeThaiOverlayHTML(to url: URL, text: String) throws {
        let html = """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><style>
          html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: transparent; overflow: hidden; }
          .pill {
            position: absolute; left: 40px; right: 40px; top: 64px;
            padding: 20px 24px; border-radius: 18px;
            background: rgba(12, 18, 32, 0.88); color: #ffffff;
            font-family: 'Thonburi', sans-serif; font-size: 40px; font-weight: 700;
            text-align: center; letter-spacing: 0.5px;
          }
        </style></head>
        <body><div class="pill">\(text)</div></body>
        </html>
        """
        try html.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func createTestBlendScene(at url: URL, width: Int, height: Int) throws {
        let scriptURL = url.deletingLastPathComponent().appendingPathComponent("mk_scene.py")
        let py = """
        import math, bpy
        from mathutils import Vector
        bpy.ops.wm.read_factory_settings(use_empty=True)
        sc = bpy.context.scene
        sc.render.resolution_x = \(width)
        sc.render.resolution_y = \(height)
        sc.render.resolution_percentage = 100
        sc.render.fps = 30
        sc.frame_start = 1
        sc.frame_end = 20
        sc.render.engine = 'BLENDER_EEVEE'
        sc.view_settings.view_transform = 'Standard'
        world = bpy.data.worlds.new('W')
        world.use_nodes = True
        world.node_tree.nodes['Background'].inputs['Color'].default_value = (0.06, 0.14, 0.30, 1.0)
        sc.world = world
        bpy.ops.mesh.primitive_uv_sphere_add(segments=24, ring_count=12, radius=0.8, location=(0, 0, 0.9))
        sp = bpy.context.active_object
        mat = bpy.data.materials.new('HeroMat')
        mat.use_nodes = True
        mat.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value = (0.95, 0.22, 0.14, 1.0)
        sp.data.materials.append(mat)
        for f in (1, 10, 20):
            sp.location.z = 0.9 + 0.3 * math.sin((f - 1) * 0.4)
            sp.keyframe_insert(data_path='location', frame=f)
        sun_d = bpy.data.lights.new('Sun', type='SUN')
        sun_d.energy = 4.0
        sun = bpy.data.objects.new('Sun', sun_d)
        sun.location = (4, -4, 6)
        sun.rotation_euler = (0.7, 0.2, 0.6)
        sc.collection.objects.link(sun)
        cam_d = bpy.data.cameras.new('Cam')
        cam_d.lens = 35.0
        cam_d.sensor_width = 36.0
        cam_d.sensor_height = 24.0
        cam_d.sensor_fit = 'AUTO'
        cam = bpy.data.objects.new('Cam', cam_d)
        cam.location = Vector((0.0, -4.5, 1.4))
        cam.rotation_mode = 'QUATERNION'
        cam.rotation_quaternion = (Vector((0, 0, 0.9)) - cam.location).to_track_quat('-Z', 'Y')
        sc.collection.objects.link(cam)
        sc.camera = cam
        sc.frame_set(1)
        bpy.context.view_layer.update()
        bpy.ops.wm.save_as_mainfile(filepath=r'''\(url.path)''')
        """
        try py.write(to: scriptURL, atomically: true, encoding: .utf8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/Applications/Blender.app/Contents/MacOS/Blender")
        proc.arguments = ["-b", "--factory-startup", "--python-exit-code", "1", "-P", scriptURL.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        try? FileManager.default.removeItem(at: scriptURL)
        guard proc.terminationStatus == 0 else {
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw SafariumError.encode("Blender test scene creation failed: \(out)")
        }
    }

    private static func writeMinimalCubeGLB(to url: URL) throws {
        // Minimal self-contained GLB 2.0 colored cube (24 vertices with normals + 36 uint16 indices)
        let positions: [Float] = [
            // Front (+Z)
            -0.7, -0.7,  0.7,   0.7, -0.7,  0.7,   0.7,  0.7,  0.7,  -0.7,  0.7,  0.7,
            // Back (-Z)
             0.7, -0.7, -0.7,  -0.7, -0.7, -0.7,  -0.7,  0.7, -0.7,   0.7,  0.7, -0.7,
            // Top (+Y)
            -0.7,  0.7,  0.7,   0.7,  0.7,  0.7,   0.7,  0.7, -0.7,  -0.7,  0.7, -0.7,
            // Bottom (-Y)
            -0.7, -0.7, -0.7,   0.7, -0.7, -0.7,   0.7, -0.7,  0.7,  -0.7, -0.7,  0.7,
            // Right (+X)
             0.7, -0.7,  0.7,   0.7, -0.7, -0.7,   0.7,  0.7, -0.7,   0.7,  0.7,  0.7,
            // Left (-X)
            -0.7, -0.7, -0.7,  -0.7, -0.7,  0.7,  -0.7,  0.7,  0.7,  -0.7,  0.7, -0.7,
        ]
        let normals: [Float] = [
             0,  0,  1,   0,  0,  1,   0,  0,  1,   0,  0,  1,
             0,  0, -1,   0,  0, -1,   0,  0, -1,   0,  0, -1,
             0,  1,  0,   0,  1,  0,   0,  1,  0,   0,  1,  0,
             0, -1,  0,   0, -1,  0,   0, -1,  0,   0, -1,  0,
             1,  0,  0,   1,  0,  0,   1,  0,  0,   1,  0,  0,
            -1,  0,  0,  -1,  0,  0,  -1,  0,  0,  -1,  0,  0,
        ]
        var indices: [UInt16] = []
        for f in 0..<6 {
            let b = UInt16(f * 4)
            indices.append(contentsOf: [b, b + 1, b + 2, b, b + 2, b + 3])
        }

        var bin = Data()
        let posOffset = bin.count
        positions.withUnsafeBytes { bin.append(contentsOf: $0) }
        let posLen = bin.count - posOffset
        let normOffset = bin.count
        normals.withUnsafeBytes { bin.append(contentsOf: $0) }
        let normLen = bin.count - normOffset
        let idxOffset = bin.count
        indices.withUnsafeBytes { bin.append(contentsOf: $0) }
        let idxLen = bin.count - idxOffset
        while bin.count % 4 != 0 { bin.append(0) }

        let gltf: [String: Any] = [
            "asset": ["version": "2.0", "generator": "SafariumPrismTest"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0, "translation": [0.0, 0.85, 0.0]]],
            "materials": [[
                "pbrMetallicRoughness": [
                    "baseColorFactor": [0.92, 0.25, 0.18, 1.0],
                    "metallicFactor": 0.2,
                    "roughnessFactor": 0.3,
                ]
            ]],
            "meshes": [[
                "primitives": [[
                    "attributes": ["POSITION": 0, "NORMAL": 1],
                    "indices": 2,
                    "material": 0,
                ]]
            ]],
            "buffers": [["byteLength": bin.count]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": posOffset, "byteLength": posLen, "target": 34962],
                ["buffer": 0, "byteOffset": normOffset, "byteLength": normLen, "target": 34962],
                ["buffer": 0, "byteOffset": idxOffset, "byteLength": idxLen, "target": 34963],
            ],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 24, "type": "VEC3", "min": [-0.7, -0.7, -0.7], "max": [0.7, 0.7, 0.7]],
                ["bufferView": 1, "componentType": 5126, "count": 24, "type": "VEC3"],
                ["bufferView": 2, "componentType": 5123, "count": 36, "type": "SCALAR"],
            ],
        ]
        var jsonData = try JSONSerialization.data(withJSONObject: gltf, options: [])
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }

        let totalLen = UInt32(12 + 8 + jsonData.count + 8 + bin.count)
        var glb = Data()
        func appendLE(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { glb.append(contentsOf: $0) }
        }
        appendLE(0x46546C67) // glTF
        appendLE(2)
        appendLE(totalLen)
        appendLE(UInt32(jsonData.count))
        appendLE(0x4E4F534A) // JSON
        glb.append(jsonData)
        appendLE(UInt32(bin.count))
        appendLE(0x004E4942) // BIN
        glb.append(bin)
        try glb.write(to: url)
    }
}
