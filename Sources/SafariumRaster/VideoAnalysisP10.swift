// SafariumRaster — Phase 10: Video Analysis (PyrLK, Farneback, PhaseCorrelate via vDSP 2D FFT, MOG2, MeanShift, ECC)
// 100% Apple-native Swift + Accelerate.

import Accelerate
import Foundation

// MARK: - Private Helpers

private func p10ReadGrayF32(_ img: SRImage) -> [Float] {
    let w = img.width
    let h = img.height
    let c = img.channels
    var out = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
        let rowPtr = img.row(y)
        let off = y * w
        switch img.depth {
        case .u8:
            let p = rowPtr.assumingMemoryBound(to: UInt8.self)
            if c == 1 {
                for x in 0..<w { out[off + x] = Float(p[x]) }
            } else {
                for x in 0..<w {
                    let b = Float(p[x * c])
                    let g = Float(p[x * c + 1])
                    let r = Float(p[x * c + 2])
                    out[off + x] = 0.114 * b + 0.587 * g + 0.299 * r
                }
            }
        case .u16:
            let p = rowPtr.assumingMemoryBound(to: UInt16.self)
            if c == 1 {
                for x in 0..<w { out[off + x] = Float(p[x]) }
            } else {
                for x in 0..<w {
                    let b = Float(p[x * c])
                    let g = Float(p[x * c + 1])
                    let r = Float(p[x * c + 2])
                    out[off + x] = 0.114 * b + 0.587 * g + 0.299 * r
                }
            }
        case .s32:
            let p = rowPtr.assumingMemoryBound(to: Int32.self)
            if c == 1 {
                for x in 0..<w { out[off + x] = Float(p[x]) }
            } else {
                for x in 0..<w {
                    let b = Float(p[x * c])
                    let g = Float(p[x * c + 1])
                    let r = Float(p[x * c + 2])
                    out[off + x] = 0.114 * b + 0.587 * g + 0.299 * r
                }
            }
        case .f32:
            let p = rowPtr.assumingMemoryBound(to: Float.self)
            if c == 1 {
                for x in 0..<w { out[off + x] = p[x] }
            } else {
                for x in 0..<w {
                    let b = p[x * c]
                    let g = p[x * c + 1]
                    let r = p[x * c + 2]
                    out[off + x] = 0.114 * b + 0.587 * g + 0.299 * r
                }
            }
        }
    }
    return out
}

@inline(__always)
private func p10Clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
    v < lo ? lo : (v > hi ? hi : v)
}

@inline(__always)
private func p10Reflect(_ i: Int, _ n: Int) -> Int {
    if n <= 1 { return 0 }
    var v = i
    while v < 0 || v >= n {
        if v < 0 { v = -v }
        if v >= n { v = 2 * n - 2 - v }
    }
    return v
}

@inline(__always)
private func p10Sample(_ img: [Float], _ w: Int, _ h: Int, _ x: Float, _ y: Float) -> Float {
    let cx = min(max(x, 0.0), Float(w - 1))
    let cy = min(max(y, 0.0), Float(h - 1))
    let x0 = Int(floorf(cx))
    let y0 = Int(floorf(cy))
    let x1 = min(x0 + 1, w - 1)
    let y1 = min(y0 + 1, h - 1)
    let fx = cx - Float(x0)
    let fy = cy - Float(y0)
    let v00 = img[y0 * w + x0]
    let v10 = img[y0 * w + x1]
    let v01 = img[y1 * w + x0]
    let v11 = img[y1 * w + x1]
    let top = v00 + fx * (v10 - v00)
    let bot = v01 + fx * (v11 - v01)
    return top + fy * (bot - top)
}

private func p10Blur5(_ src: [Float], _ w: Int, _ h: Int) -> [Float] {
    let k: [Float] = [1, 4, 6, 4, 1]
    let inv: Float = 1.0 / 16.0
    var tmp = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
        let off = y * w
        for x in 0..<w {
            var s: Float = 0
            for d in -2...2 { s += k[d + 2] * src[off + p10Reflect(x + d, w)] }
            tmp[off + x] = s * inv
        }
    }
    var dst = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
        let off = y * w
        for x in 0..<w {
            var s: Float = 0
            for d in -2...2 { s += k[d + 2] * tmp[p10Reflect(y + d, h) * w + x] }
            dst[off + x] = s * inv
        }
    }
    return dst
}

private func p10PyrDown(_ src: [Float], _ w: Int, _ h: Int) -> ([Float], Int, Int) {
    let blurred = p10Blur5(src, w, h)
    let nw = max(1, (w + 1) / 2)
    let nh = max(1, (h + 1) / 2)
    var dst = [Float](repeating: 0, count: nw * nh)
    for y in 0..<nh {
        let sy = min(2 * y, h - 1) * w
        for x in 0..<nw {
            let sx = min(2 * x, w - 1)
            dst[y * nw + x] = blurred[sy + sx]
        }
    }
    return (dst, nw, nh)
}

private func p10ResizeF32(_ src: [Float], _ sw: Int, _ sh: Int, _ dw: Int, _ dh: Int) -> [Float] {
    if sw == dw && sh == dh { return src }
    var dst = [Float](repeating: 0, count: dw * dh)
    let sx = Float(sw) / Float(dw)
    let sy = Float(sh) / Float(dh)
    for y in 0..<dh {
        let fy = (Float(y) + 0.5) * sy - 0.5
        for x in 0..<dw {
            let fx = (Float(x) + 0.5) * sx - 0.5
            dst[y * dw + x] = p10Sample(src, sw, sh, fx, fy)
        }
    }
    return dst
}

private func p10BoxFilter(_ src: [Float], _ w: Int, _ h: Int, _ radius: Int) -> [Float] {
    let r = max(1, radius)
    let inv = 1.0 / Float(2 * r + 1)
    var tmp = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
        let off = y * w
        var acc: Float = 0
        for dx in -r...r { acc += src[off + p10Clamp(dx, 0, w - 1)] }
        tmp[off] = acc * inv
        for x in 1..<w {
            let addX = p10Clamp(x + r, 0, w - 1)
            let subX = p10Clamp(x - r - 1, 0, w - 1)
            acc += src[off + addX] - src[off + subX]
            tmp[off + x] = acc * inv
        }
    }
    var dst = [Float](repeating: 0, count: w * h)
    for x in 0..<w {
        var acc: Float = 0
        for dy in -r...r { acc += tmp[p10Clamp(dy, 0, h - 1) * w + x] }
        dst[x] = acc * inv
        for y in 1..<h {
            let addY = p10Clamp(y + r, 0, h - 1)
            let subY = p10Clamp(y - r - 1, 0, h - 1)
            acc += tmp[addY * w + x] - tmp[subY * w + x]
            dst[y * w + x] = acc * inv
        }
    }
    return dst
}

