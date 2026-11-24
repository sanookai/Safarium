// SafariumRaster — drawing shapes + C ABI (circle, rectangle, line, polylines, fillPoly, ellipse).
//
// Area A (draw). Geometry follows OpenCV imgproc drawing.cpp (Apache-2.0), re-written in Swift:
//  - ellipse2Poly step rule (90/30/18/5 degrees), thick lines = quads + round joins, AA shapes = fill + 1px AA outline.
//  - cv2 half-width for thickness t >= 2 is ceil(t/2) (non-AA pixels reach +-h inclusive; AA edges add ~0.72 px).
//  - AA on non-u8 images falls back to LINE_8 exactly like cv2.

import Foundation

let lineAA: Int32 = 16

// MARK: - geometry helpers

@inline(__always) func satInt32(_ v: Double) -> Int {
    if v.isNaN { return 0 }
    return Int(max(min(v.rounded(.toNearestOrEven), 2147483647), -2147483648))
}

/// cv2::ellipse2Poly on already-fixed-point input (center/axes in 1/65536 px, integer angles in degrees).
/// cv2 uses degree-indexed sine tables for ellipse2Poly; same here (0...360 plus headroom).
/// OpenCV's SinTable is a float table printed with 7 decimals; its cos is SinTable[90 - a].
private func tabSin(_ deg: Int) -> Double { Double(Float((sin(Double(deg) * Double.pi / 180) * 1e7).rounded() / 1e7)) }
private let sinTab: [Double] = (0...360).map { tabSin($0) }
private let cosTab: [Double] = (0...360).map { tabSin(90 - $0) }

func ellipsePolyD(_ cx: Double, _ cy: Double, _ ax: Double, _ ay: Double, angle: Int, start: Int, end: Int, delta: Int) -> [P] {
    var a0 = start, a1 = end
    var ang = ((angle % 360) + 360) % 360
    if a0 > a1 { swap(&a0, &a1) }
    if a1 - a0 <= 360 {
        let k = Int((Double(a0) / 360).rounded(.down))
        a0 -= 360 * k; a1 -= 360 * k          // a0 into 0..<360
        if a1 > 360 { a1 -= 360; a0 -= 360 }
    }
    if a1 - a0 > 360 { a0 = 0; a1 = 360 }
    ang = max(0, min(360, ang))
    let ca = cosTab[ang], sa = sinTab[ang]
    var out = [P]()
    out.reserveCapacity((a1 - a0) / max(delta, 1) + 3)
    var i = a0
    while i < a1 + delta {
        var a = i
        if a > a1 { a = a1 }
        if a < 0 { a += 360 }
        let ai = max(0, min(360, a))
        let x = ax * cosTab[ai], y = ay * sinTab[ai]
        out.append(P(x: cx + x * ca - y * sa, y: cy + x * sa + y * ca))
        i += delta
    }
    if out.count == 1 { out.append(out[0]) }
    return out
}

// MARK: - ABI helpers

func makePainter(_ data: UnsafeMutableRawPointer?, _ w: Int32, _ h: Int32, _ stride: Int32, _ ch: Int32, _ depth: Int32,
                         _ color: UnsafePointer<Double>?, _ lineType: Int32, _ shift: Int32, _ what: String)
    -> (Painter, Bool, Int)? {
    guard let data, w >= 0, h >= 0, ch >= 1, ch <= 4, let eb = drawElemBytes(depth), Int(stride) >= Int(w) * Int(ch) * eb else {
        _ = srFail(SRStatus.badArgument, "\(what): unsupported image (needs 1-4 channels of u8/s8/u16/s16/s32/u32/u64/f16/f32/f64/bool)"); return nil
    }
    guard w > 0 && h > 0 else {
        _ = srFail(SRStatus.badArgument, "\(what): Layout of the output array img is incompatible with cv::Mat (empty image)"); return nil
    }
    guard shift >= 0 && shift <= 16 else { _ = srFail(SRStatus.badArgument, "\(what): shift must be in 0...16"); return nil }
    guard let p = Painter(data: data, w: Int(w), h: Int(h), stride: Int(stride), c: Int(ch), depth: depth, srColor(color)) else {
        _ = srFail(SRStatus.unsupported, "\(what): unsupported image type"); return nil
    }
    // cv2: AA is only for 8-bit images; others silently use LINE_8
    let aa = lineType == lineAA && depth == 0
    return (p, aa, Int(lineType))
}

