// SafariumRaster — own OpenEXR writer (Area C): scanline images, FLOAT or HALF samples (IMWRITE_EXR_TYPE), compression
// NONE / ZIPS / ZIP (IMWRITE_EXR_COMPRESSION 0 / 2 / 3; other codes fall back to ZIP). ImageIO's EXR encoder stores half
// floats only, so full 32-bit output needs this writer. Layout per the OpenEXR file-layout specification (public).

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
