// SafariumRaster — own OpenEXR writer (Area C): scanline images, FLOAT or HALF samples (IMWRITE_EXR_TYPE), compression
// NONE / ZIPS / ZIP (IMWRITE_EXR_COMPRESSION 0 / 2 / 3; other codes fall back to ZIP). ImageIO's EXR encoder stores half
// floats only, so full 32-bit output needs this writer. Layout per the OpenEXR file-layout specification (public).

import Compression
import Foundation

func ioEncodeEXR(_ img: SRImage, _ p: IOParams) -> [UInt8]? {
    let w = img.width, h = img.height, ch = img.channels
    guard w > 0, h > 0, ch == 1 || ch == 3 || ch == 4 else { return nil }
    let half = p.get(48, 2) == 1
    var comp = p.get(49, 3)
    if comp != 0 && comp != 2 && comp != 3 { comp = 3 }
    let names: [String] = ch == 1 ? ["Y"] : (ch == 3 ? ["B", "G", "R"] : ["A", "B", "G", "R"])
    // source channel (BGR(A) order) for each EXR channel in file (alphabetical) order
    let srcIdx: [Int] = ch == 1 ? [0] : (ch == 3 ? [0, 1, 2] : [3, 0, 1, 2])
    let sz = half ? 2 : 4
    var out: [UInt8] = [0x76, 0x2F, 0x31, 0x01, 2, 0, 0, 0]
    func str(_ s: String) { out += Array(s.utf8) + [0] }
    func i32(_ v: Int) { for k in 0..<4 { out.append(UInt8((v >> (8 * k)) & 0xFF)) } }
    func attr(_ name: String, _ type: String, _ body: [UInt8]) { str(name); str(type); i32(body.count); out += body }
    func le32(_ v: Int) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    var chl: [UInt8] = []
    let pixelTypeBytes: [UInt8] = le32(half ? 1 : 2)
    let zeroPad: [UInt8] = [0, 0, 0, 0]
    let samplingBytes: [UInt8] = le32(1)
    for n in names {
        chl.append(contentsOf: n.utf8)
        chl.append(0)
        chl.append(contentsOf: pixelTypeBytes)
        chl.append(contentsOf: zeroPad)
        chl.append(contentsOf: samplingBytes)
        chl.append(contentsOf: samplingBytes)
    }
    chl.append(0)
    attr("channels", "chlist", chl)
    attr("compression", "compression", [UInt8(comp)])
    let box = le32(0) + le32(0) + le32(w - 1) + le32(h - 1)
    attr("dataWindow", "box2i", box)
    attr("displayWindow", "box2i", box)
    attr("lineOrder", "lineOrder", [0])
    attr("pixelAspectRatio", "float", le32(Int(Float(1).bitPattern)))
    attr("screenWindowCenter", "v2f", le32(0) + le32(0))
    attr("screenWindowWidth", "float", le32(Int(Float(1).bitPattern)))
    out.append(0)
    let linesPerBlock = comp == 3 ? 16 : 1
    let nBlocks = (h + linesPerBlock - 1) / linesPerBlock
    let tableAt = out.count
    out += [UInt8](repeating: 0, count: nBlocks * 8)
    let row = UnsafeMutablePointer<Float>.allocate(capacity: w * ch + 4)
    defer { row.deallocate() }
    for b in 0..<nBlocks {
        let y0 = b * linesPerBlock, lines = min(linesPerBlock, h - y0)
        var raw = [UInt8](repeating: 0, count: lines * w * ch * sz)
        raw.withUnsafeMutableBytes { rb in
            for l in 0..<lines {
                ioRowF32(img, y0 + l, row)
                for (ci, si) in srcIdx.enumerated() {
                    let base = (l * ch + ci) * w * sz
                    for x in 0..<w {
                        let v = row[x * ch + si]
                        if half { rb.storeBytes(of: Float16(v).bitPattern, toByteOffset: base + x * 2, as: UInt16.self) }
                        else { rb.storeBytes(of: v, toByteOffset: base + x * 4, as: Float.self) }
                    }
                }
            }
        }
        var payload = raw
        if comp != 0 {
            let n = raw.count
            var t = [UInt8](repeating: 0, count: n)
            let half1 = (n + 1) / 2
            for i in 0..<n { if i & 1 == 0 { t[i / 2] = raw[i] } else { t[half1 + i / 2] = raw[i] } }
            if n > 1 { var i = n - 1; while i >= 1 { t[i] = UInt8(truncatingIfNeeded: Int(t[i]) - Int(t[i - 1]) + 128 + 256); i -= 1 } }
            let df = IODeflate(level: 3, prefix: 0, chunkBytes: max(n, 1 << 16))
            let o = df.reserve(n)
            t.withUnsafeBytes { memcpy(o, $0.baseAddress!, n) }
            df.commit(n)
            let end = df.finish()
            if end < n { payload = Array(UnsafeBufferPointer(start: df.out, count: end)) }
        }
        let at = out.count
        for k in 0..<8 { out[tableAt + b * 8 + k] = UInt8((at >> (8 * k)) & 0xFF) }
        i32(y0); i32(payload.count)
        out += payload
    }
    return out
}

