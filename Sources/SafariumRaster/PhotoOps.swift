// SafariumRaster — Phase 8 (`photo` module): inpainting, NLM/TV-L1 denoising,
// seamless cloning / Poisson editing (vDSP DST-I), NPR filters, decolorization, Bayer demosaicing.
import Foundation
import Accelerate
import SafariumRasterC

// MARK: - C bindings from photo_p8.c

@_silgen_name("sr_c_inpaint")
private func sr_c_inpaint(
    _ src: UnsafeRawPointer?, _ w: Int32, _ h: Int32, _ ch: Int32, _ srcStride: Int32, _ depth: Int32,
    _ mask: UnsafePointer<UInt8>?, _ maskStride: Int32,
    _ dst: UnsafeMutableRawPointer?, _ dstStride: Int32,
    _ radius: Double, _ flags: Int32
) -> Int32

@_silgen_name("sr_c_nlm")
private func sr_c_nlm(
    _ src: UnsafeRawPointer?, _ w: Int32, _ h: Int32, _ ch: Int32, _ srcStride: Int32, _ depth: Int32,
    _ dst: UnsafeMutableRawPointer?, _ dstStride: Int32,
    _ hArr: UnsafePointer<Float>?, _ hCount: Int32,
    _ templateWindowSize: Int32, _ searchWindowSize: Int32, _ normType: Int32
) -> Int32

@_silgen_name("sr_c_nlm_multi")
private func sr_c_nlm_multi(
    _ srcs: UnsafePointer<UnsafeRawPointer?>?, _ srcStrides: UnsafePointer<Int32>?,
    _ nFrames: Int32, _ targetIdx: Int32,
    _ w: Int32, _ h: Int32, _ ch: Int32, _ depth: Int32,
    _ dst: UnsafeMutableRawPointer?, _ dstStride: Int32,
    _ hArr: UnsafePointer<Float>?, _ hCount: Int32,
    _ templateWindowSize: Int32, _ searchWindowSize: Int32, _ normType: Int32
) -> Int32

@_silgen_name("sr_c_denoise_tvl1")
private func sr_c_denoise_tvl1(
    _ obs: UnsafePointer<UnsafePointer<UInt8>?>?, _ obsStrides: UnsafePointer<Int32>?, _ nObs: Int32,
    _ w: Int32, _ h: Int32, _ dst: UnsafeMutablePointer<UInt8>?, _ dstStride: Int32,
    _ lambdaVal: Double, _ niters: Int32
) -> Int32

@_silgen_name("sr_c_poisson_solve_f64")
private func sr_c_poisson_solve_f64(_ rhsAndOut: UnsafeMutablePointer<Double>?, _ w: Int32, _ h: Int32) -> Int32

@_silgen_name("sr_c_npr_filter_u8")
private func sr_c_npr_filter_u8(
    _ src: UnsafePointer<UInt8>?, _ w: Int32, _ h: Int32, _ srcStride: Int32,
    _ dst1: UnsafeMutablePointer<UInt8>?, _ dst1Stride: Int32,
    _ dst2: UnsafeMutablePointer<UInt8>?, _ dst2Stride: Int32,
    _ mode: Int32, _ flags: Int32, _ sigmaS: Float, _ sigmaR: Float, _ shadeFactor: Float
) -> Int32

@_silgen_name("sr_c_decolor_u8")
private func sr_c_decolor_u8(
    _ src: UnsafePointer<UInt8>?, _ w: Int32, _ h: Int32, _ srcStride: Int32,
    _ gray: UnsafeMutablePointer<UInt8>?, _ grayStride: Int32,
    _ boost: UnsafeMutablePointer<UInt8>?, _ boostStride: Int32
) -> Int32

@_silgen_name("sr_c_demosaic")
private func sr_c_demosaic(
    _ src: UnsafeRawPointer?, _ w: Int32, _ h: Int32, _ srcStride: Int32, _ depth: Int32,
    _ dst: UnsafeMutableRawPointer?, _ dstStride: Int32, _ dstCh: Int32,
    _ pattern: Int32, _ algo: Int32
) -> Int32

@_silgen_name("sr_c_canny_max_bgr3_u8")
private func sr_c_canny_max_bgr3_u8(
    _ src: UnsafePointer<UInt8>?, _ w: Int32, _ h: Int32, _ srcStride: Int32,
    _ edges: UnsafeMutablePointer<UInt8>?, _ edgeStride: Int32,
    _ lowThreshold: Double, _ highThreshold: Double, _ apertureSize: Int32, _ l2Gradient: Int32
) -> Int32

// MARK: - Self-contained BGR <-> Lab helpers (D65, matching OpenCV COLOR_BGR2Lab / Lab2BGR)

private let labSrgbToLinLUT: [Double] = (0..<256).map { i in
    let v = Double(i) / 255.0
    return v <= 0.04045 ? (v / 12.92) : pow((v + 0.055) / 1.055, 2.4)
}

@inline(__always)
private func labLinToSrgb(_ v: Double) -> Double {
    if v <= 0.0 { return 0.0 }
    if v >= 1.0 { return 1.0 }
    return v <= 0.0031308 ? (v * 12.92) : (1.055 * pow(v, 1.0 / 2.4) - 0.055)
}

@inline(__always)
private func labF(_ t: Double) -> Double {
    t > 0.008856 ? cbrt(t) : (7.787 * t + 16.0 / 116.0)
}

