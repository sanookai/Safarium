// SafariumRaster — VideoWriter backend (phase 6): AVAssetWriter, frames streamed one at a time. No FFmpeg.
//
// Streaming: `write` copies the caller's frame into a pooled BGRA CVPixelBuffer and hands it to a serial queue that
// appends to the writer input whenever it is ready. At most `maxInFlight` frames wait in that queue; the caller blocks
// (backpressure) when it is full, so memory is bounded by a few frames, never the clip.
// Codecs: H.264 (avc1/H264), HEVC (hvc1/HEVC, alpha with hevcWithAlpha), ProRes (apcn/apch/apcs/apco/ap4h/ap4x;
// ap4h keeps alpha), MJPG (AVFoundation JPEG, mov). MPEG-4 part 2 ('mp4v'), DIVX, XVID, VP8/9, AV1 and the
// avi/mkv/webm containers are refused: Apple's stack has no encoder / muxer for them and FFmpeg is not allowed.
// Pixels are tagged BT.709 SDR (the same as the rest of the Safarium video path).

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import Accelerate

private let maxInFlight = 2

func vwFourccString(_ v: UInt32) -> String {
    String(decoding: [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8((v >> 24) & 255)], as: UTF8.self)
}

/// (num, den) with fps == num/den: integers, the NTSC family and /1000 for anything else.
/// Callers must pass 0 < fps <= vwMaxFPS (finite): larger values would not fit the Int32 time scale.
let vwMaxFPS = 100_000.0

func vwRational(_ fps: Double) -> (Int32, Int32) {
    precondition(fps.isFinite && fps > 0 && fps <= vwMaxFPS)
    if abs(fps - fps.rounded()) < 1e-6 { return (Int32(fps.rounded()), 1) }
    for den in [1001, 1000, 100, 10] as [Int32] {
        let n = (fps * Double(den)).rounded()
        if abs(n / Double(den) - fps) < 1e-6, n < Double(Int32.max) { return (Int32(n), den) }
    }
    return (Int32((fps * 1000).rounded()), 1000)
}

private func vwGcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : vwGcd(b, a % b) }

enum VWCodec {
    case h264, hevc, prores(AVVideoCodecType, alpha: Bool), jpeg

    /// nil = not encodable here (message in `why`).
    static func from(fourcc f: String, why: inout String) -> VWCodec? {
        switch f {
        case "avc1", "H264", "h264", "X264", "x264", "avc3": return .h264
        case "hvc1", "HEVC", "hevc", "hev1", "H265", "h265", "X265", "x265": return .hevc
        case "apcn": return .prores(.proRes422, alpha: false)
        case "apch": return .prores(.proRes422HQ, alpha: false)
        case "apcs": return .prores(.proRes422LT, alpha: false)
        case "apco": return .prores(.proRes422Proxy, alpha: false)
        case "ap4h", "ap4x": return .prores(.proRes4444, alpha: true)
        case "MJPG", "mjpg", "jpeg", "JPEG": return .jpeg
        case "mp4v", "MP4V", "FMP4", "DIVX", "XVID", "DX50", "MPG4", "MP42", "MP43", "H263", "X263", "FLV1", "VP80", "VP90", "AV01":
            why = "fourcc '\(f)' needs an encoder Apple's media stack does not have (no FFmpeg/libav allowed); use 'avc1', 'hvc1', 'apcn'/'ap4h' or 'MJPG'"
            return nil
        default:
            why = "unsupported fourcc '\(f)'"
            return nil
        }
    }
}

final class VideoWriterBox: @unchecked Sendable {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor?   // nil for Motion JPEG (our own encoder feeds finished samples)
    private let jpegQuality: Int32?
    private let jpegFormat: CMFormatDescription?
    let width: Int, height: Int
    let fpsNum: Int32, fpsDen: Int32
    let isColor: Bool
    let alphaOK: Bool
    /// JPEG: every decoder reads Motion JPEG as BT.601, so the RGB -> YCbCr conversion must use that matrix.
    let tagBT601: Bool
    private(set) var framesWritten = 0
    private let queue = DispatchQueue(label: "safarium.videowriter")
    private let slots = DispatchSemaphore(value: maxInFlight)
    private let done = DispatchSemaphore(value: 0)
    // queue-confined state
    private var pending: [(CVPixelBuffer?, CMSampleBuffer?, CMTime)] = []
    private var finishRequested = false
    private var finishStarted = false
    private var finishTime = CMTime.zero
    private(set) var released = false