func fp(_ x: Int32, _ y: Int32) -> FP { FP(x: Int64(x), y: Int64(y)) }

// MARK: - circle

// MARK: - cached AA filled circles (the dot-grid pattern)

private struct CirclePatch {
    let spans: [Int32]
    let bx: [Int32], by: [Int32]
    let ba: [Int32]
}

nonisolated(unsafe) private var circleCache: [UInt64: CirclePatch] = [:]
private let circleCacheLock = NSLock()
private let patchBase = 64           // integer pixel at which patches are recorded

/// A filled anti-aliased circle's pixel operations depend only on (sub-pixel centre, radius, shift) up to an integer
/// translation, and not on the colour or the background. Record them once, replay them in order: bit-identical to
/// drawing the circle from scratch, but without redoing the geometry.
private func drawCircleAACached(_ pt: Painter, _ cx: Int32, _ cy: Int32, _ radius: Int32, _ shift: Int32) {
    let mask = Int32((1 << shift) - 1)
    let key = UInt64(shift) << 58 | UInt64(cx & mask) << 44 | UInt64(cy & mask) << 30 | UInt64(radius)
    circleCacheLock.lock()
    var patch = circleCache[key]
    circleCacheLock.unlock()
    if patch == nil {
        let rec = PatchRecorder()
        let dummy = SRImage(UnsafeMutableRawPointer(bitPattern: 16), 4096, 4096, 4096, 1, 0)!
        let rp = Painter(dummy, (0, 0, 0, 0), rec: rec)!
        let sh = Int64(XY_SHIFT) - Int64(shift)
        let c0x = (Int64(patchBase) << Int64(shift)) | Int64(cx & mask), c0y = (Int64(patchBase) << Int64(shift)) | Int64(cy & mask)
        ellipseEx(rp, FP(x: c0x << sh, y: c0y << sh), FP(x: Int64(radius) << sh, y: Int64(radius) << sh),
                  angle: 0, start: 0, end: 360, thickness: -1, aa: true, lineType: 16)
        patch = CirclePatch(spans: rec.spans, bx: rec.bx, by: rec.by, ba: rec.ba)
        circleCacheLock.lock()
        if circleCache.count > 8192 { circleCache.removeAll() }
        circleCache[key] = patch
        circleCacheLock.unlock()
    }
    let p = patch!
    let dx = Int(cx >> shift) - patchBase, dy = Int(cy >> shift) - patchBase
    p.spans.withUnsafeBufferPointer { sp in
        var i = 0
        while i < sp.count { pt.span(Int(sp[i]) + dy, Int(sp[i + 1]) + dx, Int(sp[i + 2]) + dx); i += 3 }
    }
    p.bx.withUnsafeBufferPointer { bx in p.by.withUnsafeBufferPointer { by in p.ba.withUnsafeBufferPointer { ba in
        for i in 0..<bx.count { pt.aaTap(Int(bx[i]) + dx, Int(by[i]) + dy, Int(ba[i])) }
    } } }
}

@inline(__always)
private func drawCircleCore(_ pt: Painter, _ aa: Bool, _ lt: Int, _ cx: Int32, _ cy: Int32, _ radius: Int32, _ thickness: Int32, _ shift: Int32) -> Int32 {
    if radius < 0 || thickness > 32767 { return srFail(SRStatus.badArgument, "circle: radius must be >= 0 and thickness <= 32767") }
    if aa && thickness < 0 && shift > 0 && (radius >> shift) <= 48 && (radius >> shift) >= 0 {
        drawCircleAACached(pt, cx, cy, radius, shift)
        return SRStatus.ok
    }
    if thickness > 1 || (lt != 8 && !(lt == 16 && !aa)) || shift > 0 || radius >= 1 << 16 {
        let sh = Int64(XY_SHIFT) - Int64(shift)
        ellipseEx(pt, FP(x: Int64(cx) << sh, y: Int64(cy) << sh), FP(x: Int64(radius) << sh, y: Int64(radius) << sh),
                  angle: 0, start: 0, end: 360, thickness: Int(thickness), aa: aa, lineType: lt)
    } else {
        midpointCircle(pt, Int(cx), Int(cy), Int(radius), fill: thickness < 0)
    }
    return SRStatus.ok
}

