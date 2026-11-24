import CoreGraphics
import CoreVideo
import Foundation
import Metal
import MetalFX

/// Opt-in Wave 2 Grade B Metal shader effects (`paper-cutout` and `marker-texture`).
public enum Wave2EffectKind: String, Sendable {
    case none
    case paperCutout = "paper-cutout"
    case markerTexture = "marker-texture"
}

private struct PaperCutoutUniforms {
    var texSize: SIMD2<UInt32>
    var halfSize: SIMD2<UInt32>
    var rInner: Int32
    var rOuter: Int32
    var shadowOffset: SIMD2<Float>
    var shadowSigma2x: Float
    var shadowOpacity: Float
    var linearRGB: UInt32
    var _pad0: UInt32 = 0
    var bgColorSRGB: SIMD4<Float>
    var compositeBg: UInt32
    var _pad1: UInt32 = 0
    var _pad2: UInt32 = 0
    var _pad3: UInt32 = 0
}

private struct MarkerUniforms {
    var texSize: SIMD2<UInt32>
    var baseFreq: SIMD2<Float>
    var dispScale: Float
    var numOctaves: UInt32
    var linearFilter: UInt32
    var compositeBg: UInt32
    var bgColorSRGB: SIMD4<Float>
    var originOffset: SIMD2<Float>
    var _pad0: SIMD2<Float> = .zero
}

private struct CompositeOverlayUniforms {
    var canvasSize: SIMD2<UInt32>
    var ovOrigin: SIMD2<UInt32>
    var ovSize: SIMD2<UInt32>
    var opacity: Float
    var _pad0: UInt32 = 0
}

/// Single-init Metal shader + optional `MTLBinaryArchive` cache + split `MTLFXSpatialScaler` engine.
/// Never invokes `xcrun metal` (compiles once via `device.makeLibrary(source:options:)` and caches binaries).
public final class Wave2MetalEffectsEngine {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let textureCache: CVMetalTextureCache

    private let pPaperDilateH: MTLComputePipelineState
    private let pPaperDilateV: MTLComputePipelineState
    private let pGauss2xH: MTLComputePipelineState
    private let pGauss2xV: MTLComputePipelineState
    private let pPaperMerge: MTLComputePipelineState
    private let pMarkerDisp: MTLComputePipelineState
    private let pCompositeOverlay: MTLComputePipelineState
    private let turbulenceTables: MTLBuffer

    private var hMaskTex: MTLTexture?
    private var maskTex: MTLTexture?
    private var halfBlurH: MTLTexture?
    private var halfBlurV: MTLTexture?
    private var cachedTexW = 0
    private var cachedTexH = 0

    private var spatialScaler: MTLFXSpatialScaler?
    private var scalerInputW = 0
    private var scalerInputH = 0
    private var scalerOutputW = 0
    private var scalerOutputH = 0
    private var upscaledPrivateTex: MTLTexture?

    private static let shaderSource: String = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct PaperCutoutUniforms {
        uint2  texSize;
        uint2  halfSize;
        int    rInner;
        int    rOuter;
        float2 shadowOffset;
        float  shadowSigma2x;
        float  shadowOpacity;
        uint   linearRGB;
        uint   _pad0;
        float4 bgColorSRGB;
        uint   compositeBg;
        uint   _pad1;
        uint   _pad2;
        uint   _pad3;
    };

    inline float3 srgbToLinear(float3 c) {
        c = clamp(c, 0.0f, 1.0f);
        float3 lo = c / 12.92f;
        float3 hi = pow((c + 0.055f) / 1.055f, 2.4f);
        return select(hi, lo, c <= 0.04045f);
    }

    inline float3 linearToSrgb(float3 c) {
        c = clamp(c, 0.0f, 1.0f);
        float3 lo = c * 12.92f;
        float3 hi = 1.055f * pow(c, 1.0f / 2.4f) - 0.055f;
        return select(hi, lo, c <= 0.0031308f);
    }

