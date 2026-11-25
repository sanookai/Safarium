import AVFoundation
import Foundation

// MARK: - Module-Wide Codable Conformances & Wave 10 Type Aliases

extension VideoCodec: Codable {}
extension SinkPixelFormat: Codable {}

/// Alias matching Wave 10 scenario API naming (`SinkPixelFormat` in `FrameSink.swift`).
public typealias PixelFormat = SinkPixelFormat

/// Alias matching Wave 10 scenario API naming (`ColorMasteringProfile` in `FrameSink.swift`).
public typealias HDRMode = ColorMasteringProfile

/// Alias matching Wave 10 scenario API naming (`SafariumAudioCodec` in `ProAudioEncoder.swift`).
public typealias ProAudioCodec = SafariumAudioCodec

// MARK: - Spatial Adaptive QP Level

/// VideoToolbox Spatial Adaptive Quantization strength (macOS 15+ Apple Silicon).
public enum SpatialAQLevel: String, Codable, Sendable, CaseIterable {
    case off = "off"
    case low = "low"
    case medium = "medium"
    case high = "high"
    case auto = "auto"

    public var isEnabled: Bool {
        self != .off
    }

    /// Integer value for VideoToolbox `SpatialAdaptiveQPLevel` (`0` = disabled, `-1` = default/auto).
    public var vtPropertyValue: Int {
        switch self {
        case .off: return 0
        case .auto: return -1
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }
}

// MARK: - Wave 10 Encoding Scenarios

/// Curated Apple Silicon native encoding scenarios covering web, social, cinema, HDR, visionOS,
/// live streaming, archival, and animated clip deliverables (0% FFmpeg).
public enum EncodingScenario: String, CaseIterable, Codable, Sendable {
    case youtube = "youtube"
    case youtube4k = "youtube-4k"
    case shorts = "shorts"
    case tiktok = "tiktok"
    case reels = "reels"
    case webStreaming = "web-streaming"
    case webCompat = "web-compat"
    case screenRecording = "screen-recording"
    case cinemaMaster = "cinema-master"
    case cinemaVFX = "cinema-vfx"
    case transparentVFX = "transparent-vfx"
    case hdrDolbyVision = "hdr-dolby-vision"
    case hdr10 = "hdr10"
    case spatialVisionOS = "spatial-visionos"
    case archival = "archival"
    case liveLowLatency = "live-low-latency"
    case podcastVideo = "podcast-video"
    case webpClip = "webp-clip"
    case gifClip = "gif-clip"

    /// Returns the tuned `EncodingScenarioProfile` for this scenario.
    public var profile: EncodingScenarioProfile {
        EncodingScenario.profile(for: self)
    }

    /// Returns all scenario profiles in `CaseIterable` order.
    public static func allProfiles() -> [EncodingScenarioProfile] {
        allCases.map { profile(for: $0) }
    }

