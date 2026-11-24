// SafariumRaster — Phase 1: reductions (reduce, norm, mean/meanStdDev/sum, minMaxLoc, countNonZero, findNonZero).
// Accumulation order follows OpenCV's reduceR_/reduceC_ so float sums agree to the last bit where OpenCV is
// deterministic (reduceC_ unrolls by four with two accumulators).

import Foundation
import Accelerate
import SafariumRasterC

protocol Acc {
    static var depthCodeForAcc: Int32 { get }
    static func plus(_ a: Self, _ b: Self) -> Self
    static func mx(_ a: Self, _ b: Self) -> Self
    static func mn(_ a: Self, _ b: Self) -> Self
}
extension Int64: Acc {
    static var depthCodeForAcc: Int32 { -1 }
    @inline(__always) static func plus(_ a: Int64, _ b: Int64) -> Int64 { a &+ b }
    @inline(__always) static func mx(_ a: Int64, _ b: Int64) -> Int64 { b > a ? b : a }
    @inline(__always) static func mn(_ a: Int64, _ b: Int64) -> Int64 { b < a ? b : a }
}
extension Float: Acc {
    static var depthCodeForAcc: Int32 { 5 }
    @inline(__always) static func plus(_ a: Float, _ b: Float) -> Float { a + b }
    @inline(__always) static func mx(_ a: Float, _ b: Float) -> Float { b > a ? b : a }
    @inline(__always) static func mn(_ a: Float, _ b: Float) -> Float { b < a ? b : a }
}
extension Double: Acc {
    static var depthCodeForAcc: Int32 { 6 }
    @inline(__always) static func plus(_ a: Double, _ b: Double) -> Double { a + b }
    @inline(__always) static func mx(_ a: Double, _ b: Double) -> Double { b > a ? b : a }
    @inline(__always) static func mn(_ a: Double, _ b: Double) -> Double { b < a ? b : a }
}

@inline(__always) private func combine<W: Acc>(_ op: Int32, _ a: W, _ b: W) -> W {
    switch op { case 2: return W.mx(a, b); case 3: return W.mn(a, b); default: return W.plus(a, b) }
}

