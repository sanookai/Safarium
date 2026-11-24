// SafariumRaster — fixed-point ports of OpenCV's non-AA drawing primitives (imgproc/src/drawing.cpp, Apache-2.0),
// re-written in Swift: clipLine, LineIterator (Bresenham, 8/4 connected), Line2 (fractional DDA), Circle (midpoint),
// FillConvexPoly, CollectPolyEdges + FillEdgeCollection, ThickLine, PolyLine, EllipseEx.
// Coordinates are Int64 fixed point with XY_SHIFT = 16 fractional bits, exactly like cv2, so non-AA output matches it
// pixel for pixel. The AA edge lines (cv2 LineAA) come from lineAA() in DrawCore.swift.

import Foundation

let XY_SHIFT = 16
let XY_ONE: Int64 = 1 << 16

struct FP { var x: Int64; var y: Int64 }

@inline(__always) func fxRound(_ v: Double) -> Int64 {
    if v.isNaN { return 0 }
    return Int64(max(min(v.rounded(.toNearestOrEven), 4.0e18), -4.0e18))
}

// MARK: - clipLine (Size2l version)

func clipLine64(_ width: Int64, _ height: Int64, _ p1: inout FP, _ p2: inout FP) -> Bool {
    let right = width - 1, bottom = height - 1
    if width <= 0 || height <= 0 { return false }
    func code(_ x: Int64, _ y: Int64) -> Int { (x < 0 ? 1 : 0) + (x > right ? 2 : 0) + (y < 0 ? 4 : 0) + (y > bottom ? 8 : 0) }
    var c1 = code(p1.x, p1.y), c2 = code(p2.x, p2.y)
    if (c1 & c2) == 0 && (c1 | c2) != 0 {
        var a: Int64
        if c1 & 12 != 0 {
            a = c1 < 8 ? 0 : bottom
            p1.x += Int64(Double(a - p1.y) * Double(p2.x - p1.x) / Double(p2.y - p1.y))
            p1.y = a
            c1 = (p1.x < 0 ? 1 : 0) + (p1.x > right ? 2 : 0)
        }
        if c2 & 12 != 0 {
            a = c2 < 8 ? 0 : bottom
            p2.x += Int64(Double(a - p2.y) * Double(p2.x - p1.x) / Double(p2.y - p1.y))
            p2.y = a
            c2 = (p2.x < 0 ? 1 : 0) + (p2.x > right ? 2 : 0)
        }
        if (c1 & c2) == 0 && (c1 | c2) != 0 {
            if c1 != 0 {
                a = c1 == 1 ? 0 : right
                p1.y += Int64(Double(a - p1.x) * Double(p2.y - p1.y) / Double(p2.x - p1.x))
                p1.x = a
                c1 = 0
            }
            if c2 != 0 {
                a = c2 == 1 ? 0 : right
                p2.y += Int64(Double(a - p2.x) * Double(p2.y - p1.y) / Double(p2.x - p1.x))
                p2.x = a
                c2 = 0
            }
        }
    }
    return (c1 | c2) == 0
}

// MARK: - Line (LineIterator, leftToRight = true)

