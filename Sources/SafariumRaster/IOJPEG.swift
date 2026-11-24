// SafariumRaster — baseline JPEG encoder matching libjpeg's defaults (Area C).
//
// ImageIO's JPEG encoder has a different rate/quality curve from IJG libjpeg (at "quality 88" it writes ~60 % more bytes),
// so `imencode('.jpg', ..., [IMWRITE_JPEG_QUALITY, q])` would not be size/quality compatible with OpenCV. This encoder follows
// libjpeg-turbo's defaults that OpenCV uses: IJG quantisation tables scaled by quality (baseline-forced, 1...255), fixed-point
// JFIF RGB->YCbCr, 4:2:0 chroma subsampling with libjpeg's alternating rounding bias, edge replication, accurate DCT with
// round-to-nearest quantisation, the standard (Annex K) Huffman tables, a JFIF APP0 header. Tables and the algorithm are the
// public JPEG standard / IJG constants (ITU T.81 Annex K), rewritten here in Swift.

import Foundation
import Accelerate
import SafariumRasterC

let jpegBaseLuma: [Int] = [
    16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55,
    14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
    18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
]
let jpegBaseChroma: [Int] = [
    17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
]
let jpegZigzag: [Int] = [
    0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
]

let dcLumaBits: [UInt8] = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
let dcChromaBits: [UInt8] = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0]
let dcVals: [UInt8] = Array(0...11)
let acLumaBits: [UInt8] = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d]
let acLumaVals: [UInt8] = [
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
]
let acChromaBits: [UInt8] = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77]
let acChromaVals: [UInt8] = [
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
    0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
]

/// code/length per symbol (0...255), built per ITU T.81 Annex C.
/// Per-symbol code and length (ITU T.81 Annex C), flattened into plain buffers for the hot loop.
struct JPEGCodeTable {
    var code = [UInt32](repeating: 0, count: 256)
    var size = [UInt8](repeating: 0, count: 256)
    init(bits: [UInt8], vals: [UInt8]) {
        var c: UInt32 = 0
        var k = 0
        for len in 1...16 {
            for _ in 0..<Int(bits[len - 1]) {
                code[Int(vals[k])] = c
                size[Int(vals[k])] = UInt8(len)
                c += 1
                k += 1
            }
            c <<= 1
        }
    }
}

/// 64-bit bit accumulator writing straight into a growable raw buffer (0xFF byte stuffing on flush).
struct JPEGBits {
    var out: UnsafeMutablePointer<UInt8>
    var pos = 0
    var cap: Int
    var acc: UInt64 = 0
    var n = 0

    init(capacity: Int) {
        cap = max(capacity, 1024)
        out = UnsafeMutablePointer<UInt8>.allocate(capacity: cap + 64)
    }

    /// Make room for `extra` more output bytes (worst case, including stuffing).
    @inline(__always) mutating func reserve(_ extra: Int) {
        if pos + extra > cap { grow(pos + extra) }
    }

    mutating func grow(_ need: Int) {
        let ncap = max(cap * 2, need)
        let nb = UnsafeMutablePointer<UInt8>.allocate(capacity: ncap + 64)
        memcpy(nb, out, pos)
        out.deallocate()
        out = nb
        cap = ncap
    }

    @inline(__always) mutating func put(_ value: UInt32, _ len: Int) {
        acc = (acc << UInt64(len)) | UInt64(value)
        n &+= len
        if n >= 32 {
            let word = UInt32(truncatingIfNeeded: acc >> UInt64(n &- 32))
            n &-= 32
            flush32(word)
        }
    }

    @inline(__always) mutating func flush32(_ word: UInt32) {
        // ((~w - 0x01010101) & w & 0x80808080) != 0  <=>  the word contains a 0xFF byte (needs stuffing)
        if ((~word &- 0x0101_0101) & word & 0x8080_8080) == 0 {
            UnsafeMutableRawPointer(out + pos).storeBytes(of: word.bigEndian, as: UInt32.self)
            pos &+= 4
        } else {
            var shift: UInt32 = 24
            while true {
                let b = UInt8(truncatingIfNeeded: word >> shift)
                out[pos] = b; pos &+= 1
                if b == 0xFF { out[pos] = 0; pos &+= 1 }
                if shift == 0 { break }
                shift &-= 8
            }
        }
    }

    /// Pad the last partial byte with 1-bits and write every whole byte (end of scan / before a restart marker).
    mutating func finish() {
        if n % 8 != 0 {
            let pad = 8 - n % 8
            acc = (acc << UInt64(pad)) | ((1 << UInt64(pad)) - 1)
            n += pad
        }
        while n >= 8 {
            let b = UInt8(truncatingIfNeeded: acc >> UInt64(n - 8))
            n -= 8
            out[pos] = b; pos += 1
            if b == 0xFF { out[pos] = 0; pos += 1 }
        }
        acc = 0
        n = 0
    }

    mutating func marker(_ m: UInt8) {
        out[pos] = 0xFF; out[pos + 1] = m
        pos += 2
    }

    func free() { out.deallocate() }
}

// MARK: - Options

/// IMWRITE_JPEG_* parameters (OpenCV 5.1 names / semantics).
struct JPEGOptions {
    var quality = 95
    var lumaQuality = -1
    var chromaQuality = -1
    var optimize = false
    var progressive = false
    var rstInterval = 0
    var hSamp = 2   // luma sampling factors; chroma is always 1x1 (4:2:0 = 2x2, 4:2:2 = 2x1, 4:4:0 = 1x2, 4:1:1 = 4x1, 4:4:4 = 1x1)
    var vSamp = 2

    /// OpenCV encodes the factor as 0xYYYYYY: nibbles = Y h, Y v, Cb h, Cb v, Cr h, Cr v. Returns false for an unsupported value.
    mutating func setSampling(_ v: Int) -> Bool {
        guard (v & 0xFFFF) == 0x1111 else { return false }
        let h = (v >> 20) & 0xF, vv = (v >> 16) & 0xF
        guard [1, 2, 4].contains(h), [1, 2].contains(vv) else { return false }
        hSamp = h
        vSamp = vv
        return true
    }
}

/// Quantisation tables in natural (row-major) order.
func jpegQuantTable(_ base: [Int], quality: Int) -> [Int] {
    let q = max(1, min(100, quality))
    let scale = q < 50 ? 5000 / q : 200 - q * 2
    return base.map { max(1, min(255, ($0 * scale + 50) / 100)) }
}

