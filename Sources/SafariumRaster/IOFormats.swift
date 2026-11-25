// SafariumRaster — own readers/writers for the simple formats ImageIO does not cover (Area C):
// BMP (write), PNM family PBM/PGM/PPM/PAM/PFM (read + write), Sun raster (read + write), Radiance HDR (read + write),
// plus the key/value parameter block shared by every encoder (IMWRITE_* flags, OpenCV 5.1 numbering).
// Layouts follow the public format descriptions (Microsoft BMP v3/v4, Netpbm, Sun rasterfile.h, Radiance picture format).

import Foundation

// MARK: - Parameters

/// IMWRITE_* key/value pairs as passed from Python (a flat int32 array: key, value, key, value, ...).
struct IOParams {
    private(set) var kv: [Int: Int] = [:]

    init(_ p: UnsafePointer<Int32>?, _ n: Int) {
        guard let p, n >= 2 else { return }
        var i = 0
        while i + 1 < n { kv[Int(p[i])] = Int(p[i + 1]); i += 2 }
    }

    init() {}

    func get(_ key: Int, _ fallback: Int) -> Int { kv[key] ?? fallback }
    func has(_ key: Int) -> Bool { kv[key] != nil }
}

// MARK: - Pixel access

/// One row as 8-bit samples (16-bit keeps the high byte, float saturates 0...255 like cv2's 8-bit fallback).
func ioRowU8(_ img: SRImage, _ y: Int, _ dst: UnsafeMutablePointer<UInt8>) {
    let s = UnsafeRawPointer(img.row(y))
    let n = img.width * img.channels
    switch img.depth {
    case .u8: memcpy(dst, s, n)
    case .u16: for k in 0..<n { dst[k] = UInt8(s.loadUnaligned(fromByteOffset: k * 2, as: UInt16.self) >> 8) }
    case .f32: for k in 0..<n { dst[k] = srSatU8(Double(s.loadUnaligned(fromByteOffset: k * 4, as: Float.self))) }
    case .s32: for k in 0..<n { dst[k] = srSatU8(Double(s.loadUnaligned(fromByteOffset: k * 4, as: Int32.self))) }
    }
}

/// One row as UInt16 samples (u8 -> v * 257 is NOT done: cv2 keeps 8-bit images 8-bit, so this is only for u16 sources).
func ioRowU16(_ img: SRImage, _ y: Int, _ dst: UnsafeMutablePointer<UInt16>) {
    let s = UnsafeRawPointer(img.row(y))
    let n = img.width * img.channels
    for k in 0..<n { dst[k] = s.loadUnaligned(fromByteOffset: k * 2, as: UInt16.self) }
}

/// One row as Float samples: u8 / 255, u16 / 65535, float as is.
func ioRowF32(_ img: SRImage, _ y: Int, _ dst: UnsafeMutablePointer<Float>) {
    let s = UnsafeRawPointer(img.row(y))
    let n = img.width * img.channels
    switch img.depth {
    case .u8: for k in 0..<n { dst[k] = Float(s.load(fromByteOffset: k, as: UInt8.self)) / 255 }
    case .u16: for k in 0..<n { dst[k] = Float(s.loadUnaligned(fromByteOffset: k * 2, as: UInt16.self)) / 65535 }
    case .f32: for k in 0..<n { dst[k] = s.loadUnaligned(fromByteOffset: k * 4, as: Float.self) }
    case .s32: for k in 0..<n { dst[k] = Float(s.loadUnaligned(fromByteOffset: k * 4, as: Int32.self)) }
    }
}

private func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)] }
private func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
private func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

// MARK: - BMP

/// 8-bit gray (palette), 24-bit BGR, 32-bit BGRA (BI_BITFIELDS in a V4 header, or plain RGB when asked for).
func ioEncodeBMP(_ img: SRImage, _ p: IOParams) -> [UInt8]? {
    let w = img.width, h = img.height, ch = img.channels
    guard w > 0, h > 0, ch != 2 else { return nil }
    let bitfields = ch == 4 && p.get(768, 3) == 3   // IMWRITE_BMP_COMPRESSION: 0 = RGB, 3 = BITFIELDS
    let bpp = ch == 1 ? 8 : (ch == 3 ? 24 : 32)
    let rowBytes = (w * bpp + 31) / 32 * 4
    let paletteBytes = ch == 1 ? 1024 : 0
    let dibSize = bitfields ? 108 : 40
    let offset = 14 + dibSize + paletteBytes
    let total = offset + rowBytes * h
    var out = [UInt8]()
    out.reserveCapacity(total)
    out += [0x42, 0x4D] + le32(total) + le32(0) + le32(offset)
    out += le32(dibSize) + le32(w) + le32(h) + le16(1) + le16(bpp) + le32(bitfields ? 3 : 0) + le32(rowBytes * h)
    out += le32(2835) + le32(2835) + le32(ch == 1 ? 256 : 0) + le32(0)
    if bitfields {
        out += le32(0x00FF_0000) + le32(0x0000_FF00) + le32(0x0000_00FF) + le32(Int(UInt32(0xFF00_0000)))
        out += [0x20, 0x6E, 0x69, 0x57]  // "Win " colour space type
        out += [UInt8](repeating: 0, count: 48)  // endpoints + gamma
    }
    if ch == 1 { for i in 0..<256 { out += [UInt8(i), UInt8(i), UInt8(i), 0] } }
    let row = UnsafeMutablePointer<UInt8>.allocate(capacity: w * ch + 8)
    defer { row.deallocate() }
    for y in stride(from: h - 1, through: 0, by: -1) {
        ioRowU8(img, y, row)
        out.append(contentsOf: UnsafeBufferPointer(start: row, count: w * ch))
        let pad = rowBytes - w * ch
        if pad > 0 { out += [UInt8](repeating: 0, count: pad) }
    }
    return out
}