    kernel void paper_dilate_h(
        texture2d<half, access::read>  srcTex   [[texture(0)]],
        texture2d<half, access::write> hMaskTex [[texture(1)]],
        constant PaperCutoutUniforms&  u        [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.texSize.x || gid.y >= u.texSize.y) return;
        int maxR = max(u.rInner, u.rOuter);
        half mIn = 0.0h, mOut = 0.0h;
        int x0 = max(0, int(gid.x) - maxR);
        int x1 = min(int(u.texSize.x) - 1, int(gid.x) + maxR);
        for (int x = x0; x <= x1; ++x) {
            half a = srcTex.read(uint2(x, gid.y)).a;
            int d = abs(x - int(gid.x));
            if (d <= u.rInner) mIn  = max(mIn, a);
            if (d <= u.rOuter) mOut = max(mOut, a);
        }
        hMaskTex.write(half4(mIn, mOut, 0.0h, 1.0h), gid);
    }

    kernel void paper_dilate_v(
        texture2d<half, access::read>  hMaskTex [[texture(0)]],
        texture2d<half, access::write> maskTex  [[texture(1)]],
        constant PaperCutoutUniforms&  u        [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.texSize.x || gid.y >= u.texSize.y) return;
        int maxR = max(u.rInner, u.rOuter);
        half mIn = 0.0h, mOut = 0.0h;
        int y0 = max(0, int(gid.y) - maxR);
        int y1 = min(int(u.texSize.y) - 1, int(gid.y) + maxR);
        for (int y = y0; y <= y1; ++y) {
            half2 rg = hMaskTex.read(uint2(gid.x, y)).rg;
            int d = abs(y - int(gid.y));
            if (d <= u.rInner) mIn  = max(mIn, rg.r);
            if (d <= u.rOuter) mOut = max(mOut, rg.g);
        }
        maskTex.write(half4(mIn, mOut, 0.0h, 1.0h), gid);
    }

    kernel void gaussian_blur_2x_h_from_mask(
        texture2d<half, access::sample> maskTex   [[texture(0)]],
        texture2d<half, access::write>  halfBlurH [[texture(1)]],
        constant PaperCutoutUniforms&   u         [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.halfSize.x || gid.y >= u.halfSize.y) return;
        constexpr sampler lin(coord::normalized, address::clamp_to_edge, filter::linear);
        float sigma = max(u.shadowSigma2x, 0.5f);
        int radius = int(ceil(3.0f * sigma));
        float inv2s2 = 0.5f / (sigma * sigma);
        float sum = 0.0f, wsum = 0.0f;
        for (int k = -radius; k <= radius; ++k) {
            float2 uv = (float2(int2(gid) + int2(k, 0)) * 2.0f + 1.0f) / float2(u.texSize);
            float w = exp(-float(k * k) * inv2s2);
            sum  += float(maskTex.sample(lin, uv).g) * w;
            wsum += w;
        }
        halfBlurH.write(half4(half(sum / wsum), 0, 0, 1), gid);
    }

    kernel void gaussian_blur_2x_v(
        texture2d<half, access::read>  halfBlurH [[texture(0)]],
        texture2d<half, access::write> halfBlurV [[texture(1)]],
        constant PaperCutoutUniforms&  u         [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.halfSize.x || gid.y >= u.halfSize.y) return;
        float sigma = max(u.shadowSigma2x, 0.5f);
        int radius = int(ceil(3.0f * sigma));
        float inv2s2 = 0.5f / (sigma * sigma);
        float sum = 0.0f, wsum = 0.0f;
        for (int k = -radius; k <= radius; ++k) {
            int y = clamp(int(gid.y) + k, 0, int(u.halfSize.y) - 1);
            float w = exp(-float(k * k) * inv2s2);
            sum  += float(halfBlurH.read(uint2(gid.x, y)).r) * w;
            wsum += w;
        }
        halfBlurV.write(half4(half(sum / wsum), 0, 0, 1), gid);
    }

