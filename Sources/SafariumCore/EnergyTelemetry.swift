import Darwin
import Foundation
import IOKit
import IOKit.ps

// MARK: - Native Apple Silicon Energy, Thermal & Memory Telemetry (Wave 17)

/// Single point-in-time energy, thermal, memory, and CPU telemetry reading.
public struct EnergyTelemetrySample: Codable, Sendable, Equatable {
    public let timestampSeconds: Double
    public let watts: Double
    public let thermalState: String
    public let rssMB: Double
    public let cpuUtilization: Double

    public init(
        timestampSeconds: Double,
        watts: Double,
        thermalState: String,
        rssMB: Double,
        cpuUtilization: Double
    ) {
        self.timestampSeconds = timestampSeconds
        self.watts = watts
        self.thermalState = thermalState
        self.rssMB = rssMB
        self.cpuUtilization = cpuUtilization
    }
}

/// Aggregated energy efficiency report for a media encode/processing workload.
public struct EnergyReport: Codable, Sendable, Equatable {
    public let elapsedSeconds: Double
    public let framesProcessed: Int
    public let fps: Double
    public let averageWatts: Double
    public let peakWatts: Double
    public let wattsSource: String
    public let joulesTotal: Double
    public let joulesPerFrame: Double
    public let fpsPerWatt: Double
    public let peakRSSMB: Double
    public let thermalStates: [String]
    public let sampleCount: Int

    public init(
        elapsedSeconds: Double,
        framesProcessed: Int,
        fps: Double,
        averageWatts: Double,
        peakWatts: Double,
        wattsSource: String,
        joulesTotal: Double,
        joulesPerFrame: Double,
        fpsPerWatt: Double,
        peakRSSMB: Double,
        thermalStates: [String],
        sampleCount: Int
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.framesProcessed = framesProcessed
        self.fps = fps
        self.averageWatts = averageWatts
        self.peakWatts = peakWatts
        self.wattsSource = wattsSource
        self.joulesTotal = joulesTotal
        self.joulesPerFrame = joulesPerFrame
        self.fpsPerWatt = fpsPerWatt
        self.peakRSSMB = peakRSSMB
        self.thermalStates = thermalStates
        self.sampleCount = sampleCount
    }
}

/// Zero-privilege macOS / Apple Silicon energy & thermal telemetry sampler.
/// Reads live `AppleSmartBattery` voltage/amperage via `IOKit` + `IOKit.ps` when discharging on battery,
/// and falls back cleanly to a process CPU-time + Apple Silicon baseline power estimator (`"estimated_cpu_load"`)
/// on AC-powered desktop Macs and headless CI VMs.
public final class EnergyTelemetrySampler: @unchecked Sendable {
    public typealias Sample = EnergyTelemetrySample

    private let lock = NSLock()
    private var startUptimeNs: UInt64 = 0
    private var lastWallNs: UInt64 = 0
    private var lastProcessCPUSec: Double = 0.0
    private var isStarted: Bool = false
    private var samples: [EnergyTelemetrySample] = []
    private var observedWattsSource: String = "estimated_cpu_load"

    public init() {}

    /// Starts (or resets) a telemetry sampling session.
    public func start() {
        lock.lock()
        defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        startUptimeNs = now
        lastWallNs = now
        lastProcessCPUSec = Self.currentProcessCPUTimeSeconds()
        isStarted = true
        samples = []
        observedWattsSource = "estimated_cpu_load"
    }

    /// Captures and stores one telemetry sample (auto-starts the session if `start()` was not yet called).
    @discardableResult
    public func recordSample() -> EnergyTelemetrySample {
        lock.lock()
        defer { lock.unlock() }
        return recordSampleLocked()
    }

