import CoreGraphics
import Foundation

extension Snapshot {
    // A native-size crop of these ordinary 8-bit sRGB snapshots does not change the
    // color transform. Keep the original full normalization for other SDR profiles,
    // decode arrays, or storage formats accepted by RetainedViewport.
    var supportsBGRAComparisonStrips: Bool {
        let image = cgImage
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.bitmapInfo.rawValue == Self.bitmapInfo, !image.isMask,
              image.decode == nil, let space = image.colorSpace,
              CFEqual(space, Self.colorSpace) else { return false }
        return true
    }

    /// Canonical top-down BGRA for a full-width, integer-aligned subset of the image.
    func checkedBGRAStrip(y: Int, rows: Int) throws -> Data {
        guard y >= 0, rows > 0, y <= height - rows,
              let tile = cgImage.cropping(to: CGRect(x: 0, y: y, width: width, height: rows)),
              tile.width == width, tile.height == rows else {
            throw SafariumError.snapshot("cannot crop a full-width comparison strip")
        }
        return try Snapshot(cgImage: tile).checkedBGRA()
    }

    /// First unequal byte in the same canonical BGRA order as `checkedBGRA()`.
    /// Identical images return nil only after the entire viewport has been compared.
    func firstDifferentBGRAByte(from other: Snapshot) throws -> Int? {
        let w = width, h = height
        guard w == other.width, h == other.height, w > 0, h > 0, w <= Int.max / 4 / h else {
            throw SafariumError.snapshot("incompatible comparison geometry")
        }
        func firstDifference(_ a: Data, _ b: Data) -> Int? {
            guard a != b else { return nil }
            return a.indices.first { a[$0] != b[$0] }
        }
        if supportsBGRAComparisonStrips && other.supportsBGRAComparisonStrips {
            do {
                for y in stride(from: 0, to: h, by: 64) {
                    let rows = min(64, h - y)
                    let difference = try autoreleasepool {
                        try firstDifference(checkedBGRAStrip(y: y, rows: rows), other.checkedBGRAStrip(y: y, rows: rows))
                    }
                    if let difference { return y * w * 4 + difference }
                }
                return nil
            } catch {
                // If a source cannot provide a strip, still apply the original exact gate.
            }
        }
        return try firstDifference(checkedBGRA(), other.checkedBGRA())
    }
}
