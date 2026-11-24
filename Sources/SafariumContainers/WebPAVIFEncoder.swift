import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import SafariumCore
import UniformTypeIdentifiers

public struct StillImageWriteReport: Codable, Sendable {
    public let outputPath: String
    public let format: ContainerFormat
    public let width: Int
    public let height: Int
    public let quality: Double?
    public let bytes: Int
    public let wallMs: Double

    public init(
        outputPath: String,
        format: ContainerFormat,
        width: Int,
        height: Int,
        quality: Double?,
        bytes: Int,
        wallMs: Double
    ) {
        self.outputPath = outputPath
        self.format = format
        self.width = width
        self.height = height
        self.quality = quality
        self.bytes = bytes
        self.wallMs = wallMs
    }
}

public struct ImageSequenceReport: Codable, Sendable {
    public let outputPath: String
    public let format: ContainerFormat
    public let width: Int
    public let height: Int
    public let frameCount: Int
    public let loopCount: Int
    public let bytes: Int
    public let wallMs: Double

    public init(
        outputPath: String,
        format: ContainerFormat,
        width: Int,
        height: Int,
        frameCount: Int,
        loopCount: Int,
        bytes: Int,
        wallMs: Double
    ) {
        self.outputPath = outputPath
        self.format = format
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.loopCount = loopCount
        self.bytes = bytes
        self.wallMs = wallMs
    }
}

public enum WebPAVIFEncoder {
    // MARK: - LSB-First Bitstream Writer & Package-Merge Canonical Huffman

    private final class LSBStreamWriter {
        private var bytes = Data()
        private var buf: UInt64 = 0
        private var bits: Int = 0

        func writeBits(_ value: UInt32, count: Int) {
            guard count > 0 else { return }
            let mask: UInt64 = (UInt64(1) << count) - 1
            buf |= (UInt64(value) & mask) << bits
            bits += count
            while bits >= 8 {
                bytes.append(UInt8(buf & 0xFF))
                buf >>= 8
                bits -= 8
            }
        }

        func finish() -> Data {
            if bits > 0 {
                bytes.append(UInt8(buf & 0xFF))
                buf = 0
                bits = 0
            }
            return bytes
        }
    }

    private struct HuffmanTable {
        let lengths: [Int]
        let codesLSB: [UInt32]
    }

    private static func reverseBits(_ code: UInt32, length: Int) -> UInt32 {
        var x = code
        var rev: UInt32 = 0
        for _ in 0..<length {
            rev = (rev << 1) | (x & 1)
            x >>= 1
        }
        return rev
    }

    private static func computeLimitedCodeLengths(freqs: [Int], maxBits: Int) -> [Int] {
        let n = freqs.count
        var active: [(sym: Int, freq: Int)] = []
        active.reserveCapacity(n)
        for i in 0..<n where freqs[i] > 0 {
            active.append((i, freqs[i]))
        }
        var lengths = [Int](repeating: 0, count: n)
        if active.isEmpty { return lengths }
        if active.count == 1 {
            lengths[active[0].sym] = 1
            return lengths
        }
        if active.count == 2 {
            lengths[active[0].sym] = 1
            lengths[active[1].sym] = 1
            return lengths
        }

        active.sort { ($0.freq, $0.sym) < ($1.freq, $1.sym) }

        struct Node {
            let weight: Int
            let syms: [Int]
        }
        var prevCoins: [Node] = []
        for _ in 0..<maxBits {
            var current: [Node] = active.enumerated().map { Node(weight: $0.element.freq, syms: [$0.offset]) }
            var i = 0
            while i + 1 < prevCoins.count {
                let a = prevCoins[i]
                let b = prevCoins[i + 1]
                current.append(Node(weight: a.weight + b.weight, syms: a.syms + b.syms))
                i += 2
            }
            current.sort { $0.weight < $1.weight }
            prevCoins = current
        }

        let takeCount = min(prevCoins.count, 2 * active.count - 2)
        var activeLen = [Int](repeating: 0, count: active.count)
        for idx in 0..<takeCount {
            for sIdx in prevCoins[idx].syms {
                activeLen[sIdx] += 1
            }
        }
        for (idx, item) in active.enumerated() {
            lengths[item.sym] = activeLen[idx]
        }
        return lengths
    }

