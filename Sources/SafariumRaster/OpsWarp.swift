// SafariumRaster — cv::warpAffine and cv::remap (NEAREST / LINEAR / CUBIC / LANCZOS4; all OpenCV border modes),
// u8 / u16 / f32, 1-4 channels. Both share one row sampler working on OpenCV's fixed-point positions
// (INTER_BITS = 5, i.e. 1/32 px), so sampling positions quantise exactly like cv2. warpAffine also follows cv2's
// AB_BITS = 10 coordinate pipeline.

import Foundation

private let abBits = 10
private let abScale = 1 << abBits
private let interBits = 5
private let interTab = 1 << interBits

/// Interpolation tables: cubic (A = -0.75, 4 taps), Lanczos4 (8 taps) per 1/32 step, plus SIMD weight patterns.
private final class SampleTables {
    let cub = UnsafeMutablePointer<Float>.allocate(capacity: interTab * 4)
    let lan = UnsafeMutablePointer<Float>.allocate(capacity: interTab * 8)
    let pat = UnsafeMutablePointer<SIMD16<Float>>.allocate(capacity: interTab)   // x-weights laid out for c channels
    init(channels c: Int) {
        for i in 0..<interTab {
            let x = Double(i) / Double(interTab)
            let a = -0.75
            let c0 = ((a * (x + 1) - 5 * a) * (x + 1) + 8 * a) * (x + 1) - 4 * a
            let c1 = ((a + 2) * x - (a + 3)) * x * x + 1
            let c2 = ((a + 2) * (1 - x) - (a + 3)) * (1 - x) * (1 - x) + 1
            let w = [Float(c0), Float(c1), Float(c2), Float(1 - c0 - c1 - c2)]
            for k in 0..<4 { cub[i * 4 + k] = w[k] }
            let l = SampleTables.lanczos4(x)
            for k in 0..<8 { lan[i * 8 + k] = l[k] }
            var p = SIMD16<Float>(repeating: 0)
            if c == 1 { for k in 0..<4 { p[k] = w[k] } }
            else { for k in 0..<4 { for ch in 0..<c { p[k * c + ch] = w[k] } } }
            pat[i] = p
        }
    }
    deinit { cub.deallocate(); lan.deallocate(); pat.deallocate() }

    /// cv::interpolateLanczos4
    static func lanczos4(_ x: Double) -> [Float] {
        var coeffs = [Float](repeating: 0, count: 8)
        if x < Double(Float.ulpOfOne) { coeffs[3] = 1; return coeffs }
        let s45 = 0.70710678118654752440084436210485
        let cs: [(Double, Double)] = [(1, 0), (-s45, -s45), (0, 1), (s45, -s45), (-1, 0), (s45, s45), (0, -1), (-s45, s45)]
        var sum: Float = 0
        let y0 = -(x + 3) * Double.pi * 0.25
        let s0 = sin(y0), c0 = cos(y0)
        for i in 0..<8 {
            let y = -(x + 3 - Double(i)) * Double.pi * 0.25
            coeffs[i] = Float((cs[i].0 * s0 + cs[i].1 * c0) / (y * y))
            sum += coeffs[i]
        }
        sum = 1 / sum
        for i in 0..<8 { coeffs[i] *= sum }
        return coeffs
    }
}

private struct Sampler<T: SRPix> {
    let src: SRImage
    let interp: Int          // 0 nearest, 1 linear, 2 cubic, 4 lanczos4
    let border: Int32
    let bval: [Double]
    let tab: SampleTables
    let c: Int
    let sw: Int, sh: Int
    let simdMargin: Int      // pixels a 16-lane load starting at (sx-1) touches

    init(src: SRImage, interp: Int, border: Int32, bval: [Double], tab: SampleTables) {
        self.src = src; self.interp = interp; self.border = border; self.bval = bval; self.tab = tab
        c = src.channels; sw = src.width; sh = src.height
        simdMargin = (16 + src.channels - 1) / src.channels
    }

