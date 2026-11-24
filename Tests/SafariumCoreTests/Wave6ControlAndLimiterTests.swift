import Foundation
@testable import SafariumCore
import XCTest

final class Wave6ControlAndLimiterTests: XCTestCase {
    func testOfflinePeakLimiter4xOversampledTruePeakBoundsInterSamplePeaks() throws {
        let sampleRate = 48_000.0
        let channels = 2
        let totalFrames = 24_000 // 0.5s at 48kHz
        var interleaved = [Float](repeating: 0, count: totalFrames * channels)
        // 12 kHz shifted by pi/4 produces inter-sample peaks ~+3.0 dB above sample peaks
        let freq: Double = 12_000.0
        for f in 0..<totalFrames {
            let phase = 2.0 * Double.pi * freq * (Double(f) + 0.5) / sampleRate
            let sample = Float(0.99 * sin(phase))
            interleaved[f * 2] = sample
            interleaved[f * 2 + 1] = sample
        }

        let ceilingDB = -1.5
        let limiter = try OfflinePeakLimiter(
            sampleRate: sampleRate,
            channels: channels,
            ceilingDBTP: ceilingDB,
            oversampled4xTruePeak: true
        )
        XCTAssertTrue(limiter.oversampled4xTruePeak)
        try limiter.processBuffer(&interleaved)

        let meter = try LoudnessMeter(sampleRate: sampleRate, channels: channels)
        interleaved.withUnsafeBufferPointer { buf in
            meter.processInterleaved(buf)
        }
        XCTAssertGreaterThan(meter.rms, 0.1, "signal should not be muted by limiter")
        XCTAssertLessThanOrEqual(meter.truePeakDBTP, -1.2, "4x oversampled limiter must keep truePeak <= -1.2 dBTP (got \(meter.truePeakDBTP))")
        XCTAssertLessThanOrEqual(meter.samplePeakDBFS, -1.2, "samplePeak must stay <= -1.2 dBFS (got \(meter.samplePeakDBFS))")

        // Also exercise direct processBlock across uneven block lengths on mono
        let monoLimiter = try OfflinePeakLimiter(sampleRate: sampleRate, channels: 1, ceilingDBTP: -1.1, oversampled4xTruePeak: true)
        var monoChunk = [Float](repeating: 0.95, count: 513)
        try monoChunk.withUnsafeMutableBufferPointer { ptr in
            try monoLimiter.processBlock(interleaved: ptr.baseAddress!, frameCount: 513)
        }
        for s in monoChunk {
            XCTAssertTrue(s.isFinite)
            XCTAssertLessThanOrEqual(abs(s), 0.95)
        }
    }

    func testStructuredErrorEnvelopeJSONLineAllCodes() throws {
        XCTAssertGreaterThanOrEqual(SafariumErrorCode.allCases.count, 10)
        for code in SafariumErrorCode.allCases {
            XCTAssertFalse(code.defaultHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(code) must have defaultHint")
        }

        let timeoutEnv = SafariumStructuredErrorEnvelope.from(SafariumError.timeout("budget 5s"), tool: "safarium-forge")
        XCTAssertFalse(timeoutEnv.ok)
        XCTAssertEqual(timeoutEnv.tool, "safarium-forge")
        XCTAssertEqual(timeoutEnv.error.code, .E_TIMEOUT)
        XCTAssertTrue(timeoutEnv.error.recoverable)

        let encodeEnv = SafariumStructuredErrorEnvelope.from(SafariumError.encode("bad frame"), tool: "safarium-html")
        XCTAssertEqual(encodeEnv.error.code, .E_ENCODE)
        XCTAssertFalse(encodeEnv.error.recoverable)

        let overrideEnv = SafariumStructuredErrorEnvelope.from(
            SafariumError.invalidState("bad cli arg"),
            tool: "safarium-media",
            overrideCode: .E_USAGE,
            hint: "custom usage hint"
        )
        XCTAssertEqual(overrideEnv.error.code, .E_USAGE)
        XCTAssertEqual(overrideEnv.error.hint, "custom usage hint")

        let line = overrideEnv.jsonLineData()
        XCTAssertEqual(line.last, 0x0A, "jsonLineData must end with LF newline")
        let decoded = try JSONDecoder().decode(SafariumStructuredErrorEnvelope.self, from: Data(line.dropLast()))
        XCTAssertEqual(decoded.ok, false)
        XCTAssertEqual(decoded.tool, "safarium-media")
        XCTAssertEqual(decoded.error.code, .E_USAGE)
        XCTAssertEqual(decoded.error.hint, "custom usage hint")
    }

    func testRuntimeTelemetryAndProgressEvents() throws {
        let mb = SafariumRuntimeTelemetry.currentFootprintMB()
        XCTAssertTrue(mb.isFinite && mb > 0.0, "physical footprint must be positive (got \(mb))")
        let thermal = SafariumRuntimeTelemetry.thermalStateString()
        XCTAssertTrue(["nominal", "fair", "serious", "critical", "unknown"].contains(thermal), "unexpected thermal string: \(thermal)")

        let disabled = SafariumProgressEmitter(enabled: false)
        disabled.emitStart(stage: "unit_noop", total: 10)
        disabled.emitFrame(stage: "unit_noop", completed: 5, total: 10)
        disabled.emitComplete(stage: "unit_noop", total: 10)

        let ev = SafariumProgressEvent(
            event: "progress",
            stage: "encode",
            frame: 15,
            total: 30,
            progress: 0.5,
            fps: 60.0,
            etaSec: 0.25,
            elapsedSec: 0.2512
        )
        let encoded = try JSONEncoder().encode(ev)
        let decoded = try JSONDecoder().decode(SafariumProgressEvent.self, from: encoded)
        XCTAssertEqual(decoded.event, "progress")
        XCTAssertEqual(decoded.stage, "encode")
        XCTAssertEqual(decoded.frame, 15)
        XCTAssertEqual(decoded.total, 30)
        XCTAssertGreaterThan(decoded.footprintMB, 0.0)
    }
}
