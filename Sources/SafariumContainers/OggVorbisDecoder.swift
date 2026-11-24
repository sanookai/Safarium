import Accelerate
import Foundation
import SafariumCore

// Pure-Swift Vorbis I decoder (Xiph Vorbis I specification), accelerated with Apple Accelerate/vDSP.
// No C, no third-party code, no FFmpeg/libav. Bounded RAM: O(blocksize_1 * channels) per packet.

// MARK: - Public Types

public struct VorbisIdentificationHeader: Codable, Sendable, Equatable {
    public let vorbisVersion: UInt32
    public let channels: Int
    public let sampleRate: Int
    public let bitrateMaximum: Int32
    public let bitrateNominal: Int32
    public let bitrateMinimum: Int32
    public let blocksize0: Int
    public let blocksize1: Int
}

public struct VorbisCommentHeader: Codable, Sendable, Equatable {
    public let vendor: String
    public let comments: [String]
}

public struct OggAudioInfo: Codable, Sendable {
    public let path: String
    public let codec: String
    public let serialNumber: UInt32
    public let sampleRate: Int
    public let channels: Int
    public let blocksize0: Int
    public let blocksize1: Int
    public let bitrateNominal: Int32
    public let vendor: String
    public let comments: [String]
    public let lastGranulePosition: Int64
    public let durationSeconds: Double
}

public struct OggDecodeSummary: Codable, Sendable {
    public let path: String
    public let sampleRate: Int
    public let channels: Int
    public let frames: Int64
    public let audioPackets: Int
    public let durationSeconds: Double
    public let peak: Float
    public let rms: Double
    public let nonFiniteSamples: Int
    public let trimmedLeadingFrames: Int64
    public let trimmedTrailingFrames: Int64
    public let finalGranulePosition: Int64
    public let maxChunkFrames: Int
}

public enum OggWAVSampleFormat: String, Codable, Sendable {
    case float32
    case int16
}

// MARK: - Bit Reader (LSB-first, Vorbis I §2.1.4)

struct VorbisBitReader {
    private let base: UnsafePointer<UInt8>?
    let byteCount: Int
    private(set) var bitPosition = 0
    private(set) var endOfPacket = false

    init(_ buf: UnsafeRawBufferPointer) {
        self.base = buf.count > 0 ? buf.bindMemory(to: UInt8.self).baseAddress : nil
        self.byteCount = buf.count
    }

    @inline(__always) var bitsRemaining: Int { byteCount &* 8 &- bitPosition }

    /// Next `n` (0...32) bits without consuming; bits past the end read as zero.
    @inline(__always) func peek(_ n: Int) -> UInt32 {
        guard n > 0, let base else { return 0 }
        let byteIdx = bitPosition >> 3
        let shift = bitPosition & 7
        let need = (shift + n + 7) >> 3
        var acc: UInt64 = 0
        var i = 0
        while i < need {
            let bi = byteIdx + i
            if bi < byteCount { acc |= UInt64(base[bi]) << UInt64(8 * i) }
            i += 1
        }
        let mask: UInt64 = n == 64 ? ~0 : ((1 << UInt64(n)) - 1)
        return UInt32(truncatingIfNeeded: (acc >> UInt64(shift)) & mask)
    }

    @inline(__always) mutating func advance(_ n: Int) {
        bitPosition += n
        if bitPosition > byteCount * 8 {
            bitPosition = byteCount * 8
            endOfPacket = true
        }
    }

    @inline(__always) mutating func markEndOfPacket() {
        bitPosition = byteCount * 8
        endOfPacket = true
    }

    @inline(__always) mutating func read(_ n: Int) -> UInt32 {
        guard n > 0 else { return 0 }
        guard n <= bitsRemaining else {
            markEndOfPacket()
            return 0
        }
        let v = peek(n)
        bitPosition += n
        return v
    }

    @inline(__always) mutating func readInt(_ n: Int) -> Int { Int(read(n)) }
    @inline(__always) mutating func readFlag() -> Bool { read(1) == 1 }
}

@inline(__always) func vorbisILog(_ x: Int) -> Int {
    x <= 0 ? 0 : (Int.bitWidth - x.leadingZeroBitCount)
}

/// Vorbis I §9.2.2 float32_unpack.
@inline(__always) func vorbisFloat32Unpack(_ x: UInt32) -> Float {
    var mantissa = Double(x & 0x1F_FFFF)
    let exponent = Int((x & 0x7FE0_0000) >> 21)
    if (x & 0x8000_0000) != 0 { mantissa = -mantissa }
    return Float(scalbn(mantissa, exponent - 788))
}

/// Vorbis I §9.2.3 lookup1_values: greatest r with r^dims <= entries.
func vorbisLookup1Values(entries: Int, dimensions: Int) -> Int {
    guard entries > 0, dimensions > 0 else { return 0 }
    func powLE(_ base: Int, _ exp: Int, _ limit: Int) -> Bool {
        var acc = 1
        for _ in 0..<exp {
            let (m, o) = acc.multipliedReportingOverflow(by: base)
            if o || m > limit { return false }
            acc = m
        }
        return acc <= limit
    }
    var r = Int(floor(exp(log(Double(entries)) / Double(dimensions))))
    r = max(0, r)
    while powLE(r + 1, dimensions, entries) { r += 1 }
    while r > 0 && !powLE(r, dimensions, entries) { r -= 1 }
    return r
}

// MARK: - Codebook (Vorbis I §3)

final class VorbisCodebook {
    let dimensions: Int
    let entries: Int
    let lengths: [UInt8]
    let lookupType: Int
    let usedEntries: Int
    /// Reversed (LSB-first) codewords, valid where length > 0.
    let codewords: [UInt32]
    private(set) var vq: UnsafeMutablePointer<Float>?
    private let table: UnsafeMutablePointer<Int32>
    private let tableBits: Int
    private let maxLength: Int
    private let singleEntry: Int
    private var longCodes: [[(code: UInt32, entry: Int32)]]

    static let maxTableBits = 10

    deinit {
        table.deallocate()
        vq?.deallocate()
    }

