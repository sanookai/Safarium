// SafariumRaster — Phase 4: Contours & Geometry C-ABI entry points backed by geo_p4.c.
// All heavy geometry runs in C11 (geo_p4.c), bound via @_silgen_name and exposed via @_cdecl("sr_p4_...").

import Foundation

// MARK: - C bindings (Sources/SafariumRasterC/geo_p4.c)

@_silgen_name("sr_c_p4_arc_length")
private func sr_c_p4_arc_length(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32, _ closed: Int32,
                                _ outLen: UnsafeMutablePointer<Double>?) -> Int32

@_silgen_name("sr_c_p4_point_polygon_test")
private func sr_c_p4_point_polygon_test(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32,
                                        _ px: Double, _ py: Double, _ measureDist: Int32,
                                        _ outVal: UnsafeMutablePointer<Double>?) -> Int32

@_silgen_name("sr_c_p4_bounding_rect_pts")
private func sr_c_p4_bounding_rect_pts(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32,
                                       _ outXYWH: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_bounding_rect_img")
private func sr_c_p4_bounding_rect_img(_ img: UnsafePointer<UInt8>?, _ w: Int32, _ h: Int32,
                                       _ stride: Int32, _ outXYWH: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_contour_area")
private func sr_c_p4_contour_area(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32, _ oriented: Int32,
                                  _ outArea: UnsafeMutablePointer<Double>?) -> Int32

@_silgen_name("sr_c_p4_is_contour_convex")
private func sr_c_p4_is_contour_convex(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32,
                                       _ outConvex: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_convex_hull")
private func sr_c_p4_convex_hull(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32, _ clockwise: Int32,
                                 _ outIdx: UnsafeMutablePointer<Int32>?, _ outK: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_convexity_defects")
private func sr_c_p4_convexity_defects(_ pts: UnsafePointer<Int32>?, _ n: Int32,
                                       _ hull: UnsafePointer<Int32>?, _ h: Int32,
                                       _ outDefects: UnsafeMutablePointer<Int32>?,
                                       _ outK: UnsafeMutablePointer<Int32>?) -> Int32

@_silgen_name("sr_c_p4_min_area_rect")
private func sr_c_p4_min_area_rect(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32,
                                   _ out5: UnsafeMutablePointer<Float>?) -> Int32

@_silgen_name("sr_c_p4_box_points")
private func sr_c_p4_box_points(_ cx: Float, _ cy: Float, _ w: Float, _ h: Float, _ angle: Float,
                                _ outPts8: UnsafeMutablePointer<Float>?) -> Int32

@_silgen_name("sr_c_p4_min_enclosing_circle")
private func sr_c_p4_min_enclosing_circle(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32,
                                          _ out3: UnsafeMutablePointer<Float>?) -> Int32

@_silgen_name("sr_c_p4_min_enclosing_triangle")
private func sr_c_p4_min_enclosing_triangle(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32,
                                            _ outArea: UnsafeMutablePointer<Double>?,
                                            _ outTri6: UnsafeMutablePointer<Float>?) -> Int32

@_silgen_name("sr_c_p4_fit_ellipse")
private func sr_c_p4_fit_ellipse(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32, _ method: Int32,
                                 _ out5: UnsafeMutablePointer<Float>?) -> Int32

@_silgen_name("sr_c_p4_fit_line")
private func sr_c_p4_fit_line(_ pts: UnsafeRawPointer?, _ n: Int32, _ dims: Int32, _ isF32: Int32,
                              _ distType: Int32, _ param: Double, _ reps: Double, _ aeps: Double,
                              _ outLine: UnsafeMutablePointer<Float>?) -> Int32

@_silgen_name("sr_c_p4_moments_pts")
private func sr_c_p4_moments_pts(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32,
                                 _ out24: UnsafeMutablePointer<Double>?) -> Int32

@_silgen_name("sr_c_p4_moments_img")
private func sr_c_p4_moments_img(_ img: UnsafeRawPointer?, _ w: Int32, _ h: Int32, _ stride: Int32,
                                 _ depth: Int32, _ binary: Int32, _ out24: UnsafeMutablePointer<Double>?) -> Int32

@_silgen_name("sr_c_p4_hu_moments")
private func sr_c_p4_hu_moments(_ m24: UnsafePointer<Double>?, _ hu7: UnsafeMutablePointer<Double>?) -> Int32

@_silgen_name("sr_c_p4_match_shapes")
private func sr_c_p4_match_shapes(_ m24a: UnsafePointer<Double>?, _ m24b: UnsafePointer<Double>?,
                                  _ method: Int32, _ param: Double, _ outVal: UnsafeMutablePointer<Double>?) -> Int32

@_silgen_name("sr_c_p4_intersect_convex_convex")
private func sr_c_p4_intersect_convex_convex(_ p1: UnsafePointer<Float>?, _ n1: Int32,
                                             _ p2: UnsafePointer<Float>?, _ n2: Int32,
                                             _ handleNested: Int32, _ outPts: UnsafeMutablePointer<Float>?,
                                             _ outK: UnsafeMutablePointer<Int32>?,
                                             _ outArea: UnsafeMutablePointer<Float>?) -> Int32

@_silgen_name("sr_c_p4_rot_rect_intersection")
private func sr_c_p4_rot_rect_intersection(_ r1: UnsafePointer<Float>?, _ r2: UnsafePointer<Float>?,
                                           _ outPts: UnsafeMutablePointer<Float>?,
                                           _ outK: UnsafeMutablePointer<Int32>?,
                                           _ outType: UnsafeMutablePointer<Int32>?) -> Int32

// MARK: - Helpers

@inline(__always)
private func mapStatus(_ rc: Int32, _ fnName: String) -> Int32 {
    if rc == 0 { return SRStatus.ok }
    if rc == -2 { return srFail(SRStatus.unsupported, "\(fnName): unsupported mode or format") }
    if rc == -4 { return srFail(SRStatus.internalError, "\(fnName): out of memory") }
    return srFail(SRStatus.badArgument, "\(fnName): invalid argument")
}

// MARK: - Exported C-ABI entry points

@_cdecl("sr_p4_arc_length")
public func sr_p4_arc_length(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32, _ closed: Int32,
                             _ outLen: UnsafeMutablePointer<Double>?) -> Int32 {
    mapStatus(sr_c_p4_arc_length(pts, n, isF32, closed, outLen), "arcLength")
}

@_cdecl("sr_p4_point_polygon_test")
public func sr_p4_point_polygon_test(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32,
                                     _ px: Double, _ py: Double, _ measureDist: Int32,
                                     _ outVal: UnsafeMutablePointer<Double>?) -> Int32 {
    mapStatus(sr_c_p4_point_polygon_test(pts, n, isF32, px, py, measureDist, outVal), "pointPolygonTest")
}

@_cdecl("sr_p4_bounding_rect_pts")
public func sr_p4_bounding_rect_pts(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32,
                                    _ outXYWH: UnsafeMutablePointer<Int32>?) -> Int32 {
    mapStatus(sr_c_p4_bounding_rect_pts(pts, n, isF32, outXYWH), "boundingRect")
}

@_cdecl("sr_p4_bounding_rect_img")
public func sr_p4_bounding_rect_img(_ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32,
                                    _ ss: Int32, _ sc: Int32, _ sdep: Int32,
                                    _ outXYWH: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep), src.depth == .u8, src.channels == 1, let outXYWH else {
        return srFail(SRStatus.badArgument, "boundingRect: requires 1-channel uint8 image")
    }
    return mapStatus(sr_c_p4_bounding_rect_img(src.data.assumingMemoryBound(to: UInt8.self),
                                               Int32(src.width), Int32(src.height), Int32(src.stride), outXYWH),
                     "boundingRect")
}

@_cdecl("sr_p4_contour_area")
public func sr_p4_contour_area(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32, _ oriented: Int32,
                               _ outArea: UnsafeMutablePointer<Double>?) -> Int32 {
    mapStatus(sr_c_p4_contour_area(pts, n, isF32, oriented, outArea), "contourArea")
}

@_cdecl("sr_p4_is_contour_convex")
public func sr_p4_is_contour_convex(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32,
                                    _ outConvex: UnsafeMutablePointer<Int32>?) -> Int32 {
    mapStatus(sr_c_p4_is_contour_convex(pts, n, isF32, outConvex), "isContourConvex")
}

@_cdecl("sr_p4_convex_hull")
public func sr_p4_convex_hull(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32, _ clockwise: Int32,
                              _ outIdx: UnsafeMutablePointer<Int32>?, _ outK: UnsafeMutablePointer<Int32>?) -> Int32 {
    mapStatus(sr_c_p4_convex_hull(pts, n, isF32, clockwise, outIdx, outK), "convexHull")
}

@_cdecl("sr_p4_convexity_defects")
public func sr_p4_convexity_defects(_ pts: UnsafePointer<Int32>?, _ n: Int32,
                                    _ hull: UnsafePointer<Int32>?, _ h: Int32,
                                    _ outDefects: UnsafeMutablePointer<Int32>?,
                                    _ outK: UnsafeMutablePointer<Int32>?) -> Int32 {
    mapStatus(sr_c_p4_convexity_defects(pts, n, hull, h, outDefects, outK), "convexityDefects")
}

@_cdecl("sr_p4_min_area_rect")
public func sr_p4_min_area_rect(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32,
                                _ out5: UnsafeMutablePointer<Float>?) -> Int32 {
    mapStatus(sr_c_p4_min_area_rect(pts, n, isF32, out5), "minAreaRect")
}

@_cdecl("sr_p4_box_points")
public func sr_p4_box_points(_ cx: Float, _ cy: Float, _ w: Float, _ h: Float, _ angle: Float,
                             _ outPts8: UnsafeMutablePointer<Float>?) -> Int32 {
    mapStatus(sr_c_p4_box_points(cx, cy, w, h, angle, outPts8), "boxPoints")
}

@_cdecl("sr_p4_min_enclosing_circle")
public func sr_p4_min_enclosing_circle(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32,
                                       _ out3: UnsafeMutablePointer<Float>?) -> Int32 {
    mapStatus(sr_c_p4_min_enclosing_circle(pts, n, isF32, out3), "minEnclosingCircle")
}

@_cdecl("sr_p4_min_enclosing_triangle")
public func sr_p4_min_enclosing_triangle(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32,
                                         _ outArea: UnsafeMutablePointer<Double>?,
                                         _ outTri6: UnsafeMutablePointer<Float>?) -> Int32 {
    mapStatus(sr_c_p4_min_enclosing_triangle(pts, n, isF32, outArea, outTri6), "minEnclosingTriangle")
}

@_cdecl("sr_p4_fit_ellipse")
public func sr_p4_fit_ellipse(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32, _ method: Int32,
                              _ out5: UnsafeMutablePointer<Float>?) -> Int32 {
    guard n >= 5 else {
        return srFail(SRStatus.badArgument, "fitEllipse: at least 5 points are required")
    }
    return mapStatus(sr_c_p4_fit_ellipse(pts, n, isF32, method, out5), "fitEllipse")
}

@_cdecl("sr_p4_fit_line")
public func sr_p4_fit_line(_ pts: UnsafeRawPointer?, _ n: Int32, _ dims: Int32, _ isF32: Int32,
                           _ distType: Int32, _ param: Double, _ reps: Double, _ aeps: Double,
                           _ outLine: UnsafeMutablePointer<Float>?) -> Int32 {
    guard n > 0 else {
        return srFail(SRStatus.badArgument, "fitLine: count > 0 required")
    }
    return mapStatus(sr_c_p4_fit_line(pts, n, dims, isF32, distType, param, reps, aeps, outLine), "fitLine")
}

@_cdecl("sr_p4_moments_pts")
public func sr_p4_moments_pts(_ pts: UnsafeRawPointer?, _ n: Int32, _ isF32: Int32,
                              _ out24: UnsafeMutablePointer<Double>?) -> Int32 {
    mapStatus(sr_c_p4_moments_pts(pts, n, isF32, out24), "moments")
}

@_cdecl("sr_p4_moments_img")
public func sr_p4_moments_img(_ sd: UnsafeRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32,
                              _ sc: Int32, _ sdep: Int32, _ binary: Int32,
                              _ out24: UnsafeMutablePointer<Double>?) -> Int32 {
    guard sc == 1, sw >= 0, sh >= 0, let out24 else {
        return srFail(SRStatus.badArgument, "moments: requires single-channel raster image")
    }
    if sw == 0 || sh == 0 {
        for i in 0..<24 { out24[i] = 0.0 }
        return SRStatus.ok
    }
    guard let sd else { return srFail(SRStatus.badArgument, "moments: null image") }
    let elemBytes: Int
    switch sdep {
    case 0: elemBytes = 1
    case 2, 3: elemBytes = 2
    case 5: elemBytes = 4
    case 6: elemBytes = 8
    default: return srFail(SRStatus.unsupported, "moments: unsupported image depth \(sdep)")
    }
    guard Int(ss) >= Int(sw) * elemBytes else {
        return srFail(SRStatus.badArgument, "moments: invalid stride")
    }
    return mapStatus(sr_c_p4_moments_img(sd, sw, sh, ss, sdep, binary, out24), "moments")
}

@_cdecl("sr_p4_hu_moments")
public func sr_p4_hu_moments(_ m24: UnsafePointer<Double>?, _ hu7: UnsafeMutablePointer<Double>?) -> Int32 {
    mapStatus(sr_c_p4_hu_moments(m24, hu7), "HuMoments")
}

@_cdecl("sr_p4_match_shapes")
public func sr_p4_match_shapes(_ m24a: UnsafePointer<Double>?, _ m24b: UnsafePointer<Double>?,
                               _ method: Int32, _ param: Double, _ outVal: UnsafeMutablePointer<Double>?) -> Int32 {
    mapStatus(sr_c_p4_match_shapes(m24a, m24b, method, param, outVal), "matchShapes")
}

@_cdecl("sr_p4_intersect_convex_convex")
public func sr_p4_intersect_convex_convex(_ p1: UnsafePointer<Float>?, _ n1: Int32,
                                          _ p2: UnsafePointer<Float>?, _ n2: Int32,
                                          _ handleNested: Int32, _ outPts: UnsafeMutablePointer<Float>?,
                                          _ outK: UnsafeMutablePointer<Int32>?,
                                          _ outArea: UnsafeMutablePointer<Float>?) -> Int32 {
    mapStatus(sr_c_p4_intersect_convex_convex(p1, n1, p2, n2, handleNested, outPts, outK, outArea),
                     "intersectConvexConvex")
}

@_cdecl("sr_p4_rot_rect_intersection")
public func sr_p4_rot_rect_intersection(_ r1: UnsafePointer<Float>?, _ r2: UnsafePointer<Float>?,
                                        _ outPts: UnsafeMutablePointer<Float>?,
                                        _ outK: UnsafeMutablePointer<Int32>?,
                                        _ outType: UnsafeMutablePointer<Int32>?) -> Int32 {
    mapStatus(sr_c_p4_rot_rect_intersection(r1, r2, outPts, outK, outType), "rotatedRectangleIntersection")
}
