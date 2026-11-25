import Accelerate
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Metal

// MARK: - Wave 12A Public Configuration & Telemetry Types

/// Subsampled 4:2:0 chroma sample siting convention.
public enum ChromaSiting: String, Codable, Sendable, CaseIterable {
    /// Horizontal left / MPEG-2 / H.264 / HEVC co-sited chroma (`x = 2*cx, y = 2*cy + 0.5`).
    case coSited
    /// Center-sited chroma (`x = 2*cx + 0.5, y = 2*cy + 0.5`, JPEG / MPEG-1 style).
    case centerSited
}

/// 4:4:4 -> 4:2:0 chroma filtering strategy.
public enum ChromaFilterMode: String, Codable, Sendable, CaseIterable {
    /// Standard uniform box/phase average without edge protection.
    case boxAverage
    /// Phase-aware luma-guided edge-aware chroma filtering with joint SharpYUV-style
    /// clamped-gamut luma/chroma refinement to suppress saturated edge bleed and chroma haloing.
    case lumaGuidedEdgeAware
}

/// Quantization dithering strategy applied before 8-bit NV12 or 10-bit P010 packing.
public enum DitherMode: String, Codable, Sendable, CaseIterable {
    /// Nearest-level rounding with no dither.
    case none
    /// Deterministic 4x4 ordered Bayer matrix dithering (+/- 0.5 LSB).
    case bayer4x4
    /// Temporally-stable Interleaved Gradient Noise (IGN) dithering (+/- 0.5 LSB,
    /// smoothly modulated across `frameIndex % 4` to prevent dark-gradient banding without shimmer).
    case temporalInterleavedGradient
}

/// Configuration for `MetalChromaPipeline` RGB <-> YCbCr 4:2:0 conversions.
public struct ChromaConversionConfig: Codable, Sendable, Equatable {
    public var bitDepth: Int
    public var siting: ChromaSiting
    public var filterMode: ChromaFilterMode
    public var ditherMode: DitherMode
    public var isBT2020: Bool
    public var fullRange: Bool
    public var frameIndex: UInt32

    public init(
        bitDepth: Int = 10,
        siting: ChromaSiting = .coSited,
        filterMode: ChromaFilterMode = .lumaGuidedEdgeAware,
        ditherMode: DitherMode = .temporalInterleavedGradient,
        isBT2020: Bool = false,
        fullRange: Bool = false,
        frameIndex: UInt32 = 0
    ) {
        self.bitDepth = bitDepth
        self.siting = siting
        self.filterMode = filterMode
        self.ditherMode = ditherMode
        self.isBT2020 = isBT2020
        self.fullRange = fullRange
        self.frameIndex = frameIndex
    }
}

/// Perceptual CIEDE2000 & temporal stability metrics for chroma fidelity evaluation.
public struct ChromaDeltaEReport: Codable, Sendable, Equatable {
    public let meanDeltaE00: Double
    public let p95DeltaE00: Double
    public let p99DeltaE00: Double
    public let saturatedEdgeP95DeltaE00: Double
    public let textRegionP95DeltaE00: Double
    public let maxTemporalFlicker: Double

    public init(
        meanDeltaE00: Double,
        p95DeltaE00: Double,
        p99DeltaE00: Double,
        saturatedEdgeP95DeltaE00: Double,
        textRegionP95DeltaE00: Double,
        maxTemporalFlicker: Double = 0.0
    ) {
        self.meanDeltaE00 = meanDeltaE00
        self.p95DeltaE00 = p95DeltaE00
        self.p99DeltaE00 = p99DeltaE00
        self.saturatedEdgeP95DeltaE00 = saturatedEdgeP95DeltaE00
        self.textRegionP95DeltaE00 = textRegionP95DeltaE00
        self.maxTemporalFlicker = maxTemporalFlicker
    }
}

// MARK: - Uniform Bridge Struct

private struct ChromaKernelUniforms {
    var width: UInt32
    var height: UInt32
    var chromaWidth: UInt32
    var chromaHeight: UInt32
    var bitDepth: UInt32
    var coSited: UInt32
    var edgeAware: UInt32
    var ditherMode: UInt32
    var isBT2020: UInt32
    var fullRange: UInt32
    var frameIndex: UInt32
    var _pad0: UInt32 = 0
}

// MARK: - Wave 12A Metal Chroma Fidelity Pipeline

/// Zero-copy Metal GPU chroma fidelity pipeline for Apple Silicon.
///
/// Compiles runtime MSL compute kernels via `device.makeLibrary(source:options:)` (no external `.metal`
/// bundle resources needed, compatible across Swift 5.9–6.4 and macOS 14–27 SDKs):
/// 1. `bgra8_to_rgba16f_linear` — exact IEC 61966-2-1 sRGB EOTF into linear-light `RGBA16Float`.
/// 2. `rgba16f_to_nv12_and_p010_chroma_aware` — deferred, phase-aware 4:4:4 -> 4:2:0 YCbCr conversion
///    directly into IOSurface-backed `NV12` (8-bit) or `P010` (10-bit MSB-aligned) via `CVMetalTextureCache`,
///    with luma-guided edge-aware chroma filtering + SharpYUV-style clamped-gamut refinement + IGN dithering.
/// 3. `yuv420_to_bgra8_reference` — exact siting-aware bilinear YCbCr -> BGRA8 GPU reconstruction kernel.
public final class MetalChromaPipeline: @unchecked Sendable {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let textureCache: CVMetalTextureCache

    private let pBGRAtoLinear: MTLComputePipelineState
    private let pLinearToYUV: MTLComputePipelineState
    private let pYUVtoBGRA: MTLComputePipelineState

    private let lock = NSLock()
    private var linearTexture: MTLTexture?
    private var cachedWidth: Int = 0
    private var cachedHeight: Int = 0

    // MARK: - Inline Metal Shading Language Source

    private static let shaderSource: String = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct ChromaKernelUniforms {
        uint width;
        uint height;
        uint chromaWidth;
        uint chromaHeight;
        uint bitDepth;
        uint coSited;
        uint edgeAware;
        uint ditherMode;
        uint isBT2020;
        uint fullRange;
        uint frameIndex;
        uint _pad0;
    };

    // Exact IEC 61966-2-1 sRGB EOTF (encoded -> linear light).
    inline float srgb_to_linear_ch(float v) {
        v = clamp(v, 0.0f, 1.0f);
        return (v <= 0.04045f) ? (v / 12.92f) : pow((v + 0.055f) / 1.055f, 2.4f);
    }

    inline float3 srgb_to_linear(float3 c) {
        return float3(
            srgb_to_linear_ch(c.r),
            srgb_to_linear_ch(c.g),
            srgb_to_linear_ch(c.b)
        );
    }

    // Exact inverse sRGB OETF (linear light -> encoded).
    inline float linear_to_srgb_ch(float v) {
        v = clamp(v, 0.0f, 1.0f);
        return (v <= 0.0031308f) ? (12.92f * v) : (1.055f * pow(v, 1.0f / 2.4f) - 0.055f);
    }

    inline float3 linear_to_srgb(float3 c) {
        return float3(
            linear_to_srgb_ch(c.r),
            linear_to_srgb_ch(c.g),
            linear_to_srgb_ch(c.b)
        );
    }

    struct YUVMatrix {
        float kr;
        float kg;
        float kb;
        float rFromCr;
        float gFromCb;
        float gFromCr;
        float bFromCb;
        float invCbDiv;
        float invCrDiv;
    };

