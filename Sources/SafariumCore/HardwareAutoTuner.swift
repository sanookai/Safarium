import CoreMedia
import CoreVideo
import Darwin
import Foundation
import IOSurface
import VideoToolbox

// MARK: - Wave 14A: Hardware Auto-Tuner & Thermal Hysteresis Scheduler

/// Power and thermal operating budget for video encoding pipelines.
public enum PowerBudget: String, Codable, Sendable, CaseIterable {
    case low
    case balanced
    case max
}

/// Measured throughput and energy-proxy telemetry for a single concurrency level.
public struct ConcurrencyCalibrationPoint: Codable, Sendable, Equatable {
    public let sessions: Int
    public let totalFPS: Double
    public let perStreamFPS: Double
    public let wallMs: Double
    public let cpuTimeMs: Double
    public let estimatedJoulesPerFrame: Double
    public let gainOverPreviousPct: Double

    public init(
        sessions: Int,
        totalFPS: Double,
        perStreamFPS: Double,
        wallMs: Double,
        cpuTimeMs: Double,
        estimatedJoulesPerFrame: Double,
        gainOverPreviousPct: Double
    ) {
        self.sessions = sessions
        self.totalFPS = totalFPS
        self.perStreamFPS = perStreamFPS
        self.wallMs = wallMs
        self.cpuTimeMs = cpuTimeMs
        self.estimatedJoulesPerFrame = estimatedJoulesPerFrame
        self.gainOverPreviousPct = gainOverPreviousPct
    }
}

/// Complete live calibration report recommending optimal concurrent VideoToolbox sessions.
public struct ConcurrencyCalibrationReport: Codable, Sendable, Equatable {
    public let codecFourCC: String
    public let recommendedSessions: Int
    public let points: [ConcurrencyCalibrationPoint]
    public let thermalState: String
    public let stopReason: String

    public init(
        codecFourCC: String,
        recommendedSessions: Int,
        points: [ConcurrencyCalibrationPoint],
        thermalState: String,
        stopReason: String
    ) {
        self.codecFourCC = codecFourCC
        self.recommendedSessions = recommendedSessions
        self.points = points
        self.thermalState = thermalState
        self.stopReason = stopReason
    }
}

/// Process-level CPU/energy proxy measurement recorded during encoding bursts.
///
/// NOTE: `estimatedJoules`, `joulesPerFrame`, and `framesPerSecondPerWatt` are derived from
/// `getrusage(RUSAGE_SELF)` + Darwin `task_info` CPU time and an Apple Silicon watt envelope
/// model. They represent an honest CPU/process energy proxy, NOT a direct hardware power sensor.
public struct EnergySample: Codable, Sendable, Equatable {
    public let wallSeconds: Double
    public let cpuSeconds: Double
    public let framesEncoded: Int
    public let estimatedJoules: Double
    public let joulesPerFrame: Double
    public let framesPerSecondPerWatt: Double
    public let thermalState: String
    public let energyProxyNote: String

    public static let defaultProxyNote =
        "CPU/process energy proxy via getrusage(RUSAGE_SELF) + Darwin task_info CPU time + Apple Silicon watt envelope estimator (not a hardware power sensor)"

    public init(
        wallSeconds: Double,
        cpuSeconds: Double,
        framesEncoded: Int,
        estimatedJoules: Double,
        joulesPerFrame: Double,
        framesPerSecondPerWatt: Double,
        thermalState: String,
        energyProxyNote: String = EnergySample.defaultProxyNote
    ) {
        self.wallSeconds = wallSeconds
        self.cpuSeconds = cpuSeconds
        self.framesEncoded = framesEncoded
        self.estimatedJoules = estimatedJoules
        self.joulesPerFrame = joulesPerFrame
        self.framesPerSecondPerWatt = framesPerSecondPerWatt
        self.thermalState = thermalState
        self.energyProxyNote = energyProxyNote
    }
}

/// Token capturing start wall and process CPU timestamps for energy proxy intervals.
public struct EnergyMeasurementToken: Sendable, Equatable {
    public let startWallSeconds: Double
    public let startCPUSeconds: Double

    public init(startWallSeconds: Double, startCPUSeconds: Double) {
        self.startWallSeconds = startWallSeconds
        self.startCPUSeconds = startCPUSeconds
    }
}

