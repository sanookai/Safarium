// SafariumRaster — Phase 1: SIMD / vImage fast paths for the hot core kernels (same results as the generic code).

import Foundation
import Accelerate
import SafariumRasterC

// MARK: - integer <-> float row conversion (concrete SIMD kernels; generic SIMD init paths are not specialised by Swift)

func perfLoadU8F(_ p: UnsafeRawPointer, _ n: Int, _ out: UnsafeMutablePointer<Float>) {
    var i = 0
    while i + 16 <= n {
        let v = p.loadUnaligned(fromByteOffset: i * MemoryLayout<UInt8>.size, as: SIMD16<UInt8>.self)
        UnsafeMutableRawPointer(out + i).storeBytes(of: SIMD16<Float>(v), as: SIMD16<Float>.self)
        i += 16
    }
    let s = p.assumingMemoryBound(to: UInt8.self)
    while i < n { out[i] = Float(s[i]); i += 1 }
}

func perfStoreFU8(_ w: UnsafePointer<Float>, _ n: Int, _ d: UnsafeMutableRawPointer) {
    // vDSP rounds half to even but wraps out-of-range values, so clip in cache-sized chunks first (NaN -> 0).
    var lo: Float = 0, hi: Float = 255
    let dp = d.assumingMemoryBound(to: UInt8.self)
    withTemp(2048, Float.self) { tmp in
        var i = 0
        while i < n {
            let m = min(2048, n - i)
            vDSP_vclip(w + i, 1, &lo, &hi, tmp, 1, vDSP_Length(m))
            vDSP_vfixru8(tmp, 1, dp + i, 1, vDSP_Length(m))
            i += m
        }
    }
}

func perfLoadS8F(_ p: UnsafeRawPointer, _ n: Int, _ out: UnsafeMutablePointer<Float>) {
    var i = 0
    while i + 16 <= n {
        let v = p.loadUnaligned(fromByteOffset: i * MemoryLayout<Int8>.size, as: SIMD16<Int8>.self)
        UnsafeMutableRawPointer(out + i).storeBytes(of: SIMD16<Float>(v), as: SIMD16<Float>.self)
        i += 16
    }
    let s = p.assumingMemoryBound(to: Int8.self)
    while i < n { out[i] = Float(s[i]); i += 1 }
}

func perfStoreFS8(_ w: UnsafePointer<Float>, _ n: Int, _ d: UnsafeMutableRawPointer) {
    // vDSP rounds half to even but wraps out-of-range values, so clip in cache-sized chunks first (NaN -> 0).
    var lo: Float = -128, hi: Float = 127
    let dp = d.assumingMemoryBound(to: Int8.self)
    withTemp(2048, Float.self) { tmp in
        var i = 0
        while i < n {
            let m = min(2048, n - i)
            vDSP_vclip(w + i, 1, &lo, &hi, tmp, 1, vDSP_Length(m))
            vDSP_vfixr8(tmp, 1, dp + i, 1, vDSP_Length(m))
            i += m
        }
    }
}

func perfLoadU16F(_ p: UnsafeRawPointer, _ n: Int, _ out: UnsafeMutablePointer<Float>) {
    var i = 0
    while i + 16 <= n {
        let v = p.loadUnaligned(fromByteOffset: i * MemoryLayout<UInt16>.size, as: SIMD16<UInt16>.self)
        UnsafeMutableRawPointer(out + i).storeBytes(of: SIMD16<Float>(v), as: SIMD16<Float>.self)
        i += 16
    }
    let s = p.assumingMemoryBound(to: UInt16.self)
    while i < n { out[i] = Float(s[i]); i += 1 }
}

func perfStoreFU16(_ w: UnsafePointer<Float>, _ n: Int, _ d: UnsafeMutableRawPointer) {
    // vDSP rounds half to even but wraps out-of-range values, so clip in cache-sized chunks first (NaN -> 0).
    var lo: Float = 0, hi: Float = 65535
    let dp = d.assumingMemoryBound(to: UInt16.self)
    withTemp(2048, Float.self) { tmp in
        var i = 0
        while i < n {
            let m = min(2048, n - i)
            vDSP_vclip(w + i, 1, &lo, &hi, tmp, 1, vDSP_Length(m))
            vDSP_vfixru16(tmp, 1, dp + i, 1, vDSP_Length(m))
            i += m
        }
    }
}

