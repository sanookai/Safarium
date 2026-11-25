// SafariumRaster — Phase 11: Calib3D + Stereo (FindHomography, Rodrigues, ProjectPoints, SolvePnP, UndistortMap, StereoBM)
// 100% Apple-native Swift + Accelerate.

import Accelerate
import Foundation

// MARK: - Private Linear Algebra Helpers

private func p11SolveLinear(_ A: inout [Double], _ b: inout [Double], _ n: Int) -> Bool {
    for col in 0..<n {
        var pivot = col
        var maxVal = abs(A[col * n + col])
        for row in (col + 1)..<n {
            let v = abs(A[row * n + col])
            if v > maxVal {
                maxVal = v
                pivot = row
            }
        }
        if maxVal < 1e-13 { return false }
        if pivot != col {
            for k in col..<n {
                let t = A[col * n + k]
                A[col * n + k] = A[pivot * n + k]
                A[pivot * n + k] = t
            }
            let tb = b[col]
            b[col] = b[pivot]
            b[pivot] = tb
        }
        let diag = A[col * n + col]
        for row in (col + 1)..<n {
            let f = A[row * n + col] / diag
            if f == 0 { continue }
            for k in (col + 1)..<n {
                A[row * n + k] -= f * A[col * n + k]
            }
            b[row] -= f * b[col]
        }
    }
    for row in stride(from: n - 1, through: 0, by: -1) {
        var s = b[row]
        for k in (row + 1)..<n {
            s -= A[row * n + k] * b[k]
        }
        b[row] = s / A[row * n + row]
    }
    return true
}

/// Jacobi symmetric eigendecomposition returning eigenvalues and column-major eigenvectors (V[row * n + col]).
private func p11JacobiEigen(_ symA: [Double], _ n: Int) -> ([Double], [Double]) {
    var A = symA
    var V = [Double](repeating: 0, count: n * n)
    for i in 0..<n { V[i * n + i] = 1.0 }

    for _ in 0..<80 {
        var maxOff: Double = 0
        var p = 0
        var q = 1
        for i in 0..<(n - 1) {
            for j in (i + 1)..<n {
                let v = abs(A[i * n + j])
                if v > maxOff {
                    maxOff = v
                    p = i
                    q = j
                }
            }
        }
        if maxOff < 1e-14 { break }

        let app = A[p * n + p]
        let aqq = A[q * n + q]
        let apq = A[p * n + q]
        let tau = (aqq - app) / (2.0 * apq)
        let t: Double
        if tau >= 0 {
            t = 1.0 / (tau + sqrt(1.0 + tau * tau))
        } else {
            t = -1.0 / (-tau + sqrt(1.0 + tau * tau))
        }
        let c = 1.0 / sqrt(1.0 + t * t)
        let s = t * c

        for i in 0..<n {
            if i != p && i != q {
                let aip = A[i * n + p]
                let aiq = A[i * n + q]
                let np = c * aip - s * aiq
                let nq = s * aip + c * aiq
                A[i * n + p] = np
                A[p * n + i] = np
                A[i * n + q] = nq
                A[q * n + i] = nq
            }
        }
        A[p * n + p] = app - t * apq
        A[q * n + q] = aqq + t * apq
        A[p * n + q] = 0
        A[q * n + p] = 0

        for i in 0..<n {
            let vip = V[i * n + p]
            let viq = V[i * n + q]
            V[i * n + p] = c * vip - s * viq
            V[i * n + q] = s * vip + c * viq
        }
    }

    var evals = [Double](repeating: 0, count: n)
    for i in 0..<n { evals[i] = A[i * n + i] }
    return (evals, V)
}

private func p11SmallestEigenvector(_ ata: [Double], _ n: Int) -> [Double] {
    let (evals, V) = p11JacobiEigen(ata, n)
    var minIdx = 0
    var minVal = evals[0]
    for i in 1..<n {
        if evals[i] < minVal {
            minVal = evals[i]
            minIdx = i
        }
    }
    var vec = [Double](repeating: 0, count: n)
    for r in 0..<n { vec[r] = V[r * n + minIdx] }
    return vec
}

private func p11Mat3Mul(_ A: [Double], _ B: [Double]) -> [Double] {
    var C = [Double](repeating: 0, count: 9)
    for r in 0..<3 {
        for c in 0..<3 {
            C[r * 3 + c] = A[r * 3] * B[c] + A[r * 3 + 1] * B[3 + c] + A[r * 3 + 2] * B[6 + c]
        }
    }
    return C
}

private func p11Mat3Det(_ M: [Double]) -> Double {
    let a = M[0] * (M[4] * M[8] - M[5] * M[7])
    let b = M[1] * (M[3] * M[8] - M[5] * M[6])
    let c = M[2] * (M[3] * M[7] - M[4] * M[6])
    return a - b + c
}

private func p11Mat3Inv(_ M: [Double]) -> [Double]? {
    let det = p11Mat3Det(M)
    if abs(det) < 1e-15 { return nil }
    let inv = 1.0 / det
    var R = [Double](repeating: 0, count: 9)
    R[0] = (M[4] * M[8] - M[5] * M[7]) * inv
    R[1] = (M[2] * M[7] - M[1] * M[8]) * inv
    R[2] = (M[1] * M[5] - M[2] * M[4]) * inv
    R[3] = (M[5] * M[6] - M[3] * M[8]) * inv
    R[4] = (M[0] * M[8] - M[2] * M[6]) * inv
    R[5] = (M[2] * M[3] - M[0] * M[5]) * inv
    R[6] = (M[3] * M[7] - M[4] * M[6]) * inv
    R[7] = (M[1] * M[6] - M[0] * M[7]) * inv
    R[8] = (M[0] * M[4] - M[1] * M[3]) * inv
    return R
}

