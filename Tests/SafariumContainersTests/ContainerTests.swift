import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import SafariumCore
import UniformTypeIdentifiers
import VideoToolbox
import XCTest
@testable import SafariumContainers

final class ContainerTests: XCTestCase {
    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safarium-containers-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func generateTestMP4(
        url: URL,
        codec: AVVideoCodecType,
        frames: Int = 30,
        width: Int = 160,
        height: Int = 120,
        fps: Int32 = 30,
        allowBFrames: Bool = true
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        writer.movieTimeScale = 600

        let vSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 600_000,
                AVVideoMaxKeyFrameIntervalKey: 15,
                AVVideoAllowFrameReorderingKey: allowBFrames,
            ],
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vIn,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(vIn) else { throw SafariumError.encode("cannot add video input") }
        writer.add(vIn)

        let pcmFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true)!
        let aSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings, sourceFormatHint: pcmFmt.formatDescription)
        aIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(aIn) else { throw SafariumError.encode("cannot add audio input") }
        writer.add(aIn)

        guard writer.startWriting() else {
            throw SafariumError.encode("startWriting failed: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)

        for i in 0..<frames {
            while !vIn.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var pb: CVPixelBuffer?
            let st = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool!, &pb)
            guard st == kCVReturnSuccess, let buf = pb else {
                throw SafariumError.encode("pixel buffer pool failed")
            }
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                let bpr = CVPixelBufferGetBytesPerRow(buf)
                let p = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let off = y * bpr + x * 4
                        p[off + 0] = UInt8(((x + y) + i * 3) & 0xFF)
                        p[off + 1] = UInt8((y * 2 + i * 5) & 0xFF)
                        p[off + 2] = UInt8((x * 2 + i * 7) & 0xFF)
                        p[off + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            let pts = CMTime(value: Int64(i) * 20, timescale: 600)
            guard adaptor.append(buf, withPresentationTime: pts) else {
                throw SafariumError.encode("video append failed at \(i)")
            }
        }
        vIn.markAsFinished()

        let totalAudio = 48_000
        var sent = 0
        while sent < totalAudio {
            while !aIn.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            let take = min(1024, totalAudio - sent)
            var samples = [Float](repeating: 0, count: take * 2)
            for f in 0..<take {
                let t = Double(sent + f) / 48_000.0
                samples[f * 2 + 0] = Float(0.25 * sin(2.0 * .pi * 440.0 * t))
                samples[f * 2 + 1] = Float(0.25 * sin(2.0 * .pi * 660.0 * t))
            }
            let byteLen = samples.count * 4
            var bb: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteLen,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: byteLen, flags: 0, blockBufferOut: &bb
            )
            samples.withUnsafeBytes { raw in
                _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: byteLen)
            }
            var sb: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: bb!,
                formatDescription: pcmFmt.formatDescription,
                sampleCount: take,
                presentationTimeStamp: CMTime(value: Int64(sent), timescale: 48_000),
                packetDescriptions: nil,
                sampleBufferOut: &sb
            )
            guard aIn.append(sb!) else {
                throw SafariumError.encode("audio append failed")
            }
            sent += take
        }
        aIn.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(frames) * 20, timescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw SafariumError.encode("finishWriting failed: \(writer.error?.localizedDescription ?? "?")")
        }
    }

    private func extractVideoAndAudioHashesAndCounts(_ url: URL) async throws -> (
        videoHashes: [String],
        audioHashes: [String],
        decodedVideoFrames: Int,
        decodedAudioBytes: Int,
        subtitleTexts: [String]
    ) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let vTrack = try await asset.loadTracks(withMediaType: .video).first!
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first!
        let subTracks = try await asset.loadTracks(withMediaType: .subtitle)

        // 1. Packet SHA-256 pass
        let pktReader = try AVAssetReader(asset: asset)
        let vo = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        let ao = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
        pktReader.add(vo)
        pktReader.add(ao)
        let so = subTracks.first.map { AVAssetReaderTrackOutput(track: $0, outputSettings: nil) }
        if let so { pktReader.add(so) }
        guard pktReader.startReading() else {
            throw SafariumError.encode("packet reader failed: \(pktReader.error?.localizedDescription ?? "?")")
        }

        var vHashes: [String] = []
        while let sb = vo.copyNextSampleBuffer() {
            guard sb.numSamples > 0, let db = sb.dataBuffer else { continue }
            let len = CMBlockBufferGetDataLength(db)
            var bytes = Data(count: len)
            if len > 0 {
                bytes.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(db, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            }
            vHashes.append(sha256Hex(bytes))
        }

        var aHashes: [String] = []
        while let sb = ao.copyNextSampleBuffer() {
            let count = sb.numSamples
            guard count > 0, let db = sb.dataBuffer else { continue }
            let total = CMBlockBufferGetDataLength(db)
            var all = Data(count: total)
            all.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(db, atOffset: 0, dataLength: total, destination: $0.baseAddress!) }
            if count == 1 {
                aHashes.append(sha256Hex(all))
            } else {
                var sizes = [Int](repeating: 0, count: count)
                var needed: CMItemCount = 0
                CMSampleBufferGetSampleSizeArray(sb, entryCount: count, arrayToFill: &sizes, entriesNeededOut: &needed)
                var off = 0
                for i in 0..<count {
                    let sz = sizes[i]
                    aHashes.append(sha256Hex(all.subdata(in: off..<(off + sz))))
                    off += sz
                }
            }
        }

        var subTexts: [String] = []
        if let so {
            while let sb = so.copyNextSampleBuffer() {
                guard sb.numSamples > 0, let db = sb.dataBuffer else { continue }
                let len = CMBlockBufferGetDataLength(db)
                var raw = Data(count: len)
                raw.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(db, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
                if raw.count >= 2 {
                    let textLen = (Int(raw[0]) << 8) | Int(raw[1])
                    if textLen > 0 && 2 + textLen <= raw.count {
                        subTexts.append(String(decoding: raw[2..<(2 + textLen)], as: UTF8.self))
                    }
                }
            }
        }

        // 2. Full decode frame count pass
        let decReader = try AVAssetReader(asset: asset)
        let dvo = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        let dao = AVAssetReaderTrackOutput(track: aTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ])
        decReader.add(dvo)
        decReader.add(dao)
        guard decReader.startReading() else {
            throw SafariumError.encode("decode reader failed")
        }
        var decVideo = 0
        while let sb = dvo.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sb) != nil { decVideo += 1 }
        }
        var decAudioBytes = 0
        while let sb = dao.copyNextSampleBuffer() {
            decAudioBytes += sb.dataBuffer.map { CMBlockBufferGetDataLength($0) } ?? 0
        }
        return (vHashes, aHashes, decVideo, decAudioBytes, subTexts)
    }

    private static func diagnoseAudioMismatch(_ url: URL) async throws -> String {
        let data = try Data(contentsOf: url)
        func u32(_ off: Int) -> UInt32 {
            let b0 = UInt32(data[off]) << 24
            let b1 = UInt32(data[off + 1]) << 16
            let b2 = UInt32(data[off + 2]) << 8
            let b3 = UInt32(data[off + 3])
            return b0 | b1 | b2 | b3
        }
        var trakSummaries: [String] = []
        func walk(_ start: Int, _ end: Int, _ curHandler: inout String, _ curElst: inout String, _ curStsz: inout String) {
            var off = start
            while off + 8 <= end {
                var sz = Int(u32(off))
                let typ = String(decoding: data[(off + 4)..<(off + 8)], as: UTF8.self)
                var hdr = 8
                if sz == 0 { sz = end - off }
                if sz == 1, off + 16 <= end {
                    let hi = UInt64(u32(off + 8))
                    let lo = UInt64(u32(off + 12))
                    sz = Int(min(UInt64(end - off), (hi << 32) | lo))
                    hdr = 16
                }
                guard sz >= hdr, off + sz <= end else { break }
                if typ == "moov" || typ == "mdia" || typ == "minf" || typ == "stbl" || typ == "edts" {
                    walk(off + hdr, off + sz, &curHandler, &curElst, &curStsz)
                } else if typ == "trak" {
                    var h = "?", e = "none", s = "none"
                    walk(off + hdr, off + sz, &h, &e, &s)
                    trakSummaries.append("trak(\(h) elst=\(e) stsz=\(s))")
                } else if typ == "hdlr", off + hdr + 12 <= off + sz {
                    curHandler = String(decoding: data[(off + hdr + 8)..<(off + hdr + 12)], as: UTF8.self)
                } else if typ == "elst", off + hdr + 8 <= off + sz {
                    let cnt = Int(u32(off + hdr + 4))
                    var items: [String] = []
                    for i in 0..<min(cnt, 4) {
                        let p = off + hdr + 8 + i * 12
                        if p + 12 <= off + sz {
                            let d = u32(p)
                            let mt = Int32(bitPattern: u32(p + 4))
                            items.append("(\(d),\(mt))")
                        }
                    }
                    curElst = "[\(items.joined(separator: ","))]"
                } else if typ == "stsz", off + hdr + 12 <= off + sz {
                    let ssz = u32(off + hdr + 4)
                    let cnt = Int(u32(off + hdr + 8))
                    var first5: [UInt32] = []
                    if ssz == 0 {
                        for i in 0..<min(cnt, 5) {
                            let p = off + hdr + 12 + i * 4
                            if p + 4 <= off + sz { first5.append(u32(p)) }
                        }
                    }
                    curStsz = "cnt=\(cnt):first=\(first5)"
                }
                off += sz
            }
        }
        var h0 = "", e0 = "", s0 = ""
        walk(0, data.count, &h0, &e0, &s0)

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        var bufDesc: [String] = []
        if let aTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let r = try AVAssetReader(asset: asset)
            let o = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            r.add(o)
            if r.startReading() {
                while let sb = o.copyNextSampleBuffer() {
                    let pts = sb.presentationTimeStamp
                    let dur = sb.duration
                    bufDesc.append("n=\(sb.numSamples)@\(pts.value)/\(pts.timescale)+d=\(dur.value)/\(dur.timescale)")
                }
            }
        }
        return "\(trakSummaries.joined(separator: " ")) bufs=\(bufDesc)"
    }

    private func makeUnpremultipliedPatternImage(width: Int, height: Int, frameIndex: Int) throws -> (cgImage: CGImage, rgba: [UInt8]) {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let checker = ((x / 16 + y / 16 + frameIndex) & 1) == 0
                let rTerm = (x * 255) / max(1, width - 1)
                let gTerm = (y * 255) / max(1, height - 1)
                let r = UInt8((rTerm + frameIndex * 31) & 0xFF)
                let g = UInt8((gTerm + frameIndex * 17) & 0xFF)
                let bVal: Int = checker ? ((x ^ y) & 0xFF) : 200
                let b = UInt8(bVal)
                let a: UInt8
                if x < width / 4 && y < height / 4 {
                    a = 0
                } else if x < width / 2 && y < height / 4 {
                    a = 128
                } else {
                    a = 255
                }
                rgba[idx + 0] = (a == 0) ? 0 : (a == 128 ? (r & 0xFE) : r)
                rgba[idx + 1] = (a == 0) ? 0 : (a == 128 ? (g & 0xFE) : g)
                rgba[idx + 2] = (a == 0) ? 0 : (a == 128 ? (b & 0xFE) : b)
                rgba[idx + 3] = a
            }
        }
        let data = Data(rgba)
        guard let provider = CGDataProvider(data: data as CFData),
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: cs,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw SafariumError.encode("failed to create straight RGBA CGImage")
        }
        return (cg, rgba)
    }

    private func decodeStraightRGBAFromCGImage(_ cgImage: CGImage) throws -> [UInt8] {
        let w = cgImage.width
        let h = cgImage.height
        guard let dp = cgImage.dataProvider, let cfData = dp.data as Data? else {
            throw SafariumError.encode("missing CGImage dataProvider")
        }
        let alphaInfo = cgImage.alphaInfo
        let byteOrder = cgImage.bitmapInfo.intersection(.byteOrderMask)
        let bpr = cgImage.bytesPerRow
        if alphaInfo == .last && (byteOrder == [] || byteOrder == .byteOrder32Big) && bpr == w * 4 {
            return [UInt8](cfData.prefix(w * h * 4))
        }
        var out = [UInt8](repeating: 0, count: w * h * 4)
        cfData.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: UInt8.self).baseAddress!
            for y in 0..<h {
                for x in 0..<w {
                    let s = y * bpr + x * 4
                    let d = (y * w + x) * 4
                    if byteOrder == .byteOrder32Little && (alphaInfo == .first || alphaInfo == .premultipliedFirst || alphaInfo == .noneSkipFirst) {
                        let b = src[s + 0], g = src[s + 1], r = src[s + 2], a = (alphaInfo == .noneSkipFirst) ? UInt8(255) : src[s + 3]
                        if alphaInfo == .premultipliedFirst && a > 0 && a < 255 {
                            out[d + 0] = UInt8(min(255, (Int(r) * 255 + Int(a) / 2) / Int(a)))
                            out[d + 1] = UInt8(min(255, (Int(g) * 255 + Int(a) / 2) / Int(a)))
                            out[d + 2] = UInt8(min(255, (Int(b) * 255 + Int(a) / 2) / Int(a)))
                            out[d + 3] = a
                        } else {
                            out[d + 0] = r; out[d + 1] = g; out[d + 2] = b; out[d + 3] = a
                        }
                    } else {
                        let r = src[s + 0], g = src[s + 1], b = src[s + 2], a = (alphaInfo == .noneSkipLast) ? UInt8(255) : src[s + 3]
                        if alphaInfo == .premultipliedLast && a > 0 && a < 255 {
                            out[d + 0] = UInt8(min(255, (Int(r) * 255 + Int(a) / 2) / Int(a)))
                            out[d + 1] = UInt8(min(255, (Int(g) * 255 + Int(a) / 2) / Int(a)))
                            out[d + 2] = UInt8(min(255, (Int(b) * 255 + Int(a) / 2) / Int(a)))
                            out[d + 3] = a
                        } else {
                            out[d + 0] = r; out[d + 1] = g; out[d + 2] = b; out[d + 3] = a
                        }
                    }
                }
            }
        }
        return out
    }

    private func makeComplexGraphicCGImage(width: Int = 320, height: Int = 240, includeAlpha: Bool) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let info: UInt32 = includeAlpha
            ? (CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            : (CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: cs, bitmapInfo: info)!
        let colors = [
            CGColor(srgbRed: 0.08, green: 0.14, blue: 0.30, alpha: includeAlpha ? 0.55 : 1.0),
            CGColor(srgbRed: 0.92, green: 0.36, blue: 0.22, alpha: 1.0),
        ] as CFArray
        let grad = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: width, y: height), options: [])
        ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.92, blue: 0.20, alpha: 1.0))
        ctx.fill(CGRect(x: 40, y: 40, width: width / 3, height: height / 3))
        return ctx.makeImage()!
    }

    private func makeSyntheticAudioFile(
        url: URL,
        formatID: AudioFormatID,
        fileType: AudioFileTypeID,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        durationSeconds: Double = 0.5
    ) throws {
        try? FileManager.default.removeItem(at: url)
        if formatID == kAudioFormatMPEG4AAC || formatID == kAudioFormatLinearPCM {
            let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)!
            let total = AVAudioFrameCount((sampleRate * durationSeconds).rounded())
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: total)!
            buf.frameLength = total
            for c in 0..<channels {
                let ptr = buf.floatChannelData![c]
                for i in 0..<Int(total) {
                    let t = Double(i) / sampleRate
                    ptr[i] = Float(0.35 * sin(2.0 * .pi * (440.0 + Double(c) * 220.0) * t))
                }
            }
            let settings: [String: Any]
            if formatID == kAudioFormatMPEG4AAC {
                settings = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: 128_000,
                ]
            } else {
                settings = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                ]
            }
            let af = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try af.write(from: buf)
            #if compiler(>=6.0)
            if #available(macOS 15.0, *) {
                af.close()
            }
            #endif
            return
        }
        var srcASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 4),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * 4),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var dstASBD = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: formatID,
            mFormatFlags: formatID == kAudioFormatMPEG4AAC ? UInt32(MPEG4ObjectID.AAC_LC.rawValue) : 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: formatID == kAudioFormatMPEG4AAC ? 1024 : 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var sz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        _ = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo, 0, nil, &sz, &dstASBD)

        var extRef: ExtAudioFileRef?
        let st1 = ExtAudioFileCreateWithURL(url as CFURL, fileType, &dstASBD, nil, AudioFileFlags.eraseFile.rawValue, &extRef)
        guard st1 == noErr, let ext = extRef else {
            throw SafariumError.encode("ExtAudioFileCreateWithURL failed: \(st1)")
        }
        defer { ExtAudioFileDispose(ext) }
        let st2 = ExtAudioFileSetProperty(ext, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &srcASBD)
        guard st2 == noErr else {
            throw SafariumError.encode("SetClientDataFormat failed: \(st2)")
        }
        let total = Int((sampleRate * durationSeconds).rounded())
        var samples = [Float](repeating: 0, count: total * channels)
        for i in 0..<total {
            let t = Double(i) / sampleRate
            for c in 0..<channels {
                samples[i * channels + c] = Float(0.35 * sin(2.0 * .pi * (440.0 + Double(c) * 220.0) * t))
            }
        }
        let st3 = samples.withUnsafeMutableBytes { raw in
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(raw.count), mData: raw.baseAddress)
            )
            return ExtAudioFileWrite(ext, UInt32(total), &abl)
        }
        guard st3 == noErr else {
            throw SafariumError.encode("ExtAudioFileWrite failed: \(st3)")
        }
    }

    // MARK: - 1. EBML / Matroska / WebM Tests

    func testEBML_H264_AAC_ThaiSubtitles_RoundTrip_ExactParityAndFrameCount() async throws {
        let dir = try makeTempDir("ebml-h264")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcMP4 = dir.appendingPathComponent("src_h264.mp4")
        let mkvURL = dir.appendingPathComponent("out_h264.mkv")
        let roundMP4 = dir.appendingPathComponent("round_h264.mp4")

        try await generateTestMP4(url: srcMP4, codec: .h264, frames: 30, allowBFrames: true)
        let orig = try await extractVideoAndAudioHashesAndCounts(srcMP4)
        XCTAssertEqual(orig.videoHashes.count, 30)
        XCTAssertEqual(orig.decodedVideoFrames, 30)

        let thaiCues = [
            SafariumSRTCue(startMS: 100, endMS: 800, text: "ทดสอบภาษาไทย MKV UTF-8")
        ]
        let muxReport = try await EBMLMatroskaCodec.muxFromMP4OrMOV(
            inputURL: srcMP4,
            outputURL: mkvURL,
            docType: "matroska",
            subtitleCues: thaiCues,
            overwrite: false
        )
        XCTAssertEqual(muxReport.sourceContainer, "mp4")
        XCTAssertEqual(muxReport.targetContainer, "matroska")
        XCTAssertEqual(muxReport.videoPackets, 30)
        XCTAssertEqual(muxReport.audioPackets, orig.audioHashes.count)
        XCTAssertEqual(muxReport.subtitleCues, 1)

        let inspected = try EBMLMatroskaCodec.inspect(url: mkvURL)
        XCTAssertEqual(inspected.docType, "matroska")
        XCTAssertEqual(inspected.tracks.count, 3)
        XCTAssertEqual(inspected.tracks.first(where: { $0.kind == .video })?.codecID, "V_MPEG4/ISO/AVC")
        XCTAssertEqual(inspected.tracks.first(where: { $0.kind == .audio })?.codecID, "A_AAC")
        XCTAssertEqual(inspected.tracks.first(where: { $0.kind == .subtitle })?.codecID, "S_TEXT/UTF8")
        XCTAssertEqual(inspected.cues.first?.text, "ทดสอบภาษาไทย MKV UTF-8")
        XCTAssertGreaterThan(inspected.cuePointCount, 0)

        let demuxReport = try await EBMLMatroskaCodec.demuxToMP4(inputURL: mkvURL, outputURL: roundMP4, overwrite: false)
        XCTAssertEqual(demuxReport.videoPackets, 30)
        XCTAssertEqual(demuxReport.audioPackets, orig.audioHashes.count)
        XCTAssertEqual(demuxReport.subtitleCues, 1)

        let rAsset = AVURLAsset(url: roundMP4, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playable = try await rAsset.load(.isPlayable)
        XCTAssertTrue(playable)

        let round = try await extractVideoAndAudioHashesAndCounts(roundMP4)
        XCTAssertEqual(round.videoHashes, orig.videoHashes, "H.264 video packet SHA-256 must match 30/30")
        var audioDiag = ""
        if round.audioHashes != orig.audioHashes {
            audioDiag = " [diag: \(try await Self.diagnoseAudioMismatch(roundMP4))]"
        }
        XCTAssertEqual(round.audioHashes, orig.audioHashes, "AAC audio packet SHA-256 must match 100%\(audioDiag)")
        XCTAssertEqual(round.decodedVideoFrames, 30, "B-frame preroll minVPTS alignment must prevent 31->30 duplicate")
        XCTAssertGreaterThanOrEqual(round.decodedAudioBytes, orig.decodedAudioBytes)
        XCTAssertEqual(round.subtitleTexts, ["ทดสอบภาษาไทย MKV UTF-8"])

        // Also verify automatic tx3g -> S_TEXT/UTF8 extraction from roundMP4 without explicit subtitleCues param
        let mkvAutoSubURL = dir.appendingPathComponent("out_autosub.mkv")
        let autoMux = try await EBMLMatroskaCodec.muxFromMP4OrMOV(
            inputURL: roundMP4,
            outputURL: mkvAutoSubURL,
            docType: "matroska",
            overwrite: false
        )
        XCTAssertEqual(autoMux.subtitleCues, 1)
        let autoInspect = try EBMLMatroskaCodec.inspect(url: mkvAutoSubURL)
        XCTAssertEqual(autoInspect.cues.map(\.text), ["ทดสอบภาษาไทย MKV UTF-8"])
    }

    func testEBML_HEVC_AAC_RoundTrip_ExactParityAndFrameCount() async throws {
        let dir = try makeTempDir("ebml-hevc")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcMP4 = dir.appendingPathComponent("src_hevc.mp4")
        let mkvURL = dir.appendingPathComponent("out_hevc.mkv")
        let roundMP4 = dir.appendingPathComponent("round_hevc.mp4")

        try await generateTestMP4(url: srcMP4, codec: .hevc, frames: 30, allowBFrames: true)
        let orig = try await extractVideoAndAudioHashesAndCounts(srcMP4)
        XCTAssertEqual(orig.videoHashes.count, 30)

        _ = try await EBMLMatroskaCodec.muxFromMP4OrMOV(inputURL: srcMP4, outputURL: mkvURL, docType: "matroska", overwrite: false)
        let inspected = try EBMLMatroskaCodec.inspect(url: mkvURL)
        XCTAssertEqual(inspected.tracks.first(where: { $0.kind == .video })?.codecID, "V_MPEGH/ISO/HEVC")

        _ = try await EBMLMatroskaCodec.demuxToMP4(inputURL: mkvURL, outputURL: roundMP4, overwrite: false)
        let round = try await extractVideoAndAudioHashesAndCounts(roundMP4)
        XCTAssertEqual(round.videoHashes, orig.videoHashes)
        XCTAssertEqual(round.audioHashes, orig.audioHashes)
        XCTAssertEqual(round.decodedVideoFrames, 30)
        XCTAssertGreaterThanOrEqual(round.decodedAudioBytes, orig.decodedAudioBytes)
    }

    func testEBML_WebM_VP9_AV1_Opus_InspectAndStreamingUnknownSize() throws {
        let dir = try makeTempDir("ebml-webm")
        defer { try? FileManager.default.removeItem(at: dir) }

        let opusHead = Data([0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64, 0x01, 0x02, 0x38, 0x01, 0x80, 0xBB, 0x00, 0x00, 0x00, 0x00, 0x00])
        let av1C = Data([0x81, 0x08, 0x0C, 0x00])
        let vpcCFeature = Data([0x01, 0x01, 0x00, 0x02, 0x02, 0x00, 0x02, 0x01, 0x08, 0x01, 0x01])
        let tracks = [
            ContainerTrackInfo(trackNumber: 1, kind: .video, codecID: "V_VP9", width: 1280, height: 720, codecPrivate: vpcCFeature),
            ContainerTrackInfo(trackNumber: 2, kind: .video, codecID: "V_AV1", width: 1280, height: 720, codecPrivate: av1C),
            ContainerTrackInfo(trackNumber: 3, kind: .audio, codecID: "A_OPUS", sampleRate: 48_000, channels: 2, codecPrivate: opusHead),
        ]
        let packets = [
            DemuxedPacket(trackNumber: 1, kind: .video, pts90k: 0, dts90k: 0, duration90k: 3000, isKeyframe: true, data: Data([0x82, 0x49, 0x83, 0x42])),
            DemuxedPacket(trackNumber: 2, kind: .video, pts90k: 0, dts90k: 0, duration90k: 3000, isKeyframe: true, data: Data([0x12, 0x00])),
            DemuxedPacket(trackNumber: 3, kind: .audio, pts90k: 0, dts90k: 0, duration90k: 1800, isKeyframe: true, data: Data([0xFC, 0xFF, 0xFE])),
        ]
        let webmData = try EBMLMatroskaCodec.buildEBML(
            docType: "webm",
            tracks: tracks,
            packets: packets,
            durationMS: 33,
            streamingUnknownSegment: true
        )
        let webmURL = dir.appendingPathComponent("test.webm")
        try webmData.write(to: webmURL)

        let info = try EBMLMatroskaCodec.inspect(url: webmURL)
        XCTAssertEqual(info.docType, "webm")
        XCTAssertTrue(info.hasStreamingUnknownSize)
        XCTAssertEqual(info.tracks.count, 3)
        XCTAssertEqual(info.tracks[0].codecID, "V_VP9")
        XCTAssertEqual(info.tracks[1].codecID, "V_AV1")
        XCTAssertEqual(info.tracks[2].codecID, "A_OPUS")
        XCTAssertEqual(String(decoding: info.tracks[2].codecPrivate.prefix(8), as: UTF8.self), "OpusHead")
        XCTAssertEqual(info.packetCount, 3)
    }

    func testEBML_OverwriteFalsePreservationAndEmptyReject() async throws {
        let dir = try makeTempDir("ebml-overwrite")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcMP4 = dir.appendingPathComponent("src.mp4")
        try await generateTestMP4(url: srcMP4, codec: .h264, frames: 10)
        let mkvURL = dir.appendingPathComponent("existing.mkv")
        let sentinel = Data("KEEP_EXISTING_MKV".utf8)
        try sentinel.write(to: mkvURL)

        do {
            _ = try await EBMLMatroskaCodec.muxFromMP4OrMOV(inputURL: srcMP4, outputURL: mkvURL, docType: "matroska", overwrite: false)
            XCTFail("Expected overwrite=false to throw")
        } catch {
            XCTAssertTrue(error is SafariumError)
        }
        XCTAssertEqual(try Data(contentsOf: mkvURL), sentinel)

        let emptyFile = dir.appendingPathComponent("empty.mkv")
        try Data().write(to: emptyFile)
        XCTAssertThrowsError(try EBMLMatroskaCodec.inspect(url: emptyFile))
    }

    // MARK: - 2. MPEG-TS Tests

    func testMPEGTS_33Bit90kHzPTSRolloverUnwrap() {
        var uw = TSPTSUnwrapper()
        let preWrap: UInt64 = 0x1_FFFF_FA00
        let postWrap1: UInt64 = (preWrap + 3000) & 0x1_FFFF_FFFF
        let postWrap2: UInt64 = (preWrap + 6000) & 0x1_FFFF_FFFF
        let u0 = uw.unwrap(preWrap)
        let u1 = uw.unwrap(postWrap1)
        let u2 = uw.unwrap(postWrap2)
        XCTAssertEqual(u1 - u0, 3000)
        XCTAssertEqual(u2 - u1, 3000)
        XCTAssertEqual(u1, Int64(postWrap1) + TSPTSUnwrapper.modulus)
        XCTAssertEqual(u2, Int64(postWrap2) + TSPTSUnwrapper.modulus)

        // Also test B-frame PTS crossing back below 2^33 after I-frame wrapped past 0
        var uwB = TSPTSUnwrapper()
        let iPre = uwB.unwrap(0x1_FFFF_FC00)
        let pPost = uwB.unwrap(0x0000_07D0) // wrapped (+3024 ticks)
        let bPre = uwB.unwrap(0x1_FFFF_FE00) // B-frame logically between iPre and pPost
        XCTAssertGreaterThan(pPost, iPre)
        XCTAssertGreaterThan(bPre, iPre)
        XCTAssertLessThan(bPre, pPost)
    }

    func testMPEGTS_H264_ADTS_RoundTrip_ZeroCRCErrors_ExactParity() async throws {
        let dir = try makeTempDir("ts-h264")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcMP4 = dir.appendingPathComponent("src_h264.mp4")
        let tsURL = dir.appendingPathComponent("out_h264.ts")
        let roundMP4 = dir.appendingPathComponent("round_h264.mp4")

        try await generateTestMP4(url: srcMP4, codec: .h264, frames: 30, allowBFrames: true)
        let orig = try await extractVideoAndAudioHashesAndCounts(srcMP4)

        let muxRep = try await MPEGTSCodec.muxFromMP4OrMOV(inputURL: srcMP4, outputURL: tsURL, overwrite: false)
        XCTAssertEqual(muxRep.videoPackets, 30)
        XCTAssertEqual(muxRep.audioPackets, orig.audioHashes.count)

        let tsInfo = try MPEGTSCodec.inspect(url: tsURL)
        XCTAssertEqual(tsInfo.crcErrors, 0)
        XCTAssertGreaterThan(tsInfo.packetCount, 0)
        XCTAssertTrue(tsInfo.streamTypesByPID.values.contains(0x1B))
        XCTAssertTrue(tsInfo.streamTypesByPID.values.contains(0x0F))

        _ = try await MPEGTSCodec.demuxToMP4(inputURL: tsURL, outputURL: roundMP4, overwrite: false)
        let round = try await extractVideoAndAudioHashesAndCounts(roundMP4)
        XCTAssertEqual(round.videoHashes, orig.videoHashes)
        XCTAssertEqual(round.audioHashes, orig.audioHashes)
        XCTAssertEqual(round.decodedVideoFrames, 30)
        XCTAssertGreaterThanOrEqual(round.decodedAudioBytes, orig.decodedAudioBytes)
    }

    func testMPEGTS_HEVC_ADTS_RoundTrip_ZeroCRCErrors_ExactParity() async throws {
        let dir = try makeTempDir("ts-hevc")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcMP4 = dir.appendingPathComponent("src_hevc.mp4")
        let tsURL = dir.appendingPathComponent("out_hevc.ts")
        let roundMP4 = dir.appendingPathComponent("round_hevc.mp4")

        try await generateTestMP4(url: srcMP4, codec: .hevc, frames: 30, allowBFrames: true)
        let orig = try await extractVideoAndAudioHashesAndCounts(srcMP4)

        _ = try await MPEGTSCodec.muxFromMP4OrMOV(inputURL: srcMP4, outputURL: tsURL, overwrite: false)
        let tsInfo = try MPEGTSCodec.inspect(url: tsURL)
        XCTAssertEqual(tsInfo.crcErrors, 0)
        XCTAssertTrue(tsInfo.streamTypesByPID.values.contains(0x24))
        XCTAssertTrue(tsInfo.streamTypesByPID.values.contains(0x0F))

        _ = try await MPEGTSCodec.demuxToMP4(inputURL: tsURL, outputURL: roundMP4, overwrite: false)
        let round = try await extractVideoAndAudioHashesAndCounts(roundMP4)
        XCTAssertEqual(round.videoHashes, orig.videoHashes)
        XCTAssertEqual(round.audioHashes, orig.audioHashes)
        XCTAssertEqual(round.decodedVideoFrames, 30)
        XCTAssertGreaterThanOrEqual(round.decodedAudioBytes, orig.decodedAudioBytes)
    }

    func testMPEGTS_OverwriteFalseAndInvalidInputRejected() async throws {
        let dir = try makeTempDir("ts-overwrite")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcMP4 = dir.appendingPathComponent("src.mp4")
        try await generateTestMP4(url: srcMP4, codec: .h264, frames: 10)
        let tsURL = dir.appendingPathComponent("existing.ts")
        let sentinel = Data("KEEP_EXISTING_TS".utf8)
        try sentinel.write(to: tsURL)

        do {
            _ = try await MPEGTSCodec.muxFromMP4OrMOV(inputURL: srcMP4, outputURL: tsURL, overwrite: false)
            XCTFail("Expected overwrite=false to throw")
        } catch {
            XCTAssertTrue(error is SafariumError)
        }
        XCTAssertEqual(try Data(contentsOf: tsURL), sentinel)
        XCTAssertThrowsError(try MPEGTSCodec.inspect(url: tsURL))
    }

    // MARK: - 3. WebP & AVIF / HEIC / HEICS Tests

    func testWebP_StaticLosslessVP8L_ByteExactImageIOReadback() throws {
        let dir = try makeTempDir("webp-static")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (cg, origRGBA) = try makeUnpremultipliedPatternImage(width: 128, height: 96, frameIndex: 0)
        let outURL = dir.appendingPathComponent("static.webp")
        let rep = try WebPAVIFEncoder.writeLosslessWebP(images: [cg], to: outURL, loopCount: 0, overwrite: false)
        XCTAssertFalse(rep.animated)
        XCTAssertEqual(rep.frameCount, 1)
        XCTAssertEqual(rep.width, 128)
        XCTAssertEqual(rep.height, 96)

        guard let src = CGImageSourceCreateWithURL(outURL as CFURL, nil),
              let dec = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            return XCTFail("ImageIO failed to decode VP8L WebP")
        }
        let decodedRGBA = try decodeStraightRGBAFromCGImage(dec)
        XCTAssertEqual(decodedRGBA, origRGBA, "VP8L static WebP must round-trip 100% byte-exact")

        // 1x1 edge case
        let (cg1x1, rgba1x1) = try makeUnpremultipliedPatternImage(width: 1, height: 1, frameIndex: 2)
        let url1x1 = dir.appendingPathComponent("tiny.webp")
        _ = try WebPAVIFEncoder.writeLosslessWebP(images: [cg1x1], to: url1x1, loopCount: 0, overwrite: false)
        let src1 = try XCTUnwrap(CGImageSourceCreateWithURL(url1x1 as CFURL, nil))
        let dec1 = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src1, 0, nil))
        XCTAssertEqual(try decodeStraightRGBAFromCGImage(dec1), rgba1x1)
    }

    func testWebP_AnimatedVP8X_ANIM_ANMF_ByteExactAllFrames() throws {
        let dir = try makeTempDir("webp-anim")
        defer { try? FileManager.default.removeItem(at: dir) }

        var cgs: [CGImage] = []
        var rgbas: [[UInt8]] = []
        for idx in 0..<3 {
            let pair = try makeUnpremultipliedPatternImage(width: 96, height: 96, frameIndex: idx)
            cgs.append(pair.cgImage)
            rgbas.append(pair.rgba)
        }
        let delays = [50, 100, 150]
        let outURL = dir.appendingPathComponent("anim.webp")
        let rep = try WebPAVIFEncoder.writeLosslessWebP(
            images: cgs,
            to: outURL,
            loopCount: 0,
            overwrite: false,
            frameDurationsMs: delays
        )
        XCTAssertTrue(rep.animated)
        XCTAssertEqual(rep.frameCount, 3)

        let src = try XCTUnwrap(CGImageSourceCreateWithURL(outURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), 3)
        for idx in 0..<3 {
            let fImg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, idx, nil))
            let props = CGImageSourceCopyPropertiesAtIndex(src, idx, nil) as? [CFString: Any]
            let webpDict = props?[kCGImagePropertyWebPDictionary] as? [CFString: Any]
            let d = (webpDict?[kCGImagePropertyWebPUnclampedDelayTime] as? Double)
                ?? (webpDict?[kCGImagePropertyWebPDelayTime] as? Double)
                ?? -1
            XCTAssertEqual(d, Double(delays[idx]) / 1000.0, accuracy: 0.002)
            XCTAssertEqual(try decodeStraightRGBAFromCGImage(fImg), rgbas[idx])
        }
    }

    func testStillImage_AllSupportedFormats_AndAVIFLosslessRejects() throws {
        let dir = try makeTempDir("still-formats")
        defer { try? FileManager.default.removeItem(at: dir) }

        let opaque = makeComplexGraphicCGImage(width: 320, height: 240, includeAlpha: false)
        let alpha = makeComplexGraphicCGImage(width: 320, height: 240, includeAlpha: true)
        let avifSupported = ((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []).contains("public.avif")

        for (fmt, img, q, ext) in [
            (ContainerFormat.webp, alpha, Optional<Double>.none, "webp"),
            (ContainerFormat.avif, opaque, Optional(0.85), "avif"),
            (ContainerFormat.avif, alpha, Optional(0.85), "alpha.avif"),
            (ContainerFormat.heic, opaque, Optional(0.90), "heic"),
            (ContainerFormat.png, alpha, Optional<Double>.none, "png"),
            (ContainerFormat.jpg, opaque, Optional(0.90), "jpg"),
        ] {
            let u = dir.appendingPathComponent("out.\(ext)")
            if fmt == .avif && !avifSupported {
                XCTAssertThrowsError(
                    try WebPAVIFEncoder.writeStillImage(cgImage: img, format: fmt, quality: q, to: u, overwrite: false)
                ) { err in
                    XCTAssertTrue(err is SafariumError)
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: u.path))
                continue
            }
            let rep = try WebPAVIFEncoder.writeStillImage(cgImage: img, format: fmt, quality: q, to: u, overwrite: false)
            XCTAssertEqual(rep.width, 320)
            XCTAssertEqual(rep.height, 240)
            XCTAssertGreaterThan(rep.bytes, 0)
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(u as CFURL, nil))
            let dec = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
            XCTAssertEqual(dec.width, 320)
            XCTAssertEqual(dec.height, 240)
            if ext == "alpha.avif" {
                XCTAssertNotEqual(dec.alphaInfo, .none)
                XCTAssertNotEqual(dec.alphaInfo, .noneSkipFirst)
                XCTAssertNotEqual(dec.alphaInfo, .noneSkipLast)
            }
        }

        // Unsupported AVIF lossless q==1.0 must throw explicit SafariumError and leave no file
        let badAVIF = dir.appendingPathComponent("lossless.avif")
        XCTAssertThrowsError(
            try WebPAVIFEncoder.writeStillImage(cgImage: opaque, format: .avif, quality: 1.0, to: badAVIF, overwrite: false)
        ) { err in
            XCTAssertTrue(err is SafariumError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: badAVIF.path))

        // overwrite=false preservation
        let keepPNG = dir.appendingPathComponent("keep.png")
        try Data("KEEP_PNG".utf8).write(to: keepPNG)
        XCTAssertThrowsError(
            try WebPAVIFEncoder.writeStillImage(cgImage: opaque, format: .png, quality: nil, to: keepPNG, overwrite: false)
        )
        XCTAssertEqual(try Data(contentsOf: keepPNG), Data("KEEP_PNG".utf8))
    }

    func testHEICS_AnimatedSequence_WriteAndReadback() throws {
        let dir = try makeTempDir("heics")
        defer { try? FileManager.default.removeItem(at: dir) }

        let frames = [
            makeComplexGraphicCGImage(width: 192, height: 144, includeAlpha: false),
            makeComplexGraphicCGImage(width: 192, height: 144, includeAlpha: false),
            makeComplexGraphicCGImage(width: 192, height: 144, includeAlpha: false),
        ]
        let outURL = dir.appendingPathComponent("ทดสอบ ภาษาไทย.heics")
        let rep = try WebPAVIFEncoder.writeHEICSSequence(images: frames, quality: 0.85, loopCount: 0, to: outURL, overwrite: false)
        XCTAssertEqual(rep.frameCount, 3)
        XCTAssertEqual(rep.width, 192)
        XCTAssertEqual(rep.height, 144)

        let src = try XCTUnwrap(CGImageSourceCreateWithURL(outURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), 3)

        // overwrite=false preserves existing sequence
        let origData = try Data(contentsOf: outURL)
        XCTAssertThrowsError(
            try WebPAVIFEncoder.writeHEICSSequence(images: frames, quality: 0.85, loopCount: 0, to: outURL, overwrite: false)
        )
        XCTAssertEqual(try Data(contentsOf: outURL), origData)

        // Mixed opaque + alpha frames must fail cleanly with SafariumError
        let mixedFrames = [
            makeComplexGraphicCGImage(width: 192, height: 144, includeAlpha: false),
            makeComplexGraphicCGImage(width: 192, height: 144, includeAlpha: true),
        ]
        let mixedURL = dir.appendingPathComponent("mixed.heics")
        XCTAssertThrowsError(
            try WebPAVIFEncoder.writeHEICSSequence(images: mixedFrames, quality: 0.85, loopCount: 0, to: mixedURL, overwrite: false)
        ) { err in
            XCTAssertTrue(err is SafariumError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: mixedURL.path))
    }

    // MARK: - 4. MediaCompatBridge Tests

    func testMediaCompatBridge_01_SupplementalDecodersAndHardwareSupport() throws {
        MediaCompatBridge.registerSupplementalDecoders()
        XCTAssertFalse(MediaCompatBridge.supportsHardwareDecode(fourCC: "mp1v"))
        XCTAssertFalse(MediaCompatBridge.supportsHardwareEncode(fourCC: "av01"))
        XCTAssertFalse(MediaCompatBridge.supportsHardwareEncode(fourCC: "vp09"))

        let bareMetalAppleSilicon = AppleMacOSBackend.current.isAppleSilicon && !AppleMacOSBackend.current.isRunningInVM
        try XCTSkipUnless(
            bareMetalAppleSilicon,
            "VideoToolbox hardware decode/encode blocks are not exposed inside macOS Cloud VMs"
        )
        XCTAssertTrue(MediaCompatBridge.supportsHardwareDecode(fourCC: "vp09"))
        XCTAssertTrue(MediaCompatBridge.supportsHardwareDecode(fourCC: "av01"))
        XCTAssertTrue(MediaCompatBridge.supportsHardwareDecode(fourCC: "hvc1"))
        XCTAssertTrue(MediaCompatBridge.supportsHardwareDecode(fourCC: "avc1"))
        XCTAssertTrue(MediaCompatBridge.supportsHardwareDecode(fourCC: "muxa"))

        XCTAssertTrue(MediaCompatBridge.supportsHardwareEncode(fourCC: "avc1"))
        XCTAssertTrue(MediaCompatBridge.supportsHardwareEncode(fourCC: "hvc1"))
        XCTAssertTrue(MediaCompatBridge.supportsHardwareEncode(fourCC: "muxa"))
        XCTAssertTrue(MediaCompatBridge.supportsHardwareEncode(fourCC: "ap4h"))
    }

    func testMediaCompatBridge_ESDSUnwrap39BAnd76B_AndWrapASC() throws {
        let rawASC = Data([0x11, 0x90])
        let rawRes = try MediaCompatBridge.unwrapWebCodecsESDS(rawASC)
        XCTAssertFalse(rawRes.wasWrapped)
        XCTAssertFalse(rawRes.wasBug302253)
        XCTAssertEqual(rawRes.audioSpecificConfig, rawASC)

        // Exact 39-byte Safari 27.2 WebCodecs ES_Descriptor
        let wrapped39 = Data([
            0x03, 0x80, 0x80, 0x80, 0x22,
            0x00, 0x00, 0x00,
            0x04, 0x80, 0x80, 0x80, 0x14,
            0x40, 0x14, 0x00, 0x18, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
            0x05, 0x80, 0x80, 0x80, 0x02,
            0x11, 0x90,
            0x06, 0x80, 0x80, 0x80, 0x01, 0x02,
        ])
        XCTAssertEqual(wrapped39.count, 39)
        let res39 = try MediaCompatBridge.unwrapWebCodecsESDS(wrapped39)
        XCTAssertTrue(res39.wasWrapped)
        XCTAssertTrue(res39.wasBug302253)
        XCTAssertEqual(res39.layersUnwrapped, 1)
        XCTAssertEqual(res39.audioSpecificConfig, rawASC)

        // 76-byte double-wrapped Bug 302253 payload (ES_Descriptor whose 0x05 contains 39B ES_Descriptor)
        let innerLen = wrapped39.count
        let decCfgPayload = Data([0x40, 0x15, 0x00, 0x18, 0x00, 0x00, 0x01, 0xF4, 0x00, 0x00, 0x01, 0xF4, 0x00, 0x05, 0x80, 0x80, 0x80, UInt8(innerLen)]) + wrapped39
        let esPayload = Data([0x00, 0x01, 0x00, 0x04, 0x80, 0x80, 0x80, UInt8(decCfgPayload.count)]) + decCfgPayload + Data([0x06, 0x80, 0x80, 0x80, 0x01, 0x02])
        let doubleWrapped76 = Data([0x03, 0x80, 0x80, 0x80, UInt8(esPayload.count)]) + esPayload
        XCTAssertEqual(doubleWrapped76.count, 76)

        let res76 = try MediaCompatBridge.unwrapWebCodecsESDS(doubleWrapped76)
        XCTAssertTrue(res76.wasWrapped)
        XCTAssertTrue(res76.wasBug302253)
        XCTAssertEqual(res76.layersUnwrapped, 2)
        XCTAssertEqual(res76.audioSpecificConfig, rawASC)

        // makeESDescriptorWrappingASC must wrap raw ASC AND avoid double-wrapping 39B input
        let builtFromRaw = try MediaCompatBridge.makeESDescriptorWrappingASC(rawASC)
        let builtFrom39 = try MediaCompatBridge.makeESDescriptorWrappingASC(wrapped39)
        XCTAssertEqual(builtFromRaw, builtFrom39)
        let reUnwrapped = try MediaCompatBridge.unwrapWebCodecsESDS(builtFromRaw)
        XCTAssertEqual(reUnwrapped.audioSpecificConfig, rawASC)
        XCTAssertEqual(reUnwrapped.layersUnwrapped, 1)
    }

    func testMediaCompatBridge_VPCCFullBox_CreatesHardwareVP9Decoder() throws {
        MediaCompatBridge.registerSupplementalDecoders()
        let vpcC = MediaCompatBridge.makeVPCCFullBox(profile: 0, level: 10, bitDepth: 8, chromaSubsampling: 1, fullRange: false)
        XCTAssertEqual(vpcC.count, 12)
        XCTAssertEqual(vpcC.prefix(4), Data([0x01, 0x00, 0x00, 0x00]))
        XCTAssertEqual(vpcC[6], 0x82)

        var desc: CMVideoFormatDescription?
        let stD = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_VP9,
            width: 1280,
            height: 720,
            extensions: [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["vpcC": vpcC]] as CFDictionary,
            formatDescriptionOut: &desc
        )
        XCTAssertEqual(stD, noErr)
        let vDesc = try XCTUnwrap(desc)

        var sess: VTDecompressionSession?
        let stS = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: vDesc,
            decoderSpecification: nil,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &sess
        )
        XCTAssertEqual(stS, noErr)
        let session = try XCTUnwrap(sess)
        var rawProp: UnsafeMutableRawPointer?
        let stProp = withUnsafeMutablePointer(to: &rawProp) { ptr in
            VTSessionCopyProperty(
                session,
                key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(ptr)
            )
        }
        if stProp == noErr, let rawProp {
            let obj = Unmanaged<AnyObject>.fromOpaque(rawProp).takeRetainedValue()
            XCTAssertEqual(obj as? Bool, true)
        }
        VTDecompressionSessionInvalidate(session)
    }

    func testMediaCompatBridge_DecodeAudioToFloat32PCM_AllFormats() throws {
        let dir = try makeTempDir("audio-decode")
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavURL = dir.appendingPathComponent("test.wav")
        let flacURL = dir.appendingPathComponent("test.flac")
        let m4aURL = dir.appendingPathComponent("test.m4a")
        let cafURL = dir.appendingPathComponent("test_opus.caf")
        let mp3URL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/PersonalAudio.framework/Resources/Enrollment_1.mp3")

        try makeSyntheticAudioFile(url: wavURL, formatID: kAudioFormatLinearPCM, fileType: kAudioFileWAVEType, sampleRate: 44_100, channels: 1)
        try makeSyntheticAudioFile(url: flacURL, formatID: kAudioFormatFLAC, fileType: kAudioFileFLACType, sampleRate: 44_100, channels: 2)
        try makeSyntheticAudioFile(url: m4aURL, formatID: kAudioFormatMPEG4AAC, fileType: kAudioFileM4AType, sampleRate: 48_000, channels: 2)
        try makeSyntheticAudioFile(url: cafURL, formatID: kAudioFormatOpus, fileType: kAudioFileCAFType, sampleRate: 48_000, channels: 2)

        for url in [wavURL, mp3URL, flacURL, m4aURL, cafURL] {
            let pcm = try MediaCompatBridge.decodeAudioToFloat32PCM(url: url, sampleRate: 48_000, channels: 2)
            XCTAssertEqual(pcm.sampleRate, 48_000)
            XCTAssertEqual(pcm.channels, 2)
            XCTAssertGreaterThan(pcm.frameCount, 10_000, "expected decoded frames for \(url.lastPathComponent)")
            XCTAssertEqual(pcm.interleavedSamples.count, pcm.frameCount * 2)
            XCTAssertGreaterThan(pcm.peak, 0.005)
            XCTAssertGreaterThan(pcm.rms, 0.0005)
        }

        // Verify streaming decode matches materialized frame count
        var streamedFrames = 0
        let info = try MediaCompatBridge.streamAudioToFloat32PCM(url: flacURL, sampleRate: 48_000, channels: 2, chunkFrames: 1024) { buf, frames in
            XCTAssertLessThanOrEqual(frames, 1024)
            XCTAssertEqual(buf.count, frames * 2)
            streamedFrames += frames
        }
        XCTAssertEqual(streamedFrames, info.frameCount)
        XCTAssertGreaterThan(streamedFrames, 20_000)

        // Verify empty & unsupported .ogg files rejected cleanly
        let emptyWAV = dir.appendingPathComponent("empty.wav")
        try Data().write(to: emptyWAV)
        XCTAssertThrowsError(try MediaCompatBridge.decodeAudioToFloat32PCM(url: emptyWAV))

        let badOGG = dir.appendingPathComponent("fake.ogg")
        try Data("OggS\0\u{02}unsupported_ogg_vorbis".utf8).write(to: badOGG)
        XCTAssertThrowsError(try MediaCompatBridge.decodeAudioToFloat32PCM(url: badOGG)) { err in
            XCTAssertTrue(err is SafariumError)
        }
    }

    func testMediaCompatBridge_SplitMP3PacketsLosslessly() throws {
        let dir = try makeTempDir("split-mp3")
        defer { try? FileManager.default.removeItem(at: dir) }

        let mp3URL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/PersonalAudio.framework/Resources/Enrollment_1.mp3")
        let outDir = dir.appendingPathComponent("chunks", isDirectory: true)
        let rep = try MediaCompatBridge.splitMP3PacketsLosslessly(
            inputURL: mp3URL,
            outputDir: outDir,
            chunkSeconds: 10.0,
            prefix: "part",
            overwrite: false
        )
        XCTAssertGreaterThanOrEqual(rep.chunks.count, 3)
        XCTAssertEqual(rep.chunkSeconds, 10.0)

        var totalChunkSamples: AVAudioFramePosition = 0
        for chunkPath in rep.chunks {
            let chunkURL = URL(fileURLWithPath: chunkPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: chunkURL.path))
            let af = try AVAudioFile(forReading: chunkURL)
            XCTAssertEqual(Int(af.processingFormat.sampleRate), 22_050)
            XCTAssertEqual(Int(af.processingFormat.channelCount), 2)
            XCTAssertGreaterThan(af.length, 0)
            totalChunkSamples += af.length
        }

        let fullAF = try AVAudioFile(forReading: mp3URL)
        XCTAssertEqual(totalChunkSamples, fullAF.length, "Lossless MP3 split must preserve exact packet/sample count")

        // overwrite=false preservation
        let firstChunkURL = URL(fileURLWithPath: rep.chunks[0])
        let before = try Data(contentsOf: firstChunkURL)
        XCTAssertThrowsError(
            try MediaCompatBridge.splitMP3PacketsLosslessly(inputURL: mp3URL, outputDir: outDir, chunkSeconds: 10.0, prefix: "part", overwrite: false)
        )
        XCTAssertEqual(try Data(contentsOf: firstChunkURL), before)
    }
}