    /// Parses canonical names and common CLI aliases into an `EncodingScenario`.
    public static func parse(_ raw: String) -> EncodingScenario? {
        let normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")

        if let direct = EncodingScenario(rawValue: normalized) {
            return direct
        }

        switch normalized {
        case "yt", "youtube-1080p", "yt-1080p", "youtube-hd":
            return .youtube
        case "yt4k", "yt-4k", "youtube4k", "youtube-uhd", "youtube-2160p", "4k":
            return .youtube4k
        case "youtube-shorts", "yt-shorts", "short", "vertical":
            return .shorts
        case "tt", "tik-tok":
            return .tiktok
        case "ig-reels", "instagram-reels", "instagram", "reel":
            return .reels
        case "webstreaming", "hls", "cmaf", "abr", "hls-cmaf", "streaming":
            return .webStreaming
        case "webcompat", "web", "compat", "universal", "h264-web", "mp4-compat":
            return .webCompat
        case "screenrecording", "screen", "screencast", "desktop", "ui-recording":
            return .screenRecording
        case "cinemamaster", "cinema", "master", "prores", "prores422hq", "prores-hq":
            return .cinemaMaster
        case "cinemavfx", "vfx", "prores4444", "prores4444xq", "prores-xq", "di-master":
            return .cinemaVFX
        case "transparentvfx", "transparent", "alpha", "hevc-alpha", "overlay", "motion-graphics":
            return .transparentVFX
        case "hdrdolbyvision", "dolby-vision", "dolbyvision", "dv", "dv84", "dv-8.4":
            return .hdrDolbyVision
        case "hdr", "hdr10-pq", "hdr-pq", "pq", "bt2020-pq":
            return .hdr10
        case "spatialvisionos", "spatial", "visionos", "vision-os", "mv-hevc", "mvhevc", "stereo":
            return .spatialVisionOS
        case "archive", "preservation", "lossless-archive", "master-archive":
            return .archival
        case "livelowlatency", "live", "low-latency", "realtime", "real-time", "rtmp", "ll-hls":
            return .liveLowLatency
        case "podcastvideo", "podcast", "talking-head", "webinar", "lecture":
            return .podcastVideo
        case "webpclip", "webp", "animated-webp", "webp-anim":
            return .webpClip
        case "gifclip", "gif", "animated-gif", "gif-anim":
            return .gifClip
        default:
            return nil
        }
    }

