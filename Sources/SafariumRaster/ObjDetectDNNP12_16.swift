// SafariumRaster — Phases 12–16 + Popular Contrib:
//   Phase 12 (ObjDetect): Apple Vision QR & Barcode detection/decoding + ArUco marker generation & detection
//   Phase 13 (DNN): Fast IoU NMS + Apple CoreML (.mlmodelc/.mlpackage) ANE/GPU inference bridge
//   Phase 16 + Contrib: ximgproc (Guided Filter, Zhang-Suen/Guo-Hall Thinning) & xphoto (SimpleWB, GrayworldWB, OilPainting)
// 100% Apple-native Swift + Vision + CoreML + CoreGraphics + Accelerate.

import Accelerate
import CoreGraphics
import CoreML
import Foundation
import Vision

// MARK: - Shared Private Helpers

private func p12MakeCGImage(_ img: SRImage) -> CGImage? {
    let w = img.width
    let h = img.height
    if w <= 0 || h <= 0 || img.depth != .u8 { return nil }

    if img.channels == 1 {
        var buf = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let srcRow = img.row(y).assumingMemoryBound(to: UInt8.self)
            let off = y * w
            for x in 0..<w { buf[off + x] = srcRow[x] }
        }
        let data = Data(buf)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    } else {
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let c = img.channels
        for y in 0..<h {
            let srcRow = img.row(y).assumingMemoryBound(to: UInt8.self)
            let dstOff = y * w * 4
            for x in 0..<w {
                let b = srcRow[x * c]
                let g = c > 1 ? srcRow[x * c + 1] : b
                let r = c > 2 ? srcRow[x * c + 2] : b
                rgba[dstOff + x * 4] = r
                rgba[dstOff + x * 4 + 1] = g
                rgba[dstOff + x * 4 + 2] = b
                rgba[dstOff + x * 4 + 3] = 255
            }
        }
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: w, height: h,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

private func p12ReadGrayU8(_ img: SRImage) -> [UInt8] {
    let w = img.width
    let h = img.height
    let c = img.channels
    var out = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
        let row = img.row(y)
        let off = y * w
        if img.depth == .u8 {
            let p = row.assumingMemoryBound(to: UInt8.self)
            if c == 1 {
                for x in 0..<w { out[off + x] = p[x] }
            } else {
                for x in 0..<w {
                    let b = Double(p[x * c])
                    let g = Double(p[x * c + 1])
                    let r = Double(p[x * c + 2])
                    out[off + x] = srSatU8(0.114 * b + 0.587 * g + 0.299 * r)
                }
            }
        } else if img.depth == .f32 {
            let p = row.assumingMemoryBound(to: Float.self)
            if c == 1 {
                for x in 0..<w { out[off + x] = srSatU8(Double(p[x])) }
            } else {
                for x in 0..<w {
                    let b = Double(p[x * c])
                    let g = Double(p[x * c + 1])
                    let r = Double(p[x * c + 2])
                    out[off + x] = srSatU8(0.114 * b + 0.587 * g + 0.299 * r)
                }
            }
        }
    }
    return out
}

// MARK: - Phase 12A: Apple Vision QR & Barcode Detection / Decoding

private func p12VisionBarcodes(
    _ img: SRImage,
    qrOnly: Bool,
    outCorners: UnsafeMutablePointer<Float>?,
    outTextBuf: UnsafeMutablePointer<CChar>?, _ outTextCap: Int32,
    outTextOffsets: UnsafeMutablePointer<Int32>?,
    outTextLens: UnsafeMutablePointer<Int32>?,
    outSymBuf: UnsafeMutablePointer<CChar>?, _ outSymCap: Int32,
    outSymOffsets: UnsafeMutablePointer<Int32>?,
    outSymLens: UnsafeMutablePointer<Int32>?,
    outCap: Int32,
    outCount: UnsafeMutablePointer<Int32>?
) -> Int32 {
    guard let outCount else {
        return srFail(SRStatus.badArgument, "sr_vision_barcode: outCount is null")
    }
    guard let cgImg = p12MakeCGImage(img) else {
        return srFail(SRStatus.badArgument, "sr_vision_barcode: failed to build CGImage from u8 SRImage")
    }

    let request = VNDetectBarcodesRequest()
    if qrOnly {
        request.symbologies = [.qr]
    }
    let handler = VNImageRequestHandler(cgImage: cgImg, options: [:])
    do {
        try handler.perform([request])
    } catch {
        return srFail(SRStatus.internalError, "Vision barcode detection failed: \(error.localizedDescription)")
    }

    let results = request.results ?? []
    let cap = max(0, Int(outCap))
    let w = Double(img.width)
    let h = Double(img.height)

    var written = 0
    var textPos = 0
    var symPos = 0
    let textCap = max(0, Int(outTextCap))
    let symCap = max(0, Int(outSymCap))

    for obs in results {
        if written >= cap { break }
        if let outCorners {
            let base = written * 8
            outCorners[base + 0] = Float(obs.topLeft.x * w)
            outCorners[base + 1] = Float((1.0 - obs.topLeft.y) * h)
            outCorners[base + 2] = Float(obs.topRight.x * w)
            outCorners[base + 3] = Float((1.0 - obs.topRight.y) * h)
            outCorners[base + 4] = Float(obs.bottomRight.x * w)
            outCorners[base + 5] = Float((1.0 - obs.bottomRight.y) * h)
            outCorners[base + 6] = Float(obs.bottomLeft.x * w)
            outCorners[base + 7] = Float((1.0 - obs.bottomLeft.y) * h)
        }

        let payload = obs.payloadStringValue ?? ""
        let pBytes = Array(payload.utf8)
        let pCopy = min(pBytes.count, max(0, textCap - textPos))
        outTextOffsets?[written] = Int32(textPos)
        outTextLens?[written] = Int32(pCopy)
        if let outTextBuf {
            for k in 0..<pCopy { outTextBuf[textPos + k] = CChar(bitPattern: pBytes[k]) }
        }
        textPos += pCopy

        let sym = obs.symbology.rawValue
        let sBytes = Array(sym.utf8)
        let sCopy = min(sBytes.count, max(0, symCap - symPos))
        outSymOffsets?[written] = Int32(symPos)
        outSymLens?[written] = Int32(sCopy)
        if let outSymBuf {
            for k in 0..<sCopy { outSymBuf[symPos + k] = CChar(bitPattern: sBytes[k]) }
        }
        symPos += sCopy

        written += 1
    }

    outCount.pointee = Int32(written)
    return SRStatus.ok
}

@_cdecl("sr_qr_detect_decode")
public func sr_qr_detect_decode(
    _ srcData: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sd: Int32,
    _ outCorners: UnsafeMutablePointer<Float>?,
    _ outTextBuf: UnsafeMutablePointer<CChar>?, _ outTextCap: Int32,
    _ outTextOffsets: UnsafeMutablePointer<Int32>?,
    _ outTextLens: UnsafeMutablePointer<Int32>?,
    _ outCap: Int32,
    _ outCount: UnsafeMutablePointer<Int32>?
) -> Int32 {
    guard let src = SRImage(srcData, sw, sh, ss, sc, sd) else {
        return srFail(SRStatus.badArgument, "sr_qr_detect_decode: invalid image")
    }
    return p12VisionBarcodes(
        src, qrOnly: true,
        outCorners: outCorners,
        outTextBuf: outTextBuf, outTextCap,
        outTextOffsets: outTextOffsets, outTextLens: outTextLens,
        outSymBuf: nil, 0, outSymOffsets: nil, outSymLens: nil,
        outCap: outCap, outCount: outCount
    )
}

