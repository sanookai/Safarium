import XCTest
import SafariumCore
import WebKit

/// Probe 4: is a 1x snapshot (core: snapshotWidth = W/backingScale, e.g. 540pt for 1080px) as sharp as a 2x render downscaled?
@MainActor
final class SnapshotQualityProbeTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare(); try Probe.requireHeavy(); try Probe.requireLibs() }

    /// 2x2 box average of a BGRA buffer (premultiplied), the "true" supersampled reference.
    static func boxDown2(_ s: Snapshot) -> [UInt8] {
        let d = s.bgra(), w = s.width, h = s.height, ow = w / 2, oh = h / 2
        var out = [UInt8](repeating: 0, count: ow * oh * 4)
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            let b = p.bindMemory(to: UInt8.self)
            for y in 0..<oh { for x in 0..<ow { for c in 0..<4 {
                let i0 = ((2 * y) * w + 2 * x) * 4 + c, i1 = i0 + 4, i2 = i0 + w * 4, i3 = i2 + 4
                out[(y * ow + x) * 4 + c] = UInt8((Int(b[i0]) + Int(b[i1]) + Int(b[i2]) + Int(b[i3]) + 2) / 4)
            } } }
        }
        return out
    }

    static func psnr(_ a: [UInt8], _ b: Data) -> Double {
        precondition(a.count == b.count)
        var se = 0.0
        b.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for i in stride(from: 0, to: a.count, by: 4) { for c in 0..<3 { let d = Double(a[i + c]) - Double(p[i + c]); se += d * d } }
        }
        let mse = se / Double(a.count / 4 * 3)
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }

    /// Mean absolute horizontal+vertical gradient (higher = crisper edges).
    static func sharpness(_ d: Data, w: Int, h: Int) -> Double {
        var g = 0.0
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            for y in 0..<(h - 1) { for x in 0..<(w - 1) {
                let i = (y * w + x) * 4 + 1
                g += abs(Double(p[i]) - Double(p[i + 4])) + abs(Double(p[i]) - Double(p[i + w * 4]))
            } }
        }
        return g / Double(w * h)
    }

    func testSnapshot_1x_vs_2xDownsample_PSNR() async throws {
        let W = 1080, H = 1920
        let url = try Probe.siteURL("quality.html")

        // A: core path at scale 1 → snapshotWidth = 1080/backing
        let p1 = try await Page(config: PageConfig(width: W, height: H, scale: 1))
        try await p1.load(.fileURL(url, readAccess: Probe.scratch)); try await p1.waitFor(.fonts)
        let a = try await p1.snapshot()          // first call calibrates backing scale
        let a2 = try await p1.snapshot()
        // raw look at what WebKit returns for snapshotWidth = W/2 and W
        func raw(_ page: Page, _ sw: Double) async throws -> (Int, Int) {
            let c = WKSnapshotConfiguration(); c.snapshotWidth = NSNumber(value: sw); c.afterScreenUpdates = true
            let img = try await page.webView.takeSnapshot(configuration: c)
            let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            return (cg.width, cg.height)
        }
        let rawHalf = try await raw(p1, Double(W) / 2), rawFull = try await raw(p1, Double(W))

        // B: reference — same page rendered at 2160x3840 (scale 2), box-downsampled to 1080x1920
        let p2 = try await Page(config: PageConfig(width: W, height: H, scale: 2))
        try await p2.load(.fileURL(url, readAccess: Probe.scratch)); try await p2.waitFor(.fonts)
        let big = try await p2.snapshot()
        XCTAssertEqual(big.width, 2160); XCTAssertEqual(big.height, 3840)
        let ref = Self.boxDown2(big)
        let refData = Data(ref)

        // C: 2x snapshot downscaled by CoreGraphics (what Snapshot.normalized would do)
        let cgDown = Self.cgDownscale(big, width: W, height: H)

        let psnrA = Self.psnr(ref, a.bgra()), psnrC = Self.psnr(ref, cgDown.bgra())
        let shA = Self.sharpness(a.bgra(), w: W, h: H), shRef = Self.sharpness(refData, w: W, h: H)
        Probe.save(a, "quality-1x-core"); Probe.save(big, "quality-2x-source")
        Probe.save(Snapshot(cgImage: Self.image(ref, w: W, h: H)), "quality-reference-box")
        Probe.log("snapshot-quality: raw snapshotWidth=W/2 → \(rawHalf) ; snapshotWidth=W → \(rawFull) ; 1x-vs-ref PSNR=\(String(format: "%.2f", psnrA)) dB ; CG-downscale-2x-vs-ref PSNR=\(String(format: "%.2f", psnrC)) dB ; sharpness 1x=\(String(format: "%.3f", shA)) ref=\(String(format: "%.3f", shRef)) ; repeat-snapshot identical=\(Probe.hash(a) == Probe.hash(a2))")
        // Measured gap (docs/probe-results.md probe 4): the core's 1x snapshot is rasterised at 1:1, not supersampled, so it differs from the
        // 2x→box-downsample reference by ~22 dB. Strict expected failure: flips to an error (→ update the doc) if the core ever closes the gap.
        XCTExpectFailure("1x snapshot is not equivalent to a 2x-supersampled render (PSNR < 30 dB)")
        XCTAssertGreaterThanOrEqual(psnrA, 30, "1x snapshot differs visibly from the 2x-downsampled reference")
    }

    /// Same operation as the core's resize path (CGContext, .high interpolation).
    static func cgDownscale(_ s: Snapshot, width w: Int, height h: Int) -> Snapshot {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(s.cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Snapshot(cgImage: ctx.makeImage()!)
    }

    static func image(_ px: [UInt8], w: Int, h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        px.withUnsafeBytes { ctx.data!.copyMemory(from: $0.baseAddress!, byteCount: px.count) }
        return ctx.makeImage()!
    }
}