/// Native scanline OpenEXR decoder (NONE/ZIPS/ZIP, HALF/FLOAT) so macOS 15 ImageIO cannot degrade 1-channel Y to uint8.
func ioDecodeEXR(_ b: [UInt8], tooLarge: inout Bool) -> IOOwnImage? {
    guard b.count >= 12, b[0] == 0x76, b[1] == 0x2F, b[2] == 0x31, b[3] == 0x01 else { return nil }
    @inline(__always) func u32(_ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }
    @inline(__always) func i32(_ o: Int) -> Int32 { Int32(bitPattern: u32(o)) }
    @inline(__always) func u64(_ o: Int) -> UInt64 {
        UInt64(u32(o)) | (UInt64(u32(o + 4)) << 32)
    }

    let version = u32(4)
    // Only single-part scanline OpenEXR (version 2, flags == 0)
    guard (version & 0xFF) == 2, (version & ~0xFF) == 0 else { return nil }

    var cur = 8
    func readCStr(limit: Int = 256) -> String? {
        let start = cur
        let stop = min(b.count, cur + limit)
        while cur < stop && b[cur] != 0 { cur += 1 }
        guard cur < stop else { return nil }
        let s = String(decoding: b[start..<cur], as: UTF8.self)
        cur += 1
        return s
    }

    struct EXRChannel { let name: String; let pixelType: Int }
    var channels: [EXRChannel] = []
    var comp = -1
    var xMin: Int64 = 0, yMin: Int64 = 0, xMax: Int64 = -1, yMax: Int64 = -1
    var hasBox = false

    while cur < b.count {
        if b[cur] == 0 { cur += 1; break }
        guard let attrName = readCStr(), let attrType = readCStr(), cur + 4 <= b.count else { return nil }
        let attrLen = Int(i32(cur))
        cur += 4
        guard attrLen >= 0, cur + attrLen <= b.count else { return nil }
        let body = cur
        if attrName == "channels" && attrType == "chlist" {
            var c = body
            let end = body + attrLen
            while c < end {
                if b[c] == 0 { c += 1; break }
                let ns = c
                while c < end && b[c] != 0 { c += 1 }
                guard c < end else { return nil }
                let cname = String(decoding: b[ns..<c], as: UTF8.self)
                c += 1
                guard c + 16 <= end else { return nil }
                let ptype = Int(Int32(bitPattern: UInt32(b[c]) | (UInt32(b[c + 1]) << 8) | (UInt32(b[c + 2]) << 16) | (UInt32(b[c + 3]) << 24)))
                let xs = UInt32(b[c + 8]) | (UInt32(b[c + 9]) << 8) | (UInt32(b[c + 10]) << 16) | (UInt32(b[c + 11]) << 24)
                let ys = UInt32(b[c + 12]) | (UInt32(b[c + 13]) << 8) | (UInt32(b[c + 14]) << 16) | (UInt32(b[c + 15]) << 24)
                guard (ptype == 1 || ptype == 2), xs == 1, ys == 1 else { return nil }
                channels.append(EXRChannel(name: cname, pixelType: ptype))
                c += 16
            }
        } else if attrName == "compression" && attrType == "compression" && attrLen == 1 {
            comp = Int(b[body])
        } else if attrName == "dataWindow" && attrType == "box2i" && attrLen == 16 {
            xMin = Int64(i32(body)); yMin = Int64(i32(body + 4))
            xMax = Int64(i32(body + 8)); yMax = Int64(i32(body + 12))
            hasBox = true
        }
        cur += attrLen
    }

    guard hasBox, xMax >= xMin, yMax >= yMin else { return nil }
    let w64 = xMax - xMin + 1, h64 = yMax - yMin + 1
    guard w64 > 0, h64 > 0 else { return nil }
    if w64 > Int64(ioMaxImagePixels) || h64 > Int64(ioMaxImagePixels) || w64 * h64 > Int64(ioMaxImagePixels) {
        tooLarge = true
        return nil
    }
    guard comp == 0 || comp == 2 || comp == 3, !channels.isEmpty else { return nil }

    let outMap: [Int]
    if channels.count == 1 && (channels[0].name == "Y" || channels[0].name == "Z") {
        outMap = [0]
    } else if let bi = channels.firstIndex(where: { $0.name == "B" }),
              let gi = channels.firstIndex(where: { $0.name == "G" }),
              let ri = channels.firstIndex(where: { $0.name == "R" }) {
        if let ai = channels.firstIndex(where: { $0.name == "A" }) {
            outMap = [bi, gi, ri, ai]
        } else {
            outMap = [bi, gi, ri]
        }
    } else {
        return nil
    }

    let w = Int(w64), h = Int(h64), outCh = outMap.count
    let linesPerBlock = comp == 3 ? 16 : 1
    let nBlocks = (h + linesPerBlock - 1) / linesPerBlock
    guard cur + nBlocks * 8 <= b.count else { return nil }
    let tableEnd = cur + nBlocks * 8

    let bytesPerLine = channels.reduce(0) { $0 + w * ($1.pixelType == 1 ? 2 : 4) }
    var chOffsets = [Int](repeating: 0, count: channels.count)
    do {
        var off = 0
        for ci in 0..<channels.count {
            chOffsets[ci] = off
            off += w * (channels[ci].pixelType == 1 ? 2 : 4)
        }
    }

    let out = IOMat(width: w, height: h, channels: outCh, depth: .f32)
    var scratch = [UInt8]()

    for blk in 0..<nBlocks {
        let off64 = u64(cur + blk * 8)
        guard off64 >= UInt64(tableEnd), off64 <= UInt64(b.count - 8) else { return nil }
        let off = Int(off64)
        let rowY = Int64(i32(off)) - yMin
        let packedSize = Int(i32(off + 4))
        guard rowY >= 0, rowY < h64, packedSize >= 0, off + 8 + packedSize <= b.count else { return nil }
        let lines = min(linesPerBlock, h - Int(rowY))
        let rawSize = lines * bytesPerLine
        let payloadStart = off + 8

        var useScratch = false
        if comp != 0 && packedSize < rawSize {
            // EXR ZIP/ZIPS wraps raw deflate inside a 2-byte zlib header + 4-byte adler32 trailer
            guard packedSize >= 6 else { return nil }
            if scratch.count < rawSize * 2 { scratch = [UInt8](repeating: 0, count: rawSize * 2) }
            let ok = scratch.withUnsafeMutableBufferPointer { dst in
                b.withUnsafeBufferPointer { src in
                    let tPtr = dst.baseAddress!
                    let dec = compression_decode_buffer(
                        tPtr, rawSize,
                        src.baseAddress! + payloadStart + 2, packedSize - 6,
                        nil, COMPRESSION_ZLIB
                    )
                    guard dec == rawSize else { return false }
                    if rawSize > 1 {
                        for i in 1..<rawSize {
                            tPtr[i] = UInt8(truncatingIfNeeded: Int(tPtr[i]) + Int(tPtr[i - 1]) - 128)
                        }
                    }
                    let uPtr = dst.baseAddress! + rawSize
                    let half1 = (rawSize + 1) / 2
                    for i in 0..<rawSize {
                        uPtr[i] = (i & 1) == 0 ? tPtr[i >> 1] : tPtr[half1 + (i >> 1)]
                    }
                    return true
                }
            }
            guard ok else { return nil }
            useScratch = true
        } else {
            guard packedSize == rawSize else { return nil }
        }

        out.bytes.withUnsafeMutableBytes { outRaw in
            let dstF = outRaw.bindMemory(to: Float.self).baseAddress!
            let decodeBlock: (UnsafePointer<UInt8>) -> Void = { base in
                for l in 0..<lines {
                    let lineBase = base + l * bytesPerLine
                    let dstRow = dstF + (Int(rowY) + l) * w * outCh
                    for (oc, ci) in outMap.enumerated() {
                        let cBase = lineBase + chOffsets[ci]
                        let isHalf = channels[ci].pixelType == 1
                        if isHalf {
                            for x in 0..<w {
                                var bits: UInt16 = 0
                                memcpy(&bits, cBase + x * 2, 2)
                                dstRow[x * outCh + oc] = Float(Float16(bitPattern: bits))
                            }
                        } else {
                            for x in 0..<w {
                                var v: Float = 0
                                memcpy(&v, cBase + x * 4, 4)
                                dstRow[x * outCh + oc] = v
                            }
                        }
                    }
                }
            }
            if useScratch {
                scratch.withUnsafeBufferPointer { sb in decodeBlock(sb.baseAddress! + rawSize) }
            } else {
                b.withUnsafeBufferPointer { src in decodeBlock(src.baseAddress! + payloadStart) }
            }
        }
    }

    return IOOwnImage(mat: out, kind: "exr")
}
