// SafariumRaster — Phase 2: Discrete Fourier / Cosine Transforms via Apple Accelerate (vDSP).
import Foundation
import Accelerate

// MARK: - Lazily cached vDSP FFT setups, Bluestein plans, and DCT twiddle tables

private final class BluesteinD {
    let n: Int, L: Int, log2L: Int
    let setup: FFTSetupD
    let wr: UnsafeMutablePointer<Double>
    let wi: UnsafeMutablePointer<Double>
    let fbr: UnsafeMutablePointer<Double>
    let fbi: UnsafeMutablePointer<Double>
    init(_ n: Int, _ inverse: Bool, _ setup: FFTSetupD, _ L: Int) {
        self.n = n; self.L = L; self.log2L = L.trailingZeroBitCount; self.setup = setup
        wr = .allocate(capacity: n); wi = .allocate(capacity: n)
        fbr = .allocate(capacity: L); fbi = .allocate(capacity: L)
        fbr.initialize(repeating: 0.0, count: L); fbi.initialize(repeating: 0.0, count: L)
        let sign = inverse ? 1.0 : -1.0
        let twoN = 2 * n
        for k in 0..<n {
            let idxMod = (k * k) % twoN
            let ang = sign * Double.pi * Double(idxMod) / Double(n)
            let cw = cos(ang), sw = sin(ang)
            wr[k] = cw; wi[k] = sw
        }
        fbr[0] = wr[0]; fbi[0] = -wi[0]
        for k in 1..<n {
            fbr[k] = wr[k]; fbi[k] = -wi[k]
            fbr[L - k] = wr[k]; fbi[L - k] = -wi[k]
        }
        var sb = DSPDoubleSplitComplex(realp: fbr, imagp: fbi)
        vDSP_fft_zipD(setup, &sb, 1, vDSP_Length(log2L), FFTDirection(FFT_FORWARD))
    }
    deinit { wr.deallocate(); wi.deallocate(); fbr.deallocate(); fbi.deallocate() }
}

private final class BluesteinF {
    let n: Int, L: Int, log2L: Int
    let setup: FFTSetup
    let wr: UnsafeMutablePointer<Float>
    let wi: UnsafeMutablePointer<Float>
    let fbr: UnsafeMutablePointer<Float>
    let fbi: UnsafeMutablePointer<Float>
    init(_ n: Int, _ inverse: Bool, _ setup: FFTSetup, _ L: Int) {
        self.n = n; self.L = L; self.log2L = L.trailingZeroBitCount; self.setup = setup
        wr = .allocate(capacity: n); wi = .allocate(capacity: n)
        fbr = .allocate(capacity: L); fbi = .allocate(capacity: L)
        fbr.initialize(repeating: 0.0, count: L); fbi.initialize(repeating: 0.0, count: L)
        let sign = inverse ? 1.0 : -1.0
        let twoN = 2 * n
        for k in 0..<n {
            let idxMod = (k * k) % twoN
            let ang = sign * Double.pi * Double(idxMod) / Double(n)
            wr[k] = Float(cos(ang)); wi[k] = Float(sin(ang))
        }
        fbr[0] = wr[0]; fbi[0] = -wi[0]
        for k in 1..<n {
            fbr[k] = wr[k]; fbi[k] = -wi[k]
            fbr[L - k] = wr[k]; fbi[L - k] = -wi[k]
        }
        var sb = DSPSplitComplex(realp: fbr, imagp: fbi)
        vDSP_fft_zip(setup, &sb, 1, vDSP_Length(log2L), FFTDirection(FFT_FORWARD))
    }
    deinit { wr.deallocate(); wi.deallocate(); fbr.deallocate(); fbi.deallocate() }
}

private final class DctTwiddleD {
    let cosT: UnsafeMutablePointer<Double>
    let sinT: UnsafeMutablePointer<Double>
    init(_ n: Int, _ inverse: Bool) {
        cosT = .allocate(capacity: n); sinT = .allocate(capacity: n)
        let pStep = (inverse ? 1.0 : -1.0) * Double.pi / Double(2 * n)
        for k in 0..<n {
            let ang = pStep * Double(k)
            cosT[k] = cos(ang); sinT[k] = sin(ang)
        }
    }
    deinit { cosT.deallocate(); sinT.deallocate() }
}

private final class DctTwiddleF {
    let cosT: UnsafeMutablePointer<Float>
    let sinT: UnsafeMutablePointer<Float>
    init(_ n: Int, _ inverse: Bool) {
        cosT = .allocate(capacity: n); sinT = .allocate(capacity: n)
        let pStep = (inverse ? 1.0 : -1.0) * Double.pi / Double(2 * n)
        for k in 0..<n {
            let ang = pStep * Double(k)
            cosT[k] = Float(cos(ang)); sinT[k] = Float(sin(ang))
        }
    }
    deinit { cosT.deallocate(); sinT.deallocate() }
}

private final class VDSPSetupCache: @unchecked Sendable {
    static let shared = VDSPSetupCache()
    private let lock = NSLock()
    private var setupsF64: [Int: FFTSetupD] = [:]
    private var setupsF32: [Int: FFTSetup] = [:]
    private var blueD: [Int: BluesteinD] = [:]
    private var blueF: [Int: BluesteinF] = [:]
    private var dctD: [Int: DctTwiddleD] = [:]
    private var dctF: [Int: DctTwiddleF] = [:]

    private func setupDLocked(_ log2n: Int) -> FFTSetupD? {
        if let s = setupsF64[log2n] { return s }
        guard let s = vDSP_create_fftsetupD(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return nil }
        setupsF64[log2n] = s
        return s
    }

