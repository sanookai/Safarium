import Accelerate
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox

#if canImport(MetalFX)
import MetalFX
#endif

// MARK: - Wave 15D-A: Metal Edge-Masked Multi-Tap Deband + Temporal IGN Dither

/// Configuration for `MetalDebandFilter` edge-masked directional debanding and dithering.
public struct DebandConfig: Codable, Sendable, Equatable {
    /// Debanding blend strength (`0.0...1.0`).
    public var strength: Float
    /// Maximum normalized color/luma difference treated as a quantization band step (`0.002...0.08`).
    public var threshold: Float
    /// Triangular-PDF blue-noise-like dither amplitude in LSB units (`0.0...2.0`).
    public var ditherAmplitude: Float
    /// When `true`, protects sharp text/UI/object edges from smoothing and dithering.
    public var protectSharpEdges: Bool
    /// Normalized local gradient threshold above which edges are protected.
    public var edgeThreshold: Float

    public init(
        strength: Float = 0.65,
        threshold: Float = 0.015,
        ditherAmplitude: Float = 1.0,
        protectSharpEdges: Bool = true,
        edgeThreshold: Float = 0.045
    ) {
        self.strength = strength
        self.threshold = threshold
        self.ditherAmplitude = ditherAmplitude
        self.protectSharpEdges = protectSharpEdges
        self.edgeThreshold = edgeThreshold
    }
}

private struct DebandUniforms {
    var width: UInt32
    var height: UInt32
    var frameIndex: UInt32
    var protectSharpEdges: UInt32
    var strength: Float
    var threshold: Float
    var ditherAmplitude: Float
    var edgeThreshold: Float
    var lsbStep: Float
    var isP010: UInt32
    var pad0: UInt32
    var pad1: UInt32
}

/// GPU-accelerated edge-masked directional multi-tap deband filter with temporally stable
/// triangular-PDF Interleaved Gradient Noise (IGN) dithering and automatic CPU fallback.
///
/// Compiles its Metal Shading Language (MSL) compute kernels at runtime via
/// `MTLDevice.makeLibrary(source:options:)` with zero external `.metallib` dependency.
public final class MetalDebandFilter: @unchecked Sendable {
    public static let shared = MetalDebandFilter()

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let textureCache: CVMetalTextureCache?
    private let bgraPipeline: MTLComputePipelineState?
    private let lumaPipeline: MTLComputePipelineState?
    private let chromaCopyPipeline: MTLComputePipelineState?
    private let lock = NSLock()

    /// True when the runtime-compiled Metal compute backend is active.
    public var isUsingMetal: Bool {
        device != nil && commandQueue != nil && textureCache != nil && bgraPipeline != nil && lumaPipeline != nil
    }

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let dev = device, let queue = dev.makeCommandQueue() else {
            self.device = nil
            self.commandQueue = nil
            self.textureCache = nil
            self.bgraPipeline = nil
            self.lumaPipeline = nil
            self.chromaCopyPipeline = nil
            return
        }

