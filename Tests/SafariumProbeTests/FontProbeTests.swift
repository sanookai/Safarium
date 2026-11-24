import XCTest
import SafariumCore

/// Probe 7: webfonts from local files (Inter + Noto Sans Thai); `waitFor(.fonts)` must be enough — no fallback-glyph frames.
@MainActor
final class FontProbeTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare(); try Probe.requireLibs() }

    private func render(_ fixture: String, clock: Bool, extraWaitMs: Int = 0, waitFonts: Bool = true) async throws -> (hash: String, snap: Snapshot, status: String) {
        let url = try Probe.siteURL(fixture)
        let page = try await Page(config: PageConfig(width: 900, height: 450, deterministicClock: clock))
        try await page.load(.fileURL(url, readAccess: Probe.scratch))
        if waitFonts { try await page.waitFor(.fonts) }
        if extraWaitMs > 0 { try await Task.sleep(nanoseconds: UInt64(extraWaitMs) * 1_000_000) }
        let status = try await page.evaluate("return Array.from(document.fonts).map(f => f.family + ':' + f.weight + ':' + f.status).join(',')") as? String ?? ""
        let s = try await page.snapshot()
        return (Probe.hash(s), s, status)
    }

    /// Ground truth: fonts explicitly loaded (document.fonts.load per face) and the page left to settle for 1 s.
    private func reference(clock: Bool) async throws -> (hash: String, snap: Snapshot) {
        let url = try Probe.siteURL("fonts.html")
        let page = try await Page(config: PageConfig(width: 900, height: 450, deterministicClock: clock))
        try await page.load(.fileURL(url, readAccess: Probe.scratch))
        try await page.evaluate("""
            await Promise.all(['400 48px ProbeInter','700 48px ProbeInter','400 48px ProbeThai','700 48px ProbeThai'].map(f => document.fonts.load(f, 'Aก')));
            return true
            """)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let s = try await page.snapshot()
        return (Probe.hash(s), s)
    }

    func testFonts_waitForFonts_matchesFullyLoadedReference_noFallbackFrames() async throws {
        let ref = try await reference(clock: true)
        Probe.save(ref.snap, "fonts-reference")
        let fallback = try await render("fonts-fallback.html", clock: true)
        Probe.save(fallback.snap, "fonts-fallback-sample")
        XCTAssertNotEqual(ref.hash, fallback.hash, "sanity: a fallback render must differ from the real-font render")
        var mismatches = 0, statuses = Set<String>()
        let trials = ProcessInfo.processInfo.environment["SAFARIUM_PROBES"] == "1" ? 12 : 2   // default run stays fast
        for i in 0..<trials {
            let r = try await render("fonts.html", clock: i % 2 == 0)   // alternate with / without VirtualClock
            statuses.insert(r.status)
            let refHash = i % 2 == 0 ? ref.hash : try await reference(clock: false).hash
            if r.hash != refHash { mismatches += 1; Probe.save(r.snap, "fonts-mismatch-\(i)") }
        }
        Probe.log("fonts: \(trials) fresh loads, waitFor(.fonts) only → mismatches vs loaded-reference=\(mismatches); fontface status=\(statuses)")
        XCTAssertEqual(mismatches, 0, "frames rendered with fallback glyphs after waitFor(.fonts)")
    }

    /// Without any wait the first frame may use fallback fonts — this documents why waitFor(.fonts) is mandatory.
    func testFonts_noWait_isRacy_documented() async throws {
        try Probe.requireHeavy()
        let ref = try await reference(clock: true)
        var bad = 0
        for _ in 0..<5 { if try await render("fonts.html", clock: true, waitFonts: false).hash != ref.hash { bad += 1 } }
        Probe.log("fonts: WITHOUT waitFor(.fonts): \(bad)/5 first frames differ from the loaded reference")
    }
}
