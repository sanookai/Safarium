import Darwin
import Foundation

public enum SafariumError: Error, CustomStringConvertible, Equatable {
    case timeout(String)
    case javascript(String)
    case navigation(String)
    case snapshot(String)
    case encode(String)
    case invalidState(String)

    public var description: String {
        switch self {
        case .timeout(let m): return "timeout: \(m)"
        case .javascript(let m): return "javascript: \(m)"
        case .navigation(let m): return "navigation: \(m)"
        case .snapshot(let m): return "snapshot: \(m)"
        case .encode(let m): return "encode: \(m)"
        case .invalidState(let m): return "invalid state: \(m)"
        }
    }
}

public enum SafariumErrorCode: String, Codable, Sendable, CaseIterable {
    case E_USAGE
    case E_INPUT_MISSING
    case E_UNSUPPORTED_CODEC
    case E_QUEUE_BUSY
    case E_TIMEOUT
    case E_JS_EVAL
    case E_NAVIGATION
    case E_SNAPSHOT
    case E_ENCODE
    case E_VERIFY_FAIL
    case E_THERMAL_OR_MEM
    case E_INTERNAL

    public var defaultHint: String {
        switch self {
        case .E_USAGE: return "Check command arguments or recipe schema via `safarium-forge schema`."
        case .E_INPUT_MISSING: return "Verify input file paths exist and are readable regular files."
        case .E_UNSUPPORTED_CODEC: return "Inspect OS walls via `safarium-render capabilities` and choose a supported Apple codec/container."
        case .E_QUEUE_BUSY: return "Another foreground SF-VIDEO-1 render holds the slot; wait or inspect with `safarium-render status`."
        case .E_TIMEOUT: return "Operation exceeded deadline; split long timelines or inspect with `safarium-render doctor --json`."
        case .E_JS_EVAL: return "Page script threw or failed readiness check; test DOM/expressions or use local `--font-dir`."
        case .E_NAVIGATION: return "Check local HTML/loopback URL and readAccess bounds."
        case .E_SNAPSHOT: return "WebKit snapshot failed or size mismatched; retry single-worker or reduce heavy CSS/SVG filters."
        case .E_ENCODE: return "AVAssetWriter / AudioToolbox failed; validate even dimensions, BT.709 colorimetry, and free APFS space."
        case .E_VERIFY_FAIL: return "Output failed SafariumPQ / verify parity checks; inspect deltaE00, msSSIM, and Thai OCR fields."
        case .E_THERMAL_OR_MEM: return "Memory budget or thermal ceiling exceeded; lower `--adaptive-workers` or enable `--low-ram`."
        case .E_INTERNAL: return "Unexpected internal error; run `safarium-render doctor --json`."
        }
    }
}

public struct SafariumStructuredErrorDetail: Codable, Sendable {
    public let code: SafariumErrorCode
    public let category: String
    public let message: String
    public let hint: String
    public let recoverable: Bool

    public init(code: SafariumErrorCode, category: String, message: String, hint: String, recoverable: Bool) {
        self.code = code
        self.category = category
        self.message = message
        self.hint = hint
        self.recoverable = recoverable
    }
}

public struct SafariumStructuredErrorEnvelope: Codable, Sendable {
    public let ok: Bool
    public let tool: String
    public let error: SafariumStructuredErrorDetail

    public init(ok: Bool = false, tool: String, error: SafariumStructuredErrorDetail) {
        self.ok = ok
        self.tool = tool
        self.error = error
    }

    public static func from(
        _ error: Error,
        tool: String,
        overrideCode: SafariumErrorCode? = nil,
        hint: String? = nil
    ) -> SafariumStructuredErrorEnvelope {
        let msg = String(describing: error)
        let lower = msg.lowercased()
        let code: SafariumErrorCode
        let category: String
        let recoverable: Bool

        if let overrideCode {
            code = overrideCode
            category = overrideCode.rawValue.lowercased()
            recoverable = (overrideCode == .E_TIMEOUT || overrideCode == .E_QUEUE_BUSY || overrideCode == .E_THERMAL_OR_MEM)
        } else if let se = error as? SafariumError {
            switch se {
            case .timeout:
                code = .E_TIMEOUT; category = "timeout"; recoverable = true
            case .javascript:
                code = .E_JS_EVAL; category = "webkit_js"; recoverable = false
            case .navigation:
                code = .E_NAVIGATION; category = "navigation"; recoverable = true
            case .snapshot:
                code = .E_SNAPSHOT; category = "snapshot"; recoverable = true
            case .encode:
                if lower.contains("unsupported") || lower.contains("ogg") || lower.contains("opus") || lower.contains("vorbis") {
                    code = .E_UNSUPPORTED_CODEC; category = "codec"; recoverable = false
                } else {
                    code = .E_ENCODE; category = "encode"; recoverable = false
                }
            case .invalidState:
                if lower.contains("missing") || lower.contains("not a readable") || lower.contains("does not exist") || lower.contains("empty") {
                    code = .E_INPUT_MISSING; category = "input"; recoverable = false
                } else if lower.contains("qa failed") || lower.contains("verify") || lower.contains("safarium") && lower.contains("pq") {
                    code = .E_VERIFY_FAIL; category = "verify"; recoverable = false
                } else if lower.contains("unsupported") || lower.contains("rejects") || lower.contains("codec") {
                    code = .E_UNSUPPORTED_CODEC; category = "codec"; recoverable = false
                } else if lower.contains("thermal") || lower.contains("budget") || lower.contains("memory") {
                    code = .E_THERMAL_OR_MEM; category = "resource"; recoverable = true
                } else {
                    code = .E_USAGE; category = "validation"; recoverable = false
                }
            }
        } else {
            if lower.contains("does not exist") || lower.contains("no such file") || lower.contains("not readable") {
                code = .E_INPUT_MISSING; category = "input"; recoverable = false
            } else if lower.contains("timeout") || lower.contains("timed out") {
                code = .E_TIMEOUT; category = "timeout"; recoverable = true
            } else {
                code = .E_INTERNAL; category = "internal"; recoverable = false
            }
        }

        return SafariumStructuredErrorEnvelope(
            ok: false,
            tool: tool,
            error: SafariumStructuredErrorDetail(
                code: code,
                category: category,
                message: msg,
                hint: hint ?? code.defaultHint,
                recoverable: recoverable
            )
        )
    }

