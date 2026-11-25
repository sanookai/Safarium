import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

// MARK: - A. Native HLS / CMAF ABR Packager (100% Apple Native, 0% FFmpeg)

/// Output segment container format for `HLSPackager`.
public enum HLSFormat: String, Codable, Sendable, CaseIterable {
    /// Modern RFC 8216 HLS v7 fragmented MP4 / CMAF (`init.mp4` + `seg_XXXX.m4s`) via native `AVAssetWriter` `.mpeg4AppleHLS`.
    case fmp4CMAF = "fmp4-cmaf"
    /// Legacy HLS v3 MPEG-2 Transport Stream (`seg_XXXX.ts`) via native `VTCompressionSession` + pure-Swift 188-byte TS muxer.
    case mpegTS = "mpeg-ts"
}

/// Single ABR bitrate rung in an HLS rendition ladder.
public struct HLSRung: Codable, Sendable, Equatable {
    public let name: String
    public let width: Int
    public let height: Int
    public let bitrate: Int
    public let fps: Double
    public let codec: VideoCodec
    public let audioBitrate: Int

    public init(
        name: String,
        width: Int,
        height: Int,
        bitrate: Int,
        fps: Double = 30.0,
        codec: VideoCodec = .hevc10,
        audioBitrate: Int = 128_000
    ) {
        self.name = name
        self.width = max(16, (width / 2) * 2)
        self.height = max(16, (height / 2) * 2)
        self.bitrate = max(100_000, bitrate)
        self.fps = max(1.0, fps)
        self.codec = codec
        self.audioBitrate = max(32_000, audioBitrate)
    }

    /// Standard 4-rung ABR streaming ladder (360p / 720p / 1080p / 2160p).
    public static func defaultLadder(codec: VideoCodec = .hevc10, fps: Double = 30.0) -> [HLSRung] {
        [
            HLSRung(name: "360p", width: 640, height: 360, bitrate: 900_000, fps: fps, codec: codec, audioBitrate: 96_000),
            HLSRung(name: "720p", width: 1280, height: 720, bitrate: 3_000_000, fps: fps, codec: codec, audioBitrate: 128_000),
            HLSRung(name: "1080p", width: 1920, height: 1080, bitrate: 6_000_000, fps: fps, codec: codec, audioBitrate: 160_000),
            HLSRung(name: "2160p", width: 3840, height: 2160, bitrate: 18_000_000, fps: fps, codec: codec, audioBitrate: 192_000),
        ]
    }
}

/// Configuration for `HLSPackager.package`.
public struct HLSPackageOptions: Sendable {
    public var rungs: [HLSRung]
    public var segmentDurationSeconds: Double
    public var format: HLSFormat
    public var codec: VideoCodec
    public var subtitleVTTPath: URL?
    public var subtitleLanguage: String
    public var subtitleName: String

    public init(
        rungs: [HLSRung] = HLSRung.defaultLadder(codec: .hevc10),
        segmentDurationSeconds: Double = 4.0,
        format: HLSFormat = .fmp4CMAF,
        codec: VideoCodec = .hevc10,
        subtitleVTTPath: URL? = nil,
        subtitleLanguage: String = "en",
        subtitleName: String = "English"
    ) {
        self.rungs = rungs
        self.segmentDurationSeconds = max(0.5, segmentDurationSeconds)
        self.format = format
        self.codec = codec
        self.subtitleVTTPath = subtitleVTTPath
        self.subtitleLanguage = subtitleLanguage
        self.subtitleName = subtitleName
    }
}

/// Output summary for one packaged ABR variant rendition.
public struct HLSVariantResult: Codable, Sendable {
    public let name: String
    public let width: Int
    public let height: Int
    public let fps: Double
    public let bitrate: Int
    public let peakBandwidth: Int
    public let averageBitrate: Int
    public let codecs: String
    public let playlistPath: String
    public let initSegmentPath: String?
    public let segmentCount: Int
    public let segmentDurations: [Double]
    public let totalBytes: Int64
}

/// Output summary for an entire packaged HLS ABR stream.
public struct HLSPackageResult: Codable, Sendable {
    public let masterPlaylistPath: String
    public let variants: [HLSVariantResult]
    public let subtitlePlaylistPath: String?
    public let sharedIDRBoundaries: [Double]
    public let totalBytes: Int64
    public let elapsedMs: Double
    public let format: HLSFormat
}

/// Native Apple Silicon HLS / CMAF ABR packager (0% FFmpeg).
public enum HLSPackager {
    /// Computes deterministic shared-IDR segment boundary timestamps (`0, segDur, 2*segDur, ...`)
    /// so every ABR rung cuts segments at identical presentation timestamps.
    public static func computeSharedIDRBoundaries(
        totalDurationSeconds: Double,
        segmentDurationSeconds: Double
    ) -> [Double] {
        let segDur = max(0.5, segmentDurationSeconds)
        let totalDur = max(0.0, totalDurationSeconds)
        var boundaries: [Double] = [0.0]
        var nextBoundary = segDur
        // Only add a boundary if at least 0.1s of media remains after it to avoid tiny trailing slivers.
        while nextBoundary + 0.10 < totalDur {
            boundaries.append((nextBoundary * 1000.0).rounded() / 1000.0)
            nextBoundary += segDur
        }
        return boundaries
    }

    /// Packages `inputURL` into a complete RFC 8216 multi-rung HLS stream inside `outputDirectory`.
    public static func package(
        inputURL: URL,
        outputDirectory: URL,
        options: HLSPackageOptions = HLSPackageOptions()
    ) async throws -> HLSPackageResult {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(inputURL)
        if let vtt = options.subtitleVTTPath {
            try SafeFilePublisher.assertRegularReadableFile(vtt)
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let asset = AVURLAsset(url: inputURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        ])
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw SafariumError.invalidState("no video track in \(inputURL.lastPathComponent)")
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let sourceWidth = max(16, (Int(abs(transformedRect.width).rounded()) / 2) * 2)
        let sourceHeight = max(16, (Int(abs(transformedRect.height).rounded()) / 2) * 2)
        let nominalFPS = Double(try await videoTrack.load(.nominalFrameRate))
        let sourceFPS = (nominalFPS.isFinite && nominalFPS > 0.1) ? nominalFPS : 30.0
        let durationCM = try await asset.load(.duration)
        let totalDurationSec = (durationCM.isNumeric && durationCM.seconds.isFinite && durationCM.seconds > 0)
            ? durationCM.seconds
            : 1.0

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let hasAudio = !audioTracks.isEmpty

        // Compute exact shared-IDR boundary timestamps once for all rungs
        let sharedIDRBoundaries = computeSharedIDRBoundaries(
            totalDurationSeconds: totalDurationSec,
            segmentDurationSeconds: options.segmentDurationSeconds
        )

        // Filter rungs: skip rungs taller than source unless only 1 rung was requested.
        let activeRungs: [HLSRung]
        if options.rungs.isEmpty {
            activeRungs = [
                HLSRung(
                    name: "\(sourceHeight)p",
                    width: sourceWidth,
                    height: sourceHeight,
                    bitrate: 4_000_000,
                    fps: sourceFPS,
                    codec: options.codec,
                    audioBitrate: 128_000
                ),
            ]
        } else if options.rungs.count == 1 {
            activeRungs = options.rungs
        } else {
            let filtered = options.rungs.filter { $0.height <= sourceHeight }
            if !filtered.isEmpty {
                activeRungs = filtered
            } else if let smallest = options.rungs.min(by: { $0.height < $1.height }) {
                activeRungs = [smallest]
            } else {
                activeRungs = [options.rungs[0]]
            }
        }

        // Encode each rung sequentially (each rung already saturates hardware encode + scale).
        var variants: [HLSVariantResult] = []
        variants.reserveCapacity(activeRungs.count)
        var grandTotalBytes: Int64 = 0

        for (idx, rung) in activeRungs.enumerated() {
            let safeName = sanitizePathComponent(rung.name.isEmpty ? "v\(idx)" : rung.name)
            let variantDir = outputDirectory.appendingPathComponent(safeName, isDirectory: true)
            try FileManager.default.createDirectory(at: variantDir, withIntermediateDirectories: true)

            let effectiveFPS = min(sourceFPS, rung.fps)
            let variant: HLSVariantResult
            switch options.format {
            case .fmp4CMAF:
                variant = try await encodeCMAFVariant(
                    asset: asset,
                    videoTrack: videoTrack,
                    audioTrack: audioTracks.first,
                    rung: rung,
                    variantName: safeName,
                    variantDir: variantDir,
                    effectiveFPS: effectiveFPS,
                    segmentDuration: options.segmentDurationSeconds,
                    sharedIDRBoundaries: sharedIDRBoundaries
                )
            case .mpegTS:
                variant = try await encodeMPEGTSVariant(
                    asset: asset,
                    videoTrack: videoTrack,
                    rung: rung,
                    variantName: safeName,
                    variantDir: variantDir,
                    effectiveFPS: effectiveFPS,
                    segmentDuration: options.segmentDurationSeconds,
                    sharedIDRBoundaries: sharedIDRBoundaries
                )
            }
            variants.append(variant)
            grandTotalBytes += variant.totalBytes
        }

        // Optional WebVTT subtitle rendition
        var subtitlePlaylistPath: String? = nil
        if let vttSource = options.subtitleVTTPath {
            let subDir = outputDirectory.appendingPathComponent("subtitles", isDirectory: true)
            try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)
            let vttDest = subDir.appendingPathComponent("subtitles.vtt")
            if FileManager.default.fileExists(atPath: vttDest.path) {
                try FileManager.default.removeItem(at: vttDest)
            }
            try FileManager.default.copyItem(at: vttSource, to: vttDest)

            let targetDur = max(1, Int(ceil(totalDurationSec)))
            let subPlaylistText = [
                "#EXTM3U",
                "#EXT-X-VERSION:\(options.format == .fmp4CMAF ? 7 : 3)",
                "#EXT-X-TARGETDURATION:\(targetDur)",
                "#EXT-X-MEDIA-SEQUENCE:0",
                "#EXT-X-PLAYLIST-TYPE:VOD",
                String(format: "#EXTINF:%.3f,", totalDurationSec),
                "subtitles.vtt",
                "#EXT-X-ENDLIST",
                "",
            ].joined(separator: "\n")
            let subPlaylistURL = subDir.appendingPathComponent("playlist.m3u8")
            try Data(subPlaylistText.utf8).write(to: subPlaylistURL, options: .atomic)
            subtitlePlaylistPath = subPlaylistURL.path
            grandTotalBytes += fileSize(vttDest) + fileSize(subPlaylistURL)
        }

