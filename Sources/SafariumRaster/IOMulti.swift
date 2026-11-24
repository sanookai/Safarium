// SafariumRaster — multi-frame / animation support (Area C): frame count, decode of frame N, frame timing, and
// multi-image encode (multi-page TIFF, animated GIF / APNG) through ImageIO. WebP animation is read-only.

import Foundation
import ImageIO
import CoreGraphics

private func ioSource(_ buf: UnsafePointer<UInt8>?, _ len: Int) -> CGImageSource? {
    guard let buf, len > 0 else { return nil }
    let opts: [CFString: Any] = [kCGImageSourceShouldAllowFloat: true, kCGImageSourceShouldCache: false]
    return CGImageSourceCreateWithData(Data(bytes: buf, count: len) as CFData, opts as CFDictionary)
}

/// Dictionary holding the per-frame timing keys for the container type.
private func ioAnimDict(_ props: [CFString: Any]?, type: String) -> [CFString: Any]? {
    switch type {
    case "com.compuserve.gif": return props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    case "public.png": return props?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
    case "org.webmproject.webp": return props?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
    default: return nil
    }
}

/// out[0] = frame count, out[1] = loop count (0 = forever), out[2] = type code (0 other, 1 gif, 2 png/apng, 3 webp, 4 tiff).
@_cdecl("sr_io_frame_info")
public func sr_io_frame_info(_ buf: UnsafePointer<UInt8>?, _ len: Int, _ out: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let out, let src = ioSource(buf, len) else { return srFail(SRStatus.unsupported, "imcount: cannot decode image") }
    let type = (CGImageSourceGetType(src) as String?) ?? ""
    out[0] = Int32(CGImageSourceGetCount(src))
    out[1] = 0
    switch type {
    case "com.compuserve.gif": out[2] = 1
    case "public.png": out[2] = 2
    case "org.webmproject.webp": out[2] = 3
    case "public.tiff": out[2] = 4
    default: out[2] = 0
    }
    if let cp = CGImageSourceCopyProperties(src, nil) as? [CFString: Any], let d = ioAnimDict(cp, type: type) {
        let key: CFString
        switch type {
        case "com.compuserve.gif": key = kCGImagePropertyGIFLoopCount
        case "public.png": key = kCGImagePropertyAPNGLoopCount
        default: key = kCGImagePropertyWebPLoopCount
        }
        if let n = d[key] as? Int { out[1] = Int32(n) }
    }
    return SRStatus.ok
}

/// Frame display time in milliseconds (0 when the container carries none).
@_cdecl("sr_io_frame_delay")
public func sr_io_frame_delay(_ buf: UnsafePointer<UInt8>?, _ len: Int, _ index: Int32) -> Int32 {
    guard let src = ioSource(buf, len), index >= 0, Int(index) < CGImageSourceGetCount(src) else { return -1 }
    let type = (CGImageSourceGetType(src) as String?) ?? ""
    guard let props = CGImageSourceCopyPropertiesAtIndex(src, Int(index), nil) as? [CFString: Any],
          let d = ioAnimDict(props, type: type) else { return 0 }
    let unclamped: CFString, clamped: CFString
    switch type {
    case "com.compuserve.gif": unclamped = kCGImagePropertyGIFUnclampedDelayTime; clamped = kCGImagePropertyGIFDelayTime
    case "public.png": unclamped = kCGImagePropertyAPNGUnclampedDelayTime; clamped = kCGImagePropertyAPNGDelayTime
    default: unclamped = kCGImagePropertyWebPUnclampedDelayTime; clamped = kCGImagePropertyWebPDelayTime
    }
    let sec = (d[unclamped] as? Double) ?? (d[clamped] as? Double) ?? 0
    return Int32((sec * 1000.0).rounded())
}

/// Decode frame `index` (flags as imdecode).
@_cdecl("sr_io_decode_frame")
public func sr_io_decode_frame(_ buf: UnsafePointer<UInt8>?, _ len: Int, _ flags: Int32, _ index: Int32,
                               _ out: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard let buf, len > 0, let out, index >= 0 else { return srFail(SRStatus.badArgument, "imdecode: bad arguments") }
    var tooLarge = false
    guard let m = ioDecode(Data(bytes: buf, count: len), flags: flags, tooLarge: &tooLarge, index: Int(index)) else {
        if tooLarge { return srFail(SRStatus.badArgument, "imdecode: image is larger than CV_IO_MAX_IMAGE_PIXELS (2^30 pixels)") }
        return srFail(SRStatus.unsupported, "imdecode: cannot decode frame \(index)")
    }
    let blob = IOBlob()
    blob.mat = m
    out.pointee = Unmanaged.passRetained(blob).toOpaque()
    return SRStatus.ok
}

