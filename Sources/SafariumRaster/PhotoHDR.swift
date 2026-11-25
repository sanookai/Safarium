// SafariumRaster — Phase 8 (`photo` HDR pipeline):
// AlignMTB, CalibrateDebevec, CalibrateRobertson, MergeDebevec, MergeRobertson, MergeMertens,
// Tonemap, TonemapDrago, TonemapReinhard, TonemapMantiuk (using Accelerate vDSP + LAPACK).
import Foundation
import Accelerate

// MARK: - AlignMTB

private func bgrToGrayU8(_ src: SRImage) -> [UInt8] {
    let w = src.width, h = src.height
    var out = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        let row = src.row(y).assumingMemoryBound(to: UInt8.self)
        if src.channels == 1 {
            out.withUnsafeMutableBufferPointer { op in
                _ = memcpy(op.baseAddress! + y * w, row, w)
            }
        } else {
            for x in 0..<w {
                let b = Int(row[x * src.channels + 0])
                let g = Int(row[x * src.channels + 1])
                let r = Int(row[x * src.channels + 2])
                out[y * w + x] = UInt8((b * 3735 + g * 19235 + r * 9798 + 16384) >> 15)
            }
        }
    }
    return out
}

private func computeMTB(_ gray: [UInt8], _ w: Int, _ h: Int, _ excludeRange: Int) -> ([UInt8], [UInt8]) {
    var hist = [Int](repeating: 0, count: 256)
    for v in gray { hist[Int(v)] += 1 }
    let half = (w * h) / 2
    var acc = 0
    var med = 0
    while acc < half && med < 255 {
        acc += hist[med]
        med += 1
    }
    var tb = [UInt8](repeating: 0, count: w * h)
    var eb = [UInt8](repeating: 0, count: w * h)
    for i in 0..<(w * h) {
        let v = Int(gray[i])
        tb[i] = v > med ? 255 : 0
        eb[i] = abs(v - med) <= excludeRange ? 0 : 255
    }
    return (tb, eb)
}

private func downsample2x(_ img: [UInt8], _ w: Int, _ h: Int) -> ([UInt8], Int, Int) {
    let nw = max(1, w / 2), nh = max(1, h / 2)
    var out = [UInt8](repeating: 0, count: nw * nh)
    for y in 0..<nh {
        let sy = min(2 * y, h - 1), sy1 = min(2 * y + 1, h - 1)
        for x in 0..<nw {
            let sx = min(2 * x, w - 1), sx1 = min(2 * x + 1, w - 1)
            let s = Int(img[sy * w + sx]) + Int(img[sy * w + sx1]) + Int(img[sy1 * w + sx]) + Int(img[sy1 * w + sx1])
            out[y * nw + x] = UInt8((s + 2) >> 2)
        }
    }
    return (out, nw, nh)
}

private func calcShiftMTB(_ g0: [UInt8], _ g1: [UInt8], _ w: Int, _ h: Int,
                          _ maxBits: Int, _ excludeRange: Int) -> (Int, Int) {
    let levels = max(1, min(maxBits, Int(floor(log2(Double(max(2, min(w, h))))))))
    var pyr0 = [(g0, w, h)]
    var pyr1 = [(g1, w, h)]
    for _ in 1..<levels {
        let p0 = pyr0.last!
        let p1 = pyr1.last!
        pyr0.append(downsample2x(p0.0, p0.1, p0.2))
        pyr1.append(downsample2x(p1.0, p1.1, p1.2))
    }

    var sx = 0, sy = 0
    for lvl in stride(from: levels - 1, through: 0, by: -1) {
        sx *= 2; sy *= 2
        let (a, lw, lh) = pyr0[lvl]
        let (b, _, _) = pyr1[lvl]
        let (tb0, eb0) = computeMTB(a, lw, lh, excludeRange)
        let (tb1, eb1) = computeMTB(b, lw, lh, excludeRange)

        var bestErr = Int.max
        var bestDx = sx, bestDy = sy
        for dy in -1...1 {
            for dx in -1...1 {
                let cx = sx + dx
                let cy = sy + dy
                // Shift image 1 by (cx, cy): pixel at (y, x) comes from img1(y - cy, x - cx)
                let y0 = max(0, cy), y1 = min(lh, lh + cy)
                let x0 = max(0, cx), x1 = min(lw, lw + cx)
                if x1 <= x0 || y1 <= y0 { continue }
                var err = 0
                for y in y0..<y1 {
                    let sy1 = y - cy
                    for x in x0..<x1 {
                        let sx1 = x - cx
                        let i0 = y * lw + x
                        let i1 = sy1 * lw + sx1
                        if eb0[i0] != 0 && eb1[i1] != 0 && tb0[i0] != tb1[i1] {
                            err += 1
                        }
                    }
                }
                // Normalize slightly to prefer smaller shifts on tie
                if err < bestErr || (err == bestErr && abs(cx) + abs(cy) < abs(bestDx) + abs(bestDy)) {
                    bestErr = err
                    bestDx = cx
                    bestDy = cy
                }
            }
        }
        sx = bestDx; sy = bestDy
    }
    return (sx, sy)
}

