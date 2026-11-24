// SafariumRaster — Area E: DSP kernels behind the `scipy.signal` / `scipy.ndimage` stand-ins.
//
// Numerics follow scipy's reference loops (direct form II transposed, same operation order per
// sample), so results agree with scipy to float64 rounding. State is explicit: every filter takes
// the initial state `zi` and writes the final state back, so block/streaming use keeps its state
// across blocks (SF-VIDEO-1). Nothing is down-converted: float64 in, float64 out.
//
// Speed: two lines (e.g. L/R) run in the two lanes of one SIMD2<Double>, and two biquad sections
// are cascaded per sample, so the serial recursion of each line hides the latency of the other.
// Everything is single-threaded (one worker, SF-VIDEO-1).

import Foundation

private typealias V2 = SIMD2<Double>

// MARK: - SOS cascade

/// Runs one or two biquad sections over a pair of lines in place. `zi` holds 2 doubles per section per line.
/// pa/pb: the two lines (pb may equal pa for a single line: lane 1 then duplicates lane 0 and is not stored).
private func sosPair(_ pa: UnsafeMutablePointer<Double>, _ pb: UnsafeMutablePointer<Double>, _ storeB: Bool,
                     _ n: Int, _ step: Int, _ sos: UnsafePointer<Double>, _ nsec: Int,
                     _ za: UnsafeMutablePointer<Double>, _ zb: UnsafeMutablePointer<Double>) {
    if nsec == 2 {
        let b00 = sos[0], b01 = sos[1], b02 = sos[2], a01 = sos[4], a02 = sos[5]
        let b10 = sos[6], b11 = sos[7], b12 = sos[8], a11 = sos[10], a12 = sos[11]
        var s0 = V2(za[0], zb[0]), s1 = V2(za[1], zb[1])
        var t0 = V2(za[2], zb[2]), t1 = V2(za[3], zb[3])
        var k = 0
        for _ in 0..<n {
            let x = V2(pa[k], pb[k])
            let y = V2(repeating: b00) * x + s0
            s0 = V2(repeating: b01) * x + s1 - V2(repeating: a01) * y
            s1 = V2(repeating: b02) * x - V2(repeating: a02) * y
            let w = V2(repeating: b10) * y + t0
            t0 = V2(repeating: b11) * y + t1 - V2(repeating: a11) * w
            t1 = V2(repeating: b12) * y - V2(repeating: a12) * w
            pa[k] = w[0]
            if storeB { pb[k] = w[1] }
            k &+= step
        }
        za[0] = s0[0]; za[1] = s1[0]; za[2] = t0[0]; za[3] = t1[0]
        if storeB { zb[0] = s0[1]; zb[1] = s1[1]; zb[2] = t0[1]; zb[3] = t1[1] }
    } else {
        let b0 = sos[0], b1 = sos[1], b2 = sos[2], a1 = sos[4], a2 = sos[5]
        var s0 = V2(za[0], zb[0]), s1 = V2(za[1], zb[1])
        var k = 0
        for _ in 0..<n {
            let x = V2(pa[k], pb[k])
            let y = V2(repeating: b0) * x + s0
            s0 = V2(repeating: b1) * x + s1 - V2(repeating: a1) * y
            s1 = V2(repeating: b2) * x - V2(repeating: a2) * y
            pa[k] = y[0]
            if storeB { pb[k] = y[1] }
            k &+= step
        }
        za[0] = s0[0]; za[1] = s1[0]
        if storeB { zb[0] = s0[1]; zb[1] = s1[1] }
    }
}

