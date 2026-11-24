// Independent AVAssetReader readback for the synthetic direct-worker smoke test.
import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation

private struct Mismatch: Error, CustomStringConvertible { let description: String; init(_ s: String) { description = s } }
private func need(_ ok: Bool, _ message: String) throws { if !ok { throw Mismatch(message) } }

private func read(_ asset: AVURLAsset, _ track: AVAssetTrack, _ settings: [String: Any],
                  visit: (CMSampleBuffer) throws -> Void) throws {
    let r = try AVAssetReader(asset: asset), o = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    o.alwaysCopiesSampleData = false
    try need(r.canAdd(o), "reader rejected track")
    r.add(o); try need(r.startReading(), "could not start reader")
    while let s = o.copyNextSampleBuffer() { if s.numSamples > 0 { try visit(s) } }
    try need(r.status == .completed, "reader: \(String(describing: r.error))")
}

@main
struct Inspect {
    static func main() async {
        do { try await check() }
        catch { FileHandle.standardError.write(Data("inspect: \(error)\n".utf8)); exit(1) }
    }
    private static func check() async throws {
        let a = CommandLine.arguments
        // Only the smoke harness supplies these arguments.
        let asset = AVURLAsset(url: URL(fileURLWithPath: a[1]), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let w = Int(a[2])!, h = Int(a[3])!, fps = Int32(a[4])!, frames = Int(a[5])!, phase = Int(a[6])!
        let audio = a[7] != "-", duration = CMTime(value: Int64(frames), timescale: fps)
        let tracks = try await asset.load(.tracks), v = tracks.filter { $0.mediaType == .video }
        try need(v.count == 1 && tracks.count == (audio ? 2 : 1), "unexpected track layout")
        try need(try await asset.load(.duration) == duration, "movie duration")
        for t in tracks {
            let range = try await t.load(.timeRange)
            try need(range.start == .zero && range.duration == duration, "track range: \(range)")
        }
        let vf = try await v[0].load(.formatDescriptions)[0]
        try need(CMFormatDescriptionGetMediaSubType(vf) == kCMVideoCodecType_H264, "not H.264")
        for key in [kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionExtension_YCbCrMatrix] {
            try need(CMFormatDescriptionGetExtension(vf, extensionKey: key) as? String == "ITU_R_709_2", "missing 709 \(key)")
        }
        var i = 0, pixels = SHA256()
        try read(asset, v[0], [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]) { s in
            let pts = CMTime(value: Int64(i), timescale: fps)
            try need(s.presentationTimeStamp == pts, "decoded frame \(i) PTS \(s.presentationTimeStamp), expected \(pts)")
            guard let image = s.imageBuffer else { throw Mismatch("missing decoded picture") }
            try need(CVPixelBufferGetWidth(image) == w && CVPixelBufferGetHeight(image) == h, "decoded geometry")
            try need(CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess, "locking picture")
            defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(image)!, stride = CVPixelBufferGetBytesPerRow(image)
            for y in 0..<h {
                pixels.update(bufferPointer: UnsafeRawBufferPointer(start: base.advanced(by: y * stride), count: w * 4))
            }
            let row = base.advanced(by: (h / 2) * stride)
            for (x, shift) in [(w / 4, 0), (3 * w / 4, 1)] {
                let p = row.assumingMemoryBound(to: UInt8.self).advanced(by: 4 * x), rgb = [p[2], p[1], p[0]]
                let expected = phase < 0 ? 0 : (phase + i + shift) % 3
                try need(rgb[expected] > 180 && rgb[(expected + 1) % 3] < 75 && rgb[(expected + 2) % 3] < 75,
                         "wrong page time/colour at frame \(i) x=\(x): \(rgb)")
            }
            i += 1
        }
        try need(i == frames, "decoded \(i)/\(frames) frames")
        var result: [String: Any] = ["frames": i, "bgra_sha256": pixels.finalize().map { String(format: "%02x", $0) }.joined()]
        if audio {
            guard let t = tracks.first(where: { $0.mediaType == .audio }) else { throw Mismatch("missing audio") }
            let desc = try await t.load(.formatDescriptions)[0], asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)!.pointee
            let rate: Int32 = a.count > 8 ? Int32(a[8])! : 48000
            let channels = a.count > 9 ? Int(a[9])! : 1, stride = channels * 4
            try need(asbd.mFormatID == kAudioFormatMPEG4AAC && asbd.mSampleRate == Double(rate) && asbd.mChannelsPerFrame == channels, "AAC format")
            guard let layout = CMAudioFormatDescriptionGetChannelLayout(desc, sizeOut: nil) else { throw Mismatch("missing AAC speaker layout") }
            // MPEG 1.0 is C, but Core Audio doesn't equate its generic Mono label
            // with a discrete-C bitmap. Stereo must match the actual WAVE L/R bits.
            var expected = AudioChannelLayout(), same: UInt32 = 0, bytes: UInt32 = 4
            if channels == 1 { expected.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_1_0 }
            else {
                expected.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap
                withUnsafeMutableBytes(of: &expected.mChannelBitmap) { $0.storeBytes(of: UInt32(3), as: UInt32.self) }
            }
            let status = withUnsafePointer(to: &expected) { p in
                [p, layout].withUnsafeBytes { AudioFormatGetProperty(kAudioFormatProperty_AreChannelLayoutsEquivalent,
                                                                     UInt32($0.count), $0.baseAddress, &bytes, &same) }
            }
            try need(status == noErr && same == 1, "AAC speaker labels/order differ from MPEG center mono or WAVE front stereo")
            result["aac_layout_tag"] = layout.pointee.mChannelLayoutTag
            let total = frames * Int(rate) / Int(fps)
            var pcm = Data(count: total * stride), filled = 0
            try read(asset, t, [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true,
                                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]) { s in
                let stamp = CMTimeConvertScale(s.presentationTimeStamp, timescale: rate, method: .roundHalfAwayFromZero)
                try need(stamp == s.presentationTimeStamp, "off-grid decoded PCM PTS")
                let base = Int(stamp.value), lo = max(0, base), hi = min(total, base + s.numSamples)
                if lo >= hi { return } // AAC encoder priming/trailing packets outside the presentation range
                try need(lo == filled, "decoded PCM gap/overlap")
                guard let block = s.dataBuffer else { throw Mismatch("missing decoded PCM bytes") }
                let err = pcm.withUnsafeMutableBytes { dst in
                    CMBlockBufferCopyDataBytes(block, atOffset: (lo - base) * stride, dataLength: (hi - lo) * stride,
                                               destination: dst.baseAddress!.advanced(by: lo * stride))
                }
                try need(err == noErr, "could not read decoded PCM")
                filled = hi
            }
            try need(filled == total, "incomplete decoded audio: \(filled)/\(total)")
            try pcm.write(to: URL(fileURLWithPath: a[7]), options: .withoutOverwriting)
            result["presented_samples_per_channel"] = filled
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    }
}
