import AVFoundation
import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import ImageIO
import SafariumCore
import SafariumForgeCore
@testable import SafariumPrism
import Vision
import XCTest

final class Wave6PrismWebTests: XCTestCase {
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
            .appendingPathComponent("safarium-w6-2b-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func sampleSystemFontURL(preferredExtensions: [String]) throws -> URL {
        let candidates = [
            "/System/Library/Fonts/Supplemental/Ayuthaya.ttf",
            "/System/Library/Fonts/Supplemental/Krungthep.ttf",
            "/System/Library/Fonts/NewYork.ttf",
            "/System/Library/Fonts/Supplemental/NotoSansJavanese-Regular.otf",
        ]
        for path in candidates {
            let u = URL(fileURLWithPath: path)
            if preferredExtensions.contains(u.pathExtension.lowercased()),
               FileManager.default.isReadableFile(atPath: u.path) {
                return u
            }
        }
        let dirs = ["/System/Library/Fonts/Supplemental", "/System/Library/Fonts"]
        for d in dirs {
            if let items = try? FileManager.default.contentsOfDirectory(atPath: d) {
                for name in items.sorted() where !name.hasPrefix("._") {
                    let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
                    if preferredExtensions.contains(ext) {
                        return URL(fileURLWithPath: d).appendingPathComponent(name)
                    }
                }
            }
        }
        throw SafariumError.invalidState("No system font found matching \(preferredExtensions)")
    }

    private func populateSampleFonts(in fontDir: URL) throws -> (ttfURL: URL, otfURL: URL, thaiURL: URL) {
        try FileManager.default.createDirectory(at: fontDir, withIntermediateDirectories: true)
        let sysTTF = try sampleSystemFontURL(preferredExtensions: ["ttf"])
        let sysOTF = try sampleSystemFontURL(preferredExtensions: ["otf"])

        let ttfDest = fontDir.appendingPathComponent("Kanit-Regular.ttf")
        let otfDest = fontDir.appendingPathComponent("Mali-Regular.otf")
        let thaiDest = fontDir.appendingPathComponent("ฟอนต์ไทย.ttf")
        let sidecarDest = fontDir.appendingPathComponent("._Kanit-Regular.ttf")

        try FileManager.default.copyItem(at: sysTTF, to: ttfDest)
        try FileManager.default.copyItem(at: sysOTF, to: otfDest)
        try FileManager.default.copyItem(at: sysTTF, to: thaiDest)
        try Data("appledouble-sidecar".utf8).write(to: sidecarDest)
        return (ttfDest, otfDest, thaiDest)
    }

    // MARK: - 1. Font Loopback Security, Thai/Unicode Percent-Decoding, @font-face & Clean Shutdown

    func testLoopbackFontServerSecurityAndThaiUnicodeCORS() async throws {
        let root = try makeTempDir("font-sec")
        let fontDir = root.appendingPathComponent("fonts", isDirectory: true)
        let outsideDir = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)

        let (ttfURL, otfURL, thaiURL) = try populateSampleFonts(in: fontDir)
        let secretFile = outsideDir.appendingPathComponent("secret.txt")
        try Data("TOP_SECRET_DATA".utf8).write(to: secretFile)

