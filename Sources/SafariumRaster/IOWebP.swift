// SafariumRaster — own WebP writer (Area C): VP8L lossless bitstream + RIFF container + animation (VP8X/ANIM/ANMF).
// The VP8L encoder core is Sources/SafariumRasterC/webp_ll.c (per the public WebP Lossless Bitstream Specification:
// subtract-green / predictor / cross-colour / palette transforms, cost-based LZ77, colour cache, meta prefix codes).
// This file converts the image to ARGB, calls the core and wraps the result (RIFF, VP8X alpha, animation).

import Foundation

@_silgen_name("sr_vp8l_encode")
private func sr_vp8l_encode(_ argb: UnsafePointer<UInt32>, _ w: Int32, _ h: Int32, _ hasAlpha: Int32, _ quality: Int32,
                            _ out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>) -> Int64

@_silgen_name("sr_vp8_free")
private func sr_vp8_free_ll(_ p: UnsafeMutablePointer<UInt8>?)

let ioWebPLimitError = "WebP dimensions exceed 14-bit limit (max 16383x16383 and 2^27 pixels)"

func ioWebPValidDimensions(_ width: Int, _ height: Int) -> Bool {
    width > 0 && height > 0 && width <= 16383 && height <= 16383 && Int64(width) * Int64(height) <= (1 << 27)
}

/// VP8L bitstream for a BGR(A) image (any depth, converted to 8 bit). The encoder core is Sources/SafariumRasterC/webp_ll.c.
func ioWebPLosslessBitstream(_ img: SRImage, quality: Int) -> (bytes: [UInt8], hasAlpha: Bool)? {
    let w = img.width, h = img.height
    guard ioWebPValidDimensions(w, h), img.channels != 2 else { return nil }
    let ch = img.channels
    let px = UnsafeMutablePointer<UInt32>.allocate(capacity: w * h)
    defer { px.deallocate() }
    let row = UnsafeMutablePointer<UInt8>.allocate(capacity: w * ch + 8)
    defer { row.deallocate() }
    var hasAlpha = false
    for y in 0..<h {
        ioRowU8(img, y, row)
        let o = px + y * w
        switch ch {
        case 1: for x in 0..<w { let g = UInt32(row[x]); o[x] = 0xFF00_0000 | g << 16 | g << 8 | g }
        case 3: for x in 0..<w { o[x] = 0xFF00_0000 | UInt32(row[x * 3 + 2]) << 16 | UInt32(row[x * 3 + 1]) << 8 | UInt32(row[x * 3]) }
        default:
            for x in 0..<w {
                let a = UInt32(row[x * 4 + 3])
                if a != 255 { hasAlpha = true }
                o[x] = a << 24 | UInt32(row[x * 4 + 2]) << 16 | UInt32(row[x * 4 + 1]) << 8 | UInt32(row[x * 4])
            }
        }
    }
    var out: UnsafeMutablePointer<UInt8>? = nil
    let n = sr_vp8l_encode(px, Int32(w), Int32(h), hasAlpha ? 1 : 0, Int32(quality), &out)
    guard n > 0, let out else { return nil }
    defer { sr_vp8_free_ll(out) }
    return (Array(UnsafeBufferPointer(start: out, count: Int(n))), hasAlpha)
}

private func riffChunk(_ tag: String, _ body: [UInt8]) -> [UInt8] {
    var o = Array(tag.utf8)
    let n = body.count
    o += [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)]
    o += body
    if n & 1 == 1 { o.append(0) }
    return o
}

private func riffWrap(_ payload: [UInt8]) -> [UInt8] {
    let n = payload.count + 4
    return Array("RIFF".utf8) + [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)] + Array("WEBP".utf8) + payload
}

/// Lossless still image (quality only steers the LZ77 effort: the output is always exact).
func ioEncodeWebPLossless(_ img: SRImage, quality: Int) -> [UInt8]? {
    guard let (bs, _) = ioWebPLosslessBitstream(img, quality: quality) else { return nil }
    return riffWrap(riffChunk("VP8L", bs))
}

