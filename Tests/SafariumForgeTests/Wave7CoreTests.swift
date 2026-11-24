import CoreGraphics
import CoreVideo
import Darwin
import Foundation
import SafariumCore
@testable import SafariumForgeCore
import XCTest

private final class Wave7LockedStorage<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.withLock { body(&value) }
    }
}

final class Wave7CoreTests: XCTestCase {
    private func makeShortAPFSDir(_ prefix: String) throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        chmod(dir.path, 0o700)
        return dir
    }

    // MARK: - Task 1: ForgeAdaptiveWebKitPool.collectProcessTreePIDs(rootPIDs:)

    func testCollectProcessTreePIDsCapturesChildrenAndSamplerIncludesFootprint() async throws {
        let dir = try makeShortAPFSDir("w7tree")
        defer { try? FileManager.default.removeItem(at: dir) }

        let childPidFile = dir.appendingPathComponent("child.pid")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [
            "-c",
            "sleep 20 & echo $! > \"\(childPidFile.path)\"; wait",
        ]
        try proc.run()
        defer {
            if proc.isRunning { proc.terminate() }
            proc.waitUntilExit()
        }

        // Wait up to 2s for child sleep PID file to appear
        var childPID: pid_t = 0
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if let text = try? String(contentsOf: childPidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               let parsed = pid_t(text), parsed > 0 {
                childPID = parsed
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertGreaterThan(childPID, 0, "expected child sleep PID from sh")
        defer {
            if childPID > 0 { _ = Darwin.kill(childPID, SIGKILL) }
        }

        let tree = ForgeAdaptiveWebKitPool.collectProcessTreePIDs(rootPIDs: [proc.processIdentifier])
        XCTAssertTrue(tree.contains(proc.processIdentifier), "tree must include root worker PID \(proc.processIdentifier): \(tree)")
        XCTAssertTrue(tree.contains(childPID), "tree must include descendant child PID \(childPID): \(tree)")

        let selfOnlyMB = SafariumRuntimeTelemetry.currentFootprintMB()
        let combinedMB = ForgeAdaptiveWebKitPool.processAndChildrenFootprintMB(childPIDs: [proc.processIdentifier])
        XCTAssertGreaterThan(combinedMB, selfOnlyMB, "processAndChildrenFootprintMB must include parent+child tree footprints")

        // Verify telemetrySampler inside ForgeAdaptiveWebKitPool receives expanded process-tree PIDs
        let sampledPIDs = Wave7LockedStorage<[[pid_t]]>([])
        let pool = try ForgeAdaptiveWebKitPool(
            config: ForgeAdaptivePoolConfig(requestedWorkers: 1, totalFrames: 2, fps: 30, chunkFrames: 2),
            telemetrySampler: { pids in
                sampledPIDs.withLock { $0.append(pids) }
                return ForgeAdaptiveWebKitPool.liveSample(childPIDs: pids)
            }
        )
        pool.trackChildProcess(proc)
        _ = try await pool.runChunks(stagingDirectory: dir.appendingPathComponent("stage", isDirectory: true), overwrite: true) { _, _, segURL in
            try Data("placeholder".utf8).write(to: segURL)
        }
        let observed = sampledPIDs.withLock { $0 }
        XCTAssertFalse(observed.isEmpty)
        XCTAssertTrue(
            observed.contains { $0.contains(proc.processIdentifier) && $0.contains(childPID) },
            "telemetrySampler must receive tracked worker and its child process tree: \(observed)"
        )
    }

    // MARK: - Task 2: ForgeIncrementalCache Recursive Directory Input Hashing

    func testIncrementalCacheHashesDirectoryInputsLexicographicallySkippingAppleDoubleAndRejectingBadEntries() throws {
        let dir = try makeShortAPFSDir("w7dir")
        defer { try? FileManager.default.removeItem(at: dir) }

        let inputsDir = dir.appendingPathComponent("assets", isDirectory: true)
        let subDir = inputsDir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: subDir, withIntermediateDirectories: true)

        let fileA = inputsDir.appendingPathComponent("alpha.txt")
        let fileB = subDir.appendingPathComponent("beta.bin")
        try Data("hello".utf8).write(to: fileA)
        try Data([1, 2, 3, 4]).write(to: fileB)

        let spec = ForgeSceneSpec(
            sceneId: "dir-scene",
            inputs: [inputsDir.path],
            opsHash: "ops-v1",
            durationSeconds: 1.0,
            fps: 30,
            width: 320,
            height: 180,
            codec: "h264"
        )

        let kInitial = try ForgeIncrementalCache.cacheKey(for: spec, hashingInputFiles: [])
        let kInitialSync = ForgeIncrementalCache.cacheKey(for: spec)

        // Adding ._ AppleDouble sidecars must NOT invalidate the key
        try Data("appledouble-root".utf8).write(to: inputsDir.appendingPathComponent("._foo"))
        try Data("appledouble-nested".utf8).write(to: subDir.appendingPathComponent("._beta.bin"))
        let kWithAppleDouble = try ForgeIncrementalCache.cacheKey(for: spec, hashingInputFiles: [])
        XCTAssertEqual(kInitial, kWithAppleDouble)
        XCTAssertEqual(kInitialSync, ForgeIncrementalCache.cacheKey(for: spec))

        // Modifying one regular file inside a subdirectory (even same byte count) MUST invalidate the key
        try Data([1, 2, 3, 9]).write(to: fileB)
        let kModified = try ForgeIncrementalCache.cacheKey(for: spec, hashingInputFiles: [])
        XCTAssertNotEqual(kInitial, kModified)
        XCTAssertNotEqual(kInitialSync, ForgeIncrementalCache.cacheKey(for: spec))

        // Adding a symlink pointing outside the directory MUST throw
        let outsideFile = dir.appendingPathComponent("outside.txt")
        try Data("secret".utf8).write(to: outsideFile)
        let escapingLink = subDir.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: escapingLink, withDestinationURL: outsideFile)
        XCTAssertThrowsError(try ForgeIncrementalCache.cacheKey(for: spec, hashingInputFiles: []))
        try FileManager.default.removeItem(at: escapingLink)

        // Adding a non-regular entry (FIFO) inside the directory MUST throw
        let fifoPath = inputsDir.appendingPathComponent("pipe.fifo").path
        XCTAssertEqual(Darwin.mkfifo(fifoPath, 0o600), 0)
        XCTAssertThrowsError(try ForgeIncrementalCache.cacheKey(for: spec, hashingInputFiles: []))
    }

    // MARK: - Task 3: ForgeLLSRUpscaler Session Reuse + Resize/Deinit EndSession + Headless Metal Check

    func testLLSRUpscalerReusesSessionAcrossSameDimensionsAndEndsOnResize() throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let engine = try ForgeMetalFilterEngine(bakeArchive: false)
        var upscaler: ForgeLLSRUpscaler? = try ForgeLLSRUpscaler(engine: engine)

        let pb360 = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: 540, height: 960, pixelFormat: .bgra)
        let res1 = try XCTUnwrap(upscaler).upscale(
            lowResPB: pb360,
            targetWidth: 1080,
            targetHeight: 1920,
            policy: ForgeLLSRPolicy(enabled: true)
        )
        XCTAssertEqual(CVPixelBufferGetWidth(res1.outputPB), 1080)

        let res2 = try XCTUnwrap(upscaler).upscale(
            lowResPB: pb360,
            targetWidth: 1080,
            targetHeight: 1920,
            policy: ForgeLLSRPolicy(enabled: true)
        )
        XCTAssertEqual(CVPixelBufferGetWidth(res2.outputPB), 1080)

        if ForgeLLSRUpscaler.isHardwareLLSRSupported(), res1.usedLLSR {
            XCTAssertEqual(upscaler?.llsrSessionCreationCount, 1, "same dimensions must reuse cached VTFrameProcessor session")
            XCTAssertEqual(upscaler?.llsrSessionEndCount, 0)
            XCTAssertTrue(upscaler?.hasCachedLLSRSession == true)

            let pb270 = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: 270, height: 480, pixelFormat: .bgra)
            let res3 = try XCTUnwrap(upscaler).upscale(
                lowResPB: pb270,
                targetWidth: 540,
                targetHeight: 960,
                policy: ForgeLLSRPolicy(enabled: true)
            )
            if res3.usedLLSR {
                XCTAssertEqual(upscaler?.llsrSessionCreationCount, 2, "dimension change must start new VTFrameProcessor session")
                XCTAssertGreaterThanOrEqual(upscaler?.llsrSessionEndCount ?? 0, 1, "dimension change must call endSession()")
            }
        }
        upscaler?.resetLLSRSession()
        XCTAssertFalse(upscaler?.hasCachedLLSRSession == true)
        upscaler = nil
    }
}
