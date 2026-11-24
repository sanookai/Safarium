// SafariumRaster — drawing core: painter, scanline coverage rasteriser, binary fills, thin lines.
//
// Area A (draw). Behaviour modelled on OpenCV imgproc drawing.cpp (Apache-2.0); algorithms re-written
// from scratch in Swift, no OpenCV code linked in. cv2 pixel convention: integer coordinate = pixel centre.
//
// Geometry lives in "cv2 coordinates" (pixel i centre = i). Edge sets store coordinates shifted by +0.5
// so pixel i covers [i, i+1) in raster space.

import Foundation

struct P { var x: Double; var y: Double }

// MARK: - Painter

/// Writes colour into a u8 / f32 image (1...4 channels), with clipping. One per draw call.
/// Records the pixel operations of one shape (used to cache translation-invariant AA circles; see DrawShapes.swift).
final class PatchRecorder {
    var spans: [Int32] = []          // y, x1, x2 triples
    var bx: [Int32] = [], by: [Int32] = []
    var ba: [Int32] = []
}

/// Element size in bytes per OpenCV depth code that cv2's drawing functions accept
/// (0 u8, 1 s8, 2 u16, 3 s16, 4 s32, 5 f32, 6 f64, 7 f16, 9 bool, 10 u64, 12 u32); nil = unsupported (cv2: "Bad argument").
func drawElemBytes(_ depth: Int32) -> Int? {
    switch depth {
    case 0, 1, 9: return 1
    case 2, 3, 7: return 2
    case 4, 5, 12: return 4
    case 6, 10: return 8
    default: return nil
    }
}

final class Painter {
    let rec: PatchRecorder?                 // `let`: no dynamic exclusivity check on the per-pixel path
    let base: UnsafeMutableRawPointer
    let stride: Int
    let w: Int, h: Int, c: Int
    let kind: Int32
    let isF32: Bool
    let isU8: Bool
    let pxBytes: Int
    let cu: UnsafeMutablePointer<UInt8>     // saturated colour for u8
    let cf: UnsafeMutablePointer<Float>     // colour as float (f32 images, and blend source for u8)
    private let mem: UnsafeMutableRawPointer
    let tpl: UnsafeMutablePointer<UInt8>    // one pixel of the colour in the image's own element type (all other depths)

