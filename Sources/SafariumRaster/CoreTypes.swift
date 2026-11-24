// SafariumRaster — Phase 1 (core-numeric): shared types for Core*.swift.
//
// Matrices cross the ABI as a `CoreMat` struct passed by pointer (ctypes.Structure on the Python side) so that all
// seven OpenCV depths (u8, s8, u16, s16, s32, f32, f64) and any channel count are expressible; ABI.swift's SRImage
// only knows four depths. Rows may be strided, elements within a row are contiguous (the shim guarantees this).
// Numeric rules (cvRound = ties-to-even, saturate_cast, NaN -> 0 for integer targets) follow OpenCV 5.1 core.

import Foundation

public struct CoreMat {
    public var data: UnsafeMutableRawPointer?
    public var rows: Int
    public var cols: Int
    public var step: Int      // bytes between row starts
    public var cn: Int32
    public var depth: Int32   // OpenCV depth code: 0 u8, 1 s8, 2 u16, 3 s16, 4 s32, 5 f32, 6 f64

    @inline(__always) var n: Int { cols * Int(cn) }   // elements per row
    @inline(__always) var elemSize: Int { coreElemSize(depth) }
    @inline(__always) var pixelBytes: Int { elemSize * Int(cn) }
    @inline(__always) func row(_ y: Int) -> UnsafeMutableRawPointer { data! + y * step }
    var isValid: Bool {
        data != nil && rows >= 0 && cols >= 0 && cn >= 1 && depth >= 0 && depth <= 6 && step >= cols * Int(cn) * coreElemSize(depth)
    }
}

@inline(__always) func coreElemSize(_ d: Int32) -> Int {
    switch d {
    case 0, 1: return 1
    case 2, 3: return 2
    case 4, 5: return 4
    default: return 8
    }
}

/// Pointer to a CoreMat or nil when the caller passed NULL.
public typealias MatP = UnsafeRawPointer
/// Reads a CoreMat from the caller's ctypes.Structure (40 bytes: data, rows, cols, step, cn, depth).
@inline(__always) func mat(_ p: UnsafeRawPointer?) -> CoreMat? { p?.load(as: CoreMat.self) }

// MARK: - element protocol

protocol CoreNum {
    static var depthCode: Int32 { get }
    static var isFloat: Bool { get }
    static var minD: Double { get }
    static var maxD: Double { get }
    static func satD(_ v: Double) -> Self       // cvRound + saturate (floats: plain conversion)
    static func satF(_ v: Float) -> Self
    static func satI(_ v: Int64) -> Self
    func toD() -> Double
    func toF() -> Float
    func toI() -> Int64
}

@inline(__always) func clampD(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    let r = v.rounded(.toNearestOrEven)
    let c = r.isNaN ? 0 : r
    return c < lo ? lo : (c > hi ? hi : c)
}
@inline(__always) func clampF(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
    let r = v.rounded(.toNearestOrEven)
    let c = r.isNaN ? 0 : r
    return c < lo ? lo : (c > hi ? hi : c)
}

