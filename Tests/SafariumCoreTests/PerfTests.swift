import XCTest
import AVFoundation
import SafariumCore

@MainActor
final class PerfTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare() }

    /// 1080x1920 H.264, 90 frames: seek + snapshot + convert + encode, average ms/frame.
    func testH264_1080x1920_90frames_under10msPerFrame() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SAFARIUM_PERF"] == "1",
                          "perf test is opt-in: run with SAFARIUM_PERF=1 on a quiet machine")
        let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let page = try await Page(config: PageConfig(width: 1080, height: 1920, deterministicClock: true))
        try await page.load(.fileURL(Fixtures.url("clock.html")))
        let sink = try AVAssetWriterSink(url: dir.appendingPathComponent("p.mp4"), width: 1080, height: 1920, fps: 30,
                                         codec: .h264, bitrate: 20_000_000)
        for i in 0..<10 { try await page.seek(Double(i) / 30); _ = try await page.snapshot() } // warm-up
        var tSeek = 0.0, tSnap = 0.0, tEnc = 0.0
        let t0 = CFAbsoluteTimeGetCurrent()
        for i in 0..<90 {
            var a = CFAbsoluteTimeGetCurrent()
            try await page.seek(Double(i) / 30); tSeek += CFAbsoluteTimeGetCurrent() - a
            a = CFAbsoluteTimeGetCurrent()
            let s = try await page.snapshot(); tSnap += CFAbsoluteTimeGetCurrent() - a
            a = CFAbsoluteTimeGetCurrent()
            try await sink.append(s); tEnc += CFAbsoluteTimeGetCurrent() - a
        }
        let fa = CFAbsoluteTimeGetCurrent()
        try await sink.finish()
        let tFin = CFAbsoluteTimeGetCurrent() - fa
        let total = (CFAbsoluteTimeGetCurrent() - t0) * 1000 / 90
        print(String(format: "PERF h264 1080x1920: total %.2f ms/frame (seek %.2f, snapshot %.2f, convert+encode %.2f) finish %.0f ms",
                     total, tSeek * 1000 / 90, tSnap * 1000 / 90, tEnc * 1000 / 90, tFin * 1000))
        XCTAssertLessThanOrEqual(total, 10.0, "avg ms/frame incl. seek+snapshot+encode")
    }
}
