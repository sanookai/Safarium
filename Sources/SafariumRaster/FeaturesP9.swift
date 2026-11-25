// SafariumRaster — Phase 9: Features2D (Harris, Shi-Tomasi, GFTT, CornerSubPix, FAST, ORB, BFMatcher)
// 100% Apple-native Swift + Accelerate.

import Accelerate
import Foundation

// MARK: - Private Grayscale & Filtering Helpers

private func p9ReadGrayF32(_ img: SRImage, scaleU8: Float = 1.0 / 255.0) -> [Float] {
    let w = img.width
    let h = img.height
    let c = img.channels
    var out = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
        let rowPtr = img.row(y)
        let rowOff = y * w
        switch img.depth {
        case .u8:
            let p = rowPtr.assumingMemoryBound(to: UInt8.self)
            if c == 1 {
                for x in 0..<w {
                    out[rowOff + x] = Float(p[x]) * scaleU8
                }
            } else {
                for x in 0..<w {
                    let b = Float(p[x * c])
                    let g = Float(p[x * c + 1])
                    let r = Float(p[x * c + 2])
                    out[rowOff + x] = (0.114 * b + 0.587 * g + 0.299 * r) * scaleU8
                }
            }
        case .u16:
            let p = rowPtr.assumingMemoryBound(to: UInt16.self)
            let s: Float = scaleU8 == 1.0 ? 1.0 : (1.0 / 65535.0)
            if c == 1 {
                for x in 0..<w {
                    out[rowOff + x] = Float(p[x]) * s
                }
            } else {
                for x in 0..<w {
                    let b = Float(p[x * c])
                    let g = Float(p[x * c + 1])
                    let r = Float(p[x * c + 2])
                    out[rowOff + x] = (0.114 * b + 0.587 * g + 0.299 * r) * s
                }
            }
        case .s32:
            let p = rowPtr.assumingMemoryBound(to: Int32.self)
            if c == 1 {
                for x in 0..<w { out[rowOff + x] = Float(p[x]) }
            } else {
                for x in 0..<w {
                    let b = Float(p[x * c])
                    let g = Float(p[x * c + 1])
                    let r = Float(p[x * c + 2])
                    out[rowOff + x] = 0.114 * b + 0.587 * g + 0.299 * r
                }
            }
        case .f32:
            let p = rowPtr.assumingMemoryBound(to: Float.self)
            if c == 1 {
                for x in 0..<w { out[rowOff + x] = p[x] }
            } else {
                for x in 0..<w {
                    let b = p[x * c]
                    let g = p[x * c + 1]
                    let r = p[x * c + 2]
                    out[rowOff + x] = 0.114 * b + 0.587 * g + 0.299 * r
                }
            }
        }
    }
    return out
}

private func p9ReadGrayU8(_ img: SRImage) -> [UInt8] {
    let w = img.width
    let h = img.height
    let c = img.channels
    var out = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        let rowPtr = img.row(y)
        let rowOff = y * w
        switch img.depth {
        case .u8:
            let p = rowPtr.assumingMemoryBound(to: UInt8.self)
            if c == 1 {
                for x in 0..<w { out[rowOff + x] = p[x] }
            } else {
                for x in 0..<w {
                    let b = Double(p[x * c])
                    let g = Double(p[x * c + 1])
                    let r = Double(p[x * c + 2])
                    out[rowOff + x] = srSatU8(0.114 * b + 0.587 * g + 0.299 * r)
                }
            }
        case .f32:
            let p = rowPtr.assumingMemoryBound(to: Float.self)
            if c == 1 {
                for x in 0..<w { out[rowOff + x] = srSatU8(Double(p[x])) }
            } else {
                for x in 0..<w {
                    let b = Double(p[x * c])
                    let g = Double(p[x * c + 1])
                    let r = Double(p[x * c + 2])
                    out[rowOff + x] = srSatU8(0.114 * b + 0.587 * g + 0.299 * r)
                }
            }
        default:
            let f = p9ReadGrayF32(img, scaleU8: 1.0)
            for i in 0..<(w * h) { out[i] = srSatU8(Double(f[i])) }
            return out
        }
    }
    return out
}

@inline(__always)
private func p9Reflect101(_ i: Int, _ n: Int) -> Int {
    if n <= 1 { return 0 }
    var v = i
    while v < 0 || v >= n {
        if v < 0 { v = -v }
        if v >= n { v = 2 * n - 2 - v }
    }
    return v
}

