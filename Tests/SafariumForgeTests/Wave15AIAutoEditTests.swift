import AVFoundation
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import SafariumCore
import SafariumForgeCore
import XCTest

/// Wave 15B & 15C — Thai-Safe Smart Auto-Reframe v2 + Auto-Highlight & Silence-Cut Engine tests.
final class Wave15AIAutoEditTests: XCTestCase {

    // MARK: - Synthetic 16:9 (640x360, 24fps, 3s) A/V Test Asset Builder

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf-wave15-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Generates a synthetic 640x360, 24fps, 3.0s MP4 with:
    /// - Moving bright subject during [0..1s] and [2..3s], static dim scene during [1..2s]
    /// - Crisp Thai + English caption banner across the lower third
    /// - 48kHz mono AAC audio: 1.0s 440Hz tone, 1.0s silence, 1.0s 660Hz tone
    private func createSyntheticTestVideo(at url: URL) async throws {
        let width = 640
        let height = 360
        let fps = 24
        let totalSeconds = 3
        let totalFrames = fps * totalSeconds
        let sampleRate = 48_000

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: adaptorAttrs
        )
        writer.add(videoInput)

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "Wave15Tests", code: 1)
        }
        writer.startSession(atSourceTime: .zero)

        // Prepare audio format description (Int16 mono 48kHz PCM)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var formatDescOpt: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescOpt
        )
        guard fmtStatus == noErr, let audioFormatDesc = formatDescOpt else {
            throw NSError(domain: "Wave15Tests", code: Int(fmtStatus))
        }

        let audioChunkFrames = 2_000 // 24 chunks per second -> aligns cleanly with 24fps
        let totalAudioChunks = (sampleRate * totalSeconds) / audioChunkFrames

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, 22.0, nil)

        var frameIdx = 0
        var chunkIdx = 0
        var videoMarkedFinished = false
        var audioMarkedFinished = false

        while frameIdx < totalFrames || chunkIdx < totalAudioChunks {
            if writer.status != .writing {
                throw writer.error ?? NSError(domain: "Wave15Tests", code: 3)
            }
            let vReady = (frameIdx < totalFrames) && videoInput.isReadyForMoreMediaData
            let aReady = (chunkIdx < totalAudioChunks) && audioInput.isReadyForMoreMediaData

            if !vReady && !aReady {
                try await Task.sleep(nanoseconds: 2_000_000)
                continue
            }

            let pushVideo: Bool
            if vReady && aReady {
                let vTime = Double(frameIdx) / Double(fps)
                let aTime = Double(chunkIdx * audioChunkFrames) / Double(sampleRate)
                pushVideo = vTime <= aTime
            } else {
                pushVideo = vReady
            }

            if pushVideo {
                var pbOpt: CVPixelBuffer?
                if let pool = adaptor.pixelBufferPool {
                    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOpt)
                }
                guard let pb = pbOpt else {
                    throw NSError(domain: "Wave15Tests", code: 2)
                }
                drawSyntheticFrame(
                    into: pb,
                    width: width,
                    height: height,
                    frameIndex: frameIdx,
                    fps: fps,
                    colorSpace: colorSpace,
                    bitmapInfo: bitmapInfo,
                    font: font
                )
                let pts = CMTime(value: CMTimeValue(frameIdx), timescale: CMTimeScale(fps))
                XCTAssertTrue(adaptor.append(pb, withPresentationTime: pts))
                frameIdx += 1
                if frameIdx >= totalFrames && !videoMarkedFinished {
                    videoInput.markAsFinished()
                    videoMarkedFinished = true
                }
            } else {
                let startSample = chunkIdx * audioChunkFrames
                let sb = try makeAudioSampleBuffer(
                    startSample: startSample,
                    frameCount: audioChunkFrames,
                    sampleRate: sampleRate,
                    formatDesc: audioFormatDesc
                )
                XCTAssertTrue(audioInput.append(sb))
                chunkIdx += 1
                if chunkIdx >= totalAudioChunks && !audioMarkedFinished {
                    audioInput.markAsFinished()
                    audioMarkedFinished = true
                }
            }
        }

        if !videoMarkedFinished {
            videoInput.markAsFinished()
        }
        if !audioMarkedFinished {
            audioInput.markAsFinished()
        }
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, "synthetic writer error: \(writer.error?.localizedDescription ?? "none")")
    }

    private func drawSyntheticFrame(
        into pb: CVPixelBuffer,
        width: Int,
        height: Int,
        frameIndex: Int,
        fps: Int,
        colorSpace: CGColorSpace,
        bitmapInfo: UInt32,
        font: CTFont
    ) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bpr,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return }

        let t = Double(frameIndex) / Double(fps)
        let isMiddleStatic = (t >= 1.0 && t < 2.0)

        // Background
        if isMiddleStatic {
            ctx.setFillColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0)
        } else {
            ctx.setFillColor(red: 0.10, green: 0.14, blue: 0.22, alpha: 1.0)
        }
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Moving bright subject during active seconds [0..1s] and [2..3s]; static dim box in [1..2s]
        if isMiddleStatic {
            ctx.setFillColor(red: 0.14, green: 0.16, blue: 0.19, alpha: 1.0)
            ctx.fill(CGRect(x: 280, y: 140, width: 80, height: 80))
        } else {
            let phase = t < 1.0 ? t : (t - 2.0)
            let subjectX = t < 1.0
                ? (90.0 + phase * 380.0)
                : (470.0 - phase * 360.0)
            let subjectY = 140.0 + sin(phase * .pi * 4.0) * 36.0
            ctx.setFillColor(red: 0.98, green: 0.82, blue: 0.18, alpha: 1.0)
            ctx.fillEllipse(in: CGRect(x: subjectX - 42.0, y: subjectY - 42.0, width: 84.0, height: 84.0))

            // High-contrast moving accent bars for strong motion energy
            ctx.setFillColor(red: 0.18, green: 0.92, blue: 0.78, alpha: 1.0)
            let barX = 40.0 + fmod(phase * 520.0, 500.0)
            ctx.fill(CGRect(x: barX, y: 240.0, width: 64.0, height: 48.0))
        }

        // Crisp high-contrast caption banner (CGContext has bottom-left origin)
        ctx.setFillColor(red: 0.03, green: 0.03, blue: 0.05, alpha: 0.92)
        ctx.fill(CGRect(x: 180, y: 28, width: 280, height: 44))

        let caption = "SAFARIUM LIVE 2026" as CFString
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
        ]
        if let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, caption, attrs as CFDictionary) {
            let line = CTLineCreateWithAttributedString(attrStr)
            ctx.textPosition = CGPoint(x: 200, y: 42)
            CTLineDraw(line, ctx)
        }
    }

    private func makeAudioSampleBuffer(
        startSample: Int,
        frameCount: Int,
        sampleRate: Int,
        formatDesc: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        var samples = [Int16](repeating: 0, count: frameCount)
        let srD = Double(sampleRate)
        let twoPi = 2.0 * Double.pi

        for i in 0..<frameCount {
            let globalIdx = startSample + i
            let t = Double(globalIdx) / srD
            let sampleVal: Double
            if t < 1.0 {
                // Speech-like 440Hz tone modulated at 5Hz
                let env = 0.75 + 0.25 * sin(twoPi * 5.0 * t)
                sampleVal = 0.40 * env * sin(twoPi * 440.0 * t)
            } else if t < 2.0 {
                // Dead-air silence
                sampleVal = 0.0
            } else {
                // Speech-like 660Hz tone modulated at 6Hz
                let env = 0.75 + 0.25 * sin(twoPi * 6.0 * t)
                sampleVal = 0.40 * env * sin(twoPi * 660.0 * t)
            }
            let clamped = max(-1.0, min(1.0, sampleVal))
            samples[i] = Int16(clamped * 32767.0)
        }

        let byteCount = frameCount * MemoryLayout<Int16>.size
        var blockBufOpt: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBufOpt
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuf = blockBufOpt else {
            throw NSError(domain: "Wave15Tests", code: Int(createStatus))
        }

        let replaceStatus = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuf,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else {
            throw NSError(domain: "Wave15Tests", code: Int(replaceStatus))
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: CMTime(value: CMTimeValue(startSample), timescale: CMTimeScale(sampleRate)),
            decodeTimeStamp: .invalid
        )
        var sampleSize = MemoryLayout<Int16>.size
        var sbOpt: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuf,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sbOpt
        )
        guard sbStatus == noErr, let sb = sbOpt else {
            throw NSError(domain: "Wave15Tests", code: Int(sbStatus))
        }
        return sb
    }

    // MARK: - Test 1: Thai-Safe Smart Auto-Reframe v2 (16:9 -> 9:16)

    func testSmartReframeThaiSafe9x16() async throws {
        let dir = try makeTempDir("reframe")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("input_16x9.mp4")
        let outURL = dir.appendingPathComponent("reframed_9x16.mp4")
        try await createSyntheticTestVideo(at: srcURL)

        let config = SmartReframeConfig(
            aspect: .vertical9x16,
            protectThaiText: true,
            protectFaces: true,
            safeMarginRatio: 0.06,
            smoothingAlpha: 0.18,
            maxPanPixelsPerSecond: 360.0,
            analysisStrideFrames: 5
        )
        let report = try await SmartReframeThaiSafe.reframe(
            inputURL: srcURL,
            outputURL: outURL,
            config: config
        )

        XCTAssertEqual(report.sourceWidth, 640)
        XCTAssertEqual(report.sourceHeight, 360)
        XCTAssertEqual(report.outputWidth % 2, 0, "outputWidth must be even")
        XCTAssertEqual(report.outputHeight % 2, 0, "outputHeight must be even")
        XCTAssertEqual(report.outputWidth, 202)
        XCTAssertEqual(report.outputHeight, 360)
        XCTAssertGreaterThan(report.framesProcessed, 60)
        XCTAssertFalse(report.keyframes.isEmpty, "keyframes should not be empty")
        XCTAssertLessThanOrEqual(
            report.maxPanVelocityPxPerSec,
            config.maxPanPixelsPerSecond + 0.5,
            "pan velocity must remain bounded by maxPanPixelsPerSecond"
        )

        // Verify consecutive keyframe pan speeds are also bounded
        for i in 1..<report.keyframes.count {
            let prev = report.keyframes[i - 1]
            let curr = report.keyframes[i]
            let dt = max(1.0 / 120.0, curr.timeSeconds - prev.timeSeconds)
            let dist = hypot(curr.cropX - prev.cropX, curr.cropY - prev.cropY)
            let vel = dist / dt
            XCTAssertLessThanOrEqual(vel, config.maxPanPixelsPerSecond + 1.0)
        }

        // Verify output MP4 is playable, matches reframed dimensions, and preserved audio
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
        let outAsset = AVURLAsset(url: outURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playable = try await outAsset.load(.isPlayable)
        XCTAssertTrue(playable, "reframed output MP4 should be playable")

        let vTracks = try await outAsset.loadTracks(withMediaType: .video)
        XCTAssertEqual(vTracks.count, 1)
        if let vt = vTracks.first {
            let natSize = try await vt.load(.naturalSize)
            XCTAssertEqual(Int(natSize.width.rounded()), 202)
            XCTAssertEqual(Int(natSize.height.rounded()), 360)
        }
        let aTracks = try await outAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(aTracks.count, 1, "audio track should be preserved during reframe")
    }

    // MARK: - Test 2: Auto Silence-Cut Removes Middle Dead Air

    func testAutoEditCutSilenceRemovesMiddleDeadAir() async throws {
        let dir = try makeTempDir("silence")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("input_with_silence.mp4")
        let outURL = dir.appendingPathComponent("tightened.mp4")
        try await createSyntheticTestVideo(at: srcURL)

        let config = AutoSilenceCutConfig(
            silenceThresholdDB: -38.0,
            minSilenceSeconds: 0.65,
            paddingSeconds: 0.12,
            crossfadeSeconds: 0.02
        )
        let report = try await AutoEditEngine.cutSilence(
            inputURL: srcURL,
            outputURL: outURL,
            config: config
        )

        XCTAssertEqual(report.segments.count, 2, "expected 2 kept speech segments around the middle 1.0s silence")
        XCTAssertLessThan(
            report.editedDurationSeconds,
            report.originalDurationSeconds - 0.4,
            "edited duration should be at least 0.4s shorter after removing middle 1.0s silence"
        )
        XCTAssertGreaterThan(report.removedSeconds, 0.4)
        XCTAssertEqual(report.outputPath, outURL.path)

        // Verify output MP4 is playable and shorter
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
        let outAsset = AVURLAsset(url: outURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playable = try await outAsset.load(.isPlayable)
        XCTAssertTrue(playable, "silence-cut output MP4 should be playable")

        let outDur = CMTimeGetSeconds(try await outAsset.load(.duration))
        XCTAssertLessThan(outDur, report.originalDurationSeconds - 0.4)
        XCTAssertGreaterThan(outDur, 1.5)

        let vTracks = try await outAsset.loadTracks(withMediaType: .video)
        let aTracks = try await outAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(vTracks.count, 1)
        XCTAssertEqual(aTracks.count, 1)
    }

    // MARK: - Test 3: Auto-Highlight Scoring & Reel Extraction

    func testAutoEditExtractHighlightsRanksActiveOverSilent() async throws {
        let dir = try makeTempDir("highlights")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("input_highlights.mp4")
        let outURL = dir.appendingPathComponent("highlight_reel.mp4")
        try await createSyntheticTestVideo(at: srcURL)

        // First score all 3 non-overlapping 1.0s windows to verify active windows beat silent/static middle
        let fullPlanConfig = AutoHighlightConfig(
            targetClipDurationSeconds: 1.0,
            maxClips: 3,
            windowStepSeconds: 1.0,
            audioWeight: 0.45,
            motionWeight: 0.35,
            visualWeight: 0.20
        )
        let plan = try await AutoEditEngine.planHighlights(inputURL: srcURL, config: fullPlanConfig)
        XCTAssertEqual(plan.segments.count, 3)

        let firstWindow = try XCTUnwrap(plan.segments.first(where: { $0.startSeconds < 0.5 }))
        let middleWindow = try XCTUnwrap(plan.segments.first(where: { $0.startSeconds >= 0.9 && $0.startSeconds < 1.5 }))
        let lastWindow = try XCTUnwrap(plan.segments.first(where: { $0.startSeconds >= 1.9 }))

        XCTAssertGreaterThan(
            firstWindow.score,
            middleWindow.score + 0.15,
            "active audio+motion [0..1s] window (\(firstWindow.score)) should score higher than silent/static [1..2s] (\(middleWindow.score))"
        )
        XCTAssertGreaterThan(
            lastWindow.score,
            middleWindow.score + 0.15,
            "active audio+motion [2..3s] window (\(lastWindow.score)) should score higher than silent/static [1..2s] (\(middleWindow.score))"
        )

        // Extract top 2 highlights -> should pick the two active windows and export playable MP4
        let extractConfig = AutoHighlightConfig(
            targetClipDurationSeconds: 1.0,
            maxClips: 2,
            windowStepSeconds: 1.0,
            audioWeight: 0.45,
            motionWeight: 0.35,
            visualWeight: 0.20
        )
        let report = try await AutoEditEngine.extractHighlights(
            inputURL: srcURL,
            outputURL: outURL,
            config: extractConfig
        )

        XCTAssertEqual(report.segments.count, 2)
        XCTAssertEqual(report.outputPath, outURL.path)
        XCTAssertFalse(
            report.segments.contains(where: { $0.startSeconds >= 0.9 && $0.startSeconds < 1.5 }),
            "silent/static middle window should not be chosen when maxClips == 2"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
        let outAsset = AVURLAsset(url: outURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playable = try await outAsset.load(.isPlayable)
        XCTAssertTrue(playable, "highlight reel MP4 should be playable")

        let outDur = CMTimeGetSeconds(try await outAsset.load(.duration))
        XCTAssertGreaterThan(outDur, 1.5)
        XCTAssertLessThan(outDur, 2.5)

        let vTracks = try await outAsset.loadTracks(withMediaType: .video)
        let aTracks = try await outAsset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(vTracks.count, 1)
        XCTAssertEqual(aTracks.count, 1)
    }
}