@inline(__always)
private func labFInv(_ t: Double) -> Double {
    let t3 = t * t * t
    return t3 > 0.008856 ? t3 : ((t - 16.0 / 116.0) / 7.787)
}

private func bgrToLabSplitU8(_ src: SRImage, _ lOut: UnsafeMutablePointer<UInt8>, _ abOut: UnsafeMutablePointer<UInt8>) {
    let w = src.width, h = src.height
    for y in 0..<h {
        let sr = src.row(y).assumingMemoryBound(to: UInt8.self)
        let lr = lOut + y * w
        let abr = abOut + y * w * 2
        for x in 0..<w {
            let bl = labSrgbToLinLUT[Int(sr[x * 3 + 0])]
            let gl = labSrgbToLinLUT[Int(sr[x * 3 + 1])]
            let rl = labSrgbToLinLUT[Int(sr[x * 3 + 2])]
            let X = (0.412453 * rl + 0.357580 * gl + 0.180423 * bl) / 0.950456
            let Y = 0.212671 * rl + 0.715160 * gl + 0.072169 * bl
            let Z = (0.019334 * rl + 0.119193 * gl + 0.950227 * bl) / 1.088754
            let fY = labF(Y)
            let L = Y > 0.008856 ? (116.0 * cbrt(Y) - 16.0) : (903.3 * Y)
            let a = 500.0 * (labF(X) - fY)
            let b = 200.0 * (fY - labF(Z))
            lr[x] = srSatU8(L * (255.0 / 100.0))
            abr[x * 2 + 0] = srSatU8(a + 128.0)
            abr[x * 2 + 1] = srSatU8(b + 128.0)
        }
    }
}

private func labMergeToBgrU8(_ lIn: UnsafePointer<UInt8>, _ abIn: UnsafePointer<UInt8>, _ dst: SRImage) {
    let w = dst.width, h = dst.height
    for y in 0..<h {
        let lr = lIn + y * w
        let abr = abIn + y * w * 2
        let dr = dst.row(y).assumingMemoryBound(to: UInt8.self)
        for x in 0..<w {
            let L = Double(lr[x]) * (100.0 / 255.0)
            let a = Double(abr[x * 2 + 0]) - 128.0
            let b = Double(abr[x * 2 + 1]) - 128.0
            let fy = (L + 16.0) / 116.0
            let Y = L > 7.9996248 ? (fy * fy * fy) : (L / 903.3)
            let fyA = labF(Y)
            let X = 0.950456 * labFInv(fyA + a / 500.0)
            let Z = 1.088754 * labFInv(fyA - b / 200.0)
            let r = labLinToSrgb(3.240479 * X - 1.537150 * Y - 0.498535 * Z)
            let g = labLinToSrgb(-0.969256 * X + 1.875992 * Y + 0.041556 * Z)
            let bl = labLinToSrgb(0.055648 * X - 0.204043 * Y + 1.057311 * Z)
            dr[x * 3 + 0] = srSatU8(bl * 255.0)
            dr[x * 3 + 1] = srSatU8(g * 255.0)
            dr[x * 3 + 2] = srSatU8(r * 255.0)
        }
    }
}

// MARK: - 1. Inpainting

@_cdecl("sr_photo_inpaint")
public func sr_photo_inpaint(
    _ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
    _ md: UnsafeMutableRawPointer?, _ mw: Int32, _ mh: Int32, _ ms: Int32, _ mc: Int32, _ mdep: Int32,
    _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
    _ radius: Double, _ flags: Int32
) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep),
          let mask = SRImage(md, mw, mh, ms, mc, mdep),
          let dst = SRImage(dd, dw, dh, ds, dc, ddep) else {
        return srFail(SRStatus.badArgument, "inpaint: invalid image descriptor")
    }
    guard src.width == mask.width, src.height == mask.height,
          src.width == dst.width, src.height == dst.height,
          src.channels == dst.channels, src.depth == dst.depth,
          mask.channels == 1, mask.depth == .u8 else {
        return srFail(SRStatus.badArgument, "inpaint: shape/type mismatch or mask is not CV_8UC1")
    }
    guard src.channels == 1 || src.channels == 3 else {
        return srFail(SRStatus.unsupported, "inpaint: supports 1-ch or 3-ch images")
    }
    guard src.depth == .u8 || src.depth == .u16 || src.depth == .f32 else {
        return srFail(SRStatus.unsupported, "inpaint: supports u8, u16, f32")
    }
    if src.width == 0 || src.height == 0 { return SRStatus.ok }
    let rc = sr_c_inpaint(
        src.data, Int32(src.width), Int32(src.height), Int32(src.channels), Int32(src.stride), src.depth.rawValue,
        mask.data.assumingMemoryBound(to: UInt8.self), Int32(mask.stride),
        dst.data, Int32(dst.stride), radius, flags
    )
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.badArgument, "inpaint: invalid flags or execution failed")
}

// MARK: - 2. Non-Local Means & TV-L1 Denoising

