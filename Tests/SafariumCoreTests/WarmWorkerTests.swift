import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import SafariumCore
import XCTest

@MainActor
final class WarmWorkerTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare() }

    private nonisolated static func shortTempDir() throws -> URL {
        let shortID = String(UUID().uuidString.prefix(8))
        let dir = URL(fileURLWithPath: "/tmp/sf-ww-\(shortID)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated static func connectUDS(path: String, timeoutSeconds: Double = 10.0) throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { throw SafariumError.encode("client socket() failed: \(errno)") }
                var addr = sockaddr_un()
                addr.sun_family = sa_family_t(AF_UNIX)
                let bytes = Array(path.utf8CString)
                guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
                    Darwin.close(fd)
                    throw SafariumError.encode("socket path too long")
                }
                withUnsafeMutableBytes(of: &addr.sun_path) { dst in
                    bytes.withUnsafeBytes { src in dst.copyBytes(from: src) }
                }
                let rc = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                if rc == 0 { return fd }
                Darwin.close(fd)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw SafariumError.encode("timed out connecting to UDS \(path)")
    }

    private nonisolated static func sendLine(_ fd: Int32, _ line: String, attachedFD: Int32? = nil) throws {
        var payload = Array((line + "\n").utf8)
        if let attachedFD {
            try payload.withUnsafeMutableBytes { buf in
                var iov = iovec(iov_base: buf.baseAddress, iov_len: buf.count)
                let cmsgSpace = MemoryLayout<cmsghdr>.stride + MemoryLayout<Int32>.stride
                let ctrl = UnsafeMutableRawPointer.allocate(byteCount: cmsgSpace, alignment: MemoryLayout<cmsghdr>.alignment)
                defer { ctrl.deallocate() }
                ctrl.initializeMemory(as: UInt8.self, repeating: 0, count: cmsgSpace)

                let hdr = ctrl.assumingMemoryBound(to: cmsghdr.self)
                hdr.pointee.cmsg_len = socklen_t(MemoryLayout<cmsghdr>.stride + MemoryLayout<Int32>.stride)
                hdr.pointee.cmsg_level = SOL_SOCKET
                hdr.pointee.cmsg_type = SCM_RIGHTS
                ctrl.advanced(by: MemoryLayout<cmsghdr>.stride).storeBytes(of: attachedFD, as: Int32.self)

                var msg = msghdr()
                msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
                msg.msg_iovlen = 1
                msg.msg_control = ctrl
                msg.msg_controllen = socklen_t(cmsgSpace)
                let sent = sendmsg(fd, &msg, 0)
                guard sent == buf.count else {
                    throw SafariumError.encode("sendmsg(SCM_RIGHTS) failed errno=\(errno)")
                }
            }
        } else {
            var written = 0
            try payload.withUnsafeBytes { raw in
                while written < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: written), raw.count - written)
                    guard n > 0 else {
                        throw SafariumError.encode("write() failed errno=\(errno)")
                    }
                    written += n
                }
            }
        }
    }

    private nonisolated static func readJSONLine(_ fd: Int32) throws -> [String: Any] {
        var data = Data()
        var ch: UInt8 = 0
        while true {
            let n = Darwin.read(fd, &ch, 1)
            guard n == 1 else {
                throw SafariumError.encode("unexpected EOF reading UDS response")
            }
            if ch == 0x0A { break }
            data.append(ch)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SafariumError.encode("invalid JSON response from WarmWorker")
        }
        return obj
    }

    func testWarmWorkerEnforcesPermissionsRenderPNGAndSCMRightsMmapRing() async throws {
        let dir = try Self.shortTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let udsDir = dir.appendingPathComponent("uds", isDirectory: true)
        let sockURL = udsDir.appendingPathComponent("w.sock")
        // Plant stale file to verify serve() unlinks stale sockets cleanly.
        try FileManager.default.createDirectory(at: udsDir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: sockURL.path, contents: Data())

        let htmlURL = dir.appendingPathComponent("card.html")
        try """
        <!doctype html><html><head><meta charset="utf-8"><style>
        body{margin:0;width:160px;height:120px;background:#102a43;color:#f8fafc;
        display:flex;align-items:center;justify-content:center;font-family:sans-serif;font-size:20px;}
        </style></head><body>สวัสดีปิ๊ก</body></html>
        """.write(to: htmlURL, atomically: true, encoding: .utf8)

        let pngURL = dir.appendingPathComponent("card.png")
        let mp4URL = dir.appendingPathComponent("ring.mp4")

        let serverTask = Task {
            try await WarmWorkerServer.serve(socketPath: sockURL.path)
        }

        // Run POSIX client on background queue so server Task on MainActor stays unblocked.
        try await Task.detached(priority: .userInitiated) {
            let fd = try Self.connectUDS(path: sockURL.path)
            defer { Darwin.close(fd) }

            var dirSt = stat()
            XCTAssertEqual(stat(udsDir.path, &dirSt), 0)
            XCTAssertEqual(dirSt.st_mode & 0o777, 0o700, "UDS directory must be locked down to 0700")

            var sockSt = stat()
            XCTAssertEqual(lstat(sockURL.path, &sockSt), 0)
            XCTAssertEqual(sockSt.st_mode & 0o777, 0o600, "UDS socket must be owner-only 0600")

            try Self.sendLine(fd, #"{"cmd":"ping"}"#)
            let pong = try Self.readJSONLine(fd)
            XCTAssertEqual(pong["ok"] as? Bool, true)

            let renderReq = try JSONSerialization.data(withJSONObject: [
                "cmd": "render_png",
                "html": htmlURL.path,
                "out_png": pngURL.path,
                "width": 160,
                "height": 120,
            ])
            try Self.sendLine(fd, String(decoding: renderReq, as: UTF8.self))
            let renderResp = try Self.readJSONLine(fd)
            XCTAssertEqual(renderResp["ok"] as? Bool, true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: pngURL.path))

            // 3-slot unlinked mmap ring over SCM_RIGHTS
            let w = 160, h = 120, slots = 3, frames = 6
            let slotBytes = w * h * 4
            let ringBytes = slotBytes * slots
            let ringPath = udsDir.appendingPathComponent("anon_ring.bin").path
            let ringFD = open(ringPath, O_CREAT | O_RDWR | O_TRUNC, 0o600)
            XCTAssertGreaterThanOrEqual(ringFD, 0)
            XCTAssertEqual(ftruncate(ringFD, off_t(ringBytes)), 0)
            XCTAssertEqual(unlink(ringPath), 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: ringPath))

            let mapped = mmap(nil, ringBytes, PROT_READ | PROT_WRITE, MAP_SHARED, ringFD, 0)!
            XCTAssertNotEqual(mapped, MAP_FAILED)
            defer { _ = munmap(mapped, ringBytes) }

            let startReq = try JSONSerialization.data(withJSONObject: [
                "cmd": "encode_ring_start",
                "out_mp4": mp4URL.path,
                "width": w,
                "height": h,
                "fps": 30,
                "slot_bytes": slotBytes,
                "slots": slots,
            ])
            try Self.sendLine(fd, String(decoding: startReq, as: UTF8.self), attachedFD: ringFD)
            Darwin.close(ringFD)
            let startResp = try Self.readJSONLine(fd)
            XCTAssertEqual(startResp["ok"] as? Bool, true)

            for i in 0..<frames {
                let s = i % slots
                let slotPtr = mapped.advanced(by: s * slotBytes).assumingMemoryBound(to: UInt8.self)
                // Write distinct solid BGRA pattern per frame
                for p in stride(from: 0, to: slotBytes, by: 4) {
                    slotPtr[p] = UInt8((20 + i * 30) & 0xFF)
                    slotPtr[p + 1] = 140
                    slotPtr[p + 2] = UInt8((220 - i * 20) & 0xFF)
                    slotPtr[p + 3] = 255
                }
                try Self.sendLine(fd, "S \(s) \(i)")
                let ack = try Self.readJSONLine(fd)
                XCTAssertEqual(ack["ok"] as? Bool, true)
                XCTAssertEqual(ack["slot"] as? Int, s)
            }

            try Self.sendLine(fd, #"{"cmd":"encode_ring_finish"}"#)
            let finResp = try Self.readJSONLine(fd)
            XCTAssertEqual(finResp["ok"] as? Bool, true)
            XCTAssertEqual(finResp["frames"] as? Int, frames)

            // Truncated FD must be rejected by fstat before mmap (no SIGBUS).
            let badPath = udsDir.appendingPathComponent("bad_ring.bin").path
            let badFD = open(badPath, O_CREAT | O_RDWR | O_TRUNC, 0o600)
            XCTAssertGreaterThanOrEqual(badFD, 0)
            XCTAssertEqual(ftruncate(badFD, 128), 0)
            _ = unlink(badPath)
            let badReq = try JSONSerialization.data(withJSONObject: [
                "cmd": "encode_ring_start",
                "out_mp4": dir.appendingPathComponent("should_not_exist.mp4").path,
                "width": w,
                "height": h,
                "fps": 30,
                "slot_bytes": slotBytes,
                "slots": slots,
            ])
            try Self.sendLine(fd, String(decoding: badReq, as: UTF8.self), attachedFD: badFD)
            Darwin.close(badFD)
            let badResp = try Self.readJSONLine(fd)
            XCTAssertEqual(badResp["ok"] as? Bool, false)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("should_not_exist.mp4").path))

            try Self.sendLine(fd, #"{"cmd":"quit"}"#)
            let quitResp = try Self.readJSONLine(fd)
            XCTAssertEqual(quitResp["ok"] as? Bool, true)
        }.value

        try await serverTask.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: sockURL.path), "socket must be unlinked on exit")

        let probe = try await PacketProbe.inspect(url: mp4URL)
        XCTAssertEqual(probe.tracks.first?.packetCount, 6)

        // Decode ring.mp4 back to BGRA and verify frame 0 & frame 3 center pixels match written slots.
        let asset = AVURLAsset(url: mp4URL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let vTrack = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        out.alwaysCopiesSampleData = false
        reader.add(out)
        XCTAssertTrue(reader.startReading())

        var decodedCenterBGR: [(Int, Int, Int)] = []
        while let sb = autoreleasepool(invoking: { out.copyNextSampleBuffer() }) {
            guard sb.numSamples > 0, let pb = sb.imageBuffer else { continue }
            XCTAssertEqual(CVPixelBufferLockBaseAddress(pb, .readOnly), kCVReturnSuccess)
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let strideBytes = CVPixelBufferGetBytesPerRow(pb)
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                let cy = CVPixelBufferGetHeight(pb) / 2
                let cx = CVPixelBufferGetWidth(pb) / 2
                let off = cy * strideBytes + cx * 4
                decodedCenterBGR.append((Int(ptr[off]), Int(ptr[off + 1]), Int(ptr[off + 2])))
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        }
        XCTAssertEqual(decodedCenterBGR.count, 6)
        // Frame 0 expected (20, 140, 220), Frame 3 expected (110, 140, 160)
        XCTAssertLessThanOrEqual(abs(decodedCenterBGR[0].0 - 20), 12)
        XCTAssertLessThanOrEqual(abs(decodedCenterBGR[0].1 - 140), 12)
        XCTAssertLessThanOrEqual(abs(decodedCenterBGR[0].2 - 220), 12)
        XCTAssertLessThanOrEqual(abs(decodedCenterBGR[3].0 - 110), 12)
        XCTAssertLessThanOrEqual(abs(decodedCenterBGR[3].1 - 140), 12)
        XCTAssertLessThanOrEqual(abs(decodedCenterBGR[3].2 - 160), 12)
    }
}
