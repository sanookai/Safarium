// SafariumRaster — still-image decode/encode (Area C). ImageIO/CoreGraphics only, no OpenCV/FFmpeg.
//
// Behaviour mirrors OpenCV 5.1 imgcodecs (imdecode/imencode flags, EXIF orientation, alpha dropped for
// IMREAD_COLOR, ICC profiles ignored: pixels are taken raw from the decoder's data provider, never
// colour-converted). The reduced modes follow loadsave.cpp: JPEG uses DCT-style box scaling (ceil dims),
// other formats use a bilinear "exact" resize (floor dims).

import Foundation
import ImageIO
import CoreGraphics
import Accelerate

@_silgen_name("sr_jpeg_decode_baseline")
private func sr_jpeg_decode_baseline(_ data: UnsafePointer<UInt8>, _ len: Int,
                                     _ outW: UnsafeMutablePointer<Int32>?, _ outH: UnsafeMutablePointer<Int32>?,
                                     _ outCn: UnsafeMutablePointer<Int32>?,
                                     _ dst: UnsafeMutablePointer<UInt8>?, _ dstStride: Int, _ wantCn: Int32) -> Int32

@_silgen_name("sr_c_cvt_swap_u8")
private func sr_io_cvt_swap_u8(_ src: UnsafePointer<UInt8>, _ sstep: Int, _ dst: UnsafeMutablePointer<UInt8>, _ dstep: Int,
                               _ w: Int32, _ h: Int32, _ scn: Int32, _ dcn: Int32, _ swapRB: Int32)

// MARK: - Pixel container

/// Owned, tightly packed interleaved pixel buffer (BGR / BGRA / gray order, OpenCV conventions).
final class IOMat {
    var width: Int
    var height: Int
    var channels: Int
    var depth: SRDepth
    var bytes: [UInt8]

    init(width: Int, height: Int, channels: Int, depth: SRDepth) {
        self.width = width
        self.height = height
        self.channels = channels
        self.depth = depth
        self.bytes = [UInt8](repeating: 0, count: width * height * channels * depth.bytes)
    }

    var rowBytes: Int { width * channels * depth.bytes }
    var pixelBytes: Int { channels * depth.bytes }
}

/// Handle handed to Python: either a decoded image or an encoded byte buffer.
final class IOBlob {
    var mat: IOMat?
    var buffer: [UInt8] = []
    var rawPtr: UnsafeMutablePointer<UInt8>?
    var rawCount: Int = 0
    deinit {
        if let rawPtr { free(rawPtr) }
    }
}

// MARK: - Decode

private let ioFlagColor: Int32 = 1 | 256  // IMREAD_COLOR_BGR | IMREAD_COLOR_RGB (the R/B swap itself happens in Python)
private let ioFlagAnyDepth: Int32 = 2
private let ioFlagAnyColor: Int32 = 4
private let ioFlagIgnoreOrientation: Int32 = 128

private func ioSourceIsJPEG(_ src: CGImageSource) -> Bool {
    (CGImageSourceGetType(src) as String?) == "public.jpeg"
}

/// Read the raw (un-colour-converted) pixels of a CGImage as BGR / BGRA / gray.
func ioExtractNative(_ im: CGImage) -> IOMat? {
    let w = im.width, h = im.height
    guard w > 0, h > 0 else { return nil }
    let bpc = im.bitsPerComponent
    let bpp = im.bitsPerPixel
    let bpr = im.bytesPerRow
    let info = im.bitmapInfo.rawValue
    let alphaInfo = info & CGBitmapInfo.alphaInfoMask.rawValue
    let byteOrder = info & CGBitmapInfo.byteOrderMask.rawValue
    let isFloat = (info & CGBitmapInfo.floatComponents.rawValue) != 0
    let model = im.colorSpace?.model ?? .rgb
    guard let provider = im.dataProvider, let cfData = provider.data, let base = CFDataGetBytePtr(cfData) else {
        return nil
    }
    let dataLen = CFDataGetLength(cfData)
    guard dataLen >= bpr * (h - 1) + (w * bpp + 7) / 8 else { return ioRedrawNative(im) }

    let hasAlpha = !(alphaInfo == CGImageAlphaInfo.none.rawValue
                     || alphaInfo == CGImageAlphaInfo.noneSkipFirst.rawValue
                     || alphaInfo == CGImageAlphaInfo.noneSkipLast.rawValue)
    let alphaFirst = alphaInfo == CGImageAlphaInfo.premultipliedFirst.rawValue
        || alphaInfo == CGImageAlphaInfo.first.rawValue
        || alphaInfo == CGImageAlphaInfo.noneSkipFirst.rawValue

    if model == .indexed {
        guard bpc == 8, bpp == 8, let cs = im.colorSpace else { return ioRedrawNative(im) }
        let table: [UInt8] = cs.colorTable ?? []
        let n = table.count / 3
        guard n > 0 else { return ioRedrawNative(im) }
        let out = IOMat(width: w, height: h, channels: 3, depth: .u8)
        out.bytes.withUnsafeMutableBufferPointer { o in
            for y in 0..<h {
                let s = base + y * bpr
                for x in 0..<w {
                    let idx = min(Int(s[x]), n - 1)
                    o[(y * w + x) * 3 + 0] = table[idx * 3 + 2]
                    o[(y * w + x) * 3 + 1] = table[idx * 3 + 1]
                    o[(y * w + x) * 3 + 2] = table[idx * 3 + 0]
                }
            }
        }
        return out
    }

    guard model == .monochrome || model == .rgb, bpc > 0, bpp % bpc == 0, bpp / bpc <= 4 else {
        return ioRedrawNative(im)
    }
    let comps = bpp / bpc
    let isGray = model == .monochrome
    if isGray ? !(comps == 1 || (comps == 2 && hasAlpha)) : !(comps == 3 || comps == 4) {
        return ioRedrawNative(im)
    }

    // Output channels: gray 1; gray+alpha -> BGRA (gray replicated, like cv2); RGB 3; RGBA 4.
    let outCh: Int
    if isGray { outCh = comps == 2 ? 4 : 1 } else { outCh = (comps == 4 && hasAlpha) ? 4 : 3 }

    switch (bpc, isFloat) {
    case (8, false):
        let out = IOMat(width: w, height: h, channels: outCh, depth: .u8)
        // Memory offsets of R,G,B,A inside one 4-byte pixel.
        var offs = [0, 1, 2, 3]
        if comps == 4 {
            var logical: [Int] = alphaFirst ? [3, 0, 1, 2] : [0, 1, 2, 3]  // component id per logical slot (R0 G1 B2 A3)
            if byteOrder == CGBitmapInfo.byteOrder32Little.rawValue { logical.reverse() }
            for (slot, comp) in logical.enumerated() { offs[comp] = slot }
        } else if comps == 2 {
            offs = alphaFirst ? [1, 1, 1, 0] : [0, 0, 0, 1]
            if byteOrder == CGBitmapInfo.byteOrder16Little.rawValue { offs = alphaFirst ? [0, 0, 0, 1] : [1, 1, 1, 0] }
        }
        out.bytes.withUnsafeMutableBufferPointer { o in
            let dstBase = o.baseAddress!
            if isGray && comps == 1 {
                for y in 0..<h { memcpy(dstBase + y * w, base + y * bpr, w) }
            } else if !isGray && comps == 3 && offs[0] == 0 && offs[1] == 1 && offs[2] == 2 {
                sr_io_cvt_swap_u8(base, bpr, dstBase, w * 3, Int32(w), Int32(h), 3, 3, 1)
            } else if !isGray && comps == 4 && offs[0] == 2 && offs[1] == 1 && offs[2] == 0 && offs[3] == 3 {
                if outCh == 4 {
                    for y in 0..<h { memcpy(dstBase + y * w * 4, base + y * bpr, w * 4) }
                } else {
                    sr_io_cvt_swap_u8(base, bpr, dstBase, w * 3, Int32(w), Int32(h), 4, 3, 0)
                }
            } else if !isGray && comps == 4 && offs[0] == 0 && offs[1] == 1 && offs[2] == 2 && offs[3] == 3 {
                sr_io_cvt_swap_u8(base, bpr, dstBase, w * outCh, Int32(w), Int32(h), 4, Int32(outCh), 1)
            } else {
                for y in 0..<h {
                    let s = base + y * bpr
                    let d = dstBase + y * w * outCh
                    for x in 0..<w {
                        let p = s + x * comps
                        switch (isGray, comps) {
                        case (true, 1): d[x] = p[0]
                        case (true, _):  // gray + alpha
                            let g = p[offs[0]]
                            d[x * 4] = g; d[x * 4 + 1] = g; d[x * 4 + 2] = g; d[x * 4 + 3] = p[offs[3]]
                        default:
                            d[x * outCh] = p[offs[2]]
                            d[x * outCh + 1] = p[offs[1]]
                            d[x * outCh + 2] = p[offs[0]]
                            if outCh == 4 { d[x * 4 + 3] = p[offs[3]] }
                        }
                    }
                }
            }
        }
        return out
    case (16, false):
        let out = IOMat(width: w, height: h, channels: outCh, depth: .u16)
        let bigEndian = byteOrder != CGBitmapInfo.byteOrder16Little.rawValue
        let alphaAt = alphaFirst ? 0 : comps - 1
        out.bytes.withUnsafeMutableBytes { raw in
            let o = raw.bindMemory(to: UInt16.self).baseAddress!
            for y in 0..<h {
                let s = base + y * bpr
                let d = o + y * w * outCh
                @inline(__always) func sample(_ x: Int, _ c: Int) -> UInt16 {
                    var v: UInt16 = 0
                    memcpy(&v, s + (x * comps + c) * 2, 2)
                    return bigEndian ? UInt16(bigEndian: v) : v
                }
                for x in 0..<w {
                    if isGray {
                        let g = sample(x, comps == 2 ? (alphaFirst ? 1 : 0) : 0)
                        if comps == 1 { d[x] = g } else {
                            d[x * 4] = g; d[x * 4 + 1] = g; d[x * 4 + 2] = g; d[x * 4 + 3] = sample(x, alphaAt)
                        }
                    } else {
                        let first = (comps == 4 && alphaFirst) ? 1 : 0
                        d[x * outCh] = sample(x, first + 2)
                        d[x * outCh + 1] = sample(x, first + 1)
                        d[x * outCh + 2] = sample(x, first)
                        if outCh == 4 { d[x * 4 + 3] = sample(x, alphaAt) }
                    }
                }
            }
        }
        return out
    case (32, true), (16, true):
        // float / half samples: gray (1), RGB (3) or RGBA (4, alpha kept as stored); order follows the alpha position
        guard isGray ? comps == 1 : (comps == 3 || comps == 4) else { return ioRedrawNative(im) }
        let half = bpc == 16
        let ch = isGray ? 1 : comps
        let out = IOMat(width: w, height: h, channels: ch, depth: .f32)
        let bigEndian = !half && byteOrder == CGBitmapInfo.byteOrder32Big.rawValue
        let first = (comps == 4 && alphaFirst) ? 1 : 0
        out.bytes.withUnsafeMutableBytes { raw in
            let o = raw.bindMemory(to: Float.self).baseAddress!
            if isGray && !half && !bigEndian && bpp == 32 {
                let rawDst = raw.baseAddress!
                for y in 0..<h { memcpy(rawDst + y * w * 4, base + y * bpr, w * 4) }
            } else {
                for y in 0..<h {
                    let s = base + y * bpr
                    @inline(__always) func sample(_ x: Int, _ c: Int) -> Float {
                        if half {
                            var v: UInt16 = 0
                            memcpy(&v, s + (x * comps + c) * 2, 2)
                            return Float(Float16(bitPattern: byteOrder == CGBitmapInfo.byteOrder16Big.rawValue ? UInt16(bigEndian: v) : v))
                        }
                        var v: UInt32 = 0
                        memcpy(&v, s + (x * comps + c) * 4, 4)
                        return Float(bitPattern: bigEndian ? UInt32(bigEndian: v) : v)
                    }
                    for x in 0..<w {
                        if isGray { o[y * w + x] = sample(x, 0) } else {
                            o[(y * w + x) * ch] = sample(x, first + 2)       // B
                            o[(y * w + x) * ch + 1] = sample(x, first + 1)   // G
                            o[(y * w + x) * ch + 2] = sample(x, first)       // R
                            if ch == 4 { o[(y * w + x) * 4 + 3] = sample(x, alphaFirst ? 0 : 3) }
                        }
                    }
                }
            }
        }
        return out
    default:
        return ioRedrawNative(im)
    }
}