    private func setupFLocked(_ log2n: Int) -> FFTSetup? {
        if let s = setupsF32[log2n] { return s }
        guard let s = vDSP_create_fftsetup(vDSP_Length(log2n), FFTRadix(kFFTRadix2)) else { return nil }
        setupsF32[log2n] = s
        return s
    }

    func setupD(_ log2n: Int) -> FFTSetupD? { lock.lock(); defer { lock.unlock() }; return setupDLocked(log2n) }
    func setupF(_ log2n: Int) -> FFTSetup? { lock.lock(); defer { lock.unlock() }; return setupFLocked(log2n) }

    func bluesteinD(_ n: Int, _ inverse: Bool) -> BluesteinD? {
        let key = (n << 1) | (inverse ? 1 : 0)
        lock.lock(); defer { lock.unlock() }
        if let b = blueD[key] { return b }
        let L = nextPow2(2 * n - 1)
        guard let s = setupDLocked(L.trailingZeroBitCount) else { return nil }
        let b = BluesteinD(n, inverse, s, L)
        blueD[key] = b
        return b
    }

    func bluesteinF(_ n: Int, _ inverse: Bool) -> BluesteinF? {
        let key = (n << 1) | (inverse ? 1 : 0)
        lock.lock(); defer { lock.unlock() }
        if let b = blueF[key] { return b }
        let L = nextPow2(2 * n - 1)
        guard let s = setupFLocked(L.trailingZeroBitCount) else { return nil }
        let b = BluesteinF(n, inverse, s, L)
        blueF[key] = b
        return b
    }

    func dctTwiddleD(_ n: Int, _ inverse: Bool) -> DctTwiddleD {
        let key = (n << 1) | (inverse ? 1 : 0)
        lock.lock(); defer { lock.unlock() }
        if let t = dctD[key] { return t }
        let t = DctTwiddleD(n, inverse)
        dctD[key] = t
        return t
    }

    func dctTwiddleF(_ n: Int, _ inverse: Bool) -> DctTwiddleF {
        let key = (n << 1) | (inverse ? 1 : 0)
        lock.lock(); defer { lock.unlock() }
        if let t = dctF[key] { return t }
        let t = DctTwiddleF(n, inverse)
        dctF[key] = t
        return t
    }
}

@inline(__always)
private func nextPow2(_ n: Int) -> Int {
    var p = 1
    while p < n { p <<= 1 }
    return p
}

// MARK: - 1D / 2D FFT (Float64 & native Float32)

private func fft1D_D(_ re: UnsafeMutablePointer<Double>, _ im: UnsafeMutablePointer<Double>, _ n: Int, _ inverse: Bool,
                     _ scratchR: UnsafeMutablePointer<Double>? = nil, _ scratchI: UnsafeMutablePointer<Double>? = nil) {
    if n <= 1 { return }
    if (n & (n - 1)) == 0 {
        let log2n = n.trailingZeroBitCount
        guard let setup = VDSPSetupCache.shared.setupD(log2n) else { return }
        var sc = DSPDoubleSplitComplex(realp: re, imagp: im)
        vDSP_fft_zipD(setup, &sc, 1, vDSP_Length(log2n), FFTDirection(inverse ? FFT_INVERSE : FFT_FORWARD))
        return
    }
    guard let plan = VDSPSetupCache.shared.bluesteinD(n, inverse) else { return }
    let L = plan.L
    let ar: UnsafeMutablePointer<Double>, ai: UnsafeMutablePointer<Double>
    let ownScratch = scratchR == nil || scratchI == nil
    if ownScratch {
        ar = .allocate(capacity: L); ai = .allocate(capacity: L)
    } else {
        ar = scratchR!; ai = scratchI!
    }
    defer { if ownScratch { ar.deallocate(); ai.deallocate() } }
    if L > n { memset(ar + n, 0, (L - n) * 8); memset(ai + n, 0, (L - n) * 8) }
    let wr = plan.wr, wi = plan.wi
    for k in 0..<n {
        let rk = re[k], ik = im[k], cw = wr[k], sw = wi[k]
        ar[k] = rk * cw - ik * sw
        ai[k] = rk * sw + ik * cw
    }
    var sa = DSPDoubleSplitComplex(realp: ar, imagp: ai)
    vDSP_fft_zipD(plan.setup, &sa, 1, vDSP_Length(plan.log2L), FFTDirection(FFT_FORWARD))
    var sb = DSPDoubleSplitComplex(realp: plan.fbr, imagp: plan.fbi)
    vDSP_zvmulD(&sa, 1, &sb, 1, &sa, 1, vDSP_Length(L), 1)
    vDSP_fft_zipD(plan.setup, &sa, 1, vDSP_Length(plan.log2L), FFTDirection(FFT_INVERSE))
    let invL = 1.0 / Double(L)
    for k in 0..<n {
        let vr = ar[k] * invL, vi = ai[k] * invL
        re[k] = vr * wr[k] - vi * wi[k]
        im[k] = vr * wi[k] + vi * wr[k]
    }
}

