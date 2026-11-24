// SafariumRaster — cvtColor BGR/RGB(A) -> HSV for 8-bit images (port of OpenCV 5.1 RGB2HSV_b, hrange 180).
//
// The numpy version needed ~260 MiB of int64 temporaries for a 1080x1920 frame. The kernel (core_hsv.c, NEON) streams rows
// straight from the source into the destination with three small tables supplied by the caller (they stay in _numpy_ops.py,
// where they were fitted exhaustively against the reference):
//   sLut      65536 bytes, [v * 256 + (v - min)] -> S for pixels OpenCV handles in its 8-pixel SIMD blocks
//   sLutTail  same index, S for the last (cols % 8) pixels of each row (OpenCV's scalar tail rounds differently)
//   hdiv      256 Int32, round((180 << 12) / (6 * diff)), 0 for diff 0

import Foundation
import SafariumRasterC

/// src: rows x cols pixels of `scn` (3 or 4) u8 channels; dst: rows x cols x 3 u8. `blueIdx` is 0 for BGR, 2 for RGB.
@_cdecl("sr_core_hsv_u8")
public func sr_core_hsv_u8(_ src: UnsafeRawPointer?, _ srcStep: Int, _ dst: UnsafeMutableRawPointer?, _ dstStep: Int,
                           _ rows: Int, _ cols: Int, _ scn: Int32, _ blueIdx: Int32,
                           _ sLut: UnsafePointer<UInt8>?, _ sLutTail: UnsafePointer<UInt8>?, _ hdiv: UnsafePointer<Int32>?) -> Int32 {
    guard let src = src, let dst = dst, let sLut = sLut, let sLutTail = sLutTail, let hdiv = hdiv,
          rows >= 0, cols >= 0, rows < (1 << 31), cols < (1 << 31), scn == 3 || scn == 4, blueIdx == 0 || blueIdx == 2,
          srcStep >= cols * Int(scn), dstStep >= cols * 3 else {
        return srFail(SRStatus.badArgument, "hsv: bad arguments")
    }
    src_hsv_u8(src.assumingMemoryBound(to: UInt8.self), srcStep, dst.assumingMemoryBound(to: UInt8.self), dstStep,
               Int32(rows), Int32(cols), scn, blueIdx, sLut, sLutTail, hdiv)
    return 0
}