/// Fallback for CMYK / Lab / exotic layouts: draw into an 8-bit RGBA context (a colour conversion is
/// unavoidable here; cv2 would also convert CMYK JPEGs).
private func ioRedrawNative(_ im: CGImage) -> IOMat? {
    let w = im.width, h = im.height
    let isGray = im.colorSpace?.model == .monochrome
    let cs = isGray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
    var buf = [UInt8](repeating: 0, count: w * h * (isGray ? 1 : 4))
    let bi: UInt32 = isGray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let ok: Bool = buf.withUnsafeMutableBytes { raw in
        guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * (isGray ? 1 : 4), space: cs, bitmapInfo: bi) else { return false }
        ctx.draw(im, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    guard ok else { return nil }
    let out = IOMat(width: w, height: h, channels: isGray ? 1 : 3, depth: .u8)
    if isGray { out.bytes = buf; return out }
    for i in 0..<(w * h) {
        out.bytes[i * 3] = buf[i * 4 + 2]
        out.bytes[i * 3 + 1] = buf[i * 4 + 1]
        out.bytes[i * 3 + 2] = buf[i * 4]
    }
    return out
}

// MARK: - Mat transforms

/// Which fixed-point gray formula OpenCV 5.1's imread uses, by decoder (measured against the reference).
private enum IOGrayKind {
    case libpng   // png: libpng rgb_to_gray, 15-bit weights 9797/19234/3737, no rounding (16-bit: +16384)
    case cv14     // bmp, tiff: 14-bit weights 4899/9617/1868, +8192
    case cv15     // webp, gif and cvtColor in 5.1: 15-bit weights 9798/19235/3735, +16384

    init(sourceType: String) {
        switch sourceType {
        case "public.png": self = .libpng
        case "com.microsoft.bmp", "public.tiff": self = .cv14
        default: self = .cv15
        }
    }
}

private func ioToGray(_ m: IOMat, kind: IOGrayKind) -> IOMat {
    if m.channels == 1 { return m }
    let out = IOMat(width: m.width, height: m.height, channels: 1, depth: m.depth)
    let n = m.width * m.height, ch = m.channels
    let wb: Int, wg: Int, wr: Int, shift: Int, rnd: Int
    switch kind {
    case .libpng: (wb, wg, wr, shift, rnd) = (3737, 19234, 9797, 15, m.depth == .u16 ? 16384 : 0)
    case .cv14: (wb, wg, wr, shift, rnd) = (1868, 9617, 4899, 14, 8192)
    case .cv15: (wb, wg, wr, shift, rnd) = (3735, 19235, 9798, 15, 16384)
    }
    switch m.depth {
    case .u8:
        m.bytes.withUnsafeBufferPointer { (s: UnsafeBufferPointer<UInt8>) -> Void in
            out.bytes.withUnsafeMutableBufferPointer { (d: inout UnsafeMutableBufferPointer<UInt8>) -> Void in
                for i in 0..<n {
                    let base: Int = i * ch
                    let bSum: Int = Int(s[base]) * wb
                    let gSum: Int = Int(s[base + 1]) * wg
                    let rSum: Int = Int(s[base + 2]) * wr
                    d[i] = UInt8((bSum + gSum + rSum + rnd) >> shift)
                }
            }
        }
    case .u16:
        m.bytes.withUnsafeBytes { (sr: UnsafeRawBufferPointer) -> Void in
            out.bytes.withUnsafeMutableBytes { (dr: UnsafeMutableRawBufferPointer) -> Void in
                let s: UnsafeBufferPointer<UInt16> = sr.bindMemory(to: UInt16.self)
                let d: UnsafeMutableBufferPointer<UInt16> = dr.bindMemory(to: UInt16.self)
                for i in 0..<n {
                    let base: Int = i * ch
                    let bSum: Int = Int(s[base]) * wb
                    let gSum: Int = Int(s[base + 1]) * wg
                    let rSum: Int = Int(s[base + 2]) * wr
                    d[i] = UInt16((bSum + gSum + rSum + rnd) >> shift)
                }
            }
        }
    default:
        return m
    }
    return out
}

func ioToColor3(_ m: IOMat) -> IOMat {
    if m.channels == 3 { return m }
    let out = IOMat(width: m.width, height: m.height, channels: 3, depth: m.depth)
    let n = m.width * m.height, ch = m.channels, eb = m.depth.bytes
    m.bytes.withUnsafeBufferPointer { s in
        out.bytes.withUnsafeMutableBufferPointer { d in
            for i in 0..<n {
                if ch == 1 {
                    for c in 0..<3 { for b in 0..<eb { d[(i * 3 + c) * eb + b] = s[i * eb + b] } }
                } else {
                    for k in 0..<(3 * eb) { d[i * 3 * eb + k] = s[i * ch * eb + k] }
                }
            }
        }
    }
    return out
}

/// BGR -> BGRA with an opaque alpha (4-channel input is returned unchanged).
func ioAddAlpha(_ m: IOMat) -> IOMat {
    if m.channels != 3 { return m }
    let out = IOMat(width: m.width, height: m.height, channels: 4, depth: m.depth)
    for i in 0..<(m.width * m.height) {
        out.bytes[i * 4] = m.bytes[i * 3]; out.bytes[i * 4 + 1] = m.bytes[i * 3 + 1]
        out.bytes[i * 4 + 2] = m.bytes[i * 3 + 2]; out.bytes[i * 4 + 3] = 255
    }
    return out
}

func ioDropAlpha(_ m: IOMat) -> IOMat {
    if m.channels != 4 { return m }
    return ioToColor3(m)
}

/// 16 -> 8 bit. PNG/gray: high byte (png_set_strip_16). Multi-channel TIFF: (v + 128) / 257 (OpenCV convertTo 1/257).
private func ioU16ToU8(_ m: IOMat, round257: Bool = false) -> IOMat {
    let out = IOMat(width: m.width, height: m.height, channels: m.channels, depth: .u8)
    let n = m.width * m.height * m.channels
    m.bytes.withUnsafeBytes { sr in
        let s = sr.bindMemory(to: UInt16.self)
        out.bytes.withUnsafeMutableBufferPointer { d in
            for i in 0..<n { d[i] = round257 ? UInt8((Int(s[i]) + 128) / 257) : UInt8(s[i] >> 8) }
        }
    }
    return out
}

/// EXIF orientation 1...8 applied to the pixels (TIFF/EXIF semantics, same as cv2's rotation helper).
private func ioApplyOrientation(_ m: IOMat, _ o: Int) -> IOMat {
    guard o >= 2 && o <= 8 else { return m }
    let swap = o >= 5
    let ow = swap ? m.height : m.width
    let oh = swap ? m.width : m.height
    let out = IOMat(width: ow, height: oh, channels: m.channels, depth: m.depth)
    let pb = m.pixelBytes
    m.bytes.withUnsafeBufferPointer { s in
        out.bytes.withUnsafeMutableBufferPointer { d in
            for y in 0..<m.height {
                for x in 0..<m.width {
                    var dx = x, dy = y
                    switch o {
                    case 2: dx = m.width - 1 - x
                    case 3: dx = m.width - 1 - x; dy = m.height - 1 - y
                    case 4: dy = m.height - 1 - y
                    case 5: dx = y; dy = x
                    case 6: dx = m.height - 1 - y; dy = x
                    case 7: dx = m.height - 1 - y; dy = m.width - 1 - x
                    default: dx = y; dy = m.width - 1 - x  // 8
                    }
                    let si = (y * m.width + x) * pb
                    let di = (dy * ow + dx) * pb
                    for k in 0..<pb { d[di + k] = s[si + k] }
                }
            }
        }
    }
    return out
}

/// Reduced decode. JPEG: box average over scale x scale blocks, ceil dims (libjpeg DCT scaling).
/// Others: OpenCV INTER_LINEAR_EXACT resize to floor(dim / scale).
private func ioReduce(_ m: IOMat, scale: Int, jpeg: Bool) -> IOMat {
    guard scale > 1, m.depth == .u8 else { return m }
    let ow = max(1, jpeg ? (m.width + scale - 1) / scale : m.width / scale)
    let oh = max(1, jpeg ? (m.height + scale - 1) / scale : m.height / scale)
    let ch = m.channels
    let out = IOMat(width: ow, height: oh, channels: ch, depth: .u8)
    m.bytes.withUnsafeBufferPointer { s in
        out.bytes.withUnsafeMutableBufferPointer { d in
            if jpeg {
                for oy in 0..<oh {
                    let y0 = oy * scale, y1 = min(m.height, y0 + scale)
                    for ox in 0..<ow {
                        let x0 = ox * scale, x1 = min(m.width, x0 + scale)
                        let cnt = (y1 - y0) * (x1 - x0)
                        for c in 0..<ch {
                            var acc = 0
                            for y in y0..<y1 { for x in x0..<x1 { acc += Int(s[(y * m.width + x) * ch + c]) } }
                            d[(oy * ow + ox) * ch + c] = UInt8((acc + cnt / 2) / cnt)
                        }
                    }
                }
            } else {
                let fx = Double(m.width) / Double(ow), fy = Double(m.height) / Double(oh)
                for oy in 0..<oh {
                    let sy = max(0.0, (Double(oy) + 0.5) * fy - 0.5)
                    let y0 = min(Int(sy), m.height - 1), y1 = min(y0 + 1, m.height - 1)
                    let wy = sy - Double(y0)
                    for ox in 0..<ow {
                        let sx = max(0.0, (Double(ox) + 0.5) * fx - 0.5)
                        let x0 = min(Int(sx), m.width - 1), x1 = min(x0 + 1, m.width - 1)
                        let wx = sx - Double(x0)
                        for c in 0..<ch {
                            let a = Double(s[(y0 * m.width + x0) * ch + c]), b = Double(s[(y0 * m.width + x1) * ch + c])
                            let cc = Double(s[(y1 * m.width + x0) * ch + c]), dd = Double(s[(y1 * m.width + x1) * ch + c])
                            let v = (a * (1 - wx) + b * wx) * (1 - wy) + (cc * (1 - wx) + dd * wx) * wy
                            d[(oy * ow + ox) * ch + c] = srSatU8(v)
                        }
                    }
                }
            }
        }
    }
    return out
}

/// True when the first IFD of a TIFF carries ExtraSamples (338) = 2 (unassociated alpha).
private func ioTIFFHasUnassociatedAlpha(_ data: Data) -> Bool {
    guard data.count > 16 else { return false }
    let b = [UInt8](data.prefix(min(data.count, 1 << 16)))
    let little = b[0] == 0x49
    func u16(_ o: Int) -> Int { o + 2 <= b.count ? (little ? Int(b[o]) | Int(b[o + 1]) << 8 : Int(b[o]) << 8 | Int(b[o + 1])) : -1 }
    func u32(_ o: Int) -> Int { o + 4 <= b.count ? (little ? u16(o) | u16(o + 2) << 16 : u16(o) << 16 | u16(o + 2)) : -1 }
    guard u16(2) == 42 else { return false }
    let ifd = u32(4)
    guard ifd > 0, ifd + 2 <= b.count else { return false }  // IFD beyond the first 64 KB: not inspected
    let n = u16(ifd)
    guard n > 0 else { return false }
    for i in 0..<n {
        let e = ifd + 2 + i * 12
        if u16(e) == 338 { return u16(e + 2) == 3 && u32(e + 4) >= 1 && u16(e + 8) == 2 }
    }
    return false
}

/// True for a paletted BMP (<= 8 bits) whose palette entries all have r == g == b (cv2's IsColorPalette() is false).
private func ioBMPHasGrayPalette(_ d: Data) -> Bool {
    guard d.count > 54 else { return false }
    let b = [UInt8](d.prefix(min(d.count, 1200)))
    func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
    let dib = u32(14)
    guard dib >= 40, b.count > 14 + dib, b[28] | (b[29] << 0) != 0 else { return false }
    let bpp = Int(b[28]) | Int(b[29]) << 8
    guard bpp > 0, bpp <= 8 else { return false }
    var colours = u32(46)
    if colours == 0 { colours = 1 << bpp }
    let start = 14 + dib
    guard start + colours * 4 <= b.count else { return false }
    for i in 0..<colours {
        let idx: Int = start + i * 4
        let b0: UInt8 = b[idx]
        let b1: UInt8 = b[idx + 1]
        let b2: UInt8 = b[idx + 2]
        if !(b0 == b1 && b1 == b2) { return false }
    }
    return true
}

/// `tooLarge` is set when the header claims more than CV_IO_MAX_IMAGE_PIXELS (2^30) pixels: cv2 raises for that, so
/// the caller reports an error instead of "not an image". Nothing is allocated for such a file.
func ioDecode(_ data: Data, flags: Int32, tooLarge: inout Bool, index: Int = 0) -> IOMat? {
    if index == 0 {
        if data.count >= 4, data.first == 0xFF {
            var jw: Int32 = 0, jh: Int32 = 0, jnf: Int32 = 0
            let probe = data.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 1 }
                return sr_jpeg_decode_baseline(base, data.count, &jw, &jh, &jnf, nil, 0, 0)
            }
            if probe == -2 { tooLarge = true; return nil }
            if probe == 0 {
                let unchanged = flags < 0
                let wantColor = !unchanged && (flags & ioFlagColor) != 0
                let wantAny = !unchanged && (flags & ioFlagAnyColor) != 0
                let outCh = Int(unchanged ? jnf : (wantColor ? 3 : (wantAny ? jnf : 1)))
                let m = IOMat(width: Int(jw), height: Int(jh), channels: outCh, depth: .u8)
                let rc = data.withUnsafeBytes { raw -> Int32 in
                    m.bytes.withUnsafeMutableBufferPointer { dst in
                        sr_jpeg_decode_baseline(raw.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                               nil, nil, nil, dst.baseAddress!, Int(jw) * outCh, Int32(outCh))
                    }
                }
                if rc == 0 {
                    if unchanged { return m }
                    let scale = (flags & 64) != 0 ? 8 : ((flags & 32) != 0 ? 4 : ((flags & 16) != 0 ? 2 : 1))
                    return ioReduce(m, scale: scale, jpeg: true)
                }
            }
        }
        if let own = ioDecodeOwn(data, tooLarge: &tooLarge) { return ioFinishOwn(own, flags: flags) }
        if tooLarge { return nil }
        // a file that claims one of the formats we parse ourselves but fails our (strict) parser is refused, not retried by ImageIO
        let h = [UInt8](data.prefix(3))
        if h.count == 3, (h[0] == 0x50 && ((h[1] >= 0x31 && h[1] <= 0x37) || h[1] == 0x66 || h[1] == 0x46) && (h[2] == 10 || h[2] == 32 || h[2] == 9 || h[2] == 13))
            || (h[0] == 0x23 && h[1] == 0x3F) || (h[0] == 0x59 && h[1] == 0xA6 && h[2] == 0x6A) { return nil }
    }
    let opts: [CFString: Any] = [kCGImageSourceShouldAllowFloat: true, kCGImageSourceShouldCache: false]
    var gifFrame: IOGifFrame?
    if index == 0, let (gw, gh) = ioGifCanvas(data) {
        if gw * gh > ioMaxImagePixels { tooLarge = true; return nil }
        switch ioGifFirstFrame(data) {
        case .frame(let g): gifFrame = g  // keeps the palette colour under transparent pixels, like cv2
        case .tooLarge: tooLarge = true; return nil
        case .corrupt: return nil
        case .unsupported: break
        }
    }
    var extracted: IOMat?
    var sourceKind = ""
    var frameCount = 0
    var orient = 1
    var isJpeg = false
    var sizeTooLarge = false
    autoreleasepool {
        guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary) else { return }
        frameCount = CGImageSourceGetCount(src)
        guard frameCount > index else { return }
        let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any]
        if let pw = props?[kCGImagePropertyPixelWidth] as? Int, let ph = props?[kCGImagePropertyPixelHeight] as? Int,
           pw * ph > ioMaxImagePixels {
            sizeTooLarge = true
            return
        }
        sourceKind = (CGImageSourceGetType(src) as String?) ?? ""
        isJpeg = sourceKind == "public.jpeg"
        if let o = props?[kCGImagePropertyOrientation] as? Int { orient = o }
        if let g = gifFrame {
            let gm = IOMat(width: g.width, height: g.height, channels: 4, depth: .u8)
            gm.bytes = g.bgra
            extracted = gm
        } else {
            guard let cg = CGImageSourceCreateImageAtIndex(src, index, opts as CFDictionary),
                  let native = ioExtractNative(cg) else { return }
            extracted = native
        }
    }
    if sizeTooLarge { tooLarge = true; return nil }
    guard var m = extracted else { return nil }

    let unchanged = flags < 0
    if sourceKind == "com.ilm.openexr-image", m.depth == .f32, m.channels == 4 {
        // ImageIO always exposes an alpha plane for EXR; a fully opaque one means the file is plain RGB (what cv2 returns)
        let opaque = m.bytes.withUnsafeBytes { raw -> Bool in
            let f = raw.bindMemory(to: Float.self)
            for i in 0..<(m.width * m.height) where f[i * 4 + 3] != 1.0 { return false }
            return true
        }
        if opaque { m = ioDropAlpha(m) }
    }
    if sourceKind == "com.microsoft.bmp", m.depth == .u8, m.channels == 3, ioBMPHasGrayPalette(data) {
        // cv2 reads an 8-bit BMP whose palette is a gray ramp as a single channel
        let g = IOMat(width: m.width, height: m.height, channels: 1, depth: .u8)
        for i in 0..<(m.width * m.height) { g.bytes[i] = m.bytes[i * 3] }
        m = g
    }
    if sourceKind == "public.tiff", m.depth == .u8, m.channels == 4, ioTIFFHasUnassociatedAlpha(data) {
        // cv2 reads such a TIFF through libtiff's RGBA path, which hands back premultiplied colour.
        m.bytes.withUnsafeMutableBufferPointer { p in
            for i in 0..<(m.width * m.height) {
                let a = Int(p[i * 4 + 3])
                for c in 0..<3 { p[i * 4 + c] = UInt8((Int(p[i * 4 + c]) * a + 127) / 255) }
            }
        }
    }
    if sourceKind == "com.compuserve.gif", m.depth == .u8 {
        var animatedOrTransparent = frameCount > 1
        if let g = gifFrame {
            animatedOrTransparent = g.frameCount > 1 || g.hasTransparency
        } else if m.channels == 4 {
            animatedOrTransparent = true
        }
        // IMREAD_UNCHANGED: BGRA for an animated or transparent GIF, BGR for a plain still one.
        if unchanged { m = animatedOrTransparent ? ioAddAlpha(m) : ioDropAlpha(m) }
    }
    if !unchanged {
        if m.depth == .f32 { return nil }  // cv2 refuses a float TIFF unless asked for IMREAD_UNCHANGED
        let isPNG = sourceKind == "public.png"
        let wantGray = (flags & ioFlagColor) == 0 && (flags & ioFlagAnyColor) == 0
        if m.depth == .u16 && (flags & ioFlagAnyDepth) == 0 {
            if isPNG && wantGray && m.channels >= 3 {
                m = ioU16ToU8(ioToGray(m, kind: .libpng))  // libpng converts to gray at 16 bits, then strips
            } else {
                m = ioU16ToU8(m, round257: sourceKind == "public.tiff" && m.channels >= 3)
            }
        }
        if (flags & ioFlagColor) != 0 {
            m = ioToColor3(m)
        } else if (flags & ioFlagAnyColor) != 0 {
            m = m.channels == 1 ? m : ioDropAlpha(m)
        } else {
            m = ioToGray(m, kind: IOGrayKind(sourceType: sourceKind))
        }
        if (flags & ioFlagIgnoreOrientation) == 0, orient != 1 {
            m = ioApplyOrientation(m, orient)
        }
        let scale = (flags & 64) != 0 ? 8 : ((flags & 32) != 0 ? 4 : ((flags & 16) != 0 ? 2 : 1))
        m = ioReduce(m, scale: scale, jpeg: isJpeg)
    }
    return m
}

