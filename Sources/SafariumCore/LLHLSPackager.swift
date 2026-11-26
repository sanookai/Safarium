import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import UniformTypeIdentifiers
import VideoToolbox

// MARK: - Wave 16B: Low-Latency HLS (LL-HLS, RFC 8216bis) CMAF Packager & Validator

/// Packaging options for `LLHLSPackager.package`.
public struct LLHLSPackageOptions: Codable, Sendable, Equatable {
    public var partDurationSeconds: Double
    public var segmentDurationSeconds: Double
    public var width: Int?
    public var height: Int?
    public var bitrate: Int
    public var codec: VideoCodec
    public var includePreloadHint: Bool
    public var endList: Bool

    public init(
        partDurationSeconds: Double = 0.34,
        segmentDurationSeconds: Double = 2.0,
        width: Int? = nil,
        height: Int? = nil,
        bitrate: Int = 3_500_000,
        codec: VideoCodec = .hevc10,
        includePreloadHint: Bool = true,
        endList: Bool = true
    ) {
        let clampedPart = max(0.10, min(2.0, partDurationSeconds))
        let clampedSeg = max(clampedPart, segmentDurationSeconds)
        self.partDurationSeconds = clampedPart
        self.segmentDurationSeconds = clampedSeg
        self.width = width.map { max(16, ($0 / 2) * 2) }
        self.height = height.map { max(16, ($0 / 2) * 2) }
        self.bitrate = max(150_000, bitrate)
        self.codec = codec
        self.includePreloadHint = includePreloadHint
        self.endList = endList
    }
}

/// Metadata for a single LL-HLS partial segment (`#EXT-X-PART`).
public struct LLHLSPartInfo: Codable, Sendable, Equatable {
    public let uri: String
    public let durationSeconds: Double
    public let independent: Bool
    public let bytes: Int64

    public init(uri: String, durationSeconds: Double, independent: Bool, bytes: Int64) {
        self.uri = uri
        self.durationSeconds = durationSeconds
        self.independent = independent
        self.bytes = bytes
    }
}

/// Output summary produced by `LLHLSPackager.package`.
public struct LLHLSPackageResult: Codable, Sendable, Equatable {
    public let outputDirectory: String
    public let masterPlaylistPath: String
    public let mediaPlaylistPath: String
    public let initSegmentPath: String
    public let parts: [LLHLSPartInfo]
    public let segments: [String]
    public let partTargetSeconds: Double
    public let partHoldBackSeconds: Double
    public let elapsedMs: Double

    public init(
        outputDirectory: String,
        masterPlaylistPath: String,
        mediaPlaylistPath: String,
        initSegmentPath: String,
        parts: [LLHLSPartInfo],
        segments: [String],
        partTargetSeconds: Double,
        partHoldBackSeconds: Double,
        elapsedMs: Double
    ) {
        self.outputDirectory = outputDirectory
        self.masterPlaylistPath = masterPlaylistPath
        self.mediaPlaylistPath = mediaPlaylistPath
        self.initSegmentPath = initSegmentPath
        self.parts = parts
        self.segments = segments
        self.partTargetSeconds = partTargetSeconds
        self.partHoldBackSeconds = partHoldBackSeconds
        self.elapsedMs = elapsedMs
    }
}

/// RFC 8216bis Low-Latency HLS conformance validation report.
public struct LLHLSValidationReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let partCount: Int
    public let independentPartCount: Int
    public let partTarget: Double
    public let hasServerControl: Bool
    public let hasPartInf: Bool
    public let hasPreloadHint: Bool
    public let violations: [String]

    public init(
        passed: Bool,
        partCount: Int,
        independentPartCount: Int,
        partTarget: Double,
        hasServerControl: Bool,
        hasPartInf: Bool,
        hasPreloadHint: Bool,
        violations: [String]
    ) {
        self.passed = passed
        self.partCount = partCount
        self.independentPartCount = independentPartCount
        self.partTarget = partTarget
        self.hasServerControl = hasServerControl
        self.hasPartInf = hasPartInf
        self.hasPreloadHint = hasPreloadHint
        self.violations = violations
    }
}

/// Native Apple Silicon Low-Latency HLS (LL-HLS / RFC 8216bis) CMAF packager & validator.
public enum LLHLSPackager {

