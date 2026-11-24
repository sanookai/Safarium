import CoreMedia
import CoreVideo
import Darwin
import Foundation
import SafariumCore
import VideoToolbox

// Pure-Swift ISO/IEC 13818-1 Program Stream (and ISO/IEC 11172-1 system stream) demuxer with
// bounded-chunk reads, MPEG-1/MPEG-2 video access-unit assembly and a VideoToolbox decode bridge.

// MARK: - Public Types

public struct MPEG2SequenceInfo: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let aspectRatioCode: Int
    public let displayAspectRatio: String
    public let frameRateCode: Int
    public let frameRateNumerator: Int
    public let frameRateDenominator: Int
    public let bitRateBps: Int
    public let isMPEG2: Bool
    public let profileAndLevel: Int?
    public let progressiveSequence: Bool?
    public let chromaFormat: Int?

    public var framesPerSecond: Double { Double(frameRateNumerator) / Double(frameRateDenominator) }
}

public struct MPEG2PSStreamStats: Codable, Sendable {
    public let streamID: Int
    public let kind: String
    public let pesPackets: Int
    public let payloadBytes: Int64
    public let firstPTS90k: Int64?
    public let lastPTS90k: Int64?
}

public struct MPEG2PSInspectReport: Codable, Sendable {
    public let path: String
    public let fileBytes: Int64
    public let systemLayer: String
    public let packCount: Int
    public let systemHeaderCount: Int
    public let firstSCR90k: Int64?
    public let lastSCR90k: Int64?
    public let streams: [MPEG2PSStreamStats]
    public let sequence: MPEG2SequenceInfo?
    public let pictureCount: Int
    public let iPictures: Int
    public let pPictures: Int
    public let bPictures: Int
    public let gopCount: Int
    public let durationSeconds: Double
    public let tracks: [ContainerTrackInfo]
}

public struct MPEG2PESPacket: Sendable {
    public let streamID: UInt8
    public let pts90k: Int64?
    public let dts90k: Int64?
    public let payload: Data
    public let fileOffset: Int64
    public let mpeg2Syntax: Bool
}

public enum MPEG2PictureType: Int, Codable, Sendable {
    case i = 1, p = 2, b = 3, d = 4, unknown = 0
}

public struct MPEG2VideoAccessUnit: Sendable {
    public let data: Data
    public let byteCount: Int
    public let pictureType: MPEG2PictureType
    public let temporalReference: Int
    public let pts90k: Int64?
    public let dts90k: Int64?
    public let hasSequenceHeader: Bool
    public let startsGOP: Bool
    public let closedGOP: Bool
    public let brokenLink: Bool
    public let pictureStructure: Int
}

public struct MPEG2PSDecodeSummary: Codable, Sendable {
    public let path: String
    public let codec: String
    public let width: Int
    public let height: Int
    public let accessUnitsSubmitted: Int
    public let framesDecoded: Int
    public let framesEmitted: Int
    public let firstPTS90k: Int64?
    public let lastPTS90k: Int64?
    public let pixelFormat: String
}

// MARK: - Bounded Byte Source

final class MPEG2PSByteSource {
    private let handle: FileHandle?
    private var buf: [UInt8]
    private var start = 0
    private var end = 0
    private var eof = false
    private let capacity: Int
    /// Absolute file offset of `buf[start]`.
    private(set) var position: Int64 = 0

    init(url: URL, capacity: Int = 1 << 20) throws {
        try SafeFilePublisher.assertRegularReadableFile(url)
        guard let h = FileHandle(forReadingAtPath: url.path) else {
            throw SafariumError.invalidState("cannot open MPEG program stream: \(url.path)")
        }
        handle = h
        self.capacity = max(capacity, 70_000)
        buf = [UInt8](repeating: 0, count: self.capacity)
    }

    init(data: Data) {
        handle = nil
        capacity = data.count
        buf = [UInt8](data)
        end = data.count
        eof = true
    }

    deinit { try? handle?.close() }

    var available: Int { end - start }
    var atEnd: Bool { eof && start == end }

    /// Ensures at least `n` bytes are buffered; returns false only at end of input.
    func ensure(_ n: Int) throws -> Bool {
        if n > capacity {
            // In-memory sources are sized exactly to their input, so a request beyond the window
            // means the input is truncated (caller reports it); file windows (>= 70 000 B) always
            // cover the largest PES/system header (6 + 65 535 B).
            precondition(eof, "MPEG-PS byte source request \(n) exceeds window \(capacity)")
            return false
        }
        while end - start < n {
            if eof { return false }
            if start > 0 {
                let count = end - start
                if count > 0 {
                    buf.withUnsafeMutableBufferPointer { p in
                        _ = memmove(p.baseAddress!, p.baseAddress! + start, count)
                    }
                }
                start = 0
                end = count
            }
            let want = capacity - end
            let chunk = try handle?.read(upToCount: want) ?? Data()
            if chunk.isEmpty {
                eof = true
                continue
            }
            buf.withUnsafeMutableBufferPointer { p in
                _ = chunk.copyBytes(to: UnsafeMutableBufferPointer(rebasing: p[end..<(end + chunk.count)]))
            }
            end += chunk.count
        }
        return true
    }