/// Projects a 3x3 matrix M onto the closest proper rotation matrix R in SO(3).
private func p11ClosestRotation(_ M: [Double]) -> [Double] {
    // M^T M = V D V^T -> U = M V D^{-1/2}, R = U V^T
    var mtm = [Double](repeating: 0, count: 9)
    for r in 0..<3 {
        for c in 0..<3 {
            mtm[r * 3 + c] = M[r] * M[c] + M[3 + r] * M[3 + c] + M[6 + r] * M[6 + c]
        }
    }
    let (evals, V) = p11JacobiEigen(mtm, 3)
    var U = [Double](repeating: 0, count: 9)
    for col in 0..<3 {
        let s = sqrt(max(1e-15, evals[col]))
        for row in 0..<3 {
            let mv = M[row * 3] * V[col] + M[row * 3 + 1] * V[3 + col] + M[row * 3 + 2] * V[6 + col]
            U[row * 3 + col] = mv / s
        }
    }
    var Vt = [Double](repeating: 0, count: 9)
    for r in 0..<3 {
        for c in 0..<3 { Vt[r * 3 + c] = V[c * 3 + r] }
    }
    var R = p11Mat3Mul(U, Vt)
    if p11Mat3Det(R) < 0 {
        // Flip smallest singular vector column of U
        var minC = 0
        if evals[1] < evals[minC] { minC = 1 }
        if evals[2] < evals[minC] { minC = 2 }
        for row in 0..<3 { U[row * 3 + minC] = -U[row * 3 + minC] }
        R = p11Mat3Mul(U, Vt)
    }
    return R
}

// MARK: - 1. sr_find_homography (Normalized DLT + RANSAC / LMEDS + LM Refinement)

private func p11Normalize2D(_ pts: [(Double, Double)]) -> ([(Double, Double)], [Double]) {
    let n = pts.count
    var mx: Double = 0
    var my: Double = 0
    for p in pts { mx += p.0; my += p.1 }
    mx /= Double(n)
    my /= Double(n)

    var distSum: Double = 0
    for p in pts {
        let dx = p.0 - mx
        let dy = p.1 - my
        distSum += sqrt(dx * dx + dy * dy)
    }
    let meanDist = distSum / Double(n)
    let scale = meanDist > 1e-12 ? (sqrt(2.0) / meanDist) : 1.0

    var norm: [(Double, Double)] = []
    norm.reserveCapacity(n)
    for p in pts {
        norm.append(((p.0 - mx) * scale, (p.1 - my) * scale))
    }
    let T: [Double] = [
        scale, 0, -scale * mx,
        0, scale, -scale * my,
        0, 0, 1
    ]
    return (norm, T)
}

private func p11ComputeHomographyDLT(_ src: [(Double, Double)], _ dst: [(Double, Double)]) -> [Double]? {
    let n = src.count
    if n < 4 { return nil }
    let (ns, Ts) = p11Normalize2D(src)
    let (nd, Td) = p11Normalize2D(dst)
    guard let TdInv = p11Mat3Inv(Td) else { return nil }

    var ata = [Double](repeating: 0, count: 81)
    var r1 = [Double](repeating: 0, count: 9)
    var r2 = [Double](repeating: 0, count: 9)

    for i in 0..<n {
        let x = ns[i].0, y = ns[i].1
        let u = nd[i].0, v = nd[i].1
        r1[0] = -x; r1[1] = -y; r1[2] = -1; r1[3] = 0; r1[4] = 0; r1[5] = 0; r1[6] = u * x; r1[7] = u * y; r1[8] = u
        r2[0] = 0; r2[1] = 0; r2[2] = 0; r2[3] = -x; r2[4] = -y; r2[5] = -1; r2[6] = v * x; r2[7] = v * y; r2[8] = v
        for a in 0..<9 {
            for b in a..<9 {
                ata[a * 9 + b] += r1[a] * r1[b] + r2[a] * r2[b]
            }
        }
    }
    for a in 0..<9 {
        for b in 0..<a { ata[a * 9 + b] = ata[b * 9 + a] }
    }

    let hVec = p11SmallestEigenvector(ata, 9)
    let H = p11Mat3Mul(p11Mat3Mul(TdInv, hVec), Ts)
    let denom = abs(H[8]) > 1e-12 ? H[8] : 1.0
    var out = [Double](repeating: 0, count: 9)
    for k in 0..<9 { out[k] = H[k] / denom }
    return out
}

private func p11IsCollinear(_ p0: (Double, Double), _ p1: (Double, Double), _ p2: (Double, Double)) -> Bool {
    let area2 = (p1.0 - p0.0) * (p2.1 - p0.1) - (p1.1 - p0.1) * (p2.0 - p0.0)
    return abs(area2) < 1e-6
}

private func p11RefineHomographyLM(_ Hinit: [Double], _ src: [(Double, Double)], _ dst: [(Double, Double)]) -> [Double] {
    var p = [Double](repeating: 0, count: 8)
    let scale = abs(Hinit[8]) > 1e-12 ? Hinit[8] : 1.0
    for k in 0..<8 { p[k] = Hinit[k] / scale }

    func evalErr(_ params: [Double]) -> Double {
        var total: Double = 0
        for i in 0..<src.count {
            let x = src[i].0, y = src[i].1
            let w = params[6] * x + params[7] * y + 1.0
            if abs(w) < 1e-12 { return 1e30 }
            let u = (params[0] * x + params[1] * y + params[2]) / w
            let v = (params[3] * x + params[4] * y + params[5]) / w
            let eu = u - dst[i].0
            let ev = v - dst[i].1
            total += eu * eu + ev * ev
        }
        return total
    }

    var currErr = evalErr(p)
    var lambda: Double = 1e-3

    for _ in 0..<25 {
        var jtj = [Double](repeating: 0, count: 64)
        var jte = [Double](repeating: 0, count: 8)
        var ju = [Double](repeating: 0, count: 8)
        var jv = [Double](repeating: 0, count: 8)

        for i in 0..<src.count {
            let x = src[i].0, y = src[i].1
            let w = p[6] * x + p[7] * y + 1.0
            if abs(w) < 1e-12 { continue }
            let invW = 1.0 / w
            let u = (p[0] * x + p[1] * y + p[2]) * invW
            let v = (p[3] * x + p[4] * y + p[5]) * invW
            let eu = u - dst[i].0
            let ev = v - dst[i].1

            ju[0] = x * invW; ju[1] = y * invW; ju[2] = invW
            ju[3] = 0; ju[4] = 0; ju[5] = 0
            ju[6] = -u * x * invW; ju[7] = -u * y * invW

            jv[0] = 0; jv[1] = 0; jv[2] = 0
            jv[3] = x * invW; jv[4] = y * invW; jv[5] = invW
            jv[6] = -v * x * invW; jv[7] = -v * y * invW

            for r in 0..<8 {
                jte[r] -= ju[r] * eu + jv[r] * ev
                for c in r..<8 {
                    jtj[r * 8 + c] += ju[r] * ju[c] + jv[r] * jv[c]
                }
            }
        }
        for r in 0..<8 {
            for c in 0..<r { jtj[r * 8 + c] = jtj[c * 8 + r] }
            jtj[r * 8 + r] += lambda * max(1.0, jtj[r * 8 + r])
        }

        var rhs = jte
        if !p11SolveLinear(&jtj, &rhs, 8) {
            lambda *= 10.0
            continue
        }
        var cand = p
        var step2: Double = 0
        for k in 0..<8 {
            cand[k] += rhs[k]
            step2 += rhs[k] * rhs[k]
        }
        let newErr = evalErr(cand)
        if newErr < currErr {
            p = cand
            currErr = newErr
            lambda = max(1e-7, lambda * 0.3)
            if step2 < 1e-18 { break }
        } else {
            lambda *= 5.0
        }
    }

    var out = [Double](repeating: 0, count: 9)
    for k in 0..<8 { out[k] = p[k] }
    out[8] = 1.0
    return out
}