    init?(data: UnsafeMutableRawPointer, w: Int, h: Int, stride: Int, c: Int, depth: Int32, _ col: (Double, Double, Double, Double), rec: PatchRecorder? = nil) {
        guard let eb = drawElemBytes(depth), c >= 1, c <= 4, w >= 0, h >= 0, stride >= w * c * eb else { return nil }
        self.rec = rec
        base = data; self.stride = stride
        self.w = w; self.h = h; self.c = c
        kind = depth
        isF32 = depth == 5
        isU8 = depth == 0
        pxBytes = c * eb
        mem = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)    // one block: tpl[32] | cf[4 floats] | cu[4]
        tpl = mem.assumingMemoryBound(to: UInt8.self)
        cf = (mem + 32).assumingMemoryBound(to: Float.self)
        cu = (mem + 48).assumingMemoryBound(to: UInt8.self)
        setColor(col)
    }

    convenience init?(_ img: SRImage, _ col: (Double, Double, Double, Double), rec: PatchRecorder? = nil) {
        guard img.depth == .u8 || img.depth == .f32 else { return nil }
        self.init(data: img.data, w: img.width, h: img.height, stride: img.stride, c: img.channels, depth: img.depth == .u8 ? 0 : 5, col, rec: rec)
    }

    deinit { mem.deallocate() }

    @inline(__always) func row(_ y: Int) -> UnsafeMutableRawPointer { base + y * stride }

    func setColor(_ col: (Double, Double, Double, Double)) {
        cu[0] = srSatU8(col.0); cu[1] = srSatU8(col.1); cu[2] = srSatU8(col.2); cu[3] = srSatU8(col.3)
        cf[0] = Float(col.0); cf[1] = Float(col.1); cf[2] = Float(col.2); cf[3] = Float(col.3)
        if isU8 || isF32 { return }
        let v = [col.0, col.1, col.2, col.3]
        let raw = UnsafeMutableRawPointer(tpl)
        for k in 0..<c {
            let x = v[k]
            switch kind {
            case 1: raw.storeBytes(of: Int8(truncatingIfNeeded: satRound(x, -128, 127)), toByteOffset: k, as: Int8.self)
            case 2: raw.storeBytes(of: UInt16(truncatingIfNeeded: satRound(x, 0, 65535)), toByteOffset: 2 * k, as: UInt16.self)
            case 3: raw.storeBytes(of: Int16(truncatingIfNeeded: satRound(x, -32768, 32767)), toByteOffset: 2 * k, as: Int16.self)
            case 4: raw.storeBytes(of: Int32(truncatingIfNeeded: satRound(x, -2147483648, 2147483647)), toByteOffset: 4 * k, as: Int32.self)
            case 6: raw.storeBytes(of: x, toByteOffset: 8 * k, as: Double.self)
            case 7: raw.storeBytes(of: Float16(x), toByteOffset: 2 * k, as: Float16.self)
            case 9: raw.storeBytes(of: x != 0 ? UInt8(1) : UInt8(0), toByteOffset: k, as: UInt8.self)
            case 10: raw.storeBytes(of: x.isNaN ? 0 : (x <= 0 ? 0 : (x >= 18446744073709551615.0 ? UInt64.max : UInt64(x.rounded(.toNearestOrEven)))), toByteOffset: 8 * k, as: UInt64.self)
            default: raw.storeBytes(of: UInt32(truncatingIfNeeded: satRound(x, 0, 4294967295)), toByteOffset: 4 * k, as: UInt32.self)   // 12
            }
        }
    }

    /// Opaque horizontal span, inclusive, clipped.
    @inline(__always) func span(_ y: Int, _ xa: Int, _ xb: Int) {
        if let rec { rec.spans.append(Int32(y)); rec.spans.append(Int32(xa)); rec.spans.append(Int32(xb)); return }
        if y < 0 || y >= h { return }
        let x0 = max(xa, 0), x1 = min(xb, w - 1)
        if x0 > x1 { return }
        if isF32 {
            let base = row(y).assumingMemoryBound(to: Float.self) + x0 * c
            for i in 0..<((x1 - x0 + 1) * c) { base[i] = cf[i % c] }
        } else if !isU8 {
            var p = row(y) + x0 * pxBytes
            for _ in x0...x1 { memcpy(p, tpl, pxBytes); p += pxBytes }
        } else {
            let base = row(y).assumingMemoryBound(to: UInt8.self) + x0 * c
            if c == 1 {
                memset(base, Int32(cu[0]), x1 - x0 + 1)
            } else if c == 3 {
                let a = cu[0], b = cu[1], d = cu[2]
                var p = base
                for _ in x0...x1 { p[0] = a; p[1] = b; p[2] = d; p += 3 }
            } else {
                var p = base
                for _ in x0...x1 { for k in 0..<c { p[k] = cu[k] }; p += c }
            }
        }
    }

    @inline(__always) func pixel(_ x: Int, _ y: Int) {
        if x < 0 || y < 0 || x >= w || y >= h { return }
        if isU8 && rec == nil {
            let p = (base + y * stride).assumingMemoryBound(to: UInt8.self) + x * c
            if c == 3 { p[0] = cu[0]; p[1] = cu[1]; p[2] = cu[2] }
            else if c == 1 { p[0] = cu[0] }
            else { for k in 0..<c { p[k] = cu[k] } }
            return
        }
        span(y, x, x)
    }
}

// MARK: - Edge sets and sweep

struct Edge { var x0: Double; var y0: Double; var y1: Double; var slope: Double; var dir: Int32 }

