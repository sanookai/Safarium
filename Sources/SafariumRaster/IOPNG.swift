// SafariumRaster — own PNG writer (Area C): adaptive row filters + a fast deflate with dynamic Huffman blocks.
//
// Why not ImageIO / Compression.framework: ImageIO's PNG output was 12 % larger than OpenCV's and 2x slower to produce, and
// COMPRESSION_ZLIB costs ~120 ms for a 1080x1920 frame. OpenCV writes every row with the Sub filter through zlib level 1 with
// Z_RLE (measured on 5.1: filter histogram [0, rows, 0, 0, 0], zlib header 78 01). This writer instead
//   * picks the filter per row by the minimum-sum-of-absolute-differences heuristic (vectorised, all five filters),
//   * runs a greedy single-probe LZ77 (4-byte hash, long-run fast path, skip-ahead on incompressible stretches),
//   * writes dynamic Huffman blocks (length-limited codes built per block), falling back to stored blocks,
//   * checksums with a table-driven CRC32 and an adler32 over the filtered stream.
// The output is a plain PNG (signature, IHDR, one IDAT, IEND) that any decoder reads. Level 0 writes stored blocks.
// Deflate/PNG format: RFC 1951, RFC 1950, ISO/IEC 15948 (public specifications; code written from them).

import Foundation
import Accelerate

// MARK: - CRC32 / Adler32

private let crcTables: UnsafeMutablePointer<UInt32> = {
    let t = UnsafeMutablePointer<UInt32>.allocate(capacity: 8 * 256)
    for n in 0..<256 {
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        t[n] = c
    }
    for n in 0..<256 {
        var c = t[n]
        for k in 1..<8 {
            c = t[Int(c & 0xFF)] ^ (c >> 8)
            t[k * 256 + n] = c
        }
    }
    return t
}()

/// Apple's system libz is already loaded in every macOS process and ships NEON/CRC-instruction checksums. Only `adler32` and
/// `crc32` are borrowed (looked up at run time, so there is no link dependency); the deflate stream itself is ours. If the
/// symbols are missing the portable code below runs.
private typealias ZChecksum = @convention(c) (UInt, UnsafePointer<UInt8>?, UInt32) -> UInt
private let sysZ: (adler: ZChecksum, crc: ZChecksum)? = {
    guard let h = dlopen("/usr/lib/libz.1.dylib", RTLD_NOW) ?? dlopen("libz.dylib", RTLD_NOW),
          let a = dlsym(h, "adler32"), let c = dlsym(h, "crc32") else { return nil }
    return (unsafeBitCast(a, to: ZChecksum.self), unsafeBitCast(c, to: ZChecksum.self))
}()

/// CRC-32 (IEEE) over `n` bytes, slicing-by-8. Pass 0 to start; the result of one call can seed the next.
func ioCRC32(_ seed: UInt32, _ p: UnsafePointer<UInt8>, _ n: Int) -> UInt32 {
    if let z = sysZ {
        var crc = UInt(seed), off = 0
        while off < n { let k = min(n - off, 1 << 30); crc = z.crc(crc, p + off, UInt32(k)); off += k }
        return UInt32(truncatingIfNeeded: crc)
    }
    let t = crcTables
    var c = ~seed
    var i = 0
    while i + 8 <= n {
        let a = UnsafeRawPointer(p + i).loadUnaligned(as: UInt32.self) ^ c
        let b = UnsafeRawPointer(p + i + 4).loadUnaligned(as: UInt32.self)
        c = t[7 * 256 + Int(a & 0xFF)] ^ t[6 * 256 + Int((a >> 8) & 0xFF)] ^ t[5 * 256 + Int((a >> 16) & 0xFF)] ^ t[4 * 256 + Int(a >> 24)]
            ^ t[3 * 256 + Int(b & 0xFF)] ^ t[2 * 256 + Int((b >> 8) & 0xFF)] ^ t[256 + Int((b >> 16) & 0xFF)] ^ t[Int(b >> 24)]
        i += 8
    }
    while i < n { c = t[Int((c ^ UInt32(p[i])) & 0xFF)] ^ (c >> 8); i += 1 }
    return ~c
}

func ioAdler32(_ seed: UInt32, _ p: UnsafePointer<UInt8>, _ n: Int) -> UInt32 {
    if let z = sysZ {
        var ad = UInt(seed), off = 0
        while off < n { let k = min(n - off, 1 << 30); ad = z.adler(ad, p + off, UInt32(k)); off += k }
        return UInt32(truncatingIfNeeded: ad)
    }
    var a = seed & 0xFFFF, b = seed >> 16
    var i = 0
    while i < n {
        let end = min(n, i + 5552)
        // 16 bytes per step: s1 gets the byte sum; s2 gets the position-weighted sum + 16 * s1 (before)
        while i + 16 <= end {
            let v = SIMD16<UInt16>(truncatingIfNeeded: UnsafeRawPointer(p + i).loadUnaligned(as: SIMD16<UInt8>.self))
            let w = SIMD16<UInt16>(16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1)
            let lo = SIMD8<UInt32>(truncatingIfNeeded: (v &* w).lowHalf) &+ SIMD8<UInt32>(truncatingIfNeeded: (v &* w).highHalf)
            b &+= 16 &* a &+ UInt32(truncatingIfNeeded: lo.wrappedSum())
            a &+= UInt32(truncatingIfNeeded: SIMD16<UInt32>(truncatingIfNeeded: v).wrappedSum())
            i += 16
        }
        while i < end { a &+= UInt32(p[i]); b &+= a; i += 1 }
        a %= 65521
        b %= 65521
    }
    return (b << 16) | a
}

/// A match must beat plain Huffman-coded literals: residual bytes cost ~3-4 bits each, a match 20+ bits, so short far
/// matches are skipped. Minimum lengths by distance (tuned on real reel frames and photo-like content): <= 4 (runs / pixel
/// repeats) 7, <= 256 14, farther 20.
private let matchNeed: (near: Int, mid: Int, far: Int) = (7, 14, 20)
/// Same idea for the hash-chain tiers, whose search is deeper and so finds fewer useless short matches.
private let chainBias: Float = {
    if let e = ProcessInfo.processInfo.environment["SR_PNG_BIAS"], let v = Float(e) { return v }
    return 1.0
}()

// MARK: - Deflate tables

private let lenBase: [Int] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
private let lenExtra: [Int] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
private let distBase: [Int] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
                               4097, 6145, 8193, 12289, 16385, 24577]
private let distExtra: [Int] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
private let clOrder: [Int] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

/// length (3...258) -> length code index 0...28
private let lenCodeOf: [UInt8] = {
    var t = [UInt8](repeating: 0, count: 259)
    for c in 0..<29 {
        let hi = c == 28 ? 258 : lenBase[c + 1] - 1
        for l in lenBase[c]...hi { t[l] = UInt8(c) }
    }
    t[258] = 28
    return t
}()