    @inline(__always) subscript(_ i: Int) -> UInt8 { buf[start + i] }

    func data(_ offset: Int, _ count: Int) -> Data {
        Data(buf[(start + offset)..<(start + offset + count)])
    }

    func consume(_ n: Int) {
        precondition(n <= end - start)
        start += n
        position += Int64(n)
    }

    /// Advances to the next 00 00 01 prefix; returns bytes skipped, or nil at end of input.
    func seekStartCode() throws -> Int? {
        var skipped = 0
        while true {
            guard try ensure(4) else {
                let rest = available
                consume(rest)
                return skipped + rest > 0 ? nil : nil
            }
            if self[0] == 0 && self[1] == 0 && self[2] == 1 { return skipped }
            consume(1)
            skipped += 1
        }
    }
}

// MARK: - Demuxer

public final class MPEG2ProgramStreamDemuxer {
    private let src: MPEG2PSByteSource
    public private(set) var packCount = 0
    public private(set) var systemHeaderCount = 0
    public private(set) var isMPEG2Pack: Bool?
    public private(set) var firstSCR90k: Int64?
    public private(set) var lastSCR90k: Int64?
    public private(set) var resyncBytes = 0
    private var unwrappers: [UInt8: (pts: TSPTSUnwrapper, dts: TSPTSUnwrapper)] = [:]
    private var scrUnwrapper = TSPTSUnwrapper()
    private var started = false

    public init(url: URL, chunkSize: Int = 1 << 20) throws {
        src = try MPEG2PSByteSource(url: url, capacity: min(max(chunkSize, 70_000), 1 << 20))
    }

    public init(data: Data) {
        src = MPEG2PSByteSource(data: data)
    }

    public var byteOffset: Int64 { src.position }

    private static func decodeTimestamp(_ s: MPEG2PSByteSource, _ o: Int) throws -> UInt64 {
        let b0 = UInt64(s[o]), b1 = UInt64(s[o + 1]), b2 = UInt64(s[o + 2]), b3 = UInt64(s[o + 3]), b4 = UInt64(s[o + 4])
        guard (b0 & 1) == 1, (b2 & 1) == 1, (b4 & 1) == 1 else {
            throw SafariumError.encode("MPEG-PS: PTS/DTS marker bits invalid at byte \(s.position + Int64(o))")
        }
        return ((b0 & 0x0E) << 29) | (b1 << 22) | ((b2 & 0xFE) << 14) | (b3 << 7) | ((b4 & 0xFE) >> 1)
    }

    /// Next PES packet of any stream (pack/system headers are parsed and counted along the way).
    public func nextPES() throws -> MPEG2PESPacket? {
        while true {
            guard try src.ensure(4) else {
                if src.available > 0 {
                    throw SafariumError.encode("MPEG-PS: \(src.available) trailing bytes after last packet at byte \(src.position)")
                }
                return nil
            }
            guard src[0] == 0, src[1] == 0, src[2] == 1 else {
                guard started else {
                    throw SafariumError.encode("MPEG-PS: stream does not begin with a start code (not a program stream)")
                }
                guard let skipped = try src.seekStartCode() else { return nil }
                resyncBytes += skipped
                continue
            }
            let code = src[3]
            switch code {
            case 0xBA:
                try parsePack()
                started = true
            case 0xBB:
                guard try src.ensure(6) else { throw SafariumError.encode("MPEG-PS: truncated system header at byte \(src.position)") }
                let len = (Int(src[4]) << 8) | Int(src[5])
                guard len >= 6, try src.ensure(6 + len) else {
                    throw SafariumError.encode("MPEG-PS: truncated/invalid system header (length \(len)) at byte \(src.position)")
                }
                systemHeaderCount += 1
                src.consume(6 + len)
            case 0xB9:
                src.consume(4)
            case 0xBC...0xFF:
                guard started else {
                    throw SafariumError.encode("MPEG-PS: PES packet before first pack header")
                }
                if let pes = try parsePES(streamID: code) { return pes }
            default:
                throw SafariumError.encode(String(format: "MPEG-PS: unexpected start code 0x%02X at system layer, byte %lld", code, src.position))
            }
        }
    }

