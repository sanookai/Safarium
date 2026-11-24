import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import SafariumContainers
@testable import SafariumCore
@testable import SafariumForgeCore
import XCTest

final class Wave6Phase1BugfixTests: XCTestCase {
    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safarium-w6-bugfix-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func readFloatPCM(_ url: URL, sampleRate: Double = 48_000, channels: Int = 2) throws -> (samples: [Float], durationSeconds: Double) {
        let file = try AVAudioFile(forReading: url)
        let procFmt = file.processingFormat
        let actualChannels = Int(procFmt.channelCount)
        let cap = max(1, AVAudioFrameCount(file.length))
        let buf = AVAudioPCMBuffer(pcmFormat: procFmt, frameCapacity: cap)!
        try file.read(into: buf)
        let frames = Int(buf.frameLength)
        var out = [Float](repeating: 0, count: frames * channels)
        if let chData = buf.floatChannelData {
            for f in 0..<frames {
                for c in 0..<channels {
                    let srcC = min(c, max(0, actualChannels - 1))
                    out[f * channels + c] = chData[srcC][f]
                }
            }
        }
        let dur = Double(frames) / procFmt.sampleRate
        return (out, dur)
    }

    private func rmsInterleaved(_ samples: [Float], channels: Int, startFrame: Int, endFrame: Int) -> Double {
        let lo = max(0, min(samples.count / channels, startFrame))
        let hi = max(lo, min(samples.count / channels, endFrame))
        if hi <= lo { return 0.0 }
        var sumSq = 0.0
        for f in lo..<hi {
            for c in 0..<channels {
                let v = Double(samples[f * channels + c])
                sumSq += v * v
            }
        }
        return sqrt(sumSq / Double((hi - lo) * channels))
    }

