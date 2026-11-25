import AVFoundation
import CoreMedia
import Darwin
import Foundation

// MARK: - Wave 12C: Pipeline Resilience, Atomic Publish, Backpressure & A/V Sync Validation

/// Lifecycle phases of a Safarium media pipeline.
public enum PipelinePhase: String, Codable, Sendable, CaseIterable {
    case idle
    case probing
    case analyzing
    case encoding
    case muxing
    case validating
    case publishing
    case completed
    case cancelled
    case failed

    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed:
            return true
        default:
            return false
        }
    }

    internal var progressionRank: Int {
        switch self {
        case .idle: return 0
        case .probing: return 1
        case .analyzing: return 2
        case .encoding: return 3
        case .muxing: return 4
        case .validating: return 5
        case .publishing: return 6
        case .completed: return 7
        case .cancelled: return 8
        case .failed: return 9
        }
    }
}

/// Recorded state transition for auditability and diagnostics.
public struct PipelinePhaseTransition: Codable, Sendable, Equatable {
    public let from: PipelinePhase
    public let to: PipelinePhase
    public let timestampISO8601: String
    public let note: String?

    public init(from: PipelinePhase, to: PipelinePhase, timestampISO8601: String, note: String? = nil) {
        self.from = from
        self.to = to
        self.timestampISO8601 = timestampISO8601
        self.note = note
    }
}

/// Structured errors raised by pipeline state, atomic publish, and preflight guards.
public enum PipelineResilienceError: Error, CustomStringConvertible, Equatable, Sendable {
    case invalidTransition(from: PipelinePhase, to: PipelinePhase)
    case cancelled(reason: String)
    case destinationAlreadyExists(path: String)
    case emptyOutput(path: String)
    case insufficientDiskSpace(path: String, availableBytes: UInt64, requiredBytes: UInt64)
    case publishFailed(String)

    public var description: String {
        switch self {
        case .invalidTransition(let from, let to):
            return "Invalid pipeline phase transition: \(from.rawValue) -> \(to.rawValue)"
        case .cancelled(let reason):
            return "Pipeline cancelled: \(reason)"
        case .destinationAlreadyExists(let path):
            return "Refusing to overwrite existing output at '\(path)' (overwrite=false)"
        case .emptyOutput(let path):
            return "Refusing to publish empty or missing staged output at '\(path)'"
        case .insufficientDiskSpace(let path, let avail, let req):
            return "Insufficient disk space at '\(path)': available \(avail) bytes < required \(req) bytes"
        case .publishFailed(let msg):
            return "Atomic publish failed: \(msg)"
        }
    }
}

// MARK: - PipelineStateMachine

/// Thread-safe pipeline state machine with cancellation token and LIFO cleanup handler stack.
/// Guarantees zero leaked VideoToolbox sessions or staged temp files on cancel or failure.
public final class PipelineStateMachine: @unchecked Sendable {
    private let lock = NSLock()
    private var _phase: PipelinePhase
    private var _isCancelled: Bool = false
    private var _cancellationReason: String?
    private var _failureMessage: String?
    private var _history: [PipelinePhaseTransition] = []
    private var cleanupStack: [@Sendable () -> Void] = []

    public init(initialPhase: PipelinePhase = .idle) {
        self._phase = initialPhase
    }

    public var phase: PipelinePhase {
        lock.lock()
        defer { lock.unlock() }
        return _phase
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled || _phase == .cancelled
    }