        var cacheOut: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, dev, nil, &cacheOut)
        guard cacheStatus == kCVReturnSuccess, let cache = cacheOut else {
            self.device = nil
            self.commandQueue = nil
            self.textureCache = nil
            self.bgraPipeline = nil
            self.lumaPipeline = nil
            self.chromaCopyPipeline = nil
            return
        }

        do {
            let library = try dev.makeLibrary(source: Self.mslSource, options: nil)
            guard let fnBGRA = library.makeFunction(name: "safarium_deband_bgra8"),
                  let fnLuma = library.makeFunction(name: "safarium_deband_luma"),
                  let fnChroma = library.makeFunction(name: "safarium_copy_chroma")
            else {
                self.device = nil
                self.commandQueue = nil
                self.textureCache = nil
                self.bgraPipeline = nil
                self.lumaPipeline = nil
                self.chromaCopyPipeline = nil
                return
            }
            let bgraPipe = try dev.makeComputePipelineState(function: fnBGRA)
            let lumaPipe = try dev.makeComputePipelineState(function: fnLuma)
            let chromaPipe = try dev.makeComputePipelineState(function: fnChroma)
            self.bgraPipeline = bgraPipe
            self.lumaPipeline = lumaPipe
            self.chromaCopyPipeline = chromaPipe
            self.device = dev
            self.commandQueue = queue
            self.textureCache = cache
        } catch {
            self.device = nil
            self.commandQueue = nil
            self.textureCache = nil
            self.bgraPipeline = nil
            self.lumaPipeline = nil
            self.chromaCopyPipeline = nil
        }
    }

    /// Processes an input `CVPixelBuffer` (`BGRA8`, `NV12`, or `P010`) and returns a newly allocated
    /// debanded and edge-protected `CVPixelBuffer` in the same pixel format with color attachments preserved.
    public func process(
        input: CVPixelBuffer,
        frameIndex: Int = 0,
        config: DebandConfig = DebandConfig()
    ) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)
        let format = CVPixelBufferGetPixelFormatType(input)

        guard width > 0, height > 0 else {
            throw SafariumError.invalidState("MetalDebandFilter: invalid pixel buffer dimensions \(width)x\(height)")
        }

        let isBGRA = (format == kCVPixelFormatType_32BGRA)
        let isNV12 = (format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let isP010 = (format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)

        // Convert unsupported pixel formats to BGRA8 cleanly before processing
        let workingInput: CVPixelBuffer
        let workingFormat: OSType
        if isBGRA || isNV12 || isP010 {
            workingInput = input
            workingFormat = format
        } else {
            workingInput = try Self.convertToBGRA8(input)
            workingFormat = kCVPixelFormatType_32BGRA
        }

        let output = try Self.createIOSurfacePixelBuffer(width: width, height: height, pixelFormat: workingFormat)
        CVBufferPropagateAttachments(workingInput, output)

        if isUsingMetal {
            do {
                if workingFormat == kCVPixelFormatType_32BGRA {
                    try processMetalBGRA8(input: workingInput, output: output, frameIndex: frameIndex, config: config)
                    return output
                } else {
                    let isTenBit = (workingFormat == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                        || workingFormat == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
                    try processMetalBiPlanar(
                        input: workingInput,
                        output: output,
                        isP010: isTenBit,
                        frameIndex: frameIndex,
                        config: config
                    )
                    return output
                }
            } catch {
                // Fall back deterministically to CPU if GPU submission fails
            }
        }

        try processCPUFallback(input: workingInput, output: output, frameIndex: frameIndex, config: config)
        return output
    }

    // MARK: - Metal GPU Execution

    private func processMetalBGRA8(
        input: CVPixelBuffer,
        output: CVPixelBuffer,
        frameIndex: Int,
        config: DebandConfig
    ) throws {
        guard let queue = commandQueue,
              let cache = textureCache,
              let pipeline = bgraPipeline
        else {
            throw SafariumError.invalidState("MetalDebandFilter GPU pipeline unavailable")
        }

        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)

        lock.lock()
        defer { lock.unlock() }

        let (inCV, inTex) = try bindTexture(cache: cache, pb: input, format: .bgra8Unorm, width: width, height: height, plane: 0)
        let (outCV, outTex) = try bindTexture(cache: cache, pb: output, format: .bgra8Unorm, width: width, height: height, plane: 0)

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else {
            throw SafariumError.encode("MetalDebandFilter: failed creating command encoder")
        }

        var uniforms = DebandUniforms(
            width: UInt32(width),
            height: UInt32(height),
            frameIndex: UInt32(max(0, frameIndex)),
            protectSharpEdges: config.protectSharpEdges ? 1 : 0,
            strength: max(0.0, min(1.0, config.strength)),
            threshold: max(0.001, config.threshold),
            ditherAmplitude: max(0.0, config.ditherAmplitude),
            edgeThreshold: max(0.005, config.edgeThreshold),
            lsbStep: 1.0 / 255.0,
            isP010: 0,
            pad0: 0,
            pad1: 0
        )

        enc.setComputePipelineState(pipeline)
        enc.setTexture(inTex, index: 0)
        enc.setTexture(outTex, index: 1)
        enc.setBytes(&uniforms, length: MemoryLayout<DebandUniforms>.stride, index: 0)
        let (groups, threads) = dispatchGrid(pipeline: pipeline, width: width, height: height)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
        enc.endEncoding()

        cmd.commit()
        cmd.waitUntilCompleted()
        _ = (inCV, outCV)
        CVMetalTextureCacheFlush(cache, 0)

        if let err = cmd.error {
            throw SafariumError.encode("MetalDebandFilter BGRA8 execution failed: \(err.localizedDescription)")
        }
    }

    private func processMetalBiPlanar(
        input: CVPixelBuffer,
        output: CVPixelBuffer,
        isP010: Bool,
        frameIndex: Int,
        config: DebandConfig
    ) throws {
        guard let queue = commandQueue,
              let cache = textureCache,
              let lumaPipe = lumaPipeline,
              let chromaPipe = chromaCopyPipeline
        else {
            throw SafariumError.invalidState("MetalDebandFilter bi-planar GPU pipeline unavailable")
        }

        let yW = CVPixelBufferGetWidthOfPlane(input, 0)
        let yH = CVPixelBufferGetHeightOfPlane(input, 0)
        let uvW = CVPixelBufferGetWidthOfPlane(input, 1)
        let uvH = CVPixelBufferGetHeightOfPlane(input, 1)

        let yFmt: MTLPixelFormat = isP010 ? .r16Unorm : .r8Unorm
        let uvFmt: MTLPixelFormat = isP010 ? .rg16Unorm : .rg8Unorm

        lock.lock()
        defer { lock.unlock() }

        let (inYCV, inYTex) = try bindTexture(cache: cache, pb: input, format: yFmt, width: yW, height: yH, plane: 0)
        let (outYCV, outYTex) = try bindTexture(cache: cache, pb: output, format: yFmt, width: yW, height: yH, plane: 0)
        let (inUVCV, inUVTex) = try bindTexture(cache: cache, pb: input, format: uvFmt, width: uvW, height: uvH, plane: 1)
        let (outUVCV, outUVTex) = try bindTexture(cache: cache, pb: output, format: uvFmt, width: uvW, height: uvH, plane: 1)

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder()
        else {
            throw SafariumError.encode("MetalDebandFilter: failed creating bi-planar command encoder")
        }

        var uniforms = DebandUniforms(
            width: UInt32(yW),
            height: UInt32(yH),
            frameIndex: UInt32(max(0, frameIndex)),
            protectSharpEdges: config.protectSharpEdges ? 1 : 0,
            strength: max(0.0, min(1.0, config.strength)),
            threshold: max(0.001, config.threshold),
            ditherAmplitude: max(0.0, config.ditherAmplitude),
            edgeThreshold: max(0.005, config.edgeThreshold),
            lsbStep: isP010 ? (1.0 / 1023.0) : (1.0 / 255.0),
            isP010: isP010 ? 1 : 0,
            pad0: 0,
            pad1: 0
        )

        enc.setComputePipelineState(lumaPipe)
        enc.setTexture(inYTex, index: 0)
        enc.setTexture(outYTex, index: 1)
        enc.setBytes(&uniforms, length: MemoryLayout<DebandUniforms>.stride, index: 0)
        let (yGroups, yThreads) = dispatchGrid(pipeline: lumaPipe, width: yW, height: yH)
        enc.dispatchThreadgroups(yGroups, threadsPerThreadgroup: yThreads)

        enc.setComputePipelineState(chromaPipe)
        enc.setTexture(inUVTex, index: 0)
        enc.setTexture(outUVTex, index: 1)
        let (uvGroups, uvThreads) = dispatchGrid(pipeline: chromaPipe, width: uvW, height: uvH)
        enc.dispatchThreadgroups(uvGroups, threadsPerThreadgroup: uvThreads)
        enc.endEncoding()

        cmd.commit()
        cmd.waitUntilCompleted()
        _ = (inYCV, outYCV, inUVCV, outUVCV)
        CVMetalTextureCacheFlush(cache, 0)

        if let err = cmd.error {
            throw SafariumError.encode("MetalDebandFilter bi-planar execution failed: \(err.localizedDescription)")
        }
    }

    private func bindTexture(
        cache: CVMetalTextureCache,
        pb: CVPixelBuffer,
        format: MTLPixelFormat,
        width: Int,
        height: Int,
        plane: Int
    ) throws -> (CVMetalTexture, MTLTexture) {
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pb,
            nil,
            format,
            width,
            height,
            plane,
            &cvTex
        )
        guard status == kCVReturnSuccess, let cvTex, let mtlTex = CVMetalTextureGetTexture(cvTex) else {
            throw SafariumError.encode("CVMetalTextureCacheCreateTextureFromImage failed (\(status))")
        }
        return (cvTex, mtlTex)
    }

    private func dispatchGrid(
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) -> (MTLSize, MTLSize) {
        let tw = min(16, pipeline.threadExecutionWidth)
        let th = max(1, min(16, pipeline.maxTotalThreadsPerThreadgroup / max(1, tw)))
        let threads = MTLSize(width: tw, height: th, depth: 1)
        let groups = MTLSize(
            width: (width + tw - 1) / tw,
            height: (height + th - 1) / th,
            depth: 1
        )
        return (groups, threads)
    }

    // MARK: - Deterministic CPU Fallback

    private func processCPUFallback(
        input: CVPixelBuffer,
        output: CVPixelBuffer,
        frameIndex: Int,
        config: DebandConfig
    ) throws {
        CVPixelBufferLockBaseAddress(input, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
            CVPixelBufferUnlockBaseAddress(input, .readOnly)
        }

        let format = CVPixelBufferGetPixelFormatType(input)
        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)

        if format == kCVPixelFormatType_32BGRA {
            guard let inBase = CVPixelBufferGetBaseAddress(input)?.assumingMemoryBound(to: UInt8.self),
                  let outBase = CVPixelBufferGetBaseAddress(output)?.assumingMemoryBound(to: UInt8.self)
            else {
                throw SafariumError.encode("CPU deband fallback: missing BGRA base address")
            }
            let inBpr = CVPixelBufferGetBytesPerRow(input)
            let outBpr = CVPixelBufferGetBytesPerRow(output)
            debandBGRA8CPU(
                inBase: inBase,
                inBpr: inBpr,
                outBase: outBase,
                outBpr: outBpr,
                width: width,
                height: height,
                frameIndex: frameIndex,
                config: config
            )
            return
        }

        let isP010 = (format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            || format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)
        let yW = CVPixelBufferGetWidthOfPlane(input, 0)
        let yH = CVPixelBufferGetHeightOfPlane(input, 0)
        let uvW = CVPixelBufferGetWidthOfPlane(input, 1)
        let uvH = CVPixelBufferGetHeightOfPlane(input, 1)

        // Copy chroma plane directly
        if let inUV = CVPixelBufferGetBaseAddressOfPlane(input, 1),
           let outUV = CVPixelBufferGetBaseAddressOfPlane(output, 1)
        {
            let inUVBpr = CVPixelBufferGetBytesPerRowOfPlane(input, 1)
            let outUVBpr = CVPixelBufferGetBytesPerRowOfPlane(output, 1)
            let copyBytes = min(inUVBpr, outUVBpr, uvW * (isP010 ? 4 : 2))
            for y in 0..<uvH {
                memcpy(outUV.advanced(by: y * outUVBpr), inUV.advanced(by: y * inUVBpr), copyBytes)
            }
        }

        if isP010 {
            guard let inY = CVPixelBufferGetBaseAddressOfPlane(input, 0)?.assumingMemoryBound(to: UInt16.self),
                  let outY = CVPixelBufferGetBaseAddressOfPlane(output, 0)?.assumingMemoryBound(to: UInt16.self)
            else { return }
            let inStride = CVPixelBufferGetBytesPerRowOfPlane(input, 0) / 2
            let outStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0) / 2
            debandLumaPlaneCPU(
                width: yW,
                height: yH,
                frameIndex: frameIndex,
                config: config,
                lsbStep: 1.0 / 1023.0,
                readSample: { x, y in Float(inY[y * inStride + x] &>> 6) / 1023.0 },
                writeSample: { x, y, val in
                    let clamped = max(0.0, min(1.0, val))
                    let code10 = UInt16((clamped * 1023.0).rounded())
                    outY[y * outStride + x] = code10 &<< 6
                }
            )
        } else {
            guard let inY = CVPixelBufferGetBaseAddressOfPlane(input, 0)?.assumingMemoryBound(to: UInt8.self),
                  let outY = CVPixelBufferGetBaseAddressOfPlane(output, 0)?.assumingMemoryBound(to: UInt8.self)
            else { return }
            let inStride = CVPixelBufferGetBytesPerRowOfPlane(input, 0)
            let outStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
            debandLumaPlaneCPU(
                width: yW,
                height: yH,
                frameIndex: frameIndex,
                config: config,
                lsbStep: 1.0 / 255.0,
                readSample: { x, y in Float(inY[y * inStride + x]) / 255.0 },
                writeSample: { x, y, val in
                    let clamped = max(0.0, min(1.0, val))
                    outY[y * outStride + x] = UInt8((clamped * 255.0).rounded())
                }
            )
        }
    }

    private func debandBGRA8CPU(
        inBase: UnsafePointer<UInt8>,
        inBpr: Int,
        outBase: UnsafeMutablePointer<UInt8>,
        outBpr: Int,
        width: Int,
        height: Int,
        frameIndex: Int,
        config: DebandConfig
    ) {
        let strength = max(0.0, min(1.0, config.strength))
        let threshold = max(0.001, config.threshold)
        let edgeThresh = max(0.005, config.edgeThreshold)
        let ditherAmp = max(0.0, config.ditherAmplitude)
        let lsb: Float = 1.0 / 255.0
        let framePhase = Float(frameIndex % 4)
        let ox = 5.588238 * framePhase
        let oy = 7.131942 * framePhase

        @inline(__always)
        func sampleRGB(_ x: Int, _ y: Int) -> SIMD3<Float> {
            let cx = max(0, min(width - 1, x))
            let cy = max(0, min(height - 1, y))
            let off = cy * inBpr + cx * 4
            let b = Float(inBase[off + 0]) * lsb
            let g = Float(inBase[off + 1]) * lsb
            let r = Float(inBase[off + 2]) * lsb
            return SIMD3<Float>(r, g, b)
        }

        @inline(__always)
        func maxChanDiff(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
            let d = abs(a - b)
            return max(d.x, max(d.y, d.z))
        }

        for y in 0..<height {
            for x in 0..<width {
                let center = sampleRGB(x, y)
                let outOff = y * outBpr + x * 4
                let srcOff = y * inBpr + x * 4
                let alpha = inBase[srcOff + 3]

                var edgeFactor: Float = 0.0
                if config.protectSharpEdges {
                    let g1 = maxChanDiff(sampleRGB(x + 1, y), sampleRGB(x - 1, y))
                    let g2 = maxChanDiff(sampleRGB(x, y + 1), sampleRGB(x, y - 1))
                    let g3 = maxChanDiff(sampleRGB(x + 2, y), sampleRGB(x - 2, y))
                    let g4 = maxChanDiff(sampleRGB(x, y + 2), sampleRGB(x, y - 2))
                    let maxG = max(max(g1, g2), max(g3, g4))
                    edgeFactor = Self.smoothstep(edgeThresh * 0.5, edgeThresh, maxG)
                }

                let h1 = Self.ignNoise(Float(x) + ox, Float(y) + oy)
                let h2 = Self.ignNoise(Float(x) + ox + 17.0, Float(y) + oy + 31.0)
                let baseAngle = h1 * Float.pi * 0.5
                let r1 = 5.0 + h2 * 7.0
                let r2 = 13.0 + h1 * 11.0

                var acc = center
                var weightSum: Float = 1.0
                var maxSpread: Float = 0.0

                for ring in 0..<2 {
                    let rad = (ring == 0) ? r1 : r2
                    for dir in 0..<4 {
                        let angle = baseAngle + Float(dir) * (Float.pi * 0.25)
                        let dx = Int((cosf(angle) * rad).rounded())
                        let dy = Int((sinf(angle) * rad).rounded())
                        let pPos = sampleRGB(x + dx, y + dy)
                        let pNeg = sampleRGB(x - dx, y - dy)
                        let pMidPos = sampleRGB(x + dx / 2, y + dy / 2)
                        let pMidNeg = sampleRGB(x - dx / 2, y - dy / 2)

                        let pairAvg = (pPos + pNeg) * 0.5
                        let avgDiff = maxChanDiff(pairAvg, center)
                        let endDiff = max(maxChanDiff(pPos, center), maxChanDiff(pNeg, center))
                        let midDiff = max(maxChanDiff(pMidPos, center), maxChanDiff(pMidNeg, center))
                        let peakDiff = max(endDiff, midDiff)

                        if peakDiff > maxSpread {
                            maxSpread = peakDiff
                        }

                        if avgDiff < threshold && peakDiff < threshold * 2.4 {
                            let wAvg = 1.0 - Self.smoothstep(threshold * 0.25, threshold, avgDiff)
                            let wEnd = 1.0 - Self.smoothstep(threshold * 1.1, threshold * 2.4, peakDiff)
                            let w = wAvg * wEnd
                            acc += pairAvg * w
                            weightSum += w
                        }
                    }
                }

                let smoothed = acc / weightSum
                let blend = strength * (1.0 - edgeFactor)
                var result = center + (smoothed - center) * blend

                // Only dither non-flat regions so pure solid backgrounds stay clean
                let nonFlatMask = Self.smoothstep(0.0005, 0.003, maxSpread)
                let tpdf = (h1 - h2) * ditherAmp * lsb * (1.0 - edgeFactor) * nonFlatMask
                result = result + SIMD3<Float>(repeating: tpdf)

                let rOut = UInt8((max(0.0, min(1.0, result.x)) * 255.0).rounded())
                let gOut = UInt8((max(0.0, min(1.0, result.y)) * 255.0).rounded())
                let bOut = UInt8((max(0.0, min(1.0, result.z)) * 255.0).rounded())
                outBase[outOff + 0] = bOut
                outBase[outOff + 1] = gOut
                outBase[outOff + 2] = rOut
                outBase[outOff + 3] = alpha
            }
        }
    }

    private func debandLumaPlaneCPU(
        width: Int,
        height: Int,
        frameIndex: Int,
        config: DebandConfig,
        lsbStep: Float,
        readSample: (Int, Int) -> Float,
        writeSample: (Int, Int, Float) -> Void
    ) {
        let strength = max(0.0, min(1.0, config.strength))
        let threshold = max(0.001, config.threshold)
        let edgeThresh = max(0.005, config.edgeThreshold)
        let ditherAmp = max(0.0, config.ditherAmplitude)
        let framePhase = Float(frameIndex % 4)
        let ox = 5.588238 * framePhase
        let oy = 7.131942 * framePhase

        @inline(__always)
        func clamped(_ x: Int, _ y: Int) -> Float {
            readSample(max(0, min(width - 1, x)), max(0, min(height - 1, y)))
        }

        for y in 0..<height {
            for x in 0..<width {
                let center = clamped(x, y)
                var edgeFactor: Float = 0.0
                if config.protectSharpEdges {
                    let g1 = abs(clamped(x + 1, y) - clamped(x - 1, y))
                    let g2 = abs(clamped(x, y + 1) - clamped(x, y - 1))
                    let g3 = abs(clamped(x + 2, y) - clamped(x - 2, y))
                    let g4 = abs(clamped(x, y + 2) - clamped(x, y - 2))
                    let maxG = max(max(g1, g2), max(g3, g4))
                    edgeFactor = Self.smoothstep(edgeThresh * 0.5, edgeThresh, maxG)
                }

                let h1 = Self.ignNoise(Float(x) + ox, Float(y) + oy)
                let h2 = Self.ignNoise(Float(x) + ox + 17.0, Float(y) + oy + 31.0)
                let baseAngle = h1 * Float.pi * 0.5
                let r1 = 5.0 + h2 * 7.0
                let r2 = 13.0 + h1 * 11.0

                var acc = center
                var weightSum: Float = 1.0
                var maxSpread: Float = 0.0

                for ring in 0..<2 {
                    let rad = (ring == 0) ? r1 : r2
                    for dir in 0..<4 {
                        let angle = baseAngle + Float(dir) * (Float.pi * 0.25)
                        let dx = Int((cosf(angle) * rad).rounded())
                        let dy = Int((sinf(angle) * rad).rounded())
                        let pPos = clamped(x + dx, y + dy)
                        let pNeg = clamped(x - dx, y - dy)
                        let pMidPos = clamped(x + dx / 2, y + dy / 2)
                        let pMidNeg = clamped(x - dx / 2, y - dy / 2)

                        let pairAvg = (pPos + pNeg) * 0.5
                        let avgDiff = abs(pairAvg - center)
                        let endDiff = max(abs(pPos - center), abs(pNeg - center))
                        let midDiff = max(abs(pMidPos - center), abs(pMidNeg - center))
                        let peakDiff = max(endDiff, midDiff)

                        if peakDiff > maxSpread {
                            maxSpread = peakDiff
                        }

                        if avgDiff < threshold && peakDiff < threshold * 2.4 {
                            let wAvg = 1.0 - Self.smoothstep(threshold * 0.25, threshold, avgDiff)
                            let wEnd = 1.0 - Self.smoothstep(threshold * 1.1, threshold * 2.4, peakDiff)
                            let w = wAvg * wEnd
                            acc += pairAvg * w
                            weightSum += w
                        }
                    }
                }

                let smoothed = acc / weightSum
                let blend = strength * (1.0 - edgeFactor)
                let nonFlatMask = Self.smoothstep(0.0005, 0.003, maxSpread)
                let tpdf = (h1 - h2) * ditherAmp * lsbStep * (1.0 - edgeFactor) * nonFlatMask
                let finalVal = center + (smoothed - center) * blend + tpdf
                writeSample(x, y, finalVal)
            }
        }
    }

    private static func ignNoise(_ x: Float, _ y: Float) -> Float {
        let dot = 0.06711056 * x + 0.00583715 * y
        let f1 = dot - floorf(dot)
        let scaled = 52.9829189 * f1
        return scaled - floorf(scaled)
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let denom = max(1e-6, edge1 - edge0)
        let t = max(0.0, min(1.0, (x - edge0) / denom))
        return t * t * (3.0 - 2.0 * t)
    }

    // MARK: - PixelBuffer Helpers

    internal static func createIOSurfacePixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType
    ) throws -> CVPixelBuffer {
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pbOut: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attrs as CFDictionary,
            &pbOut
        )
        guard status == kCVReturnSuccess, let pb = pbOut else {
            throw SafariumError.encode("CVPixelBufferCreate failed (\(status)) for \(width)x\(height)")
        }
        return pb
    }

    internal static func convertToBGRA8(_ input: CVPixelBuffer) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)
        let out = try createIOSurfacePixelBuffer(width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA)
        let ciImage = CIImage(cvPixelBuffer: input)
        let ctx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])
        ctx.render(ciImage, to: out)
        CVBufferPropagateAttachments(input, out)
        return out
    }

    // MARK: - Embedded Runtime-Compiled Metal Shading Language (MSL)

    private static let mslSource: String = """
    #include <metal_stdlib>
    using namespace metal;

    struct DebandUniforms {
        uint width;
        uint height;
        uint frameIndex;
        uint protectSharpEdges;
        float strength;
        float threshold;
        float ditherAmplitude;
        float edgeThreshold;
        float lsbStep;
        uint isP010;
        uint pad0;
        uint pad1;
    };

    inline float ign(float2 p) {
        return fract(52.9829189f * fract(dot(p, float2(0.06711056f, 0.00583715f))));
    }

    inline float maxChanDiff(float3 a, float3 b) {
        float3 d = abs(a - b);
        return max(d.x, max(d.y, d.z));
    }

    inline uint2 clampCoord(int2 p, uint w, uint h) {
        return uint2(clamp(p.x, 0, int(w) - 1), clamp(p.y, 0, int(h) - 1));
    }

    kernel void safarium_deband_bgra8(
        texture2d<float, access::read> srcTex [[texture(0)]],
        texture2d<float, access::write> dstTex [[texture(1)]],
        constant DebandUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= u.width || gid.y >= u.height) { return; }

        int2 pos = int2(gid);
        float4 center4 = srcTex.read(gid);
        float3 center = center4.rgb;

        float edgeFactor = 0.0f;
        if (u.protectSharpEdges != 0u) {
            float3 l1 = srcTex.read(clampCoord(pos + int2(-1, 0), u.width, u.height)).rgb;
            float3 r1 = srcTex.read(clampCoord(pos + int2( 1, 0), u.width, u.height)).rgb;
            float3 u1 = srcTex.read(clampCoord(pos + int2( 0,-1), u.width, u.height)).rgb;
            float3 d1 = srcTex.read(clampCoord(pos + int2( 0, 1), u.width, u.height)).rgb;
            float3 l2 = srcTex.read(clampCoord(pos + int2(-2, 0), u.width, u.height)).rgb;
            float3 r2 = srcTex.read(clampCoord(pos + int2( 2, 0), u.width, u.height)).rgb;
            float3 u2 = srcTex.read(clampCoord(pos + int2( 0,-2), u.width, u.height)).rgb;
            float3 d2 = srcTex.read(clampCoord(pos + int2( 0, 2), u.width, u.height)).rgb;

            float g1 = maxChanDiff(r1, l1);
            float g2 = maxChanDiff(d1, u1);
            float g3 = maxChanDiff(r2, l2);
            float g4 = maxChanDiff(d2, u2);
            float maxG = max(max(g1, g2), max(g3, g4));
            edgeFactor = smoothstep(u.edgeThreshold * 0.5f, u.edgeThreshold, maxG);
        }

        float framePhase = float(u.frameIndex % 4u);
        float2 pNoise = float2(gid) + float2(5.588238f, 7.131942f) * framePhase;
        float h1 = ign(pNoise);
        float h2 = ign(pNoise + float2(17.0f, 31.0f));

        float baseAngle = h1 * 1.5707963f;
        float radii[2] = { 5.0f + h2 * 7.0f, 13.0f + h1 * 11.0f };

        float3 acc = center;
        float weightSum = 1.0f;
        float maxSpread = 0.0f;

        for (int ring = 0; ring < 2; ++ring) {
            float rad = radii[ring];
            for (int dir = 0; dir < 4; ++dir) {
                float angle = baseAngle + float(dir) * 0.78539816f;
                int2 delta = int2(round(cos(angle) * rad), round(sin(angle) * rad));
                int2 halfDelta = delta / 2;

                float3 pPos = srcTex.read(clampCoord(pos + delta, u.width, u.height)).rgb;
                float3 pNeg = srcTex.read(clampCoord(pos - delta, u.width, u.height)).rgb;
                float3 mPos = srcTex.read(clampCoord(pos + halfDelta, u.width, u.height)).rgb;
                float3 mNeg = srcTex.read(clampCoord(pos - halfDelta, u.width, u.height)).rgb;

                float3 pairAvg = 0.5f * (pPos + pNeg);
                float avgDiff = maxChanDiff(pairAvg, center);
                float endDiff = max(maxChanDiff(pPos, center), maxChanDiff(pNeg, center));
                float midDiff = max(maxChanDiff(mPos, center), maxChanDiff(mNeg, center));
                float peakDiff = max(endDiff, midDiff);

                maxSpread = max(maxSpread, peakDiff);

                if (avgDiff < u.threshold && peakDiff < u.threshold * 2.4f) {
                    float wAvg = 1.0f - smoothstep(u.threshold * 0.25f, u.threshold, avgDiff);
                    float wEnd = 1.0f - smoothstep(u.threshold * 1.1f, u.threshold * 2.4f, peakDiff);
                    float w = wAvg * wEnd;
                    acc += pairAvg * w;
                    weightSum += w;
                }
            }
        }

        float3 smoothed = acc / weightSum;
        float blend = u.strength * (1.0f - edgeFactor);
        float nonFlatMask = smoothstep(0.0005f, 0.003f, maxSpread);
        float tpdf = (h1 - h2) * u.ditherAmplitude * u.lsbStep * (1.0f - edgeFactor) * nonFlatMask;
        float3 outRGB = clamp(mix(center, smoothed, blend) + float3(tpdf), 0.0f, 1.0f);

        dstTex.write(float4(outRGB, center4.a), gid);
    }

    inline float readLumaNorm(texture2d<float, access::read> tex, uint2 coord, uint isP010) {
        float raw = tex.read(coord).r;
        if (isP010 != 0u) {
            // P010 stores 10-bit code in upper 10 bits of 16-bit word: code10 = (raw * 65535) / 64
            return clamp((raw * 65535.0f / 64.0f) / 1023.0f, 0.0f, 1.0f);
        }
        return raw;
    }

    inline float encodeLumaNorm(float normVal, uint isP010) {
        float clamped = clamp(normVal, 0.0f, 1.0f);
        if (isP010 != 0u) {
            float code10 = round(clamped * 1023.0f);
            return (code10 * 64.0f) / 65535.0f;
        }
        return clamped;
    }

    kernel void safarium_deband_luma(
        texture2d<float, access::read> srcTex [[texture(0)]],
        texture2d<float, access::write> dstTex [[texture(1)]],
        constant DebandUniforms& u [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= u.width || gid.y >= u.height) { return; }

        int2 pos = int2(gid);
        float center = readLumaNorm(srcTex, gid, u.isP010);

        float edgeFactor = 0.0f;
        if (u.protectSharpEdges != 0u) {
            float l1 = readLumaNorm(srcTex, clampCoord(pos + int2(-1, 0), u.width, u.height), u.isP010);
            float r1 = readLumaNorm(srcTex, clampCoord(pos + int2( 1, 0), u.width, u.height), u.isP010);
            float u1 = readLumaNorm(srcTex, clampCoord(pos + int2( 0,-1), u.width, u.height), u.isP010);
            float d1 = readLumaNorm(srcTex, clampCoord(pos + int2( 0, 1), u.width, u.height), u.isP010);
            float l2 = readLumaNorm(srcTex, clampCoord(pos + int2(-2, 0), u.width, u.height), u.isP010);
            float r2 = readLumaNorm(srcTex, clampCoord(pos + int2( 2, 0), u.width, u.height), u.isP010);
            float u2 = readLumaNorm(srcTex, clampCoord(pos + int2( 0,-2), u.width, u.height), u.isP010);
            float d2 = readLumaNorm(srcTex, clampCoord(pos + int2( 0, 2), u.width, u.height), u.isP010);

            float maxG = max(max(abs(r1 - l1), abs(d1 - u1)), max(abs(r2 - l2), abs(d2 - u2)));
            edgeFactor = smoothstep(u.edgeThreshold * 0.5f, u.edgeThreshold, maxG);
        }

        float framePhase = float(u.frameIndex % 4u);
        float2 pNoise = float2(gid) + float2(5.588238f, 7.131942f) * framePhase;
        float h1 = ign(pNoise);
        float h2 = ign(pNoise + float2(17.0f, 31.0f));

        float baseAngle = h1 * 1.5707963f;
        float radii[2] = { 5.0f + h2 * 7.0f, 13.0f + h1 * 11.0f };

        float acc = center;
        float weightSum = 1.0f;
        float maxSpread = 0.0f;

        for (int ring = 0; ring < 2; ++ring) {
            float rad = radii[ring];
            for (int dir = 0; dir < 4; ++dir) {
                float angle = baseAngle + float(dir) * 0.78539816f;
                int2 delta = int2(round(cos(angle) * rad), round(sin(angle) * rad));
                int2 halfDelta = delta / 2;

                float pPos = readLumaNorm(srcTex, clampCoord(pos + delta, u.width, u.height), u.isP010);
                float pNeg = readLumaNorm(srcTex, clampCoord(pos - delta, u.width, u.height), u.isP010);
                float mPos = readLumaNorm(srcTex, clampCoord(pos + halfDelta, u.width, u.height), u.isP010);
                float mNeg = readLumaNorm(srcTex, clampCoord(pos - halfDelta, u.width, u.height), u.isP010);

                float pairAvg = 0.5f * (pPos + pNeg);
                float avgDiff = abs(pairAvg - center);
                float peakDiff = max(max(abs(pPos - center), abs(pNeg - center)),
                                     max(abs(mPos - center), abs(mNeg - center)));

                maxSpread = max(maxSpread, peakDiff);

                if (avgDiff < u.threshold && peakDiff < u.threshold * 2.4f) {
                    float wAvg = 1.0f - smoothstep(u.threshold * 0.25f, u.threshold, avgDiff);
                    float wEnd = 1.0f - smoothstep(u.threshold * 1.1f, u.threshold * 2.4f, peakDiff);
                    float w = wAvg * wEnd;
                    acc += pairAvg * w;
                    weightSum += w;
                }
            }
        }

        float smoothed = acc / weightSum;
        float blend = u.strength * (1.0f - edgeFactor);
        float nonFlatMask = smoothstep(0.0005f, 0.003f, maxSpread);
        float tpdf = (h1 - h2) * u.ditherAmplitude * u.lsbStep * (1.0f - edgeFactor) * nonFlatMask;
        float finalNorm = mix(center, smoothed, blend) + tpdf;
        float encoded = encodeLumaNorm(finalNorm, u.isP010);

        dstTex.write(float4(encoded, 0.0f, 0.0f, 1.0f), gid);
    }

    kernel void safarium_copy_chroma(
        texture2d<float, access::read> srcTex [[texture(0)]],
        texture2d<float, access::write> dstTex [[texture(1)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= dstTex.get_width() || gid.y >= dstTex.get_height()) { return; }
        dstTex.write(srcTex.read(gid), gid);
    }
    """
}

