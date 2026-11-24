import Accelerate
import AVFoundation
import CoreGraphics
import CoreImage
import CoreML
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import Metal
import SafariumCore
import Vision

// MARK: - Vision ANE Compute Device Helper

public enum ForgeVisionANE {
    public static func preferANE(for request: VNRequest) -> Bool {
        guard let stageDevices = try? request.supportedComputeStageDevices else {
            return false
        }
        var foundANE = false
        for (stage, devices) in stageDevices {
            if let ane = devices.first(where: { if case .neuralEngine = $0 { return true }; return false }) {
                request.setComputeDevice(ane, for: stage)
                foundANE = true
            } else if let gpu = devices.first(where: { if case .gpu = $0 { return true }; return false }) {
                request.setComputeDevice(gpu, for: stage)
            }
        }
        return foundANE
    }

    public static func preferANEAndGPU(for request: VNRequest) -> Bool {
        guard let stageDevices = try? request.supportedComputeStageDevices else {
            return false
        }
        var foundHW = false
        for (stage, devices) in stageDevices {
            if let ane = devices.first(where: { if case .neuralEngine = $0 { return true }; return false }) {
                request.setComputeDevice(ane, for: stage)
                foundHW = true
            } else if let gpu = devices.first(where: { if case .gpu = $0 { return true }; return false }) {
                request.setComputeDevice(gpu, for: stage)
                foundHW = true
            }
        }
        return foundHW
    }
}

// MARK: - SafariumPQ (ANE FeaturePrint Rev2 + Metal 5-scale MS-SSIM + Metal Sharma-2005 CIEDE2000 + Thai OCR)

public struct SafariumPQReport: Codable, Sendable {
    public let score0To100: Double
    public let msSSIM: Double
    public let aneFeatureDistance: Double
    public let deltaE00Mean: Double
    public let deltaE00P95: Double
    public let thaiOCROK: Bool
    public let sampledFrames: Int
    public let aneDeviceActive: Bool
    public let wallMs: Double
    public let passed: Bool
    public let notes: [String]
}

public final class SafariumPQEngine {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let textureCache: CVMetalTextureCache

    private let pLuma: MTLComputePipelineState
    private let pDown: MTLComputePipelineState
    private let pHoriz: MTLComputePipelineState
    private let pVert: MTLComputePipelineState
    private let pDE00: MTLComputePipelineState

    private var cachedW = 0
    private var cachedH = 0
    private var lumaA: [MTLTexture] = []
    private var lumaB: [MTLTexture] = []
    private var momTex: [MTLTexture] = []
    private var crossTex: [MTLTexture] = []
    private var sumLumaBuf: [MTLBuffer] = []
    private var sumCSBuf: [MTLBuffer] = []
    private var deBuf: MTLBuffer?

    private static let shaderSource: String = #"""
    #include <metal_stdlib>
    using namespace metal;

    constant float kGauss11[11] = {
        0.001028f, 0.007599f, 0.036001f, 0.109360f, 0.213006f, 0.266012f,
        0.213006f, 0.109360f, 0.036001f, 0.007599f, 0.001028f
    };

