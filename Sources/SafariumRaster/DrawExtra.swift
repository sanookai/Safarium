// SafariumRaster — the rest of the cv2 5.1 drawing family: arrowedLine, drawMarker, drawContours, ellipse2Poly.
//
// Area A (draw), phase 7. Behaviour modelled on OpenCV imgproc drawing.cpp (Apache-2.0), re-written in Swift.

import Foundation

// MARK: - arrowedLine

@_cdecl("sr_draw_arrowedline")
public func sr_draw_arrowedline(_ data: UnsafeMutableRawPointer?, _ w: Int32, _ h: Int32, _ stride: Int32, _ ch: Int32, _ depth: Int32,
                                _ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32, _ color: UnsafePointer<Double>?,
                                _ thickness: Int32, _ lineType: Int32, _ shift: Int32, _ tipLength: Double) -> Int32 {
    guard let (pt, aa, lt) = makePainter(data, w, h, stride, ch, depth, color, lineType, shift, "arrowedLine") else { return SRStatus.badArgument }
    // norm(pt1 - pt2): the Point subtraction is done in int32 (wraps), the norm in double
    let ddx = Double(x0 &- x1), ddy = Double(y0 &- y1)
    let tipSize = (ddx * ddx + ddy * ddy).squareRoot() * tipLength
    var rc = drawLineCore(pt, aa, lt, x0, y0, x1, y1, thickness, shift, "arrowedLine")
    if rc != SRStatus.ok { return rc }
    let angle = atan2(Double(y0) - Double(y1), Double(x0) - Double(x1))
    for sgn in [1.0, -1.0] {
        let px = satInt32((Double(x1) + tipSize * cos(angle + sgn * Double.pi / 4)).rounded(.toNearestOrEven))
        let py = satInt32((Double(y1) + tipSize * sin(angle + sgn * Double.pi / 4)).rounded(.toNearestOrEven))
        rc = drawLineCore(pt, aa, lt, Int32(truncatingIfNeeded: px), Int32(truncatingIfNeeded: py), x1, y1, thickness, shift, "arrowedLine")
        if rc != SRStatus.ok { return rc }
    }
    return SRStatus.ok
}

// MARK: - drawMarker

@_cdecl("sr_draw_marker")
public func sr_draw_marker(_ data: UnsafeMutableRawPointer?, _ w: Int32, _ h: Int32, _ stride: Int32, _ ch: Int32, _ depth: Int32,
                           _ x: Int32, _ y: Int32, _ color: UnsafePointer<Double>?, _ markerType: Int32, _ markerSize: Int32,
                           _ thickness: Int32, _ lineType: Int32) -> Int32 {
    guard let (pt, aa, lt) = makePainter(data, w, h, stride, ch, depth, color, lineType, 0, "drawMarker") else { return SRStatus.badArgument }
    let m = markerSize / 2
    func ln(_ ax: Int32, _ ay: Int32, _ bx: Int32, _ by: Int32) -> Int32 {
        drawLineCore(pt, aa, lt, ax, ay, bx, by, thickness, 0, "drawMarker")
    }
    let l = x &- m, r = x &+ m, t = y &- m, b = y &+ m
    var rc = SRStatus.ok
    func all(_ calls: [() -> Int32]) { for c in calls where rc == SRStatus.ok { rc = c() } }
    switch markerType {
    case 0: all([{ ln(l, y, r, y) }, { ln(x, t, x, b) }])                                                   // MARKER_CROSS
    case 1: all([{ ln(l, t, r, b) }, { ln(r, t, l, b) }])                                                   // MARKER_TILTED_CROSS
    case 2: all([{ ln(l, y, r, y) }, { ln(x, t, x, b) }, { ln(l, t, r, b) }, { ln(r, t, l, b) }])           // MARKER_STAR
    case 3: all([{ ln(x, t, r, y) }, { ln(r, y, x, b) }, { ln(x, b, l, y) }, { ln(l, y, x, t) }])           // MARKER_DIAMOND
    case 4: all([{ ln(l, t, r, t) }, { ln(r, t, r, b) }, { ln(r, b, l, b) }, { ln(l, b, l, t) }])           // MARKER_SQUARE
    case 5: all([{ ln(l, b, r, b) }, { ln(r, b, x, t) }, { ln(x, t, l, b) }])                               // MARKER_TRIANGLE_UP
    case 6: all([{ ln(l, t, r, t) }, { ln(r, t, x, b) }, { ln(x, b, l, t) }])                               // MARKER_TRIANGLE_DOWN
    default: all([{ ln(l, y, r, y) }, { ln(x, t, x, b) }])                                                  // unknown: cross
    }
    return rc
}

// MARK: - ellipse2Poly

