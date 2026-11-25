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

public enum VideoCodec: String, CustomStringConvertible, Sendable, CaseIterable {
    case h264
    case hevc
    case hevc10
    case hevc42210
    case hevc44410
    case hevcAlpha
    case proRes422Proxy
    case proRes422LT
    case proRes422
    case proRes422HQ
    case proRes4444
    case proRes4444XQ

    public var description: String { rawValue }

    public var isProRes: Bool {
        switch self {
        case .proRes422Proxy, .proRes422LT, .proRes422, .proRes422HQ, .proRes4444, .proRes4444XQ:
            return true
        default:
            return false
        }
    }

    public var isHEVC: Bool {
        switch self {
        case .hevc, .hevc10, .hevc42210, .hevc44410, .hevcAlpha:
            return true
        default:
            return false
        }
    }

    public var is10Bit: Bool {
        switch self {
        case .hevc10, .hevc42210, .hevc44410,
             .proRes422Proxy, .proRes422LT, .proRes422, .proRes422HQ, .proRes4444, .proRes4444XQ:
            return true
        default:
            return false
        }
    }

    public var avCodec: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc, .hevc10, .hevc42210, .hevc44410: return .hevc
        case .hevcAlpha: return .hevcWithAlpha
        case .proRes422Proxy: return .proRes422Proxy
        case .proRes422LT: return .proRes422LT
        case .proRes422: return .proRes422
        case .proRes422HQ: return .proRes422HQ
        case .proRes4444: return .proRes4444
        case .proRes4444XQ: return AVVideoCodecType(rawValue: "ap4x")
        }
    }

    public var cmCodecType: CMVideoCodecType {
        switch self {
        case .h264: return kCMVideoCodecType_H264
        case .hevc, .hevc10, .hevc42210, .hevc44410: return kCMVideoCodecType_HEVC
        case .hevcAlpha: return kCMVideoCodecType_HEVCWithAlpha
        case .proRes422Proxy: return kCMVideoCodecType_AppleProRes422Proxy
        case .proRes422LT: return kCMVideoCodecType_AppleProRes422LT
        case .proRes422: return kCMVideoCodecType_AppleProRes422
        case .proRes422HQ: return kCMVideoCodecType_AppleProRes422HQ
        case .proRes4444: return kCMVideoCodecType_AppleProRes4444
        case .proRes4444XQ: return kCMVideoCodecType_AppleProRes4444XQ
        }
    }

    public var defaultProfileLevel: String? {
        switch self {
        case .hevc10: return kVTProfileLevel_HEVC_Main10_AutoLevel as String
        case .hevc42210: return "HEVC_Main42210_AutoLevel"
        case .hevc44410: return "HEVC_Main44410_AutoLevel"
        default: return nil
        }
    }

    public var fileType: AVFileType {
        switch self {
        case .h264, .hevc, .hevc10: return .mp4
        case .hevc42210, .hevc44410, .hevcAlpha,
             .proRes422Proxy, .proRes422LT, .proRes422, .proRes422HQ, .proRes4444, .proRes4444XQ:
            return .mov
        }
    }

    public var fileExtension: String { fileType == .mp4 ? "mp4" : "mov" }

    public var hasAlpha: Bool {
        self == .hevcAlpha || self == .proRes4444 || self == .proRes4444XQ
    }

    public var defaultPixelFormat: SinkPixelFormat {
        switch self {
        case .hevcAlpha, .proRes4444, .proRes4444XQ: return .bgra
        case .hevc10: return .p010
        case .hevc42210: return .p210
        case .hevc44410: return .p410
        default: return .nv12Left
        }
    }

    public var cliDisplayName: String {
        switch self {
        case .h264: return "h264"
        case .hevc: return "hevc"
        case .hevc10: return "hevc-10bit"
        case .hevc42210: return "hevc-422-10bit"
        case .hevc44410: return "hevc-444-10bit"
        case .hevcAlpha: return "hevc-alpha"
        case .proRes422Proxy: return "prores422-proxy"
        case .proRes422LT: return "prores422-lt"
        case .proRes422: return "prores422"
        case .proRes422HQ: return "prores422-hq"
        case .proRes4444: return "prores4444"
        case .proRes4444XQ: return "prores4444-xq"
        }
    }

    public static func parseCLI(_ s: String) -> VideoCodec? {
        switch s.lowercased() {
        case "h264", "avc", "avc1": return .h264
        case "hevc", "h265", "hvc1": return .hevc
        case "hevc-10bit", "hevc10", "h265-10bit", "main10": return .hevc10
        case "hevc-422-10bit", "hevc-422-10", "hevc42210", "hevc422", "hevc-422": return .hevc42210
        case "hevc-444-10bit", "hevc-444-10", "hevc44410", "hevc444", "hevc-444": return .hevc44410
        case "hevc-alpha", "hevcalpha", "hevc_alpha", "muxa": return .hevcAlpha
        case "prores422-proxy", "prores422proxy", "prores-proxy", "prores_proxy", "apco": return .proRes422Proxy
        case "prores422-lt", "prores422lt", "prores-lt", "prores_lt", "apcs": return .proRes422LT
        case "prores422", "prores-422", "prores_422", "apcn": return .proRes422
        case "prores422-hq", "prores422hq", "prores-hq", "prores_hq", "apch": return .proRes422HQ
        case "prores4444", "prores-4444", "prores_4444", "ap4h": return .proRes4444
        case "prores4444-xq", "prores4444xq", "prores-xq", "prores_xq", "ap4x": return .proRes4444XQ
        default: return nil
        }
    }
}