@_cdecl("sr_barcode_detect")
public func sr_barcode_detect(
    _ srcData: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sd: Int32,
    _ outCorners: UnsafeMutablePointer<Float>?,
    _ outTextBuf: UnsafeMutablePointer<CChar>?, _ outTextCap: Int32,
    _ outTextOffsets: UnsafeMutablePointer<Int32>?,
    _ outTextLens: UnsafeMutablePointer<Int32>?,
    _ outSymBuf: UnsafeMutablePointer<CChar>?, _ outSymCap: Int32,
    _ outSymOffsets: UnsafeMutablePointer<Int32>?,
    _ outSymLens: UnsafeMutablePointer<Int32>?,
    _ outCap: Int32,
    _ outCount: UnsafeMutablePointer<Int32>?
) -> Int32 {
    guard let src = SRImage(srcData, sw, sh, ss, sc, sd) else {
        return srFail(SRStatus.badArgument, "sr_barcode_detect: invalid image")
    }
    return p12VisionBarcodes(
        src, qrOnly: false,
        outCorners: outCorners,
        outTextBuf: outTextBuf, outTextCap,
        outTextOffsets: outTextOffsets, outTextLens: outTextLens,
        outSymBuf: outSymBuf, outSymCap, outSymOffsets: outSymOffsets, outSymLens: outSymLens,
        outCap: outCap, outCount: outCount
    )
}

// MARK: - Phase 12B: ArUco Marker Dictionaries, Generation, and Detection

private struct P12ArucoDict: Sendable {
    let gridSize: Int
    let codes: [UInt64]
    let maxCorrectionBits: Int
}

private func p12RotateBits90(_ bits: UInt64, _ n: Int) -> UInt64 {
    var out: UInt64 = 0
    for r in 0..<n {
        for c in 0..<n {
            let srcBit = (bits >> (r * n + c)) & 1
            let nr = c
            let nc = n - 1 - r
            out |= (srcBit << (nr * n + nc))
        }
    }
    return out
}

private func p12BuildDict(gridSize n: Int, count: Int, minHamming: Int, seed: UInt64) -> P12ArucoDict {
    let totalBits = n * n
    let mask: UInt64 = (totalBits == 64) ? UInt64.max : ((UInt64(1) << totalBits) - 1)
    var rng = seed
    func nextRand() -> UInt64 {
        rng ^= rng << 13
        rng ^= rng >> 7
        rng ^= rng << 17
        return rng & mask
    }

    var codes: [UInt64] = []
    codes.reserveCapacity(count)
    var allRotations: [UInt64] = []
    allRotations.reserveCapacity(count * 4)

    var curMinH = minHamming
    var attempts = 0
    while codes.count < count {
        attempts += 1
        if attempts > 80_000 && curMinH > 2 {
            curMinH -= 1
            attempts = 0
        }
        let cand = nextRand()
        let ones = cand.nonzeroBitCount
        if ones < totalBits / 4 || ones > (totalBits * 3) / 4 { continue }

        let r1 = p12RotateBits90(cand, n)
        let r2 = p12RotateBits90(r1, n)
        let r3 = p12RotateBits90(r2, n)

        // Ensure self-rotation separation so orientation is unambiguous
        if (cand ^ r1).nonzeroBitCount < curMinH ||
           (cand ^ r2).nonzeroBitCount < curMinH ||
           (cand ^ r3).nonzeroBitCount < curMinH {
            continue
        }

        var ok = true
        for prev in allRotations {
            if (cand ^ prev).nonzeroBitCount < curMinH {
                ok = false
                break
            }
        }
        if ok {
            codes.append(cand)
            allRotations.append(cand)
            allRotations.append(r1)
            allRotations.append(r2)
            allRotations.append(r3)
        }
    }
    return P12ArucoDict(gridSize: n, codes: codes, maxCorrectionBits: max(1, (curMinH - 1) / 2))
}

private let p12Dict4x4: P12ArucoDict = p12BuildDict(gridSize: 4, count: 50, minHamming: 4, seed: 0xA40C_0044_1234_5678)
private let p12Dict5x5: P12ArucoDict = p12BuildDict(gridSize: 5, count: 100, minHamming: 6, seed: 0xA50C_0055_8765_4321)
private let p12Dict6x6: P12ArucoDict = p12BuildDict(gridSize: 6, count: 250, minHamming: 8, seed: 0xA60C_0066_FEDC_BA98)

private func p12GetDict(_ dictId: Int32) -> P12ArucoDict? {
    // OpenCV enum values: DICT_4X4_50=0, DICT_4X4_100=1, ..., DICT_5X5_50=4, DICT_5X5_100=5, ..., DICT_6X6_50=8, DICT_6X6_250=10
    switch dictId {
    case 0, 1, 2, 3: return p12Dict4x4
    case 4, 5, 6, 7: return p12Dict5x5
    case 8, 9, 10, 11: return p12Dict6x6
    default: return nil
    }
}

@_cdecl("sr_aruco_generate_marker")
public func sr_aruco_generate_marker(
    _ dictId: Int32, _ markerId: Int32, _ sidePixels: Int32, _ borderBits: Int32,
    _ dstData: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ dd: Int32
) -> Int32 {
    guard let dict = p12GetDict(dictId),
          let dst = SRImage(dstData, dw, dh, ds, dc, dd),
          dst.depth == .u8, dst.channels == 1 else {
        return srFail(SRStatus.badArgument, "sr_aruco_generate_marker: invalid dictId or dst")
    }
    let mId = Int(markerId)
    let side = Int(sidePixels)
    let border = max(1, Int(borderBits))
    guard mId >= 0 && mId < dict.codes.count, side == dst.width, side == dst.height else {
        return srFail(SRStatus.badArgument, "sr_aruco_generate_marker: invalid markerId or sidePixels")
    }

    let n = dict.gridSize
    let totalCells = n + 2 * border
    let code = dict.codes[mId]

    for y in 0..<side {
        let cellY = min(totalCells - 1, (y * totalCells) / side)
        let row = dst.row(y).assumingMemoryBound(to: UInt8.self)
        for x in 0..<side {
            let cellX = min(totalCells - 1, (x * totalCells) / side)
            if cellX < border || cellX >= border + n || cellY < border || cellY >= border + n {
                row[x] = 0
            } else {
                let r = cellY - border
                let c = cellX - border
                let bit = (code >> (r * n + c)) & 1
                row[x] = (bit != 0) ? 255 : 0
            }
        }
    }
    return SRStatus.ok
}

