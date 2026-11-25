import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import SafariumCore
import XCTest

/// Wave 12 — SupremacyEncoder BT.709 colorimetry & CIEDE2000 parity verification.
/// Guards against YUV -> BGRA -> YUV roundtrip degradation and matrix/siting mismatches
/// across 8-bit HEVC (`hevc`) and 10-bit HEVC (`hevc10`) in high-quality, 2-pass, Mini-CAE,
/// and BGRA-preprocessor paths.
final class Wave12SupremacyColorParityTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf-wave12-supremacy-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates a deterministic BT.709 640x360 test video containing:
    /// - Top third (0..<120): smooth gradient (dark slate -> sky blue)
    /// - Middle third (120..<240): saturated red, green, blue, cyan, yellow vertical color bars
    /// - Bottom third (240..<360): sharp white text-like glyph bars on dark background
    private func makeDeterministicBT709TestVideo(
        at url: URL,
        width: Int = 640,
        height: Int = 360,
        fps: Int = 30,
        frameCount: Int = 30
    ) async throws {
        let sink = try AVAssetWriterSink(
            url: url,
            width: width,
            height: height,
            fps: fps,
            codec: .hevc,
            bitrate: 10_000_000,
            pixelFormat: .nv12Left,
            profile: .baseline
        )
        let stride = width * 4
        var bgra = [UInt8](repeating: 0, count: height * stride)

        let bars: [(r: UInt8, g: UInt8, b: UInt8)] = [
            (225, 28, 28),   // saturated red
            (28, 215, 36),   // saturated green
            (30, 52, 232),   // saturated blue
            (24, 218, 232),  // saturated cyan
            (236, 224, 30),  // saturated yellow
        ]

        for f in 0..<frameCount {
            let shift = (f * 2) % 32
            for y in 0..<height {
                let rowOff = y * stride
                if y < 120 {
                    // Top band: smooth gradient
                    let gy = Double(y) / 119.0
                    for x in 0..<width {
                        let gx = Double((x + shift) % width) / Double(width - 1)
                        let r = UInt8(min(255, max(0, Int((18.0 + 78.0 * gx + 24.0 * gy).rounded()))))
                        let g = UInt8(min(255, max(0, Int((28.0 + 112.0 * gx + 42.0 * gy).rounded()))))
                        let b = UInt8(min(255, max(0, Int((46.0 + 168.0 * gx + 28.0 * gy).rounded()))))
                        let off = rowOff + x * 4
                        bgra[off + 0] = b
                        bgra[off + 1] = g
                        bgra[off + 2] = r
                        bgra[off + 3] = 255
                    }
                } else if y < 240 {
                    // Middle band: saturated red / green / blue / cyan / yellow vertical color bars
                    for x in 0..<width {
                        let barIdx = min(bars.count - 1, (x * bars.count) / width)
                        let c = bars[barIdx]
                        let off = rowOff + x * 4
                        bgra[off + 0] = c.b
                        bgra[off + 1] = c.g
                        bgra[off + 2] = c.r
                        bgra[off + 3] = 255
                    }
                } else {
                    // Bottom band: sharp white text-like glyph bars on dark background
                    let localY = y - 240
                    for x in 0..<width {
                        let cellX = (x + shift) % 32
                        let isGlyphBand = (localY >= 24 && localY < 96)
                        let isGlyphBar = isGlyphBand && (
                            (cellX >= 4 && cellX < 8) ||
                            (cellX >= 14 && cellX < 18) ||
                            ((localY >= 24 && localY < 30 || localY >= 56 && localY < 62 || localY >= 90 && localY < 96) && cellX >= 4 && cellX < 24)
                        )
                        let off = rowOff + x * 4
                        if isGlyphBar {
                            bgra[off + 0] = 242
                            bgra[off + 1] = 242
                            bgra[off + 2] = 242
                            bgra[off + 3] = 255
                        } else {
                            bgra[off + 0] = 22
                            bgra[off + 1] = 18
                            bgra[off + 2] = 16
                            bgra[off + 3] = 255
                        }
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

    /// Decodes specified frame indices from a video file into `32BGRA` pixel buffers.
    private func decodeBGRAFrames(from url: URL, indices: Set<Int>) async throws -> [Int: CVPixelBuffer] {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "Wave12SupremacyColorParityTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing video track"])
        }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else {
            throw NSError(domain: "Wave12SupremacyColorParityTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot add BGRA output"])
        }
        reader.add(out)
        guard reader.startReading() else {
            throw NSError(domain: "Wave12SupremacyColorParityTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "startReading failed"])
        }
        defer { reader.cancelReading() }

        let maxIndex = indices.max() ?? 0
        var frames: [Int: CVPixelBuffer] = [:]
        var idx = 0
        while let sb = autoreleasepool(invoking: { out.copyNextSampleBuffer() }) {
            if indices.contains(idx), let pb = CMSampleBufferGetImageBuffer(sb) {
                frames[idx] = pb
            }
            idx += 1
            if idx > maxIndex && frames.count == indices.count {
                break
            }
        }
        return frames
    }

    /// Verifies that the video track format description carries ITU-R BT.709 primaries, transfer function, and YCbCr matrix tags.
    private func assertBT709ColorTags(at url: URL, label: String) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1, "\(label): expected 1 video track")
        guard let track = tracks.first else { return }
        let descs = try await track.load(.formatDescriptions)
        guard let desc = descs.first else {
            XCTFail("\(label): missing CMFormatDescription")
            return
        }
        let exts = (CMFormatDescriptionGetExtensions(desc) as? [String: Any]) ?? [:]
        let primaries = exts[kCVImageBufferColorPrimariesKey as String] as? String
        let transfer = exts[kCVImageBufferTransferFunctionKey as String] as? String
        let matrix = exts[kCVImageBufferYCbCrMatrixKey as String] as? String

        XCTAssertEqual(primaries, kCVImageBufferColorPrimaries_ITU_R_709_2 as String, "\(label): primaries must be ITU_R_709_2")
        XCTAssertEqual(transfer, kCVImageBufferTransferFunction_ITU_R_709_2 as String, "\(label): transfer must be ITU_R_709_2")
        XCTAssertEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String, "\(label): matrix must be ITU_R_709_2")
    }

    private func measureVideoDeltaE00(
        referenceURL: URL,
        candidateURL: URL,
        sampleIndices: [Int] = [0, 10, 20]
    ) async throws -> (mean: Double, p95: Double) {
        let idxSet = Set(sampleIndices)
        let refFrames = try await decodeBGRAFrames(from: referenceURL, indices: idxSet)
        let candFrames = try await decodeBGRAFrames(from: candidateURL, indices: idxSet)
        XCTAssertEqual(refFrames.count, idxSet.count, "expected all reference sample frames")
        XCTAssertEqual(candFrames.count, idxSet.count, "expected all candidate sample frames")

        var meanSum = 0.0
        var maxP95 = 0.0
        var count = 0
        for idx in sampleIndices {
            guard let rPB = refFrames[idx], let cPB = candFrames[idx] else { continue }
            let report = try MetalChromaPipeline.measureMaskedDeltaE00(
                referenceBGRA: rPB,
                candidateBGRA: cPB
            )
            meanSum += report.meanDeltaE00
            maxP95 = max(maxP95, report.p95DeltaE00)
            count += 1
        }
        XCTAssertGreaterThan(count, 0)
        return (meanSum / Double(max(1, count)), maxP95)
    }

    // MARK: - Tests

    func testSupremacyHEVC8And10BitBT709ColorParity() async throws {
        let dir = try makeTempDir("hevc8-hevc10")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("bt709-source.mp4")
        try await makeDeterministicBT709TestVideo(at: srcURL)

        // 1) 8-bit HEVC (`hevc`) via SupremacyEncoder.transcode
        let out8URL = dir.appendingPathComponent("out-hevc8.mp4")
        let cfg8 = SupremacyTranscodeConfig(
            codec: .hevc,
            mode: .highQuality,
            bitrate: 2_400_000,
            colorMastering: .sdrBT709,
            overwrite: true
        )
        let rep8 = try await SupremacyEncoder.transcode(inputURL: srcURL, outputURL: out8URL, config: cfg8)
        XCTAssertEqual(rep8.framesEncoded, 30)
        XCTAssertGreaterThan(rep8.outputBytes, 2_000)
        try await assertBT709ColorTags(at: out8URL, label: "hevc8-hq")

        let de8 = try await measureVideoDeltaE00(referenceURL: srcURL, candidateURL: out8URL)
        print(String(format: "[Wave12 ColorParity] hevc8  HQ: meanDeltaE00=%.4f p95DeltaE00=%.4f", de8.mean, de8.p95))
        XCTAssertLessThan(de8.mean, 1.2, "hevc8 meanDeltaE00 \(de8.mean) must be < 1.2")
        XCTAssertLessThanOrEqual(de8.p95, 2.0, "hevc8 p95DeltaE00 \(de8.p95) must be <= 2.0")

        // 2) 10-bit HEVC (`hevc10`) via SupremacyEncoder.transcode
        let out10URL = dir.appendingPathComponent("out-hevc10.mp4")
        let cfg10 = SupremacyTranscodeConfig(
            codec: .hevc10,
            mode: .highQuality,
            bitrate: 2_400_000,
            colorMastering: .sdrBT709,
            overwrite: true
        )
        let rep10 = try await SupremacyEncoder.transcode(inputURL: srcURL, outputURL: out10URL, config: cfg10)
        XCTAssertEqual(rep10.framesEncoded, 30)
        XCTAssertGreaterThan(rep10.outputBytes, 2_000)
        try await assertBT709ColorTags(at: out10URL, label: "hevc10-hq")

        let de10 = try await measureVideoDeltaE00(referenceURL: srcURL, candidateURL: out10URL)
        print(String(format: "[Wave12 ColorParity] hevc10 HQ: meanDeltaE00=%.4f p95DeltaE00=%.4f", de10.mean, de10.p95))
        XCTAssertLessThan(de10.mean, 1.2, "hevc10 meanDeltaE00 \(de10.mean) must be < 1.2")
        XCTAssertLessThanOrEqual(de10.p95, 2.0, "hevc10 p95DeltaE00 \(de10.p95) must be <= 2.0")
    }

    func testSupremacyTwoPassAndMiniCAE10BitColorParity() async throws {
        let dir = try makeTempDir("2pass-minicae-10bit")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("bt709-source.mp4")
        try await makeDeterministicBT709TestVideo(at: srcURL)

        // 1) 2-Pass 10-bit HEVC
        let out2Pass = dir.appendingPathComponent("out-hevc10-2pass.mp4")
        let cfg2Pass = SupremacyTranscodeConfig(
            codec: .hevc10,
            mode: .twoPass,
            bitrate: 2_400_000,
            colorMastering: .sdrBT709,
            overwrite: true
        )
        let rep2 = try await SupremacyEncoder.transcode(inputURL: srcURL, outputURL: out2Pass, config: cfg2Pass)
        XCTAssertEqual(rep2.framesEncoded, 30)
        try await assertBT709ColorTags(at: out2Pass, label: "hevc10-2pass")
        let de2 = try await measureVideoDeltaE00(referenceURL: srcURL, candidateURL: out2Pass)
        print(String(format: "[Wave12 ColorParity] hevc10 2Pass: meanDeltaE00=%.4f p95DeltaE00=%.4f", de2.mean, de2.p95))
        XCTAssertLessThan(de2.mean, 1.2)
        XCTAssertLessThanOrEqual(de2.p95, 2.0)

        // 2) Mini-CAE 10-bit HEVC
        let outCAE = dir.appendingPathComponent("out-hevc10-minicae.mp4")
        let cfgCAE = SupremacyTranscodeConfig(
            codec: .hevc10,
            mode: .miniCAE,
            bitrate: 2_400_000,
            colorMastering: .sdrBT709,
            parallelEngines: 1,
            overwrite: true
        )
        let repCAE = try await SupremacyEncoder.transcode(inputURL: srcURL, outputURL: outCAE, config: cfgCAE)
        XCTAssertEqual(repCAE.framesEncoded, 30)
        try await assertBT709ColorTags(at: outCAE, label: "hevc10-minicae")
        let deCAE = try await measureVideoDeltaE00(referenceURL: srcURL, candidateURL: outCAE)
        print(String(format: "[Wave12 ColorParity] hevc10 MiniCAE: meanDeltaE00=%.4f p95DeltaE00=%.4f", deCAE.mean, deCAE.p95))
        XCTAssertLessThan(deCAE.mean, 1.2)
        XCTAssertLessThanOrEqual(deCAE.p95, 2.0)
    }

    func testSupremacyBGRAPreprocessorToP010UsesMetalChromaPipeline() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("No Metal GPU device available on this host")
        }
        let dir = try makeTempDir("bgra-preproc-p010")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("bt709-source.mp4")
        try await makeDeterministicBT709TestVideo(at: srcURL, frameCount: 15)

        let pipeline = try MetalChromaPipeline()
        let outURL = dir.appendingPathComponent("out-hevc10-bgra-preproc.mp4")
        let cfg = SupremacyTranscodeConfig(
            codec: .hevc10,
            mode: .highQuality,
            bitrate: 3_000_000,
            colorMastering: .sdrBT709,
            overwrite: true
        )

        // Preprocessor simulates a BGRA-emitting stage (e.g. HardwareToneMapper) so SupremacyEncoder
        // exercises the MetalChromaPipeline BGRA -> P010 conversion path end-to-end.
        let rep = try await SupremacyEncoder.transcode(
            inputURL: srcURL,
            outputURL: outURL,
            config: cfg,
            framePreprocessor: { pb, _, _ in
                let w = CVPixelBufferGetWidth(pb)
                let h = CVPixelBufferGetHeight(pb)
                let attrs: [CFString: Any] = [
                    kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                    kCVPixelBufferMetalCompatibilityKey: true,
                ]
                var bgraOpt: CVPixelBuffer?
                let st = CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &bgraOpt)
                guard st == kCVReturnSuccess, let bgra = bgraOpt else { return pb }
                let reconCfg = ChromaConversionConfig(
                    bitDepth: 10,
                    siting: .coSited,
                    filterMode: .lumaGuidedEdgeAware,
                    ditherMode: .none,
                    isBT2020: false,
                    fullRange: false,
                    frameIndex: 0
                )
                try pipeline.reconstructYUVtoBGRA(srcYUV: pb, dstBGRA: bgra, config: reconCfg)
                return bgra
            }
        )
        XCTAssertEqual(rep.framesEncoded, 15)
        try await assertBT709ColorTags(at: outURL, label: "hevc10-bgra-preproc")

        let de = try await measureVideoDeltaE00(referenceURL: srcURL, candidateURL: outURL, sampleIndices: [0, 7, 14])
        print(String(format: "[Wave12 ColorParity] hevc10 BGRA->MetalChroma->P010: meanDeltaE00=%.4f p95DeltaE00=%.4f", de.mean, de.p95))
        XCTAssertLessThan(de.mean, 1.2)
        XCTAssertLessThanOrEqual(de.p95, 2.0)
    }
}