private func p9Sobel(_ src: [Float], _ w: Int, _ h: Int, _ ksize: Int) -> ([Float], [Float]) {
    var gx = [Float](repeating: 0, count: w * h)
    var gy = [Float](repeating: 0, count: w * h)
    let useScharr = (ksize < 0)
    let w0: Float = useScharr ? 3.0 : 1.0
    let w1: Float = useScharr ? 10.0 : 2.0
    let scale: Float = useScharr ? (1.0 / 32.0) : (1.0 / 4.0)

    for y in 0..<h {
        let ym1 = p9Reflect101(y - 1, h) * w
        let y0 = y * w
        let yp1 = p9Reflect101(y + 1, h) * w
        for x in 0..<w {
            let xm1 = p9Reflect101(x - 1, w)
            let xp1 = p9Reflect101(x + 1, w)

            let tl = src[ym1 + xm1]
            let tc = src[ym1 + x]
            let tr = src[ym1 + xp1]
            let ml = src[y0 + xm1]
            let mr = src[y0 + xp1]
            let bl = src[yp1 + xm1]
            let bc = src[yp1 + x]
            let br = src[yp1 + xp1]

            let dxTop = tr - tl
            let dxMid = mr - ml
            let dxBot = br - bl
            gx[y0 + x] = (w0 * dxTop + w1 * dxMid + w0 * dxBot) * scale

            let dyLeft = bl - tl
            let dyMid = bc - tc
            let dyRight = br - tr
            gy[y0 + x] = (w0 * dyLeft + w1 * dyMid + w0 * dyRight) * scale
        }
    }
    return (gx, gy)
}

private func p9BoxFilter(_ src: [Float], _ w: Int, _ h: Int, _ blockSize: Int) -> [Float] {
    let b = max(1, blockSize)
    let rLeft = b / 2
    let rRight = b - 1 - rLeft
    let invB = 1.0 / Float(b)

    var tmp = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
        let rowOff = y * w
        for x in 0..<w {
            var acc: Float = 0
            for dx in -rLeft...rRight {
                acc += src[rowOff + p9Reflect101(x + dx, w)]
            }
            tmp[rowOff + x] = acc * invB
        }
    }

    var dst = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
        let rowOff = y * w
        for x in 0..<w {
            var acc: Float = 0
            for dy in -rLeft...rRight {
                acc += tmp[p9Reflect101(y + dy, h) * w + x]
            }
            dst[rowOff + x] = acc * invB
        }
    }
    return dst
}

private func p9StructureTensor(_ gray: [Float], _ w: Int, _ h: Int, _ blockSize: Int, _ ksize: Int) -> ([Float], [Float], [Float]) {
    let (gx, gy) = p9Sobel(gray, w, h, ksize)
    let n = w * h
    var gxx = [Float](repeating: 0, count: n)
    var gxy = [Float](repeating: 0, count: n)
    var gyy = [Float](repeating: 0, count: n)
    vDSP_vmul(gx, 1, gx, 1, &gxx, 1, vDSP_Length(n))
    vDSP_vmul(gx, 1, gy, 1, &gxy, 1, vDSP_Length(n))
    vDSP_vmul(gy, 1, gy, 1, &gyy, 1, vDSP_Length(n))
    let sxx = p9BoxFilter(gxx, w, h, blockSize)
    let sxy = p9BoxFilter(gxy, w, h, blockSize)
    let syy = p9BoxFilter(gyy, w, h, blockSize)
    return (sxx, sxy, syy)
}

private func p9WriteF32(_ src: [Float], to dst: SRImage) {
    let w = dst.width
    let h = dst.height
    for y in 0..<h {
        let row = dst.row(y).assumingMemoryBound(to: Float.self)
        let off = y * w
        for x in 0..<w {
            row[x] = src[off + x]
        }
    }
}

// MARK: - 1. sr_corner_harris

@_cdecl("sr_corner_harris")
public func sr_corner_harris(
    _ srcData: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sd: Int32,
    _ dstData: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ dd: Int32,
    _ blockSize: Int32, _ ksize: Int32, _ k: Double, _ borderType: Int32
) -> Int32 {
    guard let src = SRImage(srcData, sw, sh, ss, sc, sd),
          let dst = SRImage(dstData, dw, dh, ds, dc, dd) else {
        return srFail(SRStatus.badArgument, "sr_corner_harris: invalid image")
    }
    guard src.width == dst.width, src.height == dst.height, dst.channels == 1, dst.depth == .f32 else {
        return srFail(SRStatus.badArgument, "sr_corner_harris: dst must be 1-ch float32 matching src size")
    }
    if src.width == 0 || src.height == 0 { return SRStatus.ok }
    let w = src.width
    let h = src.height
    let gray = p9ReadGrayF32(src)
    let (sxx, sxy, syy) = p9StructureTensor(gray, w, h, Int(blockSize), Int(ksize))
    let kf = Float(k)
    let n = w * h
    var resp = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let a = sxx[i]
        let b = sxy[i]
        let c = syy[i]
        let det = a * c - b * b
        let tr = a + c
        resp[i] = det - kf * tr * tr
    }
    p9WriteF32(resp, to: dst)
    return SRStatus.ok
}

// MARK: - 2. sr_corner_min_eigen_val

@_cdecl("sr_corner_min_eigen_val")
public func sr_corner_min_eigen_val(
    _ srcData: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sd: Int32,
    _ dstData: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ dd: Int32,
    _ blockSize: Int32, _ ksize: Int32, _ borderType: Int32
) -> Int32 {
    guard let src = SRImage(srcData, sw, sh, ss, sc, sd),
          let dst = SRImage(dstData, dw, dh, ds, dc, dd) else {
        return srFail(SRStatus.badArgument, "sr_corner_min_eigen_val: invalid image")
    }
    guard src.width == dst.width, src.height == dst.height, dst.channels == 1, dst.depth == .f32 else {
        return srFail(SRStatus.badArgument, "sr_corner_min_eigen_val: dst must be 1-ch float32 matching src size")
    }
    if src.width == 0 || src.height == 0 { return SRStatus.ok }
    let w = src.width
    let h = src.height
    let gray = p9ReadGrayF32(src)
    let (sxx, sxy, syy) = p9StructureTensor(gray, w, h, Int(blockSize), Int(ksize))
    let n = w * h
    var resp = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let a = sxx[i]
        let b = sxy[i]
        let c = syy[i]
        let diff = a - c
        let disc = sqrtf(max(0.0, diff * diff + 4.0 * b * b))
        resp[i] = 0.5 * ((a + c) - disc)
    }
    p9WriteF32(resp, to: dst)
    return SRStatus.ok
}