// ArUco quad detection helpers
private func p12Homography4Pts(_ src: [(Double, Double)], _ dst: [(Double, Double)]) -> [Double]? {
    var A = [Double](repeating: 0, count: 64)
    var b = [Double](repeating: 0, count: 8)
    for i in 0..<4 {
        let x = src[i].0, y = src[i].1
        let u = dst[i].0, v = dst[i].1
        let r0 = 2 * i
        let r1 = 2 * i + 1
        A[r0 * 8 + 0] = x; A[r0 * 8 + 1] = y; A[r0 * 8 + 2] = 1
        A[r0 * 8 + 6] = -u * x; A[r0 * 8 + 7] = -u * y
        b[r0] = u

        A[r1 * 8 + 3] = x; A[r1 * 8 + 4] = y; A[r1 * 8 + 5] = 1
        A[r1 * 8 + 6] = -v * x; A[r1 * 8 + 7] = -v * y
        b[r1] = v
    }
    // Gaussian elimination for 8x8
    for col in 0..<8 {
        var piv = col
        var maxV = abs(A[col * 8 + col])
        for row in (col + 1)..<8 {
            let v = abs(A[row * 8 + col])
            if v > maxV { maxV = v; piv = row }
        }
        if maxV < 1e-12 { return nil }
        if piv != col {
            for k in col..<8 { A.swapAt(col * 8 + k, piv * 8 + k) }
            b.swapAt(col, piv)
        }
        let diag = A[col * 8 + col]
        for row in (col + 1)..<8 {
            let f = A[row * 8 + col] / diag
            for k in (col + 1)..<8 { A[row * 8 + k] -= f * A[col * 8 + k] }
            b[row] -= f * b[col]
        }
    }
    for row in stride(from: 7, through: 0, by: -1) {
        var s = b[row]
        for k in (row + 1)..<8 { s -= A[row * 8 + k] * b[k] }
        b[row] = s / A[row * 8 + row]
    }
    return [b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], 1.0]
}

private func p12ConvexHull(_ pts: [(Int, Int)]) -> [(Double, Double)] {
    if pts.count < 3 { return [] }
    let sorted = pts.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
    func cross(_ o: (Int, Int), _ a: (Int, Int), _ b: (Int, Int)) -> Int {
        (a.0 - o.0) * (b.1 - o.1) - (a.1 - o.1) * (b.0 - o.0)
    }
    var lower: [(Int, Int)] = []
    for p in sorted {
        while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
            lower.removeLast()
        }
        lower.append(p)
    }
    var upper: [(Int, Int)] = []
    for p in sorted.reversed() {
        while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
            upper.removeLast()
        }
        upper.append(p)
    }
    lower.removeLast()
    upper.removeLast()
    let hull = lower + upper
    return hull.map { (Double($0.0), Double($0.1)) }
}

/// Simplifies a closed convex polygon to 4 vertices if it is well-approximated by a quadrilateral.
private func p12SimplifyToQuad(_ hull: [(Double, Double)]) -> [(Double, Double)]? {
    if hull.count < 4 { return nil }
    var poly = hull
    // Compute total perimeter
    var perim: Double = 0
    for i in 0..<poly.count {
        let a = poly[i]
        let b = poly[(i + 1) % poly.count]
        perim += hypot(b.0 - a.0, b.1 - a.1)
    }
    if perim < 32.0 { return nil }

    // Iteratively remove the vertex whose removal adds the smallest triangle area
    while poly.count > 4 {
        var minArea = Double.greatestFiniteMagnitude
        var minIdx = 0
        let m = poly.count
        for i in 0..<m {
            let prev = poly[(i - 1 + m) % m]
            let curr = poly[i]
            let next = poly[(i + 1) % m]
            let area = 0.5 * abs((curr.0 - prev.0) * (next.1 - prev.1) - (curr.1 - prev.1) * (next.0 - prev.0))
            if area < minArea {
                minArea = area
                minIdx = i
            }
        }
        poly.remove(at: minIdx)
    }

    // Verify all 4 edges have reasonable length and hull points lie close to quad edges
    for i in 0..<4 {
        let a = poly[i]
        let b = poly[(i + 1) % 4]
        if hypot(b.0 - a.0, b.1 - a.1) < 8.0 { return nil }
    }

    // Compute quad area and compare to hull area (should match > 88%)
    func polyArea(_ p: [(Double, Double)]) -> Double {
        var s: Double = 0
        for i in 0..<p.count {
            let a = p[i], b = p[(i + 1) % p.count]
            s += a.0 * b.1 - b.0 * a.1
        }
        return 0.5 * abs(s)
    }
    let hArea = polyArea(hull)
    let qArea = polyArea(poly)
    if hArea < 64.0 || qArea / hArea < 0.85 { return nil }

    // Ensure clockwise order in image coordinates (y down -> positive signed area)
    var signedArea: Double = 0
    for i in 0..<4 {
        let a = poly[i], b = poly[(i + 1) % 4]
        signedArea += (b.0 - a.0) * (b.1 + a.1)
    }
    if signedArea > 0 { poly.reverse() }
    return poly
}

private func p12SampleGrayBilinear(_ gray: [UInt8], _ w: Int, _ h: Int, _ x: Double, _ y: Double) -> Double {
    let cx = min(max(x, 0.0), Double(w - 1))
    let cy = min(max(y, 0.0), Double(h - 1))
    let x0 = Int(floor(cx))
    let y0 = Int(floor(cy))
    let x1 = min(x0 + 1, w - 1)
    let y1 = min(y0 + 1, h - 1)
    let fx = cx - Double(x0)
    let fy = cy - Double(y0)
    let v00 = Double(gray[y0 * w + x0])
    let v10 = Double(gray[y0 * w + x1])
    let v01 = Double(gray[y1 * w + x0])
    let v11 = Double(gray[y1 * w + x1])
    let top = v00 + fx * (v10 - v00)
    let bot = v01 + fx * (v11 - v01)
    return top + fy * (bot - top)
}

private func p12ExtractCandidateQuads(_ bin: [UInt8], _ w: Int, _ h: Int) -> [[(Double, Double)]] {
    var labels = [Int32](repeating: 0, count: w * h)
    var nextLabel: Int32 = 1
    var queue = [Int]()
    queue.reserveCapacity(4096)
    var quads: [[(Double, Double)]] = []
    let minArea = 64
    let maxArea = Int(Double(w * h) * 0.95)

    for sy in 1..<(h - 1) {
        let sOff = sy * w
        for sx in 1..<(w - 1) {
            let start = sOff + sx
            if bin[start] == 0 || labels[start] != 0 { continue }
            let lbl = nextLabel
            nextLabel += 1
            labels[start] = lbl
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            var head = 0
            var minX = sx, maxX = sx, minY = sy, maxY = sy
            var boundary: [(Int, Int)] = []

            while head < queue.count {
                let idx = queue[head]
                head += 1
                let x = idx % w
                let y = idx / w
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }

                var isEdge = false
                if x > 0 {
                    let nb = idx - 1
                    if bin[nb] != 0 {
                        if labels[nb] == 0 { labels[nb] = lbl; queue.append(nb) }
                    } else { isEdge = true }
                } else { isEdge = true }
                if x + 1 < w {
                    let nb = idx + 1
                    if bin[nb] != 0 {
                        if labels[nb] == 0 { labels[nb] = lbl; queue.append(nb) }
                    } else { isEdge = true }
                } else { isEdge = true }
                if y > 0 {
                    let nb = idx - w
                    if bin[nb] != 0 {
                        if labels[nb] == 0 { labels[nb] = lbl; queue.append(nb) }
                    } else { isEdge = true }
                } else { isEdge = true }
                if y + 1 < h {
                    let nb = idx + w
                    if bin[nb] != 0 {
                        if labels[nb] == 0 { labels[nb] = lbl; queue.append(nb) }
                    } else { isEdge = true }
                } else { isEdge = true }

                if isEdge { boundary.append((x, y)) }
            }

            let bboxArea = (maxX - minX + 1) * (maxY - minY + 1)
            if bboxArea < minArea || bboxArea > maxArea { continue }
            if (maxX - minX) < 12 || (maxY - minY) < 12 { continue }
            let hull = p12ConvexHull(boundary)
            if let q = p12SimplifyToQuad(hull) {
                quads.append(q)
            }
        }
    }
    return quads
}

