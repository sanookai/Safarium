import Accelerate
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - Safe Atomic Publishing

package enum SafeFilePublisher {
    /// Returns `true` only when `getattrlist` positively confirms the target filesystem does not enforce POSIX permissions (e.g., ExFAT).
    /// Fails closed to `false` on APFS or any query error.
    package static func volumeHasNoPermissions(at dirPath: String) -> Bool {
        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        struct CapBuf {
            var length: UInt32 = 0
            var caps: vol_capabilities_attr_t = vol_capabilities_attr_t()
        }
        var buf = CapBuf()
        guard getattrlist(dirPath, &al, &buf, MemoryLayout<CapBuf>.size, 0) == 0 else {
            return false
        }
        let flag = UInt32(VOL_CAP_FMT_NO_PERMISSIONS)
        return (buf.caps.valid.0 & flag) != 0 && (buf.caps.capabilities.0 & flag) != 0
    }

    /// Publishes `tempURL` to `outputURL`, preserving `RENAME_EXCL` on APFS while falling back cleanly on ExFAT (`ENOTSUP`/`ENOSYS`).
    /// Returns `0` on success, or POSIX `errno` on failure.
    package static func exclusiveOrAtomicPublish(tempURL: URL, to outputURL: URL, overwrite: Bool) -> Int32 {
        let flags: UInt32 = overwrite ? 0 : UInt32(RENAME_EXCL)
        if renamex_np(tempURL.path, outputURL.path, flags) == 0 {
            return 0
        }
        let code = errno
        guard code == ENOTSUP || code == ENOSYS else {
            return code
        }
        if overwrite {
            return Darwin.rename(tempURL.path, outputURL.path) == 0 ? 0 : errno
        }
        let fd = Darwin.open(outputURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        if fd < 0 {
            return errno
        }
        _ = Darwin.close(fd)
        if Darwin.rename(tempURL.path, outputURL.path) == 0 {
            return 0
        }
        let renErr = errno
        _ = Darwin.unlink(outputURL.path)
        return renErr
    }

    package static func assertRegularReadableFile(_ url: URL) throws {
        var st = stat()
        guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw SafariumError.invalidState("input is not a readable regular file: \(url.path)")
        }
    }

    package final class Staging {
        package let directory: URL

        package init(beside outputURL: URL) throws {
            let parent = outputURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let dir = parent.appendingPathComponent(".safarium-stage-\(UUID().uuidString)", isDirectory: true)
            guard mkdir(dir.path, 0o700) == 0 else {
                let code = errno
                throw SafariumError.encode("cannot create staging directory beside output: \(String(cString: strerror(code)))")
            }
            _ = chmod(dir.path, 0o700)
            var st = stat()
            guard lstat(dir.path, &st) == 0,
                  (st.st_mode & S_IFMT) == S_IFDIR,
                  st.st_uid == getuid(),
                  ((st.st_mode & 0o777) == 0o700 || SafeFilePublisher.volumeHasNoPermissions(at: parent.path)) else {
                try? FileManager.default.removeItem(at: dir)
                throw SafariumError.invalidState("output volume must support a private (0700) staging directory")
            }
            self.directory = dir
        }

        package func fileURL(_ name: String) -> URL {
            directory.appendingPathComponent(name)
        }

        package func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }

        deinit {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    package static func preflight(outputURL: URL, overwrite: Bool) throws {
        var st = stat()
        if lstat(outputURL.path, &st) == 0 && !overwrite {
            throw SafariumError.invalidState("output already exists (pass --overwrite to replace): \(outputURL.path)")
        }
        let parent = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    package static func makeTempURL(beside outputURL: URL, ext: String? = nil) -> URL {
        let dir = outputURL.deletingLastPathComponent()
        let suffix = ext ?? outputURL.pathExtension
        let name = ".\(outputURL.lastPathComponent).safarium-\(UUID().uuidString)\(suffix.isEmpty ? "" : ".\(suffix)")"
        return dir.appendingPathComponent(name)
    }

    package static func publish(tempURL: URL, to outputURL: URL, overwrite: Bool) throws {
        let err = exclusiveOrAtomicPublish(tempURL: tempURL, to: outputURL, overwrite: overwrite)
        if err != 0 {
            try? FileManager.default.removeItem(at: tempURL)
            throw SafariumError.encode("could not publish output \(outputURL.path): \(String(cString: strerror(err)))")
        }
    }
}

// MARK: - Reports

public struct AudioExtractReport: Codable, Sendable {
    public let inputPath: String
    public let outputPath: String
    public let format: String
    public let sampleRate: Int
    public let channels: Int
    public let durationSeconds: Double
    public let sampleCount: Int64
    public let rms: Double
    public let lufs: Double
    public let peakLinear: Float
}

public struct AudioMixTrack: Codable, Sendable {
    public let url: URL
    public var gainDB: Double
    public var startSeconds: Double
    public var loop: Bool

    public init(url: URL, gainDB: Double = 0, startSeconds: Double = 0, loop: Bool = false) {
        self.url = url
        self.gainDB = gainDB
        self.startSeconds = startSeconds
        self.loop = loop
    }
}

public struct AudioMixReport: Codable, Sendable {
    public let trackCount: Int
    public let outputPath: String
    public let format: String
    public let sampleRate: Int
    public let channels: Int
    public let durationSeconds: Double
    public let normalizedTargetLUFS: Double?
    public let measuredInputLUFS: Double
    public let outputLUFS: Double
    public let truePeakDBTP: Double
    public let peakLinear: Float
    public let appliedGainDB: Double
}

public struct GIFWriteReport: Codable, Sendable {
    public let inputPath: String
    public let outputPath: String
    public let frames: Int
    public let fps: Int
    public let width: Int
    public let height: Int
    public let loopCount: Int
    public let fileSizeBytes: Int64
}

public struct SubjectCutoutReport: Codable, Sendable {
    public let inputPath: String
    public let outputPath: String
    public let kind: String
    public let frames: Int
    public let width: Int
    public let height: Int
    public let instanceCount: Int
    public let foregroundCoveragePercent: Double
}

// MARK: - Internal Streaming Audio Helpers

private enum AudioOutputKind: String {
    case wav, m4a

    init(outputURL: URL) throws {
        switch outputURL.pathExtension.lowercased() {
        case "wav": self = .wav
        case "m4a": self = .m4a
        default: throw SafariumError.invalidState("unsupported audio output extension (expected .wav or .m4a): \(outputURL.lastPathComponent)")
        }
    }
}

private final class StreamingAudioSink {
    let kind: AudioOutputKind
    let sampleRate: Int
    let channels: Int
    private let pcmFormat: AVAudioFormat
    private var wavFile: AVAudioFile?
    private var wavBuffer: AVAudioPCMBuffer?
    private let m4aWriter: AVAssetWriter?
    private let m4aInput: AVAssetWriterInput?
    private var writtenFrames: Int64 = 0

    init(tempURL: URL, kind: AudioOutputKind, sampleRate: Int, channels: Int, bitrate: Int, wavBitDepth: Int = 16) throws {
        guard wavBitDepth == 16 || wavBitDepth == 24 else {
            throw SafariumError.invalidState("wavBitDepth must be 16 or 24, got \(wavBitDepth)")
        }
        self.kind = kind
        self.sampleRate = sampleRate
        self.channels = channels
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            throw SafariumError.encode("unsupported audio format \(sampleRate) Hz \(channels) ch")
        }
        self.pcmFormat = fmt

        switch kind {
        case .wav:
            let wavSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Double(sampleRate),
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: wavBitDepth,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            self.wavFile = try AVAudioFile(
                forWriting: tempURL,
                settings: wavSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: true
            )
            self.wavBuffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096)
            self.m4aWriter = nil
            self.m4aInput = nil
        case .m4a:
            let writer = try AVAssetWriter(url: tempURL, fileType: .m4a)
            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitrate,
            ]
            guard writer.canApply(outputSettings: aacSettings, forMediaType: .audio) else {
                throw SafariumError.encode("Apple AAC cannot encode \(sampleRate) Hz \(channels) ch at \(bitrate) bps")
            }
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: aacSettings,
                sourceFormatHint: fmt.formatDescription
            )
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw SafariumError.encode("cannot add M4A audio writer input")
            }
            writer.add(input)
            guard writer.startWriting() else {
                throw SafariumError.encode("M4A startWriting failed: \(writer.error?.localizedDescription ?? "?")")
            }
            writer.startSession(atSourceTime: .zero)
            self.wavFile = nil
            self.wavBuffer = nil
            self.m4aWriter = writer
            self.m4aInput = input
        }
    }

    func append(interleavedFrames frames: UnsafePointer<Float>, frameCount: Int) async throws {
        guard frameCount > 0 else { return }
        switch kind {
        case .wav:
            guard let wavFile, let wavBuffer else { return }
            var offset = 0
            while offset < frameCount {
                let take = min(Int(wavBuffer.frameCapacity), frameCount - offset)
                wavBuffer.frameLength = AVAudioFrameCount(take)
                let bytes = take * channels * MemoryLayout<Float>.size
                guard let dst = wavBuffer.audioBufferList.pointee.mBuffers.mData else {
                    throw SafariumError.encode("missing WAV buffer data")
                }
                _ = memcpy(dst, frames.advanced(by: offset * channels), bytes)
                try wavFile.write(from: wavBuffer)
                offset += take
            }
            writtenFrames += Int64(frameCount)
        case .m4a:
            guard let m4aWriter, let m4aInput else { return }
            while !m4aInput.isReadyForMoreMediaData {
                if m4aWriter.status != .writing {
                    throw SafariumError.encode("M4A writer stopped: \(m4aWriter.error?.localizedDescription ?? "?")")
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let bytes = frameCount * channels * MemoryLayout<Float>.size
            var block: CMBlockBuffer?
            let st1 = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: bytes,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: bytes,
                flags: 0,
                blockBufferOut: &block
            )
            guard st1 == noErr, let block else {
                throw SafariumError.encode("CMBlockBuffer alloc failed (\(st1))")
            }
            let st2 = CMBlockBufferReplaceDataBytes(
                with: frames,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: bytes
            )
            guard st2 == noErr else {
                throw SafariumError.encode("CMBlockBuffer copy failed (\(st2))")
            }
            var sample: CMSampleBuffer?
            let pts = CMTime(value: writtenFrames, timescale: Int32(sampleRate))
            let st3 = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: block,
                formatDescription: pcmFormat.formatDescription,
                sampleCount: frameCount,
                presentationTimeStamp: pts,
                packetDescriptions: nil,
                sampleBufferOut: &sample
            )
            guard st3 == noErr, let sample else {
                throw SafariumError.encode("CMAudioSampleBuffer create failed (\(st3))")
            }
            guard m4aInput.append(sample) else {
                throw SafariumError.encode("M4A append failed: \(m4aWriter.error?.localizedDescription ?? "?")")
            }
            writtenFrames += Int64(frameCount)
        }
    }

    func finish() async throws {
        if kind == .wav {
            #if compiler(>=6.0)
            if #available(macOS 15.0, *) {
                wavFile?.close()
            }
            #endif
            wavFile = nil
            wavBuffer = nil
        }
        if let m4aWriter, let m4aInput {
            m4aInput.markAsFinished()
            m4aWriter.endSession(atSourceTime: CMTime(value: writtenFrames, timescale: Int32(sampleRate)))
            await m4aWriter.finishWriting()
            guard m4aWriter.status == .completed else {
                throw SafariumError.encode("M4A finishWriting failed: \(m4aWriter.error?.localizedDescription ?? "?")")
            }
        }
    }

    func cancel() {
        wavFile = nil
        wavBuffer = nil
        if let m4aWriter, m4aWriter.status == .writing {
            m4aWriter.cancelWriting()
        }
    }
}