/// Animated WebP of lossless frames: delays in ms, loop 0 = forever, background BGRA colour (0 = transparent black).
func ioEncodeWebPAnimation(_ frames: [SRImage], delaysMs: [Int], loop: Int, quality: Int) -> [UInt8]? {
    guard let f0 = frames.first, frames.allSatisfy({ ioWebPValidDimensions($0.width, $0.height) }) else { return nil }
    let cw = f0.width, chh = f0.height
    var body: [UInt8] = []
    var anyAlpha = false
    var chunks: [UInt8] = []
    func u24(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF)] }
    for (i, f) in frames.enumerated() {
        guard let (bs, a) = ioWebPLosslessBitstream(f, quality: quality) else { return nil }
        if a { anyAlpha = true }
        let d = i < delaysMs.count ? delaysMs[i] : 100
        let fb = riffChunk("VP8L", bs)
        var anmf: [UInt8] = []
        anmf.append(contentsOf: u24(0))
        anmf.append(contentsOf: u24(0))
        anmf.append(contentsOf: u24(f.width - 1))
        anmf.append(contentsOf: u24(f.height - 1))
        anmf.append(contentsOf: u24(d))
        anmf.append(0x02)
        anmf.append(contentsOf: fb)
        chunks += riffChunk("ANMF", anmf)   // blend off? 0x02 = do not blend, no dispose
    }
    body += riffChunk("VP8X", [UInt8(0x02 | (anyAlpha ? 0x10 : 0)), 0, 0, 0] + u24(cw - 1) + u24(chh - 1))
    body += riffChunk("ANIM", [0, 0, 0, 0] + [UInt8(loop & 0xFF), UInt8((loop >> 8) & 0xFF)])
    body += chunks
    return riffWrap(body)
}

private func wpRiff(_ payload: [UInt8]) -> [UInt8] { riffWrap(payload) }

/// Lossy still image. Alpha (if any) goes into an ALPH chunk (raw 8-bit plane, filter 0).
func ioEncodeWebPLossy(_ img: SRImage, _ p: IOParams) -> [UInt8]? {
    let q = max(0, min(100, p.get(64, 95)))
    guard let vp8 = ioWebPLossyBitstream(img, quality: q) else { return nil }
    if img.channels != 4 { return riffWrap(riffChunk("VP8 ", vp8)) }
    var alpha = [UInt8](repeating: 0, count: img.width * img.height + 1)   // header byte + plane
    var any = false
    let row = UnsafeMutablePointer<UInt8>.allocate(capacity: img.width * 4 + 8)
    defer { row.deallocate() }
    for y in 0..<img.height {
        ioRowU8(img, y, row)
        for x in 0..<img.width { let a = row[x * 4 + 3]; alpha[1 + y * img.width + x] = a; if a != 255 { any = true } }
    }
    if !any { return riffWrap(riffChunk("VP8 ", vp8)) }
    func u24(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF)] }
    var body = riffChunk("VP8X", [0x10, 0, 0, 0] + u24(img.width - 1) + u24(img.height - 1))
    // alpha as a lossless image (green channel, header-less VP8L stream) when that is smaller than the raw plane
    var plane = Array(alpha[1...])
    let packed = plane.withUnsafeMutableBytes { raw -> [UInt8]? in
        guard let g = SRImage(raw.baseAddress, Int32(img.width), Int32(img.height), Int32(img.width), 1, SRDepth.u8.rawValue),
              let (bs, _) = ioWebPLosslessBitstream(g, quality: 60) else { return nil }
        return [0x01] + Array(bs.dropFirst(5))
    }
    if let packed, packed.count < alpha.count { body += riffChunk("ALPH", packed) } else { body += riffChunk("ALPH", alpha) }
    body += riffChunk("VP8 ", vp8)
    return riffWrap(body)
}