func jpegQuantTables(_ o: JPEGOptions) -> (luma: [Int], chroma: [Int]) {
    if o.lumaQuality >= 0 && o.chromaQuality >= 0 {
        return (jpegQuantTable(jpegBaseLuma, quality: o.lumaQuality), jpegQuantTable(jpegBaseChroma, quality: o.chromaQuality))
    }
    return (jpegQuantTable(jpegBaseLuma, quality: o.quality), jpegQuantTable(jpegBaseChroma, quality: o.quality))
}

// MARK: - Forward DCT + quantisation

let aanScale: [Float] = [1.0, 1.387039845, 1.306562965, 1.175875602, 1.0, 0.785694958, 0.541196100, 0.275899379]

/// Reciprocal quantiser per natural coefficient index k*8+u (k vertical, u horizontal): 1 / (q * aan_k * aan_u * 8),
/// matching the float AAN butterflies of the C kernel (libjpeg jfdctflt scaling).
func jpegRecipTable(_ q: [Int]) -> [Float] {
    var r = [Float](repeating: 0, count: 64)
    for k in 0..<8 { for u in 0..<8 { r[k * 8 + u] = 1.0 / (Float(q[k * 8 + u]) * aanScale[k] * aanScale[u] * 8.0) } }
    return r
}

/// cos((2c+1) u pi / 16), row c, as two SIMD4 (u 0-3, u 4-7).
let jpegCosMatrix: UnsafeMutablePointer<SIMD4<Float>> = {
    let p = UnsafeMutablePointer<SIMD4<Float>>.allocate(capacity: 16)
    let v: [SIMD4<Float>] = [
        SIMD4<Float>(1.000000000, 0.980785280, 0.923879533, 0.831469612), SIMD4<Float>(0.707106781, 0.555570233, 0.382683432, 0.195090322),
        SIMD4<Float>(1.000000000, 0.831469612, 0.382683432, -0.195090322), SIMD4<Float>(-0.707106781, -0.980785280, -0.923879533, -0.555570233),
        SIMD4<Float>(1.000000000, 0.555570233, -0.382683432, -0.980785280), SIMD4<Float>(-0.707106781, 0.195090322, 0.923879533, 0.831469612),
        SIMD4<Float>(1.000000000, 0.195090322, -0.923879533, -0.555570233), SIMD4<Float>(0.707106781, 0.831469612, -0.382683432, -0.980785280),
        SIMD4<Float>(1.000000000, -0.195090322, -0.923879533, 0.555570233), SIMD4<Float>(0.707106781, -0.831469612, -0.382683432, 0.980785280),
        SIMD4<Float>(1.000000000, -0.555570233, -0.382683432, 0.980785280), SIMD4<Float>(-0.707106781, -0.195090322, 0.923879533, -0.831469612),
        SIMD4<Float>(1.000000000, -0.831469612, 0.382683432, 0.195090322), SIMD4<Float>(-0.707106781, 0.980785280, -0.923879533, 0.555570233),
        SIMD4<Float>(1.000000000, -0.980785280, 0.923879533, -0.831469612), SIMD4<Float>(0.707106781, -0.555570233, 0.382683432, -0.195090322),
    ]
    for i in 0..<16 { p[i] = v[i] }
    return p
}()

/// Float AAN 1-D DCT (libjpeg jfdctflt.c) on 8 vectors at once; lane k of each vector is an independent transform.
@inline(__always)
private func aan4(_ d0: SIMD4<Float>, _ d1: SIMD4<Float>, _ d2: SIMD4<Float>, _ d3: SIMD4<Float>,
                  _ d4: SIMD4<Float>, _ d5: SIMD4<Float>, _ d6: SIMD4<Float>, _ d7: SIMD4<Float>)
    -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) {
    let t0 = d0 + d7, t7 = d0 - d7, t1 = d1 + d6, t6 = d1 - d6
    let t2 = d2 + d5, t5 = d2 - d5, t3 = d3 + d4, t4 = d3 - d4
    let t10 = t0 + t3, t13 = t0 - t3, t11 = t1 + t2, t12 = t1 - t2
    let o0 = t10 + t11, o4 = t10 - t11
    let z1 = (t12 + t13) * 0.707106781
    let o2 = t13 + z1, o6 = t13 - z1
    let u10 = t4 + t5, u11 = t5 + t6, u12 = t6 + t7
    let z5 = (u10 - u12) * 0.382683433
    let z2 = u10 * 0.541196100 + z5, z4 = u12 * 1.306562965 + z5
    let z3 = u11 * 0.707106781
    let z11 = t7 + z3, z13 = t7 - z3
    return (o0, z11 + z4, o2, z13 - z2, o4, z13 + z2, o6, z11 - z4)
}

/// zzSrc[i] = natural index (row*8 + col) of zigzag position i; zzMask[k*256+b] = zigzag-order bits for byte value b at natural byte k.
let jpegZZTables: (mask: UnsafeMutablePointer<UInt64>, src: UnsafeMutablePointer<Int>) = {
    let src = UnsafeMutablePointer<Int>.allocate(capacity: 64)
    var posOfNat = [Int](repeating: 0, count: 64)
    for i in 0..<64 {
        src[i] = jpegZigzag[i]
        posOfNat[jpegZigzag[i]] = i
    }
    let mask = UnsafeMutablePointer<UInt64>.allocate(capacity: 8 * 256)
    for k in 0..<8 {
        for b in 0..<256 {
            var m: UInt64 = 0
            for bit in 0..<8 where (b >> bit) & 1 == 1 { m |= 1 << UInt64(posOfNat[k * 8 + bit]) }
            mask[k * 256 + b] = m
        }
    }
    return (mask, src)
}()

@inline(__always)
private func jpegLoad16(_ p: UnsafePointer<UInt8>, _ stride: Int, _ k: Int) -> SIMD4<UInt32> {
    UnsafeRawPointer(p + k &* stride).loadUnaligned(as: SIMD4<UInt32>.self)
}

/// True when the 8x8 luma block at `p` has 64 equal samples.
@inline(__always)
private func jpegLumaFlat(_ p: UnsafePointer<UInt8>, _ stride: Int) -> Bool {
    let first = UInt64(p[0]) &* 0x0101_0101_0101_0101
    for k in 0..<8 where UnsafeRawPointer(p + k &* stride).loadUnaligned(as: UInt64.self) != first { return false }
    return true
}

