import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SafariumContainers
import SafariumCore
import VideoToolbox
import XCTest

/// Wave 11B, 11C & 12B conformance tests:
/// - Pure-Swift ISOBMFF / CMAF / MPEG-TS binary parser + independent AVAssetReader decode (`BitstreamConformance`)
/// - Shared-IDR HLS packager + RFC 8216 / Apple HLS Authoring validator (`HLSPackager` + `HLSConformanceValidator`)
/// - HDR dynamic metadata safety policy, synthetic 10-bit P010 PQ/HLG buffers, and display attachment checks (`HDRIntegrity`)
final class Wave11BitstreamAndHLSConformanceTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf-wave11-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Encodes a real synthetic animated video via native VideoToolbox / AVAssetWriter (0% FFmpeg).
    private func encodeSyntheticVideo(
        at url: URL,
        fileType: AVFileType,
        width: Int = 320,
        height: Int = 180,
        fps: Int = 30,
        durationSeconds: Double = 1.5,
        codec: VideoCodec,
        includeAudio: Bool = false
    ) async throws {
        let totalFrames = max(1, Int((durationSeconds * Double(fps)).rounded()))
        let writer = try AVAssetWriter(url: url, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = (fileType == .mp4)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: ColorMasteringProfile.sdrBT709.avColorProperties,
        ]
        if !codec.isProRes {
            var compProps: [String: Any] = [
                AVVideoAverageBitRateKey: 2_000_000,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
            ]
            if let profile = codec.defaultProfileLevel {
                compProps[AVVideoProfileLevelKey] = profile
            } else if codec == .h264 {
                compProps[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            videoSettings[AVVideoCompressionPropertiesKey] = compProps
        }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let pixelFormat: OSType = codec.is10Bit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_32BGRA
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
        )
        XCTAssertTrue(writer.canAdd(videoInput))
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if includeAudio {
            let aSettings = ProAudioEncoder.outputSettings(codec: .aacMax, sampleRate: 48_000, channels: 2, bitrate: 128_000)
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings)
            aIn.expectsMediaDataInRealTime = false
            if writer.canAdd(aIn) {
                writer.add(aIn)
                audioInput = aIn
            }
        }

        XCTAssertTrue(writer.startWriting(), "startWriting failed: \(writer.error?.localizedDescription ?? "?")")
        writer.startSession(atSourceTime: .zero)

        let pool = try XCTUnwrap(adaptor.pixelBufferPool)

        // Optional stereo 48kHz PCM format description
        let sampleRate = 48_000
        let channels = 2
        let totalAudioSamples = includeAudio ? Int((durationSeconds * Double(sampleRate)).rounded()) : 0
        var audioFmt: CMAudioFormatDescription?
        if includeAudio {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Double(sampleRate),
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(channels * 4),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(channels * 4),
                mChannelsPerFrame: UInt32(channels),
                mBitsPerChannel: 32,
                mReserved: 0
            )
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &audioFmt
            )
        }

        var frameIdx = 0
        var audioOffset = 0
        let hasAudio = (audioInput != nil && audioFmt != nil && totalAudioSamples > 0)
        var vDone = false
        var aDone = !hasAudio

        while frameIdx < totalFrames || (hasAudio && audioOffset < totalAudioSamples) {
            if frameIdx >= totalFrames && !vDone {
                videoInput.markAsFinished()
                vDone = true
            }
            if (!hasAudio || audioOffset >= totalAudioSamples) && !aDone {
                audioInput?.markAsFinished()
                aDone = true
            }

            let vReady = (frameIdx < totalFrames) && videoInput.isReadyForMoreMediaData
            let aReady = (hasAudio && audioOffset < totalAudioSamples) && (audioInput?.isReadyForMoreMediaData ?? false)
            if !vReady && !aReady {
                if writer.status != .writing {
                    XCTFail("Writer failed: \(writer.error?.localizedDescription ?? "?")")
                    break
                }
                try await Task.sleep(nanoseconds: 500_000)
                continue
            }

            let doVideo: Bool
            if vReady && aReady {
                doVideo = (Double(frameIdx) / Double(fps)) <= (Double(audioOffset) / Double(sampleRate))
            } else {
                doVideo = vReady
            }

            if doVideo {
                var pbOpt: CVPixelBuffer?
                XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOpt), kCVReturnSuccess)
                let pb = try XCTUnwrap(pbOpt)
                if codec.is10Bit {
                    fillAnimatedP010(pb, frame: frameIdx)
                } else {
                    fillAnimatedBGRA(pb, frame: frameIdx)
                }
                ColorMasteringProfile.sdrBT709.tagPixelBuffer(pb)
                let pts = CMTime(value: CMTimeValue(frameIdx), timescale: CMTimeScale(fps))
                XCTAssertTrue(adaptor.append(pb, withPresentationTime: pts))
                frameIdx += 1
            } else if let aIn = audioInput, let fmt = audioFmt {
                let count = min(1024, totalAudioSamples - audioOffset)
                var pcm = [Float](repeating: 0, count: count * channels)
                for i in 0..<count {
                    let t = Double(audioOffset + i) / Double(sampleRate)
                    pcm[i * 2 + 0] = Float(0.25 * sin(2.0 * Double.pi * 440.0 * t))
                    pcm[i * 2 + 1] = Float(0.25 * sin(2.0 * Double.pi * 660.0 * t))
                }
                let byteCount = pcm.count * MemoryLayout<Float>.size
                var blockOpt: CMBlockBuffer?
                CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault,
                    memoryBlock: nil,
                    blockLength: byteCount,
                    blockAllocator: kCFAllocatorDefault,
                    customBlockSource: nil,
                    offsetToData: 0,
                    dataLength: byteCount,
                    flags: 0,
                    blockBufferOut: &blockOpt
                )
                if let block = blockOpt {
                    pcm.withUnsafeBytes { raw in
                        _ = CMBlockBufferReplaceDataBytes(
                            with: raw.baseAddress!,
                            blockBuffer: block,
                            offsetIntoDestination: 0,
                            dataLength: byteCount
                        )
                    }
                    var timing = CMSampleTimingInfo(
                        duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                        presentationTimeStamp: CMTime(value: CMTimeValue(audioOffset), timescale: CMTimeScale(sampleRate)),
                        decodeTimeStamp: .invalid
                    )
                    var sbOpt: CMSampleBuffer?
                    CMSampleBufferCreateReady(
                        allocator: kCFAllocatorDefault,
                        dataBuffer: block,
                        formatDescription: fmt,
                        sampleCount: count,
                        sampleTimingEntryCount: 1,
                        sampleTimingArray: &timing,
                        sampleSizeEntryCount: 0,
                        sampleSizeArray: nil,
                        sampleBufferOut: &sbOpt
                    )
                    if let sb = sbOpt { _ = aIn.append(sb) }
                }
                audioOffset += count
            }
        }
        if !vDone { videoInput.markAsFinished() }
        if !aDone { audioInput?.markAsFinished() }

        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "finishWriting failed: \(writer.error?.localizedDescription ?? "?")")
    }

    private func fillAnimatedBGRA(_ pb: CVPixelBuffer, frame: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let boxX = (frame * 7) % max(1, w - 48)
        let boxY = (frame * 5) % max(1, h - 36)
        let phase = UInt8((frame * 11) % 256)
        for y in 0..<h {
            let row = base.advanced(by: y * bpr)
            let gVal = UInt8((y * 220) / max(1, h))
            for x in 0..<w {
                let off = x * 4
                if x >= boxX && x < boxX + 48 && y >= boxY && y < boxY + 36 {
                    row[off + 0] = 30
                    row[off + 1] = 240
                    row[off + 2] = 250
                    row[off + 3] = 255
                } else {
                    row[off + 0] = phase
                    row[off + 1] = gVal
                    row[off + 2] = UInt8((x * 230) / max(1, w))
                    row[off + 3] = 255
                }
            }
        }
    }

    private func fillAnimatedP010(_ pb: CVPixelBuffer, frame: Int) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let boxX = (frame * 7) % max(1, w - 48)
        let boxY = (frame * 5) % max(1, h - 36)

        if let yPtr = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt16.self) {
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0) / 2
            for y in 0..<h {
                let row = yPtr.advanced(by: y * yStride)
                for x in 0..<w {
                    let inBox = (x >= boxX && x < boxX + 48 && y >= boxY && y < boxY + 36)
                    let val10: UInt16 = inBox ? 860 : UInt16(120 + ((x * 650) / max(1, w)))
                    row[x] = val10 << 6
                }
            }
        }
        if let uvPtr = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt16.self) {
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1) / 2
            let uvW = CVPixelBufferGetWidthOfPlane(pb, 1)
            let uvH = CVPixelBufferGetHeightOfPlane(pb, 1)
            let cbShift = UInt16(360 + ((frame * 13) % 300))
            for y in 0..<uvH {
                let row = uvPtr.advanced(by: y * uvStride)
                for x in 0..<uvW {
                    row[x * 2 + 0] = cbShift << 6
                    row[x * 2 + 1] = UInt16(340 + ((y * 320) / max(1, uvH))) << 6
                }
            }
        }
    }

    // MARK: - 1. Wave 11B: BitstreamConformance on Real VideoToolbox Encodes

    func testBitstreamConformanceH264HEVC8BitHEVC10BitAndProRes422HQ() async throws {
        let dir = try makeTempDir("bitstream")
        defer { try? FileManager.default.removeItem(at: dir) }

        // (a) H.264 (avc1) + AAC audio
        let h264URL = dir.appendingPathComponent("test_h264.mp4")
        try await encodeSyntheticVideo(
            at: h264URL, fileType: .mp4, width: 320, height: 180, fps: 30,
            durationSeconds: 1.0, codec: .h264, includeAudio: true
        )
        let h264Report = try await BitstreamConformance.verifyMediaFile(
            url: h264URL,
            expectedCodec: "avc1",
            expectedBitDepth: 8,
            expectedChroma: 1,
            expectedPrimaries: 1, // BT.709
            requireIndependentDecode: true
        )
        XCTAssertTrue(h264Report.passed, "H.264 violations: \(h264Report.violations)")
        XCTAssertTrue(h264Report.violations.isEmpty)
        XCTAssertEqual(h264Report.detectedVideoCodec, "avc1")
        XCTAssertEqual(h264Report.detectedAudioCodec, "mp4a")
        XCTAssertNotNil(h264Report.isobmff?.avcConfig)
        XCTAssertGreaterThan(h264Report.isobmff?.avcConfig?.avcProfileIndication ?? 0, 0)
        XCTAssertGreaterThan(h264Report.isobmff?.avcConfig?.avcLevelIndication ?? 0, 0)
        XCTAssertGreaterThanOrEqual(h264Report.independentDecode?.decodedVideoFrames ?? 0, 25)
        XCTAssertEqual(h264Report.independentDecode?.monotonicPTS, true)
        XCTAssertEqual(h264Report.independentDecode?.nonZeroPixelVariance, true)
        XCTAssertGreaterThan(h264Report.independentDecode?.decodedAudioBuffers ?? 0, 0)

        // (b) HEVC 8-bit (hvc1 Main)
        let hevc8URL = dir.appendingPathComponent("test_hevc8.mp4")
        try await encodeSyntheticVideo(
            at: hevc8URL, fileType: .mp4, width: 320, height: 180, fps: 30,
            durationSeconds: 1.0, codec: .hevc, includeAudio: false
        )
        let hevc8Report = try await BitstreamConformance.verifyMediaFile(
            url: hevc8URL,
            expectedCodec: "hvc1",
            expectedBitDepth: 8,
            expectedChroma: 1,
            expectedPrimaries: 1,
            requireIndependentDecode: true
        )
        XCTAssertTrue(hevc8Report.passed, "HEVC 8-bit violations: \(hevc8Report.violations)")
        XCTAssertEqual(hevc8Report.detectedVideoCodec, "hvc1")
        let hvc8 = try XCTUnwrap(hevc8Report.isobmff?.hevcConfig)
        XCTAssertEqual(hvc8.generalProfileIdc, 1, "HEVC 8-bit must signal Main profile (general_profile_idc == 1)")
        XCTAssertEqual(hvc8.bitDepthLuma, 8)
        XCTAssertEqual(hvc8.chromaFormatIdc, 1)
        XCTAssertGreaterThan(hvc8.numOfArrays, 0)

        // (c) HEVC 10-bit (hvc1 Main10)
        let hevc10URL = dir.appendingPathComponent("test_hevc10.mp4")
        try await encodeSyntheticVideo(
            at: hevc10URL, fileType: .mp4, width: 320, height: 180, fps: 30,
            durationSeconds: 1.0, codec: .hevc10, includeAudio: false
        )
        let hevc10Report = try await BitstreamConformance.verifyMediaFile(
            url: hevc10URL,
            expectedCodec: "hvc1",
            expectedBitDepth: 10,
            expectedChroma: 1,
            expectedPrimaries: 1,
            requireIndependentDecode: true
        )
        XCTAssertTrue(hevc10Report.passed, "HEVC 10-bit violations: \(hevc10Report.violations)")
        XCTAssertEqual(hevc10Report.detectedVideoCodec, "hvc1")
        let hvc10 = try XCTUnwrap(hevc10Report.isobmff?.hevcConfig)
        XCTAssertEqual(hvc10.bitDepthLuma, 10, "HEVC Main10 hvcC must report bitDepth == 10")
        XCTAssertEqual(hvc10.generalProfileIdc, 2, "HEVC Main10 hvcC must report general_profile_idc == 2")
        XCTAssertEqual(hvc10.chromaFormatIdc, 1)
        XCTAssertGreaterThan(hvc10.numOfArrays, 0)
        XCTAssertEqual(hevc10Report.independentDecode?.nonZeroPixelVariance, true)

        // (d) ProRes 422 HQ (apch)
        let proresURL = dir.appendingPathComponent("test_prores_hq.mov")
        try await encodeSyntheticVideo(
            at: proresURL, fileType: .mov, width: 320, height: 180, fps: 30,
            durationSeconds: 0.5, codec: .proRes422HQ, includeAudio: false
        )
        let proresReport = try await BitstreamConformance.verifyMediaFile(
            url: proresURL,
            expectedCodec: "apch",
            expectedBitDepth: 10,
            expectedChroma: 2,
            expectedPrimaries: 1,
            requireIndependentDecode: true
        )
        XCTAssertTrue(proresReport.passed, "ProRes 422 HQ violations: \(proresReport.violations)")
        XCTAssertEqual(proresReport.detectedVideoCodec, "apch")
        XCTAssertEqual(proresReport.detectedBitDepth, 10)
        XCTAssertEqual(proresReport.detectedChromaFormat, 2)
        XCTAssertEqual(proresReport.independentDecode?.monotonicPTS, true)
        XCTAssertEqual(proresReport.independentDecode?.nonZeroPixelVariance, true)
    }

    func testMPEGTSInspectorDetectsSyncAndContinuityViolations() {
        // Construct a minimal broken 2-packet TS buffer with invalid sync byte on packet 2
        var badTS = Data(repeating: 0xFF, count: 188 * 2)
        badTS[0] = 0x47
        badTS[188] = 0x00 // broken sync byte
        let res = BitstreamConformance.inspectMPEGTS(data: badTS)
        XCTAssertFalse(res.isValid)
        XCTAssertEqual(res.syncErrors, 1)
        XCTAssertFalse(res.hasPAT)
    }

    // MARK: - 2. Wave 11C: HLSPackager + HLSConformanceValidator End-to-End (CMAF + MPEG-TS)

    func testHLSCMAF2RungWithWebVTTPassesConformanceAndSharedIDRAlignment() async throws {
        let dir = try makeTempDir("hls-cmaf-2rung")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("source_640x360.mp4")
        try await encodeSyntheticVideo(
            at: srcURL, fileType: .mp4, width: 640, height: 360, fps: 30,
            durationSeconds: 3.0, codec: .h264, includeAudio: true
        )

        let vttURL = dir.appendingPathComponent("subs.vtt")
        let vttText = """
        WEBVTT

        00:00:00.000 --> 00:00:01.500
        Safarium Wave 11C CMAF Conformance

        00:00:01.500 --> 00:00:03.000
        Shared IDR & Real Measured Bandwidth
        """
        try Data(vttText.utf8).write(to: vttURL)

        let hlsDir = dir.appendingPathComponent("hls_cmaf", isDirectory: true)
        let options = HLSPackageOptions(
            rungs: [
                HLSRung(name: "180p", width: 320, height: 180, bitrate: 450_000, fps: 30, codec: .hevc, audioBitrate: 96_000),
                HLSRung(name: "360p", width: 640, height: 360, bitrate: 1_200_000, fps: 30, codec: .hevc10, audioBitrate: 128_000),
            ],
            segmentDurationSeconds: 1.5,
            format: .fmp4CMAF,
            codec: .hevc10,
            subtitleVTTPath: vttURL,
            subtitleLanguage: "en",
            subtitleName: "English"
        )

        let pkg = try await HLSPackager.package(inputURL: srcURL, outputDirectory: hlsDir, options: options)
        XCTAssertEqual(pkg.variants.count, 2)
        XCTAssertEqual(pkg.sharedIDRBoundaries.first, 0.0)
        XCTAssertGreaterThanOrEqual(pkg.sharedIDRBoundaries.count, 2)

        let report = try await HLSConformanceValidator.validate(directory: hlsDir)
        XCTAssertTrue(report.passed, "CMAF HLS conformance violations: \(report.violations)")
        XCTAssertTrue(report.violations.isEmpty)
        XCTAssertTrue(report.hasIndependentSegments)
        XCTAssertEqual(report.masterVersion, 7)
        XCTAssertEqual(report.variants.count, 2)
        XCTAssertEqual(report.subtitles.count, 1)
        XCTAssertTrue(report.subtitles[0].hasWebVTTHeader)
        XCTAssertTrue(report.crossRungSegmentCountAligned, "CMAF rungs must have identical segment counts")
        XCTAssertLessThanOrEqual(report.crossRungDurationMaxDeltaSeconds, 0.25)

        for variant in report.variants {
            XCTAssertEqual(variant.segmentContainerKind, "cmaf")
            XCTAssertGreaterThanOrEqual(variant.segmentCount, 2)
            XCTAssertEqual(variant.initInspection?.hasFtyp, true)
            XCTAssertEqual(variant.initInspection?.hasMoov, true)
            XCTAssertGreaterThanOrEqual(
                Double(variant.declaredBandwidth),
                Double(variant.actualPeakSegmentBitrate) * 0.90,
                "Declared BANDWIDTH (\(variant.declaredBandwidth)) must cover measured peak (\(variant.actualPeakSegmentBitrate))"
            )
            if let avg = variant.declaredAverageBandwidth {
                XCTAssertLessThanOrEqual(avg, variant.declaredBandwidth)
            }
        }
    }

    func testHLSMPEGTS2RungPassesConformanceAndSharedIDRAlignment() async throws {
        let dir = try makeTempDir("hls-ts-2rung")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("source_ts_640x360.mp4")
        try await encodeSyntheticVideo(
            at: srcURL, fileType: .mp4, width: 640, height: 360, fps: 30,
            durationSeconds: 3.0, codec: .h264, includeAudio: false
        )

        let hlsDir = dir.appendingPathComponent("hls_ts", isDirectory: true)
        let options = HLSPackageOptions(
            rungs: [
                HLSRung(name: "180p", width: 320, height: 180, bitrate: 500_000, fps: 30, codec: .h264),
                HLSRung(name: "360p", width: 640, height: 360, bitrate: 1_200_000, fps: 30, codec: .hevc),
            ],
            segmentDurationSeconds: 1.0,
            format: .mpegTS,
            codec: .h264
        )

        let pkg = try await HLSPackager.package(inputURL: srcURL, outputDirectory: hlsDir, options: options)
        XCTAssertEqual(pkg.variants.count, 2)
        XCTAssertEqual(pkg.sharedIDRBoundaries, [0.0, 1.0, 2.0])

        let report = try await HLSConformanceValidator.validate(directory: hlsDir)
        XCTAssertTrue(report.passed, "MPEG-TS HLS conformance violations: \(report.violations)")
        XCTAssertTrue(report.violations.isEmpty)
        XCTAssertTrue(report.hasIndependentSegments)
        XCTAssertEqual(report.masterVersion, 3)
        XCTAssertEqual(report.variants.count, 2)
        XCTAssertTrue(report.crossRungSegmentCountAligned, "MPEG-TS rungs must cut identical segment counts")
        XCTAssertLessThanOrEqual(report.crossRungDurationMaxDeltaSeconds, 0.05, "MPEG-TS shared-IDR cadence must align segment durations tightly")

        for variant in report.variants {
            XCTAssertEqual(variant.segmentContainerKind, "mpegts")
            XCTAssertEqual(variant.segmentCount, 3)
            XCTAssertGreaterThanOrEqual(
                Double(variant.declaredBandwidth),
                Double(variant.actualPeakSegmentBitrate) * 0.90
            )
            if let avg = variant.declaredAverageBandwidth {
                XCTAssertLessThanOrEqual(avg, variant.declaredBandwidth)
            }
        }
    }

    // MARK: - 3. Wave 12B: HDRIntegrity Policy, Synthetic P010 HDR Buffers & Display Attachment Validation

    func testHDRIntegrityRefusesBlindPreservationOfStaleDynamicMetadata() throws {
        // Strict rule: pixelsModified == true && sourceHasDynamicMetadata == true && requested == .preserve
        // MUST NOT blindly preserve stale Dolby Vision dynamic metadata!
        let forcedRecompute = HDRIntegrity.resolvePolicy(
            sourceIsHDR: true,
            sourceHasDynamicMetadata: true,
            pixelsModified: true,
            requestedPolicy: .preserve,
            dynamicRecomputeAvailable: true
        )
        XCTAssertFalse(forcedRecompute.preserveDynamicMetadata, "Stale Dolby Vision metadata must NEVER be preserved when pixels were modified")
        XCTAssertEqual(forcedRecompute.effectivePolicy, .recompute)
        XCTAssertTrue(forcedRecompute.recomputeDynamicMetadata)
        XCTAssertTrue(forcedRecompute.forcedOverride)
        XCTAssertFalse(forcedRecompute.warnings.isEmpty)

        // When recompute is unavailable, must fall back to .stripDynamicMetadata (still NEVER preserving stale metadata)
        let forcedStrip = HDRIntegrity.resolvePolicy(
            sourceIsHDR: true,
            sourceHasDynamicMetadata: true,
            pixelsModified: true,
            requestedPolicy: .preserve,
            dynamicRecomputeAvailable: false
        )
        XCTAssertFalse(forcedStrip.preserveDynamicMetadata)
        XCTAssertEqual(forcedStrip.effectivePolicy, .stripDynamicMetadata)
        XCTAssertTrue(forcedStrip.stripDynamicMetadata)
        XCTAssertTrue(forcedStrip.forcedOverride)
        XCTAssertFalse(forcedStrip.warnings.isEmpty)

        // Default 4-argument call also enforces the invariant cleanly
        let defaultCall = HDRIntegrity.resolvePolicy(
            sourceIsHDR: true,
            sourceHasDynamicMetadata: true,
            pixelsModified: true,
            requestedPolicy: .preserve
        )
        XCTAssertFalse(defaultCall.preserveDynamicMetadata)
        XCTAssertTrue(defaultCall.forcedOverride)

        // Unmodified pixels CAN safely preserve dynamic metadata
        let unmodified = HDRIntegrity.resolvePolicy(
            sourceIsHDR: true,
            sourceHasDynamicMetadata: true,
            pixelsModified: false,
            requestedPolicy: .preserve
        )
        XCTAssertTrue(unmodified.preserveDynamicMetadata)
        XCTAssertEqual(unmodified.effectivePolicy, .preserve)
        XCTAssertFalse(unmodified.forcedOverride)
        XCTAssertTrue(unmodified.warnings.isEmpty)

        // Tone-mapping to SDR strips dynamic metadata and marks toneMapToSDR
        let toneMap = HDRIntegrity.resolvePolicy(
            sourceIsHDR: true,
            sourceHasDynamicMetadata: true,
            pixelsModified: true,
            requestedPolicy: .toneMapToSDR
        )
        XCTAssertFalse(toneMap.preserveDynamicMetadata)
        XCTAssertTrue(toneMap.stripDynamicMetadata)
        XCTAssertTrue(toneMap.toneMapToSDR)

        // Verify applySessionMetadataPolicy works cleanly on a real VTCompressionSession
        var sessionOpt: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 192,
            height: 108,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &sessionOpt
        )
        XCTAssertEqual(st, noErr)
        if let session = sessionOpt {
            defer { VTCompressionSessionInvalidate(session) }
            HDRIntegrity.applySessionMetadataPolicy(session, policy: forcedRecompute)
            HDRIntegrity.applySessionMetadataPolicy(session, policy: unmodified)
        }
    }

    func testHDRIntegritySyntheticP010BuffersAndDisplayAttachmentValidationPQAndHLG() throws {
        for mode in [HDRMode.hdr10PQ, HDRMode.hlgBT2100] {
            let pb = try HDRIntegrity.createSyntheticHDRTestBuffer(width: 160, height: 90, transfer: mode)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(pb), kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            XCTAssertEqual(CVPixelBufferGetWidth(pb), 160)
            XCTAssertEqual(CVPixelBufferGetHeight(pb), 90)

            let audit = HDRIntegrity.auditPixelBuffer(pb, sampleEntryFourCC: "hvc1")
            XCTAssertTrue(audit.passed, "HDR audit failed for \(mode): \(audit.issues)")
            XCTAssertTrue(audit.is10Bit)
            XCTAssertTrue(audit.hasMasteringDisplay)
            XCTAssertTrue(audit.hasContentLightLevel)
            XCTAssertTrue((audit.primaries ?? "").contains("2020"))
            if mode == .hdr10PQ {
                XCTAssertTrue((audit.transfer ?? "").contains("2084"))
            } else {
                XCTAssertTrue((audit.transfer ?? "").contains("HLG"))
            }

            // Wrap CVPixelBuffer in a CMSampleBuffer and validate for AVSampleBufferDisplayLayer
            var fmtOpt: CMVideoFormatDescription?
            let fmtSt = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pb,
                formatDescriptionOut: &fmtOpt
            )
            XCTAssertEqual(fmtSt, noErr)
            let fmt = try XCTUnwrap(fmtOpt)

            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: .zero,
                decodeTimeStamp: .invalid
            )
            var sbOpt: CMSampleBuffer?
            let sbSt = CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pb,
                formatDescription: fmt,
                sampleTiming: &timing,
                sampleBufferOut: &sbOpt
            )
            XCTAssertEqual(sbSt, noErr)
            let sb = try XCTUnwrap(sbOpt)

            let displayIssues = HDRIntegrity.validateDisplayAttachment(sampleBuffer: sb)
            XCTAssertTrue(displayIssues.isEmpty, "Display attachment issues for \(mode): \(displayIssues)")
        }

        // Negative test: untagged 8-bit BGRA buffer tagged with PQ transfer must report display attachment issues
        var badPBOpt: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &badPBOpt),
            kCVReturnSuccess
        )
        let badPB = try XCTUnwrap(badPBOpt)
        CVBufferSetAttachment(badPB, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(badPB, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
        CVBufferSetAttachment(badPB, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

        var badFmtOpt: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: badPB, formatDescriptionOut: &badFmtOpt),
            noErr
        )
        var badTiming = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var badSBOpt: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: badPB,
                formatDescription: try XCTUnwrap(badFmtOpt),
                sampleTiming: &badTiming,
                sampleBufferOut: &badSBOpt
            ),
            noErr
        )
        let badIssues = HDRIntegrity.validateDisplayAttachment(sampleBuffer: try XCTUnwrap(badSBOpt))
        XCTAssertGreaterThanOrEqual(badIssues.count, 3, "8-bit BT.709 PQ buffer without mdcv/clli should report multiple display issues: \(badIssues)")
    }
}
