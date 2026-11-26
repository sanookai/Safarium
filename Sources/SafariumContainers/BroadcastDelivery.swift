import AVFoundation
import Accelerate
import CoreMedia
import Foundation
import SafariumCore

// MARK: - A. SMPTE ST 12-1 Timecode & QuickTime `tmcd` Track Writer (Wave 17)

/// SMPTE ST 12-1 timecode supporting both drop-frame (29.97 / 59.94) and non-drop-frame (23.976 / 24 / 25 / 30 / 60).
public struct SMPTETimecode: Codable, Sendable, Equatable, CustomStringConvertible {
    public let hours: Int
    public let minutes: Int
    public let seconds: Int
    public let frames: Int
    public let frameRate: Double
    public let isDropFrame: Bool

    /// Nominal integer frames per second (e.g., 24, 25, 30, 60).
    public var nominalFPS: Int {
        max(1, Int(frameRate.rounded()))
    }

    /// Number of frame labels dropped at each non-10th minute boundary (2 for 29.97 DF, 4 for 59.94 DF, 0 for NDF).
    public var dropFramesPerMinute: Int {
        guard isDropFrame else { return 0 }
        let nom = nominalFPS
        if nom == 60 { return 4 }
        if nom == 30 { return 2 }
        return 0
    }

    /// Formatted SMPTE string (`HH:MM:SS;FF` for drop-frame, `HH:MM:SS:FF` for non-drop-frame).
    public var description: String {
        let sep = isDropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds, sep, frames)
    }

    public init(
        hours: Int,
        minutes: Int,
        seconds: Int,
        frames: Int,
        frameRate: Double = 29.97,
        isDropFrame: Bool = false
    ) {
        let safeFPS = max(1.0, frameRate)
        let nom = max(1, Int(safeFPS.rounded()))
        let validDF = isDropFrame && (nom == 30 || nom == 60)
        self.hours = max(0, hours % 24)
        self.minutes = max(0, min(59, minutes))
        self.seconds = max(0, min(59, seconds))
        self.frames = max(0, min(nom - 1, frames))
        self.frameRate = safeFPS
        self.isDropFrame = validDF
    }

    /// Converts an exact zero-based frame counter into a SMPTE timecode (SMPTE ST 12-1).
    public init(frameNumber: Int64, frameRate: Double = 29.97, isDropFrame: Bool = false) {
        let safeFPS = max(1.0, frameRate)
        let nom = Int64(max(1, Int(safeFPS.rounded())))
        let validDF = isDropFrame && (nom == 30 || nom == 60)
        let n = max(Int64(0), frameNumber)

        let adjustedFrames: Int64
        if validDF {
            let drop: Int64 = (nom == 60) ? 4 : 2
            let framesPerTenMin: Int64 = 10 * 60 * nom - 9 * drop
            let framesPerOneMin: Int64 = 60 * nom - drop
            let tenMinBlocks: Int64 = n / framesPerTenMin
            let remainderInTen: Int64 = n % framesPerTenMin
            let baseDropped: Int64 = 9 * drop * tenMinBlocks
            if remainderInTen < drop {
                adjustedFrames = n + baseDropped
            } else {
                let extraMinutes: Int64 = (remainderInTen - drop) / framesPerOneMin
                let extraDropped: Int64 = drop * extraMinutes
                adjustedFrames = n + baseDropped + extraDropped
            }
        } else {
            adjustedFrames = n
        }

        let ff = Int(adjustedFrames % nom)
        let totalSeconds = adjustedFrames / nom
        let ss = Int(totalSeconds % 60)
        let totalMinutes = totalSeconds / 60
        let mm = Int(totalMinutes % 60)
        let hh = Int((totalMinutes / 60) % 24)

        self.hours = hh
        self.minutes = mm
        self.seconds = ss
        self.frames = ff
        self.frameRate = safeFPS
        self.isDropFrame = validDF
    }

    /// Parses a SMPTE timecode string (`HH:MM:SS:FF` or `HH:MM:SS;FF`).
    public init(parsing string: String, frameRate: Double = 29.97) throws {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSemicolon = trimmed.contains(";")
        let normalized = trimmed.replacingOccurrences(of: ";", with: ":")
        let parts = normalized.split(separator: ":")
        guard parts.count == 4,
              let h = Int(parts[0]),
              let m = Int(parts[1]),
              let s = Int(parts[2]),
              let f = Int(parts[3]) else {
            throw SafariumError.invalidState("invalid SMPTE timecode string: \(string)")
        }
        self.init(hours: h, minutes: m, seconds: s, frames: f, frameRate: frameRate, isDropFrame: hasSemicolon)
    }

    /// Exact zero-based frame counter corresponding to this timecode (SMPTE ST 12-1).
    public var frameNumber: Int64 {
        let nom = Int64(nominalFPS)
        let h64 = Int64(hours)
        let m64 = Int64(minutes)
        let s64 = Int64(seconds)
        let f64 = Int64(frames)

        let totalSec: Int64 = h64 * 3600 + m64 * 60 + s64
        let rawFrames: Int64 = totalSec * nom + f64
        guard isDropFrame else {
            return rawFrames
        }
        let drop = Int64(dropFramesPerMinute)
        let totalMinutes: Int64 = h64 * 60 + m64
        let nonTenthMinutes: Int64 = totalMinutes - (totalMinutes / 10)
        let droppedTotal: Int64 = drop * nonTenthMinutes
        return rawFrames - droppedTotal
    }
}

/// Summary report returned after remuxing media with a native QuickTime `tmcd` track.
public struct TimecodeWriteReport: Codable, Sendable {
    public let outputPath: String
    public let startTimecode: String
    public let startFrameNumber: Int64
    public let frameRate: Double
    public let isDropFrame: Bool
    public let durationSeconds: Double
    public let videoTracksCopied: Int
    public let audioTracksCopied: Int