private func reduceGeneric<W: Acc>(_ w: W.Type, _ s: CoreMat, _ d: CoreMat, _ dim: Int32, _ op: Int32, _ scale: Double,
                                   _ load: (Int32, UnsafeRawPointer, Int, UnsafeMutablePointer<W>) -> Void,
                                   _ store: (Int32, UnsafePointer<W>, Int, UnsafeMutableRawPointer) -> Void,
                                   _ avgStore: (UnsafePointer<W>, Int, UnsafeMutableRawPointer, Double) -> Void) {
    let n = s.n, cn = Int(s.cn)
    let bufA = Scratch(n * 8), bufB = Scratch(n * 8)
    let acc = bufA.ptr(W.self), tmp = bufB.ptr(W.self)
    defer { withExtendedLifetime(bufA) {}; withExtendedLifetime(bufB) {} }
    if dim == 0 {
        load(s.depth, s.row(0), n, acc)
        if s.rows > 1 {
            for y in 1..<s.rows {
                load(s.depth, s.row(y), n, tmp)
                for i in 0..<n { acc[i] = combine(op, acc[i], tmp[i]) }
            }
        }
        if op == 1 { avgStore(acc, n, d.row(0), scale) } else { store(d.depth, acc, n, d.row(0)) }
    } else {
        let outS = Scratch(s.rows * cn * 8)
        let out = outS.ptr(W.self)
        defer { withExtendedLifetime(outS) {} }
        let cop: Int32 = op == 1 ? 0 : op
        let width = n
        if W.self == Float.self && cn == 1 && cop == 0 && s.depth == 5 {
            // OpenCV 5.1 vectorised reduceC for f32 single-channel SUM/AVG (see src_rowsum_f32): four rows at a time.
            src_rowsum_f32(s.data!.assumingMemoryBound(to: UInt8.self), s.step, Int32(s.rows), Int32(width),
                           UnsafeMutableRawPointer(out).assumingMemoryBound(to: Float.self))
        } else {
        for y in 0..<s.rows {
            let direct = s.depth == W.self.depthCodeForAcc   // source already in the accumulator type: no copy
            if !direct { load(s.depth, s.row(y), n, tmp) }
            let src: UnsafeMutablePointer<W> = direct ? s.row(y).assumingMemoryBound(to: W.self) : tmp
            let o = out + y * cn
            if W.self == Float.self && cn == 1 && cop == 0 {
                // OpenCV 5.1 vectorised reduceC for f32 single-channel SUM/AVG: four 4-lane accumulators over 16-wide blocks,
                // folded as (v0+v1)+(v2+v3), then 4-wide blocks, then (l0+l1)+(l2+l3), then a sequential tail.
                let t = UnsafeRawPointer(src)
                var v0 = SIMD4<Float>(), v1 = SIMD4<Float>(), v2 = SIMD4<Float>(), v3 = SIMD4<Float>()
                var i = 0
                while i + 16 <= width {
                    v0 += t.loadUnaligned(fromByteOffset: i * 4, as: SIMD4<Float>.self)
                    v1 += t.loadUnaligned(fromByteOffset: (i + 4) * 4, as: SIMD4<Float>.self)
                    v2 += t.loadUnaligned(fromByteOffset: (i + 8) * 4, as: SIMD4<Float>.self)
                    v3 += t.loadUnaligned(fromByteOffset: (i + 12) * 4, as: SIMD4<Float>.self)
                    i += 16
                }
                var v = (v0 + v1) + (v2 + v3)
                while i + 4 <= width { v += t.loadUnaligned(fromByteOffset: i * 4, as: SIMD4<Float>.self); i += 4 }
                var acc = (v[0] + v[1]) + (v[2] + v[3])
                let tf = t.assumingMemoryBound(to: Float.self)
                while i < width { acc += tf[i]; i += 1 }
                UnsafeMutableRawPointer(o).assumingMemoryBound(to: Float.self).pointee = acc
            } else if W.self == Double.self && cn == 1 && cop == 0 {
                // f64 single-channel: same scheme with 2-lane vectors (8-wide blocks).
                let t = UnsafeRawPointer(src)
                var v0 = SIMD2<Double>(), v1 = SIMD2<Double>(), v2 = SIMD2<Double>(), v3 = SIMD2<Double>()
                var i = 0
                while i + 8 <= width {
                    v0 += t.loadUnaligned(fromByteOffset: i * 8, as: SIMD2<Double>.self)
                    v1 += t.loadUnaligned(fromByteOffset: (i + 2) * 8, as: SIMD2<Double>.self)
                    v2 += t.loadUnaligned(fromByteOffset: (i + 4) * 8, as: SIMD2<Double>.self)
                    v3 += t.loadUnaligned(fromByteOffset: (i + 6) * 8, as: SIMD2<Double>.self)
                    i += 8
                }
                var v = (v0 + v1) + (v2 + v3)
                while i + 2 <= width { v += t.loadUnaligned(fromByteOffset: i * 8, as: SIMD2<Double>.self); i += 2 }
                var acc = v[0] + v[1]
                let tf = t.assumingMemoryBound(to: Double.self)
                while i < width { acc += tf[i]; i += 1 }
                UnsafeMutableRawPointer(o).assumingMemoryBound(to: Double.self).pointee = acc
            } else {
                for k in 0..<cn {
                    var a = src[k]
                    var i = cn + k
                    while i < width { a = combine(cop, a, src[i]); i += cn }
                    o[k] = a
                }
            }
        }
        }
        // d is rows x 1 (cn channels): one pixel per row. A packed destination column is converted in one call.
        if packed(d) {
            if op == 1 { avgStore(out, s.rows * cn, d.data!, scale) } else { store(d.depth, out, s.rows * cn, d.data!) }
        } else {
            for y in 0..<s.rows {
                if op == 1 { avgStore(out + y * cn, cn, d.row(y), scale) } else { store(d.depth, out + y * cn, cn, d.row(y)) }
            }
        }
    }
}