    @inline(__always) func tap(_ x: Int, _ y: Int, _ ch: Int) -> Float? {
        var xx = x, yy = y
        if x < 0 || x >= sw || y < 0 || y >= sh {
            if border == SR_BORDER_CONSTANT { return Float(bval[ch]) }
            if border == SR_BORDER_TRANSPARENT { return nil }
            xx = srBorderInterp(x, sw, border)
            yy = srBorderInterp(y, sh, border)
            if xx < 0 || yy < 0 { return Float(bval[ch]) }
        }
        return src.row(yy).assumingMemoryBound(to: T.self)[xx * c + ch].asFloat
    }

    /// General (border-aware) pixel for K-tap interpolation. Returns false when the pixel must be left untouched.
    @inline(never)
    func slow(_ sx: Int, _ sy: Int, _ fx: Int, _ fy: Int, _ op: UnsafeMutablePointer<T>) -> Bool {
        let K = interp == 1 ? 2 : (interp == 2 ? 4 : 8)
        let base = K / 2 - 1
        var wx = [Float](repeating: 0, count: 8), wy = [Float](repeating: 0, count: 8)
        switch interp {
        case 1:
            wx[0] = Float(32 - fx) / 32; wx[1] = Float(fx) / 32; wy[0] = Float(32 - fy) / 32; wy[1] = Float(fy) / 32
        case 2:
            for k in 0..<4 { wx[k] = tab.cub[fx * 4 + k]; wy[k] = tab.cub[fy * 4 + k] }
        default:
            for k in 0..<8 { wx[k] = tab.lan[fx * 8 + k]; wy[k] = tab.lan[fy * 8 + k] }
        }
        for ch in 0..<c {
            var acc: Float = 0
            for j in 0..<K {
                var r: Float = 0
                for i in 0..<K {
                    guard let v = tap(sx - base + i, sy - base + j, ch) else { return false }
                    r += wx[i] * v
                }
                acc += wy[j] * r
            }
            op[ch] = T.fromFloat(acc)
        }
        return true
    }

