// SafariumRaster — VideoCapture backend (Area C): AVAssetReader, BGR u8 frames. No FFmpeg.
//
// Frame index = round((pts - firstPTS) * fps). Seeking recreates the reader with a timeRange that starts a quarter
// frame into the target frame (the first sample is the frame covering that time), so the next read returns exactly it.
// Frames come out of the decoder in the file's own colour matrix (AVFoundation), rotated upright by the track's
// preferredTransform (like cv2's CAP_PROP_ORIENTATION_AUTO).

import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import Accelerate

private final class VideoBox<T>: @unchecked Sendable {
    var value: T?
}

/// Run an async loader to completion from a synchronous C-ABI call.
private func videoAwait<T>(_ body: @escaping @Sendable () async throws -> T) -> T? {
    let box = VideoBox<T>()
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        box.value = try? await body()
        sem.signal()
    }
    sem.wait()
    return box.value
}

/// What the C ABI needs from a frame source (AVFoundation video or an ImageIO animated GIF).
protocol VideoBackend: AnyObject {
    var width: Int { get }
    var height: Int { get }
    var fps: Double { get }
    var frameCount: Int { get }
    var nextIndex: Int { get }
    func seek(_ index: Int) -> Bool
    /// 0 = frame written, 1 = end of stream, 2 = not positioned (an earlier seek failed), <0 = error.
    func read(into dst: SRImage) -> Int32
    /// Extended properties (see `sr_video_props` for the slot layout). Defaults: unknown.
    func props(_ out: UnsafeMutablePointer<Double>)
    /// Backend switches: key 0 = auto-orient (CAP_PROP_ORIENTATION_AUTO). Returns false when unsupported.
    func setFlag(_ key: Int, _ value: Double) -> Bool
}

extension VideoBackend {
    func props(_ out: UnsafeMutablePointer<Double>) {
        for i in 0..<videoPropSlots { out[i] = 0 }
        out[3] = 0; out[4] = 1  // SAR 0:1 = unknown, like cv2
        out[11] = 1
    }
    func setFlag(_ key: Int, _ value: Double) -> Bool { false }
}

let videoPropSlots = 16

final class VideoSource: VideoBackend {
    let asset: AVURLAsset
    let track: AVAssetTrack
    let fps: Double
    let origin: Double          // PTS (s) of frame 0
    let frameCount: Int
    private(set) var width: Int              // output size: upright when autoOrient (default), as stored otherwise
    private(set) var height: Int
    /// preferredTransform as integers (a b c d), each -1/0/1: rotations by 90 degrees and mirrored variants.
    private(set) var tfa: Int, tfb: Int, tfc: Int, tfd: Int
    private let rawTransform: (Int, Int, Int, Int)
    private let storedW: Int, storedH: Int
    private(set) var autoOrient = true
    /// Presentation timestamps (s) of every sample, sorted: frame index = position in this table (VFR-safe).
    private var ptsTable: [Double] = []
    /// Per frame (same order as ptsTable): 'I' / 'P' / 'B' as cv2 reports it (from the compressed samples' attachments).
    private var typeTable: [UInt8] = []
    /// After a time-range seek the reader re-stamps the first sample to the requested start time, so that sample is
    /// frame `nextIndex` by construction, whatever its PTS says.
    private var restamped = false
    private var props16 = [Double](repeating: 0, count: videoPropSlots)
    private var lastFrameType: Double = 63  // '?'
    private var positioned = true
    /// Test hook: the next reader re-creation fails (what a decoder error mid-seek looks like).
    var failNextReposition = false
    private(set) var nextIndex = 0
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var scratch: [UInt8] = []

