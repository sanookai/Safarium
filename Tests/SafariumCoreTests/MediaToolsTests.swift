import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import SafariumCore
import XCTest

final class MediaToolsTests: XCTestCase {
    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safarium-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeSineWAV(url: URL, durationSeconds: Double, frequencyHz: Double = 440, amplitude: Float = 0.25, sampleRate: Double = 48_000, channels: Int = 1) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)!
        let totalFrames = AVAudioFrameCount((durationSeconds * sampleRate).rounded())
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames)!
        buffer.frameLength = totalFrames
        for ch in 0..<channels {
            let ptr = buffer.floatChannelData![ch]
            for i in 0..<Int(totalFrames) {
                ptr[i] = amplitude * sinf(2.0 * .pi * Float(frequencyHz) * Float(i) / Float(sampleRate))
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    private func writeSyntheticMP4WithAudio(videoURL: URL, wavURL: URL, frames: Int = 30, fps: Int = 30, width: Int = 160, height: Int = 120) async throws {
        let wav = try AVAudioFile(forReading: wavURL, commonFormat: .pcmFormatFloat32, interleaved: true)
        let writer = try AVAssetWriter(url: videoURL, fileType: .mp4)
        let vSettings = AVAssetWriterSink.buildVideoSettings(width: width, height: height, fps: fps, codec: .h264, bitrate: 1_000_000, quality: nil)
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vi.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vi,
            sourcePixelBufferAttributes: AVAssetWriterSink.pixelBufferAttributes(width: width, height: height, pixelFormat: .bgra)
        )
        writer.add(vi)

        let aSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Int(wav.processingFormat.sampleRate),
            AVNumberOfChannelsKey: Int(wav.processingFormat.channelCount),
            AVEncoderBitRateKey: 96_000,
        ]
        let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings, sourceFormatHint: wav.processingFormat.formatDescription)
        ai.expectsMediaDataInRealTime = false
        writer.add(ai)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let duration = CMTime(value: Int64(frames), timescale: Int32(fps))

        for i in 0..<frames {
            while !vi.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf)!, width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: sRGB, bitmapInfo: bitmapInfo)!
            let t = CGFloat(i) / CGFloat(max(1, frames - 1))
            ctx.setFillColor(CGColor(colorSpace: sRGB, components: [0.1 + 0.8 * t, 0.2, 0.9 - 0.7 * t, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(CGColor(colorSpace: sRGB, components: [1, 1, 0, 1])!)
            ctx.fill(CGRect(x: Int(10 + 100 * t), y: 40, width: 32, height: 32))
            CVPixelBufferUnlockBaseAddress(buf, [])
            XCTAssertTrue(adaptor.append(buf, withPresentationTime: CMTime(value: Int64(i), timescale: Int32(fps))))
        }
        vi.markAsFinished()

        let buf = AVAudioPCMBuffer(pcmFormat: wav.processingFormat, frameCapacity: AVAudioFrameCount(wav.length))!
        try wav.read(into: buf)
        let bytes = Int(buf.frameLength) * Int(wav.processingFormat.channelCount) * MemoryLayout<Float>.size
        var bb: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &bb)
        CMBlockBufferReplaceDataBytes(with: buf.audioBufferList.pointee.mBuffers.mData!, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: bytes)
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: bb!, formatDescription: wav.processingFormat.formatDescription, sampleCount: Int(buf.frameLength), presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sb)
        while !ai.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(ai.append(sb!))
        ai.markAsFinished()

        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    func testAudioExtractorProducesValidWAVAndM4AWithNoClobber() async throws {
        let dir = try makeTempDir("audio-extract")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcWAV = dir.appendingPathComponent("src.wav")
        let srcMP4 = dir.appendingPathComponent("งาน ตัวอย่าง.mp4")
        try writeSineWAV(url: srcWAV, durationSeconds: 1.0, frequencyHz: 440, amplitude: 0.3, sampleRate: 48_000, channels: 1)
        try await writeSyntheticMP4WithAudio(videoURL: srcMP4, wavURL: srcWAV, frames: 30, fps: 30)

        let outWAV = dir.appendingPathComponent("extracted ภาษาไทย.wav")
        let wavReport = try await AudioExtractor.extract(from: srcMP4, to: outWAV, startSeconds: 0.1, durationSeconds: 0.5, sampleRate: 48_000, channels: 2)
        XCTAssertEqual(wavReport.format, "wav")
        XCTAssertEqual(wavReport.channels, 2)
        XCTAssertGreaterThan(wavReport.sampleCount, 20_000)
        XCTAssertGreaterThan(wavReport.rms, 0.05)

        let outAudio = try AVAudioFile(forReading: outWAV)
        XCTAssertEqual(Int(outAudio.fileFormat.sampleRate), 48_000)
        XCTAssertEqual(Int(outAudio.fileFormat.channelCount), 2)

        // Existing output must fail unless overwrite == true
        do {
            _ = try await AudioExtractor.extract(from: srcMP4, to: outWAV, overwrite: false)
            XCTFail("Expected no-clobber error")
        } catch {}

        let outM4A = dir.appendingPathComponent("extracted.m4a")
        let m4aReport = try await AudioExtractor.extract(from: srcMP4, to: outM4A, sampleRate: 48_000, channels: 1)
        XCTAssertEqual(m4aReport.format, "m4a")
        let m4aAsset = AVURLAsset(url: outM4A)
        let tracks = try await m4aAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
    }

    func testAudioMixerNormalizesToTargetLUFSAndSupportsLoopAndOffset() async throws {
        let dir = try makeTempDir("audio-mix")
        defer { try? FileManager.default.removeItem(at: dir) }

        let trackA = dir.appendingPathComponent("voice.wav")
        let trackB = dir.appendingPathComponent("bed.wav")
        try writeSineWAV(url: trackA, durationSeconds: 1.5, frequencyHz: 880, amplitude: 0.08, sampleRate: 48_000, channels: 1)
        try writeSineWAV(url: trackB, durationSeconds: 0.5, frequencyHz: 220, amplitude: 0.04, sampleRate: 48_000, channels: 2)

        let outM4A = dir.appendingPathComponent("mixed.m4a")
        let report = try await AudioMixer.mix(
            tracks: [
                AudioMixTrack(url: trackA, gainDB: 0, startSeconds: 0, loop: false),
                AudioMixTrack(url: trackB, gainDB: -6, startSeconds: 0.25, loop: true),
            ],
            to: outM4A,
            durationSeconds: 1.5,
            sampleRate: 48_000,
            channels: 2,
            normalizeLUFS: -16.0
        )
        XCTAssertEqual(report.trackCount, 2)
        XCTAssertEqual(report.outputLUFS, -16.0, accuracy: 0.6)

        let outWAV = dir.appendingPathComponent("mixed.wav")
        let wavReport = try await AudioMixer.mix(
            tracks: [AudioMixTrack(url: trackA)],
            to: outWAV,
            normalizeLUFS: -18.0
        )
        XCTAssertEqual(wavReport.outputLUFS, -18.0, accuracy: 0.5)
    }

    func testGIFWriterProducesValidAnimatedGIF() async throws {
        let dir = try makeTempDir("gif")
        defer { try? FileManager.default.removeItem(at: dir) }

        let wav = dir.appendingPathComponent("s.wav")
        let mp4 = dir.appendingPathComponent("in.mp4")
        try writeSineWAV(url: wav, durationSeconds: 0.5, sampleRate: 48_000, channels: 1)
        try await writeSyntheticMP4WithAudio(videoURL: mp4, wavURL: wav, frames: 15, fps: 30, width: 320, height: 240)

        let gifURL = dir.appendingPathComponent("out.gif")
        let report = try await GIFWriter.convert(from: mp4, to: gifURL, fps: 10, maxWidth: 160, loopCount: 0)
        XCTAssertEqual(report.width, 160)
        XCTAssertEqual(report.height, 120)
        XCTAssertEqual(report.frames, 5)
        let bytes = try Data(contentsOf: gifURL)
        XCTAssertTrue(bytes.starts(with: Data("GIF89a".utf8)))
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(gifURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(src), 5)
    }

    func testSubjectCutoutExtractsHeroMaskToPNGAndHEVCAlpha() async throws {
        try XCTSkipUnless(
            AppleMacOSBackend.current.supportsANE && SafariumMetalContext.shared != nil,
            "Vision foreground instance mask cutout requires physical Apple Silicon ANE and Metal GPU"
        )
        let dir = try makeTempDir("cutout")
        defer { try? FileManager.default.removeItem(at: dir) }

        let w = 480, h = 640
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB, bitmapInfo: bitmapInfo)!
        let sky = CGGradient(colorsSpace: sRGB, colors: [
            CGColor(colorSpace: sRGB, components: [0.10, 0.18, 0.34, 1])!,
            CGColor(colorSpace: sRGB, components: [0.24, 0.36, 0.44, 1])!,
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: CGFloat(h)), end: .zero, options: [])
        // Salient centered hero figure
        ctx.setFillColor(CGColor(colorSpace: sRGB, components: [0.95, 0.72, 0.24, 1])!)
        ctx.fill(CGRect(x: 160, y: 140, width: 160, height: 260))
        ctx.fillEllipse(in: CGRect(x: 180, y: 410, width: 120, height: 120))
        ctx.setFillColor(CGColor(colorSpace: sRGB, components: [0.08, 0.12, 0.18, 1])!)
        ctx.fillEllipse(in: CGRect(x: 205, y: 455, width: 70, height: 32))
        let heroCG = ctx.makeImage()!

        let heroPNG = dir.appendingPathComponent("hero.png")
        let dest = CGImageDestinationCreateWithURL(heroPNG as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, heroCG, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let outPNG = dir.appendingPathComponent("cutout.png")
        let imgReport = try await SubjectCutout.cutoutImage(from: heroPNG, to: outPNG)
        XCTAssertEqual(imgReport.kind, "image")
        XCTAssertGreaterThanOrEqual(imgReport.instanceCount, 1)
        XCTAssertGreaterThan(imgReport.foregroundCoveragePercent, 5.0)
        let outSrc = try XCTUnwrap(CGImageSourceCreateWithURL(outPNG as CFURL, nil))
        let outCG = try XCTUnwrap(CGImageSourceCreateImageAtIndex(outSrc, 0, nil))
        let snap = Snapshot(cgImage: outCG)
        XCTAssertLessThan(snap.pixel(x: 10, y: 10).a, 16)
        XCTAssertGreaterThan(snap.pixel(x: w / 2, y: h / 2).a, 200)

        // Blank image must fail loudly when allowEmptyMask == false
        let blankCtx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256, space: sRGB, bitmapInfo: bitmapInfo)!
        blankCtx.setFillColor(CGColor(colorSpace: sRGB, components: [0.5, 0.5, 0.5, 1])!)
        blankCtx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let blankPNG = dir.appendingPathComponent("blank.png")
        let bDest = CGImageDestinationCreateWithURL(blankPNG as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(bDest, blankCtx.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(bDest))
        do {
            _ = try await SubjectCutout.cutoutImage(from: blankPNG, to: dir.appendingPathComponent("blank-out.png"), allowEmptyMask: false)
            XCTFail("Expected empty mask rejection")
        } catch {}

        // Also test short cutoutVideo -> HEVC-alpha .mov
        let sink = try AVAssetWriterSink(url: dir.appendingPathComponent("hero.mp4"), width: w, height: h, fps: 15, codec: .h264, bitrate: 2_000_000)
        for _ in 0..<4 { try await sink.append(Snapshot(cgImage: heroCG)) }
        try await sink.finish()
        let outMOV = dir.appendingPathComponent("cutout.mov")
        let vidReport = try await SubjectCutout.cutoutVideo(from: dir.appendingPathComponent("hero.mp4"), to: outMOV, codec: .hevcAlpha)
        XCTAssertEqual(vidReport.kind, "video")
        XCTAssertEqual(vidReport.frames, 4)
        let asset = AVURLAsset(url: outMOV)
        let firstTrack = try await asset.loadTracks(withMediaType: .video).first
        let vTrack = try XCTUnwrap(firstTrack)
        let chars = try await vTrack.load(.mediaCharacteristics)
        XCTAssertTrue(chars.contains(.containsAlphaChannel))
    }

    func testGIFWriterRespectsRotatedPreferredTransform() async throws {
        let dir = try makeTempDir("gif-rot")
        defer { try? FileManager.default.removeItem(at: dir) }

        let rotMP4 = dir.appendingPathComponent("rotated.mp4")
        let writer = try AVAssetWriter(url: rotMP4, fileType: .mp4)
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: AVAssetWriterSink.buildVideoSettings(
            width: 160, height: 120, fps: 10, codec: .h264, bitrate: 1_200_000, quality: nil
        ))
        vi.transform = CGAffineTransform(rotationAngle: .pi / 2)
        vi.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vi,
            sourcePixelBufferAttributes: AVAssetWriterSink.pixelBufferAttributes(width: 160, height: 120, pixelFormat: .bgra)
        )
        writer.add(vi)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        for i in 0..<4 {
            while !vi.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf)!, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: sRGB, bitmapInfo: info)!
            ctx.setFillColor(CGColor(colorSpace: sRGB, components: [0, 0, 1, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 60))
            ctx.setFillColor(CGColor(colorSpace: sRGB, components: [1, 0, 0, 1])!)
            ctx.fill(CGRect(x: 0, y: 60, width: 160, height: 60))
            CVPixelBufferUnlockBaseAddress(buf, [])
            XCTAssertTrue(adaptor.append(buf, withPresentationTime: CMTime(value: Int64(i), timescale: 10)))
        }
        vi.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 4, timescale: 10))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)

        let gifURL = dir.appendingPathComponent("rot.gif")
        let report = try await GIFWriter.convert(from: rotMP4, to: gifURL, fps: 10)
        XCTAssertEqual(report.width, 120)
        XCTAssertEqual(report.height, 160)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(gifURL as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        let snap = Snapshot(cgImage: cg)
        XCTAssertGreaterThan(snap.pixel(x: 90, y: 80).r, 200)
        XCTAssertLessThan(snap.pixel(x: 90, y: 80).b, 40)
        XCTAssertGreaterThan(snap.pixel(x: 30, y: 80).b, 200)
        XCTAssertLessThan(snap.pixel(x: 30, y: 80).r, 40)
    }

    func testAudioMixerDefaultDurationUsesNonLoopedTracksWhenPresent() async throws {
        let dir = try makeTempDir("mix-dur")
        defer { try? FileManager.default.removeItem(at: dir) }

        let voice = dir.appendingPathComponent("voice.wav")
        let bed = dir.appendingPathComponent("bed.wav")
        try writeSineWAV(url: voice, durationSeconds: 0.4, frequencyHz: 440, amplitude: 0.2)
        try writeSineWAV(url: bed, durationSeconds: 1.2, frequencyHz: 220, amplitude: 0.1)

        let outWAV = dir.appendingPathComponent("out.wav")
        let report = try await AudioMixer.mix(
            tracks: [
                AudioMixTrack(url: voice, gainDB: 0, startSeconds: 0, loop: false),
                AudioMixTrack(url: bed, gainDB: -6, startSeconds: 0, loop: true),
            ],
            to: outWAV
        )
        XCTAssertEqual(report.durationSeconds, 0.4, accuracy: 0.02)
    }
}