// MARK: - Wave 15D-B: Hardware Super-Resolution / MetalFX / CoreImage Lanczos Upscaler

/// Configuration for `HardwareUpscaler`.
public struct UpscaleConfig: Codable, Sendable, Equatable {
    public var targetWidth: Int
    public var targetHeight: Int
    public var useHardwareSR: Bool
    public var sharpenAmount: Float

    public init(
        targetWidth: Int,
        targetHeight: Int,
        useHardwareSR: Bool = true,
        sharpenAmount: Float = 0.25
    ) {
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
        self.useHardwareSR = useHardwareSR
        self.sharpenAmount = sharpenAmount
    }
}

/// Native Apple Silicon upscaler attempting `VTFrameProcessor` Low-Latency Super-Resolution (macOS 26+),
/// then `MetalFX` Spatial Scaler (macOS 14+), with a deterministic high-quality `CoreImage` Lanczos
/// (`CILanczosScaleTransform` + subtle `CISharpenLuminance`) fallback.
public enum HardwareUpscaler {

    /// Upscales `pixelBuffer` to `(config.targetWidth, config.targetHeight)`.
    public static func upscale(pixelBuffer: CVPixelBuffer, config: UpscaleConfig) throws -> CVPixelBuffer {
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let dstW = config.targetWidth
        let dstH = config.targetHeight

        guard srcW > 0, srcH > 0, dstW > 0, dstH > 0 else {
            throw SafariumError.invalidState("HardwareUpscaler: invalid dimensions \(srcW)x\(srcH) -> \(dstW)x\(dstH)")
        }

        if config.useHardwareSR && dstW > srcW && dstH > srcH {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                if let vtOut = tryVTFrameProcessorSR(pixelBuffer: pixelBuffer, config: config) {
                    return vtOut
                }
            }
            #endif

            #if canImport(MetalFX)
            if let mfxOut = tryMetalFXSpatialUpscale(pixelBuffer: pixelBuffer, config: config) {
                return mfxOut
            }
            #endif
        }

