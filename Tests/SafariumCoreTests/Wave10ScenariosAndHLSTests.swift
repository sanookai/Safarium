import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import SafariumCore
import XCTest

/// Wave 10 — "Every Video Encoding Scenario" + Native HLS/CMAF Packager + Hardware HDR Tone-Mapper + Animated Clip Exporter tests.
final class Wave10ScenariosAndHLSTests: XCTestCase {

    // MARK: - Synthetic Media Helpers (100% Apple Native, 0% FFmpeg)

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf-wave10-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Generates a synthetic 3-second 640x360 H.264/HEVC video with optional sine-wave AAC audio using native AVAssetWriter.
    private func makeSyntheticVideo(
        at url: URL,
        width: Int = 640,
        height: Int = 360,
        fps: Int = 30,
        durationSeconds: Double = 3.0,
        codec: VideoCodec = .h264,
        includeAudio: Bool = true
    ) async throws {
        let totalFrames = max(1, Int((durationSeconds * Double(fps)).rounded()))
        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: ColorMasteringProfile.sdrBT709.avColorProperties,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_500_000,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
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

        XCTAssertTrue(writer.startWriting(), "synthetic writer startWriting failed: \(writer.error?.localizedDescription ?? "?")")
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            XCTFail("Missing pixelBufferPool on synthetic writer")
            return
        }

