// SafariumRaster — cv::resize (NEAREST / LINEAR / CUBIC / AREA), u8 + f32, 1-4 channels.
// Semantics follow OpenCV's resize (pixel-centre convention, area weights, cubic A = -0.75).

import Foundation
import Accelerate

/// Ragged tap table: for output index i, taps off[i]..<off[i+1] with source index idx[t] and weight w[t].
struct SRTaps {
    var off: [Int32]
    var idx: [Int32]
    var w: [Float]
    /// > 0 when every output has exactly this many taps (stored back to back; `off` unused).
    var fixedK = 0
}

private func linearTaps(_ dsize: Int, _ ssize: Int, _ scale: Double) -> SRTaps {
    var off = [Int32](), idx = [Int32](), w = [Float]()
    off.reserveCapacity(dsize + 1); idx.reserveCapacity(dsize * 2); w.reserveCapacity(dsize * 2)
    off.append(0)
    for d in 0..<dsize {
        var fx = (Double(d) + 0.5) * scale - 0.5
        var sx = srFloor(fx)
        fx -= Double(sx)
        if sx < 0 { fx = 0; sx = 0 }
        if sx >= ssize - 1 { fx = 0; sx = ssize - 1 }
        let x1 = min(sx + 1, ssize - 1)
        idx.append(Int32(sx)); w.append(Float(1 - fx))
        idx.append(Int32(x1)); w.append(Float(fx))
        off.append(Int32(idx.count))
    }
    return SRTaps(off: off, idx: idx, w: w, fixedK: 2)
}

@inline(__always) private func cubicCoeffs(_ x: Double) -> (Double, Double, Double, Double) {
    let a = -0.75
    let c0 = ((a * (x + 1) - 5 * a) * (x + 1) + 8 * a) * (x + 1) - 4 * a
    let c1 = ((a + 2) * x - (a + 3)) * x * x + 1
    let c2 = ((a + 2) * (1 - x) - (a + 3)) * (1 - x) * (1 - x) + 1
    return (c0, c1, c2, 1 - c0 - c1 - c2)
}

private func cubicTaps(_ dsize: Int, _ ssize: Int, _ scale: Double) -> SRTaps {
    var off = [Int32](), idx = [Int32](), w = [Float]()
    off.append(0)
    for d in 0..<dsize {
        var fx = (Double(d) + 0.5) * scale - 0.5
        let sx = srFloor(fx)
        fx -= Double(sx)
        let c = cubicCoeffs(fx)
        let ws = [c.0, c.1, c.2, c.3]
        for k in 0..<4 {
            idx.append(Int32(min(max(sx - 1 + k, 0), ssize - 1)))
            w.append(Float(ws[k]))
        }
        off.append(Int32(idx.count))
    }
    return SRTaps(off: off, idx: idx, w: w, fixedK: 4)
}

private func lanczosTaps(_ dsize: Int, _ ssize: Int, _ scale: Double) -> SRTaps {
    var off = [Int32](), idx = [Int32](), w = [Float]()
    off.append(0)
    for d in 0..<dsize {
        var fx = (Double(d) + 0.5) * scale - 0.5
        let sx = srFloor(fx)
        fx -= Double(sx)
        let c = SRLanczos.coeffs(fx)
        for k in 0..<8 {
            idx.append(Int32(min(max(sx - 3 + k, 0), ssize - 1)))
            w.append(c[k])
        }
        off.append(Int32(idx.count))
    }
    return SRTaps(off: off, idx: idx, w: w, fixedK: 8)
}

enum SRLanczos {
    /// cv::interpolateLanczos4
    static func coeffs(_ x: Double) -> [Float] {
        var c = [Float](repeating: 0, count: 8)
        if x < Double(Float.ulpOfOne) { c[3] = 1; return c }
        let s45 = 0.70710678118654752440084436210485
        let cs: [(Double, Double)] = [(1, 0), (-s45, -s45), (0, 1), (s45, -s45), (-1, 0), (s45, s45), (0, -1), (-s45, s45)]
        var sum: Float = 0
        let y0 = -(x + 3) * Double.pi * 0.25
        let s0 = sin(y0), c0 = cos(y0)
        for i in 0..<8 {
            let y = -(x + 3 - Double(i)) * Double.pi * 0.25
            c[i] = Float((cs[i].0 * s0 + cs[i].1 * c0) / (y * y))
            sum += c[i]
        }
        sum = 1 / sum
        for i in 0..<8 { c[i] *= sum }
        return c
    }
}