    func row(_ X: UnsafePointer<Int32>, _ Y: UnsafePointer<Int32>, _ n: Int, _ out: UnsafeMutablePointer<T>) {
        let c = self.c
        if interp == 0 {
            for x in 0..<n {
                let sx = Int(X[x]), sy = Int(Y[x])
                let op = out + x * c
                if UInt(bitPattern: sx) < UInt(sw) && UInt(bitPattern: sy) < UInt(sh) {
                    let s = src.row(sy).assumingMemoryBound(to: T.self) + sx * c
                    switch c {
                    case 1: op[0] = s[0]
                    case 3: op[0] = s[0]; op[1] = s[1]; op[2] = s[2]
                    case 4: op[0] = s[0]; op[1] = s[1]; op[2] = s[2]; op[3] = s[3]
                    default: for ch in 0..<c { op[ch] = s[ch] }
                    }
                } else if border == SR_BORDER_TRANSPARENT {
                    continue
                } else if border == SR_BORDER_CONSTANT {
                    for ch in 0..<c { op[ch] = T.fromFloat(Float(bval[ch])) }
                } else {
                    let xx = srBorderInterp(sx, sw, border), yy = srBorderInterp(sy, sh, border)
                    let s = src.row(yy).assumingMemoryBound(to: T.self) + xx * c
                    for ch in 0..<c { op[ch] = s[ch] }
                }
            }
            return
        }
        let rowBytes = src.stride
        let base0 = UnsafeRawPointer(src.data)
        switch interp {
        case 1:
            for x in 0..<n {
                let X = Int(X[x]), Y = Int(Y[x])
                let sx = X >> interBits, sy = Y >> interBits
                let fx = X & (interTab - 1), fy = Y & (interTab - 1)
                let op = out + x * c
                if UInt(bitPattern: sx) < UInt(sw - 1) && UInt(bitPattern: sy) < UInt(sh - 1) {
                    let p0 = (base0 + sy * rowBytes).assumingMemoryBound(to: T.self) + sx * c
                    let p1 = (base0 + (sy + 1) * rowBytes).assumingMemoryBound(to: T.self) + sx * c
                    if T.self == UInt8.self {
                        // 10-bit combined weights: v = (sum p*w + 512) >> 10 (exact, no float)
                        let a0 = Int32(32 - fx), a1 = Int32(fx), b0 = Int32(32 - fy), b1 = Int32(fy)
                        let q0 = UnsafeRawPointer(p0).assumingMemoryBound(to: UInt8.self)
                        let q1 = UnsafeRawPointer(p1).assumingMemoryBound(to: UInt8.self)
                        let o = UnsafeMutableRawPointer(op).assumingMemoryBound(to: UInt8.self)
                        if (c == 4 || (c == 3 && sx + 2 < sw && sx < sw - 2)) && (c == 4 || sy + 1 < sh) {
                            // 4-byte window per pixel: [px, next px] -> SIMD4 lanes (c = 3 reads one byte past the pixel)
                            @inline(__always) func w4(_ p: UnsafePointer<UInt8>) -> SIMD4<Int32> {
                                SIMD4<Int32>(truncatingIfNeeded: UnsafeRawPointer(p).loadUnaligned(as: SIMD4<UInt8>.self))
                            }
                            let va = SIMD4<Int32>(repeating: a0), vb = SIMD4<Int32>(repeating: a1)
                            let vc = SIMD4<Int32>(repeating: b0), vd = SIMD4<Int32>(repeating: b1)
                            let t0 = w4(q0) &* va &+ w4(q0 + c) &* vb
                            let t1 = w4(q1) &* va &+ w4(q1 + c) &* vb
                            let r = (t0 &* vc &+ t1 &* vd &+ SIMD4<Int32>(repeating: 512)) &>> 10
                            let b = SIMD4<UInt8>(truncatingIfNeeded: r)
                            if c == 4 {
                                UnsafeMutableRawPointer(o).storeBytes(of: b, as: SIMD4<UInt8>.self)
                            } else {
                                o[0] = b[0]; o[1] = b[1]; o[2] = b[2]
                            }
                        } else {
                            @inline(__always) func lerp(_ k: Int) -> UInt8 {
                                let t = (Int32(q0[k]) * a0 + Int32(q0[k + c]) * a1) * b0 + (Int32(q1[k]) * a0 + Int32(q1[k + c]) * a1) * b1
                                return UInt8(truncatingIfNeeded: (t + 512) >> 10)
                            }
                            switch c {
                            case 1: o[0] = lerp(0)
                            case 3: o[0] = lerp(0); o[1] = lerp(1); o[2] = lerp(2)
                            case 4: o[0] = lerp(0); o[1] = lerp(1); o[2] = lerp(2); o[3] = lerp(3)
                            default: for k in 0..<c { o[k] = lerp(k) }
                            }
                        }
                    } else {
                        let a0 = Float(32 - fx) * (1.0 / 32), a1 = Float(fx) * (1.0 / 32)
                        let b0 = Float(32 - fy) * (1.0 / 32), b1 = Float(fy) * (1.0 / 32)
                        for k in 0..<c {
                            let t = (p0[k].asFloat * a0 + p0[k + c].asFloat * a1) * b0 + (p1[k].asFloat * a0 + p1[k + c].asFloat * a1) * b1
                            op[k] = T.fromFloat(t)
                        }
                    }
                } else if !slow(sx, sy, fx, fy, op) { continue }
            }
        case 2:
            let patBase = tab.pat, cub = tab.cub
            let wide = c == 1 || c == 3 || c == 4
            for x in 0..<n {
                let X = Int(X[x]), Y = Int(Y[x])
                let sx = X >> interBits, sy = Y >> interBits
                let fx = X & (interTab - 1), fy = Y & (interTab - 1)
                let op = out + x * c
                if sy >= 1 && sy + 2 < sh && sx >= 1 {
                    if wide && sx - 1 + simdMargin <= sw {
                        let wxp = patBase[fx]
                        let wy0 = cub[fy * 4], wy1 = cub[fy * 4 + 1], wy2 = cub[fy * 4 + 2], wy3 = cub[fy * 4 + 3]
                        let r0 = (base0 + (sy - 1) * rowBytes).assumingMemoryBound(to: T.self) + (sx - 1) * c
                        let r1 = (base0 + sy * rowBytes).assumingMemoryBound(to: T.self) + (sx - 1) * c
                        let r2 = (base0 + (sy + 1) * rowBytes).assumingMemoryBound(to: T.self) + (sx - 1) * c
                        let r3 = (base0 + (sy + 2) * rowBytes).assumingMemoryBound(to: T.self) + (sx - 1) * c
                        var acc = T.load16(r0) * wxp * wy0
                        acc += T.load16(r1) * wxp * wy1
                        acc += T.load16(r2) * wxp * wy2
                        acc += T.load16(r3) * wxp * wy3
                        if c == 1 {
                            op[0] = T.fromFloat(acc.sum())
                        } else if c == 4 {
                            let s = (acc.lowHalf.lowHalf + acc.lowHalf.highHalf) + (acc.highHalf.lowHalf + acc.highHalf.highHalf)
                            op[0] = T.fromFloat(s[0]); op[1] = T.fromFloat(s[1]); op[2] = T.fromFloat(s[2]); op[3] = T.fromFloat(s[3])
                        } else {
                            op[0] = T.fromFloat((acc[0] + acc[3]) + (acc[6] + acc[9]))
                            op[1] = T.fromFloat((acc[1] + acc[4]) + (acc[7] + acc[10]))
                            op[2] = T.fromFloat((acc[2] + acc[5]) + (acc[8] + acc[11]))
                        }
                        continue
                    }
                    if sx + 2 < sw {
                        let wx0 = cub[fx * 4], wx1 = cub[fx * 4 + 1], wx2 = cub[fx * 4 + 2], wx3 = cub[fx * 4 + 3]
                        let wy = (cub[fy * 4], cub[fy * 4 + 1], cub[fy * 4 + 2], cub[fy * 4 + 3])
                        for k in 0..<c {
                            var acc: Float = 0
                            for j in 0..<4 {
                                let p = (base0 + (sy - 1 + j) * rowBytes).assumingMemoryBound(to: T.self) + (sx - 1) * c + k
                                let v = wx0 * p[0].asFloat + wx1 * p[c].asFloat + wx2 * p[2 * c].asFloat + wx3 * p[3 * c].asFloat
                                acc += (j == 0 ? wy.0 : (j == 1 ? wy.1 : (j == 2 ? wy.2 : wy.3))) * v
                            }
                            op[k] = T.fromFloat(acc)
                        }
                        continue
                    }
                }
                if !slow(sx, sy, fx, fy, op) { continue }
            }
        default:  // Lanczos4
            let lan = tab.lan
            for x in 0..<n {
                let X = Int(X[x]), Y = Int(Y[x])
                let sx = X >> interBits, sy = Y >> interBits
                let fx = X & (interTab - 1), fy = Y & (interTab - 1)
                let op = out + x * c
                if sx >= 3 && sx + 4 < sw && sy >= 3 && sy + 4 < sh {
                    for k in 0..<c {
                        var acc: Float = 0
                        for j in 0..<8 {
                            let p = (base0 + (sy - 3 + j) * rowBytes).assumingMemoryBound(to: T.self) + (sx - 3) * c + k
                            var r: Float = 0
                            for i in 0..<8 { r += lan[fx * 8 + i] * p[i * c].asFloat }
                            acc += lan[fy * 8 + j] * r
                        }
                        op[k] = T.fromFloat(acc)
                    }
                } else if !slow(sx, sy, fx, fy, op) { continue }
            }
        }
    }
}