@_cdecl("sr_aruco_detect_markers")
public func sr_aruco_detect_markers(
    _ srcData: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sd: Int32,
    _ dictId: Int32,
    _ outCorners: UnsafeMutablePointer<Float>?,
    _ outIds: UnsafeMutablePointer<Int32>?,
    _ outCap: Int32,
    _ outCount: UnsafeMutablePointer<Int32>?
) -> Int32 {
    guard let src = SRImage(srcData, sw, sh, ss, sc, sd),
          let dict = p12GetDict(dictId),
          let outCount else {
        return srFail(SRStatus.badArgument, "sr_aruco_detect_markers: invalid arguments")
    }
    let w = src.width
    let h = src.height
    if w < 16 || h < 16 {
        outCount.pointee = 0
        return SRStatus.ok
    }

    let gray = p12ReadGrayU8(src)
    let n = w * h

    // Pass 1: Global Otsu threshold for dark foreground
    var hist = [Int](repeating: 0, count: 256)
    for v in gray { hist[Int(v)] += 1 }
    var sumAll: Double = 0
    for i in 0..<256 { sumAll += Double(i * hist[i]) }
    var wB = 0
    var sumB: Double = 0
    var bestVar: Double = -1
    var otsuT = 128
    for t in 0..<256 {
        wB += hist[t]
        if wB == 0 { continue }
        let wF = n - wB
        if wF == 0 { break }
        sumB += Double(t * hist[t])
        let mB = sumB / Double(wB)
        let mF = (sumAll - sumB) / Double(wF)
        let v = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
        if v > bestVar {
            bestVar = v
            otsuT = t
        }
    }

    var binOtsu = [UInt8](repeating: 0, count: n)
    for i in 0..<n { binOtsu[i] = Int(gray[i]) <= otsuT ? 1 : 0 }

    // Pass 2: Local adaptive threshold via integral image
    let iw = w + 1
    var integral = [Int](repeating: 0, count: (h + 1) * iw)
    for y in 0..<h {
        let off = y * w
        let iRow = (y + 1) * iw
        let iPrev = y * iw
        var rs = 0
        for x in 0..<w {
            rs += Int(gray[off + x])
            integral[iRow + x + 1] = integral[iPrev + x + 1] + rs
        }
    }
    let rad = max(7, min(31, min(w, h) / 10))
    var binAdapt = [UInt8](repeating: 0, count: n)
    for y in 0..<h {
        let y0 = max(0, y - rad)
        let y1 = min(h, y + rad + 1)
        let off = y * w
        for x in 0..<w {
            let x0 = max(0, x - rad)
            let x1 = min(w, x + rad + 1)
            let cnt = (x1 - x0) * (y1 - y0)
            let s = integral[y1 * iw + x1] - integral[y0 * iw + x1] - integral[y1 * iw + x0] + integral[y0 * iw + x0]
            let mean = s / max(1, cnt)
            binAdapt[off + x] = Int(gray[off + x]) < (mean - 8) ? 1 : 0
        }
    }

    var candidateQuads = p12ExtractCandidateQuads(binOtsu, w, h)
    candidateQuads.append(contentsOf: p12ExtractCandidateQuads(binAdapt, w, h))

    let grid = dict.gridSize
    let totalCells = grid + 2
    let canonical: [(Double, Double)] = [
        (0, 0), (Double(totalCells), 0), (Double(totalCells), Double(totalCells)), (0, Double(totalCells))
    ]

    struct Detection {
        var id: Int
        var dist: Int
        var cx: Double
        var cy: Double
        var corners: [(Double, Double)]
    }
    var detections: [Detection] = []

    for quad in candidateQuads {
        guard let H = p12Homography4Pts(canonical, quad) else { continue }

        var cellVals = [Double](repeating: 0, count: totalCells * totalCells)
        var minV = 255.0
        var maxV = 0.0
        for r in 0..<totalCells {
            for c in 0..<totalCells {
                var sum: Double = 0
                let offsets: [Double] = [0.3, 0.5, 0.7]
                for oy in offsets {
                    for ox in offsets {
                        let sx = Double(c) + ox
                        let sy = Double(r) + oy
                        let denom = H[6] * sx + H[7] * sy + H[8]
                        let px = (H[0] * sx + H[1] * sy + H[2]) / denom
                        let py = (H[3] * sx + H[4] * sy + H[5]) / denom
                        sum += p12SampleGrayBilinear(gray, w, h, px, py)
                    }
                }
                let avg = sum / 9.0
                cellVals[r * totalCells + c] = avg
                if avg < minV { minV = avg }
                if avg > maxV { maxV = avg }
            }
        }
        if maxV - minV < 25.0 { continue }
        let midThresh = 0.5 * (minV + maxV)

        // Check border cells are dark
        var borderTotal = 0
        var borderBlack = 0
        for r in 0..<totalCells {
            for c in 0..<totalCells {
                if r == 0 || r == totalCells - 1 || c == 0 || c == totalCells - 1 {
                    borderTotal += 1
                    if cellVals[r * totalCells + c] < midThresh { borderBlack += 1 }
                }
            }
        }
        if Double(borderBlack) / Double(borderTotal) < 0.85 { continue }

        var bits: UInt64 = 0
        for r in 0..<grid {
            for c in 0..<grid {
                if cellVals[(r + 1) * totalCells + (c + 1)] >= midThresh {
                    bits |= (UInt64(1) << (r * grid + c))
                }
            }
        }

        // Match against dictionary across 4 rotations
        var bestId = -1
        var bestDist = dict.maxCorrectionBits + 1
        var bestRot = 0

        var rotBits = bits
        for rot in 0..<4 {
            for (mId, code) in dict.codes.enumerated() {
                let d = (rotBits ^ code).nonzeroBitCount
                if d < bestDist {
                    bestDist = d
                    bestId = mId
                    bestRot = rot
                }
            }
            rotBits = p12RotateBits90(rotBits, grid)
        }

        if bestId >= 0 {
            // Rotate corners to align canonical top-left with corner 0
            // Rotating image bits clockwise by `bestRot` means canonical corner 0 is at quad[(4 - bestRot) % 4]
            let shift = (4 - bestRot) % 4
            let ordered = [
                quad[shift % 4],
                quad[(shift + 1) % 4],
                quad[(shift + 2) % 4],
                quad[(shift + 3) % 4]
            ]
            let cx = 0.25 * (ordered[0].0 + ordered[1].0 + ordered[2].0 + ordered[3].0)
            let cy = 0.25 * (ordered[0].1 + ordered[1].1 + ordered[2].1 + ordered[3].1)

            // Deduplicate nearby detections
            var dupIdx: Int? = nil
            for (di, existing) in detections.enumerated() {
                if hypot(existing.cx - cx, existing.cy - cy) < 12.0 {
                    dupIdx = di
                    break
                }
            }
            if let di = dupIdx {
                if bestDist < detections[di].dist {
                    detections[di] = Detection(id: bestId, dist: bestDist, cx: cx, cy: cy, corners: ordered)
                }
            } else {
                detections.append(Detection(id: bestId, dist: bestDist, cx: cx, cy: cy, corners: ordered))
            }
        }
    }

    let limit = min(detections.count, max(0, Int(outCap)))
    for i in 0..<limit {
        let det = detections[i]
        outIds?[i] = Int32(det.id)
        if let outCorners {
            for c in 0..<4 {
                outCorners[i * 8 + c * 2] = Float(det.corners[c].0)
                outCorners[i * 8 + c * 2 + 1] = Float(det.corners[c].1)
            }
        }
    }
    outCount.pointee = Int32(limit)
    return SRStatus.ok
}