@_cdecl("sr_photo_nlm")
public func sr_photo_nlm(
    _ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
    _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
    _ hArr: UnsafePointer<Float>?, _ hCount: Int32,
    _ templateWindowSize: Int32, _ searchWindowSize: Int32, _ normType: Int32
) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep),
          let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          let hArr else {
        return srFail(SRStatus.badArgument, "fastNlMeansDenoising: null descriptor")
    }
    guard src.width == dst.width, src.height == dst.height,
          src.channels == dst.channels, src.depth == dst.depth else {
        return srFail(SRStatus.badArgument, "fastNlMeansDenoising: shape/type mismatch")
    }
    guard src.depth == .u8 || (src.depth == .u16 && normType == 2) else {
        return srFail(SRStatus.unsupported, "fastNlMeansDenoising: u8 supports L1/L2, u16 supports NORM_L1")
    }
    if src.width == 0 || src.height == 0 { return SRStatus.ok }
    let rc = sr_c_nlm(
        src.data, Int32(src.width), Int32(src.height), Int32(src.channels), Int32(src.stride), src.depth.rawValue,
        dst.data, Int32(dst.stride), hArr, hCount, templateWindowSize, searchWindowSize, normType
    )
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.badArgument, "fastNlMeansDenoising: invalid window or h params")
}

@_cdecl("sr_photo_nlm_colored")
public func sr_photo_nlm_colored(
    _ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
    _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
    _ h: Float, _ hColor: Float, _ templateWindowSize: Int32, _ searchWindowSize: Int32
) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep),
          let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          src.depth == .u8, dst.depth == .u8, src.channels == 3, dst.channels == 3,
          src.width == dst.width, src.height == dst.height else {
        return srFail(SRStatus.badArgument, "fastNlMeansDenoisingColored: requires 3-ch u8 images of equal size")
    }
    let w = src.width, hImg = src.height
    if w == 0 || hImg == 0 { return SRStatus.ok }
    let npix = w * hImg
    let lIn = UnsafeMutablePointer<UInt8>.allocate(capacity: npix)
    let abIn = UnsafeMutablePointer<UInt8>.allocate(capacity: npix * 2)
    let lOut = UnsafeMutablePointer<UInt8>.allocate(capacity: npix)
    let abOut = UnsafeMutablePointer<UInt8>.allocate(capacity: npix * 2)
    defer { lIn.deallocate(); abIn.deallocate(); lOut.deallocate(); abOut.deallocate() }

    bgrToLabSplitU8(src, lIn, abIn)
    var hL = h * Float(sqrt(2.0))
    var hC = hColor * Float(sqrt(2.0))
    let rc1 = sr_c_nlm(lIn, Int32(w), Int32(hImg), 1, Int32(w), 0, lOut, Int32(w), &hL, 1, templateWindowSize, searchWindowSize, 4)
    let rc2 = sr_c_nlm(abIn, Int32(w), Int32(hImg), 2, Int32(w * 2), 0, abOut, Int32(w * 2), &hC, 1, templateWindowSize, searchWindowSize, 4)
    guard rc1 == 0 && rc2 == 0 else {
        return srFail(SRStatus.badArgument, "fastNlMeansDenoisingColored: invalid window parameters")
    }
    labMergeToBgrU8(lOut, abOut, dst)
    return SRStatus.ok
}

@_cdecl("sr_photo_nlm_multi")
public func sr_photo_nlm_multi(
    _ framePtrs: UnsafePointer<UnsafeMutableRawPointer?>?, _ frameStrides: UnsafePointer<Int32>?,
    _ nFrames: Int32, _ targetIdx: Int32, _ w: Int32, _ h: Int32, _ ch: Int32, _ depth: Int32,
    _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
    _ hArr: UnsafePointer<Float>?, _ hCount: Int32,
    _ templateWindowSize: Int32, _ searchWindowSize: Int32, _ normType: Int32
) -> Int32 {
    guard let framePtrs, let frameStrides, let hArr,
          let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          nFrames > 0, targetIdx >= 0, targetIdx < nFrames,
          Int(w) == dst.width, Int(h) == dst.height, Int(ch) == dst.channels, depth == dst.depth.rawValue else {
        return srFail(SRStatus.badArgument, "fastNlMeansDenoisingMulti: bad arguments")
    }
    guard dst.depth == .u8 || (dst.depth == .u16 && normType == 2) else {
        return srFail(SRStatus.unsupported, "fastNlMeansDenoisingMulti: unsupported depth/normType")
    }
    if w == 0 || h == 0 { return SRStatus.ok }
    let rawPtrs = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: Int(nFrames))
    defer { rawPtrs.deallocate() }
    for i in 0..<Int(nFrames) { rawPtrs[i] = UnsafeRawPointer(framePtrs[i]) }
    let rc = sr_c_nlm_multi(
        UnsafePointer(rawPtrs), frameStrides, nFrames, targetIdx, w, h, ch, depth,
        dst.data, Int32(dst.stride), hArr, hCount, templateWindowSize, searchWindowSize, normType
    )
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.badArgument, "fastNlMeansDenoisingMulti: failed")
}