/// Encode `n` images into one file: multi-page TIFF, or an animated GIF / APNG (delays in ms, loop 0 = forever).
@_cdecl("sr_io_encode_multi")
public func sr_io_encode_multi(_ n: Int32, _ datas: UnsafePointer<UnsafeMutableRawPointer?>?, _ widths: UnsafePointer<Int32>?,
                               _ heights: UnsafePointer<Int32>?, _ strides: UnsafePointer<Int32>?, _ channels: UnsafePointer<Int32>?,
                               _ depths: UnsafePointer<Int32>?, _ delaysMs: UnsafePointer<Int32>?, _ loop: Int32,
                               _ ext: UnsafePointer<CChar>?, _ params: UnsafePointer<Int32>?, _ nparams: Int32,
                               _ out: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard n > 0, let datas, let widths, let heights, let strides, let channels, let depths, let ext, let out else {
        return srFail(SRStatus.badArgument, "imencodemulti: bad arguments")
    }
    let e = String(cString: ext).lowercased()
    let p = IOParams(params, Int(nparams))
    let uti: String
    switch e {
    case ".tif", ".tiff": uti = "public.tiff"
    case ".gif": uti = "com.compuserve.gif"
    case ".png", ".apng": uti = "public.png"
    case ".webp":
        var list: [SRImage] = []
        for i in 0..<Int(n) {
            guard let im = SRImage(datas[i], widths[i], heights[i], strides[i], channels[i], depths[i]) else {
                return srFail(SRStatus.badArgument, "imencodemulti: bad image \(i)")
            }
            if !ioWebPValidDimensions(im.width, im.height) {
                return srFail(SRStatus.badArgument, ioWebPLimitError)
            }
            list.append(im)
        }
        let q = p.get(64, 101)
        guard let bytes = ioEncodeWebPAnimation(list, delaysMs: (0..<Int(n)).map { i in delaysMs.map { Int($0[i]) } ?? 100 }, loop: Int(loop), quality: q > 100 ? 100 : q) else {
            return srFail(SRStatus.ioFailure, "imencodemulti: encoder failed")
        }
        let blob = IOBlob()
        blob.buffer = bytes
        out.pointee = Unmanaged.passRetained(blob).toOpaque()
        return SRStatus.ok
    default: return srFail(SRStatus.unsupported, "imencodemulti: could not find a multi-image writer for '\(e)'")
    }
    if uti == "public.tiff" {
        var list: [SRImage] = []
        for i in 0..<Int(n) {
            guard let im = SRImage(datas[i], widths[i], heights[i], strides[i], channels[i], depths[i]) else {
                return srFail(SRStatus.badArgument, "imencodemulti: bad image \(i)")
            }
            if !ioWebPValidDimensions(im.width, im.height) {
                return srFail(SRStatus.badArgument, ioWebPLimitError)
            }
            list.append(im)
        }
        let tiffBytes = ioEncodeTIFF(list, p)
        if ioTIFFTooLarge { return srFail(SRStatus.ioFailure, "imencodemulti: the TIFF would exceed 4 GiB (classic TIFF offsets)") }
        if let bytes = tiffBytes {
            let blob = IOBlob()
            blob.buffer = bytes
            out.pointee = Unmanaged.passRetained(blob).toOpaque()
            return SRStatus.ok
        }
    }
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, uti as CFString, Int(n), nil) else {
        return srFail(SRStatus.ioFailure, "imencodemulti: cannot create the destination")
    }
    if uti == "com.compuserve.gif" {
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: Int(loop)]] as CFDictionary)
    } else if uti == "public.png" {
        CGImageDestinationSetProperties(dest, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: Int(loop)]] as CFDictionary)
    }
    for i in 0..<Int(n) {
        guard let img = SRImage(datas[i], widths[i], heights[i], strides[i], channels[i], depths[i]) else {
            return srFail(SRStatus.badArgument, "imencodemulti: bad image \(i)")
        }
        var frame = img
        var holder: [UInt8] = []
        if uti == "com.compuserve.gif" && img.depth != .u8 {
            // 8-bit only: reuse the generic converter through a packed copy
            holder = [UInt8](repeating: 0, count: img.width * img.height * img.channels)
            holder.withUnsafeMutableBufferPointer { b in
                for y in 0..<img.height { ioRowU8(img, y, b.baseAddress! + y * img.width * img.channels) }
            }
        }
        let build: (SRImage) -> CGImage? = { ioMakeCGImage($0, uti: uti) }
        var props: [CFString: Any] = [:]
        let delay = delaysMs.map { Double($0[i]) / 1000.0 } ?? 0.1
        if uti == "com.compuserve.gif" { props[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay] }
        if uti == "public.png" { props[kCGImagePropertyPNGDictionary] = [kCGImagePropertyAPNGDelayTime: delay, kCGImagePropertyAPNGUnclampedDelayTime: delay] }
        if uti == "public.tiff" {
            let comp = p.get(259, 8)   // multi-page: Adobe Deflate by default (smaller than cv2's LZW), any of 1 / 5 / 8 / 32773 on request
            if [1, 5, 32773, 8, 32946].contains(comp) { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: comp == 32946 ? 8 : comp] }
        }
        if !holder.isEmpty {
            let ok: Bool = holder.withUnsafeMutableBytes { raw in
                guard let t = SRImage(raw.baseAddress, Int32(img.width), Int32(img.height), Int32(img.width * img.channels), Int32(img.channels), SRDepth.u8.rawValue),
                      let cg = build(t) else { return false }
                CGImageDestinationAddImage(dest, cg, props as CFDictionary)
                return true
            }
            if !ok { return srFail(SRStatus.ioFailure, "imencodemulti: cannot convert frame \(i)") }
            continue
        }
        frame = img
        guard let cg = build(frame) else { return srFail(SRStatus.ioFailure, "imencodemulti: cannot convert frame \(i)") }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
    }
    guard CGImageDestinationFinalize(dest) else { return srFail(SRStatus.ioFailure, "imencodemulti: encoder failed") }
    let blob = IOBlob()
    blob.buffer = [UInt8](data as Data)
    out.pointee = Unmanaged.passRetained(blob).toOpaque()
    return SRStatus.ok
}