        // Write RFC 8216 master.m3u8 sorted by measured peak bandwidth ascending
        let sortedVariants = variants.sorted { $0.peakBandwidth < $1.peakBandwidth }
        var masterLines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:\(options.format == .fmp4CMAF ? 7 : 3)",
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]
        if subtitlePlaylistPath != nil {
            let escapedLang = options.subtitleLanguage.replacingOccurrences(of: "\"", with: "")
            let escapedName = options.subtitleName.replacingOccurrences(of: "\"", with: "")
            masterLines.append(
                "#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(escapedName)\",DEFAULT=YES,AUTOSELECT=YES,LANGUAGE=\"\(escapedLang)\",URI=\"subtitles/playlist.m3u8\""
            )
        }
        for v in sortedVariants {
            let peakBW = max(v.peakBandwidth, v.averageBitrate, 1_000)
            let avgBW = min(peakBW, max(1_000, v.averageBitrate))
            var attrs = "BANDWIDTH=\(peakBW),AVERAGE-BANDWIDTH=\(avgBW),RESOLUTION=\(v.width)x\(v.height),FRAME-RATE=\(String(format: "%.3f", v.fps)),CODECS=\"\(v.codecs)\""
            if subtitlePlaylistPath != nil {
                attrs += ",SUBTITLES=\"subs\""
            }
            masterLines.append("#EXT-X-STREAM-INF:\(attrs)")
            masterLines.append("\(v.name)/playlist.m3u8")
        }
        masterLines.append("")

        let masterURL = outputDirectory.appendingPathComponent("master.m3u8")
        try Data(masterLines.joined(separator: "\n").utf8).write(to: masterURL, options: .atomic)
        grandTotalBytes += fileSize(masterURL)

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0
        _ = hasAudio
        return HLSPackageResult(
            masterPlaylistPath: masterURL.path,
            variants: sortedVariants,
            subtitlePlaylistPath: subtitlePlaylistPath,
            sharedIDRBoundaries: sharedIDRBoundaries,
            totalBytes: grandTotalBytes,
            elapsedMs: (elapsedMs * 100.0).rounded() / 100.0,
            format: options.format
        )
    }

    private static func measureVariantBandwidths(
        segments: [RecordedSegment],
        fallbackBitrate: Int
    ) -> (peakBandwidth: Int, averageBandwidth: Int) {
        let totalDur = segments.reduce(0.0) { $0 + $1.durationSeconds }
        let totalBytes = segments.reduce(Int64(0)) { $0 + $1.bytes }
        let avgBW: Int
        if totalDur > 0.05 && totalBytes > 0 {
            avgBW = max(1_000, Int((Double(totalBytes) * 8.0 / totalDur).rounded()))
        } else {
            avgBW = max(1_000, fallbackBitrate)
        }
        var maxSegBitrate = Double(avgBW)
        for seg in segments {
            if seg.durationSeconds > 0.05 && seg.bytes > 0 {
                let segBW = (Double(seg.bytes) * 8.0) / seg.durationSeconds
                if segBW > maxSegBitrate {
                    maxSegBitrate = segBW
                }
            }
        }
        let peakBW = max(avgBW, Int(ceil(maxSegBitrate)))
        return (peakBW, avgBW)
    }

    // MARK: - CMAF fMP4 Variant Encoder (Native AVAssetWriter .mpeg4AppleHLS)

    private struct RecordedSegment: Sendable {
        let filename: String
        let durationSeconds: Double
        let bytes: Int64
    }

    private final class CMAFSegmentDelegate: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
        private let variantDir: URL
        private let fallbackSegmentDuration: Double
        private let lock = NSLock()
        private var initWritten = false
        private var initBytes: Int64 = 0
        private var segments: [RecordedSegment] = []
        private var writeError: Error?

        init(variantDir: URL, fallbackSegmentDuration: Double) {
            self.variantDir = variantDir
            self.fallbackSegmentDuration = fallbackSegmentDuration
            super.init()
        }

        func assetWriter(
            _ writer: AVAssetWriter,
            didOutputSegmentData segmentData: Data,
            segmentType: AVAssetSegmentType,
            segmentReport: AVAssetSegmentReport?
        ) {
            lock.lock()
            defer { lock.unlock() }
            if writeError != nil { return }

            do {
                if segmentType == .initialization {
                    let initURL = variantDir.appendingPathComponent("init.mp4")
                    try segmentData.write(to: initURL, options: .atomic)
                    initWritten = true
                    initBytes = Int64(segmentData.count)
                } else if segmentType == .separable {
                    let idx = segments.count
                    let name = String(format: "seg_%04d.m4s", idx)
                    let segURL = variantDir.appendingPathComponent(name)
                    try segmentData.write(to: segURL, options: .atomic)

                    var dur = fallbackSegmentDuration
                    if let report = segmentReport {
                        if let videoRep = report.trackReports.first(where: { $0.mediaType == .video }),
                           videoRep.duration.isNumeric,
                           videoRep.duration.seconds.isFinite,
                           videoRep.duration.seconds > 0.01 {
                            dur = videoRep.duration.seconds
                        } else if let anyRep = report.trackReports.first,
                                  anyRep.duration.isNumeric,
                                  anyRep.duration.seconds.isFinite,
                                  anyRep.duration.seconds > 0.01 {
                            dur = anyRep.duration.seconds
                        }
                    }
                    segments.append(RecordedSegment(filename: name, durationSeconds: dur, bytes: Int64(segmentData.count)))
                }
            } catch {
                writeError = error
            }
        }

        func snapshot() -> (initWritten: Bool, initBytes: Int64, segments: [RecordedSegment], error: Error?) {
            lock.lock()
            defer { lock.unlock() }
            return (initWritten, initBytes, segments, writeError)
        }
    }

    private static func encodeCMAFVariant(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        audioTrack: AVAssetTrack?,
        rung: HLSRung,
        variantName: String,
        variantDir: URL,
        effectiveFPS: Double,
        segmentDuration: Double,
        sharedIDRBoundaries: [Double]
    ) async throws -> HLSVariantResult {
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: segmentDuration, preferredTimescale: 600)
        writer.initialSegmentStartTime = .zero

        let delegate = CMAFSegmentDelegate(variantDir: variantDir, fallbackSegmentDuration: segmentDuration)
        writer.delegate = delegate

        // Map ProRes / alpha codecs gracefully to HEVC for CMAF HLS delivery
        let hlsCodec: VideoCodec = (rung.codec == .h264) ? .h264 : (rung.codec.is10Bit ? .hevc10 : .hevc)
        let keyframeInterval = max(1, Int((effectiveFPS * segmentDuration).rounded()))

        var compProps: [String: Any] = [
            AVVideoAverageBitRateKey: rung.bitrate,
            AVVideoMaxKeyFrameIntervalKey: keyframeInterval,
            AVVideoMaxKeyFrameIntervalDurationKey: segmentDuration,
            AVVideoExpectedSourceFrameRateKey: effectiveFPS,
            AVVideoAllowFrameReorderingKey: true,
            kVTCompressionPropertyKey_AllowOpenGOP as String: false,
        ]
        if let profileLevel = hlsCodec.defaultProfileLevel {
            compProps[AVVideoProfileLevelKey] = profileLevel
        } else if hlsCodec == .h264 {
            compProps[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: hlsCodec.avCodec,
            AVVideoWidthKey: rung.width,
            AVVideoHeightKey: rung.height,
            AVVideoColorPropertiesKey: ColorMasteringProfile.sdrBT709.avColorProperties,
            AVVideoCompressionPropertiesKey: compProps,
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw SafariumError.encode("AVAssetWriter (.mpeg4AppleHLS) cannot add video input for rung \(variantName)")
        }
        writer.add(videoInput)

        let writerPixelFormat: OSType = hlsCodec.is10Bit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: writerPixelFormat,
            kCVPixelBufferWidthKey as String: rung.width,
            kCVPixelBufferHeightKey as String: rung.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: adaptorAttrs
        )

        // Optional audio input (AAC-Max muxed into CMAF segments)
        var audioInput: AVAssetWriterInput?
        var audioReaderOutput: AVAssetReaderTrackOutput?
        var hasMuxedAudio = false

        let reader = try AVAssetReader(asset: asset)
        let readPixelFormat: OSType = hlsCodec.is10Bit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: readPixelFormat,
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw SafariumError.encode("AVAssetReader cannot read video track for HLS rung \(variantName)")
        }
        reader.add(videoOutput)

        if let audioTrack {
            let descs = (try? await audioTrack.load(.formatDescriptions)) ?? []
            let asbd = descs.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let sampleRate = Int((asbd?.mSampleRate ?? 48_000).rounded())
            let channels = max(1, min(2, Int(asbd?.mChannelsPerFrame ?? 2)))
            let aSettings = ProAudioEncoder.outputSettings(
                codec: .aacMax,
                sampleRate: sampleRate,
                channels: channels,
                bitrate: rung.audioBitrate
            )
            if writer.canApply(outputSettings: aSettings, forMediaType: .audio) {
                let pcmSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: Double(sampleRate),
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
                let aOut = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
                aOut.alwaysCopiesSampleData = false
                let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
                aIn.expectsMediaDataInRealTime = false
                if reader.canAdd(aOut) && writer.canAdd(aIn) {
                    reader.add(aOut)
                    writer.add(aIn)
                    audioReaderOutput = aOut
                    audioInput = aIn
                    hasMuxedAudio = true
                }
            }
        }

        // Hardware pixel transfer scaler (with CIContext fallback)
        var transferSession: VTPixelTransferSession?
        if VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transferSession) == noErr,
           let ts = transferSession {
            _ = VTSessionSetProperty(ts, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)
        }
        defer {
            if let ts = transferSession {
                VTPixelTransferSessionInvalidate(ts)
            }
        }
        let fallbackCIContext = CIContext(options: [.cacheIntermediates: false])

        guard reader.startReading() else {
            throw SafariumError.encode("AVAssetReader failed to start: \(reader.error?.localizedDescription ?? "?")")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw SafariumError.encode("AVAssetWriter (.mpeg4AppleHLS) startWriting failed: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            reader.cancelReading()
            writer.cancelWriting()
            throw SafariumError.encode("AVAssetWriterInputPixelBufferAdaptor has no pixelBufferPool")
        }

        // Interleaved video + audio pumping normalized to t = 0
        var nextVideoSB: CMSampleBuffer? = autoreleasepool { videoOutput.copyNextSampleBuffer() }
        var nextAudioSB: CMSampleBuffer? = audioReaderOutput.flatMap { out in
            autoreleasepool { out.copyNextSampleBuffer() }
        }
        let firstVideoPTS = nextVideoSB.map { CMSampleBufferGetPresentationTimeStamp($0) } ?? .zero
        // Anchor all rungs to firstVideoPTS so frame 0 lands at t = 0.000s identically across every rung.
        let basePTS = firstVideoPTS

        let minFrameStep = 1.0 / effectiveFPS
        let halfFrameTol = minFrameStep * 0.45
        var nextBoundaryIdx = 0
        var lastAppendedVideoSec = -Double.greatestFiniteMagnitude
        var encodedFrames = 0
        var videoMarkedFinished = false
        var audioMarkedFinished = (audioInput == nil)

        while nextVideoSB != nil || nextAudioSB != nil {
            if nextVideoSB == nil && !videoMarkedFinished {
                videoInput.markAsFinished()
                videoMarkedFinished = true
            }
            if nextAudioSB == nil && !audioMarkedFinished {
                audioInput?.markAsFinished()
                audioMarkedFinished = true
            }

            let vReady = (nextVideoSB != nil) && videoInput.isReadyForMoreMediaData
            let aReady = (nextAudioSB != nil) && (audioInput?.isReadyForMoreMediaData ?? false)

            if !vReady && !aReady {
                if writer.status != .writing {
                    reader.cancelReading()
                    throw SafariumError.encode("HLS writer failed: \(writer.error?.localizedDescription ?? "?")")
                }
                try await Task.sleep(nanoseconds: 500_000)
                continue
            }

            let pickVideo: Bool
            if vReady && aReady, let vsb = nextVideoSB, let asb = nextAudioSB {
                let vPTS = CMSampleBufferGetPresentationTimeStamp(vsb)
                let aPTS = CMSampleBufferGetPresentationTimeStamp(asb)
                pickVideo = CMTimeCompare(vPTS, aPTS) <= 0
            } else {
                pickVideo = vReady
            }

            if pickVideo, let vsb = nextVideoSB {
                nextVideoSB = autoreleasepool { videoOutput.copyNextSampleBuffer() }
                guard let srcPB = CMSampleBufferGetImageBuffer(vsb) else { continue }
                let rawPTS = CMSampleBufferGetPresentationTimeStamp(vsb)
                let normPTS = CMTimeMaximum(.zero, CMTimeSubtract(rawPTS, basePTS))
                let ptsSec = normPTS.seconds

                // Check whether this frame hits a shared IDR segment boundary; boundary frames are never skipped.
                var hitsSharedBoundary = false
                while nextBoundaryIdx < sharedIDRBoundaries.count &&
                      ptsSec >= (sharedIDRBoundaries[nextBoundaryIdx] - halfFrameTol) {
                    hitsSharedBoundary = true
                    nextBoundaryIdx += 1
                }

                // Optional FPS decimation when rung.fps < sourceFPS (never drop shared IDR boundary frames)
                if !hitsSharedBoundary && encodedFrames > 0 && (ptsSec - lastAppendedVideoSec) < (minFrameStep * 0.90) {
                    continue
                }

                var dstPBOpt: CVPixelBuffer?
                let poolSt = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dstPBOpt)
                guard poolSt == kCVReturnSuccess, let dstPB = dstPBOpt else {
                    reader.cancelReading()
                    throw SafariumError.encode("HLS CVPixelBufferPoolCreatePixelBuffer failed (\(poolSt))")
                }

                try scalePixelBuffer(
                    srcPB,
                    into: dstPB,
                    transferSession: transferSession,
                    ciContext: fallbackCIContext
                )
                ColorMasteringProfile.sdrBT709.tagPixelBuffer(dstPB)

                guard adaptor.append(dstPB, withPresentationTime: normPTS) else {
                    reader.cancelReading()
                    throw SafariumError.encode("HLS adaptor.append failed: \(writer.error?.localizedDescription ?? "?")")
                }
                lastAppendedVideoSec = ptsSec
                encodedFrames += 1
            } else if let asb = nextAudioSB, let aIn = audioInput, let aOut = audioReaderOutput {
                nextAudioSB = autoreleasepool { aOut.copyNextSampleBuffer() }
                if let shifted = retimedSampleBuffer(asb, subtract: basePTS) {
                    _ = aIn.append(shifted)
                } else {
                    _ = aIn.append(asb)
                }
            }
        }

        if !videoMarkedFinished { videoInput.markAsFinished() }
        if !audioMarkedFinished { audioInput?.markAsFinished() }
        reader.cancelReading()

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw SafariumError.encode("AVAssetWriter (.mpeg4AppleHLS) finishWriting failed: \(writer.error?.localizedDescription ?? "?")")
        }

        let snap = delegate.snapshot()
        if let err = snap.error {
            throw SafariumError.encode("HLS segment write error: \(err.localizedDescription)")
        }
        guard snap.initWritten, !snap.segments.isEmpty else {
            throw SafariumError.encode("HLS CMAF produced no initialization or media segments for rung \(variantName)")
        }

        let maxSegDur = snap.segments.map(\.durationSeconds).max() ?? segmentDuration
        let targetDuration = max(1, Int(ceil(maxSegDur)))
        let segBytes = snap.segments.reduce(Int64(0)) { $0 + $1.bytes }

        var m3u8Lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MAP:URI=\"init.mp4\"",
        ]
        for seg in snap.segments {
            m3u8Lines.append(String(format: "#EXTINF:%.3f,", seg.durationSeconds))
            m3u8Lines.append(seg.filename)
        }
        m3u8Lines.append("#EXT-X-ENDLIST")
        m3u8Lines.append("")

        let playlistURL = variantDir.appendingPathComponent("playlist.m3u8")
        try Data(m3u8Lines.joined(separator: "\n").utf8).write(to: playlistURL, options: .atomic)

        let totalVariantBytes = snap.initBytes + segBytes + fileSize(playlistURL)
        let measured = measureVariantBandwidths(
            segments: snap.segments,
            fallbackBitrate: rung.bitrate + (hasMuxedAudio ? rung.audioBitrate : 0)
        )
        let codecsStr = rfc6381CodecsString(videoCodec: hlsCodec, width: rung.width, height: rung.height, hasAudio: hasMuxedAudio)

        return HLSVariantResult(
            name: variantName,
            width: rung.width,
            height: rung.height,
            fps: effectiveFPS,
            bitrate: measured.peakBandwidth,
            peakBandwidth: measured.peakBandwidth,
            averageBitrate: measured.averageBandwidth,
            codecs: codecsStr,
            playlistPath: playlistURL.path,
            initSegmentPath: variantDir.appendingPathComponent("init.mp4").path,
            segmentCount: snap.segments.count,
            segmentDurations: snap.segments.map(\.durationSeconds),
            totalBytes: totalVariantBytes
        )
    }

    // MARK: - MPEG-TS Variant Encoder (Native VTCompressionSession + Pure-Swift 188-byte TS Muxer)

    private static func encodeMPEGTSVariant(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        rung: HLSRung,
        variantName: String,
        variantDir: URL,
        effectiveFPS: Double,
        segmentDuration: Double,
        sharedIDRBoundaries: [Double]
    ) async throws -> HLSVariantResult {
        let tsCodec: VideoCodec = (rung.codec == .h264) ? .h264 : .hevc
        let cmCodec: CMVideoCodecType = (tsCodec == .h264) ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC

        var sessionOpt: VTCompressionSession?
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]
        let st = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(rung.width),
            height: Int32(rung.height),
            codecType: cmCodec,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &sessionOpt
        )
        guard st == noErr, let session = sessionOpt else {
            throw SafariumError.encode("VTCompressionSessionCreate for MPEG-TS failed (\(st))")
        }
        defer { VTCompressionSessionInvalidate(session) }

        let keyframeInterval = max(1, Int((effectiveFPS * segmentDuration).rounded()))
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: rung.bitrate))
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: effectiveFPS))
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowOpenGOP, value: kCFBooleanFalse)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: keyframeInterval))
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: segmentDuration))
        VTCompressionSessionPrepareToEncodeFrames(session)

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw SafariumError.encode("AVAssetReader cannot read video for MPEG-TS HLS")
        }
        reader.add(videoOutput)
        guard reader.startReading() else {
            throw SafariumError.encode("AVAssetReader failed to start for MPEG-TS HLS")
        }

        let poolAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: rung.width,
            kCVPixelBufferHeightKey as String: rung.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var poolOpt: CVPixelBufferPool?
        let poolSt = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, poolAttrs as CFDictionary, &poolOpt)
        guard poolSt == kCVReturnSuccess, let pool = poolOpt else {
            reader.cancelReading()
            throw SafariumError.encode("CVPixelBufferPoolCreate failed for MPEG-TS (\(poolSt))")
        }

        var transferSession: VTPixelTransferSession?
        _ = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &transferSession)
        defer {
            if let ts = transferSession { VTPixelTransferSessionInvalidate(ts) }
        }
        let fallbackCI = CIContext(options: [.cacheIntermediates: false])

        final class Collector: @unchecked Sendable {
            let lock = NSLock()
            var samples: [CMSampleBuffer] = []
            var err: OSStatus = noErr
            func add(_ sb: CMSampleBuffer) { lock.lock(); samples.append(sb); lock.unlock() }
            func fail(_ st: OSStatus) { lock.lock(); if err == noErr { err = st }; lock.unlock() }
        }
        let collector = Collector()

        let minFrameStep = 1.0 / effectiveFPS
        let halfFrameTol = minFrameStep * 0.45
        var firstPTS: CMTime?
        var nextBoundaryIdx = 0
        var lastEncodedSec = -Double.greatestFiniteMagnitude
        var encodedFrames = 0

        while let sb = autoreleasepool(invoking: { videoOutput.copyNextSampleBuffer() }) {
            guard let srcPB = CMSampleBufferGetImageBuffer(sb) else { continue }
            let rawPTS = CMSampleBufferGetPresentationTimeStamp(sb)
            if firstPTS == nil { firstPTS = rawPTS }
            let normPTS = CMTimeMaximum(.zero, CMTimeSubtract(rawPTS, firstPTS ?? .zero))
            let ptsSec = normPTS.seconds
            let dur = CMSampleBufferGetDuration(sb)

            // Force an IDR keyframe on every shared segment boundary timestamp across all rungs.
            var forceKey = false
            while nextBoundaryIdx < sharedIDRBoundaries.count &&
                  ptsSec >= (sharedIDRBoundaries[nextBoundaryIdx] - halfFrameTol) {
                forceKey = true
                nextBoundaryIdx += 1
            }

            if !forceKey && encodedFrames > 0 && (ptsSec - lastEncodedSec) < (minFrameStep * 0.90) {
                continue
            }

            var dstPBOpt: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dstPBOpt) == kCVReturnSuccess,
                  let dstPB = dstPBOpt else { continue }
            try scalePixelBuffer(srcPB, into: dstPB, transferSession: transferSession, ciContext: fallbackCI)
            ColorMasteringProfile.sdrBT709.tagPixelBuffer(dstPB)

            let props: CFDictionary? = forceKey
                ? ([kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary)
                : nil
            let encSt = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: dstPB,
                presentationTimeStamp: normPTS,
                duration: dur.isValid ? dur : CMTime(value: 1, timescale: Int32(max(1, Int(effectiveFPS.rounded())))),
                frameProperties: props,
                infoFlagsOut: nil
            ) { status, flags, outSB in
                if status != noErr { collector.fail(status); return }
                if flags.contains(.frameDropped) { return }
                if let outSB { collector.add(outSB) }
            }
            guard encSt == noErr else {
                reader.cancelReading()
                throw SafariumError.encode("VTCompressionSessionEncodeFrame for MPEG-TS failed (\(encSt))")
            }
            lastEncodedSec = ptsSec
            encodedFrames += 1
        }
        reader.cancelReading()
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)

        guard collector.err == noErr, !collector.samples.isEmpty else {
            throw SafariumError.encode("MPEG-TS encode produced no samples (status \(collector.err))")
        }

        // Partition encoded samples at the exact shared IDR boundary timestamps into 188-byte MPEG-TS segment files
        var segmentBuckets: [[CMSampleBuffer]] = []
        var currentBucket: [CMSampleBuffer] = []
        var cutBoundaryIdx = 1 // index 0 is t=0.0

        for sb in collector.samples {
            let ptsSec = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            let isKey = isKeyframeSampleBuffer(sb)
            if !currentBucket.isEmpty &&
               isKey &&
               cutBoundaryIdx < sharedIDRBoundaries.count &&
               ptsSec >= (sharedIDRBoundaries[cutBoundaryIdx] - halfFrameTol) {
                segmentBuckets.append(currentBucket)
                currentBucket = [sb]
                while cutBoundaryIdx < sharedIDRBoundaries.count &&
                      ptsSec >= (sharedIDRBoundaries[cutBoundaryIdx] - halfFrameTol) {
                    cutBoundaryIdx += 1
                }
            } else {
                currentBucket.append(sb)
            }
        }
        if !currentBucket.isEmpty {
            segmentBuckets.append(currentBucket)
        }

        let streamTypeByte: UInt8 = (tsCodec == .h264) ? 0x1B : 0x24
        var recorded: [RecordedSegment] = []
        var patCC: UInt8 = 0
        var pmtCC: UInt8 = 0
        var vidCC: UInt8 = 0

        for (segIdx, bucket) in segmentBuckets.enumerated() {
            var tsData = Data()
            tsData.append(buildPATPacket(cc: &patCC))
            tsData.append(buildPMTPacket(videoStreamType: streamTypeByte, cc: &pmtCC))

            let firstSec = CMSampleBufferGetPresentationTimeStamp(bucket[0]).seconds
            let segDur: Double
            if segIdx + 1 < segmentBuckets.count, let nextFirst = segmentBuckets[segIdx + 1].first {
                let nextFirstSec = CMSampleBufferGetPresentationTimeStamp(nextFirst).seconds
                segDur = max(1.0 / effectiveFPS, nextFirstSec - firstSec)
            } else {
                let lastSB = bucket[bucket.count - 1]
                let lastPTS = CMSampleBufferGetPresentationTimeStamp(lastSB).seconds
                let lastDur = CMSampleBufferGetDuration(lastSB).seconds
                let frameDur = (lastDur.isFinite && lastDur > 0) ? lastDur : (1.0 / effectiveFPS)
                segDur = max(1.0 / effectiveFPS, (lastPTS - firstSec) + frameDur)
            }

            for sb in bucket {
                let annexB = extractAnnexBBytes(from: sb, isHEVC: tsCodec != .h264)
                guard !annexB.isEmpty else { continue }
                let pts90k = UInt64(max(0.0, CMSampleBufferGetPresentationTimeStamp(sb).seconds * 90_000.0))
                let pes = buildVideoPES(payload: annexB, pts90k: pts90k)
                appendTSPackets(into: &tsData, pid: 0x0100, payload: pes, pcr90k: isKeyframeSampleBuffer(sb) ? pts90k : nil, cc: &vidCC)
            }

            let segName = String(format: "seg_%04d.ts", segIdx)
            let segURL = variantDir.appendingPathComponent(segName)
            try tsData.write(to: segURL, options: .atomic)
            recorded.append(RecordedSegment(filename: segName, durationSeconds: segDur, bytes: Int64(tsData.count)))
        }

        let maxSegDur = recorded.map(\.durationSeconds).max() ?? segmentDuration
        let targetDur = max(1, Int(ceil(maxSegDur)))
        let totalSegBytes = recorded.reduce(Int64(0)) { $0 + $1.bytes }

        var m3u8Lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(targetDur)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
        ]
        for seg in recorded {
            m3u8Lines.append(String(format: "#EXTINF:%.3f,", seg.durationSeconds))
            m3u8Lines.append(seg.filename)
        }
        m3u8Lines.append("#EXT-X-ENDLIST")
        m3u8Lines.append("")

        let playlistURL = variantDir.appendingPathComponent("playlist.m3u8")
        try Data(m3u8Lines.joined(separator: "\n").utf8).write(to: playlistURL, options: .atomic)

        let totalBytes = totalSegBytes + fileSize(playlistURL)
        let measured = measureVariantBandwidths(segments: recorded, fallbackBitrate: rung.bitrate)
        let codecsStr = rfc6381CodecsString(videoCodec: tsCodec, width: rung.width, height: rung.height, hasAudio: false)

        return HLSVariantResult(
            name: variantName,
            width: rung.width,
            height: rung.height,
            fps: effectiveFPS,
            bitrate: measured.peakBandwidth,
            peakBandwidth: measured.peakBandwidth,
            averageBitrate: measured.averageBandwidth,
            codecs: codecsStr,
            playlistPath: playlistURL.path,
            initSegmentPath: nil,
            segmentCount: recorded.count,
            segmentDurations: recorded.map(\.durationSeconds),
            totalBytes: totalBytes
        )
    }

    // MARK: - Internal HLS & Scaling Helpers

    private static func scalePixelBuffer(
        _ src: CVPixelBuffer,
        into dst: CVPixelBuffer,
        transferSession: VTPixelTransferSession?,
        ciContext: CIContext
    ) throws {
        if let ts = transferSession {
            let st = VTPixelTransferSessionTransferImage(ts, from: src, to: dst)
            if st == noErr {
                return
            }
        }
        let dstW = CVPixelBufferGetWidth(dst)
        let dstH = CVPixelBufferGetHeight(dst)
        let srcW = CVPixelBufferGetWidth(src)
        let srcH = CVPixelBufferGetHeight(src)
        var ci = CIImage(cvPixelBuffer: src)
        if srcW != dstW || srcH != dstH {
            let sx = CGFloat(dstW) / CGFloat(max(1, srcW))
            let sy = CGFloat(dstH) / CGFloat(max(1, srcH))
            ci = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }
        let cs = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
        ciContext.render(ci, to: dst, bounds: CGRect(x: 0, y: 0, width: dstW, height: dstH), colorSpace: cs)
    }

    private static func retimedSampleBuffer(_ sb: CMSampleBuffer, subtract offset: CMTime) -> CMSampleBuffer? {
        guard CMTimeCompare(offset, .zero) != 0 else { return sb }
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0 else { return nil }
        var infos = [CMSampleTimingInfo](repeating: .invalid, count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: count, arrayToFill: &infos, entriesNeededOut: &count) == noErr else {
            return nil
        }
        for i in 0..<infos.count {
            if infos[i].presentationTimeStamp.isValid {
                infos[i].presentationTimeStamp = CMTimeMaximum(.zero, CMTimeSubtract(infos[i].presentationTimeStamp, offset))
            }
            if infos[i].decodeTimeStamp.isValid {
                infos[i].decodeTimeStamp = CMTimeMaximum(.zero, CMTimeSubtract(infos[i].decodeTimeStamp, offset))
            }
        }
        var outSB: CMSampleBuffer?
        let st = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sb,
            sampleTimingEntryCount: count,
            sampleTimingArray: &infos,
            sampleBufferOut: &outSB
        )
        return st == noErr ? outSB : nil
    }

    private static func rfc6381CodecsString(videoCodec: VideoCodec, width: Int, height: Int, hasAudio: Bool) -> String {
        let videoTag: String
        switch videoCodec {
        case .h264:
            if width * height <= 1280 * 720 {
                videoTag = "avc1.64001F"
            } else {
                videoTag = "avc1.640028"
            }
        case .hevc10, .hevc42210, .hevc44410:
            videoTag = "hvc1.2.4.L123.B0"
        default:
            videoTag = "hvc1.1.6.L120.90"
        }
        return hasAudio ? "\(videoTag),mp4a.40.2" : videoTag
    }

    private static func sanitizePathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let str = String(cleaned)
        return str.isEmpty ? "variant" : str
    }

    private static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    private static func isKeyframeSampleBuffer(_ sb: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            return true
        }
        let notSync = (first[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        return !notSync
    }

    private static func extractAnnexBBytes(from sb: CMSampleBuffer, isHEVC: Bool) -> Data {
        var out = Data()
        let startCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

        // Prepend parameter sets on keyframes
        if isKeyframeSampleBuffer(sb), let fmt = CMSampleBufferGetFormatDescription(sb) {
            if isHEVC {
                var paramCount = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &paramCount, nalUnitHeaderLengthOut: nil)
                for idx in 0..<paramCount {
                    var ptr: UnsafePointer<UInt8>?
                    var size = 0
                    if CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: idx, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                       let ptr, size > 0 {
                        out.append(contentsOf: startCode)
                        out.append(ptr, count: size)
                    }
                }
            } else {
                var paramCount = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &paramCount, nalUnitHeaderLengthOut: nil)
                for idx in 0..<paramCount {
                    var ptr: UnsafePointer<UInt8>?
                    var size = 0
                    if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: idx, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr,
                       let ptr, size > 0 {
                        out.append(contentsOf: startCode)
                        out.append(ptr, count: size)
                    }
                }
            }
        }

        guard let block = CMSampleBufferGetDataBuffer(sb) else { return out }
        var totalLen = 0
        var dataPtr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLen, dataPointerOut: &dataPtr) == kCMBlockBufferNoErr,
              let base = dataPtr, totalLen > 4 else {
            return out
        }

        let u8 = UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + 4 <= totalLen {
            let b0 = Int(u8[offset]) << 24
            let b1 = Int(u8[offset + 1]) << 16
            let b2 = Int(u8[offset + 2]) << 8
            let b3 = Int(u8[offset + 3])
            let nalLen = b0 | b1 | b2 | b3
            offset += 4
            guard nalLen > 0, offset + nalLen <= totalLen else { break }
            out.append(contentsOf: startCode)
            out.append(u8.advanced(by: offset), count: nalLen)
            offset += nalLen
        }
        return out
    }

    // Minimal ISO/IEC 13818-1 188-byte MPEG-TS packet helpers

    private static func mpegCRC32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b) << 24
            for _ in 0..<8 {
                if (crc & 0x8000_0000) != 0 {
                    crc = (crc << 1) ^ 0x04C1_1DB7
                } else {
                    crc <<= 1
                }
            }
        }
        return crc
    }

    private static func buildPATPacket(cc: inout UInt8) -> Data {
        var pkt = [UInt8](repeating: 0xFF, count: 188)
        pkt[0] = 0x47
        pkt[1] = 0x40
        pkt[2] = 0x00
        pkt[3] = 0x10 | (cc & 0x0F)
        cc = (cc &+ 1) & 0x0F
        pkt[4] = 0x00 // pointer_field
        let section: [UInt8] = [
            0x00, // table_id PAT
            0xB0, 0x0D, // section_length = 13
            0x00, 0x01, // transport_stream_id
            0xC1, 0x00, 0x00,
            0x00, 0x01, // program_number = 1
            0xF0, 0x00, // PMT PID = 0x1000
        ]
        let crc = mpegCRC32(section)
        for i in 0..<section.count { pkt[5 + i] = section[i] }
        let base = 5 + section.count
        pkt[base + 0] = UInt8((crc >> 24) & 0xFF)
        pkt[base + 1] = UInt8((crc >> 16) & 0xFF)
        pkt[base + 2] = UInt8((crc >> 8) & 0xFF)
        pkt[base + 3] = UInt8(crc & 0xFF)
        return Data(pkt)
    }

    private static func buildPMTPacket(videoStreamType: UInt8, cc: inout UInt8) -> Data {
        var pkt = [UInt8](repeating: 0xFF, count: 188)
        pkt[0] = 0x47
        pkt[1] = 0x50
        pkt[2] = 0x00 // PID 0x1000
        pkt[3] = 0x10 | (cc & 0x0F)
        cc = (cc &+ 1) & 0x0F
        pkt[4] = 0x00 // pointer_field
        let section: [UInt8] = [
            0x02, // table_id PMT
            0xB0, 0x12, // section_length = 18
            0x00, 0x01, // program_number = 1
            0xC1, 0x00, 0x00,
            0xE1, 0x00, // PCR PID = 0x0100
            0xF0, 0x00, // program_info_length = 0
            videoStreamType,
            0xE1, 0x00, // elementary PID = 0x0100
            0xF0, 0x00, // ES_info_length = 0
        ]
        let crc = mpegCRC32(section)
        for i in 0..<section.count { pkt[5 + i] = section[i] }
        let base = 5 + section.count
        pkt[base + 0] = UInt8((crc >> 24) & 0xFF)
        pkt[base + 1] = UInt8((crc >> 16) & 0xFF)
        pkt[base + 2] = UInt8((crc >> 8) & 0xFF)
        pkt[base + 3] = UInt8(crc & 0xFF)
        return Data(pkt)
    }

    private static func buildVideoPES(payload: Data, pts90k: UInt64) -> Data {
        var pes = Data(capacity: 14 + payload.count)
        let p = pts90k & 0x1_FFFF_FFFF
        let b0 = UInt8(0x21 | (((p >> 30) & 0x07) << 1))
        let b1 = UInt8((p >> 22) & 0xFF)
        let b2 = UInt8(0x01 | (((p >> 15) & 0x7F) << 1))
        let b3 = UInt8((p >> 7) & 0xFF)
        let b4 = UInt8(0x01 | ((p & 0x7F) << 1))
        pes.append(contentsOf: [0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x80, 0x05, b0, b1, b2, b3, b4])
        pes.append(payload)
        return pes
    }

    private static func appendTSPackets(into out: inout Data, pid: UInt16, payload: Data, pcr90k: UInt64?, cc: inout UInt8) {
        var offset = 0
        var first = true
        while offset < payload.count {
            var pkt = [UInt8](repeating: 0xFF, count: 188)
            pkt[0] = 0x47
            let pusi: UInt8 = first ? 0x40 : 0x00
            pkt[1] = pusi | UInt8((pid >> 8) & 0x1F)
            pkt[2] = UInt8(pid & 0xFF)

            let remaining = payload.count - offset
            let writePCR = first && pcr90k != nil
            var headerLen = 4

            if writePCR, let pcr = pcr90k {
                let afLen = 7
                let maxPayload = 188 - 4 - 1 - afLen
                let copyLen = min(remaining, maxPayload)
                let pad = maxPayload - copyLen
                pkt[3] = 0x30 | (cc & 0x0F)
                pkt[4] = UInt8(afLen + pad)
                pkt[5] = 0x10 // PCR_flag
                let base = pcr & 0x1_FFFF_FFFF
                pkt[6] = UInt8((base >> 25) & 0xFF)
                pkt[7] = UInt8((base >> 17) & 0xFF)
                pkt[8] = UInt8((base >> 9) & 0xFF)
                pkt[9] = UInt8((base >> 1) & 0xFF)
                pkt[10] = UInt8(((base & 1) << 7) | 0x7E)
                pkt[11] = 0x00
                headerLen = 5 + afLen + pad
                payload.copyBytes(to: &pkt[headerLen], from: offset..<(offset + copyLen))
                offset += copyLen
            } else if remaining < 184 {
                let stuff = 184 - remaining
                pkt[3] = 0x30 | (cc & 0x0F)
                pkt[4] = UInt8(stuff - 1)
                if stuff >= 2 { pkt[5] = 0x00 }
                headerLen = 4 + stuff
                payload.copyBytes(to: &pkt[headerLen], from: offset..<(offset + remaining))
                offset += remaining
            } else {
                pkt[3] = 0x10 | (cc & 0x0F)
                payload.copyBytes(to: &pkt[4], from: offset..<(offset + 184))
                offset += 184
            }

            cc = (cc &+ 1) & 0x0F
            first = false
            out.append(contentsOf: pkt)
        }
    }
}

