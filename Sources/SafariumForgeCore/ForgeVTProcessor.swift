import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SafariumCore
import VideoToolbox

// MARK: - Pillar 4: Zero-Copy VTFrameProcessor Pre-Encode Suite (macOS 15.4–27)

public struct ForgeVTProcessorCapabilities: Codable, Sendable, Equatable {
    public let temporalNoiseFilter: Bool
    public let frameRateConversion: Bool
    public let opticalFlow: Bool
    public let motionBlur: Bool
    public let offlineSuperResolution: Bool
    public let lowLatencySuperResolution: Bool

    public static func probe() -> ForgeVTProcessorCapabilities {
        var tnf = false
        var frc = false
        var optFlow = false
        var mblur = false
        var offlineSR = false
        var llsr = false

        #if compiler(>=6.1)
        if #available(macOS 15.4, *) {
            frc = VTFrameRateConversionConfiguration.isSupported
            optFlow = VTOpticalFlowConfiguration.isSupported
            mblur = VTMotionBlurConfiguration.isSupported
        }
        #endif

        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            tnf = VTTemporalNoiseFilterConfiguration.isSupported
            offlineSR = VTSuperResolutionScalerConfiguration.isSupported
            llsr = VTLowLatencySuperResolutionScalerConfiguration.isSupported
        }
        #endif

        return ForgeVTProcessorCapabilities(
            temporalNoiseFilter: tnf,
            frameRateConversion: frc,
            opticalFlow: optFlow,
            motionBlur: mblur,
            offlineSuperResolution: offlineSR,
            lowLatencySuperResolution: llsr
        )
    }
}

// MARK: - Helper: Resolved IOSurface-backed PixelBuffer Pool

private func makeResolvedVTBufferPool(
    width: Int,
    height: Int,
    pixelFormat: OSType,
    requiredAttributes: [String: Any]
) throws -> CVPixelBufferPool {
    let base: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]
    var resolved: CFDictionary?
    let rSt = CVPixelBufferCreateResolvedAttributesDictionary(
        kCFAllocatorDefault,
        [requiredAttributes as CFDictionary, base as CFDictionary] as CFArray,
        &resolved
    )
    let finalAttrs = (rSt == kCVReturnSuccess && resolved != nil) ? resolved! : (base as CFDictionary)
    var pool: CVPixelBufferPool?
    let pSt = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, finalAttrs, &pool)
    guard pSt == kCVReturnSuccess, let pool else {
        throw SafariumError.encode("VTFrameProcessor CVPixelBufferPoolCreate failed (\(pSt))")
    }
    return pool
}

private func allocateFromPool(_ pool: CVPixelBufferPool) throws -> CVPixelBuffer {
    var out: CVPixelBuffer?
    let st = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
    guard st == kCVReturnSuccess, let out else {
        throw SafariumError.encode("VTFrameProcessor pool allocation failed (\(st))")
    }
    return out
}

// MARK: - Temporal Noise Filter (macOS 26+, Pre-Encode Denoise for Massive BD-Rate Gain!)

/// Hardware Neural/GPU Temporal Noise Filter (`VTTemporalNoiseFilterConfiguration`, macOS 26+).
/// Strips invisible sensor grain/noise before VideoToolbox encoding with automatic `hasDiscontinuity` reset on scene cuts.
public final class TemporalDenoiseSession {
    public let width: Int
    public let height: Int
    public let pixelFormat: OSType
    public let strength: Float
    public private(set) var framesProcessed: Int = 0
    public var isHardwareActive: Bool { impl != nil }

    private var impl: AnyObject?
    private var endClosure: (() -> Void)?