/// True when the 8 interleaved samples of one chroma plane (byte offset `parity` of each pair) are equal in all 8 rows.
@inline(__always)
private func jpegChromaFlat(_ p: UnsafePointer<UInt8>, _ stride: Int, _ parity: Int) -> Bool {
    let first = UInt64(p[parity]) &* 0x0001_0001_0001_0001
    let sh = UInt64(parity * 8)
    for k in 0..<8 {
        let r = UnsafeRawPointer(p + k &* stride)
        if (r.loadUnaligned(as: UInt64.self) >> sh) & 0x00FF_00FF_00FF_00FF != first { return false }
        if (r.loadUnaligned(fromByteOffset: 8, as: UInt64.self) >> sh) & 0x00FF_00FF_00FF_00FF != first { return false }
    }
    return true
}

/// Quantise 64 float coefficients (natural order) to Int32 and build the non-zero bitmap (bit i = natural index i).
/// Kept as its own function with every row unrolled on literal indices: fused into the DCT, or with run-time shift
/// amounts, LLVM scalarises these vector chains.
@inline(never)
private func jpegQuantMask(_ f: UnsafePointer<Float>, _ recip: UnsafePointer<Float>, _ out: UnsafeMutablePointer<Int32>) -> UInt64 {
    let fm = SIMD4<Float>(repeating: 12582912.0)
    @inline(__always) func row(_ k: Int, _ w0: SIMD4<UInt32>, _ w1: SIMD4<UInt32>) -> SIMD4<UInt32> {
        let l = UnsafeRawPointer(f + k &* 8).loadUnaligned(as: SIMD4<Float>.self)
        let h = UnsafeRawPointer(f + (k &* 8 &+ 4)).loadUnaligned(as: SIMD4<Float>.self)
        let rl = UnsafeRawPointer(recip + k &* 8).loadUnaligned(as: SIMD4<Float>.self)
        let rh = UnsafeRawPointer(recip + (k &* 8 &+ 4)).loadUnaligned(as: SIMD4<Float>.self)
        // round to nearest via the 1.5 * 2^23 trick (the integer lands in the low mantissa bits); ties go to even,
        // which cannot matter for float DCT output
        let ql = unsafeBitCast(l * rl + fm, to: SIMD4<Int32>.self) &- 0x4B40_0000
        let qh = unsafeBitCast(h * rh + fm, to: SIMD4<Int32>.self) &- 0x4B40_0000
        UnsafeMutableRawPointer(out + k &* 8).storeBytes(of: ql, as: SIMD4<Int32>.self)
        UnsafeMutableRawPointer(out + (k &* 8 &+ 4)).storeBytes(of: qh, as: SIMD4<Int32>.self)
        let nl = unsafeBitCast(ql | (0 &- ql), to: SIMD4<UInt32>.self) &>> 31
        let nh = unsafeBitCast(qh | (0 &- qh), to: SIMD4<UInt32>.self) &>> 31
        return (nl &<< w0) | (nh &<< w1)
    }
    // natural index 8k + 4h + lane -> bit (index mod 32) of the low (k < 4) or high (k >= 4) 32-bit word
    let a0 = row(0, SIMD4<UInt32>(0, 1, 2, 3), SIMD4<UInt32>(4, 5, 6, 7))
    let a1 = row(1, SIMD4<UInt32>(8, 9, 10, 11), SIMD4<UInt32>(12, 13, 14, 15))
    let a2 = row(2, SIMD4<UInt32>(16, 17, 18, 19), SIMD4<UInt32>(20, 21, 22, 23))
    let a3 = row(3, SIMD4<UInt32>(24, 25, 26, 27), SIMD4<UInt32>(28, 29, 30, 31))
    let b0 = row(4, SIMD4<UInt32>(0, 1, 2, 3), SIMD4<UInt32>(4, 5, 6, 7))
    let b1 = row(5, SIMD4<UInt32>(8, 9, 10, 11), SIMD4<UInt32>(12, 13, 14, 15))
    let b2 = row(6, SIMD4<UInt32>(16, 17, 18, 19), SIMD4<UInt32>(20, 21, 22, 23))
    let b3 = row(7, SIMD4<UInt32>(24, 25, 26, 27), SIMD4<UInt32>(28, 29, 30, 31))
    let accLo = (a0 | a1) | (a2 | a3), accHi = (b0 | b1) | (b2 | b3)
    let lo32 = accLo[0] | accLo[1] | accLo[2] | accLo[3], hi32 = accHi[0] | accHi[1] | accHi[2] | accHi[3]
    return UInt64(lo32) | (UInt64(hi32) << 32)
}

@_silgen_name("sr_jpeg_block")
private func sr_jpeg_block(_ src: UnsafePointer<UInt8>, _ stride: Int, _ par: Int32, _ recip: UnsafePointer<Float>,
                           _ out: UnsafeMutablePointer<Int32>, _ zz: UnsafePointer<UInt64>) -> UInt64

/// Forward DCT + quantisation of two 8x8 blocks through the NEON C kernel (SafariumRasterC).
///  * luma: two horizontally adjacent blocks of a u8 plane; chroma: the Cb and Cr block of the byte-interleaved strip.
/// Output natural order Int32 (block 0 then block 1); masks = zigzag bitmap of non-zero AC (0 for a flat block, DC only).
func jpegDCTPair(_ src: UnsafePointer<UInt8>, _ stride: Int, _ chroma: Bool, _ recip: UnsafePointer<Float>,
                 _ out: UnsafeMutablePointer<Int32>, _ masks: UnsafeMutablePointer<UInt64>,
                 _ zzMask: UnsafePointer<UInt64>, _ scratch: UnsafeMutablePointer<SIMD4<Float>>) {
    if chroma {
        masks[0] = sr_jpeg_block(src, stride, 0, recip, out, zzMask)
        masks[1] = sr_jpeg_block(src, stride, 1, recip, out + 64, zzMask)
    } else {
        masks[0] = sr_jpeg_block(src, stride, -1, recip, out, zzMask)
        masks[1] = sr_jpeg_block(src + 8, stride, -1, recip, out + 64, zzMask)
    }
}