/// rtype: 0 SUM, 1 AVG, 2 MAX, 3 MIN. dim 0 reduces to a single row, 1 to a single column. Depth combinations are
/// validated by the caller (see _core.py).
@_cdecl("sr_core_reduce")
public func sr_core_reduce(_ src: MatP?, _ dst: MatP?, _ dim: Int32, _ rtype: Int32) -> Int32 {
    guard let s = mat(src), let d = mat(dst), s.cn == d.cn, s.rows > 0, s.cols > 0 else { return srFail(SRStatus.badArgument, "reduce: bad operands") }
    if let r = coreCheck([s, d], name: "reduce") { return r }
    if dim == 0 { guard d.rows == 1, d.cols == s.cols else { return srFail(SRStatus.badArgument, "reduce: dst size") } }
    else { guard d.cols == 1, d.rows == s.rows else { return srFail(SRStatus.badArgument, "reduce: dst size") } }
    let cnt = dim == 0 ? s.rows : s.cols
    let scale = 1.0 / Double(cnt)
    let intSrc = s.depth < 5
    if s.depth == 0 && s.cn == 1 && perfReduceU8(s, d, dim, rtype, scale) { return 0 }
    if rtype == 2 || rtype == 3 {
        guard s.depth == d.depth else { return srFail(SRStatus.badArgument, "reduce: MIN/MAX need dtype == src depth") }
        reduceGeneric(Double.self, s, d, dim, rtype, scale, loadRowD, storeRowD, { _, _, _, _ in })
    } else if intSrc && d.depth < 5 {
        reduceGeneric(Int64.self, s, d, dim, rtype, scale, loadRowI, storeRowI) { acc, n, out, sc in
            withTemp(n, Double.self) { t in
                if d.depth < 4 {   // OpenCV 5.1 multiplies the integer sum by a float32 1/n when the result is 8/16-bit (ties round up on 106.50001)
                    let f = Float(sc)
                    for i in 0..<n { t[i] = Double(Float(acc[i]) * f) }
                } else {
                    for i in 0..<n { t[i] = Double(acc[i]) * sc }
                }
                storeRowD(d.depth, t, n, out)
            }
        }
    } else if d.depth == 5 {
        reduceGeneric(Float.self, s, d, dim, rtype, scale, loadRowF, storeRowF) { acc, n, out, sc in
            withTemp(n, Float.self) { t in
                let f = Float(sc)
                for i in 0..<n { t[i] = acc[i] * f }
                storeRowF(d.depth, t, n, out)
            }
        }
    } else {
        reduceGeneric(Double.self, s, d, dim, rtype, scale, loadRowD, storeRowD) { acc, n, out, sc in
            withTemp(n, Double.self) { t in
                for i in 0..<n { t[i] = acc[i] * sc }
                storeRowD(d.depth, t, n, out)
            }
        }
    }
    return 0
}

// MARK: - norm

