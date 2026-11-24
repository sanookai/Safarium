@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import SafariumCore

public struct MKVSubtitleCue: Codable, Equatable, Sendable {
    public let startMS: Int64
    public let endMS: Int64
    public let text: String

    public init(startMS: Int64, endMS: Int64, text: String) {
        self.startMS = startMS
        self.endMS = endMS
        self.text = text
    }
}

public struct MKVInspectReport: Codable, Sendable {
    public let path: String
    public let docType: String
    public let timestampScaleNS: UInt64
    public let durationSeconds: Double
    public let tracks: [ContainerTrackInfo]
    public let packetCount: Int
    public let videoPackets: Int
    public let audioPackets: Int
    public let subtitleCues: Int
    public let cues: [MKVSubtitleCue]
    public let cuePointCount: Int
    public let hasStreamingUnknownSize: Bool

    public init(
        path: String,
        docType: String,
        timestampScaleNS: UInt64,
        durationSeconds: Double,
        tracks: [ContainerTrackInfo],
        packetCount: Int,
        videoPackets: Int,
        audioPackets: Int,
        subtitleCues: Int,
        cues: [MKVSubtitleCue],
        cuePointCount: Int,
        hasStreamingUnknownSize: Bool
    ) {
        self.path = path
        self.docType = docType
        self.timestampScaleNS = timestampScaleNS
        self.durationSeconds = durationSeconds
        self.tracks = tracks
        self.packetCount = packetCount
        self.videoPackets = videoPackets
        self.audioPackets = audioPackets
        self.subtitleCues = subtitleCues
        self.cues = cues
        self.cuePointCount = cuePointCount
        self.hasStreamingUnknownSize = hasStreamingUnknownSize
    }
}

public enum EBMLMatroskaCodec {
    // MARK: - EBML Low-Level Primitives

    private enum EBML {
        static let unknownSizeRaw8 = Data([0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])

        static let idEBML: UInt32               = 0x1A45DFA3
        static let idEBMLVersion: UInt32        = 0x4286
        static let idEBMLReadVersion: UInt32    = 0x42F7
        static let idEBMLMaxIDLength: UInt32    = 0x42F2
        static let idEBMLMaxSizeLength: UInt32  = 0x42F3
        static let idDocType: UInt32            = 0x4282
        static let idDocTypeVersion: UInt32     = 0x4287
        static let idDocTypeReadVersion: UInt32 = 0x4285

        static let idSegment: UInt32            = 0x18538067
        static let idSeekHead: UInt32           = 0x114D9B74
        static let idSeek: UInt32               = 0x4DBB
        static let idSeekID: UInt32             = 0x53AB
        static let idSeekPosition: UInt32       = 0x53AC

        static let idInfo: UInt32               = 0x1549A966
        static let idTimestampScale: UInt32     = 0x2AD7B1
        static let idMuxingApp: UInt32          = 0x4D80
        static let idWritingApp: UInt32         = 0x5741
        static let idDuration: UInt32           = 0x4489

        static let idTracks: UInt32             = 0x1654AE6B
        static let idTrackEntry: UInt32         = 0xAE
        static let idTrackNumber: UInt32        = 0xD7
        static let idTrackUID: UInt32           = 0x73C5
        static let idTrackType: UInt32          = 0x83
        static let idCodecID: UInt32            = 0x86
        static let idCodecPrivate: UInt32       = 0x63A2
        static let idLanguage: UInt32           = 0x22B59C
        static let idLanguageBCP47: UInt32      = 0x22B59D
        static let idDefaultDuration: UInt32    = 0x23E383
        static let idVideo: UInt32              = 0xE0
        static let idPixelWidth: UInt32         = 0xB0
        static let idPixelHeight: UInt32        = 0xBA
        static let idAudio: UInt32              = 0xE1
        static let idSamplingFrequency: UInt32  = 0xB5
        static let idChannels: UInt32           = 0x9F
        static let idBitDepth: UInt32           = 0x6264

        static let idCluster: UInt32            = 0x1F43B675
        static let idTimestamp: UInt32          = 0xE7
        static let idSimpleBlock: UInt32        = 0xA3
        static let idBlockGroup: UInt32         = 0xA0
        static let idBlock: UInt32              = 0xA1
        static let idBlockDuration: UInt32      = 0x9B
        static let idReferenceBlock: UInt32     = 0xFB

        static let idCues: UInt32               = 0x1C53BB6B
        static let idCuePoint: UInt32           = 0xBB
        static let idCueTime: UInt32            = 0xB3
        static let idCueTrackPositions: UInt32  = 0xB7
        static let idCueTrack: UInt32           = 0xF7
        static let idCueClusterPosition: UInt32 = 0xF1

        static let idChapters: UInt32           = 0x1043A770
        static let idAttachments: UInt32        = 0x1941A469
        static let idTags: UInt32               = 0x1254C367

        static let segmentLevelIDs: Set<UInt32> = [
            idSeekHead, idInfo, idTracks, idCluster, idCues, idChapters, idAttachments, idTags,
        ]

