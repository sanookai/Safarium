import AVFoundation
import CoreMedia
import Darwin
import Foundation
import SafariumCore

public struct ForgeAdaptivePoolConfig: Codable, Sendable, Equatable {
    public var requestedWorkers: Int
    public var budgetMB: Double
    public var maxWorkersCeiling: Int
    public var totalFrames: Int
    public var fps: Int
    public var chunkFrames: Int

    public init(
        requestedWorkers: Int = 1,
        budgetMB: Double = 700.0,
        maxWorkersCeiling: Int = 4,
        totalFrames: Int,
        fps: Int = 30,
        chunkFrames: Int = 30
    ) {
        self.requestedWorkers = requestedWorkers
        self.budgetMB = budgetMB
        self.maxWorkersCeiling = maxWorkersCeiling
        self.totalFrames = totalFrames
        self.fps = fps
        self.chunkFrames = chunkFrames
    }
}

public struct ForgeAdaptivePoolTelemetry: Codable, Sendable, Equatable {
    public let peakFootprintMB: Double
    public let peakWorkersUsed: Int
    public let scaleDownEvents: Int
    public let thermalTrips: Int
    public let chunksCompleted: Int
    public let wallMs: Double
}

public struct ForgeFrameChunkRange: Codable, Sendable, Equatable {
    public let index: Int
    public let startFrame: Int
    public let frameCount: Int
    public let fps: Int
    public let startSeconds: Double
    public let durationSeconds: Double
}

public struct ForgePoolSample: Sendable, Equatable {
    public let footprintMB: Double
    public let thermalState: ProcessInfo.ThermalState

    public init(footprintMB: Double, thermalState: ProcessInfo.ThermalState) {
        self.footprintMB = footprintMB
        self.thermalState = thermalState
    }
}

public struct ForgeAdaptivePoolRunReport: Codable, Sendable {
    public let telemetry: ForgeAdaptivePoolTelemetry
    public let stitchReport: ForgeSegmentStitchReport?
    public let outputPath: String?
    public let chunks: [ForgeFrameChunkRange]
}

/// Opt-in Adaptive Multi-WebKit / Multi-Worker Pool (`requestedWorkers = 1` strictly default).
/// Starts conservatively at 1 worker, scales up only while `ri_phys_footprint < 0.72 * budgetMB`
/// and `thermalState < .serious`, drains back to 1 immediately at `>= 0.85 * budgetMB` or `.serious`/`.critical`,
/// guarantees child process cleanup on completion/throw/cancel, and stitches closed-GOP chunks losslessly.
public final class ForgeAdaptiveWebKitPool: @unchecked Sendable {
    public let config: ForgeAdaptivePoolConfig
    private let telemetrySampler: @Sendable ([pid_t]) -> ForgePoolSample
    private let childLock = NSLock()
    private var trackedChildren: [pid_t: Process] = [:]

    public init(
        config: ForgeAdaptivePoolConfig,
        telemetrySampler: (@Sendable ([pid_t]) -> ForgePoolSample)? = nil
    ) throws {
        guard config.totalFrames > 0 else {
            throw SafariumError.invalidState("ForgeAdaptiveWebKitPool requires totalFrames > 0, got \(config.totalFrames)")
        }
        guard config.fps > 0 else {
            throw SafariumError.invalidState("ForgeAdaptiveWebKitPool requires fps > 0, got \(config.fps)")
        }
        guard config.budgetMB > 0, config.budgetMB.isFinite else {
            throw SafariumError.invalidState("ForgeAdaptiveWebKitPool requires finite budgetMB > 0")
        }
        guard config.maxWorkersCeiling >= 1 else {
            throw SafariumError.invalidState("ForgeAdaptiveWebKitPool requires maxWorkersCeiling >= 1")
        }
        guard config.requestedWorkers >= 1 else {
            throw SafariumError.invalidState("ForgeAdaptiveWebKitPool requires requestedWorkers >= 1")
        }
        guard config.chunkFrames >= 1 else {
            throw SafariumError.invalidState("ForgeAdaptiveWebKitPool requires chunkFrames >= 1")
        }
        self.config = config
        self.telemetrySampler = telemetrySampler ?? { childPIDs in
            Self.liveSample(childPIDs: childPIDs)
        }
    }