struct EdgeSet {
    var edges: [Edge] = []
    var evenOdd: Bool
    var minX = Double.infinity, minY = Double.infinity
    var maxX = -Double.infinity, maxY = -Double.infinity
    init(evenOdd: Bool) { self.evenOdd = evenOdd }

    /// `normalize` makes the polygon positively oriented so a non-zero winding union of several polygons works.
    mutating func addPoly(_ p: [P], normalize: Bool = false, shift: Double = 0.5) {
        let n = p.count
        if n < 3 { return }
        var rev = false
        if normalize {
            var area = 0.0
            for i in 0..<n { let a = p[i], b = p[(i + 1) % n]; area += a.x * b.y - b.x * a.y }
            rev = area < 0
        }
        for i in 0..<n {
            var a = p[i], b = p[(i + 1) % n]
            if rev { swap(&a, &b) }
            a.x += shift; a.y += shift; b.x += shift; b.y += shift
            minX = min(minX, min(a.x, b.x)); maxX = max(maxX, max(a.x, b.x))
            minY = min(minY, min(a.y, b.y)); maxY = max(maxY, max(a.y, b.y))
            if a.y == b.y { continue }
            if a.y < b.y {
                edges.append(Edge(x0: a.x, y0: a.y, y1: b.y, slope: (b.x - a.x) / (b.y - a.y), dir: 1))
            } else {
                edges.append(Edge(x0: b.x, y0: b.y, y1: a.y, slope: (a.x - b.x) / (a.y - b.y), dir: -1))
            }
        }
    }
}

struct Sweeper {
    let edges: [Edge]
    let order: [Int32]
    let evenOdd: Bool
    var next = 0
    var active: [Int32] = []
    var xs: [Double] = []
    var ds: [Int32] = []

    init(_ s: EdgeSet) {
        edges = s.edges
        evenOdd = s.evenOdd
        let e = s.edges
        order = (0..<e.count).sorted { e[$0].y0 < e[$1].y0 }.map { Int32($0) }
        active.reserveCapacity(64); xs.reserveCapacity(64); ds.reserveCapacity(64)
    }

    /// Emits covered x-intervals [xa, xb) of the sample line `ys` (raster space).
    mutating func spans(_ ys: Double, _ emit: (Double, Double) -> Void) {
        while next < order.count && edges[Int(order[next])].y0 <= ys {
            active.append(order[next]); next += 1
        }
        xs.removeAll(keepingCapacity: true); ds.removeAll(keepingCapacity: true)
        var i = 0
        while i < active.count {
            let e = edges[Int(active[i])]
            if e.y1 <= ys {
                active[i] = active[active.count - 1]; active.removeLast(); continue
            }
            let x = e.x0 + (ys - e.y0) * e.slope
            // insertion sort
            var j = xs.count
            xs.append(x); ds.append(e.dir)
            while j > 0 && xs[j - 1] > x {
                xs[j] = xs[j - 1]; ds[j] = ds[j - 1]; j -= 1
            }
            xs[j] = x; ds[j] = e.dir
            i += 1
        }
        if xs.count < 2 { return }
        if evenOdd {
            var k = 0
            while k + 1 < xs.count { emit(xs[k], xs[k + 1]); k += 2 }
        } else {
            var wnd: Int32 = 0
            var start = 0.0
            for k in 0..<xs.count {
                let prev = wnd
                wnd += ds[k]
                if prev == 0 && wnd != 0 { start = xs[k] }
                else if prev != 0 && wnd == 0 { emit(start, xs[k]) }
            }
        }
    }
}

// MARK: - Binary (non anti-aliased) fills