/// Huffman-code one quantised block (baseline sequential, streaming). `coef` is natural-order Int32, `mask` the AC bitmap.
@inline(__always)
private func jpegHuffBlock(_ coef: UnsafePointer<Int32>, _ mask0: UInt64, _ pred: inout Int,
                           _ dcT: UnsafePointer<UInt32>, _ acT: UnsafePointer<UInt32>, _ bits: inout JPEGBits,
                           _ zzSrc: UnsafePointer<Int>) {
    let dc = Int(coef[0])
    let diff = dc &- pred
    pred = dc
    let mag = UInt32(truncatingIfNeeded: diff < 0 ? 0 &- diff : diff)
    let nb = 32 - mag.leadingZeroBitCount
    let extra = UInt32(truncatingIfNeeded: diff < 0 ? diff &- 1 : diff) & ((1 << UInt32(nb)) &- 1)
    let dce = dcT[nb]
    bits.put(((dce >> 8) << UInt32(nb)) | extra, Int(dce & 0xFF) &+ nb)
    var mask = mask0 & ~UInt64(1)
    var last = 0
    while mask != 0 {
        let i = mask.trailingZeroBitCount
        mask &= mask &- 1
        var run = i &- last &- 1
        while run > 15 { let z = acT[0xF0]; bits.put(z >> 8, Int(z & 0xFF)); run &-= 16 }
        let v = Int(coef[zzSrc[i]])  // zigzag position -> natural index
        let s = 32 - UInt32(truncatingIfNeeded: v < 0 ? 0 &- v : v).leadingZeroBitCount
        let sym = (run << 4) | s
        let ex = UInt32(truncatingIfNeeded: v < 0 ? v &- 1 : v) & ((1 << UInt32(s)) &- 1)
        let ae = acT[sym]
        bits.put(((ae >> 8) << UInt32(s)) | ex, Int(ae & 0xFF) &+ s)
        last = i
    }
    if last < 63 { let e = acT[0]; bits.put(e >> 8, Int(e & 0xFF)) }
}

// MARK: - Colour conversion + subsampling (one MCU row at a time)

/// 16 pixels of one plane as (even pixels, odd pixels), each widened to u16 without any conversion call.
@inline(__always)
private func jpegEO(_ p: UnsafePointer<UInt8>) -> (SIMD8<UInt16>, SIMD8<UInt16>) {
    let v = UnsafeRawPointer(p).loadUnaligned(as: SIMD8<UInt16>.self)
    return (v & 0x00FF, v &>> 8)
}

/// libjpeg jccolor.c fixed-point JFIF RGB -> YCbCr, evaluated exactly in 16-bit lanes (coefficients split into a high
/// byte and a low byte; verified bit-exact against the 32-bit formula for all 2^24 inputs).
@inline(__always)
private func jpegYCC(_ B: SIMD8<UInt16>, _ G: SIMD8<UInt16>, _ R: SIMD8<UInt16>) -> (SIMD8<UInt16>, SIMD8<UInt16>, SIMD8<UInt16>) {
    let y = (76 &* R &+ 150 &* G &+ 29 &* B &+ ((139 &* R &+ 70 &* G &+ 47 &* B) &>> 8) &+ 128) &>> 8
    let cb = (128 &* B &+ 32895 &- 43 &* R &- 84 &* G &- ((51 &* R &+ 205 &* G) &>> 8)) &>> 8
    let cr = (128 &* R &+ 32895 &- 107 &* G &- 20 &* B &- ((47 &* G &+ 209 &* B) &>> 8)) &>> 8
    return (y, cb, cr)
}

@inline(__always)
private func jpegPack(_ e: SIMD8<UInt16>, _ o: SIMD8<UInt16>) -> SIMD16<UInt8> {
    unsafeBitCast(e | (o &<< 8), to: SIMD16<UInt8>.self)
}

@_silgen_name("sr_jpeg_ycc420")
private func sr_jpeg_ycc420(_ src: UnsafePointer<UInt8>, _ stride: Int, _ ch: Int32, _ w: Int32, _ rows: Int32, _ pw: Int32,
                            _ y: UnsafeMutablePointer<UInt8>, _ cc: UnsafeMutablePointer<UInt8>)

/// Mirror of the C struct SRJState (jpeg_huff.c): bit accumulator + restart bookkeeping of the streaming Huffman coder.
struct SRJState {
    var out: UnsafeMutablePointer<UInt8>
    var pos: Int = 0
    var acc: UInt64 = 0
    var n: Int = 0
    var count: Int = 0
    var rstNum: Int = 0
    var pred0: Int = 0, pred1: Int = 0, pred2: Int = 0
}

@_silgen_name("sr_jpeg_finish")
private func sr_jpeg_finish(_ s: UnsafeMutablePointer<SRJState>)

@_silgen_name("sr_jpeg_huff_row_s16")
private func sr_jpeg_huff_row_s16(_ s: UnsafeMutablePointer<SRJState>, _ yCoef: UnsafePointer<Int16>, _ yMask: UnsafePointer<UInt64>,
                                  _ ccCoef: UnsafePointer<Int16>, _ ccMask: UnsafePointer<UInt64>, _ nbx: Int, _ mcuCols: Int,
                                  _ hs: Int32, _ vs: Int32, _ colour: Int32, _ rst: Int, _ dcL: UnsafePointer<UInt32>,
                                  _ acL: UnsafePointer<UInt32>, _ dcC: UnsafePointer<UInt32>, _ acC: UnsafePointer<UInt32>,
                                  _ zz: UnsafePointer<Int>)

/// Produces, for each MCU row, the Y / Cb+Cr sample strips and their quantised DCT blocks.
final class JPEGStripper {
    let img: SRImage
    let w: Int, h: Int, colour: Bool, hs: Int, vs: Int
    let pw: Int, cw: Int, stripRows: Int
    let mcuCols: Int
    let yBlocksPerRow: Int   // Y blocks per strip block-row (mcuCols * hs), padded to even for pair processing
    let ccBlocks: Int        // CbCr pairs per strip, padded to even
    let planeB: UnsafeMutablePointer<UInt8>, planeG: UnsafeMutablePointer<UInt8>
    let planeR: UnsafeMutablePointer<UInt8>, planeA: UnsafeMutablePointer<UInt8>
    let yStrip: UnsafeMutablePointer<UInt8>
    let cbFull: UnsafeMutablePointer<UInt8>, crFull: UnsafeMutablePointer<UInt8>
    let ccStrip: UnsafeMutablePointer<UInt8>          // byte-interleaved Cb,Cr: row r at r * 2 * cw
    let yCoef: UnsafeMutablePointer<Int16>, yMask: UnsafeMutablePointer<UInt64>       // [by * yBlocksPerRow + bx]
    let ccCoef: UnsafeMutablePointer<Int16>, ccMask: UnsafeMutablePointer<UInt64>     // [mx * 2 + (0 Cb | 1 Cr)]
    private var owned: [UnsafeMutablePointer<UInt8>] = []
    private var ownedOther: [UnsafeMutableRawPointer] = []

