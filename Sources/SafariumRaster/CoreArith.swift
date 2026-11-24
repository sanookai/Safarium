// SafariumRaster — Phase 1: arithmetic (add/subtract/absdiff/multiply/divide/addWeighted/scaleAdd/convert/convertScaleAbs).
// Semantics follow cv::arithm_op in OpenCV 5.1: operands are brought to a working type (wtype), the operation runs
// there, and the result is saturate_cast to the destination depth (cvRound = ties-to-even). Same-depth integer and
// float fast paths bypass the row buffers.

import Foundation
import SafariumRasterC

public enum CoreArithOp: Int32 { case add = 0, sub = 1, absdiff = 2, mul = 3, div = 4 }

// MARK: - fast same-type kernels

func fastInt<T: CoreInt>(_ op: CoreArithOp, _ a: UnsafePointer<T>, _ b: UnsafePointer<T>,
                                 _ d: UnsafeMutablePointer<T>, _ n: Int, _ t: T.Type) {
    switch op {
    case .add: for i in 0..<n { d[i] = T.narrow(T.widen(a[i]) + T.widen(b[i])) }
    case .sub: for i in 0..<n { d[i] = T.narrow(T.widen(a[i]) - T.widen(b[i])) }
    case .absdiff:
        for i in 0..<n { let x = T.widen(a[i]) - T.widen(b[i]); d[i] = T.narrow(x < 0 ? 0 - x : x) }
    case .mul: for i in 0..<n { d[i] = T.satI(a[i].toI() &* b[i].toI()) }
    case .div: break
    }
}

private func fastFlt<F: FloatingPoint & CoreNum>(_ op: CoreArithOp, _ a: UnsafePointer<F>, _ b: UnsafePointer<F>,
                                                 _ d: UnsafeMutablePointer<F>, _ n: Int, _ t: F.Type) {
    switch op {
    case .add: for i in 0..<n { d[i] = a[i] + b[i] }
    case .sub: for i in 0..<n { d[i] = a[i] - b[i] }
    case .absdiff: for i in 0..<n { d[i] = (a[i] - b[i]).magnitude }
    case .mul: for i in 0..<n { d[i] = a[i] * b[i] }
    case .div: break
    }
}

/// Same depth everywhere, no mask, array-array. Returns false when not applicable.
private func arithFast(_ op: CoreArithOp, _ a: CoreMat, _ b: CoreMat, _ dst: CoreMat, _ scale: Double) -> Bool {
    guard a.depth == b.depth, a.depth == dst.depth else { return false }
    if op == .mul && a.depth == 0 && scale != 1.0 {
        let flat = packed(a) && packed(b) && packed(dst)
        for y in 0..<(flat ? 1 : a.rows) { src_mul_u8(a.row(y), b.row(y), dst.row(y), flat ? a.n * a.rows : a.n, Float(scale)) }
        return true
    }
    if op == .mul && a.depth < 5 && scale != 1.0 { return false }
    if op == .div && a.depth < 5 { return false }
    if (op == .mul || op == .div) && a.depth >= 5 {}   // float mul/div with scale handled below
    let n = a.n
    let flat = packed(a) && packed(b) && packed(dst)
    let rows = flat ? 1 : a.rows
    let len = flat ? n * a.rows : n
    for y in 0..<rows {
        let pa = a.row(y), pb = b.row(y), pd = dst.row(y)
        switch a.depth {
        case 0, 1, 2, 3:
            if op == .mul {
                switch a.depth {   // exact integer products, saturated (scale == 1)
                case 0: fastInt(op, pa.assumingMemoryBound(to: UInt8.self), pb.assumingMemoryBound(to: UInt8.self), pd.assumingMemoryBound(to: UInt8.self), len, UInt8.self)
                case 1: fastInt(op, pa.assumingMemoryBound(to: Int8.self), pb.assumingMemoryBound(to: Int8.self), pd.assumingMemoryBound(to: Int8.self), len, Int8.self)
                case 2: fastInt(op, pa.assumingMemoryBound(to: UInt16.self), pb.assumingMemoryBound(to: UInt16.self), pd.assumingMemoryBound(to: UInt16.self), len, UInt16.self)
                default: fastInt(op, pa.assumingMemoryBound(to: Int16.self), pb.assumingMemoryBound(to: Int16.self), pd.assumingMemoryBound(to: Int16.self), len, Int16.self)
                }
            } else { src_addsub(Int32(a.depth), Int32(op.rawValue), pa, pb, pd, len) }
        case 4:
            if op == .div { return false }
            fastInt(op, pa.assumingMemoryBound(to: Int32.self), pb.assumingMemoryBound(to: Int32.self), pd.assumingMemoryBound(to: Int32.self), len, Int32.self)
        case 5: src_fbin32(Int32(op.rawValue), pa.assumingMemoryBound(to: Float.self), pb.assumingMemoryBound(to: Float.self), pd.assumingMemoryBound(to: Float.self), len, Float(scale))
        default: src_fbin64(Int32(op.rawValue), pa.assumingMemoryBound(to: Double.self), pb.assumingMemoryBound(to: Double.self), pd.assumingMemoryBound(to: Double.self), len, scale)
        }
    }
    return true
}

