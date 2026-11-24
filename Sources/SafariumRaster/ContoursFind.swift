// SafariumRaster — cv::findContours (Suzuki-Abe border following, as OpenCV's cvFindContours).
// Contour points / start points / output order follow OpenCV 4+/5: borders are discovered in raster order and emitted
// newest-first; TREE / CCOMP emit a pre-order walk of the hierarchy with siblings newest-first.

import Foundation

final class SRContourResult {
    var points: [Int32] = []      // x,y interleaved, all contours back to back
    var counts: [Int32] = []      // points per contour
    var hierarchy: [Int32] = []   // 4 per contour: next, prev, first_child, parent
}

private struct Border {
    var isHole: Bool
    var parent: Int
    var start: Int
    var count: Int
}

private func findContoursImpl(_ img: SRImage, mode: Int, simple: Bool, offX: Int, offY: Int) -> SRContourResult {
    let w = img.width, h = img.height
    let pw = w + 2, ph = h + 2
    var f = [Int32](repeating: 0, count: pw * ph)
    for y in 0..<h {
        let s = img.row(y).assumingMemoryBound(to: UInt8.self)
        for x in 0..<w where s[x] != 0 { f[(y + 1) * pw + x + 1] = 1 }
    }
    let d: [Int] = [1, -pw + 1, -pw, -pw - 1, -1, pw - 1, pw, pw + 1, 1, -pw + 1, -pw, -pw - 1, -1, pw - 1, pw, pw + 1]
    let cdx = [1, 1, 0, -1, -1, -1, 0, 1], cdy = [0, -1, -1, -1, 0, 1, 1, 1]
    var borders = [Border]()
    var pts = [Int32]()

    f.withUnsafeMutableBufferPointer { f in
        for y in 1...h {
            var lnbd: Int32 = 1
            for x in 1...w {
                let idx = y * pw + x
                let fij = f[idx]
                var isBorder = false, hole = false
                if fij == 1 && f[idx - 1] == 0 {
                    isBorder = true
                } else if fij >= 1 && f[idx + 1] == 0 {
                    isBorder = true; hole = true
                    if fij > 1 { lnbd = fij }
                }
                if isBorder {
                    let id = borders.count
                    let nbd = Int32(id + 2)
                    let lid = lnbd >= 2 ? Int(lnbd) - 2 : -1
                    var parent = -1
                    if !hole {
                        if lid >= 0 { parent = borders[lid].isHole ? lid : borders[lid].parent }
                    } else {
                        if lid >= 0 { parent = borders[lid].isHole ? borders[lid].parent : lid }
                    }
                    let startCount = pts.count
                    // --- fetch contour (port of OpenCV icvFetchContour) ---
                    let i0 = idx
                    var px = x - 1, py = y - 1
                    var s = hole ? 0 : 4
                    let s0 = s
                    var i1 = 0
                    var found = false
                    repeat {
                        s = (s - 1) & 7
                        i1 = i0 + d[s]
                        if f[i1] != 0 { found = true; break }
                    } while s != s0
                    if !found {
                        f[i0] = -nbd
                        pts.append(Int32(px)); pts.append(Int32(py))
                    } else {
                        var i3 = i0
                        var prevS = s ^ 4
                        while true {
                            let sEnd = s
                            var i4 = 0
                            while true {
                                s += 1
                                i4 = i3 + d[s]
                                if f[i4] != 0 { break }
                            }
                            s &= 7
                            if s >= 1 && s - 1 < sEnd {
                                f[i3] = -nbd
                            } else if f[i3] == 1 {
                                f[i3] = nbd
                            }
                            if !simple || s != prevS {
                                pts.append(Int32(px)); pts.append(Int32(py))
                                prevS = s
                            }
                            px += cdx[s]; py += cdy[s]
                            if i4 == i0 && i3 == i1 { break }
                            i3 = i4
                            s = (s + 4) & 7
                        }
                    }
                    borders.append(Border(isHole: hole, parent: parent, start: startCount / 2, count: (pts.count - startCount) / 2))
                }
                let v = f[idx]
                if v != 0 && v != 1 { lnbd = abs(v) }
            }
        }
    }

    // --- ordering / hierarchy ---
    let n = borders.count
    let res = SRContourResult()
    var order = [Int]()          // emitted border ids
    var hier = [Int32]()
    if mode == 0 || mode == 1 {  // EXTERNAL / LIST: newest first, flat chain
        for k in stride(from: n - 1, through: 0, by: -1) {
            if mode == 0 && (borders[k].isHole || borders[k].parent != -1) { continue }
            order.append(k)
        }
        let m = order.count
        for i in 0..<m { hier += [Int32(i + 1 < m ? i + 1 : -1), Int32(i - 1), -1, -1] }
    } else {
        // tree parents: TREE → Suzuki parent; CCOMP → holes keep their outer, outer borders are top level
        var par = [Int](repeating: -1, count: n)
        for k in 0..<n { par[k] = (mode == 3 || borders[k].isHole) ? borders[k].parent : -1 }
        var kids = [[Int]](repeating: [], count: n)
        var roots = [Int]()
        for k in stride(from: n - 1, through: 0, by: -1) {
            if par[k] < 0 { roots.append(k) } else { kids[par[k]].append(k) }
        }
        var pos = [Int](repeating: -1, count: n)
        func walk(_ k: Int) {
            pos[k] = order.count
            order.append(k)
            for c in kids[k] { walk(c) }
        }
        // iterative-safe enough: depth = nesting depth of the image (small); recursion is fine.
        for r in roots { walk(r) }
        var sibNext = [Int](repeating: -1, count: n), sibPrev = [Int](repeating: -1, count: n)
        func link(_ list: [Int]) {
            for (i, k) in list.enumerated() {
                sibNext[k] = i + 1 < list.count ? list[i + 1] : -1
                sibPrev[k] = i > 0 ? list[i - 1] : -1
            }
        }
        link(roots)
        for k in 0..<n { link(kids[k]) }
        for k in order {
            hier += [Int32(sibNext[k] >= 0 ? pos[sibNext[k]] : -1), Int32(sibPrev[k] >= 0 ? pos[sibPrev[k]] : -1),
                     Int32(kids[k].first.map { pos[$0] } ?? -1), Int32(par[k] >= 0 ? pos[par[k]] : -1)]
        }
    }
    for k in order {
        let b = borders[k]
        res.counts.append(Int32(b.count))
        for i in 0..<b.count {
            res.points.append(pts[(b.start + i) * 2] + Int32(offX))
            res.points.append(pts[(b.start + i) * 2 + 1] + Int32(offY))
        }
    }
    res.hierarchy = hier
    return res
}