    public init(width: Int, height: Int, pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, strength: Float = 0.5) throws {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.strength = min(1.0, max(0.0, strength))

        #if compiler(>=6.2)
        if #available(macOS 26.0, *), VTTemporalNoiseFilterConfiguration.isSupported {
            if let state = try? TNFState(width: width, height: height, pixelFormat: pixelFormat) {
                self.impl = state
                self.endClosure = { [weak state] in state?.end() }
            }
        }
        #endif
    }

    deinit {
        end()
    }

    public func end() {
        endClosure?()
        endClosure = nil
        impl = nil
    }

    /// Processes a single frame in presentation order; falls back transparently to passthrough on macOS < 26.
    public func process(_ pixelBuffer: CVPixelBuffer, pts: CMTime, isSceneCut: Bool = false) throws -> CVPixelBuffer {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let state = impl as? TNFState {
            let out = try state.process(pixelBuffer, pts: pts, strength: strength, isSceneCut: isSceneCut)
            framesProcessed += 1
            return out
        }
        #endif
        framesProcessed += 1
        return pixelBuffer
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private final class TNFState {
        let processor: VTFrameProcessor
        let config: VTTemporalNoiseFilterConfiguration
        let dstPool: CVPixelBufferPool
        let srcPool: CVPixelBufferPool
        let outPool: CVPixelBufferPool
        let transferSession: VTPixelTransferSession
        let maxPrev: Int
        var prevHistory: [VTFrameProcessorFrame] = []
        let hwPixelFormat: OSType
        let callerPixelFormat: OSType
        var ended = false

        init(width: Int, height: Int, pixelFormat: OSType) throws {
            let supported = VTTemporalNoiseFilterConfiguration.supportedSourcePixelFormats
            // Prefer Lossless AFBC 8-bit ('&8v0') or 10-bit ('&xv0') matching caller depth, falling back to first supported format.
            let is10Bit = (pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                           pixelFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
            let preferred: OSType = is10Bit
                ? kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange
                : kCVPixelFormatType_Lossless_420YpCbCr8BiPlanarVideoRange
            let chosenHWFormat: OSType
            if supported.contains(pixelFormat) {
                chosenHWFormat = pixelFormat
            } else if supported.contains(preferred) {
                chosenHWFormat = preferred
            } else if let first = supported.first {
                chosenHWFormat = first
            } else {
                throw SafariumError.encode("VTTemporalNoiseFilterConfiguration has no supported source pixel formats")
            }

            guard let cfg = VTTemporalNoiseFilterConfiguration(
                frameWidth: width,
                frameHeight: height,
                sourcePixelFormat: chosenHWFormat
            ) else {
                throw SafariumError.encode("VTTemporalNoiseFilterConfiguration unsupported for \(width)x\(height)")
            }
            let proc = VTFrameProcessor()
            try proc.startSession(configuration: cfg)

            var xferOpt: VTPixelTransferSession?
            let xSt = VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &xferOpt)
            guard xSt == noErr, let xfer = xferOpt else {
                proc.endSession()
                throw SafariumError.encode("VTPixelTransferSessionCreate failed (\(xSt))")
            }

            self.processor = proc
            self.config = cfg
            self.transferSession = xfer
            self.hwPixelFormat = chosenHWFormat
            self.callerPixelFormat = pixelFormat
            self.maxPrev = max(0, min(4, cfg.previousFrameCount ?? 2))
            self.srcPool = try makeResolvedVTBufferPool(
                width: width,
                height: height,
                pixelFormat: chosenHWFormat,
                requiredAttributes: cfg.sourcePixelBufferAttributes
            )
            self.dstPool = try makeResolvedVTBufferPool(
                width: width,
                height: height,
                pixelFormat: chosenHWFormat,
                requiredAttributes: cfg.destinationPixelBufferAttributes
            )
            self.outPool = try makeResolvedVTBufferPool(
                width: width,
                height: height,
                pixelFormat: pixelFormat,
                requiredAttributes: [:]
            )
        }

        func end() {
            guard !ended else { return }
            ended = true
            prevHistory.removeAll()
            VTPixelTransferSessionInvalidate(transferSession)
            processor.endSession()
        }

        deinit { end() }

        func process(_ pb: CVPixelBuffer, pts: CMTime, strength: Float, isSceneCut: Bool) throws -> CVPixelBuffer {
            guard CVPixelBufferGetWidth(pb) == config.frameWidth,
                  CVPixelBufferGetHeight(pb) == config.frameHeight else {
                return pb
            }
            if isSceneCut {
                prevHistory.removeAll()
            }
            // Hardware blit into AFBC Lossless source IOSurface if pixel format differs
            let srcBuf: CVPixelBuffer
            if CVPixelBufferGetPixelFormatType(pb) == hwPixelFormat && CVPixelBufferGetIOSurface(pb) != nil {
                srcBuf = pb
            } else {
                let hwIn = try allocateFromPool(srcPool)
                let st = VTPixelTransferSessionTransferImage(transferSession, from: pb, to: hwIn)
                guard st == noErr else { return pb }
                srcBuf = hwIn
            }
            let dstBuf = try allocateFromPool(dstPool)
            guard let srcFrame = VTFrameProcessorFrame(buffer: srcBuf, presentationTimeStamp: pts),
                  let dstFrame = VTFrameProcessorFrame(buffer: dstBuf, presentationTimeStamp: pts) else {
                return pb
            }
            guard let params = VTTemporalNoiseFilterParameters(
                sourceFrame: srcFrame,
                nextFrames: [],
                previousFrames: prevHistory,
                destinationFrame: dstFrame,
                filterStrength: strength,
                hasDiscontinuity: isSceneCut
            ) else {
                return pb
            }
            let sem = DispatchSemaphore(value: 0)
            var procErr: Error?
            processor.process(parameters: params) { _, err in
                procErr = err
                sem.signal()
            }
            sem.wait()
            if let procErr {
                throw procErr
            }
            if maxPrev > 0 {
                prevHistory.append(srcFrame)
                if prevHistory.count > maxPrev {
                    prevHistory.removeFirst(prevHistory.count - maxPrev)
                }
            }
            // Return buffer in caller's expected pixelFormat (via zero-copy hardware VTPixelTransferSession)
            if CVPixelBufferGetPixelFormatType(pb) == hwPixelFormat {
                return dstBuf
            }
            let outBuf = try allocateFromPool(outPool)
            let outSt = VTPixelTransferSessionTransferImage(transferSession, from: dstBuf, to: outBuf)
            return (outSt == noErr) ? outBuf : dstBuf
        }
    }
    #endif
}

