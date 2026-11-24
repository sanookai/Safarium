// SafariumRaster — Phase 2: Discrete Fourier / Cosine Transforms via Apple Accelerate (vDSP).
import Foundation
import Accelerate

// MARK: - Lazily cached power-of-2 vDSP FFT setups

private final class VDSPSetupCache: @unchecked Sendable {
    static let shared = VDSPSetupCache()
    private let lock = NSLock()
    private var setupsF64: [Int: FFTSetupD] = [:]

    func setupD(_ log2n: Int) -> FFTSetupD? {
        lock.lock()
        defer { lock.unlock() }
        if let s = setupsF64[log2n] { return s }
        guard let s = vDSP_create_fftsetupD(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return nil }
        setupsF64[log2n] = s
        return s
    }
}

@inline(__always)
private func nextPow2(_ n: Int) -> Int {
    var p = 1
    while p < n { p <<= 1 }
    return p
}

/// 1-D complex FFT/IFFT of arbitrary length N using native vDSP_fft_zipD (power of 2) or Bluestein over vDSP_fft_zipD.
/// Uses exact forward sign exp(-2*pi*i*n*k/N) and inverse exp(+2*pi*i*n*k/N), unnormalized.
private func fft1D(_ re: UnsafeMutablePointer<Double>, _ im: UnsafeMutablePointer<Double>, _ n: Int, _ inverse: Bool) {
    if n <= 1 { return }
    if (n & (n - 1)) == 0 {
        let log2n = n.trailingZeroBitCount
        guard let setup = VDSPSetupCache.shared.setupD(log2n) else { return }
        var sc = DSPDoubleSplitComplex(realp: re, imagp: im)
        vDSP_fft_zipD(setup, &sc, 1, vDSP_Length(log2n), FFTDirection(inverse ? FFT_INVERSE : FFT_FORWARD))
        return
    }
    // Bluestein's FFT convolution over power-of-2 length L >= 2*n - 1
    let L = nextPow2(2 * n - 1)
    let log2L = L.trailingZeroBitCount
    guard let setup = VDSPSetupCache.shared.setupD(log2L) else { return }
    let ar = UnsafeMutablePointer<Double>.allocate(capacity: L)
    let ai = UnsafeMutablePointer<Double>.allocate(capacity: L)
    let br = UnsafeMutablePointer<Double>.allocate(capacity: L)
    let bi = UnsafeMutablePointer<Double>.allocate(capacity: L)
    let wr = UnsafeMutablePointer<Double>.allocate(capacity: n)
    let wi = UnsafeMutablePointer<Double>.allocate(capacity: n)
    ar.initialize(repeating: 0.0, count: L)
    ai.initialize(repeating: 0.0, count: L)
    br.initialize(repeating: 0.0, count: L)
    bi.initialize(repeating: 0.0, count: L)
    defer {
        ar.deallocate(); ai.deallocate(); br.deallocate(); bi.deallocate(); wr.deallocate(); wi.deallocate()
    }
    let sign = inverse ? 1.0 : -1.0
    let twoN = 2 * n
    for k in 0..<n {
        let idxMod = (k * k) % twoN
        let ang = sign * Double.pi * Double(idxMod) / Double(n)
        let cw = cos(ang), sw = sin(ang)
        wr[k] = cw; wi[k] = sw
        ar[k] = re[k] * cw - im[k] * sw
        ai[k] = re[k] * sw + im[k] * cw
    }
    br[0] = wr[0]; bi[0] = -wi[0]
    for k in 1..<n {
        br[k] = wr[k]; bi[k] = -wi[k]
        br[L - k] = wr[k]; bi[L - k] = -wi[k]
    }
    var sa = DSPDoubleSplitComplex(realp: ar, imagp: ai)
    var sb = DSPDoubleSplitComplex(realp: br, imagp: bi)
    vDSP_fft_zipD(setup, &sa, 1, vDSP_Length(log2L), FFTDirection(FFT_FORWARD))
    vDSP_fft_zipD(setup, &sb, 1, vDSP_Length(log2L), FFTDirection(FFT_FORWARD))
    for k in 0..<L {
        let tr = ar[k] * br[k] - ai[k] * bi[k]
        let ti = ar[k] * bi[k] + ai[k] * br[k]
        ar[k] = tr; ai[k] = ti
    }
    vDSP_fft_zipD(setup, &sa, 1, vDSP_Length(log2L), FFTDirection(FFT_INVERSE))
    let invL = 1.0 / Double(L)
    for k in 0..<n {
        let vr = ar[k] * invL, vi = ai[k] * invL
        re[k] = vr * wr[k] - vi * wi[k]
        im[k] = vr * wi[k] + vi * wr[k]
    }
}