    inline YUVMatrix make_yuv_matrix(uint isBT2020) {
        YUVMatrix m;
        if (isBT2020 != 0u) {
            m.kr = 0.2627f;
            m.kg = 0.6780f;
            m.kb = 0.0593f;
            m.rFromCr = 1.4746f;
            m.gFromCb = -0.164553127f;
            m.gFromCr = -0.571353127f;
            m.bFromCb = 1.8814f;
        } else {
            m.kr = 0.2126f;
            m.kg = 0.7152f;
            m.kb = 0.0722f;
            m.rFromCr = 1.5748f;
            m.gFromCb = -0.187324273f;
            m.gFromCr = -0.468124273f;
            m.bFromCb = 1.8556f;
        }
        m.invCbDiv = 1.0f / m.bFromCb;
        m.invCrDiv = 1.0f / m.rFromCr;
        return m;
    }

    inline float3 rgb_to_ycbcr(float3 rgb, constant YUVMatrix& unused, YUVMatrix m) {
        (void)unused;
        float y  = m.kr * rgb.r + m.kg * rgb.g + m.kb * rgb.b;
        float cb = (rgb.b - y) * m.invCbDiv;
        float cr = (rgb.r - y) * m.invCrDiv;
        return float3(y, cb, cr);
    }

    inline float3 rgb_to_ycbcr_val(float3 rgb, YUVMatrix m) {
        float y  = m.kr * rgb.r + m.kg * rgb.g + m.kb * rgb.b;
        float cb = (rgb.b - y) * m.invCbDiv;
        float cr = (rgb.r - y) * m.invCrDiv;
        return float3(y, cb, cr);
    }

    inline float3 ycbcr_to_rgb_raw(float y, float cb, float cr, YUVMatrix m) {
        float r = y + m.rFromCr * cr;
        float g = y + m.gFromCb * cb + m.gFromCr * cr;
        float b = y + m.bFromCb * cb;
        return float3(r, g, b);
    }

    // Zero-mean dithering noise strictly inside (-0.495, +0.495) LSB.
    inline float compute_dither(uint2 pos, uint mode, uint frameIndex) {
        if (mode == 0u) {
            return 0.0f;
        }
        if (mode == 1u) {
            // 4x4 ordered Bayer threshold matrix.
            constexpr float bayer[16] = {
                 0.0f,  8.0f,  2.0f, 10.0f,
                12.0f,  4.0f, 14.0f,  6.0f,
                 3.0f, 11.0f,  1.0f,  9.0f,
                15.0f,  7.0f, 13.0f,  5.0f
            };
            uint idx = ((pos.y & 3u) << 2u) | (pos.x & 3u);
            return (((bayer[idx] + 0.5f) / 16.0f) - 0.5f) * 0.99f;
        }
        // Temporally-stable Interleaved Gradient Noise (Jimenez IGN),
        // smoothly modulated across frameIndex % 4 without temporal shimmer.
        float phase = float(frameIndex & 3u);
        float2 p = float2(pos) + 5.588238f * phase;
        float ign = fract(52.9829189f * fract(dot(p, float2(0.06711056f, 0.00583715f))));
        return (ign - 0.5f) * 0.99f;
    }

    inline float pack_luma(float y, float dither, uint bitDepth, uint fullRange) {
        y = clamp(y, 0.0f, 1.0f);
        if (bitDepth >= 10u) {
            float code = (fullRange != 0u) ? (1023.0f * y) : (64.0f + 876.0f * y);
            float lo = (fullRange != 0u) ? 0.0f : 64.0f;
            float hi = (fullRange != 0u) ? 1023.0f : 940.0f;
            float q10 = clamp(floor(code + dither + 0.5f), lo, hi);
            // P010 stores 10-bit code in the upper 10 bits of uint16 (q10 << 6).
            return (q10 * 64.0f) / 65535.0f;
        } else {
            float code = (fullRange != 0u) ? (255.0f * y) : (16.0f + 219.0f * y);
            float lo = (fullRange != 0u) ? 0.0f : 16.0f;
            float hi = (fullRange != 0u) ? 255.0f : 235.0f;
            float q8 = clamp(floor(code + dither + 0.5f), lo, hi);
            return q8 / 255.0f;
        }
    }

    inline float2 pack_chroma(float2 cbcr, float2 dither, uint bitDepth, uint fullRange) {
        cbcr = clamp(cbcr, float2(-0.5f), float2(0.5f));
        if (bitDepth >= 10u) {
            float2 code = (fullRange != 0u)
                ? (512.0f + 1023.0f * cbcr)
                : (512.0f + 896.0f * cbcr);
            float lo = (fullRange != 0u) ? 0.0f : 64.0f;
            float hi = (fullRange != 0u) ? 1023.0f : 960.0f;
            float2 q10 = clamp(floor(code + dither + 0.5f), float2(lo), float2(hi));
            return (q10 * 64.0f) / 65535.0f;
        } else {
            float2 code = (fullRange != 0u)
                ? (128.0f + 255.0f * cbcr)
                : (128.0f + 224.0f * cbcr);
            float lo = (fullRange != 0u) ? 0.0f : 16.0f;
            float hi = (fullRange != 0u) ? 255.0f : 240.0f;
            float2 q8 = clamp(floor(code + dither + 0.5f), float2(lo), float2(hi));
            return q8 / 255.0f;
        }
    }

    inline float unpack_luma(float raw, uint bitDepth, uint fullRange) {
        if (bitDepth >= 10u) {
            float q10 = float(uint(round(raw * 65535.0f)) >> 6u);
            return (fullRange != 0u) ? (q10 / 1023.0f) : clamp((q10 - 64.0f) / 876.0f, 0.0f, 1.0f);
        } else {
            float q8 = round(raw * 255.0f);
            return (fullRange != 0u) ? (q8 / 255.0f) : clamp((q8 - 16.0f) / 219.0f, 0.0f, 1.0f);
        }
    }

    inline float2 unpack_chroma(float2 raw, uint bitDepth, uint fullRange) {
        if (bitDepth >= 10u) {
            float cb10 = float(uint(round(raw.x * 65535.0f)) >> 6u);
            float cr10 = float(uint(round(raw.y * 65535.0f)) >> 6u);
            float2 q10 = float2(cb10, cr10);
            return (fullRange != 0u) ? ((q10 - 512.0f) / 1023.0f) : ((q10 - 512.0f) / 896.0f);
        } else {
            float2 q8 = round(raw * 255.0f);
            return (fullRange != 0u) ? ((q8 - 128.0f) / 255.0f) : ((q8 - 128.0f) / 224.0f);
        }
    }

    // Fast OKLab conversion from linear-light RGB (15 FLOPs, closely tracks CIEDE2000).
    inline float3 linear_rgb_to_oklab(float3 c) {
        float l = 0.4122214708f * c.r + 0.5363325363f * c.g + 0.0514459929f * c.b;
        float m = 0.2119034982f * c.r + 0.6806995451f * c.g + 0.1073969566f * c.b;
        float s = 0.0883024619f * c.r + 0.2817188376f * c.g + 0.6299787005f * c.b;
        float l_ = pow(max(l, 0.0f), 1.0f / 3.0f);
        float m_ = pow(max(m, 0.0f), 1.0f / 3.0f);
        float s_ = pow(max(s, 0.0f), 1.0f / 3.0f);
        return float3(
            0.2104542553f * l_ + 0.7936177850f * m_ - 0.0040720468f * s_,
            1.9779984951f * l_ - 2.4285922050f * m_ + 0.4505937099f * s_,
            0.0259040371f * l_ + 0.7827717662f * m_ - 0.8086757660f * s_
        );
    }

    // CIEDE2000-weighted OKLab perceptual error squared:
    // Penalizes chroma bleed onto dark/neutral pixels (low C*) ~5x more strongly than
    // mild saturation compression on bright saturated strokes (high C*), matching CIEDE2000 SC.
    inline float oklab_de00_proxy_sq(float3 labRec, float3 labRef) {
        float dL = labRec.x - labRef.x;
        float da = labRec.y - labRef.y;
        float db = labRec.z - labRef.z;
        float cMean = 0.5f * (length(labRef.yz) + length(labRec.yz));
        float invSC = 1.0f / (1.0f + 11.0f * cMean);
        float chromaSq = (da * da + db * db) * (invSC * invSC);
        return (dL * dL) + 1.15f * chromaSq;
    }