    private static func buildCanonicalHuffman(freqs: [Int], maxBits: Int) -> HuffmanTable {
        let lengths = computeLimitedCodeLengths(freqs: freqs, maxBits: maxBits)
        var blCount = [Int](repeating: 0, count: maxBits + 1)
        for l in lengths where l > 0 {
            blCount[l] += 1
        }
        var nextCode = [UInt32](repeating: 0, count: maxBits + 1)
        var code: UInt32 = 0
        for bits in 1...maxBits {
            code = (code + UInt32(blCount[bits - 1])) << 1
            nextCode[bits] = code
        }
        var codesLSB = [UInt32](repeating: 0, count: lengths.count)
        for sym in 0..<lengths.count {
            let l = lengths[sym]
            if l > 0 {
                let msb = nextCode[l]
                nextCode[l] = msb + 1
                codesLSB[sym] = reverseBits(msb, length: l)
            }
        }
        return HuffmanTable(lengths: lengths, codesLSB: codesLSB)
    }

    private static func writePrefixCode(_ bw: LSBStreamWriter, freqs: [Int]) -> HuffmanTable {
        let active = freqs.enumerated().filter { $0.element > 0 }.map { $0.offset }

        if active.isEmpty {
            bw.writeBits(1, count: 1)
            bw.writeBits(0, count: 1)
            bw.writeBits(0, count: 1)
            bw.writeBits(0, count: 1)
            return HuffmanTable(
                lengths: [Int](repeating: 0, count: freqs.count),
                codesLSB: [UInt32](repeating: 0, count: freqs.count)
            )
        }

        if active.count == 1 && active[0] < 256 {
            let s0 = active[0]
            bw.writeBits(1, count: 1)
            bw.writeBits(0, count: 1)
            if s0 <= 1 {
                bw.writeBits(0, count: 1)
                bw.writeBits(UInt32(s0), count: 1)
            } else {
                bw.writeBits(1, count: 1)
                bw.writeBits(UInt32(s0), count: 8)
            }
            return HuffmanTable(
                lengths: [Int](repeating: 0, count: freqs.count),
                codesLSB: [UInt32](repeating: 0, count: freqs.count)
            )
        }

        if active.count == 2 && active[0] < 256 && active[1] < 256 {
            let s0 = active[0]
            let s1 = active[1]
            bw.writeBits(1, count: 1)
            bw.writeBits(1, count: 1)
            if s0 <= 1 {
                bw.writeBits(0, count: 1)
                bw.writeBits(UInt32(s0), count: 1)
            } else {
                bw.writeBits(1, count: 1)
                bw.writeBits(UInt32(s0), count: 8)
            }
            bw.writeBits(UInt32(s1), count: 8)
            var lengths = [Int](repeating: 0, count: freqs.count)
            var codes = [UInt32](repeating: 0, count: freqs.count)
            lengths[s0] = 1
            codes[s0] = 0
            lengths[s1] = 1
            codes[s1] = 1
            return HuffmanTable(lengths: lengths, codesLSB: codes)
        }

        let table = buildCanonicalHuffman(freqs: freqs, maxBits: 15)
        let codeLengthOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

        var rleSyms: [(sym: Int, extraBits: Int, extraVal: UInt32)] = []
        var i = 0
        var prevNonZero = 8
        while i < table.lengths.count {
            let l = table.lengths[i]
            if l == 0 {
                var run = 1
                while i + run < table.lengths.count && table.lengths[i + run] == 0 && run < 138 {
                    run += 1
                }
                if run >= 11 {
                    rleSyms.append((18, 7, UInt32(run - 11)))
                    i += run
                } else if run >= 3 {
                    rleSyms.append((17, 3, UInt32(run - 3)))
                    i += run
                } else {
                    rleSyms.append((0, 0, 0))
                    i += 1
                }
            } else {
                rleSyms.append((l, 0, 0))
                prevNonZero = l
                i += 1
                while i < table.lengths.count && table.lengths[i] == prevNonZero {
                    var run = 1
                    while i + run < table.lengths.count && table.lengths[i + run] == prevNonZero && run < 6 {
                        run += 1
                    }
                    if run >= 3 {
                        rleSyms.append((16, 2, UInt32(run - 3)))
                        i += run
                    } else {
                        break
                    }
                }
            }
        }

        var clFreqs = [Int](repeating: 0, count: 19)
        for item in rleSyms {
            clFreqs[item.sym] += 1
        }
        if clFreqs.filter({ $0 > 0 }).count == 1 {
            let dummy = clFreqs[0] == 0 ? 0 : 1
            clFreqs[dummy] = 1
        }

        let clTable = buildCanonicalHuffman(freqs: clFreqs, maxBits: 7)
        var numCodeLengths = 4
        for idx in stride(from: 18, through: 4, by: -1) {
            if clTable.lengths[codeLengthOrder[idx]] > 0 {
                numCodeLengths = idx + 1
                break
            }
        }

        bw.writeBits(0, count: 1) // normal prefix code
        bw.writeBits(UInt32(numCodeLengths - 4), count: 4)
        for idx in 0..<numCodeLengths {
            bw.writeBits(UInt32(clTable.lengths[codeLengthOrder[idx]]), count: 3)
        }
        bw.writeBits(0, count: 1) // use_max_symbol = 0
        for item in rleSyms {
            let len = clTable.lengths[item.sym]
            bw.writeBits(clTable.codesLSB[item.sym], count: len)
            if item.extraBits > 0 {
                bw.writeBits(item.extraVal, count: item.extraBits)
            }
        }
        return table
    }

