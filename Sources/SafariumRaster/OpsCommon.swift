// SafariumRaster — area B (image ops): shared helpers.
// Algorithms follow OpenCV semantics (Apache-2.0); re-written in Swift, no OpenCV code linked.

import Foundation
import Accelerate

/// Pixel element types the image ops support (u8 and f32).
protocol SRPix {
    static var zero: Self { get }
    var asFloat: Float { get }
    /// Round-half-up + saturate for integer types; identity for floats.
    static func fromFloat(_ v: Float) -> Self
    /// dst[i] = convert(src[i] + add) for i in 0..<n (vectorised, same rounding as fromFloat).
    static func storeRow(_ src: UnsafePointer<Float>, _ dst: UnsafeMutablePointer<Self>, _ n: Int, _ add: Float)
    /// dst[i] = Float(src[i]) (vectorised).
    static func toFloatRow(_ src: UnsafePointer<Self>, _ dst: UnsafeMutablePointer<Float>, _ n: Int)
    /// 16 consecutive elements as floats (unaligned).
    static func load16(_ p: UnsafePointer<Self>) -> SIMD16<Float>
}

extension UInt8: SRPix {
    static var zero: UInt8 { 0 }
    @inline(__always) var asFloat: Float { Float(self) }
    @inline(__always) static func fromFloat(_ v: Float) -> UInt8 {
        let t = v + 0.5
        return t <= 0 ? 0 : (t >= 255 ? 255 : UInt8(t))
    }
    @inline(__always) static func load16(_ p: UnsafePointer<UInt8>) -> SIMD16<Float> {
        SIMD16<Float>(UnsafeRawPointer(p).loadUnaligned(as: SIMD16<UInt8>.self))
    }
    static func toFloatRow(_ src: UnsafePointer<UInt8>, _ dst: UnsafeMutablePointer<Float>, _ n: Int) {
        vDSP_vfltu8(src, 1, dst, 1, vDSP_Length(n))
    }
    static func storeRow(_ src: UnsafePointer<Float>, _ dst: UnsafeMutablePointer<UInt8>, _ n: Int, _ add: Float) {
        // round half up + saturate: vDSP truncating convert after adding 0.5 (chunked through a small scratch buffer)
        withUnsafeTemporaryAllocation(of: Float.self, capacity: 2048) { tmp in
            var a = add + 0.5
            var i = 0
            while i < n {
                let m = Swift.min(2048, n - i)
                vDSP_vsadd(src + i, 1, &a, tmp.baseAddress!, 1, vDSP_Length(m))
                vDSP_vfixu8(tmp.baseAddress!, 1, dst + i, 1, vDSP_Length(m))
                i += m
            }
        }
    }
}

extension UInt16: SRPix {
    static var zero: UInt16 { 0 }
    @inline(__always) var asFloat: Float { Float(self) }
    @inline(__always) static func fromFloat(_ v: Float) -> UInt16 {
        let t = v + 0.5
        return t <= 0 ? 0 : (t >= 65535 ? 65535 : UInt16(t))
    }
    @inline(__always) static func load16(_ p: UnsafePointer<UInt16>) -> SIMD16<Float> {
        SIMD16<Float>(UnsafeRawPointer(p).loadUnaligned(as: SIMD16<UInt16>.self))
    }
    static func toFloatRow(_ src: UnsafePointer<UInt16>, _ dst: UnsafeMutablePointer<Float>, _ n: Int) {
        vDSP_vfltu16(src, 1, dst, 1, vDSP_Length(n))
    }
    static func storeRow(_ src: UnsafePointer<Float>, _ dst: UnsafeMutablePointer<UInt16>, _ n: Int, _ add: Float) {
        withUnsafeTemporaryAllocation(of: Float.self, capacity: 2048) { tmp in
            var a = add + 0.5
            var i = 0
            while i < n {
                let m = Swift.min(2048, n - i)
                vDSP_vsadd(src + i, 1, &a, tmp.baseAddress!, 1, vDSP_Length(m))
                vDSP_vfixu16(tmp.baseAddress!, 1, dst + i, 1, vDSP_Length(m))
                i += m
            }
        }
    }
}

extension Float: SRPix {
    static var zero: Float { 0 }
    @inline(__always) var asFloat: Float { self }
    @inline(__always) static func fromFloat(_ v: Float) -> Float { v }
    @inline(__always) static func load16(_ p: UnsafePointer<Float>) -> SIMD16<Float> {
        UnsafeRawPointer(p).loadUnaligned(as: SIMD16<Float>.self)
    }
    static func toFloatRow(_ src: UnsafePointer<Float>, _ dst: UnsafeMutablePointer<Float>, _ n: Int) {
        dst.update(from: src, count: n)
    }
    static func storeRow(_ src: UnsafePointer<Float>, _ dst: UnsafeMutablePointer<Float>, _ n: Int, _ add: Float) {
        if add == 0 { dst.update(from: src, count: n); return }
        for i in 0..<n { dst[i] = src[i] + add }
    }
}

// OpenCV border codes.
let SR_BORDER_CONSTANT: Int32 = 0
let SR_BORDER_REPLICATE: Int32 = 1
let SR_BORDER_REFLECT: Int32 = 2
let SR_BORDER_WRAP: Int32 = 3
let SR_BORDER_REFLECT_101: Int32 = 4
let SR_BORDER_TRANSPARENT: Int32 = 5

/// cv::borderInterpolate: maps p outside [0, len) into range, or -1 for BORDER_CONSTANT/TRANSPARENT.
@inline(__always) func srBorderInterp(_ p: Int, _ len: Int, _ type: Int32) -> Int {
    if p >= 0 && p < len { return p }
    if len == 1 { return type == SR_BORDER_CONSTANT || type == SR_BORDER_TRANSPARENT ? -1 : 0 }
    switch type {
    case SR_BORDER_REPLICATE:
        return p < 0 ? 0 : len - 1
    case SR_BORDER_REFLECT, SR_BORDER_REFLECT_101:
        let delta = type == SR_BORDER_REFLECT_101 ? 1 : 0
        let period = 2 * (len - 1 + (1 - delta) )  // reflect: 2*len ; reflect101: 2*(len-1)
        var q = p
        // fold into [0, period)
        q %= period
        if q < 0 { q += period }
        if type == SR_BORDER_REFLECT_101 {
            return q < len ? q : period - q
        } else {
            return q < len ? q : period - 1 - q
        }
    case SR_BORDER_WRAP:
        var q = p % len
        if q < 0 { q += len }
        return q
    default:
        return -1
    }
}

/// Reads an Int32 array of 6 image scalars into an SRImage or fails.
func srImg(_ d: UnsafeMutableRawPointer?, _ w: Int32, _ h: Int32, _ s: Int32, _ c: Int32, _ dep: Int32) -> SRImage? {
    SRImage(d, w, h, s, c, dep)
}

@inline(__always) func srFloor(_ v: Double) -> Int { Int(v.rounded(.down)) }

/// Runs `body` rows [0,rows) split over srNumThreads workers (1 by default → inline).
func srParallelRows(_ rows: Int, _ body: @escaping (Range<Int>) -> Void) {
    let n = min(srNumThreads, max(1, rows))
    if n <= 1 { body(0..<rows); return }
    let chunk = (rows + n - 1) / n
    DispatchQueue.concurrentPerform(iterations: n) { i in
        let a = i * chunk, b = min(rows, a + chunk)
        if a < b { body(a..<b) }
    }
}
