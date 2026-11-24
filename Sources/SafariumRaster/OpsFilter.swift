// SafariumRaster — separable filtering (cv::sepFilter2D / GaussianBlur core) and cv::pyrDown.
// Correlation semantics as OpenCV filter2D: dst(x,y) = sum_j kx[j] * ky[i] * src(x + j - ax, y + i - ay).
// Float arithmetic with 32-wide register blocking; u8 results are rounded half-up and saturated.

import Foundation
import SafariumRasterC

private typealias V8 = SIMD8<Float>

@inline(__always) private func load8(_ p: UnsafePointer<Float>) -> V8 {
    UnsafeRawPointer(p).loadUnaligned(as: V8.self)
}

@inline(__always) private func store8(_ p: UnsafeMutablePointer<Float>, _ v: V8) {
    UnsafeMutableRawPointer(p).storeBytes(of: v, as: V8.self)
}

/// out[i] = sum_j k[j] * in[i + j*step] for i in 0..<nPadded (nPadded multiple of 32; `in` readable past the end).
@inline(__always)
private func tapsRow(_ input: UnsafePointer<Float>, _ step: Int, _ k: UnsafePointer<Float>, _ nk: Int,
                     _ out: UnsafeMutablePointer<Float>, _ nPadded: Int) {
    var i = 0
    while i < nPadded {
        var a0 = V8(repeating: 0), a1 = V8(repeating: 0), a2 = V8(repeating: 0), a3 = V8(repeating: 0)
        var p = input + i
        for j in 0..<nk {
            let kv = V8(repeating: k[j])
            a0 += kv * load8(p); a1 += kv * load8(p + 8); a2 += kv * load8(p + 16); a3 += kv * load8(p + 24)
            p += step
        }
        store8(out + i, a0); store8(out + i + 8, a1); store8(out + i + 16, a2); store8(out + i + 24, a3)
        i += 32
    }
}

/// Same but each tap reads from its own row pointer.
@inline(__always)
func srRowsCombine(_ rows: UnsafePointer<UnsafePointer<Float>>, _ k: UnsafePointer<Float>, _ nk: Int,
                         _ out: UnsafeMutablePointer<Float>, _ nPadded: Int) {
    var i = 0
    while i < nPadded {
        var a0 = V8(repeating: 0), a1 = V8(repeating: 0), a2 = V8(repeating: 0), a3 = V8(repeating: 0)
        for j in 0..<nk {
            let kv = V8(repeating: k[j])
            let p = rows[j] + i
            a0 += kv * load8(p); a1 += kv * load8(p + 8); a2 += kv * load8(p + 16); a3 += kv * load8(p + 24)
        }
        store8(out + i, a0); store8(out + i + 8, a1); store8(out + i + 16, a2); store8(out + i + 24, a3)
        i += 32
    }
}

private func sepFilterImpl<S: SRPix, D: SRPix>(_ src: SRImage, _ dst: SRImage, _ kx: [Float], _ ky: [Float],
                                               _ ax: Int, _ ay: Int, _ delta: Float, _ border: Int32,
                                               _ bval: [Double], _: S.Type, _: D.Type) {
    let c = src.channels, w = src.width, h = src.height
    let n = w * c
    let nP = (n + 31) & ~31
    let nkx = kx.count, nky = ky.count
    let padLen = (w + nkx - 1) * c + 64
    let pad = UnsafeMutablePointer<Float>.allocate(capacity: padLen)
    pad.initialize(repeating: 0, count: padLen)
    // Streaming vertical pass: horizontally filtered rows live in a small ring keyed by source row (peak RAM
    // O(kernel height) instead of a full float copy of the image).
    let slots = max(2 * nky, 4)
    let ring = UnsafeMutablePointer<Float>.allocate(capacity: slots * nP + 64)
    ring.initialize(repeating: 0, count: slots * nP + 64)
    var keys = [Int](repeating: -1, count: slots)
    let constRow = UnsafeMutablePointer<Float>.allocate(capacity: nP + 64)
    constRow.initialize(repeating: 0, count: nP + 64)
    let outRow = UnsafeMutablePointer<Float>.allocate(capacity: nP + 64)
    defer { pad.deallocate(); ring.deallocate(); constRow.deallocate(); outRow.deallocate() }
    let sumKx = kx.reduce(0, +)
    for x in 0..<w { for ch in 0..<c { constRow[x * c + ch] = Float(bval[ch]) * sumKx } }
    let left = ax, right = nkx - 1 - ax

    kx.withUnsafeBufferPointer { kxp in
    ky.withUnsafeBufferPointer { kyp in
        func hRow(_ y: Int) -> UnsafePointer<Float> {
            let slot = y % slots
            let dstRow = ring + slot * nP
            if keys[slot] == y { return UnsafePointer(dstRow) }
            let s = src.row(y).assumingMemoryBound(to: S.self)
            S.toFloatRow(UnsafePointer(s), pad + left * c, n)
            for q in 0..<left {
                let sx = srBorderInterp(q - left, w, border)
                for ch in 0..<c { pad[q * c + ch] = sx < 0 ? Float(bval[ch]) : s[sx * c + ch].asFloat }
            }
            for q in 0..<max(0, right) {
                let sx = srBorderInterp(w + q, w, border)
                for ch in 0..<c { pad[(left + w + q) * c + ch] = sx < 0 ? Float(bval[ch]) : s[sx * c + ch].asFloat }
            }
            tapsRow(pad, c, kxp.baseAddress!, nkx, dstRow, nP)
            keys[slot] = y
            return UnsafePointer(dstRow)
        }
        var rowPtrs = [UnsafePointer<Float>](repeating: UnsafePointer(constRow), count: nky)
        for y in 0..<h {
            for j in 0..<nky {
                let sy = srBorderInterp(y + j - ay, h, border)
                rowPtrs[j] = sy < 0 ? UnsafePointer(constRow) : hRow(sy)
            }
            rowPtrs.withUnsafeBufferPointer { rp in
                srRowsCombine(rp.baseAddress!, kyp.baseAddress!, nky, outRow, nP)
            }
            D.storeRow(outRow, dst.row(y).assumingMemoryBound(to: D.self), n, delta)
        }
    }}
}