@_cdecl("sr_photo_nlm_colored_multi")
public func sr_photo_nlm_colored_multi(
    _ framePtrs: UnsafePointer<UnsafeMutableRawPointer?>?, _ frameStrides: UnsafePointer<Int32>?,
    _ nFrames: Int32, _ targetIdx: Int32, _ w: Int32, _ h: Int32,
    _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
    _ hVal: Float, _ hColor: Float, _ templateWindowSize: Int32, _ searchWindowSize: Int32
) -> Int32 {
    guard let framePtrs, let frameStrides,
          let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          nFrames > 0, targetIdx >= 0, targetIdx < nFrames,
          Int(w) == dst.width, Int(h) == dst.height, dst.channels == 3, dst.depth == .u8 else {
        return srFail(SRStatus.badArgument, "fastNlMeansDenoisingColoredMulti: bad arguments")
    }
    let nf = Int(nFrames), wi = Int(w), hi = Int(h), npix = wi * hi
    if wi == 0 || hi == 0 { return SRStatus.ok }

    let lBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: nf * npix)
    let abBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: nf * npix * 2)
    let lPtrs = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: nf)
    let abPtrs = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: nf)
    let lStrides = UnsafeMutablePointer<Int32>.allocate(capacity: nf)
    let abStrides = UnsafeMutablePointer<Int32>.allocate(capacity: nf)
    let lOut = UnsafeMutablePointer<UInt8>.allocate(capacity: npix)
    let abOut = UnsafeMutablePointer<UInt8>.allocate(capacity: npix * 2)
    defer {
        lBuf.deallocate(); abBuf.deallocate(); lPtrs.deallocate(); abPtrs.deallocate()
        lStrides.deallocate(); abStrides.deallocate(); lOut.deallocate(); abOut.deallocate()
    }

    for i in 0..<nf {
        guard let src = SRImage(framePtrs[i], w, h, frameStrides[i], 3, 0) else {
            return srFail(SRStatus.badArgument, "fastNlMeansDenoisingColoredMulti: invalid frame")
        }
        let lp = lBuf + i * npix
        let abp = abBuf + i * npix * 2
        bgrToLabSplitU8(src, lp, abp)
        lPtrs[i] = UnsafeRawPointer(lp)
        abPtrs[i] = UnsafeRawPointer(abp)
        lStrides[i] = w
        abStrides[i] = w * 2
    }

    var hL = hVal * Float(sqrt(2.0))
    var hC = hColor * Float(sqrt(2.0))
    let rc1 = sr_c_nlm_multi(UnsafePointer(lPtrs), lStrides, nFrames, targetIdx, w, h, 1, 0, lOut, w, &hL, 1, templateWindowSize, searchWindowSize, 4)
    let rc2 = sr_c_nlm_multi(UnsafePointer(abPtrs), abStrides, nFrames, targetIdx, w, h, 2, 0, abOut, w * 2, &hC, 1, templateWindowSize, searchWindowSize, 4)
    guard rc1 == 0 && rc2 == 0 else {
        return srFail(SRStatus.badArgument, "fastNlMeansDenoisingColoredMulti: failed")
    }
    labMergeToBgrU8(lOut, abOut, dst)
    return SRStatus.ok
}

@_cdecl("sr_photo_denoise_tvl1")
public func sr_photo_denoise_tvl1(
    _ obsPtrs: UnsafePointer<UnsafeMutableRawPointer?>?, _ obsStrides: UnsafePointer<Int32>?,
    _ nObs: Int32, _ w: Int32, _ h: Int32,
    _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
    _ lambdaVal: Double, _ niters: Int32
) -> Int32 {
    guard let obsPtrs, let obsStrides,
          let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          nObs > 0, Int(w) == dst.width, Int(h) == dst.height, dst.channels == 1, dst.depth == .u8 else {
        return srFail(SRStatus.badArgument, "denoise_TVL1: requires 1-ch u8 observations and result")
    }
    if w == 0 || h == 0 { return SRStatus.ok }
    let ptrs = UnsafeMutablePointer<UnsafePointer<UInt8>?>.allocate(capacity: Int(nObs))
    defer { ptrs.deallocate() }
    for i in 0..<Int(nObs) {
        guard let p = obsPtrs[i] else { return srFail(SRStatus.badArgument, "denoise_TVL1: null frame") }
        ptrs[i] = UnsafePointer(p.assumingMemoryBound(to: UInt8.self))
    }
    let rc = sr_c_denoise_tvl1(
        UnsafePointer(ptrs), obsStrides, nObs, w, h,
        dst.data.assumingMemoryBound(to: UInt8.self), Int32(dst.stride), lambdaVal, niters
    )
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.badArgument, "denoise_TVL1: invalid params")
}

// MARK: - 3. Seamless Cloning & Poisson Editing

private enum PoissonMode {
    case normalClone
    case mixedClone
    case monochromeTransfer
    case colorChange(Double, Double, Double)
    case illuminationChange(Double, Double)
    case textureFlattening([UInt8])
}

@inline(__always)
private func readPixD(_ img: SRImage, _ x: Int, _ y: Int, _ c: Int) -> Double {
    let row = img.row(y).assumingMemoryBound(to: UInt8.self)
    return Double(row[x * img.channels + c])
}

private func erodeMask7x7(_ mask: SRImage?, _ w: Int, _ h: Int) -> ([Bool], Bool) {
    guard let m = mask else {
        return ([Bool](repeating: true, count: w * h), true)
    }
    var raw = [Bool](repeating: false, count: w * h)
    var anyRaw = false
    for y in 0..<h {
        let mr = m.row(y).assumingMemoryBound(to: UInt8.self)
        for x in 0..<w {
            if mr[x * m.channels] != 0 {
                raw[y * w + x] = true
                anyRaw = true
            }
        }
    }
    if !anyRaw { return (raw, false) }
    var eroded = [Bool](repeating: false, count: w * h)
    var anyEroded = false
    for y in 0..<h {
        for x in 0..<w {
            var ok = true
            for dy in -3...3 where ok {
                let yy = y + dy
                if yy < 0 || yy >= h { continue }
                for dx in -3...3 {
                    let xx = x + dx
                    if xx < 0 || xx >= w { continue }
                    if !raw[yy * w + xx] { ok = false; break }
                }
            }
            if ok {
                eroded[y * w + x] = true
                anyEroded = true
            }
        }
    }
    return (anyEroded ? (eroded, true) : (raw, true))
}