    /// Static factory returning the hardware-tuned encoding profile for a given scenario.
    public static func profile(for scenario: EncodingScenario) -> EncodingScenarioProfile {
        switch scenario {
        case .youtube:
            return EncodingScenarioProfile(
                scenario: .youtube,
                summary: "YouTube 1080p SDR master — 10-bit HEVC with Mini-CAE, Spatial AQ, 16-frame lookahead, fast-start MP4, and AAC-Max audio.",
                recommendedContainer: "mp4",
                codec: .hevc10,
                pixelFormat: .p010,
                hdrMode: .sdrBT709,
                audioCodec: .aacMax,
                audioBitrate: 256_000,
                targetVideoBitrate: 12_000_000,
                cqf: nil,
                useTwoPass: false,
                useMiniCAE: true,
                spatialAQ: .high,
                lookAheadFrames: 16,
                maxGOPSeconds: 2.0,
                allowBFrames: true,
                fastStart: true,
                targetWidth: 1920,
                targetHeight: 1080,
                targetFPS: nil,
                toneMapHDRToSDR: false
            )

        case .youtube4k:
            return EncodingScenarioProfile(
                scenario: .youtube4k,
                summary: "YouTube 4K UHD master — 10-bit HEVC P010 at 45 Mbps with Mini-CAE, Spatial AQ, 16-frame lookahead, and 320 kbps AAC-Max.",
                recommendedContainer: "mp4",
                codec: .hevc10,
                pixelFormat: .p010,
                hdrMode: .sdrBT709,
                audioCodec: .aacMax,
                audioBitrate: 320_000,
                targetVideoBitrate: 45_000_000,
                cqf: nil,
                useTwoPass: false,
                useMiniCAE: true,
                spatialAQ: .high,
                lookAheadFrames: 16,
                maxGOPSeconds: 2.0,
                allowBFrames: true,
                fastStart: true,
                targetWidth: 3840,
                targetHeight: 2160,
                targetFPS: nil,
                toneMapHDRToSDR: false
            )

        case .shorts:
            return EncodingScenarioProfile(
                scenario: .shorts,
                summary: "YouTube Shorts vertical 9:16 1080x1920 up to 60 fps — 10-bit HEVC with Mini-CAE and HDR-to-SDR tone-mapping safety.",
                recommendedContainer: "mp4",
                codec: .hevc10,
                pixelFormat: .p010,
                hdrMode: .sdrBT709,
                audioCodec: .aacMax,
                audioBitrate: 192_000,
                targetVideoBitrate: 12_000_000,
                cqf: nil,
                useTwoPass: false,
                useMiniCAE: true,
                spatialAQ: .high,
                lookAheadFrames: 12,
                maxGOPSeconds: 2.0,
                allowBFrames: true,
                fastStart: true,
                targetWidth: 1080,
                targetHeight: 1920,
                targetFPS: 60,
                toneMapHDRToSDR: true
            )

        case .tiktok:
            return EncodingScenarioProfile(
                scenario: .tiktok,
                summary: "TikTok vertical 9:16 1080x1920 30 fps — 2-pass H.264 SDR BT.709 for maximum re-encode preservation and universal mobile playback.",
                recommendedContainer: "mp4",
                codec: .h264,
                pixelFormat: .nv12Left,
                hdrMode: .sdrBT709,
                audioCodec: .aacMax,
                audioBitrate: 192_000,
                targetVideoBitrate: 10_000_000,
                cqf: nil,
                useTwoPass: true,
                useMiniCAE: false,
                spatialAQ: .medium,
                lookAheadFrames: 0,
                maxGOPSeconds: 2.0,
                allowBFrames: true,
                fastStart: true,
                targetWidth: 1080,
                targetHeight: 1920,
                targetFPS: 30,
                toneMapHDRToSDR: true
            )

        case .reels:
            return EncodingScenarioProfile(
                scenario: .reels,
                summary: "Instagram Reels vertical 9:16 1080x1920 30 fps — 2-pass H.264 SDR BT.709 with fast-start MP4 and 192 kbps AAC-Max.",
                recommendedContainer: "mp4",
                codec: .h264,
                pixelFormat: .nv12Left,
                hdrMode: .sdrBT709,
                audioCodec: .aacMax,
                audioBitrate: 192_000,
                targetVideoBitrate: 10_000_000,
                cqf: nil,
                useTwoPass: true,
                useMiniCAE: false,
                spatialAQ: .medium,
                lookAheadFrames: 0,
                maxGOPSeconds: 2.0,
                allowBFrames: true,
                fastStart: true,
                targetWidth: 1080,
                targetHeight: 1920,
                targetFPS: 30,
                toneMapHDRToSDR: true
            )

        case .webStreaming:
            return EncodingScenarioProfile(
                scenario: .webStreaming,
                summary: "Adaptive HLS / CMAF fMP4 streaming ladder — closed-GOP 4 s IDR-aligned 10-bit HEVC with Spatial AQ and AAC-Max.",
                recommendedContainer: "m3u8",
                codec: .hevc10,
                pixelFormat: .p010,
                hdrMode: .sdrBT709,
                audioCodec: .aacMax,
                audioBitrate: 128_000,
                targetVideoBitrate: 6_000_000,
                cqf: nil,
                useTwoPass: false,
                useMiniCAE: true,
                spatialAQ: .high,
                lookAheadFrames: 12,
                maxGOPSeconds: 4.0,
                allowBFrames: true,
                fastStart: true,
                targetWidth: nil,
                targetHeight: nil,
                targetFPS: nil,
                toneMapHDRToSDR: false
            )

        case .webCompat:
            return EncodingScenarioProfile(
                scenario: .webCompat,
                summary: "Universal web-compatible H.264 SDR MP4 — 2-pass NV12 BT.709 with moov-at-front fast-start and AAC-Max audio.",
                recommendedContainer: "mp4",
                codec: .h264,
                pixelFormat: .nv12Left,
                hdrMode: .sdrBT709,
                audioCodec: .aacMax,
                audioBitrate: 160_000,
                targetVideoBitrate: 5_000_000,
                cqf: nil,
                useTwoPass: true,
                useMiniCAE: false,
                spatialAQ: .medium,
                lookAheadFrames: 0,
                maxGOPSeconds: 2.0,
                allowBFrames: true,
                fastStart: true,
                targetWidth: nil,
                targetHeight: nil,
                targetFPS: nil,
                toneMapHDRToSDR: true
            )

        case .screenRecording:
            return EncodingScenarioProfile(
                scenario: .screenRecording,
                summary: "Crisp UI/code screen recording — 10-bit 4:4:4 HEVC (P410) with CQF quality control for razor-sharp subpixel text.",
                recommendedContainer: "mov",
                codec: .hevc44410,
                pixelFormat: .p410,
                hdrMode: .sdrBT709,
                audioCodec: .aacMax,
                audioBitrate: 192_000,
                targetVideoBitrate: 10_000_000,
                cqf: 0.72,
                useTwoPass: false,
                useMiniCAE: false,
                spatialAQ: .high,
                lookAheadFrames: 8,
                maxGOPSeconds: 4.0,
                allowBFrames: true,
                fastStart: true,
                targetWidth: nil,
                targetHeight: nil,
                targetFPS: nil,
                toneMapHDRToSDR: false
            )

        case .cinemaMaster:
            return EncodingScenarioProfile(
                scenario: .cinemaMaster,
                summary: "Broadcast & cinema edit master — Apple ProRes 422 HQ 10-bit 4:2:2 all-intra MOV with uncompressed 24-bit PCM audio.",
                recommendedContainer: "mov",
                codec: .proRes422HQ,
                pixelFormat: .p210,
                hdrMode: .sdrBT709,
                audioCodec: .pcm24,
                audioBitrate: 2_304_000,
                targetVideoBitrate: 220_000_000,
                cqf: nil,
                useTwoPass: false,
                useMiniCAE: false,
                spatialAQ: .off,
                lookAheadFrames: 0,
                maxGOPSeconds: 0.0,
                allowBFrames: false,
                fastStart: false,
                targetWidth: nil,
                targetHeight: nil,
                targetFPS: nil,
                toneMapHDRToSDR: false
            )

        case .cinemaVFX:
            return EncodingScenarioProfile(
                scenario: .cinemaVFX,
                summary: "VFX / DI mastering plate — Apple ProRes 4444 XQ 4:4:4:4 with alpha channel and uncompressed 24-bit PCM audio.",
                recommendedContainer: "mov",
                codec: .proRes4444XQ,
                pixelFormat: .bgra,
                hdrMode: .sdrBT709,
                audioCodec: .pcm24,
                audioBitrate: 2_304_000,
                targetVideoBitrate: 500_000_000,
                cqf: nil,
                useTwoPass: false,
                useMiniCAE: false,
                spatialAQ: .off,
                lookAheadFrames: 0,
                maxGOPSeconds: 0.0,
                allowBFrames: false,
                fastStart: false,
                targetWidth: nil,
                targetHeight: nil,
                targetFPS: nil,
                toneMapHDRToSDR: false
            )

        case .transparentVFX:
            return EncodingScenarioProfile(
                scenario: .transparentVFX,
                summary: "Lightweight alpha-channel motion graphics & web/NLE overlay — Apple HEVC with Alpha (muxa) MOV and ALAC lossless audio.",
                recommendedContainer: "mov",
                codec: .hevcAlpha,
                pixelFormat: .bgra,
                hdrMode: .sdrBT709,
                audioCodec: .alac,
                audioBitrate: 0,
                targetVideoBitrate: 25_000_000,
                cqf: 0.75,
                useTwoPass: false,
                useMiniCAE: false,
                spatialAQ: .high,
                lookAheadFrames: 8,
                maxGOPSeconds: 2.0,
                allowBFrames: true,
                fastStart: true,
                targetWidth: nil,
                targetHeight: nil,
                targetFPS: nil,
                toneMapHDRToSDR: false
            )

        case .hdrDolbyVision:
            return EncodingScenarioProfile(
                scenario: .hdrDolbyVision,
                summary: "Dolby Vision Profile 8.4 HDR — 10-bit HEVC BT.2020 HLG with live VTHDRPerFrameMetadataGenerationSession and Mini-CAE.",
                recommendedContainer: "mov",
                codec: .hevc10,
                pixelFormat: .p010,
                hdrMode: .dolbyVision84,
                audioCodec: .aacMax,
                audioBitrate: 256_000,
                targetVideoBitrate: 30_000_000,
                cqf: nil,
                useTwoPass: false,
                useMiniCAE: true,
                spatialAQ: .high,
                lookAheadFrames: 16,
                maxGOPSeconds: 2.0,
                allowBFrames: true,
                fastStart: true,
                targetWidth: nil,
                targetHeight: nil,
                targetFPS: nil,
                toneMapHDRToSDR: false
            )

        case .hdr10:
            return EncodingScenarioProfile(
                scenario: .hdr10,
                summary: "HDR10 static-metadata master — 10-bit HEVC BT.2020 SMPTE ST.2084 PQ with Mini-CAE, Spatial AQ, and fast-start MP4.",
                recommendedContainer: "mp4",
                codec: .hevc10,
                pixelFormat: .p010,
                hdrMode: .hdr10PQ,
                audioCodec: .aacMax,
                audioBitrate: 256_000,
                targetVideoBitrate: 25_000_000,
                cqf: nil,
                useTwoPass: false,
                useMiniCAE: true,
                spatialAQ: .high,
                lookAheadFrames: 16,
                maxGOPSeconds: 2.0,
                allowBFrames: true,
                fastStart: true,
                targetWidth: nil,
                targetHeight: nil,
                targetFPS: nil,
                toneMapHDRToSDR: false
            )

        case .spatialVisionOS:
            return EncodingScenarioProfile(
                scenario: .spatialVisionOS,
                summary: "Apple Vision Pro spatial video — MV-HEVC 10-bit HLG with Apple Positional Audio Codec (APAC) spatial audio.",
                recommendedContainer: "mov",
                codec: .hevc10,
                pixelFormat: .p010,
                hdrMode: .hlgBT2100,
                audioCodec: .apac,
                audioBitrate: 256_000,
                targetVideoBitrate: 35_000_000,
                cqf: 0.65,
                useTwoPass: false,
                useMiniCAE: false,
                spatialAQ: .high,
                lookAheadFrames: 8,
                maxGOPSeconds: 1.0,
                allowBFrames: true,
                fastStart: true,
                targetWidth: nil,
                targetHeight: nil,
                targetFPS: nil,
                toneMapHDRToSDR: false
            )

        case .archival:
            return EncodingScenarioProfile(
                scenario: .archival,
                summary: "Visually lossless long-term archive — 10-bit 4:2:2 HEVC (P210) at CQF 0.85 with ALAC bit-exact lossless audio.",
                recommendedContainer: "mov",
                codec: .hevc42210,
                pixelFormat: .p210,
                hdrMode: .sdrBT709,
                audioCodec: .alac,
                audioBitrate: 0,
                targetVideoBitrate: 50_000_000,
                cqf: 0.85,
                useTwoPass: false,
                useMiniCAE: false,
                spatialAQ: .high,
                lookAheadFrames: 16,
                maxGOPSeconds: 2.0,
                allowBFrames: true,
                fastStart: true,
                targetWidth: nil,
                targetHeight: nil,
                targetFPS: nil,
                toneMapHDRToSDR: false
            )

        case .liveLowLatency:
            return EncodingScenarioProfile(
                scenario: .liveLowLatency,
                summary: "Ultra-low-latency live broadcast — zero-lookahead closed-GOP H.264 without B-frames, 1 s IDR cadence, and 128 kbps AAC-Max.",
                recommendedContainer: "mp4",
                codec: .h264,
                pixelFormat: .nv12Left,
                hdrMode: .sdrBT709,
                audioCodec: .aacMax,
                audioBitrate: 128_000,
                targetVideoBitrate: 6_000_000,
                cqf: nil,
                useTwoPass: false,
                useMiniCAE: false,
                spatialAQ: .low,
                lookAheadFrames: 0,
                maxGOPSeconds: 1.0,
                allowBFrames: false,
                fastStart: true,
                targetWidth: nil,
                targetHeight: nil,
                targetFPS: nil,
                toneMapHDRToSDR: true
            )

        case .podcastVideo:
            return EncodingScenarioProfile(
                scenario: .podcastVideo,
                summary: "Long-form talking-head / slide podcast video — 10-bit HEVC with Mini-CAE static-hold savings, 4 s GOP, and 160 kbps AAC-Max.",
                recommendedContainer: "mp4",
                codec: .hevc10,
                pixelFormat: .p010,
                hdrMode: .sdrBT709,
                audioCodec: .aacMax,
                audioBitrate: 160_000,
                targetVideoBitrate: 3_500_000,
                cqf: nil,
                useTwoPass: false,
                useMiniCAE: true,
                spatialAQ: .high,
                lookAheadFrames: 16,
                maxGOPSeconds: 4.0,
                allowBFrames: true,
                fastStart: true,
                targetWidth: 1920,
                targetHeight: 1080,
                targetFPS: 30,
                toneMapHDRToSDR: false
            )

        case .webpClip:
            return EncodingScenarioProfile(
                scenario: .webpClip,
                summary: "Direct native animated WebP clip — lossless VP8L RIFF VP8X+ANIM+ANMF at 12 fps up to 640 px wide with SDR tone-mapping.",
                recommendedContainer: "webp",
                codec: .hevc,
                pixelFormat: .bgra,
                hdrMode: .sdrBT709,
                audioCodec: .aacMax,
                audioBitrate: 0,
                targetVideoBitrate: 0,
                cqf: nil,
                useTwoPass: false,
                useMiniCAE: false,
                spatialAQ: .off,
                lookAheadFrames: 0,
                maxGOPSeconds: 0.0,
                allowBFrames: false,
                fastStart: false,
                targetWidth: 640,
                targetHeight: nil,
                targetFPS: 12,
                toneMapHDRToSDR: true
            )

        case .gifClip:
            return EncodingScenarioProfile(
                scenario: .gifClip,
                summary: "Direct native animated GIF clip — ImageIO CGImageDestination at 12 fps up to 640 px wide with SDR tone-mapping.",
                recommendedContainer: "gif",
                codec: .hevc,
                pixelFormat: .bgra,
                hdrMode: .sdrBT709,
                audioCodec: .aacMax,
                audioBitrate: 0,
                targetVideoBitrate: 0,
                cqf: nil,
                useTwoPass: false,
                useMiniCAE: false,
                spatialAQ: .off,
                lookAheadFrames: 0,
                maxGOPSeconds: 0.0,
                allowBFrames: false,
                fastStart: false,
                targetWidth: 640,
                targetHeight: nil,
                targetFPS: 12,
                toneMapHDRToSDR: true
            )
        }
    }
}

// MARK: - EncodingScenarioProfile

/// Complete, serializable hardware encoding specification for an `EncodingScenario`.
public struct EncodingScenarioProfile: Codable, Sendable, Equatable {
    public let scenario: EncodingScenario
    public let summary: String
    public let recommendedContainer: String
    public let codec: VideoCodec
    public let pixelFormat: PixelFormat
    public let hdrMode: HDRMode
    public let audioCodec: ProAudioCodec
    public let audioBitrate: Int
    public let targetVideoBitrate: Int
    public let cqf: Double?
    public let useTwoPass: Bool
    public let useMiniCAE: Bool
    public let spatialAQ: SpatialAQLevel
    public let lookAheadFrames: Int
    public let maxGOPSeconds: Double
    public let allowBFrames: Bool
    public let fastStart: Bool
    public let targetWidth: Int?
    public let targetHeight: Int?
    public let targetFPS: Int?
    public let toneMapHDRToSDR: Bool