private func makePCMReader(
    asset: AVURLAsset,
    track: AVAssetTrack,
    timeRange: CMTimeRange?,
    sampleRate: Double,
    channels: Int
) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
    let reader = try AVAssetReader(asset: asset)
    if let timeRange {
        reader.timeRange = timeRange
    }
    let outSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: outSettings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
        throw SafariumError.encode("AVAssetReader cannot read audio track at \(Int(sampleRate)) Hz \(channels) ch")
    }
    reader.add(output)
    guard reader.startReading() else {
        throw SafariumError.encode("AVAssetReader audio startReading failed: \(reader.error?.localizedDescription ?? "?")")
    }
    return (reader, output)
}

private func copyFloatSamples(from sample: CMSampleBuffer, into scratch: inout [Float], channels: Int) throws -> Int {
    guard CMSampleBufferGetNumSamples(sample) > 0,
          let block = CMSampleBufferGetDataBuffer(sample) else { return 0 }
    let byteLen = CMBlockBufferGetDataLength(block)
    let stride = MemoryLayout<Float>.size * max(1, channels)
    guard byteLen > 0, byteLen % stride == 0 else {
        throw SafariumError.encode("unexpected audio sample buffer byte length \(byteLen)")
    }
    let floatCount = byteLen / MemoryLayout<Float>.size
    if scratch.count < floatCount {
        scratch = [Float](repeating: 0, count: floatCount)
    }
    let err = scratch.withUnsafeMutableBytes { raw in
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: floatCount * MemoryLayout<Float>.size, destination: raw.baseAddress!)
    }
    guard err == noErr else {
        throw SafariumError.encode("CMBlockBufferCopyDataBytes failed (\(err))")
    }
    return floatCount / max(1, channels)
}

