// SafariumRaster — Phase 2: linear algebra backed by Apple Accelerate (BLAS / LAPACK / vDSP).
import Foundation
import Accelerate
import SafariumRasterC

// MARK: - Matrix packing & transpose helpers

@inline(__always)
private func laScratch(_ bytes: Int) -> UnsafeMutableRawPointer? {
    bytes > 0 ? UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16) : UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 16)
}

private func packRowsF32(_ m: CoreMat, _ dst: UnsafeMutablePointer<Float>) {
    let cols = m.cols * Int(m.cn)
    for r in 0..<m.rows { memcpy(dst + r * cols, m.row(r), cols * 4) }
}

private func packRowsF64(_ m: CoreMat, _ dst: UnsafeMutablePointer<Double>) {
    let cols = m.cols * Int(m.cn)
    for r in 0..<m.rows { memcpy(dst + r * cols, m.row(r), cols * 8) }
}

private func unpackRowsF32(_ src: UnsafePointer<Float>, _ m: CoreMat) {
    let cols = m.cols * Int(m.cn)
    for r in 0..<m.rows { memcpy(m.row(r), src + r * cols, cols * 4) }
}

private func unpackRowsF64(_ src: UnsafePointer<Double>, _ m: CoreMat) {
    let cols = m.cols * Int(m.cn)
    for r in 0..<m.rows { memcpy(m.row(r), src + r * cols, cols * 8) }
}

private func packColMajorF32(_ m: CoreMat, _ dstCol: UnsafeMutablePointer<Float>) {
    if m.rows == 0 || m.cols == 0 { return }
    let tmp = UnsafeMutablePointer<Float>.allocate(capacity: m.rows * m.cols)
    defer { tmp.deallocate() }
    packRowsF32(m, tmp)
    vDSP_mtrans(tmp, 1, dstCol, 1, vDSP_Length(m.cols), vDSP_Length(m.rows))
}

private func packColMajorF64(_ m: CoreMat, _ dstCol: UnsafeMutablePointer<Double>) {
    if m.rows == 0 || m.cols == 0 { return }
    let tmp = UnsafeMutablePointer<Double>.allocate(capacity: m.rows * m.cols)
    defer { tmp.deallocate() }
    packRowsF64(m, tmp)
    vDSP_mtransD(tmp, 1, dstCol, 1, vDSP_Length(m.cols), vDSP_Length(m.rows))
}

private func unpackColMajorF32(_ srcCol: UnsafePointer<Float>, _ m: CoreMat) {
    if m.rows == 0 || m.cols == 0 { return }
    let tmp = UnsafeMutablePointer<Float>.allocate(capacity: m.rows * m.cols)
    defer { tmp.deallocate() }
    vDSP_mtrans(srcCol, 1, tmp, 1, vDSP_Length(m.rows), vDSP_Length(m.cols))
    unpackRowsF32(tmp, m)
}

private func unpackColMajorF64(_ srcCol: UnsafePointer<Double>, _ m: CoreMat) {
    if m.rows == 0 || m.cols == 0 { return }
    let tmp = UnsafeMutablePointer<Double>.allocate(capacity: m.rows * m.cols)
    defer { tmp.deallocate() }
    vDSP_mtransD(srcCol, 1, tmp, 1, vDSP_Length(m.rows), vDSP_Length(m.cols))
    unpackRowsF64(tmp, m)
}

private func zeroMat(_ m: CoreMat) {
    let rowBytes = m.cols * Int(m.cn) * m.elemSize
    for r in 0..<m.rows { memset(m.row(r), 0, rowBytes) }
}

private func asRowF64(_ m: CoreMat, _ dst: UnsafeMutablePointer<Double>) {
    let n = m.cols * Int(m.cn)
    for r in 0..<m.rows {
        let row = m.row(r)
        if m.depth == 6 {
            memcpy(dst + r * n, row, n * 8)
        } else {
            let p = row.assumingMemoryBound(to: Float.self)
            vDSP_vspdp(p, 1, dst + r * n, 1, vDSP_Length(n))
        }
    }
}

private func storeRowFromF64(_ src: UnsafePointer<Double>, _ m: CoreMat) {
    let n = m.cols * Int(m.cn)
    for r in 0..<m.rows {
        let row = m.row(r)
        if m.depth == 6 {
            memcpy(row, src + r * n, n * 8)
        } else {
            let p = row.assumingMemoryBound(to: Float.self)
            vDSP_vdpsp(src + r * n, 1, p, 1, vDSP_Length(n))
        }
    }
}

// MARK: - GEMM

