import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SafariumContainers
import SafariumCore
import XCTest

/// Wave 17 tests:
/// 1. FCPXML 1.11 & OpenTimelineIO (OTIO) canonical timeline round-trip (23.976 & 30 fps)
/// 2. Dual CMAF HLS + MPEG-DASH single-pass packaging & ISO/IEC 23009-1 validation
/// 3. SMPTE DF/NDF timecode math (incl. 29.97 minute skip) + real QuickTime `tmcd` track writer
/// 4. WebVTT -> CEA-608 odd-parity encoding + SMPTE ST 334-2 CEA-708 CDP checksum validation
/// 5. ITU-R BS.1770-4 / EBU R128 broadcast loudness auditor (-23 LUFS calibrated stereo sine + file decode)
/// 6. Native Apple Silicon / IOKit energy, thermal, RSS & CPU telemetry sampler
final class Wave17NLEBroadcastEnergyTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf-wave17-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Generates a synthetic H.264 video via native AVAssetWriter.
    private func encodeSyntheticVideo(
        at url: URL,
        fileType: AVFileType = .mov,
        width: Int = 320,
        height: Int = 180,
        fps: Int = 30,
        durationSeconds: Double = 2.0
    ) async throws {
        let totalFrames = max(1, Int((durationSeconds * Double(fps)).rounded()))
        let writer = try AVAssetWriter(url: url, fileType: fileType)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 1_500_000,
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let pixelAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelAttrs
        )
        XCTAssertTrue(writer.canAdd(videoInput))
        writer.add(videoInput)

        XCTAssertTrue(writer.startWriting(), "writer failed to start: \(writer.error?.localizedDescription ?? "unknown")")
        writer.startSession(atSourceTime: .zero)

        let timescale = CMTimeScale(fps)
        for frameIdx in 0..<totalFrames {
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var pb: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                kCVPixelFormatType_32BGRA,
                pixelAttrs as CFDictionary,
                &pb
            )
            XCTAssertEqual(status, kCVReturnSuccess)
            guard let buffer = pb else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                let rVal = UInt8((frameIdx * 7) % 255)
                let gVal = UInt8((frameIdx * 13 + 60) % 255)
                let bVal = UInt8((frameIdx * 19 + 120) % 255)
                for y in 0..<height {
                    let rowBase = y * bytesPerRow
                    for x in 0..<width {
                        let px = rowBase + x * 4
                        ptr[px] = bVal
                        ptr[px + 1] = gVal
                        ptr[px + 2] = rVal
                        ptr[px + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let pts = CMTime(value: CMTimeValue(frameIdx), timescale: timescale)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: pts))
        }
        videoInput.markAsFinished()

        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "writer failed: \(writer.error?.localizedDescription ?? "none")")
    }

    /// Writes a calibrated 48 kHz stereo 1 kHz sine WAV file via native AVAudioFile.
    private func writeCalibratedStereoWAV(at url: URL, targetLUFS: Double, durationSeconds: Double = 1.5) throws {
        let sampleRate: Double = 48_000.0
        let frameCount = AVAudioFrameCount(Int((durationSeconds * sampleRate).rounded()))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            XCTFail("failed to create AVAudioFormat / AVAudioPCMBuffer")
            return
        }
        pcmBuffer.frameLength = frameCount
        let amp = Float(pow(10.0, targetLUFS / 20.0))
        if let channelData = pcmBuffer.floatChannelData {
            for i in 0..<Int(frameCount) {
                let phase = 2.0 * Double.pi * 1000.0 * (Double(i) / sampleRate)
                let s = amp * Float(sin(phase))
                channelData[0][i] = s
                channelData[1][i] = s
            }
        }
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
        try audioFile.write(from: pcmBuffer)
    }

    // MARK: - Test 1: FCPXML 1.11 & OTIO Round-Trip

    func test1_FCPXMLAndOTIORoundTrip() throws {
        // Verify RationalTime FCPXML formatting
        let ntscFrame = RationalTime(value: 1001, timescale: 30000)
        XCTAssertEqual(ntscFrame.fcpxmlString, "1001/30000s")
        XCTAssertEqual(ntscFrame.seconds, 1001.0 / 30000.0, accuracy: 1e-9)

        // 23.976 fps timeline (24000/1001) with video + audio tracks, gaps, clip markers, timeline markers
        let clipMarker = TimelineMarker(
            name: "BeatDrop",
            start: RationalTime(value: 24024, timescale: 24000),
            duration: RationalTime(value: 1001, timescale: 24000),
            note: "Sync cut here"
        )
        let timelineMarker = TimelineMarker(
            name: "Act1",
            start: RationalTime(value: 48048, timescale: 24000),
            duration: RationalTime(value: 1001, timescale: 24000),
            note: "Opening act"
        )

        let vTrack = TimelineTrack(
            name: "V1",
            kind: "video",
            clips: [
                TimelineClip(
                    name: "IntroShot",
                    mediaURL: "file:///media/intro.mov",
                    sourceStart: RationalTime(value: 1001, timescale: 24000),
                    duration: RationalTime(value: 48048, timescale: 24000),
                    isGap: false,
                    trackKind: "video",
                    markers: [clipMarker]
                ),
                TimelineClip(
                    name: "BlackSlug",
                    mediaURL: nil,
                    sourceStart: RationalTime(value: 0, timescale: 24000),
                    duration: RationalTime(value: 24024, timescale: 24000),
                    isGap: true,
                    trackKind: "video",
                    markers: []
                ),
                TimelineClip(
                    name: "MainShot",
                    mediaURL: "file:///media/main.mov",
                    sourceStart: RationalTime(value: 0, timescale: 24000),
                    duration: RationalTime(value: 72072, timescale: 24000),
                    isGap: false,
                    trackKind: "video",
                    markers: []
                ),
            ]
        )

        let aTrack = TimelineTrack(
            name: "A1",
            kind: "audio",
            clips: [
                TimelineClip(
                    name: "VoiceOver",
                    mediaURL: "file:///media/vo.wav",
                    sourceStart: RationalTime(value: 0, timescale: 24000),
                    duration: RationalTime(value: 144144, timescale: 24000),
                    isGap: false,
                    trackKind: "audio",
                    markers: []
                ),
            ]
        )

        let original23976 = SafariumTimeline(
            name: "Safarium Promo 23.976",
            width: 3840,
            height: 2160,
            fpsNum: 24000,
            fpsDen: 1001,
            tracks: [vTrack, aTrack],
            markers: [timelineMarker]
        )

        // FCPXML 1.11 export + parse round-trip
        let xml = TimelineInterop.exportFCPXML(original23976)
        XCTAssertTrue(xml.contains(#"<fcpxml version="1.11">"#))
        XCTAssertTrue(xml.contains(#"frameDuration="1001/24000s""#))
        XCTAssertTrue(xml.contains("<asset-clip"))
        XCTAssertTrue(xml.contains("<gap"))
        XCTAssertTrue(xml.contains("<marker"))

        let parsedFCP = try TimelineInterop.parseFCPXML(xml)
        XCTAssertEqual(parsedFCP.name, original23976.name)
        XCTAssertEqual(parsedFCP.width, 3840)
        XCTAssertEqual(parsedFCP.height, 2160)
        XCTAssertEqual(parsedFCP.fpsNum, 24000)
        XCTAssertEqual(parsedFCP.fpsDen, 1001)
        XCTAssertEqual(parsedFCP.tracks.count, 2)
        XCTAssertEqual(parsedFCP.tracks[0].clips.count, 3)
        XCTAssertEqual(parsedFCP.tracks[0].clips[0].name, "IntroShot")
        XCTAssertEqual(parsedFCP.tracks[0].clips[0].mediaURL, "file:///media/intro.mov")
        XCTAssertEqual(parsedFCP.tracks[0].clips[0].sourceStart, RationalTime(value: 1001, timescale: 24000))
        XCTAssertEqual(parsedFCP.tracks[0].clips[0].duration, RationalTime(value: 48048, timescale: 24000))
        XCTAssertEqual(parsedFCP.tracks[0].clips[0].markers, [clipMarker])
        XCTAssertTrue(parsedFCP.tracks[0].clips[1].isGap)
        XCTAssertEqual(parsedFCP.tracks[0].clips[1].duration, RationalTime(value: 24024, timescale: 24000))
        XCTAssertEqual(parsedFCP.tracks[1].kind, "audio")
        XCTAssertEqual(parsedFCP.tracks[1].clips[0].mediaURL, "file:///media/vo.wav")
        XCTAssertEqual(parsedFCP.markers, [timelineMarker])

        // OTIO JSON export + parse round-trip
        let otioData = try TimelineInterop.exportOTIO(original23976)
        let otioText = String(decoding: otioData, as: UTF8.self)
        XCTAssertTrue(otioText.contains(#""Timeline.1""#))
        XCTAssertTrue(otioText.contains(#""Track.1""#))
        XCTAssertTrue(otioText.contains(#""Clip.2""#))
        XCTAssertTrue(otioText.contains(#""Gap.1""#))
        XCTAssertTrue(otioText.contains(#""Marker.2""#))
        XCTAssertTrue(otioText.contains(#""RationalTime.1""#))
        XCTAssertTrue(otioText.contains(#""TimeRange.1""#))

        let parsedOTIO = try TimelineInterop.parseOTIO(otioData)
        XCTAssertEqual(parsedOTIO, original23976)

        // Also test 30fps integer rational timebase round-trip
        let timeline30 = SafariumTimeline(
            name: "WebSpot 30fps",
            width: 1920,
            height: 1080,
            fpsNum: 30,
            fpsDen: 1,
            tracks: [
                TimelineTrack(
                    name: "V1",
                    kind: "video",
                    clips: [
                        TimelineClip(
                            name: "Clip30",
                            mediaURL: "file:///media/clip30.mp4",
                            sourceStart: RationalTime(value: 15, timescale: 30),
                            duration: RationalTime(value: 90, timescale: 30)
                        ),
                    ]
                ),
            ],
            markers: []
        )
        let fcp30 = try TimelineInterop.parseFCPXML(TimelineInterop.exportFCPXML(timeline30))
        XCTAssertEqual(fcp30.fpsNum, 30)
        XCTAssertEqual(fcp30.fpsDen, 1)
        XCTAssertEqual(fcp30.tracks[0].clips[0].duration, RationalTime(value: 90, timescale: 30))

        let otio30 = try TimelineInterop.parseOTIO(try TimelineInterop.exportOTIO(timeline30))
        XCTAssertEqual(otio30, timeline30)
    }

    // MARK: - Test 2: Dual CMAF HLS + MPEG-DASH Packaging & Validation

    func test2_DualCMAFHLSAndDASHPackaging() async throws {
        let workDir = try makeTempDir("dual-dash")
        defer { try? FileManager.default.removeItem(at: workDir) }

        let inputURL = workDir.appendingPathComponent("source.mov")
        try await encodeSyntheticVideo(at: inputURL, fileType: .mov, width: 320, height: 180, fps: 30, durationSeconds: 2.0)

        let outDir = workDir.appendingPathComponent("pkg", isDirectory: true)
        let options = HLSPackageOptions(
            rungs: [
                HLSRung(name: "180p", width: 320, height: 180, bitrate: 600_000, fps: 30.0, codec: .h264),
            ],
            segmentDurationSeconds: 1.0,
            format: .fmp4CMAF,
            codec: .h264
        )

        let (hls, dash) = try await DASHPackager.packageDualHLSAndDASH(
            inputURL: inputURL,
            outputDirectory: outDir,
            options: options
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: hls.masterPlaylistPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dash.manifestPath))
        XCTAssertTrue(dash.sharedWithHLS)
        XCTAssertEqual(dash.representations, hls.variants.count)

        let mpdText = try String(contentsOfFile: dash.manifestPath, encoding: .utf8)
        XCTAssertTrue(mpdText.contains("urn:mpeg:dash:profile:cmaf:2019"))
        XCTAssertTrue(mpdText.contains("$RepresentationID$/init.mp4"))
        XCTAssertTrue(mpdText.contains("$RepresentationID$/seg_$Number%04d$.m4s"))

        let report = DASHPackager.validate(manifestURL: URL(fileURLWithPath: dash.manifestPath))
        XCTAssertTrue(report.passed, "DASH validation failed: \(report.violations) missing: \(report.missingFiles)")
        XCTAssertEqual(report.violations, [])
        XCTAssertEqual(report.missingFiles, [])
        XCTAssertEqual(report.adaptationSetCount, 1)
        XCTAssertEqual(report.representationCount, 1)
        XCTAssertGreaterThan(report.totalReferencedSegments, 0)
    }

    // MARK: - Test 3: SMPTE DF/NDF Timecode + QuickTime `tmcd` Track Writer

    func test3_SMPTETimecodeAndTmcdTrackWriter() async throws {
        // 29.97 Drop-Frame exact minute boundary skip: 00:00:59;29 (1799) -> 00:01:00;02 (1800)
        let beforeSkip = SMPTETimecode(hours: 0, minutes: 0, seconds: 59, frames: 29, frameRate: 29.97, isDropFrame: true)
        XCTAssertEqual(beforeSkip.description, "00:00:59;29")
        XCTAssertEqual(beforeSkip.frameNumber, 1799)

        let afterSkip = SMPTETimecode(frameNumber: 1800, frameRate: 29.97, isDropFrame: true)
        XCTAssertEqual(afterSkip.description, "00:01:00;02")
        XCTAssertEqual(afterSkip.frameNumber, 1800)

        // 10th-minute boundary must NOT drop frames: 00:09:59;29 (17981) -> 00:10:00;00 (17982)
        let beforeTenth = SMPTETimecode(hours: 0, minutes: 9, seconds: 59, frames: 29, frameRate: 29.97, isDropFrame: true)
        XCTAssertEqual(beforeTenth.frameNumber, 17981)
        let atTenth = SMPTETimecode(frameNumber: 17982, frameRate: 29.97, isDropFrame: true)
        XCTAssertEqual(atTenth.description, "00:10:00;00")
        XCTAssertEqual(atTenth.frameNumber, 17982)

        // 59.94 Drop-Frame skips 4 frames at non-10th minute: 00:00:59;59 (3599) -> 00:01:00;04 (3600)
        let df59Before = SMPTETimecode(hours: 0, minutes: 0, seconds: 59, frames: 59, frameRate: 59.94, isDropFrame: true)
        XCTAssertEqual(df59Before.frameNumber, 3599)
        let df59After = SMPTETimecode(frameNumber: 3600, frameRate: 59.94, isDropFrame: true)
        XCTAssertEqual(df59After.description, "00:01:00;04")
        XCTAssertEqual(df59After.frameNumber, 3600)

        // NDF 24fps, 25fps, 30fps round-trip
        for fps in [24.0, 25.0, 30.0, 60.0] {
            let tc = SMPTETimecode(hours: 1, minutes: 23, seconds: 45, frames: 12, frameRate: fps, isDropFrame: false)
            let roundTripped = SMPTETimecode(frameNumber: tc.frameNumber, frameRate: fps, isDropFrame: false)
            XCTAssertEqual(roundTripped, tc)
            let parsed = try SMPTETimecode(parsing: tc.description, frameRate: fps)
            XCTAssertEqual(parsed, tc)
        }

        // Write a genuine QuickTime `tmcd` track into a `.mov` file and verify with AVURLAsset
        let workDir = try makeTempDir("tmcd")
        defer { try? FileManager.default.removeItem(at: workDir) }

        let srcURL = workDir.appendingPathComponent("input.mov")
        let dstURL = workDir.appendingPathComponent("output_tmcd.mov")
        try await encodeSyntheticVideo(at: srcURL, fileType: .mov, width: 320, height: 180, fps: 30, durationSeconds: 1.0)

        let startTC = SMPTETimecode(hours: 1, minutes: 0, seconds: 0, frames: 0, frameRate: 29.97, isDropFrame: true)
        let report = try await TimecodeTrackWriter.addTimecodeTrack(to: srcURL, outputURL: dstURL, startTimecode: startTC)
        XCTAssertEqual(report.startTimecode, "01:00:00;00")
        XCTAssertEqual(report.startFrameNumber, startTC.frameNumber)
        XCTAssertEqual(report.videoTracksCopied, 1)

        let outAsset = AVURLAsset(url: dstURL)
        let tcTracks = try await outAsset.loadTracks(withMediaType: .timecode)
        XCTAssertEqual(tcTracks.count, 1, "expected genuine tmcd track in output .mov")
        let outVideoTracks = try await outAsset.loadTracks(withMediaType: .video)
        XCTAssertEqual(outVideoTracks.count, 1)

        // Verify the 32-bit big-endian frame counter written inside the tmcd sample
        let reader = try AVAssetReader(asset: outAsset)
        let tcOut = AVAssetReaderTrackOutput(track: tcTracks[0], outputSettings: nil)
        reader.add(tcOut)
        XCTAssertTrue(reader.startReading())
        let sample = tcOut.copyNextSampleBuffer()
        XCTAssertNotNil(sample)
        if let sb = sample, let block = CMSampleBufferGetDataBuffer(sb) {
            var totalLen = 0
            var ptr: UnsafeMutablePointer<Int8>?
            let st = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLen, dataPointerOut: &ptr)
            XCTAssertEqual(st, kCMBlockBufferNoErr)
            XCTAssertEqual(totalLen, 4)
            if let p = ptr {
                let raw = UnsafeRawPointer(p).load(as: Int32.self)
                let decodedFrame = Int64(Int32(bigEndian: raw))
                XCTAssertEqual(decodedFrame, startTC.frameNumber)
            }
        }
    }

    // MARK: - Test 4: WebVTT -> CEA-608 Odd Parity & CEA-708 CDP Checksum

    func test4_WebVTTToCEA608AndCEA708CDP() {
        let vtt = """
        WEBVTT

        1
        00:00:01.000 --> 00:00:03.500
        Hello Broadcast World!

        2
        00:00:04.000 --> 00:00:06.000
        <i>Line One</i>
        Line Two
        """

        let cues = ClosedCaptionPacketizer.parseWebVTT(vtt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].startSeconds, 1.0, accuracy: 1e-6)
        XCTAssertEqual(cues[0].endSeconds, 3.5, accuracy: 1e-6)
        XCTAssertEqual(cues[0].text, "Hello Broadcast World!")
        XCTAssertEqual(cues[1].text, "Line One\nLine Two")

        let packets = ClosedCaptionPacketizer.encodeCuesToCEA608(cues)
        XCTAssertEqual(packets.count, 4) // 2 display packets + 2 EDM erase packets

        // Every single emitted CEA-608 byte must have strict odd parity
        for pkt in packets {
            XCTAssertFalse(pkt.bytes.isEmpty)
            for byte in pkt.bytes {
                XCTAssertEqual(byte.nonzeroBitCount % 2, 1, "byte 0x\(String(byte, radix: 16)) violated CEA-608 odd parity")
            }
        }

        // Verify RCL (0x14, 0x20) and EOC (0x14, 0x2F) are present (after masking parity bit)
        let firstPairs = packets[0].pairs
        XCTAssertEqual((firstPairs.first?.b1 ?? 0) & 0x7F, 0x14)
        XCTAssertEqual((firstPairs.first?.b2 ?? 0) & 0x7F, 0x20)
        XCTAssertEqual((firstPairs.last?.b1 ?? 0) & 0x7F, 0x14)
        XCTAssertEqual((firstPairs.last?.b2 ?? 0) & 0x7F, 0x2F)

        // Wrap into SMPTE ST 334-2 CEA-708 CDP and verify header 0x9669, 0x72, 0x74, and 8-bit modular checksum
        let cdp = ClosedCaptionPacketizer.wrapCEA708CDP(
            ccData: packets[0].tuplePairs,
            sequenceCounter: 0x0123,
            frameRateCode: 4
        )
        let cdpBytes = [UInt8](cdp)
        XCTAssertGreaterThanOrEqual(cdpBytes.count, 13)
        XCTAssertEqual(cdpBytes[0], 0x96)
        XCTAssertEqual(cdpBytes[1], 0x69)
        XCTAssertEqual(Int(cdpBytes[2]), cdpBytes.count)
        XCTAssertEqual(cdpBytes[7], 0x72)
        XCTAssertEqual(cdpBytes[cdpBytes.count - 4], 0x74)
        XCTAssertEqual(cdpBytes[5], 0x01)
        XCTAssertEqual(cdpBytes[6], 0x23)

        let modularSum = cdpBytes.reduce(0) { ($0 + Int($1)) & 0xFF }
        XCTAssertEqual(modularSum, 0, "CDP 8-bit modular checksum must sum to 0 mod 256")
        XCTAssertTrue(ClosedCaptionPacketizer.verifyCEA708CDP(cdp))

        // Flipping 1 bit must fail checksum verification
        var corrupted = cdpBytes
        corrupted[4] ^= 0x01
        XCTAssertFalse(ClosedCaptionPacketizer.verifyCEA708CDP(Data(corrupted)))
    }

    // MARK: - Test 5: EBU R128 / ATSC A/85 Broadcast Loudness Auditor

    func test5_EBUR128BroadcastLoudnessAuditor() async throws {
        // Generate calibrated -23.0 LUFS 1 kHz stereo sine wave at 48 kHz (4 seconds)
        // At 1 kHz, ITU-R BS.1770-4 K-weighting has ~+0.691 dB gain, cancelling the -0.691 offset,
        // so stereo sine with peak amplitude A = 10^(-23/20) gives L^2/2 + R^2/2 = A^2 => -23.0 LUFS.
        let sampleRate: Double = 48_000.0
        let durationSec: Double = 4.0
        let frameCount = Int(sampleRate * durationSec)
        let amplitude = Float(pow(10.0, -23.0 / 20.0))

        var chL = [Float](repeating: 0.0, count: frameCount)
        var chR = [Float](repeating: 0.0, count: frameCount)
        for i in 0..<frameCount {
            let phase = 2.0 * Double.pi * 1000.0 * (Double(i) / sampleRate)
            let s = amplitude * Float(sin(phase))
            chL[i] = s
            chR[i] = s
        }

        let report = BroadcastLoudnessAuditor.analyze(
            samples: [chL, chR],
            sampleRate: sampleRate,
            standard: .ebuR128
        )

        XCTAssertEqual(report.integratedLUFS, -23.0, accuracy: 1.0, "expected ~-23.0 LUFS, got \(report.integratedLUFS)")
        XCTAssertEqual(report.momentaryMaxLUFS, -23.0, accuracy: 1.0)
        XCTAssertEqual(report.shortTermMaxLUFS, -23.0, accuracy: 1.0)
        XCTAssertLessThan(report.truePeakDBTP, -1.0)
        XCTAssertTrue(report.compliant, "calibrated -23 LUFS stereo sine should be EBU R128 compliant; violations: \(report.violations)")
        XCTAssertEqual(report.violations, [])

        // Verify overly loud signal (-6 dBFS peak) triggers non-compliance for EBU R128
        let loudAmp = Float(pow(10.0, -6.0 / 20.0))
        let loudSamples = chL.map { ($0 / amplitude) * loudAmp }
        let loudReport = BroadcastLoudnessAuditor.analyze(
            samples: [loudSamples, loudSamples],
            sampleRate: sampleRate,
            standard: .ebuR128
        )
        XCTAssertFalse(loudReport.compliant)
        XCTAssertFalse(loudReport.violations.isEmpty)
        XCTAssertLessThan(loudReport.recommendedGainDB, -10.0)

        // Also test AVAssetReader file-based analysis on a real .wav with calibrated stereo audio
        let workDir = try makeTempDir("loudness")
        defer { try? FileManager.default.removeItem(at: workDir) }
        let audioWav = workDir.appendingPathComponent("calibrated.wav")
        try writeCalibratedStereoWAV(at: audioWav, targetLUFS: -23.0, durationSeconds: 1.5)
        let fileReport = try await BroadcastLoudnessAuditor.analyze(url: audioWav, standard: .ebuR128)
        XCTAssertEqual(fileReport.integratedLUFS, -23.0, accuracy: 1.0)
        XCTAssertTrue(fileReport.compliant, "file loudness violations: \(fileReport.violations)")
    }

    // MARK: - Test 6: Energy, Thermal & RSS Telemetry Sampler

    func test6_EnergyTelemetrySampler() {
        let sampler = EnergyTelemetrySampler()
        sampler.start()
        sampler.recordSample()

        // Run a brief deterministic numeric workload so CPU and elapsed time are measurable
        var acc: Double = 0.0
        for batch in 0..<4 {
            for i in 1...40_000 {
                let x = Double(i + batch)
                acc += sin(x * 0.001) * cos(x * 0.002)
            }
            sampler.recordSample()
        }
        XCTAssertTrue(acc.isFinite)

        let report = sampler.stop(framesProcessed: 120)
        XCTAssertGreaterThan(report.elapsedSeconds, 0.0)
        XCTAssertEqual(report.framesProcessed, 120)
        XCTAssertGreaterThan(report.fps, 0.0)
        XCTAssertGreaterThan(report.averageWatts, 0.0)
        XCTAssertGreaterThanOrEqual(report.peakWatts, report.averageWatts)
        XCTAssertTrue(report.joulesTotal.isFinite && report.joulesTotal > 0.0)
        XCTAssertTrue(report.joulesPerFrame.isFinite && report.joulesPerFrame > 0.0)
        XCTAssertTrue(report.fpsPerWatt.isFinite && report.fpsPerWatt > 0.0)
        XCTAssertTrue(report.peakRSSMB.isFinite && report.peakRSSMB > 0.0)
        XCTAssertGreaterThanOrEqual(report.sampleCount, 5)
        XCTAssertFalse(report.thermalStates.isEmpty)
        XCTAssertFalse(report.wattsSource.isEmpty)
    }
}