// MARK: - Optical Flow Frame Rate Conversion (macOS 15.4+, e.g. 24fps -> 60fps / 30fps -> 60fps)

public struct OpticalFlowRetimeReport: Codable, Sendable {
    public let inputPath: String
    public let outputPath: String
    public let sourceFPS: Double
    public let targetFPS: Double
    public let sourceFrames: Int
    public let outputFrames: Int
    public let hardwareOpticalFlowUsed: Bool
    public let outputBytes: Int64
    public let elapsedMs: Double
}

/// Hardware Optical-Flow Frame Rate Converter (`VTFrameRateConversionConfiguration`, macOS 15.4+).
public enum OpticalFlowRetimer {
    public static func retime(
        inputURL: URL,
        outputURL: URL,
        targetFPS: Double,
        codec: VideoCodec = .hevc10,
        bitrate: Int = 8_000_000,
        overwrite: Bool = false
    ) async throws -> OpticalFlowRetimeReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard targetFPS.isFinite, targetFPS >= 10.0, targetFPS <= 240.0 else {
            throw SafariumError.invalidState("targetFPS must be in 10...240, got \(targetFPS)")
        }
        try SafeFilePublisher.assertRegularReadableFile(inputURL)
        try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)

        let asset = AVURLAsset(url: inputURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SafariumError.invalidState("no video track in \(inputURL.lastPathComponent)")
        }
        let naturalSize = try await track.load(.naturalSize)
        let width = max(2, Int(abs(naturalSize.width).rounded()))
        let height = max(2, Int(abs(naturalSize.height).rounded()))
        let nomFPS = Double(try await track.load(.nominalFrameRate))
        let srcFPS = (nomFPS.isFinite && nomFPS > 0.1) ? nomFPS : 30.0

        // Decode source frames into IOSurface-backed NV12 buffers
        let reader = try AVAssetReader(asset: asset)
        let ro = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        ro.alwaysCopiesSampleData = false
        guard reader.canAdd(ro) else {
            throw SafariumError.encode("AVAssetReader cannot read source video for optical-flow retiming")
        }
        reader.add(ro)
        guard reader.startReading() else {
            throw SafariumError.encode("AVAssetReader startReading failed")
        }

        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }
        let tempURL = staging.fileURL("retime.\(codec.fileExtension)")
        let targetFileType: AVFileType = outputURL.pathExtension.lowercased() == "mov" ? .mov : codec.fileType

        let writer = try AVAssetWriter(url: tempURL, fileType: targetFileType)
        writer.shouldOptimizeForNetworkUse = true

        let outSettings: [String: Any]
        if codec.isProRes {
            outSettings = [
                AVVideoCodecKey: codec.avCodec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
        } else {
            var comp: [String: Any] = [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: Int(targetFPS.rounded()),
                AVVideoAllowFrameReorderingKey: true,
            ]
            if let prof = codec.defaultProfileLevel {
                comp[AVVideoProfileLevelKey] = prof
            }
            outSettings = [
                AVVideoCodecKey: codec.avCodec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: comp,
            ]
        }
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: outSettings)
        vInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
        )
        guard writer.canAdd(vInput) else {
            throw SafariumError.encode("AVAssetWriter cannot add retimed video input")
        }
        writer.add(vInput)
        guard writer.startWriting() else {
            throw SafariumError.encode("AVAssetWriter startWriting failed: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)

        let timescale: Int32 = 600_000
        let dstStep = 1.0 / targetFPS
        var srcCount = 0
        var outCount = 0
        var hwUsed = false

        func appendFrame(_ pb: CVPixelBuffer, atSeconds sec: Double) async throws {
            while !vInput.isReadyForMoreMediaData {
                if writer.status != .writing {
                    throw SafariumError.encode("retime writer stopped: \(writer.error?.localizedDescription ?? "?")")
                }
                try await Task.sleep(nanoseconds: 500_000)
            }
            let pts = CMTime(seconds: sec, preferredTimescale: timescale)
            guard adaptor.append(pb, withPresentationTime: pts) else {
                throw SafariumError.encode("retime adaptor append failed: \(writer.error?.localizedDescription ?? "?")")
            }
            outCount += 1
        }

        // Pull pairs of consecutive source frames and interpolate intermediate phases via VTFrameRateConversion
        var prevPB: CVPixelBuffer?
        var prevPTS: Double = 0
        var nextOutSec: Double = 0

        #if compiler(>=6.1)
        var frcProc: AnyObject?
        var frcDstPool: CVPixelBufferPool?
        var frcEnd: (() -> Void)?
        if #available(macOS 15.4, *), VTFrameRateConversionConfiguration.isSupported {
            if let cfg = VTFrameRateConversionConfiguration(
                frameWidth: width,
                frameHeight: height,
                usePrecomputedFlow: false,
                qualityPrioritization: .quality,
                revision: VTFrameRateConversionConfiguration.defaultRevision
            ) {
                let proc = VTFrameProcessor()
                if (try? proc.startSession(configuration: cfg)) != nil,
                   let pool = try? makeResolvedVTBufferPool(
                    width: width,
                    height: height,
                    pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    requiredAttributes: cfg.destinationPixelBufferAttributes
                   ) {
                    frcProc = proc
                    frcDstPool = pool
                    frcEnd = { proc.endSession() }
                    hwUsed = true
                }
            }
        }
        defer { frcEnd?() }
        #endif

        while let sb = autoreleasepool(invoking: { ro.copyNextSampleBuffer() }) {
            guard let curPB = CMSampleBufferGetImageBuffer(sb) else { continue }
            let curPTS = CMSampleBufferGetPresentationTimeStamp(sb).seconds
            srcCount += 1

            if let pPB = prevPB {
                let span = max(1e-6, curPTS - prevPTS)
                var phases: [Float] = []
                var phaseTimes: [Double] = []
                while nextOutSec < curPTS - 1e-6 {
                    let alpha = Float((nextOutSec - prevPTS) / span)
                    if alpha <= 0.001 {
                        try await appendFrame(pPB, atSeconds: nextOutSec)
                    } else if alpha >= 0.999 {
                        try await appendFrame(curPB, atSeconds: nextOutSec)
                    } else {
                        phases.append(alpha)
                        phaseTimes.append(nextOutSec)
                    }
                    nextOutSec += dstStep
                }

                if !phases.isEmpty {
                    #if compiler(>=6.1)
                    if #available(macOS 15.4, *),
                       let proc = frcProc as? VTFrameProcessor,
                       let pool = frcDstPool,
                       let f0 = VTFrameProcessorFrame(buffer: pPB, presentationTimeStamp: CMTime(seconds: prevPTS, preferredTimescale: timescale)),
                       let f1 = VTFrameProcessorFrame(buffer: curPB, presentationTimeStamp: CMTime(seconds: curPTS, preferredTimescale: timescale)) {
                        var dstFrames: [VTFrameProcessorFrame] = []
                        var dstBufs: [CVPixelBuffer] = []
                        for t in phaseTimes {
                            let b = try allocateFromPool(pool)
                            if let df = VTFrameProcessorFrame(buffer: b, presentationTimeStamp: CMTime(seconds: t, preferredTimescale: timescale)) {
                                dstBufs.append(b)
                                dstFrames.append(df)
                            }
                        }
                        if dstFrames.count == phases.count,
                           let params = VTFrameRateConversionParameters(
                            sourceFrame: f0,
                            nextFrame: f1,
                            opticalFlow: nil,
                            interpolationPhase: phases,
                            submissionMode: (srcCount == 2) ? .sequential : .sequential,
                            destinationFrames: dstFrames
                           ) {
                            _ = try await proc.process(parameters: params)
                            for (i, b) in dstBufs.enumerated() {
                                try await appendFrame(b, atSeconds: phaseTimes[i])
                            }
                        } else {
                            for (i, a) in phases.enumerated() {
                                try await appendFrame(a < 0.5 ? pPB : curPB, atSeconds: phaseTimes[i])
                            }
                        }
                    } else {
                        for (i, a) in phases.enumerated() {
                            try await appendFrame(a < 0.5 ? pPB : curPB, atSeconds: phaseTimes[i])
                        }
                    }
                    #else
                    for (i, a) in phases.enumerated() {
                        try await appendFrame(a < 0.5 ? pPB : curPB, atSeconds: phaseTimes[i])
                    }
                    #endif
                }
            } else {
                nextOutSec = curPTS
            }
            prevPB = curPB
            prevPTS = curPTS
        }
        reader.cancelReading()

        if let lastPB = prevPB {
            try await appendFrame(lastPB, atSeconds: nextOutSec)
        }

        vInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw SafariumError.encode("retime finishWriting failed: \(writer.error?.localizedDescription ?? "?")")
        }

        try SafeFilePublisher.publish(tempURL: tempURL, to: outputURL, overwrite: overwrite)
        let outBytes = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0

        return OpticalFlowRetimeReport(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            sourceFPS: (srcFPS * 1000).rounded() / 1000,
            targetFPS: targetFPS,
            sourceFrames: srcCount,
            outputFrames: outCount,
            hardwareOpticalFlowUsed: hwUsed,
            outputBytes: outBytes,
            elapsedMs: (elapsedMs * 100).rounded() / 100
        )
    }
}

