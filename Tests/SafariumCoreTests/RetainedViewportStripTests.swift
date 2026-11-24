import AppKit
import SafariumCore
import XCTest

@MainActor
final class RetainedViewportStripTests: XCTestCase {
    func testVerifiedPatchesFindLastPixelInTwoRowTailAndRebase() async throws {
        let page = try await Page(config: PageConfig(width: 258, height: 194, deterministicClock: true)) {
            $0.websiteDataStore = .nonPersistent()
        }
        defer { page.close() }
        XCTAssertNil(page.webView.window)
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .prohibited)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try await page.load(.fileURL(root.appendingPathComponent("bench/experiments/render-standard/pixels/live/edge.html")))
        let view = RetainedViewport(page: page)
        let damage = try RetainedViewport.Rect(x: 29, y: 59, width: 151, height: 111)
        var previous = Data()
        for i in 0..<4 {
            let frame = try await view.snapshot(at: Double(i) / 30, damage: damage)
            let expected = try await page.snapshot().checkedBGRA(), actual = try frame.checkedBGRA()
            XCTAssertEqual(actual, expected)
            XCTAssertNotEqual(actual, previous)
            previous = actual
        }
        do {
            _ = try await view.snapshot(at: 4.0 / 30, damage: damage)
            XCTFail("The late bottom-right pixel is outside the already verified rect")
        } catch SafariumError.snapshot(let reason) {
            XCTAssertEqual(reason, "retained pixels differ from full capture at x=257, y=193")
        }
        XCTAssertEqual(view.fullCaptures, 1)
        XCTAssertEqual(view.rectCaptures, 4)
        XCTAssertEqual(view.verificationCaptures, 4)
        let recovered = try await view.snapshot(at: 4.0 / 30, damage: damage)
        let independent = try await page.snapshot().checkedBGRA()
        XCTAssertEqual(try recovered.checkedBGRA(), independent)
        XCTAssertEqual(recovered.pixel(x: 257, y: 193).b, 255)
        XCTAssertEqual(view.fullCaptures, 2)
        XCTAssertEqual(view.rectCaptures, 4)
        XCTAssertNil(page.webView.window)
    }
}
