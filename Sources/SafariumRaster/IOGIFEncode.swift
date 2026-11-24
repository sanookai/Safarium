// SafariumRaster — own GIF writer (Area C), the default settings of OpenCV 5.1's GIF encoder (IMWRITE_GIF_QUALITY 2).
//
// Measured against the reference wheel (see tests/test_parity_io.py):
//   * one global 256-colour table, fixed "3-3-2" palette: index = R3 << 5 | G3 << 2 | B2 with R, G in steps of 36 and
//     B in steps of 85;
//   * Floyd-Steinberg error diffusion (7/16, 3/16, 5/16, 1/16, left to right on every row), nearest level per channel;
//   * BGRA input: only alpha == 0 is transparent. It becomes palette index 146, drops out of the error diffusion, and a
//     colour pixel that would land on 146 is written as 142 instead; any other alpha counts as opaque;
//   * 1-channel input is refused (OpenCV asserts in its dithering kernel); u16 / s32 / f32 samples are saturate_cast to 8 bit;
//   * GIF89a, NETSCAPE2.0 loop block, one Graphic Control Extension per frame (disposal 3), full-canvas frames, LZW with
//     8-bit minimum code size.
// Other qualities / dither modes / colour-table sizes are not implemented here: callers fall back to ImageIO for them.

import Foundation

/// IMWRITE_GIF_* keys (OpenCV 5.1): loop 1024, speed 1025, quality 1026, dither 1027, transparency 1028, colortable 1029.
private let gifParamKeys = [1024, 1025, 1026, 1027, 1028, 1029]

/// True when the parameter list asks for what the default encoder does (no GIF key, or QUALITY 2 / COLORTABLE any).
func ioGifParamsAreDefault(_ p: IOParams) -> Bool {
    for k in gifParamKeys where p.has(k) {
        switch k {
        case 1026: if p.get(k, 2) != 2 { return false }
        case 1029: break
        case 1024, 1025: break   // "not functional since 4.12": loop / delay come from the Animation
        default: return false
        }
    }
    return true
}

private let gifTransparentIndex = 146
private let gifTransparentSubstitute = 142

/// Reads one source pixel's channel as an 8-bit value (saturate_cast for the wider depths).
@inline(__always) private func gifSample(_ img: SRImage, _ row: UnsafeRawPointer, _ k: Int) -> Int {
    switch img.depth {
    case .u8: return Int(row.load(fromByteOffset: k, as: UInt8.self))
    case .u16: return Int(srSatU8(Double(row.loadUnaligned(fromByteOffset: k * 2, as: UInt16.self))))
    case .f32: return Int(srSatU8(Double(row.loadUnaligned(fromByteOffset: k * 4, as: Float.self))))
    case .s32: return Int(srSatU8(Double(row.loadUnaligned(fromByteOffset: k * 4, as: Int32.self))))
    }
}

/// Palette indices for one frame (w * h bytes) and whether any pixel is transparent.
private func gifQuantise(_ img: SRImage, transparent: Bool) -> [UInt8] {
    let w = img.width, h = img.height, ch = img.channels
    var out = [UInt8](repeating: 0, count: w * h)
    let rowLen = (w + 2) * 3
    var bufA = [Float](repeating: 0, count: rowLen)
    var bufB = [Float](repeating: 0, count: rowLen)
    out.withUnsafeMutableBufferPointer { o in
        bufA.withUnsafeMutableBufferPointer { a in
            bufB.withUnsafeMutableBufferPointer { b in
                var curP = a.baseAddress!, nxtP = b.baseAddress!
                for y in 0..<h {
                    let row = UnsafeRawPointer(img.row(y))
                    for x in 0..<w {
                        if ch == 4 && gifSample(img, row, x * 4 + 3) == 0 {
                            o[y * w + x] = UInt8(gifTransparentIndex)
                            continue
                        }
                        var q = 0
                        var e: (Float, Float, Float) = (0, 0, 0)
                        for c in 0..<3 {
                            let v = Float(gifSample(img, row, x * ch + (2 - c))) + curP[(x + 1) * 3 + c]
                            let step: Float = c == 2 ? 85 : 36
                            let top = c == 2 ? 3 : 7
                            var i = Int((v / step + 0.5).rounded(.down))
                            if i < 0 { i = 0 } else if i > top { i = top }
                            let err = v - Float(i) * step
                            switch c {
                            case 0: e.0 = err; q = i << 5
                            case 1: e.1 = err; q |= i << 2
                            default: e.2 = err; q |= i
                            }
                        }
                        // a colour pixel that quantises onto the transparent index is written as its neighbour (cv2)
                        o[y * w + x] = UInt8(transparent && q == gifTransparentIndex ? gifTransparentSubstitute : q)
                        let ev = (e.0, e.1, e.2)
                        curP[(x + 2) * 3] += ev.0 * 7 / 16; curP[(x + 2) * 3 + 1] += ev.1 * 7 / 16; curP[(x + 2) * 3 + 2] += ev.2 * 7 / 16
                        nxtP[x * 3] += ev.0 * 3 / 16; nxtP[x * 3 + 1] += ev.1 * 3 / 16; nxtP[x * 3 + 2] += ev.2 * 3 / 16
                        nxtP[(x + 1) * 3] += ev.0 * 5 / 16; nxtP[(x + 1) * 3 + 1] += ev.1 * 5 / 16; nxtP[(x + 1) * 3 + 2] += ev.2 * 5 / 16
                        nxtP[(x + 2) * 3] += ev.0 / 16; nxtP[(x + 2) * 3 + 1] += ev.1 / 16; nxtP[(x + 2) * 3 + 2] += ev.2 / 16
                    }
                    swap(&curP, &nxtP)
                    nxtP.update(repeating: 0, count: rowLen)
                }
            }
        }
    }
    return out
}

