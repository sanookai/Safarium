// SafariumRaster — own TIFF writer (Area C): classic little-endian TIFF, any number of pages, 8/16-bit integer and 32-bit
// float samples, 1 / 3 / 4 channels (BGR(A) stored as RGB(A), ExtraSamples = 1 like OpenCV), strips of ~1 MB, and
//   * Compression 1 (none) or 8 / 32946 (Adobe Deflate, our own deflate engine),
//   * Predictor 2 (horizontal differencing) for integers, 3 (floating point: byte planes + differencing) for floats.
// OpenCV defaults to LZW with the horizontal predictor (and no compression for float); Deflate + predictor is typically
// 2-5x smaller, every libtiff-based reader understands it. LZW / PackBits requests still go through ImageIO.
// Float images default to Deflate level 1 (Pick 2026-11-24: ~4x smaller than cv2's uncompressed floats for a few ms); level 1 runs
// through the C engine in Sources/SafariumRasterC/deflate_fast.c (NEON float predictor + a zlib-level-1-class deflate), the
// denser levels (2-9, explicit IMWRITE_TIFF_COMPRESSION_LEVEL) keep the Swift engine.
// TIFF 6.0 + Adobe Photoshop Technical Note 3 (deflate) + Adobe Technical Note 3 (floating point predictor).

import Foundation

// Fast deflate (level 1) and the float-predictor kernel live in Sources/SafariumRasterC/deflate_fast.c.
@_silgen_name("sr_dstream_new")
private func sr_dstream_new() -> UnsafeMutableRawPointer?
@_silgen_name("sr_dstream_free")
private func sr_dstream_free(_ st: UnsafeMutableRawPointer?)
@_silgen_name("sr_dstream_rebase")
private func sr_dstream_rebase(_ st: UnsafeMutableRawPointer?, _ shift: Int64)
@_silgen_name("sr_dstream_feed")
private func sr_dstream_feed(_ st: UnsafeMutableRawPointer?, _ src: UnsafePointer<UInt8>?, _ start: Int64, _ len: Int64, _ final: Int32,
                             _ out: UnsafeMutablePointer<UInt8>?, _ cap: Int64, _ consumed: UnsafeMutablePointer<Int64>?) -> Int64
@_silgen_name("sr_deflate_bound")
private func sr_deflate_bound(_ n: Int64) -> Int64
@_silgen_name("sr_tiff_f32_predict_row")
private func sr_tiff_f32_predict_row(_ src: UnsafePointer<UInt8>, _ w: Int32, _ ch: Int32, _ swapRB: Int32,
                                     _ tmp: UnsafeMutablePointer<UInt8>, _ dst: UnsafeMutablePointer<UInt8>)

/// Images as (pointer view). Returns nil when a depth / channel layout is not supported by this writer.
/// Classic TIFF has 32-bit offsets. Test hook: SAFARIUM_TEST_TIFF_LIMIT lowers the limit so the refusal can be exercised cheaply.
private let ioTIFFLimit: Int = {
    if let v = ProcessInfo.processInfo.environment["SAFARIUM_TEST_TIFF_LIMIT"], let n = Int(v), n > 0 { return n }
    return 0xFFFF_0000
}()

/// Set when the last ioEncodeTIFF call returned nil because the file would not fit 32-bit offsets (callers must not retry elsewhere).
var ioTIFFTooLarge = false
/// Level-1 deflate input chunk (bytes of new samples per engine call); strips up to this size are coded in one call.
let ioTIFFChunkBytes = 8 << 20