@inline(__always) private func clampI32(_ v: Int) -> Int32 { Int32(max(-(1 << 30), min(1 << 30, v))) }

private func warpImpl<T: SRPix>(_ src: SRImage, _ dst: SRImage, _ m: [Double], _ interp: Int, _ border: Int32,
                                _ bval: [Double], _: T.Type) {
    let dw = dst.width, dh = dst.height
    let tab = SampleTables(channels: src.channels)
    let smp = Sampler<T>(src: src, interp: interp, border: border, bval: bval, tab: tab)
    var adelta = [Int32](repeating: 0, count: dw), bdelta = [Int32](repeating: 0, count: dw)
    for x in 0..<dw {
        adelta[x] = Int32(clamping: Int((m[0] * Double(x) * Double(abScale)).rounded(.toNearestOrEven)))
        bdelta[x] = Int32(clamping: Int((m[3] * Double(x) * Double(abScale)).rounded(.toNearestOrEven)))
    }
    let roundDelta = interp == 0 ? abScale / 2 : abScale / interTab / 2
    let shift = Int32(interp == 0 ? abBits : abBits - interBits)
    let X = UnsafeMutablePointer<Int32>.allocate(capacity: dw), Y = UnsafeMutablePointer<Int32>.allocate(capacity: dw)
    defer { X.deallocate(); Y.deallocate() }
    for y in 0..<dh {
        let xb = Int32(clamping: Int((m[1] * Double(y) + m[2]) * Double(abScale)) + roundDelta)
        let yb = Int32(clamping: Int((m[4] * Double(y) + m[5]) * Double(abScale)) + roundDelta)
        adelta.withUnsafeBufferPointer { ad in
            bdelta.withUnsafeBufferPointer { bd in
                for x in 0..<dw {
                    X[x] = (xb &+ ad[x]) >> shift
                    Y[x] = (yb &+ bd[x]) >> shift
                }
            }
        }
        smp.row(X, Y, dw, dst.row(y).assumingMemoryBound(to: T.self))
    }
}