func perfLoadS16F(_ p: UnsafeRawPointer, _ n: Int, _ out: UnsafeMutablePointer<Float>) {
    var i = 0
    while i + 16 <= n {
        let v = p.loadUnaligned(fromByteOffset: i * MemoryLayout<Int16>.size, as: SIMD16<Int16>.self)
        UnsafeMutableRawPointer(out + i).storeBytes(of: SIMD16<Float>(v), as: SIMD16<Float>.self)
        i += 16
    }
    let s = p.assumingMemoryBound(to: Int16.self)
    while i < n { out[i] = Float(s[i]); i += 1 }
}

func perfStoreFS16(_ w: UnsafePointer<Float>, _ n: Int, _ d: UnsafeMutableRawPointer) {
    // vDSP rounds half to even but wraps out-of-range values, so clip in cache-sized chunks first (NaN -> 0).
    var lo: Float = -32768, hi: Float = 32767
    let dp = d.assumingMemoryBound(to: Int16.self)
    withTemp(2048, Float.self) { tmp in
        var i = 0
        while i < n {
            let m = min(2048, n - i)
            vDSP_vclip(w + i, 1, &lo, &hi, tmp, 1, vDSP_Length(m))
            vDSP_vfixr16(tmp, 1, dp + i, 1, vDSP_Length(m))
            i += m
        }
    }
}

// MARK: - countNonZero

func perfCountNonZeroU8(_ p: UnsafePointer<UInt8>, _ n: Int) -> Int {
    var total = 0
    var i = 0
    let raw = UnsafeRawPointer(p)
    let zero = SIMD64<UInt8>()
    while i + 64 <= n {
        var acc = SIMD64<UInt8>()
        var blocks = 0
        while blocks < 255 && i + 64 <= n {
            let v = raw.loadUnaligned(fromByteOffset: i, as: SIMD64<UInt8>.self)
            acc &-= unsafeBitCast(v .!= zero, to: SIMD64<UInt8>.self)
            i += 64; blocks += 1
        }
        total += Int(SIMD64<UInt16>(truncatingIfNeeded: acc).wrappedSum())
    }
    while i < n { if p[i] != 0 { total += 1 }; i += 1 }
    return total
}

func perfCountNonZeroF32(_ p: UnsafePointer<Float>, _ n: Int) -> Int {
    var i = 0
    let raw = UnsafeRawPointer(p)
    var acc = SIMD16<Int32>()
    while i + 16 <= n {
        let v = raw.loadUnaligned(fromByteOffset: i * 4, as: SIMD16<Float>.self)
        acc &-= unsafeBitCast(v .!= SIMD16<Float>(), to: SIMD16<Int32>.self)
        i += 16
    }
    var total = Int(acc.wrappedSum())
    while i < n { if p[i] != 0 { total += 1 }; i += 1 }
    return total
}

// MARK: - LUT via vImage (u8 -> u8, one shared 256-entry table)

func perfLutU8(_ s: CoreMat, _ d: CoreMat, _ table: UnsafePointer<UInt8>) {
    let n = s.n
    if packed(s) && packed(d) {
        src_lut_u8(s.data!.assumingMemoryBound(to: UInt8.self), d.data!.assumingMemoryBound(to: UInt8.self), n * s.rows, table)
        return
    }
    for y in 0..<s.rows { src_lut_u8(s.row(y).assumingMemoryBound(to: UInt8.self), d.row(y).assumingMemoryBound(to: UInt8.self), n, table) }
}

// MARK: - u8 sums / sums of squares per channel (SIMD, exact integers)

