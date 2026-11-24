// SafariumRaster — Phase 1: row load/store between any depth and a work type (Int64 / Float / Double),
// integer kernels with widening, and the masked-row driver shared by the arithmetic families.

import Foundation

// MARK: - integer protocol (widening arithmetic that vectorises)

protocol CoreInt: CoreNum, FixedWidthInteger {
    associatedtype IW: FixedWidthInteger & SignedInteger
    static func widen(_ v: Self) -> IW
    static func narrow(_ w: IW) -> Self      // saturating
}

extension UInt8: CoreInt {
    @inline(__always) static func widen(_ v: UInt8) -> Int32 { Int32(v) }
    @inline(__always) static func narrow(_ w: Int32) -> UInt8 { UInt8(truncatingIfNeeded: w < 0 ? 0 : (w > 255 ? 255 : w)) }
}
extension Int8: CoreInt {
    @inline(__always) static func widen(_ v: Int8) -> Int32 { Int32(v) }
    @inline(__always) static func narrow(_ w: Int32) -> Int8 { Int8(truncatingIfNeeded: w < -128 ? -128 : (w > 127 ? 127 : w)) }
}
extension UInt16: CoreInt {
    @inline(__always) static func widen(_ v: UInt16) -> Int32 { Int32(v) }
    @inline(__always) static func narrow(_ w: Int32) -> UInt16 { UInt16(truncatingIfNeeded: w < 0 ? 0 : (w > 65535 ? 65535 : w)) }
}
extension Int16: CoreInt {
    @inline(__always) static func widen(_ v: Int16) -> Int32 { Int32(v) }
    @inline(__always) static func narrow(_ w: Int32) -> Int16 { Int16(truncatingIfNeeded: w < -32768 ? -32768 : (w > 32767 ? 32767 : w)) }
}
extension Int32: CoreInt {
    @inline(__always) static func widen(_ v: Int32) -> Int64 { Int64(v) }
    @inline(__always) static func narrow(_ w: Int64) -> Int32 { Int32(truncatingIfNeeded: w < -2147483648 ? -2147483648 : (w > 2147483647 ? 2147483647 : w)) }
}

// MARK: - load / store rows through a work type

@inline(__always) private func loadG<T: CoreNum, W>(_ p: UnsafeRawPointer, _ n: Int, _ out: UnsafeMutablePointer<W>,
                                                    _ conv: (T) -> W) {
    let s = p.assumingMemoryBound(to: T.self)
    for i in 0..<n { out[i] = conv(s[i]) }
}

func loadRowD(_ depth: Int32, _ p: UnsafeRawPointer, _ n: Int, _ out: UnsafeMutablePointer<Double>) {
    switch depth {
    case 0: loadG(p, n, out) { (v: UInt8) in Double(v) }
    case 1: loadG(p, n, out) { (v: Int8) in Double(v) }
    case 2: loadG(p, n, out) { (v: UInt16) in Double(v) }
    case 3: loadG(p, n, out) { (v: Int16) in Double(v) }
    case 4: loadG(p, n, out) { (v: Int32) in Double(v) }
    case 5: loadG(p, n, out) { (v: Float) in Double(v) }
    default: loadG(p, n, out) { (v: Double) in v }
    }
}
func loadRowF(_ depth: Int32, _ p: UnsafeRawPointer, _ n: Int, _ out: UnsafeMutablePointer<Float>) {
    switch depth {
    case 0: perfLoadU8F(p, n, out)
    case 1: perfLoadS8F(p, n, out)
    case 2: perfLoadU16F(p, n, out)
    case 3: perfLoadS16F(p, n, out)
    case 4: loadG(p, n, out) { (v: Int32) in Float(v) }
    case 5: loadG(p, n, out) { (v: Float) in v }
    default: loadG(p, n, out) { (v: Double) in Float(v) }
    }
}
func loadRowI(_ depth: Int32, _ p: UnsafeRawPointer, _ n: Int, _ out: UnsafeMutablePointer<Int64>) {
    switch depth {
    case 0: loadG(p, n, out) { (v: UInt8) in Int64(v) }
    case 1: loadG(p, n, out) { (v: Int8) in Int64(v) }
    case 2: loadG(p, n, out) { (v: UInt16) in Int64(v) }
    case 3: loadG(p, n, out) { (v: Int16) in Int64(v) }
    case 4: loadG(p, n, out) { (v: Int32) in Int64(v) }
    case 5: loadG(p, n, out) { (v: Float) in clampI64(Double(v)) }
    default: loadG(p, n, out) { (v: Double) in clampI64(v) }
    }
}