    // Exact bilinear-footprint-aware minimax OKLab cost for candidate chroma (cb, cr)
    // and interior luma yVals[0..3], accounting for BOTH interior reconstruction AND
    // immediate bilinear chroma bleed into adjacent 1-pixel border neighbors.
    inline float footprint_oklab_cost(
        thread const float3 labIn[4],
        thread const float  yIn[4],
        thread const float3 labExt[6], // L0, L1, T0, T1, B0, B1
        thread const float  yExt[6],
        float2 cLeft,
        float2 cRight,
        float2 cTop,
        float2 cBot,
        float2 cbcr,
        uint coSited,
        YUVMatrix m
    ) {
        float2 cIn[4];
        if (coSited != 0u) {
            cIn[0] = 0.75f * cbcr + 0.25f * cTop;
            cIn[1] = 0.375f * cbcr + 0.50f * cRight + 0.125f * cTop;
            cIn[2] = 0.75f * cbcr + 0.25f * cBot;
            cIn[3] = 0.375f * cbcr + 0.50f * cRight + 0.125f * cBot;
        } else {
            cIn[0] = 0.5625f * cbcr + 0.21875f * cLeft  + 0.21875f * cTop;
            cIn[1] = 0.5625f * cbcr + 0.21875f * cRight + 0.21875f * cTop;
            cIn[2] = 0.5625f * cbcr + 0.21875f * cLeft  + 0.21875f * cBot;
            cIn[3] = 0.5625f * cbcr + 0.21875f * cRight + 0.21875f * cBot;
        }

        float sumErr = 0.0f;
        float maxErr = 0.0f;

        for (int i = 0; i < 4; ++i) {
            float3 rec = clamp(ycbcr_to_rgb_raw(yIn[i], cIn[i].x, cIn[i].y, m), 0.0f, 1.0f);
            float e = oklab_de00_proxy_sq(linear_rgb_to_oklab(srgb_to_linear(rec)), labIn[i]);
            sumErr += e;
            maxErr = max(maxErr, e);
        }

        // Exterior bleed footprint: how much cbcr leaks into left/top/bottom border pixels.
        float wL = (coSited != 0u) ? 0.50f : 0.25f;
        float2 cExt[6] = {
            (1.0f - wL) * cLeft + wL * cbcr,
            (1.0f - wL) * cLeft + wL * cbcr,
            0.75f * cTop + 0.25f * cbcr,
            0.75f * cTop + 0.25f * cbcr,
            0.75f * cBot + 0.25f * cbcr,
            0.75f * cBot + 0.25f * cbcr
        };

        for (int j = 0; j < 6; ++j) {
            float3 rec = clamp(ycbcr_to_rgb_raw(yExt[j], cExt[j].x, cExt[j].y, m), 0.0f, 1.0f);
            float e = oklab_de00_proxy_sq(linear_rgb_to_oklab(srgb_to_linear(rec)), labExt[j]);
            float wt = (j < 2 && coSited != 0u) ? 0.70f : 0.45f;
            sumErr += wt * e;
            maxErr = max(maxErr, e);
        }

        return sumErr + 1.10f * maxErr;
    }

    // Kernel 1: BGRA8 (sRGB/BT.709) -> linear-light RGBA16Float.
    kernel void bgra8_to_rgba16f_linear(
        texture2d<float, access::read>  srcBGRA   [[texture(0)]],
        texture2d<half,  access::write> dstLinear [[texture(1)]],
        constant ChromaKernelUniforms&  u         [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= u.width || gid.y >= u.height) {
            return;
        }
        float4 px = srcBGRA.read(gid);
        float3 lin = srgb_to_linear(px.rgb);
        dstLinear.write(half4(half3(lin), half(px.a)), gid);
    }