// MARK: - PNM / PAM / PFM

/// ext: ".pbm" ".pgm" ".ppm" ".pnm" ".pxm" ".pam" ".pfm"
func ioEncodePNM(_ img: SRImage, ext: String, _ p: IOParams) -> [UInt8]? {
    let w = img.width, h = img.height, ch = img.channels
    guard w > 0, h > 0, ch != 2 else { return nil }
    let e = ext.lowercased()
    var out = [UInt8]()
    if e == ".pfm" {
        guard ch == 1 || ch == 3 || ch == 4 else { return nil }
        let oc = ch == 1 ? 1 : 3
        out += Array((oc == 1 ? "Pf\n\(w) \(h)\n-1.0\n" : "PF\n\(w) \(h)\n-1.0\n").utf8)
        let row = UnsafeMutablePointer<Float>.allocate(capacity: w * ch + 4)
        defer { row.deallocate() }
        var bytes = [UInt8](repeating: 0, count: w * oc * 4)
        for y in stride(from: h - 1, through: 0, by: -1) {
            ioRowF32(img, y, row)
            bytes.withUnsafeMutableBytes { b in
                for x in 0..<w {
                    for c in 0..<oc {
                        let sc = oc == 3 ? 2 - c : c  // BGR -> RGB
                        b.storeBytes(of: row[x * ch + sc], toByteOffset: (x * oc + c) * 4, as: Float.self)
                    }
                }
            }
            out += bytes
        }
        return out
    }
    let wide = img.depth == .u16 || img.depth == .f32 && false
    let maxval = wide ? 65535 : 255
    let binary = p.get(32, 1) != 0   // IMWRITE_PXM_BINARY
    if e == ".pam" {
        // tuple type: IMWRITE_PAM_TUPLETYPE 0 auto, 1 b&w, 2 gray, 3 gray+alpha, 4 RGB, 5 RGB+alpha
        var t = p.get(128, 0)
        if t == 0 { t = ch == 1 ? 2 : (ch == 3 ? 4 : 5) }
        let depth = (t == 1 || t == 2) ? 1 : (t == 3 ? 2 : (t == 4 ? 3 : 4))
        let names = [1: "BLACKANDWHITE", 2: "GRAYSCALE", 3: "GRAYSCALE_ALPHA", 4: "RGB", 5: "RGB_ALPHA"]
        guard let tn = names[t], ch == depth || (ch == 1 && depth == 1) || (ch >= 3 && depth >= 3) else { return nil }
        out += Array("P7\nWIDTH \(w)\nHEIGHT \(h)\nDEPTH \(depth)\nMAXVAL \(t == 1 ? 1 : maxval)\nTUPLTYPE \(tn)\nENDHDR\n".utf8)
        // cv2 stores PAM samples in the array's own (BGR / BGRA) order and its reader does not swap either: stay compatible
        return ioPNMPixels(img, &out, outCh: depth, swapRB: false, maxval: t == 1 ? 1 : maxval, binary: true, bilevel: t == 1)
    }
    if e == ".pbm" {
        guard ch == 1 else { return nil }
        out += Array((binary ? "P4\n\(w) \(h)\n" : "P1\n\(w) \(h)\n").utf8)
        let row = UnsafeMutablePointer<UInt8>.allocate(capacity: w + 8)
        defer { row.deallocate() }
        for y in 0..<h {
            ioRowU8(img, y, row)
            if binary {
                var acc: UInt8 = 0, nb = 0
                for x in 0..<w {
                    acc = (acc << 1) | (row[x] == 0 ? 1 : 0)   // 1 = black; cv2 writes zero pixels as black
                    nb += 1
                    if nb == 8 { out.append(acc); acc = 0; nb = 0 }
                }
                if nb > 0 { out.append(acc << UInt8(8 - nb)) }
            } else {
                out += Array((0..<w).map { row[$0] == 0 ? "1" : "0" }.joined(separator: " ").utf8) + [10]
            }
        }
        return out
    }
    // PGM (gray) or PPM (colour); ".pnm" / ".pxm" pick by channel count
    let gray = ch == 1
    if e == ".pgm" && !gray { return nil }
    if e == ".ppm" && gray { return nil }
    let magic = gray ? (binary ? "P5" : "P2") : (binary ? "P6" : "P3")
    out += Array("\(magic)\n\(w) \(h)\n\(maxval)\n".utf8)
    return ioPNMPixels(img, &out, outCh: gray ? 1 : 3, swapRB: !gray, maxval: maxval, binary: binary, bilevel: false)
}