@_cdecl("sr_hdr_align_compute_bitmaps")
public func sr_hdr_align_compute_bitmaps(
    _ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
    _ td: UnsafeMutableRawPointer?, _ tw: Int32, _ th: Int32, _ ts: Int32, _ tc: Int32, _ tdep: Int32,
    _ ed: UnsafeMutableRawPointer?, _ ew: Int32, _ eh: Int32, _ es: Int32, _ ec: Int32, _ edep: Int32,
    _ excludeRange: Int32
) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep),
          let tb = SRImage(td, tw, th, ts, tc, tdep),
          let eb = SRImage(ed, ew, eh, es, ec, edep),
          src.depth == .u8, src.channels == 1,
          tb.depth == .u8, tb.channels == 1, eb.depth == .u8, eb.channels == 1,
          src.width == tb.width, src.height == tb.height,
          src.width == eb.width, src.height == eb.height else {
        return srFail(SRStatus.badArgument, "AlignMTB.computeBitmaps: requires 1-ch u8 images")
    }
    let gray = bgrToGrayU8(src)
    let (tArr, eArr) = computeMTB(gray, src.width, src.height, Int(excludeRange))
    for y in 0..<src.height {
        tArr.withUnsafeBufferPointer { tp in _ = memcpy(tb.row(y), tp.baseAddress! + y * src.width, src.width) }
        eArr.withUnsafeBufferPointer { ep in _ = memcpy(eb.row(y), ep.baseAddress! + y * src.width, src.width) }
    }
    return SRStatus.ok
}

@_cdecl("sr_hdr_align_calc_shift")
public func sr_hdr_align_calc_shift(
    _ d0: UnsafeMutableRawPointer?, _ w0: Int32, _ h0: Int32, _ s0: Int32, _ c0: Int32, _ dep0: Int32,
    _ d1: UnsafeMutableRawPointer?, _ w1: Int32, _ h1: Int32, _ s1: Int32, _ c1: Int32, _ dep1: Int32,
    _ maxBits: Int32, _ excludeRange: Int32,
    _ outDx: UnsafeMutablePointer<Int32>?, _ outDy: UnsafeMutablePointer<Int32>?
) -> Int32 {
    guard let img0 = SRImage(d0, w0, h0, s0, c0, dep0),
          let img1 = SRImage(d1, w1, h1, s1, c1, dep1),
          img0.depth == .u8, img1.depth == .u8, img0.channels == 1, img1.channels == 1,
          img0.width == img1.width, img0.height == img1.height,
          let outDx, let outDy else {
        return srFail(SRStatus.badArgument, "AlignMTB.calculateShift: requires matching 1-ch u8 images")
    }
    let g0 = bgrToGrayU8(img0), g1 = bgrToGrayU8(img1)
    let (dx, dy) = calcShiftMTB(g0, g1, img0.width, img0.height, Int(maxBits), Int(excludeRange))
    outDx.pointee = Int32(dx)
    outDy.pointee = Int32(dy)
    return SRStatus.ok
}

@_cdecl("sr_hdr_align_shift_mat")
public func sr_hdr_align_shift_mat(
    _ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
    _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
    _ dx: Int32, _ dy: Int32
) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep),
          let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          src.width == dst.width, src.height == dst.height,
          src.channels == dst.channels, src.depth == dst.depth else {
        return srFail(SRStatus.badArgument, "AlignMTB.shiftMat: shape/type mismatch")
    }
    let w = src.width, h = src.height, pb = src.pixelBytes
    let rowBytes = w * pb
    for y in 0..<h { memset(dst.row(y), 0, rowBytes) }
    let y0 = max(0, Int(dy)), y1 = min(h, h + Int(dy))
    let x0 = max(0, Int(dx)), x1 = min(w, w + Int(dx))
    if x1 <= x0 || y1 <= y0 { return SRStatus.ok }
    let copyBytes = (x1 - x0) * pb
    for y in y0..<y1 {
        let sy = y - Int(dy)
        let sx = x0 - Int(dx)
        memcpy(dst.row(y) + x0 * pb, src.row(sy) + sx * pb, copyBytes)
    }
    return SRStatus.ok
}

// MARK: - CalibrateDebevec (Accelerate LAPACK dgels_)

@_silgen_name("sr_c_dgels")
private func sr_c_dgels(_ m: Int32, _ n: Int32, _ aColMajor: UnsafeMutablePointer<Double>?, _ bVec: UnsafeMutablePointer<Double>?) -> Int32