// MARK: - 3. sr_good_features_to_track

@_cdecl("sr_good_features_to_track")
public func sr_good_features_to_track(
    _ srcData: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sd: Int32,
    _ maskData: UnsafeMutableRawPointer?, _ mw: Int32, _ mh: Int32, _ ms: Int32, _ mc: Int32, _ md: Int32,
    _ maxCorners: Int32, _ qualityLevel: Double, _ minDistance: Double,
    _ blockSize: Int32, _ useHarris: Int32, _ k: Double,
    _ outXY: UnsafeMutablePointer<Float>?, _ outCap: Int32, _ outCount: UnsafeMutablePointer<Int32>?
) -> Int32 {
    guard let src = SRImage(srcData, sw, sh, ss, sc, sd), let outCount else {
        return srFail(SRStatus.badArgument, "sr_good_features_to_track: invalid arguments")
    }
    let w = src.width
    let h = src.height
    if w < 3 || h < 3 {
        outCount.pointee = 0
        return SRStatus.ok
    }

    var maskImg: SRImage? = nil
    if maskData != nil {
        guard let m = SRImage(maskData, mw, mh, ms, mc, md), m.width == w, m.height == h, m.channels == 1, m.depth == .u8 else {
            return srFail(SRStatus.badArgument, "sr_good_features_to_track: invalid mask")
        }
        maskImg = m
    }

    let gray = p9ReadGrayF32(src)
    let (sxx, sxy, syy) = p9StructureTensor(gray, w, h, max(1, Int(blockSize)), 3)
    let n = w * h
    var resp = [Float](repeating: 0, count: n)
    var maxVal: Float = 0
    if useHarris != 0 {
        let kf = Float(k)
        for i in 0..<n {
            let a = sxx[i], b = sxy[i], c = syy[i]
            let tr = a + c
            let v = (a * c - b * b) - kf * tr * tr
            resp[i] = v
            if v > maxVal { maxVal = v }
        }
    } else {
        for i in 0..<n {
            let a = sxx[i], b = sxy[i], c = syy[i]
            let diff = a - c
            let disc = sqrtf(max(0.0, diff * diff + 4.0 * b * b))
            let v = 0.5 * ((a + c) - disc)
            resp[i] = v
            if v > maxVal { maxVal = v }
        }
    }

    let thresh = maxVal * Float(qualityLevel)
    if maxVal <= 0 || thresh <= 0 {
        outCount.pointee = 0
        return SRStatus.ok
    }

    var candidates: [(x: Int, y: Int, score: Float)] = []
    candidates.reserveCapacity(1024)

    for y in 1..<(h - 1) {
        let maskRow = maskImg?.row(y).assumingMemoryBound(to: UInt8.self)
        let rowOff = y * w
        for x in 1..<(w - 1) {
            if let mr = maskRow, mr[x] == 0 { continue }
            let v = resp[rowOff + x]
            if v <= thresh { continue }
            var isMax = true
            for dy in -1...1 {
                let rOff = (y + dy) * w
                for dx in -1...1 {
                    if dx == 0 && dy == 0 { continue }
                    if resp[rOff + x + dx] > v {
                        isMax = false
                        break
                    }
                }
                if !isMax { break }
            }
            if isMax {
                candidates.append((x, y, v))
            }
        }
    }

    candidates.sort { $0.score > $1.score }

    let limit = maxCorners > 0 ? min(Int(maxCorners), Int(outCap)) : Int(outCap)
    var accepted: [(x: Int, y: Int)] = []
    accepted.reserveCapacity(min(candidates.count, max(16, limit)))

    if minDistance >= 1.0 {
        let cellSize = max(1, Int(ceil(minDistance)))
        let gridW = (w + cellSize - 1) / cellSize
        let gridH = (h + cellSize - 1) / cellSize
        var grid = [[(Int, Int)]](repeating: [], count: gridW * gridH)
        let minDist2 = minDistance * minDistance

        for cand in candidates {
            if accepted.count >= limit { break }
            let gx = cand.x / cellSize
            let gy = cand.y / cellSize
            let x0 = max(0, gx - 1)
            let x1 = min(gridW - 1, gx + 1)
            let y0 = max(0, gy - 1)
            let y1 = min(gridH - 1, gy + 1)
            var tooClose = false
            for cy in y0...y1 {
                for cx in x0...x1 {
                    for pt in grid[cy * gridW + cx] {
                        let dx = Double(cand.x - pt.0)
                        let dy = Double(cand.y - pt.1)
                        if dx * dx + dy * dy < minDist2 {
                            tooClose = true
                            break
                        }
                    }
                    if tooClose { break }
                }
                if tooClose { break }
            }
            if !tooClose {
                grid[gy * gridW + gx].append((cand.x, cand.y))
                accepted.append((cand.x, cand.y))
            }
        }
    } else {
        for cand in candidates {
            if accepted.count >= limit { break }
            accepted.append((cand.x, cand.y))
        }
    }

    if let outXY {
        for (i, pt) in accepted.enumerated() {
            outXY[2 * i] = Float(pt.x)
            outXY[2 * i + 1] = Float(pt.y)
        }
    }
    outCount.pointee = Int32(accepted.count)
    return SRStatus.ok
}