    public init(
        scenario: EncodingScenario,
        summary: String,
        recommendedContainer: String,
        codec: VideoCodec,
        pixelFormat: PixelFormat,
        hdrMode: HDRMode,
        audioCodec: ProAudioCodec,
        audioBitrate: Int,
        targetVideoBitrate: Int,
        cqf: Double?,
        useTwoPass: Bool,
        useMiniCAE: Bool,
        spatialAQ: SpatialAQLevel,
        lookAheadFrames: Int,
        maxGOPSeconds: Double,
        allowBFrames: Bool,
        fastStart: Bool,
        targetWidth: Int?,
        targetHeight: Int?,
        targetFPS: Int?,
        toneMapHDRToSDR: Bool
    ) {
        self.scenario = scenario
        self.summary = summary
        self.recommendedContainer = recommendedContainer
        self.codec = codec
        self.pixelFormat = pixelFormat
        self.hdrMode = hdrMode
        self.audioCodec = audioCodec
        self.audioBitrate = audioBitrate
        self.targetVideoBitrate = targetVideoBitrate
        self.cqf = cqf
        self.useTwoPass = useTwoPass
        self.useMiniCAE = useMiniCAE
        self.spatialAQ = spatialAQ
        self.lookAheadFrames = lookAheadFrames
        self.maxGOPSeconds = maxGOPSeconds
        self.allowBFrames = allowBFrames
        self.fastStart = fastStart
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.targetFPS = targetFPS
        self.toneMapHDRToSDR = toneMapHDRToSDR
    }