/// In-place SOS filter of `nlines` float64 lines of length `n` (line l starts at x + l*rowStride doubles).
/// reverse != 0 runs each line from its last sample to its first (the backward pass of filtfilt, no reversed copy).
/// sos: nsec rows of [b0 b1 b2 a0 a1 a2] (a0 must be 1). zi: nlines*nsec*2 doubles laid out
/// [line][section][2]; read as the initial state and overwritten with the final state (pass NULL for zero state, no output).
@_cdecl("sr_sci_sosfilt")
public func sr_sci_sosfilt(_ x: UnsafeMutablePointer<Double>?, _ nlines: Int64, _ n: Int64, _ rowStride: Int64,
                           _ sos: UnsafePointer<Double>?, _ nsec: Int32,
                           _ zi: UnsafeMutablePointer<Double>?, _ reverse: Int32) -> Int32 {
    guard let x, let sos, nlines >= 0, n >= 0, rowStride >= n, nsec >= 1 else {
        return srFail(SRStatus.badArgument, "sosfilt: bad arguments")
    }
    let ns = Int(nsec), nl = Int(nlines), len = Int(n), rs = Int(rowStride)
    let step = reverse != 0 ? -1 : 1
    let first = (reverse != 0 && len > 0) ? len - 1 : 0
    for s in 0..<ns where sos[s * 6 + 3] != 1.0 {
        return srFail(SRStatus.badArgument, "sosfilt: sos a0 must be 1")
    }
    let zper = ns * 2
    let scratch = UnsafeMutablePointer<Double>.allocate(capacity: 2 * zper)
    defer { scratch.deallocate() }
    var l = 0
    while l < nl {
        let two = (l + 1 < nl)
        let pa = x + l * rs + first
        let pb = two ? x + (l + 1) * rs + first : pa
        // states for these two lines (copied in/out so lane-duplication never aliases caller memory)
        for k in 0..<zper {
            scratch[k] = zi?[l * zper + k] ?? 0
            scratch[zper + k] = two ? (zi?[(l + 1) * zper + k] ?? 0) : scratch[k]
        }
        var s = 0
        while s < ns {
            let take = (ns - s >= 2) ? 2 : 1
            sosPair(pa, pb, two, len, step, sos + s * 6, take, scratch + s * 2, scratch + zper + s * 2)
            s += take
        }
        if let zi {
            for k in 0..<zper { zi[l * zper + k] = scratch[k] }
            if two { for k in 0..<zper { zi[(l + 1) * zper + k] = scratch[zper + k] } }
        }
        l += two ? 2 : 1
    }
    return SRStatus.ok
}

// MARK: - lfilter (direct form II transposed)

/// In-place IIR/FIR filter of `nlines` contiguous float64 lines. b, a already normalised by a[0] (a[0]==1), both of
/// length `order+1` (zero-padded). zi: nlines*order doubles [line][order] (initial state in, final state out) or NULL.
@_cdecl("sr_sci_lfilter")
public func sr_sci_lfilter(_ x: UnsafeMutablePointer<Double>?, _ nlines: Int64, _ n: Int64,
                           _ b: UnsafePointer<Double>?, _ a: UnsafePointer<Double>?, _ order: Int32,
                           _ zi: UnsafeMutablePointer<Double>?) -> Int32 {
    guard let x, let b, let a, nlines >= 0, n >= 0, order >= 0 else {
        return srFail(SRStatus.badArgument, "lfilter: bad arguments")
    }
    let o = Int(order), nl = Int(nlines), len = Int(n)
    if o == 0 {
        for i in 0..<(nl * len) { x[i] *= b[0] }
        return SRStatus.ok
    }
    let z = UnsafeMutablePointer<Double>.allocate(capacity: o)
    defer { z.deallocate() }
    for l in 0..<nl {
        let p = x + l * len
        for k in 0..<o { z[k] = zi?[l * o + k] ?? 0 }
        if o == 1 {
            let b0 = b[0], b1 = b[1], a1 = a[1]
            var z0 = z[0]
            for i in 0..<len {
                let xi = p[i]
                let y = b0 * xi + z0
                z0 = b1 * xi - a1 * y
                p[i] = y
            }
            z[0] = z0
        } else if o == 2 {
            let b0 = b[0], b1 = b[1], b2 = b[2], a1 = a[1], a2 = a[2]
            var z0 = z[0], z1 = z[1]
            for i in 0..<len {
                let xi = p[i]
                let y = b0 * xi + z0
                z0 = b1 * xi + z1 - a1 * y
                z1 = b2 * xi - a2 * y
                p[i] = y
            }
            z[0] = z0; z[1] = z1
        } else {
            let b0 = b[0]
            for i in 0..<len {
                let xi = p[i]
                let y = b0 * xi + z[0]
                var k = 0
                while k < o - 1 {
                    z[k] = b[k + 1] * xi + z[k + 1] - a[k + 1] * y
                    k += 1
                }
                z[o - 1] = b[o] * xi - a[o] * y
                p[i] = y
            }
        }
        if let zi { for k in 0..<o { zi[l * o + k] = z[k] } }
    }
    return SRStatus.ok
}

// MARK: - 1-D minimum filter (monotone deque, O(n))