    public init(
        outputPath: String,
        startTimecode: String,
        startFrameNumber: Int64,
        frameRate: Double,
        isDropFrame: Bool,
        durationSeconds: Double,
        videoTracksCopied: Int,
        audioTracksCopied: Int
    ) {
        self.outputPath = outputPath
        self.startTimecode = startTimecode
        self.startFrameNumber = startFrameNumber
        self.frameRate = frameRate
        self.isDropFrame = isDropFrame
        self.durationSeconds = durationSeconds
        self.videoTracksCopied = videoTracksCopied
        self.audioTracksCopied = audioTracksCopied
    }
}

/// Native `AVAssetWriter` / `CMTimeCodeFormatDescription` writer that attaches a real `tmcd` track.
public enum TimecodeTrackWriter {

    /// Losslessly remuxes video and audio tracks from `inputURL` into `outputURL` (`.mov`)
    /// and attaches a genuine `CMMediaType.timeCode` (`tmcd`) track starting at `startTimecode`.
    public static func addTimecodeTrack(
        to inputURL: URL,
        outputURL: URL,
        startTimecode: SMPTETimecode
    ) async throws -> TimecodeWriteReport {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw SafariumError.invalidState("input media file does not exist: \(inputURL.path)")
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let asset = AVURLAsset(url: inputURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
        ])
        let totalDuration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard !videoTracks.isEmpty else {
            throw SafariumError.invalidState("no video track found in \(inputURL.lastPathComponent)")
        }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(url: outputURL, fileType: .mov)

        var trackPipes: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput, finished: Bool)] = []
        var firstVideoInput: AVAssetWriterInput?

        for vTrack in videoTracks {
            let formatDescriptions = try await vTrack.load(.formatDescriptions)
            let preferredTransform = try await vTrack.load(.preferredTransform)
            let readerOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
            readerOut.alwaysCopiesSampleData = false
            guard reader.canAdd(readerOut) else {
                throw SafariumError.invalidState("AVAssetReader cannot add video passthrough output")
            }
            reader.add(readerOut)

            let writerIn = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: nil,
                sourceFormatHint: formatDescriptions.first
            )
            writerIn.expectsMediaDataInRealTime = false
            writerIn.transform = preferredTransform
            guard writer.canAdd(writerIn) else {
                throw SafariumError.invalidState("AVAssetWriter cannot add video passthrough input")
            }
            writer.add(writerIn)
            if firstVideoInput == nil {
                firstVideoInput = writerIn
            }
            trackPipes.append((output: readerOut, input: writerIn, finished: false))
        }

        for aTrack in audioTracks {
            let formatDescriptions = try await aTrack.load(.formatDescriptions)
            let readerOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            readerOut.alwaysCopiesSampleData = false
            guard reader.canAdd(readerOut) else { continue }
            reader.add(readerOut)

            let writerIn = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: formatDescriptions.first
            )
            writerIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(writerIn) else { continue }
            writer.add(writerIn)
            trackPipes.append((output: readerOut, input: writerIn, finished: false))
        }

        // Build genuine CMTimeCodeFormatDescription (`tmcd` 32-bit big-endian frame counter)
        let frameDuration = cmFrameDuration(for: startTimecode.frameRate)
        let frameQuanta = UInt32(max(1, startTimecode.nominalFPS))
        var tcFlags: UInt32 = kCMTimeCodeFlag_24HourMax
        if startTimecode.isDropFrame {
            tcFlags |= kCMTimeCodeFlag_DropFrame
        }

        var tcFormatDesc: CMTimeCodeFormatDescription?
        let fmtStatus = CMTimeCodeFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
            frameDuration: frameDuration,
            frameQuanta: frameQuanta,
            flags: tcFlags,
            extensions: nil,
            formatDescriptionOut: &tcFormatDesc
        )
        guard fmtStatus == noErr, let formatDesc = tcFormatDesc else {
            throw SafariumError.encode("CMTimeCodeFormatDescriptionCreate failed with OSStatus \(fmtStatus)")
        }

        let tcInput = AVAssetWriterInput(
            mediaType: .timecode,
            outputSettings: nil,
            sourceFormatHint: formatDesc
        )
        tcInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(tcInput) else {
            throw SafariumError.encode("AVAssetWriter cannot add .timecode (tmcd) track")
        }
        writer.add(tcInput)

        if let vIn = firstVideoInput {
            let assocType = AVAssetTrack.AssociationType.timecode.rawValue
            if vIn.canAddTrackAssociation(withTrackOf: tcInput, type: assocType) {
                vIn.addTrackAssociation(withTrackOf: tcInput, type: assocType)
            }
        }

        guard reader.startReading() else {
            let msg = reader.error?.localizedDescription ?? "unknown reader error"
            throw SafariumError.encode("AVAssetReader failed to start: \(msg)")
        }
        guard writer.startWriting() else {
            let msg = writer.error?.localizedDescription ?? "unknown writer error"
            throw SafariumError.encode("AVAssetWriter failed to start: \(msg)")
        }
        writer.startSession(atSourceTime: .zero)

        // Append single continuous 32-bit big-endian timecode sample covering totalDuration
        let tcDuration = (totalDuration.isNumeric && totalDuration.seconds > 0) ? totalDuration : frameDuration
        let tcSample = try makeTimecodeSampleBuffer(
            frameNumber: startTimecode.frameNumber,
            duration: tcDuration,
            formatDescription: formatDesc
        )
        while !tcInput.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard tcInput.append(tcSample) else {
            let msg = writer.error?.localizedDescription ?? "failed to append tmcd sample"
            throw SafariumError.encode("AVAssetWriter tmcd append failed: \(msg)")
        }
        tcInput.markAsFinished()

        // Interleaved passthrough pump (100% Swift 6 Sendable-clean, deadlock-free)
        while trackPipes.contains(where: { !$0.finished }) {
            var progressed = false
            for idx in trackPipes.indices where !trackPipes[idx].finished {
                if trackPipes[idx].input.isReadyForMoreMediaData {
                    if let sample = trackPipes[idx].output.copyNextSampleBuffer() {
                        if !trackPipes[idx].input.append(sample) {
                            let msg = writer.error?.localizedDescription ?? "append failed"
                            throw SafariumError.encode("AVAssetWriter passthrough append failed: \(msg)")
                        }
                        progressed = true
                    } else {
                        trackPipes[idx].input.markAsFinished()
                        trackPipes[idx].finished = true
                        progressed = true
                    }
                }
            }
            if !progressed {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }

        await writer.finishWriting()
        if writer.status != .completed {
            let msg = writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)"
            throw SafariumError.encode("TimecodeTrackWriter finishWriting failed: \(msg)")
        }

        let durSec = (tcDuration.isNumeric && tcDuration.seconds.isFinite) ? tcDuration.seconds : 0.0
        return TimecodeWriteReport(
            outputPath: outputURL.path,
            startTimecode: startTimecode.description,
            startFrameNumber: startTimecode.frameNumber,
            frameRate: startTimecode.frameRate,
            isDropFrame: startTimecode.isDropFrame,
            durationSeconds: durSec,
            videoTracksCopied: videoTracks.count,
            audioTracksCopied: audioTracks.count
        )
    }

    private static func cmFrameDuration(for fps: Double) -> CMTime {
        if abs(fps - 23.976) < 0.05 {
            return CMTime(value: 1001, timescale: 24000)
        }
        if abs(fps - 29.97) < 0.05 {
            return CMTime(value: 1001, timescale: 30000)
        }
        if abs(fps - 59.94) < 0.1 {
            return CMTime(value: 1001, timescale: 60000)
        }
        let scale = CMTimeScale(max(1, Int32(fps.rounded())))
        return CMTime(value: 1, timescale: scale)
    }

    private static func makeTimecodeSampleBuffer(
        frameNumber: Int64,
        duration: CMTime,
        formatDescription: CMTimeCodeFormatDescription
    ) throws -> CMSampleBuffer {
        var bigEndianFrame = Int32(clamping: frameNumber).bigEndian
        let byteCount = MemoryLayout<Int32>.size

        var blockBuffer: CMBlockBuffer?
        let allocStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard allocStatus == kCMBlockBufferNoErr, let dataBuffer = blockBuffer else {
            throw SafariumError.encode("CMBlockBufferCreateWithMemoryBlock failed: \(allocStatus)")
        }

        let copyStatus: OSStatus = withUnsafeBytes(of: &bigEndianFrame) { rawBytes in
            guard let base = rawBytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: dataBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else {
            throw SafariumError.encode("CMBlockBufferReplaceDataBytes failed: \(copyStatus)")
        }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleSize = byteCount
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: dataBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let created = sampleBuffer else {
            throw SafariumError.encode("CMSampleBufferCreateReady failed: \(sampleStatus)")
        }
        return created
    }
}