@_cdecl("sr_la_gemm")
public func sr_la_gemm(_ aP: MatP?, _ bP: MatP?, _ alpha: Double, _ cP: MatP?, _ beta: Double,
                       _ dP: MatP?, _ flags: Int32) -> Int32 {
    guard let a = mat(aP), let b = mat(bP), let d = mat(dP) else { return srFail(SRStatus.badArgument, "gemm: null matrix") }
    guard (a.depth == 5 || a.depth == 6), a.depth == b.depth, a.depth == d.depth,
          (a.cn == 1 || a.cn == 2), a.cn == b.cn, a.cn == d.cn else {
        return srFail(SRStatus.badArgument, "gemm: matrices must have matching float/double 1- or 2-channel type")
    }
    if a.rows == 0 || a.cols == 0 || b.rows == 0 || b.cols == 0 { return SRStatus.ok }
    let tA: Int32 = (flags & 1) != 0 ? 1 : 0
    let tB: Int32 = (flags & 2) != 0 ? 1 : 0
    let tC: Int32 = (flags & 4) != 0 ? 1 : 0
    let m = tA != 0 ? a.cols : a.rows
    let k = tA != 0 ? a.rows : a.cols
    let kb = tB != 0 ? b.cols : b.rows
    let n = tB != 0 ? b.rows : b.cols
    guard kb == k, d.rows == m, d.cols == n else {
        return srFail(SRStatus.badArgument, "gemm: dimension mismatch")
    }

    var actualBeta = beta
    if let c = mat(cP), c.rows > 0, c.cols > 0, beta != 0.0 {
        guard c.depth == a.depth, c.cn == a.cn else { return srFail(SRStatus.badArgument, "gemm: src3 type mismatch") }
        let cm = tC != 0 ? c.cols : c.rows
        let cnCols = tC != 0 ? c.rows : c.cols
        guard cm == m, cnCols == n else { return srFail(SRStatus.badArgument, "gemm: src3 dimension mismatch") }
        let eb = a.elemSize * Int(a.cn)
        if tC == 0 {
            for r in 0..<m { memcpy(d.row(r), c.row(r), n * eb) }
        } else {
            // Transpose C (c.rows x c.cols) into D (m x n) cleanly; supports 1 or 2 channels
            for r in 0..<m {
                let dr = d.row(r)
                for col in 0..<n { memcpy(dr + col * eb, c.row(col) + r * eb, eb) }
            }
        }
    } else {
        actualBeta = 0.0
    }

    let unitBytes = a.elemSize * Int(a.cn)
    let aTight = a.step % unitBytes == 0 && a.step >= a.cols * unitBytes
    let bTight = b.step % unitBytes == 0 && b.step >= b.cols * unitBytes
    let dTight = d.step % unitBytes == 0 && d.step >= d.cols * unitBytes

    var aBuf: UnsafeMutableRawPointer? = nil
    var bBuf: UnsafeMutableRawPointer? = nil
    var dBuf: UnsafeMutableRawPointer? = nil
    defer { aBuf?.deallocate(); bBuf?.deallocate(); dBuf?.deallocate() }

    let aPtr: UnsafeRawPointer
    let lda: Int32
    if aTight {
        aPtr = UnsafeRawPointer(a.data!)
        lda = Int32(a.step / unitBytes)
    } else {
        let buf = UnsafeMutableRawPointer.allocate(byteCount: a.rows * a.cols * unitBytes, alignment: 16)
        aBuf = buf
        for r in 0..<a.rows { memcpy(buf + r * a.cols * unitBytes, a.row(r), a.cols * unitBytes) }
        aPtr = UnsafeRawPointer(buf)
        lda = Int32(a.cols)
    }

    let bPtr: UnsafeRawPointer
    let ldb: Int32
    if bTight {
        bPtr = UnsafeRawPointer(b.data!)
        ldb = Int32(b.step / unitBytes)
    } else {
        let buf = UnsafeMutableRawPointer.allocate(byteCount: b.rows * b.cols * unitBytes, alignment: 16)
        bBuf = buf
        for r in 0..<b.rows { memcpy(buf + r * b.cols * unitBytes, b.row(r), b.cols * unitBytes) }
        bPtr = UnsafeRawPointer(buf)
        ldb = Int32(b.cols)
    }

    let dPtr: UnsafeMutableRawPointer
    let ldc: Int32
    if dTight {
        dPtr = d.data!
        ldc = Int32(d.step / unitBytes)
    } else {
        let buf = UnsafeMutableRawPointer.allocate(byteCount: m * n * unitBytes, alignment: 16)
        dBuf = buf
        for r in 0..<m { memcpy(buf + r * n * unitBytes, d.row(r), n * unitBytes) }
        dPtr = buf
        ldc = Int32(n)
    }

    if a.cn == 1 {
        if a.depth == 5 {
            _ = sr_c_gemm_f32(tA, tB, Int32(m), Int32(n), Int32(k), Float(alpha),
                              aPtr.assumingMemoryBound(to: Float.self), lda,
                              bPtr.assumingMemoryBound(to: Float.self), ldb, Float(actualBeta),
                              dPtr.assumingMemoryBound(to: Float.self), ldc)
        } else {
            _ = sr_c_gemm_f64(tA, tB, Int32(m), Int32(n), Int32(k), alpha,
                              aPtr.assumingMemoryBound(to: Double.self), lda,
                              bPtr.assumingMemoryBound(to: Double.self), ldb, actualBeta,
                              dPtr.assumingMemoryBound(to: Double.self), ldc)
        }
    } else {
        if a.depth == 5 {
            _ = sr_c_gemm_c32(tA, tB, Int32(m), Int32(n), Int32(k), Float(alpha),
                              aPtr.assumingMemoryBound(to: Float.self), lda,
                              bPtr.assumingMemoryBound(to: Float.self), ldb, Float(actualBeta),
                              dPtr.assumingMemoryBound(to: Float.self), ldc)
        } else {
            _ = sr_c_gemm_c64(tA, tB, Int32(m), Int32(n), Int32(k), alpha,
                              aPtr.assumingMemoryBound(to: Double.self), lda,
                              bPtr.assumingMemoryBound(to: Double.self), ldb, actualBeta,
                              dPtr.assumingMemoryBound(to: Double.self), ldc)
        }
    }

    if !dTight {
        for r in 0..<m { memcpy(d.row(r), dPtr + r * n * unitBytes, n * unitBytes) }
    }
    return SRStatus.ok
}

// MARK: - Determinant

@_cdecl("sr_la_det")
public func sr_la_det(_ aP: MatP?, _ outDet: UnsafeMutablePointer<Double>?) -> Int32 {
    guard let a = mat(aP), let outDet else { return srFail(SRStatus.badArgument, "determinant: null") }
    guard (a.depth == 5 || a.depth == 6), a.cn == 1, a.rows == a.cols, a.rows > 0 else {
        return srFail(SRStatus.badArgument, "determinant: requires non-empty square CV_32FC1 or CV_64FC1 matrix")
    }
    let n = a.rows
    let aCol = UnsafeMutablePointer<Double>.allocate(capacity: n * n)
    let ipiv = UnsafeMutablePointer<Int32>.allocate(capacity: n)
    defer { aCol.deallocate(); ipiv.deallocate() }

    // Transpose into col-major Double; det(A^T) == det(A), so even col-major copy suffices!
    asRowF64(a, aCol)
    let info = sr_c_lu_f64(Int32(n), Int32(n), aCol, ipiv)
    if info > 0 { outDet.pointee = 0.0; return SRStatus.ok }
    if info < 0 { return srFail(SRStatus.internalError, "determinant: LAPACK failure") }
    var det = 1.0
    for i in 0..<n {
        det *= aCol[i * n + i]
        if ipiv[i] != Int32(i + 1) { det = -det }
    }
    outDet.pointee = det
    return SRStatus.ok
}

// MARK: - SVD & SVBackSubst

@_cdecl("sr_la_svd")
public func sr_la_svd(_ aP: MatP?, _ wP: MatP?, _ uP: MatP?, _ vtP: MatP?, _ flags: Int32) -> Int32 {
    guard let a = mat(aP), let w = mat(wP) else { return srFail(SRStatus.badArgument, "SVDecomp: null") }
    guard (a.depth == 5 || a.depth == 6), a.cn == 1, w.depth == a.depth, w.cn == 1 else {
        return srFail(SRStatus.badArgument, "SVDecomp: requires CV_32FC1 or CV_64FC1")
    }
    let m = a.rows, n = a.cols
    if m == 0 || n == 0 { return SRStatus.ok }
    let mn = min(m, n)
    let noUV = (flags & 2) != 0
    let fullUV = (flags & 4) != 0
    let jobz: CChar = noUV ? 78 /* 'N' */ : (fullUV ? 65 /* 'A' */ : 83 /* 'S' */)
    let u = noUV ? nil : mat(uP)
    let vt = noUV ? nil : mat(vtP)
    if !noUV && (u == nil || vt == nil) {
        return srFail(SRStatus.badArgument, "SVDecomp: u/vt output buffers required")
    }
    let uRows = m
    let uCols = fullUV ? m : mn
    let vtRows = fullUV ? n : mn
    let vtCols = n
    guard w.rows * w.cols >= mn else { return srFail(SRStatus.badArgument, "SVDecomp: w size mismatch") }
    if let u, let vt {
        guard u.depth == a.depth, vt.depth == a.depth, u.rows == uRows, u.cols == uCols, vt.rows == vtRows, vt.cols == vtCols else {
            return srFail(SRStatus.badArgument, "SVDecomp: u/vt shape mismatch")
        }
    }

    // Row-major A (m x n) in memory == Col-major A^T (n x m).
    // Calling sgesdd/dgesdd on A^T (rows=n, cols=m) yields:
    //   U_fortran (n x vtRows col-major)  == row-major vt (vtRows x n)!
    //   VT_fortran (uCols x m col-major) == row-major u (m x uCols)!
    if a.depth == 5 {
        let b = UnsafeMutablePointer<Float>.allocate(capacity: m * n)
        let s = UnsafeMutablePointer<Float>.allocate(capacity: mn)
        let uF = UnsafeMutablePointer<Float>.allocate(capacity: noUV ? 1 : vtRows * n)
        let vtF = UnsafeMutablePointer<Float>.allocate(capacity: noUV ? 1 : m * uCols)
        defer { b.deallocate(); s.deallocate(); uF.deallocate(); vtF.deallocate() }
        packRowsF32(a, b)
        let info = sr_c_svd_f32(Int32(n), Int32(m), jobz, b, s, uF, Int32(noUV ? 1 : n), vtF, Int32(noUV ? 1 : uCols))
        guard info == 0 else { return srFail(SRStatus.internalError, "SVDecomp: sgesdd failed") }
        for i in 0..<mn { w.row(i).assumingMemoryBound(to: Float.self)[0] = s[i] }
        if let u, let vt {
            unpackRowsF32(vtF, u)
            unpackRowsF32(uF, vt)
        }
    } else {
        let b = UnsafeMutablePointer<Double>.allocate(capacity: m * n)
        let s = UnsafeMutablePointer<Double>.allocate(capacity: mn)
        let uF = UnsafeMutablePointer<Double>.allocate(capacity: noUV ? 1 : vtRows * n)
        let vtF = UnsafeMutablePointer<Double>.allocate(capacity: noUV ? 1 : m * uCols)
        defer { b.deallocate(); s.deallocate(); uF.deallocate(); vtF.deallocate() }
        packRowsF64(a, b)
        let info = sr_c_svd_f64(Int32(n), Int32(m), jobz, b, s, uF, Int32(noUV ? 1 : n), vtF, Int32(noUV ? 1 : uCols))
        guard info == 0 else { return srFail(SRStatus.internalError, "SVDecomp: dgesdd failed") }
        for i in 0..<mn { w.row(i).assumingMemoryBound(to: Double.self)[0] = s[i] }
        if let u, let vt {
            unpackRowsF64(vtF, u)
            unpackRowsF64(uF, vt)
        }
    }
    return SRStatus.ok
}