        let sampleRate = 48_000
        let channels = 2
        let totalAudioSamples = includeAudio ? Int((durationSeconds * Double(sampleRate)).rounded()) : 0
        let chunkFrames = 1024
        var fmtDescOpt: CMAudioFormatDescription?
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
                formatDescriptionOut: &fmtDescOpt
            )
        }

        // Interleave colorful animated video frames + 48 kHz stereo sine audio
        var f = 0
        var audioOffset = 0
        let hasAudio = (audioInput != nil && fmtDescOpt != nil && totalAudioSamples > 0)
        var vMarked = false
        var aMarked = !hasAudio

        while f < totalFrames || (hasAudio && audioOffset < totalAudioSamples) {
            if f >= totalFrames && !vMarked {
                videoInput.markAsFinished()
                vMarked = true
            }
            if (!hasAudio || audioOffset >= totalAudioSamples) && !aMarked {
                audioInput?.markAsFinished()
                aMarked = true
            }
            let vNeeds = f < totalFrames
            let aNeeds = hasAudio && audioOffset < totalAudioSamples
            let vReady = vNeeds && videoInput.isReadyForMoreMediaData
            let aReady = aNeeds && (audioInput?.isReadyForMoreMediaData ?? false)

            if !vReady && !aReady {
                if writer.status != .writing {
                    XCTFail("synthetic writer failed: \(writer.error?.localizedDescription ?? "?")")
                    break
                }
                try await Task.sleep(nanoseconds: 500_000)
                continue
            }

            let feedVideo: Bool
            if vReady && aReady {
                let vTime = Double(f) / Double(fps)
                let aTime = Double(audioOffset) / Double(sampleRate)
                feedVideo = vTime <= aTime
            } else {
                feedVideo = vReady
            }

            if feedVideo {
                var pbOpt: CVPixelBuffer?
                let st = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOpt)
                XCTAssertEqual(st, kCVReturnSuccess)
                if let pb = pbOpt {
                    CVPixelBufferLockBaseAddress(pb, [])
                    if let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) {
                        let bpr = CVPixelBufferGetBytesPerRow(pb)
                        let boxX = (f * 7) % max(1, width - 80)
                        let boxY = (f * 3) % max(1, height - 60)
                        let phase = UInt8((f * 9) % 256)
                        for y in 0..<height {
                            let row = base.advanced(by: y * bpr)
                            let gBase = UInt8((y * 200) / max(1, height))
                            for x in 0..<width {
                                let off = x * 4
                                let inBox = (x >= boxX && x < boxX + 80 && y >= boxY && y < boxY + 60)
                                if inBox {
                                    row[off + 0] = 40
                                    row[off + 1] = 230
                                    row[off + 2] = 245
                                    row[off + 3] = 255
                                } else {
                                    let rVal = UInt8((x * 220) / max(1, width))
                                    row[off + 0] = phase
                                    row[off + 1] = gBase
                                    row[off + 2] = rVal
                                    row[off + 3] = 255
                                }
                            }
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(pb, [])
                    ColorMasteringProfile.sdrBT709.tagPixelBuffer(pb)

                    let pts = CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps))
                    XCTAssertTrue(adaptor.append(pb, withPresentationTime: pts))
                }
                f += 1
            } else if let aIn = audioInput, let fmtDesc = fmtDescOpt {
                let count = min(chunkFrames, totalAudioSamples - audioOffset)
                var pcm = [Float](repeating: 0, count: count * channels)
                for i in 0..<count {
                    let t = Double(audioOffset + i) / Double(sampleRate)
                    let s0 = Float(0.25 * sin(2.0 * Double.pi * 440.0 * t))
                    let s1 = Float(0.25 * sin(2.0 * Double.pi * 660.0 * t))
                    pcm[i * 2] = s0
                    pcm[i * 2 + 1] = s1
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
                    let pts = CMTime(value: CMTimeValue(audioOffset), timescale: CMTimeScale(sampleRate))
                    var timing = CMSampleTimingInfo(
                        duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                        presentationTimeStamp: pts,
                        decodeTimeStamp: .invalid
                    )
                    var sbOpt: CMSampleBuffer?
                    CMSampleBufferCreateReady(
                        allocator: kCFAllocatorDefault,
                        dataBuffer: block,
                        formatDescription: fmtDesc,
                        sampleCount: count,
                        sampleTimingEntryCount: 1,
                        sampleTimingArray: &timing,
                        sampleSizeEntryCount: 0,
                        sampleSizeArray: nil,
                        sampleBufferOut: &sbOpt
                    )
                    if let sb = sbOpt {
                        _ = aIn.append(sb)
                    }
                }
                audioOffset += count
            }
        }
        if !vMarked { videoInput.markAsFinished() }
        if !aMarked { audioInput?.markAsFinished() }

        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "synthetic writer failed: \(writer.error?.localizedDescription ?? "?")")
    }

    // MARK: - 1. Encoding Scenarios & CLI Alias Parser

    func testAllEncodingScenariosHaveValidProfilesAndCodableRoundTrip() throws {
        XCTAssertEqual(EncodingScenario.allCases.count, 19)
        let profiles = EncodingScenario.allProfiles()
        XCTAssertEqual(profiles.count, EncodingScenario.allCases.count)

        let validContainers: Set<String> = ["mp4", "mov", "m3u8", "webp", "gif"]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for scenario in EncodingScenario.allCases {
            let p = EncodingScenario.profile(for: scenario)
            XCTAssertEqual(p.scenario, scenario)
            XCTAssertFalse(p.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty summary for \(scenario)")
            XCTAssertTrue(validContainers.contains(p.recommendedContainer), "Unexpected container \(p.recommendedContainer) for \(scenario)")
            XCTAssertGreaterThanOrEqual(p.lookAheadFrames, 0)
            XCTAssertGreaterThanOrEqual(p.maxGOPSeconds, 0.0)
            XCTAssertGreaterThanOrEqual(p.audioBitrate, 0)
            XCTAssertGreaterThanOrEqual(p.targetVideoBitrate, 0)

            // Video scenarios must have positive target video bitrate
            if scenario != .webpClip && scenario != .gifClip {
                XCTAssertGreaterThan(p.targetVideoBitrate, 0, "Scenario \(scenario) should have positive bitrate")
            }

            // Two-pass and LookAhead are mutually exclusive in VideoToolbox
            if p.useTwoPass {
                XCTAssertEqual(p.lookAheadFrames, 0, "Scenario \(scenario) must not mix 2-pass and lookahead")
            }

            // Codable round-trip
            let data = try encoder.encode(p)
            let decoded = try decoder.decode(EncodingScenarioProfile.self, from: data)
            XCTAssertEqual(decoded, p)

            // Bridge conversions succeed cleanly
            let supCfg = p.toSupremacyConfig(overwrite: true)
            XCTAssertEqual(supCfg.codec, p.codec)
            XCTAssertEqual(supCfg.colorMastering, p.hdrMode)
            let encProf = p.toEncoderProfile()
            XCTAssertEqual(encProf.colorMastering, p.hdrMode)
        }
    }

    func testEncodingScenarioCLIParserAliases() {
        // Direct raw values for all cases
        for scenario in EncodingScenario.allCases {
            XCTAssertEqual(EncodingScenario.parse(scenario.rawValue), scenario)
            XCTAssertEqual(EncodingScenario.parse(scenario.rawValue.uppercased()), scenario)
            XCTAssertEqual(EncodingScenario.parse(scenario.rawValue.replacingOccurrences(of: "-", with: "_")), scenario)
        }

        // Common CLI aliases
        XCTAssertEqual(EncodingScenario.parse("yt"), .youtube)
        XCTAssertEqual(EncodingScenario.parse("yt-4k"), .youtube4k)
        XCTAssertEqual(EncodingScenario.parse("youtube_shorts"), .shorts)
        XCTAssertEqual(EncodingScenario.parse("ig-reels"), .reels)
        XCTAssertEqual(EncodingScenario.parse("hls"), .webStreaming)
        XCTAssertEqual(EncodingScenario.parse("cmaf"), .webStreaming)
        XCTAssertEqual(EncodingScenario.parse("web"), .webCompat)
        XCTAssertEqual(EncodingScenario.parse("screencast"), .screenRecording)
        XCTAssertEqual(EncodingScenario.parse("prores"), .cinemaMaster)
        XCTAssertEqual(EncodingScenario.parse("vfx"), .cinemaVFX)
        XCTAssertEqual(EncodingScenario.parse("alpha"), .transparentVFX)
        XCTAssertEqual(EncodingScenario.parse("dv"), .hdrDolbyVision)
        XCTAssertEqual(EncodingScenario.parse("dolby-vision"), .hdrDolbyVision)
        XCTAssertEqual(EncodingScenario.parse("hdr10-pq"), .hdr10)
        XCTAssertEqual(EncodingScenario.parse("visionos"), .spatialVisionOS)
        XCTAssertEqual(EncodingScenario.parse("mv-hevc"), .spatialVisionOS)
        XCTAssertEqual(EncodingScenario.parse("archive"), .archival)
        XCTAssertEqual(EncodingScenario.parse("live"), .liveLowLatency)
        XCTAssertEqual(EncodingScenario.parse("podcast"), .podcastVideo)
        XCTAssertEqual(EncodingScenario.parse("webp"), .webpClip)
        XCTAssertEqual(EncodingScenario.parse("gif"), .gifClip)

        // Unknown values return nil
        XCTAssertNil(EncodingScenario.parse("nonexistent-scenario"))
        XCTAssertNil(EncodingScenario.parse(""))
    }

    // MARK: - 2. Native HLS / CMAF ABR Packager End-to-End

    func testHLSCMAFPackagerEndToEndWithSubtitles() async throws {
        let dir = try makeTempDir("hls-cmaf")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("source_640x360.mp4")
        try await makeSyntheticVideo(at: srcURL, width: 640, height: 360, fps: 30, durationSeconds: 3.0, codec: .h264, includeAudio: true)

        let vttURL = dir.appendingPathComponent("captions.vtt")
        let vttContent = """
        WEBVTT

        00:00:00.000 --> 00:00:01.500
        Safarium Wave 10 HLS Test

        00:00:01.500 --> 00:00:03.000
        100% Native Apple Silicon CMAF
        """
        try Data(vttContent.utf8).write(to: vttURL)

        let hlsDir = dir.appendingPathComponent("hls_out", isDirectory: true)
        let options = HLSPackageOptions(
            rungs: [
                HLSRung(name: "180p", width: 320, height: 180, bitrate: 450_000, fps: 30, codec: .hevc, audioBitrate: 96_000),
                HLSRung(name: "360p", width: 640, height: 360, bitrate: 1_100_000, fps: 30, codec: .hevc10, audioBitrate: 128_000),
                // Taller than 360p source -> must be automatically skipped
                HLSRung(name: "1080p", width: 1920, height: 1080, bitrate: 6_000_000, fps: 30, codec: .hevc10, audioBitrate: 160_000),
            ],
            segmentDurationSeconds: 1.5,
            format: .fmp4CMAF,
            codec: .hevc10,
            subtitleVTTPath: vttURL,
            subtitleLanguage: "en",
            subtitleName: "English"
        )

        let result = try await HLSPackager.package(inputURL: srcURL, outputDirectory: hlsDir, options: options)

        XCTAssertEqual(result.format, .fmp4CMAF)
        XCTAssertEqual(result.variants.count, 2, "1080p rung taller than 360p source should be skipped")
        XCTAssertGreaterThan(result.totalBytes, 0)
        XCTAssertNotNil(result.subtitlePlaylistPath)

        // Verify master.m3u8 RFC 8216 tags
        let masterText = try String(contentsOfFile: result.masterPlaylistPath, encoding: .utf8)
        XCTAssertTrue(masterText.contains("#EXTM3U"))
        XCTAssertTrue(masterText.contains("#EXT-X-VERSION:7"))
        XCTAssertTrue(masterText.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
        XCTAssertTrue(masterText.contains("#EXT-X-MEDIA:TYPE=SUBTITLES"))
        XCTAssertTrue(masterText.contains("#EXT-X-STREAM-INF:"))
        XCTAssertTrue(masterText.contains("RESOLUTION=320x180"))
        XCTAssertTrue(masterText.contains("RESOLUTION=640x360"))
        XCTAssertTrue(masterText.contains("SUBTITLES=\"subs\""))
        XCTAssertTrue(masterText.contains("mp4a.40.2"))

        // Verify each variant has non-empty init.mp4, seg_*.m4s, and RFC 8216 playlist.m3u8
        for variant in result.variants {
            XCTAssertGreaterThanOrEqual(variant.segmentCount, 1)
            XCTAssertGreaterThan(variant.totalBytes, 0)
            let initPath = try XCTUnwrap(variant.initSegmentPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: initPath))
            let initSize = (try FileManager.default.attributesOfItem(atPath: initPath)[.size] as? Int64) ?? 0
            XCTAssertGreaterThan(initSize, 100, "init.mp4 should be non-empty")

            let variantText = try String(contentsOfFile: variant.playlistPath, encoding: .utf8)
            XCTAssertTrue(variantText.contains("#EXTM3U"))
            XCTAssertTrue(variantText.contains("#EXT-X-VERSION:7"))
            XCTAssertTrue(variantText.contains("#EXT-X-MAP:URI=\"init.mp4\""))
            XCTAssertTrue(variantText.contains("#EXTINF:"))
            XCTAssertTrue(variantText.contains("seg_0000.m4s"))
            XCTAssertTrue(variantText.contains("#EXT-X-ENDLIST"))

            let seg0URL = URL(fileURLWithPath: variant.playlistPath)
                .deletingLastPathComponent()
                .appendingPathComponent("seg_0000.m4s")
            let seg0Size = (try FileManager.default.attributesOfItem(atPath: seg0URL.path)[.size] as? Int64) ?? 0
            XCTAssertGreaterThan(seg0Size, 500, "seg_0000.m4s should contain media payload")
        }

        // Verify subtitle playlist
        let subPlaylistText = try String(contentsOfFile: try XCTUnwrap(result.subtitlePlaylistPath), encoding: .utf8)
        XCTAssertTrue(subPlaylistText.contains("#EXTM3U"))
        XCTAssertTrue(subPlaylistText.contains("subtitles.vtt"))
        XCTAssertTrue(subPlaylistText.contains("#EXT-X-ENDLIST"))
    }

    func testHLSMPEGTSPackagerProducesValidTSPackets() async throws {
        let dir = try makeTempDir("hls-ts")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("source_ts.mp4")
        try await makeSyntheticVideo(at: srcURL, width: 320, height: 180, fps: 30, durationSeconds: 2.0, codec: .h264, includeAudio: false)

        let hlsDir = dir.appendingPathComponent("hls_ts_out", isDirectory: true)
        let options = HLSPackageOptions(
            rungs: [
                HLSRung(name: "180p", width: 320, height: 180, bitrate: 600_000, fps: 30, codec: .h264),
            ],
            segmentDurationSeconds: 1.0,
            format: .mpegTS,
            codec: .h264
        )
        let result = try await HLSPackager.package(inputURL: srcURL, outputDirectory: hlsDir, options: options)
        XCTAssertEqual(result.format, .mpegTS)
        XCTAssertEqual(result.variants.count, 1)
        let v = result.variants[0]
        XCTAssertGreaterThanOrEqual(v.segmentCount, 1)
        XCTAssertNil(v.initSegmentPath)

        let playlist = try String(contentsOfFile: v.playlistPath, encoding: .utf8)
        XCTAssertTrue(playlist.contains("#EXT-X-VERSION:3"))
        XCTAssertTrue(playlist.contains("seg_0000.ts"))
        XCTAssertTrue(playlist.contains("#EXT-X-ENDLIST"))

        let tsURL = URL(fileURLWithPath: v.playlistPath).deletingLastPathComponent().appendingPathComponent("seg_0000.ts")
        let tsData = try Data(contentsOf: tsURL)
        XCTAssertGreaterThanOrEqual(tsData.count, 188 * 3)
        XCTAssertEqual(tsData.count % 188, 0, "MPEG-TS segment must be an integer multiple of 188 bytes")
        XCTAssertEqual(tsData[0], 0x47, "MPEG-TS sync byte 0x47")
        XCTAssertEqual(tsData[188], 0x47, "Second MPEG-TS packet sync byte 0x47")
    }

    // MARK: - 3. Hardware HDR-to-SDR Tone-Mapper

    func testHardwareToneMapperBGRAAnd10BitHDRToSDR() throws {
        let width = 160
        let height = 90

        // (a) Test 10-bit P010 HDR10 PQ pixel buffer -> SDR BGRA
        var p010Opt: CVPixelBuffer?
        let p010St = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary,
            &p010Opt
        )
        XCTAssertEqual(p010St, kCVReturnSuccess)
        let p010 = try XCTUnwrap(p010Opt)

        CVPixelBufferLockBaseAddress(p010, [])
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(p010, 0)?.assumingMemoryBound(to: UInt16.self) {
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(p010, 0) / 2
            for y in 0..<height {
                for x in 0..<width {
                    // Bright HDR PQ luma (~70% code value in 10-bit MSB-aligned P010)
                    let val10 = UInt16(450 + ((x * 300) / width))
                    yBase[y * yStride + x] = val10 << 6
                }
            }
        }
        if let uvBase = CVPixelBufferGetBaseAddressOfPlane(p010, 1)?.assumingMemoryBound(to: UInt16.self) {
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(p010, 1) / 2
            let uvH = CVPixelBufferGetHeightOfPlane(p010, 1)
            let uvW = CVPixelBufferGetWidthOfPlane(p010, 1)
            for y in 0..<uvH {
                for x in 0..<uvW {
                    uvBase[y * uvStride + x * 2 + 0] = UInt16(512) << 6
                    uvBase[y * uvStride + x * 2 + 1] = UInt16(512) << 6
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(p010, [])
        ColorMasteringProfile.hdr10PQ.tagPixelBuffer(p010)
        XCTAssertTrue(HardwareToneMapper.isHDRPixelBuffer(p010))

        var dstOpt: CVPixelBuffer?
        let dstSt = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary,
            &dstOpt
        )
        XCTAssertEqual(dstSt, kCVReturnSuccess)
        let dst = try XCTUnwrap(dstOpt)

        try HardwareToneMapper.toneMapPixelBuffer(p010, into: dst, targetHeadroom: 1.0)
        XCTAssertFalse(HardwareToneMapper.isHDRPixelBuffer(dst))

        let meanRGB10 = averageRGB(of: dst)
        XCTAssertGreaterThan(meanRGB10, 20.0, "Tone-mapped 10-bit HDR10 output must not be black (mean=\(meanRGB10))")

        // (b) Test 8-bit BGRA buffer -> SDR BGRA
        var srcBGRAOpt: CVPixelBuffer?
        let bgraSt = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]] as CFDictionary,
            &srcBGRAOpt
        )
        XCTAssertEqual(bgraSt, kCVReturnSuccess)
        let srcBGRA = try XCTUnwrap(srcBGRAOpt)

        CVPixelBufferLockBaseAddress(srcBGRA, [])
        if let base = CVPixelBufferGetBaseAddress(srcBGRA)?.assumingMemoryBound(to: UInt8.self) {
            let bpr = CVPixelBufferGetBytesPerRow(srcBGRA)
            for y in 0..<height {
                let row = base.advanced(by: y * bpr)
                for x in 0..<width {
                    let off = x * 4
                    row[off + 0] = 90
                    row[off + 1] = 170
                    row[off + 2] = 220
                    row[off + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(srcBGRA, [])

        try HardwareToneMapper.toneMapPixelBuffer(srcBGRA, into: dst, targetHeadroom: 1.0)
        let meanRGBBGRA = averageRGB(of: dst)
        XCTAssertGreaterThan(meanRGBBGRA, 60.0, "Tone-mapped BGRA output must be non-black (mean=\(meanRGBBGRA))")
    }

    private func averageRGB(of pb: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else {
            return 0
        }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        var sum: Double = 0
        for y in 0..<h {
            let row = base.advanced(by: y * bpr)
            for x in 0..<w {
                let off = x * 4
                sum += Double(row[off + 0]) + Double(row[off + 1]) + Double(row[off + 2])
            }
        }
        return sum / Double(max(1, w * h * 3))
    }

    // MARK: - 4. Direct Video -> Animated GIF, APNG, and Animated WebP

    func testAnimatedClipExporterGIFAPNGAndWebP() async throws {
        let dir = try makeTempDir("anim-clips")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("clip_src.mp4")
        try await makeSyntheticVideo(at: srcURL, width: 320, height: 180, fps: 24, durationSeconds: 1.0, codec: .h264, includeAudio: false)

        // 1. GIF
        let gifURL = dir.appendingPathComponent("out.gif")
        let gifRes = try await AnimatedClipExporter.exportGIF(
            inputURL: srcURL,
            outputURL: gifURL,
            fps: 8,
            maxWidth: 160,
            maxDurationSeconds: 0.9
        )
        XCTAssertEqual(gifRes.format, "gif")
        XCTAssertEqual(gifRes.width, 160)
        XCTAssertEqual(gifRes.height, 90)
        XCTAssertGreaterThanOrEqual(gifRes.frameCount, 3)
        XCTAssertGreaterThan(gifRes.outputBytes, 0)

        let gifSrc = try XCTUnwrap(CGImageSourceCreateWithURL(gifURL as CFURL, nil))
        XCTAssertGreaterThanOrEqual(CGImageSourceGetCount(gifSrc), 3)
        let gifFrame0 = try XCTUnwrap(CGImageSourceCreateImageAtIndex(gifSrc, 0, nil))
        XCTAssertEqual(gifFrame0.width, 160)
        XCTAssertEqual(gifFrame0.height, 90)

        // 2. APNG
        let apngURL = dir.appendingPathComponent("out.png")
        let apngRes = try await AnimatedClipExporter.exportAPNG(
            inputURL: srcURL,
            outputURL: apngURL,
            fps: 8,
            maxWidth: 160,
            maxDurationSeconds: 0.9
        )
        XCTAssertEqual(apngRes.format, "apng")
        XCTAssertGreaterThanOrEqual(apngRes.frameCount, 3)
        XCTAssertGreaterThan(apngRes.outputBytes, 0)

        let apngSrc = try XCTUnwrap(CGImageSourceCreateWithURL(apngURL as CFURL, nil))
        XCTAssertGreaterThanOrEqual(CGImageSourceGetCount(apngSrc), 3)
        let apngFrame0 = try XCTUnwrap(CGImageSourceCreateImageAtIndex(apngSrc, 0, nil))
        XCTAssertEqual(apngFrame0.width, 160)
        XCTAssertEqual(apngFrame0.height, 90)

        // 3. Animated WebP (RIFF....WEBPVP8X + ANIM + ANMF + VP8L)
        let webpURL = dir.appendingPathComponent("out.webp")
        let webpRes = try await AnimatedClipExporter.exportAnimatedWebP(
            inputURL: srcURL,
            outputURL: webpURL,
            fps: 8,
            maxWidth: 160,
            maxDurationSeconds: 0.9
        )
        XCTAssertEqual(webpRes.format, "webp")
        XCTAssertEqual(webpRes.width, 160)
        XCTAssertEqual(webpRes.height, 90)
        XCTAssertGreaterThanOrEqual(webpRes.frameCount, 3)
        XCTAssertGreaterThan(webpRes.outputBytes, 0)

        // Verify RIFF....WEBPVP8X header magic bytes
        let webpData = try Data(contentsOf: webpURL)
        XCTAssertGreaterThanOrEqual(webpData.count, 20)
        XCTAssertEqual(String(decoding: webpData[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: webpData[8..<12], as: UTF8.self), "WEBP")
        XCTAssertEqual(String(decoding: webpData[12..<16], as: UTF8.self), "VP8X")

        // Verify Apple ImageIO natively decodes multiple frames from our Animated WebP
        let webpSrc = try XCTUnwrap(CGImageSourceCreateWithURL(webpURL as CFURL, nil))
        let webpCount = CGImageSourceGetCount(webpSrc)
        XCTAssertGreaterThanOrEqual(webpCount, 3, "ImageIO should decode >= 3 frames from animated WebP, got \(webpCount)")
        for idx in 0..<min(3, webpCount) {
            let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(webpSrc, idx, nil), "Failed to decode WebP frame \(idx)")
            XCTAssertEqual(frame.width, 160)
            XCTAssertEqual(frame.height, 90)
        }
    }
}
