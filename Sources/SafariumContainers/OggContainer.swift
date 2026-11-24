import Foundation
import SafariumCore

// MARK: - RFC 3533 CRC-32

/// Ogg page checksum (RFC 3533): polynomial 0x04C11DB7, MSB-first, initial value 0,
/// no reflection and no final XOR. Computed over the whole page with the CRC field zeroed.
public enum OggCRC32 {
    public static let polynomial: UInt32 = 0x04C1_1DB7

    static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var r = UInt32(i) << 24
        for _ in 0..<8 {
            r = (r & 0x8000_0000) != 0 ? (r << 1) ^ polynomial : (r << 1)
        }
        return r
    }

    @inline(__always)
    public static func update(_ crc: UInt32, _ bytes: UnsafeRawBufferPointer) -> UInt32 {
        var c = crc
        table.withUnsafeBufferPointer { t in
            for b in bytes {
                c = (c << 8) ^ t[Int(((c >> 24) ^ UInt32(b)) & 0xFF)]
            }
        }
        return c
    }

    public static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { update(0, $0) }
    }

    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBytes { update(0, $0) }
    }

    /// CRC of a serialized page (header + body) with bytes 22..<26 treated as zero.
    public static func pageChecksum(_ page: UnsafeRawBufferPointer) -> UInt32 {
        precondition(page.count >= 26)
        var c = update(0, UnsafeRawBufferPointer(rebasing: page[0..<22]))
        let zeros: [UInt8] = [0, 0, 0, 0]
        c = zeros.withUnsafeBytes { update(c, $0) }
        return update(c, UnsafeRawBufferPointer(rebasing: page[26..<page.count]))
    }
}

// MARK: - Page

public struct OggPage: Sendable, Equatable {
    public static let capturePattern: [UInt8] = [0x4F, 0x67, 0x67, 0x53] // "OggS"
    public static let fixedHeaderSize = 27
    public static let maxPageSize = 27 + 255 + 255 * 255

    public static let flagContinued: UInt8 = 0x01
    public static let flagBOS: UInt8 = 0x02
    public static let flagEOS: UInt8 = 0x04

    public let version: UInt8
    public let headerType: UInt8
    public let granulePosition: Int64
    public let serialNumber: UInt32
    public let pageSequence: UInt32
    public let checksum: UInt32
    public let segmentTable: [UInt8]
    public let body: Data

    public var isContinued: Bool { (headerType & Self.flagContinued) != 0 }
    public var isBeginningOfStream: Bool { (headerType & Self.flagBOS) != 0 }
    public var isEndOfStream: Bool { (headerType & Self.flagEOS) != 0 }
    public var headerSize: Int { Self.fixedHeaderSize + segmentTable.count }
    public var totalSize: Int { headerSize + body.count }

    /// Builds a page; `checksum` is computed on serialization.
    public init(
        headerType: UInt8,
        granulePosition: Int64,
        serialNumber: UInt32,
        pageSequence: UInt32,
        segmentTable: [UInt8],
        body: Data
    ) throws {
        guard segmentTable.count <= 255 else {
            throw SafariumError.encode("Ogg page segment count \(segmentTable.count) exceeds 255")
        }
        let sum = segmentTable.reduce(0) { $0 + Int($1) }
        guard sum == body.count else {
            throw SafariumError.encode("Ogg page lacing sum \(sum) != body size \(body.count)")
        }
        guard (headerType & ~0x07) == 0 else {
            throw SafariumError.encode("Ogg page header_type 0x\(String(headerType, radix: 16)) has reserved bits set")
        }
        self.version = 0
        self.headerType = headerType
        self.granulePosition = granulePosition
        self.serialNumber = serialNumber
        self.pageSequence = pageSequence
        self.segmentTable = segmentTable
        self.body = body
        self.checksum = Self.computeChecksum(
            headerType: headerType,
            granulePosition: granulePosition,
            serialNumber: serialNumber,
            pageSequence: pageSequence,
            segmentTable: segmentTable,
            body: body
        )
    }

    private init(
        version: UInt8,
        headerType: UInt8,
        granulePosition: Int64,
        serialNumber: UInt32,
        pageSequence: UInt32,
        checksum: UInt32,
        segmentTable: [UInt8],
        body: Data
    ) {
        self.version = version
        self.headerType = headerType
        self.granulePosition = granulePosition
        self.serialNumber = serialNumber
        self.pageSequence = pageSequence
        self.checksum = checksum
        self.segmentTable = segmentTable
        self.body = body
    }

