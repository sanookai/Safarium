// SafariumRaster — cv::erode / cv::dilate with arbitrary kernels (u8 + f32, 1-4 channels).
// Kernel rows are decomposed into runs of consecutive non-zero entries; each run length L is handled with a
// doubling min/max over padded rows (O(log L) per pixel), then folded into the result per kernel row.

import Foundation

private protocol MorphPix: SRPix, Comparable {
    static var lowest: Self { get }
    static var highest: Self { get }
}
extension UInt8: MorphPix {
    static var lowest: UInt8 { 0 }
    static var highest: UInt8 { 255 }
}
extension Float: MorphPix {
    static var lowest: Float { -Float.greatestFiniteMagnitude }
    static var highest: Float { Float.greatestFiniteMagnitude }
}

@inline(__always) private func pick<T: MorphPix>(_ a: T, _ b: T, _ isMax: Bool) -> T {
    isMax ? (a > b ? a : b) : (a < b ? a : b)
}

private func morphOnce<T: MorphPix>(_ src: SRImage, _ dst: SRImage, _ kernel: [UInt8], _ kw: Int, _ kh: Int,
                                    _ ax: Int, _ ay: Int, _ isMax: Bool, _ border: Int32, _ bval: [Double],
                                    _ identityBorder: Bool, _: T.Type) {
    let c = src.channels, w = src.width, h = src.height
    let n = w * c
    let pw = w + kw - 1, ph = h + kh - 1
    let pn = pw * c
    let padded = UnsafeMutablePointer<T>.allocate(capacity: ph * pn)
    defer { padded.deallocate() }
    let ident: T = isMax ? T.lowest : T.highest
    for py in 0..<ph {
        let sy0 = py - ay
        let o = padded + py * pn
        var syi = sy0
        var rowConst = false
        if sy0 < 0 || sy0 >= h {
            if border == SR_BORDER_CONSTANT { rowConst = true } else { syi = srBorderInterp(sy0, h, border) }
        }
        if rowConst {
            for x in 0..<pw { for ch in 0..<c { o[x * c + ch] = identityBorder ? ident : T.fromFloat(Float(bval[ch])) } }
            continue
        }
        let s = src.row(syi).assumingMemoryBound(to: T.self)
        for x in 0..<pw {
            let sx0 = x - ax
            if sx0 >= 0 && sx0 < w {
                for ch in 0..<c { o[x * c + ch] = s[sx0 * c + ch] }
            } else if border == SR_BORDER_CONSTANT {
                for ch in 0..<c { o[x * c + ch] = identityBorder ? ident : T.fromFloat(Float(bval[ch])) }
            } else {
                let sx = srBorderInterp(sx0, w, border)
                for ch in 0..<c { o[x * c + ch] = s[sx * c + ch] }
            }
        }
    }
    // Runs: (row i, start j, length L)
    var runsByLen = [Int: [(Int, Int)]]()
    for i in 0..<kh {
        var j = 0
        while j < kw {
            if kernel[i * kw + j] != 0 {
                var e = j
                while e < kw && kernel[i * kw + e] != 0 { e += 1 }
                runsByLen[e - j, default: []].append((i, j))
                j = e
            } else { j += 1 }
        }
    }
    // result accumulation buffer
    let acc = UnsafeMutablePointer<T>.allocate(capacity: h * n)
    defer { acc.deallocate() }
    for i in 0..<(h * n) { acc[i] = ident }
    let hbuf = UnsafeMutablePointer<T>.allocate(capacity: ph * pn)
    defer { hbuf.deallocate() }
    let lvl = UnsafeMutablePointer<T>.allocate(capacity: pn)
    let lvl2 = UnsafeMutablePointer<T>.allocate(capacity: pn)
    defer { lvl.deallocate(); lvl2.deallocate() }
    for (len, runs) in runsByLen.sorted(by: { $0.key < $1.key }) {
        // H_len[row][i] = op over padded[row][i ... i + (len-1)*c] (valid for i + (len-1)*c < pn)
        var p = 1
        while p * 2 <= len { p *= 2 }
        for r in 0..<ph {
            let src0 = padded + r * pn
            var cur = lvl, nxt = lvl2
            for i in 0..<pn { cur[i] = src0[i] }
            var span = 1
            while span < p {
                let valid = pn - span * c
                for i in 0..<valid { nxt[i] = pick(cur[i], cur[i + span * c], isMax) }
                for i in max(0, valid)..<pn { nxt[i] = cur[i] }
                swap(&cur, &nxt)
                span *= 2
            }
            let out = hbuf + r * pn
            let rem = (len - p) * c
            if rem == 0 {
                for i in 0..<pn { out[i] = cur[i] }
            } else {
                let valid = pn - rem
                for i in 0..<valid { out[i] = pick(cur[i], cur[i + rem], isMax) }
                for i in max(0, valid)..<pn { out[i] = cur[i] }
            }
        }
        for (ki, kj) in runs {
            for y in 0..<h {
                let hr = hbuf + (y + ki) * pn + kj * c
                let a = acc + y * n
                for i in 0..<n { a[i] = pick(a[i], hr[i], isMax) }
            }
        }
    }
    for y in 0..<h {
        let o = dst.row(y).assumingMemoryBound(to: T.self)
        let a = acc + y * n
        for i in 0..<n { o[i] = a[i] }
    }
}

