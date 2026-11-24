@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import SafariumCore

public struct TSPTSUnwrapper: Sendable {
    public static let modulus: Int64 = 1 << 33
    private static let halfRange: UInt64 = 1 << 32

    private var prevRaw: UInt64?
    private var wraps: Int64 = 0

    public init() {}

    public mutating func unwrap(_ raw33: UInt64) -> Int64 {
        let r = raw33 & 0x1_FFFF_FFFF
        if let prev = prevRaw {
            if prev > r && (prev - r) > Self.halfRange {
                wraps += 1
            } else if r > prev && (r - prev) > Self.halfRange && wraps > 0 {
                wraps -= 1
            }
        }
        prevRaw = r
        return Int64(r) + wraps * Self.modulus
    }
}

public struct MPEGTSInspectReport: Codable, Sendable {
    public let path: String
    public let packetCount: Int
    public let pmtPID: Int
    public let tracks: [ContainerTrackInfo]
    public let streamTypesByPID: [Int: UInt8]
    public let videoPackets: Int
    public let audioPackets: Int
    public let durationSeconds: Double
    public let crcErrors: Int

    public init(
        path: String,
        packetCount: Int,
        pmtPID: Int,
        tracks: [ContainerTrackInfo],
        streamTypesByPID: [Int: UInt8],
        videoPackets: Int,
        audioPackets: Int,
        durationSeconds: Double,
        crcErrors: Int
    ) {
        self.path = path
        self.packetCount = packetCount
        self.pmtPID = pmtPID
        self.tracks = tracks
        self.streamTypesByPID = streamTypesByPID
        self.videoPackets = videoPackets
        self.audioPackets = audioPackets
        self.durationSeconds = durationSeconds
        self.crcErrors = crcErrors
    }
}

public enum MPEGTSCodec {
    private enum VideoCodecKind {
        case h264
        case hevc
    }

    private struct DemuxedTSUnit {
        let pid: UInt16
        let streamType: UInt8
        let pts90k: Int64
        let dts90k: Int64
        let isRandomAccess: Bool
        let payload: Data
    }

    private struct ParsedTS {
        let packetCount: Int
        let pmtPID: UInt16
        let pidStreamTypes: [UInt16: UInt8]
        let crcErrors: Int
        let units: [DemuxedTSUnit]
    }

    // MARK: - CRC-32 / MPEG-2