/// cv::ellipse2Poly(Point, Size, ...): rounds the Point2d result, drops consecutive duplicates, a single point becomes 2 x centre.
/// Returns the number of points written (cap >= 2 * (360 + 3) is always enough), or < 0 on error.
@_cdecl("sr_ellipse2poly")
public func sr_ellipse2poly(_ cx: Int32, _ cy: Int32, _ axX: Int32, _ axY: Int32, _ angle: Int32, _ start: Int32, _ end: Int32,
                            _ delta: Int32, _ out: UnsafeMutablePointer<Int32>?, _ cap: Int32) -> Int32 {
    guard delta > 0 && delta <= 180 else { return srFail(SRStatus.badArgument, "ellipse2Poly: 0 < delta && delta <= 180") }
    guard let out else { return srFail(SRStatus.badArgument, "ellipse2Poly: null output") }
    let poly = ellipsePolyD(Double(cx), Double(cy), Double(axX), Double(axY), angle: Int(angle), start: Int(start), end: Int(end), delta: Int(delta))
    var n = 0
    var px = Int.min, py = Int.min
    for p in poly {
        let x = satInt32(p.x), y = satInt32(p.y)
        if x == px && y == py { continue }
        if (n + 1) * 2 > Int(cap) { return srFail(SRStatus.badArgument, "ellipse2Poly: output too small") }
        out[2 * n] = Int32(truncatingIfNeeded: x); out[2 * n + 1] = Int32(truncatingIfNeeded: y)
        n += 1; px = x; py = y
    }
    if n == 1 {
        if 4 > Int(cap) { return srFail(SRStatus.badArgument, "ellipse2Poly: output too small") }
        out[2] = cx; out[3] = cy; out[0] = cx; out[1] = cy; n = 2
    }
    return Int32(n)
}

// MARK: - drawContours

/// cv::drawContours. `hier` = n x 4 int32 (next, prev, first child, parent) or nil. maxLevel as in cv2 5.1: 0 = only the
/// selected contour(s) with no hierarchy walk, 1 = contour + its direct children, 2 = + grandchildren, ... (INT_MAX = all).
/// thickness < 0 fills (all drawn contours go through one even-odd edge collection, so holes work).
@_cdecl("sr_draw_contours")
public func sr_draw_contours(_ data: UnsafeMutableRawPointer?, _ w: Int32, _ h: Int32, _ stride: Int32, _ ch: Int32, _ depth: Int32,
                             _ xy: UnsafePointer<Int32>?, _ counts: UnsafePointer<Int32>?, _ n: Int32, _ hier: UnsafePointer<Int32>?,
                             _ contourIdx: Int32, _ color: UnsafePointer<Double>?, _ thickness: Int32, _ lineType: Int32,
                             _ maxLevel: Int32, _ offX: Int32, _ offY: Int32) -> Int32 {
    guard let (pt, aa, lt) = makePainter(data, w, h, stride, ch, depth, color, lineType, 0, "drawContours") else { return SRStatus.badArgument }
    if thickness > 32767 { return srFail(SRStatus.badArgument, "drawContours: thickness must be <= 32767") }
    guard n >= 0, n == 0 || (xy != nil && counts != nil) else { return srFail(SRStatus.badArgument, "drawContours: bad contours") }
    if n == 0 { return SRStatus.ok }
    let nn = Int(n)
    var start = [Int](repeating: 0, count: nn + 1)
    for i in 0..<nn {
        guard counts![i] >= 0 else { return srFail(SRStatus.badArgument, "drawContours: negative point count") }
        start[i + 1] = start[i] + Int(counts![i])
    }
    var first = 0, last = nn
    if contourIdx >= 0 {
        guard Int(contourIdx) < nn else { return srFail(SRStatus.badArgument, "drawContours: 0 <= contourIdx && contourIdx < ncontours") }
        first = Int(contourIdx); last = first + 1
    }
    // visiting order
    var order: [Int] = []
    if hier == nil || maxLevel == 0 {
        order = Array(first..<last)
    } else {
        // cv2 5.1 walks the hierarchy by absolute depth: contourIdx < 0 starts at every root (parent < 0) in index order,
        // contourIdx >= 0 at that contour (depth counted through its parent chain); descend through first-child / next links
        // while depth <= maxLevel. Siblings of the starting contour are never drawn.
        func link(_ i: Int, _ k: Int) -> Int? { let v = Int(hier![4 * i + k]); return v >= 0 && v < nn ? v : nil }
        let limit = Int(maxLevel)
        var budget = 4 * nn + 8
        func walk(_ root: Int, _ level0: Int) {
            var stack: [(node: Int, level: Int)] = [(root, level0)]
            while let (node, level) = stack.popLast(), budget > 0 {
                budget -= 1
                if level > limit { continue }
                order.append(node)
                // push the children chain reversed so the first child is visited first
                var kids: [Int] = []
                var c = link(node, 2)
                var steps = 0
                while let cc = c, steps <= nn { kids.append(cc); c = link(cc, 0); steps += 1 }
                for k in kids.reversed() { stack.append((k, level + 1)) }
            }
        }
        if contourIdx >= 0 {
            var depth = 0, cur = first, steps = 0
            while let p = link(cur, 3), steps <= nn { depth += 1; cur = p; steps += 1 }
            walk(first, depth)
        } else {
            for i in 0..<nn where hier![4 * i + 3] < 0 { walk(i, 0) }
        }
    }
    let ox = Int64(offX), oy = Int64(offY)
    var edges: [PolyEdge] = []
    for ci in order {
        let m = Int(counts![ci])
        if m == 0 { continue }
        var v = [FP](); v.reserveCapacity(m)
        for j in 0..<m {
            v.append(FP(x: Int64(Int32(truncatingIfNeeded: Int64(xy![2 * (start[ci] + j)]) + ox)),
                        y: Int64(Int32(truncatingIfNeeded: Int64(xy![2 * (start[ci] + j) + 1]) + oy))))
        }
        if thickness >= 0 {
            for i in 0..<m { thickLine(pt, v[i], v[(i + 1) % m], thickness: Int(thickness), aa: aa, lineType: lt, flags: 2, shift: 0) }
        } else {
            collectPolyEdges(pt, v, &edges, shift: 0, aa: aa, lineType: lt, offX: 0, offY: 0)
        }
    }
    if thickness < 0 { fillEdgeCollection(pt, edges) }
    return SRStatus.ok
}