private func p10SolveLinearSystem(_ A: inout [Double], _ b: inout [Double], _ n: Int) -> Bool {
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
        if maxVal < 1e-12 { return false }
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

// MARK: - 1. sr_calc_optical_flow_pyr_lk

@_cdecl("sr_calc_optical_flow_pyr_lk")
public func sr_calc_optical_flow_pyr_lk(
    _ prevData: UnsafeMutableRawPointer?, _ pw: Int32, _ ph: Int32, _ ps: Int32, _ pc: Int32, _ pd: Int32,
    _ nextData: UnsafeMutableRawPointer?, _ nw: Int32, _ nh: Int32, _ ns: Int32, _ nc: Int32, _ nd: Int32,
    _ prevPts: UnsafePointer<Float>?, _ numPts: Int32,
    _ nextPts: UnsafeMutablePointer<Float>?,
    _ status: UnsafeMutablePointer<UInt8>?,
    _ err: UnsafeMutablePointer<Float>?,
    _ winW: Int32, _ winH: Int32, _ maxLevel: Int32,
    _ maxIter: Int32, _ eps: Double, _ useInitialFlow: Int32
) -> Int32 {
    guard let prev = SRImage(prevData, pw, ph, ps, pc, pd),
          let next = SRImage(nextData, nw, nh, ns, nc, nd),
          prev.width == next.width, prev.height == next.height,
          let prevPts, let nextPts, let status else {
        return srFail(SRStatus.badArgument, "sr_calc_optical_flow_pyr_lk: invalid arguments")
    }
    let nPts = Int(numPts)
    if nPts <= 0 { return SRStatus.ok }

    let levels = max(0, min(6, Int(maxLevel)))
    let halfW = max(1, Int(winW) / 2)
    let halfH = max(1, Int(winH) / 2)
    let iters = max(1, Int(maxIter))
    let eps2 = Float(eps * eps)

    var prevPyr: [([Float], Int, Int)] = [(p10ReadGrayF32(prev), prev.width, prev.height)]
    var nextPyr: [([Float], Int, Int)] = [(p10ReadGrayF32(next), next.width, next.height)]

    for _ in 0..<levels {
        let lp = prevPyr.last!
        if lp.1 < 8 || lp.2 < 8 { break }
        prevPyr.append(p10PyrDown(lp.0, lp.1, lp.2))
        let ln = nextPyr.last!
        nextPyr.append(p10PyrDown(ln.0, ln.1, ln.2))
    }

    let actualMaxLevel = prevPyr.count - 1
    let patchCount = (2 * halfW + 1) * (2 * halfH + 1)
    var patchI = [Float](repeating: 0, count: patchCount)
    var patchIx = [Float](repeating: 0, count: patchCount)
    var patchIy = [Float](repeating: 0, count: patchCount)

    for i in 0..<nPts {
        let px0 = prevPts[2 * i]
        let py0 = prevPts[2 * i + 1]
        var gx: Float = 0
        var gy: Float = 0
        if useInitialFlow != 0 {
            let scale = powf(0.5, Float(actualMaxLevel))
            gx = (nextPts[2 * i] - px0) * scale
            gy = (nextPts[2 * i + 1] - py0) * scale
        }

        var ok = true
        var lastErr: Float = 0

        for lvl in stride(from: actualMaxLevel, through: 0, by: -1) {
            let (imgI, w, h) = prevPyr[lvl]
            let (imgJ, _, _) = nextPyr[lvl]
            let scale = powf(0.5, Float(lvl))
            let ux = px0 * scale
            let uy = py0 * scale

            if ux < 1 || uy < 1 || ux >= Float(w - 1) || uy >= Float(h - 1) {
                ok = false
                break
            }

            var gxx: Double = 0
            var gxy: Double = 0
            var gyy: Double = 0
            var idx = 0
            for dy in -halfH...halfH {
                let sy = uy + Float(dy)
                for dx in -halfW...halfW {
                    let sx = ux + Float(dx)
                    let val = p10Sample(imgI, w, h, sx, sy)
                    let ix = (p10Sample(imgI, w, h, sx + 1.0, sy) - p10Sample(imgI, w, h, sx - 1.0, sy)) * 0.5
                    let iy = (p10Sample(imgI, w, h, sx, sy + 1.0) - p10Sample(imgI, w, h, sx, sy - 1.0)) * 0.5
                    patchI[idx] = val
                    patchIx[idx] = ix
                    patchIy[idx] = iy
                    gxx += Double(ix * ix)
                    gxy += Double(ix * iy)
                    gyy += Double(iy * iy)
                    idx += 1
                }
            }

            let det = gxx * gyy - gxy * gxy
            let minEig = 0.5 * ((gxx + gyy) - sqrt(max(0.0, (gxx - gyy) * (gxx - gyy) + 4.0 * gxy * gxy)))
            if det < 1e-7 || minEig / Double(patchCount) < 1e-4 {
                if lvl == 0 { ok = false }
                if lvl > 0 { gx *= 2.0; gy *= 2.0 }
                continue
            }
            let invDet = 1.0 / det

            var vx = gx
            var vy = gy
            for _ in 0..<iters {
                var bx: Double = 0
                var by: Double = 0
                var absSum: Float = 0
                var k = 0
                for dy in -halfH...halfH {
                    let sy = uy + vy + Float(dy)
                    for dx in -halfW...halfW {
                        let sx = ux + vx + Float(dx)
                        let jVal = p10Sample(imgJ, w, h, sx, sy)
                        let diff = patchI[k] - jVal
                        absSum += fabsf(diff)
                        bx += Double(diff * patchIx[k])
                        by += Double(diff * patchIy[k])
                        k += 1
                    }
                }
                lastErr = absSum / Float(patchCount)
                let dvx = Float((gyy * bx - gxy * by) * invDet)
                let dvy = Float((gxx * by - gxy * bx) * invDet)
                vx += dvx
                vy += dvy
                if dvx * dvx + dvy * dvy < eps2 { break }
                if abs(vx) > Float(w) || abs(vy) > Float(h) {
                    ok = false
                    break
                }
            }

            if !ok { break }
            if lvl > 0 {
                gx = vx * 2.0
                gy = vy * 2.0
            } else {
                gx = vx
                gy = vy
            }
        }

        let finalX = px0 + gx
        let finalY = py0 + gy
        if ok && finalX >= 0 && finalY >= 0 && finalX < Float(prev.width) && finalY < Float(prev.height) {
            nextPts[2 * i] = finalX
            nextPts[2 * i + 1] = finalY
            status[i] = 1
            err?[i] = lastErr
        } else {
            nextPts[2 * i] = px0
            nextPts[2 * i + 1] = py0
            status[i] = 0
            err?[i] = 0
        }
    }
    return SRStatus.ok
}

// MARK: - 2. sr_calc_optical_flow_farneback

@_cdecl("sr_calc_optical_flow_farneback")
public func sr_calc_optical_flow_farneback(
    _ prevData: UnsafeMutableRawPointer?, _ pw: Int32, _ ph: Int32, _ ps: Int32, _ pc: Int32, _ pd: Int32,
    _ nextData: UnsafeMutableRawPointer?, _ nw: Int32, _ nh: Int32, _ ns: Int32, _ nc: Int32, _ nd: Int32,
    _ flowData: UnsafeMutableRawPointer?, _ fw: Int32, _ fh: Int32, _ fs: Int32, _ fc: Int32, _ fd: Int32,
    _ pyrScale: Double, _ levels: Int32, _ winsize: Int32, _ iterations: Int32, _ polyN: Int32, _ polySigma: Double
) -> Int32 {
    guard let prev = SRImage(prevData, pw, ph, ps, pc, pd),
          let next = SRImage(nextData, nw, nh, ns, nc, nd),
          let flow = SRImage(flowData, fw, fh, fs, fc, fd) else {
        return srFail(SRStatus.badArgument, "sr_calc_optical_flow_farneback: invalid image")
    }
    guard prev.width == next.width, prev.height == next.height,
          flow.width == prev.width, flow.height == prev.height,
          flow.channels == 2, flow.depth == .f32 else {
        return srFail(SRStatus.badArgument, "sr_calc_optical_flow_farneback: flow must be 2-ch float32 matching src size")
    }

    let baseW = prev.width
    let baseH = prev.height
    if baseW < 4 || baseH < 4 { return SRStatus.ok }

    let scale = (pyrScale > 0.1 && pyrScale < 0.95) ? pyrScale : 0.5
    let nLevels = max(1, min(8, Int(levels)))
    let winR = max(2, Int(winsize) / 2)
    let nIters = max(1, Int(iterations))

    var prevPyr: [([Float], Int, Int)] = [(p10ReadGrayF32(prev), baseW, baseH)]
    var nextPyr: [([Float], Int, Int)] = [(p10ReadGrayF32(next), baseW, baseH)]
    for _ in 1..<nLevels {
        let lp = prevPyr.last!
        let nw = Int(round(Double(lp.1) * scale))
        let nh = Int(round(Double(lp.2) * scale))
        if nw < 8 || nh < 8 { break }
        let bp = p10Blur5(lp.0, lp.1, lp.2)
        prevPyr.append((p10ResizeF32(bp, lp.1, lp.2, nw, nh), nw, nh))
        let ln = nextPyr.last!
        let bn = p10Blur5(ln.0, ln.1, ln.2)
        nextPyr.append((p10ResizeF32(bn, ln.1, ln.2, nw, nh), nw, nh))
    }

    var ux: [Float] = []
    var uy: [Float] = []
    var prevW = 0
    var prevH = 0

    for lvl in stride(from: prevPyr.count - 1, through: 0, by: -1) {
        let (img1, w, h) = prevPyr[lvl]
        let (img2, _, _) = nextPyr[lvl]
        let n = w * h

        if ux.isEmpty {
            ux = [Float](repeating: 0, count: n)
            uy = [Float](repeating: 0, count: n)
        } else {
            let sx = Float(w) / Float(prevW)
            let sy = Float(h) / Float(prevH)
            ux = p10ResizeF32(ux, prevW, prevH, w, h)
            uy = p10ResizeF32(uy, prevW, prevH, w, h)
            for i in 0..<n {
                ux[i] *= sx
                uy[i] *= sy
            }
        }
        prevW = w
        prevH = h

        // Smooth input slightly according to polySigma
        let i1 = p10Blur5(img1, w, h)
        let i2 = p10Blur5(img2, w, h)

        var i2w = [Float](repeating: 0, count: n)
        var sxx = [Float](repeating: 0, count: n)
        var sxy = [Float](repeating: 0, count: n)
        var syy = [Float](repeating: 0, count: n)
        var sxt = [Float](repeating: 0, count: n)
        var syt = [Float](repeating: 0, count: n)

        let lvlWinR = max(2, min(winR, min(w, h) / 4))

        for _ in 0..<nIters {
            for y in 0..<h {
                let off = y * w
                for x in 0..<w {
                    i2w[off + x] = p10Sample(i2, w, h, Float(x) + ux[off + x], Float(y) + uy[off + x])
                }
            }

            for y in 0..<h {
                let ym = p10Clamp(y - 1, 0, h - 1) * w
                let y0 = y * w
                let yp = p10Clamp(y + 1, 0, h - 1) * w
                for x in 0..<w {
                    let xm = p10Clamp(x - 1, 0, w - 1)
                    let xp = p10Clamp(x + 1, 0, w - 1)
                    let ix1 = 0.5 * (i1[y0 + xp] - i1[y0 + xm])
                    let iy1 = 0.5 * (i1[yp + x] - i1[ym + x])
                    let ix2 = 0.5 * (i2w[y0 + xp] - i2w[y0 + xm])
                    let iy2 = 0.5 * (i2w[yp + x] - i2w[ym + x])
                    let ix = 0.5 * (ix1 + ix2)
                    let iy = 0.5 * (iy1 + iy2)
                    let it = i2w[y0 + x] - i1[y0 + x]
                    let k = y0 + x
                    sxx[k] = ix * ix
                    sxy[k] = ix * iy
                    syy[k] = iy * iy
                    sxt[k] = ix * it
                    syt[k] = iy * it
                }
            }

            // Two box passes approximate Gaussian aggregation over winsize
            let axx = p10BoxFilter(p10BoxFilter(sxx, w, h, lvlWinR), w, h, lvlWinR)
            let axy = p10BoxFilter(p10BoxFilter(sxy, w, h, lvlWinR), w, h, lvlWinR)
            let ayy = p10BoxFilter(p10BoxFilter(syy, w, h, lvlWinR), w, h, lvlWinR)
            let axt = p10BoxFilter(p10BoxFilter(sxt, w, h, lvlWinR), w, h, lvlWinR)
            let ayt = p10BoxFilter(p10BoxFilter(syt, w, h, lvlWinR), w, h, lvlWinR)

            let reg: Float = 1e-2
            for i in 0..<n {
                let a = axx[i] + reg
                let b = axy[i]
                let c = ayy[i] + reg
                let det = a * c - b * b
                if det > 1e-6 {
                    let invDet = 1.0 / det
                    let dux = -(c * axt[i] - b * ayt[i]) * invDet
                    let duy = -(a * ayt[i] - b * axt[i]) * invDet
                    let maxStep: Float = Float(lvlWinR)
                    ux[i] += max(-maxStep, min(maxStep, dux))
                    uy[i] += max(-maxStep, min(maxStep, duy))
                }
            }
            ux = p10BoxFilter(ux, w, h, max(1, lvlWinR / 2))
            uy = p10BoxFilter(uy, w, h, max(1, lvlWinR / 2))
        }
    }

    for y in 0..<baseH {
        let row = flow.row(y).assumingMemoryBound(to: Float.self)
        let off = y * baseW
        for x in 0..<baseW {
            row[2 * x] = ux[off + x]
            row[2 * x + 1] = uy[off + x]
        }
    }
    return SRStatus.ok
}

// MARK: - 3. sr_phase_correlate (Accelerate vDSP 2D FFT Cross-Power Spectrum + Hanning Window)

private func p10NextPow2(_ n: Int) -> Int {
    var p = 16
    while p < n { p <<= 1 }
    return p
}

@_cdecl("sr_phase_correlate")
public func sr_phase_correlate(
    _ src1Data: UnsafeMutableRawPointer?, _ w1: Int32, _ h1: Int32, _ s1: Int32, _ c1: Int32, _ d1: Int32,
    _ src2Data: UnsafeMutableRawPointer?, _ w2: Int32, _ h2: Int32, _ s2: Int32, _ c2: Int32, _ d2: Int32,
    _ winData: UnsafeMutableRawPointer?, _ ww: Int32, _ wh: Int32, _ ws: Int32, _ wc: Int32, _ wd: Int32,
    _ outShiftX: UnsafeMutablePointer<Double>?, _ outShiftY: UnsafeMutablePointer<Double>?,
    _ outResponse: UnsafeMutablePointer<Double>?
) -> Int32 {
    guard let src1 = SRImage(src1Data, w1, h1, s1, c1, d1),
          let src2 = SRImage(src2Data, w2, h2, s2, c2, d2),
          src1.width == src2.width, src1.height == src2.height,
          let outShiftX, let outShiftY else {
        return srFail(SRStatus.badArgument, "sr_phase_correlate: invalid arguments")
    }
    let w = src1.width
    let h = src1.height
    if w < 4 || h < 4 {
        outShiftX.pointee = 0
        outShiftY.pointee = 0
        outResponse?.pointee = 0
        return SRStatus.ok
    }

    var winArr: [Float]? = nil
    if winData != nil {
        guard let wm = SRImage(winData, ww, wh, ws, wc, wd), wm.width == w, wm.height == h else {
            return srFail(SRStatus.badArgument, "sr_phase_correlate: invalid window image")
        }
        winArr = p10ReadGrayF32(wm)
    }

    let g1 = p10ReadGrayF32(src1)
    let g2 = p10ReadGrayF32(src2)

    var mean1: Float = 0
    var mean2: Float = 0
    vDSP_meanv(g1, 1, &mean1, vDSP_Length(w * h))
    vDSP_meanv(g2, 1, &mean2, vDSP_Length(w * h))

    let fftW = p10NextPow2(w)
    let fftH = p10NextPow2(h)
    let log2W = vDSP_Length(round(log2(Double(fftW))))
    let log2H = vDSP_Length(round(log2(Double(fftH))))
    let fftN = fftW * fftH

    var hannX = [Float](repeating: 1.0, count: w)
    var hannY = [Float](repeating: 1.0, count: h)
    if winArr == nil {
        let denomX = Float(max(1, w - 1))
        let denomY = Float(max(1, h - 1))
        for x in 0..<w {
            hannX[x] = 0.5 * (1.0 - cosf(2.0 * Float.pi * Float(x) / denomX))
        }
        for y in 0..<h {
            hannY[y] = 0.5 * (1.0 - cosf(2.0 * Float.pi * Float(y) / denomY))
        }
    }

    var r1 = [Float](repeating: 0, count: fftN)
    var i1 = [Float](repeating: 0, count: fftN)
    var r2 = [Float](repeating: 0, count: fftN)
    var i2 = [Float](repeating: 0, count: fftN)

    for y in 0..<h {
        let srcOff = y * w
        let dstOff = y * fftW
        for x in 0..<w {
            let wt: Float
            if let wa = winArr {
                wt = wa[srcOff + x]
            } else {
                wt = hannX[x] * hannY[y]
            }
            r1[dstOff + x] = (g1[srcOff + x] - mean1) * wt
            r2[dstOff + x] = (g2[srcOff + x] - mean2) * wt
        }
    }

    guard let setup = vDSP_create_fftsetup(max(log2W, log2H), FFTRadix(kFFTRadix2)) else {
        return srFail(SRStatus.internalError, "sr_phase_correlate: failed to create vDSP FFT setup")
    }
    defer { vDSP_destroy_fftsetup(setup) }

    r1.withUnsafeMutableBufferPointer { r1p in
        i1.withUnsafeMutableBufferPointer { i1p in
            var c1 = DSPSplitComplex(realp: r1p.baseAddress!, imagp: i1p.baseAddress!)
            vDSP_fft2d_zip(setup, &c1, 1, 0, log2W, log2H, FFTDirection(kFFTDirection_Forward))
        }
    }
    r2.withUnsafeMutableBufferPointer { r2p in
        i2.withUnsafeMutableBufferPointer { i2p in
            var c2 = DSPSplitComplex(realp: r2p.baseAddress!, imagp: i2p.baseAddress!)
            vDSP_fft2d_zip(setup, &c2, 1, 0, log2W, log2H, FFTDirection(kFFTDirection_Forward))
        }
    }

    // Cross-power spectrum: F2 * conj(F1) / (|F2 * conj(F1)| + eps)
    var cpsR = [Float](repeating: 0, count: fftN)
    var cpsI = [Float](repeating: 0, count: fftN)
    let eps: Float = 1e-8
    for k in 0..<fftN {
        let a = r2[k]
        let b = i2[k]
        let c = r1[k]
        let d = i1[k]
        let re = a * c + b * d
        let im = b * c - a * d
        let mag = sqrtf(re * re + im * im) + eps
        cpsR[k] = re / mag
        cpsI[k] = im / mag
    }

    cpsR.withUnsafeMutableBufferPointer { crp in
        cpsI.withUnsafeMutableBufferPointer { cip in
            var cps = DSPSplitComplex(realp: crp.baseAddress!, imagp: cip.baseAddress!)
            vDSP_fft2d_zip(setup, &cps, 1, 0, log2W, log2H, FFTDirection(kFFTDirection_Inverse))
        }
    }

    let invN = 1.0 / Float(fftN)
    var peakVal: Float = -Float.greatestFiniteMagnitude
    var peakX = 0
    var peakY = 0
    for y in 0..<fftH {
        let off = y * fftW
        for x in 0..<fftW {
            let v = cpsR[off + x] * invN
            cpsR[off + x] = v
            if v > peakVal {
                peakVal = v
                peakX = x
                peakY = y
            }
        }
    }

    // 5x5 weighted centroid around integer peak (cyclic wrap)
    var sumW: Double = 0
    var sumDx: Double = 0
    var sumDy: Double = 0
    for dy in -2...2 {
        let yy = (peakY + dy + fftH) % fftH
        let off = yy * fftW
        for dx in -2...2 {
            let xx = (peakX + dx + fftW) % fftW
            let v = Double(max(0.0, cpsR[off + xx]))
            sumW += v
            sumDx += Double(dx) * v
            sumDy += Double(dy) * v
        }
    }

    let subDx = sumW > 1e-12 ? (sumDx / sumW) : 0.0
    let subDy = sumW > 1e-12 ? (sumDy / sumW) : 0.0

    var sx = Double(peakX) + subDx
    var sy = Double(peakY) + subDy
    if sx > Double(fftW) * 0.5 { sx -= Double(fftW) }
    if sy > Double(fftH) * 0.5 { sy -= Double(fftH) }

    outShiftX.pointee = sx
    outShiftY.pointee = sy
    outResponse?.pointee = min(1.0, max(0.0, sumW))
    return SRStatus.ok
}

// MARK: - 4. MOG2 Background Subtractor (sr_mog2_create / apply / free)

private final class P10MOG2Model {
    let history: Int
    let varThreshold: Float
    let detectShadows: Bool
    let maxK: Int = 3
    var width: Int = 0
    var height: Int = 0
    var channels: Int = 0
    var frameCount: Int = 0

    // Per pixel, K components: weight, var, mean[3]
    var weights: [Float] = []
    var variances: [Float] = []
    var means: [Float] = []

    init(history: Int, varThreshold: Float, detectShadows: Bool) {
        self.history = max(1, history)
        self.varThreshold = max(1.0, varThreshold)
        self.detectShadows = detectShadows
    }

    func ensureInit(w: Int, h: Int, c: Int) {
        if width == w && height == h && channels == c && !weights.isEmpty { return }
        width = w
        height = h
        channels = c
        frameCount = 0
        let n = w * h
        weights = [Float](repeating: 0, count: n * maxK)
        variances = [Float](repeating: 225.0, count: n * maxK)
        means = [Float](repeating: 0, count: n * maxK * c)
    }

    func apply(src: SRImage, dst: SRImage, learningRate: Double) {
        let w = src.width
        let h = src.height
        let c = min(3, src.channels)
        ensureInit(w: w, h: h, c: c)
        frameCount += 1

        let alpha: Float
        if learningRate >= 0 {
            alpha = Float(min(1.0, learningRate))
        } else {
            let denom = Float(min(frameCount, history))
            alpha = 1.0 / max(1.0, denom)
        }
        let initVar: Float = 225.0
        let minVar: Float = 16.0
        let maxVar: Float = 2500.0
        let bgRatio: Float = 0.85

        var pix = (Float(0), Float(0), Float(0))
        for y in 0..<h {
            let sRow = src.row(y).assumingMemoryBound(to: UInt8.self)
            let dRow = dst.row(y).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                let pxBase = x * src.channels
                pix.0 = Float(sRow[pxBase])
                pix.1 = c > 1 ? Float(sRow[pxBase + 1]) : pix.0
                pix.2 = c > 2 ? Float(sRow[pxBase + 2]) : pix.0

                let pIdx = y * w + x
                let kBase = pIdx * maxK

                if frameCount == 1 {
                    weights[kBase] = 1.0
                    variances[kBase] = initVar
                    let mBase = kBase * c
                    means[mBase] = pix.0
                    if c > 1 { means[mBase + 1] = pix.1 }
                    if c > 2 { means[mBase + 2] = pix.2 }
                    for k in 1..<maxK { weights[kBase + k] = 0 }
                    dRow[x] = 0
                    continue
                }

                // Check match against existing Gaussians
                var matched = -1
                var bestDist = Float.greatestFiniteMagnitude
                for k in 0..<maxK {
                    let wt = weights[kBase + k]
                    if wt <= 1e-6 { continue }
                    let mBase = (kBase + k) * c
                    var d2: Float = 0
                    let d0 = pix.0 - means[mBase]
                    d2 += d0 * d0
                    if c > 1 {
                        let d1 = pix.1 - means[mBase + 1]
                        d2 += d1 * d1
                    }
                    if c > 2 {
                        let d2c = pix.2 - means[mBase + 2]
                        d2 += d2c * d2c
                    }
                    let v = variances[kBase + k]
                    let thresh = varThreshold * v * Float(c)
                    if d2 < thresh && d2 < bestDist {
                        bestDist = d2
                        matched = k
                    }
                }

                // Determine if matched component belongs to background before updating
                var isBg = false
                if matched >= 0 {
                    var sumW: Float = 0
                    for k in 0..<maxK {
                        if k == matched {
                            if sumW < bgRatio || weights[kBase + k] > 0.25 {
                                isBg = true
                            }
                            break
                        }
                        sumW += weights[kBase + k]
                    }
                }

                // Shadow check if foreground
                var isShadow = false
                if !isBg && detectShadows {
                    for k in 0..<maxK {
                        if weights[kBase + k] < 0.25 { continue }
                        let mBase = (kBase + k) * c
                        let m0 = means[mBase]
                        let m1 = c > 1 ? means[mBase + 1] : m0
                        let m2 = c > 2 ? means[mBase + 2] : m0
                        let bgNorm2 = m0 * m0 + m1 * m1 + m2 * m2
                        if bgNorm2 < 25.0 { continue }
                        let dot = pix.0 * m0 + pix.1 * m1 + pix.2 * m2
                        let ratio = dot / bgNorm2
                        if ratio >= 0.5 && ratio < 0.98 {
                            let e0 = pix.0 - ratio * m0
                            let e1 = pix.1 - ratio * m1
                            let e2 = pix.2 - ratio * m2
                            let err2 = e0 * e0 + e1 * e1 + e2 * e2
                            if err2 < varThreshold * variances[kBase + k] {
                                isShadow = true
                                break
                            }
                        }
                    }
                }

                // Update mixture if alpha > 0
                if alpha > 0 {
                    if matched >= 0 {
                        for k in 0..<maxK {
                            weights[kBase + k] *= (1.0 - alpha)
                        }
                        weights[kBase + matched] += alpha
                        let rho = min(1.0, alpha / max(0.05, weights[kBase + matched]))
                        let mBase = (kBase + matched) * c
                        let d0 = pix.0 - means[mBase]
                        means[mBase] += rho * d0
                        var d2 = d0 * d0
                        if c > 1 {
                            let d1 = pix.1 - means[mBase + 1]
                            means[mBase + 1] += rho * d1
                            d2 += d1 * d1
                        }
                        if c > 2 {
                            let d2c = pix.2 - means[mBase + 2]
                            means[mBase + 2] += rho * d2c
                            d2 += d2c * d2c
                        }
                        let newVar = variances[kBase + matched] + rho * (d2 / Float(c) - variances[kBase + matched])
                        variances[kBase + matched] = max(minVar, min(maxVar, newVar))
                    } else {
                        // Replace lowest-weight component
                        var minK = maxK - 1
                        var minW = weights[kBase + minK]
                        for k in 0..<(maxK - 1) {
                            if weights[kBase + k] < minW {
                                minW = weights[kBase + k]
                                minK = k
                            }
                        }
                        for k in 0..<maxK { weights[kBase + k] *= (1.0 - alpha) }
                        weights[kBase + minK] = alpha
                        variances[kBase + minK] = initVar
                        let mBase = (kBase + minK) * c
                        means[mBase] = pix.0
                        if c > 1 { means[mBase + 1] = pix.1 }
                        if c > 2 { means[mBase + 2] = pix.2 }
                    }

                    // Normalize weights and bubble-sort by weight / sqrt(var) descending
                    var wSum: Float = 0
                    for k in 0..<maxK { wSum += weights[kBase + k] }
                    if wSum > 1e-6 {
                        let invW = 1.0 / wSum
                        for k in 0..<maxK { weights[kBase + k] *= invW }
                    }
                    for a in 0..<(maxK - 1) {
                        for b in (a + 1)..<maxK {
                            let pa = weights[kBase + a] / sqrtf(variances[kBase + a])
                            let pb = weights[kBase + b] / sqrtf(variances[kBase + b])
                            if pb > pa {
                                weights.swapAt(kBase + a, kBase + b)
                                variances.swapAt(kBase + a, kBase + b)
                                let ma = (kBase + a) * c
                                let mb = (kBase + b) * c
                                for ch in 0..<c { means.swapAt(ma + ch, mb + ch) }
                            }
                        }
                    }
                }

                dRow[x] = isBg ? 0 : (isShadow ? 127 : 255)
            }
        }
    }
}