private func ioPNMPixels(_ img: SRImage, _ out: inout [UInt8], outCh: Int, swapRB: Bool, maxval: Int, binary: Bool, bilevel: Bool) -> [UInt8] {
    let w = img.width, h = img.height, ch = img.channels
    let wide = maxval > 255
    let row8 = UnsafeMutablePointer<UInt8>.allocate(capacity: w * ch + 8)
    let row16 = UnsafeMutablePointer<UInt16>.allocate(capacity: w * ch + 8)
    defer { row8.deallocate(); row16.deallocate() }
    var line = [UInt8]()
    for y in 0..<h {
        if wide { ioRowU16(img, y, row16) } else { ioRowU8(img, y, row8) }
        if binary {
            for x in 0..<w {
                for c in 0..<outCh {
                    let sc = swapRB && c < 3 ? 2 - c : c
                    if wide {
                        let v = row16[x * ch + sc]
                        out.append(UInt8(v >> 8)); out.append(UInt8(v & 0xFF))
                    } else {
                        let v = row8[x * ch + sc]
                        out.append(bilevel ? (v == 0 ? 0 : 1) : v)
                    }
                }
            }
        } else {
            line.removeAll(keepingCapacity: true)
            for x in 0..<w {
                for c in 0..<outCh {
                    let sc = swapRB && c < 3 ? 2 - c : c
                    let v = wide ? Int(row16[x * ch + sc]) : Int(row8[x * ch + sc])
                    line += Array(String(v).utf8)
                    line.append(32)
                }
            }
            line[line.count - 1] = 10
            out += line
        }
    }
    return out
}

// MARK: - Sun raster

/// 8-bit gray or 24-bit BGR, standard (uncompressed) layout, rows padded to 16 bits.
func ioEncodeSunRaster(_ img: SRImage) -> [UInt8]? {
    let w = img.width, h = img.height, ch = img.channels
    guard w > 0, h > 0, ch != 2 else { return nil }
    let depth = ch == 1 ? 8 : 24
    let rowBytes = (w * depth / 8 + 1) & ~1
    var out = be32(0x59A6_6A95) + be32(w) + be32(h) + be32(depth) + be32(rowBytes * h) + be32(1) + be32(0) + be32(0)
    out.reserveCapacity(32 + rowBytes * h)
    let row = UnsafeMutablePointer<UInt8>.allocate(capacity: w * ch + 8)
    defer { row.deallocate() }
    for y in 0..<h {
        ioRowU8(img, y, row)
        if ch == 1 { out.append(contentsOf: UnsafeBufferPointer(start: row, count: w)) }
        else { for x in 0..<w { out.append(row[x * ch]); out.append(row[x * ch + 1]); out.append(row[x * ch + 2]) } }  // BGR order
        if rowBytes > w * depth / 8 { out.append(0) }
    }
    return out
}

// MARK: - Radiance HDR

