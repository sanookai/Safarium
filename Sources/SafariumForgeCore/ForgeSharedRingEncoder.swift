import CoreVideo
import Darwin
import Foundation
import SafariumContainers
import SafariumCore

// MARK: - UDS Listener & Peer Auth Helpers

public enum ForgeUnixSocketHelper {
    public static func createListener(at socketPath: String) throws -> Int32 {
        let sockURL = URL(fileURLWithPath: socketPath)
        let dirPath = sockURL.deletingLastPathComponent().path
        var dirSt = stat()
        if lstat(dirPath, &dirSt) != 0 {
            guard Darwin.mkdir(dirPath, 0o700) == 0 else {
                let err = errno
                throw SafariumError.invalidState("cannot create socket dir \(dirPath): \(String(cString: strerror(err)))")
            }
        }
        guard lstat(dirPath, &dirSt) == 0,
              (dirSt.st_mode & S_IFMT) == S_IFDIR,
              dirSt.st_uid == getuid(),
              (dirSt.st_mode & 0o777) == 0o700 else {
            throw SafariumError.invalidState("socket directory must be owned by uid and mode 0700 (not ExFAT): \(dirPath)")
        }
        let dirCaps = try APFSAutoStage.inspectVolume(at: URL(fileURLWithPath: dirPath))
        guard !dirCaps.noPermissions else {
            throw SafariumError.invalidState("socket directory must reside on a POSIX-permission volume (not ExFAT): \(dirPath)")
        }

        _ = unlink(socketPath)
        let lfd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard lfd >= 0 else {
            let err = errno
            throw SafariumError.encode("socket() failed: \(String(cString: strerror(err)))")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathUTF8 = Array(socketPath.utf8)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathUTF8.count < maxPath else {
            Darwin.close(lfd)
            throw SafariumError.invalidState("UDS path exceeds sun_path limit (\(maxPath)): \(socketPath)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            for (idx, b) in pathUTF8.enumerated() { raw[idx] = b }
        }
        let prevMask = umask(0o077)
        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(lfd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(prevMask)
        guard bindRC == 0 else {
            let err = errno
            Darwin.close(lfd)
            throw SafariumError.encode("bind(\(socketPath)) failed: \(String(cString: strerror(err)))")
        }
        _ = chmod(socketPath, 0o600)
        guard Darwin.listen(lfd, 8) == 0 else {
            let err = errno
            Darwin.close(lfd)
            _ = unlink(socketPath)
            throw SafariumError.encode("listen(\(socketPath)) failed: \(String(cString: strerror(err)))")
        }
        return lfd
    }

    public static func verifyPeerUID(connFD: Int32) -> Bool {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        return getpeereid(connFD, &peerUID, &peerGID) == 0 && peerUID == getuid()
    }
}

// MARK: - Ring Start Configuration & Report

public struct ForgeRingStartSpec: Codable, Sendable {
    public let width: Int
    public let height: Int
    public let fps: Int
    public let slots: Int
    public let pixFmt: String
    public let vflip: Bool?
    public let codec: String?
    public let bitrate: Int?
    public let quality: Double?
    public let outputPath: String
    public let secondaryPath: String?
    public let secondaryCodec: String?
    public let secondaryBitrate: Int?
    public let secondaryQuality: Double?
    public let secondaryBg: String?
    public let audioPath: String?
    public let subtitlesPath: String?
    public let subtitleLang: String?
    public let closedGOP: Bool?
    public let shmPath: String?
    public let overwrite: Bool?
}

public struct ForgeRingSessionReport: Codable, Sendable {
    public let transport: String
    public let slots: Int
    public let vflip: Bool
    public let pipeReport: ForgePipeEncodeReport
}

// MARK: - Zero-Copy mmap Ring Mapping (SCM_RIGHTS or Private 0600 APFS File)

public final class ForgeSharedRingSession {
    public let slots: Int
    public let slotBytes: Int
    public let totalBytes: Int
    public let transportMode: String
    public let vflip: Bool

    private var mmapBase: UnsafeMutableRawPointer?
    private let teeSession: ForgeDualTeeSession
    private var bgraScratch: [UInt8]
    private let startedNs: UInt64

    public init(spec: ForgeRingStartSpec, attachedFD: Int32?) throws {
        guard spec.slots >= 2 && spec.slots <= 64 else {
            if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
            throw SafariumError.invalidState("ring-encode slots must be in 2...64, got \(spec.slots)")
        }
        guard spec.width >= 2, spec.height >= 2, spec.width <= 16_384, spec.height <= 16_384 else {
            if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
            throw SafariumError.invalidState("ring-encode dimensions out of bounds: \(spec.width)x\(spec.height)")
        }
        let rawFmt = try ForgeRawPixelFormat.parse(spec.pixFmt)
        let (px, ov1) = spec.width.multipliedReportingOverflow(by: spec.height)
        let (sBytes, ov2) = px.multipliedReportingOverflow(by: rawFmt.bytesPerPixel)
        let (totBytes, ov3) = spec.slots.multipliedReportingOverflow(by: sBytes)
        guard !ov1 && !ov2 && !ov3 && totBytes > 0 else {
            if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
            throw SafariumError.invalidState("ring-encode geometry overflow")
        }

        let targetFD: Int32
        let mode: String
        if let fd = attachedFD, fd >= 0 {
            targetFD = fd
            mode = "scm_rights_mmap"
        } else if let shmPath = spec.shmPath, !shmPath.isEmpty {
            let vol = try APFSAutoStage.inspectVolume(at: URL(fileURLWithPath: shmPath))
            guard !vol.noPermissions else {
                throw SafariumError.invalidState("shm-file must reside on a POSIX-permission volume (not ExFAT): \(shmPath)")
            }
            let opened = Darwin.open(shmPath, O_RDONLY | O_NOFOLLOW)
            guard opened >= 0 else {
                let err = errno
                throw SafariumError.invalidState("cannot open shm-file \(shmPath): \(String(cString: strerror(err)))")
            }
            targetFD = opened
            mode = "file_backed_mmap"
        } else {
            throw SafariumError.invalidState("RING_START requires attached SCM_RIGHTS FD or shmPath")
        }
        defer { Darwin.close(targetFD) }

        var st = stat()
        guard fstat(targetFD, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == getuid(),
              (st.st_nlink == 0 || (st.st_mode & 0o777) == 0o600),
              st.st_size >= off_t(totBytes) else {
            throw SafariumError.invalidState(
                "ring FD rejected (expected regular file, owner uid, unlinked or 0600, size >= \(totBytes))"
            )
        }

        let mapped = mmap(nil, totBytes, PROT_READ, MAP_SHARED, targetFD, 0)
        guard mapped != MAP_FAILED else {
            let err = errno
            throw SafariumError.encode("mmap ring failed: \(String(cString: strerror(err)))")
        }

        let priCodec = try Self.parseCodec(spec.codec ?? "h264")
        let secURL = spec.secondaryPath.map { URL(fileURLWithPath: $0) }
        let secCodec: VideoCodec?
        if let sc = spec.secondaryCodec {
            secCodec = try Self.parseCodec(sc)
        } else {
            secCodec = secURL.map { $0.pathExtension.lowercased() == "mov" ? .proRes4444 : .h264 }
        }
        let cfg = ForgePipeEncodeConfig(
            width: spec.width,
            height: spec.height,
            fps: spec.fps,
            inputPixelFormat: rawFmt,
            primaryCodec: priCodec,
            primaryBitrate: spec.bitrate,
            primaryQuality: spec.quality,
            secondaryOutputURL: secURL,
            secondaryCodec: secCodec,
            secondaryBitrate: spec.secondaryBitrate ?? 8_000_000,
            secondaryQuality: spec.secondaryQuality,
            secondaryBackgroundHex: spec.secondaryBg ?? "#000000",
            audioURL: spec.audioPath.map { URL(fileURLWithPath: $0) },
            subtitlesURL: spec.subtitlesPath.map { URL(fileURLWithPath: $0) },
            subtitleLang: spec.subtitleLang ?? "tha",
            closedGOP: spec.closedGOP ?? true,
            maxFrames: nil,
            vflip: spec.vflip ?? false,
            overwrite: spec.overwrite ?? false
        )

        do {
            self.teeSession = try ForgeDualTeeSession(primaryOutputURL: URL(fileURLWithPath: spec.outputPath), config: cfg)
        } catch {
            munmap(mapped, totBytes)
            throw error
        }

        self.mmapBase = mapped
        self.slots = spec.slots
        self.slotBytes = sBytes
        self.totalBytes = totBytes
        self.transportMode = mode
        self.vflip = cfg.vflip
        self.bgraScratch = [UInt8](repeating: 0, count: spec.width * spec.height * 4)
        self.startedNs = DispatchTime.now().uptimeNanoseconds
    }

    deinit {
        closeMapping()
    }

    public func closeMapping() {
        if let base = mmapBase {
            munmap(base, totalBytes)
            mmapBase = nil
        }
    }

    public func appendSlot(_ slot: Int, frameIndex: Int) async throws {
        guard let base = mmapBase else {
            throw SafariumError.invalidState("ring mapping already closed")
        }
        guard slot >= 0 && slot < slots else {
            throw SafariumError.invalidState("ring slot \(slot) out of range 0..<\(slots)")
        }
        guard frameIndex == teeSession.framesWritten else {
            throw SafariumError.invalidState("ring frameIdx \(frameIndex) out of sequence (expected \(teeSession.framesWritten))")
        }
        let slotPtr = UnsafeRawPointer(base.advanced(by: slot * slotBytes))
        let w = teeSession.config.width
        let h = teeSession.config.height
        let fmt = teeSession.config.inputPixelFormat
        let vf = teeSession.config.vflip
        try bgraScratch.withUnsafeMutableBytes { dstRaw in
            try ForgeSheetAndQA.convertRawPointerToBGRA(
                srcPtr: slotPtr,
                byteCount: slotBytes,
                format: fmt,
                width: w,
                height: h,
                destination: dstRaw.baseAddress!,
                dstStride: w * 4,
                vflip: vf
            )
        }
        try await teeSession.appendBGRAFrame(bgraScratch)
    }

    public func finish() async throws -> ForgeRingSessionReport {
        defer { closeMapping() }
        let rep = try await teeSession.finishAndCommit(startedUptimeNs: startedNs)
        return ForgeRingSessionReport(
            transport: transportMode,
            slots: slots,
            vflip: vflip,
            pipeReport: rep
        )
    }

    public func cancel() {
        teeSession.cancel()
        closeMapping()
    }

    private static func parseCodec(_ raw: String) throws -> VideoCodec {
        switch raw.lowercased() {
        case "h264", "avc1": return .h264
        case "hevc", "h265", "hvc1": return .hevc
        case "hevc-alpha", "hevc_alpha", "muxa": return .hevcAlpha
        case "prores4444", "prores-4444", "ap4h": return .proRes4444
        case "prores422", "prores-422": return .proRes422
        default: throw SafariumError.invalidState("unsupported codec '\(raw)'")
        }
    }
}

// MARK: - Standalone UDS Server (`safarium-forge ring-encode`)

public enum ForgeSharedRingServer {
    public static func serve(socketPath: String, idleTimeoutSeconds: Double = 30.0) async throws -> ForgeRingSessionReport {
        await MainActor.run { HostApp.prepare() }
        let lfd = try ForgeUnixSocketHelper.createListener(at: socketPath)
        defer {
            Darwin.close(lfd)
            _ = unlink(socketPath)
        }

        // Emit ready marker on stderr so subprocess clients do not busy-poll.
        FileHandle.standardError.write(Data("RING_READY \(socketPath)\n".utf8))

        var pfd = pollfd(fd: lfd, events: Int16(POLLIN), revents: 0)
        let timeoutMs = Int32(max(100, min(600_000, Int(idleTimeoutSeconds * 1000.0))))
        let ready = Darwin.poll(&pfd, 1, timeoutMs)
        guard ready > 0 else {
            throw SafariumError.timeout("ring-encode timed out waiting for client connection after \(idleTimeoutSeconds)s")
        }

        let connFD = Darwin.accept(lfd, nil, nil)
        guard connFD >= 0 else {
            let err = errno
            throw SafariumError.encode("accept() failed: \(String(cString: strerror(err)))")
        }
        defer { Darwin.close(connFD) }
        guard ForgeUnixSocketHelper.verifyPeerUID(connFD: connFD) else {
            WarmWorkerServer.sendJSONLine(fd: connFD, obj: ["ok": false, "error": "peer UID mismatch"])
            throw SafariumError.invalidState("ring-encode rejected client with mismatched UID")
        }

        let reader = SafariumSocketLineReader(fd: connFD)
        var ringSession: ForgeRingSessionWrapper?
        defer { ringSession?.cancelIfActive() }

        while true {
            let (rawLine, fd) = await reader.nextCommand()
            guard let line = rawLine?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                if let fd, fd >= 0 { Darwin.close(fd) }
                throw SafariumError.encode("ring-encode client disconnected before RING_FINISH")
            }
            if line.isEmpty {
                if let fd, fd >= 0 { Darwin.close(fd) }
                continue
            }

            if line.hasPrefix("RING_START ") {
                if ringSession != nil {
                    if let fd, fd >= 0 { Darwin.close(fd) }
                    WarmWorkerServer.sendJSONLine(fd: connFD, obj: ["ok": false, "error": "ring already started"])
                    continue
                }
                let jsonStr = String(line.dropFirst("RING_START ".count))
                do {
                    let spec = try JSONDecoder().decode(ForgeRingStartSpec.self, from: Data(jsonStr.utf8))
                    let s = try ForgeSharedRingSession(spec: spec, attachedFD: fd)
                    ringSession = ForgeRingSessionWrapper(s)
                    WarmWorkerServer.sendJSONLine(fd: connFD, obj: [
                        "ok": true, "cmd": "RING_START", "transport": s.transportMode, "slots": s.slots,
                    ])
                } catch {
                    WarmWorkerServer.sendJSONLine(fd: connFD, obj: ["ok": false, "error": "\(error)"])
                    throw error
                }
            } else if line.hasPrefix("S ") {
                if let fd, fd >= 0 { Darwin.close(fd) }
                let parts = line.split(separator: " ")
                guard parts.count == 3, let slot = Int(parts[1]), let idx = Int(parts[2]) else {
                    WarmWorkerServer.sendJSONLine(fd: connFD, obj: ["ok": false, "error": "usage: S <slot> <frameIdx>"])
                    continue
                }
                guard let active = ringSession?.session else {
                    WarmWorkerServer.sendJSONLine(fd: connFD, obj: ["ok": false, "error": "no active RING_START"])
                    continue
                }
                try await active.appendSlot(slot, frameIndex: idx)
                WarmWorkerServer.sendJSONLine(fd: connFD, obj: ["ok": true, "cmd": "S", "slot": slot, "frame": idx])
            } else if line == "RING_FINISH" {
                if let fd, fd >= 0 { Darwin.close(fd) }
                guard let active = ringSession?.take() else {
                    throw SafariumError.invalidState("RING_FINISH without active RING_START")
                }
                let rep = try await active.finish()
                let repData = try JSONEncoder().encode(rep)
                let repObj = (try? JSONSerialization.jsonObject(with: repData)) ?? [:]
                WarmWorkerServer.sendJSONLine(fd: connFD, obj: ["ok": true, "cmd": "RING_FINISH", "report": repObj])
                return rep
            } else {
                if let fd, fd >= 0 { Darwin.close(fd) }
                WarmWorkerServer.sendJSONLine(fd: connFD, obj: ["ok": false, "error": "unknown ring command: \(line)"])
            }
        }
    }
}

private final class ForgeRingSessionWrapper {
    var session: ForgeSharedRingSession?
    init(_ session: ForgeSharedRingSession) { self.session = session }
    func take() -> ForgeSharedRingSession? {
        let s = session
        session = nil
        return s
    }
    func cancelIfActive() {
        session?.cancel()
        session = nil
    }
}