    init(dimensions: Int, entries: Int, lengths: [UInt8], lookupType: Int, vqValues: [Float]?) throws {
        self.dimensions = dimensions
        self.entries = entries
        self.lengths = lengths
        self.lookupType = lookupType

        // libvorbis-compatible codeword assignment (_make_words) with over/under-population checks.
        var marker = [UInt64](repeating: 0, count: 33)
        var codes = [UInt32](repeating: 0, count: entries)
        var used = 0
        var maxLen = 0
        for i in 0..<entries {
            let len = Int(lengths[i])
            guard len > 0 else { continue }
            used += 1
            maxLen = max(maxLen, len)
            var entry = marker[len]
            if len < 32 && (entry >> UInt64(len)) != 0 {
                throw SafariumError.encode("Vorbis codebook: Huffman tree overpopulated (entry \(i), length \(len))")
            }
            codes[i] = UInt32(truncatingIfNeeded: entry)
            var j = len
            while j > 0 {
                if (marker[j] & 1) != 0 {
                    if j == 1 { marker[1] += 1 } else { marker[j] = marker[j - 1] << 1 }
                    break
                }
                marker[j] += 1
                j -= 1
            }
            var k = len + 1
            while k < 33 {
                if (marker[k] >> 1) == entry {
                    entry = marker[k]
                    marker[k] = marker[k - 1] << 1
                } else {
                    break
                }
                k += 1
            }
        }
        if used != 1 && used > 0 {
            for i in 1...32 where (marker[i] & (UInt64(0xFFFF_FFFF) >> UInt64(32 - i))) != 0 {
                throw SafariumError.encode("Vorbis codebook: Huffman tree underpopulated (length \(i))")
            }
        }
        self.usedEntries = used
        self.maxLength = maxLen
        var reversed = [UInt32](repeating: 0, count: entries)
        var single = -1
        for i in 0..<entries {
            let len = Int(lengths[i])
            guard len > 0 else { continue }
            var r: UInt32 = 0
            for b in 0..<len { r = (r << 1) | ((codes[i] >> UInt32(b)) & 1) }
            reversed[i] = r
            if used == 1 { single = i }
        }
        self.codewords = reversed
        self.singleEntry = single

        let tb = min(maxLen, Self.maxTableBits)
        self.tableBits = tb
        let tsize = 1 << tb
        self.table = UnsafeMutablePointer<Int32>.allocate(capacity: tsize)
        table.initialize(repeating: -1, count: tsize)
        var long = [[(code: UInt32, entry: Int32)]](repeating: [], count: 33)
        if used > 1 {
            for i in 0..<entries {
                let len = Int(lengths[i])
                guard len > 0 else { continue }
                if len <= tb {
                    var idx = Int(reversed[i])
                    let step = 1 << len
                    while idx < tsize {
                        table[idx] = (Int32(i) << 8) | Int32(len)
                        idx += step
                    }
                } else {
                    long[len].append((reversed[i], Int32(i)))
                }
            }
            for l in 0..<33 where !long[l].isEmpty {
                long[l].sort { $0.code < $1.code }
            }
        }
        self.longCodes = long

        if let vqValues {
            precondition(vqValues.count == entries * dimensions)
            let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, vqValues.count))
            vqValues.withUnsafeBufferPointer { src in
                if let b = src.baseAddress { p.initialize(from: b, count: vqValues.count) }
            }
            self.vq = p
        }
    }

    /// Decodes one entry number; returns -1 on end-of-packet or an invalid codeword.
    @inline(__always) func decode(_ r: inout VorbisBitReader) -> Int {
        if singleEntry >= 0 { return singleEntry } // §3.2.1: single used entry sinks zero bits
        guard usedEntries > 1 else {
            r.markEndOfPacket()
            return -1
        }
        let v = table[Int(r.peek(tableBits))]
        if v >= 0 {
            let len = Int(v & 0xFF)
            if len > r.bitsRemaining {
                r.markEndOfPacket()
                return -1
            }
            r.advance(len)
            return Int(v >> 8)
        }
        if maxLength > tableBits {
            for len in (tableBits + 1)...maxLength {
                let bucket = longCodes[len]
                if bucket.isEmpty { continue }
                let code = r.peek(len)
                var lo = 0
                var hi = bucket.count - 1
                while lo <= hi {
                    let mid = (lo + hi) >> 1
                    let c = bucket[mid].code
                    if c == code {
                        if len > r.bitsRemaining {
                            r.markEndOfPacket()
                            return -1
                        }
                        r.advance(len)
                        return Int(bucket[mid].entry)
                    } else if c < code {
                        lo = mid + 1
                    } else {
                        hi = mid - 1
                    }
                }
            }
        }
        r.markEndOfPacket()
        return -1
    }

    static func parse(_ r: inout VorbisBitReader) throws -> VorbisCodebook {
        let sync = r.read(24)
        guard sync == 0x564342 else {
            throw SafariumError.encode(String(format: "Vorbis codebook: bad sync pattern 0x%06X", sync))
        }
        let dims = r.readInt(16)
        let entries = r.readInt(24)
        guard !r.endOfPacket else { throw SafariumError.encode("Vorbis codebook: truncated header") }
        guard entries > 0 else { throw SafariumError.encode("Vorbis codebook: zero entries") }
        // libvorbis sanity bound (keeps dims*entries < 2^24).
        guard vorbisILog(dims) + vorbisILog(entries) <= 24 else {
            throw SafariumError.encode("Vorbis codebook: dimensions \(dims) x entries \(entries) too large")
        }
        var lengths = [UInt8](repeating: 0, count: entries)
        let ordered = r.readFlag()
        if !ordered {
            let sparse = r.readFlag()
            for i in 0..<entries {
                if sparse {
                    if r.readFlag() { lengths[i] = UInt8(r.read(5) + 1) }
                } else {
                    lengths[i] = UInt8(r.read(5) + 1)
                }
                if r.endOfPacket { throw SafariumError.encode("Vorbis codebook: truncated length list") }
            }
        } else {
            var current = 0
            var length = r.readInt(5) + 1
            while current < entries {
                let number = r.readInt(vorbisILog(entries - current))
                guard !r.endOfPacket else { throw SafariumError.encode("Vorbis codebook: truncated ordered lengths") }
                guard length <= 32, number <= entries - current else {
                    throw SafariumError.encode("Vorbis codebook: invalid ordered length run (length \(length), count \(number))")
                }
                for i in current..<(current + number) { lengths[i] = UInt8(length) }
                current += number
                length += 1
            }
        }
        let lookupType = r.readInt(4)
        var vqValues: [Float]?
        switch lookupType {
        case 0:
            break
        case 1, 2:
            guard dims > 0 else { throw SafariumError.encode("Vorbis codebook: VQ lookup with zero dimensions") }
            let minimum = vorbisFloat32Unpack(r.read(32))
            let delta = vorbisFloat32Unpack(r.read(32))
            let valueBits = r.readInt(4) + 1
            let sequenceP = r.readFlag()
            let lookupValues = lookupType == 1
                ? vorbisLookup1Values(entries: entries, dimensions: dims)
                : entries * dims
            guard lookupValues > 0 else { throw SafariumError.encode("Vorbis codebook: zero lookup values") }
            guard lookupValues * valueBits <= r.bitsRemaining else {
                throw SafariumError.encode("Vorbis codebook: truncated multiplicands (\(lookupValues) x \(valueBits) bits)")
            }
            var mult = [Float](repeating: 0, count: lookupValues)
            for i in 0..<lookupValues { mult[i] = Float(r.read(valueBits)) }
            var vals = [Float](repeating: 0, count: entries * dims)
            for e in 0..<entries where lengths[e] > 0 {
                var last: Float = 0
                if lookupType == 1 {
                    var indexDivisor = 1
                    for i in 0..<dims {
                        let off = (e / indexDivisor) % lookupValues
                        let v = mult[off] * delta + minimum + last
                        vals[e * dims + i] = v
                        if sequenceP { last = v }
                        indexDivisor = indexDivisor.multipliedReportingOverflow(by: lookupValues).overflow
                            ? Int.max : indexDivisor * lookupValues
                    }
                } else {
                    let base = e * dims
                    for i in 0..<dims {
                        let v = mult[base + i] * delta + minimum + last
                        vals[base + i] = v
                        if sequenceP { last = v }
                    }
                }
            }
            vqValues = vals
        default:
            throw SafariumError.encode("Vorbis codebook: invalid lookup type \(lookupType)")
        }
        guard !r.endOfPacket else { throw SafariumError.encode("Vorbis codebook: truncated") }
        return try VorbisCodebook(dimensions: dims, entries: entries, lengths: lengths, lookupType: lookupType, vqValues: vqValues)
    }
}

// MARK: - Floors / Residues / Mappings / Modes

/// Vorbis I §10.1 floor1_inverse_dB_table. Values are the spec's 8-significant-digit literals,
/// regenerated from their closed form 10^(7(i+1)/256 - 7) and rounded to 8 significant digits
/// before conversion to Float, exactly as a C compiler parses the published literals.
let vorbisFloor1FromDBTable: [Float] = (0..<256).map { i in
    let d = pow(10.0, Double(i + 1) * 7.0 / 256.0 - 7.0)
    let lit = String(format: "%.7e", d)
    return Float(lit) ?? Float(d)
}

final class VorbisFloor0 {
    let order: Int
    let rate: Int
    let barkMapSize: Int
    let amplitudeBits: Int
    let amplitudeOffset: Int
    let books: [Int]
    var maps: [[Int]] = [[], []]

    init(order: Int, rate: Int, barkMapSize: Int, amplitudeBits: Int, amplitudeOffset: Int, books: [Int]) {
        self.order = order
        self.rate = rate
        self.barkMapSize = barkMapSize
        self.amplitudeBits = amplitudeBits
        self.amplitudeOffset = amplitudeOffset
        self.books = books
    }

    static func bark(_ x: Double) -> Double {
        13.1 * atan(0.00074 * x) + 2.24 * atan(0.0000000185 * x * x) + 0.0001 * x
    }

    func prepareMaps(blocksizes: [Int]) {
        for b in 0..<2 {
            let n = blocksizes[b] / 2
            var map = [Int](repeating: 0, count: n + 1)
            let denom = Self.bark(0.5 * Double(rate))
            for i in 0..<n {
                let foobar = floor(Self.bark(Double(rate) * Double(i) / (2.0 * Double(n))) * Double(barkMapSize) / denom)
                map[i] = min(barkMapSize - 1, Int(foobar))
            }
            map[n] = -1
            maps[b] = map
        }
    }
}

final class VorbisFloor1 {
    let partitionClassList: [Int]
    let classDimensions: [Int]
    let classSubclasses: [Int]
    let classMasterbooks: [Int]
    let subclassBooks: [[Int]]
    let multiplier: Int
    let xList: [Int]
    let sortOrder: [Int]
    let lowNeighbor: [Int]
    let highNeighbor: [Int]

    init(partitionClassList: [Int], classDimensions: [Int], classSubclasses: [Int], classMasterbooks: [Int],
         subclassBooks: [[Int]], multiplier: Int, xList: [Int]) throws {
        self.partitionClassList = partitionClassList
        self.classDimensions = classDimensions
        self.classSubclasses = classSubclasses
        self.classMasterbooks = classMasterbooks
        self.subclassBooks = subclassBooks
        self.multiplier = multiplier
        self.xList = xList
        let order = xList.indices.sorted { xList[$0] < xList[$1] }
        for i in 1..<order.count where xList[order[i]] == xList[order[i - 1]] {
            throw SafariumError.encode("Vorbis floor1: duplicate X value \(xList[order[i]])")
        }
        self.sortOrder = order
        var low = [Int](repeating: 0, count: xList.count)
        var high = [Int](repeating: 0, count: xList.count)
        for i in 2..<max(2, xList.count) {
            var lo = -1
            var hi = -1
            for j in 0..<i {
                if xList[j] < xList[i] && (lo < 0 || xList[j] > xList[lo]) { lo = j }
                if xList[j] > xList[i] && (hi < 0 || xList[j] < xList[hi]) { hi = j }
            }
            low[i] = lo
            high[i] = hi
        }
        self.lowNeighbor = low
        self.highNeighbor = high
    }
}

