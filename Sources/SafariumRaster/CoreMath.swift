// SafariumRaster — Phase 1: element-wise math (sqrt, exp, log, pow, magnitude, phase/atan2, cartToPolar, polarToCart).
// The angle kernel is OpenCV's polynomial atan2 (accurate to ~0.01 degree, not libm) because cv2 returns exactly
// those values: coefficients are OpenCV's (Apache-2.0) fastAtan2 constants, rewritten in Swift.

import Foundation
import Accelerate
import SafariumRasterC

private let rad2degF: Float = Float(180.0 / Double.pi)
private let atanP1: Float = 0.9997878412794807 * rad2degF
private let atanP3: Float = -0.3258083974640975 * rad2degF
private let atanP5: Float = 0.1555786518463281 * rad2degF
private let atanP7: Float = -0.04432655554792128 * rad2degF
private let atanEps: Float = Float(Double.ulpOfOne)

/// OpenCV atan_f32 (scalar, no fused multiply-add) — also used by cv::fastAtan2 and the 64-bit phase path.
@inline(__always) func coreAtan2Deg(_ y: Float, _ x: Float) -> Float {
    let ax = x.magnitude, ay = y.magnitude
    var a: Float
    if ax >= ay {
        let c = ay / (ax + atanEps), c2 = c * c
        a = (((atanP7 * c2 + atanP5) * c2 + atanP3) * c2 + atanP1) * c
    } else {
        let c = ax / (ay + atanEps), c2 = c * c
        a = 90 - (((atanP7 * c2 + atanP5) * c2 + atanP3) * c2 + atanP1) * c
    }
    if x < 0 { a = 180 - a }
    if y < 0 { a = 360 - a }
    return a
}

/// Same polynomial with fused multiply-adds (OpenCV's float32 SIMD kernel).
@inline(__always) private func atanDegFMA(_ y: Float, _ x: Float) -> Float {
    let ax = x.magnitude, ay = y.magnitude
    var a: Float
    if ax >= ay {
        let c = ay / (ax + atanEps), c2 = c * c
        let t = atanP5.addingProduct(atanP7, c2)
        let u = atanP3.addingProduct(t, c2)
        a = atanP1.addingProduct(u, c2) * c
    } else {
        let c = ax / (ay + atanEps), c2 = c * c
        let t = atanP5.addingProduct(atanP7, c2)
        let u = atanP3.addingProduct(t, c2)
        a = 90 - atanP1.addingProduct(u, c2) * c
    }
    if x < 0 { a = 180 - a }
    if y < 0 { a = 360 - a }
    return a
}

@_cdecl("sr_core_fastatan2")
public func sr_core_fastatan2(_ y: Double, _ x: Double) -> Double { Double(coreAtan2Deg(Float(y), Float(x))) }

private func floatDepthOK(_ m: CoreMat) -> Bool { m.depth == 5 || m.depth == 6 }

/// op: 0 sqrt, 1 exp, 2 log (float depths only). Out of place or in place.
@_cdecl("sr_core_math")
public func sr_core_math(_ op: Int32, _ src: MatP?, _ dst: MatP?) -> Int32 {
    guard let s = mat(src), let d = mat(dst), floatDepthOK(s), s.depth == d.depth, s.rows == d.rows, s.cols == d.cols, s.cn == d.cn else {
        return srFail(SRStatus.badArgument, "math: need same-size float arrays of one depth")
    }
    if let r = coreCheck([s, d], name: "math") { return r }
    let n = s.n
    let flat = packed(s) && packed(d)
    let rows = flat ? 1 : s.rows
    let len = flat ? n * s.rows : n
    for y in 0..<rows {
        if s.depth == 5 {
            let p = s.row(y).assumingMemoryBound(to: Float.self), q = d.row(y).assumingMemoryBound(to: Float.self)
            var cnt = Int32(len)
            switch op {
            case 0: src_sqrt32(p, q, len)
            case 1: src_exp32(p, q, len)
            default: vvlogf(q, p, &cnt)
            }
        } else {
            let p = s.row(y).assumingMemoryBound(to: Double.self), q = d.row(y).assumingMemoryBound(to: Double.self)
            var cnt = Int32(len)
            switch op {
            case 0: for i in 0..<len { q[i] = p[i].squareRoot() }
            case 1: vvexp(q, p, &cnt)
            default: vvlog(q, p, &cnt)
            }
        }
    }
    return 0
}

// MARK: - pow

@inline(__always) private func powInt(_ x: Double, _ n: Int) -> Double {
    var r = 1.0, b = x, e = n < 0 ? -n : n
    while e > 0 { if e & 1 == 1 { r *= b }; b *= b; e >>= 1 }
    return n < 0 ? 1.0 / r : r
}