/// Thermal-aware concurrency scheduler with true hysteresis to prevent oscillation under load.
///
/// - Steps concurrency down immediately when `ProcessInfo.ThermalState` enters `.serious` or `.critical`.
/// - Requires `cooldownTicks` consecutive `.nominal`/`.fair` readings before stepping concurrency
///   back up by one slot at a time.
/// - Exposes inter-frame pacing guidance for `.low` power budgets and elevated thermal states.
/// - Records honest CPU/process energy proxy telemetry via `getrusage(RUSAGE_SELF)` and Darwin `task_info`.
public final class ThermalHysteresisScheduler: @unchecked Sendable {
    private let lock = NSLock()

    private var thermalState: ProcessInfo.ThermalState
    private var powerBudget: PowerBudget
    private let cooldownTicks: Int

    /// Active thermal ceiling when throttled; `nil` when unthrottled.
    private var thermalCeiling: Int?
    /// Number of consecutive `.nominal`/`.fair` updates accumulated while throttled.
    private var consecutiveHealthyTicks: Int = 0
    /// Most recently observed calibrated concurrency cap.
    private var lastMaxCalibrated: Int = 1
    /// Recorded process energy proxy samples.
    private var samples: [EnergySample] = []

    /// Base active media-engine watt proxy (W) + per-active-CPU-core watt proxy (W) for Apple Silicon.
    private static let baseActiveWatts: Double = 1.8
    private static let perActiveCoreWatts: Double = 2.6
    private static let minEnvelopeWatts: Double = 0.8
    private static let maxEnvelopeWatts: Double = 45.0

    public init(
        powerBudget: PowerBudget = .balanced,
        cooldownTicks: Int = 3,
        initialThermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) {
        self.powerBudget = powerBudget
        self.cooldownTicks = max(1, cooldownTicks)
        self.thermalState = initialThermalState
    }

    // MARK: - State Accessors & Controls

    public var currentThermalState: ProcessInfo.ThermalState {
        lock.lock()
        defer { lock.unlock() }
        return thermalState
    }

    public var currentPowerBudget: PowerBudget {
        lock.lock()
        defer { lock.unlock() }
        return powerBudget
    }

    public var currentCooldownProgress: Int {
        lock.lock()
        defer { lock.unlock() }
        return consecutiveHealthyTicks
    }

    public var configuredCooldownTicks: Int {
        cooldownTicks
    }

    public var recordedEnergySamples: [EnergySample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    public func setPowerBudget(_ budget: PowerBudget) {
        lock.lock()
        defer { lock.unlock() }
        powerBudget = budget
    }

    /// Reads the live macOS `ProcessInfo.processInfo.thermalState` and advances hysteresis state.
    @discardableResult
    public func pollSystemThermalState(maxCalibrated: Int? = nil) -> ProcessInfo.ThermalState {
        let live = ProcessInfo.processInfo.thermalState
        updateThermalState(live, maxCalibrated: maxCalibrated)
        return live
    }

    /// Feeds a thermal observation into the hysteresis state machine.
    ///
    /// - Immediate step-down on `.serious` and `.critical` (resets cooldown counter).
    /// - On `.nominal` or `.fair`, holds throttled concurrency until `cooldownTicks` consecutive
    ///   healthy readings have been observed, then increments concurrency ceiling by 1.
    public func updateThermalState(
        _ newState: ProcessInfo.ThermalState,
        maxCalibrated: Int? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }

        thermalState = newState
        if let providedMax = maxCalibrated {
            lastMaxCalibrated = max(1, providedMax)
        }

        let cap = budgetCapLocked(for: lastMaxCalibrated)
        switch newState {
        case .critical:
            consecutiveHealthyTicks = 0
            thermalCeiling = 1
        case .serious:
            consecutiveHealthyTicks = 0
            let target = seriousTarget(for: cap)
            if let existing = thermalCeiling {
                thermalCeiling = min(existing, target)
            } else {
                thermalCeiling = target
            }
        case .nominal, .fair:
            guard let existing = thermalCeiling else {
                consecutiveHealthyTicks = 0
                return
            }
            if existing >= cap {
                thermalCeiling = nil
                consecutiveHealthyTicks = 0
                return
            }
            consecutiveHealthyTicks += 1
            if consecutiveHealthyTicks >= cooldownTicks {
                let steppedUp = min(cap, existing + 1)
                consecutiveHealthyTicks = 0
                thermalCeiling = (steppedUp >= cap) ? nil : steppedUp
            }
        @unknown default:
            consecutiveHealthyTicks = 0
            let target = seriousTarget(for: cap)
            thermalCeiling = min(thermalCeiling ?? cap, target)
        }
    }