    // Kernel 2: Deferred, phase-aware, luma-guided 4:4:4 -> 4:2:0 YCbCr conversion
    // directly into IOSurface-backed NV12 (r8Unorm + rg8Unorm) or P010 (r16Unorm + rg16Unorm).
    kernel void rgba16f_to_nv12_and_p010_chroma_aware(
        texture2d<half,  access::read>  srcLinear [[texture(0)]],
        texture2d<float, access::write> dstY      [[texture(1)]],
        texture2d<float, access::write> dstUV     [[texture(2)]],
        constant ChromaKernelUniforms&  u         [[buffer(0)]],
        uint2 cid [[thread_position_in_grid]]
    ) {
        if (cid.x >= u.chromaWidth || cid.y >= u.chromaHeight) {
            return;
        }

        YUVMatrix m = make_yuv_matrix(u.isBT2020);

        uint x0 = cid.x * 2u;
        uint y0 = cid.y * 2u;
        uint x1 = min(x0 + 1u, u.width - 1u);
        uint y1 = min(y0 + 1u, u.height - 1u);
        uint xL = (x0 > 0u) ? (x0 - 1u) : 0u;
        uint xR = min(x1 + 1u, u.width - 1u);
        uint yT = (y0 > 0u) ? (y0 - 1u) : 0u;
        uint yB = min(y1 + 1u, u.height - 1u);

        uint2 coords[4] = {
            uint2(x0, y0), uint2(x1, y0),
            uint2(x0, y1), uint2(x1, y1)
        };

        float3 lin[4];
        float3 rgb[4];
        float3 ycc[4];
        float  yOut[4];

        for (int i = 0; i < 4; ++i) {
            lin[i] = float3(srcLinear.read(coords[i]).rgb);
            rgb[i] = linear_to_srgb(lin[i]);
            ycc[i] = rgb_to_ycbcr_val(rgb[i], m);
            yOut[i] = ycc[i].x;
        }

        // 1-pixel border neighbors around the 2x2 tile.
        float3 linL0 = float3(srcLinear.read(uint2(xL, y0)).rgb);
        float3 linL1 = float3(srcLinear.read(uint2(xL, y1)).rgb);
        float3 yccL0 = rgb_to_ycbcr_val(linear_to_srgb(linL0), m);
        float3 yccL1 = rgb_to_ycbcr_val(linear_to_srgb(linL1), m);

        float2 cbcrOut;

        if (u.edgeAware == 0u) {
            // Standard uniform/phase box average.
            if (u.coSited != 0u) {
                float2 row0 = 0.25f * yccL0.yz + 0.50f * ycc[0].yz + 0.25f * ycc[1].yz;
                float2 row1 = 0.25f * yccL1.yz + 0.50f * ycc[2].yz + 0.25f * ycc[3].yz;
                cbcrOut = 0.50f * (row0 + row1);
            } else {
                cbcrOut = 0.25f * (ycc[0].yz + ycc[1].yz + ycc[2].yz + ycc[3].yz);
            }
        } else {
            // Read right/top/bottom 1-pixel border neighbors to capture inter-block edges too.
            float3 linR0 = float3(srcLinear.read(uint2(xR, y0)).rgb);
            float3 linR1 = float3(srcLinear.read(uint2(xR, y1)).rgb);
            float3 linT0 = float3(srcLinear.read(uint2(x0, yT)).rgb);
            float3 linT1 = float3(srcLinear.read(uint2(x1, yT)).rgb);
            float3 linB0 = float3(srcLinear.read(uint2(x0, yB)).rgb);
            float3 linB1 = float3(srcLinear.read(uint2(x1, yB)).rgb);

            float3 yccR0 = rgb_to_ycbcr_val(linear_to_srgb(linR0), m);
            float3 yccR1 = rgb_to_ycbcr_val(linear_to_srgb(linR1), m);
            float3 yccT0 = rgb_to_ycbcr_val(linear_to_srgb(linT0), m);
            float3 yccT1 = rgb_to_ycbcr_val(linear_to_srgb(linT1), m);
            float3 yccB0 = rgb_to_ycbcr_val(linear_to_srgb(linB0), m);
            float3 yccB1 = rgb_to_ycbcr_val(linear_to_srgb(linB1), m);

            float2 cLeft  = 0.5f * (yccL0.yz + yccL1.yz);
            float2 cRight = 0.5f * (yccR0.yz + yccR1.yz);
            float2 cTop   = 0.5f * (yccT0.yz + yccT1.yz);
            float2 cBot   = 0.5f * (yccB0.yz + yccB1.yz);

            // Detect both intra-block AND inter-block luma/chroma edges.
            float yMin = min(min(ycc[0].x, ycc[1].x), min(ycc[2].x, ycc[3].x));
            float yMax = max(max(ycc[0].x, ycc[1].x), max(ycc[2].x, ycc[3].x));
            yMin = min(yMin, min(min(yccL0.x, yccL1.x), min(yccR0.x, yccR1.x)));
            yMax = max(yMax, max(max(yccL0.x, yccL1.x), max(yccR0.x, yccR1.x)));
            yMin = min(yMin, min(min(yccT0.x, yccT1.x), min(yccB0.x, yccB1.x)));
            yMax = max(yMax, max(max(yccT0.x, yccT1.x), max(yccB0.x, yccB1.x)));

            float2 cAvgIn = 0.25f * (ycc[0].yz + ycc[1].yz + ycc[2].yz + ycc[3].yz);
            float cEdge = max(
                max(length(ycc[0].yz - cAvgIn), length(ycc[1].yz - cAvgIn)),
                max(length(ycc[2].yz - cAvgIn), length(ycc[3].yz - cAvgIn))
            );
            cEdge = max(cEdge, max(length(cLeft - cAvgIn), length(cRight - cAvgIn)));
            cEdge = max(cEdge, max(length(cTop - cAvgIn), length(cBot - cAvgIn)));
            float ySpread = yMax - yMin;

            // Linear-light phase baseline for smooth regions.
            float3 linAvg;
            if (u.coSited != 0u) {
                float3 row0 = 0.25f * linL0 + 0.50f * lin[0] + 0.25f * lin[1];
                float3 row1 = 0.25f * linL1 + 0.50f * lin[2] + 0.25f * lin[3];
                linAvg = 0.50f * (row0 + row1);
            } else {
                linAvg = 0.25f * (lin[0] + lin[1] + lin[2] + lin[3]);
            }
            float3 yccLinInit = rgb_to_ycbcr_val(linear_to_srgb(linAvg), m);

            if (ySpread < 0.035f && cEdge < 0.035f) {
                // Smooth region (gradients, skin tones): pure linear-light phase average.
                cbcrOut = yccLinInit.yz;
            } else {
                // Edge block (intra-block or inter-block boundary):
                // Bilinear-footprint-aware OKLab minimax optimization over (Cb, Cr, Y[0..3]).
                float3 labIn[4];
                for (int i = 0; i < 4; ++i) {
                    labIn[i] = linear_rgb_to_oklab(lin[i]);
                }
                float3 labExt[6] = {
                    linear_rgb_to_oklab(linL0), linear_rgb_to_oklab(linL1),
                    linear_rgb_to_oklab(linT0), linear_rgb_to_oklab(linT1),
                    linear_rgb_to_oklab(linB0), linear_rgb_to_oklab(linB1)
                };
                float yExt[6] = {
                    yccL0.x, yccL1.x, yccT0.x, yccT1.x, yccB0.x, yccB1.x
                };

                // Non-overshooting chroma bounds: restrict chroma to the convex hull of the
                // 2x2 block's own pixels and neutral (0, 0). Prevents saturated neighbors from
                // contaminating clean dark blocks and eliminates out-of-hull ringing halos.
                float2 cMinIn = min(min(ycc[0].yz, ycc[1].yz), min(ycc[2].yz, ycc[3].yz));
                float2 cMaxIn = max(max(ycc[0].yz, ycc[1].yz), max(ycc[2].yz, ycc[3].yz));
                float2 cBoundLo = clamp(min(cMinIn, float2(0.0f)), float2(-0.5f), float2(0.5f));
                float2 cBoundHi = clamp(max(cMaxIn, float2(0.0f)), float2(-0.5f), float2(0.5f));

                // Evaluate smart initial chroma candidates inside the non-overshooting hull.
                float2 bestC = clamp(cAvgIn, cBoundLo, cBoundHi);
                float bestCost = footprint_oklab_cost(
                    labIn, yOut, labExt, yExt, cLeft, cRight, cTop, cBot, bestC, u.coSited, m
                );

                float2 linInit = clamp(yccLinInit.yz, cBoundLo, cBoundHi);
                float linCost = footprint_oklab_cost(
                    labIn, yOut, labExt, yExt, cLeft, cRight, cTop, cBot, linInit, u.coSited, m
                );
                if (linCost < bestCost) {
                    bestCost = linCost;
                    bestC = linInit;
                }

                // Neutral-protective attenuated chroma candidate (prevents bleeding into dark borders).
                float2 attenInit = clamp(
                    0.65f * cAvgIn + 0.35f * (0.5f * cLeft + 0.25f * cTop + 0.25f * cBot),
                    cBoundLo,
                    cBoundHi
                );
                float attenCost = footprint_oklab_cost(
                    labIn, yOut, labExt, yExt, cLeft, cRight, cTop, cBot, attenInit, u.coSited, m
                );
                if (attenCost < bestCost) {
                    bestCost = attenCost;
                    bestC = attenInit;
                }

                float2 cbcr = bestC;
                float yCur[4] = { yOut[0], yOut[1], yOut[2], yOut[3] };

                // 3-stage multi-scale coordinate search on (Cb, Cr) + per-pixel Y_i refinement
                // using the exact bilinear reconstruction chroma for each pixel.
                const float cSteps[3] = { 0.08f, 0.032f, 0.012f };
                const float ySteps[3] = { 0.06f, 0.025f, 0.010f };

                for (int s = 0; s < 3; ++s) {
                    float stepC = cSteps[s];
                    float2 dirs[4] = {
                        float2( stepC,  0.0f), float2(-stepC,  0.0f),
                        float2( 0.0f,  stepC), float2( 0.0f, -stepC)
                    };
                    for (int d = 0; d < 4; ++d) {
                        float2 cand = clamp(cbcr + dirs[d], cBoundLo, cBoundHi);
                        float tCost = footprint_oklab_cost(
                            labIn, yCur, labExt, yExt, cLeft, cRight, cTop, cBot, cand, u.coSited, m
                        );
                        if (tCost < bestCost) {
                            bestCost = tCost;
                            cbcr = cand;
                        }
                    }

                    // Per-pixel luma refinement under the exact interpolated chroma each pixel sees!
                    float2 cIn[4];
                    if (u.coSited != 0u) {
                        cIn[0] = 0.75f * cbcr + 0.25f * cTop;
                        cIn[1] = 0.375f * cbcr + 0.50f * cRight + 0.125f * cTop;
                        cIn[2] = 0.75f * cbcr + 0.25f * cBot;
                        cIn[3] = 0.375f * cbcr + 0.50f * cRight + 0.125f * cBot;
                    } else {
                        cIn[0] = 0.5625f * cbcr + 0.21875f * cLeft  + 0.21875f * cTop;
                        cIn[1] = 0.5625f * cbcr + 0.21875f * cRight + 0.21875f * cTop;
                        cIn[2] = 0.5625f * cbcr + 0.21875f * cLeft  + 0.21875f * cBot;
                        cIn[3] = 0.5625f * cbcr + 0.21875f * cRight + 0.21875f * cBot;
                    }

                    float stepY = ySteps[s];
                    for (int i = 0; i < 4; ++i) {
                        float baseY = yCur[i];
                        float curE = oklab_de00_proxy_sq(
                            linear_rgb_to_oklab(srgb_to_linear(clamp(ycbcr_to_rgb_raw(baseY, cIn[i].x, cIn[i].y, m), 0.0f, 1.0f))),
                            labIn[i]
                        );
                        float yHi = clamp(baseY + stepY, max(0.0f, ycc[i].x - 0.16f), min(1.0f, ycc[i].x + 0.16f));
                        float yLo = clamp(baseY - stepY, max(0.0f, ycc[i].x - 0.16f), min(1.0f, ycc[i].x + 0.16f));
                        float eHi = oklab_de00_proxy_sq(
                            linear_rgb_to_oklab(srgb_to_linear(clamp(ycbcr_to_rgb_raw(yHi, cIn[i].x, cIn[i].y, m), 0.0f, 1.0f))),
                            labIn[i]
                        );
                        float eLo = oklab_de00_proxy_sq(
                            linear_rgb_to_oklab(srgb_to_linear(clamp(ycbcr_to_rgb_raw(yLo, cIn[i].x, cIn[i].y, m), 0.0f, 1.0f))),
                            labIn[i]
                        );
                        if (eHi < curE && eHi <= eLo) {
                            yCur[i] = yHi;
                        } else if (eLo < curE) {
                            yCur[i] = yLo;
                        }
                    }

                    bestCost = footprint_oklab_cost(
                        labIn, yCur, labExt, yExt, cLeft, cRight, cTop, cBot, cbcr, u.coSited, m
                    );
                }

                cbcrOut = cbcr;
                for (int i = 0; i < 4; ++i) {
                    yOut[i] = yCur[i];
                }
            }
        }

        // Apply optional dithering to full-res luma Y (+/- 0.5 LSB) and write 4 Y samples.
        // At 10-bit P010, also apply subtle chroma dithering (+/- 0.25 LSB, < 0.15 RGB8 counts);
        // at 8-bit NV12, keep chroma undithered so temporal flicker stays strictly <= 2/255.
        for (int i = 0; i < 4; ++i) {
            uint2 p = coords[i];
            if (p.x < u.width && p.y < u.height) {
                float dy = compute_dither(p, u.ditherMode, u.frameIndex);
                float packedY = pack_luma(yOut[i], dy, u.bitDepth, u.fullRange);
                dstY.write(float4(packedY, 0.0f, 0.0f, 1.0f), p);
            }
        }

        float2 cDither = float2(0.0f);
        if (u.bitDepth >= 10u && u.ditherMode != 0u) {
            cDither = 0.5f * float2(
                compute_dither(cid, u.ditherMode, u.frameIndex),
                compute_dither(cid + uint2(17u, 31u), u.ditherMode, u.frameIndex)
            );
        }
        float2 packedUV = pack_chroma(cbcrOut, cDither, u.bitDepth, u.fullRange);
        dstUV.write(float4(packedUV.x, packedUV.y, 0.0f, 1.0f), cid);
    }