    private static func mpeg2CRC32(_ bytes: Data) -> UInt32 {
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

    // MARK: - Annex-B <-> AVCC/HVCC

    private static func parseAVCCParameterSets(_ avcC: Data) throws -> [Data] {
        let b = [UInt8](avcC)
        guard b.count >= 7 else {
            throw SafariumError.encode("avcC atom too short (\(b.count) bytes)")
        }
        var p = 5
        let numSPS = Int(b[p] & 0x1F)
        p += 1
        var sets: [Data] = []
        for _ in 0..<numSPS {
            guard p + 2 <= b.count else { throw SafariumError.encode("avcC truncated SPS") }
            let len = (Int(b[p]) << 8) | Int(b[p + 1])
            p += 2
            guard p + len <= b.count else { throw SafariumError.encode("avcC truncated SPS data") }
            sets.append(Data(b[p..<(p + len)]))
            p += len
        }
        guard p < b.count else { throw SafariumError.encode("avcC missing PPS count") }
        let numPPS = Int(b[p])
        p += 1
        for _ in 0..<numPPS {
            guard p + 2 <= b.count else { throw SafariumError.encode("avcC truncated PPS") }
            let len = (Int(b[p]) << 8) | Int(b[p + 1])
            p += 2
            guard p + len <= b.count else { throw SafariumError.encode("avcC truncated PPS data") }
            sets.append(Data(b[p..<(p + len)]))
            p += len
        }
        return sets
    }

    private static func parseHVCCParameterSets(_ hvcC: Data) throws -> [Data] {
        let b = [UInt8](hvcC)
        guard b.count >= 23 else {
            throw SafariumError.encode("hvcC atom too short (\(b.count) bytes)")
        }
        let numArrays = Int(b[22])
        var p = 23
        var sets: [Data] = []
        for _ in 0..<numArrays {
            guard p + 3 <= b.count else { throw SafariumError.encode("hvcC truncated array") }
            p += 1
            let count = (Int(b[p]) << 8) | Int(b[p + 1])
            p += 2
            for _ in 0..<count {
                guard p + 2 <= b.count else { throw SafariumError.encode("hvcC truncated nalu") }
                let len = (Int(b[p]) << 8) | Int(b[p + 1])
                p += 2
                guard p + len <= b.count else { throw SafariumError.encode("hvcC truncated nalu data") }
                sets.append(Data(b[p..<(p + len)]))
                p += len
            }
        }
        return sets
    }

    private static func lengthPrefixedToAnnexB(
        sample: Data,
        codec: VideoCodecKind,
        paramSets: [Data],
        includeParamSets: Bool
    ) -> Data {
        var out = Data()
        switch codec {
        case .h264: out.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x09, 0xF0])
        case .hevc: out.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x46, 0x01, 0x50])
        }
        if includeParamSets {
            for ps in paramSets {
                out.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                out.append(ps)
            }
        }
        var p = 0
        while p + 4 <= sample.count {
            let len = (Int(sample[p]) << 24)
                | (Int(sample[p + 1]) << 16)
                | (Int(sample[p + 2]) << 8)
                | Int(sample[p + 3])
            p += 4
            guard len >= 0, p + len <= sample.count else { break }
            out.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            out.append(sample[p..<(p + len)])
            p += len
        }
        return out
    }

    private static func splitAnnexBNALUs(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var offsets: [(start: Int, scLen: Int)] = []
        var i = 0
        while i + 3 <= b.count {
            if i + 4 <= b.count && b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 0 && b[i + 3] == 1 {
                offsets.append((i, 4))
                i += 4
            } else if b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
                offsets.append((i, 3))
                i += 3
            } else {
                i += 1
            }
        }
        var nalus: [Data] = []
        nalus.reserveCapacity(offsets.count)
        for idx in 0..<offsets.count {
            let contentStart = offsets[idx].start + offsets[idx].scLen
            let contentEnd = (idx + 1 < offsets.count) ? offsets[idx + 1].start : b.count
            if contentEnd > contentStart {
                nalus.append(Data(b[contentStart..<contentEnd]))
            }
        }
        return nalus
    }

    // MARK: - ADTS 7-Byte Framing

    private struct ADTSHeaderInfo {
        let objectType: Int
        let sampleRateIndex: Int
        let channels: Int
        let headerBytes: Int
        let frameLength: Int
    }

    private static func makeADTSHeader(rawAACLength: Int, objType: Int, srIdx: Int, ch: Int) -> Data {
        let frameLen = 7 + rawAACLength
        let profile = max(0, objType - 1)
        var hdr = [UInt8](repeating: 0, count: 7)
        hdr[0] = 0xFF
        hdr[1] = 0xF1
        hdr[2] = UInt8(((profile & 0x03) << 6) | ((srIdx & 0x0F) << 2) | ((ch >> 2) & 0x01))
        hdr[3] = UInt8(((ch & 0x03) << 6) | ((frameLen >> 11) & 0x03))
        hdr[4] = UInt8((frameLen >> 3) & 0xFF)
        hdr[5] = UInt8(((frameLen & 0x07) << 5) | 0x1F)
        hdr[6] = 0xFC
        return Data(hdr)
    }

    private static func parseADTSFrame(_ data: Data, at offset: Int) -> ADTSHeaderInfo? {
        guard offset + 7 <= data.count else { return nil }
        let b0 = data[offset]
        let b1 = data[offset + 1]
        guard b0 == 0xFF && (b1 & 0xF0) == 0xF0 else { return nil }
        let protectionAbsent = (b1 & 0x01) != 0
        let profile = Int((data[offset + 2] >> 6) & 0x03)
        let srIdx = Int((data[offset + 2] >> 2) & 0x0F)
        let ch = (Int(data[offset + 2] & 0x01) << 2) | Int((data[offset + 3] >> 6) & 0x03)
        let frameLen = (Int(data[offset + 3] & 0x03) << 11)
            | (Int(data[offset + 4]) << 3)
            | Int((data[offset + 5] >> 5) & 0x07)
        let hdrLen = protectionAbsent ? 7 : 9
        guard frameLen >= hdrLen, offset + frameLen <= data.count else { return nil }
        return ADTSHeaderInfo(
            objectType: profile + 1,
            sampleRateIndex: srIdx,
            channels: max(1, ch),
            headerBytes: hdrLen,
            frameLength: frameLen
        )
    }

    // MARK: - 188-Byte TS Muxer

    private final class TS188Muxer {
        private var ccByPID: [UInt16: UInt8] = [:]
        private var output = Data()

        let pmtPID: UInt16 = 0x1000
        let videoPID: UInt16 = 0x0100
        let audioPID: UInt16 = 0x0101

        private func nextCC(_ pid: UInt16) -> UInt8 {
            let cur = ccByPID[pid] ?? 0
            ccByPID[pid] = (cur + 1) & 0x0F
            return cur
        }

        func writePAT() {
            var sec = Data([
                0x00,
                0xB0, 0x0D,
                0x00, 0x01,
                0xC1, 0x00, 0x00,
                0x00, 0x01,
                UInt8(0xE0 | ((pmtPID >> 8) & 0x1F)), UInt8(pmtPID & 0xFF),
            ])
            let crc = MPEGTSCodec.mpeg2CRC32(sec)
            sec.append(contentsOf: [
                UInt8((crc >> 24) & 0xFF),
                UInt8((crc >> 16) & 0xFF),
                UInt8((crc >> 8) & 0xFF),
                UInt8(crc & 0xFF),
            ])
            writePSI(pid: 0x0000, section: sec)
        }

        func writePMT(videoStreamType: UInt8?, audioStreamType: UInt8?) {
            var streams: [(type: UInt8, pid: UInt16)] = []
            if let vst = videoStreamType { streams.append((vst, videoPID)) }
            if let ast = audioStreamType { streams.append((ast, audioPID)) }
            let pcrPID = videoStreamType != nil ? videoPID : audioPID
            let sectionLen = 9 + streams.count * 5 + 4

            var sec = Data([
                0x02,
                UInt8(0xB0 | ((sectionLen >> 8) & 0x0F)), UInt8(sectionLen & 0xFF),
                0x00, 0x01,
                0xC1, 0x00, 0x00,
                UInt8(0xE0 | ((pcrPID >> 8) & 0x1F)), UInt8(pcrPID & 0xFF),
                0xF0, 0x00,
            ])
            for s in streams {
                sec.append(contentsOf: [
                    s.type,
                    UInt8(0xE0 | ((s.pid >> 8) & 0x1F)),
                    UInt8(s.pid & 0xFF),
                    0xF0,
                    0x00,
                ])
            }
            let crc = MPEGTSCodec.mpeg2CRC32(sec)
            sec.append(contentsOf: [
                UInt8((crc >> 24) & 0xFF),
                UInt8((crc >> 16) & 0xFF),
                UInt8((crc >> 8) & 0xFF),
                UInt8(crc & 0xFF),
            ])
            writePSI(pid: pmtPID, section: sec)
        }

        private func writePSI(pid: UInt16, section: Data) {
            precondition(section.count <= 183)
            var pkt = [UInt8](repeating: 0xFF, count: 188)
            pkt[0] = 0x47
            pkt[1] = UInt8(0x40 | ((pid >> 8) & 0x1F))
            pkt[2] = UInt8(pid & 0xFF)
            pkt[3] = UInt8(0x10 | nextCC(pid))
            pkt[4] = 0x00
            for i in 0..<section.count {
                pkt[5 + i] = section[i]
            }
            output.append(contentsOf: pkt)
        }

        private static func encode90kTS(_ ts90k: UInt64, prefix: UInt8) -> [UInt8] {
            let t = ts90k & 0x1_FFFF_FFFF
            return [
                UInt8((Int(prefix) << 4) | Int((t >> 29) & 0x0E) | 0x01),
                UInt8((t >> 22) & 0xFF),
                UInt8(((t >> 14) & 0xFE) | 0x01),
                UInt8((t >> 7) & 0xFF),
                UInt8(((t << 1) & 0xFE) | 0x01),
            ]
        }

        func writePES(
            pid: UInt16,
            streamID: UInt8,
            payload: Data,
            pts90k: UInt64,
            dts90k: UInt64?,
            isKeyframe: Bool,
            includePCR: Bool
        ) {
            var pes = Data([0x00, 0x00, 0x01, streamID])
            let hasDTS = (dts90k != nil && dts90k != pts90k)
            let optHdrDataLen: UInt8 = hasDTS ? 10 : 5
            let rawPesLen = (streamID >= 0xE0) ? 0 : (3 + Int(optHdrDataLen) + payload.count)
            let pesLen = rawPesLen <= 65_535 ? rawPesLen : 0
            pes.append(UInt8((pesLen >> 8) & 0xFF))
            pes.append(UInt8(pesLen & 0xFF))
            pes.append(0x80)
            pes.append(hasDTS ? 0xC0 : 0x80)
            pes.append(optHdrDataLen)
            pes.append(contentsOf: Self.encode90kTS(pts90k, prefix: hasDTS ? 0x03 : 0x02))
            if hasDTS, let dts = dts90k {
                pes.append(contentsOf: Self.encode90kTS(dts, prefix: 0x01))
            }
            pes.append(payload)

            var offset = 0
            var first = true
            while offset < pes.count {
                var pkt = [UInt8](repeating: 0xFF, count: 188)
                pkt[0] = 0x47
                pkt[1] = UInt8((first ? 0x40 : 0x00) | ((pid >> 8) & 0x1F))
                pkt[2] = UInt8(pid & 0xFF)
                let wantPCR = first && includePCR
                let needAdaptHeader = wantPCR || (first && isKeyframe)
                let pcrBytes = wantPCR ? 6 : 0
                let minAdaptBytes = needAdaptHeader ? (2 + pcrBytes) : 0
                let remaining = pes.count - offset
                let maxPayloadWithMinAdapt = 184 - minAdaptBytes

                var adaptTotalLen = 0
                if remaining < maxPayloadWithMinAdapt {
                    adaptTotalLen = 184 - remaining
                } else if needAdaptHeader {
                    adaptTotalLen = minAdaptBytes
                }

                if adaptTotalLen == 0 {
                    pkt[3] = UInt8(0x10 | nextCC(pid))
                    for i in 0..<184 { pkt[4 + i] = pes[offset + i] }
                    offset += 184
                } else {
                    pkt[3] = UInt8(0x30 | nextCC(pid))
                    pkt[4] = UInt8(adaptTotalLen - 1)
                    if adaptTotalLen > 1 {
                        var flags: UInt8 = 0
                        if first && isKeyframe { flags |= 0x40 }
                        if wantPCR { flags |= 0x10 }
                        pkt[5] = flags
                        if wantPCR {
                            let pcrBase = (dts90k ?? pts90k) & 0x1_FFFF_FFFF
                            pkt[6] = UInt8((pcrBase >> 25) & 0xFF)
                            pkt[7] = UInt8((pcrBase >> 17) & 0xFF)
                            pkt[8] = UInt8((pcrBase >> 9) & 0xFF)
                            pkt[9] = UInt8((pcrBase >> 1) & 0xFF)
                            pkt[10] = UInt8(((pcrBase & 1) << 7) | 0x7E)
                            pkt[11] = 0x00
                        }
                    }
                    let payloadStart = 4 + adaptTotalLen
                    let take = 188 - payloadStart
                    for i in 0..<take { pkt[payloadStart + i] = pes[offset + i] }
                    offset += take
                }
                first = false
                output.append(contentsOf: pkt)
            }
        }

        func finalize() -> Data { output }
    }

    // MARK: - 188-Byte TS Parser

    private static func parseTS(_ tsData: Data) throws -> ParsedTS {
        guard !tsData.isEmpty, tsData.count % 188 == 0 else {
            throw SafariumError.encode("TS size \(tsData.count) must be a positive multiple of 188 bytes")
        }
        var pmtPID: UInt16?
        var pidStreamTypes: [UInt16: UInt8] = [:]
        var crcErrors = 0
        var pesBuffers: [UInt16: (buf: Data, randomAccess: Bool)] = [:]
        var unwrappers: [UInt16: (pts: TSPTSUnwrapper, dts: TSPTSUnwrapper)] = [:]
        var units: [DemuxedTSUnit] = []

        func decode90k(_ p: Data, at off: Int) -> UInt64 {
            let b0 = UInt64(p[off])
            let b1 = UInt64(p[off + 1])
            let b2 = UInt64(p[off + 2])
            let b3 = UInt64(p[off + 3])
            let b4 = UInt64(p[off + 4])
            return ((b0 & 0x0E) << 29) | (b1 << 22) | ((b2 & 0xFE) << 14) | (b3 << 7) | ((b4 & 0xFE) >> 1)
        }

        func flushPES(pid: UInt16) {
            guard let state = pesBuffers[pid], !state.buf.isEmpty else { return }
            let d = state.buf
            pesBuffers[pid] = nil
            guard d.count >= 9, d[0] == 0x00, d[1] == 0x00, d[2] == 0x01 else { return }
            let flags = d[7]
            let hdrLen = Int(d[8])
            let payloadStart = 9 + hdrLen
            guard payloadStart <= d.count else { return }
            var uw = unwrappers[pid] ?? (TSPTSUnwrapper(), TSPTSUnwrapper())
            var pts: Int64 = 0
            var dts: Int64 = 0
            if (flags & 0x80) != 0 && hdrLen >= 5 && 14 <= d.count {
                pts = uw.pts.unwrap(decode90k(d, at: 9))
                dts = pts
            }
            if (flags & 0x40) != 0 && hdrLen >= 10 && 19 <= d.count {
                dts = uw.dts.unwrap(decode90k(d, at: 14))
            }
            unwrappers[pid] = uw
            let st = pidStreamTypes[pid] ?? 0
            units.append(DemuxedTSUnit(
                pid: pid,
                streamType: st,
                pts90k: pts,
                dts90k: dts,
                isRandomAccess: state.randomAccess,
                payload: d.subdata(in: payloadStart..<d.count)
            ))
        }

        let pktCount = tsData.count / 188
        for idx in 0..<pktCount {
            let base = idx * 188
            guard tsData[base] == 0x47 else {
                throw SafariumError.encode("missing MPEG-TS 0x47 sync byte at packet \(idx)")
            }
            let pusi = (tsData[base + 1] & 0x40) != 0
            let pid = (UInt16(tsData[base + 1] & 0x1F) << 8) | UInt16(tsData[base + 2])
            let afc = (tsData[base + 3] >> 4) & 0x03

            var pos = base + 4
            var rai = false
            if afc == 2 || afc == 3 {
                let afLen = Int(tsData[pos])
                pos += 1
                guard pos + afLen <= base + 188 else {
                    throw SafariumError.encode("corrupt MPEG-TS adaptation_field_length \(afLen) at packet \(idx)")
                }
                if afLen > 0 {
                    rai = (tsData[pos] & 0x40) != 0
                }
                pos += afLen
            }
            if afc == 0 || afc == 2 || pos >= base + 188 { continue }
            let payload = tsData.subdata(in: pos..<(base + 188))

            if pid == 0x0000 {
                guard pusi, !payload.isEmpty else { continue }
                let ptr = Int(payload[0])
                let secStart = 1 + ptr
                guard secStart + 8 <= payload.count else { continue }
                let secLen = ((Int(payload[secStart + 1]) & 0x0F) << 8) | Int(payload[secStart + 2])
                let secEnd = secStart + 3 + secLen
                guard secEnd <= payload.count, secLen >= 9 else { continue }
                if mpeg2CRC32(payload.subdata(in: secStart..<secEnd)) != 0 {
                    crcErrors += 1
                }
                var p = secStart + 8
                while p + 4 <= secEnd - 4 {
                    let prog = (UInt16(payload[p]) << 8) | UInt16(payload[p + 1])
                    let mappedPID = (UInt16(payload[p + 2] & 0x1F) << 8) | UInt16(payload[p + 3])
                    if prog != 0 { pmtPID = mappedPID }
                    p += 4
                }
            } else if pid == pmtPID {
                guard pusi, !payload.isEmpty else { continue }
                let ptr = Int(payload[0])
                let secStart = 1 + ptr
                guard secStart + 12 <= payload.count else { continue }
                let secLen = ((Int(payload[secStart + 1]) & 0x0F) << 8) | Int(payload[secStart + 2])
                let secEnd = secStart + 3 + secLen
                guard secEnd <= payload.count, secLen >= 13 else { continue }
                if mpeg2CRC32(payload.subdata(in: secStart..<secEnd)) != 0 {
                    crcErrors += 1
                }
                let progInfoLen = ((Int(payload[secStart + 10]) & 0x0F) << 8) | Int(payload[secStart + 11])
                var p = secStart + 12 + progInfoLen
                while p + 5 <= secEnd - 4 {
                    let st = payload[p]
                    let ePID = (UInt16(payload[p + 1] & 0x1F) << 8) | UInt16(payload[p + 2])
                    let esInfoLen = ((Int(payload[p + 3]) & 0x0F) << 8) | Int(payload[p + 4])
                    pidStreamTypes[ePID] = st
                    p += 5 + esInfoLen
                }
            } else if pidStreamTypes[pid] != nil {
                if pusi {
                    flushPES(pid: pid)
                    pesBuffers[pid] = (payload, rai)
                } else if var cur = pesBuffers[pid] {
                    cur.buf.append(payload)
                    pesBuffers[pid] = cur
                }
            }
        }
        for pid in pesBuffers.keys.sorted() {
            flushPES(pid: pid)
        }
        return ParsedTS(
            packetCount: pktCount,
            pmtPID: pmtPID ?? 0,
            pidStreamTypes: pidStreamTypes,
            crcErrors: crcErrors,
            units: units
        )
    }

    // MARK: - Inspect

    public static func inspect(url: URL) throws -> MPEGTSInspectReport {
        try SafeFilePublisher.assertRegularReadableFile(url)
        let data = try Data(contentsOf: url)
        let parsed = try parseTS(data)

        var tracks: [ContainerTrackInfo] = []
        var streamMap: [Int: UInt8] = [:]
        for (pid, st) in parsed.pidStreamTypes.sorted(by: { $0.key < $1.key }) {
            streamMap[Int(pid)] = st
            let kind: ContainerTrackKind
            let codecName: String
            switch st {
            case 0x1B:
                kind = .video
                codecName = "H264"
            case 0x24:
                kind = .video
                codecName = "HEVC"
            case 0x02:
                kind = .video
                codecName = "MPEG2"
            case 0x0F:
                kind = .audio
                codecName = "AAC_ADTS"
            case 0x03, 0x04:
                kind = .audio
                codecName = "MP3"
            default:
                kind = .audio
                codecName = String(format: "0x%02X", st)
            }
            tracks.append(ContainerTrackInfo(trackNumber: Int(pid), kind: kind, codecID: codecName))
        }

        let vUnits = parsed.units.filter { $0.streamType == 0x1B || $0.streamType == 0x24 || $0.streamType == 0x02 }
        let aUnits = parsed.units.filter { $0.streamType == 0x0F || $0.streamType == 0x03 || $0.streamType == 0x04 }
        let allPTS = parsed.units.map(\.pts90k)
        let minPTS = allPTS.min() ?? 0
        let maxPTS = allPTS.max() ?? 0
        let durSec = maxPTS > minPTS ? Double(maxPTS - minPTS) / 90_000.0 : 0

        return MPEGTSInspectReport(
            path: url.path,
            packetCount: parsed.packetCount,
            pmtPID: Int(parsed.pmtPID),
            tracks: tracks,
            streamTypesByPID: streamMap,
            videoPackets: vUnits.count,
            audioPackets: aUnits.count,
            durationSeconds: durSec,
            crcErrors: parsed.crcErrors
        )
    }

    // MARK: - Demux MPEG-TS -> MP4 / MOV

    private static func makeVideoFormatDescription(isH264: Bool, paramSets: [Data]) throws -> CMVideoFormatDescription {
        guard !paramSets.isEmpty else {
            throw SafariumError.encode("MPEG-TS missing SPS/PPS/VPS parameter sets")
        }
        let rawBufs = paramSets.map { data -> UnsafeMutablePointer<UInt8> in
            let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: data.count)
            data.copyBytes(to: ptr, count: data.count)
            return ptr
        }
        defer { rawBufs.forEach { $0.deallocate() } }
        var ptrs = rawBufs.map { UnsafePointer($0) }
        var sizes = paramSets.map { $0.count }
        var vFmtOut: CMVideoFormatDescription?
        let st: OSStatus
        if isH264 {
            st = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: paramSets.count,
                parameterSetPointers: &ptrs,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4,
                formatDescriptionOut: &vFmtOut
            )
        } else {
            st = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: paramSets.count,
                parameterSetPointers: &ptrs,
                parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4,
                extensions: nil,
                formatDescriptionOut: &vFmtOut
            )
        }
        guard st == noErr, let vFmtOut else {
            throw SafariumError.encode("MPEG-TS video CMVideoFormatDescription creation failed (\(st))")
        }
        return vFmtOut
    }

    public static func demuxToMP4(
        inputURL: URL,
        outputURL: URL,
        overwrite: Bool = false
    ) async throws -> RemuxReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(inputURL)
        try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)

        let ext = outputURL.pathExtension.lowercased()
        guard ext == "mp4" || ext == "mov" else {
            throw SafariumError.invalidState("demuxToMP4 output must end with .mp4 or .mov, got '\(outputURL.lastPathComponent)'")
        }
        let fileType: AVFileType = (ext == "mov") ? .mov : .mp4

        let tsBytes = try Data(contentsOf: inputURL)
        let demuxed = try parseTS(tsBytes)
        let vUnits = demuxed.units.filter { $0.streamType == 0x1B || $0.streamType == 0x24 }
        let aUnits = demuxed.units.filter { $0.streamType == 0x0F }

        guard !vUnits.isEmpty || !aUnits.isEmpty else {
            throw SafariumError.encode("MPEG-TS contains no supported H.264/HEVC/AAC streams: \(inputURL.lastPathComponent)")
        }

        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }
        let tempURL = staging.fileURL("ts-demux.\(ext)")

        let writer = try AVAssetWriter(url: tempURL, fileType: fileType)
        writer.movieTimeScale = 90_000
        writer.shouldOptimizeForNetworkUse = true

        var vFmt: CMVideoFormatDescription?
        var vi: AVAssetWriterInput?
        var reconVideoPkts: [(pts: Int64, dts: Int64, isSync: Bool, data: Data)] = []

        if !vUnits.isEmpty {
            let isH264 = vUnits[0].streamType == 0x1B
            var collectedSPS: [Data] = []
            var collectedPPS: [Data] = []
            var collectedVPS: [Data] = []

            for u in vUnits {
                let nalus = splitAnnexBNALUs(u.payload)
                var avccPayload = Data()
                var isIDR = false
                for nal in nalus where !nal.isEmpty {
                    if isH264 {
                        let nt = nal[0] & 0x1F
                        if nt == 9 { continue }
                        if nt == 7 {
                            if !collectedSPS.contains(nal) { collectedSPS.append(nal) }
                            continue
                        }
                        if nt == 8 {
                            if !collectedPPS.contains(nal) { collectedPPS.append(nal) }
                            continue
                        }
                        if nt == 5 { isIDR = true }
                    } else {
                        let nt = (nal[0] >> 1) & 0x3F
                        if nt == 35 { continue }
                        if nt == 32 {
                            if !collectedVPS.contains(nal) { collectedVPS.append(nal) }
                            continue
                        }
                        if nt == 33 {
                            if !collectedSPS.contains(nal) { collectedSPS.append(nal) }
                            continue
                        }
                        if nt == 34 {
                            if !collectedPPS.contains(nal) { collectedPPS.append(nal) }
                            continue
                        }
                        if nt >= 16 && nt <= 21 { isIDR = true }
                    }
                    var beLen = UInt32(nal.count).bigEndian
                    avccPayload.append(Data(bytes: &beLen, count: 4))
                    avccPayload.append(nal)
                }
                reconVideoPkts.append((u.pts90k, u.dts90k, isIDR || u.isRandomAccess, avccPayload))
            }

            let allPS = isH264 ? (collectedSPS + collectedPPS) : (collectedVPS + collectedSPS + collectedPPS)
            let fmt = try makeVideoFormatDescription(isH264: isH264, paramSets: allPS)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
            input.mediaTimeScale = 90_000
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw SafariumError.encode("AVAssetWriter cannot add MPEG-TS video input")
            }
            writer.add(input)
            vFmt = fmt
            vi = input
        }

        var aFmt: CMAudioFormatDescription?
        var ai: AVAssetWriterInput?
        var reconAudioPkts: [(pts90k: Int64, data: Data)] = []
        var aRate = 48_000

        if !aUnits.isEmpty {
            var ascFromADTS: Data?
            for u in aUnits {
                var off = 0
                var idxInPES = 0
                while let info = parseADTSFrame(u.payload, at: off) {
                    if ascFromADTS == nil {
                        ascFromADTS = MediaCompatBridge.makeAACAudioSpecificConfig(
                            objectType: info.objectType,
                            sampleRateIndex: info.sampleRateIndex,
                            channels: info.channels
                        )
                        if info.sampleRateIndex < MediaCompatBridge.aacSampleRates.count {
                            aRate = MediaCompatBridge.aacSampleRates[info.sampleRateIndex]
                        }
                    }
                    let raw = u.payload.subdata(in: (off + info.headerBytes)..<(off + info.frameLength))
                    let framePTS = u.pts90k + Int64(idxInPES) * Int64((1024.0 / Double(aRate) * 90_000.0).rounded())
                    reconAudioPkts.append((framePTS, raw))
                    off += info.frameLength
                    idxInPES += 1
                }
            }
            guard let ascBytes = ascFromADTS else {
                throw SafariumError.encode("MPEG-TS audio stream contained no valid ADTS frames")
            }
            let fmt = try MediaCompatBridge.makeAudioFormatDescriptionFromASC(
                ascBytes,
                sampleRate: Double(aRate),
                channels: (try? MediaCompatBridge.parseAACAudioSpecificConfig(ascBytes).channels) ?? 2
            )
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: fmt)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw SafariumError.encode("AVAssetWriter cannot add MPEG-TS audio input")
            }
            writer.add(input)
            aFmt = fmt
            ai = input
        }

        guard writer.startWriting() else {
            throw SafariumError.encode("MPEG-TS demux writer startWriting failed: \(writer.error?.localizedDescription ?? "?")")
        }
        let minVPTS90k = reconVideoPkts.map(\.pts).min() ?? 0
        writer.startSession(atSourceTime: .zero)

        let defaultVDur90k: Int64 = {
            if reconVideoPkts.count >= 2 {
                let dtsSorted = reconVideoPkts.map(\.dts).sorted()
                let diffs = zip(dtsSorted, dtsSorted.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
                if !diffs.isEmpty { return diffs[diffs.count / 2] }
            }
            return 3000
        }()

        if let vi, let vFmt {
            for (i, vp) in reconVideoPkts.enumerated() {
                while !vi.isReadyForMoreMediaData {
                    if writer.status == .failed {
                        throw SafariumError.encode("MPEG-TS video writer failed: \(writer.error?.localizedDescription ?? "?")")
                    }
                    try await Task.sleep(nanoseconds: 500_000)
                }
                let nextDTS = i + 1 < reconVideoPkts.count ? reconVideoPkts[i + 1].dts : (vp.dts + defaultVDur90k)
                let dur = max(1, nextDTS - vp.dts)
                let sb = try MediaCompatBridge.makeReadySampleBuffer(
                    data: vp.data,
                    formatDescription: vFmt,
                    pts: CMTime(value: vp.pts - minVPTS90k, timescale: 90_000),
                    dts: CMTime(value: vp.dts - minVPTS90k, timescale: 90_000),
                    duration: CMTime(value: dur, timescale: 90_000),
                    isSync: vp.isSync
                )
                guard vi.append(sb) else {
                    throw SafariumError.encode("MPEG-TS video append failed: \(writer.error?.localizedDescription ?? "?")")
                }
            }
            vi.markAsFinished()
        }

        if let ai, let aFmt {
            for (i, ap) in reconAudioPkts.enumerated() {
                while !ai.isReadyForMoreMediaData {
                    if writer.status == .failed {
                        throw SafariumError.encode("MPEG-TS audio writer failed: \(writer.error?.localizedDescription ?? "?")")
                    }
                    try await Task.sleep(nanoseconds: 500_000)
                }
                let sb = try MediaCompatBridge.makeReadySampleBuffer(
                    data: ap.data,
                    formatDescription: aFmt,
                    pts: CMTime(value: Int64(i) * 1024, timescale: Int32(aRate)),
                    dts: .invalid,
                    duration: CMTime(value: 1024, timescale: Int32(aRate)),
                    isSync: true
                )
                guard ai.append(sb) else {
                    throw SafariumError.encode("MPEG-TS audio append failed: \(writer.error?.localizedDescription ?? "?")")
                }
            }
            ai.markAsFinished()
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw SafariumError.encode("MPEG-TS demux finishWriting failed: \(writer.error?.localizedDescription ?? "?")")
        }

        try SafeFilePublisher.publish(tempURL: tempURL, to: outputURL, overwrite: overwrite)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return RemuxReport(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            sourceContainer: "ts",
            targetContainer: ext,
            videoPackets: reconVideoPkts.count,
            audioPackets: reconAudioPkts.count,
            subtitleCues: 0,
            wallMs: elapsedMs
        )
    }

    // MARK: - Mux MP4 / MOV -> 188-Byte MPEG-TS

    public static func muxFromMP4OrMOV(
        inputURL: URL,
        outputURL: URL,
        overwrite: Bool = false
    ) async throws -> RemuxReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(inputURL)
        try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)

        let asset = AVURLAsset(url: inputURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let vTrack = try await asset.loadTracks(withMediaType: .video).first
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first

        guard vTrack != nil || aTrack != nil else {
            throw SafariumError.encode("input MP4/MOV has no video or audio track: \(inputURL.lastPathComponent)")
        }

        let reader = try AVAssetReader(asset: asset)
        var vOut: AVAssetReaderTrackOutput?
        var aOut: AVAssetReaderTrackOutput?
        var videoCodecKind: VideoCodecKind?
        var videoStreamType: UInt8?
        var paramSets: [Data] = []
        var audioStreamType: UInt8?
        var ascInfo: (objectType: Int, sampleRateIndex: Int, sampleRate: Int, channels: Int)?

        if let vTrack {
            let vFmts = try await vTrack.load(.formatDescriptions)
            guard let vFmt = vFmts.first else {
                throw SafariumError.encode("missing video format description in \(inputURL.lastPathComponent)")
            }
            let sub = MediaCompatBridge.fourCCString(CMFormatDescriptionGetMediaSubType(vFmt))
            let atoms = CMFormatDescriptionGetExtension(
                vFmt,
                extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
            ) as? [String: Any]

            if sub == "avc1" || sub == "avc3" {
                videoCodecKind = .h264
                videoStreamType = 0x1B
                guard let avcC = atoms?["avcC"] as? Data else {
                    throw SafariumError.encode("missing avcC atom in \(inputURL.lastPathComponent)")
                }
                paramSets = try parseAVCCParameterSets(avcC)
            } else if sub == "hvc1" || sub == "hev1" {
                videoCodecKind = .hevc
                videoStreamType = 0x24
                guard let hvcC = atoms?["hvcC"] as? Data else {
                    throw SafariumError.encode("missing hvcC atom in \(inputURL.lastPathComponent)")
                }
                paramSets = try parseHVCCParameterSets(hvcC)
            } else {
                throw SafariumError.encode("MPEG-TS mux supports H.264 (avc1) and HEVC (hvc1), got '\(sub)'")
            }
            let out = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            reader.add(out)
            vOut = out
        }

        if let aTrack {
            let aFmts = try await aTrack.load(.formatDescriptions)
            guard let aFmt = aFmts.first,
                  let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(aFmt) else {
                throw SafariumError.encode("missing audio format description in \(inputURL.lastPathComponent)")
            }
            guard asbdPtr.pointee.mFormatID == kAudioFormatMPEG4AAC else {
                throw SafariumError.encode("MPEG-TS mux audio currently supports AAC (got '\(MediaCompatBridge.fourCCString(asbdPtr.pointee.mFormatID))')")
            }
            var cookieLen = 0
            let cookiePtr = CMAudioFormatDescriptionGetMagicCookie(aFmt, sizeOut: &cookieLen)
            guard let cookiePtr, cookieLen > 0 else {
                throw SafariumError.encode("missing AAC ESDS magic cookie in \(inputURL.lastPathComponent)")
            }
            let cookie = Data(bytes: cookiePtr, count: cookieLen)
            let asc = try MediaCompatBridge.unwrapWebCodecsESDS(cookie).audioSpecificConfig
            ascInfo = try MediaCompatBridge.parseAACAudioSpecificConfig(asc)
            audioStreamType = 0x0F
            let out = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            reader.add(out)
            aOut = out
        }

        guard reader.startReading() else {
            throw SafariumError.encode("AVAssetReader failed for \(inputURL.lastPathComponent): \(reader.error?.localizedDescription ?? "?")")
        }

        var vPkts: [(pts90k: Int64, dts90k: Int64, isSync: Bool, data: Data)] = []
        if let vOut {
            while let sb = vOut.copyNextSampleBuffer() {
                guard sb.numSamples > 0 else { continue }
                let len = sb.dataBuffer.map { CMBlockBufferGetDataLength($0) } ?? 0
                var d = Data(count: len)
                if let db = sb.dataBuffer, len > 0 {
                    d.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(db, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
                }
                let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
                let notSync = (att?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
                let pts90k = Int64((sb.presentationTimeStamp.seconds * 90_000.0).rounded())
                let dts90k = sb.decodeTimeStamp.isValid ? Int64((sb.decodeTimeStamp.seconds * 90_000.0).rounded()) : pts90k
                vPkts.append((pts90k, dts90k, !notSync, d))
            }
        }

        var aPkts: [(pts90k: Int64, data: Data)] = []
        if let aOut {
            while let sb = aOut.copyNextSampleBuffer() {
                for ap in MediaCompatBridge.splitCompressedAudioPackets(from: sb) {
                    aPkts.append((ap.pts90k, ap.data))
                }
            }
        }

        let minTS = (vPkts.map(\.dts90k) + aPkts.map(\.pts90k)).min() ?? 0
        let tsShift: Int64 = minTS < 0 ? -minTS : 0

        let muxer = TS188Muxer()
        muxer.writePAT()
        muxer.writePMT(videoStreamType: videoStreamType, audioStreamType: audioStreamType)

        if let codec = videoCodecKind {
            for (idx, vp) in vPkts.enumerated() {
                if idx > 0 && vp.isSync {
                    muxer.writePAT()
                    muxer.writePMT(videoStreamType: videoStreamType, audioStreamType: audioStreamType)
                }
                let annexB = lengthPrefixedToAnnexB(
                    sample: vp.data,
                    codec: codec,
                    paramSets: paramSets,
                    includeParamSets: vp.isSync
                )
                muxer.writePES(
                    pid: muxer.videoPID,
                    streamID: 0xE0,
                    payload: annexB,
                    pts90k: UInt64(vp.pts90k + tsShift),
                    dts90k: UInt64(vp.dts90k + tsShift),
                    isKeyframe: vp.isSync,
                    includePCR: vp.isSync
                )
            }
        }

        if let asc = ascInfo {
            for ap in aPkts {
                let adts = makeADTSHeader(
                    rawAACLength: ap.data.count,
                    objType: asc.objectType,
                    srIdx: asc.sampleRateIndex,
                    ch: asc.channels
                )
                var frame = adts
                frame.append(ap.data)
                muxer.writePES(
                    pid: muxer.audioPID,
                    streamID: 0xC0,
                    payload: frame,
                    pts90k: UInt64(ap.pts90k + tsShift),
                    dts90k: nil,
                    isKeyframe: true,
                    includePCR: false
                )
            }
        }

        let tsBytes = muxer.finalize()
        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }
        let tempURL = staging.fileURL("mux.ts")
        try tsBytes.write(to: tempURL, options: .atomic)
        try SafeFilePublisher.publish(tempURL: tempURL, to: outputURL, overwrite: overwrite)

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let srcExt = inputURL.pathExtension.lowercased()
        return RemuxReport(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            sourceContainer: srcExt.isEmpty ? "mp4" : srcExt,
            targetContainer: "ts",
            videoPackets: vPkts.count,
            audioPackets: aPkts.count,
            subtitleCues: 0,
            wallMs: elapsedMs
        )
    }
}
