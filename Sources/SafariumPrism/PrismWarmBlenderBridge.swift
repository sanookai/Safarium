import CoreVideo
import Darwin
import Foundation
import SafariumCore
import SafariumForgeCore

public enum PrismBlenderEngine: String, Codable, Sendable, Equatable {
    case eevee = "BLENDER_EEVEE"
    case cycles = "CYCLES"

    public static func parse(_ raw: String) throws -> PrismBlenderEngine {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "EEVEE", "BLENDER_EEVEE", "BLENDER_EEVEE_NEXT":
            return .eevee
        case "CYCLES":
            return .cycles
        default:
            throw SafariumError.invalidState("unsupported Blender engine '\(raw)' (expected eevee|BLENDER_EEVEE|CYCLES)")
        }
    }
}

public enum PrismSHMMethod: String, Codable, Sendable, Equatable {
    case bmpMmap = "bmp_mmap"
    case gpuOffscreen = "gpu_offscreen"

    public static func parse(_ raw: String) throws -> PrismSHMMethod {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "bmp", "bmp_mmap", "bmpmmap":
            return .bmpMmap
        case "gpu", "gpu_offscreen", "gpuoffscreen":
            return .gpuOffscreen
        default:
            throw SafariumError.invalidState("unsupported SHM method '\(raw)' (expected bmp_mmap|gpu_offscreen)")
        }
    }
}

public struct PrismBlenderDelta: Codable, Sendable, Equatable {
    public var frame: Int?
    public var cameraPositionThree: PrismVec3?
    public var cameraQuaternionThree: PrismQuaternion?
    public var cameraPositionDeltaBlender: PrismVec3?
    public var lensMM: Double?
    public var fovYDeg: Double?
    public var shiftX: Double?
    public var shiftY: Double?
    public var focusDistance: Double?
    public var fstop: Double?
    public var filmTransparent: Bool?
    public var samples: Int?

    public init(
        frame: Int? = nil,
        cameraPositionThree: PrismVec3? = nil,
        cameraQuaternionThree: PrismQuaternion? = nil,
        cameraPositionDeltaBlender: PrismVec3? = nil,
        lensMM: Double? = nil,
        fovYDeg: Double? = nil,
        shiftX: Double? = nil,
        shiftY: Double? = nil,
        focusDistance: Double? = nil,
        fstop: Double? = nil,
        filmTransparent: Bool? = nil,
        samples: Int? = nil
    ) {
        self.frame = frame
        self.cameraPositionThree = cameraPositionThree
        self.cameraQuaternionThree = cameraQuaternionThree
        self.cameraPositionDeltaBlender = cameraPositionDeltaBlender
        self.lensMM = lensMM
        self.fovYDeg = fovYDeg
        self.shiftX = shiftX
        self.shiftY = shiftY
        self.focusDistance = focusDistance
        self.fstop = fstop
        self.filmTransparent = filmTransparent
        self.samples = samples
    }
}

public struct PrismLoadedBlendInfo: Codable, Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let fps: Double
    public let frameStart: Int
    public let frameEnd: Int
    public let engine: String
    public let loadMs: Double
    public let ruMaxRSSBytes: Int64
}

public struct PrismSHMFrameInfo: Codable, Sendable, Equatable {
    public let frame: Int
    public let method: String
    public let width: Int
    public let height: Int
    public let byteCount: Int
    public let sha256Prefix: String
    public let meanRGB: Double
    public let transparentPixels: Int
    public let renderMs: Double
    public let extractMs: Double
    public let totalMs: Double
    public let ruMaxRSSBytes: Int64
}

/// Persistent warm Blender 5.2.2 LTS UDS + `MAP_SHARED` `mmap` daemon bridge.
/// Guarantees clean worker reaping on `shutdown()` and `deinit`.
public final class PrismWarmBlenderBridge: @unchecked Sendable {
    public static let defaultBlenderPath = "/Applications/Blender.app/Contents/MacOS/Blender"

    private let lock = NSLock()
    private let blenderURL: URL
    private let workerURL: URL
    private let idleTimeoutSeconds: Double
    private let gpuRecycleEveryFrames: Int
    private let threads: Int?