/// Flag handling for the own decoders (PNM / Sun raster / HDR), mirroring the ImageIO branch above.
private func ioFinishOwn(_ own: IOOwnImage, flags: Int32) -> IOMat? {
    var m = own.mat
    if flags < 0 { return m }
    if m.depth == .f32 {
        // cv2 hands a float image (HDR / PFM) back as float only for IMREAD_ANYDEPTH; otherwise it is converted to 8 bit
        if (flags & ioFlagAnyDepth) == 0 { m = ioF32ToU8(m, scale: own.kind == "pfm" ? 1.0 : 255.0) }
    } else if m.depth == .u16 && (flags & ioFlagAnyDepth) == 0 {
        m = ioU16ToU8(m)
    }
    if (flags & ioFlagColor) != 0 {
        m = ioToColor3(m)
    } else if (flags & ioFlagAnyColor) != 0 {
        m = m.channels == 1 ? m : ioDropAlpha(m)
    } else {
        m = ioToGray(m, kind: own.kind == "bmp" ? .cv14 : .cv15)
    }
    let scale = (flags & 64) != 0 ? 8 : ((flags & 32) != 0 ? 4 : ((flags & 16) != 0 ? 2 : 1))
    return ioReduce(m, scale: scale, jpeg: false)
}

/// float [0,1] -> 8 bit with saturation (what cv2 does for a float HDR/PFM read without IMREAD_ANYDEPTH).
private func ioF32ToU8(_ m: IOMat, scale: Double) -> IOMat {
    let out = IOMat(width: m.width, height: m.height, channels: m.channels, depth: .u8)
    let n = m.width * m.height * m.channels
    m.bytes.withUnsafeBytes { s in
        for k in 0..<n { out.bytes[k] = srSatU8(Double(s.loadUnaligned(fromByteOffset: k * 4, as: Float.self)) * scale) }
    }
    return out
}