/// OpenCV INTER_AREA weights for scale >= 1 (non-integer scales get fractional edge weights).
private func areaTaps(_ dsize: Int, _ ssize: Int, _ scale: Double) -> SRTaps {
    var off = [Int32](), idx = [Int32](), w = [Float]()
    off.append(0)
    for d in 0..<dsize {
        let fsx1 = Double(d) * scale
        let fsx2 = fsx1 + scale
        let cell = min(scale, Double(ssize) - fsx1)
        var sx1 = Int(fsx1.rounded(.up))
        var sx2 = Int(fsx2.rounded(.down))
        sx2 = min(sx2, ssize - 1)
        sx1 = min(sx1, sx2)
        if Double(sx1) - fsx1 > 1e-3 {
            idx.append(Int32(sx1 - 1)); w.append(Float((Double(sx1) - fsx1) / cell))
        }
        var s = sx1
        while s < sx2 { idx.append(Int32(s)); w.append(Float(1 / cell)); s += 1 }
        if fsx2 - Double(sx2) > 1e-3 {
            idx.append(Int32(sx2)); w.append(Float(min(min(fsx2 - Double(sx2), 1), cell) / cell))
        }
        off.append(Int32(idx.count))
    }
    return SRTaps(off: off, idx: idx, w: w)
}

/// OpenCV's generic-path INTER_AREA (used when an axis is enlarged): sx = floor(d*scale), weights from the overlap fraction.
private func areaModeTaps(_ dsize: Int, _ ssize: Int, _ scale: Double) -> SRTaps {
    var off = [Int32](), idx = [Int32](), w = [Float]()
    off.append(0)
    let inv = 1.0 / scale
    for d in 0..<dsize {
        var sx = srFloor(Double(d) * scale)
        var fx = Float((Double(d + 1)) - Double(sx + 1) * inv)
        fx = fx <= 0 ? 0 : fx - fx.rounded(.down)
        if sx >= ssize { fx = 0; sx = ssize - 1 }
        idx.append(Int32(sx)); w.append(1 - fx)
        idx.append(Int32(min(sx + 1, ssize - 1))); w.append(fx)
        off.append(Int32(idx.count))
    }
    return SRTaps(off: off, idx: idx, w: w, fixedK: 2)
}

/// Horizontal resample of one source row into a float row (dw * c floats).
@inline(__always)
private func hResample<T: SRPix>(_ src: UnsafePointer<T>, _ c: Int, _ dw: Int, _ t: SRTaps, _ out: UnsafeMutablePointer<Float>) {
    t.off.withUnsafeBufferPointer { off in
    t.idx.withUnsafeBufferPointer { idx in
    t.w.withUnsafeBufferPointer { w in
        switch c {
        case 1:
            for dx in 0..<dw {
                var s: Float = 0
                for k in Int(off[dx])..<Int(off[dx + 1]) { s += w[k] * src[Int(idx[k])].asFloat }
                out[dx] = s
            }
        case 3:
            for dx in 0..<dw {
                var s0: Float = 0, s1: Float = 0, s2: Float = 0
                for k in Int(off[dx])..<Int(off[dx + 1]) {
                    let p = src + Int(idx[k]) * 3, wk = w[k]
                    s0 += wk * p[0].asFloat; s1 += wk * p[1].asFloat; s2 += wk * p[2].asFloat
                }
                out[dx * 3] = s0; out[dx * 3 + 1] = s1; out[dx * 3 + 2] = s2
            }
        case 4:
            for dx in 0..<dw {
                var s0: Float = 0, s1: Float = 0, s2: Float = 0, s3: Float = 0
                for k in Int(off[dx])..<Int(off[dx + 1]) {
                    let p = src + Int(idx[k]) * 4, wk = w[k]
                    s0 += wk * p[0].asFloat; s1 += wk * p[1].asFloat; s2 += wk * p[2].asFloat; s3 += wk * p[3].asFloat
                }
                out[dx * 4] = s0; out[dx * 4 + 1] = s1; out[dx * 4 + 2] = s2; out[dx * 4 + 3] = s3
            }
        default:
            for dx in 0..<dw {
                for ch in 0..<c {
                    var s: Float = 0
                    for k in Int(off[dx])..<Int(off[dx + 1]) { s += w[k] * src[Int(idx[k]) * c + ch].asFloat }
                    out[dx * c + ch] = s
                }
            }
        }
    }}}
}

