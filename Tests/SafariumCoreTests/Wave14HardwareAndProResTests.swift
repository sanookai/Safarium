import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import SafariumCore
import XCTest

final class Wave14HardwareAndProResTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf-wave14-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func make422Buffers(count: Int, width: Int, height: Int) throws -> [CVPixelBuffer] {
        var result: [CVPixelBuffer] = []
        result.reserveCapacity(count)

        for idx in 0..<count {
            let pb = try ProResPipeline.makeIOSurfacePixelBuffer(
                width: width,
                height: height,
                pixelFormat: kCVPixelFormatType_422YpCbCr8,
                colorMetadata: .bt709SDR()
            )
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let bpr = CVPixelBufferGetBytesPerRow(pb)
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                // 2vuy byte order: Cb, Y0, Cr, Y1 per 2 pixels
                for y in 0..<height {
                    let row = ptr.advanced(by: y * bpr)
                    for pair in 0..<(width / 2) {
                        let off = pair * 4
                        let cb = UInt8(64 + ((pair + idx * 7) & 0x7F))
                        let cr = UInt8(64 + ((y + idx * 5) & 0x7F))
                        let y0 = UInt8(16 + (((y * 2 + pair + idx * 11) & 0xFF) * 219) / 255)
                        let y1 = UInt8(16 + (((y * 2 + pair + 1 + idx * 11) & 0xFF) * 219) / 255)
                        row[off] = cb
                        row[off + 1] = y0
                        row[off + 2] = cr
                        row[off + 3] = y1
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            result.append(pb)
        }
        return result
    }

    private func makeBGRAAlphaBuffers(count: Int, width: Int, height: Int) throws -> [CVPixelBuffer] {
        var result: [CVPixelBuffer] = []
        result.reserveCapacity(count)

        for idx in 0..<count {
            let pb = try ProResPipeline.makeIOSurfacePixelBuffer(
                width: width,
                height: height,
                pixelFormat: kCVPixelFormatType_32BGRA,
                colorMetadata: .bt709SDR()
            )
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb) {
                let bpr = CVPixelBufferGetBytesPerRow(pb)
                let ptr = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    let row = ptr.advanced(by: y * bpr)
                    for x in 0..<width {
                        let off = x * 4
                        // Deliberate non-opaque alpha gradient (transparent border, semi-transparent center, opaque strip)
                        let alpha: UInt8
                        if x < width / 4 {
                            alpha = 0
                        } else if x < width / 2 {
                            alpha = 96
                        } else if x < (3 * width) / 4 {
                            alpha = 180
                        } else {
                            alpha = 255
                        }
                        let premulR = UInt8((Int((x + idx * 13) & 0xFF) * Int(alpha)) / 255)
                        let premulG = UInt8((Int((y + idx * 7) & 0xFF) * Int(alpha)) / 255)
                        let premulB = UInt8((Int(((x ^ y) + idx * 19) & 0xFF) * Int(alpha)) / 255)
                        row[off] = premulB
                        row[off + 1] = premulG
                        row[off + 2] = premulR
                        row[off + 3] = alpha
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            result.append(pb)
        }
        return result
    }

    private func makeNV12Buffer(width: Int, height: Int, tenBit: Bool = false) throws -> CVPixelBuffer {
        let format: OSType = tenBit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: format,
        ]
        var pbOut: CVPixelBuffer?
        let st = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            format,
            attrs as CFDictionary,
            &pbOut
        )
        XCTAssertEqual(st, kCVReturnSuccess)
        return try XCTUnwrap(pbOut)
    }

    private func firstVideoTrackFourCC(at url: URL) throws -> String {
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        final class ResultBox: @unchecked Sendable {
            var fourCC: String?
            var error: Error?
        }
        let box = ResultBox()

        Task {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                if let track = tracks.first {
                    let descs = try await track.load(.formatDescriptions)
                    if let first = descs.first {
                        let subType = CMFormatDescriptionGetMediaSubType(first)
                        let bytes: [UInt8] = [
                            UInt8((subType >> 24) & 0xFF),
                            UInt8((subType >> 16) & 0xFF),
                            UInt8((subType >> 8) & 0xFF),
                            UInt8(subType & 0xFF),
                        ]
                        box.fourCC = String(bytes: bytes, encoding: .ascii)
                    }
                }
            } catch {
                box.error = error
            }
            semaphore.signal()
        }
        semaphore.wait()

