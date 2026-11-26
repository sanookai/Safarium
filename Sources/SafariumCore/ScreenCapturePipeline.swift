import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreText
import CoreVideo
import Foundation
import Metal
import ScreenCaptureKit
import VideoToolbox

// MARK: - Wave 16A: ScreenCaptureKit Zero-Copy Recorder (100% Apple Silicon Native)

/// Preflight check result for macOS ScreenCaptureKit recording access.
public struct ScreenCapturePreflight: Codable, Sendable, Equatable {
    public let hasPermission: Bool
    public let platformSupported: Bool
    public let notes: String

    public init(hasPermission: Bool, platformSupported: Bool, notes: String) {
        self.hasPermission = hasPermission
        self.platformSupported = platformSupported
        self.notes = notes
    }
}

/// Configuration for zero-copy screen capture and `ZeroCopyStreamRecorder`.
public struct ScreenCaptureConfig: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var codec: VideoCodec
    public var bitrate: Int
    public var captureAudio: Bool
    public var showCursor: Bool
    public var hudOverlayText: String?
    public var maxDurationSeconds: Double

    public init(
        width: Int = 1280,
        height: Int = 720,
        fps: Int = 30,
        codec: VideoCodec = .hevc10,
        bitrate: Int = 6_000_000,
        captureAudio: Bool = false,
        showCursor: Bool = true,
        hudOverlayText: String? = nil,
        maxDurationSeconds: Double = 10.0
    ) {
        let clampedW = max(16, (width / 2) * 2)
        let clampedH = max(16, (height / 2) * 2)
        self.width = clampedW
        self.height = clampedH
        self.fps = max(1, min(240, fps))
        self.codec = codec
        self.bitrate = max(200_000, bitrate)
        self.captureAudio = captureAudio
        self.showCursor = showCursor
        self.hudOverlayText = hudOverlayText
        self.maxDurationSeconds = max(0.1, maxDurationSeconds)
    }
}

/// Output summary produced by `ZeroCopyStreamRecorder.finish()` and `ScreenCapturePipeline.recordDisplay(...)`.
public struct ScreenCaptureReport: Codable, Sendable, Equatable {
    public let outputPath: String
    public let width: Int
    public let height: Int
    public let framesWritten: Int
    public let droppedFrames: Int
    public let cpuReadbacks: Int
    public let hudOverlayApplied: Bool
    public let elapsedMs: Double
    public let bytesWritten: Int64

    public init(
        outputPath: String,
        width: Int,
        height: Int,
        framesWritten: Int,
        droppedFrames: Int,
        cpuReadbacks: Int,
        hudOverlayApplied: Bool,
        elapsedMs: Double,
        bytesWritten: Int64
    ) {
        self.outputPath = outputPath
        self.width = width
        self.height = height
        self.framesWritten = framesWritten
        self.droppedFrames = droppedFrames
        self.cpuReadbacks = cpuReadbacks
        self.hudOverlayApplied = hudOverlayApplied
        self.elapsedMs = elapsedMs
        self.bytesWritten = bytesWritten
    }
}

/// Zero-copy IOSurface `CVPixelBuffer` recorder backed by hardware `AVAssetWriter`.
///
/// Serves both as the live `SCStreamOutput` sink (with `realTime: true`) and as a direct
/// headless sink for pushed `CVPixelBuffer` + `CMTime` frames in automated tests without
/// requiring macOS Screen Recording GUI permission.
///
/// Video frames stay strictly in IOSurface/GPU memory: `CVPixelBufferLockBaseAddress` is never
/// invoked on incoming video frames (`cpuReadbacks == 0`). When `hudOverlayText` is set, a
/// crisp CoreImage badge is composited onto an IOSurface pool buffer on the GPU via `CIContext`.
public final class ZeroCopyStreamRecorder: @unchecked Sendable {
    public let outputURL: URL
    public let config: ScreenCaptureConfig

    private let realTime: Bool
    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let ciContext: CIContext
    private let colorSpace: CGColorSpace

    private var started = false
    private var finished = false
    private var sessionStarted = false
    private var startUptimeNanos: UInt64 = 0
    private var firstPTS: CMTime?
    private var lastVideoPTS: CMTime?
    private var framesWrittenCount = 0
    private var droppedFramesCount = 0
    private var hudApplied = false

