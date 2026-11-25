import Accelerate
import Foundation
import AVFoundation
import CoreVideo
import VideoToolbox
import WebKit

public protocol FrameSink: AnyObject {
    /// Frame `index`-th at the sink's fps (timestamp = index/fps), appended in order.
    func append(_ frame: Snapshot) async throws
    /// Flush and close the output. Must be called exactly once.
    func finish() async throws
}

public enum VideoCodec: String, CustomStringConvertible, Sendable {
    case h264, hevc, hevcAlpha, proRes422, proRes4444
    public var description: String { rawValue }
    public var avCodec: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        case .hevcAlpha: return .hevcWithAlpha
        case .proRes422: return .proRes422
        case .proRes4444: return .proRes4444
        }
    }
    public var fileType: AVFileType { (self == .h264 || self == .hevc) ? .mp4 : .mov }
    public var fileExtension: String { (self == .h264 || self == .hevc) ? "mp4" : "mov" }
    public var hasAlpha: Bool { self == .hevcAlpha || self == .proRes4444 }

    public static func parseCLI(_ s: String) -> VideoCodec? {
        switch s.lowercased() {
        case "h264": return .h264
        case "hevc": return .hevc
        case "hevc-alpha", "hevcalpha": return .hevcAlpha
        case "prores422": return .proRes422
        case "prores4444": return .proRes4444
        default: return nil
        }
    }
}

public enum SinkPixelFormat: String, Sendable {
    case bgra
    case nv12vImage
    case nv12Left
}

/// Hardware encoder and buffer-pool tuning profile.
public struct EncoderProfile: Sendable {
    public var allowFrameReordering: Bool
    public var allowOpenGOP: Bool
    public var suggestedLookAheadFrameCount: Int?
    public var maxFrameDelayCount: Int?
    public var prioritizeEncodingSpeed: Bool
    public var maxKeyFrameInterval: Int?
    public var maxKeyFrameIntervalDuration: Double?
    public var poolAllocationThreshold: Int?
    public var expectedSourceFrameRate: Int?

    public init(
        allowFrameReordering: Bool = true,
        allowOpenGOP: Bool = true,
        suggestedLookAheadFrameCount: Int? = nil,
        maxFrameDelayCount: Int? = nil,
        prioritizeEncodingSpeed: Bool = false,
        maxKeyFrameInterval: Int? = nil,
        maxKeyFrameIntervalDuration: Double? = nil,
        poolAllocationThreshold: Int? = nil,
        expectedSourceFrameRate: Int? = nil
    ) {
        self.allowFrameReordering = allowFrameReordering
        self.allowOpenGOP = allowOpenGOP
        self.suggestedLookAheadFrameCount = suggestedLookAheadFrameCount
        self.maxFrameDelayCount = maxFrameDelayCount
        self.prioritizeEncodingSpeed = prioritizeEncodingSpeed
        self.maxKeyFrameInterval = maxKeyFrameInterval
        self.maxKeyFrameIntervalDuration = maxKeyFrameIntervalDuration
        self.poolAllocationThreshold = poolAllocationThreshold
        self.expectedSourceFrameRate = expectedSourceFrameRate
    }

    public static let baseline = EncoderProfile()

    /// Bounded K=2 CVPixelBufferPool, closed-GOP IDR cadence without B-frame reordering or lookahead.
    public static let lowRamClosedGOP = EncoderProfile(
        allowFrameReordering: false,
        allowOpenGOP: false,
        suggestedLookAheadFrameCount: 0,
        maxFrameDelayCount: nil,
        prioritizeEncodingSpeed: true,
        poolAllocationThreshold: 2
    )
}

