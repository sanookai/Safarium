import XCTest
import CoreVideo
import SafariumCore

@MainActor
final class RetainedViewportTests: XCTestCase {
    // Intentionally asymmetric: a reflected patch or a stale old position must be observable.
    private func makePage(gradient: Bool = false) async throws -> Page {
        let page = try await Page(config: PageConfig(width: 96, height: 72))
        let background = gradient ? "linear-gradient(#dba752,#14285d)" : "#cc8b63"
        let bands = gradient ? "" : "<i style='top:12px'></i><i style='top:51px'></i>"
        try await page.load(.html("""
            <!doctype html><style>
            html,body { margin:0; height:100%; background:\(background); }
            i { position:absolute; left:0; right:0; height:7px; background:#234568; }
            #dot { position:absolute; left:52px; top:42px; width:7px; height:6px; background:red; }
            </style>\(bands)<div id="dot"></div>
            """))
        return page
    }

    func testMovingPatchMatchesEveryByteAndPreservesIssuedFrames() async throws {
        let page = try await makePage()
        let r = RetainedViewport(page: page)
        // Odd dimensions, nonzero origin; last pixel is the bottom-right viewport pixel.
        let damage = try RetainedViewport.Rect(x: 51, y: 41, width: 45, height: 31)
        let first = try await r.snapshot(damage: damage)
        let firstBytes = first.bgra()
        try await page.evaluate("dot.style.left='89px'; dot.style.top='66px'; return true")
        let second: Snapshot
        do { second = try await r.snapshot(damage: damage) }
        catch { XCTFail("verified edge-touching patch: \(error)"); return }
        let secondBytes = second.bgra()
        XCTAssertEqual(second.pixel(x: 95, y: 71).r, 255)
        XCTAssertNotEqual(firstBytes, secondBytes)
        try await page.evaluate("dot.style.left='65px'; dot.style.top='49px'; return true")
        let third = try await r.snapshot(damage: damage)
        let independent = try await page.snapshot()
        XCTAssertEqual(independent.bgra(), third.bgra())
        XCTAssertNotEqual(secondBytes, third.bgra())
        XCTAssertEqual(first.bgra(), firstBytes)
        XCTAssertEqual(second.bgra(), secondBytes, "a previously returned patch result must not alias mutable pixels")
        XCTAssertEqual(r.fullCaptures, 1); XCTAssertEqual(r.rectCaptures, 2); XCTAssertEqual(r.verificationCaptures, 2)
    }

    func testVerifiedIncompleteDamageRejectsThenNextFrameStartsFull() async throws {
        let page = try await makePage()
        let r = RetainedViewport(page: page)
        let wrong = try RetainedViewport.Rect(x: 0, y: 0, width: 20, height: 16)
        _ = try await r.snapshot()
        _ = try await r.snapshot(damage: wrong) // first-patch check passes before motion
        try await page.evaluate("dot.style.background='lime'; return true")
        do { _ = try await r.snapshot(damage: wrong); XCTFail("undeclared motion must be rejected by default") }
        catch SafariumError.snapshot(let reason) { XCTAssertTrue(reason.contains("differ from full capture"), reason) }
        let recovered = try await r.snapshot(damage: wrong)
        XCTAssertEqual(recovered.pixel(x: 54, y: 44).g, 255)
        XCTAssertEqual(r.fullCaptures, 2); XCTAssertEqual(r.rectCaptures, 2); XCTAssertEqual(r.verificationCaptures, 2)
    }

    func testClipDependentPaintCannotSilentlyPassFirstPatch() async throws {
        let page = try await makePage(gradient: true)
        let r = RetainedViewport(page: page)
        let damage = try RetainedViewport.Rect(x: 51, y: 41, width: 45, height: 31)
        _ = try await r.snapshot(damage: damage)
        try await page.evaluate("dot.style.left='89px'; dot.style.top='66px'; return true")
        let reference = try await page.snapshot()
        do {
            // WebKit versions with position-independent gradient rasterization may pass.
            let frame = try await r.snapshot(damage: damage)
            XCTAssertEqual(frame.bgra(), reference.bgra())
        } catch SafariumError.snapshot(let reason) {
            XCTAssertTrue(reason.contains("differ from full capture"), reason)
            let full = try await r.snapshot()
            XCTAssertEqual(full.bgra(), reference.bgra())
        }
        XCTAssertEqual(r.verificationCaptures, 1)
    }

    func testNoHintRefreshesGlobalChangesAndResizeRebases() async throws {
        let page = try await makePage()
        let r = RetainedViewport(page: page)
        let damage = try RetainedViewport.Rect(x: 50, y: 40, width: 12, height: 10)
        _ = try await r.snapshot(damage: damage)
        try await page.evaluate("document.body.style.background='lime'; return true")
        let full = try await r.snapshot()
        XCTAssertEqual(full.pixel(x: 0, y: 0).g, 255)
        try await page.evaluate("dot.style.background='blue'; return true")
        let patched = try await r.snapshot(damage: damage)
        XCTAssertEqual(patched.pixel(x: 53, y: 43).b, 255)
        page.setViewport(width: 100, height: 80)
        let resized = try await r.snapshot(damage: damage)
        XCTAssertEqual(resized.width, 100); XCTAssertEqual(resized.height, 80)
        XCTAssertEqual(r.fullCaptures, 3); XCTAssertEqual(r.rectCaptures, 1)
    }