/// Sliding minimum over `nlines` contiguous float64 lines of length `n`, writing `nout` values per line to `out`.
/// out[i] = min over j in [i+shift, i+shift+size-1] of ext(j); ext = line value clamped to the ends (mode 0, "nearest")
/// or `cval` outside [0,n) (mode 1, "constant"). NaN handling follows `<` (a NaN never replaces a number).
@_cdecl("sr_sci_minfilt1d_f64")
public func sr_sci_minfilt1d_f64(_ x: UnsafePointer<Double>?, _ out: UnsafeMutablePointer<Double>?,
                                 _ nlines: Int64, _ n: Int64, _ nout: Int64, _ size: Int64, _ shift: Int64,
                                 _ mode: Int32, _ cval: Double) -> Int32 {
    guard let x, let out, nlines >= 0, n >= 0, nout >= 0, size >= 1, mode == 0 || mode == 1 else {
        return srFail(SRStatus.badArgument, "minimum_filter1d: bad arguments")
    }
    return slidingMin(x, out, Int(nlines), Int(n), Int(nout), Int(size), Int(shift), mode, cval)
}

@_cdecl("sr_sci_minfilt1d_f32")
public func sr_sci_minfilt1d_f32(_ x: UnsafePointer<Float>?, _ out: UnsafeMutablePointer<Float>?,
                                 _ nlines: Int64, _ n: Int64, _ nout: Int64, _ size: Int64, _ shift: Int64,
                                 _ mode: Int32, _ cval: Double) -> Int32 {
    guard let x, let out, nlines >= 0, n >= 0, nout >= 0, size >= 1, mode == 0 || mode == 1 else {
        return srFail(SRStatus.badArgument, "minimum_filter1d: bad arguments")
    }
    return slidingMin(x, out, Int(nlines), Int(n), Int(nout), Int(size), Int(shift), mode, Float(cval))
}

/// Lemire-style monotone queue with the exact compare rules of scipy's NI_MinOrMaxFilter1D (a new value that is <= the
/// queue front replaces the whole queue, otherwise it pops the back while <= back), so NaN inputs give the same output
/// as scipy. Out-of-line values (nearest / constant) are never materialised: the left border is ONE queue entry
/// (index -1) and the right border one entry per output step, so memory is O(min(size, n)) and time O(n) for any size.
private func slidingMin<T: BinaryFloatingPoint>(_ x: UnsafePointer<T>, _ out: UnsafeMutablePointer<T>,
                                                _ nl: Int, _ n: Int, _ nout: Int, _ size: Int, _ shift: Int,
                                                _ mode: Int32, _ cval: T) -> Int32 {
    if nout == 0 || nl == 0 { return SRStatus.ok }
    if n == 0 { return srFail(SRStatus.badArgument, "minimum_filter1d: empty line with non-empty output") }
    // live entries <= window elements <= min(size, n + 1 + nout); power-of-two ring so wrap is a mask
    let live = min(size, n + nout + 2) + 2
    var cap = 4
    while cap < live { cap <<= 1 }
    let mask = cap - 1
    let qi = UnsafeMutablePointer<Int>.allocate(capacity: cap)
    let qv = UnsafeMutablePointer<T>.allocate(capacity: cap)
    defer { qi.deallocate(); qv.deallocate() }
    for l in 0..<nl {
        let p = x + l * n, o = out + l * nout
        let first = mode == 0 ? p[0] : cval
        let last = mode == 0 ? p[n - 1] : cval
        var head = 0, tail = 0
        @inline(__always) func push(_ idx: Int, _ v: T) {
            if tail > head && v <= qv[head & mask] {
                head = tail                                  // new minimum: drop everything
            } else {
                while tail > head && v <= qv[(tail - 1) & mask] { tail -= 1 }
            }
            qi[tail & mask] = idx; qv[tail & mask] = v
            tail += 1
        }
        let hi0 = shift + size - 1
        if shift < 0 { push(-1, first) }
        var next = max(shift, 0)
        let lim0 = min(hi0, n - 1)
        while next <= lim0 { push(next, p[next]); next += 1 }
        if hi0 >= n { push(hi0, last) }
        o[0] = qv[head & mask]
        var i = 1
        while i < nout {
            let lo = i + shift, hi = lo + size - 1
            while tail > head && qi[head & mask] < lo { head += 1 }
            if hi <= n - 1 { push(hi, p[hi]) } else { push(hi, last) }
            o[i] = qv[head & mask]
            i += 1
        }
    }
    return SRStatus.ok
}