// MARK: - AudioExtractor

public enum AudioExtractor {
    public static func extract(
        from inputURL: URL,
        to outputURL: URL,
        startSeconds: Double = 0,
        durationSeconds: Double? = nil,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        bitrate: Int = 192_000,
        overwrite: Bool = false
    ) async throws -> AudioExtractReport {
        try SafeFilePublisher.assertRegularReadableFile(inputURL)
        guard sampleRate.isFinite, sampleRate > 0, let intRate = Int(exactly: sampleRate.rounded()) else {
            throw SafariumError.invalidState("invalid sampleRate \(sampleRate)")
        }
        guard (1...2).contains(channels) else {
            throw SafariumError.invalidState("channels must be 1 or 2")
        }
        guard bitrate > 0 else {
            throw SafariumError.invalidState("bitrate must be > 0")
        }
        guard startSeconds.isFinite, startSeconds >= 0 else {
            throw SafariumError.invalidState("startSeconds must be >= 0")
        }
        if let d = durationSeconds {
            guard d.isFinite, d > 0 else { throw SafariumError.invalidState("durationSeconds must be > 0") }
        }

        let kind = try AudioOutputKind(outputURL: outputURL)
        try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)

        let asset = AVURLAsset(url: inputURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        ])
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = tracks.first else {
            throw SafariumError.invalidState("no audio track found in \(inputURL.lastPathComponent)")
        }
        let assetDur = try await asset.load(.duration).seconds
        guard assetDur.isFinite, assetDur > 0, startSeconds < assetDur else {
            throw SafariumError.invalidState("startSeconds \(startSeconds) beyond media duration \(assetDur)")
        }
        let effectiveDur = min(durationSeconds ?? (assetDur - startSeconds), assetDur - startSeconds)
        let range = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600_000),
            duration: CMTime(seconds: effectiveDur, preferredTimescale: 600_000)
        )

        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }
        let tempURL = staging.fileURL("out.\(kind.rawValue)")
        let sink = try StreamingAudioSink(tempURL: tempURL, kind: kind, sampleRate: intRate, channels: channels, bitrate: bitrate)
        let (reader, output) = try makePCMReader(asset: asset, track: audioTrack, timeRange: range, sampleRate: sampleRate, channels: channels)
        let meter = try LoudnessMeter(sampleRate: sampleRate, channels: channels)

        var scratch = [Float](repeating: 0, count: 8192 * channels)
        do {
            while let sb = autoreleasepool(invoking: { output.copyNextSampleBuffer() }) {
                let frameCount = try copyFloatSamples(from: sb, into: &scratch, channels: channels)
                if frameCount > 0 {
                    scratch.withUnsafeBufferPointer { ptr in
                        let sub = UnsafeBufferPointer(start: ptr.baseAddress, count: frameCount * channels)
                        meter.processInterleaved(sub)
                    }
                    try await sink.append(interleavedFrames: scratch, frameCount: frameCount)
                }
            }
            if reader.status == .failed {
                throw SafariumError.encode("audio read failed: \(reader.error?.localizedDescription ?? "?")")
            }
            guard meter.processedFrames > 0 else {
                throw SafariumError.encode("no audio samples decoded from \(inputURL.lastPathComponent)")
            }
            try await sink.finish()
            try SafeFilePublisher.publish(tempURL: tempURL, to: outputURL, overwrite: overwrite)
        } catch {
            reader.cancelReading()
            sink.cancel()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        return AudioExtractReport(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            format: kind.rawValue,
            sampleRate: intRate,
            channels: channels,
            durationSeconds: Double(meter.processedFrames) / Double(intRate),
            sampleCount: meter.processedFrames,
            rms: meter.rms,
            lufs: meter.gatedLUFS,
            peakLinear: meter.peakLinear
        )
    }
}

