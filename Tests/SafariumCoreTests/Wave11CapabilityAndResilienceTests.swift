import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Metal
import SafariumCore
import XCTest

final class Wave11CapabilityAndResilienceTests: XCTestCase {

    // MARK: - Helper

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf-wave11-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Wave 11A: EncoderCapabilityProfiler Tests

    func testEnumerateEncodersReturnsRealAppleEncoders() {
        let encoders = EncoderCapabilityProfiler.enumerateEncoders()
        XCTAssertFalse(encoders.isEmpty, "VTCopyVideoEncoderList should return real macOS VideoToolbox encoders")

        let fourCCs = Set(encoders.map { $0.codecFourCC.lowercased() })
        XCTAssertTrue(fourCCs.contains("avc1"), "Expected H.264 (avc1) encoder in VideoToolbox list")
        XCTAssertTrue(fourCCs.contains("hvc1"), "Expected HEVC (hvc1) encoder in VideoToolbox list")

        for enc in encoders {
            XCTAssertFalse(enc.encoderID.isEmpty, "Encoder ID should be non-empty for \(enc.codecFourCC)")
            XCTAssertFalse(enc.codecFourCC.isEmpty, "Codec FourCC should be non-empty")
        }
    }

    func testProbeLiveProducesHonestSnapshotAndValidatesRequirements() throws {
        let snapshot = EncoderCapabilityProfiler.probeLive(useCache: false)

        XCTAssertEqual(snapshot.schemaVersion, EncoderCapabilityProfiler.currentSchemaVersion)
        XCTAssertFalse(snapshot.machineModel.isEmpty)
        XCTAssertFalse(snapshot.chipName.isEmpty)
        XCTAssertFalse(snapshot.osVersion.isEmpty)
        XCTAssertFalse(snapshot.osBuild.isEmpty)
        XCTAssertGreaterThan(snapshot.physicalMemoryBytes, 0)
        XCTAssertGreaterThan(snapshot.cpuCount, 0)
        XCTAssertFalse(snapshot.availableEncoders.isEmpty)

        // H.264 and HEVC must exist with real encoderIDs and real propertyProbes.
        let h264 = try XCTUnwrap(snapshot.profile(for: "avc1"))
        XCTAssertTrue(h264.isAvailable)
        XCTAssertNotNil(h264.encoderID)
        XCTAssertGreaterThanOrEqual(h264.maxWidth, 1920)
        XCTAssertGreaterThanOrEqual(h264.maxHeight, 1080)
        XCTAssertFalse(h264.propertyProbes.isEmpty)

        let probedKeys = Set(h264.propertyProbes.map { $0.key })
        XCTAssertTrue(probedKeys.contains("MultiPassStorage"))
        XCTAssertTrue(probedKeys.contains("SpatialAdaptiveQPLevel"))
        XCTAssertTrue(probedKeys.contains("BaseFrameQP"))
        XCTAssertTrue(probedKeys.contains("AllowOpenGOP"))
        XCTAssertTrue(probedKeys.contains("MaxKeyFrameInterval"))
        XCTAssertTrue(probedKeys.contains("DataRateLimits"))
        XCTAssertTrue(probedKeys.contains("Quality"))
        XCTAssertTrue(probedKeys.contains("PreserveDynamicHDRMetadata"))

        let hevc = try XCTUnwrap(snapshot.profile(for: "hvc1"))
        XCTAssertTrue(hevc.isAvailable)
        XCTAssertNotNil(hevc.encoderID)
        XCTAssertFalse(hevc.propertyProbes.isEmpty)

        let prores422 = try XCTUnwrap(snapshot.profile(for: "apcn"))
        XCTAssertTrue(prores422.isAvailable)
        XCTAssertTrue(prores422.supports422)
        XCTAssertTrue(prores422.supportsMain10)

        let prores4444 = try XCTUnwrap(snapshot.profile(for: "ap4h"))
        XCTAssertTrue(prores4444.isAvailable)
        XCTAssertTrue(prores4444.supports444)
        XCTAssertTrue(prores4444.supportsAlpha)

        // AV1 hardware reporting must be completely honest:
        // hardwareAccelerated can only be true if VTCopyVideoEncoderList / live HW session genuinely supports av01.
        let av1 = try XCTUnwrap(snapshot.profile(for: "av01"))
        let enumeratedAV1HW = snapshot.availableEncoders.contains {
            $0.codecFourCC.lowercased() == "av01" && $0.isHardwareAccelerated
        }
        if !enumeratedAV1HW {
            XCTAssertFalse(av1.hardwareAccelerated, "av01 must not claim hardware acceleration when none is enumerated")
        }

        // Codable JSON round-trip.
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(EncoderCapabilitySnapshot.self, from: encoded)
        XCTAssertEqual(decoded.machineModel, snapshot.machineModel)
        XCTAssertEqual(decoded.codecs.count, snapshot.codecs.count)

        // ValidateRequirement succeeds for supported codec and fails closed for bogus/unsupported requirements.
        let validatedHEVC = try EncoderCapabilityProfiler.validateRequirement(
            codecFourCC: "hevc",
            requireHardware: hevc.hardwareAccelerated,
            requireMultipass: false,
            require10Bit: hevc.supportsMain10,
            snapshot: snapshot
        )
        XCTAssertEqual(validatedHEVC.codecFourCC, "hvc1")

        XCTAssertThrowsError(
            try EncoderCapabilityProfiler.validateRequirement(
                codecFourCC: "zzzz",
                requireHardware: false,
                requireMultipass: false,
                require10Bit: false,
                snapshot: snapshot
            )
        ) { error in
            guard case EncoderCapabilityError.codecUnavailable(let fourCC, _) = error else {
                XCTFail("Expected codecUnavailable, got \(error)")
                return
            }
            XCTAssertEqual(fourCC, "zzzz")
        }

        if !av1.hardwareAccelerated {
            XCTAssertThrowsError(
                try EncoderCapabilityProfiler.validateRequirement(
                    codecFourCC: "av01",
                    requireHardware: true,
                    requireMultipass: false,
                    require10Bit: false,
                    snapshot: snapshot
                )
            )
        }
    }