    private func parsePack() throws {
        guard try src.ensure(12) else { throw SafariumError.encode("MPEG-PS: truncated pack header at byte \(src.position)") }
        let b4 = src[4]
        if (b4 & 0xC0) == 0x40 {
            guard try src.ensure(14) else { throw SafariumError.encode("MPEG-PS: truncated MPEG-2 pack header at byte \(src.position)") }
            guard (b4 & 0x04) != 0, (src[6] & 0x04) != 0, (src[8] & 0x04) != 0, (src[9] & 0x01) != 0, (src[12] & 0x03) == 0x03 else {
                throw SafariumError.encode("MPEG-PS: corrupt MPEG-2 pack header marker bits at byte \(src.position)")
            }
            let scr = (UInt64((b4 >> 3) & 0x07) << 30) | (UInt64(b4 & 0x03) << 28) | (UInt64(src[5]) << 20)
                | (UInt64(src[6] >> 3) << 15) | (UInt64(src[6] & 0x03) << 13) | (UInt64(src[7]) << 5) | UInt64(src[8] >> 3)
            let stuffing = Int(src[13] & 0x07)
            guard try src.ensure(14 + stuffing) else { throw SafariumError.encode("MPEG-PS: truncated pack stuffing at byte \(src.position)") }
            if isMPEG2Pack == false { throw SafariumError.encode("MPEG-PS: mixed MPEG-1/MPEG-2 pack headers") }
            isMPEG2Pack = true
            noteSCR(scr)
            src.consume(14 + stuffing)
        } else if (b4 & 0xF0) == 0x20 {
            guard (b4 & 0x01) != 0, (src[6] & 0x01) != 0, (src[8] & 0x01) != 0, (src[9] & 0x80) != 0, (src[11] & 0x01) != 0 else {
                throw SafariumError.encode("MPEG-PS: corrupt MPEG-1 pack header marker bits at byte \(src.position)")
            }
            let scr = (UInt64((b4 >> 1) & 0x07) << 30) | (UInt64(src[5]) << 22) | (UInt64(src[6] >> 1) << 15)
                | (UInt64(src[7]) << 7) | UInt64(src[8] >> 1)
            if isMPEG2Pack == true { throw SafariumError.encode("MPEG-PS: mixed MPEG-1/MPEG-2 pack headers") }
            isMPEG2Pack = false
            noteSCR(scr)
            src.consume(12)
        } else {
            throw SafariumError.encode(String(format: "MPEG-PS: corrupt pack header (byte4 0x%02X) at byte %lld", b4, src.position))
        }
        packCount += 1
    }

    private func noteSCR(_ raw: UInt64) {
        let v = scrUnwrapper.unwrap(raw)
        if firstSCR90k == nil { firstSCR90k = v }
        lastSCR90k = v
    }

    private func parsePES(streamID: UInt8) throws -> MPEG2PESPacket? {
        let off = src.position
        guard try src.ensure(6) else { throw SafariumError.encode("MPEG-PS: truncated PES header at byte \(off)") }
        let len = (Int(src[4]) << 8) | Int(src[5])
        guard len > 0 else {
            throw SafariumError.encode(String(format: "MPEG-PS: zero PES_packet_length for stream 0x%02X at byte %lld", streamID, off))
        }
        guard try src.ensure(6 + len) else {
            throw SafariumError.encode(String(format: "MPEG-PS: truncated PES packet (stream 0x%02X, declared %d bytes, %d available) at byte %lld", streamID, len, src.available - 6, off))
        }
        let total = 6 + len
        // Streams without the optional PES header: program_stream_map, padding, private_2, ECM/EMM, directory, H.222.1 E.
        let noHeader: Set<UInt8> = [0xBC, 0xBE, 0xBF, 0xF0, 0xF1, 0xF2, 0xF8, 0xFF]
        if noHeader.contains(streamID) {
            let payload = streamID == 0xBE ? Data() : src.data(6, len)
            src.consume(total)
            return MPEG2PESPacket(streamID: streamID, pts90k: nil, dts90k: nil, payload: payload, fileOffset: off, mpeg2Syntax: false)
        }
        var pts: UInt64?
        var dts: UInt64?
        var payloadStart: Int
        let mpeg2 = (src[6] & 0xC0) == 0x80
        if mpeg2 {
            guard len >= 3 else { throw SafariumError.encode("MPEG-PS: PES header longer than packet at byte \(off)") }
            let flags = src[7]
            let hdrLen = Int(src[8])
            payloadStart = 9 + hdrLen
            guard payloadStart <= total else {
                throw SafariumError.encode("MPEG-PS: PES_header_data_length \(hdrLen) exceeds packet at byte \(off)")
            }
            let ptsDts = flags >> 6
            if ptsDts == 2 || ptsDts == 3 {
                guard hdrLen >= 5 else { throw SafariumError.encode("MPEG-PS: PES header too short for PTS at byte \(off)") }
                pts = try Self.decodeTimestamp(src, 9)
            }
            if ptsDts == 3 {
                guard hdrLen >= 10 else { throw SafariumError.encode("MPEG-PS: PES header too short for DTS at byte \(off)") }
                dts = try Self.decodeTimestamp(src, 14)
            }
            if ptsDts == 1 { throw SafariumError.encode("MPEG-PS: forbidden PTS_DTS_flags '01' at byte \(off)") }
        } else {
            var p = 6
            var stuffing = 0
            while p < total && src[p] == 0xFF {
                p += 1
                stuffing += 1
                guard stuffing <= 16 else { throw SafariumError.encode("MPEG-PS: excessive MPEG-1 PES stuffing at byte \(off)") }
            }
            guard p < total else { throw SafariumError.encode("MPEG-PS: MPEG-1 PES header truncated at byte \(off)") }
            if (src[p] & 0xC0) == 0x40 { p += 2 }
            guard p < total else { throw SafariumError.encode("MPEG-PS: MPEG-1 PES header truncated at byte \(off)") }
            let t = src[p] & 0xF0
            if t == 0x20 {
                guard p + 5 <= total else { throw SafariumError.encode("MPEG-PS: MPEG-1 PES PTS truncated at byte \(off)") }
                pts = try Self.decodeTimestamp(src, p)
                p += 5
            } else if t == 0x30 {
                guard p + 10 <= total else { throw SafariumError.encode("MPEG-PS: MPEG-1 PES PTS/DTS truncated at byte \(off)") }
                pts = try Self.decodeTimestamp(src, p)
                dts = try Self.decodeTimestamp(src, p + 5)
                p += 10
            } else if src[p] == 0x0F {
                p += 1
            } else {
                throw SafariumError.encode(String(format: "MPEG-PS: invalid MPEG-1 PES header byte 0x%02X at byte %lld", src[p], off))
            }
            payloadStart = p
        }
        var uw = unwrappers[streamID] ?? (TSPTSUnwrapper(), TSPTSUnwrapper())
        let ptsU = pts.map { uw.pts.unwrap($0) }
        let dtsU = dts.map { uw.dts.unwrap($0) }
        unwrappers[streamID] = uw
        let payload = src.data(payloadStart, total - payloadStart)
        src.consume(total)
        return MPEG2PESPacket(streamID: streamID, pts90k: ptsU, dts90k: dtsU ?? ptsU, payload: payload, fileOffset: off, mpeg2Syntax: mpeg2)
    }
}