private func fft2D(_ re: UnsafeMutablePointer<Double>, _ im: UnsafeMutablePointer<Double>,
                   _ rows: Int, _ cols: Int, _ inverse: Bool, _ rowsOnly: Bool) {
    for r in 0..<rows {
        fft1D(re + r * cols, im + r * cols, cols, inverse)
    }
    if rowsOnly || (rows <= 1 && cols > 1) { return }
    if cols == 1 && rows > 1 {
        fft1D(re, im, rows, inverse)
        return
    }
    // Transpose into (cols x rows), batch 1-D FFT across columns, transpose back
    let tRe = UnsafeMutablePointer<Double>.allocate(capacity: rows * cols)
    let tIm = UnsafeMutablePointer<Double>.allocate(capacity: rows * cols)
    defer { tRe.deallocate(); tIm.deallocate() }
    vDSP_mtransD(re, 1, tRe, 1, vDSP_Length(cols), vDSP_Length(rows))
    vDSP_mtransD(im, 1, tIm, 1, vDSP_Length(cols), vDSP_Length(rows))
    for c in 0..<cols {
        fft1D(tRe + c * rows, tIm + c * rows, rows, inverse)
    }
    vDSP_mtransD(tRe, 1, re, 1, vDSP_Length(rows), vDSP_Length(cols))
    vDSP_mtransD(tIm, 1, im, 1, vDSP_Length(rows), vDSP_Length(cols))
}

// MARK: - OpenCV CCS (Complex Conjugate Symmetrical) pack / unpack

private func packCCS1D(_ re: UnsafePointer<Double>, _ im: UnsafePointer<Double>, _ n: Int,
                       _ out: UnsafeMutablePointer<Double>, _ outStride: Int) {
    out[0] = re[0]
    let pairs = (n - 1) / 2
    for k in 1...max(pairs, 0) where pairs >= 1 {
        out[(2 * k - 1) * outStride] = re[k]
        out[(2 * k) * outStride] = im[k]
    }
    if n % 2 == 0 && n > 1 {
        out[(n - 1) * outStride] = re[n / 2]
    }
}

private func unpackCCS1D(_ src: UnsafePointer<Double>, _ srcStride: Int, _ n: Int,
                         _ re: UnsafeMutablePointer<Double>, _ im: UnsafeMutablePointer<Double>) {
    re[0] = src[0]; im[0] = 0.0
    let pairs = (n - 1) / 2
    for k in 1...max(pairs, 0) where pairs >= 1 {
        let rv = src[(2 * k - 1) * srcStride]
        let iv = src[(2 * k) * srcStride]
        re[k] = rv; im[k] = iv
        re[n - k] = rv; im[n - k] = -iv
    }
    if n % 2 == 0 && n > 1 {
        re[n / 2] = src[(n - 1) * srcStride]
        im[n / 2] = 0.0
    }
}