// MARK: - B. CEA-608 / CEA-708 Closed Captions & SMPTE ST 334-2 CDP Packetizer (Wave 17)

/// Single timed subtitle/caption cue parsed from WebVTT or created programmatically.
public struct CaptionCue: Codable, Sendable, Equatable {
    public var startSeconds: Double
    public var endSeconds: Double
    public var text: String

    public init(startSeconds: Double, endSeconds: Double, text: String) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
    }
}

/// Odd-parity-encoded 2-byte CEA-608 character/control pair.
public struct CEA608BytePair: Codable, Sendable, Equatable {
    public let b1: UInt8
    public let b2: UInt8

    public init(_ b1: UInt8, _ b2: UInt8) {
        self.b1 = b1
        self.b2 = b2
    }

    public var tuple: (UInt8, UInt8) { (b1, b2) }
}

/// Timed sequence of odd-parity CEA-608 byte pairs for a caption cue event.
public struct CEA608Packet: Codable, Sendable, Equatable {
    public let ptsSeconds: Double
    public let pairs: [CEA608BytePair]

    public init(ptsSeconds: Double, pairs: [CEA608BytePair]) {
        self.ptsSeconds = ptsSeconds
        self.pairs = pairs
    }

    /// Flat array of all odd-parity bytes in this packet.
    public var bytes: [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(pairs.count * 2)
        for p in pairs {
            out.append(p.b1)
            out.append(p.b2)
        }
        return out
    }

    /// Tuple representation compatible with `ClosedCaptionPacketizer.wrapCEA708CDP`.
    public var tuplePairs: [(UInt8, UInt8)] {
        pairs.map { ($0.b1, $0.b2) }
    }
}

/// Pure-Swift WebVTT parser, ANSI/CTA-608-E odd-parity encoder, and SMPTE ST 334-2 CEA-708 CDP wrapper.
public enum ClosedCaptionPacketizer {