@_cdecl("sr_mog2_create")
public func sr_mog2_create(_ history: Int32, _ varThreshold: Double, _ detectShadows: Int32) -> UnsafeMutableRawPointer? {
    let model = P10MOG2Model(history: Int(history), varThreshold: Float(varThreshold), detectShadows: detectShadows != 0)
    return Unmanaged.passRetained(model).toOpaque()
}

@_cdecl("sr_mog2_apply")
public func sr_mog2_apply(
    _ handle: UnsafeMutableRawPointer?,
    _ srcData: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sd: Int32,
    _ dstData: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ dd: Int32,
    _ learningRate: Double
) -> Int32 {
    guard let handle,
          let src = SRImage(srcData, sw, sh, ss, sc, sd),
          let dst = SRImage(dstData, dw, dh, ds, dc, dd) else {
        return srFail(SRStatus.badArgument, "sr_mog2_apply: invalid arguments")
    }
    guard src.depth == .u8, dst.depth == .u8, dst.channels == 1,
          src.width == dst.width, src.height == dst.height else {
        return srFail(SRStatus.badArgument, "sr_mog2_apply: src must be u8 and dst 1-ch u8 of same size")
    }
    let model = Unmanaged<P10MOG2Model>.fromOpaque(handle).takeUnretainedValue()
    model.apply(src: src, dst: dst, learningRate: learningRate)
    return SRStatus.ok
}

