import XCTest
import SafariumCore

@MainActor
final class SnapshotQualityTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare() }

    static let html = """
        <body style="margin:0"><div style="position:absolute;left:10.5px;top:20.5px;width:300px;height:1px;background:#000"></div>
        <div style="position:absolute;left:30.5px;top:40px;width:1px;height:100px;background:#000"></div>
        <p style="position:absolute;left:12px;top:60px;margin:0;font:13px Helvetica, sans-serif">Thin text 0123456789 สวัสดีครับ</p></body>
        """

    func testDefaultIsFast() {
        XCTAssertEqual(PageConfig(width: 10, height: 10).snapshotQuality, .fast)
    }

    func testSharp_exactSize_differsFromFast_keepsAlpha() async throws {
        var hashes: [SnapshotQuality: String] = [:]
        for q in [SnapshotQuality.fast, .sharp] {
            let page = try await Page(config: PageConfig(width: 320, height: 200, scale: 1, transparent: true, snapshotQuality: q))
            try await page.load(.html(Self.html))
            let s = try await page.snapshot()
            XCTAssertEqual(s.width, 320, "\(q)"); XCTAssertEqual(s.height, 200, "\(q)")
            XCTAssertEqual(s.pixel(x: 300, y: 190).a, 0, "\(q): transparent background must keep alpha 0")
            hashes[q] = sha256Hex(s.bgra())
        }
        XCTAssertNotEqual(hashes[.fast], hashes[.sharp], "sharp must actually take a different (supersampled) path")
    }

    func testSharp_scale2_exactSize() async throws {
        let page = try await Page(config: PageConfig(width: 100, height: 60, scale: 2, snapshotQuality: .sharp))
        try await page.load(.html(Self.html))
        let s = try await page.snapshot()
        XCTAssertEqual(s.width, 200); XCTAssertEqual(s.height, 120)
    }

    func testSharp_isDeterministic() async throws {
        var hashes: [String] = []
        for _ in 0..<2 {
            let page = try await Page(config: PageConfig(width: 320, height: 200, snapshotQuality: .sharp))
            try await page.load(.html(Self.html))
            hashes.append(sha256Hex(try await page.snapshot().bgra()))
        }
        XCTAssertEqual(hashes[0], hashes[1])
    }
}