// MARK: - Optical Flow Motion Blur Session (macOS 15.4+)

/// Hardware optical-flow cinematic Motion Blur processor (`VTMotionBlurConfiguration`, macOS 15.4+).
public final class MotionBlurSession {
    public let width: Int
    public let height: Int
    public let strength: Int
    public var isHardwareActive: Bool { impl != nil }

    private var impl: AnyObject?
    private var endClosure: (() -> Void)?

    public init(width: Int, height: Int, strength: Int = 50) {
        self.width = width
        self.height = height
        self.strength = max(1, min(100, strength))

        #if compiler(>=6.1)
        if #available(macOS 15.4, *), VTMotionBlurConfiguration.isSupported {
            if let state = try? MBState(width: width, height: height) {
                self.impl = state
                self.endClosure = { [weak state] in state?.end() }
            }
        }
        #endif
    }

    deinit { end() }

    public func end() {
        endClosure?()
        endClosure = nil
        impl = nil
    }

    public func process(
        current: CVPixelBuffer,
        previous: CVPixelBuffer?,
        next: CVPixelBuffer?,
        pts: CMTime,
        previousPTS: CMTime? = nil,
        nextPTS: CMTime? = nil
    ) throws -> CVPixelBuffer {
        #if compiler(>=6.1)
        if #available(macOS 15.4, *), let state = impl as? MBState {
            return try state.process(
                current: current,
                previous: previous,
                next: next,
                pts: pts,
                previousPTS: previousPTS,
                nextPTS: nextPTS,
                strength: strength
            )
        }
        #endif
        return current
    }

    #if compiler(>=6.1)
    @available(macOS 15.4, *)
    private final class MBState {
        let processor: VTFrameProcessor
        let dstPool: CVPixelBufferPool
        var ended = false

        init(width: Int, height: Int) throws {
            guard let cfg = VTMotionBlurConfiguration(
                frameWidth: width,
                frameHeight: height,
                usePrecomputedFlow: false,
                qualityPrioritization: .quality,
                revision: VTMotionBlurConfiguration.defaultRevision
            ) else {
                throw SafariumError.encode("VTMotionBlurConfiguration unsupported")
            }
            let proc = VTFrameProcessor()
            try proc.startSession(configuration: cfg)
            self.processor = proc
            self.dstPool = try makeResolvedVTBufferPool(
                width: width,
                height: height,
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                requiredAttributes: cfg.destinationPixelBufferAttributes
            )
        }

        func end() {
            guard !ended else { return }
            ended = true
            processor.endSession()
        }

        deinit { end() }

        func process(
            current: CVPixelBuffer,
            previous: CVPixelBuffer?,
            next: CVPixelBuffer?,
            pts: CMTime,
            previousPTS: CMTime?,
            nextPTS: CMTime?,
            strength: Int
        ) throws -> CVPixelBuffer {
            guard let srcFrame = VTFrameProcessorFrame(buffer: current, presentationTimeStamp: pts) else {
                return current
            }
            let prevFrame = previous.flatMap { VTFrameProcessorFrame(buffer: $0, presentationTimeStamp: previousPTS ?? pts) }
            let nextFrame = next.flatMap { VTFrameProcessorFrame(buffer: $0, presentationTimeStamp: nextPTS ?? pts) }
            let dstBuf = try allocateFromPool(dstPool)
            guard let dstFrame = VTFrameProcessorFrame(buffer: dstBuf, presentationTimeStamp: pts),
                  let params = VTMotionBlurParameters(
                    sourceFrame: srcFrame,
                    nextFrame: nextFrame,
                    previousFrame: prevFrame,
                    nextOpticalFlow: nil,
                    previousOpticalFlow: nil,
                    motionBlurStrength: strength,
                    submissionMode: .sequential,
                    destinationFrame: dstFrame
                  ) else {
                return current
            }
            let sem = DispatchSemaphore(value: 0)
            var procErr: Error?
            processor.process(parameters: params) { _, err in
                procErr = err
                sem.signal()
            }
            sem.wait()
            if let procErr {
                throw procErr
            }
            return dstBuf
        }
    }
    #endif
}