private func svdBackSubstDouble(
    _ w: UnsafePointer<Double>, _ uRowMajor: UnsafePointer<Double>, _ vtRowMajor: UnsafePointer<Double>,
    _ rhsRowMajor: UnsafePointer<Double>, _ m: Int, _ n: Int, _ k: Int, _ uCols: Int, _ nrhs: Int,
    _ thresh: Double, _ dstRowMajor: UnsafeMutablePointer<Double>
) {
    // tmp = U[:, :k]^T * rhs  (k x nrhs)
    let tmp = UnsafeMutablePointer<Double>.allocate(capacity: k * nrhs)
    defer { tmp.deallocate() }
    _ = sr_c_gemm_f64(1, 0, Int32(k), Int32(nrhs), Int32(m), 1.0, uRowMajor, Int32(uCols), rhsRowMajor, Int32(nrhs), 0.0, tmp, Int32(nrhs))
    for i in 0..<k {
        let scale = w[i] > thresh ? (1.0 / w[i]) : 0.0
        for c in 0..<nrhs { tmp[i * nrhs + c] *= scale }
    }
    // dst = Vt[:k, :]^T * tmp  (n x nrhs)
    _ = sr_c_gemm_f64(1, 0, Int32(n), Int32(nrhs), Int32(k), 1.0, vtRowMajor, Int32(n), tmp, Int32(nrhs), 0.0, dstRowMajor, Int32(nrhs))
}

@_cdecl("sr_la_sv_backsubst")
public func sr_la_sv_backsubst(_ wP: MatP?, _ uP: MatP?, _ vtP: MatP?, _ rhsP: MatP?, _ dstP: MatP?) -> Int32 {
    guard let w = mat(wP), let u = mat(uP), let vt = mat(vtP), let rhs = mat(rhsP), let dst = mat(dstP) else {
        return srFail(SRStatus.badArgument, "SVBackSubst: null")
    }
    guard (w.depth == 5 || w.depth == 6), u.depth == w.depth, vt.depth == w.depth, rhs.depth == w.depth, dst.depth == w.depth else {
        return srFail(SRStatus.badArgument, "SVBackSubst: type mismatch")
    }
    let m = u.rows, n = vt.cols, k = min(w.rows * w.cols, min(u.cols, vt.rows)), nrhs = rhs.cols
    guard rhs.rows == m, dst.rows == n, dst.cols == nrhs else {
        return srFail(SRStatus.badArgument, "SVBackSubst: dimension mismatch")
    }
    if m == 0 || n == 0 || nrhs == 0 { return SRStatus.ok }
    let wBuf = UnsafeMutablePointer<Double>.allocate(capacity: k)
    let uBuf = UnsafeMutablePointer<Double>.allocate(capacity: m * u.cols)
    let vtBuf = UnsafeMutablePointer<Double>.allocate(capacity: vt.rows * n)
    let rBuf = UnsafeMutablePointer<Double>.allocate(capacity: m * nrhs)
    let dBuf = UnsafeMutablePointer<Double>.allocate(capacity: n * nrhs)
    defer { wBuf.deallocate(); uBuf.deallocate(); vtBuf.deallocate(); rBuf.deallocate(); dBuf.deallocate() }

    if w.depth == 5 {
        for i in 0..<k { wBuf[i] = Double(w.row(i).assumingMemoryBound(to: Float.self)[0]) }
    } else {
        for i in 0..<k { wBuf[i] = w.row(i).assumingMemoryBound(to: Double.self)[0] }
    }
    asRowF64(u, uBuf); asRowF64(vt, vtBuf); asRowF64(rhs, rBuf)
    let eps = w.depth == 5 ? 1e-6 : 1e-12
    let thresh = Double(max(m, n)) * eps * (k > 0 ? wBuf[0] : 0.0)
    svdBackSubstDouble(wBuf, uBuf, vtBuf, rBuf, m, n, k, u.cols, nrhs, thresh, dBuf)
    storeRowFromF64(dBuf, dst)
    return SRStatus.ok
}

// MARK: - Solve & Invert