/// distance-1 (0...32767) -> distance code, via the zlib split table (direct below 256, >> 7 above)
private let distCodeOf: [UInt8] = {
    var t = [UInt8](repeating: 0, count: 512)
    for c in 0..<30 {
        let lo = distBase[c] - 1
        let hi = c == 29 ? 32767 : distBase[c + 1] - 2
        var d = lo
        while d <= hi {
            if d < 256 { t[d] = UInt8(c) } else { t[256 + (d >> 7)] = UInt8(c) }
            d += d < 256 ? 1 : 128
        }
    }
    return t
}()

// MARK: - Huffman

/// Length-limited Huffman code lengths for `freq[0..<n]` (symbols with zero frequency get length 0).
func huffmanLengths(_ freq: UnsafePointer<Int32>, _ n: Int, maxLen: Int, _ lens: UnsafeMutablePointer<UInt8>) {
    for i in 0..<n { lens[i] = 0 }
    var syms: [(f: Int, s: Int)] = []
    for i in 0..<n where freq[i] > 0 { syms.append((Int(freq[i]), i)) }
    if syms.isEmpty { return }
    if syms.count == 1 { lens[syms[0].s] = 1; return }
    syms.sort { $0.f != $1.f ? $0.f < $1.f : $0.s < $1.s }
    let m = syms.count
    // two-queue construction: leaves in `syms` order, internal nodes appended in creation order
    var weight = [Int](repeating: 0, count: 2 * m)
    var parent = [Int](repeating: 0, count: 2 * m)
    for i in 0..<m { weight[i] = syms[i].f }
    var leaf = 0, node = m, internalHead = m
    for _ in 0..<(m - 1) {
        var picks = [0, 0]
        for k in 0..<2 {
            if leaf < m && (internalHead >= node || weight[leaf] <= weight[internalHead]) { picks[k] = leaf; leaf += 1 }
            else { picks[k] = internalHead; internalHead += 1 }
        }
        weight[node] = weight[picks[0]] + weight[picks[1]]
        parent[picks[0]] = node
        parent[picks[1]] = node
        node += 1
    }
    var depth = [Int](repeating: 0, count: 2 * m)
    var idx = node - 2
    while idx >= 0 { depth[idx] = depth[parent[idx]] + 1; idx -= 1 }
    // count per length, then enforce the limit (miniz-style Kraft repair)
    var numCodes = [Int](repeating: 0, count: maxLen + 1)
    for i in 0..<m { numCodes[min(depth[i], maxLen)] += 1 }
    var total = 0
    for l in 1...maxLen { total += numCodes[l] << (maxLen - l) }
    while total > (1 << maxLen) {
        numCodes[maxLen] -= 1
        var l = maxLen - 1
        while l > 0 {
            if numCodes[l] > 0 { numCodes[l] -= 1; numCodes[l + 1] += 2; break }
            l -= 1
        }
        total -= 1
    }
    // rarest symbols (front of `syms`) take the longest lengths
    var k = 0
    var l = maxLen
    while l >= 1 {
        for _ in 0..<numCodes[l] { lens[syms[k].s] = UInt8(l); k += 1 }
        l -= 1
    }
}

/// Canonical codes (bit-reversed for LSB-first output), packed as code | len << 16.
func canonicalCodes(_ lens: UnsafePointer<UInt8>, _ n: Int, _ out: UnsafeMutablePointer<UInt32>) {
    var blCount = [Int](repeating: 0, count: 17)
    for i in 0..<n { blCount[Int(lens[i])] += 1 }
    blCount[0] = 0
    var next = [Int](repeating: 0, count: 17)
    var code = 0
    for b in 1...16 { code = (code + blCount[b - 1]) << 1; next[b] = code }
    for i in 0..<n {
        let l = Int(lens[i])
        if l == 0 { out[i] = 0; continue }
        let c = next[l]; next[l] += 1
        var r = 0
        for b in 0..<l where (c >> b) & 1 == 1 { r |= 1 << (l - 1 - b) }
        out[i] = UInt32(r) | UInt32(l) << 16
    }
}

// MARK: - Deflate

final class IODeflate {
    static let window = 32768
    static let hashBits = 15
    static let maxTokens = 1 << 13

    private(set) var out: UnsafeMutablePointer<UInt8>
    private(set) var pos: Int
    private var cap: Int
    private var acc: UInt64 = 0
    private var nbits = 0

    private let buf: UnsafeMutablePointer<UInt8>
    private let bufCap: Int
    private var fill = 0          // valid bytes in buf
    private var done = 0          // bytes already tokenised
    private var base = 0          // absolute stream index of buf[0]
    private let head: UnsafeMutablePointer<Int32>
    private let chainPrev: UnsafeMutablePointer<Int32>   // hash chains for the denser tiers (level >= 2), indexed by absolute position & 0x7FFF
    private let tokens: UnsafeMutablePointer<UInt64>
    private let histo: UnsafeMutablePointer<Int32>
    private var litCursor = 0     // buf index just after the last match of the current block
    private var nextFlushAt = 0
    static let blockSpan = 1 << 17
    private var tokenCount = 0
    private var blockStart = 0    // buf index where the current token block begins
    private let litFreq: UnsafeMutablePointer<Int32>
    private let distFreq: UnsafeMutablePointer<Int32>
    private let level: Int
    private var litCost: Float = 6.0   // average bits per literal in the previous block (drives the match/literal decision of the chain tiers)
    private let strategy: Int      // IMWRITE_PNG_STRATEGY: 0 default, 1 filtered, 2 huffman only, 3 RLE, 4 fixed codes
    private(set) var adler: UInt32 = 1

    private let lenCode: UnsafeMutablePointer<UInt8>
    private let distCode: UnsafeMutablePointer<UInt8>
    private let lenBaseP: UnsafeMutablePointer<Int>
    private let lenExtraP: UnsafeMutablePointer<Int>
    private let distBaseP: UnsafeMutablePointer<Int>
    private let distExtraP: UnsafeMutablePointer<Int>