// MARK: - Phase 13: DNN NMS + Native Apple CoreML Bridge

@_cdecl("sr_dnn_nms_boxes")
public func sr_dnn_nms_boxes(
    _ boxes: UnsafePointer<Float>?,
    _ scores: UnsafePointer<Float>?,
    _ nBoxes: Int32,
    _ scoreThreshold: Float,
    _ nmsThreshold: Float,
    _ outIndices: UnsafeMutablePointer<Int32>?,
    _ outCount: UnsafeMutablePointer<Int32>?
) -> Int32 {
    guard let outCount else {
        return srFail(SRStatus.badArgument, "sr_dnn_nms_boxes: outCount is null")
    }
    let n = Int(nBoxes)
    if n <= 0 {
        outCount.pointee = 0
        return SRStatus.ok
    }
    guard let boxes, let scores, let outIndices else {
        return srFail(SRStatus.badArgument, "sr_dnn_nms_boxes: null buffer")
    }

    var order: [Int] = []
    order.reserveCapacity(n)
    for i in 0..<n {
        if scores[i] >= scoreThreshold {
            order.append(i)
        }
    }
    order.sort { scores[$0] > scores[$1] }

    var kept: [Int] = []
    kept.reserveCapacity(order.count)

    for idx in order {
        let ax = boxes[idx * 4]
        let ay = boxes[idx * 4 + 1]
        let aw = max(0.0, boxes[idx * 4 + 2])
        let ah = max(0.0, boxes[idx * 4 + 3])
        let ax2 = ax + aw
        let ay2 = ay + ah
        let aArea = aw * ah

        var suppress = false
        for k in kept {
            let bx = boxes[k * 4]
            let by = boxes[k * 4 + 1]
            let bw = max(0.0, boxes[k * 4 + 2])
            let bh = max(0.0, boxes[k * 4 + 3])
            let bx2 = bx + bw
            let by2 = by + bh
            let iw = max(0.0, min(ax2, bx2) - max(ax, bx))
            let ih = max(0.0, min(ay2, by2) - max(ay, by))
            let inter = iw * ih
            let union = aArea + bw * bh - inter
            let iou = union > 1e-12 ? (inter / union) : 0.0
            if iou > nmsThreshold {
                suppress = true
                break
            }
        }
        if !suppress {
            kept.append(idx)
        }
    }

    for (i, idx) in kept.enumerated() {
        outIndices[i] = Int32(idx)
    }
    outCount.pointee = Int32(kept.count)
    return SRStatus.ok
}

private final class P13CoreMLModel {
    let model: MLModel
    let defaultInputName: String
    let defaultOutputName: String

    init(model: MLModel) {
        self.model = model
        self.defaultInputName = model.modelDescription.inputDescriptionsByName.keys.sorted().first ?? "input"
        self.defaultOutputName = model.modelDescription.outputDescriptionsByName.keys.sorted().first ?? "output"
    }
}

@_cdecl("sr_coreml_load")
public func sr_coreml_load(_ pathCStr: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? {
    guard let pathCStr else {
        _ = srFail(SRStatus.badArgument, "sr_coreml_load: null path")
        return nil
    }
    let path = String(cString: pathCStr)
    let url = URL(fileURLWithPath: path)
    do {
        let compiledURL: URL
        if url.pathExtension.lowercased() == "mlmodelc" {
            compiledURL = url
        } else {
            compiledURL = try MLModel.compileModel(at: url)
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all
        let mlModel = try MLModel(contentsOf: compiledURL, configuration: cfg)
        let wrapper = P13CoreMLModel(model: mlModel)
        return Unmanaged.passRetained(wrapper).toOpaque()
    } catch {
        _ = srFail(SRStatus.ioFailure, "sr_coreml_load failed: \(error.localizedDescription)")
        return nil
    }
}

@_cdecl("sr_coreml_infer_f32")
public func sr_coreml_infer_f32(
    _ handle: UnsafeMutableRawPointer?,
    _ inputNameCStr: UnsafePointer<CChar>?,
    _ inputData: UnsafePointer<Float>?, _ inputShape: UnsafePointer<Int32>?, _ inputNdim: Int32,
    _ outputNameCStr: UnsafePointer<CChar>?,
    _ outData: UnsafeMutablePointer<Float>?, _ outCap: Int32,
    _ outCount: UnsafeMutablePointer<Int32>?,
    _ outShape: UnsafeMutablePointer<Int32>?, _ outNdim: UnsafeMutablePointer<Int32>?
) -> Int32 {
    guard let handle, let inputData, let inputShape, inputNdim > 0, let outCount else {
        return srFail(SRStatus.badArgument, "sr_coreml_infer_f32: invalid arguments")
    }
    let wrapper = Unmanaged<P13CoreMLModel>.fromOpaque(handle).takeUnretainedValue()
    let inName = inputNameCStr != nil ? String(cString: inputNameCStr!) : wrapper.defaultInputName
    let outName = outputNameCStr != nil ? String(cString: outputNameCStr!) : wrapper.defaultOutputName

    var shapeNums: [NSNumber] = []
    var totalIn = 1
    for i in 0..<Int(inputNdim) {
        let d = Int(inputShape[i])
        shapeNums.append(NSNumber(value: d))
        totalIn *= d
    }

    do {
        let mlIn = try MLMultiArray(shape: shapeNums, dataType: .float32)
        let dstPtr = mlIn.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<totalIn { dstPtr[i] = inputData[i] }

        let provider = try MLDictionaryFeatureProvider(dictionary: [inName: MLFeatureValue(multiArray: mlIn)])
        let result = try wrapper.model.prediction(from: provider)
        guard let outFeat = result.featureValue(for: outName),
              let mlOut = outFeat.multiArrayValue else {
            return srFail(SRStatus.internalError, "sr_coreml_infer_f32: missing multiArray output '\(outName)'")
        }

        let nElem = mlOut.count
        let nCopy = min(nElem, max(0, Int(outCap)))
        if let outData {
            if mlOut.dataType == .float32 {
                let srcPtr = mlOut.dataPointer.assumingMemoryBound(to: Float.self)
                for i in 0..<nCopy { outData[i] = srcPtr[i] }
            } else {
                for i in 0..<nCopy { outData[i] = mlOut[i].floatValue }
            }
        }
        outCount.pointee = Int32(nElem)
        if let outNdim { outNdim.pointee = Int32(mlOut.shape.count) }
        if let outShape {
            for (i, d) in mlOut.shape.enumerated() {
                if i < 8 { outShape[i] = Int32(d.intValue) }
            }
        }
        return SRStatus.ok
    } catch {
        return srFail(SRStatus.internalError, "sr_coreml_infer_f32 failed: \(error.localizedDescription)")
    }
}

@_cdecl("sr_coreml_free")
public func sr_coreml_free(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    guard let handle else { return SRStatus.ok }
    Unmanaged<P13CoreMLModel>.fromOpaque(handle).release()
    return SRStatus.ok
}

// MARK: - Phase 16 + Contrib: ximgproc (Guided Filter, Thinning) & xphoto (SimpleWB, GrayworldWB, OilPainting)

@inline(__always)
private func p16Clamp(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
    v < lo ? lo : (v > hi ? hi : v)
}

/// Fast O(1) per-pixel box mean filter using running sums.
private func p16BoxMean(_ src: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
    let rad = max(1, r)
    var tmp = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
        let off = y * w
        var sum: Double = 0
        for dx in -rad...rad {
            sum += Double(src[off + p16Clamp(dx, 0, w - 1)])
        }
        let inv = 1.0 / Double(2 * rad + 1)
        tmp[off] = Float(sum * inv)
        for x in 1..<w {
            let addX = p16Clamp(x + rad, 0, w - 1)
            let subX = p16Clamp(x - rad - 1, 0, w - 1)
            sum += Double(src[off + addX]) - Double(src[off + subX])
            tmp[off + x] = Float(sum * inv)
        }
    }
    var dst = [Float](repeating: 0, count: w * h)
    let inv = 1.0 / Double(2 * rad + 1)
    for x in 0..<w {
        var sum: Double = 0
        for dy in -rad...rad {
            sum += Double(tmp[p16Clamp(dy, 0, h - 1) * w + x])
        }
        dst[x] = Float(sum * inv)
        for y in 1..<h {
            let addY = p16Clamp(y + rad, 0, h - 1)
            let subY = p16Clamp(y - rad - 1, 0, h - 1)
            sum += Double(tmp[addY * w + x]) - Double(tmp[subY * w + x])
            dst[y * w + x] = Float(sum * inv)
        }
    }
    return dst
}

private func p16ExtractChannelF32(_ img: SRImage, _ ch: Int, _ scaleU8: Float) -> [Float] {
    let w = img.width
    let h = img.height
    let c = img.channels
    var out = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
        let off = y * w
        if img.depth == .u8 {
            let p = img.row(y).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w { out[off + x] = Float(p[x * c + ch]) * scaleU8 }
        } else if img.depth == .f32 {
            let p = img.row(y).assumingMemoryBound(to: Float.self)
            for x in 0..<w { out[off + x] = p[x * c + ch] }
        }
    }
    return out
}