func lineIter(_ pt: Painter, _ a: FP, _ b: FP, connectivity: Int) {
    var p1 = a, p2 = b
    let w = Int64(pt.w), h = Int64(pt.h)
    if p1.x < 0 || p1.x >= w || p1.y < 0 || p1.y >= h || p2.x < 0 || p2.x >= w || p2.y < 0 || p2.y >= h {
        if !clipLine64(w, h, &p1, &p2) { return }
    }
    var dx = p2.x - p1.x, dy = p2.y - p1.y
    if dx < 0 { dx = -dx; dy = -dy; swap(&p1, &p2) }   // leftToRight: start at the leftmost point
    var x = p1.x, y = p1.y
    let sy: Int64 = dy < 0 ? -1 : 1
    dy = abs(dy)
    let swapAxes = dy > dx
    if swapAxes { swap(&dx, &dy) }          // now dx = major length, dy = minor length
    // steps: major step / minor step in (x, y)
    let majX: Int64 = swapAxes ? 0 : 1, majY: Int64 = swapAxes ? sy : 0
    let minX: Int64 = swapAxes ? 1 : 0, minY: Int64 = swapAxes ? 0 : sy
    var err: Int64, plusDelta: Int64, minusDelta: Int64, count: Int64
    if connectivity == 8 {
        err = dx - 2 * dy; plusDelta = 2 * dx; minusDelta = -2 * dy; count = dx + 1
    } else {
        err = 0; plusDelta = 2 * dx + 2 * dy; minusDelta = -2 * dy; count = dx + dy + 1
    }
    if pt.isU8 && pt.rec == nil {
        // clipped end points are inside the image: step a pointer, no per-pixel bounds checks
        let c = pt.c, st = pt.stride
        let majStep = Int(majX) * c + Int(majY) * st, minStep = Int(minX) * c + Int(minY) * st
        var p = pt.base.assumingMemoryBound(to: UInt8.self) + Int(y) * st + Int(x) * c
        let cu = pt.cu
        let c0 = cu[0], c1 = cu[1], c2 = cu[2]
        var n = Int(count)
        let conn8 = connectivity == 8
        if conn8 && (c == 3 || c == 1) {
            var e = Int(err)
            let pl = Int(plusDelta), mi = Int(minusDelta)
            let both = majStep + minStep
            if c == 3 {
                while n > 0 {
                    p[0] = c0; p[1] = c1; p[2] = c2
                    if e < 0 { e += mi + pl; p += both } else { e += mi; p += majStep }
                    n -= 1
                }
            } else {
                while n > 0 {
                    p[0] = c0
                    if e < 0 { e += mi + pl; p += both } else { e += mi; p += majStep }
                    n -= 1
                }
            }
            return
        }
        while n > 0 {
            if c == 3 { p[0] = c0; p[1] = c1; p[2] = c2 } else if c == 1 { p[0] = c0 } else { for k in 0..<c { p[k] = cu[k] } }
            let neg = err < 0
            err += minusDelta + (neg ? plusDelta : 0)
            if conn8 { p += majStep; if neg { p += minStep } }
            else if neg { p += minStep } else { p += majStep }
            n -= 1
        }
        return
    }
    var i: Int64 = 0
    while i < count {
        pt.pixel(Int(x), Int(y))
        let neg = err < 0
        err += minusDelta + (neg ? plusDelta : 0)
        if connectivity == 8 {
            x += majX; y += majY
            if neg { x += minX; y += minY }
        } else if neg {
            x += minX; y += minY          // plusStep + minusStep = minor step only
        } else {
            x += majX; y += majY
        }
        i += 1
    }
}

// MARK: - Line2 (fractional endpoints, fixed point)

func line2(_ pt: Painter, _ a: FP, _ b: FP) {
    var p1 = a, p2 = b
    if !clipLine64(Int64(pt.w) << 16, Int64(pt.h) << 16, &p1, &p2) { return }
    var dx = p2.x - p1.x, dy = p2.y - p1.y
    let j: Int64 = dx < 0 ? -1 : 0
    let ax = (dx ^ j) - j
    let i: Int64 = dy < 0 ? -1 : 0
    let ay = (dy ^ i) - i
    var xStep: Int64, yStep: Int64, ecount: Int
    if ax > ay {
        dy = (dy ^ j) - j
        if j != 0 { swap(&p1, &p2) }
        xStep = XY_ONE
        yStep = dy * (1 << 16) / (ax | 1)
        ecount = Int((p2.x - p1.x) >> 16)
    } else {
        dx = (dx ^ i) - i
        if i != 0 { swap(&p1, &p2) }
        xStep = dx * (1 << 16) / (ay | 1)
        yStep = XY_ONE
        ecount = Int((p2.y - p1.y) >> 16)
    }
    p1.x += XY_ONE >> 1
    p1.y += XY_ONE >> 1
    pt.pixel(Int((p2.x + (XY_ONE >> 1)) >> 16), Int((p2.y + (XY_ONE >> 1)) >> 16))
    if ax > ay {
        var px = p1.x >> 16
        var py = p1.y
        while ecount >= 0 {
            pt.pixel(Int(px), Int(py >> 16))
            px += 1; py += yStep; ecount -= 1
        }
    } else {
        var py = p1.y >> 16
        var px = p1.x
        while ecount >= 0 {
            pt.pixel(Int(px >> 16), Int(py))
            px += xStep; py += 1; ecount -= 1
        }
    }
    _ = xStep
}