@_cdecl("sr_find_homography")
public func sr_find_homography(
    _ srcPts: UnsafePointer<Double>?, _ dstPts: UnsafePointer<Double>?, _ nPts: Int32,
    _ method: Int32, _ ransacReprojThreshold: Double, _ maxIters: Int32, _ confidence: Double,
    _ outH: UnsafeMutablePointer<Double>?, _ outMask: UnsafeMutablePointer<UInt8>?
) -> Int32 {
    let n = Int(nPts)
    guard let srcPts, let dstPts, let outH, n >= 4 else {
        return srFail(SRStatus.badArgument, "sr_find_homography: need at least 4 point pairs")
    }
    var src: [(Double, Double)] = []
    var dst: [(Double, Double)] = []
    src.reserveCapacity(n)
    dst.reserveCapacity(n)
    for i in 0..<n {
        src.append((srcPts[2 * i], srcPts[2 * i + 1]))
        dst.append((dstPts[2 * i], dstPts[2 * i + 1]))
    }

    var bestH: [Double]? = nil
    var bestMask = [UInt8](repeating: 1, count: n)

    if method == 0 || n == 4 {
        bestH = p11ComputeHomographyDLT(src, dst)
        if let h = bestH {
            bestH = p11RefineHomographyLM(h, src, dst)
        }
    } else {
        let isLmeds = (method == 4)
        let thresh2 = ransacReprojThreshold * ransacReprojThreshold
        var limitIters = max(10, Int(maxIters))
        let conf = min(0.9999, max(0.5, confidence))

        var rng: UInt64 = 0x1234_5678_9ABC_DEF1
        func nextIdx() -> Int {
            rng ^= rng << 13
            rng ^= rng >> 7
            rng ^= rng << 17
            return Int(rng % UInt64(n))
        }

        var bestInliers = -1
        var bestErrSum = Double.greatestFiniteMagnitude
        var bestMedian = Double.greatestFiniteMagnitude
        var sampleSrc = [(Double, Double)](repeating: (0, 0), count: 4)
        var sampleDst = [(Double, Double)](repeating: (0, 0), count: 4)
        var errs = [Double](repeating: 0, count: n)

        var iter = 0
        while iter < limitIters {
            iter += 1
            var idxs = (0, 0, 0, 0)
            idxs.0 = nextIdx()
            repeat { idxs.1 = nextIdx() } while idxs.1 == idxs.0
            repeat { idxs.2 = nextIdx() } while idxs.2 == idxs.0 || idxs.2 == idxs.1
            repeat { idxs.3 = nextIdx() } while idxs.3 == idxs.0 || idxs.3 == idxs.1 || idxs.3 == idxs.2

            let s0 = src[idxs.0], s1 = src[idxs.1], s2 = src[idxs.2], s3 = src[idxs.3]
            if p11IsCollinear(s0, s1, s2) || p11IsCollinear(s0, s1, s3) ||
               p11IsCollinear(s0, s2, s3) || p11IsCollinear(s1, s2, s3) {
                continue
            }
            sampleSrc[0] = s0; sampleSrc[1] = s1; sampleSrc[2] = s2; sampleSrc[3] = s3
            sampleDst[0] = dst[idxs.0]; sampleDst[1] = dst[idxs.1]; sampleDst[2] = dst[idxs.2]; sampleDst[3] = dst[idxs.3]

            guard let H = p11ComputeHomographyDLT(sampleSrc, sampleDst) else { continue }

            var inliers = 0
            var errSum: Double = 0
            for i in 0..<n {
                let x = src[i].0, y = src[i].1
                let w = H[6] * x + H[7] * y + H[8]
                if abs(w) < 1e-12 {
                    errs[i] = 1e18
                    continue
                }
                let u = (H[0] * x + H[1] * y + H[2]) / w
                let v = (H[3] * x + H[4] * y + H[5]) / w
                let eu = u - dst[i].0
                let ev = v - dst[i].1
                let e2 = eu * eu + ev * ev
                errs[i] = e2
                if e2 < thresh2 {
                    inliers += 1
                    errSum += e2
                }
            }

            if isLmeds {
                var sorted = errs
                sorted.sort()
                let med = sorted[n / 2]
                if med < bestMedian {
                    bestMedian = med
                    bestH = H
                }
            } else if inliers > bestInliers || (inliers == bestInliers && errSum < bestErrSum) {
                bestInliers = inliers
                bestErrSum = errSum
                bestH = H
                for i in 0..<n { bestMask[i] = errs[i] < thresh2 ? 1 : 0 }
                let ratio = Double(inliers) / Double(n)
                if ratio > 0.05 && ratio < 0.9999 {
                    let pAll = pow(ratio, 4.0)
                    let est = Int(ceil(log(1.0 - conf) / log(max(1e-12, 1.0 - pAll))))
                    if est < limitIters { limitIters = max(iter, est) }
                }
            }
        }

        if isLmeds, let H = bestH {
            let sigma = 1.4826 * (1.0 + 5.0 / Double(max(1, n - 4))) * sqrt(max(0.0, bestMedian))
            let t2 = max(1e-6, (2.5 * sigma) * (2.5 * sigma))
            for i in 0..<n {
                let x = src[i].0, y = src[i].1
                let w = H[6] * x + H[7] * y + H[8]
                if abs(w) < 1e-12 { bestMask[i] = 0; continue }
                let u = (H[0] * x + H[1] * y + H[2]) / w
                let v = (H[3] * x + H[4] * y + H[5]) / w
                let e2 = (u - dst[i].0) * (u - dst[i].0) + (v - dst[i].1) * (v - dst[i].1)
                bestMask[i] = e2 < t2 ? 1 : 0
            }
        }

        // Refit on all inliers
        var inSrc: [(Double, Double)] = []
        var inDst: [(Double, Double)] = []
        for i in 0..<n where bestMask[i] != 0 {
            inSrc.append(src[i])
            inDst.append(dst[i])
        }
        if inSrc.count >= 4, let hRefit = p11ComputeHomographyDLT(inSrc, inDst) {
            bestH = p11RefineHomographyLM(hRefit, inSrc, inDst)
        }
    }

    guard let finalH = bestH else {
        return srFail(SRStatus.internalError, "sr_find_homography: failed to estimate homography")
    }
    for k in 0..<9 { outH[k] = finalH[k] }
    if let outMask {
        for i in 0..<n { outMask[i] = bestMask[i] }
    }
    return SRStatus.ok
}