    public var cancellationReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return _cancellationReason
    }

    public var failureMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return _failureMessage
    }

    public var history: [PipelinePhaseTransition] {
        lock.lock()
        defer { lock.unlock() }
        return _history
    }

    /// Registers a cleanup handler executed in strict LIFO order if the pipeline is cancelled or fails.
    /// If the pipeline is already cancelled or failed, the handler runs immediately.
    public func registerCleanup(_ handler: @escaping @Sendable () -> Void) {
        var shouldRunImmediately = false
        lock.lock()
        if _isCancelled || _phase == .cancelled || _phase == .failed {
            shouldRunImmediately = true
        } else if _phase != .completed {
            cleanupStack.append(handler)
        }
        lock.unlock()

        if shouldRunImmediately {
            handler()
        }
    }

    /// Transitions the state machine forward to `next`, validating terminal & ordering invariants.
    public func transition(to next: PipelinePhase, note: String? = nil) throws {
        var handlersToRun: [@Sendable () -> Void] = []

        lock.lock()
        if _isCancelled || _phase == .cancelled {
            let reason = _cancellationReason ?? "Cancelled"
            lock.unlock()
            throw PipelineResilienceError.cancelled(reason: reason)
        }

        if _phase.isTerminal {
            let current = _phase
            lock.unlock()
            throw PipelineResilienceError.invalidTransition(from: current, to: next)
        }

        if next == .cancelled {
            let from = _phase
            _isCancelled = true
            _cancellationReason = note ?? "Cancelled"
            _phase = .cancelled
            _history.append(makeTransition(from: from, to: .cancelled, note: _cancellationReason))
            handlersToRun = drainCleanupsLocked()
            lock.unlock()
            runLIFO(handlersToRun)
            return
        }

        if next == .failed {
            let from = _phase
            _failureMessage = note ?? "Failed"
            _phase = .failed
            _history.append(makeTransition(from: from, to: .failed, note: _failureMessage))
            handlersToRun = drainCleanupsLocked()
            lock.unlock()
            runLIFO(handlersToRun)
            return
        }

        guard next.progressionRank > _phase.progressionRank else {
            let current = _phase
            lock.unlock()
            throw PipelineResilienceError.invalidTransition(from: current, to: next)
        }

        let from = _phase
        _phase = next
        _history.append(makeTransition(from: from, to: next, note: note))
        if next == .completed {
            cleanupStack.removeAll()
        }
        lock.unlock()
    }

    /// Cancels the pipeline atomically and runs all registered cleanup handlers in LIFO order.
    public func cancel(reason: String = "Cancelled by caller") {
        var handlersToRun: [@Sendable () -> Void] = []

        lock.lock()
        if _phase == .completed {
            lock.unlock()
            return
        }
        if !_isCancelled {
            _isCancelled = true
            _cancellationReason = reason
            if !_phase.isTerminal {
                let from = _phase
                _phase = .cancelled
                _history.append(makeTransition(from: from, to: .cancelled, note: reason))
            }
        }
        handlersToRun = drainCleanupsLocked()
        lock.unlock()

        runLIFO(handlersToRun)
    }

    /// Marks the pipeline failed and runs all registered cleanup handlers in LIFO order.
    public func fail(reason: String) {
        var handlersToRun: [@Sendable () -> Void] = []

        lock.lock()
        if _phase.isTerminal {
            lock.unlock()
            return
        }
        let from = _phase
        _failureMessage = reason
        _phase = .failed
        _history.append(makeTransition(from: from, to: .failed, note: reason))
        handlersToRun = drainCleanupsLocked()
        lock.unlock()

        runLIFO(handlersToRun)
    }

    /// Completes the pipeline cleanly, disarming cancel/failure cleanup handlers.
    public func complete(note: String? = nil) throws {
        try transition(to: .completed, note: note)
    }

    /// Throws `PipelineResilienceError.cancelled` if cancellation has been triggered.
    public func checkCancelled() throws {
        lock.lock()
        let cancelled = _isCancelled || _phase == .cancelled
        let reason = _cancellationReason ?? "Cancelled"
        lock.unlock()
        if cancelled {
            throw PipelineResilienceError.cancelled(reason: reason)
        }
    }

    private func drainCleanupsLocked() -> [@Sendable () -> Void] {
        let copy = cleanupStack
        cleanupStack.removeAll()
        return copy
    }

    private func runLIFO(_ handlers: [@Sendable () -> Void]) {
        for handler in handlers.reversed() {
            handler()
        }
    }

    private func makeTransition(from: PipelinePhase, to: PipelinePhase, note: String?) -> PipelinePhaseTransition {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return PipelinePhaseTransition(
            from: from,
            to: to,
            timestampISO8601: formatter.string(from: Date()),
            note: note
        )
    }
}