// MARK: - AudioMixer

private final class TrackStreamCursor {
    let url: URL
    let asset: AVURLAsset
    let track: AVAssetTrack
    let gainLinear: Float
    let startFrame: Int64
    let loop: Bool
    let sampleRate: Double
    let channels: Int

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var staging: [Float] = []
    private var stagingOffset = 0 // in floats
    private var eofReached = false
    private var scratch: [Float] = [Float](repeating: 0, count: 4096 * 2)

    init(info: AudioMixTrack, asset: AVURLAsset, track: AVAssetTrack, sampleRate: Double, channels: Int) {
        self.url = info.url
        self.asset = asset
        self.track = track
        self.gainLinear = powf(10.0, Float(info.gainDB) / 20.0)
        self.startFrame = max(0, Int64((info.startSeconds * sampleRate).rounded()))
        self.loop = info.loop
        self.sampleRate = sampleRate
        self.channels = channels
    }

    func close() {
        reader?.cancelReading()
        reader = nil
        output = nil
        staging.removeAll(keepingCapacity: true)
        stagingOffset = 0
        eofReached = false
    }

    private func ensureReaderOpen() throws {
        if reader != nil { return }
        let (r, o) = try makePCMReader(asset: asset, track: track, timeRange: nil, sampleRate: sampleRate, channels: channels)
        reader = r
        output = o
        eofReached = false
    }

    private func refill() throws -> Bool {
        while stagingOffset * 2 > staging.count && stagingOffset > 0 {
            staging.removeFirst(stagingOffset)
            stagingOffset = 0
        }
        try ensureReaderOpen()
        guard let output else { return false }
        if let sb = autoreleasepool(invoking: { output.copyNextSampleBuffer() }) {
            let nFrames = try copyFloatSamples(from: sb, into: &scratch, channels: channels)
            if nFrames > 0 {
                staging.append(contentsOf: scratch[0..<(nFrames * channels)])
                return true
            }
            return try refill()
        }
        if reader?.status == .failed {
            throw SafariumError.encode("mix track read failed (\(url.lastPathComponent)): \(reader?.error?.localizedDescription ?? "?")")
        }
        if loop {
            reader?.cancelReading()
            reader = nil
            self.output = nil
            try ensureReaderOpen()
            if let sb = autoreleasepool(invoking: { self.output?.copyNextSampleBuffer() }) {
                let nFrames = try copyFloatSamples(from: sb, into: &scratch, channels: channels)
                if nFrames > 0 {
                    staging.append(contentsOf: scratch[0..<(nFrames * channels)])
                    return true
                }
            }
        }
        eofReached = true
        return false
    }

    /// Accumulates active frames for timeline range `[blockStartFrame, blockStartFrame + frameCount)`.
    func mixInto(dest: UnsafeMutablePointer<Float>, blockStartFrame: Int64, frameCount: Int) throws {
        let blockEnd = blockStartFrame + Int64(frameCount)
        if blockEnd <= startFrame { return }
        if eofReached && !loop && stagingOffset >= staging.count { return }

        let destFrameOffset = Int(max(0, startFrame - blockStartFrame))
        var framesRemaining = frameCount - destFrameOffset
        var dstFloatOffset = destFrameOffset * channels

        while framesRemaining > 0 {
            let availFloats = staging.count - stagingOffset
            let availFrames = availFloats / channels
            if availFrames == 0 {
                if eofReached { break }
                let gotMore = try refill()
                if !gotMore { break }
                continue
            }
            let takeFrames = min(framesRemaining, availFrames)
            let takeFloats = takeFrames * channels
            var g = gainLinear
            staging.withUnsafeBufferPointer { srcPtr in
                vDSP_vsma(srcPtr.baseAddress! + stagingOffset, 1, &g, dest + dstFloatOffset, 1, dest + dstFloatOffset, 1, vDSP_Length(takeFloats))
            }
            stagingOffset += takeFloats
            dstFloatOffset += takeFloats
            framesRemaining -= takeFrames
        }
    }
}

public enum AudioMixer {
    private static let materializerLock = NSLock()
    private static var _legacyAudioMaterializer: (@Sendable (_ sourceURL: URL, _ stagingDir: URL, _ sampleRate: Double, _ channels: Int) throws -> URL?)?

    package static var legacyAudioMaterializer: (@Sendable (_ sourceURL: URL, _ stagingDir: URL, _ sampleRate: Double, _ channels: Int) throws -> URL?)? {
        get { materializerLock.withLock { _legacyAudioMaterializer } }
        set { materializerLock.withLock { _legacyAudioMaterializer = newValue } }
    }

    public static func mix(
        tracks: [AudioMixTrack],
        to outputURL: URL,
        durationSeconds: Double? = nil,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        bitrate: Int = 192_000,
        normalizeLUFS: Double? = nil,
        peakCeilingDBTP: Double = -1.05,
        wavBitDepth: Int = 16,
        overwrite: Bool = false
    ) async throws -> AudioMixReport {
        guard !tracks.isEmpty else { throw SafariumError.invalidState("mix requires at least one track") }
        guard sampleRate.isFinite, sampleRate > 0, let intRate = Int(exactly: sampleRate.rounded()) else {
            throw SafariumError.invalidState("invalid sampleRate \(sampleRate)")
        }
        guard (1...2).contains(channels) else { throw SafariumError.invalidState("channels must be 1 or 2") }
        guard bitrate > 0 else { throw SafariumError.invalidState("bitrate must be > 0") }
        if let d = durationSeconds {
            guard d.isFinite, d > 0 else { throw SafariumError.invalidState("durationSeconds must be > 0") }
        }
        if let target = normalizeLUFS {
            guard target.isFinite, target <= 0, target >= -60 else {
                throw SafariumError.invalidState("normalizeLUFS must be between -60 and 0 LUFS")
            }
        }
        guard peakCeilingDBTP.isFinite, peakCeilingDBTP <= 0, peakCeilingDBTP >= -24 else {
            throw SafariumError.invalidState("peakCeilingDBTP must be between -24 and 0 dBTP")
        }
        guard wavBitDepth == 16 || wavBitDepth == 24 else {
            throw SafariumError.invalidState("wavBitDepth must be 16 or 24")
        }
        let kind = try AudioOutputKind(outputURL: outputURL)
        try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)