    // Cached static HUD badge (rebuilt only when formatted text changes, e.g. 1Hz timestamp update)
    private var cachedHUDKey: String?
    private var cachedHUDBadge: CIImage?

    public init(
        outputURL: URL,
        config: ScreenCaptureConfig = ScreenCaptureConfig(),
        realTime: Bool = false
    ) throws {
        self.outputURL = outputURL
        self.config = config
        self.realTime = realTime

        let parentDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let ext = outputURL.pathExtension.lowercased()
        let fileType: AVFileType
        if ext == "mov" {
            fileType = .mov
        } else if ext == "mp4" && !config.codec.isProRes && config.codec != .hevcAlpha {
            fileType = .mp4
        } else {
            fileType = config.codec.fileType
        }

        let writer = try AVAssetWriter(url: outputURL, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = (fileType == .mp4)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: config.codec.avCodec,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoColorPropertiesKey: ColorMasteringProfile.sdrBT709.avColorProperties,
        ]

        if !config.codec.isProRes {
            let keyframeInterval = max(1, config.fps * 2)
            var compProps: [String: Any] = [
                AVVideoAverageBitRateKey: config.bitrate,
                AVVideoExpectedSourceFrameRateKey: config.fps,
                AVVideoMaxKeyFrameIntervalKey: keyframeInterval,
                AVVideoAllowFrameReorderingKey: !realTime,
                kVTCompressionPropertyKey_AllowOpenGOP as String: false,
            ]
            if let profileLevel = config.codec.defaultProfileLevel {
                compProps[AVVideoProfileLevelKey] = profileLevel
            } else if config.codec == .h264 {
                compProps[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            videoSettings[AVVideoCompressionPropertiesKey] = compProps
        }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = realTime
        guard writer.canAdd(videoInput) else {
            throw SafariumError.encode(
                "ZeroCopyStreamRecorder: AVAssetWriter cannot add video input for codec \(config.codec.rawValue)"
            )
        }
        writer.add(videoInput)

        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: config.width,
            kCVPixelBufferHeightKey as String: config.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: adaptorAttrs
        )

        var configuredAudioInput: AVAssetWriterInput? = nil
        if config.captureAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000.0,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ]
            if writer.canApply(outputSettings: audioSettings, forMediaType: .audio) {
                let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                aInput.expectsMediaDataInRealTime = realTime
                if writer.canAdd(aInput) {
                    writer.add(aInput)
                    configuredAudioInput = aInput
                }
            }
        }