    /// `prefix` bytes at the start of `out` are left for the caller (PNG header chunks).
    init(level: Int, prefix: Int, chunkBytes: Int, strategy: Int = 0) {
        self.level = level
        self.strategy = strategy
        cap = max(1 << 16, prefix + chunkBytes)
        out = UnsafeMutablePointer<UInt8>.allocate(capacity: cap + 64)
        pos = prefix
        bufCap = IODeflate.window + chunkBytes + 1024
        buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufCap + 16)
        head = UnsafeMutablePointer<Int32>.allocate(capacity: 1 << IODeflate.hashBits)
        head.initialize(repeating: -1, count: 1 << IODeflate.hashBits)
        chainPrev = UnsafeMutablePointer<Int32>.allocate(capacity: IODeflate.window)
        chainPrev.initialize(repeating: -1, count: IODeflate.window)
        tokens = UnsafeMutablePointer<UInt64>.allocate(capacity: IODeflate.maxTokens + 300)
        histo = UnsafeMutablePointer<Int32>.allocate(capacity: 1024)
        nextFlushAt = IODeflate.blockSpan
        litFreq = UnsafeMutablePointer<Int32>.allocate(capacity: 288)
        distFreq = UnsafeMutablePointer<Int32>.allocate(capacity: 32)
        litFreq.initialize(repeating: 0, count: 288)
        distFreq.initialize(repeating: 0, count: 32)
        lenCode = UnsafeMutablePointer<UInt8>.allocate(capacity: 259)
        for i in 0..<259 { lenCode[i] = lenCodeOf[i] }
        distCode = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
        for i in 0..<512 { distCode[i] = distCodeOf[i] }
        lenBaseP = UnsafeMutablePointer<Int>.allocate(capacity: 29)
        lenExtraP = UnsafeMutablePointer<Int>.allocate(capacity: 29)
        distBaseP = UnsafeMutablePointer<Int>.allocate(capacity: 30)
        distExtraP = UnsafeMutablePointer<Int>.allocate(capacity: 30)
        for i in 0..<29 { lenBaseP[i] = lenBase[i]; lenExtraP[i] = lenExtra[i] }
        for i in 0..<30 { distBaseP[i] = distBase[i]; distExtraP[i] = distExtra[i] }
        // zlib header: deflate, 32 KiB window, fastest-algorithm flag (same bytes as OpenCV's level-1 output: 78 01)
        out[pos] = 0x78; out[pos + 1] = 0x01
        pos += 2
    }

    deinit {
        out.deallocate(); buf.deallocate(); head.deallocate(); chainPrev.deallocate(); tokens.deallocate(); histo.deallocate(); litFreq.deallocate(); distFreq.deallocate()
        lenCode.deallocate(); distCode.deallocate(); lenBaseP.deallocate(); lenExtraP.deallocate(); distBaseP.deallocate(); distExtraP.deallocate()
    }

    /// Space for `n` more input bytes at the end of the window (slides the window when needed). Call `commit` after writing.
    func reserve(_ n: Int) -> UnsafeMutablePointer<UInt8> {
        if fill + n > bufCap {
            compress(final: false)
            if level != 0 { flushBlock(upTo: fill, final: false) }  // the token block still reads the raw bytes we are about to move
            let keep = min(IODeflate.window, fill)
            memmove(buf, buf + (fill - keep), keep)
            base += fill - keep
            done = keep
            fill = keep
            blockStart = keep
            litCursor = keep
            nextFlushAt = keep + IODeflate.blockSpan
        }
        return buf + fill
    }

    func commit(_ n: Int) {
        adler = ioAdler32(adler, buf + fill, n)
        fill += n
    }

    var pending: Int { fill - done }

    // ---- output bits
    @inline(__always) private func put(_ value: UInt32, _ len: Int) {
        acc |= UInt64(value) << UInt64(nbits)
        nbits += len
        if nbits >= 32 {
            UnsafeMutableRawPointer(out + pos).storeBytes(of: UInt32(truncatingIfNeeded: acc), as: UInt32.self)
            pos += 4
            acc >>= 32
            nbits -= 32
        }
    }

    private func ensure(_ extra: Int) {
        if pos + extra + 64 > cap {
            cap = max(cap * 2, pos + extra + 64)
            let n = UnsafeMutablePointer<UInt8>.allocate(capacity: cap + 64)
            memcpy(n, out, pos)
            out.deallocate()
            out = n
        }
    }

    private func alignByte() {
        if nbits % 8 != 0 { put(0, 8 - nbits % 8) }
        while nbits >= 8 {
            out[pos] = UInt8(truncatingIfNeeded: acc); pos += 1
            acc >>= 8; nbits -= 8
        }
    }

    // ---- tokenisation
    // Literals are implicit: a token only describes a match plus how many literal bytes precede it. The literal bytes stay in
    // `buf` until the block is flushed, so no per-literal token or frequency work happens while searching.
    /// Tokenise everything that is pending, flushing blocks as they fill.
    func compress(final: Bool) {
        if level == 0 {
            storeAll(final: final)
            return
        }
        let end = fill
        var i = done
        let b = buf
        var misses = 0
        let lastHash = end - 4
        if (level >= 2 && (strategy == 0 || strategy == 1 || strategy == 4)) || strategy == 1 || strategy == 4 {
            compressChain(final: final)   // Z_FILTERED / Z_FIXED always use the deeper matcher (like zlib's, which is never a single-probe)
            return
        }
        if strategy == 2 {
            // Z_HUFFMAN_ONLY: no matching, literals only (blocks are cut every blockSpan bytes)
            while end - blockStart >= IODeflate.blockSpan { flushBlock(upTo: blockStart + IODeflate.blockSpan, final: false) }
            done = end
            if final { flushBlock(upTo: end, final: true) }
            return
        }
        while i < end {
            if i > lastHash { break }  // the last few bytes can only be literals
            let v = UnsafeRawPointer(b + i).loadUnaligned(as: UInt32.self)
            let h = Int((v &* 0x9E37_79B1) >> UInt32(32 - IODeflate.hashBits))
            var cand = strategy == 3 ? i - 1 : Int(head[h]) - base   // Z_RLE: only distance-1 matches
            head[h] = Int32(truncatingIfNeeded: base + i)
            if cand >= 0, cand < i, i - cand <= IODeflate.window, UnsafeRawPointer(b + cand).loadUnaligned(as: UInt32.self) == v {
                var start = i
                // extend backwards over bytes that were skipped while searching (never into the previous match)
                while start > litCursor && cand > 0 && start > i - 8 && b[start - 1] == b[cand - 1] { start -= 1; cand -= 1 }
                var len = 4 + (i - start)
                let maxLen = min(258, end - start)
                while len + 8 <= maxLen {
                    let x = UnsafeRawPointer(b + cand + len).loadUnaligned(as: UInt64.self) ^ UnsafeRawPointer(b + start + len).loadUnaligned(as: UInt64.self)
                    if x != 0 { len += x.trailingZeroBitCount >> 3; break }
                    len += 8
                }
                if len > maxLen { len = maxLen }
                while len < maxLen && b[cand + len] == b[start + len] { len += 1 }
                let dist = start - cand
                let need = dist <= 4 ? matchNeed.near : (dist <= 256 ? matchNeed.mid : matchNeed.far)
                if len >= need {
                    tokens[tokenCount] = UInt64(start - litCursor) << 24 | UInt64(len - 3) << 15 | UInt64(dist - 1)
                    tokenCount += 1
                    litFreq[257 + Int(lenCode[len])] += 1
                    let d = dist - 1
                    distFreq[Int(d < 256 ? distCode[d] : distCode[256 + (d >> 7)])] += 1
                    litCursor = start + len
                    // index a few positions inside the match
                    let stop = min(litCursor, lastHash + 1)
                    var j = i + 1
                    let limit = min(stop, i + 7)
                    while j < limit {
                        let vj = UnsafeRawPointer(b + j).loadUnaligned(as: UInt32.self)
                        head[Int((vj &* 0x9E37_79B1) >> UInt32(32 - IODeflate.hashBits))] = Int32(truncatingIfNeeded: base + j)
                        j += 1
                    }
                    i = litCursor
                    misses = 0
                    if tokenCount >= IODeflate.maxTokens || i >= nextFlushAt { flushBlock(upTo: i, final: false) }
                    continue
                }
            }
            misses += 1
            i += misses < 16 ? 1 : (misses < 48 ? 2 : (misses < 128 ? 4 : 8))  // skipped bytes are literals at no cost
            if i >= nextFlushAt { flushBlock(upTo: min(i, end), final: false) }
        }
        done = end
        if final { flushBlock(upTo: end, final: true) }
    }


    // ---- denser tiers: hash chains + lazy matching (levels 2...9)
    /// (chain depth, lazy matching, "good enough" length) per level.
    private var tier: (depth: Int, lazy: Bool, nice: Int) {
        switch max(level, 3) {
        case 2: return (8, false, 32)
        case 3: return (16, true, 32)
        case 4: return (32, true, 64)
        case 5: return (48, true, 96)
        case 6: return (96, true, 128)
        case 7: return (192, true, 192)
        case 8: return (384, true, 258)
        default: return (1024, true, 258)
        }
    }

    private func compressChain(final: Bool) {
        let (depth, lazy, nice) = tier
        let end = fill
        var i = done
        let b = buf
        let lastHash = end - 4
        let mask = IODeflate.window - 1
        let shiftBits = UInt32(32 - IODeflate.hashBits)
        var pendLen = 0, pendDist = 0, pendPos = 0

        @inline(__always) func insert(_ pos: Int) {
            let v = UnsafeRawPointer(b + pos).loadUnaligned(as: UInt32.self)
            let h = Int((v &* 0x9E37_79B1) >> shiftBits)
            chainPrev[(base + pos) & mask] = head[h]
            head[h] = Int32(truncatingIfNeeded: base + pos)
        }
        /// Longest match at `pos` (length >= 4) through the hash chain; also links `pos` into the chain.
        @inline(__always) func longest(_ pos: Int) -> (Int, Int) {
            let v = UnsafeRawPointer(b + pos).loadUnaligned(as: UInt32.self)
            let h = Int((v &* 0x9E37_79B1) >> shiftBits)
            var cand = Int(head[h]) - base
            let maxLen = min(258, end - pos)
            var best = 3, bestDist = 0
            var chain = depth
            while cand >= 0, cand < pos, pos - cand <= IODeflate.window {
                if b[cand + best] == b[pos + best], UnsafeRawPointer(b + cand).loadUnaligned(as: UInt32.self) == v {
                    var len = 4
                    while len + 8 <= maxLen {
                        let x = UnsafeRawPointer(b + cand + len).loadUnaligned(as: UInt64.self) ^ UnsafeRawPointer(b + pos + len).loadUnaligned(as: UInt64.self)
                        if x != 0 { len += x.trailingZeroBitCount >> 3; break }
                        len += 8
                    }
                    if len > maxLen { len = maxLen }
                    while len < maxLen && b[cand + len] == b[pos + len] { len += 1 }
                    if len > best {
                        best = len; bestDist = pos - cand
                        if len >= nice || len == maxLen { break }
                    }
                }
                chain -= 1
                if chain == 0 { break }
                cand = Int(chainPrev[(base + cand) & mask]) - base
            }
            chainPrev[(base + pos) & mask] = head[h]
            head[h] = Int32(truncatingIfNeeded: base + pos)
            if best < 4 { return (0, 0) }
            // take the match only when it is cheaper than the literals it replaces (cost of the previous block's literal code)
            let matchBits = 9.0 + Float(bestDist.bitWidth - bestDist.leadingZeroBitCount)
            return Float(best) * litCost >= matchBits * chainBias ? (best, bestDist) : (0, 0)
        }
        func emit(_ start: Int, _ len: Int, _ dist: Int) {
            tokens[tokenCount] = UInt64(start - litCursor) << 24 | UInt64(len - 3) << 15 | UInt64(dist - 1)
            tokenCount += 1
            litFreq[257 + Int(lenCode[len])] += 1
            let d = dist - 1
            distFreq[Int(d < 256 ? distCode[d] : distCode[256 + (d >> 7)])] += 1
            litCursor = start + len
            if tokenCount >= IODeflate.maxTokens || litCursor >= nextFlushAt { flushBlock(upTo: litCursor, final: false) }
        }

        while i <= lastHash {
            let (len, dist) = longest(i)
            if pendLen > 0 {
                if len > pendLen {
                    pendLen = len; pendDist = dist; pendPos = i   // the earlier position becomes a literal
                    i += 1
                    continue
                }
                emit(pendPos, pendLen, pendDist)
                let matchEnd = pendPos + pendLen
                var j = i + 1
                while j < matchEnd && j <= lastHash { insert(j); j += 1 }
                i = matchEnd
                pendLen = 0
                continue
            }
            if len >= 4 {
                if lazy && len < nice {
                    pendLen = len; pendDist = dist; pendPos = i
                    i += 1
                    continue
                }
                emit(i, len, dist)
                var j = i + 1
                while j < i + len && j <= lastHash { insert(j); j += 1 }
                i += len
                continue
            }
            i += 1
        }
        if pendLen > 0 { emit(pendPos, pendLen, pendDist) }
        done = end
        if final { flushBlock(upTo: end, final: true) }
    }

    // ---- block output
    private func histogram(_ p: UnsafePointer<UInt8>, _ n: Int, _ h: UnsafeMutablePointer<Int32>) {
        var j = 0
        while j + 4 <= n {
            h[Int(p[j])] += 1
            h[256 + Int(p[j + 1])] += 1
            h[512 + Int(p[j + 2])] += 1
            h[768 + Int(p[j + 3])] += 1
            j += 4
        }
        while j < n { h[Int(p[j])] += 1; j += 1 }
    }

    private func flushBlock(upTo end: Int, final: Bool) {
        let rawBytes = end - blockStart
        defer {
            tokenCount = 0
            litFreq.update(repeating: 0, count: 288)
            distFreq.update(repeating: 0, count: 32)
            blockStart = end
            litCursor = end
            nextFlushAt = end + IODeflate.blockSpan
        }
        if rawBytes <= 0 && !final { return }
        // literal histogram over the runs between matches
        histo.update(repeating: 0, count: 1024)
        var cursor = blockStart
        for k in 0..<tokenCount {
            let tk = tokens[k]
            let run = Int(tk >> 24)
            histogram(buf + cursor, run, histo)
            cursor += run + Int((tk >> 15) & 0xFF) + 3
        }
        let tail = end - cursor
        if tail > 0 { histogram(buf + cursor, tail, histo) }
        for c in 0..<256 { litFreq[c] += histo[c] + histo[256 + c] + histo[512 + c] + histo[768 + c] }
        litFreq[256] = 1
        let litLens = UnsafeMutablePointer<UInt8>.allocate(capacity: 288)
        let distLens = UnsafeMutablePointer<UInt8>.allocate(capacity: 32)
        let litCodes = UnsafeMutablePointer<UInt32>.allocate(capacity: 288)
        let distCodes = UnsafeMutablePointer<UInt32>.allocate(capacity: 32)
        defer { litLens.deallocate(); distLens.deallocate(); litCodes.deallocate(); distCodes.deallocate() }
        if strategy == 4 {
            // Z_FIXED: the predefined code of RFC 1951 3.2.6, no header at all
            for i in 0..<288 { litLens[i] = i < 144 ? 8 : (i < 256 ? 9 : (i < 280 ? 7 : 8)) }
            for i in 0..<30 { distLens[i] = 5 }
            canonicalCodes(litLens, 288, litCodes)
            canonicalCodes(distLens, 30, distCodes)
            ensure(rawBytes * 2 + tokenCount * 8 + 2048)
            put(final ? 1 : 0, 1)
            put(1, 2)
            writeTokens(litCodes, distCodes, end: end)
            return
        }
        huffmanLengths(litFreq, 286, maxLen: 15, litLens)
        do {
            var bitsSum = 0, cnt = 0
            for c in 0..<256 { bitsSum += Int(litLens[c]) * Int(litFreq[c]); cnt += Int(litFreq[c]) }
            if cnt > 64 { litCost = max(1.2, Float(bitsSum) / Float(cnt)) }
        }
        if (0..<30).allSatisfy({ distFreq[$0] == 0 }) { distFreq[0] = 1 }
        huffmanLengths(distFreq, 30, maxLen: 15, distLens)
        canonicalCodes(litLens, 286, litCodes)
        canonicalCodes(distLens, 30, distCodes)

        var hlit = 286
        while hlit > 257 && litLens[hlit - 1] == 0 { hlit -= 1 }
        var hdist = 30
        while hdist > 1 && distLens[hdist - 1] == 0 { hdist -= 1 }
        // run-length encode the code lengths (symbols 16/17/18)
        var seq = [UInt8](), extra = [UInt8]()
        var lengths = [UInt8](); for i in 0..<hlit { lengths.append(litLens[i]) }; for i in 0..<hdist { lengths.append(distLens[i]) }
        var r = 0
        while r < lengths.count {
            let v = lengths[r]
            var run = 1
            while r + run < lengths.count && lengths[r + run] == v { run += 1 }
            if v == 0 && run >= 3 {
                let n = min(run, 138)
                if n >= 11 { seq.append(18); extra.append(UInt8(n - 11)) } else { seq.append(17); extra.append(UInt8(n - 3)) }
                r += n
            } else if v != 0 && run >= 4 {
                seq.append(v); extra.append(0)
                let left = min(run - 1, 6)
                seq.append(16); extra.append(UInt8(left - 3))
                r += 1 + left
            } else {
                seq.append(v); extra.append(0)
                r += 1
            }
        }
        let clFreq = UnsafeMutablePointer<Int32>.allocate(capacity: 19)
        clFreq.initialize(repeating: 0, count: 19)
        for s in seq { clFreq[Int(s)] += 1 }
        let clLens = UnsafeMutablePointer<UInt8>.allocate(capacity: 19)
        let clCodes = UnsafeMutablePointer<UInt32>.allocate(capacity: 19)
        defer { clFreq.deallocate(); clLens.deallocate(); clCodes.deallocate() }
        huffmanLengths(clFreq, 19, maxLen: 7, clLens)
        canonicalCodes(clLens, 19, clCodes)
        var hclen = 19
        while hclen > 4 && clLens[clOrder[hclen - 1]] == 0 { hclen -= 1 }

        // size comparison: dynamic block vs stored
        var bits = 3 + 5 + 5 + 4 + 3 * hclen
        for s in seq { bits += Int(clLens[Int(s)]) + (s == 16 ? 2 : (s == 17 ? 3 : (s == 18 ? 7 : 0))) }
        for s in 0..<286 where litFreq[s] > 0 {
            var l = Int(litLens[s]) * Int(litFreq[s])
            if s >= 257 { l += lenExtra[s - 257] * Int(litFreq[s]) }
            bits += l
        }
        for s in 0..<30 where distFreq[s] > 0 { bits += (Int(distLens[s]) + distExtra[s]) * Int(distFreq[s]) }
        let storedBits = (rawBytes + 5 * ((rawBytes + 65534) / 65535)) * 8
        if bits > storedBits + 64 && rawBytes > 0 {
            writeStored(from: blockStart, count: rawBytes, final: final)
            return
        }

        ensure(rawBytes * 2 + tokenCount * 8 + 2048)
        put(final ? 1 : 0, 1)
        put(2, 2)
        put(UInt32(hlit - 257), 5)
        put(UInt32(hdist - 1), 5)
        put(UInt32(hclen - 4), 4)
        for k in 0..<hclen { put(UInt32(clLens[clOrder[k]]), 3) }
        for (k, s) in seq.enumerated() {
            let c = clCodes[Int(s)]
            put(c & 0xFFFF, Int(c >> 16))
            if s == 16 { put(UInt32(extra[k]), 2) } else if s == 17 { put(UInt32(extra[k]), 3) } else if s == 18 { put(UInt32(extra[k]), 7) }
        }
        writeTokens(litCodes, distCodes, end: end)
    }

    private func writeTokens(_ litCodes: UnsafeMutablePointer<UInt32>, _ distCodes: UnsafeMutablePointer<UInt32>, end: Int) {
        var cursor = blockStart
        // literal runs: two literals per put (<= 30 bits), matches in two parts
        @inline(__always) func emitLiterals(_ p: UnsafePointer<UInt8>, _ n: Int) {
            var j = 0
            while j + 4 <= n {
                let a = litCodes[Int(p[j])], b = litCodes[Int(p[j + 1])], c = litCodes[Int(p[j + 2])], d = litCodes[Int(p[j + 3])]
                let la = Int(a >> 16), lb = Int(b >> 16), lc = Int(c >> 16), ld = Int(d >> 16)
                put((a & 0xFFFF) | (b & 0xFFFF) << UInt32(la), la + lb)
                put((c & 0xFFFF) | (d & 0xFFFF) << UInt32(lc), lc + ld)
                j += 4
            }
            while j < n {
                let a = litCodes[Int(p[j])]
                put(a & 0xFFFF, Int(a >> 16))
                j += 1
            }
        }
        for k in 0..<tokenCount {
            let tk = tokens[k]
            let run = Int(tk >> 24)
            emitLiterals(buf + cursor, run)
            cursor += run
            let len = Int((tk >> 15) & 0xFF) + 3
            let d = Int(tk & 0x7FFF)
            let lc = Int(lenCode[len])
            let lcode = litCodes[257 + lc]
            put((lcode & 0xFFFF) | UInt32(len - lenBaseP[lc]) << (lcode >> 16), Int(lcode >> 16) + lenExtraP[lc])
            let dc = Int(d < 256 ? distCode[d] : distCode[256 + (d >> 7)])
            let dcode = distCodes[dc]
            put((dcode & 0xFFFF) | UInt32(d + 1 - distBaseP[dc]) << (dcode >> 16), Int(dcode >> 16) + distExtraP[dc])
            cursor += len
        }
        emitLiterals(buf + cursor, end - cursor)
        let eob = litCodes[256]
        put(eob & 0xFFFF, Int(eob >> 16))
    }

    private func writeStored(from start: Int, count: Int, final: Bool) {
        var p = start
        var left = count
        ensure(count + 64 + 5 * (count / 65535 + 1))
        repeat {
            let n = min(left, 65535)
            let last = final && n == left
            put(last ? 1 : 0, 1)
            put(0, 2)
            alignByte()
            out[pos] = UInt8(n & 0xFF); out[pos + 1] = UInt8(n >> 8)
            out[pos + 2] = UInt8(~n & 0xFF); out[pos + 3] = UInt8((~n >> 8) & 0xFF)
            pos += 4
            memcpy(out + pos, buf + p, n)
            pos += n
            p += n
            left -= n
        } while left > 0
    }

    /// Level 0: stored blocks only.
    private func storeAll(final: Bool) {
        let n = fill - done
        if n > 0 || final {
            if n == 0 { ensure(16); put(1, 1); put(0, 2); alignByte(); out[pos] = 0; out[pos + 1] = 0; out[pos + 2] = 0xFF; out[pos + 3] = 0xFF; pos += 4 }
            else { writeStored(from: done, count: n, final: final) }
        }
        done = fill
        blockStart = fill
    }

    /// Flush the last block, the byte padding and the adler32; returns the end of the zlib stream in `out`.
    func finish() -> Int {
        compress(final: true)
        alignByte()
        ensure(8)
        out[pos] = UInt8(adler >> 24); out[pos + 1] = UInt8((adler >> 16) & 0xFF)
        out[pos + 2] = UInt8((adler >> 8) & 0xFF); out[pos + 3] = UInt8(adler & 0xFF)
        pos += 4
        ensure(64)  // room for the PNG trailer (CRC + IEND): the buffer must not move after `finish` returns
        return pos
    }

    func reserveOutput(_ extra: Int) { ensure(extra) }
    func appendOutput(_ bytes: [UInt8]) {
        ensure(bytes.count)
        for b in bytes { out[pos] = b; pos += 1 }
    }
}

