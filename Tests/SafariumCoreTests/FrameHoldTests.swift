import CoreMedia
import XCTest
import SafariumCore

@MainActor
final class FrameHoldTests: XCTestCase {
    func testBadDeclarationsDoNotBecomeHolds() throws {
        let decoder = JSONDecoder()
        for doc in [
            #"{"timescale":0,"holds":[]}"#,
            #"{"timescale":30,"holds":[{"start":-1,"end":1}]}"#,
            #"{"timescale":30,"holds":[{"start":2,"end":2}]}"#,
            #"{"timescale":30,"holds":[{"start":4,"end":2}]}"#,
            #"{"timescale":30,"holds":[{"start":2,"end":4},{"start":0,"end":1}]}"#,
            #"{"timescale":30,"holds":[{"start":0,"end":4},{"start":3,"end":5}]}"#,
            #"{"timescale":30,"holds":[{"start":0.5,"end":1}]}"#,
            #"{"timescale":30,"holds":[{"start":0,"end":"NaN"}]}"#,
            #"{"timescale":30,"holds":[{"start":NaN,"end":2}]}"#,
            #"{"timescale":30,"holds":[{"start":0,"end":9223372036854775808}]}"#,
            #"{"timescale":30}"#,
        ] {
            XCTAssertThrowsError(try decoder.decode(FrameHoldPlan.self, from: Data(doc.utf8)), doc)
        }
    }

    func testStartInsideAdjacentHoldsAndExitMatchFreshWebKitSnapshots() async throws {
        let html = """
        <meta charset=utf-8><script>
        window.visits = [];
        window.__seek = t => {
          const n = Math.round(t * 15);
          visits.push(n);
          const red = n < 10 ? 30 : n < 12 ? 90 : n * 6 + visits.length;
          document.documentElement.style.background = `rgb(${red},12,128)`;
        };
        </script>
        """
        let config = PageConfig(width: 64, height: 48, deterministicClock: true)
        let legacy = try await Page(config: config), page = try await Page(config: config)
        try await legacy.load(.html(html))
        try await page.load(.html(html))
        let plan = try FrameHoldPlan(timescale: 30, holds: [.init(start: 10, end: 20), .init(start: 20, end: 24)])
        var capture = FrameHoldCapture(page: page, plan: plan)
        var hashes: [String] = []
        var fresh: [Int] = []
        for n in 6...13 {  // enter the first hold after its start; use a different sample timescale
            let t = CMTime(value: Int64(n), timescale: 15)
            try await legacy.seek(t.seconds)
            try await page.seek(t.seconds)
            let oldCalls = capture.snapshotCalls
            let baseline = try await legacy.snapshot().bgra()
            let actual = try await capture.snapshot(afterSeekingTo: t).bgra()
            if oldCalls != capture.snapshotCalls { fresh.append(n) }
            XCTAssertEqual(sha256Hex(actual), sha256Hex(baseline), "absolute sample \(n)/15")
            hashes.append(sha256Hex(actual))
        }
        XCTAssertEqual(fresh, [6, 10, 12, 13])
        XCTAssertEqual(Set(hashes).count, 4, "adjacent hold and both dynamic frames are visibly different")
        XCTAssertEqual(capture.reusedFrames, 4)
        let visits = try await page.evaluate("return window.visits") as? [Int]
        XCTAssertEqual(visits, Array(6...13))
    }

    func testRoundedJSStartCannotSeedACacheWithAnOutsideImage() async throws {
        let page = try await Page(config: PageConfig(width: 48, height: 48, deterministicClock: true))
        try await page.load(.html("""
            <meta charset=utf-8><script>window.__seek = t => {
              document.documentElement.style.background = t < 0.3 ? 'black' : 'white';
            };</script>
            """))
        let plan = try FrameHoldPlan(timescale: 10, holds: [.init(start: 3, end: 8)])
        var capture = FrameHoldCapture(page: page, plan: plan)
        let start = CMTime(value: 3, timescale: 10)
        try await page.seek(start.seconds.nextDown)
        let before = try await capture.snapshot(afterSeekingTo: start, pageSeconds: start.seconds.nextDown)
        try await page.seek(0.4)
        let inside = try await capture.snapshot(afterSeekingTo: CMTime(value: 4, timescale: 10))
        XCTAssertNotEqual(sha256Hex(before.bgra()), sha256Hex(inside.bgra()))
        XCTAssertEqual(capture.snapshotCalls, 2)
        XCTAssertEqual(capture.reusedFrames, 0)
        for (time, seconds) in [(CMTime.indefinite, 0.0), (.zero, Double.nan)] {
            do {
                _ = try await capture.snapshot(afterSeekingTo: time, pageSeconds: seconds)
                XCTFail("invalid time should fail before capture")
            } catch SafariumError.invalidState { }
        }
        XCTAssertEqual(capture.snapshotCalls, 2)
    }

    func testPageHooksSeeMillisecondsRoundTripAtRationalBoundary() async throws {
        let page = try await Page(config: PageConfig(width: 48, height: 48, deterministicClock: true))
        try await page.load(.html("""
            <meta charset=utf-8><script>window.__seek = t => {
              window.hookTime = t;
              document.documentElement.style.background = t < 57 / 31 ? 'black' : 'white';
            };</script>
            """))
        let plan = try FrameHoldPlan(timescale: 31, holds: [.init(start: 57, end: 61)])
        var capture = FrameHoldCapture(page: page, plan: plan)
        for n in 57...59 {
            let t = CMTime(value: Int64(n), timescale: 31)
            try await page.seek(t.seconds)
            if n == 57 {
                let hookTime = try await page.evaluate("return window.hookTime") as? Double
                XCTAssertLessThan(try XCTUnwrap(hookTime), t.seconds, "clock stores milliseconds, calls hooks in seconds")
            }
            let actual = try await capture.snapshot(afterSeekingTo: t)
            let reference = try await page.snapshot()
            XCTAssertEqual(sha256Hex(actual.bgra()), sha256Hex(reference.bgra()), "absolute sample \(n)/31")
        }
        XCTAssertEqual(capture.snapshotCalls, 2)
        XCTAssertEqual(capture.reusedFrames, 1)
    }
}