        let ciOpts: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .useSoftwareRenderer: false,
        ]
        if let mtlDevice = MTLCreateSystemDefaultDevice() {
            self.ciContext = CIContext(mtlDevice: mtlDevice, options: ciOpts)
        } else {
            self.ciContext = CIContext(options: ciOpts)
        }

        self.colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()
        self.writer = writer
        self.videoInput = videoInput
        self.adaptor = adaptor
        self.audioInput = configuredAudioInput
    }

    /// Starts the underlying hardware `AVAssetWriter`.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }

        if started { return }
        guard !finished else {
            throw SafariumError.invalidState("ZeroCopyStreamRecorder already finished")
        }
        guard writer.startWriting() else {
            let reason = writer.error?.localizedDescription ?? "unknown AVAssetWriter startWriting error"
            throw SafariumError.encode("ZeroCopyStreamRecorder.start failed: \(reason)")
        }
        startUptimeNanos = DispatchTime.now().uptimeNanoseconds
        started = true
    }

    /// Appends a single IOSurface/GPU `CVPixelBuffer` frame at `presentationTime`.
    ///
    /// Performs zero CPU readbacks of the source video pixel buffer. If `config.hudOverlayText`
    /// is configured or dimensions differ from `config.width x config.height`, composites on GPU
    /// into an IOSurface buffer from `AVAssetWriterInputPixelBufferAdaptor.pixelBufferPool`.
    @discardableResult
    public func append(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> Bool {
        guard presentationTime.isNumeric, presentationTime.isValid else {
            lock.lock()
            droppedFramesCount += 1
            lock.unlock()
            return false
        }

        lock.lock()
        defer { lock.unlock() }

        guard started, !finished else {
            droppedFramesCount += 1
            return false
        }
        guard writer.status == .writing else {
            droppedFramesCount += 1
            return false
        }

        // Wait briefly for hardware encoder readiness when running in deterministic offline mode.
        if !videoInput.isReadyForMoreMediaData {
            if realTime {
                droppedFramesCount += 1
                return false
            }
            let deadlineNanos = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            while !videoInput.isReadyForMoreMediaData && writer.status == .writing {
                if DispatchTime.now().uptimeNanoseconds >= deadlineNanos {
                    droppedFramesCount += 1
                    return false
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
            if !videoInput.isReadyForMoreMediaData || writer.status != .writing {
                droppedFramesCount += 1
                return false
            }
        }

        if !sessionStarted {
            writer.startSession(atSourceTime: .zero)
            firstPTS = presentationTime
            sessionStarted = true
        }

        let originPTS = firstPTS ?? .zero
        let rawNormalized = CMTimeSubtract(presentationTime, originPTS)
        var normalizedPTS = CMTimeMaximum(.zero, rawNormalized)

        if let prev = lastVideoPTS, CMTimeCompare(normalizedPTS, prev) <= 0 {
            let minStep = CMTime(value: 1, timescale: CMTimeScale(max(600, config.fps * 10)))
            normalizedPTS = CMTimeAdd(prev, minStep)
        }

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let needsHUD = (config.hudOverlayText != nil)
        let needsScale = (srcW != config.width || srcH != config.height)
        let isIOSurfaceBacked = (CVPixelBufferGetIOSurface(pixelBuffer) != nil)

        let bufferToAppend: CVPixelBuffer
        if needsHUD || needsScale || !isIOSurfaceBacked {
            guard let pool = adaptor.pixelBufferPool else {
                droppedFramesCount += 1
                return false
            }
            var dstPBOpt: CVPixelBuffer?
            let poolStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dstPBOpt)
            guard poolStatus == kCVReturnSuccess, let dstPB = dstPBOpt else {
                droppedFramesCount += 1
                return false
            }

            autoreleasepool {
                var image = CIImage(cvPixelBuffer: pixelBuffer)
                if needsScale && srcW > 0 && srcH > 0 {
                    let scaleX = CGFloat(config.width) / CGFloat(srcW)
                    let scaleY = CGFloat(config.height) / CGFloat(srcH)
                    image = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                }
                let targetRect = CGRect(x: 0, y: 0, width: config.width, height: config.height)
                image = image.cropped(to: targetRect)

                if let hudLabel = config.hudOverlayText {
                    let elapsedSec = normalizedPTS.seconds.isFinite ? max(0.0, normalizedPTS.seconds) : 0.0
                    let badge = makeOrFetchHUDBadge(label: hudLabel, elapsedSeconds: elapsedSec)
                    if let badge {
                        let margin: CGFloat = 10.0
                        let badgeOriginY = max(margin, CGFloat(config.height) - badge.extent.height - margin)
                        let positioned = badge.transformed(
                            by: CGAffineTransform(translationX: margin, y: badgeOriginY)
                        )
                        image = positioned.composited(over: image).cropped(to: targetRect)
                        hudApplied = true
                    }
                }

                ciContext.render(image, to: dstPB, bounds: targetRect, colorSpace: colorSpace)
            }
            bufferToAppend = dstPB
        } else {
            // Pure zero-copy IOSurface passthrough directly into AVAssetWriter hardware encoder.
            bufferToAppend = pixelBuffer
        }

        let ok = adaptor.append(bufferToAppend, withPresentationTime: normalizedPTS)
        if ok {
            framesWrittenCount += 1
            lastVideoPTS = normalizedPTS
        } else {
            droppedFramesCount += 1
        }
        return ok
    }

    /// Appends an audio `CMSampleBuffer` when `config.captureAudio == true`.
    @discardableResult
    public func appendAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard started, !finished, sessionStarted, writer.status == .writing else {
            return false
        }
        guard let aInput = audioInput, aInput.isReadyForMoreMediaData else {
            return false
        }
        guard let originPTS = firstPTS else {
            return false
        }

        let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard rawPTS.isNumeric else { return false }
        let shiftedPTS = CMTimeSubtract(rawPTS, originPTS)
        if CMTimeCompare(shiftedPTS, .zero) < 0 {
            return false
        }

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: shiftedPTS,
            decodeTimeStamp: .invalid
        )
        var retimed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        )
        guard status == noErr, let copy = retimed else {
            return false
        }
        return aInput.append(copy)
    }

    /// Flushes and finalizes the output movie file, returning a `ScreenCaptureReport`.
    public func finish() async throws -> ScreenCaptureReport {
        let alreadyFinished: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if !started || finished {
                return true
            }
            finished = true
            if !sessionStarted {
                writer.startSession(atSourceTime: .zero)
                sessionStarted = true
            }
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            return false
        }()

        if alreadyFinished {
            throw SafariumError.invalidState("ZeroCopyStreamRecorder must be started and finished exactly once")
        }

        await writer.finishWriting()

        let status = writer.status
        if status != .completed {
            let reason = writer.error?.localizedDescription ?? "AVAssetWriter status \(status.rawValue)"
            throw SafariumError.encode("ZeroCopyStreamRecorder.finish failed: \(reason)")
        }

        let endNanos = DispatchTime.now().uptimeNanoseconds
        let snapshot: (frames: Int, dropped: Int, hud: Bool, startNanos: UInt64) = {
            lock.lock()
            defer { lock.unlock() }
            return (framesWrittenCount, droppedFramesCount, hudApplied, startUptimeNanos)
        }()

        let elapsedNanos = endNanos >= snapshot.startNanos ? (endNanos - snapshot.startNanos) : 0
        let rawElapsedMs = Double(elapsedNanos) / 1_000_000.0
        let roundedElapsedMs = (rawElapsedMs * 100.0).rounded() / 100.0
        let fileBytes = Self.fileSize(outputURL)

        return ScreenCaptureReport(
            outputPath: outputURL.path,
            width: config.width,
            height: config.height,
            framesWritten: snapshot.frames,
            droppedFrames: snapshot.dropped,
            cpuReadbacks: 0,
            hudOverlayApplied: snapshot.hud,
            elapsedMs: roundedElapsedMs,
            bytesWritten: fileBytes
        )
    }

    // MARK: - HUD Overlay Badge (CoreGraphics/CoreText -> CIImage, cached per tenth-second)

    private func makeOrFetchHUDBadge(label: String, elapsedSeconds: Double) -> CIImage? {
        let tenths = Int((elapsedSeconds * 10.0).rounded(.down))
        let secs = tenths / 10
        let sub = tenths % 10
        let mins = secs / 60
        let remSecs = secs % 60
        let stamp = String(format: "%02d:%02d.%d", mins, remSecs, sub)
        let displayText = label.isEmpty ? "REC \(stamp)" : "\(label)  \(stamp)"

        if cachedHUDKey == displayText, let existing = cachedHUDBadge {
            return existing
        }

        let fontSize = max(11.0, min(20.0, Double(config.height) * 0.045))
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, CGFloat(fontSize), nil)
        let whiteColor = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [1.0, 1.0, 1.0, 0.96])
            ?? CGColor(gray: 1.0, alpha: 1.0)
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: whiteColor,
        ]
        guard let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, displayText as CFString, attrs as CFDictionary) else {
            return nil
        }
        let line = CTLineCreateWithAttributedString(attrStr)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

        let padX: CGFloat = 10.0
        let padY: CGFloat = 5.0
        let dotSpace: CGFloat = 14.0
        let rawW = ceil(textWidth + padX * 2.0 + dotSpace)
        let rawH = ceil(ascent + descent + padY * 2.0)
        let maxW = max(32, config.width - 20)
        let badgeW = min(maxW, max(32, Int(rawW)))
        let badgeH = max(18, Int(rawH))

        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: badgeW,
            height: badgeH,
            bitsPerComponent: 8,
            bytesPerRow: badgeW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        let rect = CGRect(x: 0, y: 0, width: CGFloat(badgeW), height: CGFloat(badgeH))
        let cornerRadius = min(6.0, CGFloat(badgeH) * 0.3)
        let pillPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        ctx.setFillColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 0.78)
        ctx.addPath(pillPath)
        ctx.fillPath()

        // Crisp recording status indicator dot
        let dotDiameter: CGFloat = max(5.0, CGFloat(fontSize) * 0.45)
        let dotY = (CGFloat(badgeH) - dotDiameter) * 0.5
        let dotRect = CGRect(x: padX, y: dotY, width: dotDiameter, height: dotDiameter)
        ctx.setFillColor(red: 0.96, green: 0.24, blue: 0.24, alpha: 0.98)
        ctx.fillEllipse(in: dotRect)

        // Draw crisp HUD label + elapsed timestamp
        ctx.textMatrix = .identity
        let textOriginX = padX + dotSpace
        let textOriginY = padY + descent
        ctx.textPosition = CGPoint(x: textOriginX, y: textOriginY)
        CTLineDraw(line, ctx)

        guard let cgImage = ctx.makeImage() else { return nil }
        let ciBadge = CIImage(cgImage: cgImage)
        cachedHUDKey = displayText
        cachedHUDBadge = ciBadge
        return ciBadge
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