private func fft1D_F(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>, _ n: Int, _ inverse: Bool,
                     _ scratchR: UnsafeMutablePointer<Float>? = nil, _ scratchI: UnsafeMutablePointer<Float>? = nil) {
    if n <= 1 { return }
    if (n & (n - 1)) == 0 {
        let log2n = n.trailingZeroBitCount
        guard let setup = VDSPSetupCache.shared.setupF(log2n) else { return }
        var sc = DSPSplitComplex(realp: re, imagp: im)
        vDSP_fft_zip(setup, &sc, 1, vDSP_Length(log2n), FFTDirection(inverse ? FFT_INVERSE : FFT_FORWARD))
        return
    }
    guard let plan = VDSPSetupCache.shared.bluesteinF(n, inverse) else { return }
    let L = plan.L
    let ar: UnsafeMutablePointer<Float>, ai: UnsafeMutablePointer<Float>
    let ownScratch = scratchR == nil || scratchI == nil
    if ownScratch {
        ar = .allocate(capacity: L); ai = .allocate(capacity: L)
    } else {
        ar = scratchR!; ai = scratchI!
    }
    defer { if ownScratch { ar.deallocate(); ai.deallocate() } }
    if L > n { memset(ar + n, 0, (L - n) * 4); memset(ai + n, 0, (L - n) * 4) }
    let wr = plan.wr, wi = plan.wi
    for k in 0..<n {
        let rk = re[k], ik = im[k], cw = wr[k], sw = wi[k]
        ar[k] = rk * cw - ik * sw
        ai[k] = rk * sw + ik * cw
    }
    var sa = DSPSplitComplex(realp: ar, imagp: ai)
    vDSP_fft_zip(plan.setup, &sa, 1, vDSP_Length(plan.log2L), FFTDirection(FFT_FORWARD))
    var sb = DSPSplitComplex(realp: plan.fbr, imagp: plan.fbi)
    vDSP_zvmul(&sa, 1, &sb, 1, &sa, 1, vDSP_Length(L), 1)
    vDSP_fft_zip(plan.setup, &sa, 1, vDSP_Length(plan.log2L), FFTDirection(FFT_INVERSE))
    let invL = Float(1.0 / Double(L))
    for k in 0..<n {
        let vr = ar[k] * invL, vi = ai[k] * invL
        re[k] = vr * wr[k] - vi * wi[k]
        im[k] = vr * wi[k] + vi * wr[k]
    }
}

private func fft2D_D(_ re: UnsafeMutablePointer<Double>, _ im: UnsafeMutablePointer<Double>,
                     _ rows: Int, _ cols: Int, _ inverse: Bool, _ rowsOnly: Bool) {
    if !rowsOnly && rows >= 16 && cols >= 16 && (rows & (rows - 1)) == 0 && (cols & (cols - 1)) == 0 {
        let log2c = cols.trailingZeroBitCount, log2r = rows.trailingZeroBitCount
        if let setup = VDSPSetupCache.shared.setupD(max(log2c, log2r)) {
            var sc = DSPDoubleSplitComplex(realp: re, imagp: im)
            vDSP_fft2d_zipD(setup, &sc, 1, 0, vDSP_Length(log2c), vDSP_Length(log2r),
                            FFTDirection(inverse ? FFT_INVERSE : FFT_FORWARD))
            return
        }
    }
    let Lmax = max((cols & (cols - 1)) == 0 ? 1 : nextPow2(2 * cols - 1),
                   (rows & (rows - 1)) == 0 ? 1 : nextPow2(2 * rows - 1))
    let sr = UnsafeMutablePointer<Double>.allocate(capacity: Lmax)
    let si = UnsafeMutablePointer<Double>.allocate(capacity: Lmax)
    defer { sr.deallocate(); si.deallocate() }
    for r in 0..<rows { fft1D_D(re + r * cols, im + r * cols, cols, inverse, sr, si) }
    if rowsOnly || (rows <= 1 && cols > 1) { return }
    if cols == 1 && rows > 1 { fft1D_D(re, im, rows, inverse, sr, si); return }
    let tRe = UnsafeMutablePointer<Double>.allocate(capacity: rows * cols)
    let tIm = UnsafeMutablePointer<Double>.allocate(capacity: rows * cols)
    defer { tRe.deallocate(); tIm.deallocate() }
    vDSP_mtransD(re, 1, tRe, 1, vDSP_Length(cols), vDSP_Length(rows))
    vDSP_mtransD(im, 1, tIm, 1, vDSP_Length(cols), vDSP_Length(rows))
    for c in 0..<cols { fft1D_D(tRe + c * rows, tIm + c * rows, rows, inverse, sr, si) }
    vDSP_mtransD(tRe, 1, re, 1, vDSP_Length(rows), vDSP_Length(cols))
    vDSP_mtransD(tIm, 1, im, 1, vDSP_Length(rows), vDSP_Length(cols))
}