// MARK: - 4. sr_corner_sub_pix

@inline(__always)
private func p9SampleBilinear(_ img: [Float], _ w: Int, _ h: Int, _ x: Float, _ y: Float) -> Float {
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

@_cdecl("sr_corner_sub_pix")
public func sr_corner_sub_pix(
    _ srcData: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sd: Int32,
    _ ptsXY: UnsafeMutablePointer<Float>?, _ numPts: Int32,
    _ winW: Int32, _ winH: Int32, _ zeroW: Int32, _ zeroH: Int32,
    _ maxIter: Int32, _ eps: Double
) -> Int32 {
    guard let src = SRImage(srcData, sw, sh, ss, sc, sd), let ptsXY else {
        return srFail(SRStatus.badArgument, "sr_corner_sub_pix: invalid arguments")
    }
    let w = src.width
    let h = src.height
    let nPts = Int(numPts)
    if nPts <= 0 || w < 3 || h < 3 { return SRStatus.ok }

    let ww = max(1, Int(winW))
    let wh = max(1, Int(winH))
    let zw = Int(zeroW)
    let zh = Int(zeroH)
    let iters = max(1, Int(maxIter))
    let eps2 = Float(eps * eps)

    let gray = p9ReadGrayF32(src, scaleU8: 1.0)
    let patchW = 2 * ww + 1
    let patchH = 2 * wh + 1
    var mask = [Float](repeating: 0, count: patchW * patchH)
    for dy in -wh...wh {
        let wy = expf(-Float(dy * dy) / Float(wh * wh))
        for dx in -ww...ww {
            if zw >= 0 && zh >= 0 && abs(dx) <= zw && abs(dy) <= zh {
                mask[(dy + wh) * patchW + (dx + ww)] = 0
            } else {
                let wx = expf(-Float(dx * dx) / Float(ww * ww))
                mask[(dy + wh) * patchW + (dx + ww)] = wx * wy
            }
        }
    }

    for i in 0..<nPts {
        let initX = ptsXY[2 * i]
        let initY = ptsXY[2 * i + 1]
        var cx = initX
        var cy = initY

        for _ in 0..<iters {
            var a: Double = 0
            var b: Double = 0
            var c: Double = 0
            var bb1: Double = 0
            var bb2: Double = 0

            for dy in -wh...wh {
                for dx in -ww...ww {
                    let mw = Double(mask[(dy + wh) * patchW + (dx + ww)])
                    if mw == 0 { continue }
                    let sx = cx + Float(dx)
                    let sy = cy + Float(dy)
                    let gx = Double(p9SampleBilinear(gray, w, h, sx + 1.0, sy) - p9SampleBilinear(gray, w, h, sx - 1.0, sy)) * 0.5
                    let gy = Double(p9SampleBilinear(gray, w, h, sx, sy + 1.0) - p9SampleBilinear(gray, w, h, sx, sy - 1.0)) * 0.5
                    let gxx = gx * gx * mw
                    let gxy = gx * gy * mw
                    let gyy = gy * gy * mw
                    a += gxx
                    b += gxy
                    c += gyy
                    let px = Double(dx)
                    let py = Double(dy)
                    bb1 += gxx * px + gxy * py
                    bb2 += gxy * px + gyy * py
                }
            }

            let det = a * c - b * b
            if abs(det) < 1e-12 { break }
            let invDet = 1.0 / det
            let dxStep = Float((c * bb1 - b * bb2) * invDet)
            let dyStep = Float((a * bb2 - b * bb1) * invDet)
            let nx = cx + dxStep
            let ny = cy + dyStep

            if abs(nx - initX) > Float(ww) || abs(ny - initY) > Float(wh) {
                cx = initX
                cy = initY
                break
            }
            cx = nx
            cy = ny
            if dxStep * dxStep + dyStep * dyStep < eps2 { break }
        }

        ptsXY[2 * i] = cx
        ptsXY[2 * i + 1] = cy
    }
    return SRStatus.ok
}

// MARK: - 5. sr_fast_detect (FAST-9)

private let p9FastCircleX: [Int] = [0, 1, 2, 3, 3, 3, 2, 1, 0, -1, -2, -3, -3, -3, -2, -1]
private let p9FastCircleY: [Int] = [-3, -3, -2, -1, 0, 1, 2, 3, 3, 3, 2, 1, 0, -1, -2, -3]

private func p9Fast9Score(_ gray: [UInt8], _ w: Int, _ x: Int, _ y: Int, _ threshold: Int) -> Int {
    let center = Int(gray[y * w + x])
    let hi = center + threshold
    let lo = center - threshold

    // Quick reject using 4 compass pixels (indices 0, 4, 8, 12)
    let p0 = Int(gray[(y - 3) * w + x])
    let p4 = Int(gray[y * w + (x + 3)])
    let p8 = Int(gray[(y + 3) * w + x])
    let p12 = Int(gray[y * w + (x - 3)])

    var countHi = 0
    if p0 > hi { countHi += 1 }
    if p4 > hi { countHi += 1 }
    if p8 > hi { countHi += 1 }
    if p12 > hi { countHi += 1 }

    var countLo = 0
    if p0 < lo { countLo += 1 }
    if p4 < lo { countLo += 1 }
    if p8 < lo { countLo += 1 }
    if p12 < lo { countLo += 1 }

    if countHi < 3 && countLo < 3 { return 0 }

    var d = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    withUnsafeMutablePointer(to: &d) { ptr in
        ptr.withMemoryRebound(to: Int.self, capacity: 16) { arr in
            for k in 0..<16 {
                let px = x + p9FastCircleX[k]
                let py = y + p9FastCircleY[k]
                arr[k] = Int(gray[py * w + px]) - center
            }
        }
    }

    var bestBright = 0
    var bestDark = 0
    withUnsafePointer(to: d) { ptr in
        ptr.withMemoryRebound(to: Int.self, capacity: 16) { arr in
            for start in 0..<16 {
                var minPos = 256
                var minNeg = 256
                for j in 0..<9 {
                    let v = arr[(start + j) & 15]
                    if v < minPos { minPos = v }
                    if -v < minNeg { minNeg = -v }
                }
                if minPos > bestBright { bestBright = minPos }
                if minNeg > bestDark { bestDark = minNeg }
            }
        }
    }

    let score = max(bestBright, bestDark)
    return score > threshold ? score - 1 : 0
}

private func p9DetectFast9(_ gray: [UInt8], _ w: Int, _ h: Int, _ threshold: Int, _ nms: Bool, _ border: Int = 3) -> [(x: Int, y: Int, score: Int)] {
    let b = max(3, border)
    if w <= 2 * b || h <= 2 * b { return [] }
    let t = max(1, threshold)
    var scores = [Int](repeating: 0, count: w * h)
    var raw: [(x: Int, y: Int, score: Int)] = []
    raw.reserveCapacity(1024)

    for y in b..<(h - b) {
        let rowOff = y * w
        for x in b..<(w - b) {
            let s = p9Fast9Score(gray, w, x, y, t)
            if s > 0 {
                scores[rowOff + x] = s
                raw.append((x, y, s))
            }
        }
    }

    if !nms { return raw }

    var kept: [(x: Int, y: Int, score: Int)] = []
    kept.reserveCapacity(raw.count / 2 + 1)
    for kp in raw {
        let s = kp.score
        let x = kp.x
        let y = kp.y
        if s >= scores[(y - 1) * w + (x - 1)] &&
           s >= scores[(y - 1) * w + x] &&
           s >= scores[(y - 1) * w + (x + 1)] &&
           s >= scores[y * w + (x - 1)] &&
           s > scores[y * w + (x + 1)] &&
           s > scores[(y + 1) * w + (x - 1)] &&
           s > scores[(y + 1) * w + x] &&
           s > scores[(y + 1) * w + (x + 1)] {
            kept.append(kp)
        }
    }
    return kept
}

@_cdecl("sr_fast_detect")
public func sr_fast_detect(
    _ srcData: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sd: Int32,
    _ threshold: Int32, _ nonmaxSuppression: Int32,
    _ outXYScore: UnsafeMutablePointer<Float>?, _ outCap: Int32, _ outCount: UnsafeMutablePointer<Int32>?
) -> Int32 {
    guard let src = SRImage(srcData, sw, sh, ss, sc, sd), let outCount else {
        return srFail(SRStatus.badArgument, "sr_fast_detect: invalid arguments")
    }
    let gray = p9ReadGrayU8(src)
    let kps = p9DetectFast9(gray, src.width, src.height, Int(threshold), nonmaxSuppression != 0)
    let n = min(kps.count, max(0, Int(outCap)))
    if let outXYScore {
        for i in 0..<n {
            outXYScore[3 * i] = Float(kps[i].x)
            outXYScore[3 * i + 1] = Float(kps[i].y)
            outXYScore[3 * i + 2] = Float(kps[i].score)
        }
    }
    outCount.pointee = Int32(n)
    return SRStatus.ok
}

// MARK: - 6. sr_orb_detect_compute (Multi-scale FAST + Harris + IC Angle + Rotated BRIEF-256)

private let p9OrbPattern: [(Int, Int, Int, Int)] = {
    // Deterministic 256 test pairs inside [-12, 12] x [-12, 12] (well-distributed Gaussian-like spread).
    var state: UInt64 = 0x5EED_012B_C0DE_2561
    func nextInt(_ range: Int) -> Int {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Int(state % UInt64(range))
    }
    func sampleCoord() -> Int {
        // Triangular distribution in [-12, 12] centered at 0 for rotational stability.
        let a = nextInt(13) - 6
        let b = nextInt(13) - 6
        return a + b
    }
    var pairs: [(Int, Int, Int, Int)] = []
    pairs.reserveCapacity(256)
    for _ in 0..<256 {
        var x1 = sampleCoord()
        var y1 = sampleCoord()
        var x2 = sampleCoord()
        var y2 = sampleCoord()
        if x1 == x2 && y1 == y2 {
            x2 = min(12, x1 + 3)
        }
        pairs.append((x1, y1, x2, y2))
    }
    return pairs
}()

private func p9ResizeGrayU8(_ src: [UInt8], _ sw: Int, _ sh: Int, _ dw: Int, _ dh: Int) -> [UInt8] {
    var dst = [UInt8](repeating: 0, count: dw * dh)
    let sx = Float(sw) / Float(dw)
    let sy = Float(sh) / Float(dh)
    for y in 0..<dh {
        let fy = (Float(y) + 0.5) * sy - 0.5
        let y0 = max(0, min(sh - 1, Int(floorf(fy))))
        let y1 = min(sh - 1, y0 + 1)
        let wy = max(0.0, min(1.0, fy - Float(y0)))
        for x in 0..<dw {
            let fx = (Float(x) + 0.5) * sx - 0.5
            let x0 = max(0, min(sw - 1, Int(floorf(fx))))
            let x1 = min(sw - 1, x0 + 1)
            let wx = max(0.0, min(1.0, fx - Float(x0)))
            let v00 = Float(src[y0 * sw + x0])
            let v10 = Float(src[y0 * sw + x1])
            let v01 = Float(src[y1 * sw + x0])
            let v11 = Float(src[y1 * sw + x1])
            let top = v00 + wx * (v10 - v00)
            let bot = v01 + wx * (v11 - v01)
            let val = top + wy * (bot - top)
            dst[y * dw + x] = srSatU8(Double(val))
        }
    }
    return dst
}

private func p9Blur5x5(_ src: [UInt8], _ w: Int, _ h: Int) -> [Float] {
    let k: [Float] = [1, 4, 6, 4, 1]
    let inv: Float = 1.0 / 16.0
    var tmp = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
        let off = y * w
        for x in 0..<w {
            var s: Float = 0
            for d in -2...2 {
                s += k[d + 2] * Float(src[off + p9Reflect101(x + d, w)])
            }
            tmp[off + x] = s * inv
        }
    }
    var dst = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
        let off = y * w
        for x in 0..<w {
            var s: Float = 0
            for d in -2...2 {
                s += k[d + 2] * tmp[p9Reflect101(y + d, h) * w + x]
            }
            dst[off + x] = s * inv
        }
    }
    return dst
}