// MARK: - Circle (midpoint)

func circleMid(_ pt: Painter, _ cx: Int, _ cy: Int, _ radius: Int, fill: Bool) {
    midpointCircle(pt, cx, cy, radius, fill: fill)
}

// MARK: - FillConvexPoly

func fillConvexPoly(_ pt: Painter, _ v: [FP], shift: Int, aa: Bool, lineType: Int) {
    let npts = v.count
    if npts == 0 { return }
    let delta: Int64 = (Int64(1) << Int64(shift)) >> 1
    var imin = 0
    var edges = npts
    let delta1: Int64 = aa ? XY_ONE - 1 : XY_ONE >> 1
    let delta2: Int64 = aa ? 0 : XY_ONE >> 1
    let sh = Int64(XY_SHIFT - shift)
    var xmin = v[0].x, xmax = v[0].x, ymin = v[0].y, ymax = v[0].y

    /// cv2 draws the outline first (AA: LineAA hairlines, non-AA: Line/Line2). For AA we draw the hairlines AFTER the fill and
    /// skip pixels the fill already covers: blending the opaque colour over itself is a no-op, so the result is identical.
    func drawEdges(skip: UnsafePointer<Int32>?, skipY0: Int, skipRows: Int) {
        var p0 = FP(x: v[npts - 1].x << sh, y: v[npts - 1].y << sh)
        for i in 0..<npts {
            let p = FP(x: v[i].x << sh, y: v[i].y << sh)
            if !aa {
                if shift == 0 {
                    lineIter(pt, FP(x: p0.x >> 16, y: p0.y >> 16), FP(x: p.x >> 16, y: p.y >> 16), connectivity: lineType == 4 ? 4 : 8)
                } else {
                    line2(pt, p0, p)
                }
            } else {
                lineAA(pt, p0, p, skip: skip, skipY0: skipY0, skipRows: skipRows)
            }
            p0 = p
        }
    }

    for i in 0..<npts {
        let p = v[i]
        if p.y < ymin { ymin = p.y; imin = i }
        ymax = max(ymax, p.y); xmax = max(xmax, p.x); xmin = min(xmin, p.x)
    }
    xmin = (xmin + delta) >> Int64(shift); xmax = (xmax + delta) >> Int64(shift)
    ymin = (ymin + delta) >> Int64(shift); ymax = (ymax + delta) >> Int64(shift)
    let W = Int64(pt.w), H = Int64(pt.h)
    if npts < 3 || xmax < 0 || ymax < 0 || xmin >= W || ymin >= H {
        drawEdges(skip: nil, skipY0: 0, skipRows: 0)
        return
    }
    ymax = min(ymax, H - 1)

    struct E { var idx: Int; var di: Int; var ye: Int; var x: Int64; var dx: Int64 }
    func runFill(_ spans: UnsafeMutablePointer<Int32>?) {
        var e0 = E(idx: imin, di: 1, ye: Int(ymin), x: -XY_ONE, dx: 0)
        var e1 = E(idx: imin, di: npts - 1, ye: Int(ymin), x: -XY_ONE, dx: 0)
        var y = Int(ymin)
        let yMin = Int(ymin), yMax = Int(ymax)

        func step(_ e: inout E) {
            var idx0 = e.idx
            var idx = idx0 + e.di
            if idx >= npts { idx -= npts }
            while true {
                let more = edges > 0
                edges -= 1                       // C++: for (; edges-- > 0; ) leaves edges at -1 when exhausted
                if !more { break }
                let ty = Int((v[idx].y + delta) >> Int64(shift))
                if ty > y {
                    var xs = v[idx0].x, xe = v[idx].x
                    if shift != XY_SHIFT { xs <<= sh; xe <<= sh }
                    e.ye = ty
                    e.dx = ((xe &- xs) &* 2 &+ (Int64(ty) - Int64(y))) / (2 * (Int64(ty) - Int64(y)))
                    e.x = xs
                    e.idx = idx
                    break
                }
                idx0 = idx
                idx += e.di
                if idx >= npts { idx -= npts }
            }
        }

        repeat {
            if !aa || y < yMax || y == yMin {
                if y >= e0.ye { step(&e0) }
                if y >= e1.ye { step(&e1) }
            }
            if edges < 0 { break }
            if y >= 0 && y < pt.h {
                let lx = e0.x > e1.x ? e1.x : e0.x, rx = e0.x > e1.x ? e0.x : e1.x
                let xx1 = Int((lx + delta1) >> 16)
                let xx2 = Int((rx + delta2) >> 16)
                if xx2 >= 0 && xx1 < pt.w {
                    pt.span(y, xx1, xx2)
                    if let spans, y - yMin >= 0 {
                        spans[2 * (y - yMin)] = Int32(max(xx1, 0)); spans[2 * (y - yMin) + 1] = Int32(min(xx2, pt.w - 1))
                    }
                }
            }
            e0.x &+= e0.dx; e1.x &+= e1.dx
            y += 1
            // rows above the image draw nothing: jump to the next row where an edge changes (or row 0), advancing x linearly
            if y < 0 {
                let target = min(min(e0.ye, e1.ye), 0)
                if target > y {
                    let k = Int64(target - y)
                    e0.x &+= e0.dx &* k; e1.x &+= e1.dx &* k
                    y = target
                }
            }
        } while y <= yMax
    }

    if aa {
        let nrows = Int(ymax) - Int(ymin) + 1
        if nrows >= 1 && nrows <= 256 {
            withUnsafeTemporaryAllocation(of: Int32.self, capacity: nrows * 2) { buf in
                for i in 0..<nrows { buf[2 * i] = 1; buf[2 * i + 1] = 0 }   // empty span
                runFill(buf.baseAddress)
                drawEdges(skip: UnsafePointer(buf.baseAddress), skipY0: Int(ymin), skipRows: nrows)
            }
        } else {
            drawEdges(skip: nil, skipY0: 0, skipRows: 0)
            runFill(nil)
        }
    } else {
        drawEdges(skip: nil, skipY0: 0, skipRows: 0)
        runFill(nil)
    }
}