/// dst = src ^ power. Float arrays stay float (integer powers by repeated multiplication, 0.5 via sqrt); integer arrays
/// compute in double and saturate (cv::pow).
@_cdecl("sr_core_pow")
public func sr_core_pow(_ src: MatP?, _ dst: MatP?, _ power: Double) -> Int32 {
    guard let s = mat(src), let d = mat(dst), s.depth == d.depth, s.rows == d.rows, s.cols == d.cols, s.cn == d.cn else {
        return srFail(SRStatus.badArgument, "pow: mismatch")
    }
    if let r = coreCheck([s, d], name: "pow") { return r }
    let n = s.n
    let isInt = power == power.rounded() && abs(power) < 1024
    let ip = isInt ? Int(power) : 0
    let w = Scratch(n * 8)
    defer { withExtendedLifetime(w) {} }
    for y in 0..<s.rows {
        switch s.depth {
        case 5:
            let p = s.row(y).assumingMemoryBound(to: Float.self), q = d.row(y).assumingMemoryBound(to: Float.self)
            if isInt && ip == 2 { for i in 0..<n { q[i] = p[i] * p[i] } }
            else if isInt && ip == 1 { for i in 0..<n { q[i] = p[i] } }
            else if isInt && ip == 0 { for i in 0..<n { q[i] = 1 } }
            else if power == 0.5 { for i in 0..<n { q[i] = p[i].squareRoot() } }
            else if isInt { let pf = Float(power); _ = pf; for i in 0..<n { q[i] = Float(powInt(Double(p[i]), ip)) } }
            else {
                withTemp(n, Float.self) { e in
                    for i in 0..<n { e[i] = Float(power) }
                    var cnt = Int32(n)
                    vvpowf(q, e, p, &cnt)
                }
            }
        case 6:
            let p = s.row(y).assumingMemoryBound(to: Double.self), q = d.row(y).assumingMemoryBound(to: Double.self)
            if isInt { for i in 0..<n { q[i] = powInt(p[i], ip) } }
            else if power == 0.5 { for i in 0..<n { q[i] = p[i].squareRoot() } }
            else { for i in 0..<n { q[i] = Foundation.pow(p[i], power) } }
        default:
            let x = w.ptr(Double.self)
            loadRowD(s.depth, s.row(y), n, x)
            if isInt {
                // negative integer powers of integers round half away from zero (cv2: 2^-1 -> 1, (-2)^-1 -> -1)
                if ip < 0 { for i in 0..<n { x[i] = powInt(x[i], ip).rounded(.toNearestOrAwayFromZero) } }
                else if ip >= 3 {
                    // cv2 multiplies in C int (wraps) for powers >= 3 and only then saturates to the element type
                    let unsigned = d.depth == 0 || d.depth == 2
                    for i in 0..<n {
                        if unsigned {
                            var r: UInt32 = 1, b = UInt32(truncatingIfNeeded: Int64(x[i])), e = ip
                            while e > 0 { if e & 1 == 1 { r = r &* b }; b = b &* b; e >>= 1 }
                            x[i] = Double(r)
                        } else {
                            var r: Int32 = 1, b = Int32(truncatingIfNeeded: Int64(x[i])), e = ip
                            while e > 0 { if e & 1 == 1 { r = r &* b }; b = b &* b; e >>= 1 }
                            x[i] = Double(r)
                        }
                    }
                }
                else { for i in 0..<n { x[i] = powInt(x[i], ip) } }
            }
            else { for i in 0..<n { x[i] = Foundation.pow(x[i], power) } }
            storeRowD(d.depth, x, n, d.row(y))
        }
    }
    return 0
}

// MARK: - magnitude / phase / polar

@_cdecl("sr_core_magnitude")
public func sr_core_magnitude(_ x: MatP?, _ y: MatP?, _ dst: MatP?) -> Int32 {
    guard let a = mat(x), let b = mat(y), let d = mat(dst), floatDepthOK(a), a.depth == b.depth, a.depth == d.depth,
          a.rows == b.rows, a.cols == b.cols, a.cn == b.cn, a.rows == d.rows, a.cols == d.cols, a.cn == d.cn else {
        return srFail(SRStatus.badArgument, "magnitude: need two same-size arrays of one float depth")
    }
    if let r = coreCheck([a, b, d], name: "magnitude") { return r }
    let n = a.n
    for r in 0..<a.rows {
        if a.depth == 5 {
            let p = a.row(r).assumingMemoryBound(to: Float.self), q = b.row(r).assumingMemoryBound(to: Float.self)
            let o = d.row(r).assumingMemoryBound(to: Float.self)
            for i in 0..<n { o[i] = (p[i] * p[i] + q[i] * q[i]).squareRoot() }
        } else {
            let p = a.row(r).assumingMemoryBound(to: Double.self), q = b.row(r).assumingMemoryBound(to: Double.self)
            let o = d.row(r).assumingMemoryBound(to: Double.self)
            for i in 0..<n { o[i] = (p[i] * p[i] + q[i] * q[i]).squareRoot() }
        }
    }
    return 0
}

