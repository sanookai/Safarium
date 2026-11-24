import AVFoundation
import AudioToolbox
import CoreMedia
import CoreVideo
import Foundation
import SafariumCore
import VideoToolbox

public struct ESDSUnwrapResult: Equatable, Codable, Sendable {
    public let wasWrapped: Bool
    public let wasBug302253: Bool
    public let audioSpecificConfig: Data
    public let layersUnwrapped: Int

    public init(wasWrapped: Bool, wasBug302253: Bool, audioSpecificConfig: Data, layersUnwrapped: Int) {
        self.wasWrapped = wasWrapped
        self.wasBug302253 = wasBug302253
        self.audioSpecificConfig = audioSpecificConfig
        self.layersUnwrapped = layersUnwrapped
    }
}

public struct DecodedAudioInfo: Codable, Sendable {
    public let path: String
    public let sampleRate: Double
    public let channels: Int
    public let frameCount: Int
    public let sourceSampleRate: Double
    public let sourceChannels: Int
    public let peak: Float
    public let rms: Double

    public init(
        path: String,
        sampleRate: Double,
        channels: Int,
        frameCount: Int,
        sourceSampleRate: Double,
        sourceChannels: Int,
        peak: Float,
        rms: Double
    ) {
        self.path = path
        self.sampleRate = sampleRate
        self.channels = channels
        self.frameCount = frameCount
        self.sourceSampleRate = sourceSampleRate
        self.sourceChannels = sourceChannels
        self.peak = peak
        self.rms = rms
    }
}

public struct DecodedAudioPCM: Sendable {
    public let sampleRate: Double
    public let channels: Int
    public let frameCount: Int
    public let interleavedSamples: [Float]
    public let sourceSampleRate: Double
    public let sourceChannels: Int
    public let peak: Float
    public let rms: Double

    public init(
        sampleRate: Double,
        channels: Int,
        frameCount: Int,
        interleavedSamples: [Float],
        sourceSampleRate: Double,
        sourceChannels: Int,
        peak: Float,
        rms: Double
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.frameCount = frameCount
        self.interleavedSamples = interleavedSamples
        self.sourceSampleRate = sourceSampleRate
        self.sourceChannels = sourceChannels
        self.peak = peak
        self.rms = rms
    }
}