/// normType: 1 INF, 2 L1, 4 L2, 5 L2SQR (already masked to the low bits). Result via out[0]. b optional (norm of a - b).
@_cdecl("sr_core_norm")
public func sr_core_norm(_ a: MatP?, _ b: MatP?, _ mask: MatP?, _ normType: Int32, _ out: UnsafeMutablePointer<Double>?) -> Int32 {
    guard let a = mat(a), let out else { return srFail(SRStatus.badArgument, "norm: missing operand") }
    let bm = mat(b), mm = mat(mask)
    if let r = coreCheck([a, bm, mm], name: "norm") { return r }
    if let b = bm, !(b.rows == a.rows && b.cols == a.cols && b.cn == a.cn && b.depth == a.depth) { return srFail(SRStatus.badArgument, "norm: operand mismatch") }
    if let m = mm, !(m.rows == a.rows && m.cols == a.cols && m.depth <= 1) { return srFail(SRStatus.badArgument, "norm: mask mismatch") }
    let n = a.n, cn = Int(a.cn)

    if normType == 6 || normType == 7 {   // Hamming on bytes
        guard a.depth == 0 else { return srFail(SRStatus.badArgument, "norm: HAMMING needs CV_8U") }
        var total = 0
        for y in 0..<a.rows {
            let p = a.row(y).assumingMemoryBound(to: UInt8.self)
            let q = bm?.row(y).assumingMemoryBound(to: UInt8.self)
            let m = mm?.row(y).assumingMemoryBound(to: UInt8.self)
            for x in 0..<a.cols {
                if let m = m, m[x] == 0 { continue }
                for c in 0..<cn {
                    let v = q != nil ? (p[x * cn + c] ^ q![x * cn + c]) : p[x * cn + c]
                    if normType == 6 { total += v.nonzeroBitCount }
                    else { total += ((v & 3) != 0 ? 1 : 0) + ((v & 12) != 0 ? 1 : 0) + ((v & 48) != 0 ? 1 : 0) + ((v & 192) != 0 ? 1 : 0) }
                }
            }
        }
        out[0] = Double(total)
        return 0
    }
    if mm == nil && a.depth == 0 {
        var accU: UInt64 = 0
        var mxU: UInt8 = 0
        var su = [UInt64](repeating: 0, count: 4), qu = [UInt64](repeating: 0, count: 4)
        for y in 0..<a.rows {
            let pa = a.row(y).assumingMemoryBound(to: UInt8.self)
            if let b = bm {
                let pb = b.row(y).assumingMemoryBound(to: UInt8.self)
                if normType == 1 { mxU = Swift.max(mxU, src_maxabsdiff_u8(pa, pb, n)); continue }
                if normType == 2 { su[0] += src_sum_absdiff_u8(pa, pb, n) } else { qu[0] += src_sumsq_absdiff_u8(pa, pb, n) }
            } else if normType == 1 { var lo: UInt8 = 0, hi: UInt8 = 0; src_minmax_u8(pa, n, &lo, &hi); mxU = Swift.max(mxU, hi) }
            else if normType == 2 { su[0] += src_sum_u8(pa, n) } else { qu[0] += src_sumsq_u8(pa, n) }
        }
        accU = normType == 2 ? su[0] : qu[0]
        switch normType {
        case 1: out[0] = Double(mxU)
        case 2: out[0] = Double(accU)
        case 4: out[0] = Double(accU).squareRoot()
        default: out[0] = Double(accU)
        }
        return 0
    }
    if mm == nil && a.depth == 5 && normType == 1 {
        var mx: Float = 0
        for y in 0..<a.rows {
            let v = src_maxabs_f32(UnsafePointer(a.row(y).assumingMemoryBound(to: Float.self)), bm.map { UnsafePointer($0.row(y).assumingMemoryBound(to: Float.self)) }, n)
            if v > mx || v.isNaN { mx = v }
            if mx.isNaN { break }
        }
        out[0] = Double(mx)
        return 0
    }
    if mm == nil && a.depth == 5 {
        var acc = 0.0, mx: Float = 0
        withTemp(2048, Float.self) { tf in
            withTemp(2048, Double.self) { td in
                for y in 0..<a.rows {
                    let pa = a.row(y).assumingMemoryBound(to: Float.self)
                    let pb = bm?.row(y).assumingMemoryBound(to: Float.self)
                    var x = 0
                    while x < n {
                        let m = Swift.min(2048, n - x)
                        var src = UnsafePointer(pa + x)
                        if let pb = pb { vDSP_vsub(pb + x, 1, pa + x, 1, tf, 1, vDSP_Length(m)); src = UnsafePointer(tf) }
                        if normType == 1 { var v: Float = 0; vDSP_maxmgv(src, 1, &v, vDSP_Length(m)); if v > mx || v.isNaN { mx = v } }
                        else {
                            vDSP_vspdp(src, 1, td, 1, vDSP_Length(m))
                            var v = 0.0
                            if normType == 2 { vDSP_svemgD(td, 1, &v, vDSP_Length(m)) } else { vDSP_svesqD(td, 1, &v, vDSP_Length(m)) }
                            acc += v
                        }
                        x += m
                    }
                }
            }
        }
        switch normType {
        case 1: out[0] = Double(mx)
        case 4: out[0] = acc.squareRoot()
        default: out[0] = acc
        }
        return 0
    }
    let wA = Scratch(n * 8), wB = Scratch(n * 8)
    defer { withExtendedLifetime(wA) {}; withExtendedLifetime(wB) {} }
    var acc = 0.0
    var inf = 0.0
    for y in 0..<a.rows {
        let xa = wA.ptr(Double.self)
        let ra = a.row(y)
        loadRowD(a.depth, ra, n, xa)
        if let b = bm {
            let xb = wB.ptr(Double.self)
            loadRowD(b.depth, b.row(y), n, xb)
            for i in 0..<n { xa[i] = (xa[i] - xb[i]).magnitude }
        } else {
            for i in 0..<n { xa[i] = xa[i].magnitude }
        }
        if let m = mm {
            let mp = m.row(y).assumingMemoryBound(to: UInt8.self)
            for x in 0..<a.cols where mp[x] == 0 { for c in 0..<cn { xa[x * cn + c] = 0 } }
        }
        switch normType {
        case 1: for i in 0..<n { let v = xa[i]; if v > inf { inf = v } }
        case 2: var s = 0.0; for i in 0..<n { s += xa[i] }; acc += s
        default: var s = 0.0; for i in 0..<n { s += xa[i] * xa[i] }; acc += s
        }
    }
    switch normType {
    case 1: out[0] = inf
    case 2: out[0] = acc
    case 4: out[0] = acc.squareRoot()
    default: out[0] = acc
    }
    return 0
}