        return try upscaleCoreImageLanczos(pixelBuffer: pixelBuffer, config: config)
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private static func tryVTFrameProcessorSR(
        pixelBuffer: CVPixelBuffer,
        config: UpscaleConfig
    ) -> CVPixelBuffer? {
        guard VTLowLatencySuperResolutionScalerConfiguration.isSupported else {
            return nil
        }

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let scaleX = Float(config.targetWidth) / Float(srcW)
        let scaleY = Float(config.targetHeight) / Float(srcH)
        guard abs(scaleX - scaleY) < 0.005 else {
            return nil
        }

        let supportedFactors = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(
            frameWidth: srcW,
            frameHeight: srcH
        )
        guard let matchedScale = supportedFactors.first(where: { abs($0 - scaleX) < 0.01 }) else {
            return nil
        }

        let srConfig = VTLowLatencySuperResolutionScalerConfiguration(
            frameWidth: srcW,
            frameHeight: srcH,
            scaleFactor: matchedScale
        )

        let srcAttrs = srConfig.sourcePixelBufferAttributes as CFDictionary
        let dstAttrs = srConfig.destinationPixelBufferAttributes as CFDictionary

        var resolvedSrcPB: CVPixelBuffer = pixelBuffer
        let supportedFormats = srConfig.supportedPixelFormats
        let currentFmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if !supportedFormats.contains(currentFmt) {
            guard let targetFmt = supportedFormats.first,
                  let converted = try? convertPixelBufferWithAttributes(
                    pixelBuffer,
                    width: srcW,
                    height: srcH,
                    pixelFormat: targetFmt,
                    extraAttributes: srcAttrs
                  )
            else {
                return nil
            }
            resolvedSrcPB = converted
        }

        var dstPBOut: CVPixelBuffer?
        let dstFmt = CVPixelBufferGetPixelFormatType(resolvedSrcPB)
        var baseAttrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        if let extra = dstAttrs as? [String: Any] {
            for (k, v) in extra {
                baseAttrs[k] = v
            }
        }
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            config.targetWidth,
            config.targetHeight,
            dstFmt,
            baseAttrs as CFDictionary,
            &dstPBOut
        )
        guard status == kCVReturnSuccess, let dstPB = dstPBOut else {
            return nil
        }

