// SafariumRaster — minimal GIF first-frame decoder (Area C).
//
// ImageIO hands back GIF frames premultiplied, which turns every transparent pixel into black and loses the palette
// colour underneath. OpenCV 5.1 keeps the palette colour and marks the pixel with alpha 0, so imread of a GIF that has
// a transparent colour is decoded here: palette lookup + LZW (GIF89a spec), first frame, full-canvas images only
// (anything else returns nil and the caller falls back to ImageIO).

import Foundation

struct IOGifFrame {
    var width: Int
    var height: Int
    var bgra: [UInt8]          // 4 channels, palette colour kept under transparent pixels (alpha 0 there)
    var hasTransparency: Bool  // the graphic-control extension of frame 0 declares a transparent colour
    var frameCount: Int
}

/// Same limit as OpenCV's CV_IO_MAX_IMAGE_PIXELS default (2^30): larger images are refused before any allocation.
let ioMaxImagePixels = 1 << 30

enum IOGifParse {
    case frame(IOGifFrame)
    case unsupported   // not something this parser handles (sub-rect frame, odd structure): let ImageIO try
    case tooLarge      // canvas over the pixel cap
    case corrupt       // the LZW payload cannot possibly fill the claimed canvas
}

func ioGifFirstFrame(_ data: Data) -> IOGifParse {
    let b = [UInt8](data)
    guard b.count > 13, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 else { return .unsupported }
    func u16(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
    let cw = u16(6), ch = u16(8)
    let packed = b[10]
    var pos = 13
    var globalTable: [UInt8] = []
    if packed & 0x80 != 0 {
        let n = 3 * (2 << Int(packed & 7))
        guard pos + n <= b.count else { return .unsupported }
        globalTable = Array(b[pos..<(pos + n)])
        pos += n
    }
    var transparentIndex = -1
    var firstFrame: IOGifFrame?
    var frames = 0

    func skipSubBlocks(_ p: inout Int) -> Bool {
        while p < b.count {
            let n = Int(b[p]); p += 1
            if n == 0 { return true }
            p += n
        }
        return false
    }

    while pos < b.count {
        let tag = b[pos]; pos += 1
        if tag == 0x3B { break }
        if tag == 0x21 {
            guard pos < b.count else { return .unsupported }
            let label = b[pos]; pos += 1
            if label == 0xF9, pos + 5 < b.count, b[pos] == 4 {
                transparentIndex = (b[pos + 1] & 1) != 0 ? Int(b[pos + 4]) : -1
            }
            guard skipSubBlocks(&pos) else { return .unsupported }
            continue
        }
        guard tag == 0x2C, pos + 9 <= b.count else { return .unsupported }
        let left = u16(pos), top = u16(pos + 2), w = u16(pos + 4), h = u16(pos + 6)
        let ip = b[pos + 8]
        pos += 9
        frames += 1
        var table = globalTable
        if ip & 0x80 != 0 {
            let n = 3 * (2 << Int(ip & 7))
            guard pos + n <= b.count else { return .unsupported }
            table = Array(b[pos..<(pos + n)])
            pos += n
        }
        guard pos < b.count else { return .unsupported }
        let minCode = Int(b[pos]); pos += 1
        var lz = [UInt8]()
        while pos < b.count {
            let n = Int(b[pos]); pos += 1
            if n == 0 { break }
            guard pos + n <= b.count else { return .unsupported }
            lz.append(contentsOf: b[pos..<(pos + n)])
            pos += n
        }
        if frames > 1 { continue }  // only counting further frames
        guard left == 0, top == 0, w == cw, h == ch, w > 0, h > 0, !table.isEmpty, minCode >= 1, minCode <= 11 else {
            return .unsupported
        }
        if w * h > ioMaxImagePixels { return .tooLarge }
        // n LZW codes can expand to at most 4096 pixels each: a payload that cannot reach w*h is truncated/crafted.
        let maxCodes = lz.count * 8 / (minCode + 1) + 1
        if w * h > maxCodes * 4096 { return .corrupt }
        guard let idx = ioGifLZW(lz, minCode: minCode, count: w * h) else { return .corrupt }
        // de-interlace
        var rows = Array(0..<h)
        if ip & 0x40 != 0 {
            rows = []
            for (start, step) in [(0, 8), (4, 8), (2, 4), (1, 2)] { rows += Array(stride(from: start, to: h, by: step)) }
        }
        var out = [UInt8](repeating: 255, count: w * h * 4)
        let tn = table.count / 3
        let bgIndex = Int(b[11])
        let bgTable = globalTable.isEmpty ? table : globalTable
        for (srcRow, dstRow) in rows.enumerated() {
            for x in 0..<w {
                let i = Int(idx[srcRow * w + x])
                let o = (dstRow * w + x) * 4
                let transparent = i == transparentIndex
                // cv2 (measured on 5.1) shows the logical screen's background colour under a transparent pixel.
                let c = transparent ? min(bgIndex, bgTable.count / 3 - 1) : min(i, tn - 1)
                let src = transparent ? bgTable : table
                out[o] = src[c * 3 + 2]; out[o + 1] = src[c * 3 + 1]; out[o + 2] = src[c * 3]
                out[o + 3] = transparent ? 0 : 255
            }
        }
        firstFrame = IOGifFrame(width: w, height: h, bgra: out, hasTransparency: transparentIndex >= 0, frameCount: 1)
    }
    guard var f = firstFrame else { return .unsupported }
    f.frameCount = frames
    return .frame(f)
}

/// GIF variable-width LZW. Returns `count` palette indices (missing data stays 0).
private func ioGifLZW(_ data: [UInt8], minCode: Int, count: Int) -> [UInt8]? {
    let clear = 1 << minCode, eoi = clear + 1
    var prefix = [Int](repeating: 0, count: 4096)
    var suffix = [UInt8](repeating: 0, count: 4096)
    var length = [Int](repeating: 0, count: 4096)
    for i in 0..<clear { suffix[i] = UInt8(truncatingIfNeeded: i); length[i] = 1 }
    var out = [UInt8](repeating: 0, count: count)
    var o = 0
    var codeSize = minCode + 1
    var next = eoi + 1
    var prev = -1
    var acc = 0, bits = 0, p = 0
    var tmp = [UInt8](repeating: 0, count: 4097)
    while o < count {
        while bits < codeSize {
            guard p < data.count else { return o > 0 ? out : nil }
            acc |= Int(data[p]) << bits; p += 1; bits += 8
        }
        let code = acc & ((1 << codeSize) - 1)
        acc >>= codeSize; bits -= codeSize
        if code == clear { codeSize = minCode + 1; next = eoi + 1; prev = -1; continue }
        if code == eoi { break }
        if prev < 0 {
            guard code < clear else { return nil }
            out[o] = suffix[code]; o += 1
            prev = code
            continue
        }
        guard code <= next else { return nil }
        // string(code), or string(prev) + first(prev) for the not-yet-defined code (KwKwK)
        let expandFrom = code < next ? code : prev
        var n = length[expandFrom]
        var c = expandFrom
        var i = n
        while i > 0 { i -= 1; tmp[i] = suffix[c]; c = prefix[c] }
        let first = tmp[0]
        if code == next { tmp[n] = first; n += 1 }
        for k in 0..<n where o < count { out[o] = tmp[k]; o += 1 }
        if next < 4096 {
            prefix[next] = prev; suffix[next] = first; length[next] = length[prev] + 1
            next += 1
            if next == (1 << codeSize), codeSize < 12 { codeSize += 1 }
        }
        prev = code
    }
    return out
}

/// Logical-screen size from a GIF header (nil when the data is not a GIF).
func ioGifCanvas(_ data: Data) -> (Int, Int)? {
    guard data.count > 10, data[data.startIndex] == 0x47, data[data.startIndex + 1] == 0x49, data[data.startIndex + 2] == 0x46 else { return nil }
    let o = data.startIndex
    return (Int(data[o + 6]) | Int(data[o + 7]) << 8, Int(data[o + 8]) | Int(data[o + 9]) << 8)
}