@_cdecl("sr_draw_circle")
public func sr_draw_circle(_ data: UnsafeMutableRawPointer?, _ w: Int32, _ h: Int32, _ stride: Int32, _ ch: Int32, _ depth: Int32,
                           _ cx: Int32, _ cy: Int32, _ radius: Int32, _ color: UnsafePointer<Double>?,
                           _ thickness: Int32, _ lineType: Int32, _ shift: Int32) -> Int32 {
    guard let (pt, aa, lt) = makePainter(data, w, h, stride, ch, depth, color, lineType, shift, "circle") else { return SRStatus.badArgument }
    return drawCircleCore(pt, aa, lt, cx, cy, radius, thickness, shift)
}

/// Batch of circles, identical to calling sr_draw_circle n times in order. `xyr` = n x (cx, cy, radius) int32;
/// `colors` = ncolors x 4 doubles (ncolors == 1: one colour for all, else must equal n).
@_cdecl("sr_draw_circles")
public func sr_draw_circles(_ data: UnsafeMutableRawPointer?, _ w: Int32, _ h: Int32, _ stride: Int32, _ ch: Int32, _ depth: Int32,
                            _ xyr: UnsafePointer<Int32>?, _ n: Int32, _ colors: UnsafePointer<Double>?, _ ncolors: Int32,
                            _ thickness: Int32, _ lineType: Int32, _ shift: Int32) -> Int32 {
    guard n >= 0, ncolors == 1 || ncolors == n, n == 0 || xyr != nil else { return srFail(SRStatus.badArgument, "circles: bad counts") }
    guard let (pt, aa, lt) = makePainter(data, w, h, stride, ch, depth, colors, lineType, shift, "circles") else { return SRStatus.badArgument }
    guard let xyr, n > 0 else { return SRStatus.ok }
    for i in 0..<Int(n) {
        if ncolors > 1, let colors { pt.setColor(srColor(colors + 4 * i)) }
        let rc = drawCircleCore(pt, aa, lt, xyr[3 * i], xyr[3 * i + 1], xyr[3 * i + 2], thickness, shift)
        if rc != SRStatus.ok { return rc }
    }
    return SRStatus.ok
}

// MARK: - ellipse

@_cdecl("sr_draw_ellipse")
public func sr_draw_ellipse(_ data: UnsafeMutableRawPointer?, _ w: Int32, _ h: Int32, _ stride: Int32, _ ch: Int32, _ depth: Int32,
                            _ cx: Int32, _ cy: Int32, _ axX: Int32, _ axY: Int32, _ angle: Double, _ startAngle: Double, _ endAngle: Double,
                            _ color: UnsafePointer<Double>?, _ thickness: Int32, _ lineType: Int32, _ shift: Int32) -> Int32 {
    guard let (pt, aa, lt) = makePainter(data, w, h, stride, ch, depth, color, lineType, shift, "ellipse") else { return SRStatus.badArgument }
    if axX < 0 || axY < 0 || thickness > 32767 { return srFail(SRStatus.badArgument, "ellipse: axes must be >= 0 and thickness <= 32767") }
    let sh = Int64(XY_SHIFT) - Int64(shift)
    ellipseEx(pt, FP(x: Int64(cx) << sh, y: Int64(cy) << sh), FP(x: Int64(axX) << sh, y: Int64(axY) << sh),
              angle: satInt32(angle), start: satInt32(startAngle), end: satInt32(endAngle), thickness: Int(thickness), aa: aa, lineType: lt)
    return SRStatus.ok
}

// MARK: - line

@_cdecl("sr_draw_line")
public func sr_draw_line(_ data: UnsafeMutableRawPointer?, _ w: Int32, _ h: Int32, _ stride: Int32, _ ch: Int32, _ depth: Int32,
                         _ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32, _ color: UnsafePointer<Double>?,
                         _ thickness: Int32, _ lineType: Int32, _ shift: Int32) -> Int32 {
    guard let (pt, aa, lt) = makePainter(data, w, h, stride, ch, depth, color, lineType, shift, "line") else { return SRStatus.badArgument }
    return drawLineCore(pt, aa, lt, x0, y0, x1, y1, thickness, shift)
}

/// cv::line on a prepared painter (also used by arrowedLine / drawMarker).
func drawLineCore(_ pt: Painter, _ aa: Bool, _ lt: Int, _ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32,
                  _ thickness: Int32, _ shift: Int32, _ what: String = "line") -> Int32 {
    if thickness <= 0 || thickness > 32767 { return srFail(SRStatus.badArgument, "\(what): thickness must be in 1...32767") }
    thickLine(pt, fp(x0, y0), fp(x1, y1), thickness: Int(thickness), aa: aa, lineType: lt, flags: 3, shift: Int(shift), lastOpen: true)
    return SRStatus.ok
}

