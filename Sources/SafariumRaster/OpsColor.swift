// SafariumRaster — Phase 3: Color space conversions (Lab, Luv, XYZ, YCrCb, YUV, HLS, HSV, linear/gamma BGR/RGB).
import Foundation
import SafariumRasterC

// MARK: - sRGB <-> Linear helpers (IEC 61966-2-1)

@inline(__always)
private func srgbToLin(_ v: Double) -> Double {
    v <= 0.04045 ? (v / 12.92) : pow((v + 0.055) / 1.055, 2.4)
}

@inline(__always)
private func linToSrgb(_ v: Double) -> Double {
    if v <= 0.0 { return 0.0 }
    if v >= 1.0 { return 1.0 }
    return v <= 0.0031308 ? (v * 12.92) : (1.055 * pow(v, 1.0 / 2.4) - 0.055)
}

private let srgbToLinLUT: [Double] = (0..<256).map { srgbToLin(Double($0) / 255.0) }

// MARK: - CIE Lab / Luv (D65)

private let labXn = 0.950456
private let labZn = 1.088754
private let labT0 = 0.008856

@inline(__always)
private func labF(_ t: Double) -> Double {
    t > labT0 ? cbrt(t) : (7.787 * t + 16.0 / 116.0)
}

@inline(__always)
private func labFInv(_ t: Double) -> Double {
    let t3 = t * t * t
    return t3 > labT0 ? t3 : ((t - 16.0 / 116.0) / 7.787)
}

@inline(__always)
private func rgbToLab(_ r: Double, _ g: Double, _ b: Double, _ linearIn: Bool) -> (Double, Double, Double) {
    let rl = linearIn ? r : srgbToLin(r)
    let gl = linearIn ? g : srgbToLin(g)
    let bl = linearIn ? b : srgbToLin(b)
    let X = (0.412453 * rl + 0.357580 * gl + 0.180423 * bl) / labXn
    let Y = 0.212671 * rl + 0.715160 * gl + 0.072169 * bl
    let Z = (0.019334 * rl + 0.119193 * gl + 0.950227 * bl) / labZn
    let fY = labF(Y)
    let L = Y > labT0 ? (116.0 * cbrt(Y) - 16.0) : (903.3 * Y)
    let a = 500.0 * (labF(X) - fY)
    let bLab = 200.0 * (fY - labF(Z))
    return (L, a, bLab)
}

@inline(__always)
private func labToRgb(_ L: Double, _ a: Double, _ b: Double, _ linearOut: Bool) -> (Double, Double, Double) {
    let fy = (L + 16.0) / 116.0
    let Y = L > 7.9996248 ? (fy * fy * fy) : (L / 903.3)
    let fyActual = labF(Y)
    let X = labXn * labFInv(fyActual + a / 500.0)
    let Z = labZn * labFInv(fyActual - b / 200.0)
    let rl = 3.240479 * X - 1.537150 * Y - 0.498535 * Z
    let gl = -0.969256 * X + 1.875992 * Y + 0.041556 * Z
    let bl = 0.055648 * X - 0.204043 * Y + 1.057311 * Z
    return linearOut ? (rl, gl, bl) : (linToSrgb(rl), linToSrgb(gl), linToSrgb(bl))
}

private let luvUn = 4.0 * labXn / (labXn + 15.0 + 3.0 * labZn)
private let luvVn = 9.0 / (labXn + 15.0 + 3.0 * labZn)

@inline(__always)
private func rgbToLuv(_ r: Double, _ g: Double, _ b: Double, _ linearIn: Bool) -> (Double, Double, Double) {
    let rl = linearIn ? r : srgbToLin(r)
    let gl = linearIn ? g : srgbToLin(g)
    let bl = linearIn ? b : srgbToLin(b)
    let X = 0.412453 * rl + 0.357580 * gl + 0.180423 * bl
    let Y = 0.212671 * rl + 0.715160 * gl + 0.072169 * bl
    let Z = 0.019334 * rl + 0.119193 * gl + 0.950227 * bl
    let L = Y > labT0 ? (116.0 * cbrt(Y) - 16.0) : (903.3 * Y)
    let denom = X + 15.0 * Y + 3.0 * Z
    if denom <= 1e-12 { return (L, 0.0, 0.0) }
    let u = 13.0 * L * (4.0 * X / denom - luvUn)
    let v = 13.0 * L * (9.0 * Y / denom - luvVn)
    return (L, u, v)
}

