import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

public final class SafariumSocketLineReader: @unchecked Sendable {
    private let fd: Int32
    private let maxLineBytes = 65_536
    private var pending = Data()
    private var pendingFDs: [(fd: Int32, byteOffset: Int)] = []
    private let ioQueue = DispatchQueue(label: "safarium.warmworker.uds.read")

    public init(fd: Int32) {
        self.fd = fd
    }

    private func closeAllPendingFDs() {
        for entry in pendingFDs where entry.fd >= 0 {
            Darwin.close(entry.fd)
        }
        pendingFDs.removeAll()
    }

    deinit {
        closeAllPendingFDs()
    }

    public func nextCommand() async -> (line: String?, fd: Int32?) {
        await withCheckedContinuation { cont in
            ioQueue.async { [self] in
                cont.resume(returning: readBlocking())
            }
        }
    }

    private func readBlocking() -> (line: String?, fd: Int32?) {
        while true {
            if let nl = pending.firstIndex(of: 0x0A) {
                guard nl <= maxLineBytes else {
                    closeAllPendingFDs()
                    return (nil, nil)
                }
                let s = String(decoding: pending[..<nl], as: UTF8.self)
                let consumed = nl + 1
                pending.removeSubrange(...nl)
                var attachedFD: Int32?
                while !pendingFDs.isEmpty && pendingFDs[0].byteOffset <= nl {
                    let entry = pendingFDs.removeFirst()
                    if attachedFD == nil {
                        attachedFD = entry.fd
                    } else if entry.fd >= 0 {
                        Darwin.close(entry.fd)
                    }
                }
                for i in pendingFDs.indices {
                    pendingFDs[i].byteOffset = max(0, pendingFDs[i].byteOffset - consumed)
                }
                return (s, attachedFD)
            }

            var buf = [UInt8](repeating: 0, count: 4096)
            var cbuf = [UInt8](repeating: 0, count: 256)
            var n: ssize_t = 0
            var gotFD: Int32?
            buf.withUnsafeMutableBytes { bRaw in
                cbuf.withUnsafeMutableBytes { cRaw in
                    var iov = iovec(iov_base: bRaw.baseAddress, iov_len: bRaw.count)
                    var msg = msghdr()
                    msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
                    msg.msg_iovlen = 1
                    msg.msg_control = cRaw.baseAddress
                    msg.msg_controllen = socklen_t(cRaw.count)
                    n = recvmsg(fd, &msg, 0)
                    if n > 0 && msg.msg_controllen >= socklen_t(MemoryLayout<cmsghdr>.stride) {
                        var offset = 0
                        while offset + MemoryLayout<cmsghdr>.stride <= Int(msg.msg_controllen) {
                            let cPtr = cRaw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: cmsghdr.self)
                            let clen = Int(cPtr.pointee.cmsg_len)
                            guard clen >= MemoryLayout<cmsghdr>.stride else { break }
                            if cPtr.pointee.cmsg_level == SOL_SOCKET && cPtr.pointee.cmsg_type == SCM_RIGHTS {
                                let payloadOffset = offset + MemoryLayout<cmsghdr>.stride
                                let cmsgEnd = min(offset + clen, Int(msg.msg_controllen))
                                let fdCount = max(0, (cmsgEnd - payloadOffset) / MemoryLayout<Int32>.stride)
                                for i in 0..<fdCount {
                                    let fdVal = cRaw.baseAddress!.advanced(by: payloadOffset + i * MemoryLayout<Int32>.stride).load(as: Int32.self)
                                    guard fdVal >= 0 else { continue }
                                    _ = fcntl(fdVal, F_SETFD, FD_CLOEXEC)
                                    if gotFD == nil {
                                        gotFD = fdVal
                                    } else {
                                        Darwin.close(fdVal)
                                    }
                                }
                            }
                            let step = (clen + MemoryLayout<Int32>.stride - 1) & ~(MemoryLayout<Int32>.stride - 1)
                            offset += max(MemoryLayout<cmsghdr>.stride, step)
                        }
                    }
                }
            }
            if n <= 0 {
                if let fdVal = gotFD, fdVal >= 0 { Darwin.close(fdVal) }
                if n < 0 && errno == EINTR { continue }
                closeAllPendingFDs()
                return (nil, nil)
            }
            let chunkStart = pending.count
            pending.append(contentsOf: buf[0..<Int(n)])
            if let fdVal = gotFD {
                pendingFDs.append((fd: fdVal, byteOffset: chunkStart))
            }
            if pending.firstIndex(of: 0x0A) == nil && pending.count > maxLineBytes {
                closeAllPendingFDs()
                return (nil, nil)
            }
        }
    }
}