// MARK: - CollectPolyEdges + FillEdgeCollection (fillPoly, pies)

struct PolyEdge { var y0: Int; var y1: Int; var x: Int64; var dx: Int64 }

func collectPolyEdges(_ pt: Painter, _ v: [FP], _ edges: inout [PolyEdge], shift: Int, aa: Bool, lineType: Int, offX: Int64, offY: Int64) {
    let count = v.count
    if count == 0 { return }
    let delta = offY + ((Int64(1) << Int64(shift)) >> 1)
    var pt0 = v[count - 1]
    let sh = Int64(XY_SHIFT - shift)
    pt0.x = (pt0.x + offX) << sh
    pt0.y = (pt0.y + delta) >> Int64(shift)
    for i in 0..<count {
        var pt1 = v[i]
        pt1.x = (pt1.x + offX) << sh
        pt1.y = (pt1.y + delta) >> Int64(shift)
        var pt0c = pt0, pt1c = pt1
        if !aa {
            var t0 = FP(x: (pt0.x + (XY_ONE >> 1)) >> 16, y: pt0.y)
            var t1 = FP(x: (pt1.x + (XY_ONE >> 1)) >> 16, y: pt1.y)
            lineIter(pt, t0, t1, connectivity: lineType == 4 ? 4 : 8)
            if t0.x < 0 || t0.x >= Int64(pt.w) || t1.x < 0 || t1.x >= Int64(pt.w) || t0.y < 0 || t0.y >= Int64(pt.h) || t1.y < 0 || t1.y >= Int64(pt.h) {
                _ = clipLine64(Int64(pt.w), Int64(pt.h), &t0, &t1)
                if t0.y != t1.y { pt0c.y = t0.y; pt1c.y = t1.y }
            }
            pt0c.x = t0.x << 16
            pt1c.x = t1.x << 16
        } else {
            lineAA(pt, FP(x: pt0.x, y: pt0.y << 16), FP(x: pt1.x, y: pt1.y << 16))
        }
        defer { pt0 = pt1 }
        if pt0.y == pt1.y { continue }
        if pt1c.y == pt0c.y { continue }
        let dx = (pt1c.x &- pt0c.x) / (pt1c.y &- pt0c.y)
        if pt0.y < pt1.y {
            edges.append(PolyEdge(y0: Int(pt0.y), y1: Int(pt1.y), x: pt0c.x &+ (pt0.y &- pt0c.y) &* dx, dx: dx))
        } else {
            edges.append(PolyEdge(y0: Int(pt1.y), y1: Int(pt0.y), x: pt1c.x &+ (pt1.y &- pt1c.y) &* dx, dx: dx))
        }
    }
}