@_cdecl("sr_sep_filter")
public func sr_sep_filter(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                          _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
                          _ kx: UnsafePointer<Float>?, _ nkx: Int32, _ ky: UnsafePointer<Float>?, _ nky: Int32,
                          _ anchorX: Int32, _ anchorY: Int32, _ delta: Double, _ border: Int32,
                          _ borderValue: UnsafePointer<Double>?) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep), let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          src.channels == dst.channels, src.width == dst.width, src.height == dst.height,
          let kx, let ky, nkx > 0, nky > 0, src.width > 0, src.height > 0 else {
        return srFail(SRStatus.badArgument, "sepFilter2D: bad arguments")
    }
    let okDepth: (SRDepth) -> Bool = { $0 == .u8 || $0 == .u16 || $0 == .f32 }
    guard okDepth(src.depth) && okDepth(dst.depth) else {
        return srFail(SRStatus.unsupported, "sepFilter2D: only u8, u16 and f32 images are supported")
    }
    guard [SR_BORDER_CONSTANT, SR_BORDER_REPLICATE, SR_BORDER_REFLECT, SR_BORDER_WRAP, SR_BORDER_REFLECT_101].contains(border) else {
        return srFail(SRStatus.unsupported, "sepFilter2D: unsupported border type")
    }
    let ax = anchorX < 0 ? Int(nkx) / 2 : Int(anchorX), ay = anchorY < 0 ? Int(nky) / 2 : Int(anchorY)
    guard ax < Int(nkx), ay < Int(nky) else { return srFail(SRStatus.badArgument, "sepFilter2D: anchor outside kernel") }
    let kxa = Array(UnsafeBufferPointer(start: kx, count: Int(nkx)))
    let kya = Array(UnsafeBufferPointer(start: ky, count: Int(nky)))
    let bv = borderValue.map { Array(UnsafeBufferPointer(start: $0, count: 4)) } ?? [0, 0, 0, 0]
    let df = Float(delta)
    @inline(__always) func run<S: SRPix>(_ st: S.Type) {
        switch dst.depth {
        case .u8: sepFilterImpl(src, dst, kxa, kya, ax, ay, df, border, bv, st, UInt8.self)
        case .u16: sepFilterImpl(src, dst, kxa, kya, ax, ay, df, border, bv, st, UInt16.self)
        default: sepFilterImpl(src, dst, kxa, kya, ax, ay, df, border, bv, st, Float.self)
        }
    }
    switch src.depth {
    case .u8: run(UInt8.self)
    case .u16: run(UInt16.self)
    default: run(Float.self)
    }
    return SRStatus.ok
}

// MARK: - pyrDown

private func pyrDownImpl<T: SRPix>(_ src: SRImage, _ dst: SRImage, _ border: Int32, _: T.Type) {
    let c = src.channels, w = src.width, h = src.height
    let dw = dst.width, dh = dst.height
    let n = dw * c
    let nP = (n + 31) & ~31
    // padded float source row: pad[q] <-> source x = q - 2 (borders mapped once per row)
    let padLen = (w + 4) * c + 64
    let pad = UnsafeMutablePointer<Float>.allocate(capacity: padLen)
    pad.initialize(repeating: 0, count: padLen)
    let slots = 8   // ring of horizontally filtered + decimated rows (peak RAM independent of image height)
    let ring = UnsafeMutablePointer<Float>.allocate(capacity: slots * nP + 64)
    ring.initialize(repeating: 0, count: slots * nP + 64)
    let acc = UnsafeMutablePointer<Float>.allocate(capacity: nP + 64)
    acc.initialize(repeating: 0, count: nP + 64)
    defer { pad.deallocate(); ring.deallocate(); acc.deallocate() }
    var keys = [Int](repeating: -1, count: slots)
    func hrow(_ y: Int) -> UnsafePointer<Float> {
        let slot = y & (slots - 1)
        let o = ring + slot * nP
        if keys[slot] == y { return UnsafePointer(o) }
        let s = src.row(y).assumingMemoryBound(to: T.self)
        T.toFloatRow(UnsafePointer(s), pad + 2 * c, w * c)
        for q in 0..<2 {
            let l = srBorderInterp(q - 2, w, border), r = srBorderInterp(w + q, w, border)
            for ch in 0..<c {
                pad[q * c + ch] = l < 0 ? 0 : pad[(l + 2) * c + ch]
                pad[(w + 2 + q) * c + ch] = r < 0 ? 0 : pad[(r + 2) * c + ch]
            }
        }
        // out[x*c+ch] = 1*p[2x-2] + 4*p[2x-1] + 6*p[2x] + 4*p[2x+1] + 1*p[2x+2]  (pad index = source x + 2)
        if c == 1 {
            for x in 0..<dw {
                let p = pad + 2 * x
                o[x] = p[0] + 4 * p[1] + 6 * p[2] + 4 * p[3] + p[4]
            }
        } else {
            let k4 = SIMD4<Float>(repeating: 4), k6 = SIMD4<Float>(repeating: 6)
            for x in 0..<dw {
                let p = pad + 2 * x * c
                @inline(__always) func ld(_ j: Int) -> SIMD4<Float> {
                    UnsafeRawPointer(p + j * c).loadUnaligned(as: SIMD4<Float>.self)
                }
                let v = ld(0) + k4 * ld(1) + k6 * ld(2) + k4 * ld(3) + ld(4)
                if c == 4 { UnsafeMutableRawPointer(o + x * 4).storeBytes(of: v, as: SIMD4<Float>.self) }
                else if c == 3 { o[x * 3] = v[0]; o[x * 3 + 1] = v[1]; o[x * 3 + 2] = v[2] }
                else { for ch in 0..<c { o[x * c + ch] = v[ch] } }
            }
        }
        keys[slot] = y
        return UnsafePointer(o)
    }
    var rows = [UnsafePointer<Float>](repeating: UnsafePointer(acc), count: 5)
    let wts: [Float] = [1.0 / 256, 4.0 / 256, 6.0 / 256, 4.0 / 256, 1.0 / 256]
    wts.withUnsafeBufferPointer { wp in
        for y in 0..<dh {
            for j in 0..<5 {
                let r = srBorderInterp(2 * y + j - 2, h, border)
                rows[j] = hrow(max(r, 0))
            }
            rows.withUnsafeBufferPointer { rp in srRowsCombine(rp.baseAddress!, wp.baseAddress!, 5, acc, nP) }
            T.storeRow(acc, dst.row(y).assumingMemoryBound(to: T.self), n, 0)
        }
    }
}