func ioEncodeTIFF(_ imgs: [SRImage], _ p: IOParams) -> [UInt8]? {
    ioTIFFTooLarge = false
    guard !imgs.isEmpty else { return nil }
    let comp = p.get(259, 8)
    guard comp == 1 || comp == 8 || comp == 32946 else { return nil }
    var out = [UInt8](repeating: 0, count: 8)
    out[0] = 0x49; out[1] = 0x49; out[2] = 42
    var firstIFD = 0
    var patchNext = 0   // offset of the previous IFD's "next IFD" field
    func put16(_ v: Int) { out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF)) }
    func put32(_ v: Int) { put16(v & 0xFFFF); put16((v >> 16) & 0xFFFF) }
    func set32(_ at: Int, _ v: Int) {
        out[at] = UInt8(v & 0xFF); out[at + 1] = UInt8((v >> 8) & 0xFF); out[at + 2] = UInt8((v >> 16) & 0xFF); out[at + 3] = UInt8((v >> 24) & 0xFF)
    }
    func align() { if out.count & 1 == 1 { out.append(0) } }

    for img in imgs {
        let w = img.width, h = img.height, ch = img.channels
        guard (img.depth == .u8 || img.depth == .u16 || img.depth == .f32), w > 0, h > 0, ch == 1 || ch == 3 || ch == 4 else { return nil }
        let es = img.depth.bytes
        let rowBytes = w * ch * es
        guard rowBytes * h < Int(Int32.max) / 2 else { return nil }
        let isFloat = img.depth == .f32
        let predictor = comp == 1 ? 1 : p.get(317, isFloat ? 3 : 2)   // IMWRITE_TIFF_PREDICTOR (1 none, 2 horizontal, 3 floating point)
        guard predictor == 1 || (predictor == 2 && !isFloat) || (predictor == 3 && isFloat) else { return nil }
        let rps = max(1, min(h, p.get(278, max(1, (1 << 20) / max(1, rowBytes)))))   // IMWRITE_TIFF_ROWSPERSTRIP
        let nStrips = (h + rps - 1) / rps
        var offsets = [Int](), counts = [Int]()
        // IMWRITE_TIFF_COMPRESSION_LEVEL: floats default to 1 (Pick 2026-11-24: ~4x smaller than OpenCV's uncompressed floats at a fraction of the
        // cost of the denser levels), everything else to 3. Level 1 runs through the C engine one strip at a time.
        let level = max(1, min(9, p.get(260, isFloat ? 1 : 3)))
        let fast = comp != 1 && level == 1
        let row = UnsafeMutablePointer<UInt8>.allocate(capacity: rowBytes + 16)
        let tmp = UnsafeMutablePointer<UInt8>.allocate(capacity: 2 * rowBytes + 64)
        // Level 1 streams each strip through the C engine: the sample window holds at most `window` bytes of history plus
        // `chunkBytes` of new data (at least one row), so peak extra memory does not depend on the strip size. A strip that fits
        // one chunk (every default strip) is compressed in a single call, exactly as before.
        let window = 32768
        let chunkBytes = fast ? max(ioTIFFChunkBytes, rowBytes) : 0
        let sCap = fast ? min(rowBytes * rps, chunkBytes) + window + 64 : 0
        let sbuf = UnsafeMutablePointer<UInt8>.allocate(capacity: sCap + 16)
        let zcap = fast ? Int(sr_deflate_bound(Int64(sCap))) + 64 : 0
        let zbuf = UnsafeMutablePointer<UInt8>.allocate(capacity: zcap + 16)
        defer { row.deallocate(); tmp.deallocate(); sbuf.deallocate(); zbuf.deallocate() }
        var dstream: UnsafeMutableRawPointer? = nil   // one per strip (a strip is one zlib stream)
        defer { sr_dstream_free(dstream) }
        var fill = 0, hist = 0, adlerFrom = 0
        var adler: UInt32 = 1
        var stripBytes = 0
        /// Code what is buffered; `final` ends the zlib stream (adler32 trailer). Returns false when the engine refuses.
        func feed(final: Bool) -> Bool {
            var consumed: Int64 = 0
            let n = Int(sr_dstream_feed(dstream, sbuf, Int64(hist), Int64(fill), final ? 1 : 0, zbuf, Int64(zcap), &consumed))
            guard n >= 0 else { return false }
            adler = ioAdler32(adler, sbuf + adlerFrom, fill - adlerFrom)
            out.append(contentsOf: UnsafeBufferPointer(start: zbuf, count: n))
            stripBytes += n
            if final {
                out.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)])
                stripBytes += 4
                return true
            }
            let pos = hist + Int(consumed)
            let keepFrom = pos - min(pos, window)
            if keepFrom > 0 { memmove(sbuf, sbuf + keepFrom, fill - keepFrom); sr_dstream_rebase(dstream, Int64(keepFrom)) }
            fill -= keepFrom
            hist = pos - keepFrom
            adlerFrom = fill
            return true
        }
        let src8 = img.data.assumingMemoryBound(to: UInt8.self)

        for s in 0..<nStrips {
            let y0 = s * rps, rows = min(rps, h - y0)
            guard out.count < ioTIFFLimit - rowBytes * rows else { ioTIFFTooLarge = true; return nil }
            align()
            offsets.append(out.count)
            let df: IODeflate? = comp == 1 || fast ? nil : IODeflate(level: level, prefix: 0, chunkBytes: max(rowBytes, 1 << 18))
            if fast {   // new zlib stream: header, fresh match window
                sr_dstream_free(dstream)
                dstream = sr_dstream_new()
                guard dstream != nil else { return nil }
                out.append(0x78); out.append(0x01)   // zlib header: deflate, 32 KiB window, fastest-algorithm flag
                fill = 0; hist = 0; adlerFrom = 0; adler = 1; stripBytes = 2
            }
            for y in y0..<(y0 + rows) {
                let sr = src8 + y * img.stride
                if fast && fill + rowBytes > sCap { guard feed(final: false) else { return nil } }
                if isFloat && predictor == 3 {   // C kernel: RGB swap + byte planes + differencing
                    if fast {   // straight into the strip buffer
                        sr_tiff_f32_predict_row(sr, Int32(w), Int32(ch), ch >= 3 ? 1 : 0, tmp, sbuf + fill)
                        fill += rowBytes
                        continue
                    }
                    sr_tiff_f32_predict_row(sr, Int32(w), Int32(ch), ch >= 3 ? 1 : 0, tmp, row)
                    if let df {
                        let o = df.reserve(rowBytes)
                        memcpy(o, row, rowBytes)
                        df.commit(rowBytes)
                        if df.pending >= max(rowBytes, 1 << 18) { df.compress(final: false) }
                    } else { out.append(contentsOf: UnsafeBufferPointer(start: row, count: rowBytes)) }
                    continue
                }
                // 1. file-order samples (RGB(A), little endian)
                if ch == 1 { memcpy(row, sr, rowBytes) }
                else if es == 1 {
                    for x in 0..<w {
                        row[x * ch] = sr[x * ch + 2]; row[x * ch + 1] = sr[x * ch + 1]; row[x * ch + 2] = sr[x * ch]
                        if ch == 4 { row[x * 4 + 3] = sr[x * 4 + 3] }
                    }
                } else {
                    for x in 0..<w {
                        for c in 0..<ch {
                            let sc = c < 3 ? 2 - c : c
                            memcpy(row + (x * ch + c) * es, sr + (x * ch + sc) * es, es)
                        }
                    }
                }
                // 2. predictor
                if predictor == 2 {
                    if es == 1 {
                        var i = rowBytes - 1
                        while i >= ch { row[i] = row[i] &- row[i - ch]; i -= 1 }
                    } else {
                        let r16 = UnsafeMutableRawPointer(row)
                        var i = w * ch - 1
                        while i >= ch {
                            let a = r16.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self), b = r16.loadUnaligned(fromByteOffset: (i - ch) * 2, as: UInt16.self)
                            r16.storeBytes(of: a &- b, toByteOffset: i * 2, as: UInt16.self)
                            i -= 1
                        }
                    }
                } else if predictor == 3 {
                    let n = w * ch
                    for j in 0..<n {   // little-endian float j: bytes b0..b3 -> planes MSB first
                        tmp[j] = row[j * 4 + 3]; tmp[n + j] = row[j * 4 + 2]; tmp[2 * n + j] = row[j * 4 + 1]; tmp[3 * n + j] = row[j * 4]
                    }
                    var i = rowBytes - 1
                    while i >= ch { tmp[i] = tmp[i] &- tmp[i - ch]; i -= 1 }
                    memcpy(row, tmp, rowBytes)
                }
                // 3. out
                if fast {
                    memcpy(sbuf + fill, row, rowBytes)
                    fill += rowBytes
                } else if let df {
                    let o = df.reserve(rowBytes)
                    memcpy(o, row, rowBytes)
                    df.commit(rowBytes)
                    if df.pending >= max(rowBytes, 1 << 18) { df.compress(final: false) }
                } else {
                    out.append(contentsOf: UnsafeBufferPointer(start: row, count: rowBytes))
                }
            }
            if fast {
                guard feed(final: true) else { return nil }
                counts.append(stripBytes)
            } else if let df {
                let end = df.finish()
                out.append(contentsOf: UnsafeBufferPointer(start: df.out, count: end))
                counts.append(end)
            } else {
                counts.append(out.count - offsets[s])
            }
        }
        // external arrays
        align()
        let bpsOff = out.count
        for _ in 0..<ch { put16(es * 8) }
        align()
        let sfOff = out.count
        for _ in 0..<ch { put16(isFloat ? 3 : 1) }
        align()
        var soOff = 0, scOff = 0
        if nStrips > 1 {
            soOff = out.count
            for o in offsets { put32(o) }
            scOff = out.count
            for c in counts { put32(c) }
        }
        align()
        guard out.count < ioTIFFLimit else { ioTIFFTooLarge = true; return nil }   // classic TIFF has 32-bit offsets: refuse instead of truncating them
        let ifd = out.count
        if firstIFD == 0 { firstIFD = ifd } else { set32(patchNext, ifd) }
        var entries: [(Int, Int, Int, Int)] = []   // tag, type (3 SHORT, 4 LONG), count, value or offset
        entries.append((256, 4, 1, w)); entries.append((257, 4, 1, h))
        entries.append((258, 3, ch, ch == 1 ? es * 8 : bpsOff))
        entries.append((259, 3, 1, comp == 1 ? 1 : 8))
        entries.append((262, 3, 1, ch == 1 ? 1 : 2))
        entries.append((273, 4, nStrips, nStrips == 1 ? offsets[0] : soOff))
        entries.append((277, 3, 1, ch))
        entries.append((278, 4, 1, rps))
        entries.append((279, 4, nStrips, nStrips == 1 ? counts[0] : scOff))
        entries.append((284, 3, 1, 1))
        if predictor != 1 { entries.append((317, 3, 1, predictor)) }
        if ch == 4 { entries.append((338, 3, 1, 1)) }   // associated alpha, as OpenCV tags it (see ioEncodeTIFFRGBA)
        if isFloat || es == 2 { entries.append((339, 3, ch, ch == 1 ? (isFloat ? 3 : 1) : sfOff)) }
        put16(entries.count)
        for (tag, type, count, value) in entries {
            put16(tag); put16(type); put32(count)
            if type == 3 && count == 1 { put16(value); put16(0) }
            else if type == 3 && count == 2 { put16(value); put16(value) }
            else { put32(value) }
        }
        patchNext = out.count
        put32(0)
    }
    set32(4, firstIFD)
    return out
}