    private static func headerBytes(
        headerType: UInt8,
        granulePosition: Int64,
        serialNumber: UInt32,
        pageSequence: UInt32,
        checksum: UInt32,
        segmentTable: [UInt8]
    ) -> [UInt8] {
        var h = [UInt8]()
        h.reserveCapacity(27 + segmentTable.count)
        h.append(contentsOf: capturePattern)
        h.append(0)
        h.append(headerType)
        let g = UInt64(bitPattern: granulePosition)
        for i in 0..<8 { h.append(UInt8(truncatingIfNeeded: g >> (8 * UInt64(i)))) }
        for i in 0..<4 { h.append(UInt8(truncatingIfNeeded: serialNumber >> (8 * UInt32(i)))) }
        for i in 0..<4 { h.append(UInt8(truncatingIfNeeded: pageSequence >> (8 * UInt32(i)))) }
        for i in 0..<4 { h.append(UInt8(truncatingIfNeeded: checksum >> (8 * UInt32(i)))) }
        h.append(UInt8(segmentTable.count))
        h.append(contentsOf: segmentTable)
        return h
    }

    private static func computeChecksum(
        headerType: UInt8,
        granulePosition: Int64,
        serialNumber: UInt32,
        pageSequence: UInt32,
        segmentTable: [UInt8],
        body: Data
    ) -> UInt32 {
        let h = headerBytes(
            headerType: headerType,
            granulePosition: granulePosition,
            serialNumber: serialNumber,
            pageSequence: pageSequence,
            checksum: 0,
            segmentTable: segmentTable
        )
        let c = h.withUnsafeBytes { OggCRC32.update(0, $0) }
        return body.withUnsafeBytes { OggCRC32.update(c, $0) }
    }

    public func serialized() -> Data {
        var d = Data(Self.headerBytes(
            headerType: headerType,
            granulePosition: granulePosition,
            serialNumber: serialNumber,
            pageSequence: pageSequence,
            checksum: checksum,
            segmentTable: segmentTable
        ))
        d.append(body)
        return d
    }

    /// Body fragments in lacing order: each fragment's byte range and whether it terminates a packet.
    public func fragments() -> [(range: Range<Int>, terminatesPacket: Bool)] {
        var out: [(Range<Int>, Bool)] = []
        var pos = 0
        var start = 0
        for (i, lace) in segmentTable.enumerated() {
            pos += Int(lace)
            if lace < 255 {
                out.append((start..<pos, true))
                start = pos
            } else if i == segmentTable.count - 1 {
                out.append((start..<pos, false))
                start = pos
            }
        }
        return out
    }