/// mode: 0 EXTERNAL, 1 LIST, 2 CCOMP, 3 TREE. method: 1 NONE, 2 SIMPLE. Returns a handle (see sr_contours_*).
@_cdecl("sr_find_contours")
public func sr_find_contours(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                             _ mode: Int32, _ method: Int32, _ offX: Int32, _ offY: Int32,
                             _ outCount: UnsafeMutablePointer<Int32>?, _ outPoints: UnsafeMutablePointer<Int64>?,
                             _ outHandle: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep), src.depth == .u8, src.channels == 1,
          let outCount, let outPoints, let outHandle else {
        return srFail(SRStatus.badArgument, "findContours: need a 1-channel u8 image")
    }
    guard (0...3).contains(mode) else { return srFail(SRStatus.unsupported, "findContours: unsupported retrieval mode") }
    guard method == 1 || method == 2 else { return srFail(SRStatus.unsupported, "findContours: unsupported approximation method") }
    if src.width == 0 || src.height == 0 {
        outCount.pointee = 0; outPoints.pointee = 0; outHandle.pointee = nil
        return SRStatus.ok
    }
    let res = findContoursImpl(src, mode: Int(mode), simple: method == 2, offX: Int(offX), offY: Int(offY))
    outCount.pointee = Int32(res.counts.count)
    outPoints.pointee = Int64(res.points.count / 2)
    outHandle.pointee = Unmanaged.passRetained(res).toOpaque()
    return SRStatus.ok
}

/// Copies counts (n int32), points (total*2 int32) and hierarchy (n*4 int32) out of the handle and releases it.
@_cdecl("sr_contours_take")
public func sr_contours_take(_ handle: UnsafeMutableRawPointer?, _ counts: UnsafeMutablePointer<Int32>?,
                             _ points: UnsafeMutablePointer<Int32>?, _ hier: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let handle else { return srFail(SRStatus.badArgument, "contours_take: null handle") }
    let res = Unmanaged<SRContourResult>.fromOpaque(handle).takeRetainedValue()
    if let counts, !res.counts.isEmpty { res.counts.withUnsafeBufferPointer { counts.update(from: $0.baseAddress!, count: res.counts.count) } }
    if let points, !res.points.isEmpty { res.points.withUnsafeBufferPointer { points.update(from: $0.baseAddress!, count: res.points.count) } }
    if let hier, !res.hierarchy.isEmpty { res.hierarchy.withUnsafeBufferPointer { hier.update(from: $0.baseAddress!, count: res.hierarchy.count) } }
    return SRStatus.ok
}
