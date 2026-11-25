import Accelerate
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Metal
import SafariumContainers
import SafariumCore
import SafariumForgeCore

// MARK: - Public Reports & Configuration Types

public struct PrismCapabilitiesReport: Codable, Sendable {
    public let version: String
    public let schema: String
    public let blenderAvailable: Bool
    public let blenderPath: String
    public let blenderVersion: String?
    public let workerScriptPath: String?
    public let workerScriptValid: Bool
    public let webkitWebGL2Available: Bool
    public let webkitWebGPUAvailable: Bool
    public let webkitRenderer: String?
    public let metalfxAvailable: Bool
    public let metalDeviceName: String?
    public let aneAvailable: Bool
    public let hidListenAccess: Bool
    public let thermalState: PrismThermalLevel
    public let taskpolicyAvailable: Bool
    public let notes: [String]
}

public struct PrismSyncResult: Codable, Sendable {
    public let blendPath: String
    public let glbPath: String
    public let irPath: String
    public let glbBytes: Int64
    public let irSHA256: String
    public let camera: PrismCameraIR
    public let timeline: PrismTimelineIR
    public let wallMs: Double
}

public enum PrismPreviewTier: String, Codable, Sendable, Equatable {
    case webkitGLB
    case warmBlender
    case auto

    public static func parse(_ raw: String) throws -> PrismPreviewTier {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "webkit", "webkitglb", "webkit-glb", "glb":
            return .webkitGLB
        case "blender", "warmblender", "warm-blender", "warm":
            return .warmBlender
        case "auto":
            return .auto
        default:
            throw SafariumError.invalidState("unsupported preview tier '\(raw)' (expected webkitGLB|warmBlender|auto)")
        }
    }
}

public struct PrismPreviewStillsReport: Codable, Sendable {
    public let inputPath: String
    public let tierUsed: String
    public let stillPaths: [String]
    public let contactSheetPath: String?
    public let stillsCaptured: Int
    public let width: Int
    public let height: Int
    public let meanStillMs: Double
    public let peakFootprintBytes: UInt64
    public let wallMs: Double
}

public struct PrismRenderReport: Codable, Sendable {
    public let inputPath: String
    public let outputPath: String
    public let secondaryOutputPath: String?
    public let engineUsed: String
    public let width: Int
    public let height: Int
    public let fps: Int
    public let frames: Int
    public let codec: String
    public let secondaryCodec: String?
    public let primaryBytes: Int64
    public let secondaryBytes: Int64?
    public let usedMetalFX: Bool
    public let didFallbackTo1x: Bool
    public let fallbackFrame: Int?
    public let fallbackReasons: [String]
    public let lastPQReport: SafariumPQReport?
    public let antiLagStats: PrismAntiLagStats
    public let peakFootprintBytes: UInt64
    public let wallMs: Double
}

public struct PrismCompositeReport: Codable, Sendable {
    public let blendPath: String
    public let backgroundPath: String?
    public let overlayHTMLPath: String?
    public let outputPath: String
    public let secondaryMOVPath: String?
    public let width: Int
    public let height: Int
    public let fps: Int
    public let frames: Int
    public let primaryCodec: String
    public let secondaryCodec: String?
    public let primaryBytes: Int64
    public let secondaryBytes: Int64?
    public let usedMetalFX: Bool
    public let didFallbackTo1x: Bool
    public let fallbackReasons: [String]
    public let lastPQReport: SafariumPQReport?
    public let antiLagStats: PrismAntiLagStats
    public let peakFootprintBytes: UInt64
    public let wallMs: Double
}

public struct PrismWebRenderOptions: Codable, Sendable, Equatable {
    public var readyExpr: String?
    public var initJS: String?
    public var initFileURL: URL?
    public var seekExpr: String?
    public var outputFPS: Int?
    public var grainIntensity: Double?
    public var grainSize: Double
    public var loudnormTargetI: Double?
    public var loudnormTruePeak: Double?
    public var audioPadToVideo: Bool
    public var fontDirURL: URL?
    public var injectFontFaceCSS: Bool
    public var metalSVGFilters: Bool
    public var preserveSharpText1x: Bool
    public var readyTimeoutSeconds: Double

    public init(
        readyExpr: String? = nil,
        initJS: String? = nil,
        initFileURL: URL? = nil,
        seekExpr: String? = nil,
        outputFPS: Int? = nil,
        grainIntensity: Double? = nil,
        grainSize: Double = 1.0,
        loudnormTargetI: Double? = nil,
        loudnormTruePeak: Double? = nil,
        audioPadToVideo: Bool = false,
        fontDirURL: URL? = nil,
        injectFontFaceCSS: Bool = true,
        metalSVGFilters: Bool = false,
        preserveSharpText1x: Bool = true,
        readyTimeoutSeconds: Double = 30.0
    ) {
        self.readyExpr = readyExpr
        self.initJS = initJS
        self.initFileURL = initFileURL
        self.seekExpr = seekExpr
        self.outputFPS = outputFPS
        self.grainIntensity = grainIntensity
        self.grainSize = grainSize
        self.loudnormTargetI = loudnormTargetI
        self.loudnormTruePeak = loudnormTruePeak
        self.audioPadToVideo = audioPadToVideo
        self.fontDirURL = fontDirURL
        self.injectFontFaceCSS = injectFontFaceCSS
        self.metalSVGFilters = metalSVGFilters
        self.preserveSharpText1x = preserveSharpText1x
        self.readyTimeoutSeconds = readyTimeoutSeconds
    }
}

// MARK: - Single-Pass Metal Layer Compositor

private struct PrismCompositeUniforms {
    var size: SIMD2<UInt32>
    var hasBg: UInt32
    var hasHero: UInt32
    var heroPremultiplied: UInt32
    var hasHud: UInt32
    var preserveAlpha: UInt32
    var _pad0: UInt32 = 0
    var solidBg: SIMD4<Float>
}

private struct PrismDropShadowUniforms {
    var size: SIMD2<UInt32>
    var offset: SIMD2<Float>
    var floodColor: SIMD4<Float>
    var hasBg: UInt32
    var preserveAlpha: UInt32
    var _pad0: SIMD2<UInt32> = .zero
}

private final class PrismMetalCompositor {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let textureCache: CVMetalTextureCache
    private let pipeline: MTLComputePipelineState
    private let shadowPipeline: MTLComputePipelineState
    private let dummy1x1Tex: MTLTexture

    private static let shaderSource = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct PrismCompositeUniforms {
        uint2  size;
        uint   hasBg;
        uint   hasHero;
        uint   heroPremultiplied;
        uint   hasHud;
        uint   preserveAlpha;
        uint   _pad0;
        float4 solidBg;
    };

    struct PrismDropShadowUniforms {
        uint2  size;
        float2 offset;
        float4 floodColor;
        uint   hasBg;
        uint   preserveAlpha;
        uint2  _pad0;
    };

    kernel void prism_composite_layers(
        texture2d<half, access::read>  bgTex   [[texture(0)]],
        texture2d<half, access::read>  heroTex [[texture(1)]],
        texture2d<half, access::read>  hudTex  [[texture(2)]],
        texture2d<half, access::write> dstTex  [[texture(3)]],
        constant PrismCompositeUniforms& u     [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.size.x || gid.y >= u.size.y) return;
        half4 out = (u.hasBg != 0u) ? bgTex.read(gid) : half4(u.solidBg);
        if (u.hasHero != 0u) {
            half4 hero = heroTex.read(gid);
            half4 hPre = (u.heroPremultiplied != 0u) ? hero : half4(hero.rgb * hero.a, hero.a);
            out = hPre + out * (1.0h - hPre.a);
        }
        if (u.hasHud != 0u) {
            half4 hud = hudTex.read(gid);
            out = hud + out * (1.0h - hud.a);
        }
        if (u.preserveAlpha == 0u) {
            out.a = 1.0h;
        }
        dstTex.write(clamp(out, 0.0h, 1.0h), gid);
    }

    inline half prism_read_alpha(texture2d<half, access::read> tex, uint2 size, int x, int y) {
        if (x < 0 || y < 0 || x >= int(size.x) || y >= int(size.y)) return 0.0h;
        return tex.read(uint2(uint(x), uint(y))).a;
    }

    inline half sample_alpha_bilinear(texture2d<half, access::read> tex, uint2 size, float2 pos) {
        if (pos.x < -1.0f || pos.y < -1.0f || pos.x > float(size.x) || pos.y > float(size.y)) {
            return 0.0h;
        }
        int x0 = int(floor(pos.x));
        int y0 = int(floor(pos.y));
        float fx = pos.x - float(x0);
        float fy = pos.y - float(y0);
        half a00 = prism_read_alpha(tex, size, x0, y0);
        half a10 = prism_read_alpha(tex, size, x0 + 1, y0);
        half a01 = prism_read_alpha(tex, size, x0, y0 + 1);
        half a11 = prism_read_alpha(tex, size, x0 + 1, y0 + 1);
        half a0 = mix(a00, a10, half(fx));
        half a1 = mix(a01, a11, half(fx));
        return mix(a0, a1, half(fy));
    }