// MARK: - generic (wtype) path

private enum Dom { case i, f, d }

/// Working type of multiply/divide on two arrays (OpenCV 5.1, measured against the reference for every depth pair and every
/// dtype: the requested output depth never changes it). f64 or s32 inputs (except s32 beside f32) and two different integer
/// depths wider than 8 bit compute in double; everything else in float32.
private func arrayPairDom(_ d1: Int32, _ d2: Int32) -> Dom {
    if d1 == 6 || d2 == 6 { return .d }
    if d1 == 4 || d2 == 4 { return (d1 == 5 || d2 == 5) ? .f : .d }
    if d1 != d2 && d1 < 5 && d2 < 5 && !(d1 <= 1 && d2 <= 1) { return .d }
    return .f
}

private func arithGeneric(_ op: CoreArithOp, _ a: CoreMat, _ b: CoreMat?, _ sc: UnsafePointer<Double>?, _ swap: Bool,
                          _ dst: CoreMat, _ mask: CoreMat?, _ scale: Double) {
    let n = a.n
    let cn = Int(a.cn)
    let d1 = a.depth
    // OpenCV 5.1: an all-integer-valued scalar beside an integer array stays integer (exact); any other double scalar
    // acts as f32 beside every depth but f64.
    var scalarInt = false
    if let sc = sc, d1 < 5 {
        scalarInt = true
        for c in 0..<4 where !(sc[c] == sc[c].rounded() && abs(sc[c]) < 9e15) { scalarInt = false }
    }
    let d2: Int32 = b?.depth ?? ((scalarInt && op != .div) ? 4 : ((d1 < 6 && op != .mul && op != .div) ? 5 : 6))   // multiply and divide keep the double scalar
    let dt = dst.depth
    let anyFloat = d1 >= 5 || d2 >= 5 || dt >= 5
    let anyF64 = d1 == 6 || d2 == 6 || dt == 6
    let muldiv = op == .mul || op == .div
    var dom: Dom
    if muldiv {
        let bothInt = d1 < 5 && d2 < 5 && dt < 5
        if bothInt && op == .mul && scale == 1.0 && (b == nil || (d1 == d2 && d1 == dt)) { dom = .i }
        else if b != nil { dom = arrayPairDom(d1, d2) }
        else if anyF64 || (dt == 4 && d1 == 4) { dom = .d }
        else { dom = .f }
    } else {
        dom = anyFloat ? (anyF64 ? .d : .f) : .i
    }
    if muldiv && dom == .i && (d1 >= 5 || d2 >= 5) { dom = .f }
    let arrIsInt = d1 < 5 && (b == nil ? scalarInt : d2 < 5)
    let zeroDiv = op == .div && arrIsInt

    let w1 = Scratch(n * 8), w2 = Scratch(n * 8)
    defer { withExtendedLifetime(w1) {}; withExtendedLifetime(w2) {} }
    var patD: Scratch? = nil
    if let sc = sc {
        let p = Scratch(n * 8)
        scalarPatternD(sc, cn, a.cols, p.ptr(Double.self))
        patD = p
    }
    let patF = Scratch(n * 4)
    if let p = patD, dom == .f {
        let src = p.ptr(Double.self), dstp = patF.ptr(Float.self)
        for i in 0..<n { dstp[i] = Float(src[i]) }
    }
    let scaleF = Float(scale)

    driveRows(dst, mask) { y, out in
        switch dom {
        case .i:
            let x = w1.ptr(Int64.self), z = w2.ptr(Int64.self)
            loadRowI(d1, a.row(y), n, x)
            if let b = b { loadRowI(d2, b.row(y), n, z) } else { for i in 0..<n { z[i] = clampI64(patD!.ptr(Double.self)[i]) } }
            let (l, r) = swap ? (z, x) : (x, z)
            switch op {
            case .add: for i in 0..<n { x[i] = l[i] &+ r[i] }
            case .sub: for i in 0..<n { x[i] = l[i] &- r[i] }
            case .absdiff: for i in 0..<n { let v = l[i] &- r[i]; x[i] = v < 0 ? 0 &- v : v }
            case .mul: for i in 0..<n { x[i] = l[i] &* r[i] }
            case .div: break
            }
            storeRowI(dt, x, n, out)
        case .f:
            let x = w1.ptr(Float.self), z = w2.ptr(Float.self)
            loadRowF(d1, a.row(y), n, x)
            if let b = b { loadRowF(d2, b.row(y), n, z) } else { z.update(from: patF.ptr(Float.self), count: n) }
            let (l, r) = swap ? (z, x) : (x, z)
            switch op {
            case .add: for i in 0..<n { x[i] = l[i] + r[i] }
            case .sub: for i in 0..<n { x[i] = l[i] - r[i] }
            case .absdiff: for i in 0..<n { x[i] = (l[i] - r[i]).magnitude }
            case .mul: for i in 0..<n { x[i] = (scaleF * l[i]) * r[i] }
            case .div:
                if zeroDiv { for i in 0..<n { x[i] = r[i] == 0 ? 0 : (l[i] * scaleF) / r[i] } }
                else { for i in 0..<n { x[i] = (l[i] * scaleF) / r[i] } }
            }
            storeRowF(dt, x, n, out)
        case .d:
            let x = w1.ptr(Double.self), z = w2.ptr(Double.self)
            loadRowD(d1, a.row(y), n, x)
            if let b = b { loadRowD(d2, b.row(y), n, z) } else { z.update(from: patD!.ptr(Double.self), count: n) }
            let (l, r) = swap ? (z, x) : (x, z)
            switch op {
            case .add: for i in 0..<n { x[i] = l[i] + r[i] }
            case .sub: for i in 0..<n { x[i] = l[i] - r[i] }
            case .absdiff: for i in 0..<n { x[i] = (l[i] - r[i]).magnitude }
            case .mul: for i in 0..<n { x[i] = (scale * l[i]) * r[i] }
            case .div:
                if zeroDiv { for i in 0..<n { x[i] = r[i] == 0 ? 0 : (l[i] * scale) / r[i] } }
                else { for i in 0..<n { x[i] = (l[i] * scale) / r[i] } }
            }
            storeRowD(dt, x, n, out)
        }
    }
}