@_cdecl("sr_pyr_down")
public func sr_pyr_down(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                        _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
                        _ border: Int32) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep), let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          src.channels == dst.channels, src.depth == dst.depth, src.width > 0, src.height > 0,
          dst.width == (src.width + 1) / 2, dst.height == (src.height + 1) / 2 else {
        return srFail(SRStatus.badArgument, "pyrDown: bad arguments")
    }
    guard src.depth == .u8 || src.depth == .u16 || src.depth == .f32 else {
        return srFail(SRStatus.unsupported, "pyrDown: only u8, u16 and f32 images are supported")
    }
    switch src.depth {
    case .u8: pyrDownImpl(src, dst, border, UInt8.self)
    case .u16: pyrDownImpl(src, dst, border, UInt16.self)
    default: pyrDownImpl(src, dst, border, Float.self)
    }
    return SRStatus.ok
}

// MARK: - Phase 3: Full-depth Filters, Sobel/Scharr/Laplacian, Box, Canny, Bilateral, Median, Integral, pyrUp, CLAHE, ColorMap

@inline(__always)
private func fReadD(_ row: UnsafeRawPointer, _ idx: Int, _ depth: Int32) -> Double {
    switch depth {
    case 0: return Double(row.assumingMemoryBound(to: UInt8.self)[idx])
    case 1: return Double(row.assumingMemoryBound(to: Int8.self)[idx])
    case 2: return Double(row.assumingMemoryBound(to: UInt16.self)[idx])
    case 3: return Double(row.assumingMemoryBound(to: Int16.self)[idx])
    case 4: return Double(row.assumingMemoryBound(to: Int32.self)[idx])
    case 5: return Double(row.assumingMemoryBound(to: Float.self)[idx])
    default: return row.assumingMemoryBound(to: Double.self)[idx]
    }
}

@inline(__always)
private func fWriteD(_ row: UnsafeMutableRawPointer, _ idx: Int, _ depth: Int32, _ v: Double) {
    switch depth {
    case 0: row.assumingMemoryBound(to: UInt8.self)[idx] = srSatU8(v)
    case 1: row.assumingMemoryBound(to: Int8.self)[idx] = Int8(max(-128, min(127, Int(v.rounded(.toNearestOrEven)))))
    case 2: row.assumingMemoryBound(to: UInt16.self)[idx] = srSatU16(v)
    case 3: row.assumingMemoryBound(to: Int16.self)[idx] = Int16(max(-32768, min(32767, Int(v.rounded(.toNearestOrEven)))))
    case 4: row.assumingMemoryBound(to: Int32.self)[idx] = Int32(max(-2147483648, min(2147483647, Int(v.rounded(.toNearestOrEven)))))
    case 5: row.assumingMemoryBound(to: Float.self)[idx] = Float(v)
    default: row.assumingMemoryBound(to: Double.self)[idx] = v
    }
}

private func sepFilter2Core(_ s: CoreMat, _ d: CoreMat, _ kx: [Double], _ ky: [Double],
                            _ ax0: Int32, _ ay0: Int32, _ delta: Double, _ border: Int32) {
    let w = s.cols, h = s.rows, c = Int(s.cn)
    if w == 0 || h == 0 { return }
    let kw = kx.count, kh = ky.count
    let ax = ax0 < 0 ? kw / 2 : Int(ax0)
    let ay = ay0 < 0 ? kh / 2 : Int(ay0)
    let n = w * c
    let tmp = UnsafeMutablePointer<Double>.allocate(capacity: h * n)
    defer { tmp.deallocate() }
    let rowD = UnsafeMutablePointer<Double>.allocate(capacity: n)
    defer { rowD.deallocate() }

    for y in 0..<h {
        let sRow = UnsafeRawPointer(s.row(y))
        for i in 0..<n { rowD[i] = fReadD(sRow, i, s.depth) }
        let tRow = tmp + y * n
        for x in 0..<w {
            for ch in 0..<c {
                var acc = 0.0
                for k in 0..<kw {
                    let rx = srBorderInterp(x + k - ax, w, border)
                    let sv = rx < 0 ? 0.0 : rowD[rx * c + ch]
                    acc += kx[k] * sv
                }
                tRow[x * c + ch] = acc
            }
        }
    }

    for y in 0..<h {
        let dRow = d.row(y)
        for i in 0..<n { rowD[i] = delta }
        for k in 0..<kh {
            let ry = srBorderInterp(y + k - ay, h, border)
            if ry >= 0 {
                let wk = ky[k]
                let tr = tmp + ry * n
                for i in 0..<n { rowD[i] += wk * tr[i] }
            }
        }
        for i in 0..<n { fWriteD(dRow, i, d.depth, rowD[i]) }
    }
}