public enum SinkPixelFormat: String, Sendable {
    case bgra
    case nv12vImage
    case nv12Left
    /// 10-bit 4:2:0 bi-planar video range (`x420` / P010LE).
    case p010
    /// 10-bit 4:2:2 bi-planar video range (`x422` / P210LE).
    case p210
    /// 10-bit 4:4:4 bi-planar video range (`x444` / P410LE).
    case p410

    public var isSubsampled420: Bool {
        self == .nv12vImage || self == .nv12Left || self == .p010
    }

    public var isSubsampled422: Bool {
        self == .p210
    }

    public var is10Bit: Bool {
        self == .p010 || self == .p210 || self == .p410
    }

    public var cvPixelFormat: OSType {
        switch self {
        case .bgra: return kCVPixelFormatType_32BGRA
        case .nv12vImage, .nv12Left: return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .p010: return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case .p210: return kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange
        case .p410: return kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange
        }
    }
}

/// Video color mastering & HDR transfer pipeline tag.
public enum ColorMasteringProfile: String, Codable, Sendable, CaseIterable {
    case sdrBT709 = "sdr"
    case hdr10PQ = "hdr10"
    case hlgBT2100 = "hlg"
    case dolbyVision84 = "dv84"
    case appleLog = "apple-log"
    case appleLog2 = "apple-log2"

    public var isHDR: Bool { self != .sdrBT709 }

    public var isBT2020: Bool { self != .sdrBT709 }

    public var avColorProperties: [String: Any] {
        switch self {
        case .sdrBT709:
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        case .hdr10PQ:
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        case .hlgBT2100, .dolbyVision84:
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        case .appleLog, .appleLog2:
            return [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        }
    }

    public func tagPixelBuffer(_ pb: CVPixelBuffer) {
        switch self {
        case .sdrBT709:
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        case .hdr10PQ:
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        case .hlgBT2100, .dolbyVision84:
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        case .appleLog:
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(pb, "LogTransferFunction" as CFString, "com.apple.rec2020.apple-log" as CFString, .shouldPropagate)
        case .appleLog2:
            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(pb, "LogTransferFunction" as CFString, "com.apple.apple-wide-gamut.apple-log" as CFString, .shouldPropagate)
        }
        CVBufferSetAttachment(pb, kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Left, .shouldPropagate)
    }

    public static func parseCLI(_ s: String) -> ColorMasteringProfile? {
        switch s.lowercased() {
        case "sdr", "bt709", "rec709": return .sdrBT709
        case "hdr10", "pq", "st2084": return .hdr10PQ
        case "hlg", "bt2100": return .hlgBT2100
        case "dv84", "dolby-vision", "dolbyvision", "dv": return .dolbyVision84
        case "apple-log", "applelog": return .appleLog
        case "apple-log2", "applelog2": return .appleLog2
        default: return nil
        }
    }
}

/// Constrained VBR + VBV rate-control configuration (macOS 26+ VideoToolbox, falls back to AverageBitRate on macOS 14-15).
public struct ConstrainedVBRConfig: Sendable, Equatable {
    public var targetBitrate: Int
    public var maxBitrate: Int
    public var bufferDurationSeconds: Double
    public var initialDelayPercentage: Double