        let processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: srConfig)
            defer { processor.endSession() }
            guard let srcFrame = VTFrameProcessorFrame(buffer: resolvedSrcPB, presentationTimeStamp: .zero),
                  let dstFrame = VTFrameProcessorFrame(buffer: dstPB, presentationTimeStamp: .zero)
            else {
                return nil
            }
            let params = VTLowLatencySuperResolutionScalerParameters(
                sourceFrame: srcFrame,
                destinationFrame: dstFrame
            )
            try processor.process(parameters: params)
            CVBufferPropagateAttachments(pixelBuffer, dstPB)
            if config.sharpenAmount > 0.01 {
                return try? applySubtleSharpen(to: dstPB, amount: config.sharpenAmount)
            }
            return dstPB
        } catch {
            return nil
        }
    }

    private static func convertPixelBufferWithAttributes(
        _ input: CVPixelBuffer,
        width: Int,
        height: Int,
        pixelFormat: OSType,
        extraAttributes: CFDictionary
    ) throws -> CVPixelBuffer {
        var attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        if let extra = extraAttributes as? [String: Any] {
            for (k, v) in extra {
                attrs[k] = v
            }
        }
        var outPB: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attrs as CFDictionary, &outPB)
        guard status == kCVReturnSuccess, let out = outPB else {
            throw SafariumError.encode("CVPixelBufferCreate failed (\(status))")
        }
        let ctx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])
        ctx.render(CIImage(cvPixelBuffer: input), to: out)
        CVBufferPropagateAttachments(input, out)
        return out
    }
    #endif

    #if canImport(MetalFX)
    private static func tryMetalFXSpatialUpscale(
        pixelBuffer: CVPixelBuffer,
        config: UpscaleConfig
    ) -> CVPixelBuffer? {
        guard let metalCtx = SafariumMetalContext.shared else {
            return nil
        }
        let device = metalCtx.device
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else {
            return nil
        }

        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let dstW = config.targetWidth
        let dstH = config.targetHeight

        let bgraInput: CVPixelBuffer
        if CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA {
            bgraInput = pixelBuffer
        } else {
            guard let converted = try? MetalDebandFilter.convertToBGRA8(pixelBuffer) else {
                return nil
            }
            bgraInput = converted
        }

        let desc = MTLFXSpatialScalerDescriptor()
        desc.colorTextureFormat = .bgra8Unorm
        desc.outputTextureFormat = .bgra8Unorm
        desc.inputWidth = srcW
        desc.inputHeight = srcH
        desc.outputWidth = dstW
        desc.outputHeight = dstH
        desc.colorProcessingMode = .perceptual

        guard let scaler = desc.makeSpatialScaler(device: device) else {
            return nil
        }

        let privDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: dstW,
            height: dstH,
            mipmapped: false
        )
        privDesc.storageMode = .private
        privDesc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let privTex = device.makeTexture(descriptor: privDesc) else {
            return nil
        }

        guard let outPB = try? MetalDebandFilter.createIOSurfacePixelBuffer(
            width: dstW,
            height: dstH,
            pixelFormat: kCVPixelFormatType_32BGRA
        ) else {
            return nil
        }

        guard let (inCV, inTex) = try? metalCtx.bindBGRA8Texture(for: bgraInput),
              let (outCV, outTex) = try? metalCtx.bindBGRA8Texture(for: outPB),
              let cmd = metalCtx.commandQueue.makeCommandBuffer()
        else {
            return nil
        }

        scaler.colorTexture = inTex
        scaler.inputContentWidth = srcW
        scaler.inputContentHeight = srcH
        scaler.outputTexture = privTex
        scaler.encode(commandBuffer: cmd)

        guard let blit = cmd.makeBlitCommandEncoder() else {
            return nil
        }
        blit.copy(
            from: privTex,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: dstW, height: dstH, depth: 1),
            to: outTex,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()

        cmd.commit()
        cmd.waitUntilCompleted()
        _ = (inCV, outCV)
        metalCtx.flushTextureCache()

        guard cmd.error == nil else {
            return nil
        }
        CVBufferPropagateAttachments(pixelBuffer, outPB)

        if config.sharpenAmount > 0.01 {
            if let sharpened = try? applySubtleSharpen(to: outPB, amount: config.sharpenAmount) {
                return sharpened
            }
        }
        return outPB
    }
    #endif

    private static func applySubtleSharpen(to input: CVPixelBuffer, amount: Float) throws -> CVPixelBuffer {
        let width = CVPixelBufferGetWidth(input)
        let height = CVPixelBufferGetHeight(input)
        let format = CVPixelBufferGetPixelFormatType(input)
        let outPB = try MetalDebandFilter.createIOSurfacePixelBuffer(width: width, height: height, pixelFormat: format)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        let ciInput = CIImage(cvPixelBuffer: input).clampedToExtent()
        let sharpened = ciInput
            .applyingFilter("CISharpenLuminance", parameters: [
                kCIInputSharpnessKey: Double(max(0.0, min(1.0, amount))),
                "inputRadius": 1.2,
            ])
            .cropped(to: bounds)

        let ctx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])
        ctx.render(sharpened, to: outPB)
        CVBufferPropagateAttachments(input, outPB)
        return outPB
    }

    private static func upscaleCoreImageLanczos(
        pixelBuffer: CVPixelBuffer,
        config: UpscaleConfig
    ) throws -> CVPixelBuffer {
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        let dstW = config.targetWidth
        let dstH = config.targetHeight

        let outPB = try MetalDebandFilter.createIOSurfacePixelBuffer(
            width: dstW,
            height: dstH,
            pixelFormat: kCVPixelFormatType_32BGRA
        )

        let scaleY = Double(dstH) / Double(srcH)
        let srcAspect = Double(srcW) / Double(srcH)
        let dstAspect = Double(dstW) / Double(dstH)
        let aspectRatio = dstAspect / max(1e-6, srcAspect)
        let targetRect = CGRect(x: 0, y: 0, width: dstW, height: dstH)

        var image = CIImage(cvPixelBuffer: pixelBuffer)
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scaleY,
                kCIInputAspectRatioKey: aspectRatio,
            ])
            .cropped(to: targetRect)

        if config.sharpenAmount > 0.01 {
            image = image
                .clampedToExtent()
                .applyingFilter("CISharpenLuminance", parameters: [
                    kCIInputSharpnessKey: Double(max(0.0, min(1.0, config.sharpenAmount))),
                    "inputRadius": 1.2,
                ])
                .cropped(to: targetRect)
        }

        let ctx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])
        ctx.render(image, to: outPB, bounds: targetRect, colorSpace: Snapshot.colorSpace)
        CVBufferPropagateAttachments(pixelBuffer, outPB)
        return outPB
    }
}