        let escapeLink = fontDir.appendingPathComponent("escape.ttf")
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: secretFile)

        let subDir = fontDir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let server = try ForgeLoopbackFontServer(fontDirURL: fontDir)
        let port = try server.start()
        defer { server.stop() }

        XCTAssertGreaterThan(port, 0)
        XCTAssertTrue(server.isRunning)

        // Direct resolver must reject traversal, symlink escape, ExFAT sidecar, and directories with SafariumError
        XCTAssertThrowsError(try server.resolveSafeAssetURL(requestPath: "/../outside/secret.txt")) { err in
            XCTAssertTrue(err is SafariumError)
        }
        XCTAssertThrowsError(try server.resolveSafeAssetURL(requestPath: "/%2e%2e/outside/secret.txt")) { err in
            XCTAssertTrue(err is SafariumError)
        }
        XCTAssertThrowsError(try server.resolveSafeAssetURL(requestPath: "/escape.ttf")) { err in
            XCTAssertTrue(err is SafariumError)
        }
        XCTAssertThrowsError(try server.resolveSafeAssetURL(requestPath: "/._Kanit-Regular.ttf")) { err in
            XCTAssertTrue(err is SafariumError)
        }
        XCTAssertThrowsError(try server.resolveSafeAssetURL(requestPath: "/nested")) { err in
            XCTAssertTrue(err is SafariumError)
        }

        // Valid files + Thai percent-decoding must resolve cleanly
        let resolvedTTF = try server.resolveSafeAssetURL(requestPath: "/Kanit-Regular.ttf")
        XCTAssertEqual(resolvedTTF.lastPathComponent, ttfURL.lastPathComponent)
        let resolvedThai = try server.resolveSafeAssetURL(
            requestPath: "/%E0%B8%9F%E0%B8%AD%E0%B8%99%E0%B8%95%E0%B9%8C%E0%B9%84%E0%B8%97%E0%B8%A2.ttf"
        )
        XCTAssertEqual(resolvedThai.lastPathComponent, thaiURL.lastPathComponent)

        // Font discovery & @font-face generation skips ._* sidecars and includes Thai font
        let entries = try server.discoveredFontEntries()
        XCTAssertFalse(entries.contains { $0.filename.hasPrefix("._") })
        XCTAssertTrue(entries.contains { $0.filename == "Kanit-Regular.ttf" })
        XCTAssertTrue(entries.contains { $0.filename == "Mali-Regular.otf" })
        XCTAssertTrue(entries.contains { $0.filename == "ฟอนต์ไทย.ttf" })
        let css = try server.fontFaceCSS()
        XCTAssertTrue(css.contains("@font-face"))
        XCTAssertTrue(css.contains("format(\"truetype\")"))
        XCTAssertTrue(css.contains("format(\"opentype\")"))

        // HTTP verification via URLSession
        let session = URLSession(configuration: .ephemeral)
        for (reqPath, expectedFile, expectedMIME) in [
            ("/Kanit-Regular.ttf", ttfURL, "font/ttf"),
            ("/Mali-Regular.otf", otfURL, "font/otf"),
            ("/%E0%B8%9F%E0%B8%AD%E0%B8%99%E0%B8%95%E0%B9%8C%E0%B9%84%E0%B8%97%E0%B8%A2.ttf", thaiURL, "font/ttf"),
        ] {
            let url = URL(string: "http://127.0.0.1:\(port)\(reqPath)")!
            let (data, resp) = try await session.data(from: url)
            let http = try XCTUnwrap(resp as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 200)
            XCTAssertEqual(http.value(forHTTPHeaderField: "Access-Control-Allow-Origin"), "*")
            XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Type"), expectedMIME)
            XCTAssertEqual(data, try Data(contentsOf: expectedFile))
        }

        // HTTP traversal & symlink escape rejected (403), ExFAT sidecar hidden (404)
        let (_, escResp) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/escape.ttf")!)
        XCTAssertEqual((escResp as? HTTPURLResponse)?.statusCode, 403)

        let (_, travResp) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/%2e%2e/outside/secret.txt")!)
        XCTAssertEqual((travResp as? HTTPURLResponse)?.statusCode, 403)

        let (_, sidecarResp) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/._Kanit-Regular.ttf")!)
        XCTAssertEqual((sidecarResp as? HTTPURLResponse)?.statusCode, 404)

        // Deterministic teardown
        server.stop()
        XCTAssertFalse(server.isRunning)
        do {
            _ = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/Kanit-Regular.ttf")!)
            XCTFail("Server must reject connections after stop()")
        } catch {
            // Connection refused expected
        }
    }

    // MARK: - 2. renderWeb3D Flexible Lifecycle Hooks, outputFPS 30->60, Grain, Font Mount & Metal SVG Filter Surgery

    @MainActor
    func testRenderWeb3DFlexibleHooksOutputFPSGrainAndSVGFilters() async throws {
        let dir = try makeTempDir("render-hooks")
        let fontDir = dir.appendingPathComponent("fonts", isDirectory: true)
        _ = try populateSampleFonts(in: fontDir)

        let initFile = dir.appendingPathComponent("init_hook.js")
        try """
        window.__initMultiplier = 2.0;
        """.write(to: initFile, atomically: true, encoding: .utf8)

        let htmlURL = dir.appendingPathComponent("custom_app.html")
        let html = """
        <!doctype html>
        <html lang="th">
        <head>
        <meta charset="utf-8">
        <style>
          html, body { margin: 0; padding: 0; width: 320px; height: 320px; overflow: hidden; background: #0f172a; }
          svg { display: block; width: 320px; height: 320px; }
        </style>
        </head>
        <body>
        <svg id="scene" viewBox="0 0 320 320" width="320" height="320" xmlns="http://www.w3.org/2000/svg">
          <defs>
            <filter id="card-shadow" x="-30%" y="-30%" width="160%" height="160%">
              <feDropShadow dx="4" dy="8" stdDeviation="6" flood-color="#000000" flood-opacity="0.7" />
            </filter>
            <filter id="glow" x="-30%" y="-30%" width="160%" height="160%">
              <feGaussianBlur stdDeviation="8" result="blur" />
              <feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>
            </filter>
          </defs>
          <rect x="0" y="0" width="320" height="320" fill="#0f172a" />
          <g id="card-group" filter="url(#card-shadow)">
            <rect id="mover" x="30" y="60" width="90" height="90" rx="14" fill="#ef4444" />
          </g>
          <circle id="orb" cx="220" cy="210" r="36" fill="#38bdf8" filter="url(#glow)" />
          <text id="thai-label" x="160" y="290" text-anchor="middle"
                style="font-family: 'ฟอนต์ไทย', 'Ayuthaya', sans-serif; font-size: 32px; fill: #ffffff;">ปิ๊ง ญ ฐ</text>
        </svg>
        <script>
        (() => {
          window.__myAppReady = false;
          setTimeout(() => { window.__myAppReady = true; }, 20);
          window.__myAdvance = (t, frame, fps, dur) => {
            const mult = window.__initMultiplier || 1.0;
            const x = 30 + Math.round((t * 150) * mult) + (window.__initTag === 'wave6' ? 10 : 0);
            const r = document.getElementById('mover');
            r.setAttribute('x', String(x));
            window.__lastAdvance = { t, frame, fps, dur, tag: window.__initTag };
          };
        })();
        </script>
        </body>
        </html>
        """
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)

        let outMP4 = dir.appendingPathComponent("out_60fps.mp4")
        let opts = PrismWebRenderOptions(
            readyExpr: "window.__myAppReady === true",
            initJS: "window.__initTag = 'wave6';",
            initFileURL: initFile,
            seekExpr: "window.__myAdvance({t}, {frame}, {fps}, {duration})",
            outputFPS: 60,
            grainIntensity: 0.02,
            fontDirURL: fontDir,
            metalSVGFilters: true,
            preserveSharpText1x: true
        )

        let report = try await PrismHybridEngine.renderWeb3D(
            htmlURL: htmlURL,
            outputURL: outMP4,
            width: 320,
            height: 320,
            fps: 30,
            frames: 3,
            codec: .h264,
            governorConfig: PrismAntiLagConfig(enabled: false),
            overwrite: true,
            options: opts
        )

        XCTAssertEqual(report.fps, 60)
        XCTAssertEqual(report.frames, 6)
        XCTAssertGreaterThan(report.primaryBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outMP4.path))

        let probe = try await PacketProbe.inspect(url: outMP4)
        XCTAssertTrue(probe.playable)
        let vTrack = try XCTUnwrap(probe.tracks.first { $0.mediaType == "vide" })
        XCTAssertEqual(vTrack.packetCount, 6)
        XCTAssertEqual(vTrack.nominalFrameRate ?? 0, 60.0, accuracy: 0.5)
        for i in 1..<vTrack.packets.count {
            XCTAssertGreaterThan(vTrack.packets[i].ptsSeconds, vTrack.packets[i - 1].ptsSeconds)
        }

        let reader = try await SafariumSequentialVideoReader(url: outMP4, loop: false, pixelFormat: kCVPixelFormatType_32BGRA)
        defer { reader.close() }
        let pb0 = try XCTUnwrap(try reader.pixelBuffer(at: 0.0))
        let pbEnd = try XCTUnwrap(try reader.pixelBuffer(at: 5.0 / 60.0))
        XCTAssertNotEqual(Self.pixelBufferBGRA(pb0), Self.pixelBufferBGRA(pbEnd), "Custom seekExpr + outputFPS must show animation progression")

        // Verify grain modifies pixels deterministically on a static card
        let staticHTML = dir.appendingPathComponent("static.html")
        try """
        <!doctype html><html><body style="margin:0;width:128px;height:128px;background:#336699;"></body></html>
        """.write(to: staticHTML, atomically: true, encoding: .utf8)
        let cleanMP4 = dir.appendingPathComponent("clean.mp4")
        let grainMP4 = dir.appendingPathComponent("grain.mp4")
        _ = try await PrismHybridEngine.renderWeb3D(
            htmlURL: staticHTML, outputURL: cleanMP4, width: 128, height: 128, fps: 30, frames: 2,
            governorConfig: PrismAntiLagConfig(enabled: false), overwrite: true
        )
        _ = try await PrismHybridEngine.renderWeb3D(
            htmlURL: staticHTML, outputURL: grainMP4, width: 128, height: 128, fps: 30, frames: 2,
            governorConfig: PrismAntiLagConfig(enabled: false), overwrite: true,
            options: PrismWebRenderOptions(grainIntensity: 0.04)
        )
        let cleanReader = try await SafariumSequentialVideoReader(url: cleanMP4, loop: false, pixelFormat: kCVPixelFormatType_32BGRA)
        let grainReader = try await SafariumSequentialVideoReader(url: grainMP4, loop: false, pixelFormat: kCVPixelFormatType_32BGRA)
        defer { cleanReader.close(); grainReader.close() }
        let cleanPB = try XCTUnwrap(try cleanReader.pixelBuffer(at: 0.0))
        let grainPB = try XCTUnwrap(try grainReader.pixelBuffer(at: 0.0))
        XCTAssertNotEqual(Self.pixelBufferBGRA(cleanPB), Self.pixelBufferBGRA(grainPB), "Metal grain must apply procedural noise before encode")
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .prohibited)
    }

    // MARK: - 3. Inline Loudnorm + Peak Limiter + apad

    @MainActor
    func testRenderWeb3DInlineLoudnormAndApadAudio() async throws {
        let dir = try makeTempDir("loudnorm-apad")
        let quietWAV = dir.appendingPathComponent("quiet_short.wav")
        let synthSpec = ForgeAudioSynthSpec(
            waveform: "sine",
            frequencyHz: 440.0,
            amplitude: 0.04, // ~ -31 LUFS
            durationSeconds: 0.25,
            sampleRate: 48_000,
            channels: 2
        )
        _ = try await ForgeProceduralSynth.renderToFile(spec: synthSpec, outputURL: quietWAV, overwrite: true)

        let htmlURL = dir.appendingPathComponent("card.html")
        try """
        <!doctype html><html><body style="margin:0;width:128px;height:128px;background:#1e293b;"></body></html>
        """.write(to: htmlURL, atomically: true, encoding: .utf8)

        let outMP4 = dir.appendingPathComponent("muxed_norm_apad.mp4")
        let opts = PrismWebRenderOptions(
            loudnormTargetI: -16.0,
            loudnormTruePeak: -1.5,
            audioPadToVideo: true
        )
        let report = try await PrismHybridEngine.renderWeb3D(
            htmlURL: htmlURL,
            outputURL: outMP4,
            width: 128,
            height: 128,
            fps: 30,
            frames: 18, // 0.60s video > 0.25s audio -> apad must pad trailing silence to 0.60s
            audioURL: quietWAV,
            governorConfig: PrismAntiLagConfig(enabled: false),
            overwrite: true,
            options: opts
        )
        XCTAssertGreaterThan(report.primaryBytes, 0)

        let probe = try await PacketProbe.inspect(url: outMP4)
        XCTAssertTrue(probe.playable)
        let aTrack = try XCTUnwrap(probe.tracks.first { $0.mediaType == "soun" })
        XCTAssertGreaterThanOrEqual(aTrack.durationSeconds, 0.55, "apad must extend 0.25s audio to ~0.60s video duration")

        let qa = try await NativeQAAnalyzer.analyze(url: outMP4)
        XCTAssertTrue(qa.hasAudioTrack)
        if let lufs = qa.audioLoudnessLUFS {
            XCTAssertGreaterThan(lufs, -22.0, "Inline loudnorm should boost -31 LUFS toward -16 LUFS, got \(lufs)")
        } else {
            XCTFail("Expected measured audioLoudnessLUFS in muxed output")
        }
        if let tp = qa.audioTruePeakDBTP {
            XCTAssertLessThanOrEqual(tp, -1.2, "OfflinePeakLimiter should enforce true peak ceiling <= -1.5 dBTP (within AAC encode tolerance), got \(tp)")
        }
    }

    // MARK: - 4. SVG Filter Surgery Unit & Sharp Text Safeguard

    @MainActor
    func testPrismWebKit3DSVGFilterSurgeryAndOptOut() async throws {
        let dir = try makeTempDir("svg-surgery")
        let htmlURL = dir.appendingPathComponent("svg_test.html")
        try """
        <!doctype html>
        <html lang="th">
        <head><meta charset="utf-8"><style>
          html, body { margin: 0; width: 320px; height: 320px; background: #102030; }
        </style></head>
        <body>
          <svg width="320" height="320" xmlns="http://www.w3.org/2000/svg">
            <defs>
              <filter id="ds"><feDropShadow dx="4" dy="6" stdDeviation="5" flood-color="#000" flood-opacity="0.6"/></filter>
              <filter id="keepBlur"><feGaussianBlur stdDeviation="3"/></filter>
            </defs>
            <g id="targetGroup" filter="url(#ds)"><rect x="20" y="20" width="120" height="80" fill="#f97316"/></g>
            <g id="optedOutGroup" data-safarium-keep-filter="1" filter="url(#keepBlur)"><rect x="180" y="20" width="100" height="80" fill="#22c55e"/></g>
            <text id="thaiText" x="160" y="220" text-anchor="middle" style="font-family: 'Kanit', 'Ayuthaya', sans-serif; font-size: 36px; fill: #fff;">ปิ๊ง ญ ฐ ก่ำ</text>
          </svg>
        </body>
        </html>
        """.write(to: htmlURL, atomically: true, encoding: .utf8)

        let host = try await PrismWebKit3D(width: 320, height: 320, transparent: true)
        defer { host.close() }
        try await host.loadHTMLFile(htmlURL)

        let plan = try await host.applySVGFilterSurgery(preserveSharpText1x: true)
        XCTAssertFalse(plan.ops.isEmpty)
        XCTAssertTrue(plan.hasSharpTextLayer)

        let targetFilter = try await host.evaluate("return document.getElementById('targetGroup').getAttribute('filter');")
        XCTAssertTrue(targetFilter == nil || targetFilter is NSNull, "Target heavy SVG filter must be stripped")
        let optOutFilter = try await host.evaluate("return document.getElementById('optedOutGroup').getAttribute('filter');") as? String
        XCTAssertEqual(optOutFilter, "url(#keepBlur)", "Opted-out element must retain its original filter")
        let sharpAttr = try await host.evaluate("return document.getElementById('thaiText').getAttribute('data-sf-sharp-text');") as? String
        XCTAssertEqual(sharpAttr, "1", "Thai Kanit text must be tagged for crisp 1x preservation")
    }

    // MARK: - 5. ForgeBatchDOM Warm Auto-BBox Transparent Thai PNG Batcher

    @MainActor
    func testForgeBatchDOMWarmAutoBBoxThaiAndEmptyManifest() async throws {
        let dir = try makeTempDir("batch-dom")
        let fontDir = dir.appendingPathComponent("fonts", isDirectory: true)
        _ = try populateSampleFonts(in: fontDir)

        // Empty manifest [] must throw SafariumError
        let emptyManifestURL = dir.appendingPathComponent("empty.json")
        try Data("[]".utf8).write(to: emptyManifestURL)
        do {
            _ = try await ForgeBatchDOM.run(manifestURL: emptyManifestURL)
            XCTFail("Empty manifest [] must throw SafariumError")
        } catch let err as SafariumError {
            XCTAssertFalse("\(err)".isEmpty)
        }

        // Prepare 3 cards with Thai upper/lower diacritics (ปิ๊ง ญ ฐ ก่ำ)
        let card1HTML = dir.appendingPathComponent("card1.html")
        try """
        <!doctype html>
        <html lang="th">
        <head><meta charset="utf-8"><style>
          html, body { margin: 0; padding: 24px; background: transparent; }
          .badge {
            display: inline-block; padding: 18px 28px; border-radius: 16px;
            background: #1e293b; color: #ffffff; border: 3px solid #38bdf8;
            font-family: 'ฟอนต์ไทย', 'Ayuthaya', sans-serif; font-size: 44px; line-height: 1.45;
          }
        </style></head>
        <body><div id="card" class="badge">ปิ๊ง ญ ฐ ก่ำ</div></body>
        </html>
        """.write(to: card1HTML, atomically: true, encoding: .utf8)

        let out1 = dir.appendingPathComponent("การ์ด_ปิ๊ง_01.png")
        let out2 = dir.appendingPathComponent("การ์ด_ญฐ_02.png")
        let out3 = dir.appendingPathComponent("การ์ด_ก่ำ_03.png")

        let items: [ForgeBatchDOMItem] = [
            ForgeBatchDOMItem(
                id: "card-1",
                htmlPath: card1HTML.path,
                selector: "#card",
                padding: 10,
                transparent: true,
                outputPath: out1.path
            ),
            ForgeBatchDOMItem(
                id: "card-2",
                htmlContent: """
                <!doctype html><html lang="th"><head><meta charset="utf-8"><style>
                html,body{margin:0;padding:24px;background:transparent;}
                .bubble{display:inline-block;padding:16px 26px;background:#7e2a24;color:#fff;border-radius:14px;font-family:'Ayuthaya',sans-serif;font-size:40px;line-height:1.4;}
                </style></head><body><div class="bubble">ญี่ปุ่น ฐานะ ปิ๊</div></body></html>
                """,
                selector: ".bubble",
                padding: 8,
                transparent: true,
                outputPath: out2.path,
                readyExpr: "document.querySelector('.bubble') !== null"
            ),
            ForgeBatchDOMItem(
                id: "card-3",
                htmlContent: """
                <!doctype html><html lang="th"><head><meta charset="utf-8"><style>
                html,body{margin:0;padding:24px;background:transparent;}
                #pill{display:inline-block;padding:16px 24px;background:#0f766e;color:#fff;border-radius:12px;font-family:'Ayuthaya',sans-serif;font-size:38px;line-height:1.4;}
                </style></head><body><div id="pill">ก่ำกึ่ง ปู่ย่า ฐิติ</div></body></html>
                """,
                padding: 8,
                transparent: true,
                outputPath: out3.path
            ),
        ]

        let manifestURL = dir.appendingPathComponent("manifest.json")
        let manifestData = try JSONEncoder().encode(items)
        try manifestData.write(to: manifestURL)

        let report = try await ForgeBatchDOM.run(
            manifestURL: manifestURL,
            fontDirURL: fontDir,
            overwrite: true
        )

        XCTAssertEqual(report.totalItems, 3)
        XCTAssertEqual(report.succeeded, 3)
        XCTAssertEqual(report.items.count, 3)
        XCTAssertGreaterThan(report.peakRSSMB, 0)
        XCTAssertGreaterThan(report.wallMs, 0)

        for res in report.items {
            XCTAssertTrue(res.ok, "Item failed: \(res.error ?? "?")")
            XCTAssertGreaterThan(res.bytes, 0)
            XCTAssertGreaterThan(res.width, 40)
            XCTAssertLessThan(res.width, 1000, "Auto-crop should tightly bound card width instead of full viewport")
            XCTAssertGreaterThan(res.height, 40)
            XCTAssertLessThan(res.height, 500, "Auto-crop should tightly bound card height instead of full viewport")

            let pngURL = URL(fileURLWithPath: res.outputPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: pngURL.path))
            guard let src = CGImageSourceCreateWithURL(pngURL as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                XCTFail("Failed decoding PNG at \(pngURL.path)")
                continue
            }
            XCTAssertEqual(cg.width, res.width)
            XCTAssertEqual(cg.height, res.height)

            let snap = Snapshot(cgImage: cg)
            // Corner pixel outside rounded card padding must be transparent (alpha == 0)
            let cornerTL = snap.pixel(x: 0, y: 0)
            let cornerBR = snap.pixel(x: cg.width - 1, y: cg.height - 1)
            XCTAssertEqual(cornerTL.a, 0, "Top-left corner must preserve transparent alpha")
            XCTAssertEqual(cornerBR.a, 0, "Bottom-right corner must preserve transparent alpha")

            // Center pixel of card must be opaque
            let center = snap.pixel(x: cg.width / 2, y: cg.height / 2)
            XCTAssertGreaterThan(center.a, 200, "Card center must be opaque")

            // Top row (y=0) and bottom row (y=h-1) must be empty alpha=0 thanks to safety padding (no Thai clip!)
            let bgra = try snap.checkedBGRA()
            let rowBytes = cg.width * 4
            let topMaxA = bgra.withUnsafeBytes { raw -> UInt8 in
                let ptr = raw.bindMemory(to: UInt8.self)
                var m: UInt8 = 0
                for x in 0..<cg.width { m = max(m, ptr[x * 4 + 3]) }
                return m
            }
            let botMaxA = bgra.withUnsafeBytes { raw -> UInt8 in
                let ptr = raw.bindMemory(to: UInt8.self)
                var m: UInt8 = 0
                let base = (cg.height - 1) * rowBytes
                for x in 0..<cg.width { m = max(m, ptr[base + x * 4 + 3]) }
                return m
            }
            XCTAssertEqual(topMaxA, 0, "Top border row must have alpha == 0 (no clipped upper Thai tone marks)")
            XCTAssertEqual(botMaxA, 0, "Bottom border row must have alpha == 0 (no clipped lower Thai vowels/glyphs)")
        }

        // overwrite: false must reject existing output cleanly
        do {
            _ = try await ForgeBatchDOM.run(manifestURL: manifestURL, fontDirURL: fontDir, overwrite: false)
            XCTFail("Expected overwrite=false to fail on existing output files")
        } catch is SafariumError {
            // Expected
        }
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .prohibited)
    }

    @MainActor
    func testRenderWeb3DIgnoresOfflineBlockedExternalFontLinkButFailsLocalLink() async throws {
        let dir = try makeTempDir("ext-vs-local-link")
        let extHTML = dir.appendingPathComponent("external_font_link.html")
        try """
        <!doctype html><html><head><meta charset="utf-8">
        <link href="https://fonts.googleapis.com/css2?family=Kanit" rel="stylesheet">
        </head><body style="margin:0;width:128px;height:128px;background:#1e293b;"></body></html>
        """.write(to: extHTML, atomically: true, encoding: .utf8)

        let okMP4 = dir.appendingPathComponent("ext_ok.mp4")
        let report = try await PrismHybridEngine.renderWeb3D(
            htmlURL: extHTML,
            outputURL: okMP4,
            width: 128,
            height: 128,
            fps: 30,
            frames: 2,
            governorConfig: PrismAntiLagConfig(enabled: false),
            overwrite: true
        )
        XCTAssertEqual(report.frames, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: okMP4.path))
        XCTAssertGreaterThan(report.primaryBytes, 0)

        let badHTML = dir.appendingPathComponent("missing_local_link.html")
        try """
        <!doctype html><html><head><meta charset="utf-8">
        <link href="does_not_exist_local.css" rel="stylesheet">
        </head><body style="margin:0;width:128px;height:128px;background:#1e293b;"></body></html>
        """.write(to: badHTML, atomically: true, encoding: .utf8)

        let badMP4 = dir.appendingPathComponent("local_fail.mp4")
        do {
            _ = try await PrismHybridEngine.renderWeb3D(
                htmlURL: badHTML,
                outputURL: badMP4,
                width: 128,
                height: 128,
                fps: 30,
                frames: 2,
                governorConfig: PrismAntiLagConfig(enabled: false),
                overwrite: true
            )
            XCTFail("Expected missing local <link> stylesheet to fail renderWeb3D")
        } catch let SafariumError.javascript(msg) {
            XCTAssertTrue(msg.contains("could not load local <link> asset"), "Unexpected JS error message: \(msg)")
        }
    }

    @MainActor
    func testAuditSecurityHardeningSymlinkSidecarCSSEscapeAndLoopbackUserinfo() async throws {
        let root = try makeTempDir("audit-sec")
        let fontDir = root.appendingPathComponent("fonts", isDirectory: true)
        let (ttfURL, _, _) = try populateSampleFonts(in: fontDir)

        // Symlink inside fontDir targeting an AppleDouble ._* sidecar inside the same root must be rejected (404)
        let sidecarTarget = fontDir.appendingPathComponent("._Kanit-Regular.ttf")
        let sidecarAlias = fontDir.appendingPathComponent("alias_sidecar.ttf")
        try FileManager.default.createSymbolicLink(at: sidecarAlias, withDestinationURL: sidecarTarget)

        // Font filename containing CSS/HTML breakout chars (newlines + '<' / '>') must be safely CSS-escaped
        let hostileFont = fontDir.appendingPathComponent("Evil\n<style>Font.ttf")
        try FileManager.default.copyItem(at: ttfURL, to: hostileFont)

        let server = try ForgeLoopbackFontServer(fontDirURL: fontDir)
        let port = try server.start()
        defer { server.stop() }

        XCTAssertThrowsError(try server.resolveSafeAssetURL(requestPath: "/alias_sidecar.ttf")) { err in
            XCTAssertTrue(err is SafariumError)
        }
        let session = URLSession(configuration: .ephemeral)
        let (_, aliasResp) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/alias_sidecar.ttf")!)
        XCTAssertEqual((aliasResp as? HTTPURLResponse)?.statusCode, 404)

        let css = try server.fontFaceCSS()
        XCTAssertFalse(css.contains("<style>"), "CSS output must escape '<' / '>' to prevent style breakout")
        XCTAssertTrue(css.contains("\\3c style\\3e "), "CSS output must contain hex-escaped brackets")

        // Loopback URL carrying HTTP userinfo must be refused
        let host = try await PrismWebKit3D(width: 128, height: 128, transparent: false, allowLoopbackHTTP: true)
        defer { host.close() }
        do {
            try await host.loadURL(URL(string: "http://127.0.0.1:80@example.com/")!)
            XCTFail("loadURL must reject loopback lookalike URLs with userinfo")
        } catch let SafariumError.invalidState(msg) {
            XCTAssertTrue(msg.contains("userinfo"), "Unexpected error message: \(msg)")
        }
    }

    // MARK: - Helpers

    private static func pixelBufferBGRA(_ pb: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return Data() }
        let h = CVPixelBufferGetHeight(pb)
        let w = CVPixelBufferGetWidth(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var out = Data(count: w * h * 4)
        out.withUnsafeMutableBytes { dst in
            for y in 0..<h {
                memcpy(dst.baseAddress!.advanced(by: y * w * 4), base.advanced(by: y * stride), w * 4)
            }
        }
        return out
    }
}
