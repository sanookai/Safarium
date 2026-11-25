// SafariumRaster — Phase 1: structural ops that move elements without arithmetic: mixChannels (split/merge/extract/
// insert), flip, rotate, transpose, copyMakeBorder, LUT, borderInterpolate. Element types are handled by size
// (UInt8/16/32/64 bit patterns), so all seven depths share one code path.

import Foundation
import SafariumRasterC

@inline(__always) private func matAt(_ base: UnsafeRawPointer, _ i: Int) -> CoreMat {
    base.load(fromByteOffset: i * MemoryLayout<CoreMat>.stride, as: CoreMat.self)
}

// MARK: - mixChannels

private func copyPlane<E>(_ s: UnsafeRawPointer, _ scn: Int, _ sc: Int, _ d: UnsafeMutableRawPointer, _ dcn: Int, _ dc: Int,
                          _ cols: Int, _ e: E.Type) {
    let sp = s.assumingMemoryBound(to: E.self) + sc
    let dp = d.assumingMemoryBound(to: E.self) + dc
    if scn == 1 && dcn == 1 { for x in 0..<cols { dp[x] = sp[x] } }
    else { for x in 0..<cols { dp[x * dcn] = sp[x * scn] } }
}

@_silgen_name("sr_c_merge3_u8")
private func sr_c_merge3_u8(_ p0: UnsafePointer<UInt8>, _ s0: Int,
                            _ p1: UnsafePointer<UInt8>, _ s1: Int,
                            _ p2: UnsafePointer<UInt8>, _ s2: Int,
                            _ dst: UnsafeMutablePointer<UInt8>, _ dstep: Int,
                            _ w: Int32, _ h: Int32)

@inline(__always) private func rangesDisjoint(_ a: UnsafeRawPointer, _ aBytes: Int,
                                              _ b: UnsafeRawPointer, _ bBytes: Int) -> Bool {
    let a0 = Int(bitPattern: a), b0 = Int(bitPattern: b)
    return a0 + aBytes <= b0 || b0 + bBytes <= a0
}