/// Midpoint circle exactly as cv2's Circle() (shift 0, LINE_8, thickness 1 or filled).
func midpointCircle(_ pt: Painter, _ cx: Int, _ cy: Int, _ radius: Int, fill: Bool) {
    if cx + radius < 0 || cx - radius >= pt.w || cy + radius < 0 || cy - radius >= pt.h { return }
    var err = 0, dx = radius, dy = 0, plus = 1, minus = (radius << 1) - 1
    while dx >= dy {
        let y11 = cy - dy, y12 = cy + dy, y21 = cy - dx, y22 = cy + dx
        let x11 = cx - dx, x12 = cx + dx, x21 = cx - dy, x22 = cx + dy
        if fill {
            pt.span(y11, x11, x12); pt.span(y12, x11, x12)
            pt.span(y21, x21, x22); pt.span(y22, x21, x22)
        } else {
            pt.pixel(x11, y11); pt.pixel(x12, y11); pt.pixel(x11, y12); pt.pixel(x12, y12)
            pt.pixel(x21, y21); pt.pixel(x22, y21); pt.pixel(x21, y22); pt.pixel(x22, y22)
        }
        dy += 1
        err += plus
        plus += 2
        // cv2: mask = (err <= 0) - 1  ->  0 when err <= 0, -1 otherwise
        let m = err <= 0 ? 0 : -1
        err -= minus & m
        dx += m
        minus -= m & 2
    }
}

// MARK: - LineAA (OpenCV imgproc drawing.cpp LineAA, re-derived)

// Per-column filter taps and slope correction of cv2's anti-aliased line. The 96 tap weights (centre / first / last tap for
// the 32 sub-pixel positions) and the 32-entry slope table were recovered by measuring OpenCV 5.1 output on 8-bit images
// (every interior pixel of random lines is reproduced exactly); the end-point correction follows the same measurements.
// Blending: two successive v += ((colour - v) * a + 127) >> 8 per channel.
private let aaFilter: UnsafeMutablePointer<Int> = {
    let v: [Int] = [168, 177, 185, 194, 202, 210, 218, 224, 231, 236, 241, 246, 249, 252, 254, 254, 254, 254, 252, 249, 246, 241, 236, 231, 224, 218, 210, 202, 194, 185, 177, 168, 158, 149, 140, 131, 122, 114, 105, 97, 89, 82, 75, 68, 62, 56, 50, 45, 40, 36, 32, 28, 25, 22, 19, 16, 14, 12, 11, 9, 8, 7, 5, 5, 5, 5, 7, 8, 9, 11, 12, 14, 16, 19, 22, 25, 28, 32, 36, 40, 45, 50, 56, 62, 68, 75, 82, 89, 97, 105, 114, 122, 131, 140, 149, 158]
    let p = UnsafeMutablePointer<Int>.allocate(capacity: v.count)
    for i in 0..<v.count { p[i] = v[i] }
    return p
}()
private let aaSlopeCorr: UnsafeMutablePointer<Int> = {
    let v: [Int] = [181, 181, 181, 182, 182, 183, 184, 185, 187, 188, 190, 192, 194, 196, 198, 201, 203, 206, 209, 211, 214, 218, 221, 224,
                    227, 231, 235, 238, 242, 246, 250, 254]
    let p = UnsafeMutablePointer<Int>.allocate(capacity: v.count)
    for i in 0..<v.count { p[i] = v[i] }
    return p
}()

extension Painter {
    /// One AA tap: both blends of cv2's ICV_PUT_POINT (a in 0...~256). Recorded instead of drawn when `rec` is set.
    @inline(__always) func aaTap(_ x: Int, _ y: Int, _ a: Int) {
        if x < 0 || y < 0 || x >= w || y >= h || a == 0 { return }
        if let rec { rec.bx.append(Int32(x)); rec.by.append(Int32(y)); rec.ba.append(Int32(a)); return }
        let p = (base + y * stride).assumingMemoryBound(to: UInt8.self) + x * c
        if c == 3 {
            var v0 = Int(p[0]), v1 = Int(p[1]), v2 = Int(p[2])
            let c0 = Int(cu[0]), c1 = Int(cu[1]), c2 = Int(cu[2])
            v0 += ((c0 - v0) * a + 127) >> 8; v1 += ((c1 - v1) * a + 127) >> 8; v2 += ((c2 - v2) * a + 127) >> 8
            v0 += ((c0 - v0) * a + 127) >> 8; v1 += ((c1 - v1) * a + 127) >> 8; v2 += ((c2 - v2) * a + 127) >> 8
            p[0] = UInt8(truncatingIfNeeded: v0); p[1] = UInt8(truncatingIfNeeded: v1); p[2] = UInt8(truncatingIfNeeded: v2)
            return
        }
        for k in 0..<c {
            var v = Int(p[k])
            let col = Int(cu[k])
            v += ((col - v) * a + 127) >> 8
            v += ((col - v) * a + 127) >> 8
            p[k] = UInt8(truncatingIfNeeded: v)
        }
    }
}