private func p9HarrisScore7x7(_ gray: [UInt8], _ w: Int, _ h: Int, _ cx: Int, _ cy: Int) -> Float {
    var a: Float = 0
    var b: Float = 0
    var c: Float = 0
    for dy in -3...3 {
        let y = cy + dy
        for dx in -3...3 {
            let x = cx + dx
            let ix = Float(Int(gray[y * w + x + 1]) - Int(gray[y * w + x - 1]))
            let iy = Float(Int(gray[(y + 1) * w + x]) - Int(gray[(y - 1) * w + x]))
            a += ix * ix
            b += ix * iy
            c += iy * iy
        }
    }
    let scale: Float = 1.0 / (255.0 * 255.0 * 4.0 * 49.0)
    a *= scale
    b *= scale
    c *= scale
    let tr = a + c
    return (a * c - b * b) - 0.04 * tr * tr
}

private func p9IntensityCentroidAngle(_ gray: [UInt8], _ w: Int, _ cx: Int, _ cy: Int) -> Float {
    let r = 15
    let r2 = r * r
    var m10: Float = 0
    var m01: Float = 0
    for dy in -r...r {
        let y = cy + dy
        let rowOff = y * w
        let maxDx = Int(sqrtf(Float(r2 - dy * dy)))
        for dx in -maxDx...maxDx {
            let val = Float(gray[rowOff + cx + dx])
            m10 += Float(dx) * val
            m01 += Float(dy) * val
        }
    }
    var deg = atan2f(m01, m10) * (180.0 / Float.pi)
    if deg < 0 { deg += 360.0 }
    return deg
}