    /// Returns a snapshot of samples collected so far.
    public func currentSamples() -> [EnergyTelemetrySample] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    /// Ends the sampling session and computes total energy, J/frame, FPS/W, peak RSS, and thermal states.
    public func stop(framesProcessed: Int) -> EnergyReport {
        lock.lock()
        defer { lock.unlock() }

        let now = DispatchTime.now().uptimeNanoseconds
        if !isStarted {
            startUptimeNs = now
            lastWallNs = now
            lastProcessCPUSec = Self.currentProcessCPUTimeSeconds()
            isStarted = true
        }

        // Always take a final sample so short workloads have accurate end bounds
        if samples.isEmpty || (now > lastWallNs && (now - lastWallNs) >= 1_000_000) {
            _ = recordSampleLocked()
        }

        let endWallNs = DispatchTime.now().uptimeNanoseconds
        let elapsedNs = (endWallNs > startUptimeNs) ? (endWallNs - startUptimeNs) : 1_000
        let elapsedSeconds = max(1e-6, Double(elapsedNs) / 1_000_000_000.0)

        var peakWatts = 0.0
        var peakRSS = 0.0
        var sumWatts = 0.0
        var thermalOrder: [String] = []
        var thermalSeen: Set<String> = []

        for s in samples {
            sumWatts += s.watts
            if s.watts > peakWatts { peakWatts = s.watts }
            if s.rssMB > peakRSS { peakRSS = s.rssMB }
            if !thermalSeen.contains(s.thermalState) {
                thermalSeen.insert(s.thermalState)
                thermalOrder.append(s.thermalState)
            }
        }

        let avgWatts: Double
        if samples.isEmpty {
            avgWatts = 4.5
            peakWatts = 4.5
        } else {
            avgWatts = sumWatts / Double(samples.count)
        }

        // Trapezoidal integration across samples; cover any leading/trailing interval with endpoint power
        var joulesTotal = 0.0
        if samples.count >= 2 {
            let firstT = samples[0].timestampSeconds
            if firstT > 0.0 {
                joulesTotal += samples[0].watts * firstT
            }
            for i in 1..<samples.count {
                let dt = max(0.0, samples[i].timestampSeconds - samples[i - 1].timestampSeconds)
                let midW = 0.5 * (samples[i - 1].watts + samples[i].watts)
                joulesTotal += midW * dt
            }
            let lastT = samples[samples.count - 1].timestampSeconds
            let tailDt = max(0.0, elapsedSeconds - lastT)
            if tailDt > 0.0 {
                joulesTotal += samples[samples.count - 1].watts * tailDt
            }
        } else {
            joulesTotal = avgWatts * elapsedSeconds
        }
        if joulesTotal <= 0.0 {
            joulesTotal = max(1e-9, avgWatts * elapsedSeconds)
        }

        let safeFrames = max(0, framesProcessed)
        let fps = safeFrames > 0 ? (Double(safeFrames) / elapsedSeconds) : 0.0
        let joulesPerFrame = safeFrames > 0 ? (joulesTotal / Double(safeFrames)) : 0.0
        let fpsPerWatt = avgWatts > 1e-9 ? (fps / avgWatts) : 0.0

        isStarted = false
        return EnergyReport(
            elapsedSeconds: round4(elapsedSeconds),
            framesProcessed: safeFrames,
            fps: round3(fps),
            averageWatts: round3(avgWatts),
            peakWatts: round3(peakWatts),
            wattsSource: observedWattsSource,
            joulesTotal: round4(joulesTotal),
            joulesPerFrame: round6(joulesPerFrame),
            fpsPerWatt: round3(fpsPerWatt),
            peakRSSMB: round3(peakRSS),
            thermalStates: thermalOrder.isEmpty ? [Self.currentThermalState()] : thermalOrder,
            sampleCount: samples.count
        )
    }

    // MARK: - Internal Sampling

