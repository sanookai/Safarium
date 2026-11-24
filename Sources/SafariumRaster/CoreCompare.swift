// SafariumRaster — Phase 1: bitwise ops, compare, inRange, min/max (cv::bitwise_*, cv::compare, cv::inRange, cv::min/max).

import Foundation
import SafariumRasterC

// MARK: - bitwise (depth-agnostic: operates on the raw bytes of each pixel)

/// op: 0 and, 1 or, 2 xor, 3 not. `pattern` = one pixel's bytes (scalar operand, already converted to the array type).
@_cdecl("sr_core_bitwise")
public func sr_core_bitwise(_ op: Int32, _ a: MatP?, _ b: MatP?, _ pattern: UnsafeRawPointer?, _ dst: MatP?, _ mask: MatP?) -> Int32 {
    let bm = mat(b), mm = mat(mask)
    guard let a = mat(a), let dst = mat(dst) else { return srFail(SRStatus.badArgument, "bitwise: missing operand") }
    if let r = coreCheck([a, dst, bm, mm], name: "bitwise") { return r }
    guard a.rows == dst.rows, a.cols == dst.cols, a.pixelBytes == dst.pixelBytes else {
        return srFail(SRStatus.badArgument, "bitwise: size mismatch")
    }
    if let b = bm, !(b.rows == a.rows && b.cols == a.cols && b.pixelBytes == a.pixelBytes) {
        return srFail(SRStatus.badArgument, "bitwise: operand size mismatch")
    }
    let rowBytes = a.cols * a.pixelBytes
    var pat: Scratch? = nil
    if op != 3, bm == nil {
        guard let pattern = pattern else { return srFail(SRStatus.badArgument, "bitwise: no second operand") }
        let p = Scratch(rowBytes)
        let pb = a.pixelBytes
        for x in 0..<a.cols { memcpy(p.p + x * pb, pattern, pb) }
        pat = p
    }
    let flat = mm == nil && packed(a) && packed(dst) && (bm.map { packed($0) } ?? true) && pat == nil
    if flat {
        let total = rowBytes * a.rows
        let x = a.data!.assumingMemoryBound(to: UInt8.self), d = dst.data!.assumingMemoryBound(to: UInt8.self)
        let y = bm?.data?.assumingMemoryBound(to: UInt8.self)
        bitRow(op, x, y, d, total)
        return 0
    }
    driveRows(dst, mm) { yy, out in
        let x = a.row(yy).assumingMemoryBound(to: UInt8.self)
        let y: UnsafePointer<UInt8>? = bm != nil ? UnsafePointer(bm!.row(yy).assumingMemoryBound(to: UInt8.self))
                                                  : pat.map { UnsafePointer($0.p.assumingMemoryBound(to: UInt8.self)) }
        bitRow(op, x, y, out.assumingMemoryBound(to: UInt8.self), rowBytes)
    }
    return 0
}

@inline(__always) private func bitRow(_ op: Int32, _ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>?, _ d: UnsafeMutablePointer<UInt8>, _ n: Int) {
    // 64-bit lanes first (alignment of numpy rows is at least element size, so use unaligned loads)
    let words = n / 8
    let ra = UnsafeRawPointer(a), rd = UnsafeMutableRawPointer(d)
    switch op {
    case 0:
        let rb = UnsafeRawPointer(b!)
        for i in 0..<words { rd.storeBytes(of: ra.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self) & rb.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self), toByteOffset: i * 8, as: UInt64.self) }
        for i in (words * 8)..<n { d[i] = a[i] & b![i] }
    case 1:
        let rb = UnsafeRawPointer(b!)
        for i in 0..<words { rd.storeBytes(of: ra.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self) | rb.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self), toByteOffset: i * 8, as: UInt64.self) }
        for i in (words * 8)..<n { d[i] = a[i] | b![i] }
    case 2:
        let rb = UnsafeRawPointer(b!)
        for i in 0..<words { rd.storeBytes(of: ra.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self) ^ rb.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self), toByteOffset: i * 8, as: UInt64.self) }
        for i in (words * 8)..<n { d[i] = a[i] ^ b![i] }
    default:
        for i in 0..<words { rd.storeBytes(of: ~ra.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self), toByteOffset: i * 8, as: UInt64.self) }
        for i in (words * 8)..<n { d[i] = ~a[i] }
    }
}

// MARK: - compare