    private var runtimeDir: URL?
    private var socketPath: String?
    private var shmPath: String?
    private var process: Process?
    private var socketFD: Int32 = -1
    private var readBuffer = Data()
    private var shmPtr: UnsafeMutableRawPointer?
    private var shmSize: Int = 0
    private var shmWidth: Int = 0
    private var shmHeight: Int = 0
    private var isShutDown = false

    public init(
        blenderURL: URL? = nil,
        workerScriptURL: URL? = nil,
        idleTimeoutSeconds: Double = 300.0,
        gpuRecycleEveryFrames: Int = 100,
        threads: Int? = nil
    ) throws {
        self.blenderURL = try blenderURL ?? Self.resolveBlenderBinary()
        self.workerURL = try workerScriptURL ?? Self.resolveWorkerScript()
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.gpuRecycleEveryFrames = max(1, gpuRecycleEveryFrames)
        self.threads = threads
    }

    deinit {
        shutdownSync()
    }

    public var childPID: Int32? {
        lock.withLock {
            guard let p = process, p.isRunning else { return nil }
            return p.processIdentifier
        }
    }

    public static func resolveBlenderBinary() throws -> URL {
        let envPath = ProcessInfo.processInfo.environment["SAFARIUM_BLENDER_BIN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidatePath = (envPath?.isEmpty == false) ? envPath! : defaultBlenderPath
        let url = URL(fileURLWithPath: candidatePath)
        try assertRegularNonSymlink(url: url, expectedExtension: nil, requireExecutable: true)
        return url
    }

    public static func resolveWorkerScript() throws -> URL {
        var candidates: [URL] = []
        if let envPath = ProcessInfo.processInfo.environment["SAFARIUM_PRISM_WORKER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !envPath.isEmpty {
            candidates.append(URL(fileURLWithPath: envPath))
        }
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent("prism-blender-worker.py"))
        }
        // Development fallback: search up from source file path & current directory for Tools/prism-blender-worker.py
        for anchor in [
            URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        ] {
            var cur = anchor
            for _ in 0..<8 {
                candidates.append(cur.appendingPathComponent("Tools/prism-blender-worker.py"))
                let parent = cur.deletingLastPathComponent()
                if parent.path == cur.path { break }
                cur = parent
            }
        }