@_cdecl("sr_hdr_calibrate_debevec")
public func sr_hdr_calibrate_debevec(
    _ framePtrs: UnsafePointer<UnsafeMutableRawPointer?>?, _ frameStrides: UnsafePointer<Int32>?,
    _ nFrames: Int32, _ w: Int32, _ h: Int32, _ ch: Int32,
    _ times: UnsafePointer<Float>?, _ samples: Int32, _ lambdaVal: Double, _ randomSample: Int32,
    _ outCRF: UnsafeMutablePointer<Float>?
) -> Int32 {
    guard let framePtrs, let frameStrides, let times, let outCRF,
          nFrames >= 2, w > 0, h > 0, (ch == 1 || ch == 3), samples >= 1 else {
        return srFail(SRStatus.badArgument, "CalibrateDebevec: invalid arguments")
    }
    let nf = Int(nFrames), wi = Int(w), hi = Int(h), ci = Int(ch)
    var imgs: [SRImage] = []
    imgs.reserveCapacity(nf)
    for i in 0..<nf {
        guard let img = SRImage(framePtrs[i], w, h, frameStrides[i], ch, 0) else {
            return srFail(SRStatus.badArgument, "CalibrateDebevec: all inputs must be u8 of same size")
        }
        imgs.append(img)
    }

    // Build grid or deterministic-PRNG sample coordinates
    var pts: [(Int, Int)] = []
    if randomSample != 0 {
        let pCount = min(Int(samples), wi * hi)
        pts.reserveCapacity(pCount)
        var seed: UInt64 = 0x123456789ABCDEF
        for _ in 0..<pCount {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let px = Int((seed >> 16) % UInt64(wi))
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let py = Int((seed >> 16) % UInt64(hi))
            pts.append((px, py))
        }
    } else {
        let cols = max(1, Int(sqrt(Double(samples) * Double(wi) / Double(hi))))
        let rows = max(1, (Int(samples) + cols - 1) / cols)
        let dx = max(1, wi / cols)
        let dy = max(1, hi / rows)
        for r in 0..<rows {
            let py = min(hi - 1, r * dy + dy / 2)
            for c in 0..<cols {
                if pts.count >= Int(samples) { break }
                let px = min(wi - 1, c * dx + dx / 2)
                pts.append((px, py))
            }
        }
    }
    let P = pts.count
    let Z = 256
    let rows = P * nf + 1 + 254
    let cols = Z + P

    // Hat weights w(z)
    var wLut = [Double](repeating: 0.0, count: Z)
    for z in 0..<Z { wLut[z] = Double(z <= 127 ? z : (255 - z)) }
    let logTimes = (0..<nf).map { log(max(Double(times[$0]), 1e-12)) }

    // Column-major matrix A (rows x cols) and RHS b (rows) for LAPACK dgels_
    var A = [Double](repeating: 0.0, count: rows * cols)
    var b = [Double](repeating: 0.0, count: rows)

    for c in 0..<ci {
        A.withUnsafeMutableBufferPointer { ap in _ = memset(ap.baseAddress!, 0, rows * cols * 8) }
        b.withUnsafeMutableBufferPointer { bp in _ = memset(bp.baseAddress!, 0, rows * 8) }

        var row = 0
        for (pi, (px, py)) in pts.enumerated() {
            for j in 0..<nf {
                let z = Int(imgs[j].row(py).assumingMemoryBound(to: UInt8.self)[px * ci + c])
                let wz = wLut[z]
                A[z * rows + row] = wz
                A[(Z + pi) * rows + row] = -wz
                b[row] = wz * logTimes[j]
                row += 1
            }
        }
        // Unit exposure constraint g(128) = 0
        A[128 * rows + row] = 1.0
        b[row] = 0.0
        row += 1

        // Smoothness constraint
        for z in 1..<255 {
            let wz = lambdaVal * wLut[z]
            A[(z - 1) * rows + row] = wz
            A[z * rows + row] = -2.0 * wz
            A[(z + 1) * rows + row] = wz
            row += 1
        }

        let info = A.withUnsafeMutableBufferPointer { ap in
            b.withUnsafeMutableBufferPointer { bp in
                sr_c_dgels(Int32(rows), Int32(cols), ap.baseAddress!, bp.baseAddress!)
            }
        }

        for z in 0..<Z {
            let g = (info == 0) ? min(20.0, max(-20.0, b[z])) : log(max(Double(z), 0.5) / 128.0)
            outCRF[z * ci + c] = Float(exp(g))
        }
    }
    return SRStatus.ok
}

// MARK: - CalibrateRobertson

@inline(__always)
private func robertsonWeight(_ z: Int) -> Double {
    let shift = 127.5
    let q = (Double(z) - shift) / shift
    let w = exp(-4.0 * q * q)
    let edge = exp(-4.0)
    return max(0.0, w - edge)
}

@_cdecl("sr_hdr_calibrate_robertson")
public func sr_hdr_calibrate_robertson(
    _ framePtrs: UnsafePointer<UnsafeMutableRawPointer?>?, _ frameStrides: UnsafePointer<Int32>?,
    _ nFrames: Int32, _ w: Int32, _ h: Int32, _ ch: Int32,
    _ times: UnsafePointer<Float>?, _ maxIter: Int32, _ threshold: Double,
    _ outCRF: UnsafeMutablePointer<Float>?, _ outRad: UnsafeMutablePointer<Float>?
) -> Int32 {
    guard let framePtrs, let frameStrides, let times, let outCRF,
          nFrames >= 2, w > 0, h > 0, (ch == 1 || ch == 3), maxIter >= 1 else {
        return srFail(SRStatus.badArgument, "CalibrateRobertson: invalid arguments")
    }
    let nf = Int(nFrames), wi = Int(w), hi = Int(h), ci = Int(ch), npix = wi * hi
    var imgs: [SRImage] = []
    imgs.reserveCapacity(nf)
    for i in 0..<nf {
        guard let img = SRImage(framePtrs[i], w, h, frameStrides[i], ch, 0) else {
            return srFail(SRStatus.badArgument, "CalibrateRobertson: requires matching u8 frames")
        }
        imgs.append(img)
    }

    var wLut = [Double](repeating: 0.0, count: 256)
    for z in 0..<256 { wLut[z] = robertsonWeight(z) }
    let tD = (0..<nf).map { Double(times[$0]) }

    var resp = [Double](repeating: 0.0, count: 256)
    var nextResp = [Double](repeating: 0.0, count: 256)
    var binSum = [Double](repeating: 0.0, count: 256)
    var binCnt = [Int](repeating: 0, count: 256)
    var rad = [Double](repeating: 0.0, count: npix)

    for c in 0..<ci {
        for z in 0..<256 { resp[z] = Double(z) / 128.0 }

        for _ in 0..<Int(maxIter) {
            // 1. Estimate radiance given current response
            for y in 0..<hi {
                for x in 0..<wi {
                    var num = 0.0, den = 0.0
                    for j in 0..<nf {
                        let z = Int(imgs[j].row(y).assumingMemoryBound(to: UInt8.self)[x * ci + c])
                        let wz = wLut[z]
                        let tj = tD[j]
                        num += wz * tj * resp[z]
                        den += wz * tj * tj
                    }
                    rad[y * wi + x] = den > 1e-12 ? (num / den) : 0.0
                }
            }

            // 2. Gauss-Seidel update of response curve
            binSum.withUnsafeMutableBufferPointer { p in _ = memset(p.baseAddress!, 0, 256 * 8) }
            binCnt.withUnsafeMutableBufferPointer { p in _ = memset(p.baseAddress!, 0, 256 * MemoryLayout<Int>.size) }
            for y in 0..<hi {
                for x in 0..<wi {
                    let e = rad[y * wi + x]
                    for j in 0..<nf {
                        let z = Int(imgs[j].row(y).assumingMemoryBound(to: UInt8.self)[x * ci + c])
                        binSum[z] += tD[j] * e
                        binCnt[z] += 1
                    }
                }
            }

            for z in 0..<256 {
                nextResp[z] = binCnt[z] > 0 ? (binSum[z] / Double(binCnt[z])) : -1.0
            }
            // Interpolate missing bins linearly
            var prevValid = -1
            for z in 0..<256 {
                if nextResp[z] >= 0.0 {
                    if prevValid >= 0 && z > prevValid + 1 {
                        let span = Double(z - prevValid)
                        for k in (prevValid + 1)..<z {
                            let alpha = Double(k - prevValid) / span
                            nextResp[k] = nextResp[prevValid] * (1.0 - alpha) + nextResp[z] * alpha
                        }
                    } else if prevValid < 0 && z > 0 {
                        for k in 0..<z { nextResp[k] = nextResp[z] * Double(k) / Double(z) }
                    }
                    prevValid = z
                }
            }
            if prevValid >= 0 && prevValid < 255 {
                for k in (prevValid + 1)..<256 { nextResp[k] = nextResp[prevValid] }
            }
            // Normalize at z=128
            let normVal = nextResp[128] > 1e-12 ? nextResp[128] : 1.0
            var maxDiff = 0.0
            for z in 0..<256 {
                nextResp[z] /= normVal
                let d = abs(nextResp[z] - resp[z])
                if d > maxDiff { maxDiff = d }
                resp[z] = nextResp[z]
            }
            if maxDiff < threshold { break }
        }

        // Final radiance pass with converged response
        for y in 0..<hi {
            for x in 0..<wi {
                var num = 0.0, den = 0.0
                for j in 0..<nf {
                    let z = Int(imgs[j].row(y).assumingMemoryBound(to: UInt8.self)[x * ci + c])
                    let wz = wLut[z]
                    let tj = tD[j]
                    num += wz * tj * resp[z]
                    den += wz * tj * tj
                }
                if let outRad {
                    outRad[(y * wi + x) * ci + c] = Float(den > 1e-12 ? (num / den) : 0.0)
                }
            }
        }
        for z in 0..<256 { outCRF[z * ci + c] = Float(resp[z]) }
    }
    return SRStatus.ok
}