private func remapImpl<T: SRPix>(_ src: SRImage, _ dst: SRImage, _ m1: SRImage, _ m2: SRImage?, _ interp: Int,
                                 _ border: Int32, _ bval: [Double], _: T.Type) {
    let dw = dst.width, dh = dst.height
    let tab = SampleTables(channels: src.channels)
    let smp = Sampler<T>(src: src, interp: interp, border: border, bval: bval, tab: tab)
    let X = UnsafeMutablePointer<Int32>.allocate(capacity: dw), Y = UnsafeMutablePointer<Int32>.allocate(capacity: dw)
    defer { X.deallocate(); Y.deallocate() }
    let scale: Float = interp == 0 ? 1 : Float(interTab)
    @inline(__always) func fix(_ v: Float) -> Int32 {
        if v.isNaN { return -(1 << 30) }
        let t = max(-1e9, min(1e9, v * scale))
        return Int32(t.rounded(.toNearestOrEven))
    }
    for y in 0..<dh {
        if let m2 {
            let a = m1.row(y).assumingMemoryBound(to: Float.self), b = m2.row(y).assumingMemoryBound(to: Float.self)
            for x in 0..<dw { X[x] = fix(a[x]); Y[x] = fix(b[x]) }
        } else {
            let a = m1.row(y).assumingMemoryBound(to: Float.self)
            for x in 0..<dw { X[x] = fix(a[2 * x]); Y[x] = fix(a[2 * x + 1]) }
        }
        smp.row(X, Y, dw, dst.row(y).assumingMemoryBound(to: T.self))
    }
}

private func dispatch(_ src: SRImage, _ f8: () -> Void, _ f16: () -> Void, _ ff: () -> Void) {
    switch src.depth { case .u8: f8(); case .u16: f16(); default: ff() }
}

@inline(__always)
private func validBorder(_ b: Int32) -> Bool {
    switch b {
    case SR_BORDER_CONSTANT, SR_BORDER_REPLICATE, SR_BORDER_REFLECT,
         SR_BORDER_WRAP, SR_BORDER_REFLECT_101, SR_BORDER_TRANSPARENT:
        return true
    default:
        return false
    }
}

@_silgen_name("sr_c_warp_affine")
private func sr_c_warp_affine(_ src: UnsafeRawPointer, _ sstep: Int, _ sw: Int32, _ sh: Int32,
                              _ dst: UnsafeMutableRawPointer, _ dstep: Int, _ dw: Int32, _ dh: Int32,
                              _ cn: Int32, _ depth: Int32, _ m6: UnsafePointer<Double>,
                              _ interp: Int32, _ border: Int32, _ bval: UnsafePointer<Double>) -> Int32

@_silgen_name("sr_c_warp_perspective")
private func sr_c_warp_perspective(_ src: UnsafeRawPointer, _ sstep: Int, _ sw: Int32, _ sh: Int32,
                                   _ dst: UnsafeMutableRawPointer, _ dstep: Int, _ dw: Int32, _ dh: Int32,
                                   _ cn: Int32, _ depth: Int32, _ m9: UnsafePointer<Double>,
                                   _ interp: Int32, _ border: Int32, _ bval: UnsafePointer<Double>) -> Int32