    private func writeSyntheticColorMP4(url: URL, width: Int = 320, height: Int = 180, fps: Int = 24, frames: Int = 12) async throws {
        let sink = try AVAssetWriterSink(
            url: url,
            width: width,
            height: height,
            fps: fps,
            codec: .h264,
            bitrate: 1_500_000,
            pixelFormat: .bgra
        )
        for idx in 0..<frames {
            try await sink.append(presentationTime: CMTime(value: Int64(idx), timescale: Int32(fps))) { pb in
                CVPixelBufferLockBaseAddress(pb, [])
                defer { CVPixelBufferUnlockBaseAddress(pb, []) }
                let ctx = CGContext(
                    data: CVPixelBufferGetBaseAddress(pb)!,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                    space: Snapshot.colorSpace,
                    bitmapInfo: Snapshot.bitmapInfo
                )!
                ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.25, blue: 0.15, alpha: 1.0))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.85, blue: 0.3, alpha: 1.0))
                let barX = (idx * 18) % max(40, width - 40)
                ctx.fill(CGRect(x: barX, y: 30, width: 40, height: height - 60))
            }
        }
        try await sink.finish()
    }

    /// Wraps a real Apple-encoded `.flac` file inside a valid Ogg FLAC `.oga` container.
    private func synthesizeValidOggFLAC(into ogaURL: URL, durationSeconds: Double = 0.25, sampleRate: Double = 48_000) throws {
        let tmpDir = ogaURL.deletingLastPathComponent()
        let rawFlacURL = tmpDir.appendingPathComponent("src-\(UUID().uuidString).flac")
        defer { try? FileManager.default.removeItem(at: rawFlacURL) }

        let totalFrames = Int((durationSeconds * sampleRate).rounded())
        let pcmFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 2, interleaved: false)!
        let pcmBuf = AVAudioPCMBuffer(pcmFormat: pcmFmt, frameCapacity: AVAudioFrameCount(totalFrames))!
        pcmBuf.frameLength = AVAudioFrameCount(totalFrames)
        for ch in 0..<2 {
            let p = pcmBuf.floatChannelData![ch]
            for i in 0..<totalFrames {
                p[i] = 0.25 * sinf(2.0 * .pi * 440.0 * Float(i) / Float(sampleRate))
            }
        }
        let flacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatFLAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
        ]
        do {
            let wf = try AVAudioFile(forWriting: rawFlacURL, settings: flacSettings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try wf.write(from: pcmBuf)
        }

        let flac = [UInt8](try Data(contentsOf: rawFlacURL))
        XCTAssertEqual(Array(flac.prefix(4)), Array("fLaC".utf8))
        var cursor = 4
        var isLast = (flac[cursor] & 0x80) != 0
        let siLen = (Int(flac[cursor + 1]) << 16) | (Int(flac[cursor + 2]) << 8) | Int(flac[cursor + 3])
        XCTAssertEqual(siLen, 34)
        var streamInfoBlock = Array(flac[cursor..<(cursor + 4 + siLen)])
        streamInfoBlock[0] &= 0x7F
        cursor += 4 + siLen

        var extraMeta: [Data] = []
        while !isLast && cursor + 4 <= flac.count {
            isLast = (flac[cursor] & 0x80) != 0
            let len = (Int(flac[cursor + 1]) << 16) | (Int(flac[cursor + 2]) << 8) | Int(flac[cursor + 3])
            var blk = Array(flac[cursor..<(cursor + 4 + len)])
            blk[0] &= 0x7F
            extraMeta.append(Data(blk))
            cursor += 4 + len
        }
        let rawAudioFrames = Data(flac[cursor...])
        XCTAssertGreaterThanOrEqual(rawAudioFrames.count, 4)
        XCTAssertEqual(rawAudioFrames[rawAudioFrames.startIndex], 0xFF)
        XCTAssertEqual(rawAudioFrames[rawAudioFrames.startIndex + 1] & 0xFE, 0xF8)

        let metaCount = UInt16(extraMeta.count)
        var firstPacket: [UInt8] = [0x7F] + Array("FLAC".utf8) + [1, 0, UInt8(metaCount >> 8), UInt8(metaCount & 0xFF)]
        firstPacket += Array("fLaC".utf8)
        firstPacket += streamInfoBlock

        var writer = OggPageWriter(serialNumber: 0x5AFA10)
        try writer.append(packet: Data(firstPacket), granulePosition: 0, flush: true)
        for (i, m) in extraMeta.enumerated() {
            try writer.append(packet: m, granulePosition: 0, flush: i == extraMeta.count - 1)
        }
        try writer.append(packet: rawAudioFrames, granulePosition: Int64(totalFrames), endOfStream: true)
        try writer.serializedStream().write(to: ogaURL)
    }

    func testProceduralSynthWhiteNoiseDeterministicAndDistinctFromPinkNoise() throws {
        let specWhite = ForgeAudioSynthSpec(
            waveform: "whiteNoise",
            amplitude: 0.4,
            durationSeconds: 0.25,
            sampleRate: 48_000,
            channels: 2
        )
        let synthA = try ForgeProceduralSynth(spec: specWhite)
        let synthB = try ForgeProceduralSynth(spec: specWhite)
        var bufA = [Float](repeating: 0, count: 4800 * 2)
        var bufB = [Float](repeating: 0, count: 4800 * 2)

        let countA = bufA.withUnsafeMutableBufferPointer { synthA.renderNextBlock(into: $0.baseAddress!, maxFrames: 4096) }
        let countB = bufB.withUnsafeMutableBufferPointer { synthB.renderNextBlock(into: $0.baseAddress!, maxFrames: 4096) }
        XCTAssertEqual(countA, 4096)
        XCTAssertEqual(countB, 4096)
        XCTAssertEqual(bufA, bufB, "whiteNoise synth with fixed seed must be 100% deterministic")

        let usedA = Array(bufA.prefix(countA * 2))
        var maxMag: Float = 0
        for s in usedA {
            XCTAssertTrue(s.isFinite)
            maxMag = max(maxMag, abs(s))
        }
        XCTAssertLessThanOrEqual(maxMag, 0.4001)
        let rmsW = rmsInterleaved(usedA, channels: 2, startFrame: 0, endFrame: countA)
        XCTAssertGreaterThan(rmsW, 0.1, "whiteNoise amplitude 0.4 should yield RMS > 0.1 (got \(rmsW))")

        let pinkSpec = ForgeAudioSynthSpec(waveform: "pinkNoise", amplitude: 0.4, durationSeconds: 0.25, sampleRate: 48_000, channels: 2)
        let synthPink = try ForgeProceduralSynth(spec: pinkSpec)
        var bufPink = [Float](repeating: 0, count: 4800 * 2)
        _ = bufPink.withUnsafeMutableBufferPointer { synthPink.renderNextBlock(into: $0.baseAddress!, maxFrames: 4096) }
        XCTAssertNotEqual(Array(bufPink.prefix(countA * 2)), usedA, "whiteNoise and pinkNoise must generate distinct signals")
    }

    func testForgeAudioMixStartSecondsFadeAndPadTrim() async throws {
        let dir = try makeTempDir("audio-ops")
        defer { try? FileManager.default.removeItem(at: dir) }

        let vidURL = dir.appendingPathComponent("src.mp4")
        try await writeSyntheticColorMP4(url: vidURL, width: 160, height: 120, fps: 24, frames: 12)
        let outMP4 = dir.appendingPathComponent("out_mix.mp4")

        // Track 1: attenuated quiet carrier 0..0.4s -> fade -> pad to 0.45s
        // Track 2: 0.2s 440Hz sine -> trim [0.0..0.18s] -> afade -> mix with startSeconds [0.0, 0.25]
        let recipe = ForgeRecipe(
            inputs: [
                ForgeInputSpec(id: "vid", kind: .video, path: vidURL.path),
                ForgeInputSpec(
                    id: "quietPad",
                    kind: .synthAudio,
                    synth: ForgeAudioSynthSpec(waveform: "sine", frequencyHz: 220, amplitude: 0.002, durationSeconds: 0.25, sampleRate: 48_000, channels: 2)
                ),
                ForgeInputSpec(
                    id: "ping",
                    kind: .synthAudio,
                    synth: ForgeAudioSynthSpec(waveform: "sine", frequencyHz: 660, amplitude: 0.35, durationSeconds: 0.22, sampleRate: 48_000, channels: 2)
                ),
            ],
            timeline: ForgeTimelineSpec(fps: 24, width: 160, height: 120, durationSeconds: 0.5),
            audioOps: [
                ForgeAudioOp(id: "q_trim", op: .atrim, input: "quietPad", trimStartSeconds: 0.02, trimEndSeconds: 0.18),
                ForgeAudioOp(id: "q_pad", op: .apad, input: "q_trim", padToDurationSeconds: 0.45),
                ForgeAudioOp(id: "p_fade", op: .afade, input: "ping", fadeInSeconds: 0.02, fadeOutSeconds: 0.02),
                ForgeAudioOp(id: "mixed", op: .mix, tracks: ["q_pad", "p_fade"], gainsDB: [0.0, 0.0], startSeconds: [0.0, 0.25]),
            ],
            output: ForgeOutputSpec(
                path: outMP4.path,
                audioOutNode: "mixed",
                videoCodec: "h264",
                audioCodec: "aac",
                audioSampleRate: 48_000,
                audioChannels: 2,
                overwrite: true
            )
        )

        let report = try await ForgeGraphExecutor.execute(recipe: recipe)
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.outputPath))

        let extractedWAV = dir.appendingPathComponent("extracted.wav")
        _ = try await AudioExtractor.extract(from: outMP4, to: extractedWAV, sampleRate: 48_000, channels: 2, overwrite: true)
        let (samples, dur) = try readFloatPCM(extractedWAV, sampleRate: 48_000, channels: 2)
        XCTAssertGreaterThanOrEqual(dur, 0.40)

        let earlyRMS = rmsInterleaved(samples, channels: 2, startFrame: 0, endFrame: Int(0.20 * 48_000))
        let lateRMS = rmsInterleaved(samples, channels: 2, startFrame: Int(0.27 * 48_000), endFrame: Int(0.42 * 48_000))
        XCTAssertLessThan(earlyRMS, 0.006, "first 0.20s before delayed ping track should stay near silent (got \(earlyRMS))")
        XCTAssertGreaterThan(lateRMS, 0.05, "delayed track starting at 0.25s must be audible in [0.27..0.42s] (got \(lateRMS))")
    }

    func testVideoDeinterlacePooledRingWave6DAGOpsAndClosedGOPSceneCache() async throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let dir = try makeTempDir("dag-cache")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcMP4 = dir.appendingPathComponent("input_320x180.mp4")
        try await writeSyntheticColorMP4(url: srcMP4, width: 320, height: 180, fps: 24, frames: 12)
        let cacheDir = dir.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let out1 = dir.appendingPathComponent("out1.mp4")
        let out2 = dir.appendingPathComponent("out2.mp4")
        let out3 = dir.appendingPathComponent("out3.mp4")

        func makeRecipe(outURL: URL, includeMonochromeQA: Bool) -> ForgeRecipe {
            ForgeRecipe(
                job: ForgeJobConfig(stagePolicy: ForgeStagePolicy(apfsAutoStage: true, cacheDir: cacheDir.path, allowClonefileCoW: true)),
                inputs: [ForgeInputSpec(id: "src", kind: .video, path: srcMP4.path)],
                timeline: ForgeTimelineSpec(fps: 24, width: 180, height: 320, durationSeconds: 1.0, closedGOPSceneCache: true),
                videoOps: [
                    ForgeVideoOp(id: "deint", op: .deinterlace, input: "src", fieldOrder: "tff", motionThreshold: 0.08),
                    ForgeVideoOp(id: "fill", op: .geom, input: "deint", width: 180, height: 320, aspectFill: true),
                    ForgeVideoOp(id: "tavg", op: .tmix, input: "fill", tmixWeights: [0.25, 0.5, 0.25]),
                    ForgeVideoOp(id: "kg", op: .kGrief, input: "tavg", kGriefTemporalWeight: 0.45, kGriefExposure: 0.0, kGriefContrast: 1.05, kGriefSaturation: 0.0),
                    ForgeVideoOp(id: "slow", op: .setpts, input: "kg", ptsFactor: 1.2),
                    ForgeVideoOp(id: "hold", op: .tpad, input: "slow", holdTailSeconds: 0.35),
                ],
                qaOps: includeMonochromeQA ? ForgeQASpec(monochromeCheck: true, maxChromaDelta: 3.0) : nil,
                output: ForgeOutputSpec(path: outURL.path, videoOutNode: "hold", videoCodec: "h264", bitrate: 1_500_000, closedGOP: true, overwrite: true)
            )
        }

        let report1 = try await ForgeGraphExecutor.execute(recipe: makeRecipe(outURL: out1, includeMonochromeQA: true))
        XCTAssertEqual(report1.monochromeOK, true, "kGrief saturation 0 must pass monochromeCheck")
        XCTAssertNotNil(report1.maxChromaDelta)
        XCTAssertLessThanOrEqual(report1.maxChromaDelta ?? 999, 3.0)
        XCTAssertEqual(report1.sceneCacheHit, false)
        XCTAssertGreaterThanOrEqual(report1.framesRendered, 24)
        let reader = try await SafariumSequentialVideoReader(url: out1, loop: false)
        defer { reader.close() }
        XCTAssertEqual(reader.width, 180)
        XCTAssertEqual(reader.height, 320)
        XCTAssertGreaterThanOrEqual(reader.durationSeconds, 0.9)

        let report2 = try await ForgeGraphExecutor.execute(recipe: makeRecipe(outURL: out2, includeMonochromeQA: false))
        XCTAssertEqual(report2.sceneCacheHit, true, "second identical closedGOPSceneCache run must hit incremental cache")
        let report3 = try await ForgeGraphExecutor.execute(recipe: makeRecipe(outURL: out3, includeMonochromeQA: false))
        XCTAssertEqual(report3.sceneCacheHit, true, "subsequent identical closedGOPSceneCache run must hit incremental cache")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out3.path))
    }

    func testOggFLACAudioViaForgeStreamingAudioReaderAndAudioMixer() async throws {
        let dir = try makeTempDir("ogg-flac")
        defer { try? FileManager.default.removeItem(at: dir) }

        let ogaURL = dir.appendingPathComponent("tone.oga")
        try synthesizeValidOggFLAC(into: ogaURL, durationSeconds: 0.25, sampleRate: 48_000)

        let reader = try await ForgeStreamingAudioReader(url: ogaURL, sampleRate: 48_000, channels: 2)
        defer { reader.close() }
        var readAll: [Float] = []
        var block = [Float](repeating: 0, count: 4096 * 2)
        while true {
            let n = try block.withUnsafeMutableBufferPointer { try reader.readNextBlock(into: $0.baseAddress!, maxFrames: 4096) }
            if n == 0 { break }
            readAll.append(contentsOf: block.prefix(n * 2))
        }
        let readFrames = readAll.count / 2
        XCTAssertGreaterThan(readFrames, 8000)
        let rms = rmsInterleaved(readAll, channels: 2, startFrame: 0, endFrame: readFrames)
        XCTAssertGreaterThan(rms, 0.05, "ForgeStreamingAudioReader must decode Ogg FLAC to non-silent PCM")

        let mixedWAV = dir.appendingPathComponent("mixed_from_ogg.wav")
        let mixReport = try await AudioMixer.mix(
            tracks: [AudioMixTrack(url: ogaURL, gainDB: -3.0, startSeconds: 0.0, loop: false)],
            to: mixedWAV,
            sampleRate: 48_000,
            channels: 2,
            overwrite: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: mixedWAV.path))
        XCTAssertGreaterThan(mixReport.durationSeconds, 0.18)
        let (outSamples, _) = try readFloatPCM(mixedWAV, sampleRate: 48_000, channels: 2)
        XCTAssertGreaterThan(rmsInterleaved(outSamples, channels: 2, startFrame: 0, endFrame: outSamples.count / 2), 0.03)
    }
}