// MARK: - AtomicOutputPublisher

/// Stages media writes into a unique sibling temp file and atomically promotes them on success.
/// Never corrupts or overwrites an existing destination on error, cancel, or `overwrite == false`.
public struct AtomicOutputPublisher: Sendable {
    public struct StagingHandle: Sendable {
        public let tempURL: URL
        public let destinationURL: URL
        public let overwrite: Bool
    }

    public let destinationURL: URL
    public let overwrite: Bool
    public let minimumRequiredDiskBytes: UInt64?

    public init(
        destinationURL: URL,
        overwrite: Bool = false,
        minimumRequiredDiskBytes: UInt64? = nil
    ) {
        self.destinationURL = destinationURL
        self.overwrite = overwrite
        self.minimumRequiredDiskBytes = minimumRequiredDiskBytes
    }

    /// Returns available volume bytes for the nearest existing ancestor directory of `url`.
    public static func availableDiskSpaceBytes(at url: URL) throws -> UInt64 {
        let fm = FileManager.default
        var probe = url.standardizedFileURL
        while !fm.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path {
                break
            }
            probe = parent
        }

        if let values = try? probe.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ]) {
            if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
                return UInt64(important)
            }
            if let regular = values.volumeAvailableCapacity, regular > 0 {
                return UInt64(regular)
            }
        }

        let attrs = try fm.attributesOfFileSystem(forPath: probe.path)
        if let freeSize = attrs[.systemFreeSize] as? NSNumber {
            return freeSize.uint64Value
        }
        throw PipelineResilienceError.publishFailed("Unable to query available disk space at '\(probe.path)'")
    }

    /// Preflights disk capacity at `url`, throwing `insufficientDiskSpace` if below `requiredBytes`.
    @discardableResult
    public static func checkAvailableDiskSpace(at url: URL, requiredBytes: UInt64) throws -> UInt64 {
        let available = try availableDiskSpaceBytes(at: url)
        if available < requiredBytes {
            throw PipelineResilienceError.insufficientDiskSpace(
                path: url.path,
                availableBytes: available,
                requiredBytes: requiredBytes
            )
        }
        return available
    }

    /// Prepares a unique sibling temp path (`.safarium-tmp-<uuid>-<name>`) and registers cancel/fail cleanup.
    public func prepareStaging(stateMachine: PipelineStateMachine? = nil) throws -> StagingHandle {
        try stateMachine?.checkCancelled()

        let fm = FileManager.default
        if !overwrite && fm.fileExists(atPath: destinationURL.path) {
            throw PipelineResilienceError.destinationAlreadyExists(path: destinationURL.path)
        }

        if let required = minimumRequiredDiskBytes {
            _ = try Self.checkAvailableDiskSpace(at: destinationURL, requiredBytes: required)
        }

        let parentDir = destinationURL.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let tempName = ".safarium-tmp-\(UUID().uuidString)-\(destinationURL.lastPathComponent)"
        let tempURL = parentDir.appendingPathComponent(tempName, isDirectory: false)

        stateMachine?.registerCleanup {
            try? FileManager.default.removeItem(at: tempURL)
        }

        return StagingHandle(
            tempURL: tempURL,
            destinationURL: destinationURL,
            overwrite: overwrite
        )
    }

    /// Validates non-empty staged output and atomically publishes `handle.tempURL` to `handle.destinationURL`.
    @discardableResult
    public func commit(
        _ handle: StagingHandle,
        stateMachine: PipelineStateMachine? = nil
    ) throws -> URL {
        let fm = FileManager.default
        do {
            try stateMachine?.checkCancelled()

            guard fm.fileExists(atPath: handle.tempURL.path) else {
                throw PipelineResilienceError.emptyOutput(path: handle.tempURL.path)
            }
            let attrs = try fm.attributesOfItem(atPath: handle.tempURL.path)
            let fileSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            guard fileSize > 0 else {
                throw PipelineResilienceError.emptyOutput(path: handle.tempURL.path)
            }

            if !handle.overwrite {
                // Atomic non-clobbering rename via macOS `renamex_np(..., RENAME_EXCL)`.
                let rc = handle.tempURL.path.withCString { src in
                    handle.destinationURL.path.withCString { dst in
                        renamex_np(src, dst, UInt32(RENAME_EXCL))
                    }
                }
                if rc == 0 {
                    return handle.destinationURL
                }
                let err = errno
                if err == EEXIST {
                    throw PipelineResilienceError.destinationAlreadyExists(path: handle.destinationURL.path)
                }
                // Fallback for filesystems that return ENOTSUP/EINVAL for RENAME_EXCL (e.g. ExFAT/SMB).
                if err == ENOTSUP || err == EINVAL {
                    if fm.fileExists(atPath: handle.destinationURL.path) {
                        throw PipelineResilienceError.destinationAlreadyExists(path: handle.destinationURL.path)
                    }
                    try fm.moveItem(at: handle.tempURL, to: handle.destinationURL)
                    return handle.destinationURL
                }
                throw PipelineResilienceError.publishFailed(
                    "renamex_np failed with errno \(err) (\(String(cString: strerror(err))))"
                )
            } else {
                if fm.fileExists(atPath: handle.destinationURL.path) {
                    _ = try fm.replaceItemAt(handle.destinationURL, withItemAt: handle.tempURL)
                    return handle.destinationURL
                } else {
                    let rc = handle.tempURL.path.withCString { src in
                        handle.destinationURL.path.withCString { dst in
                            Darwin.rename(src, dst)
                        }
                    }
                    if rc != 0 {
                        let err = errno
                        throw PipelineResilienceError.publishFailed(
                            "rename(2) failed with errno \(err) (\(String(cString: strerror(err))))"
                        )
                    }
                    return handle.destinationURL
                }
            }
        } catch {
            try? fm.removeItem(at: handle.tempURL)
            throw error
        }
    }

    /// Executes `writeToTemp` against a unique sibling temp file, cleaning up on any failure/cancellation
    /// and atomically promoting on success.
    @discardableResult
    public func publish(
        stateMachine: PipelineStateMachine? = nil,
        writeToTemp: (URL) throws -> Void
    ) throws -> URL {
        let handle = try prepareStaging(stateMachine: stateMachine)
        do {
            try writeToTemp(handle.tempURL)
            return try commit(handle, stateMachine: stateMachine)
        } catch {
            try? FileManager.default.removeItem(at: handle.tempURL)
            throw error
        }
    }

    /// Async variant of `publish(stateMachine:writeToTemp:)`.
    @discardableResult
    public func publishAsync(
        stateMachine: PipelineStateMachine? = nil,
        writeToTemp: (URL) async throws -> Void
    ) async throws -> URL {
        let handle = try prepareStaging(stateMachine: stateMachine)
        do {
            try await writeToTemp(handle.tempURL)
            return try commit(handle, stateMachine: stateMachine)
        } catch {
            try? FileManager.default.removeItem(at: handle.tempURL)
            throw error
        }
    }
}

