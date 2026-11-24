import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal

/// Shared Metal + CVMetalTextureCache + CoreImage context configured for bounded RAM.
/// Reusing one CIContext with `.cacheIntermediates: false` eliminates per-frame GPU cache leaks.
public final class SafariumMetalContext: @unchecked Sendable {
    public static let shared: SafariumMetalContext? = SafariumMetalContext.createDefault()

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let textureCache: CVMetalTextureCache
    public let ciContext: CIContext

    private static func createDefault() -> SafariumMetalContext? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let textureCache = cache else {
            return nil
        }
        return SafariumMetalContext(device: device, commandQueue: queue, textureCache: textureCache)
    }

    private init(device: MTLDevice, commandQueue: MTLCommandQueue, textureCache: CVMetalTextureCache) {
        self.device = device
        self.commandQueue = commandQueue
        self.textureCache = textureCache

        var opts: [CIContextOption: Any] = [
            .workingColorSpace: Snapshot.colorSpace,
            .outputColorSpace: Snapshot.colorSpace,
            .cacheIntermediates: false,
            .priorityRequestLow: false,
            .memoryTarget: 32,
        ]
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            opts[.cvMetalTextureCache] = textureCache
        }
        #endif
        self.ciContext = CIContext(mtlCommandQueue: commandQueue, options: opts)
    }

    public func flushTextureCache() {
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    public func bindBGRA8Texture(for pixelBuffer: CVPixelBuffer) throws -> (CVMetalTexture, MTLTexture) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        var cvTex: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &cvTex
        )
        guard status == kCVReturnSuccess, let cvTex, let mtlTex = CVMetalTextureGetTexture(cvTex) else {
            throw SafariumError.encode("CVMetalTextureCacheCreateTextureFromImage failed (\(status))")
        }
        return (cvTex, mtlTex)
    }
}