    init?(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        struct Loaded: Sendable {
            let track: AVAssetTrack
            let size: CGSize
            let transform: CGAffineTransform
            let fps: Float
            let range: CMTimeRange
            let minDuration: CMTime
            let timeScale: Int32
        }
        guard let l: Loaded = videoAwait({
            guard let t = try await asset.loadTracks(withMediaType: .video).first else { throw CocoaError(.fileReadCorruptFile) }
            let (size, tf, rate, range, minD) = try await t.load(.naturalSize, .preferredTransform, .nominalFrameRate,
                                                                .timeRange, .minFrameDuration)
            let ts = try await t.load(.naturalTimeScale)
            return Loaded(track: t, size: size, transform: tf, fps: rate, range: range, minDuration: minD, timeScale: ts)
        }) else { return nil }
        guard l.size.width > 0, l.size.height > 0 else { return nil }
        self.asset = asset
        self.track = l.track
        var f = Double(l.fps)
        if f <= 0, l.minDuration.isNumeric, l.minDuration.seconds > 0 { f = 1.0 / l.minDuration.seconds }
        if f > 0 {
            // nominalFrameRate is a Float: snap it to the exact integer / NTSC rate it stands for.
            if abs(f - f.rounded()) < 2e-3 { f = f.rounded() }
            else if let ntsc = [24000.0 / 1001, 30000.0 / 1001, 60000.0 / 1001, 120000.0 / 1001].first(where: { abs($0 - f) < 2e-3 }) { f = ntsc }
        }
        self.fps = f > 0 ? f : 30
        self.origin = l.range.start.isNumeric ? l.range.start.seconds : 0
        let dur = l.range.duration.isNumeric ? l.range.duration.seconds : 0
        // The real sample count (compressed samples, no decoding): a track can end a frame or two before
        // round(duration * fps), and then the last "frame" would not exist.
        let estimated = max(0, Int((dur * self.fps).rounded()))
        var table: [Double] = []
        var types: [UInt8] = []
        var totalBytes = 0
        var fmtDesc: CMFormatDescription?
        let t0 = DispatchTime.now().uptimeNanoseconds
        if let r = try? AVAssetReader(asset: asset) {
            let co = AVAssetReaderTrackOutput(track: l.track, outputSettings: nil)
            if r.canAdd(co) {
                r.add(co)
                if r.startReading() {
                    while let sb = co.copyNextSampleBuffer() {
                        let ns = CMSampleBufferGetNumSamples(sb)
                        if fmtDesc == nil { fmtDesc = CMSampleBufferGetFormatDescription(sb) }
                        totalBytes += CMSampleBufferGetTotalSampleSize(sb)
                        if ns == 1 {
                            table.append(sb.presentationTimeStamp.seconds)
                            types.append(UInt8(Videoprops.frameType(sb)))
                        } else if ns > 1 {
                            var count = 0
                            CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
                            var infos = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
                            CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count)
                            for ti in infos { table.append(ti.presentationTimeStamp.seconds); types.append(63) }
                        }
                    }
                }
            }
        }
        let openMicros = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
        if types.count == table.count {
            let order = table.indices.sorted { table[$0] < table[$1] }
            types = order.map { types[$0] }
        } else { types = [] }
        table.sort()
        // Compressed samples carry media time (a B-frame delay shows up as a start offset that the edit list removes
        // from the decoded frames): align the first frame with the start of the track, like the decoded timeline.
        let start0 = l.range.start.isNumeric ? l.range.start.seconds : 0
        if let first = table.first, first != start0 { table = table.map { $0 - first + start0 } }
        if table.count > 1 {
            // A real frame table must hold distinct, increasing times; otherwise fall back to the CFR formula.
            for i in 1..<table.count where !(table[i] > table[i - 1]) { table = []; break }
        }
        self.ptsTable = table
        self.typeTable = types.count == table.count ? types : []
        self.frameCount = table.count > 0 ? table.count : estimated
        if let fd = fmtDesc {
            props16[0] = Double(CMFormatDescriptionGetMediaSubType(fd))
            props16[2] = Videoprops.pixelFormat(fd)
            if let par = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? [String: Any],
               let hs = (par[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] as? NSNumber)?.doubleValue,
               let vs = (par[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] as? NSNumber)?.doubleValue, hs > 0, vs > 0 {
                props16[3] = hs; props16[4] = vs
            } else { props16[3] = 0; props16[4] = 1 }
        } else { props16[3] = 0; props16[4] = 1 }
        // CAP_PROP_BITRATE (kbit/s) = container size / duration, truncated - what cv2's FFmpeg backend reports.
        let fileBytes = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.doubleValue ?? 0
        props16[1] = dur > 0 ? (fileBytes * 8 / dur / 1000).rounded(.down) : 0
        props16[8] = openMicros
        props16[10] = dur
        let tf = l.transform
        var m = (Int(tf.a.rounded()), Int(tf.b.rounded()), Int(tf.c.rounded()), Int(tf.d.rounded()))
        let exact = abs(tf.a - tf.a.rounded()) < 1e-3 && abs(tf.b - tf.b.rounded()) < 1e-3
            && abs(tf.c - tf.c.rounded()) < 1e-3 && abs(tf.d - tf.d.rounded()) < 1e-3
        if !exact || abs(m.0 * m.3 - m.1 * m.2) != 1 { m = (1, 0, 0, 1) }  // skewed / scaled: leave the frame as stored
        (self.tfa, self.tfb, self.tfc, self.tfd) = m
        self.rawTransform = m
        let sw = Int(l.size.width.rounded()), sh = Int(l.size.height.rounded())
        self.storedW = sw
        self.storedH = sh
        self.width = abs(m.0) * sw + abs(m.2) * sh
        self.height = abs(m.1) * sw + abs(m.3) * sh
        // cv2 (FFmpeg) CAP_PROP_ORIENTATION_META: rotation in degrees from the display matrix, atan2 of its normalised first row.
        let s0 = (Double(m.0 * m.0 + m.2 * m.2)).squareRoot(), s1 = (Double(m.1 * m.1 + m.3 * m.3)).squareRoot()
        var deg = (atan2(Double(m.1) / s1, Double(m.0) / s0) * 180 / .pi).rounded()
        if deg < 0 { deg += 360 }
        props16[5] = deg
        props16[9] = 1  // decoding goes through VideoToolbox (hardware when the codec/size allows)
        props16[12] = Double(l.timeScale)
        guard startReader(at: 0) else { return nil }
    }

    /// CAP_PROP_ORIENTATION_AUTO: when off, frames come out as stored (no rotation / mirror).
    func setAutoOrient(_ on: Bool) {
        autoOrient = on
        let m = on ? rawTransform : (1, 0, 0, 1)
        (tfa, tfb, tfc, tfd) = m
        width = abs(m.0) * storedW + abs(m.2) * storedH
        height = abs(m.1) * storedW + abs(m.3) * storedH
    }

    func setFlag(_ key: Int, _ value: Double) -> Bool {
        guard key == 0 else { return false }
        setAutoOrient(value != 0)
        return true
    }

    /// Frame index of a decoded sample's timestamp.
    private func indexFor(pts t: Double) -> Int {
        if ptsTable.isEmpty { return Int(((t - origin) * fps).rounded()) }
        var lo = 0, hi = ptsTable.count   // first entry >= t
        while lo < hi { let mid = (lo + hi) / 2; if ptsTable[mid] < t { lo = mid + 1 } else { hi = mid } }
        if lo == 0 { return 0 }
        if lo == ptsTable.count { return lo - 1 }
        return (t - ptsTable[lo - 1]) <= (ptsTable[lo] - t) ? lo - 1 : lo
    }

    /// PTS (s, absolute) of frame `i`.
    private func ptsOf(_ i: Int) -> Double {
        if ptsTable.isEmpty { return origin + Double(i) / fps }
        return ptsTable[min(max(0, i), ptsTable.count - 1)]
    }

    /// Frame index nearest to `ms` milliseconds after the first frame (VFR-aware).
    func frameIndex(atMsec ms: Double) -> Int {
        let t = ptsOf(0) + ms / 1000
        if ptsTable.count > 1, t > ptsTable[ptsTable.count - 1] + 0.5 * (ptsTable[ptsTable.count - 1] - ptsTable[ptsTable.count - 2]) {
            return frameCount   // past the last frame: like seeking past the end
        }
        return indexFor(pts: t)
    }

    func props(_ out: UnsafeMutablePointer<Double>) {
        for i in 0..<videoPropSlots { out[i] = props16[i] }
        out[5] = autoOrient ? props16[5] : props16[5]  // the stored rotation, independent of the auto flag
        out[6] = nextIndex > 0 ? ptsOf(nextIndex - 1) * props16[12] : 0
        out[7] = lastFrameType
        out[11] = autoOrient ? 1 : 0
        out[13] = nextIndex > 0 ? (ptsOf(nextIndex - 1) - ptsOf(0)) * 1000 : 0   // POS_MSEC from the real PTS
        out[14] = nextIndex < frameCount && nextIndex >= 0 ? ptsOf(nextIndex) - ptsOf(0) : dur()
        out[15] = Double(ptsTable.isEmpty ? 0 : 1)
    }

    private func dur() -> Double { props16[10] }

    /// Time of the first frame (s), for POS_AVI_RATIO etc.
    var firstPTS: Double { ptsOf(0) }

    deinit { reader?.cancelReading() }

    @discardableResult
    private func startReader(at index: Int) -> Bool {
        reader?.cancelReading()
        reader = nil
        output = nil
        guard let r = try? AVAssetReader(asset: asset) else { return false }
        let o = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        o.alwaysCopiesSampleData = false
        guard r.canAdd(o) else { return false }
        r.add(o)
        restamped = false
        if index > 0 {
            // inside frame `index`'s interval (a quarter in); the reader re-stamps the first sample to this time
            let p0 = ptsOf(index)
            let p1 = index + 1 < frameCount ? ptsOf(index + 1) : p0 + 1 / fps
            let start = max(0, p0 + 0.25 * (p1 - p0))
            restamped = true
            r.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 90000), duration: .positiveInfinity)
        }
        guard r.startReading() else { return false }
        reader = r
        output = o
        nextIndex = index
        return true
    }

    /// Position so the next `read` returns frame `index`. Like cv2: negative clamps to 0, past the end is accepted
    /// (position = frame count, every read then fails); only a real reader failure returns false.
    func seek(_ index: Int) -> Bool {
        let target = max(0, index)
        if frameCount > 0, target >= frameCount {
            reader?.cancelReading()
            reader = nil
            output = nil
            nextIndex = frameCount
            positioned = true
            return true
        }
        if positioned, reader != nil, target >= nextIndex, target - nextIndex <= 4 {
            // A short hop forward: decode and drop instead of re-opening the reader.
            while nextIndex < target {
                guard let sb = output?.copyNextSampleBuffer() else { nextIndex = target; return true }
                nextIndex = consumedIndex(sb) + 1
            }
            return true
        }
        if failNextReposition {
            failNextReposition = false
            reader?.cancelReading(); reader = nil; output = nil
            positioned = false
        } else {
            positioned = startReader(at: target)
        }
        if !positioned { nextIndex = target }
        return positioned
    }

    /// Index of the frame a freshly read sample is.
    private func consumedIndex(_ sb: CMSampleBuffer) -> Int {
        if restamped { restamped = false; return nextIndex }
        return indexFor(pts: sb.presentationTimeStamp.seconds)
    }

    func read(into dst: SRImage) -> Int32 {
        guard positioned else { _ = srFail(SRStatus.ioFailure, "video read: the last seek failed"); return 2 }
        guard dst.channels == 3, dst.depth == .u8, dst.width == width, dst.height == height else {
            return srFail(SRStatus.badArgument, "video read: destination must be \(width)x\(height) BGR u8")
        }
        guard let output else { return 1 }
        while true {
            guard let sb = output.copyNextSampleBuffer() else {
                if reader?.status == .failed {
                    return srFail(SRStatus.ioFailure, "video read: \(reader?.error?.localizedDescription ?? "reader failed")")
                }
                return 1
            }
            let idx = consumedIndex(sb)
            if idx < nextIndex { continue }  // pre-roll before the seek target
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let rc = convert(pb, into: dst)
            if rc == 0 {
                nextIndex = idx + 1
                lastFrameType = idx < typeTable.count ? Double(typeTable[idx]) : 63
            }
            return rc
        }
    }

    private func convert(_ pb: CVPixelBuffer, into dst: SRImage) -> Int32 {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return srFail(SRStatus.ioFailure, "video read: no pixels") }
        let pw = CVPixelBufferGetWidth(pb), ph = CVPixelBufferGetHeight(pb)
        let prow = CVPixelBufferGetBytesPerRow(pb)
        var src = vImage_Buffer(data: base, height: vImagePixelCount(ph), width: vImagePixelCount(pw), rowBytes: prow)
        let identity = tfa == 1 && tfb == 0 && tfc == 0 && tfd == 1
        let ow = abs(tfa) * pw + abs(tfc) * ph, oh = abs(tfb) * pw + abs(tfd) * ph
        guard ow == dst.width, oh == dst.height else {
            return srFail(SRStatus.ioFailure, "video read: frame is \(pw)x\(ph) (\(ow)x\(oh) after the track transform), expected \(dst.width)x\(dst.height)")
        }
        if identity {
            var d = vImage_Buffer(data: dst.data, height: vImagePixelCount(ph), width: vImagePixelCount(pw), rowBytes: dst.stride)
            vImageConvert_RGBA8888toRGB888(&src, &d, vImage_Flags(kvImageNoFlags))  // BGRA -> BGR: alpha (last) dropped, order kept
            return 0
        }
        if scratch.count != pw * ph * 3 { scratch = [UInt8](repeating: 0, count: pw * ph * 3) }
        scratch.withUnsafeMutableBytes { sc in
            var t = vImage_Buffer(data: sc.baseAddress, height: vImagePixelCount(ph), width: vImagePixelCount(pw), rowBytes: pw * 3)
            vImageConvert_RGBA8888toRGB888(&src, &t, vImage_Flags(kvImageNoFlags))
            let sp = sc.bindMemory(to: UInt8.self).baseAddress!
            // dest = M * (x, y) with M = [a c; b d] (CGAffineTransform row-vector convention), shifted to start at 0.
            let offX = -(min(0, tfa * (pw - 1)) + min(0, tfc * (ph - 1)))
            let offY = -(min(0, tfb * (pw - 1)) + min(0, tfd * (ph - 1)))
            let dp = dst.data.assumingMemoryBound(to: UInt8.self)
            for y in 0..<ph {
                for x in 0..<pw {
                    let dx = tfa * x + tfc * y + offX
                    let dy = tfb * x + tfd * y + offY
                    let q = dp + dy * dst.stride + dx * 3
                    let s3 = sp + (y * pw + x) * 3
                    q[0] = s3[0]; q[1] = s3[1]; q[2] = s3[2]
                }
            }
        }
        return 0
    }
}