@inline(__always)
private func luvToRgb(_ L: Double, _ u: Double, _ v: Double, _ linearOut: Bool) -> (Double, Double, Double) {
    if L <= 1e-6 { return (0.0, 0.0, 0.0) }
    let Y = L > 7.9996248 ? pow((L + 16.0) / 116.0, 3.0) : (L / 903.3)
    let up = u / (13.0 * L) + luvUn
    let vp = v / (13.0 * L) + luvVn
    let denom = abs(vp) > 1e-12 ? (4.0 * vp) : 1e-12
    let X = Y * (9.0 * up) / denom
    let Z = Y * (12.0 - 3.0 * up - 20.0 * vp) / denom
    let rl = 3.240479 * X - 1.537150 * Y - 0.498535 * Z
    let gl = -0.969256 * X + 1.875992 * Y + 0.041556 * Z
    let bl = 0.055648 * X - 0.204043 * Y + 1.057311 * Z
    return linearOut ? (rl, gl, bl) : (linToSrgb(rl), linToSrgb(gl), linToSrgb(bl))
}

// MARK: - HSV / HLS helpers

@inline(__always)
private func rgbToHsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
    let vmax = max(r, max(g, b)), vmin = min(r, min(g, b)), diff = vmax - vmin
    let s = vmax > 0 ? diff / vmax : 0.0
    var h = 0.0
    if diff > 0 {
        if vmax == r { h = 60.0 * (g - b) / diff }
        else if vmax == g { h = 120.0 + 60.0 * (b - r) / diff }
        else { h = 240.0 + 60.0 * (r - g) / diff }
        if h < 0 { h += 360.0 }
    }
    return (h, s, vmax)
}

@inline(__always)
private func hsvToRgb(_ hDeg: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
    if s <= 0 { return (v, v, v) }
    var h = hDeg.truncatingRemainder(dividingBy: 360.0)
    if h < 0 { h += 360.0 }
    let sector = h / 60.0
    let i = Int(floor(sector))
    let f = sector - Double(i)
    let p = v * (1.0 - s), q = v * (1.0 - s * f), t = v * (1.0 - s * (1.0 - f))
    switch i % 6 {
    case 0: return (v, t, p)
    case 1: return (q, v, p)
    case 2: return (p, v, t)
    case 3: return (p, q, v)
    case 4: return (t, p, v)
    default: return (v, p, q)
    }
}

@inline(__always)
private func rgbToHls(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
    let vmax = max(r, max(g, b)), vmin = min(r, min(g, b))
    let l = (vmax + vmin) * 0.5
    let diff = vmax - vmin
    if diff <= 0 { return (0.0, l, 0.0) }
    let s = l < 0.5 ? diff / (vmax + vmin) : diff / (2.0 - vmax - vmin)
    var h: Double
    if vmax == r { h = 60.0 * (g - b) / diff }
    else if vmax == g { h = 120.0 + 60.0 * (b - r) / diff }
    else { h = 240.0 + 60.0 * (r - g) / diff }
    if h < 0 { h += 360.0 }
    return (h, l, s)
}

@inline(__always)
private func hlsToRgb(_ hDeg: Double, _ l: Double, _ s: Double) -> (Double, Double, Double) {
    if s <= 0 { return (l, l, l) }
    let m2 = l <= 0.5 ? l * (1.0 + s) : (l + s - l * s)
    let m1 = 2.0 * l - m2
    @inline(__always) func chan(_ hue: Double) -> Double {
        var h = hue
        if h > 360.0 { h -= 360.0 } else if h < 0.0 { h += 360.0 }
        if h < 60.0 { return m1 + (m2 - m1) * h / 60.0 }
        if h < 180.0 { return m2 }
        if h < 240.0 { return m1 + (m2 - m1) * (240.0 - h) / 60.0 }
        return m1
    }
    return (chan(hDeg + 120.0), chan(hDeg), chan(hDeg - 120.0))
}

// MARK: - C ABI: sr_cvt_color

private func readCh(_ row: UnsafeRawPointer, _ idx: Int, _ depth: Int32) -> Double {
    switch depth {
    case 0: return Double(row.assumingMemoryBound(to: UInt8.self)[idx])
    case 2: return Double(row.assumingMemoryBound(to: UInt16.self)[idx])
    default: return Double(row.assumingMemoryBound(to: Float.self)[idx])
    }
}

private func writeChU8(_ row: UnsafeMutableRawPointer, _ idx: Int, _ v: Double) {
    row.assumingMemoryBound(to: UInt8.self)[idx] = srSatU8(v)
}

