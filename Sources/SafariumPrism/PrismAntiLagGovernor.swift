import CoreGraphics
import Darwin
import Foundation

public enum PrismThermalLevel: String, Codable, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .fair
        }
    }
}

public struct PrismTelemetrySnapshot: Codable, Sendable, Equatable {
    public var hidIdleSeconds: Double
    public var hidListenAccessOK: Bool
    public var thermalState: PrismThermalLevel
    public var isLowPowerMode: Bool
    public var selfFootprintBytes: UInt64
    public var childFootprintBytes: UInt64?

    public init(
        hidIdleSeconds: Double,
        hidListenAccessOK: Bool,
        thermalState: PrismThermalLevel,
        isLowPowerMode: Bool,
        selfFootprintBytes: UInt64,
        childFootprintBytes: UInt64? = nil
    ) {
        self.hidIdleSeconds = hidIdleSeconds
        self.hidListenAccessOK = hidListenAccessOK
        self.thermalState = thermalState
        self.isLowPowerMode = isLowPowerMode
        self.selfFootprintBytes = selfFootprintBytes
        self.childFootprintBytes = childFootprintBytes
    }
}

public protocol PrismTelemetryProviding: Sendable {
    func capture(childPID: Int32?) -> PrismTelemetrySnapshot
}

public struct PrismLiveTelemetryProvider: PrismTelemetryProviding {
    public init() {}

    public func capture(childPID: Int32?) -> PrismTelemetrySnapshot {
        let anyEvent = CGEventType(rawValue: ~0) ?? .null
        let rawIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyEvent)
        let hidIdle = rawIdle.isFinite ? max(0.0, rawIdle) : 3600.0
        let listenOK = CGPreflightListenEventAccess()
        let procInfo = ProcessInfo.processInfo
        let thermal = PrismThermalLevel(procInfo.thermalState)
        let lowPower = procInfo.isLowPowerModeEnabled
        let selfFoot = Self.selfPhysicalFootprintBytes()
        let childFoot = childPID.flatMap { Self.processPhysicalFootprintBytes(pid: $0) }
        return PrismTelemetrySnapshot(
            hidIdleSeconds: hidIdle,
            hidListenAccessOK: listenOK,
            thermalState: thermal,
            isLowPowerMode: lowPower,
            selfFootprintBytes: selfFoot,
            childFootprintBytes: childFoot
        )
    }

    public static func selfPhysicalFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { iptr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), iptr, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    public static func processPhysicalFootprintBytes(pid: Int32) -> UInt64? {
        guard pid > 0 else { return nil }
        var ru = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &ru) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rPtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rPtr)
            }
        }
        return rc == 0 ? ru.ri_phys_footprint : nil
    }
}

public final class PrismClosureTelemetryProvider: PrismTelemetryProviding, @unchecked Sendable {
    private let closure: (Int32?) -> PrismTelemetrySnapshot

    public init(_ closure: @escaping (Int32?) -> PrismTelemetrySnapshot) {
        self.closure = closure
    }

    public func capture(childPID: Int32?) -> PrismTelemetrySnapshot {
        closure(childPID)
    }
}

public struct PrismAntiLagConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var pauseWindowSeconds: Double
    public var activeHIDSleepMs: Int
    public var seriousThermalSleepMs: Int
    public var criticalThermalSleepMs: Int
    public var applyDarwinBackground: Bool
    public var useTaskpolicyForChild: Bool

    public init(
        enabled: Bool = true,
        pauseWindowSeconds: Double = 1.5,
        activeHIDSleepMs: Int = 100,
        seriousThermalSleepMs: Int = 150,
        criticalThermalSleepMs: Int = 1000,
        applyDarwinBackground: Bool = true,
        useTaskpolicyForChild: Bool = true
    ) {
        self.enabled = enabled
        self.pauseWindowSeconds = max(0.0, pauseWindowSeconds)
        self.activeHIDSleepMs = max(0, activeHIDSleepMs)
        self.seriousThermalSleepMs = max(0, seriousThermalSleepMs)
        self.criticalThermalSleepMs = max(0, criticalThermalSleepMs)
        self.applyDarwinBackground = applyDarwinBackground
        self.useTaskpolicyForChild = useTaskpolicyForChild
    }
}

public struct PrismGovernorDecision: Codable, Sendable, Equatable {
    public var shouldYield: Bool
    public var sleepMs: Int
    public var useDarwinBG: Bool
    public var reason: String
    public var telemetry: PrismTelemetrySnapshot
}

public struct PrismAntiLagStats: Codable, Sendable, Equatable {
    public var stepsEvaluated: Int = 0
    public var hidPauseEvents: Int = 0
    public var thermalCooldownEvents: Int = 0
    public var totalYieldMs: Int = 0
    public var darwinBGToggles: Int = 0
    public var maxSelfFootprintBytes: UInt64 = 0
    public var maxChildFootprintBytes: UInt64 = 0
}

/// Unprivileged macOS HID-idle + thermal + physical-footprint anti-lag governor.
/// Yields CPU/GPU only while the user actively moves mouse/keyboard (`hidIdleSeconds < pauseWindowSeconds`)
/// or when thermal pressure reaches `.serious`/`.critical`, running at full speed when idle.
public final class PrismAntiLagGovernor: @unchecked Sendable {
    public static let taskpolicyPath = "/usr/sbin/taskpolicy"

