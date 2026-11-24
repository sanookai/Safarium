// Self-contained, read-only Apple media comparator for Safarium's SDR, Alpha, and tx3g delivery profiles.
// No shell commands. No movie-sized buffers, side-by-side readers or frame lists.
import Foundation
import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin

struct Problem: Error, CustomStringConvertible {
    let description: String
    init(_ s: String) { description = s }
}
func require(_ test: Bool, _ reason: String) throws { if !test { throw Problem(reason) } }
func ratio(_ t: CMTime) throws -> String {
    try require(t.isNumeric && t.timescale > 0 && t.epoch == 0, "unsupported or missing presentation time")
    var a = UInt64(t.timescale), b = t.value.magnitude % a
    while b != 0 { (a, b) = (b, a % b) }
    return "\(t.value / Int64(a))/\(Int64(t.timescale) / Int64(a))"
}
func framesAt(_ t: CMTime, rate: Int32) throws -> Int64 {
    _ = try ratio(t)
    let v = CMTimeConvertScale(t, timescale: rate, method: .roundHalfAwayFromZero)
    try require(v.isNumeric && CMTimeCompare(t, v) == 0, "audio edit is not on its sample grid")
    return v.value
}
func hashString(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
func fourcc(_ v: FourCharCode) -> String {
    String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: v >> $0) }, as: UTF8.self)
}
typealias Obj = [String: Any]
func reader(_ a: AVAsset, _ track: AVAssetTrack, _ settings: Obj?) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
    let r = try AVAssetReader(asset: a), o = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    o.alwaysCopiesSampleData = false
    try require(r.canAdd(o), "cannot configure Apple reader"); r.add(o)
    try require(r.startReading(), "reader did not start: \(r.error?.localizedDescription ?? "unknown")")
    return (r, o)
}