private func writeChU16(_ row: UnsafeMutableRawPointer, _ idx: Int, _ v: Double) {
    row.assumingMemoryBound(to: UInt16.self)[idx] = srSatU16(v)
}

private func writeChF32(_ row: UnsafeMutableRawPointer, _ idx: Int, _ v: Double) {
    row.assumingMemoryBound(to: Float.self)[idx] = Float(v)
}

@_silgen_name("sr_c_bgr2lab_u8")
private func sr_c_bgr2lab_u8(_ src: UnsafePointer<UInt8>, _ sstep: Int, _ dst: UnsafeMutablePointer<UInt8>, _ dstep: Int,
                             _ w: Int32, _ h: Int32, _ scn: Int32, _ dcn: Int32, _ isBGR: Int32, _ linearIn: Int32) -> Int32

@_cdecl("sr_cvt_color")
public func sr_cvt_color(_ srcP: MatP?, _ dstP: MatP?, _ code: Int32) -> Int32 {
    guard let s = mat(srcP), let d = mat(dstP) else { return srFail(SRStatus.badArgument, "cvtColor: null") }
    guard s.rows == d.rows, s.cols == d.cols, s.depth == d.depth,
          (s.depth == 0 || s.depth == 2 || s.depth == 5) else {
        return srFail(SRStatus.badArgument, "cvtColor: unsupported shape or depth")
    }
    let w = s.cols, h = s.rows
    if w == 0 || h == 0 { return SRStatus.ok }
    let sc = Int(s.cn), dc = Int(d.cn)
    guard sc >= 3, dc == 3 || dc == 4 else { return srFail(SRStatus.badArgument, "cvtColor: requires 3/4 channels") }
    if s.depth == 0 && (code == 44 || code == 45 || code == 74 || code == 75), let sp = s.data, let dp = d.data {
        let isBgr: Int32 = (code == 44 || code == 74) ? 1 : 0
        let lin: Int32 = (code == 74 || code == 75) ? 1 : 0
        if sr_c_bgr2lab_u8(sp.assumingMemoryBound(to: UInt8.self), s.step,
                           dp.assumingMemoryBound(to: UInt8.self), d.step,
                           Int32(w), Int32(h), Int32(sc), Int32(dc), isBgr, lin) == 0 {
            return SRStatus.ok
        }
    }
    let isF32 = s.depth == 5
    let maxVal: Double = s.depth == 0 ? 255.0 : (s.depth == 2 ? 65535.0 : 1.0)
    let halfVal: Double = s.depth == 0 ? 128.0 : (s.depth == 2 ? 32768.0 : 0.5)

    for y in 0..<h {
        let sr = UnsafeRawPointer(s.row(y))
        let dr = d.row(y)
        for x in 0..<w {
            let c0 = readCh(sr, x * sc + 0, s.depth)
            let c1 = readCh(sr, x * sc + 1, s.depth)
            let c2 = readCh(sr, x * sc + 2, s.depth)
            let alpha = sc == 4 ? readCh(sr, x * sc + 3, s.depth) : maxVal

            var o0 = 0.0, o1 = 0.0, o2 = 0.0
            switch code {
            // XYZ
            case 32, 33: // BGR2XYZ, RGB2XYZ
                let b = (code == 32 ? c0 : c2) / maxVal, g = c1 / maxVal, r = (code == 32 ? c2 : c0) / maxVal
                o0 = (0.412453 * r + 0.357580 * g + 0.180423 * b) * maxVal
                o1 = (0.212671 * r + 0.715160 * g + 0.072169 * b) * maxVal
                o2 = (0.019334 * r + 0.119193 * g + 0.950227 * b) * maxVal
            case 34, 35: // XYZ2BGR, XYZ2RGB
                let X = c0 / maxVal, Y = c1 / maxVal, Z = c2 / maxVal
                let r = (3.240479 * X - 1.537150 * Y - 0.498535 * Z) * maxVal
                let g = (-0.969256 * X + 1.875992 * Y + 0.041556 * Z) * maxVal
                let b = (0.055648 * X - 0.204043 * Y + 1.057311 * Z) * maxVal
                if code == 34 { (o0, o1, o2) = (b, g, r) } else { (o0, o1, o2) = (r, g, b) }

            // YCrCb (ITU BT.601)
            case 36, 37: // BGR2YCrCb, RGB2YCrCb
                let b = code == 36 ? c0 : c2, g = c1, r = code == 36 ? c2 : c0
                let yy = 0.299 * r + 0.587 * g + 0.114 * b
                o0 = yy; o1 = (r - yy) * 0.713 + halfVal; o2 = (b - yy) * 0.564 + halfVal
            case 38, 39: // YCrCb2BGR, YCrCb2RGB
                let yy = c0, cr = c1 - halfVal, cb = c2 - halfVal
                let r = yy + 1.403 * cr, b = yy + 1.773 * cb, g = yy - 0.714 * cr - 0.344 * cb
                if code == 38 { (o0, o1, o2) = (b, g, r) } else { (o0, o1, o2) = (r, g, b) }

            // YUV (ITU BT.601)
            case 82, 83: // BGR2YUV, RGB2YUV
                let b = code == 82 ? c0 : c2, g = c1, r = code == 82 ? c2 : c0
                let yy = 0.299 * r + 0.587 * g + 0.114 * b
                o0 = yy; o1 = (b - yy) * 0.492 + halfVal; o2 = (r - yy) * 0.877 + halfVal
            case 84, 85: // YUV2BGR, YUV2RGB
                let yy = c0, u = c1 - halfVal, v = c2 - halfVal
                let r = yy + 1.140 * v, b = yy + 2.032 * u, g = yy - 0.395 * u - 0.581 * v
                if code == 84 { (o0, o1, o2) = (b, g, r) } else { (o0, o1, o2) = (r, g, b) }

            // Lab (sRGB and linear)
            case 44, 45, 74, 75: // BGR2Lab, RGB2Lab, LBGR2Lab, LRGB2Lab
                guard !isF32 || s.depth == 5 else { return srFail(SRStatus.unsupported, "Lab: f32/u8 only") }
                let isBgr = (code == 44 || code == 74), lin = (code == 74 || code == 75)
                let (L, a, bb): (Double, Double, Double)
                if s.depth == 0 && !lin {
                    let bIdx = Int(srSatU8(isBgr ? c0 : c2)), gIdx = Int(srSatU8(c1)), rIdx = Int(srSatU8(isBgr ? c2 : c0))
                    (L, a, bb) = rgbToLab(srgbToLinLUT[rIdx], srgbToLinLUT[gIdx], srgbToLinLUT[bIdx], true)
                } else {
                    let b = (isBgr ? c0 : c2) / maxVal, g = c1 / maxVal, r = (isBgr ? c2 : c0) / maxVal
                    (L, a, bb) = rgbToLab(r, g, b, lin)
                }
                if s.depth == 0 { o0 = L * 255.0 / 100.0; o1 = a + 128.0; o2 = bb + 128.0 }
                else { o0 = L; o1 = a; o2 = bb }
            case 56, 57, 78, 79: // Lab2BGR, Lab2RGB, Lab2LBGR, Lab2LRGB
                let isBgr = (code == 56 || code == 78), lin = (code == 78 || code == 79)
                let L = s.depth == 0 ? (c0 * 100.0 / 255.0) : c0
                let a = s.depth == 0 ? (c1 - 128.0) : c1
                let bb = s.depth == 0 ? (c2 - 128.0) : c2
                let (r, g, b) = labToRgb(L, a, bb, lin)
                if isBgr { (o0, o1, o2) = (b * maxVal, g * maxVal, r * maxVal) }
                else { (o0, o1, o2) = (r * maxVal, g * maxVal, b * maxVal) }

            // Luv (sRGB and linear)
            case 50, 51, 76, 77: // BGR2Luv, RGB2Luv, LBGR2Luv, LRGB2Luv
                let isBgr = (code == 50 || code == 76), lin = (code == 76 || code == 77)
                let b = (isBgr ? c0 : c2) / maxVal, g = c1 / maxVal, r = (isBgr ? c2 : c0) / maxVal
                let (L, u, v) = rgbToLuv(r, g, b, lin)
                if s.depth == 0 { o0 = L * 255.0 / 100.0; o1 = (u + 134.0) * 255.0 / 354.0; o2 = (v + 140.0) * 255.0 / 262.0 }
                else { o0 = L; o1 = u; o2 = v }
            case 58, 59, 80, 81: // Luv2BGR, Luv2RGB, Luv2LBGR, Luv2LRGB
                let isBgr = (code == 58 || code == 80), lin = (code == 80 || code == 81)
                let L = s.depth == 0 ? (c0 * 100.0 / 255.0) : c0
                let u = s.depth == 0 ? (c1 * 354.0 / 255.0 - 134.0) : c1
                let v = s.depth == 0 ? (c2 * 262.0 / 255.0 - 140.0) : c2
                let (r, g, b) = luvToRgb(L, u, v, lin)
                if isBgr { (o0, o1, o2) = (b * maxVal, g * maxVal, r * maxVal) }
                else { (o0, o1, o2) = (r * maxVal, g * maxVal, b * maxVal) }

            // HSV & HSV_FULL
            case 40, 41, 66, 67: // BGR2HSV, RGB2HSV, BGR2HSV_FULL, RGB2HSV_FULL
                let isBgr = (code == 40 || code == 66), full = (code == 66 || code == 67)
                let b = isBgr ? c0 : c2, g = c1, r = isBgr ? c2 : c0
                let scale = s.depth == 0 ? 1.0 / 255.0 : 1.0
                let (hDeg, sv, vv) = rgbToHsv(r * scale, g * scale, b * scale)
                if s.depth == 0 { o0 = hDeg * (full ? 255.0 / 360.0 : 0.5); o1 = sv * 255.0; o2 = vv * 255.0 }
                else { o0 = hDeg; o1 = sv; o2 = vv }
            case 54, 55, 70, 71: // HSV2BGR, HSV2RGB, HSV2BGR_FULL, HSV2RGB_FULL
                let isBgr = (code == 54 || code == 70), full = (code == 70 || code == 71)
                let hDeg = s.depth == 0 ? (c0 * (full ? 360.0 / 255.0 : 2.0)) : c0
                let sv = s.depth == 0 ? (c1 / 255.0) : c1
                let vv = s.depth == 0 ? (c2 / 255.0) : c2
                let (r, g, b) = hsvToRgb(hDeg, sv, vv)
                if isBgr { (o0, o1, o2) = (b * maxVal, g * maxVal, r * maxVal) }
                else { (o0, o1, o2) = (r * maxVal, g * maxVal, b * maxVal) }

            // HLS & HLS_FULL
            case 52, 53, 68, 69: // BGR2HLS, RGB2HLS, BGR2HLS_FULL, RGB2HLS_FULL
                let isBgr = (code == 52 || code == 68), full = (code == 68 || code == 69)
                let b = isBgr ? c0 : c2, g = c1, r = isBgr ? c2 : c0
                let scale = s.depth == 0 ? 1.0 / 255.0 : 1.0
                let (hDeg, lv, sv) = rgbToHls(r * scale, g * scale, b * scale)
                if s.depth == 0 { o0 = hDeg * (full ? 255.0 / 360.0 : 0.5); o1 = lv * 255.0; o2 = sv * 255.0 }
                else { o0 = hDeg; o1 = lv; o2 = sv }
            case 60, 61, 72, 73: // HLS2BGR, HLS2RGB, HLS2BGR_FULL, HLS2RGB_FULL
                let isBgr = (code == 60 || code == 72), full = (code == 72 || code == 73)
                let hDeg = s.depth == 0 ? (c0 * (full ? 360.0 / 255.0 : 2.0)) : c0
                let lv = s.depth == 0 ? (c1 / 255.0) : c1
                let sv = s.depth == 0 ? (c2 / 255.0) : c2
                let (r, g, b) = hlsToRgb(hDeg, lv, sv)
                if isBgr { (o0, o1, o2) = (b * maxVal, g * maxVal, r * maxVal) }
                else { (o0, o1, o2) = (r * maxVal, g * maxVal, b * maxVal) }

            default:
                return srFail(SRStatus.unsupported, "cvtColor: unsupported conversion code \(code)")
            }

            if s.depth == 0 {
                writeChU8(dr, x * dc, o0); writeChU8(dr, x * dc + 1, o1); writeChU8(dr, x * dc + 2, o2)
                if dc == 4 { writeChU8(dr, x * dc + 3, alpha) }
            } else if s.depth == 2 {
                writeChU16(dr, x * dc, o0); writeChU16(dr, x * dc + 1, o1); writeChU16(dr, x * dc + 2, o2)
                if dc == 4 { writeChU16(dr, x * dc + 3, alpha) }
            } else {
                writeChF32(dr, x * dc, o0); writeChF32(dr, x * dc + 1, o1); writeChF32(dr, x * dc + 2, o2)
                if dc == 4 { writeChF32(dr, x * dc + 3, alpha) }
            }
        }
    }
    return SRStatus.ok
}