        static func encodeID(_ id: UInt32) -> Data {
            if id <= 0xFF { return Data([UInt8(id)]) }
            if id <= 0xFFFF { return Data([UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF)]) }
            if id <= 0xFFFFFF { return Data([UInt8((id >> 16) & 0xFF), UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF)]) }
            return Data([UInt8((id >> 24) & 0xFF), UInt8((id >> 16) & 0xFF), UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF)])
        }

        static func encodeSize(_ size: UInt64, fixedLength: Int? = nil) -> Data {
            let len: Int
            if let fixedLength {
                len = fixedLength
            } else if size < (1 << 7) - 1 { len = 1 }
            else if size < (1 << 14) - 1 { len = 2 }
            else if size < (1 << 21) - 1 { len = 3 }
            else if size < (1 << 28) - 1 { len = 4 }
            else if size < (1 << 35) - 1 { len = 5 }
            else if size < (1 << 42) - 1 { len = 6 }
            else if size < (1 << 49) - 1 { len = 7 }
            else { len = 8 }
            var out = [UInt8](repeating: 0, count: len)
            var v = size
            for i in stride(from: len - 1, through: 0, by: -1) {
                out[i] = UInt8(v & 0xFF)
                v >>= 8
            }
            out[0] |= UInt8(1 << (8 - len))
            return Data(out)
        }

        static func encodeUInt(_ val: UInt64) -> Data {
            if val == 0 { return Data([0]) }
            var tmp: [UInt8] = []
            var v = val
            while v > 0 {
                tmp.append(UInt8(v & 0xFF))
                v >>= 8
            }
            return Data(tmp.reversed())
        }

        static func encodeFloat64(_ val: Double) -> Data {
            var bits = val.bitPattern.bigEndian
            return Data(bytes: &bits, count: 8)
        }

        static func element(_ id: UInt32, _ payload: Data) -> Data {
            var out = encodeID(id)
            out.append(encodeSize(UInt64(payload.count)))
            out.append(payload)
            return out
        }

        static func elementUInt(_ id: UInt32, _ val: UInt64) -> Data {
            element(id, encodeUInt(val))
        }

        static func elementStr(_ id: UInt32, _ val: String) -> Data {
            element(id, Data(val.utf8))
        }

        static func readVINT(_ data: Data, at offset: Int, keepMarker: Bool) throws -> (value: UInt64, rawLen: Int, isUnknown: Bool) {
            guard offset < data.count else {
                throw SafariumError.encode("truncated EBML VINT at offset \(offset)")
            }
            let first = data[offset]
            guard first != 0 else {
                throw SafariumError.encode("invalid zero-byte EBML VINT at offset \(offset)")
            }
            let width = first.leadingZeroBitCount + 1
            guard width <= 8, offset + width <= data.count else {
                throw SafariumError.encode("truncated EBML VINT width \(width) at offset \(offset)")
            }
            let mask: UInt8 = keepMarker ? 0xFF : UInt8(0xFF >> width)
            var val = UInt64(first & mask)
            var allOnes = (first & UInt8(0xFF >> width)) == UInt8(0xFF >> width)
            for i in 1..<width {
                let b = data[offset + i]
                val = (val << 8) | UInt64(b)
                if b != 0xFF { allOnes = false }
            }
            return (val, width, allOnes)
        }

        static func decodeUInt(_ data: Data.SubSequence) -> UInt64 {
            var v: UInt64 = 0
            for b in data.prefix(8) {
                v = (v << 8) | UInt64(b)
            }
            return v
        }

        static func decodeFloat(_ data: Data.SubSequence) -> Double {
            if data.count == 4 {
                var bits: UInt32 = 0
                for b in data { bits = (bits << 8) | UInt32(b) }
                return Double(Float(bitPattern: bits))
            } else if data.count == 8 {
                var bits: UInt64 = 0
                for b in data { bits = (bits << 8) | UInt64(b) }
                return Double(bitPattern: bits)
            }
            return 0
        }
    }

    private struct InternalTrack {
        let trackNumber: Int
        let trackUID: UInt64
        let kind: ContainerTrackKind
        let codecID: String
        let codecPrivate: Data
        let defaultDurationNS: UInt64?
        let width: Int?
        let height: Int?
        let sampleRate: Double?
        let channels: Int?
        let language: String?

        func toPublic() -> ContainerTrackInfo {
            ContainerTrackInfo(
                trackNumber: trackNumber,
                kind: kind,
                codecID: codecID,
                width: width,
                height: height,
                sampleRate: sampleRate.map { Int($0.rounded()) },
                channels: channels,
                language: language,
                codecPrivate: codecPrivate
            )
        }
    }

    private struct InternalPacket {
        let trackNumber: Int
        let ptsTicks: Int64
        let durationTicks: Int64?
        let isKeyframe: Bool
        let data: Data
    }

    private struct ParsedMKV {
        var docType: String = ""
        var timestampScaleNS: UInt64 = 1_000_000
        var durationTicks: Double = 0
        var tracks: [Int: InternalTrack] = [:]
        var packets: [InternalPacket] = []
        var cuePointCount: Int = 0
        var hasStreamingUnknownSize: Bool = false
    }

    // MARK: - Parser

    private static func parseEBML(_ data: Data) throws -> ParsedMKV {
        guard data.count >= 4 else {
            throw SafariumError.encode("EBML/MKV input is empty or too short (\(data.count) bytes)")
        }
        var out = ParsedMKV()
        var pos = 0

        func parseBlockFrames(
            payload: Data,
            clusterTS: Int64,
            blockDuration: Int64?,
            allowKeyframeFlag: Bool
        ) throws -> [InternalPacket] {
            let (tn64, tnLen, _) = try EBML.readVINT(payload, at: 0, keepMarker: false)
            let tn = Int(tn64)
            var p = tnLen
            guard p + 3 <= payload.count else {
                throw SafariumError.encode("truncated Matroska block header")
            }
            let rel = Int16(bitPattern: (UInt16(payload[p]) << 8) | UInt16(payload[p + 1]))
            p += 2
            let flags = payload[p]
            p += 1
            let keyframe = allowKeyframeFlag ? ((flags & 0x80) != 0) : false
            let lacing = (flags >> 1) & 0x03
            let pts = clusterTS + Int64(rel)

            if lacing == 0 {
                return [InternalPacket(
                    trackNumber: tn,
                    ptsTicks: pts,
                    durationTicks: blockDuration,
                    isKeyframe: keyframe,
                    data: payload.subdata(in: p..<payload.count)
                )]
            }

            guard p < payload.count else {
                throw SafariumError.encode("truncated Matroska laced block frame count")
            }
            let frameCount = Int(payload[p]) + 1
            p += 1
            var sizes: [Int] = []
            sizes.reserveCapacity(frameCount)

            if lacing == 1 { // Xiph lacing
                for _ in 0..<(frameCount - 1) {
                    var sz = 0
                    while p < payload.count {
                        let b = Int(payload[p])
                        p += 1
                        sz += b
                        if b < 255 { break }
                    }
                    sizes.append(sz)
                }
                sizes.append(payload.count - p - sizes.reduce(0, +))
            } else if lacing == 2 { // Fixed-size lacing
                let rem = payload.count - p
                guard rem >= 0, rem % frameCount == 0 else {
                    throw SafariumError.encode("invalid fixed-size Matroska lacing")
                }
                sizes = Array(repeating: rem / frameCount, count: frameCount)
            } else { // EBML signed delta lacing
                let (firstSz, fLen, _) = try EBML.readVINT(payload, at: p, keepMarker: false)
                p += fLen
                var prev = Int64(firstSz)
                sizes.append(Int(prev))
                for _ in 1..<(frameCount - 1) {
                    let (rawD, dLen, _) = try EBML.readVINT(payload, at: p, keepMarker: false)
                    p += dLen
                    let bias = (Int64(1) << (7 * dLen - 1)) - 1
                    prev += Int64(rawD) - bias
                    sizes.append(Int(prev))
                }
                sizes.append(payload.count - p - sizes.reduce(0, +))
            }

            var pkts: [InternalPacket] = []
            pkts.reserveCapacity(sizes.count)
            for (idx, sz) in sizes.enumerated() {
                guard sz >= 0, p + sz <= payload.count else {
                    throw SafariumError.encode("invalid Matroska laced frame size \(sz)")
                }
                pkts.append(InternalPacket(
                    trackNumber: tn,
                    ptsTicks: pts,
                    durationTicks: blockDuration,
                    isKeyframe: keyframe && idx == 0,
                    data: payload.subdata(in: p..<(p + sz))
                ))
                p += sz
            }
            return pkts
        }

        func parseMaster(end: Int, stopOnSegmentSibling: Bool = false, handler: (UInt32, Int, Int, Bool) throws -> Void) throws {
            while pos < end {
                let elemStart = pos
                let (id64, idLen, _) = try EBML.readVINT(data, at: pos, keepMarker: true)
                let id = UInt32(truncatingIfNeeded: id64)
                if stopOnSegmentSibling && EBML.segmentLevelIDs.contains(id) {
                    pos = elemStart
                    return
                }
                pos += idLen
                let (sz64, szLen, isUnk) = try EBML.readVINT(data, at: pos, keepMarker: false)
                pos += szLen
                if isUnk {
                    out.hasStreamingUnknownSize = true
                }
                let elemEnd: Int
                if isUnk {
                    elemEnd = end
                } else {
                    guard sz64 <= UInt64(end - pos) else {
                        elemEnd = end
                        break
                    }
                    elemEnd = pos + Int(sz64)
                }
                try handler(id, pos, elemEnd, isUnk)
                pos = elemEnd
            }
        }

        var sawEBMLHeader = false
        var sawSegment = false

        while pos < data.count {
            let (id64, idLen, _) = try EBML.readVINT(data, at: pos, keepMarker: true)
            pos += idLen
            let (sz64, szLen, isUnk) = try EBML.readVINT(data, at: pos, keepMarker: false)
            pos += szLen
            if isUnk {
                out.hasStreamingUnknownSize = true
            }
            let topEnd: Int
            if isUnk {
                topEnd = data.count
            } else {
                guard sz64 <= UInt64(data.count - pos) else {
                    throw SafariumError.encode("truncated top-level EBML element")
                }
                topEnd = pos + Int(sz64)
            }
            let topID = UInt32(truncatingIfNeeded: id64)

            if topID == EBML.idEBML {
                sawEBMLHeader = true
                try parseMaster(end: topEnd) { id, s, e, _ in
                    if id == EBML.idDocType {
                        out.docType = String(decoding: data[s..<e], as: UTF8.self)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                    }
                }
            } else if topID == EBML.idSegment {
                sawSegment = true
                try parseMaster(end: topEnd) { segChild, s, e, childUnknown in
                    if segChild == EBML.idInfo {
                        pos = s
                        try parseMaster(end: e) { id, is0, ie0, _ in
                            if id == EBML.idTimestampScale {
                                let ts = EBML.decodeUInt(data[is0..<ie0])
                                if ts > 0 { out.timestampScaleNS = ts }
                            } else if id == EBML.idDuration {
                                out.durationTicks = EBML.decodeFloat(data[is0..<ie0])
                            }
                        }
                    } else if segChild == EBML.idTracks {
                        pos = s
                        try parseMaster(end: e) { id, ts0, te0, _ in
                            if id == EBML.idTrackEntry {
                                var num = 0
                                var uid: UInt64 = 0
                                var ttype: UInt64 = 0
                                var cid = ""
                                var cp = Data()
                                var dd: UInt64?
                                var w: Int?
                                var h: Int?
                                var sr: Double?
                                var ch: Int?
                                var lang: String?
                                pos = ts0
                                try parseMaster(end: te0) { tid, fs, fe, _ in
                                    switch tid {
                                    case EBML.idTrackNumber: num = Int(EBML.decodeUInt(data[fs..<fe]))
                                    case EBML.idTrackUID: uid = EBML.decodeUInt(data[fs..<fe])
                                    case EBML.idTrackType: ttype = EBML.decodeUInt(data[fs..<fe])
                                    case EBML.idCodecID:
                                        cid = String(decoding: data[fs..<fe], as: UTF8.self)
                                            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                                    case EBML.idCodecPrivate: cp = Data(data[fs..<fe])
                                    case EBML.idLanguageBCP47:
                                        lang = String(decoding: data[fs..<fe], as: UTF8.self)
                                            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                                    case EBML.idLanguage:
                                        if lang == nil {
                                            lang = String(decoding: data[fs..<fe], as: UTF8.self)
                                                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                                        }
                                    case EBML.idDefaultDuration: dd = EBML.decodeUInt(data[fs..<fe])
                                    case EBML.idVideo:
                                        pos = fs
                                        try parseMaster(end: fe) { vid, vs, ve, _ in
                                            if vid == EBML.idPixelWidth { w = Int(EBML.decodeUInt(data[vs..<ve])) }
                                            else if vid == EBML.idPixelHeight { h = Int(EBML.decodeUInt(data[vs..<ve])) }
                                        }
                                    case EBML.idAudio:
                                        pos = fs
                                        try parseMaster(end: fe) { aid, as0, ae0, _ in
                                            if aid == EBML.idSamplingFrequency { sr = EBML.decodeFloat(data[as0..<ae0]) }
                                            else if aid == EBML.idChannels { ch = Int(EBML.decodeUInt(data[as0..<ae0])) }
                                        }
                                    default: break
                                    }
                                }
                                let kind: ContainerTrackKind
                                switch ttype {
                                case 1: kind = .video
                                case 2: kind = .audio
                                default: kind = .subtitle
                                }
                                if num > 0 {
                                    out.tracks[num] = InternalTrack(
                                        trackNumber: num,
                                        trackUID: uid,
                                        kind: kind,
                                        codecID: cid,
                                        codecPrivate: cp,
                                        defaultDurationNS: dd,
                                        width: w,
                                        height: h,
                                        sampleRate: sr,
                                        channels: ch,
                                        language: lang
                                    )
                                }
                            }
                        }
                    } else if segChild == EBML.idCluster {
                        var clusterTS: Int64 = 0
                        pos = s
                        try parseMaster(end: e, stopOnSegmentSibling: childUnknown) { cid, cs, ce, _ in
                            if cid == EBML.idTimestamp {
                                clusterTS = Int64(EBML.decodeUInt(data[cs..<ce]))
                            } else if cid == EBML.idSimpleBlock {
                                let pkts = try parseBlockFrames(
                                    payload: Data(data[cs..<ce]),
                                    clusterTS: clusterTS,
                                    blockDuration: nil,
                                    allowKeyframeFlag: true
                                )
                                out.packets.append(contentsOf: pkts)
                            } else if cid == EBML.idBlockGroup {
                                var blkData: Data?
                                var blkDur: Int64?
                                var isRef = false
                                pos = cs
                                try parseMaster(end: ce) { bid, bs, be, _ in
                                    if bid == EBML.idBlock { blkData = Data(data[bs..<be]) }
                                    else if bid == EBML.idBlockDuration { blkDur = Int64(EBML.decodeUInt(data[bs..<be])) }
                                    else if bid == EBML.idReferenceBlock { isRef = true }
                                }
                                if let blkData {
                                    let pkts = try parseBlockFrames(
                                        payload: blkData,
                                        clusterTS: clusterTS,
                                        blockDuration: blkDur,
                                        allowKeyframeFlag: false
                                    )
                                    for p in pkts {
                                        out.packets.append(InternalPacket(
                                            trackNumber: p.trackNumber,
                                            ptsTicks: p.ptsTicks,
                                            durationTicks: p.durationTicks,
                                            isKeyframe: !isRef,
                                            data: p.data
                                        ))
                                    }
                                }
                            }
                        }
                        if childUnknown {
                            return
                        }
                    } else if segChild == EBML.idCues {
                        pos = s
                        try parseMaster(end: e) { cid, _, _, _ in
                            if cid == EBML.idCuePoint { out.cuePointCount += 1 }
                        }
                    }
                }
            }
            pos = topEnd
        }

        guard sawEBMLHeader, sawSegment else {
            throw SafariumError.encode("input is not a valid EBML Matroska/WebM file")
        }
        return out
    }

    private static func buildReport(url: URL, parsed: ParsedMKV) -> (MKVInspectReport, [DemuxedPacket]) {
        let scaleNS = parsed.timestampScaleNS
        func ticksTo90k(_ ticks: Int64) -> Int64 {
            if scaleNS == 1_000_000 { return ticks * 90 }
            let sec = Double(ticks) * Double(scaleNS) / 1_000_000_000.0
            return Int64((sec * 90_000.0).rounded())
        }
        func ticksToMS(_ ticks: Int64) -> Int64 {
            if scaleNS == 1_000_000 { return ticks }
            return Int64((Double(ticks) * Double(scaleNS) / 1_000_000.0).rounded())
        }

        let sortedTracks = parsed.tracks.values.sorted { $0.trackNumber < $1.trackNumber }
        let trackInfos = sortedTracks.map { $0.toPublic() }

        var demuxedPkts: [DemuxedPacket] = []
        demuxedPkts.reserveCapacity(parsed.packets.count)
        var vCount = 0
        var aCount = 0
        var cues: [MKVSubtitleCue] = []

        for p in parsed.packets {
            let kind = parsed.tracks[p.trackNumber]?.kind ?? .video
            switch kind {
            case .video: vCount += 1
            case .audio: aCount += 1
            case .subtitle:
                let startMS = max(0, ticksToMS(p.ptsTicks))
                let durMS = max(1, ticksToMS(p.durationTicks ?? 1000))
                let txt = String(decoding: p.data, as: UTF8.self)
                if !txt.isEmpty {
                    cues.append(MKVSubtitleCue(startMS: startMS, endMS: startMS + durMS, text: txt))
                }
            }
            let pts90k = ticksTo90k(p.ptsTicks)
            let dur90k = p.durationTicks.map { ticksTo90k($0) } ?? 0
            demuxedPkts.append(DemuxedPacket(
                trackNumber: p.trackNumber,
                kind: kind,
                pts90k: pts90k,
                dts90k: pts90k,
                duration90k: dur90k,
                isKeyframe: p.isKeyframe,
                data: p.data
            ))
        }

        let durSec: Double
        if parsed.durationTicks > 0 {
            durSec = parsed.durationTicks * Double(scaleNS) / 1_000_000_000.0
        } else if let maxTicks = parsed.packets.map({ $0.ptsTicks + ($0.durationTicks ?? 0) }).max() {
            durSec = Double(max(0, maxTicks)) * Double(scaleNS) / 1_000_000_000.0
        } else {
            durSec = 0
        }

        let report = MKVInspectReport(
            path: url.path,
            docType: parsed.docType.isEmpty ? "matroska" : parsed.docType,
            timestampScaleNS: scaleNS,
            durationSeconds: durSec,
            tracks: trackInfos,
            packetCount: parsed.packets.count,
            videoPackets: vCount,
            audioPackets: aCount,
            subtitleCues: cues.count,
            cues: cues,
            cuePointCount: parsed.cuePointCount,
            hasStreamingUnknownSize: parsed.hasStreamingUnknownSize
        )
        return (report, demuxedPkts)
    }

    // MARK: - Public Inspect / Packet Demux / EBML Builder

    public static func inspect(url: URL) throws -> MKVInspectReport {
        try SafeFilePublisher.assertRegularReadableFile(url)
        let data = try Data(contentsOf: url)
        let parsed = try parseEBML(data)
        return buildReport(url: url, parsed: parsed).0
    }

    public static func demuxPackets(url: URL) throws -> (inspect: MKVInspectReport, packets: [DemuxedPacket]) {
        try SafeFilePublisher.assertRegularReadableFile(url)
        let data = try Data(contentsOf: url)
        let parsed = try parseEBML(data)
        return buildReport(url: url, parsed: parsed)
    }

    /// Builds an EBML (`"matroska"` or `"webm"`) byte stream from track configs and packets (timestamps in 90 kHz).
    public static func buildEBML(
        docType: String,
        tracks: [ContainerTrackInfo],
        packets: [DemuxedPacket],
        durationMS: Int64? = nil,
        streamingUnknownSegment: Bool = false
    ) throws -> Data {
        guard docType == "matroska" || docType == "webm" else {
            throw SafariumError.invalidState("EBML docType must be 'matroska' or 'webm', got '\(docType)'")
        }
        guard !tracks.isEmpty else {
            throw SafariumError.invalidState("buildEBML requires at least one track")
        }

        var ebmlBody = Data()
        ebmlBody.append(EBML.elementUInt(EBML.idEBMLVersion, 1))
        ebmlBody.append(EBML.elementUInt(EBML.idEBMLReadVersion, 1))
        ebmlBody.append(EBML.elementUInt(EBML.idEBMLMaxIDLength, 4))
        ebmlBody.append(EBML.elementUInt(EBML.idEBMLMaxSizeLength, 8))
        ebmlBody.append(EBML.elementStr(EBML.idDocType, docType))
        ebmlBody.append(EBML.elementUInt(EBML.idDocTypeVersion, 4))
        ebmlBody.append(EBML.elementUInt(EBML.idDocTypeReadVersion, 2))
        let ebmlHeader = EBML.element(EBML.idEBML, ebmlBody)

        let msPackets: [(trackNumber: Int, kind: ContainerTrackKind, ptsMS: Int64, durationMS: Int64?, isKeyframe: Bool, data: Data)] = packets.map { p in
            let ptsMS = Int64((Double(p.pts90k) / 90.0).rounded())
            let durMS: Int64? = (p.kind == .subtitle || p.duration90k > 0)
                ? Int64((Double(p.duration90k) / 90.0).rounded())
                : nil
            return (p.trackNumber, p.kind, ptsMS, durMS, p.isKeyframe, p.data)
        }

        var infoBody = Data()
        infoBody.append(EBML.elementUInt(EBML.idTimestampScale, 1_000_000))
        infoBody.append(EBML.elementStr(EBML.idMuxingApp, "SafariumEBML/1.0"))
        infoBody.append(EBML.elementStr(EBML.idWritingApp, "SafariumContainers/1.0"))
        let computedMaxMS = msPackets.map { $0.ptsMS + ($0.durationMS ?? 0) }.max() ?? 0
        infoBody.append(EBML.element(EBML.idDuration, EBML.encodeFloat64(Double(durationMS ?? computedMaxMS))))
        let infoEl = EBML.element(EBML.idInfo, infoBody)

        var tracksBody = Data()
        for t in tracks {
            var entry = Data()
            entry.append(EBML.elementUInt(EBML.idTrackNumber, UInt64(t.trackNumber)))
            entry.append(EBML.elementUInt(EBML.idTrackUID, UInt64(100 + t.trackNumber)))
            let tType: UInt64
            switch t.kind {
            case .video: tType = 1
            case .audio: tType = 2
            case .subtitle: tType = 17
            }
            entry.append(EBML.elementUInt(EBML.idTrackType, tType))
            entry.append(EBML.elementStr(EBML.idCodecID, t.codecID))
            if !t.codecPrivate.isEmpty {
                entry.append(EBML.element(EBML.idCodecPrivate, t.codecPrivate))
            }
            if let lang = t.language, !lang.isEmpty {
                entry.append(EBML.elementStr(EBML.idLanguage, lang))
            }
            if let w = t.width, let h = t.height {
                var v = Data()
                v.append(EBML.elementUInt(EBML.idPixelWidth, UInt64(w)))
                v.append(EBML.elementUInt(EBML.idPixelHeight, UInt64(h)))
                entry.append(EBML.element(EBML.idVideo, v))
            }
            if let sr = t.sampleRate, let ch = t.channels {
                var a = Data()
                a.append(EBML.element(EBML.idSamplingFrequency, EBML.encodeFloat64(Double(sr))))
                a.append(EBML.elementUInt(EBML.idChannels, UInt64(ch)))
                a.append(EBML.elementUInt(EBML.idBitDepth, 16))
                entry.append(EBML.element(EBML.idAudio, a))
            }
            tracksBody.append(EBML.element(EBML.idTrackEntry, entry))
        }
        let tracksEl = EBML.element(EBML.idTracks, tracksBody)

        let primaryVideoTrack = tracks.first(where: { $0.kind == .video })?.trackNumber
            ?? tracks.first?.trackNumber
            ?? 1

        var clusterBuckets: [(ts: Int64, pkts: [(trackNumber: Int, kind: ContainerTrackKind, ptsMS: Int64, durationMS: Int64?, isKeyframe: Bool, data: Data)])] = []
        for p in msPackets {
            let splitCluster = clusterBuckets.isEmpty
                || (p.trackNumber == primaryVideoTrack && p.isKeyframe && p.ptsMS - clusterBuckets.last!.ts >= 400)
            if splitCluster {
                clusterBuckets.append((max(0, p.ptsMS), [p]))
            } else {
                clusterBuckets[clusterBuckets.count - 1].pkts.append(p)
            }
        }

        var clustersData = Data()
        var clusterOffsets: [(ts: Int64, offsetInSegment: Int)] = []
        for bucket in clusterBuckets {
            clusterOffsets.append((bucket.ts, clustersData.count))
            var cBody = Data()
            cBody.append(EBML.elementUInt(EBML.idTimestamp, UInt64(max(0, bucket.ts))))
            for p in bucket.pkts {
                let rel = Int16(clamping: p.ptsMS - bucket.ts)
                if p.kind == .subtitle, let dur = p.durationMS {
                    var blk = EBML.encodeSize(UInt64(p.trackNumber))
                    var relBE = rel.bigEndian
                    blk.append(Data(bytes: &relBE, count: 2))
                    blk.append(0x00)
                    blk.append(p.data)
                    var bg = Data()
                    bg.append(EBML.element(EBML.idBlock, blk))
                    bg.append(EBML.elementUInt(EBML.idBlockDuration, UInt64(max(0, dur))))
                    cBody.append(EBML.element(EBML.idBlockGroup, bg))
                } else {
                    var sb = EBML.encodeSize(UInt64(p.trackNumber))
                    var relBE = rel.bigEndian
                    sb.append(Data(bytes: &relBE, count: 2))
                    sb.append(p.isKeyframe ? 0x80 : 0x00)
                    sb.append(p.data)
                    cBody.append(EBML.element(EBML.idSimpleBlock, sb))
                }
            }
            clustersData.append(EBML.element(EBML.idCluster, cBody))
        }

        func makeSeekEntry(id: UInt32, pos: UInt64) -> Data {
            var b = Data()
            b.append(EBML.element(EBML.idSeekID, EBML.encodeID(id)))
            b.append(EBML.elementUInt(EBML.idSeekPosition, pos))
            return EBML.element(EBML.idSeek, b)
        }

        var seekHeadEl = Data()
        var cuesEl = Data()
        for _ in 0..<3 {
            let infoPos = UInt64(seekHeadEl.count)
            let tracksPos = infoPos + UInt64(infoEl.count)
            let firstClusterPos = tracksPos + UInt64(tracksEl.count)
            let cuesPos = firstClusterPos + UInt64(clustersData.count)

            var cuesBody = Data()
            for co in clusterOffsets {
                var ctp = Data()
                ctp.append(EBML.elementUInt(EBML.idCueTrack, UInt64(primaryVideoTrack)))
                ctp.append(EBML.elementUInt(EBML.idCueClusterPosition, firstClusterPos + UInt64(co.offsetInSegment)))
                var cp = Data()
                cp.append(EBML.elementUInt(EBML.idCueTime, UInt64(max(0, co.ts))))
                cp.append(EBML.element(EBML.idCueTrackPositions, ctp))
                cuesBody.append(EBML.element(EBML.idCuePoint, cp))
            }
            cuesEl = EBML.element(EBML.idCues, cuesBody)

            var sh = Data()
            sh.append(makeSeekEntry(id: EBML.idInfo, pos: infoPos))
            sh.append(makeSeekEntry(id: EBML.idTracks, pos: tracksPos))
            sh.append(makeSeekEntry(id: EBML.idCluster, pos: firstClusterPos))
            sh.append(makeSeekEntry(id: EBML.idCues, pos: cuesPos))
            seekHeadEl = EBML.element(EBML.idSeekHead, sh)
        }

        var segmentPayload = Data()
        segmentPayload.append(seekHeadEl)
        segmentPayload.append(infoEl)
        segmentPayload.append(tracksEl)
        segmentPayload.append(clustersData)
        segmentPayload.append(cuesEl)

        var file = Data()
        file.append(ebmlHeader)
        file.append(EBML.encodeID(EBML.idSegment))
        if streamingUnknownSegment {
            file.append(EBML.unknownSizeRaw8)
        } else {
            file.append(EBML.encodeSize(UInt64(segmentPayload.count)))
        }
        file.append(segmentPayload)
        return file
    }

    // MARK: - Demux MKV -> MP4 / MOV

    private static func makeVideoFormatDescription(from track: InternalTrack) throws -> CMVideoFormatDescription {
        guard !track.codecPrivate.isEmpty else {
            throw SafariumError.encode("missing CodecPrivate for MKV video codec \(track.codecID)")
        }
        guard let w = track.width, let h = track.height, w > 0, h > 0 else {
            throw SafariumError.encode("missing dimensions for MKV video track \(track.trackNumber)")
        }
        let codecType: CMVideoCodecType
        let atomKey: String
        let atomData: Data
        switch track.codecID {
        case "V_MPEG4/ISO/AVC":
            codecType = kCMVideoCodecType_H264
            atomKey = "avcC"
            atomData = track.codecPrivate
        case "V_MPEGH/ISO/HEVC":
            codecType = kCMVideoCodecType_HEVC
            atomKey = "hvcC"
            atomData = track.codecPrivate
        case "V_AV1":
            codecType = kCMVideoCodecType_AV1
            atomKey = "av1C"
            atomData = track.codecPrivate
        case "V_VP9":
            MediaCompatBridge.registerSupplementalDecoders()
            codecType = kCMVideoCodecType_VP9
            atomKey = "vpcC"
            atomData = MediaCompatBridge.makeVPCCFullBox(fromWebMCodecPrivate: track.codecPrivate)
        default:
            throw SafariumError.encode("unsupported MKV/WebM video codec for MP4 mux: \(track.codecID)")
        }
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: [atomKey: atomData] as CFDictionary
        ]
        var desc: CMVideoFormatDescription?
        let st = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: codecType,
            width: Int32(w),
            height: Int32(h),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &desc
        )
        guard st == noErr, let desc else {
            throw SafariumError.encode("CMVideoFormatDescriptionCreate(\(track.codecID)) failed (\(st))")
        }
        return desc
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

        let raw = try Data(contentsOf: inputURL)
        let parsed = try parseEBML(raw)

        let vTrack = parsed.tracks.values.sorted { $0.trackNumber < $1.trackNumber }.first { $0.kind == .video }
        let aTrack = parsed.tracks.values.sorted { $0.trackNumber < $1.trackNumber }.first { $0.kind == .audio }
        let sTrack = parsed.tracks.values.sorted { $0.trackNumber < $1.trackNumber }.first { $0.kind == .subtitle }

        guard vTrack != nil || aTrack != nil else {
            throw SafariumError.encode("MKV/WebM contains no video or audio track: \(inputURL.lastPathComponent)")
        }

        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }
        let tempURL = staging.fileURL("demux.\(ext)")

        let writer = try AVAssetWriter(url: tempURL, fileType: fileType)
        writer.movieTimeScale = 90_000
        writer.shouldOptimizeForNetworkUse = true

        let scaleNS = parsed.timestampScaleNS
        func ticksTo90k(_ ticks: Int64) -> Int64 {
            if scaleNS == 1_000_000 { return ticks * 90 }
            let sec = Double(ticks) * Double(scaleNS) / 1_000_000_000.0
            return Int64((sec * 90_000.0).rounded())
        }
        func ticksToMS(_ ticks: Int64) -> Int64 {
            if scaleNS == 1_000_000 { return ticks }
            return Int64((Double(ticks) * Double(scaleNS) / 1_000_000.0).rounded())
        }

        var vFmt: CMVideoFormatDescription?
        var vi: AVAssetWriterInput?
        if let vTrack {
            let fmt = try makeVideoFormatDescription(from: vTrack)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmt)
            input.mediaTimeScale = 90_000
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw SafariumError.encode("AVAssetWriter cannot add MKV video codec \(vTrack.codecID)")
            }
            writer.add(input)
            vFmt = fmt
            vi = input
        }

        var aFmt: CMAudioFormatDescription?
        var ai: AVAssetWriterInput?
        var audioSampleRate = 48_000
        if let aTrack {
            let sr = aTrack.sampleRate ?? 48_000
            let ch = aTrack.channels ?? 2
            let fmt: CMAudioFormatDescription
            if aTrack.codecID == "A_AAC" {
                fmt = try MediaCompatBridge.makeAudioFormatDescriptionFromASC(aTrack.codecPrivate, sampleRate: sr, channels: ch)
                if let parsedASC = try? MediaCompatBridge.parseAACAudioSpecificConfig(
                    try MediaCompatBridge.unwrapWebCodecsESDS(aTrack.codecPrivate).audioSpecificConfig
                ) {
                    audioSampleRate = parsedASC.sampleRate
                } else {
                    audioSampleRate = Int(sr.rounded())
                }
            } else {
                throw SafariumError.encode("unsupported MKV audio codec for lossless MP4 remux: \(aTrack.codecID)")
            }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: fmt)
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw SafariumError.encode("AVAssetWriter cannot add MKV audio codec \(aTrack.codecID)")
            }
            writer.add(input)
            aFmt = fmt
            ai = input
        }

        let dvPkts = vTrack.map { vt in parsed.packets.filter { $0.trackNumber == vt.trackNumber } } ?? []
        let daPkts = aTrack.map { at in parsed.packets.filter { $0.trackNumber == at.trackNumber } } ?? []
        let dsPkts = sTrack.map { st in parsed.packets.filter { $0.trackNumber == st.trackNumber } } ?? []

        // Prepare video timings (monotonic DTS + minVPTS preroll alignment eliminating 31->30 frame duplicate)
        let vPTS90k = dvPkts.map { ticksTo90k($0.ptsTicks) }
        let sortedVPTS90k = vPTS90k.sorted()
        let minVPTS90k = sortedVPTS90k.first ?? 0
        var maxShift90k: Int64 = 0
        for i in vPTS90k.indices {
            maxShift90k = max(maxShift90k, sortedVPTS90k[i] - vPTS90k[i])
        }
        let defaultVDuration90k: Int64 = {
            if let dd = vTrack?.defaultDurationNS, dd > 0 {
                return max(1, Int64((Double(dd) / 1_000_000_000.0 * 90_000.0).rounded()))
            }
            if sortedVPTS90k.count >= 2 {
                let diffs = zip(sortedVPTS90k, sortedVPTS90k.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
                if !diffs.isEmpty { return diffs[diffs.count / 2] }
            }
            return 3000
        }()

        let totalVideoEnd90k: Int64 = {
            guard !sortedVPTS90k.isEmpty else { return 0 }
            let lastPTS = (sortedVPTS90k.last ?? 0) - minVPTS90k
            return max(1, lastPTS + defaultVDuration90k)
        }()
        let totalAudioEnd90k: Int64 = {
            guard !daPkts.isEmpty else { return 0 }
            let sec = Double(daPkts.count * 1024) / Double(max(1, audioSampleRate))
            return Int64((sec * 90_000.0).rounded())
        }()
        let movieEnd90k = max(1, max(totalVideoEnd90k, totalAudioEnd90k))
        let movieDuration = CMTime(value: movieEnd90k, timescale: 90_000)

        var subSetup: (CMFormatDescription, [CMSampleBuffer])?
        var parsedSubCues: [SafariumSRTCue] = []
        for p in dsPkts where sTrack?.codecID == "S_TEXT/UTF8" {
            let text = String(decoding: p.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                let sMS = max(0, ticksToMS(p.ptsTicks))
                let durMS = max(1, ticksToMS(p.durationTicks ?? 1000))
                parsedSubCues.append(SafariumSRTCue(startMS: sMS, endMS: sMS + durMS, text: text))
            }
        }
        var si: AVAssetWriterInput?
        if !parsedSubCues.isEmpty {
            let w = vTrack?.width ?? 1280
            let h = vTrack?.height ?? 720
            let built = try SafariumTX3G.buildContiguousSamples(
                cues: parsedSubCues,
                duration: movieDuration,
                width: w,
                height: h
            )
            subSetup = built
            let sIn = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: built.0)
            sIn.mediaTimeScale = SafariumTX3G.recommendedTimeScale(for: movieDuration)
            sIn.marksOutputTrackAsEnabled = true
            sIn.expectsMediaDataInRealTime = false
            if let lang = sTrack?.language, lang.count == 3 {
                sIn.languageCode = lang
            }
            guard writer.canAdd(sIn) else {
                throw SafariumError.encode("AVAssetWriter cannot add tx3g subtitle track")
            }
            writer.add(sIn)
            si = sIn
        }

        guard writer.startWriting() else {
            throw SafariumError.encode("AVAssetWriter startWriting failed: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)

        if let vi, let vFmt {
            for (idx, p) in dvPkts.enumerated() {
                while !vi.isReadyForMoreMediaData {
                    if writer.status == .failed {
                        throw SafariumError.encode("video writer failed: \(writer.error?.localizedDescription ?? "?")")
                    }
                    try await Task.sleep(nanoseconds: 500_000)
                }
                let dts90k = (sortedVPTS90k[idx] - maxShift90k) - minVPTS90k
                let nextDTS90k = (idx + 1 < dvPkts.count
                    ? (sortedVPTS90k[idx + 1] - maxShift90k)
                    : (sortedVPTS90k[idx] - maxShift90k + defaultVDuration90k)) - minVPTS90k
                let dur90k = max(1, nextDTS90k - dts90k)
                let sb = try MediaCompatBridge.makeReadySampleBuffer(
                    data: p.data,
                    formatDescription: vFmt,
                    pts: CMTime(value: vPTS90k[idx] - minVPTS90k, timescale: 90_000),
                    dts: CMTime(value: dts90k, timescale: 90_000),
                    duration: CMTime(value: dur90k, timescale: 90_000),
                    isSync: p.isKeyframe
                )
                guard vi.append(sb) else {
                    throw SafariumError.encode("video sample append failed at \(idx): \(writer.error?.localizedDescription ?? "?")")
                }
            }
            vi.markAsFinished()
        }

        if let ai, let aFmt {
            let initialAudioOffset90k: Int64 = {
                guard let first = daPkts.first else { return 0 }
                let t = ticksTo90k(first.ptsTicks)
                return t > 900 ? t : 0
            }()
            for (idx, p) in daPkts.enumerated() {
                while !ai.isReadyForMoreMediaData {
                    if writer.status == .failed {
                        throw SafariumError.encode("audio writer failed: \(writer.error?.localizedDescription ?? "?")")
                    }
                    try await Task.sleep(nanoseconds: 500_000)
                }
                let basePTS = CMTime(value: Int64(idx) * 1024, timescale: Int32(audioSampleRate))
                let pts = initialAudioOffset90k > 0
                    ? CMTimeAdd(CMTime(value: initialAudioOffset90k, timescale: 90_000), basePTS)
                    : basePTS
                let sb = try MediaCompatBridge.makeReadySampleBuffer(
                    data: p.data,
                    formatDescription: aFmt,
                    pts: pts,
                    dts: .invalid,
                    duration: CMTime(value: 1024, timescale: Int32(audioSampleRate)),
                    isSync: true
                )
                guard ai.append(sb) else {
                    throw SafariumError.encode("audio sample append failed at \(idx): \(writer.error?.localizedDescription ?? "?")")
                }
            }
            ai.markAsFinished()
        }

        if let si, let subSamples = subSetup?.1 {
            for (idx, sb) in subSamples.enumerated() {
                while !si.isReadyForMoreMediaData {
                    if writer.status == .failed {
                        throw SafariumError.encode("subtitle writer failed: \(writer.error?.localizedDescription ?? "?")")
                    }
                    try await Task.sleep(nanoseconds: 500_000)
                }
                guard si.append(sb) else {
                    throw SafariumError.encode("subtitle sample append failed at \(idx): \(writer.error?.localizedDescription ?? "?")")
                }
            }
            si.markAsFinished()
        }

        writer.endSession(atSourceTime: movieDuration)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw SafariumError.encode("MKV demux finishWriting failed: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")")
        }

        try SafeFilePublisher.publish(tempURL: tempURL, to: outputURL, overwrite: overwrite)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return RemuxReport(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            sourceContainer: parsed.docType.isEmpty ? "matroska" : parsed.docType,
            targetContainer: ext,
            videoPackets: dvPkts.count,
            audioPackets: daPkts.count,
            subtitleCues: parsedSubCues.count,
            wallMs: elapsedMs
        )
    }

    // MARK: - Mux MP4 / MOV -> MKV / WebM

    public static func muxFromMP4OrMOV(
        inputURL: URL,
        outputURL: URL,
        docType: String = "matroska",
        subtitleCues: [SafariumSRTCue] = [],
        overwrite: Bool = false
    ) async throws -> RemuxReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(inputURL)
        guard docType == "matroska" || docType == "webm" else {
            throw SafariumError.invalidState("EBML docType must be 'matroska' or 'webm', got '\(docType)'")
        }
        try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)

        let asset = AVURLAsset(url: inputURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let vTrack = try await asset.loadTracks(withMediaType: .video).first
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first
        let subTrackPrimary = try await asset.loadTracks(withMediaType: .subtitle).first
        let sTrack: AVAssetTrack?
        if let subTrackPrimary {
            sTrack = subTrackPrimary
        } else {
            sTrack = try await asset.loadTracks(withMediaType: .text).first
        }

        guard vTrack != nil || aTrack != nil else {
            throw SafariumError.encode("input MP4/MOV has no video or audio track: \(inputURL.lastPathComponent)")
        }

        var tracks: [ContainerTrackInfo] = []
        var packets: [DemuxedPacket] = []
        var nextTrackNum = 1
        var vTrackNum = 0
        var aTrackNum = 0
        var sTrackNum = 0

        let reader = try AVAssetReader(asset: asset)
        var vOut: AVAssetReaderTrackOutput?
        var aOut: AVAssetReaderTrackOutput?
        var sOut: AVAssetReaderTrackOutput?

        if let vTrack {
            let vFmts = try await vTrack.load(.formatDescriptions)
            guard let vFmt = vFmts.first else {
                throw SafariumError.encode("missing video format description in \(inputURL.lastPathComponent)")
            }
            let sub = MediaCompatBridge.fourCCString(CMFormatDescriptionGetMediaSubType(vFmt))
            let dims = CMVideoFormatDescriptionGetDimensions(vFmt)
            let atoms = CMFormatDescriptionGetExtension(
                vFmt,
                extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
            ) as? [String: Any]

            let codecID: String
            let codecPrivate: Data
            switch sub {
            case "avc1", "avc3":
                guard docType == "matroska" else {
                    throw SafariumError.encode("WebM container does not support H.264; use docType 'matroska'")
                }
                codecID = "V_MPEG4/ISO/AVC"
                codecPrivate = (atoms?["avcC"] as? Data) ?? Data()
            case "hvc1", "hev1":
                guard docType == "matroska" else {
                    throw SafariumError.encode("WebM container does not support HEVC; use docType 'matroska'")
                }
                codecID = "V_MPEGH/ISO/HEVC"
                codecPrivate = (atoms?["hvcC"] as? Data) ?? Data()
            case "vp09":
                codecID = "V_VP9"
                codecPrivate = (atoms?["vpcC"] as? Data) ?? Data()
            case "av01":
                codecID = "V_AV1"
                codecPrivate = (atoms?["av1C"] as? Data) ?? Data()
            default:
                throw SafariumError.encode("unsupported video FourCC '\(sub)' for MKV/WebM mux")
            }

            vTrackNum = nextTrackNum
            nextTrackNum += 1
            tracks.append(ContainerTrackInfo(
                trackNumber: vTrackNum,
                kind: .video,
                codecID: codecID,
                width: Int(dims.width),
                height: Int(dims.height),
                codecPrivate: codecPrivate
            ))
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
            let asbd = asbdPtr.pointee
            let codecID: String
            let codecPrivate: Data
            if asbd.mFormatID == kAudioFormatMPEG4AAC {
                guard docType == "matroska" else {
                    throw SafariumError.encode("WebM container does not support AAC; use docType 'matroska'")
                }
                codecID = "A_AAC"
                var cookieLen = 0
                let cookiePtr = CMAudioFormatDescriptionGetMagicCookie(aFmt, sizeOut: &cookieLen)
                let cookie = (cookiePtr != nil && cookieLen > 0) ? Data(bytes: cookiePtr!, count: cookieLen) : Data()
                codecPrivate = cookie.isEmpty ? Data() : (try MediaCompatBridge.unwrapWebCodecsESDS(cookie).audioSpecificConfig)
            } else if asbd.mFormatID == kAudioFormatOpus {
                codecID = "A_OPUS"
                var cookieLen = 0
                let cookiePtr = CMAudioFormatDescriptionGetMagicCookie(aFmt, sizeOut: &cookieLen)
                codecPrivate = (cookiePtr != nil && cookieLen > 0) ? Data(bytes: cookiePtr!, count: cookieLen) : Data()
            } else if asbd.mFormatID == kAudioFormatLinearPCM {
                guard docType == "matroska" else {
                    throw SafariumError.encode("WebM container does not support PCM; use docType 'matroska'")
                }
                codecID = "A_PCM/INT/LIT"
                codecPrivate = Data()
            } else {
                throw SafariumError.encode("unsupported audio format '\(MediaCompatBridge.fourCCString(asbd.mFormatID))' for MKV/WebM mux")
            }

            aTrackNum = nextTrackNum
            nextTrackNum += 1
            tracks.append(ContainerTrackInfo(
                trackNumber: aTrackNum,
                kind: .audio,
                codecID: codecID,
                sampleRate: Int(asbd.mSampleRate.rounded()),
                channels: Int(asbd.mChannelsPerFrame),
                codecPrivate: codecPrivate
            ))
            let out = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            reader.add(out)
            aOut = out
        }

        let hasSubtitles = !subtitleCues.isEmpty || (sTrack != nil && docType == "matroska")
        if hasSubtitles {
            guard docType == "matroska" else {
                throw SafariumError.encode("WebM does not support S_TEXT/UTF8 subtitle tracks")
            }
            sTrackNum = nextTrackNum
            nextTrackNum += 1
            tracks.append(ContainerTrackInfo(
                trackNumber: sTrackNum,
                kind: .subtitle,
                codecID: "S_TEXT/UTF8",
                codecPrivate: Data()
            ))
            if subtitleCues.isEmpty, let sTrack {
                let out = AVAssetReaderTrackOutput(track: sTrack, outputSettings: nil)
                reader.add(out)
                sOut = out
            }
        }

        guard reader.startReading() else {
            throw SafariumError.encode("AVAssetReader failed for \(inputURL.lastPathComponent): \(reader.error?.localizedDescription ?? "?")")
        }

        var vCount = 0
        var aCount = 0
        var sCount = 0

        if let vOut {
            while let sb = vOut.copyNextSampleBuffer() {
                guard sb.numSamples > 0 else { continue }
                let len = sb.dataBuffer.map { CMBlockBufferGetDataLength($0) } ?? 0
                var bytes = Data(count: len)
                if let db = sb.dataBuffer, len > 0 {
                    bytes.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(db, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
                }
                let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
                let notSync = (att?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
                let pts90k = Int64((sb.presentationTimeStamp.seconds * 90_000.0).rounded())
                let dts90k = sb.decodeTimeStamp.isValid ? Int64((sb.decodeTimeStamp.seconds * 90_000.0).rounded()) : pts90k
                let dur90k = sb.duration.isValid ? Int64((sb.duration.seconds * 90_000.0).rounded()) : 0
                packets.append(DemuxedPacket(
                    trackNumber: vTrackNum,
                    kind: .video,
                    pts90k: pts90k,
                    dts90k: dts90k,
                    duration90k: dur90k,
                    isKeyframe: !notSync,
                    data: bytes
                ))
                vCount += 1
            }
        }

        if let aOut {
            while let sb = aOut.copyNextSampleBuffer() {
                for ap in MediaCompatBridge.splitCompressedAudioPackets(from: sb) {
                    packets.append(DemuxedPacket(
                        trackNumber: aTrackNum,
                        kind: .audio,
                        pts90k: ap.pts90k,
                        dts90k: ap.pts90k,
                        duration90k: ap.duration90k,
                        isKeyframe: true,
                        data: ap.data
                    ))
                    aCount += 1
                }
            }
        }

        if sTrackNum > 0 {
            if !subtitleCues.isEmpty {
                for cue in subtitleCues where !cue.text.isEmpty {
                    let durMS = max(1, cue.endMS - cue.startMS)
                    packets.append(DemuxedPacket(
                        trackNumber: sTrackNum,
                        kind: .subtitle,
                        pts90k: cue.startMS * 90,
                        dts90k: cue.startMS * 90,
                        duration90k: durMS * 90,
                        isKeyframe: true,
                        data: Data(cue.text.utf8)
                    ))
                    sCount += 1
                }
            } else if let sOut {
                while let sb = sOut.copyNextSampleBuffer() {
                    guard sb.numSamples > 0, let db = sb.dataBuffer else { continue }
                    let len = CMBlockBufferGetDataLength(db)
                    var raw = Data(count: len)
                    if len > 0 {
                        raw.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(db, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
                    }
                    if raw.count >= 2 {
                        let textLen = (Int(raw[0]) << 8) | Int(raw[1])
                        if textLen > 0 && 2 + textLen <= raw.count {
                            let pts90k = Int64((sb.presentationTimeStamp.seconds * 90_000.0).rounded())
                            let dur90k = max(90, Int64((sb.duration.seconds * 90_000.0).rounded()))
                            packets.append(DemuxedPacket(
                                trackNumber: sTrackNum,
                                kind: .subtitle,
                                pts90k: pts90k,
                                dts90k: pts90k,
                                duration90k: dur90k,
                                isKeyframe: true,
                                data: raw.subdata(in: 2..<(2 + textLen))
                            ))
                            sCount += 1
                        }
                    }
                }
            }
        }

        let ebmlData = try buildEBML(docType: docType, tracks: tracks, packets: packets)
        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }
        let ext = outputURL.pathExtension.isEmpty ? (docType == "webm" ? "webm" : "mkv") : outputURL.pathExtension.lowercased()
        let tempURL = staging.fileURL("mux.\(ext)")
        try ebmlData.write(to: tempURL, options: .atomic)
        try SafeFilePublisher.publish(tempURL: tempURL, to: outputURL, overwrite: overwrite)

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let srcExt = inputURL.pathExtension.lowercased()
        return RemuxReport(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            sourceContainer: srcExt.isEmpty ? "mp4" : srcExt,
            targetContainer: docType,
            videoPackets: vCount,
            audioPackets: aCount,
            subtitleCues: sCount,
            wallMs: elapsedMs
        )
    }
}