extension UInt8: CoreNum {
    static var depthCode: Int32 { 0 }; static var isFloat: Bool { false }
    static var minD: Double { 0 }; static var maxD: Double { 255 }
    @inline(__always) static func satD(_ v: Double) -> UInt8 { UInt8(clampD(v, 0, 255)) }
    @inline(__always) static func satF(_ v: Float) -> UInt8 { UInt8(clampF(v, 0, 255)) }
    @inline(__always) static func satI(_ v: Int64) -> UInt8 { UInt8(truncatingIfNeeded: v < 0 ? 0 : (v > 255 ? 255 : v)) }
    @inline(__always) func toD() -> Double { Double(self) }
    @inline(__always) func toF() -> Float { Float(self) }
    @inline(__always) func toI() -> Int64 { Int64(self) }
}
extension Int8: CoreNum {
    static var depthCode: Int32 { 1 }; static var isFloat: Bool { false }
    static var minD: Double { -128 }; static var maxD: Double { 127 }
    @inline(__always) static func satD(_ v: Double) -> Int8 { Int8(clampD(v, -128, 127)) }
    @inline(__always) static func satF(_ v: Float) -> Int8 { Int8(clampF(v, -128, 127)) }
    @inline(__always) static func satI(_ v: Int64) -> Int8 { Int8(truncatingIfNeeded: v < -128 ? -128 : (v > 127 ? 127 : v)) }
    @inline(__always) func toD() -> Double { Double(self) }
    @inline(__always) func toF() -> Float { Float(self) }
    @inline(__always) func toI() -> Int64 { Int64(self) }
}
extension UInt16: CoreNum {
    static var depthCode: Int32 { 2 }; static var isFloat: Bool { false }
    static var minD: Double { 0 }; static var maxD: Double { 65535 }
    @inline(__always) static func satD(_ v: Double) -> UInt16 { UInt16(clampD(v, 0, 65535)) }
    @inline(__always) static func satF(_ v: Float) -> UInt16 { UInt16(clampF(v, 0, 65535)) }
    @inline(__always) static func satI(_ v: Int64) -> UInt16 { UInt16(truncatingIfNeeded: v < 0 ? 0 : (v > 65535 ? 65535 : v)) }
    @inline(__always) func toD() -> Double { Double(self) }
    @inline(__always) func toF() -> Float { Float(self) }
    @inline(__always) func toI() -> Int64 { Int64(self) }
}
extension Int16: CoreNum {
    static var depthCode: Int32 { 3 }; static var isFloat: Bool { false }
    static var minD: Double { -32768 }; static var maxD: Double { 32767 }
    @inline(__always) static func satD(_ v: Double) -> Int16 { Int16(clampD(v, -32768, 32767)) }
    @inline(__always) static func satF(_ v: Float) -> Int16 { Int16(clampF(v, -32768, 32767)) }
    @inline(__always) static func satI(_ v: Int64) -> Int16 { Int16(truncatingIfNeeded: v < -32768 ? -32768 : (v > 32767 ? 32767 : v)) }
    @inline(__always) func toD() -> Double { Double(self) }
    @inline(__always) func toF() -> Float { Float(self) }
    @inline(__always) func toI() -> Int64 { Int64(self) }
}
extension Int32: CoreNum {
    static var depthCode: Int32 { 4 }; static var isFloat: Bool { false }
    static var minD: Double { -2147483648 }; static var maxD: Double { 2147483647 }
    @inline(__always) static func satD(_ v: Double) -> Int32 { Int32(clampD(v, -2147483648, 2147483647)) }
    @inline(__always) static func satF(_ v: Float) -> Int32 {
        // Float cannot represent 2^31-1: clamp in Double so +big maps to INT_MAX like cvRound on arm64.
        Int32(clampD(Double(v), -2147483648, 2147483647))
    }
    @inline(__always) static func satI(_ v: Int64) -> Int32 { Int32(truncatingIfNeeded: v < -2147483648 ? -2147483648 : (v > 2147483647 ? 2147483647 : v)) }
    @inline(__always) func toD() -> Double { Double(self) }
    @inline(__always) func toF() -> Float { Float(self) }
    @inline(__always) func toI() -> Int64 { Int64(self) }
}
extension Float: CoreNum {
    static var depthCode: Int32 { 5 }; static var isFloat: Bool { true }
    static var minD: Double { -Double(Float.greatestFiniteMagnitude) }; static var maxD: Double { Double(Float.greatestFiniteMagnitude) }
    @inline(__always) static func satD(_ v: Double) -> Float { Float(v) }
    @inline(__always) static func satF(_ v: Float) -> Float { v }
    @inline(__always) static func satI(_ v: Int64) -> Float { Float(v) }
    @inline(__always) func toD() -> Double { Double(self) }
    @inline(__always) func toF() -> Float { self }
    @inline(__always) func toI() -> Int64 { clampI64(Double(self)) }
}
extension Double: CoreNum {
    static var depthCode: Int32 { 6 }; static var isFloat: Bool { true }
    static var minD: Double { -Double.greatestFiniteMagnitude }; static var maxD: Double { Double.greatestFiniteMagnitude }
    @inline(__always) static func satD(_ v: Double) -> Double { v }
    @inline(__always) static func satF(_ v: Float) -> Double { Double(v) }
    @inline(__always) static func satI(_ v: Int64) -> Double { Double(v) }
    @inline(__always) func toD() -> Double { self }
    @inline(__always) func toF() -> Float { Float(self) }
    @inline(__always) func toI() -> Int64 { clampI64(self) }
}

@inline(__always) func clampI64(_ v: Double) -> Int64 {
    let r = v.rounded(.toNearestOrEven)
    if r.isNaN { return 0 }
    if r >= 9.2e18 { return Int64.max }
    if r <= -9.2e18 { return Int64.min }
    return Int64(r)
}

// MARK: - validation / dispatch helpers

func coreCheck(_ ms: [CoreMat?], name: String) -> Int32? {
    for m in ms {
        if let m = m, !m.isValid {
            return srFail(SRStatus.badArgument, "\(name): invalid matrix descriptor")
        }
    }
    return nil
}

/// Run `body(y, rowPtr)` for every row of `m` (contiguous rows are not merged: callers handle row-wise loops).
@inline(__always) func forRows(_ rows: Int, _ body: (Int) -> Void) {
    var y = 0
    while y < rows { body(y); y += 1 }
}

/// True when rows of all given mats are packed (step == row bytes) so the whole image can be one flat span.
@inline(__always) func packed(_ m: CoreMat) -> Bool { m.step == m.cols * m.pixelBytes }

/// OpenCV scalar -> per-element array for `cn` channels (`vals` has 4 doubles; channels > 4 are 0 like cv::Scalar).
@inline(__always) func scalarChannel(_ vals: UnsafePointer<Double>, _ c: Int) -> Double { c < 4 ? vals[c] : 0 }