func ioEncodeHDR(_ img: SRImage, _ p: IOParams) -> [UInt8]? {
    let w = img.width, h = img.height, ch = img.channels
    guard w > 0, h > 0, ch != 2 else { return nil }
    let rle = p.get(80, 1) == 1 && w >= 8 && w <= 32767   // IMWRITE_HDR_COMPRESSION: 0 none, 1 RLE
    var out = Array("#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y \(h) +X \(w)\n".utf8)
    let row = UnsafeMutablePointer<Float>.allocate(capacity: w * ch + 4)
    defer { row.deallocate() }
    var rgbe = [UInt8](repeating: 0, count: w * 4)
    var planes = [UInt8](repeating: 0, count: w * 4)
    for y in 0..<h {
        ioRowF32(img, y, row)
        for x in 0..<w {
            let b = row[x * ch], g = ch == 1 ? b : row[x * ch + 1], r = ch == 1 ? b : row[x * ch + 2]  // BGR -> r,g,b
            let m = max(r, max(g, b))
            if !(m > 1e-32) { rgbe[x * 4] = 0; rgbe[x * 4 + 1] = 0; rgbe[x * 4 + 2] = 0; rgbe[x * 4 + 3] = 0; continue }
            let e = Int(frexp(Double(m)).1)
            let scale = Float(ldexp(1.0, 8 - e))   // 256 / 2^e
            rgbe[x * 4] = UInt8(max(0, min(255, r * scale)))
            rgbe[x * 4 + 1] = UInt8(max(0, min(255, g * scale)))
            rgbe[x * 4 + 2] = UInt8(max(0, min(255, b * scale)))
            rgbe[x * 4 + 3] = UInt8(max(0, min(255, e + 128)))
        }
        if !rle { out += rgbe; continue }
        out += [2, 2, UInt8(w >> 8), UInt8(w & 0xFF)]
        for c in 0..<4 { for x in 0..<w { planes[c * w + x] = rgbe[x * 4 + c] } }
        for c in 0..<4 {
            var x = 0
            while x < w {
                // run of >= 4 equal bytes?
                var run = 1
                while x + run < w && run < 127 && planes[c * w + x + run] == planes[c * w + x] { run += 1 }
                if run >= 4 {
                    out.append(UInt8(128 + run)); out.append(planes[c * w + x]); x += run
                } else {
                    // literal stretch up to 128 bytes, stopping before the next run of 4
                    var n = 0
                    while x + n < w && n < 128 {
                        var r2 = 1
                        while x + n + r2 < w && r2 < 4 && planes[c * w + x + n + r2] == planes[c * w + x + n] { r2 += 1 }
                        if r2 >= 4 { break }
                        n += 1
                    }
                    if n == 0 { n = 1 }
                    out.append(UInt8(n))
                    out.append(contentsOf: planes[(c * w + x)..<(c * w + x + n)])
                    x += n
                }
            }
        }
    }
    return out
}

// MARK: - Decoders

/// Native-order result of an own decoder.
struct IOOwnImage {
    var mat: IOMat
    var kind: String   // "pnm", "sr", "hdr", "bmp", "exr"
}

func ioDecodeOwn(_ d: Data, tooLarge: inout Bool) -> IOOwnImage? {
    let b = [UInt8](d)
    guard b.count >= 4 else { return nil }
    if b[0] == 0x42 && b[1] == 0x4D { return ioDecodeBMP(b, tooLarge: &tooLarge) }
    if b[0] == 0x76 && b[1] == 0x2F && b[2] == 0x31 && b[3] == 0x01 { return ioDecodeEXR(b, tooLarge: &tooLarge) }
    if b[0] == 0x59 && b[1] == 0xA6 && b[2] == 0x6A && b[3] == 0x95 { return ioDecodeSun(b) }
    if b[0] == 0x50, (b[1] >= 0x31 && b[1] <= 0x37) || b[1] == 0x66 || b[1] == 0x46 { return ioDecodePNM(b) }
    if b.count > 10, b[0] == 0x23, b[1] == 0x3F { return ioDecodeHDR(b) }
    return nil
}