@_cdecl("sr_sep_filter2")
public func sr_sep_filter2(_ srcP: MatP?, _ dstP: MatP?, _ kxP: UnsafePointer<Double>?, _ kw: Int32,
                           _ kyP: UnsafePointer<Double>?, _ kh: Int32, _ ax: Int32, _ ay: Int32,
                           _ delta: Double, _ border: Int32) -> Int32 {
    guard let s = mat(srcP), let d = mat(dstP), let kxP, let kyP, kw > 0, kh > 0 else {
        return srFail(SRStatus.badArgument, "sepFilter2D: null")
    }
    guard s.rows == d.rows, s.cols == d.cols, s.cn == d.cn else {
        return srFail(SRStatus.badArgument, "sepFilter2D: shape/channel mismatch")
    }
    let kx = (0..<Int(kw)).map { kxP[$0] }, ky = (0..<Int(kh)).map { kyP[$0] }
    sepFilter2Core(s, d, kx, ky, ax, ay, delta, border)
    return SRStatus.ok
}

@_cdecl("sr_filter2d")
public func sr_filter2d(_ srcP: MatP?, _ dstP: MatP?, _ kerP: UnsafePointer<Double>?, _ kw0: Int32, _ kh0: Int32,
                        _ ax0: Int32, _ ay0: Int32, _ delta: Double, _ border: Int32) -> Int32 {
    guard let s = mat(srcP), let d = mat(dstP), let kerP, kw0 > 0, kh0 > 0 else {
        return srFail(SRStatus.badArgument, "filter2D: null")
    }
    guard s.rows == d.rows, s.cols == d.cols, s.cn == d.cn else {
        return srFail(SRStatus.badArgument, "filter2D: shape/channel mismatch")
    }
    let w = s.cols, h = s.rows, c = Int(s.cn), kw = Int(kw0), kh = Int(kh0)
    if w == 0 || h == 0 { return SRStatus.ok }
    let ax = ax0 < 0 ? kw / 2 : Int(ax0)
    let ay = ay0 < 0 ? kh / 2 : Int(ay0)
    let n = w * c
    let sBuf = UnsafeMutablePointer<Double>.allocate(capacity: h * n)
    defer { sBuf.deallocate() }
    for y in 0..<h {
        let sr = UnsafeRawPointer(s.row(y))
        for i in 0..<n { sBuf[y * n + i] = fReadD(sr, i, s.depth) }
    }
    for y in 0..<h {
        let dr = d.row(y)
        for x in 0..<w {
            for ch in 0..<c {
                var acc = delta
                for ky in 0..<kh {
                    let ry = srBorderInterp(y + ky - ay, h, border)
                    if ry < 0 { continue }
                    let sRow = sBuf + ry * n
                    let kRow = kerP + ky * kw
                    for kx in 0..<kw {
                        let rx = srBorderInterp(x + kx - ax, w, border)
                        if rx >= 0 { acc += kRow[kx] * sRow[rx * c + ch] }
                    }
                }
                fWriteD(dr, x * c + ch, d.depth, acc)
            }
        }
    }
    return SRStatus.ok
}

@_cdecl("sr_box_filter")
public func sr_box_filter(_ srcP: MatP?, _ dstP: MatP?, _ kx: Int32, _ ky: Int32,
                          _ ax0: Int32, _ ay0: Int32, _ normalize: Int32, _ border: Int32) -> Int32 {
    guard let s = mat(srcP), let d = mat(dstP), kx > 0, ky > 0, s.rows == d.rows, s.cols == d.cols, s.cn == d.cn else {
        return srFail(SRStatus.badArgument, "boxFilter: bad arguments")
    }
    let w = s.cols, h = s.rows, c = Int(s.cn), kw = Int(kx), kh = Int(ky)
    if w == 0 || h == 0 { return SRStatus.ok }
    let ax = ax0 < 0 ? kw / 2 : Int(ax0)
    let ay = ay0 < 0 ? kh / 2 : Int(ay0)
    let scale = normalize != 0 ? (1.0 / Double(kw * kh)) : 1.0
    let n = w * c
    let tmp = UnsafeMutablePointer<Double>.allocate(capacity: h * n)
    let rowD = UnsafeMutablePointer<Double>.allocate(capacity: n)
    defer { tmp.deallocate(); rowD.deallocate() }

    // O(1) horizontal sliding window (exact integer/double sum)
    for y in 0..<h {
        let sr = UnsafeRawPointer(s.row(y))
        for i in 0..<n { rowD[i] = fReadD(sr, i, s.depth) }
        let tr = tmp + y * n
        for ch in 0..<c {
            var acc = 0.0
            for k in 0..<kw {
                let rx = srBorderInterp(k - ax, w, border)
                if rx >= 0 { acc += rowD[rx * c + ch] }
            }
            tr[ch] = acc
            for x in 1..<w {
                let rxOut = srBorderInterp(x - 1 - ax, w, border)
                let rxIn = srBorderInterp(x + kw - 1 - ax, w, border)
                if rxOut >= 0 { acc -= rowD[rxOut * c + ch] }
                if rxIn >= 0 { acc += rowD[rxIn * c + ch] }
                tr[x * c + ch] = acc
            }
        }
    }
    // O(1) vertical sliding window
    let colAcc = UnsafeMutablePointer<Double>.allocate(capacity: n)
    defer { colAcc.deallocate() }
    colAcc.initialize(repeating: 0.0, count: n)
    for k in 0..<kh {
        let ry = srBorderInterp(k - ay, h, border)
        if ry >= 0 { let tr = tmp + ry * n; for i in 0..<n { colAcc[i] += tr[i] } }
    }
    for y in 0..<h {
        let dr = d.row(y)
        for i in 0..<n { fWriteD(dr, i, d.depth, colAcc[i] * scale) }
        if y + 1 < h {
            let ryOut = srBorderInterp(y - ay, h, border)
            let ryIn = srBorderInterp(y + kh - ay, h, border)
            if ryOut >= 0 { let tO = tmp + ryOut * n; for i in 0..<n { colAcc[i] -= tO[i] } }
            if ryIn >= 0 { let tI = tmp + ryIn * n; for i in 0..<n { colAcc[i] += tI[i] } }
        }
    }
    return SRStatus.ok
}