enum VorbisFloor {
    case type0(VorbisFloor0)
    case type1(VorbisFloor1)
}

final class VorbisResidue {
    let type: Int
    let begin: Int
    let end: Int
    let partitionSize: Int
    let classifications: Int
    let classbook: Int
    let books: [[Int]] // [class][pass], -1 = unused
    let partVals: Int

    init(type: Int, begin: Int, end: Int, partitionSize: Int, classifications: Int, classbook: Int, books: [[Int]], partVals: Int) {
        self.type = type
        self.begin = begin
        self.end = end
        self.partitionSize = partitionSize
        self.classifications = classifications
        self.classbook = classbook
        self.books = books
        self.partVals = partVals
    }
}

struct VorbisMapping {
    let submaps: Int
    let couplingMagnitude: [Int]
    let couplingAngle: [Int]
    let mux: [Int]
    let submapFloor: [Int]
    let submapResidue: [Int]
}

struct VorbisMode {
    let blockflag: Int
    let mapping: Int
}

// MARK: - IMDCT (Accelerate)

/// Exact Vorbis inverse MDCT of size N (64...8192):
/// y[i] = Σ_{k<N/2} X[k] cos(2π/N (i + 1/2 + N/4)(k + 1/2)), computed as a DCT-IV of size N/2
/// via an N/4-point complex inverse FFT (`vDSP_fft_zip`) with pre/post twiddles.
final class VorbisIMDCT {
    let n: Int
    private let m: Int
    private let q: Int
    private let log2q: vDSP_Length
    private let setup: FFTSetup
    private let twCos: UnsafeMutablePointer<Float>
    private let twSin: UnsafeMutablePointer<Float>
    private let zr: UnsafeMutablePointer<Float>
    private let zi: UnsafeMutablePointer<Float>
    private let tr: UnsafeMutablePointer<Float>
    private let ti: UnsafeMutablePointer<Float>
    private let u: UnsafeMutablePointer<Float>

    init(size: Int) throws {
        guard size >= 64, size <= 8192, size & (size - 1) == 0 else {
            throw SafariumError.encode("Vorbis IMDCT: unsupported size \(size)")
        }
        n = size
        m = size / 2
        q = size / 4
        log2q = vDSP_Length(q.trailingZeroBitCount)
        guard let s = vDSP_create_fftsetup(log2q, FFTRadix(kFFTRadix2)) else {
            throw SafariumError.encode("Vorbis IMDCT: vDSP_create_fftsetup failed for N=\(size)")
        }
        setup = s
        twCos = .allocate(capacity: q)
        twSin = .allocate(capacity: q)
        zr = .allocate(capacity: q)
        zi = .allocate(capacity: q)
        tr = .allocate(capacity: q)
        ti = .allocate(capacity: q)
        u = .allocate(capacity: m)
        for p in 0..<q {
            let a = Double.pi * (Double(p) + 0.125) / Double(m)
            twCos[p] = Float(cos(a))
            twSin[p] = Float(sin(a))
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        twCos.deallocate(); twSin.deallocate()
        zr.deallocate(); zi.deallocate(); tr.deallocate(); ti.deallocate()
        u.deallocate()
    }

    /// `x`: N/2 spectral coefficients. `y`: N output samples (must not alias `x`).
    func inverse(_ x: UnsafePointer<Float>, _ y: UnsafeMutablePointer<Float>) {
        // a_p = X[2p], b_p = X[M-1-2p]; z_p = (a_p - i b_p) * e^{iπ(p+1/8)/M}
        for p in 0..<q {
            let a = x[2 * p]
            let b = x[m - 1 - 2 * p]
            let c = twCos[p]
            let s = twSin[p]
            zr[p] = a * c + b * s
            zi[p] = a * s - b * c
        }
        var split = DSPSplitComplex(realp: zr, imagp: zi)
        vDSP_fft_zip(setup, &split, 1, log2q, FFTDirection(kFFTDirection_Inverse))
        // W_q = Z_q * e^{iπ(q+1/8)/M}; u[2q] = Re W, u[M-1-2q] = Im W
        var tw = DSPSplitComplex(realp: twCos, imagp: twSin)
        var out = DSPSplitComplex(realp: tr, imagp: ti)
        vDSP_zvmul(&split, 1, &tw, 1, &out, 1, vDSP_Length(q), 1)
        for k in 0..<q {
            u[2 * k] = tr[k]
            u[m - 1 - 2 * k] = ti[k]
        }
        // Unfold DCT-IV (length M) into the N-point IMDCT output.
        let h = m / 2
        for i in 0..<h { y[i] = u[i + h] }
        for i in h..<(3 * h) { y[i] = -u[3 * h - 1 - i] }
        for i in (3 * h)..<(2 * m) { y[i] = -u[i - 3 * h] }
    }
}

// MARK: - Header Parsing

public enum OggVorbisDecoder {
    public static func parseIdentificationHeader(_ data: Data) throws -> VorbisIdentificationHeader {
        let b = [UInt8](data)
        guard b.count >= 30 else {
            throw SafariumError.encode("Vorbis identification header too short (\(b.count) bytes)")
        }
        guard b[0] == 1, Array(b[1..<7]) == Array("vorbis".utf8) else {
            throw SafariumError.encode("Vorbis identification header: bad packet type/signature")
        }
        func le32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
        }
        let version = le32(7)
        guard version == 0 else { throw SafariumError.encode("Vorbis: unsupported vorbis_version \(version)") }
        let channels = Int(b[11])
        guard (1...8).contains(channels) else {
            throw SafariumError.encode("Vorbis: unsupported channel count \(channels) (supported 1...8)")
        }
        let rate = le32(12)
        guard rate > 0, rate <= 768_000 else { throw SafariumError.encode("Vorbis: invalid sample rate \(rate)") }
        let e0 = Int(b[28] & 0x0F)
        let e1 = Int(b[28] >> 4)
        guard (6...13).contains(e0), (6...13).contains(e1), e0 <= e1 else {
            throw SafariumError.encode("Vorbis: invalid blocksizes 2^\(e0) / 2^\(e1)")
        }
        guard (b[29] & 1) == 1 else { throw SafariumError.encode("Vorbis identification header: framing bit not set") }
        return VorbisIdentificationHeader(
            vorbisVersion: version,
            channels: channels,
            sampleRate: Int(rate),
            bitrateMaximum: Int32(bitPattern: le32(16)),
            bitrateNominal: Int32(bitPattern: le32(20)),
            bitrateMinimum: Int32(bitPattern: le32(24)),
            blocksize0: 1 << e0,
            blocksize1: 1 << e1
        )
    }

    public static func parseCommentHeader(_ data: Data) throws -> VorbisCommentHeader {
        let b = [UInt8](data)
        guard b.count >= 7, b[0] == 3, Array(b[1..<7]) == Array("vorbis".utf8) else {
            throw SafariumError.encode("Vorbis comment header: bad packet type/signature")
        }
        var p = 7
        func readLen() throws -> Int {
            guard p + 4 <= b.count else { throw SafariumError.encode("Vorbis comment header truncated at byte \(p)") }
            let v = UInt32(b[p]) | UInt32(b[p + 1]) << 8 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 24
            p += 4
            return Int(v)
        }
        func readString() throws -> String {
            let len = try readLen()
            guard len <= b.count - p else {
                throw SafariumError.encode("Vorbis comment header: string length \(len) exceeds packet")
            }
            let s = String(decoding: b[p..<(p + len)], as: UTF8.self)
            p += len
            return s
        }
        let vendor = try readString()
        let count = try readLen()
        guard count <= (b.count - p) / 4 else {
            throw SafariumError.encode("Vorbis comment header: comment count \(count) exceeds packet")
        }
        var comments: [String] = []
        comments.reserveCapacity(count)
        for _ in 0..<count { comments.append(try readString()) }
        guard p < b.count, (b[p] & 1) == 1 else {
            throw SafariumError.encode("Vorbis comment header: framing bit not set")
        }
        return VorbisCommentHeader(vendor: vendor, comments: comments)
    }

    // MARK: Probe

    public static func probe(url: URL) throws -> OggAudioInfo {
        try SafeFilePublisher.assertRegularReadableFile(url)
        let demux = try OggStreamDemuxer(url: url)
        let (serial, headers) = try readHeaders(demux)
        let id = try parseIdentificationHeader(headers[0])
        let comments = try parseCommentHeader(headers[1])
        _ = try OggVorbisStreamDecoder(identificationPacket: headers[0], commentPacket: headers[1], setupPacket: headers[2])
        let last = try lastGranule(url: url, serial: serial)
        return OggAudioInfo(
            path: url.path,
            codec: "vorbis",
            serialNumber: serial,
            sampleRate: id.sampleRate,
            channels: id.channels,
            blocksize0: id.blocksize0,
            blocksize1: id.blocksize1,
            bitrateNominal: id.bitrateNominal,
            vendor: comments.vendor,
            comments: comments.comments,
            lastGranulePosition: last,
            durationSeconds: last > 0 ? Double(last) / Double(id.sampleRate) : 0
        )
    }