    kernel void paper_cutout_merge(
        texture2d<half, access::read>   srcTex       [[texture(0)]],
        texture2d<half, access::read>   maskTex      [[texture(1)]],
        texture2d<half, access::sample> shadowBlur2x [[texture(2)]],
        texture2d<half, access::write>  dstTex       [[texture(3)]],
        constant PaperCutoutUniforms&   u            [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.texSize.x || gid.y >= u.texSize.y) return;
        constexpr sampler lin(coord::normalized, address::clamp_to_edge, filter::linear);

        float4 src = float4(srcTex.read(gid));
        float2 m   = float2(maskTex.read(gid).rg);
        float2 shUv = (float2(gid) + 0.5f - u.shadowOffset) / float2(u.texSize);
        float shA  = float(shadowBlur2x.sample(lin, shUv).r) * u.shadowOpacity;

        float3 cWhite  = float3(0.9843137f, 0.9725490f, 0.9411765f);
        float3 cEdge   = float3(0.7960784f, 0.7333333f, 0.6274510f);
        float3 cShadow = float3(0.0784314f, 0.0627451f, 0.0392157f);

        if (u.linearRGB != 0u) {
            cWhite  = srgbToLinear(cWhite);
            cEdge   = srgbToLinear(cEdge);
            cShadow = srgbToLinear(cShadow);
            float aSafe = max(src.a, 1e-5f);
            src.rgb = srgbToLinear(src.rgb / aSafe) * src.a;
        }

        float4 out = float4(cShadow * shA, shA);
        float4 edgeP   = float4(cEdge  * m.y, m.y);
        float4 borderP = float4(cWhite * m.x, m.x);
        out = edgeP   + out * (1.0f - edgeP.a);
        out = borderP + out * (1.0f - borderP.a);
        out = src     + out * (1.0f - src.a);

        if (u.linearRGB != 0u) {
            float aSafe = max(out.a, 1e-5f);
            out.rgb = linearToSrgb(out.rgb / aSafe) * out.a;
        }
        if (u.compositeBg != 0u) {
            out = out + u.bgColorSRGB * (1.0f - out.a);
        }
        dstTex.write(half4(clamp(out, 0.0f, 1.0f)), gid);
    }

    struct MarkerUniforms {
        uint2  texSize;
        float2 baseFreq;
        float  dispScale;
        uint   numOctaves;
        uint   linearFilter;
        uint   compositeBg;
        float4 bgColorSRGB;
        float2 originOffset;
        float2 _pad0;
    };

    struct TurbulenceTables {
        uchar lattice[514];
        half2 gradR[256];
        half2 gradG[256];
    };

    inline float w3c_scurve(float t) { return t * t * (3.0f - 2.0f * t); }

    inline float evalPerlinOctave(
        float2 pt, float2 fFreq,
        constant uchar* lattice, constant half2* grad)
    {
        float2 vec = pt * fFreq;
        float2 t   = vec + 4096.0f;
        int bx0 = int(floor(t.x)) & 0xFF;
        int by0 = int(floor(t.y)) & 0xFF;
        int bx1 = (bx0 + 1) & 0xFF;
        int by1 = (by0 + 1) & 0xFF;

        float rx0 = fract(t.x), rx1 = rx0 - 1.0f;
        float ry0 = fract(t.y), ry1 = ry0 - 1.0f;

        int i = int(lattice[bx0]), j = int(lattice[bx1]);
        int b00 = int(lattice[i + by0]) & 0xFF;
        int b10 = int(lattice[j + by0]) & 0xFF;
        int b01 = int(lattice[i + by1]) & 0xFF;
        int b11 = int(lattice[j + by1]) & 0xFF;

        float sx = w3c_scurve(rx0);
        float sy = w3c_scurve(ry0);

        float2 g00 = float2(grad[b00]);
        float2 g10 = float2(grad[b10]);
        float2 g01 = float2(grad[b01]);
        float2 g11 = float2(grad[b11]);

        float u00 = rx0 * g00.x + ry0 * g00.y;
        float v10 = rx1 * g10.x + ry0 * g10.y;
        float a   = mix(u00, v10, sx);

        float u01 = rx0 * g01.x + ry1 * g01.y;
        float v11 = rx1 * g11.x + ry1 * g11.y;
        float b   = mix(u01, v11, sx);

        return mix(a, b, sy);
    }