public typealias IOAllocCallback = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32) -> UnsafeMutableRawPointer?

/// Fast uncompressed single-strip/multi-strip little-endian Float32 grayscale TIFF reader directly into `dst`.
/// Returns 0 = decoded, 1 = fallback to ImageIO, -1 = tooLarge (> ioMaxImagePixels).
private func ioTryFastUncompressedF32TIFF(_ data: Data, _ flags: Int32,
                                          _ allocCb: IOAllocCallback, _ allocCtx: UnsafeMutableRawPointer?) -> Int32 {
    guard flags < 0, data.count >= 16 else { return 1 }
    return data.withUnsafeBytes { raw -> Int32 in
        guard let b = raw.bindMemory(to: UInt8.self).baseAddress else { return 1 }
        let n = data.count
        guard b[0] == 0x49 && b[1] == 0x49 && b[2] == 0x2A && b[3] == 0x00 else { return 1 }
        func u16(_ o: Int) -> Int {
            o + 2 <= n ? (Int(b[o]) | (Int(b[o + 1]) << 8)) : -1
        }
        func u32(_ o: Int) -> Int {
            o + 4 <= n ? (Int(b[o]) | (Int(b[o + 1]) << 8) | (Int(b[o + 2]) << 16) | (Int(b[o + 3]) << 24)) : -1
        }
        let ifd = u32(4)
        guard ifd >= 8, ifd + 2 <= n else { return 1 }
        let cnt = u16(ifd)
        guard cnt > 0, cnt <= 128, ifd + 2 + cnt * 12 + 4 <= n else { return 1 }
        var w = -1, h = -1, bps = 0, comp = 1, photo = 1, spp = 1, orient = 1, planar = 1, fmt = 1
        var stripOffType = 0, stripOffCnt = 0, stripOffVal = 0
        var stripByteType = 0, stripByteCnt = 0, stripByteVal = 0
        for i in 0..<cnt {
            let e = ifd + 2 + i * 12
            let tag = u16(e), typ = u16(e + 2), c = u32(e + 4), voff = u32(e + 8)
            func scalarVal() -> Int {
                if c != 1 { return -1 }
                if typ == 3 { return u16(e + 8) }
                if typ == 4 { return voff }
                return -1
            }
            switch tag {
            case 256: w = scalarVal()
            case 257: h = scalarVal()
            case 258: bps = scalarVal()
            case 259: comp = scalarVal()
            case 262: photo = scalarVal()
            case 273: stripOffType = typ; stripOffCnt = c; stripOffVal = voff
            case 274: orient = scalarVal()
            case 277: spp = scalarVal()
            case 279: stripByteType = typ; stripByteCnt = c; stripByteVal = voff
            case 284: planar = scalarVal()
            case 322, 323, 324, 325: return 1 // tiled TIFF -> ImageIO
            case 339: fmt = scalarVal()
            default: break
            }
        }
        guard w > 0, h > 0 else { return 1 }
        if w * h > ioMaxImagePixels { return -1 }
        guard bps == 32, comp == 1, spp == 1, fmt == 3, orient <= 1, planar <= 1, (photo == 0 || photo == 1) else { return 1 }
        guard stripOffCnt > 0, stripOffCnt == stripByteCnt else { return 1 }
        let dstBytes = w * h * 4
        if stripOffCnt == 1 {
            let off = stripOffVal, bc = stripByteVal
            guard off >= 0, bc >= dstBytes, off + dstBytes <= n else { return 1 }
            guard let dstRaw = allocCb(allocCtx, Int32(w), Int32(h), 1, SRDepth.f32.rawValue) else { return 1 }
            memcpy(dstRaw, b + off, dstBytes)
            return 0
        }
        let offElem = stripOffType == 3 ? 2 : (stripOffType == 4 ? 4 : 0)
        let bcElem = stripByteType == 3 ? 2 : (stripByteType == 4 ? 4 : 0)
        guard offElem > 0, bcElem > 0,
              stripOffVal >= 0, stripOffVal + stripOffCnt * offElem <= n,
              stripByteVal >= 0, stripByteVal + stripByteCnt * bcElem <= n else { return 1 }
        var totalCheck = 0
        for s in 0..<stripOffCnt {
            let off = offElem == 2 ? u16(stripOffVal + s * 2) : u32(stripOffVal + s * 4)
            let bc = bcElem == 2 ? u16(stripByteVal + s * 2) : u32(stripByteVal + s * 4)
            let cp = min(bc, dstBytes - totalCheck)
            guard off >= 0, cp >= 0, off + cp <= n else { return 1 }
            totalCheck += cp
            if totalCheck >= dstBytes { break }
        }
        guard totalCheck == dstBytes else { return 1 }
        guard let dstRaw = allocCb(allocCtx, Int32(w), Int32(h), 1, SRDepth.f32.rawValue) else { return 1 }
        var written = 0
        for s in 0..<stripOffCnt {
            let off = offElem == 2 ? u16(stripOffVal + s * 2) : u32(stripOffVal + s * 4)
            let bc = bcElem == 2 ? u16(stripByteVal + s * 2) : u32(stripByteVal + s * 4)
            let cp = min(bc, dstBytes - written)
            if cp > 0 {
                memcpy(dstRaw + written, b + off, cp)
                written += cp
            }
            if written >= dstBytes { break }
        }
        return 0
    }
}

