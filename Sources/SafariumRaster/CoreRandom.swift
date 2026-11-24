// SafariumRaster — Phase 1: cv::RNG-compatible random numbers (randu, randn, randShuffle, setRNGSeed).
// The generator is OpenCV's multiply-with-carry: state = lo32(state) * 4164903690 + hi32(state); next() = lo32(state).
// Uniform integers, uniform floats and the ziggurat normal sampler reproduce cv2's streams value for value
// (verified against reference cv2 in sdk/python/tests/test_parity_core.py). Algorithm shape from OpenCV's
// core/src/rand.cpp (Apache-2.0), rewritten in Swift; the ziggurat tables are rebuilt with Marsaglia & Tsang's
// construction instead of being copied.

import Foundation
import SafariumRasterC

// cv2's theRNG() is thread-local: each thread owns its own generator state (default 0xFFFFFFFF).
private let rngKey: pthread_key_t = {
    var k = pthread_key_t()
    pthread_key_create(&k) { $0.assumingMemoryBound(to: UInt64.self).deallocate() }
    return k
}()
private func rngSlot() -> UnsafeMutablePointer<UInt64> {
    if let p = pthread_getspecific(rngKey) { return p.assumingMemoryBound(to: UInt64.self) }
    let q = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    q.pointee = 0xFFFF_FFFF
    pthread_setspecific(rngKey, q)
    return q
}

@inline(__always) private func rngNext(_ s: inout UInt64) -> UInt32 {
    s = UInt64(UInt32(truncatingIfNeeded: s)) &* 4164903690 &+ (s >> 32)
    return UInt32(truncatingIfNeeded: s)
}

/// cv::setRNGSeed: state = seed, or 0xFFFFFFFF when the seed is 0.
@_cdecl("sr_core_set_rng_seed")
public func sr_core_set_rng_seed(_ seed: UInt64) -> Int32 {
    rngSlot().pointee = seed != 0 ? seed : 0xFFFF_FFFF
    return 0
}

@_cdecl("sr_core_get_rng_state")
public func sr_core_get_rng_state() -> UInt64 { rngSlot().pointee }

private let blockElems = 1024

// MARK: - uniform