/// Accumulates per-channel sum and sum of squares of one u8 row (n = cols * cn elements). cn in 1...4.
func perfSumsU8Row(_ p: UnsafePointer<UInt8>, _ n: Int, _ cn: Int, _ s: inout [UInt64], _ q: inout [UInt64], _ wantSq: Bool) {
    let M = cn == 3 ? 3 : 1
    let accS = UnsafeMutablePointer<SIMD4<UInt32>>.allocate(capacity: 12)
    let accQ = UnsafeMutablePointer<SIMD4<UInt32>>.allocate(capacity: 12)
    accS.initialize(repeating: SIMD4<UInt32>(), count: 12); accQ.initialize(repeating: SIMD4<UInt32>(), count: 12)
    defer { accS.deallocate(); accQ.deallocate() }
    let raw = UnsafeRawPointer(p)
    let mask = SIMD4<UInt32>(repeating: 0xFF)
    var i = 0, m = 0
    while i + 16 <= n {
        let v = raw.loadUnaligned(fromByteOffset: i, as: SIMD4<UInt32>.self)
        let b0 = v & mask, b1 = (v &>> 8) & mask, b2 = (v &>> 16) & mask, b3 = v &>> 24
        let base = m * 4
        accS[base] &+= b0; accS[base + 1] &+= b1; accS[base + 2] &+= b2; accS[base + 3] &+= b3
        if wantSq {
            accQ[base] &+= b0 &* b0; accQ[base + 1] &+= b1 &* b1; accQ[base + 2] &+= b2 &* b2; accQ[base + 3] &+= b3 &* b3
        }
        i += 16; m += 1; if m == M { m = 0 }
    }
    for mm in 0..<M { for j in 0..<4 { for l in 0..<4 {
        let byteIdx = 16 * mm + 4 * l + j
        let c = byteIdx % cn
        s[c] &+= UInt64(accS[mm * 4 + j][l]); q[c] &+= UInt64(accQ[mm * 4 + j][l])
    } } }
    // tail: element index i.. continues the channel pattern from i % cn (i is a multiple of 16, M-aligned only for cn=3 handled by mm mapping above)
    var k = i
    while k < n { let v = UInt64(p[k]); let c = k % cn; s[c] &+= v; q[c] &+= v &* v; k += 1 }
}

func perfMaxMinU8(_ p: UnsafePointer<UInt8>, _ n: Int) -> (UInt8, UInt8) {
    var vmin = SIMD16<UInt8>(repeating: 255), vmax = SIMD16<UInt8>()
    var i = 0
    let raw = UnsafeRawPointer(p)
    while i + 16 <= n {
        let v = raw.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
        vmin = pointwiseMin(vmin, v); vmax = pointwiseMax(vmax, v)
        i += 16
    }
    var lo = vmin.min(), hi = vmax.max()
    while i < n { lo = Swift.min(lo, p[i]); hi = Swift.max(hi, p[i]); i += 1 }
    return (lo, hi)
}

/// max |a - b| over a u8 row pair
func perfMaxAbsDiffU8(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, _ n: Int) -> UInt8 {
    var vmax = SIMD16<UInt8>()
    var i = 0
    let ra = UnsafeRawPointer(a), rb = UnsafeRawPointer(b)
    while i + 16 <= n {
        let x = ra.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self), y = rb.loadUnaligned(fromByteOffset: i, as: SIMD16<UInt8>.self)
        vmax = pointwiseMax(vmax, pointwiseMax(x, y) &- pointwiseMin(x, y))
        i += 16
    }
    var hi = vmax.max()
    while i < n { let d = a[i] > b[i] ? a[i] - b[i] : b[i] - a[i]; hi = Swift.max(hi, d); i += 1 }
    return hi
}

// MARK: - f32 sums via vDSP (double accumulation)

func perfSumsF32Row(_ p: UnsafePointer<Float>, _ n: Int, _ cn: Int, _ s: inout [Double], _ q: inout [Double], _ wantSq: Bool) {
    let cols = n / cn
    withTemp(2048, Double.self) { tmp in
        for c in 0..<cn {
            var x = 0
            while x < cols {
                let m = Swift.min(2048, cols - x)
                vDSP_vspdp(p + x * cn + c, vDSP_Stride(cn), tmp, 1, vDSP_Length(m))
                var a = 0.0
                vDSP_sveD(tmp, 1, &a, vDSP_Length(m))
                s[c] += a
                if wantSq { var b = 0.0; vDSP_svesqD(tmp, 1, &b, vDSP_Length(m)); q[c] += b }
                x += m
            }
        }
    }
}