// MARK: - MergeDebevec & MergeRobertson

@_cdecl("sr_hdr_merge_debevec")
public func sr_hdr_merge_debevec(
    _ framePtrs: UnsafePointer<UnsafeMutableRawPointer?>?, _ frameStrides: UnsafePointer<Int32>?,
    _ nFrames: Int32, _ w: Int32, _ h: Int32, _ ch: Int32,
    _ times: UnsafePointer<Float>?, _ response: UnsafePointer<Float>?,
    _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32
) -> Int32 {
    guard let framePtrs, let frameStrides, let times,
          let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          nFrames >= 1, Int(w) == dst.width, Int(h) == dst.height, Int(ch) == dst.channels,
          (dst.channels == 1 || dst.channels == 3), dst.depth == .f32 else {
        return srFail(SRStatus.badArgument, "MergeDebevec: invalid arguments")
    }
    let nf = Int(nFrames), wi = dst.width, hi = dst.height, ci = dst.channels
    var imgs: [SRImage] = []
    for i in 0..<nf {
        guard let img = SRImage(framePtrs[i], w, h, frameStrides[i], ch, 0) else {
            return srFail(SRStatus.badArgument, "MergeDebevec: inputs must be matching u8 frames")
        }
        imgs.append(img)
    }

    var wLut = [Double](repeating: 0.0, count: 256)
    for z in 0..<256 { wLut[z] = Double(z <= 127 ? z : (255 - z)) }
    let logTimes = (0..<nf).map { log(max(Double(times[$0]), 1e-12)) }
    var logResp = [Double](repeating: 0.0, count: 256 * ci)
    for z in 0..<256 {
        for c in 0..<ci {
            let rv = response != nil ? Double(response![z * ci + c]) : Double(z)
            logResp[z * ci + c] = log(max(rv, 1e-6))
        }
    }

    for y in 0..<hi {
        let dr = dst.row(y).assumingMemoryBound(to: Float.self)
        for x in 0..<wi {
            var wSum = 0.0
            var wFrames = [Double](repeating: 0.0, count: nf)
            for j in 0..<nf {
                let rr = imgs[j].row(y).assumingMemoryBound(to: UInt8.self)
                var wp = 0.0
                for c in 0..<ci {
                    wp += wLut[Int(rr[x * ci + c])]
                }
                wp /= Double(ci)
                wFrames[j] = wp
                wSum += wp
            }
            for c in 0..<ci {
                var num = 0.0, fallback = 0.0
                for j in 0..<nf {
                    let z = Int(imgs[j].row(y).assumingMemoryBound(to: UInt8.self)[x * ci + c])
                    let diff = logResp[z * ci + c] - logTimes[j]
                    num += wFrames[j] * diff
                    fallback += diff
                }
                let logE = wSum > 1e-12 ? (num / wSum) : (fallback / Double(nf))
                dr[x * ci + c] = Float(exp(min(30.0, max(-30.0, logE))))
            }
        }
    }
    return SRStatus.ok
}