    kernel void prism_drop_shadow_merge(
        texture2d<half, access::read>  bgTex   [[texture(0)]],
        texture2d<half, access::read>  srcTex  [[texture(1)]],
        texture2d<half, access::read>  blurTex [[texture(2)]],
        texture2d<half, access::write> dstTex  [[texture(3)]],
        constant PrismDropShadowUniforms& u    [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.size.x || gid.y >= u.size.y) return;
        half4 out = (u.hasBg != 0u) ? bgTex.read(gid) : half4(0.0h, 0.0h, 0.0h, 0.0h);

        float2 samplePos = float2(float(gid.x) - u.offset.x, float(gid.y) - u.offset.y);
        half blurA = sample_alpha_bilinear(blurTex, u.size, samplePos);
        half shA = clamp(blurA * half(u.floodColor.a), 0.0h, 1.0h);
        half4 shPre = half4(half3(u.floodColor.rgb) * shA, shA);
        out = shPre + out * (1.0h - shA);

        half4 fg = srcTex.read(gid);
        out = fg + out * (1.0h - fg.a);
        if (u.preserveAlpha == 0u) {
            out.a = 1.0h;
        }
        dstTex.write(clamp(out, 0.0h, 1.0h), gid);
    }
    """#

    init() throws {
        guard let ctx = SafariumMetalContext.shared else {
            throw SafariumError.encode("SafariumMetalContext.shared unavailable for PrismMetalCompositor")
        }
        self.device = ctx.device
        self.commandQueue = ctx.commandQueue
        self.textureCache = ctx.textureCache
        let lib = try device.makeLibrary(source: Self.shaderSource, options: nil)
        guard let fn = lib.makeFunction(name: "prism_composite_layers") else {
            throw SafariumError.encode("missing Metal kernel prism_composite_layers")
        }
        guard let sfn = lib.makeFunction(name: "prism_drop_shadow_merge") else {
            throw SafariumError.encode("missing Metal kernel prism_drop_shadow_merge")
        }
        self.pipeline = try device.makeComputePipelineState(function: fn)
        self.shadowPipeline = try device.makeComputePipelineState(function: sfn)

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        td.storageMode = .shared
        td.usage = [.shaderRead]
        guard let dummy = device.makeTexture(descriptor: td) else {
            throw SafariumError.encode("failed allocating dummy 1x1 Metal texture")
        }
        var zero: [UInt8] = [0, 0, 0, 0]
        dummy.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 4)
        self.dummy1x1Tex = dummy
    }

    func composite(
        bgPB: CVPixelBuffer?,
        heroPB: CVPixelBuffer?,
        heroPremultiplied: Bool,
        hudPB: CVPixelBuffer?,
        solidBg: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1),
        preserveAlpha: Bool = false,
        into dstPB: CVPixelBuffer
    ) throws {
        guard let ctx = SafariumMetalContext.shared else {
            throw SafariumError.encode("SafariumMetalContext.shared unavailable")
        }
        let w = CVPixelBufferGetWidth(dstPB)
        let h = CVPixelBufferGetHeight(dstPB)
        let bgBind = try bgPB.map { try ctx.bindBGRA8Texture(for: $0) }
        let heroBind = try heroPB.map { try ctx.bindBGRA8Texture(for: $0) }
        let hudBind = try hudPB.map { try ctx.bindBGRA8Texture(for: $0) }
        let (dstCV, dstTex) = try ctx.bindBGRA8Texture(for: dstPB)

        var uni = PrismCompositeUniforms(
            size: SIMD2<UInt32>(UInt32(w), UInt32(h)),
            hasBg: bgBind != nil ? 1 : 0,
            hasHero: heroBind != nil ? 1 : 0,
            heroPremultiplied: heroPremultiplied ? 1 : 0,
            hasHud: hudBind != nil ? 1 : 0,
            preserveAlpha: preserveAlpha ? 1 : 0,
            solidBg: solidBg
        )

        guard let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            throw SafariumError.encode("Metal command encoder unavailable for Prism composite")
        }
        let tw = min(16, pipeline.threadExecutionWidth)
        let th = max(1, min(16, pipeline.maxTotalThreadsPerThreadgroup / tw))
        let groups = MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1)
        let threads = MTLSize(width: tw, height: th, depth: 1)

        enc.setComputePipelineState(pipeline)
        enc.setTexture(bgBind?.1 ?? dummy1x1Tex, index: 0)
        enc.setTexture(heroBind?.1 ?? dummy1x1Tex, index: 1)
        enc.setTexture(hudBind?.1 ?? dummy1x1Tex, index: 2)
        enc.setTexture(dstTex, index: 3)
        enc.setBytes(&uni, length: MemoryLayout<PrismCompositeUniforms>.stride, index: 0)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        _ = (bgBind, heroBind, hudBind, dstCV)
        ctx.flushTextureCache()
        if let err = cmd.error {
            throw SafariumError.encode("Prism Metal composite failed: \(err)")
        }
    }

    func mergeDropShadow(
        bgPB: CVPixelBuffer?,
        srcPB: CVPixelBuffer,
        blurPB: CVPixelBuffer,
        dx: Float,
        dy: Float,
        floodColorRGBA: SIMD4<Float>,
        preserveAlpha: Bool,
        into dstPB: CVPixelBuffer
    ) throws {
        guard let ctx = SafariumMetalContext.shared else {
            throw SafariumError.encode("SafariumMetalContext.shared unavailable")
        }
        let w = CVPixelBufferGetWidth(dstPB)
        let h = CVPixelBufferGetHeight(dstPB)
        let bgBind = try bgPB.map { try ctx.bindBGRA8Texture(for: $0) }
        let srcBind = try ctx.bindBGRA8Texture(for: srcPB)
        let blurBind = try ctx.bindBGRA8Texture(for: blurPB)
        let (dstCV, dstTex) = try ctx.bindBGRA8Texture(for: dstPB)

        var uni = PrismDropShadowUniforms(
            size: SIMD2<UInt32>(UInt32(w), UInt32(h)),
            offset: SIMD2<Float>(dx, dy),
            floodColor: floodColorRGBA,
            hasBg: bgBind != nil ? 1 : 0,
            preserveAlpha: preserveAlpha ? 1 : 0
        )

        guard let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            throw SafariumError.encode("Metal command encoder unavailable for Prism drop shadow")
        }
        let tw = min(16, shadowPipeline.threadExecutionWidth)
        let th = max(1, min(16, shadowPipeline.maxTotalThreadsPerThreadgroup / tw))
        let groups = MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1)
        let threads = MTLSize(width: tw, height: th, depth: 1)

        enc.setComputePipelineState(shadowPipeline)
        enc.setTexture(bgBind?.1 ?? dummy1x1Tex, index: 0)
        enc.setTexture(srcBind.1, index: 1)
        enc.setTexture(blurBind.1, index: 2)
        enc.setTexture(dstTex, index: 3)
        enc.setBytes(&uni, length: MemoryLayout<PrismDropShadowUniforms>.stride, index: 0)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        _ = (bgBind, srcBind, blurBind, dstCV)
        ctx.flushTextureCache()
        if let err = cmd.error {
            throw SafariumError.encode("Prism Metal drop shadow failed: \(err)")
        }
    }
}

// MARK: - Dual-Tee APFS-Staged Video & Mux Sink

private final class PrismDualOutputSink {
    let width: Int
    let height: Int
    let fps: Int
    let primaryURL: URL
    let primaryCodec: VideoCodec
    let primaryPixelFormat: SinkPixelFormat
    let secondaryURL: URL?
    let secondaryCodec: VideoCodec?
    let secondaryPixelFormat: SinkPixelFormat?
    let overwrite: Bool

    private let primaryStage: APFSStageSession
    private let secondaryStage: APFSStageSession?
    private let stagedPrimaryVideo: URL
    private let stagedSecondaryVideo: URL?
    private let primarySink: AVAssetWriterSink
    private let secondarySink: AVAssetWriterSink?
    private var framesWritten = 0

    init(
        primaryOutputURL: URL,
        secondaryOutputURL: URL?,
        width: Int,
        height: Int,
        fps: Int,
        primaryCodec: VideoCodec,
        secondaryCodec: VideoCodec?,
        bitrate: Int,
        quality: Double?,
        overwrite: Bool
    ) throws {
        let pFmt: SinkPixelFormat = primaryCodec.hasAlpha ? .bgra : .nv12Left
        let resolvedSecCodec = secondaryCodec ?? (secondaryOutputURL != nil ? (secondaryOutputURL!.pathExtension.lowercased() == "mov" ? .proRes4444 : .h264) : nil)
        let sFmt: SinkPixelFormat? = resolvedSecCodec.map { $0.hasAlpha ? .bgra : .nv12Left }

        if pFmt != .bgra || (sFmt != nil && sFmt != .bgra) {
            guard width % 2 == 0, height % 2 == 0 else {
                throw SafariumError.invalidState("H.264/HEVC encoding requires even dimensions, got \(width)x\(height)")
            }
        }

        self.width = width
        self.height = height
        self.fps = fps
        self.primaryURL = primaryOutputURL
        self.primaryCodec = primaryCodec
        self.primaryPixelFormat = pFmt
        self.secondaryURL = secondaryOutputURL
        self.secondaryCodec = resolvedSecCodec
        self.secondaryPixelFormat = sFmt
        self.overwrite = overwrite

        self.primaryStage = try APFSAutoStage.makeSession(for: primaryOutputURL, overwrite: overwrite)
        do {
            self.secondaryStage = try secondaryOutputURL.map {
                try APFSAutoStage.makeSession(for: $0, overwrite: overwrite)
            }
            let pVid = primaryStage.fileURL("primary.\(primaryCodec.fileExtension)")
            self.stagedPrimaryVideo = pVid
            self.primarySink = try AVAssetWriterSink(
                url: pVid,
                width: width,
                height: height,
                fps: fps,
                codec: primaryCodec,
                bitrate: primaryCodec.isProRes ? nil : bitrate,
                quality: quality,
                pixelFormat: pFmt,
                profile: .lowRamClosedGOP
            )
            if let sCodec = resolvedSecCodec, secondaryOutputURL != nil {
                let sVid = primaryStage.fileURL("secondary.\(sCodec.fileExtension)")
                self.stagedSecondaryVideo = sVid
                self.secondarySink = try AVAssetWriterSink(
                    url: sVid,
                    width: width,
                    height: height,
                    fps: fps,
                    codec: sCodec,
                    bitrate: sCodec.isProRes ? nil : bitrate,
                    quality: quality,
                    pixelFormat: sFmt!,
                    profile: .lowRamClosedGOP
                )
            } else {
                self.stagedSecondaryVideo = nil
                self.secondarySink = nil
            }
        } catch {
            primaryStage.cleanup()
            throw error
        }
    }

    deinit {
        primaryStage.cleanup()
        secondaryStage?.cleanup()
    }

    func stageFileURL(_ name: String) -> URL {
        primaryStage.fileURL(name)
    }

    func append(primaryPB: CVPixelBuffer, secondaryPB: CVPixelBuffer? = nil, presentationTime: CMTime? = nil) async throws {
        try await Self.writePixelBuffer(
            primaryPB,
            into: primarySink,
            pixelFormat: primaryPixelFormat,
            width: width,
            height: height,
            presentationTime: presentationTime
        )
        if let secSink = secondarySink, let secFmt = secondaryPixelFormat {
            try await Self.writePixelBuffer(
                secondaryPB ?? primaryPB,
                into: secSink,
                pixelFormat: secFmt,
                width: width,
                height: height,
                presentationTime: presentationTime
            )
        }
        framesWritten += 1
        if framesWritten % 60 == 0 {
            primarySink.flushPool()
            secondarySink?.flushPool()
        }
    }

    func finishAndCommit(
        audioURL: URL?,
        subtitlesURL: URL?,
        subtitleLang: String
    ) async throws -> (primaryBytes: Int64, secondaryBytes: Int64?) {
        try await primarySink.finish()
        try await secondarySink?.finish()

        let finalPrimary: URL
        if audioURL != nil || subtitlesURL != nil {
            let muxed = primaryStage.fileURL("primary_muxed.\(primaryCodec.fileExtension)")
            _ = try await LosslessSoundtrackMux.mux(
                videoURL: stagedPrimaryVideo,
                wavURL: audioURL,
                subtitlesURL: subtitlesURL,
                subtitleLang: subtitleLang,
                outputURL: muxed,
                overwrite: true
            )
            finalPrimary = muxed
        } else {
            finalPrimary = stagedPrimaryVideo
        }
        try primaryStage.commit(stagedFile: finalPrimary, to: primaryURL, overwrite: overwrite)
        let priBytes = Self.fileSize(primaryURL)

        var secBytes: Int64?
        if let secOut = secondaryURL, let secStage = secondaryStage, let sVid = stagedSecondaryVideo, let sCodec = secondaryCodec {
            let finalSec: URL
            if audioURL != nil || subtitlesURL != nil {
                let muxed = primaryStage.fileURL("secondary_muxed.\(sCodec.fileExtension)")
                _ = try await LosslessSoundtrackMux.mux(
                    videoURL: sVid,
                    wavURL: audioURL,
                    subtitlesURL: subtitlesURL,
                    subtitleLang: subtitleLang,
                    outputURL: muxed,
                    overwrite: true
                )
                finalSec = muxed
            } else {
                finalSec = sVid
            }
            try secStage.commit(stagedFile: finalSec, to: secOut, overwrite: overwrite)
            secBytes = Self.fileSize(secOut)
        }
        return (priBytes, secBytes)
    }

    func cancel() {
        primarySink.cancel()
        secondarySink?.cancel()
        primaryStage.cleanup()
        secondaryStage?.cleanup()
    }

    private static func writePixelBuffer(
        _ srcPB: CVPixelBuffer,
        into sink: AVAssetWriterSink,
        pixelFormat: SinkPixelFormat,
        width: Int,
        height: Int,
        presentationTime: CMTime? = nil
    ) async throws {
        try await sink.append(presentationTime: presentationTime) { dstPB in
            guard CVPixelBufferLockBaseAddress(srcPB, .readOnly) == kCVReturnSuccess else {
                throw SafariumError.encode("cannot lock source CVPixelBuffer")
            }
            defer { _ = CVPixelBufferUnlockBaseAddress(srcPB, .readOnly) }
            guard let srcBase = CVPixelBufferGetBaseAddress(srcPB) else {
                throw SafariumError.encode("missing source CVPixelBuffer baseAddress")
            }
            let srcStride = CVPixelBufferGetBytesPerRow(srcPB)

            switch pixelFormat {
            case .bgra:
                guard CVPixelBufferLockBaseAddress(dstPB, []) == kCVReturnSuccess else {
                    throw SafariumError.encode("cannot lock destination BGRA CVPixelBuffer")
                }
                defer { _ = CVPixelBufferUnlockBaseAddress(dstPB, []) }
                guard let dstBase = CVPixelBufferGetBaseAddress(dstPB) else {
                    throw SafariumError.encode("missing destination BGRA baseAddress")
                }
                let dstStride = CVPixelBufferGetBytesPerRow(dstPB)
                let rowBytes = width * 4
                if srcStride == dstStride && dstStride == rowBytes {
                    memcpy(dstBase, srcBase, height * rowBytes)
                } else {
                    for y in 0..<height {
                        memcpy(dstBase.advanced(by: y * dstStride), srcBase.advanced(by: y * srcStride), rowBytes)
                    }
                }
            case .nv12Left, .nv12vImage:
                try SafariumAccelerate.convertRawBGRAToNV12BT709Left(
                    bgra: srcBase,
                    bgraBytesPerRow: srcStride,
                    into: dstPB,
                    width: width,
                    height: height
                )
            case .p010, .p210, .p410:
                try AVAssetWriterSink.convertBGRATo10BitBiPlanar(
                    bgra: srcBase,
                    bgraBytesPerRow: srcStride,
                    into: dstPB,
                    width: width,
                    height: height,
                    pixelFormat: pixelFormat
                )
            }
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
}

// MARK: - PrismHybridEngine

public enum PrismHybridEngine {
    public static func inspectCapabilities() async throws -> PrismCapabilitiesReport {
        let blenderURL = try? PrismWarmBlenderBridge.resolveBlenderBinary()
        let blenderVersion = blenderURL.flatMap { PrismWarmBlenderBridge.queryBlenderVersion(blenderURL: $0) }
        let workerURL = try? PrismWarmBlenderBridge.resolveWorkerScript()

        let wkCaps = try await Task { @MainActor in
            let host = try await PrismWebKit3D(width: 256, height: 256)
            defer { host.close() }
            return try await host.checkCapabilities()
        }.value

        let liveTelemetry = PrismLiveTelemetryProvider().capture(childPID: nil)
        let metalDevice = SafariumMetalContext.shared?.device
        let notes: [String] = [
            "Blender 5.2.2 LTS uses engine BLENDER_EEVEE (not BLENDER_EEVEE_NEXT) and Scene.compositing_node_group (Scene.node_tree removed).",
            "Blender -b Viewer Node & RenderResult.pixels are empty; WarmBlenderBridge reads top-down BGRA8 via APFS MAP_SHARED mmap (bmp_mmap default, gpu_offscreen opt-in EEVEE).",
            "Portrait AUTO camera trap solved: 1080x1920 35mm uses sensor_width along height (~54.432 deg) instead of cam.data.angle_y (~37.849 deg).",
            "0.67x -> 1x MTLFXSpatialScaler auto-verified via SafariumPQ (ANE FeaturePrint + Metal MS-SSIM + dE00 p95 + optional Thai OCR) with automatic 1.0x fallback.",
        ]

        return PrismCapabilitiesReport(
            version: SafariumPrismModuleInfo.version,
            schema: SafariumPrismModuleInfo.schema,
            blenderAvailable: blenderURL != nil,
            blenderPath: blenderURL?.path ?? PrismWarmBlenderBridge.defaultBlenderPath,
            blenderVersion: blenderVersion,
            workerScriptPath: workerURL?.path,
            workerScriptValid: workerURL != nil,
            webkitWebGL2Available: wkCaps.webgl2,
            webkitWebGPUAvailable: wkCaps.webgpu,
            webkitRenderer: wkCaps.renderer,
            metalfxAvailable: PrismMetalFXVerifier.isSupported(),
            metalDeviceName: metalDevice?.name,
            aneAvailable: AppleMacOSBackend.current.supportsANE,
            hidListenAccess: liveTelemetry.hidListenAccessOK,
            thermalState: liveTelemetry.thermalState,
            taskpolicyAvailable: PrismAntiLagGovernor.isTaskpolicyAvailable(),
            notes: notes
        )
    }

    public static func syncFromBlender(
        blendURL: URL,
        outputGLBURL: URL,
        outputIRURL: URL,
        frame: Int = 1,
        engine: PrismBlenderEngine = .eevee,
        exportAnimations: Bool = true,
        width: Int? = nil,
        height: Int? = nil,
        overwrite: Bool = false
    ) async throws -> PrismSyncResult {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(blendURL)
        try SafeFilePublisher.preflight(outputURL: outputGLBURL, overwrite: overwrite)
        try SafeFilePublisher.preflight(outputURL: outputIRURL, overwrite: overwrite)

        let bridge = try PrismWarmBlenderBridge()
        do {
            _ = try await bridge.loadBlend(url: blendURL, engine: engine, width: width, height: height, samples: 8)
            let ir = try await bridge.exportGLBAndIR(
                glbURL: outputGLBURL,
                irURL: outputIRURL,
                frame: frame,
                exportAnimations: exportAnimations,
                width: width,
                height: height,
                overwrite: overwrite
            )
            await bridge.shutdown()
            let glbBytes = ((try? FileManager.default.attributesOfItem(atPath: outputGLBURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
            let irHash = try ir.deterministicSHA256()
            let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            return PrismSyncResult(
                blendPath: blendURL.path,
                glbPath: outputGLBURL.path,
                irPath: outputIRURL.path,
                glbBytes: glbBytes,
                irSHA256: irHash,
                camera: ir.camera,
                timeline: ir.timeline,
                wallMs: wallMs
            )
        } catch {
            await bridge.shutdown()
            throw error
        }
    }

    private static func validateWebInputURL(_ url: URL, allowLoopbackHTTP: Bool) throws {
        if url.isFileURL {
            try SafeFilePublisher.assertRegularReadableFile(url)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        guard allowLoopbackHTTP && scheme == "http" && (host == "127.0.0.1" || host == "localhost") else {
            throw SafariumError.invalidState("web input must be a local file or loopback http://127.0.0.1|localhost with allowLoopbackHTTP=true: \(url.absoluteString)")
        }
    }

    @MainActor
    public static func previewStills(
        inputURL: URL,
        outputDir: URL? = nil,
        contactSheetURL: URL? = nil,
        tier: PrismPreviewTier = .auto,
        width: Int = 1080,
        height: Int = 1920,
        angles: [Double] = [0.0, 45.0, 90.0],
        frames: [Int]? = nil,
        cols: Int? = nil,
        rows: Int? = nil,
        tileWidth: Int = 360,
        padding: Int = 8,
        bgColorHex: String = "#0F172A",
        stillFormat: String = "png",
        engine: PrismBlenderEngine = .eevee,
        samples: Int = 16,
        shmMethod: PrismSHMMethod = .bmpMmap,
        allowLoopbackHTTP: Bool = false,
        overwrite: Bool = false
    ) async throws -> PrismPreviewStillsReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try validateWebInputURL(inputURL, allowLoopbackHTTP: allowLoopbackHTTP)
        guard width >= 16, height >= 16, width <= 8192, height <= 8192 else {
            throw SafariumError.invalidState("previewStills invalid dimensions \(width)x\(height)")
        }
        if let contactSheetURL {
            try SafeFilePublisher.preflight(outputURL: contactSheetURL, overwrite: overwrite)
        }
        if let outputDir {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        }

        let ext = inputURL.pathExtension.lowercased()
        let chosenTier: PrismPreviewTier
        switch tier {
        case .auto:
            if ext == "blend" && frames != nil && !(frames!.isEmpty) {
                chosenTier = .warmBlender
            } else {
                chosenTier = .webkitGLB
            }
        case .webkitGLB, .warmBlender:
            chosenTier = tier
        }

        var capturedImages: [CGImage] = []
        var stillPaths: [String] = []
        var stillLatencies: [Double] = []
        var peakFootprint: UInt64 = PrismLiveTelemetryProvider.selfPhysicalFootprintBytes()

        if chosenTier == .webkitGLB {
            var tempExportDir: URL?
            defer {
                if let d = tempExportDir { try? FileManager.default.removeItem(at: d) }
            }
            let targetAssetURL: URL
            if ext == "blend" {
                let tmpDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("safarium-prism-glb-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
                tempExportDir = tmpDir
                let glbTmp = tmpDir.appendingPathComponent("preview.glb")
                let irTmp = tmpDir.appendingPathComponent("preview_ir.json")
                _ = try await syncFromBlender(
                    blendURL: inputURL,
                    outputGLBURL: glbTmp,
                    outputIRURL: irTmp,
                    frame: frames?.first ?? 1,
                    engine: engine,
                    exportAnimations: false,
                    width: width,
                    height: height,
                    overwrite: true
                )
                targetAssetURL = glbTmp
            } else {
                targetAssetURL = inputURL
            }

            let host = try await PrismWebKit3D(
                width: width, height: height, transparent: false, allowLoopbackHTTP: allowLoopbackHTTP
            )
            defer { host.close() }

            if !targetAssetURL.isFileURL || ext == "html" || ext == "htm" {
                if targetAssetURL.isFileURL {
                    try await host.loadHTMLFile(targetAssetURL)
                } else {
                    try await host.loadURL(targetAssetURL)
                }
                let count = max(1, frames?.count ?? angles.count)
                for idx in 0..<count {
                    let s0 = DispatchTime.now().uptimeNanoseconds
                    let tSec = Double(frames?[safe: idx] ?? idx) / 30.0
                    try await host.seekHTML(timeSeconds: tSec)
                    let snap = try await host.snapshot()
                    capturedImages.append(snap.cgImage)
                    stillLatencies.append(Double(DispatchTime.now().uptimeNanoseconds - s0) / 1e6)
                    peakFootprint = max(peakFootprint, PrismLiveTelemetryProvider.selfPhysicalFootprintBytes())
                }
            } else {
                try await host.loadBuiltinGLB(glbURL: targetAssetURL)
                let angleList = angles.isEmpty ? [0.0] : angles
                for deg in angleList {
                    let s0 = DispatchTime.now().uptimeNanoseconds
                    _ = try await host.renderGLBAngle(deg)
                    let snap = try await host.snapshot()
                    capturedImages.append(snap.cgImage)
                    stillLatencies.append(Double(DispatchTime.now().uptimeNanoseconds - s0) / 1e6)
                    peakFootprint = max(peakFootprint, PrismLiveTelemetryProvider.selfPhysicalFootprintBytes())
                }
            }
        } else {
            guard ext == "blend" else {
                throw SafariumError.invalidState("warmBlender preview tier requires a .blend file, got \(inputURL.lastPathComponent)")
            }
            let bridge = try PrismWarmBlenderBridge()
            do {
                _ = try await bridge.loadBlend(url: inputURL, engine: engine, width: width, height: height, samples: samples)
                let frameList = (frames?.isEmpty == false) ? frames! : [1]
                for f in frameList {
                    let s0 = DispatchTime.now().uptimeNanoseconds
                    let (_, pb) = try await bridge.renderFrameToSHM(frame: f, method: shmMethod)
                    let cg = try pixelBufferToCGImage(pb)
                    capturedImages.append(cg)
                    stillLatencies.append(Double(DispatchTime.now().uptimeNanoseconds - s0) / 1e6)
                    peakFootprint = max(peakFootprint, PrismLiveTelemetryProvider.selfPhysicalFootprintBytes())
                    if let cpid = bridge.childPID, let cFoot = PrismLiveTelemetryProvider.processPhysicalFootprintBytes(pid: cpid) {
                        peakFootprint = max(peakFootprint, cFoot)
                    }
                }
                await bridge.shutdown()
            } catch {
                await bridge.shutdown()
                throw error
            }
        }

        if let outputDir {
            let fmt = stillFormat.lowercased()
            for (idx, cg) in capturedImages.enumerated() {
                let outURL = outputDir.appendingPathComponent(String(format: "still_%03d.%@", idx, fmt))
                try writeImage(cg, to: outURL, format: fmt, quality: 0.92, overwrite: overwrite)
                stillPaths.append(outURL.path)
            }
        }

        if let sheetURL = contactSheetURL {
            try writeContactSheet(
                images: capturedImages,
                to: sheetURL,
                cols: cols,
                rows: rows,
                tileWidth: tileWidth,
                padding: padding,
                bgColorHex: bgColorHex,
                overwrite: overwrite
            )
        }

        let meanStill = stillLatencies.isEmpty ? 0.0 : stillLatencies.reduce(0, +) / Double(stillLatencies.count)
        let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return PrismPreviewStillsReport(
            inputPath: inputURL.path,
            tierUsed: chosenTier.rawValue,
            stillPaths: stillPaths,
            contactSheetPath: contactSheetURL?.path,
            stillsCaptured: capturedImages.count,
            width: width,
            height: height,
            meanStillMs: meanStill,
            peakFootprintBytes: peakFootprint,
            wallMs: wallMs
        )
    }

    @MainActor
    public static func renderWeb3D(
        htmlURL: URL,
        outputURL: URL,
        width: Int = 1080,
        height: Int = 1920,
        fps: Int = 30,
        frames: Int = 30,
        startSeconds: Double = 0.0,
        codec: VideoCodec = .h264,
        bitrate: Int = 12_000_000,
        quality: Double? = nil,
        transparent: Bool = false,
        overlayHTMLURL: URL? = nil,
        audioURL: URL? = nil,
        subtitlesURL: URL? = nil,
        subtitleLang: String = "tha",
        secondaryOutputURL: URL? = nil,
        secondaryCodec: VideoCodec? = nil,
        qualityPolicy: PrismQualityPolicy = PrismQualityPolicy(),
        governorConfig: PrismAntiLagConfig = PrismAntiLagConfig(),
        allowLoopbackHTTP: Bool = false,
        overwrite: Bool = false,
        options: PrismWebRenderOptions = PrismWebRenderOptions()
    ) async throws -> PrismRenderReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try validateWebInputURL(htmlURL, allowLoopbackHTTP: allowLoopbackHTTP)
        if let overlayHTMLURL { try SafeFilePublisher.assertRegularReadableFile(overlayHTMLURL) }
        guard frames > 0, fps > 0, width >= 2, height >= 2 else {
            throw SafariumError.invalidState("renderWeb3D requires positive width, height, fps, frames")
        }
        let targetFPS = options.outputFPS ?? fps
        guard targetFPS > 0 else {
            throw SafariumError.invalidState("outputFPS must be > 0, got \(targetFPS)")
        }
        let totalOutFrames: Int = (targetFPS == fps)
            ? frames
            : max(1, Int((Double(frames) * Double(targetFPS) / Double(fps)).rounded()))
        let videoDurationSeconds = Double(totalOutFrames) / Double(targetFPS)

        var fontServer: ForgeLoopbackFontServer?
        if let fontDir = options.fontDirURL {
            let srv = try ForgeLoopbackFontServer(
                fontDirURL: fontDir,
                htmlDirURL: htmlURL.isFileURL ? htmlURL.deletingLastPathComponent() : nil
            )
            _ = try srv.start()
            fontServer = srv
        }
        defer { fontServer?.stop() }

        let fontInjectionJS: String?
        if let srv = fontServer, options.injectFontFaceCSS {
            let src = try srv.injectionScriptSource()
            fontInjectionJS = src.isEmpty ? nil : src
        } else {
            fontInjectionJS = nil
        }

        let sink = try PrismDualOutputSink(
            primaryOutputURL: outputURL,
            secondaryOutputURL: secondaryOutputURL,
            width: width,
            height: height,
            fps: targetFPS,
            primaryCodec: codec,
            secondaryCodec: secondaryCodec,
            bitrate: bitrate,
            quality: quality,
            overwrite: overwrite
        )

        let compositor = try PrismMetalCompositor()
        let governor = PrismAntiLagGovernor(config: governorConfig)
        let verifier = (qualityPolicy.useMetalFX && qualityPolicy.scaleFactor < 0.999) ? try PrismMetalFXVerifier() : nil

        var activeMetalFX = (verifier != nil) && !options.metalSVGFilters
        let lowW = max(16, Int((Double(width) * qualityPolicy.scaleFactor).rounded()) & ~1)
        let lowH = max(16, Int((Double(height) * qualityPolicy.scaleFactor).rounded()) & ~1)

        let initialW = activeMetalFX ? lowW : width
        let initialH = activeMetalFX ? lowH : height
        let webHost = try await PrismWebKit3D(
            width: initialW,
            height: initialH,
            transparent: transparent || options.metalSVGFilters,
            allowLoopbackHTTP: allowLoopbackHTTP || (fontServer != nil),
            fontFaceInjectionJS: fontInjectionJS
        )
        defer { webHost.close() }
        if htmlURL.isFileURL {
            try await webHost.loadHTMLFile(
                htmlURL,
                waitReadyTimeout: options.readyTimeoutSeconds,
                readyExpr: options.readyExpr
            )
        } else {
            try await webHost.loadURL(
                htmlURL,
                waitReadyTimeout: options.readyTimeoutSeconds,
                readyExpr: options.readyExpr
            )
        }

        try await webHost.runInitScript(
            js: options.initJS,
            fileURL: options.initFileURL,
            timeout: options.readyTimeoutSeconds
        )

        let svgPlan: PrismSVGSurgeryPlan? = options.metalSVGFilters
            ? try await webHost.applySVGFilterSurgery(preserveSharpText1x: options.preserveSharpText1x)
            : nil
        let hasSVGFilters = (svgPlan?.ops.isEmpty == false)
        if hasSVGFilters {
            activeMetalFX = false
        }

        let grainAmount = max(0.0, options.grainIntensity ?? 0.0)
        let needsWave2 = svgPlan?.ops.contains(where: { $0.kind == .paperCutout || $0.kind == .markerTexture }) ?? false
        let filterEngine: ForgeMetalFilterEngine? = (grainAmount > 0.0 || hasSVGFilters)
            ? try ForgeMetalFilterEngine(initWave2Engine: needsWave2)
            : nil

        let overlayHost = try await makeOptionalOverlayHost(url: overlayHTMLURL, width: width, height: height)
        defer { overlayHost?.close() }

        let outPB = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra)
        let lowPB = activeMetalFX ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: lowW, height: lowH, pixelFormat: .bgra) : nil
        let upPB = activeMetalFX ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra) : nil
        let ref1xPB = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra)
        let refCompPB = (activeMetalFX && overlayHost != nil) ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra) : nil
        let hudPB = overlayHost != nil ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra) : nil
        let svgAccumA = hasSVGFilters ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra) : nil
        let svgAccumB = hasSVGFilters ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra) : nil
        let svgLayerPB = hasSVGFilters ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra) : nil
        let svgWorkPB = hasSVGFilters ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra) : nil
        let grainPB = grainAmount > 0.0 ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra) : nil

        var didFallback = false
        var fallbackFrame: Int?
        var fallbackReasons: [String] = []
        var lastPQ: SafariumPQReport?
        var peakFootprint: UInt64 = PrismLiveTelemetryProvider.selfPhysicalFootprintBytes()
        let preserveAlpha = transparent || codec.hasAlpha || (sink.secondaryCodec?.hasAlpha == true)

        var lastCapturedSrcIdx = -1
        var cachedCleanFramePB: CVPixelBuffer?

        do {
            for outIdx in 0..<totalOutFrames {
                let srcIdx = (targetFPS == fps) ? outIdx : min(frames - 1, (outIdx * fps) / targetFPS)

                if srcIdx != lastCapturedSrcIdx || cachedCleanFramePB == nil {
                    _ = try await governor.paceStep(childPID: nil)
                    let tSec = startSeconds + Double(srcIdx) / Double(fps)
                    let activeHUDPB = try await captureOptionalOverlay(overlayHost, timeSeconds: tSec, into: hudPB)

                    let frameCleanPB: CVPixelBuffer
                    if hasSVGFilters,
                       let plan = svgPlan,
                       let filterEngine,
                       let accumA = svgAccumA,
                       let accumB = svgAccumB,
                       let layerPB = svgLayerPB,
                       let workPB = svgWorkPB {
                        if webHost.width != width || webHost.height != height {
                            try await webHost.resize(width: width, height: height)
                        }
                        try await webHost.seekHTML(
                            timeSeconds: tSec,
                            frameIndex: srcIdx,
                            fps: Double(fps),
                            durationSeconds: videoDurationSeconds,
                            seekExpr: options.seekExpr
                        )
                        frameCleanPB = try await Self.captureSVGFilteredFrame(
                            webHost: webHost,
                            plan: plan,
                            compositor: compositor,
                            filterEngine: filterEngine,
                            activeHUDPB: activeHUDPB,
                            transparent: transparent,
                            preserveAlpha: preserveAlpha,
                            accumA: accumA,
                            accumB: accumB,
                            layerPB: layerPB,
                            workPB: workPB
                        )
                    } else if activeMetalFX, let verifier, let lPB = lowPB, let uPB = upPB {
                        if webHost.width != lowW || webHost.height != lowH {
                            try await webHost.resize(width: lowW, height: lowH)
                        }
                        try await webHost.seekHTML(
                            timeSeconds: tSec,
                            frameIndex: srcIdx,
                            fps: Double(fps),
                            durationSeconds: videoDurationSeconds,
                            seekExpr: options.seekExpr
                        )
                        _ = try await webHost.snapshotPixelBuffer(into: lPB)

                        let shouldVerify = qualityPolicy.autoVerifyMetalFX && (srcIdx == 0 || srcIdx % qualityPolicy.verifyEveryNFrames == 0)
                        if shouldVerify {
                            try await webHost.resize(width: width, height: height)
                            try await webHost.seekHTML(
                                timeSeconds: tSec,
                                frameIndex: srcIdx,
                                fps: Double(fps),
                                durationSeconds: videoDurationSeconds,
                                seekExpr: options.seekExpr
                            )
                            _ = try await webHost.snapshotPixelBuffer(into: ref1xPB)

                            let refTargetPB: CVPixelBuffer
                            if let activeHUDPB, let rComp = refCompPB {
                                try compositor.composite(
                                    bgPB: ref1xPB, heroPB: nil, heroPremultiplied: true,
                                    hudPB: activeHUDPB, preserveAlpha: preserveAlpha, into: rComp
                                )
                                refTargetPB = rComp
                            } else {
                                refTargetPB = ref1xPB
                            }

                            let res = try verifier.evaluateAndUpscale(
                                lowResPB: lPB,
                                reference1xPB: refTargetPB,
                                overlay1xPB: activeHUDPB,
                                policy: qualityPolicy
                            )
                            lastPQ = res.pqReport
                            if res.didFallbackTo1x {
                                activeMetalFX = false
                                didFallback = true
                                fallbackFrame = srcIdx
                                fallbackReasons = res.pqReport.notes
                                frameCleanPB = res.outputPB
                            } else {
                                frameCleanPB = res.outputPB
                            }
                        } else {
                            _ = try verifier.upscale(lowResPB: lPB, into: uPB)
                            try compositor.composite(
                                bgPB: uPB, heroPB: nil, heroPremultiplied: true,
                                hudPB: activeHUDPB, preserveAlpha: preserveAlpha, into: outPB
                            )
                            frameCleanPB = outPB
                        }
                    } else {
                        if webHost.width != width || webHost.height != height {
                            try await webHost.resize(width: width, height: height)
                        }
                        try await webHost.seekHTML(
                            timeSeconds: tSec,
                            frameIndex: srcIdx,
                            fps: Double(fps),
                            durationSeconds: videoDurationSeconds,
                            seekExpr: options.seekExpr
                        )
                        let snapPB = try await webHost.snapshotPixelBuffer(into: ref1xPB)
                        if let activeHUDPB {
                            try compositor.composite(
                                bgPB: snapPB, heroPB: nil, heroPremultiplied: true,
                                hudPB: activeHUDPB, preserveAlpha: preserveAlpha, into: outPB
                            )
                            frameCleanPB = outPB
                        } else if transparent && !preserveAlpha {
                            try compositor.composite(
                                bgPB: nil, heroPB: snapPB, heroPremultiplied: true,
                                hudPB: nil, solidBg: SIMD4<Float>(0, 0, 0, 1), preserveAlpha: false, into: outPB
                            )
                            frameCleanPB = outPB
                        } else {
                            frameCleanPB = snapPB
                        }
                    }

                    lastCapturedSrcIdx = srcIdx
                    cachedCleanFramePB = frameCleanPB
                }

                guard let sourcePB = cachedCleanFramePB else {
                    throw SafariumError.encode("missing captured frame buffer at output index \(outIdx)")
                }
                let finalOutPB: CVPixelBuffer
                if grainAmount > 0.0, let filterEngine, let gPB = grainPB {
                    try filterEngine.applyGrain(
                        srcPB: sourcePB,
                        into: gPB,
                        amount: Float(grainAmount),
                        grainSize: Float(max(1.0, options.grainSize)),
                        frameSeed: UInt32(outIdx)
                    )
                    finalOutPB = gPB
                } else {
                    finalOutPB = sourcePB
                }

                let pts = CMTime(value: Int64(outIdx), timescale: Int32(targetFPS))
                try await sink.append(primaryPB: finalOutPB, presentationTime: pts)
                peakFootprint = max(peakFootprint, PrismLiveTelemetryProvider.selfPhysicalFootprintBytes())
            }

            governor.restorePriority(childPID: nil)
            let preparedAudioURL = try await Self.prepareWebAudio(
                audioURL: audioURL,
                sink: sink,
                videoDurationSeconds: videoDurationSeconds,
                options: options
            )
            let (priBytes, secBytes) = try await sink.finishAndCommit(
                audioURL: preparedAudioURL,
                subtitlesURL: subtitlesURL,
                subtitleLang: subtitleLang
            )
            let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            return PrismRenderReport(
                inputPath: htmlURL.path,
                outputPath: outputURL.path,
                secondaryOutputPath: secondaryOutputURL?.path,
                engineUsed: "WEBKIT_3D",
                width: width,
                height: height,
                fps: targetFPS,
                frames: totalOutFrames,
                codec: codec.rawValue,
                secondaryCodec: sink.secondaryCodec?.rawValue,
                primaryBytes: priBytes,
                secondaryBytes: secBytes,
                usedMetalFX: verifier != nil && !hasSVGFilters,
                didFallbackTo1x: didFallback,
                fallbackFrame: fallbackFrame,
                fallbackReasons: fallbackReasons,
                lastPQReport: lastPQ,
                antiLagStats: governor.stats,
                peakFootprintBytes: peakFootprint,
                wallMs: wallMs
            )
        } catch {
            governor.restorePriority(childPID: nil)
            sink.cancel()
            throw error
        }
    }

    @MainActor
    private static func captureSVGFilteredFrame(
        webHost: PrismWebKit3D,
        plan: PrismSVGSurgeryPlan,
        compositor: PrismMetalCompositor,
        filterEngine: ForgeMetalFilterEngine,
        activeHUDPB: CVPixelBuffer?,
        transparent: Bool,
        preserveAlpha: Bool,
        accumA: CVPixelBuffer,
        accumB: CVPixelBuffer,
        layerPB: CVPixelBuffer,
        workPB: CVPixelBuffer
    ) async throws -> CVPixelBuffer {
        try await webHost.setSVGPassVisibilityMode("base")
        _ = try await webHost.snapshotPixelBuffer(into: layerPB)

        var curAccum = accumA
        var nxtAccum = accumB
        let defaultSolid = transparent ? SIMD4<Float>(0, 0, 0, 0) : SIMD4<Float>(1, 1, 1, 1)
        try compositor.composite(
            bgPB: nil,
            heroPB: layerPB,
            heroPremultiplied: true,
            hudPB: nil,
            solidBg: defaultSolid,
            preserveAlpha: preserveAlpha,
            into: curAccum
        )

        for op in plan.ops {
            try await webHost.setSVGPassVisibilityMode("svg-target", targetIndex: op.targetIndex)
            _ = try await webHost.snapshotPixelBuffer(into: layerPB)

            switch op.kind {
            case .dropShadow:
                let blurInputPB: CVPixelBuffer
                if op.stdDeviation > 0.05 {
                    try filterEngine.applyGaussianBlur(srcPB: layerPB, into: workPB, sigma: Float(op.stdDeviation))
                    blurInputPB = workPB
                } else {
                    blurInputPB = layerPB
                }
                let flood = Self.rgbaSIMD4(op.floodColorRGBA)
                try compositor.mergeDropShadow(
                    bgPB: curAccum,
                    srcPB: layerPB,
                    blurPB: blurInputPB,
                    dx: Float(op.dx),
                    dy: Float(op.dy),
                    floodColorRGBA: flood,
                    preserveAlpha: preserveAlpha,
                    into: nxtAccum
                )
                swap(&curAccum, &nxtAccum)
            case .gaussianBlur:
                if op.stdDeviation > 0.05 {
                    try filterEngine.applyGaussianBlur(srcPB: layerPB, into: workPB, sigma: Float(op.stdDeviation))
                    try compositor.composite(
                        bgPB: curAccum,
                        heroPB: workPB,
                        heroPremultiplied: true,
                        hudPB: op.mergeSourceGraphic ? layerPB : nil,
                        preserveAlpha: preserveAlpha,
                        into: nxtAccum
                    )
                } else {
                    try compositor.composite(
                        bgPB: curAccum,
                        heroPB: layerPB,
                        heroPremultiplied: true,
                        hudPB: nil,
                        preserveAlpha: preserveAlpha,
                        into: nxtAccum
                    )
                }
                swap(&curAccum, &nxtAccum)
            case .paperCutout:
                try filterEngine.applyWave2Effect(.paperCutout, srcPB: layerPB, into: workPB)
                try compositor.composite(
                    bgPB: curAccum,
                    heroPB: workPB,
                    heroPremultiplied: true,
                    hudPB: nil,
                    preserveAlpha: preserveAlpha,
                    into: nxtAccum
                )
                swap(&curAccum, &nxtAccum)
            case .markerTexture:
                try filterEngine.applyWave2Effect(.markerTexture, srcPB: layerPB, into: workPB)
                try compositor.composite(
                    bgPB: curAccum,
                    heroPB: workPB,
                    heroPremultiplied: true,
                    hudPB: nil,
                    preserveAlpha: preserveAlpha,
                    into: nxtAccum
                )
                swap(&curAccum, &nxtAccum)
            }
        }

        if plan.hasSharpTextLayer {
            try await webHost.setSVGPassVisibilityMode("sharp-text")
            _ = try await webHost.snapshotPixelBuffer(into: layerPB)
            try compositor.composite(
                bgPB: curAccum,
                heroPB: layerPB,
                heroPremultiplied: true,
                hudPB: nil,
                preserveAlpha: preserveAlpha,
                into: nxtAccum
            )
            swap(&curAccum, &nxtAccum)
        }

        if let activeHUDPB {
            try compositor.composite(
                bgPB: curAccum,
                heroPB: nil,
                heroPremultiplied: true,
                hudPB: activeHUDPB,
                preserveAlpha: preserveAlpha,
                into: nxtAccum
            )
            swap(&curAccum, &nxtAccum)
        }

        try await webHost.setSVGPassVisibilityMode("all")
        return curAccum
    }

    private static func rgbaSIMD4(_ arr: [Double]) -> SIMD4<Float> {
        SIMD4<Float>(
            Float(arr.count > 0 ? arr[0] : 0.0),
            Float(arr.count > 1 ? arr[1] : 0.0),
            Float(arr.count > 2 ? arr[2] : 0.0),
            Float(arr.count > 3 ? arr[3] : 0.5)
        )
    }

    private static func prepareWebAudio(
        audioURL: URL?,
        sink: PrismDualOutputSink,
        videoDurationSeconds: Double,
        options: PrismWebRenderOptions
    ) async throws -> URL? {
        guard let srcAudioURL = audioURL else { return nil }
        try SafeFilePublisher.assertRegularReadableFile(srcAudioURL)

        let needsNorm = (options.loudnormTargetI != nil) || (options.loudnormTruePeak != nil)
        let needsPad = options.audioPadToVideo
        guard needsNorm || needsPad else { return srcAudioURL }

        if needsNorm {
            let normWAV = sink.stageFileURL("audio_norm.wav")
            _ = try await AudioMixer.mix(
                tracks: [AudioMixTrack(url: srcAudioURL)],
                to: normWAV,
                durationSeconds: nil,
                sampleRate: 48_000,
                channels: 2,
                normalizeLUFS: options.loudnormTargetI,
                peakCeilingDBTP: options.loudnormTruePeak ?? -1.05,
                wavBitDepth: 16,
                overwrite: true
            )
            if needsPad {
                let paddedWAV = sink.stageFileURL("audio_norm_pad.wav")
                _ = try await ForgeAudioDSP.padOrTrim(
                    inputURL: normWAV,
                    outputURL: paddedWAV,
                    padToDurationSeconds: videoDurationSeconds,
                    sampleRate: 48_000,
                    channels: 2,
                    overwrite: true
                )
                return paddedWAV
            }
            return normWAV
        }

        let paddedWAV = sink.stageFileURL("audio_pad.wav")
        _ = try await ForgeAudioDSP.padOrTrim(
            inputURL: srcAudioURL,
            outputURL: paddedWAV,
            padToDurationSeconds: videoDurationSeconds,
            sampleRate: 48_000,
            channels: 2,
            overwrite: true
        )
        return paddedWAV
    }

    @MainActor
    public static func renderBlenderAdaptive(
        blendURL: URL,
        outputURL: URL,
        irURL: URL? = nil,
        engine: PrismBlenderEngine = .eevee,
        shmMethod: PrismSHMMethod = .bmpMmap,
        samples: Int = 16,
        width: Int = 1080,
        height: Int = 1920,
        fps: Int = 30,
        startFrame: Int = 1,
        frames: Int = 30,
        filmTransparent: Bool = false,
        codec: VideoCodec = .h264,
        bitrate: Int = 12_000_000,
        quality: Double? = nil,
        overlayHTMLURL: URL? = nil,
        audioURL: URL? = nil,
        subtitlesURL: URL? = nil,
        subtitleLang: String = "tha",
        secondaryOutputURL: URL? = nil,
        secondaryCodec: VideoCodec? = nil,
        qualityPolicy: PrismQualityPolicy = PrismQualityPolicy(),
        governorConfig: PrismAntiLagConfig = PrismAntiLagConfig(),
        overwrite: Bool = false
    ) async throws -> PrismRenderReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(blendURL)
        if let overlayHTMLURL { try SafeFilePublisher.assertRegularReadableFile(overlayHTMLURL) }
        guard frames > 0, fps > 0, width >= 2, height >= 2 else {
            throw SafariumError.invalidState("renderBlenderAdaptive requires positive width, height, fps, frames")
        }

        let sceneIR = try irURL.map { try PrismSceneIR.load(from: $0) }
        let sink = try PrismDualOutputSink(
            primaryOutputURL: outputURL,
            secondaryOutputURL: secondaryOutputURL,
            width: width,
            height: height,
            fps: fps,
            primaryCodec: codec,
            secondaryCodec: secondaryCodec,
            bitrate: bitrate,
            quality: quality,
            overwrite: overwrite
        )

        let compositor = try PrismMetalCompositor()
        let governor = PrismAntiLagGovernor(config: governorConfig)
        let verifier = (qualityPolicy.useMetalFX && qualityPolicy.scaleFactor < 0.999) ? try PrismMetalFXVerifier() : nil
        var activeMetalFX = (verifier != nil)
        let lowW = max(16, Int((Double(width) * qualityPolicy.scaleFactor).rounded()) & ~1)
        let lowH = max(16, Int((Double(height) * qualityPolicy.scaleFactor).rounded()) & ~1)

        let bridge = try PrismWarmBlenderBridge()
        let overlayHost = try await makeOptionalOverlayHost(url: overlayHTMLURL, width: width, height: height)
        defer { overlayHost?.close() }

        let lowPB = activeMetalFX ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: lowW, height: lowH, pixelFormat: .bgra) : nil
        let upPB = activeMetalFX ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra) : nil
        let ref1xPB = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra)
        let outPB = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra)
        let refCompPB = (activeMetalFX && overlayHost != nil) ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra) : nil
        let hudPB = overlayHost != nil ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra) : nil

        var didFallback = false
        var fallbackFrame: Int?
        var fallbackReasons: [String] = []
        var lastPQ: SafariumPQReport?
        var peakFootprint: UInt64 = PrismLiveTelemetryProvider.selfPhysicalFootprintBytes()

        do {
            _ = try await bridge.loadBlend(
                url: blendURL,
                engine: engine,
                width: activeMetalFX ? lowW : width,
                height: activeMetalFX ? lowH : height,
                samples: samples,
                filmTransparent: filmTransparent
            )
            if let ir = sceneIR {
                let delta = PrismBlenderDelta(
                    cameraPositionThree: ir.camera.positionThree,
                    cameraQuaternionThree: ir.camera.quaternionThree,
                    lensMM: ir.camera.lensMM,
                    shiftX: ir.camera.shiftX,
                    shiftY: ir.camera.shiftY,
                    focusDistance: ir.camera.dof?.enabled == true ? ir.camera.dof?.focusDistance : nil,
                    fstop: ir.camera.dof?.enabled == true ? ir.camera.dof?.fstop : nil
                )
                try await bridge.applyDelta(delta)
            }

            let heroPremul = (shmMethod == .gpuOffscreen)
            let preserveAlpha = filmTransparent && codec.hasAlpha

            for idx in 0..<frames {
                let fNum = startFrame + idx
                _ = try await governor.paceStep(childPID: bridge.childPID)
                let tSec = Double(idx) / Double(fps)

                let activeHUDPB = try await captureOptionalOverlay(overlayHost, timeSeconds: tSec, into: hudPB)

                let frameOutPB: CVPixelBuffer
                if activeMetalFX, let verifier, let lPB = lowPB, let uPB = upPB {
                    let (_, lowRendered) = try await bridge.renderFrameToSHM(
                        frame: fNum, method: shmMethod, width: lowW, height: lowH,
                        filmTransparent: filmTransparent, samples: samples, into: lPB
                    )
                    let shouldVerify = qualityPolicy.autoVerifyMetalFX && (idx == 0 || idx % qualityPolicy.verifyEveryNFrames == 0)
                    if shouldVerify {
                        let (_, fullRendered) = try await bridge.renderFrameToSHM(
                            frame: fNum, method: shmMethod, width: width, height: height,
                            filmTransparent: filmTransparent, samples: samples, into: ref1xPB
                        )
                        try compositor.composite(
                            bgPB: nil, heroPB: fullRendered, heroPremultiplied: heroPremul,
                            hudPB: activeHUDPB, solidBg: SIMD4<Float>(0, 0, 0, filmTransparent ? 0 : 1),
                            preserveAlpha: preserveAlpha, into: refCompPB ?? outPB
                        )
                        let refTarget = refCompPB ?? outPB
                        let res = try verifier.evaluateAndUpscale(
                            lowResPB: lowRendered,
                            reference1xPB: refTarget,
                            overlay1xPB: activeHUDPB,
                            policy: qualityPolicy
                        )
                        lastPQ = res.pqReport
                        if res.didFallbackTo1x {
                            activeMetalFX = false
                            didFallback = true
                            fallbackFrame = idx
                            fallbackReasons = res.pqReport.notes
                            frameOutPB = res.outputPB
                        } else {
                            frameOutPB = res.outputPB
                        }
                    } else {
                        _ = try verifier.upscale(lowResPB: lowRendered, into: uPB)
                        try compositor.composite(
                            bgPB: nil, heroPB: uPB, heroPremultiplied: heroPremul,
                            hudPB: activeHUDPB, solidBg: SIMD4<Float>(0, 0, 0, filmTransparent ? 0 : 1),
                            preserveAlpha: preserveAlpha, into: outPB
                        )
                        frameOutPB = outPB
                    }
                } else {
                    let (_, fullRendered) = try await bridge.renderFrameToSHM(
                        frame: fNum, method: shmMethod, width: width, height: height,
                        filmTransparent: filmTransparent, samples: samples, into: ref1xPB
                    )
                    try compositor.composite(
                        bgPB: nil, heroPB: fullRendered, heroPremultiplied: heroPremul,
                        hudPB: activeHUDPB, solidBg: SIMD4<Float>(0, 0, 0, filmTransparent ? 0 : 1),
                        preserveAlpha: preserveAlpha, into: outPB
                    )
                    frameOutPB = outPB
                }

                try await sink.append(primaryPB: frameOutPB)
                peakFootprint = max(peakFootprint, governor.stats.maxSelfFootprintBytes, governor.stats.maxChildFootprintBytes)
            }

            governor.restorePriority(childPID: bridge.childPID)
            await bridge.shutdown()
            let (priBytes, secBytes) = try await sink.finishAndCommit(
                audioURL: audioURL,
                subtitlesURL: subtitlesURL,
                subtitleLang: subtitleLang
            )
            let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            return PrismRenderReport(
                inputPath: blendURL.path,
                outputPath: outputURL.path,
                secondaryOutputPath: secondaryOutputURL?.path,
                engineUsed: engine.rawValue,
                width: width,
                height: height,
                fps: fps,
                frames: frames,
                codec: codec.rawValue,
                secondaryCodec: sink.secondaryCodec?.rawValue,
                primaryBytes: priBytes,
                secondaryBytes: secBytes,
                usedMetalFX: verifier != nil,
                didFallbackTo1x: didFallback,
                fallbackFrame: fallbackFrame,
                fallbackReasons: fallbackReasons,
                lastPQReport: lastPQ,
                antiLagStats: governor.stats,
                peakFootprintBytes: peakFootprint,
                wallMs: wallMs
            )
        } catch {
            governor.restorePriority(childPID: bridge.childPID)
            await bridge.shutdown()
            sink.cancel()
            throw error
        }
    }

    @MainActor
    public static func compositeHybrid(
        blendURL: URL,
        backgroundHTMLURL: URL? = nil,
        backgroundGLBURL: URL? = nil,
        overlayHTMLURL: URL? = nil,
        outputURL: URL,
        secondaryMOVURL: URL? = nil,
        primaryCodec: VideoCodec = .h264,
        secondaryCodec: VideoCodec? = .proRes4444,
        width: Int = 1080,
        height: Int = 1920,
        fps: Int = 30,
        startFrame: Int = 1,
        frames: Int = 15,
        blenderEngine: PrismBlenderEngine = .eevee,
        samples: Int = 16,
        shmMethod: PrismSHMMethod = .bmpMmap,
        bitrate: Int = 12_000_000,
        quality: Double? = nil,
        audioURL: URL? = nil,
        subtitlesURL: URL? = nil,
        subtitleLang: String = "tha",
        qualityPolicy: PrismQualityPolicy = PrismQualityPolicy(),
        governorConfig: PrismAntiLagConfig = PrismAntiLagConfig(),
        overwrite: Bool = false
    ) async throws -> PrismCompositeReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(blendURL)
        if let backgroundHTMLURL { try SafeFilePublisher.assertRegularReadableFile(backgroundHTMLURL) }
        if let backgroundGLBURL { try SafeFilePublisher.assertRegularReadableFile(backgroundGLBURL) }
        if let overlayHTMLURL { try SafeFilePublisher.assertRegularReadableFile(overlayHTMLURL) }
        guard frames > 0, fps > 0, width >= 2, height >= 2 else {
            throw SafariumError.invalidState("compositeHybrid requires positive width, height, fps, frames")
        }

        let resolvedSecCodec = secondaryMOVURL != nil ? (secondaryCodec ?? .proRes4444) : nil
        let sink = try PrismDualOutputSink(
            primaryOutputURL: outputURL,
            secondaryOutputURL: secondaryMOVURL,
            width: width,
            height: height,
            fps: fps,
            primaryCodec: primaryCodec,
            secondaryCodec: resolvedSecCodec,
            bitrate: bitrate,
            quality: quality,
            overwrite: overwrite
        )

        let compositor = try PrismMetalCompositor()
        let governor = PrismAntiLagGovernor(config: governorConfig)
        let verifier = (qualityPolicy.useMetalFX && qualityPolicy.scaleFactor < 0.999) ? try PrismMetalFXVerifier() : nil
        var activeMetalFX = (verifier != nil && (backgroundHTMLURL != nil || backgroundGLBURL != nil))
        let lowW = max(16, Int((Double(width) * qualityPolicy.scaleFactor).rounded()) & ~1)
        let lowH = max(16, Int((Double(height) * qualityPolicy.scaleFactor).rounded()) & ~1)

        let bgHost: PrismWebKit3D?
        if let bgHTML = backgroundHTMLURL {
            let h = try await PrismWebKit3D(width: activeMetalFX ? lowW : width, height: activeMetalFX ? lowH : height, transparent: false)
            try await h.loadHTMLFile(bgHTML)
            bgHost = h
        } else if let bgGLB = backgroundGLBURL {
            let h = try await PrismWebKit3D(width: activeMetalFX ? lowW : width, height: activeMetalFX ? lowH : height, transparent: false)
            try await h.loadBuiltinGLB(glbURL: bgGLB)
            bgHost = h
        } else {
            bgHost = nil
        }
        defer { bgHost?.close() }

        let overlayHost = try await makeOptionalOverlayHost(url: overlayHTMLURL, width: width, height: height)
        defer { overlayHost?.close() }

        let bridge = try PrismWarmBlenderBridge()
        let heroPB = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra)
        let bgFullPB = bgHost != nil ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra) : nil
        let bgLowPB = (activeMetalFX && bgHost != nil) ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: lowW, height: lowH, pixelFormat: .bgra) : nil
        let bgUpPB = (activeMetalFX && bgHost != nil) ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra) : nil
        let hudPB = overlayHost != nil ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra) : nil
        let outPrimaryPB = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra)
        let outAlphaPB = (resolvedSecCodec?.hasAlpha == true || primaryCodec.hasAlpha)
            ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra)
            : nil

        var didFallback = false
        var fallbackReasons: [String] = []
        var lastPQ: SafariumPQReport?
        var peakFootprint: UInt64 = PrismLiveTelemetryProvider.selfPhysicalFootprintBytes()

        do {
            _ = try await bridge.loadBlend(
                url: blendURL,
                engine: blenderEngine,
                width: width,
                height: height,
                samples: samples,
                filmTransparent: true
            )
            let heroPremul = (shmMethod == .gpuOffscreen)

            for idx in 0..<frames {
                let fNum = startFrame + idx
                _ = try await governor.paceStep(childPID: bridge.childPID)
                let tSec = Double(idx) / Double(fps)

                // 1. Warm Blender hero with film_transparent=True via zero-PNG mmap
                let (_, renderedHeroPB) = try await bridge.renderFrameToSHM(
                    frame: fNum, method: shmMethod, width: width, height: height,
                    filmTransparent: true, samples: samples, into: heroPB
                )

                // 2. WebKit 3D background (HTML or GLB), optionally 0.67x -> 1x MetalFX + SafariumPQ Auto-Verify
                var activeBgPB: CVPixelBuffer?
                if let bg = bgHost, let fullBG = bgFullPB {
                    func renderBG(into target: CVPixelBuffer, targetW: Int, targetH: Int) async throws -> CVPixelBuffer {
                        if bg.width != targetW || bg.height != targetH {
                            try await bg.resize(width: targetW, height: targetH)
                        }
                        if backgroundHTMLURL != nil {
                            try await bg.seekHTML(timeSeconds: tSec)
                        } else {
                            _ = try await bg.renderGLBAngle(Double(idx) * 3.0)
                        }
                        return try await bg.snapshotPixelBuffer(into: target)
                    }

                    if activeMetalFX, let verifier, let lBG = bgLowPB, let uBG = bgUpPB {
                        let lowRes = try await renderBG(into: lBG, targetW: lowW, targetH: lowH)
                        let shouldVerify = qualityPolicy.autoVerifyMetalFX && (idx == 0 || idx % qualityPolicy.verifyEveryNFrames == 0)
                        if shouldVerify {
                            let refRes = try await renderBG(into: fullBG, targetW: width, targetH: height)
                            let pqRes = try verifier.evaluateAndUpscale(
                                lowResPB: lowRes,
                                reference1xPB: refRes,
                                overlay1xPB: nil,
                                policy: qualityPolicy
                            )
                            lastPQ = pqRes.pqReport
                            if pqRes.didFallbackTo1x {
                                activeMetalFX = false
                                didFallback = true
                                fallbackReasons = pqRes.pqReport.notes
                                activeBgPB = pqRes.outputPB
                            } else {
                                activeBgPB = pqRes.outputPB
                            }
                        } else {
                            _ = try verifier.upscale(lowResPB: lowRes, into: uBG)
                            activeBgPB = uBG
                        }
                    } else {
                        activeBgPB = try await renderBG(into: fullBG, targetW: width, targetH: height)
                    }
                }

                // 3. 1.0x Thai WebKit HUD overlay
                let activeHUDPB = try await captureOptionalOverlay(overlayHost, timeSeconds: tSec, into: hudPB)

                // 4. Single-pass Metal GPU composite -> primary + optional alpha-preserving ProRes 4444 tee
                try compositor.composite(
                    bgPB: activeBgPB,
                    heroPB: renderedHeroPB,
                    heroPremultiplied: heroPremul,
                    hudPB: activeHUDPB,
                    solidBg: SIMD4<Float>(0, 0, 0, primaryCodec.hasAlpha ? 0 : 1),
                    preserveAlpha: primaryCodec.hasAlpha && activeBgPB == nil,
                    into: outPrimaryPB
                )
                if let alphaOut = outAlphaPB {
                    try compositor.composite(
                        bgPB: nil,
                        heroPB: renderedHeroPB,
                        heroPremultiplied: heroPremul,
                        hudPB: activeHUDPB,
                        solidBg: SIMD4<Float>(0, 0, 0, 0),
                        preserveAlpha: true,
                        into: alphaOut
                    )
                }

                let secInputPB: CVPixelBuffer? = (resolvedSecCodec?.hasAlpha == true) ? (outAlphaPB ?? outPrimaryPB) : outPrimaryPB
                try await sink.append(primaryPB: outPrimaryPB, secondaryPB: secInputPB)
                peakFootprint = max(peakFootprint, governor.stats.maxSelfFootprintBytes, governor.stats.maxChildFootprintBytes)
            }

            governor.restorePriority(childPID: bridge.childPID)
            await bridge.shutdown()
            let (priBytes, secBytes) = try await sink.finishAndCommit(
                audioURL: audioURL,
                subtitlesURL: subtitlesURL,
                subtitleLang: subtitleLang
            )
            let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            return PrismCompositeReport(
                blendPath: blendURL.path,
                backgroundPath: backgroundHTMLURL?.path ?? backgroundGLBURL?.path,
                overlayHTMLPath: overlayHTMLURL?.path,
                outputPath: outputURL.path,
                secondaryMOVPath: secondaryMOVURL?.path,
                width: width,
                height: height,
                fps: fps,
                frames: frames,
                primaryCodec: primaryCodec.rawValue,
                secondaryCodec: sink.secondaryCodec?.rawValue,
                primaryBytes: priBytes,
                secondaryBytes: secBytes,
                usedMetalFX: verifier != nil,
                didFallbackTo1x: didFallback,
                fallbackReasons: fallbackReasons,
                lastPQReport: lastPQ,
                antiLagStats: governor.stats,
                peakFootprintBytes: peakFootprint,
                wallMs: wallMs
            )
        } catch {
            governor.restorePriority(childPID: bridge.childPID)
            await bridge.shutdown()
            sink.cancel()
            throw error
        }
    }

    // MARK: - Private Helpers

    @MainActor
    private static func makeOptionalOverlayHost(url: URL?, width: Int, height: Int) async throws -> PrismWebKit3D? {
        guard let url else { return nil }
        let host = try await PrismWebKit3D(width: width, height: height, transparent: true)
        try await host.loadHTMLFile(url)
        return host
    }

    @MainActor
    private static func captureOptionalOverlay(
        _ host: PrismWebKit3D?,
        timeSeconds: Double,
        into pb: CVPixelBuffer?
    ) async throws -> CVPixelBuffer? {
        guard let host, let pb else { return nil }
        try await host.seekHTML(timeSeconds: timeSeconds)
        return try await host.snapshotPixelBuffer(into: pb)
    }

    private static func pixelBufferToCGImage(_ pb: CVPixelBuffer) throws -> CGImage {
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let ci = CIImage(cvPixelBuffer: pb)
        let ctx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])
        guard let cg = ctx.createCGImage(ci, from: CGRect(x: 0, y: 0, width: w, height: h), format: .BGRA8, colorSpace: Snapshot.colorSpace) else {
            throw SafariumError.snapshot("failed creating CGImage from CVPixelBuffer")
        }
        return cg
    }

    private static func writeImage(_ cg: CGImage, to url: URL, format: String, quality: Double, overwrite: Bool) throws {
        let fmt = format.lowercased()
        let stage = try APFSAutoStage.makeSession(for: url, overwrite: overwrite)
        defer { stage.cleanup() }
        if fmt == "webp" {
            let staged = stage.fileURL("still.webp")
            _ = try WebPAVIFEncoder.writeLosslessWebP(images: [cg], to: staged, loopCount: 0, overwrite: true)
            try stage.commit(stagedFile: staged, to: url, overwrite: overwrite)
            return
        }
        let data = try ForgeSheetAndQA.encodeCGImage(cg, format: fmt, quality: quality)
        let staged = stage.fileURL("still.\(fmt)")
        try data.write(to: staged)
        try stage.commit(stagedFile: staged, to: url, overwrite: overwrite)
    }

    private static func writeContactSheet(
        images: [CGImage],
        to outputURL: URL,
        cols: Int?,
        rows: Int?,
        tileWidth: Int,
        padding: Int,
        bgColorHex: String,
        overwrite: Bool
    ) throws {
        guard let first = images.first else {
            throw SafariumError.invalidState("contact sheet requires at least 1 captured still")
        }
        let c = max(1, cols ?? min(images.count, 4))
        let r = max(1, rows ?? Int(ceil(Double(images.count) / Double(c))))
        let tW = max(16, tileWidth)
        let tH = max(16, Int((Double(tW) * Double(first.height) / Double(max(1, first.width))).rounded()) & ~1)
        let pad = max(0, padding)
        let sheetW = c * tW + (c + 1) * pad
        let sheetH = r * tH + (r + 1) * pad
        guard sheetW <= 16384, sheetH <= 16384 else {
            throw SafariumError.invalidState("contact sheet dimensions \(sheetW)x\(sheetH) exceed 16384 limit")
        }
        guard let ctx = CGContext(
            data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: sheetW * 4,
            space: Snapshot.colorSpace, bitmapInfo: Snapshot.bitmapInfo
        ) else {
            throw SafariumError.encode("failed allocating \(sheetW)x\(sheetH) contact sheet CGContext")
        }
        let bg = ForgeColorHex.parseRGBA(bgColorHex)
        ctx.setFillColor(CGColor(srgbRed: CGFloat(bg.x), green: CGFloat(bg.y), blue: CGFloat(bg.z), alpha: CGFloat(bg.w)))
        ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))

        for (idx, img) in images.prefix(c * r).enumerated() {
            let row = idx / c
            let col = idx % c
            let x = pad + col * (tW + pad)
            let yTop = pad + row * (tH + pad)
            let cgY = sheetH - yTop - tH
            ctx.draw(img, in: CGRect(x: x, y: cgY, width: tW, height: tH))
        }
        guard let outImg = ctx.makeImage() else {
            throw SafariumError.encode("contact sheet makeImage failed")
        }
        let ext = outputURL.pathExtension.lowercased()
        try writeImage(outImg, to: outputURL, format: ext.isEmpty ? "jpg" : ext, quality: 0.90, overwrite: overwrite)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