// MARK: - 2. sr_rodrigues

private func p11RodriguesVecToMat(_ r0: Double, _ r1: Double, _ r2: Double) -> [Double] {
    let theta2 = r0 * r0 + r1 * r1 + r2 * r2
    let theta = sqrt(theta2)
    if theta < 1e-12 {
        return [
            1, -r2, r1,
            r2, 1, -r0,
            -r1, r0, 1
        ]
    }
    let kx = r0 / theta
    let ky = r1 / theta
    let kz = r2 / theta
    let c = cos(theta)
    let s = sin(theta)
    let omc = 1.0 - c
    return [
        c + kx * kx * omc, kx * ky * omc - kz * s, kx * kz * omc + ky * s,
        ky * kx * omc + kz * s, c + ky * ky * omc, ky * kz * omc - kx * s,
        kz * kx * omc - ky * s, kz * ky * omc + kx * s, c + kz * kz * omc
    ]
}

private func p11RodriguesMatToVec(_ R: [Double]) -> (Double, Double, Double) {
    let trace = R[0] + R[4] + R[8]
    let cosTheta = max(-1.0, min(1.0, (trace - 1.0) * 0.5))
    let theta = acos(cosTheta)

    let rx = R[7] - R[5]
    let ry = R[2] - R[6]
    let rz = R[3] - R[1]

    if theta < 1e-8 {
        return (0.5 * rx, 0.5 * ry, 0.5 * rz)
    }
    if abs(Double.pi - theta) < 1e-5 {
        let xx = max(0.0, (R[0] + 1.0) * 0.5)
        let yy = max(0.0, (R[4] + 1.0) * 0.5)
        let zz = max(0.0, (R[8] + 1.0) * 0.5)
        var x = sqrt(xx)
        var y = sqrt(yy)
        var z = sqrt(zz)
        if x >= y && x >= z {
            if R[1] + R[3] < 0 { y = -y }
            if R[2] + R[6] < 0 { z = -z }
        } else if y >= x && y >= z {
            if R[1] + R[3] < 0 { x = -x }
            if R[5] + R[7] < 0 { z = -z }
        } else {
            if R[2] + R[6] < 0 { x = -x }
            if R[5] + R[7] < 0 { y = -y }
        }
        let norm = sqrt(x * x + y * y + z * z)
        if norm > 1e-12 {
            let s = theta / norm
            return (x * s, y * s, z * s)
        }
        return (0, 0, 0)
    }

    let s = theta / (2.0 * sin(theta))
    return (rx * s, ry * s, rz * s)
}

@_cdecl("sr_rodrigues")
public func sr_rodrigues(
    _ src: UnsafePointer<Double>?, _ srcLen: Int32,
    _ dst: UnsafeMutablePointer<Double>?,
    _ jacobian: UnsafeMutablePointer<Double>?
) -> Int32 {
    guard let src, let dst else {
        return srFail(SRStatus.badArgument, "sr_rodrigues: null pointer")
    }
    if srcLen == 3 {
        let R = p11RodriguesVecToMat(src[0], src[1], src[2])
        for k in 0..<9 { dst[k] = R[k] }
        if let jac = jacobian {
            let eps = 1e-7
            for p in 0..<3 {
                var rp = [src[0], src[1], src[2]]
                var rm = rp
                rp[p] += eps
                rm[p] -= eps
                let Rp = p11RodriguesVecToMat(rp[0], rp[1], rp[2])
                let Rm = p11RodriguesVecToMat(rm[0], rm[1], rm[2])
                for k in 0..<9 {
                    jac[p * 9 + k] = (Rp[k] - Rm[k]) / (2.0 * eps)
                }
            }
        }
        return SRStatus.ok
    } else if srcLen == 9 {
        var R = [Double](repeating: 0, count: 9)
        for k in 0..<9 { R[k] = src[k] }
        let v = p11RodriguesMatToVec(R)
        dst[0] = v.0
        dst[1] = v.1
        dst[2] = v.2
        if let jac = jacobian {
            let eps = 1e-7
            for k in 0..<9 {
                var Rp = R
                var Rm = R
                Rp[k] += eps
                Rm[k] -= eps
                let vp = p11RodriguesMatToVec(Rp)
                let vm = p11RodriguesMatToVec(Rm)
                jac[k * 3] = (vp.0 - vm.0) / (2.0 * eps)
                jac[k * 3 + 1] = (vp.1 - vm.1) / (2.0 * eps)
                jac[k * 3 + 2] = (vp.2 - vm.2) / (2.0 * eps)
            }
        }
        return SRStatus.ok
    }
    return srFail(SRStatus.badArgument, "sr_rodrigues: srcLen must be 3 or 9")
}

// MARK: - 3. sr_project_points