    /// Parses standard WebVTT text into an ordered array of `CaptionCue`s.
    public static func parseWebVTT(_ vtt: String) -> [CaptionCue] {
        let normalized = vtt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var cues: [CaptionCue] = []
        var idx = 0
        while idx < lines.count {
            let line = lines[idx].trimmingCharacters(in: .whitespaces)
            if line.contains("-->") {
                let parts = line.components(separatedBy: "-->")
                if parts.count >= 2 {
                    let startToken = parts[0].trimmingCharacters(in: .whitespaces)
                    let endRest = parts[1].trimmingCharacters(in: .whitespaces)
                    let endToken = endRest.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
                    if let startSec = parseVTTTimestamp(startToken),
                       let endSec = parseVTTTimestamp(endToken) {
                        var textLines: [String] = []
                        idx += 1
                        while idx < lines.count {
                            let contentLine = lines[idx]
                            if contentLine.trimmingCharacters(in: .whitespaces).isEmpty {
                                break
                            }
                            let cleaned = stripVTTTags(contentLine).trimmingCharacters(in: .whitespaces)
                            if !cleaned.isEmpty {
                                textLines.append(cleaned)
                            }
                            idx += 1
                        }
                        if !textLines.isEmpty {
                            cues.append(CaptionCue(
                                startSeconds: startSec,
                                endSeconds: max(startSec, endSec),
                                text: textLines.joined(separator: "\n")
                            ))
                        }
                        continue
                    }
                }
            }
            idx += 1
        }
        return cues
    }

    /// Enforces odd parity in bit 7 for a 7-bit CEA-608 byte (`nonzeroBitCount % 2 == 1`).
    public static func applyOddParity(_ byte: UInt8) -> UInt8 {
        let low7 = byte & 0x7F
        if low7.nonzeroBitCount % 2 == 0 {
            return low7 | 0x80
        }
        return low7
    }

    /// Encodes a 2-byte CEA-608 pair with strict ANSI/CTA-608-E odd parity on both bytes.
    public static func encodeCEA608Pair(_ b1: UInt8, _ b2: UInt8) -> (UInt8, UInt8) {
        (applyOddParity(b1), applyOddParity(b2))
    }

    /// Converts timed `CaptionCue`s into Pop-On CEA-608 CC1 packets (RCL, ENM, PAC row 15, odd-parity ASCII pairs, EOC, and EDM).
    public static func encodeCuesToCEA608(_ cues: [CaptionCue]) -> [CEA608Packet] {
        var packets: [CEA608Packet] = []
        packets.reserveCapacity(cues.count * 2)

        for cue in cues {
            var pairs: [CEA608BytePair] = []

            // Pop-On preamble: RCL (0x14, 0x20) + ENM (0x14, 0x2E)
            let rcl = encodeCEA608Pair(0x14, 0x20)
            let enm = encodeCEA608Pair(0x14, 0x2E)
            pairs.append(CEA608BytePair(rcl.0, rcl.1))
            pairs.append(CEA608BytePair(enm.0, enm.1))

            let rawLines = cue.text
                .components(separatedBy: "\n")
                .map { String($0.prefix(32)) }
                .filter { !$0.isEmpty }
            let displayLines = Array(rawLines.prefix(2))

            for (lineIndex, lineText) in displayLines.enumerated() {
                // Row 14 PAC (0x14, 0x40) for first of 2 lines; Row 15 PAC (0x14, 0x60) for bottom line
                let pacByte2: UInt8 = (displayLines.count == 2 && lineIndex == 0) ? 0x40 : 0x60
                let pac = encodeCEA608Pair(0x14, pacByte2)
                pairs.append(CEA608BytePair(pac.0, pac.1))

                var asciiBytes: [UInt8] = []
                asciiBytes.reserveCapacity(lineText.count + 1)
                for scalar in lineText.unicodeScalars {
                    if scalar.value >= 0x20 && scalar.value <= 0x7E {
                        asciiBytes.append(UInt8(scalar.value))
                    } else {
                        asciiBytes.append(0x3F) // '?'
                    }
                }
                if asciiBytes.count % 2 == 1 {
                    asciiBytes.append(0x00) // NUL pad (becomes 0x80 after odd parity)
                }
                var i = 0
                while i + 1 < asciiBytes.count {
                    let encoded = encodeCEA608Pair(asciiBytes[i], asciiBytes[i + 1])
                    pairs.append(CEA608BytePair(encoded.0, encoded.1))
                    i += 2
                }
            }

            // EOC (End of Caption: 0x14, 0x2F) flips non-displayed memory to screen
            let eoc = encodeCEA608Pair(0x14, 0x2F)
            pairs.append(CEA608BytePair(eoc.0, eoc.1))

            packets.append(CEA608Packet(ptsSeconds: cue.startSeconds, pairs: pairs))

            // EDM (Erase Displayed Memory: 0x14, 0x2C) at cue end
            if cue.endSeconds > cue.startSeconds {
                let edm = encodeCEA608Pair(0x14, 0x2C)
                packets.append(CEA608Packet(ptsSeconds: cue.endSeconds, pairs: [CEA608BytePair(edm.0, edm.1)]))
            }
        }

        return packets.sorted { $0.ptsSeconds < $1.ptsSeconds }
    }