    kernel void bgraToLumaPair(
        texture2d<float, access::read> texA [[texture(0)]],
        texture2d<float, access::read> texB [[texture(1)]],
        texture2d<float, access::write> outA [[texture(2)]],
        texture2d<float, access::write> outB [[texture(3)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= outA.get_width() || gid.y >= outA.get_height()) return;
        float4 a = texA.read(gid);
        float4 b = texB.read(gid);
        float ya = dot(a.rgb, float3(0.2126f, 0.7152f, 0.0722f));
        float yb = dot(b.rgb, float3(0.2126f, 0.7152f, 0.0722f));
        outA.write(float4(ya, 0, 0, 1), gid);
        outB.write(float4(yb, 0, 0, 1), gid);
    }

    kernel void downsample2xPair(
        texture2d<float, access::read> inA [[texture(0)]],
        texture2d<float, access::read> inB [[texture(1)]],
        texture2d<float, access::write> outA [[texture(2)]],
        texture2d<float, access::write> outB [[texture(3)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint w = outA.get_width(), h = outA.get_height();
        if (gid.x >= w || gid.y >= h) return;
        uint2 p = gid * 2;
        uint maxX = inA.get_width() - 1, maxY = inA.get_height() - 1;
        uint2 p00 = uint2(min(p.x, maxX), min(p.y, maxY));
        uint2 p10 = uint2(min(p.x + 1, maxX), min(p.y, maxY));
        uint2 p01 = uint2(min(p.x, maxX), min(p.y + 1, maxY));
        uint2 p11 = uint2(min(p.x + 1, maxX), min(p.y + 1, maxY));
        float a = 0.25f * (inA.read(p00).r + inA.read(p10).r + inA.read(p01).r + inA.read(p11).r);
        float b = 0.25f * (inB.read(p00).r + inB.read(p10).r + inB.read(p01).r + inB.read(p11).r);
        outA.write(float4(a, 0, 0, 1), gid);
        outB.write(float4(b, 0, 0, 1), gid);
    }

    kernel void ssimHoriz(
        texture2d<float, access::read> inA [[texture(0)]],
        texture2d<float, access::read> inB [[texture(1)]],
        texture2d<float, access::write> outMoments [[texture(2)]],
        texture2d<float, access::write> outCross [[texture(3)]],
        uint2 gid [[thread_position_in_grid]])
    {
        int w = int(inA.get_width()), h = int(inA.get_height());
        if (int(gid.x) >= w || int(gid.y) >= h) return;
        float ma = 0, mb = 0, ma2 = 0, mb2 = 0, mab = 0;
        for (int k = -5; k <= 5; k++) {
            int sx = clamp(int(gid.x) + k, 0, w - 1);
            float wt = kGauss11[k + 5];
            float a = inA.read(uint2(sx, gid.y)).r;
            float b = inB.read(uint2(sx, gid.y)).r;
            ma  += wt * a;
            mb  += wt * b;
            ma2 += wt * (a * a);
            mb2 += wt * (b * b);
            mab += wt * (a * b);
        }
        outMoments.write(float4(ma, mb, ma2, mb2), gid);
        outCross.write(float4(mab, 0, 0, 1), gid);
    }

    kernel void ssimVert(
        texture2d<float, access::read> inMoments [[texture(0)]],
        texture2d<float, access::read> inCross [[texture(1)]],
        device float* outLumaSum [[buffer(0)]],
        device float* outCSSum [[buffer(1)]],
        constant uint& outWidth [[buffer(2)]],
        constant uint& outHeight [[buffer(3)]],
        uint2 gid [[thread_position_in_grid]],
        uint tid [[thread_index_in_threadgroup]],
        uint2 tgid [[threadgroup_position_in_grid]])
    {
        threadgroup float tgL[256];
        threadgroup float tgCS[256];
        float lVal = 0.0f, csVal = 0.0f;
        if (gid.x < outWidth && gid.y < outHeight) {
            int h = int(outHeight);
            float4 mom = float4(0.0f);
            float mab = 0.0f;
            for (int k = -5; k <= 5; k++) {
                int sy = clamp(int(gid.y) + k, 0, h - 1);
                float wt = kGauss11[k + 5];
                mom += wt * inMoments.read(uint2(gid.x, sy));
                mab += wt * inCross.read(uint2(gid.x, sy)).r;
            }
            float muA = mom.x, muB = mom.y;
            float varA = max(0.0f, mom.z - muA * muA);
            float varB = max(0.0f, mom.w - muB * muB);
            float cov  = mab - muA * muB;
            constexpr float C1 = 0.01f * 0.01f;
            constexpr float C2 = 0.03f * 0.03f;
            float lumaTerm = (2.0f * muA * muB + C1) / (muA * muA + muB * muB + C1);
            float csTerm   = (2.0f * cov + C2) / (varA + varB + C2);
            lVal = lumaTerm * csTerm;
            csVal = max(0.0f, csTerm);
        }
        tgL[tid] = lVal;
        tgCS[tid] = csVal;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint s = 128; s > 0; s >>= 1) {
            if (tid < s) {
                tgL[tid] += tgL[tid + s];
                tgCS[tid] += tgCS[tid + s];
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (tid == 0) {
            uint numGroupsX = (outWidth + 15) / 16;
            uint gIdx = tgid.y * numGroupsX + tgid.x;
            outLumaSum[gIdx] = tgL[0];
            outCSSum[gIdx] = tgCS[0];
        }
    }

    inline float srgbToLinear(float c) {
        return (c <= 0.04045f) ? (c / 12.92f) : pow((c + 0.055f) / 1.055f, 2.4f);
    }
    inline float labF(float t) {
        return (t > 0.008856451679f) ? pow(t, 1.0f / 3.0f) : (7.787037037f * t + 16.0f / 116.0f);
    }
    inline float3 rgbToLab(float3 rgb) {
        float r = srgbToLinear(rgb.r), g = srgbToLinear(rgb.g), b = srgbToLinear(rgb.b);
        float X = (0.4124564f * r + 0.3575761f * g + 0.1804375f * b) / 0.95047f;
        float Y = (0.2126729f * r + 0.7151522f * g + 0.0721750f * b);
        float Z = (0.0193339f * r + 0.1191920f * g + 0.9503041f * b) / 1.08883f;
        float fx = labF(X), fy = labF(Y), fz = labF(Z);
        return float3(116.0f * fy - 16.0f, 500.0f * (fx - fy), 200.0f * (fy - fz));
    }

    kernel void deltaE2000Kernel(
        texture2d<float, access::read> texA [[texture(0)]],
        texture2d<float, access::read> texB [[texture(1)]],
        device float* outDE [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        uint w = texA.get_width(), h = texA.get_height();
        if (gid.x >= w || gid.y >= h) return;
        float3 lab1 = rgbToLab(texA.read(gid).rgb);
        float3 lab2 = rgbToLab(texB.read(gid).rgb);

        float L1 = lab1.x, a1 = lab1.y, b1 = lab1.z;
        float L2 = lab2.x, a2 = lab2.y, b2 = lab2.z;

        float C1 = sqrt(a1 * a1 + b1 * b1);
        float C2 = sqrt(a2 * a2 + b2 * b2);
        float Cbar = 0.5f * (C1 + C2);
        float Cbar7 = pow(Cbar, 7.0f);
        constexpr float p25_7 = 6103515625.0f;
        float G = 0.5f * (1.0f - sqrt(Cbar7 / (Cbar7 + p25_7)));
        float ap1 = (1.0f + G) * a1;
        float ap2 = (1.0f + G) * a2;
        float Cp1 = sqrt(ap1 * ap1 + b1 * b1);
        float Cp2 = sqrt(ap2 * ap2 + b2 * b2);

        constexpr float rad2deg = 180.0f / M_PI_F;
        constexpr float deg2rad = M_PI_F / 180.0f;

        float hp1 = (Cp1 < 1e-6f) ? 0.0f : fmod(atan2(b1, ap1) * rad2deg + 360.0f, 360.0f);
        float hp2 = (Cp2 < 1e-6f) ? 0.0f : fmod(atan2(b2, ap2) * rad2deg + 360.0f, 360.0f);

        float dLp = L2 - L1;
        float dCp = Cp2 - Cp1;

        float dhp = 0.0f;
        if (Cp1 * Cp2 >= 1e-6f) {
            float diff = hp2 - hp1;
            if (abs(diff) <= 180.0f) dhp = diff;
            else if (diff > 180.0f) dhp = diff - 360.0f;
            else dhp = diff + 360.0f;
        }
        float dHp = 2.0f * sqrt(Cp1 * Cp2) * sin(0.5f * dhp * deg2rad);

        float Lbarp = 0.5f * (L1 + L2);
        float Cbarp = 0.5f * (Cp1 + Cp2);
        float hbarp = hp1 + hp2;
        if (Cp1 * Cp2 >= 1e-6f) {
            if (abs(hp1 - hp2) <= 180.0f) hbarp = 0.5f * (hp1 + hp2);
            else if ((hp1 + hp2) < 360.0f) hbarp = 0.5f * (hp1 + hp2 + 360.0f);
            else hbarp = 0.5f * (hp1 + hp2 - 360.0f);
        }

        float T = 1.0f
            - 0.17f * cos((hbarp - 30.0f) * deg2rad)
            + 0.24f * cos((2.0f * hbarp) * deg2rad)
            + 0.32f * cos((3.0f * hbarp + 6.0f) * deg2rad)
            - 0.20f * cos((4.0f * hbarp - 63.0f) * deg2rad);
        float dTheta = 30.0f * exp(-pow((hbarp - 275.0f) / 25.0f, 2.0f));
        float Cbarp7 = pow(Cbarp, 7.0f);
        float RC = 2.0f * sqrt(Cbarp7 / (Cbarp7 + p25_7));
        float L50 = (Lbarp - 50.0f);
        float SL = 1.0f + (0.015f * L50 * L50) / sqrt(20.0f + L50 * L50);
        float SC = 1.0f + 0.045f * Cbarp;
        float SH = 1.0f + 0.015f * Cbarp * T;
        float RT = -sin(2.0f * dTheta * deg2rad) * RC;

        float tL = dLp / SL, tC = dCp / SC, tH = dHp / SH;
        float de00 = sqrt(max(0.0f, tL * tL + tC * tC + tH * tH + RT * tC * tH));
        outDE[gid.y * w + gid.x] = de00;
    }
    """#

    public init() throws {
        guard let ctx = SafariumMetalContext.shared else {
            throw SafariumError.encode("Metal context unavailable for SafariumPQ")
        }
        let dev = ctx.device
        self.device = dev
        self.commandQueue = ctx.commandQueue
        self.textureCache = ctx.textureCache
        let lib = try dev.makeLibrary(source: Self.shaderSource, options: nil)
        func mk(_ name: String) throws -> MTLComputePipelineState {
            guard let fn = lib.makeFunction(name: name) else {
                throw SafariumError.encode("missing SafariumPQ Metal kernel '\(name)'")
            }
            return try dev.makeComputePipelineState(function: fn)
        }
        self.pLuma = try mk("bgraToLumaPair")
        self.pDown = try mk("downsample2xPair")
        self.pHoriz = try mk("ssimHoriz")
        self.pVert = try mk("ssimVert")
        self.pDE00 = try mk("deltaE2000Kernel")
    }

    private func ensureResources(width: Int, height: Int) throws {
        if cachedW == width && cachedH == height && deBuf != nil { return }
        lumaA.removeAll(); lumaB.removeAll(); momTex.removeAll(); crossTex.removeAll()
        sumLumaBuf.removeAll(); sumCSBuf.removeAll()

        var cw = width, ch = height
        for _ in 0..<5 {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: cw, height: ch, mipmapped: false)
            td.usage = [.shaderRead, .shaderWrite]
            td.storageMode = .private
            guard let la = device.makeTexture(descriptor: td),
                  let lb = device.makeTexture(descriptor: td),
                  let cx = device.makeTexture(descriptor: td) else {
                throw SafariumError.encode("SafariumPQ pyramid alloc failed")
            }
            lumaA.append(la); lumaB.append(lb); crossTex.append(cx)

            let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: cw, height: ch, mipmapped: false)
            md.usage = [.shaderRead, .shaderWrite]
            md.storageMode = .private
            guard let mt = device.makeTexture(descriptor: md) else {
                throw SafariumError.encode("SafariumPQ moments alloc failed")
            }
            momTex.append(mt)

            let ng = ((cw + 15) / 16) * ((ch + 15) / 16)
            guard let sbL = device.makeBuffer(length: max(1, ng) * 4, options: .storageModeShared),
                  let sbC = device.makeBuffer(length: max(1, ng) * 4, options: .storageModeShared) else {
                throw SafariumError.encode("SafariumPQ sum buffer alloc failed")
            }
            sumLumaBuf.append(sbL); sumCSBuf.append(sbC)
            cw = max(1, cw / 2); ch = max(1, ch / 2)
        }
        guard let deb = device.makeBuffer(length: max(1, width * height) * 4, options: .storageModeShared) else {
            throw SafariumError.encode("SafariumPQ dE00 buffer alloc failed")
        }
        deBuf = deb
        cachedW = width
        cachedH = height
    }

    private func computeMetalMetrics(texA: MTLTexture, texB: MTLTexture) throws -> (mssim: Double, deMean: Double, deP95: Double) {
        let w = texA.width, h = texA.height
        guard texB.width == w, texB.height == h else {
            throw SafariumError.invalidState("SafariumPQ frame dimensions mismatch: \(w)x\(h) vs \(texB.width)x\(texB.height)")
        }
        try ensureResources(width: w, height: h)
        guard let deBuf else { throw SafariumError.encode("SafariumPQ dE00 buffer missing") }
        guard let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else {
            throw SafariumError.encode("SafariumPQ Metal command buffer creation failed")
        }
        let tg = MTLSize(width: 16, height: 16, depth: 1)

        enc.setComputePipelineState(pLuma)
        enc.setTexture(texA, index: 0); enc.setTexture(texB, index: 1)
        enc.setTexture(lumaA[0], index: 2); enc.setTexture(lumaB[0], index: 3)
        enc.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
        enc.memoryBarrier(scope: .textures)

        var cw = w, ch = h
        for s in 0..<5 {
            if s > 0 {
                enc.setComputePipelineState(pDown)
                enc.setTexture(lumaA[s - 1], index: 0); enc.setTexture(lumaB[s - 1], index: 1)
                enc.setTexture(lumaA[s], index: 2); enc.setTexture(lumaB[s], index: 3)
                enc.dispatchThreadgroups(MTLSize(width: (cw + 15) / 16, height: (ch + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
                enc.memoryBarrier(scope: .textures)
            }
            enc.setComputePipelineState(pHoriz)
            enc.setTexture(lumaA[s], index: 0); enc.setTexture(lumaB[s], index: 1)
            enc.setTexture(momTex[s], index: 2); enc.setTexture(crossTex[s], index: 3)
            enc.dispatchThreadgroups(MTLSize(width: (cw + 15) / 16, height: (ch + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
            enc.memoryBarrier(scope: .textures)

            enc.setComputePipelineState(pVert)
            enc.setTexture(momTex[s], index: 0); enc.setTexture(crossTex[s], index: 1)
            enc.setBuffer(sumLumaBuf[s], offset: 0, index: 0)
            enc.setBuffer(sumCSBuf[s], offset: 0, index: 1)
            var uw = UInt32(cw), uh = UInt32(ch)
            enc.setBytes(&uw, length: 4, index: 2)
            enc.setBytes(&uh, length: 4, index: 3)
            enc.dispatchThreadgroups(MTLSize(width: (cw + 15) / 16, height: (ch + 15) / 16, depth: 1), threadsPerThreadgroup: tg)

            cw = max(1, cw / 2); ch = max(1, ch / 2)
        }

        enc.setComputePipelineState(pDE00)
        enc.setTexture(texA, index: 0); enc.setTexture(texB, index: 1)
        enc.setBuffer(deBuf, offset: 0, index: 0)
        enc.dispatchThreadgroups(MTLSize(width: (w + 15) / 16, height: (h + 15) / 16, depth: 1), threadsPerThreadgroup: tg)
        enc.endEncoding()

        cmd.commit()
        cmd.waitUntilCompleted()
        CVMetalTextureCacheFlush(textureCache, 0)
        if let err = cmd.error {
            throw SafariumError.encode("SafariumPQ Metal execution failed: \(err)")
        }

        let weights = [0.0448, 0.2856, 0.3001, 0.2363, 0.1333]
        var mssim = 1.0
        cw = w; ch = h
        for s in 0..<5 {
            let nPx = Double(cw * ch)
            let ng = ((cw + 15) / 16) * ((ch + 15) / 16)
            let lPtr = sumLumaBuf[s].contents().bindMemory(to: Float.self, capacity: ng)
            let cPtr = sumCSBuf[s].contents().bindMemory(to: Float.self, capacity: ng)
            var lSum = 0.0, cSum = 0.0
            for i in 0..<ng {
                lSum += Double(lPtr[i])
                cSum += Double(cPtr[i])
            }
            let csMean = max(1e-9, min(1.0, cSum / nPx))
            if s < 4 {
                mssim *= pow(csMean, weights[s])
            } else {
                let ssimMean = max(1e-9, min(1.0, lSum / nPx))
                mssim *= pow(ssimMean, weights[s])
            }
            cw = max(1, cw / 2); ch = max(1, ch / 2)
        }

        let n = w * h
        let dePtr = deBuf.contents().bindMemory(to: Float.self, capacity: n)
        var sumDE = 0.0
        var bins = [Int](repeating: 0, count: 20_002)
        for i in 0..<n {
            let v = dePtr[i]
            sumDE += Double(v)
            let idx = min(20_001, max(0, Int(v * 500.0)))
            bins[idx] += 1
        }
        let target = Int(Double(n) * 0.95)
        var cum = 0
        var p95 = 0.0
        for b in 0..<bins.count {
            cum += bins[b]
            if cum >= target {
                p95 = Double(b) / 500.0
                break
            }
        }
        return (mssim, sumDE / Double(n), p95)
    }

    private func featurePrint(for pb: CVPixelBuffer) throws -> (obs: VNFeaturePrintObservation, aneActive: Bool) {
        let req = VNGenerateImageFeaturePrintRequest()
        req.revision = VNGenerateImageFeaturePrintRequestRevision2
        let ane = ForgeVisionANE.preferANE(for: req)
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, options: [:])
        try handler.perform([req])
        guard let obs = req.results?.first as? VNFeaturePrintObservation else {
            throw SafariumError.snapshot("VNGenerateImageFeaturePrintRequest returned no observation")
        }
        return (obs, ane)
    }

    private func recognizeText(in pb: CVPixelBuffer) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["th-TH", "en-US"]
        req.usesLanguageCorrection = false
        _ = ForgeVisionANE.preferANEAndGPU(for: req)
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, options: [:])
        try handler.perform([req])
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n").precomposedStringWithCanonicalMapping
    }

    private static func normalizeOCRText(_ s: String) -> String {
        let scalars = s.precomposedStringWithCanonicalMapping.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func containsThai(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.value >= 0x0E00 && $0.value <= 0x0E7F }
    }

    public static func calibratedScore0To100(
        msSSIM: Double,
        aneFeatureDistance: Double,
        deltaE00Mean: Double,
        deltaE00P95: Double
    ) -> Double {
        let ssimTerm = pow(max(0.0, min(1.0, msSSIM)), 6.0)
        let aneTerm = exp(-1.1 * max(0.0, aneFeatureDistance))
        let colorTerm = exp(-0.10 * max(0.0, deltaE00P95) - 0.10 * max(0.0, deltaE00Mean))
        let raw = 100.0 * (0.45 * ssimTerm + 0.30 * aneTerm + 0.25 * colorTerm)
        return max(0.0, min(100.0, raw))
    }

    public func evaluatePair(
        reference referencePB: CVPixelBuffer,
        candidate candidatePB: CVPixelBuffer,
        checkThaiOCR: Bool = false,
        expectedThaiText: String? = nil,
        minScore: Double = 85.0,
        maxDeltaE00P95: Double = 2.0,
        minMSSSIM: Double = 0.97
    ) throws -> SafariumPQReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard let ctx = SafariumMetalContext.shared else {
            throw SafariumError.encode("SafariumMetalContext.shared unavailable")
        }
        let (refCV, refTex) = try ctx.bindBGRA8Texture(for: referencePB)
        let (candCV, candTex) = try ctx.bindBGRA8Texture(for: candidatePB)
        let (mssim, deMean, deP95) = try computeMetalMetrics(texA: refTex, texB: candTex)
        _ = (refCV, candCV)

        let (refFP, ane1) = try featurePrint(for: referencePB)
        let (candFP, ane2) = try featurePrint(for: candidatePB)
        var aneDist: Float = 0
        try refFP.computeDistance(&aneDist, to: candFP)

        var notes: [String] = []
        var thaiOK = true
        if checkThaiOCR || expectedThaiText != nil {
            let candText = try recognizeText(in: candidatePB)
            let candNorm = Self.normalizeOCRText(candText)
            if let exp = expectedThaiText {
                let expNorm = Self.normalizeOCRText(exp)
                if !expNorm.isEmpty && !candNorm.contains(expNorm) {
                    thaiOK = false
                    notes.append("Thai OCR missing expected '\(exp)' (got '\(candText)')")
                }
            } else {
                let refText = try recognizeText(in: referencePB)
                let refNorm = Self.normalizeOCRText(refText)
                if Self.containsThai(refNorm) && candNorm != refNorm {
                    // Check every Thai token from reference is preserved cleanly
                    let refTokens = refText.split(whereSeparator: \.isWhitespace).map { Self.normalizeOCRText(String($0)) }.filter { Self.containsThai($0) }
                    for tok in refTokens where !candNorm.contains(tok) {
                        thaiOK = false
                        notes.append("Thai OCR mismatch for token '\(tok)' (cand='\(candText)')")
                        break
                    }
                }
            }
        }

        let score = Self.calibratedScore0To100(
            msSSIM: mssim,
            aneFeatureDistance: Double(aneDist),
            deltaE00Mean: deMean,
            deltaE00P95: deP95
        )
        let passed = (score >= minScore) && (mssim >= minMSSSIM) && (deP95 <= maxDeltaE00P95) && thaiOK
        if deP95 > maxDeltaE00P95 { notes.append(String(format: "deltaE00P95 %.3f > %.3f", deP95, maxDeltaE00P95)) }
        if mssim < minMSSSIM { notes.append(String(format: "msSSIM %.5f < %.5f", mssim, minMSSSIM)) }
        if score < minScore { notes.append(String(format: "score %.2f < %.2f", score, minScore)) }

        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return SafariumPQReport(
            score0To100: score,
            msSSIM: mssim,
            aneFeatureDistance: Double(aneDist),
            deltaE00Mean: deMean,
            deltaE00P95: deP95,
            thaiOCROK: thaiOK,
            sampledFrames: 1,
            aneDeviceActive: ane1 && ane2,
            wallMs: ms,
            passed: passed,
            notes: notes
        )
    }

    public func evaluatePair(
        referenceCG: CGImage,
        candidateCG: CGImage,
        checkThaiOCR: Bool = false,
        expectedThaiText: String? = nil,
        minScore: Double = 85.0,
        maxDeltaE00P95: Double = 2.0,
        minMSSSIM: Double = 0.97
    ) throws -> SafariumPQReport {
        let w = referenceCG.width, h = referenceCG.height
        let refPB = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: w, height: h, pixelFormat: .bgra)
        let candPB = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: w, height: h, pixelFormat: .bgra)
        try Snapshot(cgImage: referenceCG).draw(into: refPB, width: w, height: h)
        try Snapshot(cgImage: candidateCG).draw(into: candPB, width: w, height: h)
        return try evaluatePair(
            reference: refPB,
            candidate: candPB,
            checkThaiOCR: checkThaiOCR,
            expectedThaiText: expectedThaiText,
            minScore: minScore,
            maxDeltaE00P95: maxDeltaE00P95,
            minMSSSIM: minMSSSIM
        )
    }
}

public enum SafariumPQ {
    public static func compareVideos(
        referenceURL: URL,
        candidateURL: URL,
        maxSamples: Int = 12,
        checkThaiOCR: Bool = false,
        expectedThaiText: String? = nil,
        minScore: Double = 85.0,
        maxDeltaE00P95: Double = 2.0,
        minMSSSIM: Double = 0.97,
        engine precompiledEngine: SafariumPQEngine? = nil
    ) async throws -> SafariumPQReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(referenceURL)
        try SafeFilePublisher.assertRegularReadableFile(candidateURL)
        let engine = try precompiledEngine ?? SafariumPQEngine()

        let refReader = try await SafariumSequentialVideoReader(url: referenceURL, loop: false, pixelFormat: kCVPixelFormatType_32BGRA)
        let candReader = try await SafariumSequentialVideoReader(url: candidateURL, loop: false, pixelFormat: kCVPixelFormatType_32BGRA)
        defer {
            refReader.close()
            candReader.close()
        }

        let minDur = min(refReader.durationSeconds, candReader.durationSeconds)
        let sampleCount = max(1, min(maxSamples, Int((minDur * min(refReader.nominalFPS, candReader.nominalFPS)).rounded())))
        let ciCtx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])

        var sumScore = 0.0
        var minMSSIMObserved = 1.0
        var maxANEDist = 0.0
        var sumDEMean = 0.0
        var maxDEP95 = 0.0
        var allThaiOK = true
        var aneActive = true
        var notes: [String] = []

        var refUprightPB: CVPixelBuffer?
        var candScaledPB: CVPixelBuffer?

        for i in 0..<sampleCount {
            let t = sampleCount == 1 ? minDur * 0.5 : (Double(i) + 0.5) * (minDur / Double(sampleCount))
            guard let rRaw = try refReader.pixelBuffer(at: t),
                  let cRaw = try candReader.pixelBuffer(at: t) else {
                throw SafariumError.snapshot("SafariumPQ missing frame at t=\(t)s")
            }

            let rw = refReader.width, rh = refReader.height
            let refPB: CVPixelBuffer
            if refReader.preferredTransform.isIdentity && CVPixelBufferGetWidth(rRaw) == rw && CVPixelBufferGetHeight(rRaw) == rh {
                refPB = rRaw
            } else {
                if refUprightPB == nil {
                    refUprightPB = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: rw, height: rh, pixelFormat: .bgra)
                }
                let ci = refReader.orientedCIImage(from: rRaw)
                ciCtx.render(ci, to: refUprightPB!, bounds: CGRect(x: 0, y: 0, width: rw, height: rh), colorSpace: Snapshot.colorSpace)
                refPB = refUprightPB!
            }

            let candPB: CVPixelBuffer
            if candReader.preferredTransform.isIdentity && CVPixelBufferGetWidth(cRaw) == rw && CVPixelBufferGetHeight(cRaw) == rh {
                candPB = cRaw
            } else {
                if candScaledPB == nil {
                    candScaledPB = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: rw, height: rh, pixelFormat: .bgra)
                }
                var ci = candReader.orientedCIImage(from: cRaw)
                if Int(ci.extent.width.rounded()) != rw || Int(ci.extent.height.rounded()) != rh {
                    ci = ci.transformed(by: CGAffineTransform(
                        scaleX: CGFloat(rw) / max(1, ci.extent.width),
                        y: CGFloat(rh) / max(1, ci.extent.height)
                    ))
                }
                ciCtx.render(ci, to: candScaledPB!, bounds: CGRect(x: 0, y: 0, width: rw, height: rh), colorSpace: Snapshot.colorSpace)
                candPB = candScaledPB!
            }

            // Run Thai OCR check on first, middle, and last sampled frames to balance thoroughness and speed.
            let runOCRThisFrame = (checkThaiOCR || expectedThaiText != nil) && (i == 0 || i == sampleCount / 2 || i == sampleCount - 1)
            let rep = try autoreleasepool {
                try engine.evaluatePair(
                    reference: refPB,
                    candidate: candPB,
                    checkThaiOCR: runOCRThisFrame,
                    expectedThaiText: expectedThaiText,
                    minScore: minScore,
                    maxDeltaE00P95: maxDeltaE00P95,
                    minMSSSIM: minMSSSIM
                )
            }
            sumScore += rep.score0To100
            minMSSIMObserved = min(minMSSIMObserved, rep.msSSIM)
            maxANEDist = max(maxANEDist, rep.aneFeatureDistance)
            sumDEMean += rep.deltaE00Mean
            maxDEP95 = max(maxDEP95, rep.deltaE00P95)
            if !rep.thaiOCROK { allThaiOK = false }
            if !rep.aneDeviceActive { aneActive = false }
            notes.append(contentsOf: rep.notes)
        }

        let meanScore = sumScore / Double(sampleCount)
        let meanDE = sumDEMean / Double(sampleCount)
        let passed = (meanScore >= minScore) && (minMSSIMObserved >= minMSSSIM) && (maxDEP95 <= maxDeltaE00P95) && allThaiOK
        let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return SafariumPQReport(
            score0To100: meanScore,
            msSSIM: minMSSIMObserved,
            aneFeatureDistance: maxANEDist,
            deltaE00Mean: meanDE,
            deltaE00P95: maxDEP95,
            thaiOCROK: allThaiOK,
            sampledFrames: sampleCount,
            aneDeviceActive: aneActive,
            wallMs: wallMs,
            passed: passed,
            notes: Array(Set(notes)).sorted()
        )
    }
}

// MARK: - ForgeAutoReframe (420v Plane-0 Cut Detect + ANE Face/Saliency + VNTrackObjectRequest + EMA/Hysteresis)

public struct ForgeAutoReframeReport: Codable, Sendable {
    public let inputPath: String
    public let outputPath: String
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let outputWidth: Int
    public let outputHeight: Int
    public let frames: Int
    public let sceneCuts: Int
    public let facesDetectedFrames: Int
    public let wallMs: Double
}

public enum ForgeReframeDetector: String, Codable, Sendable {
    case saliency
    case face
    case saliencyAndFace = "saliency+face"

    public static func parse(_ s: String?) -> ForgeReframeDetector {
        switch s?.lowercased() {
        case "saliency": return .saliency
        case "face": return .face
        default: return .saliencyAndFace
        }
    }
}

public final class ForgeReframeTracker {
    public let detector: ForgeReframeDetector
    public let emaAlpha: Double
    public let hysteresis: Double
    public let sceneCutThreshold: Double
    public let resetOnSceneCut: Bool
    public let keyframeInterval: Int

    private var prevLuma: [Float] = []
    private var currLuma: [Float] = []
    private var diffLuma: [Float] = []
    private var smoothedCenter = CGPoint(x: 0.5, y: 0.5)
    private var hasSmoothed = false
    private var seqHandler = VNSequenceRequestHandler()
    private var lastTrackedObs: VNDetectedObjectObservation?
    private var frameCount = 0
    public private(set) var sceneCutCount = 0
    public private(set) var facesDetectedFrames = 0

    public init(
        detector: ForgeReframeDetector = .saliencyAndFace,
        emaAlpha: Double = 0.14,
        hysteresis: Double = 0.02,
        sceneCutThreshold: Double = 0.20,
        resetOnSceneCut: Bool = true,
        keyframeInterval: Int = 6
    ) {
        self.detector = detector
        self.emaAlpha = max(0.01, min(1.0, emaAlpha))
        self.hysteresis = max(0.0, min(0.25, hysteresis))
        self.sceneCutThreshold = max(0.05, min(0.95, sceneCutThreshold))
        self.resetOnSceneCut = resetOnSceneCut
        self.keyframeInterval = max(1, keyframeInterval)
    }

    public static func parseAspect(_ aspect: String) throws -> Double {
        let trimmed = aspect.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":")
            if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 {
                return w / h
            }
        }
        if let v = Double(trimmed), v.isFinite, v > 0.1, v < 10.0 {
            return v
        }
        throw SafariumError.invalidState("invalid aspect ratio '\(aspect)'")
    }

    private func computeLumaMADAndDetectCut(count: Int, fillCurr: (UnsafeMutablePointer<Float>) -> Void) -> Bool {
        if currLuma.count != count {
            currLuma = [Float](repeating: 0, count: count)
            prevLuma = [Float](repeating: 0, count: count)
            diffLuma = [Float](repeating: 0, count: count)
            currLuma.withUnsafeMutableBufferPointer { fillCurr($0.baseAddress!) }
            swap(&prevLuma, &currLuma)
            return false
        }
        currLuma.withUnsafeMutableBufferPointer { fillCurr($0.baseAddress!) }
        var mad: Float = 0
        prevLuma.withUnsafeBufferPointer { pPtr in
            currLuma.withUnsafeBufferPointer { cPtr in
                diffLuma.withUnsafeMutableBufferPointer { dPtr in
                    vDSP_vsub(pPtr.baseAddress!, 1, cPtr.baseAddress!, 1, dPtr.baseAddress!, 1, vDSP_Length(count))
                    vDSP_vabs(dPtr.baseAddress!, 1, dPtr.baseAddress!, 1, vDSP_Length(count))
                    vDSP_meanv(dPtr.baseAddress!, 1, &mad, vDSP_Length(count))
                }
            }
        }
        swap(&prevLuma, &currLuma)
        return (Double(mad) / 255.0) >= sceneCutThreshold
    }

    private func detectCutOn420vPlane0(_ pb: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0)
        let h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        guard let rawBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return false }
        let base = rawBase.assumingMemoryBound(to: UInt8.self)
        let count = w * h
        return computeLumaMADAndDetectCut(count: count) { dst in
            if stride == w {
                vDSP_vfltu8(base, 1, dst, 1, vDSP_Length(count))
            } else {
                for y in 0..<h {
                    vDSP_vfltu8(base.advanced(by: y * stride), 1, dst.advanced(by: y * w), 1, vDSP_Length(w))
                }
            }
        }
    }

    private func detectCutOnBGRA(_ pb: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        guard let rawBase = CVPixelBufferGetBaseAddress(pb) else { return false }
        let base = rawBase.assumingMemoryBound(to: UInt8.self)
        let step = 4
        let sw = max(1, (w + step - 1) / step)
        let sh = max(1, (h + step - 1) / step)
        return computeLumaMADAndDetectCut(count: sw * sh) { dst in
            var idx = 0
            for y in Swift.stride(from: 0, to: h, by: step) {
                let row = base.advanced(by: y * stride)
                for x in Swift.stride(from: 0, to: w, by: step) {
                    let off = x * 4
                    let yVal = 0.0722 * Float(row[off]) + 0.7152 * Float(row[off + 1]) + 0.2126 * Float(row[off + 2])
                    dst[idx] = yVal
                    idx += 1
                }
            }
        }
    }

    /// Computes normalized crop rect (in top-left UI coordinates [0..1] x [0..1]) for `targetAspect`.
    public func nextCropRectNormalized(
        visionPB: CVPixelBuffer,
        luma420vPB: CVPixelBuffer?,
        targetAspect: Double,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> CGRect {
        let isCut = luma420vPB.map { detectCutOn420vPlane0($0) } ?? detectCutOnBGRA(visionPB)
        if isCut {
            sceneCutCount += 1
            if resetOnSceneCut {
                seqHandler = VNSequenceRequestHandler()
                lastTrackedObs = nil
                hasSmoothed = false
            }
        }

        let needKeyframe = (frameCount == 0) || isCut || (frameCount % keyframeInterval == 0) || (lastTrackedObs == nil)
        var targetVisionBox: CGRect?

        if !needKeyframe, let prevObs = lastTrackedObs {
            let trackReq = VNTrackObjectRequest(detectedObjectObservation: prevObs)
            trackReq.trackingLevel = .fast
            _ = ForgeVisionANE.preferANE(for: trackReq)
            try? seqHandler.perform([trackReq], on: visionPB)
            if let tracked = trackReq.results?.first as? VNDetectedObjectObservation, tracked.confidence > 0.25 {
                lastTrackedObs = tracked
                targetVisionBox = tracked.boundingBox
            }
        }

        if targetVisionBox == nil {
            var requests: [VNRequest] = []
            let faceReq = VNDetectFaceRectanglesRequest()
            let salReq = VNGenerateAttentionBasedSaliencyImageRequest()
            _ = ForgeVisionANE.preferANE(for: faceReq)
            _ = ForgeVisionANE.preferANE(for: salReq)
            if detector == .face || detector == .saliencyAndFace { requests.append(faceReq) }
            if detector == .saliency || detector == .saliencyAndFace { requests.append(salReq) }

            let handler = VNImageRequestHandler(cvPixelBuffer: visionPB, options: [:])
            try? handler.perform(requests)

            if let faces = faceReq.results, !faces.isEmpty {
                facesDetectedFrames += 1
                var union = faces[0].boundingBox
                for f in faces.dropFirst() {
                    union = union.union(f.boundingBox)
                }
                targetVisionBox = union
                lastTrackedObs = VNDetectedObjectObservation(boundingBox: union)
            } else if let sal = salReq.results?.first {
                if let objs = sal.salientObjects, !objs.isEmpty {
                    let best = objs.max(by: { $0.confidence < $1.confidence }) ?? objs[0]
                    targetVisionBox = best.boundingBox
                    lastTrackedObs = VNDetectedObjectObservation(boundingBox: best.boundingBox)
                }
            }
        }

        // Convert Vision bottom-left origin -> top-left UI space
        let rawCenterTopLeft: CGPoint
        if let box = targetVisionBox {
            rawCenterTopLeft = CGPoint(x: box.midX, y: 1.0 - box.midY)
        } else {
            rawCenterTopLeft = CGPoint(x: 0.5, y: 0.5)
        }

        if !hasSmoothed {
            smoothedCenter = rawCenterTopLeft
            hasSmoothed = true
        } else {
            let dx = rawCenterTopLeft.x - smoothedCenter.x
            let dy = rawCenterTopLeft.y - smoothedCenter.y
            let nx = abs(dx) > hysteresis ? (emaAlpha * rawCenterTopLeft.x + (1.0 - emaAlpha) * smoothedCenter.x) : smoothedCenter.x
            let ny = abs(dy) > hysteresis ? (emaAlpha * rawCenterTopLeft.y + (1.0 - emaAlpha) * smoothedCenter.y) : smoothedCenter.y
            smoothedCenter = CGPoint(x: nx, y: ny)
        }

        frameCount += 1

        let srcAspect = Double(sourceWidth) / Double(max(1, sourceHeight))
        let normW: Double
        let normH: Double
        if targetAspect < srcAspect {
            normH = 1.0
            normW = max(0.05, min(1.0, targetAspect / srcAspect))
        } else {
            normW = 1.0
            normH = max(0.05, min(1.0, srcAspect / targetAspect))
        }

        let minX = normW * 0.5
        let maxX = 1.0 - normW * 0.5
        let minY = normH * 0.5
        let maxY = 1.0 - normH * 0.5
        let cx = max(minX, min(maxX, smoothedCenter.x))
        let cy = max(minY, min(maxY, smoothedCenter.y))
        return CGRect(x: cx - normW * 0.5, y: cy - normH * 0.5, width: normW, height: normH)
    }
}

public enum ForgeAutoReframe {
    public static func reframeVideo(
        inputURL: URL,
        aspect: String = "9:16",
        detector: ForgeReframeDetector = .saliencyAndFace,
        emaAlpha: Double = 0.14,
        hysteresis: Double = 0.02,
        sceneCutThreshold: Double = 0.20,
        resetOnSceneCut: Bool = true,
        outputHeight: Int? = nil,
        codec: VideoCodec = .h264,
        bitrate: Int = 8_000_000,
        quality: Double? = nil,
        outputURL: URL,
        overwrite: Bool = false
    ) async throws -> ForgeAutoReframeReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(inputURL)
        let targetAspect = try ForgeReframeTracker.parseAspect(aspect)
        let stage = try APFSAutoStage.makeSession(for: outputURL, overwrite: overwrite)
        defer { stage.cleanup() }

        let asset = AVURLAsset(url: inputURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let vt = try await asset.loadTracks(withMediaType: .video).first else {
            throw SafariumError.invalidState("autoReframe input has no video track: \(inputURL.path)")
        }
        let natSize = try await vt.load(.naturalSize)
        let prefTx = try await vt.load(.preferredTransform)
        let nomFPS = Double(try await vt.load(.nominalFrameRate))
        let outFPS = max(1, Int((nomFPS > 0 ? nomFPS : 30.0).rounded()))
        let uprightRect = CGRect(origin: .zero, size: natSize).applying(prefTx)
        let srcW = max(2, Int(abs(uprightRect.width).rounded()))
        let srcH = max(2, Int(abs(uprightRect.height).rounded()))

        let outH = max(2, (outputHeight ?? srcH) & ~1)
        let outW = max(2, Int((Double(outH) * targetAspect).rounded()) & ~1)

        // Decode BGRA for crop render + 420v Plane-0 for fast cut detection when transform is identity
        let readerBGRA = try AVAssetReader(asset: asset)
        let outBGRA = AVAssetReaderTrackOutput(track: vt, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        outBGRA.alwaysCopiesSampleData = false
        readerBGRA.add(outBGRA)
        guard readerBGRA.startReading() else {
            throw SafariumError.encode("autoReframe reader failed: \(readerBGRA.error?.localizedDescription ?? "?")")
        }
        defer { if readerBGRA.status == .reading { readerBGRA.cancelReading() } }

        let reader420v = try AVAssetReader(asset: asset)
        let out420v = AVAssetReaderTrackOutput(track: vt, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        out420v.alwaysCopiesSampleData = false
        reader420v.add(out420v)
        guard reader420v.startReading() else {
            throw SafariumError.encode("autoReframe 420v reader failed: \(reader420v.error?.localizedDescription ?? "?")")
        }
        defer { if reader420v.status == .reading { reader420v.cancelReading() } }

        let filterEngine = try ForgeMetalFilterEngine(initWave2Engine: false)
        let tracker = ForgeReframeTracker(
            detector: detector,
            emaAlpha: emaAlpha,
            hysteresis: hysteresis,
            sceneCutThreshold: sceneCutThreshold,
            resetOnSceneCut: resetOnSceneCut
        )
        let stagedOut = stage.fileURL("reframed.\(codec.fileExtension)")
        let sink = try AVAssetWriterSink(
            url: stagedOut,
            width: outW,
            height: outH,
            fps: outFPS,
            codec: codec,
            bitrate: bitrate,
            quality: quality,
            pixelFormat: codec.hasAlpha ? .bgra : .bgra,
            profile: .lowRamClosedGOP
        )

        var uprightPB: CVPixelBuffer?
        let ciCtx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])
        var framesWritten = 0

        do {
            while let sbBGRA = autoreleasepool(invoking: { outBGRA.copyNextSampleBuffer() }) {
                let sb420 = autoreleasepool(invoking: { out420v.copyNextSampleBuffer() })
                if sbBGRA.numSamples == 0 { continue }
                guard let rawBGRA = sbBGRA.imageBuffer else { continue }
                let raw420 = sb420.flatMap { CMSampleBufferGetImageBuffer($0) }

                let srcPB: CVPixelBuffer
                if prefTx.isIdentity {
                    srcPB = rawBGRA
                } else {
                    if uprightPB == nil {
                        uprightPB = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: srcW, height: srcH, pixelFormat: .bgra)
                    }
                    let oriented = SafariumSequentialVideoReader.orientedCIImage(from: rawBGRA, transform: prefTx, targetWidth: srcW, targetHeight: srcH)
                    ciCtx.render(oriented, to: uprightPB!, bounds: CGRect(x: 0, y: 0, width: srcW, height: srcH), colorSpace: Snapshot.colorSpace)
                    srcPB = uprightPB!
                }

                let normCrop = tracker.nextCropRectNormalized(
                    visionPB: srcPB,
                    luma420vPB: raw420,
                    targetAspect: targetAspect,
                    sourceWidth: srcW,
                    sourceHeight: srcH
                )
                let cropPx = CGRect(
                    x: normCrop.origin.x * Double(srcW),
                    y: normCrop.origin.y * Double(srcH),
                    width: normCrop.width * Double(srcW),
                    height: normCrop.height * Double(srcH)
                )

                try await sink.append(presentationTime: sbBGRA.presentationTimeStamp) { dstPB in
                    try filterEngine.applyGeom(srcPB: srcPB, into: dstPB, cropRect: cropPx)
                }
                framesWritten += 1
            }
            guard framesWritten > 0 else {
                throw SafariumError.invalidState("autoReframe yielded 0 frames from \(inputURL.lastPathComponent)")
            }
            try await sink.finish()
            try stage.commit(stagedFile: stagedOut, overwrite: overwrite)
        } catch {
            sink.cancel()
            throw error
        }

        let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return ForgeAutoReframeReport(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            sourceWidth: srcW,
            sourceHeight: srcH,
            outputWidth: outW,
            outputHeight: outH,
            frames: framesWritten,
            sceneCuts: tracker.sceneCutCount,
            facesDetectedFrames: tracker.facesDetectedFrames,
            wallMs: wallMs
        )
    }
}

// MARK: - ForgePersonMatte (ANE PersonSegmentation / ForegroundInstanceMask + Temporal EMA)

public enum ForgeMatteMode: String, Codable, Sendable {
    case personFast
    case personBalanced
    case personAccurate
    case instance

    public static func parse(_ s: String?) -> ForgeMatteMode {
        switch s?.lowercased() {
        case "personfast", "fast": return .personFast
        case "personaccurate", "accurate": return .personAccurate
        case "instance": return .instance
        default: return .personBalanced
        }
    }
}

public struct ForgePersonMatteReport: Codable, Sendable {
    public let inputPath: String
    public let outputPath: String
    public let mode: String
    public let frames: Int
    public let width: Int
    public let height: Int
    public let codec: String
    public let maskOnly: Bool
    public let wallMs: Double
}

public final class ForgePersonMatteProcessor {
    public let mode: ForgeMatteMode
    public let temporalEMA: Double
    private let filterEngine: ForgeMetalFilterEngine
    private var prevMaskTex: MTLTexture?
    private var currMaskTex: MTLTexture?
    private var maskW = 0
    private var maskH = 0

    public init(mode: ForgeMatteMode = .personBalanced, temporalEMA: Double = 0.35, filterEngine: ForgeMetalFilterEngine) {
        self.mode = mode
        self.temporalEMA = max(0.01, min(1.0, temporalEMA))
        self.filterEngine = filterEngine
    }

    public func resetTemporalState() {
        prevMaskTex = nil
    }

    private func ensureMaskPingPong(width: Int, height: Int) throws {
        if maskW == width && maskH == height && currMaskTex != nil && prevMaskTex != nil { return }
        func mk() throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
            d.storageMode = .private
            d.usage = [.shaderRead, .shaderWrite]
            guard let t = filterEngine.device.makeTexture(descriptor: d) else {
                throw SafariumError.encode("matte ping-pong texture alloc failed")
            }
            return t
        }
        prevMaskTex = try mk()
        currMaskTex = try mk()
        maskW = width
        maskH = height
    }

    public func processFrame(
        srcPB: CVPixelBuffer,
        bgTex: MTLTexture? = nil,
        bgColor: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 0),
        maskOnly: Bool = false,
        into dstPB: CVPixelBuffer
    ) throws {
        let w = CVPixelBufferGetWidth(dstPB), h = CVPixelBufferGetHeight(dstPB)
        let hadPrev = (maskW == w && maskH == h && prevMaskTex != nil)
        try ensureMaskPingPong(width: w, height: h)
        guard let outMask = currMaskTex else { throw SafariumError.encode("missing mask texture") }

        let rawMaskPB: CVPixelBuffer
        switch mode {
        case .personFast, .personBalanced, .personAccurate:
            let req = VNGeneratePersonSegmentationRequest()
            switch mode {
            case .personFast: req.qualityLevel = .fast
            case .personBalanced: req.qualityLevel = .balanced
            case .personAccurate: req.qualityLevel = .accurate
            case .instance: break
            }
            req.outputPixelFormat = kCVPixelFormatType_OneComponent8
            _ = ForgeVisionANE.preferANEAndGPU(for: req)
            let handler = VNImageRequestHandler(cvPixelBuffer: srcPB, options: [:])
            try handler.perform([req])
            guard let obs = req.results?.first else {
                throw SafariumError.snapshot("VNGeneratePersonSegmentationRequest yielded no mask")
            }
            rawMaskPB = obs.pixelBuffer
        case .instance:
            let req = VNGenerateForegroundInstanceMaskRequest()
            _ = ForgeVisionANE.preferANEAndGPU(for: req)
            let handler = VNImageRequestHandler(cvPixelBuffer: srcPB, options: [:])
            try handler.perform([req])
            if let obs = req.results?.first, !obs.allInstances.isEmpty {
                rawMaskPB = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
            } else {
                // Empty foreground fallback: zero mask
                let empty = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: w, height: h, pixelFormat: .bgra)
                try filterEngine.fillSolid(colorRGBA: maskOnly ? SIMD4<Float>(0, 0, 0, 1) : bgColor, into: empty)
                try filterEngine.applyGeom(srcPB: empty, into: dstPB)
                return
            }
        }

        try filterEngine.applyMatteEMAAndComposite(
            srcPB: srcPB,
            rawMaskPB: rawMaskPB,
            prevMaskTex: hadPrev ? prevMaskTex : nil,
            outMaskTex: outMask,
            bgTex: bgTex,
            bgColor: bgColor,
            emaAlpha: Float(temporalEMA),
            maskOnly: maskOnly,
            into: dstPB
        )
        swap(&prevMaskTex, &currMaskTex)
    }
}

public enum ForgePersonMatte {
    public static func matteVideo(
        inputURL: URL,
        mode: ForgeMatteMode = .personBalanced,
        temporalEMA: Double = 0.35,
        replaceBgHex: String? = nil,
        replaceBgImageURL: URL? = nil,
        codec: VideoCodec = .hevcAlpha,
        maskOnly: Bool = false,
        bitrate: Int = 10_000_000,
        quality: Double? = nil,
        maxFrames: Int? = nil,
        outputURL: URL,
        overwrite: Bool = false
    ) async throws -> ForgePersonMatteReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(inputURL)
        let stage = try APFSAutoStage.makeSession(for: outputURL, overwrite: overwrite)
        defer { stage.cleanup() }

        let reader = try await SafariumSequentialVideoReader(url: inputURL, loop: false, pixelFormat: kCVPixelFormatType_32BGRA)
        defer { reader.close() }
        let fps = max(1, Int(reader.nominalFPS.rounded()))
        let estFrames = max(1, Int((reader.durationSeconds * Double(fps)).rounded()))
        let totalFrames = maxFrames.map { min($0, estFrames) } ?? estFrames
        let w = max(2, reader.width & ~1)
        let h = max(2, reader.height & ~1)

        let filterEngine = try ForgeMetalFilterEngine(initWave2Engine: false)
        let processor = ForgePersonMatteProcessor(mode: mode, temporalEMA: temporalEMA, filterEngine: filterEngine)

        var bgTex: MTLTexture?
        if let bgImgURL = replaceBgImageURL {
            try SafeFilePublisher.assertRegularReadableFile(bgImgURL)
            if let src = CGImageSourceCreateWithURL(bgImgURL as CFURL, nil),
               let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                bgTex = try filterEngine.uploadCGImageToTexture(cg)
            }
        }
        let bgColor = replaceBgHex.map { ForgeColorHex.parseRGBA($0) } ?? SIMD4<Float>(0, 0, 0, 0)

        let stagedOut = stage.fileURL("matte.\(codec.fileExtension)")
        let sink = try AVAssetWriterSink(
            url: stagedOut,
            width: w,
            height: h,
            fps: fps,
            codec: codec,
            bitrate: bitrate,
            quality: quality,
            pixelFormat: .bgra,
            profile: .lowRamClosedGOP
        )

        var uprightPB: CVPixelBuffer?
        let ciCtx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])

        do {
            for i in 0..<totalFrames {
                let sampleT = (Double(i) + 0.5) / Double(fps)
                guard let rawPB = try reader.pixelBuffer(at: sampleT) else {
                    throw SafariumError.snapshot("personMatte missing frame \(i)")
                }
                let srcPB: CVPixelBuffer
                if reader.preferredTransform.isIdentity && CVPixelBufferGetWidth(rawPB) == w && CVPixelBufferGetHeight(rawPB) == h {
                    srcPB = rawPB
                } else {
                    if uprightPB == nil {
                        uprightPB = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: w, height: h, pixelFormat: .bgra)
                    }
                    let oriented = reader.orientedCIImage(from: rawPB)
                    ciCtx.render(oriented, to: uprightPB!, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: Snapshot.colorSpace)
                    srcPB = uprightPB!
                }

                try await sink.append { dstPB in
                    try autoreleasepool {
                        try processor.processFrame(
                            srcPB: srcPB,
                            bgTex: bgTex,
                            bgColor: bgColor,
                            maskOnly: maskOnly,
                            into: dstPB
                        )
                    }
                }
            }
            try await sink.finish()
            try stage.commit(stagedFile: stagedOut, overwrite: overwrite)
        } catch {
            sink.cancel()
            throw error
        }

        let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return ForgePersonMatteReport(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            mode: mode.rawValue,
            frames: totalFrames,
            width: w,
            height: h,
            codec: codec.rawValue,
            maskOnly: maskOnly,
            wallMs: wallMs
        )
    }
}
