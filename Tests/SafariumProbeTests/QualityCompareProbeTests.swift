import XCTest
import AppKit
import AVFoundation
import SafariumCore

/// Side-by-side of `SnapshotQuality.fast` (WebKit rasterises at 1080x1920) vs `.sharp` (2160x3840 + Lanczos), with timings.
/// Opt-in (SAFARIUM_PROBES=1). Output folder: SAFARIUM_QUALITY_OUT, else <scratch>/probe-evidence/quality-compare.
@MainActor
final class QualityCompareProbeTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare() }

    static var outDir: URL {
        if let e = ProcessInfo.processInfo.environment["SAFARIUM_QUALITY_OUT"], !e.isEmpty { return URL(fileURLWithPath: e) }
        return Probe.evidence.appendingPathComponent("quality-compare")
    }

    static func load1() -> Double { var l = [Double](repeating: 0, count: 3); getloadavg(&l, 3); return l[0] }

    struct Run { var frame: Snapshot; var crops: [CGRect]; var msPerFrame: Double; var msSnapshotOnly: Double; var load: Double }

    func render(_ q: SnapshotQuality) async throws -> Run {
        let page = try await Page(config: PageConfig(width: 1080, height: 1920, deterministicClock: true, snapshotQuality: q))
        try await page.load(.fileURL(try Probe.siteURL("quality-compare.html")))
        try await page.waitFor(.fonts); try await page.waitFor(.images)
        // crop regions (CSS px): the 14 px Thai/English paragraph, and the thin-line/circle area
        let rects = try await page.evaluate("""
            const r = document.getElementById('t14').getBoundingClientRect();
            const s = document.querySelector('svg').getBoundingClientRect();
            return [r.left, r.top, s.left + 330, s.top + 20]
            """) as? [Double] ?? []
        let crops = [CGRect(x: rects[0], y: rects[1], width: 200, height: 60), CGRect(x: rects[2], y: rects[3], width: 200, height: 60)]
        let first = try await page.snapshot()
        Probe.save(first, "quality-compare-\(q)")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sfqc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let sink = try AVAssetWriterSink(url: dir.appendingPathComponent("o.mp4"), width: 1080, height: 1920, fps: 30, codec: .h264, bitrate: 20_000_000)
        var snapMs = 0.0
        let load = Self.load1()
        let t0 = CFAbsoluteTimeGetCurrent()
        for i in 0..<90 {
            try await page.seek(Double(i) / 30)
            let a = CFAbsoluteTimeGetCurrent()
            let s = try await page.snapshot()
            snapMs += (CFAbsoluteTimeGetCurrent() - a) * 1000
            try await sink.append(s)
        }
        try await sink.finish()
        let total = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        return Run(frame: first, crops: crops, msPerFrame: total / 90, msSnapshotOnly: snapMs / 90, load: load)
    }

    /// Nearest-neighbour `zoom`× crop (pixels stay visible).
    static func zoomed(_ s: Snapshot, _ rect: CGRect, zoom: Int) -> CGImage {
        let c = s.cgImage.cropping(to: CGRect(x: rect.minX.rounded(), y: rect.minY.rounded(), width: rect.width, height: rect.height))!
        let w = c.width * zoom, h = c.height * zoom
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.interpolationQuality = .none
        ctx.draw(c, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    static func sideBySide(_ a: CGImage, _ b: CGImage, label: (String, String)) -> CGImage {
        let gap = 16, bar = 28, w = a.width + gap + b.width, h = max(a.height, b.height) + bar
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(red: 0.85, green: 0.1, blue: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(a, in: CGRect(x: 0, y: 0, width: a.width, height: a.height))
        ctx.draw(b, in: CGRect(x: a.width + gap, y: 0, width: b.width, height: b.height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.white]
        (label.0 as NSString).draw(at: NSPoint(x: 8, y: h - bar + 4), withAttributes: attrs)
        (label.1 as NSString).draw(at: NSPoint(x: CGFloat(a.width + gap + 8), y: CGFloat(h - bar + 4)), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    static func psnr(_ a: Snapshot, _ b: Snapshot) -> Double {
        let x = a.bgra(), y = b.bgra(); var se = 0.0
        x.withUnsafeBytes { (p: UnsafeRawBufferPointer) in y.withUnsafeBytes { (q: UnsafeRawBufferPointer) in
            for i in 0..<p.count where i % 4 != 3 { let d = Double(p[i]) - Double(q[i]); se += d * d }
        } }
        let mse = se / Double(x.count / 4 * 3)
        return mse == 0 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    func testCompare_fastVsSharp_writesImagesAndTimings() async throws {
        try Probe.requireHeavy()
        let out = Self.outDir
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let fast = try await render(.fast)
        let sharp = try await render(.sharp)
        for (name, run) in [("fast-1x-1080x1920", fast), ("sharp-2x-lanczos-1080x1920", sharp)] {
            try run.frame.pngData().write(to: out.appendingPathComponent(name + ".png"))
        }
        let names = ["small-thai-text", "thin-lines-circle"]
        for (i, n) in names.enumerated() {
            let img = Self.sideBySide(Self.zoomed(fast.frame, fast.crops[i], zoom: 4), Self.zoomed(sharp.frame, sharp.crops[i], zoom: 4),
                                      label: ("fast (1x) - 4x zoom", "sharp (2x + Lanczos) - 4x zoom"))
            try Snapshot(cgImage: img).pngData().write(to: out.appendingPathComponent("compare-4x-\(n).png"))
        }
        let p = Self.psnr(fast.frame, sharp.frame)
        let report = """
            quality-compare (\(Date())) machine load avg(1m) at start: fast \(String(format: "%.2f", fast.load)), sharp \(String(format: "%.2f", sharp.load)) (\(ProcessInfo.processInfo.activeProcessorCount) cores)
            90 frames, 1080x1920, H.264 20 Mbps (seek + snapshot + encode):
              fast : \(String(format: "%.1f", fast.msPerFrame)) ms/frame total, snapshot alone \(String(format: "%.1f", fast.msSnapshotOnly)) ms
              sharp: \(String(format: "%.1f", sharp.msPerFrame)) ms/frame total, snapshot alone \(String(format: "%.1f", sharp.msSnapshotOnly)) ms
            PSNR(fast, sharp) = \(String(format: "%.2f", p)) dB
            """
        try report.write(to: out.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8)
        Probe.log("quality-compare: " + report.replacingOccurrences(of: "\n", with: " | "))
        XCTAssertNotEqual(Probe.hash(fast.frame), Probe.hash(sharp.frame))
        XCTAssertEqual(sharp.frame.width, 1080); XCTAssertEqual(sharp.frame.height, 1920)
    }
}