private func ioTryExtractDirect(_ im: CGImage, _ sourceKind: String, _ flags: Int32, _ swapRBForPy: Bool,
                                _ allocCb: IOAllocCallback, _ allocCtx: UnsafeMutableRawPointer?) -> Bool {
    let w = im.width, h = im.height
    guard w > 0, h > 0 else { return false }
    let bpc = im.bitsPerComponent, bpp = im.bitsPerPixel, bpr = im.bytesPerRow
    let info = im.bitmapInfo.rawValue
    let alphaInfo = info & CGBitmapInfo.alphaInfoMask.rawValue
    let byteOrder = info & CGBitmapInfo.byteOrderMask.rawValue
    let isFloat = (info & CGBitmapInfo.floatComponents.rawValue) != 0
    let model = im.colorSpace?.model ?? .rgb
    guard model == .monochrome || model == .rgb, bpc > 0, bpp % bpc == 0, bpp / bpc <= 4 else { return false }
    let comps = bpp / bpc
    let isGray = model == .monochrome
    if isGray ? !(comps == 1 || (comps == 2 && alphaInfo != CGImageAlphaInfo.none.rawValue)) : !(comps == 3 || comps == 4) {
        return false
    }
    if sourceKind == "com.ilm.openexr-image" && isFloat && comps == 4 { return false }
    if sourceKind == "com.microsoft.bmp" && bpc == 8 && comps == 3 { return false }
    if sourceKind == "public.tiff" && bpc == 8 && comps == 4 { return false }
    if sourceKind == "com.compuserve.gif" { return false }
    guard let provider = im.dataProvider, let cfData = provider.data, let base = CFDataGetBytePtr(cfData) else { return false }
    let dataLen = CFDataGetLength(cfData)
    guard dataLen >= bpr * (h - 1) + (w * bpp + 7) / 8 else { return false }

    let hasAlpha = !(alphaInfo == CGImageAlphaInfo.none.rawValue
                     || alphaInfo == CGImageAlphaInfo.noneSkipFirst.rawValue
                     || alphaInfo == CGImageAlphaInfo.noneSkipLast.rawValue)
    let alphaFirst = alphaInfo == CGImageAlphaInfo.premultipliedFirst.rawValue
        || alphaInfo == CGImageAlphaInfo.first.rawValue
        || alphaInfo == CGImageAlphaInfo.noneSkipFirst.rawValue
    let unchanged = flags < 0
    let wantColor = !unchanged && (flags & ioFlagColor) != 0

    if bpc == 8 && !isFloat {
        var offs = [0, 1, 2, 3]
        if comps == 4 {
            var logical: [Int] = alphaFirst ? [3, 0, 1, 2] : [0, 1, 2, 3]
            if byteOrder == CGBitmapInfo.byteOrder32Little.rawValue { logical.reverse() }
            for (slot, comp) in logical.enumerated() { offs[comp] = slot }
        } else if isGray && comps == 2 {
            offs = alphaFirst ? [1, 1, 1, 0] : [0, 0, 0, 1]
            if byteOrder == CGBitmapInfo.byteOrder16Little.rawValue { offs = alphaFirst ? [0, 0, 0, 1] : [1, 1, 1, 0] }
        }
        let nativeCh = isGray ? (comps == 2 ? 4 : 1) : ((comps == 4 && hasAlpha) ? 4 : 3)
        if unchanged {
            guard !swapRBForPy else { return false }
            guard let dstRaw = allocCb(allocCtx, Int32(w), Int32(h), Int32(nativeCh), SRDepth.u8.rawValue) else { return false }
            let d = dstRaw.assumingMemoryBound(to: UInt8.self)
            if isGray && comps == 1 {
                for y in 0..<h { memcpy(d + y * w, base + y * bpr, w) }
                return true
            } else if !isGray && comps == 3 && offs[0] == 0 && offs[1] == 1 && offs[2] == 2 {
                sr_io_cvt_swap_u8(base, bpr, d, w * 3, Int32(w), Int32(h), 3, 3, 1)
                return true
            } else if !isGray && comps == 4 && offs[0] == 2 && offs[1] == 1 && offs[2] == 0 && offs[3] == 3 {
                if nativeCh == 4 {
                    for y in 0..<h { memcpy(d + y * w * 4, base + y * bpr, w * 4) }
                } else {
                    sr_io_cvt_swap_u8(base, bpr, d, w * 3, Int32(w), Int32(h), 4, 3, 0)
                }
                return true
            } else if !isGray && comps == 4 && offs[0] == 0 && offs[1] == 1 && offs[2] == 2 && offs[3] == 3 {
                sr_io_cvt_swap_u8(base, bpr, d, w * nativeCh, Int32(w), Int32(h), 4, Int32(nativeCh), 1)
                return true
            }
            return false
        }
        if wantColor && !isGray {
            guard let dstRaw = allocCb(allocCtx, Int32(w), Int32(h), 3, SRDepth.u8.rawValue) else { return false }
            let d = dstRaw.assumingMemoryBound(to: UInt8.self)
            if comps == 3 && offs[0] == 0 && offs[1] == 1 && offs[2] == 2 {
                sr_io_cvt_swap_u8(base, bpr, d, w * 3, Int32(w), Int32(h), 3, 3, swapRBForPy ? 0 : 1)
                return true
            } else if comps == 4 && offs[0] == 2 && offs[1] == 1 && offs[2] == 0 && offs[3] == 3 {
                sr_io_cvt_swap_u8(base, bpr, d, w * 3, Int32(w), Int32(h), 4, 3, swapRBForPy ? 1 : 0)
                return true
            } else if comps == 4 && offs[0] == 0 && offs[1] == 1 && offs[2] == 2 && offs[3] == 3 {
                sr_io_cvt_swap_u8(base, bpr, d, w * 3, Int32(w), Int32(h), 4, 3, swapRBForPy ? 0 : 1)
                return true
            }
            return false
        }
        return false
    }
    if unchanged && (bpc == 32 && isFloat) && isGray && comps == 1 && bpp == 32 && byteOrder != CGBitmapInfo.byteOrder32Big.rawValue {
        guard let dstRaw = allocCb(allocCtx, Int32(w), Int32(h), 1, SRDepth.f32.rawValue) else { return false }
        for y in 0..<h { memcpy(dstRaw + y * w * 4, base + y * bpr, w * 4) }
        return true
    }
    return false
}