@_cdecl("sr_ximgproc_guided_filter")
public func sr_ximgproc_guided_filter(
    _ guideData: UnsafeMutableRawPointer?, _ gw: Int32, _ gh: Int32, _ gs: Int32, _ gc: Int32, _ gd: Int32,
    _ srcData: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sd: Int32,
    _ dstData: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ dd: Int32,
    _ radius: Int32, _ eps: Double
) -> Int32 {
    guard let guide = SRImage(guideData, gw, gh, gs, gc, gd),
          let src = SRImage(srcData, sw, sh, ss, sc, sd),
          let dst = SRImage(dstData, dw, dh, ds, dc, dd) else {
        return srFail(SRStatus.badArgument, "sr_ximgproc_guided_filter: invalid images")
    }
    guard guide.width == src.width, guide.height == src.height,
          dst.width == src.width, dst.height == src.height,
          dst.channels == src.channels, dst.depth == src.depth else {
        return srFail(SRStatus.badArgument, "sr_ximgproc_guided_filter: mismatched dimensions/channels/depth")
    }
    guard (src.depth == .u8 || src.depth == .f32) && (guide.depth == .u8 || guide.depth == .f32) else {
        return srFail(SRStatus.unsupported, "sr_ximgproc_guided_filter: supports u8 and f32")
    }

    let w = src.width
    let h = src.height
    let n = w * h
    let r = max(1, Int(radius))
    let epsF = Float(max(1e-8, eps))

    // Use native intensity scale (OpenCV guidedFilter operates on raw pixel scale [0..255] for u8, [0..1] for f32)
    if guide.channels == 1 {
        let I = p16ExtractChannelF32(guide, 0, 1.0)
        let meanI = p16BoxMean(I, w, h, r)
        var II = [Float](repeating: 0, count: n)
        vDSP_vmul(I, 1, I, 1, &II, 1, vDSP_Length(n))
        let corrI = p16BoxMean(II, w, h, r)
        var varI = [Float](repeating: 0, count: n)
        for i in 0..<n { varI[i] = max(0.0, corrI[i] - meanI[i] * meanI[i]) }

        var channelsOut: [[Float]] = []
        for ch in 0..<src.channels {
            let p = p16ExtractChannelF32(src, ch, 1.0)
            let meanP = p16BoxMean(p, w, h, r)
            var Ip = [Float](repeating: 0, count: n)
            vDSP_vmul(I, 1, p, 1, &Ip, 1, vDSP_Length(n))
            let corrIp = p16BoxMean(Ip, w, h, r)
            var a = [Float](repeating: 0, count: n)
            var b = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let cov = corrIp[i] - meanI[i] * meanP[i]
                let ai = cov / (varI[i] + epsF)
                a[i] = ai
                b[i] = meanP[i] - ai * meanI[i]
            }
            let meanA = p16BoxMean(a, w, h, r)
            let meanB = p16BoxMean(b, w, h, r)
            var q = [Float](repeating: 0, count: n)
            for i in 0..<n { q[i] = meanA[i] * I[i] + meanB[i] }
            channelsOut.append(q)
        }
        p16WriteChannels(channelsOut, to: dst)
    } else {
        // 3-channel color guide (He et al. exact 3x3 covariance inversion per pixel)
        let I0 = p16ExtractChannelF32(guide, 0, 1.0)
        let I1 = p16ExtractChannelF32(guide, 1, 1.0)
        let I2 = p16ExtractChannelF32(guide, 2, 1.0)
        let m0 = p16BoxMean(I0, w, h, r)
        let m1 = p16BoxMean(I1, w, h, r)
        let m2 = p16BoxMean(I2, w, h, r)

        func mulArr(_ u: [Float], _ v: [Float]) -> [Float] {
            var res = [Float](repeating: 0, count: n)
            vDSP_vmul(u, 1, v, 1, &res, 1, vDSP_Length(n))
            return res
        }
        let c00 = p16BoxMean(mulArr(I0, I0), w, h, r)
        let c01 = p16BoxMean(mulArr(I0, I1), w, h, r)
        let c02 = p16BoxMean(mulArr(I0, I2), w, h, r)
        let c11 = p16BoxMean(mulArr(I1, I1), w, h, r)
        let c12 = p16BoxMean(mulArr(I1, I2), w, h, r)
        let c22 = p16BoxMean(mulArr(I2, I2), w, h, r)

        var channelsOut: [[Float]] = []
        for ch in 0..<src.channels {
            let p = p16ExtractChannelF32(src, ch, 1.0)
            let mp = p16BoxMean(p, w, h, r)
            let c0p = p16BoxMean(mulArr(I0, p), w, h, r)
            let c1p = p16BoxMean(mulArr(I1, p), w, h, r)
            let c2p = p16BoxMean(mulArr(I2, p), w, h, r)

            var a0 = [Float](repeating: 0, count: n)
            var a1 = [Float](repeating: 0, count: n)
            var a2 = [Float](repeating: 0, count: n)
            var b = [Float](repeating: 0, count: n)

            for i in 0..<n {
                let s00 = c00[i] - m0[i] * m0[i] + epsF
                let s01 = c01[i] - m0[i] * m1[i]
                let s02 = c02[i] - m0[i] * m2[i]
                let s11 = c11[i] - m1[i] * m1[i] + epsF
                let s12 = c12[i] - m1[i] * m2[i]
                let s22 = c22[i] - m2[i] * m2[i] + epsF

                let k0 = c0p[i] - m0[i] * mp[i]
                let k1 = c1p[i] - m1[i] * mp[i]
                let k2 = c2p[i] - m2[i] * mp[i]

                let inv00 = s11 * s22 - s12 * s12
                let inv01 = s02 * s12 - s01 * s22
                let inv02 = s01 * s12 - s02 * s11
                let inv11 = s00 * s22 - s02 * s02
                let inv12 = s02 * s01 - s00 * s12
                let inv22 = s00 * s11 - s01 * s01
                let det = s00 * inv00 + s01 * inv01 + s02 * inv02
                let invDet = abs(det) > 1e-12 ? (1.0 / det) : 0.0

                let va0 = (inv00 * k0 + inv01 * k1 + inv02 * k2) * invDet
                let va1 = (inv01 * k0 + inv11 * k1 + inv12 * k2) * invDet
                let va2 = (inv02 * k0 + inv12 * k1 + inv22 * k2) * invDet
                a0[i] = va0
                a1[i] = va1
                a2[i] = va2
                b[i] = mp[i] - (va0 * m0[i] + va1 * m1[i] + va2 * m2[i])
            }

            let ma0 = p16BoxMean(a0, w, h, r)
            let ma1 = p16BoxMean(a1, w, h, r)
            let ma2 = p16BoxMean(a2, w, h, r)
            let mb = p16BoxMean(b, w, h, r)

            var q = [Float](repeating: 0, count: n)
            for i in 0..<n {
                q[i] = ma0[i] * I0[i] + ma1[i] * I1[i] + ma2[i] * I2[i] + mb[i]
            }
            channelsOut.append(q)
        }
        p16WriteChannels(channelsOut, to: dst)
    }
    return SRStatus.ok
}