/// srcs / dsts: contiguous arrays of CoreMat (40-byte structs). fromTo: npairs (srcChannel, dstChannel) pairs counted
/// across the concatenated channel lists; a negative source channel fills the destination channel with zeros.
@_cdecl("sr_core_mixchannels")
public func sr_core_mixchannels(_ nsrc: Int32, _ srcs: UnsafeRawPointer?, _ ndst: Int32, _ dsts: UnsafeRawPointer?,
                                _ npairs: Int32, _ fromTo: UnsafePointer<Int32>?) -> Int32 {
    guard let srcs, let dsts, let fromTo, nsrc > 0, ndst > 0 else { return srFail(SRStatus.badArgument, "mixChannels: empty") }
    var S: [CoreMat] = [], D: [CoreMat] = []
    for i in 0..<Int(nsrc) { S.append(matAt(srcs, i)) }
    for i in 0..<Int(ndst) { D.append(matAt(dsts, i)) }
    if let r = coreCheck(S + D, name: "mixChannels") { return r }
    let rows = S[0].rows, cols = S[0].cols
    // identity split / merge of 8-bit 3/4-channel images -> NEON / vImage
    var identity = Int(npairs) > 0
    for p in 0..<Int(npairs) where !(fromTo[2 * p] == fromTo[2 * p + 1]) { identity = false }
    if identity {
        if S.count == 1, D.count == Int(S[0].cn), Int(npairs) == D.count, D.allSatisfy({ $0.cn == 1 && $0.depth == 0 && $0.rows == rows && $0.cols == cols }),
           perfSplitU8(S[0], D) { return 0 }
        if D.count == 1, S.count == Int(D[0].cn), Int(npairs) == S.count, S.allSatisfy({ $0.cn == 1 && $0.depth == 0 && $0.rows == rows && $0.cols == cols }) {
            let dm = D[0]
            if dm.depth == 0 && S.count == 3 && dm.rows == rows && dm.cols == cols {
                if rows == 0 || cols == 0 { return 0 }
                if let dd = dm.data, let p0 = S[0].data, let p1 = S[1].data, let p2 = S[2].data {
                    let dSpan = (rows - 1) * dm.step + cols * 3
                    let s0Span = (rows - 1) * S[0].step + cols
                    let s1Span = (rows - 1) * S[1].step + cols
                    let s2Span = (rows - 1) * S[2].step + cols
                    if rangesDisjoint(dd, dSpan, p0, s0Span) &&
                       rangesDisjoint(dd, dSpan, p1, s1Span) &&
                       rangesDisjoint(dd, dSpan, p2, s2Span) {
                        sr_c_merge3_u8(p0.assumingMemoryBound(to: UInt8.self), S[0].step,
                                       p1.assumingMemoryBound(to: UInt8.self), S[1].step,
                                       p2.assumingMemoryBound(to: UInt8.self), S[2].step,
                                       dd.assumingMemoryBound(to: UInt8.self), dm.step,
                                       Int32(cols), Int32(rows))
                        return 0
                    }
                }
            }
            if perfMergeU8(S, dm) { return 0 }
        }
    }
    for m in S + D where m.rows != rows || m.cols != cols { return srFail(SRStatus.badArgument, "mixChannels: size mismatch") }
    func locate(_ list: [CoreMat], _ ch: Int) -> (Int, Int)? {
        var c = ch
        for (i, m) in list.enumerated() { if c < Int(m.cn) { return (i, c) }; c -= Int(m.cn) }
        return nil
    }
    for p in 0..<Int(npairs) {
        let f = Int(fromTo[2 * p]), t = Int(fromTo[2 * p + 1])
        guard let (di, dc) = locate(D, t) else { return srFail(SRStatus.badArgument, "mixChannels: dst channel out of range") }
        let dm = D[di]
        if f < 0 {
            for y in 0..<rows {
                let d = dm.row(y)
                let es = dm.elemSize
                for x in 0..<cols { memset(d + (x * Int(dm.cn) + dc) * es, 0, es) }
            }
            continue
        }
        guard let (si, sc) = locate(S, f) else { return srFail(SRStatus.badArgument, "mixChannels: src channel out of range") }
        let sm = S[si]
        guard sm.depth == dm.depth else { return srFail(SRStatus.badArgument, "mixChannels: depth mismatch") }
        for y in 0..<rows {
            let s = UnsafeRawPointer(sm.row(y)), d = dm.row(y)
            switch sm.elemSize {
            case 1: copyPlane(s, Int(sm.cn), sc, d, Int(dm.cn), dc, cols, UInt8.self)
            case 2: copyPlane(s, Int(sm.cn), sc, d, Int(dm.cn), dc, cols, UInt16.self)
            case 4: copyPlane(s, Int(sm.cn), sc, d, Int(dm.cn), dc, cols, UInt32.self)
            default: copyPlane(s, Int(sm.cn), sc, d, Int(dm.cn), dc, cols, UInt64.self)
            }
        }
    }
    return 0
}

// MARK: - flip / rotate / transpose

private func flipRowH<E>(_ s: UnsafeRawPointer, _ d: UnsafeMutableRawPointer, _ cols: Int, _ cn: Int, _ e: E.Type) {
    let sp = s.assumingMemoryBound(to: E.self), dp = d.assumingMemoryBound(to: E.self)
    if cn == 1 { for x in 0..<cols { dp[x] = sp[cols - 1 - x] } }
    else { for x in 0..<cols { let sx = (cols - 1 - x) * cn; let dx = x * cn; for c in 0..<cn { dp[dx + c] = sp[sx + c] } } }
}

private func flipRowHInPlace<E>(_ d: UnsafeMutableRawPointer, _ cols: Int, _ cn: Int, _ e: E.Type) {
    let dp = d.assumingMemoryBound(to: E.self)
    for x in 0..<(cols / 2) {
        let a = x * cn, b = (cols - 1 - x) * cn
        for c in 0..<cn { let t = dp[a + c]; dp[a + c] = dp[b + c]; dp[b + c] = t }
    }
}