private func solvePoissonROI(
    src: SRImage, dst: SRImage, mask: SRImage?,
    srcX0: Int, srcY0: Int, dstX0: Int, dstY0: Int, roiW: Int, roiH: Int,
    out: SRImage, mode: PoissonMode, erodeMask: Bool = false
) -> Int32 {
    // Copy dst -> out first so outside ROI is preserved identically
    for y in 0..<dst.height {
        _ = memcpy(out.row(y), dst.row(y), dst.width * dst.channels)
    }
    // Interior of ROI (1-px outer ring serves as Dirichlet boundary)
    let iw = roiW - 2
    let ih = roiH - 2
    if iw <= 0 || ih <= 0 { return SRStatus.ok }

    // Precompute grayscale src if monochrome transfer
    var monoSrc: [Double] = []
    if case .monochromeTransfer = mode {
        monoSrc = [Double](repeating: 0.0, count: roiW * roiH)
        for ry in 0..<roiH {
            let sy = srcY0 + ry
            for rx in 0..<roiW {
                let sx = srcX0 + rx
                let b = readPixD(src, sx, sy, 0)
                let g = readPixD(src, sx, sy, 1)
                let r = readPixD(src, sx, sy, 2)
                monoSrc[ry * roiW + rx] = 0.114 * b + 0.587 * g + 0.299 * r
            }
        }
    }

    // Active mask inside ROI (eroded 7x7 for full-image Poisson effects to match OpenCV Cloning)
    var maskGrid = [Bool](repeating: true, count: roiW * roiH)
    if erodeMask {
        let (erGrid, anyOn) = erodeMask7x7(mask, src.width, src.height)
        if !anyOn { return SRStatus.ok }
        for ry in 0..<roiH {
            let sy = srcY0 + ry
            for rx in 0..<roiW {
                maskGrid[ry * roiW + rx] = erGrid[sy * src.width + (srcX0 + rx)]
            }
        }
    } else if let m = mask {
        var anyOn = false
        for ry in 0..<roiH {
            let sy = srcY0 + ry
            let mr = m.row(sy).assumingMemoryBound(to: UInt8.self)
            for rx in 0..<roiW {
                let sx = srcX0 + rx
                let on = mr[sx * m.channels] != 0
                maskGrid[ry * roiW + rx] = on
                if on { anyOn = true }
            }
        }
        if !anyOn { return SRStatus.ok }
    }

    let n = iw * ih
    let gxArr = UnsafeMutablePointer<Double>.allocate(capacity: roiW * roiH)
    let gyArr = UnsafeMutablePointer<Double>.allocate(capacity: roiW * roiH)
    let rhs = UnsafeMutablePointer<Double>.allocate(capacity: n)
    defer { gxArr.deallocate(); gyArr.deallocate(); rhs.deallocate() }

    for c in 0..<3 {
        // Compute guidance gradients gxArr[ry, rx] = u(rx+1, ry) - u(rx, ry) and gyArr[ry, rx] = u(rx, ry+1) - u(rx, ry)
        for ry in 0..<roiH {
            let sy = srcY0 + ry
            let dy = dstY0 + ry
            for rx in 0..<roiW {
                let sx = srcX0 + rx
                let dx = dstX0 + rx
                let idx = ry * roiW + rx
                let inM = maskGrid[idx]

                let dvX = (rx + 1 < roiW) ? (readPixD(dst, dx + 1, dy, c) - readPixD(dst, dx, dy, c)) : 0.0
                let dvY = (ry + 1 < roiH) ? (readPixD(dst, dx, dy + 1, c) - readPixD(dst, dx, dy, c)) : 0.0

                let svX: Double
                let svY: Double
                if case .monochromeTransfer = mode {
                    svX = (rx + 1 < roiW) ? (monoSrc[idx + 1] - monoSrc[idx]) : 0.0
                    svY = (ry + 1 < roiH) ? (monoSrc[idx + roiW] - monoSrc[idx]) : 0.0
                } else {
                    svX = (rx + 1 < roiW) ? (readPixD(src, sx + 1, sy, c) - readPixD(src, sx, sy, c)) : 0.0
                    svY = (ry + 1 < roiH) ? (readPixD(src, sx, sy + 1, c) - readPixD(src, sx, sy, c)) : 0.0
                }

                let inRight: Bool
                let inDown: Bool
                if erodeMask {
                    inRight = (rx + 1 < roiW) ? (inM && maskGrid[idx + 1]) : false
                    inDown = (ry + 1 < roiH) ? (inM && maskGrid[idx + roiW]) : false
                } else {
                    inRight = (rx + 1 < roiW) ? (inM || maskGrid[idx + 1]) : inM
                    inDown = (ry + 1 < roiH) ? (inM || maskGrid[idx + roiW]) : inM
                }

                switch mode {
                case .normalClone, .monochromeTransfer:
                    gxArr[idx] = inRight ? svX : dvX
                    gyArr[idx] = inDown ? svY : dvY
                case .mixedClone:
                    if inRight {
                        // Compare gradient magnitude across all 3 channels at this edge
                        var magS = 0.0, magD = 0.0
                        if rx + 1 < roiW {
                            for k in 0..<3 {
                                let gs = readPixD(src, sx + 1, sy, k) - readPixD(src, sx, sy, k)
                                let gd = readPixD(dst, dx + 1, dy, k) - readPixD(dst, dx, dy, k)
                                magS += gs * gs; magD += gd * gd
                            }
                        }
                        gxArr[idx] = (magS >= magD) ? svX : dvX
                    } else {
                        gxArr[idx] = dvX
                    }
                    if inDown {
                        var magS = 0.0, magD = 0.0
                        if ry + 1 < roiH {
                            for k in 0..<3 {
                                let gs = readPixD(src, sx, sy + 1, k) - readPixD(src, sx, sy, k)
                                let gd = readPixD(dst, dx, dy + 1, k) - readPixD(dst, dx, dy, k)
                                magS += gs * gs; magD += gd * gd
                            }
                        }
                        gyArr[idx] = (magS >= magD) ? svY : dvY
                    } else {
                        gyArr[idx] = dvY
                    }
                case .colorChange(let bMul, let gMul, let rMul):
                    let mul = (c == 0) ? bMul : ((c == 1) ? gMul : rMul)
                    gxArr[idx] = inRight ? (svX * mul) : dvX
                    gyArr[idx] = inDown ? (svY * mul) : dvY
                case .illuminationChange(let alpha, let beta):
                    let ab = pow(max(alpha, 1e-6), beta)
                    let mag = hypot(svX, svY)
                    let fac = mag > 1e-6 ? (ab * pow(mag, -beta)) : 0.0
                    gxArr[idx] = inRight ? (svX * fac) : dvX
                    gyArr[idx] = inDown ? (svY * fac) : dvY
                case .textureFlattening(let edges):
                    let dw = dst.width
                    let eHere = edges[dy * dw + dx] != 0
                    gxArr[idx] = inRight ? (eHere ? svX : 0.0) : dvX
                    gyArr[idx] = inDown ? (eHere ? svY : 0.0) : dvY
                }
            }
        }

        // Assemble interior RHS: div(g) - boundary contributions for discrete 5-pt Laplacian
        for iy in 0..<ih {
            let ry = iy + 1
            let dy = dstY0 + ry
            for ix in 0..<iw {
                let rx = ix + 1
                let dx = dstX0 + rx
                let rIdx = ry * roiW + rx
                var val = (gxArr[rIdx] - gxArr[rIdx - 1]) + (gyArr[rIdx] - gyArr[rIdx - roiW])
                if ix == 0 { val -= readPixD(dst, dstX0, dy, c) }
                if ix == iw - 1 { val -= readPixD(dst, dstX0 + roiW - 1, dy, c) }
                if iy == 0 { val -= readPixD(dst, dx, dstY0, c) }
                if iy == ih - 1 { val -= readPixD(dst, dx, dstY0 + roiH - 1, c) }
                rhs[iy * iw + ix] = val
            }
        }

        if sr_c_poisson_solve_f64(rhs, Int32(iw), Int32(ih)) != 0 {
            return srFail(SRStatus.internalError, "Poisson solver failed")
        }

        for iy in 0..<ih {
            let dy = dstY0 + iy + 1
            let outRow = out.row(dy).assumingMemoryBound(to: UInt8.self)
            for ix in 0..<iw {
                let dx = dstX0 + ix + 1
                outRow[dx * 3 + c] = srSatU8(rhs[iy * iw + ix])
            }
        }
    }
    return SRStatus.ok
}

