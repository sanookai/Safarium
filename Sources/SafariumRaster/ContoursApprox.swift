// SafariumRaster — cv::approxPolyDP (Douglas-Peucker, after OpenCV's approxPolyDP_ incl. its final clean-up pass).
// Verified bit-exact against OpenCV 5.1 on random int32/float32 open+closed curves: OpenCV 5 measures the split
// distance to the *segment* (not the infinite line), so collinear points beyond an endpoint are kept.

import Foundation

protocol SRCoord {
    static func diff(_ a: Self, _ b: Self) -> Double   // computed in the element type, like cv::Point_<T>
    var dbl: Double { get }
}
extension Int32: SRCoord {
    @inline(__always) static func diff(_ a: Int32, _ b: Int32) -> Double { Double(a &- b) }
    @inline(__always) var dbl: Double { Double(self) }
}
extension Float: SRCoord {
    @inline(__always) static func diff(_ a: Float, _ b: Float) -> Double { Double(a - b) }
    @inline(__always) var dbl: Double { Double(self) }
}

private struct Range2 { var start: Int; var end: Int }

/// src/dst: interleaved x,y of T. Returns the new point count.
private func approxPolyDP<T: SRCoord>(_ src: UnsafePointer<T>, _ count0: Int, _ dst: UnsafeMutablePointer<T>,
                                      _ closed0: Bool, _ epsIn: Double, _ zero: T, _ sentinel: T) -> Int {
    var count = count0
    if count == 0 { return 0 }
    let eps = epsIn * epsIn
    var initIters = 3
    var slice = Range2(start: 0, end: 0), rightSlice = Range2(start: 0, end: 0)
    var startPt = (sentinel, sentinel), endPt = (zero, zero), pt = (zero, zero)
    var pos = 0, newCount = 0
    var isClosed = closed0
    var leEps = false
    var stack = [Range2]()
    @inline(__always) func readSrc(_ p: inout Int) -> (T, T) {
        let r = (src[p * 2], src[p * 2 + 1]); p += 1; if p >= count { p = 0 }; return r
    }
    @inline(__always) func write(_ p: (T, T)) { dst[newCount * 2] = p.0; dst[newCount * 2 + 1] = p.1; newCount += 1 }

    if !isClosed {
        rightSlice.start = count
        endPt = (src[0], src[1])
        startPt = (src[(count - 1) * 2], src[(count - 1) * 2 + 1])
        if startPt.0.dbl != endPt.0.dbl || startPt.1.dbl != endPt.1.dbl {
            slice = Range2(start: 0, end: count - 1)
            stack.append(slice)
        } else {
            isClosed = true
            initIters = 1
        }
    }
    if isClosed {
        rightSlice.start = 0
        for _ in 0..<initIters {
            var maxDist = 0.0
            pos = (pos + rightSlice.start) % count
            startPt = readSrc(&pos)
            for j in 1..<max(1, count) {
                pt = readSrc(&pos)
                let dx = T.diff(pt.0, startPt.0), dy = T.diff(pt.1, startPt.1)
                let dist = dx * dx + dy * dy
                if dist > maxDist { maxDist = dist; rightSlice.start = j }
            }
            leEps = maxDist <= eps
        }
        if !leEps {
            rightSlice.end = pos % count
            slice.start = rightSlice.end
            slice.end = (rightSlice.start + slice.start) % count
            rightSlice.start = slice.end
            stack.append(rightSlice)
            stack.append(slice)
        } else {
            write(startPt)
        }
    }
    while let sl = stack.popLast() {
        slice = sl
        endPt = (src[slice.end * 2], src[slice.end * 2 + 1])
        pos = slice.start
        startPt = readSrc(&pos)
        if pos != slice.end {
            var maxDist = 0.0   // squared distance from the point to the *segment* start-end (OpenCV 5 behaviour)
            let dx = T.diff(endPt.0, startPt.0), dy = T.diff(endPt.1, startPt.1)
            let len2 = dx * dx + dy * dy
            while pos != slice.end {
                pt = readSrc(&pos)
                let px = T.diff(pt.0, startPt.0), py = T.diff(pt.1, startPt.1)
                let dot = px * dx + py * dy
                let dist: Double
                if dot <= 0 { dist = px * px + py * py }
                else if dot >= len2 {
                    let ex = T.diff(pt.0, endPt.0), ey = T.diff(pt.1, endPt.1)
                    dist = ex * ex + ey * ey
                } else {
                    let cr = py * dx - px * dy
                    dist = cr * cr / len2
                }
                if dist > maxDist { maxDist = dist; rightSlice.start = (pos + count - 1) % count }
            }
            leEps = maxDist <= eps
        } else {
            leEps = true
            startPt = (src[slice.start * 2], src[slice.start * 2 + 1])
        }
        if leEps {
            write(startPt)
        } else {
            rightSlice.end = slice.end
            slice.end = rightSlice.start
            stack.append(rightSlice)
            stack.append(slice)
        }
    }
    if !isClosed { write((src[(count - 1) * 2], src[(count - 1) * 2 + 1])) }

    // final clean-up: drop points on (almost) straight lines
    isClosed = closed0
    count = newCount
    pos = isClosed ? count - 1 : 0
    @inline(__always) func readDst(_ p: inout Int) -> (T, T) {
        let r = (dst[p * 2], dst[p * 2 + 1]); p += 1; if p >= count { p = 0 }; return r
    }
    startPt = readDst(&pos)
    var wpos = pos
    pt = readDst(&pos)
    var i = isClosed ? 0 : 1
    while i < count - (isClosed ? 0 : 1) && newCount > 2 {
        endPt = readDst(&pos)
        let dx = T.diff(endPt.0, startPt.0), dy = T.diff(endPt.1, startPt.1)
        let dist = abs(T.diff(pt.0, startPt.0) * dy - T.diff(pt.1, startPt.1) * dx)
        let inner = T.diff(pt.0, startPt.0) * T.diff(endPt.0, pt.0) + T.diff(pt.1, startPt.1) * T.diff(endPt.1, pt.1)
        if dist * dist <= 0.5 * eps * (dx * dx + dy * dy) && dx != 0 && dy != 0 && inner >= 0 {
            newCount -= 1
            startPt = endPt
            dst[wpos * 2] = endPt.0; dst[wpos * 2 + 1] = endPt.1
            wpos += 1; if wpos >= count { wpos = 0 }
            pt = readDst(&pos)
            i += 1
            i += 1
            continue
        }
        dst[wpos * 2] = pt.0; dst[wpos * 2 + 1] = pt.1
        startPt = pt
        wpos += 1; if wpos >= count { wpos = 0 }
        pt = endPt
        i += 1
    }
    if !isClosed { dst[wpos * 2] = pt.0; dst[wpos * 2 + 1] = pt.1 }
    return newCount
}

/// isFloat: 0 = int32 points, 1 = float32 points. `out` must hold n points; returns the count via outCount.
@_cdecl("sr_approx_poly_dp")
public func sr_approx_poly_dp(_ pts: UnsafeRawPointer?, _ n: Int32, _ isFloat: Int32, _ eps: Double, _ closed: Int32,
                              _ out: UnsafeMutableRawPointer?, _ outCount: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let pts, let out, let outCount, n >= 0, eps >= 0 else {
        return srFail(SRStatus.badArgument, "approxPolyDP: bad arguments")
    }
    if isFloat != 0 {
        outCount.pointee = Int32(approxPolyDP(pts.assumingMemoryBound(to: Float.self), Int(n),
                                              out.assumingMemoryBound(to: Float.self), closed != 0, eps, 0, -1_000_000))
    } else {
        outCount.pointee = Int32(approxPolyDP(pts.assumingMemoryBound(to: Int32.self), Int(n),
                                              out.assumingMemoryBound(to: Int32.self), closed != 0, eps, 0, -1_000_000))
    }
    return SRStatus.ok
}