/// Total sum (sq == false) or sum of squares (sq == true) of a u8 run, register accumulators.
func perfTotalU8(_ p: UnsafePointer<UInt8>, _ n: Int, _ sq: Bool) -> UInt64 {
    var total: UInt64 = 0
    var i = 0
    let raw = UnsafeRawPointer(p)
    let mask = SIMD4<UInt32>(repeating: 0xFF)
    while i + 16 <= n {
        var a0 = SIMD4<UInt32>(), a1 = SIMD4<UInt32>(), a2 = SIMD4<UInt32>(), a3 = SIMD4<UInt32>()
        var blocks = 0
        // lane limit: 65025 per square -> 66k additions; keep well below
        while blocks < 4096 && i + 16 <= n {
            let v = raw.loadUnaligned(fromByteOffset: i, as: SIMD4<UInt32>.self)
            let b0 = v & mask, b1 = (v &>> 8) & mask, b2 = (v &>> 16) & mask, b3 = v &>> 24
            if sq { a0 &+= b0 &* b0; a1 &+= b1 &* b1; a2 &+= b2 &* b2; a3 &+= b3 &* b3 }
            else { a0 &+= b0; a1 &+= b1; a2 &+= b2; a3 &+= b3 }
            i += 16; blocks += 1
        }
        let t = (a0 &+ a1) &+ (a2 &+ a3)
        total += UInt64(t[0]) + UInt64(t[1]) + UInt64(t[2]) + UInt64(t[3])
    }
    while i < n { let v = UInt64(p[i]); total += sq ? v * v : v; i += 1 }
    return total
}

/// Index of the first NaN in a float row, or nil.
func perfFirstNaNF32(_ p: UnsafePointer<Float>, _ n: Int) -> Int? {
    var i = 0
    let raw = UnsafeRawPointer(p)
    while i + 16 <= n {
        let v = raw.loadUnaligned(fromByteOffset: i * 4, as: SIMD16<Float>.self)
        if any(v .!= v) { break }
        i += 16
    }
    while i < n { if p[i] != p[i] { return i }; i += 1 }
    return nil
}

// MARK: - vImage channel split / merge for 8-bit 3/4-channel images

private func vbuf(_ p: UnsafeMutableRawPointer, _ rows: Int, _ w: Int, _ step: Int) -> vImage_Buffer {
    vImage_Buffer(data: p, height: vImagePixelCount(rows), width: vImagePixelCount(w), rowBytes: step)
}

/// true when handled. mats[0] interleaved (3 or 4 channels), planes: cn single-channel u8 mats of equal size.
func perfSplitU8(_ s: CoreMat, _ planes: [CoreMat]) -> Bool {
    guard s.depth == 0, planes.count == Int(s.cn), s.cn == 3 || s.cn == 4, s.rows > 0, s.cols > 0 else { return false }
    var src = vbuf(s.data!, s.rows, s.cols, s.step)
    var p = planes.map { vbuf($0.data!, $0.rows, $0.cols, $0.step) }
    let flags = vImage_Flags(kvImageDoNotTile)
    if s.cn == 3 { return vImageConvert_RGB888toPlanar8(&src, &p[0], &p[1], &p[2], flags) == kvImageNoError }
    return vImageConvert_ARGB8888toPlanar8(&src, &p[0], &p[1], &p[2], &p[3], flags) == kvImageNoError
}

func perfMergeU8(_ planes: [CoreMat], _ d: CoreMat) -> Bool {
    guard d.depth == 0, planes.count == Int(d.cn), d.cn == 3 || d.cn == 4, d.rows > 0, d.cols > 0 else { return false }
    var dst = vbuf(d.data!, d.rows, d.cols, d.step)
    var p = planes.map { vbuf($0.data!, $0.rows, $0.cols, $0.step) }
    let flags = vImage_Flags(kvImageDoNotTile)
    if d.cn == 3 { return vImageConvert_Planar8toRGB888(&p[0], &p[1], &p[2], &dst, flags) == kvImageNoError }
    return vImageConvert_Planar8toARGB8888(&p[0], &p[1], &p[2], &p[3], &dst, flags) == kvImageNoError
}