// MARK: - BoundedFrameQueue

/// Lock + condition-variable bounded FIFO queue providing blocking backpressure,
/// immediate wake-up on cancel/finish, O(1) ring storage, and high-water-mark telemetry.
public final class BoundedFrameQueue<T: Sendable>: @unchecked Sendable {
    public let capacity: Int

    private let condition = NSCondition()
    private var ring: [T?]
    private var head: Int = 0
    private var tail: Int = 0
    private var storedCount: Int = 0
    private var _highWaterMark: Int = 0
    private var _totalEnqueued: Int = 0
    private var _totalDequeued: Int = 0
    private var _finished: Bool = false
    private var _cancelled: Bool = false

    public init(capacity: Int) {
        let cap = max(1, capacity)
        self.capacity = cap
        self.ring = Array(repeating: nil, count: cap)
    }

    public var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return storedCount
    }

    public var highWaterMark: Int {
        condition.lock()
        defer { condition.unlock() }
        return _highWaterMark
    }

    public var totalEnqueued: Int {
        condition.lock()
        defer { condition.unlock() }
        return _totalEnqueued
    }

    public var totalDequeued: Int {
        condition.lock()
        defer { condition.unlock() }
        return _totalDequeued
    }

    public var isFinished: Bool {
        condition.lock()
        defer { condition.unlock() }
        return _finished
    }

    public var isCancelled: Bool {
        condition.lock()
        defer { condition.unlock() }
        return _cancelled
    }

    /// Enqueues an item, blocking when at capacity until space opens, `finish()`, or `cancel()`.
    /// Returns `true` if enqueued, or `false` if the queue was finished or cancelled.
    @discardableResult
    public func enqueue(_ item: T) -> Bool {
        condition.lock()
        while storedCount >= capacity && !_cancelled && !_finished {
            condition.wait()
        }
        if _cancelled || _finished {
            condition.unlock()
            return false
        }

        ring[tail] = item
        tail = (tail + 1) % capacity
        storedCount += 1
        _totalEnqueued += 1
        if storedCount > _highWaterMark {
            _highWaterMark = storedCount
        }
        condition.signal()
        condition.unlock()
        return true
    }

    /// Dequeues the oldest item in FIFO order, blocking while empty until an item arrives,
    /// `finish()` drains the queue, or `cancel()` aborts immediately.
    public func dequeue() -> T? {
        condition.lock()
        while storedCount == 0 && !_cancelled && !_finished {
            condition.wait()
        }
        if _cancelled {
            condition.unlock()
            return nil
        }
        if storedCount == 0 && _finished {
            condition.unlock()
            return nil
        }

        let item = ring[head]
        ring[head] = nil
        head = (head + 1) % capacity
        storedCount -= 1
        _totalDequeued += 1
        condition.signal()
        condition.unlock()
        return item
    }

    /// Signals end-of-stream: rejects future enqueues and allows consumers to drain remaining items then receive `nil`.
    public func finish() {
        condition.lock()
        _finished = true
        condition.broadcast()
        condition.unlock()
    }

    /// Immediately cancels the queue, drops buffered items to release backpressure/pool leases, and unblocks all waiters.
    public func cancel() {
        condition.lock()
        _cancelled = true
        for idx in 0..<capacity {
            ring[idx] = nil
        }
        head = 0
        tail = 0
        storedCount = 0
        condition.broadcast()
        condition.unlock()
    }
}

