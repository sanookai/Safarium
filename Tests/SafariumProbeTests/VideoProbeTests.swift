import XCTest
import AVFoundation
import AppKit
import CryptoKit
import SafariumCore

/// Probe 2 (<video> seek accuracy) and Probe 3 (HEVC with alpha decode).
/// The <video> probes need ffmpeg + a few seconds of encoding → opt-in (SAFARIUM_PROBES=1). The alpha probe is small and always runs.
@MainActor
final class VideoProbeTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare() }

    static let fps = 30
    static let frames = 150

    // MARK: ffmpeg + clip generation

    /// `SAFARIUM_FFMPEG` env, else first `ffmpeg` on PATH, else /opt/homebrew/bin/ffmpeg.
    static func findFFmpeg() -> String? {
        let fm = FileManager.default
        if let e = ProcessInfo.processInfo.environment["SAFARIUM_FFMPEG"], fm.isExecutableFile(atPath: e) { return e }
        let dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin"]
        for d in dirs { let p = d + "/ffmpeg"; if fm.isExecutableFile(atPath: p) { return p } }
        return nil
    }

    /// Runs a process with stdout+stderr on ONE pipe, read to EOF before waiting (neither stream can fill and deadlock the child).
    static func run(_ exe: String, _ args: [String]) throws -> (Int32, String) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let pipe = Pipe(); p.standardError = pipe; p.standardOutput = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// True when `encoders` (ffmpeg -encoders output) lists `lib` as a whole word (`libx264` must not match `libx264rgb`).
    static func hasEncoder(_ encoders: String, _ lib: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "(?<![A-Za-z0-9_])" + NSRegularExpression.escapedPattern(for: lib) + "(?![A-Za-z0-9_])") else { return false }
        return re.firstMatch(in: encoders, range: NSRange(encoders.startIndex..., in: encoders)) != nil
    }

    /// 640x360 clip; frame number N burned in as 16 black/white 40x40 blocks (bit i of N) along the top row — compression-proof.
    /// Cached by label + parameters; written to `<name>.tmp` then moved into place only when ffmpeg exits 0.
    func makeClip(_ label: String, vcodec: [String], gop: Int) throws -> URL {
        guard let ffmpeg = Self.findFFmpeg() else { throw XCTSkip("ffmpeg not found (set SAFARIUM_FFMPEG or add it to PATH)") }
        let (_, encoders) = try Self.run(ffmpeg, ["-hide_banner", "-encoders"])
        let lib = vcodec.first { $0.hasPrefix("lib") } ?? ""
        if !lib.isEmpty { try XCTSkipUnless(Self.hasEncoder(encoders, lib), "ffmpeg at \(ffmpeg) lacks encoder \(lib)") }
        let expr = "if(lt(Y,40),255*mod(floor(N/pow(2,floor(X/40))),2),128+60*sin(X/50+N/10))"
        let args = ["-y", "-v", "error", "-f", "lavfi", "-i", "color=c=gray:s=640x360:r=\(Self.fps):d=\(Self.frames / Self.fps)",
                    "-vf", "geq=lum='\(expr)':cb=128:cr=128,format=yuv420p", "-frames:v", "\(Self.frames)"] + vcodec + ["-g", "\(gop)", "-an"]
        let key = SHA256.hash(data: Data((args.joined(separator: "|") + "|v1").utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        let dir = Probe.scratch.appendingPathComponent("probe-clips")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let final = dir.appendingPathComponent("\(label)-\(key).mp4"), tmp = dir.appendingPathComponent("\(label)-\(key).tmp")
        if FileManager.default.fileExists(atPath: final.path) { return final }
        try? FileManager.default.removeItem(at: tmp)
        let (status, log) = try Self.run(ffmpeg, args + ["-f", "mp4", tmp.path])
        guard status == 0 else { try? FileManager.default.removeItem(at: tmp); throw SafariumError.encode("ffmpeg (\(ffmpeg)) exit \(status): \(log)") }
        try FileManager.default.moveItem(at: tmp, to: final)
        Probe.log("ffmpeg used: \(ffmpeg) → \(final.lastPathComponent)")
        return final
    }

    /// Reads the burned-in frame number from a 640x360 snapshot.
    func decodeFrameNumber(_ s: Snapshot) -> Int {
        var n = 0
        for i in 0..<16 { if s.pixel(x: 20 + 40 * i, y: 20).g > 128 { n |= (1 << i) } }
        return n
    }

    // MARK: page with a <video> (core video modes)

    /// Core-owned video page: `.element` = off-screen window + canvas copy, `.extract` = native AVAssetImageGenerator frames.
    /// The caller must `page.close()` (releases the hidden window) — use `defer` right after this returns; if setup throws here
    /// the window is released before the error propagates.
    private func videoPage(_ clip: URL, mode: VideoMode) async throws -> Page {
        let page = try await Page(config: PageConfig(width: 640, height: 360, deterministicClock: true, video: mode))
        do {
            try await page.load(.fileURL(try Probe.siteURL("video.html"), readAccess: Probe.scratch))
            let src = "../probe-clips/\(clip.lastPathComponent)"
            switch mode {
            case .element:
                let dur = try await page.evaluate("return await window.__loadClip(src)", arguments: ["src": src], timeout: 15)
                _ = try XCTUnwrap(dur as? Double, "clip failed to load (duration: \(String(describing: dur)))")
            default:
                try await page.evaluate("v.src = src; return true", arguments: ["src": src], timeout: 10)
            }
            return page
        } catch {
            page.close()
            throw error
        }
    }

    struct Stat { var exact = 0, off = [Int: Int](), total = 0, ms = 0.0, seekErrors = 0 }

    /// Seeks with the core (`page.seek`) to t = (n + offset)/fps for every n in `order` and decodes the frame that is actually visible.
    private func measure(_ page: Page, offset: Double, order: [Int], saveTag: String?) async throws -> Stat {
        var st = Stat()
        for n in order {
            let t = (Double(n) + offset) / Double(Self.fps)
            let a = CFAbsoluteTimeGetCurrent()
            do { try await page.seek(t) } catch { st.seekErrors += 1 }
            let s = try await page.snapshot()
            st.ms += (CFAbsoluteTimeGetCurrent() - a) * 1000
            let got = decodeFrameNumber(s)
            st.total += 1
            if got == n { st.exact += 1 } else { st.off[got - n, default: 0] += 1 }
            if let tag = saveTag, n == order.first || n == order.last { Probe.save(s, "\(tag)-n\(n)") }
        }
        return st
    }

    /// Deterministic pseudo-random frame order, never the same frame twice in a row (a repeat would be a no-op seek).
    static func randomOrder(count: Int, seed: UInt64 = 42) -> [Int] {
        var s = seed, out: [Int] = []
        while out.count < count {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let n = Int((s >> 33) % UInt64(frames))
            if n != out.last { out.append(n) }
        }
        return out
    }

    /// Strict seek-accuracy probe. Every configuration must land on exactly the requested frame with no failed seek.
    /// `knownGap`: a NAMED core gap this (clip, mode) pair is known to hit; the whole assertion block is then a STRICT expected
    /// failure (it fails the test as soon as the gap is fixed, so the marker cannot rot).
    private func probeClip(_ label: String, vcodec: [String], gop: Int, mode: VideoMode, knownGap: String? = nil) async throws {
        try Probe.requireHeavy()
        let clip = try makeClip(label, vcodec: vcodec, gop: gop)
        let page = try await videoPage(clip, mode: mode); defer { page.close() }
        let sequential = Array(0..<60), random = Self.randomOrder(count: 60)
        // warm-up (first decode) at a frame that is NOT one of the measured times, not counted
        _ = try await measure(page, offset: 0.5, order: [100], saveTag: nil)
        let tag = "\(label)-\(mode)"
        let mid = try await measure(page, offset: 0.5, order: sequential, saveTag: "video-\(tag)-mid")
        let midRand = try await measure(page, offset: 0.5, order: random, saveTag: nil)
        let bound = try await measure(page, offset: 0.0, order: sequential, saveTag: "video-\(tag)-boundary")
        let boundRand = try await measure(page, offset: 0.0, order: random, saveTag: nil)
        let biased = try await measure(page, offset: 0.25, order: random, saveTag: nil)
        let errs = [mid, midRand, bound, boundRand, biased].map(\.seekErrors).reduce(0, +)
        Probe.log("video \(label) [core mode .\(mode)]: mid-frame seq \(mid.exact)/\(mid.total) rand \(midRand.exact)/\(midRand.total) off=\(midRand.off) | boundary t=n/30 seq \(bound.exact)/\(bound.total) off=\(bound.off) rand \(boundRand.exact)/\(boundRand.total) off=\(boundRand.off) | +0.25 frame rand \(biased.exact)/\(biased.total) off=\(biased.off) | seek errors \(errs) | ms per seek+snapshot \(String(format: "%.1f", mid.ms / Double(mid.total)))")
        if mode == .element {
            // Info only (not asserted): the raw fixture path (currentTime = t, no centre-of-frame rule) shows why the core hook biases the target.
            let raw = try await rawElementProbe(page)
            Probe.log("video \(label) INFO ONLY raw element path (currentTime = n/30 exactly, no core rule): \(raw.exact)/\(raw.total) off=\(raw.off)")
        }
        if let gap = knownGap { XCTExpectFailure("known core gap: \(gap)") }
        for (name, s) in [("mid-frame sequential", mid), ("mid-frame random", midRand), ("boundary t=n/fps sequential", bound),
                          ("boundary t=n/fps random", boundRand), ("boundary + 0.25 frame random", biased)] {
            XCTAssertEqual(s.seekErrors, 0, "\(label) \(mode) \(name): page.seek threw")
            XCTAssertTrue(s.off.isEmpty, "\(label) \(mode) \(name): not frame-accurate (offset→count \(s.off))")
        }
    }

    /// Info-only baseline: bypasses the core hook and sets `currentTime` through the fixture helper at the exact boundary.
    /// Earlier runs landed on frame n-1 for most n: likely because n/30 in binary floating point sits a hair below the frame's pts, so
    /// the decoder picks the previous frame (a time-rounding effect, not necessarily a seek error). The core hook avoids it by seeking to frame centres.
    private func rawElementProbe(_ page: Page) async throws -> Stat {
        var st = Stat()
        for n in Self.randomOrder(count: 30, seed: 5) {
            _ = try await page.evaluate("return await window.__seekVideo(t, false, true, 0)", arguments: ["t": Double(n) / Double(Self.fps)], timeout: 10)
            let got = decodeFrameNumber(try await page.snapshot())
            st.total += 1
            if got == n { st.exact += 1 } else { st.off[got - n, default: 0] += 1 }
        }
        return st
    }

    static let x264 = ["-c:v", "libx264", "-crf", "18", "-preset", "fast"]
    static let x265 = ["-c:v", "libx265", "-crf", "20", "-preset", "fast", "-tag:v", "hvc1", "-x265-params", "log-level=error"]

    func testVideo_h264_longGOP_element_seekAccuracy() async throws { try await probeClip("h264-gop250", vcodec: Self.x264, gop: 250, mode: .element) }
    func testVideo_h264_intraOnly_element_seekAccuracy() async throws { try await probeClip("h264-intra", vcodec: Self.x264, gop: 1, mode: .element) }
    /// NAMED CORE GAP "element-hevc-open-gop": ffmpeg's x265 writes an open GOP; the 4 leading pictures (RASL) before each CRA
    /// (frames 56-59, 116-119) are not decodable after a seek — `<video>` keeps showing the previous frame, and AVAssetImageGenerator
    /// reports "Cannot Decode -11821" for the same frames. `.extract` handles them (AVAssetReader fallback) and is the supported path for
    /// HEVC. STRICT expected failure: the test fails as soon as the element path gets these frames right, so the marker cannot rot.
    func testVideo_hevc_element_seekAccuracy() async throws {
        try await probeClip("hevc-gop60", vcodec: Self.x265, gop: 60, mode: .element,
                            knownGap: "element-hevc-open-gop: <video> cannot show open-GOP leading pictures after a seek (use VideoMode.extract)")
    }
    func testVideo_h264_longGOP_extract_seekAccuracy() async throws { try await probeClip("h264-gop250", vcodec: Self.x264, gop: 250, mode: .extract) }
    func testVideo_h264_intraOnly_extract_seekAccuracy() async throws { try await probeClip("h264-intra", vcodec: Self.x264, gop: 1, mode: .extract) }
    func testVideo_hevc_extract_seekAccuracy() async throws { try await probeClip("hevc-gop60", vcodec: Self.x265, gop: 60, mode: .extract) }

    /// Without a window the <video> never leaves networkState NO_SOURCE (nothing loads). Documents why the hook needs a window.
    func testVideo_withoutWindow_neverLoads_documented() async throws {
        try Probe.requireHeavy()
        let clip = try makeClip("h264-gop250", vcodec: ["-c:v", "libx264", "-crf", "18", "-preset", "fast"], gop: 250)
        let page = try await Page(config: PageConfig(width: 640, height: 360, deterministicClock: true))
        try await page.load(.fileURL(try Probe.siteURL("video.html"), readAccess: Probe.scratch))
        try await page.evaluate("v.src = src; v.load(); return true", arguments: ["src": "../probe-clips/\(clip.lastPathComponent)"], timeout: 10)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let state = try await page.evaluate("return JSON.stringify({rs: v.readyState, ns: v.networkState, cur: v.currentSrc})", timeout: 10) as? String ?? "?"
        Probe.log("video without NSWindow: \(state) (networkState 3 = NO_SOURCE, readyState 0 = nothing loaded)")
        XCTAssertTrue(state.contains("\"rs\":0"), "unexpected: video loaded without a window (\(state)) — core may not need a window after all")
    }

    /// The VirtualClock hook path (core built-in hook): page.seek() must leave the video on the expected frame, same standard as the
    /// accuracy probes — in both core modes, mid-frame AND exact-boundary targets.
    func testVideo_clockHook_seekDrivesVideo() async throws {
        try Probe.requireHeavy()
        let clip = try makeClip("h264-gop250", vcodec: Self.x264, gop: 250)
        for mode in [VideoMode.element, .extract] {
            let page = try await videoPage(clip, mode: mode); defer { page.close() }
            _ = try await measure(page, offset: 0.5, order: [100], saveTag: nil)    // warm-up at an unrelated frame
            let targets = [0, 7, 29, 30, 31, 100, 149, 3]
            for offset in [0.5, 0.0] {
                var got: [Int] = []
                for n in targets {
                    try await page.seek((Double(n) + offset) / Double(Self.fps))
                    got.append(decodeFrameNumber(try await page.snapshot()))
                }
                Probe.log("video clock-hook .\(mode) offset \(offset) frames=\(got) expected=\(targets)")
                XCTAssertEqual(got, targets, "\(mode): hook-driven page.seek() (+\(offset) frame) must land on the expected frames")
            }
        }
    }

    // MARK: Probe 3 — HEVC with alpha

    func testHEVCAlpha_writeThenDecode_hasAlphaChannel() async throws {
        try FileManager.default.createDirectory(at: Probe.evidence, withIntermediateDirectories: true)
        let url = Probe.evidence.appendingPathComponent("hevc-alpha.mov")
        try? FileManager.default.removeItem(at: url)
        let page = try await Page(config: PageConfig(width: 320, height: 240, transparent: true, deterministicClock: true))
        try await page.load(.html("<style>html,body{margin:0;background:transparent}div{position:absolute;left:80px;top:60px;width:160px;height:120px;background:rgba(255,0,0,.5)}</style><div></div>"))
        let sink = try AVAssetWriterSink(url: url, width: 320, height: 240, fps: 30, codec: .hevcAlpha, quality: 0.8)
        do {
            for i in 0..<10 { try await page.seek(Double(i) / 30); try await sink.append(try await page.snapshot()) }
            try await sink.finish()
        } catch {
            try? await sink.finish()                       // no cancel() on the sink: close the writer, then drop the partial file
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first, "no video track")
        let descs = try await track.load(.formatDescriptions)
        let fd = try XCTUnwrap(descs.first, "no format description")
        let codec = CMFormatDescriptionGetMediaSubType(fd)
        let fourCC = String(format: "%c%c%c%c", (codec >> 24) & 255, (codec >> 16) & 255, (codec >> 8) & 255, codec & 255)
        let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any]
        let containsAlpha = (ext?[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? Bool) ?? false
        let hasChar = track.hasMediaCharacteristic(.containsAlphaChannel)
        let f = try await readBackFrame(url, index: 5)
        func px(_ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) { let o = (y * f.w + x) * 4; return (f.bgra[o], f.bgra[o + 1], f.bgra[o + 2], f.bgra[o + 3]) }
        let corner = px(2, 2), centre = px(160, 120)
        Probe.log("hevc-alpha fourCC='\(fourCC)' containsAlphaChannel(ext)=\(containsAlpha) trackCharacteristic=\(hasChar) corner BGRA=\(corner) centre BGRA=\(centre)")
        XCTAssertEqual(fourCC, "hvc1", "output must be HEVC (hvc1), not another codec")
        XCTAssertTrue(containsAlpha, "format description must advertise ContainsAlphaChannel")
        XCTAssertTrue(hasChar, "track must carry the containsAlphaChannel characteristic")
        XCTAssertLessThanOrEqual(corner.a, 4, "transparent corner must decode with alpha ~0 (lossy alpha plane)")
        XCTAssertEqual(Int(centre.a), 128, accuracy: 6, "50% red box must decode with alpha ~128")
        XCTAssertGreaterThan(centre.r, 100, "premultiplied red must survive")
    }
}
