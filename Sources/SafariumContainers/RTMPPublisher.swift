import Darwin
import Foundation
import SafariumCore

// MARK: - Wave 16C: Pure-Swift Zero-Dependency RTMP 1.0 + Enhanced RTMP Publisher

/// AMF0 dynamic value representation (Adobe Action Message Format 0).
public enum AMF0Value: Sendable, Equatable {
    case number(Double)
    case boolean(Bool)
    case string(String)
    case object([(String, AMF0Value)])
    case null

    public static func == (lhs: AMF0Value, rhs: AMF0Value) -> Bool {
        switch (lhs, rhs) {
        case (.number(let a), .number(let b)):
            return a == b
        case (.boolean(let a), .boolean(let b)):
            return a == b
        case (.string(let a), .string(let b)):
            return a == b
        case (.null, .null):
            return true
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            for i in 0..<a.count {
                if a[i].0 != b[i].0 || a[i].1 != b[i].1 {
                    return false
                }
            }
            return true
        default:
            return false
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var numberValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var boolValue: Bool? {
        if case .boolean(let b) = self { return b }
        return nil
    }

    public subscript(key: String) -> AMF0Value? {
        guard case .object(let pairs) = self else { return nil }
        return pairs.first(where: { $0.0 == key })?.1
    }
}

/// Pure-Swift AMF0 binary encoder and decoder.
public enum AMF0Codec {
    private static let markerNumber: UInt8 = 0x00
    private static let markerBoolean: UInt8 = 0x01
    private static let markerString: UInt8 = 0x02
    private static let markerObject: UInt8 = 0x03
    private static let markerNull: UInt8 = 0x05
    private static let markerUndefined: UInt8 = 0x06
    private static let markerECMAArray: UInt8 = 0x08
    private static let markerObjectEnd: UInt8 = 0x09
    private static let markerStrictArray: UInt8 = 0x0A
    private static let markerLongString: UInt8 = 0x0C

    /// Encodes a single `AMF0Value` into wire bytes.
    public static func encode(_ value: AMF0Value) -> Data {
        var out = Data()
        encodeValue(value, into: &out)
        return out
    }

    /// Encodes a sequence of `AMF0Value` items back-to-back (standard RTMP command body format).
    public static func encodeSequence(_ values: [AMF0Value]) -> Data {
        var out = Data()
        for value in values {
            encodeValue(value, into: &out)
        }
        return out
    }

    /// Decodes all consecutive `AMF0Value` items in `data`.
    public static func decode(_ data: Data) throws -> [AMF0Value] {
        let bytes = [UInt8](data)
        var offset = 0
        var values: [AMF0Value] = []
        while offset < bytes.count {
            let value = try decodeOne(bytes, offset: &offset)
            values.append(value)
        }
        return values
    }

    private static func encodeValue(_ value: AMF0Value, into out: inout Data) {
        switch value {
        case .number(let num):
            out.append(markerNumber)
            var bits = num.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }

        case .boolean(let flag):
            out.append(markerBoolean)
            out.append(flag ? 0x01 : 0x00)

        case .string(let str):
            let utf8 = [UInt8](str.utf8)
            if utf8.count <= Int(UInt16.max) {
                out.append(markerString)
                appendUInt16BE(UInt16(utf8.count), to: &out)
                out.append(contentsOf: utf8)
            } else {
                out.append(markerLongString)
                appendUInt32BE(UInt32(utf8.count), to: &out)
                out.append(contentsOf: utf8)
            }

        case .object(let pairs):
            out.append(markerObject)
            for (key, val) in pairs {
                let keyBytes = [UInt8](key.utf8)
                let keyLen = min(keyBytes.count, Int(UInt16.max))
                appendUInt16BE(UInt16(keyLen), to: &out)
                out.append(contentsOf: keyBytes.prefix(keyLen))
                encodeValue(val, into: &out)
            }
            out.append(contentsOf: [0x00, 0x00, markerObjectEnd])

        case .null:
            out.append(markerNull)
        }
    }

    private static func decodeOne(_ bytes: [UInt8], offset: inout Int) throws -> AMF0Value {
        guard offset < bytes.count else {
            throw SafariumError.invalidState("AMF0 unexpected EOF at offset \(offset)")
        }
        let marker = bytes[offset]
        offset += 1

        switch marker {
        case markerNumber:
            guard offset + 8 <= bytes.count else {
                throw SafariumError.invalidState("AMF0 truncated number")
            }
            var raw: UInt64 = 0
            for i in 0..<8 {
                raw = (raw << 8) | UInt64(bytes[offset + i])
            }
            offset += 8
            return .number(Double(bitPattern: raw))

        case markerBoolean:
            guard offset + 1 <= bytes.count else {
                throw SafariumError.invalidState("AMF0 truncated boolean")
            }
            let b = bytes[offset] != 0
            offset += 1
            return .boolean(b)

        case markerString:
            let str = try readShortString(bytes, offset: &offset)
            return .string(str)

        case markerLongString:
            guard offset + 4 <= bytes.count else {
                throw SafariumError.invalidState("AMF0 truncated long string length")
            }
            let len = Int(readUInt32BE(bytes, offset: offset))
            offset += 4
            guard offset + len <= bytes.count else {
                throw SafariumError.invalidState("AMF0 truncated long string body")
            }
            let str = String(decoding: bytes[offset..<(offset + len)], as: UTF8.self)
            offset += len
            return .string(str)

        case markerObject:
            let pairs = try readObjectPairs(bytes, offset: &offset)
            return .object(pairs)

        case markerECMAArray:
            guard offset + 4 <= bytes.count else {
                throw SafariumError.invalidState("AMF0 truncated ECMA array count")
            }
            offset += 4
            let pairs = try readObjectPairs(bytes, offset: &offset)
            return .object(pairs)

        case markerStrictArray:
            guard offset + 4 <= bytes.count else {
                throw SafariumError.invalidState("AMF0 truncated strict array count")
            }
            let count = Int(readUInt32BE(bytes, offset: offset))
            offset += 4
            var pairs: [(String, AMF0Value)] = []
            for idx in 0..<count {
                let item = try decodeOne(bytes, offset: &offset)
                pairs.append(("\(idx)", item))
            }
            return .object(pairs)

        case markerNull, markerUndefined:
            return .null

        default:
            throw SafariumError.invalidState("AMF0 unsupported marker 0x\(String(marker, radix: 16))")
        }
    }

    private static func readObjectPairs(_ bytes: [UInt8], offset: inout Int) throws -> [(String, AMF0Value)] {
        var pairs: [(String, AMF0Value)] = []
        while true {
            guard offset + 3 <= bytes.count else {
                throw SafariumError.invalidState("AMF0 truncated object entry")
            }
            if bytes[offset] == 0x00 && bytes[offset + 1] == 0x00 && bytes[offset + 2] == markerObjectEnd {
                offset += 3
                break
            }
            let key = try readShortString(bytes, offset: &offset)
            let val = try decodeOne(bytes, offset: &offset)
            pairs.append((key, val))
        }
        return pairs
    }

    private static func readShortString(_ bytes: [UInt8], offset: inout Int) throws -> String {
        guard offset + 2 <= bytes.count else {
            throw SafariumError.invalidState("AMF0 truncated string length")
        }
        let hi = Int(bytes[offset]) << 8
        let lo = Int(bytes[offset + 1])
        let len = hi | lo
        offset += 2
        guard offset + len <= bytes.count else {
            throw SafariumError.invalidState("AMF0 truncated string payload")
        }
        let str = String(decoding: bytes[offset..<(offset + len)], as: UTF8.self)
        offset += len
        return str
    }

    private static func appendUInt16BE(_ v: UInt16, to out: inout Data) {
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8(v & 0xFF))
    }

