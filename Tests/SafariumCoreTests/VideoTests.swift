import XCTest
import AppKit
import AVFoundation
import SafariumCore

/// `<video>` support: `.element` (hidden off-screen window + canvas copy) and `.extract` (native AVAssetImageGenerator frames).
/// Clips are generated here with the core's own writer (no ffmpeg, no network): frame N is burned in as 16 black/white blocks.
@MainActor
final class VideoTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare() }

    static let fps = 30, frames = 90, w = 320, h = 180

    static func numberedFrame(_ n: Int) -> Snapshot {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(gray: 0.5, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        for i in 0..<16 {            // CG origin is bottom-left: top row of the image = y near h
            ctx.setFillColor(gray: (n >> i) & 1 == 1 ? 1 : 0, alpha: 1)
            ctx.fill(CGRect(x: 20 * i, y: h - 20, width: 20, height: 20))
        }
        return Snapshot(cgImage: ctx.makeImage()!)
    }

    /// Writes clip + a page that references it; returns the page URL and the directory to grant read access to.
    func makeClipAndHTML(_ codec: VideoCodec, in dir: URL, videoAttrs: String = "muted playsinline preload=\"auto\"") async throws -> URL {
        let clip = dir.appendingPathComponent("clip.mp4")
        let sink = try AVAssetWriterSink(url: clip, width: Self.w, height: Self.h, fps: Self.fps, codec: codec, quality: codec == .hevc ? 0.9 : nil)
        for n in 0..<Self.frames { try await sink.append(Self.numberedFrame(n)) }
        try await sink.finish()
        let html = dir.appendingPathComponent("page.html")
        try """
            <!doctype html><meta charset="utf-8"><style>html,body{margin:0;background:#fff;overflow:hidden}
            video{position:absolute;left:0;top:0;width:\(Self.w)px;height:\(Self.h)px}</style>
            <video id="v" \(videoAttrs) src="clip.mp4"></video>
            """.write(to: html, atomically: true, encoding: .utf8)
        return html
    }

    func decodeFrameNumber(_ s: Snapshot) -> Int {
        var n = 0
        for i in 0..<16 { if s.pixel(x: 10 + 20 * i, y: 10).g > 128 { n |= (1 << i) } }
        return n
    }

    func videoPage(_ mode: VideoMode, _ codec: VideoCodec, dir: URL, videoAttrs: String = "muted playsinline preload=\"auto\"") async throws -> Page {
        let html = try await makeClipAndHTML(codec, in: dir, videoAttrs: videoAttrs)
        let page = try await Page(config: PageConfig(width: Self.w, height: Self.h, deterministicClock: true, video: mode))
        try await page.load(.fileURL(html, readAccess: dir))
        return page
    }

    /// Seeks to every target time and returns the (expected, got) mismatches.
    func mismatches(_ page: Page, order: [Int], offset: Double) async throws -> [String] {
        var bad: [String] = []
        for n in order {
            try await page.seek((Double(n) + offset) / Double(Self.fps))
            let got = decodeFrameNumber(try await page.snapshot())
            if got != n { bad.append("t=(\(n)+\(offset))/\(Self.fps) → frame \(got)") }
        }
        return bad
    }

    static func shuffled(_ count: Int, seed: UInt64 = 7) -> [Int] {
        var s = seed, out: [Int] = []
        while out.count < count {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            let n = Int((s >> 33) % UInt64(frames)); if n != out.last { out.append(n) }
        }
        return out
    }

    private func check(_ mode: VideoMode, _ codec: VideoCodec) async throws {
        let dir = try makeTempDir("video"); defer { try? FileManager.default.removeItem(at: dir) }
        let page = try await videoPage(mode, codec, dir: dir); defer { page.close() }
        let seq = Array(0..<45), rnd = Self.shuffled(40)
        let a = try await mismatches(page, order: seq, offset: 0.5)
        let b = try await mismatches(page, order: rnd, offset: 0.5)
        let c = try await mismatches(page, order: seq, offset: 0)       // t = n/fps exactly: must NOT land on n-1
        let d = try await mismatches(page, order: rnd, offset: 0)
        let bad = a + b + c + d
        XCTAssertTrue(bad.isEmpty, "\(mode) \(codec): \(bad.count) of \(2 * (seq.count + rnd.count)) seeks showed the wrong frame, e.g. \(bad.prefix(4))")
    }

    func testExtract_h264_frameExact() async throws { try await check(.extract, .h264) }
    func testExtract_hevc_frameExact() async throws { try await check(.extract, .hevc) }
    func testElement_h264_frameExact() async throws { try await check(.element, .h264) }

    func testExtract_needsNoWindow_elementUsesHiddenWindowThatIsNeverFront() async throws {
        let dir = try makeTempDir("video"); defer { try? FileManager.default.removeItem(at: dir) }
        let ext = try await videoPage(.extract, .h264, dir: dir); defer { ext.close() }
        XCTAssertNil(ext.webView.window, "extract mode must not create a window")
        let el = try await videoPage(.element, .h264, dir: dir)
        let win = try XCTUnwrap(el.webView.window, "element mode needs a window for media to load")
        XCTAssertTrue(win.styleMask == .borderless)
        XCTAssertFalse(win.isKeyWindow); XCTAssertFalse(win.isMainWindow)
        XCTAssertLessThan(win.frame.maxX, -1000, "window must be far off-screen")
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .prohibited)
        XCTAssertFalse(NSApplication.shared.isActive)
        el.close()
        XCTAssertNil(el.webView.window, "close() must detach the window")
        XCTAssertFalse(win.isVisible)
    }

    /// A plain `<video src>` (no preload attribute, default `metadata`) must still load and seek in element mode.
    func testElement_plainVideoTag_withoutPreload_loadsAndSeeks() async throws {
        let dir = try makeTempDir("video"); defer { try? FileManager.default.removeItem(at: dir) }
        let page = try await videoPage(.element, .h264, dir: dir, videoAttrs: ""); defer { page.close() }
        let bad = try await mismatches(page, order: [5, 40, 12, 80], offset: 0.5)
        XCTAssertTrue(bad.isEmpty, "\(bad)")
    }

    func testExtract_unreadableSource_failsLoudly() async throws {
        let page = try await Page(config: PageConfig(width: 100, height: 100, deterministicClock: true, video: .extract))
        defer { page.close() }
        try await page.load(.html("<video id=v src='file:///nonexistent/none.mp4'></video>"))
        do { try await page.seek(0.5); XCTFail("seek must throw for an unreadable video") }
        catch SafariumError.javascript(let m) { XCTAssertTrue(m.contains("video"), m) }
    }

    func testVideoModeNone_leavesVideosAlone() async throws {
        let page = try await Page(config: PageConfig(width: 100, height: 100, deterministicClock: true))
        try await page.load(.html("<video id=v src='file:///nonexistent/none.mp4'></video>"))
        try await page.seek(0.5)
        let n = try await page.evaluate("return document.querySelectorAll('canvas').length") as? Int
        XCTAssertEqual(n, 0)
    }
}
