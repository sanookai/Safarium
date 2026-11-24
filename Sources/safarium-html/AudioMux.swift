import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import SafariumCore

/// Cheap header/edit-list verification before atomic RENAME_EXCL publication.
enum PublishedAssetCheck {
    static func verify(_ url: URL, options o: Options, audio: WAVRange?, hasSubtitles: Bool) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.load(.tracks)
        let video = tracks.filter { $0.mediaType == .video }
        let sound = tracks.filter { $0.mediaType == .audio }
        let subs = tracks.filter { $0.mediaType == .subtitle }
        let expectedCount = 1 + (audio == nil ? 0 : 1) + (hasSubtitles ? 1 : 0)
        guard tracks.count == expectedCount,
              video.count == 1,
              sound.count == (audio == nil ? 0 : 1),
              subs.count == (hasSubtitles ? 1 : 0),
              try await asset.load(.duration) == o.duration else {
            throw WorkerError("unexpected track layout or movie duration")
        }
        func checkRange(_ track: AVAssetTrack, _ name: String) async throws {
            let range = try await track.load(.timeRange)
            guard range.start == .zero, range.duration == o.duration else {
                throw WorkerError("\(name) track does not cover exactly [0, \(o.frames)/\(o.fps)) seconds")
            }
        }
        try await checkRange(video[0], "video")
        let formats = try await video[0].load(.formatDescriptions)
        let expectedSubtype: CMVideoCodecType = switch o.codec {
        case .h264: kCMVideoCodecType_H264
        case .hevc, .hevcAlpha: kCMVideoCodecType_HEVC
        case .proRes422: kCMVideoCodecType_AppleProRes422
        case .proRes4444: kCMVideoCodecType_AppleProRes4444
        }
        guard formats.count == 1, let f = formats.first, CMFormatDescriptionGetMediaSubType(f) == expectedSubtype else {
            throw WorkerError("expected a single \(o.codec) video format")
        }
        let d = CMVideoFormatDescriptionGetDimensions(f)
        guard d.width == o.width, d.height == o.height else {
            throw WorkerError("encoder changed the requested dimensions")
        }
        for (key, tag) in [(kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2),
                           (kCMFormatDescriptionExtension_TransferFunction, kCMFormatDescriptionTransferFunction_ITU_R_709_2),
                           (kCMFormatDescriptionExtension_YCbCrMatrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2)] {
            guard CMFormatDescriptionGetExtension(f, extensionKey: key) as? String == tag as String else {
                throw WorkerError("video track is missing the requested BT.709 \(key) tag")
            }
        }
        if o.codec.hasAlpha {
            let exts = CMFormatDescriptionGetExtensions(f) as? [String: Any]
            let containsAlpha = (exts?[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? Bool) ?? false
            let chars = try await video[0].load(.mediaCharacteristics)
            guard containsAlpha || chars.contains(.containsAlphaChannel) else {
                throw WorkerError("\(o.codec) track is missing alpha channel metadata")
            }
        }
        if let audio {
            try await checkRange(sound[0], "audio")
            let af = try await sound[0].load(.formatDescriptions)
            guard af.count == 1, let desc = af.first,
                  let info = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee,
                  info.mFormatID == kAudioFormatMPEG4AAC,
                  info.mSampleRate == Double(audio.rate),
                  info.mChannelsPerFrame == audio.channels else {
                throw WorkerError("AAC did not preserve WAV rate/channel count")
            }
            guard let layout = CMAudioFormatDescriptionGetChannelLayout(desc, sizeOut: nil),
                  audio.speakers.matches(layout) else {
                throw WorkerError("AAC did not preserve the WAV speaker layout and channel order")
            }
        }
        if hasSubtitles {
            let sf = try await subs[0].load(.formatDescriptions)
            guard sf.count == 1, let sdesc = sf.first,
                  CMFormatDescriptionGetMediaType(sdesc) == kCMMediaType_Subtitle else {
                throw WorkerError("missing tx3g subtitle format description")
            }
            let group = try await asset.loadMediaSelectionGroup(for: .legible)
            guard let group, group.options.contains(where: { $0.isPlayable }) else {
                throw WorkerError("subtitle track has no playable legible selection option")
            }
        }
    }
}