    private static func appendUInt32BE(_ v: UInt32, to out: inout Data) {
        out.append(UInt8((v >> 24) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8(v & 0xFF))
    }

    private static func readUInt32BE(_ bytes: [UInt8], offset: Int) -> UInt32 {
        let b0 = UInt32(bytes[offset]) << 24
        let b1 = UInt32(bytes[offset + 1]) << 16
        let b2 = UInt32(bytes[offset + 2]) << 8
        let b3 = UInt32(bytes[offset + 3])
        return b0 | b1 | b2 | b3
    }
}

// MARK: - RTMP Chunk Stream Framing

/// Standard RTMP message type identifiers.
public enum RTMPMessageType {
    public static let setChunkSize: UInt8 = 1
    public static let abortMessage: UInt8 = 2
    public static let acknowledgement: UInt8 = 3
    public static let userControl: UInt8 = 4
    public static let windowAckSize: UInt8 = 5
    public static let setPeerBandwidth: UInt8 = 6
    public static let audio: UInt8 = 8
    public static let video: UInt8 = 9
    public static let amf0Data: UInt8 = 18
    public static let amf0Command: UInt8 = 20
}

/// RTMP chunk header metadata (`fmt 0`..`fmt 3`).
public struct RTMPChunkHeader: Sendable, Equatable {
    public var fmt: UInt8
    public var chunkStreamID: UInt32
    public var timestamp: UInt32
    public var messageLength: UInt32
    public var messageTypeID: UInt8
    public var messageStreamID: UInt32

    public init(
        fmt: UInt8 = 0,
        chunkStreamID: UInt32,
        timestamp: UInt32 = 0,
        messageLength: UInt32,
        messageTypeID: UInt8,
        messageStreamID: UInt32 = 0
    ) {
        self.fmt = fmt & 0x03
        self.chunkStreamID = chunkStreamID
        self.timestamp = timestamp
        self.messageLength = messageLength
        self.messageTypeID = messageTypeID
        self.messageStreamID = messageStreamID
    }
}

/// Reassembled RTMP protocol message.
public struct RTMPMessage: Sendable, Equatable {
    public let chunkStreamID: UInt32
    public let timestamp: UInt32
    public let messageTypeID: UInt8
    public let messageStreamID: UInt32
    public let payload: Data

    public init(
        chunkStreamID: UInt32,
        timestamp: UInt32,
        messageTypeID: UInt8,
        messageStreamID: UInt32,
        payload: Data
    ) {
        self.chunkStreamID = chunkStreamID
        self.timestamp = timestamp
        self.messageTypeID = messageTypeID
        self.messageStreamID = messageStreamID
        self.payload = payload
    }
}

/// RTMP chunk stream serializer (`fmt 0` + `fmt 3` continuations) and stateful incremental decoder.
public enum RTMPChunkCodec {

    /// Serializes an `RTMPMessage` into RTMP chunks using `fmt 0` for the first chunk and `fmt 3` for continuations.
    public static func serialize(message: RTMPMessage, chunkSize: Int = 128) -> Data {
        let effectiveChunkSize = max(1, chunkSize)
        var out = Data()
        let payloadBytes = [UInt8](message.payload)
        let msgLen = UInt32(payloadBytes.count)
        let hasExtTS = message.timestamp >= 0x00FF_FFFF
        let headerTS: UInt32 = hasExtTS ? 0x00FF_FFFF : message.timestamp

        // Chunk 0: fmt 0 basic header + 11-byte message header
        appendBasicHeader(fmt: 0, csid: message.chunkStreamID, to: &out)
        appendUInt24BE(headerTS, to: &out)
        appendUInt24BE(msgLen, to: &out)
        out.append(message.messageTypeID)
        appendUInt32LE(message.messageStreamID, to: &out)
        if hasExtTS {
            appendUInt32BE(message.timestamp, to: &out)
        }

        if payloadBytes.isEmpty {
            return out
        }

        var offset = 0
        let firstSliceLen = min(effectiveChunkSize, payloadBytes.count)
        out.append(contentsOf: payloadBytes[0..<firstSliceLen])
        offset += firstSliceLen

        while offset < payloadBytes.count {
            appendBasicHeader(fmt: 3, csid: message.chunkStreamID, to: &out)
            if hasExtTS {
                appendUInt32BE(message.timestamp, to: &out)
            }
            let sliceLen = min(effectiveChunkSize, payloadBytes.count - offset)
            out.append(contentsOf: payloadBytes[offset..<(offset + sliceLen)])
            offset += sliceLen
        }

        return out
    }

    /// Builds a protocol control `SetChunkSize` (type 1) message serialized at the active chunk size.
    public static func serializeSetChunkSize(_ newChunkSize: UInt32, currentChunkSize: Int = 128) -> Data {
        let clamped = max(1, newChunkSize & 0x7FFF_FFFF)
        var payload = Data(capacity: 4)
        appendUInt32BE(clamped, to: &payload)
        let msg = RTMPMessage(
            chunkStreamID: 2,
            timestamp: 0,
            messageTypeID: RTMPMessageType.setChunkSize,
            messageStreamID: 0,
            payload: payload
        )
        return serialize(message: msg, chunkSize: currentChunkSize)
    }

    /// Builds a `WindowAcknowledgementSize` (type 5) protocol control message.
    public static func serializeWindowAckSize(_ windowSize: UInt32, currentChunkSize: Int = 128) -> Data {
        var payload = Data(capacity: 4)
        appendUInt32BE(windowSize, to: &payload)
        let msg = RTMPMessage(
            chunkStreamID: 2,
            timestamp: 0,
            messageTypeID: RTMPMessageType.windowAckSize,
            messageStreamID: 0,
            payload: payload
        )
        return serialize(message: msg, chunkSize: currentChunkSize)
    }

    /// Builds a `SetPeerBandwidth` (type 6) protocol control message.
    public static func serializeSetPeerBandwidth(_ bandwidth: UInt32, limitType: UInt8 = 2, currentChunkSize: Int = 128) -> Data {
        var payload = Data(capacity: 5)
        appendUInt32BE(bandwidth, to: &payload)
        payload.append(limitType)
        let msg = RTMPMessage(
            chunkStreamID: 2,
            timestamp: 0,
            messageTypeID: RTMPMessageType.setPeerBandwidth,
            messageStreamID: 0,
            payload: payload
        )
        return serialize(message: msg, chunkSize: currentChunkSize)
    }

    private static func appendBasicHeader(fmt: UInt8, csid: UInt32, to out: inout Data) {
        let fmtBits = (fmt & 0x03) << 6
        if csid >= 2 && csid <= 63 {
            out.append(fmtBits | UInt8(csid))
        } else if csid >= 64 && csid <= 319 {
            out.append(fmtBits)
            out.append(UInt8(csid - 64))
        } else {
            let adjusted = csid - 64
            out.append(fmtBits | 1)
            out.append(UInt8(adjusted & 0xFF))
            out.append(UInt8((adjusted >> 8) & 0xFF))
        }
    }