    private static func encodeVP8LLengthCode(_ length: Int) -> (code: Int, extraBits: Int, extraVal: UInt32) {
        if length <= 4 {
            return (256 + length - 1, 0, 0)
        }
        let val = length - 1
        let highestBit = Int.bitWidth - 1 - val.leadingZeroBitCount
        let extraBits = highestBit - 1
        let prefix = (val >> extraBits) & 1
        let code = 256 + 2 * extraBits + prefix + 2
        let extraVal = UInt32(val & ((1 << extraBits) - 1))
        return (code, extraBits, extraVal)
    }

    // MARK: - Pure-Swift RFC 9649 VP8L Lossless Bitstream & RIFF Container

    public static func encodeVP8LBitstream(
        rgba: [UInt8],
        width: Int,
        height: Int,
        useSubtractGreen: Bool = true,
        useRLE: Bool = true
    ) throws -> Data {
        guard width >= 1, width <= 16_384, height >= 1, height <= 16_384, rgba.count == width * height * 4 else {
            throw SafariumError.encode("invalid VP8L geometry \(width)x\(height) for \(rgba.count) RGBA bytes")
        }
        let pixelCount = width * height
        var hasAlpha = false
        for i in stride(from: 3, to: rgba.count, by: 4) {
            if rgba[i] != 255 {
                hasAlpha = true
                break
            }
        }

        // Pack transformed (g, r, b, a) into UInt32 for fast RLE comparisons
        var packed = [UInt32](repeating: 0, count: pixelCount)
        packed.withUnsafeMutableBufferPointer { dst in
            rgba.withUnsafeBufferPointer { src in
                for i in 0..<pixelCount {
                    let base = i * 4
                    let r0 = src[base + 0]
                    let g0 = src[base + 1]
                    let b0 = src[base + 2]
                    let a0 = src[base + 3]
                    let r = useSubtractGreen ? (r0 &- g0) : r0
                    let b = useSubtractGreen ? (b0 &- g0) : b0
                    dst[i] = (UInt32(g0) << 24) | (UInt32(r) << 16) | (UInt32(b) << 8) | UInt32(a0)
                }
            }
        }

        enum Token {
            case literal(UInt32)
            case copyLeft(Int)
        }
        var tokens: [Token] = []
        tokens.reserveCapacity(pixelCount)
        var gFreq = [Int](repeating: 0, count: 280)
        var rFreq = [Int](repeating: 0, count: 256)
        var bFreq = [Int](repeating: 0, count: 256)
        var aFreq = [Int](repeating: 0, count: 256)
        var dFreq = [Int](repeating: 0, count: 40)

        var p = 0
        while p < pixelCount {
            let cur = packed[p]
            if useRLE && p > 0 && packed[p - 1] == cur {
                var run = 1
                while p + run < pixelCount && packed[p + run] == cur && run < 4096 {
                    run += 1
                }
                if run >= 2 {
                    let lc = encodeVP8LLengthCode(run)
                    gFreq[lc.code] += 1
                    dFreq[1] += 1 // RFC 9649 2D distance symbol 1 -> code 2 = (dx=1, dy=0) left pixel
                    tokens.append(.copyLeft(run))
                    p += run
                    continue
                }
            }
            let g = Int((cur >> 24) & 0xFF)
            let r = Int((cur >> 16) & 0xFF)
            let b = Int((cur >> 8) & 0xFF)
            let a = Int(cur & 0xFF)
            gFreq[g] += 1
            rFreq[r] += 1
            bFreq[b] += 1
            aFreq[a] += 1
            tokens.append(.literal(cur))
            p += 1
        }

        let bw = LSBStreamWriter()
        bw.writeBits(0x2F, count: 8)
        bw.writeBits(UInt32(width - 1), count: 14)
        bw.writeBits(UInt32(height - 1), count: 14)
        bw.writeBits(hasAlpha ? 1 : 0, count: 1)
        bw.writeBits(0, count: 3)

        if useSubtractGreen {
            bw.writeBits(1, count: 1)
            bw.writeBits(2, count: 2)
        }
        bw.writeBits(0, count: 1) // end of transforms
        bw.writeBits(0, count: 1) // color_cache_used = 0
        bw.writeBits(0, count: 1) // use_meta_prefix = 0

        let gTbl = writePrefixCode(bw, freqs: gFreq)
        let rTbl = writePrefixCode(bw, freqs: rFreq)
        let bTbl = writePrefixCode(bw, freqs: bFreq)
        let aTbl = writePrefixCode(bw, freqs: aFreq)
        let dTbl = writePrefixCode(bw, freqs: dFreq)

        for tok in tokens {
            switch tok {
            case .literal(let px):
                let g = Int((px >> 24) & 0xFF)
                let r = Int((px >> 16) & 0xFF)
                let b = Int((px >> 8) & 0xFF)
                let a = Int(px & 0xFF)
                if gTbl.lengths[g] > 0 { bw.writeBits(gTbl.codesLSB[g], count: gTbl.lengths[g]) }
                if rTbl.lengths[r] > 0 { bw.writeBits(rTbl.codesLSB[r], count: rTbl.lengths[r]) }
                if bTbl.lengths[b] > 0 { bw.writeBits(bTbl.codesLSB[b], count: bTbl.lengths[b]) }
                if aTbl.lengths[a] > 0 { bw.writeBits(aTbl.codesLSB[a], count: aTbl.lengths[a]) }
            case .copyLeft(let length):
                let lc = encodeVP8LLengthCode(length)
                if gTbl.lengths[lc.code] > 0 { bw.writeBits(gTbl.codesLSB[lc.code], count: gTbl.lengths[lc.code]) }
                if lc.extraBits > 0 { bw.writeBits(lc.extraVal, count: lc.extraBits) }
                if dTbl.lengths[1] > 0 { bw.writeBits(dTbl.codesLSB[1], count: dTbl.lengths[1]) }
            }
        }

        return bw.finish()
    }