    /// Converts this scenario profile into a `SupremacyTranscodeConfig` for `VTMultiPassEncoder` / `MultiEngineChunkEncoder`.
    public func toSupremacyConfig(overwrite: Bool = false) -> SupremacyTranscodeConfig {
        let mode: SupremacyEncodeMode
        if useMiniCAE {
            mode = .miniCAE
        } else if useTwoPass {
            mode = .twoPass
        } else if cqf != nil {
            mode = .cqf
        } else if !allowBFrames && lookAheadFrames == 0 {
            mode = .fast
        } else {
            mode = .highQuality
        }
        return SupremacyTranscodeConfig(
            codec: codec,
            mode: mode,
            bitrate: max(100_000, targetVideoBitrate),
            maxBitrate: nil,
            vbvBufferSeconds: max(1.0, maxGOPSeconds > 0 ? maxGOPSeconds * 2.0 : 4.0),
            cqf: cqf ?? 0.55,
            spatialAdaptiveQP: spatialAQ.isEnabled,
            lookAheadFrames: useTwoPass ? 0 : lookAheadFrames,
            colorMastering: hdrMode,
            parallelEngines: nil,
            audioCodec: audioCodec,
            audioBitrate: audioBitrate > 0 ? audioBitrate : nil,
            overwrite: overwrite
        )
    }

    /// Converts this scenario profile into an `EncoderProfile` for `AVAssetWriterSink`.
    public func toEncoderProfile() -> EncoderProfile {
        EncoderProfile(
            allowFrameReordering: allowBFrames,
            allowOpenGOP: allowBFrames && scenario != .webStreaming && scenario != .liveLowLatency,
            suggestedLookAheadFrameCount: lookAheadFrames > 0 ? lookAheadFrames : nil,
            maxFrameDelayCount: nil,
            prioritizeEncodingSpeed: scenario == .liveLowLatency,
            maxKeyFrameInterval: nil,
            maxKeyFrameIntervalDuration: maxGOPSeconds > 0 ? maxGOPSeconds : nil,
            poolAllocationThreshold: scenario == .liveLowLatency ? 2 : nil,
            expectedSourceFrameRate: targetFPS,
            spatialAdaptiveQP: spatialAQ.isEnabled ? true : false,
            perceptualQualityOptimization: spatialAQ.isEnabled,
            constantQualityFactor: cqf,
            constrainedVBR: nil,
            colorMastering: hdrMode,
            profileLevelOverride: codec.defaultProfileLevel
        )
    }
}
