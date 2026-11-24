import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SafariumCore
import XCTest
@testable import SafariumContainers

/// Legacy container coverage: Ogg (RFC 3533 pages, Vorbis I decode, Ogg FLAC) and MPEG-1/2 Program Stream.
/// Real-asset checks run whenever the `Main` drive is mounted; they are never skipped.
final class LegacyContainerVorbisTests: XCTestCase {
    // MARK: - Assets

    private static let projectsRoot = ProcessInfo.processInfo.environment["SAFARIUM_LEGACY_ASSETS_ROOT"] ?? ""
    private static let pianoOgg = projectsRoot + "/piano.ogg"
    private static let pianoWav = projectsRoot + "/piano.wav"
    private static let howtoMPEG = projectsRoot + "/HowtoUse1927.mpeg"
    private static let curiousBach = projectsRoot + "/curious-bach-wtc-prelude-c-major.ogg"
    private static let calmSatie = projectsRoot + "/calm-satie-gymnopedie-1.ogg"
    private static let footstepSnow = projectsRoot + "/footstep_snow_002.ogg"

    /// Returns the asset URL when the drive is mounted (failing if the asset itself is missing),
    /// or nil only when the whole `Main` drive is absent. Never skips.
    private func realAsset(_ path: String) -> URL? {
        guard !Self.projectsRoot.isEmpty, FileManager.default.fileExists(atPath: Self.projectsRoot) else {
            print("[legacy] NOTE: \(Self.projectsRoot) not mounted; real-asset check for \((path as NSString).lastPathComponent) not executed")
            return nil
        }
        let exists = FileManager.default.fileExists(atPath: path)
        XCTAssertTrue(exists, "drive is mounted but asset is missing: \(path)")
        return exists ? URL(fileURLWithPath: path) : nil
    }

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safarium-legacy-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func assertSafariumError(_ expr: @autoclosure () throws -> some Any, _ label: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expr(), label, file: file, line: line) { err in
            XCTAssertTrue(err is SafariumError, "\(label): expected SafariumError, got \(type(of: err)): \(err)", file: file, line: line)
        }
    }

    private struct StopDecode: Error {}

    // MARK: - Statistics

    private struct CorrAcc {
        var n = 0.0, sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0, sd2 = 0.0
        @inline(__always) mutating func add(_ x: Float, _ y: Float) {
            let a = Double(x), b = Double(y)
            n += 1; sx += a; sy += b; sxx += a * a; syy += b * b; sxy += a * b
            let d = a - b
            sd2 += d * d
        }
        var r: Double {
            guard n > 1 else { return .nan }
            let cov = sxy - sx * sy / n
            let vx = sxx - sx * sx / n
            let vy = syy - sy * sy / n
            return cov / (vx * vy).squareRoot()
        }
        var rmsDiff: Double { n > 0 ? (sd2 / n).squareRoot() : .nan }
    }

    // MARK: - Synthetic Vorbis builder (Vorbis I bit packing, LSB first)

    private struct LSBBitWriter {
        var bytes: [UInt8] = []
        var bitPos = 0
        mutating func write(_ value: UInt64, _ n: Int) {
            for i in 0..<n {
                if bitPos % 8 == 0 { bytes.append(0) }
                if (value >> UInt64(i)) & 1 == 1 { bytes[bytes.count - 1] |= UInt8(1 << (bitPos % 8)) }
                bitPos += 1
            }
        }
    }

    private static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }

    private static func vorbisIDHeader(channels: Int, rate: Int, e0: Int = 8, e1: Int = 11, framing: UInt8 = 1) -> Data {
        var b: [UInt8] = [1] + Array("vorbis".utf8)
        b += le32(0)
        b.append(UInt8(channels))
        b += le32(UInt32(rate))
        b += le32(0) + le32(UInt32(bitPattern: 96_000)) + le32(0)
        b.append(UInt8(e0 | (e1 << 4)))
        b.append(framing)
        return Data(b)
    }

    private static func vorbisCommentHeader(vendor: String = "safarium-synthetic", comments: [String] = ["TITLE=silence"]) -> Data {
        var b: [UInt8] = [3] + Array("vorbis".utf8)
        b += le32(UInt32(vendor.utf8.count)) + Array(vendor.utf8)
        b += le32(UInt32(comments.count))
        for c in comments { b += le32(UInt32(c.utf8.count)) + Array(c.utf8) }
        b.append(1)
        return Data(b)
    }

    /// One codebook (dim 1, `entries` x length 1), one floor1 (no partitions), one residue 0 (no books),
    /// one mapping, two modes (short + long).
    private static func vorbisSetupHeader(codebookSync: UInt64 = 0x564342, entries: Int = 2) -> Data {
        var w = LSBBitWriter()
        w.write(0, 8)                                   // codebook_count - 1
        w.write(codebookSync, 24)
        w.write(1, 16)                                  // dimensions
        w.write(UInt64(entries), 24)
        w.write(0, 1)                                   // ordered
        w.write(0, 1)                                   // sparse
        for _ in 0..<entries { w.write(0, 5) }          // length 1
        w.write(0, 4)                                   // lookup type 0
        w.write(0, 6); w.write(0, 16)                   // time domain: 1 x type 0
        w.write(0, 6); w.write(1, 16)                   // 1 floor, type 1
        w.write(0, 5)                                   // partitions = 0
        w.write(1, 2)                                   // multiplier - 1
        w.write(8, 4)                                   // rangebits
        w.write(0, 6); w.write(0, 16)                   // 1 residue, type 0
        w.write(0, 24); w.write(128, 24); w.write(31, 24) // begin, end, partition_size - 1
        w.write(0, 6); w.write(0, 8)                    // classifications - 1, classbook
        w.write(0, 3); w.write(0, 1)                    // cascade (no books)
        w.write(0, 6); w.write(0, 16)                   // 1 mapping, type 0
        w.write(0, 1); w.write(0, 1); w.write(0, 2)     // submaps flag, coupling flag, reserved
        w.write(0, 8); w.write(0, 8); w.write(0, 8)     // submap: time, floor, residue
        w.write(1, 6)                                   // mode_count - 1 = 1
        w.write(0, 1); w.write(0, 16); w.write(0, 16); w.write(0, 8)
        w.write(1, 1); w.write(0, 16); w.write(0, 16); w.write(0, 8)
        w.write(1, 1)                                   // framing
        return Data([5] + Array("vorbis".utf8) + w.bytes)
    }

    private static func vorbisAudioPacket(long: Bool, prev: Bool, next: Bool, channels: Int) -> Data {
        var w = LSBBitWriter()
        w.write(0, 1)                                   // audio packet
        w.write(long ? 1 : 0, 1)                        // mode number (1 bit for 2 modes)
        if long { w.write(prev ? 1 : 0, 1); w.write(next ? 1 : 0, 1) }
        for _ in 0..<channels { w.write(0, 1) }         // floor1 nonzero = 0 (unused)
        return Data(w.bytes)
    }

    /// Builds a complete silent Vorbis-in-Ogg stream. Returns stream bytes and the untrimmed frame total.
    private static func syntheticVorbisStream(
        channels: Int,
        rate: Int = 48_000,
        trimTail: Int64 = 0,
        setup: Data? = nil
    ) throws -> (data: Data, untrimmed: Int64, finalGranule: Int64) {
        var w = OggPageWriter(serialNumber: 0x5AFA_0001)
        try w.append(packet: vorbisIDHeader(channels: channels, rate: rate), granulePosition: 0, flush: true)
        try w.append(packet: vorbisCommentHeader(), granulePosition: 0)
        try w.append(packet: setup ?? vorbisSetupHeader(), granulePosition: 0, flush: true)
        // short short long long long short short ... (window flags consistent with neighbours)
        let pattern: [Bool] = [false, false, true, true, true, false, false, false, true, false,
                               false, true, true, false, false, false, false, true, true, false]
        let sizes = pattern.map { $0 ? 2048 : 256 }
        var granule: Int64 = 0
        var totals: [Int64] = []
        for i in pattern.indices {
            if i > 0 { granule += Int64(sizes[i - 1] / 4 + sizes[i] / 4) }
            totals.append(granule)
        }
        let untrimmed = totals.last!
        let finalGranule = untrimmed - trimTail
        for i in pattern.indices {
            let long = pattern[i]
            let prev = i > 0 ? pattern[i - 1] : false
            let next = i + 1 < pattern.count ? pattern[i + 1] : false
            let pkt = vorbisAudioPacket(long: long, prev: prev, next: next, channels: channels)
            let isLast = i == pattern.count - 1
            let endOfFirstPage = i == 9
            try w.append(
                packet: pkt,
                granulePosition: isLast ? finalGranule : totals[i],
                flush: endOfFirstPage,
                endOfStream: isLast
            )
        }
        return (w.serializedStream(), untrimmed, finalGranule)
    }

    // MARK: - Test 1a: synthetic Vorbis (self-contained, no external media)

    func testSyntheticVorbisHeadersAndSilentStreamDecode() throws {
        let id = try OggVorbisDecoder.parseIdentificationHeader(Self.vorbisIDHeader(channels: 2, rate: 44_100))
        XCTAssertEqual(id.channels, 2)
        XCTAssertEqual(id.sampleRate, 44_100)
        XCTAssertEqual(id.blocksize0, 256)
        XCTAssertEqual(id.blocksize1, 2048)
        XCTAssertEqual(id.bitrateNominal, 96_000)
        let cm = try OggVorbisDecoder.parseCommentHeader(Self.vorbisCommentHeader())
        XCTAssertEqual(cm.vendor, "safarium-synthetic")
        XCTAssertEqual(cm.comments, ["TITLE=silence"])

        let dec = try OggVorbisStreamDecoder(
            identificationPacket: Self.vorbisIDHeader(channels: 1, rate: 48_000),
            commentPacket: Self.vorbisCommentHeader(),
            setupPacket: Self.vorbisSetupHeader()
        )
        XCTAssertEqual(dec.blockSize(ofAudioPacket: Self.vorbisAudioPacket(long: false, prev: false, next: false, channels: 1)), 256)
        XCTAssertEqual(dec.blockSize(ofAudioPacket: Self.vorbisAudioPacket(long: true, prev: false, next: true, channels: 1)), 2048)
        XCTAssertNil(dec.blockSize(ofAudioPacket: Data([0x01])), "header-type packet is not audio")
        // First packet primes overlap (0 frames); then prev/4 + cur/4.
        XCTAssertEqual(try dec.decode(packet: Self.vorbisAudioPacket(long: false, prev: false, next: false, channels: 1)), 0)
        XCTAssertEqual(try dec.decode(packet: Self.vorbisAudioPacket(long: true, prev: false, next: false, channels: 1)), 64 + 512)
        XCTAssertEqual(try dec.decode(packet: Self.vorbisAudioPacket(long: false, prev: false, next: false, channels: 1)), 512 + 64)

        for channels in [1, 2] {
            let trim: Int64 = 37
            let s = try Self.syntheticVorbisStream(channels: channels, trimTail: trim)
            let pages = try OggPage.parseAll(s.data)
            XCTAssertGreaterThanOrEqual(pages.count, 4)
            XCTAssertTrue(pages.first!.isBeginningOfStream)
            XCTAssertTrue(pages.last!.isEndOfStream)

            var frames: Int64 = 0
            var maxChunk = 0
            var nonZero = 0
            let summary = try OggVorbisDecoder.streamToFloat32PCM(data: s.data, chunkFrames: 100) { buf, n, rate, ch in
                XCTAssertEqual(rate, 48_000)
                XCTAssertEqual(ch, channels)
                XCTAssertEqual(buf.count, n * ch)
                maxChunk = max(maxChunk, n)
                frames += Int64(n)
                for v in buf where v != 0 { nonZero += 1 }
            }
            print("[legacy] synthetic vorbis ch=\(channels): frames=\(summary.frames) untrimmed=\(s.untrimmed) finalGranule=\(s.finalGranule) trimmedTrailing=\(summary.trimmedTrailingFrames) packets=\(summary.audioPackets) maxChunk=\(maxChunk)")
            XCTAssertEqual(summary.frames, s.finalGranule)
            XCTAssertEqual(frames, s.finalGranule)
            XCTAssertEqual(summary.trimmedTrailingFrames, trim)
            XCTAssertEqual(summary.trimmedLeadingFrames, 0)
            XCTAssertEqual(summary.audioPackets, 20)
            XCTAssertEqual(summary.finalGranulePosition, s.finalGranule)
            XCTAssertEqual(summary.nonFiniteSamples, 0)
            XCTAssertEqual(summary.peak, 0)
            XCTAssertEqual(summary.rms, 0)
            XCTAssertEqual(nonZero, 0)
            XCTAssertLessThanOrEqual(maxChunk, 100)
            XCTAssertEqual(summary.maxChunkFrames, 100)
            XCTAssertEqual(summary.durationSeconds, Double(s.finalGranule) / 48_000, accuracy: 1e-12)
        }
    }

    func testMalformedVorbisHeadersAndCodebooksAreRejected() throws {
        // Identification header invariants.
        assertSafariumError(try OggVorbisDecoder.parseIdentificationHeader(Data([1, 0x76])), "short id header")
        var badSig = [UInt8](Self.vorbisIDHeader(channels: 1, rate: 48_000)); badSig[1] = 0x56
        assertSafariumError(try OggVorbisDecoder.parseIdentificationHeader(Data(badSig)), "bad id signature")
        assertSafariumError(try OggVorbisDecoder.parseIdentificationHeader(Self.vorbisIDHeader(channels: 0, rate: 48_000)), "zero channels")
        assertSafariumError(try OggVorbisDecoder.parseIdentificationHeader(Self.vorbisIDHeader(channels: 1, rate: 0)), "zero rate")
        assertSafariumError(try OggVorbisDecoder.parseIdentificationHeader(Self.vorbisIDHeader(channels: 1, rate: 48_000, e0: 11, e1: 8)), "blocksize0 > blocksize1")
        assertSafariumError(try OggVorbisDecoder.parseIdentificationHeader(Self.vorbisIDHeader(channels: 1, rate: 48_000, e0: 5, e1: 8)), "blocksize below 64")
        assertSafariumError(try OggVorbisDecoder.parseIdentificationHeader(Self.vorbisIDHeader(channels: 1, rate: 48_000, framing: 0)), "id framing bit")
        // Comment header invariants.
        let comment = [UInt8](Self.vorbisCommentHeader())
        assertSafariumError(try OggVorbisDecoder.parseCommentHeader(Data(comment.prefix(12))), "truncated comment header")
        var noFraming = comment; noFraming[noFraming.count - 1] = 0
        assertSafariumError(try OggVorbisDecoder.parseCommentHeader(Data(noFraming)), "comment framing bit")
        var hugeLen = comment; hugeLen[7] = 0xFF; hugeLen[8] = 0xFF; hugeLen[9] = 0xFF; hugeLen[10] = 0x7F
        assertSafariumError(try OggVorbisDecoder.parseCommentHeader(Data(hugeLen)), "vendor length overflow")
        // Setup / codebook invariants.
        let id = Self.vorbisIDHeader(channels: 1, rate: 48_000)
        let cm = Self.vorbisCommentHeader()
        assertSafariumError(try OggVorbisStreamDecoder(identificationPacket: id, commentPacket: cm, setupPacket: Self.vorbisSetupHeader(codebookSync: 0x123456)), "bad codebook sync")
        assertSafariumError(try OggVorbisStreamDecoder(identificationPacket: id, commentPacket: cm, setupPacket: Self.vorbisSetupHeader(entries: 3)), "overpopulated Huffman tree")
        let setup = [UInt8](Self.vorbisSetupHeader())
        assertSafariumError(try OggVorbisStreamDecoder(identificationPacket: id, commentPacket: cm, setupPacket: Data(setup.prefix(setup.count / 2))), "truncated setup header")
        var setupSig = setup; setupSig[0] = 4
        assertSafariumError(try OggVorbisStreamDecoder(identificationPacket: id, commentPacket: cm, setupPacket: Data(setupSig)), "bad setup packet type")
        // A full stream whose setup codebook is corrupt fails the streaming decode with SafariumError.
        let corrupt = try Self.syntheticVorbisStream(channels: 1, setup: Self.vorbisSetupHeader(codebookSync: 0x000000))
        assertSafariumError(try OggVorbisDecoder.streamToFloat32PCM(data: corrupt.data) { _, _, _, _ in }, "stream with corrupt codebook")
        // A stream with no Vorbis logical stream is rejected.
        var w = OggPageWriter(serialNumber: 9)
        try w.append(packet: Data("OpusHead\u{1}\u{2}\u{0}\u{0}\u{80}\u{bb}\u{0}\u{0}\u{0}\u{0}\u{0}".utf8), granulePosition: 0, flush: true, endOfStream: true)
        assertSafariumError(try OggVorbisDecoder.streamToFloat32PCM(data: w.serializedStream()) { _, _, _, _ in }, "non-Vorbis stream")
    }

    // MARK: - Test 1b: piano.ogg vs piano.wav

    private struct BiquadDF2T {
        let b0: Double, b1: Double, b2: Double, a1: Double, a2: Double
        var z1: Double = 0, z2: Double = 0

        static func butterworthHighpass(cutoffHz: Double, sampleRate: Double) -> BiquadDF2T {
            let w0 = 2.0 * Double.pi * cutoffHz / sampleRate
            let cosW0 = cos(w0)
            let alpha = sin(w0) / sqrt(2.0)
            let a0 = 1.0 + alpha
            return BiquadDF2T(
                b0: ((1.0 + cosW0) * 0.5) / a0,
                b1: (-(1.0 + cosW0)) / a0,
                b2: ((1.0 + cosW0) * 0.5) / a0,
                a1: (-2.0 * cosW0) / a0,
                a2: (1.0 - alpha) / a0
            )
        }

        static func butterworthLowpass(cutoffHz: Double, sampleRate: Double) -> BiquadDF2T {
            let w0 = 2.0 * Double.pi * cutoffHz / sampleRate
            let cosW0 = cos(w0)
            let alpha = sin(w0) / sqrt(2.0)
            let a0 = 1.0 + alpha
            return BiquadDF2T(
                b0: ((1.0 - cosW0) * 0.5) / a0,
                b1: (1.0 - cosW0) / a0,
                b2: ((1.0 - cosW0) * 0.5) / a0,
                a1: (-2.0 * cosW0) / a0,
                a2: (1.0 - alpha) / a0
            )
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    func testPianoOggMatchesReferenceWAV() throws {
        guard let oggURL = realAsset(Self.pianoOgg), let wavURL = realAsset(Self.pianoWav) else { return }

        let info = try OggVorbisDecoder.probe(url: oggURL)
        let rate = info.sampleRate
        let ch = info.channels
        XCTAssertEqual(rate, 44_100)
        XCTAssertEqual(ch, 2)
        XCTAssertGreaterThan(info.lastGranulePosition, 8_000_000)

        let wavFile = try AVAudioFile(forReading: wavURL)
        let wavRate = wavFile.fileFormat.sampleRate
        let wavCh = Int(wavFile.fileFormat.channelCount)
        XCTAssertEqual(wavRate, 48_000)
        XCTAssertEqual(wavCh, 1)
        print("[legacy] piano.ogg: rate=\(rate) ch=\(ch) lastGranule=\(info.lastGranulePosition) duration=\(info.durationSeconds)s vendor=\(info.vendor)")
        print("[legacy] piano.wav (render.py DSP output): rate=\(wavRate) ch=\(wavCh) frames=\(wavFile.length)")

        // `_build/piano.wav` was produced by `ห้วงเวลาขาวดำ/tools/render.py` (`_make_piano`):
        // [0:a]atrim=4.2:193.0, acrossfade=d=2.0, aresample=48000, aformat=mono, highpass=70, lowpass=7000, volume=-13dB.
        // Note `render.py` loops at t = 193.0 - 4.2 - 2.0 = 186.8s, so [0s..184s] matches the unlooped `[4.2s..188.2s]` slice.
        let preRollSec = 0.2
        let oggSkipFrames = Int((4.2 - preRollSec) * Double(rate))
        let totalCompareSec = 184.0
        let oggTakeFrames = Int((totalCompareSec + preRollSec + 0.5) * Double(rate))
        let oggEndFrame = oggSkipFrames + oggTakeFrames

        var fullOggMono: [Float] = []
        fullOggMono.reserveCapacity(oggTakeFrames)
        var totalDecodedFrames: Int64 = 0
        var maxChunkSeen = 0
        let downmixCoeff = Float(sqrt(0.5)) // libswresample stereo->mono matrix: 1/sqrt(2) * (L + R)
        let summary = try OggVorbisDecoder.streamToFloat32PCM(url: oggURL, chunkFrames: 8192) { buf, n, r, streamCh in
            XCTAssertEqual(r, rate)
            XCTAssertEqual(streamCh, ch)
            maxChunkSeen = max(maxChunkSeen, n)
            let chunkStart = Int(totalDecodedFrames)
            totalDecodedFrames += Int64(n)
            let chunkEnd = chunkStart + n
            guard chunkEnd > oggSkipFrames && chunkStart < oggEndFrame else { return }
            let lo = max(0, oggSkipFrames - chunkStart)
            let hi = min(n, oggEndFrame - chunkStart)
            for f in lo..<hi {
                fullOggMono.append(downmixCoeff * (buf[f * 2] + buf[f * 2 + 1]))
            }
        }
        XCTAssertLessThanOrEqual(maxChunkSeen, 8192)
        XCTAssertEqual(summary.sampleRate, rate)
        XCTAssertEqual(summary.channels, ch)
        XCTAssertEqual(summary.nonFiniteSamples, 0)
        XCTAssertEqual(summary.frames, info.lastGranulePosition, "decoded frames must equal the final granule")
        XCTAssertEqual(totalDecodedFrames, info.lastGranulePosition)
        XCTAssertGreaterThanOrEqual(fullOggMono.count, Int(totalCompareSec * Double(rate)))

        guard let srcFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false),
              let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            return XCTFail("failed to build AVAudioConverter 44.1k->48k")
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(fullOggMono.count)),
              let outBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: AVAudioFrameCount(Int(Double(fullOggMono.count) * 48_000.0 / Double(rate)) + 8192)) else {
            return XCTFail("failed to allocate AVAudioPCMBuffer")
        }
        inBuf.frameLength = AVAudioFrameCount(fullOggMono.count)
        if let ch0 = inBuf.floatChannelData?[0] {
            fullOggMono.withUnsafeBufferPointer { srcPtr in
                ch0.update(from: srcPtr.baseAddress!, count: fullOggMono.count)
            }
        }
        var fedAll = false
        var convError: NSError?
        let status = converter.convert(to: outBuf, error: &convError) { _, outStatus in
            if fedAll {
                outStatus.pointee = .endOfStream
                return nil
            }
            fedAll = true
            outStatus.pointee = .haveData
            return inBuf
        }
        XCTAssertNil(convError)
        XCTAssertTrue(status == .haveData || status == .endOfStream || status == .inputRanDry)

        let resampledCount = Int(outBuf.frameLength)
        guard let resPtr = outBuf.floatChannelData?[0] else {
            return XCTFail("missing resampled floatChannelData")
        }
        var hpf = BiquadDF2T.butterworthHighpass(cutoffHz: 70.0, sampleRate: 48_000)
        var lpf = BiquadDF2T.butterworthLowpass(cutoffHz: 7_000.0, sampleRate: 48_000)
        let gain = pow(10.0, -13.0 / 20.0)
        var simSamples = [Float](repeating: 0, count: resampledCount)
        for i in 0..<resampledCount {
            simSamples[i] = Float(lpf.process(hpf.process(Double(resPtr[i]))) * gain)
        }

        let wavFramesToRead = Int(totalCompareSec * 48_000)
        guard let wbuf = AVAudioPCMBuffer(pcmFormat: wavFile.processingFormat, frameCapacity: AVAudioFrameCount(wavFramesToRead)) else {
            return XCTFail("cannot allocate WAV buffer")
        }
        try wavFile.read(into: wbuf, frameCount: AVAudioFrameCount(wavFramesToRead))
        XCTAssertEqual(Int(wbuf.frameLength), wavFramesToRead)
        guard let wch = wbuf.floatChannelData?[0] else { return XCTFail("missing WAV floatChannelData") }

        let anchor = Int(preRollSec * 48_000)
        // Phase A: best integer lag search over [1s..21s]
        let headStart = 48_000
        let headEnd = 21 * 48_000
        func corrRange(_ lo: Int, _ hi: Int, lag: Int) -> CorrAcc {
            var acc = CorrAcc()
            for i in lo..<hi { acc.add(simSamples[anchor + i + lag], wch[i]) }
            return acc
        }
        var bestCoarse = corrRange(headStart, headStart + 48_000, lag: 0)
        var coarseLag = 0
        for lag in -512...512 where lag != 0 {
            let cand = corrRange(headStart, headStart + 48_000, lag: lag)
            if cand.r > bestCoarse.r { bestCoarse = cand; coarseLag = lag }
        }
        var best = corrRange(headStart, headEnd, lag: coarseLag)
        var bestLag = coarseLag
        for lag in max(-512, coarseLag - 8)...min(512, coarseLag + 8) where lag != coarseLag {
            let cand = corrRange(headStart, headEnd, lag: lag)
            if cand.r > best.r { best = cand; bestLag = lag }
        }
        print(String(format: "[legacy] piano head [1s..21s]: bestLag=%d r=%.9f rmsDiff=%.3e (samples=%.0f)",
                     bestLag, best.r, best.rmsDiff, best.n))
        XCTAssertGreaterThanOrEqual(best.r, 0.999)
        XCTAssertLessThanOrEqual(best.rmsDiff, 1e-3)

        // Phase B: long-span comparison [1s..184s] at bestLag
        let fullEnd = min(wavFramesToRead, resampledCount - anchor - max(0, bestLag) - 1)
        let fullAcc = corrRange(headStart, fullEnd, lag: bestLag)
        XCTAssertGreaterThan(fullEnd - headStart, 180 * 48_000)
        print(String(format: "[legacy] piano full overlap [1s..%.1fs]: bestLag=%d r=%.9f rmsDiff=%.3e (samples=%.0f)",
                     Double(fullEnd) / 48_000.0, bestLag, fullAcc.r, fullAcc.rmsDiff, fullAcc.n))
        XCTAssertGreaterThanOrEqual(fullAcc.r, 0.999)
        XCTAssertLessThanOrEqual(fullAcc.rmsDiff, 1e-3)
    }

    // MARK: - Test 2a: other real Ogg Vorbis assets

    func testRealOggVorbisAssetsDecodeCleanly() throws {
        let cases: [(path: String, channels: Int?)] = [
            (Self.calmSatie, 2),
            (Self.curiousBach, 1),
            (Self.footstepSnow, nil),
        ]
        var executed = 0
        for c in cases {
            guard let url = realAsset(c.path) else { continue }
            let name = url.lastPathComponent
            let info = try OggVorbisDecoder.probe(url: url)
            let inspect = try OggContainer.inspect(url: url)
            XCTAssertEqual(inspect.streams.first?.codec, .vorbis, name)
            var maxChunk = 0
            var frames: Int64 = 0
            let s = try OggVorbisDecoder.streamToFloat32PCM(url: url, chunkFrames: 16_384) { buf, n, _, ch in
                XCTAssertEqual(buf.count, n * ch)
                maxChunk = max(maxChunk, n)
                frames += Int64(n)
            }
            print(String(format: "[legacy] %@: rate=%d ch=%d frames=%lld duration=%.4fs probeDuration=%.4fs peak=%.5f rms=%.5f nonFinite=%d packets=%d maxChunk=%d pages=%d",
                         name, s.sampleRate, s.channels, s.frames, s.durationSeconds, info.durationSeconds, s.peak, s.rms,
                         s.nonFiniteSamples, s.audioPackets, maxChunk, inspect.pageCount))
            if let expected = c.channels { XCTAssertEqual(s.channels, expected, name) }
            XCTAssertEqual(s.channels, info.channels, name)
            XCTAssertEqual(s.sampleRate, info.sampleRate, name)
            XCTAssertEqual(frames, s.frames, name)
            XCTAssertGreaterThan(s.durationSeconds, 0, name)
            XCTAssertEqual(s.frames, info.lastGranulePosition, "\(name): frames vs final granule")
            XCTAssertEqual(s.nonFiniteSamples, 0, name)
            XCTAssertLessThanOrEqual(s.peak, 1.5, name)
            XCTAssertGreaterThan(s.rms, 0, name)
            XCTAssertLessThanOrEqual(maxChunk, 16_384, name)
            executed += 1
        }
        if !Self.projectsRoot.isEmpty, FileManager.default.fileExists(atPath: Self.projectsRoot) {
            XCTAssertEqual(executed, cases.count, "all real Ogg assets must be checked when the drive is mounted")
        }
    }

    func testDecodeToWAVProducesReadableFile() throws {
        guard let url = realAsset(Self.footstepSnow) else { return }
        let dir = try makeTempDir("wav")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Reference: streamed float decode kept in memory (short sound effect).
        var ref = [Float]()
        let refSummary = try OggVorbisDecoder.streamToFloat32PCM(url: url) { buf, _, _, _ in ref.append(contentsOf: buf) }

        for format in [OggWAVSampleFormat.float32, .int16] {
            let out = dir.appendingPathComponent("footstep-\(format.rawValue).wav")
            let s = try OggVorbisDecoder.decodeToWAV(url: url, outputURL: out, format: format)
            let f = try AVAudioFile(forReading: out)
            print("[legacy] decodeToWAV \(format.rawValue): rate=\(f.fileFormat.sampleRate) ch=\(f.fileFormat.channelCount) frames=\(f.length) summaryFrames=\(s.frames) bytes=\((try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.intValue ?? -1)")
            XCTAssertEqual(f.fileFormat.sampleRate, Double(s.sampleRate))
            XCTAssertEqual(Int(f.fileFormat.channelCount), s.channels)
            XCTAssertEqual(f.length, s.frames)
            XCTAssertGreaterThan(f.length, 0)
            XCTAssertEqual(s.frames, refSummary.frames)
            XCTAssertEqual(f.fileFormat.commonFormat, format == .float32 ? .pcmFormatFloat32 : .pcmFormatInt16)

            guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)) else {
                return XCTFail("buffer alloc")
            }
            try f.read(into: b)
            XCTAssertEqual(Int(b.frameLength), Int(s.frames))
            guard let p = b.floatChannelData else { return XCTFail("float processing format expected") }
            var maxErr: Float = 0
            for i in 0..<Int(b.frameLength) {
                for c in 0..<s.channels {
                    maxErr = max(maxErr, abs(p[c][i] - ref[i * s.channels + c]))
                }
            }
            print("[legacy] decodeToWAV \(format.rawValue): max |wav - decode| = \(maxErr)")
            if format == .float32 {
                XCTAssertEqual(maxErr, 0, "float32 WAV must be bit-exact to the streamed decode")
            } else {
                XCTAssertLessThanOrEqual(maxErr, 1.0 / 32768.0 + 1e-6, "int16 WAV must be within one LSB")
            }
        }
        // Refuses to overwrite without permission.
        assertSafariumError(
            try OggVorbisDecoder.decodeToWAV(url: url, outputURL: dir.appendingPathComponent("footstep-float32.wav")),
            "decodeToWAV overwrite guard"
        )
    }

    // MARK: - Test 2b: Ogg container (CRC, paging, FLAC, corruption)

    func testOggCRC32MatchesRFC3533Definition() {
        // Independent bitwise MSB-first CRC: poly 0x04C11DB7, init 0, no reflection, no final XOR.
        func bitwise(_ bytes: [UInt8]) -> UInt32 {
            var crc: UInt32 = 0
            for b in bytes {
                crc ^= UInt32(b) << 24
                for _ in 0..<8 { crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
            }
            return crc
        }
        let check = Array("123456789".utf8)
        XCTAssertEqual(OggCRC32.checksum(check), 0x89A1_897F, "CRC-32/CKSUM check value without final XOR")
        XCTAssertEqual(OggCRC32.checksum(check), bitwise(check))
        XCTAssertEqual(OggCRC32.checksum([UInt8]()), 0)
        var rng = SystemRandomNumberGenerator()
        for len in [1, 3, 255, 4096] {
            let bytes = (0..<len).map { _ in UInt8.random(in: 0...255, using: &rng) }
            XCTAssertEqual(OggCRC32.checksum(bytes), bitwise(bytes), "len \(len)")
            XCTAssertEqual(OggCRC32.checksum(Data(bytes)), bitwise(bytes), "Data len \(len)")
        }
    }

    func testOggMultiPageRoundTripWithSpanningPackets() throws {
        var rng = SystemRandomNumberGenerator()
        let sizes = [0, 1, 254, 255, 256, 510, 70_000, 3, 65_025, 131_000, 17]
        let packets = sizes.map { n in Data((0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }) }
        var w = OggPageWriter(serialNumber: 0xCAFE_F00D, firstSequence: 7)
        for (i, p) in packets.enumerated() {
            try w.append(packet: p, granulePosition: Int64((i + 1) * 1000), flush: i == 0, endOfStream: i == packets.count - 1)
        }
        let bytes = w.serializedStream()
        let pages = try OggPage.parseAll(bytes)
        XCTAssertEqual(pages.count, w.pages.count)
        XCTAssertGreaterThanOrEqual(pages.count, 5)
        XCTAssertTrue(pages.contains { $0.isContinued }, "large packets must span pages")
        XCTAssertTrue(pages.contains { $0.granulePosition == -1 }, "a page with no completed packet carries granule -1")
        XCTAssertTrue(pages.first!.isBeginningOfStream)
        XCTAssertTrue(pages.last!.isEndOfStream)
        for (i, p) in pages.enumerated() {
            XCTAssertEqual(p.pageSequence, UInt32(7 + i))
            XCTAssertEqual(p.serialNumber, 0xCAFE_F00D)
            XCTAssertLessThanOrEqual(p.segmentTable.count, 255)
            XCTAssertEqual(p, w.pages[i])
            let ser = p.serialized()
            let crc = ser.withUnsafeBytes { OggCRC32.pageChecksum($0) }
            XCTAssertEqual(crc, p.checksum)
        }

        let demux = OggStreamDemuxer(data: bytes)
        var out: [OggPacket] = []
        while let p = try demux.nextPacket() { out.append(p) }
        XCTAssertEqual(out.count, packets.count)
        for (i, p) in out.enumerated() {
            XCTAssertEqual(p.data, packets[i], "packet \(i) (\(sizes[i]) bytes)")
            XCTAssertEqual(p.packetIndex, i)
            XCTAssertEqual(p.serialNumber, 0xCAFE_F00D)
            if p.granulePosition != -1 { XCTAssertEqual(p.granulePosition, Int64((i + 1) * 1000)) }
        }
        XCTAssertTrue(out.first!.isBeginningOfStream)
        XCTAssertTrue(out.last!.isLastPacketOfStream)
        XCTAssertEqual(out.last!.granulePosition, Int64(packets.count * 1000))

        // Same bytes from disk through the chunked reader (small chunks force refills mid-page).
        let dir = try makeTempDir("ogg")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("multi.ogg")
        try bytes.write(to: file)
        let reader = try OggPageReader(url: file, chunkSize: 4096)
        var n = 0
        while let p = try reader.nextPage() {
            XCTAssertEqual(p, pages[n])
            n += 1
        }
        XCTAssertEqual(n, pages.count)
        XCTAssertEqual(reader.offset, Int64(bytes.count))
        let report = try OggContainer.inspect(url: file)
        XCTAssertEqual(report.pageCount, pages.count)
        XCTAssertEqual(report.streams.count, 1)
        XCTAssertEqual(report.streams[0].packets, packets.count)
        XCTAssertTrue(report.streams[0].sawEOS)
    }

    func testOggPageWriterExact255LaceBoundaryDoesNotMarkFreshPacketContinued() throws {
        // 255 tiny 1-byte packets fill segmentTable to 255 entries cleanly on page 0.
        // The 256th packet begins fresh on page 1 and MUST NOT set flagContinued.
        var w = OggPageWriter(serialNumber: 0x1234_5678, firstSequence: 0)
        var expected: [Data] = []
        for i in 0..<256 {
            let pkt = Data([UInt8(i & 0xFF)])
            expected.append(pkt)
            try w.append(packet: pkt, granulePosition: Int64(i + 1), flush: false, endOfStream: i == 255)
        }
        let stream = w.serializedStream()
        let pages = try OggPage.parseAll(stream)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].segmentTable.count, 255)
        XCTAssertFalse(pages[1].isContinued, "fresh packet starting at lace 255 boundary must NOT have flagContinued set")
        XCTAssertTrue(pages[1].isEndOfStream)

        let demux = OggStreamDemuxer(data: stream)
        var recovered: [Data] = []
        while let pkt = try demux.nextPacket() {
            recovered.append(pkt.data)
        }
        XCTAssertEqual(recovered, expected)
    }

    private static func syntheticOggFLAC() throws -> (ogg: Data, native: Data, totalSamples: Int64) {
        let rate = 44_100, ch = 2, bps = 16
        let total: Int64 = 3 * 4096
        var si = [UInt8](repeating: 0, count: 34)
        si[0] = 0x10; si[1] = 0x00; si[2] = 0x10; si[3] = 0x00 // min/max block 4096
        si[10] = UInt8((rate >> 12) & 0xFF)
        si[11] = UInt8((rate >> 4) & 0xFF)
        si[12] = UInt8(((rate & 0x0F) << 4) | ((ch - 1) << 1) | ((bps - 1) >> 4))
        si[13] = UInt8((((bps - 1) & 0x0F) << 4) | Int((total >> 32) & 0x0F))
        si[14] = UInt8((total >> 24) & 0xFF); si[15] = UInt8((total >> 16) & 0xFF)
        si[16] = UInt8((total >> 8) & 0xFF); si[17] = UInt8(total & 0xFF)
        let streaminfoBlock: [UInt8] = [0x00, 0x00, 0x00, 0x22] + si
        let first: [UInt8] = [0x7F] + Array("FLAC".utf8) + [1, 0, 0x00, 0x02] + Array("fLaC".utf8) + streaminfoBlock
        precondition(first.count == 51)
        let vendor = Array("safarium".utf8)
        let commentBody = le32(UInt32(vendor.count)) + vendor + le32(0)
        func blockHeader(_ type: UInt8, _ len: Int) -> [UInt8] {
            [type, UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)]
        }
        let commentPacket = blockHeader(0x84, commentBody.count) + commentBody   // wrongly flagged "last"
        let paddingPacket = blockHeader(0x01, 8) + [UInt8](repeating: 0, count: 8)
        var rng = SystemRandomNumberGenerator()
        let frames: [[UInt8]] = [300, 1000, 17].map { n in [0xFF, 0xF8] + (0..<(n - 2)).map { _ in UInt8.random(in: 0...255, using: &rng) } }

        var w = OggPageWriter(serialNumber: 0xF1AC)
        try w.append(packet: Data(first), granulePosition: 0, flush: true)
        try w.append(packet: Data(commentPacket), granulePosition: 0)
        try w.append(packet: Data(paddingPacket), granulePosition: 0, flush: true)
        for (i, f) in frames.enumerated() {
            try w.append(packet: Data(f), granulePosition: Int64(i + 1) * 4096, endOfStream: i == frames.count - 1)
        }
        var native = Array("fLaC".utf8) + streaminfoBlock
        native += blockHeader(0x04, commentBody.count) + commentBody
        native += blockHeader(0x81, 8) + [UInt8](repeating: 0, count: 8)
        for f in frames { native += f }
        return (w.serializedStream(), Data(native), total)
    }

    func testOggFLACInspectAndExtractRawFLAC() throws {
        let s = try Self.syntheticOggFLAC()
        let native = try OggContainer.extractRawFLACData(from: s.ogg)
        XCTAssertEqual(native, s.native, "native FLAC must be fLaC + STREAMINFO + metadata (last flag fixed) + frames")
        XCTAssertEqual(Array(native.prefix(4)), Array("fLaC".utf8))

        let dir = try makeTempDir("flac")
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("synthetic.oga")
        try s.ogg.write(to: input)
        let report = try OggContainer.inspect(url: input)
        XCTAssertEqual(report.streams.count, 1)
        XCTAssertEqual(report.streams[0].codec, .flac)
        XCTAssertEqual(report.streams[0].sampleRate, 44_100)
        XCTAssertEqual(report.streams[0].channels, 2)
        XCTAssertEqual(report.durationSeconds, Double(s.totalSamples) / 44_100, accuracy: 1e-9)
        XCTAssertEqual(report.tracks.first?.codecID, "flac")

        let output = dir.appendingPathComponent("synthetic.flac")
        let r = try OggContainer.extractRawFLAC(from: input, to: output)
        XCTAssertEqual(r.sampleRate, 44_100)
        XCTAssertEqual(r.channels, 2)
        XCTAssertEqual(r.bitsPerSample, 16)
        XCTAssertEqual(r.totalSamples, s.totalSamples)
        XCTAssertEqual(r.metadataBlocks, 3)
        XCTAssertEqual(r.audioFrames, 3)
        XCTAssertEqual(r.bytesWritten, Int64(s.native.count))
        XCTAssertEqual(try Data(contentsOf: output), s.native)
        assertSafariumError(try OggContainer.extractRawFLAC(from: input, to: output), "extractRawFLAC overwrite guard")

        // Non-FLAC Ogg input is rejected.
        let vorbis = try Self.syntheticVorbisStream(channels: 1)
        assertSafariumError(try OggContainer.extractRawFLACData(from: vorbis.data), "Vorbis stream is not FLAC")
        // Malformed first FLAC packet (wrong STREAMINFO length) is rejected.
        var bad = [UInt8](s.ogg)
        let firstPage = try OggPage.parseAll(s.ogg)[0]
        var body = [UInt8](firstPage.body)
        body[16] = 0x21
        let rebuilt = try OggPage(headerType: firstPage.headerType, granulePosition: firstPage.granulePosition,
                                  serialNumber: firstPage.serialNumber, pageSequence: firstPage.pageSequence,
                                  segmentTable: firstPage.segmentTable, body: Data(body)).serialized()
        bad.replaceSubrange(0..<firstPage.totalSize, with: [UInt8](rebuilt))
        assertSafariumError(try OggContainer.extractRawFLACData(from: Data(bad)), "bad STREAMINFO length")
    }

    func testCorruptAndTruncatedOggIsRejected() throws {
        let s = try Self.syntheticVorbisStream(channels: 2)
        let good = [UInt8](s.data)
        XCTAssertNoThrow(try OggPage.parseAll(s.data))

        func drain(_ bytes: [UInt8]) throws {
            let d = OggStreamDemuxer(data: Data(bytes))
            while try d.nextPacket() != nil {}
        }
        // Bad capture pattern.
        var badMagic = good; badMagic[0] = 0x6F
        assertSafariumError(try OggPage.parseAll(Data(badMagic)), "bad OggS magic (parseAll)")
        assertSafariumError(try drain(badMagic), "bad OggS magic (demux)")
        // CRC mismatch: flip one body byte of the first page.
        let firstSize = try OggPage.parse(s.data)!.size
        var badCRC = good; badCRC[firstSize - 3] ^= 0x01
        assertSafariumError(try OggPage.parseAll(Data(badCRC)), "CRC mismatch (parseAll)")
        assertSafariumError(try drain(badCRC), "CRC mismatch (demux)")
        assertSafariumError(try OggVorbisDecoder.streamToFloat32PCM(data: Data(badCRC)) { _, _, _, _ in }, "CRC mismatch (decode)")
        XCTAssertNoThrow(try OggPage.parse(Data(badCRC), verifyCRC: false), "only the CRC is wrong")
        // Truncated lacing table.
        let nseg = Int(good[26])
        XCTAssertGreaterThan(nseg, 0)
        let cutLacing = Array(good.prefix(27 + nseg / 2))
        XCTAssertNil(try OggPage.parse(Data(cutLacing)), "incomplete segment table needs more bytes")
        assertSafariumError(try OggPage.parseAll(Data(cutLacing)), "truncated lacing table (parseAll)")
        assertSafariumError(try drain(cutLacing), "truncated lacing table (demux)")
        // Truncated body mid-stream.
        assertSafariumError(try drain(Array(good.prefix(good.count - 5))), "truncated final page")
        // Reserved header_type bits and bad version.
        var reserved = good; reserved[5] |= 0x08
        assertSafariumError(try OggPage.parseAll(Data(reserved)), "reserved header_type bits")
        var version = good; version[4] = 1
        assertSafariumError(try OggPage.parseAll(Data(version)), "stream_structure_version 1")
        // Page-sequence gap: drop the second page.
        let pages = try OggPage.parseAll(s.data)
        var gap = Data()
        for (i, p) in pages.enumerated() where i != 1 { gap.append(p.serialized()) }
        assertSafariumError(try drain([UInt8](gap)), "page sequence gap")
        // Stream ending inside a spanning packet.
        var w = OggPageWriter(serialNumber: 3)
        try w.append(packet: Data(repeating: 0xAB, count: 100_000), granulePosition: 0, endOfStream: true)
        XCTAssertGreaterThan(w.pages.count, 1)
        assertSafariumError(try drain([UInt8](w.pages[0].serialized())), "unterminated spanning packet")
        // Writer validation.
        XCTAssertThrowsError(try OggPage(headerType: 0, granulePosition: 0, serialNumber: 1, pageSequence: 0, segmentTable: [10], body: Data(count: 9)))
        XCTAssertThrowsError(try OggPage(headerType: 0x10, granulePosition: 0, serialNumber: 1, pageSequence: 0, segmentTable: [], body: Data()))
    }

    // MARK: - Test 3: MPEG-1/2 Program Stream

    func testHowtoUse1927InspectAndDecodeFirstFrames() throws {
        guard let url = realAsset(Self.howtoMPEG) else { return }
        let r = try MPEG2ProgramStream.inspect(url: url)
        let seq = try XCTUnwrap(r.sequence, "sequence header expected")
        print(String(format: "[legacy] HowtoUse1927: layer=%@ packs=%d sysHeaders=%d bytes=%lld size=%dx%d dar=%@ fps=%d/%d (%.3f) bitRate=%d mpeg2=%@ pictures=%d (I %d / P %d / B %d) gops=%d duration=%.3fs",
                     r.systemLayer, r.packCount, r.systemHeaderCount, r.fileBytes, seq.width, seq.height, seq.displayAspectRatio,
                     seq.frameRateNumerator, seq.frameRateDenominator, seq.framesPerSecond, seq.bitRateBps,
                     seq.isMPEG2 ? "yes" : "no", r.pictureCount, r.iPictures, r.pPictures, r.bPictures, r.gopCount, r.durationSeconds))
        for st in r.streams {
            print("[legacy]   stream 0x\(String(st.streamID, radix: 16)) \(st.kind): pes=\(st.pesPackets) bytes=\(st.payloadBytes) pts=\(st.firstPTS90k.map(String.init) ?? "nil")...\(st.lastPTS90k.map(String.init) ?? "nil")")
        }
        XCTAssertGreaterThan(r.packCount, 0)
        XCTAssertGreaterThan(seq.width, 0)
        XCTAssertGreaterThan(seq.height, 0)
        XCTAssertGreaterThan(seq.framesPerSecond, 1)
        XCTAssertLessThan(seq.framesPerSecond, 121)
        XCTAssertGreaterThan(r.pictureCount, 0)
        XCTAssertGreaterThan(r.iPictures, 0)
        XCTAssertGreaterThan(r.gopCount, 0)
        XCTAssertGreaterThan(r.durationSeconds, 0)
        let video = r.streams.filter { $0.kind == "video" }
        let audio = r.streams.filter { $0.kind == "audio" }
        XCTAssertFalse(video.isEmpty, "video stream expected")
        XCTAssertFalse(audio.isEmpty, "audio stream expected")
        XCTAssertTrue(video.allSatisfy { $0.pesPackets > 0 && $0.payloadBytes > 0 })
        XCTAssertTrue(audio.allSatisfy { $0.pesPackets > 0 && $0.payloadBytes > 0 })
        XCTAssertEqual(r.tracks.first { $0.kind == .video }?.width, seq.width)

        var frames: [(pts: Double, w: Int, h: Int, lumaMean: Double)] = []
        let summary = try MPEG2ProgramStream.decodeVideoFrames(url: url, maxFrames: 5) { pb, pts, index in
            XCTAssertEqual(index, frames.count)
            XCTAssertTrue(pts.isValid, "frame \(index) PTS invalid")
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let planar = CVPixelBufferIsPlanar(pb)
            let base = planar ? CVPixelBufferGetBaseAddressOfPlane(pb, 0) : CVPixelBufferGetBaseAddress(pb)
            let bpr = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, 0) : CVPixelBufferGetBytesPerRow(pb)
            XCTAssertNotNil(base, "frame \(index) has no pixel data")
            XCTAssertGreaterThan(bpr, 0)
            var sum = 0.0
            var cnt = 0.0
            if let base {
                let p = base.assumingMemoryBound(to: UInt8.self)
                for y in stride(from: 0, to: h, by: 4) {
                    for x in stride(from: 0, to: w, by: 4) { sum += Double(p[y * bpr + x]); cnt += 1 }
                }
            }
            frames.append((pts.seconds, w, h, cnt > 0 ? sum / cnt : 0))
        }
        for (i, f) in frames.enumerated() {
            print(String(format: "[legacy]   frame %d: pts=%.5fs %dx%d lumaMean=%.2f", i, f.pts, f.w, f.h, f.lumaMean))
        }
        print("[legacy] HowtoUse1927 decode: codec=\(summary.codec) \(summary.width)x\(summary.height) submitted=\(summary.accessUnitsSubmitted) decoded=\(summary.framesDecoded) emitted=\(summary.framesEmitted) pts90k=\(summary.firstPTS90k.map(String.init) ?? "nil")...\(summary.lastPTS90k.map(String.init) ?? "nil") pixfmt=\(summary.pixelFormat)")
        XCTAssertGreaterThanOrEqual(frames.count, 5)
        XCTAssertEqual(summary.framesEmitted, frames.count)
        XCTAssertEqual(summary.codec, seq.isMPEG2 ? "MPEG-2" : "MPEG-1")
        XCTAssertEqual(summary.width, seq.width)
        XCTAssertEqual(summary.height, seq.height)
        for (i, f) in frames.enumerated() {
            XCTAssertEqual(f.w, seq.width, "frame \(i) width")
            XCTAssertEqual(f.h, seq.height, "frame \(i) height")
            if i > 0 { XCTAssertGreaterThan(f.pts, frames[i - 1].pts, "frame \(i) PTS must increase") }
        }
    }

    private static func mpeg2PackHeader() -> [UInt8] {
        [0x00, 0x00, 0x01, 0xBA, 0x44, 0x00, 0x04, 0x00, 0x04, 0x01, 0x01, 0x89, 0xC3, 0xF8]
    }

    func testCorruptAndTruncatedProgramStreamIsRejected() throws {
        // A minimal valid pack + PES inspects fine (proves the corrupt variants fail for the injected reason).
        let pesPayload = [UInt8](repeating: 0x55, count: 97)
        let validPES: [UInt8] = [0x00, 0x00, 0x01, 0xE0, 0x00, UInt8(3 + pesPayload.count), 0x80, 0x00, 0x00] + pesPayload
        let valid = Self.mpeg2PackHeader() + validPES + [0x00, 0x00, 0x01, 0xB9]
        let ok = try MPEG2ProgramStream.inspect(data: Data(valid))
        XCTAssertEqual(ok.packCount, 1)
        XCTAssertEqual(ok.systemLayer, "MPEG-2 Program Stream")
        XCTAssertEqual(ok.streams.first?.streamID, 0xE0)
        XCTAssertEqual(ok.streams.first?.payloadBytes, Int64(pesPayload.count))

        assertSafariumError(try MPEG2ProgramStream.inspect(data: Data("definitely not an mpeg program stream".utf8)), "no start code")
        assertSafariumError(try MPEG2ProgramStream.inspect(data: Data()), "empty input")
        assertSafariumError(try MPEG2ProgramStream.inspect(data: Data(Self.mpeg2PackHeader() + Array(validPES.prefix(20)))), "truncated PES")
        assertSafariumError(try MPEG2ProgramStream.inspect(data: Data(Array(Self.mpeg2PackHeader().prefix(9)))), "truncated pack header")
        var badMarker = valid; badMarker[4] = 0x40
        assertSafariumError(try MPEG2ProgramStream.inspect(data: Data(badMarker)), "corrupt pack marker bits")
        var zeroLen = valid; zeroLen[18] = 0; zeroLen[19] = 0
        assertSafariumError(try MPEG2ProgramStream.inspect(data: Data(zeroLen)), "zero PES length")
        assertSafariumError(try MPEG2ProgramStream.inspect(data: Data([0x00, 0x00, 0x01, 0xE0, 0x00, 0x03, 0x80, 0x00, 0x00])), "PES before pack header")

        let dir = try makeTempDir("ps")
        defer { try? FileManager.default.removeItem(at: dir) }
        let synthetic = dir.appendingPathComponent("truncated-synthetic.mpg")
        try Data(Self.mpeg2PackHeader() + Array(validPES.prefix(20))).write(to: synthetic)
        assertSafariumError(try MPEG2ProgramStream.decodeVideoFrames(url: synthetic, maxFrames: 5) { _, _, _ in }, "decode truncated synthetic PS")

        // Real file cut in the middle of a PES packet.
        guard let url = realAsset(Self.howtoMPEG) else { return }
        let fh = try FileHandle(forReadingFrom: url)
        let prefix = try fh.read(upToCount: 1 << 20) ?? Data()
        try fh.close()
        XCTAssertEqual(prefix.count, 1 << 20)
        let demux = MPEG2ProgramStreamDemuxer(data: prefix)
        var cut: Int?
        var seen = 0
        while cut == nil, let pes = try? demux.nextPES() {
            seen += 1
            if seen > 3 && pes.payload.count > 64 { cut = Int(pes.fileOffset) + 24 }
        }
        let cutAt = try XCTUnwrap(cut, "no PES found in first MiB")
        let truncated = Data(prefix.prefix(cutAt))
        print("[legacy] truncated HowtoUse1927 prefix at byte \(cutAt) (inside PES #\(seen))")
        assertSafariumError(try MPEG2ProgramStream.inspect(data: truncated), "real PS truncated mid-PES (inspect)")
        let file = dir.appendingPathComponent("truncated-real.mpeg")
        try truncated.write(to: file)
        assertSafariumError(try MPEG2ProgramStream.inspect(url: file), "real PS truncated mid-PES (file inspect)")
        assertSafariumError(try MPEG2ProgramStream.decodeVideoFrames(url: file, maxFrames: 100_000) { _, _, _ in }, "real PS truncated mid-PES (decode)")
    }

    func testAuditBinaryParserBoundsAndESDSOverflowDoNotTrap() throws {
        // Huge expandable length in ESDS must throw SafariumError cleanly without signed-addition overflow
        let maliciousESDS = Data([0x03, 0xFF, 0xFF, 0xFF, 0x7F, 0x00, 0x01, 0x00])
        assertSafariumError(try MediaCompatBridge.unwrapWebCodecsESDS(maliciousESDS), "malicious ESDS huge expandable length")
        assertSafariumError(try MediaCompatBridge.unwrapWebCodecsESDS(Data()), "empty ESDS")

        // Valid minimal AudioSpecificConfig wraps cleanly
        let wrapped = try MediaCompatBridge.makeESDescriptorWrappingASC(Data([0x11, 0x90]))
        let unwrapped = try MediaCompatBridge.unwrapWebCodecsESDS(wrapped)
        XCTAssertEqual(unwrapped.audioSpecificConfig, Data([0x11, 0x90]))

        // OggStreamDemuxer must bound concurrent logical streams (>64) cleanly
        var multiBOS = Data()
        for s in UInt32(1)...UInt32(66) {
            var w = OggPageWriter(serialNumber: s, firstSequence: 0)
            try w.append(packet: Data([0x01] + Array("vorbis".utf8)), granulePosition: 0, flush: true, endOfStream: true)
            multiBOS.append(w.serializedStream())
        }
        let demux = OggStreamDemuxer(data: multiBOS)
        assertSafariumError(try { while let _ = try demux.nextPacket() {} }(), "excessive concurrent Ogg streams")
    }
}