    /// Reads the final granule from the file tail (bounded read), falling back to a streaming scan.
    static func lastGranule(url: URL, serial: UInt32) throws -> Int64 {
        guard let fh = FileHandle(forReadingAtPath: url.path) else {
            throw SafariumError.invalidState("cannot open \(url.path)")
        }
        defer { try? fh.close() }
        let size = try fh.seekToEnd()
        let tail = min(size, UInt64(OggPage.maxPageSize * 2))
        try fh.seek(toOffset: size - tail)
        let data = try fh.read(upToCount: Int(tail)) ?? Data()
        var best: Int64 = -1
        let bytes = [UInt8](data)
        var i = 0
        while i + 27 <= bytes.count {
            if bytes[i] == 0x4F && bytes[i + 1] == 0x67 && bytes[i + 2] == 0x67 && bytes[i + 3] == 0x53 {
                if let (page, size) = try? OggPage.parse(data, at: i), page.serialNumber == serial {
                    if page.granulePosition != -1 { best = page.granulePosition }
                    i += size
                    continue
                }
            }
            i += 1
        }
        if best >= 0 { return best }
        let reader = try OggPageReader(url: url)
        while let page = try reader.nextPage() {
            if page.serialNumber == serial && page.granulePosition != -1 { best = page.granulePosition }
        }
        return best
    }

    static func readHeaders(_ demux: OggStreamDemuxer) throws -> (UInt32, [Data]) {
        var serial: UInt32?
        var headers: [Data] = []
        var seenCodecs: [String] = []
        while headers.count < 3 {
            guard let p = try demux.nextPacket() else {
                if serial == nil {
                    throw SafariumError.encode("Ogg: no Vorbis logical stream (found: \(seenCodecs.joined(separator: ", ")))")
                }
                throw SafariumError.encode("Vorbis: stream ended before all three header packets")
            }
            if serial == nil {
                if p.isBeginningOfStream {
                    let codec = OggCodecKind.detect(bosPacket: p.data)
                    if codec == .vorbis {
                        serial = p.serialNumber
                        demux.serialFilter = p.serialNumber
                        headers.append(p.data)
                    } else {
                        seenCodecs.append(codec.rawValue)
                    }
                    continue
                }
                throw SafariumError.encode("Ogg: unsupported codec, no Vorbis logical stream (found: \(seenCodecs.joined(separator: ", ")))")
            }
            guard p.serialNumber == serial else { continue }
            let expectType: UInt8 = headers.count == 1 ? 3 : 5
            guard let first = p.data.first, first == expectType else {
                throw SafariumError.encode("Vorbis: expected header packet type \(expectType)")
            }
            headers.append(p.data)
        }
        return (serial!, headers)
    }

    // MARK: Streaming Decode

    /// Decodes the first Vorbis logical stream of an Ogg file to interleaved Float32 PCM chunks
    /// (native sample rate and channel order). RAM is bounded by `chunkFrames` + one Vorbis block.
    @discardableResult
    public static func streamToFloat32PCM(
        url: URL,
        chunkFrames: Int = 4096,
        onChunk: (_ interleaved: UnsafeBufferPointer<Float>, _ frames: Int, _ sampleRate: Int, _ channels: Int) throws -> Void
    ) throws -> OggDecodeSummary {
        try SafeFilePublisher.assertRegularReadableFile(url)
        let demux = try OggStreamDemuxer(url: url)
        return try streamCore(demux: demux, path: url.path, chunkFrames: chunkFrames, onChunk: onChunk)
    }

    /// In-memory variant (synthetic streams, tests).
    @discardableResult
    public static func streamToFloat32PCM(
        data: Data,
        chunkFrames: Int = 4096,
        onChunk: (_ interleaved: UnsafeBufferPointer<Float>, _ frames: Int, _ sampleRate: Int, _ channels: Int) throws -> Void
    ) throws -> OggDecodeSummary {
        let demux = OggStreamDemuxer(data: data)
        return try streamCore(demux: demux, path: "<memory>", chunkFrames: chunkFrames, onChunk: onChunk)
    }

    static func streamCore(
        demux: OggStreamDemuxer,
        path: String,
        chunkFrames: Int,
        onChunk: (_ interleaved: UnsafeBufferPointer<Float>, _ frames: Int, _ sampleRate: Int, _ channels: Int) throws -> Void
    ) throws -> OggDecodeSummary {
        guard chunkFrames > 0, chunkFrames <= 1 << 20 else {
            throw SafariumError.invalidState("chunkFrames must be in 1...1048576")
        }
        let (serial, headers) = try readHeaders(demux)
        let dec = try OggVorbisStreamDecoder(identificationPacket: headers[0], commentPacket: headers[1], setupPacket: headers[2])
        let ch = dec.identification.channels
        let rate = dec.identification.sampleRate

        var chunk = [Float](repeating: 0, count: chunkFrames * ch)
        var fill = 0
        var totalFrames: Int64 = 0
        var peak: Float = 0
        var sumSq: Double = 0
        var nonFinite = 0
        var packets = 0
        var skipLeading: Int64 = 0
        var trimmedLeading: Int64 = 0
        var trimmedTrailing: Int64 = 0
        var absPos: Int64 = 0
        var finalGranule: Int64 = -1

        func flush() throws {
            guard fill > 0 else { return }
            try chunk.withUnsafeBufferPointer { buf in
                try onChunk(UnsafeBufferPointer(rebasing: buf[0..<(fill * ch)]), fill, rate, ch)
            }
            fill = 0
        }

        func process(_ pkt: OggPacket) throws {
            let frames = try dec.decode(packet: pkt.data)
            packets += 1
            guard frames > 0 else { return }
            var start = 0
            var count = frames
            if skipLeading > 0 {
                let d = Int(min(skipLeading, Int64(count)))
                start += d
                count -= d
                skipLeading -= Int64(d)
                trimmedLeading += Int64(d)
            }
            if pkt.pageIsEndOfStream && pkt.pageGranulePosition >= 0 {
                let allowed = max(0, pkt.pageGranulePosition - absPos)
                if Int64(count) > allowed {
                    trimmedTrailing += Int64(count) - allowed
                    count = Int(allowed)
                }
            }
            guard count > 0 else { return }
            try dec.withOutput { chans in
                var src = start
                var remaining = count
                while remaining > 0 {
                    let take = min(remaining, chunkFrames - fill)
                    chunk.withUnsafeMutableBufferPointer { dst in
                        let d = dst.baseAddress!
                        for c in 0..<ch {
                            let s = chans[c]
                            var o = fill * ch + c
                            for i in src..<(src + take) {
                                let v = s[i]
                                d[o] = v
                                o += ch
                                if v.isFinite {
                                    let a = abs(v)
                                    if a > peak { peak = a }
                                    sumSq += Double(v) * Double(v)
                                } else {
                                    nonFinite += 1
                                }
                            }
                        }
                    }
                    fill += take
                    src += take
                    remaining -= take
                    if fill == chunkFrames { try flush() }
                }
            }
            let (nextPos, posOv) = absPos.addingReportingOverflow(Int64(count))
            guard !posOv else {
                throw SafariumError.encode("Ogg Vorbis: PCM sample count overflow")
            }
            absPos = nextPos
            totalFrames += Int64(count)
        }

        var pendingFirstPage: [OggPacket] = []
        var firstPageResolved = false
        while let p = try demux.nextPacket() {
            guard p.serialNumber == serial else { continue }
            if p.pageGranulePosition >= 0 { finalGranule = p.pageGranulePosition }
            if !firstPageResolved {
                pendingFirstPage.append(p)
                guard p.granulePosition != -1 || p.isLastPacketOfStream else { continue }
                var prevBS: Int?
                var total: Int64 = 0
                for q in pendingFirstPage {
                    if let bs = dec.blockSize(ofAudioPacket: q.data) {
                        if let pb = prevBS { total += Int64(pb / 4 + bs / 4) }
                        prevBS = bs
                    }
                }
                let g = p.granulePosition
                if !p.pageIsEndOfStream && g >= 0 {
                    if total > g {
                        skipLeading = total - g
                        absPos = 0
                    } else {
                        absPos = g - total
                    }
                }
                firstPageResolved = true
                for q in pendingFirstPage { try process(q) }
                pendingFirstPage.removeAll()
                continue
            }
            try process(p)
            if p.isLastPacketOfStream { break }
        }
        for q in pendingFirstPage { try process(q) }
        try flush()

        let samples = Double(totalFrames) * Double(ch)
        return OggDecodeSummary(
            path: path,
            sampleRate: rate,
            channels: ch,
            frames: totalFrames,
            audioPackets: packets,
            durationSeconds: Double(totalFrames) / Double(rate),
            peak: peak,
            rms: samples > 0 ? sqrt(sumSq / samples) : 0,
            nonFiniteSamples: nonFinite,
            trimmedLeadingFrames: trimmedLeading,
            trimmedTrailingFrames: trimmedTrailing,
            finalGranulePosition: finalGranule,
            maxChunkFrames: chunkFrames
        )
    }

    // MARK: WAV Writer