/// Horizontal flip of u8 3-channel: reflect the byte row, then swap channels 0 and 2 back.
func perfFlipHU8x3(_ s: CoreMat, _ d: CoreMat) -> Bool {
    guard s.depth == 0, s.cn == 3, s.rows > 0, s.cols > 0, s.data != d.data else { return false }
    var src = vbuf(s.data!, s.rows, s.cols * 3, s.step)
    var dst = vbuf(d.data!, d.rows, d.cols * 3, d.step)
    guard vImageHorizontalReflect_Planar8(&src, &dst, vImage_Flags(kvImageDoNotTile)) == kvImageNoError else { return false }
    var d3 = vbuf(d.data!, d.rows, d.cols, d.step)
    var d3b = d3
    let map: [UInt8] = [2, 1, 0]
    return vImagePermuteChannels_RGB888(&d3, &d3b, map, vImage_Flags(kvImageDoNotTile)) == kvImageNoError
}

// MARK: - Workstream 1 NEON NumPy / pixel kernels (ops_perf_neon.c)

@_silgen_name("sr_c_bgr2gray_u8")
private func sr_c_bgr2gray_u8(_ src: UnsafePointer<UInt8>, _ sstep: Int, _ dst: UnsafeMutablePointer<UInt8>, _ dstep: Int,
                              _ w: Int32, _ h: Int32, _ scn: Int32, _ blueIdx: Int32)
@_silgen_name("sr_c_bgr2gray_u16")
private func sr_c_bgr2gray_u16(_ src: UnsafePointer<UInt16>, _ sstep: Int, _ dst: UnsafeMutablePointer<UInt16>, _ dstep: Int,
                               _ w: Int32, _ h: Int32, _ scn: Int32, _ blueIdx: Int32)
@_silgen_name("sr_c_bgr2gray_f32")
private func sr_c_bgr2gray_f32(_ src: UnsafePointer<Float>, _ sstep: Int, _ dst: UnsafeMutablePointer<Float>, _ dstep: Int,
                               _ w: Int32, _ h: Int32, _ scn: Int32, _ blueIdx: Int32)
@_silgen_name("sr_c_cvt_swap_u8")
private func sr_c_cvt_swap_u8(_ src: UnsafePointer<UInt8>, _ sstep: Int, _ dst: UnsafeMutablePointer<UInt8>, _ dstep: Int,
                              _ w: Int32, _ h: Int32, _ scn: Int32, _ dcn: Int32, _ swapRB: Int32)
@_silgen_name("sr_c_cvt_swap_u16")
private func sr_c_cvt_swap_u16(_ src: UnsafePointer<UInt16>, _ sstep: Int, _ dst: UnsafeMutablePointer<UInt16>, _ dstep: Int,
                               _ w: Int32, _ h: Int32, _ scn: Int32, _ dcn: Int32, _ swapRB: Int32)
@_silgen_name("sr_c_cvt_swap_f32")
private func sr_c_cvt_swap_f32(_ src: UnsafePointer<Float>, _ sstep: Int, _ dst: UnsafeMutablePointer<Float>, _ dstep: Int,
                               _ w: Int32, _ h: Int32, _ scn: Int32, _ dcn: Int32, _ swapRB: Int32)
@_silgen_name("sr_c_gray2bgr_u8")
private func sr_c_gray2bgr_u8(_ src: UnsafePointer<UInt8>, _ sstep: Int, _ dst: UnsafeMutablePointer<UInt8>, _ dstep: Int,
                              _ w: Int32, _ h: Int32, _ dcn: Int32)
@_silgen_name("sr_c_gray2bgr_u16")
private func sr_c_gray2bgr_u16(_ src: UnsafePointer<UInt16>, _ sstep: Int, _ dst: UnsafeMutablePointer<UInt16>, _ dstep: Int,
                               _ w: Int32, _ h: Int32, _ dcn: Int32)
@_silgen_name("sr_c_gray2bgr_f32")
private func sr_c_gray2bgr_f32(_ src: UnsafePointer<Float>, _ sstep: Int, _ dst: UnsafeMutablePointer<Float>, _ dstep: Int,
                               _ w: Int32, _ h: Int32, _ dcn: Int32)