    /// Wraps CEA-608 byte pairs into a standards-compliant SMPTE ST 334-2 CEA-708 Caption Distribution Packet (CDP).
    /// - Parameters:
    ///   - ccData: Array of CEA-608 `(b1, b2)` pairs (up to 31 triplets per CDP).
    ///   - sequenceCounter: 16-bit incrementing packet sequence counter.
    ///   - frameRateCode: 4-bit SMPTE ST 334-2 frame rate code (`1`=23.976, `2`=24, `3`=25, `4`=29.97, `5`=30, `7`=59.94, `8`=60).
    public static func wrapCEA708CDP(
        ccData: [(UInt8, UInt8)],
        sequenceCounter: UInt16,
        frameRateCode: UInt8 = 4
    ) -> Data {
        let clampedPairs = Array(ccData.prefix(31))
        let ccCount = clampedPairs.count
        let totalLength = 7 + 2 + (ccCount * 3) + 4

        var bytes: [UInt8] = []
        bytes.reserveCapacity(totalLength)

        // CDP Header (7 bytes)
        bytes.append(0x96)
        bytes.append(0x69)
        bytes.append(UInt8(totalLength & 0xFF))
        bytes.append(((frameRateCode & 0x0F) << 4) | 0x0F)
        bytes.append(0x43) // ccdata_present=1, caption_service_active=1, reserved=1
        bytes.append(UInt8((sequenceCounter >> 8) & 0xFF))
        bytes.append(UInt8(sequenceCounter & 0xFF))

        // ccdata_section (2 + 3*N bytes)
        bytes.append(0x72)
        bytes.append(0xE0 | UInt8(ccCount & 0x1F))
        for (b1, b2) in clampedPairs {
            bytes.append(0xFC) // marker_bits(11111) | cc_valid(1) | cc_type(00 = NTSC Field 1 CEA-608)
            bytes.append(b1)
            bytes.append(b2)
        }

        // cdp_footer (4 bytes)
        bytes.append(0x74)
        bytes.append(UInt8((sequenceCounter >> 8) & 0xFF))
        bytes.append(UInt8(sequenceCounter & 0xFF))

        // 8-bit modular checksum so sum of all packet bytes mod 256 == 0
        var sum = 0
        for b in bytes {
            sum = (sum + Int(b)) & 0xFF
        }
        let checksum = UInt8((256 - sum) & 0xFF)
        bytes.append(checksum)

        return Data(bytes)
    }

    /// Validates a SMPTE ST 334-2 CDP packet's sync word (`0x9669`), length, section IDs, sequence counters, and checksum.
    public static func verifyCEA708CDP(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 13 else { return false }
        guard bytes[0] == 0x96 && bytes[1] == 0x69 else { return false }
        guard Int(bytes[2]) == bytes.count else { return false }
        guard bytes[7] == 0x72 else { return false }

        let ccCount = Int(bytes[8] & 0x1F)
        let footerOffset = 9 + ccCount * 3
        guard footerOffset + 4 == bytes.count else { return false }
        guard bytes[footerOffset] == 0x74 else { return false }

        // Header and footer sequence counters must match
        guard bytes[5] == bytes[footerOffset + 1] && bytes[6] == bytes[footerOffset + 2] else {
            return false
        }

        var sum = 0
        for b in bytes {
            sum = (sum + Int(b)) & 0xFF
        }
        return sum == 0
    }

    private static func parseVTTTimestamp(_ token: String) -> Double? {
        let cleaned = token.replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":")
        if parts.count == 3 {
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else {
                return nil
            }
            let hSec = h * 3600.0
            let mSec = m * 60.0
            return hSec + mSec + s
        } else if parts.count == 2 {
            guard let m = Double(parts[0]), let s = Double(parts[1]) else {
                return nil
            }
            let mSec = m * 60.0
            return mSec + s
        }
        return nil
    }

    private static func stripVTTTags(_ line: String) -> String {
        var out = ""
        var inTag = false
        for ch in line {
            if ch == "<" {
                inTag = true
            } else if ch == ">" {
                inTag = false
            } else if !inTag {
                out.append(ch)
            }
        }
        return out
    }
}

// MARK: - C. EBU R128 / ATSC A/85 Broadcast Loudness Auditor (ITU-R BS.1770-4, Wave 17)

/// Broadcast and streaming loudness delivery specifications.
public enum BroadcastLoudnessStandard: String, Codable, Sendable, CaseIterable {
    case ebuR128 = "ebu-r128"
    case atscA85 = "atsc-a85"
    case streaming = "streaming"

    /// Target integrated program loudness in LUFS.
    public var targetLUFS: Double {
        switch self {
        case .ebuR128: return -23.0
        case .atscA85: return -24.0
        case .streaming: return -14.0
        }
    }

    /// Maximum permitted deviation around `targetLUFS` in LU.
    public var toleranceLU: Double {
        switch self {
        case .ebuR128: return 1.0
        case .atscA85: return 1.0
        case .streaming: return 1.5
        }
    }

    /// Maximum permitted True Peak ceiling in dBTP.
    public var maxTruePeakDBTP: Double {
        switch self {
        case .ebuR128: return -1.0
        case .atscA85: return -2.0
        case .streaming: return -1.0
        }
    }
}

/// Complete ITU-R BS.1770-4 / EBU R128 loudness & True Peak compliance report.
public struct BroadcastLoudnessReport: Codable, Sendable {
    public let standard: BroadcastLoudnessStandard
    public let integratedLUFS: Double
    public let momentaryMaxLUFS: Double
    public let shortTermMaxLUFS: Double
    public let loudnessRangeLU: Double
    public let truePeakDBTP: Double
    public let compliant: Bool
    public let recommendedGainDB: Double
    public let violations: [String]

    public init(
        standard: BroadcastLoudnessStandard,
        integratedLUFS: Double,
        momentaryMaxLUFS: Double,
        shortTermMaxLUFS: Double,
        loudnessRangeLU: Double,
        truePeakDBTP: Double,
        compliant: Bool,
        recommendedGainDB: Double,
        violations: [String]
    ) {
        self.standard = standard
        self.integratedLUFS = integratedLUFS
        self.momentaryMaxLUFS = momentaryMaxLUFS
        self.shortTermMaxLUFS = shortTermMaxLUFS
        self.loudnessRangeLU = loudnessRangeLU
        self.truePeakDBTP = truePeakDBTP
        self.compliant = compliant
        self.recommendedGainDB = recommendedGainDB
        self.violations = violations
    }
}

/// Pure-Swift + Accelerate ITU-R BS.1770-4 / EBU R128 / ATSC A/85 broadcast loudness auditor.
public enum BroadcastLoudnessAuditor {

    private struct BiquadCoeffs {
        let b0: Double
        let b1: Double
        let b2: Double
        let a1: Double
        let a2: Double
    }

