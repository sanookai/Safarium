import XCTest
import SafariumCore

/// Probe 1: real npm animation / graphics libraries driven by the VirtualClock.
/// Every fixture shows a 100x100 box whose left edge must be at x = 100 + 200*t (t in seconds) on a white page.
@MainActor
final class LibraryProbeTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare(); try Probe.requireLibs() }

    struct Run { var xs: [Int]; var counts: [Int]; var hashes: [String] }

    private func run(_ fixture: String, tag: String, step: Double? = 1.0 / 30, times: [Double] = [0, 1.5, 3],
                     width: Int = 800, height: Int = 600, saveFrames: Bool = true) async throws -> Run {
        let url = try Probe.siteURL(fixture)
        let page = try await Page(config: PageConfig(width: width, height: height, deterministicClock: true))
        try await page.load(.fileURL(url, readAccess: Probe.scratch))
        try await page.waitFor(.predicate("window.__ready === true"))
        var r = Run(xs: [], counts: [], hashes: [])
        for t in times {
            try await page.seek(t, step: step)
            let s = try await page.snapshot()
            if saveFrames { Probe.save(s, "\(tag)-t\(t)") }
            guard let bb = Probe.bbox(s) else { XCTFail("\(tag) t=\(t): snapshot is empty (all white)"); r.xs.append(-1); r.counts.append(0); r.hashes.append("empty"); continue }
            r.xs.append(bb.minX); r.counts.append(bb.count); r.hashes.append(Probe.hash(s))
        }
        return r
    }

    private func check(_ fixture: String, tag: String, step: Double? = 1.0 / 30, tol: Int = 2, minPixels: Int = 8000,
                       times: [Double] = [0, 1.5, 3]) async throws {
        let a = try await run(fixture, tag: tag, step: step, times: times)
        let b = try await run(fixture, tag: tag + "-run2", step: step, times: times, saveFrames: false)
        let expected = times.map { 100 + Int((200 * $0).rounded()) }
        Probe.log("lib \(tag) left-edge x=\(a.xs) expected=\(expected) pixels=\(a.counts) hashesRun1=\(a.hashes) hashesRun2=\(b.hashes)")
        for (i, t) in times.enumerated() {
            XCTAssertLessThanOrEqual(abs(a.xs[i] - expected[i]), tol, "\(tag) t=\(t): x=\(a.xs[i]) expected \(expected[i])")
            XCTAssertGreaterThanOrEqual(a.counts[i], minPixels, "\(tag) t=\(t): too few non-background pixels (\(a.counts[i]))")
        }
        XCTAssertEqual(a.hashes, b.hashes, "\(tag): two runs must be bit-identical")
    }

    func testGSAP_pausedTimeline_seek() async throws { try await check("gsap-paused.html", tag: "gsap-paused") }
    func testGSAP_playingTicker_drivenByVirtualClock() async throws { try Probe.requireHeavy(); try await check("gsap-ticker.html", tag: "gsap-ticker", tol: 8, times: [0.1, 1.5, 3]) }

    /// GSAP's ticker only dispatches once >= 1/240 s has elapsed; the core clock pre-rolls one rAF round on the first seek,
    /// so a native-ticker tween must show its first frame at exactly t=0 (was a known gap, fixed in core).
    func testGSAP_playingTicker_firstFrameAtT0() async throws { try Probe.requireHeavy();
        let r = try await run("gsap-ticker.html", tag: "gsap-ticker-t0", times: [0], saveFrames: true)
        // Not 100: GSAP's own first tick applies its lag-smoothing adjustment (a ticker with no previous tick counts as 33 ms),
        // so a real browser also shows x = 100 + 600 px/3 s * 0.0333 s = 106.7 on the first frame. "Stuck at 0" or exactly 100
        // (nothing rendered / wrong time) must both fail.
        XCTAssertEqual(Double(r.xs[0]), 106.7, accuracy: 2)
    }
    func testAnimeJS_seek() async throws { try await check("anime.html", tag: "anime") }
    func testLottieWeb_svg_goToAndStop() async throws { try Probe.requireHeavy(); try await check("lottie.html", tag: "lottie") }
    func testPixiJS_webgl() async throws { try Probe.requireHeavy(); try await check("pixi.html", tag: "pixi") }
    func testThreeJS_webgl_lightsAndTexture() async throws { try Probe.requireHeavy(); try await check("three.html", tag: "three") }
}