/// angle = atan2(y, x) in [0, 360) degrees (or radians). x, y, dst: same-size arrays of one float depth.
@_cdecl("sr_core_phase")
public func sr_core_phase(_ x: MatP?, _ y: MatP?, _ dst: MatP?, _ degrees: Int32) -> Int32 {
    guard let a = mat(x), let b = mat(y), let d = mat(dst), floatDepthOK(a), a.depth == b.depth, a.depth == d.depth,
          a.rows == b.rows, a.cols == b.cols, a.cn == b.cn, a.rows == d.rows, a.cols == d.cols, a.cn == d.cn else {
        return srFail(SRStatus.badArgument, "phase: need two same-size arrays of one float depth")
    }
    if let r = coreCheck([a, b, d], name: "phase") { return r }
    let n = a.n
    let k = Float(Double.pi / 180.0)
    for r in 0..<a.rows {
        if a.depth == 5 {
            let p = a.row(r).assumingMemoryBound(to: Float.self), q = b.row(r).assumingMemoryBound(to: Float.self)
            let o = d.row(r).assumingMemoryBound(to: Float.self)
            src_phase32(p, q, o, n, degrees != 0 ? 1.0 : k)
        } else {
            let p = a.row(r).assumingMemoryBound(to: Double.self), q = b.row(r).assumingMemoryBound(to: Double.self)
            let o = d.row(r).assumingMemoryBound(to: Double.self)
            if degrees != 0 { for i in 0..<n { o[i] = Double(coreAtan2Deg(Float(q[i]), Float(p[i]))) } }
            else { for i in 0..<n { o[i] = Double(coreAtan2Deg(Float(q[i]), Float(p[i]))) * Double(k) } }
        }
    }
    return 0
}

/// x = mag * cos(angle), y = mag * sin(angle). mag may be NULL (unit length).
@_cdecl("sr_core_polar2cart")
public func sr_core_polar2cart(_ mag: MatP?, _ angle: MatP?, _ x: MatP?, _ y: MatP?, _ degrees: Int32) -> Int32 {
    guard let an = mat(angle), let xo = mat(x), let yo = mat(y), floatDepthOK(an), an.depth == xo.depth, an.depth == yo.depth,
          an.rows == xo.rows, an.cols == xo.cols, an.cn == xo.cn, an.rows == yo.rows, an.cols == yo.cols, an.cn == yo.cn else {
        return srFail(SRStatus.badArgument, "polarToCart: bad operands")
    }
    let mg = mat(mag)
    if let r = coreCheck([an, xo, yo, mg], name: "polarToCart") { return r }
    if let m = mg, !(m.depth == an.depth && m.rows == an.rows && m.cols == an.cols && m.cn == an.cn) {
        return srFail(SRStatus.badArgument, "polarToCart: magnitude mismatch")
    }
    let n = an.n
    let w = Scratch(n * 8)
    defer { withExtendedLifetime(w) {} }
    for r in 0..<an.rows {
        if an.depth == 5 {
            let a = an.row(r).assumingMemoryBound(to: Float.self)
            let xs = xo.row(r).assumingMemoryBound(to: Float.self), ys = yo.row(r).assumingMemoryBound(to: Float.self)
            let t = w.ptr(Float.self)
            let k = Float(Double.pi / 180.0)
            for i in 0..<n { t[i] = degrees != 0 ? a[i] * k : a[i] }
            var cnt = Int32(n)
            vvsincosf(ys, xs, t, &cnt)
            if let m = mg {
                let mp = m.row(r).assumingMemoryBound(to: Float.self)
                for i in 0..<n { xs[i] *= mp[i]; ys[i] *= mp[i] }
            }
        } else {
            // cv2 evaluates the double overload in single precision (results match float32 sin/cos widened to double).
            let a = an.row(r).assumingMemoryBound(to: Double.self)
            let xs = xo.row(r).assumingMemoryBound(to: Double.self), ys = yo.row(r).assumingMemoryBound(to: Double.self)
            let k = Float(Double.pi / 180.0)
            withTemp(n * 3, Float.self) { t in
                let ang = t, sn = t + n, cs = t + 2 * n
                for i in 0..<n { ang[i] = degrees != 0 ? Float(a[i]) * k : Float(a[i]) }
                var cnt = Int32(n)
                vvsincosf(sn, cs, ang, &cnt)
                if let m = mg {
                    let mp = m.row(r).assumingMemoryBound(to: Double.self)
                    for i in 0..<n { xs[i] = Double(Float(mp[i]) * cs[i]); ys[i] = Double(Float(mp[i]) * sn[i]) }
                } else {
                    for i in 0..<n { xs[i] = Double(cs[i]); ys[i] = Double(sn[i]) }
                }
            }
        }
    }
    return 0
}