    private static func riffChunk(_ fourcc: String, payload: Data) -> Data {
        var out = Data(fourcc.utf8)
        var sz = UInt32(payload.count).littleEndian
        out.append(Data(bytes: &sz, count: 4))
        out.append(payload)
        if (payload.count & 1) != 0 {
            out.append(0x00)
        }
        return out
    }

    private static func appendU24LE(_ data: inout Data, _ val: Int) {
        data.append(UInt8(val & 0xFF))
        data.append(UInt8((val >> 8) & 0xFF))
        data.append(UInt8((val >> 16) & 0xFF))
    }

    private static func wrapRIFFWebP(body: Data) -> Data {
        var riff = Data("RIFF".utf8)
        var sz = UInt32(body.count).littleEndian
        riff.append(Data(bytes: &sz, count: 4))
        riff.append(body)
        return riff
    }

    // MARK: - CGImage Straight-RGBA Extraction

    private static func extractStraightRGBA(from cgImage: CGImage) throws -> [UInt8] {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else {
            throw SafariumError.encode("CGImage has invalid dimensions \(w)x\(h)")
        }

        if let dp = cgImage.dataProvider,
           let cfData = dp.data as Data?,
           cgImage.bitsPerComponent == 8,
           cgImage.bitsPerPixel == 32 {
            let alphaInfo = cgImage.alphaInfo
            let byteOrder = cgImage.bitmapInfo.intersection(.byteOrderMask)
            let bpr = cgImage.bytesPerRow
            if bpr >= w * 4 && cfData.count >= h * bpr {
                if alphaInfo == .last && (byteOrder == [] || byteOrder == .byteOrder32Big) && bpr == w * 4 {
                    return [UInt8](cfData.prefix(w * h * 4))
                }
                var bytes = [UInt8](repeating: 0, count: w * h * 4)
                cfData.withUnsafeBytes { raw in
                    let src = raw.bindMemory(to: UInt8.self).baseAddress!
                    for y in 0..<h {
                        for x in 0..<w {
                            let s = y * bpr + x * 4
                            let d = (y * w + x) * 4
                            if byteOrder == .byteOrder32Little &&
                                (alphaInfo == .first || alphaInfo == .premultipliedFirst || alphaInfo == .noneSkipFirst) {
                                let b = src[s + 0], g = src[s + 1], r = src[s + 2]
                                let a = (alphaInfo == .noneSkipFirst) ? UInt8(255) : src[s + 3]
                                if alphaInfo == .premultipliedFirst && a > 0 && a < 255 {
                                    bytes[d + 0] = UInt8(min(255, (Int(r) * 255 + Int(a) / 2) / Int(a)))
                                    bytes[d + 1] = UInt8(min(255, (Int(g) * 255 + Int(a) / 2) / Int(a)))
                                    bytes[d + 2] = UInt8(min(255, (Int(b) * 255 + Int(a) / 2) / Int(a)))
                                    bytes[d + 3] = a
                                } else {
                                    bytes[d + 0] = r
                                    bytes[d + 1] = g
                                    bytes[d + 2] = b
                                    bytes[d + 3] = a
                                }
                            } else {
                                let r = src[s + 0], g = src[s + 1], b = src[s + 2]
                                let a = (alphaInfo == .noneSkipLast) ? UInt8(255) : src[s + 3]
                                if alphaInfo == .premultipliedLast && a > 0 && a < 255 {
                                    bytes[d + 0] = UInt8(min(255, (Int(r) * 255 + Int(a) / 2) / Int(a)))
                                    bytes[d + 1] = UInt8(min(255, (Int(g) * 255 + Int(a) / 2) / Int(a)))
                                    bytes[d + 2] = UInt8(min(255, (Int(b) * 255 + Int(a) / 2) / Int(a)))
                                    bytes[d + 3] = a
                                } else {
                                    bytes[d + 0] = r
                                    bytes[d + 1] = g
                                    bytes[d + 2] = b
                                    bytes[d + 3] = a
                                }
                            }
                        }
                    }
                }
                return bytes
            }
        }

        // Fallback: normalize into sRGB 32BGRA CGContext
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? cgImage.colorSpace else {
            throw SafariumError.encode("missing RGB colorspace for WebP encode")
        }
        let hasAlpha = cgImageHasAlpha(cgImage)
        let info = (hasAlpha ? CGImageAlphaInfo.premultipliedFirst.rawValue : CGImageAlphaInfo.noneSkipFirst.rawValue)
            | CGBitmapInfo.byteOrder32Little.rawValue
        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        let drew = bgra.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: cs,
                bitmapInfo: info
            ) else {
                return false
            }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else {
            throw SafariumError.encode("CGContext fallback draw failed for WebP encode")
        }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let off = i * 4
            let b = bgra[off + 0], g = bgra[off + 1], r = bgra[off + 2]
            let a = hasAlpha ? bgra[off + 3] : UInt8(255)
            if hasAlpha && a > 0 && a < 255 {
                rgba[off + 0] = UInt8(min(255, (Int(r) * 255 + Int(a) / 2) / Int(a)))
                rgba[off + 1] = UInt8(min(255, (Int(g) * 255 + Int(a) / 2) / Int(a)))
                rgba[off + 2] = UInt8(min(255, (Int(b) * 255 + Int(a) / 2) / Int(a)))
                rgba[off + 3] = a
            } else {
                rgba[off + 0] = r
                rgba[off + 1] = g
                rgba[off + 2] = b
                rgba[off + 3] = a
            }
        }
        return rgba
    }

    private static func cgImageHasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
    }

    // MARK: - Public Encoders

    /// Writes a static (`1` image) or animated (`> 1` images, `VP8X+ANIM+ANMF`) lossless `VP8L` WebP file.
    public static func writeLosslessWebP(
        images: [CGImage],
        to outputURL: URL,
        loopCount: Int = 0,
        overwrite: Bool = false,
        frameDurationsMs: [Int]? = nil
    ) throws -> WebPEncodeReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let first = images.first else {
            throw SafariumError.invalidState("writeLosslessWebP requires at least 1 image")
        }
        guard loopCount >= 0, loopCount <= Int(UInt16.max) else {
            throw SafariumError.invalidState("WebP loopCount must be 0...65535, got \(loopCount)")
        }
        let w = first.width
        let h = first.height
        guard w >= 1, w <= 16_384, h >= 1, h <= 16_384 else {
            throw SafariumError.encode("invalid WebP dimensions \(w)x\(h)")
        }
        for (idx, img) in images.enumerated() {
            guard img.width == w, img.height == h else {
                throw SafariumError.invalidState("WebP frame \(idx) dimensions \(img.width)x\(img.height) do not match \(w)x\(h)")
            }
        }
        let delays: [Int]
        if let frameDurationsMs {
            guard frameDurationsMs.count == images.count else {
                throw SafariumError.invalidState("frameDurationsMs count \(frameDurationsMs.count) != images count \(images.count)")
            }
            for (idx, d) in frameDurationsMs.enumerated() where d < 0 || d > 0xFF_FFFF {
                throw SafariumError.invalidState("invalid WebP frame delay \(d) ms at index \(idx)")
            }
            delays = frameDurationsMs
        } else {
            delays = Array(repeating: 100, count: images.count)
        }

        try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)
        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }
        let tempURL = staging.fileURL("out.webp")

        let webpBytes: Data
        let animated = images.count > 1
        if !animated {
            let rgba = try extractStraightRGBA(from: first)
            let vp8l = try encodeVP8LBitstream(rgba: rgba, width: w, height: h)
            var body = Data("WEBP".utf8)
            body.append(riffChunk("VP8L", payload: vp8l))
            webpBytes = wrapRIFFWebP(body: body)
        } else {
            var framesRGBA: [[UInt8]] = []
            framesRGBA.reserveCapacity(images.count)
            var anyAlpha = false
            for img in images {
                let rgba = try extractStraightRGBA(from: img)
                if !anyAlpha {
                    anyAlpha = stride(from: 3, to: rgba.count, by: 4).contains { rgba[$0] != 255 }
                }
                framesRGBA.append(rgba)
            }

            var vp8xPayload = Data([0x02 | (anyAlpha ? 0x10 : 0x00), 0x00, 0x00, 0x00])
            appendU24LE(&vp8xPayload, w - 1)
            appendU24LE(&vp8xPayload, h - 1)

            var animPayload = Data([0x00, 0x00, 0x00, 0x00])
            var lcLE = UInt16(loopCount).littleEndian
            animPayload.append(Data(bytes: &lcLE, count: 2))

            var body = Data("WEBP".utf8)
            body.append(riffChunk("VP8X", payload: vp8xPayload))
            body.append(riffChunk("ANIM", payload: animPayload))

            for (idx, rgba) in framesRGBA.enumerated() {
                let vp8l = try encodeVP8LBitstream(rgba: rgba, width: w, height: h)
                var anmfPayload = Data()
                appendU24LE(&anmfPayload, 0)
                appendU24LE(&anmfPayload, 0)
                appendU24LE(&anmfPayload, w - 1)
                appendU24LE(&anmfPayload, h - 1)
                appendU24LE(&anmfPayload, delays[idx])
                anmfPayload.append(0x02) // no-blend, no-dispose
                anmfPayload.append(riffChunk("VP8L", payload: vp8l))
                body.append(riffChunk("ANMF", payload: anmfPayload))
            }
            webpBytes = wrapRIFFWebP(body: body)
        }

        try webpBytes.write(to: tempURL, options: .atomic)
        try SafeFilePublisher.publish(tempURL: tempURL, to: outputURL, overwrite: overwrite)

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return WebPEncodeReport(
            outputPath: outputURL.path,
            width: w,
            height: h,
            frameCount: images.count,
            animated: animated,
            bytes: webpBytes.count,
            wallMs: elapsedMs
        )
    }

    /// Writes a still image in `.webp` (pure-Swift lossless `VP8L`), `.avif` (`q < 1.0`), `.heic`, `.png`, or `.jpg`.
    public static func writeStillImage(
        cgImage: CGImage,
        format: ContainerFormat,
        quality: Double? = nil,
        to outputURL: URL,
        overwrite: Bool = false
    ) throws -> StillImageWriteReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard cgImage.width > 0, cgImage.height > 0 else {
            throw SafariumError.encode("invalid still image dimensions \(cgImage.width)x\(cgImage.height)")
        }

        if format == .webp {
            let webpReport = try writeLosslessWebP(images: [cgImage], to: outputURL, loopCount: 0, overwrite: overwrite)
            return StillImageWriteReport(
                outputPath: webpReport.outputPath,
                format: .webp,
                width: webpReport.width,
                height: webpReport.height,
                quality: nil,
                bytes: webpReport.bytes,
                wallMs: webpReport.wallMs
            )
        }

        let uti: String
        let effectiveQuality: Double?
        switch format {
        case .avif:
            let q = quality ?? 0.90
            guard q.isFinite, q >= 0.0, q < 1.0 else {
                throw SafariumError.encode(
                    "AVIF lossless (quality == 1.0) is unsupported by macOS ImageIO; pass quality < 1.0 (e.g. 0.90) or use lossless WebP/PNG"
                )
            }
            let supported = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
            guard supported.contains("public.avif") else {
                throw SafariumError.encode("public.avif encoding is not supported on this macOS version")
            }
            uti = "public.avif"
            effectiveQuality = q
        case .heic:
            let q = quality ?? 0.90
            guard q.isFinite, q >= 0.0, q <= 1.0 else {
                throw SafariumError.invalidState("HEIC quality must be within 0.0...1.0, got \(q)")
            }
            uti = UTType.heic.identifier
            effectiveQuality = q
        case .png:
            uti = UTType.png.identifier
            effectiveQuality = nil
        case .jpg:
            let q = quality ?? 0.92
            guard q.isFinite, q >= 0.0, q <= 1.0 else {
                throw SafariumError.invalidState("JPEG quality must be within 0.0...1.0, got \(q)")
            }
            uti = UTType.jpeg.identifier
            effectiveQuality = q
        default:
            throw SafariumError.invalidState("unsupported still image format: \(format.rawValue)")
        }

        try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)
        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }
        let tempURL = staging.fileURL("out.\(format.rawValue)")

        guard let dst = CGImageDestinationCreateWithURL(tempURL as CFURL, uti as CFString, 1, nil) else {
            throw SafariumError.encode("CGImageDestinationCreateWithURL failed for format \(format.rawValue)")
        }
        var opts: [CFString: Any] = [:]
        if let effectiveQuality {
            opts[kCGImageDestinationLossyCompressionQuality] = effectiveQuality
        }
        CGImageDestinationAddImage(dst, cgImage, opts.isEmpty ? nil : opts as CFDictionary)
        guard CGImageDestinationFinalize(dst) else {
            throw SafariumError.encode("CGImageDestinationFinalize failed for format \(format.rawValue)")
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        let byteCount = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount > 0 else {
            throw SafariumError.encode("ImageIO produced 0 bytes for format \(format.rawValue)")
        }

        try SafeFilePublisher.publish(tempURL: tempURL, to: outputURL, overwrite: overwrite)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return StillImageWriteReport(
            outputPath: outputURL.path,
            format: format,
            width: cgImage.width,
            height: cgImage.height,
            quality: effectiveQuality,
            bytes: byteCount,
            wallMs: elapsedMs
        )
    }

    /// Writes an animated HEIC image sequence (`public.heics`) via `ImageIO`.
    public static func writeHEICSSequence(
        images: [CGImage],
        quality: Double = 0.85,
        loopCount: Int = 0,
        to outputURL: URL,
        overwrite: Bool = false,
        frameDurationsMs: [Int]? = nil
    ) throws -> ImageSequenceReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let first = images.first else {
            throw SafariumError.invalidState("writeHEICSSequence requires at least 1 image")
        }
        guard quality.isFinite, quality >= 0.0, quality <= 1.0 else {
            throw SafariumError.invalidState("HEICS quality must be within 0.0...1.0, got \(quality)")
        }
        guard loopCount >= 0, loopCount <= Int(UInt16.max) else {
            throw SafariumError.invalidState("HEICS loopCount must be 0...65535, got \(loopCount)")
        }
        let w = first.width
        let h = first.height
        let firstHasAlpha = cgImageHasAlpha(first)
        for (idx, img) in images.enumerated() {
            guard img.width == w, img.height == h else {
                throw SafariumError.invalidState("HEICS frame \(idx) dimensions \(img.width)x\(img.height) do not match \(w)x\(h)")
            }
            guard cgImageHasAlpha(img) == firstHasAlpha else {
                throw SafariumError.encode(
                    "HEICS requires uniform alpha presence across all frames; frame \(idx) differs from frame 0"
                )
            }
        }
        let delays: [Int]
        if let frameDurationsMs {
            guard frameDurationsMs.count == images.count else {
                throw SafariumError.invalidState("frameDurationsMs count \(frameDurationsMs.count) != images count \(images.count)")
            }
            for (idx, d) in frameDurationsMs.enumerated() where d <= 0 {
                throw SafariumError.invalidState("HEICS frame delay must be > 0 ms at index \(idx)")
            }
            delays = frameDurationsMs
        } else {
            delays = Array(repeating: 100, count: images.count)
        }

        try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)
        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }
        let tempURL = staging.fileURL("sequence.heics")

        guard let dst = CGImageDestinationCreateWithURL(tempURL as CFURL, "public.heics" as CFString, images.count, nil) else {
            throw SafariumError.encode("CGImageDestinationCreateWithURL failed for public.heics")
        }
        CGImageDestinationSetProperties(
            dst,
            [kCGImagePropertyHEICSDictionary: [kCGImagePropertyHEICSLoopCount: loopCount]] as CFDictionary
        )
        for (idx, img) in images.enumerated() {
            let props: [CFString: Any] = [
                kCGImagePropertyHEICSDictionary: [
                    kCGImagePropertyHEICSUnclampedDelayTime: Double(delays[idx]) / 1000.0
                ],
                kCGImageDestinationLossyCompressionQuality: quality,
            ]
            CGImageDestinationAddImage(dst, img, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dst) else {
            throw SafariumError.encode("CGImageDestinationFinalize failed for public.heics")
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        let byteCount = (attrs[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount > 0 else {
            throw SafariumError.encode("ImageIO produced 0 bytes for public.heics")
        }

        try SafeFilePublisher.publish(tempURL: tempURL, to: outputURL, overwrite: overwrite)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return ImageSequenceReport(
            outputPath: outputURL.path,
            format: .heics,
            width: w,
            height: h,
            frameCount: images.count,
            loopCount: loopCount,
            bytes: byteCount,
            wallMs: elapsedMs
        )
    }
}