@_silgen_name("sr_c_bgr2hsv_u8")
private func sr_c_bgr2hsv_u8(_ src: UnsafePointer<UInt8>, _ sstep: Int, _ dst: UnsafeMutablePointer<UInt8>, _ dstep: Int,
                             _ w: Int32, _ h: Int32, _ scn: Int32, _ blueIdx: Int32,
                             _ sLut: UnsafePointer<UInt8>, _ sTail: UnsafePointer<UInt8>, _ hdiv: UnsafePointer<Int32>)
@_silgen_name("sr_c_reduce_u8")
private func sr_c_reduce_u8(_ src: UnsafePointer<UInt8>, _ sstep: Int, _ dst: UnsafeMutableRawPointer, _ dstep: Int,
                            _ w: Int32, _ h: Int32, _ cn: Int32, _ dim: Int32, _ rtype: Int32, _ ddepth: Int32) -> Int32
@_silgen_name("sr_c_laplacian")
private func sr_c_np_laplacian(_ src: UnsafeRawPointer, _ sstep: Int, _ sdepth: Int32,
                               _ dst: UnsafeMutableRawPointer, _ dstep: Int, _ ddepth: Int32,
                               _ w: Int32, _ h: Int32, _ cn: Int32,
                               _ ksize: Int32, _ scale: Double, _ delta: Double, _ border: Int32) -> Int32

@_cdecl("sr_np_bgr2gray")
public func sr_np_bgr2gray(_ src: UnsafeRawPointer?, _ sstep: Int, _ dst: UnsafeMutableRawPointer?, _ dstep: Int,
                           _ w: Int32, _ h: Int32, _ scn: Int32, _ depth: Int32, _ blueIdx: Int32) -> Int32 {
    guard let src, let dst, w >= 0, h >= 0, scn == 3 || scn == 4 else { return srFail(SRStatus.badArgument, "bgr2gray: bad arguments") }
    if w == 0 || h == 0 { return SRStatus.ok }
    switch depth {
    case 0: sr_c_bgr2gray_u8(src.assumingMemoryBound(to: UInt8.self), sstep, dst.assumingMemoryBound(to: UInt8.self), dstep, w, h, scn, blueIdx)
    case 2: sr_c_bgr2gray_u16(src.assumingMemoryBound(to: UInt16.self), sstep, dst.assumingMemoryBound(to: UInt16.self), dstep, w, h, scn, blueIdx)
    case 5: sr_c_bgr2gray_f32(src.assumingMemoryBound(to: Float.self), sstep, dst.assumingMemoryBound(to: Float.self), dstep, w, h, scn, blueIdx)
    default: return srFail(SRStatus.unsupported, "bgr2gray: unsupported depth \(depth)")
    }
    return SRStatus.ok
}

@_cdecl("sr_np_cvt_swap")
public func sr_np_cvt_swap(_ src: UnsafeRawPointer?, _ sstep: Int, _ dst: UnsafeMutableRawPointer?, _ dstep: Int,
                           _ w: Int32, _ h: Int32, _ scn: Int32, _ dcn: Int32, _ depth: Int32, _ swapRB: Int32) -> Int32 {
    guard let src, let dst, w >= 0, h >= 0, scn == 3 || scn == 4, dcn == 3 || dcn == 4 else { return srFail(SRStatus.badArgument, "cvt_swap: bad arguments") }
    if w == 0 || h == 0 { return SRStatus.ok }
    switch depth {
    case 0: sr_c_cvt_swap_u8(src.assumingMemoryBound(to: UInt8.self), sstep, dst.assumingMemoryBound(to: UInt8.self), dstep, w, h, scn, dcn, swapRB)
    case 2: sr_c_cvt_swap_u16(src.assumingMemoryBound(to: UInt16.self), sstep, dst.assumingMemoryBound(to: UInt16.self), dstep, w, h, scn, dcn, swapRB)
    case 5: sr_c_cvt_swap_f32(src.assumingMemoryBound(to: Float.self), sstep, dst.assumingMemoryBound(to: Float.self), dstep, w, h, scn, dcn, swapRB)
    default: return srFail(SRStatus.unsupported, "cvt_swap: unsupported depth \(depth)")
    }
    return SRStatus.ok
}

