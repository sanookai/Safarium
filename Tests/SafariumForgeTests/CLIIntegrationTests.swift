import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SafariumContainers
import SafariumCore
@testable import SafariumForgeCore
import XCTest

final class CLIIntegrationTests: XCTestCase {
    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safarium-cli-test-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func forgeExecutableURL() throws -> URL {
        let productsDir = Bundle(for: CLIIntegrationTests.self).bundleURL.deletingLastPathComponent()
        let sibling = productsDir.appendingPathComponent("safarium-forge")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        // Fallback if invoked via filtered `swift test` on a clean scratch path before `swift build`
        let isRelease = productsDir.lastPathComponent.lowercased() == "release"
        let scratchDir = productsDir.deletingLastPathComponent().deletingLastPathComponent()
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        build.currentDirectoryURL = packageRoot
        var buildArgs = ["swift", "build", "--product", "safarium-forge", "--scratch-path", scratchDir.path]
        if isRelease {
            buildArgs += ["-c", "release"]
        }
        build.arguments = buildArgs
        let errPipe = Pipe()
        build.standardError = errPipe
        try build.run()
        build.waitUntilExit()
        if build.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        let errTxt = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw SafariumError.invalidState("could not locate or build safarium-forge binary at \(sibling.path): \(errTxt)")
    }