// MARK: - B. Hardware HDR-to-SDR Tone-Mapper (CoreImage CIToneMapHeadroom + BT.709)

/// Apple Silicon CoreImage hardware HDR-to-SDR tone-mapper (`CIToneMapHeadroom` on macOS 15+ with BT.709 fallback).
public enum HardwareToneMapper {
    private static let sharedContext: CIContext = {
        let workCS = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
            ?? CGColorSpace(name: CGColorSpace.linearSRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        return CIContext(options: [
            .workingColorSpace: workCS,
            .cacheIntermediates: false,
        ])
    }()

    /// Returns `true` when `pb` carries PQ (ST.2084) or HLG (BT.2100) HDR transfer attachments.
    public static func isHDRPixelBuffer(_ pb: CVPixelBuffer) -> Bool {
        guard let tf = CVBufferCopyAttachment(pb, kCVImageBufferTransferFunctionKey, nil) else {
            return false
        }
        let tfStr = String(describing: tf)
        return tfStr.contains("2084") || tfStr.contains("HLG") || tfStr.contains("PQ")
    }

    /// Tone-maps `src` (HDR10 PQ, HLG, Dolby Vision 8.4, or wide-gamut 10-bit/BGRA) into SDR BT.709 `dst`.
    public static func toneMapPixelBuffer(
        _ src: CVPixelBuffer,
        into dst: CVPixelBuffer,
        targetHeadroom: Float = 1.0
    ) throws {
        let srcW = CVPixelBufferGetWidth(src)
        let srcH = CVPixelBufferGetHeight(src)
        let dstW = CVPixelBufferGetWidth(dst)
        let dstH = CVPixelBufferGetHeight(dst)
        guard srcW > 0, srcH > 0, dstW > 0, dstH > 0 else {
            throw SafariumError.invalidState("HardwareToneMapper requires non-zero pixel buffer dimensions")
        }

        var image = CIImage(cvPixelBuffer: src)
        let clampedHeadroom = max(1.0, targetHeadroom)

        if #available(macOS 15.0, *),
           let filter = CIFilter(name: "CIToneMapHeadroom") {
            filter.setValue(image, forKey: kCIInputImageKey)
            if filter.inputKeys.contains("inputTargetHeadroom") {
                filter.setValue(NSNumber(value: clampedHeadroom), forKey: "inputTargetHeadroom")
            }
            if let mapped = filter.outputImage {
                image = mapped
            }
        }

        if srcW != dstW || srcH != dstH {
            let sx = CGFloat(dstW) / CGFloat(srcW)
            let sy = CGFloat(dstH) / CGFloat(srcH)
            image = image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        }

        let targetColorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
        let bounds = CGRect(x: 0, y: 0, width: dstW, height: dstH)
        sharedContext.render(image, to: dst, bounds: bounds, colorSpace: targetColorSpace)
        ColorMasteringProfile.sdrBT709.tagPixelBuffer(dst)
    }
}

// MARK: - C. Direct Video -> Animated Clip Exporter (GIF / APNG / Animated WebP, 0% FFmpeg)

/// Summary report returned by `AnimatedClipExporter`.
public struct AnimatedClipResult: Codable, Sendable {
    public let inputPath: String
    public let outputPath: String
    public let format: String
    public let width: Int
    public let height: Int
    public let fps: Double
    public let frameCount: Int
    public let durationSeconds: Double
    public let outputBytes: Int64
    public let elapsedMs: Double
}

/// Direct native Video → Animated GIF / APNG / Animated WebP exporter (100% Apple frameworks + pure-Swift VP8L, 0% FFmpeg).
public enum AnimatedClipExporter {
    /// Exports a video clip directly to an animated GIF via `AVAssetReader` + `ImageIO` (`CGImageDestination`).
    public static func exportGIF(
        inputURL: URL,
        outputURL: URL,
        fps: Double = 12,
        maxWidth: Int = 640,
        maxDurationSeconds: Double? = nil
    ) async throws -> AnimatedClipResult {
        try await exportViaImageIO(
            inputURL: inputURL,
            outputURL: outputURL,
            utType: UTType.gif.identifier as CFString,
            formatName: "gif",
            fps: fps,
            maxWidth: maxWidth,
            maxDurationSeconds: maxDurationSeconds
        )
    }

