import Darwin
import Foundation
import SafariumCore

public struct ForgeWarmDaemonReport: Codable, Sendable {
    public let socketPath: String
    public let exitReason: String
    public let requestsHandled: Int
    public let pqCompiledWarm: Bool
    public let metalAvailable: Bool
    public let cacheRoot: String?
    public let uptimeMs: Double
    public let selfFootprintMB: Double
}

/// Slot-Scoped Warm Session (Model 1 — 100% SF-VIDEO-1 compliant):
/// Runs inside `safarium-render forge daemon`, keeps Metal/SafariumPQEngine/ShotCache hot
/// across sequential UDS RPCs (~10-30 ms dispatch), and auto-exits after `idleTimeoutSeconds` (default 20s)
/// releasing the FIFO queue slot and returning RAM to 0 MB.
public enum ForgeWarmDaemon {
    @MainActor
    public static func serve(
        socketPath: String,
        idleTimeoutSeconds: Double = 20.0,
        cacheRootURL: URL? = nil,
        preloadPQEngine: Bool = true
    ) async throws -> ForgeWarmDaemonReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        HostApp.prepare()

        let lfd = try ForgeUnixSocketHelper.createListener(at: socketPath)
        defer {
            Darwin.close(lfd)
            _ = unlink(socketPath)
        }

        let metalCtx = SafariumMetalContext.shared
        let pqEngine: SafariumPQEngine? = preloadPQEngine ? (try? SafariumPQEngine()) : nil
        let shotCache: ForgeShotCache? = try? ForgeShotCache(rootURL: cacheRootURL)

        FileHandle.standardError.write(Data("DAEMON_READY \(socketPath)\n".utf8))

        var requestsHandled = 0
        var exitReason = "idle_timeout"
        let idleMsTotal = max(100, Int(idleTimeoutSeconds * 1000.0))