    /// Returns the recommended concurrent encode session count under current thermal hysteresis
    /// and power budget constraints.
    public func recommendedConcurrency(maxCalibrated: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }

        let safeMax = max(1, maxCalibrated)
        lastMaxCalibrated = safeMax
        let cap = budgetCapLocked(for: safeMax)

        switch thermalState {
        case .critical:
            thermalCeiling = 1
            return 1
        case .serious:
            let target = seriousTarget(for: cap)
            if let existing = thermalCeiling {
                let clamped = min(existing, target)
                thermalCeiling = clamped
                return max(1, clamped)
            } else {
                thermalCeiling = target
                return max(1, target)
            }
        case .nominal, .fair:
            if let ceiling = thermalCeiling {
                return max(1, min(cap, ceiling))
            }
            return max(1, cap)
        @unknown default:
            let target = seriousTarget(for: cap)
            thermalCeiling = min(thermalCeiling ?? cap, target)
            return max(1, thermalCeiling ?? target)
        }
    }

    /// Recommended inter-frame pacing pause in milliseconds for `.low` power budget or elevated thermals.
    public func recommendedInterFramePauseMs() -> Double {
        lock.lock()
        defer { lock.unlock() }

        switch (powerBudget, thermalState) {
        case (.low, .critical):
            return 40.0
        case (.low, .serious):
            return 20.0
        case (.low, .fair):
            return 10.0
        case (.low, .nominal):
            return 8.0
        case (.balanced, .critical):
            return 25.0
        case (.balanced, .serious):
            return 12.0
        case (.balanced, .fair):
            return 2.0
        case (.balanced, .nominal):
            return 0.0
        case (.max, .critical):
            return 15.0
        case (.max, .serious):
            return 6.0
        case (.max, .fair), (.max, .nominal):
            return 0.0
        default:
            return 10.0
        }
    }

    // MARK: - Process CPU Time & Energy Proxy Measurement

    /// Starts an energy-proxy measurement interval using monotonic wall clock + process CPU time.
    public func beginEnergyMeasurement() -> EnergyMeasurementToken {
        EnergyMeasurementToken(
            startWallSeconds: Self.monotonicWallSeconds(),
            startCPUSeconds: Self.currentProcessCPUTimeSeconds()
        )
    }

    /// Completes an energy-proxy interval, stores the sample on the scheduler, and returns it.
    @discardableResult
    public func endEnergyMeasurement(
        token: EnergyMeasurementToken,
        framesEncoded: Int
    ) -> EnergySample {
        let endWall = Self.monotonicWallSeconds()
        let endCPU = Self.currentProcessCPUTimeSeconds()
        let wallDelta = max(1e-6, endWall - token.startWallSeconds)
        let cpuDelta = max(0.0, endCPU - token.startCPUSeconds)
        return recordEnergySample(
            wallSeconds: wallDelta,
            cpuSeconds: cpuDelta,
            framesEncoded: framesEncoded
        )
    }

    /// Executes `work` and records a process CPU/energy proxy `EnergySample`.
    @discardableResult
    public func measureEnergySample(
        framesEncoded: Int,
        work: () throws -> Void
    ) rethrows -> EnergySample {
        let token = beginEnergyMeasurement()
        try work()
        return endEnergyMeasurement(token: token, framesEncoded: framesEncoded)
    }

    /// Computes and records an `EnergySample` from observed wall time, CPU time, and encoded frame count.
    @discardableResult
    public func recordEnergySample(
        wallSeconds: Double,
        cpuSeconds: Double,
        framesEncoded: Int
    ) -> EnergySample {
        let safeWall = max(1e-6, wallSeconds)
        let safeCPU = max(0.0, cpuSeconds)
        let safeFrames = max(0, framesEncoded)

        lock.lock()
        let stateName = Self.thermalStateName(thermalState)
        let thermalMultiplier = Self.thermalWattMultiplier(thermalState)
        lock.unlock()

        let estimatedWatts = Self.estimateAppleSiliconProxyWatts(
            wallSeconds: safeWall,
            cpuSeconds: safeCPU,
            thermalMultiplier: thermalMultiplier
        )
        let estimatedJoules = estimatedWatts * safeWall
        let joulesPerFrame = safeFrames > 0 ? (estimatedJoules / Double(safeFrames)) : 0.0
        let fps = Double(safeFrames) / safeWall
        let fpsPerWatt = estimatedWatts > 0 ? (fps / estimatedWatts) : 0.0

        let sample = EnergySample(
            wallSeconds: safeWall,
            cpuSeconds: safeCPU,
            framesEncoded: safeFrames,
            estimatedJoules: estimatedJoules,
            joulesPerFrame: joulesPerFrame,
            framesPerSecondPerWatt: fpsPerWatt,
            thermalState: stateName
        )

        lock.lock()
        samples.append(sample)
        lock.unlock()
        return sample
    }

    // MARK: - Low-Level Darwin CPU & Thermal Helpers

    /// Returns cumulative process CPU seconds using BOTH `getrusage(RUSAGE_SELF)` and Darwin `task_info`.
    public static func currentProcessCPUTimeSeconds() -> Double {
        let rusageCPU = rusageSelfCPUTimeSeconds()
        let machCPU = machTaskCPUTimeSeconds()
        return max(rusageCPU, machCPU)
    }

    /// Process user + system CPU time via POSIX `getrusage(RUSAGE_SELF)`.
    public static func rusageSelfCPUTimeSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return 0.0
        }
        let userSec = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000.0
        let sysSec = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000.0
        return max(0.0, userSec + sysSec)
    }

    /// Process user + system CPU time via Darwin `task_info` (`TASK_THREAD_TIMES_INFO` + `MACH_TASK_BASIC_INFO`).
    public static func machTaskCPUTimeSeconds() -> Double {
        var totalSeconds = 0.0

        // Live threads CPU time.
        var threadInfo = task_thread_times_info_data_t()
        var threadCount = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let threadStatus: kern_return_t = withUnsafeMutablePointer(to: &threadInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(threadCount)) { intPtr in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_THREAD_TIMES_INFO),
                    intPtr,
                    &threadCount
                )
            }
        }
        if threadStatus == KERN_SUCCESS {
            totalSeconds += Double(threadInfo.user_time.seconds)
                + Double(threadInfo.user_time.microseconds) / 1_000_000.0
            totalSeconds += Double(threadInfo.system_time.seconds)
                + Double(threadInfo.system_time.microseconds) / 1_000_000.0
        }

        // Terminated threads CPU time.
        var basicInfo = mach_task_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let basicStatus: kern_return_t = withUnsafeMutablePointer(to: &basicInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { intPtr in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    intPtr,
                    &basicCount
                )
            }
        }
        if basicStatus == KERN_SUCCESS {
            totalSeconds += Double(basicInfo.user_time.seconds)
                + Double(basicInfo.user_time.microseconds) / 1_000_000.0
            totalSeconds += Double(basicInfo.system_time.seconds)
                + Double(basicInfo.system_time.microseconds) / 1_000_000.0
        }

        return max(0.0, totalSeconds)
    }

    public static func monotonicWallSeconds() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
    }

    public static func thermalStateName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "nominal"
        case .fair:
            return "fair"
        case .serious:
            return "serious"
        case .critical:
            return "critical"
        @unknown default:
            return "unknown"
        }
    }

    /// Honest Apple Silicon CPU/process watt envelope proxy (NOT a hardware power sensor).
    public static func estimateAppleSiliconProxyWatts(
        wallSeconds: Double,
        cpuSeconds: Double,
        thermalMultiplier: Double = 1.0
    ) -> Double {
        let safeWall = max(1e-6, wallSeconds)
        let activeCoreEquivalents = max(0.0, cpuSeconds / safeWall)
        let rawWatts = (baseActiveWatts + activeCoreEquivalents * perActiveCoreWatts) * thermalMultiplier
        return min(maxEnvelopeWatts, max(minEnvelopeWatts, rawWatts))
    }

    // MARK: - Private Hysteresis Helpers

    private func budgetCapLocked(for maxCalibrated: Int) -> Int {
        let safeMax = max(1, maxCalibrated)
        switch powerBudget {
        case .low:
            return 1
        case .balanced, .max:
            return safeMax
        }
    }

    private func seriousTarget(for cap: Int) -> Int {
        if cap <= 1 {
            return 1
        }
        return max(1, cap / 2)
    }

    private static func thermalWattMultiplier(_ state: ProcessInfo.ThermalState) -> Double {
        switch state {
        case .nominal: return 1.0
        case .fair: return 1.05
        case .serious: return 1.12
        case .critical: return 1.20
        @unknown default: return 1.0
        }
    }
}

