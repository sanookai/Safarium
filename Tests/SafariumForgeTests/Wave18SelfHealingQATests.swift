@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import SafariumContainers
import SafariumCore
import SafariumForgeCore
import XCTest

/// Wave 18A & 18B — Self-Healing AI Video QA Defect Inspector + Surgical Closed-GOP Shot Repair Engine tests.
final class Wave18SelfHealingQATests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf-wave18-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func drawText(
        _ text: String,
        in ctx: CGContext,
        x: CGFloat,
        y: CGFloat,
        fontSize: CGFloat,
        color: CGColor
    ) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ]
        let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrStr)
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Creates an H.264 Closed-GOP MP4 with optional 48kHz mono AAC audio.
    private func writeSyntheticH264MP4(
        to url: URL,
        width: Int = 640,
        height: Int = 360,
        fps: Int = 24,
        totalFrames: Int,
        includeAudio: Bool,
        audioAmplitude: Float = 0.305,
        drawFrame: (_ frameIndex: Int, _ ctx: CGContext, _ width: Int, _ height: Int) -> Void
    ) async throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.movieTimeScale = CMTimeScale(fps * 100)

        let compressionProps: [String: Any] = [
            AVVideoAverageBitRateKey: 2_400_000,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            AVVideoMaxKeyFrameIntervalKey: fps,
            AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
            AVVideoAllowFrameReorderingKey: false,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProps,
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: adaptorAttrs
        )
        guard writer.canAdd(videoInput) else {
            throw SafariumError.encode("cannot add H.264 video input")
        }
        writer.add(videoInput)

        let sampleRate = 48_000
        var audioInput: AVAssetWriterInput?
        if includeAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Double(sampleRate),
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 96_000,
            ]
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(aIn) else {
                throw SafariumError.encode("cannot add AAC audio input")
            }
            writer.add(aIn)
            audioInput = aIn
        }

        guard writer.startWriting() else {
            throw writer.error ?? SafariumError.encode("AVAssetWriter failed to start")
        }
        writer.startSession(atSourceTime: .zero)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue

        // Prepare audio buffers if enabled
        var audioBuffers: [CMSampleBuffer] = []
        if includeAudio {
            let totalAudioSamples = Int((Double(totalFrames) / Double(fps) * Double(sampleRate)).rounded())
            let chunkSize = 1024
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Float64(sampleRate),
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4,
                mFramesPerPacket: 1,
                mBytesPerFrame: 4,
                mChannelsPerFrame: 1,
                mBitsPerChannel: 32,
                mReserved: 0
            )
            var audioFmtDesc: CMAudioFormatDescription?
            let fmtStatus = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &audioFmtDesc
            )
            guard fmtStatus == noErr, let aFmt = audioFmtDesc else {
                throw SafariumError.encode("CMAudioFormatDescriptionCreate failed: \(fmtStatus)")
            }

            let omega = 2.0 * Double.pi * 440.0 / Double(sampleRate)
            var sampleOffset = 0
            while sampleOffset < totalAudioSamples {
                let count = min(chunkSize, totalAudioSamples - sampleOffset)
                var pcm = [Float](repeating: 0.0, count: count)
                for i in 0..<count {
                    let phase = omega * Double(sampleOffset + i)
                    pcm[i] = audioAmplitude * Float(sin(phase))
                }
                let byteCount = count * MemoryLayout<Float>.size
                var blockBuf: CMBlockBuffer?
                let bSt = CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault,
                    memoryBlock: nil,
                    blockLength: byteCount,
                    blockAllocator: kCFAllocatorDefault,
                    customBlockSource: nil,
                    offsetToData: 0,
                    dataLength: byteCount,
                    flags: 0,
                    blockBufferOut: &blockBuf
                )
                guard bSt == kCMBlockBufferNoErr, let bb = blockBuf else {
                    throw SafariumError.encode("CMBlockBufferCreate failed: \(bSt)")
                }
                let cSt = pcm.withUnsafeBytes { raw -> OSStatus in
                    CMBlockBufferReplaceDataBytes(
                        with: raw.baseAddress!,
                        blockBuffer: bb,
                        offsetIntoDestination: 0,
                        dataLength: byteCount
                    )
                }
                guard cSt == kCMBlockBufferNoErr else {
                    throw SafariumError.encode("CMBlockBufferReplaceDataBytes failed: \(cSt)")
                }

                let pts = CMTime(value: CMTimeValue(sampleOffset), timescale: CMTimeScale(sampleRate))
                var timing = CMSampleTimingInfo(
                    duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                    presentationTimeStamp: pts,
                    decodeTimeStamp: .invalid
                )
                var sb: CMSampleBuffer?
                let sSt = CMSampleBufferCreate(
                    allocator: kCFAllocatorDefault,
                    dataBuffer: bb,
                    dataReady: true,
                    makeDataReadyCallback: nil,
                    refcon: nil,
                    formatDescription: aFmt,
                    sampleCount: count,
                    sampleTimingEntryCount: 1,
                    sampleTimingArray: &timing,
                    sampleSizeEntryCount: 0,
                    sampleSizeArray: nil,
                    sampleBufferOut: &sb
                )
                guard sSt == noErr, let created = sb else {
                    throw SafariumError.encode("CMSampleBufferCreate audio failed: \(sSt)")
                }
                audioBuffers.append(created)
                sampleOffset += count
            }
        }

        // Interleaved writer pump (Swift 6 Sendable-clean)
        var vIdx = 0
        var aIdx = 0
        var vDone = false
        var aDone = (audioInput == nil)

        while !vDone || !aDone {
            var progressed = false

            if !vDone && videoInput.isReadyForMoreMediaData {
                if vIdx < totalFrames {
                    var pixelBuffer: CVPixelBuffer?
                    if let pool = adaptor.pixelBufferPool {
                        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
                    } else {
                        CVPixelBufferCreate(
                            kCFAllocatorDefault,
                            width,
                            height,
                            kCVPixelFormatType_32BGRA,
                            adaptorAttrs as CFDictionary,
                            &pixelBuffer
                        )
                    }
                    guard let pb = pixelBuffer else {
                        throw SafariumError.encode("failed to allocate CVPixelBuffer")
                    }
                    CVPixelBufferLockBaseAddress(pb, [])
                    if let base = CVPixelBufferGetBaseAddress(pb),
                       let ctx = CGContext(
                           data: base,
                           width: width,
                           height: height,
                           bitsPerComponent: 8,
                           bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                           space: colorSpace,
                           bitmapInfo: bitmapInfo
                       ) {
                        drawFrame(vIdx, ctx, width, height)
                    }
                    CVPixelBufferUnlockBaseAddress(pb, [])

                    let pts = CMTime(value: CMTimeValue(vIdx), timescale: CMTimeScale(fps))
                    guard adaptor.append(pb, withPresentationTime: pts) else {
                        throw writer.error ?? SafariumError.encode("adaptor.append failed at frame \(vIdx)")
                    }
                    vIdx += 1
                    progressed = true
                } else {
                    videoInput.markAsFinished()
                    vDone = true
                    progressed = true
                }
            }

            if !aDone, let aIn = audioInput, aIn.isReadyForMoreMediaData {
                if aIdx < audioBuffers.count {
                    guard aIn.append(audioBuffers[aIdx]) else {
                        throw writer.error ?? SafariumError.encode("audioInput.append failed at chunk \(aIdx)")
                    }
                    aIdx += 1
                    progressed = true
                } else {
                    aIn.markAsFinished()
                    aDone = true
                    progressed = true
                }
            }

            if !progressed {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? SafariumError.encode("writer finish failed with status \(writer.status.rawValue)")
        }
    }

    // MARK: - Test 1: VideoDefectInspector Catches Planted Defects & Passes Clean Video

    func testVideoDefectInspectorCatchesPlantedDefectsAndPassesCleanVideo() async throws {
        let dir = try makeTempDir("inspector")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cleanURL = dir.appendingPathComponent("clean.mp4")
        let defectiveURL = dir.appendingPathComponent("defective.mp4")

        // 1. Build clean synthetic video: varying color/motion, centered safe text, -14 LUFS compliant audio
        try await writeSyntheticH264MP4(
            to: cleanURL,
            width: 640,
            height: 360,
            fps: 24,
            totalFrames: 72,
            includeAudio: true,
            audioAmplitude: 0.305
        ) { frame, ctx, w, h in
            let t = CGFloat(frame) / 72.0
            // Bright smoothly-varying teal/slate background
            let bgR = 0.16 + 0.10 * sin(t * 2.0 * .pi)
            let bgG = 0.32 + 0.12 * cos(t * 2.0 * .pi)
            let bgB = 0.52 + 0.10 * sin(t * 4.0 * .pi)
            ctx.setFillColor(red: bgR, green: bgG, blue: bgB, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

            // Moving vibrant accent bar well inside safe margins
            let barX = 90.0 + CGFloat(frame) * 5.0
            ctx.setFillColor(red: 0.95, green: 0.65, blue: 0.18, alpha: 1.0)
            ctx.fill(CGRect(x: barX, y: 70.0, width: 110.0, height: 64.0))

            // Centered title-safe text well away from all borders
            self.drawText(
                "SAFARIUM QA OK",
                in: ctx,
                x: 195.0,
                y: 190.0,
                fontSize: 30.0,
                color: CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            )
        }

        let cleanReport = try await VideoDefectInspector.inspect(url: cleanURL)
        XCTAssertTrue(
            cleanReport.passed,
            "Clean synthetic video should pass QA with 0 defects, got defects: \(cleanReport.defects)"
        )
        XCTAssertEqual(cleanReport.defectCount, 0)
        XCTAssertEqual(cleanReport.totalFrames, 72)
        XCTAssertNotNil(cleanReport.broadcastLoudness)
        XCTAssertEqual(cleanReport.broadcastLoudness?.compliant, true)

        // 2. Build defective synthetic video:
        //    - Frames 0..15: moving scene with near-edge clipped text touching left/top border
        //    - Frames 16..27 (12 frames): planted BLACK frames
        //    - Frames 28..43 (16 frames): planted FROZEN frames (identical non-black pixels)
        //    - Frames 44..71: moving scene with safe centered text
        try await writeSyntheticH264MP4(
            to: defectiveURL,
            width: 640,
            height: 360,
            fps: 24,
            totalFrames: 72,
            includeAudio: false
        ) { frame, ctx, w, h in
            if frame >= 16 && frame <= 27 {
                // Planted black-frame run
                ctx.setFillColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                return
            }

            if frame >= 28 && frame <= 43 {
                // Planted frozen-frame run (exact same static frame every frame)
                ctx.setFillColor(red: 0.20, green: 0.45, blue: 0.70, alpha: 1.0)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.setFillColor(red: 0.90, green: 0.30, blue: 0.25, alpha: 1.0)
                ctx.fill(CGRect(x: 200, y: 120, width: 220, height: 120))
                return
            }

            // Active moving background
            ctx.setFillColor(red: 0.12, green: 0.16, blue: 0.24, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let barX = 80.0 + CGFloat((frame * 9) % 360)
            ctx.setFillColor(red: 0.22, green: 0.78, blue: 0.55, alpha: 1.0)
            ctx.fill(CGRect(x: barX, y: 80.0, width: 100.0, height: 55.0))

            if frame < 16 {
                // Planted near-edge clipped text touching the left and top borders (< 2.5% margin)
                self.drawText(
                    "CLIPPED EDGE TEXT ALERT",
                    in: ctx,
                    x: 2.0,
                    y: CGFloat(h) - 28.0,
                    fontSize: 28.0,
                    color: CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
                )
            } else {
                self.drawText(
                    "SAFE CENTER TEXT",
                    in: ctx,
                    x: 190.0,
                    y: 190.0,
                    fontSize: 26.0,
                    color: CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
                )
            }
        }

        let defectReport = try await VideoDefectInspector.inspect(url: defectiveURL)
        XCTAssertFalse(defectReport.passed, "Defective video must fail QA inspection")
        XCTAssertGreaterThanOrEqual(defectReport.defectCount, 3)

        // Verify exact black frame run [16..27]
        let blackDefects = defectReport.defects.filter { $0.type == .blackFrames }
        XCTAssertEqual(blackDefects.count, 1, "Expected 1 black frame run, got \(blackDefects)")
        if let black = blackDefects.first {
            XCTAssertEqual(black.startFrame, 16)
            XCTAssertEqual(black.endFrame, 27)
            XCTAssertFalse(black.suggestedFix.isEmpty)
        }

        // Verify exact frozen frame run [28..43]
        let frozenDefects = defectReport.defects.filter { $0.type == .frozenFrames }
        XCTAssertEqual(frozenDefects.count, 1, "Expected 1 frozen frame run, got \(frozenDefects)")
        if let frozen = frozenDefects.first {
            XCTAssertEqual(frozen.startFrame, 28)
            XCTAssertEqual(frozen.endFrame, 43)
            XCTAssertFalse(frozen.suggestedFix.isEmpty)
        }

        // Verify text edge clipping detection
        let clipDefects = defectReport.defects.filter { $0.type == .textEdgeClipping }
        XCTAssertFalse(clipDefects.isEmpty, "Expected textEdgeClipping defect to be caught")
        if let clipped = clipDefects.first {
            XCTAssertNotNil(clipped.boundingBox)
            XCTAssertEqual(clipped.boundingBox?.count, 4)
            XCTAssertLessThan(clipped.measuredValue, 0.025)
            XCTAssertFalse(clipped.suggestedFix.isEmpty)
        }
    }

    // MARK: - Test 2: SurgicalRepairEngine Preserves Untouched Shots Bit-Exact

    func testSurgicalRepairPreservesUntouchedShotsBitExact() async throws {
        let dir = try makeTempDir("surgical-repair")
        defer { try? FileManager.default.removeItem(at: dir) }

        let originalURL = dir.appendingPathComponent("original_3shot.mp4")
        let replacementURL = dir.appendingPathComponent("shot1_orange_fix.mp4")
        let repairedURL = dir.appendingPathComponent("repaired_3shot.mp4")

        // 1. Build 3-shot Closed-GOP H.264 MP4 (24fps, 3s = 72 frames, keyframes forced every 24 frames):
        //    - Shot 0 (0-1s, frames 0..23): moving blue
        //    - Shot 1 (1-2s, frames 24..47): planted BLACK defective shot
        //    - Shot 2 (2-3s, frames 48..71): moving green
        try await writeSyntheticH264MP4(
            to: originalURL,
            width: 640,
            height: 360,
            fps: 24,
            totalFrames: 72,
            includeAudio: false
        ) { frame, ctx, w, h in
            if frame < 24 {
                // Shot 0: moving blue
                let localF = frame
                ctx.setFillColor(red: 0.12, green: 0.28, blue: 0.78, alpha: 1.0)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                let bx = 60.0 + CGFloat(localF) * 18.0
                ctx.setFillColor(red: 0.65, green: 0.88, blue: 1.0, alpha: 1.0)
                ctx.fill(CGRect(x: bx, y: 110.0, width: 120.0, height: 140.0))
            } else if frame < 48 {
                // Shot 1: planted BLACK defective shot
                ctx.setFillColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            } else {
                // Shot 2: moving green
                let localF = frame - 48
                ctx.setFillColor(red: 0.14, green: 0.62, blue: 0.28, alpha: 1.0)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                let bx = 460.0 - CGFloat(localF) * 18.0
                ctx.setFillColor(red: 0.92, green: 0.96, blue: 0.45, alpha: 1.0)
                ctx.fill(CGRect(x: bx, y: 110.0, width: 120.0, height: 140.0))
            }
        }

        // Confirm inspector catches the planted black shot in the original file
        let preReport = try await VideoDefectInspector.inspect(url: originalURL)
        XCTAssertFalse(preReport.passed)
        XCTAssertTrue(preReport.defects.contains { $0.type == .blackFrames && $0.startFrame == 24 && $0.endFrame == 47 })

        // 2. Build 1s replacement clip for Shot 1 (moving orange, identical codec/dimensions/GOP)
        try await writeSyntheticH264MP4(
            to: replacementURL,
            width: 640,
            height: 360,
            fps: 24,
            totalFrames: 24,
            includeAudio: false
        ) { frame, ctx, w, h in
            ctx.setFillColor(red: 0.88, green: 0.42, blue: 0.10, alpha: 1.0)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let bx = 80.0 + CGFloat(frame) * 16.0
            ctx.setFillColor(red: 1.0, green: 0.92, blue: 0.72, alpha: 1.0)
            ctx.fill(CGRect(x: bx, y: 100.0, width: 130.0, height: 160.0))
        }

        // 3. Surgically repair ONLY Shot 1 [1.0, 2.0) without re-encoding Shot 0 or Shot 2
        let patch = SurgicalRepairPatch(
            shotIndex: 1,
            startSeconds: 1.0,
            endSeconds: 2.0,
            replacementPath: replacementURL.path
        )
        let repairReport = try await SurgicalRepairEngine.repair(
            originalURL: originalURL,
            outputURL: repairedURL,
            patches: [patch],
            verifyConformance: true,
            verifyDefects: true
        )

        XCTAssertEqual(repairReport.repairedShotCount, 1)
        XCTAssertTrue(
            repairReport.untouchedShotsPreservedBitExact,
            "Untouched shots must be preserved bit-for-bit without re-encoding"
        )
        XCTAssertEqual(repairReport.untouchedVideoPacketHash, repairReport.repairedOutputUntouchedHash)
        XCTAssertEqual(repairReport.untouchedVideoPacketHash.count, 64)
        XCTAssertGreaterThan(repairReport.untouchedVideoPacketCount, 0)
        XCTAssertEqual(repairReport.untouchedVideoPacketCount, 48)
        XCTAssertGreaterThan(repairReport.repairedVideoPacketCount, 0)
        XCTAssertEqual(repairReport.repairedVideoPacketCount, 24)
        XCTAssertTrue(repairReport.conformancePassed, "Repaired output must pass BitstreamConformance")
        XCTAssertEqual(
            repairReport.remainingDefectCount,
            0,
            "Repaired 3-shot video must have 0 remaining defects"
        )
    }
}