// MARK: - LZW

/// GIF LZW (8-bit symbols): clear code first, 9...12-bit codes, table reset when it is full, data in 255-byte sub-blocks.
private func gifLZW(_ idx: [UInt8]) -> [UInt8] {
    let clear = 256, eoi = 257
    var out = [UInt8]()
    out.reserveCapacity(idx.count / 2 + 64)
    var block = [UInt8](); block.reserveCapacity(255)
    var acc: UInt32 = 0, nbits = 0
    func flushBlock() {
        if block.isEmpty { return }
        out.append(UInt8(block.count)); out.append(contentsOf: block); block.removeAll(keepingCapacity: true)
    }
    func emit(_ code: Int, _ size: Int) {
        acc |= UInt32(code) << UInt32(nbits); nbits += size
        while nbits >= 8 {
            block.append(UInt8(acc & 0xFF)); acc >>= 8; nbits -= 8
            if block.count == 255 { flushBlock() }
        }
    }
    // open-addressing table: key = prefix << 8 | byte (+1 so 0 means empty)
    let tabSize = 1 << 14
    var keys = [UInt32](repeating: 0, count: tabSize), vals = [UInt16](repeating: 0, count: tabSize)
    var next = 258, size = 9
    func resetTable() { for i in 0..<tabSize { keys[i] = 0 }; next = 258; size = 9 }
    emit(clear, size)
    if idx.isEmpty { emit(eoi, size); if nbits > 0 { block.append(UInt8(acc & 0xFF)) }; flushBlock(); out.append(0); return out }
    var prefix = Int(idx[0])
    for n in 1..<idx.count {
        let k = Int(idx[n])
        let key = UInt32(prefix << 8 | k) + 1
        var h = Int((key &* 2654435761) >> 18) & (tabSize - 1)
        var found = -1
        while keys[h] != 0 {
            if keys[h] == key { found = Int(vals[h]); break }
            h = (h + 1) & (tabSize - 1)
        }
        if found >= 0 { prefix = found; continue }
        emit(prefix, size)
        if next < 4095 {   // OpenCV stops adding one entry early: clear after 3839 codes
            keys[h] = key; vals[h] = UInt16(next); next += 1
            if next - 1 == (1 << size) && size < 12 { size += 1 }
        } else {
            emit(clear, size)
            resetTable()
        }
        prefix = k
    }
    emit(prefix, size)
    emit(eoi, size)
    if nbits > 0 { block.append(UInt8(acc & 0xFF)) }
    flushBlock()
    out.append(0)
    return out
}

// MARK: - container