func fillEdgeCollection(_ pt: Painter, _ edges: [PolyEdge]) {
    let total = edges.count
    if total < 2 { return }
    var yMax = Int.min, yMin = Int.max
    var xMax = Int64.min, xMin = Int64.max
    for e in edges {
        let x1 = e.x &+ Int64(e.y1 - e.y0) &* e.dx
        yMin = min(yMin, e.y0); yMax = max(yMax, e.y1)
        xMin = min(xMin, min(e.x, x1)); xMax = max(xMax, max(e.x, x1))
    }
    if yMax < 0 || yMin >= pt.h || xMax < 0 || xMin >= Int64(pt.w) << 16 { return }
    let sorted = edges.sorted { a, b in
        if a.y0 != b.y0 { return a.y0 < b.y0 }
        if a.x != b.x { return a.x < b.x }
        return a.dx < b.dx
    }
    let delta = XY_ONE - 1
    var active: [PolyEdge] = []
    var next = 0
    yMax = min(yMax, pt.h)
    var y = max(sorted[0].y0, 0)
    while y < yMax {
        // drop finished edges, add new ones (an edge that began above row 0 enters with its x advanced to this row)
        active.removeAll { $0.y1 <= y }
        while next < total && sorted[next].y0 <= y {
            var e = sorted[next]; next += 1
            if e.y1 <= y { continue }
            if e.y0 < y { e.x &+= e.dx &* Int64(y - e.y0) }
            active.append(e)
        }
        active.sort { $0.x < $1.x }
        if y >= 0 {
            var k = 0
            while k + 1 < active.count {
                let a = active[k].x, b = active[k + 1].x
                let x1: Int, x2: Int
                if a > b { x1 = Int((b + delta) >> 16); x2 = Int(a >> 16) }
                else { x1 = Int((a + delta) >> 16); x2 = Int(b >> 16) }
                if x1 < pt.w && x2 >= 0 { pt.span(y, max(x1, 0), min(x2, pt.w - 1)) }
                k += 2
            }
        }
        for i in 0..<active.count { active[i].x &+= active[i].dx }
        y += 1
    }
}

// MARK: - ThickLine / PolyLine