private func derivKernel1D(_ order: Int, _ ksize: Int) -> [Double] {
    if ksize == 1 {
        if order == 0 { return [1.0] }
        if order == 1 { return [-1.0, 0.0, 1.0] }
        return [1.0, -2.0, 1.0]
    }
    var ker = [1.0]
    let smoothSteps = max(0, ksize - 1 - order)
    for _ in 0..<smoothSteps {
        var nxt = [Double](repeating: 0.0, count: ker.count + 1)
        for i in 0..<ker.count { nxt[i] += ker[i]; nxt[i + 1] += ker[i] }
        ker = nxt
    }
    for _ in 0..<order {
        var nxt = [Double](repeating: 0.0, count: ker.count + 1)
        for i in 0..<ker.count { nxt[i] -= ker[i]; nxt[i + 1] += ker[i] }
        ker = nxt
    }
    return ker
}

@_cdecl("sr_sobel")
public func sr_sobel(_ srcP: MatP?, _ dstP: MatP?, _ dx: Int32, _ dy: Int32, _ ksize: Int32,
                     _ scale: Double, _ delta: Double, _ border: Int32) -> Int32 {
    guard let s = mat(srcP), let d = mat(dstP), s.rows == d.rows, s.cols == d.cols, s.cn == d.cn else {
        return srFail(SRStatus.badArgument, "Sobel: bad arguments")
    }
    if ksize < 0 {
        return sr_scharr(srcP, dstP, dx, dy, scale, delta, border)
    }
    let ks = Int(ksize)
    guard ks == 1 || ks == 3 || ks == 5 || ks == 7, dx >= 0, dy >= 0, dx + dy >= 1 else {
        return srFail(SRStatus.badArgument, "Sobel: invalid ksize or derivative order")
    }
    var kx = derivKernel1D(Int(dx), ks)
    let ky = derivKernel1D(Int(dy), ks)
    if scale != 1.0 { kx = kx.map { $0 * scale } }
    sepFilter2Core(s, d, kx, ky, -1, -1, delta, border)
    return SRStatus.ok
}

@_cdecl("sr_scharr")
public func sr_scharr(_ srcP: MatP?, _ dstP: MatP?, _ dx: Int32, _ dy: Int32,
                      _ scale: Double, _ delta: Double, _ border: Int32) -> Int32 {
    guard let s = mat(srcP), let d = mat(dstP), s.rows == d.rows, s.cols == d.cols, s.cn == d.cn else {
        return srFail(SRStatus.badArgument, "Scharr: bad arguments")
    }
    guard (dx == 1 && dy == 0) || (dx == 0 && dy == 1) else {
        return srFail(SRStatus.badArgument, "Scharr: requires (dx=1,dy=0) or (dx=0,dy=1)")
    }
    var kx = dx == 1 ? [-1.0, 0.0, 1.0] : [3.0, 10.0, 3.0]
    let ky = dx == 1 ? [3.0, 10.0, 3.0] : [-1.0, 0.0, 1.0]
    if scale != 1.0 { kx = kx.map { $0 * scale } }
    sepFilter2Core(s, d, kx, ky, -1, -1, delta, border)
    return SRStatus.ok
}