private func findMaskBBox(_ mask: SRImage?, _ w: Int, _ h: Int) -> (Int, Int, Int, Int)? {
    guard let m = mask else { return (0, 0, w, h) }
    var minX = w, minY = h, maxX = -1, maxY = -1
    for y in 0..<h {
        let mr = m.row(y).assumingMemoryBound(to: UInt8.self)
        for x in 0..<w {
            if mr[x * m.channels] != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    if maxX < minX || maxY < minY { return nil }
    return (minX, minY, maxX - minX + 1, maxY - minY + 1)
}

@_cdecl("sr_photo_seamless_clone")
public func sr_photo_seamless_clone(
    _ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
    _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
    _ md: UnsafeMutableRawPointer?, _ mw: Int32, _ mh: Int32, _ ms: Int32, _ mc: Int32, _ mdep: Int32,
    _ od: UnsafeMutableRawPointer?, _ ow: Int32, _ oh: Int32, _ os: Int32, _ oc: Int32, _ odep: Int32,
    _ px: Int32, _ py: Int32, _ flags: Int32
) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep),
          let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          let out = SRImage(od, ow, oh, os, oc, odep),
          src.depth == .u8, dst.depth == .u8, out.depth == .u8,
          src.channels == 3, dst.channels == 3, out.channels == 3,
          dst.width == out.width, dst.height == out.height else {
        return srFail(SRStatus.badArgument, "seamlessClone: requires 3-ch u8 src/dst/blend")
    }
    let maskImg = (md != nil && mw > 0 && mh > 0) ? SRImage(md, mw, mh, ms, mc, mdep) : nil
    if let m = maskImg {
        guard m.width == src.width, m.height == src.height, m.depth == .u8 else {
            return srFail(SRStatus.badArgument, "seamlessClone: mask must match src dimensions")
        }
    }
    for y in 0..<dst.height { _ = memcpy(out.row(y), dst.row(y), dst.width * 3) }
    guard let (bx, by, bw, bh) = findMaskBBox(maskImg, src.width, src.height) else {
        return SRStatus.ok
    }

    // Center mask bounding box at (px, py) in dst; clip to valid src/dst overlap
    let targetX0 = Int(px) - bw / 2
    let targetY0 = Int(py) - bh / 2

    let dx0 = max(0, targetX0)
    let dy0 = max(0, targetY0)
    let dx1 = min(dst.width, targetX0 + bw)
    let dy1 = min(dst.height, targetY0 + bh)
    let sx0 = bx + (dx0 - targetX0)
    let sy0 = by + (dy0 - targetY0)
    let cw = min(dx1 - dx0, src.width - sx0)
    let ch = min(dy1 - dy0, src.height - sy0)
    if cw <= 2 || ch <= 2 { return SRStatus.ok }

    let mode: PoissonMode
    switch flags {
    case 1, 9: mode = .normalClone
    case 2, 10: mode = .mixedClone
    case 3: mode = .monochromeTransfer
    default: return srFail(SRStatus.badArgument, "seamlessClone: invalid flags \(flags)")
    }
    return solvePoissonROI(src: src, dst: dst, mask: maskImg,
                           srcX0: sx0, srcY0: sy0, dstX0: dx0, dstY0: dy0, roiW: cw, roiH: ch,
                           out: out, mode: mode, erodeMask: true)
}