// MARK: - Live ScreenCaptureKit Stream Pipeline (macOS 14+ Compatible)

/// Live macOS `ScreenCaptureKit` capture driver feeding `ZeroCopyStreamRecorder`.
public enum ScreenCapturePipeline {

    /// Checks whether Screen Recording permission is currently granted without triggering a modal prompt.
    public static func preflightAccess() -> ScreenCapturePreflight {
        let granted = CGPreflightScreenCaptureAccess()
        let notes: String
        if granted {
            notes = "ScreenCaptureKit access granted (zero-copy IOSurface capture ready)."
        } else {
            notes = "Screen Recording permission not granted. Enable access in System Settings -> Privacy & Security -> Screen & System Audio Recording."
        }
        return ScreenCapturePreflight(
            hasPermission: granted,
            platformSupported: true,
            notes: notes
        )
    }

    /// Captures the primary display via macOS 14-compatible `ScreenCaptureKit` APIs for
    /// `config.maxDurationSeconds`, encoding directly through `ZeroCopyStreamRecorder`.
    public static func recordDisplay(
        outputURL: URL,
        config: ScreenCaptureConfig = ScreenCaptureConfig()
    ) async throws -> ScreenCaptureReport {
        let preflight = preflightAccess()
        guard preflight.hasPermission else {
            throw SafariumError.invalidState(preflight.notes)
        }

        let shareable = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = shareable.displays.first else {
            throw SafariumError.invalidState("ScreenCaptureKit returned no active displays")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = config.width
        streamConfig.height = config.height
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, config.fps)))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.showsCursor = config.showCursor
        streamConfig.capturesAudio = config.captureAudio
        streamConfig.queueDepth = 5

        let recorder = try ZeroCopyStreamRecorder(outputURL: outputURL, config: config, realTime: true)
        try recorder.start()

        let bridge = StreamOutputBridge(recorder: recorder)
        let stream = SCStream(filter: filter, configuration: streamConfig, delegate: bridge)

        let videoQueue = DispatchQueue(label: "com.safarium.screencapture.video", qos: .userInteractive)
        try stream.addStreamOutput(bridge, type: .screen, sampleHandlerQueue: videoQueue)

        if config.captureAudio {
            let audioQueue = DispatchQueue(label: "com.safarium.screencapture.audio", qos: .userInteractive)
            try stream.addStreamOutput(bridge, type: .audio, sampleHandlerQueue: audioQueue)
        }

        try await stream.startCapture()

        let durationSeconds = max(0.1, config.maxDurationSeconds)
        let sleepNanos = UInt64((durationSeconds * 1_000_000_000.0).rounded())
        try await Task.sleep(nanoseconds: sleepNanos)

        try await stream.stopCapture()

        if let streamErr = bridge.streamError() {
            _ = try? await recorder.finish()
            throw SafariumError.encode("ScreenCaptureKit stream stopped with error: \(streamErr.localizedDescription)")
        }

        return try await recorder.finish()
    }

    private final class StreamOutputBridge: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
        private let recorder: ZeroCopyStreamRecorder
        private let lock = NSLock()
        private var capturedError: Error?

        init(recorder: ZeroCopyStreamRecorder) {
            self.recorder = recorder
            super.init()
        }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
            guard sampleBuffer.isValid else { return }

            switch type {
            case .screen:
                if let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                   let firstAttachment = attachmentsArray.first,
                   let statusRaw = firstAttachment[.status] as? Int,
                   let status = SCFrameStatus(rawValue: statusRaw),
                   status != .complete {
                    return
                }
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                recorder.append(pixelBuffer: pixelBuffer, presentationTime: pts)

            case .audio:
                recorder.appendAudio(sampleBuffer)

            @unknown default:
                break
            }
        }

        func stream(_ stream: SCStream, didStopWithError error: Error) {
            lock.lock()
            capturedError = error
            lock.unlock()
        }

        func streamError() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return capturedError
        }
    }
}