    /// Exports a video clip directly to an animated PNG (APNG) via `AVAssetReader` + `ImageIO` (`CGImageDestination`).
    public static func exportAPNG(
        inputURL: URL,
        outputURL: URL,
        fps: Double = 12,
        maxWidth: Int = 640,
        maxDurationSeconds: Double? = nil
    ) async throws -> AnimatedClipResult {
        try await exportViaImageIO(
            inputURL: inputURL,
            outputURL: outputURL,
            utType: UTType.png.identifier as CFString,
            formatName: "apng",
            fps: fps,
            maxWidth: maxWidth,
            maxDurationSeconds: maxDurationSeconds
        )
    }

    /// Exports a video clip directly to a spec-compliant Animated WebP (`RIFF....WEBPVP8X` + `ANIM` + `ANMF` + lossless `VP8L`).
    public static func exportAnimatedWebP(
        inputURL: URL,
        outputURL: URL,
        fps: Double = 12,
        maxWidth: Int = 640,
        maxDurationSeconds: Double? = nil
    ) async throws -> AnimatedClipResult {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let sampled = try await extractSampledFrames(
            inputURL: inputURL,
            fps: fps,
            maxWidth: maxWidth,
            maxDurationSeconds: maxDurationSeconds
        )
        guard !sampled.frames.isEmpty else {
            throw SafariumError.encode("AnimatedClipExporter extracted 0 frames from \(inputURL.lastPathComponent)")
        }

        let delayMs = max(10, Int((1000.0 / sampled.fps).rounded()))
        let webpData = try NativeAnimatedWebPEncoder.encode(
            frames: sampled.frames,
            width: sampled.width,
            height: sampled.height,
            frameDurationMs: delayMs
        )

        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }
        let tempURL = staging.fileURL("clip.webp")
        try webpData.write(to: tempURL, options: .atomic)
        try SafeFilePublisher.publish(tempURL: tempURL, to: outputURL, overwrite: true)