/// Horizontal resample with exactly K taps per output (K constant-folded by the caller's literal).
@inline(__always)
private func hFixed<T: SRPix>(_ src: UnsafePointer<T>, _ c: Int, _ dw: Int, _ K: Int,
                              _ idx: UnsafePointer<Int32>, _ w: UnsafePointer<Float>, _ out: UnsafeMutablePointer<Float>) {
    switch c {
    case 1:
        for dx in 0..<dw {
            var s: Float = 0
            for k in 0..<K { s += w[dx * K + k] * src[Int(idx[dx * K + k])].asFloat }
            out[dx] = s
        }
    case 3:
        for dx in 0..<dw {
            var s0: Float = 0, s1: Float = 0, s2: Float = 0
            for k in 0..<K {
                let p = src + Int(idx[dx * K + k]) * 3, wk = w[dx * K + k]
                s0 += wk * p[0].asFloat; s1 += wk * p[1].asFloat; s2 += wk * p[2].asFloat
            }
            out[dx * 3] = s0; out[dx * 3 + 1] = s1; out[dx * 3 + 2] = s2
        }
    case 4:
        for dx in 0..<dw {
            var s = SIMD4<Float>(repeating: 0)
            for k in 0..<K {
                let p = src + Int(idx[dx * K + k]) * 4
                s += w[dx * K + k] * SIMD4<Float>(p[0].asFloat, p[1].asFloat, p[2].asFloat, p[3].asFloat)
            }
            UnsafeMutableRawPointer(out + dx * 4).storeBytes(of: s, as: SIMD4<Float>.self)
        }
    default:
        for dx in 0..<dw {
            for ch in 0..<c {
                var s: Float = 0
                for k in 0..<K { s += w[dx * K + k] * src[Int(idx[dx * K + k]) * c + ch].asFloat }
                out[dx * c + ch] = s
            }
        }
    }
}

private func resizeSeparable<T: SRPix>(_ src: SRImage, _ dst: SRImage, _ tx: SRTaps, _ ty: SRTaps, _: T.Type) {
    let c = src.channels, dw = dst.width, dh = dst.height, sw = src.width
    let n = dw * c
    let nP = (n + 31) & ~31
    var maxTaps = 2
    for y in 0..<dh { maxTaps = max(maxTaps, Int(ty.off[y + 1] - ty.off[y])) }
    var slots = 4
    while slots < maxTaps { slots *= 2 }   // every tap row of one output row must stay resident
    let cache = UnsafeMutablePointer<Float>.allocate(capacity: slots * nP + 64)
    cache.initialize(repeating: 0, count: slots * nP + 64)
    let acc = UnsafeMutablePointer<Float>.allocate(capacity: nP + 64)
    acc.initialize(repeating: 0, count: nP + 64)
    let fbuf = UnsafeMutablePointer<Float>.allocate(capacity: sw * c + 16)   // one source row as float
    defer { cache.deallocate(); acc.deallocate(); fbuf.deallocate() }
    var keys = [Int](repeating: -1, count: slots)
    let K = tx.fixedK
    let clipHigh: Float? = T.self == UInt8.self ? 255 : (T.self == UInt16.self ? 65535 : nil)
    var rowPtrs = [UnsafePointer<Float>]()
    tx.idx.withUnsafeBufferPointer { xi in
    tx.w.withUnsafeBufferPointer { xw in
    ty.idx.withUnsafeBufferPointer { idx in
    ty.w.withUnsafeBufferPointer { w in
        let xo = tx.off
        func hrow(_ srow: UnsafePointer<T>, _ out: UnsafeMutablePointer<Float>) {
            T.toFloatRow(srow, fbuf, sw * c)
            let f = UnsafePointer(fbuf)
            switch K {
            case 2: hFixed(f, c, dw, 2, xi.baseAddress!, xw.baseAddress!, out)
            case 4: hFixed(f, c, dw, 4, xi.baseAddress!, xw.baseAddress!, out)
            case 8: hFixed(f, c, dw, 8, xi.baseAddress!, xw.baseAddress!, out)
            default: hResample(f, c, dw, SRTaps(off: xo, idx: tx.idx, w: tx.w), out)
            }
        }
        for y in 0..<dh {
            let t0 = Int(ty.off[y]), t1 = Int(ty.off[y + 1])
            rowPtrs.removeAll(keepingCapacity: true)
            for t in t0..<t1 {
                let sy = Int(idx[t])
                let slot = sy & (slots - 1)
                let row = cache + slot * nP
                if keys[slot] != sy {
                    hrow(UnsafePointer(src.row(sy).assumingMemoryBound(to: T.self)), row)
                    keys[slot] = sy
                }
                rowPtrs.append(UnsafePointer(row))
            }
            rowPtrs.withUnsafeBufferPointer { rp in
                srRowsCombine(rp.baseAddress!, w.baseAddress! + t0, t1 - t0, acc, nP)
            }
            // cubic / Lanczos weights are negative in places, so a sum can leave the sample range; vDSP's float -> integer
            // conversion wraps instead of saturating, so clip to the destination range first.
            if let hi = clipHigh {
                var lo: Float = 0, h = hi
                vDSP_vclip(acc, 1, &lo, &h, acc, 1, vDSP_Length(n))
            }
            T.storeRow(acc, dst.row(y).assumingMemoryBound(to: T.self), n, 0)
        }
    }}}}
}

