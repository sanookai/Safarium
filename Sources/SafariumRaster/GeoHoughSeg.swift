// SafariumRaster — Phase 4: Hough transforms, LineSegmentDetector, Segmentation (floodFill/watershed/grabCut), Subdiv2D.
// Backed by pure C11 kernels in geo_p4.c via @_silgen_name, exposed as @_cdecl("sr_p4_...").

import Foundation

// MARK: - C bindings (Sources/SafariumRasterC/geo_p4.c)

@_silgen_name("sr_c_p4_free")
private func sr_c_p4_free(_ ptr: UnsafeMutableRawPointer?)

@_silgen_name("sr_c_p4_hough_lines")
private func sr_c_p4_hough_lines(_ img: UnsafePointer<UInt8>?, _ w: Int32, _ h: Int32, _ stride: Int32,
                                 _ rho: Double, _ theta: Double, _ threshold: Int32,
                                 _ srn: Double, _ stn: Double, _ minTheta: Double, _ maxTheta: Double,
                                 _ useEdgeval: Int32, _ linesMax: Int32,
                                 _ outLines: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?,
                                 _ outCount: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_hough_lines_p")
private func sr_c_p4_hough_lines_p(_ img: UnsafePointer<UInt8>?, _ w: Int32, _ h: Int32, _ stride: Int32,
                                   _ rho: Double, _ theta: Double, _ threshold: Int32,
                                   _ minLen: Double, _ maxGap: Double, _ linesMax: Int32,
                                   _ outLines: UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>?,
                                   _ outCount: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_hough_circles")
private func sr_c_p4_hough_circles(_ img: UnsafePointer<UInt8>?, _ w: Int32, _ h: Int32, _ stride: Int32,
                                   _ method: Int32, _ dp: Double, _ minDist: Double,
                                   _ param1: Double, _ param2: Double, _ minR: Int32, _ maxR: Int32,
                                   _ circlesMax: Int32,
                                   _ outCircles: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?,
                                   _ outCount: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_lsd_detect")
private func sr_c_p4_lsd_detect(_ img: UnsafePointer<UInt8>?, _ w: Int32, _ h: Int32, _ stride: Int32,
                                _ refine: Int32, _ scale: Double, _ sigmaScale: Double, _ quant: Double,
                                _ angTh: Double, _ logEps: Double, _ densityTh: Double, _ nBins: Int32,
                                _ outLines: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?,
                                _ outWidth: UnsafeMutablePointer<UnsafeMutablePointer<Double>?>?,
                                _ outPrec: UnsafeMutablePointer<UnsafeMutablePointer<Double>?>?,
                                _ outNfa: UnsafeMutablePointer<UnsafeMutablePointer<Double>?>?,
                                _ outCount: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_lsd_draw")
private func sr_c_p4_lsd_draw(_ bgr: UnsafeMutablePointer<UInt8>?, _ w: Int32, _ h: Int32, _ stride: Int32,
                              _ lines: UnsafePointer<Float>?, _ nlines: Int32) -> Int32

@_silgen_name("sr_c_p4_lsd_compare")
private func sr_c_p4_lsd_compare(_ w: Int32, _ h: Int32,
                                 _ l1: UnsafePointer<Float>?, _ n1: Int32,
                                 _ l2: UnsafePointer<Float>?, _ n2: Int32,
                                 _ bgr: UnsafeMutablePointer<UInt8>?, _ stride: Int32,
                                 _ outMismatch: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_flood_fill")
private func sr_c_p4_flood_fill(_ img: UnsafeMutableRawPointer?, _ w: Int32, _ h: Int32, _ stride: Int32,
                                _ ch: Int32, _ depth: Int32, _ mask: UnsafeMutablePointer<UInt8>?,
                                _ maskStride: Int32, _ sx: Int32, _ sy: Int32,
                                _ newVal: UnsafePointer<Double>?, _ loDiff: UnsafePointer<Double>?,
                                _ upDiff: UnsafePointer<Double>?, _ flags: Int32,
                                _ outArea: UnsafeMutablePointer<Int32>?,
                                _ outRect4: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_watershed")
private func sr_c_p4_watershed(_ img: UnsafePointer<UInt8>?, _ w: Int32, _ h: Int32, _ imgStride: Int32,
                               _ markers: UnsafeMutablePointer<Int32>?, _ mStrideBytes: Int32) -> Int32

@_silgen_name("sr_c_p4_grabcut")
private func sr_c_p4_grabcut(_ img: UnsafePointer<UInt8>?, _ w: Int32, _ h: Int32, _ imgStride: Int32,
                             _ mask: UnsafeMutablePointer<UInt8>?, _ mStride: Int32,
                             _ rx: Int32, _ ry: Int32, _ rw: Int32, _ rh: Int32,
                             _ bgdModel: UnsafeMutablePointer<Double>?, _ fgdModel: UnsafeMutablePointer<Double>?,
                             _ iterCount: Int32, _ mode: Int32) -> Int32

@_silgen_name("sr_c_p4_subdiv_new")
private func sr_c_p4_subdiv_new() -> UnsafeMutableRawPointer?

@_silgen_name("sr_c_p4_subdiv_free")
private func sr_c_p4_subdiv_free(_ ptr: UnsafeMutableRawPointer?)

@_silgen_name("sr_c_p4_subdiv_init")
private func sr_c_p4_subdiv_init(_ ptr: UnsafeMutableRawPointer?, _ rx: Float, _ ry: Float, _ rw: Float, _ rh: Float) -> Int32

@_silgen_name("sr_c_p4_subdiv_insert")
private func sr_c_p4_subdiv_insert(_ ptr: UnsafeMutableRawPointer?, _ x: Float, _ y: Float, _ outId: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_subdiv_locate")
private func sr_c_p4_subdiv_locate(_ ptr: UnsafeMutableRawPointer?, _ x: Float, _ y: Float,
                                   _ outLoc: UnsafeMutablePointer<Int32>?,
                                   _ outEdge: UnsafeMutablePointer<Int32>?,
                                   _ outVtx: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_subdiv_nearest")
private func sr_c_p4_subdiv_nearest(_ ptr: UnsafeMutableRawPointer?, _ x: Float, _ y: Float,
                                    _ outPt2: UnsafeMutablePointer<Float>?, _ outVtx: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_subdiv_edges")
private func sr_c_p4_subdiv_edges(_ ptr: UnsafeMutableRawPointer?,
                                  _ outEdges: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?,
                                  _ outCount: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_subdiv_tris")
private func sr_c_p4_subdiv_tris(_ ptr: UnsafeMutableRawPointer?,
                                 _ outTris: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?,
                                 _ outCount: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_subdiv_leading_edges")
private func sr_c_p4_subdiv_leading_edges(_ ptr: UnsafeMutableRawPointer?,
                                          _ outEdges: UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>?,
                                          _ outCount: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_subdiv_voronoi")
private func sr_c_p4_subdiv_voronoi(_ ptr: UnsafeMutableRawPointer?, _ idx: UnsafePointer<Int32>?, _ nidx: Int32,
                                    _ outPts: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?,
                                    _ outCounts: UnsafeMutablePointer<UnsafeMutablePointer<Int32>?>?,
                                    _ outCenters: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?,
                                    _ outNFacets: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_subdiv_vertex")
private func sr_c_p4_subdiv_vertex(_ ptr: UnsafeMutableRawPointer?, _ vid: Int32,
                                   _ outPt2: UnsafeMutablePointer<Float>?, _ outEdge: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_subdiv_get_edge")
private func sr_c_p4_subdiv_get_edge(_ ptr: UnsafeMutableRawPointer?, _ edge: Int32, _ nextType: Int32) -> Int32

@_silgen_name("sr_c_p4_subdiv_next_edge")
private func sr_c_p4_subdiv_next_edge(_ ptr: UnsafeMutableRawPointer?, _ edge: Int32) -> Int32

@_silgen_name("sr_c_p4_subdiv_rotate_edge")
private func sr_c_p4_subdiv_rotate_edge(_ edge: Int32, _ rot: Int32) -> Int32

@_silgen_name("sr_c_p4_subdiv_sym_edge")
private func sr_c_p4_subdiv_sym_edge(_ edge: Int32) -> Int32

@_silgen_name("sr_c_p4_subdiv_edge_org")
private func sr_c_p4_subdiv_edge_org(_ ptr: UnsafeMutableRawPointer?, _ edge: Int32,
                                     _ outPt2: UnsafeMutablePointer<Float>?, _ outVtx: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_subdiv_edge_dst")
private func sr_c_p4_subdiv_edge_dst(_ ptr: UnsafeMutableRawPointer?, _ edge: Int32,
                                     _ outPt2: UnsafeMutablePointer<Float>?, _ outVtx: UnsafeMutablePointer<Int32>?) -> Int32

// MARK: - Handle wrappers

private final class SRFloatBufBox {
    let ptr: UnsafeMutablePointer<Float>?
    let count: Int
    init(_ ptr: UnsafeMutablePointer<Float>?, _ count: Int) { self.ptr = ptr; self.count = count }
    deinit { if let ptr { sr_c_p4_free(ptr) } }
}

private final class SRInt32BufBox {
    let ptr: UnsafeMutablePointer<Int32>?
    let count: Int
    init(_ ptr: UnsafeMutablePointer<Int32>?, _ count: Int) { self.ptr = ptr; self.count = count }
    deinit { if let ptr { sr_c_p4_free(ptr) } }
}

private final class SRLSDBox {
    let lines: UnsafeMutablePointer<Float>?
    let width: UnsafeMutablePointer<Double>?
    let prec: UnsafeMutablePointer<Double>?
    let nfa: UnsafeMutablePointer<Double>?
    let count: Int
    init(_ lines: UnsafeMutablePointer<Float>?, _ width: UnsafeMutablePointer<Double>?,
         _ prec: UnsafeMutablePointer<Double>?, _ nfa: UnsafeMutablePointer<Double>?, _ count: Int) {
        self.lines = lines; self.width = width; self.prec = prec; self.nfa = nfa; self.count = count
    }
    deinit {
        if let lines { sr_c_p4_free(lines) }
        if let width { sr_c_p4_free(width) }
        if let prec { sr_c_p4_free(prec) }
        if let nfa { sr_c_p4_free(nfa) }
    }
}

private final class SRVoronoiBox {
    let pts: UnsafeMutablePointer<Float>?
    let counts: UnsafeMutablePointer<Int32>?
    let centers: UnsafeMutablePointer<Float>?
    let nfacets: Int
    let totalPts: Int
    init(_ pts: UnsafeMutablePointer<Float>?, _ counts: UnsafeMutablePointer<Int32>?,
         _ centers: UnsafeMutablePointer<Float>?, _ nfacets: Int, _ totalPts: Int) {
        self.pts = pts; self.counts = counts; self.centers = centers
        self.nfacets = nfacets; self.totalPts = totalPts
    }
    deinit {
        if let pts { sr_c_p4_free(pts) }
        if let counts { sr_c_p4_free(counts) }
        if let centers { sr_c_p4_free(centers) }
    }
}

@inline(__always)
private func mapHS(_ rc: Int32, _ who: String) -> Int32 {
    if rc == 0 { return SRStatus.ok }
    if rc == -2 { return srFail(SRStatus.unsupported, "\(who): unsupported mode") }
    if rc == -4 { return srFail(SRStatus.internalError, "\(who): out of memory") }
    return srFail(SRStatus.badArgument, "\(who): invalid argument")
}

// MARK: - HoughLines / HoughLinesP / HoughCircles

@_cdecl("sr_p4_hough_lines")
public func sr_p4_hough_lines(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                              _ rho: Double, _ theta: Double, _ threshold: Int32,
                              _ srn: Double, _ stn: Double, _ minTheta: Double, _ maxTheta: Double, _ useEdgeval: Int32,
                              _ linesMax: Int32, _ outCount: UnsafeMutablePointer<Int32>?,
                              _ outHandle: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep), src.depth == .u8, src.channels == 1,
          let outCount, let outHandle else {
        return srFail(SRStatus.badArgument, "HoughLines: requires 1-channel uint8 image")
    }
    var ptr: UnsafeMutablePointer<Float>? = nil
    var cnt: Int32 = 0
    let rc = sr_c_p4_hough_lines(src.data.assumingMemoryBound(to: UInt8.self),
                                 Int32(src.width), Int32(src.height), Int32(src.stride),
                                 rho, theta, threshold, srn, stn, minTheta, maxTheta, useEdgeval,
                                 linesMax, &ptr, &cnt)
    if rc != 0 {
        if let ptr { sr_c_p4_free(ptr) }
        return mapHS(rc, "HoughLines")
    }
    outCount.pointee = cnt
    outHandle.pointee = cnt > 0 ? Unmanaged.passRetained(SRFloatBufBox(ptr, Int(cnt) * 2)).toOpaque() : nil
    return SRStatus.ok
}

@_cdecl("sr_p4_hough_lines_take")
public func sr_p4_hough_lines_take(_ handle: UnsafeMutableRawPointer?, _ outLines: UnsafeMutablePointer<Float>?) -> Int32 {
    guard let handle else { return srFail(SRStatus.badArgument, "hough_lines_take: null handle") }
    let box = Unmanaged<SRFloatBufBox>.fromOpaque(handle).takeRetainedValue()
    if let outLines, let p = box.ptr, box.count > 0 { outLines.update(from: p, count: box.count) }
    return SRStatus.ok
}

@_cdecl("sr_p4_hough_lines_p")
public func sr_p4_hough_lines_p(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                                _ rho: Double, _ theta: Double, _ threshold: Int32,
                                _ minLen: Double, _ maxGap: Double, _ linesMax: Int32,
                                _ outCount: UnsafeMutablePointer<Int32>?,
                                _ outHandle: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep), src.depth == .u8, src.channels == 1,
          let outCount, let outHandle else {
        return srFail(SRStatus.badArgument, "HoughLinesP: requires 1-channel uint8 image")
    }
    var ptr: UnsafeMutablePointer<Int32>? = nil
    var cnt: Int32 = 0
    let rc = sr_c_p4_hough_lines_p(src.data.assumingMemoryBound(to: UInt8.self),
                                   Int32(src.width), Int32(src.height), Int32(src.stride),
                                   rho, theta, threshold, minLen, maxGap, linesMax, &ptr, &cnt)
    if rc != 0 {
        if let ptr { sr_c_p4_free(ptr) }
        return mapHS(rc, "HoughLinesP")
    }
    outCount.pointee = cnt
    outHandle.pointee = cnt > 0 ? Unmanaged.passRetained(SRInt32BufBox(ptr, Int(cnt) * 4)).toOpaque() : nil
    return SRStatus.ok
}

@_cdecl("sr_p4_hough_lines_p_take")
public func sr_p4_hough_lines_p_take(_ handle: UnsafeMutableRawPointer?, _ outLines: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let handle else { return srFail(SRStatus.badArgument, "hough_lines_p_take: null handle") }
    let box = Unmanaged<SRInt32BufBox>.fromOpaque(handle).takeRetainedValue()
    if let outLines, let p = box.ptr, box.count > 0 { outLines.update(from: p, count: box.count) }
    return SRStatus.ok
}

@_cdecl("sr_p4_hough_circles")
public func sr_p4_hough_circles(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                                _ method: Int32, _ dp: Double, _ minDist: Double,
                                _ param1: Double, _ param2: Double, _ minR: Int32, _ maxR: Int32, _ circlesMax: Int32,
                                _ outCount: UnsafeMutablePointer<Int32>?,
                                _ outHandle: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep), src.depth == .u8, src.channels == 1,
          let outCount, let outHandle else {
        return srFail(SRStatus.badArgument, "HoughCircles: requires 1-channel uint8 image")
    }
    var ptr: UnsafeMutablePointer<Float>? = nil
    var cnt: Int32 = 0
    let rc = sr_c_p4_hough_circles(src.data.assumingMemoryBound(to: UInt8.self),
                                   Int32(src.width), Int32(src.height), Int32(src.stride),
                                   method, dp, minDist, param1, param2, minR, maxR, circlesMax, &ptr, &cnt)
    if rc != 0 {
        if let ptr { sr_c_p4_free(ptr) }
        return mapHS(rc, "HoughCircles")
    }
    outCount.pointee = cnt
    outHandle.pointee = cnt > 0 ? Unmanaged.passRetained(SRFloatBufBox(ptr, Int(cnt) * 3)).toOpaque() : nil
    return SRStatus.ok
}

@_cdecl("sr_p4_hough_circles_take")
public func sr_p4_hough_circles_take(_ handle: UnsafeMutableRawPointer?, _ outCircles: UnsafeMutablePointer<Float>?) -> Int32 {
    guard let handle else { return srFail(SRStatus.badArgument, "hough_circles_take: null handle") }
    let box = Unmanaged<SRFloatBufBox>.fromOpaque(handle).takeRetainedValue()
    if let outCircles, let p = box.ptr, box.count > 0 { outCircles.update(from: p, count: box.count) }
    return SRStatus.ok
}

// MARK: - LineSegmentDetector

@_cdecl("sr_p4_lsd_detect")
public func sr_p4_lsd_detect(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                             _ refine: Int32, _ scale: Double, _ sigmaScale: Double, _ quant: Double,
                             _ angTh: Double, _ logEps: Double, _ densityTh: Double, _ nBins: Int32,
                             _ outCount: UnsafeMutablePointer<Int32>?, _ outHasNfa: UnsafeMutablePointer<Int32>?,
                             _ outHandle: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep), src.depth == .u8, src.channels == 1,
          let outCount, let outHasNfa, let outHandle else {
        return srFail(SRStatus.badArgument, "LSD.detect: requires 1-channel uint8 image")
    }
    var pl: UnsafeMutablePointer<Float>? = nil
    var pw: UnsafeMutablePointer<Double>? = nil
    var pp: UnsafeMutablePointer<Double>? = nil
    var pn: UnsafeMutablePointer<Double>? = nil
    var cnt: Int32 = 0
    let rc = sr_c_p4_lsd_detect(src.data.assumingMemoryBound(to: UInt8.self),
                                Int32(src.width), Int32(src.height), Int32(src.stride),
                                refine, scale, sigmaScale, quant, angTh, logEps, densityTh, nBins,
                                &pl, &pw, &pp, &pn, &cnt)
    if rc != 0 {
        if let pl { sr_c_p4_free(pl) }
        if let pw { sr_c_p4_free(pw) }
        if let pp { sr_c_p4_free(pp) }
        if let pn { sr_c_p4_free(pn) }
        return mapHS(rc, "LSD.detect")
    }
    outCount.pointee = cnt
    outHasNfa.pointee = pn != nil ? 1 : 0
    outHandle.pointee = cnt > 0 ? Unmanaged.passRetained(SRLSDBox(pl, pw, pp, pn, Int(cnt))).toOpaque() : nil
    return SRStatus.ok
}

@_cdecl("sr_p4_lsd_take")
public func sr_p4_lsd_take(_ handle: UnsafeMutableRawPointer?, _ outLines: UnsafeMutablePointer<Float>?,
                           _ outWidth: UnsafeMutablePointer<Double>?, _ outPrec: UnsafeMutablePointer<Double>?,
                           _ outNfa: UnsafeMutablePointer<Double>?) -> Int32 {
    guard let handle else { return srFail(SRStatus.badArgument, "lsd_take: null handle") }
    let box = Unmanaged<SRLSDBox>.fromOpaque(handle).takeRetainedValue()
    let c = box.count
    if c > 0 {
        if let outLines, let p = box.lines { outLines.update(from: p, count: c * 4) }
        if let outWidth, let p = box.width { outWidth.update(from: p, count: c) }
        if let outPrec, let p = box.prec { outPrec.update(from: p, count: c) }
        if let outNfa, let p = box.nfa { outNfa.update(from: p, count: c) }
    }
    return SRStatus.ok
}

@_cdecl("sr_p4_lsd_draw")
public func sr_p4_lsd_draw(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                           _ lines: UnsafePointer<Float>?, _ nlines: Int32) -> Int32 {
    guard let dst = SRImage(sd, sw, sh, ss, sc, sdep), dst.depth == .u8, dst.channels == 3 else {
        return srFail(SRStatus.badArgument, "LSD.drawSegments: requires 3-channel uint8 destination")
    }
    return mapHS(sr_c_p4_lsd_draw(dst.data.assumingMemoryBound(to: UInt8.self),
                                  Int32(dst.width), Int32(dst.height), Int32(dst.stride), lines, nlines),
                 "LSD.drawSegments")
}

@_cdecl("sr_p4_lsd_compare")
public func sr_p4_lsd_compare(_ w: Int32, _ h: Int32,
                              _ l1: UnsafePointer<Float>?, _ n1: Int32,
                              _ l2: UnsafePointer<Float>?, _ n2: Int32,
                              _ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                              _ outMismatch: UnsafeMutablePointer<Int32>?) -> Int32 {
    var bgrPtr: UnsafeMutablePointer<UInt8>? = nil
    var bgrStride: Int32 = 0
    if let sd {
        guard let dst = SRImage(sd, sw, sh, ss, sc, sdep), dst.depth == .u8, dst.channels == 3,
              dst.width == Int(w), dst.height == Int(h) else {
            return srFail(SRStatus.badArgument, "LSD.compareSegments: image must be 3-channel uint8 matching size")
        }
        bgrPtr = dst.data.assumingMemoryBound(to: UInt8.self)
        bgrStride = Int32(dst.stride)
    }
    return mapHS(sr_c_p4_lsd_compare(w, h, l1, n1, l2, n2, bgrPtr, bgrStride, outMismatch), "LSD.compareSegments")
}

// MARK: - floodFill / watershed / grabCut

@_cdecl("sr_p4_flood_fill")
public func sr_p4_flood_fill(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                             _ md: UnsafeMutableRawPointer?, _ mw: Int32, _ mh: Int32, _ ms: Int32, _ mc: Int32, _ mdep: Int32,
                             _ sx: Int32, _ sy: Int32, _ newVal: UnsafePointer<Double>?,
                             _ loDiff: UnsafePointer<Double>?, _ upDiff: UnsafePointer<Double>?, _ flags: Int32,
                             _ outArea: UnsafeMutablePointer<Int32>?, _ outRect4: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let img = SRImage(sd, sw, sh, ss, sc, sdep),
          (img.depth == .u8 || img.depth == .s32 || img.depth == .f32),
          (img.channels == 1 || img.channels == 3),
          let mask = SRImage(md, mw, mh, ms, mc, mdep),
          mask.depth == .u8, mask.channels == 1,
          mask.width == img.width + 2, mask.height == img.height + 2 else {
        return srFail(SRStatus.badArgument, "floodFill: bad image or (h+2, w+2) uint8 mask")
    }
    guard sx >= 0, sx < Int32(img.width), sy >= 0, sy < Int32(img.height) else {
        return srFail(SRStatus.badArgument, "floodFill: seedPoint is outside of image")
    }
    return mapHS(sr_c_p4_flood_fill(img.data, Int32(img.width), Int32(img.height), Int32(img.stride),
                                    Int32(img.channels), img.depth.rawValue,
                                    mask.data.assumingMemoryBound(to: UInt8.self), Int32(mask.stride),
                                    sx, sy, newVal, loDiff, upDiff, flags, outArea, outRect4),
                 "floodFill")
}

@_cdecl("sr_p4_watershed")
public func sr_p4_watershed(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                            _ md: UnsafeMutableRawPointer?, _ mw: Int32, _ mh: Int32, _ ms: Int32, _ mc: Int32, _ mdep: Int32) -> Int32 {
    guard let img = SRImage(sd, sw, sh, ss, sc, sdep), img.depth == .u8, img.channels == 3,
          let markers = SRImage(md, mw, mh, ms, mc, mdep), markers.depth == .s32, markers.channels == 1,
          img.width == markers.width, img.height == markers.height else {
        return srFail(SRStatus.badArgument, "watershed: requires 3-channel uint8 image and matching 1-channel int32 markers")
    }
    return mapHS(sr_c_p4_watershed(img.data.assumingMemoryBound(to: UInt8.self),
                                   Int32(img.width), Int32(img.height), Int32(img.stride),
                                   markers.data.assumingMemoryBound(to: Int32.self), Int32(markers.stride)),
                 "watershed")
}

@_cdecl("sr_p4_grabcut")
public func sr_p4_grabcut(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                          _ md: UnsafeMutableRawPointer?, _ mw: Int32, _ mh: Int32, _ ms: Int32, _ mc: Int32, _ mdep: Int32,
                          _ rx: Int32, _ ry: Int32, _ rw: Int32, _ rh: Int32,
                          _ bgdModel: UnsafeMutablePointer<Double>?, _ fgdModel: UnsafeMutablePointer<Double>?,
                          _ iterCount: Int32, _ mode: Int32) -> Int32 {
    guard let img = SRImage(sd, sw, sh, ss, sc, sdep), img.depth == .u8, img.channels == 3,
          let mask = SRImage(md, mw, mh, ms, mc, mdep), mask.depth == .u8, mask.channels == 1,
          img.width == mask.width, img.height == mask.height else {
        return srFail(SRStatus.badArgument, "grabCut: requires 3-channel uint8 image and matching 1-channel uint8 mask")
    }
    return mapHS(sr_c_p4_grabcut(img.data.assumingMemoryBound(to: UInt8.self),
                                 Int32(img.width), Int32(img.height), Int32(img.stride),
                                 mask.data.assumingMemoryBound(to: UInt8.self), Int32(mask.stride),
                                 rx, ry, rw, rh, bgdModel, fgdModel, iterCount, mode),
                 "grabCut")
}

// MARK: - Subdiv2D

@_cdecl("sr_p4_subdiv_new")
public func sr_p4_subdiv_new() -> UnsafeMutableRawPointer? {
    sr_c_p4_subdiv_new()
}

@_cdecl("sr_p4_subdiv_free")
public func sr_p4_subdiv_free(_ ptr: UnsafeMutableRawPointer?) {
    sr_c_p4_subdiv_free(ptr)
}

@_cdecl("sr_p4_subdiv_init")
public func sr_p4_subdiv_init(_ ptr: UnsafeMutableRawPointer?, _ rx: Float, _ ry: Float, _ rw: Float, _ rh: Float) -> Int32 {
    mapHS(sr_c_p4_subdiv_init(ptr, rx, ry, rw, rh), "Subdiv2D.initDelaunay")
}

@_cdecl("sr_p4_subdiv_insert")
public func sr_p4_subdiv_insert(_ ptr: UnsafeMutableRawPointer?, _ x: Float, _ y: Float, _ outId: UnsafeMutablePointer<Int32>?) -> Int32 {
    mapHS(sr_c_p4_subdiv_insert(ptr, x, y, outId), "Subdiv2D.insert")
}

@_cdecl("sr_p4_subdiv_locate")
public func sr_p4_subdiv_locate(_ ptr: UnsafeMutableRawPointer?, _ x: Float, _ y: Float,
                                _ outLoc: UnsafeMutablePointer<Int32>?,
                                _ outEdge: UnsafeMutablePointer<Int32>?,
                                _ outVtx: UnsafeMutablePointer<Int32>?) -> Int32 {
    mapHS(sr_c_p4_subdiv_locate(ptr, x, y, outLoc, outEdge, outVtx), "Subdiv2D.locate")
}

@_cdecl("sr_p4_subdiv_nearest")
public func sr_p4_subdiv_nearest(_ ptr: UnsafeMutableRawPointer?, _ x: Float, _ y: Float,
                                 _ outPt2: UnsafeMutablePointer<Float>?, _ outVtx: UnsafeMutablePointer<Int32>?) -> Int32 {
    mapHS(sr_c_p4_subdiv_nearest(ptr, x, y, outPt2, outVtx), "Subdiv2D.findNearest")
}

@_cdecl("sr_p4_subdiv_edges")
public func sr_p4_subdiv_edges(_ ptr: UnsafeMutableRawPointer?, _ outCount: UnsafeMutablePointer<Int32>?,
                               _ outHandle: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard let outCount, let outHandle else { return srFail(SRStatus.badArgument, "Subdiv2D.getEdgeList: null arg") }
    var p: UnsafeMutablePointer<Float>? = nil
    var cnt: Int32 = 0
    let rc = sr_c_p4_subdiv_edges(ptr, &p, &cnt)
    if rc != 0 { if let p { sr_c_p4_free(p) }; return mapHS(rc, "Subdiv2D.getEdgeList") }
    outCount.pointee = cnt
    outHandle.pointee = cnt > 0 ? Unmanaged.passRetained(SRFloatBufBox(p, Int(cnt) * 4)).toOpaque() : nil
    return SRStatus.ok
}

@_cdecl("sr_p4_subdiv_edges_take")
public func sr_p4_subdiv_edges_take(_ handle: UnsafeMutableRawPointer?, _ outEdges: UnsafeMutablePointer<Float>?) -> Int32 {
    guard let handle else { return srFail(SRStatus.badArgument, "subdiv_edges_take: null handle") }
    let box = Unmanaged<SRFloatBufBox>.fromOpaque(handle).takeRetainedValue()
    if let outEdges, let p = box.ptr, box.count > 0 { outEdges.update(from: p, count: box.count) }
    return SRStatus.ok
}

@_cdecl("sr_p4_subdiv_tris")
public func sr_p4_subdiv_tris(_ ptr: UnsafeMutableRawPointer?, _ outCount: UnsafeMutablePointer<Int32>?,
                              _ outHandle: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard let outCount, let outHandle else { return srFail(SRStatus.badArgument, "Subdiv2D.getTriangleList: null arg") }
    var p: UnsafeMutablePointer<Float>? = nil
    var cnt: Int32 = 0
    let rc = sr_c_p4_subdiv_tris(ptr, &p, &cnt)
    if rc != 0 { if let p { sr_c_p4_free(p) }; return mapHS(rc, "Subdiv2D.getTriangleList") }
    outCount.pointee = cnt
    outHandle.pointee = cnt > 0 ? Unmanaged.passRetained(SRFloatBufBox(p, Int(cnt) * 6)).toOpaque() : nil
    return SRStatus.ok
}

@_cdecl("sr_p4_subdiv_tris_take")
public func sr_p4_subdiv_tris_take(_ handle: UnsafeMutableRawPointer?, _ outTris: UnsafeMutablePointer<Float>?) -> Int32 {
    guard let handle else { return srFail(SRStatus.badArgument, "subdiv_tris_take: null handle") }
    let box = Unmanaged<SRFloatBufBox>.fromOpaque(handle).takeRetainedValue()
    if let outTris, let p = box.ptr, box.count > 0 { outTris.update(from: p, count: box.count) }
    return SRStatus.ok
}

@_cdecl("sr_p4_subdiv_leading_edges")
public func sr_p4_subdiv_leading_edges(_ ptr: UnsafeMutableRawPointer?, _ outCount: UnsafeMutablePointer<Int32>?,
                                       _ outHandle: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard let outCount, let outHandle else { return srFail(SRStatus.badArgument, "Subdiv2D.getLeadingEdgeList: null arg") }
    var p: UnsafeMutablePointer<Int32>? = nil
    var cnt: Int32 = 0
    let rc = sr_c_p4_subdiv_leading_edges(ptr, &p, &cnt)
    if rc != 0 { if let p { sr_c_p4_free(p) }; return mapHS(rc, "Subdiv2D.getLeadingEdgeList") }
    outCount.pointee = cnt
    outHandle.pointee = cnt > 0 ? Unmanaged.passRetained(SRInt32BufBox(p, Int(cnt))).toOpaque() : nil
    return SRStatus.ok
}

@_cdecl("sr_p4_subdiv_leading_edges_take")
public func sr_p4_subdiv_leading_edges_take(_ handle: UnsafeMutableRawPointer?, _ outEdges: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let handle else { return srFail(SRStatus.badArgument, "subdiv_leading_edges_take: null handle") }
    let box = Unmanaged<SRInt32BufBox>.fromOpaque(handle).takeRetainedValue()
    if let outEdges, let p = box.ptr, box.count > 0 { outEdges.update(from: p, count: box.count) }
    return SRStatus.ok
}

@_cdecl("sr_p4_subdiv_voronoi")
public func sr_p4_subdiv_voronoi(_ ptr: UnsafeMutableRawPointer?, _ idx: UnsafePointer<Int32>?, _ nidx: Int32,
                                 _ outNFacets: UnsafeMutablePointer<Int32>?, _ outTotalPts: UnsafeMutablePointer<Int32>?,
                                 _ outHandle: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard let outNFacets, let outTotalPts, let outHandle else {
        return srFail(SRStatus.badArgument, "Subdiv2D.getVoronoiFacetList: null arg")
    }
    var pPts: UnsafeMutablePointer<Float>? = nil
    var pCnts: UnsafeMutablePointer<Int32>? = nil
    var pCenters: UnsafeMutablePointer<Float>? = nil
    var nf: Int32 = 0
    let rc = sr_c_p4_subdiv_voronoi(ptr, idx, nidx, &pPts, &pCnts, &pCenters, &nf)
    if rc != 0 {
        if let pPts { sr_c_p4_free(pPts) }
        if let pCnts { sr_c_p4_free(pCnts) }
        if let pCenters { sr_c_p4_free(pCenters) }
        return mapHS(rc, "Subdiv2D.getVoronoiFacetList")
    }
    var totalPts = 0
    if let pCnts, nf > 0 {
        for i in 0..<Int(nf) { totalPts += Int(pCnts[i]) }
    }
    outNFacets.pointee = nf
    outTotalPts.pointee = Int32(totalPts)
    outHandle.pointee = nf > 0 ? Unmanaged.passRetained(SRVoronoiBox(pPts, pCnts, pCenters, Int(nf), totalPts)).toOpaque() : nil
    if nf == 0 {
        if let pPts { sr_c_p4_free(pPts) }
        if let pCnts { sr_c_p4_free(pCnts) }
        if let pCenters { sr_c_p4_free(pCenters) }
    }
    return SRStatus.ok
}

@_cdecl("sr_p4_subdiv_voronoi_take")
public func sr_p4_subdiv_voronoi_take(_ handle: UnsafeMutableRawPointer?, _ outPts: UnsafeMutablePointer<Float>?,
                                      _ outCounts: UnsafeMutablePointer<Int32>?, _ outCenters: UnsafeMutablePointer<Float>?) -> Int32 {
    guard let handle else { return srFail(SRStatus.badArgument, "subdiv_voronoi_take: null handle") }
    let box = Unmanaged<SRVoronoiBox>.fromOpaque(handle).takeRetainedValue()
    if box.nfacets > 0 {
        if let outCounts, let p = box.counts { outCounts.update(from: p, count: box.nfacets) }
        if let outCenters, let p = box.centers { outCenters.update(from: p, count: box.nfacets * 2) }
        if let outPts, let p = box.pts, box.totalPts > 0 { outPts.update(from: p, count: box.totalPts * 2) }
    }
    return SRStatus.ok
}

@_cdecl("sr_p4_subdiv_vertex")
public func sr_p4_subdiv_vertex(_ ptr: UnsafeMutableRawPointer?, _ vid: Int32,
                                _ outPt2: UnsafeMutablePointer<Float>?, _ outEdge: UnsafeMutablePointer<Int32>?) -> Int32 {
    mapHS(sr_c_p4_subdiv_vertex(ptr, vid, outPt2, outEdge), "Subdiv2D.getVertex")
}

@_cdecl("sr_p4_subdiv_get_edge")
public func sr_p4_subdiv_get_edge(_ ptr: UnsafeMutableRawPointer?, _ edge: Int32, _ nextType: Int32) -> Int32 {
    sr_c_p4_subdiv_get_edge(ptr, edge, nextType)
}

@_cdecl("sr_p4_subdiv_next_edge")
public func sr_p4_subdiv_next_edge(_ ptr: UnsafeMutableRawPointer?, _ edge: Int32) -> Int32 {
    sr_c_p4_subdiv_next_edge(ptr, edge)
}

@_cdecl("sr_p4_subdiv_rotate_edge")
public func sr_p4_subdiv_rotate_edge(_ edge: Int32, _ rot: Int32) -> Int32 {
    sr_c_p4_subdiv_rotate_edge(edge, rot)
}

@_cdecl("sr_p4_subdiv_sym_edge")
public func sr_p4_subdiv_sym_edge(_ edge: Int32) -> Int32 {
    sr_c_p4_subdiv_sym_edge(edge)
}

@_cdecl("sr_p4_subdiv_edge_org")
public func sr_p4_subdiv_edge_org(_ ptr: UnsafeMutableRawPointer?, _ edge: Int32,
                                  _ outPt2: UnsafeMutablePointer<Float>?, _ outVtx: UnsafeMutablePointer<Int32>?) -> Int32 {
    mapHS(sr_c_p4_subdiv_edge_org(ptr, edge, outPt2, outVtx), "Subdiv2D.edgeOrg")
}

@_cdecl("sr_p4_subdiv_edge_dst")
public func sr_p4_subdiv_edge_dst(_ ptr: UnsafeMutableRawPointer?, _ edge: Int32,
                                  _ outPt2: UnsafeMutablePointer<Float>?, _ outVtx: UnsafeMutablePointer<Int32>?) -> Int32 {
    mapHS(sr_c_p4_subdiv_edge_dst(ptr, edge, outPt2, outVtx), "Subdiv2D.edgeDst")
}