        if let err = box.error {
            throw err
        }
        return try XCTUnwrap(box.fourCC)
    }

    // MARK: - Wave 14A: HardwareAutoTuner Tests

    func testHardwareAutoTunerCalibratesLiveHEVCConcurrency() throws {
        let report = HardwareAutoTuner.calibrateConcurrency(
            codec: .hevc,
            width: 320,
            height: 180,
            framesPerSession: 12,
            maxSessions: 3
        )

        XCTAssertEqual(report.codecFourCC, "hvc1")
        XCTAssertGreaterThanOrEqual(report.recommendedSessions, 1)
        XCTAssertLessThanOrEqual(report.recommendedSessions, 3)
        XCTAssertFalse(report.points.isEmpty, "Calibration must produce at least one live point")
        XCTAssertFalse(report.thermalState.isEmpty)
        XCTAssertFalse(report.stopReason.isEmpty)

        for (index, point) in report.points.enumerated() {
            XCTAssertEqual(point.sessions, index + 1)
            XCTAssertGreaterThan(point.totalFPS, 0.0, "Live VTCompressionSession burst must yield positive FPS")
            XCTAssertGreaterThan(point.perStreamFPS, 0.0)
            XCTAssertGreaterThan(point.wallMs, 0.0)
            XCTAssertGreaterThanOrEqual(point.cpuTimeMs, 0.0)
            XCTAssertGreaterThanOrEqual(point.estimatedJoulesPerFrame, 0.0)
            if index == 0 {
                XCTAssertEqual(point.gainOverPreviousPct, 0.0, accuracy: 1e-9)
            }
        }

        // Verify stopping invariant: if any point after index 0 had < 10% gain, it MUST be the final point
        // and recommendedSessions MUST stay at the previous concurrency level.
        if let firstSubThresholdIdx = report.points.indices.dropFirst().first(where: {
            report.points[$0].gainOverPreviousPct < HardwareAutoTuner.minimumGainThresholdPct
        }) {
            XCTAssertEqual(firstSubThresholdIdx, report.points.count - 1, "Calibration must stop immediately once gain < 10%")
            XCTAssertEqual(report.recommendedSessions, report.points[firstSubThresholdIdx - 1].sessions)
            XCTAssertTrue(report.stopReason.contains("below_10pct"))
        } else {
            XCTAssertEqual(report.recommendedSessions, report.points.last?.sessions)
        }

        // Round-trip Codable check
        let encoded = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(ConcurrencyCalibrationReport.self, from: encoded)
        XCTAssertEqual(decoded, report)
    }

    func testHardwareAutoTunerStopsWhenThroughputGainBelowTenPercent() {
        let points: [ConcurrencyCalibrationPoint] = [
            ConcurrencyCalibrationPoint(
                sessions: 1,
                totalFPS: 120.0,
                perStreamFPS: 120.0,
                wallMs: 100.0,
                cpuTimeMs: 40.0,
                estimatedJoulesPerFrame: 0.02,
                gainOverPreviousPct: 0.0
            ),
            ConcurrencyCalibrationPoint(
                sessions: 2,
                totalFPS: 210.0, // +75% gain -> accept 2
                perStreamFPS: 105.0,
                wallMs: 114.0,
                cpuTimeMs: 75.0,
                estimatedJoulesPerFrame: 0.018,
                gainOverPreviousPct: 75.0
            ),
            ConcurrencyCalibrationPoint(
                sessions: 3,
                totalFPS: 222.0, // +5.71% gain (< 10%) -> STOP and keep 2!
                perStreamFPS: 74.0,
                wallMs: 162.0,
                cpuTimeMs: 120.0,
                estimatedJoulesPerFrame: 0.022,
                gainOverPreviousPct: 5.714
            ),
            ConcurrencyCalibrationPoint(
                sessions: 4,
                totalFPS: 225.0,
                perStreamFPS: 56.25,
                wallMs: 213.0,
                cpuTimeMs: 170.0,
                estimatedJoulesPerFrame: 0.028,
                gainOverPreviousPct: 1.35
            ),
        ]

        let evaluation = HardwareAutoTuner.evaluateRecommendedSessions(from: points)
        XCTAssertEqual(evaluation.recommendedSessions, 2)
        XCTAssertTrue(evaluation.stopReason.contains("below_10pct"))
    }

    // MARK: - Wave 14A: ThermalHysteresisScheduler Tests

    func testThermalHysteresisStepsDownImmediatelyAndHoldsDuringCooldown() {
        let scheduler = ThermalHysteresisScheduler(
            powerBudget: .balanced,
            cooldownTicks: 3,
            initialThermalState: .nominal
        )

        // Baseline nominal concurrency equals maxCalibrated
        XCTAssertEqual(scheduler.recommendedConcurrency(maxCalibrated: 4), 4)
        XCTAssertEqual(scheduler.recommendedInterFramePauseMs(), 0.0)

        // Immediate step-down on .serious (4 -> 2)
        scheduler.updateThermalState(.serious)
        XCTAssertEqual(scheduler.recommendedConcurrency(maxCalibrated: 4), 2)
        XCTAssertGreaterThan(scheduler.recommendedInterFramePauseMs(), 0.0)

        // Immediate step-down on .critical (2 -> 1)
        scheduler.updateThermalState(.critical)
        XCTAssertEqual(scheduler.recommendedConcurrency(maxCalibrated: 4), 1)
        XCTAssertGreaterThanOrEqual(scheduler.recommendedInterFramePauseMs(), 20.0)

        // Cooldown tick 1 (.nominal): MUST hold at 1 (no oscillation!)
        scheduler.updateThermalState(.nominal)
        XCTAssertEqual(scheduler.recommendedConcurrency(maxCalibrated: 4), 1)
        XCTAssertEqual(scheduler.currentCooldownProgress, 1)

        // Cooldown tick 2 (.fair): MUST still hold at 1
        scheduler.updateThermalState(.fair)
        XCTAssertEqual(scheduler.recommendedConcurrency(maxCalibrated: 4), 1)
        XCTAssertEqual(scheduler.currentCooldownProgress, 2)

        // Brief spike back to .serious mid-cooldown resets streak to 0 and keeps concurrency at 1
        scheduler.updateThermalState(.serious)
        XCTAssertEqual(scheduler.currentCooldownProgress, 0)
        XCTAssertEqual(scheduler.recommendedConcurrency(maxCalibrated: 4), 1)

        // Now complete 3 consecutive healthy ticks (.nominal, .fair, .nominal) -> step up by 1 (1 -> 2)
        scheduler.updateThermalState(.nominal)
        XCTAssertEqual(scheduler.recommendedConcurrency(maxCalibrated: 4), 1)
        scheduler.updateThermalState(.fair)
        XCTAssertEqual(scheduler.recommendedConcurrency(maxCalibrated: 4), 1)
        scheduler.updateThermalState(.nominal)
        XCTAssertEqual(scheduler.recommendedConcurrency(maxCalibrated: 4), 2)
        XCTAssertEqual(scheduler.currentCooldownProgress, 0)

        // Low power budget caps concurrency at 1 and adds inter-frame pause even when nominal
        scheduler.setPowerBudget(.low)
        XCTAssertEqual(scheduler.recommendedConcurrency(maxCalibrated: 4), 1)
        XCTAssertGreaterThan(scheduler.recommendedInterFramePauseMs(), 0.0)
    }

    func testThermalSchedulerRecordsHonestEnergyProxySample() {
        let scheduler = ThermalHysteresisScheduler(
            powerBudget: .balanced,
            cooldownTicks: 3,
            initialThermalState: .nominal
        )

        let sample = scheduler.measureEnergySample(framesEncoded: 30) {
            var acc: UInt64 = 0
            for i in 0..<50_000 {
                acc &+= UInt64(i) &* 31
            }
            _ = acc
        }

        XCTAssertEqual(sample.framesEncoded, 30)
        XCTAssertGreaterThan(sample.wallSeconds, 0.0)
        XCTAssertGreaterThanOrEqual(sample.cpuSeconds, 0.0)
        XCTAssertGreaterThan(sample.estimatedJoules, 0.0)
        XCTAssertGreaterThan(sample.joulesPerFrame, 0.0)
        XCTAssertGreaterThan(sample.framesPerSecondPerWatt, 0.0)
        XCTAssertEqual(sample.thermalState, "nominal")
        XCTAssertTrue(sample.energyProxyNote.lowercased().contains("proxy"))
        XCTAssertEqual(scheduler.recordedEnergySamples.count, 1)
    }

    // MARK: - Wave 14B: ProRes Zero-4:2:0 Pipeline Tests

    func testProRes422HQEncodePreservesZero420Invariant() throws {
        let tempDir = try makeTempDir("prores422hq")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let width = 320
        let height = 180
        let frameCount = 8
        let buffers = try make422Buffers(count: frameCount, width: width, height: height)
        let outputURL = tempDir.appendingPathComponent("master_422hq.mov")

        let options = ProResEncodeOptions(
            tier: .hq,
            width: width,
            height: height,
            fps: 24.0,
            preserveAlpha: false,
            colorMetadata: .bt709SDR()
        )
        let result = try ProResPipeline.encodeFrames(buffers, to: outputURL, options: options)

        XCTAssertEqual(result.tier, ProResTier.hq.rawValue)
        XCTAssertEqual(result.fourCC, "apch")
        XCTAssertEqual(result.pixelFormatUsed, "2vuy")
        XCTAssertTrue(result.zero420Downconversion)
        XCTAssertFalse(result.preservesAlpha)
        XCTAssertEqual(result.framesEncoded, frameCount)
        XCTAssertGreaterThan(result.bytesWritten, 0)
        XCTAssertGreaterThan(result.elapsedMs, 0.0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let trackFourCC = try firstVideoTrackFourCC(at: outputURL)
        XCTAssertEqual(trackFourCC, "apch")
    }

    func testProRes4444EncodeWithAlphaPreservesZero420Invariant() throws {
        let tempDir = try makeTempDir("prores4444")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let width = 320
        let height = 180
        let frameCount = 8
        let buffers = try makeBGRAAlphaBuffers(count: frameCount, width: width, height: height)
        let outputURL = tempDir.appendingPathComponent("vfx_4444_alpha.mov")

        let options = ProResEncodeOptions(
            tier: .fourFourFourFour,
            width: width,
            height: height,
            fps: 30.0,
            preserveAlpha: true,
            colorMetadata: .bt709SDR()
        )
        let result = try ProResPipeline.encodeFrames(buffers, to: outputURL, options: options)

        XCTAssertEqual(result.tier, ProResTier.fourFourFourFour.rawValue)
        XCTAssertEqual(result.fourCC, "ap4h")
        XCTAssertEqual(result.pixelFormatUsed, "BGRA")
        XCTAssertTrue(result.zero420Downconversion)
        XCTAssertTrue(result.preservesAlpha)
        XCTAssertEqual(result.framesEncoded, frameCount)
        XCTAssertGreaterThan(result.bytesWritten, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let trackFourCC = try firstVideoTrackFourCC(at: outputURL)
        XCTAssertEqual(trackFourCC, "ap4h")
    }

    func testProResRejectsForbidden420BuffersStrictly() throws {
        let tempDir = try makeTempDir("prores-reject-420")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let nv12Buffer = try makeNV12Buffer(width: 320, height: 180, tenBit: false)
        let p010Buffer = try makeNV12Buffer(width: 320, height: 180, tenBit: true)

        // 1. NV12 into ProRes 4444 MUST throw forbidden420Subsampling
        let out4444 = tempDir.appendingPathComponent("should_not_exist_4444.mov")
        let opt4444 = ProResEncodeOptions(
            tier: .fourFourFourFour,
            width: 320,
            height: 180,
            fps: 30.0,
            preserveAlpha: true
        )
        XCTAssertThrowsError(try ProResPipeline.encodeFrames([nv12Buffer], to: out4444, options: opt4444)) { error in
            guard case ProResPipelineError.forbidden420Subsampling(let fmt, let tier) = error else {
                XCTFail("Expected ProResPipelineError.forbidden420Subsampling, got \(error)")
                return
            }
            XCTAssertEqual(fmt, "420v")
            XCTAssertEqual(tier, ProResTier.fourFourFourFour.rawValue)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out4444.path))

        // 2. NV12 into ProRes 422 HQ MUST also throw forbidden420Subsampling
        let out422 = tempDir.appendingPathComponent("should_not_exist_422.mov")
        let opt422 = ProResEncodeOptions(
            tier: .hq,
            width: 320,
            height: 180,
            fps: 30.0,
            preserveAlpha: false
        )
        XCTAssertThrowsError(try ProResPipeline.encodeFrames([nv12Buffer], to: out422, options: opt422)) { error in
            guard case ProResPipelineError.forbidden420Subsampling = error else {
                XCTFail("Expected ProResPipelineError.forbidden420Subsampling, got \(error)")
                return
            }
        }

        // 3. P010 (10-bit 4:2:0) into ProRes 4444 MUST also throw forbidden420Subsampling
        XCTAssertThrowsError(try ProResPipeline.encodeFrames([p010Buffer], to: out4444, options: opt4444)) { error in
            guard case ProResPipelineError.forbidden420Subsampling = error else {
                XCTFail("Expected ProResPipelineError.forbidden420Subsampling for P010, got \(error)")
                return
            }
        }
    }
}