// MARK: - HardwareAutoTuner

/// Empirical Apple Silicon VideoToolbox concurrency auto-tuner.
///
/// Runs real concurrent `VTCompressionSession` encode bursts across `1...maxSessions`
/// and selects the concurrency sweet spot, stopping once marginal throughput gain drops below 10%.
public enum HardwareAutoTuner {

    /// Minimum throughput gain percentage required to justify adding another concurrent encode session.
    public static let minimumGainThresholdPct: Double = 10.0

    /// Box wrapper for passing immutable `CVPixelBuffer`s across concurrent GCD bursts safely.
    private struct SendablePixelBufferBox: @unchecked Sendable {
        let buffers: [CVPixelBuffer]
    }

    /// Runs live `1...maxSessions` concurrent `VTCompressionSession` encode bursts on synthetic
    /// IOSurface-backed `CVPixelBuffer`s, measures aggregate FPS and CPU/energy proxy cost, and
    /// stops increasing `recommendedSessions` as soon as throughput gain falls below 10%.
    public static func calibrateConcurrency(
        codec: VideoCodec = .hevc,
        width: Int = 640,
        height: Int = 360,
        framesPerSession: Int = 15,
        maxSessions: Int = 4
    ) -> ConcurrencyCalibrationReport {
        let safeWidth = max(64, width & ~1)
        let safeHeight = max(64, height & ~1)
        let safeFrames = max(1, framesPerSession)
        let safeMaxSessions = max(1, maxSessions)
        let codecType = codec.cmCodecType
        let fourCC = fourCCString(from: codecType)
        let thermalName = ThermalHysteresisScheduler.thermalStateName(ProcessInfo.processInfo.thermalState)

        let pixelFormat = calibrationPixelFormat(for: codec)
        let ringCount = min(4, safeFrames)
        let syntheticBuffers = makeSyntheticCalibrationBuffers(
            count: ringCount,
            width: safeWidth,
            height: safeHeight,
            pixelFormat: pixelFormat
        )
        guard !syntheticBuffers.isEmpty else {
            return ConcurrencyCalibrationReport(
                codecFourCC: fourCC,
                recommendedSessions: 1,
                points: [],
                thermalState: thermalName,
                stopReason: "pixel_buffer_allocation_failed"
            )
        }

        let bufferBox = SendablePixelBufferBox(buffers: syntheticBuffers)
        var points: [ConcurrencyCalibrationPoint] = []
        points.reserveCapacity(safeMaxSessions)

        var recommendedSessions = 1
        var previousTotalFPS: Double = 0.0
        var stopReason = "reached_max_sessions (\(safeMaxSessions))"

        for sessionCount in 1...safeMaxSessions {
            guard let burst = runConcurrentBurst(
                sessionCount: sessionCount,
                codec: codec,
                width: safeWidth,
                height: safeHeight,
                framesPerSession: safeFrames,
                buffers: bufferBox
            ) else {
                stopReason = "encoder_session_failed_at_\(sessionCount)_sessions"
                break
            }

            let wallSeconds = max(1e-6, burst.wallSeconds)
            let totalFrames = max(1, burst.encodedFrames)
            let totalFPS = Double(totalFrames) / wallSeconds
            let perStreamFPS = totalFPS / Double(sessionCount)
            let proxyWatts = ThermalHysteresisScheduler.estimateAppleSiliconProxyWatts(
                wallSeconds: wallSeconds,
                cpuSeconds: burst.cpuSeconds
            )
            let joulesPerFrame = (proxyWatts * wallSeconds) / Double(totalFrames)

            let gainPct: Double
            if sessionCount == 1 || previousTotalFPS <= 0.0 {
                gainPct = 0.0
            } else {
                gainPct = ((totalFPS - previousTotalFPS) / previousTotalFPS) * 100.0
            }

            let point = ConcurrencyCalibrationPoint(
                sessions: sessionCount,
                totalFPS: totalFPS,
                perStreamFPS: perStreamFPS,
                wallMs: wallSeconds * 1000.0,
                cpuTimeMs: burst.cpuSeconds * 1000.0,
                estimatedJoulesPerFrame: joulesPerFrame,
                gainOverPreviousPct: gainPct
            )
            points.append(point)

            if sessionCount == 1 {
                recommendedSessions = 1
                previousTotalFPS = totalFPS
            } else if gainPct < minimumGainThresholdPct {
                let formatted = String(format: "%.2f", gainPct)
                stopReason = "throughput_gain_below_10pct (gain=\(formatted)% at \(sessionCount) sessions)"
                break
            } else {
                recommendedSessions = sessionCount
                previousTotalFPS = totalFPS
            }
        }

        return ConcurrencyCalibrationReport(
            codecFourCC: fourCC,
            recommendedSessions: recommendedSessions,
            points: points,
            thermalState: thermalName,
            stopReason: stopReason
        )
    }