@_cdecl("sr_la_solve")
public func sr_la_solve(_ aP: MatP?, _ bP: MatP?, _ xP: MatP?, _ flags: Int32, _ outOk: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let a = mat(aP), let b = mat(bP), let x = mat(xP), let outOk else {
        return srFail(SRStatus.badArgument, "solve: null")
    }
    guard (a.depth == 5 || a.depth == 6), a.depth == b.depth, a.depth == x.depth, a.cn == 1, b.cn == 1, x.cn == 1 else {
        return srFail(SRStatus.badArgument, "solve: requires matching float/double matrices")
    }
    let m = a.rows, n = a.cols, nrhs = b.cols
    if m == 0 || n == 0 { outOk.pointee = 1; return SRStatus.ok }
    guard b.rows == m, x.rows == n, x.cols == nrhs else {
        return srFail(SRStatus.badArgument, "solve: dimension mismatch")
    }

    let method = flags & 0xF
    let isNormal = (flags & 16) != 0
    if !isNormal && (method == 0 || method == 2 || method == 3) && m != n {
        return srFail(SRStatus.badArgument, "solve: non-square matrix requires DECOMP_SVD, DECOMP_QR, or DECOMP_NORMAL")
    }

    if isNormal {
        let ata = UnsafeMutablePointer<Double>.allocate(capacity: n * n)
        let atb = UnsafeMutablePointer<Double>.allocate(capacity: n * nrhs)
        let aD = UnsafeMutablePointer<Double>.allocate(capacity: m * n)
        let bD = UnsafeMutablePointer<Double>.allocate(capacity: m * nrhs)
        defer { ata.deallocate(); atb.deallocate(); aD.deallocate(); bD.deallocate() }
        asRowF64(a, aD); asRowF64(b, bD)
        _ = sr_c_gemm_f64(1, 0, Int32(n), Int32(n), Int32(m), 1.0, aD, Int32(n), aD, Int32(n), 0.0, ata, Int32(n))
        _ = sr_c_gemm_f64(1, 0, Int32(n), Int32(nrhs), Int32(m), 1.0, aD, Int32(n), bD, Int32(nrhs), 0.0, atb, Int32(nrhs))
        let aCol = UnsafeMutablePointer<Double>.allocate(capacity: n * n)
        let bCol = UnsafeMutablePointer<Double>.allocate(capacity: n * nrhs)
        defer { aCol.deallocate(); bCol.deallocate() }
        vDSP_mtransD(ata, 1, aCol, 1, vDSP_Length(n), vDSP_Length(n))
        vDSP_mtransD(atb, 1, bCol, 1, vDSP_Length(nrhs), vDSP_Length(n))
        let rc: Int32
        if method == 3 {
            rc = sr_c_solve_chol_f64(Int32(n), Int32(nrhs), aCol, bCol)
        } else if method == 1 {
            let s = UnsafeMutablePointer<Double>.allocate(capacity: n)
            let uF = UnsafeMutablePointer<Double>.allocate(capacity: n * n)
            let vtF = UnsafeMutablePointer<Double>.allocate(capacity: n * n)
            let dst = UnsafeMutablePointer<Double>.allocate(capacity: n * nrhs)
            defer { s.deallocate(); uF.deallocate(); vtF.deallocate(); dst.deallocate() }
            let info = sr_c_svd_f64(Int32(n), Int32(n), 83, ata, s, uF, Int32(n), vtF, Int32(n))
            guard info == 0 else { zeroMat(x); outOk.pointee = 0; return SRStatus.ok }
            let thresh = Double(n) * 1e-12 * s[0]
            svdBackSubstDouble(s, vtF, uF, atb, n, n, n, n, nrhs, thresh, dst)
            storeRowFromF64(dst, x)
            outOk.pointee = 1
            return SRStatus.ok
        } else {
            rc = sr_c_solve_lu_f64(Int32(n), Int32(nrhs), aCol, bCol)
        }
        if rc != 0 { zeroMat(x); outOk.pointee = 0; return SRStatus.ok }
        let xRow = UnsafeMutablePointer<Double>.allocate(capacity: n * nrhs)
        defer { xRow.deallocate() }
        vDSP_mtransD(bCol, 1, xRow, 1, vDSP_Length(n), vDSP_Length(nrhs))
        storeRowFromF64(xRow, x)
        outOk.pointee = 1
        return SRStatus.ok
    }

    if method == 0 {
        if a.depth == 5 {
            let aCol = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
            let bCol = UnsafeMutablePointer<Float>.allocate(capacity: n * nrhs)
            defer { aCol.deallocate(); bCol.deallocate() }
            packColMajorF32(a, aCol); packColMajorF32(b, bCol)
            if sr_c_solve_lu_f32(Int32(n), Int32(nrhs), aCol, bCol) != 0 { zeroMat(x); outOk.pointee = 0; return SRStatus.ok }
            unpackColMajorF32(bCol, x)
        } else {
            let aCol = UnsafeMutablePointer<Double>.allocate(capacity: n * n)
            let bCol = UnsafeMutablePointer<Double>.allocate(capacity: n * nrhs)
            defer { aCol.deallocate(); bCol.deallocate() }
            packColMajorF64(a, aCol); packColMajorF64(b, bCol)
            if sr_c_solve_lu_f64(Int32(n), Int32(nrhs), aCol, bCol) != 0 { zeroMat(x); outOk.pointee = 0; return SRStatus.ok }
            unpackColMajorF64(bCol, x)
        }
        outOk.pointee = 1
        return SRStatus.ok
    }

    if method == 3 {
        if a.depth == 5 {
            let aCol = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
            let bCol = UnsafeMutablePointer<Float>.allocate(capacity: n * nrhs)
            defer { aCol.deallocate(); bCol.deallocate() }
            packColMajorF32(a, aCol); packColMajorF32(b, bCol)
            if sr_c_solve_chol_f32(Int32(n), Int32(nrhs), aCol, bCol) != 0 { zeroMat(x); outOk.pointee = 0; return SRStatus.ok }
            unpackColMajorF32(bCol, x)
        } else {
            let aCol = UnsafeMutablePointer<Double>.allocate(capacity: n * n)
            let bCol = UnsafeMutablePointer<Double>.allocate(capacity: n * nrhs)
            defer { aCol.deallocate(); bCol.deallocate() }
            packColMajorF64(a, aCol); packColMajorF64(b, bCol)
            if sr_c_solve_chol_f64(Int32(n), Int32(nrhs), aCol, bCol) != 0 { zeroMat(x); outOk.pointee = 0; return SRStatus.ok }
            unpackColMajorF64(bCol, x)
        }
        outOk.pointee = 1
        return SRStatus.ok
    }

    if method == 4 {
        let ldb = max(m, n)
        if a.depth == 5 {
            let aCol = UnsafeMutablePointer<Float>.allocate(capacity: m * n)
            let bTmp = UnsafeMutablePointer<Float>.allocate(capacity: m * nrhs)
            let bCol = UnsafeMutablePointer<Float>.allocate(capacity: ldb * nrhs)
            bCol.initialize(repeating: 0, count: ldb * nrhs)
            defer { aCol.deallocate(); bTmp.deallocate(); bCol.deallocate() }
            packColMajorF32(a, aCol); packRowsF32(b, bTmp)
            for c in 0..<nrhs { for r in 0..<m { bCol[c * ldb + r] = bTmp[r * nrhs + c] } }
            if sr_c_solve_qr_f32(Int32(m), Int32(n), Int32(nrhs), aCol, bCol) != 0 { zeroMat(x); outOk.pointee = 0; return SRStatus.ok }
            let xRow = UnsafeMutablePointer<Float>.allocate(capacity: n * nrhs)
            defer { xRow.deallocate() }
            for c in 0..<nrhs { for r in 0..<n { xRow[r * nrhs + c] = bCol[c * ldb + r] } }
            unpackRowsF32(xRow, x)
        } else {
            let aCol = UnsafeMutablePointer<Double>.allocate(capacity: m * n)
            let bTmp = UnsafeMutablePointer<Double>.allocate(capacity: m * nrhs)
            let bCol = UnsafeMutablePointer<Double>.allocate(capacity: ldb * nrhs)
            bCol.initialize(repeating: 0, count: ldb * nrhs)
            defer { aCol.deallocate(); bTmp.deallocate(); bCol.deallocate() }
            packColMajorF64(a, aCol); packRowsF64(b, bTmp)
            for c in 0..<nrhs { for r in 0..<m { bCol[c * ldb + r] = bTmp[r * nrhs + c] } }
            if sr_c_solve_qr_f64(Int32(m), Int32(n), Int32(nrhs), aCol, bCol) != 0 { zeroMat(x); outOk.pointee = 0; return SRStatus.ok }
            let xRow = UnsafeMutablePointer<Double>.allocate(capacity: n * nrhs)
            defer { xRow.deallocate() }
            for c in 0..<nrhs { for r in 0..<n { xRow[r * nrhs + c] = bCol[c * ldb + r] } }
            unpackRowsF64(xRow, x)
        }
        outOk.pointee = 1
        return SRStatus.ok
    }

    if method == 2 {
        // DECOMP_EIG (symmetric matrix A): A = V^T * diag(w) * V => X = V^T * diag(1/w) * V * B
        let aD = UnsafeMutablePointer<Double>.allocate(capacity: n * n)
        let wD = UnsafeMutablePointer<Double>.allocate(capacity: n)
        let bD = UnsafeMutablePointer<Double>.allocate(capacity: n * nrhs)
        let tmp = UnsafeMutablePointer<Double>.allocate(capacity: n * nrhs)
        let xD = UnsafeMutablePointer<Double>.allocate(capacity: n * nrhs)
        defer { aD.deallocate(); wD.deallocate(); bD.deallocate(); tmp.deallocate(); xD.deallocate() }
        asRowF64(a, aD); asRowF64(b, bD)
        guard sr_c_syevd_f64(Int32(n), 1, aD, wD) == 0 else { zeroMat(x); outOk.pointee = 0; return SRStatus.ok }
        // aD rows are eigenvectors
        _ = sr_c_gemm_f64(0, 0, Int32(n), Int32(nrhs), Int32(n), 1.0, aD, Int32(n), bD, Int32(nrhs), 0.0, tmp, Int32(nrhs))
        let maxW = max(abs(wD[0]), abs(wD[n - 1]))
        let thresh = Double(n) * (a.depth == 5 ? 1e-6 : 1e-12) * maxW
        for i in 0..<n {
            let s = abs(wD[i]) > thresh ? 1.0 / wD[i] : 0.0
            for c in 0..<nrhs { tmp[i * nrhs + c] *= s }
        }
        _ = sr_c_gemm_f64(1, 0, Int32(n), Int32(nrhs), Int32(n), 1.0, aD, Int32(n), tmp, Int32(nrhs), 0.0, xD, Int32(nrhs))
        storeRowFromF64(xD, x)
        outOk.pointee = 1
        return SRStatus.ok
    }

    // DECOMP_SVD (method == 1 or fallback)
    let k = min(m, n)
    let aD = UnsafeMutablePointer<Double>.allocate(capacity: m * n)
    let bD = UnsafeMutablePointer<Double>.allocate(capacity: m * nrhs)
    let sD = UnsafeMutablePointer<Double>.allocate(capacity: k)
    let uF = UnsafeMutablePointer<Double>.allocate(capacity: k * n)   // row-major vt (k x n)
    let vtF = UnsafeMutablePointer<Double>.allocate(capacity: m * k)  // row-major u  (m x k)
    let xD = UnsafeMutablePointer<Double>.allocate(capacity: n * nrhs)
    defer { aD.deallocate(); bD.deallocate(); sD.deallocate(); uF.deallocate(); vtF.deallocate(); xD.deallocate() }
    asRowF64(a, aD); asRowF64(b, bD)
    guard sr_c_svd_f64(Int32(n), Int32(m), 83, aD, sD, uF, Int32(n), vtF, Int32(k)) == 0 else {
        zeroMat(x); outOk.pointee = 0; return SRStatus.ok
    }
    let eps = a.depth == 5 ? 1e-6 : 1e-12
    let thresh = Double(max(m, n)) * eps * sD[0]
    svdBackSubstDouble(sD, vtF, uF, bD, m, n, k, k, nrhs, thresh, xD)
    storeRowFromF64(xD, x)
    outOk.pointee = 1
    return SRStatus.ok
}