private func p11ApplyDistortion(_ x: Double, _ y: Double, _ d: [Double]) -> (Double, Double) {
    if d.isEmpty { return (x, y) }
    let k1 = d.count > 0 ? d[0] : 0
    let k2 = d.count > 1 ? d[1] : 0
    let p1 = d.count > 2 ? d[2] : 0
    let p2 = d.count > 3 ? d[3] : 0
    let k3 = d.count > 4 ? d[4] : 0
    let k4 = d.count > 5 ? d[5] : 0
    let k5 = d.count > 6 ? d[6] : 0
    let k6 = d.count > 7 ? d[7] : 0

    let r2 = x * x + y * y
    let r4 = r2 * r2
    let r6 = r4 * r2
    let num = 1.0 + k1 * r2 + k2 * r4 + k3 * r6
    let den = 1.0 + k4 * r2 + k5 * r4 + k6 * r6
    let radial = abs(den) > 1e-12 ? (num / den) : num

    let x2 = x * x
    let y2 = y * y
    let xy2 = 2.0 * x * y
    let xd = x * radial + p1 * xy2 + p2 * (r2 + 2.0 * x2)
    let yd = y * radial + p1 * (r2 + 2.0 * y2) + p2 * xy2
    return (xd, yd)
}

private func p11UndistortNormPoint(_ xd: Double, _ yd: Double, _ d: [Double]) -> (Double, Double) {
    if d.isEmpty { return (xd, yd) }
    var x = xd
    var y = yd
    let k1 = d.count > 0 ? d[0] : 0
    let k2 = d.count > 1 ? d[1] : 0
    let p1 = d.count > 2 ? d[2] : 0
    let p2 = d.count > 3 ? d[3] : 0
    let k3 = d.count > 4 ? d[4] : 0
    let k4 = d.count > 5 ? d[5] : 0
    let k5 = d.count > 6 ? d[6] : 0
    let k6 = d.count > 7 ? d[7] : 0

    for _ in 0..<15 {
        let r2 = x * x + y * y
        let r4 = r2 * r2
        let r6 = r4 * r2
        let num = 1.0 + k1 * r2 + k2 * r4 + k3 * r6
        let den = 1.0 + k4 * r2 + k5 * r4 + k6 * r6
        let icdist = den / max(1e-12, num)
        let dx = 2.0 * p1 * x * y + p2 * (r2 + 2.0 * x * x)
        let dy = p1 * (r2 + 2.0 * y * y) + 2.0 * p2 * x * y
        let nx = (xd - dx) * icdist
        let ny = (yd - dy) * icdist
        if (nx - x) * (nx - x) + (ny - y) * (ny - y) < 1e-22 {
            x = nx; y = ny
            break
        }
        x = nx; y = ny
    }
    return (x, y)
}

@_cdecl("sr_project_points")
public func sr_project_points(
    _ objPts: UnsafePointer<Double>?, _ nPts: Int32,
    _ rvec: UnsafePointer<Double>?,
    _ tvec: UnsafePointer<Double>?,
    _ K: UnsafePointer<Double>?,
    _ distCoeffs: UnsafePointer<Double>?, _ nDist: Int32,
    _ outImgPts: UnsafeMutablePointer<Double>?
) -> Int32 {
    let n = Int(nPts)
    guard let objPts, let rvec, let tvec, let K, let outImgPts, n >= 0 else {
        return srFail(SRStatus.badArgument, "sr_project_points: invalid arguments")
    }
    if n == 0 { return SRStatus.ok }
    let R = p11RodriguesVecToMat(rvec[0], rvec[1], rvec[2])
    let tx = tvec[0], ty = tvec[1], tz = tvec[2]
    let fx = K[0], skew = K[1], cx = K[2]
    let fy = K[4], cy = K[5]

    var dist: [Double] = []
    if let distCoeffs, nDist > 0 {
        dist = [Double](repeating: 0, count: Int(nDist))
        for i in 0..<Int(nDist) { dist[i] = distCoeffs[i] }
    }

    for i in 0..<n {
        let X = objPts[3 * i]
        let Y = objPts[3 * i + 1]
        let Z = objPts[3 * i + 2]
        let xc = R[0] * X + R[1] * Y + R[2] * Z + tx
        let yc = R[3] * X + R[4] * Y + R[5] * Z + ty
        let zc = R[6] * X + R[7] * Y + R[8] * Z + tz
        let invZ = abs(zc) > 1e-12 ? (1.0 / zc) : 1.0
        let xn = xc * invZ
        let yn = yc * invZ
        let (xd, yd) = p11ApplyDistortion(xn, yn, dist)
        outImgPts[2 * i] = fx * xd + skew * yd + cx
        outImgPts[2 * i + 1] = fy * yd + cy
    }
    return SRStatus.ok
}

// MARK: - 4. sr_solve_pnp (Planar Homography / 3D DLT Init + Levenberg-Marquardt Refinement)