    public func jsonLineData() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var d = (try? enc.encode(self)) ?? Data("{\"ok\":false}\n".utf8)
        d.append(0x0A)
        return d
    }
}

public enum SafariumRuntimeTelemetry {
    public static func currentFootprintMB() -> Double {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rPtr in
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rPtr)
            }
        }
        guard rc == 0 else { return 0.0 }
        return Double(info.ri_phys_footprint) / (1024.0 * 1024.0)
    }

    public static func thermalStateString() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

public struct SafariumProgressEvent: Codable, Sendable {
    public let event: String
    public let stage: String
    public let frame: Int?
    public let total: Int?
    public let progress: Double?
    public let fps: Double?
    public let etaSec: Double?
    public let elapsedSec: Double
    public let footprintMB: Double
    public let thermal: String

    public init(
        event: String,
        stage: String,
        frame: Int? = nil,
        total: Int? = nil,
        progress: Double? = nil,
        fps: Double? = nil,
        etaSec: Double? = nil,
        elapsedSec: Double,
        footprintMB: Double = SafariumRuntimeTelemetry.currentFootprintMB(),
        thermal: String = SafariumRuntimeTelemetry.thermalStateString()
    ) {
        self.event = event
        self.stage = stage
        self.frame = frame
        self.total = total
        self.progress = progress
        self.fps = fps
        self.etaSec = etaSec
        self.elapsedSec = (elapsedSec * 1000.0).rounded() / 1000.0
        self.footprintMB = (footprintMB * 100.0).rounded() / 100.0
        self.thermal = thermal
    }
}

public final class SafariumProgressEmitter: @unchecked Sendable {
    public let enabled: Bool
    private let startNs: UInt64
    private var lastEmitNs: UInt64 = 0
    private let minIntervalNs: UInt64
    private let lock = NSLock()
    private let encoder: JSONEncoder

    public init(enabled: Bool, minIntervalSeconds: Double = 0.15) {
        self.enabled = enabled
        self.startNs = DispatchTime.now().uptimeNanoseconds
        self.minIntervalNs = UInt64(max(0.0, minIntervalSeconds) * 1_000_000_000.0)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = enc
    }

    public func emitStart(stage: String, total: Int? = nil) {
        guard enabled else { return }
        write(SafariumProgressEvent(
            event: "start",
            stage: stage,
            frame: total != nil ? 0 : nil,
            total: total,
            progress: total != nil ? 0.0 : nil,
            elapsedSec: 0.0
        ))
    }

    public func emitFrame(stage: String, completed: Int, total: Int, force: Bool = false) {
        guard enabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldForce = force || total <= 120 || completed >= total || completed == 1
        lock.lock()
        let delta = now &- lastEmitNs
        if !shouldForce && delta < minIntervalNs {
            lock.unlock()
            return
        }
        lastEmitNs = now
        lock.unlock()

        let elapsed = Double(now &- startNs) / 1e9
        let frac = total > 0 ? min(1.0, max(0.0, Double(completed) / Double(total))) : nil
        let fps = elapsed > 0.001 && completed > 0 ? (Double(completed) / elapsed) : nil
        let eta = (fps != nil && fps! > 0.001 && total > completed) ? Double(total - completed) / fps! : (completed >= total ? 0.0 : nil)
        write(SafariumProgressEvent(
            event: "progress",
            stage: stage,
            frame: completed,
            total: total,
            progress: frac.map { ($0 * 10000.0).rounded() / 10000.0 },
            fps: fps.map { ($0 * 100.0).rounded() / 100.0 },
            etaSec: eta.map { ($0 * 100.0).rounded() / 100.0 },
            elapsedSec: elapsed
        ))
    }

    public func emitComplete(stage: String, total: Int? = nil) {
        guard enabled else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(now &- startNs) / 1e9
        let fps = (elapsed > 0.001 && (total ?? 0) > 0) ? (Double(total!) / elapsed) : nil
        write(SafariumProgressEvent(
            event: "complete",
            stage: stage,
            frame: total,
            total: total,
            progress: 1.0,
            fps: fps.map { ($0 * 100.0).rounded() / 100.0 },
            etaSec: 0.0,
            elapsedSec: elapsed
        ))
    }

    private func write(_ ev: SafariumProgressEvent) {
        guard var data = try? encoder.encode(ev) else { return }
        data.append(0x0A)
        FileHandle.standardError.write(data)
    }
}