private func p16WriteChannels(_ chans: [[Float]], to dst: SRImage) {
    let w = dst.width
    let h = dst.height
    let c = dst.channels
    for y in 0..<h {
        let off = y * w
        if dst.depth == .u8 {
            let p = dst.row(y).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                for ch in 0..<c {
                    p[x * c + ch] = srSatU8(Double(chans[ch][off + x]))
                }
            }
        } else if dst.depth == .f32 {
            let p = dst.row(y).assumingMemoryBound(to: Float.self)
            for x in 0..<w {
                for ch in 0..<c {
                    p[x * c + ch] = chans[ch][off + x]
                }
            }
        }
    }
}

// Zhang-Suen / Guo-Hall morphological skeleton thinning
@_cdecl("sr_ximgproc_thinning")
public func sr_ximgproc_thinning(
    _ srcData: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sd: Int32,
    _ dstData: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ dd: Int32,
    _ thinningType: Int32
) -> Int32 {
    guard let src = SRImage(srcData, sw, sh, ss, sc, sd),
          let dst = SRImage(dstData, dw, dh, ds, dc, dd),
          src.depth == .u8, dst.depth == .u8,
          src.channels == 1, dst.channels == 1,
          src.width == dst.width, src.height == dst.height else {
        return srFail(SRStatus.badArgument, "sr_ximgproc_thinning: expects 1-ch u8 images of equal size")
    }
    let w = src.width
    let h = src.height
    let n = w * h
    var img = [UInt8](repeating: 0, count: n)
    for y in 0..<h {
        let row = src.row(y).assumingMemoryBound(to: UInt8.self)
        let off = y * w
        for x in 0..<w { img[off + x] = row[x] > 0 ? 1 : 0 }
    }
    var marker = [UInt8](repeating: 0, count: n)
    let useGuoHall = (thinningType == 1)

    var changed = true
    while changed {
        changed = false
        for iter in 0..<2 {
            for i in 0..<n { marker[i] = 0 }
            for y in 1..<(h - 1) {
                let rowOff = y * w
                let prevOff = (y - 1) * w
                let nextOff = (y + 1) * w
                for x in 1..<(w - 1) {
                    if img[rowOff + x] == 0 { continue }
                    let p2 = img[prevOff + x]
                    let p3 = img[prevOff + x + 1]
                    let p4 = img[rowOff + x + 1]
                    let p5 = img[nextOff + x + 1]
                    let p6 = img[nextOff + x]
                    let p7 = img[nextOff + x - 1]
                    let p8 = img[rowOff + x - 1]
                    let p9 = img[prevOff + x - 1]

                    if !useGuoHall {
                        // Zhang-Suen
                        let b = Int(p2 + p3 + p4 + p5 + p6 + p7 + p8 + p9)
                        if b < 2 || b > 6 { continue }
                        var a = 0
                        if p2 == 0 && p3 == 1 { a += 1 }
                        if p3 == 0 && p4 == 1 { a += 1 }
                        if p4 == 0 && p5 == 1 { a += 1 }
                        if p5 == 0 && p6 == 1 { a += 1 }
                        if p6 == 0 && p7 == 1 { a += 1 }
                        if p7 == 0 && p8 == 1 { a += 1 }
                        if p8 == 0 && p9 == 1 { a += 1 }
                        if p9 == 0 && p2 == 1 { a += 1 }
                        if a != 1 { continue }

                        let m1 = iter == 0 ? (p2 & p4 & p6) : (p2 & p4 & p8)
                        let m2 = iter == 0 ? (p4 & p6 & p8) : (p2 & p6 & p8)
                        if m1 == 0 && m2 == 0 {
                            marker[rowOff + x] = 1
                        }
                    } else {
                        // Guo-Hall
                        let c = Int((~p2 & 1) & (p3 | p4)) +
                                Int((~p4 & 1) & (p5 | p6)) +
                                Int((~p6 & 1) & (p7 | p8)) +
                                Int((~p8 & 1) & (p9 | p2))
                        if c != 1 { continue }
                        let n1 = Int(p9 | p2) + Int(p3 | p4) + Int(p5 | p6) + Int(p7 | p8)
                        let n2 = Int(p2 | p3) + Int(p4 | p5) + Int(p6 | p7) + Int(p8 | p9)
                        let nMin = min(n1, n2)
                        if nMin < 2 || nMin > 3 { continue }
                        let m = iter == 0 ? ((p6 | p7 | (~p9 & 1)) & p8) : ((p2 | p3 | (~p5 & 1)) & p4)
                        if m == 0 {
                            marker[rowOff + x] = 1
                        }
                    }
                }
            }
            for i in 0..<n {
                if marker[i] != 0 {
                    img[i] = 0
                    changed = true
                }
            }
        }
    }

    for y in 0..<h {
        let row = dst.row(y).assumingMemoryBound(to: UInt8.self)
        let off = y * w
        for x in 0..<w { row[x] = img[off + x] != 0 ? 255 : 0 }
    }
    return SRStatus.ok
}