@_cdecl("sr_mog2_free")
public func sr_mog2_free(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard let handle else { return SRStatus.ok }
    Unmanaged<P10MOG2Model>.fromOpaque(handle).release()
    return SRStatus.ok
}

// MARK: - 5. sr_mean_shift (with spatial moments output for CamShift)

@_cdecl("sr_mean_shift")
public func sr_mean_shift(
    _ probData: UnsafeMutableRawPointer?, _ pw: Int32, _ ph: Int32, _ ps: Int32, _ pc: Int32, _ pd: Int32,
    _ winX: UnsafeMutablePointer<Int32>?, _ winY: UnsafeMutablePointer<Int32>?,
    _ winW: UnsafeMutablePointer<Int32>?, _ winH: UnsafeMutablePointer<Int32>?,
    _ maxIter: Int32, _ eps: Double,
    _ outIters: UnsafeMutablePointer<Int32>?,
    _ outM00: UnsafeMutablePointer<Double>?,
    _ outM10: UnsafeMutablePointer<Double>?, _ outM01: UnsafeMutablePointer<Double>?,
    _ outM20: UnsafeMutablePointer<Double>?, _ outM11: UnsafeMutablePointer<Double>?, _ outM02: UnsafeMutablePointer<Double>?
) -> Int32 {
    guard let prob = SRImage(probData, pw, ph, ps, pc, pd),
          let winX, let winY, let winW, let winH else {
        return srFail(SRStatus.badArgument, "sr_mean_shift: invalid arguments")
    }
    let imgW = prob.width
    let imgH = prob.height
    let gray = p10ReadGrayF32(prob)

    var rx = Int(winX.pointee)
    var ry = Int(winY.pointee)
    let rw = max(1, min(imgW, Int(winW.pointee)))
    let rh = max(1, min(imgH, Int(winH.pointee)))
    rx = p10Clamp(rx, 0, max(0, imgW - rw))
    ry = p10Clamp(ry, 0, max(0, imgH - rh))

    let iters = max(1, Int(maxIter))
    let eps2 = eps * eps
    var usedIters = 0
    var m00: Double = 0, m10: Double = 0, m01: Double = 0
    var m20: Double = 0, m11: Double = 0, m02: Double = 0

    for it in 0..<iters {
        usedIters = it + 1
        m00 = 0; m10 = 0; m01 = 0; m20 = 0; m11 = 0; m02 = 0
        for dy in 0..<rh {
            let y = ry + dy
            let off = y * imgW
            let fy = Double(dy)
            for dx in 0..<rw {
                let v = Double(gray[off + rx + dx])
                if v == 0 { continue }
                let fx = Double(dx)
                m00 += v
                m10 += fx * v
                m01 += fy * v
                m20 += fx * fx * v
                m11 += fx * fy * v
                m02 += fy * fy * v
            }
        }
        if m00 <= 1e-12 { break }
        let cx = m10 / m00
        let cy = m01 / m00
        let dxShift = Int(round(cx - Double(rw) * 0.5))
        let dyShift = Int(round(cy - Double(rh) * 0.5))
        let nx = p10Clamp(rx + dxShift, 0, max(0, imgW - rw))
        let ny = p10Clamp(ry + dyShift, 0, max(0, imgH - rh))
        let step2 = Double((nx - rx) * (nx - rx) + (ny - ry) * (ny - ry))
        rx = nx
        ry = ny
        if step2 <= eps2 { break }
    }

    winX.pointee = Int32(rx)
    winY.pointee = Int32(ry)
    winW.pointee = Int32(rw)
    winH.pointee = Int32(rh)
    outIters?.pointee = Int32(usedIters)
    outM00?.pointee = m00
    outM10?.pointee = m10
    outM01?.pointee = m01
    outM20?.pointee = m20
    outM11?.pointee = m11
    outM02?.pointee = m02
    return SRStatus.ok
}

