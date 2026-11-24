import AVFoundation
import CoreGraphics
import SafariumCore
import VideoToolbox
import XCTest

/// Regression: AVAssetWriterInput.init raised an uncatchable NSInvalidArgumentException (SIGABRT) when the selected
/// encoder (software fallback) did not support PrioritizeEncodingSpeedOverQuality.
@MainActor
final class FrameSinkEncoderSupportTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare() }

    private let softwareOnly: [String: Any] = [
        kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false,
    ]

    func testSoftwareEncoderDoesNotCrashAndKeepsSpecWhenSpeedHintUnsupported() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sf-sw-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try AVAssetWriterSink(
            url: url, width: 320, height: 180, fps: 30, codec: .h264, bitrate: 2_000_000,
            profile: .lowRamClosedGOP, encoderSpecification: softwareOnly)
        // Software H.264 lacks the speed hint (probed: 71 props vs 140 with HW): it must be dropped, and only hints.
        XCTAssertTrue(sink.droppedCompressionProperties.contains(
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String))
        let allowed = AVAssetWriterSink.droppableCompressionKeys + [kVTCompressionPropertyKey_AllowOpenGOP as String]
        for key in sink.droppedCompressionProperties { XCTAssertTrue(allowed.contains(key)) }
        let ctx = CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 1280,
                            space: Snapshot.colorSpace, bitmapInfo: Snapshot.bitmapInfo)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        for _ in 0..<3 { try await sink.append(Snapshot(cgImage: ctx.makeImage()!)) }
        try await sink.finish()
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first
        let size = try await XCTUnwrap(track).load(.naturalSize)
        XCTAssertEqual(size.width, 320); XCTAssertEqual(size.height, 180)
    }

    func testResolveKeepsSettingsIdenticalWhenSupported() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sf-r-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        let s = AVAssetWriterSink.buildVideoSettings(width: 320, height: 180, fps: 30, codec: .h264,
                                                     bitrate: 2_000_000, quality: nil, profile: .lowRamClosedGOP)
        let r = try AVAssetWriterSink.resolveSupportedSettings(s, writer: writer, codec: .h264, canApply: { _ in true })
        XCTAssertTrue(r.dropped.isEmpty)
        XCTAssertEqual(NSDictionary(dictionary: r.settings), NSDictionary(dictionary: s))
    }

    func testResolveDropsOnlyHintsAndNeverQualityOrGOP() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sf-d-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(url: url, fileType: .mp4)
        let s = AVAssetWriterSink.buildVideoSettings(width: 320, height: 180, fps: 30, codec: .h264,
                                                     bitrate: 2_000_000, quality: nil, profile: .lowRamClosedGOP)
        let prio = kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String
        let r = try AVAssetWriterSink.resolveSupportedSettings(s, writer: writer, codec: .h264, canApply: {
            ($0[AVVideoCompressionPropertiesKey] as? [String: Any])?[prio] == nil
        })
        XCTAssertEqual(r.dropped, [prio])
        var expected = (s[AVVideoCompressionPropertiesKey] as! [String: Any]); expected[prio] = nil
        XCTAssertEqual(NSDictionary(dictionary: r.settings[AVVideoCompressionPropertiesKey] as! [String: Any]),
                       NSDictionary(dictionary: expected))
        // A non-droppable rejection (bitrate) must throw, not be silently dropped.
        XCTAssertThrowsError(try AVAssetWriterSink.resolveSupportedSettings(s, writer: writer, codec: .h264, canApply: { _ in false }))
    }
}