@_silgen_name("sr_c_remap")
private func sr_c_remap(_ src: UnsafeRawPointer, _ sstep: Int, _ sw: Int32, _ sh: Int32,
                        _ dst: UnsafeMutableRawPointer, _ dstep: Int, _ dw: Int32, _ dh: Int32,
                        _ cn: Int32, _ depth: Int32,
                        _ m1: UnsafePointer<Float>, _ m1step: Int, _ m1cn: Int32,
                        _ m2: UnsafePointer<Float>?, _ m2step: Int,
                        _ interp: Int32, _ border: Int32, _ bval: UnsafePointer<Double>) -> Int32

/// m: 6 doubles (2x3, row-major). If WARP_INVERSE_MAP (16) is not set the matrix is the forward map and gets inverted.
@_cdecl("sr_warp_affine")
public func sr_warp_affine(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                           _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
                           _ matrix: UnsafePointer<Double>?, _ flags: Int32, _ borderMode: Int32,
                           _ borderValue: UnsafePointer<Double>?) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep), let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          src.channels == dst.channels, src.depth == dst.depth, let matrix, let borderValue,
          src.width > 0, src.height > 0 else {
        return srFail(SRStatus.badArgument, "warpAffine: bad image arguments")
    }
    guard src.depth == .u8 || src.depth == .u16 || src.depth == .f32 else {
        return srFail(SRStatus.unsupported, "warpAffine: only u8, u16 and f32 images are supported")
    }
    var interp = Int32(flags & 7)
    if interp == 3 { interp = 1 }  // INTER_AREA behaves as linear in warps
    guard interp <= 2 || interp == 4 else { return srFail(SRStatus.unsupported, "warpAffine: interpolation not supported") }
    guard validBorder(borderMode) else { return srFail(SRStatus.unsupported, "warpAffine: unknown border mode") }
    let rc: Int32
    if flags & 16 != 0 {
        rc = sr_c_warp_affine(src.data, src.stride, sw, sh, dst.data, dst.stride, dw, dh,
                              sc, sdep, matrix, interp, borderMode, borderValue)
    } else {
        let m0 = matrix[0], m1 = matrix[1], m2 = matrix[2]
        let m3 = matrix[3], m4 = matrix[4], m5 = matrix[5]
        var d = m0 * m4 - m1 * m3
        d = d != 0 ? 1.0 / d : 0
        let a11 = m4 * d, a22 = m0 * d, a12 = -m1 * d, a21 = -m3 * d
        let b1 = -a11 * m2 - a12 * m5, b2 = -a21 * m2 - a22 * m5
        var inv = (a11, a12, b1, a21, a22, b2)
        rc = withUnsafeBytes(of: &inv) { raw in
            sr_c_warp_affine(src.data, src.stride, sw, sh, dst.data, dst.stride, dw, dh,
                             sc, sdep, raw.baseAddress!.assumingMemoryBound(to: Double.self),
                             interp, borderMode, borderValue)
        }
    }
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.internalError, "warpAffine failed")
}