/// dst = op(a, b) or op(a, scalar) / op(scalar, a) (swap). `dst.depth` is the requested dtype.
@_cdecl("sr_core_arith")
public func sr_core_arith(_ op: Int32, _ a: MatP?, _ b: MatP?, _ scalar: UnsafePointer<Double>?, _ swap: Int32,
                          _ dst: MatP?, _ mask: MatP?, _ scale: Double) -> Int32 {
    let bm = mat(b), mm = mat(mask)
    guard let a = mat(a), let dst = mat(dst), let aop = CoreArithOp(rawValue: op) else {
        return srFail(SRStatus.badArgument, "arith: missing operand")
    }
    if let r = coreCheck([a, dst, bm, mm], name: "arith") { return r }
    let b = bm
    guard a.rows == dst.rows, a.cols == dst.cols, a.cn == dst.cn else { return srFail(SRStatus.badArgument, "arith: size/channel mismatch") }
    if let b = b {
        guard b.rows == a.rows, b.cols == a.cols, b.cn == a.cn else {
            return srFail(SRStatus.badArgument, "arith: operand size/channel mismatch")
        }
    } else if scalar == nil { return srFail(SRStatus.badArgument, "arith: no second operand") }
    if let b = b, mm == nil, arithFast(aop, a, b, dst, scale) { return 0 }
    // absdiff with an integer-valued scalar converts it to the array depth first (saturating cast).
    var sc = [Double](repeating: 0, count: 4)
    var scale = scale
    if aop == .mul, let s = scalar {   // cv2 folds the scale into the scalar operand: a * (scale * s)
        for c in 0..<4 { sc[c] = scale * s[c] }
        scale = 1.0
    } else if let s = scalar {
        var allInt = true
        for c in 0..<4 where !(s[c] == s[c].rounded() && abs(s[c]) < 9e15) { allInt = false }
        let cast = aop == .absdiff && (a.depth >= 5 || allInt)
        for c in 0..<4 { sc[c] = cast ? castScalar(s[c], a.depth) : s[c] }
    }
    let hasScalar = scalar != nil
    if hasScalar, mm == nil, a.depth <= 3, dst.depth == a.depth, aop == .add || aop == .sub || aop == .absdiff,
       arithScalarFast(aop, a, sc, swap != 0, dst) { return 0 }
    sc.withUnsafeBufferPointer { arithGeneric(aop, a, b, hasScalar ? $0.baseAddress : nil, swap != 0, dst, mm, scale) }
    return 0
}

