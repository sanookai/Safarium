import AVFoundation
import CoreGraphics
import Foundation
import SafariumCore
import XCTest

@MainActor
final class PlatformBackendTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare() }

    func testAppleMacOSBackendCapabilitiesReportLiveRuntimeState() throws {
        let backend = AppleMacOSBackend.current
        let cap: any SafariumPlatformCapabilities = backend
        let web: any WebFrameRendererBackend = backend
        let enc: any VideoEncoderBackend = backend
        let fs: any FilesystemCloneBackend = backend
        _ = (web, enc)

        XCTAssertEqual(cap.osName, "macOS")
        XCTAssertFalse(cap.osVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(["arm64", "x86_64"].contains(cap.architecture), "unexpected arch: \(cap.architecture)")
        XCTAssertTrue(cap.supportsWindowlessWebKit)
        XCTAssertTrue(cap.supportsVideoToolbox)
        XCTAssertTrue(cap.supportsAudioToolbox)
        XCTAssertEqual(cap.supportsANE, backend.isAppleSilicon && !backend.isRunningInVM)

        let expectedMetal = SafariumMetalContext.shared != nil
        XCTAssertEqual(cap.hasMetalGPU, expectedMetal)
        XCTAssertEqual(cap.metalDeviceName, SafariumMetalContext.shared?.device.name)

        let tmpURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
        XCTAssertTrue(fs.supportsClonefile(at: tmpURL))
        XCTAssertTrue(cap.supportsAPFSClonefile)

        let snap = cap.capabilitySnapshot(probePath: tmpURL)
        XCTAssertEqual(snap.osName, cap.osName)
        XCTAssertEqual(snap.hasMetalGPU, cap.hasMetalGPU)
        XCTAssertEqual(snap.supportsAPFSClonefile, true)
        XCTAssertEqual(snap.supportsWindowlessWebKit, true)
        XCTAssertEqual(snap.supportsVideoToolbox, true)
        XCTAssertEqual(snap.supportsAudioToolbox, true)
        XCTAssertEqual(snap.isAppleSilicon, cap.isAppleSilicon)
    }

    func testAppleMacOSBackendWebRenderEncodeAndClonefile() async throws {
        let dir = try makeTempDir("platform-backend")
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = AppleMacOSBackend.current
        XCTAssertTrue(backend.supportsCodec(.h264))
        XCTAssertTrue(backend.supportsCodec(.proRes4444))

        let snap = try await backend.renderWebFrame(
            source: .html("<body style='margin:0;background:#12aa34'></body>"),
            config: PageConfig(width: 160, height: 120),
            seekSeconds: nil
        )
        XCTAssertEqual(snap.width, 160)
        XCTAssertEqual(snap.height, 120)
        let px = snap.pixel(x: 80, y: 60)
        XCTAssertGreaterThan(Int(px.g), Int(px.r) + 50)

        let mp4 = dir.appendingPathComponent("backend.mp4")
        let sink = try backend.makeFrameSink(
            url: mp4,
            width: 160,
            height: 120,
            fps: 30,
            codec: .h264,
            bitrate: 1_000_000,
            quality: nil,
            pixelFormat: .nv12Left,
            profile: .lowRamClosedGOP
        )
        for _ in 0..<3 {
            try await sink.append(snap)
        }
        try await sink.finish()
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp4.path))

        let cloned = dir.appendingPathComponent("cloned.mp4")
        let usedClone = try backend.cloneOrCopy(from: mp4, to: cloned, overwrite: true)
        XCTAssertTrue(usedClone, "APFS temp dir should clonefile")
        XCTAssertEqual(try Data(contentsOf: mp4), try Data(contentsOf: cloned))

        let missing = dir.appendingPathComponent("missing.mp4")
        XCTAssertThrowsError(try backend.cloneOrCopy(from: missing, to: cloned, overwrite: true))
    }
}