// xphoto: SimpleWB (percentile color balance)
@_cdecl("sr_xphoto_simple_wb")
public func sr_xphoto_simple_wb(
    _ srcData: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sd: Int32,
    _ dstData: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ dd: Int32,
    _ p: Float, _ inputMin: Float, _ inputMax: Float, _ outputMin: Float, _ outputMax: Float
) -> Int32 {
    guard let src = SRImage(srcData, sw, sh, ss, sc, sd),
          let dst = SRImage(dstData, dw, dh, ds, dc, dd),
          src.depth == .u8, dst.depth == .u8,
          src.width == dst.width, src.height == dst.height, src.channels == dst.channels else {
        return srFail(SRStatus.badArgument, "sr_xphoto_simple_wb: expects matching u8 images")
    }
    let w = src.width
    let h = src.height
    let c = src.channels
    let total = w * h
    if total == 0 { return SRStatus.ok }

    let halfP = max(0.0, min(49.0, Double(p) * 0.5)) / 100.0
    let loCount = Int(Double(total) * halfP)
    let hiCount = total - loCount

    var lut = [[UInt8]](repeating: [UInt8](repeating: 0, count: 256), count: c)
    for ch in 0..<c {
        var hist = [Int](repeating: 0, count: 256)
        for y in 0..<h {
            let row = src.row(y).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w { hist[Int(row[x * c + ch])] += 1 }
        }
        var acc = 0
        var vmin = Int(inputMin)
        for v in 0..<256 {
            acc += hist[v]
            if acc > loCount { vmin = v; break }
        }
        acc = 0
        var vmax = Int(inputMax)
        for v in 0..<256 {
            acc += hist[v]
            if acc >= hiCount { vmax = v; break }
        }
        let span = max(1, vmax - vmin)
        let oMin = Double(outputMin)
        let oSpan = Double(outputMax - outputMin)
        for v in 0..<256 {
            let clamped = max(vmin, min(vmax, v))
            let val = oMin + Double(clamped - vmin) * oSpan / Double(span)
            lut[ch][v] = srSatU8(val)
        }
    }

    for y in 0..<h {
        let sRow = src.row(y).assumingMemoryBound(to: UInt8.self)
        let dRow = dst.row(y).assumingMemoryBound(to: UInt8.self)
        for x in 0..<w {
            for ch in 0..<c {
                dRow[x * c + ch] = lut[ch][Int(sRow[x * c + ch])]
            }
        }
    }
    return SRStatus.ok
}

// xphoto: GrayworldWB
@_cdecl("sr_xphoto_grayworld_wb")
public func sr_xphoto_grayworld_wb(
    _ srcData: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sd: Int32,
    _ dstData: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ dd: Int32,
    _ saturationThreshold: Float
) -> Int32 {
    guard let src = SRImage(srcData, sw, sh, ss, sc, sd),
          let dst = SRImage(dstData, dw, dh, ds, dc, dd),
          src.depth == .u8, dst.depth == .u8,
          src.width == dst.width, src.height == dst.height, src.channels == dst.channels else {
        return srFail(SRStatus.badArgument, "sr_xphoto_grayworld_wb: expects matching u8 images")
    }
    let w = src.width
    let h = src.height
    let c = src.channels
    let satThresh = Int(round(Double(max(0.1, min(1.0, saturationThreshold))) * 255.0))

    var sums = [Double](repeating: 0, count: c)
    var count = 0
    for y in 0..<h {
        let row = src.row(y).assumingMemoryBound(to: UInt8.self)
        for x in 0..<w {
            var saturated = false
            for ch in 0..<min(3, c) {
                if Int(row[x * c + ch]) >= satThresh { saturated = true; break }
            }
            if saturated { continue }
            for ch in 0..<c { sums[ch] += Double(row[x * c + ch]) }
            count += 1
        }
    }
    if count == 0 {
        for y in 0..<h {
            let row = src.row(y).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w {
                for ch in 0..<c { sums[ch] += Double(row[x * c + ch]) }
            }
        }
        count = max(1, w * h)
    }

    let nColor = min(3, c)
    var avgGray: Double = 0
    for ch in 0..<nColor { avgGray += sums[ch] / Double(count) }
    avgGray /= Double(max(1, nColor))

    var gains = [Double](repeating: 1.0, count: c)
    for ch in 0..<nColor {
        let chMean = sums[ch] / Double(count)
        gains[ch] = chMean > 1e-6 ? (avgGray / chMean) : 1.0
    }

    for y in 0..<h {
        let sRow = src.row(y).assumingMemoryBound(to: UInt8.self)
        let dRow = dst.row(y).assumingMemoryBound(to: UInt8.self)
        for x in 0..<w {
            for ch in 0..<c {
                dRow[x * c + ch] = srSatU8(Double(sRow[x * c + ch]) * gains[ch])
            }
        }
    }
    return SRStatus.ok
}

// xphoto: Oil Painting stylization filter
@_cdecl("sr_xphoto_oil_painting")
public func sr_xphoto_oil_painting(
    _ srcData: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sd: Int32,
    _ dstData: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ dd: Int32,
    _ size: Int32, _ dynRatio: Int32
) -> Int32 {
    guard let src = SRImage(srcData, sw, sh, ss, sc, sd),
          let dst = SRImage(dstData, dw, dh, ds, dc, dd),
          src.depth == .u8, dst.depth == .u8,
          src.width == dst.width, src.height == dst.height, src.channels == dst.channels else {
        return srFail(SRStatus.badArgument, "sr_xphoto_oil_painting: expects matching u8 images")
    }
    let w = src.width
    let h = src.height
    let c = src.channels
    let r = max(1, Int(size))
    let ratio = max(1, Int(dynRatio))
    let nBins = min(256, max(1, 256 / ratio + 1))

    var bins = [Int](repeating: 0, count: w * h)
    for y in 0..<h {
        let row = src.row(y).assumingMemoryBound(to: UInt8.self)
        let off = y * w
        for x in 0..<w {
            let lum: Int
            if c == 1 {
                lum = Int(row[x])
            } else {
                let b = Int(row[x * c])
                let g = Int(row[x * c + 1])
                let rv = Int(row[x * c + 2])
                lum = (29 * b + 150 * g + 77 * rv) >> 8
            }
            bins[off + x] = min(nBins - 1, lum / ratio)
        }
    }

    var counts = [Int](repeating: 0, count: nBins)
    var sumC = [Int](repeating: 0, count: nBins * c)

    for y in 0..<h {
        let y0 = max(0, y - r)
        let y1 = min(h - 1, y + r)
        let dRow = dst.row(y).assumingMemoryBound(to: UInt8.self)
        for x in 0..<w {
            let x0 = max(0, x - r)
            let x1 = min(w - 1, x + r)

            for b in 0..<nBins {
                counts[b] = 0
                for ch in 0..<c { sumC[b * c + ch] = 0 }
            }

            var bestBin = 0
            var bestCount = 0
            for ny in y0...y1 {
                let sRow = src.row(ny).assumingMemoryBound(to: UInt8.self)
                let bOff = ny * w
                for nx in x0...x1 {
                    let bin = bins[bOff + nx]
                    let nc = counts[bin] + 1
                    counts[bin] = nc
                    for ch in 0..<c {
                        sumC[bin * c + ch] += Int(sRow[nx * c + ch])
                    }
                    if nc > bestCount {
                        bestCount = nc
                        bestBin = bin
                    }
                }
            }

            let denom = max(1, bestCount)
            for ch in 0..<c {
                dRow[x * c + ch] = UInt8(min(255, sumC[bestBin * c + ch] / denom))
            }
        }
    }
    return SRStatus.ok
}