        let outBytes = Int64(webpData.count)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0
        return AnimatedClipResult(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            format: "webp",
            width: sampled.width,
            height: sampled.height,
            fps: sampled.fps,
            frameCount: sampled.frames.count,
            durationSeconds: Double(sampled.frames.count) / sampled.fps,
            outputBytes: outBytes,
            elapsedMs: (elapsedMs * 100.0).rounded() / 100.0
        )
    }

    // MARK: - Shared Frame Sampler & ImageIO Writer

    private struct SampledVideoFrames {
        let frames: [CGImage]
        let width: Int
        let height: Int
        let fps: Double
    }

    private static func exportViaImageIO(
        inputURL: URL,
        outputURL: URL,
        utType: CFString,
        formatName: String,
        fps: Double,
        maxWidth: Int,
        maxDurationSeconds: Double?
    ) async throws -> AnimatedClipResult {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let sampled = try await extractSampledFrames(
            inputURL: inputURL,
            fps: fps,
            maxWidth: maxWidth,
            maxDurationSeconds: maxDurationSeconds
        )
        guard !sampled.frames.isEmpty else {
            throw SafariumError.encode("AnimatedClipExporter extracted 0 frames from \(inputURL.lastPathComponent)")
        }

        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }
        let tempURL = staging.fileURL("clip.\(formatName)")

        guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, utType, sampled.frames.count, nil) else {
            throw SafariumError.encode("CGImageDestinationCreateWithURL failed for \(formatName)")
        }

        let delaySec = 1.0 / sampled.fps
        if formatName == "gif" {
            let fileProps: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFLoopCount: 0,
                ],
            ]
            CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
            let frameProps: [CFString: Any] = [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFUnclampedDelayTime: delaySec,
                    kCGImagePropertyGIFDelayTime: delaySec,
                ],
            ]
            for cg in sampled.frames {
                CGImageDestinationAddImage(dest, cg, frameProps as CFDictionary)
            }
        } else {
            let fileProps: [CFString: Any] = [
                kCGImagePropertyPNGDictionary: [
                    kCGImagePropertyAPNGLoopCount: 0,
                ],
            ]
            CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
            let frameProps: [CFString: Any] = [
                kCGImagePropertyPNGDictionary: [
                    kCGImagePropertyAPNGUnclampedDelayTime: delaySec,
                    kCGImagePropertyAPNGDelayTime: delaySec,
                ],
            ]
            for cg in sampled.frames {
                CGImageDestinationAddImage(dest, cg, frameProps as CFDictionary)
            }
        }

        guard CGImageDestinationFinalize(dest) else {
            throw SafariumError.encode("CGImageDestinationFinalize failed for \(formatName)")
        }

        try SafeFilePublisher.publish(tempURL: tempURL, to: outputURL, overwrite: true)
        let outBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0
        return AnimatedClipResult(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            format: formatName,
            width: sampled.width,
            height: sampled.height,
            fps: sampled.fps,
            frameCount: sampled.frames.count,
            durationSeconds: Double(sampled.frames.count) / sampled.fps,
            outputBytes: outBytes,
            elapsedMs: (elapsedMs * 100.0).rounded() / 100.0
        )
    }

    private static func extractSampledFrames(
        inputURL: URL,
        fps: Double,
        maxWidth: Int,
        maxDurationSeconds: Double?
    ) async throws -> SampledVideoFrames {
        try SafeFilePublisher.assertRegularReadableFile(inputURL)
        let clampedFPS = max(1.0, min(60.0, fps))
        let clampedMaxW = max(16, maxWidth)

        let asset = AVURLAsset(url: inputURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        ])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw SafariumError.invalidState("no video track in \(inputURL.lastPathComponent)")
        }
        let naturalSize = try await track.load(.naturalSize)
        let srcW = max(2, Int(abs(naturalSize.width).rounded()))
        let srcH = max(2, Int(abs(naturalSize.height).rounded()))

        let scale = srcW > clampedMaxW ? (Double(clampedMaxW) / Double(srcW)) : 1.0
        let dstW = max(2, (Int((Double(srcW) * scale).rounded()) / 2) * 2)
        let dstH = max(2, (Int((Double(srcH) * scale).rounded()) / 2) * 2)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw SafariumError.encode("AVAssetReader cannot read video for animated clip export")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw SafariumError.encode("AVAssetReader startReading failed: \(reader.error?.localizedDescription ?? "?")")
        }

        let ciCtx = CIContext(options: [.cacheIntermediates: false])
        let outCS = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let stepSec = 1.0 / clampedFPS
        var firstPTS: Double?
        var nextCaptureSec = 0.0
        var frames: [CGImage] = []

        while let sb = autoreleasepool(invoking: { output.copyNextSampleBuffer() }) {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let rawSec = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            guard rawSec.isFinite else { continue }
            if firstPTS == nil { firstPTS = rawSec }
            let relSec = rawSec - (firstPTS ?? rawSec)

            if let maxDur = maxDurationSeconds, relSec > maxDur + 0.001 {
                break
            }
            if relSec + 0.0005 < nextCaptureSec {
                continue
            }

            var ci = CIImage(cvPixelBuffer: pb)
            if HardwareToneMapper.isHDRPixelBuffer(pb), #available(macOS 15.0, *),
               let filter = CIFilter(name: "CIToneMapHeadroom") {
                filter.setValue(ci, forKey: kCIInputImageKey)
                if filter.inputKeys.contains("inputTargetHeadroom") {
                    filter.setValue(NSNumber(value: 1.0 as Float), forKey: "inputTargetHeadroom")
                }
                if let mapped = filter.outputImage {
                    ci = mapped
                }
            }
            if dstW != srcW || dstH != srcH {
                let sx = CGFloat(dstW) / CGFloat(srcW)
                let sy = CGFloat(dstH) / CGFloat(srcH)
                ci = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            }

            if let cg = ciCtx.createCGImage(
                ci,
                from: CGRect(x: 0, y: 0, width: dstW, height: dstH),
                format: .RGBA8,
                colorSpace: outCS
            ) {
                frames.append(cg)
            }
            nextCaptureSec += stepSec
            while nextCaptureSec <= relSec {
                nextCaptureSec += stepSec
            }
        }
        reader.cancelReading()

        return SampledVideoFrames(frames: frames, width: dstW, height: dstH, fps: clampedFPS)
    }
}