    private static func appendUInt24BE(_ v: UInt32, to out: inout Data) {
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8(v & 0xFF))
    }

    private static func appendUInt32BE(_ v: UInt32, to out: inout Data) {
        out.append(UInt8((v >> 24) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8(v & 0xFF))
    }

    private static func appendUInt32LE(_ v: UInt32, to out: inout Data) {
        out.append(UInt8(v & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 24) & 0xFF))
    }
}

/// Stateful incremental RTMP chunk stream decoder supporting `fmt 0`..`fmt 3` and dynamic `SetChunkSize`.
public struct RTMPChunkDecoder: Sendable {
    private struct StreamState: Sendable {
        var timestamp: UInt32 = 0
        var timestampDelta: UInt32 = 0
        var hasExtendedTimestamp: Bool = false
        var messageLength: UInt32 = 0
        var messageTypeID: UInt8 = 0
        var messageStreamID: UInt32 = 0
        var buffer: Data = Data()
    }

    public private(set) var chunkSize: Int = 128
    private var incoming = Data()
    private var streams: [UInt32: StreamState] = [:]

    public init(initialChunkSize: Int = 128) {
        self.chunkSize = max(1, initialChunkSize)
    }

    /// Feeds raw TCP bytes and returns all completely reassembled `RTMPMessage` values.
    public mutating func feed(_ data: Data) throws -> [RTMPMessage] {
        if !data.isEmpty {
            incoming.append(data)
        }

        var messages: [RTMPMessage] = []
        let bytes = [UInt8](incoming)
        var cursor = 0

        while cursor < bytes.count {
            let chunkStart = cursor

            // 1. Parse Basic Header
            let firstByte = bytes[cursor]
            cursor += 1
            let fmt = (firstByte >> 6) & 0x03
            let rawCsid = firstByte & 0x3F
            let csid: UInt32

            if rawCsid == 0 {
                guard cursor + 1 <= bytes.count else {
                    cursor = chunkStart
                    break
                }
                csid = UInt32(bytes[cursor]) + 64
                cursor += 1
            } else if rawCsid == 1 {
                guard cursor + 2 <= bytes.count else {
                    cursor = chunkStart
                    break
                }
                let lo = UInt32(bytes[cursor])
                let hi = UInt32(bytes[cursor + 1]) << 8
                csid = (hi | lo) + 64
                cursor += 2
            } else {
                csid = UInt32(rawCsid)
            }

            // 2. Parse Message Header
            var state = streams[csid] ?? StreamState()
            let needMoreBytes: Bool

            switch fmt {
            case 0:
                if cursor + 11 > bytes.count {
                    needMoreBytes = true
                } else {
                    needMoreBytes = false
                    let ts24 = readUInt24BE(bytes, offset: cursor)
                    let msgLen = readUInt24BE(bytes, offset: cursor + 3)
                    let typeID = bytes[cursor + 6]
                    let streamID = readUInt32LE(bytes, offset: cursor + 7)
                    cursor += 11

                    state.messageLength = msgLen
                    state.messageTypeID = typeID
                    state.messageStreamID = streamID
                    state.hasExtendedTimestamp = (ts24 == 0x00FF_FFFF)
                    if !state.hasExtendedTimestamp {
                        state.timestamp = ts24
                        state.timestampDelta = 0
                    }
                    state.buffer.removeAll(keepingCapacity: true)
                }

            case 1:
                if cursor + 7 > bytes.count {
                    needMoreBytes = true
                } else {
                    needMoreBytes = false
                    let delta24 = readUInt24BE(bytes, offset: cursor)
                    let msgLen = readUInt24BE(bytes, offset: cursor + 3)
                    let typeID = bytes[cursor + 6]
                    cursor += 7

                    state.messageLength = msgLen
                    state.messageTypeID = typeID
                    state.hasExtendedTimestamp = (delta24 == 0x00FF_FFFF)
                    if !state.hasExtendedTimestamp {
                        state.timestampDelta = delta24
                        state.timestamp = state.timestamp &+ delta24
                    }
                    state.buffer.removeAll(keepingCapacity: true)
                }

            case 2:
                if cursor + 3 > bytes.count {
                    needMoreBytes = true
                } else {
                    needMoreBytes = false
                    let delta24 = readUInt24BE(bytes, offset: cursor)
                    cursor += 3

                    state.hasExtendedTimestamp = (delta24 == 0x00FF_FFFF)
                    if !state.hasExtendedTimestamp {
                        state.timestampDelta = delta24
                        state.timestamp = state.timestamp &+ delta24
                    }
                    state.buffer.removeAll(keepingCapacity: true)
                }

            default: // fmt == 3
                needMoreBytes = false
                if state.buffer.isEmpty && !state.hasExtendedTimestamp {
                    state.timestamp = state.timestamp &+ state.timestampDelta
                }
            }

            if needMoreBytes {
                cursor = chunkStart
                break
            }

            // 3. Optional Extended Timestamp
            if state.hasExtendedTimestamp {
                guard cursor + 4 <= bytes.count else {
                    cursor = chunkStart
                    break
                }
                let extTS = readUInt32BE(bytes, offset: cursor)
                cursor += 4
                if fmt == 0 {
                    state.timestamp = extTS
                } else if fmt == 1 || fmt == 2 {
                    state.timestampDelta = extTS
                    state.timestamp = state.timestamp &+ extTS
                }
            }

            // 4. Chunk Payload Slice
            let remaining = Int(state.messageLength) - state.buffer.count
            if remaining < 0 {
                throw SafariumError.invalidState("RTMP chunk decoder state underflow for csid \(csid)")
            }
            let sliceLen = min(chunkSize, remaining)
            guard cursor + sliceLen <= bytes.count else {
                cursor = chunkStart
                break
            }

            if sliceLen > 0 {
                state.buffer.append(contentsOf: bytes[cursor..<(cursor + sliceLen)])
                cursor += sliceLen
            }

            if state.buffer.count == Int(state.messageLength) {
                let completed = RTMPMessage(
                    chunkStreamID: csid,
                    timestamp: state.timestamp,
                    messageTypeID: state.messageTypeID,
                    messageStreamID: state.messageStreamID,
                    payload: state.buffer
                )
                state.buffer.removeAll(keepingCapacity: true)
                streams[csid] = state

                // Immediately apply SetChunkSize so subsequent chunks in the same TCP read decode accurately.
                if completed.messageTypeID == RTMPMessageType.setChunkSize && completed.payload.count >= 4 {
                    let p = [UInt8](completed.payload)
                    let newSize = readUInt32BE(p, offset: 0) & 0x7FFF_FFFF
                    if newSize >= 1 {
                        chunkSize = Int(newSize)
                    }
                }
                messages.append(completed)
            } else {
                streams[csid] = state
            }
        }

        if cursor > 0 {
            if cursor >= bytes.count {
                incoming.removeAll(keepingCapacity: true)
            } else {
                incoming = Data(bytes[cursor..<bytes.count])
            }
        }

        return messages
    }

    private func readUInt24BE(_ bytes: [UInt8], offset: Int) -> UInt32 {
        let b0 = UInt32(bytes[offset]) << 16
        let b1 = UInt32(bytes[offset + 1]) << 8
        let b2 = UInt32(bytes[offset + 2])
        return b0 | b1 | b2
    }