private func flipRowDispatch(_ s: UnsafeRawPointer, _ d: UnsafeMutableRawPointer, _ cols: Int, _ cn: Int, _ es: Int) {
    switch es {
    case 1: flipRowH(s, d, cols, cn, UInt8.self)
    case 2: flipRowH(s, d, cols, cn, UInt16.self)
    case 4: flipRowH(s, d, cols, cn, UInt32.self)
    default: flipRowH(s, d, cols, cn, UInt64.self)
    }
}

/// code: 0 = around the x-axis (vertical flip), > 0 = around the y-axis (horizontal), < 0 = both. In place allowed.
@_cdecl("sr_core_flip")
public func sr_core_flip(_ src: MatP?, _ dst: MatP?, _ code: Int32) -> Int32 {
    guard let s = mat(src), let d = mat(dst), s.rows == d.rows, s.cols == d.cols, s.cn == d.cn, s.depth == d.depth else {
        return srFail(SRStatus.badArgument, "flip: size mismatch")
    }
    if let r = coreCheck([s, d], name: "flip") { return r }
    let rows = s.rows, cols = s.cols, cn = Int(s.cn), es = s.elemSize
    let rowBytes = cols * s.pixelBytes
    let inPlace = s.data == d.data && s.step == d.step
    let vert = code <= 0
    if code != 0 && !inPlace && (s.pixelBytes == 1 || s.pixelBytes == 3 || s.pixelBytes == 4) {
        for y in 0..<rows {
            let sy = vert ? rows - 1 - y : y
            src_fliph_row(UnsafePointer(s.row(sy).assumingMemoryBound(to: UInt8.self)), d.row(y).assumingMemoryBound(to: UInt8.self), Int32(cols), Int32(s.pixelBytes))
        }
        return 0
    }
    let horz = code != 0
    if inPlace {
        if vert {
            let tmp = Scratch(rowBytes)
            for y in 0..<(rows / 2) {
                let a = s.row(y), b = s.row(rows - 1 - y)
                if horz {
                    flipRowDispatch(a, tmp.p, cols, cn, es); flipRowDispatch(b, a, cols, cn, es); memcpy(b, tmp.p, rowBytes)
                } else { memcpy(tmp.p, a, rowBytes); memcpy(a, b, rowBytes); memcpy(b, tmp.p, rowBytes) }
            }
            if horz && rows % 2 == 1 { flipRowInPlace(s.row(rows / 2), cols, cn, es) }
        } else {
            for y in 0..<rows { flipRowInPlace(s.row(y), cols, cn, es) }
        }
        return 0
    }
    for y in 0..<rows {
        let sy = vert ? rows - 1 - y : y
        if horz { flipRowDispatch(s.row(sy), d.row(y), cols, cn, es) } else { memcpy(d.row(y), s.row(sy), rowBytes) }
    }
    return 0
}

private func flipRowInPlace(_ d: UnsafeMutableRawPointer, _ cols: Int, _ cn: Int, _ es: Int) {
    switch es {
    case 1: flipRowHInPlace(d, cols, cn, UInt8.self)
    case 2: flipRowHInPlace(d, cols, cn, UInt16.self)
    case 4: flipRowHInPlace(d, cols, cn, UInt32.self)
    default: flipRowHInPlace(d, cols, cn, UInt64.self)
    }
}

/// Pixel-granular transpose into dst (cols x rows). `mode`: 0 transpose, 1 rotate 90 CW, 2 rotate 90 CCW.
private func transposeKernel<E>(_ s: CoreMat, _ d: CoreMat, _ mode: Int, _ e: E.Type) {
    let sr = s.rows, sc = s.cols, cn = Int(s.cn)
    let B = 32
    var by = 0
    while by < sr {
        let ye = min(by + B, sr)
        var bx = 0
        while bx < sc {
            let xe = min(bx + B, sc)
            for y in by..<ye {
                let sp = s.row(y).assumingMemoryBound(to: E.self)
                for x in bx..<xe {
                    // destination pixel for source (y, x)
                    let dy: Int, dx: Int
                    switch mode {
                    case 0: dy = x; dx = y
                    case 1: dy = x; dx = sr - 1 - y          // 90 CW
                    default: dy = sc - 1 - x; dx = y         // 90 CCW
                    }
                    let dp = d.row(dy).assumingMemoryBound(to: E.self) + dx * cn
                    let sp2 = sp + x * cn
                    if cn == 1 { dp[0] = sp2[0] } else { for c in 0..<cn { dp[c] = sp2[c] } }
                }
            }
            bx += B
        }
        by += B
    }
}