/// saturate_cast<depth>(double) returned as double (ints: cvRound + clamp; f32: rounded to float).
func castScalar(_ v: Double, _ depth: Int32) -> Double {
    switch depth {
    case 0: return UInt8.satD(v).toD()
    case 1: return Int8.satD(v).toD()
    case 2: return UInt16.satD(v).toD()
    case 3: return Int16.satD(v).toD()
    case 4: return Int32.satD(v).toD()
    case 5: return Double(Float(v))
    default: return v
    }
}


// MARK: - addWeighted / scaleAdd

@_cdecl("sr_core_addweighted")
public func sr_core_addweighted(_ a: MatP?, _ alpha: Double, _ b: MatP?, _ beta: Double, _ gamma: Double, _ dst: MatP?) -> Int32 {
    guard let a = mat(a), let b = mat(b), let dst = mat(dst) else { return srFail(SRStatus.badArgument, "addWeighted: missing operand") }
    if let r = coreCheck([a, b, dst], name: "addWeighted") { return r }
    guard a.rows == b.rows, a.cols == b.cols, a.cn == b.cn, a.rows == dst.rows, a.cols == dst.cols, a.cn == dst.cn else {
        return srFail(SRStatus.badArgument, "addWeighted: size mismatch")
    }
    let n = a.n
    let same = a.depth == b.depth && a.depth == dst.depth
    let wt: Int32 = same ? a.depth : max(a.depth, b.depth, 5, dst.depth)
    let al = Float(alpha), be = Float(beta), ga = Float(gamma)
    if same && (a.depth == 0 || a.depth == 5) {
        let flat = packed(a) && packed(b) && packed(dst)
        for y in 0..<(flat ? 1 : dst.rows) {
            let len = flat ? n * a.rows : n
            if a.depth == 0 { src_addw_u8(a.row(y), b.row(y), dst.row(y), len, al, be, ga) }
            else { src_addw_f32(a.row(y).assumingMemoryBound(to: Float.self), b.row(y).assumingMemoryBound(to: Float.self), dst.row(y).assumingMemoryBound(to: Float.self), len, al, be, ga) }
        }
        return 0
    }
    let w1 = Scratch(n * 8), w2 = Scratch(n * 8)
    for y in 0..<dst.rows {
        if wt == 6 || wt == 4 || a.depth == 4 || b.depth == 4 {
            let x = w1.ptr(Double.self), z = w2.ptr(Double.self)
            loadRowD(a.depth, a.row(y), n, x); loadRowD(b.depth, b.row(y), n, z)
            for i in 0..<n { x[i] = gamma.addingProduct(z[i], beta).addingProduct(x[i], alpha) }   // fma(a, alpha, fma(b, beta, gamma))
            storeRowD(dst.depth, x, n, dst.row(y))
        } else {
            // f32 chain: fma(src1, alpha, fma(src2, beta, gamma)) — OpenCV's SIMD kernel for 8/16-bit and f32.
            let x = w1.ptr(Float.self), z = w2.ptr(Float.self)
            loadRowF(a.depth, a.row(y), n, x); loadRowF(b.depth, b.row(y), n, z)
            for i in 0..<n { x[i] = ga.addingProduct(z[i], be).addingProduct(x[i], al) }
            storeRowF(dst.depth, x, n, dst.row(y))
        }
    }
    return 0
}