    private func readUInt32BE(_ bytes: [UInt8], offset: Int) -> UInt32 {
        let b0 = UInt32(bytes[offset]) << 24
        let b1 = UInt32(bytes[offset + 1]) << 16
        let b2 = UInt32(bytes[offset + 2]) << 8
        let b3 = UInt32(bytes[offset + 3])
        return b0 | b1 | b2 | b3
    }

    private func readUInt32LE(_ bytes: [UInt8], offset: Int) -> UInt32 {
        let b0 = UInt32(bytes[offset])
        let b1 = UInt32(bytes[offset + 1]) << 8
        let b2 = UInt32(bytes[offset + 2]) << 16
        let b3 = UInt32(bytes[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }
}

// MARK: - FLV Video & Audio Tag Builders (AVC, Enhanced RTMP HEVC 'hvc1', AAC)

/// Pure-Swift FLV video and audio tag payload builder for RTMP 1.0 and Enhanced RTMP.
public struct FLVTagBuilder: Sendable {

    /// Builds an AVC (H.264) sequence header tag payload (`0x17 0x00 0x00 0x00 0x00` + `avcC`).
    public static func avcSequenceHeader(avcC: Data) -> Data {
        var out = Data(capacity: 5 + avcC.count)
        out.append(contentsOf: [0x17, 0x00, 0x00, 0x00, 0x00])
        out.append(avcC)
        return out
    }

    /// Builds an AVC (H.264) NALU frame tag payload (`0x17`/`0x27` + `0x01` + SI24 CTS + length-prefixed NALUs).
    public static func avcVideoFrame(
        naluPayload: Data,
        isKeyframe: Bool,
        compositionTimeMs: Int32 = 0
    ) -> Data {
        var out = Data(capacity: 5 + naluPayload.count)
        let frameHeader: UInt8 = isKeyframe ? 0x17 : 0x27
        out.append(frameHeader)
        out.append(0x01)
        appendSI24BE(compositionTimeMs, to: &out)
        out.append(naluPayload)
        return out
    }

    /// Builds an Enhanced RTMP HEVC sequence start payload (`IsExHeader=1`, `PacketType=0`, FourCC `'hvc1'` + `hvcC`).
    public static func enhancedHEVCSequenceHeader(hvcC: Data) -> Data {
        var out = Data(capacity: 5 + hvcC.count)
        // IsExHeader(1) | FrameType(1=keyframe) << 4 | PacketType(0=SequenceStart) = 0x90
        out.append(0x90)
        out.append(contentsOf: [0x68, 0x76, 0x63, 0x31]) // "hvc1"
        out.append(hvcC)
        return out
    }

    /// Builds an Enhanced RTMP HEVC coded frame payload (`IsExHeader=1`, FourCC `'hvc1'`).
    public static func enhancedHEVCVideoFrame(
        naluPayload: Data,
        isKeyframe: Bool,
        compositionTimeMs: Int32 = 0
    ) -> Data {
        let frameTypeBits: UInt8 = isKeyframe ? (1 << 4) : (2 << 4)
        if compositionTimeMs == 0 {
            // PacketType = 3 (CodedFramesX, no composition time bytes)
            var out = Data(capacity: 5 + naluPayload.count)
            out.append(0x80 | frameTypeBits | 0x03)
            out.append(contentsOf: [0x68, 0x76, 0x63, 0x31]) // "hvc1"
            out.append(naluPayload)
            return out
        } else {
            // PacketType = 1 (CodedFrames, followed by SI24 composition time)
            var out = Data(capacity: 8 + naluPayload.count)
            out.append(0x80 | frameTypeBits | 0x01)
            out.append(contentsOf: [0x68, 0x76, 0x63, 0x31]) // "hvc1"
            appendSI24BE(compositionTimeMs, to: &out)
            out.append(naluPayload)
            return out
        }
    }

    /// Builds an AAC sequence header tag payload (`0xAF 0x00` + `AudioSpecificConfig`).
    public static func aacSequenceHeader(audioSpecificConfig: Data) -> Data {
        var out = Data(capacity: 2 + audioSpecificConfig.count)
        out.append(contentsOf: [0xAF, 0x00])
        out.append(audioSpecificConfig)
        return out
    }

    /// Builds a raw AAC frame tag payload (`0xAF 0x01` + raw AAC frame bytes).
    public static func aacAudioFrame(rawFrame: Data) -> Data {
        var out = Data(capacity: 2 + rawFrame.count)
        out.append(contentsOf: [0xAF, 0x01])
        out.append(rawFrame)
        return out
    }

    private static func appendSI24BE(_ value: Int32, to out: inout Data) {
        let bits = UInt32(bitPattern: value)
        out.append(UInt8((bits >> 16) & 0xFF))
        out.append(UInt8((bits >> 8) & 0xFF))
        out.append(UInt8(bits & 0xFF))
    }
}

// MARK: - Publisher Config & Stats

/// Connection and stream configuration for `RTMPPublisher`.
public struct RTMPPublishConfig: Codable, Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var app: String
    public var streamKey: String
    public var timeoutSeconds: Double

    public init(
        host: String,
        port: UInt16 = 1935,
        app: String = "live",
        streamKey: String,
        timeoutSeconds: Double = 10.0
    ) {
        self.host = host
        self.port = port
        self.app = app
        self.streamKey = streamKey
        self.timeoutSeconds = max(0.5, timeoutSeconds)
    }
}

/// Summary statistics returned by `RTMPPublisher.close()`.
public struct RTMPPublishStats: Codable, Sendable, Equatable {
    public let handshakeCompleted: Bool
    public let publishedStreamName: String
    public let videoPacketsSent: Int
    public let audioPacketsSent: Int
    public let bytesSent: Int64
    public let elapsedMs: Double

    public init(
        handshakeCompleted: Bool,
        publishedStreamName: String,
        videoPacketsSent: Int,
        audioPacketsSent: Int,
        bytesSent: Int64,
        elapsedMs: Double
    ) {
        self.handshakeCompleted = handshakeCompleted
        self.publishedStreamName = publishedStreamName
        self.videoPacketsSent = videoPacketsSent
        self.audioPacketsSent = audioPacketsSent
        self.bytesSent = bytesSent
        self.elapsedMs = elapsedMs
    }
}

// MARK: - POSIX Socket Helpers

private enum RTMPSocketIO {
    static func connectTCP(host: String, port: UInt16, timeoutSeconds: Double) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var res: UnsafeMutablePointer<addrinfo>?
        let portStr = String(port)
        let gaiStatus = getaddrinfo(host, portStr, &hints, &res)
        guard gaiStatus == 0, let firstAddr = res else {
            let msg = String(cString: gai_strerror(gaiStatus))
            throw SafariumError.navigation("RTMP getaddrinfo(\(host):\(port)) failed: \(msg)")
        }
        defer { freeaddrinfo(firstAddr) }

        var lastErrno: Int32 = ECONNREFUSED
        var current: UnsafeMutablePointer<addrinfo>? = firstAddr

        while let info = current {
            let fd = Darwin.socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                configureSocket(fd)
                let flags = Darwin.fcntl(fd, F_GETFL, 0)
                _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK)