    /// Analyzes planar per-channel float PCM buffers (`samples[channel][frame]`) at `sampleRate`.
    public static func analyze(
        samples: [[Float]],
        sampleRate: Double,
        standard: BroadcastLoudnessStandard = .ebuR128
    ) -> BroadcastLoudnessReport {
        let fs = max(8000.0, sampleRate)
        let channelCount = samples.count
        let frameCount = samples.map(\.count).min() ?? 0

        guard channelCount > 0 && frameCount > 0 else {
            return BroadcastLoudnessReport(
                standard: standard,
                integratedLUFS: -120.0,
                momentaryMaxLUFS: -120.0,
                shortTermMaxLUFS: -120.0,
                loudnessRangeLU: 0.0,
                truePeakDBTP: -120.0,
                compliant: false,
                recommendedGainDB: 0.0,
                violations: ["no audio samples to analyze"]
            )
        }

        // 1. Compute 4x windowed-sinc oversampled True Peak (dBTP) on unfiltered signal
        var maxTruePeakLinear: Double = 0.0
        for ch in 0..<channelCount {
            let chPeak = measureTruePeak4x(samples[ch])
            if chPeak > maxTruePeakLinear {
                maxTruePeakLinear = chPeak
            }
        }
        let truePeakDBTP: Double
        if maxTruePeakLinear > 1e-12 {
            truePeakDBTP = 20.0 * log10(maxTruePeakLinear)
        } else {
            truePeakDBTP = -120.0
        }

        // 2. Apply ITU-R BS.1770-4 2-stage K-weighting biquad filter per channel
        let (stage1, stage2) = kWeightingCoefficients(sampleRate: fs)
        var weightedSquared: [[Double]] = []
        weightedSquared.reserveCapacity(channelCount)

        for ch in 0..<channelCount {
            let filtered = applyTwoStageBiquad(samples[ch], count: frameCount, s1: stage1, s2: stage2)
            var sq = [Double](repeating: 0.0, count: frameCount)
            for i in 0..<frameCount {
                let v = filtered[i]
                sq[i] = v * v
            }
            weightedSquared.append(sq)
        }

        // Channel gain weights G_i per ITU-R BS.1770-4
        let weights = channelWeights(count: channelCount)

        // Precompute prefix sums of weighted combined power per sample for O(1) window energy queries
        var prefixSum = [Double](repeating: 0.0, count: frameCount + 1)
        var running = 0.0
        for i in 0..<frameCount {
            var p = 0.0
            for ch in 0..<channelCount {
                p += weights[ch] * weightedSquared[ch][i]
            }
            running += p
            prefixSum[i + 1] = running
        }

        // 3. 400ms Momentary blocks (100ms hop, 75% overlap) + Integrated Gated Loudness
        let win400 = max(1, Int((0.400 * fs).rounded()))
        let hop100 = max(1, Int((0.100 * fs).rounded()))
        var blockPowers400: [Double] = []
        var blockLoudness400: [Double] = []

        if frameCount >= win400 {
            var start = 0
            while start + win400 <= frameCount {
                let energy = prefixSum[start + win400] - prefixSum[start]
                let meanPower = energy / Double(win400)
                let lufs = powerToLUFS(meanPower)
                blockPowers400.append(meanPower)
                blockLoudness400.append(lufs)
                start += hop100
            }
        } else {
            let meanPower = prefixSum[frameCount] / Double(frameCount)
            blockPowers400.append(meanPower)
            blockLoudness400.append(powerToLUFS(meanPower))
        }

        let momentaryMaxLUFS = blockLoudness400.max() ?? -120.0

        // Absolute gate: > -70.0 LUFS
        var absGatedIndices: [Int] = []
        for idx in blockLoudness400.indices {
            if blockLoudness400[idx] > -70.0 {
                absGatedIndices.append(idx)
            }
        }

        let integratedLUFS: Double
        if absGatedIndices.isEmpty {
            integratedLUFS = -120.0
        } else {
            var absSum = 0.0
            for idx in absGatedIndices {
                absSum += blockPowers400[idx]
            }
            let absMeanPower = absSum / Double(absGatedIndices.count)
            let relThreshold = powerToLUFS(absMeanPower) - 10.0

            var relSum = 0.0
            var relCount = 0
            for idx in absGatedIndices {
                if blockLoudness400[idx] > relThreshold {
                    relSum += blockPowers400[idx]
                    relCount += 1
                }
            }
            if relCount > 0 {
                let finalMeanPower = relSum / Double(relCount)
                integratedLUFS = powerToLUFS(finalMeanPower)
            } else {
                integratedLUFS = powerToLUFS(absMeanPower)
            }
        }

        // 4. 3.0s Short-Term blocks (100ms hop) + EBU Tech 3342 Loudness Range (LRA)
        let win3s = max(1, Int((3.0 * fs).rounded()))
        var stPowers: [Double] = []
        var stLoudness: [Double] = []

        if frameCount >= win3s {
            var start = 0
            while start + win3s <= frameCount {
                let energy = prefixSum[start + win3s] - prefixSum[start]
                let meanPower = energy / Double(win3s)
                stPowers.append(meanPower)
                stLoudness.append(powerToLUFS(meanPower))
                start += hop100
            }
        } else {
            let meanPower = prefixSum[frameCount] / Double(frameCount)
            stPowers.append(meanPower)
            stLoudness.append(powerToLUFS(meanPower))
        }

        let shortTermMaxLUFS = stLoudness.max() ?? -120.0

        var lraAbsIndices: [Int] = []
        for idx in stLoudness.indices {
            if stLoudness[idx] > -70.0 {
                lraAbsIndices.append(idx)
            }
        }

        let loudnessRangeLU: Double
        if lraAbsIndices.count < 2 {
            loudnessRangeLU = 0.0
        } else {
            var stAbsSum = 0.0
            for idx in lraAbsIndices {
                stAbsSum += stPowers[idx]
            }
            let stAbsMean = stAbsSum / Double(lraAbsIndices.count)
            let lraRelThreshold = powerToLUFS(stAbsMean) - 20.0

            var lraValues: [Double] = []
            for idx in lraAbsIndices {
                if stLoudness[idx] > lraRelThreshold {
                    lraValues.append(stLoudness[idx])
                }
            }
            if lraValues.count < 2 {
                loudnessRangeLU = 0.0
            } else {
                lraValues.sort()
                let p10 = percentile(sorted: lraValues, fraction: 0.10)
                let p95 = percentile(sorted: lraValues, fraction: 0.95)
                loudnessRangeLU = max(0.0, p95 - p10)
            }
        }

        // 5. Evaluate compliance against standard
        var violations: [String] = []
        let lufsDiff = abs(integratedLUFS - standard.targetLUFS)
        if integratedLUFS <= -70.0 {
            violations.append("audio program is effectively silent (\(String(format: "%.2f", integratedLUFS)) LUFS)")
        } else if lufsDiff > standard.toleranceLU {
            violations.append(
                "integrated loudness \(String(format: "%.2f", integratedLUFS)) LUFS outside \(standard.rawValue) target \(String(format: "%.1f", standard.targetLUFS)) ± \(String(format: "%.1f", standard.toleranceLU)) LU"
            )
        }
        if truePeakDBTP > standard.maxTruePeakDBTP {
            violations.append(
                "true peak \(String(format: "%.2f", truePeakDBTP)) dBTP exceeds \(standard.rawValue) ceiling \(String(format: "%.1f", standard.maxTruePeakDBTP)) dBTP"
            )
        }

        let recommendedGainDB: Double = (integratedLUFS > -70.0) ? (standard.targetLUFS - integratedLUFS) : 0.0
        let compliant = violations.isEmpty

        return BroadcastLoudnessReport(
            standard: standard,
            integratedLUFS: round3(integratedLUFS),
            momentaryMaxLUFS: round3(momentaryMaxLUFS),
            shortTermMaxLUFS: round3(shortTermMaxLUFS),
            loudnessRangeLU: round3(loudnessRangeLU),
            truePeakDBTP: round3(truePeakDBTP),
            compliant: compliant,
            recommendedGainDB: round3(recommendedGainDB),
            violations: violations
        )
    }