    /// Parses one page from raw bytes. Returns `nil` when more bytes are needed (caller decides whether
    /// that is truncation). Throws on bad capture pattern, version, reserved flags or CRC mismatch.
    public static func parse(
        bytes: UnsafeRawBufferPointer,
        verifyCRC: Bool = true,
        offsetForErrors: Int64 = 0
    ) throws -> (page: OggPage, size: Int)? {
        guard bytes.count >= fixedHeaderSize else { return nil }
        guard bytes[0] == 0x4F, bytes[1] == 0x67, bytes[2] == 0x67, bytes[3] == 0x53 else {
            throw SafariumError.encode("Ogg: missing 'OggS' capture pattern at byte offset \(offsetForErrors)")
        }
        guard bytes[4] == 0 else {
            throw SafariumError.encode("Ogg: unsupported stream_structure_version \(bytes[4]) at byte offset \(offsetForErrors)")
        }
        let headerType = bytes[5]
        guard (headerType & ~0x07) == 0 else {
            throw SafariumError.encode("Ogg: reserved header_type bits set (0x\(String(headerType, radix: 16))) at byte offset \(offsetForErrors)")
        }
        func le64(_ o: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v |= UInt64(bytes[o + i]) << (8 * UInt64(i)) }
            return v
        }
        func le32(_ o: Int) -> UInt32 {
            var v: UInt32 = 0
            for i in 0..<4 { v |= UInt32(bytes[o + i]) << (8 * UInt32(i)) }
            return v
        }
        let granule = Int64(bitPattern: le64(6))
        let serial = le32(14)
        let seq = le32(18)
        let crc = le32(22)
        let nseg = Int(bytes[26])
        let headerSize = fixedHeaderSize + nseg
        guard bytes.count >= headerSize else { return nil }
        var bodySize = 0
        var table = [UInt8](repeating: 0, count: nseg)
        for i in 0..<nseg {
            let lace = bytes[fixedHeaderSize + i]
            table[i] = lace
            bodySize += Int(lace)
        }
        let total = headerSize + bodySize
        guard total <= maxPageSize else {
            throw SafariumError.encode("Ogg: page size \(total) exceeds RFC 3533 maximum at byte offset \(offsetForErrors)")
        }
        guard bytes.count >= total else { return nil }
        let pageBytes = UnsafeRawBufferPointer(rebasing: bytes[0..<total])
        if verifyCRC {
            let computed = OggCRC32.pageChecksum(pageBytes)
            guard computed == crc else {
                throw SafariumError.encode(String(
                    format: "Ogg: CRC-32 mismatch at byte offset %lld (stored 0x%08X, computed 0x%08X, serial 0x%08X, seq %u)",
                    offsetForErrors, crc, computed, serial, seq
                ))
            }
        }
        let body = Data(UnsafeRawBufferPointer(rebasing: bytes[headerSize..<total]))
        let page = OggPage(
            version: 0,
            headerType: headerType,
            granulePosition: granule,
            serialNumber: serial,
            pageSequence: seq,
            checksum: crc,
            segmentTable: table,
            body: body
        )
        return (page, total)
    }

    /// Parses one page from `data` at `offset`; `nil` when more bytes are needed.
    public static func parse(_ data: Data, at offset: Int = 0, verifyCRC: Bool = true) throws -> (page: OggPage, size: Int)? {
        guard offset >= 0, offset <= data.count else {
            throw SafariumError.encode("Ogg: parse offset \(offset) out of bounds (\(data.count) bytes)")
        }
        return try data.withUnsafeBytes { raw in
            try parse(
                bytes: UnsafeRawBufferPointer(rebasing: raw[offset..<raw.count]),
                verifyCRC: verifyCRC,
                offsetForErrors: Int64(offset)
            )
        }
    }

    /// Parses a complete in-memory Ogg byte stream into pages; throws on any truncated tail.
    public static func parseAll(_ data: Data, verifyCRC: Bool = true) throws -> [OggPage] {
        var pages: [OggPage] = []
        var off = 0
        while off < data.count {
            guard let (p, n) = try parse(data, at: off, verifyCRC: verifyCRC) else {
                throw SafariumError.encode("Ogg: truncated page at byte offset \(off) (\(data.count - off) trailing bytes)")
            }
            pages.append(p)
            off += n
        }
        return pages
    }
}

// MARK: - Page Writer (paginator)

/// Packs packets into RFC 3533 pages for one logical stream (used for synthetic streams and remuxing).
public struct OggPageWriter {
    public let serialNumber: UInt32
    public private(set) var nextSequence: UInt32
    private var pendingTable: [UInt8] = []
    private var pendingBody = Data()
    private var pendingGranule: Int64 = -1
    private var pendingContinued = false
    private var wroteBOS = false
    public private(set) var pages: [OggPage] = []

    public init(serialNumber: UInt32, firstSequence: UInt32 = 0) {
        self.serialNumber = serialNumber
        self.nextSequence = firstSequence
    }

    /// Appends one packet. `granulePosition` is the absolute granule at the end of this packet.
    /// `flush` forces the page to end after this packet; `endOfStream` marks the final page EOS.
    public mutating func append(packet: Data, granulePosition: Int64, flush: Bool = false, endOfStream: Bool = false) throws {
        var remaining = packet.count
        var pos = 0
        while true {
            if pendingTable.count == 255 {
                try emit(eos: false)
                pendingContinued = (pos > 0)
            }
            let lace = min(remaining, 255)
            pendingTable.append(UInt8(lace))
            pendingBody.append(packet.subdata(in: pos..<(pos + lace)))
            pos += lace
            remaining -= lace
            if lace < 255 { break }
            if remaining == 0 {
                // A packet whose size is a multiple of 255 needs a terminating 0 lace.
                if pendingTable.count == 255 {
                    try emit(eos: false)
                    pendingContinued = (pos > 0)
                }
                pendingTable.append(0)
                break
            }
        }
        pendingGranule = granulePosition
        if flush || endOfStream {
            try emit(eos: endOfStream)
        }
    }

