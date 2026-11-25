import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SafariumCore

final class ColorCalibrationTests: XCTestCase {
    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safarium-color-cal-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func toolExecutableURL(named name: String) throws -> URL {
        let productsDir = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let sibling = productsDir.appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        let isRelease = productsDir.lastPathComponent.lowercased() == "release"
        let scratchDir = productsDir.deletingLastPathComponent().deletingLastPathComponent()
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        build.currentDirectoryURL = packageRoot
        var args = ["swift", "build", "--product", name, "--scratch-path", scratchDir.path]
        if isRelease { args += ["-c", "release"] }
        build.arguments = args
        let errPipe = Pipe()
        build.standardError = errPipe
        try build.run()
        build.waitUntilExit()
        if build.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        let errTxt = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw SafariumError.invalidState("failed to locate or build \(name) at \(sibling.path): \(errTxt)")
    }

    private func runTool(named name: String, args: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let bin = try toolExecutableURL(named: name)
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        let outP = Pipe(), errP = Pipe()
        p.standardOutput = outP
        p.standardError = errP
        try p.run()
        p.waitUntilExit()
        return (
            p.terminationStatus,
            String(data: outP.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: errP.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    // MARK: - CIE Lab / ΔE2000 Reference Metrics

    @inline(__always)
    private func srgbToLinear(_ u: UInt8) -> Double {
        let x = Double(u) / 255.0
        return x <= 0.04045 ? (x / 12.92) : pow((x + 0.055) / 1.055, 2.4)
    }

    @inline(__always)
    private func rgbToLab(r: UInt8, g: UInt8, b: UInt8) -> (Double, Double, Double) {
        let rl = srgbToLinear(r), gl = srgbToLinear(g), bl = srgbToLinear(b)
        let X = (0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl) / 0.95047
        let Y = 0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl
        let Z = (0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl) / 1.08883
        @inline(__always) func f(_ t: Double) -> Double {
            t > 0.008856 ? cbrt(t) : (7.787 * t + 16.0 / 116.0)
        }
        let fx = f(X), fy = f(Y), fz = f(Z)
        return (116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz))
    }

    private func deltaE2000(_ lab1: (Double, Double, Double), _ lab2: (Double, Double, Double)) -> Double {
        let (l1, a1, b1) = lab1
        let (l2, a2, b2) = lab2
        let c1 = hypot(a1, b1)
        let c2 = hypot(a2, b2)
        let cBar = 0.5 * (c1 + c2)
        let cBar7 = pow(cBar, 7.0)
        let pow25_7 = 6_103_515_625.0 // 25^7
        let g = 0.5 * (1.0 - sqrt(cBar7 / (cBar7 + pow25_7)))
        let a1p = (1.0 + g) * a1
        let a2p = (1.0 + g) * a2
        let c1p = hypot(a1p, b1)
        let c2p = hypot(a2p, b2)
        let rad2deg = 180.0 / Double.pi
        let deg2rad = Double.pi / 180.0
        func hueDeg(b: Double, ap: Double) -> Double {
            if b == 0.0 && ap == 0.0 { return 0.0 }
            let h = atan2(b, ap) * rad2deg
            return h < 0.0 ? h + 360.0 : h
        }
        let h1p = hueDeg(b: b1, ap: a1p)
        let h2p = hueDeg(b: b2, ap: a2p)
        let dLp = l2 - l1
        let dCp = c2p - c1p
        var dhp = 0.0
        if c1p * c2p != 0.0 {
            let dh = h2p - h1p
            dhp = abs(dh) <= 180.0 ? dh : (dh > 180.0 ? dh - 360.0 : dh + 360.0)
        }
        let dHp = 2.0 * sqrt(c1p * c2p) * sin(0.5 * dhp * deg2rad)
        let lBarp = 0.5 * (l1 + l2)
        let cBarp = 0.5 * (c1p + c2p)
        var hBarp = h1p + h2p
        if c1p * c2p != 0.0 {
            hBarp = abs(h1p - h2p) <= 180.0
                ? 0.5 * (h1p + h2p)
                : (h1p + h2p < 360.0 ? 0.5 * (h1p + h2p + 360.0) : 0.5 * (h1p + h2p - 360.0))
        }
        let t = 1.0
            - 0.17 * cos((hBarp - 30.0) * deg2rad)
            + 0.24 * cos((2.0 * hBarp) * deg2rad)
            + 0.32 * cos((3.0 * hBarp + 6.0) * deg2rad)
            - 0.20 * cos((4.0 * hBarp - 63.0) * deg2rad)
        let dTheta = 30.0 * exp(-pow((hBarp - 275.0) / 25.0, 2.0))
        let cBarp7 = pow(cBarp, 7.0)
        let rc = 2.0 * sqrt(cBarp7 / (cBarp7 + pow25_7))
        let l50 = pow(lBarp - 50.0, 2.0)
        let sl = 1.0 + 0.015 * l50 / sqrt(20.0 + l50)
        let sc = 1.0 + 0.045 * cBarp
        let sh = 1.0 + 0.015 * cBarp * t
        let rt = -sin(2.0 * dTheta * deg2rad) * rc
        return sqrt(
            pow(dLp / sl, 2.0)
                + pow(dCp / sc, 2.0)
                + pow(dHp / sh, 2.0)
                + rt * (dCp / sc) * (dHp / sh)
        )
    }

    private func computeDeltaE00Stats(refBGRA: [UInt8], candBGRA: [UInt8], width: Int, height: Int, strideA: Int, strideB: Int) -> (mean: Double, p95: Double) {
        var values: [Double] = []
        values.reserveCapacity(width * height)
        var sum = 0.0
        for y in 0..<height {
            let rowA = y * strideA
            let rowB = y * strideB
            for x in 0..<width {
                let oa = rowA + x * 4
                let ob = rowB + x * 4
                let de = deltaE2000(
                    rgbToLab(r: refBGRA[oa + 2], g: refBGRA[oa + 1], b: refBGRA[oa]),
                    rgbToLab(r: candBGRA[ob + 2], g: candBGRA[ob + 1], b: candBGRA[ob])
                )
                values.append(de)
                sum += de
            }
        }
        values.sort()
        let p95 = values[Int(Double(values.count - 1) * 0.95)]
        return (sum / Double(values.count), p95)
    }

    private func readFrame0BGRA(at url: URL) throws -> (bytes: [UInt8], width: Int, height: Int, stride: Int) {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else {
            throw SafariumError.encode("missing video track at \(url.path)")
        }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        reader.add(out)
        guard reader.startReading(),
              let sb = out.copyNextSampleBuffer(),
              let pb = CMSampleBufferGetImageBuffer(sb) else {
            throw SafariumError.encode("cannot decode first frame from \(url.path)")
        }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let data = Array(UnsafeBufferPointer(start: base, count: h * stride))
        return (data, w, h, stride)
    }

    // MARK: - Calibration Tests

    func testAccelerateNV12LeftExactBT709AndOddColumnChromaFilter() throws {
        let w = 24, h = 4
        let pb = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: w, height: h, pixelFormat: .nv12Left)
        var bgra = [UInt8](repeating: 0, count: w * h * 4)

        func setPixel(x: Int, y: Int, r: UInt8, g: UInt8, b: UInt8) {
            let o = (y * w + x) * 4
            bgra[o] = b; bgra[o + 1] = g; bgra[o + 2] = r; bgra[o + 3] = 255
        }

        // Neutral dark background everywhere first (#090d16)
        for y in 0..<h {
            for x in 0..<w { setPixel(x: x, y: y, r: 9, g: 13, b: 22) }
        }
        // Solid neutral gray block at x=0..3 -> exact neutral Cb=128, Cr=128
        for y in 0..<2 {
            for x in 0..<4 { setPixel(x: x, y: y, r: 128, g: 128, b: 128) }
        }
        // 1px bright cyan (#22d3ee -> 34,211,238) stroke strictly on ODD column x=5, rows 0..1
        setPixel(x: 5, y: 0, r: 34, g: 211, b: 238)
        setPixel(x: 5, y: 1, r: 34, g: 211, b: 238)
        // Pure blue 4px block at x=8..11 (check interior x=10) and pure white 4px block at x=16..19 (check interior x=18)
        for y in 0..<2 {
            for x in 8..<12 { setPixel(x: x, y: y, r: 0, g: 0, b: 255) }
            for x in 16..<20 { setPixel(x: x, y: y, r: 255, g: 255, b: 255) }
        }

        try bgra.withUnsafeBytes { raw in
            try SafariumAccelerate.convertRawBGRAToNV12BT709Left(
                bgra: raw.baseAddress!,
                bgraBytesPerRow: w * 4,
                into: pb,
                width: w,
                height: h
            )
        }

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)

        // Neutral gray -> exact 128, 128
        XCTAssertEqual(uvBase[0], 128)
        XCTAssertEqual(uvBase[1], 128)
        // Pure white interior at x=18 -> exact Y=235, Cb=128, Cr=128
        XCTAssertEqual(yBase[18], 235)
        XCTAssertEqual(uvBase[18], 128)
        XCTAssertEqual(uvBase[19], 128)
        // Pure blue interior at x=10 -> exact BT.709 Q16 (Y=32, Cb=240, Cr=118)
        XCTAssertEqual(yBase[10], 32)
        XCTAssertEqual(uvBase[10], 240)
        XCTAssertEqual(uvBase[11], 118)

        // Odd column x=5 cyan stripe MUST contribute chroma into UV pair j=2 (x0=4..5) via [1,2,1]/4 horizontal filter!
        // With old point-sampling `(r00+r10+1)>>1`, uvBase[4] stayed 133 and uvBase[5] stayed 126 (dropping the stripe!).
        XCTAssertGreaterThanOrEqual(uvBase[4], 138, "Odd-column cyan stroke must influence Left-cosited Cb via horizontal filtering")
        XCTAssertLessThanOrEqual(uvBase[5], 108, "Odd-column cyan stroke must influence Left-cosited Cr via horizontal filtering")
    }