// MARK: - PNG

/// Encode a u8 gray / BGR / BGRA image as PNG. `level` 0 = stored, 1...9 = the same tuned deflate (no slower/denser tiers yet).
func ioEncodePNG(_ img: SRImage, level: Int) -> [UInt8]? {
    var kv: [Int32] = [16, Int32(level)]
    return kv.withUnsafeMutableBufferPointer { ioEncodePNG(img, params: IOParams($0.baseAddress, $0.count)) }
}

/// PNG writer with the IMWRITE_PNG_* parameters: COMPRESSION (16), STRATEGY (17), BILEVEL (18), FILTER (19, bit mask of
/// the five filter types), ZLIBBUFFER_SIZE (20, IDAT chunk size; unset = a single IDAT). 8- and 16-bit gray / BGR / BGRA.
func ioEncodePNG(_ img: SRImage, params p: IOParams) -> [UInt8]? {
    let level = max(0, min(9, p.get(16, 1)))
    let strategy = max(0, min(4, p.get(17, 0)))
    guard let first = pngEncodeCore(img, p, level: level) else { return nil }
    // The chain tiers are cost-model driven and can lose to the tuned fast tier on smooth content: keep the smaller file,
    // so a higher level is never bigger than level 1.
    if level >= 2 && (strategy == 0 || strategy == 1 || strategy == 4), let fast = pngEncodeCore(img, p, level: 1), fast.count < first.count { return fast }
    return first
}