@_cdecl("sr_hdr_merge_robertson")
public func sr_hdr_merge_robertson(
    _ framePtrs: UnsafePointer<UnsafeMutableRawPointer?>?, _ frameStrides: UnsafePointer<Int32>?,
    _ nFrames: Int32, _ w: Int32, _ h: Int32, _ ch: Int32,
    _ times: UnsafePointer<Float>?, _ response: UnsafePointer<Float>?,
    _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32
) -> Int32 {
    guard let framePtrs, let frameStrides, let times,
          let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          nFrames >= 1, Int(w) == dst.width, Int(h) == dst.height, Int(ch) == dst.channels,
          (dst.channels == 1 || dst.channels == 3), dst.depth == .f32 else {
        return srFail(SRStatus.badArgument, "MergeRobertson: invalid arguments")
    }
    let nf = Int(nFrames), wi = dst.width, hi = dst.height, ci = dst.channels
    var imgs: [SRImage] = []
    for i in 0..<nf {
        guard let img = SRImage(framePtrs[i], w, h, frameStrides[i], ch, 0) else {
            return srFail(SRStatus.badArgument, "MergeRobertson: inputs must be matching u8 frames")
        }
        imgs.append(img)
    }

    var wLut = [Double](repeating: 0.0, count: 256)
    for z in 0..<256 { wLut[z] = robertsonWeight(z) }
    let tD = (0..<nf).map { Double(times[$0]) }
    var resp = [Double](repeating: 0.0, count: 256 * ci)
    for z in 0..<256 {
        for c in 0..<ci {
            resp[z * ci + c] = response != nil ? Double(response![z * ci + c]) : (Double(z) / 128.0)
        }
    }

    for y in 0..<hi {
        let dr = dst.row(y).assumingMemoryBound(to: Float.self)
        for x in 0..<wi {
            for c in 0..<ci {
                var num = 0.0, den = 0.0
                for j in 0..<nf {
                    let z = Int(imgs[j].row(y).assumingMemoryBound(to: UInt8.self)[x * ci + c])
                    let wz = wLut[z]
                    let tj = tD[j]
                    num += wz * tj * resp[z * ci + c]
                    den += wz * tj * tj
                }
                if den > 1e-12 {
                    dr[x * ci + c] = Float(num / den)
                } else {
                    var fbNum = 0.0, fbDen = 0.0
                    for j in 0..<nf {
                        let z = Int(imgs[j].row(y).assumingMemoryBound(to: UInt8.self)[x * ci + c])
                        fbNum += tD[j] * resp[z * ci + c]
                        fbDen += tD[j] * tD[j]
                    }
                    dr[x * ci + c] = Float(fbDen > 1e-12 ? (fbNum / fbDen) : 0.0)
                }
            }
        }
    }
    return SRStatus.ok
}

// MARK: - MergeMertens (Gaussian/Laplacian Pyramid Exposure Fusion)

@inline(__always)
private func reflect101Idx(_ p: Int, _ len: Int) -> Int {
    if len <= 1 { return 0 }
    var q = p
    while q < 0 || q >= len {
        if q < 0 { q = -q } else { q = 2 * len - 2 - q }
    }
    return q
}

private func pyrBlur5x5(_ src: [Float], _ w: Int, _ h: Int, _ ch: Int) -> [Float] {
    let ker: [Float] = [0.0625, 0.25, 0.375, 0.25, 0.0625]
    var tmp = [Float](repeating: 0.0, count: w * h * ch)
    var out = [Float](repeating: 0.0, count: w * h * ch)
    for y in 0..<h {
        for x in 0..<w {
            for c in 0..<ch {
                var acc: Float = 0.0
                for k in -2...2 {
                    let sx = reflect101Idx(x + k, w)
                    acc += ker[k + 2] * src[(y * w + sx) * ch + c]
                }
                tmp[(y * w + x) * ch + c] = acc
            }
        }
    }
    for y in 0..<h {
        for x in 0..<w {
            for c in 0..<ch {
                var acc: Float = 0.0
                for k in -2...2 {
                    let sy = reflect101Idx(y + k, h)
                    acc += ker[k + 2] * tmp[(sy * w + x) * ch + c]
                }
                out[(y * w + x) * ch + c] = acc
            }
        }
    }
    return out
}

private func pyrDownF32(_ src: [Float], _ w: Int, _ h: Int, _ ch: Int) -> ([Float], Int, Int) {
    let blurred = pyrBlur5x5(src, w, h, ch)
    let nw = max(1, (w + 1) / 2), nh = max(1, (h + 1) / 2)
    var out = [Float](repeating: 0.0, count: nw * nh * ch)
    for y in 0..<nh {
        let sy = min(2 * y, h - 1)
        for x in 0..<nw {
            let sx = min(2 * x, w - 1)
            for c in 0..<ch { out[(y * nw + x) * ch + c] = blurred[(sy * w + sx) * ch + c] }
        }
    }
    return (out, nw, nh)
}

private func pyrUpF32(_ src: [Float], _ w: Int, _ h: Int, _ ch: Int, _ dw: Int, _ dh: Int) -> [Float] {
    var up = [Float](repeating: 0.0, count: dw * dh * ch)
    for y in 0..<h {
        let dy = y * 2
        if dy >= dh { break }
        for x in 0..<w {
            let dx = x * 2
            if dx >= dw { break }
            for c in 0..<ch { up[(dy * dw + dx) * ch + c] = src[(y * w + x) * ch + c] * 4.0 }
        }
    }
    return pyrBlur5x5(up, dw, dh, ch)
}