    func testLateGradientAndTrustedPolicyUseDifferentChecks() async throws {
        let repoFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("bench/experiments/regions/late-gradient-control.html")
        var tempFixtureURL: URL?
        let url: URL
        if FileManager.default.fileExists(atPath: repoFixture.path) {
            url = repoFixture
        } else {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("safarium-late-gradient-\(UUID().uuidString).html")
            let html = """
            <!doctype html><meta charset="utf-8"><title>Truthful rect, gradient first revealed on frame 2</title>
            <style>
            html,body { margin:0; height:100%; background:linear-gradient(#dba752,#14285d); }
            #cover { position:absolute; left:50px; top:40px; width:46px; height:32px; background:red; }
            </style><div id="cover"></div>
            <script>
            // Only this rectangle changes. Its opaque cover makes the first patched frame clip-independent.
            window.__seek = t => {
              const n = Math.round(t * 30);
              cover.style.background = n ? "lime" : "red";
              cover.style.visibility = n < 2 ? "visible" : "hidden";
            };
            </script>
            """
            try html.write(to: tmp, atomically: true, encoding: .utf8)
            tempFixtureURL = tmp
            url = tmp
        }
        defer {
            if let tempFixtureURL {
                try? FileManager.default.removeItem(at: tempFixtureURL)
            }
        }
        let page = try await Page(config: PageConfig(width: 96, height: 72, deterministicClock: true))
        try await page.load(.fileURL(url))
        let safe = RetainedViewport(page: page), fast = RetainedViewport(page: page)
        let rect = try RetainedViewport.Rect(x: 50, y: 40, width: 46, height: 32)
        for i in 0..<3 {
            try await page.seek(Double(i) / 30)
            let reference = try await page.snapshot().checkedBGRA()
            let trusted = try await fast.snapshot(damage: rect, verification: .trustRect).checkedBGRA()
            do {
                let result = try await safe.snapshot(damage: rect)
                XCTAssertEqual(try result.checkedBGRA(), reference, "never return an incorrect verified frame")
            } catch SafariumError.snapshot(let reason) {
                XCTAssertEqual(i, 2); XCTAssertNotEqual(trusted, reference); XCTAssertTrue(reason.contains("differ"), reason)
            }
        }
        XCTAssertEqual(safe.verificationCaptures, 2); XCTAssertEqual(fast.verificationCaptures, 1)
    }

    func testCheckedBitmapAndPixelBufferRejectIncompatibleStorage() async throws {
        let page = try await makePage(), snapshot = try await page.snapshot()
        let raw = try snapshot.checkedBGRA()
        XCTAssertEqual(raw.count, 96 * 72 * 4)
        XCTAssertEqual(raw[3], 255)
        var buf: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 96, 72, kCVPixelFormatType_32BGRA, nil, &buf), kCVReturnSuccess)
        let buffer = try XCTUnwrap(buf)
        try snapshot.draw(into: buffer, width: 96, height: 72)
        XCTAssertThrowsError(try snapshot.draw(into: buffer, width: 120, height: 72))
        XCTAssertEqual(CVPixelBufferCreate(nil, 96, 72, kCVPixelFormatType_OneComponent8, nil, &buf), kCVReturnSuccess)
        let monochrome = try XCTUnwrap(buf)
        XCTAssertThrowsError(try snapshot.draw(into: monochrome, width: 96, height: 72))
    }

    func testInvalidSignedAndOutOfBoundsInputRejectedBeforeCapture() async throws {
        for (x, y, w, h) in [(-1, 0, 1, 1), (0, -1, 1, 1), (0, 0, -2, 1), (0, 0, 1, -2),
                              (0, 0, 0, 2), (0, 0, 2, 0), (Int.max, 0, 1, 2), (0, Int.max, 2, 1)] {
            XCTAssertThrowsError(try RetainedViewport.Rect(x: x, y: y, width: w, height: h))
        }
        let page = try await makePage()
        let r = RetainedViewport(page: page)
        for invalid in [try RetainedViewport.Rect(x: 95, y: 0, width: 2, height: 1),
                        try RetainedViewport.Rect(x: 0, y: 71, width: 1, height: 2)] {
            do { _ = try await r.snapshot(damage: invalid); XCTFail("out of bounds on first frame must be rejected") }
            catch SafariumError.invalidState { }
        }
        page.setViewport(width: 95, height: 72)
        do {
            _ = try await r.snapshot(damage: RetainedViewport.Rect(x: 0, y: 0, width: 2, height: 2))
            XCTFail("odd viewport must reject a partial capture rather than resample it")
        } catch SafariumError.invalidState { }
        page.setViewport(width: 96, height: 72, scale: 2)
        do { _ = try await r.snapshot(); XCTFail("unsupported scale must be rejected") }
        catch SafariumError.invalidState { }
        XCTAssertEqual(r.fullCaptures, 0); XCTAssertEqual(r.rectCaptures, 0)
    }
}