        var legacyTempDir: URL?
        defer {
            if let legacyTempDir {
                try? FileManager.default.removeItem(at: legacyTempDir)
            }
        }

        var resolvedTracks: [(AudioMixTrack, AVURLAsset, AVAssetTrack, Double)] = []
        for t in tracks {
            try SafeFilePublisher.assertRegularReadableFile(t.url)
            guard t.gainDB.isFinite else {
                throw SafariumError.invalidState("track gainDB must be finite")
            }
            guard t.startSeconds.isFinite, t.startSeconds >= 0 else {
                throw SafariumError.invalidState("track startSeconds must be >= 0")
            }
            var trackInfo = t
            let ext = t.url.pathExtension.lowercased()
            if ["ogg", "oga", "opus", "mpeg", "mpg"].contains(ext), let mat = Self.legacyAudioMaterializer {
                if legacyTempDir == nil {
                    let d = FileManager.default.temporaryDirectory
                        .appendingPathComponent("safarium-mix-compat-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
                    legacyTempDir = d
                }
                if let matURL = try mat(t.url, legacyTempDir!, sampleRate, channels) {
                    trackInfo = AudioMixTrack(url: matURL, gainDB: t.gainDB, startSeconds: t.startSeconds, loop: t.loop)
                }
            }
            let asset = AVURLAsset(url: trackInfo.url, options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true,
                AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
            ])
            guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                throw SafariumError.invalidState("no audio track in \(t.url.lastPathComponent)")
            }
            let d = try await asset.load(.duration).seconds
            guard d.isFinite, d > 0 else {
                throw SafariumError.invalidState("empty audio track \(t.url.lastPathComponent)")
            }
            resolvedTracks.append((trackInfo, asset, audioTrack, d))
        }

        let nonLoopedEnd = resolvedTracks.filter { !$0.0.loop }.map { $0.0.startSeconds + $0.3 }.max()
        let anyEnd = resolvedTracks.map { $0.0.startSeconds + $0.3 }.max() ?? 0.0
        let computedDur = nonLoopedEnd ?? anyEnd
        let targetDur = durationSeconds ?? computedDur
        let totalFrames = Int64((targetDur * sampleRate).rounded())
        guard totalFrames > 0 else { throw SafariumError.invalidState("mix duration yields 0 frames") }

        let blockFrames = 4096
        var mixBuf = [Float](repeating: 0, count: blockFrames * channels)
        var normGainDB = 0.0
        var measuredInputLUFS = -Double.infinity

        // Pass 1: measure integrated K-weighted LUFS in bounded 4096-frame blocks when normalization is requested.
        if let targetLUFS = normalizeLUFS {
            let cursors = resolvedTracks.map { TrackStreamCursor(info: $0.0, asset: $0.1, track: $0.2, sampleRate: sampleRate, channels: channels) }
            defer { cursors.forEach { $0.close() } }
            let pass1Meter = try LoudnessMeter(sampleRate: sampleRate, channels: channels)
            var framePos: Int64 = 0
            while framePos < totalFrames {
                let take = Int(min(Int64(blockFrames), totalFrames - framePos))
                try mixBuf.withUnsafeMutableBufferPointer { buf in
                    vDSP_vclr(buf.baseAddress!, 1, vDSP_Length(take * channels))
                    for c in cursors {
                        try c.mixInto(dest: buf.baseAddress!, blockStartFrame: framePos, frameCount: take)
                    }
                    pass1Meter.processInterleaved(UnsafeBufferPointer(start: buf.baseAddress, count: take * channels))
                }
                framePos += Int64(take)
            }
            measuredInputLUFS = pass1Meter.gatedLUFS
            if measuredInputLUFS.isFinite {
                normGainDB = targetLUFS - measuredInputLUFS
            }
        }

        // Pass 2 (or single pass when normalizeLUFS == nil): mix + apply norm gain + true-peak limiter + encode atomically.
        let normGainLinear = powf(10.0, Float(normGainDB) / 20.0)
        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }
        let tempURL = staging.fileURL("out.\(kind.rawValue)")
        let sink = try StreamingAudioSink(tempURL: tempURL, kind: kind, sampleRate: intRate, channels: channels, bitrate: bitrate, wavBitDepth: wavBitDepth)
        let cursors = resolvedTracks.map { TrackStreamCursor(info: $0.0, asset: $0.1, track: $0.2, sampleRate: sampleRate, channels: channels) }
        defer { cursors.forEach { $0.close() } }
        let outMeter = try LoudnessMeter(sampleRate: sampleRate, channels: channels)
        let limiter = try OfflinePeakLimiter(sampleRate: sampleRate, channels: channels, ceilingDBTP: peakCeilingDBTP, oversampled4xTruePeak: true)
        let latencyFrames = Int64(limiter.latencyFrames)

        do {
            var framePos: Int64 = 0
            var discardedLatency: Int64 = 0
            var outBuf = [Float](repeating: 0, count: blockFrames * channels)
            while framePos < totalFrames + latencyFrames {
                let take = Int(min(Int64(blockFrames), (totalFrames + latencyFrames) - framePos))
                let mixTake = framePos < totalFrames ? Int(min(Int64(take), totalFrames - framePos)) : 0
                let sampleCount = take * channels
                try mixBuf.withUnsafeMutableBufferPointer { buf in
                    vDSP_vclr(buf.baseAddress!, 1, vDSP_Length(sampleCount))
                    if mixTake > 0 {
                        for c in cursors {
                            try c.mixInto(dest: buf.baseAddress!, blockStartFrame: framePos, frameCount: mixTake)
                        }
                        if normalizeLUFS != nil {
                            var g = normGainLinear
                            vDSP_vsmul(buf.baseAddress!, 1, &g, buf.baseAddress!, 1, vDSP_Length(mixTake * channels))
                        }
                    }
                    try limiter.processBlock(interleaved: buf.baseAddress!, frameCount: take)
                }

                var dropFrames = 0
                if discardedLatency < latencyFrames {
                    dropFrames = Int(min(Int64(take), latencyFrames - discardedLatency))
                    discardedLatency += Int64(dropFrames)
                }
                let validFrames = take - dropFrames
                if validFrames > 0 {
                    let validSamples = validFrames * channels
                    let startSample = dropFrames * channels
                    mixBuf.withUnsafeBufferPointer { src in
                        outBuf.withUnsafeMutableBufferPointer { dst in
                            _ = memcpy(dst.baseAddress!, src.baseAddress!.advanced(by: startSample), validSamples * 4)
                            outMeter.processInterleaved(UnsafeBufferPointer(start: dst.baseAddress, count: validSamples))
                        }
                    }
                    try await sink.append(interleavedFrames: outBuf, frameCount: validFrames)
                }
                framePos += Int64(take)
            }
            if normalizeLUFS == nil {
                measuredInputLUFS = outMeter.gatedLUFS
            }
            try await sink.finish()
            try SafeFilePublisher.publish(tempURL: tempURL, to: outputURL, overwrite: overwrite)
        } catch {
            sink.cancel()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        return AudioMixReport(
            trackCount: tracks.count,
            outputPath: outputURL.path,
            format: kind.rawValue,
            sampleRate: intRate,
            channels: channels,
            durationSeconds: Double(totalFrames) / Double(intRate),
            normalizedTargetLUFS: normalizeLUFS,
            measuredInputLUFS: measuredInputLUFS,
            outputLUFS: outMeter.gatedLUFS,
            truePeakDBTP: outMeter.truePeakDBTP,
            peakLinear: outMeter.peakLinear,
            appliedGainDB: normGainDB
        )
    }
}