// MARK: - sum / mean / meanStdDev

/// fused multiply-add c + a * b with one rounding (OpenCV's meanStdDev evaluates sq * scale - mean * mean this way on arm64).
@_cdecl("sr_core_fma")
public func sr_core_fma(_ a: Double, _ b: Double, _ c: Double) -> Double { c.addingProduct(a, b) }

/// out: sum[4], sqsum[4], count (as double). Channel counts above 4 are rejected.
@_cdecl("sr_core_sums")
public func sr_core_sums(_ a: MatP?, _ mask: MatP?, _ out: UnsafeMutablePointer<Double>?, _ wantSq: Int32) -> Int32 {
    guard let a = mat(a), let out, a.cn <= 4 else { return srFail(SRStatus.badArgument, "sum: need 1-4 channels") }
    let mm = mat(mask)
    if let r = coreCheck([a, mm], name: "sum") { return r }
    let n = a.n, cn = Int(a.cn)
    if let m = mm, m.rows != a.rows || m.cols != a.cols { return srFail(SRStatus.badArgument, "sum: mask size mismatch") }
    if a.depth == 0, (mm == nil || mm!.depth <= 1) {
        // u8 (masked or not): exact integer sums in SIMD; the masked kernel zeroes unselected pixels and popcounts the mask.
        var su: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0), qu: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
        var cnt: UInt64 = 0
        withUnsafeMutablePointer(to: &su) { sp in withUnsafeMutablePointer(to: &qu) { qp in
            let s64 = UnsafeMutableRawPointer(sp).assumingMemoryBound(to: UInt64.self), q64 = UnsafeMutableRawPointer(qp).assumingMemoryBound(to: UInt64.self)
            if let m = mm {
                for y in 0..<a.rows {
                    src_sums_u8_mask(a.row(y).assumingMemoryBound(to: UInt8.self), m.row(y).assumingMemoryBound(to: UInt8.self), a.cols, Int32(cn), s64, q64, &cnt, wantSq)
                }
            } else {
                for y in 0..<a.rows { src_sums_u8_cn(a.row(y).assumingMemoryBound(to: UInt8.self), a.cols, Int32(cn), s64, q64, wantSq) }
                cnt = UInt64(a.rows) * UInt64(a.cols)
            }
            for c in 0..<4 { out[c] = Double(s64[c]); out[4 + c] = Double(q64[c]) }
        } }
        out[8] = Double(cnt)
        return 0
    }
    let wS = Scratch(n * 8)
    let w = wS.ptr(Double.self)
    defer { withExtendedLifetime(wS) {} }
    var s = [Double](repeating: 0, count: 4), q = [Double](repeating: 0, count: 4)
    var count = 0.0
    if mm == nil && a.depth == 5 {
        for y in 0..<a.rows { perfSumsF32Row(a.row(y).assumingMemoryBound(to: Float.self), n, cn, &s, &q, true) }
        for c in 0..<4 { out[c] = s[c]; out[4 + c] = q[c] }
        out[8] = Double(a.rows * a.cols)
        return 0
    }
    for y in 0..<a.rows {
        loadRowD(a.depth, a.row(y), n, w)
        if let m = mm {
            let mp = m.row(y).assumingMemoryBound(to: UInt8.self)
            for x in 0..<a.cols where mp[x] != 0 {
                count += 1
                for c in 0..<cn { let v = w[x * cn + c]; s[c] += v; q[c] += v * v }
            }
        } else {
            count += Double(a.cols)
            if cn == 1 { var s0 = 0.0, q0 = 0.0; for i in 0..<n { let v = w[i]; s0 += v; q0 += v * v }; s[0] += s0; q[0] += q0 }
            else { for x in 0..<a.cols { for c in 0..<cn { let v = w[x * cn + c]; s[c] += v; q[c] += v * v } } }
        }
    }
    for c in 0..<4 { out[c] = s[c]; out[4 + c] = q[c] }
    out[8] = count
    return 0
}