// MARK: - Video Elementary Stream Assembler

/// Splits an MPEG-1/MPEG-2 video elementary stream into picture access units
/// (sequence header / GOP header / picture + slices), pairing field pictures.
public final class MPEG2VideoAccessUnitAssembler {
    public static let maxAccessUnitBytes = 16 * 1024 * 1024

    public private(set) var sequence: MPEG2SequenceInfo?
    public private(set) var sawSequenceExtension = false
    public private(set) var gopCount = 0
    public let retainData: Bool

    private var es: [UInt8] = []
    private var scanPos = 0
    private var auStart = -1
    private var hasPicture = false
    private var pictureType: MPEG2PictureType = .unknown
    private var temporalRef = 0
    private var pictureStructure = 3
    private var fieldCount = 0
    private var auHasSeq = false
    private var auStartsGOP = false
    private var closedGOP = false
    private var brokenLink = false
    private var auPTS: Int64?
    private var auDTS: Int64?
    private var timestamps: [(offset: Int, pts: Int64?, dts: Int64?)] = []
    private var timestampHead = 0
    private var baseSequence: (w: Int, h: Int, aspect: Int, frc: Int, bitrate: Int)?

    public init(retainData: Bool = true) {
        self.retainData = retainData
    }

    /// Appends one PES payload; returns completed access units in decode order.
    public func append(_ payload: Data, pts90k: Int64?, dts90k: Int64?) throws -> [MPEG2VideoAccessUnit] {
        if pts90k != nil {
            timestamps.append((es.count, pts90k, dts90k))
            if timestamps.count - timestampHead > 65_536 {
                throw SafariumError.encode("MPEG video: timestamp queue exceeded 65536 entries")
            }
        }
        es.append(contentsOf: payload)
        return try scan(final: false)
    }

    public func finish() throws -> [MPEG2VideoAccessUnit] {
        var out = try scan(final: true)
        if auStart >= 0 && hasPicture {
            out.append(makeAU(end: es.count))
        }
        es.removeAll()
        timestamps.removeAll()
        timestampHead = 0
        auStart = -1
        hasPicture = false
        return out
    }

    private func makeAU(end: Int) -> MPEG2VideoAccessUnit {
        let size = end - auStart
        let au = MPEG2VideoAccessUnit(
            data: retainData ? Data(es[auStart..<end]) : Data(),
            byteCount: size,
            pictureType: pictureType,
            temporalReference: temporalRef,
            pts90k: auPTS,
            dts90k: auDTS,
            hasSequenceHeader: auHasSeq,
            startsGOP: auStartsGOP,
            closedGOP: closedGOP,
            brokenLink: brokenLink,
            pictureStructure: pictureStructure
        )
        return au
    }

    private func beginAU(at o: Int) {
        auStart = o
        hasPicture = false
        auHasSeq = false
        auStartsGOP = false
        auPTS = nil
        auDTS = nil
        fieldCount = 0
        pictureStructure = 3
    }

