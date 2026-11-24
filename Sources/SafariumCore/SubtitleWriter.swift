import CoreMedia
import Darwin
import Foundation

public struct SafariumSRTCue: Equatable, Sendable {
    public let startMS: Int64
    public let endMS: Int64
    public let text: String

    public init(startMS: Int64, endMS: Int64, text: String) {
        self.startMS = startMS
        self.endMS = endMS
        self.text = text
    }
}

/// Native ISO BMFF `'sbtl'` / `'tx3g'` subtitle track builder using CoreMedia only.
public enum SafariumTX3G {
    public static let maxSRTFileBytes: Int64 = 16 * 1024 * 1024

    public static func recommendedTimeScale(for duration: CMTime) -> Int32 {
        let base = max(1, Int(duration.timescale))
        var a = base, b = 1000
        while b != 0 { (a, b) = (b, a % b) }
        return Int32(exactly: (base / a) * 1000) ?? duration.timescale
    }

    public static func parseSRT(url: URL, offsetSeconds: Double, duration: CMTime) throws -> [SafariumSRTCue] {
        var st = stat()
        guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw SafariumError.invalidState("SRT subtitles path is not a readable regular file: \(url.path)")
        }
        guard st.st_size <= maxSRTFileBytes else {
            throw SafariumError.invalidState("SRT file exceeds 16 MiB limit: \(st.st_size) bytes")
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw SafariumError.invalidState("cannot read SRT subtitles at \(url.path): \(error.localizedDescription)") }
        guard let raw = String(data: data, encoding: .utf8) else {
            throw SafariumError.invalidState("SRT file must be valid UTF-8: \(url.path)")
        }
        return try parseSRT(text: raw, offsetSeconds: offsetSeconds, duration: duration)
    }

    public static func parseSRT(text: String, offsetSeconds: Double, duration: CMTime) throws -> [SafariumSRTCue] {
        guard offsetSeconds.isFinite, offsetSeconds >= 0, (offsetSeconds * 1000.0).isFinite,
              abs(offsetSeconds * 1000.0) <= Double(Int64.max / 2) else {
            throw SafariumError.invalidState("invalid subtitle offsetSeconds: \(offsetSeconds)")
        }
        let durSec = CMTimeGetSeconds(duration)
        guard duration.isNumeric, durSec.isFinite, durSec > 0, (durSec * 1000.0).isFinite,
              durSec * 1000.0 <= Double(Int64.max / 2) else {
            throw SafariumError.invalidState("invalid subtitle movie duration")
        }

        var raw = text
        if raw.hasPrefix("\u{FEFF}") { raw.removeFirst() }
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var blocks: [[String]] = []
        var current: [String] = []
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    blocks.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(String(line))
            }
        }
        if !current.isEmpty { blocks.append(current) }

        let offsetMS = Int64((offsetSeconds * 1000.0).rounded())
        let durMS = max(0, Int64((durSec * 1000.0).rounded(.up)))

        func parseTime(_ s: String) -> Int64? {
            let clean = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            let parts = clean.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3,
                  let hh = Int64(parts[0]), hh >= 0,
                  let mm = Int64(parts[1]), mm >= 0, mm < 60,
                  let secDouble = Double(parts[2]), secDouble.isFinite, secDouble >= 0, secDouble < 60.0 else {
                return nil
            }
            let (hhSec, ov1) = hh.multipliedReportingOverflow(by: 3600)
            let (mmSec, ov2) = mm.multipliedReportingOverflow(by: 60)
            let (wholeSec, ov3) = hhSec.addingReportingOverflow(mmSec)
            let (wholeMS, ov4) = wholeSec.multipliedReportingOverflow(by: 1000)
            let fracMS = Int64((secDouble * 1000.0).rounded())
            let (totalMS, ov5) = wholeMS.addingReportingOverflow(fracMS)
            guard !ov1 && !ov2 && !ov3 && !ov4 && !ov5 else { return nil }
            return totalMS
        }

        var cues: [SafariumSRTCue] = []
        for lines in blocks {
            guard let timeIdx = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timeParts = lines[timeIdx].components(separatedBy: "-->")
            guard timeParts.count == 2,
                  let sMS = parseTime(timeParts[0]),
                  let endToken = timeParts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: .whitespaces).first,
                  let eMS = parseTime(endToken) else {
                throw SafariumError.invalidState("invalid SRT cue timing: \(lines[timeIdx])")
            }
            let relStart = max(0, sMS - offsetMS)
            let relEnd = min(durMS, eMS - offsetMS)
            guard relEnd > relStart else { continue }
            let cueText = lines[(timeIdx + 1)...]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cueText.isEmpty {
                cues.append(SafariumSRTCue(
                    startMS: relStart,
                    endMS: relEnd,
                    text: cueText.precomposedStringWithCanonicalMapping
                ))
            }
        }
        return cues.sorted { ($0.startMS, $0.endMS) < ($1.startMS, $1.endMS) }
    }

    public static func makeFormatDescription(
        width: Int,
        height: Int,
        fontName: String = "Sans-Serif",
        fontSize: UInt8 = 24
    ) throws -> CMFormatDescription {
        let fontBytes = Array(fontName.utf8)
        guard !fontBytes.isEmpty, fontBytes.count <= Int(UInt8.max) else {
            throw SafariumError.encode("invalid tx3g font name")
        }

        // Full ISO BMFF 'tx3g' SampleEntry + TextSampleEntry + ftab box.
        var data = Data()
        func appendU32(_ v: UInt32) { var be = v.bigEndian; data.append(Data(bytes: &be, count: 4)) }
        func appendU16(_ v: UInt16) { var be = v.bigEndian; data.append(Data(bytes: &be, count: 2)) }
        func appendI16(_ v: Int16) { var be = v.bigEndian; data.append(Data(bytes: &be, count: 2)) }
        func appendU8(_ v: UInt8) { data.append(v) }
        func appendI8(_ v: Int8) { data.append(UInt8(bitPattern: v)) }

        let ftabSize = UInt32(4 + 4 + 2 + 2 + 1 + fontBytes.count)
        let totalSize = UInt32(16 + 30 + Int(ftabSize))

        // 16-byte SampleEntry header
        appendU32(totalSize)
        data.append(contentsOf: "tx3g".utf8)
        data.append(contentsOf: [0, 0, 0, 0, 0, 0])
        appendU16(1) // data_reference_index

        // 30-byte TextSampleEntry fields
        appendU32(UInt32(kCMTextDisplayFlag_obeySubtitleFormatting))
        appendI8(Int8(kCMTextJustification_centered))
        appendI8(Int8(kCMTextJustification_bottom_right))
        data.append(contentsOf: [0, 0, 0, 0]) // transparent background RGBA
        appendI16(0)
        appendI16(0)
        appendI16(Int16(clamping: height))
        appendI16(Int16(clamping: width))

        // 12-byte DefaultStyle StyleRecord
        appendU16(0)
        appendU16(0)
        appendU16(1) // font ID
        appendU8(0)  // normal face
        appendU8(fontSize)
        data.append(contentsOf: [255, 255, 255, 255]) // white RGBA

        // ftab box
        appendU32(ftabSize)
        data.append(contentsOf: "ftab".utf8)
        appendU16(1) // entry count
        appendU16(1) // font ID
        appendU8(UInt8(fontBytes.count))
        data.append(contentsOf: fontBytes)

        var desc: CMTextFormatDescription?
        let st = data.withUnsafeBytes { raw in
            CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: kCFAllocatorDefault,
                bigEndianTextDescriptionData: raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                size: data.count,
                flavor: nil,
                mediaType: kCMMediaType_Subtitle,
                formatDescriptionOut: &desc
            )
        }
        guard st == noErr, let desc else {
            throw SafariumError.encode("CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData failed (\(st))")
        }
        return desc
    }

    public static func buildContiguousSamples(
        cues: [SafariumSRTCue],
        duration: CMTime,
        width: Int,
        height: Int,
        fontName: String = "Sans-Serif",
        fontSize: UInt8 = 24
    ) throws -> (CMFormatDescription, [CMSampleBuffer]) {
        guard duration.isNumeric, CMTimeCompare(duration, .zero) > 0 else {
            throw SafariumError.invalidState("subtitle movie duration must be positive")
        }
        for cue in cues where cue.text.utf8.count > Int(UInt16.max) {
            throw SafariumError.encode("subtitle cue exceeds 65535 UTF-8 bytes")
        }
        let fmt = try makeFormatDescription(width: width, height: height, fontName: fontName, fontSize: fontSize)

        struct Interval { let start: CMTime; let end: CMTime; let text: String }
        var intervals: [Interval] = []
        var cursor = CMTime.zero
        for cue in cues.sorted(by: { ($0.startMS, $0.endMS) < ($1.startMS, $1.endMS) }) {
            let cueStart = CMTimeMinimum(duration, CMTimeMaximum(.zero, CMTime(value: cue.startMS, timescale: 1000)))
            let cueEnd = CMTimeMinimum(duration, CMTimeMaximum(.zero, CMTime(value: cue.endMS, timescale: 1000)))
            let s = CMTimeMaximum(cursor, cueStart)
            if CMTimeCompare(s, cursor) > 0 {
                intervals.append(Interval(start: cursor, end: s, text: ""))
            }
            if CMTimeCompare(cueEnd, s) > 0 {
                intervals.append(Interval(start: s, end: cueEnd, text: cue.text))
                cursor = cueEnd
            }
        }
        if CMTimeCompare(duration, cursor) > 0 {
            intervals.append(Interval(start: cursor, end: duration, text: ""))
        }

        var samples: [CMSampleBuffer] = []
        samples.reserveCapacity(intervals.count)
        for iv in intervals {
            let sampleDuration = CMTimeSubtract(iv.end, iv.start)
            guard CMTimeCompare(sampleDuration, .zero) > 0 else { continue }
            let utf8 = Array(iv.text.utf8)
            guard utf8.count <= Int(UInt16.max) else {
                throw SafariumError.encode("subtitle cue exceeds 65535 UTF-8 bytes")
            }
            var payload = Data(capacity: 2 + utf8.count)
            let lenBE = UInt16(utf8.count).bigEndian
            withUnsafeBytes(of: lenBE) { payload.append(contentsOf: $0) }
            payload.append(contentsOf: utf8)

            var block: CMBlockBuffer?
            let st1 = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &block
            )
            guard st1 == noErr, let block else {
                throw SafariumError.encode("subtitle CMBlockBuffer creation failed (\(st1))")
            }
            let st2 = payload.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(
                    with: raw.baseAddress!, blockBuffer: block,
                    offsetIntoDestination: 0, dataLength: payload.count
                )
            }
            guard st2 == noErr else {
                throw SafariumError.encode("subtitle CMBlockBuffer copy failed (\(st2))")
            }

            var timing = CMSampleTimingInfo(
                duration: sampleDuration,
                presentationTimeStamp: iv.start,
                decodeTimeStamp: .invalid
            )
            var size = payload.count
            var sample: CMSampleBuffer?
            let st3 = CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fmt,
                sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
            )
            guard st3 == noErr, let sample else {
                throw SafariumError.encode("subtitle CMSampleBuffer creation failed (\(st3))")
            }
            samples.append(sample)
        }
        return (fmt, samples)
    }
}