    /// Vorbis channel order (§4.3.9) -> WAV/WAVE_FORMAT_EXTENSIBLE order, with channel masks.
    static func wavChannelLayout(_ channels: Int) -> (order: [Int], mask: UInt32) {
        switch channels {
        case 1: return ([0], 0x4)
        case 2: return ([0, 1], 0x3)
        case 3: return ([0, 2, 1], 0x7)
        case 4: return ([0, 1, 2, 3], 0x33)
        case 5: return ([0, 2, 1, 3, 4], 0x37)
        case 6: return ([0, 2, 1, 5, 3, 4], 0x3F)
        case 7: return ([0, 2, 1, 6, 5, 3, 4], 0x70F)
        default: return ([0, 2, 1, 7, 5, 6, 3, 4], 0x63F)
        }
    }

    static func wavHeader(channels: Int, sampleRate: Int, format: OggWAVSampleFormat, frames: Int64) -> (Data, dataSizeOffset: Int, factOffset: Int?) {
        let bits = format == .float32 ? 32 : 16
        let blockAlign = channels * bits / 8
        let dataBytes = UInt32(truncatingIfNeeded: frames * Int64(blockAlign))
        var d = Data()
        func u16(_ v: Int) { d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF)) }
        func u32(_ v: UInt32) { for i in 0..<4 { d.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
        let extensible = channels > 2
        let fmtSize: UInt32 = extensible ? 40 : (format == .float32 ? 18 : 16)
        let hasFact = format == .float32 || extensible
        let riffSize = 4 + (8 + fmtSize) + (hasFact ? 12 : 0) + 8 + dataBytes
        d.append(contentsOf: Array("RIFF".utf8)); u32(riffSize)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(fmtSize)
        u16(extensible ? 0xFFFE : (format == .float32 ? 3 : 1))
        u16(channels)
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * blockAlign))
        u16(blockAlign)
        u16(bits)
        if extensible {
            u16(22)
            u16(bits)
            u32(wavChannelLayout(channels).mask)
            u32(format == .float32 ? 3 : 1)
            d.append(contentsOf: [0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
        } else if format == .float32 {
            u16(0)
        }
        var factOffset: Int?
        if hasFact {
            d.append(contentsOf: Array("fact".utf8)); u32(4)
            factOffset = d.count
            u32(UInt32(truncatingIfNeeded: frames))
        }
        d.append(contentsOf: Array("data".utf8))
        let dataSizeOffset = d.count
        u32(dataBytes)
        return (d, dataSizeOffset, factOffset)
    }

    /// Streams the decode straight to a WAV file at the native rate/channels (bounded RAM, atomic publish).
    @discardableResult
    public static func decodeToWAV(
        url: URL,
        outputURL: URL,
        overwrite: Bool = false,
        format: OggWAVSampleFormat = .float32,
        chunkFrames: Int = 16_384
    ) throws -> OggDecodeSummary {
        try SafeFilePublisher.assertRegularReadableFile(url)
        try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)
        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }
        let tmp = staging.fileURL("decode.wav")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil),
              let fh = FileHandle(forWritingAtPath: tmp.path) else {
            throw SafariumError.encode("Vorbis WAV: cannot create staging file")
        }
        var headerInfo: (data: Data, dataSizeOffset: Int, factOffset: Int?)?
        var written: Int64 = 0
        var layout: [Int] = []
        let summary: OggDecodeSummary
        do {
            summary = try streamToFloat32PCM(url: url, chunkFrames: chunkFrames) { buf, frames, rate, ch in
                if headerInfo == nil {
                    let h = wavHeader(channels: ch, sampleRate: rate, format: format, frames: 0)
                    headerInfo = h
                    layout = wavChannelLayout(ch).order
                    try fh.write(contentsOf: h.0)
                }
                let bytesPerSample = format == .float32 ? 4 : 2
                let sampleCount = frames * ch
                if format == .float32 {
                    var pcmWords = [UInt32](repeating: 0, count: sampleCount)
                    for f in 0..<frames {
                        for c in 0..<ch {
                            pcmWords[f * ch + c] = buf[f * ch + layout[c]].bitPattern.littleEndian
                        }
                    }
                    try pcmWords.withUnsafeBytes { raw in
                        try fh.write(contentsOf: raw)
                    }
                } else {
                    var pcmSamples = [Int16](repeating: 0, count: sampleCount)
                    for f in 0..<frames {
                        for c in 0..<ch {
                            let v = buf[f * ch + layout[c]]
                            let s = max(-32768.0, min(32767.0, (Double(v) * 32768.0).rounded()))
                            pcmSamples[f * ch + c] = Int16(s).littleEndian
                        }
                    }
                    try pcmSamples.withUnsafeBytes { raw in
                        try fh.write(contentsOf: raw)
                    }
                }
                _ = bytesPerSample
                written += Int64(frames)
            }
            guard let headerInfo else {
                throw SafariumError.encode("Vorbis WAV: decoded zero frames from \(url.lastPathComponent)")
            }
            let blockAlign = Int64(summary.channels * (format == .float32 ? 4 : 2))
            guard written * blockAlign < Int64(UInt32.max) - 64 else {
                throw SafariumError.encode("Vorbis WAV: output exceeds 4 GiB RIFF limit")
            }
            let final = wavHeader(channels: summary.channels, sampleRate: summary.sampleRate, format: format, frames: written)
            precondition(final.0.count == headerInfo.data.count)
            try fh.seek(toOffset: 0)
            try fh.write(contentsOf: final.0)
            try fh.close()
        } catch {
            try? fh.close()
            throw error
        }
        try SafeFilePublisher.publish(tempURL: tmp, to: outputURL, overwrite: overwrite)
        return summary
    }
}

// MARK: - Stream Decoder

public final class OggVorbisStreamDecoder {
    public let identification: VorbisIdentificationHeader
    public let comments: VorbisCommentHeader
    let codebooks: [VorbisCodebook]
    let floors: [VorbisFloor]
    let residues: [VorbisResidue]
    let mappings: [VorbisMapping]
    let modes: [VorbisMode]
    private let modeBits: Int
    private let blocksizes: [Int]
    private let imdct: [VorbisIMDCT]
    private let windowShort: [Float]
    private let windowLong: [[[Float]]] // [prevFlag][nextFlag]

    private let channels: Int
    private let maxHalf: Int
    private let floorBuf: UnsafeMutablePointer<Float>
    private let resBuf: UnsafeMutablePointer<Float>
    private let type2Buf: UnsafeMutablePointer<Float>
    private var pcmBuf: UnsafeMutablePointer<Float>
    private var prevBuf: UnsafeMutablePointer<Float>
    private let outBuf: UnsafeMutablePointer<Float>
    private var floorUsed: [Bool]
    private var noResidue: [Bool]
    private var floorY: [Int]
    private var finalY: [Int]
    private var step2: [Bool]
    private var classWork: [Int32]
    private var prevN = 0
    private var hasPrev = false
    private var outFrames = 0