enum Videoprops {
    static func fourcc(_ a: Character, _ b: Character, _ c: Character, _ d: Character) -> Double {
        let v = a.asciiValue.map(UInt32.init)! | (b.asciiValue.map(UInt32.init)! << 8) | (c.asciiValue.map(UInt32.init)! << 16) | (d.asciiValue.map(UInt32.init)! << 24)
        return Double(v)
    }

    /// CAP_PROP_CODEC_PIXEL_FORMAT: the fourcc of the stored pixel layout when it is known (8-bit 4:2:0 -> 'I420').
    static func pixelFormat(_ fd: CMFormatDescription) -> Double {
        let sub = CMFormatDescriptionGetMediaSubType(fd)
        let bits = (CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_BitsPerComponent) as? NSNumber)?.intValue
        func tag(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Double { Double(UInt32(a) | UInt32(b) << 8 | UInt32(c) << 16 | UInt32(d) << 24) }
        let depth = (CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_Depth) as? NSNumber)?.intValue ?? 24
        switch sub {
        case kCMVideoCodecType_H264, kCMVideoCodecType_HEVC:
            return (bits ?? 8) == 8 ? fourcc("I", "4", "2", "0") : 0
        case kCMVideoCodecType_JPEG:
            return fourcc("I", "4", "2", "0")                     // yuvj420p
        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422Proxy:
            return tag(0x59, 0x33, 10, 10)                         // yuv422p10
        case kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_AppleProRes4444XQ:
            return depth == 32 ? tag(0x59, 0x34, 0, 12) : tag(0x59, 0x33, 0, 12)  // yuva444p12 / yuv444p12
        default:
            return 0
        }
    }

    /// CAP_PROP_FRAME_TYPE: 'I' for a sync sample, otherwise 'B' when nothing refers to it, else 'P' ('?' when unknown).
    static func frameType(_ sb: CMSampleBuffer) -> Double {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]], let a = arr.first else { return 63 }
        let notSync = (a[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        if !notSync { return 73 }
        let dependedOn = (a[kCMSampleAttachmentKey_IsDependedOnByOthers] as? Bool) ?? true
        return dependedOn ? 80 : 66
    }
}

