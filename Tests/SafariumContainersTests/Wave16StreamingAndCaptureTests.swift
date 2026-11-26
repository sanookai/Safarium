import CoreMedia
import CoreVideo
import Foundation
import SafariumContainers
import SafariumCore
import XCTest

/// Wave 16 end-to-end tests:
/// 1. `ZeroCopyStreamRecorder` (IOSurface zero-copy recording + CoreImage HUD overlay + ISOBMFF/decode conformance)
/// 2. `LLHLSPackager` (CMAF partial segments + RFC 8216bis playlist generation & validator)
/// 3. `RTMPPublisher` + `LoopbackRTMPTestServer` (real TCP 127.0.0.1 handshake, AMF0 commands, FLV AVC/HEVC/AAC tags)
final class Wave16StreamingAndCaptureTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf-wave16-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates an IOSurface-backed BGRA `CVPixelBuffer` with a crisp animated gradient pattern.
    private func makeSyntheticBGRAPixelBuffer(width: Int, height: Int, frameIndex: Int) throws -> CVPixelBuffer {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        var pbOpt: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pbOpt
        )
        guard status == kCVReturnSuccess, let pb = pbOpt else {
            throw NSError(domain: "Wave16Test", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed"])
        }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        if let base = CVPixelBufferGetBaseAddress(pb) {
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            let shift = (frameIndex * 9) & 0xFF
            for y in 0..<height {
                let rowOffset = y * bytesPerRow
                let greenVal = UInt8(((y * 255) / max(1, height - 1)) & 0xFF)
                for x in 0..<width {
                    let pxOffset = rowOffset + (x * 4)
                    let redVal = UInt8((((x * 255) / max(1, width - 1)) + shift) & 0xFF)
                    let blueVal = UInt8(((255 - Int(greenVal)) + (shift / 2)) & 0xFF)
                    ptr[pxOffset + 0] = blueVal
                    ptr[pxOffset + 1] = greenVal
                    ptr[pxOffset + 2] = redVal
                    ptr[pxOffset + 3] = 255
                }
            }
        }
        return pb
    }

    // MARK: - Test 1: ZeroCopyStreamRecorder + HUD Overlay + BitstreamConformance

    func testZeroCopyStreamRecorderWithHUDOverlayAndMP4Conformance() async throws {
        let tempDir = try makeTempDir("screencap")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let preflight = ScreenCapturePipeline.preflightAccess()
        XCTAssertTrue(preflight.platformSupported)
        XCTAssertFalse(preflight.notes.isEmpty)

        let outURL = tempDir.appendingPathComponent("zero_copy_hud.mp4")
        let config = ScreenCaptureConfig(
            width: 320,
            height: 180,
            fps: 30,
            codec: .hevc10,
            bitrate: 2_000_000,
            captureAudio: false,
            showCursor: true,
            hudOverlayText: "SAFARIUM HUD",
            maxDurationSeconds: 2.0
        )

        let recorder = try ZeroCopyStreamRecorder(outputURL: outURL, config: config, realTime: false)
        try recorder.start()

        let totalFrames = 20
        for i in 0..<totalFrames {
            let pb = try makeSyntheticBGRAPixelBuffer(width: 320, height: 180, frameIndex: i)
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            let appended = recorder.append(pixelBuffer: pb, presentationTime: pts)
            XCTAssertTrue(appended, "Frame \(i) should append cleanly")
        }

        let report = try await recorder.finish()
        XCTAssertEqual(report.outputPath, outURL.path)
        XCTAssertEqual(report.width, 320)
        XCTAssertEqual(report.height, 180)
        XCTAssertEqual(report.framesWritten, totalFrames)
        XCTAssertEqual(report.droppedFrames, 0)
        XCTAssertEqual(report.cpuReadbacks, 0)
        XCTAssertTrue(report.hudOverlayApplied)
        XCTAssertGreaterThan(report.bytesWritten, 1024)
        XCTAssertGreaterThanOrEqual(report.elapsedMs, 0.0)

        // Independent binary ISOBMFF inspection + AVAssetReader full decode verification
        let iso = try BitstreamConformance.inspectISOBMFF(url: outURL)
        XCTAssertTrue(iso.isValid, "ISOBMFF violations: \(iso.violations)")
        XCTAssertTrue(iso.hasFtyp)
        XCTAssertTrue(iso.hasMoov)
        XCTAssertTrue(iso.hasMdat)

        let conformance = try await BitstreamConformance.verifyMediaFile(
            url: outURL,
            requireIndependentDecode: true
        )
        XCTAssertTrue(conformance.passed, "BitstreamConformance violations: \(conformance.violations)")
        XCTAssertEqual(conformance.independentDecode?.decodedVideoFrames, totalFrames)
        XCTAssertEqual(conformance.independentDecode?.monotonicPTS, true)
        XCTAssertEqual(conformance.independentDecode?.nonZeroPixelVariance, true)
    }

    // MARK: - Test 2: LLHLSPackager CMAF Partial Segments + RFC 8216bis Validator

    func testLLHLSPackagerAndRFC8216bisValidation() async throws {
        let tempDir = try makeTempDir("llhls")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Synthesize a 2.5s (75 frames @ 30fps) animated source video via native ZeroCopyStreamRecorder.
        let sourceURL = tempDir.appendingPathComponent("source_2p5s.mp4")
        let srcConfig = ScreenCaptureConfig(
            width: 320,
            height: 180,
            fps: 30,
            codec: .h264,
            bitrate: 2_000_000,
            hudOverlayText: nil
        )
        let recorder = try ZeroCopyStreamRecorder(outputURL: sourceURL, config: srcConfig, realTime: false)
        try recorder.start()
        for i in 0..<75 {
            let pb = try makeSyntheticBGRAPixelBuffer(width: 320, height: 180, frameIndex: i)
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            XCTAssertTrue(recorder.append(pixelBuffer: pb, presentationTime: pts))
        }
        _ = try await recorder.finish()

        // Package as Low-Latency HLS (RFC 8216bis CMAF partial segments)
        let llhlsDir = tempDir.appendingPathComponent("llhls_out", isDirectory: true)
        let options = LLHLSPackageOptions(
            partDurationSeconds: 0.34,
            segmentDurationSeconds: 1.5,
            width: 320,
            height: 180,
            bitrate: 1_800_000,
            codec: .hevc10,
            includePreloadHint: true,
            endList: true
        )
        let result = try await LLHLSPackager.package(
            inputURL: sourceURL,
            outputDirectory: llhlsDir,
            options: options
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: result.masterPlaylistPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.mediaPlaylistPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.initSegmentPath))
        XCTAssertGreaterThanOrEqual(result.parts.count, 4, "Expected >= 4 partial segments for 2.5s video")
        XCTAssertGreaterThanOrEqual(result.segments.count, 1)
        XCTAssertGreaterThanOrEqual(result.partHoldBackSeconds, result.partTargetSeconds * 2.0 - 0.005)

        for part in result.parts {
            let pURL = llhlsDir.appendingPathComponent(part.uri)
            XCTAssertTrue(FileManager.default.fileExists(atPath: pURL.path), "Missing part \(part.uri)")
            XCTAssertGreaterThan(part.bytes, 0)
        }
        for seg in result.segments {
            let sURL = llhlsDir.appendingPathComponent(seg)
            XCTAssertTrue(FileManager.default.fileExists(atPath: sURL.path), "Missing segment \(seg)")
        }

        let mediaText = try String(contentsOfFile: result.mediaPlaylistPath, encoding: .utf8)
        XCTAssertTrue(mediaText.contains("#EXT-X-VERSION:7"))
        XCTAssertTrue(mediaText.contains("#EXT-X-SERVER-CONTROL:"))
        XCTAssertTrue(mediaText.contains("#EXT-X-PART-INF:PART-TARGET="))
        XCTAssertTrue(mediaText.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        XCTAssertTrue(mediaText.contains("#EXT-X-PART:"))
        XCTAssertTrue(mediaText.contains("#EXT-X-PRELOAD-HINT:"))
        XCTAssertTrue(mediaText.contains("#EXT-X-ENDLIST"))

        // Validate generated LL-HLS playlist and CMAF boxes
        let validation = LLHLSPackager.validate(playlistURL: URL(fileURLWithPath: result.mediaPlaylistPath))
        XCTAssertTrue(validation.passed, "LL-HLS violations: \(validation.violations)")
        XCTAssertEqual(validation.violations, [])
        XCTAssertGreaterThanOrEqual(validation.partCount, 4)
        XCTAssertGreaterThanOrEqual(validation.independentPartCount, 4)
        XCTAssertTrue(validation.hasServerControl)
        XCTAssertTrue(validation.hasPartInf)
        XCTAssertTrue(validation.hasPreloadHint)
    }

    // MARK: - Test 3: Pure-Swift RTMPPublisher <-> LoopbackRTMPTestServer

    func testRTMPPublisherLoopbackHandshakeAndFLVStreaming() throws {
        // 3a. Verify AMF0 codec round-trip
        let amfOriginal: [AMF0Value] = [
            .string("connect"),
            .number(1.0),
            .object([
                ("app", .string("live")),
                ("fpad", .boolean(false)),
                ("audioCodecs", .number(1024.0)),
            ]),
            .null,
        ]
        let amfWire = AMF0Codec.encodeSequence(amfOriginal)
        let amfDecoded = try AMF0Codec.decode(amfWire)
        XCTAssertEqual(amfDecoded, amfOriginal)

        // 3b. Verify Enhanced RTMP HEVC ('hvc1') FLV tag headers
        let sampleHvcC = Data([0x01, 0x02, 0x60, 0x00, 0x00, 0x00])
        let hevcSeq = FLVTagBuilder.enhancedHEVCSequenceHeader(hvcC: sampleHvcC)
        XCTAssertEqual(hevcSeq.prefix(5), Data([0x90, 0x68, 0x76, 0x63, 0x31]))
        XCTAssertEqual(hevcSeq.dropFirst(5), sampleHvcC)

        let hevcNalu = Data([0x00, 0x00, 0x00, 0x04, 0x26, 0x01, 0xAF, 0x08])
        let hevcKey = FLVTagBuilder.enhancedHEVCVideoFrame(naluPayload: hevcNalu, isKeyframe: true, compositionTimeMs: 0)
        XCTAssertEqual(hevcKey.prefix(5), Data([0x93, 0x68, 0x76, 0x63, 0x31]))
        XCTAssertEqual(hevcKey.dropFirst(5), hevcNalu)

        // 3c. Full TCP 127.0.0.1 RTMP handshake + AMF0 connect/createStream/publish + FLV video/audio stream
        let server = LoopbackRTMPTestServer()
        try server.start()
        defer { server.stop() }
        XCTAssertGreaterThan(server.port, 0)

        let config = RTMPPublishConfig(
            host: "127.0.0.1",
            port: server.port,
            app: "live",
            streamKey: "safarium-w16-stream",
            timeoutSeconds: 5.0
        )
        let publisher = RTMPPublisher(config: config)
        try publisher.connect()

        // Synthetic AVC avcC sequence header + keyframe (> 4096 bytes to verify multi-chunk fmt 3 reassembly!) + interframes
        let avcC = Data([
            0x01, 0x64, 0x00, 0x1F, 0xFF,
            0xE1, 0x00, 0x04, 0x67, 0x64, 0x00, 0x1F,
            0x01, 0x00, 0x04, 0x68, 0xEE, 0x3C, 0x80,
        ])
        var largeKeyframeNalu = Data([0x00, 0x00, 0x14, 0x00, 0x65, 0x88, 0x84, 0x21])
        largeKeyframeNalu.append(contentsOf: (0..<5116).map { UInt8($0 & 0xFF) })
        let interFrame1 = Data([0x00, 0x00, 0x00, 0x08, 0x41, 0x9A, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77])
        let interFrame2 = Data([0x00, 0x00, 0x00, 0x06, 0x41, 0x9E, 0x11, 0x22, 0x33, 0x44])

        // Synthetic AAC AudioSpecificConfig (48kHz stereo AAC-LC) + 2 raw AAC frames
        let aacConfig = Data([0x11, 0x90])
        let aacFrame1 = Data([0x21, 0x10, 0x04, 0x60, 0x8C, 0x1C])
        let aacFrame2 = Data([0x21, 0x10, 0x05, 0x70, 0x9D, 0x2E])

        try publisher.sendVideoSequenceHeader(avcC, enhancedHEVC: false, timestampMs: 0)
        try publisher.sendAudioSequenceHeader(aacConfig, timestampMs: 0)
        try publisher.sendVideoFrame(largeKeyframeNalu, isKeyframe: true, timestampMs: 0, compositionTimeMs: 0)
        try publisher.sendAudioFrame(aacFrame1, timestampMs: 21)
        try publisher.sendVideoFrame(interFrame1, isKeyframe: false, timestampMs: 33, compositionTimeMs: 33)
        try publisher.sendAudioFrame(aacFrame2, timestampMs: 42)
        try publisher.sendVideoFrame(interFrame2, isKeyframe: false, timestampMs: 66, compositionTimeMs: 0)

        let stats = publisher.close()
        XCTAssertTrue(stats.handshakeCompleted)
        XCTAssertEqual(stats.publishedStreamName, "safarium-w16-stream")
        XCTAssertEqual(stats.videoPacketsSent, 4)
        XCTAssertEqual(stats.audioPacketsSent, 3)
        XCTAssertGreaterThan(stats.bytesSent, 5_000)

        XCTAssertTrue(server.waitForSessionEnd(timeoutSeconds: 3.0))
        let snap = server.snapshot()
        XCTAssertTrue(snap.handshakeCompleted)
        XCTAssertEqual(snap.connectedApp, "live")
        XCTAssertEqual(snap.publishedStreamKey, "safarium-w16-stream")
        XCTAssertEqual(snap.videoPackets.count, 4)
        XCTAssertEqual(snap.audioPackets.count, 3)

        // Verify exact byte-for-byte FLV tag payloads received over loopback TCP
        XCTAssertEqual(snap.videoPackets[0].payload, FLVTagBuilder.avcSequenceHeader(avcC: avcC))
        XCTAssertEqual(snap.videoPackets[1].payload, FLVTagBuilder.avcVideoFrame(naluPayload: largeKeyframeNalu, isKeyframe: true, compositionTimeMs: 0))
        XCTAssertEqual(snap.videoPackets[2].payload, FLVTagBuilder.avcVideoFrame(naluPayload: interFrame1, isKeyframe: false, compositionTimeMs: 33))
        XCTAssertEqual(snap.videoPackets[2].timestamp, 33)
        XCTAssertEqual(snap.videoPackets[3].payload, FLVTagBuilder.avcVideoFrame(naluPayload: interFrame2, isKeyframe: false, compositionTimeMs: 0))
        XCTAssertEqual(snap.videoPackets[3].timestamp, 66)

        XCTAssertEqual(snap.audioPackets[0].payload, FLVTagBuilder.aacSequenceHeader(audioSpecificConfig: aacConfig))
        XCTAssertEqual(snap.audioPackets[1].payload, FLVTagBuilder.aacAudioFrame(rawFrame: aacFrame1))
        XCTAssertEqual(snap.audioPackets[1].timestamp, 21)
        XCTAssertEqual(snap.audioPackets[2].payload, FLVTagBuilder.aacAudioFrame(rawFrame: aacFrame2))
        XCTAssertEqual(snap.audioPackets[2].timestamp, 42)
    }
}