    deinit {
        cleanupTrackedChildren()
    }

    private struct ProcessTreeEntry {
        let pid: pid_t
        let ppid: pid_t
        let pgid: pid_t
        let uid: uid_t
        let sid: pid_t
        let isWebKitHelper: Bool
    }

    /// Walks Darwin `proc_listallpids` + `proc_pidinfo(..., PROC_PIDTBSDINFO, ...)` parent->children recursively
    /// from `rootPIDs` and includes matching WebKit XPC helpers belonging to the same UID and process group/session.
    public static func collectProcessTreePIDs(rootPIDs: [pid_t]) -> [pid_t] {
        let validRoots = rootPIDs.filter { $0 > 0 }
        guard !validRoots.isEmpty else { return [] }

        var capacity = max(Int(proc_listallpids(nil, 0)) + 64, 256)
        var rawPIDs: [pid_t] = []
        for _ in 0..<4 {
            var buf = [pid_t](repeating: 0, count: capacity)
            let count = Int(proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.stride)))
            if count <= 0 {
                return Array(Set(validRoots)).sorted()
            }
            if count < capacity {
                rawPIDs = Array(buf.prefix(count))
                break
            }
            capacity *= 2
            rawPIDs = Array(buf.prefix(count))
        }

        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let pathCap = 4096
        var pathBuf = [CChar](repeating: 0, count: pathCap)
        var entriesByPID: [pid_t: ProcessTreeEntry] = [:]
        var childrenByPPID: [pid_t: [pid_t]] = [:]

        for pid in rawPIDs where pid > 0 {
            var bsd = proc_bsdinfo()
            let rc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize)
            guard rc == bsdSize else { continue }
            if bsd.pbi_status == 5 { continue } // SZOMB

            let comm = withUnsafePointer(to: &bsd.pbi_comm) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
            }
            let name = withUnsafePointer(to: &bsd.pbi_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 2 * Int(MAXCOMLEN)) { String(cString: $0) }
            }
            var execPath = ""
            if proc_pidpath(pid, &pathBuf, UInt32(pathCap)) > 0 {
                execPath = String(cString: pathBuf)
            }
            let isWebKit = execPath.contains("com.apple.WebKit")
                || name.contains("com.apple.WebKit")
                || comm.contains("WebKit")

            let entry = ProcessTreeEntry(
                pid: pid,
                ppid: pid_t(bsd.pbi_ppid),
                pgid: pid_t(bsd.pbi_pgid),
                uid: bsd.pbi_uid,
                sid: Darwin.getsid(pid),
                isWebKitHelper: isWebKit
            )
            entriesByPID[pid] = entry
            childrenByPPID[entry.ppid, default: []].append(pid)
        }

        let currentUID = getuid()
        let launchdSID = Darwin.getsid(1)
        var collected = Set<pid_t>()
        var queue: [pid_t] = []
        for root in validRoots {
            if entriesByPID[root] != nil || Darwin.kill(root, 0) == 0 || errno == EPERM {
                if collected.insert(root).inserted {
                    queue.append(root)
                }
            }
        }

        while true {
            var idx = 0
            while idx < queue.count {
                let parent = queue[idx]
                idx += 1
                for child in childrenByPPID[parent] ?? [] {
                    if collected.insert(child).inserted {
                        queue.append(child)
                    }
                }
            }

            var activePGIDs = Set<pid_t>()
            var activeSIDs = Set<pid_t>()
            for pid in collected {
                if let entry = entriesByPID[pid] {
                    if entry.pgid > 1 { activePGIDs.insert(entry.pgid) }
                    if entry.sid > 1 && entry.sid != launchdSID { activeSIDs.insert(entry.sid) }
                } else {
                    let pg = Darwin.getpgid(pid)
                    if pg > 1 { activePGIDs.insert(pg) }
                    let s = Darwin.getsid(pid)
                    if s > 1 && s != launchdSID { activeSIDs.insert(s) }
                }
            }

            var addedXPC = false
            for (pid, entry) in entriesByPID where entry.isWebKitHelper && entry.uid == currentUID && !collected.contains(pid) {
                let pgidMatch = entry.pgid > 1 && activePGIDs.contains(entry.pgid)
                let sidMatch = entry.sid > 1 && entry.sid != launchdSID && activeSIDs.contains(entry.sid)
                if pgidMatch || sidMatch {
                    if collected.insert(pid).inserted {
                        queue.append(pid)
                        addedXPC = true
                    }
                }
            }
            if !addedXPC { break }
        }

        return collected.sorted()
    }

    /// Samples current process + tracked child process-tree & WebKit XPC helper `ri_phys_footprint` in MiB.
    public static func processAndChildrenFootprintMB(childPIDs: [pid_t]) -> Double {
        let myPID = getpid()
        var totalMB = SafariumRuntimeTelemetry.currentFootprintMB()
        let treePIDs = collectProcessTreePIDs(rootPIDs: [myPID] + childPIDs)
        for pid in treePIDs where pid > 0 && pid != myPID {
            var info = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rPtr in
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, rPtr)
                }
            }
            if rc == 0 {
                totalMB += Double(info.ri_phys_footprint) / (1024.0 * 1024.0)
            }
        }
        return totalMB
    }

    public static func liveSample(childPIDs: [pid_t]) -> ForgePoolSample {
        ForgePoolSample(
            footprintMB: processAndChildrenFootprintMB(childPIDs: childPIDs),
            thermalState: ProcessInfo.processInfo.thermalState
        )
    }

    public func trackChildProcess(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        childLock.withLock {
            trackedChildren[pid] = process
        }
    }

    public func untrackChildProcess(_ process: Process) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        childLock.withLock {
            _ = trackedChildren.removeValue(forKey: pid)
        }
    }

    public func activeChildPIDs() -> [pid_t] {
        childLock.withLock {
            trackedChildren.values.filter { $0.isRunning }.map { $0.processIdentifier }
        }
    }

    /// Terminates and reaps all tracked child processes (`SIGTERM` -> brief wait -> `SIGKILL`) so zero orphans remain.
    public func cleanupTrackedChildren() {
        let procs: [Process] = childLock.withLock {
            let values = Array(trackedChildren.values)
            trackedChildren.removeAll()
            return values
        }
        for proc in procs {
            if proc.isRunning {
                proc.terminate()
                let deadline = Date().addingTimeInterval(0.15)
                while proc.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if proc.isRunning {
                    let pid = proc.processIdentifier
                    if pid > 0 {
                        _ = Darwin.kill(pid, SIGKILL)
                    }
                }
            }
            if proc.processIdentifier > 0 {
                proc.waitUntilExit()
            }
        }
    }

    public func buildChunkRanges() -> [ForgeFrameChunkRange] {
        var ranges: [ForgeFrameChunkRange] = []
        var cursor = 0
        var idx = 0
        while cursor < config.totalFrames {
            let count = min(config.chunkFrames, config.totalFrames - cursor)
            ranges.append(ForgeFrameChunkRange(
                index: idx,
                startFrame: cursor,
                frameCount: count,
                fps: config.fps,
                startSeconds: Double(cursor) / Double(config.fps),
                durationSeconds: Double(count) / Double(config.fps)
            ))
            cursor += count
            idx += 1
        }
        return ranges
    }

    private func sampleCurrentTelemetry() -> ForgePoolSample {
        let treePIDs = Self.collectProcessTreePIDs(rootPIDs: [getpid()] + activeChildPIDs())
        return telemetrySampler(treePIDs)
    }

    /// Executes closed-GOP frame chunks with dynamic RAM/thermal scaling and optional lossless stitch into `finalOutputURL`.
    public func runChunks(
        finalOutputURL: URL? = nil,
        stagingDirectory: URL? = nil,
        wavURL: URL? = nil,
        subtitlesURL: URL? = nil,
        subtitleLang: String = "tha",
        overwrite: Bool = false,
        renderChunk: @escaping @Sendable (_ chunk: ForgeFrameChunkRange, _ workerSlot: Int, _ outputURL: URL) async throws -> Void
    ) async throws -> ForgeAdaptivePoolRunReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let chunks = buildChunkRanges()
        let maxAllowed = max(1, min(config.requestedWorkers, config.maxWorkersCeiling))

        let ownStage: Bool
        let stageDir: URL
        if let stagingDirectory {
            ownStage = false
            stageDir = stagingDirectory
            try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
            _ = chmod(stageDir.path, 0o700)
        } else {
            ownStage = true
            let root = ForgeIncrementalCache.defaultCacheRootURL()
                .deletingLastPathComponent()
                .appendingPathComponent("com.safarium.adaptive-pool-stage-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            _ = chmod(root.path, 0o700)
            stageDir = root
        }
        defer {
            cleanupTrackedChildren()
            if ownStage {
                try? FileManager.default.removeItem(at: stageDir)
            }
        }

        var currentTargetWorkers = 1
        var peakWorkersUsed = 0
        var peakFootprintMB = 0.0
        var scaleDownEvents = 0
        var thermalTrips = 0
        var chunksCompleted = 0
        var segmentByChunkIdx = [URL?](repeating: nil, count: chunks.count)

        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: (Int, Int, URL).self) { group in
                var freeSlots = Array((0..<maxAllowed).reversed())
                var inFlight = 0
                var nextIdx = 0
                var hasCompletedChunk = false

                func evaluatePressure(allowScaleUp: Bool) async throws {
                    let sample = sampleCurrentTelemetry()
                    if sample.footprintMB > peakFootprintMB {
                        peakFootprintMB = sample.footprintMB
                    }
                    let thermalTripped = (sample.thermalState == .serious || sample.thermalState == .critical)
                    if thermalTripped {
                        thermalTrips += 1
                    }
                    let highMem = sample.footprintMB >= config.budgetMB * 0.85
                    if highMem || thermalTripped {
                        if currentTargetWorkers > 1 {
                            currentTargetWorkers = 1
                            scaleDownEvents += 1
                        }
                        safariumMemFlush()
                        while inFlight > 0 {
                            if let (doneIdx, doneSlot, doneURL) = try await group.next() {
                                inFlight -= 1
                                freeSlots.append(doneSlot)
                                segmentByChunkIdx[doneIdx] = doneURL
                                chunksCompleted += 1
                                hasCompletedChunk = true
                            }
                        }
                    } else if allowScaleUp,
                              hasCompletedChunk,
                              sample.footprintMB < config.budgetMB * 0.72,
                              currentTargetWorkers < maxAllowed {
                        currentTargetWorkers = min(maxAllowed, currentTargetWorkers + 1)
                    }
                }

                // Initial baseline sample (keeps initial target at 1 worker conservatively).
                try await evaluatePressure(allowScaleUp: false)

                while nextIdx < chunks.count {
                    try Task.checkCancellation()

                    while inFlight < currentTargetWorkers && nextIdx < chunks.count {
                        let chunk = chunks[nextIdx]
                        nextIdx += 1
                        let slot = freeSlots.removeLast()
                        inFlight += 1
                        if inFlight > peakWorkersUsed {
                            peakWorkersUsed = inFlight
                        }
                        let segURL = stageDir.appendingPathComponent(String(format: "chunk_%05d.mp4", chunk.index))
                        group.addTask {
                            try await renderChunk(chunk, slot, segURL)
                            return (chunk.index, slot, segURL)
                        }
                    }

                    if inFlight > 0 {
                        if let (doneIdx, doneSlot, doneURL) = try await group.next() {
                            inFlight -= 1
                            freeSlots.append(doneSlot)
                            segmentByChunkIdx[doneIdx] = doneURL
                            chunksCompleted += 1
                            hasCompletedChunk = true
                            try await evaluatePressure(allowScaleUp: true)
                        }
                    }
                }

                while inFlight > 0 {
                    if let (doneIdx, doneSlot, doneURL) = try await group.next() {
                        inFlight -= 1
                        freeSlots.append(doneSlot)
                        segmentByChunkIdx[doneIdx] = doneURL
                        chunksCompleted += 1
                    }
                }
            }
        } onCancel: {
            cleanupTrackedChildren()
        }

        var orderedSegments: [URL] = []
        orderedSegments.reserveCapacity(chunks.count)
        for (i, u) in segmentByChunkIdx.enumerated() {
            guard let url = u else {
                throw SafariumError.invalidState("missing output segment for chunk \(i)")
            }
            orderedSegments.append(url)
        }

        var stitchReport: ForgeSegmentStitchReport?
        if let finalOutputURL {
            stitchReport = try await ClosedGOPSegmentStitcher.splice(
                segments: orderedSegments,
                wavURL: wavURL,
                subtitlesURL: subtitlesURL,
                subtitleLang: subtitleLang,
                outputURL: finalOutputURL,
                overwrite: overwrite
            )
        }

        let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let telemetry = ForgeAdaptivePoolTelemetry(
            peakFootprintMB: peakFootprintMB,
            peakWorkersUsed: max(1, peakWorkersUsed),
            scaleDownEvents: scaleDownEvents,
            thermalTrips: thermalTrips,
            chunksCompleted: chunksCompleted,
            wallMs: wallMs
        )
        return ForgeAdaptivePoolRunReport(
            telemetry: telemetry,
            stitchReport: stitchReport,
            outputPath: finalOutputURL?.path,
            chunks: chunks
        )
    }

    /// Convenience windowless WebKit (`HostApp.prepare()` `.prohibited`) chunk renderer + lossless closed-GOP stitch.
    @MainActor
    public func renderHTMLAndStitch(
        htmlURL: URL,
        readAccessURL: URL? = nil,
        width: Int,
        height: Int,
        codec: VideoCodec = .h264,
        bitrate: Int = 8_000_000,
        transparent: Bool = false,
        wavURL: URL? = nil,
        subtitlesURL: URL? = nil,
        subtitleLang: String = "tha",
        outputURL: URL,
        overwrite: Bool = false
    ) async throws -> ForgeAdaptivePoolRunReport {
        HostApp.prepare()
        let pageConfig = PageConfig(
            width: width,
            height: height,
            transparent: transparent,
            deterministicClock: true
        )
        return try await runChunks(
            finalOutputURL: outputURL,
            wavURL: wavURL,
            subtitlesURL: subtitlesURL,
            subtitleLang: subtitleLang,
            overwrite: overwrite
        ) { chunk, _, segURL in
            try await Self.renderHTMLChunkWithWebKit(
                htmlURL: htmlURL,
                readAccessURL: readAccessURL,
                pageConfig: pageConfig,
                chunk: chunk,
                codec: codec,
                bitrate: bitrate,
                outputURL: segURL
            )
        }
    }

    @MainActor
    private static func renderHTMLChunkWithWebKit(
        htmlURL: URL,
        readAccessURL: URL?,
        pageConfig: PageConfig,
        chunk: ForgeFrameChunkRange,
        codec: VideoCodec,
        bitrate: Int,
        outputURL: URL
    ) async throws {
        HostApp.prepare()
        let page = try await Page(config: pageConfig)
        defer { page.close() }
        try await page.load(.fileURL(htmlURL, readAccess: readAccessURL ?? htmlURL.deletingLastPathComponent()))
        try await page.waitFor(.readyState)
        try await page.waitFor(.fonts)

        let pxFmt: SinkPixelFormat = codec.hasAlpha ? .bgra : .nv12Left
        let sink = try AVAssetWriterSink(
            url: outputURL,
            width: pageConfig.width,
            height: pageConfig.height,
            fps: chunk.fps,
            codec: codec,
            bitrate: bitrate,
            pixelFormat: pxFmt,
            profile: .lowRamClosedGOP
        )
        for localIdx in 0..<chunk.frameCount {
            let t = Double(chunk.startFrame + localIdx) / Double(chunk.fps)
            try await page.seek(t)
            let snap = try await page.snapshot()
            let pts = CMTime(value: Int64(localIdx), timescale: Int32(chunk.fps))
            try await sink.append(snap, presentationTime: pts)
        }
        try await sink.finish()
        safariumMemFlush()
    }
}