/// Mode C opt-in DOM/Canvas/WebGL/WAAPI/SMIL mutation probe for detecting static hold frames in HTML renders.
public enum StaticHoldProbe {
    public static let script: String = #"""
    (function () {
      if (window.__sfDirtyProbe) return;
      let mutCount = 0;
      let canvas2dDraws = 0;
      let webglDraws = 0;
      let smilTouches = 0;
      let activeTracking = false;
      let prevAnimSig = new Map();
      let prevSmilTime = new Map();

      function markCanvas2d(proto, method) {
        const orig = proto && proto[method];
        if (typeof orig !== 'function') return;
        proto[method] = function () {
          if (activeTracking) canvas2dDraws++;
          return orig.apply(this, arguments);
        };
      }
      if (typeof CanvasRenderingContext2D !== 'undefined') {
        for (const m of ['fillRect','strokeRect','clearRect','fillText','strokeText','drawImage','putImageData','fill','stroke']) {
          markCanvas2d(CanvasRenderingContext2D.prototype, m);
        }
      }
      function markWebGL(proto) {
        if (!proto) return;
        for (const m of ['clear','drawArrays','drawElements','drawArraysInstanced','drawElementsInstanced','texImage2D','texSubImage2D']) {
          const orig = proto[m];
          if (typeof orig !== 'function') continue;
          proto[m] = function () {
            if (activeTracking) webglDraws++;
            return orig.apply(this, arguments);
          };
        }
      }
      if (typeof WebGLRenderingContext !== 'undefined') markWebGL(WebGLRenderingContext.prototype);
      if (typeof WebGL2RenderingContext !== 'undefined') markWebGL(WebGL2RenderingContext.prototype);

      if (typeof SVGSVGElement !== 'undefined' && SVGSVGElement.prototype.setCurrentTime) {
        const origSet = SVGSVGElement.prototype.setCurrentTime;
        SVGSVGElement.prototype.setCurrentTime = function (t) {
          if (activeTracking) smilTouches++;
          return origSet.apply(this, arguments);
        };
      }

      const obs = new MutationObserver((records) => {
        if (activeTracking && records && records.length) {
          mutCount += records.length;
        }
      });

      function ensureObserver() {
        const target = document.documentElement || document;
        if (!target) return;
        try {
          obs.disconnect();
          obs.observe(target, { subtree: true, childList: true, attributes: true, characterData: true });
        } catch (e) {}
      }

      function snapshotAnimSignatures() {
        const map = new Map();
        if (typeof document.getAnimations === 'function') {
          for (const a of document.getAnimations()) {
            let p = '';
            try {
              const ct = a.effect && typeof a.effect.getComputedTiming === 'function' ? a.effect.getComputedTiming() : null;
              p = ct ? String(ct.progress) : '';
            } catch (e) {}
            map.set(a, `${a.playState}|${a.currentTime}|${p}`);
          }
        }
        return map;
      }

      window.__sfDirtyProbe = {
        beginStep() {
          ensureObserver();
          obs.takeRecords();
          mutCount = 0;
          canvas2dDraws = 0;
          webglDraws = 0;
          smilTouches = 0;
          prevAnimSig = snapshotAnimSignatures();
          for (const svg of document.querySelectorAll('svg')) {
            try { prevSmilTime.set(svg, svg.getCurrentTime()); } catch (e) {}
          }
          activeTracking = true;
        },
        consumeStep() {
          const drained = obs.takeRecords();
          if (drained && drained.length) mutCount += drained.length;
          activeTracking = false;

          let waapiDirty = 0;
          if (typeof document.getAnimations === 'function') {
            const anims = document.getAnimations();
            for (const a of anims) {
              let p = '';
              try {
                const ct = a.effect && typeof a.effect.getComputedTiming === 'function' ? a.effect.getComputedTiming() : null;
                p = ct ? String(ct.progress) : '';
              } catch (e) {}
              const sig = `${a.playState}|${a.currentTime}|${p}`;
              const prev = prevAnimSig.get(a);
              if (sig !== prev || a.playState === 'running') {
                waapiDirty++;
              }
            }
          }

          let smilDirty = smilTouches;
          for (const svg of document.querySelectorAll('svg')) {
            try {
              const cur = svg.getCurrentTime();
              if (prevSmilTime.get(svg) !== cur && svg.querySelector('animate,animateTransform,animateMotion,set')) {
                smilDirty++;
              }
            } catch (e) {}
          }

          const dirty = (mutCount > 0) || (canvas2dDraws > 0) || (webglDraws > 0) || (waapiDirty > 0) || (smilDirty > 0);
          return {
            dirty,
            domMutations: mutCount,
            canvas2dDraws,
            webglDraws,
            waapiDirty,
            smilDirty
          };
        }
      };
    })();
    """#

    public static func userScript() -> WKUserScript {
        WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }
}

/// Event-driven backpressure gate over `AVAssetWriterInput.isReadyForMoreMediaData`.
/// Registers `requestMediaDataWhenReady(on:)` once and supports structured cancellation.
package final class InputReadyGate: @unchecked Sendable {
    private let input: AVAssetWriterInput
    private let writer: AVAssetWriter
    private let queue = DispatchQueue(label: "safarium.writer.ready")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var activeWaitID: UInt64 = 0
    private var cancelledWaitID: UInt64 = 0
    private var waitCounter: UInt64 = 0
    private var startedObserving = false
    private var invalidated = false
    private var statusObs: NSKeyValueObservation?
    private var nudgeTimer: DispatchSourceTimer?

    package init(input: AVAssetWriterInput, writer: AVAssetWriter) {
        self.input = input
        self.writer = writer
    }

    deinit {
        invalidate()
    }

    private func prepareIfNeeded() {
        let shouldStart: Bool = lock.withLock {
            if startedObserving || invalidated { return false }
            startedObserving = true
            return true
        }
        guard shouldStart else { return }
        let obs = writer.observe(\.status, options: [.new]) { [weak self] _, _ in
            self?.signal()
        }
        let keep = lock.withLock {
            if invalidated { return false }
            statusObs = obs
            return true
        }
        if !keep {
            obs.invalidate()
            return
        }
        input.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.signal()
        }
    }

    private func stopNudgeLocked() {
        nudgeTimer?.cancel()
        nudgeTimer = nil
    }

    private func startNudgeLocked() {
        guard nudgeTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25))
        t.setEventHandler { [weak self] in
            self?.signal()
        }
        nudgeTimer = t
        t.resume()
    }

    private func signal() {
        let pending: (CheckedContinuation<Void, Error>, Result<Void, Error>)? = lock.withLock {
            guard let cont = continuation else {
                stopNudgeLocked()
                return nil
            }
            if invalidated {
                continuation = nil
                activeWaitID = 0
                stopNudgeLocked()
                return (cont, .failure(SafariumError.invalidState("writer sink cancelled")))
            }
            if writer.status != .writing {
                continuation = nil
                activeWaitID = 0
                stopNudgeLocked()
                return (cont, .failure(SafariumError.encode(writer.error?.localizedDescription ?? "writer stopped")))
            }
            if input.isReadyForMoreMediaData {
                continuation = nil
                activeWaitID = 0
                stopNudgeLocked()
                return (cont, .success(()))
            }
            return nil
        }
        if let (cont, result) = pending {
            cont.resume(with: result)
        }
    }

    private func register(_ cont: CheckedContinuation<Void, Error>, waitID: UInt64) {
        let (immediate, armed): (Result<Void, Error>?, Bool) = lock.withLock {
            if Task.isCancelled || cancelledWaitID >= waitID {
                return (.failure(CancellationError()), false)
            }
            if invalidated {
                return (.failure(SafariumError.invalidState("writer sink cancelled")), false)
            }
            if writer.status != .writing {
                return (.failure(SafariumError.encode(writer.error?.localizedDescription ?? "writer stopped")), false)
            }
            if input.isReadyForMoreMediaData {
                return (.success(()), false)
            }
            continuation = cont
            activeWaitID = waitID
            startNudgeLocked()
            return (nil, true)
        }
        if let immediate {
            cont.resume(with: immediate)
        } else if armed && (input.isReadyForMoreMediaData || writer.status != .writing) {
            signal()
        }
    }

    private func cancelPending(waitID: UInt64) {
        let cont: CheckedContinuation<Void, Error>? = lock.withLock {
            if waitID > cancelledWaitID {
                cancelledWaitID = waitID
            }
            guard activeWaitID == waitID else { return nil }
            stopNudgeLocked()
            activeWaitID = 0
            let c = continuation
            continuation = nil
            return c
        }
        cont?.resume(throwing: CancellationError())
    }

    package func invalidate() {
        let (cont, obs): (CheckedContinuation<Void, Error>?, NSKeyValueObservation?) = lock.withLock {
            invalidated = true
            stopNudgeLocked()
            let o = statusObs
            statusObs = nil
            activeWaitID = 0
            let c = continuation
            continuation = nil
            return (c, o)
        }
        obs?.invalidate()
        cont?.resume(throwing: SafariumError.invalidState("writer sink cancelled"))
    }

    package func waitUntilReady() async throws {
        try Task.checkCancellation()
        if input.isReadyForMoreMediaData && writer.status == .writing { return }
        prepareIfNeeded()
        let waitID = lock.withLock {
            waitCounter += 1
            return waitCounter
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                register(cont, waitID: waitID)
            }
        } onCancel: {
            cancelPending(waitID: waitID)
        }
    }
}

/// Hardware-accelerated AVAssetWriter sink with IOSurface-backed pixel buffer pool and pre-allocation backpressure.
public final class AVAssetWriterSink: FrameSink {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let readyGate: InputReadyGate
    private let pixelFormat: SinkPixelFormat
    private let profile: EncoderProfile
    private var nv12Info: vImage_ARGBToYpCbCr?
    private var bgraScratch: [UInt8] = []
    private let scratchBandContext: CGContext?
    private let width: Int, height: Int, fps: Int32
    private var index: Int64 = 0
    private var endTime: CMTime?
    private var finished = false

    /// - bitrate: average bits/s (H.264/HEVC); ignored for ProRes.
    /// - quality: 0...1 constant quality (HEVC/HEVC-alpha); used instead of bitrate when set.
    /// - pixelFormat: `.bgra`, `.nv12vImage`, or `.nv12Left`; defaults to `.bgra` when `codec.hasAlpha` else `.nv12Left` (Fix A 1-1-1 + Left siting).
    /// - profile: encoder & pool backpressure settings (`.baseline` or `.lowRamClosedGOP`).
    public init(url: URL, width: Int, height: Int, fps: Int, codec: VideoCodec,
                bitrate: Int? = nil, quality: Double? = nil,
                pixelFormat: SinkPixelFormat? = nil,
                profile: EncoderProfile = .baseline,
                encoderSpecification: [String: Any]? = nil) throws {
        let resolvedPixelFormat = pixelFormat ?? (codec.hasAlpha ? .bgra : .nv12Left)
        guard width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 33_554_432 else {
            throw SafariumError.encode("dimensions must be <= 8192 per side and 33554432 pixels, got \(width)x\(height)")
        }
        if (resolvedPixelFormat == .nv12vImage || resolvedPixelFormat == .nv12Left) && (width % 2 != 0 || height % 2 != 0) {
            throw SafariumError.encode("\(resolvedPixelFormat.rawValue) requires even dimensions, got \(width)x\(height)")
        }
        if let b = bitrate, b <= 0 {
            throw SafariumError.encode("bitrate must be > 0")
        }
        if let q = quality, !q.isFinite || q <= 0 || q > 1.0 {
            throw SafariumError.encode("quality must be finite in (0, 1]")
        }
        guard let rate = Int32(exactly: fps), rate > 0 else { throw SafariumError.encode("fps must be a positive Int32") }
        if (resolvedPixelFormat == .nv12vImage || resolvedPixelFormat == .nv12Left) && codec.hasAlpha {
            throw SafariumError.invalidState("\(resolvedPixelFormat.rawValue) pixel format does not support alpha codec \(codec)")
        }
        self.width = width; self.height = height; self.fps = rate
        self.pixelFormat = resolvedPixelFormat
        self.profile = profile
        self.nv12Info = (resolvedPixelFormat == .nv12vImage) ? try Self.makeNV12Info() : nil
        self.scratchBandContext = (resolvedPixelFormat == .nv12Left) ? Self.makeScratchBandContext(width: width) : nil

        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(url: url, fileType: codec.fileType)
        var requested = Self.buildVideoSettings(
            width: width, height: height, fps: fps, codec: codec,
            bitrate: bitrate, quality: quality, profile: profile
        )
        if let spec = encoderSpecification { requested[AVVideoEncoderSpecificationKey] = spec }
        // AVAssetWriterInput.init raises an uncatchable NSInvalidArgumentException when the encoder AVFoundation
        // selects (e.g. software fallback while the HW encoder is busy) lacks a requested property. Validate first.
        let (settings, dropped) = try Self.resolveSupportedSettings(requested, writer: writer, codec: codec)
        droppedCompressionProperties = dropped
        if !dropped.isEmpty {
            FileHandle.standardError.write(Data("safarium: warning: encoder for \(codec) does not support \(dropped.joined(separator: ", ")); dropped (encoded spec unchanged)\n".utf8))
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let exactScale = Self.exactTimeScale(fps: fps, fallback: rate)
        writer.movieTimeScale = exactScale
        input.mediaTimeScale = exactScale
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: Self.pixelBufferAttributes(
                width: width, height: height, pixelFormat: resolvedPixelFormat,
                allocationThreshold: profile.poolAllocationThreshold
            )
        )
        guard writer.canAdd(input) else { throw SafariumError.encode("writer cannot add input for \(codec)") }
        writer.add(input)
        guard writer.startWriting() else { throw SafariumError.encode("startWriting: \(writer.error?.localizedDescription ?? "?")") }
        writer.startSession(atSourceTime: .zero)
        readyGate = InputReadyGate(input: input, writer: writer)
    }

    /// Compression properties dropped because the selected encoder rejects them (encoder hints only).
    public let droppedCompressionProperties: [String]

    /// Encoder hints that do not alter the encoded spec (rate/quality, GOP structure, colour, size): speed/latency
    /// tuning only. Anything else unsupported is an error, never silently dropped.
    package static var droppableCompressionKeys: [String] {
        var keys = [kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String]
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) { keys.append(kVTCompressionPropertyKey_SuggestedLookAheadFrameCount as String) }
        #endif
        keys.append(kVTCompressionPropertyKey_MaxFrameDelayCount as String)
        return keys
    }

    /// `AllowOpenGOP=false` is redundant (so spec-neutral to drop) when frame reordering is off: open GOPs need
    /// leading/reordered pictures, which cannot exist without B-frame reordering. The software H.264 encoder lacks it.
    private static func droppableKeys(for settings: [String: Any]) -> [String] {
        var keys = droppableCompressionKeys
        let props = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
        if (props?[AVVideoAllowFrameReorderingKey] as? Bool) == false {
            keys.append(kVTCompressionPropertyKey_AllowOpenGOP as String)
        }
        return keys
    }

    /// Returns settings AVAssetWriterInput will accept (`canApply`), dropping only `droppableCompressionKeys`.
    package static func resolveSupportedSettings(
        _ settings: [String: Any], writer: AVAssetWriter, codec: VideoCodec,
        canApply: (([String: Any]) -> Bool)? = nil
    ) throws -> (settings: [String: Any], dropped: [String]) {
        let check: ([String: Any]) -> Bool = canApply ?? { writer.canApply(outputSettings: $0, forMediaType: .video) }
        var current = settings
        if check(current) { return (current, []) }
        var dropped: [String] = []
        for key in droppableKeys(for: settings) {
            guard var props = current[AVVideoCompressionPropertiesKey] as? [String: Any], props[key] != nil else { continue }
            props[key] = nil
            current[AVVideoCompressionPropertiesKey] = props.isEmpty ? nil : props
            dropped.append(key)
            if check(current) { return (current, dropped) }
        }
        throw SafariumError.encode("encoder for \(codec) rejects output settings even after dropping \(dropped)")
    }

    public static func makeScratchBandContext(width: Int, bandRows: Int = 256) -> CGContext? {
        let alignedRows = max(2, bandRows & ~1)
        return CGContext(
            data: nil, width: width, height: alignedRows,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: Snapshot.colorSpace, bitmapInfo: Snapshot.bitmapInfo
        )
    }

    public static func exactTimeScale(fps: Int, fallback: Int32) -> Int32 {
        // Preserve the conventional 600-tick grid when possible, but every frame boundary must be
        // representable (e.g. 31 fps needs 1/31, not 19/600). Use the LCM when it fits CMTimeScale.
        var a = fps, b = 600
        while b != 0 { (a, b) = (b, a % b) }
        return Int32(exactly: (fps / a) * 600) ?? fallback
    }

    public static func buildVideoSettings(
        width: Int, height: Int, fps: Int, codec: VideoCodec,
        bitrate: Int?, quality: Double?, profile: EncoderProfile = .baseline
    ) -> [String: Any] {
        var settings: [String: Any] = [AVVideoCodecKey: codec.avCodec, AVVideoWidthKey: width, AVVideoHeightKey: height]
        var props: [String: Any] = [:]
        if codec != .proRes422 && codec != .proRes4444 {
            if let q = quality { props[AVVideoQualityKey] = q }
            else if codec == .hevcAlpha { props[AVVideoQualityKey] = 0.85 }
            else if let b = bitrate { props[AVVideoAverageBitRateKey] = b }

            if let efr = profile.expectedSourceFrameRate {
                props[AVVideoExpectedSourceFrameRateKey] = efr
            } else if profile.maxKeyFrameIntervalDuration == nil {
                props[AVVideoExpectedSourceFrameRateKey] = fps
            }
            if !profile.allowFrameReordering {
                props[AVVideoAllowFrameReorderingKey] = false
            }
            if !profile.allowOpenGOP {
                props[kVTCompressionPropertyKey_AllowOpenGOP as String] = false
            }
            if profile.prioritizeEncodingSpeed {
                props[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = true
            }
            if let kfi = profile.maxKeyFrameInterval {
                props[AVVideoMaxKeyFrameIntervalKey] = kfi
            }
            if let kfd = profile.maxKeyFrameIntervalDuration {
                props[AVVideoMaxKeyFrameIntervalDurationKey] = kfd
            }
            if let la = profile.suggestedLookAheadFrameCount {
                #if compiler(>=6.0)
                if #available(macOS 15.0, *) {
                    props[kVTCompressionPropertyKey_SuggestedLookAheadFrameCount as String] = la
                }
                #endif
            }
            if let mfd = profile.maxFrameDelayCount, codec != .h264 {
                props[kVTCompressionPropertyKey_MaxFrameDelayCount as String] = mfd
            }
            if codec == .hevcAlpha {
                props[kVTCompressionPropertyKey_TargetQualityForAlpha as String] = quality ?? 0.90
                props[kVTCompressionPropertyKey_AlphaChannelMode as String] = kVTAlphaChannelMode_PremultipliedAlpha
            }
        }
        if !props.isEmpty { settings[AVVideoCompressionPropertiesKey] = props }
        // Tag the colour pipeline (BT.709 1-1-1).
        settings[AVVideoColorPropertiesKey] = [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        return settings
    }

    public static func pixelBufferAttributes(
        width: Int, height: Int, pixelFormat: SinkPixelFormat, allocationThreshold: Int? = nil
    ) -> [String: Any] {
        let cvFormat: OSType = (pixelFormat == .nv12vImage || pixelFormat == .nv12Left)
            ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            : kCVPixelFormatType_32BGRA
        var attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: cvFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferBytesPerRowAlignmentKey as String: 64,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        if let threshold = allocationThreshold {
            attrs[kCVPixelBufferPoolAllocationThresholdKey as String] = threshold
        }
        return attrs
    }

    public static func makeNV12Info() throws -> vImage_ARGBToYpCbCr {
        try SafariumAccelerate.makeBT709NV12Info()
    }

    /// Zero-alloc NV12 conversion reusing either canonical CGImage bytes or caller-owned `bgraScratch`.
    package static func writeNV12(
        _ frame: Snapshot, into pb: CVPixelBuffer, width: Int, height: Int,
        info: inout vImage_ARGBToYpCbCr, bgraScratch: inout [UInt8]
    ) throws {
        guard frame.width == width, frame.height == height else {
            throw SafariumError.encode("NV12 snapshot dimensions \(frame.width)x\(frame.height) != \(width)x\(height)")
        }
        let borrowed = try frame.borrowCanonicalBGRABytes(width: width, height: height) { raw, stride in
            try SafariumAccelerate.convertBGRAToNV12BT709(
                bgra: raw,
                bgraBytesPerRow: stride,
                into: pb,
                width: width,
                height: height,
                info: &info
            )
            return true
        } ?? false
        if borrowed { return }

        let stride = width * 4
        let needed = stride * height
        if bgraScratch.count < needed {
            bgraScratch = [UInt8](repeating: 0, count: needed)
        }
        try bgraScratch.withUnsafeMutableBytes { raw in
            try frame.drawBGRAInto(baseAddress: raw.baseAddress!, width: width, height: height, stride: stride)
            try SafariumAccelerate.convertBGRAToNV12BT709(
                bgra: raw.baseAddress!,
                bgraBytesPerRow: stride,
                into: pb,
                width: width,
                height: height,
                info: &info
            )
        }
    }

    package static func writeNV12(
        _ frame: Snapshot, into pb: CVPixelBuffer, width: Int, height: Int, info: inout vImage_ARGBToYpCbCr
    ) throws {
        var scratch: [UInt8] = []
        try writeNV12(frame, into: pb, width: width, height: height, info: &info, bgraScratch: &scratch)
    }

    public static func allocateStandalonePixelBuffer(
        width: Int, height: Int, pixelFormat: SinkPixelFormat
    ) throws -> CVPixelBuffer {
        let cvFormat: OSType = (pixelFormat == .nv12vImage || pixelFormat == .nv12Left)
            ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            : kCVPixelFormatType_32BGRA
        let attrs: [String: Any] = [
            kCVPixelBufferBytesPerRowAlignmentKey as String: 64,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(kCFAllocatorDefault, width, height, cvFormat, attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let pb else {
            throw SafariumError.encode("CVPixelBufferCreate standalone failed (\(st))")
        }
        return pb
    }

    public func allocateStandalonePixelBuffer() throws -> CVPixelBuffer {
        try Self.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: pixelFormat)
    }

    public func flushPool() {
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolFlush(pool, .excessBuffers)
        }
    }

    public func populate(_ frame: Snapshot, into buf: CVPixelBuffer) throws {
        switch pixelFormat {
        case .bgra:
            try frame.draw(into: buf, width: width, height: height)
        case .nv12vImage:
            guard var info = nv12Info else { throw SafariumError.invalidState("missing NV12 converter") }
            try Self.writeNV12(frame, into: buf, width: width, height: height, info: &info, bgraScratch: &bgraScratch)
            nv12Info = info
        case .nv12Left:
            try SafariumAccelerate.convertBGRAToNV12BT709LeftBanded(
                snapshot: frame, scratchBand: scratchBandContext, into: buf, width: width, height: height
            )
        }
    }

    public static func allocatePoolBuffer(
        from pool: CVPixelBufferPool,
        allocationThreshold: Int?,
        waitReady: @escaping () async throws -> Void
    ) async throws -> CVPixelBuffer {
        let aux: CFDictionary? = allocationThreshold.map {
            [kCVPixelBufferPoolAllocationThresholdKey as String: $0] as CFDictionary
        }
        var pb: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &pb)
        if status == kCVReturnWouldExceedAllocationThreshold {
            for _ in 0..<400 {
                try await waitReady()
                var retryPB: CVPixelBuffer?
                let st2 = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &retryPB)
                if st2 == kCVReturnSuccess, let buf = retryPB { return buf }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            throw SafariumError.encode("pixel buffer pool allocation threshold wait timed out")
        }
        guard status == kCVReturnSuccess, let buf = pb else {
            throw SafariumError.encode("pixel buffer allocation failed (\(status))")
        }
        return buf
    }

    public func appendPixelBuffer(
        _ buf: CVPixelBuffer,
        presentationTime: CMTime? = nil,
        duration: CMTime? = nil
    ) async throws {
        guard !finished else { throw SafariumError.invalidState("sink already finished") }
        try await readyGate.waitUntilReady()
        guard !finished else { throw SafariumError.invalidState("sink already finished") }
        let pts = presentationTime ?? CMTime(value: index, timescale: fps)
        let dur = duration ?? CMTime(value: 1, timescale: fps)
        try autoreleasepool {
            let appended: Bool
            if endTime == nil || duration != nil {
                let timing = CMSampleTimingInfo(duration: dur, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
                let sample = try CMSampleBuffer(
                    imageBuffer: buf,
                    formatDescription: CMVideoFormatDescription(imageBuffer: buf),
                    sampleTiming: timing
                )
                appended = input.append(sample)
            } else {
                appended = adaptor.append(buf, withPresentationTime: pts)
            }
            guard appended else {
                throw SafariumError.encode("append failed: \(writer.error?.localizedDescription ?? "?")")
            }
            endTime = CMTimeAdd(pts, dur)
        }
        if presentationTime == nil { index += 1 }
    }

    public func append(_ frame: Snapshot) async throws {
        try await append(frame, presentationTime: CMTime(value: index, timescale: fps))
        index += 1
    }

    public func append(_ frame: Snapshot, presentationTime: CMTime) async throws {
        try await append(presentationTime: presentationTime) { buf in
            try self.populate(frame, into: buf)
        }
    }

    /// Zero-copy append: obtains an IOSurface-backed pixel buffer from the pool after backpressure gating
    /// and passes it directly to `populate` (e.g. Metal / Core Image render target) before appending.
    package func append(presentationTime: CMTime? = nil, populate: (CVPixelBuffer) throws -> Void) async throws {
        guard !finished else { throw SafariumError.invalidState("sink already finished") }
        try await readyGate.waitUntilReady()
        guard !finished else { throw SafariumError.invalidState("sink already finished") }
        guard let pool = adaptor.pixelBufferPool else { throw SafariumError.encode("no pixel buffer pool") }
        let buf = try await Self.allocatePoolBuffer(
            from: pool,
            allocationThreshold: profile.poolAllocationThreshold,
            waitReady: { [self] in try await self.readyGate.waitUntilReady() }
        )

        let pts = presentationTime ?? CMTime(value: index, timescale: fps)
        try autoreleasepool {
            try populate(buf)
            let duration = CMTime(value: 1, timescale: fps)
            let appended: Bool
            if endTime == nil {
                // If this remains the sole sample there is no following DTS from which to infer its
                // duration. The pixel adaptor otherwise writes a 1/15 sample hidden behind a movie edit.
                let timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
                let sample = try CMSampleBuffer(imageBuffer: buf, formatDescription: CMVideoFormatDescription(imageBuffer: buf), sampleTiming: timing)
                appended = input.append(sample)
            } else {
                appended = adaptor.append(buf, withPresentationTime: pts)
            }
            guard appended else {
                throw SafariumError.encode("append failed: \(writer.error?.localizedDescription ?? "?")")
            }
            endTime = CMTimeAdd(pts, duration)
        }
        if presentationTime == nil {
            index += 1
        }
    }

    public func finish() async throws {
        guard !finished else { return }
        finished = true
        readyGate.invalidate()
        if let endTime, writer.status == .writing { writer.endSession(atSourceTime: endTime) }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw SafariumError.encode("finish: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")") }
    }

    /// Discard an unfinished session (e.g. the caller rejected a capture).
    public func cancel() {
        finished = true
        readyGate.invalidate()
        if writer.status == .writing { writer.cancelWriting() }
    }
}

/// Writes `frame_00000.png` (or .jpg) files.
public final class ImageSequenceSink: FrameSink {
    public enum Format { case png, jpeg(quality: Double) }
    private let dir: URL, format: Format
    private var index = 0

    public init(directory: URL, format: Format = .png) throws {
        dir = directory; self.format = format
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func append(_ frame: Snapshot) async throws {
        let (data, ext): (Data, String)
        switch format {
        case .png: (data, ext) = (frame.pngData(), "png")
        case .jpeg(let q): (data, ext) = (frame.jpegData(quality: q), "jpg")
        }
        guard !data.isEmpty else { throw SafariumError.encode("image encode failed") }
        try data.write(to: dir.appendingPathComponent(String(format: "frame_%05d.%@", index, ext)))
        index += 1
    }
    public func finish() async throws {}
}