// MARK: - Animated GIF (ImageIO)

/// cv2 reads GIF through VideoCapture (FFmpeg) too; here ImageIO supplies the composited frames.
/// fps = frames / total delay (a delay of 0 counts as 10 ms, like FFmpeg), so 100 ms frames give 10 fps.
final class GifSource: VideoBackend {
    private let src: CGImageSource
    let width: Int
    let height: Int
    let fps: Double
    let frameCount: Int
    private(set) var nextIndex = 0

    init?(path: String) {
        guard let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              (CGImageSourceGetType(s) as String?) == "com.compuserve.gif",
              CGImageSourceGetCount(s) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        src = s
        width = w
        height = h
        frameCount = CGImageSourceGetCount(s)
        var total = 0.0
        for i in 0..<frameCount {
            let gp = (CGImageSourceCopyPropertiesAtIndex(s, i, nil) as? [CFString: Any])?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let d = (gp?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gp?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
            total += max(d, 0.01)
        }
        fps = Double(frameCount) / total
    }

    func seek(_ index: Int) -> Bool {
        nextIndex = min(max(0, index), frameCount)
        return true
    }

    func read(into dst: SRImage) -> Int32 {
        guard dst.channels == 3, dst.depth == .u8, dst.width == width, dst.height == height else {
            return srFail(SRStatus.badArgument, "video read: destination must be \(width)x\(height) BGR u8")
        }
        guard nextIndex < frameCount else { return 1 }
        guard let cg = CGImageSourceCreateImageAtIndex(src, nextIndex, [kCGImageSourceShouldAllowFloat: true, kCGImageSourceShouldCache: false] as CFDictionary), let m = ioExtractNative(cg) else {
            return srFail(SRStatus.ioFailure, "video read: cannot decode GIF frame \(nextIndex)")
        }
        // Transparent pixels come out of ImageIO as premultiplied black; FFmpeg (cv2) shows them white.
        if m.channels == 4 {
            for i in 0..<(m.width * m.height) {
                let inv = 255 - Int(m.bytes[i * 4 + 3])
                for c in 0..<3 { m.bytes[i * 4 + c] = UInt8(min(255, Int(m.bytes[i * 4 + c]) + inv)) }
            }
        }
        let full = ioToColor3(ioDropAlpha(m))
        guard full.width == width, full.height == height else {
            return srFail(SRStatus.ioFailure, "video read: GIF frame size changed")
        }
        full.bytes.withUnsafeBytes { sp in
            for y in 0..<height { memcpy(dst.row(y), sp.baseAddress! + y * full.rowBytes, full.rowBytes) }
        }
        nextIndex += 1
        return 0
    }
}

// MARK: - C ABI

final class VideoBox2 {
    let backend: VideoBackend
    init(_ b: VideoBackend) { backend = b }
}

@_cdecl("sr_video_open")
public func sr_video_open(_ path: UnsafePointer<CChar>?, _ out: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    guard let path, let out else { return srFail(SRStatus.badArgument, "video open: null") }
    let p = String(cString: path)
    let backend: VideoBackend? = GifSource(path: p) ?? VideoSource(path: p)
    guard let v = backend else {
        return srFail(SRStatus.ioFailure, "video open: cannot open \(p)")
    }
    out.pointee = Unmanaged.passRetained(VideoBox2(v)).toOpaque()
    return SRStatus.ok
}

/// out[0..5] = width, height, fps, frame count, next frame index, position in ms of the last frame read.
@_cdecl("sr_video_info")
public func sr_video_info(_ h: UnsafeMutableRawPointer?, _ out: UnsafeMutablePointer<Double>?) -> Int32 {
    guard let h, let out else { return srFail(SRStatus.badArgument, "video info: null") }
    let v = Unmanaged<VideoBox2>.fromOpaque(h).takeUnretainedValue().backend
    out[0] = Double(v.width)
    out[1] = Double(v.height)
    out[2] = v.fps
    out[3] = Double(v.frameCount)
    out[4] = Double(v.nextIndex)
    out[5] = Double(max(0, v.nextIndex - 1)) / v.fps * 1000.0
    return SRStatus.ok
}

/// Extended properties, `videoPropSlots` (16) doubles: 0 codec fourcc, 1 bitrate kbit/s, 2 pixel-format fourcc,
/// 3/4 SAR num/den, 5 orientation meta (deg), 6 PTS of the last frame (track time-scale ticks), 7 frame type char,
/// 8 open time (us), 9 hardware decode (0/1), 10 duration (s), 11 auto-orient flag, 12 time-scale,
/// 13 POS_MSEC from real PTS, 14 time of the NEXT frame (s from first frame), 15 has frame table.
@_cdecl("sr_video_props")
public func sr_video_props(_ h: UnsafeMutableRawPointer?, _ out: UnsafeMutablePointer<Double>?) -> Int32 {
    guard let h, let out else { return srFail(SRStatus.badArgument, "video props: null") }
    Unmanaged<VideoBox2>.fromOpaque(h).takeUnretainedValue().backend.props(out)
    return SRStatus.ok
}

/// Backend switch. key 0 = auto-orient. Returns 0 when applied, -2 when this source does not support the key.
@_cdecl("sr_video_set_flag")
public func sr_video_set_flag(_ h: UnsafeMutableRawPointer?, _ key: Int32, _ value: Double) -> Int32 {
    guard let h else { return srFail(SRStatus.badArgument, "video set: null") }
    return Unmanaged<VideoBox2>.fromOpaque(h).takeUnretainedValue().backend.setFlag(Int(key), value) ? SRStatus.ok : SRStatus.unsupported
}

/// Index of the frame nearest to `ms` after the first frame (VFR-aware; CFR files use the frame rate).
@_cdecl("sr_video_frame_at_msec")
public func sr_video_frame_at_msec(_ h: UnsafeMutableRawPointer?, _ ms: Double) -> Int64 {
    guard let h else { return 0 }
    let v = Unmanaged<VideoBox2>.fromOpaque(h).takeUnretainedValue().backend
    if let s = v as? VideoSource { return Int64(s.frameIndex(atMsec: ms)) }
    return Int64((ms * v.fps / 1000).rounded())
}

@_cdecl("sr_video_read")
public func sr_video_read(_ h: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?, _ width: Int32, _ height: Int32,
                          _ stride: Int32, _ channels: Int32, _ depth: Int32) -> Int32 {
    guard let h, let img = SRImage(data, width, height, stride, channels, depth) else {
        return srFail(SRStatus.badArgument, "video read: bad destination")
    }
    return Unmanaged<VideoBox2>.fromOpaque(h).takeUnretainedValue().backend.read(into: img)
}

@_cdecl("sr_video_seek")
public func sr_video_seek(_ h: UnsafeMutableRawPointer?, _ frame: Int64) -> Int32 {
    guard let h else { return srFail(SRStatus.badArgument, "video seek: null") }
    let ok = Unmanaged<VideoBox2>.fromOpaque(h).takeUnretainedValue().backend.seek(Int(clamping: frame))
    return ok ? SRStatus.ok : srFail(SRStatus.ioFailure, "video seek: cannot reposition the reader")
}

@_cdecl("sr_video_close")
public func sr_video_close(_ h: UnsafeMutableRawPointer?) {
    guard let h else { return }
    Unmanaged<VideoBox2>.fromOpaque(h).release()
}

// MARK: - Test-fixture writer (used by the parity tests; not part of the cv2 surface)

/// Write a small H.264 .mp4 of `count` BGR frames that encode their own frame number (8 stripes + a colour band), at `fps`. Returns 0 on success.
@_cdecl("sr_video_write_test")
public func sr_video_write_test(_ path: UnsafePointer<CChar>?, _ width: Int32, _ height: Int32, _ fps: Int32, _ count: Int32, _ transform: Int32, _ tailFrames: Int32) -> Int32 {
    guard srTestHooksEnabled() else { return srFail(SRStatus.unsupported, "test hook disabled (set SAFARIUM_RASTER_TESTING=1)") }
    guard let path, width > 0, height > 0, fps > 0, count > 0 else { return srFail(SRStatus.badArgument, "video write: bad args") }
    let url = URL(fileURLWithPath: String(cString: path))
    try? FileManager.default.removeItem(at: url)
    guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return srFail(SRStatus.ioFailure, "writer") }
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(width), AVVideoHeightKey: Int(height),
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000, AVVideoMaxKeyFrameIntervalKey: 10],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: Int(width), kCVPixelBufferHeightKey as String: Int(height),
    ])
    input.expectsMediaDataInRealTime = false
    // 0 identity, 1 mirror-x, 2 mirror-y, 3 rot90 cw, 4 rot180, 5 rot270 cw, 6 transpose, 7 anti-transpose  (a, b, c, d)
    let tfTable: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(1, 0, 0, 1), (-1, 0, 0, 1), (1, 0, 0, -1), (0, 1, -1, 0),
                                                           (-1, 0, 0, -1), (0, -1, 1, 0), (0, 1, 1, 0), (0, -1, -1, 0)]
    let t = tfTable[Int(max(0, min(7, transform)))]
    input.transform = CGAffineTransform(a: t.0, b: t.1, c: t.2, d: t.3, tx: 0, ty: 0)
    guard writer.canAdd(input) else { return srFail(SRStatus.ioFailure, "writer: cannot add input") }
    writer.add(input)
    guard writer.startWriting() else { return srFail(SRStatus.ioFailure, "writer: \(writer.error?.localizedDescription ?? "?")") }
    writer.startSession(atSourceTime: .zero)
    for i in 0..<Int(count) {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        guard let pool = adaptor.pixelBufferPool else { return srFail(SRStatus.ioFailure, "writer: no pool") }
        var pbOut: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut)
        guard let pb = pbOut else { return srFail(SRStatus.ioFailure, "writer: no buffer") }
        CVPixelBufferLockBaseAddress(pb, [])
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let rb = CVPixelBufferGetBytesPerRow(pb)
        // Top 3/4: the frame index as 8 black/white stripes (MSB left). Bottom 1/4: four flat BGR segments, left to
        // right (40,40,200) (40,200,40) (200,40,40) (40,200,200) - asymmetric on purpose, so a rotated or mirrored track
        // can be checked against an analytic expectation. Keep in sync with pattern() in test_parity_io.py.
        let stripeW = max(1, Int(width) / 8)
        let split = Int(height) * 3 / 4
        let band: [(UInt8, UInt8, UInt8)] = [(40, 40, 200), (40, 200, 40), (200, 40, 40), (40, 200, 200)]
        for y in 0..<Int(height) {
            for x in 0..<Int(width) {
                let p = base + y * rb + x * 4
                if y < split {
                    let bit = x / stripeW < 8 ? (i >> (7 - x / stripeW)) & 1 : 0
                    let v: UInt8 = bit == 1 ? 255 : 0
                    p[0] = v; p[1] = v; p[2] = v
                } else {
                    let c = band[min(3, x * 4 / Int(width))]
                    p[0] = c.0; p[1] = c.1; p[2] = c.2
                }
                p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(Int(count) + Int(max(0, tailFrames))), timescale: CMTimeScale(fps)))
    let sem = DispatchSemaphore(value: 0)
    writer.finishWriting { sem.signal() }
    sem.wait()
    return writer.status == .completed ? SRStatus.ok : srFail(SRStatus.ioFailure, "writer: \(writer.error?.localizedDescription ?? "failed")")
}

/// Test hook (parity tests only): make the next seek that needs a new reader fail. Returns 0, or -1 for a non-AVFoundation source.
@_cdecl("sr_video_test_fail_next_seek")
public func sr_video_test_fail_next_seek(_ h: UnsafeMutableRawPointer?) -> Int32 {
    guard srTestHooksEnabled(), let h, let v = Unmanaged<VideoBox2>.fromOpaque(h).takeUnretainedValue().backend as? VideoSource else { return -1 }
    v.failNextReposition = true
    return 0
}

/// The test-only exports (`sr_video_write_test`, `sr_video_test_fail_next_seek`) do nothing unless this env var is "1".
func srTestHooksEnabled() -> Bool {
    guard let e = getenv("SAFARIUM_RASTER_TESTING") else { return false }
    return String(cString: e) == "1"
}