/// cmpop: 0 EQ, 1 GT, 2 GE, 3 LT, 4 LE, 5 NE. dst: u8, same size and channels. Scalar operand is always the right side.
@_cdecl("sr_core_compare")
public func sr_core_compare(_ cmpop: Int32, _ a: MatP?, _ b: MatP?, _ scalar: UnsafePointer<Double>?, _ dst: MatP?) -> Int32 {
    guard let a = mat(a), let dst = mat(dst), dst.depth == 0, a.rows == dst.rows, a.cols == dst.cols, a.cn == dst.cn else {
        return srFail(SRStatus.badArgument, "compare: bad operands")
    }
    let bm = mat(b)
    if let r = coreCheck([a, dst, bm], name: "compare") { return r }
    if let b = bm, !(b.depth == a.depth && b.rows == a.rows && b.cols == a.cols && b.cn == a.cn) {
        return srFail(SRStatus.badArgument, "compare: operand mismatch")
    }
    if bm == nil && scalar == nil { return srFail(SRStatus.badArgument, "compare: no second operand") }
    let n = a.n, cn = Int(a.cn)

    @inline(__always) func run<T: CoreNum & Comparable>(_ t: T.Type, _ scalarConv: (Double) -> T) {
        let flat = packed(a) && packed(dst) && bm.map({ packed($0) }) == true
        let rows = flat ? 1 : a.rows
        let len = flat ? n * a.rows : n
        var pat: Scratch? = nil
        if bm == nil, let sc = scalar {
            let p = Scratch(n * MemoryLayout<T>.stride)
            let q = p.ptr(T.self)
            for x in 0..<a.cols { for c in 0..<cn { q[x * cn + c] = scalarConv(scalarChannel(sc, c)) } }
            pat = p
        }
        for y in 0..<rows {
            let x = a.row(y).assumingMemoryBound(to: T.self)
            let d = dst.row(y).assumingMemoryBound(to: UInt8.self)
            let r: UnsafePointer<T> = bm != nil ? UnsafePointer(bm!.row(y).assumingMemoryBound(to: T.self)) : UnsafePointer(pat!.ptr(T.self))
            switch cmpop {
            case 0: for i in 0..<len { d[i] = x[i] == r[i] ? 255 : 0 }
            case 1: for i in 0..<len { d[i] = x[i] > r[i] ? 255 : 0 }
            case 2: for i in 0..<len { d[i] = x[i] >= r[i] ? 255 : 0 }
            case 3: for i in 0..<len { d[i] = x[i] < r[i] ? 255 : 0 }
            case 4: for i in 0..<len { d[i] = x[i] <= r[i] ? 255 : 0 }
            default: for i in 0..<len { d[i] = x[i] != r[i] ? 255 : 0 }
            }
        }
    }

    // f32: SIMD kernel with the scalar (cn == 1) or the second array; u8 array-array.
    if a.depth == 5, bm != nil || (cn == 1 && scalar != nil) {
        let flat = packed(a) && packed(dst) && (bm.map { packed($0) } ?? true)
        let rows = flat ? 1 : a.rows, len = flat ? n * a.rows : n
        let sv = scalar.map { Float($0[0]) } ?? 0
        for y in 0..<rows {
            src_cmp_f32(cmpop, UnsafePointer(a.row(y).assumingMemoryBound(to: Float.self)),
                        bm.map { UnsafePointer($0.row(y).assumingMemoryBound(to: Float.self)) }, sv,
                        dst.row(y).assumingMemoryBound(to: UInt8.self), len)
        }
        return 0
    }
    if a.depth == 0, let b = bm {
        let flat = packed(a) && packed(dst) && packed(b)
        let rows = flat ? 1 : a.rows, len = flat ? n * a.rows : n
        for y in 0..<rows {
            src_cmp_u8(cmpop, UnsafePointer(a.row(y).assumingMemoryBound(to: UInt8.self)), UnsafePointer(b.row(y).assumingMemoryBound(to: UInt8.self)),
                       dst.row(y).assumingMemoryBound(to: UInt8.self), len)
        }
        return 0
    }
    // Integer arrays against a (possibly fractional / out-of-range) scalar: compare exactly in double.
    if bm == nil, a.depth < 5 {
        let sc = scalar!
        let w = Scratch(n * 8)
        let pat = w.ptr(Double.self)
        defer { withExtendedLifetime(w) {} }
        for x in 0..<a.cols { for c in 0..<cn { pat[x * cn + c] = scalarChannel(sc, c) } }
        let wl = Scratch(n * 8)
        defer { withExtendedLifetime(wl) {} }
        for y in 0..<a.rows {
            let xv = wl.ptr(Double.self)
            loadRowD(a.depth, a.row(y), n, xv)
            let d = dst.row(y).assumingMemoryBound(to: UInt8.self)
            switch cmpop {
            case 0: for i in 0..<n { d[i] = xv[i] == pat[i] ? 255 : 0 }
            case 1: for i in 0..<n { d[i] = xv[i] > pat[i] ? 255 : 0 }
            case 2: for i in 0..<n { d[i] = xv[i] >= pat[i] ? 255 : 0 }
            case 3: for i in 0..<n { d[i] = xv[i] < pat[i] ? 255 : 0 }
            case 4: for i in 0..<n { d[i] = xv[i] <= pat[i] ? 255 : 0 }
            default: for i in 0..<n { d[i] = xv[i] != pat[i] ? 255 : 0 }
            }
        }
        return 0
    }
    switch a.depth {
    case 0: run(UInt8.self) { UInt8.satD($0) }
    case 1: run(Int8.self) { Int8.satD($0) }
    case 2: run(UInt16.self) { UInt16.satD($0) }
    case 3: run(Int16.self) { Int16.satD($0) }
    case 4: run(Int32.self) { Int32.satD($0) }
    case 5: run(Float.self) { Float($0) }
    default: run(Double.self) { $0 }
    }
    return 0
}

