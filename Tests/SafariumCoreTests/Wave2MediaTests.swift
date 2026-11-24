import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import SafariumCore
import XCTest

final class Wave2MediaTests: XCTestCase {
    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safarium-w2media-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeWAV(
        url: URL,
        durationSeconds: Double,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        generator: (_ frame: Int, _ ch: Int) -> Float
    ) throws {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)!
        let totalFrames = AVAudioFrameCount((durationSeconds * sampleRate).rounded())
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: totalFrames)!
        buf.frameLength = totalFrames
        for ch in 0..<channels {
            let ptr = buf.floatChannelData![ch]
            for i in 0..<Int(totalFrames) {
                ptr[i] = max(-1.0, min(1.0, generator(i, ch)))
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
        try file.write(from: buf)
    }

    private func writeClosedGOPVideo(
        url: URL,
        frames: Int,
        fps: Int = 30,
        width: Int = 160,
        height: Int = 120,
        drawFrame: (CGContext, Int, Int, Int) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let sink = try AVAssetWriterSink(
            url: url, width: width, height: height, fps: fps,
            codec: .h264, bitrate: 1_500_000, quality: nil,
            pixelFormat: .nv12Left, profile: .lowRamClosedGOP
        )
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        for f in 0..<frames {
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: sRGB, bitmapInfo: info)!
            drawFrame(ctx, f, width, height)
            try await sink.append(Snapshot(cgImage: ctx.makeImage()!))
        }
        try await sink.finish()
    }

    func testOfflinePeakLimiterPreventsTruePeakClipping() throws {
        let fs = 48_000.0
        let ch = 2
        let frames = 48_000
        // +6 dBFS hot 1 kHz sine + impulse peak -> OfflinePeakLimiter must clamp below -0.95 dBTP and keep aligned duration
        var interleaved = [Float](repeating: 0, count: frames * ch)
        for i in 0..<frames {
            let s = Float(2.0 * sin(2.0 * .pi * 997.0 * Double(i) / fs))
            interleaved[i * 2] = s
            interleaved[i * 2 + 1] = s
        }
        let limiter = try OfflinePeakLimiter(sampleRate: fs, channels: ch, ceilingDBTP: -1.05)
        try limiter.processBuffer(&interleaved)
        XCTAssertEqual(interleaved.count, frames * ch)

        let meter = try LoudnessMeter(sampleRate: fs, channels: ch)
        interleaved.withUnsafeBufferPointer { meter.processInterleaved($0) }
        XCTAssertLessThanOrEqual(meter.truePeakDBTP, -0.95, "true peak must remain capped near -1.05 dBTP ceiling")
        XCTAssertGreaterThan(meter.truePeakLinear, 0.2)

        // Verify SidechainDucker lowers BGM RMS during active voice window [0.5, 1.0) vs silent voice [0.0, 0.5)
        let ducker = try SidechainDucker(sampleRate: fs, channels: ch)
        var voice = [Float](repeating: 0, count: frames * ch)
        var music = [Float](repeating: 0, count: frames * ch)
        for i in 0..<frames {
            let m = Float(0.2 * sin(2.0 * .pi * 220.0 * Double(i) / fs))
            music[i * 2] = m
            music[i * 2 + 1] = m
            if i >= 24_000 {
                let v = Float(0.25 * sin(2.0 * .pi * 700.0 * Double(i) / fs))
                voice[i * 2] = v
                voice[i * 2 + 1] = v
            }
        }
        voice.withUnsafeBufferPointer { vPtr in
            music.withUnsafeMutableBufferPointer { mPtr in
                ducker.apply(voiceInterleaved: vPtr.baseAddress!, targetInterleaved: mPtr.baseAddress!, frameCount: frames)
            }
        }
        let quietWindowMeanSq = music[2_000..<(20_000 * ch)].reduce(0.0) { $0 + Double($1 * $1) } / Double(20_000 * ch - 2_000)
        let duckedWindowMeanSq = music[(32_000 * ch)..<(47_000 * ch)].reduce(0.0) { $0 + Double($1 * $1) } / Double((47_000 - 32_000) * ch)
        XCTAssertLessThan(sqrt(duckedWindowMeanSq), sqrt(quietWindowMeanSq) * 0.5, "ducked BGM should drop >= 6 dB under voice")
    }

    func testLosslessSoundtrackMuxPreservesVideoPacketsAndAddsAudioAndTx3g() async throws {
        let dir = try makeTempDir("mux")
        defer { try? FileManager.default.removeItem(at: dir) }

        let vidURL = dir.appendingPathComponent("video.mp4")
        let wavURL = dir.appendingPathComponent("audio.wav")
        let srtURL = dir.appendingPathComponent("subs.srt")
        let outURL = dir.appendingPathComponent("muxed.mp4")

        try await writeClosedGOPVideo(url: vidURL, frames: 30, fps: 30) { ctx, f, w, h in
            ctx.setFillColor(red: Double(f % 10) / 10.0, green: 0.4, blue: 0.7, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        try writeWAV(url: wavURL, durationSeconds: 2.0, sampleRate: 48_000, channels: 2) { i, _ in
            Float(0.25 * sin(2.0 * .pi * 440.0 * Double(i) / 48_000.0))
        }
        let srtText = """
        1
        00:00:00,100 --> 00:00:00,800
        Cześć สวัสดีปิ๊ก
        """
        try srtText.write(to: srtURL, atomically: true, encoding: .utf8)

        let report = try await LosslessSoundtrackMux.mux(
            videoURL: vidURL,
            wavURL: wavURL,
            audioStartSeconds: 0.5,
            subtitlesURL: srtURL,
            subtitleLang: "pol",
            outputURL: outURL,
            overwrite: false
        )
        XCTAssertTrue(report.videoPacketsExactMatch)
        XCTAssertEqual(report.videoDiffCount, 0)
        XCTAssertEqual(report.videoPacketCount, 30)
        XCTAssertTrue(report.hasAudioTrack)
        XCTAssertTrue(report.hasSubtitleTrack)

        let probe = try await PacketProbe.inspect(url: outURL, includeAudioPackets: false)
        XCTAssertEqual(probe.tracks.filter { $0.mediaType == "vide" }.count, 1)
        XCTAssertEqual(probe.tracks.filter { $0.mediaType == "soun" }.count, 1)
        XCTAssertEqual(probe.tracks.filter { $0.mediaType == "sbtl" }.count, 1)
    }

    func testClosedGOPStitcherConcatenatesSegmentsLosslessly() async throws {
        let dir = try makeTempDir("splice")
        defer { try? FileManager.default.removeItem(at: dir) }

        let seg1 = dir.appendingPathComponent("seg1.mp4")
        let seg2 = dir.appendingPathComponent("seg2.mp4")
        let wavURL = dir.appendingPathComponent("bed.wav")
        let outURL = dir.appendingPathComponent("stitched.mp4")

        try await writeClosedGOPVideo(url: seg1, frames: 15, fps: 30) { ctx, f, w, h in
            ctx.setFillColor(red: 0.8, green: Double(f) / 20.0, blue: 0.2, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        try await writeClosedGOPVideo(url: seg2, frames: 15, fps: 30) { ctx, f, w, h in
            ctx.setFillColor(red: 0.2, green: 0.5, blue: Double(f + 5) / 20.0, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        try writeWAV(url: wavURL, durationSeconds: 1.5, sampleRate: 48_000, channels: 1) { i, _ in
            Float(0.2 * sin(2.0 * .pi * 550.0 * Double(i) / 48_000.0))
        }

        let cloneTarget = dir.appendingPathComponent("seg1_clone.mp4")
        _ = try LosslessSoundtrackMux.cloneOrCopy(from: seg1, to: cloneTarget)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cloneTarget.path))

        let report = try await ClosedGOPStitcher.splice(
            segments: [cloneTarget, seg2],
            wavURL: wavURL,
            outputURL: outURL
        )
        XCTAssertTrue(report.stsdUniform)
        XCTAssertEqual(report.segmentCount, 2)
        XCTAssertEqual(report.outputVideoPacketCount, 30)
        XCTAssertEqual(report.durationSeconds, 1.0, accuracy: 0.08)

        let p1 = try await PacketProbe.inspect(url: seg1)
        let pOut = try await PacketProbe.inspect(url: outURL)
        let seg1V = try XCTUnwrap(p1.tracks.first(where: { $0.mediaType == "vide" }))
        let outV = try XCTUnwrap(pOut.tracks.first(where: { $0.mediaType == "vide" }))
        XCTAssertEqual(outV.packetCount, 30)
        XCTAssertEqual(outV.packets.prefix(15).map(\.sha256), seg1V.packets.map(\.sha256))
    }

    func testNativeProbeInspectsTracksColorAndBitExactPacketHash() async throws {
        let dir = try makeTempDir("probe")
        defer { try? FileManager.default.removeItem(at: dir) }

        let vidURL = dir.appendingPathComponent("sample.mp4")
        let wavURL = dir.appendingPathComponent("sample.wav")
        let muxURL = dir.appendingPathComponent("sample-av.mp4")

        try await writeClosedGOPVideo(url: vidURL, frames: 12, fps: 24) { ctx, _, w, h in
            ctx.setFillColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        try writeWAV(url: wavURL, durationSeconds: 1.0, sampleRate: 48_000, channels: 2) { i, _ in
            Float(0.15 * sin(2.0 * .pi * 440.0 * Double(i) / 48_000.0))
        }
        _ = try await LosslessSoundtrackMux.mux(videoURL: vidURL, wavURL: wavURL, outputURL: muxURL)

        let report = try await PacketProbe.inspect(url: muxURL, includeAudioPackets: true)
        XCTAssertTrue(report.playable)
        XCTAssertEqual(report.durationSeconds, 0.5, accuracy: 0.05)

        let vTrack = try XCTUnwrap(report.tracks.first(where: { $0.mediaType == "vide" }))
        XCTAssertEqual(vTrack.packetCount, 12)
        XCTAssertEqual(vTrack.formats.first?.codec, "avc1")
        XCTAssertEqual(vTrack.formats.first?.width, 160)
        XCTAssertEqual(vTrack.formats.first?.height, 120)
        XCTAssertFalse(vTrack.packets.isEmpty)
        XCTAssertEqual(vTrack.packets.first?.sha256.count, 64)
        XCTAssertEqual(vTrack.formats.first?.primaries, kCVImageBufferColorPrimaries_ITU_R_709_2 as String)

        let aTrack = try XCTUnwrap(report.tracks.first(where: { $0.mediaType == "soun" }))
        XCTAssertEqual(aTrack.formats.first?.channels, 2)
        XCTAssertEqual(aTrack.formats.first?.sampleRate, 48_000)
        XCTAssertGreaterThan(aTrack.packetCount, 0)
    }

    func testNativeQAAnalyzerDetectsBlackFreezeSilenceAndWritesContactSheet() async throws {
        let dir = try makeTempDir("qa")
        defer { try? FileManager.default.removeItem(at: dir) }

        let vidOnly = dir.appendingPathComponent("raw.mp4")
        let wavURL = dir.appendingPathComponent("track.wav")
        let faultURL = dir.appendingPathComponent("faults.mp4")
        let sheetURL = dir.appendingPathComponent("sheet.jpg")

        // 45 frames @ 30fps (1.5s): [0..14] dynamic green, [15..24] black (10 frames), [25..44] frozen blue (20 frames)
        try await writeClosedGOPVideo(url: vidOnly, frames: 45, fps: 30) { ctx, f, w, h in
            if f < 15 {
                ctx.setFillColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1.0)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.setFillColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1.0)
                ctx.fill(CGRect(x: f * 8, y: 20, width: 30, height: 60))
            } else if f < 25 {
                ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1.0)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            } else {
                ctx.setFillColor(red: 0.1, green: 0.3, blue: 0.85, alpha: 1.0)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        // [0..1.0s) tone, [1.0..1.5s] silence (>= 0.2s)
        try writeWAV(url: wavURL, durationSeconds: 1.6, sampleRate: 48_000, channels: 1) { i, _ in
            i < 48_000 ? Float(0.25 * sin(2.0 * .pi * 440.0 * Double(i) / 48_000.0)) : 0
        }
        _ = try await LosslessSoundtrackMux.mux(videoURL: vidOnly, wavURL: wavURL, outputURL: faultURL)

        let qa = try await NativeQAAnalyzer.analyze(url: faultURL, contactSheetURL: sheetURL)
        XCTAssertEqual(qa.totalVideoFrames, 45)
        XCTAssertTrue(qa.hasAudioTrack)
        XCTAssertFalse(qa.blackEvents.isEmpty, "should detect black run [15..24]")
        XCTAssertFalse(qa.freezeEvents.isEmpty, "should detect frozen blue run [25..44]")
        XCTAssertFalse(qa.silenceEvents.isEmpty, "should detect trailing silence [1.0..1.5s]")
        XCTAssertFalse(qa.clean)
        XCTAssertNotNil(qa.audioLoudnessLUFS)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sheetURL.path))
        XCTAssertGreaterThan(qa.contactSheetBytes ?? 0, 100)
    }

    func testLoudnessRangeLUDetectsFlatVsDynamicAudio() throws {
        let fs = 48_000.0
        // 1. Flat 8-second 1 kHz sine -> LRA < 0.5 LU
        let flatMeter = try LoudnessMeter(sampleRate: fs, channels: 1)
        let flatFrames = Int(8.0 * fs)
        let flatSamples = (0..<flatFrames).map { Float(0.25 * sin(2.0 * .pi * 1000.0 * Double($0) / fs)) }
        flatSamples.withUnsafeBufferPointer { flatMeter.processMonoBlock($0) }
        XCTAssertLessThan(flatMeter.loudnessRangeLU, 0.5, "steady sine must have negligible loudness range")

        // 2. Dynamic 12-second sequence: 4s quiet (-30 dB), 4s loud (-6 dB), 4s quiet (-30 dB) -> LRA > 6.0 LU
        let dynMeter = try LoudnessMeter(sampleRate: fs, channels: 1)
        let dynFrames = Int(12.0 * fs)
        let dynSamples = (0..<dynFrames).map { i -> Float in
            let sec = Double(i) / fs
            let amp: Double = (sec >= 4.0 && sec < 8.0) ? 0.5 : 0.03
            return Float(amp * sin(2.0 * .pi * 1000.0 * sec))
        }
        dynSamples.withUnsafeBufferPointer { dynMeter.processMonoBlock($0) }
        XCTAssertGreaterThan(dynMeter.loudnessRangeLU, 6.0, "4s quiet/loud swings must yield LRA > 6 LU")
    }

    func testAudioMixerSupportsCustomPeakCeilingAnd24BitWAV() async throws {
        let dir = try makeTempDir("mix24")
        defer { try? FileManager.default.removeItem(at: dir) }

        let inWAV = dir.appendingPathComponent("in.wav")
        let outWAV = dir.appendingPathComponent("out24.wav")
        try writeWAV(url: inWAV, durationSeconds: 2.0, sampleRate: 48_000, channels: 1) { i, _ in
            Float(0.6 * sin(2.0 * .pi * 997.0 * Double(i) / 48_000.0))
        }

        let report = try await AudioMixer.mix(
            tracks: [AudioMixTrack(url: inWAV)],
            to: outWAV,
            sampleRate: 48_000,
            channels: 1,
            normalizeLUFS: -14.0,
            peakCeilingDBTP: -1.5,
            wavBitDepth: 24,
            overwrite: true
        )
        XCTAssertLessThanOrEqual(report.truePeakDBTP, -1.45, "true peak must respect -1.5 dBTP ceiling")
        XCTAssertEqual(report.outputLUFS, -14.0, accuracy: 0.4)

        let outFile = try AVAudioFile(forReading: outWAV)
        XCTAssertEqual(outFile.length, 96_000)
        XCTAssertEqual(outFile.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 24)
    }

    func testMuxSetsAudioLangAndClampsOneFrameWAVShortfallAtStartZero() async throws {
        let dir = try makeTempDir("muxpol")
        defer { try? FileManager.default.removeItem(at: dir) }

        let vidURL = dir.appendingPathComponent("v.mp4")
        let wavURL = dir.appendingPathComponent("a.wav")
        let srtURL = dir.appendingPathComponent("s.srt")
        let outURL = dir.appendingPathComponent("out.mp4")

        // 1.000s video (30 frames @ 30fps) paired with 0.970s WAV (30 ms shorter -> ~1 frame rounding)
        try await writeClosedGOPVideo(url: vidURL, frames: 30, fps: 30) { ctx, f, w, h in
            ctx.setFillColor(red: 0.2, green: Double(f % 5) * 0.15, blue: 0.7, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        try writeWAV(url: wavURL, durationSeconds: 0.97, sampleRate: 48_000, channels: 1) { i, _ in
            Float(0.2 * sin(2.0 * .pi * 440.0 * Double(i) / 48_000.0))
        }
        try "1\n00:00:00,100 --> 00:00:00,700\nPolski test\n".write(to: srtURL, atomically: true, encoding: .utf8)

        let report = try await LosslessSoundtrackMux.mux(
            videoURL: vidURL,
            wavURL: wavURL,
            audioStartSeconds: 0.0,
            audioLang: "pol",
            subtitlesURL: srtURL,
            subtitleLang: "pol",
            outputURL: outURL
        )
        XCTAssertTrue(report.videoPacketsExactMatch)
        XCTAssertTrue(report.hasAudioTrack)
        XCTAssertTrue(report.hasSubtitleTrack)

        let probe = try await PacketProbe.inspect(url: outURL, includeAudioPackets: false)
        let aTrack = try XCTUnwrap(probe.tracks.first(where: { $0.mediaType == "soun" }))
        let sTrack = try XCTUnwrap(probe.tracks.first(where: { $0.mediaType == "sbtl" }))
        XCTAssertEqual(aTrack.languageCode, "pol")
        XCTAssertEqual(sTrack.languageCode, "pol")
    }

    func testNativeQAAnalyzerHandlesAudioOnlyInputWithCustomSilenceThreshold() async throws {
        let dir = try makeTempDir("qa-audio")
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavURL = dir.appendingPathComponent("voice.wav")
        // 4.0s @ 48 kHz: [0..1.5s) speech-like tone, [1.5..2.2s) quiet room tone (~-56 dB), [2.2..4.0s) tone
        try writeWAV(url: wavURL, durationSeconds: 4.0, sampleRate: 48_000, channels: 1) { i, _ in
            let t = Double(i) / 48_000.0
            let amp: Double = (t >= 1.5 && t < 2.2) ? 0.0015 : 0.25
            return Float(amp * sin(2.0 * .pi * 330.0 * t))
        }

        let qa = try await NativeQAAnalyzer.analyze(url: wavURL, silenceThresholdDB: -40.0)
        XCTAssertEqual(qa.totalVideoFrames, 0)
        XCTAssertTrue(qa.hasAudioTrack)
        XCTAssertNotNil(qa.audioLoudnessLUFS)
        XCTAssertNotNil(qa.audioLoudnessRangeLU)
        XCTAssertFalse(qa.silenceEvents.isEmpty, "0.7s @ -56 dB pause must trigger under -40 dB threshold")
    }

    func testFrameExtractorTimestampsEveryAndGrayRaw() async throws {
        let dir = try makeTempDir("extract")
        defer { try? FileManager.default.removeItem(at: dir) }

        let vidURL = dir.appendingPathComponent("clip.mp4")
        try await writeClosedGOPVideo(url: vidURL, frames: 30, fps: 30, width: 108, height: 192) { ctx, f, w, h in
            ctx.setFillColor(red: Double(f) / 30.0, green: 0.4, blue: 1.0 - Double(f) / 30.0, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }

        let tsDir = dir.appendingPathComponent("ts")
        let tsReport = try await FrameExtractor.extractAtTimestamps(
            url: vidURL, times: [0.1, 0.7], outDir: tsDir, width: 360, height: 640, format: "jpg"
        )
        XCTAssertEqual(tsReport.frameCount, 2)
        XCTAssertEqual(tsReport.width, 360)
        XCTAssertEqual(tsReport.height, 640)
        XCTAssertEqual(tsReport.files, ["f0001.jpg", "f0002.jpg"])
        for name in tsReport.files {
            XCTAssertTrue(FileManager.default.fileExists(atPath: tsDir.appendingPathComponent(name).path))
        }

        let evDir = dir.appendingPathComponent("every")
        let evReport = try await FrameExtractor.extractEvery(
            url: vidURL, everySeconds: 0.4, outDir: evDir, width: 216, height: nil, format: "jpg"
        )
        XCTAssertGreaterThanOrEqual(evReport.frameCount, 2)
        XCTAssertEqual(evReport.width, 216)
        XCTAssertEqual(evReport.height, 384)

        let rawURL = dir.appendingPathComponent("gray.raw")
        let grayReport = try await FrameExtractor.extractGrayRaw(
            url: vidURL, fps: 4.0, width: 90, height: 160, outputURL: rawURL
        )
        XCTAssertGreaterThanOrEqual(grayReport.frameCount, 4)
        XCTAssertEqual(grayReport.bytesWritten, grayReport.frameCount * 90 * 160)
        let rawSize = try FileManager.default.attributesOfItem(atPath: rawURL.path)[.size] as? Int
        XCTAssertEqual(rawSize, grayReport.bytesWritten)
    }

    func testSidechainDuckerSingleTrailingFrameDoesNotProduceNaN() throws {
        let fs = 48_000.0
        let ch = 2
        // hopFrames at 48kHz / 10ms = 480; 481 frames leaves a 1-frame final slice (take == 1).
        let frames = 481
        let ducker = try SidechainDucker(sampleRate: fs, channels: ch)
        let voice = [Float](repeating: 0.2, count: frames * ch)
        var target = [Float](repeating: 0.5, count: frames * ch)
        voice.withUnsafeBufferPointer { vPtr in
            target.withUnsafeMutableBufferPointer { tPtr in
                ducker.apply(voiceInterleaved: vPtr.baseAddress!, targetInterleaved: tPtr.baseAddress!, frameCount: frames)
            }
        }
        XCTAssertTrue(target.allSatisfy { !$0.isNaN && !$0.isInfinite }, "1-frame trailing ducking slice must stay finite")
    }
}