@_cdecl("sr_io_decode_cb")
public func sr_io_decode_cb(_ buf: UnsafePointer<UInt8>?, _ len: Int, _ flags: Int32, _ index: Int32,
                            _ allocCb: IOAllocCallback?, _ allocCtx: UnsafeMutableRawPointer?) -> Int32 {
    guard let buf, len > 0, let allocCb else { return srFail(SRStatus.badArgument, "imdecode: empty buffer") }
    let idx = index < 0 ? 0 : Int(index)
    let wantRgbPy = flags >= 0 && (flags & 256) != 0
    let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: buf), count: len, deallocator: .none)
    if idx == 0 && len >= 16 && buf[0] == 0x49 && buf[1] == 0x49 && buf[2] == 0x2A && buf[3] == 0x00 && flags < 0 {
        let rcT = ioTryFastUncompressedF32TIFF(data, flags, allocCb, allocCtx)
        if rcT == 0 { return SRStatus.ok }
        if rcT < 0 { return srFail(SRStatus.badArgument, "imdecode: image is larger than CV_IO_MAX_IMAGE_PIXELS (2^30 pixels)") }
    }
    var tooLarge = false
    var handledDirect = false
    if idx == 0 && !(len >= 4 && buf[0] == 0xFF) && ioGifCanvas(data) == nil {
        let scale = flags < 0 ? 1 : ((flags & 64) != 0 ? 8 : ((flags & 32) != 0 ? 4 : ((flags & 16) != 0 ? 2 : 1)))
        if scale == 1 && (ioDecodeOwn(data, tooLarge: &tooLarge) == nil) && !tooLarge {
            let h3 = [UInt8](data.prefix(3))
            let isOwnMagic = h3.count == 3 && ((h3[0] == 0x50 && ((h3[1] >= 0x31 && h3[1] <= 0x37) || h3[1] == 0x66 || h3[1] == 0x46) && (h3[2] == 10 || h3[2] == 32 || h3[2] == 9 || h3[2] == 13))
                || (h3[0] == 0x23 && h3[1] == 0x3F) || (h3[0] == 0x59 && h3[1] == 0xA6 && h3[2] == 0x6A))
            if !isOwnMagic {
                let opts: [CFString: Any] = [kCGImageSourceShouldAllowFloat: true, kCGImageSourceShouldCache: false]
                autoreleasepool {
                    guard let src = CGImageSourceCreateWithData(data as CFData, opts as CFDictionary) else { return }
                    let fc = CGImageSourceGetCount(src)
                    guard fc > 0 else { return }
                    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
                    if let pw = props?[kCGImagePropertyPixelWidth] as? Int, let ph = props?[kCGImagePropertyPixelHeight] as? Int,
                       pw * ph > ioMaxImagePixels { tooLarge = true; return }
                    let sourceKind = (CGImageSourceGetType(src) as String?) ?? ""
                    let orient = (props?[kCGImagePropertyOrientation] as? Int) ?? 1
                    if flags >= 0 && orient != 1 && (flags & ioFlagIgnoreOrientation) == 0 { return }
                    guard let cg = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) else { return }
                    handledDirect = ioTryExtractDirect(cg, sourceKind, flags, wantRgbPy, allocCb, allocCtx)
                }
                if tooLarge { return srFail(SRStatus.badArgument, "imdecode: image is larger than CV_IO_MAX_IMAGE_PIXELS (2^30 pixels)") }
                if handledDirect { return SRStatus.ok }
            }
        }
    }
    tooLarge = false
    let m: IOMat? = autoreleasepool {
        ioDecode(data, flags: flags, tooLarge: &tooLarge, index: idx)
    }
    guard let m else {
        if tooLarge { return srFail(SRStatus.badArgument, "imdecode: image is larger than CV_IO_MAX_IMAGE_PIXELS (2^30 pixels)") }
        return srFail(SRStatus.unsupported, "imdecode: cannot decode image")
    }
    guard let dstRaw = allocCb(allocCtx, Int32(m.width), Int32(m.height), Int32(m.channels), m.depth.rawValue) else {
        return srFail(SRStatus.internalError, "imdecode: allocation callback failed")
    }
    if wantRgbPy && m.channels >= 3 && m.depth == .u8 {
        if m.channels == 3 || m.channels == 4 {
            m.bytes.withUnsafeBytes { s in
                sr_io_cvt_swap_u8(s.bindMemory(to: UInt8.self).baseAddress!, m.rowBytes,
                                  dstRaw.assumingMemoryBound(to: UInt8.self), m.rowBytes,
                                  Int32(m.width), Int32(m.height), Int32(m.channels), Int32(m.channels), 1)
            }
            return SRStatus.ok
        }
    }
    m.bytes.withUnsafeBytes { s in
        if !s.isEmpty { memcpy(dstRaw, s.baseAddress!, s.count) }
    }
    if wantRgbPy && m.channels >= 3 && m.depth != .u8 { return 1 } // tell Python to swap channels in NumPy for u16/f32
    return SRStatus.ok
}

@_cdecl("sr_io_decode")
public func sr_io_decode(_ buf: UnsafePointer<UInt8>?, _ len: Int, _ flags: Int32,
                         _ out: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard let buf, len > 0, let out else { return srFail(SRStatus.badArgument, "imdecode: empty buffer") }
    var tooLarge = false
    let m: IOMat? = autoreleasepool {
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: buf), count: len, deallocator: .none)
        return ioDecode(data, flags: flags, tooLarge: &tooLarge)
    }
    guard let m else {
        if tooLarge { return srFail(SRStatus.badArgument, "imdecode: image is larger than CV_IO_MAX_IMAGE_PIXELS (2^30 pixels)") }
        return srFail(SRStatus.unsupported, "imdecode: cannot decode image")
    }
    let blob = IOBlob()
    blob.mat = m
    out.pointee = Unmanaged.passRetained(blob).toOpaque()
    return SRStatus.ok
}

@_cdecl("sr_io_jpeg_probe")
public func sr_io_jpeg_probe(_ buf: UnsafePointer<UInt8>?, _ len: Int, _ flags: Int32,
                             _ outW: UnsafeMutablePointer<Int32>?, _ outH: UnsafeMutablePointer<Int32>?,
                             _ outCh: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let buf, len > 3, let outW, let outH, let outCh else { return 1 }
    if flags >= 0 && (flags & (16 | 32 | 64)) != 0 { return 1 }
    var w: Int32 = 0, h: Int32 = 0, nf: Int32 = 0
    let rc = sr_jpeg_decode_baseline(buf, len, &w, &h, &nf, nil, 0, 0)
    if rc == -2 { return srFail(SRStatus.badArgument, "imdecode: image is larger than CV_IO_MAX_IMAGE_PIXELS (2^30 pixels)") }
    if rc != 0 { return 1 }
    let unchanged = flags < 0
    let wantColor = !unchanged && (flags & ioFlagColor) != 0
    let wantAny = !unchanged && (flags & ioFlagAnyColor) != 0
    outW.pointee = w
    outH.pointee = h
    outCh.pointee = unchanged ? nf : (wantColor ? 3 : (wantAny ? nf : 1))
    return 0
}

@_cdecl("sr_io_jpeg_decode_into")
public func sr_io_jpeg_decode_into(_ buf: UnsafePointer<UInt8>?, _ len: Int, _ flags: Int32,
                                   _ dst: UnsafeMutablePointer<UInt8>?, _ dstStride: Int) -> Int32 {
    guard let buf, len > 3, let dst else { return 1 }
    var w: Int32 = 0, h: Int32 = 0, nf: Int32 = 0
    let probe = sr_jpeg_decode_baseline(buf, len, &w, &h, &nf, nil, 0, 0)
    if probe != 0 { return 1 }
    let unchanged = flags < 0
    let wantColor = !unchanged && (flags & ioFlagColor) != 0
    let wantAny = !unchanged && (flags & ioFlagAnyColor) != 0
    let outCh: Int32 = unchanged ? nf : (wantColor ? 3 : (wantAny ? nf : 1))
    let wantRgb = !unchanged && (flags & 256) != 0 && outCh == 3
    let wantCn: Int32 = wantRgb ? -3 : outCh
    return sr_jpeg_decode_baseline(buf, len, nil, nil, nil, dst, dstStride, wantCn)
}

/// out[0..3] = width, height, channels, depth code.
@_cdecl("sr_io_info")
public func sr_io_info(_ h: UnsafeMutableRawPointer?, _ out: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let h, let out else { return srFail(SRStatus.badArgument, "io_info: null") }
    let blob = Unmanaged<IOBlob>.fromOpaque(h).takeUnretainedValue()
    if let m = blob.mat {
        out[0] = Int32(m.width); out[1] = Int32(m.height); out[2] = Int32(m.channels); out[3] = m.depth.rawValue
    } else if blob.rawPtr != nil {
        out[0] = Int32(blob.rawCount); out[1] = 1; out[2] = 1; out[3] = 0
    } else {
        out[0] = Int32(blob.buffer.count); out[1] = 1; out[2] = 1; out[3] = 0
    }
    return SRStatus.ok
}

/// Copy the decoded pixels (or encoded bytes) into a caller buffer with the given row stride.
@_cdecl("sr_io_copy")
public func sr_io_copy(_ h: UnsafeMutableRawPointer?, _ dst: UnsafeMutableRawPointer?, _ stride: Int32) -> Int32 {
    guard let h, let dst else { return srFail(SRStatus.badArgument, "io_copy: null") }
    let blob = Unmanaged<IOBlob>.fromOpaque(h).takeUnretainedValue()
    if let m = blob.mat {
        guard Int(stride) >= m.rowBytes else { return srFail(SRStatus.badArgument, "io_copy: stride too small") }
        m.bytes.withUnsafeBytes { s in
            for y in 0..<m.height {
                memcpy(dst + y * Int(stride), s.baseAddress! + y * m.rowBytes, m.rowBytes)
            }
        }
    } else if let p = blob.rawPtr {
        if blob.rawCount > 0 { memcpy(dst, p, blob.rawCount) }
    } else {
        blob.buffer.withUnsafeBytes { s in if s.count > 0 { memcpy(dst, s.baseAddress!, s.count) } }
    }
    return SRStatus.ok
}

@_cdecl("sr_io_free")
public func sr_io_free(_ h: UnsafeMutableRawPointer?) {
    guard let h else { return }
    Unmanaged<IOBlob>.fromOpaque(h).release()
}

// MARK: - Encode