@_cdecl("sr_orb_detect_compute")
public func sr_orb_detect_compute(
    _ srcData: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sd: Int32,
    _ nFeatures: Int32, _ scaleFactor: Float, _ nLevels: Int32, _ edgeThreshold: Int32, _ fastThreshold: Int32,
    _ outKpts: UnsafeMutablePointer<Float>?,
    _ outDesc: UnsafeMutablePointer<UInt8>?,
    _ outCap: Int32,
    _ outCount: UnsafeMutablePointer<Int32>?
) -> Int32 {
    guard let src = SRImage(srcData, sw, sh, ss, sc, sd), let outCount else {
        return srFail(SRStatus.badArgument, "sr_orb_detect_compute: invalid arguments")
    }
    let baseW = src.width
    let baseH = src.height
    let maxFeat = min(max(1, Int(nFeatures)), max(0, Int(outCap)))
    if maxFeat == 0 || baseW < 36 || baseH < 36 {
        outCount.pointee = 0
        return SRStatus.ok
    }

    let sf = scaleFactor > 1.01 ? scaleFactor : 1.2
    let levels = max(1, min(12, Int(nLevels)))
    let edge = max(16, Int(edgeThreshold))
    let fThresh = max(5, Int(fastThreshold))

    let baseGray = p9ReadGrayU8(src)

    // Compute per-level budgets proportional to 1 / sf^(2*lvl)
    var invScales = [Float](repeating: 1.0, count: levels)
    var scaleSum: Float = 0
    for lvl in 0..<levels {
        let s = powf(sf, Float(lvl))
        let wLvl = Int(roundf(Float(baseW) / s))
        let hLvl = Int(roundf(Float(baseH) / s))
        if wLvl < 2 * edge + 4 || hLvl < 2 * edge + 4 {
            invScales[lvl] = 0
        } else {
            let inv = 1.0 / (s * s)
            invScales[lvl] = inv
            scaleSum += inv
        }
    }
    if scaleSum <= 0 {
        outCount.pointee = 0
        return SRStatus.ok
    }

    struct OrbKp {
        var x: Float
        var y: Float
        var size: Float
        var angle: Float
        var response: Float
        var octave: Int
        var desc: [UInt8]
    }

    var allKps: [OrbKp] = []
    allKps.reserveCapacity(maxFeat)

    for lvl in 0..<levels {
        if invScales[lvl] <= 0 { continue }
        let s = powf(sf, Float(lvl))
        let wLvl = lvl == 0 ? baseW : Int(roundf(Float(baseW) / s))
        let hLvl = lvl == 0 ? baseH : Int(roundf(Float(baseH) / s))
        let lvlGray = lvl == 0 ? baseGray : p9ResizeGrayU8(baseGray, baseW, baseH, wLvl, hLvl)

        var raw = p9DetectFast9(lvlGray, wLvl, hLvl, fThresh, true, edge)
        if raw.count < 8 && fThresh > 7 {
            raw = p9DetectFast9(lvlGray, wLvl, hLvl, max(5, fThresh / 2), true, edge)
        }
        if raw.isEmpty { continue }

        var scored: [(x: Int, y: Int, hScore: Float)] = []
        scored.reserveCapacity(raw.count)
        for r in raw {
            let hs = p9HarrisScore7x7(lvlGray, wLvl, hLvl, r.x, r.y)
            scored.append((r.x, r.y, hs))
        }
        scored.sort { $0.hScore > $1.hScore }

        let budget = max(1, Int(roundf(Float(maxFeat) * invScales[lvl] / scaleSum)))
        let take = min(scored.count, budget)

        let blurred = p9Blur5x5(lvlGray, wLvl, hLvl)
        for i in 0..<take {
            let kp = scored[i]
            let angleDeg = p9IntensityCentroidAngle(lvlGray, wLvl, kp.x, kp.y)
            let rad = angleDeg * (Float.pi / 180.0)
            let cosA = cosf(rad)
            let sinA = sinf(rad)

            var desc = [UInt8](repeating: 0, count: 32)
            for byteIdx in 0..<32 {
                var byteVal: UInt8 = 0
                for bit in 0..<8 {
                    let pair = p9OrbPattern[byteIdx * 8 + bit]
                    let px1 = Float(kp.x) + Float(pair.0) * cosA - Float(pair.1) * sinA
                    let py1 = Float(kp.y) + Float(pair.0) * sinA + Float(pair.1) * cosA
                    let px2 = Float(kp.x) + Float(pair.2) * cosA - Float(pair.3) * sinA
                    let py2 = Float(kp.y) + Float(pair.2) * sinA + Float(pair.3) * cosA
                    let v1 = p9SampleBilinear(blurred, wLvl, hLvl, px1, py1)
                    let v2 = p9SampleBilinear(blurred, wLvl, hLvl, px2, py2)
                    if v1 < v2 {
                        byteVal |= (UInt8(1) << bit)
                    }
                }
                desc[byteIdx] = byteVal
            }

            allKps.append(OrbKp(
                x: Float(kp.x) * s,
                y: Float(kp.y) * s,
                size: 31.0 * s,
                angle: angleDeg,
                response: kp.hScore,
                octave: lvl,
                desc: desc
            ))
        }
    }

    if allKps.count > maxFeat {
        allKps.sort { $0.response > $1.response }
        allKps.removeSubrange(maxFeat..<allKps.count)
    }

    let finalN = min(allKps.count, Int(outCap))
    for i in 0..<finalN {
        let kp = allKps[i]
        if let outKpts {
            outKpts[6 * i] = kp.x
            outKpts[6 * i + 1] = kp.y
            outKpts[6 * i + 2] = kp.size
            outKpts[6 * i + 3] = kp.angle
            outKpts[6 * i + 4] = kp.response
            outKpts[6 * i + 5] = Float(kp.octave)
        }
        if let outDesc {
            for b in 0..<32 {
                outDesc[32 * i + b] = kp.desc[b]
            }
        }
    }
    outCount.pointee = Int32(finalN)
    return SRStatus.ok
}