    private func recordSampleLocked() -> EnergyTelemetrySample {
        let now = DispatchTime.now().uptimeNanoseconds
        if !isStarted {
            startUptimeNs = now
            lastWallNs = now
            lastProcessCPUSec = Self.currentProcessCPUTimeSeconds()
            isStarted = true
        }

        let currentCPUSec = Self.currentProcessCPUTimeSeconds()
        let deltaWallSec = max(1e-6, Double(now >= lastWallNs ? (now - lastWallNs) : 0) / 1_000_000_000.0)
        let deltaCPUSec = max(0.0, currentCPUSec - lastProcessCPUSec)
        let coreCount = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        let cpuUtil = min(coreCount, deltaCPUSec / deltaWallSec)

        lastWallNs = now
        lastProcessCPUSec = currentCPUSec

        let timestampSec = Double(now >= startUptimeNs ? (now - startUptimeNs) : 0) / 1_000_000_000.0
        let rssMB = Self.currentProcessRSSMB()
        let thermal = Self.currentThermalState()

        let (watts, source) = Self.measureSystemWatts(cpuUtilization: cpuUtil)
        if source == "iokit_smart_battery" {
            observedWattsSource = source
        } else if samples.isEmpty {
            observedWattsSource = source
        }

        let sample = EnergyTelemetrySample(
            timestampSeconds: round4(timestampSec),
            watts: round3(watts),
            thermalState: thermal,
            rssMB: round3(rssMB),
            cpuUtilization: round4(cpuUtil)
        )
        samples.append(sample)
        return sample
    }

    // MARK: - Native macOS System Probes

    /// Attempts live battery discharge power via `IOKit.ps` + `AppleSmartBattery`, falling back
    /// to an Apple Silicon CPU-load power estimator on AC/desktop/headless systems.
    private static func measureSystemWatts(cpuUtilization: Double) -> (watts: Double, source: String) {
        if let batteryWatts = readAppleSmartBatteryDischargeWatts() {
            return (batteryWatts, "iokit_smart_battery")
        }
        // Apple Silicon baseline (idle SoC ~4.5W) + dynamic CPU core power scaling
        let clampedCPU = max(0.0, cpuUtilization)
        let baselineWatts = 4.5
        let dynamicWatts = clampedCPU * 2.5
        let estimated = baselineWatts + dynamicWatts
        return (estimated, "estimated_cpu_load")
    }

    private static func readAppleSmartBatteryDischargeWatts() -> Double? {
        // Check via IOKit.ps whether system is currently running on battery discharge
        var isOnBattery = false
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for item in list {
                if let desc = IOPSGetPowerSourceDescription(blob, item)?.takeUnretainedValue() as? [String: Any],
                   let powerState = desc[kIOPSPowerSourceStateKey as String] as? String,
                   powerState == (kIOPSBatteryPowerValue as String) {
                    isOnBattery = true
                    break
                }
            }
        }
        guard isOnBattery else {
            return nil
        }

        guard let matching = IOServiceMatching("AppleSmartBattery") else {
            return nil
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != IO_OBJECT_NULL else {
            return nil
        }
        defer { IOObjectRelease(service) }

        guard let voltProp = IORegistryEntryCreateCFProperty(service, "Voltage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber,
              let ampProp = IORegistryEntryCreateCFProperty(service, "InstantAmperage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber else {
            return nil
        }

        let voltageMV = voltProp.int64Value
        let amperageMA = ampProp.int64Value
        guard voltageMV > 0 && amperageMA < 0 else {
            return nil
        }

        let volts = Double(voltageMV) / 1000.0
        let amps = Double(-amperageMA) / 1000.0
        let watts = volts * amps
        if watts.isFinite && watts > 0.5 && watts < 250.0 {
            return watts
        }
        return nil
    }

    private static func currentThermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func currentProcessCPUTimeSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return 0.0
        }
        let userSec = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000.0
        let sysSec = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000.0
        return userSec + sysSec
    }

    private static func currentProcessRSSMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    intPtr,
                    &count
                )
            }
        }
        guard kr == KERN_SUCCESS else {
            return 0.0
        }
        let bytes = Double(info.resident_size)
        return bytes / (1024.0 * 1024.0)
    }

    private func round3(_ v: Double) -> Double { (v * 1000.0).rounded() / 1000.0 }
    private func round4(_ v: Double) -> Double { (v * 10_000.0).rounded() / 10_000.0 }
    private func round6(_ v: Double) -> Double { (v * 1_000_000.0).rounded() / 1_000_000.0 }
}