@_cdecl("sr_solve_pnp")
public func sr_solve_pnp(
    _ objPts: UnsafePointer<Double>?, _ imgPts: UnsafePointer<Double>?, _ nPts: Int32,
    _ K: UnsafePointer<Double>?,
    _ distCoeffs: UnsafePointer<Double>?, _ nDist: Int32,
    _ useExtrinsicGuess: Int32,
    _ rvec: UnsafeMutablePointer<Double>?,
    _ tvec: UnsafeMutablePointer<Double>?
) -> Int32 {
    let n = Int(nPts)
    guard let objPts, let imgPts, let K, let rvec, let tvec, n >= 4 else {
        return srFail(SRStatus.badArgument, "sr_solve_pnp: need at least 4 point correspondences")
    }

    let fx = K[0], skew = K[1], cx = K[2]
    let fy = K[4], cy = K[5]
    if abs(fx) < 1e-12 || abs(fy) < 1e-12 {
        return srFail(SRStatus.badArgument, "sr_solve_pnp: degenerate camera matrix K")
    }

    var dist: [Double] = []
    if let distCoeffs, nDist > 0 {
        dist = [Double](repeating: 0, count: Int(nDist))
        for i in 0..<Int(nDist) { dist[i] = distCoeffs[i] }
    }

    var obj = [(Double, Double, Double)]()
    var img = [(Double, Double)]()
    var normImg = [(Double, Double)]()
    obj.reserveCapacity(n)
    img.reserveCapacity(n)
    normImg.reserveCapacity(n)

    var zMin = Double.greatestFiniteMagnitude
    var zMax = -Double.greatestFiniteMagnitude
    var meanX: Double = 0, meanY: Double = 0, meanZ: Double = 0

    for i in 0..<n {
        let X = objPts[3 * i]
        let Y = objPts[3 * i + 1]
        let Z = objPts[3 * i + 2]
        obj.append((X, Y, Z))
        meanX += X; meanY += Y; meanZ += Z
        if Z < zMin { zMin = Z }
        if Z > zMax { zMax = Z }

        let u = imgPts[2 * i]
        let v = imgPts[2 * i + 1]
        img.append((u, v))
        let yd = (v - cy) / fy
        let xd = (u - cx - skew * yd) / fx
        normImg.append(p11UndistortNormPoint(xd, yd, dist))
    }
    meanX /= Double(n); meanY /= Double(n); meanZ /= Double(n)

    var params = [Double](repeating: 0, count: 6)
    if useExtrinsicGuess != 0 {
        params[0] = rvec[0]; params[1] = rvec[1]; params[2] = rvec[2]
        params[3] = tvec[0]; params[4] = tvec[1]; params[5] = tvec[2]
    } else {
        let isPlanar = (zMax - zMin) < 1e-4 || n < 6
        var initOk = false

        if isPlanar {
            var planar2D: [(Double, Double)] = []
            planar2D.reserveCapacity(n)
            for p in obj { planar2D.append((p.0, p.1)) }
            if var H = p11ComputeHomographyDLT(planar2D, normImg) {
                let h1Norm = sqrt(H[0] * H[0] + H[3] * H[3] + H[6] * H[6])
                let h2Norm = sqrt(H[1] * H[1] + H[4] * H[4] + H[7] * H[7])
                let scale = 0.5 * (h1Norm + h2Norm)
                if scale > 1e-12 {
                    if H[8] < 0 {
                        for k in 0..<9 { H[k] = -H[k] }
                    }
                    let r1 = (H[0] / h1Norm, H[3] / h1Norm, H[6] / h1Norm)
                    let r2 = (H[1] / h2Norm, H[4] / h2Norm, H[7] / h2Norm)
                    let r3 = (
                        r1.1 * r2.2 - r1.2 * r2.1,
                        r1.2 * r2.0 - r1.0 * r2.2,
                        r1.0 * r2.1 - r1.1 * r2.0
                    )
                    let Rapprox: [Double] = [
                        r1.0, r2.0, r3.0,
                        r1.1, r2.1, r3.1,
                        r1.2, r2.2, r3.2
                    ]
                    let R = p11ClosestRotation(Rapprox)
                    let rv = p11RodriguesMatToVec(R)
                    let tz0 = H[8] / scale
                    let tx0 = H[2] / scale
                    let ty0 = H[5] / scale
                    // Compensate for constant z0 = meanZ
                    params[0] = rv.0; params[1] = rv.1; params[2] = rv.2
                    params[3] = tx0 - R[2] * meanZ
                    params[4] = ty0 - R[5] * meanZ
                    params[5] = tz0 - R[8] * meanZ
                    initOk = true
                }
            }
        } else {
            // Non-planar 3D DLT on normalized 3D coordinates
            var distSum: Double = 0
            for p in obj {
                let dx = p.0 - meanX, dy = p.1 - meanY, dz = p.2 - meanZ
                distSum += sqrt(dx * dx + dy * dy + dz * dz)
            }
            let s3d = (distSum / Double(n)) > 1e-12 ? (sqrt(3.0) / (distSum / Double(n))) : 1.0

            var ata = [Double](repeating: 0, count: 144)
            var r1 = [Double](repeating: 0, count: 12)
            var r2 = [Double](repeating: 0, count: 12)

            for i in 0..<n {
                let X = (obj[i].0 - meanX) * s3d
                let Y = (obj[i].1 - meanY) * s3d
                let Z = (obj[i].2 - meanZ) * s3d
                let u = normImg[i].0
                let v = normImg[i].1
                r1[0] = X; r1[1] = Y; r1[2] = Z; r1[3] = 1
                r1[4] = 0; r1[5] = 0; r1[6] = 0; r1[7] = 0
                r1[8] = -u * X; r1[9] = -u * Y; r1[10] = -u * Z; r1[11] = -u

                r2[0] = 0; r2[1] = 0; r2[2] = 0; r2[3] = 0
                r2[4] = X; r2[5] = Y; r2[6] = Z; r2[7] = 1
                r2[8] = -v * X; r2[9] = -v * Y; r2[10] = -v * Z; r2[11] = -v

                for a in 0..<12 {
                    for b in a..<12 {
                        ata[a * 12 + b] += r1[a] * r1[b] + r2[a] * r2[b]
                    }
                }
            }
            for a in 0..<12 {
                for b in 0..<a { ata[a * 12 + b] = ata[b * 12 + a] }
            }

            let pVec = p11SmallestEigenvector(ata, 12)
            // Unnormalize P_world = P_norm * T3d
            var M = [Double](repeating: 0, count: 9)
            var tCol = [Double](repeating: 0, count: 3)
            for row in 0..<3 {
                let p0 = pVec[row * 4]
                let p1 = pVec[row * 4 + 1]
                let p2 = pVec[row * 4 + 2]
                let p3 = pVec[row * 4 + 3]
                M[row * 3] = p0 * s3d
                M[row * 3 + 1] = p1 * s3d
                M[row * 3 + 2] = p2 * s3d
                tCol[row] = p3 - s3d * (p0 * meanX + p1 * meanY + p2 * meanZ)
            }

            let detM = p11Mat3Det(M)
            if abs(detM) > 1e-18 {
                let c0 = sqrt(M[0] * M[0] + M[3] * M[3] + M[6] * M[6])
                let c1 = sqrt(M[1] * M[1] + M[4] * M[4] + M[7] * M[7])
                let c2 = sqrt(M[2] * M[2] + M[5] * M[5] + M[8] * M[8])
                let scale = (c0 + c1 + c2) / 3.0
                if scale > 1e-12 {
                    var sign: Double = detM < 0 ? -1.0 : 1.0
                    let avgZ = (M[6] * meanX + M[7] * meanY + M[8] * meanZ + tCol[2]) * sign
                    if avgZ < 0 { sign = -sign }
                    for k in 0..<9 { M[k] *= (sign / scale) }
                    for k in 0..<3 { tCol[k] *= (sign / scale) }
                    let R = p11ClosestRotation(M)
                    let rv = p11RodriguesMatToVec(R)
                    params[0] = rv.0; params[1] = rv.1; params[2] = rv.2
                    params[3] = tCol[0]; params[4] = tCol[1]; params[5] = tCol[2]
                    initOk = true
                }
            }
        }

        if !initOk {
            params = [0, 0, 0, -meanX, -meanY, 5.0 - meanZ]
        }
    }

    // Levenberg-Marquardt nonlinear refinement minimizing pixel reprojection error
    func projectWith(_ prm: [Double], _ outRes: inout [Double]) -> Double {
        let R = p11RodriguesVecToMat(prm[0], prm[1], prm[2])
        let tx = prm[3], ty = prm[4], tz = prm[5]
        var err2: Double = 0
        for i in 0..<n {
            let X = obj[i].0, Y = obj[i].1, Z = obj[i].2
            let xc = R[0] * X + R[1] * Y + R[2] * Z + tx
            let yc = R[3] * X + R[4] * Y + R[5] * Z + ty
            let zc = R[6] * X + R[7] * Y + R[8] * Z + tz
            if abs(zc) < 1e-9 { return 1e30 }
            let invZ = 1.0 / zc
            let (xd, yd) = p11ApplyDistortion(xc * invZ, yc * invZ, dist)
            let u = fx * xd + skew * yd + cx
            let v = fy * yd + cy
            let eu = u - img[i].0
            let ev = v - img[i].1
            outRes[2 * i] = eu
            outRes[2 * i + 1] = ev
            err2 += eu * eu + ev * ev
        }
        return err2
    }

    var res = [Double](repeating: 0, count: 2 * n)
    var resTmp = [Double](repeating: 0, count: 2 * n)
    var currErr = projectWith(params, &res)
    var lambda: Double = 1e-3
    var J = [Double](repeating: 0, count: 2 * n * 6)

    for _ in 0..<60 {
        let eps = 1e-6
        for k in 0..<6 {
            var pPert = params
            pPert[k] += eps
            _ = projectWith(pPert, &resTmp)
            for m in 0..<(2 * n) {
                J[m * 6 + k] = (resTmp[m] - res[m]) / eps
            }
        }

        var jtj = [Double](repeating: 0, count: 36)
        var jte = [Double](repeating: 0, count: 6)
        for m in 0..<(2 * n) {
            let rm = res[m]
            let jOff = m * 6
            for r in 0..<6 {
                let jr = J[jOff + r]
                jte[r] -= jr * rm
                for c in r..<6 {
                    jtj[r * 6 + c] += jr * J[jOff + c]
                }
            }
        }
        for r in 0..<6 {
            for c in 0..<r { jtj[r * 6 + c] = jtj[c * 6 + r] }
            jtj[r * 6 + r] += lambda * max(1.0, jtj[r * 6 + r])
        }

        var step = jte
        if !p11SolveLinear(&jtj, &step, 6) {
            lambda *= 10.0
            continue
        }

        var cand = params
        var step2: Double = 0
        for k in 0..<6 {
            cand[k] += step[k]
            step2 += step[k] * step[k]
        }
        let newErr = projectWith(cand, &resTmp)
        if newErr < currErr {
            params = cand
            res = resTmp
            currErr = newErr
            lambda = max(1e-8, lambda * 0.3)
            if step2 < 1e-18 { break }
        } else {
            lambda *= 5.0
            if lambda > 1e10 { break }
        }
    }

    rvec[0] = params[0]; rvec[1] = params[1]; rvec[2] = params[2]
    tvec[0] = params[3]; tvec[1] = params[4]; tvec[2] = params[5]
    return SRStatus.ok
}

