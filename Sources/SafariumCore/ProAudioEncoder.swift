import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// Wave 9 Pro AudioToolbox codecs (100% native Apple AudioToolbox, 0% FFmpeg).
public enum SafariumAudioCodec: String, Codable, Sendable, CaseIterable {
    /// Apple AAC-LC with `AVAudioQuality.max` (`kAudioConverterQuality_Max`) — world-leading AAC-LC quality.
    case aacMax = "aac"
    /// HE-AAC v1 (SBR) for ultra-low-bitrate streaming (32–96 kbps).
    case heAAC = "he-aac"
    /// HE-AAC v2 (SBR + Parametric Stereo, 24–64 kbps stereo).
    case heAACv2 = "he-aac-v2"
    /// Apple Lossless Audio Codec (`alac`) — 100% bit-exact lossless in `.m4a` / `.mov` / `.mp4`.
    case alac = "alac"
    /// Native AudioToolbox Opus (`opus`) in `.caf` / `.mp4`.
    case opus = "opus"
    /// Apple Positional Audio Codec (`apac`, macOS 26+ Spatial Audio for MV-HEVC / visionOS).
    case apac = "apac"
    /// Uncompressed 16-bit integer PCM (`.wav` / `.mov`).
    case pcm16 = "pcm16"
    /// Uncompressed 24-bit integer PCM (`.wav` / `.mov`).
    case pcm24 = "pcm24"
    /// Uncompressed 32-bit float PCM (`.wav`).
    case pcmFloat32 = "pcm32f"

    /// FourCC `'apac'` (`0x61706163`), defined as `kAudioFormatAPAC` in macOS 26+ SDKs and safe on macOS 15 SDKs.
    public static let apacFormatID: AudioFormatID = 0x6170_6163

    public var formatID: AudioFormatID {
        switch self {
        case .aacMax: return kAudioFormatMPEG4AAC
        case .heAAC: return kAudioFormatMPEG4AAC_HE
        case .heAACv2: return kAudioFormatMPEG4AAC_HE_V2
        case .alac: return kAudioFormatAppleLossless
        case .opus: return kAudioFormatOpus
        case .apac: return Self.apacFormatID
        case .pcm16, .pcm24, .pcmFloat32: return kAudioFormatLinearPCM
        }
    }

    public var defaultExtension: String {
        switch self {
        case .aacMax, .heAAC, .heAACv2, .alac: return "m4a"
        case .opus: return "caf"
        case .apac: return "mov"
        case .pcm16, .pcm24, .pcmFloat32: return "wav"
        }
    }

    public static func parseCLI(_ raw: String) -> SafariumAudioCodec? {
        switch raw.lowercased() {
        case "aac", "aac-lc", "aac-max", "aac_at": return .aacMax
        case "he-aac", "heaac", "aach", "he-aac-v1": return .heAAC
        case "he-aac-v2", "heaacv2", "aacp", "he-aac2": return .heAACv2
        case "alac", "lossless": return .alac
        case "opus": return .opus
        case "apac", "spatial", "spatial-audio": return .apac
        case "pcm16", "pcm_s16le", "s16le", "wav": return .pcm16
        case "pcm24", "pcm_s24le", "s24le": return .pcm24
        case "pcm32f", "pcm_f32le", "f32le": return .pcmFloat32
        default: return nil
        }
    }
}

public struct ProAudioCapabilities: Codable, Sendable, Equatable {
    public let aacMaxQuality: Bool
    public let heAACv1: Bool
    public let heAACv2: Bool
    public let alac: Bool
    public let opus: Bool
    public let apacSpatial: Bool
    public let pcm16_24_32f: Bool
}

public struct ProAudioEncodeReport: Codable, Sendable {
    public let inputPath: String
    public let outputPath: String
    public let codec: String
    public let actualFormatFourCC: String
    public let sampleRate: Int
    public let channels: Int
    public let targetBitrate: Int?
    public let durationSeconds: Double
    public let outputBytes: Int64
    public let heAACFallbackDetected: Bool
    public let elapsedMs: Double
}