// MARK: - Wave 15D-C: End-to-End Native Video Enhancement Pipeline

/// Options for `EnhancementPipeline.enhanceVideo`.
public struct EnhanceVideoOptions: Codable, Sendable, Equatable {
    public var deband: Bool
    public var debandConfig: DebandConfig
    public var upscaleWidth: Int?
    public var upscaleHeight: Int?
    public var codec: VideoCodec
    public var bitrate: Int?

    public init(
        deband: Bool = true,
        debandConfig: DebandConfig = DebandConfig(),
        upscaleWidth: Int? = nil,
        upscaleHeight: Int? = nil,
        codec: VideoCodec = .hevc10,
        bitrate: Int? = nil
    ) {
        self.deband = deband
        self.debandConfig = debandConfig
        self.upscaleWidth = upscaleWidth
        self.upscaleHeight = upscaleHeight
        self.codec = codec
        self.bitrate = bitrate
    }
}

/// Telemetry and CAMBI delta report returned by `EnhancementPipeline.enhanceVideo`.
public struct EnhanceVideoReport: Codable, Sendable, Equatable {
    public let framesProcessed: Int
    public let beforeCAMBI: Double
    public let afterCAMBI: Double
    public let cambiReductionPct: Double
    public let usedMetalDeband: Bool
    public let upscaledTo: String?
    public let elapsedMs: Double
    public let outputPath: String