    // MARK: - Wave 11D: FrameLease, FrameLeasePool, Metadata & ZeroCopyTelemetry Tests

    func testFrameLeasePoolZeroCopyMetalTexturesAndMetadataRoundTrip() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available")
        }
        var cacheOpt: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cacheOpt)
        XCTAssertEqual(cacheStatus, kCVReturnSuccess)
        let textureCache = try XCTUnwrap(cacheOpt)

        let telemetry = ZeroCopyTelemetry()
        let pool = try FrameLeasePool(
            width: 320,
            height: 180,
            pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            minimumBufferCount: 2,
            telemetry: telemetry
        )

        // Synthetic 24-byte Mastering Display Color Volume (SMPTE ST 2086) + 4-byte Content Light Level Info.
        let mdcv = Data((0..<24).map { UInt8($0 + 1) })
        let clli = Data([0x03, 0xE8, 0x01, 0x90]) // 1000 nits MaxCLL, 400 nits MaxFALL
        let amve = Data([0x00, 0x00, 0x00, 0x64, 0x3D, 0x13, 0x40, 0x42])

        let hdrMeta = FrameColorMetadata.bt2020PQ(
            bitDepth: 10,
            masteringDisplayData: mdcv,
            contentLightLevelData: clli,
            ambientViewingData: amve,
            hasDynamicHDR: true,
            edrHeadroom: 4.0
        )

        let pts = CMTime(value: 1, timescale: 30)
        let dur = CMTime(value: 1, timescale: 30)

        let lease = try pool.lease(metadata: hdrMeta, pts: pts, duration: dur)
        XCTAssertTrue(lease.isIOSurfaceBacked, "FrameLeasePool buffers must be IOSurface-backed")
        XCTAssertNotNil(lease.iosurface)
        XCTAssertEqual(lease.width, 320)
        XCTAssertEqual(lease.height, 180)
        XCTAssertEqual(lease.pts, pts)
        XCTAssertEqual(lease.duration, dur)

        // Bind zero-copy luma (plane 0) and chroma (plane 1) Metal textures.
        let luma = try lease.lumaTexture(cache: textureCache)
        let chroma = try lease.chromaTexture(cache: textureCache)

        XCTAssertEqual(luma.width, 320)
        XCTAssertEqual(luma.height, 180)
        XCTAssertEqual(luma.pixelFormat, .r16Unorm)
        XCTAssertEqual(chroma.width, 160)
        XCTAssertEqual(chroma.height, 90)
        XCTAssertEqual(chroma.pixelFormat, .rg16Unorm)

        // Re-fetching cached textures should not allocate additional CVMetalTextures.
        _ = try lease.lumaTexture(cache: textureCache)
        _ = try lease.chromaTexture(cache: textureCache)

        let snap = telemetry.snapshot()
        XCTAssertEqual(snap.cpuReadbacks, 0)
        XCTAssertEqual(snap.pixelBufferCopies, 0)
        XCTAssertEqual(snap.leasesCreated, 1)
        XCTAssertEqual(snap.metalTexturesCreated, 2)
        try telemetry.assertBudget(maxCPUReadbacks: 0, maxCopies: 0)

        // Verify full FrameColorMetadata round-trip directly from CVPixelBuffer attachments.
        let roundTripped = FrameColorMetadata.from(pixelBuffer: lease.pixelBuffer)
        XCTAssertEqual(roundTripped, hdrMeta)
        XCTAssertEqual(roundTripped.masteringDisplayData, mdcv)
        XCTAssertEqual(roundTripped.contentLightLevelData, clli)
        XCTAssertEqual(roundTripped.ambientViewingData, amve)
        XCTAssertTrue(roundTripped.hasDynamicHDR)
        XCTAssertEqual(roundTripped.edrHeadroom, 4.0)

        // Verify applying BT.709 SDR metadata cleanly strips stale HDR mastering tags.
        let sdrMeta = FrameColorMetadata.bt709SDR()
        sdrMeta.apply(to: lease.pixelBuffer)
        let readAfterSDR = FrameColorMetadata.from(pixelBuffer: lease.pixelBuffer)
        XCTAssertEqual(readAfterSDR, sdrMeta)
        XCTAssertNil(readAfterSDR.masteringDisplayData)
        XCTAssertNil(readAfterSDR.contentLightLevelData)
        XCTAssertFalse(readAfterSDR.hasDynamicHDR)
        XCTAssertNil(readAfterSDR.edrHeadroom)

        // Inject a CPU readback and verify assertBudget fails closed.
        telemetry.recordCPUReadback()
        XCTAssertThrowsError(try telemetry.assertBudget(maxCPUReadbacks: 0, maxCopies: 0)) { error in
            XCTAssertEqual(error as? ZeroCopyBudgetError, .cpuReadbackBudgetExceeded(actual: 1, maxAllowed: 0))
        }

        // Inject a pixel buffer copy after reset and verify copy budget enforcement.
        telemetry.reset()
        XCTAssertEqual(telemetry.snapshot(), ZeroCopyCounters())
        telemetry.recordPixelBufferCopy(2)
        XCTAssertThrowsError(try telemetry.assertBudget(maxCPUReadbacks: 0, maxCopies: 1)) { error in
            XCTAssertEqual(error as? ZeroCopyBudgetError, .pixelBufferCopyBudgetExceeded(actual: 2, maxAllowed: 1))
        }
    }

    // MARK: - Wave 12C: PipelineStateMachine Tests

    func testPipelineStateMachineCancellationRunsLIFOCleanupsAndBlocksTransitions() throws {
        let sm = PipelineStateMachine()
        XCTAssertEqual(sm.phase, .idle)

        try sm.transition(to: .probing)
        try sm.transition(to: .encoding)
        XCTAssertEqual(sm.phase, .encoding)

        // Backward transition must fail.
        XCTAssertThrowsError(try sm.transition(to: .probing)) { error in
            XCTAssertEqual(
                error as? PipelineResilienceError,
                .invalidTransition(from: .encoding, to: .probing)
            )
        }

        final class LockedBox<T>: @unchecked Sendable {
            private let lock = NSLock()
            private var value: T
            init(_ value: T) { self.value = value }
            func mutate(_ body: (inout T) -> Void) {
                lock.lock()
                body(&value)
                lock.unlock()
            }
            func get() -> T {
                lock.lock()
                defer { lock.unlock() }
                return value
            }
        }

        let cleanupOrder = LockedBox<[Int]>([])

        sm.registerCleanup { cleanupOrder.mutate { $0.append(1) } }
        sm.registerCleanup { cleanupOrder.mutate { $0.append(2) } }
        sm.registerCleanup { cleanupOrder.mutate { $0.append(3) } }

        sm.cancel(reason: "User interrupted render")
        XCTAssertTrue(sm.isCancelled)
        XCTAssertEqual(sm.phase, .cancelled)
        XCTAssertEqual(sm.cancellationReason, "User interrupted render")

        // Calling cancel() again must be idempotent (cleanups run exactly once).
        sm.cancel(reason: "Duplicate cancel")

        XCTAssertEqual(cleanupOrder.get(), [3, 2, 1], "Cleanup handlers must execute in strict LIFO order")

        // checkCancelled and further transitions must throw cancelled.
        XCTAssertThrowsError(try sm.checkCancelled()) { error in
            XCTAssertEqual(
                error as? PipelineResilienceError,
                .cancelled(reason: "User interrupted render")
            )
        }
        XCTAssertThrowsError(try sm.transition(to: .muxing)) { error in
            XCTAssertEqual(
                error as? PipelineResilienceError,
                .cancelled(reason: "User interrupted render")
            )
        }

        // Late-registered cleanup on an already-cancelled machine runs immediately.
        let lateRan = LockedBox<Bool>(false)
        sm.registerCleanup { lateRan.mutate { $0 = true } }
        XCTAssertTrue(lateRan.get())
    }

    // MARK: - Wave 12C: AtomicOutputPublisher Tests

    func testAtomicOutputPublisherSuccessRollbackAndOverwritePolicy() throws {
        let dir = try makeTempDir("atomic-publish")
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Disk space preflight check.
        let freeBytes = try AtomicOutputPublisher.checkAvailableDiskSpace(at: dir, requiredBytes: 1024)
        XCTAssertGreaterThanOrEqual(freeBytes, 1024)
        XCTAssertThrowsError(
            try AtomicOutputPublisher.checkAvailableDiskSpace(at: dir, requiredBytes: UInt64.max)
        ) { error in
            guard case PipelineResilienceError.insufficientDiskSpace = error else {
                XCTFail("Expected insufficientDiskSpace, got \(error)")
                return
            }
        }

        // 2. Clean atomic publish on success.
        let dest = dir.appendingPathComponent("master.mp4")
        let publisher = AtomicOutputPublisher(destinationURL: dest, overwrite: false, minimumRequiredDiskBytes: 1024)
        let payloadV1 = Data("SAFARIUM-V1-PAYLOAD".utf8)

        let publishedURL = try publisher.publish { tempURL in
            XCTAssertTrue(tempURL.lastPathComponent.hasPrefix(".safarium-tmp-"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
            try payloadV1.write(to: tempURL)
        }
        XCTAssertEqual(publishedURL, dest)
        XCTAssertEqual(try Data(contentsOf: dest), payloadV1)

        // Ensure no leftover temp files exist.
        let filesAfterV1 = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(filesAfterV1, ["master.mp4"])

        // 3. Overwrite == false rejects collision and leaves original file untouched.
        XCTAssertThrowsError(
            try publisher.publish { tempURL in
                try Data("SHOULD-NOT-REPLACE".utf8).write(to: tempURL)
            }
        ) { error in
            XCTAssertEqual(error as? PipelineResilienceError, .destinationAlreadyExists(path: dest.path))
        }
        XCTAssertEqual(try Data(contentsOf: dest), payloadV1)

        // 4. Injected error during write deletes temp file and leaves destination untouched (even when overwrite == true).
        enum InjectedWriteError: Error { case diskFlushFailed }
        let overwritePublisher = AtomicOutputPublisher(destinationURL: dest, overwrite: true)
        var capturedTempURL: URL?

        XCTAssertThrowsError(
            try overwritePublisher.publish { tempURL in
                capturedTempURL = tempURL
                try Data("PARTIAL-CORRUPT-DATA".utf8).write(to: tempURL)
                throw InjectedWriteError.diskFlushFailed
            }
        )
        if let tempURL = capturedTempURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path), "Temp file must be deleted on error")
        }
        XCTAssertEqual(try Data(contentsOf: dest), payloadV1, "Existing destination must remain untouched on error")

        // 5. Cancellation during staging deletes temp file and leaves destination untouched.
        let cancelSM = PipelineStateMachine()
        var cancelTempURL: URL?
        XCTAssertThrowsError(
            try overwritePublisher.publish(stateMachine: cancelSM) { tempURL in
                cancelTempURL = tempURL
                try Data("CANCELLED-DATA".utf8).write(to: tempURL)
                cancelSM.cancel(reason: "Aborted mid-mux")
            }
        ) { error in
            XCTAssertEqual(error as? PipelineResilienceError, .cancelled(reason: "Aborted mid-mux"))
        }
        if let tempURL = cancelTempURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path), "Temp file must be deleted on cancel")
        }
        XCTAssertEqual(try Data(contentsOf: dest), payloadV1)

        // 6. Overwrite == true atomically replaces destination on clean success.
        let payloadV2 = Data("SAFARIUM-V2-ATOMIC-REPLACEMENT".utf8)
        try overwritePublisher.publish { tempURL in
            try payloadV2.write(to: tempURL)
        }
        XCTAssertEqual(try Data(contentsOf: dest), payloadV2)
        let filesAfterV2 = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(filesAfterV2, ["master.mp4"])
    }

    // MARK: - Wave 12C: BoundedFrameQueue Tests

    func testBoundedFrameQueueBackpressureDrainAndCancelUnblock() {
        // 1. Backpressure & FIFO drain.
        let queue = BoundedFrameQueue<Int>(capacity: 2)
        XCTAssertTrue(queue.enqueue(10))
        XCTAssertTrue(queue.enqueue(20))
        XCTAssertEqual(queue.highWaterMark, 2)

        let thirdEnqueued = expectation(description: "Third enqueue unblocks after dequeue")
        let producer = DispatchQueue(label: "sf.test.bounded.producer")
        producer.async {
            let ok = queue.enqueue(30)
            XCTAssertTrue(ok)
            queue.finish()
            thirdEnqueued.fulfill()
        }

        // Brief pause to ensure producer hits capacity backpressure.
        Thread.sleep(forTimeInterval: 0.03)
        XCTAssertEqual(queue.count, 2)

        // Drain all 3 items in strict FIFO order.
        XCTAssertEqual(queue.dequeue(), 10)
        wait(for: [thirdEnqueued], timeout: 2.0)
        XCTAssertEqual(queue.dequeue(), 20)
        XCTAssertEqual(queue.dequeue(), 30)
        XCTAssertNil(queue.dequeue(), "Drained finished queue must return nil")
        XCTAssertEqual(queue.totalEnqueued, 3)
        XCTAssertEqual(queue.totalDequeued, 3)

        // 2. Immediate unblock on cancel() for blocked producer.
        let cancelQueue = BoundedFrameQueue<Int>(capacity: 1)
        XCTAssertTrue(cancelQueue.enqueue(1))

        let blockedProducerReturned = expectation(description: "Blocked producer returns false on cancel")
        producer.async {
            let ok = cancelQueue.enqueue(2)
            XCTAssertFalse(ok, "Enqueue unblocked by cancel() must return false")
            blockedProducerReturned.fulfill()
        }

        Thread.sleep(forTimeInterval: 0.03)
        cancelQueue.cancel()
        wait(for: [blockedProducerReturned], timeout: 2.0)
        XCTAssertTrue(cancelQueue.isCancelled)
        XCTAssertNil(cancelQueue.dequeue(), "Cancelled queue must immediately return nil")
    }

    // MARK: - Wave 12C: AudioSyncValidator Tests

    func testAudioSyncValidatorDetectsDriftAndVFRAnomaliesAndAcceptsAlignedAV() {
        let validator = AudioSyncValidator(sampleRate: 48_000, samplesPerAudioFrame: 1024)
        XCTAssertLessThan(validator.maxDriftMs, 22.0)
        XCTAssertGreaterThan(validator.maxDriftMs, 21.0)

        // Clean 30 fps timestamps (10 frames).
        let cleanPTS = (0..<10).map { CMTime(value: CMTimeValue($0), timescale: 30) }

        // 1. Aligned A/V: 3.000s video + 3.044s raw AAC with 2112 priming samples (44.0 ms) -> trimmed 3.000s (0 ms drift!).
        let aligned = validator.validate(
            videoStart: .zero,
            videoDuration: CMTime(seconds: 3.0, preferredTimescale: 600),
            audioStart: .zero,
            audioDuration: CMTime(seconds: 3.0 + (2112.0 / 48_000.0), preferredTimescale: 48_000),
            audioPrimingSamples: 2112,
            videoFrameTimestamps: cleanPTS,
            nominalFPS: 30.0
        )
        XCTAssertTrue(aligned.withinTolerance)
        XCTAssertTrue(aligned.vfrAnomalies.isEmpty)
        XCTAssertTrue(aligned.isPassed)
        XCTAssertLessThan(aligned.maxAbsDriftMs, 0.5)

        // 2. Drifted A/V: 45 ms duration drift (> 21.33 ms threshold) must fail.
        let drifted = validator.validate(
            videoStart: .zero,
            videoDuration: CMTime(seconds: 3.0, preferredTimescale: 600),
            audioStart: .zero,
            audioDuration: CMTime(seconds: 3.045, preferredTimescale: 48_000),
            audioPrimingSamples: 0,
            videoFrameTimestamps: cleanPTS,
            nominalFPS: 30.0
        )
        XCTAssertFalse(drifted.withinTolerance)
        XCTAssertFalse(drifted.isPassed)
        XCTAssertGreaterThan(drifted.maxAbsDriftMs, 40.0)

        // 3. VFR timestamp anomalies: duplicate PTS, non-monotonic PTS, and large gap must be caught.
        let anomalousPTS: [CMTime] = [
            CMTime(value: 0, timescale: 1000),
            CMTime(value: 33, timescale: 1000),
            CMTime(value: 33, timescale: 1000),  // duplicate_pts
            CMTime(value: 20, timescale: 1000),  // non_monotonic
            CMTime(value: 150, timescale: 1000), // large_gap
        ]
        let vfrReport = validator.validate(
            videoStart: .zero,
            videoDuration: CMTime(seconds: 1.0, preferredTimescale: 600),
            audioStart: .zero,
            audioDuration: CMTime(seconds: 1.0, preferredTimescale: 48_000),
            videoFrameTimestamps: anomalousPTS,
            nominalFPS: 30.0
        )
        XCTAssertTrue(vfrReport.withinTolerance)
        XCTAssertFalse(vfrReport.isPassed)
        let anomalyKinds = Set(vfrReport.vfrAnomalies.map { $0.kind })
        XCTAssertTrue(anomalyKinds.contains("duplicate_pts"))
        XCTAssertTrue(anomalyKinds.contains("non_monotonic"))
        XCTAssertTrue(anomalyKinds.contains("large_gap"))
    }
}