    kernel void marker_texture_displace(
        texture2d<half, access::sample> srcTex [[texture(0)]],
        texture2d<half, access::write>  dstTex [[texture(1)]],
        constant MarkerUniforms&        u      [[buffer(0)]],
        constant TurbulenceTables&      tbl    [[buffer(1)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.texSize.x || gid.y >= u.texSize.y) return;
        constexpr sampler linClamp(coord::normalized, address::clamp_to_zero, filter::linear);

        float2 pt = float2(gid) + 0.5f - u.originOffset;
        float sumR = 0.0f, sumG = 0.0f;
        float2 freq = u.baseFreq;
        float  ratio = 1.0f;
        for (uint oct = 0; oct < u.numOctaves; ++oct) {
            sumR  += evalPerlinOctave(pt, freq, tbl.lattice, tbl.gradR) / ratio;
            sumG  += evalPerlinOctave(pt, freq, tbl.lattice, tbl.gradG) / ratio;
            freq  *= 2.0f;
            ratio *= 2.0f;
        }
        float nx = clamp(sumR * 0.5f + 0.5f, 0.0f, 1.0f);
        float ny = clamp(sumG * 0.5f + 0.5f, 0.0f, 1.0f);
        if (u.linearFilter != 0u) {
            float3 lin = srgbToLinear(float3(nx, ny, 0.0f));
            nx = lin.x;
            ny = lin.y;
        }

        float2 delta = float2(nx - 0.5f, ny - 0.5f) * u.dispScale;
        float2 uv = (float2(gid) + 0.5f + delta) / float2(u.texSize);
        float4 out = float4(srcTex.sample(linClamp, uv));
        if (u.compositeBg != 0u) {
            out = out + u.bgColorSRGB * (1.0f - out.a);
        }
        dstTex.write(half4(clamp(out, 0.0f, 1.0f)), gid);
    }

    struct OverlayUniforms {
        uint2 canvasSize;
        uint2 ovOrigin;
        uint2 ovSize;
        float opacity;
        uint  _pad0;
    };

    kernel void composite_overlay(
        texture2d<half, access::read>  bgTex  [[texture(0)]],
        texture2d<half, access::read>  ovTex  [[texture(1)]],
        texture2d<half, access::write> dstTex [[texture(2)]],
        constant OverlayUniforms&      u      [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= u.canvasSize.x || gid.y >= u.canvasSize.y) return;
        float4 bg = float4(bgTex.read(gid));
        if (gid.x < u.ovOrigin.x || gid.y < u.ovOrigin.y ||
            gid.x >= u.ovOrigin.x + u.ovSize.x || gid.y >= u.ovOrigin.y + u.ovSize.y) {
            dstTex.write(half4(bg), gid);
            return;
        }
        float4 ov = float4(ovTex.read(gid - u.ovOrigin)) * u.opacity;
        float4 out = ov + bg * (1.0f - ov.a);
        dstTex.write(half4(out), gid);
    }
    """#

    public static func defaultBinaryArchiveURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Safarium/wave2-effects.metallib-archive")
    }

    public init(
        binaryArchiveURL: URL? = Wave2MetalEffectsEngine.defaultBinaryArchiveURL(),
        bakeArchive: Bool = true
    ) throws {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else {
            throw SafariumError.encode("Metal device unavailable")
        }
        var cacheOpt: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cacheOpt) == kCVReturnSuccess,
              let cache = cacheOpt else {
            throw SafariumError.encode("CVMetalTextureCacheCreate failed")
        }
        self.device = dev
        self.commandQueue = q
        self.textureCache = cache

        let lib = try dev.makeLibrary(source: Self.shaderSource, options: nil)

        var archive: MTLBinaryArchive?
        if let archURL = binaryArchiveURL {
            try? FileManager.default.createDirectory(at: archURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let archDesc = MTLBinaryArchiveDescriptor()
            if FileManager.default.fileExists(atPath: archURL.path) {
                archDesc.url = archURL
            }
            archive = try? dev.makeBinaryArchive(descriptor: archDesc)
        }

        func makePipe(_ name: String) throws -> MTLComputePipelineState {
            guard let fn = lib.makeFunction(name: name) else {
                throw SafariumError.encode("missing Metal kernel '\(name)'")
            }
            let desc = MTLComputePipelineDescriptor()
            desc.computeFunction = fn
            if let arch = archive {
                desc.binaryArchives = [arch]
                if bakeArchive {
                    try? arch.addComputePipelineFunctions(descriptor: desc)
                }
            }
            return try dev.makeComputePipelineState(descriptor: desc, options: [], reflection: nil)
        }

        self.pPaperDilateH = try makePipe("paper_dilate_h")
        self.pPaperDilateV = try makePipe("paper_dilate_v")
        self.pGauss2xH = try makePipe("gaussian_blur_2x_h_from_mask")
        self.pGauss2xV = try makePipe("gaussian_blur_2x_v")
        self.pPaperMerge = try makePipe("paper_cutout_merge")
        self.pMarkerDisp = try makePipe("marker_texture_displace")
        self.pCompositeOverlay = try makePipe("composite_overlay")

        if bakeArchive, let arch = archive, let archURL = binaryArchiveURL {
            try? arch.serialize(to: archURL)
        }

        self.turbulenceTables = Self.buildTurbulenceTablesBuffer(device: dev, seed: 0)
    }

    private static func buildTurbulenceTablesBuffer(device: MTLDevice, seed: Int) -> MTLBuffer {
        let randM: Int64 = 2147483647
        let randA: Int64 = 16807
        let randQ: Int64 = 127773
        let randR: Int64 = 2836
        let bSize = 256

        var lSeed = Int64(seed)
        if lSeed <= 0 { lSeed = -(lSeed % (randM - 1)) + 1 }
        if lSeed > randM - 1 { lSeed = randM - 1 }

        func nextRand() -> Int64 {
            var res = randA * (lSeed % randQ) - randR * (lSeed / randQ)
            if res <= 0 { res += randM }
            lSeed = res
            return res
        }

        var grad = Array(repeating: Array(repeating: SIMD2<Float>(0, 0), count: bSize), count: 2)
        var lattice = [UInt8](repeating: 0, count: 514)

        for k in 0..<2 {
            for i in 0..<bSize {
                var gx: Float = 0, gy: Float = 0
                repeat {
                    gx = Float(Int(nextRand() % Int64(2 * bSize)) - bSize) / Float(bSize)
                    gy = Float(Int(nextRand() % Int64(2 * bSize)) - bSize) / Float(bSize)
                } while gx == 0 && gy == 0
                let len = sqrt(gx * gx + gy * gy)
                grad[k][i] = SIMD2<Float>(gx / len, gy / len)
            }
        }
        for i in 0..<bSize { lattice[i] = UInt8(i) }
        for i in stride(from: bSize - 1, through: 1, by: -1) {
            let j = Int(nextRand() % Int64(bSize))
            lattice.swapAt(i, j)
        }
        for i in 0..<(bSize + 2) { lattice[bSize + i] = lattice[i] }

        let buf = device.makeBuffer(length: 2564, options: .storageModeShared)!
        let raw = buf.contents()
        memcpy(raw, &lattice, 514)
        let gradRPtr = raw.advanced(by: 516).assumingMemoryBound(to: Float16.self)
        let gradGPtr = raw.advanced(by: 1540).assumingMemoryBound(to: Float16.self)
        for i in 0..<bSize {
            gradRPtr[i * 2] = Float16(grad[0][i].x)
            gradRPtr[i * 2 + 1] = Float16(grad[0][i].y)
            gradGPtr[i * 2] = Float16(grad[1][i].x)
            gradGPtr[i * 2 + 1] = Float16(grad[1][i].y)
        }
        return buf
    }

    private func threadgroups(pipeline: MTLComputePipelineState, width: Int, height: Int) -> (MTLSize, MTLSize) {
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        return (
            MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1),
            MTLSize(width: w, height: h, depth: 1)
        )
    }

    private func ensurePaperCutoutTextures(width: Int, height: Int) throws {
        if cachedTexW == width && cachedTexH == height && hMaskTex != nil { return }
        func makeTex(_ w: Int, _ h: Int, _ fmt: MTLPixelFormat) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: fmt, width: w, height: h, mipmapped: false)
            d.storageMode = .private
            d.usage = [.shaderRead, .shaderWrite]
            guard let t = device.makeTexture(descriptor: d) else {
                throw SafariumError.encode("makeTexture \(w)x\(h) failed")
            }
            return t
        }
        let hw = max(1, (width + 1) / 2), hh = max(1, (height + 1) / 2)
        hMaskTex = try makeTex(width, height, .rg8Unorm)
        maskTex = try makeTex(width, height, .rg8Unorm)
        halfBlurH = try makeTex(hw, hh, .r8Unorm)
        halfBlurV = try makeTex(hw, hh, .r8Unorm)
        cachedTexW = width
        cachedTexH = height
    }

    private func bindBGRA8(_ pb: CVPixelBuffer) throws -> (CVMetalTexture, MTLTexture) {
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        var cvTex: CVMetalTexture?
        let st = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex
        )
        guard st == kCVReturnSuccess, let cv = cvTex, let tex = CVMetalTextureGetTexture(cv) else {
            throw SafariumError.encode("CVMetalTextureCacheCreateTextureFromImage failed (\(st))")
        }
        return (cv, tex)
    }

    private func makeBGRA8Buffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferBytesPerRowAlignmentKey as String: 64,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let st = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let out = pb else {
            throw SafariumError.encode("CVPixelBufferCreate BGRA8 failed (\(st))")
        }
        return out
    }

    @discardableResult
    public func applyEffect(
        _ effect: Wave2EffectKind,
        to srcPB: CVPixelBuffer,
        into dstPB: CVPixelBuffer? = nil
    ) throws -> CVPixelBuffer {
        if effect == .none {
            return srcPB
        }
        let w = CVPixelBufferGetWidth(srcPB)
        let h = CVPixelBufferGetHeight(srcPB)
        let targetPB = try dstPB ?? makeBGRA8Buffer(width: w, height: h)
        let (srcCV, srcTex) = try bindBGRA8(srcPB)
        let (dstCV, dstTex) = try bindBGRA8(targetPB)
        guard let cmd = commandQueue.makeCommandBuffer() else {
            throw SafariumError.encode("makeCommandBuffer failed")
        }
        try encodeEffect(effect, srcTex: srcTex, dstTex: dstTex, on: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
        _ = (srcCV, dstCV)
        if let err = cmd.error {
            throw SafariumError.encode("Metal effect execution failed: \(err)")
        }
        CVMetalTextureCacheFlush(textureCache, 0)
        return targetPB
    }

    public func encodeEffect(
        _ effect: Wave2EffectKind,
        srcTex: MTLTexture,
        dstTex: MTLTexture,
        on cmd: MTLCommandBuffer
    ) throws {
        let w = dstTex.width
        let h = dstTex.height
        switch effect {
        case .none:
            guard let blit = cmd.makeBlitCommandEncoder() else {
                throw SafariumError.encode("makeBlitCommandEncoder failed")
            }
            blit.copy(from: srcTex, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: w, height: h, depth: 1),
                      to: dstTex, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        case .paperCutout:
            try ensurePaperCutoutTextures(width: w, height: h)
            guard let hMaskTex, let maskTex, let halfBlurH, let halfBlurV,
                  let enc = cmd.makeComputeCommandEncoder() else {
                throw SafariumError.encode("paperCutout compute encoder failed")
            }
            let hw = max(1, (w + 1) / 2), hh = max(1, (h + 1) / 2)
            var uni = PaperCutoutUniforms(
                texSize: SIMD2<UInt32>(UInt32(w), UInt32(h)),
                halfSize: SIMD2<UInt32>(UInt32(hw), UInt32(hh)),
                rInner: 10, rOuter: 11,
                shadowOffset: SIMD2<Float>(5.0, 13.0),
                shadowSigma2x: 4.0, shadowOpacity: 0.34,
                linearRGB: 1,
                bgColorSRGB: .zero, compositeBg: 0
            )
            let (g1, t1) = threadgroups(pipeline: pPaperDilateH, width: w, height: h)
            enc.setComputePipelineState(pPaperDilateH)
            enc.setTexture(srcTex, index: 0); enc.setTexture(hMaskTex, index: 1)
            enc.setBytes(&uni, length: MemoryLayout<PaperCutoutUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g1, threadsPerThreadgroup: t1)
            enc.memoryBarrier(scope: .textures)

            enc.setComputePipelineState(pPaperDilateV)
            enc.setTexture(hMaskTex, index: 0); enc.setTexture(maskTex, index: 1)
            enc.setBytes(&uni, length: MemoryLayout<PaperCutoutUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g1, threadsPerThreadgroup: t1)
            enc.memoryBarrier(scope: .textures)

            let (g2, t2) = threadgroups(pipeline: pGauss2xH, width: hw, height: hh)
            enc.setComputePipelineState(pGauss2xH)
            enc.setTexture(maskTex, index: 0); enc.setTexture(halfBlurH, index: 1)
            enc.setBytes(&uni, length: MemoryLayout<PaperCutoutUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g2, threadsPerThreadgroup: t2)
            enc.memoryBarrier(scope: .textures)

            enc.setComputePipelineState(pGauss2xV)
            enc.setTexture(halfBlurH, index: 0); enc.setTexture(halfBlurV, index: 1)
            enc.setBytes(&uni, length: MemoryLayout<PaperCutoutUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g2, threadsPerThreadgroup: t2)
            enc.memoryBarrier(scope: .textures)

            let (g3, t3) = threadgroups(pipeline: pPaperMerge, width: w, height: h)
            enc.setComputePipelineState(pPaperMerge)
            enc.setTexture(srcTex, index: 0); enc.setTexture(maskTex, index: 1)
            enc.setTexture(halfBlurV, index: 2); enc.setTexture(dstTex, index: 3)
            enc.setBytes(&uni, length: MemoryLayout<PaperCutoutUniforms>.stride, index: 0)
            enc.dispatchThreadgroups(g3, threadsPerThreadgroup: t3)
            enc.endEncoding()
        case .markerTexture:
            guard let enc = cmd.makeComputeCommandEncoder() else {
                throw SafariumError.encode("markerTexture compute encoder failed")
            }
            var uni = MarkerUniforms(
                texSize: SIMD2<UInt32>(UInt32(w), UInt32(h)),
                baseFreq: SIMD2<Float>(0.06, 0.06),
                dispScale: 2.8,
                numOctaves: 2,
                linearFilter: 0, // Sharp grain (linearFilter = 0, ΔE00 1.339)
                compositeBg: 0,
                bgColorSRGB: .zero,
                originOffset: .zero
            )
            let (g, t) = threadgroups(pipeline: pMarkerDisp, width: w, height: h)
            enc.setComputePipelineState(pMarkerDisp)
            enc.setTexture(srcTex, index: 0); enc.setTexture(dstTex, index: 1)
            enc.setBytes(&uni, length: MemoryLayout<MarkerUniforms>.stride, index: 0)
            enc.setBuffer(turbulenceTables, offset: 0, index: 1)
            enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
            enc.endEncoding()
        }
    }

    private func ensureSpatialScaler(inW: Int, inH: Int, outW: Int, outH: Int) throws -> (MTLFXSpatialScaler, MTLTexture) {
        if let sc = spatialScaler, let up = upscaledPrivateTex,
           scalerInputW == inW, scalerInputH == inH, scalerOutputW == outW, scalerOutputH == outH {
            return (sc, up)
        }
        let sd = MTLFXSpatialScalerDescriptor()
        sd.colorTextureFormat = .bgra8Unorm
        sd.outputTextureFormat = .bgra8Unorm
        sd.inputWidth = inW
        sd.inputHeight = inH
        sd.outputWidth = outW
        sd.outputHeight = outH
        sd.colorProcessingMode = .perceptual
        guard let sc = sd.makeSpatialScaler(device: device) else {
            throw SafariumError.encode("MTLFXSpatialScalerDescriptor failed for \(inW)x\(inH) -> \(outW)x\(outH)")
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: outW, height: outH, mipmapped: false)
        d.storageMode = .private
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let up = device.makeTexture(descriptor: d) else {
            throw SafariumError.encode("failed allocating .private texture for MTLFXSpatialScaler")
        }
        spatialScaler = sc
        upscaledPrivateTex = up
        scalerInputW = inW; scalerInputH = inH
        scalerOutputW = outW; scalerOutputH = outH
        return (sc, up)
    }

    /// Split rendering: scales low-res background into `.private` via `MTLFXSpatialScaler`, then
    /// composites crisp 1× overlay (e.g. Thai text/UI) on top without blurring glyphs.
    public func applySplitMetalFX(
        backgroundHalfRes bgPB: CVPixelBuffer,
        overlay1x ovPB: CVPixelBuffer,
        into outPB: CVPixelBuffer
    ) throws {
        let inW = CVPixelBufferGetWidth(bgPB)
        let inH = CVPixelBufferGetHeight(bgPB)
        let outW = CVPixelBufferGetWidth(outPB)
        let outH = CVPixelBufferGetHeight(outPB)
        let ovW = CVPixelBufferGetWidth(ovPB)
        let ovH = CVPixelBufferGetHeight(ovPB)
        let (sc, upTex) = try ensureSpatialScaler(inW: inW, inH: inH, outW: outW, outH: outH)

        let (bgCV, bgTex) = try bindBGRA8(bgPB)
        let (ovCV, ovTex) = try bindBGRA8(ovPB)
        let (outCV, outTex) = try bindBGRA8(outPB)
        guard let cmd = commandQueue.makeCommandBuffer() else {
            throw SafariumError.encode("makeCommandBuffer failed for Split MetalFX")
        }

        sc.colorTexture = bgTex
        sc.inputContentWidth = inW
        sc.inputContentHeight = inH
        sc.outputTexture = upTex
        sc.encode(commandBuffer: cmd)

        guard let enc = cmd.makeComputeCommandEncoder() else {
            throw SafariumError.encode("composite_overlay encoder failed")
        }
        var u = CompositeOverlayUniforms(
            canvasSize: SIMD2<UInt32>(UInt32(outW), UInt32(outH)),
            ovOrigin: .zero,
            ovSize: SIMD2<UInt32>(UInt32(min(ovW, outW)), UInt32(min(ovH, outH))),
            opacity: 1.0
        )
        let (g, t) = threadgroups(pipeline: pCompositeOverlay, width: outW, height: outH)
        enc.setComputePipelineState(pCompositeOverlay)
        enc.setTexture(upTex, index: 0)
        enc.setTexture(ovTex, index: 1)
        enc.setTexture(outTex, index: 2)
        enc.setBytes(&u, length: MemoryLayout<CompositeOverlayUniforms>.stride, index: 0)
        enc.dispatchThreadgroups(g, threadsPerThreadgroup: t)
        enc.endEncoding()

        cmd.commit()
        cmd.waitUntilCompleted()
        _ = (bgCV, ovCV, outCV)
        if let err = cmd.error {
            throw SafariumError.encode("Split MetalFX failed: \(err)")
        }
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}