struct Track: Equatable, Codable {
    let start: String, duration: String, language: String?, extendedLanguage: String?, enabled: Bool
}
func trackInfo(_ t: AVAssetTrack, _ range: CMTimeRange) async throws -> Track {
    return Track(
        start: try ratio(range.start),
        duration: try ratio(range.duration),
        language: try await t.load(.languageCode),
        extendedLanguage: try await t.load(.extendedLanguageTag),
        enabled: try await t.load(.isEnabled)
    )
}
struct Video: Equatable, Codable {
    let track: Track, codec: String, width: Int, height: Int, displaySize: [Double], transform: [Double]
    let avcProfile: Int?, avcConstraints: Int?, avcLevel: Int?, hasAlpha: Bool?, chromaLocations: [String]
    let aperture: [Double], pixelAspect: [String], primaries: String, transfer: String, matrix: String, sourceRange: String
    let frames: Int, firstPTS: String, lastPTS: String, ptsAndDurationsSHA256: String
    let activeNV12SHA256: String?, activeBGRASHA256: String?
}
struct Audio: Equatable, Codable {
    let track: Track, codec: String, sampleRate: Int, channels: Int, channelLayoutSHA256: String?, volume: Float
    let presentedSamples: Int64, float32PCM_SHA256: String
}
struct SubtitleSummary: Equatable, Codable {
    let track: Track, codec: String, sampleCount: Int, cuesSHA256: String
}
struct Movie: Equatable, Codable {
    let duration: String, video: Video, audio: Audio?, subtitles: SubtitleSummary?
}
struct Reply: Encodable {
    let scope = "Decoded SDR H.264/HEVC/ProRes (8-bit 4:2:0 BT.709 or 32-bit BGRA alpha), presentation timing, declared track properties, optional mono/stereo AAC PCM, optional tx3g subtitles. Excludes container tags, chapters and playback differences across machines."
    let mode: String, reference: Movie, candidate: Movie?, exactMatch: Bool?, differingSections: [String]
}
func ext(_ f: CMFormatDescription, _ key: CFString) -> String? {
    if let v = CMFormatDescriptionGetExtension(f, extensionKey: key) { return String(describing: v) }
    return nil
}
func nonEmpty(_ s: CMSampleBuffer) throws -> Bool {
    if s.numSamples != 0 { return true }
    try require(s.imageBuffer == nil && (s.dataBuffer.map(CMBlockBufferGetDataLength) ?? 0) == 0, "unrecognized zero-sample marker")
    return false
}
// Baseline/Main/Extended imply 8-bit 4:2:0. In High, read the actual SPS values
// rather than certifying identity after a potentially lossy decoder conversion.
func supports420(_ s: UnsafePointer<UInt8>, _ length: Int) -> Bool {
    guard length >= 5, s[0] & 31 == 7 else { return false }
    if [66, 77, 88].contains(Int(s[1])) { return true }
    guard s[1] == 100 else { return false }
    var bits = [UInt8](), zeros = 0
    for i in 1..<min(length, 128) {
        let b = s[i]
        if zeros >= 2 && b == 3 { zeros = 0; continue }
        bits.append(b); zeros = b == 0 ? zeros + 1 : 0
    }
    var index = 24
    func next() -> Int? {
        guard index < bits.count * 8 else { return nil }
        let v = Int((bits[index / 8] >> (7 - index % 8)) & 1); index += 1; return v
    }
    func ue() -> Int? {
        var z = 0
        while true { guard let b = next(), z <= 22 else { return nil }; if b == 1 { break }; z += 1 }
        var value = 1
        for _ in 0..<z { guard let b = next() else { return nil }; value = value * 2 + b }
        return value - 1
    }
    guard ue() != nil else { return false }
    return ue() == 1 && ue() == 0 && ue() == 0
}
func video(_ a: AVAsset, _ t: AVAssetTrack) async throws -> Video {
    let fmts = try await t.load(.formatDescriptions), range = try await t.load(.timeRange)
    try require(fmts.count == 1, "changing video formats are outside this verifier")
    let f = fmts[0], code = fourcc(CMFormatDescriptionGetMediaSubType(f))
    let supportedCodecs = ["avc1", "hvc1", "hev1", "muxa", "ap4h", "apcn"]
    try require(supportedCodecs.contains(code), "unsupported video codec \(code); expected avc1, hvc1/hev1, muxa, ap4h, or apcn")
    let dim = CMVideoFormatDescriptionGetDimensions(f), width = Int(dim.width), height = Int(dim.height)
    try require(width > 0 && height > 0 && width % 2 == 0 && height % 2 == 0, "nonstandard geometry")

    let chars = try await t.load(.mediaCharacteristics)
    let extAlpha = (CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) as? NSNumber)?.boolValue == true
    let isAlpha = code == "ap4h" || code == "muxa" || extAlpha || chars.contains(.containsAlphaChannel)

    var profile: Int? = nil, constraints: Int? = nil, level: Int? = nil
    if code == "avc1" {
        try require(!isAlpha, "avc1 cannot carry alpha channel")
        var src: UnsafePointer<UInt8>?, size = 0, parameterSets = 0
        let sps = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            f, parameterSetIndex: 0, parameterSetPointerOut: &src,
            parameterSetSizeOut: &size, parameterSetCountOut: &parameterSets, nalUnitHeaderLengthOut: nil
        )
        guard sps == noErr, let src, supports420(src, size) else {
            throw Problem("unsupported H.264 profile or bit depth; cannot certify at 8-bit 4:2:0")
        }
        profile = Int(src[1]); constraints = Int(src[2]); level = Int(src[3])
        guard (2...64).contains(parameterSets) else { throw Problem("unsupported AVC parameter sets") }
        for i in 1..<parameterSets {
            var ptr: UnsafePointer<UInt8>?, n = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                f, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                parameterSetSizeOut: &n, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let ptr, n > 0, ptr[0] & 31 == 8 else {
                throw Problem("changing AVC sequence parameters require a format-specific check")
            }
        }
    }

    let fields = (CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_FieldCount) as? NSNumber)?.intValue
    guard fields == nil || fields == 1 else { throw Problem("interlaced video requires a field-aware comparator") }
    let locations = [kCMFormatDescriptionExtension_ChromaLocationTopField, kCMFormatDescriptionExtension_ChromaLocationBottomField]
        .map { ext(f, $0) ?? "unspecified" }
    let p = ext(f, kCMFormatDescriptionExtension_ColorPrimaries)
    let tr = ext(f, kCMFormatDescriptionExtension_TransferFunction)
    let mx = ext(f, kCMFormatDescriptionExtension_YCbCrMatrix)
    let full = (CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? NSNumber)?.boolValue

    if code == "avc1" {
        guard p == kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
              tr == kCVImageBufferTransferFunction_ITU_R_709_2 as String,
              mx == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String else {
            throw Problem("requires tagged BT.709 SDR; use a format-specific checker for other colour profiles")
        }
        guard CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_ICCProfile) == nil,
              CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_GammaLevel) == nil else {
            throw Problem("custom ICC/gamma profile needs a format-specific check")
        }
        try require(full != true, "full-range input requires a native full-range verification path")
    } else if !isAlpha {
        guard p == kCVImageBufferColorPrimaries_ITU_R_709_2 as String || p == nil else {
            throw Problem("unsupported color primaries \(p ?? "")")
        }
    }

    let clean = CMVideoFormatDescriptionGetCleanAperture(f, originIsAtTopLeft: true)
    let aspect = CMFormatDescriptionGetExtension(f, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) as? NSDictionary
    let asp = [kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing, kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing]
        .map { aspect?[$0].map { String(describing: $0) } ?? "unspecified" }
    let display = try await t.load(.naturalSize), m = try await t.load(.preferredTransform), meta = try await trackInfo(t, range)

    let targetPixelFormat = isAlpha ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    let (r, o) = try reader(a, t, [kCVPixelBufferPixelFormatTypeKey as String: targetPixelFormat])
    var pixels = SHA256(), clock = SHA256(), n = 0, first = "", last = "", previous: CMTime?
    while try autoreleasepool(invoking: { () throws -> Bool in
        guard let s = o.copyNextSampleBuffer() else { return false }
        if try !nonEmpty(s) { return true }
        guard s.numSamples == 1, let b = s.imageBuffer else { throw Problem("decoded buffer is not a single video frame") }
        let pts = s.presentationTimeStamp, stamp = try ratio(pts)
        try require(CMTimeCompare(pts, range.start) >= 0 && CMTimeCompare(pts, range.end) < 0, "video PTS outside presentation range")
        if let prev = previous { try require(CMTimeCompare(prev, pts) < 0, "non-increasing video PTS") }
        let duration = s.duration.isNumeric ? try ratio(s.duration) : "unspecified"
        clock.update(data: Data("\(stamp) \(duration)\n".utf8))
        try require(
            CVPixelBufferGetWidth(b) == width && CVPixelBufferGetHeight(b) == height &&
            CVPixelBufferGetPixelFormatType(b) == targetPixelFormat,
            "decoded video format changed"
        )
        try require(CVPixelBufferLockBaseAddress(b, .readOnly) == kCVReturnSuccess, "cannot lock image")
        defer { CVPixelBufferUnlockBaseAddress(b, .readOnly) }

        if isAlpha {
            let stride = CVPixelBufferGetBytesPerRow(b), rowBytes = width * 4
            guard stride >= rowBytes, let base = CVPixelBufferGetBaseAddress(b) else {
                throw Problem("invalid decoded BGRA buffer")
            }
            for y in 0..<height {
                pixels.update(bufferPointer: UnsafeRawBufferPointer(start: base.advanced(by: y * stride), count: rowBytes))
            }
        } else {
            try require(CVPixelBufferGetPlaneCount(b) == 2, "decoded video format changed")
            for plane in 0..<2 {
                let h = CVPixelBufferGetHeightOfPlane(b, plane), w = CVPixelBufferGetWidthOfPlane(b, plane), stride = CVPixelBufferGetBytesPerRowOfPlane(b, plane)
                guard h == height / (1 + plane), w == width / (1 + plane), stride >= width, let base = CVPixelBufferGetBaseAddressOfPlane(b, plane) else {
                    throw Problem("invalid decoded plane")
                }
                for y in 0..<h {
                    pixels.update(bufferPointer: UnsafeRawBufferPointer(start: base.advanced(by: y * stride), count: width))
                }
            }
        }
        if n == 0 { first = stamp }; last = stamp; previous = pts; n += 1
        return true
    }) {}
    try require(r.status == .completed && n > 0, "video decode failed or empty: \(r.error?.localizedDescription ?? "no video")")

    let pixelDigest = hashString(pixels.finalize())
    return Video(
        track: meta, codec: code, width: width, height: height,
        displaySize: [display.width, display.height], transform: [m.a, m.b, m.c, m.d, m.tx, m.ty],
        avcProfile: profile, avcConstraints: constraints, avcLevel: level,
        hasAlpha: code == "avc1" ? nil : isAlpha,
        chromaLocations: locations, aperture: [clean.minX, clean.minY, clean.width, clean.height],
        pixelAspect: asp,
        primaries: p ?? "unspecified", transfer: tr ?? "unspecified", matrix: mx ?? "unspecified",
        sourceRange: full == nil ? "unspecified" : (full == true ? "full" : "video"),
        frames: n, firstPTS: first, lastPTS: last, ptsAndDurationsSHA256: hashString(clock.finalize()),
        activeNV12SHA256: isAlpha ? nil : pixelDigest,
        activeBGRASHA256: isAlpha ? pixelDigest : nil
    )
}
func audio(_ a: AVAsset, _ t: AVAssetTrack) async throws -> Audio {
    let fmts = try await t.load(.formatDescriptions), range = try await t.load(.timeRange), meta = try await trackInfo(t, range)
    let volume = try await t.load(.preferredVolume)
    guard fmts.count == 1, let fmt = fmts.first, let orig = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
          orig.mFormatID == kAudioFormatMPEG4AAC, let rate = Int32(exactly: orig.mSampleRate), rate > 0,
          (1...2).contains(orig.mChannelsPerFrame) else {
        throw Problem("requires a single native-rate mono/stereo AAC format")
    }
    let ch = Int(orig.mChannelsPerFrame), start = try framesAt(range.start, rate: rate), end = try framesAt(range.end, rate: rate)
    try require(end > start && start >= 0, "unsupported empty or negative audio edit")
    var layoutSize = 0
    let layout = CMAudioFormatDescriptionGetChannelLayout(fmt, sizeOut: &layoutSize)
        .map { hashString(SHA256.hash(data: Data(bytes: $0, count: layoutSize))) }
    let (r, o) = try reader(a, t, [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ])
    var hash = SHA256(), next = start, chunk = [UInt8](repeating: 0, count: 65536)
    while try autoreleasepool(invoking: { () throws -> Bool in
        guard let s = o.copyNextSampleBuffer() else { return false }
        if try !nonEmpty(s) { return true }
        guard let f = s.formatDescription, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f)?.pointee,
              asbd.mSampleRate == Double(rate), Int(asbd.mChannelsPerFrame) == ch, asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mBitsPerChannel == 32, Int(asbd.mBytesPerFrame) == ch * 4,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & (kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian) == 0,
              let buf = s.dataBuffer else { throw Problem("unexpected decoded PCM") }
        let pos = try framesAt(s.presentationTimeStamp, rate: rate), n = s.numSamples, stride = ch * 4
        let (last, ov) = pos.addingReportingOverflow(Int64(n))
        try require(n > 0 && !ov && n <= Int.max / stride && CMBlockBufferGetDataLength(buf) == n * stride, "inconsistent PCM buffer length")
        let lo = max(start, pos), hi = min(end, last)
        if lo < hi {
            try require(lo == next, "gap/overlap in presented audio")
            var offset = Int(lo - pos) * stride, rest = Int(hi - lo) * stride
            while rest > 0 {
                let take = min(rest, chunk.count)
                try chunk.withUnsafeMutableBytes { raw in
                    try require(CMBlockBufferCopyDataBytes(buf, atOffset: offset, dataLength: take, destination: raw.baseAddress!) == noErr, "cannot read PCM")
                    hash.update(bufferPointer: UnsafeRawBufferPointer(start: raw.baseAddress, count: take))
                }
                rest -= take; offset += take
            }
            next = hi
        }
        return true
    }) {}
    try require(r.status == .completed && next == end, "incomplete decoded audio; expected end \(end), got \(next)")
    return Audio(
        track: meta, codec: fourcc(orig.mFormatID), sampleRate: Int(rate), channels: ch,
        channelLayoutSHA256: layout, volume: volume, presentedSamples: end - start,
        float32PCM_SHA256: hashString(hash.finalize())
    )
}
func subtitles(_ a: AVAsset, _ t: AVAssetTrack) async throws -> SubtitleSummary {
    let fmts = try await t.load(.formatDescriptions), range = try await t.load(.timeRange), meta = try await trackInfo(t, range)
    guard fmts.count == 1, let fmt = fmts.first else {
        throw Problem("changing subtitle formats are outside this verifier")
    }
    let code = fourcc(CMFormatDescriptionGetMediaSubType(fmt))
    try require(code == "tx3g", "unsupported subtitle codec \(code); expected tx3g")
    let legible = try await a.loadMediaSelectionGroup(for: .legible)
    try require(legible?.options.contains(where: { $0.isPlayable }) == true, "subtitle track is not playable in legible media selection group")

    let (r, o) = try reader(a, t, nil)
    var hash = SHA256(), count = 0, chunk = [UInt8](repeating: 0, count: 65536)
    while try autoreleasepool(invoking: { () throws -> Bool in
        guard let s = o.copyNextSampleBuffer() else { return false }
        let len = s.dataBuffer.map(CMBlockBufferGetDataLength) ?? 0
        if s.numSamples == 0 && len == 0 { return true }
        let pts = try ratio(s.presentationTimeStamp)
        let dur = s.duration.isNumeric ? try ratio(s.duration) : "unspecified"
        hash.update(data: Data("\(pts) \(dur) \(len):".utf8))
        if len > 0, let db = s.dataBuffer {
            var offset = 0
            while offset < len {
                let take = min(chunk.count, len - offset)
                try chunk.withUnsafeMutableBytes { raw in
                    try require(CMBlockBufferCopyDataBytes(db, atOffset: offset, dataLength: take, destination: raw.baseAddress!) == noErr, "cannot read subtitle cue")
                    hash.update(bufferPointer: UnsafeRawBufferPointer(start: raw.baseAddress, count: take))
                }
                offset += take
            }
        }
        count += 1
        return true
    }) {}
    try require(r.status == .completed && count > 0, "subtitle read failed or empty: \(r.error?.localizedDescription ?? "no cues")")
    return SubtitleSummary(track: meta, codec: code, sampleCount: count, cuesSHA256: hashString(hash.finalize()))
}
func inspect(_ file: String) async throws -> Movie {
    let u = URL(fileURLWithPath: file)
    let values = try u.resourceValues(forKeys: [.isRegularFileKey])
    try require(values.isRegularFile == true, "expected a local regular media file")
    let a = AVURLAsset(url: u, options: [
        AVURLAssetPreferPreciseDurationAndTimingKey: true,
        AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
    ])
    let tracks = try await a.load(.tracks)
    let vs = tracks.filter { $0.mediaType == .video }
    let as_ = tracks.filter { $0.mediaType == .audio }
    let subs = tracks.filter { $0.mediaType == .subtitle }
    guard vs.count == 1, as_.count <= 1, subs.count <= 1, tracks.count == vs.count + as_.count + subs.count else {
        throw Problem("expected one video, at most one audio, and at most one tx3g subtitle track")
    }
    let dur = try ratio(await a.load(.duration)), v = try await video(a, vs[0])
    let sound: Audio?
    if let t = as_.first { sound = try await audio(a, t) } else { sound = nil }
    let sub: SubtitleSummary?
    if let st = subs.first { sub = try await subtitles(a, st) } else { sub = nil }
    return Movie(duration: dur, video: v, audio: sound, subtitles: sub)
}
@main struct Verify {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        let help = "Usage: safarium-render verify REFERENCE.(mp4|mov) [CANDIDATE.(mp4|mov)]\nOne file inspects; two check exact decoded image/audio/tx3g essence and track timing. Tagged SDR H.264/HEVC/ProRes (opaque or alpha), optional mono/stereo AAC, optional tx3g subtitles."
        if args == ["--help"] || args == ["-h"] { print(help); return }
        guard (1...2).contains(args.count) else {
            FileHandle.standardError.write(Data((help + "\n").utf8)); exit(64)
        }
        do {
            let ref = try await inspect(args[0]); var other: Movie?, diff = [String]()
            if args.count == 2 {
                let m = try await inspect(args[1]); other = m
                if ref.duration != m.duration { diff.append("duration") }
                if ref.video != m.video { diff.append("video") }
                if ref.audio != m.audio { diff.append("audio") }
                if ref.subtitles != m.subtitles { diff.append("subtitles") }
            }
            let reply = Reply(
                mode: other == nil ? "inspect" : "compare", reference: ref, candidate: other,
                exactMatch: other == nil ? nil : diff.isEmpty, differingSections: diff
            )
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try enc.encode(reply))
            FileHandle.standardOutput.write(Data("\n".utf8))
            if !diff.isEmpty { exit(2) }
        } catch {
            FileHandle.standardError.write(Data(("safarium-verify: \(error)\n").utf8))
            exit(1)
        }
    }
}