    public mutating func flush() throws {
        if !pendingTable.isEmpty { try emit(eos: false) }
    }

    private mutating func emit(eos: Bool) throws {
        var flags: UInt8 = 0
        if pendingContinued { flags |= OggPage.flagContinued }
        if !wroteBOS { flags |= OggPage.flagBOS; wroteBOS = true }
        if eos { flags |= OggPage.flagEOS }
        // Granule is -1 when no packet completes on this page.
        let completes = pendingTable.contains { $0 < 255 }
        let page = try OggPage(
            headerType: flags,
            granulePosition: completes ? pendingGranule : -1,
            serialNumber: serialNumber,
            pageSequence: nextSequence,
            segmentTable: pendingTable,
            body: pendingBody
        )
        pages.append(page)
        nextSequence &+= 1
        pendingTable.removeAll(keepingCapacity: true)
        pendingBody = Data()
        pendingContinued = false
    }

    public func serializedStream() -> Data {
        var d = Data()
        for p in pages { d.append(p.serialized()) }
        return d
    }
}

// MARK: - Streaming Page Reader

/// Bounded-memory page reader over a file (chunked reads) or an in-memory buffer.
public final class OggPageReader {
    private let handle: FileHandle?
    private var buffer: [UInt8]
    private var start = 0
    private var end = 0
    private var eof = false
    private let chunkSize: Int
    public let verifyCRC: Bool
    /// Absolute byte offset of the next unread page.
    public private(set) var offset: Int64 = 0

    public init(url: URL, chunkSize: Int = 64 * 1024, verifyCRC: Bool = true) throws {
        try SafeFilePublisher.assertRegularReadableFile(url)
        guard let h = FileHandle(forReadingAtPath: url.path) else {
            throw SafariumError.invalidState("cannot open Ogg input: \(url.path)")
        }
        self.handle = h
        self.chunkSize = max(4096, chunkSize)
        self.buffer = [UInt8](repeating: 0, count: OggPage.maxPageSize + self.chunkSize)
        self.verifyCRC = verifyCRC
    }

    public init(data: Data, verifyCRC: Bool = true) {
        self.handle = nil
        self.chunkSize = data.count
        self.buffer = [UInt8](data)
        self.end = data.count
        self.eof = true
        self.verifyCRC = verifyCRC
    }

    deinit { try? handle?.close() }

    private func refill() throws {
        guard !eof, let handle else { eof = true; return }
        if start > 0 {
            let n = end - start
            if n > 0 {
                buffer.withUnsafeMutableBufferPointer { p in
                    _ = memmove(p.baseAddress!, p.baseAddress! + start, n)
                }
            }
            start = 0
            end = n
        }
        let want = min(chunkSize, buffer.count - end)
        guard want > 0 else { return }
        let chunk = try handle.read(upToCount: want) ?? Data()
        if chunk.isEmpty {
            eof = true
            return
        }
        buffer.withUnsafeMutableBufferPointer { p in
            _ = chunk.copyBytes(to: UnsafeMutableBufferPointer(rebasing: p[end..<(end + chunk.count)]))
        }
        end += chunk.count
    }

    /// Next page, or `nil` at a clean end of input. Throws on truncation or corruption.
    public func nextPage() throws -> OggPage? {
        while true {
            let avail = end - start
            if avail == 0 && eof { return nil }
            let parsed: (page: OggPage, size: Int)? = try buffer.withUnsafeBytes { raw in
                try OggPage.parse(
                    bytes: UnsafeRawBufferPointer(rebasing: raw[start..<end]),
                    verifyCRC: verifyCRC,
                    offsetForErrors: offset
                )
            }
            if let (page, size) = parsed {
                start += size
                offset += Int64(size)
                return page
            }
            if eof {
                throw SafariumError.encode("Ogg: truncated page at byte offset \(offset) (\(avail) trailing bytes)")
            }
            try refill()
        }
    }
}

// MARK: - Packets / Codec Detection

public enum OggCodecKind: String, Codable, Sendable {
    case vorbis, flac, opus, theora, unknown