    public init(identificationPacket: Data, commentPacket: Data, setupPacket: Data) throws {
        let id = try OggVorbisDecoder.parseIdentificationHeader(identificationPacket)
        identification = id
        comments = try OggVorbisDecoder.parseCommentHeader(commentPacket)
        channels = id.channels
        blocksizes = [id.blocksize0, id.blocksize1]

        let setupBytes = [UInt8](setupPacket)
        guard setupBytes.count >= 7, setupBytes[0] == 5, Array(setupBytes[1..<7]) == Array("vorbis".utf8) else {
            throw SafariumError.encode("Vorbis setup header: bad packet type/signature")
        }
        var books: [VorbisCodebook] = []
        var floorsOut: [VorbisFloor] = []
        var residuesOut: [VorbisResidue] = []
        var mappingsOut: [VorbisMapping] = []
        var modesOut: [VorbisMode] = []
        let ch = id.channels
        try setupBytes.withUnsafeBytes { raw in
            var r = VorbisBitReader(UnsafeRawBufferPointer(rebasing: raw[7..<raw.count]))
            // Codebooks
            let bookCount = r.readInt(8) + 1
            var totalBookEntries = 0
            for _ in 0..<bookCount {
                let cb = try VorbisCodebook.parse(&r)
                let (nextTotal, totalOv) = totalBookEntries.addingReportingOverflow(cb.entries)
                guard !totalOv, nextTotal <= 4_194_304 else {
                    throw SafariumError.encode("Vorbis setup: cumulative codebook entries exceed limit")
                }
                totalBookEntries = nextTotal
                books.append(cb)
            }
            // Time domain transforms (placeholders)
            let timeCount = r.readInt(6) + 1
            for _ in 0..<timeCount {
                guard r.read(16) == 0 else { throw SafariumError.encode("Vorbis setup: nonzero time-domain transform type") }
            }
            // Floors
            let floorCount = r.readInt(6) + 1
            for _ in 0..<floorCount {
                let type = r.readInt(16)
                switch type {
                case 0:
                    let order = r.readInt(8)
                    let rate = r.readInt(16)
                    let barkMap = r.readInt(16)
                    let ampBits = r.readInt(6)
                    guard ampBits <= 62 else {
                        throw SafariumError.encode("Vorbis floor0: amplitudeBits \(ampBits) exceeds safe bound 62")
                    }
                    let ampOffset = r.readInt(8)
                    let nBooks = r.readInt(4) + 1
                    var list: [Int] = []
                    for _ in 0..<nBooks {
                        let bk = r.readInt(8)
                        guard bk < books.count, books[bk].lookupType != 0, books[bk].dimensions > 0 else {
                            throw SafariumError.encode("Vorbis floor0: invalid book \(bk)")
                        }
                        list.append(bk)
                    }
                    guard order > 0, rate > 0, barkMap > 0 else {
                        throw SafariumError.encode("Vorbis floor0: invalid order/rate/bark map size")
                    }
                    let f = VorbisFloor0(order: order, rate: rate, barkMapSize: barkMap, amplitudeBits: ampBits, amplitudeOffset: ampOffset, books: list)
                    f.prepareMaps(blocksizes: [id.blocksize0, id.blocksize1])
                    floorsOut.append(.type0(f))
                case 1:
                    let partitions = r.readInt(5)
                    var classList: [Int] = []
                    var maxClass = -1
                    for _ in 0..<partitions {
                        let c = r.readInt(4)
                        classList.append(c)
                        maxClass = max(maxClass, c)
                    }
                    var dims: [Int] = []
                    var subs: [Int] = []
                    var masters: [Int] = []
                    var subBooks: [[Int]] = []
                    if maxClass >= 0 {
                        for _ in 0...maxClass {
                            dims.append(r.readInt(3) + 1)
                            let s = r.readInt(2)
                            subs.append(s)
                            var master = -1
                            if s != 0 {
                                master = r.readInt(8)
                                guard master < books.count else { throw SafariumError.encode("Vorbis floor1: invalid masterbook \(master)") }
                            }
                            masters.append(master)
                            var sb: [Int] = []
                            for _ in 0..<(1 << s) {
                                let bk = r.readInt(8) - 1
                                guard bk < books.count else { throw SafariumError.encode("Vorbis floor1: invalid subclass book \(bk)") }
                                sb.append(bk)
                            }
                            subBooks.append(sb)
                        }
                    }
                    let mult = r.readInt(2) + 1
                    let rangeBits = r.readInt(4)
                    var xList = [0, 1 << rangeBits]
                    for c in classList {
                        for _ in 0..<dims[c] { xList.append(r.readInt(rangeBits)) }
                    }
                    guard xList.count <= 65 else { throw SafariumError.encode("Vorbis floor1: too many X values (\(xList.count))") }
                    guard !r.endOfPacket else { throw SafariumError.encode("Vorbis floor1: truncated") }
                    floorsOut.append(.type1(try VorbisFloor1(
                        partitionClassList: classList, classDimensions: dims, classSubclasses: subs,
                        classMasterbooks: masters, subclassBooks: subBooks, multiplier: mult, xList: xList
                    )))
                default:
                    throw SafariumError.encode("Vorbis setup: invalid floor type \(type)")
                }
            }
            // Residues
            let residueCount = r.readInt(6) + 1
            for _ in 0..<residueCount {
                let type = r.readInt(16)
                guard type <= 2 else { throw SafariumError.encode("Vorbis setup: invalid residue type \(type)") }
                let begin = r.readInt(24)
                let end = r.readInt(24)
                let psize = r.readInt(24) + 1
                let classifications = r.readInt(6) + 1
                let classbook = r.readInt(8)
                guard classbook < books.count, books[classbook].dimensions > 0 else {
                    throw SafariumError.encode("Vorbis residue: invalid classbook \(classbook)")
                }
                var cascade: [Int] = []
                for _ in 0..<classifications {
                    let low = r.readInt(3)
                    let high = r.readFlag() ? r.readInt(5) : 0
                    cascade.append(high * 8 + low)
                }
                var rbooks: [[Int]] = []
                for c in 0..<classifications {
                    var row = [Int](repeating: -1, count: 8)
                    for j in 0..<8 where (cascade[c] >> j) & 1 == 1 {
                        let bk = r.readInt(8)
                        guard bk < books.count, books[bk].lookupType != 0, books[bk].dimensions > 0 else {
                            throw SafariumError.encode("Vorbis residue: invalid book \(bk)")
                        }
                        if type == 0 && psize % books[bk].dimensions != 0 {
                            throw SafariumError.encode("Vorbis residue 0: partition size \(psize) not a multiple of book dimension")
                        }
                        row[j] = bk
                    }
                    rbooks.append(row)
                }
                // Classbook must not specify impossible partitioning (libvorbis check).
                var partVals = 1
                for _ in 0..<books[classbook].dimensions {
                    let (nextPart, ov) = partVals.multipliedReportingOverflow(by: classifications)
                    guard !ov, nextPart <= books[classbook].entries else {
                        throw SafariumError.encode("Vorbis residue: classbook cannot encode \(classifications) classes")
                    }
                    partVals = nextPart
                }
                guard !r.endOfPacket else { throw SafariumError.encode("Vorbis residue: truncated") }
                residuesOut.append(VorbisResidue(
                    type: type, begin: begin, end: end, partitionSize: psize, classifications: classifications,
                    classbook: classbook, books: rbooks, partVals: partVals
                ))
            }
            // Mappings
            let mappingCount = r.readInt(6) + 1
            for _ in 0..<mappingCount {
                let type = r.readInt(16)
                guard type == 0 else { throw SafariumError.encode("Vorbis setup: invalid mapping type \(type)") }
                let submaps = r.readFlag() ? r.readInt(4) + 1 : 1
                var mags: [Int] = []
                var angs: [Int] = []
                if r.readFlag() {
                    let steps = r.readInt(8) + 1
                    let bits = vorbisILog(ch - 1)
                    for _ in 0..<steps {
                        let m = r.readInt(bits)
                        let a = r.readInt(bits)
                        guard m != a, m < ch, a < ch else {
                            throw SafariumError.encode("Vorbis mapping: invalid coupling \(m)/\(a)")
                        }
                        mags.append(m)
                        angs.append(a)
                    }
                }
                guard r.read(2) == 0 else { throw SafariumError.encode("Vorbis mapping: reserved bits set") }
                var mux = [Int](repeating: 0, count: ch)
                if submaps > 1 {
                    for j in 0..<ch {
                        mux[j] = r.readInt(4)
                        guard mux[j] < submaps else { throw SafariumError.encode("Vorbis mapping: invalid mux \(mux[j])") }
                    }
                }
                var sf: [Int] = []
                var sr: [Int] = []
                for _ in 0..<submaps {
                    _ = r.read(8)
                    let f = r.readInt(8)
                    let rr = r.readInt(8)
                    guard f < floorsOut.count, rr < residuesOut.count else {
                        throw SafariumError.encode("Vorbis mapping: invalid floor/residue index \(f)/\(rr)")
                    }
                    sf.append(f)
                    sr.append(rr)
                }
                mappingsOut.append(VorbisMapping(submaps: submaps, couplingMagnitude: mags, couplingAngle: angs, mux: mux, submapFloor: sf, submapResidue: sr))
            }
            // Modes
            let modeCount = r.readInt(6) + 1
            for _ in 0..<modeCount {
                let bf = r.readInt(1)
                let wt = r.readInt(16)
                let tt = r.readInt(16)
                let mp = r.readInt(8)
                guard wt == 0, tt == 0 else { throw SafariumError.encode("Vorbis mode: invalid window/transform type \(wt)/\(tt)") }
                guard mp < mappingsOut.count else { throw SafariumError.encode("Vorbis mode: invalid mapping \(mp)") }
                modesOut.append(VorbisMode(blockflag: bf, mapping: mp))
            }
            guard r.read(1) == 1, !r.endOfPacket else {
                throw SafariumError.encode("Vorbis setup header: framing bit not set / truncated")
            }
        }
        codebooks = books
        floors = floorsOut
        residues = residuesOut
        mappings = mappingsOut
        modes = modesOut
        modeBits = vorbisILog(modesOut.count - 1)
        imdct = [try VorbisIMDCT(size: id.blocksize0), try VorbisIMDCT(size: id.blocksize1)]

        // Windows (§4.3.1): sin(π/2 · sin²(...)) slopes; long windows depend on neighbour block sizes.
        func slope(_ len: Int) -> [Float] {
            (0..<len).map { i in
                let s = sin((Double(i) + 0.5) / Double(len) * Double.pi / 2)
                return Float(sin(Double.pi / 2 * s * s))
            }
        }
        func window(n: Int, leftN: Int, rightN: Int) -> [Float] {
            var w = [Float](repeating: 0, count: n)
            let ls = n / 4 - leftN / 2
            let rs = n * 3 / 4 - rightN / 2
            let lsl = slope(leftN)
            let rsl = slope(rightN)
            for i in 0..<leftN { w[ls + i] = lsl[i] }
            for i in (ls + leftN)..<rs { w[i] = 1 }
            for i in 0..<rightN { w[rs + i] = rsl[rightN - 1 - i] }
            return w
        }
        let b0 = id.blocksize0
        let b1 = id.blocksize1
        windowShort = window(n: b0, leftN: b0 / 2, rightN: b0 / 2)
        var wl: [[[Float]]] = []
        for p in 0..<2 {
            var row: [[Float]] = []
            for nx in 0..<2 {
                row.append(window(n: b1, leftN: p == 1 ? b1 / 2 : b0 / 2, rightN: nx == 1 ? b1 / 2 : b0 / 2))
            }
            wl.append(row)
        }
        windowLong = wl

        maxHalf = b1 / 2
        floorBuf = .allocate(capacity: ch * maxHalf)
        resBuf = .allocate(capacity: ch * maxHalf)
        type2Buf = .allocate(capacity: ch * maxHalf)
        pcmBuf = .allocate(capacity: ch * b1)
        prevBuf = .allocate(capacity: ch * b1)
        outBuf = .allocate(capacity: ch * maxHalf)
        floorBuf.initialize(repeating: 0, count: ch * maxHalf)
        resBuf.initialize(repeating: 0, count: ch * maxHalf)
        type2Buf.initialize(repeating: 0, count: ch * maxHalf)
        pcmBuf.initialize(repeating: 0, count: ch * b1)
        prevBuf.initialize(repeating: 0, count: ch * b1)
        outBuf.initialize(repeating: 0, count: ch * maxHalf)
        floorUsed = [Bool](repeating: false, count: ch)
        noResidue = [Bool](repeating: false, count: ch)
        floorY = [Int](repeating: 0, count: 65)
        finalY = [Int](repeating: 0, count: 65)
        step2 = [Bool](repeating: false, count: 65)
        classWork = []
    }