    init?(path: String, fourcc: UInt32, fps: Double, width: Int, height: Int, isColor: Bool, params: [Int: Double], error: inout String) {
        guard width > 0, height > 0, width <= 32768, height <= 32768 else { error = "frame size \(width)x\(height) is out of range (1...32768)"; return nil }
        guard fps.isFinite, fps > 0, fps <= vwMaxFPS else { error = "fps \(fps) is out of range (0 < fps <= \(Int(vwMaxFPS)))"; return nil }
        // Every numeric parameter must be finite and in range before it is converted to an integer.
        func param(_ key: Int, _ lo: Double, _ hi: Double, _ name: String) -> Double?? {
            guard let v = params[key] else { return .some(nil) }
            guard v.isFinite, v >= lo, v <= hi else { error = "\(name) = \(v) is out of range (\(lo)...\(hi))"; return nil }
            return .some(v)
        }
        guard let pBitrate = param(16, 1, 2_000_000_000, "bitrate"), let pQuality = param(1, 0, 100, "quality"),
              let pCRF = param(17, 0, 51, "crf"), let pGop = param(19, 0, 1_000_000, "gop size"),
              let pKey = param(10, 0, 1_000_000, "key interval"), let pAlpha = param(15, -1e9, 1e9, "enable alpha") else { return nil }
        var why = ""
        guard let codec = VWCodec.from(fourcc: vwFourccString(fourcc), why: &why) else { error = why; return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        let fileType: AVFileType
        switch ext {
        case "mp4": fileType = .mp4
        case "m4v": fileType = .m4v
        case "mov": fileType = .mov
        default:
            error = "container '.\(ext)' is not supported (mp4, m4v and mov only; avi/mkv/webm need FFmpeg)"
            return nil
        }
        switch codec {
        case .h264, .hevc:
            // 4:2:0 needs even sides; AVAssetWriter would silently crop to even, which changes the resolution.
            if width % 2 != 0 || height % 2 != 0 { error = "\(width)x\(height): H.264/HEVC need even width and height (pad or crop the frames first)"; return nil }
        default: break
        }
        var settings: [String: Any] = [AVVideoWidthKey: width, AVVideoHeightKey: height]
        var comp: [String: Any] = [:]
        let wantAlpha = (pAlpha ?? 0) != 0
        var alpha = false
        let bitrate = pBitrate.map { Int($0) }                 // VIDEOWRITER_PROP_BITRATE, bits/s
        let quality = pQuality.map { $0 / 100 }  // VIDEOWRITER_PROP_QUALITY 0..100
        let crf = pCRF                                     // VIDEOWRITER_PROP_CRF 0..51 (lower = better)
        let gop = (pGop ?? pKey).map { Int($0) }     // GOP_SIZE / KEY_INTERVAL
        let colour: [String: Any] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        switch codec {
        case .h264, .hevc:
            var hevc = false
            if case .hevc = codec { hevc = true }
            settings[AVVideoCodecKey] = hevc ? (wantAlpha ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.hevc) : AVVideoCodecType.h264
            alpha = hevc && wantAlpha
            if wantAlpha && !hevc { error = "alpha needs HEVC ('hvc1') or ProRes 4444 ('ap4h'); H.264 has no alpha"; return nil }
            // Apple's H.264 encoder does not take a quality value (canApply flips with load), so for H.264 QUALITY / CRF
            // become an average bit rate in bits per pixel (0.03 at quality 0 up to 0.75 at 100, geometric in between).
            // HEVC takes the quality value directly.
            let q = quality ?? crf.map { max(0, min(1, 1 - $0 / 51)) }
            if let b = bitrate {
                comp[AVVideoAverageBitRateKey] = b
            } else if let q {
                if hevc { comp[AVVideoQualityKey] = q }
                else { comp[AVVideoAverageBitRateKey] = max(100_000, Int(min(2e9, Double(width * height) * fps * 0.03 * pow(25, q)))) }
            } else {
                comp[AVVideoAverageBitRateKey] = max(2_000_000, Int(min(2e9, Double(width * height) * fps * 0.2)))
            }
            if let g = gop, g > 0 { comp[AVVideoMaxKeyFrameIntervalKey] = g }
            if !hevc { comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            settings[AVVideoColorPropertiesKey] = colour
        case .prores(let t, let a):
            if fileType == .mp4 || fileType == .m4v { error = "ProRes needs a .mov container"; return nil }
            settings[AVVideoCodecKey] = t
            alpha = a
            settings[AVVideoColorPropertiesKey] = colour
        case .jpeg:
            if fileType != .mov { error = "MJPG needs a .mov container (mp4 cannot carry Motion JPEG)"; return nil }
            // Motion JPEG: frames are compressed by Safarium's own JPEG encoder (JFIF, BT.601 full range, which every
            // decoder expects) and passed through to the file untouched.
            break
        }
        var isJPEG = false
        if case .jpeg = codec { isJPEG = true }
        if !comp.isEmpty { settings[AVVideoCompressionPropertiesKey] = comp }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        guard let w = try? AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: fileType) else {
            error = "cannot create \(path)"; return nil
        }
        var fmt: CMFormatDescription?
        let inp: AVAssetWriterInput
        if isJPEG {
            CMVideoFormatDescriptionCreate(allocator: nil, codecType: kCMVideoCodecType_JPEG, width: Int32(width), height: Int32(height), extensions: [kCMFormatDescriptionExtension_PixelAspectRatio: [kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: 1, kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: 1]] as CFDictionary, formatDescriptionOut: &fmt)
            guard let fmt else { error = "cannot describe the JPEG track"; return nil }
            inp = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
        } else {
            guard w.canApply(outputSettings: settings, forMediaType: .video) else {
                error = "this Mac cannot encode these settings (\(vwFourccString(fourcc)) \(width)x\(height))"; return nil
            }
            inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        }
        inp.expectsMediaDataInRealTime = false
        let (num, den) = vwRational(fps)
        let g = vwGcd(600, Int(num))
        let mts = Int(num) / g * 600
        if mts > 0, mts <= 600_000 { inp.mediaTimeScale = CMTimeScale(mts) }
        let ad: AVAssetWriterInputPixelBufferAdaptor? = isJPEG ? nil : AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard w.canAdd(inp) else { error = "writer refused the video input"; return nil }
        w.add(inp)
        guard w.startWriting() else { error = "writer: \(w.error?.localizedDescription ?? "cannot start")"; return nil }
        w.startSession(atSourceTime: .zero)
        self.writer = w
        self.input = inp
        self.adaptor = ad
        self.jpegFormat = fmt
        self.jpegQuality = isJPEG ? Int32(pQuality ?? 95) : nil
        self.width = width
        self.height = height
        self.fpsNum = num
        self.fpsDen = den
        self.isColor = isColor
        self.alphaOK = alpha
        tagBT601 = false
        inp.requestMediaDataWhenReady(on: queue) { [weak self] in self?.pump() }
    }

    /// Queue-confined: append everything the input will take; start finishing once drained.
    private func pump() {
        if writer.status == .failed || writer.status == .cancelled {
            while !pending.isEmpty { pending.removeFirst(); slots.signal() }
        }
        while !pending.isEmpty, input.isReadyForMoreMediaData {
            let (pb, sb, t) = pending.removeFirst()
            if let sb { _ = input.append(sb) } else if let pb { _ = adaptor?.append(pb, withPresentationTime: t) }
            slots.signal()
        }
        if finishRequested, pending.isEmpty, !finishStarted {
            finishStarted = true
            if writer.status == .writing {
                input.markAsFinished()
                writer.endSession(atSourceTime: finishTime)
                writer.finishWriting { [done] in done.signal() }
            } else {
                done.signal()
            }
        }
    }

    var failure: String? {
        switch writer.status {
        case .failed: return writer.error?.localizedDescription ?? "writer failed"
        case .cancelled: return "writer was cancelled"
        default: return nil
        }
    }

    /// Test hook: abort the writer mid-stream (what a failing encoder looks like to the caller).
    func forceFailure() { writer.cancelWriting() }

    /// 0 ok, <0 failure (message through srFail).
    func write(_ img: SRImage) -> Int32 {
        guard !released else { return srFail(SRStatus.badArgument, "VideoWriter: write after release") }
        if let f = failure { return srFail(SRStatus.ioFailure, "VideoWriter: \(f)") }
        guard img.depth == .u8 else { return srFail(SRStatus.badArgument, "VideoWriter: frames must be 8-bit") }
        guard img.width == width, img.height == height else {
            return srFail(SRStatus.badArgument, "VideoWriter: frame is \(img.width)x\(img.height), the writer was opened for \(width)x\(height)")
        }
        let okChannels = isColor ? (img.channels == 3 || (img.channels == 4 && alphaOK)) : img.channels == 1
        guard okChannels else {
            return srFail(SRStatus.badArgument, "VideoWriter: \(img.channels)-channel frame does not match isColor=\(isColor)\(isColor && img.channels == 4 ? " (4 channels need an alpha codec: ap4h or HEVC with alpha)" : "")")
        }
        // Backpressure: wait for a free slot (or a writer failure).
        while slots.wait(timeout: .now() + 0.25) == .timedOut {
            if let f = failure { return srFail(SRStatus.ioFailure, "VideoWriter: \(f)") }
        }
        if let q = jpegQuality { return writeJPEG(img, quality: q) }
        guard let adaptor, let pool = adaptor.pixelBufferPool else { slots.signal(); return srFail(SRStatus.ioFailure, "VideoWriter: no pixel-buffer pool") }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let pb = out else {
            slots.signal(); return srFail(SRStatus.ioFailure, "VideoWriter: cannot allocate a frame buffer")
        }
        if tagBT601 {
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_SMPTE_C, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        }
        CVPixelBufferLockBaseAddress(pb, [])
        let rc = vwFill(pb, img)
        CVPixelBufferUnlockBaseAddress(pb, [])
        if rc != 0 { slots.signal(); return rc }
        let t = CMTime(value: Int64(framesWritten) * Int64(fpsDen), timescale: fpsNum)
        framesWritten += 1
        finishTime = CMTime(value: Int64(framesWritten) * Int64(fpsDen), timescale: fpsNum)
        queue.async { [self] in
            pending.append((pb, nil, t))
            pump()
        }
        return SRStatus.ok
    }

    /// Motion JPEG: encode with the IO codec's JPEG (through its C ABI), wrap the bytes as one sample, queue it.
    /// Called with a slot already taken from `slots`.
    private func writeJPEG(_ img: SRImage, quality: Int32) -> Int32 {
        var h: UnsafeMutableRawPointer?
        let rc = ".jpg".withCString { sr_io_encode(img.data, Int32(img.width), Int32(img.height), Int32(img.stride), Int32(img.channels), img.depth.rawValue, $0, quality, 1, &h) }
        guard rc == 0, let h else { slots.signal(); return srFail(SRStatus.ioFailure, "VideoWriter: JPEG encode failed") }
        defer { sr_io_free(h) }
        var meta = [Int32](repeating: 0, count: 4)
        guard sr_io_info(h, &meta) == 0, meta[0] > 0 else { slots.signal(); return srFail(SRStatus.ioFailure, "VideoWriter: JPEG size") }
        let n = Int(meta[0])
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n, blockAllocator: nil, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: n, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block
        else { slots.signal(); return srFail(SRStatus.ioFailure, "VideoWriter: sample buffer") }
        var ptr: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &ptr)
        guard let ptr, sr_io_copy(h, UnsafeMutableRawPointer(ptr), 0) == 0 else { slots.signal(); return srFail(SRStatus.ioFailure, "VideoWriter: JPEG copy") }
        let t = CMTime(value: Int64(framesWritten) * Int64(fpsDen), timescale: fpsNum)
        var timing = CMSampleTimingInfo(duration: CMTime(value: Int64(fpsDen), timescale: fpsNum), presentationTimeStamp: t, decodeTimeStamp: .invalid)
        var size = n
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: jpegFormat, sampleCount: 1, sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb) == noErr, let sb
        else { slots.signal(); return srFail(SRStatus.ioFailure, "VideoWriter: sample buffer") }
        framesWritten += 1
        finishTime = CMTime(value: Int64(framesWritten) * Int64(fpsDen), timescale: fpsNum)
        queue.async { [self] in
            pending.append((nil, sb, t))
            pump()
        }
        return SRStatus.ok
    }

    /// Finish the file (blocks until it is complete). Returns 0 on success.
    func release() -> Int32 {
        guard !released else { return SRStatus.ok }
        released = true
        queue.sync { finishRequested = true }
        queue.async { [self] in pump() }
        // pump runs again whenever the input is ready; poll the writer status as the safety net.
        while done.wait(timeout: .now() + 0.2) == .timedOut {
            queue.async { [self] in pump() }
            if writer.status == .failed || writer.status == .cancelled {
                writer.cancelWriting()   // drop the half-written file; a no-op if it already is cancelled
                queue.sync { pending.removeAll() }
                break
            }
        }
        queue.sync {}   // no callback is still running when the box is freed
        if let f = failure { return srFail(SRStatus.ioFailure, "VideoWriter: \(f)") }
        if framesWritten == 0 {
            return srFail(SRStatus.ioFailure, "VideoWriter: no frames were written")
        }
        return writer.status == .completed ? SRStatus.ok : srFail(SRStatus.ioFailure, "VideoWriter: file not completed (\(writer.status.rawValue))")
    }

    private func vwFill(_ pb: CVPixelBuffer, _ img: SRImage) -> Int32 {
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return srFail(SRStatus.ioFailure, "VideoWriter: no pixels") }
        let rb = CVPixelBufferGetBytesPerRow(pb)
        var dst = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rb)
        var src = vImage_Buffer(data: img.data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: img.stride)
        switch img.channels {
        case 3:
            // BGR -> BGRA (opaque): the plain 3->4 conversion keeps channel order and appends alpha = 255.
            return vImageConvert_RGB888toRGBA8888(&src, nil, 255, &dst, false, vImage_Flags(kvImageNoFlags)) == kvImageNoError
                ? 0 : srFail(SRStatus.internalError, "VideoWriter: convert failed")
        case 4:
            for y in 0..<height { memcpy(base + y * rb, img.row(y), width * 4) }
            return 0
        default:
            return vImageConvert_Planar8ToBGRX8888(&src, &src, &src, 255, &dst, vImage_Flags(kvImageNoFlags)) == kvImageNoError
                ? 0 : srFail(SRStatus.internalError, "VideoWriter: convert failed")
        }
    }
}