// MARK: - 5. sr_init_undistort_rectify_map

@_cdecl("sr_init_undistort_rectify_map")
public func sr_init_undistort_rectify_map(
    _ K: UnsafePointer<Double>?,
    _ distCoeffs: UnsafePointer<Double>?, _ nDist: Int32,
    _ R: UnsafePointer<Double>?,
    _ newK: UnsafePointer<Double>?,
    _ width: Int32, _ height: Int32,
    _ map1: UnsafeMutablePointer<Float>?,
    _ map2: UnsafeMutablePointer<Float>?
) -> Int32 {
    guard let K, let map1, let map2, width > 0, height > 0 else {
        return srFail(SRStatus.badArgument, "sr_init_undistort_rectify_map: invalid arguments")
    }
    let w = Int(width)
    let h = Int(height)

    var dist: [Double] = []
    if let distCoeffs, nDist > 0 {
        dist = [Double](repeating: 0, count: Int(nDist))
        for i in 0..<Int(nDist) { dist[i] = distCoeffs[i] }
    }

    var nK = [Double](repeating: 0, count: 9)
    if let newK {
        for i in 0..<9 { nK[i] = newK[i] }
    } else {
        for i in 0..<9 { nK[i] = K[i] }
    }

    var rMat: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
    if let R {
        for i in 0..<9 { rMat[i] = R[i] }
    }

    let ar = p11Mat3Mul(nK, rMat)
    guard let invAR = p11Mat3Inv(ar) else {
        return srFail(SRStatus.badArgument, "sr_init_undistort_rectify_map: singular newK * R")
    }

    let fx = K[0], skew = K[1], cx = K[2]
    let fy = K[4], cy = K[5]

    for y in 0..<h {
        let fyCoord = Double(y)
        let rowOff = y * w
        let bx = invAR[1] * fyCoord + invAR[2]
        let by = invAR[4] * fyCoord + invAR[5]
        let bz = invAR[7] * fyCoord + invAR[8]
        for x in 0..<w {
            let fxCoord = Double(x)
            let X = invAR[0] * fxCoord + bx
            let Y = invAR[3] * fxCoord + by
            let Z = invAR[6] * fxCoord + bz
            let invZ = abs(Z) > 1e-12 ? (1.0 / Z) : 1.0
            let (xd, yd) = p11ApplyDistortion(X * invZ, Y * invZ, dist)
            map1[rowOff + x] = Float(fx * xd + skew * yd + cx)
            map2[rowOff + x] = Float(fy * yd + cy)
        }
    }
    return SRStatus.ok
}