@_cdecl("sr_la_invert")
public func sr_la_invert(_ aP: MatP?, _ invP: MatP?, _ flags: Int32, _ outRet: UnsafeMutablePointer<Double>?) -> Int32 {
    guard let a = mat(aP), let inv = mat(invP), let outRet else { return srFail(SRStatus.badArgument, "invert: null") }
    guard (a.depth == 5 || a.depth == 6), a.depth == inv.depth, a.cn == 1, inv.cn == 1, a.rows > 0, a.cols > 0 else {
        return srFail(SRStatus.badArgument, "invert: requires non-empty float/double matrix")
    }
    let m = a.rows, n = a.cols
    guard inv.rows == n, inv.cols == m else { return srFail(SRStatus.badArgument, "invert: output shape must be (cols, rows)") }
    let method = flags & 0xF
    if (method == 0 || method == 3) && m != n {
        return srFail(SRStatus.badArgument, "invert: LU/CHOLESKY require square matrix")
    }
    if method == 0 {
        if a.depth == 5 {
            let c = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
            defer { c.deallocate() }
            packColMajorF32(a, c)
            if sr_c_invert_lu_f32(Int32(n), c) != 0 { zeroMat(inv); outRet.pointee = 0.0; return SRStatus.ok }
            unpackColMajorF32(c, inv)
        } else {
            let c = UnsafeMutablePointer<Double>.allocate(capacity: n * n)
            defer { c.deallocate() }
            packColMajorF64(a, c)
            if sr_c_invert_lu_f64(Int32(n), c) != 0 { zeroMat(inv); outRet.pointee = 0.0; return SRStatus.ok }
            unpackColMajorF64(c, inv)
        }
        outRet.pointee = 1.0
        return SRStatus.ok
    }
    if method == 3 {
        if a.depth == 5 {
            let c = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
            defer { c.deallocate() }
            packColMajorF32(a, c)
            if sr_c_invert_chol_f32(Int32(n), c) != 0 { zeroMat(inv); outRet.pointee = 0.0; return SRStatus.ok }
            unpackColMajorF32(c, inv)
        } else {
            let c = UnsafeMutablePointer<Double>.allocate(capacity: n * n)
            defer { c.deallocate() }
            packColMajorF64(a, c)
            if sr_c_invert_chol_f64(Int32(n), c) != 0 { zeroMat(inv); outRet.pointee = 0.0; return SRStatus.ok }
            unpackColMajorF64(c, inv)
        }
        outRet.pointee = 1.0
        return SRStatus.ok
    }

    // DECOMP_SVD: A = U * S * Vt  =>  pinv(A) = V * S^+ * U^T  (n x m)
    let k = min(m, n)
    let aD = UnsafeMutablePointer<Double>.allocate(capacity: m * n)
    let sD = UnsafeMutablePointer<Double>.allocate(capacity: k)
    let vtD = UnsafeMutablePointer<Double>.allocate(capacity: k * n)   // U_fortran
    let uD = UnsafeMutablePointer<Double>.allocate(capacity: m * k)    // VT_fortran
    let invD = UnsafeMutablePointer<Double>.allocate(capacity: n * m)
    defer { aD.deallocate(); sD.deallocate(); vtD.deallocate(); uD.deallocate(); invD.deallocate() }
    asRowF64(a, aD)
    guard sr_c_svd_f64(Int32(n), Int32(m), 83, aD, sD, vtD, Int32(n), uD, Int32(k)) == 0 else {
        zeroMat(inv); outRet.pointee = 0.0; return SRStatus.ok
    }
    let eps = a.depth == 5 ? Double(Float.ulpOfOne) : Double.ulpOfOne
    let smax = sD[0], smin = sD[k - 1]
    let thresh = Double(max(m, n)) * eps * smax
    if smax <= 0 {
        zeroMat(inv); outRet.pointee = 0.0; return SRStatus.ok
    }
    for i in 0..<k {
        let sc = sD[i] > thresh ? (1.0 / sD[i]) : 0.0
        for c in 0..<n { vtD[i * n + c] *= sc }
    }
    _ = sr_c_gemm_f64(1, 1, Int32(n), Int32(m), Int32(k), 1.0, vtD, Int32(n), uD, Int32(k), 0.0, invD, Int32(m))
    storeRowFromF64(invD, inv)
    outRet.pointee = smin <= thresh ? 0.0 : (smin / smax)
    return SRStatus.ok
}