    public init(
        targetBitrate: Int,
        maxBitrate: Int? = nil,
        bufferDurationSeconds: Double = 4.0,
        initialDelayPercentage: Double = 90.0
    ) {
        self.targetBitrate = max(64_000, targetBitrate)
        self.maxBitrate = max(self.targetBitrate, maxBitrate ?? Int(Double(self.targetBitrate) * 1.5))
        self.bufferDurationSeconds = max(0.5, bufferDurationSeconds)
        self.initialDelayPercentage = min(100.0, max(10.0, initialDelayPercentage))
    }
}

/// Wrapper around macOS 15+ `VTHDRPerFrameMetadataGenerationSession` for live Dolby Vision Profile 8.4 dynamic metadata.
public final class HDRDynamicMetadataGenerator: @unchecked Sendable {
    private let sessionRef: AnyObject?

    public init(fps: Float) {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) {
            self.sessionRef = try? VTHDRPerFrameMetadataGenerationSession(
                framesPerSecond: max(1.0, fps),
                hdrFormats: [.dolbyVision]
            )
        } else {
            self.sessionRef = nil
        }
        #else
        self.sessionRef = nil
        #endif
    }

    public var isAvailable: Bool { sessionRef != nil }

    @discardableResult
    public func attach(to pixelBuffer: CVPixelBuffer, sceneChange: Bool = false) -> Bool {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *), let session = sessionRef as? VTHDRPerFrameMetadataGenerationSession {
            return (try? session.attachMetadata(to: pixelBuffer, sceneChange: sceneChange)) != nil
        }
        #endif
        return false
    }
}

