// SafariumRaster — cv::connectedComponents(WithStats): delegates to C99/NEON cc_fast.c
// (4-connected run-length union-find + 8-connected native 2x2 BBDT). Matches OpenCV's exact
// label ordering, stats, and centroids. Background = label 0 (included in stats).

import Foundation

@_silgen_name("sr_c_connected_components")
private func sr_c_connected_components(_ src: UnsafePointer<UInt8>?, _ sstep: Int,
                                       _ lab: UnsafeMutablePointer<Int32>?, _ lstep: Int,
                                       _ w: Int32, _ h: Int32, _ connectivity: Int32,
                                       _ outN: UnsafeMutablePointer<Int32>?,
                                       _ outHandle: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32

@_silgen_name("sr_c_cc_take")
private func sr_c_cc_take(_ handle: UnsafeMutableRawPointer?,
                          _ stats: UnsafeMutablePointer<Int32>?,
                          _ centroids: UnsafeMutablePointer<Double>?) -> Int32

@_cdecl("sr_connected_components")
public func sr_connected_components(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                                    _ ld: UnsafeMutableRawPointer?, _ lw: Int32, _ lh: Int32, _ ls: Int32, _ lc: Int32, _ ldep: Int32,
                                    _ connectivity: Int32, _ outN: UnsafeMutablePointer<Int32>?,
                                    _ outHandle: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep), let lab = SRImage(ld, lw, lh, ls, lc, ldep),
          src.depth == .u8, src.channels == 1, lab.depth == .s32, lab.channels == 1,
          src.width == lab.width, src.height == lab.height, connectivity == 4 || connectivity == 8,
          let outN else {
        return srFail(SRStatus.badArgument, "connectedComponents: need 1-channel u8 image, int32 labels, connectivity 4 or 8")
    }
    let rc = sr_c_connected_components(src.data.assumingMemoryBound(to: UInt8.self), src.stride,
                                       lab.data.assumingMemoryBound(to: Int32.self), lab.stride,
                                       Int32(src.width), Int32(src.height), connectivity,
                                       outN, outHandle)
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.internalError, "connectedComponents: allocation failed")
}

/// Copies stats (n*5 int32) and centroids (n*2 f64) out of the handle and releases it.
@_cdecl("sr_cc_take")
public func sr_cc_take(_ handle: UnsafeMutableRawPointer?, _ stats: UnsafeMutablePointer<Int32>?,
                       _ centroids: UnsafeMutablePointer<Double>?) -> Int32 {
    guard let handle else { return srFail(SRStatus.badArgument, "cc_take: null handle") }
    let rc = sr_c_cc_take(handle, stats, centroids)
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.badArgument, "cc_take: invalid handle")
}
