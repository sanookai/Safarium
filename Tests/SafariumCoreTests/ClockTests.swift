import XCTest
import SafariumCore

@MainActor
final class ClockTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare() }

    private func tx(_ page: Page, _ id: String) async throws -> Double {
        let v = try await page.evaluate(
            "return new DOMMatrix(getComputedStyle(document.getElementById(id)).transform).m41", arguments: ["id": id])
        return (v as? NSNumber)?.doubleValue ?? .nan
    }

    private func loadClockPage() async throws -> Page {
        let page = try await Page(config: PageConfig(width: 1080, height: 1920, deterministicClock: true))
        try await page.load(.fileURL(Fixtures.url("clock.html")))
        return page
    }

    func testAllTimeSourcesLandAtExpectedPositionAt1_5s() async throws {
        let page = try await loadClockPage()
        try await page.seek(1.5, step: 1.0 / 30)
        let acc = 0.5
        let css = try await tx(page, "css"), waapi = try await tx(page, "waapi"), raf = try await tx(page, "raf")
        let tmo = try await tx(page, "tmo"), tick = try await tx(page, "tick"), late = try await tx(page, "late")
        XCTAssertEqual(css, 300, accuracy: acc, "CSS animation")
        XCTAssertEqual(waapi, 600, accuracy: acc, "WAAPI")
        XCTAssertEqual(raf, 600, accuracy: acc, "rAF")
        XCTAssertEqual(tmo, 500, accuracy: acc, "setTimeout (1000 fired, 2000 not)")
        XCTAssertEqual(tick, 600, accuracy: acc, "GSAP-like ticker")
        XCTAssertEqual(late, 250, accuracy: acc, "timer chained from a timer callback")
        let intervals = try await page.evaluate("return log.intervals") as? Int
        XCTAssertEqual(intervals, 3, "setInterval 500ms fired at 500/1000/1500")
        let timeouts = try await page.evaluate("return log.timeouts") as? [Int]
        XCTAssertEqual(timeouts, [1000], "cleared timeout must not fire; 2000 not yet")
        let dt = try await page.evaluate("return [Date.now()-log.dateStart, performance.now()-log.perfStart, new Date().getTime()-log.dateStart]") as? [Double]
        XCTAssertEqual(dt, [1500, 1500, 1500])
        let micro = try await page.evaluate("return log.micro") as? Int
        XCTAssertEqual(micro, 1, "queueMicrotask untouched")
    }

    func testSingleJumpSeekWithoutStepping() async throws {
        let page = try await loadClockPage()
        try await page.seek(1.5)   // one big jump: animations/rAF/timers still correct (ticker lag-smoothing excluded)
        let css = try await tx(page, "css"), waapi = try await tx(page, "waapi")
        let raf = try await tx(page, "raf"), tmo = try await tx(page, "tmo")
        XCTAssertEqual(css, 300, accuracy: 0.5)
        XCTAssertEqual(waapi, 600, accuracy: 0.5)
        XCTAssertEqual(raf, 600, accuracy: 0.5)
        XCTAssertEqual(tmo, 500, accuracy: 0.5)
    }

    func testPageDefinedSeekHooksAreCalled() async throws {
        let page = try await Page(config: PageConfig(width: 200, height: 200, deterministicClock: true))
        try await page.load(.html("<body><script>window.calls=[];window.__seek=t=>{calls.push(['seek',t])};window.__hf={seek:async t=>{calls.push(['hf',t])}}</script></body>"))
        try await page.seek(0.25)
        let calls = try await page.evaluate("return JSON.stringify(calls)") as? String
        XCTAssertEqual(calls, "[[\"seek\",0.25],[\"hf\",0.25]]")
    }

    func testClockIsInstalledInFrames_andOffByDefault() async throws {
        let page = try await Page(config: PageConfig(width: 200, height: 200)) // no virtual clock
        try await page.load(.html("<body></body>"))
        let has = try await page.evaluate("return typeof window.__sfClock") as? String
        XCTAssertEqual(has, "undefined")
        do { try await page.seek(1); XCTFail("seek without clock must throw") } catch SafariumError.invalidState { }
    }

    func testDeterminism_threeRunsIdenticalFrameHashes() async throws {
        var runs: [[String]] = []
        var rollingHashes: [String] = []
        for _ in 0..<3 {
            let page = try await loadClockPage()
            var hashes: [String] = []
            var concatData = Data()
            for i in 0..<60 {
                try await page.seek(Double(i) / 30)
                let frameHash = sha256Hex(try await page.snapshot().bgra())
                hashes.append(frameHash)
                concatData.append(Data((frameHash + "\n").utf8))
            }
            runs.append(hashes)
            rollingHashes.append(sha256Hex(concatData))
        }
        XCTAssertEqual(runs[0].count, 60)
        XCTAssertEqual(runs[0], runs[1])
        XCTAssertEqual(runs[1], runs[2])
        XCTAssertEqual(rollingHashes[0], rollingHashes[1])
        XCTAssertEqual(rollingHashes[1], rollingHashes[2])
        XCTAssertGreaterThan(Set(runs[0]).count, 4, "animated frames across 60 steps must vary")
    }
}