@inline(__always) private func w16(_ p: UnsafePointer<UInt8>) -> SIMD16<UInt16> {
    let v: SIMD16<UInt8> = UnsafeRawPointer(p).loadUnaligned(as: SIMD16<UInt8>.self)
    return SIMD16<UInt16>(truncatingIfNeeded: v)
}

/// Exact 2x2 box mean for u8 (INTER_AREA with scale 2 on both axes), integer arithmetic, SIMD.
private func areaHalfU8(_ src: SRImage, _ dst: SRImage) {
    let c = src.channels, ow = dst.width, oh = dst.height
    for y in 0..<oh {
        let a = UnsafePointer<UInt8>(OpaquePointer(src.row(2 * y)))
        let b = UnsafePointer<UInt8>(OpaquePointer(src.row(2 * y + 1)))
        let o = UnsafeMutablePointer<UInt8>(OpaquePointer(dst.row(y)))
        var x = 0
        let two = SIMD8<UInt16>(repeating: 2)
        switch c {
        case 4:   // 4 px in -> 2 px out (8 bytes)
            while x + 2 <= ow {
                let s: SIMD16<UInt16> = w16(a + x * 8) &+ w16(b + x * 8)
                let p0: SIMD4<UInt16> = s.lowHalf.lowHalf &+ s.lowHalf.highHalf
                let p1: SIMD4<UInt16> = s.highHalf.lowHalf &+ s.highHalf.highHalf
                let q8 = SIMD8<UInt16>(lowHalf: p0, highHalf: p1)
                let r: SIMD8<UInt16> = (q8 &+ two) &>> 2
                UnsafeMutableRawPointer(o + x * 4).storeBytes(of: SIMD8<UInt8>(truncatingIfNeeded: r), as: SIMD8<UInt8>.self)
                x += 2
            }
        case 1:   // 16 px in -> 8 out
            while x + 8 <= ow {
                let s: SIMD16<UInt16> = w16(a + x * 2) &+ w16(b + x * 2)
                let e: SIMD8<UInt16> = s.evenHalf &+ s.oddHalf
                let r: SIMD8<UInt16> = (e &+ two) &>> 2
                UnsafeMutableRawPointer(o + x).storeBytes(of: SIMD8<UInt8>(truncatingIfNeeded: r), as: SIMD8<UInt8>.self)
                x += 8
            }
        case 3:   // 4 px (12 bytes) in -> 2 px (6 bytes) out; needs 16 readable bytes and 8 writable
            while x + 3 <= ow && (x * 6 + 16) <= src.width * 3 {
                let s: SIMD16<UInt16> = w16(a + x * 6) &+ w16(b + x * 6)
                var r = SIMD8<UInt16>(repeating: 0)
                r[0] = s[0] &+ s[3]; r[1] = s[1] &+ s[4]; r[2] = s[2] &+ s[5]
                r[3] = s[6] &+ s[9]; r[4] = s[7] &+ s[10]; r[5] = s[8] &+ s[11]
                let r2: SIMD8<UInt16> = (r &+ two) &>> 2
                let q = SIMD8<UInt8>(truncatingIfNeeded: r2)
                UnsafeMutableRawPointer(o + x * 3).storeBytes(of: q, as: SIMD8<UInt8>.self)
                x += 2
            }
        default: break
        }
        while x < ow {
            for ch in 0..<c {
                let i = x * 2 * c + ch
                let sum = Int(a[i]) + Int(a[i + c]) + Int(b[i]) + Int(b[i + c])
                o[x * c + ch] = UInt8((sum + 2) >> 2)
            }
            x += 1
        }
    }
}

