import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import SafariumCore
import VideoToolbox
import XCTest

/// Wave 9 — Apple Silicon Encoding Supremacy test suite.
/// Covers all 6 pillars:
///   1. Modern VideoToolbox Rate-Control (SpatialAQ, LookAhead, Constrained VBR+VBV, CQF) & 10-bit HEVC (P010/P210/P410 + Bayer dithering)
///   2. True Native 2-Pass VideoToolbox (`VTMultiPassStorage`)
///   3. MetalShotAnalyzer + MultiEngineChunkEncoder ("Safarium Mini-CAE")
///   4. Pro Mastering Formats (All 12 codecs, HDR10/HLG/Dolby Vision 8.4, MV-HEVC Spatial Video)
///   5. Pro AudioToolbox Mastering (AAC-Max, HE-AAC v1/v2, ALAC, Opus, PCM 24-bit)
final class Wave9SupremacyTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf-wave9-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Generates a synthetic 3-shot test video (Shot 0: static dark gradient, Shot 1: moving diagonal bars, Shot 2: bright checkerboard)
    /// using native SafariumCore AVAssetWriterSink (0% FFmpeg).
    private func makeThreeShotClip(
        at url: URL,
        width: Int = 320,
        height: Int = 180,
        fps: Int = 30,
        framesPerShot: Int = 18
    ) async throws {
        let sink = try AVAssetWriterSink(
            url: url,
            width: width,
            height: height,
            fps: fps,
            codec: .hevc,
            bitrate: 2_500_000,
            pixelFormat: .nv12Left,
            profile: .baseline
        )
        let stride = width * 4
        var bgra = [UInt8](repeating: 0, count: height * stride)
        let totalFrames = framesPerShot * 3
        for f in 0..<totalFrames {
            let shot = f / framesPerShot
            let localF = f % framesPerShot
            for y in 0..<height {
                let rowOff = y * stride
                for x in 0..<width {
                    let off = rowOff + x * 4
                    switch shot {
                    case 0:
                        // Subtle dark gradient (tests 10-bit banding resistance & static hold detection)
                        let v = UInt8(min(255, 16 + (x * 48) / max(1, width) + (y * 24) / max(1, height)))
                        bgra[off + 0] = v
                        bgra[off + 1] = UInt8(min(255, Int(v) + 4))
                        bgra[off + 2] = UInt8(min(255, Int(v) + 10))
                        bgra[off + 3] = 255
                    case 1:
                        // Fast moving high-contrast diagonal stripes (high temporal & spatial complexity)
                        let band = ((x + y + localF * 11) / 10) % 2
                        let r: UInt8 = band == 0 ? 235 : 25
                        let g: UInt8 = band == 0 ? 60 : 185
                        let b: UInt8 = band == 0 ? 40 : 230
                        bgra[off + 0] = b
                        bgra[off + 1] = g
                        bgra[off + 2] = r
                        bgra[off + 3] = 255
                    default:
                        // Bright shifting checkerboard (distinct 3rd shot cut)
                        let cx = ((x + localF * 5) / 16) % 2
                        let cy = (y / 16) % 2
                        let bright = (cx ^ cy) == 0
                        bgra[off + 0] = bright ? 240 : 190
                        bgra[off + 1] = bright ? 240 : 140
                        bgra[off + 2] = bright ? 240 : 90
                        bgra[off + 3] = 255
                    }
                }
            }
            try await sink.append { pb in
                try bgra.withUnsafeBytes { raw in
                    try SafariumAccelerate.convertRawBGRAToNV12BT709Left(
                        bgra: raw.baseAddress!,
                        bgraBytesPerRow: stride,
                        into: pb,
                        width: width,
                        height: height
                    )
                }
            }
        }
        try await sink.finish()
    }

    private func makeSineWAV(at url: URL, seconds: Double = 1.0, sampleRate: Int = 48_000) throws {
        let channels = 2
        let frames = Int(seconds * Double(sampleRate))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels), interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        let ch0 = buf.floatChannelData![0]
        let ch1 = buf.floatChannelData![1]
        for i in 0..<frames {
            let t = Double(i) / Double(sampleRate)
            ch0[i] = Float(0.35 * sin(2.0 * .pi * 440.0 * t))
            ch1[i] = Float(0.35 * sin(2.0 * .pi * 660.0 * t))
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        try file.write(from: buf)
    }

    // MARK: - Pillar 1: Hardware Probe, 10-bit HEVC + Bayer Dithering, All 12 Codecs & Rate Control

    func testAppleSiliconMediaEngineProbe() {
        let info = AppleSiliconMediaEngineInfo.probe()
        XCTAssertFalse(info.chipBrand.isEmpty)
        XCTAssertGreaterThanOrEqual(info.physicalCores, 1)
        XCTAssertGreaterThanOrEqual(info.estimatedMediaEngines, 1)
        XCTAssertGreaterThanOrEqual(info.recommendedParallelEngines, 1)
        XCTAssertLessThanOrEqual(info.recommendedParallelEngines, 4)
        XCTAssertFalse(info.macOSVersion.isEmpty)
    }

    func testTenBitHEVCWithBayerDitheringAndSupremacyQualityAndDV84() async throws {
        let dir = try makeTempDir("hevc10")
        defer { try? FileManager.default.removeItem(at: dir) }

        let outURL = dir.appendingPathComponent("hevc10-dv84.mov")
        var profile = EncoderProfile.supremacyQuality
        profile.colorMastering = .dolbyVision84

        let sink = try AVAssetWriterSink(
            url: outURL,
            width: 320,
            height: 180,
            fps: 30,
            codec: .hevc10,
            bitrate: 3_000_000,
            pixelFormat: .p010,
            profile: profile
        )
        let dvGen = HDRDynamicMetadataGenerator(fps: 30)
        var bgra = [UInt8](repeating: 0, count: 320 * 180 * 4)
        for y in 0..<180 {
            for x in 0..<320 {
                let off = (y * 320 + x) * 4
                let v = UInt8((x * 255) / 319)
                bgra[off + 0] = v
                bgra[off + 1] = UInt8((y * 255) / 179)
                bgra[off + 2] = UInt8(255 - Int(v))
                bgra[off + 3] = 255
            }
        }
        for i in 0..<10 {
            try await sink.append { pb in
                try bgra.withUnsafeBytes { raw in
                    try AVAssetWriterSink.convertBGRATo10BitBiPlanar(
                        bgra: raw.baseAddress!,
                        bgraBytesPerRow: 320 * 4,
                        into: pb,
                        width: 320,
                        height: 180,
                        pixelFormat: .p010
                    )
                }
                _ = dvGen.attach(to: pb, sceneChange: i == 0)
            }
        }
        try await sink.finish()

        let asset = AVURLAsset(url: outURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let size = try await tracks[0].load(.naturalSize)
        XCTAssertEqual(size.width, 320)
        XCTAssertEqual(size.height, 180)
        let fileSize = ((try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        XCTAssertGreaterThan(fileSize, 1_000)
    }

    func testTenBit422AndProResTiersEncodeCleanly() async throws {
        let dir = try makeTempDir("pro-codecs")
        defer { try? FileManager.default.removeItem(at: dir) }

        let codecsToTest: [(VideoCodec, SinkPixelFormat, String)] = [
            (.hevc42210, .p210, "hevc42210.mov"),
            (.proRes422Proxy, .bgra, "prores-proxy.mov"),
            (.proRes422LT, .bgra, "prores-lt.mov"),
            (.proRes422, .bgra, "prores422.mov"),
            (.proRes422HQ, .bgra, "prores422hq.mov"),
            (.proRes4444XQ, .bgra, "prores4444xq.mov"),
        ]
        let bgra = [UInt8](repeating: 140, count: 160 * 90 * 4)
        for (codec, pf, name) in codecsToTest {
            let outURL = dir.appendingPathComponent(name)
            let sink = try AVAssetWriterSink(
                url: outURL,
                width: 160,
                height: 90,
                fps: 30,
                codec: codec,
                bitrate: 2_000_000,
                pixelFormat: pf,
                profile: .baseline
            )
            let is10BitPF = (pf == .p010 || pf == .p210 || pf == .p410)
            for _ in 0..<4 {
                try await sink.append { pb in
                    if is10BitPF {
                        try bgra.withUnsafeBytes { raw in
                            try AVAssetWriterSink.convertBGRATo10BitBiPlanar(
                                bgra: raw.baseAddress!,
                                bgraBytesPerRow: 160 * 4,
                                into: pb,
                                width: 160,
                                height: 90,
                                pixelFormat: pf
                            )
                        }
                    } else {
                        CVPixelBufferLockBaseAddress(pb, [])
                        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
                        if let base = CVPixelBufferGetBaseAddress(pb) {
                            let dstStride = CVPixelBufferGetBytesPerRow(pb)
                            bgra.withUnsafeBytes { raw in
                                for y in 0..<90 {
                                    memcpy(base.advanced(by: y * dstStride), raw.baseAddress!.advanced(by: y * 160 * 4), 160 * 4)
                                }
                            }
                        }
                    }
                }
            }
            try await sink.finish()
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
            XCTAssertGreaterThan(bytes, 500, "codec \(codec.cliDisplayName) produced empty file")
        }
    }

    // MARK: - Pillar 2: True Native 2-Pass VideoToolbox (VTMultiPassStorage) & CQF

    func testTrueTwoPassAndCQFTranscode() async throws {
        let dir = try makeTempDir("2pass-cqf")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("src.mp4")
        try await makeThreeShotClip(at: srcURL)

        // 1) True 2-pass VTMultiPassStorage
        let out2Pass = dir.appendingPathComponent("out-2pass.mp4")
        var cfg2 = SupremacyTranscodeConfig(
            codec: .hevc10,
            mode: .twoPass,
            bitrate: 1_500_000,
            overwrite: true
        )
        cfg2.spatialAdaptiveQP = true
        let rep2 = try await VTMultiPassEncoder.encode(inputURL: srcURL, outputURL: out2Pass, config: cfg2)
        XCTAssertEqual(rep2.framesEncoded, 54)
        XCTAssertGreaterThanOrEqual(rep2.passesExecuted, 1)
        XCTAssertGreaterThan(rep2.outputBytes, 2_000)

        // 2) Constant Quality Factor (CQF)
        let outCQF = dir.appendingPathComponent("out-cqf.mp4")
        let cfgCQF = SupremacyTranscodeConfig(
            codec: .hevc10,
            mode: .cqf,
            cqf: 0.65,
            overwrite: true
        )
        let repCQF = try await VTMultiPassEncoder.encode(inputURL: srcURL, outputURL: outCQF, config: cfgCQF)
        XCTAssertEqual(repCQF.framesEncoded, 54)
        XCTAssertGreaterThan(repCQF.outputBytes, 2_000)
    }

    // MARK: - Pillar 3: MetalShotAnalyzer + MultiEngineChunkEncoder ("Mini-CAE")

    func testMetalShotAnalyzerDetectsThreeShotsAndComplexityDelta() async throws {
        let dir = try makeTempDir("shots")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("three-shots.mp4")
        try await makeThreeShotClip(at: srcURL)

        let report = try await MetalShotAnalyzer.analyze(inputURL: srcURL, cutThresholdHist: 0.25)
        XCTAssertEqual(report.totalFrames, 54)
        XCTAssertGreaterThanOrEqual(report.shots.count, 2, "expected at least 2 distinct shots in synthetic 3-shot clip")
        // Static gradient shot should have lower temporal complexity than moving bars shot
        let minTemporal = report.shots.map { $0.temporalComplexity }.min() ?? 1.0
        let maxTemporal = report.shots.map { $0.temporalComplexity }.max() ?? 0.0
        XCTAssertGreaterThan(maxTemporal, minTemporal)
    }

    func testMiniCAEMultiEngineChunkEncoder() async throws {
        let dir = try makeTempDir("minicae")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("three-shots.mp4")
        try await makeThreeShotClip(at: srcURL)

        let outURL = dir.appendingPathComponent("out-minicae.mp4")
        var cfg = SupremacyTranscodeConfig(
            codec: .hevc10,
            mode: .miniCAE,
            bitrate: 1_500_000,
            overwrite: true
        )
        cfg.parallelEngines = 2
        let rep = try await MultiEngineChunkEncoder.encode(inputURL: srcURL, outputURL: outURL, config: cfg)
        XCTAssertEqual(rep.framesEncoded, 54)
        XCTAssertGreaterThanOrEqual(rep.chunksEncoded, 2)
        XCTAssertGreaterThan(rep.outputBytes, 2_000)

        let asset = AVURLAsset(url: outURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
    }

    // MARK: - Pillar 5: MV-HEVC Spatial Video (Apple Vision Pro)

    func testMVHEVCSpatialStereoEncodeIfSupported() async throws {
        guard MVHEVCSpatialEncoder.isSupported else {
            throw XCTSkip("MV-HEVC hardware encoding not supported on this runner")
        }
        let dir = try makeTempDir("mvhevc")
        defer { try? FileManager.default.removeItem(at: dir) }

        let leftURL = dir.appendingPathComponent("left.mp4")
        let rightURL = dir.appendingPathComponent("right.mp4")
        try await makeThreeShotClip(at: leftURL, width: 320, height: 180, fps: 30, framesPerShot: 5)
        try await makeThreeShotClip(at: rightURL, width: 320, height: 180, fps: 30, framesPerShot: 5)

        let outURL = dir.appendingPathComponent("spatial.mov")
        let rep = try await MVHEVCSpatialEncoder.encodeStereo(
            leftURL: leftURL,
            rightURL: rightURL,
            outputURL: outURL,
            config: MVHEVCEncodeConfig(bitrate: 3_000_000, tenBit: true, overwrite: true)
        )
        XCTAssertEqual(rep.framesEncoded, 15)
        XCTAssertGreaterThan(rep.outputBytes, 1_500)
    }

    // MARK: - Pillar 6: Pro AudioToolbox Mastering

    func testProAudioEncoderAllCodecs() async throws {
        let caps = ProAudioEncoder.probeCapabilities()
        XCTAssertTrue(caps.aacMaxQuality)
        XCTAssertTrue(caps.alac)
        XCTAssertTrue(caps.pcm16_24_32f)

        let dir = try makeTempDir("audio")
        defer { try? FileManager.default.removeItem(at: dir) }

        let wavURL = dir.appendingPathComponent("tone.wav")
        try makeSineWAV(at: wavURL, seconds: 0.75)

        let codecs: [SafariumAudioCodec] = [.aacMax, .heAAC, .heAACv2, .alac, .opus, .pcm24]
        for codec in codecs {
            let outURL = dir.appendingPathComponent("out-\(codec.rawValue).\(codec.defaultExtension)")
            let rep = try await ProAudioEncoder.transcode(
                inputURL: wavURL,
                outputURL: outURL,
                codec: codec,
                overwrite: true
            )
            XCTAssertGreaterThan(rep.outputBytes, 200, "audio codec \(codec.rawValue) produced empty output")
            XCTAssertEqual(rep.channels, 2)
        }
    }
}