// MARK: - AudioSyncValidator

/// A single timestamp spacing or monotonicity anomaly detected in a video PTS stream.
public struct VFRAnomaly: Codable, Sendable, Equatable {
    public let frameIndex: Int
    public let ptsSeconds: Double
    public let deltaMs: Double
    public let expectedDeltaMs: Double
    public let kind: String

    public init(
        frameIndex: Int,
        ptsSeconds: Double,
        deltaMs: Double,
        expectedDeltaMs: Double,
        kind: String
    ) {
        self.frameIndex = frameIndex
        self.ptsSeconds = ptsSeconds
        self.deltaMs = deltaMs
        self.expectedDeltaMs = expectedDeltaMs
        self.kind = kind
    }
}

/// Complete A/V synchronization and timestamp regularity validation report.
public struct AudioSyncReport: Codable, Sendable, Equatable {
    public let videoStartSeconds: Double
    public let videoDurationSeconds: Double
    public let audioStartSeconds: Double
    public let audioDurationSeconds: Double
    public let audioPrimingSeconds: Double
    public let audioTrimmedDurationSeconds: Double
    public let startDriftMs: Double
    public let durationDriftMs: Double
    public let maxAbsDriftMs: Double
    public let thresholdMs: Double
    public let withinTolerance: Bool
    public let vfrAnomalies: [VFRAnomaly]
    public let isPassed: Bool