                let connRes = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
                if connRes == 0 {
                    _ = Darwin.fcntl(fd, F_SETFL, flags)
                    return fd
                }
                if errno == EINPROGRESS {
                    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    let timeoutMs = Int32(max(100, min(60_000, Int(timeoutSeconds * 1000.0))))
                    let pollRes = Darwin.poll(&pfd, 1, timeoutMs)
                    if pollRes > 0 {
                        var soErr: Int32 = 0
                        var soLen = socklen_t(MemoryLayout<Int32>.size)
                        _ = Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &soLen)
                        if soErr == 0 {
                            _ = Darwin.fcntl(fd, F_SETFL, flags)
                            return fd
                        }
                        lastErrno = soErr
                    } else if pollRes == 0 {
                        lastErrno = ETIMEDOUT
                    } else {
                        lastErrno = errno
                    }
                } else {
                    lastErrno = errno
                }
                Darwin.close(fd)
            } else {
                lastErrno = errno
            }
            current = info.pointee.ai_next
        }

        throw SafariumError.navigation("RTMP connect(\(host):\(port)) failed: \(String(cString: strerror(lastErrno)))")
    }

    static func configureSocket(_ fd: Int32) {
        var one: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = Darwin.setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    @discardableResult
    static func writeAll(fd: Int32, data: Data, timeoutSeconds: Double) throws -> Int {
        let bytes = [UInt8](data)
        let total = bytes.count
        var written = 0
        let deadlineNanos = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds * 1_000_000_000.0)

        while written < total {
            let nowNanos = DispatchTime.now().uptimeNanoseconds
            if nowNanos >= deadlineNanos {
                throw SafariumError.timeout("RTMP socket write timed out")
            }
            let remMs = Int32(max(1, min(5_000, Int((deadlineNanos - nowNanos) / 1_000_000))))
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pr = Darwin.poll(&pfd, 1, remMs)
            if pr == 0 {
                continue
            }
            if pr < 0 {
                if errno == EINTR { continue }
                throw SafariumError.navigation("RTMP poll(POLLOUT) error: \(String(cString: strerror(errno)))")
            }

            let n: Int = bytes.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return -1 }
                return Darwin.send(fd, base.advanced(by: written), total - written, 0)
            }
            if n > 0 {
                written += n
            } else if n < 0 && (errno == EINTR || errno == EAGAIN) {
                continue
            } else {
                throw SafariumError.navigation("RTMP send failed: \(String(cString: strerror(errno)))")
            }
        }
        return written
    }

    static func readExact(fd: Int32, count: Int, timeoutSeconds: Double) throws -> Data {
        var result = [UInt8](repeating: 0, count: count)
        var received = 0
        let deadlineNanos = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds * 1_000_000_000.0)

        while received < count {
            let nowNanos = DispatchTime.now().uptimeNanoseconds
            if nowNanos >= deadlineNanos {
                throw SafariumError.timeout("RTMP socket readExact(\(count)) timed out at \(received) bytes")
            }
            let remMs = Int32(max(1, min(5_000, Int((deadlineNanos - nowNanos) / 1_000_000))))
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = Darwin.poll(&pfd, 1, remMs)
            if pr == 0 {
                continue
            }
            if pr < 0 {
                if errno == EINTR { continue }
                throw SafariumError.navigation("RTMP poll(POLLIN) error: \(String(cString: strerror(errno)))")
            }

            let n: Int = result.withUnsafeMutableBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return -1 }
                return Darwin.recv(fd, base.advanced(by: received), count - received, 0)
            }
            if n > 0 {
                received += n
            } else if n == 0 {
                throw SafariumError.navigation("RTMP peer closed connection during readExact")
            } else if errno == EINTR || errno == EAGAIN {
                continue
            } else {
                throw SafariumError.navigation("RTMP recv failed: \(String(cString: strerror(errno)))")
            }
        }

        return Data(result)
    }

    static func readAvailable(fd: Int32, maxBytes: Int, timeoutSeconds: Double) throws -> Data {
        let deadlineNanos = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutSeconds * 1_000_000_000.0)
        var buf = [UInt8](repeating: 0, count: max(1, maxBytes))

        while true {
            let nowNanos = DispatchTime.now().uptimeNanoseconds
            if nowNanos >= deadlineNanos {
                throw SafariumError.timeout("RTMP socket readAvailable timed out")
            }
            let remMs = Int32(max(1, min(5_000, Int((deadlineNanos - nowNanos) / 1_000_000))))
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = Darwin.poll(&pfd, 1, remMs)
            if pr == 0 {
                continue
            }
            if pr < 0 {
                if errno == EINTR { continue }
                throw SafariumError.navigation("RTMP poll(POLLIN) error: \(String(cString: strerror(errno)))")
            }

            let n: Int = buf.withUnsafeMutableBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return -1 }
                return Darwin.recv(fd, base, rawBuf.count, 0)
            }
            if n > 0 {
                return Data(buf[0..<n])
            } else if n == 0 {
                return Data()
            } else if errno == EINTR || errno == EAGAIN {
                continue
            } else {
                throw SafariumError.navigation("RTMP recv failed: \(String(cString: strerror(errno)))")
            }
        }
    }
}

// MARK: - Pure-Swift RTMP 1.0 + Enhanced RTMP Publisher

/// Pure-Swift RTMP 1.0 + Enhanced RTMP client publisher over POSIX TCP sockets.
public final class RTMPPublisher: @unchecked Sendable {
    public let config: RTMPPublishConfig

    private let lock = NSLock()
    private var fd: Int32 = -1
    private var outgoingChunkSize: Int = 128
    private var decoder = RTMPChunkDecoder(initialChunkSize: 128)
    private var pendingMessages: [RTMPMessage] = []

    private var startUptimeNanos: UInt64 = 0
    private var handshakeDone = false
    private var publishedStreamID: UInt32 = 1
    private var videoPacketsCount = 0
    private var audioPacketsCount = 0
    private var totalBytesSent: Int64 = 0

    public init(config: RTMPPublishConfig) {
        self.config = config
    }

    deinit {
        _ = close()
    }