private func pngEncodeCore(_ img: SRImage, _ p: IOParams, level: Int) -> [UInt8]? {
    guard (img.depth == .u8 || img.depth == .u16), img.width > 0, img.height > 0 else { return nil }
    let strategy = max(0, min(4, p.get(17, 0)))
    let filterMask = (p.get(19, 248) >> 3) & 31
    let bilevel = p.get(18, 0) != 0 && img.channels == 1 && img.depth == .u8
    let zbuf = p.get(20, 0)
    let w = img.width, h = img.height, ch = img.channels
    let wide = img.depth == .u16
    guard ch == 1 || ch == 3 || ch == 4 else { return nil }
    let bitDepth = bilevel ? 1 : (wide ? 16 : 8)
    let rowBytes = bilevel ? (w + 7) / 8 : w * ch * (wide ? 2 : 1)
    guard (rowBytes + 1) * h < Int(Int32.max) / 2 else { return nil }
    let colorType: UInt8 = ch == 1 ? 0 : (ch == 3 ? 2 : 6)
    let bpp = bilevel ? 1 : ch * (wide ? 2 : 1)   // filter byte distance (bilevel rows are packed: whole bytes)
    let allowed = filterMask == 0 ? 31 : filterMask

    // PNG header chunks go first in the same buffer: signature (8) + IHDR (25) + IDAT length/type (8)
    let prefix = 8 + 25 + 8
    let chunkBytes = max(rowBytes + 1, 1 << 18)
    let df = IODeflate(level: level, prefix: prefix, chunkBytes: chunkBytes, strategy: strategy)
    func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    var head: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    var ihdr: [UInt8] = Array("IHDR".utf8) + be32(UInt32(w)) + be32(UInt32(h)) + [UInt8(bitDepth), colorType, 0, 0, 0]
    let ihdrCRC = ihdr.withUnsafeBufferPointer { ioCRC32(0, $0.baseAddress!, $0.count) }
    head += be32(13) + ihdr + be32(ihdrCRC)
    ihdr = []
    for (i, b) in head.enumerated() { df.out[i] = b }

    // row buffers with 16 zero bytes in front (left / up-left neighbours of the first pixel) and slack behind
    let pad = 16
    let rowAlloc = pad + rowBytes + 64
    let cur = UnsafeMutablePointer<UInt8>.allocate(capacity: rowAlloc)
    let prev = UnsafeMutablePointer<UInt8>.allocate(capacity: rowAlloc)
    cur.initialize(repeating: 0, count: rowAlloc)
    prev.initialize(repeating: 0, count: rowAlloc)
    defer { cur.deallocate(); prev.deallocate() }
    var curRow = cur + pad, prevRow = prev + pad
    let src0 = img.data.assumingMemoryBound(to: UInt8.self)

    // vImage permute maps (BGR -> RGB, BGRA -> RGBA)
    let map3: [UInt8] = [2, 1, 0]
    let map4: [UInt8] = [2, 1, 0, 3]

    for y in 0..<h {
        // 1. file-order row
        let srcRow = src0 + y * img.stride
        if bilevel {
            memset(curRow, 0, rowBytes)
            for x in 0..<w where srcRow[x] != 0 { curRow[x >> 3] |= UInt8(0x80 >> (x & 7)) }
        } else if wide {
            let s16 = UnsafeRawPointer(srcRow)
            for x in 0..<w {
                for c in 0..<ch {
                    let sc = (ch >= 3 && c < 3) ? 2 - c : c   // BGR(A) -> RGB(A)
                    let v = s16.loadUnaligned(fromByteOffset: (x * ch + sc) * 2, as: UInt16.self)
                    curRow[(x * ch + c) * 2] = UInt8(v >> 8)
                    curRow[(x * ch + c) * 2 + 1] = UInt8(v & 0xFF)
                }
            }
        } else if ch == 1 { memcpy(curRow, srcRow, rowBytes) }
        else {
            var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: srcRow), height: 1, width: vImagePixelCount(w), rowBytes: rowBytes)
            var d = vImage_Buffer(data: curRow, height: 1, width: vImagePixelCount(w), rowBytes: rowBytes)
            if ch == 3 { vImagePermuteChannels_RGB888(&s, &d, map3, vImage_Flags(kvImageDoNotTile)) }
            else { vImagePermuteChannels_ARGB8888(&s, &d, map4, vImage_Flags(kvImageDoNotTile)) }
        }
        // 2. score the five filters, 3. write the chosen one straight into the deflate window
        let best = pngBestFilter(curRow, prevRow, rowBytes, bpp, allowed)
        let o = df.reserve(rowBytes + 1)
        o[0] = UInt8(best)
        pngWriteFiltered(best, curRow, prevRow, o + 1, rowBytes, bpp)
        df.commit(rowBytes + 1)
        if df.pending >= chunkBytes { df.compress(final: false) }
        swap(&curRow, &prevRow)
    }
    let end = df.finish()  // after this the output buffer is final (no more reallocation)
    let out = df.out
    let idatLen = end - prefix
    var tail = be32(0) + Array("IEND".utf8) + [0xAE, 0x42, 0x60, 0x82]
    if zbuf > 0 && idatLen > zbuf {
        // IDAT split into chunks of `zbuf` bytes, like libpng with a small zlib buffer
        var res = Array(UnsafeBufferPointer(start: out, count: 33))
        var p0 = prefix
        while p0 < end {
            let n = min(zbuf, end - p0)
            res += be32(UInt32(n)) + Array("IDAT".utf8)
            res.append(contentsOf: UnsafeBufferPointer(start: out + p0, count: n))
            let crc = res.withUnsafeBufferPointer { b in ioCRC32(0, b.baseAddress! + (b.count - n - 4), n + 4) }
            res += be32(crc)
            p0 += n
        }
        return res + tail
    }
    // IDAT length + type, CRC; IEND
    let lenBytes = be32(UInt32(idatLen))
    for i in 0..<4 { out[33 + i] = lenBytes[i] }
    out[37] = 0x49; out[38] = 0x44; out[39] = 0x41; out[40] = 0x54
    let crc = ioCRC32(0, out + 37, 4 + idatLen)
    tail = be32(crc) + tail
    for (i, b) in tail.enumerated() { out[end + i] = b }
    return Array(UnsafeBufferPointer(start: out, count: end + tail.count))
}