@_cdecl("sr_core_scaleadd")
public func sr_core_scaleadd(_ a: MatP?, _ alpha: Double, _ b: MatP?, _ dst: MatP?) -> Int32 {
    guard let a = mat(a), let b = mat(b), let dst = mat(dst), a.depth == b.depth, a.depth == dst.depth, a.depth >= 5 else {
        return srFail(SRStatus.badArgument, "scaleAdd: need float arrays of one depth")
    }
    if let r = coreCheck([a, b, dst], name: "scaleAdd") { return r }
    let n = a.n
    for y in 0..<a.rows {
        if a.depth == 5 {
            let p = a.row(y).assumingMemoryBound(to: Float.self), q = b.row(y).assumingMemoryBound(to: Float.self)
            let d = dst.row(y).assumingMemoryBound(to: Float.self)
            let al = Float(alpha)
            for i in 0..<n { d[i] = q[i].addingProduct(p[i], al) }
        } else {
            let p = a.row(y).assumingMemoryBound(to: Double.self), q = b.row(y).assumingMemoryBound(to: Double.self)
            let d = dst.row(y).assumingMemoryBound(to: Double.self)
            for i in 0..<n { d[i] = q[i].addingProduct(p[i], alpha) }
        }
    }
    return 0
}

// MARK: - convertTo / convertScaleAbs

/// dst = saturate(src * alpha + beta); abs != 0 takes |.| first (convertScaleAbs).
private let convertRamp: [UInt8] = (0..<256).map { UInt8($0) }

@_cdecl("sr_core_convert")
public func sr_core_convert(_ src: MatP?, _ dst: MatP?, _ alpha: Double, _ beta: Double, _ abs: Int32) -> Int32 {
    guard let s = mat(src), let d = mat(dst), s.rows == d.rows, s.cols == d.cols, s.cn == d.cn else {
        return srFail(SRStatus.badArgument, "convert: size mismatch")
    }
    if let r = coreCheck([s, d], name: "convert") { return r }
    let n = s.n
    let plain = alpha == 1.0 && beta == 0.0 && abs == 0
    let useD = s.depth == 6 || d.depth == 6 || (s.depth == 4 && d.depth == 4)
    if s.depth == 0 && d.depth == 0 && s.rows * s.n >= 256 {
        // u8 -> u8 is a function of one byte: build the 256-entry table with the vector kernel itself (identical results), then
        // one vImage table lookup per row (faster than recomputing the float arithmetic for every pixel)
        var table = [UInt8](repeating: 0, count: 256)
        convertRamp.withUnsafeBufferPointer { src_cvt(0, 0, $0.baseAddress, &table, 256, Float(alpha), Float(beta), abs) }
        table.withUnsafeBufferPointer { perfLutU8(s, d, $0.baseAddress!) }
        return 0
    }
    if (s.depth == 0 || s.depth == 5) && (d.depth == 0 || d.depth == 5) && !(abs != 0 && d.depth == 5 && s.depth == 0 && false) {
        let flat = packed(s) && packed(d)
        for y in 0..<(flat ? 1 : s.rows) {
            src_cvt(s.depth, d.depth, s.row(y), d.row(y), flat ? n * s.rows : n, Float(alpha), Float(beta), abs)
        }
        return 0
    }
    let w = Scratch(n * 8)
    let al = Float(alpha), be = Float(beta)
    for y in 0..<s.rows {
        if useD {
            let x = w.ptr(Double.self)
            loadRowD(s.depth, s.row(y), n, x)
            if !plain { for i in 0..<n { x[i] = beta.addingProduct(x[i], alpha) } }
            if abs != 0 { for i in 0..<n { x[i] = x[i].magnitude } }
            storeRowD(d.depth, x, n, d.row(y))
        } else {
            let x = w.ptr(Float.self)
            loadRowF(s.depth, s.row(y), n, x)
            if !plain { for i in 0..<n { x[i] = be.addingProduct(x[i], al) } }
            if abs != 0 { for i in 0..<n { x[i] = x[i].magnitude } }
            storeRowF(d.depth, x, n, d.row(y))
        }
    }
    return 0
}