private func fft2D_F(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>,
                     _ rows: Int, _ cols: Int, _ inverse: Bool, _ rowsOnly: Bool) {
    if !rowsOnly && rows >= 16 && cols >= 16 && (rows & (rows - 1)) == 0 && (cols & (cols - 1)) == 0 {
        let log2c = cols.trailingZeroBitCount, log2r = rows.trailingZeroBitCount
        if let setup = VDSPSetupCache.shared.setupF(max(log2c, log2r)) {
            var sc = DSPSplitComplex(realp: re, imagp: im)
            vDSP_fft2d_zip(setup, &sc, 1, 0, vDSP_Length(log2c), vDSP_Length(log2r),
                           FFTDirection(inverse ? FFT_INVERSE : FFT_FORWARD))
            return
        }
    }
    let Lmax = max((cols & (cols - 1)) == 0 ? 1 : nextPow2(2 * cols - 1),
                   (rows & (rows - 1)) == 0 ? 1 : nextPow2(2 * rows - 1))
    let sr = UnsafeMutablePointer<Float>.allocate(capacity: Lmax)
    let si = UnsafeMutablePointer<Float>.allocate(capacity: Lmax)
    defer { sr.deallocate(); si.deallocate() }
    for r in 0..<rows { fft1D_F(re + r * cols, im + r * cols, cols, inverse, sr, si) }
    if rowsOnly || (rows <= 1 && cols > 1) { return }
    if cols == 1 && rows > 1 { fft1D_F(re, im, rows, inverse, sr, si); return }
    let tRe = UnsafeMutablePointer<Float>.allocate(capacity: rows * cols)
    let tIm = UnsafeMutablePointer<Float>.allocate(capacity: rows * cols)
    defer { tRe.deallocate(); tIm.deallocate() }
    vDSP_mtrans(re, 1, tRe, 1, vDSP_Length(cols), vDSP_Length(rows))
    vDSP_mtrans(im, 1, tIm, 1, vDSP_Length(cols), vDSP_Length(rows))
    for c in 0..<cols { fft1D_F(tRe + c * rows, tIm + c * rows, rows, inverse, sr, si) }
    vDSP_mtrans(tRe, 1, re, 1, vDSP_Length(rows), vDSP_Length(cols))
    vDSP_mtrans(tIm, 1, im, 1, vDSP_Length(rows), vDSP_Length(cols))
}

// MARK: - OpenCV CCS (Complex Conjugate Symmetrical) pack / unpack

private func packCCS1D_D(_ re: UnsafePointer<Double>, _ im: UnsafePointer<Double>, _ n: Int,
                         _ out: UnsafeMutablePointer<Double>, _ outStride: Int) {
    out[0] = re[0]
    let pairs = (n - 1) / 2
    for k in 1...max(pairs, 0) where pairs >= 1 {
        out[(2 * k - 1) * outStride] = re[k]; out[(2 * k) * outStride] = im[k]
    }
    if n % 2 == 0 && n > 1 { out[(n - 1) * outStride] = re[n / 2] }
}

private func unpackCCS1D_D(_ src: UnsafePointer<Double>, _ srcStride: Int, _ n: Int,
                           _ re: UnsafeMutablePointer<Double>, _ im: UnsafeMutablePointer<Double>) {
    re[0] = src[0]; im[0] = 0.0
    let pairs = (n - 1) / 2
    for k in 1...max(pairs, 0) where pairs >= 1 {
        let rv = src[(2 * k - 1) * srcStride], iv = src[(2 * k) * srcStride]
        re[k] = rv; im[k] = iv; re[n - k] = rv; im[n - k] = -iv
    }
    if n % 2 == 0 && n > 1 { re[n / 2] = src[(n - 1) * srcStride]; im[n / 2] = 0.0 }
}

private func packCCS_D(_ re: UnsafePointer<Double>, _ im: UnsafePointer<Double>,
                       _ m: Int, _ n: Int, _ rowsOnly: Bool, _ ccs: UnsafeMutablePointer<Double>) {
    if rowsOnly { for r in 0..<m { packCCS1D_D(re + r * n, im + r * n, n, ccs + r * n, 1) }; return }
    if m == 1 { packCCS1D_D(re, im, n, ccs, 1); return }
    if n == 1 { packCCS1D_D(re, im, m, ccs, 1); return }
    packCCS1D_D(re, im, n, ccs, 1)
    ccs[0] = re[0]
    let rPairs = (m - 1) / 2
    for i in 1...max(rPairs, 0) where rPairs >= 1 { ccs[(2 * i - 1) * n] = re[i * n]; ccs[(2 * i) * n] = im[i * n] }
    if m % 2 == 0 { ccs[(m - 1) * n] = re[(m / 2) * n] }
    if n % 2 == 0 {
        let halfC = n / 2
        ccs[n - 1] = re[halfC]
        for i in 1...max(rPairs, 0) where rPairs >= 1 { ccs[(2 * i - 1) * n + (n - 1)] = re[i * n + halfC]; ccs[(2 * i) * n + (n - 1)] = im[i * n + halfC] }
        if m % 2 == 0 { ccs[(m - 1) * n + (n - 1)] = re[(m / 2) * n + halfC] }
    }
    let cPairs = (n - 1) / 2
    if cPairs >= 1 {
        for i in 1..<m { for j in 1...cPairs { ccs[i * n + 2 * j - 1] = re[i * n + j]; ccs[i * n + 2 * j] = im[i * n + j] } }
    }
}