// MARK: - 6. sr_find_transform_ecc

private func p10RunECCLevel(
    _ tmpl: [Float], _ inp: [Float], _ w: Int, _ h: Int,
    _ warp: inout [Double], _ motionType: Int, _ maxIter: Int, _ eps: Double
) -> Double {
    let n = w * h
    // Zero-mean unit-norm template
    var tMean: Double = 0
    for i in 0..<n { tMean += Double(tmpl[i]) }
    tMean /= Double(n)
    var tZero = [Double](repeating: 0, count: n)
    var tNorm2: Double = 0
    for i in 0..<n {
        let v = Double(tmpl[i]) - tMean
        tZero[i] = v
        tNorm2 += v * v
    }
    let tNorm = sqrt(max(1e-12, tNorm2))
    let invTNorm = 1.0 / tNorm
    for i in 0..<n { tZero[i] *= invTNorm }

    // Input image gradients
    var gxImg = [Float](repeating: 0, count: n)
    var gyImg = [Float](repeating: 0, count: n)
    for y in 0..<h {
        let ym = p10Clamp(y - 1, 0, h - 1) * w
        let y0 = y * w
        let yp = p10Clamp(y + 1, 0, h - 1) * w
        for x in 0..<w {
            let xm = p10Clamp(x - 1, 0, w - 1)
            let xp = p10Clamp(x + 1, 0, w - 1)
            gxImg[y0 + x] = 0.5 * (inp[y0 + xp] - inp[y0 + xm])
            gyImg[y0 + x] = 0.5 * (inp[yp + x] - inp[ym + x])
        }
    }

    let nParams = (motionType == 0) ? 2 : ((motionType == 1) ? 3 : 6)
    var warped = [Double](repeating: 0, count: n)
    var lastCorr: Double = 0

    for _ in 0..<maxIter {
        let w00 = warp[0], w01 = warp[1], w02 = warp[2]
        let w10 = warp[3], w11 = warp[4], w12 = warp[5]

        var wMean: Double = 0
        var validCount = 0
        for y in 0..<h {
            let fy = Double(y)
            let off = y * w
            for x in 0..<w {
                let fx = Double(x)
                let sx = Float(w00 * fx + w01 * fy + w02)
                let sy = Float(w10 * fx + w11 * fy + w12)
                let v = Double(p10Sample(inp, w, h, sx, sy))
                warped[off + x] = v
                wMean += v
                validCount += 1
            }
        }
        wMean /= Double(max(1, validCount))

        var wNorm2: Double = 0
        var dotTW: Double = 0
        for i in 0..<n {
            let v = warped[i] - wMean
            warped[i] = v
            wNorm2 += v * v
            dotTW += tZero[i] * v
        }
        let wNorm = sqrt(max(1e-12, wNorm2))
        lastCorr = dotTW / wNorm
        let invWNorm = 1.0 / wNorm

        // Build Hessian H = J^T J and RHS = J^T (rho * tZero - wZero/wNorm)
        var H = [Double](repeating: 0, count: nParams * nParams)
        var gVec = [Double](repeating: 0, count: nParams)
        var jRow = [Double](repeating: 0, count: nParams)
        let theta = atan2(w10, w00)
        let cosT = cos(theta)
        let sinT = sin(theta)

        for y in 1..<(h - 1) {
            let fy = Double(y)
            let off = y * w
            for x in 1..<(w - 1) {
                let fx = Double(x)
                let sx = Float(w00 * fx + w01 * fy + w02)
                let sy = Float(w10 * fx + w11 * fy + w12)
                let gx = Double(p10Sample(gxImg, w, h, sx, sy)) * invWNorm
                let gy = Double(p10Sample(gyImg, w, h, sx, sy)) * invWNorm
                if motionType == 0 {
                    jRow[0] = gx
                    jRow[1] = gy
                } else if motionType == 1 {
                    jRow[0] = gx * (-sinT * fx - cosT * fy) + gy * (cosT * fx - sinT * fy)
                    jRow[1] = gx
                    jRow[2] = gy
                } else {
                    jRow[0] = gx * fx
                    jRow[1] = gx * fy
                    jRow[2] = gx
                    jRow[3] = gy * fx
                    jRow[4] = gy * fy
                    jRow[5] = gy
                }

                let errVal = tZero[off + x] - warped[off + x] * invWNorm
                for r in 0..<nParams {
                    let jr = jRow[r]
                    gVec[r] += jr * errVal
                    for c in r..<nParams {
                        H[r * nParams + c] += jr * jRow[c]
                    }
                }
            }
        }
        for r in 0..<nParams {
            for c in 0..<r { H[r * nParams + c] = H[c * nParams + r] }
            H[r * nParams + r] += 1e-6
        }

        if !p10SolveLinearSystem(&H, &gVec, nParams) { break }

        var stepNorm: Double = 0
        if motionType == 0 {
            warp[2] += gVec[0]
            warp[5] += gVec[1]
            stepNorm = sqrt(gVec[0] * gVec[0] + gVec[1] * gVec[1])
        } else if motionType == 1 {
            let newTheta = theta + gVec[0]
            warp[0] = cos(newTheta)
            warp[1] = -sin(newTheta)
            warp[2] += gVec[1]
            warp[3] = sin(newTheta)
            warp[4] = cos(newTheta)
            warp[5] += gVec[2]
            stepNorm = sqrt(gVec[0] * gVec[0] + gVec[1] * gVec[1] + gVec[2] * gVec[2])
        } else {
            for k in 0..<6 {
                warp[k] += gVec[k]
                stepNorm += gVec[k] * gVec[k]
            }
            stepNorm = sqrt(stepNorm)
        }
        if stepNorm < eps { break }
    }
    return lastCorr
}

