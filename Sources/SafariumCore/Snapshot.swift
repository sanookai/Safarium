import Foundation
import CoreGraphics
import CoreVideo
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// One captured frame, exactly `width`×`height` device pixels (premultiplied BGRA when read as raw).
public struct Snapshot: @unchecked Sendable {
    public let cgImage: CGImage
    public var width: Int { cgImage.width }
    public var height: Int { cgImage.height }

    public init(cgImage: CGImage) { self.cgImage = cgImage }

    package static let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    package static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// True when `image` already matches canonical premultiplied BGRA8 in sRGB with no mask or decode remapping.
    package static func isCanonicalSRGBBGRA8(_ image: CGImage) -> Bool {
        guard image.bitsPerComponent == 8,
              image.bitsPerPixel == 32,
              image.bitmapInfo.rawValue == bitmapInfo,
              !image.isMask,
              image.decode == nil,
              let space = image.colorSpace else {
            return false
        }
        return CFEqual(space, colorSpace)
    }

    /// Draws `image` into a context of exactly `w`×`h` (scaling only if sizes differ).
    static func normalized(_ image: CGImage, width w: Int, height h: Int) -> CGImage? {
        if image.width == w && image.height == h { return image }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
        ctx.interpolationQuality = .high
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Core Image Lanczos downscale of `image` to exactly `w`×`h` (alpha stays premultiplied).
    /// Reuses `SafariumMetalContext.shared?.ciContext` to keep peak RAM bounded across frames.
    static func lanczosDownscale(_ image: CGImage, width w: Int, height h: Int) -> CGImage? {
        autoreleasepool {
            let src = CIImage(cgImage: image)
            guard let f = CIFilter(name: "CILanczosScaleTransform") else { return nil }
            f.setValue(src, forKey: kCIInputImageKey)
            f.setValue(Double(h) / Double(image.height), forKey: kCIInputScaleKey)
            f.setValue(Double(w) / Double(h) * Double(image.height) / Double(image.width), forKey: kCIInputAspectRatioKey)
            guard let out = f.outputImage else { return nil }
            let ctx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [
                .workingColorSpace: colorSpace,
                .outputColorSpace: colorSpace,
                .cacheIntermediates: false,
            ])
            defer { SafariumMetalContext.shared?.flushTextureCache() }
            guard let cg = ctx.createCGImage(out, from: CGRect(x: 0, y: 0, width: w, height: h), format: .BGRA8, colorSpace: colorSpace) else { return nil }
            return normalized(cg, width: w, height: h)
        }
    }

    /// Tightly packed premultiplied BGRA bytes (row 0 = top), or empty on failure.
    /// Use `checkedBGRA()` for comparisons, hashing and other correctness-sensitive work.
    public func bgra() -> Data {
        (try? checkedBGRA()) ?? Data()
    }

    public func checkedBGRA() throws -> Data {
        guard width > 0, height > 0, width <= Int.max / 4 / height else {
            throw SafariumError.snapshot("unrepresentable BGRA dimensions")
        }
        var data = Data(count: width * height * 4)
        try data.withUnsafeMutableBytes { buf in
            try drawBGRA(to: buf.baseAddress, width: width, height: height, stride: width * 4)
        }
        return data
    }