private func unpackCCS_D(_ ccs: UnsafePointer<Double>, _ m: Int, _ n: Int, _ rowsOnly: Bool,
                         _ re: UnsafeMutablePointer<Double>, _ im: UnsafeMutablePointer<Double>) {
    if rowsOnly { for r in 0..<m { unpackCCS1D_D(ccs + r * n, 1, n, re + r * n, im + r * n) }; return }
    if m == 1 { unpackCCS1D_D(ccs, 1, n, re, im); return }
    if n == 1 { unpackCCS1D_D(ccs, 1, m, re, im); return }
    unpackCCS1D_D(ccs, 1, n, re, im)
    re[0] = ccs[0]; im[0] = 0.0
    let rPairs = (m - 1) / 2
    for i in 1...max(rPairs, 0) where rPairs >= 1 {
        let rv = ccs[(2 * i - 1) * n], iv = ccs[(2 * i) * n]
        re[i * n] = rv; im[i * n] = iv; re[(m - i) * n] = rv; im[(m - i) * n] = -iv
    }
    if m % 2 == 0 { re[(m / 2) * n] = ccs[(m - 1) * n]; im[(m / 2) * n] = 0.0 }
    if n % 2 == 0 {
        let halfC = n / 2
        re[halfC] = ccs[n - 1]; im[halfC] = 0.0
        for i in 1...max(rPairs, 0) where rPairs >= 1 {
            let rv = ccs[(2 * i - 1) * n + (n - 1)], iv = ccs[(2 * i) * n + (n - 1)]
            re[i * n + halfC] = rv; im[i * n + halfC] = iv; re[(m - i) * n + halfC] = rv; im[(m - i) * n + halfC] = -iv
        }
        if m % 2 == 0 { re[(m / 2) * n + halfC] = ccs[(m - 1) * n + (n - 1)]; im[(m / 2) * n + halfC] = 0.0 }
    }
    let cPairs = (n - 1) / 2
    if cPairs >= 1 {
        for i in 1..<m {
            for j in 1...cPairs {
                let rv = ccs[i * n + 2 * j - 1], iv = ccs[i * n + 2 * j]
                re[i * n + j] = rv; im[i * n + j] = iv; re[(m - i) * n + (n - j)] = rv; im[(m - i) * n + (n - j)] = -iv
            }
        }
    }
}

private func packCCS1D_F(_ re: UnsafePointer<Float>, _ im: UnsafePointer<Float>, _ n: Int,
                         _ out: UnsafeMutablePointer<Float>) {
    out[0] = re[0]
    let pairs = (n - 1) / 2
    for k in 1...max(pairs, 0) where pairs >= 1 {
        out[2 * k - 1] = re[k]; out[2 * k] = im[k]
    }
    if n % 2 == 0 && n > 1 { out[n - 1] = re[n / 2] }
}

private func unpackCCS1D_F(_ src: UnsafePointer<Float>, _ n: Int,
                           _ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
    re[0] = src[0]; im[0] = 0.0
    let pairs = (n - 1) / 2
    for k in 1...max(pairs, 0) where pairs >= 1 {
        let rv = src[2 * k - 1], iv = src[2 * k]
        re[k] = rv; im[k] = iv; re[n - k] = rv; im[n - k] = -iv
    }
    if n % 2 == 0 && n > 1 { re[n / 2] = src[n - 1]; im[n / 2] = 0.0 }
}

private func packCCS_F(_ re: UnsafePointer<Float>, _ im: UnsafePointer<Float>,
                       _ m: Int, _ n: Int, _ rowsOnly: Bool, _ ccs: UnsafeMutablePointer<Float>) {
    if rowsOnly { for r in 0..<m { packCCS1D_F(re + r * n, im + r * n, n, ccs + r * n) }; return }
    if m == 1 { packCCS1D_F(re, im, n, ccs); return }
    if n == 1 { packCCS1D_F(re, im, m, ccs); return }
    packCCS1D_F(re, im, n, ccs)
    ccs[0] = re[0]
    let rPairs = (m - 1) / 2
    for i in 1...max(rPairs, 0) where rPairs >= 1 { ccs[(2 * i - 1) * n] = re[i * n]; ccs[(2 * i) * n] = im[i * n] }
    if m % 2 == 0 { ccs[(m - 1) * n] = re[(m / 2) * n] }
    if n % 2 == 0 {
        let halfC = n / 2
        ccs[n - 1] = re[halfC]
        for i in 1...max(rPairs, 0) where rPairs >= 1 { ccs[(2 * i - 1) * n + (n - 1)] = re[i * n + halfC]; ccs[(2 * i) * n + (n - 1)] = im[i * n + halfC] }
        if m % 2 == 0 { ccs[(m - 1) * n + (n - 1)] = re[(m / 2) * n + halfC] }
    }
    let cPairs = (n - 1) / 2
    if cPairs >= 1 {
        for i in 1..<m { for j in 1...cPairs { ccs[i * n + 2 * j - 1] = re[i * n + j]; ccs[i * n + 2 * j] = im[i * n + j] } }
    }
}

private func unpackCCS_F(_ ccs: UnsafePointer<Float>, _ m: Int, _ n: Int, _ rowsOnly: Bool,
                         _ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
    if rowsOnly { for r in 0..<m { unpackCCS1D_F(ccs + r * n, n, re + r * n, im + r * n) }; return }
    if m == 1 { unpackCCS1D_F(ccs, n, re, im); return }
    if n == 1 { unpackCCS1D_F(ccs, m, re, im); return }
    unpackCCS1D_F(ccs, n, re, im)
    re[0] = ccs[0]; im[0] = 0.0
    let rPairs = (m - 1) / 2
    for i in 1...max(rPairs, 0) where rPairs >= 1 {
        let rv = ccs[(2 * i - 1) * n], iv = ccs[(2 * i) * n]
        re[i * n] = rv; im[i * n] = iv; re[(m - i) * n] = rv; im[(m - i) * n] = -iv
    }
    if m % 2 == 0 { re[(m / 2) * n] = ccs[(m - 1) * n]; im[(m / 2) * n] = 0.0 }
    if n % 2 == 0 {
        let halfC = n / 2
        re[halfC] = ccs[n - 1]; im[halfC] = 0.0
        for i in 1...max(rPairs, 0) where rPairs >= 1 {
            let rv = ccs[(2 * i - 1) * n + (n - 1)], iv = ccs[(2 * i) * n + (n - 1)]
            re[i * n + halfC] = rv; im[i * n + halfC] = iv; re[(m - i) * n + halfC] = rv; im[(m - i) * n + halfC] = -iv
        }
        if m % 2 == 0 { re[(m / 2) * n + halfC] = ccs[(m - 1) * n + (n - 1)]; im[(m / 2) * n + halfC] = 0.0 }
    }
    let cPairs = (n - 1) / 2
    if cPairs >= 1 {
        for i in 1..<m {
            for j in 1...cPairs {
                let rv = ccs[i * n + 2 * j - 1], iv = ccs[i * n + 2 * j]
                re[i * n + j] = rv; im[i * n + j] = iv; re[(m - i) * n + (n - j)] = rv; im[(m - i) * n + (n - j)] = -iv
            }
        }
    }
}