public enum ProAudioEncoder {
    /// Probes runtime AudioToolbox encoder availability on this macOS version.
    public static func probeCapabilities() -> ProAudioCapabilities {
        func canEncode(_ formatID: AudioFormatID) -> Bool {
            var spec = formatID
            var size: UInt32 = 0
            let st = AudioFormatGetPropertyInfo(
                kAudioFormatProperty_Encoders,
                UInt32(MemoryLayout<AudioFormatID>.size),
                &spec,
                &size
            )
            return st == noErr && size >= UInt32(MemoryLayout<AudioClassDescription>.size)
        }
        return ProAudioCapabilities(
            aacMaxQuality: canEncode(kAudioFormatMPEG4AAC),
            heAACv1: canEncode(kAudioFormatMPEG4AAC_HE),
            heAACv2: canEncode(kAudioFormatMPEG4AAC_HE_V2),
            alac: canEncode(kAudioFormatAppleLossless),
            opus: canEncode(kAudioFormatOpus),
            apacSpatial: canEncode(SafariumAudioCodec.apacFormatID),
            pcm16_24_32f: true
        )
    }

    /// Builds Apple-native AudioToolbox output settings for `AVAssetWriterInput` / `AVAudioFile`.
    public static func outputSettings(
        codec: SafariumAudioCodec,
        sampleRate: Int,
        channels: Int,
        bitrate: Int? = nil,
        apacContentSource: String = "av_spatial_offline",
        apacDRCConfig: String = "movie"
    ) -> [String: Any] {
        switch codec {
        case .aacMax:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: max(64_000, bitrate ?? (channels == 1 ? 96_000 : 192_000)),
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
            ]
        case .heAAC:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC_HE,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: min(96_000, max(32_000, bitrate ?? (channels == 1 ? 48_000 : 64_000))),
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
            ]
        case .heAACv2:
            // HE-AAC v2 requires stereo (2ch) and low bitrate (24-64 kbps) to keep Parametric Stereo active.
            let clampedChannels = max(2, min(2, channels))
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC_HE_V2,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: clampedChannels,
                AVEncoderBitRateKey: min(64_000, max(24_000, bitrate ?? 48_000)),
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
            ]
        case .alac:
            return [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitDepthHintKey: 24,
            ]
        case .opus:
            return [
                AVFormatIDKey: kAudioFormatOpus,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: max(24_000, bitrate ?? (channels == 1 ? 64_000 : 128_000)),
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
            ]
        case .apac:
            var settings: [String: Any] = [
                AVFormatIDKey: SafariumAudioCodec.apacFormatID,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: min(768_000, max(64_000, bitrate ?? 256_000)),
            ]
            // macOS 26+ APAC mandatory DRC + ContentSource + ASP Frequency keys (by documented AVFoundation string keys).
            let drcVal: Int
            switch apacDRCConfig.lowercased() {
            case "music": drcVal = 1
            case "speech": drcVal = 2
            case "capture": drcVal = 4
            default: drcVal = 3 // Movie (None=0 is disallowed for APAC)
            }
            let srcVal: Int
            switch apacContentSource.lowercased() {
            case "capture_spatial": srcVal = 3
            case "music_spatial": srcVal = 5
            default: srcVal = 4 // AV_Spatial_Offline
            }
            settings["AVEncoderDynamicRangeControlConfigurationKey"] = drcVal
            settings["AVEncoderContentSourceKey"] = srcVal
            settings["AVEncoderASPFrequencyKey"] = 75
            return settings
        case .pcm16:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Double(sampleRate),
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        case .pcm24:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Double(sampleRate),
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        case .pcmFloat32:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Double(sampleRate),
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }
    }

    private static func avFileType(for url: URL, codec: SafariumAudioCodec) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "m4a": return .m4a
        case "mp4": return .mp4
        case "mov": return .mov
        case "caf": return .caf
        case "wav": return .wav
        default:
            switch codec {
            case .opus: return .caf
            case .apac: return .mov
            case .pcm16, .pcm24, .pcmFloat32: return .wav
            default: return .m4a
            }
        }
    }

    private static func fourCCString(_ code: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(format: "0x%08x", code)
    }

    /// Transcodes any AVFoundation-readable audio/video input to a Pro AudioToolbox target codec (0% FFmpeg).
    public static func transcode(
        inputURL: URL,
        outputURL: URL,
        codec: SafariumAudioCodec,
        sampleRate: Int = 48_000,
        channels: Int = 2,
        bitrate: Int? = nil,
        overwrite: Bool = false
    ) async throws -> ProAudioEncodeReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(inputURL)
        try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)

        let asset = AVURLAsset(url: inputURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let srcTrack = audioTracks.first else {
            throw SafariumError.invalidState("no audio track found in \(inputURL.lastPathComponent)")
        }

        let targetSR = (codec == .opus || codec == .apac) ? 48_000 : max(8_000, sampleRate)
        let targetCh = (codec == .heAACv2) ? 2 : max(1, min(64, channels))

        let reader = try AVAssetReader(asset: asset)
        let readSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSR,
            AVNumberOfChannelsKey: targetCh,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let readerOut = AVAssetReaderTrackOutput(track: srcTrack, outputSettings: readSettings)
        readerOut.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOut) else {
            throw SafariumError.encode("cannot decode audio from \(inputURL.lastPathComponent)")
        }
        reader.add(readerOut)

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safarium-proaudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let ext = outputURL.pathExtension.isEmpty ? codec.defaultExtension : outputURL.pathExtension.lowercased()
        let stagedURL = tmpDir.appendingPathComponent("out.\(ext)")

        let fileType = avFileType(for: stagedURL, codec: codec)
        let writer = try AVAssetWriter(url: stagedURL, fileType: fileType)
        var settings = outputSettings(codec: codec, sampleRate: targetSR, channels: targetCh, bitrate: bitrate)
        if !writer.canApply(outputSettings: settings, forMediaType: .audio) {
            // If APAC extended keys or HE-AACv2 bitrate bounds are rejected on older OS, strip optional keys cleanly.
            settings.removeValue(forKey: "AVEncoderDynamicRangeControlConfigurationKey")
            settings.removeValue(forKey: "AVEncoderContentSourceKey")
            settings.removeValue(forKey: "AVEncoderASPFrequencyKey")
            if !writer.canApply(outputSettings: settings, forMediaType: .audio) {
                throw SafariumError.encode("AudioToolbox cannot apply \(codec.rawValue) output settings for \(fileType.rawValue)")
            }
        }
        let writerIn = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        writerIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerIn) else {
            throw SafariumError.encode("cannot add \(codec.rawValue) audio writer input")
        }
        writer.add(writerIn)

        guard reader.startReading() else {
            throw SafariumError.encode("audio reader failed: \(reader.error?.localizedDescription ?? "?")")
        }
        guard writer.startWriting() else {
            throw SafariumError.encode("audio writer failed: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)
        let gate = InputReadyGate(input: writerIn, writer: writer)

        var lastEnd = CMTime.zero
        while let sample = readerOut.copyNextSampleBuffer() {
            try await gate.waitUntilReady()
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let dur = CMSampleBufferGetDuration(sample)
            if pts.isValid && dur.isValid {
                let end = CMTimeAdd(pts, dur)
                if CMTimeCompare(end, lastEnd) > 0 { lastEnd = end }
            }
            guard writerIn.append(sample) else {
                throw SafariumError.encode("audio append failed: \(writer.error?.localizedDescription ?? "?")")
            }
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw SafariumError.encode("audio read failed: \(reader.error?.localizedDescription ?? "?")")
        }

        gate.invalidate()
        writerIn.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw SafariumError.encode("audio finish failed: \(writer.error?.localizedDescription ?? "?")")
        }

        // Verify actual emitted FourCC & check for silent HE-AAC v2 -> AAC-LC/HE-AAC v1 fallback!
        var actualFourCC = fourCCString(codec.formatID)
        var heFallback = false
        let verifyAsset = AVURLAsset(url: stagedURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        if let vTrack = (try? await verifyAsset.loadTracks(withMediaType: .audio))?.first,
           let fds = try? await vTrack.load(.formatDescriptions),
           let fd = fds.first {
            let sub = CMFormatDescriptionGetMediaSubType(fd)
            actualFourCC = fourCCString(sub)
            if codec == .heAACv2 && sub != kAudioFormatMPEG4AAC_HE_V2 {
                // Check AudioSpecificConfig audioObjectType (29 = PS / HE-AAC v2, 5 = SBR / HE-AAC v1, 2 = AAC-LC)
                var cookieSize: Int = 0
                if let cookie = CMAudioFormatDescriptionGetMagicCookie(fd, sizeOut: &cookieSize), cookieSize >= 2 {
                    let bytes = UnsafeBufferPointer(start: cookie.assumingMemoryBound(to: UInt8.self), count: cookieSize)
                    let hasPS = bytes.contains { ($0 >> 3) == 29 }
                    heFallback = !hasPS && (sub == kAudioFormatMPEG4AAC)
                }
            }
        }

        try SafeFilePublisher.publish(tempURL: stagedURL, to: outputURL, overwrite: overwrite)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0

        return ProAudioEncodeReport(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            codec: codec.rawValue,
            actualFormatFourCC: actualFourCC,
            sampleRate: targetSR,
            channels: targetCh,
            targetBitrate: settings[AVEncoderBitRateKey] as? Int,
            durationSeconds: lastEnd.isValid ? lastEnd.seconds : 0,
            outputBytes: bytes,
            heAACFallbackDetected: heFallback,
            elapsedMs: elapsedMs
        )
    }
}