    deinit {
        floorBuf.deallocate()
        resBuf.deallocate()
        type2Buf.deallocate()
        pcmBuf.deallocate()
        prevBuf.deallocate()
        outBuf.deallocate()
    }

    /// Clears overlap state (e.g. after a seek).
    public func reset() {
        hasPrev = false
        prevN = 0
        outFrames = 0
    }

    /// Block size of an audio packet without decoding it; `nil` for non-audio/empty packets.
    public func blockSize(ofAudioPacket data: Data) -> Int? {
        data.withUnsafeBytes { raw -> Int? in
            guard raw.count > 0 else { return nil }
            var r = VorbisBitReader(raw)
            guard r.read(1) == 0 else { return nil }
            let mode = r.readInt(modeBits)
            guard !r.endOfPacket, mode < modes.count else { return nil }
            let bf = modes[mode].blockflag
            if bf == 1 {
                _ = r.read(2)
                if r.endOfPacket { return nil }
            }
            return blocksizes[bf]
        }
    }

    /// Exposes the frames produced by the last `decode` as per-channel buffers.
    public func withOutput<R>(_ body: (_ channels: [UnsafeBufferPointer<Float>]) throws -> R) rethrows -> R {
        let bufs = (0..<channels).map { UnsafeBufferPointer(start: outBuf + $0 * maxHalf, count: outFrames) }
        return try body(bufs)
    }

    /// Decodes one audio packet. Returns the number of finished PCM frames (prevN/4 + n/4,
    /// zero for the very first packet). Non-audio and truncated packets yield zero frames.
    public func decode(packet: Data) throws -> Int {
        try packet.withUnsafeBytes { raw in try decode(raw) }
    }

    func decode(_ raw: UnsafeRawBufferPointer) throws -> Int {
        outFrames = 0
        guard raw.count > 0 else { return 0 }
        var r = VorbisBitReader(raw)
        guard r.read(1) == 0 else { return 0 }
        let modeNumber = r.readInt(modeBits)
        guard !r.endOfPacket else { return 0 }
        guard modeNumber < modes.count else {
            throw SafariumError.encode("Vorbis audio packet: invalid mode number \(modeNumber)")
        }
        let mode = modes[modeNumber]
        let bf = mode.blockflag
        let n = blocksizes[bf]
        let half = n / 2
        var prevFlag = 0
        var nextFlag = 0
        if bf == 1 {
            prevFlag = r.readInt(1)
            nextFlag = r.readInt(1)
            guard !r.endOfPacket else { return 0 }
        }
        let mapping = mappings[mode.mapping]

        // Floors
        for c in 0..<channels {
            let submap = mapping.mux[c]
            let floorOut = floorBuf + c * maxHalf
            switch floors[mapping.submapFloor[submap]] {
            case .type0(let f): floorUsed[c] = decodeFloor0(f, &r, blockflag: bf, half: half, out: floorOut)
            case .type1(let f): floorUsed[c] = decodeFloor1(f, &r, half: half, out: floorOut)
            }
            noResidue[c] = !floorUsed[c]
        }
        for i in 0..<mapping.couplingMagnitude.count {
            let m = mapping.couplingMagnitude[i]
            let a = mapping.couplingAngle[i]
            if !noResidue[m] || !noResidue[a] {
                noResidue[m] = false
                noResidue[a] = false
            }
        }
        // Residues
        vDSP_vclr(resBuf, 1, vDSP_Length(channels * maxHalf))
        for s in 0..<mapping.submaps {
            var chans: [Int] = []
            var dnd: [Bool] = []
            for c in 0..<channels where mapping.mux[c] == s {
                chans.append(c)
                dnd.append(noResidue[c])
            }
            decodeResidue(residues[mapping.submapResidue[s]], chans: chans, doNotDecode: dnd, half: half, &r)
        }
        // Inverse coupling (§7.2.2 polar magnitude/angle)
        var step = mapping.couplingMagnitude.count - 1
        while step >= 0 {
            let mv = resBuf + mapping.couplingMagnitude[step] * maxHalf
            let av = resBuf + mapping.couplingAngle[step] * maxHalf
            for k in 0..<half {
                let mm = mv[k]
                let aa = av[k]
                if mm > 0 {
                    if aa > 0 { av[k] = mm - aa } else { av[k] = mm; mv[k] = mm + aa }
                } else {
                    if aa > 0 { av[k] = mm + aa } else { av[k] = mm; mv[k] = mm - aa }
                }
            }
            step -= 1
        }
        // Dot product, IMDCT, window
        let window: [Float] = bf == 0 ? windowShort : windowLong[prevFlag][nextFlag]
        window.withUnsafeBufferPointer { w in
            for c in 0..<channels {
                let spec = resBuf + c * maxHalf
                let pcm = pcmBuf + c * blocksizes[1]
                if floorUsed[c] {
                    vDSP_vmul(spec, 1, floorBuf + c * maxHalf, 1, spec, 1, vDSP_Length(half))
                    imdct[bf].inverse(spec, pcm)
                    vDSP_vmul(pcm, 1, w.baseAddress!, 1, pcm, 1, vDSP_Length(n))
                } else {
                    vDSP_vclr(pcm, 1, vDSP_Length(n))
                }
            }
        }
        // Overlap-add: output spans previous window centre -> current window centre.
        if hasPrev {
            let total = prevN / 4 + n / 4
            let prevStart = prevN / 2
            let prevCount = min(total, prevN / 2)
            let i0 = prevN / 4 - n / 4
            for c in 0..<channels {
                let out = outBuf + c * maxHalf
                let prev = prevBuf + c * blocksizes[1]
                let cur = pcmBuf + c * blocksizes[1]
                out.update(from: prev + prevStart, count: prevCount)
                if prevCount < total {
                    vDSP_vclr(out + prevCount, 1, vDSP_Length(total - prevCount))
                }
                if i0 >= 0 {
                    vDSP_vadd(out + i0, 1, cur, 1, out + i0, 1, vDSP_Length(total - i0))
                } else {
                    vDSP_vadd(out, 1, cur + (-i0), 1, out, 1, vDSP_Length(total))
                }
            }
            outFrames = total
        }
        swap(&pcmBuf, &prevBuf)
        prevN = n
        hasPrev = true
        return outFrames
    }

    // MARK: Floor 0 (§6)