// MARK: - 6. sr_stereo_bm (SAD Block Matching with Integral Image + Subpixel Parabolic Refinement)

private func p11ReadGrayU8(_ img: SRImage) -> [UInt8] {
    let w = img.width
    let h = img.height
    let c = img.channels
    var out = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        let row = img.row(y).assumingMemoryBound(to: UInt8.self)
        let off = y * w
        if c == 1 {
            for x in 0..<w { out[off + x] = row[x] }
        } else {
            for x in 0..<w {
                let b = Double(row[x * c])
                let g = Double(row[x * c + 1])
                let r = Double(row[x * c + 2])
                out[off + x] = srSatU8(0.114 * b + 0.587 * g + 0.299 * r)
            }
        }
    }
    return out
}

@_cdecl("sr_stereo_bm")
public func sr_stereo_bm(
    _ leftData: UnsafeMutableRawPointer?, _ lw: Int32, _ lh: Int32, _ ls: Int32, _ lc: Int32, _ ld: Int32,
    _ rightData: UnsafeMutableRawPointer?, _ rw: Int32, _ rh: Int32, _ rs: Int32, _ rc: Int32, _ rd: Int32,
    _ outDisp: UnsafeMutablePointer<Int16>?,
    _ numDisparities: Int32, _ blockSize: Int32, _ minDisparity: Int32, _ uniquenessRatio: Int32
) -> Int32 {
    guard let left = SRImage(leftData, lw, lh, ls, lc, ld),
          let right = SRImage(rightData, rw, rh, rs, rc, rd),
          left.depth == .u8, right.depth == .u8,
          left.width == right.width, left.height == right.height,
          let outDisp else {
        return srFail(SRStatus.badArgument, "sr_stereo_bm: invalid images or output buffer")
    }
    let w = left.width
    let h = left.height
    let nDisp = max(16, Int(numDisparities))
    let bSize = max(5, Int(blockSize) | 1)
    let r = bSize / 2
    let minD = Int(minDisparity)
    let maxD = minD + nDisp
    let uniqRatio = max(0, Int(uniquenessRatio))
    let invalidDisp = Int16((minD - 1) * 16)

    let lGray = p11ReadGrayU8(left)
    let rGray = p11ReadGrayU8(right)

    let n = w * h
    var bestCost = [Int32](repeating: Int32.max, count: n)
    var bestD = [Int32](repeating: Int32(minD - 1), count: n)
    var secondCost = [Int32](repeating: Int32.max, count: n)
    var prevCost = [Int32](repeating: 0, count: n)
    var nextCost = [Int32](repeating: 0, count: n)
    var prevDMatch = [Int32](repeating: Int32.max, count: n)

    // Integral buffer (h + 1) x (w + 1)
    let iw = w + 1
    var integral = [Int32](repeating: 0, count: (h + 1) * iw)
    var prevSad = [Int32](repeating: 0, count: n)
    var currSad = [Int32](repeating: 0, count: n)

    for d in minD..<maxD {
        // Compute absolute difference integral image for disparity d
        for x in 0...w { integral[x] = 0 }
        for y in 0..<h {
            let rowOff = y * w
            let iRow = (y + 1) * iw
            let iPrev = y * iw
            integral[iRow] = 0
            var rowSum: Int32 = 0
            for x in 0..<w {
                let rx = x - d
                let diff: Int32
                if rx >= 0 && rx < w {
                    diff = abs(Int32(lGray[rowOff + x]) - Int32(rGray[rowOff + rx]))
                } else {
                    diff = 255
                }
                rowSum += diff
                integral[iRow + x + 1] = integral[iPrev + x + 1] + rowSum
            }
        }

        // Extract block SAD and update best/second costs
        for y in r..<(h - r) {
            let y0 = y - r
            let y1 = y + r + 1
            let off = y * w
            let iY0 = y0 * iw
            let iY1 = y1 * iw
            let xStart = max(r, r + d)
            let xEnd = min(w - r, w - r + d)
            if xStart >= xEnd { continue }
            for x in xStart..<xEnd {
                let x0 = x - r
                let x1 = x + r + 1
                let sad = integral[iY1 + x1] - integral[iY0 + x1] - integral[iY1 + x0] + integral[iY0 + x0]
                let idx = off + x
                currSad[idx] = sad

                if bestD[idx] == Int32(d - 1) {
                    nextCost[idx] = sad
                }

                if sad < bestCost[idx] {
                    if bestD[idx] < Int32(d - 1) {
                        secondCost[idx] = min(secondCost[idx], bestCost[idx])
                    }
                    bestCost[idx] = sad
                    bestD[idx] = Int32(d)
                    prevCost[idx] = (d > minD) ? prevSad[idx] : sad
                    nextCost[idx] = sad
                    prevDMatch[idx] = sad
                } else if sad < secondCost[idx] && abs(Int32(d) - bestD[idx]) > 1 {
                    secondCost[idx] = sad
                }
            }
        }
        swap(&prevSad, &currSad)
    }

    for y in 0..<h {
        let off = y * w
        for x in 0..<w {
            let idx = off + x
            let d = bestD[idx]
            if d < Int32(minD) || y < r || y >= h - r || x < max(r, r + maxD - 1) || x >= w - r {
                if d < Int32(minD) || y < r || y >= h - r || x < r || x >= w - r {
                    outDisp[idx] = invalidDisp
                    continue
                }
            }
            let cBest = bestCost[idx]
            let cSec = secondCost[idx]
            if uniqRatio > 0 && cSec < Int32.max {
                if Int64(cSec) * 100 < Int64(cBest) * Int64(100 + uniqRatio) {
                    outDisp[idx] = invalidDisp
                    continue
                }
            }

            var sub: Double = Double(d)
            if d > Int32(minD) && d < Int32(maxD - 1) {
                let cPrev = Double(prevCost[idx])
                let cCurr = Double(cBest)
                let cNext = Double(nextCost[idx])
                let denom = cPrev - 2.0 * cCurr + cNext
                if denom > 1e-6 {
                    let delta = max(-0.5, min(0.5, 0.5 * (cPrev - cNext) / denom))
                    sub += delta
                }
            }
            outDisp[idx] = Int16(round(sub * 16.0))
        }
    }
    return SRStatus.ok
}