/// Maps: either map1 = f32 2-channel (x,y) and map2 data NULL, or map1/map2 = f32 1-channel (x, y). Same size as dst.
@_cdecl("sr_remap")
public func sr_remap(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                     _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
                     _ m1d: UnsafeMutableRawPointer?, _ m1w: Int32, _ m1h: Int32, _ m1s: Int32, _ m1c: Int32, _ m1dep: Int32,
                     _ m2d: UnsafeMutableRawPointer?, _ m2w: Int32, _ m2h: Int32, _ m2s: Int32, _ m2c: Int32, _ m2dep: Int32,
                     _ interp: Int32, _ borderMode: Int32, _ borderValue: UnsafePointer<Double>?) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep), let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          src.channels == dst.channels, src.depth == dst.depth, let borderValue, src.width > 0, src.height > 0,
          let map1 = SRImage(m1d, m1w, m1h, m1s, m1c, m1dep), map1.depth == .f32,
          map1.width == dst.width, map1.height == dst.height else {
        return srFail(SRStatus.badArgument, "remap: bad image or map arguments")
    }
    var map2: SRImage? = nil
    if m2d != nil {
        guard let m = SRImage(m2d, m2w, m2h, m2s, m2c, m2dep), m.depth == .f32, m.channels == 1, map1.channels == 1,
              m.width == dst.width, m.height == dst.height else {
            return srFail(SRStatus.badArgument, "remap: map2 must be a 1-channel f32 map matching map1")
        }
        map2 = m
    } else if map1.channels != 2 {
        return srFail(SRStatus.badArgument, "remap: a single map must be 2-channel f32 (CV_32FC2)")
    }
    guard src.depth == .u8 || src.depth == .u16 || src.depth == .f32 else {
        return srFail(SRStatus.unsupported, "remap: only u8, u16 and f32 images are supported")
    }
    var mode = interp & 7
    if mode == 3 { mode = 1 }
    guard mode <= 2 || mode == 4 else { return srFail(SRStatus.unsupported, "remap: interpolation not supported") }
    guard validBorder(borderMode) else { return srFail(SRStatus.unsupported, "remap: unknown border mode") }
    let rc = sr_c_remap(src.data, src.stride, sw, sh, dst.data, dst.stride, dw, dh, sc, sdep,
                        map1.data.assumingMemoryBound(to: Float.self), map1.stride, m1c,
                        map2?.data.assumingMemoryBound(to: Float.self), map2?.stride ?? 0,
                        mode, borderMode, borderValue)
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.internalError, "remap failed")
}

private func warpPerspectiveImpl<T: SRPix>(_ src: SRImage, _ dst: SRImage, _ m: [Double], _ interp: Int, _ border: Int32,
                                           _ bval: [Double], _: T.Type) {
    let dw = dst.width, dh = dst.height
    let tab = SampleTables(channels: src.channels)
    let smp = Sampler<T>(src: src, interp: interp, border: border, bval: bval, tab: tab)
    let scale: Double = interp == 0 ? 1.0 : Double(interTab)
    let X = UnsafeMutablePointer<Int32>.allocate(capacity: dw), Y = UnsafeMutablePointer<Int32>.allocate(capacity: dw)
    defer { X.deallocate(); Y.deallocate() }
    for y in 0..<dh {
        let dy = Double(y)
        let bx = m[1] * dy + m[2], by = m[4] * dy + m[5], bw = m[7] * dy + m[8]
        for x in 0..<dw {
            let dx = Double(x)
            let w = m[6] * dx + bw
            let iw = w != 0.0 ? (1.0 / w) : 0.0
            let sx = max(-1e6, min(1e6, (m[0] * dx + bx) * iw))
            let sy = max(-1e6, min(1e6, (m[3] * dx + by) * iw))
            X[x] = Int32((sx * scale).rounded(.toNearestOrEven))
            Y[x] = Int32((sy * scale).rounded(.toNearestOrEven))
        }
        smp.row(X, Y, dw, dst.row(y).assumingMemoryBound(to: T.self))
    }
}