    private func scan(final: Bool) throws -> [MPEG2VideoAccessUnit] {
        var out: [MPEG2VideoAccessUnit] = []
        let n = es.count
        var i = max(0, scanPos)
        while i + 3 < n {
            // Fast search for the 0x01 of a 00 00 01 prefix.
            let found: Int? = es.withUnsafeBufferPointer { p -> Int? in
                guard let basePtr = p.baseAddress else { return nil }
                let searchStart = basePtr + i + 2
                guard let hit = memchr(searchStart, 1, n - i - 2) else { return nil }
                let hitPtr = UnsafePointer<UInt8>(hit.assumingMemoryBound(to: UInt8.self))
                return basePtr.distance(to: hitPtr) - 2
            }
            guard let o = found else { i = n - 2; break }
            if es[o] != 0 || es[o + 1] != 0 {
                i = o + 1
                continue
            }
            guard o + 3 < n else { i = o; break }
            let code = es[o + 3]
            // Need a few bytes after the start code to parse headers.
            let need: Int
            switch code {
            case 0xB3: need = 12
            case 0xB5: need = 10
            case 0xB8: need = 8
            case 0x00: need = 6
            default: need = 4
            }
            if o + need > n && !final { i = o; break }
            if o + need > n { i = n; break }

            switch code {
            case 0xB3, 0xB8, 0x00:
                var split = hasPicture
                if code == 0x00 && hasPicture && pictureStructure != 3 && fieldCount == 1 {
                    split = false // second field of a field-picture pair
                }
                if split && auStart >= 0 {
                    out.append(makeAU(end: o))
                    beginAU(at: o)
                } else if auStart < 0 && (code == 0xB3 || sequence != nil) {
                    beginAU(at: o)
                }
                if code == 0xB3 {
                    try parseSequenceHeader(o)
                    auHasSeq = true
                } else if code == 0xB8 {
                    closedGOP = (es[o + 7] & 0x40) != 0
                    brokenLink = (es[o + 7] & 0x20) != 0
                    auStartsGOP = true
                    gopCount += 1
                } else if auStart >= 0 {
                    let tr = (Int(es[o + 4]) << 2) | Int(es[o + 5] >> 6)
                    let pt = Int((es[o + 5] >> 3) & 0x07)
                    // A PES PTS applies to the first picture start code beginning in that PES payload:
                    // consume every pending PES timestamp that started at or before this picture.
                    var chosen: (pts: Int64?, dts: Int64?)?
                    while timestampHead < timestamps.count, timestamps[timestampHead].offset <= o {
                        let first = timestamps[timestampHead]
                        chosen = (first.pts, first.dts)
                        timestampHead += 1
                    }
                    if timestampHead >= 1024 {
                        timestamps.removeFirst(timestampHead)
                        timestampHead = 0
                    }
                    if !hasPicture {
                        temporalRef = tr
                        pictureType = MPEG2PictureType(rawValue: pt) ?? .unknown
                        if let chosen {
                            auPTS = chosen.pts
                            auDTS = chosen.dts
                        }
                    }
                    hasPicture = true
                    fieldCount += 1
                }
            case 0xB5:
                let ext = es[o + 4] >> 4
                if ext == 1 {
                    sawSequenceExtension = true
                    try parseSequenceExtension(o)
                } else if ext == 8 && hasPicture {
                    if fieldCount <= 1 { pictureStructure = Int(es[o + 6] & 0x03) }
                }
            case 0xB7:
                if auStart >= 0 && hasPicture {
                    out.append(makeAU(end: o + 4))
                    auStart = -1
                    hasPicture = false
                }
            default:
                break
            }
            i = o + 3
        }
        scanPos = i
        // Compact consumed bytes.
        let keepFrom = auStart >= 0 ? auStart : max(0, min(scanPos, es.count - 3))
        if keepFrom > 0 {
            es.removeFirst(keepFrom)
            if auStart >= 0 { auStart -= keepFrom }
            scanPos -= keepFrom
            // Timestamps of PES packets that began before the kept region still apply to the next picture.
            if timestampHead > 0 {
                timestamps.removeFirst(timestampHead)
                timestampHead = 0
            }
            for idx in timestamps.indices {
                timestamps[idx].offset = max(0, timestamps[idx].offset - keepFrom)
            }
        }
        if es.count > Self.maxAccessUnitBytes {
            throw SafariumError.encode("MPEG video: access unit exceeds \(Self.maxAccessUnitBytes) bytes (corrupt elementary stream)")
        }
        return out
    }

    private static let frameRates: [(Int, Int)] = [
        (0, 1), (24000, 1001), (24, 1), (25, 1), (30000, 1001), (30, 1), (50, 1), (60000, 1001), (60, 1),
    ]

    private func parseSequenceHeader(_ o: Int) throws {
        let w = (Int(es[o + 4]) << 4) | Int(es[o + 5] >> 4)
        let h = (Int(es[o + 5] & 0x0F) << 8) | Int(es[o + 6])
        let aspect = Int(es[o + 7] >> 4)
        let frc = Int(es[o + 7] & 0x0F)
        let bitrate = (Int(es[o + 8]) << 10) | (Int(es[o + 9]) << 2) | Int(es[o + 10] >> 6)
        guard w > 0, h > 0, (1...8).contains(frc), (es[o + 10] & 0x20) != 0 else {
            throw SafariumError.encode("MPEG video: invalid sequence header (\(w)x\(h), frame_rate_code \(frc))")
        }
        baseSequence = (w, h, aspect, frc, bitrate)
        if sequence == nil || !(sequence!.isMPEG2) {
            sequence = Self.makeInfo(base: baseSequence!, ext: nil)
        }
    }

    private func parseSequenceExtension(_ o: Int) throws {
        guard let base = baseSequence else { return }
        let b4 = Int(es[o + 4]), b5 = Int(es[o + 5]), b6 = Int(es[o + 6]), b7 = Int(es[o + 7]), b9 = Int(es[o + 9])
        let pl = ((b4 & 0x0F) << 4) | (b5 >> 4)
        let progressive = (b5 & 0x08) != 0
        let chroma = (b5 >> 1) & 0x03
        let hExt = ((b5 & 0x01) << 1) | (b6 >> 7)
        let vExt = (b6 >> 5) & 0x03
        let brExt = ((b6 & 0x1F) << 7) | (b7 >> 1)
        let frn = (b9 >> 5) & 0x03
        let frd = b9 & 0x1F
        sequence = Self.makeInfo(base: base, ext: (pl, progressive, chroma, hExt, vExt, brExt, frn, frd))
    }