@_cdecl("sr_np_gray2bgr")
public func sr_np_gray2bgr(_ src: UnsafeRawPointer?, _ sstep: Int, _ dst: UnsafeMutableRawPointer?, _ dstep: Int,
                           _ w: Int32, _ h: Int32, _ dcn: Int32, _ depth: Int32) -> Int32 {
    guard let src, let dst, w >= 0, h >= 0, dcn == 3 || dcn == 4 else { return srFail(SRStatus.badArgument, "gray2bgr: bad arguments") }
    if w == 0 || h == 0 { return SRStatus.ok }
    switch depth {
    case 0: sr_c_gray2bgr_u8(src.assumingMemoryBound(to: UInt8.self), sstep, dst.assumingMemoryBound(to: UInt8.self), dstep, w, h, dcn)
    case 2: sr_c_gray2bgr_u16(src.assumingMemoryBound(to: UInt16.self), sstep, dst.assumingMemoryBound(to: UInt16.self), dstep, w, h, dcn)
    case 5: sr_c_gray2bgr_f32(src.assumingMemoryBound(to: Float.self), sstep, dst.assumingMemoryBound(to: Float.self), dstep, w, h, dcn)
    default: return srFail(SRStatus.unsupported, "gray2bgr: unsupported depth \(depth)")
    }
    return SRStatus.ok
}

@_cdecl("sr_np_hsv_u8")
public func sr_np_hsv_u8(_ src: UnsafeRawPointer?, _ sstep: Int, _ dst: UnsafeMutableRawPointer?, _ dstep: Int,
                         _ h: Int32, _ w: Int32, _ scn: Int32, _ blueIdx: Int32,
                         _ sLut: UnsafePointer<UInt8>?, _ sTail: UnsafePointer<UInt8>?, _ hdiv: UnsafePointer<Int32>?) -> Int32 {
    guard let src, let dst, let sLut, let sTail, let hdiv, h >= 0, w >= 0, scn == 3 || scn == 4 else {
        return srFail(SRStatus.badArgument, "hsv_u8: bad arguments")
    }
    if w == 0 || h == 0 { return SRStatus.ok }
    sr_c_bgr2hsv_u8(src.assumingMemoryBound(to: UInt8.self), sstep, dst.assumingMemoryBound(to: UInt8.self), dstep,
                    w, h, scn, blueIdx, sLut, sTail, hdiv)
    return SRStatus.ok
}

@_cdecl("sr_np_reduce_u8")
public func sr_np_reduce_u8(_ src: UnsafeRawPointer?, _ sstep: Int, _ dst: UnsafeMutableRawPointer?, _ dstep: Int,
                            _ w: Int32, _ h: Int32, _ cn: Int32, _ dim: Int32, _ rtype: Int32, _ ddepth: Int32) -> Int32 {
    guard let src, let dst, w > 0, h > 0, cn > 0 else { return srFail(SRStatus.badArgument, "reduce: bad arguments") }
    return sr_c_reduce_u8(src.assumingMemoryBound(to: UInt8.self), sstep, dst, dstep, w, h, cn, dim, rtype, ddepth) == 0
        ? SRStatus.ok : srFail(SRStatus.internalError, "reduce failed")
}

@_cdecl("sr_np_laplacian")
public func sr_np_laplacian(_ src: UnsafeRawPointer?, _ sstep: Int, _ sdepth: Int32,
                            _ dst: UnsafeMutableRawPointer?, _ dstep: Int, _ ddepth: Int32,
                            _ w: Int32, _ h: Int32, _ cn: Int32,
                            _ ksize: Int32, _ scale: Double, _ delta: Double, _ border: Int32) -> Int32 {
    guard let src, let dst, w > 0, h > 0, cn > 0 else { return srFail(SRStatus.badArgument, "Laplacian: bad arguments") }
    return sr_c_np_laplacian(src, sstep, sdepth, dst, dstep, ddepth, w, h, cn, ksize, scale, delta, border) == 0
        ? SRStatus.ok : srFail(SRStatus.internalError, "Laplacian failed")
}
