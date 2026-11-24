@testable import SafariumCore
import XCTest

@MainActor
final class PageLoadErrorTests: XCTestCase {
    /// A failed navigation must surface as `SafariumError.navigation`, never be replaced by the
    /// watchdog's / timeout helper's `CancellationError`.
    func testMissingFileLoadThrowsNavigationErrorNotCancellation() async throws {
        let page = try await Page(config: PageConfig(width: 64, height: 64, deterministicClock: true)) {
            $0.websiteDataStore = .nonPersistent()
        }
        defer { page.close() }
        // Same shape as the RetainedViewport tests: the directory exists, the file does not.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let missing = root.appendingPathComponent("bench/experiments/render-standard/pixels/live/missing-\(UUID().uuidString).html")
        do {
            try await page.load(.fileURL(missing))
            XCTFail("loading a missing file must throw")
        } catch SafariumError.navigation {
            // expected
        } catch {
            XCTFail("expected SafariumError.navigation, got \(error)")
        }
    }
}

@MainActor
final class SleepWithoutThrowingTests: XCTestCase {
    func testElapsedReturnsTrue() async {
        let ok = await sleepWithoutThrowing(nanoseconds: 20_000_000)
        XCTAssertTrue(ok)
    }

    func testCancellationReturnsFalseQuicklyWithoutThrowing() async {
        let t = Task { await sleepWithoutThrowing(nanoseconds: 30_000_000_000) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let start = Date()
        t.cancel()
        let ok = await t.value
        XCTAssertFalse(ok)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testAlreadyCancelledReturnsFalse() async {
        let t = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            return await sleepWithoutThrowing(nanoseconds: 30_000_000_000)
        }
        t.cancel()
        let ok = await t.value
        XCTAssertFalse(ok)
    }
}