public enum MediaCompatBridge {
    private static let supplementalRegistrationOnce: Void = {
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1)
        VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_HEVCWithAlpha)
        AudioMixer.legacyAudioMaterializer = { sourceURL, stagingDir, sampleRate, channels in
            let ext = sourceURL.pathExtension.lowercased()
            guard ["ogg", "oga", "opus", "mpeg", "mpg"].contains(ext) else { return nil }
            let outWAV = stagingDir.appendingPathComponent("compat-\(UUID().uuidString).wav")
            guard let fmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: AVAudioChannelCount(channels),
                interleaved: true
            ) else {
                throw SafariumError.encode("unsupported PCM format for legacy audio materializer")
            }
            let outFile = try AVAudioFile(forWriting: outWAV, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: true)
            let capFrames = 4096
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(capFrames)) else {
                throw SafariumError.encode("failed to allocate buffer for legacy audio materializer")
            }
            _ = try MediaCompatBridge.streamAudioToFloat32PCM(url: sourceURL, sampleRate: sampleRate, channels: channels, chunkFrames: capFrames) { chunk, n in
                guard n > 0, let src = chunk.baseAddress, let dst = buf.audioBufferList.pointee.mBuffers.mData else { return }
                var off = 0
                while off < n {
                    let take = min(capFrames, n - off)
                    buf.frameLength = AVAudioFrameCount(take)
                    _ = memcpy(dst, src + off * channels, take * channels * 4)
                    try outFile.write(from: buf)
                    off += take
                }
            }
            #if compiler(>=6.0)
            if #available(macOS 15.0, *) { outFile.close() }
            #endif
            return outWAV
        }
    }()

    public static let aacSampleRates: [Int] = [
        96_000, 88_200, 64_000, 48_000, 44_100, 32_000,
        24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350,
    ]

    /// Registers Apple supplemental hardware/system decoders (VP9, AV1, HEVC-with-alpha) once per process.
    public static func registerSupplementalDecoders() {
        _ = supplementalRegistrationOnce
    }

    public static func fourCCCode(_ fourCC: String) throws -> FourCharCode {
        let utf8 = Array(fourCC.utf8)
        guard utf8.count == 4 else {
            throw SafariumError.invalidState("FourCC must be exactly 4 ASCII bytes, got '\(fourCC)'")
        }
        return (UInt32(utf8[0]) << 24)
            | (UInt32(utf8[1]) << 16)
            | (UInt32(utf8[2]) << 8)
            | UInt32(utf8[3])
    }

    public static func fourCCString(_ code: FourCharCode) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
    }

    public static func supportsHardwareDecode(fourCC: String) -> Bool {
        guard let code = try? fourCCCode(fourCC) else { return false }
        return VTIsHardwareDecodeSupported(code)
    }

    public static func supportsHardwareDecode(codecType: CMVideoCodecType) -> Bool {
        VTIsHardwareDecodeSupported(codecType)
    }

    public static func supportsHardwareEncode(fourCC: String) -> Bool {
        guard let code = try? fourCCCode(fourCC) else { return false }
        return supportsHardwareEncode(codecType: code)
    }

    public static func supportsHardwareEncode(codecType: CMVideoCodecType) -> Bool {
        var encListCF: CFArray?
        guard VTCopyVideoEncoderList(nil, &encListCF) == noErr,
              let list = encListCF as? [[String: Any]] else {
            return false
        }
        return list.contains { entry in
            let ct = entry[kVTVideoEncoderList_CodecType as String] as? UInt32
            let isHW = (entry[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) ?? false
            return ct == codecType && isHW
        }
    }

    // MARK: - Safari Bug 302253 ESDS / AudioSpecificConfig Helpers

    private static func readExpandableLength(_ bytes: [UInt8], index: inout Int) -> Int? {
        var val = 0
        for _ in 0..<4 {
            guard index < bytes.count else { return nil }
            let b = bytes[index]
            index += 1
            val = (val << 7) | Int(b & 0x7F)
            if (b & 0x80) == 0 {
                return val
            }
        }
        return val
    }

    private static func encodeExpandableLength(_ length: Int) throws -> [UInt8] {
        guard length >= 0 && length < 0x1000_0000 else {
            throw SafariumError.encode("ES_Descriptor length out of range: \(length)")
        }
        return [
            UInt8(0x80 | ((length >> 21) & 0x7F)),
            UInt8(0x80 | ((length >> 14) & 0x7F)),
            UInt8(0x80 | ((length >> 7) & 0x7F)),
            UInt8(length & 0x7F),
        ]
    }

    private static func stripOptionalESDSBoxHeader(_ data: Data) -> Data {
        let b = [UInt8](data)
        // FullBox version(0) + flags(0) before tag 0x03
        if b.count > 5 && b[0] == 0x00 && b[1] == 0x00 && b[2] == 0x00 && b[3] == 0x00 && b[4] == 0x03 {
            return Data(b.dropFirst(4))
        }
        return data
    }

    /// Recursively unwraps ISO 14496-1 `ES_Descriptor` (`0x03 -> 0x04 -> 0x05`) payloads,
    /// cleanly recovering raw `AudioSpecificConfig` even from Safari Bug 302253 39B or 76B double-wrapped `esds`.
    public static func unwrapWebCodecsESDS(_ data: Data) throws -> ESDSUnwrapResult {
        guard !data.isEmpty else {
            throw SafariumError.encode("ESDS / AudioSpecificConfig data is empty")
        }
        var current = stripOptionalESDSBoxHeader(data)
        var layers = 0
        var firstWrappedCount = 0

        while true {
            let b = [UInt8](current)
            guard !b.isEmpty else {
                throw SafariumError.encode("ES_Descriptor payload is unexpectedly empty")
            }
            if b[0] != 0x03 {
                return ESDSUnwrapResult(
                    wasWrapped: layers > 0,
                    wasBug302253: layers >= 2 || (layers == 1 && firstWrappedCount == 39),
                    audioSpecificConfig: current,
                    layersUnwrapped: layers
                )
            }
            if layers == 0 {
                firstWrappedCount = b.count
            }
            guard b.count > 2 else {
                throw SafariumError.encode("truncated ES_Descriptor (length \(b.count))")
            }
            var p = 1
            guard let esLen = readExpandableLength(b, index: &p), p + 3 <= b.count else {
                throw SafariumError.encode("malformed ES_Descriptor 0x03 header")
            }
            let (sumEnd, endOv) = p.addingReportingOverflow(esLen)
            let esEnd = endOv ? b.count : min(b.count, sumEnd)
            let esFlags = b[p + 2]
            p += 3
            if (esFlags & 0x80) != 0 { // streamDependenceFlag
                guard p + 2 <= esEnd else { throw SafariumError.encode("truncated ES_Descriptor dependsOn_ES_ID") }
                p += 2
            }
            if (esFlags & 0x40) != 0 { // URL_Flag
                guard p < esEnd else { throw SafariumError.encode("truncated ES_Descriptor URL length") }
                let urlLen = Int(b[p])
                p += 1 + urlLen
                guard p <= esEnd else { throw SafariumError.encode("truncated ES_Descriptor URL payload") }
            }
            if (esFlags & 0x20) != 0 { // OCRstreamFlag
                guard p + 2 <= esEnd else { throw SafariumError.encode("truncated ES_Descriptor OCR_ES_Id") }
                p += 2
            }

            var extractedASC: Data?
            while p < esEnd {
                let tag = b[p]
                p += 1
                guard let len = readExpandableLength(b, index: &p), len >= 0, p + len <= b.count else {
                    throw SafariumError.encode("malformed descriptor tag 0x\(String(format: "%02x", tag)) in ES_Descriptor")
                }
                if tag == 0x04 {
                    guard len >= 13, p + 13 <= b.count else {
                        throw SafariumError.encode("truncated DecoderConfigDescriptor (0x04)")
                    }
                    p += 13
                } else if tag == 0x05 {
                    extractedASC = Data(b[p..<(p + len)])
                    break
                } else {
                    p += len
                }
            }
            guard let asc = extractedASC, !asc.isEmpty else {
                throw SafariumError.encode("ES_Descriptor lacks DecoderSpecificInfo (0x05)")
            }
            layers += 1
            current = stripOptionalESDSBoxHeader(asc)
        }
    }

    /// Wraps a raw `AudioSpecificConfig` into a standard ISO 14496-1 `ES_Descriptor` for CoreMedia magic cookies.
    /// Automatically unwraps if `asc` is already an `ES_Descriptor` (preventing 76B double-wrapping).
    public static func makeESDescriptorWrappingASC(
        _ asc: Data,
        maxBitrate: UInt32 = 128_000,
        avgBitrate: UInt32 = 128_000
    ) throws -> Data {
        let cleanASC = try unwrapWebCodecsESDS(asc).audioSpecificConfig
        guard cleanASC.count >= 2 else {
            throw SafariumError.encode("AudioSpecificConfig must be at least 2 bytes, got \(cleanASC.count)")
        }
        let ascBytes = [UInt8](cleanASC)
        let decSpecific = try [UInt8]([0x05]) + encodeExpandableLength(ascBytes.count) + ascBytes
        let decConfigPayload: [UInt8] = [
            0x40, // ObjectTypeIndication: MPEG-4 Audio
            0x15, // streamType=5 (Audio) << 2 | upstream=0 | reserved=1
            0x00, 0x18, 0x00, // bufferSizeDB = 6144
            UInt8((maxBitrate >> 24) & 0xFF), UInt8((maxBitrate >> 16) & 0xFF),
            UInt8((maxBitrate >> 8) & 0xFF), UInt8(maxBitrate & 0xFF),
            UInt8((avgBitrate >> 24) & 0xFF), UInt8((avgBitrate >> 16) & 0xFF),
            UInt8((avgBitrate >> 8) & 0xFF), UInt8(avgBitrate & 0xFF),
        ] + decSpecific
        let decConfig = try [UInt8]([0x04]) + encodeExpandableLength(decConfigPayload.count) + decConfigPayload
        let slConfig: [UInt8] = [0x06, 0x80, 0x80, 0x80, 0x01, 0x02]
        let esPayload: [UInt8] = [0x00, 0x01, 0x00] + decConfig + slConfig
        let esDescr = try [UInt8]([0x03]) + encodeExpandableLength(esPayload.count) + esPayload
        return Data(esDescr)
    }

    public static func makeAudioFormatDescriptionFromASC(
        _ asc: Data,
        sampleRate: Double,
        channels: Int
    ) throws -> CMAudioFormatDescription {
        let cleanASC = try unwrapWebCodecsESDS(asc).audioSpecificConfig
        let parsed = try? parseAACAudioSpecificConfig(cleanASC)
        let effectiveSR = parsed.map { Double($0.sampleRate) } ?? sampleRate
        let effectiveCh = UInt32(max(1, parsed?.channels ?? channels))

        var asbd = AudioStreamBasicDescription(
            mSampleRate: effectiveSR,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: effectiveCh,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        let layoutTag: AudioChannelLayoutTag? = switch effectiveCh {
        case 1: kAudioChannelLayoutTag_Mono
        case 2: kAudioChannelLayoutTag_Stereo
        case 3: kAudioChannelLayoutTag_AAC_3_0
        case 4: kAudioChannelLayoutTag_AAC_4_0
        case 5: kAudioChannelLayoutTag_AAC_5_0
        case 6: kAudioChannelLayoutTag_AAC_5_1
        case 7: kAudioChannelLayoutTag_AAC_6_1
        case 8: kAudioChannelLayoutTag_AAC_7_1
        default: nil
        }
        let cookie = try makeESDescriptorWrappingASC(cleanASC)
        var desc: CMAudioFormatDescription?
        let st: OSStatus
        if let layoutTag {
            let layout = AudioChannelLayout(
                mChannelLayoutTag: layoutTag,
                mChannelBitmap: [],
                mNumberChannelDescriptions: 0,
                mChannelDescriptions: AudioChannelDescription()
            )
            st = withUnsafePointer(to: layout) { layoutPtr in
                cookie.withUnsafeBytes { raw in
                    CMAudioFormatDescriptionCreate(
                        allocator: kCFAllocatorDefault,
                        asbd: &asbd,
                        layoutSize: MemoryLayout<AudioChannelLayout>.size,
                        layout: layoutPtr,
                        magicCookieSize: cookie.count,
                        magicCookie: raw.baseAddress,
                        extensions: nil,
                        formatDescriptionOut: &desc
                    )
                }
            }
        } else {
            st = cookie.withUnsafeBytes { raw in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: 0,
                    layout: nil,
                    magicCookieSize: cookie.count,
                    magicCookie: raw.baseAddress,
                    extensions: nil,
                    formatDescriptionOut: &desc
                )
            }
        }
        guard st == noErr, let desc else {
            throw SafariumError.encode("CMAudioFormatDescriptionCreate failed (\(st))")
        }
        return desc
    }

    public static func parseAACAudioSpecificConfig(
        _ asc: Data
    ) throws -> (objectType: Int, sampleRateIndex: Int, sampleRate: Int, channels: Int) {
        guard asc.count >= 2 else {
            throw SafariumError.encode("AAC AudioSpecificConfig requires >= 2 bytes")
        }
        let b0 = Int(asc[0])
        let b1 = Int(asc[1])
        let objType = (b0 >> 3) & 0x1F
        let srIdx = ((b0 & 0x07) << 1) | ((b1 >> 7) & 0x01)
        let ch = (b1 >> 3) & 0x0F
        guard srIdx >= 0, srIdx < aacSampleRates.count else {
            throw SafariumError.encode("unsupported AAC sampleRateIndex \(srIdx)")
        }
        return (objType, srIdx, aacSampleRates[srIdx], max(1, ch))
    }

    public static func makeAACAudioSpecificConfig(objectType: Int, sampleRateIndex: Int, channels: Int) -> Data {
        let b0 = UInt8(((objectType & 0x1F) << 3) | ((sampleRateIndex >> 1) & 0x07))
        let b1 = UInt8(((sampleRateIndex & 0x01) << 7) | ((channels & 0x0F) << 3))
        return Data([b0, b1])
    }

    // MARK: - ISO BMFF VP9 `vpcC` FullBox

    /// Builds a 12-byte (or longer if initialization data is supplied) ISO BMFF `'vpcC'` FullBox v1.0
    /// required by `CMVideoFormatDescription` / `VTDecompressionSessionCreate` for VP9 hardware decoding.
    public static func makeVPCCFullBox(
        profile: UInt8 = 0,
        level: UInt8 = 10,
        bitDepth: UInt8 = 8,
        chromaSubsampling: UInt8 = 1,
        fullRange: Bool = false,
        colorPrimaries: UInt8 = 1,
        transferCharacteristics: UInt8 = 1,
        matrixCoefficients: UInt8 = 1,
        codecInitializationData: Data = Data()
    ) -> Data {
        var out = Data([
            0x01, 0x00, 0x00, 0x00, // FullBox version=1, flags=0
            profile,
            level,
            UInt8(((bitDepth & 0x0F) << 4) | ((chromaSubsampling & 0x07) << 1) | (fullRange ? 0x01 : 0x00)),
            colorPrimaries,
            transferCharacteristics,
            matrixCoefficients,
            UInt8((codecInitializationData.count >> 8) & 0xFF),
            UInt8(codecInitializationData.count & 0xFF),
        ])
        out.append(codecInitializationData)
        return out
    }

    /// Converts WebM's optional `V_VP9` feature TLV `CodecPrivate` into an ISO BMFF `vpcC` FullBox.
    public static func makeVPCCFullBox(fromWebMCodecPrivate codecPrivate: Data) -> Data {
        var profile: UInt8 = 0
        var level: UInt8 = 10
        var bitDepth: UInt8 = 8
        var chroma: UInt8 = 1
        let b = [UInt8](codecPrivate)
        var i = 0
        while i + 2 <= b.count {
            let fid = b[i]
            let flen = Int(b[i + 1])
            i += 2
            guard flen >= 0, i + flen <= b.count else { break }
            if flen == 1 {
                switch fid {
                case 1: profile = b[i]
                case 2: level = b[i]
                case 3: bitDepth = b[i]
                case 4: chroma = b[i]
                default: break
                }
            }
            i += flen
        }
        return makeVPCCFullBox(
            profile: profile,
            level: level,
            bitDepth: bitDepth,
            chromaSubsampling: chroma
        )
    }

    // MARK: - Universal AudioToolbox Decode -> Streaming Float32 PCM

    /// Streams audio from `.wav`, `.mp3`, `.flac`, `.m4a`, `.caf`, `.mp4`, or `.aiff`
    /// in bounded `O(chunkFrames)` Float32 interleaved chunks.
    @discardableResult
    public static func streamAudioToFloat32PCM(
        url: URL,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        chunkFrames: Int = 4096,
        onChunk: (_ interleavedSamples: UnsafeBufferPointer<Float>, _ frameCount: Int) throws -> Void
    ) throws -> DecodedAudioInfo {
        try SafeFilePublisher.assertRegularReadableFile(url)
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw SafariumError.invalidState("invalid target sampleRate: \(sampleRate)")
        }
        guard (1...8).contains(channels) else {
            throw SafariumError.invalidState("target channels must be 1...8, got \(channels)")
        }
        guard chunkFrames > 0 else {
            throw SafariumError.invalidState("chunkFrames must be positive")
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard fileSize > 0 else {
            throw SafariumError.encode("audio file is empty: \(url.lastPathComponent)")
        }

        if let handled = try streamViaLegacyContainerIfNeeded(
            url: url,
            sampleRate: sampleRate,
            channels: channels,
            chunkFrames: chunkFrames,
            onChunk: onChunk
        ) {
            return handled
        }

        if let (af, conv, targetFmt) = openAVAudioFileAndConverter(url: url, sampleRate: sampleRate, channels: channels) {
            return try streamViaAVAudioFile(
                url: url,
                af: af,
                conv: conv,
                targetFmt: targetFmt,
                sampleRate: sampleRate,
                channels: channels,
                chunkFrames: chunkFrames,
                onChunk: onChunk
            )
        }
        return try streamViaExtAudioFile(
            url: url,
            sampleRate: sampleRate,
            channels: channels,
            chunkFrames: chunkFrames,
            onChunk: onChunk
        )
    }

    private static func magicPrefix(_ url: URL, count: Int = 4) -> Data {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? fh.close() }
        return (try? fh.read(upToCount: count)) ?? Data()
    }

    private static func streamViaLegacyContainerIfNeeded(
        url: URL,
        sampleRate: Double,
        channels: Int,
        chunkFrames: Int,
        onChunk: (_ interleavedSamples: UnsafeBufferPointer<Float>, _ frameCount: Int) throws -> Void
    ) throws -> DecodedAudioInfo? {
        let ext = url.pathExtension.lowercased()
        let magic = magicPrefix(url, count: 4)
        let isOggMagic = magic == Data([0x4F, 0x67, 0x67, 0x53]) // "OggS"
        let isPSMagic = magic == Data([0x00, 0x00, 0x01, 0xBA])

        if isOggMagic || ext == "ogg" || ext == "oga" {
            let report = try OggContainer.inspect(url: url)
            guard let firstCodec = report.streams.first?.codec else {
                throw SafariumError.encode("Ogg container has no streams: \(url.lastPathComponent)")
            }
            switch firstCodec {
            case .vorbis:
                return try streamViaOggVorbis(
                    url: url,
                    sampleRate: sampleRate,
                    channels: channels,
                    chunkFrames: chunkFrames,
                    onChunk: onChunk
                )
            case .flac:
                let tmpURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("safarium-oggflac-\(UUID().uuidString).flac")
                defer { try? FileManager.default.removeItem(at: tmpURL) }
                _ = try OggContainer.extractRawFLAC(from: url, to: tmpURL, overwrite: true)
                if let (af, conv, targetFmt) = openAVAudioFileAndConverter(url: tmpURL, sampleRate: sampleRate, channels: channels) {
                    return try streamViaAVAudioFile(
                        url: url, af: af, conv: conv, targetFmt: targetFmt,
                        sampleRate: sampleRate, channels: channels, chunkFrames: chunkFrames, onChunk: onChunk
                    )
                }
                return try streamViaExtAudioFile(
                    url: tmpURL, sampleRate: sampleRate, channels: channels, chunkFrames: chunkFrames, onChunk: onChunk
                )
            case .opus:
                throw SafariumError.invalidState("Ogg Opus container requires WebM/CAF container remux; pure-Swift Opus decoder is not bundled: \(url.lastPathComponent)")
            default:
                throw SafariumError.invalidState("unsupported Ogg audio codec '\(firstCodec.rawValue)' in \(url.lastPathComponent)")
            }
        }

        if isPSMagic || ext == "mpeg" || ext == "mpg" {
            let demux = try MPEG2ProgramStreamDemuxer(url: url)
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("safarium-psaudio-\(UUID().uuidString).mp2")
            defer { try? FileManager.default.removeItem(at: tmpURL) }
            FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
            let fh = try FileHandle(forWritingTo: tmpURL)
            var audioBytes: Int64 = 0
            var audioStreamID: UInt8?
            do {
                while let pes = try demux.nextPES() {
                    guard (0xC0...0xDF).contains(pes.streamID) else { continue }
                    if audioStreamID == nil { audioStreamID = pes.streamID }
                    guard pes.streamID == audioStreamID, !pes.payload.isEmpty else { continue }
                    try fh.write(contentsOf: pes.payload)
                    audioBytes += Int64(pes.payload.count)
                }
                try fh.close()
            } catch {
                try? fh.close()
                throw error
            }
            guard audioBytes > 0 else {
                throw SafariumError.encode("MPEG Program Stream contains no decodable audio elementary stream: \(url.lastPathComponent)")
            }
            if let (af, conv, targetFmt) = openAVAudioFileAndConverter(url: tmpURL, sampleRate: sampleRate, channels: channels) {
                return try streamViaAVAudioFile(
                    url: url, af: af, conv: conv, targetFmt: targetFmt,
                    sampleRate: sampleRate, channels: channels, chunkFrames: chunkFrames, onChunk: onChunk
                )
            }
            return try streamViaExtAudioFile(
                url: tmpURL, sampleRate: sampleRate, channels: channels, chunkFrames: chunkFrames, onChunk: onChunk
            )
        }
        return nil
    }

    private static func streamViaOggVorbis(
        url: URL,
        sampleRate: Double,
        channels: Int,
        chunkFrames: Int,
        onChunk: (_ interleavedSamples: UnsafeBufferPointer<Float>, _ frameCount: Int) throws -> Void
    ) throws -> DecodedAudioInfo {
        var totalOutFrames = 0
        var sumSq: Double = 0
        var peak: Float = 0
        var srcRate = sampleRate
        var srcCh = channels
        var convState: (conv: AVAudioConverter, srcFmt: AVAudioFormat, dstFmt: AVAudioFormat, outCap: AVAudioFrameCount)?

        func recordAndEmit(_ ptr: UnsafeBufferPointer<Float>, frames: Int) throws {
            let sampleCount = frames * channels
            for i in 0..<sampleCount {
                let v = ptr[i]
                let av = abs(v)
                if av > peak { peak = av }
                sumSq += Double(v) * Double(v)
            }
            var offset = 0
            while offset < frames {
                let sliceFrames = min(chunkFrames, frames - offset)
                if let base = ptr.baseAddress {
                    let sub = UnsafeBufferPointer(start: base + offset * channels, count: sliceFrames * channels)
                    try onChunk(sub, sliceFrames)
                }
                offset += sliceFrames
            }
            totalOutFrames += frames
        }

        _ = try OggVorbisDecoder.streamToFloat32PCM(url: url, chunkFrames: chunkFrames) { buf, n, r, ch in
            srcRate = Double(r)
            srcCh = ch
            if r == Int(sampleRate) && ch == channels {
                try recordAndEmit(buf, frames: n)
                return
            }
            if convState == nil {
                guard let sf = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Double(r),
                    channels: AVAudioChannelCount(ch),
                    interleaved: true
                ), let df = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: AVAudioChannelCount(channels),
                    interleaved: true
                ), let c = AVAudioConverter(from: sf, to: df) else {
                    throw SafariumError.encode("failed to create AVAudioConverter for Ogg Vorbis \(r)Hz \(ch)ch -> \(sampleRate)Hz \(channels)ch")
                }
                c.sampleRateConverterQuality = AVAudioQuality.max.rawValue
                let est = AVAudioFrameCount(max(1, chunkFrames))
                convState = (c, sf, df, est)
            }
            guard let state = convState,
                  let inBuf = AVAudioPCMBuffer(pcmFormat: state.srcFmt, frameCapacity: AVAudioFrameCount(max(1, n))),
                  let outBuf = AVAudioPCMBuffer(pcmFormat: state.dstFmt, frameCapacity: state.outCap) else {
                throw SafariumError.encode("failed to allocate Ogg conversion buffer")
            }
            inBuf.frameLength = AVAudioFrameCount(n)
            if let dstRaw = inBuf.audioBufferList.pointee.mBuffers.mData, n > 0, let srcRaw = buf.baseAddress {
                dstRaw.assumingMemoryBound(to: Float.self).update(from: srcRaw, count: n * ch)
            }
            var fed = false
            while true {
                outBuf.frameLength = 0
                var err: NSError?
                let st = state.conv.convert(to: outBuf, error: &err) { _, outStatus in
                    if fed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    fed = true
                    outStatus.pointee = .haveData
                    return inBuf
                }
                if let err { throw SafariumError.encode("Ogg Vorbis conversion error: \(err.localizedDescription)") }
                let got = Int(outBuf.frameLength)
                if got > 0, let mData = outBuf.audioBufferList.pointee.mBuffers.mData {
                    let p = UnsafeBufferPointer(start: mData.assumingMemoryBound(to: Float.self), count: got * channels)
                    try recordAndEmit(p, frames: got)
                }
                if st == .inputRanDry || st == .endOfStream || st == .error || got == 0 {
                    if st == .error { throw SafariumError.encode("Ogg Vorbis conversion failed") }
                    break
                }
            }
        }

        if let state = convState, let outBuf = AVAudioPCMBuffer(pcmFormat: state.dstFmt, frameCapacity: state.outCap) {
            while true {
                outBuf.frameLength = 0
                var err: NSError?
                let st = state.conv.convert(to: outBuf, error: &err) { _, outStatus in
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if let err { throw SafariumError.encode("Ogg Vorbis flush error: \(err.localizedDescription)") }
                let got = Int(outBuf.frameLength)
                if got > 0, let mData = outBuf.audioBufferList.pointee.mBuffers.mData {
                    let p = UnsafeBufferPointer(start: mData.assumingMemoryBound(to: Float.self), count: got * channels)
                    try recordAndEmit(p, frames: got)
                }
                if st == .endOfStream || got == 0 { break }
            }
        }

        guard totalOutFrames > 0 else {
            throw SafariumError.encode("decoded zero audio frames from Ogg Vorbis: \(url.lastPathComponent)")
        }
        let rms = sqrt(sumSq / Double(totalOutFrames * channels))
        return DecodedAudioInfo(
            path: url.path,
            sampleRate: sampleRate,
            channels: channels,
            frameCount: totalOutFrames,
            sourceSampleRate: srcRate,
            sourceChannels: srcCh,
            peak: peak,
            rms: rms
        )
    }

    private static func openAVAudioFileAndConverter(
        url: URL,
        sampleRate: Double,
        channels: Int
    ) -> (AVAudioFile, AVAudioConverter, AVAudioFormat)? {
        guard let af = try? AVAudioFile(forReading: url),
              let targetFmt = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sampleRate,
                  channels: AVAudioChannelCount(channels),
                  interleaved: true
              ),
              let conv = AVAudioConverter(from: af.processingFormat, to: targetFmt) else {
            return nil
        }
        return (af, conv, targetFmt)
    }

    private static func streamViaAVAudioFile(
        url: URL,
        af: AVAudioFile,
        conv: AVAudioConverter,
        targetFmt: AVAudioFormat,
        sampleRate: Double,
        channels: Int,
        chunkFrames: Int,
        onChunk: (_ interleavedSamples: UnsafeBufferPointer<Float>, _ frameCount: Int) throws -> Void
    ) throws -> DecodedAudioInfo {
        let inFmt = af.processingFormat
        let inCap = AVAudioFrameCount(max(512, min(chunkFrames, 4096)))
        let outCap = AVAudioFrameCount(chunkFrames)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: inCap),
              let outBuf = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: outCap) else {
            throw SafariumError.encode("failed to allocate AVAudioPCMBuffer")
        }

        var totalOutFrames = 0
        var sumSq: Double = 0
        var peak: Float = 0
        var eof = false
        var readError: Error?
        var callbackError: Error?

        while true {
            outBuf.frameLength = 0
            var convErr: NSError?
            let status = conv.convert(to: outBuf, error: &convErr) { _, outStatus in
                if eof {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                if af.framePosition >= af.length {
                    eof = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    inBuf.frameLength = 0
                    try af.read(into: inBuf, frameCount: inCap)
                    if inBuf.frameLength == 0 {
                        eof = true
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    outStatus.pointee = .haveData
                    return inBuf
                } catch {
                    let nsErr = error as NSError
                    if nsErr.domain == NSOSStatusErrorDomain && nsErr.code == Int(eofErr) {
                        eof = true
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    readError = error
                    eof = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }

            if let readError {
                throw SafariumError.encode("audio read failed for \(url.lastPathComponent): \(readError.localizedDescription)")
            }

            let n = Int(outBuf.frameLength)
            if n > 0, let mData = outBuf.audioBufferList.pointee.mBuffers.mData {
                let sampleCount = n * channels
                let ptr = mData.assumingMemoryBound(to: Float.self)
                let bufPtr = UnsafeBufferPointer(start: ptr, count: sampleCount)
                for i in 0..<sampleCount {
                    let v = bufPtr[i]
                    let av = abs(v)
                    if av > peak { peak = av }
                    sumSq += Double(v) * Double(v)
                }
                do {
                    try onChunk(bufPtr, n)
                } catch {
                    callbackError = error
                    break
                }
                totalOutFrames += n
            }

            if status == .endOfStream || status == .error {
                if status == .error {
                    throw SafariumError.encode("AVAudioConverter error on \(url.lastPathComponent): \(convErr?.localizedDescription ?? "unknown")")
                }
                break
            }
        }

        if let callbackError { throw callbackError }
        guard totalOutFrames > 0 else {
            throw SafariumError.encode("decoded zero audio frames from \(url.lastPathComponent)")
        }
        let rms = sqrt(sumSq / Double(totalOutFrames * channels))
        return DecodedAudioInfo(
            path: url.path,
            sampleRate: sampleRate,
            channels: channels,
            frameCount: totalOutFrames,
            sourceSampleRate: inFmt.sampleRate,
            sourceChannels: Int(inFmt.channelCount),
            peak: peak,
            rms: rms
        )
    }

    private static func streamViaExtAudioFile(
        url: URL,
        sampleRate: Double,
        channels: Int,
        chunkFrames: Int,
        onChunk: (_ interleavedSamples: UnsafeBufferPointer<Float>, _ frameCount: Int) throws -> Void
    ) throws -> DecodedAudioInfo {
        var extRef: ExtAudioFileRef?
        let st1 = ExtAudioFileOpenURL(url as CFURL, &extRef)
        guard st1 == noErr, let ext = extRef else {
            throw SafariumError.encode("ExtAudioFileOpenURL failed for \(url.lastPathComponent) (OSStatus \(st1))")
        }
        defer { ExtAudioFileDispose(ext) }

        var srcASBD = AudioStreamBasicDescription()
        var srcSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        _ = ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileDataFormat, &srcSize, &srcASBD)

        let bytesPerFrame = UInt32(channels * MemoryLayout<Float>.size)
        var clientASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let st2 = ExtAudioFileSetProperty(
            ext,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientASBD
        )
        guard st2 == noErr else {
            throw SafariumError.encode("ExtAudioFileSetProperty(ClientDataFormat) failed for \(url.lastPathComponent) (OSStatus \(st2))")
        }

        var pcm = [Float](repeating: 0, count: chunkFrames * channels)
        var totalFrames = 0
        var sumSq: Double = 0
        var peak: Float = 0

        while true {
            var ioFrames = UInt32(chunkFrames)
            let stRead: OSStatus = pcm.withUnsafeMutableBytes { raw in
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
                )
                return ExtAudioFileRead(ext, &ioFrames, &abl)
            }
            guard stRead == noErr else {
                throw SafariumError.encode("ExtAudioFileRead failed for \(url.lastPathComponent) (OSStatus \(stRead))")
            }
            if ioFrames == 0 { break }
            let n = Int(ioFrames)
            let sampleCount = n * channels
            for i in 0..<sampleCount {
                let v = pcm[i]
                let av = abs(v)
                if av > peak { peak = av }
                sumSq += Double(v) * Double(v)
            }
            try pcm.withUnsafeBufferPointer { buf in
                let slice = UnsafeBufferPointer(rebasing: buf.prefix(sampleCount))
                try onChunk(slice, n)
            }
            totalFrames += n
        }

        guard totalFrames > 0 else {
            throw SafariumError.encode("decoded zero audio frames from \(url.lastPathComponent)")
        }
        let rms = sqrt(sumSq / Double(totalFrames * channels))
        return DecodedAudioInfo(
            path: url.path,
            sampleRate: sampleRate,
            channels: channels,
            frameCount: totalFrames,
            sourceSampleRate: srcASBD.mSampleRate,
            sourceChannels: Int(srcASBD.mChannelsPerFrame),
            peak: peak,
            rms: rms
        )
    }

    public static func decodeAudioToFloat32PCM(
        url: URL,
        sampleRate: Double = 48_000,
        channels: Int = 2
    ) throws -> DecodedAudioPCM {
        var samples: [Float] = []
        let info = try streamAudioToFloat32PCM(url: url, sampleRate: sampleRate, channels: channels) { buf, _ in
            samples.append(contentsOf: buf)
        }
        return DecodedAudioPCM(
            sampleRate: info.sampleRate,
            channels: info.channels,
            frameCount: info.frameCount,
            interleavedSamples: samples,
            sourceSampleRate: info.sourceSampleRate,
            sourceChannels: info.sourceChannels,
            peak: info.peak,
            rms: info.rms
        )
    }

    // MARK: - Lossless MP3 Packet Splitting

    /// Splits an MP3 file into standalone `chunkSeconds` MP3 chunks at exact MPEG frame boundaries
    /// using `AudioFileOpenURL` + `AudioFileReadPacketData` with zero re-encoding.
    public static func splitMP3PacketsLosslessly(
        inputURL: URL,
        outputDir: URL,
        chunkSeconds: Double,
        prefix: String = "chunk",
        overwrite: Bool = false
    ) throws -> SplitAudioReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(inputURL)
        guard chunkSeconds.isFinite, chunkSeconds > 0 else {
            throw SafariumError.invalidState("chunkSeconds must be finite and > 0, got \(chunkSeconds)")
        }
        guard !prefix.isEmpty, !prefix.contains("/"), !prefix.contains("..") else {
            throw SafariumError.invalidState("invalid MP3 chunk filename prefix: '\(prefix)'")
        }

        var inAFOpt: AudioFileID?
        var stOpen = AudioFileOpenURL(inputURL as CFURL, .readPermission, kAudioFileMP3Type, &inAFOpt)
        if stOpen != noErr || inAFOpt == nil {
            stOpen = AudioFileOpenURL(inputURL as CFURL, .readPermission, 0, &inAFOpt)
        }
        guard stOpen == noErr, let inAF = inAFOpt else {
            throw SafariumError.encode("AudioFileOpenURL failed for MP3 \(inputURL.lastPathComponent) (OSStatus \(stOpen))")
        }
        defer { AudioFileClose(inAF) }

        var asbd = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let stFmt = AudioFileGetProperty(inAF, kAudioFilePropertyDataFormat, &asbdSize, &asbd)
        guard stFmt == noErr, asbd.mFormatID == kAudioFormatMPEGLayer3, asbd.mSampleRate > 0 else {
            throw SafariumError.encode("input is not a valid MP3 stream: \(inputURL.lastPathComponent)")
        }

        var totalPackets: UInt64 = 0
        var totalSize: UInt32 = UInt32(MemoryLayout<UInt64>.size)
        let stCount = AudioFileGetProperty(inAF, kAudioFilePropertyAudioDataPacketCount, &totalSize, &totalPackets)
        guard stCount == noErr, totalPackets > 0 else {
            throw SafariumError.encode("MP3 file contains zero audio packets: \(inputURL.lastPathComponent)")
        }

        var maxPacketSize: UInt32 = 0
        var maxPktPropSize: UInt32 = UInt32(MemoryLayout<UInt32>.size)
        let stMax = AudioFileGetProperty(inAF, kAudioFilePropertyMaximumPacketSize, &maxPktPropSize, &maxPacketSize)
        guard stMax == noErr, maxPacketSize > 0, maxPacketSize <= 1_048_576 else {
            throw SafariumError.encode("invalid or out-of-range MP3 maximum packet size (\(maxPacketSize))")
        }

        let framesPerPacket = max(1, Int(asbd.mFramesPerPacket))
        let rawPacketsPerChunk = chunkSeconds * asbd.mSampleRate / Double(framesPerPacket)
        guard rawPacketsPerChunk.isFinite, rawPacketsPerChunk > 0, rawPacketsPerChunk < Double(Int.max / 2) else {
            throw SafariumError.encode("invalid chunkSeconds for splitMP3")
        }
        let packetsPerChunk = max(1, Int(rawPacketsPerChunk.rounded(.down)))
        let (estNum, estOv) = totalPackets.addingReportingOverflow(UInt64(packetsPerChunk - 1))
        let estDiv = estOv ? UInt64.max : (estNum / UInt64(packetsPerChunk))
        guard estDiv <= 100_000 else {
            throw SafariumError.encode("MP3 split would produce too many chunks (\(estDiv))")
        }
        let estimatedChunks = Int(estDiv)

        // Preflight every chunk URL up front so !overwrite never leaves partial outputs.
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        for idx in 0..<estimatedChunks {
            let chunkURL = outputDir.appendingPathComponent(String(format: "%@_%03d.mp3", prefix, idx))
            try SafeFilePublisher.preflight(outputURL: chunkURL, overwrite: overwrite)
        }

        let staging = try SafeFilePublisher.Staging(beside: outputDir.appendingPathComponent(".\(prefix)-mp3-stage"))
        defer { staging.cleanup() }

        var packetIndex: Int64 = 0
        var chunkIndex = 0
        var chunkPaths: [String] = []
        let batchSize = min(packetsPerChunk, 256)
        let (readBufLen, bufOv) = Int(maxPacketSize).multipliedReportingOverflow(by: batchSize)
        guard !bufOv, readBufLen > 0 else {
            throw SafariumError.encode("MP3 read buffer size overflow")
        }
        var readBuf = [UInt8](repeating: 0, count: readBufLen)
        var descs = [AudioStreamPacketDescription](repeating: AudioStreamPacketDescription(), count: batchSize)

        while UInt64(packetIndex) < totalPackets {
            let chunkURL = outputDir.appendingPathComponent(String(format: "%@_%03d.mp3", prefix, chunkIndex))
            try SafeFilePublisher.preflight(outputURL: chunkURL, overwrite: overwrite)
            let tempURL = staging.fileURL(String(format: "chunk_%03d.mp3", chunkIndex))

            var outAFOpt: AudioFileID?
            let stCreate = AudioFileCreateWithURL(tempURL as CFURL, kAudioFileMP3Type, &asbd, .eraseFile, &outAFOpt)
            guard stCreate == noErr, let outAF = outAFOpt else {
                throw SafariumError.encode("AudioFileCreateWithURL(MP3) failed (OSStatus \(stCreate))")
            }

            var outPacketOffset: Int64 = 0
            var packetsRemainingInChunk = packetsPerChunk
            do {
                while packetsRemainingInChunk > 0 && UInt64(packetIndex) < totalPackets {
                    let want = min(batchSize, packetsRemainingInChunk)
                    var ioNumPackets = UInt32(want)
                    var ioNumBytes = UInt32(Int(maxPacketSize) * want)
                    let stRead = readBuf.withUnsafeMutableBytes { raw in
                        AudioFileReadPacketData(inAF, false, &ioNumBytes, &descs, packetIndex, &ioNumPackets, raw.baseAddress!)
                    }
                    guard stRead == noErr || stRead == kAudioFileEndOfFileError else {
                        throw SafariumError.encode("AudioFileReadPacketData failed at packet \(packetIndex) (OSStatus \(stRead))")
                    }
                    if ioNumPackets == 0 {
                        packetIndex = Int64(totalPackets)
                        break
                    }
                    var writePackets = ioNumPackets
                    let stWrite = readBuf.withUnsafeBytes { raw in
                        AudioFileWritePackets(outAF, false, ioNumBytes, &descs, outPacketOffset, &writePackets, raw.baseAddress!)
                    }
                    guard stWrite == noErr else {
                        throw SafariumError.encode("AudioFileWritePackets failed (OSStatus \(stWrite))")
                    }
                    packetIndex += Int64(ioNumPackets)
                    outPacketOffset += Int64(writePackets)
                    packetsRemainingInChunk -= Int(ioNumPackets)
                }
            } catch {
                AudioFileClose(outAF)
                throw error
            }
            AudioFileClose(outAF)

            if outPacketOffset > 0 {
                try SafeFilePublisher.publish(tempURL: tempURL, to: chunkURL, overwrite: overwrite)
                chunkPaths.append(chunkURL.path)
                chunkIndex += 1
            }
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return SplitAudioReport(
            inputPath: inputURL.path,
            outputDir: outputDir.path,
            chunkSeconds: chunkSeconds,
            chunks: chunkPaths,
            wallMs: elapsedMs
        )
    }

    // MARK: - Shared Internal CoreMedia Packet Helpers

    static func makeReadySampleBuffer(
        data: Data,
        formatDescription: CMFormatDescription,
        pts: CMTime,
        dts: CMTime,
        duration: CMTime,
        isSync: Bool
    ) throws -> CMSampleBuffer {
        var bb: CMBlockBuffer?
        let st1 = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &bb
        )
        guard st1 == noErr, let bb else {
            throw SafariumError.encode("CMBlockBuffer creation failed (\(st1))")
        }
        if !data.isEmpty {
            let st2 = data.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: data.count)
            }
            guard st2 == noErr else {
                throw SafariumError.encode("CMBlockBuffer copy failed (\(st2))")
            }
        }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: dts)
        var sz = data.count
        var sb: CMSampleBuffer?
        let st3 = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sz,
            sampleBufferOut: &sb
        )
        guard st3 == noErr, let sb else {
            throw SafariumError.encode("CMSampleBuffer creation failed (\(st3))")
        }
        if !isSync, let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sb
    }

    static func splitCompressedAudioPackets(from sampleBuffer: CMSampleBuffer) -> [(pts90k: Int64, duration90k: Int64, data: Data)] {
        let count = sampleBuffer.numSamples
        guard count > 0, let db = sampleBuffer.dataBuffer else { return [] }
        let totalLen = CMBlockBufferGetDataLength(db)
        var allBytes = Data(count: totalLen)
        if totalLen > 0 {
            allBytes.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(db, atOffset: 0, dataLength: totalLen, destination: $0.baseAddress!) }
        }
        func safeTicks90k(_ t: CMTime) -> Int64 {
            guard t.isValid, t.isNumeric else { return 0 }
            let sec = t.seconds
            guard sec.isFinite else { return 0 }
            let scaled = (sec * 90_000.0).rounded()
            guard scaled >= Double(Int64.min / 2), scaled <= Double(Int64.max / 2) else { return 0 }
            return Int64(scaled)
        }
        if count == 1 {
            let pts90k = safeTicks90k(sampleBuffer.presentationTimeStamp)
            let dur90k = safeTicks90k(sampleBuffer.duration)
            return [(pts90k, dur90k, allBytes)]
        }
        var sizes = [Int](repeating: 0, count: count)
        var sizeNeeded: CMItemCount = 0
        CMSampleBufferGetSampleSizeArray(sampleBuffer, entryCount: count, arrayToFill: &sizes, entriesNeededOut: &sizeNeeded)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        var timingNeeded: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &timingNeeded)
        guard timingNeeded > 0 else { return [] }
        var out: [(pts90k: Int64, duration90k: Int64, data: Data)] = []
        out.reserveCapacity(count)
        var offset = 0
        for i in 0..<count {
            let sz = sizes[i]
            guard sz >= 0, offset + sz <= allBytes.count else { break }
            let t = i < timingNeeded ? timings[i] : timings[0]
            let pts = timingNeeded == 1
                ? CMTimeAdd(t.presentationTimeStamp, CMTimeMultiply(t.duration, multiplier: Int32(i)))
                : t.presentationTimeStamp
            let pts90k = safeTicks90k(pts)
            let dur90k = safeTicks90k(t.duration)
            out.append((pts90k, dur90k, allBytes.subdata(in: offset..<(offset + sz))))
            offset += sz
        }
        return out
    }

    // MARK: - ISO BMFF Edit-List Preroll Normalization

    private struct BMFFBox {
        let type: String
        let start: Int
        let headerSize: Int
        let end: Int
    }

    private static func readU32BE(_ data: Data, at offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func readU64BE(_ data: Data, at offset: Int) -> UInt64 {
        let hi = UInt64(readU32BE(data, at: offset))
        let lo = UInt64(readU32BE(data, at: offset + 4))
        return (hi << 32) | lo
    }

    private static func writeU32BE(_ data: inout Data, at offset: Int, value: UInt32) {
        data[offset] = UInt8((value >> 24) & 0xFF)
        data[offset + 1] = UInt8((value >> 16) & 0xFF)
        data[offset + 2] = UInt8((value >> 8) & 0xFF)
        data[offset + 3] = UInt8(value & 0xFF)
    }

    private static func writeU64BE(_ data: inout Data, at offset: Int, value: UInt64) {
        writeU32BE(&data, at: offset, value: UInt32((value >> 32) & 0xFFFFFFFF))
        writeU32BE(&data, at: offset + 4, value: UInt32(value & 0xFFFFFFFF))
    }

    private static func readFourCC(_ data: Data, at offset: Int) -> String {
        String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func parseBoxes(in data: Data, from start: Int, to limit: Int) -> [BMFFBox] {
        var result: [BMFFBox] = []
        var offset = start
        while offset + 8 <= limit {
            let size32 = readU32BE(data, at: offset)
            let type = readFourCC(data, at: offset + 4)
            let headerSize: Int
            let end: Int
            if size32 == 0 {
                headerSize = 8
                end = limit
            } else if size32 == 1 {
                guard offset + 16 <= limit else { break }
                let size64 = readU64BE(data, at: offset + 8)
                guard size64 >= 16, size64 <= UInt64(limit - offset) else { break }
                headerSize = 16
                end = offset + Int(size64)
            } else {
                guard size32 >= 8, Int(size32) <= (limit - offset) else { break }
                headerSize = 8
                end = offset + Int(size32)
            }
            result.append(BMFFBox(type: type, start: offset, headerSize: headerSize, end: end))
            offset = end
        }
        return result
    }

    private static func readHeaderDuration(_ data: Data, box: BMFFBox, v0Offset: Int, v1Offset: Int) -> UInt64? {
        let payload = box.start + box.headerSize
        guard payload < box.end else { return nil }
        let version = data[payload]
        if version == 0 {
            let off = payload + v0Offset
            guard off + 4 <= box.end else { return nil }
            return UInt64(readU32BE(data, at: off))
        } else if version == 1 {
            let off = payload + v1Offset
            guard off + 8 <= box.end else { return nil }
            return readU64BE(data, at: off)
        }
        return nil
    }

    private static func writeHeaderDuration(_ data: inout Data, box: BMFFBox, v0Offset: Int, v1Offset: Int, value: UInt64) {
        let payload = box.start + box.headerSize
        guard payload < box.end else { return }
        let version = data[payload]
        if version == 0 {
            let off = payload + v0Offset
            guard off + 4 <= box.end else { return }
            writeU32BE(&data, at: off, value: UInt32(min(value, UInt64(UInt32.max))))
        } else if version == 1 {
            let off = payload + v1Offset
            guard off + 8 <= box.end else { return }
            writeU64BE(&data, at: off, value: value)
        }
    }

    /// Normalizes a passthrough MP4 emitted by `AVAssetWriter`:
    /// 1. Strips leading empty `elst` segment (`media_time == -1`) on video tracks in-place via a trailing `free` box.
    /// 2. Removes pre-macOS 27 `AVAssetWriter` bogus prepended `mp4a` priming clones when verified byte-identical to `P0`.
    /// 3. Injects ISO 14496-12 `sgpd`/`sbgp` (`roll_distance = -1`) on `mp4a` tracks lacking it and shifts post-`moov` chunk offsets cleanly.
    static func stripLeadingEmptyVideoEdit(inMP4At url: URL, expectedAudioPacketCount: Int? = nil) throws {
        var data = try Data(contentsOf: url)
        let topBoxes = parseBoxes(in: data, from: 0, to: data.count)
        guard let moov = topBoxes.first(where: { $0.type == "moov" }),
              moov.headerSize == 8 else { return }
        let initialMoovEnd = moov.end

        let moovChildren = parseBoxes(in: data, from: moov.start + moov.headerSize, to: moov.end)
        guard let mvhd = moovChildren.first(where: { $0.type == "mvhd" }) else { return }

        var didModify = false
        var trackDurations: [UInt64] = []

        for trak in moovChildren where trak.type == "trak" {
            let trakChildren = parseBoxes(in: data, from: trak.start + trak.headerSize, to: trak.end)
            guard let tkhd = trakChildren.first(where: { $0.type == "tkhd" }),
                  let originalTrackDur = readHeaderDuration(data, box: tkhd, v0Offset: 20, v1Offset: 28) else {
                continue
            }
            var finalTrackDur = originalTrackDur

            let mdia = trakChildren.first(where: { $0.type == "mdia" })
            let hdlr = mdia.flatMap { parseBoxes(in: data, from: $0.start + $0.headerSize, to: $0.end).first(where: { $0.type == "hdlr" }) }
            let isVideo: Bool = {
                guard let hdlr else { return false }
                let typeOffset = hdlr.start + hdlr.headerSize + 8
                guard typeOffset + 4 <= hdlr.end else { return false }
                return readFourCC(data, at: typeOffset) == "vide"
            }()

            if isVideo, let edts = trakChildren.first(where: { $0.type == "edts" }) {
                let edtsChildren = parseBoxes(in: data, from: edts.start + edts.headerSize, to: edts.end)
                if let elst = edtsChildren.first(where: { $0.type == "elst" }),
                   elst.headerSize == 8,
                   elst.start + 16 <= elst.end {
                    let version = data[elst.start + 8]
                    let entryCount = readU32BE(data, at: elst.start + 12)
                    let entryBytes = (version == 0) ? 12 : (version == 1 ? 20 : 0)
                    let entriesStart = elst.start + 16
                    if entryBytes >= 8,
                       entryCount == 2,
                       entriesStart + 2 * entryBytes <= elst.end {
                        let emptyDur: UInt64
                        let emptyMediaTime: Int64
                        let activeDur: UInt64
                        let activeMediaTime: Int64
                        if version == 0 {
                            emptyDur = UInt64(readU32BE(data, at: entriesStart))
                            emptyMediaTime = Int64(Int32(bitPattern: readU32BE(data, at: entriesStart + 4)))
                            activeDur = UInt64(readU32BE(data, at: entriesStart + 12))
                            activeMediaTime = Int64(Int32(bitPattern: readU32BE(data, at: entriesStart + 16)))
                        } else {
                            emptyDur = readU64BE(data, at: entriesStart)
                            emptyMediaTime = Int64(bitPattern: readU64BE(data, at: entriesStart + 8))
                            activeDur = readU64BE(data, at: entriesStart + 20)
                            activeMediaTime = Int64(bitPattern: readU64BE(data, at: entriesStart + 28))
                        }

                        if emptyMediaTime == -1 && emptyDur > 0 && activeMediaTime >= 0 && activeDur > 0 {
                            let oldElstLen = elst.end - elst.start
                            let newElstLen = oldElstLen - entryBytes
                            let activeRange = (entriesStart + entryBytes)..<(entriesStart + 2 * entryBytes)
                            let activeBytes = Data(data[activeRange])
                            data.replaceSubrange(entriesStart..<(entriesStart + entryBytes), with: activeBytes)
                            writeU32BE(&data, at: elst.start + 12, value: 1)
                            writeU32BE(&data, at: elst.start, value: UInt32(newElstLen))

                            let freeStart = elst.end - entryBytes
                            writeU32BE(&data, at: freeStart, value: UInt32(entryBytes))
                            data[freeStart + 4] = 0x66 // 'f'
                            data[freeStart + 5] = 0x72 // 'r'
                            data[freeStart + 6] = 0x65 // 'e'
                            data[freeStart + 7] = 0x65 // 'e'
                            for z in (freeStart + 8)..<elst.end {
                                data[z] = 0
                            }

                            finalTrackDur = originalTrackDur > emptyDur ? (originalTrackDur - emptyDur) : activeDur
                            writeHeaderDuration(&data, box: tkhd, v0Offset: 20, v1Offset: 28, value: finalTrackDur)
                            didModify = true
                        }
                    }
                }
            }
            trackDurations.append(finalTrackDur)
        }

        if didModify, let maxDur = trackDurations.max() {
            writeHeaderDuration(&data, box: mvhd, v0Offset: 16, v1Offset: 24, value: maxDur)
        }

        if let expectedAudioPacketCount, expectedAudioPacketCount > 0,
           stripExcessPrependedAudioPriming(in: &data, expectedAudioPacketCount: expectedAudioPacketCount) {
            didModify = true
        }

        if injectMissingAACRollSampleGroups(in: &data) {
            didModify = true
        }

        if didModify {
            let finalTopBoxes = parseBoxes(in: data, from: 0, to: data.count)
            if let finalMoov = finalTopBoxes.first(where: { $0.type == "moov" }) {
                let netDelta = Int64(finalMoov.end) - Int64(initialMoovEnd)
                if netDelta != 0 {
                    shiftPostMoovChunkOffsets(in: &data, oldMoovEnd: initialMoovEnd, delta: netDelta)
                }
            }
            try data.write(to: url, options: .atomic)
        }
    }

    private static func appendU32BE(_ out: inout [UInt8], _ value: UInt32) {
        out.append(UInt8((value >> 24) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    }

    private static func appendU64BE(_ out: inout [UInt8], _ value: UInt64) {
        appendU32BE(&out, UInt32((value >> 32) & 0xFFFFFFFF))
        appendU32BE(&out, UInt32(value & 0xFFFFFFFF))
    }

    private static func stripExcessPrependedAudioPriming(in data: inout Data, expectedAudioPacketCount: Int) -> Bool {
        let topBoxes = parseBoxes(in: data, from: 0, to: data.count)
        guard let moov = topBoxes.first(where: { $0.type == "moov" && $0.headerSize == 8 }) else {
            return false
        }
        let moovChildren = parseBoxes(in: data, from: moov.start + moov.headerSize, to: moov.end)
        for trak in moovChildren where trak.type == "trak" && trak.headerSize == 8 {
            let trakChildren = parseBoxes(in: data, from: trak.start + trak.headerSize, to: trak.end)
            guard let mdia = trakChildren.first(where: { $0.type == "mdia" && $0.headerSize == 8 }) else { continue }
            let mdiaChildren = parseBoxes(in: data, from: mdia.start + mdia.headerSize, to: mdia.end)
            guard let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }),
                  hdlr.start + hdlr.headerSize + 12 <= hdlr.end,
                  readFourCC(data, at: hdlr.start + hdlr.headerSize + 8) == "soun",
                  let mdhd = mdiaChildren.first(where: { $0.type == "mdhd" && $0.headerSize == 8 }),
                  let minf = mdiaChildren.first(where: { $0.type == "minf" && $0.headerSize == 8 }) else {
                continue
            }
            let minfChildren = parseBoxes(in: data, from: minf.start + minf.headerSize, to: minf.end)
            guard let stbl = minfChildren.first(where: { $0.type == "stbl" && $0.headerSize == 8 }) else { continue }
            let stblChildren = parseBoxes(in: data, from: stbl.start + stbl.headerSize, to: stbl.end)
            guard let stsd = stblChildren.first(where: { $0.type == "stsd" && $0.headerSize == 8 }),
                  stsd.start + 24 <= stsd.end,
                  readFourCC(data, at: stsd.start + 20) == "mp4a",
                  let stsz = stblChildren.first(where: { $0.type == "stsz" && $0.headerSize == 8 }),
                  stsz.start + 20 <= stsz.end,
                  let stts = stblChildren.first(where: { $0.type == "stts" && $0.headerSize == 8 }),
                  stts.start + 16 <= stts.end,
                  let stsc = stblChildren.first(where: { $0.type == "stsc" && $0.headerSize == 8 }),
                  stsc.start + 16 <= stsc.end else {
                continue
            }
            let offsetBox = stblChildren.first(where: { ($0.type == "stco" || $0.type == "co64") && $0.headerSize == 8 })
            guard let offsetBox, offsetBox.start + 16 <= offsetBox.end else { continue }

            let uniformSampleSize = readU32BE(data, at: stsz.start + 12)
            let actualCount = Int(readU32BE(data, at: stsz.start + 16))
            guard uniformSampleSize == 0,
                  actualCount > expectedAudioPacketCount,
                  stsz.start + 20 + actualCount * 4 <= stsz.end else {
                continue
            }
            let excess = actualCount - expectedAudioPacketCount
            var sizes = [UInt32]()
            sizes.reserveCapacity(actualCount)
            for i in 0..<actualCount {
                sizes.append(readU32BE(data, at: stsz.start + 20 + i * 4))
            }
            let p0Len = Int(sizes[excess])
            guard p0Len > 0, (0..<excess).allSatisfy({ Int(sizes[$0]) == p0Len }) else {
                continue
            }

            let isCo64 = (offsetBox.type == "co64")
            let chunkCount = Int(readU32BE(data, at: offsetBox.start + 12))
            let chunkStride = isCo64 ? 8 : 4
            guard chunkCount > 0, offsetBox.start + 16 + chunkCount * chunkStride <= offsetBox.end else { continue }
            var chunkOffsets = [UInt64]()
            chunkOffsets.reserveCapacity(chunkCount)
            for c in 0..<chunkCount {
                let p = offsetBox.start + 16 + c * chunkStride
                chunkOffsets.append(isCo64 ? readU64BE(data, at: p) : UInt64(readU32BE(data, at: p)))
            }

            let stscCount = Int(readU32BE(data, at: stsc.start + 12))
            guard stscCount > 0, stsc.start + 16 + stscCount * 12 <= stsc.end else { continue }
            var stscRuns: [(firstChunk1: Int, count: Int, sdi: UInt32)] = []
            stscRuns.reserveCapacity(stscCount)
            for e in 0..<stscCount {
                let p = stsc.start + 16 + e * 12
                stscRuns.append((Int(readU32BE(data, at: p)), Int(readU32BE(data, at: p + 4)), readU32BE(data, at: p + 8)))
            }

            var samplesPerChunk = [Int](repeating: 0, count: chunkCount)
            var sdiPerChunk = [UInt32](repeating: 1, count: chunkCount)
            for e in 0..<stscRuns.count {
                let startC = max(0, stscRuns[e].firstChunk1 - 1)
                let endC = (e + 1 < stscRuns.count) ? min(chunkCount, max(0, stscRuns[e + 1].firstChunk1 - 1)) : chunkCount
                guard startC < endC else { continue }
                for c in startC..<endC {
                    samplesPerChunk[c] = stscRuns[e].count
                    sdiPerChunk[c] = stscRuns[e].sdi
                }
            }
            guard samplesPerChunk.reduce(0, +) == actualCount else { continue }

            // Verify every prepended sample 0..<excess is byte-identical in `mdat` to sample `excess` (P0).
            var firstOffsets = [UInt64]()
            firstOffsets.reserveCapacity(excess + 1)
            var sIdx = 0
            for c in 0..<chunkCount where firstOffsets.count <= excess {
                var off = chunkOffsets[c]
                for _ in 0..<samplesPerChunk[c] {
                    firstOffsets.append(off)
                    off += UInt64(sizes[sIdx])
                    sIdx += 1
                    if firstOffsets.count > excess { break }
                }
            }
            guard firstOffsets.count > excess,
                  firstOffsets.allSatisfy({ $0 <= UInt64(data.count - p0Len) }) else {
                continue
            }
            let refStart = Int(firstOffsets[excess])
            let refPacket = data[refStart..<(refStart + p0Len)]
            guard (0..<excess).allSatisfy({ idx in
                let st = Int(firstOffsets[idx])
                return data[st..<(st + p0Len)] == refPacket
            }) else {
                continue
            }

            // Compute new `stts` and total dropped media duration.
            let sttsCount = Int(readU32BE(data, at: stts.start + 12))
            guard stts.start + 16 + sttsCount * 8 <= stts.end else { continue }
            var newSttsEntries: [(count: UInt32, dur: UInt32)] = []
            var remDropStts = excess
            var droppedMediaDur: UInt64 = 0
            for i in 0..<sttsCount {
                let p = stts.start + 16 + i * 8
                let c = Int(readU32BE(data, at: p))
                let d = readU32BE(data, at: p + 4)
                if remDropStts >= c {
                    remDropStts -= c
                    droppedMediaDur += UInt64(c) * UInt64(d)
                } else if remDropStts > 0 {
                    let kept = c - remDropStts
                    droppedMediaDur += UInt64(remDropStts) * UInt64(d)
                    remDropStts = 0
                    newSttsEntries.append((UInt32(kept), d))
                } else {
                    newSttsEntries.append((UInt32(c), d))
                }
            }
            guard remDropStts == 0 else { continue }

            // Compute updated chunks (`stco`/`co64` and `stsc`).
            var keptOffsets: [UInt64] = []
            var keptCounts: [Int] = []
            var keptSDIs: [UInt32] = []
            var remDropChunk = excess
            var cursor = 0
            for c in 0..<chunkCount {
                let n = samplesPerChunk[c]
                if remDropChunk >= n {
                    remDropChunk -= n
                    cursor += n
                } else if remDropChunk > 0 {
                    var advance: UInt64 = 0
                    for k in 0..<remDropChunk {
                        advance += UInt64(sizes[cursor + k])
                    }
                    keptOffsets.append(chunkOffsets[c] + advance)
                    keptCounts.append(n - remDropChunk)
                    keptSDIs.append(sdiPerChunk[c])
                    cursor += n
                    remDropChunk = 0
                } else {
                    keptOffsets.append(chunkOffsets[c])
                    keptCounts.append(n)
                    keptSDIs.append(sdiPerChunk[c])
                    cursor += n
                }
            }
            guard !keptOffsets.isEmpty else { continue }

            var newStscRuns: [(firstChunk1: UInt32, count: UInt32, sdi: UInt32)] = []
            for idx in 0..<keptCounts.count {
                let cntU = UInt32(keptCounts[idx])
                let sdiU = keptSDIs[idx]
                if let last = newStscRuns.last, last.count == cntU && last.sdi == sdiU {
                    continue
                }
                newStscRuns.append((UInt32(idx + 1), cntU, sdiU))
            }

            func makeFullBox(_ fourCC: String, versionFlags: UInt32, body: [UInt8]) -> [UInt8] {
                var box = [UInt8]()
                box.reserveCapacity(12 + body.count)
                appendU32BE(&box, UInt32(12 + body.count))
                box.append(contentsOf: fourCC.utf8)
                appendU32BE(&box, versionFlags)
                box.append(contentsOf: body)
                return box
            }

            var stszBody = [UInt8]()
            appendU32BE(&stszBody, 0)
            appendU32BE(&stszBody, UInt32(expectedAudioPacketCount))
            for i in excess..<actualCount { appendU32BE(&stszBody, sizes[i]) }
            let newStszBox = makeFullBox("stsz", versionFlags: 0, body: stszBody)

            var sttsBody = [UInt8]()
            appendU32BE(&sttsBody, UInt32(newSttsEntries.count))
            for entry in newSttsEntries {
                appendU32BE(&sttsBody, entry.count)
                appendU32BE(&sttsBody, entry.dur)
            }
            let newSttsBox = makeFullBox("stts", versionFlags: 0, body: sttsBody)

            var stscBody = [UInt8]()
            appendU32BE(&stscBody, UInt32(newStscRuns.count))
            for run in newStscRuns {
                appendU32BE(&stscBody, run.firstChunk1)
                appendU32BE(&stscBody, run.count)
                appendU32BE(&stscBody, run.sdi)
            }
            let newStscBox = makeFullBox("stsc", versionFlags: 0, body: stscBody)

            var offBody = [UInt8]()
            appendU32BE(&offBody, UInt32(keptOffsets.count))
            for off in keptOffsets {
                if isCo64 { appendU64BE(&offBody, off) } else { appendU32BE(&offBody, UInt32(off)) }
            }
            let newOffBox = makeFullBox(offsetBox.type, versionFlags: 0, body: offBody)

            // Update `mdhd.duration` and `elst.media_time` in-place before splicing `stbl`.
            if let origMdhdDur = readHeaderDuration(data, box: mdhd, v0Offset: 16, v1Offset: 24),
               origMdhdDur > droppedMediaDur {
                writeHeaderDuration(&data, box: mdhd, v0Offset: 16, v1Offset: 24, value: origMdhdDur - droppedMediaDur)
            }
            if let edts = trakChildren.first(where: { $0.type == "edts" }) {
                let edtsChildren = parseBoxes(in: data, from: edts.start + edts.headerSize, to: edts.end)
                if let elst = edtsChildren.first(where: { $0.type == "elst" && $0.headerSize == 8 }),
                   elst.start + 16 <= elst.end {
                    let ver = data[elst.start + 8]
                    let cnt = readU32BE(data, at: elst.start + 12)
                    if cnt == 1 && ver == 0 && elst.start + 28 <= elst.end {
                        let mt = Int32(bitPattern: readU32BE(data, at: elst.start + 20))
                        if mt > 0 && UInt64(mt) <= droppedMediaDur {
                            writeU32BE(&data, at: elst.start + 20, value: 0)
                        }
                    } else if cnt == 1 && ver == 1 && elst.start + 36 <= elst.end {
                        let mt = Int64(bitPattern: readU64BE(data, at: elst.start + 24))
                        if mt > 0 && UInt64(mt) <= droppedMediaDur {
                            writeU64BE(&data, at: elst.start + 24, value: 0)
                        }
                    }
                }
            }

            var newStblPayload = Data()
            for child in stblChildren {
                switch child.type {
                case "stsz": newStblPayload.append(contentsOf: newStszBox)
                case "stts": newStblPayload.append(contentsOf: newSttsBox)
                case "stsc": newStblPayload.append(contentsOf: newStscBox)
                case "stco", "co64": newStblPayload.append(contentsOf: newOffBox)
                default: newStblPayload.append(data[child.start..<child.end])
                }
            }
            var newStblHeader = [UInt8]()
            appendU32BE(&newStblHeader, UInt32(8 + newStblPayload.count))
            newStblHeader.append(contentsOf: "stbl".utf8)
            var newStblBox = Data(newStblHeader)
            newStblBox.append(newStblPayload)

            let stblDelta = Int64(newStblBox.count) - Int64(stbl.end - stbl.start)
            for box in [minf, mdia, trak, moov] {
                let updatedSize = Int64(readU32BE(data, at: box.start)) + stblDelta
                guard updatedSize >= 8 else { return false }
                writeU32BE(&data, at: box.start, value: UInt32(updatedSize))
            }
            data.replaceSubrange(stbl.start..<stbl.end, with: newStblBox)
            return true
        }
        return false
    }

    /// Injects ISO 14496-12 `sgpd` (`roll_distance = -1`) and `sbgp` (`roll`) sample-group boxes into
    /// passthrough `mp4a` audio tracks that lack them (container size headers updated; caller shifts `stco`/`co64`).
    private static func injectMissingAACRollSampleGroups(in data: inout Data) -> Bool {
        var didInsert = false

        for _ in 0..<16 {
            let topBoxes = parseBoxes(in: data, from: 0, to: data.count)
            guard let moov = topBoxes.first(where: { $0.type == "moov" }),
                  moov.headerSize == 8 else {
                break
            }
            let moovChildren = parseBoxes(in: data, from: moov.start + moov.headerSize, to: moov.end)
            var insertedThisPass = false

            for trak in moovChildren where trak.type == "trak" && trak.headerSize == 8 {
                let trakChildren = parseBoxes(in: data, from: trak.start + trak.headerSize, to: trak.end)
                guard let mdia = trakChildren.first(where: { $0.type == "mdia" && $0.headerSize == 8 }) else {
                    continue
                }
                let mdiaChildren = parseBoxes(in: data, from: mdia.start + mdia.headerSize, to: mdia.end)
                guard let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }),
                      hdlr.start + hdlr.headerSize + 12 <= hdlr.end,
                      readFourCC(data, at: hdlr.start + hdlr.headerSize + 8) == "soun",
                      let minf = mdiaChildren.first(where: { $0.type == "minf" && $0.headerSize == 8 }) else {
                    continue
                }
                let minfChildren = parseBoxes(in: data, from: minf.start + minf.headerSize, to: minf.end)
                guard let stbl = minfChildren.first(where: { $0.type == "stbl" && $0.headerSize == 8 }) else {
                    continue
                }
                let stblChildren = parseBoxes(in: data, from: stbl.start + stbl.headerSize, to: stbl.end)
                guard !stblChildren.contains(where: { $0.type == "sgpd" || $0.type == "sbgp" }),
                      let stsd = stblChildren.first(where: { $0.type == "stsd" && $0.headerSize == 8 }),
                      stsd.start + 24 <= stsd.end,
                      readFourCC(data, at: stsd.start + 20) == "mp4a",
                      let stsz = stblChildren.first(where: { $0.type == "stsz" && $0.headerSize == 8 }),
                      stsz.start + 20 <= stsz.end else {
                    continue
                }
                let sampleCount = readU32BE(data, at: stsz.start + 16)
                guard sampleCount > 0 else { continue }

                let groupBoxes: [UInt8] = [
                    // sgpd (26 bytes): version=1, grouping='roll', default_length=2, entry_count=1, roll_distance=-1
                    0x00, 0x00, 0x00, 0x1A,
                    0x73, 0x67, 0x70, 0x64,
                    0x01, 0x00, 0x00, 0x00,
                    0x72, 0x6F, 0x6C, 0x6C,
                    0x00, 0x00, 0x00, 0x02,
                    0x00, 0x00, 0x00, 0x01,
                    0xFF, 0xFF,
                    // sbgp (28 bytes): version=0, grouping='roll', entry_count=1, sample_count, group=1
                    0x00, 0x00, 0x00, 0x1C,
                    0x73, 0x62, 0x67, 0x70,
                    0x00, 0x00, 0x00, 0x00,
                    0x72, 0x6F, 0x6C, 0x6C,
                    0x00, 0x00, 0x00, 0x01,
                    UInt8((sampleCount >> 24) & 0xFF),
                    UInt8((sampleCount >> 16) & 0xFF),
                    UInt8((sampleCount >> 8) & 0xFF),
                    UInt8(sampleCount & 0xFF),
                    0x00, 0x00, 0x00, 0x01,
                ]
                let deltaU32 = UInt32(groupBoxes.count)
                for box in [stbl, minf, mdia, trak, moov] {
                    let oldSize = readU32BE(data, at: box.start)
                    writeU32BE(&data, at: box.start, value: oldSize + deltaU32)
                }
                data.insert(contentsOf: groupBoxes, at: stsd.end)
                didInsert = true
                insertedThisPass = true
                break
            }
            if !insertedThisPass {
                break
            }
        }

        return didInsert
    }

    private static func shiftPostMoovChunkOffsets(in data: inout Data, oldMoovEnd: Int, delta: Int64) {
        let updatedTopBoxes = parseBoxes(in: data, from: 0, to: data.count)
        guard let updatedMoov = updatedTopBoxes.first(where: { $0.type == "moov" }) else {
            return
        }
        let moovChildren = parseBoxes(in: data, from: updatedMoov.start + updatedMoov.headerSize, to: updatedMoov.end)
        for trak in moovChildren where trak.type == "trak" {
            let trakChildren = parseBoxes(in: data, from: trak.start + trak.headerSize, to: trak.end)
            guard let mdia = trakChildren.first(where: { $0.type == "mdia" }),
                  let minf = parseBoxes(in: data, from: mdia.start + mdia.headerSize, to: mdia.end).first(where: { $0.type == "minf" }),
                  let stbl = parseBoxes(in: data, from: minf.start + minf.headerSize, to: minf.end).first(where: { $0.type == "stbl" }) else {
                continue
            }
            let stblChildren = parseBoxes(in: data, from: stbl.start + stbl.headerSize, to: stbl.end)
            for box in stblChildren where box.type == "stco" && box.start + box.headerSize + 8 <= box.end {
                let count = Int(readU32BE(data, at: box.start + box.headerSize + 4))
                let entriesStart = box.start + box.headerSize + 8
                guard entriesStart + count * 4 <= box.end else { continue }
                for idx in 0..<count {
                    let offPos = entriesStart + idx * 4
                    let oldOff = readU32BE(data, at: offPos)
                    if Int(oldOff) >= oldMoovEnd {
                        let shifted = Int64(oldOff) + delta
                        if shifted >= 0 {
                            writeU32BE(&data, at: offPos, value: UInt32(shifted))
                        }
                    }
                }
            }
            for box in stblChildren where box.type == "co64" && box.start + box.headerSize + 8 <= box.end {
                let count = Int(readU32BE(data, at: box.start + box.headerSize + 4))
                let entriesStart = box.start + box.headerSize + 8
                guard entriesStart + count * 8 <= box.end else { continue }
                for idx in 0..<count {
                    let offPos = entriesStart + idx * 8
                    let oldOff = readU64BE(data, at: offPos)
                    if oldOff >= UInt64(oldMoovEnd) {
                        let shifted = Int64(bitPattern: oldOff) + delta
                        if shifted >= 0 {
                            writeU64BE(&data, at: offPos, value: UInt64(shifted))
                        }
                    }
                }
            }
        }
    }
}