    public static func detect(bosPacket p: Data) -> OggCodecKind {
        let b = [UInt8](p.prefix(8))
        if b.count >= 7, b[0] == 0x01, Array(b[1..<7]) == Array("vorbis".utf8) { return .vorbis }
        if b.count >= 5, b[0] == 0x7F, Array(b[1..<5]) == Array("FLAC".utf8) { return .flac }
        if b.count >= 8, Array(b[0..<8]) == Array("OpusHead".utf8) { return .opus }
        if b.count >= 7, b[0] == 0x80, Array(b[1..<7]) == Array("theora".utf8) { return .theora }
        return .unknown
    }
}

public struct OggPacket: Sendable {
    public let serialNumber: UInt32
    public let data: Data
    /// Page granule when this is the last packet completed on its page, otherwise -1.
    public let granulePosition: Int64
    /// Granule of the page on which this packet completed (may be -1 per RFC 3533).
    public let pageGranulePosition: Int64
    public let pageSequence: UInt32
    public let isBeginningOfStream: Bool
    /// True when the packet completed on a page flagged EOS.
    public let pageIsEndOfStream: Bool
    /// True for the last packet of the logical stream (last packet completed on the EOS page).
    public let isLastPacketOfStream: Bool
    public let packetIndex: Int
}

public struct OggLogicalStreamInfo: Codable, Sendable {
    public let serialNumber: UInt32
    public let codec: OggCodecKind
    public let pages: Int
    public let packets: Int
    public let firstGranule: Int64
    public let lastGranule: Int64
    public let sawBOS: Bool
    public let sawEOS: Bool
    public let sampleRate: Int?
    public let channels: Int?
    public let preSkip: Int?
    public let durationSeconds: Double?
}

public struct OggInspectReport: Codable, Sendable {
    public let path: String
    public let fileBytes: Int64
    public let pageCount: Int
    public let streams: [OggLogicalStreamInfo]
    public let tracks: [ContainerTrackInfo]
    public let durationSeconds: Double
}

/// Reassembles packets from pages (RFC 3533 lacing; packets may span segments and pages).
public final class OggStreamDemuxer {
    /// Upper bound for one reassembled packet; protects against endless 255-lacing.
    public static let maxPacketSize = 16 * 1024 * 1024

    private struct StreamState {
        var codec: OggCodecKind = .unknown
        var partial = Data()
        var hasPartial = false
        var lastSequence: UInt32?
        var packets = 0
        var pages = 0
        var firstGranule: Int64 = -1
        var lastGranule: Int64 = -1
        var sawBOS = false
        var sawEOS = false
        var bosPacket: Data?
    }

    private let reader: OggPageReader
    private var states: [UInt32: StreamState] = [:]
    private var order: [UInt32] = []
    private var queue: [OggPacket] = []
    private var queueIndex = 0
    public private(set) var pageCount = 0
    /// When set, pages of other logical streams are skipped (but still CRC-validated).
    public var serialFilter: UInt32?

    public init(url: URL, verifyCRC: Bool = true) throws {
        self.reader = try OggPageReader(url: url, verifyCRC: verifyCRC)
    }

    public init(data: Data, verifyCRC: Bool = true) {
        self.reader = OggPageReader(data: data, verifyCRC: verifyCRC)
    }

    public var byteOffset: Int64 { reader.offset }

    /// Next page (also updates stream bookkeeping and packet queue). Mostly for inspection.
    public func nextPacket() throws -> OggPacket? {
        while true {
            if queueIndex < queue.count {
                let p = queue[queueIndex]
                queueIndex += 1
                return p
            }
            queue.removeAll(keepingCapacity: true)
            queueIndex = 0
            guard let page = try reader.nextPage() else {
                for serial in order {
                    if let s = states[serial], s.hasPartial {
                        throw SafariumError.encode("Ogg: stream 0x\(String(serial, radix: 16)) ends with an unterminated (truncated) packet")
                    }
                }
                return nil
            }
            try ingest(page)
        }
    }