    public init(
        framesProcessed: Int,
        beforeCAMBI: Double,
        afterCAMBI: Double,
        cambiReductionPct: Double,
        usedMetalDeband: Bool,
        upscaledTo: String?,
        elapsedMs: Double,
        outputPath: String
    ) {
        self.framesProcessed = framesProcessed
        self.beforeCAMBI = beforeCAMBI
        self.afterCAMBI = afterCAMBI
        self.cambiReductionPct = cambiReductionPct
        self.usedMetalDeband = usedMetalDeband
        self.upscaledTo = upscaledTo
        self.elapsedMs = elapsedMs
        self.outputPath = outputPath
    }
}

/// End-to-end 100% Apple-native video enhancement pipeline (AVAssetReader -> MetalDebandFilter ->
/// HardwareUpscaler -> AVAssetWriter) with integrated before/after `NativeCAMBI` measurement.
public enum EnhancementPipeline {

    /// Enhances a video file natively with optional GPU debanding, upscaling, and VideoToolbox re-encoding.
    public static func enhanceVideo(
        inputURL: URL,
        outputURL: URL,
        options: EnhanceVideoOptions = EnhanceVideoOptions()
    ) async throws -> EnhanceVideoReport {
        let startTime = CFAbsoluteTimeGetCurrent()

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw SafariumError.invalidState("EnhancementPipeline: input file missing at \(inputURL.path)")
        }