    /// Connects to the RTMP server, completes the C0/C1/C2 <-> S0/S1/S2 handshake, negotiates chunk size,
    /// and executes AMF0 `connect`, `createStream`, and `publish` until `NetStream.Publish.Start`.
    public func connect() throws {
        lock.lock()
        defer { lock.unlock() }

        guard fd < 0 else {
            throw SafariumError.invalidState("RTMPPublisher is already connected")
        }

        startUptimeNanos = DispatchTime.now().uptimeNanoseconds
        let sock = try RTMPSocketIO.connectTCP(
            host: config.host,
            port: config.port,
            timeoutSeconds: config.timeoutSeconds
        )
        fd = sock

        do {
            // 1. RTMP 1.0 Handshake: C0 (1 byte) + C1 (1536 bytes)
            var c0c1 = [UInt8](repeating: 0, count: 1 + 1536)
            c0c1[0] = 0x03
            for i in 9..<c0c1.count {
                c0c1[i] = UInt8.random(in: 0...255)
            }
            try sendRaw(Data(c0c1))

            // Read S0 (1) + S1 (1536) + S2 (1536)
            let s0 = try RTMPSocketIO.readExact(fd: sock, count: 1, timeoutSeconds: config.timeoutSeconds)
            guard s0.first == 0x03 else {
                throw SafariumError.navigation("RTMP unsupported server protocol version: \(s0.first ?? 0)")
            }
            let s1 = try RTMPSocketIO.readExact(fd: sock, count: 1536, timeoutSeconds: config.timeoutSeconds)
            _ = try RTMPSocketIO.readExact(fd: sock, count: 1536, timeoutSeconds: config.timeoutSeconds)

            // Echo S1 as C2 (1536 bytes)
            try sendRaw(s1)
            handshakeDone = true

            // 2. Increase outgoing chunk size to 4096 bytes
            let newChunkSize: UInt32 = 4096
            let setChunkPacket = RTMPChunkCodec.serializeSetChunkSize(newChunkSize, currentChunkSize: outgoingChunkSize)
            try sendRaw(setChunkPacket)
            outgoingChunkSize = Int(newChunkSize)

            // 3. AMF0 `connect` (transaction ID = 1)
            let tcURL = "rtmp://\(config.host):\(config.port)/\(config.app)"
            let connectObj = AMF0Value.object([
                ("app", .string(config.app)),
                ("type", .string("nonprivate")),
                ("flashVer", .string("FMLE/3.0 (compatible; Safarium/1.0)")),
                ("tcUrl", .string(tcURL)),
                ("fpad", .boolean(false)),
                ("audioCodecs", .number(0x0400)),
                ("videoCodecs", .number(0x0080)),
            ])
            try sendAMF0Command(
                csid: 3,
                streamID: 0,
                values: [.string("connect"), .number(1.0), connectObj]
            )
            _ = try waitForCommandResult(transactionID: 1.0)

            // 4. AMF0 `createStream` (transaction ID = 2)
            try sendAMF0Command(
                csid: 3,
                streamID: 0,
                values: [.string("createStream"), .number(2.0), .null]
            )
            let createValues = try waitForCommandResult(transactionID: 2.0)
            if createValues.count >= 4, let assignedID = createValues[3].numberValue, assignedID >= 1.0 {
                publishedStreamID = UInt32(assignedID)
            } else {
                publishedStreamID = 1
            }

            // 5. AMF0 `publish` (transaction ID = 3, streamID = publishedStreamID)
            try sendAMF0Command(
                csid: 8,
                streamID: publishedStreamID,
                values: [.string("publish"), .number(3.0), .null, .string(config.streamKey), .string("live")]
            )
            try waitForPublishStart()
        } catch {
            Darwin.shutdown(sock, SHUT_RDWR)
            Darwin.close(sock)
            fd = -1
            throw error
        }
    }

    /// Sends a video decoder configuration sequence header (AVC `avcC` or Enhanced RTMP HEVC `hvcC`).
    public func sendVideoSequenceHeader(
        _ configRecord: Data,
        enhancedHEVC: Bool = false,
        timestampMs: UInt32 = 0
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireConnected()

        let flvPayload = enhancedHEVC
            ? FLVTagBuilder.enhancedHEVCSequenceHeader(hvcC: configRecord)
            : FLVTagBuilder.avcSequenceHeader(avcC: configRecord)
        let msg = RTMPMessage(
            chunkStreamID: 6,
            timestamp: timestampMs,
            messageTypeID: RTMPMessageType.video,
            messageStreamID: publishedStreamID,
            payload: flvPayload
        )
        let wire = RTMPChunkCodec.serialize(message: msg, chunkSize: outgoingChunkSize)
        try sendRaw(wire)
        videoPacketsCount += 1
    }

    /// Sends a video frame NALU payload (AVC or Enhanced RTMP HEVC `'hvc1'`).
    public func sendVideoFrame(
        _ naluPayload: Data,
        isKeyframe: Bool,
        timestampMs: UInt32,
        compositionTimeMs: Int32 = 0,
        enhancedHEVC: Bool = false
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireConnected()

        let flvPayload = enhancedHEVC
            ? FLVTagBuilder.enhancedHEVCVideoFrame(
                naluPayload: naluPayload,
                isKeyframe: isKeyframe,
                compositionTimeMs: compositionTimeMs
            )
            : FLVTagBuilder.avcVideoFrame(
                naluPayload: naluPayload,
                isKeyframe: isKeyframe,
                compositionTimeMs: compositionTimeMs
            )
        let msg = RTMPMessage(
            chunkStreamID: 6,
            timestamp: timestampMs,
            messageTypeID: RTMPMessageType.video,
            messageStreamID: publishedStreamID,
            payload: flvPayload
        )
        let wire = RTMPChunkCodec.serialize(message: msg, chunkSize: outgoingChunkSize)
        try sendRaw(wire)
        videoPacketsCount += 1
    }

    /// Sends an AAC `AudioSpecificConfig` sequence header (`0xAF 0x00`).
    public func sendAudioSequenceHeader(
        _ audioSpecificConfig: Data,
        timestampMs: UInt32 = 0
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireConnected()

        let flvPayload = FLVTagBuilder.aacSequenceHeader(audioSpecificConfig: audioSpecificConfig)
        let msg = RTMPMessage(
            chunkStreamID: 4,
            timestamp: timestampMs,
            messageTypeID: RTMPMessageType.audio,
            messageStreamID: publishedStreamID,
            payload: flvPayload
        )
        let wire = RTMPChunkCodec.serialize(message: msg, chunkSize: outgoingChunkSize)
        try sendRaw(wire)
        audioPacketsCount += 1
    }

    /// Sends a raw AAC audio frame (`0xAF 0x01`).
    public func sendAudioFrame(
        _ rawFrame: Data,
        timestampMs: UInt32
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try requireConnected()

        let flvPayload = FLVTagBuilder.aacAudioFrame(rawFrame: rawFrame)
        let msg = RTMPMessage(
            chunkStreamID: 4,
            timestamp: timestampMs,
            messageTypeID: RTMPMessageType.audio,
            messageStreamID: publishedStreamID,
            payload: flvPayload
        )
        let wire = RTMPChunkCodec.serialize(message: msg, chunkSize: outgoingChunkSize)
        try sendRaw(wire)
        audioPacketsCount += 1
    }

    /// Gracefully unpublishes and closes the TCP connection, returning `RTMPPublishStats`.
    @discardableResult
    public func close() -> RTMPPublishStats {
        lock.lock()
        defer { lock.unlock() }

        if fd >= 0 {
            // Best-effort deleteStream before tearing down TCP
            _ = try? sendAMF0Command(
                csid: 3,
                streamID: 0,
                values: [.string("deleteStream"), .number(0.0), .null, .number(Double(publishedStreamID))]
            )
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }

        let endNanos = DispatchTime.now().uptimeNanoseconds
        let elapsedNanos = (startUptimeNanos > 0 && endNanos >= startUptimeNanos) ? (endNanos - startUptimeNanos) : 0
        let rawMs = Double(elapsedNanos) / 1_000_000.0
        let elapsedMs = (rawMs * 100.0).rounded() / 100.0

        return RTMPPublishStats(
            handshakeCompleted: handshakeDone,
            publishedStreamName: config.streamKey,
            videoPacketsSent: videoPacketsCount,
            audioPacketsSent: audioPacketsCount,
            bytesSent: totalBytesSent,
            elapsedMs: elapsedMs
        )
    }

    // MARK: - Private Command Helpers

    private func requireConnected() throws {
        guard fd >= 0 && handshakeDone else {
            throw SafariumError.invalidState("RTMPPublisher is not connected")
        }
    }

    private func sendRaw(_ data: Data) throws {
        guard fd >= 0 else {
            throw SafariumError.invalidState("RTMPPublisher socket closed")
        }
        let sent = try RTMPSocketIO.writeAll(fd: fd, data: data, timeoutSeconds: config.timeoutSeconds)
        totalBytesSent += Int64(sent)
    }