    /// Analyzes interleaved float PCM samples (`[L0, R0, L1, R1, ...]`).
    public static func analyzeInterleaved(
        samples: [Float],
        channelCount: Int,
        sampleRate: Double,
        standard: BroadcastLoudnessStandard = .ebuR128
    ) -> BroadcastLoudnessReport {
        let chCount = max(1, channelCount)
        let frameCount = samples.count / chCount
        var planar = Array(repeating: [Float](repeating: 0.0, count: frameCount), count: chCount)
        for frame in 0..<frameCount {
            let base = frame * chCount
            for ch in 0..<chCount {
                planar[ch][frame] = samples[base + ch]
            }
        }
        return analyze(samples: planar, sampleRate: sampleRate, standard: standard)
    }

    /// Decodes the audio track of an audio/video file via `AVAssetReader` (32-bit float PCM at 48 kHz)
    /// and evaluates EBU R128 / ATSC A/85 broadcast loudness compliance.
    public static func analyze(
        url: URL,
        standard: BroadcastLoudnessStandard = .ebuR128
    ) async throws -> BroadcastLoudnessReport {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SafariumError.invalidState("audio/video file not found: \(url.path)")
        }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw SafariumError.invalidState("no audio track found in \(url.lastPathComponent)")
        }

        let targetRate: Double = 48_000.0
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetRate,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else {
            throw SafariumError.invalidState("AVAssetReader cannot add linear PCM audio output")
        }
        reader.add(trackOutput)
        guard reader.startReading() else {
            let msg = reader.error?.localizedDescription ?? "reader failed to start"
            throw SafariumError.encode("AVAssetReader audio decode failed: \(msg)")
        }

        var interleaved: [Float] = []
        var detectedChannels = 2

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                detectedChannels = max(1, Int(asbdPtr.pointee.mChannelsPerFrame))
            }
            if let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
                var totalLength = 0
                var dataPointer: UnsafeMutablePointer<Int8>?
                let status = CMBlockBufferGetDataPointer(
                    blockBuffer,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &totalLength,
                    dataPointerOut: &dataPointer
                )
                if status == kCMBlockBufferNoErr, let ptr = dataPointer, totalLength >= MemoryLayout<Float>.size {
                    let floatCount = totalLength / MemoryLayout<Float>.size
                    let rawBuf = UnsafeRawPointer(ptr).assumingMemoryBound(to: Float.self)
                    let bufferSlice = UnsafeBufferPointer(start: rawBuf, count: floatCount)
                    interleaved.append(contentsOf: bufferSlice)
                }
            }
        }

        return analyzeInterleaved(
            samples: interleaved,
            channelCount: detectedChannels,
            sampleRate: targetRate,
            standard: standard
        )
    }

    // MARK: - ITU-R BS.1770-4 DSP Helpers

    private static func kWeightingCoefficients(sampleRate fs: Double) -> (BiquadCoeffs, BiquadCoeffs) {
        if abs(fs - 48_000.0) < 1.0 {
            // Exact ITU-R BS.1770-4 Table 1 & Table 2 coefficients for 48 kHz
            let s1 = BiquadCoeffs(
                b0: 1.53512485958697,
                b1: -2.69169618940638,
                b2: 1.19839281085285,
                a1: -1.69065929318241,
                a2: 0.73248077421585
            )
            let s2 = BiquadCoeffs(
                b0: 1.0,
                b1: -2.0,
                b2: 1.0,
                a1: -1.99004745483398,
                a2: 0.99007225036621
            )
            return (s1, s2)
        }

        // Analytical bilinear transform for arbitrary sample rates
        let f0Shelf = 1681.974450955533
        let gShelf = 3.999843853973347
        let qShelf = 0.7071752369554196
        let k1 = tan(Double.pi * f0Shelf / fs)
        let k1Sq = k1 * k1
        let vh = pow(10.0, gShelf / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        let a0_1 = 1.0 + (k1 / qShelf) + k1Sq
        let s1 = BiquadCoeffs(
            b0: (vh + (vb * k1 / qShelf) + k1Sq) / a0_1,
            b1: (2.0 * (k1Sq - vh)) / a0_1,
            b2: (vh - (vb * k1 / qShelf) + k1Sq) / a0_1,
            a1: (2.0 * (k1Sq - 1.0)) / a0_1,
            a2: (1.0 - (k1 / qShelf) + k1Sq) / a0_1
        )

        let f0HP = 38.13547087602444
        let qHP = 0.5003270373238773
        let k2 = tan(Double.pi * f0HP / fs)
        let k2Sq = k2 * k2
        let a0_2 = 1.0 + (k2 / qHP) + k2Sq
        let s2 = BiquadCoeffs(
            b0: 1.0,
            b1: -2.0,
            b2: 1.0,
            a1: (2.0 * (k2Sq - 1.0)) / a0_2,
            a2: (1.0 - (k2 / qHP) + k2Sq) / a0_2
        )
        return (s1, s2)
    }

    private static func applyTwoStageBiquad(
        _ input: [Float],
        count: Int,
        s1: BiquadCoeffs,
        s2: BiquadCoeffs
    ) -> [Double] {
        var out = [Double](repeating: 0.0, count: count)
        var z1_1 = 0.0
        var z2_1 = 0.0
        var z1_2 = 0.0
        var z2_2 = 0.0

        for i in 0..<count {
            let x = Double(input[i])
            let y1 = s1.b0 * x + z1_1
            z1_1 = s1.b1 * x - s1.a1 * y1 + z2_1
            z2_1 = s1.b2 * x - s1.a2 * y1

            let y2 = s2.b0 * y1 + z1_2
            z1_2 = s2.b1 * y1 - s2.a1 * y2 + z2_2
            z2_2 = s2.b2 * y1 - s2.a2 * y2
            out[i] = y2
        }
        return out
    }

    private static func channelWeights(count: Int) -> [Double] {
        if count == 6 {
            // 5.1 surround: L, R, C, LFE(0), Ls(1.41), Rs(1.41)
            return [1.0, 1.0, 1.0, 0.0, 1.41, 1.41]
        }
        return Array(repeating: 1.0, count: count)
    }

    private static func powerToLUFS(_ meanPower: Double) -> Double {
        if meanPower <= 1e-12 {
            return -120.0
        }
        return -0.691 + 10.0 * log10(meanPower)
    }

    private static func percentile(sorted: [Double], fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0.0 }
        let clamped = max(0.0, min(1.0, fraction))
        let pos = clamped * Double(sorted.count - 1)
        let lo = Int(floor(pos))
        let hi = min(sorted.count - 1, lo + 1)
        let weight = pos - Double(lo)
        return sorted[lo] * (1.0 - weight) + sorted[hi] * weight
    }

    /// 4x polyphase windowed-sinc FIR True Peak detector (ITU-R BS.1770-4 Annex 2).
    private static func measureTruePeak4x(_ samples: [Float]) -> Double {
        let count = samples.count
        guard count > 0 else { return 0.0 }

        // Check native sample peak via Accelerate first (phase 0)
        var nativePeak: Float = 0.0
        vDSP_maxmgv(samples, 1, &nativePeak, vDSP_Length(count))
        var maxPeak = Double(nativePeak)

        // Precompute 3 fractional phases (0.25, 0.50, 0.75) of a 12-tap Blackman-windowed sinc kernel
        let halfTaps = 6
        let taps = halfTaps * 2
        let phases: [Double] = [0.25, 0.50, 0.75]
        var kernels: [[Double]] = []
        kernels.reserveCapacity(3)

        for frac in phases {
            var kernel = [Double](repeating: 0.0, count: taps)
            var sum = 0.0
            for k in 0..<taps {
                let offset = Double(k - halfTaps + 1) - frac
                let sincVal: Double
                if abs(offset) < 1e-9 {
                    sincVal = 1.0
                } else {
                    let arg = Double.pi * offset
                    sincVal = sin(arg) / arg
                }
                let wPos = (Double(k) + 0.5 - frac) / Double(taps)
                let win = 0.42 - 0.5 * cos(2.0 * Double.pi * wPos) + 0.08 * cos(4.0 * Double.pi * wPos)
                let coeff = sincVal * win
                kernel[k] = coeff
                sum += coeff
            }
            if abs(sum) > 1e-9 {
                for k in 0..<taps {
                    kernel[k] /= sum
                }
            }
            kernels.append(kernel)
        }

        // Evaluate 4x inter-sample peaks
        for i in 0..<count {
            for phaseIdx in 0..<3 {
                let kernel = kernels[phaseIdx]
                var acc = 0.0
                for k in 0..<taps {
                    let sampleIdx = i + (k - halfTaps + 1)
                    if sampleIdx >= 0 && sampleIdx < count {
                        acc += Double(samples[sampleIdx]) * kernel[k]
                    }
                }
                let mag = abs(acc)
                if mag > maxPeak {
                    maxPeak = mag
                }
            }
        }
        return maxPeak
    }

    private static func round3(_ v: Double) -> Double {
        (v * 1000.0).rounded() / 1000.0
    }
}