// MARK: - Self-Contained Spec-Compliant Lossless Animated WebP Encoder (RIFF VP8X + ANIM + ANMF + VP8L)

private enum NativeAnimatedWebPEncoder {
    private static let codeLengthCodeOrder: [Int] = [
        17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    ]

    private final class LSBWriter {
        var data = Data()
        private var bitBuf: UInt64 = 0
        private var bitCount: Int = 0

        func write(_ value: UInt32, bits: Int) {
            guard bits > 0 else { return }
            let mask: UInt64 = (UInt64(1) << bits) - 1
            bitBuf |= (UInt64(value) & mask) << bitCount
            bitCount += bits
            while bitCount >= 8 {
                data.append(UInt8(bitBuf & 0xFF))
                bitBuf >>= 8
                bitCount -= 8
            }
        }

        func finish() -> Data {
            if bitCount > 0 {
                data.append(UInt8(bitBuf & 0xFF))
                bitBuf = 0
                bitCount = 0
            }
            return data
        }
    }

    private struct PrefixCode {
        let isSimple: Bool
        let simpleSymbols: [Int]
        let lengths: [Int]
        let codesLSB: [UInt32]
    }

    static func encode(frames: [CGImage], width: Int, height: Int, frameDurationMs: Int) throws -> Data {
        guard width >= 1, width <= 16384, height >= 1, height <= 16384 else {
            throw SafariumError.invalidState("WebP dimensions out of range: \(width)x\(height)")
        }

        var hasAnyAlpha = false
        var framePayloads: [Data] = []
        framePayloads.reserveCapacity(frames.count)

        let bytesPerRow = width * 4
        var rgba = [UInt8](repeating: 0, count: height * bytesPerRow)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        for cg in frames {
            rgba.withUnsafeMutableBytes { rawBuf in
                if let ctx = CGContext(
                    data: rawBuf.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                ) {
                    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
                    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
                }
            }
            let (vp8l, frameHasAlpha) = encodeVP8LFrame(rgba: rgba, width: width, height: height)
            if frameHasAlpha { hasAnyAlpha = true }
            framePayloads.append(vp8l)
        }

        // Build VP8X chunk (10 bytes)
        var vp8x = Data(capacity: 10)
        let vp8xFlags: UInt8 = 0x02 | (hasAnyAlpha ? 0x10 : 0x00)
        vp8x.append(vp8xFlags)
        vp8x.append(contentsOf: [0, 0, 0])
        appendLE24(&vp8x, UInt32(width - 1))
        appendLE24(&vp8x, UInt32(height - 1))

        // Build ANIM chunk (6 bytes: BGRA background + loop count 0)
        let anim = Data([0, 0, 0, 0, 0, 0])

        // Assemble body chunks
        var body = Data()
        appendRIFFChunk(&body, fourCC: "VP8X", payload: vp8x)
        appendRIFFChunk(&body, fourCC: "ANIM", payload: anim)

        let clampedDur = UInt32(max(1, min(0xFF_FFFF, frameDurationMs)))
        for vp8l in framePayloads {
            var anmf = Data(capacity: 16 + 8 + vp8l.count + 1)
            appendLE24(&anmf, 0) // frame X / 2
            appendLE24(&anmf, 0) // frame Y / 2
            appendLE24(&anmf, UInt32(width - 1))
            appendLE24(&anmf, UInt32(height - 1))
            appendLE24(&anmf, clampedDur)
            anmf.append(0x02) // no-blend (replace), no-dispose
            appendRIFFChunk(&anmf, fourCC: "VP8L", payload: vp8l)
            appendRIFFChunk(&body, fourCC: "ANMF", payload: anmf)
        }

        var riff = Data(capacity: 12 + body.count)
        riff.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        appendLE32(&riff, UInt32(4 + body.count))
        riff.append(contentsOf: [0x57, 0x45, 0x42, 0x50]) // "WEBP"
        riff.append(body)
        return riff
    }

    private static func encodeVP8LFrame(rgba: [UInt8], width: Int, height: Int) -> (Data, Bool) {
        let pixelCount = width * height
        var freqG = [Int](repeating: 0, count: 280)
        var freqR = [Int](repeating: 0, count: 256)
        var freqB = [Int](repeating: 0, count: 256)
        var freqA = [Int](repeating: 0, count: 256)
        var hasAlpha = false

        var p = 0
        while p < pixelCount {
            let off = p * 4
            let r = Int(rgba[off])
            let g = Int(rgba[off + 1])
            let b = Int(rgba[off + 2])
            let a = Int(rgba[off + 3])
            freqR[r] += 1
            freqG[g] += 1
            freqB[b] += 1
            freqA[a] += 1
            if a < 255 { hasAlpha = true }
            p += 1
        }

        let codeG = buildPrefixCode(freqs: freqG, alphabetSize: 280)
        let codeR = buildPrefixCode(freqs: freqR, alphabetSize: 256)
        let codeB = buildPrefixCode(freqs: freqB, alphabetSize: 256)
        let codeA = buildPrefixCode(freqs: freqA, alphabetSize: 256)
        var freqD = [Int](repeating: 0, count: 40)
        freqD[0] = 1
        let codeD = buildPrefixCode(freqs: freqD, alphabetSize: 40)

        let writer = LSBWriter()
        // VP8L signature byte (0x2F) + 32-bit header
        let wField = UInt32(width - 1) & 0x3FFF
        let hField = (UInt32(height - 1) & 0x3FFF) << 14
        let aField: UInt32 = hasAlpha ? (UInt32(1) << 28) : 0
        let headerWord = wField | hField | aField

        writer.write(0x2F, bits: 8)
        writer.write(headerWord, bits: 32)

        // No transforms, no color cache, no meta prefix codes
        writer.write(0, bits: 1) // transform_present = 0
        writer.write(0, bits: 1) // color_cache_used = 0
        writer.write(0, bits: 1) // use_meta_prefix_codes = 0

        writePrefixCode(codeG, alphabetSize: 280, maxSymbolLimit: 256, to: writer)
        writePrefixCode(codeR, alphabetSize: 256, maxSymbolLimit: 256, to: writer)
        writePrefixCode(codeB, alphabetSize: 256, maxSymbolLimit: 256, to: writer)
        writePrefixCode(codeA, alphabetSize: 256, maxSymbolLimit: 256, to: writer)
        writePrefixCode(codeD, alphabetSize: 40, maxSymbolLimit: 40, to: writer)

        // Emit pixel stream in VP8L G, R, B, A order
        p = 0
        while p < pixelCount {
            let off = p * 4
            let r = Int(rgba[off])
            let g = Int(rgba[off + 1])
            let b = Int(rgba[off + 2])
            let a = Int(rgba[off + 3])
            let lenG = codeG.lengths[g]
            if lenG > 0 { writer.write(codeG.codesLSB[g], bits: lenG) }
            let lenR = codeR.lengths[r]
            if lenR > 0 { writer.write(codeR.codesLSB[r], bits: lenR) }
            let lenB = codeB.lengths[b]
            if lenB > 0 { writer.write(codeB.codesLSB[b], bits: lenB) }
            let lenA = codeA.lengths[a]
            if lenA > 0 { writer.write(codeA.codesLSB[a], bits: lenA) }
            p += 1
        }

        return (writer.finish(), hasAlpha)
    }

