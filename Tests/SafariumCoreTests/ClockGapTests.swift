import XCTest
import SafariumCore

/// Regression tests for core gaps found by the P1-F probes (docs/probe-results.md).
@MainActor
final class ClockGapTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare() }

    /// Gap 1: evaluate(timeout:) must throw `.timeout` for a JS promise that never settles (it used to hang forever).
    func testEvaluateTimeoutBoundsNeverSettlingPromise() async throws {
        let page = try await Page(config: PageConfig(width: 100, height: 100))
        try await page.load(.html("<p>x</p>"))
        let box = OutcomeBox()
        let task = Task { @MainActor in
            do { _ = try await page.evaluate("await new Promise(() => {}); return 1", timeout: 1.0); box.set("returned") }
            catch let e as SafariumError { box.set(e == .timeout("evaluate") ? "timeout" : "other: \(e)") }
            catch { box.set("other: \(error)") }
        }
        let deadline = Date().addingTimeInterval(6)
        while box.value == nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        task.cancel()
        XCTAssertEqual(box.value ?? "HUNG (no result 5 s after the 1 s timeout)", "timeout")
        // the page must stay usable afterwards
        let v = try await page.evaluate("return 1 + 1") as? Int
        XCTAssertEqual(v, 2)
    }

    /// Gap 2: a ticker that only dispatches after >= 1/240 s (GSAP) must have rendered at exactly seek(0).
    func testLazyTicker_rendersAtExactlyT0() async throws {
        let page = try await Page(config: PageConfig(width: 200, height: 200, deterministicClock: true))
        try await page.load(.html("""
            <body><script>
            // GSAP-like: first dispatch needs elapsed >= 1/240 s, then renders from the ticker's own time
            let last = performance.now(), time = 0; window.rendered = -1;
            function tick() { const n = performance.now(), dt = n - last;
              if (dt >= 1000 / 240) { last = n; time += dt; window.rendered = time; }
              requestAnimationFrame(tick); }
            requestAnimationFrame(tick);
            </script></body>
            """))
        try await page.seek(0)
        let r = try await page.evaluate("return window.rendered") as? Double
        XCTAssertNotNil(r); XCTAssertGreaterThanOrEqual(r ?? -1, 0, "ticker must have rendered once at seek(0)")
        // virtual time itself stays where the caller put it
        let now = try await page.evaluate("return performance.now()") as? Double
        XCTAssertEqual(now, 0)
    }

    /// Gap 3: timers due at 0 must have run once load() returns (no seek needed).
    func testTimersDueAtZero_runAfterLoad() async throws {
        let page = try await Page(config: PageConfig(width: 100, height: 100, deterministicClock: true))
        try await page.load(.html("<body><script>window.log=[]; setTimeout(()=>{log.push('a'); setTimeout(()=>log.push('chained'),0)},0); setTimeout(()=>log.push('late'),5)</script></body>"))
        let log = try await page.evaluate("return log") as? [String]
        XCTAssertEqual(log, ["a", "chained"], "due-at-0 timers (and ones they chain at 0) run after load; timers due later do not")
        try await page.waitFor(.predicate("log.length >= 2"), timeout: 2)
    }
}

final class OutcomeBox: @unchecked Sendable {
    private let l = NSLock(); private var v: String?
    var value: String? { l.lock(); defer { l.unlock() }; return v }
    func set(_ s: String) { l.lock(); v = s; l.unlock() }
}