    /// Pure deterministic evaluator of the `< 10%` throughput gain stopping rule on calibration points.
    public static func evaluateRecommendedSessions(
        from points: [ConcurrencyCalibrationPoint],
        minimumGainPct: Double = minimumGainThresholdPct
    ) -> (recommendedSessions: Int, stopReason: String) {
        guard let first = points.first else {
            return (1, "no_calibration_points")
        }
        var recommended = max(1, first.sessions)
        var previousFPS = max(1e-9, first.totalFPS)

        for point in points.dropFirst() {
            let gainPct = ((point.totalFPS - previousFPS) / previousFPS) * 100.0
            if gainPct < minimumGainPct {
                let formatted = String(format: "%.2f", gainPct)
                return (
                    recommended,
                    "throughput_gain_below_10pct (gain=\(formatted)% at \(point.sessions) sessions)"
                )
            }
            recommended = max(1, point.sessions)
            previousFPS = max(1e-9, point.totalFPS)
        }

        return (recommended, "reached_max_sessions (\(recommended))")
    }

    // MARK: - Live VideoToolbox Burst Execution

    private struct BurstResult {
        let wallSeconds: Double
        let cpuSeconds: Double
        let encodedFrames: Int
    }

    private final class AtomicBurstCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var encoded: Int = 0
        private var failed: Bool = false

