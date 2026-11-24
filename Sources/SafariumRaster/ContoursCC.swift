// SafariumRaster — cv::connectedComponents(WithStats): two-pass union-find; labels numbered in raster-scan order of
// each component's first pixel (OpenCV's ordering). Background = label 0 (included in stats).

import Foundation

final class SRCCResult {
    var n: Int = 0
    var stats: [Int32] = []       // n * 5: left, top, width, height, area
    var centroids: [Double] = []  // n * 2
}

@_cdecl("sr_connected_components")
public func sr_connected_components(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                                    _ ld: UnsafeMutableRawPointer?, _ lw: Int32, _ lh: Int32, _ ls: Int32, _ lc: Int32, _ ldep: Int32,
                                    _ connectivity: Int32, _ outN: UnsafeMutablePointer<Int32>?,
                                    _ outHandle: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep), let lab = SRImage(ld, lw, lh, ls, lc, ldep),
          src.depth == .u8, src.channels == 1, lab.depth == .s32, lab.channels == 1,
          src.width == lab.width, src.height == lab.height, connectivity == 4 || connectivity == 8,
          let outN, let outHandle else {
        return srFail(SRStatus.badArgument, "connectedComponents: need 1-channel u8 image, int32 labels, connectivity 4 or 8")
    }
    let w = src.width, h = src.height
    let eight = connectivity == 8
    var parent = [Int32]()
    parent.reserveCapacity(1024)
    parent.append(0)
    @inline(__always) func find(_ x: Int32) -> Int32 {
        var r = x
        while parent[Int(r)] != r { r = parent[Int(r)] }
        var c = x
        while parent[Int(c)] != r { let nx = parent[Int(c)]; parent[Int(c)] = r; c = nx }
        return r
    }
    @inline(__always) func union(_ a: Int32, _ b: Int32) -> Int32 {
        let ra = find(a), rb = find(b)
        if ra == rb { return ra }
        if ra < rb { parent[Int(rb)] = ra; return ra }
        parent[Int(ra)] = rb; return rb
    }
    // pass 1
    for y in 0..<h {
        let s = src.row(y).assumingMemoryBound(to: UInt8.self)
        let l = lab.row(y).assumingMemoryBound(to: Int32.self)
        let up: UnsafeMutablePointer<Int32>? = y > 0 ? lab.row(y - 1).assumingMemoryBound(to: Int32.self) : nil
        for x in 0..<w {
            if s[x] == 0 { l[x] = 0; continue }
            var cur: Int32 = 0
            @inline(__always) func take(_ v: Int32) {
                if v == 0 { return }
                cur = cur == 0 ? v : union(cur, v)
            }
            if x > 0 { take(l[x - 1]) }
            if let up {
                take(up[x])
                if eight {
                    if x > 0 { take(up[x - 1]) }
                    if x + 1 < w { take(up[x + 1]) }
                }
            }
            if cur == 0 {
                cur = Int32(parent.count)
                parent.append(cur)
            }
            l[x] = cur
        }
    }
    // consecutive final labels in order of root
    var finalOf = [Int32](repeating: 0, count: parent.count)
    var n: Int32 = 1
    for i in 1..<max(1, parent.count) where parent[i] == Int32(i) {
        finalOf[i] = n; n += 1
    }
    for i in 1..<max(1, parent.count) where parent[i] != Int32(i) {
        finalOf[i] = finalOf[Int(find(Int32(i)))]
    }
    let res = SRCCResult()
    res.n = Int(n)
    var left = [Int32](repeating: Int32.max, count: res.n), top = [Int32](repeating: Int32.max, count: res.n)
    var right = [Int32](repeating: -1, count: res.n), bottom = [Int32](repeating: -1, count: res.n)
    var area = [Int64](repeating: 0, count: res.n)
    var sx = [Double](repeating: 0, count: res.n), sy = [Double](repeating: 0, count: res.n)
    var minKey = [Int](repeating: Int.max, count: res.n)
    let bw = (w + 1) >> 1
    for y in 0..<h {
        let l = lab.row(y).assumingMemoryBound(to: Int32.self)
        for x in 0..<w {
            let v = l[x]
            let f = v == 0 ? 0 : Int(finalOf[Int(v)])
            l[x] = Int32(f)
            if Int32(x) < left[f] { left[f] = Int32(x) }
            if Int32(y) < top[f] { top[f] = Int32(y) }
            if Int32(x) > right[f] { right[f] = Int32(x) }
            if Int32(y) > bottom[f] { bottom[f] = Int32(y) }
            area[f] += 1
            sx[f] += Double(x); sy[f] += Double(y)
            let key = (y >> 1) * bw + (x >> 1)
            if key < minKey[f] { minKey[f] = key }
        }
    }
    res.stats = [Int32](repeating: 0, count: res.n * 5)
    res.centroids = [Double](repeating: 0, count: res.n * 2)
    for i in 0..<res.n where area[i] == 0 {  // only the background can be empty; OpenCV reports (-1, INT_MAX, 0, 0, 0) / NaN
        res.stats[i * 5] = -1; res.stats[i * 5 + 1] = Int32.max
        res.centroids[i * 2] = Double.nan; res.centroids[i * 2 + 1] = Double.nan
    }
    for i in 0..<res.n where area[i] > 0 {
        res.stats[i * 5] = left[i]; res.stats[i * 5 + 1] = top[i]
        res.stats[i * 5 + 2] = right[i] - left[i] + 1; res.stats[i * 5 + 3] = bottom[i] - top[i] + 1
        res.stats[i * 5 + 4] = Int32(area[i])
        res.centroids[i * 2] = sx[i] / Double(area[i]); res.centroids[i * 2 + 1] = sy[i] / Double(area[i])
    }
    if eight && res.n > 2 {
        // OpenCV's 8-connected labelling scans 2x2 blocks (BBDT): components are numbered by the first block
        // (2-row strip, left to right) they touch, not by their first pixel.
        let order = (1..<res.n).sorted { minKey[$0] < minKey[$1] }
        var remap = [Int32](repeating: 0, count: res.n)
        for (rank, old) in order.enumerated() { remap[old] = Int32(rank + 1) }
        var st2 = res.stats, ce2 = res.centroids
        for old in 1..<res.n {
            let nw = Int(remap[old])
            for k in 0..<5 { st2[nw * 5 + k] = res.stats[old * 5 + k] }
            ce2[nw * 2] = res.centroids[old * 2]; ce2[nw * 2 + 1] = res.centroids[old * 2 + 1]
        }
        res.stats = st2; res.centroids = ce2
        for y in 0..<h {
            let l = lab.row(y).assumingMemoryBound(to: Int32.self)
            for x in 0..<w where l[x] != 0 { l[x] = remap[Int(l[x])] }
        }
    }
    outN.pointee = n
    outHandle.pointee = Unmanaged.passRetained(res).toOpaque()
    return SRStatus.ok
}

/// Copies stats (n*5 int32) and centroids (n*2 f64) out of the handle and releases it.
@_cdecl("sr_cc_take")
public func sr_cc_take(_ handle: UnsafeMutableRawPointer?, _ stats: UnsafeMutablePointer<Int32>?,
                       _ centroids: UnsafeMutablePointer<Double>?) -> Int32 {
    guard let handle else { return srFail(SRStatus.badArgument, "cc_take: null handle") }
    let res = Unmanaged<SRCCResult>.fromOpaque(handle).takeRetainedValue()
    if let stats { res.stats.withUnsafeBufferPointer { stats.update(from: $0.baseAddress!, count: res.stats.count) } }
    if let centroids { res.centroids.withUnsafeBufferPointer { centroids.update(from: $0.baseAddress!, count: res.centroids.count) } }
    return SRStatus.ok
}