    init(_ img: SRImage, hs hs0: Int, vs vs0: Int) {
        self.img = img
        w = img.width; h = img.height
        let colourImg = img.channels >= 3
        colour = colourImg
        let hs = colourImg ? hs0 : 1, vs = colourImg ? vs0 : 1
        self.hs = hs; self.vs = vs
        // colour rows are processed 16 pixels at a time, so pad to a multiple of 16 as well as of the MCU width
        let unit = colourImg ? max(8 * hs, 16) : 8
        let pw = (img.width + unit - 1) / unit * unit
        self.pw = pw
        let cw = pw / hs
        self.cw = cw
        stripRows = 8 * vs
        let mcuCols = (img.width + 8 * hs - 1) / (8 * hs)
        self.mcuCols = mcuCols
        let yb = (mcuCols * hs + 1) & ~1
        yBlocksPerRow = yb
        let ccb = (mcuCols + 1) & ~1
        ccBlocks = ccb
        let n = pw * 8 * vs + 64
        var made: [UnsafeMutablePointer<UInt8>] = []
        func mk(_ n: Int) -> UnsafeMutablePointer<UInt8> {
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            made.append(p)
            return p
        }
        planeB = mk(colourImg ? n : 8); planeG = mk(colourImg ? n : 8); planeR = mk(colourImg ? n : 8)
        planeA = mk(img.channels == 4 ? n : 8)
        yStrip = mk(n)
        let full420 = hs == 2 && vs == 2
        cbFull = mk(colourImg && !full420 ? n : 8); crFull = mk(colourImg && !full420 ? n : 8)
        ccStrip = mk(colourImg ? cw * 16 + 64 : 8)
        owned = made
        var other: [UnsafeMutableRawPointer] = []
        func mkRaw<T>(_ type: T.Type, _ count: Int) -> UnsafeMutablePointer<T> {
            let p = UnsafeMutablePointer<T>.allocate(capacity: count)
            other.append(UnsafeMutableRawPointer(p))
            return p
        }
        yCoef = mkRaw(Int16.self, yb * vs * 64 + 128)
        yMask = mkRaw(UInt64.self, yb * vs + 2)
        ccCoef = mkRaw(Int16.self, ccb * 2 * 64 + 128)
        ccMask = mkRaw(UInt64.self, ccb * 2 + 2)
        ownedOther = other
    }

    deinit {
        for p in owned { p.deallocate() }
        for p in ownedOther { p.deallocate() }
    }