/// |signed byte| summed pairwise into 8 u16 lanes (no widening conversion: the u16 view of the bytes is split with a mask and a shift).
@inline(__always) private func absSum(_ v: SIMD16<UInt8>) -> SIMD8<UInt16> {
    let sg = unsafeBitCast(v, to: SIMD16<Int8>.self)
    let m = sg &>> 7
    let u = unsafeBitCast((sg ^ m) &- m, to: SIMD8<UInt16>.self)
    return (u & 0x00FF) &+ (u &>> 8)
}

@inline(__always) private func laneTotal(_ v: SIMD8<UInt16>) -> Int {
    Int(v[0]) + Int(v[1]) + Int(v[2]) + Int(v[3]) + Int(v[4]) + Int(v[5]) + Int(v[6]) + Int(v[7])
}

/// Index 0...4 of the filter with the smallest sum of absolute (signed-byte) residuals for this row.
@inline(never)
private func pngBestFilter(_ curRow: UnsafeMutablePointer<UInt8>, _ prevRow: UnsafeMutablePointer<UInt8>, _ rowBytes: Int, _ bpp: Int,
                           _ allowed: Int = 31) -> Int {
    // only one filter allowed: nothing to score
    if allowed & (allowed - 1) == 0 { return allowed.trailingZeroBitCount }
    // Identical to the row above: the Up filter makes it all zeros, nothing can beat that.
    if allowed & 4 != 0 && memcmp(curRow, prevRow, rowBytes) == 0 { return 2 }
    let vecEnd = rowBytes & ~15
    var t = (0, 0, 0, 0, 0)
    var x = 0
    // lane accumulators hold at most 2 * 128 per 16 bytes: flush into Int before they can pass 65535
    while x < vecEnd {
        var s0 = SIMD8<UInt16>(), s1 = SIMD8<UInt16>(), s2 = SIMD8<UInt16>(), s3 = SIMD8<UInt16>()
        let stop = min(vecEnd, x + 16 * 200)
        while x < stop {
            let c = UnsafeRawPointer(curRow + x).loadUnaligned(as: SIMD16<UInt8>.self)
            let a = UnsafeRawPointer(curRow + x - bpp).loadUnaligned(as: SIMD16<UInt8>.self)
            let b = UnsafeRawPointer(prevRow + x).loadUnaligned(as: SIMD16<UInt8>.self)
            s0 &+= absSum(c)
            // c == a == b: Sub, Up and Average all give zeros here, only the raw sum above counts
            let d = unsafeBitCast((c ^ b) | (c ^ a), to: SIMD2<UInt64>.self)
            if (d[0] | d[1]) == 0 { x += 16; continue }
            s1 &+= absSum(c &- a)
            s2 &+= absSum(c &- b)
            s3 &+= absSum(c &- ((a & b) &+ ((a ^ b) &>> 1)))
            x += 16
        }
        t.0 += laneTotal(s0); t.1 += laneTotal(s1); t.2 += laneTotal(s2); t.3 += laneTotal(s3)
    }
    @inline(__always) func ab(_ v: Int) -> Int { let u = Int(Int8(truncatingIfNeeded: v)); return u < 0 ? -u : u }
    var tx = x
    while tx < rowBytes {
        let c = Int(curRow[tx]), a = Int(curRow[tx - bpp]), b = Int(prevRow[tx])
        t.0 += ab(c); t.1 += ab(c - a); t.2 += ab(c - b); t.3 += ab(c - ((a + b) >> 1))
        tx += 1
    }
    var best = -1, bestScore = Int.max
    if allowed & 1 != 0 { best = 0; bestScore = t.0 }
    if allowed & 2 != 0 && t.1 < bestScore { best = 1; bestScore = t.1 }
    if allowed & 4 != 0 && t.2 < bestScore { best = 2; bestScore = t.2 }
    if allowed & 8 != 0 && t.3 < bestScore { best = 3; bestScore = t.3 }
    // A row some simple filter already turns into all zeros cannot be beaten (ties go to the lower index), so Paeth is skipped.
    if bestScore == 0 || allowed & 16 == 0 { return best }
    x = 0
    while x < vecEnd {
        var s4 = SIMD8<UInt16>()
        let stop = min(vecEnd, x + 16 * 200)
        while x < stop {
            let c = UnsafeRawPointer(curRow + x).loadUnaligned(as: SIMD16<UInt8>.self)
            let a = UnsafeRawPointer(curRow + x - bpp).loadUnaligned(as: SIMD16<UInt8>.self)
            let b = UnsafeRawPointer(prevRow + x).loadUnaligned(as: SIMD16<UInt8>.self)
            // c == a == b: Paeth predicts a (pa == pb <= pc whatever the up-left byte is), residual zero
            let d = unsafeBitCast((c ^ b) | (c ^ a), to: SIMD2<UInt64>.self)
            if (d[0] | d[1]) == 0 { x += 16; continue }
            let cc = UnsafeRawPointer(prevRow + x - bpp).loadUnaligned(as: SIMD16<UInt8>.self)
            s4 &+= absSum(c &- paethVec(a, b, cc))
            x += 16
        }
        t.4 += laneTotal(s4)
    }
    while x < rowBytes {
        let c = Int(curRow[x]), a = Int(curRow[x - bpp]), b = Int(prevRow[x]), cc = Int(prevRow[x - bpp])
        t.4 += ab(c - paethScalar(a, b, cc))
        x += 1
    }
    if best < 0 || t.4 < bestScore { best = 4 }
    return best
}