@inline(__always) private func storeG<T: CoreNum, W>(_ w: UnsafePointer<W>, _ n: Int, _ dst: UnsafeMutableRawPointer,
                                                     _ conv: (W) -> T) {
    let d = dst.assumingMemoryBound(to: T.self)
    for i in 0..<n { d[i] = conv(w[i]) }
}

func storeRowD(_ depth: Int32, _ w: UnsafePointer<Double>, _ n: Int, _ dst: UnsafeMutableRawPointer) {
    switch depth {
    case 0: storeG(w, n, dst) { UInt8.satD($0) }
    case 1: storeG(w, n, dst) { Int8.satD($0) }
    case 2: storeG(w, n, dst) { UInt16.satD($0) }
    case 3: storeG(w, n, dst) { Int16.satD($0) }
    case 4: storeG(w, n, dst) { Int32.satD($0) }
    case 5: storeG(w, n, dst) { Float($0) }
    default: storeG(w, n, dst) { $0 }
    }
}
func storeRowF(_ depth: Int32, _ w: UnsafePointer<Float>, _ n: Int, _ dst: UnsafeMutableRawPointer) {
    switch depth {
    case 0: perfStoreFU8(w, n, dst)
    case 1: perfStoreFS8(w, n, dst)
    case 2: perfStoreFU16(w, n, dst)
    case 3: perfStoreFS16(w, n, dst)
    case 4: storeG(w, n, dst) { Int32.satF($0) }
    case 5: storeG(w, n, dst) { $0 }
    default: storeG(w, n, dst) { Double($0) }
    }
}
func storeRowI(_ depth: Int32, _ w: UnsafePointer<Int64>, _ n: Int, _ dst: UnsafeMutableRawPointer) {
    switch depth {
    case 0: storeG(w, n, dst) { UInt8.satI($0) }
    case 1: storeG(w, n, dst) { Int8.satI($0) }
    case 2: storeG(w, n, dst) { UInt16.satI($0) }
    case 3: storeG(w, n, dst) { Int16.satI($0) }
    case 4: storeG(w, n, dst) { Int32.satI($0) }
    case 5: storeG(w, n, dst) { Float($0) }
    default: storeG(w, n, dst) { Double($0) }
    }
}

// MARK: - scratch rows

final class Scratch {
    let bytes: Int
    let p: UnsafeMutableRawPointer
    init(_ bytes: Int) {
        self.bytes = max(bytes, 16)
        p = UnsafeMutableRawPointer.allocate(byteCount: self.bytes, alignment: 64)
    }
    deinit { p.deallocate() }
    func ptr<T>(_ t: T.Type, offset: Int = 0) -> UnsafeMutablePointer<T> { (p + offset).assumingMemoryBound(to: T.self) }
}

/// Typed temporary buffer that is guaranteed to outlive `body`.
@inline(__always) func withTemp<T, R>(_ count: Int, _ t: T.Type, _ body: (UnsafeMutablePointer<T>) -> R) -> R {
    let p = UnsafeMutablePointer<T>.allocate(capacity: max(count, 1))
    defer { p.deallocate() }
    return body(p)
}

// MARK: - masked driver

/// Calls `compute(y, outRow)` for each row. Without a mask `outRow` is the dst row; with a mask the row is computed
/// into scratch and only pixels with mask != 0 are copied (dst keeps its previous content elsewhere).
func driveRows(_ dst: CoreMat, _ mask: CoreMat?, _ compute: (Int, UnsafeMutableRawPointer) -> Void) {
    guard let mask = mask else {
        for y in 0..<dst.rows { compute(y, dst.row(y)) }
        return
    }
    let pb = dst.pixelBytes
    let tmp = Scratch(dst.cols * pb)
    for y in 0..<dst.rows {
        compute(y, tmp.p)
        let m = mask.row(y).assumingMemoryBound(to: UInt8.self)
        let d = dst.row(y)
        for x in 0..<dst.cols where m[x] != 0 {
            memcpy(d + x * pb, tmp.p + x * pb, pb)
        }
    }
}

/// Per-element (n = cols*cn) pattern of a 4-double scalar: element i uses channel i % cn.
func scalarPatternD(_ sc: UnsafePointer<Double>, _ cn: Int, _ cols: Int, _ out: UnsafeMutablePointer<Double>) {
    var i = 0
    for _ in 0..<cols { for c in 0..<cn { out[i] = scalarChannel(sc, c); i += 1 } }
}