// MARK: - GIFWriter

public enum GIFWriter {
    public static func convert(
        from inputURL: URL,
        to outputURL: URL,
        fps: Int = 15,
        maxWidth: Int? = nil,
        startSeconds: Double = 0,
        durationSeconds: Double? = nil,
        loopCount: Int = 0,
        overwrite: Bool = false
    ) async throws -> GIFWriteReport {
        guard outputURL.pathExtension.lowercased() == "gif" else {
            throw SafariumError.invalidState("GIF output must end with .gif: \(outputURL.lastPathComponent)")
        }
        guard (1...60).contains(fps) else {
            throw SafariumError.invalidState("GIF fps must be in 1...60")
        }
        if let mw = maxWidth {
            guard (1...8192).contains(mw) else {
                throw SafariumError.invalidState("maxWidth must be in 1...8192")
            }
        }
        guard loopCount >= 0 else { throw SafariumError.invalidState("loopCount must be >= 0") }
        guard startSeconds.isFinite, startSeconds >= 0 else {
            throw SafariumError.invalidState("startSeconds must be >= 0")
        }
        try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)

        let reader = try await SafariumSequentialVideoReader(
            url: inputURL, loop: false, startTimeOffset: startSeconds, pixelFormat: kCVPixelFormatType_32BGRA
        )
        defer { reader.close() }

        guard startSeconds < reader.durationSeconds else {
            throw SafariumError.invalidState("startSeconds \(startSeconds) >= video duration \(reader.durationSeconds)")
        }
        let maxAvail = reader.durationSeconds - startSeconds
        let effectiveDur = min(durationSeconds ?? maxAvail, maxAvail)
        guard effectiveDur > 0 else { throw SafariumError.invalidState("GIF duration must be > 0") }