private func transposeDispatch(_ s: CoreMat, _ d: CoreMat, _ mode: Int) {
    src_transpose(s.data!.assumingMemoryBound(to: UInt8.self), s.step, Int32(s.rows), Int32(s.cols),
                  d.data!.assumingMemoryBound(to: UInt8.self), d.step, Int32(s.pixelBytes), Int32(mode))
}

/// code: 0 = 90 clockwise, 1 = 180, 2 = 90 counter-clockwise (cv::RotateFlags). dst must not alias src for 90-degree turns.
@_cdecl("sr_core_rotate")
public func sr_core_rotate(_ src: MatP?, _ dst: MatP?, _ code: Int32) -> Int32 {
    guard let s = mat(src), let d = mat(dst), s.depth == d.depth, s.cn == d.cn else { return srFail(SRStatus.badArgument, "rotate: mismatch") }
    if let r = coreCheck([s, d], name: "rotate") { return r }
    switch code {
    case 1:
        guard s.rows == d.rows, s.cols == d.cols else { return srFail(SRStatus.badArgument, "rotate: size mismatch") }
        return sr_core_flip(src, dst, -1)
    case 0, 2:
        guard s.rows == d.cols, s.cols == d.rows else { return srFail(SRStatus.badArgument, "rotate: size mismatch") }
        transposeDispatch(s, d, code == 0 ? 1 : 2)
        return 0
    default: return srFail(SRStatus.badArgument, "rotate: unknown rotation code")
    }
}

@_cdecl("sr_core_transpose")
public func sr_core_transpose(_ src: MatP?, _ dst: MatP?) -> Int32 {
    guard let s = mat(src), let d = mat(dst), s.depth == d.depth, s.cn == d.cn, s.rows == d.cols, s.cols == d.rows else {
        return srFail(SRStatus.badArgument, "transpose: mismatch")
    }
    if let r = coreCheck([s, d], name: "transpose") { return r }
    transposeDispatch(s, d, 0)
    return 0
}

// MARK: - borders

/// cv::borderInterpolate. Returns -1 for BORDER_CONSTANT outside the range; -2 for an unsupported border type.
@_cdecl("sr_core_border_interpolate")
public func sr_core_border_interpolate(_ p: Int32, _ len: Int32, _ borderType: Int32) -> Int32 {
    Int32(borderIndex(Int(p), Int(len), borderType & ~16))
}

@inline(__always) func borderIndex(_ p0: Int, _ len: Int, _ type: Int32) -> Int {
    var p = p0
    if p >= 0 && p < len { return p }
    if len <= 0 { return type == 0 ? -1 : -2 }
    switch type {
    case 1: return p < 0 ? 0 : len - 1
    case 2, 4:
        if len == 1 { return 0 }
        let delta = type == 4 ? 1 : 0
        repeat {
            if p < 0 { p = -p - 1 + delta } else { p = len - 1 - (p - len) - delta }
        } while p < 0 || p >= len
        return p
    case 3:
        if p < 0 { p -= ((p - len + 1) / len) * len }
        if p >= len { p %= len }
        return p
    case 0: return -1
    default: return -2
    }
}