private func packCCS(_ re: UnsafePointer<Double>, _ im: UnsafePointer<Double>,
                     _ m: Int, _ n: Int, _ rowsOnly: Bool, _ ccs: UnsafeMutablePointer<Double>) {
    if rowsOnly {
        for r in 0..<m { packCCS1D(re + r * n, im + r * n, n, ccs + r * n, 1) }
        return
    }
    if m == 1 { packCCS1D(re, im, n, ccs, 1); return }
    if n == 1 { packCCS1D(re, im, m, ccs, 1); return }
    // 2D CCS
    packCCS1D(re, im, n, ccs, 1)
    // Pack col 0 vertically
    ccs[0] = re[0]
    let rPairs = (m - 1) / 2
    for i in 1...max(rPairs, 0) where rPairs >= 1 {
        ccs[(2 * i - 1) * n] = re[i * n]
        ccs[(2 * i) * n] = im[i * n]
    }
    if m % 2 == 0 { ccs[(m - 1) * n] = re[(m / 2) * n] }
    // Pack Nyquist col n/2 vertically at col n-1 when n is even
    if n % 2 == 0 {
        let halfC = n / 2
        ccs[n - 1] = re[halfC]
        for i in 1...max(rPairs, 0) where rPairs >= 1 {
            ccs[(2 * i - 1) * n + (n - 1)] = re[i * n + halfC]
            ccs[(2 * i) * n + (n - 1)] = im[i * n + halfC]
        }
        if m % 2 == 0 { ccs[(m - 1) * n + (n - 1)] = re[(m / 2) * n + halfC] }
    }
    // Interior columns j = 1..<(n+1)/2 for rows 1..<m
    let cPairs = (n - 1) / 2
    if cPairs >= 1 {
        for i in 1..<m {
            for j in 1...cPairs {
                ccs[i * n + 2 * j - 1] = re[i * n + j]
                ccs[i * n + 2 * j] = im[i * n + j]
            }
        }
    }
}

private func unpackCCS(_ ccs: UnsafePointer<Double>, _ m: Int, _ n: Int, _ rowsOnly: Bool,
                       _ re: UnsafeMutablePointer<Double>, _ im: UnsafeMutablePointer<Double>) {
    if rowsOnly {
        for r in 0..<m { unpackCCS1D(ccs + r * n, 1, n, re + r * n, im + r * n) }
        return
    }
    if m == 1 { unpackCCS1D(ccs, 1, n, re, im); return }
    if n == 1 { unpackCCS1D(ccs, 1, m, re, im); return }
    unpackCCS1D(ccs, 1, n, re, im)
    // Col 0 vertical unpack
    re[0] = ccs[0]; im[0] = 0.0
    let rPairs = (m - 1) / 2
    for i in 1...max(rPairs, 0) where rPairs >= 1 {
        let rv = ccs[(2 * i - 1) * n], iv = ccs[(2 * i) * n]
        re[i * n] = rv; im[i * n] = iv
        re[(m - i) * n] = rv; im[(m - i) * n] = -iv
    }
    if m % 2 == 0 { re[(m / 2) * n] = ccs[(m - 1) * n]; im[(m / 2) * n] = 0.0 }
    if n % 2 == 0 {
        let halfC = n / 2
        re[halfC] = ccs[n - 1]; im[halfC] = 0.0
        for i in 1...max(rPairs, 0) where rPairs >= 1 {
            let rv = ccs[(2 * i - 1) * n + (n - 1)], iv = ccs[(2 * i) * n + (n - 1)]
            re[i * n + halfC] = rv; im[i * n + halfC] = iv
            re[(m - i) * n + halfC] = rv; im[(m - i) * n + halfC] = -iv
        }
        if m % 2 == 0 { re[(m / 2) * n + halfC] = ccs[(m - 1) * n + (n - 1)]; im[(m / 2) * n + halfC] = 0.0 }
    }
    let cPairs = (n - 1) / 2
    if cPairs >= 1 {
        for i in 1..<m {
            for j in 1...cPairs {
                let rv = ccs[i * n + 2 * j - 1], iv = ccs[i * n + 2 * j]
                re[i * n + j] = rv; im[i * n + j] = iv
                re[(m - i) * n + (n - j)] = rv; im[(m - i) * n + (n - j)] = -iv
            }
        }
    }
}