// MARK: - inRange

/// dst (u8, 1 channel) = 255 where every channel of src lies in [lo, hi]. Bounds: arrays (same type as src) or scalars.
@_cdecl("sr_core_inrange")
public func sr_core_inrange(_ src: MatP?, _ lo: MatP?, _ hi: MatP?, _ loS: UnsafePointer<Double>?, _ hiS: UnsafePointer<Double>?, _ dst: MatP?) -> Int32 {
    guard let a = mat(src), let dst = mat(dst), dst.depth == 0, dst.cn == 1, a.rows == dst.rows, a.cols == dst.cols else {
        return srFail(SRStatus.badArgument, "inRange: bad operands")
    }
    let lm = mat(lo), hm = mat(hi)
    if let r = coreCheck([a, dst, lm, hm], name: "inRange") { return r }
    if lm != nil || hm != nil {
        guard let l = lm, let h = hm, l.depth == a.depth, h.depth == a.depth, l.rows == a.rows, l.cols == a.cols, l.cn == a.cn,
              h.rows == a.rows, h.cols == a.cols, h.cn == a.cn else { return srFail(SRStatus.badArgument, "inRange: bound mismatch") }
    } else if loS == nil || hiS == nil { return srFail(SRStatus.badArgument, "inRange: no bounds") }
    let cn = Int(a.cn), n = a.n

    if a.depth == 0 && lm == nil, let loS, let hiS, cn <= 4 {
        // u8 with scalar bounds: (x - lo) <= (hi - lo) in unsigned arithmetic is the range test; empty ranges never match
        var lo = [UInt8](repeating: 0, count: 4), span = [UInt8](repeating: 0, count: 4), empty = [Bool](repeating: false, count: 4)
        for c in 0..<cn {
            let l = UInt8.satD(scalarChannel(loS, c)), h = UInt8.satD(scalarChannel(hiS, c))
            lo[c] = l; span[c] = h >= l ? h - l : 0; empty[c] = h < l
        }
        if !empty.contains(true) {
            let l0 = lo[0], l1 = lo[1], l2 = lo[2], l3 = lo[3], s0 = span[0], s1 = span[1], s2 = span[2], s3 = span[3]
            for y in 0..<a.rows {
                let x = a.row(y).assumingMemoryBound(to: UInt8.self)
                let d = dst.row(y).assumingMemoryBound(to: UInt8.self)
                switch cn {
                case 1: for i in 0..<a.cols { d[i] = (x[i] &- l0) <= s0 ? 255 : 0 }
                case 3: for i in 0..<a.cols {
                    let k = 3 * i
                    let m0: UInt8 = (x[k] &- l0) <= s0 ? 255 : 0, m1: UInt8 = (x[k + 1] &- l1) <= s1 ? 255 : 0, m2: UInt8 = (x[k + 2] &- l2) <= s2 ? 255 : 0
                    d[i] = m0 & m1 & m2
                }
                case 4: for i in 0..<a.cols {
                    let k = 4 * i
                    let m0: UInt8 = (x[k] &- l0) <= s0 ? 255 : 0, m1: UInt8 = (x[k + 1] &- l1) <= s1 ? 255 : 0, m2: UInt8 = (x[k + 2] &- l2) <= s2 ? 255 : 0, m3: UInt8 = (x[k + 3] &- l3) <= s3 ? 255 : 0
                    d[i] = m0 & m1 & m2 & m3
                }
                default: for i in 0..<a.cols {
                    var ok = true
                    for c in 0..<cn { if !((x[i * cn + c] &- lo[c]) <= span[c]) { ok = false } }
                    d[i] = ok ? 255 : 0
                }
                }
            }
            return 0
        }
    }

    @inline(__always) func run<T: CoreNum & Comparable>(_ t: T.Type, _ conv: (Double) -> T) {
        var lp: Scratch? = nil, hp: Scratch? = nil
        if lm == nil {
            let l = Scratch(n * MemoryLayout<T>.stride), h = Scratch(n * MemoryLayout<T>.stride)
            for x in 0..<a.cols { for c in 0..<cn {
                l.ptr(T.self)[x * cn + c] = conv(scalarChannel(loS!, c)); h.ptr(T.self)[x * cn + c] = conv(scalarChannel(hiS!, c))
            } }
            lp = l; hp = h
        }
        for y in 0..<a.rows {
            let x = a.row(y).assumingMemoryBound(to: T.self)
            let l: UnsafePointer<T> = lm != nil ? UnsafePointer(lm!.row(y).assumingMemoryBound(to: T.self)) : UnsafePointer(lp!.ptr(T.self))
            let h: UnsafePointer<T> = hm != nil ? UnsafePointer(hm!.row(y).assumingMemoryBound(to: T.self)) : UnsafePointer(hp!.ptr(T.self))
            let d = dst.row(y).assumingMemoryBound(to: UInt8.self)
            if cn == 1 {
                for i in 0..<a.cols { d[i] = (x[i] >= l[i] && x[i] <= h[i]) ? 255 : 0 }
            } else {
                for i in 0..<a.cols {
                    var ok = true
                    for c in 0..<cn { let k = i * cn + c; if !(x[k] >= l[k] && x[k] <= h[k]) { ok = false } }
                    d[i] = ok ? 255 : 0
                }
            }
        }
    }
    switch a.depth {
    case 0: run(UInt8.self) { UInt8.satD($0) }
    case 1: run(Int8.self) { Int8.satD($0) }
    case 2: run(UInt16.self) { UInt16.satD($0) }
    case 3: run(Int16.self) { Int16.satD($0) }
    case 4: run(Int32.self) { Int32.satD($0) }
    case 5: run(Float.self) { Float($0) }
    default: run(Double.self) { $0 }
    }
    return 0
}