    /// Fill the sample strips for image rows y0 ..< y0 + stripRows (edge-replicated past the bottom/right edge).
    func fill(_ y0: Int) {
        let rows = min(stripRows, h - y0)
        let src0 = img.data.assumingMemoryBound(to: UInt8.self)
        if colour && hs == 2 && vs == 2 {
            sr_jpeg_ycc420(src0 + y0 * img.stride, img.stride, Int32(img.channels), Int32(w), Int32(rows), Int32(pw), yStrip, ccStrip)
            return
        }
        var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src0 + y0 * img.stride),
                                height: vImagePixelCount(rows), width: vImagePixelCount(w), rowBytes: img.stride)
        if !colour {
            var sY = vImage_Buffer(data: yStrip, height: vImagePixelCount(rows), width: vImagePixelCount(w), rowBytes: pw)
            vImageCopyBuffer(&src, &sY, 1, vImage_Flags(kvImageDoNotTile))
            for r in 0..<rows where pw > w { memset(yStrip + r * pw + w, Int32(yStrip[r * pw + w - 1]), pw - w) }
            for r in rows..<stripRows { memcpy(yStrip + r * pw, yStrip + (rows - 1) * pw, pw) }
            return
        }
        var sB = vImage_Buffer(data: planeB, height: vImagePixelCount(rows), width: vImagePixelCount(w), rowBytes: pw)
        var sG = vImage_Buffer(data: planeG, height: vImagePixelCount(rows), width: vImagePixelCount(w), rowBytes: pw)
        var sR = vImage_Buffer(data: planeR, height: vImagePixelCount(rows), width: vImagePixelCount(w), rowBytes: pw)
        if img.channels == 3 {
            vImageConvert_RGB888toPlanar8(&src, &sB, &sG, &sR, vImage_Flags(kvImageDoNotTile))
        } else {
            var sA = vImage_Buffer(data: planeA, height: vImagePixelCount(rows), width: vImagePixelCount(w), rowBytes: pw)
            vImageConvert_ARGB8888toPlanar8(&src, &sB, &sG, &sR, &sA, vImage_Flags(kvImageDoNotTile))  // destinations follow memory byte order: B, G, R, A
        }
        for p in [planeB, planeG, planeR] {
            for r in 0..<rows where pw > w { memset(p + r * pw + w, Int32(p[r * pw + w - 1]), pw - w) }
            for r in rows..<stripRows { memcpy(p + r * pw, p + (rows - 1) * pw, pw) }
        }
        if hs == 2 && vs == 2 { fill420() } else { fillGeneric() }
    }

    /// DCT + quantise every block of the strip last filled.
    func transform(_ recipL: UnsafePointer<Int32>, _ recipC: UnsafePointer<Int32>) {
        let zz = UnsafePointer(jpegZZTables.mask)
        for by in 0..<vs {
            for bx in 0..<yBlocksPerRow {
                let idx = by * yBlocksPerRow + bx
                yMask[idx] = sr_jpeg_block_s16(yStrip + by * 8 * pw + bx * 8, pw, -1, recipL, yCoef + idx * 64, zz)
            }
        }
        if colour {
            for mx in 0..<mcuCols {
                ccMask[mx * 2] = sr_jpeg_block_s16(ccStrip + mx * 16, 2 * cw, 0, recipC, ccCoef + mx * 128, zz)
                ccMask[mx * 2 + 1] = sr_jpeg_block_s16(ccStrip + mx * 16, 2 * cw, 1, recipC, ccCoef + mx * 128 + 64, zz)
            }
        }
    }

    /// Fused colour conversion + 2x2 chroma average (libjpeg jcsample.c h2v2: alternating 1,2 rounding bias).
    private func fill420() {
        let bias = SIMD8<UInt16>(1, 2, 1, 2, 1, 2, 1, 2)
        for k in 0..<8 {
            let r0 = 2 * k * pw, r1 = (2 * k + 1) * pw
            var i = 0
            while i < pw {
                let (b0e, b0o) = jpegEO(planeB + r0 + i), (g0e, g0o) = jpegEO(planeG + r0 + i), (r0e, r0o) = jpegEO(planeR + r0 + i)
                let (b1e, b1o) = jpegEO(planeB + r1 + i), (g1e, g1o) = jpegEO(planeG + r1 + i), (r1e, r1o) = jpegEO(planeR + r1 + i)
                let (ye0, cbe0, cre0) = jpegYCC(b0e, g0e, r0e), (yo0, cbo0, cro0) = jpegYCC(b0o, g0o, r0o)
                let (ye1, cbe1, cre1) = jpegYCC(b1e, g1e, r1e), (yo1, cbo1, cro1) = jpegYCC(b1o, g1o, r1o)
                UnsafeMutableRawPointer(yStrip + r0 + i).storeBytes(of: jpegPack(ye0, yo0), as: SIMD16<UInt8>.self)
                UnsafeMutableRawPointer(yStrip + r1 + i).storeBytes(of: jpegPack(ye1, yo1), as: SIMD16<UInt8>.self)
                let cb = (cbe0 &+ cbo0 &+ cbe1 &+ cbo1 &+ bias) &>> 2
                let cr = (cre0 &+ cro0 &+ cre1 &+ cro1 &+ bias) &>> 2
                // Cb,Cr byte-interleaved: the DCT stage reads both blocks of an MCU column from one 16-byte row
                UnsafeMutableRawPointer(ccStrip + k * 2 * cw + i).storeBytes(of: jpegPack(cb, cr), as: SIMD16<UInt8>.self)
                i += 16
            }
        }
    }

    /// Full-resolution YCbCr rows, then a generic box average for the other chroma layouts (scalar; not the default path).
    private func fillGeneric() {
        for r in 0..<stripRows {
            var i = 0
            while i < pw {
                let (be, bo) = jpegEO(planeB + r * pw + i), (ge, go) = jpegEO(planeG + r * pw + i), (re, ro) = jpegEO(planeR + r * pw + i)
                let (ye, cbe, cre) = jpegYCC(be, ge, re), (yo, cbo, cro) = jpegYCC(bo, go, ro)
                UnsafeMutableRawPointer(yStrip + r * pw + i).storeBytes(of: jpegPack(ye, yo), as: SIMD16<UInt8>.self)
                UnsafeMutableRawPointer(cbFull + r * pw + i).storeBytes(of: jpegPack(cbe, cbo), as: SIMD16<UInt8>.self)
                UnsafeMutableRawPointer(crFull + r * pw + i).storeBytes(of: jpegPack(cre, cro), as: SIMD16<UInt8>.self)
                i += 16
            }
        }
        // libjpeg bias patterns: h2v1 0,1 / h1v2 1,2 / h2v2 1,2 (alternating per output column); other factors round to nearest.
        let n = hs * vs
        for r in 0..<8 {
            for c in 0..<cw {
                var sb = 0, sr = 0
                for dy in 0..<vs {
                    for dx in 0..<hs {
                        sb += Int(cbFull[(r * vs + dy) * pw + c * hs + dx])
                        sr += Int(crFull[(r * vs + dy) * pw + c * hs + dx])
                    }
                }
                let bias: Int
                if n == 1 { bias = 0 } else if hs == 2 && vs == 1 { bias = c & 1 } else if n == 2 || n == 4 && hs == 2 { bias = 1 + (c & 1) } else { bias = n / 2 }
                ccStrip[(r * cw + c) * 2] = UInt8(truncatingIfNeeded: (sb + bias) / n)
                ccStrip[(r * cw + c) * 2 + 1] = UInt8(truncatingIfNeeded: (sr + bias) / n)
            }
        }
    }
}

// MARK: - Header

func jpegHeader(_ g: JPEGGeometry, _ qLuma: [Int], _ qChroma: [Int], progressive: Bool) -> [UInt8] {
    var header: [UInt8] = [0xFF, 0xD8]
    func marker(_ m: UInt8, _ payload: [UInt8]) {
        header += [0xFF, m, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 0xFF)] + payload
    }
    marker(0xE0, [0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0])
    marker(0xDB, [0] + jpegZigzag.map { UInt8(qLuma[$0]) })
    if g.colour { marker(0xDB, [1] + jpegZigzag.map { UInt8(qChroma[$0]) }) }
    let ysamp = UInt8(g.hs << 4 | g.vs)
    let sof: [UInt8] = [8, UInt8(g.h >> 8), UInt8(g.h & 0xFF), UInt8(g.w >> 8), UInt8(g.w & 0xFF)]
        + (g.colour ? [3, 1, ysamp, 0, 2, 0x11, 1, 3, 0x11, 1] : [1, 1, 0x11, 0])
    marker(progressive ? 0xC2 : 0xC0, sof)
    return header
}

struct JPEGGeometry {
    let w: Int, h: Int, colour: Bool, hs: Int, vs: Int
    let mcuCols: Int, mcuRows: Int
    init(_ img: SRImage, hs: Int, vs: Int) {
        w = img.width; h = img.height
        colour = img.channels >= 3
        self.hs = colour ? hs : 1
        self.vs = colour ? vs : 1
        mcuCols = (w + 8 * self.hs - 1) / (8 * self.hs)
        mcuRows = (h + 8 * self.vs - 1) / (8 * self.vs)
    }
    var ncomp: Int { colour ? 3 : 1 }
}

func jpegDHT(_ cls: Int, _ id: Int, bits: [UInt8], vals: [UInt8]) -> [UInt8] {
    let payload: [UInt8] = [UInt8(cls << 4 | id)] + bits + vals
    return [0xFF, 0xC4, UInt8((payload.count + 2) >> 8), UInt8((payload.count + 2) & 0xFF)] + payload
}