// MARK: - C ABI: dft / mulSpectrums / dct

private func readRealRowMajor(_ m: CoreMat, _ dst: UnsafeMutablePointer<Double>) {
    for r in 0..<m.rows {
        let p = m.row(r)
        if m.depth == 6 { memcpy(dst + r * m.cols, p, m.cols * 8) }
        else { vDSP_vspdp(p.assumingMemoryBound(to: Float.self), 1, dst + r * m.cols, 1, vDSP_Length(m.cols)) }
    }
}

private func writeRealRowMajor(_ src: UnsafePointer<Double>, _ m: CoreMat) {
    for r in 0..<m.rows {
        let p = m.row(r)
        if m.depth == 6 { memcpy(p, src + r * m.cols, m.cols * 8) }
        else { vDSP_vdpsp(src + r * m.cols, 1, p.assumingMemoryBound(to: Float.self), 1, vDSP_Length(m.cols)) }
    }
}

private func readComplexRowMajor(_ m: CoreMat, _ re: UnsafeMutablePointer<Double>, _ im: UnsafeMutablePointer<Double>) {
    let cols = m.cols
    for r in 0..<m.rows {
        let row = m.row(r)
        if m.depth == 6 {
            let p = row.assumingMemoryBound(to: Double.self)
            for c in 0..<cols { re[r * cols + c] = p[2 * c]; im[r * cols + c] = p[2 * c + 1] }
        } else {
            let p = row.assumingMemoryBound(to: Float.self)
            for c in 0..<cols { re[r * cols + c] = Double(p[2 * c]); im[r * cols + c] = Double(p[2 * c + 1]) }
        }
    }
}

private func writeComplexRowMajor(_ re: UnsafePointer<Double>, _ im: UnsafePointer<Double>, _ m: CoreMat) {
    let cols = m.cols
    for r in 0..<m.rows {
        let row = m.row(r)
        if m.depth == 6 {
            let p = row.assumingMemoryBound(to: Double.self)
            for c in 0..<cols { p[2 * c] = re[r * cols + c]; p[2 * c + 1] = im[r * cols + c] }
        } else {
            let p = row.assumingMemoryBound(to: Float.self)
            for c in 0..<cols { p[2 * c] = Float(re[r * cols + c]); p[2 * c + 1] = Float(im[r * cols + c]) }
        }
    }
}

