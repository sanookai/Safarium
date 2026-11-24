import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import SafariumCore
import XCTest

@MainActor
final class FrameSinkUpgradeTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare() }

    private func alphaTestSnapshot(shift: Int = 0) -> Snapshot {
        let w = 320, h = 180
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: sRGB, bitmapInfo: info)!
        // Top/background: transparent alpha = 0
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setBlendMode(.copy)
        // Middle band (CG y=60..110 -> topY=70..120): alpha = 128
        ctx.setFillColor(CGColor(colorSpace: sRGB, components: [0.2, 0.55, 0.95, 128.0 / 255.0])!)
        ctx.fill(CGRect(x: 40, y: 60, width: 240, height: 50))
        // Bottom band (CG y=10..50 -> topY=130..170): alpha = 255
        ctx.setFillColor(CGColor(colorSpace: sRGB, components: [0.91, 0.70, 0.29, 1.0])!)
        ctx.fill(CGRect(x: 60 + shift, y: 10, width: 200, height: 40))
        return Snapshot(cgImage: ctx.makeImage()!)
    }

    func testHEVCAlphaRoundTripPreservesZeroSemiAndOpaqueAlpha() async throws {
        let dir = try makeTempDir("sink-hevc-alpha")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("alpha.mov")
        let sink = try AVAssetWriterSink(
            url: url, width: 320, height: 180, fps: 30,
            codec: .hevcAlpha, quality: 0.85, pixelFormat: .bgra
        )
        for i in 0..<8 {
            try await sink.append(alphaTestSnapshot(shift: i * 2))
        }
        try await sink.finish()

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let descs = try await track.load(.formatDescriptions)
        let fd = try XCTUnwrap(descs.first)
        let exts = CMFormatDescriptionGetExtensions(fd) as? [String: Any]
        let containsAlpha = (exts?[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? Bool) ?? false
        XCTAssertTrue(containsAlpha, "HEVCWithAlpha track must declare ContainsAlphaChannel")
        let chars = try await track.load(.mediaCharacteristics)
        XCTAssertTrue(chars.contains(.containsAlphaChannel), "Track must declare .containsAlphaChannel characteristic")

        let frame = try await readBackFrame(url, index: 4)
        XCTAssertEqual(frame.w, 320)
        XCTAssertEqual(frame.h, 180)
        func px(topX x: Int, topY y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
            let off = (y * frame.w + x) * 4
            return (frame.bgra[off], frame.bgra[off + 1], frame.bgra[off + 2], frame.bgra[off + 3])
        }
        let transparent = px(topX: 10, topY: 10)
        let semi = px(topX: 160, topY: 95)   // CG y=85 -> topY=180-85=95
        let opaque = px(topX: 160, topY: 150) // CG y=30 -> topY=180-30=150
        XCTAssertLessThanOrEqual(transparent.a, 4, "Transparent corner alpha must stay ~0, got \(transparent.a)")
        XCTAssertLessThanOrEqual(abs(Int(semi.a) - 128), 10, "Semi alpha must stay ~128, got \(semi.a)")
        XCTAssertGreaterThanOrEqual(opaque.a, 248, "Opaque region alpha must stay ~255, got \(opaque.a)")
    }

    func testH264SinkCreatesTaggedBT709MovieAndExactFrameCount() async throws {
        let dir = try makeTempDir("sink-h264")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.mp4")
        let sink = try AVAssetWriterSink(
            url: url, width: 320, height: 180, fps: 30,
            codec: .h264, bitrate: 2_000_000, pixelFormat: .bgra
        )
        let snap = alphaTestSnapshot()
        for _ in 0..<6 {
            try await sink.append(snap)
        }
        try await sink.finish()

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let dur = try await asset.load(.duration)
        XCTAssertEqual(dur, CMTime(value: 6, timescale: 30))
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let trackDescs = try await track.load(.formatDescriptions)
        let fd = try XCTUnwrap(trackDescs.first)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(fd), kCMVideoCodecType_H264)
        XCTAssertEqual(
            CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
            kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String
        )
    }

    func testNV12VImageSinkProducesValidBT709Video() async throws {
        let dir = try makeTempDir("sink-nv12")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nv12.mp4")
        let sink = try AVAssetWriterSink(
            url: url, width: 320, height: 180, fps: 30,
            codec: .h264, bitrate: 2_000_000, pixelFormat: .nv12vImage
        )
        let page = try await Page(config: PageConfig(width: 320, height: 180))
        try await page.load(.html("<body style='margin:0;background:#e8b34b'></body>"))
        let snap = try await page.snapshot()
        for _ in 0..<5 {
            try await sink.append(snap)
        }
        try await sink.finish()

        let frame = try await readBackFrame(url, index: 2)
        let off = (90 * 320 + 160) * 4
        XCTAssertGreaterThan(Int(frame.bgra[off + 2]), 210)
        XCTAssertGreaterThan(Int(frame.bgra[off + 1]), 155)
        XCTAssertLessThan(Int(frame.bgra[off]), 100)
    }

    func testHEVCAlphaRejectsNV12PixelFormat() throws {
        let dir = try makeTempDir("sink-reject-nv12")
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(
            try AVAssetWriterSink(
                url: dir.appendingPathComponent("bad.mov"),
                width: 320, height: 180, fps: 30,
                codec: .hevcAlpha, quality: 0.85, pixelFormat: .nv12vImage
            )
        )
    }

    func testInputReadyGateCancelDoesNotHang() async throws {
        let dir = try makeTempDir("sink-cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cancel.mp4")
        let sink = try AVAssetWriterSink(url: url, width: 320, height: 180, fps: 30, codec: .h264, bitrate: 1_000_000)
        try await sink.append(alphaTestSnapshot())
        sink.cancel()
        do {
            try await sink.append(alphaTestSnapshot())
            XCTFail("append after cancel should throw")
        } catch {
            // Expected failure after cancel
        }
    }

    func testPreCancelledTaskWaitAndAppendThrowsCancellationWithoutHanging() async throws {
        let dir = try makeTempDir("sink-pre-cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("pre-cancel.mp4")
        let sink = try AVAssetWriterSink(url: url, width: 320, height: 180, fps: 30, codec: .h264, bitrate: 1_000_000)
        defer { sink.cancel() }

        let task = Task {
            withUnsafeCurrentTask { _ in }
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            try await sink.append(alphaTestSnapshot())
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("cancelled task append must throw CancellationError")
        } catch is CancellationError {
            // Expected
        }
    }

    func testNV12LeftPixelFormatFixATagsAndEncodesCleanly() async throws {
        let dir = try makeTempDir("sink-nv12-left")
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try AVAssetWriterSink(
            url: dir.appendingPathComponent("odd.mp4"),
            width: 321, height: 180, fps: 30, codec: .h264, bitrate: 1_000_000,
            pixelFormat: .nv12Left
        ))

        let url = dir.appendingPathComponent("nv12-left.mp4")
        let sink = try AVAssetWriterSink(
            url: url, width: 320, height: 180, fps: 30,
            codec: .h264, bitrate: 1_500_000, pixelFormat: .nv12Left
        )
        for i in 0..<4 {
            try await sink.append(alphaTestSnapshot(shift: i * 2))
        }
        try await sink.finish()

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let descs = try await track.load(.formatDescriptions)
        let fd = try XCTUnwrap(descs.first)
        let exts = CMFormatDescriptionGetExtensions(fd) as? [String: Any]
        XCTAssertEqual(exts?[kCVImageBufferColorPrimariesKey as String] as? String, kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        XCTAssertEqual(exts?[kCVImageBufferTransferFunctionKey as String] as? String, kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        XCTAssertEqual(exts?[kCVImageBufferYCbCrMatrixKey as String] as? String, kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)

        let decoded = try await readBackFrame(url, index: 2)
        XCTAssertEqual(decoded.w, 320)
        XCTAssertEqual(decoded.h, 180)
    }

    func testLowRamClosedGOPProfileSetsExpectedCompressionAndPoolAttrs() async throws {
        let profile = EncoderProfile.lowRamClosedGOP
        XCTAssertFalse(profile.allowFrameReordering)
        XCTAssertFalse(profile.allowOpenGOP)
        XCTAssertEqual(profile.poolAllocationThreshold, 2)
        XCTAssertTrue(profile.prioritizeEncodingSpeed)

        let settings = AVAssetWriterSink.buildVideoSettings(
            width: 320, height: 180, fps: 30, codec: .h264,
            bitrate: 1_000_000, quality: nil, profile: profile
        )
        let props = try XCTUnwrap(settings[AVVideoCompressionPropertiesKey] as? [String: Any])
        XCTAssertEqual(props[AVVideoAllowFrameReorderingKey] as? Bool, false)
        XCTAssertEqual(props["AllowOpenGOP"] as? Bool, false)
        XCTAssertEqual(props["PrioritizeEncodingSpeedOverQuality"] as? Bool, true)

        let pbAttrs = AVAssetWriterSink.pixelBufferAttributes(
            width: 320, height: 180, pixelFormat: .nv12Left, allocationThreshold: 2
        )
        XCTAssertEqual(pbAttrs[kCVPixelBufferPixelFormatTypeKey as String] as? OSType, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        XCTAssertEqual(pbAttrs[kCVPixelBufferPoolAllocationThresholdKey as String] as? Int, 2)

        let dir = try makeTempDir("sink-lowram")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("lowram.mp4")
        let sink = try AVAssetWriterSink(
            url: url, width: 320, height: 180, fps: 30,
            codec: .h264, bitrate: 1_000_000, pixelFormat: .nv12Left, profile: profile
        )
        let standalone = try sink.allocateStandalonePixelBuffer()
        try sink.populate(alphaTestSnapshot(shift: 0), into: standalone)
        try await sink.appendPixelBuffer(standalone, presentationTime: CMTime(value: 0, timescale: 30))
        try await sink.appendPixelBuffer(standalone, presentationTime: CMTime(value: 1, timescale: 30))
        sink.flushPool()
        try await sink.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testStaticHoldProbeScriptAndReuse() async throws {
        XCTAssertTrue(StaticHoldProbe.script.contains("__sfDirtyProbe"))
        XCTAssertTrue(StaticHoldProbe.script.contains("beginStep()"))
        XCTAssertTrue(StaticHoldProbe.script.contains("consumeStep()"))
        let userScript = StaticHoldProbe.userScript()
        XCTAssertEqual(userScript.injectionTime, .atDocumentStart)
        XCTAssertFalse(userScript.isForMainFrameOnly)

        let dir = try makeTempDir("sink-hold-reuse")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hold.mp4")
        let sink = try AVAssetWriterSink(
            url: url, width: 320, height: 180, fps: 30,
            codec: .h264, bitrate: 1_000_000, pixelFormat: .nv12Left, profile: .lowRamClosedGOP
        )
        let holdBuf = try sink.allocateStandalonePixelBuffer()
        try sink.populate(alphaTestSnapshot(shift: 4), into: holdBuf)
        for i in 0..<6 {
            try await sink.appendPixelBuffer(holdBuf, presentationTime: CMTime(value: Int64(i), timescale: 30))
        }
        try await sink.finish()

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let dur = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(dur), 0.2, accuracy: 0.05)
        let frame = try await readBackFrame(url, index: 5)
        XCTAssertEqual(frame.w, 320)
    }
}