/// Build a CGImage over a copy of the source in RGB(A)/gray order. Result keeps the source colour
/// numbers untouched (device colour spaces, so ImageIO has nothing to convert).
func ioMakeCGImage(_ img: SRImage, uti: String) -> CGImage? {
    let w = img.width, h = img.height, ch = img.channels
    var depth = img.depth
    // cv2 falls back to 8 bits when the encoder cannot do the depth (jpeg: only u8; png: u8/u16; tiff: u8/u16/f32).
    let allowed: [SRDepth]
    switch uti {
    case "public.jpeg", "com.compuserve.gif", "public.avif", "public.heic": allowed = [.u8]
    case "public.png", "public.jpeg-2000": allowed = [.u8, .u16]
    case "com.ilm.openexr-image": allowed = [.f32]
    default: allowed = [.u8, .u16, .f32]
    }
    if !allowed.contains(depth) { depth = .u8 }
    let keepAlpha = uti != "public.jpeg"
    let outCh: Int = ch == 1 ? 1 : (ch == 4 && keepAlpha ? 4 : 3)
    let isGray = outCh == 1
    let bpc = depth.bytes * 8
    let bytesPer = depth.bytes
    let rowBytes = w * outCh * bytesPer
    let totalBytes = max(1, rowBytes * h)
    guard let rawPtr = malloc(totalBytes) else { return nil }
    let o = rawPtr.assumingMemoryBound(to: UInt8.self)

    if depth == .u8 && img.depth == .u8 {
        let srcU8 = img.data.assumingMemoryBound(to: UInt8.self)
        if isGray && ch == 1 {
            for y in 0..<h { memcpy(o + y * rowBytes, srcU8 + y * img.stride, rowBytes) }
        } else if !isGray && (ch == 3 || ch == 4) && (outCh == 3 || outCh == 4) {
            sr_io_cvt_swap_u8(srcU8, img.stride, o, rowBytes, Int32(w), Int32(h), Int32(ch), Int32(outCh), 1)
        } else {
            for y in 0..<h {
                let s = UnsafeRawPointer(img.row(y))
                let d = rawPtr + y * rowBytes
                for x in 0..<w {
                    for c in 0..<outCh {
                        let sc = (!isGray && c < 3) ? 2 - c : c
                        d.storeBytes(of: s.load(fromByteOffset: x * ch + sc, as: UInt8.self), toByteOffset: x * outCh + c, as: UInt8.self)
                    }
                }
            }
        }
    } else {
        @inline(__always) func readU8(_ p: UnsafeRawPointer, _ k: Int) -> UInt8 {
            switch img.depth {
            case .u8: return p.load(fromByteOffset: k, as: UInt8.self)
            case .u16: return UInt8(p.loadUnaligned(fromByteOffset: k * 2, as: UInt16.self) >> 8)
            case .f32: return srSatU8(Double(p.loadUnaligned(fromByteOffset: k * 4, as: Float.self)))
            case .s32: return srSatU8(Double(p.loadUnaligned(fromByteOffset: k * 4, as: Int32.self)))
            }
        }
        for y in 0..<h {
            let s = UnsafeRawPointer(img.row(y))
            let d = rawPtr + y * rowBytes
            for x in 0..<w {
                for c in 0..<outCh {
                    let sc = (!isGray && c < 3) ? 2 - c : c
                    let k = x * ch + sc
                    switch depth {
                    case .u8: d.storeBytes(of: readU8(s, k), toByteOffset: x * outCh + c, as: UInt8.self)
                    case .u16:
                        let v = s.loadUnaligned(fromByteOffset: k * 2, as: UInt16.self)
                        d.storeBytes(of: v, toByteOffset: (x * outCh + c) * 2, as: UInt16.self)
                    default:
                        let v = s.loadUnaligned(fromByteOffset: k * 4, as: UInt32.self)
                        d.storeBytes(of: v, toByteOffset: (x * outCh + c) * 4, as: UInt32.self)
                    }
                }
            }
        }
    }
    var bi: UInt32 = outCh == 4 ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.none.rawValue
    if depth == .f32 { bi |= CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue }
    else if depth == .u16 { bi |= CGBitmapInfo.byteOrder16Little.rawValue }
    // EXR stores linear light: hand ImageIO linear spaces so the float values are written as they are (no colour conversion)
    var cs = isGray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
    if uti == "com.ilm.openexr-image", let lin = CGColorSpace(name: isGray ? CGColorSpace.extendedLinearGray : CGColorSpace.extendedLinearSRGB) { cs = lin }
    guard let provider = CGDataProvider(dataInfo: rawPtr, data: rawPtr, size: totalBytes,
                                        releaseData: { _, p, _ in free(UnsafeMutableRawPointer(mutating: p)) }) else {
        free(rawPtr)
        return nil
    }
    return CGImage(width: w, height: h, bitsPerComponent: bpc, bitsPerPixel: bpc * outCh, bytesPerRow: rowBytes,
                   space: cs, bitmapInfo: CGBitmapInfo(rawValue: bi), provider: provider, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)
}

/// Tightly packed 8-bit copy of any supported source (16-bit keeps the high byte, float saturates, like cv2's 8-bit fallback).
private func ioEncodeJPEGAnyDepth(_ img: SRImage, _ opts: JPEGOptions) -> [UInt8]? {
    if img.depth == .u8 { return ioEncodeJPEG(img, opts) }  // already 8-bit: read in place
    let ch = img.channels, w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * ch)
    buf.withUnsafeMutableBytes { o in
        for y in 0..<h {
            let s = UnsafeRawPointer(img.row(y))
            for k in 0..<(w * ch) {
                let v: UInt8
                switch img.depth {
                case .u8: v = s.load(fromByteOffset: k, as: UInt8.self)
                case .u16: v = UInt8(s.loadUnaligned(fromByteOffset: k * 2, as: UInt16.self) >> 8)
                case .f32: v = srSatU8(Double(s.loadUnaligned(fromByteOffset: k * 4, as: Float.self)))
                case .s32: v = srSatU8(Double(s.loadUnaligned(fromByteOffset: k * 4, as: Int32.self)))
                }
                o[y * w * ch + k] = v
            }
        }
    }
    return buf.withUnsafeMutableBytes { raw -> [UInt8]? in
        guard let tight = SRImage(raw.baseAddress, Int32(w), Int32(h), Int32(w * ch), Int32(ch), SRDepth.u8.rawValue) else { return nil }
        return ioEncodeJPEG(tight, opts)
    }
}

