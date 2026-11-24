import XCTest
import AVFoundation
import SafariumCore

@MainActor
final class CoreTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare() }

    func testSnapshotExactSize1080x1920() async throws {
        let page = try await Page(config: PageConfig(width: 1080, height: 1920))
        try await page.load(.fileURL(Fixtures.url("basic.html")))
        let s = try await page.snapshot()
        XCTAssertEqual(s.width, 1080); XCTAssertEqual(s.height, 1920)
        XCTAssertEqual(s.bgra().count, 1080 * 1920 * 4)
        XCTAssertFalse(s.pngData().isEmpty)
        XCTAssertFalse(s.jpegData(quality: 0.9).isEmpty)
    }

    func testOddSizeAndScale() async throws {
        let page = try await Page(config: PageConfig(width: 400, height: 300, scale: 2))
        try await page.load(.html("<body style='margin:0;background:#00f'>x</body>"))
        let s = try await page.snapshot()
        XCTAssertEqual(s.width, 800); XCTAssertEqual(s.height, 600)
        let p = s.pixel(x: 10, y: 10)
        XCTAssertEqual(p.b, 255); XCTAssertEqual(p.a, 255)
    }

    func testH264FileHasExactSize() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let page = try await Page(config: PageConfig(width: 1080, height: 1920))
        try await page.load(.fileURL(Fixtures.url("basic.html")))
        let sink = try AVAssetWriterSink(url: dir.appendingPathComponent("o.mp4"), width: 1080, height: 1920, fps: 30, codec: .h264)
        for _ in 0..<5 { try await sink.append(try await page.snapshot()) }
        try await sink.finish()
        let t = try await AVURLAsset(url: dir.appendingPathComponent("o.mp4")).loadTracks(withMediaType: .video).first!
        let size = try await t.load(.naturalSize)
        XCTAssertEqual(Int(size.width), 1080); XCTAssertEqual(Int(size.height), 1920)
    }

    func testProRes4444KeepsAlpha() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let page = try await Page(config: PageConfig(width: 1080, height: 1920, transparent: true))
        try await page.load(.fileURL(Fixtures.url("basic.html")))
        let url = dir.appendingPathComponent("a.mov")
        let sink = try AVAssetWriterSink(url: url, width: 1080, height: 1920, fps: 30, codec: .proRes4444)
        for _ in 0..<3 { try await sink.append(try await page.snapshot()) }
        try await sink.finish()
        let f = try await readBackFrame(url, index: 1)
        XCTAssertEqual(f.w, 1080); XCTAssertEqual(f.h, 1920)
        XCTAssertEqual(Array(f.bgra[0..<4]), [0, 0, 0, 0], "pixel (0,0) must be fully transparent")
        // orange box at x 100..300, y 300..500 (CSS px = pixels at scale 1) must be opaque
        let o = (400 * 1080 + 200) * 4
        let src = try await page.snapshot().pixel(x: 200, y: 400)
        XCTAssertEqual(src.a, 255, "source snapshot is exactly opaque")
        // ProRes 4444 alpha is quantized by the codec (measured 254 for a source of 255); not a pipeline loss.
        XCTAssertGreaterThanOrEqual(f.bgra[o + 3], 254)
        XCTAssertGreaterThan(Int(f.bgra[o + 2]), 200) // red channel of #f80
    }

    func testThaiTextRendersGlyphPixels() async throws {
        let page = try await Page(config: PageConfig(width: 1080, height: 1920))
        try await page.load(.fileURL(Fixtures.url("opaque-thai.html")))
        try await page.waitFor(.fonts)
        let s = try await page.snapshot()
        var dark = 0
        for y in 900..<1010 { for x in 40..<1040 { if s.pixel(x: x, y: y).r < 100 { dark += 1 } } }
        XCTAssertGreaterThan(dark, 2000, "Thai glyph pixels expected in text region")
        // above the text must be empty white
        XCTAssertEqual(s.pixel(x: 500, y: 200).r, 255)
    }

    func testCharsetHandlingForFileWithoutMeta() async throws {
        let page = try await Page(config: PageConfig(width: 600, height: 400))
        try await page.load(.fileURL(Fixtures.url("nocharset-thai.html")))
        let txt = try await page.evaluate("return window.__txt") as? String
        XCTAssertEqual(txt, "สวัสดี")
    }

    func testHTMLStringWithThaiNoMeta() async throws {
        let page = try await Page(config: PageConfig(width: 600, height: 400))
        try await page.load(.html("<p id=p>สวัสดี</p>"))
        let txt = try await page.evaluate("return document.getElementById('p').textContent") as? String
        XCTAssertEqual(txt, "สวัสดี")
    }

    func testWebGL2CanvasNonEmpty() async throws {
        let page = try await Page(config: PageConfig(width: 540, height: 960))
        try await page.load(.fileURL(Fixtures.url("webgl2.html")))
        let ok = try await page.evaluate("return window.__gl") as? Bool
        XCTAssertEqual(ok, true, "WebGL2 context must be available")
        let s = try await page.snapshot()
        let p = s.pixel(x: 270, y: 480)
        XCTAssertGreaterThan(Int(p.r), 200); XCTAssertLessThan(Int(p.g), 50)
    }

    func testEvaluateWaitForAndTimeouts() async throws {
        let page = try await Page(config: PageConfig(width: 300, height: 300))
        try await page.load(.html("<body></body><script>setTimeout(()=>{window.ready=true},200)</script>"))
        try await page.waitFor(.predicate("window.ready === true"), timeout: 5)
        try await page.waitFor(.readyState)
        try await page.waitFor(.fonts)
        let n = try await page.evaluate("return a + b", arguments: ["a": 2, "b": 3]) as? Int
        XCTAssertEqual(n, 5)
        let v = try await page.evaluate(expression: "new Promise(r => setTimeout(() => r(42), 20))") as? Int
        XCTAssertEqual(v, 42)
        do { try await page.waitFor(.predicate("false"), timeout: 0.3); XCTFail("should time out") }
        catch SafariumError.timeout { }
        do { _ = try await page.evaluate("throw new Error('boom')"); XCTFail("should throw") }
        catch SafariumError.javascript(let m) { XCTAssertTrue(m.contains("boom"), m) }
    }

    func testImageSequenceSink() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let page = try await Page(config: PageConfig(width: 200, height: 100))
        try await page.load(.html("<body style='background:#0f0'></body>"))
        let sink = try ImageSequenceSink(directory: dir, format: .png)
        for _ in 0..<3 { try await sink.append(try await page.snapshot()) }
        try await sink.finish()
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(files, ["frame_00000.png", "frame_00001.png", "frame_00002.png"])
    }

    func testAllCodecsWriteFiles() async throws {
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let page = try await Page(config: PageConfig(width: 640, height: 360, transparent: true))
        try await page.load(.fileURL(Fixtures.url("basic.html")))
        for (codec, ext) in [(VideoCodec.h264, "mp4"), (.hevc, "mp4"), (.hevcAlpha, "mov"), (.proRes422, "mov"), (.proRes4444, "mov")] {
            let url = dir.appendingPathComponent("\(codec).\(ext)")
            let sink = try AVAssetWriterSink(url: url, width: 640, height: 360, fps: 30, codec: codec, bitrate: 4_000_000)
            for _ in 0..<4 { try await sink.append(try await page.snapshot()) }
            try await sink.finish()
            let d = try await AVURLAsset(url: url).load(.duration).seconds
            XCTAssertEqual(d, 4.0 / 30, accuracy: 0.01, "\(codec) duration")
        }
    }
}