// MARK: - minMaxLoc / nonzero

/// out: [min, max, minX, minY, maxX, maxY, found]. Single-channel; first occurrence wins.
@_cdecl("sr_core_minmaxloc")
public func sr_core_minmaxloc(_ a: MatP?, _ mask: MatP?, _ out: UnsafeMutablePointer<Double>?) -> Int32 {
    guard let a = mat(a), let out, a.cn == 1 else { return srFail(SRStatus.badArgument, "minMaxLoc: need a single channel") }
    let mm = mat(mask)
    if let r = coreCheck([a, mm], name: "minMaxLoc") { return r }
    let n = a.n
    if a.depth >= 5 {   // cv2 lets NaN poison both extrema (value NaN, location of the first NaN)
        let tmpS = Scratch(n * 8)
        defer { withExtendedLifetime(tmpS) {} }
        for y in 0..<a.rows {
            var hit: Int? = nil
            let mp = mm?.row(y).assumingMemoryBound(to: UInt8.self)
            if mp == nil && a.depth == 5 { break }   // handled after the vector min/max below (NEON min/max propagate NaN)
            else {
                let t = tmpS.ptr(Double.self)
                loadRowD(a.depth, a.row(y), n, t)
                for x in 0..<n where t[x] != t[x] && (mp == nil || mp![x] != 0) { hit = x; break }
            }
            if let x = hit {
                out[0] = .nan; out[1] = .nan; out[2] = Double(x); out[3] = Double(y); out[4] = Double(x); out[5] = Double(y); out[6] = 1
                return 0
            }
        }
    }
    let wS = Scratch(n * 8)
    let w = wS.ptr(Double.self)
    defer { withExtendedLifetime(wS) {} }
    var mn = Double.infinity, mx = -Double.infinity
    var mnX = 0, mnY = 0, mxX = 0, mxY = 0
    var found = false
    if mm == nil && (a.depth == 0 || a.depth == 5) && n > 0 && a.rows > 0 {
        for y in 0..<a.rows {
            if a.depth == 0 {
                let p = a.row(y).assumingMemoryBound(to: UInt8.self)
                var lo: UInt8 = 0, hi: UInt8 = 0
                src_minmax_u8(p, n, &lo, &hi)
                if !found || Double(lo) < mn { mn = Double(lo); var x = 0; while p[x] != lo { x += 1 }; mnX = x; mnY = y }
                if !found || Double(hi) > mx { mx = Double(hi); var x = 0; while p[x] != hi { x += 1 }; mxX = x; mxY = y }
            } else {
                let p = a.row(y).assumingMemoryBound(to: Float.self)
                var lo: Float = 0, hi: Float = 0
                src_minmax_f32(p, n, &lo, &hi)
                if lo.isNaN || hi.isNaN {
                    let x = perfFirstNaNF32(p, n) ?? 0
                    out[0] = .nan; out[1] = .nan; out[2] = Double(x); out[3] = Double(y); out[4] = Double(x); out[5] = Double(y); out[6] = 1
                    return 0
                }
                if !found || Double(lo) < mn { mn = Double(lo); var x = 0; while p[x] != lo { x += 1 }; mnX = x; mnY = y }
                if !found || Double(hi) > mx { mx = Double(hi); var x = 0; while p[x] != hi { x += 1 }; mxX = x; mxY = y }
            }
            found = true
        }
        out[0] = mn; out[1] = mx; out[2] = Double(mnX); out[3] = Double(mnY); out[4] = Double(mxX); out[5] = Double(mxY); out[6] = 1
        return 0
    }
    for y in 0..<a.rows {
        loadRowD(a.depth, a.row(y), n, w)
        if let m = mm {
            let mp = m.row(y).assumingMemoryBound(to: UInt8.self)
            for x in 0..<n where mp[x] != 0 {
                let v = w[x]
                if !found { mn = v; mx = v; mnX = x; mnY = y; mxX = x; mxY = y; found = true; continue }
                if v < mn { mn = v; mnX = x; mnY = y }
                if v > mx { mx = v; mxX = x; mxY = y }
            }
        } else {
            var x0 = 0
            if !found && n > 0 { mn = w[0]; mx = w[0]; mnX = 0; mnY = y; mxX = 0; mxY = y; found = true; x0 = 1 }
            // two passes keep the inner loops branch-light: value scan first, location only on improvement
            var lmn = mn, lmx = mx
            for x in x0..<n { let v = w[x]; lmn = v < lmn ? v : lmn; lmx = v > lmx ? v : lmx }
            if lmn < mn { mn = lmn; var x = 0; while w[x] != lmn { x += 1 }; mnX = x; mnY = y }
            if lmx > mx { mx = lmx; var x = 0; while w[x] != lmx { x += 1 }; mxX = x; mxY = y }
        }
    }
    out[0] = found ? mn : 0; out[1] = found ? mx : 0
    out[2] = Double(mnX); out[3] = Double(mnY); out[4] = Double(mxX); out[5] = Double(mxY)
    out[6] = found ? 1 : 0
    return 0
}

