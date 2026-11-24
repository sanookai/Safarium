import AVFoundation
import CoreMedia
import SafariumCore
import XCTest

@MainActor
final class SubtitleWriterTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare() }

    private func decodeTX3GText(_ payload: Data) -> String? {
        guard payload.count >= 2 else { return nil }
        let len = (Int(payload[0]) << 8) | Int(payload[1])
        guard len > 0, payload.count >= 2 + len else { return "" }
        return String(data: payload.subdata(in: 2..<(2 + len)), encoding: .utf8)
    }

    func testPolishAndThaiSRTBuildsValidTX3GTrackInMP4() async throws {
        let dir = try makeTempDir("tx3g-polish-thai")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srt = "\u{FEFF}" + [
            "1\r\n00:00:00,200 --> 00:00:00,800\r\nŻółć, gęślą jaźń — Łukasz\r\n",
            "2\r\n00:00:01,100 --> 00:00:01,700\r\nกำ ปิ๊ก แสงมณี โปแลนด์\r\n",
        ].joined(separator: "\r\n")
        let duration = CMTime(value: 60, timescale: 30) // 2.0s

        let cues = try SafariumTX3G.parseSRT(text: srt, offsetSeconds: 0, duration: duration)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "Żółć, gęślą jaźń — Łukasz")
        XCTAssertEqual(cues[1].text, "กำ ปิ๊ก แสงมณี โปแลนด์")

        let (fmt, samples) = try SafariumTX3G.buildContiguousSamples(cues: cues, duration: duration, width: 320, height: 180)
        // Expected 5 samples: [0..200ms clear], [200..800ms cue1], [800..1100ms clear], [1100..1700ms cue2], [1700..2000ms clear]
        XCTAssertEqual(samples.count, 5)

        let mp4 = dir.appendingPathComponent("subtitled.mp4")
        let writer = try AVAssetWriter(url: mp4, fileType: .mp4)
        writer.movieTimeScale = 600

        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 180,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 800_000,
                AVVideoExpectedSourceFrameRateKey: 30,
            ],
        ])
        vi.mediaTimeScale = 600
        vi.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 180,
        ])
        let si = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: fmt)
        si.mediaTimeScale = 1000
        si.expectsMediaDataInRealTime = false
        si.languageCode = "pol"
        si.extendedLanguageTag = "pl"
        si.marksOutputTrackAsEnabled = true
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            si.mediaDataLocation = .sparselyInterleavedWithMainMediaData
        }
        #endif
        XCTAssertTrue(writer.canAdd(vi))
        writer.add(vi)
        XCTAssertTrue(writer.canAdd(si))
        writer.add(si)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let page = try await Page(config: PageConfig(width: 320, height: 180))
        try await page.load(.html("<body style='margin:0;background:#123456'></body>"))
        let snap = try await page.snapshot()
        for f in 0..<60 {
            while !vi.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 500_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            try snap.draw(into: pb!, width: 320, height: 180)
            XCTAssertTrue(adaptor.append(pb!, withPresentationTime: CMTime(value: Int64(f), timescale: 30)))
        }
        vi.markAsFinished()
        for s in samples {
            while !si.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 500_000) }
            XCTAssertTrue(si.append(s))
        }
        si.markAsFinished()
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "failed")

        // Verify via AVAsset legible selection group + AVAssetReader sample payloads
        let asset = AVURLAsset(url: mp4, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let group = try await asset.loadMediaSelectionGroup(for: .legible)
        let legible = try XCTUnwrap(group)
        let plOption = legible.options.first { $0.extendedLanguageTag == "pl" || $0.locale?.language.languageCode?.identifier == "pl" }
        XCTAssertNotNil(plOption, "Expected playable Polish (pol/pl) legible option")
        XCTAssertEqual(plOption?.isPlayable, true)

        let subTrack = try await asset.loadTracks(withMediaType: .subtitle).first!
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: subTrack, outputSettings: nil)
        reader.add(out)
        XCTAssertTrue(reader.startReading())

        var decodedTexts: [String] = []
        var clearCount = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
            var length = 0
            var ptr: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
            if let ptr {
                let data = Data(bytes: ptr, count: length)
                let txt = decodeTX3GText(data) ?? ""
                if txt.isEmpty { clearCount += 1 }
                else { decodedTexts.append(txt) }
            }
        }
        XCTAssertEqual(decodedTexts, ["Żółć, gęślą jaźń — Łukasz", "กำ ปิ๊ก แสงมณี โปแลนด์"])
        XCTAssertGreaterThanOrEqual(clearCount, 3)
    }

    func testEmptySRTProducesSingleClearSample() throws {
        let dur = CMTime(value: 30, timescale: 30)
        let cues = try SafariumTX3G.parseSRT(text: "  \r\n\n ", offsetSeconds: 0, duration: dur)
        XCTAssertTrue(cues.isEmpty)
        let (_, samples) = try SafariumTX3G.buildContiguousSamples(cues: cues, duration: dur, width: 320, height: 180)
        XCTAssertEqual(samples.count, 1)
    }

    func testOverlappingCuesRemainMonotonicNonNegative() throws {
        let srt = """
        1
        00:00:00,100 --> 00:00:01,000
        First cue

        2
        00:00:00,600 --> 00:00:01,500
        Second cue
        """
        let dur = CMTime(value: 60, timescale: 30)
        let cues = try SafariumTX3G.parseSRT(text: srt, offsetSeconds: 0, duration: dur)
        let (_, samples) = try SafariumTX3G.buildContiguousSamples(cues: cues, duration: dur, width: 320, height: 180)
        var prevEnd = CMTime.zero
        for s in samples {
            let pts = CMSampleBufferGetPresentationTimeStamp(s)
            let d = CMSampleBufferGetDuration(s)
            XCTAssertGreaterThanOrEqual(CMTimeCompare(pts, prevEnd), 0)
            XCTAssertGreaterThan(CMTimeCompare(d, .zero), 0)
            prevEnd = CMTimeAdd(pts, d)
        }
    }

    func testOversizedCueThrowsEncodeError() throws {
        let giant = String(repeating: "ก", count: 25000) // > 65535 UTF-8 bytes
        let srt = "1\n00:00:00,000 --> 00:00:01,000\n\(giant)\n"
        let dur = CMTime(value: 30, timescale: 30)
        let cues = try SafariumTX3G.parseSRT(text: srt, offsetSeconds: 0, duration: dur)
        XCTAssertThrowsError(try SafariumTX3G.buildContiguousSamples(cues: cues, duration: dur, width: 320, height: 180))
    }

    func testOverflowingSRTTimestampThrowsErrorNotCrash() throws {
        let srt = "1\n9999999999999999:00:00,000 --> 9999999999999999:00:01,000\nOverflow\n"
        let dur = CMTime(value: 30, timescale: 30)
        XCTAssertThrowsError(try SafariumTX3G.parseSRT(text: srt, offsetSeconds: 0, duration: dur))
    }

    func testWhitespaceOnlySeparatorLinesParseAllCues() throws {
        let srt = "1\n00:00:00,100 --> 00:00:00,400\nOne\n   \n2\n00:00:00,500 --> 00:00:00,900\nTwo\n"
        let dur = CMTime(value: 30, timescale: 30)
        let cues = try SafariumTX3G.parseSRT(text: srt, offsetSeconds: 0, duration: dur)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues.map(\.text), ["One", "Two"])
    }

    func testNonIntegerMillisecondDurationAlignsExactCMTime() throws {
        // 2 frames at 30 fps = 2/30s = 66.666...ms (rounded ms would be 67ms > 2/30s)
        let dur = CMTime(value: 2, timescale: 30)
        let srt = "1\n00:00:00,000 --> 00:00:00,040\nHi\n"
        let cues = try SafariumTX3G.parseSRT(text: srt, offsetSeconds: 0, duration: dur)
        let (_, samples) = try SafariumTX3G.buildContiguousSamples(cues: cues, duration: dur, width: 320, height: 180)
        XCTAssertFalse(samples.isEmpty)
        var lastEnd = CMTime.zero
        for s in samples {
            let pts = CMSampleBufferGetPresentationTimeStamp(s)
            let d = CMSampleBufferGetDuration(s)
            XCTAssertGreaterThan(CMTimeCompare(d, .zero), 0)
            lastEnd = CMTimeAdd(pts, d)
        }
        XCTAssertLessThanOrEqual(CMTimeCompare(lastEnd, dur), 0, "subtitle track must never overrun exact video duration")
        XCTAssertEqual(CMTimeCompare(lastEnd, dur), 0, "subtitle track must end cleanly at exact video duration")
    }
}