    public init(
        videoStartSeconds: Double,
        videoDurationSeconds: Double,
        audioStartSeconds: Double,
        audioDurationSeconds: Double,
        audioPrimingSeconds: Double,
        audioTrimmedDurationSeconds: Double,
        startDriftMs: Double,
        durationDriftMs: Double,
        maxAbsDriftMs: Double,
        thresholdMs: Double,
        withinTolerance: Bool,
        vfrAnomalies: [VFRAnomaly],
        isPassed: Bool
    ) {
        self.videoStartSeconds = videoStartSeconds
        self.videoDurationSeconds = videoDurationSeconds
        self.audioStartSeconds = audioStartSeconds
        self.audioDurationSeconds = audioDurationSeconds
        self.audioPrimingSeconds = audioPrimingSeconds
        self.audioTrimmedDurationSeconds = audioTrimmedDurationSeconds
        self.startDriftMs = startDriftMs
        self.durationDriftMs = durationDriftMs
        self.maxAbsDriftMs = maxAbsDriftMs
        self.thresholdMs = thresholdMs
        self.withinTolerance = withinTolerance
        self.vfrAnomalies = vfrAnomalies
        self.isPassed = isPassed
    }
}

/// Validates exact A/V sync drift (sub-1-audio-frame tolerance, e.g. < 22 ms at 48 kHz AAC)
/// accounting for AAC priming/remainder trimming and VFR timestamp anomalies.
public struct AudioSyncValidator: Sendable {
    public let sampleRate: Double
    public let samplesPerAudioFrame: Int
    public let maxDriftMs: Double
    public let vfrJitterRatioThreshold: Double

    public init(
        sampleRate: Double = 48_000.0,
        samplesPerAudioFrame: Int = 1024,
        maxDriftMs: Double? = nil,
        vfrJitterRatioThreshold: Double = 0.25
    ) {
        let validSR = max(1.0, sampleRate)
        let validSPF = max(1, samplesPerAudioFrame)
        self.sampleRate = validSR
        self.samplesPerAudioFrame = validSPF
        // Default: strictly < 1 audio frame (~21.33 ms for 1024 samples @ 48 kHz AAC).
        self.maxDriftMs = maxDriftMs ?? ((Double(validSPF) / validSR) * 1000.0)
        self.vfrJitterRatioThreshold = max(0.01, vfrJitterRatioThreshold)
    }

    /// Validates alignment between video timing, audio priming/trimmed duration, and optional per-frame video PTS values.
    public func validate(
        videoStart: CMTime,
        videoDuration: CMTime,
        audioStart: CMTime,
        audioDuration: CMTime,
        audioPrimingSamples: Int = 0,
        audioRemainderSamples: Int = 0,
        videoFrameTimestamps: [CMTime] = [],
        nominalFPS: Double? = nil
    ) -> AudioSyncReport {
        let vStart = videoStart.isNumeric ? videoStart.seconds : 0.0
        let vDur = videoDuration.isNumeric ? max(0.0, videoDuration.seconds) : 0.0
        let aStart = audioStart.isNumeric ? audioStart.seconds : 0.0
        let aDur = audioDuration.isNumeric ? max(0.0, audioDuration.seconds) : 0.0

        let primingSec = Double(max(0, audioPrimingSamples)) / sampleRate
        let remainderSec = Double(max(0, audioRemainderSamples)) / sampleRate
        let trimmedAudioDur = max(0.0, aDur - primingSec - remainderSec)

        let startDriftMs = (aStart - vStart) * 1000.0
        let durationDriftMs = (trimmedAudioDur - vDur) * 1000.0
        let maxAbsDriftMs = max(abs(startDriftMs), abs(durationDriftMs))

        let anomalies = detectVFRAnomalies(timestamps: videoFrameTimestamps, nominalFPS: nominalFPS)
        let withinTolerance = maxAbsDriftMs <= maxDriftMs
        let isPassed = withinTolerance && anomalies.isEmpty

        return AudioSyncReport(
            videoStartSeconds: vStart,
            videoDurationSeconds: vDur,
            audioStartSeconds: aStart,
            audioDurationSeconds: aDur,
            audioPrimingSeconds: primingSec,
            audioTrimmedDurationSeconds: trimmedAudioDur,
            startDriftMs: startDriftMs,
            durationDriftMs: durationDriftMs,
            maxAbsDriftMs: maxAbsDriftMs,
            thresholdMs: maxDriftMs,
            withinTolerance: withinTolerance,
            vfrAnomalies: anomalies,
            isPassed: isPassed
        )
    }