/// Native BMP decoder for uncompressed 8/24/32-bit BI_RGB & 32-bit BI_BITFIELDS (avoids macOS 15/26 ImageIO V4 BGRA gaps).
private func ioDecodeBMP(_ b: [UInt8], tooLarge: inout Bool) -> IOOwnImage? {
    guard b.count >= 54, b[0] == 0x42, b[1] == 0x4D else { return nil }
    @inline(__always) func u16(_ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) }
    @inline(__always) func u32(_ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
    let pixelOffset = Int64(u32(10))
    let dibSize = Int(u32(14))
    guard dibSize >= 40, b.count >= 14 + dibSize else { return nil }
    let w = Int64(Int32(bitPattern: u32(18)))
    let rawH = Int64(Int32(bitPattern: u32(22)))
    let topDown = rawH < 0
    let h = rawH < 0 ? -rawH : rawH
    guard w > 0, h > 0 else { return nil }
    if w > Int64(ioMaxImagePixels) || h > Int64(ioMaxImagePixels) || w * h > Int64(ioMaxImagePixels) {
        tooLarge = true
        return nil
    }
    let planes = u16(26), bpp = u16(28), comp = u32(30)
    guard planes == 1, comp == 0 || comp == 3 else { return nil }
    let wi = Int(w), hi = Int(h)

    if bpp == 8, comp == 0 {
        var colors = Int(u32(46))
        if colors == 0 { colors = 256 }
        let palStart = 14 + dibSize
        guard colors > 0, colors <= 256, palStart + colors * 4 <= b.count else { return nil }
        let rowBytes = ((wi * 8 + 31) / 32) * 4
        guard pixelOffset >= 0, pixelOffset + Int64(rowBytes) * h <= Int64(b.count) else { return nil }
        var isGray = true
        for i in 0..<colors {
            let p = palStart + i * 4
            if !(b[p] == b[p + 1] && b[p + 1] == b[p + 2]) { isGray = false; break }
        }
        let pix = Int(pixelOffset)
        if isGray {
            let out = IOMat(width: wi, height: hi, channels: 1, depth: .u8)
            out.bytes.withUnsafeMutableBufferPointer { dst in
                for y in 0..<hi {
                    let sy = topDown ? y : (hi - 1 - y)
                    let sOff = pix + sy * rowBytes
                    let dOff = y * wi
                    for x in 0..<wi {
                        let idx = min(Int(b[sOff + x]), colors - 1)
                        dst[dOff + x] = b[palStart + idx * 4]
                    }
                }
            }
            return IOOwnImage(mat: out, kind: "bmp")
        }
        let out = IOMat(width: wi, height: hi, channels: 3, depth: .u8)
        out.bytes.withUnsafeMutableBufferPointer { dst in
            for y in 0..<hi {
                let sy = topDown ? y : (hi - 1 - y)
                let sOff = pix + sy * rowBytes
                let dOff = y * wi * 3
                for x in 0..<wi {
                    let idx = min(Int(b[sOff + x]), colors - 1)
                    let p = palStart + idx * 4
                    dst[dOff + x * 3 + 0] = b[p]
                    dst[dOff + x * 3 + 1] = b[p + 1]
                    dst[dOff + x * 3 + 2] = b[p + 2]
                }
            }
        }
        return IOOwnImage(mat: out, kind: "bmp")
    }

    if bpp == 24, comp == 0 {
        let rowBytes = ((wi * 24 + 31) / 32) * 4
        guard pixelOffset >= 0, pixelOffset + Int64(rowBytes) * h <= Int64(b.count) else { return nil }
        let pix = Int(pixelOffset)
        let out = IOMat(width: wi, height: hi, channels: 3, depth: .u8)
        out.bytes.withUnsafeMutableBufferPointer { dst in
            b.withUnsafeBufferPointer { src in
                for y in 0..<hi {
                    let sy = topDown ? y : (hi - 1 - y)
                    memcpy(dst.baseAddress! + y * wi * 3, src.baseAddress! + pix + sy * rowBytes, wi * 3)
                }
            }
        }
        return IOOwnImage(mat: out, kind: "bmp")
    }

    if bpp == 32 {
        var rMask: UInt32 = 0x00FF_0000, gMask: UInt32 = 0x0000_FF00, bMask: UInt32 = 0x0000_00FF, aMask: UInt32 = 0
        if comp == 3 {
            guard b.count >= 66 else { return nil }
            rMask = u32(54); gMask = u32(58); bMask = u32(62)
            aMask = dibSize >= 56 && b.count >= 70 ? u32(66) : 0
        } else if dibSize >= 56 && b.count >= 70 {
            // BI_RGB 32-bit without explicit bitfields omits alpha in OpenCV unless V4/V5 non-zero alpha mask is checked.
            aMask = 0
        }
        guard rMask == 0x00FF_0000, gMask == 0x0000_FF00, bMask == 0x0000_00FF,
              aMask == 0 || aMask == 0xFF00_0000 else { return nil }
        let ch = aMask == 0xFF00_0000 ? 4 : 3
        let rowBytes = wi * 4
        guard pixelOffset >= 0, pixelOffset + Int64(rowBytes) * h <= Int64(b.count) else { return nil }
        let pix = Int(pixelOffset)
        let out = IOMat(width: wi, height: hi, channels: ch, depth: .u8)
        out.bytes.withUnsafeMutableBufferPointer { dst in
            if ch == 4 {
                b.withUnsafeBufferPointer { src in
                    for y in 0..<hi {
                        let sy = topDown ? y : (hi - 1 - y)
                        memcpy(dst.baseAddress! + y * wi * 4, src.baseAddress! + pix + sy * rowBytes, wi * 4)
                    }
                }
            } else {
                for y in 0..<hi {
                    let sy = topDown ? y : (hi - 1 - y)
                    let sOff = pix + sy * rowBytes
                    let dOff = y * wi * 3
                    for x in 0..<wi {
                        dst[dOff + x * 3 + 0] = b[sOff + x * 4 + 0]
                        dst[dOff + x * 3 + 1] = b[sOff + x * 4 + 1]
                        dst[dOff + x * 3 + 2] = b[sOff + x * 4 + 2]
                    }
                }
            }
        }
        return IOOwnImage(mat: out, kind: "bmp")
    }

    return nil
}

