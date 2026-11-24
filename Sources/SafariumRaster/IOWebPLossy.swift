// SafariumRaster — own VP8 key-frame encoder for lossy WebP (Area C). The encoder core (intra 16x16 / 4x4 / chroma
// prediction, segments, RD mode decision, tokens, boolean coder) lives in Sources/SafariumRasterC/webp_vp8.c, written from
// RFC 6386 (the VP8 Data Format and Decoding Guide). This file converts the image to 4:2:0 YUV row by row (no whole-image
// RGB copy) and calls the core.

import Foundation

@_silgen_name("sr_vp8_encode")
private func sr_vp8_encode(_ y: UnsafePointer<UInt8>, _ u: UnsafePointer<UInt8>, _ v: UnsafePointer<UInt8>, _ ys: Int32, _ cs: Int32,
                           _ mbw: Int32, _ mbh: Int32, _ w: Int32, _ h: Int32, _ quality: Int32,
                           _ defProbs: UnsafePointer<UInt8>, _ updProbs: UnsafePointer<UInt8>,
                           _ dcq: UnsafePointer<Int32>, _ acq: UnsafePointer<Int32>,
                           _ out: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>) -> Int64

@_silgen_name("sr_vp8_free")
private func sr_vp8_free(_ p: UnsafeMutablePointer<UInt8>?)

@_silgen_name("sr_vp8_yuv_rows")
private func sr_vp8_yuv_rows(_ r0: UnsafePointer<UInt8>, _ r1: UnsafePointer<UInt8>, _ ch: Int32, _ w: Int32, _ pw: Int32,
                             _ y0: UnsafeMutablePointer<UInt8>, _ y1: UnsafeMutablePointer<UInt8>,
                             _ u: UnsafeMutablePointer<UInt8>, _ v: UnsafeMutablePointer<UInt8>)

private let vp8DCQ32: [Int32] = vp8DCQ.map { Int32($0) }
private let vp8ACQ32: [Int32] = vp8ACQ.map { Int32($0) }

func ioWebPLossyBitstream(_ img: SRImage, quality: Int) -> [UInt8]? {
    let w = img.width, h = img.height
    guard ioWebPValidDimensions(w, h), img.channels != 2 else { return nil }
    let mbw = (w + 15) / 16, mbh = (h + 15) / 16
    let ys = mbw * 16, cs = mbw * 8
    let ch = img.channels
    let Y = UnsafeMutablePointer<UInt8>.allocate(capacity: ys * mbh * 16)
    let U = UnsafeMutablePointer<UInt8>.allocate(capacity: cs * mbh * 8)
    let V = UnsafeMutablePointer<UInt8>.allocate(capacity: cs * mbh * 8)
    let rows = UnsafeMutablePointer<UInt8>.allocate(capacity: 2 * (w * ch + 8))
    defer { Y.deallocate(); U.deallocate(); V.deallocate(); rows.deallocate() }
    let stride = w * ch + 8
    for my in 0..<(mbh * 8) {
        let ya = min(2 * my, h - 1), yb = min(2 * my + 1, h - 1)
        ioRowU8(img, ya, rows)
        ioRowU8(img, yb, rows + stride)
        sr_vp8_yuv_rows(rows, rows + stride, Int32(ch), Int32(w), Int32(ys), Y + (2 * my) * ys, Y + (2 * my + 1) * ys,
                        U + my * cs, V + my * cs)
    }
    var out: UnsafeMutablePointer<UInt8>? = nil
    let n = vp8DefaultCoeffProbs.withUnsafeBufferPointer { dp in
        vp8CoeffUpdateProbs.withUnsafeBufferPointer { up in
            vp8DCQ32.withUnsafeBufferPointer { dq in
                vp8ACQ32.withUnsafeBufferPointer { aq in
                    sr_vp8_encode(Y, U, V, Int32(ys), Int32(cs), Int32(mbw), Int32(mbh), Int32(w), Int32(h), Int32(quality),
                                  dp.baseAddress!, up.baseAddress!, dq.baseAddress!, aq.baseAddress!, &out)
                }
            }
        }
    }
    guard n > 0, let out else { return nil }
    defer { sr_vp8_free(out) }
    return Array(UnsafeBufferPointer(start: out, count: Int(n)))
}