// MARK: - Eigenvalues / Eigenvectors

@_cdecl("sr_la_eigen")
public func sr_la_eigen(_ aP: MatP?, _ valsP: MatP?, _ vecsP: MatP?) -> Int32 {
    guard let a = mat(aP), let vals = mat(valsP) else { return srFail(SRStatus.badArgument, "eigen: null") }
    guard (a.depth == 5 || a.depth == 6), a.cn == 1, a.rows == a.cols, a.rows > 0, vals.depth == a.depth else {
        return srFail(SRStatus.badArgument, "eigen: requires square CV_32FC1 or CV_64FC1")
    }
    let n = a.rows
    let vecs = mat(vecsP)
    let wantV: Int32 = vecs != nil ? 1 : 0
    if let vecs {
        guard vecs.depth == a.depth, vecs.rows == n, vecs.cols == n else {
            return srFail(SRStatus.badArgument, "eigen: eigenvectors shape mismatch")
        }
    }
    if a.depth == 5 {
        let matBuf = UnsafeMutablePointer<Float>.allocate(capacity: n * n)
        let wBuf = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { matBuf.deallocate(); wBuf.deallocate() }
        packRowsF32(a, matBuf)
        guard sr_c_syevd_f32(Int32(n), wantV, matBuf, wBuf) == 0 else { return srFail(SRStatus.internalError, "eigen: ssyevd failed") }
        // ssyevd returns ascending order; OpenCV returns descending order
        for i in 0..<n {
            let srcIdx = n - 1 - i
            vals.row(i).assumingMemoryBound(to: Float.self)[0] = wBuf[srcIdx]
            if let vecs { memcpy(vecs.row(i), matBuf + srcIdx * n, n * 4) }
        }
    } else {
        let matBuf = UnsafeMutablePointer<Double>.allocate(capacity: n * n)
        let wBuf = UnsafeMutablePointer<Double>.allocate(capacity: n)
        defer { matBuf.deallocate(); wBuf.deallocate() }
        packRowsF64(a, matBuf)
        guard sr_c_syevd_f64(Int32(n), wantV, matBuf, wBuf) == 0 else { return srFail(SRStatus.internalError, "eigen: dsyevd failed") }
        for i in 0..<n {
            let srcIdx = n - 1 - i
            vals.row(i).assumingMemoryBound(to: Double.self)[0] = wBuf[srcIdx]
            if let vecs { memcpy(vecs.row(i), matBuf + srcIdx * n, n * 8) }
        }
    }
    return SRStatus.ok
}

@_cdecl("sr_la_eigen_nonsym")
public func sr_la_eigen_nonsym(_ aP: MatP?, _ valsP: MatP?, _ vecsP: MatP?) -> Int32 {
    guard let a = mat(aP), let vals = mat(valsP) else { return srFail(SRStatus.badArgument, "eigenNonSymmetric: null") }
    guard (a.depth == 5 || a.depth == 6), a.cn == 1, a.rows == a.cols, a.rows > 0, vals.depth == a.depth else {
        return srFail(SRStatus.badArgument, "eigenNonSymmetric: requires square CV_32FC1 or CV_64FC1")
    }
    let n = a.rows
    let vecs = mat(vecsP)
    if let vecs {
        guard vecs.depth == a.depth, vecs.rows == n, vecs.cols == n else {
            return srFail(SRStatus.badArgument, "eigenNonSymmetric: eigenvectors shape mismatch")
        }
    }
    let aCol = UnsafeMutablePointer<Double>.allocate(capacity: n * n)
    let wr = UnsafeMutablePointer<Double>.allocate(capacity: n)
    let wi = UnsafeMutablePointer<Double>.allocate(capacity: n)
    let vrCol = UnsafeMutablePointer<Double>.allocate(capacity: n * n)
    defer { aCol.deallocate(); wr.deallocate(); wi.deallocate(); vrCol.deallocate() }
    // Convert row-major to col-major Double
    let tmpR = UnsafeMutablePointer<Double>.allocate(capacity: n * n)
    defer { tmpR.deallocate() }
    asRowF64(a, tmpR)
    vDSP_mtransD(tmpR, 1, aCol, 1, vDSP_Length(n), vDSP_Length(n))
    guard sr_c_geev_f64(Int32(n), 1, aCol, wr, wi, vrCol) == 0 else {
        return srFail(SRStatus.internalError, "eigenNonSymmetric: dgeev failed")
    }
    let order = (0..<n).sorted { wr[$0] > wr[$1] }
    for (outR, idx) in order.enumerated() {
        let ev = wr[idx]
        if a.depth == 5 { vals.row(outR).assumingMemoryBound(to: Float.self)[0] = Float(ev) }
        else { vals.row(outR).assumingMemoryBound(to: Double.self)[0] = ev }
        if let vecs {
            var normSq = 0.0
            for c in 0..<n { let v = vrCol[idx * n + c]; normSq += v * v }
            let invNorm = normSq > 0 ? (1.0 / sqrt(normSq)) : 1.0
            if vecs.depth == 5 {
                let p = vecs.row(outR).assumingMemoryBound(to: Float.self)
                for c in 0..<n { p[c] = Float(vrCol[idx * n + c] * invNorm) }
            } else {
                let p = vecs.row(outR).assumingMemoryBound(to: Double.self)
                for c in 0..<n { p[c] = vrCol[idx * n + c] * invNorm }
            }
        }
    }
    return SRStatus.ok
}

// MARK: - PCA, Covariance, Mahalanobis, k-means, solvePoly