private struct IOTokenizer {
    let b: [UInt8]
    var i = 0
    init(_ b: [UInt8], at: Int) { self.b = b; i = at }
    mutating func skipSpace() {
        while i < b.count {
            if b[i] == 0x23 { while i < b.count && b[i] != 10 { i += 1 } }
            else if b[i] == 32 || b[i] == 9 || b[i] == 10 || b[i] == 13 { i += 1 }
            else { break }
        }
    }
    mutating func int() -> Int? {
        skipSpace()
        var v = 0, n = 0
        while i < b.count, b[i] >= 0x30, b[i] <= 0x39 { v = v * 10 + Int(b[i] - 0x30); i += 1; n += 1; if v > 1 << 30 { return nil } }
        return n > 0 ? v : nil
    }
    mutating func word() -> String? {
        skipSpace()
        let s = i
        while i < b.count, b[i] > 32 { i += 1 }
        return i > s ? String(decoding: b[s..<i], as: UTF8.self) : nil
    }
}

private func ioDecodePNM(_ b: [UInt8]) -> IOOwnImage? {
    let kind = b[1]
    var t = IOTokenizer(b, at: 2)
    var w = 0, h = 0, maxval = 1, depth = 1
    var pamBW = false
    var pamGrayAlpha = false
    if kind == 0x37 {  // P7 (PAM)
        t.i = 2
        while let key = t.word() {
            if key == "ENDHDR" { t.i += 1; break }
            switch key {
            case "WIDTH": w = t.int() ?? 0
            case "HEIGHT": h = t.int() ?? 0
            case "DEPTH": depth = t.int() ?? 0
            case "MAXVAL": maxval = t.int() ?? 0
            case "TUPLTYPE":
                let v = t.word() ?? ""
                if v == "BLACKANDWHITE" { pamBW = true }
                if v == "GRAYSCALE_ALPHA" { pamGrayAlpha = true }
            default: _ = t.word()
            }
        }
    } else if kind == 0x66 || kind == 0x46 {  // Pf / PF
        guard let ww = t.int(), let hh = t.int() else { return nil }
        w = ww; h = hh
        depth = kind == 0x66 ? 1 : 3
        guard let sc = t.word(), let scale = Double(sc) else { return nil }
        t.i += 1
        let little = scale < 0
        guard w > 0, h > 0, w <= 1 << 30, h <= 1 << 30, w * h <= ioMaxImagePixels, b.count - t.i >= w * h * depth * 4 else { return nil }
        let m = IOMat(width: w, height: h, channels: depth, depth: .f32)
        m.bytes.withUnsafeMutableBytes { o in
            b.withUnsafeBytes { s in
                for y in 0..<h {
                    for x in 0..<w {
                        for c in 0..<depth {
                            let off = t.i + ((y * w + x) * depth + c) * 4
                            var u = s.loadUnaligned(fromByteOffset: off, as: UInt32.self)
                            if !little { u = u.byteSwapped }
                            let sc2 = depth == 3 ? 2 - c : c  // RGB -> BGR
                            o.storeBytes(of: u, toByteOffset: (((h - 1 - y) * w + x) * depth + sc2) * 4, as: UInt32.self)
                        }
                    }
                }
            }
        }
        return IOOwnImage(mat: m, kind: "pfm")
    } else {
        guard let ww = t.int(), let hh = t.int() else { return nil }
        w = ww; h = hh
        depth = (kind == 0x33 || kind == 0x36) ? 3 : 1
        if kind == 0x31 || kind == 0x34 { maxval = 1 } else { maxval = t.int() ?? 0 }
        if kind != 0x31 && kind != 0x34 { t.i += 1 } else if kind == 0x34 { t.i += 1 }
    }
    guard w > 0, h > 0, w <= 1 << 30, h <= 1 << 30, depth >= 1, depth <= 4, maxval > 0, maxval < 65536 else { return nil }
    let (px, ov) = w.multipliedReportingOverflow(by: h)
    guard !ov, px <= ioMaxImagePixels else { return nil }
    // the file must be able to hold the samples before anything is allocated (ASCII: at least one byte per sample)
    let minBytes = (kind == 0x34 ? ((w + 7) / 8) * h : (kind <= 0x33 ? px * depth : px * depth * (maxval > 255 ? 2 : 1)))
    guard b.count - t.i >= minBytes else { return nil }
    let ascii = kind == 0x31 || kind == 0x32 || kind == 0x33
    let wide = maxval > 255
    let outCh = (pamGrayAlpha && depth == 2) ? 4 : (depth == 2 ? 1 : depth)
    let m = IOMat(width: w, height: h, channels: outCh, depth: wide ? .u16 : .u8)
    var pos = t.i
    var bitAcc = 0
    func nextValue() -> Int? {
        if ascii {
            var tk = IOTokenizer(b, at: pos)
            let v: Int?
            if kind == 0x31 {  // P1: digits may be adjacent
                tk.skipSpace()
                if tk.i < b.count, b[tk.i] == 0x30 || b[tk.i] == 0x31 { v = Int(b[tk.i] - 0x30); tk.i += 1 } else { v = nil }
            } else { v = tk.int() }
            pos = tk.i
            return v
        }
        if wide {
            guard pos + 2 <= b.count else { return nil }
            let v = Int(b[pos]) << 8 | Int(b[pos + 1]); pos += 2; return v
        }
        guard pos < b.count else { return nil }
        let v = Int(b[pos]); pos += 1; return v
    }
    _ = bitAcc
    for y in 0..<h {
        if kind == 0x34 {  // P4 packed bits
            let rb = (w + 7) / 8
            guard pos + rb <= b.count else { return nil }
            for x in 0..<w { m.bytes[y * w + x] = (b[pos + x / 8] >> UInt8(7 - x % 8)) & 1 == 1 ? 0 : 255 }
            pos += rb
            continue
        }
        for x in 0..<w {
            var px = [Int](repeating: 0, count: depth)
            for c in 0..<depth { guard let v = nextValue(), v <= maxval else { return nil }; px[c] = v }
            if kind == 0x31 { m.bytes[y * w + x] = px[0] == 1 ? 0 : 255; continue }
            var vals = px
            if pamBW { vals = px.map { $0 == 0 ? 0 : 255 } }
            let scaleTo = maxval
            func put(_ c: Int, _ v: Int) {
                let o = (y * w + x) * outCh + c
                if wide { m.bytes[o * 2] = UInt8(v & 0xFF); m.bytes[o * 2 + 1] = UInt8(v >> 8) }
                else { m.bytes[o] = UInt8(truncatingIfNeeded: scaleTo == 255 || pamBW ? v : v * 255 / scaleTo) }
            }
            switch depth {
            case 1: put(0, vals[0])
            case 2:
                if pamGrayAlpha { put(0, vals[0]); put(1, vals[0]); put(2, vals[0]); put(3, vals[1]) } else { put(0, vals[0]) }
            case 3: if kind == 0x37 { put(0, vals[0]); put(1, vals[1]); put(2, vals[2]) } else { put(0, vals[2]); put(1, vals[1]); put(2, vals[0]) }  // PNM: RGB -> BGR; PAM: as stored (cv2)
            default: if kind == 0x37 { put(0, vals[0]); put(1, vals[1]); put(2, vals[2]); put(3, vals[3]) } else { put(0, vals[2]); put(1, vals[1]); put(2, vals[0]); put(3, vals[3]) }
            }
        }
    }
    return IOOwnImage(mat: m, kind: "pnm")
}