@_cdecl("sr_hdr_merge_mertens")
public func sr_hdr_merge_mertens(
    _ framePtrs: UnsafePointer<UnsafeMutableRawPointer?>?, _ frameStrides: UnsafePointer<Int32>?,
    _ nFrames: Int32, _ w: Int32, _ h: Int32, _ ch: Int32,
    _ contrastW: Double, _ saturationW: Double, _ exposureW: Double,
    _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32
) -> Int32 {
    guard let framePtrs, let frameStrides,
          let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          nFrames >= 1, Int(w) == dst.width, Int(h) == dst.height, Int(ch) == dst.channels,
          (dst.channels == 1 || dst.channels == 3), dst.depth == .f32 else {
        return srFail(SRStatus.badArgument, "MergeMertens: invalid arguments")
    }
    let nf = Int(nFrames), wi = dst.width, hi = dst.height, ci = dst.channels, npix = wi * hi
    if wi == 0 || hi == 0 { return SRStatus.ok }

    var imgsF = [[Float]](repeating: [Float](repeating: 0.0, count: npix * ci), count: nf)
    var weights = [[Float]](repeating: [Float](repeating: 0.0, count: npix), count: nf)
    var wSum = [Float](repeating: 0.0, count: npix)

    let inv255: Float = 1.0 / 255.0
    for k in 0..<nf {
        guard let img = SRImage(framePtrs[k], w, h, frameStrides[k], ch, 0) else {
            return srFail(SRStatus.badArgument, "MergeMertens: inputs must be matching u8 frames")
        }
        var gray = [Float](repeating: 0.0, count: npix)
        for y in 0..<hi {
            let sr = img.row(y).assumingMemoryBound(to: UInt8.self)
            for x in 0..<wi {
                let pidx = y * wi + x
                for c in 0..<ci { imgsF[k][pidx * ci + c] = Float(sr[x * ci + c]) * inv255 }
                if ci == 1 {
                    gray[pidx] = imgsF[k][pidx]
                } else {
                    gray[pidx] = 0.114 * imgsF[k][pidx * 3] + 0.587 * imgsF[k][pidx * 3 + 1] + 0.299 * imgsF[k][pidx * 3 + 2]
                }
            }
        }

        for y in 0..<hi {
            let ym = max(0, y - 1), yp = min(hi - 1, y + 1)
            for x in 0..<wi {
                let xm = max(0, x - 1), xp = min(wi - 1, x + 1)
                let pidx = y * wi + x
                // Contrast (absolute Laplacian)
                let lap = abs(gray[y * wi + xm] + gray[y * wi + xp] + gray[ym * wi + x] + gray[yp * wi + x] - 4.0 * gray[pidx])
                var wk = contrastW > 0 ? pow(Double(lap), contrastW) : 1.0

                // Saturation (stddev across channels)
                if saturationW > 0 && ci == 3 {
                    let b = Double(imgsF[k][pidx * 3]), g = Double(imgsF[k][pidx * 3 + 1]), r = Double(imgsF[k][pidx * 3 + 2])
                    let mu = (b + g + r) / 3.0
                    let sd = sqrt(((b - mu) * (b - mu) + (g - mu) * (g - mu) + (r - mu) * (r - mu)) / 3.0)
                    wk *= pow(sd, saturationW)
                }

                // Exposedness
                if exposureW > 0 {
                    var expVal = 1.0
                    for c in 0..<ci {
                        let d = Double(imgsF[k][pidx * ci + c]) - 0.5
                        expVal *= exp(-12.5 * d * d) // -0.5 * (d / 0.2)^2
                    }
                    wk *= pow(expVal, exposureW)
                }

                let wf = Float(wk) + 1e-12
                weights[k][pidx] = wf
                wSum[pidx] += wf
            }
        }
    }

    for k in 0..<nf {
        for i in 0..<npix { weights[k][i] /= wSum[i] }
    }

    let maxLvl = max(1, Int(floor(log2(Double(min(wi, hi))))) + 1)
    var pyrShapes: [(Int, Int)] = [(wi, hi)]
    while pyrShapes.count < maxLvl {
        let (pw, ph) = pyrShapes.last!
        if pw <= 2 || ph <= 2 { break }
        pyrShapes.append(((pw + 1) / 2, (ph + 1) / 2))
    }
    let L = pyrShapes.count
    var resPyr = pyrShapes.map { [Float](repeating: 0.0, count: $0.0 * $0.1 * ci) }

    for k in 0..<nf {
        var gImg: [[Float]] = [imgsF[k]]
        var gW: [[Float]] = [weights[k]]
        for l in 1..<L {
            let (pw, ph) = pyrShapes[l - 1]
            gImg.append(pyrDownF32(gImg[l - 1], pw, ph, ci).0)
            gW.append(pyrDownF32(gW[l - 1], pw, ph, 1).0)
        }
        // Blend Laplacian pyramid levels
        for l in 0..<(L - 1) {
            let (lw, lh) = pyrShapes[l]
            let (nw, nh) = pyrShapes[l + 1]
            let up = pyrUpF32(gImg[l + 1], nw, nh, ci, lw, lh)
            for i in 0..<(lw * lh) {
                let wVal = gW[l][i]
                for c in 0..<ci {
                    resPyr[l][i * ci + c] += wVal * (gImg[l][i * ci + c] - up[i * ci + c])
                }
            }
        }
        // Coarsest level
        let (cw, chL) = pyrShapes[L - 1]
        for i in 0..<(cw * chL) {
            let wVal = gW[L - 1][i]
            for c in 0..<ci {
                resPyr[L - 1][i * ci + c] += wVal * gImg[L - 1][i * ci + c]
            }
        }
    }

    // Reconstruct
    var cur = resPyr[L - 1]
    for l in stride(from: L - 2, through: 0, by: -1) {
        let (lw, lh) = pyrShapes[l]
        let (nw, nh) = pyrShapes[l + 1]
        let up = pyrUpF32(cur, nw, nh, ci, lw, lh)
        cur = [Float](repeating: 0.0, count: lw * lh * ci)
        for i in 0..<(lw * lh * ci) { cur[i] = up[i] + resPyr[l][i] }
    }

    for y in 0..<hi {
        let dr = dst.row(y).assumingMemoryBound(to: Float.self)
        for x in 0..<(wi * ci) { dr[x] = cur[y * wi * ci + x] }
    }
    return SRStatus.ok
}

// MARK: - Tonemappers (Tonemap, Drago, Reinhard, Mantiuk)