@_cdecl("sr_find_transform_ecc")
public func sr_find_transform_ecc(
    _ tmplData: UnsafeMutableRawPointer?, _ tw: Int32, _ th: Int32, _ ts: Int32, _ tc: Int32, _ td: Int32,
    _ inpData: UnsafeMutableRawPointer?, _ iw: Int32, _ ih: Int32, _ is_: Int32, _ ic: Int32, _ id: Int32,
    _ warpMat: UnsafeMutablePointer<Float>?,
    _ motionType: Int32,
    _ maxIter: Int32, _ eps: Double,
    _ outCorr: UnsafeMutablePointer<Double>?
) -> Int32 {
    guard let tmpl = SRImage(tmplData, tw, th, ts, tc, td),
          let inp = SRImage(inpData, iw, ih, is_, ic, id),
          tmpl.width == inp.width, tmpl.height == inp.height,
          let warpMat else {
        return srFail(SRStatus.badArgument, "sr_find_transform_ecc: invalid arguments")
    }
    let w = tmpl.width
    let h = tmpl.height
    if w < 6 || h < 6 { return srFail(SRStatus.badArgument, "sr_find_transform_ecc: image too small") }

    let mType = Int(motionType)
    let iters = max(1, Int(maxIter))
    let tGray = p10ReadGrayF32(tmpl)
    let iGray = p10ReadGrayF32(inp)

    var warp = [Double](repeating: 0, count: 6)
    for k in 0..<6 { warp[k] = Double(warpMat[k]) }

    // Multi-level coarse-to-fine pyramid for wider basin of convergence
    var tPyr: [([Float], Int, Int)] = [(tGray, w, h)]
    var iPyr: [([Float], Int, Int)] = [(iGray, w, h)]
    for _ in 0..<2 {
        let lt = tPyr.last!
        if lt.1 < 32 || lt.2 < 32 { break }
        tPyr.append(p10PyrDown(lt.0, lt.1, lt.2))
        let li = iPyr.last!
        iPyr.append(p10PyrDown(li.0, li.1, li.2))
    }

    let topLvl = tPyr.count - 1
    if topLvl > 0 {
        let downScale = pow(0.5, Double(topLvl))
        warp[2] *= downScale
        warp[5] *= downScale
    }

    var corr: Double = 0
    for lvl in stride(from: topLvl, through: 0, by: -1) {
        let (tl, lw, lh) = tPyr[lvl]
        let (il, _, _) = iPyr[lvl]
        corr = p10RunECCLevel(tl, il, lw, lh, &warp, mType, iters, eps)
        if lvl > 0 {
            warp[2] *= 2.0
            warp[5] *= 2.0
        }
    }

    for k in 0..<6 { warpMat[k] = Float(warp[k]) }
    outCorr?.pointee = corr
    return SRStatus.ok
}