    private func sendAMF0Command(csid: UInt32, streamID: UInt32, values: [AMF0Value]) throws {
        let payload = AMF0Codec.encodeSequence(values)
        let msg = RTMPMessage(
            chunkStreamID: csid,
            timestamp: 0,
            messageTypeID: RTMPMessageType.amf0Command,
            messageStreamID: streamID,
            payload: payload
        )
        let wire = RTMPChunkCodec.serialize(message: msg, chunkSize: outgoingChunkSize)
        try sendRaw(wire)
    }

    private func readNextMessage() throws -> RTMPMessage {
        if !pendingMessages.isEmpty {
            return pendingMessages.removeFirst()
        }
        guard fd >= 0 else {
            throw SafariumError.invalidState("RTMPPublisher socket closed")
        }
        while pendingMessages.isEmpty {
            let chunk = try RTMPSocketIO.readAvailable(fd: fd, maxBytes: 8192, timeoutSeconds: config.timeoutSeconds)
            if chunk.isEmpty {
                throw SafariumError.navigation("RTMP peer closed connection unexpectedly")
            }
            let decoded = try decoder.feed(chunk)
            pendingMessages.append(contentsOf: decoded)
        }
        return pendingMessages.removeFirst()
    }

    private func waitForCommandResult(transactionID: Double) throws -> [AMF0Value] {
        for _ in 0..<64 {
            let msg = try readNextMessage()
            guard msg.messageTypeID == RTMPMessageType.amf0Command else { continue }
            let values = try AMF0Codec.decode(msg.payload)
            guard let cmdName = values.first?.stringValue else { continue }
            let txn = values.count > 1 ? (values[1].numberValue ?? -1.0) : -1.0
            if cmdName == "_result" && abs(txn - transactionID) < 0.001 {
                return values
            }
            if cmdName == "_error" && abs(txn - transactionID) < 0.001 {
                throw SafariumError.navigation("RTMP server returned _error for transaction \(transactionID)")
            }
        }
        throw SafariumError.timeout("RTMP timed out waiting for _result(\(transactionID))")
    }

    private func waitForPublishStart() throws {
        for _ in 0..<64 {
            let msg = try readNextMessage()
            guard msg.messageTypeID == RTMPMessageType.amf0Command else { continue }
            let values = try AMF0Codec.decode(msg.payload)
            guard let cmdName = values.first?.stringValue else { continue }
            if cmdName == "onStatus", values.count >= 4 {
                let info = values[3]
                if let code = info["code"]?.stringValue {
                    if code == "NetStream.Publish.Start" {
                        return
                    }
                    if code.contains("Failed") || code.contains("Rejected") || code.contains("BadName") {
                        throw SafariumError.navigation("RTMP publish rejected: \(code)")
                    }
                }
            }
        }
        throw SafariumError.timeout("RTMP timed out waiting for NetStream.Publish.Start")
    }
}

// MARK: - Deterministic Loopback RTMP Test Server (127.0.0.1:0)

/// Lightweight pure-Swift POSIX loopback RTMP 1.0 server bound to `127.0.0.1:0`
/// for deterministic end-to-end handshake, AMF0 command, and FLV packet verification in CI.
public final class LoopbackRTMPTestServer: @unchecked Sendable {

    /// Single media packet (video or audio FLV tag) captured by the loopback server.
    public struct CapturedMediaPacket: Sendable, Equatable {
        public let messageTypeID: UInt8
        public let timestamp: UInt32
        public let streamID: UInt32
        public let payload: Data

        public init(messageTypeID: UInt8, timestamp: UInt32, streamID: UInt32, payload: Data) {
            self.messageTypeID = messageTypeID
            self.timestamp = timestamp
            self.streamID = streamID
            self.payload = payload
        }
    }

    /// Thread-safe snapshot of everything received by `LoopbackRTMPTestServer`.
    public struct ServerSnapshot: Sendable, Equatable {
        public let handshakeCompleted: Bool
        public let connectedApp: String?
        public let publishedStreamKey: String?
        public let videoPackets: [CapturedMediaPacket]
        public let audioPackets: [CapturedMediaPacket]
        public let totalBytesReceived: Int64
        public let sessionEnded: Bool
    }

    public private(set) var port: UInt16 = 0

    private let lock = NSLock()
    private let sessionDoneSem = DispatchSemaphore(value: 0)
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var running = false

    private var handshakeCompleted = false
    private var connectedApp: String?
    private var publishedStreamKey: String?
    private var videoPackets: [CapturedMediaPacket] = []
    private var audioPackets: [CapturedMediaPacket] = []
    private var totalBytesReceived: Int64 = 0
    private var sessionEnded = false

    public init() {}

    deinit {
        stop()
    }

