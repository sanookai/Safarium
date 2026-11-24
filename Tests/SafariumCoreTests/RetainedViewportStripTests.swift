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
        let repoFixture = root.appendingPathComponent("bench/experiments/render-standard/pixels/live/edge.html")
        var tempFixtureURL: URL?
        let fixtureURL: URL
        if FileManager.default.fileExists(atPath: repoFixture.path) {
            fixtureURL = repoFixture
        } else {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("safarium-edge-\(UUID().uuidString).html")
            let html = """
            <!doctype html><meta charset="utf-8"><title>Opaque damage, then a single late off-rect pixel</title>
            <style>
            html,body { margin:0; width:100%; height:100%; overflow:hidden; background:#204063 }
            .band { position:absolute; left:0; right:0; height:9px; background:#8d6140 }
            #mark { position:absolute; width:19px; height:17px; background:#efbe41 }
            #edge { position:absolute; right:0; bottom:0; width:1px; height:1px; background:#000 }
            </style>
            <div class="band" style="top:61px"></div><div class="band" style="top:127px"></div>
            <div id="mark"></div><div id="edge"></div>
            <script>
            window.__seek = seconds => {
              const i = Math.round(seconds * 30);
              const mark = document.getElementById('mark');
              mark.style.left = (37 + 12 * (i % 6)) + 'px';
              mark.style.top = (63 + 16 * (i % 5)) + 'px';
              document.getElementById('edge').style.background = i >= 4 ? '#0000ff' : '#000000';
            };
            window.__seek(0);
            </script>
            """
            try html.write(to: tmp, atomically: true, encoding: .utf8)
            tempFixtureURL = tmp
            fixtureURL = tmp
        }
        defer {
            if let tempFixtureURL {
                try? FileManager.default.removeItem(at: tempFixtureURL)
            }
        }
        try await page.load(.fileURL(fixtureURL))
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