private func resizeNearest(_ src: SRImage, _ dst: SRImage, _ sx: Double, _ sy: Double) {
    let pb = src.pixelBytes
    var xofs = [Int](repeating: 0, count: dst.width)
    for x in 0..<dst.width { xofs[x] = min(srFloor(Double(x) * sx), src.width - 1) }
    for y in 0..<dst.height {
        let syi = min(srFloor(Double(y) * sy), src.height - 1)
        let s = UnsafeRawPointer(src.row(syi)), o = dst.row(y)
        for x in 0..<dst.width {
            memcpy(o + x * pb, s + xofs[x] * pb, pb)
        }
    }
}

/// scaleX/scaleY = source pixels per destination pixel (OpenCV's 1/fx).
@_cdecl("sr_resize")
public func sr_resize(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                      _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
                      _ interp: Int32, _ scaleX: Double, _ scaleY: Double) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep), let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          src.channels == dst.channels, src.depth == dst.depth, src.width > 0, src.height > 0,
          dst.width > 0, dst.height > 0, scaleX > 0, scaleY > 0 else {
        return srFail(SRStatus.badArgument, "resize: bad image arguments")
    }
    guard src.depth == .u8 || src.depth == .u16 || src.depth == .f32 else {
        return srFail(SRStatus.unsupported, "resize: only u8, u16 and f32 images are supported")
    }
    var mode = interp & 7
    if mode == 6 { mode = 0 }  // NEAREST_EXACT → nearest (approximation)
    if mode == 5 { mode = 1 }  // LINEAR_EXACT → linear
    // OpenCV: LINEAR with an exact 2x shrink is computed as AREA.
    if mode == 1 {
        let ix = scaleX.rounded(), iy = scaleY.rounded()
        if abs(scaleX - ix) < Double.ulpOfOne && abs(scaleY - iy) < Double.ulpOfOne && ix == 2 && iy == 2 { mode = 3 }
    }
    // OpenCV: INTER_AREA is true area averaging only when both axes shrink; otherwise its generic path uses a
    // two-tap "area mode" formula on each axis.
    let areaMode2 = mode == 3 && !(scaleX >= 1 && scaleY >= 1)
    if mode == 0 { resizeNearest(src, dst, scaleX, scaleY); return SRStatus.ok }
    if mode == 3 && !areaMode2 && src.depth == .u8 && scaleX == 2 && scaleY == 2 && src.width == dst.width * 2
        && src.height == dst.height * 2 && src.channels != 2 {
        areaHalfU8(src, dst); return SRStatus.ok
    }
    let tx: SRTaps, ty: SRTaps
    switch mode {
    case 2:
        tx = cubicTaps(dst.width, src.width, scaleX); ty = cubicTaps(dst.height, src.height, scaleY)
    case 4:
        tx = lanczosTaps(dst.width, src.width, scaleX); ty = lanczosTaps(dst.height, src.height, scaleY)
    case 3 where areaMode2:
        tx = areaModeTaps(dst.width, src.width, scaleX); ty = areaModeTaps(dst.height, src.height, scaleY)
    case 3:
        tx = areaTaps(dst.width, src.width, scaleX); ty = areaTaps(dst.height, src.height, scaleY)
    default:
        tx = linearTaps(dst.width, src.width, scaleX); ty = linearTaps(dst.height, src.height, scaleY)
    }
    switch src.depth {
    case .u8: resizeSeparable(src, dst, tx, ty, UInt8.self)
    case .u16: resizeSeparable(src, dst, tx, ty, UInt16.self)
    default: resizeSeparable(src, dst, tx, ty, Float.self)
    }
    return SRStatus.ok
}