    private func ingest(_ page: OggPage) throws {
        pageCount += 1
        let serial = page.serialNumber
        var st: StreamState
        if let s = states[serial] {
            st = s
            if page.isBeginningOfStream {
                throw SafariumError.encode("Ogg: duplicate BOS page for serial 0x\(String(serial, radix: 16))")
            }
            if st.sawEOS {
                throw SafariumError.encode("Ogg: page after EOS for serial 0x\(String(serial, radix: 16))")
            }
        } else {
            guard page.isBeginningOfStream else {
                throw SafariumError.encode("Ogg: first page of serial 0x\(String(serial, radix: 16)) lacks the BOS flag")
            }
            guard states.count < 64 else {
                throw SafariumError.encode("Ogg: too many concurrent logical streams (>64)")
            }
            st = StreamState()
            st.sawBOS = true
            order.append(serial)
        }
        if let last = st.lastSequence, page.pageSequence != last &+ 1 {
            throw SafariumError.encode("Ogg: page sequence gap for serial 0x\(String(serial, radix: 16)) (expected \(last &+ 1), got \(page.pageSequence))")
        }
        st.lastSequence = page.pageSequence
        st.pages += 1
        if page.isEndOfStream { st.sawEOS = true }
        if page.granulePosition != -1 {
            if st.firstGranule == -1 { st.firstGranule = page.granulePosition }
            st.lastGranule = page.granulePosition
        }

        if page.isContinued != st.hasPartial {
            if page.isContinued {
                throw SafariumError.encode("Ogg: continued page without a pending packet (serial 0x\(String(serial, radix: 16)), seq \(page.pageSequence))")
            } else {
                throw SafariumError.encode("Ogg: pending packet not continued on next page (serial 0x\(String(serial, radix: 16)), seq \(page.pageSequence))")
            }
        }

        let frags = page.fragments()
        let lastCompleting = frags.lastIndex { $0.terminatesPacket }
        let deliver = serialFilter == nil || serialFilter == serial
        for (i, f) in frags.enumerated() {
            if st.partial.count + f.range.count > Self.maxPacketSize {
                throw SafariumError.encode("Ogg: packet exceeds \(Self.maxPacketSize) bytes (malformed lacing) on serial 0x\(String(serial, radix: 16))")
            }
            if deliver || st.packets == 0 {
                st.partial.append(page.body.subdata(in: f.range))
            }
            st.hasPartial = true
            guard f.terminatesPacket else { continue }
            let data = st.partial
            st.partial = Data()
            st.hasPartial = false
            let isFirst = st.packets == 0
            if isFirst {
                st.codec = OggCodecKind.detect(bosPacket: data)
                st.bosPacket = data
            }
            let isLastOnPage = (i == lastCompleting)
            if deliver {
                queue.append(OggPacket(
                    serialNumber: serial,
                    data: data,
                    granulePosition: isLastOnPage ? page.granulePosition : -1,
                    pageGranulePosition: page.granulePosition,
                    pageSequence: page.pageSequence,
                    isBeginningOfStream: isFirst,
                    pageIsEndOfStream: page.isEndOfStream,
                    isLastPacketOfStream: page.isEndOfStream && isLastOnPage,
                    packetIndex: st.packets
                ))
            }
            st.packets += 1
        }
        if page.isEndOfStream && st.hasPartial {
            throw SafariumError.encode("Ogg: EOS page ends inside a packet (serial 0x\(String(serial, radix: 16)))")
        }
        states[serial] = st
    }

    public var serials: [UInt32] { order }

    public func codec(of serial: UInt32) -> OggCodecKind { states[serial]?.codec ?? .unknown }

    fileprivate func streamInfos() -> [OggLogicalStreamInfo] {
        order.compactMap { serial -> OggLogicalStreamInfo? in
            guard let s = states[serial] else { return nil }
            var rate: Int?
            var ch: Int?
            var preSkip: Int?
            if let bos = s.bosPacket {
                let b = [UInt8](bos)
                switch s.codec {
                case .vorbis where b.count >= 30:
                    ch = Int(b[11])
                    rate = Int(UInt32(b[12]) | UInt32(b[13]) << 8 | UInt32(b[14]) << 16 | UInt32(b[15]) << 24)
                case .opus where b.count >= 19:
                    ch = Int(b[9])
                    preSkip = Int(UInt16(b[10]) | UInt16(b[11]) << 8)
                    rate = 48_000
                case .flac where b.count >= 51:
                    let si = 17
                    rate = (Int(b[si + 10]) << 12) | (Int(b[si + 11]) << 4) | (Int(b[si + 12]) >> 4)
                    ch = ((Int(b[si + 12]) >> 1) & 0x07) + 1
                default:
                    break
                }
            }
            var dur: Double?
            if let rate, rate > 0, s.lastGranule >= 0 {
                dur = Double(max(0, s.lastGranule - Int64(preSkip ?? 0))) / Double(rate)
            }
            return OggLogicalStreamInfo(
                serialNumber: serial,
                codec: s.codec,
                pages: s.pages,
                packets: s.packets,
                firstGranule: s.firstGranule,
                lastGranule: s.lastGranule,
                sawBOS: s.sawBOS,
                sawEOS: s.sawEOS,
                sampleRate: rate,
                channels: ch,
                preSkip: preSkip,
                durationSeconds: dur
            )
        }
    }
}