func jpegSOS(_ comps: [(id: Int, dcTable: Int, acTable: Int)], ss: Int, se: Int, ah: Int, al: Int) -> [UInt8] {
    var p: [UInt8] = [UInt8(comps.count)]
    for c in comps { p += [UInt8(c.id), UInt8(c.dcTable << 4 | c.acTable)] }
    p += [UInt8(ss), UInt8(se), UInt8(ah << 4 | al)]
    return [0xFF, 0xDA, UInt8((p.count + 2) >> 8), UInt8((p.count + 2) & 0xFF)] + p
}

func jpegDRI(_ interval: Int) -> [UInt8] { [0xFF, 0xDD, 0, 4, UInt8((interval >> 8) & 0xFF), UInt8(interval & 0xFF)] }

// MARK: - Entry

private let jpegPackedDCLuma: [UInt32] = {
    let t = JPEGCodeTable(bits: dcLumaBits, vals: dcVals)
    return (0..<256).map { (t.code[$0] << 8) | UInt32(t.size[$0]) }
}()
private let jpegPackedACLuma: [UInt32] = {
    let t = JPEGCodeTable(bits: acLumaBits, vals: acLumaVals)
    return (0..<256).map { (t.code[$0] << 8) | UInt32(t.size[$0]) }
}()
private let jpegPackedDCChroma: [UInt32] = {
    let t = JPEGCodeTable(bits: dcChromaBits, vals: dcVals)
    return (0..<256).map { (t.code[$0] << 8) | UInt32(t.size[$0]) }
}()
private let jpegPackedACChroma: [UInt32] = {
    let t = JPEGCodeTable(bits: acChromaBits, vals: acChromaVals)
    return (0..<256).map { (t.code[$0] << 8) | UInt32(t.size[$0]) }
}()
private let jpegDHTColorBytes: [UInt8] = jpegDHT(0, 0, bits: dcLumaBits, vals: dcVals)
    + jpegDHT(1, 0, bits: acLumaBits, vals: acLumaVals)
    + jpegDHT(0, 1, bits: dcChromaBits, vals: dcVals)
    + jpegDHT(1, 1, bits: acChromaBits, vals: acChromaVals)
private let jpegDHTGrayBytes: [UInt8] = jpegDHT(0, 0, bits: dcLumaBits, vals: dcVals)
    + jpegDHT(1, 0, bits: acLumaBits, vals: acLumaVals)
private let jpegSOSColorBytes: [UInt8] = jpegSOS([(1, 0, 0), (2, 1, 1), (3, 1, 1)], ss: 0, se: 63, ah: 0, al: 0)
private let jpegSOSGrayBytes: [UInt8] = jpegSOS([(1, 0, 0)], ss: 0, se: 63, ah: 0, al: 0)

/// Write baseline JPEG header into a caller buffer, returning byte count written (<= 700 bytes).
private func jpegWriteBaselineHeader(_ dst: UnsafeMutablePointer<UInt8>, _ g: JPEGGeometry,
                                     _ qLuma: UnsafePointer<Int>, _ qChroma: UnsafePointer<Int>,
                                     _ rstInterval: Int) -> Int {
    var pos = 0
    @inline(__always) func emit(_ b: UInt8) { dst[pos] = b; pos += 1 }
    @inline(__always) func emit(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { memcpy(dst + pos, $0.baseAddress!, $0.count); pos += $0.count }
    }
    // SOI + APP0 JFIF
    emit([0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0])
    // DQT luma
    emit([0xFF, 0xDB, 0, 67, 0])
    for i in 0..<64 { emit(UInt8(qLuma[jpegZigzag[i]])) }
    if g.colour {
        emit([0xFF, 0xDB, 0, 67, 1])
        for i in 0..<64 { emit(UInt8(qChroma[jpegZigzag[i]])) }
    }
    // SOF0
    let ysamp = UInt8(g.hs << 4 | g.vs)
    let sofLen: UInt8 = g.colour ? 17 : 11
    emit([0xFF, 0xC0, 0, sofLen, 8, UInt8(g.h >> 8), UInt8(g.h & 0xFF), UInt8(g.w >> 8), UInt8(g.w & 0xFF)])
    if g.colour {
        emit([3, 1, ysamp, 0, 2, 0x11, 1, 3, 0x11, 1])
    } else {
        emit([1, 1, 0x11, 0])
    }
    emit(g.colour ? jpegDHTColorBytes : jpegDHTGrayBytes)
    if rstInterval > 0 {
        emit([0xFF, 0xDD, 0, 4, UInt8((rstInterval >> 8) & 0xFF), UInt8(rstInterval & 0xFF)])
    }
    emit(g.colour ? jpegSOSColorBytes : jpegSOSGrayBytes)
    return pos
}