private func ioDecodeSun(_ b: [UInt8]) -> IOOwnImage? {
    guard b.count >= 32 else { return nil }
    func u32(_ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }
    let w = u32(4), h = u32(8), depth = u32(12), length = u32(16), type = u32(20), mapType = u32(24), mapLen = u32(28)
    guard w > 0, h > 0, w <= 1 << 30, h <= 1 << 30, w * h <= ioMaxImagePixels, [1, 8, 24, 32].contains(depth), type >= 0, type <= 3 else { return nil }
    var pos = 32
    var palette: [UInt8] = []
    guard mapLen >= 0, mapLen <= b.count - pos else { return nil }
    if mapType == 1 && mapLen > 0 { palette = Array(b[pos..<(pos + mapLen)]) }
    pos += mapLen
    let rowBytes = (w * depth + 15) / 16 * 2
    // raw data must be present (RLE can expand at most 128x) before the output buffer is sized from the header
    guard rowBytes * h <= (type == 2 ? (b.count - pos) * 129 : b.count - pos) else { return nil }
    var data = [UInt8]()
    if type == 2 {  // RLE: 0x80 escape
        data.reserveCapacity(rowBytes * h)
        var i = pos
        while i < b.count && data.count < rowBytes * h {
            let v = b[i]; i += 1
            if v == 0x80 {
                guard i < b.count else { break }
                let n = Int(b[i]); i += 1
                if n == 0 { data.append(0x80) }
                else { guard i < b.count else { break }; let c = b[i]; i += 1; data += [UInt8](repeating: c, count: n + 1) }
            } else { data.append(v) }
        }
    } else {
        let avail = max(0, min(b.count - pos, length > 0 ? max(length, rowBytes * h) : rowBytes * h))
        data = Array(b[pos..<(pos + avail)])
    }
    guard data.count >= rowBytes * h else { return nil }
    let isRGB = type == 3
    let out: IOMat
    if depth == 8 && mapType == 1 && !palette.isEmpty {
        let n = mapLen / 3
        out = IOMat(width: w, height: h, channels: 3, depth: .u8)
        for y in 0..<h { for x in 0..<w {
            let idx = min(Int(data[y * rowBytes + x]), max(0, n - 1))
            out.bytes[(y * w + x) * 3] = palette[2 * n + idx]; out.bytes[(y * w + x) * 3 + 1] = palette[n + idx]; out.bytes[(y * w + x) * 3 + 2] = palette[idx]
        } }
    } else if depth == 8 {
        out = IOMat(width: w, height: h, channels: 1, depth: .u8)
        for y in 0..<h { for x in 0..<w { out.bytes[y * w + x] = data[y * rowBytes + x] } }
    } else if depth == 1 {
        out = IOMat(width: w, height: h, channels: 1, depth: .u8)
        for y in 0..<h { for x in 0..<w { out.bytes[y * w + x] = (data[y * rowBytes + x / 8] >> UInt8(7 - x % 8)) & 1 == 1 ? 0 : 255 } }
    } else {
        out = IOMat(width: w, height: h, channels: 3, depth: .u8)
        let bpp = depth / 8
        for y in 0..<h { for x in 0..<w {
            let o = y * rowBytes + x * bpp + (depth == 32 ? 1 : 0)   // 32-bit: leading pad/alpha byte
            let c0 = data[o], c1 = data[o + 1], c2 = data[o + 2]
            let (bb, gg, rr) = isRGB ? (c2, c1, c0) : (c0, c1, c2)   // standard type stores BGR
            out.bytes[(y * w + x) * 3] = bb; out.bytes[(y * w + x) * 3 + 1] = gg; out.bytes[(y * w + x) * 3 + 2] = rr
        } }
    }
    return IOOwnImage(mat: out, kind: "sr")
}

