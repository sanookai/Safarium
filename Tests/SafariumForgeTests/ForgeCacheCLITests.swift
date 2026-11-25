import CoreGraphics
import Foundation
import XCTest
@testable import SafariumCore
@testable import SafariumForgeCore

final class ForgeCacheCLITests: XCTestCase {
    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safarium-cache-cli-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func forgeBinaryURL() throws -> URL {
        let productsDir = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let sibling = productsDir.appendingPathComponent("safarium-forge")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        let isRelease = productsDir.lastPathComponent.lowercased() == "release"
        let scratchDir = productsDir.deletingLastPathComponent().deletingLastPathComponent()
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        build.currentDirectoryURL = packageRoot
        var buildArgs = ["swift", "build", "--product", "safarium-forge", "--scratch-path", scratchDir.path]
        if isRelease {
            buildArgs += ["-c", "release"]
        }
        build.arguments = buildArgs
        let errPipe = Pipe()
        build.standardError = errPipe
        try build.run()
        build.waitUntilExit()
        if build.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        let errTxt = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw SafariumError.invalidState("could not locate or build safarium-forge binary at \(sibling.path): \(errTxt)")
    }

    private func runForge(_ args: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let bin = try forgeBinaryURL()
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return (
            p.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }

    private func decodeJSONDict(_ text: String) throws -> [String: Any] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Expected JSON object, got: \(text)")
            return [:]
        }
        return obj
    }

    private func writeValidMP4(at url: URL, rgb: (CGFloat, CGFloat, CGFloat)) async throws {
        let sink = try AVAssetWriterSink(
            url: url,
            width: 64,
            height: 64,
            fps: 30,
            codec: .h264,
            bitrate: 400_000,
            pixelFormat: .nv12Left
        )
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let bi = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4, space: cs, bitmapInfo: bi)!
        ctx.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let snap = Snapshot(cgImage: ctx.makeImage()!)
        try await sink.append(snap)
        try await sink.append(snap)
        try await sink.finish()
    }

    func testComputeKeyHandlesDirectoriesDeterministicallyAndIgnoresAppleDouble() throws {
        let root = try makeTempDir("dir-hash")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = root.appendingPathComponent("assets", isDirectory: true)
        let sub = dir.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("hello-a".utf8).write(to: dir.appendingPathComponent("a.txt"))
        try Data("hello-b".utf8).write(to: sub.appendingPathComponent("b.txt"))

        let key1 = try ForgeShotCache.computeKey(namespace: "ns", paramsJSON: "{\"v\":1}", inputURLs: [dir])

        // AppleDouble sidecars must be ignored cleanly.
        try Data("appledouble-junk".utf8).write(to: dir.appendingPathComponent("._a.txt"))
        try Data("appledouble-nested".utf8).write(to: sub.appendingPathComponent("._b.txt"))
        let keyWithAppleDouble = try ForgeShotCache.computeKey(namespace: "ns", paramsJSON: "{\"v\":1}", inputURLs: [dir])
        XCTAssertEqual(key1, keyWithAppleDouble)

        // Modifying a real file inside directory must invalidate the digest.
        try Data("hello-b-mutated".utf8).write(to: sub.appendingPathComponent("b.txt"))
        let keyMutated = try ForgeShotCache.computeKey(namespace: "ns", paramsJSON: "{\"v\":1}", inputURLs: [dir])
        XCTAssertNotEqual(key1, keyMutated)

        // Symlink escaping directory root must fail loudly.
        let outside = root.appendingPathComponent("secret.txt")
        try Data("outside".utf8).write(to: outside)
        let link = dir.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try ForgeShotCache.computeKey(namespace: "ns", paramsJSON: "{\"v\":1}", inputURLs: [dir]))
    }

    func testRegularFileComputeKeyRemainsBackwardCompatible() throws {
        let root = try makeTempDir("file-compat")
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("clip.bin")
        try Data([0x01, 0x02, 0x03, 0x04]).write(to: file)
        let digest = try ForgeShotCache.computeKey(namespace: "shot-ns", paramsJSON: "{\"q\":1}", inputURLs: [file])
        XCTAssertEqual(digest.count, 64)

        let res = try runForge(["cache", "hash", "--namespace", "shot-ns", "--params", "{\"q\":1}", "--inputs", file.path])
        XCTAssertEqual(res.status, 0, res.stderr)
        let json = try decodeJSONDict(res.stdout)
        XCTAssertEqual(json["key"] as? String, digest)
    }

    func testCLICacheHashSupportsDirectoryInputsAndIgnoresAppleDouble() throws {
        let root = try makeTempDir("cli-dir-hash")
        defer { try? FileManager.default.removeItem(at: root) }

        let dir = root.appendingPathComponent("scene", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("<html>hi</html>".utf8).write(to: dir.appendingPathComponent("index.html"))

        let res1 = try runForge(["cache", "hash", "--namespace", "html-dir", "--inputs", dir.path])
        XCTAssertEqual(res1.status, 0, res1.stderr)
        let key1 = try decodeJSONDict(res1.stdout)["key"] as? String
        XCTAssertEqual(key1?.count, 64)

        try Data("junk".utf8).write(to: dir.appendingPathComponent("._index.html"))
        let res2 = try runForge(["cache", "hash", "--namespace", "html-dir", "--inputs", dir.path])
        XCTAssertEqual(res2.status, 0, res2.stderr)
        let key2 = try decodeJSONDict(res2.stdout)["key"] as? String
        XCTAssertEqual(key1, key2)
    }

    func testCLICacheStatsLookupAndPruneAcrossSceneAndShotEntries() async throws {
        let root = try makeTempDir("cli-unified")
        defer { try? FileManager.default.removeItem(at: root) }

        let cacheRoot = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        _ = chmod(cacheRoot.path, 0o700)

        // 1. Store two scene (.mp4 + .meta.json) entries via ForgeIncrementalCache.
        let seg1 = root.appendingPathComponent("seg1.mp4")
        let seg2 = root.appendingPathComponent("seg2.mp4")
        try await writeValidMP4(at: seg1, rgb: (0.9, 0.2, 0.2))
        try await writeValidMP4(at: seg2, rgb: (0.2, 0.3, 0.9))

        let spec1 = ForgeSceneSpec(sceneId: "sc1", inputs: [], opsHash: "h1", durationSeconds: 2.0 / 30.0, fps: 30, width: 64, height: 64, codec: "h264")
        let spec2 = ForgeSceneSpec(sceneId: "sc2", inputs: [], opsHash: "h2", durationSeconds: 2.0 / 30.0, fps: 30, width: 64, height: 64, codec: "h264")
        let sceneKey1 = ForgeIncrementalCache.cacheKey(for: spec1)
        let sceneKey2 = ForgeIncrementalCache.cacheKey(for: spec2)

        let storedScene1 = try ForgeIncrementalCache.storeScene(key: sceneKey1, segmentURL: seg1, spec: spec1, cacheRoot: cacheRoot)
        try await Task.sleep(nanoseconds: 50_000_000)
        let storedScene2 = try ForgeIncrementalCache.storeScene(key: sceneKey2, segmentURL: seg2, spec: spec2, cacheRoot: cacheRoot)

        // 2. Store one legacy .bin shot entry via ForgeShotCache in the same cache root.
        let shotSrc = root.appendingPathComponent("shot.raw")
        let shotBytes = Data(repeating: 0x5A, count: 4096)
        try shotBytes.write(to: shotSrc)
        let shotKey = try ForgeShotCache.computeKey(namespace: "shot-v1", inputURLs: [shotSrc])
        let shotCache = try ForgeShotCache(rootURL: cacheRoot)
        try await Task.sleep(nanoseconds: 50_000_000)
        let storedShot = try shotCache.store(key: shotKey, sourceURL: shotSrc, namespace: "shot-v1")

        // Also drop a ._ file to ensure stats/prune ignore it.
        try Data("appledouble".utf8).write(to: cacheRoot.appendingPathComponent("._ignored.mp4"))

        // stats --kind auto (default)
        let statsAuto = try runForge(["cache", "stats", "--root", cacheRoot.path])
        XCTAssertEqual(statsAuto.status, 0, statsAuto.stderr)
        let sAuto = try decodeJSONDict(statsAuto.stdout)
        XCTAssertEqual(sAuto["entryCount"] as? Int, 3)
        XCTAssertEqual(sAuto["shotEntryCount"] as? Int, 1)
        XCTAssertEqual(sAuto["sceneEntryCount"] as? Int, 2)
        XCTAssertEqual((sAuto["totalBytes"] as? NSNumber)?.int64Value, storedScene1.bytes + storedScene2.bytes + storedShot.bytes)

        // stats --kind scene vs --kind shot
        let statsScene = try decodeJSONDict(try runForge(["cache", "stats", "--root", cacheRoot.path, "--kind", "scene"]).stdout)
        XCTAssertEqual(statsScene["entryCount"] as? Int, 2)
        let statsShot = try decodeJSONDict(try runForge(["cache", "stats", "--root", cacheRoot.path, "--kind", "shot"]).stdout)
        XCTAssertEqual(statsShot["entryCount"] as? Int, 1)

        // lookup --kind auto hits scene AND materializes via clonefile
        let outScene = root.appendingPathComponent("mat_scene.mp4")
        let lookScene = try runForge(["cache", "lookup", "--key", sceneKey1, "--root", cacheRoot.path, "-o", outScene.path])
        XCTAssertEqual(lookScene.status, 0, lookScene.stderr)
        let lScene = try decodeJSONDict(lookScene.stdout)
        XCTAssertEqual(lScene["hit"] as? Bool, true)
        XCTAssertEqual(lScene["key"] as? String, sceneKey1)
        XCTAssertEqual(lScene["kind"] as? String, "scene")
        XCTAssertEqual(lScene["materializedPath"] as? String, outScene.path)
        XCTAssertEqual(lScene["sha256"] as? String, storedScene1.sha256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outScene.path))

        // lookup --kind shot misses scene key, --kind auto hits shot key
        let missShot = try decodeJSONDict(try runForge(["cache", "lookup", "--key", sceneKey1, "--root", cacheRoot.path, "--kind", "shot"]).stdout)
        XCTAssertEqual(missShot["hit"] as? Bool, false)

        let outShot = root.appendingPathComponent("mat_shot.bin")
        let lookShot = try runForge(["cache", "lookup", "--key", shotKey, "--root", cacheRoot.path, "-o", outShot.path])
        XCTAssertEqual(lookShot.status, 0, lookShot.stderr)
        let lShot = try decodeJSONDict(lookShot.stdout)
        XCTAssertEqual(lShot["hit"] as? Bool, true)
        XCTAssertEqual(lShot["kind"] as? String, "shot")
        XCTAssertEqual(try Data(contentsOf: outShot), shotBytes)

        // Wait briefly so lookup updated sceneKey1's lastAccessedUnix > sceneKey2's, then prune --kind auto
        let pruneMax = storedScene1.bytes + storedShot.bytes
        let pruneRes = try runForge(["cache", "prune", "--root", cacheRoot.path, "--max-bytes", "\(pruneMax)"])
        XCTAssertEqual(pruneRes.status, 0, pruneRes.stderr)
        let pJSON = try decodeJSONDict(pruneRes.stdout)
        XCTAssertEqual(pJSON["removedEntries"] as? Int, 1)
        XCTAssertEqual(pJSON["remainingEntries"] as? Int, 2)
        XCTAssertLessThanOrEqual((pJSON["remainingBytes"] as? NSNumber)?.int64Value ?? Int64.max, pruneMax)

        // Oldest untouched entry (sceneKey2) was pruned along with its .meta.json
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("\(sceneKey2).mp4").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("\(sceneKey2).meta.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("\(sceneKey1).mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheRoot.appendingPathComponent("\(shotKey).bin").path))
    }
}
