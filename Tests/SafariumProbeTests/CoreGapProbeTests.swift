import XCTest
import SafariumCore

/// Gaps in the core found while probing. Fixed in core (continuation-based timeout); kept here as a plain strict assertion.
@MainActor
final class CoreGapProbeTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare() }

    /// `Page.evaluate(timeout:)` must throw `.timeout` when the page's promise never settles. Observed: it never returns
    /// (withTimeout's task group waits for the callAsyncJavaScript child, which cannot be cancelled), so a render loop hangs forever.
    func testEvaluate_timeout_boundsNeverSettlingPromise() async throws {
        let page = try await Page(config: PageConfig(width: 100, height: 100))
        try await page.load(.html("<p>x</p>"))
        let box = ResultBox()
        let task = Task { @MainActor in
            do { _ = try await page.evaluate("await new Promise(() => {}); return 1", timeout: 1.0); box.set("returned") }
            catch let e as SafariumError { box.set(e == .timeout("evaluate") ? "timeout" : "other: \(e)") }
            catch { box.set("other: \(error)") }
        }
        let deadline = Date().addingTimeInterval(6)
        while box.value == nil && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        let outcome = box.value ?? "HUNG (no result 5 s after the 1 s timeout)"
        Probe.log("core gap: evaluate(timeout: 1) on a never-settling promise → \(outcome)")
        task.cancel()
        XCTAssertEqual(outcome, "timeout")
    }
}

final class ResultBox: @unchecked Sendable {
    private let l = NSLock(); private var v: String?
    var value: String? { l.lock(); defer { l.unlock() }; return v }
    func set(_ s: String) { l.lock(); v = s; l.unlock() }
}