/// Encode `frames` (all the same size) as a GIF; `delaysCs` in centiseconds (one per frame); loop 0 = forever, N = cv2's loop_count.
/// Returns nil for input OpenCV refuses (1-channel, mixed sizes) or cannot represent.
func ioEncodeGIF(_ frames: [SRImage], delaysCs: [Int], loop: Int) -> [UInt8]? {
    guard let f0 = frames.first, f0.width > 0, f0.height > 0, f0.width < 65536, f0.height < 65536 else { return nil }
    for f in frames where f.width != f0.width || f.height != f0.height || f.channels == 1 || f.channels == 2 { return nil }
    var out = [UInt8]()
    func put16(_ v: Int) { out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF)) }
    out.append(contentsOf: Array("GIF89a".utf8))
    put16(f0.width); put16(f0.height)
    out.append(0xF7); out.append(0); out.append(0)
    // transparency anywhere flags every frame; palette entry 146 then carries the colour of the last transparent pixel
    var transparent = false
    var lastTransparentRGB: (UInt8, UInt8, UInt8) = (0, 0, 0)
    for f in frames where f.channels == 4 {
        for y in 0..<f.height {
            let row = UnsafeRawPointer(f.row(y))
            for x in 0..<f.width where gifSample(f, row, x * 4 + 3) == 0 {
                transparent = true
                lastTransparentRGB = (UInt8(gifSample(f, row, x * 4 + 2)), UInt8(gifSample(f, row, x * 4 + 1)), UInt8(gifSample(f, row, x * 4)))
            }
        }
    }
    for i in 0..<256 {
        if transparent && i == gifTransparentIndex {
            out.append(lastTransparentRGB.0); out.append(lastTransparentRGB.1); out.append(lastTransparentRGB.2)
        } else {
            out.append(UInt8((i >> 5) * 36)); out.append(UInt8(((i >> 2) & 7) * 36)); out.append(UInt8((i & 3) * 85))
        }
    }
    if loop != 1 {   // loop_count 1 = play once: no NETSCAPE block at all
        out.append(contentsOf: [0x21, 0xFF, 0x0B]); out.append(contentsOf: Array("NETSCAPE2.0".utf8))
        out.append(contentsOf: [0x03, 0x01]); put16(loop > 0 ? (loop - 1) & 0xFFFF : 0); out.append(0)   // cv2 writes loop_count - 1 repeats; 0 = forever
    }
    for (n, f) in frames.enumerated() {
        let idx = gifQuantise(f, transparent: transparent)
        out.append(contentsOf: [0x21, 0xF9, 0x04, transparent ? 0x0D : 0x0C])
        put16(max(0, min(65535, n < delaysCs.count ? delaysCs[n] : 100)))
        out.append(UInt8(transparent ? gifTransparentIndex : 0)); out.append(0)
        out.append(0x2C); put16(0); put16(0); put16(f.width); put16(f.height); out.append(0x07)
        out.append(8)
        out.append(contentsOf: gifLZW(idx))
    }
    out.append(0x3B)
    return out
}

/// Multi-frame / animation entry for the Python shim. Same arguments as sr_io_encode_multi; `delaysMs` nil = 100 centiseconds
/// per frame (cv2 imwritemulti), otherwise milliseconds / 10 (cv2 Animation durations).
/// Returns 0 on success, 1 when the request is not the default GIF encoder's (the caller uses the generic ImageIO path),
/// SRStatus.ioFailure when OpenCV would refuse the input (1-channel, frames of different sizes).
@_cdecl("sr_io_encode_gif")
public func sr_io_encode_gif(_ n: Int32, _ datas: UnsafePointer<UnsafeMutableRawPointer?>?, _ widths: UnsafePointer<Int32>?,
                             _ heights: UnsafePointer<Int32>?, _ strides: UnsafePointer<Int32>?, _ channels: UnsafePointer<Int32>?,
                             _ depths: UnsafePointer<Int32>?, _ delaysMs: UnsafePointer<Int32>?, _ loop: Int32,
                             _ params: UnsafePointer<Int32>?, _ nparams: Int32,
                             _ out: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard n > 0, let datas, let widths, let heights, let strides, let channels, let depths, let out else {
        return srFail(SRStatus.badArgument, "imencodemulti: bad arguments")
    }
    guard ioGifParamsAreDefault(IOParams(params, Int(nparams))) else { return 1 }
    var list: [SRImage] = []
    for i in 0..<Int(n) {
        guard let im = SRImage(datas[i], widths[i], heights[i], strides[i], channels[i], depths[i]) else {
            return srFail(SRStatus.badArgument, "imencodemulti: bad image \(i)")
        }
        list.append(im)
    }
    let delays = (0..<Int(n)).map { i in delaysMs.map { Int($0[i]) / 10 } ?? 100 }
    guard let bytes = ioEncodeGIF(list, delaysCs: delays, loop: Int(loop)) else {
        return srFail(SRStatus.ioFailure, "imencodemulti: the GIF encoder cannot encode these images")
    }
    let blob = IOBlob()
    blob.buffer = bytes
    out.pointee = Unmanaged.passRetained(blob).toOpaque()
    return SRStatus.ok
}