@_cdecl("sr_photo_color_change")
public func sr_photo_color_change(
    _ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
    _ md: UnsafeMutableRawPointer?, _ mw: Int32, _ mh: Int32, _ ms: Int32, _ mc: Int32, _ mdep: Int32,
    _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
    _ redMul: Double, _ greenMul: Double, _ blueMul: Double
) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep),
          let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          src.depth == .u8, dst.depth == .u8, src.channels == 3, dst.channels == 3,
          src.width == dst.width, src.height == dst.height else {
        return srFail(SRStatus.badArgument, "colorChange: requires 3-ch u8 images")
    }
    let mask = (md != nil && mw > 0 && mh > 0) ? SRImage(md, mw, mh, ms, mc, mdep) : nil
    for y in 0..<src.height { _ = memcpy(dst.row(y), src.row(y), src.width * 3) }
    guard findMaskBBox(mask, src.width, src.height) != nil else { return SRStatus.ok }
    return solvePoissonROI(src: src, dst: src, mask: mask,
                           srcX0: 0, srcY0: 0, dstX0: 0, dstY0: 0, roiW: src.width, roiH: src.height,
                           out: dst, mode: .colorChange(blueMul, greenMul, redMul), erodeMask: true)
}

@_cdecl("sr_photo_illumination_change")
public func sr_photo_illumination_change(
    _ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
    _ md: UnsafeMutableRawPointer?, _ mw: Int32, _ mh: Int32, _ ms: Int32, _ mc: Int32, _ mdep: Int32,
    _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
    _ alpha: Double, _ beta: Double
) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep),
          let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          src.depth == .u8, dst.depth == .u8, src.channels == 3, dst.channels == 3,
          src.width == dst.width, src.height == dst.height else {
        return srFail(SRStatus.badArgument, "illuminationChange: requires 3-ch u8 images")
    }
    let mask = (md != nil && mw > 0 && mh > 0) ? SRImage(md, mw, mh, ms, mc, mdep) : nil
    for y in 0..<src.height { _ = memcpy(dst.row(y), src.row(y), src.width * 3) }
    guard findMaskBBox(mask, src.width, src.height) != nil else { return SRStatus.ok }
    return solvePoissonROI(src: src, dst: src, mask: mask,
                           srcX0: 0, srcY0: 0, dstX0: 0, dstY0: 0, roiW: src.width, roiH: src.height,
                           out: dst, mode: .illuminationChange(alpha, beta), erodeMask: true)
}

@_cdecl("sr_photo_texture_flattening")
public func sr_photo_texture_flattening(
    _ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
    _ md: UnsafeMutableRawPointer?, _ mw: Int32, _ mh: Int32, _ ms: Int32, _ mc: Int32, _ mdep: Int32,
    _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
    _ lowThreshold: Double, _ highThreshold: Double, _ kernelSize: Int32
) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep),
          let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          src.depth == .u8, dst.depth == .u8, src.channels == 3, dst.channels == 3,
          src.width == dst.width, src.height == dst.height else {
        return srFail(SRStatus.badArgument, "textureFlattening: requires 3-ch u8 images")
    }
    let mask = (md != nil && mw > 0 && mh > 0) ? SRImage(md, mw, mh, ms, mc, mdep) : nil
    for y in 0..<src.height { _ = memcpy(dst.row(y), src.row(y), src.width * 3) }
    guard findMaskBBox(mask, src.width, src.height) != nil else { return SRStatus.ok }

    var edges = [UInt8](repeating: 0, count: src.width * src.height)
    let rc = edges.withUnsafeMutableBufferPointer { ep in
        sr_c_canny_max_bgr3_u8(src.data.assumingMemoryBound(to: UInt8.self), Int32(src.width), Int32(src.height),
                               Int32(src.stride), ep.baseAddress!, Int32(src.width),
                               lowThreshold, highThreshold, kernelSize, 0)
    }
    if rc != 0 { return srFail(SRStatus.badArgument, "textureFlattening: invalid Canny parameters") }

    return solvePoissonROI(src: src, dst: src, mask: mask,
                           srcX0: 0, srcY0: 0, dstX0: 0, dstY0: 0, roiW: src.width, roiH: src.height,
                           out: dst, mode: .textureFlattening(edges), erodeMask: true)
}