// MARK: - rectangle

@_cdecl("sr_draw_rectangle")
public func sr_draw_rectangle(_ data: UnsafeMutableRawPointer?, _ w: Int32, _ h: Int32, _ stride: Int32, _ ch: Int32, _ depth: Int32,
                              _ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32, _ color: UnsafePointer<Double>?,
                              _ thickness: Int32, _ lineType: Int32, _ shift: Int32) -> Int32 {
    guard let (pt, aa, lt) = makePainter(data, w, h, stride, ch, depth, color, lineType, shift, "rectangle") else { return SRStatus.badArgument }
    if thickness > 32767 { return srFail(SRStatus.badArgument, "rectangle: thickness too large") }
    let v = [fp(x0, y0), fp(x1, y0), fp(x1, y1), fp(x0, y1)]
    if thickness >= 0 {
        polyLine(pt, v, closed: true, thickness: Int(thickness), aa: aa, lineType: lt, shift: Int(shift))
    } else {
        fillConvexPoly(pt, v, shift: Int(shift), aa: aa, lineType: lt)
    }
    return SRStatus.ok
}

// MARK: - polylines / fillPoly

private func readContours(_ xy: UnsafePointer<Int32>?, _ counts: UnsafePointer<Int32>?, _ n: Int32) -> [[FP]]? {
    var out = [[FP]]()
    guard let xy, let counts, n > 0 else { return out }
    for i in 0..<Int(n) where counts[i] < 0 { return nil }
    var k = 0
    for i in 0..<Int(n) {
        let m = Int(counts[i])
        var c = [FP](); c.reserveCapacity(m)
        for j in 0..<m { c.append(FP(x: Int64(xy[2 * (k + j)]), y: Int64(xy[2 * (k + j) + 1]))) }
        k += m
        out.append(c)
    }
    return out
}

@_cdecl("sr_draw_polylines")
public func sr_draw_polylines(_ data: UnsafeMutableRawPointer?, _ w: Int32, _ h: Int32, _ stride: Int32, _ ch: Int32, _ depth: Int32,
                              _ xy: UnsafePointer<Int32>?, _ counts: UnsafePointer<Int32>?, _ ncontours: Int32, _ isClosed: Int32,
                              _ color: UnsafePointer<Double>?, _ thickness: Int32, _ lineType: Int32, _ shift: Int32) -> Int32 {
    guard let (pt, aa, lt) = makePainter(data, w, h, stride, ch, depth, color, lineType, shift, "polylines") else { return SRStatus.badArgument }
    if thickness < 0 || thickness > 32767 { return srFail(SRStatus.badArgument, "polylines: thickness must be in 0...32767") }
    guard let cs = readContours(xy, counts, ncontours) else { return srFail(SRStatus.badArgument, "polylines: negative point count") }
    for c in cs {
        polyLine(pt, c, closed: isClosed != 0, thickness: Int(thickness), aa: aa, lineType: lt, shift: Int(shift))
    }
    return SRStatus.ok
}

@_cdecl("sr_draw_fillpoly")
public func sr_draw_fillpoly(_ data: UnsafeMutableRawPointer?, _ w: Int32, _ h: Int32, _ stride: Int32, _ ch: Int32, _ depth: Int32,
                             _ xy: UnsafePointer<Int32>?, _ counts: UnsafePointer<Int32>?, _ ncontours: Int32,
                             _ color: UnsafePointer<Double>?, _ lineType: Int32, _ shift: Int32,
                             _ offX: Int32, _ offY: Int32, _ convex: Int32) -> Int32 {
    guard let (pt, aa, lt) = makePainter(data, w, h, stride, ch, depth, color, lineType, shift, "fillPoly") else { return SRStatus.badArgument }
    guard let contours = readContours(xy, counts, ncontours) else { return srFail(SRStatus.badArgument, "fillPoly: negative point count") }
    if convex != 0 {
        if let c = contours.first { fillConvexPoly(pt, c, shift: Int(shift), aa: aa, lineType: lt) }
        return SRStatus.ok
    }
    var edges: [PolyEdge] = []
    for c in contours { collectPolyEdges(pt, c, &edges, shift: Int(shift), aa: aa, lineType: lt, offX: Int64(offX), offY: Int64(offY)) }
    fillEdgeCollection(pt, edges)
    return SRStatus.ok
}