private func normalizeHDR(_ src: SRImage) -> [Double] {
    let w = src.width, h = src.height, ci = src.channels
    var buf = [Double](repeating: 0.0, count: w * h * ci)
    var minV = Double.infinity, maxV = -Double.infinity
    for y in 0..<h {
        let sr = src.row(y).assumingMemoryBound(to: Float.self)
        for i in 0..<(w * ci) {
            let v = Double(sr[i])
            buf[y * w * ci + i] = v
            if v < minV { minV = v }
            if v > maxV { maxV = v }
        }
    }
    let span = maxV - minV
    if span > 1e-12 {
        let inv = 1.0 / span
        for i in 0..<buf.count { buf[i] = max(0.0, (buf[i] - minV) * inv) }
    } else {
        for i in 0..<buf.count { buf[i] = 0.0 }
    }
    return buf
}

private func mapLuminanceAndWrite(
    _ norm: [Double], _ lum: [Double], _ lumMapped: [Double],
    _ saturation: Double, _ gamma: Double, _ dst: SRImage
) {
    let w = dst.width, h = dst.height, npix = w * h
    var out = [Double](repeating: 0.0, count: npix * 3)
    var maxOut = -Double.infinity
    for i in 0..<npix {
        let l = lum[i]
        let lm = lumMapped[i]
        for c in 0..<3 {
            let v: Double
            if l <= 1e-9 {
                v = 0.0
            } else if abs(saturation - 1.0) < 1e-6 {
                v = norm[i * 3 + c] * (lm / l)
            } else {
                v = pow(max(0.0, norm[i * 3 + c] / l), saturation) * lm
            }
            out[i * 3 + c] = v
            if v > maxOut { maxOut = v }
        }
    }
    let scale = maxOut > 1e-12 ? (1.0 / maxOut) : 1.0
    let invG = gamma > 1e-6 ? (1.0 / gamma) : 1.0
    for y in 0..<h {
        let dr = dst.row(y).assumingMemoryBound(to: Float.self)
        for x in 0..<w {
            let idx = (y * w + x) * 3
            for c in 0..<3 {
                let v = max(0.0, min(1.0, out[idx + c] * scale))
                dr[x * 3 + c] = Float(invG == 1.0 ? v : pow(v, invG))
            }
        }
    }
}

@_cdecl("sr_hdr_tonemap")
public func sr_hdr_tonemap(
    _ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
    _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
    _ gamma: Double
) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep),
          let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          src.depth == .f32, dst.depth == .f32, src.channels == 3, dst.channels == 3,
          src.width == dst.width, src.height == dst.height else {
        return srFail(SRStatus.badArgument, "Tonemap.process: requires matching CV_32FC3 images")
    }
    if src.width == 0 || src.height == 0 { return SRStatus.ok }
    let norm = normalizeHDR(src)
    let invG = gamma > 1e-6 ? (1.0 / gamma) : 1.0
    for y in 0..<src.height {
        let dr = dst.row(y).assumingMemoryBound(to: Float.self)
        for i in 0..<(src.width * 3) {
            let v = max(0.0, norm[y * src.width * 3 + i])
            dr[i] = Float(invG == 1.0 ? v : pow(v, invG))
        }
    }
    return SRStatus.ok
}

@_cdecl("sr_hdr_tonemap_drago")
public func sr_hdr_tonemap_drago(
    _ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
    _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
    _ gamma: Double, _ saturation: Double, _ bias: Double
) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep),
          let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          src.depth == .f32, dst.depth == .f32, src.channels == 3, dst.channels == 3,
          src.width == dst.width, src.height == dst.height else {
        return srFail(SRStatus.badArgument, "TonemapDrago.process: requires matching CV_32FC3 images")
    }
    let w = src.width, h = src.height, npix = w * h
    if npix == 0 { return SRStatus.ok }
    let norm = normalizeHDR(src)
    var lum = [Double](repeating: 0.0, count: npix)
    var logSum = 0.0
    for i in 0..<npix {
        // OpenCV tonemap.cpp computes gray via COLOR_RGB2GRAY on BGR channels: 0.299*ch0 + 0.587*ch1 + 0.114*ch2
        let l = 0.299 * norm[i * 3] + 0.587 * norm[i * 3 + 1] + 0.114 * norm[i * 3 + 2]
        lum[i] = l
        logSum += log(max(l, 1e-4))
    }
    let lwAvg = exp(logSum / Double(npix))
    var lMax = 0.0
    var lScaled = [Double](repeating: 0.0, count: npix)
    for i in 0..<npix {
        let ls = lum[i] / lwAvg
        lScaled[i] = ls
        if ls > lMax { lMax = ls }
    }
    let bClamp = min(max(bias, 1e-4), 1.0 - 1e-4)
    let pExp = log(bClamp) / log(0.5)
    let denomBase = log10(1.0 + max(lMax, 1e-6))
    var mapped = [Double](repeating: 0.0, count: npix)
    for i in 0..<npix {
        let lw = lScaled[i]
        let ratio = lMax > 1e-9 ? (lw / lMax) : 0.0
        mapped[i] = (1.0 / denomBase) * log(1.0 + lw) / log(2.0 + 8.0 * pow(ratio, pExp))
    }
    mapLuminanceAndWrite(norm, lum, mapped, saturation, gamma, dst)
    return SRStatus.ok
}