    /// Starts listening on `127.0.0.1:0` and spawns the background RTMP accept/serve handler.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        let sock = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard sock >= 0 else {
            throw SafariumError.navigation("LoopbackRTMPTestServer socket() failed: \(String(cString: strerror(errno)))")
        }

        var one: Int32 = 1
        _ = Darwin.setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = Darwin.setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindRes: Int32 = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.bind(sock, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            let err = errno
            Darwin.close(sock)
            throw SafariumError.navigation("LoopbackRTMPTestServer bind() failed: \(String(cString: strerror(err)))")
        }

        guard Darwin.listen(sock, 4) == 0 else {
            let err = errno
            Darwin.close(sock)
            throw SafariumError.navigation("LoopbackRTMPTestServer listen() failed: \(String(cString: strerror(err)))")
        }

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRes: Int32 = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.getsockname(sock, saPtr, &boundLen)
            }
        }
        guard nameRes == 0 else {
            let err = errno
            Darwin.close(sock)
            throw SafariumError.navigation("LoopbackRTMPTestServer getsockname() failed: \(String(cString: strerror(err)))")
        }

        self.port = UInt16(bigEndian: boundAddr.sin_port)
        self.listenFD = sock
        self.running = true

        let queue = DispatchQueue(label: "com.safarium.rtmp.loopback.server", qos: .userInitiated)
        queue.async { [weak self] in
            self?.serveLoop(listenSocket: sock)
        }
    }

    /// Waits up to `timeoutSeconds` for the active publisher session to drain and close cleanly.
    @discardableResult
    public func waitForSessionEnd(timeoutSeconds: Double = 3.0) -> Bool {
        let alreadyEnded: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return sessionEnded
        }()
        if alreadyEnded { return true }
        let res = sessionDoneSem.wait(timeout: .now() + timeoutSeconds)
        return res == .success
    }

    /// Stops the listener and closes any active client connection.
    public func stop() {
        lock.lock()
        let lfd = listenFD
        let cfd = clientFD
        listenFD = -1
        clientFD = -1
        running = false
        lock.unlock()

        if cfd >= 0 {
            Darwin.shutdown(cfd, SHUT_RDWR)
            Darwin.close(cfd)
        }
        if lfd >= 0 {
            Darwin.shutdown(lfd, SHUT_RDWR)
            Darwin.close(lfd)
        }
    }

    /// Returns a snapshot of captured handshake state, AMF0 metadata, and FLV video/audio packets.
    public func snapshot() -> ServerSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ServerSnapshot(
            handshakeCompleted: handshakeCompleted,
            connectedApp: connectedApp,
            publishedStreamKey: publishedStreamKey,
            videoPackets: videoPackets,
            audioPackets: audioPackets,
            totalBytesReceived: totalBytesReceived,
            sessionEnded: sessionEnded
        )
    }

    // MARK: - Background Serve Loop

    private func serveLoop(listenSocket: Int32) {
        defer {
            lock.lock()
            sessionEnded = true
            lock.unlock()
            sessionDoneSem.signal()
        }

        var clientAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let cfd: Int32 = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.accept(listenSocket, saPtr, &addrLen)
            }
        }
        guard cfd >= 0 else { return }

        RTMPSocketIO.configureSocket(cfd)
        lock.lock()
        clientFD = cfd
        lock.unlock()

        defer {
            Darwin.shutdown(cfd, SHUT_RDWR)
            Darwin.close(cfd)
            lock.lock()
            if clientFD == cfd { clientFD = -1 }
            lock.unlock()
        }

        do {
            // 1. Server-side RTMP 1.0 handshake: read C0 (1) + C1 (1536)
            let c0 = try RTMPSocketIO.readExact(fd: cfd, count: 1, timeoutSeconds: 5.0)
            guard c0.first == 0x03 else { return }
            let c1 = try RTMPSocketIO.readExact(fd: cfd, count: 1536, timeoutSeconds: 5.0)
            recordBytes(1537)

            // Send S0 (0x03) + S1 (1536) + S2 (echo C1)
            var s0s1s2 = Data(capacity: 1 + 1536 + 1536)
            s0s1s2.append(0x03)
            var s1 = [UInt8](repeating: 0, count: 1536)
            for i in 8..<1536 { s1[i] = UInt8((i * 31) & 0xFF) }
            s0s1s2.append(contentsOf: s1)
            s0s1s2.append(c1)
            try RTMPSocketIO.writeAll(fd: cfd, data: s0s1s2, timeoutSeconds: 5.0)

            // Read C2 (1536)
            _ = try RTMPSocketIO.readExact(fd: cfd, count: 1536, timeoutSeconds: 5.0)
            recordBytes(1536)

            lock.lock()
            handshakeCompleted = true
            lock.unlock()

            // 2. Chunk stream message loop
            var decoder = RTMPChunkDecoder(initialChunkSize: 128)
            var outgoingChunkSize = 128

            while true {
                let raw = try RTMPSocketIO.readAvailable(fd: cfd, maxBytes: 16384, timeoutSeconds: 5.0)
                if raw.isEmpty { break }
                recordBytes(raw.count)

                let messages = try decoder.feed(raw)
                var shouldBreak = false

                for msg in messages {
                    switch msg.messageTypeID {
                    case RTMPMessageType.amf0Command:
                        let values = try AMF0Codec.decode(msg.payload)
                        guard let cmdName = values.first?.stringValue else { continue }
                        let txnID = values.count > 1 ? (values[1].numberValue ?? 0.0) : 0.0

                        if cmdName == "connect" {
                            if values.count >= 3, let appName = values[2]["app"]?.stringValue {
                                lock.lock()
                                connectedApp = appName
                                lock.unlock()
                            }
                            let winAck = RTMPChunkCodec.serializeWindowAckSize(2_500_000, currentChunkSize: outgoingChunkSize)
                            let peerBW = RTMPChunkCodec.serializeSetPeerBandwidth(2_500_000, limitType: 2, currentChunkSize: outgoingChunkSize)
                            let setCS = RTMPChunkCodec.serializeSetChunkSize(4096, currentChunkSize: outgoingChunkSize)
                            try RTMPSocketIO.writeAll(fd: cfd, data: winAck, timeoutSeconds: 5.0)
                            try RTMPSocketIO.writeAll(fd: cfd, data: peerBW, timeoutSeconds: 5.0)
                            try RTMPSocketIO.writeAll(fd: cfd, data: setCS, timeoutSeconds: 5.0)
                            outgoingChunkSize = 4096

                            let resultPayload = AMF0Codec.encodeSequence([
                                .string("_result"),
                                .number(txnID),
                                .object([("fmsVer", .string("FMS/3,0,1,123")), ("capabilities", .number(31.0))]),
                                .object([
                                    ("level", .string("status")),
                                    ("code", .string("NetConnection.Connect.Success")),
                                    ("description", .string("Connection succeeded.")),
                                ]),
                            ])
                            let reply = RTMPMessage(
                                chunkStreamID: 3,
                                timestamp: 0,
                                messageTypeID: RTMPMessageType.amf0Command,
                                messageStreamID: 0,
                                payload: resultPayload
                            )
                            let wire = RTMPChunkCodec.serialize(message: reply, chunkSize: outgoingChunkSize)
                            try RTMPSocketIO.writeAll(fd: cfd, data: wire, timeoutSeconds: 5.0)

                        } else if cmdName == "createStream" {
                            let resultPayload = AMF0Codec.encodeSequence([
                                .string("_result"),
                                .number(txnID),
                                .null,
                                .number(1.0),
                            ])
                            let reply = RTMPMessage(
                                chunkStreamID: 3,
                                timestamp: 0,
                                messageTypeID: RTMPMessageType.amf0Command,
                                messageStreamID: 0,
                                payload: resultPayload
                            )
                            let wire = RTMPChunkCodec.serialize(message: reply, chunkSize: outgoingChunkSize)
                            try RTMPSocketIO.writeAll(fd: cfd, data: wire, timeoutSeconds: 5.0)

                        } else if cmdName == "publish" {
                            if values.count >= 4, let key = values[3].stringValue {
                                lock.lock()
                                publishedStreamKey = key
                                lock.unlock()
                            }
                            let statusPayload = AMF0Codec.encodeSequence([
                                .string("onStatus"),
                                .number(0.0),
                                .null,
                                .object([
                                    ("level", .string("status")),
                                    ("code", .string("NetStream.Publish.Start")),
                                    ("description", .string("Start publishing")),
                                ]),
                            ])
                            let reply = RTMPMessage(
                                chunkStreamID: 5,
                                timestamp: 0,
                                messageTypeID: RTMPMessageType.amf0Command,
                                messageStreamID: msg.messageStreamID,
                                payload: statusPayload
                            )
                            let wire = RTMPChunkCodec.serialize(message: reply, chunkSize: outgoingChunkSize)
                            try RTMPSocketIO.writeAll(fd: cfd, data: wire, timeoutSeconds: 5.0)

                        } else if cmdName == "deleteStream" || cmdName == "FCUnpublish" {
                            shouldBreak = true
                        }

                    case RTMPMessageType.video:
                        let pkt = CapturedMediaPacket(
                            messageTypeID: msg.messageTypeID,
                            timestamp: msg.timestamp,
                            streamID: msg.messageStreamID,
                            payload: msg.payload
                        )
                        lock.lock()
                        videoPackets.append(pkt)
                        lock.unlock()

                    case RTMPMessageType.audio:
                        let pkt = CapturedMediaPacket(
                            messageTypeID: msg.messageTypeID,
                            timestamp: msg.timestamp,
                            streamID: msg.messageStreamID,
                            payload: msg.payload
                        )
                        lock.lock()
                        audioPackets.append(pkt)
                        lock.unlock()

                    default:
                        break
                    }
                }
                if shouldBreak { break }
            }
        } catch {
            // Normal teardown or peer disconnect ends loopback session cleanly.
        }
    }

    private func recordBytes(_ count: Int) {
        lock.lock()
        totalBytesReceived += Int64(count)
        lock.unlock()
    }
}