func thickLine(_ pt: Painter, _ q0: FP, _ q1: FP, thickness t: Int, aa: Bool, lineType: Int, flags: Int, shift: Int, lastOpen: Bool = false) {
    var p0 = q0, p1 = q1
    if t > 1 && shift == 0 {
        let W = Int64(pt.w), H = Int64(pt.h)
        let inside0 = p0.x >= 0 && p0.x < W && p0.y >= 0 && p0.y < H
        let inside1 = p1.x >= 0 && p1.x < W && p1.y >= 0 && p1.y < H
        if !inside0 || !inside1 {
            let m = Int64(t)
            p0.x += m; p0.y += m; p1.x += m; p1.y += m
            _ = clipLine64(W + 2 * m, H + 2 * m, &p0, &p1)
            p0.x -= m; p0.y -= m; p1.x -= m; p1.y -= m
        }
    }
    let sh = Int64(XY_SHIFT - shift)
    p0.x <<= sh; p0.y <<= sh; p1.x <<= sh; p1.y <<= sh
    if t <= 1 {
        if !aa {
            if lineType == 8 || lineType == 1 || shift == 0 {
                let a = FP(x: (p0.x + (XY_ONE >> 1)) >> 16, y: (p0.y + (XY_ONE >> 1)) >> 16)
                let b = FP(x: (p1.x + (XY_ONE >> 1)) >> 16, y: (p1.y + (XY_ONE >> 1)) >> 16)
                lineIter(pt, a, b, connectivity: lineType == 4 ? 4 : 8)
            } else {
                line2(pt, p0, p1)
            }
        } else {
            lineAA(pt, p0, p1)
        }
        return
    }
    let dx = Double(p0.x - p1.x) / 65536.0, dy = Double(p1.y - p0.y) / 65536.0
    var r = dx * dx + dy * dy
    let odd = t & 1
    let th = Int64(t) << 15
    if abs(r) > 2.220446049250313e-16 {
        r = (Double(th) + Double(odd) * Double(XY_ONE) * 0.5) / r.squareRoot()
        let dpx = fxRound(dy * r), dpy = fxRound(dx * r)
        let quad = [FP(x: p0.x + dpx, y: p0.y + dpy), FP(x: p0.x - dpx, y: p0.y - dpy),
                    FP(x: p1.x - dpx, y: p1.y - dpy), FP(x: p1.x + dpx, y: p1.y + dpy)]
        fillConvexPoly(pt, quad, shift: XY_SHIFT, aa: aa, lineType: lineType)
    }
    var cur = p0
    for i in 0..<2 {
        if flags & (i + 1) != 0 {
            if !aa {
                let c = FP(x: (cur.x + (XY_ONE >> 1)) >> 16, y: (cur.y + (XY_ONE >> 1)) >> 16)
                midpointCircle(pt, Int(c.x), Int(c.y), Int((th + (XY_ONE >> 1)) >> 16), fill: true)
            } else {
                ellipseEx(pt, cur, FP(x: th, y: th), angle: 0, start: 0, end: 360, thickness: -1, aa: true, lineType: lineType)
            }
        }
        cur = p1
    }
}

func polyLine(_ pt: Painter, _ v: [FP], closed: Bool, thickness: Int, aa: Bool, lineType: Int, shift: Int) {
    let count = v.count
    if count <= 0 { return }
    var i = closed ? count - 1 : 0
    var flags = 2 + (closed ? 0 : 1)
    var p0 = v[i]
    i = closed ? 0 : 1
    while i < count {
        let p = v[i]
        thickLine(pt, p0, p, thickness: thickness, aa: aa, lineType: lineType, flags: flags, shift: shift, lastOpen: !closed && i == count - 1)
        p0 = p
        flags = 2
        i += 1
    }
}

// MARK: - EllipseEx

func ellipseEx(_ pt: Painter, _ center: FP, _ axes: FP, angle: Int, start: Int, end: Int, thickness: Int, aa: Bool, lineType: Int) {
    let aw = abs(axes.x), ah = abs(axes.y)
    var delta = Int((max(aw, ah) + (XY_ONE >> 1)) >> 16)
    delta = delta < 3 ? 90 : (delta < 10 ? 30 : (delta < 15 ? 18 : 5))
    let poly = ellipsePolyD(Double(center.x), Double(center.y), Double(aw), Double(ah), angle: angle, start: start, end: end, delta: delta)
    var v: [FP] = []
    var prev: FP? = nil
    for p in poly {
        let q = FP(x: fxRound(p.x), y: fxRound(p.y))
        if let pr = prev, pr.x == q.x, pr.y == q.y { continue }
        v.append(q); prev = q
    }
    if v.count <= 1 { v = [center, center] }
    if thickness >= 0 {
        polyLine(pt, v, closed: false, thickness: thickness, aa: aa, lineType: lineType, shift: XY_SHIFT)
    } else if end - start >= 360 {
        fillConvexPoly(pt, v, shift: XY_SHIFT, aa: aa, lineType: lineType)
    } else {
        v.append(center)
        var edges: [PolyEdge] = []
        collectPolyEdges(pt, v, &edges, shift: XY_SHIFT, aa: aa, lineType: lineType, offX: 0, offY: 0)
        fillEdgeCollection(pt, edges)
    }
}