/// Uncompressed little-endian RGBA TIFF (u8 or u16). The bytes written are exactly the caller's channel values (no
/// premultiplying), tagged ExtraSamples = 1 ("associated alpha") the way OpenCV tags them. That tag is deliberate:
/// cv2 5.1 re-reads an 8-bit ExtraSamples = 2 file by premultiplying the colour (measured), so writing 2 would not
/// round-trip through the reference; with 1 it does, bit for bit, for 8 and 16 bit. ImageIO is not used for 4-channel
/// TIFFs because it premultiplies on write and loses the colour under transparent pixels.
private func ioEncodeTIFFRGBA(_ img: SRImage) -> [UInt8] {
    let w = img.width, h = img.height, eb = img.depth.bytes
    let dataSize = w * h * 4 * eb
    var out = [UInt8]()
    out.reserveCapacity(dataSize + 200)
    func u16(_ v: Int) { out += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    func u32(_ v: Int) { out += [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
    out += [0x49, 0x49, 42, 0]
    u32(8 + dataSize + 8)  // IFD follows the pixel data and the 8-byte BitsPerSample array
    for y in 0..<h {
        let s = UnsafeRawPointer(img.row(y))
        for x in 0..<w {
            for c in [2, 1, 0, 3] {  // BGRA -> RGBA
                if eb == 1 { out.append(s.load(fromByteOffset: x * 4 + c, as: UInt8.self)) }
                else { u16(Int(s.loadUnaligned(fromByteOffset: (x * 4 + c) * 2, as: UInt16.self))) }
            }
        }
    }
    for _ in 0..<4 { u16(eb * 8) }  // BitsPerSample array at 8 + dataSize
    let bitsOffset = 8 + dataSize
    let entries: [(Int, Int, Int, Int)] = [  // tag, type (3 SHORT, 4 LONG), count, value/offset
        (256, 4, 1, w), (257, 4, 1, h), (258, 3, 4, bitsOffset), (259, 3, 1, 1), (262, 3, 1, 2), (273, 4, 1, 8),
        (277, 3, 1, 4), (278, 4, 1, h), (279, 4, 1, dataSize), (284, 3, 1, 1), (338, 3, 1, 1),
    ]
    u16(entries.count)
    for (tag, type, count, value) in entries { u16(tag); u16(type); u32(count); u32(value) }
    u32(0)
    return out
}

/// IMWRITE_JPEG_* -> options (cv2 semantics: the sampling factor must be one of the five documented values).
func ioJPEGOptions(_ p: IOParams) -> JPEGOptions? {
    var o = JPEGOptions()
    o.quality = max(0, min(100, p.get(1, 95)))
    o.progressive = p.get(2, 0) != 0
    o.optimize = p.get(3, 0) != 0
    o.rstInterval = max(0, min(65535, p.get(4, 0)))
    o.lumaQuality = p.has(5) ? max(0, min(100, p.get(5, -1))) : -1
    o.chromaQuality = p.has(6) ? max(0, min(100, p.get(6, -1))) : -1
    // cv2: separate luma/chroma qualities switch the encoder to 4:4:4 (libjpeg-turbo default 4:2:0 otherwise); an explicit factor wins
    if o.lumaQuality >= 0 && o.chromaQuality >= 0 { o.hSamp = 1; o.vSamp = 1 }
    if p.has(7) && !o.setSampling(p.get(7, 0x221111)) { return nil }
    return o
}

/// Encoded formats cv2 5.1 / Safarium can write, by extension.
enum IOWriteKind { case jpeg, png, bmp, pnm, sunRaster, hdr, tiff, jp2, exr, avif, heic, gif, webp }

func ioWriteKind(_ ext: String) -> IOWriteKind? {
    switch ext.lowercased() {
    case ".jpg", ".jpeg", ".jpe", ".jfif": return .jpeg
    case ".png": return .png
    case ".bmp", ".dib": return .bmp
    case ".pbm", ".pgm", ".ppm", ".pnm", ".pxm", ".pam", ".pfm": return .pnm
    case ".sr", ".ras": return .sunRaster
    case ".hdr", ".pic": return .hdr
    case ".tif", ".tiff": return .tiff
    case ".jp2", ".j2k": return .jp2
    case ".exr": return .exr
    case ".avif": return .avif
    case ".heic", ".heif": return .heic
    case ".gif": return .gif
    case ".webp": return .webp
    default: return nil
    }
}

private func ioUTI(_ k: IOWriteKind) -> String? {
    switch k {
    case .jpeg: return "public.jpeg"
    case .png: return "public.png"
    case .tiff: return "public.tiff"
    case .jp2: return "public.jpeg-2000"
    case .exr: return "com.ilm.openexr-image"
    case .avif: return "public.avif"
    case .heic: return "public.heic"
    case .gif: return "com.compuserve.gif"
    default: return nil
    }
}

/// The whole image as 32-bit float (u8 / 255, u16 / 65535) for the float-only writers.
func ioToF32Image(_ img: SRImage) -> (bytes: [UInt8], image: (Int, Int, Int)) {
    let w = img.width, h = img.height, ch = img.channels
    var out = [UInt8](repeating: 0, count: w * h * ch * 4)
    let row = UnsafeMutablePointer<Float>.allocate(capacity: w * ch + 4)
    defer { row.deallocate() }
    out.withUnsafeMutableBytes { o in
        for y in 0..<h {
            ioRowF32(img, y, row)
            memcpy(o.baseAddress! + y * w * ch * 4, row, w * ch * 4)
        }
    }
    return (out, (w, h, ch))
}

/// 16-bit half-float gray / RGB(A) CGImage in a linear colour space (for EXR half output).
private func ioMakeHalfCGImage(_ img: SRImage) -> CGImage? {
    let w = img.width, h = img.height, ch = img.channels
    guard ch != 2 else { return nil }
    let outCh = ch == 1 ? 1 : (ch == 4 ? 4 : 3)
    var buf = [UInt16](repeating: 0, count: w * h * outCh)
    let row = UnsafeMutablePointer<Float>.allocate(capacity: w * ch + 4)
    defer { row.deallocate() }
    for y in 0..<h {
        ioRowF32(img, y, row)
        for x in 0..<w {
            for c in 0..<outCh {
                let sc = (outCh >= 3 && c < 3) ? 2 - c : c
                buf[(y * w + x) * outCh + c] = Float16(row[x * ch + sc]).bitPattern
            }
        }
    }
    guard let lin = CGColorSpace(name: outCh == 1 ? CGColorSpace.extendedLinearGray : CGColorSpace.extendedLinearSRGB),
          let provider = CGDataProvider(data: Data(bytes: buf, count: buf.count * 2) as CFData) else { return nil }
    let bi: UInt32 = (outCh == 4 ? CGImageAlphaInfo.last.rawValue : CGImageAlphaInfo.none.rawValue)
        | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
    return CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 16 * outCh, bytesPerRow: w * outCh * 2,
                   space: lin, bitmapInfo: CGBitmapInfo(rawValue: bi), provider: provider, decode: nil,
                   shouldInterpolate: false, intent: .defaultIntent)
}

func ioEncode(_ img: SRImage, ext: String, quality: Int, pngLevel: Int = 1) -> [UInt8]? {
    var kv: [Int32] = [1, Int32(quality), 16, Int32(pngLevel)]
    return kv.withUnsafeMutableBufferPointer { ioEncodeAny(img, ext: ext, params: IOParams($0.baseAddress, $0.count)) }
}

func ioEncodeAny(_ img: SRImage, ext: String, params p: IOParams) -> [UInt8]? {
    guard let kind = ioWriteKind(ext) else { return nil }
    switch kind {
    case .jpeg:
        guard let o = ioJPEGOptions(p) else { return nil }
        return ioEncodeJPEGAnyDepth(img, o)
    case .png:
        if img.channels == 1 || img.channels == 3 || img.channels == 4, img.depth == .u8 || img.depth == .u16,
           let png = ioEncodePNG(img, params: p) { return png }  // own writer
    case .bmp: return ioEncodeBMP(img, p)
    case .pnm: return ioEncodePNM(img, ext: ext, p)
    case .sunRaster: return ioEncodeSunRaster(img)
    case .hdr: return ioEncodeHDR(img, p)
    case .webp:
        // IMWRITE_WEBP_QUALITY > 100 or IMWRITE_WEBP_LOSSLESS_MODE on = lossless
        if p.get(64, 95) > 100 || p.get(65, 0) >= 1 { return ioEncodeWebPLossless(img, quality: p.get(64, 101) > 100 ? 100 : p.get(64, 100)) }
        return ioEncodeWebPLossy(img, p)
    case .tiff:
        if let t = ioEncodeTIFF([img], p) { return t }   // own writer: none / deflate (+ predictors)
        if ioTIFFTooLarge { return nil }
        if img.channels == 4, img.depth == .u8 || img.depth == .u16 { return ioEncodeTIFFRGBA(img) }
    case .exr: if let e = ioEncodeEXR(img, p) { return e }
    case .gif:
        if ioGifParamsAreDefault(p) { return ioEncodeGIF([img], delaysCs: [100], loop: 0) }   // own writer (cv2 default settings); nil = cv2 refuses
    case .jp2, .avif, .heic: break
    }
    guard let uti = ioUTI(kind) else { return nil }
    return autoreleasepool {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, uti as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [:]
        var source = img
        var holder: [UInt8] = []
        switch kind {
        case .jp2:
            let rate = Double(max(1, p.get(272, 1000))) / 1000.0   // IMWRITE_JPEG2000_COMPRESSION_X1000: target compression ratio x1000
            props[kCGImageDestinationLossyCompressionQuality] = min(1.0, 1.0 / rate)
        case .avif, .heic:
            props[kCGImageDestinationLossyCompressionQuality] = Double(max(0, min(100, p.get(512, 95)))) / 100.0
        case .exr:
            if p.get(48, 2) == 1 {   // IMWRITE_EXR_TYPE_HALF
                guard let cg = ioMakeHalfCGImage(img) else { return nil }
                CGImageDestinationAddImage(dest, cg, props as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { return nil }
                return [UInt8](out as Data)
            }
            if img.depth != .f32 {
                let f = ioToF32Image(img)
                holder = f.bytes
            }
        case .tiff:
            var tiff: [CFString: Any] = [:]
            let comp = p.get(259, 5)
            if [1, 5, 32773, 8, 32946].contains(comp) { tiff[kCGImagePropertyTIFFCompression] = comp == 32946 ? 8 : comp }
            props[kCGImagePropertyTIFFDictionary] = tiff
        default: break
        }
        if !holder.isEmpty {
            return holder.withUnsafeMutableBytes { raw -> [UInt8]? in
                guard let s = SRImage(raw.baseAddress, Int32(img.width), Int32(img.height), Int32(img.width * img.channels * 4),
                                      Int32(img.channels), SRDepth.f32.rawValue) else { return nil }
                source = s
                guard let cg = ioMakeCGImage(source, uti: uti) else { return nil }
                CGImageDestinationAddImage(dest, cg, props as CFDictionary)
                guard CGImageDestinationFinalize(dest) else { return nil }
                return [UInt8](out as Data)
            }
        }
        guard let cg = ioMakeCGImage(source, uti: uti) else { return nil }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return [UInt8](out as Data)
    }
}

/// ext includes the leading dot (".png"). quality is the IMWRITE_JPEG_QUALITY value (0...100). Kept for the old Python wrapper.
@_cdecl("sr_io_encode")
public func sr_io_encode(_ data: UnsafeMutableRawPointer?, _ width: Int32, _ height: Int32, _ stride: Int32,
                         _ channels: Int32, _ depth: Int32, _ ext: UnsafePointer<CChar>?, _ quality: Int32, _ pngLevel: Int32,
                         _ out: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    var kv: [Int32] = [1, quality, 16, pngLevel]
    return kv.withUnsafeMutableBufferPointer {
        sr_io_encode2(data, width, height, stride, channels, depth, ext, $0.baseAddress, Int32($0.count), out)
    }
}

/// Encode with the full IMWRITE_* parameter list (`params` = key, value, key, value, ... as int32).
@_cdecl("sr_io_encode2")
public func sr_io_encode2(_ data: UnsafeMutableRawPointer?, _ width: Int32, _ height: Int32, _ stride: Int32,
                          _ channels: Int32, _ depth: Int32, _ ext: UnsafePointer<CChar>?,
                          _ params: UnsafePointer<Int32>?, _ nparams: Int32,
                          _ out: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard let img = SRImage(data, width, height, stride, channels, depth), let ext, let out, width > 0, height > 0 else {
        return srFail(SRStatus.badArgument, "imencode: bad image")
    }
    let e = String(cString: ext)
    guard let kind = ioWriteKind(e) else { return srFail(SRStatus.unsupported, "imencode: could not find a writer for the specified extension '\(e)'") }
    let p = IOParams(params, Int(nparams))
    if kind == .jpeg {
        guard let opts = ioJPEGOptions(p) else {
            return srFail(SRStatus.badArgument, "imencode: unsupported IMWRITE_JPEG_SAMPLING_FACTOR")
        }
        if img.depth == .u8, let raw = ioEncodeJPEGRaw(img, opts) {
            let blob = IOBlob()
            blob.rawPtr = raw.ptr
            blob.rawCount = raw.count
            out.pointee = Unmanaged.passRetained(blob).toOpaque()
            return SRStatus.ok
        }
    }
    if kind == .webp && !ioWebPValidDimensions(img.width, img.height) {
        return srFail(SRStatus.badArgument, ioWebPLimitError)
    }
    guard let bytes = ioEncodeAny(img, ext: e, params: p) else {
        return srFail(SRStatus.ioFailure, "imencode: encoder failed")
    }
    let blob = IOBlob()
    blob.buffer = bytes
    out.pointee = Unmanaged.passRetained(blob).toOpaque()
    return SRStatus.ok
}