@_cdecl("sr_laplacian")
public func sr_laplacian(_ srcP: MatP?, _ dstP: MatP?, _ ksize: Int32,
                         _ scale: Double, _ delta: Double, _ border: Int32) -> Int32 {
    guard let s = mat(srcP), let d = mat(dstP), s.rows == d.rows, s.cols == d.cols, s.cn == d.cn else {
        return srFail(SRStatus.badArgument, "Laplacian: bad arguments")
    }
    let ks = Int(ksize)
    guard ks == 1 || ks == 3 || ks == 5 || ks == 7 else {
        return srFail(SRStatus.badArgument, "Laplacian: ksize must be 1, 3, 5, or 7")
    }
    let w = s.cols, h = s.rows, c = Int(s.cn), n = w * c
    if w == 0 || h == 0 { return SRStatus.ok }
    if (ks == 1 || ks == 3) && (s.depth == 0 || s.depth == 5) && d.depth == 5 {
        let sc1 = Float((ks == 1 ? 1.0 : 2.0) * scale)
        let sc0 = Float((ks == 1 ? -4.0 : -8.0) * scale)
        let dl = Float(delta)
        @inline(__always) func readF(_ y: Int, _ x: Int, _ ch: Int) -> Float {
            let yy = srBorderInterp(y, h, border)
            let xx = srBorderInterp(x, w, border)
            if yy < 0 || xx < 0 { return 0 }
            let row = s.row(yy)
            return s.depth == 5
                ? row.assumingMemoryBound(to: Float.self)[xx * c + ch]
                : Float(row.assumingMemoryBound(to: UInt8.self)[xx * c + ch])
        }
        for y in 0..<h {
            let dr = d.row(y).assumingMemoryBound(to: Float.self)
            if y >= 1 && y < h - 1 && w >= 3 && s.depth == 5 {
                let rUp = s.row(y - 1).assumingMemoryBound(to: Float.self)
                let rMid = s.row(y).assumingMemoryBound(to: Float.self)
                let rDn = s.row(y + 1).assumingMemoryBound(to: Float.self)
                for ch in 0..<c {
                    dr[ch] = ks == 1
                        ? dl + readF(y - 1, 0, ch) * sc1 + readF(y, -1, ch) * sc1 + rMid[ch] * sc0 + rMid[c + ch] * sc1 + readF(y + 1, 0, ch) * sc1
                        : dl + readF(y - 1, -1, ch) * sc1 + readF(y - 1, 1, ch) * sc1 + rMid[ch] * sc0 + readF(y + 1, -1, ch) * sc1 + readF(y + 1, 1, ch) * sc1
                }
                if ks == 1 {
                    for i in c..<(n - c) {
                        dr[i] = dl + rUp[i] * sc1 + rMid[i - c] * sc1 + rMid[i] * sc0 + rMid[i + c] * sc1 + rDn[i] * sc1
                    }
                } else {
                    for i in c..<(n - c) {
                        dr[i] = dl + rUp[i - c] * sc1 + rUp[i + c] * sc1 + rMid[i] * sc0 + rDn[i - c] * sc1 + rDn[i + c] * sc1
                    }
                }
                let last = (w - 1) * c
                for ch in 0..<c {
                    let x = w - 1
                    dr[last + ch] = ks == 1
                        ? dl + readF(y - 1, x, ch) * sc1 + rMid[last - c + ch] * sc1 + rMid[last + ch] * sc0 + readF(y, x + 1, ch) * sc1 + readF(y + 1, x, ch) * sc1
                        : dl + readF(y - 1, x - 1, ch) * sc1 + readF(y - 1, x + 1, ch) * sc1 + rMid[last + ch] * sc0 + readF(y + 1, x - 1, ch) * sc1 + readF(y + 1, x + 1, ch) * sc1
                }
            } else {
                for x in 0..<w {
                    for ch in 0..<c {
                        dr[x * c + ch] = ks == 1
                            ? dl + readF(y - 1, x, ch) * sc1 + readF(y, x - 1, ch) * sc1 + readF(y, x, ch) * sc0 + readF(y, x + 1, ch) * sc1 + readF(y + 1, x, ch) * sc1
                            : dl + readF(y - 1, x - 1, ch) * sc1 + readF(y - 1, x + 1, ch) * sc1 + readF(y, x, ch) * sc0 + readF(y + 1, x - 1, ch) * sc1 + readF(y + 1, x + 1, ch) * sc1
                    }
                }
            }
        }
        return SRStatus.ok
    }
    if ks == 1 || ks == 3 {
        let ker: [Double] = ks == 1
            ? [0, 1, 0, 1, -4, 1, 0, 1, 0].map { Double($0) * scale }
            : [2, 0, 2, 0, -8, 0, 2, 0, 2].map { Double($0) * scale }
        return ker.withUnsafeBufferPointer { kp in
            sr_filter2d(srcP, dstP, kp.baseAddress!, 3, 3, -1, -1, delta, border)
        }
    }
    // ks >= 5: Sobel(dx=2,dy=0) + Sobel(dx=0,dy=2) accumulated in Double
    let kx2 = derivKernel1D(2, ks), ky0 = derivKernel1D(0, ks)
    let kx0 = ky0, ky2 = kx2
    var buf1 = [Double](repeating: 0.0, count: h * n)
    var buf2 = [Double](repeating: 0.0, count: h * n)
    buf1.withUnsafeMutableBufferPointer { p1 in
        buf2.withUnsafeMutableBufferPointer { p2 in
            let m1 = CoreMat(data: p1.baseAddress!, rows: h, cols: w, step: n * 8, cn: Int32(c), depth: 6)
            let m2 = CoreMat(data: p2.baseAddress!, rows: h, cols: w, step: n * 8, cn: Int32(c), depth: 6)
            sepFilter2Core(s, m1, kx2, ky0, -1, -1, 0.0, border)
            sepFilter2Core(s, m2, kx0, ky2, -1, -1, 0.0, border)
            for y in 0..<h {
                let dr = d.row(y)
                for i in 0..<n {
                    let v = (p1[y * n + i] + p2[y * n + i]) * scale + delta
                    fWriteD(dr, i, d.depth, v)
                }
            }
        }
    }
    return SRStatus.ok
}