// MARK: - Helper: Plane-safe CVPixelBuffer Copy

private func copyPixelBufferData(from src: CVPixelBuffer, to dst: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(src, .readOnly)
    CVPixelBufferLockBaseAddress(dst, [])
    defer {
        CVPixelBufferUnlockBaseAddress(dst, [])
        CVPixelBufferUnlockBaseAddress(src, .readOnly)
    }
    if CVPixelBufferIsPlanar(src) && CVPixelBufferIsPlanar(dst) {
        let planes = min(CVPixelBufferGetPlaneCount(src), CVPixelBufferGetPlaneCount(dst))
        for p in 0..<planes {
            guard let sBase = CVPixelBufferGetBaseAddressOfPlane(src, p),
                  let dBase = CVPixelBufferGetBaseAddressOfPlane(dst, p) else { continue }
            let h = min(CVPixelBufferGetHeightOfPlane(src, p), CVPixelBufferGetHeightOfPlane(dst, p))
            let sBpr = CVPixelBufferGetBytesPerRowOfPlane(src, p)
            let dBpr = CVPixelBufferGetBytesPerRowOfPlane(dst, p)
            let copyBytes = min(sBpr, dBpr)
            for y in 0..<h {
                memcpy(dBase.advanced(by: y * dBpr), sBase.advanced(by: y * sBpr), copyBytes)
            }
        }
    } else if let sBase = CVPixelBufferGetBaseAddress(src), let dBase = CVPixelBufferGetBaseAddress(dst) {
        let h = min(CVPixelBufferGetHeight(src), CVPixelBufferGetHeight(dst))
        let sBpr = CVPixelBufferGetBytesPerRow(src)
        let dBpr = CVPixelBufferGetBytesPerRow(dst)
        let copyBytes = min(sBpr, dBpr)
        for y in 0..<h {
            memcpy(dBase.advanced(by: y * dBpr), sBase.advanced(by: y * sBpr), copyBytes)
        }
    }
}