    private static func buildPrefixCode(freqs: [Int], alphabetSize: Int) -> PrefixCode {
        var active: [(sym: Int, freq: Int)] = []
        active.reserveCapacity(256)
        for s in 0..<alphabetSize where freqs[s] > 0 {
            active.append((s, freqs[s]))
        }

        if active.count <= 1 {
            let s0 = active.first?.sym ?? 0
            return PrefixCode(
                isSimple: true,
                simpleSymbols: [s0],
                lengths: [Int](repeating: 0, count: alphabetSize),
                codesLSB: [UInt32](repeating: 0, count: alphabetSize)
            )
        }
        if active.count == 2 && active[0].sym < 256 && active[1].sym < 256 {
            let s0 = active[0].sym
            let s1 = active[1].sym
            var lengths = [Int](repeating: 0, count: alphabetSize)
            var codes = [UInt32](repeating: 0, count: alphabetSize)
            lengths[s0] = 1
            lengths[s1] = 1
            codes[s0] = 0
            codes[s1] = 1
            return PrefixCode(
                isSimple: true,
                simpleSymbols: [s0, s1],
                lengths: lengths,
                codesLSB: codes
            )
        }

        // Build standard Huffman tree and cap depths to 15 while keeping exact Kraft sum == 2^15.
        let lengths = computeCanonicalLengths(active: active, alphabetSize: alphabetSize, maxBits: 15)
        let codesLSB = buildCanonicalLSBCodes(lengths: lengths)
        return PrefixCode(
            isSimple: false,
            simpleSymbols: [],
            lengths: lengths,
            codesLSB: codesLSB
        )
    }

    private static func computeCanonicalLengths(
        active: [(sym: Int, freq: Int)],
        alphabetSize: Int,
        maxBits: Int
    ) -> [Int] {
        struct Node {
            var freq: Int
            var sym: Int
            var left: Int
            var right: Int
        }
        var nodes: [Node] = []
        nodes.reserveCapacity(active.count * 2)
        var queue: [Int] = []
        queue.reserveCapacity(active.count)

        for item in active {
            let idx = nodes.count
            nodes.append(Node(freq: item.freq, sym: item.sym, left: -1, right: -1))
            queue.append(idx)
        }

        while queue.count > 1 {
            queue.sort { a, b in
                if nodes[a].freq != nodes[b].freq { return nodes[a].freq < nodes[b].freq }
                return a < b
            }
            let a = queue.removeFirst()
            let b = queue.removeFirst()
            let parentIdx = nodes.count
            nodes.append(Node(freq: nodes[a].freq + nodes[b].freq, sym: -1, left: a, right: b))
            queue.append(parentIdx)
        }

        var lengths = [Int](repeating: 0, count: alphabetSize)
        if let root = queue.first {
            var stack: [(Int, Int)] = [(root, 0)]
            while let (idx, depth) = stack.popLast() {
                let n = nodes[idx]
                if n.sym >= 0 {
                    lengths[n.sym] = max(1, min(maxBits, depth))
                } else {
                    if n.left >= 0 { stack.append((n.left, depth + 1)) }
                    if n.right >= 0 { stack.append((n.right, depth + 1)) }
                }
            }
        }

        // Enforce exact Kraft sum == (1 << maxBits) after clamping any depth > maxBits.
        let kraftTarget = 1 << maxBits
        func currentKraft() -> Int {
            var sum = 0
            for len in lengths where len > 0 {
                sum += 1 << (maxBits - len)
            }
            return sum
        }

        var kraft = currentKraft()
        let activeSortedByFreqAsc = active.sorted { $0.freq < $1.freq }.map(\.sym)
        let activeSortedByFreqDesc = activeSortedByFreqAsc.reversed()

        while kraft > kraftTarget {
            var adjusted = false
            for sym in activeSortedByFreqAsc {
                let len = lengths[sym]
                if len > 0 && len < maxBits {
                    lengths[sym] = len + 1
                    kraft -= 1 << (maxBits - len - 1)
                    adjusted = true
                    break
                }
            }
            if !adjusted { break }
        }

        while kraft < kraftTarget {
            let deficit = kraftTarget - kraft
            var adjusted = false
            for sym in activeSortedByFreqDesc {
                let len = lengths[sym]
                if len > 1 {
                    let gain = 1 << (maxBits - len)
                    if gain <= deficit {
                        lengths[sym] = len - 1
                        kraft += gain
                        adjusted = true
                        break
                    }
                }
            }
            if !adjusted { break }
        }

        return lengths
    }

    private static func buildCanonicalLSBCodes(lengths: [Int]) -> [UInt32] {
        var pairs: [(sym: Int, len: Int)] = []
        pairs.reserveCapacity(lengths.count)
        for s in 0..<lengths.count where lengths[s] > 0 {
            pairs.append((s, lengths[s]))
        }
        pairs.sort { a, b in
            if a.len != b.len { return a.len < b.len }
            return a.sym < b.sym
        }
        var codes = [UInt32](repeating: 0, count: lengths.count)
        var code: UInt32 = 0
        var prevLen = 0
        for item in pairs {
            code <<= (item.len - prevLen)
            codes[item.sym] = reverseBits(code, length: item.len)
            code += 1
            prevLen = item.len
        }
        return codes
    }

    private static func writePrefixCode(
        _ pc: PrefixCode,
        alphabetSize: Int,
        maxSymbolLimit: Int,
        to writer: LSBWriter
    ) {
        if pc.isSimple {
            writer.write(1, bits: 1) // is_simple = 1
            let twoSyms = pc.simpleSymbols.count == 2
            writer.write(twoSyms ? 1 : 0, bits: 1) // num_symbols - 1
            let s0 = pc.simpleSymbols[0]
            if s0 <= 1 {
                writer.write(0, bits: 1) // is_first_8bits = 0
                writer.write(UInt32(s0), bits: 1)
            } else {
                writer.write(1, bits: 1) // is_first_8bits = 1
                writer.write(UInt32(s0), bits: 8)
            }
            if twoSyms {
                writer.write(UInt32(pc.simpleSymbols[1]), bits: 8)
            }
            return
        }

        // Normal prefix code: fixed 4-bit code-length-code table for symbols 0...15 (exact Kraft sum 16 * 2^-4 = 1).
        writer.write(0, bits: 1) // is_simple = 0
        writer.write(15, bits: 4) // num_code_lengths = 4 + 15 = 19
        for sym in codeLengthCodeOrder {
            let clLen: UInt32 = (sym >= 0 && sym <= 15) ? 4 : 0
            writer.write(clLen, bits: 3)
        }

        let limit = min(alphabetSize, maxSymbolLimit)
        if limit < alphabetSize && limit >= 2 {
            writer.write(1, bits: 1) // use_max_symbol = 1
            writer.write(3, bits: 3) // length_nbits = 2 + 2*3 = 8
            writer.write(UInt32(limit - 2), bits: 8)
        } else {
            writer.write(0, bits: 1) // use_max_symbol = 0
        }

        // Emit literal code lengths (0...15) using their 4-bit bit-reversed canonical codes.
        for sym in 0..<limit {
            let len = UInt32(pc.lengths[sym] & 0x0F)
            writer.write(reverseBits(len, length: 4), bits: 4)
        }
    }

    private static func reverseBits(_ code: UInt32, length: Int) -> UInt32 {
        var x = code
        var rev: UInt32 = 0
        for _ in 0..<length {
            rev = (rev << 1) | (x & 1)
            x >>= 1
        }
        return rev
    }

    private static func appendLE24(_ data: inout Data, _ v: UInt32) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
    }

    private static func appendLE32(_ data: inout Data, _ v: UInt32) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 24) & 0xFF))
    }

    private static func appendRIFFChunk(_ out: inout Data, fourCC: String, payload: Data) {
        out.append(contentsOf: fourCC.utf8)
        appendLE32(&out, UInt32(payload.count))
        out.append(payload)
        if (payload.count & 1) == 1 {
            out.append(0x00)
        }
    }
}