@_cdecl("sr_la_dft")
public func sr_la_dft(_ srcP: MatP?, _ dstP: MatP?, _ flags: Int32) -> Int32 {
    guard let src = mat(srcP), let dst = mat(dstP) else { return srFail(SRStatus.badArgument, "dft: null") }
    guard (src.depth == 5 || src.depth == 6), src.depth == dst.depth,
          (src.cn == 1 || src.cn == 2), (dst.cn == 1 || dst.cn == 2),
          src.rows == dst.rows, src.cols == dst.cols else {
        return srFail(SRStatus.badArgument, "dft: invalid shapes or depths")
    }
    let m = src.rows, n = src.cols
    if m == 0 || n == 0 { return SRStatus.ok }
    let inv = (flags & 1) != 0
    let scaleFlag = (flags & 2) != 0
    let rowsOnly = (flags & 4) != 0
    let cplxOut = (flags & 16) != 0
    let realOut = (flags & 32) != 0

    let count = m * n
    let re = UnsafeMutablePointer<Double>.allocate(capacity: count)
    let im = UnsafeMutablePointer<Double>.allocate(capacity: count)
    defer { re.deallocate(); im.deallocate() }

    if src.cn == 1 {
        let rBuf = UnsafeMutablePointer<Double>.allocate(capacity: count)
        defer { rBuf.deallocate() }
        readRealRowMajor(src, rBuf)
        if inv {
            unpackCCS(rBuf, m, n, rowsOnly, re, im)
        } else {
            memcpy(re, rBuf, count * 8)
            im.initialize(repeating: 0.0, count: count)
        }
    } else {
        readComplexRowMajor(src, re, im)
    }

    fft2D(re, im, m, n, inv, rowsOnly)
    if scaleFlag {
        let denom: Double
        if rowsOnly { denom = Double(n) }
        else if m == 1 || n == 1 { denom = Double(max(m, n)) }
        else { denom = Double(m * n) }
        var invD = 1.0 / denom
        vDSP_vsmulD(re, 1, &invD, re, 1, vDSP_Length(count))
        vDSP_vsmulD(im, 1, &invD, im, 1, vDSP_Length(count))
    }

    if dst.cn == 2 || (cplxOut && !realOut) {
        writeComplexRowMajor(re, im, dst)
    } else if !inv && src.cn == 1 {
        let ccs = UnsafeMutablePointer<Double>.allocate(capacity: count)
        defer { ccs.deallocate() }
        packCCS(re, im, m, n, rowsOnly, ccs)
        writeRealRowMajor(ccs, dst)
    } else {
        writeRealRowMajor(re, dst)
    }
    return SRStatus.ok
}

@_cdecl("sr_la_mul_spectrums")
public func sr_la_mul_spectrums(_ aP: MatP?, _ bP: MatP?, _ cP: MatP?, _ flags: Int32, _ conjB: Int32) -> Int32 {
    guard let a = mat(aP), let b = mat(bP), let c = mat(cP) else {
        return srFail(SRStatus.badArgument, "mulSpectrums: null")
    }
    guard (a.depth == 5 || a.depth == 6), a.depth == b.depth, a.depth == c.depth,
          (a.cn == 1 || a.cn == 2), a.cn == b.cn, a.cn == c.cn,
          a.rows == b.rows, a.cols == b.cols, a.rows == c.rows, a.cols == c.cols else {
        return srFail(SRStatus.badArgument, "mulSpectrums: shape/type mismatch")
    }
    let m = a.rows, n = a.cols, count = m * n
    if count == 0 { return SRStatus.ok }
    let rowsOnly = (flags & 4) != 0
    let conj = conjB != 0

    let ar = UnsafeMutablePointer<Double>.allocate(capacity: count)
    let ai = UnsafeMutablePointer<Double>.allocate(capacity: count)
    let br = UnsafeMutablePointer<Double>.allocate(capacity: count)
    let bi = UnsafeMutablePointer<Double>.allocate(capacity: count)
    defer { ar.deallocate(); ai.deallocate(); br.deallocate(); bi.deallocate() }

    if a.cn == 1 {
        let ta = UnsafeMutablePointer<Double>.allocate(capacity: count)
        let tb = UnsafeMutablePointer<Double>.allocate(capacity: count)
        defer { ta.deallocate(); tb.deallocate() }
        readRealRowMajor(a, ta); readRealRowMajor(b, tb)
        unpackCCS(ta, m, n, rowsOnly, ar, ai)
        unpackCCS(tb, m, n, rowsOnly, br, bi)
    } else {
        readComplexRowMajor(a, ar, ai)
        readComplexRowMajor(b, br, bi)
    }
    if conj {
        for i in 0..<count { bi[i] = -bi[i] }
    }
    for i in 0..<count {
        let rr = ar[i] * br[i] - ai[i] * bi[i]
        let ii = ar[i] * bi[i] + ai[i] * br[i]
        ar[i] = rr; ai[i] = ii
    }
    if a.cn == 1 {
        let tc = UnsafeMutablePointer<Double>.allocate(capacity: count)
        defer { tc.deallocate() }
        packCCS(ar, ai, m, n, rowsOnly, tc)
        writeRealRowMajor(tc, c)
    } else {
        writeComplexRowMajor(ar, ai, c)
    }
    return SRStatus.ok
}