// MARK: - 7. sr_bf_match (Brute-Force Matcher: NORM_HAMMING & NORM_L2 & NORM_L1)

@inline(__always)
private func p9HammingDist(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, _ cols: Int) -> Float {
    var total = 0
    var i = 0
    while i + 8 <= cols {
        var va: UInt64 = 0
        var vb: UInt64 = 0
        memcpy(&va, a + i, 8)
        memcpy(&vb, b + i, 8)
        total += (va ^ vb).nonzeroBitCount
        i += 8
    }
    while i < cols {
        total += (a[i] ^ b[i]).nonzeroBitCount
        i += 1
    }
    return Float(total)
}

@inline(__always)
private func p9L2Dist(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ cols: Int) -> Float {
    var sum: Float = 0
    for i in 0..<cols {
        let d = a[i] - b[i]
        sum += d * d
    }
    return sqrtf(sum)
}

@inline(__always)
private func p9L1Dist(_ a: UnsafePointer<Float>, _ b: UnsafePointer<Float>, _ cols: Int) -> Float {
    var sum: Float = 0
    for i in 0..<cols {
        sum += fabsf(a[i] - b[i])
    }
    return sum
}

@_cdecl("sr_bf_match")
public func sr_bf_match(
    _ desc1: UnsafeRawPointer?, _ n1: Int32,
    _ desc2: UnsafeRawPointer?, _ n2: Int32,
    _ descCols: Int32,
    _ normType: Int32,
    _ k: Int32,
    _ crossCheck: Int32,
    _ outQueryIdx: UnsafeMutablePointer<Int32>?,
    _ outTrainIdx: UnsafeMutablePointer<Int32>?,
    _ outDist: UnsafeMutablePointer<Float>?,
    _ outCap: Int32,
    _ outCount: UnsafeMutablePointer<Int32>?
) -> Int32 {
    guard let outCount else {
        return srFail(SRStatus.badArgument, "sr_bf_match: outCount is null")
    }
    let qCount = Int(n1)
    let tCount = Int(n2)
    let cols = Int(descCols)
    let kTop = max(1, Int(k))
    if qCount <= 0 || tCount <= 0 || cols <= 0 {
        outCount.pointee = 0
        return SRStatus.ok
    }
    guard let desc1, let desc2 else {
        return srFail(SRStatus.badArgument, "sr_bf_match: null descriptors")
    }

    let isHamming = (normType == 6 || normType == 7)
    let isL1 = (normType == 2)

    func distBetween(_ i: Int, _ j: Int) -> Float {
        if isHamming {
            let p1 = desc1.assumingMemoryBound(to: UInt8.self) + i * cols
            let p2 = desc2.assumingMemoryBound(to: UInt8.self) + j * cols
            return p9HammingDist(p1, p2, cols)
        } else {
            let p1 = desc1.assumingMemoryBound(to: Float.self) + i * cols
            let p2 = desc2.assumingMemoryBound(to: Float.self) + j * cols
            return isL1 ? p9L1Dist(p1, p2, cols) : p9L2Dist(p1, p2, cols)
        }
    }

    var written = 0
    let cap = max(0, Int(outCap))

    if crossCheck != 0 && kTop == 1 {
        var bestForQ = [Int](repeating: -1, count: qCount)
        var bestDistQ = [Float](repeating: Float.greatestFiniteMagnitude, count: qCount)
        for i in 0..<qCount {
            var bestJ = -1
            var bestD = Float.greatestFiniteMagnitude
            for j in 0..<tCount {
                let d = distBetween(i, j)
                if d < bestD {
                    bestD = d
                    bestJ = j
                }
            }
            bestForQ[i] = bestJ
            bestDistQ[i] = bestD
        }
        var bestForT = [Int](repeating: -1, count: tCount)
        for j in 0..<tCount {
            var bestI = -1
            var bestD = Float.greatestFiniteMagnitude
            for i in 0..<qCount {
                let d = distBetween(i, j)
                if d < bestD {
                    bestD = d
                    bestI = i
                }
            }
            bestForT[j] = bestI
        }
        for i in 0..<qCount {
            let j = bestForQ[i]
            if j >= 0 && bestForT[j] == i && written < cap {
                outQueryIdx?[written] = Int32(i)
                outTrainIdx?[written] = Int32(j)
                outDist?[written] = bestDistQ[i]
                written += 1
            }
        }
    } else {
        let actualK = min(kTop, tCount)
        var topIdx = [Int](repeating: -1, count: actualK)
        var topDst = [Float](repeating: Float.greatestFiniteMagnitude, count: actualK)
        for i in 0..<qCount {
            for r in 0..<actualK {
                topIdx[r] = -1
                topDst[r] = Float.greatestFiniteMagnitude
            }
            for j in 0..<tCount {
                let d = distBetween(i, j)
                if d < topDst[actualK - 1] {
                    var pos = actualK - 1
                    while pos > 0 && d < topDst[pos - 1] {
                        topDst[pos] = topDst[pos - 1]
                        topIdx[pos] = topIdx[pos - 1]
                        pos -= 1
                    }
                    topDst[pos] = d
                    topIdx[pos] = j
                }
            }
            for r in 0..<actualK {
                if topIdx[r] >= 0 && written < cap {
                    outQueryIdx?[written] = Int32(i)
                    outTrainIdx?[written] = Int32(topIdx[r])
                    outDist?[written] = topDst[r]
                    written += 1
                }
            }
        }
    }

    outCount.pointee = Int32(written)
    return SRStatus.ok
}