/// lo / hi: cv::Scalar (4 doubles). Fills dst (any depth, 1-4 channels) with uniform values in [lo, hi).
@_cdecl("sr_core_randu")
public func sr_core_randu(_ dst: MatP?, _ lo: UnsafePointer<Double>?, _ hi: UnsafePointer<Double>?) -> Int32 {
    guard let d = mat(dst), let lo, let hi, d.cn <= 4 else { return srFail(SRStatus.badArgument, "randu: bad operands") }
    if let r = coreCheck([d], name: "randu") { return r }
    let cn = Int(d.cn)
    let total = d.rows * d.cols * cn
    var s = rngSlot().pointee
    let blk = ((blockElems + cn - 1) / cn) * cn   // OpenCV fills ceil(1024 / cn) whole pixels per block
    var done = 0
    // work in a contiguous block buffer, then scatter into (possibly strided) rows
    let tmpS = Scratch((blk + 8) * 8)
    defer { withExtendedLifetime(tmpS) {} }
    var rowPos = 0   // element position inside the current row
    var rowIdx = 0
    func put<T: CoreNum>(_ vals: UnsafePointer<T>, _ n: Int, _ t: T.Type) {
        var k = 0
        while k < n {
            let rowLen = d.cols * cn
            let take = min(n - k, rowLen - rowPos)
            let dp = d.row(rowIdx).assumingMemoryBound(to: T.self) + rowPos
            for i in 0..<take { dp[i] = vals[k + i] }
            k += take; rowPos += take
            if rowPos == rowLen { rowPos = 0; rowIdx += 1 }
        }
    }

    if d.depth <= 4 {
        // integer destination
        // cv2 works in C int: bounds are cvCeil/cvFloor (saturating, NaN -> 0) and idiff wraps like int32 arithmetic.
        func satI32(_ v: Double) -> Int32 { v.isNaN ? 0 : (v >= 2147483647.0 ? Int32.max : (v <= -2147483648.0 ? Int32.min : Int32(v))) }
        var ia = [Int32](repeating: 0, count: cn), idiff = [Int32](repeating: 0, count: cn)
        var fast = true
        for j in 0..<cn {
            let a = hi[j] < lo[j] ? hi[j] : lo[j], b = lo[j] < hi[j] ? hi[j] : lo[j]   // std::min / std::max semantics
            ia[j] = satI32(a.rounded(.up))
            idiff[j] = satI32(b.rounded(.down)) &- ia[j] &- 1
            let diff = b - a
            fast = fast && diff <= 4294967296.0 && (idiff[j] & (idiff[j] &+ 1)) == 0
        }
        let small = fast && idiff[cn - 1] <= 255   // cv2 tests only the last channel's range
        let mode: Int32 = small ? 2 : (fast ? 1 : 0)
        let direct = packed(d)
        let es = d.elemSize
        while done < total {
            let len = min(blk, total - done)
            let ch0 = done % cn
            if direct {
                src_randu_int(d.depth, d.data! + done * es, Int32(len), &s, ia, idiff, Int32(cn), Int32(ch0), mode)
            } else {
                src_randu_int(d.depth, tmpS.p, Int32(len), &s, ia, idiff, Int32(cn), Int32(ch0), mode)
                switch d.depth {
                case 0: put(UnsafePointer(tmpS.ptr(UInt8.self)), len, UInt8.self)
                case 1: put(UnsafePointer(tmpS.ptr(Int8.self)), len, Int8.self)
                case 2: put(UnsafePointer(tmpS.ptr(UInt16.self)), len, UInt16.self)
                case 3: put(UnsafePointer(tmpS.ptr(Int16.self)), len, Int16.self)
                default: put(UnsafePointer(tmpS.ptr(Int32.self)), len, Int32.self)
                }
            }
            done += len
        }
    } else if d.depth == 5 {
        var sc = [Float](repeating: 0, count: cn), mid = [Float](repeating: 0, count: cn)
        for j in 0..<cn {
            let a = lo[j], b = hi[j]   // float fills do not reorder the bounds (a > b mirrors the range)
            sc[j] = Float((b - a) * (1.0 / 4294967296.0)); mid[j] = Float((b + a) * 0.5)
        }
        while done < total {
            let len = min(blk, total - done)
            let ch0 = done % cn
            let b = tmpS.ptr(Float.self)
            for i in 0..<len {
                let c = (ch0 + i) % cn
                let t = rngNext(&s)
                b[i] = Float(Int32(bitPattern: t)) * sc[c] + mid[c]
            }
            put(UnsafePointer(b), len, Float.self)
            done += len
        }
    } else {
        var sc = [Double](repeating: 0, count: cn), mid = [Double](repeating: 0, count: cn)
        for j in 0..<cn {
            let a = lo[j], b = hi[j]
            sc[j] = (b - a) * (1.0 / 4294967296.0); mid[j] = (b + a) * 0.5
        }
        while done < total {
            let len = min(blk, total - done)
            let ch0 = done % cn
            let b = tmpS.ptr(Double.self)
            for i in 0..<len {
                let c = (ch0 + i) % cn
                _ = rngNext(&s)
                let v = Double(Int32(bitPattern: UInt32(truncatingIfNeeded: s))) + Double(s >> 32) / 4294967296.0
                b[i] = v * sc[c] + mid[c]
            }
            put(UnsafePointer(b), len, Double.self)
            done += len
        }
    }
    rngSlot().pointee = s
    return 0
}

// MARK: - normal (ziggurat)

private struct ZigTables {
    var k = [UInt32](repeating: 0, count: 128)
    var w = [Float](repeating: 0, count: 128)
    var f = [Float](repeating: 0, count: 128)
    init() {
        var dn = 3.442619855899, tn = dn
        let vn = 9.91256303526217e-3, m1 = 2147483648.0
        let q = vn / exp(-0.5 * dn * dn)
        var kn = [Double](repeating: 0, count: 128), wn = kn, fn = kn
        kn[0] = (dn / q) * m1; kn[1] = 0
        wn[0] = q / m1; wn[127] = dn / m1
        fn[0] = 1.0; fn[127] = exp(-0.5 * dn * dn)
        var i = 126
        while i >= 1 {
            dn = (-2.0 * log(vn / dn + exp(-0.5 * dn * dn))).squareRoot()
            kn[i + 1] = (dn / tn) * m1
            tn = dn
            fn[i] = exp(-0.5 * dn * dn)
            wn[i] = dn / m1
            i -= 1
        }
        for j in 0..<128 { k[j] = UInt32(kn[j]); w[j] = Float(wn[j]); f[j] = Float(fn[j]) }
    }
}
private let zig = ZigTables()

/// One N(0,1) sample, OpenCV flow: hz comes from the current state, the state advances after each sample.
@inline(__always) private func randn01(_ s: inout UInt64) -> Float {
    let rngFlt: Float = 2.3283064365386962890625e-10
    var x: Float
    while true {
        let hz = Int32(bitPattern: UInt32(truncatingIfNeeded: s))
        let iz = Int(hz & 127)
        x = Float(hz) * zig.w[iz]
        if UInt32(hz.magnitude) < zig.k[iz] { break }
        if iz == 0 {
            while true {
                var xx = Float(rngNext(&s)) * rngFlt
                var yy = Float(rngNext(&s)) * rngFlt
                xx = -Float(log(Double(xx) + 1.1754943508222875e-38)) * 0.2904764
                yy = -Float(log(Double(yy) + 1.1754943508222875e-38))
                if yy + yy >= xx * xx { x = xx; break }
            }
            x = hz > 0 ? 3.442620 + x : -3.442620 - x
            break
        }
        let u = Float(rngNext(&s)) * rngFlt
        if u * (zig.f[iz - 1] - zig.f[iz]) + zig.f[iz] < Float(exp(-0.5 * Double(x) * Double(x))) { break }
        _ = rngNext(&s)   // reject: draw a fresh hz (state advances, then it is read at the loop top)
    }
    _ = rngNext(&s)
    return x
}

