import AVFoundation
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
@testable import SafariumCore
@testable import SafariumForgeCore
@testable import SafariumPrism
import XCTest

final class Wave5InnovationTests: XCTestCase {
    private func makeShortAPFSDir(_ prefix: String) throws -> URL {
        let dir = URL(fileURLWithPath: "/tmp/\(prefix)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        chmod(dir.path, 0o700)
        return dir
    }

    private func writeWavSilence(to url: URL, durationSeconds: Double = 0.25, sampleRate: Int = 48_000) throws {
        let channels = 2
        let bits = 16
        let frames = max(1, Int((durationSeconds * Double(sampleRate)).rounded()))
        let dataBytes = frames * channels * (bits / 8)
        var d = Data()
        d.append(contentsOf: "RIFF".utf8)
        var riffSize = UInt32(36 + dataBytes).littleEndian
        d.append(Data(bytes: &riffSize, count: 4))
        d.append(contentsOf: "WAVEfmt ".utf8)
        var fmtLen = UInt32(16).littleEndian
        var audioFmt = UInt16(1).littleEndian
        var ch = UInt16(channels).littleEndian
        var sr = UInt32(sampleRate).littleEndian
        var byteRate = UInt32(sampleRate * channels * (bits / 8)).littleEndian
        var blockAlign = UInt16(channels * (bits / 8)).littleEndian
        var bps = UInt16(bits).littleEndian
        d.append(Data(bytes: &fmtLen, count: 4))
        d.append(Data(bytes: &audioFmt, count: 2))
        d.append(Data(bytes: &ch, count: 2))
        d.append(Data(bytes: &sr, count: 4))
        d.append(Data(bytes: &byteRate, count: 4))
        d.append(Data(bytes: &blockAlign, count: 2))
        d.append(Data(bytes: &bps, count: 2))
        d.append(contentsOf: "data".utf8)
        var dataLen = UInt32(dataBytes).littleEndian
        d.append(Data(bytes: &dataLen, count: 4))
        d.append(Data(count: dataBytes))
        try d.write(to: url)
    }

    private func waitForSocketReady(at path: String, timeoutSeconds: Double = 5.0) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            var st = stat()
            if lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFSOCK {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw SafariumError.timeout("socket did not appear at \(path)")
    }

    private func connectUDS(path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SafariumError.encode("client socket() failed: \(errno)")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw SafariumError.invalidState("client socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else {
            let err = errno
            Darwin.close(fd)
            throw SafariumError.encode("connect(\(path)) failed: \(String(cString: strerror(err)))")
        }
        return fd
    }

    private func sendUDS(fd: Int32, text: String, attachedFD: Int32? = nil) throws {
        var bytes = Array(text.utf8)
        if let attached = attachedFD {
            let dataOff = (MemoryLayout<cmsghdr>.stride + 3) & ~3
            let ctrlSpace = dataOff + MemoryLayout<Int32>.size
            try bytes.withUnsafeMutableBytes { buf in
                var iov = iovec(iov_base: buf.baseAddress, iov_len: buf.count)
                var ctrlBuf = [UInt8](repeating: 0, count: ctrlSpace)
                try withUnsafeMutablePointer(to: &iov) { iovPtr in
                    try ctrlBuf.withUnsafeMutableBytes { cRaw in
                        var msg = msghdr()
                        msg.msg_iov = iovPtr
                        msg.msg_iovlen = 1
                        msg.msg_control = cRaw.baseAddress
                        msg.msg_controllen = socklen_t(ctrlSpace)

                        // Write CMSG header manually for macOS Darwin alignment.
                        let hdrPtr = cRaw.baseAddress!.assumingMemoryBound(to: cmsghdr.self)
                        hdrPtr.pointee.cmsg_len = socklen_t(ctrlSpace)
                        hdrPtr.pointee.cmsg_level = SOL_SOCKET
                        hdrPtr.pointee.cmsg_type = SCM_RIGHTS
                        var fdVal = attached
                        memcpy(cRaw.baseAddress!.advanced(by: dataOff), &fdVal, MemoryLayout<Int32>.size)

                        let sent = sendmsg(fd, &msg, 0)
                        guard sent == buf.count else {
                            let err = errno
                            throw SafariumError.encode("sendmsg failed: \(String(cString: strerror(err)))")
                        }
                    }
                }
            }
            return
        }
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: off), bytes.count - off)
            }
            guard n > 0 else {
                let err = errno
                throw SafariumError.encode("write() failed: \(String(cString: strerror(err)))")
            }
            off += n
        }
    }

    private func readJSONLine(fd: Int32) throws -> [String: Any] {
        var acc = Data()
        var ch: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &ch, 1)
            if n < 0 {
                if errno == EINTR { continue }
                throw SafariumError.encode("read() failed: \(errno)")
            }
            if n == 0 {
                throw SafariumError.encode("unexpected EOF reading UDS JSON line")
            }
            if ch == UInt8(ascii: "\n") {
                if acc.isEmpty { continue }
                let obj = try JSONSerialization.jsonObject(with: acc) as? [String: Any]
                guard let obj else {
                    throw SafariumError.encode("non-dict JSON line from server")
                }
                return obj
            }
            acc.append(ch)
        }
    }

    private func samplePixelRGBA(cgImage: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var rgba = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: &rgba,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(cgImage, in: CGRect(x: -x, y: -(cgImage.height - 1 - y), width: cgImage.width, height: cgImage.height))
        return (rgba[0], rgba[1], rgba[2], rgba[3])
    }

    private func buildSolidVideo(at url: URL, width: Int = 64, height: Int = 64, fps: Int = 30, frames: Int = 6, colorBGRA: (UInt8, UInt8, UInt8, UInt8)) async throws {
        let cfg = ForgePipeEncodeConfig(
            width: width,
            height: height,
            fps: fps,
            inputPixelFormat: .bgra,
            primaryCodec: .h264,
            primaryBitrate: 2_000_000,
            overwrite: true
        )
        let session = try ForgeDualTeeSession(primaryOutputURL: url, config: cfg)
        var row = [UInt8](repeating: 0, count: width * height * 4)
        for px in 0..<(width * height) {
            row[px * 4] = colorBGRA.0
            row[px * 4 + 1] = colorBGRA.1
            row[px * 4 + 2] = colorBGRA.2
            row[px * 4 + 3] = colorBGRA.3
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<frames {
            try await session.appendBGRAFrame(row)
        }
        _ = try await session.finishAndCommit(startedUptimeNs: t0)
    }

    // 1. Shared-memory ring encoder (SCM_RIGHTS + file-backed + vflip + dual-tee + audio + guardrails)
    func testSharedRingEncodeSCMRightsAndFileBackedWithVFlipAndDualTee() async throws {
        let dir = try makeShortAPFSDir("sfr")
        defer { try? FileManager.default.removeItem(at: dir) }

        let w = 64
        let h = 64
        let slots = 4
        let slotBytes = w * h * 3
        let totalBytes = slots * slotBytes

        let wavURL = dir.appendingPathComponent("silence.wav")
        try writeWavSilence(to: wavURL, durationSeconds: 0.2)

        // Create unlinked mmap ring (top half RED, bottom half BLUE in rgb24; vflip=true should put BLUE on top).
        let shmUnlinkedURL = dir.appendingPathComponent("unlinked.ring")
        let ringFD = Darwin.open(shmUnlinkedURL.path, O_RDWR | O_CREAT | O_EXCL, 0o600)
        XCTAssertGreaterThanOrEqual(ringFD, 0)
        _ = unlink(shmUnlinkedURL.path)
        XCTAssertEqual(ftruncate(ringFD, off_t(totalBytes)), 0)
        let mapped = mmap(nil, totalBytes, PROT_READ | PROT_WRITE, MAP_SHARED, ringFD, 0)
        XCTAssertNotEqual(mapped, MAP_FAILED)
        defer {
            munmap(mapped, totalBytes)
            Darwin.close(ringFD)
        }

        let basePtr = mapped!.assumingMemoryBound(to: UInt8.self)
        for s in 0..<slots {
            let slotPtr = basePtr.advanced(by: s * slotBytes)
            for y in 0..<h {
                let isTopHalf = y < (h / 2)
                let r: UInt8 = isTopHalf ? 240 : 10
                let g: UInt8 = 10
                let b: UInt8 = isTopHalf ? 10 : 240
                for x in 0..<w {
                    let off = (y * w + x) * 3
                    slotPtr[off] = r
                    slotPtr[off + 1] = g
                    slotPtr[off + 2] = b
                }
            }
        }

        let sockPath = dir.appendingPathComponent("ring.sock").path
        let outMP4 = dir.appendingPathComponent("pri.mp4")
        let outMOV = dir.appendingPathComponent("sec.mov")
        let serverTask = Task {
            try await ForgeSharedRingServer.serve(socketPath: sockPath, idleTimeoutSeconds: 15.0)
        }

        try await waitForSocketReady(at: sockPath)
        let clientFD = try connectUDS(path: sockPath)
        defer { Darwin.close(clientFD) }

        let spec: [String: Any] = [
            "width": w,
            "height": h,
            "fps": 30,
            "slots": slots,
            "pixFmt": "rgb24",
            "vflip": true,
            "codec": "h264",
            "outputPath": outMP4.path,
            "secondaryPath": outMOV.path,
            "secondaryCodec": "prores4444",
            "audioPath": wavURL.path,
            "overwrite": true,
        ]
        let specJSON = String(decoding: try JSONSerialization.data(withJSONObject: spec), as: UTF8.self)
        try sendUDS(fd: clientFD, text: "RING_START \(specJSON)\n", attachedFD: ringFD)
        let startAck = try readJSONLine(fd: clientFD)
        XCTAssertEqual(startAck["ok"] as? Bool, true)
        XCTAssertEqual(startAck["transport"] as? String, "scm_rights_mmap")

        for f in 0..<6 {
            let slot = f % slots
            try sendUDS(fd: clientFD, text: "S \(slot) \(f)\n")
            let fAck = try readJSONLine(fd: clientFD)
            XCTAssertEqual(fAck["ok"] as? Bool, true)
        }
        try sendUDS(fd: clientFD, text: "RING_FINISH\n")
        let finAck = try readJSONLine(fd: clientFD)
        XCTAssertEqual(finAck["ok"] as? Bool, true)

        let report = try await serverTask.value
        XCTAssertEqual(report.transport, "scm_rights_mmap")
        XCTAssertTrue(report.vflip)
        XCTAssertEqual(report.pipeReport.frames, 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outMOV.path))

        // Verify vflip orientation: top of output frame must be BLUE, bottom must be RED.
        let asset = AVURLAsset(url: outMP4)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        let cg = try gen.copyCGImage(at: CMTime(value: 1, timescale: 30), actualTime: nil)
        let topPx = samplePixelRGBA(cgImage: cg, x: 32, y: 12)
        let botPx = samplePixelRGBA(cgImage: cg, x: 32, y: 52)
        XCTAssertGreaterThan(Int(topPx.b), Int(topPx.r) + 120, "vflip should place bottom blue pixels at top: \(topPx)")
        XCTAssertGreaterThan(Int(botPx.r), Int(botPx.b) + 120, "vflip should place top red pixels at bottom: \(botPx)")

        let probe = try await PacketProbe.inspect(url: outMP4, includeAudioPackets: false)
        XCTAssertGreaterThanOrEqual(probe.tracks.count, 2, "primary MP4 should include video + muxed audio")

        // Guardrail test: world-readable 0644 shm file must be rejected; 0600 must succeed.
        let badShmURL = dir.appendingPathComponent("bad.bin")
        FileManager.default.createFile(atPath: badShmURL.path, contents: Data(count: 2 * 32 * 32 * 4))
        chmod(badShmURL.path, 0o644)
        let badSpec = ForgeRingStartSpec(
            width: 32, height: 32, fps: 30, slots: 2, pixFmt: "bgra",
            vflip: false, codec: "h264", bitrate: nil, quality: nil,
            outputPath: dir.appendingPathComponent("bad.mp4").path,
            secondaryPath: nil, secondaryCodec: nil, secondaryBitrate: nil, secondaryQuality: nil,
            secondaryBg: nil, audioPath: nil, subtitlesPath: nil, subtitleLang: nil,
            closedGOP: true, shmPath: badShmURL.path, overwrite: true
        )
        XCTAssertThrowsError(try ForgeSharedRingSession(spec: badSpec, attachedFD: nil))

        chmod(badShmURL.path, 0o600)
        let goodFileSession = try ForgeSharedRingSession(spec: badSpec, attachedFD: nil)
        XCTAssertEqual(goodFileSession.transportMode, "file_backed_mmap")
        try await goodFileSession.appendSlot(0, frameIndex: 0)
        let fileRep = try await goodFileSession.finish()
        XCTAssertEqual(fileRep.pipeReport.frames, 1)
    }

    // 2. APFS Shot Cache (CoW clonefile + ._ AppleDouble ignore + stats + prune)
    func testShotCacheAPFSClonefileAndPrune() throws {
        let dir = try makeShortAPFSDir("sfc")
        defer { try? FileManager.default.removeItem(at: dir) }

        let cacheRoot = dir.appendingPathComponent("cache", isDirectory: true)
        let cache = try ForgeShotCache(rootURL: cacheRoot)

        // Inject synthetic AppleDouble ._ file inside cache root to verify it is ignored cleanly.
        try Data("appledouble-junk".utf8).write(to: cacheRoot.appendingPathComponent("._deadbeef.bin"))

        let srcA = dir.appendingPathComponent("shotA.mp4")
        let payloadA = Data((0..<(256 * 1024)).map { UInt8($0 & 0xFF) })
        try payloadA.write(to: srcA)

        let srcB = dir.appendingPathComponent("shotB.mp4")
        let payloadB = Data((0..<(256 * 1024)).map { UInt8(($0 * 7) & 0xFF) })
        try payloadB.write(to: srcB)

        let keyA = try ForgeShotCache.computeKey(namespace: "shot", paramsJSON: "{\"id\":1}", inputURLs: [srcA])
        let keyB = try ForgeShotCache.computeKey(namespace: "shot", paramsJSON: "{\"id\":2}", inputURLs: [srcB])
        XCTAssertNotEqual(keyA, keyB)

        let stA = try cache.store(key: keyA, sourceURL: srcA, namespace: "shot")
        XCTAssertTrue(stA.usedClonefile, "APFS /tmp cache store should use clonefile")
        Thread.sleep(forTimeInterval: 0.02)
        let stB = try cache.store(key: keyB, sourceURL: srcB, namespace: "shot")
        XCTAssertTrue(stB.usedClonefile)

        let destA = dir.appendingPathComponent("restoredA.mp4")
        let hitA = try cache.lookup(key: keyA, destinationURL: destA, overwrite: true)
        XCTAssertTrue(hitA.hit)
        XCTAssertTrue(hitA.usedClonefile)
        XCTAssertEqual(try Data(contentsOf: destA), payloadA)

        let miss = try cache.lookup(key: String(repeating: "0", count: 64), destinationURL: nil)
        XCTAssertFalse(miss.hit)

        let statsBefore = try cache.stats()
        XCTAssertEqual(statsBefore.entryCount, 2, "must ignore ._deadbeef.bin")

        // Touch B so B is newest (or look up B) and prune down to fit 1 item (~262 KB).
        _ = try cache.lookup(key: keyB, destinationURL: nil)
        let prune = try cache.prune(maxBytes: 300_000)
        XCTAssertEqual(prune.removedEntries, 1)
        XCTAssertEqual(prune.remainingEntries, 1)
        XCTAssertTrue(try cache.lookup(key: keyB, destinationURL: nil).hit)
    }

    // 3. Slot-Scoped Warm Daemon (ping/capabilities/inspect/pq/cache_stats + idle auto-reap)
    func testWarmDaemonDispatchAndIdleAutoReap() async throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let dir = try makeShortAPFSDir("sfw")
        defer { try? FileManager.default.removeItem(at: dir) }

        let refMP4 = dir.appendingPathComponent("ref.mp4")
        let candMP4 = dir.appendingPathComponent("cand.mp4")
        try await buildSolidVideo(at: refMP4, colorBGRA: (40, 180, 90, 255))
        try await buildSolidVideo(at: candMP4, colorBGRA: (40, 180, 90, 255))

        let sockPath = dir.appendingPathComponent("warm.sock").path
        let cacheRoot = dir.appendingPathComponent("cache", isDirectory: true)
        let daemonTask = Task { @MainActor in
            try await ForgeWarmDaemon.serve(
                socketPath: sockPath,
                idleTimeoutSeconds: 1.5,
                cacheRootURL: cacheRoot,
                preloadPQEngine: true
            )
        }

        try await waitForSocketReady(at: sockPath)
        do {
            let clientFD = try connectUDS(path: sockPath)
            defer { Darwin.close(clientFD) }

            try sendUDS(fd: clientFD, text: "{\"cmd\":\"ping\"}\n")
            let ping = try readJSONLine(fd: clientFD)
            XCTAssertEqual(ping["ok"] as? Bool, true)
            XCTAssertEqual(ping["pqWarm"] as? Bool, true)

            try sendUDS(fd: clientFD, text: "{\"cmd\":\"capabilities\"}\n")
            let caps = try readJSONLine(fd: clientFD)
            XCTAssertEqual(caps["ok"] as? Bool, true)

            try sendUDS(fd: clientFD, text: "{\"cmd\":\"cache_stats\"}\n")
            let cs = try readJSONLine(fd: clientFD)
            XCTAssertEqual(cs["ok"] as? Bool, true)

            let inspectReq = String(decoding: try JSONSerialization.data(withJSONObject: ["cmd": "inspect", "path": refMP4.path]), as: UTF8.self)
            try sendUDS(fd: clientFD, text: inspectReq + "\n")
            let insp = try readJSONLine(fd: clientFD)
            XCTAssertEqual(insp["ok"] as? Bool, true)

            let pqReq = String(decoding: try JSONSerialization.data(withJSONObject: [
                "cmd": "pq", "refPath": refMP4.path, "candPath": candMP4.path, "samples": 4,
            ]), as: UTF8.self)
            try sendUDS(fd: clientFD, text: pqReq + "\n")
            let pqResp = try readJSONLine(fd: clientFD)
            XCTAssertEqual(pqResp["ok"] as? Bool, true)
            let pqResult = pqResp["result"] as? [String: Any]
            XCTAssertGreaterThanOrEqual((pqResult?["score0To100"] as? Double) ?? 0.0, 95.0)
            XCTAssertEqual(pqResult?["passed"] as? Bool, true)
        }

        // After client closes, daemon should auto-exit after idleTimeoutSeconds (1.5s) cleanly.
        let report = try await daemonTask.value
        XCTAssertEqual(report.exitReason, "idle_timeout")
        XCTAssertEqual(report.requestsHandled, 5)
        XCTAssertTrue(report.pqCompiledWarm)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sockPath))
    }

    // 4. Offline Safari A/B Visual Diff Gallery + XSS-safe escaping + PQ metrics
    func testABGalleryGeneratesEscapedOfflineHTMLAndSummary() async throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let dir = try makeShortAPFSDir("sfab")
        defer { try? FileManager.default.removeItem(at: dir) }

        let baseMP4 = dir.appendingPathComponent("base.mp4")
        let candMP4 = dir.appendingPathComponent("cand.mp4")
        try await buildSolidVideo(at: baseMP4, colorBGRA: (200, 120, 40, 255))
        try await buildSolidVideo(at: candMP4, colorBGRA: (200, 120, 40, 255))

        let manifest = ForgeABGalleryManifest(
            title: "Wave5 </script><script>alert(1)</script>",
            generatedNote: "Safe <b>Note</b>",
            cases: [
                ForgeABGalleryCase(
                    id: "case-one",
                    project: "TestProj",
                    title: "Adversarial </script><img onerror=alert(9)>",
                    category: "web",
                    baselineVideoPath: baseMP4.path,
                    candidateVideoPath: candMP4.path,
                    expectedThaiText: nil,
                    samples: 2,
                    minScore: 90.0,
                    minMSSSIM: 0.98,
                    maxDeltaE00P95: 2.0,
                    baselineMetrics: ForgeABMetricSet(wallMs: 2000, peakFootprintMB: 400, chromeTabs: 4, ffmpegCalls: 2),
                    candidateMetrics: ForgeABMetricSet(wallMs: 500, peakFootprintMB: 100, chromeTabs: 0, ffmpegCalls: 0),
                    notes: "</script>escaped"
                ),
            ]
        )

        let htmlOut = dir.appendingPathComponent("gallery/gallery.html")
        let report = try await ForgeABGallery.generate(manifest: manifest, outputHTMLURL: htmlOut, overwrite: true)
        XCTAssertEqual(report.caseCount, 1)
        XCTAssertEqual(report.passedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: htmlOut.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.summaryJSONPath))

        let htmlStr = try String(contentsOf: htmlOut, encoding: .utf8)
        XCTAssertFalse(htmlStr.contains("<script>alert(1)</script>"))
        XCTAssertFalse(htmlStr.contains("<img onerror=alert(9)>"))
        XCTAssertTrue(htmlStr.contains("4.00x") || htmlStr.contains("case-one"))
    }

    // 5. Loopback HTTP allowed for 127.0.0.1 ES modules while external URLs stay blocked
    @MainActor
    func testPrismWebKit3DLoopbackHTTPAllowedAndExternalBlocked() async throws {
        // Reject external https even with allowLoopbackHTTP = true, and reject loopback when allowLoopbackHTTP = false.
        let dummyOut = URL(fileURLWithPath: "/tmp/nonexistent-out-\(UUID().uuidString).mp4")
        do {
            _ = try await PrismHybridEngine.renderWeb3D(
                htmlURL: URL(string: "http://127.0.0.1:9999/index.html")!,
                outputURL: dummyOut,
                allowLoopbackHTTP: false,
                overwrite: true
            )
            XCTFail("loopback HTTP should be rejected when allowLoopbackHTTP is false")
        } catch {
            XCTAssertTrue("\(error)".contains("allowLoopbackHTTP"))
        }

        do {
            _ = try await PrismHybridEngine.renderWeb3D(
                htmlURL: URL(string: "https://example.com/index.html")!,
                outputURL: dummyOut,
                allowLoopbackHTTP: true,
                overwrite: true
            )
            XCTFail("external https must stay blocked even when allowLoopbackHTTP is true")
        } catch {
            XCTAssertTrue("\(error)".contains("loopback"))
        }

        // Start minimal POSIX TCP loopback server serving HTML + ES module on 127.0.0.1:<ephemeral>
        let srvFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(srvFD, 0)
        var yes: Int32 = 1
        setsockopt(srvFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var sin = sockaddr_in()
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_addr.s_addr = inet_addr("127.0.0.1")
        sin.sin_port = 0
        let bindOK = withUnsafePointer(to: &sin) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(srvFD, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindOK, 0)
        XCTAssertEqual(Darwin.listen(srvFD, 8), 0)

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(srvFD, sa, &addrLen)
            }
        }
        let port = Int(UInt16(bigEndian: boundAddr.sin_port))
        defer { Darwin.close(srvFD) }

        let serverQueue = DispatchQueue(label: "test-loopback-http")
        let htmlBody = """
        <!doctype html><html><body style="margin:0;width:128px;height:128px;background:#101010;">
        <div id="box" style="width:128px;height:128px;background:#aa0000;"></div>
        <script type="module" src="/mod.mjs"></script>
        </body></html>
        """
        let jsBody = """
        document.getElementById('box').style.background = 'rgb(0, 210, 80)';
        window.__PRISM_READY = true;
        """
        serverQueue.async {
            for _ in 0..<8 {
                let cfd = Darwin.accept(srvFD, nil, nil)
                if cfd < 0 { break }
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = Darwin.read(cfd, &buf, buf.count)
                let req = n > 0 ? String(decoding: buf.prefix(n), as: UTF8.self) : ""
                let isMod = req.contains("GET /mod.mjs")
                let body = isMod ? jsBody : htmlBody
                let ct = isMod ? "application/javascript; charset=utf-8" : "text/html; charset=utf-8"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: \(ct)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                _ = resp.withCString { ptr in Darwin.write(cfd, ptr, strlen(ptr)) }
                Darwin.close(cfd)
            }
        }

        HostApp.prepare()
        let runner = try await PrismWebKit3D(width: 128, height: 128, transparent: false, allowLoopbackHTTP: true)
        try await runner.loadURL(URL(string: "http://127.0.0.1:\(port)/index.html")!, waitReadyTimeout: 5.0)
        let snap = try await runner.snapshot()
        let px = samplePixelRGBA(cgImage: snap.cgImage, x: 64, y: 64)
        XCTAssertGreaterThan(Int(px.g), Int(px.r) + 100, "loopback ES module should paint green box: \(px)")
    }
}