private typealias SocketLineReader = SafariumSocketLineReader

/// Persistent warm WebKit worker communicating over `0700`/`0600` UNIX domain sockets and
/// zero-copy unlinked `SCM_RIGHTS` `mmap` rings for low-RAM multi-card/video batch rendering.
public enum WarmWorkerServer {
    private static let acceptQueue = DispatchQueue(label: "safarium.warmworker.accept")

    public static func sendRawBytes(fd: Int32, data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    break
                }
                sent += n
            }
        }
    }

    public static func sendJSONLine(fd: Int32, obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var out = data
        out.append(0x0A)
        sendRawBytes(fd: fd, data: out)
    }

    private static func sendLine(fd: Int32, obj: [String: Any]) {
        sendJSONLine(fd: fd, obj: obj)
    }

    private static func writePNG(_ cgImage: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SafariumError.encode("CGImageDestinationCreateWithURL failed for \(url.path)")
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw SafariumError.encode("CGImageDestinationFinalize PNG failed")
        }
    }

    @MainActor
    public static func serve(socketPath: String) async throws {
        HostApp.prepare()
        let sockDir = URL(fileURLWithPath: socketPath).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: sockDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = chmod(sockDir, 0o700)
        var dirSt = stat()
        guard lstat(sockDir, &dirSt) == 0,
              (dirSt.st_mode & S_IFMT) == S_IFDIR,
              dirSt.st_uid == getuid(),
              (dirSt.st_mode & 0o777) == 0o700 else {
            throw SafariumError.invalidState("WarmWorker socket directory must be private (0700) and owned by current user: \(sockDir)")
        }
        unlink(socketPath)

        let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw SafariumError.encode("WarmWorker socket() failed: \(errno)")
        }
        _ = fcntl(listenFD, F_SETFD, FD_CLOEXEC)
        defer {
            Darwin.close(listenFD)
            unlink(socketPath)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw SafariumError.encode("socket path exceeds sockaddr_un.sun_path limit (\(bytes.count))")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            bytes.withUnsafeBytes { src in dst.copyBytes(from: src) }
        }
        let oldUmask = umask(0o077)
        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(listenFD, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        _ = umask(oldUmask)
        guard bindRC == 0 else {
            throw SafariumError.encode("WarmWorker bind() failed: \(errno)")
        }
        _ = chmod(socketPath, 0o600)
        guard Darwin.listen(listenFD, 8) == 0 else {
            throw SafariumError.encode("WarmWorker listen() failed: \(errno)")
        }

        let ruleStoreDir = URL(fileURLWithPath: sockDir).appendingPathComponent(".safarium-rules-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: ruleStoreDir) }
        var cachedLocalRule: WKContentRuleList?

        func ensureLocalOnlyRule() async throws -> WKContentRuleList {
            if let existing = cachedLocalRule { return existing }
            try FileManager.default.createDirectory(at: ruleStoreDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let store = WKContentRuleListStore(url: ruleStoreDir)
            let rules = """
            [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]
            """
            guard let rule = try await store?.compileContentRuleList(forIdentifier: "local-only", encodedContentRuleList: rules) else {
                throw SafariumError.invalidState("could not prepare WebKit local-asset rules")
            }
            cachedLocalRule = rule
            return rule
        }

        var pageWidth = 1080
        var pageHeight = 1920
        var page: Page?
        var shouldShutdown = false

        var ringPtr: UnsafeMutableRawPointer?
        var ringSize = 0
        var ringSlotBytes = 0
        var ringSlots = 0
        var ringSink: AVAssetWriterSink?
        var ringWidth = 0
        var ringHeight = 0
        var ringFPS = 30
        var ringPixelFormat: SinkPixelFormat = .nv12Left
        var ringFramesEncoded = 0
        var ringStartNS: UInt64 = 0
        var ringStaging: SafeFilePublisher.Staging?
        var ringTempURL: URL?
        var ringOutputURL: URL?
        var ringOverwrite = false

        func cleanupRing() {
            ringSink?.cancel()
            ringSink = nil
            if let ptr = ringPtr, ringSize > 0 {
                munmap(ptr, ringSize)
            }
            ringPtr = nil
            ringSize = 0
            ringSlots = 0
            ringSlotBytes = 0
            ringStaging?.cleanup()
            ringStaging = nil
            ringTempURL = nil
            ringOutputURL = nil
            ringOverwrite = false
        }
        defer { cleanupRing() }

        func ensurePage(w: Int, h: Int) async throws -> Page {
            if let existing = page, pageWidth == w, pageHeight == h {
                return existing
            }
            let localRule = try await ensureLocalOnlyRule()
            page?.close()
            pageWidth = w
            pageHeight = h
            let cfg = PageConfig(width: w, height: h, transparent: false, deterministicClock: false, snapshotQuality: .fast)
            let p = try await Page(config: cfg) { wc in
                wc.websiteDataStore = .nonPersistent()
                wc.mediaTypesRequiringUserActionForPlayback = .all
                wc.userContentController.add(localRule)
            }
            page = p
            return p
        }

        while !shouldShutdown {
            let clientFD: Int32 = await withCheckedContinuation { cont in
                acceptQueue.async {
                    while true {
                        let cfd = Darwin.accept(listenFD, nil, nil)
                        if cfd >= 0 {
                            _ = fcntl(cfd, F_SETFD, FD_CLOEXEC)
                            cont.resume(returning: cfd)
                            return
                        }
                        if errno != EINTR {
                            cont.resume(returning: cfd)
                            return
                        }
                    }
                }
            }
            if clientFD < 0 { break }
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard getpeereid(clientFD, &peerUID, &peerGID) == 0, peerUID == getuid() else {
                Darwin.close(clientFD)
                continue
            }
            let reader = SocketLineReader(fd: clientFD)

            while true {
                let (lineOpt, attachedFD) = await reader.nextCommand()
                guard let line = lineOpt else {
                    if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                    cleanupRing()
                    break
                }

                // Fast-path unquoted slot command: "S <slot> <frameIdx>"
                if line.hasPrefix("S ") {
                    if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                    let parts = line.split(separator: " ")
                    guard parts.count == 3,
                          let slot = Int(parts[1]),
                          let fIdx = Int(parts[2]),
                          let base = ringPtr,
                          let sink = ringSink,
                          slot >= 0, slot < ringSlots else {
                        sendLine(fd: clientFD, obj: ["ok": false, "err": "bad_slot_cmd"])
                        continue
                    }
                    let src = base.advanced(by: slot * ringSlotBytes)
                    let rowBytes = ringWidth * 4
                    do {
                        let pts = CMTime(value: Int64(fIdx), timescale: Int32(ringFPS))
                        let fmt = ringPixelFormat
                        let w = ringWidth
                        let h = ringHeight
                        try await sink.append(presentationTime: pts) { pb in
                            if fmt == .nv12Left {
                                try SafariumAccelerate.convertRawBGRAToNV12BT709Left(
                                    bgra: src, bgraBytesPerRow: rowBytes, into: pb, width: w, height: h
                                )
                            } else {
                                guard CVPixelBufferLockBaseAddress(pb, []) == kCVReturnSuccess else {
                                    throw SafariumError.encode("CVPixelBuffer lock failed")
                                }
                                defer { _ = CVPixelBufferUnlockBaseAddress(pb, []) }
                                guard let dstBase = CVPixelBufferGetBaseAddress(pb) else {
                                    throw SafariumError.encode("CVPixelBuffer missing baseAddress")
                                }
                                let dstStride = CVPixelBufferGetBytesPerRow(pb)
                                guard dstStride >= rowBytes else {
                                    throw SafariumError.encode("CVPixelBuffer stride \(dstStride) smaller than \(rowBytes)")
                                }
                                if dstStride == rowBytes {
                                    _ = memcpy(dstBase, src, h * rowBytes)
                                } else {
                                    for y in 0..<h {
                                        _ = memcpy(dstBase.advanced(by: y * dstStride), src.advanced(by: y * rowBytes), rowBytes)
                                    }
                                }
                            }
                        }
                        ringFramesEncoded += 1
                        sendLine(fd: clientFD, obj: ["ok": true, "slot": slot, "frame": fIdx])
                    } catch {
                        sendLine(fd: clientFD, obj: ["ok": false, "err": "\(error)"])
                    }
                    continue
                }

                guard let jsonData = line.data(using: .utf8),
                      let req = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                      let cmd = req["cmd"] as? String else {
                    if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                    sendLine(fd: clientFD, obj: ["ok": false, "err": "bad_json"])
                    continue
                }

                if cmd == "ping" {
                    if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                    sendLine(fd: clientFD, obj: ["ok": true, "pid": ProcessInfo.processInfo.processIdentifier])
                } else if cmd == "render_png" {
                    if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                    let html = req["html"] as? String ?? ""
                    let outPNG = req["out_png"] as? String ?? ""
                    let w = req["width"] as? Int ?? 1080
                    let h = req["height"] as? Int ?? 1920
                    let overwrite = req["overwrite"] as? Bool ?? false
                    guard !html.isEmpty, !outPNG.isEmpty, w >= 2, h >= 2, w <= 8192, h <= 8192 else {
                        sendLine(fd: clientFD, obj: ["ok": false, "err": "invalid_render_png_args"])
                        continue
                    }
                    let htmlURL = URL(fileURLWithPath: html)
                    let outURL = URL(fileURLWithPath: outPNG)
                    do {
                        try SafeFilePublisher.assertRegularReadableFile(htmlURL)
                        try SafeFilePublisher.preflight(outputURL: outURL, overwrite: overwrite)
                        let staging = try SafeFilePublisher.Staging(beside: outURL)
                        defer { staging.cleanup() }
                        let tempPNG = staging.fileURL("out.png")

                        let p = try await ensurePage(w: w, h: h)
                        let readAccessDir = htmlURL.deletingLastPathComponent()
                        try await p.load(.fileURL(htmlURL, readAccess: readAccessDir))
                        try await p.waitFor(.fonts)
                        let snap = try await p.snapshot()
                        try writePNG(snap.cgImage, to: tempPNG)
                        try SafeFilePublisher.publish(tempURL: tempPNG, to: outURL, overwrite: overwrite)
                        try? await p.load(.html("", baseURL: nil))
                        sendLine(fd: clientFD, obj: ["ok": true, "out": outPNG])
                    } catch {
                        sendLine(fd: clientFD, obj: ["ok": false, "err": "\(error)"])
                    }
                } else if cmd == "encode_ring_start" {
                    guard let fd = attachedFD, fd >= 0 else {
                        sendLine(fd: clientFD, obj: ["ok": false, "err": "missing_scm_rights_fd"])
                        continue
                    }
                    defer { Darwin.close(fd) }
                    cleanupRing()
                    let w = req["width"] as? Int ?? 1080
                    let h = req["height"] as? Int ?? 1920
                    let fps = req["fps"] as? Int ?? 30
                    let slots = req["slots"] as? Int ?? 3
                    let outMP4 = req["out_mp4"] as? String ?? ""
                    let codec = (req["codec"] as? String).flatMap { VideoCodec.parseCLI($0) } ?? .h264
                    let bitrate = req["bitrate"] as? Int ?? 20_000_000
                    let overwrite = req["overwrite"] as? Bool ?? false
                    let pxFmtRaw = (req["pixel_format"] as? String)?.lowercased() ?? "nv12-left"
                    let pxFmt: SinkPixelFormat
                    switch pxFmtRaw {
                    case "nv12-left": pxFmt = .nv12Left
                    case "bgra": pxFmt = .bgra
                    default:
                        sendLine(fd: clientFD, obj: ["ok": false, "err": "invalid_pixel_format"])
                        continue
                    }

                    guard !outMP4.isEmpty,
                          w >= 2, h >= 2, w <= 8192, h <= 8192,
                          fps > 0, fps <= 240,
                          slots > 0, slots <= 64,
                          bitrate > 0,
                          (pxFmt == .bgra || (w % 2 == 0 && h % 2 == 0)) else {
                        sendLine(fd: clientFD, obj: ["ok": false, "err": "invalid_ring_geometry"])
                        continue
                    }
                    let (px, ov1) = w.multipliedReportingOverflow(by: h)
                    let (minSlotBytes, ov2) = px.multipliedReportingOverflow(by: 4)
                    let slotBytes = req["slot_bytes"] as? Int ?? minSlotBytes
                    guard !ov1, !ov2, slotBytes >= minSlotBytes else {
                        sendLine(fd: clientFD, obj: ["ok": false, "err": "invalid_ring_geometry"])
                        continue
                    }
                    let (totalSize, ov3) = slotBytes.multipliedReportingOverflow(by: slots)
                    guard !ov3, totalSize > 0 else {
                        sendLine(fd: clientFD, obj: ["ok": false, "err": "invalid_ring_geometry"])
                        continue
                    }

                    var fdSt = stat()
                    guard fstat(fd, &fdSt) == 0,
                          (fdSt.st_mode & S_IFMT) == S_IFREG,
                          fdSt.st_uid == getuid(),
                          (fdSt.st_nlink == 0 || (fdSt.st_mode & 0o077) == 0),
                          fdSt.st_size >= off_t(totalSize) else {
                        sendLine(fd: clientFD, obj: ["ok": false, "err": "invalid_ring_fd"])
                        continue
                    }

                    let outURL = URL(fileURLWithPath: outMP4)
                    do {
                        try SafeFilePublisher.preflight(outputURL: outURL, overwrite: overwrite)
                        let staging = try SafeFilePublisher.Staging(beside: outURL)
                        let tempURL = staging.fileURL("ring.mp4")

                        let mapped = mmap(nil, totalSize, PROT_READ, MAP_SHARED, fd, 0)
                        guard mapped != MAP_FAILED, let mapped else {
                            staging.cleanup()
                            sendLine(fd: clientFD, obj: ["ok": false, "err": "mmap_failed_\(errno)"])
                            continue
                        }
                        do {
                            let sink = try AVAssetWriterSink(
                                url: tempURL,
                                width: w, height: h, fps: fps,
                                codec: codec, bitrate: bitrate,
                                pixelFormat: pxFmt, profile: .lowRamClosedGOP
                            )
                            ringWidth = w
                            ringHeight = h
                            ringFPS = fps
                            ringSlotBytes = slotBytes
                            ringSlots = slots
                            ringPixelFormat = pxFmt
                            ringSize = totalSize
                            ringPtr = mapped
                            ringSink = sink
                            ringStaging = staging
                            ringTempURL = tempURL
                            ringOutputURL = outURL
                            ringOverwrite = overwrite
                            ringFramesEncoded = 0
                            ringStartNS = DispatchTime.now().uptimeNanoseconds
                            sendLine(fd: clientFD, obj: ["ok": true, "slots": slots, "slot_bytes": slotBytes, "pixel_format": pxFmtRaw])
                        } catch {
                            munmap(mapped, totalSize)
                            staging.cleanup()
                            throw error
                        }
                    } catch {
                        sendLine(fd: clientFD, obj: ["ok": false, "err": "\(error)"])
                    }
                } else if cmd == "encode_ring_finish" {
                    if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                    do {
                        if let sink = ringSink {
                            try await sink.finish()
                        }
                        ringSink = nil
                        if let ptr = ringPtr, ringSize > 0 {
                            munmap(ptr, ringSize)
                        }
                        ringPtr = nil
                        ringSize = 0
                        if let tempURL = ringTempURL, let outURL = ringOutputURL {
                            try SafeFilePublisher.publish(tempURL: tempURL, to: outURL, overwrite: ringOverwrite)
                        }
                        ringStaging?.cleanup()
                        ringStaging = nil
                        ringTempURL = nil
                        ringOutputURL = nil
                        ringOverwrite = false
                        let dtMs = Double(DispatchTime.now().uptimeNanoseconds - ringStartNS) / 1e6
                        sendLine(fd: clientFD, obj: ["ok": true, "frames": ringFramesEncoded, "ms": dtMs])
                    } catch {
                        cleanupRing()
                        sendLine(fd: clientFD, obj: ["ok": false, "err": "\(error)"])
                    }
                } else if cmd == "quit" {
                    if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                    cleanupRing()
                    page?.close()
                    page = nil
                    shouldShutdown = true
                    sendLine(fd: clientFD, obj: ["ok": true])
                    break
                } else {
                    if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                    sendLine(fd: clientFD, obj: ["ok": false, "err": "unknown_cmd"])
                }
            }
            Darwin.close(clientFD)
        }
    }
}