    private static func makeInfo(
        base: (w: Int, h: Int, aspect: Int, frc: Int, bitrate: Int),
        ext: (pl: Int, progressive: Bool, chroma: Int, hExt: Int, vExt: Int, brExt: Int, frn: Int, frd: Int)?
    ) -> MPEG2SequenceInfo {
        let (num0, den0) = frameRates[base.frc]
        var num = num0
        var den = den0
        var w = base.w
        var h = base.h
        var bitrate = base.bitrate
        if let e = ext {
            w |= e.hExt << 12
            h |= e.vExt << 12
            bitrate |= e.brExt << 18
            num *= (e.frn + 1)
            den *= (e.frd + 1)
        }
        let dar: String
        if ext != nil {
            switch base.aspect {
            case 1: dar = "1:1 SAR"
            case 2: dar = "4:3"
            case 3: dar = "16:9"
            case 4: dar = "2.21:1"
            default: dar = "reserved(\(base.aspect))"
            }
        } else {
            let pel: [Double] = [0, 1.0, 0.6735, 0.7031, 0.7615, 0.8055, 0.8437, 0.8935, 0.9157, 0.9815, 1.0255, 1.0695, 1.0950, 1.1575, 1.2015, 0]
            let p = base.aspect < pel.count ? pel[base.aspect] : 0
            dar = p > 0 ? String(format: "%.4f:1 (MPEG-1 pel aspect %.4f)", Double(w) / (Double(h) * p), p) : "reserved(\(base.aspect))"
        }
        return MPEG2SequenceInfo(
            width: w,
            height: h,
            aspectRatioCode: base.aspect,
            displayAspectRatio: dar,
            frameRateCode: base.frc,
            frameRateNumerator: num,
            frameRateDenominator: den,
            bitRateBps: bitrate * 400,
            isMPEG2: ext != nil,
            profileAndLevel: ext?.pl,
            progressiveSequence: ext?.progressive,
            chromaFormat: ext?.chroma
        )
    }
}

// MARK: - Facade

public enum MPEG2ProgramStream {
    private static func streamKind(_ id: UInt8) -> String {
        switch id {
        case 0xE0...0xEF: return "video"
        case 0xC0...0xDF: return "audio"
        case 0xBD: return "private_stream_1"
        case 0xBF: return "private_stream_2"
        case 0xBE: return "padding"
        case 0xBC: return "program_stream_map"
        default: return "other"
        }
    }

    /// Streams the whole file through a <= 1 MiB window and reports packs, streams and video pictures.
    public static func inspect(url: URL) throws -> MPEG2PSInspectReport {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let demux = try MPEG2ProgramStreamDemuxer(url: url)
        return try inspect(demux: demux, path: url.path, fileBytes: size)
    }

    public static func inspect(data: Data) throws -> MPEG2PSInspectReport {
        try inspect(demux: MPEG2ProgramStreamDemuxer(data: data), path: "<memory>", fileBytes: Int64(data.count))
    }

    private static func inspect(demux: MPEG2ProgramStreamDemuxer, path: String, fileBytes: Int64) throws -> MPEG2PSInspectReport {
        var stats: [UInt8: (packets: Int, bytes: Int64, first: Int64?, last: Int64?)] = [:]
        var videoID: UInt8?
        let asm = MPEG2VideoAccessUnitAssembler(retainData: false)
        var pictures = 0, iCount = 0, pCount = 0, bCount = 0
        var minPTS: Int64?
        var maxPTS: Int64?
        func count(_ aus: [MPEG2VideoAccessUnit]) {
            for au in aus {
                pictures += 1
                switch au.pictureType {
                case .i: iCount += 1
                case .p: pCount += 1
                case .b: bCount += 1
                default: break
                }
            }
        }
        while let pes = try demux.nextPES() {
            var s = stats[pes.streamID] ?? (0, 0, nil, nil)
            s.packets += 1
            s.bytes += Int64(pes.payload.count)
            if let p = pes.pts90k {
                if s.first == nil { s.first = p }
                s.last = p
            }
            stats[pes.streamID] = s
            if (0xE0...0xEF).contains(pes.streamID) {
                if videoID == nil { videoID = pes.streamID }
                guard pes.streamID == videoID else { continue }
                if let p = pes.pts90k {
                    minPTS = min(minPTS ?? p, p)
                    maxPTS = max(maxPTS ?? p, p)
                }
                count(try asm.append(pes.payload, pts90k: pes.pts90k, dts90k: pes.dts90k))
            }
        }
        count(try asm.finish())
        guard demux.packCount > 0 else {
            throw SafariumError.encode("MPEG-PS: no pack headers found in \(path)")
        }
        let streams = stats.keys.sorted().map { id -> MPEG2PSStreamStats in
            let s = stats[id]!
            return MPEG2PSStreamStats(streamID: Int(id), kind: streamKind(id), pesPackets: s.packets, payloadBytes: s.bytes, firstPTS90k: s.first, lastPTS90k: s.last)
        }
        var tracks: [ContainerTrackInfo] = []
        for s in streams where s.kind == "video" || s.kind == "audio" || s.kind == "private_stream_1" {
            if s.kind == "video" {
                let seq = asm.sequence
                tracks.append(ContainerTrackInfo(
                    trackNumber: s.streamID,
                    kind: .video,
                    codecID: (seq?.isMPEG2 ?? false) ? "MPEG2" : "MPEG1",
                    width: seq?.width,
                    height: seq?.height
                ))
            } else {
                tracks.append(ContainerTrackInfo(
                    trackNumber: s.streamID,
                    kind: .audio,
                    codecID: s.kind == "audio" ? "MPEG_AUDIO" : "PRIVATE_1"
                ))
            }
        }
        var duration = 0.0
        if let a = minPTS, let b = maxPTS, b > a {
            let fd = asm.sequence.map { Double($0.frameRateDenominator) / Double($0.frameRateNumerator) } ?? 0
            duration = Double(b - a) / 90_000.0 + fd
        } else if let a = demux.firstSCR90k, let b = demux.lastSCR90k, b > a {
            duration = Double(b - a) / 90_000.0
        }
        return MPEG2PSInspectReport(
            path: path,
            fileBytes: fileBytes,
            systemLayer: (demux.isMPEG2Pack ?? false) ? "MPEG-2 Program Stream" : "MPEG-1 System Stream",
            packCount: demux.packCount,
            systemHeaderCount: demux.systemHeaderCount,
            firstSCR90k: demux.firstSCR90k,
            lastSCR90k: demux.lastSCR90k,
            streams: streams,
            sequence: asm.sequence,
            pictureCount: pictures,
            iPictures: iCount,
            pPictures: pCount,
            bPictures: bCount,
            gopCount: asm.gopCount,
            durationSeconds: duration,
            tracks: tracks
        )
    }