@_cdecl("sr_hdr_tonemap_reinhard")
public func sr_hdr_tonemap_reinhard(
    _ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
    _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
    _ gamma: Double, _ intensity: Double, _ lightAdapt: Double, _ colorAdapt: Double
) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep),
          let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          src.depth == .f32, dst.depth == .f32, src.channels == 3, dst.channels == 3,
          src.width == dst.width, src.height == dst.height else {
        return srFail(SRStatus.badArgument, "TonemapReinhard.process: requires matching CV_32FC3 images")
    }
    let w = src.width, h = src.height, npix = w * h
    if npix == 0 { return SRStatus.ok }
    let norm = normalizeHDR(src)
    var lum = [Double](repeating: 0.0, count: npix)
    var lMin = Double.infinity, lMax = -Double.infinity, logSum = 0.0
    var cAvg = [Double](repeating: 0.0, count: 3)
    for i in 0..<npix {
        let c0 = norm[i * 3], c1 = norm[i * 3 + 1], c2 = norm[i * 3 + 2]
        cAvg[0] += c0; cAvg[1] += c1; cAvg[2] += c2
        let l = 0.299 * c0 + 0.587 * c1 + 0.114 * c2
        lum[i] = l
        if l < lMin { lMin = l }
        if l > lMax { lMax = l }
        logSum += log(max(l, 1e-4))
    }
    for c in 0..<3 { cAvg[c] /= Double(npix) }
    let lAvLog = logSum / Double(npix)
    let lAv = exp(lAvLog)
    let logMin = log(max(lMin, 1e-4)), logMax = log(max(lMax, 1e-4))
    let k = (logMax - logMin) > 1e-6 ? ((logMax - lAvLog) / (logMax - logMin)) : 1.0
    let m = 0.3 + 0.7 * pow(max(0.0, k), 1.4)
    let f = exp(-intensity)

    var out = [Double](repeating: 0.0, count: npix * 3)
    var outMin = Double.infinity, outMax = -Double.infinity
    for i in 0..<npix {
        let l = lum[i]
        for c in 0..<3 {
            let cv = norm[i * 3 + c]
            let iLocal = colorAdapt * cv + (1.0 - colorAdapt) * l
            let iGlobal = colorAdapt * cAvg[c] + (1.0 - colorAdapt) * lAv
            let iAdapt = lightAdapt * iLocal + (1.0 - lightAdapt) * iGlobal
            let denom = cv + pow(max(1e-9, f * iAdapt), m)
            let v = denom > 1e-12 ? (cv / denom) : 0.0
            out[i * 3 + c] = v
            if v < outMin { outMin = v }
            if v > outMax { outMax = v }
        }
    }
    let span = outMax - outMin
    let invSpan = span > 1e-12 ? (1.0 / span) : 1.0
    let invG = gamma > 1e-6 ? (1.0 / gamma) : 1.0
    for y in 0..<h {
        let dr = dst.row(y).assumingMemoryBound(to: Float.self)
        for i in 0..<(w * 3) {
            let v = max(0.0, min(1.0, (out[y * w * 3 + i] - outMin) * invSpan))
            dr[i] = Float(invG == 1.0 ? v : pow(v, invG))
        }
    }
    return SRStatus.ok
}

@_silgen_name("sr_c_neumann_poisson_f64")
private func sr_c_neumann_poisson_f64(_ rhsAndOut: UnsafeMutablePointer<Double>?, _ w: Int32, _ h: Int32) -> Int32

@_cdecl("sr_hdr_tonemap_mantiuk")
public func sr_hdr_tonemap_mantiuk(
    _ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
    _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
    _ gamma: Double, _ scale: Double, _ saturation: Double
) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep),
          let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          src.depth == .f32, dst.depth == .f32, src.channels == 3, dst.channels == 3,
          src.width == dst.width, src.height == dst.height else {
        return srFail(SRStatus.badArgument, "TonemapMantiuk.process: requires matching CV_32FC3 images")
    }
    let w = src.width, h = src.height, npix = w * h
    if npix == 0 { return SRStatus.ok }
    let norm = normalizeHDR(src)
    var lum = [Double](repeating: 0.0, count: npix)
    var logL = [Double](repeating: 0.0, count: npix)
    for i in 0..<npix {
        let l = 0.299 * norm[i * 3] + 0.587 * norm[i * 3 + 1] + 0.114 * norm[i * 3 + 2]
        lum[i] = l
        logL[i] = log10(max(l, 1e-4))
    }

    @inline(__always)
    func mantiukScaleGrad(_ g: Double) -> Double {
        let s = g >= 0.0 ? 1.0 : -1.0
        let ag = abs(g)
        if ag < 1e-8 { return 0.0 }
        let r = 54.09288 * pow(ag, 0.41850) * scale
        return s * pow(abs(r) / 54.09288, 1.0 / 0.41850)
    }

    var gx = [Double](repeating: 0.0, count: npix)
    var gy = [Double](repeating: 0.0, count: npix)
    for y in 0..<h {
        for x in 0..<w {
            let idx = y * w + x
            let c = logL[idx]
            if x + 1 < w { gx[idx] = mantiukScaleGrad(logL[idx + 1] - c) }
            if y + 1 < h { gy[idx] = mantiukScaleGrad(logL[idx + w] - c) }
        }
    }

    let rhs = UnsafeMutablePointer<Double>.allocate(capacity: npix)
    defer { rhs.deallocate() }
    for y in 0..<h {
        for x in 0..<w {
            let idx = y * w + x
            let divX = (x + 1 < w ? gx[idx] : 0.0) - (x > 0 ? gx[idx - 1] : 0.0)
            let divY = (y + 1 < h ? gy[idx] : 0.0) - (y > 0 ? gy[idx - w] : 0.0)
            rhs[idx] = divX + divY
        }
    }

    if sr_c_neumann_poisson_f64(rhs, Int32(w), Int32(h)) != 0 {
        return srFail(SRStatus.internalError, "TonemapMantiuk.process: Neumann Poisson solver failed")
    }

    var meanX = 0.0
    for i in 0..<npix { meanX += rhs[i] }
    meanX /= Double(npix)

    var mapped = [Double](repeating: 0.0, count: npix)
    for i in 0..<npix {
        mapped[i] = pow(10.0, min(6.0, max(-6.0, rhs[i] - meanX)))
    }
    mapLuminanceAndWrite(norm, lum, mapped, saturation, gamma, dst)
    return SRStatus.ok
}