        func incrementEncoded() {
            lock.lock()
            encoded += 1
            lock.unlock()
        }

        func markFailed() {
            lock.lock()
            failed = true
            lock.unlock()
        }

        func snapshot() -> (encoded: Int, failed: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (encoded, failed)
        }
    }

    private static func runConcurrentBurst(
        sessionCount: Int,
        codec: VideoCodec,
        width: Int,
        height: Int,
        framesPerSession: Int,
        buffers: SendablePixelBufferBox
    ) -> BurstResult? {
        let queue = DispatchQueue(
            label: "safarium.hardware-autotuner.burst.\(sessionCount)",
            qos: .userInitiated,
            attributes: .concurrent
        )
        let group = DispatchGroup()
        let counter = AtomicBurstCounter()

        let startWall = ThermalHysteresisScheduler.monotonicWallSeconds()
        let startCPU = ThermalHysteresisScheduler.currentProcessCPUTimeSeconds()

        for sessionIndex in 0..<sessionCount {
            group.enter()
            queue.async {
                defer { group.leave() }
                let ok = runSingleSessionEncode(
                    sessionIndex: sessionIndex,
                    codec: codec,
                    width: width,
                    height: height,
                    framesPerSession: framesPerSession,
                    buffers: buffers,
                    counter: counter
                )
                if !ok {
                    counter.markFailed()
                }
            }
        }

        group.wait()

        let endWall = ThermalHysteresisScheduler.monotonicWallSeconds()
        let endCPU = ThermalHysteresisScheduler.currentProcessCPUTimeSeconds()
        let snap = counter.snapshot()

        if snap.failed || snap.encoded == 0 {
            return nil
        }

        return BurstResult(
            wallSeconds: max(1e-6, endWall - startWall),
            cpuSeconds: max(0.0, endCPU - startCPU),
            encodedFrames: snap.encoded
        )
    }

    private static func runSingleSessionEncode(
        sessionIndex: Int,
        codec: VideoCodec,
        width: Int,
        height: Int,
        framesPerSession: Int,
        buffers: SendablePixelBufferBox,
        counter: AtomicBurstCounter
    ) -> Bool {
        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]

        var sessionOut: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: codec.cmCodecType,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &sessionOut
        )

        guard createStatus == noErr, let session = sessionOut else {
            return false
        }
        defer {
            VTCompressionSessionInvalidate(session)
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: NSNumber(value: 30)
        )
        if !codec.isProRes {
            let targetBitrate = max(600_000, width * height * 4)
            VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_AverageBitRate,
                value: NSNumber(value: targetBitrate)
            )
        }
        VTCompressionSessionPrepareToEncodeFrames(session)

        let ringCount = buffers.buffers.count
        let frameDuration = CMTime(value: 1, timescale: 30)

        for frameIdx in 0..<framesPerSession {
            let buffer = buffers.buffers[(frameIdx + sessionIndex) % ringCount]
            let pts = CMTime(value: CMTimeValue(frameIdx), timescale: 30)
            var flagsOut = VTEncodeInfoFlags()

            let encodeStatus = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: buffer,
                presentationTimeStamp: pts,
                duration: frameDuration,
                frameProperties: nil,
                infoFlagsOut: &flagsOut
            ) { status, _, sampleBuffer in
                if status == noErr && sampleBuffer != nil {
                    counter.incrementEncoded()
                }
            }

            if encodeStatus != noErr {
                return false
            }
        }

        let completeStatus = VTCompressionSessionCompleteFrames(
            session,
            untilPresentationTimeStamp: .invalid
        )
        return completeStatus == noErr
    }

    // MARK: - Synthetic Buffer & FourCC Helpers

    private static func calibrationPixelFormat(for codec: VideoCodec) -> OSType {
        switch codec {
        case .proRes4444, .proRes4444XQ, .hevcAlpha:
            return kCVPixelFormatType_32BGRA
        case .proRes422Proxy, .proRes422LT, .proRes422, .proRes422HQ:
            return kCVPixelFormatType_422YpCbCr8
        default:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
    }

    private static func makeSyntheticCalibrationBuffers(
        count: Int,
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) -> [CVPixelBuffer] {
        var result: [CVPixelBuffer] = []
        result.reserveCapacity(count)

        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
        ]

        for idx in 0..<count {
            var pbOut: CVPixelBuffer?
            let st = CVPixelBufferCreate(
                kCFAllocatorDefault,
                width,
                height,
                pixelFormat,
                attrs as CFDictionary,
                &pbOut
            )
            guard st == kCVReturnSuccess, let pb = pbOut else {
                continue
            }
            fillSyntheticPattern(pb, seed: idx, pixelFormat: pixelFormat)
            FrameColorMetadata.bt709SDR().apply(to: pb)
            result.append(pb)
        }
        return result
    }

    private static func fillSyntheticPattern(_ buffer: CVPixelBuffer, seed: Int, pixelFormat: OSType) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let phase = UInt8((seed * 47) & 0xFF)
        if CVPixelBufferIsPlanar(buffer) {
            let yH = CVPixelBufferGetHeightOfPlane(buffer, 0)
            let yW = CVPixelBufferGetWidthOfPlane(buffer, 0)
            let yBPR = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            if let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
                let yPtr = yBase.assumingMemoryBound(to: UInt8.self)
                for row in 0..<yH {
                    let rowPtr = yPtr.advanced(by: row * yBPR)
                    let rowVal = UInt8((row * 3 + Int(phase)) & 0xFF)
                    for col in 0..<yW {
                        let v = UInt8((Int(rowVal) + col * 2) & 0xFF)
                        rowPtr[col] = 16 + UInt8((Int(v) * 219) / 255)
                    }
                }
            }
            if CVPixelBufferGetPlaneCount(buffer) >= 2,
               let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
            {
                let uvH = CVPixelBufferGetHeightOfPlane(buffer, 1)
                let uvBPR = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
                let uvPtr = uvBase.assumingMemoryBound(to: UInt8.self)
                for row in 0..<uvH {
                    let rowPtr = uvPtr.advanced(by: row * uvBPR)
                    for col in 0..<uvBPR {
                        rowPtr[col] = UInt8(64 + ((row + col + Int(phase)) & 0x7F))
                    }
                }
            }
        } else if let base = CVPixelBufferGetBaseAddress(buffer) {
            let h = CVPixelBufferGetHeight(buffer)
            let bpr = CVPixelBufferGetBytesPerRow(buffer)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<h {
                let rowPtr = ptr.advanced(by: row * bpr)
                for col in 0..<bpr {
                    if pixelFormat == kCVPixelFormatType_32BGRA && (col & 3) == 3 {
                        rowPtr[col] = 255
                    } else {
                        rowPtr[col] = UInt8((row * 5 + col + Int(phase)) & 0xFF)
                    }
                }
            }
        }
    }

    private static func fourCCString(from value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08x", value)
    }
}