@_cdecl("sr_pyr_up")
public func sr_pyr_up(_ srcP: MatP?, _ dstP: MatP?, _ border: Int32) -> Int32 {
    guard let s = mat(srcP), let d = mat(dstP), s.cn == d.cn, s.depth == d.depth, s.rows > 0, s.cols > 0 else {
        return srFail(SRStatus.badArgument, "pyrUp: bad arguments")
    }
    let dw = d.cols, dh = d.rows, c = Int(s.cn)
    let ew = max(dw, s.cols * 2), eh = max(dh, s.rows * 2), n = ew * c
    var up = [Double](repeating: 0.0, count: eh * n)
    for sy in 0..<s.rows {
        let dy = sy * 2
        if dy >= eh { break }
        let sr = UnsafeRawPointer(s.row(sy))
        for sx in 0..<s.cols {
            let dx = sx * 2
            if dx >= ew { break }
            for ch in 0..<c { up[dy * n + dx * c + ch] = fReadD(sr, sx * c + ch, s.depth) }
        }
    }
    let ker: [Double] = [0.125, 0.5, 0.75, 0.5, 0.125]
    up.withUnsafeMutableBufferPointer { upPtr in
        let mUp = CoreMat(data: upPtr.baseAddress!, rows: eh, cols: ew, step: n * 8, cn: Int32(c), depth: 6)
        if ew == dw && eh == dh {
            sepFilter2Core(mUp, d, ker, ker, -1, -1, 0.0, border)
        } else {
            let eb = (s.depth == 6) ? 8 : ((s.depth == 4 || s.depth == 5) ? 4 : ((s.depth == 2 || s.depth == 3) ? 2 : 1))
            var tmp = [UInt8](repeating: 0, count: eh * n * eb)
            tmp.withUnsafeMutableBufferPointer { tp in
                let mTmp = CoreMat(data: tp.baseAddress!, rows: eh, cols: ew, step: n * eb, cn: Int32(c), depth: s.depth)
                sepFilter2Core(mUp, mTmp, ker, ker, -1, -1, 0.0, border)
                let rowBytes = dw * c * eb
                for y in 0..<dh {
                    memcpy(d.row(y), tp.baseAddress! + y * n * eb, rowBytes)
                }
            }
        }
    }
    return SRStatus.ok
}

@_cdecl("sr_canny")
public func sr_canny(_ srcP: MatP?, _ dstP: MatP?, _ t1: Double, _ t2: Double, _ ap: Int32, _ l2: Int32) -> Int32 {
    guard let s = mat(srcP), let d = mat(dstP), s.depth == 0, d.depth == 0, d.cn == 1,
          s.rows == d.rows, s.cols == d.cols else {
        return srFail(SRStatus.badArgument, "Canny: requires u8 input and 1-ch u8 output of same size")
    }
    let rc = sr_c_canny_u8(s.data?.assumingMemoryBound(to: UInt8.self), Int32(s.cols), Int32(s.rows), s.cn, Int32(s.step),
                           d.data?.assumingMemoryBound(to: UInt8.self), Int32(d.step), t1, t2, ap, l2)
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.badArgument, "Canny: invalid apertureSize or dimensions")
}

@_cdecl("sr_bilateral")
public func sr_bilateral(_ srcP: MatP?, _ dstP: MatP?, _ dDiam: Int32, _ sigC: Double, _ sigS: Double, _ border: Int32) -> Int32 {
    guard let s = mat(srcP), let d = mat(dstP), s.depth == d.depth, s.cn == d.cn, s.rows == d.rows, s.cols == d.cols else {
        return srFail(SRStatus.badArgument, "bilateralFilter: bad arguments")
    }
    let sc = sigC <= 0 ? 1e-6 : sigC
    let ss = sigS <= 0 ? 1e-6 : sigS
    let rad: Int32 = dDiam <= 0 ? Int32(max(1, Int((ss * 1.5).rounded()))) : max(1, dDiam / 2)
    let rc: Int32
    if s.depth == 0 {
        rc = sr_c_bilateral_u8(s.data?.assumingMemoryBound(to: UInt8.self), Int32(s.cols), Int32(s.rows), s.cn, Int32(s.step),
                               d.data?.assumingMemoryBound(to: UInt8.self), Int32(d.step), rad, sc, ss, border)
    } else if s.depth == 5 {
        rc = sr_c_bilateral_f32(s.data?.assumingMemoryBound(to: Float.self), Int32(s.cols), Int32(s.rows), s.cn, Int32(s.step),
                                d.data?.assumingMemoryBound(to: Float.self), Int32(d.step), rad, sc, ss, border)
    } else {
        return srFail(SRStatus.unsupported, "bilateralFilter: supports u8 and f32")
    }
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.badArgument, "bilateralFilter: failed")
}

@_cdecl("sr_median_blur")
public func sr_median_blur(_ srcP: MatP?, _ dstP: MatP?, _ ksize: Int32) -> Int32 {
    guard let s = mat(srcP), let d = mat(dstP), s.depth == d.depth, s.cn == d.cn, s.rows == d.rows, s.cols == d.cols else {
        return srFail(SRStatus.badArgument, "medianBlur: bad arguments")
    }
    let rc: Int32
    switch s.depth {
    case 0:
        rc = sr_c_median_u8(s.data?.assumingMemoryBound(to: UInt8.self), Int32(s.cols), Int32(s.rows), s.cn, Int32(s.step),
                            d.data?.assumingMemoryBound(to: UInt8.self), Int32(d.step), ksize)
    case 2:
        rc = sr_c_median_u16(s.data?.assumingMemoryBound(to: UInt16.self), Int32(s.cols), Int32(s.rows), s.cn, Int32(s.step),
                             d.data?.assumingMemoryBound(to: UInt16.self), Int32(d.step), ksize)
    case 5:
        rc = sr_c_median_f32(s.data?.assumingMemoryBound(to: Float.self), Int32(s.cols), Int32(s.rows), s.cn, Int32(s.step),
                             d.data?.assumingMemoryBound(to: Float.self), Int32(d.step), ksize)
    default:
        return srFail(SRStatus.unsupported, "medianBlur: unsupported depth")
    }
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.badArgument, "medianBlur: invalid ksize")
}