    func testSnapshotPreservesCoreMedia709ValuesWhileConvertingDisplayP3() throws {
        let w = 32, h = 32
        let bi = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        // 1. CGImage tagged ITU_R_709 (same primaries/raw bytes as AVAssetImageGenerator CoreMedia709 PNGs)
        let cs709 = CGColorSpace(name: CGColorSpace.itur_709)!
        let ctx709 = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs709, bitmapInfo: bi)!
        let basePtr709 = ctx709.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let o = (y * w + x) * 4
                basePtr709[o] = 45     // B
                basePtr709[o + 1] = 55 // G
                basePtr709[o + 2] = 49 // R
                basePtr709[o + 3] = 255
            }
        }
        let cg709 = ctx709.makeImage()!
        let pb709 = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: w, height: h, pixelFormat: .bgra)
        try Snapshot(cgImage: cg709).draw(into: pb709, width: w, height: h)

        CVPixelBufferLockBaseAddress(pb709, .readOnly)
        let p709 = CVPixelBufferGetBaseAddress(pb709)!.assumingMemoryBound(to: UInt8.self)
        let gotB = Int(p709[0]), gotG = Int(p709[1]), gotR = Int(p709[2])
        CVPixelBufferUnlockBaseAddress(pb709, .readOnly)
        XCTAssertLessThanOrEqual(abs(gotR - 49), 1, "ITU_R_709 / CoreMedia709 red must not shift +6..+8 via 1.961->2.2 gamma warp (got \(gotR))")
        XCTAssertLessThanOrEqual(abs(gotG - 55), 1, "ITU_R_709 / CoreMedia709 green must not shift (got \(gotG))")
        XCTAssertLessThanOrEqual(abs(gotB - 45), 1, "ITU_R_709 / CoreMedia709 blue must not shift (got \(gotB))")

        // 2. Display P3 wide-gamut CGImage MUST still convert P3 -> sRGB!
        let csP3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let ctxP3 = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: csP3, bitmapInfo: bi)!
        ctxP3.setFillColor(CGColor(colorSpace: csP3, components: [0.85, 0.15, 0.15, 1.0])!)
        ctxP3.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let cgP3 = ctxP3.makeImage()!
        let pbP3 = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: w, height: h, pixelFormat: .bgra)
        try Snapshot(cgImage: cgP3).draw(into: pbP3, width: w, height: h)

        CVPixelBufferLockBaseAddress(pbP3, .readOnly)
        let pP3 = CVPixelBufferGetBaseAddress(pbP3)!.assumingMemoryBound(to: UInt8.self)
        let srgbR = Int(pP3[2]), srgbG = Int(pP3[1])
        CVPixelBufferUnlockBaseAddress(pbP3, .readOnly)
        // P3 red (0.85, 0.15, 0.15) has wider red primary -> in sRGB it converts to higher red (>= 230) and clipped/lower green (< 30) vs literal (217, 38)
        XCTAssertGreaterThanOrEqual(srgbR, 230, "Display P3 must still ColorSync-convert to sRGB")
        XCTAssertLessThanOrEqual(srgbG, 25, "Display P3 must still ColorSync-convert to sRGB")
    }

    @MainActor
    func testSyntheticSRGBHTMLDefaultRenderMatchesSnapshotWithinDeltaE00P95Two() async throws {
        let dir = try makeTempDir("html-cal")
        defer { try? FileManager.default.removeItem(at: dir) }

        let htmlURL = dir.appendingPathComponent("cal.html")
        let html = """
        <!doctype html>
        <html lang="th">
        <head><meta charset="utf-8"><style>
          html, body {
            margin: 0; padding: 0; width: 512px; height: 512px; overflow: hidden;
            background: linear-gradient(150deg, #0f172a 0%, #1e293b 50%, #0c4a6e 100%);
            font-family: "Thonburi", sans-serif; color: #f8fafc;
          }
          .swatches { display: flex; gap: 12px; padding: 20px; }
          .sw { width: 72px; height: 72px; border-radius: 10px; }
          .card {
            margin: 12px 20px; padding: 24px; border-radius: 20px;
            background: rgba(15, 23, 42, 0.88); border: 2px solid rgba(56, 189, 248, 0.55);
          }
          h1 { margin: 0 0 12px 0; font-size: 42px; color: #ffffff; }
          .bar { height: 24px; border-radius: 12px; background: linear-gradient(90deg, #38bdf8, #22d3ee, #f59e0b); }
        </style></head>
        <body>
          <div class="swatches">
            <div class="sw" style="background:#ef4444"></div>
            <div class="sw" style="background:#22c55e"></div>
            <div class="sw" style="background:#3b82f6"></div>
            <div class="sw" style="background:#22d3ee"></div>
            <div class="sw" style="background:#df7f6d"></div>
            <div class="sw" style="background:#64748b"></div>
          </div>
          <div class="card">
            <h1>สวัสดีประเทศไทย</h1>
            <div class="bar"></div>
          </div>
        </body>
        </html>
        """
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)

        // Direct WebKit sRGB reference snapshot
        let page = try await Page(config: PageConfig(width: 512, height: 512))
        defer { page.close() }
        try await page.load(.fileURL(htmlURL))
        try await page.waitFor(.readyState)
        try await page.waitFor(.fonts)
        let snap = try await page.snapshot()
        let refData = try snap.checkedBGRA()
        let refBytes = [UInt8](refData)

        // Default safarium-html render (NO --pixel-format flag; must default to .nv12Left cleanly)
        let outMP4 = dir.appendingPathComponent("out.mp4")
        let res = try runTool(named: "safarium-html", args: [
            htmlURL.path,
            "--output", outMP4.path,
            "--width", "512",
            "--height", "512",
            "--fps", "30",
            "--frames", "3",
            "--video-only",
        ])
        XCTAssertEqual(res.status, 0, "safarium-html failed: \(res.stderr)")

        let decoded = try readFrame0BGRA(at: outMP4)
        let stats = computeDeltaE00Stats(
            refBGRA: refBytes,
            candBGRA: decoded.bytes,
            width: 512,
            height: 512,
            strideA: 512 * 4,
            strideB: decoded.stride
        )
        XCTAssertLessThanOrEqual(stats.p95, 2.0, "Default safarium-html H.264 ΔE00 p95=\(stats.p95) exceeded 2.0 (mean=\(stats.mean))")
        XCTAssertLessThanOrEqual(stats.mean, 1.0, "Default safarium-html H.264 ΔE00 mean=\(stats.mean) too high")
    }

    func testSeqEncodeCoreMedia709PNGsMatchesReferenceVideoDeltaE00P95UnderTwo() async throws {
        let dir = try makeTempDir("seq-709")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Build reference H.264 video with warm tones & midtones matching Cut Something failure regime
        let refMP4 = dir.appendingPathComponent("ref.mp4")
        let w = 256, h = 256
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bi = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: cs, bitmapInfo: bi)!
        let swatches: [(CGRect, (CGFloat, CGFloat, CGFloat))] = [
            (CGRect(x: 0, y: 0, width: 128, height: 128), (49.0 / 255.0, 55.0 / 255.0, 45.0 / 255.0)),
            (CGRect(x: 128, y: 0, width: 128, height: 128), (252.0 / 255.0, 207.0 / 255.0, 129.0 / 255.0)),
            (CGRect(x: 0, y: 128, width: 128, height: 128), (237.0 / 255.0, 174.0 / 255.0, 102.0 / 255.0)),
            (CGRect(x: 128, y: 128, width: 128, height: 128), (34.0 / 255.0, 211.0 / 255.0, 238.0 / 255.0)),
        ]
        for (rect, rgb) in swatches {
            ctx.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1.0))
            ctx.fill(rect)
        }
        let snap = Snapshot(cgImage: ctx.makeImage()!)
        let sink = try AVAssetWriterSink(url: refMP4, width: w, height: h, fps: 30, codec: .h264, bitrate: 4_000_000, pixelFormat: .nv12Left)
        for _ in 0..<3 { try await sink.append(snap) }
        try await sink.finish()

        // Extract frame 0..2 via AVAssetImageGenerator -> PNG (producing CoreMedia709-tagged PNGs like extract-frames)
        let framesDir = dir.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
        let asset = AVURLAsset(url: refMP4)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        for idx in 0..<3 {
            let t = CMTime(value: CMTimeValue(idx), timescale: 30)
            var actual = CMTime.zero
            let cg = try gen.copyCGImage(at: t, actualTime: &actual)
            let pngURL = framesDir.appendingPathComponent(String(format: "f%04d.png", idx + 1))
            let dest = CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, cg, nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
        }

        let seqMP4 = dir.appendingPathComponent("seq.mp4")
        let res = try runTool(named: "safarium-forge", args: [
            "seq-encode",
            "--dir", framesDir.path,
            "--glob", "*.png",
            "--fps", "30",
            "-o", seqMP4.path,
            "--overwrite",
        ])
        XCTAssertEqual(res.status, 0, "safarium-forge seq-encode failed: \(res.stderr)")

        let refFrame = try readFrame0BGRA(at: refMP4)
        let seqFrame = try readFrame0BGRA(at: seqMP4)
        let stats = computeDeltaE00Stats(
            refBGRA: refFrame.bytes,
            candBGRA: seqFrame.bytes,
            width: w,
            height: h,
            strideA: refFrame.stride,
            strideB: seqFrame.stride
        )
        XCTAssertLessThanOrEqual(stats.p95, 2.0, "seq-encode CoreMedia709 PNG roundtrip ΔE00 p95=\(stats.p95) exceeded 2.0 (mean=\(stats.mean))")
        XCTAssertLessThanOrEqual(stats.mean, 1.0, "seq-encode CoreMedia709 PNG roundtrip ΔE00 mean=\(stats.mean) too high")
    }
}
