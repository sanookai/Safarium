import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SafariumCore
import XCTest

final class Wave15PerceptualAndEnhancementTests: XCTestCase {

    // MARK: - 1. NativeCAMBI Multiscale Banding Detection

    func testNativeCAMBIScoresBandedHigherThanSmoothAndDithered() throws {
        let width = 256
        let height = 144

        // 8-bit dark gradient: levels 16...31 across 256px (16px wide flat bands -> strong banding!)
        var banded8 = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let level8 = UInt16(16 + (x * 16) / width)
                banded8[row + x] = level8
            }
        }

        // Smooth 10-bit gradient across the exact same luma span (64...128 in 10-bit)
        var smooth10 = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let frac = Double(x) / Double(width - 1)
                let val10 = UInt16((64.0 + frac * 64.0).rounded())
                smooth10[row + x] = val10
            }
        }

        // Dithered 8-bit gradient using triangular-PDF Interleaved Gradient Noise (+/- 1 LSB)
        var dithered8 = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let frac = Double(x) / Double(width - 1)
                let exact8 = 16.0 + frac * 16.0
                let h1 = ign(Double(x), Double(y))
                let h2 = ign(Double(x) + 17.0, Double(y) + 31.0)
                let dithered = exact8 + (h1 - h2)
                let clamped = max(0.0, min(255.0, dithered.rounded()))
                dithered8[row + x] = UInt16(clamped)
            }
        }

        let bandedRes = NativeCAMBI.measureLuma(banded8, width: width, height: height, bitDepth: 8)
        let smoothRes = NativeCAMBI.measureLuma(smooth10, width: width, height: height, bitDepth: 10)
        let ditheredRes = NativeCAMBI.measureLuma(dithered8, width: width, height: height, bitDepth: 8)

        XCTAssertEqual(bandedRes.width, width)
        XCTAssertEqual(bandedRes.height, height)
        XCTAssertEqual(bandedRes.scaleScores.count, 3)
        XCTAssertGreaterThan(bandedRes.cambiScore, 2.0, "Synthetic 8-bit banded gradient should have high CAMBI")
        XCTAssertGreaterThan(bandedRes.bandedAreaRatio, 0.15, "Banded gradient should mark substantial banded area")
        XCTAssertGreaterThan(
            bandedRes.cambiScore,
            smoothRes.cambiScore * 3.0,
            "8-bit banded gradient (\(bandedRes.cambiScore)) must score >> smooth 10-bit gradient (\(smoothRes.cambiScore))"
        )
        XCTAssertGreaterThan(
            bandedRes.cambiScore,
            ditheredRes.cambiScore * 2.0,
            "8-bit banded gradient (\(bandedRes.cambiScore)) must score >> dithered 8-bit gradient (\(ditheredRes.cambiScore))"
        )

        // Verify Codable JSON serialization
        let encoded = try JSONEncoder().encode(bandedRes)
        let decoded = try JSONDecoder().decode(NativeCAMBIResult.self, from: encoded)
        XCTAssertEqual(decoded, bandedRes)
    }

    // MARK: - 2. MetalDebandFilter Reduces CAMBI & Preserves Sharp Edges

    func testMetalDebandFilterReducesCAMBIAndPreservesSharpEdges() throws {
        let width = 256
        let height = 160

        // BGRA8 frame with a banded dark gradient + sharp white-on-black box/stroke panel
        let inputBGRA = try makeBandedGradientWithSharpBoxBGRA(width: width, height: height)
        let beforeCAMBI = NativeCAMBI.measure(pixelBuffer: inputBGRA)

        let filter = MetalDebandFilter.shared
        let config = DebandConfig(
            strength: 0.80,
            threshold: 0.025,
            ditherAmplitude: 1.15,
            protectSharpEdges: true,
            edgeThreshold: 0.045
        )
        let outputBGRA = try filter.process(input: inputBGRA, frameIndex: 0, config: config)
        let afterCAMBI = NativeCAMBI.measure(pixelBuffer: outputBGRA)

        XCTAssertGreaterThan(beforeCAMBI.cambiScore, 1.5, "Input banded gradient should have measurable CAMBI")
        XCTAssertLessThan(
            afterCAMBI.cambiScore,
            beforeCAMBI.cambiScore * 0.65,
            "Debanding should significantly reduce CAMBI (before=\(beforeCAMBI.cambiScore), after=\(afterCAMBI.cambiScore))"
        )

        // Verify sharp white-on-black box edges are preserved without halo/ringing
        let frameEval = NativePerceptualMetrics.evaluateFrame(reference: inputBGRA, candidate: outputBGRA)
        XCTAssertGreaterThanOrEqual(
            frameEval.sharpnessRetention,
            0.90,
            "Sharp white-on-black edge gradient must be retained (got \(frameEval.sharpnessRetention))"
        )
        XCTAssertLessThan(
            frameEval.ringingPenalty,
            2.5,
            "Edge-protected debanding must not introduce halo ringing (got \(frameEval.ringingPenalty))"
        )
        XCTAssertGreaterThan(
            frameEval.perceptualScore,
            85.0,
            "Debanded output should retain high perceptual fidelity (got \(frameEval.perceptualScore))"
        )

        // Also test P010 10-bit bi-planar processing
        let inputP010 = try makeBandedGradientP010(width: width, height: height)
        let beforeP010 = NativeCAMBI.measure(pixelBuffer: inputP010)
        let outputP010 = try filter.process(input: inputP010, frameIndex: 1, config: config)
        let afterP010 = NativeCAMBI.measure(pixelBuffer: outputP010)

        XCTAssertEqual(CVPixelBufferGetPixelFormatType(outputP010), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
        XCTAssertGreaterThan(beforeP010.cambiScore, 1.5)
        XCTAssertLessThan(
            afterP010.cambiScore,
            beforeP010.cambiScore * 0.50,
            "P010 10-bit debanding should strongly reduce CAMBI (before=\(beforeP010.cambiScore), after=\(afterP010.cambiScore))"
        )
    }

    // MARK: - 3. HardwareUpscaler 320x180 -> 640x360

    func testHardwareUpscalerProducesCrispExactDimensions() throws {
        let srcW = 320
        let srcH = 180
        let dstW = 640
        let dstH = 360

        let srcPB = try makeSharpTestPatternBGRA(width: srcW, height: srcH)
        let srcMeanLuma = meanBGRA8Luma(srcPB)

        let hwConfig = UpscaleConfig(
            targetWidth: dstW,
            targetHeight: dstH,
            useHardwareSR: true,
            sharpenAmount: 0.25
        )
        let upscaledHW = try HardwareUpscaler.upscale(pixelBuffer: srcPB, config: hwConfig)
        XCTAssertEqual(CVPixelBufferGetWidth(upscaledHW), dstW)
        XCTAssertEqual(CVPixelBufferGetHeight(upscaledHW), dstH)

        let hwMeanLuma = meanBGRA8Luma(upscaledHW)
        XCTAssertGreaterThan(hwMeanLuma, 30.0, "Upscaled output must be non-black")
        XCTAssertLessThan(abs(hwMeanLuma - srcMeanLuma), 25.0, "Upscaled luminance should track input luminance")
        let hwEdgeEnergy = meanEdgeGradientBGRA8(upscaledHW)
        XCTAssertGreaterThan(hwEdgeEnergy, 4.0, "Upscaled output should preserve sharp test-pattern edges")

        // Also validate explicit CoreImage Lanczos path
        let ciConfig = UpscaleConfig(
            targetWidth: dstW,
            targetHeight: dstH,
            useHardwareSR: false,
            sharpenAmount: 0.25
        )
        let upscaledCI = try HardwareUpscaler.upscale(pixelBuffer: srcPB, config: ciConfig)
        XCTAssertEqual(CVPixelBufferGetWidth(upscaledCI), dstW)
        XCTAssertEqual(CVPixelBufferGetHeight(upscaledCI), dstH)
        XCTAssertGreaterThan(meanBGRA8Luma(upscaledCI), 30.0)
    }

    // MARK: - 4. End-to-End EnhancementPipeline + NativePerceptualMetrics.evaluateVideo

    func testEnhancementPipelineEndToEndOnSyntheticBandedMP4() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safarium-w15-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let inputURL = tmpDir.appendingPathComponent("banded_input.mp4")
        let outputURL = tmpDir.appendingPathComponent("enhanced_output.mp4")

        try await writeSyntheticBandedMP4(to: inputURL, width: 256, height: 144, frameCount: 8, fps: 24)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inputURL.path))

        let options = EnhanceVideoOptions(
            deband: true,
            debandConfig: DebandConfig(
                strength: 0.80,
                threshold: 0.025,
                ditherAmplitude: 1.0,
                protectSharpEdges: true,
                edgeThreshold: 0.045
            ),
            upscaleWidth: nil,
            upscaleHeight: nil,
            codec: .hevc10,
            bitrate: 3_500_000
        )

        let report = try await EnhancementPipeline.enhanceVideo(
            inputURL: inputURL,
            outputURL: outputURL,
            options: options
        )

        XCTAssertEqual(report.framesProcessed, 8)
        XCTAssertEqual(report.outputPath, outputURL.path)
        XCTAssertNil(report.upscaledTo)
        XCTAssertGreaterThan(report.elapsedMs, 0.0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertGreaterThan(report.beforeCAMBI, 1.0, "Synthetic banded MP4 should have measurable input CAMBI")
        XCTAssertLessThan(
            report.afterCAMBI,
            report.beforeCAMBI,
            "Enhanced frames should have lower CAMBI (before=\(report.beforeCAMBI), after=\(report.afterCAMBI))"
        )
        XCTAssertGreaterThan(report.cambiReductionPct, 20.0)

        // Verify NativePerceptualMetrics.evaluateVideo on both output alone and full-reference
        let nrReport = try await NativePerceptualMetrics.evaluateVideo(url: outputURL, referenceURL: nil, maxSamples: 6)
        XCTAssertGreaterThan(nrReport.framesSampled, 0)
        XCTAssertNil(nrReport.sourceMeanCAMBI)
        XCTAssertGreaterThanOrEqual(nrReport.perceptualScore, 0.0)
        XCTAssertLessThanOrEqual(nrReport.perceptualScore, 100.0)

        let frReport = try await NativePerceptualMetrics.evaluateVideo(
            url: outputURL,
            referenceURL: inputURL,
            maxSamples: 6
        )
        XCTAssertGreaterThan(frReport.framesSampled, 0)
        XCTAssertNotNil(frReport.sourceMeanCAMBI)
        XCTAssertNotNil(frReport.cambiDelta)
        XCTAssertGreaterThan(frReport.perceptualScore, 75.0)

        // Verify JSON round-trip of reports
        let repJSON = try JSONEncoder().encode(report)
        let repDecoded = try JSONDecoder().decode(EnhanceVideoReport.self, from: repJSON)
        XCTAssertEqual(repDecoded, report)
    }

    // MARK: - 5. FutureCodecReadiness Honest AV1 Hardware Probe

    func testFutureCodecReadinessProbeAV1ReturnsHonestStructuredJSON() throws {
        let report = FutureCodecReadiness.probeAV1Readiness(useCache: false)
        let snapshot = EncoderCapabilityProfiler.probeLive(useCache: true)
        let expectedHW = snapshot.profile(for: "av01")?.hardwareAccelerated ?? false

        XCTAssertEqual(report.codecFourCC, "av01")
        XCTAssertEqual(report.codecName, "AV1")
        XCTAssertEqual(report.hardwareEncodeSupported, expectedHW)
        XCTAssertEqual(report.recommendedFallbackCodec, "hvc1")
        XCTAssertTrue(report.autoEnableWhenAvailable)
        XCTAssertFalse(report.chipName.isEmpty)
        XCTAssertFalse(report.osVersion.isEmpty)
        XCTAssertFalse(report.summary.isEmpty)

        let validStatuses: Set<String> = [
            "ready_hardware",
            "software_only",
            "awaiting_silicon_hw_av1_encoder",
        ]
        XCTAssertTrue(validStatuses.contains(report.status), "Unexpected status: \(report.status)")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let jsonData = try encoder.encode(report)
        let decoded = try JSONDecoder().decode(FutureCodecReadinessReport.self, from: jsonData)
        XCTAssertEqual(decoded, report)
    }

    // MARK: - Synthetic Test Fixture Helpers

    private func ign(_ x: Double, _ y: Double) -> Double {
        let dot = 0.06711056 * x + 0.00583715 * y
        let f1 = dot - floor(dot)
        let s = 52.9829189 * f1
        return s - floor(s)
    }

    private func createPixelBuffer(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pbOut: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs as CFDictionary, &pbOut)
        XCTAssertEqual(status, kCVReturnSuccess)
        return try XCTUnwrap(pbOut)
    }

    private func makeBandedGradientWithSharpBoxBGRA(width: Int, height: Int) throws -> CVPixelBuffer {
        let pb = try createPixelBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pb)).assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)

        for y in 0..<height {
            let row = y * bpr
            for x in 0..<width {
                let off = row + x * 4
                // Banded dark gradient across entire frame (16px wide bands, levels 18..33)
                var val = UInt8(18 + (x * 16) / width)

                // Sharp high-contrast black card + white text-like horizontal & vertical bars in bottom-right
                if x >= width - 76 && x < width - 12 && y >= height - 60 && y < height - 12 {
                    val = 0
                    let inOuterBar = (x >= width - 66 && x < width - 22 && y >= height - 50 && y < height - 42)
                    let inLowerBar = (x >= width - 66 && x < width - 22 && y >= height - 30 && y < height - 22)
                    let inStem = (x >= width - 48 && x < width - 40 && y >= height - 50 && y < height - 22)
                    if inOuterBar || inLowerBar || inStem {
                        val = 250
                    }
                }

                base[off + 0] = val
                base[off + 1] = val
                base[off + 2] = val
                base[off + 3] = 255
            }
        }
        return pb
    }

    private func makeBandedGradientP010(width: Int, height: Int) throws -> CVPixelBuffer {
        let pb = try createPixelBuffer(
            width: width,
            height: height,
            format: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        let yBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb, 0)).assumingMemoryBound(to: UInt16.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0) / 2
        for y in 0..<height {
            let row = y * yStride
            for x in 0..<width {
                // 8-bit quantized dark gradient widened into 10-bit (steps of 4 codes in 10-bit)
                let level8 = UInt16(20 + (x * 16) / width)
                let code10 = level8 &<< 2
                yBase[row + x] = code10 &<< 6
            }
        }

        let uvBase = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pb, 1)).assumingMemoryBound(to: UInt16.self)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1) / 2
        let uvH = CVPixelBufferGetHeightOfPlane(pb, 1)
        let uvW = CVPixelBufferGetWidthOfPlane(pb, 1)
        let neutralChroma: UInt16 = 512 &<< 6
        for y in 0..<uvH {
            let row = y * uvStride
            for x in 0..<uvW {
                uvBase[row + x * 2 + 0] = neutralChroma
                uvBase[row + x * 2 + 1] = neutralChroma
            }
        }
        return pb
    }

    private func makeSharpTestPatternBGRA(width: Int, height: Int) throws -> CVPixelBuffer {
        let pb = try createPixelBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pb)).assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            let row = y * bpr
            for x in 0..<width {
                let off = row + x * 4
                let checker = ((x / 16) + (y / 16)) % 2 == 0
                let isBar = (x >= 40 && x < 280 && y >= 70 && y < 110)
                let r: UInt8 = isBar ? 245 : (checker ? 200 : 40)
                let g: UInt8 = isBar ? 245 : UInt8((x * 220) / width)
                let b: UInt8 = isBar ? 245 : UInt8((y * 220) / height)
                base[off + 0] = b
                base[off + 1] = g
                base[off + 2] = r
                base[off + 3] = 255
            }
        }
        return pb
    }

    private func meanBGRA8Luma(_ pb: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return 0.0 }
        var sum: Double = 0.0
        for y in 0..<h {
            let row = y * bpr
            for x in 0..<w {
                let off = row + x * 4
                let b = Double(base[off + 0])
                let g = Double(base[off + 1])
                let r = Double(base[off + 2])
                sum += 0.2126 * r + 0.7152 * g + 0.0722 * b
            }
        }
        return sum / Double(max(1, w * h))
    }

    private func meanEdgeGradientBGRA8(_ pb: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return 0.0 }
        var sum: Double = 0.0
        var count = 0
        for y in 1..<(h - 1) {
            let row = y * bpr
            for x in 1..<(w - 1) {
                let cR = Double(base[row + (x + 1) * 4 + 1])
                let cL = Double(base[row + (x - 1) * 4 + 1])
                let cD = Double(base[(y + 1) * bpr + x * 4 + 1])
                let cU = Double(base[(y - 1) * bpr + x * 4 + 1])
                sum += abs(cR - cL) + abs(cD - cU)
                count += 1
            }
        }
        return sum / Double(max(1, count))
    }

    private func writeSyntheticBandedMP4(
        to url: URL,
        width: Int,
        height: Int,
        frameCount: Int,
        fps: Int32
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let pb = try makeBandedGradientWithSharpBoxBGRA(width: width, height: height)
        for i in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let pts = CMTime(value: CMTimeValue(i), timescale: fps)
            XCTAssertTrue(adaptor.append(pb, withPresentationTime: pts))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