    @discardableResult
    private func runCLI(
        _ args: [String],
        stdinData: Data? = nil,
        expectZero: Bool = true
    ) throws -> (status: Int32, stdout: Data, stderr: String) {
        let exe = try forgeExecutableURL()
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        var inPipe: Pipe?
        if stdinData != nil {
            let pipe = Pipe()
            p.standardInput = pipe
            inPipe = pipe
        } else {
            p.standardInput = FileHandle.nullDevice
        }

        try p.run()
        if let stdinData, let writeHandle = inPipe?.fileHandleForWriting {
            writeHandle.write(stdinData)
            try writeHandle.close()
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        let errStr = String(decoding: errData, as: UTF8.self)
        if expectZero {
            XCTAssertEqual(p.terminationStatus, 0, "safarium-forge \(args.joined(separator: " ")) failed (\(p.terminationStatus)): \(errStr)")
        }
        return (p.terminationStatus, outData, errStr)
    }

    private func writeSampleVideo(
        url: URL,
        width: Int = 160,
        height: Int = 120,
        fps: Int = 15,
        frames: Int = 12,
        withAudio: Bool = true
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let sink = try AVAssetWriterSink(
            url: url, width: width, height: height, fps: fps,
            codec: .h264, bitrate: 1_000_000, pixelFormat: .nv12Left, profile: .lowRamClosedGOP
        )
        for i in 0..<frames {
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: Snapshot.colorSpace, bitmapInfo: Snapshot.bitmapInfo
            )!
            ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.25 + 0.04 * CGFloat(i % 10), blue: 0.6, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.45, blue: 0.15, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 20 + i * 4, y: 20, width: 40, height: 40))
            try await sink.append(Snapshot(cgImage: ctx.makeImage()!))
        }
        try await sink.finish()

        if withAudio {
            let wavURL = url.deletingLastPathComponent().appendingPathComponent("tmp_tone_\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: wavURL) }
            _ = try await ForgeProceduralSynth.renderToFile(
                spec: ForgeAudioSynthSpec(waveform: "sine", frequencyHz: 440, amplitude: 0.25, durationSeconds: Double(frames) / Double(fps)),
                outputURL: wavURL,
                overwrite: true
            )
            let muxed = url.deletingLastPathComponent().appendingPathComponent("tmp_mux_\(UUID().uuidString).mp4")
            _ = try await LosslessSoundtrackMux.mux(videoURL: url, wavURL: wavURL, outputURL: muxed, overwrite: true)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: muxed, to: url)
        }
    }

    func testHelpVersionAndCapabilities() throws {
        let help = try runCLI(["--help"])
        let helpStr = String(decoding: help.stdout, as: UTF8.self)
        XCTAssertTrue(helpStr.contains("pipe-encode"))
        XCTAssertTrue(helpStr.contains("capabilities"))

        let ver = try runCLI(["version"])
        let verStr = String(decoding: ver.stdout, as: UTF8.self)
        XCTAssertTrue(verStr.contains("safarium-forge"))

        let bad = try runCLI(["no-such-command"], expectZero: false)
        XCTAssertNotEqual(bad.status, 0)

        MediaCompatBridge.registerSupplementalDecoders()
        let caps = try runCLI(["capabilities"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: caps.stdout) as? [String: Any])
        let backend = AppleMacOSBackend.current
        XCTAssertEqual(json["aneVisionAvailable"] as? Bool, backend.supportsANE)
        let metal = try XCTUnwrap(json["metal"] as? [String: Any])
        XCTAssertEqual(metal["available"] as? Bool, SafariumMetalContext.shared != nil)
        let vt = try XCTUnwrap(json["videoToolbox"] as? [[String: Any]])
        let vp09 = try XCTUnwrap(vt.first { ($0["fourCC"] as? String) == "vp09" })
        let avc1 = try XCTUnwrap(vt.first { ($0["fourCC"] as? String) == "avc1" })
        XCTAssertEqual(vp09["hardwareDecode"] as? Bool, MediaCompatBridge.supportsHardwareDecode(fourCC: "vp09"))
        XCTAssertEqual(avc1["hardwareEncode"] as? Bool, MediaCompatBridge.supportsHardwareEncode(fourCC: "avc1"))
        if backend.isAppleSilicon && !backend.isRunningInVM {
            XCTAssertEqual(vp09["hardwareDecode"] as? Bool, true)
            XCTAssertEqual(avc1["hardwareEncode"] as? Bool, true)
        }
        let walls = try XCTUnwrap(json["osWalls"] as? [String])
        XCTAssertFalse(walls.isEmpty)
    }

    func testValidateAndRunRecipeWithHeadlessWebKitThaiOverlay() async throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let dir = try makeTempDir("cli-recipe")
        defer { try? FileManager.default.removeItem(at: dir) }

        let bgURL = dir.appendingPathComponent("bg.mp4")
        try await writeSampleVideo(url: bgURL, width: 320, height: 240, fps: 15, frames: 8, withAudio: false)

        let htmlURL = dir.appendingPathComponent("thai_hud.html")
        try """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;width:320px;height:240px;background:transparent;overflow:hidden;font-family:-apple-system,"Thonburi",sans-serif;}
        .lbl{position:absolute;left:20px;bottom:20px;padding:8px 14px;background:rgba(15,23,42,0.9);color:#fff;font-size:24px;font-weight:700;}
        </style></head><body><div class="lbl">ทดสอบ</div></body></html>
        """.write(to: htmlURL, atomically: true, encoding: .utf8)

        let srtURL = dir.appendingPathComponent("sub.srt")
        try "1\n00:00:00,000 --> 00:00:00,500\nซับไทย CLI\n".write(to: srtURL, atomically: true, encoding: .utf8)

        let outURL = dir.appendingPathComponent("final.mp4")
        let recipe = ForgeRecipe(
            inputs: [
                ForgeInputSpec(id: "bg", kind: .video, path: bgURL.path),
                ForgeInputSpec(id: "hud", kind: .htmlOverlay, path: htmlURL.path, width: 320, height: 240, modeCDirtyHold: true),
                ForgeInputSpec(id: "tone", kind: .synthAudio, synth: ForgeAudioSynthSpec(waveform: "sine", frequencyHz: 520, amplitude: 0.25, durationSeconds: 0.7)),
                ForgeInputSpec(id: "sub", kind: .subtitles, path: srtURL.path, lang: "tha"),
            ],
            timeline: ForgeTimelineSpec(fps: 15, width: 320, height: 240, frameCount: 8),
            videoOps: [
                ForgeVideoOp(id: "graded", op: .colorGrade, input: "bg", contrast: 1.03),
                ForgeVideoOp(id: "comp", op: .overlay, base: "graded", over: "hud", x: "0", y: "0", opacity: "1.0"),
            ],
            audioOps: [
                ForgeAudioOp(id: "norm", op: .loudnorm, input: "tone", targetLUFS: -16.0, peakCeilingDBTP: -1.05),
            ],
            qaOps: ForgeQASpec(thaiOCRLangs: ["th-TH"], faultChecks: ["black"], failOnQA: true),
            output: ForgeOutputSpec(
                path: outURL.path,
                videoCodec: "h264",
                pixelFormat: "420v",
                subtitles: ForgeSubtitleOutputSpec(input: "sub", format: "tx3g", lang: "tha"),
                overwrite: false
            )
        )
        let recipeURL = dir.appendingPathComponent("recipe.json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(recipe).write(to: recipeURL)

        let val = try runCLI(["run", "--recipe", recipeURL.path, "--validate-only"])
        let valObj = try XCTUnwrap(JSONSerialization.jsonObject(with: val.stdout) as? [String: Any])
        XCTAssertEqual(valObj["valid"] as? Bool, true)
        XCTAssertEqual(valObj["htmlInputIDs"] as? [String], ["hud"])

        // Invalid 1x Thai Shield recipe must fail validation non-zero
        var badRecipe = recipe
        badRecipe.videoOps.append(ForgeVideoOp(id: "badScale", op: .autoReframe, input: "comp", aspect: "9:16"))
        let badURL = dir.appendingPathComponent("bad.json")
        try enc.encode(badRecipe).write(to: badURL)
        let badVal = try runCLI(["validate", "--recipe", badURL.path], expectZero: false)
        XCTAssertNotEqual(badVal.status, 0)

        let execRes = try runCLI(["run", "--recipe", recipeURL.path])
        let rep = try JSONDecoder().decode(ForgeExecutionReport.self, from: execRes.stdout)
        XCTAssertEqual(rep.framesRendered, 8)
        XCTAssertEqual(rep.htmlFramesCaptured, 1)
        XCTAssertEqual(rep.htmlFramesReusedDirtyHold, 7)

        let pq = try await SafariumPQ.compareVideos(
            referenceURL: outURL, candidateURL: outURL, maxSamples: 2, checkThaiOCR: true, expectedThaiText: "ทดสอบ"
        )
        XCTAssertTrue(pq.passed)
        XCTAssertTrue(pq.thaiOCROK)
    }

    func testRemuxInspectImageSheetComparePQAndQA() async throws {
        let dir = try makeTempDir("cli-media")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcMP4 = dir.appendingPathComponent("src.mp4")
        try await writeSampleVideo(url: srcMP4, width: 160, height: 120, fps: 20, frames: 12, withAudio: true)

        // Remux MP4 -> MKV -> inspect -> back to MP4 -> TS -> inspect
        let mkvURL = dir.appendingPathComponent("out.mkv")
        let mkvRes = try runCLI(["remux", srcMP4.path, "-o", mkvURL.path, "--to", "mkv"])
        let mkvRep = try JSONDecoder().decode(RemuxReport.self, from: mkvRes.stdout)
        XCTAssertEqual(mkvRep.videoPackets, 12)

        let inspMKV = try runCLI(["inspect", mkvURL.path])
        let inspObj = try XCTUnwrap(JSONSerialization.jsonObject(with: inspMKV.stdout) as? [String: Any])
        XCTAssertEqual(inspObj["kind"] as? String, "matroska")

        let backMP4 = dir.appendingPathComponent("back.mp4")
        _ = try runCLI(["remux", mkvURL.path, "-o", backMP4.path])

        let tsURL = dir.appendingPathComponent("out.ts")
        _ = try runCLI(["remux", srcMP4.path, "-o", tsURL.path])
        let inspTS = try runCLI(["inspect", tsURL.path])
        let tsObj = try XCTUnwrap(JSONSerialization.jsonObject(with: inspTS.stdout) as? [String: Any])
        XCTAssertEqual(tsObj["kind"] as? String, "ts")

        // Image: video -> animated VP8L WebP; PNG -> AVIF q=0.80 pass & q=1.0 fail
        let webpURL = dir.appendingPathComponent("anim.webp")
        let webpRes = try runCLI(["image", srcMP4.path, "-o", webpURL.path, "--fps", "10", "--frames", "3"])
        let webpRep = try JSONDecoder().decode(WebPEncodeReport.self, from: webpRes.stdout)
        XCTAssertEqual(webpRep.frameCount, 3)
        XCTAssertTrue(webpRep.animated)

        let pngURL = dir.appendingPathComponent("still.png")
        _ = try runCLI(["image", srcMP4.path, "-o", pngURL.path, "--frames", "1"])
        let avifOK = dir.appendingPathComponent("ok.avif")
        let avifRes = try runCLI(["image", pngURL.path, "-o", avifOK.path, "--quality", "0.80"])
        let avifRep = try JSONDecoder().decode(StillImageWriteReport.self, from: avifRes.stdout)
        XCTAssertEqual(avifRep.format, .avif)

        let avifBad = dir.appendingPathComponent("bad.avif")
        let failAVIF = try runCLI(["image", pngURL.path, "-o", avifBad.path, "--quality", "1.0"], expectZero: false)
        XCTAssertNotEqual(failAVIF.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: avifBad.path))

        // Sheet, compare, pq, qa
        let sheetURL = dir.appendingPathComponent("sheet.jpg")
        let manURL = dir.appendingPathComponent("sheet.json")
        let sheetRes = try runCLI([
            "sheet", srcMP4.path, "-o", sheetURL.path, "--cols", "3", "--rows", "2",
            "--tile-width", "80", "--every-frames", "2", "--manifest", manURL.path,
        ])
        let sheetRep = try JSONDecoder().decode(ForgeContactSheetReport.self, from: sheetRes.stdout)
        XCTAssertEqual(sheetRep.tileCount, 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manURL.path))

        let stripURL = dir.appendingPathComponent("strip.png")
        let stripRes = try runCLI(["compare", srcMP4.path, backMP4.path, "-o", stripURL.path, "--samples", "3", "--vertical"])
        let stripRep = try JSONDecoder().decode(ForgeContactSheetReport.self, from: stripRes.stdout)
        XCTAssertEqual(stripRep.tileCount, 6)

        if SafariumMetalContext.shared != nil {
            let pqRes = try runCLI(["pq", srcMP4.path, backMP4.path, "--samples", "3", "--strict"])
            let pqRep = try JSONDecoder().decode(SafariumPQReport.self, from: pqRes.stdout)
            XCTAssertTrue(pqRep.passed)

            let qaRes = try runCLI(["qa", srcMP4.path, "--ref", backMP4.path, "--strict"])
            let qaRep = try JSONDecoder().decode(ForgeQAReport.self, from: qaRes.stdout)
            XCTAssertTrue(qaRep.passed)
        }
    }

    func testAudioReframeMatteAndPipeEncode() async throws {
        let dir = try makeTempDir("cli-dsp-pipe")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Audio synth + process + waveform + silence-trim + crossfade
        let wavURL = dir.appendingPathComponent("synth.wav")
        _ = try runCLI(["audio", "synth", "-o", wavURL.path, "--waveform", "sine", "--freq", "440", "--duration", "0.6"])

        let procURL = dir.appendingPathComponent("proc.m4a")
        let procRes = try runCLI([
            "audio", "process", wavURL.path, "-o", procURL.path,
            "--eq", "highpass:80", "--lufs", "-16", "--peak-dbtp", "-1.05",
        ])
        let procRep = try JSONDecoder().decode(ForgeAudioProcessReport.self, from: procRes.stdout)
        XCTAssertNotNil(procRep.integratedLUFS)

        let wfRes = try runCLI(["audio", "waveform", wavURL.path, "--bins", "60"])
        let wfRep = try JSONDecoder().decode(ForgeWaveformReport.self, from: wfRes.stdout)
        XCTAssertEqual(wfRep.binCount, 60)

        let xfURL = dir.appendingPathComponent("xf.wav")
        _ = try runCLI(["audio", "crossfade", wavURL.path, wavURL.path, "-o", xfURL.path, "--duration", "0.2"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: xfURL.path))

        if SafariumMetalContext.shared != nil {
            // Reframe + Matte
            let vid16x9 = dir.appendingPathComponent("src16x9.mp4")
            try await writeSampleVideo(url: vid16x9, width: 320, height: 180, fps: 15, frames: 8, withAudio: false)

            let reframedURL = dir.appendingPathComponent("reframed.mp4")
            let refRes = try runCLI([
                "reframe", vid16x9.path, "-o", reframedURL.path, "--aspect", "9:16",
                "--detector", "saliencyOnly", "--height", "320",
            ])
            let refRep = try JSONDecoder().decode(ForgeAutoReframeReport.self, from: refRes.stdout)
            XCTAssertEqual(refRep.outputWidth, 180)
            XCTAssertEqual(refRep.outputHeight, 320)

            let matteURL = dir.appendingPathComponent("matte.mp4")
            let matteRes = try runCLI([
                "matte", vid16x9.path, "-o", matteURL.path, "--mode", "personFast",
                "--codec", "h264", "--mask-only", "--max-frames", "4",
            ])
            let matteRep = try JSONDecoder().decode(ForgePersonMatteReport.self, from: matteRes.stdout)
            XCTAssertEqual(matteRep.frames, 4)
        }

        // Dual tee pipe-encode via raw stdin bytes
        let w = 64, h = 64, frameCount = 4
        var rawStream = Data(capacity: w * h * 4 * frameCount)
        for f in 0..<frameCount {
            for _ in 0..<h {
                for x in 0..<w {
                    rawStream.append(UInt8((200 + f * 10) & 0xFF)) // R
                    rawStream.append(UInt8(70))                       // G
                    rawStream.append(UInt8(40))                       // B
                    rawStream.append(x < w / 2 ? 255 : 0)             // A
                }
            }
        }
        let priMOV = dir.appendingPathComponent("tee_alpha.mov")
        let secMP4 = dir.appendingPathComponent("tee_comp.mp4")
        let pipeRes = try runCLI([
            "pipe-encode", "--width", "\(w)", "--height", "\(h)", "--fps", "15",
            "--pix-fmt", "rgba", "--codec", "prores4444", "-o", priMOV.path,
            "--secondary", secMP4.path, "--secondary-codec", "h264", "--secondary-bg", "#0F172A",
        ], stdinData: rawStream)
        let pipeRep = try JSONDecoder().decode(ForgePipeEncodeReport.self, from: pipeRes.stdout)
        XCTAssertEqual(pipeRep.frames, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: priMOV.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secMP4.path))
    }

    func testPrismHelpCapabilitiesAndGLBPreviewStills() throws {
        let dir = try makeTempDir("prism")
        defer { try? FileManager.default.removeItem(at: dir) }

        let prismHelp = try runCLI(["prism", "--help"])
        let helpStr = String(data: prismHelp.stdout, encoding: .utf8) ?? ""
        XCTAssertTrue(helpStr.contains("sync-ir"))
        XCTAssertTrue(helpStr.contains("preview-stills"))
        XCTAssertTrue(helpStr.contains("render-web"))
        XCTAssertTrue(helpStr.contains("render-blender"))
        XCTAssertTrue(helpStr.contains("composite"))

        let capRes = try runCLI(["prism", "capabilities"])
        let capJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: capRes.stdout) as? [String: Any]
        )
        XCTAssertEqual(capJSON["schema"] as? String, "safarium-prism/scene-v1")
        XCTAssertFalse((capJSON["version"] as? String ?? "").isEmpty)

        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        XCTAssertEqual(capJSON["webkitWebGL2Available"] as? Bool, true)

        let glbURL = dir.appendingPathComponent("hero_cube.glb")
        try Self.writeMinimalCubeGLB(to: glbURL)
        let stillDir = dir.appendingPathComponent("stills", isDirectory: true)
        let sheetURL = dir.appendingPathComponent("prism_sheet.png")
        let previewRes = try runCLI([
            "prism", "preview-stills", glbURL.path,
            "--still-dir", stillDir.path,
            "-o", sheetURL.path,
            "--tier", "webkitGLB",
            "--width", "320", "--height", "480",
            "--angles", "0,45",
            "--cols", "2", "--rows", "1", "--tile-width", "160",
            "--overwrite",
        ])
        let previewJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: previewRes.stdout) as? [String: Any]
        )
        XCTAssertEqual(previewJSON["stillsCaptured"] as? Int, 2)
        let stillPaths = previewJSON["stillPaths"] as? [String] ?? []
        XCTAssertEqual(stillPaths.count, 2)
        let tierUsed = previewJSON["tierUsed"] as? String ?? ""
        XCTAssertTrue(tierUsed.lowercased().contains("webkit"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sheetURL.path))
        for stillPath in stillPaths {
            XCTAssertTrue(FileManager.default.fileExists(atPath: stillPath))
        }
    }

    private static func writeMinimalCubeGLB(to url: URL) throws {
        let positions: [Float] = [
            -0.7, -0.7,  0.7,   0.7, -0.7,  0.7,   0.7,  0.7,  0.7,  -0.7,  0.7,  0.7,
             0.7, -0.7, -0.7,  -0.7, -0.7, -0.7,  -0.7,  0.7, -0.7,   0.7,  0.7, -0.7,
            -0.7,  0.7,  0.7,   0.7,  0.7,  0.7,   0.7,  0.7, -0.7,  -0.7,  0.7, -0.7,
            -0.7, -0.7, -0.7,   0.7, -0.7, -0.7,   0.7, -0.7,  0.7,  -0.7, -0.7,  0.7,
             0.7, -0.7,  0.7,   0.7, -0.7, -0.7,   0.7,  0.7, -0.7,   0.7,  0.7,  0.7,
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
            "asset": ["version": "2.0", "generator": "SafariumPrismCLITest"],
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
        appendLE(0x46546C67)
        appendLE(2)
        appendLE(totalLen)
        appendLE(UInt32(jsonData.count))
        appendLE(0x4E4F534A)
        glb.append(jsonData)
        appendLE(UInt32(bin.count))
        appendLE(0x004E4942)
        glb.append(bin)
        try glb.write(to: url)
    }

    private func htmlExecutableURL() throws -> URL {
        let productsDir = Bundle(for: CLIIntegrationTests.self).bundleURL.deletingLastPathComponent()
        let sibling = productsDir.appendingPathComponent("safarium-html")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        let isRelease = productsDir.lastPathComponent.lowercased() == "release"
        let scratchDir = productsDir.deletingLastPathComponent().deletingLastPathComponent()
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        build.currentDirectoryURL = packageRoot
        var buildArgs = ["swift", "build", "--product", "safarium-html", "--scratch-path", scratchDir.path]
        if isRelease {
            buildArgs += ["-c", "release"]
        }
        build.arguments = buildArgs
        let errPipe = Pipe()
        build.standardError = errPipe
        try build.run()
        build.waitUntilExit()
        if build.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        let errTxt = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw SafariumError.invalidState("could not locate or build safarium-html binary at \(sibling.path): \(errTxt)")
    }

    private func writePNG(url: URL, width: Int, height: Int, r: CGFloat, g: CGFloat, b: CGFloat) throws {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: Snapshot.colorSpace, bitmapInfo: Snapshot.bitmapInfo
        )!
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = try XCTUnwrap(ctx.makeImage())
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "failed writing PNG \(url.path)")
    }

    func testCLIWave6SchemaDryRunProgressAndJSONErrors() throws {
        let dir = try makeTempDir("cli-w6-control")
        defer { try? FileManager.default.removeItem(at: dir) }

        let schemaRes = try runCLI(["schema"])
        let schemaJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: schemaRes.stdout) as? [String: Any])
        XCTAssertEqual(schemaJSON["schemaVersion"] as? String, "safarium-forge/schema-v1")
        let inputKinds = try XCTUnwrap(schemaJSON["inputKinds"] as? [String])
        XCTAssertTrue(inputKinds.contains("imageSequence"))
        let videoOps = try XCTUnwrap(schemaJSON["videoOps"] as? [String])
        for expectedOp in ["tmix", "kGrief", "setpts", "tpad", "llsr"] {
            XCTAssertTrue(videoOps.contains(expectedOp), "schema videoOps missing \(expectedOp)")
        }

        let errRes = try runCLI(["run", "--recipe", dir.appendingPathComponent("missing.json").path, "--json-errors"], expectZero: false)
        XCTAssertNotEqual(errRes.status, 0)
        let firstErrLine = errRes.stderr.split(separator: "\n").first.map(String.init) ?? ""
        let errObj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(firstErrLine.utf8)) as? [String: Any])
        XCTAssertEqual(errObj["ok"] as? Bool, false)
        XCTAssertEqual(errObj["tool"] as? String, "safarium-forge")
        let errDetail = try XCTUnwrap(errObj["error"] as? [String: Any])
        XCTAssertFalse((errDetail["code"] as? String ?? "").isEmpty)
        XCTAssertFalse((errDetail["hint"] as? String ?? "").isEmpty)

        let synthRecipe = ForgeRecipe(
            inputs: [ForgeInputSpec(id: "bg", kind: .image, path: dir.appendingPathComponent("still.png").path)],
            timeline: ForgeTimelineSpec(fps: 24, width: 160, height: 120, durationSeconds: 0.5),
            output: ForgeOutputSpec(path: dir.appendingPathComponent("dry.mp4").path, videoCodec: "h264", overwrite: true)
        )
        let recipeURL = dir.appendingPathComponent("dry_recipe.json")
        try JSONEncoder().encode(synthRecipe).write(to: recipeURL)
        let dryRes = try runCLI(["run", "--recipe", recipeURL.path, "--dry-run"])
        let dryObj = try XCTUnwrap(JSONSerialization.jsonObject(with: dryRes.stdout) as? [String: Any])
        XCTAssertEqual(dryObj["valid"] as? Bool, true)
        XCTAssertEqual(dryObj["dryRun"] as? Bool, true)
        XCTAssertEqual(dryObj["executes"] as? Bool, false)

        let wavOut = dir.appendingPathComponent("white.wav")
        let progRes = try runCLI([
            "audio", "synth", "-o", wavOut.path,
            "--waveform", "whiteNoise",
            "--duration", "0.15",
            "--progress", "jsonl",
            "--overwrite",
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: wavOut.path))
        let lines = progRes.stderr.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data(String($0).utf8)) as? [String: Any]
        }
        XCTAssertTrue(lines.contains { ($0["event"] as? String) == "start" })
        XCTAssertTrue(lines.contains { ($0["event"] as? String) == "complete" && ($0["footprintMB"] as? Double ?? 0) > 0 })
    }

    func testCLIWave6SeqEncodeWithInlineSheet() throws {
        let dir = try makeTempDir("cli-w6-seq")
        defer { try? FileManager.default.removeItem(at: dir) }

        let framesDir = dir.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
        for i in 1...6 {
            let fURL = framesDir.appendingPathComponent(String(format: "frame_%03d.png", i))
            try writePNG(url: fURL, width: 160, height: 120, r: CGFloat(i) / 7.0, g: 0.4, b: 0.8)
        }
        let outMP4 = dir.appendingPathComponent("seq_out.mp4")
        let sheetPNG = dir.appendingPathComponent("sheet_3x2.png")

        let res = try runCLI([
            "seq-encode",
            "--dir", framesDir.path,
            "--glob", "frame_*.png",
            "--fps", "12",
            "-o", outMP4.path,
            "--inline-sheet", sheetPNG.path,
            "--sheet-cols", "3",
            "--sheet-rows", "2",
            "--overwrite",
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outMP4.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sheetPNG.path))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: res.stdout) as? [String: Any])
        XCTAssertEqual(obj["framesRendered"] as? Int ?? obj["frames"] as? Int, 6)
    }

    func testCLIWave6BatchDOMAndTranscodeMaxBytes() async throws {
        let dir = try makeTempDir("cli-w6-batch-transcode")
        defer { try? FileManager.default.removeItem(at: dir) }

        var items: [[String: Any]] = []
        for idx in 1...3 {
            let outPNG = dir.appendingPathComponent("thai_card_\(idx).png")
            items.append([
                "id": "card-\(idx)",
                "htmlContent": "<html><body style='margin:0;background:transparent'><div id='card' style='display:inline-block;padding:12px 20px;background:rgba(15,23,42,0.9);color:#f8fafc;font-family:-apple-system,sans-serif;font-size:22px;border-radius:10px;'>บทที่ \(idx) ทดสอบภาษาไทย</div></body></html>",
                "selector": "#card",
                "padding": 4,
                "transparent": true,
                "outputPath": outPNG.path,
            ])
        }
        let manifestURL = dir.appendingPathComponent("manifest.json")
        try JSONSerialization.data(withJSONObject: ["items": items]).write(to: manifestURL)

        let batchRes = try runCLI(["batch-dom", "--manifest", manifestURL.path, "--overwrite"])
        let batchObj = try XCTUnwrap(JSONSerialization.jsonObject(with: batchRes.stdout) as? [String: Any])
        XCTAssertEqual(batchObj["totalItems"] as? Int, 3)
        XCTAssertEqual(batchObj["succeeded"] as? Int, 3)
        for idx in 1...3 {
            let pngURL = dir.appendingPathComponent("thai_card_\(idx).png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: pngURL.path))
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(pngURL as CFURL, nil))
            let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
            XCTAssertTrue(cg.alphaInfo == .premultipliedFirst || cg.alphaInfo == .premultipliedLast || cg.alphaInfo == .first || cg.alphaInfo == .last)
        }

        let srcMP4 = dir.appendingPathComponent("source.mp4")
        try await writeSampleVideo(url: srcMP4, width: 320, height: 240, fps: 12, frames: 24, withAudio: true)
        let smallMP4 = dir.appendingPathComponent("small.mp4")
        let transRes = try runCLI([
            "transcode", srcMP4.path,
            "-o", smallMP4.path,
            "--max-bytes", "180000",
            "--fps", "12",
            "--overwrite",
        ])
        let transObj = try XCTUnwrap(JSONSerialization.jsonObject(with: transRes.stdout) as? [String: Any])
        let outBytes = ((try? FileManager.default.attributesOfItem(atPath: smallMP4.path)[.size]) as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(outBytes, 1000)
        XCTAssertLessThanOrEqual(outBytes, 180_000)
        XCTAssertEqual(transObj["targetMaxBytes"] as? Int64, 180_000)
    }

    func testCLIWave6InspectOggAndSafariumHTMLHash() throws {
        let dir = try makeTempDir("cli-w6-inspect-hash")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Minimal valid Ogg FLAC header for `inspect` CLI probe
        let flacURL = dir.appendingPathComponent("sample.flac")
        let pcmFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: pcmFmt, frameCapacity: 4410)!
        buf.frameLength = 4410
        for ch in 0..<2 {
            for i in 0..<4410 { buf.floatChannelData![ch][i] = 0.2 * sinf(2.0 * .pi * 330.0 * Float(i) / 44_100.0) }
        }
        do {
            let wf = try AVAudioFile(forWriting: flacURL, settings: [AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16], commonFormat: .pcmFormatFloat32, interleaved: false)
            try wf.write(from: buf)
        }
        let flacBytes = [UInt8](try Data(contentsOf: flacURL))
        var cursor = 4
        var isLast = (flacBytes[cursor] & 0x80) != 0
        let siLen = (Int(flacBytes[cursor + 1]) << 16) | (Int(flacBytes[cursor + 2]) << 8) | Int(flacBytes[cursor + 3])
        var si = Array(flacBytes[cursor..<(cursor + 4 + siLen)])
        si[0] &= 0x7F
        cursor += 4 + siLen
        var metas: [Data] = []
        while !isLast && cursor + 4 <= flacBytes.count {
            isLast = (flacBytes[cursor] & 0x80) != 0
            let len = (Int(flacBytes[cursor + 1]) << 16) | (Int(flacBytes[cursor + 2]) << 8) | Int(flacBytes[cursor + 3])
            var b = Array(flacBytes[cursor..<(cursor + 4 + len)])
            b[0] &= 0x7F
            metas.append(Data(b))
            cursor += 4 + len
        }
        var firstPkt: [UInt8] = [0x7F]
        firstPkt.append(contentsOf: "FLAC".utf8)
        firstPkt.append(contentsOf: [1, 0, UInt8(metas.count >> 8), UInt8(metas.count & 0xFF)])
        firstPkt.append(contentsOf: "fLaC".utf8)
        firstPkt.append(contentsOf: si)
        var oggW = OggPageWriter(serialNumber: 0x1234)
        try oggW.append(packet: Data(firstPkt), granulePosition: 0, flush: true)
        for (idx, m) in metas.enumerated() {
            try oggW.append(packet: m, granulePosition: 0, flush: idx == metas.count - 1)
        }
        try oggW.append(packet: Data(flacBytes[cursor...]), granulePosition: 4410, endOfStream: true)
        let ogaURL = dir.appendingPathComponent("sample.oga")
        try oggW.serializedStream().write(to: ogaURL)

        let inspRes = try runCLI(["inspect", ogaURL.path])
        let inspObj = try XCTUnwrap(JSONSerialization.jsonObject(with: inspRes.stdout) as? [String: Any])
        XCTAssertEqual(inspObj["kind"] as? String, "ogg")
        XCTAssertNotNil(inspObj["ogg"])

        let htmlExe = try htmlExecutableURL()
        let htmlURL = dir.appendingPathComponent("det.html")
        try """
        <!doctype html><html><body style="margin:0;background:#101828;color:#f8fafc;font-family:-apple-system;">
        <div id="box" style="width:160px;height:120px;display:flex;align-items:center;justify-content:center;font-size:24px;">A0</div>
        <script>
        window.__seek = (t) => { document.getElementById('box').textContent = 'T' + Math.round(t * 10); };
        </script></body></html>
        """.write(to: htmlURL, atomically: true, encoding: .utf8)

        func runHashRender(_ outName: String) throws -> String {
            let p = Process()
            p.executableURL = htmlExe
            p.arguments = [
                htmlURL.path,
                "--output", dir.appendingPathComponent(outName).path,
                "--width", "160",
                "--height", "120",
                "--fps", "10",
                "--frames", "6",
                "--video-only",
                "--hash",
                "--json",
            ]
            let outP = Pipe(), errP = Pipe()
            p.standardOutput = outP
            p.standardError = errP
            try p.run()
            let outD = outP.fileHandleForReading.readDataToEndOfFile()
            let errD = errP.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "safarium-html failed: \(String(decoding: errD, as: UTF8.self))")
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: outD) as? [String: Any])
            XCTAssertEqual(obj["ok"] as? Bool, true)
            let sha = try XCTUnwrap(obj["sha256"] as? String)
            XCTAssertEqual(sha.count, 64)
            return sha
        }
        let h1 = try runHashRender("h1.mp4")
        let h2 = try runHashRender("h2.mp4")
        XCTAssertEqual(h1, h2, "safarium-html --hash must be 100% deterministic across separate runs")
    }

    func testCLIWave6PrismRenderWebWithMetalSVGFiltersAndGrain() throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let dir = try makeTempDir("cli-w6-prism-metal")
        defer { try? FileManager.default.removeItem(at: dir) }

        let htmlURL = dir.appendingPathComponent("svg_filter.html")
        try """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          html, body { margin: 0; width: 128px; height: 128px; overflow: hidden; background: #0f172a; }
          svg { display: block; width: 128px; height: 128px; }
        </style>
        </head>
        <body>
          <svg viewBox="0 0 128 128" width="128" height="128" xmlns="http://www.w3.org/2000/svg">
            <defs>
              <filter id="ds" x="-30%" y="-30%" width="160%" height="160%">
                <feDropShadow dx="2" dy="4" stdDeviation="3" flood-color="#000000" flood-opacity="0.7" />
              </filter>
            </defs>
            <rect width="128" height="128" fill="#0f172a" />
            <rect id="box" x="16" y="24" width="48" height="48" rx="8" fill="#38bdf8" filter="url(#ds)" />
          </svg>
          <script>
            window.__seek = (t) => {
              document.getElementById('box').setAttribute('x', String(16 + Math.round(t * 60)));
            };
          </script>
        </body>
        </html>
        """.write(to: htmlURL, atomically: true, encoding: .utf8)

        let outMP4 = dir.appendingPathComponent("prism_metal.mp4")
        let res = try runCLI([
            "prism", "render-web", htmlURL.path,
            "-o", outMP4.path,
            "--width", "128",
            "--height", "128",
            "--fps", "30",
            "--frames", "2",
            "--grain", "0.02",
            "--metal-svg-filters",
            "--no-antilag",
            "--overwrite",
        ])
        XCTAssertEqual(res.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outMP4.path))
        let outBytes = ((try? FileManager.default.attributesOfItem(atPath: outMP4.path)[.size]) as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(outBytes, 0)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: res.stdout) as? [String: Any])
        XCTAssertEqual(obj["frames"] as? Int, 2)
    }
}