// MARK: - Orthonormal DCT-II / IDCT-II (Makhoul over vDSP FFT)

private func dct1D(_ x: UnsafeMutablePointer<Double>, _ n: Int, _ inverse: Bool) {
    if n <= 1 { return }
    let re = UnsafeMutablePointer<Double>.allocate(capacity: n)
    let im = UnsafeMutablePointer<Double>.allocate(capacity: n)
    defer { re.deallocate(); im.deallocate() }

    if !inverse {
        let half = n / 2
        for k in 0..<half {
            re[k] = x[2 * k]
            re[n - 1 - k] = x[2 * k + 1]
        }
        im.initialize(repeating: 0.0, count: n)
        fft1D(re, im, n, false)
        let s0 = 1.0 / sqrt(Double(n))
        let sk = sqrt(2.0 / Double(n))
        let pStep = -Double.pi / Double(2 * n)
        x[0] = re[0] * s0
        for k in 1..<n {
            let ang = pStep * Double(k)
            x[k] = (cos(ang) * re[k] - sin(ang) * im[k]) * sk
        }
    } else {
        let s0 = sqrt(Double(n))
        let sk = sqrt(Double(n) * 0.5)
        let pStep = Double.pi / Double(2 * n)
        re[0] = x[0] * s0; im[0] = 0.0
        for k in 1..<n {
            let ck = x[k] * sk
            let cnk = x[n - k] * sk
            let ang = pStep * Double(k)
            let ca = cos(ang), sa = sin(ang)
            // (ck - i*cnk) * exp(+i*ang)
            re[k] = ck * ca + cnk * sa
            im[k] = ck * sa - cnk * ca
        }
        fft1D(re, im, n, true)
        let invN = 1.0 / Double(n)
        let half = n / 2
        for k in 0..<half {
            x[2 * k] = re[k] * invN
            x[2 * k + 1] = re[n - 1 - k] * invN
        }
    }
}

@_cdecl("sr_la_dct")
public func sr_la_dct(_ srcP: MatP?, _ dstP: MatP?, _ flags: Int32) -> Int32 {
    guard let src = mat(srcP), let dst = mat(dstP) else { return srFail(SRStatus.badArgument, "dct: null") }
    guard (src.depth == 5 || src.depth == 6), src.depth == dst.depth, src.cn == 1, dst.cn == 1,
          src.rows == dst.rows, src.cols == dst.cols else {
        return srFail(SRStatus.badArgument, "dct: invalid shapes or depths")
    }
    let m = src.rows, n = src.cols
    if m == 0 || n == 0 { return SRStatus.ok }
    let inv = (flags & 1) != 0
    let rowsOnly = (flags & 4) != 0
    if n > 1 && n % 2 != 0 { return srFail(SRStatus.badArgument, "dct: odd column count unsupported") }
    if !rowsOnly && m > 1 && m % 2 != 0 { return srFail(SRStatus.badArgument, "dct: odd row count unsupported") }

    let buf = UnsafeMutablePointer<Double>.allocate(capacity: m * n)
    defer { buf.deallocate() }
    readRealRowMajor(src, buf)
    if n > 1 || m == 1 {
        for r in 0..<m { dct1D(buf + r * n, n, inv) }
    }
    if !rowsOnly && m > 1 {
        let t = UnsafeMutablePointer<Double>.allocate(capacity: m * n)
        defer { t.deallocate() }
        vDSP_mtransD(buf, 1, t, 1, vDSP_Length(n), vDSP_Length(m))
        for c in 0..<n { dct1D(t + c * m, m, inv) }
        vDSP_mtransD(t, 1, buf, 1, vDSP_Length(m), vDSP_Length(n))
    }
    writeRealRowMajor(buf, dst)
    return SRStatus.ok
}