        for cand in candidates {
            if (try? assertRegularNonSymlink(url: cand, expectedExtension: "py", requireExecutable: false)) != nil {
                return cand
            }
        }
        throw SafariumError.invalidState("prism-blender-worker.py not found (checked SAFARIUM_PRISM_WORKER, executable sibling, and Tools/prism-blender-worker.py)")
    }

    public static func queryBlenderVersion(blenderURL: URL? = nil) -> String? {
        guard let bin = try? (blenderURL ?? resolveBlenderBinary()) else { return nil }
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return raw.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        } catch {
            return nil
        }
    }

    private static func assertRegularNonSymlink(url: URL, expectedExtension: String?, requireExecutable: Bool) throws {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            throw SafariumError.invalidState("file does not exist: \(url.path)")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw SafariumError.invalidState("refusing non-regular or symlink file: \(url.path)")
        }
        if let ext = expectedExtension, url.pathExtension.lowercased() != ext.lowercased() {
            throw SafariumError.invalidState("expected .\(ext) file, got \(url.lastPathComponent)")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw SafariumError.invalidState("file is not readable: \(url.path)")
        }
        if requireExecutable && !FileManager.default.isExecutableFile(atPath: url.path) {
            throw SafariumError.invalidState("executable permission missing: \(url.path)")
        }
    }

    // MARK: - Lifecycle

    public func start(startupTimeoutSeconds: TimeInterval = 30.0) async throws {
        try await Task.detached(priority: .userInitiated) { [self] in
            try startSync(startupTimeoutSeconds: startupTimeoutSeconds)
        }.value
    }

    private func startSync(startupTimeoutSeconds: TimeInterval) throws {
        let alreadyRunning = lock.withLock { process?.isRunning == true && socketFD >= 0 }
        if alreadyRunning { return }

        shutdownSync()

        // Use short /tmp path so sockaddr_un.sun_path (104B limit on macOS) is never exceeded.
        let rtName = "sfp-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        let rtDir = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(rtName, isDirectory: true)
        guard Darwin.mkdir(rtDir.path, 0o700) == 0 else {
            let err = errno
            throw SafariumError.encode("cannot create Blender runtime dir \(rtDir.path): \(String(cString: strerror(err)))")
        }
        _ = chmod(rtDir.path, 0o700)
        var st = stat()
        guard lstat(rtDir.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid(), (st.st_mode & 0o777) == 0o700 else {
            try? FileManager.default.removeItem(at: rtDir)
            throw SafariumError.invalidState("Blender runtime dir failed 0700 ownership check: \(rtDir.path)")
        }

        let sockP = rtDir.appendingPathComponent("w.sock").path
        let shmP = rtDir.appendingPathComponent("w.shm").path

        let proc = Process()
        proc.executableURL = blenderURL
        var args = ["-b", "--factory-startup", "-Y"]
        if let t = threads, t > 0 {
            args.append(contentsOf: ["--threads", "\(t)"])
        }
        args.append(contentsOf: [
            "--python-exit-code", "1",
            "-P", workerURL.path,
            "--",
            "--socket", sockP,
            "--shm", shmP,
            "--idle-timeout", "\(idleTimeoutSeconds)",
            "--gpu-recycle-every", "\(gpuRecycleEveryFrames)",
        ])
        proc.arguments = args

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe
        proc.standardInput = FileHandle.nullDevice

        lock.withLock {
            isShutDown = false
            runtimeDir = rtDir
            socketPath = sockP
            shmPath = shmP
            process = proc
        }

        do {
            try proc.run()
            let deadline = Date().addingTimeInterval(max(1.0, startupTimeoutSeconds))
            let fd = outPipe.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var logAccum = Data()
            var readySeen = false

            while Date() < deadline {
                if FileManager.default.fileExists(atPath: sockP) && readySeen {
                    break
                }
                var buf = [UInt8](repeating: 0, count: 4096)
                let n = Darwin.read(fd, &buf, buf.count)
                if n > 0 {
                    logAccum.append(contentsOf: buf[0..<n])
                    if let s = String(data: logAccum, encoding: .utf8), s.contains("WARM_READY ") {
                        readySeen = true
                        if FileManager.default.fileExists(atPath: sockP) { break }
                    }
                } else if !proc.isRunning {
                    let msg = String(data: logAccum, encoding: .utf8) ?? ""
                    throw SafariumError.encode("Blender worker exited early (status \(proc.terminationStatus)): \(msg)")
                } else {
                    usleep(15_000)
                }
            }
            // Drain pipe asynchronously in background? Close read end only if we don't want SIGPIPE?
            // Keeping worker clean without blocking stdout: actually `prism-blender-worker` only prints WARM_READY once;
            // Blender prints minimal status lines. Closing outPipe could cause SIGPIPE if Blender prints later!
            // Instead attach readabilityHandler to discard further output cleanly without SIGPIPE!
            outPipe.fileHandleForReading.readabilityHandler = { fh in
                _ = fh.availableData
            }

            guard readySeen && FileManager.default.fileExists(atPath: sockP) else {
                let msg = String(data: logAccum, encoding: .utf8) ?? ""
                throw SafariumError.timeout("Blender worker failed to become ready within \(startupTimeoutSeconds)s: \(msg)")
            }

            let sock = try Self.connectUnixSocket(path: sockP)
            lock.withLock {
                socketFD = sock
                readBuffer.removeAll(keepingCapacity: false)
            }
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            shutdownSync()
            throw error
        }
    }

    private static func connectUnixSocket(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SafariumError.encode("socket(AF_UNIX) failed: \(errno)")
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            Darwin.close(fd)
            throw SafariumError.encode("UDS path exceeds 104B sun_path limit: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in
            bytes.withUnsafeBytes { src in dst.copyBytes(from: src) }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
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

    // MARK: - Commands

    public func ping() async throws -> Int32 {
        let resp = try await sendCommand(["cmd": "ping"])
        guard let pid = (resp["pid"] as? NSNumber)?.int32Value else {
            throw SafariumError.encode("ping response missing pid")
        }
        return pid
    }

    public func loadBlend(
        url: URL,
        engine: PrismBlenderEngine = .eevee,
        width: Int? = nil,
        height: Int? = nil,
        samples: Int = 16,
        filmTransparent: Bool? = nil
    ) async throws -> PrismLoadedBlendInfo {
        try SafeFilePublisher.assertRegularReadableFile(url)
        try await start()
        var req: [String: Any] = [
            "cmd": "load_blend",
            "path": url.path,
            "engine": engine.rawValue,
            "samples": max(1, samples),
        ]
        if let width { req["width"] = width }
        if let height { req["height"] = height }
        if let filmTransparent { req["film_transparent"] = filmTransparent }

        let resp = try await sendCommand(req)
        guard let w = (resp["width"] as? NSNumber)?.intValue,
              let h = (resp["height"] as? NSNumber)?.intValue,
              let fps = (resp["fps"] as? NSNumber)?.doubleValue,
              let fs = (resp["frame_start"] as? NSNumber)?.intValue,
              let fe = (resp["frame_end"] as? NSNumber)?.intValue,
              let eng = resp["engine"] as? String else {
            throw SafariumError.encode("invalid load_blend response")
        }
        return PrismLoadedBlendInfo(
            width: w,
            height: h,
            fps: fps,
            frameStart: fs,
            frameEnd: fe,
            engine: eng,
            loadMs: (resp["load_ms"] as? NSNumber)?.doubleValue ?? 0,
            ruMaxRSSBytes: (resp["ru_maxrss_bytes"] as? NSNumber)?.int64Value ?? 0
        )
    }

    public func exportGLBAndIR(
        glbURL: URL,
        irURL: URL? = nil,
        frame: Int? = nil,
        exportAnimations: Bool = true,
        width: Int? = nil,
        height: Int? = nil,
        overwrite: Bool = false
    ) async throws -> PrismSceneIR {
        let glbStage = try APFSAutoStage.makeSession(for: glbURL, overwrite: overwrite)
        defer { glbStage.cleanup() }
        let irStage = try irURL.map { try APFSAutoStage.makeSession(for: $0, overwrite: overwrite) }
        defer { irStage?.cleanup() }

        let stagedGLB = glbStage.fileURL("scene.glb")
        let stagedIR = irStage?.fileURL("scene-ir.json")

        var req: [String: Any] = [
            "cmd": "export_glb_and_ir",
            "glb_path": stagedGLB.path,
            "export_animations": exportAnimations,
        ]
        if let stagedIR { req["ir_path"] = stagedIR.path }
        if let frame { req["frame"] = frame }
        if let width { req["width"] = width }
        if let height { req["height"] = height }

        let resp = try await sendCommand(req)
        guard let irObj = resp["ir"] as? [String: Any] else {
            throw SafariumError.encode("export_glb_and_ir response missing 'ir'")
        }
        let irData = try JSONSerialization.data(withJSONObject: irObj, options: [])
        let ir = try JSONDecoder().decode(PrismSceneIR.self, from: irData)

        try glbStage.commit(stagedFile: stagedGLB, to: glbURL, overwrite: overwrite)
        if let irURL, let stagedIR, let irStage {
            // Rewrite glbFilePath to final committed glbURL path before publishing IR JSON
            var finalIR = ir
            finalIR.glbFilePath = glbURL.path
            try finalIR.save(to: stagedIR, overwrite: true)
            try irStage.commit(stagedFile: stagedIR, to: irURL, overwrite: overwrite)
            return finalIR
        }
        return ir
    }

    public func applyDelta(_ delta: PrismBlenderDelta) async throws {
        let data = try JSONEncoder().encode(delta)
        let dict = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        _ = try await sendCommand(["cmd": "apply_ir_delta", "delta": dict])
    }

    public func renderFrameToSHM(
        frame: Int,
        method: PrismSHMMethod = .bmpMmap,
        delta: PrismBlenderDelta? = nil,
        width: Int? = nil,
        height: Int? = nil,
        filmTransparent: Bool? = nil,
        samples: Int? = nil,
        into reusablePB: CVPixelBuffer? = nil
    ) async throws -> (info: PrismSHMFrameInfo, pixelBuffer: CVPixelBuffer) {
        var req: [String: Any] = [
            "cmd": "render_frame_shm",
            "frame": frame,
            "method": method.rawValue,
        ]
        if let width { req["width"] = width }
        if let height { req["height"] = height }
        if let filmTransparent { req["film_transparent"] = filmTransparent }
        if let samples { req["samples"] = samples }
        if let delta {
            let dData = try JSONEncoder().encode(delta)
            req["delta"] = try JSONSerialization.jsonObject(with: dData)
        }

        let resp = try await sendCommand(req)
        guard let w = (resp["width"] as? NSNumber)?.intValue,
              let h = (resp["height"] as? NSNumber)?.intValue,
              let byteCount = (resp["byte_count"] as? NSNumber)?.intValue,
              let sha = resp["sha256_prefix"] as? String else {
            throw SafariumError.encode("invalid render_frame_shm response")
        }

        let pb: CVPixelBuffer
        if let reusablePB,
           CVPixelBufferGetWidth(reusablePB) == w,
           CVPixelBufferGetHeight(reusablePB) == h,
           CVPixelBufferGetPixelFormatType(reusablePB) == kCVPixelFormatType_32BGRA {
            pb = reusablePB
        } else {
            pb = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: w, height: h, pixelFormat: .bgra)
        }

        try copySHMToPixelBuffer(width: w, height: h, byteCount: byteCount, into: pb)

        let info = PrismSHMFrameInfo(
            frame: (resp["frame"] as? NSNumber)?.intValue ?? frame,
            method: (resp["method"] as? String) ?? method.rawValue,
            width: w,
            height: h,
            byteCount: byteCount,
            sha256Prefix: sha,
            meanRGB: (resp["mean_rgb"] as? NSNumber)?.doubleValue ?? 0,
            transparentPixels: (resp["transparent_pixels"] as? NSNumber)?.intValue ?? 0,
            renderMs: (resp["render_ms"] as? NSNumber)?.doubleValue ?? 0,
            extractMs: (resp["extract_ms"] as? NSNumber)?.doubleValue ?? 0,
            totalMs: (resp["total_ms"] as? NSNumber)?.doubleValue ?? 0,
            ruMaxRSSBytes: (resp["ru_maxrss_bytes"] as? NSNumber)?.int64Value ?? 0
        )
        return (info, pb)
    }

    private func copySHMToPixelBuffer(width w: Int, height h: Int, byteCount: Int, into pb: CVPixelBuffer) throws {
        guard w > 0, h > 0 else {
            throw SafariumError.encode("invalid SHM frame dimensions: \(w)x\(h)")
        }
        let (rowBytes, ov1) = w.multipliedReportingOverflow(by: 4)
        let (expectedBytes, ov2) = rowBytes.multipliedReportingOverflow(by: h)
        guard !ov1, !ov2, byteCount == expectedBytes else {
            throw SafariumError.encode("SHM byteCount \(byteCount) != \(w)x\(h)x4")
        }
        try lock.withLock {
            if shmPtr == nil || shmSize != byteCount || shmWidth != w || shmHeight != h {
                if let old = shmPtr, shmSize > 0 {
                    munmap(old, shmSize)
                }
                shmPtr = nil
                shmSize = 0
                shmWidth = 0
                shmHeight = 0
                guard let path = shmPath else {
                    throw SafariumError.invalidState("SHM path unavailable")
                }
                let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else {
                    let err = errno
                    throw SafariumError.encode("open SHM \(path) failed: \(String(cString: strerror(err)))")
                }
                defer { _ = Darwin.close(fd) }
                var st = stat()
                guard fstat(fd, &st) == 0,
                      (st.st_mode & S_IFMT) == S_IFREG,
                      st.st_uid == getuid(),
                      st.st_size >= off_t(byteCount) else {
                    throw SafariumError.invalidState("SHM file validation failed at \(path)")
                }
                let mapped = mmap(nil, byteCount, PROT_READ, MAP_SHARED, fd, 0)
                guard mapped != MAP_FAILED, let mapped else {
                    let err = errno
                    throw SafariumError.encode("mmap(SHM) failed: \(String(cString: strerror(err)))")
                }
                shmPtr = mapped
                shmSize = byteCount
                shmWidth = w
                shmHeight = h
            }

            guard let srcPtr = shmPtr else {
                throw SafariumError.invalidState("SHM mapping missing")
            }
            guard CVPixelBufferLockBaseAddress(pb, []) == kCVReturnSuccess else {
                throw SafariumError.encode("CVPixelBufferLockBaseAddress failed")
            }
            defer { _ = CVPixelBufferUnlockBaseAddress(pb, []) }
            guard let dstBase = CVPixelBufferGetBaseAddress(pb) else {
                throw SafariumError.encode("CVPixelBuffer missing baseAddress")
            }
            let dstStride = CVPixelBufferGetBytesPerRow(pb)
            let rowBytes = w * 4
            if dstStride == rowBytes {
                memcpy(dstBase, srcPtr, byteCount)
            } else {
                for y in 0..<h {
                    memcpy(dstBase.advanced(by: y * dstStride), srcPtr.advanced(by: y * rowBytes), rowBytes)
                }
            }
        }
    }

    private func sendCommand(_ payload: [String: Any]) async throws -> [String: Any] {
        try await Task.detached(priority: .userInitiated) { [self] in
            try sendCommandSync(payload)
        }.value
    }

    private func sendCommandSync(_ payload: [String: Any]) throws -> [String: Any] {
        var jsonData = try JSONSerialization.data(withJSONObject: payload, options: [])
        jsonData.append(0x0A)

        let fd: Int32 = try lock.withLock {
            guard socketFD >= 0 else {
                throw SafariumError.invalidState("Blender warm bridge not started")
            }
            return socketFD
        }

        try jsonData.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    throw SafariumError.encode("Blender UDS write failed: \(String(cString: strerror(errno)))")
                }
                sent += n
            }
        }

        let lineData = try lock.withLock { () -> Data in
            while true {
                if let nl = readBuffer.firstIndex(of: 0x0A) {
                    let line = Data(readBuffer[..<nl])
                    readBuffer.removeSubrange(...nl)
                    return line
                }
                var chunk = [UInt8](repeating: 0, count: 8192)
                let n = Darwin.read(fd, &chunk, chunk.count)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    throw SafariumError.encode("Blender UDS closed unexpectedly")
                }
                readBuffer.append(contentsOf: chunk[0..<n])
            }
        }

        guard let resp = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            throw SafariumError.encode("Blender UDS invalid JSON reply")
        }
        if (resp["ok"] as? Bool) != true {
            let errStr = resp["error"] as? String ?? "unknown Blender worker error"
            throw SafariumError.encode("Blender worker error: \(errStr)")
        }
        return resp
    }

    public func shutdown() async {
        await Task.detached(priority: .userInitiated) { [self] in
            let canSend = lock.withLock { socketFD >= 0 && process?.isRunning == true }
            if canSend {
                _ = try? sendCommandSync(["cmd": "shutdown"])
            }
            shutdownSync()
        }.value
    }

    public func shutdownSync() {
        let (proc, sock, ptr, sz, rtDir, sockP, shmP) = lock.withLock {
            () -> (Process?, Int32, UnsafeMutableRawPointer?, Int, URL?, String?, String?) in
            if isShutDown && proc_isNil(process) && socketFD < 0 && shmPtr == nil && runtimeDir == nil {
                return (nil, -1, nil, 0, nil, nil, nil)
            }
            isShutDown = true
            let p = process; process = nil
            let s = socketFD; socketFD = -1
            let m = shmPtr; shmPtr = nil
            let ms = shmSize; shmSize = 0
            let d = runtimeDir; runtimeDir = nil
            let sp = socketPath; socketPath = nil
            let mp = shmPath; shmPath = nil
            readBuffer.removeAll(keepingCapacity: false)
            return (p, s, m, ms, d, sp, mp)
        }

        if sock >= 0 { Darwin.close(sock) }
        if let ptr, sz > 0 { munmap(ptr, sz) }

        if let proc, proc.isRunning {
            let pid = proc.processIdentifier
            let deadline = Date().addingTimeInterval(1.5)
            while proc.isRunning && Date() < deadline {
                usleep(20_000)
            }
            if proc.isRunning && pid > 0 {
                Darwin.kill(pid, SIGTERM)
                let termDeadline = Date().addingTimeInterval(0.8)
                while proc.isRunning && Date() < termDeadline {
                    usleep(20_000)
                }
            }
            if proc.isRunning && pid > 0 {
                Darwin.kill(pid, SIGKILL)
                proc.waitUntilExit()
            }
        }

        if let sockP { Darwin.unlink(sockP) }
        if let shmP { Darwin.unlink(shmP) }
        if let rtDir { try? FileManager.default.removeItem(at: rtDir) }
    }

    private func proc_isNil(_ p: Process?) -> Bool { p == nil }
}