@inline(__always) private func nzRow<T: CoreNum & Comparable>(_ p: UnsafePointer<T>, _ n: Int, _ zero: T) -> Int {
    var c = 0
    for i in 0..<n { c &+= p[i] != zero ? 1 : 0 }
    return c
}

/// Non-zero count of a single-channel mat. out[0] = count.
@_cdecl("sr_core_countnonzero")
public func sr_core_countnonzero(_ a: MatP?, _ out: UnsafeMutablePointer<Int64>?) -> Int32 {
    guard let a = mat(a), let out, a.cn == 1 else { return srFail(SRStatus.badArgument, "countNonZero: need a single channel") }
    if let r = coreCheck([a], name: "countNonZero") { return r }
    var total = 0
    let flat = packed(a)
    let rows = flat ? 1 : a.rows, len = flat ? a.n * a.rows : a.n
    for y in 0..<rows {
        let p = a.row(y)
        switch a.depth {
        case 0: total += src_count_nz_u8(p.assumingMemoryBound(to: UInt8.self), len)
        case 1: total += nzRow(p.assumingMemoryBound(to: Int8.self), len, 0)
        case 2: total += nzRow(p.assumingMemoryBound(to: UInt16.self), len, 0)
        case 3: total += nzRow(p.assumingMemoryBound(to: Int16.self), len, 0)
        case 4: total += nzRow(p.assumingMemoryBound(to: Int32.self), len, 0)
        case 5: total += src_count_nz_f32(p.assumingMemoryBound(to: Float.self), len)
        default: total += nzRow(p.assumingMemoryBound(to: Double.self), len, 0)
        }
    }
    out[0] = Int64(total)
    return 0
}

