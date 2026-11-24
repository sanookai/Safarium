// SafariumRaster — cv::distanceTransform (chamfer 3x3 / 5x5 and exact Euclidean "PRECISE"), u8 binary -> f32.
// Chamfer metrics are OpenCV's (L2 3x3: a = 0.955, b = 1.3693; L2 5x5: a = 1, b = 1.4, c = 2.1969).

import Foundation

private func chamfer(_ src: SRImage, _ dst: SRImage, _ a: Float, _ b: Float, _ c: Float, _ mask5: Bool) {
    let w = src.width, h = src.height
    let B = mask5 ? 2 : 1
    let pw = w + 2 * B, ph = h + 2 * B
    let inf: Float = 1e6
    let t = UnsafeMutablePointer<Float>.allocate(capacity: pw * ph)
    t.initialize(repeating: inf, count: pw * ph)
    defer { t.deallocate() }
    // forward
    for y in 0..<h {
        let s = src.row(y).assumingMemoryBound(to: UInt8.self)
        let row = t + (y + B) * pw + B
        for x in 0..<w {
            if s[x] == 0 { row[x] = 0; continue }
            var m = row[x - pw - 1] + b
            m = min(m, row[x - pw] + a)
            m = min(m, row[x - pw + 1] + b)
            m = min(m, row[x - 1] + a)
            if mask5 {
                m = min(m, row[x - 2 * pw - 1] + c)
                m = min(m, row[x - 2 * pw + 1] + c)
                m = min(m, row[x - pw - 2] + c)
                m = min(m, row[x - pw + 2] + c)
            }
            row[x] = m
        }
    }
    // backward
    for y in stride(from: h - 1, through: 0, by: -1) {
        let row = t + (y + B) * pw + B
        let d = dst.row(y).assumingMemoryBound(to: Float.self)
        for x in stride(from: w - 1, through: 0, by: -1) {
            var m = row[x]
            if m > a {
                m = min(m, row[x + pw + 1] + b)
                m = min(m, row[x + pw] + a)
                m = min(m, row[x + pw - 1] + b)
                m = min(m, row[x + 1] + a)
                if mask5 {
                    m = min(m, row[x + 2 * pw + 1] + c)
                    m = min(m, row[x + 2 * pw - 1] + c)
                    m = min(m, row[x + pw + 2] + c)
                    m = min(m, row[x + pw - 2] + c)
                }
                row[x] = m
            }
            d[x] = m
        }
    }
}

/// Exact Euclidean distance (Felzenszwalb & Huttenlocher lower envelope), result sqrt'd to f32.
private func exactEuclid(_ src: SRImage, _ dst: SRImage) {
    let w = src.width, h = src.height
    let big = 1e12
    var g = [Double](repeating: big, count: w * h)
    for x in 0..<w {
        var d = big
        for y in 0..<h {
            d = src.row(y).load(fromByteOffset: x, as: UInt8.self) == 0 ? 0 : min(big, d + 1)
            g[y * w + x] = d
        }
        d = big
        for y in stride(from: h - 1, through: 0, by: -1) {
            d = src.row(y).load(fromByteOffset: x, as: UInt8.self) == 0 ? 0 : min(big, d + 1)
            if d < g[y * w + x] { g[y * w + x] = d }
        }
    }
    var f = [Double](repeating: 0, count: w)
    var v = [Int](repeating: 0, count: w)
    var z = [Double](repeating: 0, count: w + 1)
    for y in 0..<h {
        for x in 0..<w { let q = g[y * w + x]; f[x] = q * q }
        var k = 0
        v[0] = 0; z[0] = -Double.infinity; z[1] = Double.infinity
        if w > 1 {
            for q in 1..<w {
                var s = 0.0
                while true {
                    let p = v[k]
                    s = ((f[q] + Double(q * q)) - (f[p] + Double(p * p))) / Double(2 * q - 2 * p)
                    if s <= z[k] && k > 0 { k -= 1 } else { break }
                }
                if s <= z[k] { k = 0; v[0] = q; z[0] = -Double.infinity; z[1] = Double.infinity; continue }
                k += 1
                v[k] = q; z[k] = s; z[k + 1] = Double.infinity
            }
        }
        k = 0
        let d = dst.row(y).assumingMemoryBound(to: Float.self)
        for q in 0..<w {
            while z[k + 1] < Double(q) { k += 1 }
            let p = v[k]
            let dd = Double(q - p)
            let val = (dd * dd + f[p]).squareRoot()
            d[q] = Float(min(val, 1e6))
        }
    }
}

/// distType: 1 = L1, 2 = L2, 3 = C. maskSize: 3, 5, or 0 (PRECISE, exact Euclidean for any distType == L2).
@_cdecl("sr_distance_transform")
public func sr_distance_transform(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                                  _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
                                  _ distType: Int32, _ maskSize: Int32) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep), let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          src.depth == .u8, src.channels == 1, dst.depth == .f32, dst.channels == 1,
          src.width == dst.width, src.height == dst.height, src.width > 0, src.height > 0 else {
        return srFail(SRStatus.badArgument, "distanceTransform: need a 1-channel u8 source and f32 destination of equal size")
    }
    switch (distType, maskSize) {
    case (_, 0):
        guard distType == 2 else { return srFail(SRStatus.unsupported, "distanceTransform: PRECISE only for DIST_L2") }
        exactEuclid(src, dst)
    case (2, 3): chamfer(src, dst, 0.955, 1.3693, 0, false)
    case (1, 3): chamfer(src, dst, 1, 2, 0, false)
    case (3, 3): chamfer(src, dst, 1, 1, 0, false)
    case (2, 5): chamfer(src, dst, 1, 1.4, 2.1969, true)
    case (1, 5): chamfer(src, dst, 1, 2, 3, true)
    case (3, 5): chamfer(src, dst, 1, 1, 2, true)
    default: return srFail(SRStatus.unsupported, "distanceTransform: unsupported distance/mask combination")
    }
    return SRStatus.ok
}