    /// Pixel at (x, y), y=0 at the top. Channels are premultiplied.
    public func pixel(x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        var px = [UInt8](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: Snapshot.colorSpace, bitmapInfo: Snapshot.bitmapInfo) else { return }
            ctx.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
            ctx.draw(cgImage, in: CGRect(x: -x, y: -(height - 1 - y), width: width, height: height))
        }
        return (px[0], px[1], px[2], px[3])
    }

    public func pngData() -> Data { encoded(UTType.png, quality: nil) }
    public func jpegData(quality: Double = 0.9) -> Data { encoded(UTType.jpeg, quality: quality) }

    private func encoded(_ type: UTType, quality: Double?) -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return Data() }
        var props: [CFString: Any] = [:]
        if let q = quality { props[kCGImageDestinationLossyCompressionQuality] = q }
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : Data()
    }

    /// Writes this frame into a BGRA pixel buffer of exactly `width`×`height` (fast memcpy for canonical BGRA, else CGContext).
    package func draw(into pb: CVPixelBuffer, width w: Int, height h: Int) throws {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(pb) == w, CVPixelBufferGetHeight(pb) == h else {
            throw SafariumError.encode("incompatible BGRA pixel buffer")
        }
        let locked = CVPixelBufferLockBaseAddress(pb, [])
        guard locked == kCVReturnSuccess else { throw SafariumError.encode("cannot lock pixel buffer (\(locked))") }
        do {
            guard let dstBase = CVPixelBufferGetBaseAddress(pb) else {
                throw SafariumError.snapshot("missing BGRA destination base address")
            }
            let dstStride = CVPixelBufferGetBytesPerRow(pb)
            if Self.isCanonicalSRGBBGRA8(cgImage),
               cgImage.width == w, cgImage.height == h,
               let provider = cgImage.dataProvider,
               let cfData = provider.data,
               let srcPtr = CFDataGetBytePtr(cfData) {
                let srcStride = cgImage.bytesPerRow
                let rowBytes = w * 4
                let needed = (h - 1) * srcStride + rowBytes
                if srcStride >= rowBytes, dstStride >= rowBytes, CFDataGetLength(cfData) >= needed {
                    if srcStride == dstStride && srcStride == rowBytes {
                        memcpy(dstBase, srcPtr, h * rowBytes)
                    } else {
                        for y in 0..<h {
                            memcpy(dstBase.advanced(by: y * dstStride), srcPtr.advanced(by: y * srcStride), rowBytes)
                        }
                    }
                } else {
                    try drawBGRA(to: dstBase, width: w, height: h, stride: dstStride)
                }
            } else {
                try drawBGRA(to: dstBase, width: w, height: h, stride: dstStride)
            }
        } catch {
            CVPixelBufferUnlockBaseAddress(pb, [])
            throw error
        }
        let unlocked = CVPixelBufferUnlockBaseAddress(pb, [])
        guard unlocked == kCVReturnSuccess else { throw SafariumError.encode("cannot unlock pixel buffer (\(unlocked))") }
    }

    /// Borrows zero-copy canonical sRGB BGRA8 bytes when the backing CGImage already matches `w`×`h` in memory.
    package func borrowCanonicalBGRABytes<R>(width w: Int, height h: Int, _ body: (UnsafeRawPointer, Int) throws -> R) rethrows -> R? {
        guard w > 0, h > 0,
              Self.isCanonicalSRGBBGRA8(cgImage),
              cgImage.width == w, cgImage.height == h,
              let provider = cgImage.dataProvider,
              let cfData = provider.data,
              let srcPtr = CFDataGetBytePtr(cfData) else {
            return nil
        }
        let srcStride = cgImage.bytesPerRow
        let rowBytes = w * 4
        let needed = (h - 1) * srcStride + rowBytes
        guard srcStride >= rowBytes, CFDataGetLength(cfData) >= needed else {
            return nil
        }
        return try body(srcPtr, srcStride)
    }

    /// Draws into an existing tightly-strided BGRA buffer without allocating temporary `Data`.
    package func drawBGRAInto(baseAddress: UnsafeMutableRawPointer, width w: Int, height h: Int, stride: Int) throws {
        let copied = borrowCanonicalBGRABytes(width: w, height: h) { srcPtr, srcStride in
            let rowBytes = w * 4
            if srcStride == stride && srcStride == rowBytes {
                memcpy(baseAddress, srcPtr, h * rowBytes)
            } else {
                for y in 0..<h {
                    memcpy(baseAddress.advanced(by: y * stride), srcPtr.advanced(by: y * srcStride), rowBytes)
                }
            }
            return true
        } ?? false
        if copied { return }
        try drawBGRA(to: baseAddress, width: w, height: h, stride: stride)
    }

    private func drawBGRA(to base: UnsafeMutableRawPointer?, width w: Int, height h: Int, stride: Int) throws {
        guard let base, w > 0, h > 0, w <= Int.max / 4, stride >= w * 4,
              let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride,
                                  space: Snapshot.colorSpace, bitmapInfo: Snapshot.bitmapInfo) else {
            throw SafariumError.snapshot("cannot create \(w)×\(h) BGRA drawing context")
        }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
}
