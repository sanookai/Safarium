import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SafariumCore
import SafariumForgeCore
import XCTest

/// Wave 9 — Zero-Copy `VTFrameProcessor` Pre-Encode Suite tests
/// (TemporalDenoiseSession, OpticalFlowRetimer, MotionBlurSession, Capabilities probe).
final class Wave9VTProcessorTests: XCTestCase {

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf-wave9-vtp-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeIOSurfaceNV12(width: Int, height: Int, seed: UInt8) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let st = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attrs as CFDictionary,
            &pb
        )
        guard st == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "Wave9VTProcessorTests", code: Int(st))
        }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(buf, 0) {
            let yBpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 0)
            let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    // Add deterministic grain pattern
                    let noise = UInt8(((x &* 17 &+ y &* 31 &+ Int(seed) &* 13) & 0x1F))
                    yPtr[y * yBpr + x] = UInt8(min(235, 96 + (x * 64) / max(1, width) + Int(noise)))
                }
            }
        }
        if let uvBase = CVPixelBufferGetBaseAddressOfPlane(buf, 1) {
            let uvBpr = CVPixelBufferGetBytesPerRowOfPlane(buf, 1)
            memset(uvBase, 128, uvBpr * (height / 2))
        }
        return buf
    }

    func testCapabilitiesProbeReturnsValidStructure() {
        let caps = ForgeVTProcessorCapabilities.probe()
        // On Apple Silicon macOS 15.4+, opticalFlow / frameRateConversion / motionBlur are supported;
        // on macOS 26+, temporalNoiseFilter is also supported. Just assert probe completes cleanly.
        _ = (caps.temporalNoiseFilter, caps.frameRateConversion, caps.opticalFlow, caps.motionBlur, caps.offlineSuperResolution, caps.lowLatencySuperResolution)
    }

    func testTemporalDenoiseSessionWithSceneCutReset() throws {
        let caps = ForgeVTProcessorCapabilities.probe()
        let session = try TemporalDenoiseSession(width: 320, height: 180, strength: 0.65)
        defer { session.end() }
        if caps.temporalNoiseFilter {
            XCTAssertTrue(session.isHardwareActive, "expected hardware VTTemporalNoiseFilter session to activate")
        }

        for i in 0..<6 {
            let pb = try makeIOSurfaceNV12(width: 320, height: 180, seed: UInt8(i + 1))
            let pts = CMTime(value: CMTimeValue(i), timescale: 30)
            let out = try session.process(pb, pts: pts, isSceneCut: i == 3)
            XCTAssertEqual(CVPixelBufferGetWidth(out), 320)
            XCTAssertEqual(CVPixelBufferGetHeight(out), 180)
        }
        XCTAssertEqual(session.framesProcessed, 6)
    }

    func testMotionBlurSessionProcessesFramesCleanly() throws {
        let session = MotionBlurSession(width: 320, height: 180, strength: 45)
        defer { session.end() }

        let f0 = try makeIOSurfaceNV12(width: 320, height: 180, seed: 1)
        let f1 = try makeIOSurfaceNV12(width: 320, height: 180, seed: 2)
        let f2 = try makeIOSurfaceNV12(width: 320, height: 180, seed: 3)
        let out = try session.process(
            current: f1,
            previous: f0,
            next: f2,
            pts: CMTime(value: 1, timescale: 30),
            previousPTS: CMTime(value: 0, timescale: 30),
            nextPTS: CMTime(value: 2, timescale: 30)
        )
        XCTAssertEqual(CVPixelBufferGetWidth(out), 320)
        XCTAssertEqual(CVPixelBufferGetHeight(out), 180)
    }

    func testOpticalFlowRetimer24To48FPS() async throws {
        let dir = try makeTempDir("retime")
        defer { try? FileManager.default.removeItem(at: dir) }

        let srcURL = dir.appendingPathComponent("src24.mp4")
        let sink = try AVAssetWriterSink(
            url: srcURL,
            width: 320,
            height: 180,
            fps: 24,
            codec: .hevc,
            bitrate: 2_000_000,
            pixelFormat: .nv12Left,
            profile: .baseline
        )
        var bgra = [UInt8](repeating: 0, count: 320 * 180 * 4)
        for f in 0..<12 {
            for y in 0..<180 {
                for x in 0..<320 {
                    let off = (y * 320 + x) * 4
                    let inside = abs(x - (40 + f * 18)) < 24 && abs(y - 90) < 30
                    bgra[off + 0] = inside ? 40 : 30
                    bgra[off + 1] = inside ? 220 : 40
                    bgra[off + 2] = inside ? 245 : 60
                    bgra[off + 3] = 255
                }
            }
            try await sink.append { pb in
                try bgra.withUnsafeBytes { raw in
                    try SafariumAccelerate.convertRawBGRAToNV12BT709Left(
                        bgra: raw.baseAddress!,
                        bgraBytesPerRow: 320 * 4,
                        into: pb,
                        width: 320,
                        height: 180
                    )
                }
            }
        }
        try await sink.finish()

        let outURL = dir.appendingPathComponent("out48.mp4")
        let rep = try await OpticalFlowRetimer.retime(
            inputURL: srcURL,
            outputURL: outURL,
            targetFPS: 48,
            codec: .hevc10,
            bitrate: 2_500_000,
            overwrite: true
        )
        XCTAssertEqual(rep.sourceFrames, 12)
        XCTAssertGreaterThanOrEqual(rep.outputFrames, 20)
        XCTAssertGreaterThan(rep.outputBytes, 1_000)
    }
}