// MARK: - C ABI

/// `params`: nparams (key, value) double pairs, keys = cv2 VIDEOWRITER_PROP_* (1 quality, 10/19 key interval, 15 alpha,
/// 16 bitrate bit/s, 17 crf; others are ignored here). `fourcc` is the little-endian cv2 fourcc int.
/// Returns 0 and a handle, or <0 with the reason in sr_last_error.
@_cdecl("sr_vw_open")
public func sr_vw_open(_ path: UnsafePointer<CChar>?, _ fourcc: UInt32, _ fps: Double, _ width: Int32, _ height: Int32,
                       _ isColor: Int32, _ params: UnsafePointer<Double>?, _ nparams: Int32,
                       _ out: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard let path, let out else { return srFail(SRStatus.badArgument, "VideoWriter: null") }
    var p: [Int: Double] = [:]
    if let params {
        for i in 0..<Int(max(0, nparams)) {
            let k = params[2 * i]
            guard k.isFinite, abs(k) < 1e6 else { return srFail(SRStatus.badArgument, "VideoWriter: parameter id \(k) is not valid") }
            p[Int(k)] = params[2 * i + 1]
        }
    }
    var why = ""
    guard let b = VideoWriterBox(path: String(cString: path), fourcc: fourcc, fps: fps, width: Int(width), height: Int(height),
                                 isColor: isColor != 0, params: p, error: &why) else {
        return srFail(SRStatus.unsupported, "VideoWriter: \(why)")
    }
    out.pointee = Unmanaged.passRetained(b).toOpaque()
    return SRStatus.ok
}