// MARK: - min / max

@_cdecl("sr_core_minmax")
public func sr_core_minmax(_ isMax: Int32, _ a: MatP?, _ b: MatP?, _ scalar: UnsafePointer<Double>?, _ dst: MatP?) -> Int32 {
    guard let a = mat(a), let dst = mat(dst), dst.depth == a.depth, a.rows == dst.rows, a.cols == dst.cols, a.cn == dst.cn else {
        return srFail(SRStatus.badArgument, "min/max: bad operands")
    }
    let bm = mat(b)
    if let r = coreCheck([a, dst, bm], name: "min/max") { return r }
    if let b = bm, !(b.depth == a.depth && b.rows == a.rows && b.cols == a.cols && b.cn == a.cn) {
        return srFail(SRStatus.badArgument, "min/max: operand mismatch")
    }
    if bm == nil && scalar == nil { return srFail(SRStatus.badArgument, "min/max: no second operand") }
    let n = a.n, cn = Int(a.cn)
    @inline(__always) func run<T: CoreNum & Comparable>(_ t: T.Type, _ conv: (Double) -> T) {
        let flat = packed(a) && packed(dst) && (bm.map { packed($0) } ?? true) && scalar == nil
        let rows = flat ? 1 : a.rows
        let len = flat ? n * a.rows : n
        var pat: Scratch? = nil
        if bm == nil, let sc = scalar {
            let p = Scratch(n * MemoryLayout<T>.stride)
            for x in 0..<a.cols { for c in 0..<cn { p.ptr(T.self)[x * cn + c] = conv(scalarChannel(sc, c)) } }
            pat = p
        }
        for y in 0..<rows {
            let x = a.row(y).assumingMemoryBound(to: T.self)
            let d = dst.row(y).assumingMemoryBound(to: T.self)
            let r: UnsafePointer<T> = bm != nil ? UnsafePointer(bm!.row(y).assumingMemoryBound(to: T.self)) : UnsafePointer(pat!.ptr(T.self))
            if isMax != 0 { for i in 0..<len { d[i] = r[i] > x[i] ? r[i] : x[i] } }
            else { for i in 0..<len { d[i] = r[i] < x[i] ? r[i] : x[i] } }
        }
    }
    switch a.depth {
    case 0: run(UInt8.self) { UInt8.satD($0) }
    case 1: run(Int8.self) { Int8.satD($0) }
    case 2: run(UInt16.self) { UInt16.satD($0) }
    case 3: run(Int16.self) { Int16.satD($0) }
    case 4: run(Int32.self) { Int32.satD($0) }
    case 5: run(Float.self) { Float($0) }
    default: run(Double.self) { $0 }
    }
    return 0
}