@inline(never)
private func pngWriteFiltered(_ best: Int, _ curRow: UnsafeMutablePointer<UInt8>, _ prevRow: UnsafeMutablePointer<UInt8>,
                              _ od: UnsafeMutablePointer<UInt8>, _ rowBytes: Int, _ bpp: Int) {
    let vecEnd = rowBytes & ~15
    var x = 0
    switch best {
    case 0:
        memcpy(od, curRow, rowBytes)
        return
    case 1:
        while x < vecEnd {
            let c = UnsafeRawPointer(curRow + x).loadUnaligned(as: SIMD16<UInt8>.self)
            let a = UnsafeRawPointer(curRow + x - bpp).loadUnaligned(as: SIMD16<UInt8>.self)
            UnsafeMutableRawPointer(od + x).storeBytes(of: c &- a, as: SIMD16<UInt8>.self); x += 16
        }
    case 2:
        while x < vecEnd {
            let c = UnsafeRawPointer(curRow + x).loadUnaligned(as: SIMD16<UInt8>.self)
            let b = UnsafeRawPointer(prevRow + x).loadUnaligned(as: SIMD16<UInt8>.self)
            UnsafeMutableRawPointer(od + x).storeBytes(of: c &- b, as: SIMD16<UInt8>.self); x += 16
        }
    case 3:
        while x < vecEnd {
            let c = UnsafeRawPointer(curRow + x).loadUnaligned(as: SIMD16<UInt8>.self)
            let a = UnsafeRawPointer(curRow + x - bpp).loadUnaligned(as: SIMD16<UInt8>.self)
            let b = UnsafeRawPointer(prevRow + x).loadUnaligned(as: SIMD16<UInt8>.self)
            UnsafeMutableRawPointer(od + x).storeBytes(of: c &- ((a & b) &+ ((a ^ b) &>> 1)), as: SIMD16<UInt8>.self); x += 16
        }
    default:
        while x < vecEnd {
            let c = UnsafeRawPointer(curRow + x).loadUnaligned(as: SIMD16<UInt8>.self)
            let a = UnsafeRawPointer(curRow + x - bpp).loadUnaligned(as: SIMD16<UInt8>.self)
            let b = UnsafeRawPointer(prevRow + x).loadUnaligned(as: SIMD16<UInt8>.self)
            let cc = UnsafeRawPointer(prevRow + x - bpp).loadUnaligned(as: SIMD16<UInt8>.self)
            UnsafeMutableRawPointer(od + x).storeBytes(of: c &- paethVec(a, b, cc), as: SIMD16<UInt8>.self); x += 16
        }
    }
    while x < rowBytes {
        let c = Int(curRow[x]), a = Int(curRow[x - bpp]), b = Int(prevRow[x]), cc = Int(prevRow[x - bpp])
        let p: Int
        switch best { case 1: p = a; case 2: p = b; case 3: p = (a + b) >> 1; default: p = paethScalar(a, b, cc) }
        od[x] = UInt8(truncatingIfNeeded: c - p)
        x += 1
    }
}

@inline(__always) private func paethScalar(_ a: Int, _ b: Int, _ c: Int) -> Int {
    let p = a + b - c
    let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
    return (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
}

/// Vector Paeth predictor on bytes, without widening: pa = |b-c|, pb = |a-c| (max - min); pc = |pa-pb| when a-c and b-c
/// have opposite signs, otherwise pa+pb which is never the smallest, so it is saturated to 255.
@inline(__always) private func paethVec(_ a: SIMD16<UInt8>, _ b: SIMD16<UInt8>, _ c: SIMD16<UInt8>) -> SIMD16<UInt8> {
    let pa = pointwiseMax(b, c) &- pointwiseMin(b, c)
    let pb = pointwiseMax(a, c) &- pointwiseMin(a, c)
    let opposite = (b .>= c) .^ (a .>= c)
    let diff = pointwiseMax(pa, pb) &- pointwiseMin(pa, pb)
    let pc = SIMD16<UInt8>(repeating: 255).replacing(with: diff, where: opposite)
    let useA = (pa .<= pb) .& (pa .<= pc)
    let useB = (pb .<= pc) .& .!useA
    var r = c
    r = r.replacing(with: b, where: useB)
    r = r.replacing(with: a, where: useA)
    return r
}