/// Hardware encoder and buffer-pool tuning profile (Wave 9 macOS 15-27 Apple Silicon unlocked).
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
    /// macOS 15+ `SpatialAdaptiveQPLevel`: `true` -> default (-1), `false` -> disabled (0), `nil` -> unset.
    public var spatialAdaptiveQP: Bool?
    /// Hardware perceptual quality optimization hint (`PerceptualQualityOptimization`) when supported.
    public var perceptualQualityOptimization: Bool?
    /// macOS 27+ `ConstantQualityFactor` (`0.0...1.0`); automatically falls back to `AVVideoQualityKey` on older macOS.
    public var constantQualityFactor: Double?
    /// macOS 26+ Constrained VBR + VBV rate control; automatically falls back to `AverageBitRate` on older macOS.
    public var constrainedVBR: ConstrainedVBRConfig?
    /// Color mastering & HDR metadata profile (defaults to SDR BT.709).
    public var colorMastering: ColorMasteringProfile
    /// Explicit VideoToolbox `ProfileLevel` string override (auto-populated for `hevc10`/`hevc42210`/`hevc44410`).
    public var profileLevelOverride: String?

    public init(
        allowFrameReordering: Bool = true,
        allowOpenGOP: Bool = true,
        suggestedLookAheadFrameCount: Int? = nil,
        maxFrameDelayCount: Int? = nil,
        prioritizeEncodingSpeed: Bool = false,
        maxKeyFrameInterval: Int? = nil,
        maxKeyFrameIntervalDuration: Double? = nil,
        poolAllocationThreshold: Int? = nil,
        expectedSourceFrameRate: Int? = nil,
        spatialAdaptiveQP: Bool? = nil,
        perceptualQualityOptimization: Bool? = nil,
        constantQualityFactor: Double? = nil,
        constrainedVBR: ConstrainedVBRConfig? = nil,
        colorMastering: ColorMasteringProfile = .sdrBT709,
        profileLevelOverride: String? = nil
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
        self.spatialAdaptiveQP = spatialAdaptiveQP
        self.perceptualQualityOptimization = perceptualQualityOptimization
        self.constantQualityFactor = constantQualityFactor
        self.constrainedVBR = constrainedVBR
        self.colorMastering = colorMastering
        self.profileLevelOverride = profileLevelOverride
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

    /// Wave 9 maximum-efficiency single-pass profile: B-frames + 16-frame lookahead + Spatial AQ + Perceptual Quality.
    public static let supremacyQuality = EncoderProfile(
        allowFrameReordering: true,
        allowOpenGOP: true,
        suggestedLookAheadFrameCount: 16,
        maxFrameDelayCount: nil,
        prioritizeEncodingSpeed: false,
        spatialAdaptiveQP: true,
        perceptualQualityOptimization: true
    )

    /// Wave 9 macOS 27 `ConstantQualityFactor` (`CQF`) + Spatial AQ + 8-frame lookahead profile.
    public static func supremacyCQF(
        _ factor: Double = 0.55,
        colorMastering: ColorMasteringProfile = .sdrBT709
    ) -> EncoderProfile {
        EncoderProfile(
            allowFrameReordering: true,
            allowOpenGOP: true,
            suggestedLookAheadFrameCount: 8,
            maxFrameDelayCount: nil,
            prioritizeEncodingSpeed: false,
            spatialAdaptiveQP: true,
            perceptualQualityOptimization: true,
            constantQualityFactor: min(1.0, max(0.05, factor)),
            colorMastering: colorMastering
        )
    }

    /// Wave 9 macOS 26+ Constrained VBR + VBV + Spatial AQ + 16-frame lookahead profile.
    public static func supremacyVBR(
        targetBitrate: Int,
        maxBitrate: Int? = nil,
        bufferSeconds: Double = 4.0,
        colorMastering: ColorMasteringProfile = .sdrBT709
    ) -> EncoderProfile {
        EncoderProfile(
            allowFrameReordering: true,
            allowOpenGOP: true,
            suggestedLookAheadFrameCount: 16,
            maxFrameDelayCount: nil,
            prioritizeEncodingSpeed: false,
            spatialAdaptiveQP: true,
            perceptualQualityOptimization: true,
            constrainedVBR: ConstrainedVBRConfig(
                targetBitrate: targetBitrate,
                maxBitrate: maxBitrate,
                bufferDurationSeconds: bufferSeconds
            ),
            colorMastering: colorMastering
        )
    }
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
    private let hdrMetaGenerator: HDRDynamicMetadataGenerator?
    private var nv12Info: vImage_ARGBToYpCbCr?
    private var bgraScratch: [UInt8] = []
    private let scratchBandContext: CGContext?
    private let width: Int, height: Int, fps: Int32
    private var index: Int64 = 0
    private var endTime: CMTime?
    private var finished = false

    /// - bitrate: average bits/s (H.264/HEVC); ignored for ProRes.
    /// - quality: 0...1 quality (HEVC/HEVC-alpha/H.264); used instead of bitrate when set.
    /// - pixelFormat: defaults to `codec.defaultPixelFormat` (`.bgra` for alpha/4444, `.p010`/`.p210`/`.p410` for 10-bit HEVC, `.nv12Left` for 8-bit).
    /// - profile: encoder & pool backpressure settings (`.baseline`, `.lowRamClosedGOP`, `.supremacyQuality`, `.supremacyCQF(...)`, `.supremacyVBR(...)`).
    public init(url: URL, width: Int, height: Int, fps: Int, codec: VideoCodec,
                bitrate: Int? = nil, quality: Double? = nil,
                pixelFormat: SinkPixelFormat? = nil,
                profile: EncoderProfile = .baseline,
                encoderSpecification: [String: Any]? = nil) throws {
        let resolvedPixelFormat = pixelFormat ?? codec.defaultPixelFormat
        guard width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 33_554_432 else {
            throw SafariumError.encode("dimensions must be <= 8192 per side and 33554432 pixels, got \(width)x\(height)")
        }
        if resolvedPixelFormat.isSubsampled420 && (width % 2 != 0 || height % 2 != 0) {
            throw SafariumError.encode("\(resolvedPixelFormat.rawValue) requires even dimensions, got \(width)x\(height)")
        }
        if resolvedPixelFormat.isSubsampled422 && (width % 2 != 0) {
            throw SafariumError.encode("\(resolvedPixelFormat.rawValue) requires even width, got \(width)x\(height)")
        }
        if let b = bitrate, b <= 0 {
            throw SafariumError.encode("bitrate must be > 0")
        }
        if let q = quality, !q.isFinite || q <= 0 || q > 1.0 {
            throw SafariumError.encode("quality must be finite in (0, 1]")
        }
        if let cqf = profile.constantQualityFactor, !cqf.isFinite || cqf <= 0 || cqf > 1.0 {
            throw SafariumError.encode("constantQualityFactor must be finite in (0, 1]")
        }
        guard let rate = Int32(exactly: fps), rate > 0 else { throw SafariumError.encode("fps must be a positive Int32") }
        if resolvedPixelFormat != .bgra && codec.hasAlpha {
            throw SafariumError.invalidState("\(resolvedPixelFormat.rawValue) pixel format does not support alpha codec \(codec)")
        }
        self.width = width; self.height = height; self.fps = rate
        self.pixelFormat = resolvedPixelFormat
        self.profile = profile
        self.hdrMetaGenerator = (profile.colorMastering == .dolbyVision84)
            ? HDRDynamicMetadataGenerator(fps: Float(fps))
            : nil
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
        // selects (e.g. software fallback while the HW encoder is busy or older macOS SDK) lacks a requested property.
        let (settings, dropped) = try Self.resolveSupportedSettings(requested, writer: writer, codec: codec)
        droppedCompressionProperties = dropped
        if !dropped.isEmpty {
            FileHandle.standardError.write(Data("safarium: warning: encoder for \(codec) does not support \(dropped.joined(separator: ", ")); dropped/adapted (encoded spec unchanged)\n".utf8))
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

    /// Compression properties dropped or adapted because the selected encoder/OS rejected them.
    public let droppedCompressionProperties: [String]

    /// Encoder hints that do not alter the encoded spec (rate/quality, GOP structure, colour, size): speed/latency
    /// & perceptual tuning only. Anything else unsupported is an error, never silently dropped.
    package static var droppableCompressionKeys: [String] {
        var keys = [
            "PerceptualQualityOptimization",
            "SpatialAdaptiveQPLevel",
            kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String,
        ]
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) { keys.append(kVTCompressionPropertyKey_SuggestedLookAheadFrameCount as String) }
        #endif
        keys.append(kVTCompressionPropertyKey_MaxFrameDelayCount as String)
        keys.append("LogTransferFunction")
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

    /// Returns settings AVAssetWriterInput will accept (`canApply`), gracefully adapting macOS 26/27 rate-control keys
    /// on older OS releases and dropping only `droppableCompressionKeys`.
    package static func resolveSupportedSettings(
        _ settings: [String: Any], writer: AVAssetWriter, codec: VideoCodec,
        canApply: (([String: Any]) -> Bool)? = nil
    ) throws -> (settings: [String: Any], dropped: [String]) {
        let check: ([String: Any]) -> Bool = canApply ?? { writer.canApply(outputSettings: $0, forMediaType: .video) }
        var current = settings
        if check(current) { return (current, []) }
        var dropped: [String] = []

        // First drop optional perceptual/speed hints.
        for key in droppableKeys(for: settings) {
            guard var props = current[AVVideoCompressionPropertiesKey] as? [String: Any], props[key] != nil else { continue }
            props[key] = nil
            current[AVVideoCompressionPropertiesKey] = props.isEmpty ? nil : props
            dropped.append(key)
            if check(current) { return (current, dropped) }
        }

        // Adapt macOS 27 `ConstantQualityFactor` -> legacy `AVVideoQualityKey` if running on macOS 14-26.
        if var props = current[AVVideoCompressionPropertiesKey] as? [String: Any],
           let cqf = props["ConstantQualityFactor"] {
            props["ConstantQualityFactor"] = nil
            if props[AVVideoQualityKey] == nil { props[AVVideoQualityKey] = cqf }
            current[AVVideoCompressionPropertiesKey] = props
            dropped.append("ConstantQualityFactor->Quality")
            if check(current) { return (current, dropped) }
        }

        // Adapt macOS 26 `VariableBitRate` + VBV -> `AVVideoAverageBitRateKey` if running on macOS 14-15.
        if var props = current[AVVideoCompressionPropertiesKey] as? [String: Any],
           let vbr = props["VariableBitRate"] {
            props["VariableBitRate"] = nil
            props["VBVMaxBitRate"] = nil
            props["VBVBufferDuration"] = nil
            props["VBVInitialDelayPercentage"] = nil
            if props[AVVideoAverageBitRateKey] == nil { props[AVVideoAverageBitRateKey] = vbr }
            current[AVVideoCompressionPropertiesKey] = props
            dropped.append("VariableBitRate->AverageBitRate")
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
        if !codec.isProRes {
            // Rate control priority: ConstantQualityFactor (macOS 27+) -> Constrained VBR (macOS 26+) -> legacy quality -> ABR.
            if let cqf = profile.constantQualityFactor {
                props["ConstantQualityFactor"] = cqf
            } else if let vbr = profile.constrainedVBR {
                props["VariableBitRate"] = vbr.targetBitrate
                props["VBVMaxBitRate"] = vbr.maxBitrate
                props["VBVBufferDuration"] = vbr.bufferDurationSeconds
                props["VBVInitialDelayPercentage"] = vbr.initialDelayPercentage
            } else if let q = quality {
                props[AVVideoQualityKey] = q
            } else if codec == .hevcAlpha {
                props[AVVideoQualityKey] = 0.85
            } else if let b = bitrate {
                props[AVVideoAverageBitRateKey] = b
            }

            if let profLevel = profile.profileLevelOverride ?? codec.defaultProfileLevel {
                props[AVVideoProfileLevelKey] = profLevel
            }
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
            if let aq = profile.spatialAdaptiveQP {
                props["SpatialAdaptiveQPLevel"] = aq ? -1 : 0
            }
            if let pqo = profile.perceptualQualityOptimization {
                props["PerceptualQualityOptimization"] = pqo
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
            if profile.colorMastering.isHDR {
                props[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] = kVTHDRMetadataInsertionMode_Auto as String
                if profile.colorMastering == .dolbyVision84 {
                    props[kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String] = true
                }
                if profile.colorMastering == .appleLog {
                    props["LogTransferFunction"] = "com.apple.rec2020.apple-log"
                } else if profile.colorMastering == .appleLog2 {
                    props["LogTransferFunction"] = "com.apple.apple-wide-gamut.apple-log"
                }
            }
        }
        if !props.isEmpty { settings[AVVideoCompressionPropertiesKey] = props }
        settings[AVVideoColorPropertiesKey] = profile.colorMastering.avColorProperties
        return settings
    }

    public static func pixelBufferAttributes(
        width: Int, height: Int, pixelFormat: SinkPixelFormat, allocationThreshold: Int? = nil
    ) -> [String: Any] {
        var attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat.cvPixelFormat,
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

    /// Converts 8-bit BGRA pixels into 10-bit bi-planar video-range YCbCr (`p010` 4:2:0, `p210` 4:2:2, or `p410` 4:4:4)
    /// using BT.709 or BT.2020 matrix and subtle 4x4 Bayer ordered dithering to eliminate 8-bit gradient banding.
    public static func convertBGRATo10BitBiPlanar(
        bgra: UnsafeRawPointer,
        bgraBytesPerRow: Int,
        into pb: CVPixelBuffer,
        width: Int,
        height: Int,
        pixelFormat: SinkPixelFormat,
        colorMastering: ColorMasteringProfile = .sdrBT709
    ) throws {
        guard pixelFormat.is10Bit else {
            throw SafariumError.encode("convertBGRATo10BitBiPlanar requires 10-bit pixelFormat, got \(pixelFormat)")
        }
        guard CVPixelBufferLockBaseAddress(pb, []) == kCVReturnSuccess else {
            throw SafariumError.encode("failed to lock 10-bit destination pixel buffer")
        }
        defer { _ = CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else {
            throw SafariumError.encode("missing 10-bit pixel buffer planes")
        }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0) / 2
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1) / 2
        let yPtr = yBase.assumingMemoryBound(to: UInt16.self)
        let uvPtr = uvBase.assumingMemoryBound(to: UInt16.self)
        let src = bgra.assumingMemoryBound(to: UInt8.self)

        // ITU-R BT.709 vs BT.2020 limited-range 10-bit coefficients (Y in [64, 940], Cb/Cr in [64, 960], << 6 for P010/P210/P410 MSB layout).
        let kr: Float = colorMastering.isBT2020 ? 0.2627 : 0.2126
        let kb: Float = colorMastering.isBT2020 ? 0.0593 : 0.0722
        let kg: Float = 1.0 - kr - kb
        let yScale: Float = 876.0 / 255.0
        let cScale: Float = 896.0 / 255.0
        let cbNorm: Float = 0.5 / (1.0 - kb)
        let crNorm: Float = 0.5 / (1.0 - kr)

        // Subtle 4x4 Bayer ordered dither in [-0.5, +0.5) 10-bit steps to smooth 8-bit gradients cleanly.
        let bayer4: [Float] = [
            -0.46875,  0.03125, -0.34375,  0.15625,
             0.28125, -0.21875,  0.40625, -0.09375,
            -0.28125,  0.21875, -0.40625,  0.09375,
             0.46875, -0.03125,  0.34375, -0.15625,
        ]

        @inline(__always)
        func clamp10(_ v: Float) -> UInt16 {
            let iv = Int(v.rounded())
            let c = max(64, min(960, iv))
            return UInt16(c << 6)
        }

        // Plane 0: Full-resolution 10-bit Y with ordered dithering.
        for row in 0..<height {
            let sRow = src.advanced(by: row * bgraBytesPerRow)
            let dRow = yPtr.advanced(by: row * yStride)
            let by = (row & 3) << 2
            for x in 0..<width {
                let off = x << 2
                let b = Float(sRow[off])
                let g = Float(sRow[off + 1])
                let r = Float(sRow[off + 2])
                let luma = kr * r + kg * g + kb * b
                let dither = bayer4[by | (x & 3)]
                let y10 = 64.0 + luma * yScale + dither
                dRow[x] = clamp10(min(940.0, max(64.0, y10)))
            }
        }

        // Plane 1: Interleaved 10-bit Cb/Cr according to chroma subsampling (4:2:0 / 4:2:2 / 4:4:4).
        switch pixelFormat {
        case .p010:
            let ch = height / 2
            let cw = width / 2
            for cy in 0..<ch {
                let r0 = src.advanced(by: (cy * 2) * bgraBytesPerRow)
                let r1 = src.advanced(by: (cy * 2 + 1) * bgraBytesPerRow)
                let uvRow = uvPtr.advanced(by: cy * uvStride)
                for cx in 0..<cw {
                    let x0 = (cx * 2) << 2
                    let x1 = x0 + 4
                    // Left-sited 4:2:0 average (2x2 box for stability).
                    let b = (Float(r0[x0]) + Float(r0[x1]) + Float(r1[x0]) + Float(r1[x1])) * 0.25
                    let g = (Float(r0[x0 + 1]) + Float(r0[x1 + 1]) + Float(r1[x0 + 1]) + Float(r1[x1 + 1])) * 0.25
                    let r = (Float(r0[x0 + 2]) + Float(r0[x1 + 2]) + Float(r1[x0 + 2]) + Float(r1[x1 + 2])) * 0.25
                    let luma = kr * r + kg * g + kb * b
                    let cb = 512.0 + (b - luma) * cbNorm * cScale
                    let cr = 512.0 + (r - luma) * crNorm * cScale
                    uvRow[cx * 2] = clamp10(cb)
                    uvRow[cx * 2 + 1] = clamp10(cr)
                }
            }
        case .p210:
            let cw = width / 2
            for row in 0..<height {
                let r0 = src.advanced(by: row * bgraBytesPerRow)
                let uvRow = uvPtr.advanced(by: row * uvStride)
                for cx in 0..<cw {
                    let x0 = (cx * 2) << 2
                    let x1 = x0 + 4
                    let b = (Float(r0[x0]) + Float(r0[x1])) * 0.5
                    let g = (Float(r0[x0 + 1]) + Float(r0[x1 + 1])) * 0.5
                    let r = (Float(r0[x0 + 2]) + Float(r0[x1 + 2])) * 0.5
                    let luma = kr * r + kg * g + kb * b
                    let cb = 512.0 + (b - luma) * cbNorm * cScale
                    let cr = 512.0 + (r - luma) * crNorm * cScale
                    uvRow[cx * 2] = clamp10(cb)
                    uvRow[cx * 2 + 1] = clamp10(cr)
                }
            }
        case .p410:
            for row in 0..<height {
                let r0 = src.advanced(by: row * bgraBytesPerRow)
                let uvRow = uvPtr.advanced(by: row * uvStride)
                for x in 0..<width {
                    let off = x << 2
                    let b = Float(r0[off])
                    let g = Float(r0[off + 1])
                    let r = Float(r0[off + 2])
                    let luma = kr * r + kg * g + kb * b
                    let cb = 512.0 + (b - luma) * cbNorm * cScale
                    let cr = 512.0 + (r - luma) * crNorm * cScale
                    uvRow[x * 2] = clamp10(cb)
                    uvRow[x * 2 + 1] = clamp10(cr)
                }
            }
        default:
            break
        }
        colorMastering.tagPixelBuffer(pb)
    }

    /// Converts a `CVPixelBuffer` (BGRA) into a 10-bit bi-planar `CVPixelBuffer` (`p010`/`p210`/`p410`).
    public static func convertBGRAPixelBufferTo10Bit(
        _ srcBGRA: CVPixelBuffer,
        into dst10Bit: CVPixelBuffer,
        pixelFormat: SinkPixelFormat,
        colorMastering: ColorMasteringProfile = .sdrBT709
    ) throws {
        guard CVPixelBufferLockBaseAddress(srcBGRA, .readOnly) == kCVReturnSuccess else {
            throw SafariumError.encode("failed to lock BGRA source pixel buffer")
        }
        defer { _ = CVPixelBufferUnlockBaseAddress(srcBGRA, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(srcBGRA) else {
            throw SafariumError.encode("missing BGRA base address")
        }
        try convertBGRATo10BitBiPlanar(
            bgra: base,
            bgraBytesPerRow: CVPixelBufferGetBytesPerRow(srcBGRA),
            into: dst10Bit,
            width: CVPixelBufferGetWidth(dst10Bit),
            height: CVPixelBufferGetHeight(dst10Bit),
            pixelFormat: pixelFormat,
            colorMastering: colorMastering
        )
    }

    public static func allocateStandalonePixelBuffer(
        width: Int, height: Int, pixelFormat: SinkPixelFormat
    ) throws -> CVPixelBuffer {
        let attrs: [String: Any] = [
            kCVPixelBufferBytesPerRowAlignmentKey as String: 64,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat.cvPixelFormat, attrs as CFDictionary, &pb)
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
            profile.colorMastering.tagPixelBuffer(buf)
        case .nv12vImage:
            guard var info = nv12Info else { throw SafariumError.invalidState("missing NV12 converter") }
            try Self.writeNV12(frame, into: buf, width: width, height: height, info: &info, bgraScratch: &bgraScratch)
            nv12Info = info
            profile.colorMastering.tagPixelBuffer(buf)
        case .nv12Left:
            try SafariumAccelerate.convertBGRAToNV12BT709LeftBanded(
                snapshot: frame, scratchBand: scratchBandContext, into: buf, width: width, height: height
            )
            profile.colorMastering.tagPixelBuffer(buf)
        case .p010, .p210, .p410:
            let borrowed = try frame.borrowCanonicalBGRABytes(width: width, height: height) { raw, stride in
                try Self.convertBGRATo10BitBiPlanar(
                    bgra: raw, bgraBytesPerRow: stride, into: buf,
                    width: width, height: height, pixelFormat: pixelFormat,
                    colorMastering: profile.colorMastering
                )
                return true
            } ?? false
            if !borrowed {
                let stride = width * 4
                let needed = stride * height
                if bgraScratch.count < needed { bgraScratch = [UInt8](repeating: 0, count: needed) }
                try bgraScratch.withUnsafeMutableBytes { raw in
                    try frame.drawBGRAInto(baseAddress: raw.baseAddress!, width: width, height: height, stride: stride)
                    try Self.convertBGRATo10BitBiPlanar(
                        bgra: raw.baseAddress!, bgraBytesPerRow: stride, into: buf,
                        width: width, height: height, pixelFormat: pixelFormat,
                        colorMastering: profile.colorMastering
                    )
                }
            }
        }
        if let hdrMetaGenerator {
            _ = hdrMetaGenerator.attach(to: buf, sceneChange: false)
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