    private final class FrameCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [(pts: CMTime, buffer: CVPixelBuffer)] = []
        private var firstError: OSStatus = noErr
        private var decoded = 0

        func currentError() -> OSStatus {
            lock.withLock { firstError }
        }

        func decodedCount() -> Int {
            lock.withLock { decoded }
        }

        func add(status: OSStatus, flags: VTDecodeInfoFlags, image: CVImageBuffer?, pts: CMTime) {
            lock.lock()
            defer { lock.unlock() }
            if status != noErr {
                if firstError == noErr { firstError = status }
                return
            }
            guard !flags.contains(.frameDropped), let image else { return }
            decoded += 1
            frames.append((pts, image))
        }

        /// Removes and returns frames in presentation order while more than `keep` are buffered.
        func drain(keep: Int) -> [(pts: CMTime, buffer: CVPixelBuffer)] {
            lock.lock()
            defer { lock.unlock() }
            guard frames.count > keep else { return [] }
            frames.sort { CMTimeCompare($0.pts, $1.pts) < 0 }
            let n = frames.count - keep
            let out = Array(frames.prefix(n))
            frames.removeFirst(n)
            return out
        }
    }

    /// Decodes up to `maxFrames` pictures (presentation order) with VideoToolbox, streaming each
    /// `CVPixelBuffer` to `onFrame` with a small bounded reorder window. Throws on any OSStatus error.
    @discardableResult
    public static func decodeVideoFrames(
        url: URL,
        maxFrames: Int,
        onFrame: (_ pixelBuffer: CVPixelBuffer, _ pts: CMTime, _ index: Int) throws -> Void
    ) throws -> MPEG2PSDecodeSummary {
        guard maxFrames > 0 else { throw SafariumError.invalidState("maxFrames must be positive") }
        let demux = try MPEG2ProgramStreamDemuxer(url: url)
        let asm = MPEG2VideoAccessUnitAssembler(retainData: true)
        let collector = FrameCollector()
        var session: VTDecompressionSession?
        var formatDesc: CMVideoFormatDescription?
        var codecName = ""
        var seqInfo: MPEG2SequenceInfo?
        var submitted = 0
        var emitted = 0
        var firstPTS: Int64?
        var lastPTS: Int64?
        var videoID: UInt8?
        var skippingLeadingB = false
        var gopAnchor: (pts: Int64, tr: Int)?
        var lastPTSAssigned: Int64?
        var frameDur90k: Int64 = 3003
        var pixelFormat = ""
        let reorderDepth = 4

        defer {
            if let session {
                VTDecompressionSessionInvalidate(session)
            }
        }

        func emit(_ frames: [(pts: CMTime, buffer: CVPixelBuffer)]) throws {
            for f in frames where emitted < maxFrames {
                if pixelFormat.isEmpty {
                    pixelFormat = MediaCompatBridge.fourCCString(CVPixelBufferGetPixelFormatType(f.buffer))
                }
                let p = f.pts.isValid ? Int64((f.pts.seconds * 90_000).rounded()) : nil
                if let p {
                    if firstPTS == nil { firstPTS = p }
                    lastPTS = p
                }
                try onFrame(f.buffer, f.pts, emitted)
                emitted += 1
            }
        }

        func checkError() throws {
            let st = collector.currentError()
            if st != noErr {
                throw SafariumError.encode("VideoToolbox \(codecName) decode failed: OSStatus \(st)")
            }
        }

        func submit(_ au: MPEG2VideoAccessUnit) throws {
            if session == nil {
                guard au.hasSequenceHeader, au.pictureType == .i, let seq = asm.sequence else { return }
                seqInfo = seq
                let codecType: CMVideoCodecType = asm.sawSequenceExtension ? kCMVideoCodecType_MPEG2Video : kCMVideoCodecType_MPEG1Video
                codecName = asm.sawSequenceExtension ? "MPEG-2" : "MPEG-1"
                frameDur90k = Int64((90_000.0 * Double(seq.frameRateDenominator) / Double(seq.frameRateNumerator)).rounded())
                var fd: CMVideoFormatDescription?
                let st1 = CMVideoFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    codecType: codecType,
                    width: Int32(seq.width),
                    height: Int32(seq.height),
                    extensions: nil,
                    formatDescriptionOut: &fd
                )
                guard st1 == noErr, let fd else {
                    throw SafariumError.encode("VideoToolbox \(codecName) decode failed: OSStatus \(st1) (CMVideoFormatDescriptionCreate)")
                }
                let attrs: [CFString: Any] = [
                    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                ]
                var s: VTDecompressionSession?
                let st2 = VTDecompressionSessionCreate(
                    allocator: kCFAllocatorDefault,
                    formatDescription: fd,
                    decoderSpecification: nil,
                    imageBufferAttributes: attrs as CFDictionary,
                    outputCallback: nil,
                    decompressionSessionOut: &s
                )
                guard st2 == noErr, let s else {
                    throw SafariumError.encode("VideoToolbox \(codecName) decode failed: OSStatus \(st2) (VTDecompressionSessionCreate)")
                }
                session = s
                formatDesc = fd
                skippingLeadingB = !au.closedGOP
            }
            guard let session, let formatDesc else { return }
            if au.startsGOP { gopAnchor = nil }
            if au.pictureType == .b && skippingLeadingB { return }
            if au.pictureType == .i || au.pictureType == .p {
                if au.pictureType == .p { skippingLeadingB = false }
            }
            if au.pictureType == .i && submitted > 0 { skippingLeadingB = false }
            // Presentation timestamp: PES PTS, else derived from temporal_reference within the GOP.
            var pts: Int64
            if let p = au.pts90k {
                pts = p
                gopAnchor = (p, au.temporalReference)
            } else if let a = gopAnchor {
                pts = a.pts + Int64(au.temporalReference - a.tr) * frameDur90k
            } else {
                pts = (lastPTSAssigned ?? 0) + frameDur90k
            }
            lastPTSAssigned = max(lastPTSAssigned ?? pts, pts)
            let sb = try MediaCompatBridge.makeReadySampleBuffer(
                data: au.data,
                formatDescription: formatDesc,
                pts: CMTime(value: pts, timescale: 90_000),
                dts: .invalid,
                duration: CMTime(value: frameDur90k, timescale: 90_000),
                isSync: au.pictureType == .i
            )
            let st = VTDecompressionSessionDecodeFrame(
                session,
                sampleBuffer: sb,
                flags: [._EnableTemporalProcessing],
                infoFlagsOut: nil
            ) { status, flags, image, ptsOut, _ in
                collector.add(status: status, flags: flags, image: image, pts: ptsOut)
            }
            submitted += 1
            if st != noErr {
                throw SafariumError.encode("VideoToolbox \(codecName) decode failed: OSStatus \(st)")
            }
            try checkError()
            try emit(collector.drain(keep: reorderDepth))
        }

        outer: while emitted < maxFrames, let pes = try demux.nextPES() {
            guard (0xE0...0xEF).contains(pes.streamID) else { continue }
            if videoID == nil { videoID = pes.streamID }
            guard pes.streamID == videoID else { continue }
            for au in try asm.append(pes.payload, pts90k: pes.pts90k, dts90k: pes.dts90k) {
                try submit(au)
                if emitted >= maxFrames { break outer }
            }
        }
        if emitted < maxFrames {
            for au in try asm.finish() {
                try submit(au)
                if emitted >= maxFrames { break }
            }
        }
        if let session {
            let s1 = VTDecompressionSessionFinishDelayedFrames(session)
            let s2 = VTDecompressionSessionWaitForAsynchronousFrames(session)
            guard s1 == noErr, s2 == noErr else {
                throw SafariumError.encode("VideoToolbox \(codecName) decode failed: OSStatus \(s1 != noErr ? s1 : s2) (flush)")
            }
            try checkError()
            try emit(collector.drain(keep: 0))
        } else {
            throw SafariumError.encode("MPEG-PS: no decodable sequence header + I picture found in \(url.lastPathComponent)")
        }
        guard let seqInfo else {
            throw SafariumError.encode("MPEG-PS: missing sequence header in \(url.lastPathComponent)")
        }
        return MPEG2PSDecodeSummary(
            path: url.path,
            codec: codecName,
            width: seqInfo.width,
            height: seqInfo.height,
            accessUnitsSubmitted: submitted,
            framesDecoded: collector.decodedCount(),
            framesEmitted: emitted,
            firstPTS90k: firstPTS,
            lastPTS90k: lastPTS,
            pixelFormat: pixelFormat
        )
    }
}