    // Kernel 3: Siting-aware bilinear YCbCr 4:2:0 -> BGRA8 GPU reconstruction kernel.
    kernel void yuv420_to_bgra8_reference(
        texture2d<float, access::read>  srcY    [[texture(0)]],
        texture2d<float, access::read>  srcUV   [[texture(1)]],
        texture2d<float, access::write> dstBGRA [[texture(2)]],
        constant ChromaKernelUniforms&  u       [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= u.width || gid.y >= u.height) {
            return;
        }

        YUVMatrix m = make_yuv_matrix(u.isBT2020);

        float rawY = srcY.read(gid).r;
        float y = unpack_luma(rawY, u.bitDepth, u.fullRange);

        // Siting-aware continuous chroma coordinates.
        float cu = (u.coSited != 0u) ? (float(gid.x) * 0.5f) : ((float(gid.x) - 0.5f) * 0.5f);
        float cv = (float(gid.y) - 0.5f) * 0.5f;

        float maxU = float(u.chromaWidth - 1u);
        float maxV = float(u.chromaHeight - 1u);
        cu = clamp(cu, 0.0f, maxU);
        cv = clamp(cv, 0.0f, maxV);

        uint u0 = uint(floor(cu));
        uint v0 = uint(floor(cv));
        uint u1 = min(u0 + 1u, u.chromaWidth - 1u);
        uint v1 = min(v0 + 1u, u.chromaHeight - 1u);
        float fu = cu - float(u0);
        float fv = cv - float(v0);

        float2 c00 = unpack_chroma(srcUV.read(uint2(u0, v0)).rg, u.bitDepth, u.fullRange);
        float2 c10 = unpack_chroma(srcUV.read(uint2(u1, v0)).rg, u.bitDepth, u.fullRange);
        float2 c01 = unpack_chroma(srcUV.read(uint2(u0, v1)).rg, u.bitDepth, u.fullRange);
        float2 c11 = unpack_chroma(srcUV.read(uint2(u1, v1)).rg, u.bitDepth, u.fullRange);

        float2 cTop = mix(c00, c10, fu);
        float2 cBot = mix(c01, c11, fu);
        float2 cbcr = mix(cTop, cBot, fv);

        float3 rgb = clamp(ycbcr_to_rgb_raw(y, cbcr.x, cbcr.y, m), 0.0f, 1.0f);
        dstBGRA.write(float4(rgb, 1.0f), gid);
    }
    """#

    // MARK: - Initialization

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device else {
            throw SafariumError.encode("MetalChromaPipeline: no Metal GPU device available")
        }
        guard let queue = device.makeCommandQueue() else {
            throw SafariumError.encode("MetalChromaPipeline: failed to create MTLCommandQueue")
        }
        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard cacheStatus == kCVReturnSuccess, let textureCache = cache else {
            throw SafariumError.encode("MetalChromaPipeline: CVMetalTextureCacheCreate failed (\(cacheStatus))")
        }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw SafariumError.encode("MetalChromaPipeline: MSL compilation failed: \(error)")
        }

        guard let f1 = library.makeFunction(name: "bgra8_to_rgba16f_linear"),
              let f2 = library.makeFunction(name: "rgba16f_to_nv12_and_p010_chroma_aware"),
              let f3 = library.makeFunction(name: "yuv420_to_bgra8_reference") else {
            throw SafariumError.encode("MetalChromaPipeline: required MSL kernel entry points missing")
        }

        do {
            self.pBGRAtoLinear = try device.makeComputePipelineState(function: f1)
            self.pLinearToYUV  = try device.makeComputePipelineState(function: f2)
            self.pYUVtoBGRA    = try device.makeComputePipelineState(function: f3)
        } catch {
            throw SafariumError.encode("MetalChromaPipeline: compute pipeline creation failed: \(error)")
        }

        self.device = device
        self.commandQueue = queue
        self.textureCache = textureCache
    }

    // MARK: - Zero-Copy GPU Conversions

    /// Converts an IOSurface-backed `32BGRA` pixel buffer into an IOSurface-backed 4:2:0 `NV12` (8-bit)
    /// or `P010` (10-bit) `CVPixelBuffer` directly on the GPU via `CVMetalTextureCache` (zero CPU copies).
    public func convertBGRAtoYUV(
        src: CVPixelBuffer,
        dst: CVPixelBuffer,
        config: ChromaConversionConfig = ChromaConversionConfig()
    ) throws {
        let width = CVPixelBufferGetWidth(src)
        let height = CVPixelBufferGetHeight(src)
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
            throw SafariumError.encode("MetalChromaPipeline: dimensions must be positive and even (got \(width)x\(height))")
        }
        guard CVPixelBufferGetWidth(dst) == width, CVPixelBufferGetHeight(dst) == height else {
            throw SafariumError.encode("MetalChromaPipeline: src/dst dimensions mismatch")
        }
        guard CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_32BGRA else {
            throw SafariumError.encode("MetalChromaPipeline: src must be kCVPixelFormatType_32BGRA")
        }

        let dstSpec = try yuvFormatSpec(for: dst, requestedBitDepth: config.bitDepth, requestedFullRange: config.fullRange)
        let chromaW = width / 2
        let chromaH = height / 2

        lock.lock()
        defer { lock.unlock() }

        let linTex = try ensureLinearTexture(width: width, height: height)

        let (cvSrc, mtlSrc) = try bindTexture(src, pixelFormat: .bgra8Unorm, width: width, height: height, planeIndex: 0)
        let (cvY, mtlY) = try bindTexture(dst, pixelFormat: dstSpec.yFormat, width: width, height: height, planeIndex: 0)
        let (cvUV, mtlUV) = try bindTexture(dst, pixelFormat: dstSpec.uvFormat, width: chromaW, height: chromaH, planeIndex: 1)

        var uniforms = ChromaKernelUniforms(
            width: UInt32(width),
            height: UInt32(height),
            chromaWidth: UInt32(chromaW),
            chromaHeight: UInt32(chromaH),
            bitDepth: UInt32(dstSpec.bitDepth),
            coSited: config.siting == .coSited ? 1 : 0,
            edgeAware: config.filterMode == .lumaGuidedEdgeAware ? 1 : 0,
            ditherMode: ditherCode(config.ditherMode),
            isBT2020: config.isBT2020 ? 1 : 0,
            fullRange: dstSpec.fullRange ? 1 : 0,
            frameIndex: config.frameIndex
        )

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let enc = cmdBuf.makeComputeCommandEncoder() else {
            throw SafariumError.encode("MetalChromaPipeline: failed to create Metal command buffer/encoder")
        }

        // Pass 1: BGRA8 -> linear-light RGBA16Float
        enc.setComputePipelineState(pBGRAtoLinear)
        enc.setTexture(mtlSrc, index: 0)
        enc.setTexture(linTex, index: 1)
        enc.setBytes(&uniforms, length: MemoryLayout<ChromaKernelUniforms>.stride, index: 0)
        dispatch2D(encoder: enc, pipeline: pBGRAtoLinear, width: width, height: height)

        // Pass 2: Deferred phase-aware luma-guided 4:4:4 -> 4:2:0 into NV12 / P010
        enc.setComputePipelineState(pLinearToYUV)
        enc.setTexture(linTex, index: 0)
        enc.setTexture(mtlY, index: 1)
        enc.setTexture(mtlUV, index: 2)
        enc.setBytes(&uniforms, length: MemoryLayout<ChromaKernelUniforms>.stride, index: 0)
        dispatch2D(encoder: enc, pipeline: pLinearToYUV, width: chromaW, height: chromaH)

        enc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        // Retain CVMetalTexture references until GPU completion.
        withExtendedLifetime((cvSrc, cvY, cvUV)) {}

        if let error = cmdBuf.error {
            throw SafariumError.encode("MetalChromaPipeline: GPU execution error: \(error)")
        }

        // Tag destination CVPixelBuffer with accurate colorimetry & chroma siting metadata.
        attachColorMetadata(to: dst, config: config)
    }

    /// Reconstructs an IOSurface-backed 4:2:0 `NV12` or `P010` `CVPixelBuffer` back to `32BGRA` on GPU
    /// using siting-aware bilinear chroma upsampling (zero CPU copies).
    public func reconstructYUVtoBGRA(
        srcYUV: CVPixelBuffer,
        dstBGRA: CVPixelBuffer,
        config: ChromaConversionConfig = ChromaConversionConfig()
    ) throws {
        let width = CVPixelBufferGetWidth(srcYUV)
        let height = CVPixelBufferGetHeight(srcYUV)
        guard width > 0, height > 0, width % 2 == 0, height % 2 == 0 else {
            throw SafariumError.encode("MetalChromaPipeline: dimensions must be positive and even")
        }
        guard CVPixelBufferGetWidth(dstBGRA) == width, CVPixelBufferGetHeight(dstBGRA) == height else {
            throw SafariumError.encode("MetalChromaPipeline: srcYUV/dstBGRA dimensions mismatch")
        }
        guard CVPixelBufferGetPixelFormatType(dstBGRA) == kCVPixelFormatType_32BGRA else {
            throw SafariumError.encode("MetalChromaPipeline: dstBGRA must be kCVPixelFormatType_32BGRA")
        }

        let srcSpec = try yuvFormatSpec(for: srcYUV, requestedBitDepth: config.bitDepth, requestedFullRange: config.fullRange)
        let chromaW = width / 2
        let chromaH = height / 2

        lock.lock()
        defer { lock.unlock() }

        let (cvY, mtlY) = try bindTexture(srcYUV, pixelFormat: srcSpec.yFormat, width: width, height: height, planeIndex: 0)
        let (cvUV, mtlUV) = try bindTexture(srcYUV, pixelFormat: srcSpec.uvFormat, width: chromaW, height: chromaH, planeIndex: 1)
        let (cvDst, mtlDst) = try bindTexture(dstBGRA, pixelFormat: .bgra8Unorm, width: width, height: height, planeIndex: 0)

        var uniforms = ChromaKernelUniforms(
            width: UInt32(width),
            height: UInt32(height),
            chromaWidth: UInt32(chromaW),
            chromaHeight: UInt32(chromaH),
            bitDepth: UInt32(srcSpec.bitDepth),
            coSited: config.siting == .coSited ? 1 : 0,
            edgeAware: config.filterMode == .lumaGuidedEdgeAware ? 1 : 0,
            ditherMode: 0,
            isBT2020: config.isBT2020 ? 1 : 0,
            fullRange: srcSpec.fullRange ? 1 : 0,
            frameIndex: config.frameIndex
        )

        guard let cmdBuf = commandQueue.makeCommandBuffer(),
              let enc = cmdBuf.makeComputeCommandEncoder() else {
            throw SafariumError.encode("MetalChromaPipeline: failed to create Metal command buffer/encoder")
        }

        enc.setComputePipelineState(pYUVtoBGRA)
        enc.setTexture(mtlY, index: 0)
        enc.setTexture(mtlUV, index: 1)
        enc.setTexture(mtlDst, index: 2)
        enc.setBytes(&uniforms, length: MemoryLayout<ChromaKernelUniforms>.stride, index: 0)
        dispatch2D(encoder: enc, pipeline: pYUVtoBGRA, width: width, height: height)

        enc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        withExtendedLifetime((cvY, cvUV, cvDst)) {}

        if let error = cmdBuf.error {
            throw SafariumError.encode("MetalChromaPipeline: reconstructYUVtoBGRA GPU error: \(error)")
        }
    }

    // MARK: - Exact Masked CIEDE2000 & Temporal Flicker Evaluators

    /// Evaluates exact Sharma-Wu-Dalal (2005) CIEDE2000 between two `32BGRA` `CVPixelBuffer`s,
    /// reporting global mean/p95/p99 plus masked `saturatedEdgeP95DeltaE00` and `textRegionP95DeltaE00`.
    public static func measureMaskedDeltaE00(
        referenceBGRA: CVPixelBuffer,
        candidateBGRA: CVPixelBuffer,
        textMask: [UInt8]? = nil
    ) throws -> ChromaDeltaEReport {
        let width = CVPixelBufferGetWidth(referenceBGRA)
        let height = CVPixelBufferGetHeight(referenceBGRA)
        guard width > 0, height > 0 else {
            throw SafariumError.encode("measureMaskedDeltaE00: empty pixel buffer")
        }
        guard CVPixelBufferGetWidth(candidateBGRA) == width,
              CVPixelBufferGetHeight(candidateBGRA) == height else {
            throw SafariumError.encode("measureMaskedDeltaE00: reference and candidate dimensions mismatch")
        }
        guard CVPixelBufferGetPixelFormatType(referenceBGRA) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetPixelFormatType(candidateBGRA) == kCVPixelFormatType_32BGRA else {
            throw SafariumError.encode("measureMaskedDeltaE00: both buffers must be kCVPixelFormatType_32BGRA")
        }
        if let mask = textMask, mask.count != width * height {
            throw SafariumError.encode("measureMaskedDeltaE00: textMask count (\(mask.count)) != width*height (\(width * height))")
        }

        CVPixelBufferLockBaseAddress(referenceBGRA, .readOnly)
        CVPixelBufferLockBaseAddress(candidateBGRA, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(candidateBGRA, .readOnly)
            CVPixelBufferUnlockBaseAddress(referenceBGRA, .readOnly)
        }

        guard let refBase = CVPixelBufferGetBaseAddress(referenceBGRA)?.assumingMemoryBound(to: UInt8.self),
              let candBase = CVPixelBufferGetBaseAddress(candidateBGRA)?.assumingMemoryBound(to: UInt8.self) else {
            throw SafariumError.encode("measureMaskedDeltaE00: null pixel buffer base address")
        }
        let refStride = CVPixelBufferGetBytesPerRow(referenceBGRA)
        let candStride = CVPixelBufferGetBytesPerRow(candidateBGRA)

        let totalPixels = width * height
        var refLab = [(L: Double, a: Double, b: Double)](repeating: (0, 0, 0), count: totalPixels)
        var allDE = [Double](repeating: 0.0, count: totalPixels)
        var deSum: Double = 0.0

        // Pass 1: Compute exact CIE L*a*b* and CIEDE2000 for every pixel.
        for y in 0..<height {
            let rRow = refBase.advanced(by: y * refStride)
            let cRow = candBase.advanced(by: y * candStride)
            let rowIdx = y * width
            for x in 0..<width {
                let off = x * 4
                let rB = Double(rRow[off]) / 255.0
                let rG = Double(rRow[off + 1]) / 255.0
                let rR = Double(rRow[off + 2]) / 255.0

                let cB = Double(cRow[off]) / 255.0
                let cG = Double(cRow[off + 1]) / 255.0
                let cR = Double(cRow[off + 2]) / 255.0

                let lab1 = srgbToLab(r: rR, g: rG, b: rB)
                let lab2 = srgbToLab(r: cR, g: cG, b: cB)
                let de = ciede2000(lab1, lab2)

                let idx = rowIdx + x
                refLab[idx] = lab1
                allDE[idx] = de
                deSum += de
            }
        }

        // Pass 2: Extract saturated-edge region and text region masks.
        var satEdgeDE: [Double] = []
        satEdgeDE.reserveCapacity(totalPixels / 8)
        var textDE: [Double] = []
        textDE.reserveCapacity(totalPixels / 8)

        for y in 0..<height {
            let yUp = max(0, y - 1)
            let yDn = min(height - 1, y + 1)
            for x in 0..<width {
                let xLt = max(0, x - 1)
                let xRt = min(width - 1, x + 1)
                let idx = y * width + x

                let c = refLab[idx]
                let nL = refLab[y * width + xLt]
                let nR = refLab[y * width + xRt]
                let nU = refLab[yUp * width + x]
                let nD = refLab[yDn * width + x]

                // Local CIE Lab gradient magnitude (detects sharp luma OR chroma transitions).
                let gradH = hypot(nR.L - nL.L, hypot(nR.a - nL.a, nR.b - nL.b))
                let gradV = hypot(nD.L - nU.L, hypot(nD.a - nU.a, nD.b - nU.b))
                let grad = hypot(gradH, gradV)

                // Max local chroma C* across the 5-tap cross (catches both stroke & immediate halo).
                let localChroma = max(
                    hypot(c.a, c.b),
                    max(
                        max(hypot(nL.a, nL.b), hypot(nR.a, nR.b)),
                        max(hypot(nU.a, nU.b), hypot(nD.a, nD.b))
                    )
                )

                if grad >= 18.0 && localChroma >= 28.0 {
                    satEdgeDE.append(allDE[idx])
                }

                if let mask = textMask {
                    if mask[idx] != 0 {
                        textDE.append(allDE[idx])
                    }
                } else if grad >= 30.0 {
                    textDE.append(allDE[idx])
                }
            }
        }

        let meanDE = deSum / Double(totalPixels)
        allDE.sort()
        let p95 = percentile(sorted: allDE, q: 0.95)
        let p99 = percentile(sorted: allDE, q: 0.99)

        satEdgeDE.sort()
        let satP95 = satEdgeDE.isEmpty ? p95 : percentile(sorted: satEdgeDE, q: 0.95)

        textDE.sort()
        let textP95 = textDE.isEmpty ? satP95 : percentile(sorted: textDE, q: 0.95)

        return ChromaDeltaEReport(
            meanDeltaE00: meanDE,
            p95DeltaE00: p95,
            p99DeltaE00: p99,
            saturatedEdgeP95DeltaE00: satP95,
            textRegionP95DeltaE00: textP95,
            maxTemporalFlicker: 0.0
        )
    }

    /// Computes maximum normalized temporal flicker (`max |c_t - c_0| / 255.0`) across a sequence
    /// of reconstructed `32BGRA` frames rendered from identical input with varying `frameIndex`.
    public static func measureTemporalFlicker(framesBGRA: [CVPixelBuffer]) throws -> Double {
        guard framesBGRA.count >= 2 else { return 0.0 }
        let base = framesBGRA[0]
        let width = CVPixelBufferGetWidth(base)
        let height = CVPixelBufferGetHeight(base)

        CVPixelBufferLockBaseAddress(base, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(base, .readOnly) }
        guard let basePtr = CVPixelBufferGetBaseAddress(base)?.assumingMemoryBound(to: UInt8.self) else {
            throw SafariumError.encode("measureTemporalFlicker: null base pixel buffer")
        }
        let baseStride = CVPixelBufferGetBytesPerRow(base)

        var maxDiff: Int = 0
        for idx in 1..<framesBGRA.count {
            let cur = framesBGRA[idx]
            guard CVPixelBufferGetWidth(cur) == width, CVPixelBufferGetHeight(cur) == height else {
                throw SafariumError.encode("measureTemporalFlicker: frame \(idx) dimension mismatch")
            }
            CVPixelBufferLockBaseAddress(cur, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(cur, .readOnly) }
            guard let curPtr = CVPixelBufferGetBaseAddress(cur)?.assumingMemoryBound(to: UInt8.self) else {
                throw SafariumError.encode("measureTemporalFlicker: null frame \(idx) pixel buffer")
            }
            let curStride = CVPixelBufferGetBytesPerRow(cur)

            for y in 0..<height {
                let rowA = basePtr.advanced(by: y * baseStride)
                let rowB = curPtr.advanced(by: y * curStride)
                for x in 0..<width {
                    let off = x * 4
                    let dB = abs(Int(rowA[off]) - Int(rowB[off]))
                    let dG = abs(Int(rowA[off + 1]) - Int(rowB[off + 1]))
                    let dR = abs(Int(rowA[off + 2]) - Int(rowB[off + 2]))
                    let m = max(dB, max(dG, dR))
                    if m > maxDiff { maxDiff = m }
                }
            }
        }

        return Double(maxDiff) / 255.0
    }

    // MARK: - Private Helpers

    private struct YUVFormatSpec {
        let bitDepth: Int
        let fullRange: Bool
        let yFormat: MTLPixelFormat
        let uvFormat: MTLPixelFormat
    }

    private func yuvFormatSpec(
        for buffer: CVPixelBuffer,
        requestedBitDepth: Int,
        requestedFullRange: Bool
    ) throws -> YUVFormatSpec {
        let fmt = CVPixelBufferGetPixelFormatType(buffer)
        switch fmt {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            return YUVFormatSpec(bitDepth: 10, fullRange: false, yFormat: .r16Unorm, uvFormat: .rg16Unorm)
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return YUVFormatSpec(bitDepth: 10, fullRange: true, yFormat: .r16Unorm, uvFormat: .rg16Unorm)
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return YUVFormatSpec(bitDepth: 8, fullRange: false, yFormat: .r8Unorm, uvFormat: .rg8Unorm)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return YUVFormatSpec(bitDepth: 8, fullRange: true, yFormat: .r8Unorm, uvFormat: .rg8Unorm)
        default:
            _ = (requestedBitDepth, requestedFullRange)
            throw SafariumError.encode("MetalChromaPipeline: unsupported YUV pixel format FourCC 0x\(String(fmt, radix: 16)) (expected NV12 or P010)")
        }
    }

    private func ditherCode(_ mode: DitherMode) -> UInt32 {
        switch mode {
        case .none: return 0
        case .bayer4x4: return 1
        case .temporalInterleavedGradient: return 2
        }
    }

    private func ensureLinearTexture(width: Int, height: Int) throws -> MTLTexture {
        if let existing = linearTexture, cachedWidth == width, cachedHeight == height {
            return existing
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw SafariumError.encode("MetalChromaPipeline: failed to allocate private RGBA16Float texture (\(width)x\(height))")
        }
        self.linearTexture = tex
        self.cachedWidth = width
        self.cachedHeight = height
        return tex
    }

    private func bindTexture(
        _ pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        planeIndex: Int
    ) throws -> (CVMetalTexture, MTLTexture) {
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            planeIndex,
            &cvTex
        )
        guard status == kCVReturnSuccess, let cvTex, let mtlTex = CVMetalTextureGetTexture(cvTex) else {
            throw SafariumError.encode("MetalChromaPipeline: CVMetalTextureCacheCreateTextureFromImage failed (status=\(status), plane=\(planeIndex), \(width)x\(height))")
        }
        return (cvTex, mtlTex)
    }

    private func dispatch2D(
        encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let tgW = min(16, max(1, pipeline.threadExecutionWidth))
        let tgH = min(16, max(1, pipeline.maxTotalThreadsPerThreadgroup / tgW))
        let threadsPerGroup = MTLSize(width: tgW, height: tgH, depth: 1)
        let gridSize = MTLSize(width: width, height: height, depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
    }

    private func attachColorMetadata(to buffer: CVPixelBuffer, config: ChromaConversionConfig) {
        if config.isBT2020 {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        } else {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        }
        let sitingTag: CFString = (config.siting == .coSited)
            ? kCVImageBufferChromaLocation_Left
            : kCVImageBufferChromaLocation_Center
        CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey, sitingTag, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationBottomFieldKey, sitingTag, .shouldPropagate)
    }

    // MARK: - Exact CIEDE2000 Mathematics (Sharma, Wu, Dalal 2005)

    @inline(__always)
    private static func srgbChannelToLinear(_ v: Double) -> Double {
        (v <= 0.04045) ? (v / 12.92) : pow((v + 0.055) / 1.055, 2.4)
    }

    @inline(__always)
    private static func labF(_ t: Double) -> Double {
        let delta = 6.0 / 29.0
        let delta3 = delta * delta * delta
        return (t > delta3) ? cbrt(t) : (t / (3.0 * delta * delta) + 4.0 / 29.0)
    }

    @inline(__always)
    private static func srgbToLab(r: Double, g: Double, b: Double) -> (L: Double, a: Double, b: Double) {
        let rl = srgbChannelToLinear(r)
        let gl = srgbChannelToLinear(g)
        let bl = srgbChannelToLinear(b)

        // sRGB (D65) -> CIE XYZ normalized by D65 white point (0.95047, 1.00000, 1.08883).
        let x = (0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl) / 0.95047
        let y = (0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl) / 1.00000
        let z = (0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl) / 1.08883

        let fx = labF(x)
        let fy = labF(y)
        let fz = labF(z)

        return (
            L: 116.0 * fy - 16.0,
            a: 500.0 * (fx - fy),
            b: 200.0 * (fy - fz)
        )
    }

    @inline(__always)
    private static func ciede2000(
        _ p1: (L: Double, a: Double, b: Double),
        _ p2: (L: Double, a: Double, b: Double)
    ) -> Double {
        let L1 = p1.L, a1 = p1.a, b1 = p1.b
        let L2 = p2.L, a2 = p2.a, b2 = p2.b

        let C1 = hypot(a1, b1)
        let C2 = hypot(a2, b2)
        let barC = 0.5 * (C1 + C2)
        let barC7 = pow(barC, 7.0)
        let pow25_7 = 6103515625.0 // 25^7
        let G = 0.5 * (1.0 - sqrt(barC7 / (barC7 + pow25_7)))

        let a1p = (1.0 + G) * a1
        let a2p = (1.0 + G) * a2
        let C1p = hypot(a1p, b1)
        let C2p = hypot(a2p, b2)

        let rad2deg = 180.0 / Double.pi
        let deg2rad = Double.pi / 180.0

        func huePrime(_ ap: Double, _ b: Double) -> Double {
            if abs(ap) < 1e-12 && abs(b) < 1e-12 { return 0.0 }
            var h = atan2(b, ap) * rad2deg
            if h < 0.0 { h += 360.0 }
            return h
        }

        let h1p = huePrime(a1p, b1)
        let h2p = huePrime(a2p, b2)

        let dLp = L2 - L1
        let dCp = C2p - C1p

        let C1pC2p = C1p * C2p
        let dhp: Double
        if C1pC2p == 0.0 {
            dhp = 0.0
        } else {
            let diff = h2p - h1p
            if abs(diff) <= 180.0 {
                dhp = diff
            } else if diff > 180.0 {
                dhp = diff - 360.0
            } else {
                dhp = diff + 360.0
            }
        }

        let dHp = 2.0 * sqrt(C1pC2p) * sin(0.5 * dhp * deg2rad)

        let barLp = 0.5 * (L1 + L2)
        let barCp = 0.5 * (C1p + C2p)

        let barHp: Double
        if C1pC2p == 0.0 {
            barHp = h1p + h2p
        } else if abs(h1p - h2p) <= 180.0 {
            barHp = 0.5 * (h1p + h2p)
        } else if (h1p + h2p) < 360.0 {
            barHp = 0.5 * (h1p + h2p + 360.0)
        } else {
            barHp = 0.5 * (h1p + h2p - 360.0)
        }

        let T = 1.0
            - 0.17 * cos((barHp - 30.0) * deg2rad)
            + 0.24 * cos((2.0 * barHp) * deg2rad)
            + 0.32 * cos((3.0 * barHp + 6.0) * deg2rad)
            - 0.20 * cos((4.0 * barHp - 63.0) * deg2rad)

        let dTheta = 30.0 * exp(-pow((barHp - 275.0) / 25.0, 2.0))
        let barCp7 = pow(barCp, 7.0)
        let RC = 2.0 * sqrt(barCp7 / (barCp7 + pow25_7))
        let lp50 = barLp - 50.0
        let SL = 1.0 + (0.015 * lp50 * lp50) / sqrt(20.0 + lp50 * lp50)
        let SC = 1.0 + 0.045 * barCp
        let SH = 1.0 + 0.015 * barCp * T
        let RT = -sin(2.0 * dTheta * deg2rad) * RC

        let tL = dLp / SL
        let tC = dCp / SC
        let tH = dHp / SH

        return sqrt(max(0.0, tL * tL + tC * tC + tH * tH + RT * tC * tH))
    }

    private static func percentile(sorted: [Double], q: Double) -> Double {
        guard !sorted.isEmpty else { return 0.0 }
        let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * q).rounded())))
        return sorted[idx]
    }
}