/// dst is (rows + top + bottom) x (cols + left + right); value holds the constant for BORDER_CONSTANT (4 doubles).
@_cdecl("sr_core_copymakeborder")
public func sr_core_copymakeborder(_ src: MatP?, _ dst: MatP?, _ top: Int32, _ left: Int32, _ borderType: Int32,
                                   _ value: UnsafePointer<Double>?) -> Int32 {
    guard let s = mat(src), let d = mat(dst), s.depth == d.depth, s.cn == d.cn else { return srFail(SRStatus.badArgument, "copyMakeBorder: mismatch") }
    if let r = coreCheck([s, d], name: "copyMakeBorder") { return r }
    let top = Int(top), left = Int(left)
    let type = borderType & ~16
    guard type >= 0, type <= 4 else { return srFail(SRStatus.unsupported, "copyMakeBorder: unsupported border type \(borderType)") }
    guard top >= 0, left >= 0, d.rows >= s.rows + top, d.cols >= s.cols + left else { return srFail(SRStatus.badArgument, "copyMakeBorder: bad size") }
    let pb = s.pixelBytes, cn = Int(s.cn), es = s.elemSize
    // constant pixel bytes
    let constPix = Scratch(pb)
    defer { withExtendedLifetime(constPix) {} }
    if type == 0 {
        withTemp(cn, Double.self) { v in
            for c in 0..<cn { v[c] = value.map { cn > 4 ? $0[0] : scalarChannel($0, c) } ?? 0 }   // cv2: > 4 channels take value[0]
            storeRowD(s.depth, v, cn, constPix.p)
        }
    }
    let bottom = d.rows - s.rows - top, right = d.cols - s.cols - left
    let rc = src_copyborder(s.data!.assumingMemoryBound(to: UInt8.self), s.step, Int32(s.rows), Int32(s.cols),
                            d.data!.assumingMemoryBound(to: UInt8.self), d.step, Int32(top), Int32(bottom), Int32(left), Int32(right),
                            Int32(pb), type, constPix.ptr(UInt8.self))
    if rc != 0 { return srFail(SRStatus.badArgument, "copyMakeBorder: out of memory") }
    _ = es
    return 0
}

// MARK: - LUT

/// dst[x] = lut[src[x] (+128 for s8)] ; lutCn is 1 (shared) or src.cn. lut holds 256 entries of lutCn channels.
@_cdecl("sr_core_lut")
public func sr_core_lut(_ src: MatP?, _ lut: UnsafeRawPointer?, _ lutCn: Int32, _ dst: MatP?) -> Int32 {
    guard let s = mat(src), let d = mat(dst), let lut, s.depth <= 1, s.rows == d.rows, s.cols == d.cols, s.cn == d.cn,
          lutCn == 1 || lutCn == s.cn else { return srFail(SRStatus.badArgument, "LUT: bad operands") }
    if let r = coreCheck([s, d], name: "LUT") { return r }
    let cn = Int(s.cn), lc = Int(lutCn), n = s.n
    if lc == 1 && d.depth <= 1 { perfLutU8(s, d, lut.assumingMemoryBound(to: UInt8.self)); return 0 }
    let off = 0   // OpenCV 5.1 indexes the table with the raw byte, also for CV_8S sources
    @inline(__always) func run<E>(_ e: E.Type) {
        let l = lut.assumingMemoryBound(to: E.self)
        for y in 0..<s.rows {
            let sp = s.row(y).assumingMemoryBound(to: UInt8.self)
            let dp = d.row(y).assumingMemoryBound(to: E.self)
            if lc == 1 {
                if off == 0 { for i in 0..<n { dp[i] = l[Int(sp[i])] } }
                else { for i in 0..<n { dp[i] = l[Int(Int8(bitPattern: sp[i])) + 128] } }
            } else {
                for x in 0..<s.cols { for c in 0..<cn {
                    let v = Int(off == 0 ? Int(sp[x * cn + c]) : Int(Int8(bitPattern: sp[x * cn + c])) + 128)
                    dp[x * cn + c] = l[v * lc + c]
                } }
            }
        }
    }
    switch d.elemSize {
    case 1: run(UInt8.self)
    case 2: run(UInt16.self)
    case 4: run(UInt32.self)
    default: run(UInt64.self)
    }
    return 0
}