/// m: 9 doubles (3x3 row-major). If WARP_INVERSE_MAP (16) is not set, invert M first.
@_cdecl("sr_warp_perspective")
public func sr_warp_perspective(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                                _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
                                _ matrix: UnsafePointer<Double>?, _ flags: Int32, _ borderMode: Int32,
                                _ borderValue: UnsafePointer<Double>?) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep), let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          src.channels == dst.channels, src.depth == dst.depth, let matrix, let borderValue,
          src.width > 0, src.height > 0 else {
        return srFail(SRStatus.badArgument, "warpPerspective: bad image arguments")
    }
    guard src.depth == .u8 || src.depth == .u16 || src.depth == .f32 else {
        return srFail(SRStatus.unsupported, "warpPerspective: only u8, u16 and f32 images are supported")
    }
    var interp = Int32(flags & 7)
    if interp == 3 { interp = 1 }
    guard interp <= 2 || interp == 4 else { return srFail(SRStatus.unsupported, "warpPerspective: interpolation not supported") }
    guard validBorder(borderMode) else { return srFail(SRStatus.unsupported, "warpPerspective: unknown border mode") }
    let rc: Int32
    if flags & 16 != 0 {
        rc = sr_c_warp_perspective(src.data, src.stride, sw, sh, dst.data, dst.stride, dw, dh,
                                   sc, sdep, matrix, interp, borderMode, borderValue)
    } else {
        let m0 = matrix[0], m1 = matrix[1], m2 = matrix[2]
        let m3 = matrix[3], m4 = matrix[4], m5 = matrix[5]
        let m6 = matrix[6], m7 = matrix[7], m8 = matrix[8]
        let c00 = m4*m8 - m5*m7, c01 = m5*m6 - m3*m8, c02 = m3*m7 - m4*m6
        let c10 = m2*m7 - m1*m8, c11 = m0*m8 - m2*m6, c12 = m1*m6 - m0*m7
        let c20 = m1*m5 - m2*m4, c21 = m2*m3 - m0*m5, c22 = m0*m4 - m1*m3
        let det = m0*c00 + m1*c01 + m2*c02
        let invDet = det != 0.0 ? (1.0 / det) : 0.0
        var inv = (c00*invDet, c10*invDet, c20*invDet,
                   c01*invDet, c11*invDet, c21*invDet,
                   c02*invDet, c12*invDet, c22*invDet)
        rc = withUnsafeBytes(of: &inv) { raw in
            sr_c_warp_perspective(src.data, src.stride, sw, sh, dst.data, dst.stride, dw, dh,
                                  sc, sdep, raw.baseAddress!.assumingMemoryBound(to: Double.self),
                                  interp, borderMode, borderValue)
        }
    }
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.internalError, "warpPerspective failed")
}

@_cdecl("sr_get_perspective")
public func sr_get_perspective(_ srcPts: UnsafePointer<Double>?, _ dstPts: UnsafePointer<Double>?,
                               _ solveMethod: Int32, _ outMat: UnsafeMutablePointer<Double>?) -> Int32 {
    guard let s = srcPts, let d = dstPts, let outMat else { return srFail(SRStatus.badArgument, "getPerspectiveTransform: null") }
    // Solve 8x8 linear system for homography [h0..h7, 1.0]
    var aRow = [Double](repeating: 0.0, count: 64)
    var bRow = [Double](repeating: 0.0, count: 8)
    for i in 0..<4 {
        let sx = s[2*i], sy = s[2*i+1], dx = d[2*i], dy = d[2*i+1]
        let r0 = i * 8, r1 = (i + 4) * 8
        aRow[r0 + 0] = sx; aRow[r0 + 1] = sy; aRow[r0 + 2] = 1.0
        aRow[r0 + 6] = -sx * dx; aRow[r0 + 7] = -sy * dx
        bRow[i] = dx
        aRow[r1 + 3] = sx; aRow[r1 + 4] = sy; aRow[r1 + 5] = 1.0
        aRow[r1 + 6] = -sx * dy; aRow[r1 + 7] = -sy * dy
        bRow[i + 4] = dy
    }
    var ok: Int32 = 0
    var x = [Double](repeating: 0.0, count: 8)
    let rc: Int32 = aRow.withUnsafeMutableBytes { ab in
        bRow.withUnsafeMutableBytes { bb in
            x.withUnsafeMutableBytes { xb in
                var cmA = CoreMat(data: ab.baseAddress!, rows: 8, cols: 8, step: 64, cn: 1, depth: 6)
                var cmB = CoreMat(data: bb.baseAddress!, rows: 8, cols: 1, step: 8, cn: 1, depth: 6)
                var cmX = CoreMat(data: xb.baseAddress!, rows: 8, cols: 1, step: 8, cn: 1, depth: 6)
                return sr_la_solve(&cmA, &cmB, &cmX, solveMethod, &ok)
            }
        }
    }
    if rc != 0 || ok == 0 { return srFail(SRStatus.badArgument, "getPerspectiveTransform: singular point configuration") }
    for i in 0..<8 { outMat[i] = x[i] }
    outMat[8] = 1.0
    return SRStatus.ok
}