    public let config: PrismAntiLagConfig
    private let telemetryProvider: PrismTelemetryProviding
    private let lock = NSLock()
    private var _stats = PrismAntiLagStats()
    private var lastDarwinBGState: Bool?
    private var lastChildBGState: Bool?

    public init(
        config: PrismAntiLagConfig = PrismAntiLagConfig(),
        telemetryProvider: PrismTelemetryProviding = PrismLiveTelemetryProvider()
    ) {
        self.config = config
        self.telemetryProvider = telemetryProvider
    }

    deinit {
        restorePriority(childPID: nil)
    }

    public var stats: PrismAntiLagStats {
        lock.withLock { _stats }
    }

    public static func isTaskpolicyAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: taskpolicyPath)
    }

    public func evaluateDecision(childPID: Int32? = nil) -> PrismGovernorDecision {
        let snap = telemetryProvider.capture(childPID: childPID)
        guard config.enabled else {
            return PrismGovernorDecision(
                shouldYield: false,
                sleepMs: 0,
                useDarwinBG: false,
                reason: "governor_disabled",
                telemetry: snap
            )
        }

        let hidActive = snap.hidListenAccessOK && snap.hidIdleSeconds < config.pauseWindowSeconds
        var sleepMs = 0
        var reasons: [String] = []

        if snap.thermalState == .critical {
            sleepMs = max(sleepMs, config.criticalThermalSleepMs)
            reasons.append("thermal_critical")
        } else if snap.thermalState == .serious {
            sleepMs = max(sleepMs, config.seriousThermalSleepMs)
            reasons.append("thermal_serious")
        }

        if hidActive {
            sleepMs = max(sleepMs, config.activeHIDSleepMs)
            reasons.append("hid_active")
        }

        let useBG = hidActive || snap.thermalState == .serious || snap.thermalState == .critical || snap.isLowPowerMode
        let reason = reasons.isEmpty ? "idle_full_speed" : reasons.joined(separator: "+")
        return PrismGovernorDecision(
            shouldYield: sleepMs > 0,
            sleepMs: sleepMs,
            useDarwinBG: useBG,
            reason: reason,
            telemetry: snap
        )
    }

    @discardableResult
    public func paceStep(childPID: Int32? = nil) async throws -> PrismGovernorDecision {
        let decision = evaluateDecision(childPID: childPID)
        let snap = decision.telemetry

        let (prevSelfBG, prevChildBG) = lock.withLock { () -> (Bool?, Bool?) in
            _stats.stepsEvaluated += 1
            if decision.reason.contains("hid_active") {
                _stats.hidPauseEvents += 1
            }
            if snap.thermalState == .serious || snap.thermalState == .critical {
                _stats.thermalCooldownEvents += 1
            }
            _stats.totalYieldMs += decision.sleepMs
            _stats.maxSelfFootprintBytes = max(_stats.maxSelfFootprintBytes, snap.selfFootprintBytes)
            if let childBytes = snap.childFootprintBytes {
                _stats.maxChildFootprintBytes = max(_stats.maxChildFootprintBytes, childBytes)
            }
            return (lastDarwinBGState, lastChildBGState)
        }

        if config.applyDarwinBackground && prevSelfBG != decision.useDarwinBG {
            let prio = decision.useDarwinBG ? Int32(PRIO_DARWIN_BG) : Int32(0)
            if Darwin.setpriority(Int32(PRIO_DARWIN_PROCESS), 0, prio) == 0 {
                lock.withLock {
                    lastDarwinBGState = decision.useDarwinBG
                    _stats.darwinBGToggles += 1
                }
            }
        }

        if config.useTaskpolicyForChild, let pid = childPID, pid > 0, prevChildBG != decision.useDarwinBG {
            if Self.applyTaskpolicy(background: decision.useDarwinBG, pid: pid) {
                lock.withLock {
                    lastChildBGState = decision.useDarwinBG
                }
            }
        }

        if decision.sleepMs > 0 {
            try await Task.sleep(nanoseconds: UInt64(decision.sleepMs) * 1_000_000)
        }
        return decision
    }

    public func restorePriority(childPID: Int32? = nil) {
        let (hadSelfBG, hadChildBG) = lock.withLock { () -> (Bool, Bool) in
            let s = lastDarwinBGState == true
            let c = lastChildBGState == true
            lastDarwinBGState = false
            lastChildBGState = false
            return (s, c)
        }
        if hadSelfBG {
            _ = Darwin.setpriority(Int32(PRIO_DARWIN_PROCESS), 0, 0)
        }
        if hadChildBG, let pid = childPID, pid > 0 {
            _ = Self.applyTaskpolicy(background: false, pid: pid)
        }
    }

    @discardableResult
    private static func applyTaskpolicy(background: Bool, pid: Int32) -> Bool {
        guard isTaskpolicyAvailable() else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: taskpolicyPath)
        proc.arguments = [background ? "-b" : "-B", "-p", "\(pid)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}