@_cdecl("sr_vw_write")
public func sr_vw_write(_ h: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?, _ width: Int32, _ height: Int32,
                        _ stride: Int32, _ channels: Int32, _ depth: Int32) -> Int32 {
    guard let h, let img = SRImage(data, width, height, stride, channels, depth) else {
        return srFail(SRStatus.badArgument, "VideoWriter: bad frame")
    }
    return Unmanaged<VideoWriterBox>.fromOpaque(h).takeUnretainedValue().write(img)
}

/// Finish and close the file, then free the handle. Returns 0 when a complete file was written.
@_cdecl("sr_vw_close")
public func sr_vw_close(_ h: UnsafeMutableRawPointer?) -> Int32 {
    guard let h else { return SRStatus.ok }
    let box = Unmanaged<VideoWriterBox>.fromOpaque(h).takeRetainedValue()
    return box.release()
}

/// Test hook (needs SAFARIUM_RASTER_TESTING=1): cancel the writer under the caller's feet. Returns 0.
@_cdecl("sr_vw_test_force_failure")
public func sr_vw_test_force_failure(_ h: UnsafeMutableRawPointer?) -> Int32 {
    guard srTestHooksEnabled(), let h else { return SRStatus.unsupported }
    Unmanaged<VideoWriterBox>.fromOpaque(h).takeUnretainedValue().forceFailure()
    return SRStatus.ok
}