        let frameCount = max(1, Int((effectiveDur * Double(fps)).rounded(.down)))
        let srcW = reader.width, srcH = reader.height
        let outW: Int
        let outH: Int
        let scale: Double
        if let mw = maxWidth, mw < srcW {
            scale = Double(mw) / Double(srcW)
            outW = mw
            outH = max(1, Int((Double(srcH) * scale).rounded()))
        } else {
            scale = 1.0
            outW = srcW
            outH = srcH
        }

        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }
        let tempURL = staging.fileURL("out.gif")
        guard let dest = CGImageDestinationCreateWithURL(tempURL as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw SafariumError.encode("cannot create GIF destination at \(tempURL.path)")
        }
        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFLoopCount: loopCount,
            ],
        ]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)

        let delay = 1.0 / Double(fps)
        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay,
            ],
        ]
        let ciCtx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])
        defer { SafariumMetalContext.shared?.flushTextureCache() }

        do {
            for i in 0..<frameCount {
                let sampleT = (Double(i) + 0.5) / Double(fps)
                guard let pb = try reader.pixelBuffer(at: sampleT) else {
                    throw SafariumError.snapshot("missing decoded frame \(i) for GIF")
                }
                try autoreleasepool {
                    var img = reader.orientedCIImage(from: pb)
                    if scale != 1.0 {
                        let f = CIFilter(name: "CILanczosScaleTransform")!
                        f.setValue(img, forKey: kCIInputImageKey)
                        f.setValue(scale, forKey: kCIInputScaleKey)
                        f.setValue(1.0, forKey: kCIInputAspectRatioKey)
                        if let scaled = f.outputImage { img = scaled }
                    }
                    guard let cg = ciCtx.createCGImage(img, from: CGRect(x: 0, y: 0, width: outW, height: outH), format: .BGRA8, colorSpace: Snapshot.colorSpace) else {
                        throw SafariumError.snapshot("GIF CGImage render failed at frame \(i)")
                    }
                    CGImageDestinationAddImage(dest, cg, frameProps as CFDictionary)
                }
            }
            guard CGImageDestinationFinalize(dest) else {
                throw SafariumError.encode("CGImageDestinationFinalize failed for GIF")
            }
            // macOS ImageIO stamps GIF87a in bytes 0..<6 even when emitting GIF89a Graphic Control
            // and NETSCAPE2.0 extension blocks; promote the header to spec-compliant GIF89a.
            let handle = try FileHandle(forUpdating: tempURL)
            defer { try? handle.close() }
            if let header = try handle.read(upToCount: 6), header == Data("GIF87a".utf8) {
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Data("GIF89a".utf8))
                try handle.synchronize()
            }
            try handle.close()
            try SafeFilePublisher.publish(tempURL: tempURL, to: outputURL, overwrite: overwrite)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        let size = ((try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        return GIFWriteReport(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            frames: frameCount,
            fps: fps,
            width: outW,
            height: outH,
            loopCount: loopCount,
            fileSizeBytes: size
        )
    }
}

// MARK: - SubjectCutout