@_cdecl("sr_la_covar")
public func sr_la_covar(_ sampP: MatP?, _ meanP: MatP?, _ covP: MatP?, _ flags: Int32) -> Int32 {
    guard let s = mat(sampP), let m = mat(meanP), let cov = mat(covP) else {
        return srFail(SRStatus.badArgument, "calcCovarMatrix: null")
    }
    guard s.cn == 1, cov.cn == 1, m.cn == 1, s.rows > 0, s.cols > 0,
          (cov.depth == 5 || cov.depth == 6), (m.depth == 5 || m.depth == 6) else {
        return srFail(SRStatus.badArgument, "calcCovarMatrix: unsupported format")
    }
    let rowsAsSamples = (flags & 8) != 0 || (flags & 16) == 0 // COVAR_ROWS=8, COVAR_COLS=16
    let scrambled = (flags & 1) == 0                          // COVAR_NORMAL=1, COVAR_SCRAMBLED=0
    let scaleFlag = (flags & 4) != 0                          // COVAR_SCALE=4
    let useAvg = (flags & 2) != 0                             // COVAR_USE_AVG=2
    let r = s.rows, c = s.cols
    let nsamples = rowsAsSamples ? r : c
    let dim = rowsAsSamples ? c : r
    let covDim = scrambled ? nsamples : dim
    guard cov.rows == covDim, cov.cols == covDim else { return srFail(SRStatus.badArgument, "calcCovarMatrix: covar size mismatch") }

    // Load samples into rows = nsamples, cols = dim in Double (transposing if COVAR_COLS)
    let dBuf = UnsafeMutablePointer<Double>.allocate(capacity: r * c)
    let rawBuf = UnsafeMutablePointer<Double>.allocate(capacity: r * c)
    let meanBuf = UnsafeMutablePointer<Double>.allocate(capacity: dim)
    defer { dBuf.deallocate(); rawBuf.deallocate(); meanBuf.deallocate() }
    for y in 0..<r {
        let row = s.row(y)
        for x in 0..<c {
            let v: Double
            switch s.depth {
            case 0: v = Double(row.assumingMemoryBound(to: UInt8.self)[x])
            case 1: v = Double(row.assumingMemoryBound(to: Int8.self)[x])
            case 2: v = Double(row.assumingMemoryBound(to: UInt16.self)[x])
            case 3: v = Double(row.assumingMemoryBound(to: Int16.self)[x])
            case 4: v = Double(row.assumingMemoryBound(to: Int32.self)[x])
            case 5: v = Double(row.assumingMemoryBound(to: Float.self)[x])
            default: v = row.assumingMemoryBound(to: Double.self)[x]
            }
            rawBuf[y * c + x] = v
        }
    }
    if rowsAsSamples {
        memcpy(dBuf, rawBuf, r * c * 8)
    } else {
        vDSP_mtransD(rawBuf, 1, dBuf, 1, vDSP_Length(c), vDSP_Length(r))
    }

    if useAvg {
        asRowF64(m, meanBuf)
    } else {
        meanBuf.initialize(repeating: 0.0, count: dim)
        for i in 0..<nsamples {
            let row = dBuf + i * dim
            for d in 0..<dim { meanBuf[d] += row[d] }
        }
        let invN = 1.0 / Double(nsamples)
        for d in 0..<dim { meanBuf[d] *= invN }
        storeRowFromF64(meanBuf, m)
    }

    for i in 0..<nsamples {
        let row = dBuf + i * dim
        for d in 0..<dim { row[d] -= meanBuf[d] }
    }

    let covD = UnsafeMutablePointer<Double>.allocate(capacity: covDim * covDim)
    defer { covD.deallocate() }
    let scale = scaleFlag ? (1.0 / Double(nsamples)) : 1.0
    if scrambled {
        // dBuf * dBuf^T  (nsamples x nsamples)
        _ = sr_c_gemm_f64(0, 1, Int32(nsamples), Int32(nsamples), Int32(dim), scale, dBuf, Int32(dim), dBuf, Int32(dim), 0.0, covD, Int32(nsamples))
    } else {
        // dBuf^T * dBuf  (dim x dim)
        _ = sr_c_gemm_f64(1, 0, Int32(dim), Int32(dim), Int32(nsamples), scale, dBuf, Int32(dim), dBuf, Int32(dim), 0.0, covD, Int32(dim))
    }
    storeRowFromF64(covD, cov)
    return SRStatus.ok
}

@_cdecl("sr_la_mahalanobis")
public func sr_la_mahalanobis(_ v1P: MatP?, _ v2P: MatP?, _ icovP: MatP?, _ outDist: UnsafeMutablePointer<Double>?) -> Int32 {
    guard let v1 = mat(v1P), let v2 = mat(v2P), let icov = mat(icovP), let outDist else {
        return srFail(SRStatus.badArgument, "Mahalanobis: null")
    }
    guard (v1.depth == 5 || v1.depth == 6), v1.depth == v2.depth, v1.depth == icov.depth, v1.cn == 1, v2.cn == 1, icov.cn == 1 else {
        return srFail(SRStatus.badArgument, "Mahalanobis: type mismatch")
    }
    let n = v1.rows * v1.cols
    guard v2.rows * v2.cols == n, icov.rows == n, icov.cols == n, n > 0 else {
        return srFail(SRStatus.badArgument, "Mahalanobis: dimension mismatch")
    }
    let d1 = UnsafeMutablePointer<Double>.allocate(capacity: n)
    let d2 = UnsafeMutablePointer<Double>.allocate(capacity: n)
    let matD = UnsafeMutablePointer<Double>.allocate(capacity: n * n)
    let tmp = UnsafeMutablePointer<Double>.allocate(capacity: n)
    defer { d1.deallocate(); d2.deallocate(); matD.deallocate(); tmp.deallocate() }
    asRowF64(v1, d1); asRowF64(v2, d2); asRowF64(icov, matD)
    for i in 0..<n { d1[i] -= d2[i] }
    _ = sr_c_gemm_f64(0, 0, Int32(n), 1, Int32(n), 1.0, matD, Int32(n), d1, 1, 0.0, tmp, 1)
    var acc = 0.0
    vDSP_dotprD(d1, 1, tmp, 1, &acc, vDSP_Length(n))
    outDist.pointee = acc > 0 ? sqrt(acc) : 0.0
    return SRStatus.ok
}

@_cdecl("sr_la_pca")
public func sr_la_pca(_ dataP: MatP?, _ meanP: MatP?, _ vecsP: MatP?, _ valsP: MatP?,
                      _ maxComp: Int32, _ retainedVar: Double, _ useMean: Int32, _ outCount: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let data = mat(dataP), let mean = mat(meanP), let vecs = mat(vecsP), let outCount else {
        return srFail(SRStatus.badArgument, "PCACompute: null")
    }
    guard (data.depth == 5 || data.depth == 6), data.cn == 1, data.rows > 0, data.cols > 0 else {
        return srFail(SRStatus.badArgument, "PCACompute: requires non-empty float/double matrix")
    }
    let n = data.rows, d = data.cols
    let x = UnsafeMutablePointer<Double>.allocate(capacity: n * d)
    let mu = UnsafeMutablePointer<Double>.allocate(capacity: d)
    defer { x.deallocate(); mu.deallocate() }
    asRowF64(data, x)
    if useMean != 0 {
        asRowF64(mean, mu)
    } else {
        mu.initialize(repeating: 0.0, count: d)
        for i in 0..<n { for j in 0..<d { mu[j] += x[i * d + j] } }
        let inv = 1.0 / Double(n)
        for j in 0..<d { mu[j] *= inv }
        storeRowFromF64(mu, mean)
    }
    for i in 0..<n { for j in 0..<d { x[i * d + j] -= mu[j] } }

    // Covariance D^T D / max(n, 1) or centered X SVD for numerical accuracy & eigendecomposition matching OpenCV
    let cov = UnsafeMutablePointer<Double>.allocate(capacity: d * d)
    let evals = UnsafeMutablePointer<Double>.allocate(capacity: d)
    defer { cov.deallocate(); evals.deallocate() }
    let invCovScale = 1.0 / Double(max(n, 1))
    _ = sr_c_gemm_f64(1, 0, Int32(d), Int32(d), Int32(n), invCovScale, x, Int32(d), x, Int32(d), 0.0, cov, Int32(d))
    guard sr_c_syevd_f64(Int32(d), 1, cov, evals) == 0 else { return srFail(SRStatus.internalError, "PCACompute: dsyevd failed") }
    // cov rows hold eigenvectors in ascending eigenvalue order
    let descEvals = (0..<d).map { max(0.0, evals[d - 1 - $0]) }
    let totalCount = min(d, n)
    var keep = totalCount
    if retainedVar > 0 && retainedVar <= 1.0 {
        let totalSum = descEvals.prefix(totalCount).reduce(0.0, +)
        if totalSum > 0 {
            var acc = 0.0
            keep = 0
            for i in 0..<totalCount {
                acc += descEvals[i]
                keep += 1
                if acc / totalSum >= retainedVar { break }
            }
        }
    } else if maxComp > 0 {
        keep = min(Int(maxComp), totalCount)
    }
    keep = max(1, min(keep, vecs.rows))
    outCount.pointee = Int32(keep)

    for i in 0..<keep {
        let srcRow = d - 1 - i
        if let vals = mat(valsP) {
            if vals.depth == 5 { vals.row(i).assumingMemoryBound(to: Float.self)[0] = Float(descEvals[i]) }
            else { vals.row(i).assumingMemoryBound(to: Double.self)[0] = descEvals[i] }
        }
        if vecs.depth == 5 {
            let p = vecs.row(i).assumingMemoryBound(to: Float.self)
            for j in 0..<d { p[j] = Float(cov[srcRow * d + j]) }
        } else {
            let p = vecs.row(i).assumingMemoryBound(to: Double.self)
            for j in 0..<d { p[j] = cov[srcRow * d + j] }
        }
    }
    return SRStatus.ok
}