/// Writes (x, y) int32 pairs of non-zero pixels in row-major order; returns the number written via out[0]. cap = capacity in pairs.
@_cdecl("sr_core_findnonzero")
public func sr_core_findnonzero(_ a: MatP?, _ xy: UnsafeMutablePointer<Int32>?, _ cap: Int64, _ out: UnsafeMutablePointer<Int64>?) -> Int32 {
    guard let a = mat(a), let xy, let out, a.cn == 1 else { return srFail(SRStatus.badArgument, "findNonZero: need a single channel") }
    if let r = coreCheck([a], name: "findNonZero") { return r }
    var k = 0
    let n = a.n
    let wS = Scratch(n * 8)
    let w = wS.ptr(Double.self)
    defer { withExtendedLifetime(wS) {} }
    for y in 0..<a.rows {
        if a.depth == 0 {
            let p = a.row(y).assumingMemoryBound(to: UInt8.self)
            for x in 0..<n where p[x] != 0 { if k < Int(cap) { xy[2 * k] = Int32(x); xy[2 * k + 1] = Int32(y) }; k += 1 }
        } else {
            loadRowD(a.depth, a.row(y), n, w)
            for x in 0..<n where w[x] != 0 { if k < Int(cap) { xy[2 * k] = Int32(x); xy[2 * k + 1] = Int32(y) }; k += 1 }
        }
    }
    out[0] = Int64(k)
    return 0
}


/// u8 single-channel reductions with NEON row kernels; false when the combination is not handled here.
private func perfReduceU8(_ s: CoreMat, _ d: CoreMat, _ dim: Int32, _ rtype: Int32, _ scale: Double) -> Bool {
    let n = s.cols
    if rtype >= 2 {
        guard d.depth == 0 else { return false }
        if dim == 0 {
            memcpy(d.row(0), s.row(0), n)
            let acc = d.row(0).assumingMemoryBound(to: UInt8.self)
            for y in 1..<max(s.rows, 1) where s.rows > 1 { src_max_u8_rows(acc, s.row(y).assumingMemoryBound(to: UInt8.self), n, rtype == 2 ? 1 : 0) }
        } else {
            for y in 0..<s.rows {
                var lo: UInt8 = 0, hi: UInt8 = 0
                src_minmax_u8(s.row(y).assumingMemoryBound(to: UInt8.self), n, &lo, &hi)
                d.row(y).assumingMemoryBound(to: UInt8.self).pointee = rtype == 2 ? hi : lo
            }
        }
        return true
    }
    guard d.depth >= 4 else { return false }
    let count = dim == 0 ? n : s.rows
    let sums = UnsafeMutablePointer<UInt32>.allocate(capacity: max(count, 1))
    defer { sums.deallocate() }
    if dim == 0 {
        src_colsum_u8(s.data!.assumingMemoryBound(to: UInt8.self), s.step, Int32(s.rows), Int32(n), sums)
    } else {
        for y in 0..<s.rows { sums[y] = UInt32(truncatingIfNeeded: src_sum_u8(s.row(y).assumingMemoryBound(to: UInt8.self), n)) }
    }
    let out = dim == 0 ? d.row(0) : d.data!
    let stride = dim == 0 ? d.elemSize : d.step
    for i in 0..<count {
        let o = out + i * stride
        let v = sums[i]
        switch d.depth {
        case 5: o.assumingMemoryBound(to: Float.self).pointee = rtype == 1 ? Float(v) * Float(scale) : Float(v)
        case 6: o.assumingMemoryBound(to: Double.self).pointee = rtype == 1 ? Double(v) * scale : Double(v)
        default: o.assumingMemoryBound(to: Int32.self).pointee = rtype == 1 ? Int32.satD(Double(v) * scale) : Int32.satI(Int64(v))
        }
    }
    return true
}