@_silgen_name("sr_c_morph_u8")
private func sr_c_morph_u8(_ src: UnsafePointer<UInt8>, _ sstep: Int, _ dst: UnsafeMutablePointer<UInt8>, _ dstep: Int,
                           _ w: Int32, _ h: Int32, _ cn: Int32,
                           _ kernel: UnsafePointer<UInt8>, _ kw: Int32, _ kh: Int32, _ ax: Int32, _ ay: Int32,
                           _ isMax: Int32, _ iterations: Int32, _ border: Int32, _ bval: UnsafePointer<Double>,
                           _ identityBorder: Int32) -> Int32

@_silgen_name("sr_c_morph_f32")
private func sr_c_morph_f32(_ src: UnsafePointer<Float>, _ sstep: Int, _ dst: UnsafeMutablePointer<Float>, _ dstep: Int,
                            _ w: Int32, _ h: Int32, _ cn: Int32,
                            _ kernel: UnsafePointer<UInt8>, _ kw: Int32, _ kh: Int32, _ ax: Int32, _ ay: Int32,
                            _ isMax: Int32, _ iterations: Int32, _ border: Int32, _ bval: UnsafePointer<Double>,
                            _ identityBorder: Int32) -> Int32

/// op: 0 = erode (min), 1 = dilate (max). borderValue == DBL_MAX in channel 0 means OpenCV's default (neutral) border.
@_cdecl("sr_morph")
public func sr_morph(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                     _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
                     _ kernel: UnsafePointer<UInt8>?, _ kw: Int32, _ kh: Int32, _ anchorX: Int32, _ anchorY: Int32,
                     _ op: Int32, _ iterations: Int32, _ border: Int32, _ borderValue: UnsafePointer<Double>?) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep), let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          src.channels == dst.channels, src.depth == dst.depth, src.width == dst.width, src.height == dst.height,
          let kernel, kw > 0, kh > 0, iterations >= 0 else {
        return srFail(SRStatus.badArgument, "morph: bad arguments")
    }
    guard src.depth == .u8 || src.depth == .f32 else {
        return srFail(SRStatus.unsupported, "morph: only u8 and f32 images are supported")
    }
    guard [SR_BORDER_CONSTANT, SR_BORDER_REPLICATE, SR_BORDER_REFLECT, SR_BORDER_WRAP, SR_BORDER_REFLECT_101].contains(border) else {
        return srFail(SRStatus.unsupported, "morph: unsupported border type")
    }
    if src.width == 0 || src.height == 0 { return SRStatus.ok }
    let ax = anchorX < 0 ? kw / 2 : anchorX, ay = anchorY < 0 ? kh / 2 : anchorY
    guard ax < kw, ay < kh else { return srFail(SRStatus.badArgument, "morph: anchor outside kernel") }
    let bvAll = borderValue.map { Array(UnsafeBufferPointer(start: $0, count: 4)) } ?? [Double.greatestFiniteMagnitude, 0, 0, 0]
    let identity: Int32 = (border == SR_BORDER_CONSTANT && bvAll[0] == Double.greatestFiniteMagnitude) ? 1 : 0
    let isMax: Int32 = op == 1 ? 1 : 0
    let rc: Int32 = bvAll.withUnsafeBufferPointer { bp in
        if src.depth == .u8 {
            return sr_c_morph_u8(src.data.assumingMemoryBound(to: UInt8.self), src.stride,
                                 dst.data.assumingMemoryBound(to: UInt8.self), dst.stride,
                                 sw, sh, sc, kernel, kw, kh, ax, ay, isMax, iterations, border, bp.baseAddress!, identity)
        } else {
            return sr_c_morph_f32(src.data.assumingMemoryBound(to: Float.self), src.stride,
                                  dst.data.assumingMemoryBound(to: Float.self), dst.stride,
                                  sw, sh, sc, kernel, kw, kh, ax, ay, isMax, iterations, border, bp.baseAddress!, identity)
        }
    }
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.internalError, "morph failed")
}