        let parentDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let asset = AVURLAsset(url: inputURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw SafariumError.encode("EnhancementPipeline: no video track in \(inputURL.path)")
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let nominalFPS = Double(try await videoTrack.load(.nominalFrameRate))
        let srcW = max(2, Int(naturalSize.width.rounded()))
        let srcH = max(2, Int(naturalSize.height.rounded()))

        let dstW: Int
        let dstH: Int
        let needsUpscale: Bool
        if let uw = options.upscaleWidth, let uh = options.upscaleHeight, uw > 0, uh > 0 {
            dstW = uw
            dstH = uh
            needsUpscale = (uw != srcW || uh != srcH)
        } else if let uw = options.upscaleWidth, uw > 0 {
            let scaledH = max(2, Int((Double(srcH) * Double(uw) / Double(srcW)).rounded()))
            dstW = uw
            dstH = scaledH - (scaledH % 2)
            needsUpscale = (dstW != srcW || dstH != srcH)
        } else if let uh = options.upscaleHeight, uh > 0 {
            let scaledW = max(2, Int((Double(srcW) * Double(uh) / Double(srcH)).rounded()))
            dstW = scaledW - (scaledW % 2)
            dstH = uh
            needsUpscale = (dstW != srcW || dstH != srcH)
        } else {
            dstW = srcW
            dstH = srcH
            needsUpscale = false
        }

        // Choose P010 directly when targeting 10-bit without BGRA upscale; otherwise BGRA8
        let readerFormat: OSType = (options.codec.is10Bit && !needsUpscale)
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_32BGRA

        let reader = try AVAssetReader(asset: asset)
        let readerOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(readerFormat),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let videoReaderOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: readerOutputSettings)
        videoReaderOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoReaderOutput) else {
            throw SafariumError.encode("EnhancementPipeline: cannot attach video reader output")
        }
        reader.add(videoReaderOutput)

        // Optional audio passthrough
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioReaderOutput: AVAssetReaderTrackOutput?
        if let audioTrack = audioTracks.first {
            let ao = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            if reader.canAdd(ao) {
                reader.add(ao)
                audioReaderOutput = ao
            }
        }

        let ext = outputURL.pathExtension.lowercased()
        let fileType: AVFileType = (options.codec.isProRes || ext == "mov") ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)

        let videoSettings = buildVideoOutputSettings(
            codec: options.codec,
            width: dstW,
            height: dstH,
            fps: max(1.0, nominalFPS),
            bitrate: options.bitrate
        )
        let videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput.expectsMediaDataInRealTime = false

        let adaptorPixelFormat: OSType = needsUpscale ? kCVPixelFormatType_32BGRA : readerFormat
        let adaptorAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(adaptorPixelFormat),
            kCVPixelBufferWidthKey as String: dstW,
            kCVPixelBufferHeightKey as String: dstH,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoWriterInput,
            sourcePixelBufferAttributes: adaptorAttrs
        )

        guard writer.canAdd(videoWriterInput) else {
            throw SafariumError.encode("EnhancementPipeline: cannot attach video writer input for codec \(options.codec)")
        }
        writer.add(videoWriterInput)

        var audioWriterInput: AVAssetWriterInput?
        if audioReaderOutput != nil {
            let awi = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            awi.expectsMediaDataInRealTime = false
            if writer.canAdd(awi) {
                writer.add(awi)
                audioWriterInput = awi
            }
        }

        guard reader.startReading() else {
            let msg = reader.error?.localizedDescription ?? "unknown reader start failure"
            throw SafariumError.encode("EnhancementPipeline: AVAssetReader start failed: \(msg)")
        }
        guard writer.startWriting() else {
            let msg = writer.error?.localizedDescription ?? "unknown writer start failure"
            throw SafariumError.encode("EnhancementPipeline: AVAssetWriter start failed: \(msg)")
        }
        writer.startSession(atSourceTime: .zero)

        let debandFilter = MetalDebandFilter.shared
        let upscaleCfg = UpscaleConfig(targetWidth: dstW, targetHeight: dstH, useHardwareSR: true, sharpenAmount: 0.25)

        var framesProcessed = 0
        var beforeCAMBISum: Double = 0.0
        var afterCAMBISum: Double = 0.0
        var cambiSamples = 0

        while let sampleBuffer = videoReaderOutput.copyNextSampleBuffer() {
            guard let srcPB = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            // Sample CAMBI on evenly distributed frames (every frame for short clips, strided for long clips)
            let shouldSampleCAMBI = (framesProcessed < 16) || (framesProcessed % 8 == 0)
            if shouldSampleCAMBI {
                let before = NativeCAMBI.measure(pixelBuffer: srcPB)
                beforeCAMBISum += before.cambiScore
            }

            var currentPB = srcPB
            if options.deband {
                currentPB = try debandFilter.process(
                    input: currentPB,
                    frameIndex: framesProcessed,
                    config: options.debandConfig
                )
            }

            if needsUpscale {
                currentPB = try HardwareUpscaler.upscale(pixelBuffer: currentPB, config: upscaleCfg)
            }

            if shouldSampleCAMBI {
                let after = NativeCAMBI.measure(pixelBuffer: currentPB)
                afterCAMBISum += after.cambiScore
                cambiSamples += 1
            }

            while !videoWriterInput.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
                if writer.status == .failed || writer.status == .cancelled {
                    let msg = writer.error?.localizedDescription ?? "writer failed during append"
                    throw SafariumError.encode("EnhancementPipeline: \(msg)")
                }
            }

            guard adaptor.append(currentPB, withPresentationTime: pts) else {
                let msg = writer.error?.localizedDescription ?? "adaptor.append returned false"
                throw SafariumError.encode("EnhancementPipeline: frame \(framesProcessed) append failed: \(msg)")
            }
            framesProcessed += 1
        }

        videoWriterInput.markAsFinished()

        if let ao = audioReaderOutput, let awi = audioWriterInput {
            while let audioSample = ao.copyNextSampleBuffer() {
                while !awi.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                awi.append(audioSample)
            }
            awi.markAsFinished()
        }

        await writer.finishWriting()
        if writer.status != .completed {
            let msg = writer.error?.localizedDescription ?? "writer status=\(writer.status.rawValue)"
            throw SafariumError.encode("EnhancementPipeline: finishWriting failed: \(msg)")
        }

        let beforeMean = cambiSamples > 0 ? (beforeCAMBISum / Double(cambiSamples)) : 0.0
        let afterMean = cambiSamples > 0 ? (afterCAMBISum / Double(cambiSamples)) : 0.0
        let reductionPct: Double
        if beforeMean > 1e-6 {
            reductionPct = ((beforeMean - afterMean) / beforeMean) * 100.0
        } else {
            reductionPct = 0.0
        }

        let elapsedMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
        let upscaledLabel: String? = needsUpscale ? "\(dstW)x\(dstH)" : nil

        return EnhanceVideoReport(
            framesProcessed: framesProcessed,
            beforeCAMBI: beforeMean,
            afterCAMBI: afterMean,
            cambiReductionPct: reductionPct,
            usedMetalDeband: options.deband && debandFilter.isUsingMetal,
            upscaledTo: upscaledLabel,
            elapsedMs: elapsedMs,
            outputPath: outputURL.path
        )
    }

    private static func buildVideoOutputSettings(
        codec: VideoCodec,
        width: Int,
        height: Int,
        fps: Double,
        bitrate: Int?
    ) -> [String: Any] {
        var settings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]

        if !codec.isProRes {
            let autoBitrate = max(2_500_000, Int(Double(width * height) * max(1.0, fps) * 0.25))
            let targetBitrate = bitrate ?? autoBitrate
            var compProps: [String: Any] = [
                AVVideoAverageBitRateKey: targetBitrate,
                AVVideoExpectedSourceFrameRateKey: fps,
            ]
            switch codec {
            case .h264:
                compProps[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            case .hevc:
                compProps[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
            case .hevc10, .hevc44410:
                compProps[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel as String
            case .hevc42210:
                compProps[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main42210_AutoLevel as String
            default:
                break
            }
            settings[AVVideoCompressionPropertiesKey] = compProps
        }

        return settings
    }
}

// MARK: - Wave 15D-D: Future Apple Silicon Hardware AV1 Encode Readiness Hook

/// Honest live capability report for future Apple Silicon hardware AV1 (`av01`) encoding.
public struct FutureCodecReadinessReport: Codable, Sendable, Equatable {
    public let codecFourCC: String
    public let codecName: String
    /// Honest live VideoToolbox probe result (`false` on M1–M5, auto-`true` when Apple Silicon ships HW `av01` encode).
    public let hardwareEncodeSupported: Bool
    /// Whether any software AV1 VideoToolbox encoder is registered.
    public let softwareEncodeSupported: Bool
    /// Whether this Mac supports hardware-accelerated AV1 decode (`VTIsHardwareDecodeSupported('av01')`).
    public let hardwareDecodeSupported: Bool
    public let encoderID: String?
    public let displayName: String?
    public let supportsMain10: Bool
    public let chipName: String
    public let machineModel: String
    public let osVersion: String
    /// Readiness state: `"ready_hardware"`, `"software_only"`, or `"awaiting_silicon_hw_av1_encoder"`.
    public let status: String
    public let recommendedFallbackCodec: String
    public let autoEnableWhenAvailable: Bool
    public let summary: String

    public init(
        codecFourCC: String,
        codecName: String,
        hardwareEncodeSupported: Bool,
        softwareEncodeSupported: Bool,
        hardwareDecodeSupported: Bool,
        encoderID: String?,
        displayName: String?,
        supportsMain10: Bool,
        chipName: String,
        machineModel: String,
        osVersion: String,
        status: String,
        recommendedFallbackCodec: String,
        autoEnableWhenAvailable: Bool,
        summary: String
    ) {
        self.codecFourCC = codecFourCC
        self.codecName = codecName
        self.hardwareEncodeSupported = hardwareEncodeSupported
        self.softwareEncodeSupported = softwareEncodeSupported
        self.hardwareDecodeSupported = hardwareDecodeSupported
        self.encoderID = encoderID
        self.displayName = displayName
        self.supportsMain10 = supportsMain10
        self.chipName = chipName
        self.machineModel = machineModel
        self.osVersion = osVersion
        self.status = status
        self.recommendedFallbackCodec = recommendedFallbackCodec
        self.autoEnableWhenAvailable = autoEnableWhenAvailable
        self.summary = summary
    }
}

/// Live probe hook that detects VideoToolbox hardware `av01` encoding without hardcoding chip generations.
public enum FutureCodecReadiness {
    private static let av1FourCC: CMVideoCodecType = 0x61763031 // 'av01'

    /// Probes the current Apple Silicon Mac for live hardware AV1 (`av01`) encode and decode support.
    public static func probeAV1Readiness(useCache: Bool = true) -> FutureCodecReadinessReport {
        let snapshot = EncoderCapabilityProfiler.probeLive(useCache: useCache)
        let av1Profile = snapshot.profile(for: "av01")
        let hwEncode = av1Profile?.hardwareAccelerated ?? false
        let swEncode = av1Profile?.isSoftwareFallback ?? false
        let hwDecode = VTIsHardwareDecodeSupported(av1FourCC)

        let status: String
        let summary: String
        if hwEncode {
            status = "ready_hardware"
            summary = "Hardware VideoToolbox AV1 ('av01') encoder detected on \(snapshot.chipName) (\(snapshot.osVersion)); auto-enabled."
        } else if swEncode {
            status = "software_only"
            summary = "Only software VideoToolbox AV1 ('av01') encoder detected on \(snapshot.chipName); hardware AV1 encode unavailable — recommend HEVC Main10 ('hvc1')."
        } else {
            status = "awaiting_silicon_hw_av1_encoder"
            summary = "No VideoToolbox AV1 ('av01') hardware encoder on \(snapshot.chipName) (hwDecode=\(hwDecode)); fallback to HEVC Main10 ('hvc1'), auto-ready for future Apple Silicon."
        }

        return FutureCodecReadinessReport(
            codecFourCC: "av01",
            codecName: "AV1",
            hardwareEncodeSupported: hwEncode,
            softwareEncodeSupported: swEncode,
            hardwareDecodeSupported: hwDecode,
            encoderID: av1Profile?.encoderID,
            displayName: av1Profile?.displayName,
            supportsMain10: av1Profile?.supportsMain10 ?? false,
            chipName: snapshot.chipName,
            machineModel: snapshot.machineModel,
            osVersion: snapshot.osVersion,
            status: status,
            recommendedFallbackCodec: "hvc1",
            autoEnableWhenAvailable: true,
            summary: summary
        )
    }
}