@_cdecl("sr_integral")
public func sr_integral(_ srcP: MatP?, _ sumP: MatP?, _ sqP: MatP?, _ tilP: MatP?) -> Int32 {
    guard let s = mat(srcP), let sum = mat(sumP), sum.rows == s.rows + 1, sum.cols == s.cols + 1, sum.cn == s.cn else {
        return srFail(SRStatus.badArgument, "integral: invalid sum shape")
    }
    let sq = mat(sqP), til = mat(tilP)
    let rc = sr_c_integral(s.data, Int32(s.cols), Int32(s.rows), s.cn, Int32(s.step), s.depth,
                           sum.data, Int32(sum.step), sum.depth,
                           sq?.data?.assumingMemoryBound(to: Double.self), Int32(sq?.step ?? 0),
                           til?.data, Int32(til?.step ?? 0), til?.depth ?? 0)
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.badArgument, "integral: failed")
}

@_cdecl("sr_equalize_hist")
public func sr_equalize_hist(_ srcP: MatP?, _ dstP: MatP?) -> Int32 {
    guard let s = mat(srcP), let d = mat(dstP), s.depth == 0, d.depth == 0, s.cn == 1, d.cn == 1,
          s.rows == d.rows, s.cols == d.cols else {
        return srFail(SRStatus.badArgument, "equalizeHist: requires 1-channel u8 images")
    }
    let rc = sr_c_equalize_hist_u8(s.data?.assumingMemoryBound(to: UInt8.self), Int32(s.cols), Int32(s.rows), Int32(s.step),
                                   d.data?.assumingMemoryBound(to: UInt8.self), Int32(d.step))
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.badArgument, "equalizeHist: failed")
}

@_cdecl("sr_clahe_apply")
public func sr_clahe_apply(_ srcP: MatP?, _ dstP: MatP?, _ clipLimit: Double, _ tilesX: Int32, _ tilesY: Int32) -> Int32 {
    guard let s = mat(srcP), let d = mat(dstP), s.depth == d.depth, s.cn == 1, d.cn == 1, s.rows == d.rows, s.cols == d.cols else {
        return srFail(SRStatus.badArgument, "CLAHE: requires 1-channel u8 or u16 image")
    }
    let rc: Int32
    if s.depth == 0 {
        rc = sr_c_clahe_u8(s.data?.assumingMemoryBound(to: UInt8.self), Int32(s.cols), Int32(s.rows), Int32(s.step),
                           d.data?.assumingMemoryBound(to: UInt8.self), Int32(d.step), clipLimit, tilesX, tilesY)
    } else if s.depth == 2 {
        rc = sr_c_clahe_u16(s.data?.assumingMemoryBound(to: UInt16.self), Int32(s.cols), Int32(s.rows), Int32(s.step),
                            d.data?.assumingMemoryBound(to: UInt16.self), Int32(d.step), clipLimit, tilesX, tilesY)
    } else {
        return srFail(SRStatus.unsupported, "CLAHE: supports u8 and u16")
    }
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.badArgument, "CLAHE: failed")
}

@_cdecl("sr_apply_colormap")
public func sr_apply_colormap(_ srcP: MatP?, _ dstP: MatP?, _ colormap: Int32, _ customLut: UnsafePointer<UInt8>?) -> Int32 {
    guard let s = mat(srcP), let d = mat(dstP), s.depth == 0, d.depth == 0, d.cn == 3,
          s.rows == d.rows, s.cols == d.cols else {
        return srFail(SRStatus.badArgument, "applyColorMap: requires u8 input and 3-ch u8 output")
    }
    let rc = sr_c_apply_colormap(s.data?.assumingMemoryBound(to: UInt8.self), Int32(s.cols), Int32(s.rows), Int32(s.step), s.cn,
                                 d.data?.assumingMemoryBound(to: UInt8.self), Int32(d.step), colormap, customLut)
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.badArgument, "applyColorMap: invalid colormap")
}

@_cdecl("sr_adaptive_threshold")
public func sr_adaptive_threshold(_ srcP: MatP?, _ dstP: MatP?, _ maxVal: Double, _ method: Int32,
                                  _ threshType: Int32, _ blockSize: Int32, _ cConst: Double) -> Int32 {
    guard let s = mat(srcP), let d = mat(dstP), s.depth == 0, d.depth == 0, s.cn == 1, d.cn == 1,
          s.rows == d.rows, s.cols == d.cols, blockSize >= 3, (blockSize % 2) == 1 else {
        return srFail(SRStatus.badArgument, "adaptiveThreshold: bad arguments")
    }
    let w = s.cols, h = s.rows
    if w == 0 || h == 0 { return SRStatus.ok }
    var meanBuf = [Double](repeating: 0.0, count: w * h)
    meanBuf.withUnsafeMutableBufferPointer { mb in
        var mMean = CoreMat(data: mb.baseAddress!, rows: h, cols: w, step: w * 8, cn: 1, depth: 6)
        if method == 0 { // MEAN_C
            _ = sr_box_filter(srcP, &mMean, blockSize, blockSize, -1, -1, 1, 1) // BORDER_REPLICATE
        } else {         // GAUSSIAN_C
            let n = Int(blockSize)
            let sig = 0.3 * (Double(n - 1) * 0.5 - 1.0) + 0.8
            var ker = (0..<n).map { exp(-pow(Double($0) - Double(n - 1) * 0.5, 2.0) / (2.0 * sig * sig)) }
            let sumK = ker.reduce(0.0, +)
            ker = ker.map { $0 / sumK }
            sepFilter2Core(s, mMean, ker, ker, -1, -1, 0.0, 1)
        }
        let maxB = srSatU8(maxVal)
        let inv = threshType == 1
        for y in 0..<h {
            let sr = s.row(y).assumingMemoryBound(to: UInt8.self)
            let dr = d.row(y).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let thr = Int(mb[y * w + x].rounded(.toNearestOrEven)) - Int(cConst.rounded(.toNearestOrEven))
                let pass = Int(sr[x]) > thr
                dr[x] = (inv ? !pass : pass) ? maxB : 0
            }
        }
    }
    return SRStatus.ok
}