    private struct CapturedPart: Sendable {
        let info: LLHLSPartInfo
        let data: Data
    }

    private struct SegmentGroup: Sendable {
        let filename: String
        let durationSeconds: Double
        let parts: [LLHLSPartInfo]
        let bytes: Int64
    }

    private final class LLHLSSegmentDelegate: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
        private let outputDir: URL
        private let fallbackPartDuration: Double
        private let lock = NSLock()
        private var initWritten = false
        private var parts: [CapturedPart] = []
        private var writeError: Error?

        init(outputDir: URL, fallbackPartDuration: Double) {
            self.outputDir = outputDir
            self.fallbackPartDuration = fallbackPartDuration
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
                    let initURL = outputDir.appendingPathComponent("init.mp4")
                    try segmentData.write(to: initURL, options: .atomic)
                    initWritten = true
                } else if segmentType == .separable {
                    let idx = parts.count
                    let partName = String(format: "part_%04d.m4s", idx)
                    let partURL = outputDir.appendingPathComponent(partName)
                    try segmentData.write(to: partURL, options: .atomic)

                    var dur = fallbackPartDuration
                    if let report = segmentReport {
                        if let vRep = report.trackReports.first(where: { $0.mediaType == .video }),
                           vRep.duration.isNumeric,
                           vRep.duration.seconds.isFinite,
                           vRep.duration.seconds > 0.01 {
                            dur = vRep.duration.seconds
                        } else if let anyRep = report.trackReports.first,
                                  anyRep.duration.isNumeric,
                                  anyRep.duration.seconds.isFinite,
                                  anyRep.duration.seconds > 0.01 {
                            dur = anyRep.duration.seconds
                        }
                    }

                    let boxes = LLHLSPackager.parseTopLevelBoxes(segmentData)
                    let hasMoof = boxes.contains { $0.type == "moof" }
                    let info = LLHLSPartInfo(
                        uri: partName,
                        durationSeconds: (dur * 1000.0).rounded() / 1000.0,
                        independent: hasMoof,
                        bytes: Int64(segmentData.count)
                    )
                    parts.append(CapturedPart(info: info, data: segmentData))
                }
            } catch {
                writeError = error
            }
        }

        func snapshot() -> (initWritten: Bool, parts: [CapturedPart], error: Error?) {
            lock.lock()
            defer { lock.unlock() }
            return (initWritten, parts, writeError)
        }
    }

    // MARK: - Package LL-HLS Stream

    /// Encodes `inputURL` into CMAF fMP4 partial segments (`init.mp4`, `part_XXXX.m4s`, `seg_XXXX.m4s`)
    /// and RFC 8216bis compliant `playlist.m3u8` + `master.m3u8`.
    public static func package(
        inputURL: URL,
        outputDirectory: URL,
        options: LLHLSPackageOptions = LLHLSPackageOptions()
    ) async throws -> LLHLSPackageResult {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(inputURL)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let asset = AVURLAsset(url: inputURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        ])
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw SafariumError.invalidState("LLHLSPackager: no video track in \(inputURL.lastPathComponent)")
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        let srcW = max(16, (Int(abs(transformedRect.width).rounded()) / 2) * 2)
        let srcH = max(16, (Int(abs(transformedRect.height).rounded()) / 2) * 2)

        let outW = options.width ?? srcW
        let outH = options.height ?? srcH

        let nominalFPS = Double(try await videoTrack.load(.nominalFrameRate))
        let effectiveFPS = (nominalFPS.isFinite && nominalFPS > 0.1) ? nominalFPS : 30.0

        // Choose Closed-GOP keyframe cadence aligned to partDurationSeconds so every part starts on an IDR.
        let partDur = options.partDurationSeconds
        let framesPerPart = max(1, Int((effectiveFPS * partDur).rounded()))
        let actualKeyframeDur = Double(framesPerPart) / effectiveFPS
        let flushIntervalSec = max(0.05, min(partDur, actualKeyframeDur - 0.005))

        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: flushIntervalSec, preferredTimescale: 600)
        writer.initialSegmentStartTime = .zero

        let delegate = LLHLSSegmentDelegate(outputDir: outputDirectory, fallbackPartDuration: actualKeyframeDur)
        writer.delegate = delegate

        let hlsCodec: VideoCodec = (options.codec == .h264) ? .h264 : (options.codec.is10Bit ? .hevc10 : .hevc)
        var compProps: [String: Any] = [
            AVVideoAverageBitRateKey: options.bitrate,
            AVVideoMaxKeyFrameIntervalKey: framesPerPart,
            AVVideoMaxKeyFrameIntervalDurationKey: partDur,
            AVVideoExpectedSourceFrameRateKey: effectiveFPS,
            AVVideoAllowFrameReorderingKey: false,
            kVTCompressionPropertyKey_AllowOpenGOP as String: false,
        ]
        if let profileLevel = hlsCodec.defaultProfileLevel {
            compProps[AVVideoProfileLevelKey] = profileLevel
        } else if hlsCodec == .h264 {
            compProps[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: hlsCodec.avCodec,
            AVVideoWidthKey: outW,
            AVVideoHeightKey: outH,
            AVVideoColorPropertiesKey: ColorMasteringProfile.sdrBT709.avColorProperties,
            AVVideoCompressionPropertiesKey: compProps,
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else {
            throw SafariumError.encode("LLHLSPackager: AVAssetWriter (.mpeg4AppleHLS) cannot add video input")
        }
        writer.add(videoInput)

        let pixelFormat: OSType = hlsCodec.is10Bit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: outW,
            kCVPixelBufferHeightKey as String: outH,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: adaptorAttrs
        )

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw SafariumError.encode("LLHLSPackager: AVAssetReader cannot read video track")
        }
        reader.add(videoOutput)

        // Optional AAC audio muxing into CMAF partial segments
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioInput: AVAssetWriterInput?
        var audioOutput: AVAssetReaderTrackOutput?
        var hasMuxedAudio = false

        if let audioTrack = audioTracks.first {
            let descs = (try? await audioTrack.load(.formatDescriptions)) ?? []
            let asbd = descs.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let sampleRate = Int((asbd?.mSampleRate ?? 48_000).rounded())
            let channels = max(1, min(2, Int(asbd?.mChannelsPerFrame ?? 2)))
            let aSettings = ProAudioEncoder.outputSettings(
                codec: .aacMax,
                sampleRate: sampleRate,
                channels: channels,
                bitrate: 128_000
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
                    audioOutput = aOut
                    audioInput = aIn
                    hasMuxedAudio = true
                }
            }
        }

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
            throw SafariumError.encode("LLHLSPackager: AVAssetReader failed: \(reader.error?.localizedDescription ?? "?")")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw SafariumError.encode("LLHLSPackager: AVAssetWriter failed: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            reader.cancelReading()
            writer.cancelWriting()
            throw SafariumError.encode("LLHLSPackager: pixelBufferPool unavailable")
        }

        var nextVideoSB: CMSampleBuffer? = autoreleasepool { videoOutput.copyNextSampleBuffer() }
        var nextAudioSB: CMSampleBuffer? = audioOutput.flatMap { out in
            autoreleasepool { out.copyNextSampleBuffer() }
        }
        let basePTS = nextVideoSB.map { CMSampleBufferGetPresentationTimeStamp($0) } ?? .zero

        var videoMarkedFinished = false
        var audioMarkedFinished = (audioInput == nil)
        var lastVideoPTS: CMTime?

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
                    throw SafariumError.encode("LLHLSPackager: writer failed: \(writer.error?.localizedDescription ?? "?")")
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
                var normPTS = CMTimeMaximum(.zero, CMTimeSubtract(rawPTS, basePTS))
                if let prev = lastVideoPTS, CMTimeCompare(normPTS, prev) <= 0 {
                    normPTS = CMTimeAdd(prev, CMTime(value: 1, timescale: 600))
                }

                let dstPB = try scaleOrCopyPixelBuffer(
                    src: srcPB,
                    pool: pool,
                    targetWidth: outW,
                    targetHeight: outH,
                    transferSession: transferSession,
                    ciContext: fallbackCIContext
                )
                if adaptor.append(dstPB, withPresentationTime: normPTS) {
                    lastVideoPTS = normPTS
                }
            } else if let asb = nextAudioSB, let aIn = audioInput {
                nextAudioSB = audioOutput.flatMap { out in autoreleasepool { out.copyNextSampleBuffer() } }
                let rawPTS = CMSampleBufferGetPresentationTimeStamp(asb)
                let normPTS = CMTimeSubtract(rawPTS, basePTS)
                if CMTimeCompare(normPTS, .zero) >= 0 {
                    var timing = CMSampleTimingInfo(
                        duration: CMSampleBufferGetDuration(asb),
                        presentationTimeStamp: normPTS,
                        decodeTimeStamp: .invalid
                    )
                    var shifted: CMSampleBuffer?
                    if CMSampleBufferCreateCopyWithNewTiming(
                        allocator: kCFAllocatorDefault,
                        sampleBuffer: asb,
                        sampleTimingEntryCount: 1,
                        sampleTimingArray: &timing,
                        sampleBufferOut: &shifted
                    ) == noErr, let shiftedSB = shifted {
                        _ = aIn.append(shiftedSB)
                    }
                }
            }
        }

        if !videoMarkedFinished { videoInput.markAsFinished() }
        if !audioMarkedFinished { audioInput?.markAsFinished() }

        await writer.finishWriting()
        reader.cancelReading()

        let snap = delegate.snapshot()
        if let err = snap.error {
            throw err
        }
        guard writer.status == .completed else {
            throw SafariumError.encode("LLHLSPackager: finishWriting failed: \(writer.error?.localizedDescription ?? "?")")
        }
        guard snap.initWritten, !snap.parts.isEmpty else {
            throw SafariumError.encode("LLHLSPackager: AVAssetWriter produced no CMAF initialization or partial segments")
        }

        // Group parts into full seg_XXXX.m4s parent segments (concatenating CMAF moof+mdat fragments).
        let segmentGroups = try buildFullSegments(
            from: snap.parts,
            targetSegmentDuration: options.segmentDurationSeconds,
            partDuration: partDur,
            outputDirectory: outputDirectory
        )

        let partInfos = snap.parts.map { $0.info }
        let maxObservedPartDur = partInfos.map { $0.durationSeconds }.max() ?? partDur
        let rawPartTarget = max(partDur, maxObservedPartDur)
        let partTarget = (rawPartTarget * 1000.0).rounded() / 1000.0
        // RFC 8216bis recommends PART-HOLD-BACK >= 3 * PART-TARGET (minimum 2 * PART-TARGET).
        let rawHoldBack = partTarget * 3.0
        let partHoldBack = (rawHoldBack * 1000.0).rounded() / 1000.0

        let maxSegDur = segmentGroups.map { $0.durationSeconds }.max() ?? options.segmentDurationSeconds
        let targetDurationInt = max(1, Int(ceil(maxSegDur)))

        // Write RFC 8216bis media playlist (`playlist.m3u8`).
        var mediaLines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(targetDurationInt)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            String(format: "#EXT-X-SERVER-CONTROL:CAN-BLOCK-RELOAD=YES,PART-HOLD-BACK=%.3f", partHoldBack),
            String(format: "#EXT-X-PART-INF:PART-TARGET=%.3f", partTarget),
            "#EXT-X-MAP:URI=\"init.mp4\"",
        ]

        for group in segmentGroups {
            for part in group.parts {
                let durStr = String(format: "%.3f", part.durationSeconds)
                if part.independent {
                    mediaLines.append("#EXT-X-PART:DURATION=\(durStr),URI=\"\(part.uri)\",INDEPENDENT=YES")
                } else {
                    mediaLines.append("#EXT-X-PART:DURATION=\(durStr),URI=\"\(part.uri)\"")
                }
            }
            mediaLines.append(String(format: "#EXTINF:%.3f,", group.durationSeconds))
            mediaLines.append(group.filename)
        }

        if options.includePreloadHint {
            let nextPartName = String(format: "part_%04d.m4s", partInfos.count)
            mediaLines.append("#EXT-X-PRELOAD-HINT:TYPE=PART,URI=\"\(nextPartName)\"")
        }
        if options.endList {
            mediaLines.append("#EXT-X-ENDLIST")
        }
        mediaLines.append("")

        let mediaPlaylistURL = outputDirectory.appendingPathComponent("playlist.m3u8")
        try Data(mediaLines.joined(separator: "\n").utf8).write(to: mediaPlaylistURL, options: .atomic)

        // Compute measured bandwidths and codec string for master.m3u8.
        let totalDur = segmentGroups.reduce(0.0) { $0 + $1.durationSeconds }
        let totalMediaBytes = segmentGroups.reduce(Int64(0)) { $0 + $1.bytes }
        let avgBandwidth: Int
        if totalDur > 0.05 && totalMediaBytes > 0 {
            let bps = (Double(totalMediaBytes) * 8.0) / totalDur
            avgBandwidth = max(1_000, Int(bps.rounded()))
        } else {
            avgBandwidth = max(1_000, options.bitrate)
        }
        var peakBandwidth = avgBandwidth
        for group in segmentGroups where group.durationSeconds > 0.05 && group.bytes > 0 {
            let segBps = (Double(group.bytes) * 8.0) / group.durationSeconds
            let segInt = Int(ceil(segBps))
            if segInt > peakBandwidth {
                peakBandwidth = segInt
            }
        }

        let videoCodecStr: String
        switch hlsCodec {
        case .h264: videoCodecStr = "avc1.640028"
        case .hevc10: videoCodecStr = "hvc1.2.4.L120.B0"
        default: videoCodecStr = "hvc1.1.6.L120.90"
        }
        let codecsAttr = hasMuxedAudio ? "\(videoCodecStr),mp4a.40.2" : videoCodecStr
        let fpsStr = String(format: "%.3f", effectiveFPS)

        let masterLines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-STREAM-INF:BANDWIDTH=\(peakBandwidth),AVERAGE-BANDWIDTH=\(avgBandwidth),RESOLUTION=\(outW)x\(outH),FRAME-RATE=\(fpsStr),CODECS=\"\(codecsAttr)\"",
            "playlist.m3u8",
            "",
        ]
        let masterPlaylistURL = outputDirectory.appendingPathComponent("master.m3u8")
        try Data(masterLines.joined(separator: "\n").utf8).write(to: masterPlaylistURL, options: .atomic)

        let initURL = outputDirectory.appendingPathComponent("init.mp4")
        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - t0
        let elapsedMs = (Double(elapsedNanos) / 1_000_000.0 * 100.0).rounded() / 100.0

        return LLHLSPackageResult(
            outputDirectory: outputDirectory.path,
            masterPlaylistPath: masterPlaylistURL.path,
            mediaPlaylistPath: mediaPlaylistURL.path,
            initSegmentPath: initURL.path,
            parts: partInfos,
            segments: segmentGroups.map { $0.filename },
            partTargetSeconds: partTarget,
            partHoldBackSeconds: partHoldBack,
            elapsedMs: elapsedMs
        )
    }

    // MARK: - RFC 8216bis LL-HLS Validator

    /// Validates an LL-HLS media playlist (`playlist.m3u8`) and its CMAF init/part/segment files
    /// against RFC 8216bis Low-Latency HLS rules.
    public static func validate(playlistURL: URL) -> LLHLSValidationReport {
        var violations: [String] = []

        guard FileManager.default.fileExists(atPath: playlistURL.path),
              let raw = try? String(contentsOf: playlistURL, encoding: .utf8) else {
            return LLHLSValidationReport(
                passed: false,
                partCount: 0,
                independentPartCount: 0,
                partTarget: 0.0,
                hasServerControl: false,
                hasPartInf: false,
                hasPreloadHint: false,
                violations: ["playlist file unreadable: \(playlistURL.path)"]
            )
        }

        let baseDir = playlistURL.deletingLastPathComponent()
        let lines = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if lines.first != "#EXTM3U" {
            violations.append("missing #EXTM3U header")
        }

        var hasVersion = false
        var hasTargetDuration = false
        var targetDurationValue: Double = 0.0
        var hasServerControl = false
        var serverControlHoldBack: Double? = nil
        var hasPartInf = false
        var partTarget: Double = 0.0
        var hasMap = false
        var hasPreloadHint = false

        var partCount = 0
        var independentPartCount = 0
        var partsInCurrentSegment = 0
        var independentInCurrentSegment = 0
        var pendingExtInfDur: Double? = nil

        for line in lines {
            if line.hasPrefix("#EXT-X-VERSION:") {
                hasVersion = true
                let valStr = String(line.dropFirst("#EXT-X-VERSION:".count))
                if let ver = Int(valStr), ver < 7 {
                    violations.append("LL-HLS CMAF requires #EXT-X-VERSION >= 7 (found \(ver))")
                }
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                hasTargetDuration = true
                let valStr = String(line.dropFirst("#EXT-X-TARGETDURATION:".count))
                targetDurationValue = Double(valStr) ?? 0.0
                if targetDurationValue <= 0 {
                    violations.append("invalid #EXT-X-TARGETDURATION: \(valStr)")
                }
            } else if line.hasPrefix("#EXT-X-SERVER-CONTROL:") {
                hasServerControl = true
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-SERVER-CONTROL:".count)))
                if let hbStr = attrs["PART-HOLD-BACK"], let hb = Double(hbStr) {
                    serverControlHoldBack = hb
                } else {
                    violations.append("#EXT-X-SERVER-CONTROL missing numeric PART-HOLD-BACK")
                }
            } else if line.hasPrefix("#EXT-X-PART-INF:") {
                hasPartInf = true
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-PART-INF:".count)))
                if let ptStr = attrs["PART-TARGET"], let pt = Double(ptStr), pt > 0 {
                    partTarget = pt
                } else {
                    violations.append("#EXT-X-PART-INF missing positive PART-TARGET")
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                hasMap = true
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-MAP:".count)))
                if let uri = attrs["URI"] {
                    let initURL = baseDir.appendingPathComponent(uri)
                    if let initData = try? Data(contentsOf: initURL), !initData.isEmpty {
                        let boxes = parseTopLevelBoxes(initData).map { $0.type }
                        if !boxes.contains("ftyp") || !boxes.contains("moov") {
                            violations.append("init segment \(uri) missing ftyp/moov boxes (found \(boxes.joined(separator: ",")))")
                        }
                    } else {
                        violations.append("init segment missing or empty: \(uri)")
                    }
                } else {
                    violations.append("#EXT-X-MAP missing URI attribute")
                }
            } else if line.hasPrefix("#EXT-X-PART:") {
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-PART:".count)))
                guard let uri = attrs["URI"], !uri.isEmpty else {
                    violations.append("#EXT-X-PART missing URI")
                    continue
                }
                guard let durStr = attrs["DURATION"], let dur = Double(durStr), dur > 0 else {
                    violations.append("#EXT-X-PART(\(uri)) missing positive DURATION")
                    continue
                }
                partCount += 1
                partsInCurrentSegment += 1

                let isIndep = (attrs["INDEPENDENT"]?.uppercased() == "YES")
                if isIndep {
                    independentPartCount += 1
                    independentInCurrentSegment += 1
                }

                if partTarget > 0 && dur > partTarget + 0.005 {
                    violations.append(
                        String(format: "part %@ duration %.3fs exceeds PART-TARGET %.3fs", uri, dur, partTarget)
                    )
                }

                let partURL = baseDir.appendingPathComponent(uri)
                if let partData = try? Data(contentsOf: partURL), !partData.isEmpty {
                    let boxTypes = parseTopLevelBoxes(partData).map { $0.type }
                    if !boxTypes.contains("moof") {
                        violations.append("part \(uri) missing CMAF moof box (boxes: \(boxTypes.joined(separator: ",")))")
                    }
                    if !boxTypes.contains("mdat") {
                        violations.append("part \(uri) missing CMAF mdat box")
                    }
                } else {
                    violations.append("part file missing or empty: \(uri)")
                }
            } else if line.hasPrefix("#EXT-X-PRELOAD-HINT:") {
                hasPreloadHint = true
                let attrs = parseAttributeList(String(line.dropFirst("#EXT-X-PRELOAD-HINT:".count)))
                if attrs["TYPE"] == nil || attrs["URI"] == nil {
                    violations.append("#EXT-X-PRELOAD-HINT missing TYPE or URI")
                }
            } else if line.hasPrefix("#EXTINF:") {
                let body = String(line.dropFirst("#EXTINF:".count))
                let durPart = body.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
                pendingExtInfDur = Double(durPart)
            } else if !line.hasPrefix("#") {
                // Media segment URI line
                let segURL = baseDir.appendingPathComponent(line)
                if let segData = try? Data(contentsOf: segURL), !segData.isEmpty {
                    let boxTypes = parseTopLevelBoxes(segData).map { $0.type }
                    if !boxTypes.contains("moof") {
                        violations.append("segment \(line) missing CMAF moof box")
                    }
                } else {
                    violations.append("segment file missing or empty: \(line)")
                }
                if let segDur = pendingExtInfDur, targetDurationValue > 0, segDur > targetDurationValue + 0.5 {
                    violations.append(
                        String(format: "segment %@ duration %.3fs exceeds TARGETDURATION %.0fs", line, segDur, targetDurationValue)
                    )
                }
                if partsInCurrentSegment > 0 && independentInCurrentSegment == 0 {
                    violations.append("segment \(line) has no INDEPENDENT=YES partial segments")
                }
                partsInCurrentSegment = 0
                independentInCurrentSegment = 0
                pendingExtInfDur = nil
            }
        }

        if !hasVersion { violations.append("missing #EXT-X-VERSION") }
        if !hasTargetDuration { violations.append("missing #EXT-X-TARGETDURATION") }
        if !hasServerControl { violations.append("missing #EXT-X-SERVER-CONTROL") }
        if !hasPartInf { violations.append("missing #EXT-X-PART-INF") }
        if !hasMap { violations.append("missing #EXT-X-MAP") }

        if let hb = serverControlHoldBack, partTarget > 0 {
            let minHoldBack = partTarget * 2.0
            if hb + 0.005 < minHoldBack {
                violations.append(
                    String(format: "PART-HOLD-BACK %.3fs must be >= 2 * PART-TARGET (%.3fs)", hb, minHoldBack)
                )
            }
        }
        if partCount == 0 {
            violations.append("playlist contains zero #EXT-X-PART entries")
        }
        if independentPartCount == 0 {
            violations.append("playlist contains zero INDEPENDENT=YES partial segments")
        }

        let passed = violations.isEmpty && hasServerControl && hasPartInf && partCount > 0 && independentPartCount > 0
        return LLHLSValidationReport(
            passed: passed,
            partCount: partCount,
            independentPartCount: independentPartCount,
            partTarget: partTarget,
            hasServerControl: hasServerControl,
            hasPartInf: hasPartInf,
            hasPreloadHint: hasPreloadHint,
            violations: violations
        )
    }

    // MARK: - Internal Helpers

    private static func buildFullSegments(
        from capturedParts: [CapturedPart],
        targetSegmentDuration: Double,
        partDuration: Double,
        outputDirectory: URL
    ) throws -> [SegmentGroup] {
        var groups: [SegmentGroup] = []
        var bucket: [CapturedPart] = []
        var bucketDur = 0.0
        let cutThreshold = max(partDuration * 0.5, targetSegmentDuration - (partDuration * 0.25))

        func flushBucket() throws {
            guard !bucket.isEmpty else { return }
            let segIndex = groups.count
            let segName = String(format: "seg_%04d.m4s", segIndex)
            let segURL = outputDirectory.appendingPathComponent(segName)

            var combined = Data()
            for (idx, part) in bucket.enumerated() {
                if idx == 0 {
                    combined.append(part.data)
                } else {
                    // Strip duplicate leading styp boxes from subsequent fragments in the same segment.
                    let boxes = parseTopLevelBoxes(part.data)
                    if boxes.isEmpty {
                        combined.append(part.data)
                    } else {
                        for box in boxes where box.type != "styp" {
                            combined.append(part.data.subdata(in: box.range))
                        }
                    }
                }
            }
            try combined.write(to: segURL, options: .atomic)
            let roundedDur = (bucketDur * 1000.0).rounded() / 1000.0
            groups.append(SegmentGroup(
                filename: segName,
                durationSeconds: roundedDur,
                parts: bucket.map { $0.info },
                bytes: Int64(combined.count)
            ))
            bucket.removeAll(keepingCapacity: true)
            bucketDur = 0.0
        }

        for part in capturedParts {
            bucket.append(part)
            bucketDur += part.info.durationSeconds
            if bucketDur >= cutThreshold {
                try flushBucket()
            }
        }
        try flushBucket()
        return groups
    }

    private static func scaleOrCopyPixelBuffer(
        src: CVPixelBuffer,
        pool: CVPixelBufferPool,
        targetWidth: Int,
        targetHeight: Int,
        transferSession: VTPixelTransferSession?,
        ciContext: CIContext
    ) throws -> CVPixelBuffer {
        var dstOpt: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dstOpt)
        guard status == kCVReturnSuccess, let dst = dstOpt else {
            throw SafariumError.encode("LLHLSPackager: CVPixelBufferPoolCreatePixelBuffer failed (\(status))")
        }
        if let ts = transferSession, VTPixelTransferSessionTransferImage(ts, from: src, to: dst) == noErr {
            return dst
        }
        let srcW = CVPixelBufferGetWidth(src)
        let srcH = CVPixelBufferGetHeight(src)
        let scaleX = srcW > 0 ? (CGFloat(targetWidth) / CGFloat(srcW)) : 1.0
        let scaleY = srcH > 0 ? (CGFloat(targetHeight) / CGFloat(srcH)) : 1.0
        let ciImage = CIImage(cvPixelBuffer: src)
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        ciContext.render(ciImage, to: dst)
        return dst
    }

    /// Parses top-level ISOBMFF / CMAF box types and byte ranges.
    static func parseTopLevelBoxes(_ data: Data) -> [(type: String, range: Range<Int>)] {
        var result: [(type: String, range: Range<Int>)] = []
        let total = data.count
        var offset = 0

        while offset + 8 <= total {
            let b0 = UInt64(data[offset])
            let b1 = UInt64(data[offset + 1])
            let b2 = UInt64(data[offset + 2])
            let b3 = UInt64(data[offset + 3])
            var boxSize: UInt64 = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3

            let typeBytes = [data[offset + 4], data[offset + 5], data[offset + 6], data[offset + 7]]
            let boxType = String(bytes: typeBytes, encoding: .isoLatin1) ?? "????"

            if boxSize == 1 {
                guard offset + 16 <= total else { break }
                var extSize: UInt64 = 0
                for i in 0..<8 {
                    extSize = (extSize << 8) | UInt64(data[offset + 8 + i])
                }
                boxSize = extSize
            } else if boxSize == 0 {
                boxSize = UInt64(total - offset)
            }

            guard boxSize >= 8 else { break }
            let intSize = Int(min(boxSize, UInt64(total - offset)))
            let endOffset = offset + intSize
            result.append((type: boxType, range: offset..<endOffset))
            offset = endOffset
        }

        return result
    }

    /// Parses RFC 8216 HLS attribute lists (`KEY=VALUE,KEY2="QUOTED,VALUE"`).
    private static func parseAttributeList(_ raw: String) -> [String: String] {
        var attrs: [String: String] = [:]
        var idx = raw.startIndex
        let end = raw.endIndex

        while idx < end {
            while idx < end && (raw[idx] == " " || raw[idx] == ",") {
                idx = raw.index(after: idx)
            }
            if idx >= end { break }

            let keyStart = idx
            while idx < end && raw[idx] != "=" && raw[idx] != "," {
                idx = raw.index(after: idx)
            }
            let key = String(raw[keyStart..<idx]).trimmingCharacters(in: .whitespaces).uppercased()
            guard idx < end && raw[idx] == "=" else { break }
            idx = raw.index(after: idx)

            let value: String
            if idx < end && raw[idx] == "\"" {
                idx = raw.index(after: idx)
                let valStart = idx
                while idx < end && raw[idx] != "\"" {
                    idx = raw.index(after: idx)
                }
                value = String(raw[valStart..<idx])
                if idx < end { idx = raw.index(after: idx) }
            } else {
                let valStart = idx
                while idx < end && raw[idx] != "," {
                    idx = raw.index(after: idx)
                }
                value = String(raw[valStart..<idx]).trimmingCharacters(in: .whitespaces)
            }
            if !key.isEmpty {
                attrs[key] = value
            }
        }
        return attrs
    }
}