/// dst = N(mean, stddev) per channel (cv::randn). Integer targets round and saturate.
@_cdecl("sr_core_randn")
public func sr_core_randn(_ dst: MatP?, _ mean: UnsafePointer<Double>?, _ stddev: UnsafePointer<Double>?) -> Int32 {
    guard let d = mat(dst), let mean, let stddev, d.cn <= 4 else { return srFail(SRStatus.badArgument, "randn: bad operands") }
    if let r = coreCheck([d], name: "randn") { return r }
    let cn = Int(d.cn)
    let total = d.rows * d.cols * cn
    var s = rngSlot().pointee
    let bufS = Scratch((blockElems + 8) * 4)
    let outS = Scratch((blockElems + 8) * 8)
    defer { withExtendedLifetime(bufS) {}; withExtendedLifetime(outS) {} }
    var done = 0, rowPos = 0, rowIdx = 0
    let rowLen = d.cols * cn
    let blk = ((blockElems + cn - 1) / cn) * cn
    if d.depth == 5 && packed(d) {
        // float32 destination: generate straight into the image block by block (L1-resident), then apply mean/stddev in place
        let mf = (0..<4).map { Float(mean[$0]) }, sf = (0..<4).map { Float(stddev[$0]) }
        let dp = d.data!.assumingMemoryBound(to: Float.self)
        mf.withUnsafeBufferPointer { mp in sf.withUnsafeBufferPointer { sp in
            while done < total {
                let len = min(blk, total - done)
                src_randn_f32(dp + done, Int32(len), &s)
                src_randn_affine_f32(dp + done, Int32(len), mp.baseAddress, sp.baseAddress, Int32(cn), Int32(done % cn))
                done += len
            }
        } }
        rngSlot().pointee = s
        return 0
    }
    while done < total {
        let len = min(blk, total - done)
        let ch0 = done % cn
        let buf = bufS.ptr(Float.self)
        src_randn_f32(buf, Int32(len), &s)
        let o = outS.ptr(Double.self)
        if d.depth == 5 {   // cv2: fused multiply-add in float32 with float32 parameters
            for i in 0..<len { let c = (ch0 + i) % cn; o[i] = Double(Float(mean[c]).addingProduct(buf[i], Float(stddev[c]))) }
        } else if d.depth == 6 {
            for i in 0..<len { let c = (ch0 + i) % cn; o[i] = mean[c].addingProduct(Double(buf[i]), stddev[c]) }
        } else {
            for i in 0..<len { let c = (ch0 + i) % cn; o[i] = Double(Float(mean[c]).addingProduct(buf[i], Float(stddev[c]))) }
        }
        var k = 0
        while k < len {
            let take = min(len - k, rowLen - rowPos)
            let rp = d.row(rowIdx) + rowPos * d.elemSize
            storeRowD(d.depth, o + k, take, rp)
            k += take; rowPos += take
            if rowPos == rowLen { rowPos = 0; rowIdx += 1 }
        }
        done += len
    }
    rngSlot().pointee = s
    return 0
}

// MARK: - shuffle

/// cv::randShuffle: for i in 0..<N: swap(arr[i], arr[next() % N]) over a contiguous array of N = rows * cols pixels
/// (iterFactor is accepted for API compatibility; cv2 5.1 ignores it).
@_cdecl("sr_core_randshuffle")
public func sr_core_randshuffle(_ dst: MatP?, _ iterFactor: Double) -> Int32 {
    guard let d = mat(dst), packed(d) else { return srFail(SRStatus.badArgument, "randShuffle: need a contiguous array") }
    if let r = coreCheck([d], name: "randShuffle") { return r }
    let sz = d.rows * d.cols
    if sz == 0 { return 0 }
    let pb = d.pixelBytes
    var s = rngSlot().pointee
    let base = d.data!
    let tmp = Scratch(pb)
    defer { withExtendedLifetime(tmp) {} }
    for i in 0..<sz {
        let j = Int(rngNext(&s)) % sz
        if j != i {
            memcpy(tmp.p, base + i * pb, pb)
            memcpy(base + i * pb, base + j * pb, pb)
            memcpy(base + j * pb, tmp.p, pb)
        }
    }
    rngSlot().pointee = s
    return 0
}