@_cdecl("sr_la_pca_project")
public func sr_la_pca_project(_ dataP: MatP?, _ meanP: MatP?, _ vecsP: MatP?, _ dstP: MatP?, _ back: Int32) -> Int32 {
    guard let data = mat(dataP), let mean = mat(meanP), let vecs = mat(vecsP), let dst = mat(dstP) else {
        return srFail(SRStatus.badArgument, "PCAProject: null")
    }
    guard (data.depth == 5 || data.depth == 6), data.depth == mean.depth, data.depth == vecs.depth, data.depth == dst.depth else {
        return srFail(SRStatus.badArgument, "PCAProject: type mismatch")
    }
    let n = data.rows, inDim = data.cols, k = vecs.rows, d = vecs.cols
    let xD = UnsafeMutablePointer<Double>.allocate(capacity: n * inDim)
    let muD = UnsafeMutablePointer<Double>.allocate(capacity: d)
    let vD = UnsafeMutablePointer<Double>.allocate(capacity: k * d)
    let resD = UnsafeMutablePointer<Double>.allocate(capacity: n * dst.cols)
    defer { xD.deallocate(); muD.deallocate(); vD.deallocate(); resD.deallocate() }
    asRowF64(data, xD); asRowF64(mean, muD); asRowF64(vecs, vD)
    if back == 0 {
        guard inDim == d, dst.rows == n, dst.cols == k else { return srFail(SRStatus.badArgument, "PCAProject: shape mismatch") }
        for i in 0..<n { for j in 0..<d { xD[i * d + j] -= muD[j] } }
        _ = sr_c_gemm_f64(0, 1, Int32(n), Int32(k), Int32(d), 1.0, xD, Int32(d), vD, Int32(d), 0.0, resD, Int32(k))
    } else {
        guard inDim == k, dst.rows == n, dst.cols == d else { return srFail(SRStatus.badArgument, "PCABackProject: shape mismatch") }
        _ = sr_c_gemm_f64(0, 0, Int32(n), Int32(d), Int32(k), 1.0, xD, Int32(k), vD, Int32(d), 0.0, resD, Int32(d))
        for i in 0..<n { for j in 0..<d { resD[i * d + j] += muD[j] } }
    }
    storeRowFromF64(resD, dst)
    return SRStatus.ok
}

@_cdecl("sr_la_kmeans")
public func sr_la_kmeans(_ ptsP: MatP?, _ k: Int32, _ lblP: MatP?, _ ctrP: MatP?,
                         _ maxIter: Int32, _ eps: Double, _ attempts: Int32, _ flags: Int32,
                         _ outCompact: UnsafeMutablePointer<Double>?) -> Int32 {
    guard let pts = mat(ptsP), let lbl = mat(lblP), let ctr = mat(ctrP), let outCompact else {
        return srFail(SRStatus.badArgument, "kmeans: null")
    }
    let n = pts.rows, dims = pts.cols
    guard pts.depth == 5, pts.cn == 1, lbl.depth == 4, ctr.depth == 5, k > 0, k <= Int32(n), lbl.rows == n, ctr.rows == Int(k), ctr.cols == dims else {
        return srFail(SRStatus.badArgument, "kmeans: invalid arguments or shapes")
    }
    let pBuf = UnsafeMutablePointer<Float>.allocate(capacity: n * dims)
    let lBuf = UnsafeMutablePointer<Int32>.allocate(capacity: n)
    let cBuf = UnsafeMutablePointer<Float>.allocate(capacity: Int(k) * dims)
    defer { pBuf.deallocate(); lBuf.deallocate(); cBuf.deallocate() }
    packRowsF32(pts, pBuf)
    for i in 0..<n { lBuf[i] = lbl.row(i).assumingMemoryBound(to: Int32.self)[0] }
    let ret = sr_c_kmeans_f32(pBuf, Int32(n), Int32(dims), k, maxIter, eps, attempts, flags, lBuf, cBuf)
    guard ret >= 0 else { return srFail(SRStatus.internalError, "kmeans: failed") }
    for i in 0..<n { lbl.row(i).assumingMemoryBound(to: Int32.self)[0] = lBuf[i] }
    unpackRowsF32(cBuf, ctr)
    outCompact.pointee = ret
    return SRStatus.ok
}

@_cdecl("sr_la_solve_poly")
public func sr_la_solve_poly(_ coeffs: UnsafePointer<Double>?, _ count: Int32,
                             _ rootsOut: UnsafeMutablePointer<Double>?, _ outDeg: UnsafeMutablePointer<Int32>?,
                             _ outResid: UnsafeMutablePointer<Double>?) -> Int32 {
    guard let coeffs, let rootsOut, let outDeg, let outResid, count >= 2 else {
        return srFail(SRStatus.badArgument, "solvePoly: requires >= 2 coefficients")
    }
    var deg = Int(count) - 1
    while deg > 0 && coeffs[deg] == 0.0 { deg -= 1 }
    guard deg >= 1 else {
        outDeg.pointee = 0; outResid.pointee = 0.0; return SRStatus.ok
    }
    outDeg.pointee = Int32(deg)
    let c = UnsafeMutablePointer<Double>.allocate(capacity: deg * deg)
    let wr = UnsafeMutablePointer<Double>.allocate(capacity: deg)
    let wi = UnsafeMutablePointer<Double>.allocate(capacity: deg)
    c.initialize(repeating: 0.0, count: deg * deg)
    defer { c.deallocate(); wr.deallocate(); wi.deallocate() }

    // Companion matrix (col-major) for monic polynomial x^deg + a_{deg-1} x^{deg-1} + ... + a_0
    let lead = coeffs[deg]
    for i in 0..<(deg - 1) { c[i * deg + (i + 1)] = 1.0 }
    for i in 0..<deg { c[(deg - 1) * deg + i] = -coeffs[i] / lead }
    guard sr_c_geev_f64(Int32(deg), 0, c, wr, wi, nil) == 0 else {
        return srFail(SRStatus.internalError, "solvePoly: dgeev failed")
    }
    var maxRes = 0.0
    for r in 0..<deg {
        var xr = wr[r], xi = wi[r]
        if abs(xi) < 1e-13 { xi = 0.0 }
        rootsOut[2 * r] = xr
        rootsOut[2 * r + 1] = xi
        // Evaluate complex polynomial residual |p(x)|
        var pr = coeffs[deg], pi = 0.0
        for j in stride(from: deg - 1, through: 0, by: -1) {
            let nr = pr * xr - pi * xi + coeffs[j]
            let ni = pr * xi + pi * xr
            pr = nr; pi = ni
        }
        let mag = hypot(pr, pi)
        if mag > maxRes { maxRes = mag }
    }
    outResid.pointee = maxRes
    return SRStatus.ok
}