/// Fast fused C/NEON baseline JPEG path returning malloc-owned buffer (freed via sr_jpeg_free / free).
func ioEncodeJPEGRaw(_ img: SRImage, _ o: JPEGOptions) -> (ptr: UnsafeMutablePointer<UInt8>, count: Int)? {
    guard img.depth == .u8, img.width > 0, img.height > 0, img.width < 65500, img.height < 65500 else { return nil }
    guard !o.optimize && !o.progressive else { return nil }
    let g = JPEGGeometry(img, hs: o.hSamp, vs: o.vSamp)
    if !g.colour {
        guard g.hs == 1 && g.vs == 1 else { return nil }
    } else if !((g.hs == 2 && g.vs == 2) || (g.hs == 1 && g.vs == 1)) {
        return nil
    }
    let lumaQ = max(1, min(100, o.lumaQuality >= 0 && o.chromaQuality >= 0 ? o.lumaQuality : o.quality))
    let chromaQ = max(1, min(100, o.lumaQuality >= 0 && o.chromaQuality >= 0 ? o.chromaQuality : o.quality))
    let scaleL = lumaQ < 50 ? 5000 / lumaQ : 200 - lumaQ * 2
    let scaleC = chromaQ < 50 ? 5000 / chromaQ : 200 - chromaQ * 2

    return withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 720) { hdr in
        return withUnsafeTemporaryAllocation(of: Int.self, capacity: 128) { qBuf in
            return withUnsafeTemporaryAllocation(of: Int32.self, capacity: 128) { rBuf in
                let qL = qBuf.baseAddress!
                let qC = qL + 64
                let rL = rBuf.baseAddress!
                let rC = rL + 64
                for k in 0..<8 {
                    for u in 0..<8 {
                        let idx = k * 8 + u
                        let qlv = max(1, min(255, (jpegBaseLuma[idx] * scaleL + 50) / 100))
                        let qcv = max(1, min(255, (jpegBaseChroma[idx] * scaleC + 50) / 100))
                        qL[idx] = qlv
                        qC[idx] = qcv
                        let aan = Double(aanScale[k]) * Double(aanScale[u]) * 8.0
                        rL[idx] = Int32(((0.5 / (Double(qlv) * aan)) * 2147483648.0).rounded())
                        rC[idx] = Int32(((0.5 / (Double(qcv) * aan)) * 2147483648.0).rounded())
                    }
                }
                let hdrLen = jpegWriteBaselineHeader(hdr.baseAddress!, g, qL, qC, o.rstInterval)
                var outPtr: UnsafeMutablePointer<UInt8>? = nil
                let n: Int64 = jpegPackedDCLuma.withUnsafeBufferPointer { dcLT in
                    jpegPackedACLuma.withUnsafeBufferPointer { acLT in
                    jpegPackedDCChroma.withUnsafeBufferPointer { dcCT in
                    jpegPackedACChroma.withUnsafeBufferPointer { acCT in
                        sr_jpeg_encode_baseline(
                            hdr.baseAddress!, Int32(hdrLen),
                            img.data.assumingMemoryBound(to: UInt8.self), img.stride,
                            Int32(img.channels), Int32(img.width), Int32(img.height),
                            Int32(g.hs), Int32(g.vs), o.rstInterval,
                            rL, rC,
                            dcLT.baseAddress!, acLT.baseAddress!,
                            dcCT.baseAddress!, acCT.baseAddress!,
                            UnsafePointer(jpegZZTables.mask), UnsafePointer(jpegZZTables.src),
                            &outPtr)
                    }}}
                }
                guard n > 0, let outPtr else { return nil }
                return (outPtr, Int(n))
            }
        }
    }
}

func jpegRecipTableS32(_ q: [Int]) -> [Int32] {
    var r = [Int32](repeating: 0, count: 64)
    for k in 0..<8 {
        for u in 0..<8 {
            let aan = Double(aanScale[k]) * Double(aanScale[u]) * 8.0
            r[k * 8 + u] = Int32(((0.5 / (Double(q[k * 8 + u]) * aan)) * 2147483648.0).rounded())
        }
    }
    return r
}

/// Encode a u8 image (BGR/BGRA/gray, OpenCV order) as a JFIF JPEG.
func ioEncodeJPEG(_ img: SRImage, quality: Int) -> [UInt8]? {
    var o = JPEGOptions()
    o.quality = quality
    return ioEncodeJPEG(img, o)
}

func ioEncodeJPEG(_ img: SRImage, _ o: JPEGOptions) -> [UInt8]? {
    if let raw = ioEncodeJPEGRaw(img, o) {
        defer { sr_jpeg_free(raw.ptr) }
        return Array(UnsafeBufferPointer(start: raw.ptr, count: raw.count))
    }
    guard img.depth == .u8, img.width > 0, img.height > 0, img.width < 65500, img.height < 65500 else { return nil }
    let g = JPEGGeometry(img, hs: o.hSamp, vs: o.vSamp)
    let (qLuma, qChroma) = jpegQuantTables(o)
    let recipL = jpegRecipTableS32(qLuma), recipC = jpegRecipTableS32(qChroma)
    let strip = JPEGStripper(img, hs: o.hSamp, vs: o.vSamp)
    if o.optimize || o.progressive {
        return jpegEncodeBuffered(img, o, g, strip, qLuma, qChroma, recipL, recipC)
    }

    var header = jpegHeader(g, qLuma, qChroma, progressive: false)
    header += jpegDHT(0, 0, bits: dcLumaBits, vals: dcVals) + jpegDHT(1, 0, bits: acLumaBits, vals: acLumaVals)
    if g.colour { header += jpegDHT(0, 1, bits: dcChromaBits, vals: dcVals) + jpegDHT(1, 1, bits: acChromaBits, vals: acChromaVals) }
    if o.rstInterval > 0 { header += jpegDRI(o.rstInterval) }
    header += jpegSOS(g.colour ? [(1, 0, 0), (2, 1, 1), (3, 1, 1)] : [(1, 0, 0)], ss: 0, se: 63, ah: 0, al: 0)

    let hs = g.hs, vs = g.vs
    var cap = max(1 << 16, img.width * img.height / 2 + 4096)
    var st = SRJState(out: UnsafeMutablePointer<UInt8>.allocate(capacity: cap + 64))
    defer { st.out.deallocate() }
    let zzSrcT = UnsafePointer(jpegZZTables.src)
    let rst = o.rstInterval

    return recipL.withUnsafeBufferPointer { rL -> [UInt8]? in
        recipC.withUnsafeBufferPointer { rC -> [UInt8]? in
            jpegPackedDCLuma.withUnsafeBufferPointer { dcLT in jpegPackedACLuma.withUnsafeBufferPointer { acLT in
            jpegPackedDCChroma.withUnsafeBufferPointer { dcCT in jpegPackedACChroma.withUnsafeBufferPointer { acCT -> [UInt8]? in
                let nbx = strip.yBlocksPerRow
                for my in 0..<g.mcuRows {
                    strip.fill(my * strip.stripRows)
                    strip.transform(rL.baseAddress!, rC.baseAddress!)
                    if st.pos + g.mcuCols * 3000 + 64 > cap {
                        cap = max(cap * 2, st.pos + g.mcuCols * 3000 + 64)
                        let nb = UnsafeMutablePointer<UInt8>.allocate(capacity: cap + 64)
                        memcpy(nb, st.out, st.pos)
                        st.out.deallocate()
                        st.out = nb
                    }
                    sr_jpeg_huff_row_s16(&st, strip.yCoef, strip.yMask, strip.ccCoef, strip.ccMask, nbx, g.mcuCols, Int32(hs), Int32(vs),
                                         g.colour ? 1 : 0, rst, dcLT.baseAddress!, acLT.baseAddress!, dcCT.baseAddress!, acCT.baseAddress!, zzSrcT)
                }
                sr_jpeg_finish(&st)
                var out = [UInt8]()
                out.reserveCapacity(header.count + st.pos + 2)
                out += header
                out.append(contentsOf: UnsafeBufferPointer(start: st.out, count: st.pos))
                out += [0xFF, 0xD9]
                return out
            }}}}
        }
    }
}