// MARK: - 4. NPR Filters (edgePreservingFilter, detailEnhance, pencilSketch, stylization)

@_cdecl("sr_photo_npr")
public func sr_photo_npr(
    _ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
    _ d1d: UnsafeMutableRawPointer?, _ d1w: Int32, _ d1h: Int32, _ d1s: Int32, _ d1c: Int32, _ d1dep: Int32,
    _ d2d: UnsafeMutableRawPointer?, _ d2w: Int32, _ d2h: Int32, _ d2s: Int32, _ d2c: Int32, _ d2dep: Int32,
    _ mode: Int32, _ flags: Int32, _ sigmaS: Double, _ sigmaR: Double, _ shadeFactor: Double
) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep),
          let d1 = SRImage(d1d, d1w, d1h, d1s, d1c, d1dep),
          src.depth == .u8, d1.depth == .u8, src.channels == 3,
          src.width == d1.width, src.height == d1.height else {
        return srFail(SRStatus.badArgument, "NPR filter: invalid src or dst1")
    }
    var d2Ptr: UnsafeMutablePointer<UInt8>? = nil
    var d2Stride: Int32 = 0
    if mode == 2 {
        guard let d2 = SRImage(d2d, d2w, d2h, d2s, d2c, d2dep),
              d2.depth == .u8, d2.channels == 3, d1.channels == 1,
              d2.width == src.width, d2.height == src.height else {
            return srFail(SRStatus.badArgument, "pencilSketch: requires 1-ch u8 dst1 and 3-ch u8 dst2")
        }
        d2Ptr = d2.data.assumingMemoryBound(to: UInt8.self)
        d2Stride = Int32(d2.stride)
    } else if d1.channels != 3 {
        return srFail(SRStatus.badArgument, "NPR filter: requires 3-ch u8 output")
    }
    if src.width == 0 || src.height == 0 { return SRStatus.ok }
    let rc = sr_c_npr_filter_u8(
        src.data.assumingMemoryBound(to: UInt8.self), Int32(src.width), Int32(src.height), Int32(src.stride),
        d1.data.assumingMemoryBound(to: UInt8.self), Int32(d1.stride),
        d2Ptr, d2Stride, mode, flags, Float(sigmaS), Float(sigmaR), Float(shadeFactor)
    )
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.badArgument, "NPR filter: execution failed")
}

// MARK: - 5. Decolorization & Demosaicing

@_cdecl("sr_photo_decolor")
public func sr_photo_decolor(
    _ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
    _ gd: UnsafeMutableRawPointer?, _ gw: Int32, _ gh: Int32, _ gs: Int32, _ gc: Int32, _ gdep: Int32,
    _ bd: UnsafeMutableRawPointer?, _ bw: Int32, _ bh: Int32, _ bs: Int32, _ bc: Int32, _ bdep: Int32
) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep),
          let gray = SRImage(gd, gw, gh, gs, gc, gdep),
          let boost = SRImage(bd, bw, bh, bs, bc, bdep),
          src.depth == .u8, gray.depth == .u8, boost.depth == .u8,
          src.channels == 3, gray.channels == 1, boost.channels == 3,
          src.width == gray.width, src.height == gray.height,
          src.width == boost.width, src.height == boost.height else {
        return srFail(SRStatus.badArgument, "decolor: requires 3-ch u8 src/color_boost and 1-ch u8 grayscale")
    }
    if src.width == 0 || src.height == 0 { return SRStatus.ok }
    let rc = sr_c_decolor_u8(
        src.data.assumingMemoryBound(to: UInt8.self), Int32(src.width), Int32(src.height), Int32(src.stride),
        gray.data.assumingMemoryBound(to: UInt8.self), Int32(gray.stride),
        boost.data.assumingMemoryBound(to: UInt8.self), Int32(boost.stride)
    )
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.internalError, "decolor: failed")
}

@_cdecl("sr_photo_demosaicing")
public func sr_photo_demosaicing(
    _ sd: UnsafeMutableRawPointer?, _ sw: Int32, _ sh: Int32, _ ss: Int32, _ sc: Int32, _ sdep: Int32,
    _ dd: UnsafeMutableRawPointer?, _ dw: Int32, _ dh: Int32, _ ds: Int32, _ dc: Int32, _ ddep: Int32,
    _ pattern: Int32, _ algo: Int32
) -> Int32 {
    guard let src = SRImage(sd, sw, sh, ss, sc, sdep),
          let dst = SRImage(dd, dw, dh, ds, dc, ddep),
          src.channels == 1, src.depth == dst.depth,
          (src.depth == .u8 || src.depth == .u16),
          src.width == dst.width, src.height == dst.height else {
        return srFail(SRStatus.badArgument, "demosaicing: requires 1-ch u8/u16 src and matching depth/size dst")
    }
    if src.width == 0 || src.height == 0 { return SRStatus.ok }
    let rc = sr_c_demosaic(
        src.data, Int32(src.width), Int32(src.height), Int32(src.stride), src.depth.rawValue,
        dst.data, Int32(dst.stride), Int32(dst.channels), pattern, algo
    )
    return rc == 0 ? SRStatus.ok : srFail(SRStatus.badArgument, "demosaicing: invalid output channels or pattern")
}