/// Integer array +/-/absdiff an integer-valued scalar that fits the element type: one saturating typed pass.
private func arithScalarFast(_ op: CoreArithOp, _ a: CoreMat, _ sc: [Double], _ swap: Bool, _ dst: CoreMat) -> Bool {
    let lo: Double, hi: Double
    switch a.depth { case 0: (lo, hi) = (0, 255); case 1: (lo, hi) = (-128, 127); case 2: (lo, hi) = (0, 65535); default: (lo, hi) = (-32768, 32767) }
    for c in 0..<4 where !(sc[c] == sc[c].rounded() && sc[c] >= lo && sc[c] <= hi) { return false }
    let n = a.n, cn = Int(a.cn)
    if cn <= 4 {
        // 48-byte pattern stream (period cn divides it for 1- and 2-byte elements): constants stay in registers
        var pat = [UInt8](repeating: 0, count: 48)
        pat.withUnsafeMutableBytes { raw in
            switch a.depth {
            case 0: for i in 0..<48 { raw.storeBytes(of: UInt8.satD(sc[i % cn]), toByteOffset: i, as: UInt8.self) }
            case 1: for i in 0..<48 { raw.storeBytes(of: Int8.satD(sc[i % cn]), toByteOffset: i, as: Int8.self) }
            case 2: for i in 0..<24 { raw.storeBytes(of: UInt16.satD(sc[i % cn]), toByteOffset: i * 2, as: UInt16.self) }
            default: for i in 0..<24 { raw.storeBytes(of: Int16.satD(sc[i % cn]), toByteOffset: i * 2, as: Int16.self) }
            }
        }
        pat.withUnsafeBufferPointer { pp in
            for y in 0..<a.rows { src_addsub_pat(a.depth, Int32(op.rawValue), swap ? 1 : 0, a.row(y), pp.baseAddress, dst.row(y), n) }
        }
        return true
    }
    func run<T: CoreInt>(_ t: T.Type) {
        let pat = Scratch(n * MemoryLayout<T>.stride)
        let pp = pat.ptr(T.self)
        for x in 0..<a.cols { for c in 0..<cn { pp[x * cn + c] = T.satD(sc[c]) } }
        for y in 0..<a.rows {
            let ap = a.row(y), dp = dst.row(y)
            if swap { src_addsub(a.depth, Int32(op.rawValue), UnsafeRawPointer(pp), ap, dp, n) } else { src_addsub(a.depth, Int32(op.rawValue), ap, UnsafeRawPointer(pp), dp, n) }
        }
        withExtendedLifetime(pat) {}
    }
    switch a.depth { case 0: run(UInt8.self); case 1: run(Int8.self); case 2: run(UInt16.self); default: run(Int16.self) }
    return true
}