// MARK: - Container Facade

public struct OggFLACExtractReport: Codable, Sendable {
    public let inputPath: String
    public let outputPath: String
    public let serialNumber: UInt32
    public let metadataBlocks: Int
    public let audioFrames: Int
    public let sampleRate: Int
    public let channels: Int
    public let bitsPerSample: Int
    public let totalSamples: Int64
    public let bytesWritten: Int64
}

public enum OggContainer {
    /// Streams the whole file page by page (bounded RAM) and reports every logical stream.
    public static func inspect(url: URL) throws -> OggInspectReport {
        try SafeFilePublisher.assertRegularReadableFile(url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let demux = try OggStreamDemuxer(url: url)
        // Drain packets page by page without retaining them (bounded RAM).
        while try demux.nextPacket() != nil {}
        let infos = demux.streamInfos()
        guard !infos.isEmpty else {
            throw SafariumError.encode("Ogg: no logical streams in \(url.lastPathComponent)")
        }
        let tracks = infos.enumerated().map { idx, s in
            ContainerTrackInfo(
                trackNumber: idx + 1,
                kind: s.codec == .theora ? .video : .audio,
                codecID: s.codec.rawValue,
                sampleRate: s.sampleRate,
                channels: s.channels
            )
        }
        return OggInspectReport(
            path: url.path,
            fileBytes: size,
            pageCount: demux.pageCount,
            streams: infos,
            tracks: tracks,
            durationSeconds: infos.compactMap(\.durationSeconds).max() ?? 0
        )
    }

    // MARK: Ogg FLAC -> native fLaC

    private struct FLACStreamInfo {
        var sampleRate = 0
        var channels = 0
        var bitsPerSample = 0
        var totalSamples: Int64 = 0
    }

    /// Core streaming converter. `sink` receives native FLAC bytes in order.
    private static func convertOggFLAC(
        demux: OggStreamDemuxer,
        sink: (Data) throws -> Void
    ) throws -> (serial: UInt32, meta: Int, frames: Int, info: FLACStreamInfo) {
        var serial: UInt32?
        var info = FLACStreamInfo()
        var pendingMeta: Data?
        var metaCount = 0
        var frames = 0
        var inAudio = false

        func emitPendingMeta(last: Bool) throws {
            guard var m = pendingMeta else { return }
            if last { m[m.startIndex] |= 0x80 } else { m[m.startIndex] &= 0x7F }
            try sink(m)
            pendingMeta = nil
        }

        while let pkt = try demux.nextPacket() {
            if serial == nil {
                guard pkt.isBeginningOfStream else { continue }
                guard OggCodecKind.detect(bosPacket: pkt.data) == .flac else { continue }
                serial = pkt.serialNumber
                demux.serialFilter = pkt.serialNumber
                let b = [UInt8](pkt.data)
                guard b.count == 51 else {
                    throw SafariumError.encode("Ogg FLAC: first packet must be 51 bytes (got \(b.count))")
                }
                guard b[5] == 1 else {
                    throw SafariumError.encode("Ogg FLAC: unsupported mapping major version \(b[5])")
                }
                guard Array(b[9..<13]) == Array("fLaC".utf8) else {
                    throw SafariumError.encode("Ogg FLAC: missing native 'fLaC' signature in first packet")
                }
                let blockType = b[13] & 0x7F
                let blockLen = (Int(b[14]) << 16) | (Int(b[15]) << 8) | Int(b[16])
                guard blockType == 0, blockLen == 34 else {
                    throw SafariumError.encode("Ogg FLAC: first metadata block must be a 34-byte STREAMINFO (type \(blockType), len \(blockLen))")
                }
                let si = 17
                info.sampleRate = (Int(b[si + 10]) << 12) | (Int(b[si + 11]) << 4) | (Int(b[si + 12]) >> 4)
                info.channels = ((Int(b[si + 12]) >> 1) & 0x07) + 1
                info.bitsPerSample = (((Int(b[si + 12]) & 0x01) << 4) | (Int(b[si + 13]) >> 4)) + 1
                info.totalSamples = (Int64(b[si + 13] & 0x0F) << 32)
                    | (Int64(b[si + 14]) << 24) | (Int64(b[si + 15]) << 16)
                    | (Int64(b[si + 16]) << 8) | Int64(b[si + 17])
                guard info.sampleRate > 0 else {
                    throw SafariumError.encode("Ogg FLAC: STREAMINFO sample rate is zero")
                }
                try sink(Data("fLaC".utf8))
                pendingMeta = Data(b[13..<51])
                metaCount = 1
                continue
            }
            guard pkt.serialNumber == serial else { continue }
            let d = pkt.data
            guard !d.isEmpty else { continue }
            let b0 = d[d.startIndex]
            let isAudio = d.count >= 2 && b0 == 0xFF && (d[d.startIndex + 1] & 0xFE) == 0xF8
            if isAudio {
                if !inAudio {
                    try emitPendingMeta(last: true)
                    inAudio = true
                }
                try sink(d)
                frames += 1
            } else {
                guard !inAudio else {
                    throw SafariumError.encode("Ogg FLAC: non-audio packet after audio frames began (packet \(pkt.packetIndex))")
                }
                guard d.count >= 4 else {
                    throw SafariumError.encode("Ogg FLAC: metadata packet too short (\(d.count) bytes)")
                }
                let type = b0 & 0x7F
                let len = (Int(d[d.startIndex + 1]) << 16) | (Int(d[d.startIndex + 2]) << 8) | Int(d[d.startIndex + 3])
                guard type != 127, len == d.count - 4 else {
                    throw SafariumError.encode("Ogg FLAC: malformed metadata block (type \(type), declared \(len), actual \(d.count - 4))")
                }
                try emitPendingMeta(last: false)
                pendingMeta = d
                metaCount += 1
            }
        }
        guard let serial else {
            throw SafariumError.encode("Ogg FLAC: no FLAC logical stream found")
        }
        if !inAudio { try emitPendingMeta(last: true) }
        return (serial, metaCount, frames, info)
    }

    /// Converts an in-memory Ogg FLAC stream to native FLAC bytes (`fLaC` + metadata + frames).
    public static func extractRawFLACData(from oggData: Data) throws -> Data {
        var out = Data()
        let demux = OggStreamDemuxer(data: oggData)
        _ = try convertOggFLAC(demux: demux) { out.append($0) }
        return out
    }

    /// Streams an Ogg FLAC file to a native `.flac` file with bounded RAM and atomic publish.
    @discardableResult
    public static func extractRawFLAC(from inputURL: URL, to outputURL: URL, overwrite: Bool = false) throws -> OggFLACExtractReport {
        try SafeFilePublisher.assertRegularReadableFile(inputURL)
        try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)
        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }
        let tmp = staging.fileURL("extract.flac")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil),
              let fh = FileHandle(forWritingAtPath: tmp.path) else {
            throw SafariumError.encode("Ogg FLAC: cannot create staging file")
        }
        var written: Int64 = 0
        let demux = try OggStreamDemuxer(url: inputURL)
        let r: (serial: UInt32, meta: Int, frames: Int, info: FLACStreamInfo)
        do {
            r = try convertOggFLAC(demux: demux) { chunk in
                try fh.write(contentsOf: chunk)
                written += Int64(chunk.count)
            }
            try fh.close()
        } catch {
            try? fh.close()
            throw error
        }
        try SafeFilePublisher.publish(tempURL: tmp, to: outputURL, overwrite: overwrite)
        return OggFLACExtractReport(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            serialNumber: r.serial,
            metadataBlocks: r.meta,
            audioFrames: r.frames,
            sampleRate: r.info.sampleRate,
            channels: r.info.channels,
            bitsPerSample: r.info.bitsPerSample,
            totalSamples: r.info.totalSamples,
            bytesWritten: written
        )
    }
}