@inline(__always) private func epAt(_ t: (Int, Int, Int, Int, Int, Int, Int, Int, Int), _ i: Int) -> Int {
    switch i {
    case 0: return t.0
    case 1: return t.1
    case 2: return t.2
    case 3: return t.3
    case 4: return t.4
    case 5: return t.5
    case 6: return t.6
    case 7: return t.7
    default: return t.8
    }
}

/// cv2::LineAA for fixed-point (16 fractional bits) end points. 8-bit images with 1, 3 or 4 channels only; anything else
/// falls back to the plain 8-connected line like cv2. `skip` (optional) lists per row [x1, x2] spans (from `skipY0`) that a later
/// opaque fill overwrites anyway.
func lineAA(_ pt: Painter, _ a: FP, _ b: FP, skip: UnsafePointer<Int32>? = nil, skipY0: Int = 0, skipRows: Int = 0) {
    guard pt.isU8 && (pt.c == 1 || pt.c == 3 || pt.c == 4) else {
        lineIter(pt, FP(x: a.x >> 16, y: a.y >> 16), FP(x: b.x >> 16, y: b.y >> 16), connectivity: 8)
        return
    }
    var p1 = a, p2 = b
    if !clipLine64(Int64(pt.w) << 16, Int64(pt.h) << 16, &p1, &p2) { return }
    var dx = p2.x - p1.x, dy = p2.y - p1.y
    var j: Int64 = dx < 0 ? -1 : 0
    let ax = (dx ^ j) - j
    var i: Int64 = dy < 0 ? -1 : 0
    let ay = (dy ^ i) - i
    let one: Int64 = 1 << 16
    let xMajor = ax > ay
    var step: Int64, ecount: Int, slope: Int
    var i7: Int, j7: Int
    if xMajor {
        dy = (dy ^ j) - j
        if j != 0 { swap(&p1, &p2) }
        step = (dy << 16) / (ax | 1)
        p2.x += one
        ecount = Int((p2.x >> 16) - (p1.x >> 16))
        j = -(p1.x & (one - 1))
        p1.y += ((step * j) >> 16) + (one >> 1)
        slope = Int((step >> 11) & 0x3f)
        if step < 0 { slope ^= 0x3f }
        i7 = Int((p1.x >> 9) & 0x78); j7 = Int((p2.x >> 9) & 0x78)
    } else {
        dx = (dx ^ i) - i
        if i != 0 { swap(&p1, &p2) }
        step = (dx << 16) / (ay | 1)
        p2.y += one
        ecount = Int((p2.y >> 16) - (p1.y >> 16))
        i = -(p1.y & (one - 1))
        p1.x += ((step * i) >> 16) + (one >> 1)
        slope = Int((step >> 11) & 0x3f)
        if step < 0 { slope ^= 0x3f }
        i7 = Int((p1.y >> 9) & 0x78); j7 = Int((p2.y >> 9) & 0x78)
    }
    slope = (slope & 0x20) != 0 ? 0x100 : aaSlopeCorr[slope]
    // end point correction table
    let t0 = slope << 7
    let t1 = ((0x78 - i7) | 4) * slope
    let t2 = (j7 | 4) * slope
    var ep = (0, 0, 0, 0, 0, 0, 0, 0, 0)
    ep.0 = 0
    ep.8 = slope
    ep.1 = (((((j7 - i7) & 0x78) | 4) * slope) >> 8) & 0x1ff
    ep.3 = ep.1
    ep.2 = (t1 >> 8) & 0x1ff
    ep.4 = ((t0 + ((j7 - i7) | 4) * slope) >> 8) & 0x1ff
    ep.5 = ((t0 + t1) >> 8) & 0x1ff
    ep.6 = (t2 >> 8) & 0x1ff
    ep.7 = ((t0 + t2) >> 8) & 0x1ff
    let tabC = aaFilter, tabA = aaFilter + 32, tabB = aaFilter + 64
    var sc = 0
    let W = pt.w, H = pt.h
    @inline(__always) func skipped(_ x: Int, _ y: Int) -> Bool {
        guard let skip, y >= skipY0, y < skipY0 + skipRows else { return false }
        let k = 2 * (y - skipY0)
        return x >= Int(skip[k]) && x <= Int(skip[k + 1])
    }
    // Fast path: every tap of every column is inside the image and nothing is recorded -> unchecked pointer writes (+ optional skip test)
    if pt.rec == nil {
        let cnt = ecount + 1
        let a0 = xMajor ? Int(p1.x >> 16) : Int(p1.y >> 16)
        let m0 = xMajor ? Int(p1.y >> 16) : Int(p1.x >> 16)
        let m1 = xMajor ? Int((p1.y + step * Int64(ecount)) >> 16) : Int((p1.x + step * Int64(ecount)) >> 16)
        let majN = xMajor ? W : H, minN = xMajor ? H : W
        if a0 >= 0 && a0 + cnt <= majN && min(m0, m1) - 1 >= 0 && max(m0, m1) + 1 < minN {
            let c = pt.c, st = pt.stride
            let colStep = xMajor ? c : st            // along the major axis
            let tapStep = xMajor ? st : c            // across it
            var cur = Int64(xMajor ? p1.y : p1.x)
            var q = pt.base.assumingMemoryBound(to: UInt8.self) + (xMajor ? (a0 * c + (Int(cur >> 16) - 1) * st) : (a0 * st + (Int(cur >> 16) - 1) * c))
            let col0 = Int(pt.cu[0])
            let colV = SIMD4<Int32>(Int32(pt.cu[0]), Int32(pt.cu[1]), Int32(pt.cu[2]), 0)
            @inline(__always) func put(_ p: UnsafeMutablePointer<UInt8>, _ a: Int) {
                if a == 0 { return }
                if c == 3 {
                    var v = SIMD4<Int32>(Int32(p[0]), Int32(p[1]), Int32(p[2]), 0)
                    let a32 = Int32(a)
                    v &+= ((colV &- v) &* a32 &+ 127) &>> 8
                    v &+= ((colV &- v) &* a32 &+ 127) &>> 8
                    p[0] = UInt8(truncatingIfNeeded: v[0]); p[1] = UInt8(truncatingIfNeeded: v[1]); p[2] = UInt8(truncatingIfNeeded: v[2])
                } else if c == 1 {
                    var v0 = Int(p[0])
                    v0 += ((col0 - v0) * a + 127) >> 8
                    v0 += ((col0 - v0) * a + 127) >> 8
                    p[0] = UInt8(truncatingIfNeeded: v0)
                } else {
                    for k in 0..<c {
                        var v = Int(p[k]); let cl = Int(pt.cu[k])
                        v += ((cl - v) * a + 127) >> 8; v += ((cl - v) * a + 127) >> 8
                        p[k] = UInt8(truncatingIfNeeded: v)
                    }
                }
            }
            var n = ecount
            // interior columns all use the plain slope factor: tabulate the three taps once per call
            let useTbl = cnt > 48                       // tiny lines (caps, hairline polygons) do not pay for the table
            withUnsafeTemporaryAllocation(of: Int.self, capacity: 96) { buf in
            let tbl = buf.baseAddress!
            if useTbl { for j in 0..<32 { tbl[j] = (slope * tabA[j]) >> 8; tbl[32 + j] = (slope * tabC[j]) >> 8; tbl[64 + j] = (slope * tabB[j]) >> 8 } }
            var colIdx = a0
            let hasSkip = skip != nil
            while n >= 0 {
                let jj = Int((cur >> 11) & 31)
                var a0t: Int, a1t: Int, a2t: Int
                if useTbl && sc >= 2 && n >= 2 { a0t = tbl[jj]; a1t = tbl[32 + jj]; a2t = tbl[64 + jj] }
                else {
                    let e = (sc >= 2 && n >= 2) ? slope : epAt(ep, 3 * min(sc, 2) + min(n, 2))
                    a0t = (e * tabA[jj]) >> 8; a1t = (e * tabC[jj]) >> 8; a2t = (e * tabB[jj]) >> 8
                }
                if hasSkip {
                    let r0 = Int(cur >> 16) - 1
                    if xMajor {
                        if skipped(colIdx, r0) { a0t = 0 }; if skipped(colIdx, r0 + 1) { a1t = 0 }; if skipped(colIdx, r0 + 2) { a2t = 0 }
                    } else {
                        if skipped(r0, colIdx) { a0t = 0 }; if skipped(r0 + 1, colIdx) { a1t = 0 }; if skipped(r0 + 2, colIdx) { a2t = 0 }
                    }
                }
                put(q, a0t); put(q + tapStep, a1t); put(q + 2 * tapStep, a2t)
                colIdx += 1
                let oldRow = Int(cur >> 16)
                cur += step
                q += colStep + (Int(cur >> 16) - oldRow) * tapStep
                sc += 1; n -= 1
            }
            }
            return
        }
    }
    if xMajor {
        var x = Int(p1.x >> 16)
        var Y = p1.y
        while ecount >= 0 {
            if x >= 0 && x < W {
                let y = Int(Y >> 16) - 1
                let jj = Int((Y >> 11) & 31)
                let e = epAt(ep, 3 * min(sc, 2) + min(ecount, 2))
                if y >= 0 && y < H && !skipped(x, y) { pt.aaTap(x, y, (e * tabA[jj]) >> 8) }
                if y + 1 >= 0 && y + 1 < H && !skipped(x, y + 1) { pt.aaTap(x, y + 1, (e * tabC[jj]) >> 8) }
                if y + 2 >= 0 && y + 2 < H && !skipped(x, y + 2) { pt.aaTap(x, y + 2, (e * tabB[jj]) >> 8) }
            }
            x += 1; Y += step; sc += 1; ecount -= 1
        }
    } else {
        var y = Int(p1.y >> 16)
        var X = p1.x
        while ecount >= 0 {
            if y >= 0 && y < H {
                let x = Int(X >> 16) - 1
                let jj = Int((X >> 11) & 31)
                let e = epAt(ep, 3 * min(sc, 2) + min(ecount, 2))
                if x >= 0 && x < W && !skipped(x, y) { pt.aaTap(x, y, (e * tabA[jj]) >> 8) }
                if x + 1 >= 0 && x + 1 < W && !skipped(x + 1, y) { pt.aaTap(x + 1, y, (e * tabC[jj]) >> 8) }
                if x + 2 >= 0 && x + 2 < W && !skipped(x + 2, y) { pt.aaTap(x + 2, y, (e * tabB[jj]) >> 8) }
            }
            y += 1; X += step; sc += 1; ecount -= 1
        }
    }
}

/// saturate_cast<int-like>(double): round to nearest even, then clamp (NaN -> 0).
@inline(__always) func satRound(_ v: Double, _ lo: Double, _ hi: Double) -> Int64 {
    if v.isNaN { return 0 }
    return Int64(min(max(v.rounded(.toNearestOrEven), lo), hi))
}