public enum SubjectCutout {
    private static func makeBGRAPixelBuffer(from cgImage: CGImage) throws -> CVPixelBuffer {
        let w = cgImage.width, h = cgImage.height
        var pbOpt: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let st = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pbOpt)
        guard st == kCVReturnSuccess, let pb = pbOpt else {
            throw SafariumError.snapshot("CVPixelBufferCreate failed (\(st))")
        }
        try Snapshot(cgImage: cgImage).draw(into: pb, width: w, height: h)
        return pb
    }

    private static func cutoutMaskAndComposite(
        srcPB: CVPixelBuffer,
        allowEmptyMask: Bool,
        measureCoverage: Bool
    ) throws -> (image: CIImage, instanceCount: Int, coveragePercent: Double) {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: srcPB, options: [:])
        try handler.perform([request])

        guard let obs = request.results?.first, !obs.allInstances.isEmpty else {
            if !allowEmptyMask {
                throw SafariumError.snapshot("Vision found no foreground subject instances")
            }
            return (CIImage.clear.cropped(to: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(srcPB), height: CVPixelBufferGetHeight(srcPB))), 0, 0.0)
        }
        let maskPB = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
        var coverage = 0.0
        if measureCoverage {
            CVPixelBufferLockBaseAddress(maskPB, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(maskPB, .readOnly) }
            let mw = CVPixelBufferGetWidth(maskPB), mh = CVPixelBufferGetHeight(maskPB)
            let mStride = CVPixelBufferGetBytesPerRow(maskPB)
            let fmt = CVPixelBufferGetPixelFormatType(maskPB)
            if let base = CVPixelBufferGetBaseAddress(maskPB) {
                var fg = 0
                switch fmt {
                case kCVPixelFormatType_OneComponent32Float:
                    guard mStride >= mw * MemoryLayout<Float>.size else {
                        throw SafariumError.snapshot("invalid 32-bit float Vision mask stride \(mStride)")
                    }
                    for row in 0..<mh {
                        let p = base.advanced(by: row * mStride).assumingMemoryBound(to: Float.self)
                        for col in 0..<mw where p[col] > 0.5 { fg += 1 }
                    }
                case kCVPixelFormatType_OneComponent8:
                    guard mStride >= mw else {
                        throw SafariumError.snapshot("invalid 8-bit Vision mask stride \(mStride)")
                    }
                    for row in 0..<mh {
                        let p = base.advanced(by: row * mStride).assumingMemoryBound(to: UInt8.self)
                        for col in 0..<mw where p[col] > 127 { fg += 1 }
                    }
                default:
                    throw SafariumError.snapshot("unsupported Vision mask pixel format \(fmt)")
                }
                coverage = Double(fg) * 100.0 / Double(max(1, mw * mh))
            }
        }
        let srcCI = CIImage(cvPixelBuffer: srcPB)
        let maskCI = CIImage(cvPixelBuffer: maskPB)
        let composited = srcCI.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.clear.cropped(to: srcCI.extent),
            kCIInputMaskImageKey: maskCI,
        ]).cropped(to: srcCI.extent)
        return (composited, obs.allInstances.count, coverage)
    }

    public static func cutoutImage(
        from inputURL: URL,
        to outputURL: URL,
        allowEmptyMask: Bool = false,
        overwrite: Bool = false
    ) async throws -> SubjectCutoutReport {
        guard outputURL.pathExtension.lowercased() == "png" else {
            throw SafariumError.invalidState("image cutout output must end with .png: \(outputURL.lastPathComponent)")
        }
        try SafeFilePublisher.assertRegularReadableFile(inputURL)
        try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)

        guard let imgSrc = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil) else {
            throw SafariumError.snapshot("could not decode image \(inputURL.lastPathComponent)")
        }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0, w <= 8192, h <= 8192, w * h <= 33_554_432 else {
            throw SafariumError.invalidState("cutout image dimensions must be <= 8192 per side and 33554432 pixels, got \(w)x\(h)")
        }
        let srcPB = try makeBGRAPixelBuffer(from: cg)
        let ciCtx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])
        defer { SafariumMetalContext.shared?.flushTextureCache() }

        let (composited, count, cov) = try cutoutMaskAndComposite(srcPB: srcPB, allowEmptyMask: allowEmptyMask, measureCoverage: true)
        guard let outCG = ciCtx.createCGImage(composited, from: CGRect(x: 0, y: 0, width: w, height: h), format: .BGRA8, colorSpace: Snapshot.colorSpace) else {
            throw SafariumError.snapshot("failed to render cutout PNG")
        }
        let png = Snapshot(cgImage: outCG).pngData()
        guard !png.isEmpty else { throw SafariumError.encode("PNG encode failed") }

        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }
        let tempURL = staging.fileURL("out.png")
        do {
            try png.write(to: tempURL)
            try SafeFilePublisher.publish(tempURL: tempURL, to: outputURL, overwrite: overwrite)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        return SubjectCutoutReport(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            kind: "image",
            frames: 1,
            width: w,
            height: h,
            instanceCount: count,
            foregroundCoveragePercent: cov
        )
    }

    public static func cutoutVideo(
        from inputURL: URL,
        to outputURL: URL,
        codec: VideoCodec = .hevcAlpha,
        fps: Int? = nil,
        maxFrames: Int? = nil,
        allowEmptyMask: Bool = false,
        overwrite: Bool = false
    ) async throws -> SubjectCutoutReport {
        guard codec.hasAlpha else {
            throw SafariumError.invalidState("video cutout requires an alpha codec (hevc-alpha or prores4444)")
        }
        guard outputURL.pathExtension.lowercased() == "mov" else {
            throw SafariumError.invalidState("video cutout output must end with .mov: \(outputURL.lastPathComponent)")
        }
        if let fps, fps <= 0 {
            throw SafariumError.invalidState("cutout fps must be > 0")
        }
        if let maxFrames, maxFrames <= 0 {
            throw SafariumError.invalidState("cutout maxFrames must be > 0")
        }
        try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)

        let reader = try await SafariumSequentialVideoReader(url: inputURL, loop: false, startTimeOffset: 0, pixelFormat: kCVPixelFormatType_32BGRA)
        defer { reader.close() }
        let outFPS = fps ?? max(1, Int(reader.nominalFPS.rounded()))
        let total = max(1, Int((reader.durationSeconds * Double(outFPS)).rounded()))
        let frames = maxFrames.map { min($0, total) } ?? total
        let w = reader.width, h = reader.height
        guard w > 0, h > 0, w <= 8192, h <= 8192, w * h <= 33_554_432 else {
            throw SafariumError.invalidState("cutout video dimensions must be <= 8192 per side and 33554432 pixels, got \(w)x\(h)")
        }

        guard let metal = SafariumMetalContext.shared else {
            throw SafariumError.encode("Metal context unavailable for video cutout")
        }
        defer { metal.flushTextureCache() }

        var uprightScratchPB: CVPixelBuffer?
        if !reader.preferredTransform.isIdentity {
            let attrs: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            let st = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &uprightScratchPB)
            guard st == kCVReturnSuccess, uprightScratchPB != nil else {
                throw SafariumError.snapshot("upright cutout pixel buffer alloc failed (\(st))")
            }
        }

        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }
        let tempURL = staging.fileURL("out.mov")
        let sink = try AVAssetWriterSink(url: tempURL, width: w, height: h, fps: outFPS, codec: codec, pixelFormat: .bgra)
        var maxInstances = 0
        var firstCoverage = 0.0

        do {
            for i in 0..<frames {
                let sampleT = (Double(i) + 0.5) / Double(outFPS)
                guard let srcPB = try reader.pixelBuffer(at: sampleT) else {
                    throw SafariumError.snapshot("missing video frame \(i) for cutout")
                }
                let inputPB: CVPixelBuffer
                if let uprightPB = uprightScratchPB {
                    let oriented = reader.orientedCIImage(from: srcPB)
                    metal.ciContext.render(oriented, to: uprightPB, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: Snapshot.colorSpace)
                    inputPB = uprightPB
                } else {
                    inputPB = srcPB
                }
                let (composited, count, cov) = try autoreleasepool {
                    try cutoutMaskAndComposite(srcPB: inputPB, allowEmptyMask: allowEmptyMask, measureCoverage: i == 0)
                }
                maxInstances = max(maxInstances, count)
                if i == 0 { firstCoverage = cov }

                try await sink.append { outPB in
                    let (_, mtlOut) = try metal.bindBGRA8Texture(for: outPB)
                    guard let cmd = metal.commandQueue.makeCommandBuffer() else {
                        throw SafariumError.encode("missing Metal command buffer")
                    }
                    let dest = CIRenderDestination(mtlTexture: mtlOut, commandBuffer: cmd)
                    dest.isFlipped = true
                    dest.colorSpace = Snapshot.colorSpace
                    dest.alphaMode = .premultiplied
                    try metal.ciContext.startTask(toRender: composited, from: CGRect(x: 0, y: 0, width: w, height: h), to: dest, at: .zero)
                    cmd.commit()
                    cmd.waitUntilCompleted()
                    if let err = cmd.error ?? (cmd.status != .completed ? SafariumError.encode("Metal render failed (status \(cmd.status.rawValue))") : nil) {
                        throw err
                    }
                }
            }
            try await sink.finish()
            try SafeFilePublisher.publish(tempURL: tempURL, to: outputURL, overwrite: overwrite)
        } catch {
            sink.cancel()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        return SubjectCutoutReport(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            kind: "video",
            frames: frames,
            width: w,
            height: h,
            instanceCount: maxInstances,
            foregroundCoveragePercent: firstCoverage
        )
    }
}