        acceptLoop: while true {
            var pfd = pollfd(fd: lfd, events: Int16(POLLIN), revents: 0)
            let pollRes = Darwin.poll(&pfd, 1, Int32(idleMsTotal))
            if pollRes == 0 {
                exitReason = "idle_timeout"
                break acceptLoop
            }
            if pollRes < 0 {
                if errno == EINTR { continue }
                let err = errno
                throw SafariumError.encode("daemon poll() failed: \(String(cString: strerror(err)))")
            }

            let connFD = Darwin.accept(lfd, nil, nil)
            if connFD < 0 {
                if errno == EINTR { continue }
                break acceptLoop
            }
            guard ForgeUnixSocketHelper.verifyPeerUID(connFD: connFD) else {
                WarmWorkerServer.sendJSONLine(fd: connFD, obj: ["ok": false, "error": "peer UID mismatch"])
                Darwin.close(connFD)
                continue
            }

            let reader = SafariumSocketLineReader(fd: connFD)
            var activeRing: ForgeSharedRingSession?
            defer {
                activeRing?.cancel()
                Darwin.close(connFD)
            }

            while true {
                let (rawLine, attachedFD) = await reader.nextCommand()
                guard let line = rawLine?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                    activeRing?.cancel()
                    activeRing = nil
                    break
                }
                if line.isEmpty {
                    if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                    continue
                }

                // Support raw push lines ("S <slot> <frameIdx>") or JSON RPC objects.
                if line.hasPrefix("S ") {
                    if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                    let parts = line.split(separator: " ")
                    guard parts.count == 3, let slot = Int(parts[1]), let idx = Int(parts[2]), let ring = activeRing else {
                        WarmWorkerServer.sendJSONLine(fd: connFD, obj: ["ok": false, "error": "invalid or unstarted ring frame S"])
                        continue
                    }
                    do {
                        try await ring.appendSlot(slot, frameIndex: idx)
                        requestsHandled += 1
                        WarmWorkerServer.sendJSONLine(fd: connFD, obj: ["ok": true, "cmd": "S", "slot": slot, "frame": idx])
                    } catch {
                        WarmWorkerServer.sendJSONLine(fd: connFD, obj: ["ok": false, "error": "\(error)"])
                    }
                    continue
                }

                let d0 = DispatchTime.now().uptimeNanoseconds
                guard let reqData = line.data(using: .utf8),
                      let req = try? JSONSerialization.jsonObject(with: reqData) as? [String: Any],
                      let cmd = req["cmd"] as? String else {
                    if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                    WarmWorkerServer.sendJSONLine(fd: connFD, obj: ["ok": false, "error": "invalid JSON request"])
                    continue
                }

                requestsHandled += 1
                do {
                    switch cmd {
                    case "ping":
                        if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                        let dispatchMs = Double(DispatchTime.now().uptimeNanoseconds - d0) / 1e6
                        WarmWorkerServer.sendJSONLine(fd: connFD, obj: [
                            "ok": true,
                            "cmd": "ping",
                            "pid": getpid(),
                            "pqWarm": pqEngine != nil,
                            "metalAvailable": metalCtx != nil,
                            "warmDispatchMs": dispatchMs,
                            "selfFootprintMB": Self.currentFootprintMB(),
                        ])

                    case "capabilities":
                        if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                        let dispatchMs = Double(DispatchTime.now().uptimeNanoseconds - d0) / 1e6
                        WarmWorkerServer.sendJSONLine(fd: connFD, obj: [
                            "ok": true,
                            "cmd": "capabilities",
                            "metalDevice": metalCtx?.device.name ?? "none",
                            "pqWarm": pqEngine != nil,
                            "cacheRoot": shotCache?.rootURL.path ?? "",
                            "idleTimeoutSeconds": idleTimeoutSeconds,
                            "warmDispatchMs": dispatchMs,
                            "selfFootprintMB": Self.currentFootprintMB(),
                        ])

                    case "inspect":
                        if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                        guard let path = req["path"] as? String else {
                            throw SafariumError.invalidState("inspect requires path")
                        }
                        let includeAudio = (req["includeAudioPackets"] as? Bool) ?? false
                        let rep = try await PacketProbe.inspect(
                            url: URL(fileURLWithPath: path),
                            includeAudioPackets: includeAudio
                        )
                        try Self.sendCodableResponse(fd: connFD, cmd: cmd, result: rep, startNs: d0)

                    case "pq":
                        if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                        guard let refPath = req["refPath"] as? String, let candPath = req["candPath"] as? String else {
                            throw SafariumError.invalidState("pq requires refPath and candPath")
                        }
                        let rep = try await SafariumPQ.compareVideos(
                            referenceURL: URL(fileURLWithPath: refPath),
                            candidateURL: URL(fileURLWithPath: candPath),
                            maxSamples: (req["samples"] as? Int) ?? 8,
                            checkThaiOCR: (req["thaiOCR"] as? Bool) ?? false,
                            expectedThaiText: req["expectedThai"] as? String,
                            minScore: (req["minScore"] as? Double) ?? 85.0,
                            maxDeltaE00P95: (req["maxDeltaE00P95"] as? Double) ?? 2.0,
                            minMSSSIM: (req["minMSSSIM"] as? Double) ?? 0.97,
                            engine: pqEngine
                        )
                        try Self.sendCodableResponse(fd: connFD, cmd: cmd, result: rep, startNs: d0)

                    case "cache_store":
                        if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                        guard let cache = shotCache else {
                            throw SafariumError.invalidState("shot cache unavailable")
                        }
                        guard let key = req["key"] as? String, let src = req["sourcePath"] as? String else {
                            throw SafariumError.invalidState("cache_store requires key and sourcePath")
                        }
                        let ns = (req["namespace"] as? String) ?? "default"
                        let rep = try cache.store(key: key, sourceURL: URL(fileURLWithPath: src), namespace: ns)
                        try Self.sendCodableResponse(fd: connFD, cmd: cmd, result: rep, startNs: d0)

                    case "cache_lookup":
                        if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                        guard let cache = shotCache else {
                            throw SafariumError.invalidState("shot cache unavailable")
                        }
                        guard let key = req["key"] as? String else {
                            throw SafariumError.invalidState("cache_lookup requires key")
                        }
                        let destURL = (req["destPath"] as? String).map { URL(fileURLWithPath: $0) }
                        let overwrite = (req["overwrite"] as? Bool) ?? false
                        let rep = try cache.lookup(key: key, destinationURL: destURL, overwrite: overwrite)
                        try Self.sendCodableResponse(fd: connFD, cmd: cmd, result: rep, startNs: d0)

                    case "cache_stats":
                        if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                        guard let cache = shotCache else {
                            throw SafariumError.invalidState("shot cache unavailable")
                        }
                        let rep = try cache.stats()
                        try Self.sendCodableResponse(fd: connFD, cmd: cmd, result: rep, startNs: d0)

                    case "ring_start":
                        if activeRing != nil {
                            if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                            throw SafariumError.invalidState("ring already active on this connection")
                        }
                        guard let specDict = req["spec"] as? [String: Any] else {
                            if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                            throw SafariumError.invalidState("ring_start requires spec object")
                        }
                        let specBytes = try JSONSerialization.data(withJSONObject: specDict)
                        let spec = try JSONDecoder().decode(ForgeRingStartSpec.self, from: specBytes)
                        let session = try ForgeSharedRingSession(spec: spec, attachedFD: attachedFD)
                        activeRing = session
                        let dispatchMs = Double(DispatchTime.now().uptimeNanoseconds - d0) / 1e6
                        WarmWorkerServer.sendJSONLine(fd: connFD, obj: [
                            "ok": true,
                            "cmd": "ring_start",
                            "transport": session.transportMode,
                            "slots": session.slots,
                            "warmDispatchMs": dispatchMs,
                        ])

                    case "ring_finish":
                        if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                        guard let ring = activeRing else {
                            throw SafariumError.invalidState("ring_finish without ring_start")
                        }
                        activeRing = nil
                        let rep = try await ring.finish()
                        try Self.sendCodableResponse(fd: connFD, cmd: cmd, result: rep, startNs: d0)

                    case "shutdown":
                        if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                        activeRing?.cancel()
                        activeRing = nil
                        exitReason = "client_shutdown"
                        let dispatchMs = Double(DispatchTime.now().uptimeNanoseconds - d0) / 1e6
                        WarmWorkerServer.sendJSONLine(fd: connFD, obj: [
                            "ok": true, "cmd": "shutdown", "warmDispatchMs": dispatchMs,
                        ])
                        break acceptLoop

                    default:
                        if let fd = attachedFD, fd >= 0 { Darwin.close(fd) }
                        throw SafariumError.invalidState("unknown daemon command '\(cmd)'")
                    }
                } catch {
                    WarmWorkerServer.sendJSONLine(fd: connFD, obj: [
                        "ok": false,
                        "cmd": cmd,
                        "error": "\(error)",
                        "warmDispatchMs": Double(DispatchTime.now().uptimeNanoseconds - d0) / 1e6,
                    ])
                }
            }
        }

        let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return ForgeWarmDaemonReport(
            socketPath: socketPath,
            exitReason: exitReason,
            requestsHandled: requestsHandled,
            pqCompiledWarm: pqEngine != nil,
            metalAvailable: metalCtx != nil,
            cacheRoot: shotCache?.rootURL.path,
            uptimeMs: wallMs,
            selfFootprintMB: Self.currentFootprintMB()
        )
    }

    private static func sendCodableResponse<T: Encodable>(
        fd: Int32,
        cmd: String,
        result: T,
        startNs: UInt64
    ) throws {
        let data = try JSONEncoder().encode(result)
        let obj = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
        let dispatchMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1e6
        WarmWorkerServer.sendJSONLine(fd: fd, obj: [
            "ok": true,
            "cmd": cmd,
            "result": obj,
            "warmDispatchMs": dispatchMs,
            "selfFootprintMB": currentFootprintMB(),
        ])
    }

    private static func currentFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0.0 }
        return Double(info.phys_footprint) / (1024.0 * 1024.0)
    }
}