// MARK: - C ABI: dft / mulSpectrums / dct

private func readRealRowMajorD(_ m: CoreMat, _ dst: UnsafeMutablePointer<Double>) {
    for r in 0..<m.rows { memcpy(dst + r * m.cols, m.row(r), m.cols * 8) }
}
private func writeRealRowMajorD(_ src: UnsafePointer<Double>, _ m: CoreMat) {
    for r in 0..<m.rows { memcpy(m.row(r), src + r * m.cols, m.cols * 8) }
}
private func readRealRowMajorF(_ m: CoreMat, _ dst: UnsafeMutablePointer<Float>) {
    for r in 0..<m.rows { memcpy(dst + r * m.cols, m.row(r), m.cols * 4) }
}
private func writeRealRowMajorF(_ src: UnsafePointer<Float>, _ m: CoreMat) {
    for r in 0..<m.rows { memcpy(m.row(r), src + r * m.cols, m.cols * 4) }
}

private func readComplexRowMajorD(_ m: CoreMat, _ re: UnsafeMutablePointer<Double>, _ im: UnsafeMutablePointer<Double>) {
    let cols = m.cols
    for r in 0..<m.rows {
        let p = m.row(r).assumingMemoryBound(to: Double.self)
        var sc = DSPDoubleSplitComplex(realp: re + r * cols, imagp: im + r * cols)
        vDSP_ctozD(UnsafePointer<DSPDoubleComplex>(OpaquePointer(p)), 2, &sc, 1, vDSP_Length(cols))
    }
}
private func writeComplexRowMajorD(_ re: UnsafePointer<Double>, _ im: UnsafePointer<Double>, _ m: CoreMat) {
    let cols = m.cols
    for r in 0..<m.rows {
        let p = m.row(r).assumingMemoryBound(to: Double.self)
        var sc = DSPDoubleSplitComplex(realp: UnsafeMutablePointer(mutating: re + r * cols),
                                       imagp: UnsafeMutablePointer(mutating: im + r * cols))
        vDSP_ztocD(&sc, 1, UnsafeMutablePointer<DSPDoubleComplex>(OpaquePointer(p)), 2, vDSP_Length(cols))
    }
}
private func readComplexRowMajorF(_ m: CoreMat, _ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
    let cols = m.cols
    for r in 0..<m.rows {
        let p = m.row(r).assumingMemoryBound(to: Float.self)
        var sc = DSPSplitComplex(realp: re + r * cols, imagp: im + r * cols)
        vDSP_ctoz(UnsafePointer<DSPComplex>(OpaquePointer(p)), 2, &sc, 1, vDSP_Length(cols))
    }
}
private func writeComplexRowMajorF(_ re: UnsafePointer<Float>, _ im: UnsafePointer<Float>, _ m: CoreMat) {
    let cols = m.cols
    for r in 0..<m.rows {
        let p = m.row(r).assumingMemoryBound(to: Float.self)
        var sc = DSPSplitComplex(realp: UnsafeMutablePointer(mutating: re + r * cols),
                                 imagp: UnsafeMutablePointer(mutating: im + r * cols))
        vDSP_ztoc(&sc, 1, UnsafeMutablePointer<DSPComplex>(OpaquePointer(p)), 2, vDSP_Length(cols))
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

    if src.depth == 5 {
        let re = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let im = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { re.deallocate(); im.deallocate() }
        if src.cn == 1 {
            if inv {
                let ccs = UnsafeMutablePointer<Float>.allocate(capacity: count)
                readRealRowMajorF(src, ccs)
                unpackCCS_F(ccs, m, n, rowsOnly, re, im)
                ccs.deallocate()
            } else {
                readRealRowMajorF(src, re)
                im.initialize(repeating: 0.0, count: count)
            }
        } else {
            readComplexRowMajorF(src, re, im)
        }
        fft2D_F(re, im, m, n, inv, rowsOnly)
        if scaleFlag {
            let denom: Float = rowsOnly ? Float(n) : ((m == 1 || n == 1) ? Float(max(m, n)) : Float(m * n))
            var invD: Float = 1.0 / denom
            vDSP_vsmul(re, 1, &invD, re, 1, vDSP_Length(count))
            vDSP_vsmul(im, 1, &invD, im, 1, vDSP_Length(count))
        }
        if dst.cn == 2 || (cplxOut && !realOut) {
            writeComplexRowMajorF(re, im, dst)
        } else if !inv && src.cn == 1 {
            let ccs = UnsafeMutablePointer<Float>.allocate(capacity: count)
            defer { ccs.deallocate() }
            packCCS_F(re, im, m, n, rowsOnly, ccs)
            writeRealRowMajorF(ccs, dst)
        } else {
            writeRealRowMajorF(re, dst)
        }
        return SRStatus.ok
    }

    let re = UnsafeMutablePointer<Double>.allocate(capacity: count)
    let im = UnsafeMutablePointer<Double>.allocate(capacity: count)
    defer { re.deallocate(); im.deallocate() }
    if src.cn == 1 {
        if inv {
            let ccs = UnsafeMutablePointer<Double>.allocate(capacity: count)
            readRealRowMajorD(src, ccs)
            unpackCCS_D(ccs, m, n, rowsOnly, re, im)
            ccs.deallocate()
        } else {
            readRealRowMajorD(src, re)
            im.initialize(repeating: 0.0, count: count)
        }
    } else {
        readComplexRowMajorD(src, re, im)
    }
    fft2D_D(re, im, m, n, inv, rowsOnly)
    if scaleFlag {
        let denom = rowsOnly ? Double(n) : ((m == 1 || n == 1) ? Double(max(m, n)) : Double(m * n))
        var invD = 1.0 / denom
        vDSP_vsmulD(re, 1, &invD, re, 1, vDSP_Length(count))
        vDSP_vsmulD(im, 1, &invD, im, 1, vDSP_Length(count))
    }
    if dst.cn == 2 || (cplxOut && !realOut) {
        writeComplexRowMajorD(re, im, dst)
    } else if !inv && src.cn == 1 {
        let ccs = UnsafeMutablePointer<Double>.allocate(capacity: count)
        defer { ccs.deallocate() }
        packCCS_D(re, im, m, n, rowsOnly, ccs)
        writeRealRowMajorD(ccs, dst)
    } else {
        writeRealRowMajorD(re, dst)
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

    if a.depth == 5 {
        let ar = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let ai = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let br = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let bi = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { ar.deallocate(); ai.deallocate(); br.deallocate(); bi.deallocate() }
        if a.cn == 1 {
            let ta = UnsafeMutablePointer<Float>.allocate(capacity: count)
            let tb = UnsafeMutablePointer<Float>.allocate(capacity: count)
            readRealRowMajorF(a, ta); readRealRowMajorF(b, tb)
            unpackCCS_F(ta, m, n, rowsOnly, ar, ai)
            unpackCCS_F(tb, m, n, rowsOnly, br, bi)
            ta.deallocate(); tb.deallocate()
        } else {
            readComplexRowMajorF(a, ar, ai); readComplexRowMajorF(b, br, bi)
        }
        var sa = DSPSplitComplex(realp: ar, imagp: ai)
        var sb = DSPSplitComplex(realp: br, imagp: bi)
        vDSP_zvmul(&sb, 1, &sa, 1, &sa, 1, vDSP_Length(count), conj ? -1 : 1)
        if a.cn == 1 {
            let tc = UnsafeMutablePointer<Float>.allocate(capacity: count)
            defer { tc.deallocate() }
            packCCS_F(ar, ai, m, n, rowsOnly, tc)
            writeRealRowMajorF(tc, c)
        } else {
            writeComplexRowMajorF(ar, ai, c)
        }
        return SRStatus.ok
    }

    let ar = UnsafeMutablePointer<Double>.allocate(capacity: count)
    let ai = UnsafeMutablePointer<Double>.allocate(capacity: count)
    let br = UnsafeMutablePointer<Double>.allocate(capacity: count)
    let bi = UnsafeMutablePointer<Double>.allocate(capacity: count)
    defer { ar.deallocate(); ai.deallocate(); br.deallocate(); bi.deallocate() }
    if a.cn == 1 {
        let ta = UnsafeMutablePointer<Double>.allocate(capacity: count)
        let tb = UnsafeMutablePointer<Double>.allocate(capacity: count)
        readRealRowMajorD(a, ta); readRealRowMajorD(b, tb)
        unpackCCS_D(ta, m, n, rowsOnly, ar, ai)
        unpackCCS_D(tb, m, n, rowsOnly, br, bi)
        ta.deallocate(); tb.deallocate()
    } else {
        readComplexRowMajorD(a, ar, ai); readComplexRowMajorD(b, br, bi)
    }
    var sa = DSPDoubleSplitComplex(realp: ar, imagp: ai)
    var sb = DSPDoubleSplitComplex(realp: br, imagp: bi)
    vDSP_zvmulD(&sb, 1, &sa, 1, &sa, 1, vDSP_Length(count), conj ? -1 : 1)
    if a.cn == 1 {
        let tc = UnsafeMutablePointer<Double>.allocate(capacity: count)
        defer { tc.deallocate() }
        packCCS_D(ar, ai, m, n, rowsOnly, tc)
        writeRealRowMajorD(tc, c)
    } else {
        writeComplexRowMajorD(ar, ai, c)
    }
    return SRStatus.ok
}

// MARK: - Orthonormal DCT-II / IDCT-II (cached twiddles + hoisted scratch)

private func dct1D_D(_ x: UnsafeMutablePointer<Double>, _ n: Int, _ inverse: Bool,
                     _ re: UnsafeMutablePointer<Double>, _ im: UnsafeMutablePointer<Double>,
                     _ sr: UnsafeMutablePointer<Double>, _ si: UnsafeMutablePointer<Double>, _ tw: DctTwiddleD) {
    if n <= 1 { return }
    let half = n / 2
    let cosT = tw.cosT, sinT = tw.sinT
    if !inverse {
        for k in 0..<half { re[k] = x[2 * k]; re[n - 1 - k] = x[2 * k + 1] }
        im.initialize(repeating: 0.0, count: n)
        fft1D_D(re, im, n, false, sr, si)
        let s0 = 1.0 / sqrt(Double(n))
        let sk = sqrt(2.0 / Double(n))
        x[0] = re[0] * s0
        for k in 1..<n { x[k] = (cosT[k] * re[k] - sinT[k] * im[k]) * sk }
    } else {
        let s0 = sqrt(Double(n))
        let sk = sqrt(Double(n) * 0.5)
        re[0] = x[0] * s0; im[0] = 0.0
        for k in 1..<n {
            let ck = x[k] * sk, cnk = x[n - k] * sk
            let ca = cosT[k], sa = sinT[k]
            re[k] = ck * ca + cnk * sa
            im[k] = ck * sa - cnk * ca
        }
        fft1D_D(re, im, n, true, sr, si)
        let invN = 1.0 / Double(n)
        for k in 0..<half { x[2 * k] = re[k] * invN; x[2 * k + 1] = re[n - 1 - k] * invN }
    }
}

private func dct1D_F(_ x: UnsafeMutablePointer<Float>, _ n: Int, _ inverse: Bool,
                     _ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>,
                     _ sr: UnsafeMutablePointer<Float>, _ si: UnsafeMutablePointer<Float>, _ tw: DctTwiddleF) {
    if n <= 1 { return }
    let half = n / 2
    let cosT = tw.cosT, sinT = tw.sinT
    if !inverse {
        for k in 0..<half { re[k] = x[2 * k]; re[n - 1 - k] = x[2 * k + 1] }
        im.initialize(repeating: 0.0, count: n)
        fft1D_F(re, im, n, false, sr, si)
        let s0 = Float(1.0 / sqrt(Double(n)))
        let sk = Float(sqrt(2.0 / Double(n)))
        x[0] = re[0] * s0
        for k in 1..<n { x[k] = (cosT[k] * re[k] - sinT[k] * im[k]) * sk }
    } else {
        let s0 = Float(sqrt(Double(n)))
        let sk = Float(sqrt(Double(n) * 0.5))
        re[0] = x[0] * s0; im[0] = 0.0
        for k in 1..<n {
            let ck = x[k] * sk, cnk = x[n - k] * sk
            let ca = cosT[k], sa = sinT[k]
            re[k] = ck * ca + cnk * sa
            im[k] = ck * sa - cnk * ca
        }
        fft1D_F(re, im, n, true, sr, si)
        let invN = Float(1.0 / Double(n))
        for k in 0..<half { x[2 * k] = re[k] * invN; x[2 * k + 1] = re[n - 1 - k] * invN }
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

    let Lmax = max((n & (n - 1)) == 0 ? 1 : nextPow2(2 * n - 1),
                   (m & (m - 1)) == 0 ? 1 : nextPow2(2 * m - 1))
    let mx = max(m, n)
    if src.depth == 5 {
        let buf = UnsafeMutablePointer<Float>.allocate(capacity: m * n)
        let re = UnsafeMutablePointer<Float>.allocate(capacity: mx)
        let im = UnsafeMutablePointer<Float>.allocate(capacity: mx)
        let sr = UnsafeMutablePointer<Float>.allocate(capacity: Lmax)
        let si = UnsafeMutablePointer<Float>.allocate(capacity: Lmax)
        defer { buf.deallocate(); re.deallocate(); im.deallocate(); sr.deallocate(); si.deallocate() }
        readRealRowMajorF(src, buf)
        if n > 1 || m == 1 {
            let twN = VDSPSetupCache.shared.dctTwiddleF(n, inv)
            for r in 0..<m { dct1D_F(buf + r * n, n, inv, re, im, sr, si, twN) }
        }
        if !rowsOnly && m > 1 {
            let t = UnsafeMutablePointer<Float>.allocate(capacity: m * n)
            defer { t.deallocate() }
            vDSP_mtrans(buf, 1, t, 1, vDSP_Length(n), vDSP_Length(m))
            let twM = VDSPSetupCache.shared.dctTwiddleF(m, inv)
            for c in 0..<n { dct1D_F(t + c * m, m, inv, re, im, sr, si, twM) }
            vDSP_mtrans(t, 1, buf, 1, vDSP_Length(m), vDSP_Length(n))
        }
        writeRealRowMajorF(buf, dst)
        return SRStatus.ok
    }

    let buf = UnsafeMutablePointer<Double>.allocate(capacity: m * n)
    let re = UnsafeMutablePointer<Double>.allocate(capacity: mx)
    let im = UnsafeMutablePointer<Double>.allocate(capacity: mx)
    let sr = UnsafeMutablePointer<Double>.allocate(capacity: Lmax)
    let si = UnsafeMutablePointer<Double>.allocate(capacity: Lmax)
    defer { buf.deallocate(); re.deallocate(); im.deallocate(); sr.deallocate(); si.deallocate() }
    readRealRowMajorD(src, buf)
    if n > 1 || m == 1 {
        let twN = VDSPSetupCache.shared.dctTwiddleD(n, inv)
        for r in 0..<m { dct1D_D(buf + r * n, n, inv, re, im, sr, si, twN) }
    }
    if !rowsOnly && m > 1 {
        let t = UnsafeMutablePointer<Double>.allocate(capacity: m * n)
        defer { t.deallocate() }
        vDSP_mtransD(buf, 1, t, 1, vDSP_Length(n), vDSP_Length(m))
        let twM = VDSPSetupCache.shared.dctTwiddleD(m, inv)
        for c in 0..<n { dct1D_D(t + c * m, m, inv, re, im, sr, si, twM) }
        vDSP_mtransD(t, 1, buf, 1, vDSP_Length(m), vDSP_Length(n))
    }
    writeRealRowMajorD(buf, dst)
    return SRStatus.ok
}