/// out[0] = frames written so far, out[1] = 1 if the writer accepts 4-channel (alpha) frames.
@_cdecl("sr_vw_info")
public func sr_vw_info(_ h: UnsafeMutableRawPointer?, _ out: UnsafeMutablePointer<Double>?) -> Int32 {
    guard let h, let out else { return srFail(SRStatus.badArgument, "VideoWriter: null") }
    let b = Unmanaged<VideoWriterBox>.fromOpaque(h).takeUnretainedValue()
    out[0] = Double(b.framesWritten)
    out[1] = b.alphaOK ? 1 : 0
    return SRStatus.ok
}

// MARK: - Test fixture with explicit timestamps (parity tests only)

/// Write a small H.264 .mp4 whose frame i (the same stripe pattern as sr_video_write_test) is presented at
/// `pts[i] / timescale` seconds - a variable-frame-rate file. Needs SAFARIUM_RASTER_TESTING=1.
@_cdecl("sr_video_write_test_pts")
public func sr_video_write_test_pts(_ path: UnsafePointer<CChar>?, _ width: Int32, _ height: Int32, _ count: Int32,
                                    _ timescale: Int32, _ pts: UnsafePointer<Int64>?, _ endPts: Int64) -> Int32 {
    guard srTestHooksEnabled() else { return srFail(SRStatus.unsupported, "test hook disabled (set SAFARIUM_RASTER_TESTING=1)") }
    guard let path, let pts, width > 0, height > 0, count > 0, timescale > 0 else { return srFail(SRStatus.badArgument, "bad args") }
    let url = URL(fileURLWithPath: String(cString: path))
    try? FileManager.default.removeItem(at: url)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return srFail(SRStatus.ioFailure, "writer") }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(width), AVVideoHeightKey: Int(height),
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000, AVVideoMaxKeyFrameIntervalKey: 10],
    ])
    input.mediaTimeScale = timescale
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(width), kCVPixelBufferHeightKey as String: Int(height),
    ])
    input.expectsMediaDataInRealTime = false
    guard writer.canAdd(input) else { return srFail(SRStatus.ioFailure, "cannot add input") }
    writer.add(input)
    guard writer.startWriting() else { return srFail(SRStatus.ioFailure, "writer: \(writer.error?.localizedDescription ?? "?")") }
    writer.startSession(atSourceTime: .zero)
    for i in 0..<Int(count) {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        guard let pool = adaptor.pixelBufferPool else { return srFail(SRStatus.ioFailure, "no pool") }
        var pbOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
        guard let pb = pbOut else { return srFail(SRStatus.ioFailure, "no buffer") }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let rb = CVPixelBufferGetBytesPerRow(pb)
        let stripeW = max(1, Int(width) / 8)
        for y in 0..<Int(height) {
            for x in 0..<Int(width) {
                let bit = x / stripeW < 8 ? (i >> (7 - x / stripeW)) & 1 : 0
                let v: UInt8 = bit == 1 ? 255 : 0
                let p = base + y * rb + x * 4
                p[0] = v; p[1] = v; p[2] = v; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        adaptor.append(pb, withPresentationTime: CMTime(value: pts[i], timescale: timescale))
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: endPts, timescale: timescale))
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    return writer.status == .completed ? SRStatus.ok : srFail(SRStatus.ioFailure, "writer: \(writer.error?.localizedDescription ?? "failed")")
}
