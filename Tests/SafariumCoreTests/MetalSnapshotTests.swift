import XCTest
import CoreGraphics
import CoreVideo
@testable import SafariumCore

@MainActor
final class MetalSnapshotTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare() }

    private func makeCVPixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferBytesPerRowAlignmentKey as String: 64,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &pb
        )
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pb)
    }

    private func copyBytes(from pb: CVPixelBuffer, width: Int, height: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<(width * 4) {
                out[y * width * 4 + x] = base[y * stride + x]
            }
        }
        return out
    }

    func testMetalContextSharedInitializes() throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let ctx = try XCTUnwrap(SafariumMetalContext.shared)
        _ = ctx.device
        _ = ctx.commandQueue
        _ = ctx.textureCache
        _ = ctx.ciContext
        ctx.flushTextureCache()
    }

    func testCanonicalBGRAFastPathMatchesCGContextBitForBit() throws {
        let w = 240, h = 160
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let canonicalInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        // 1. Canonical sRGB premultipliedFirst little-endian BGRA8 CGImage
        let ctx1 = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: sRGB, bitmapInfo: canonicalInfo
        )!
        ctx1.setFillColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 0.75)
        ctx1.fill(CGRect(x: 20, y: 30, width: 100, height: 80))
        ctx1.setFillColor(red: 0.1, green: 0.8, blue: 0.5, alpha: 1.0)
        ctx1.fillEllipse(in: CGRect(x: 80, y: 50, width: 90, height: 90))
        let canonicalCG = ctx1.makeImage()!
        XCTAssertTrue(Snapshot.isCanonicalSRGBBGRA8(canonicalCG))

        let pbFast = try makeCVPixelBuffer(width: w, height: h)
        try Snapshot(cgImage: canonicalCG).draw(into: pbFast, width: w, height: h)

        let pbRef = try makeCVPixelBuffer(width: w, height: h)
        CVPixelBufferLockBaseAddress(pbRef, [])
        let refCtx = CGContext(
            data: CVPixelBufferGetBaseAddress(pbRef)!, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pbRef), space: sRGB, bitmapInfo: canonicalInfo
        )!
        refCtx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        refCtx.draw(canonicalCG, in: CGRect(x: 0, y: 0, width: w, height: h))
        CVPixelBufferUnlockBaseAddress(pbRef, [])

        XCTAssertEqual(copyBytes(from: pbFast, width: w, height: h), copyBytes(from: pbRef, width: w, height: h))

        // 2. Non-canonical Display P3 / RGBA image must take fallback CGContext path without error
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let rgbaInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let ctx2 = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: p3, bitmapInfo: rgbaInfo
        )!
        ctx2.setFillColor(red: 1.0, green: 0.1, blue: 0.1, alpha: 1.0)
        ctx2.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let nonCanonicalCG = ctx2.makeImage()!
        XCTAssertFalse(Snapshot.isCanonicalSRGBBGRA8(nonCanonicalCG))

        let pbFallback = try makeCVPixelBuffer(width: w, height: h)
        try Snapshot(cgImage: nonCanonicalCG).draw(into: pbFallback, width: w, height: h)
        let bytes = copyBytes(from: pbFallback, width: w, height: h)
        // Red pixel in BGRA has high red channel (offset 2) and alpha 255 (offset 3)
        XCTAssertEqual(bytes[3], 255)
        XCTAssertGreaterThan(bytes[2], 200)
    }

    func testSharpLanczosDownscaleDeterministicAndBounded() throws {
        let srcW = 1080, srcH = 1920, dstW = 540, dstH = 960
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let canonicalInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(
            data: nil, width: srcW, height: srcH, bitsPerComponent: 8, bytesPerRow: srcW * 4,
            space: sRGB, bitmapInfo: canonicalInfo
        )!
        ctx.setFillColor(red: 0.05, green: 0.1, blue: 0.2, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: srcW, height: srcH))
        ctx.setFillColor(red: 0.9, green: 0.7, blue: 0.2, alpha: 1.0)
        ctx.fill(CGRect(x: 100, y: 200, width: 600, height: 10))
        let bigCG = ctx.makeImage()!

        var hashes: Set<String> = []
        for _ in 0..<15 {
            let down = try XCTUnwrap(Snapshot.lanczosDownscale(bigCG, width: dstW, height: dstH))
            XCTAssertEqual(down.width, dstW)
            XCTAssertEqual(down.height, dstH)
            hashes.insert(sha256Hex(Snapshot(cgImage: down).bgra()))
        }
        XCTAssertEqual(hashes.count, 1)
    }
}