    private func decodeFloor0(_ f: VorbisFloor0, _ r: inout VorbisBitReader, blockflag: Int, half: Int, out: UnsafeMutablePointer<Float>) -> Bool {
        let amplitude = r.readInt(f.amplitudeBits)
        guard amplitude > 0, !r.endOfPacket else { return false }
        let bookNumber = r.readInt(vorbisILog(f.books.count))
        guard !r.endOfPacket, bookNumber < f.books.count else { return false }
        let book = codebooks[f.books[bookNumber]]
        guard let vq = book.vq else { return false }
        var coeffs: [Float] = []
        coeffs.reserveCapacity(f.order + book.dimensions)
        var last: Float = 0
        while coeffs.count < f.order {
            let e = book.decode(&r)
            guard e >= 0 else { return false }
            for j in 0..<book.dimensions { coeffs.append(vq[e * book.dimensions + j] + last) }
            last = coeffs[coeffs.count - 1]
        }
        let map = f.maps[blockflag]
        let order = f.order
        let ampMax = Double((1 << f.amplitudeBits) - 1)
        var i = 0
        while i < half {
            let omega = Double.pi * Double(map[i]) / Double(f.barkMapSize)
            let cw = cos(omega)
            var p: Double
            var q: Double
            if order % 2 == 1 {
                p = 1 - cw * cw
                var j = 0
                while j <= (order - 3) / 2 && order >= 3 {
                    let t = 4 * (cos(Double(coeffs[2 * j + 1])) - cw)
                    p *= t * (cos(Double(coeffs[2 * j + 1])) - cw)
                    j += 1
                }
                q = 0.25
                j = 0
                while j <= (order - 1) / 2 {
                    let d = cos(Double(coeffs[2 * j])) - cw
                    q *= 4 * d * d
                    j += 1
                }
            } else {
                p = (1 - cw) / 2
                q = (1 + cw) / 2
                var j = 0
                while j <= (order - 2) / 2 {
                    let dp = cos(Double(coeffs[2 * j + 1])) - cw
                    let dq = cos(Double(coeffs[2 * j])) - cw
                    p *= 4 * dp * dp
                    q *= 4 * dq * dq
                    j += 1
                }
            }
            let lin = exp(0.11512925 * (Double(amplitude) * Double(f.amplitudeOffset) / (ampMax * sqrt(p + q)) - Double(f.amplitudeOffset)))
            let cond = map[i]
            let v = Float(lin)
            repeat {
                out[i] = v
                i += 1
            } while i < half && map[i] == cond
        }
        return true
    }

    // MARK: Floor 1 (§7)

    private func decodeFloor1(_ f: VorbisFloor1, _ r: inout VorbisBitReader, half: Int, out: UnsafeMutablePointer<Float>) -> Bool {
        guard r.readFlag() else { return false }
        let range = [256, 128, 86, 64][f.multiplier - 1]
        let ybits = vorbisILog(range - 1)
        floorY[0] = r.readInt(ybits)
        floorY[1] = r.readInt(ybits)
        var offset = 2
        for cls in f.partitionClassList {
            let cdim = f.classDimensions[cls]
            let cbits = f.classSubclasses[cls]
            let csub = (1 << cbits) - 1
            var cval = 0
            if cbits > 0 {
                cval = codebooks[f.classMasterbooks[cls]].decode(&r)
                guard cval >= 0 else { return false }
            }
            for j in 0..<cdim {
                let book = f.subclassBooks[cls][cval & csub]
                cval >>= cbits
                if book >= 0 {
                    let v = codebooks[book].decode(&r)
                    guard v >= 0 else { return false }
                    floorY[offset + j] = v
                } else {
                    floorY[offset + j] = 0
                }
            }
            offset += cdim
        }
        guard !r.endOfPacket else { return false }

        // Step 1: amplitude value synthesis
        let values = f.xList.count
        let x = f.xList
        step2[0] = true
        step2[1] = true
        finalY[0] = floorY[0]
        finalY[1] = floorY[1]
        if values > 2 {
            for i in 2..<values {
                let lo = f.lowNeighbor[i]
                let hi = f.highNeighbor[i]
                let predicted = Self.renderPoint(x[lo], finalY[lo], x[hi], finalY[hi], x[i])
                let val = floorY[i]
                let highroom = range - predicted
                let lowroom = predicted
                let room = highroom < lowroom ? highroom * 2 : lowroom * 2
                if val != 0 {
                    step2[lo] = true
                    step2[hi] = true
                    step2[i] = true
                    if val >= room {
                        finalY[i] = highroom > lowroom ? (val - lowroom + predicted) : (predicted - val + highroom - 1)
                    } else {
                        finalY[i] = (val & 1) == 1 ? (predicted - (val + 1) / 2) : (predicted + val / 2)
                    }
                } else {
                    step2[i] = false
                    finalY[i] = predicted
                }
            }
        }
        // Step 2: curve synthesis
        let mult = f.multiplier
        var lx = 0
        var ly = finalY[f.sortOrder[0]] * mult
        var hx = 0
        var hy = 0
        for idx in 1..<values {
            let k = f.sortOrder[idx]
            if step2[k] {
                hy = finalY[k] * mult
                hx = x[k]
                Self.renderLine(lx, ly, hx, hy, out, half)
                lx = hx
                ly = hy
            }
        }
        if hx < half {
            Self.renderLine(hx, hy, half, hy, out, half)
        }
        return true
    }

    @inline(__always) static func renderPoint(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ x: Int) -> Int {
        let dy = y1 - y0
        let adx = x1 - x0
        let ady = abs(dy)
        let err = ady * (x - x0)
        let off = adx == 0 ? 0 : err / adx
        return dy < 0 ? y0 - off : y0 + off
    }

    /// §9.2.7 render_line writing floor1_inverse_dB_table values for x in [x0, x1) ∩ [0, limit).
    static func renderLine(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ v: UnsafeMutablePointer<Float>, _ limit: Int) {
        guard x1 > x0 else { return }
        let dy = y1 - y0
        let adx = x1 - x0
        var ady = abs(dy)
        let base = dy / adx
        let sy = dy < 0 ? base - 1 : base + 1
        var y = y0
        var err = 0
        ady -= abs(base) * adx
        vorbisFloor1FromDBTable.withUnsafeBufferPointer { t in
            if x0 < limit { v[x0] = t[max(0, min(255, y))] }
            var xx = x0 + 1
            let stop = min(x1, limit)
            while xx < stop {
                err += ady
                if err >= adx {
                    err -= adx
                    y += sy
                } else {
                    y += base
                }
                v[xx] = t[max(0, min(255, y))]
                xx += 1
            }
        }
    }

    // MARK: Residue (§8)

    private func decodeResidue(_ res: VorbisResidue, chans: [Int], doNotDecode: [Bool], half: Int, _ r: inout VorbisBitReader) {
        guard !chans.isEmpty else { return }
        if res.type == 2 {
            guard doNotDecode.contains(false) else { return }
            let nch = chans.count
            let total = half * nch
            vDSP_vclr(type2Buf, 1, vDSP_Length(total))
            decodeResidueCore(res, format: 1, vectors: [type2Buf], doNotDecode: [false], length: total, &r)
            for (j, c) in chans.enumerated() {
                let dst = resBuf + c * maxHalf
                var src = j
                for i in 0..<half {
                    dst[i] = type2Buf[src]
                    src += nch
                }
            }
        } else {
            let vectors = chans.map { resBuf + $0 * maxHalf }
            decodeResidueCore(res, format: res.type, vectors: vectors, doNotDecode: doNotDecode, length: half, &r)
        }
    }

    private func decodeResidueCore(
        _ res: VorbisResidue,
        format: Int,
        vectors: [UnsafeMutablePointer<Float>],
        doNotDecode: [Bool],
        length: Int,
        _ r: inout VorbisBitReader
    ) {
        let classbook = codebooks[res.classbook]
        let cpc = classbook.dimensions
        let limitBegin = min(res.begin, length)
        let limitEnd = min(res.end, length)
        guard limitEnd > limitBegin else { return }
        let psize = res.partitionSize
        let partitionsToRead = (limitEnd - limitBegin) / psize
        guard partitionsToRead > 0 else { return }
        let nch = vectors.count
        let stride = partitionsToRead + cpc
        if classWork.count < nch * stride {
            classWork = [Int32](repeating: 0, count: nch * stride)
        }
        let nClass = res.classifications
        classWork.withUnsafeMutableBufferPointer { cw in
            let classes = cw.baseAddress!
            for pass in 0..<8 {
                var pc = 0
                while pc < partitionsToRead {
                    if pass == 0 {
                        for j in 0..<nch where !doNotDecode[j] {
                            var temp = classbook.decode(&r)
                            if temp < 0 || temp >= res.partVals { return }
                            var i = cpc - 1
                            while i >= 0 {
                                classes[j * stride + pc + i] = Int32(temp % nClass)
                                temp /= nClass
                                i -= 1
                            }
                        }
                    }
                    var i = 0
                    while i < cpc && pc < partitionsToRead {
                        for j in 0..<nch where !doNotDecode[j] {
                            let vqclass = Int(classes[j * stride + pc])
                            let bookIdx = res.books[vqclass][pass]
                            if bookIdx >= 0 {
                                let book = codebooks[bookIdx]
                                let target = vectors[j] + limitBegin + pc * psize
                                if !decodePartition(book, format: format, target: target, psize: psize, &r) { return }
                            }
                        }
                        i += 1
                        pc += 1
                    }
                }
            }
        }
    }

    @inline(__always)
    private func decodePartition(_ book: VorbisCodebook, format: Int, target: UnsafeMutablePointer<Float>, psize: Int, _ r: inout VorbisBitReader) -> Bool {
        guard let vq = book.vq else { return false }
        let dims = book.dimensions
        if format == 0 {
            let step = psize / dims
            for i in 0..<step {
                let e = book.decode(&r)
                if e < 0 { return false }
                let v = vq + e * dims
                for j in 0..<dims { target[i + j * step] += v[j] }
            }
        } else {
            var i = 0
            while i < psize {
                let e = book.decode(&r)
                if e < 0 { return false }
                let v = vq + e * dims
                var j = 0
                while j < dims && i < psize {
                    target[i] += v[j]
                    i += 1
                    j += 1
                }
            }
        }
        return true
    }
}