private func ioDecodeHDR(_ b: [UInt8]) -> IOOwnImage? {
    // header lines until an empty line, then the resolution line
    var i = 0
    func line() -> String? {
        guard i < b.count else { return nil }
        let s = i
        while i < b.count && b[i] != 10 { i += 1 }
        let l = String(decoding: b[s..<i], as: UTF8.self)
        i += 1
        return l
    }
    guard let magic = line(), magic.hasPrefix("#?") else { return nil }
    var format = ""
    while let l = line() { if l.isEmpty { break }; if l.hasPrefix("FORMAT=") { format = l } }
    guard format.isEmpty || format.contains("32-bit_rle_rgbe"), let res = line() else { return nil }
    let parts = res.split(separator: " ")
    guard parts.count == 4, let h = Int(parts[1]), let w = Int(parts[3]), w > 0, h > 0, w <= 1 << 30, h <= 1 << 30, w * h <= ioMaxImagePixels else { return nil }
    // every scanline needs bytes in the file (flat: 4 per pixel; run-length coded: at least a header and one run per channel block)
    let perLine = (w >= 8 && w <= 32767) ? 4 + 8 * ((w + 126) / 127) : w * 4
    guard b.count - i >= h * perLine else { return nil }
    let flipY = parts[0] == "+Y", flipX = parts[2] == "-X"
    let m = IOMat(width: w, height: h, channels: 3, depth: .f32)
    var scan = [UInt8](repeating: 0, count: w * 4)
    var pos = i
    for y in 0..<h {
        guard pos + 4 <= b.count else { return nil }
        if w >= 8 && w <= 32767 && b[pos] == 2 && b[pos + 1] == 2 && Int(b[pos + 2]) << 8 | Int(b[pos + 3]) == w {
            pos += 4
            for c in 0..<4 {
                var x = 0
                while x < w {
                    guard pos < b.count else { return nil }
                    var n = Int(b[pos]); pos += 1
                    if n > 128 {
                        n -= 128
                        guard pos < b.count, x + n <= w else { return nil }
                        let v = b[pos]; pos += 1
                        for k in 0..<n { scan[(x + k) * 4 + c] = v }
                    } else {
                        guard n > 0, pos + n <= b.count, x + n <= w else { return nil }
                        for k in 0..<n { scan[(x + k) * 4 + c] = b[pos + k] }
                        pos += n
                    }
                    x += n
                }
            }
        } else {
            guard pos + w * 4 <= b.count else { return nil }
            for k in 0..<(w * 4) { scan[k] = b[pos + k] }
            pos += w * 4
        }
        let oy = flipY ? h - 1 - y : y
        m.bytes.withUnsafeMutableBytes { o in
            for x in 0..<w {
                let e = Int(scan[x * 4 + 3])
                let f: Float = e == 0 ? 0 : Float(ldexp(1.0, e - 136))
                let ox = flipX ? w - 1 - x : x
                o.storeBytes(of: Float(scan[x * 4 + 2]) * f, toByteOffset: ((oy * w + ox) * 3) * 4, as: Float.self)       // B
                o.storeBytes(of: Float(scan[x * 4 + 1]) * f, toByteOffset: ((oy * w + ox) * 3 + 1) * 4, as: Float.self)   // G
                o.storeBytes(of: Float(scan[x * 4]) * f, toByteOffset: ((oy * w + ox) * 3 + 2) * 4, as: Float.self)       // R
            }
        }
    }
    return IOOwnImage(mat: m, kind: "hdr")
}