    /// Detects non-monotonic PTS, duplicate PTS, large frame gaps, and VFR jitter anomalies.
    public func detectVFRAnomalies(
        timestamps: [CMTime],
        nominalFPS: Double? = nil
    ) -> [VFRAnomaly] {
        guard timestamps.count >= 2 else { return [] }

        let seconds = timestamps.map { $0.isNumeric ? $0.seconds : 0.0 }
        var positiveDeltasMs: [Double] = []
        positiveDeltasMs.reserveCapacity(seconds.count - 1)

        for i in 1..<seconds.count {
            let deltaMs = (seconds[i] - seconds[i - 1]) * 1000.0
            if deltaMs > 0 {
                positiveDeltasMs.append(deltaMs)
            }
        }

        let expectedDeltaMs: Double
        if let fps = nominalFPS, fps > 0 {
            expectedDeltaMs = 1000.0 / fps
        } else if !positiveDeltasMs.isEmpty {
            let sorted = positiveDeltasMs.sorted()
            expectedDeltaMs = sorted[sorted.count / 2]
        } else {
            expectedDeltaMs = 1000.0 / 30.0
        }

        var anomalies: [VFRAnomaly] = []
        let jitterLimitMs = expectedDeltaMs * vfrJitterRatioThreshold

        for i in 1..<seconds.count {
            let deltaMs = (seconds[i] - seconds[i - 1]) * 1000.0
            if deltaMs < 0 {
                anomalies.append(
                    VFRAnomaly(
                        frameIndex: i,
                        ptsSeconds: seconds[i],
                        deltaMs: deltaMs,
                        expectedDeltaMs: expectedDeltaMs,
                        kind: "non_monotonic"
                    )
                )
            } else if deltaMs == 0 {
                anomalies.append(
                    VFRAnomaly(
                        frameIndex: i,
                        ptsSeconds: seconds[i],
                        deltaMs: deltaMs,
                        expectedDeltaMs: expectedDeltaMs,
                        kind: "duplicate_pts"
                    )
                )
            } else if deltaMs > expectedDeltaMs * 2.0 {
                anomalies.append(
                    VFRAnomaly(
                        frameIndex: i,
                        ptsSeconds: seconds[i],
                        deltaMs: deltaMs,
                        expectedDeltaMs: expectedDeltaMs,
                        kind: "large_gap"
                    )
                )
            } else if abs(deltaMs - expectedDeltaMs) > jitterLimitMs {
                anomalies.append(
                    VFRAnomaly(
                        frameIndex: i,
                        ptsSeconds: seconds[i],
                        deltaMs: deltaMs,
                        expectedDeltaMs: expectedDeltaMs,
                        kind: "vfr_jitter"
                    )
                )
            }
        }

        return anomalies
    }

    /// Inspects a media file natively with AVFoundation to measure real A/V sync alignment.
    public func validateAsset(at url: URL) async throws -> AudioSyncReport {
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        guard let vTrack = videoTracks.first else {
            throw SafariumError.invalidState("No video track found at '\(url.path)'")
        }
        guard let aTrack = audioTracks.first else {
            throw SafariumError.invalidState("No audio track found at '\(url.path)'")
        }

        let vRange = try await vTrack.load(.timeRange)
        let aRange = try await aTrack.load(.timeRange)
        let fps = Double(try await vTrack.load(.nominalFrameRate))

        return validate(
            videoStart: vRange.start,
            videoDuration: vRange.duration,
            audioStart: aRange.start,
            audioDuration: aRange.duration,
            nominalFPS: fps > 0 ? fps : nil
        )
    }
}
