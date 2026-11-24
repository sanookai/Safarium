import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import WebKit

public struct HybridSceneParams: Sendable {
    public var panX: Double
    public var panY: Double
    public var spotCenterCSS: CGPoint
    public var spotInnerR: Double
    public var spotOuterR: Double
    public var spotTintRGBA: (CGFloat, CGFloat, CGFloat, CGFloat)
    public var shadowOffsetCSS: CGPoint
    public var shadowSigma: Double
    public var shadowColorRGBA: (CGFloat, CGFloat, CGFloat, CGFloat)

    public init(
        panX: Double = 0,
        panY: Double = 0,
        spotCenterCSS: CGPoint = .zero,
        spotInnerR: Double = 240,
        spotOuterR: Double = 700,
        spotTintRGBA: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0),
        shadowOffsetCSS: CGPoint = .zero,
        shadowSigma: Double = 0,
        shadowColorRGBA: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
    ) {
        self.panX = panX
        self.panY = panY
        self.spotCenterCSS = spotCenterCSS
        self.spotInnerR = spotInnerR
        self.spotOuterR = spotOuterR
        self.spotTintRGBA = spotTintRGBA
        self.shadowOffsetCSS = shadowOffsetCSS
        self.shadowSigma = shadowSigma
        self.shadowColorRGBA = shadowColorRGBA
    }
}

public struct HybridRenderReport: Codable, Sendable {
    public let htmlPath: String?
    public let videoPath: String?
    public let outputPath: String
    public let width: Int
    public let height: Int
    public let fps: Int
    public let frames: Int
    public let codec: String
    public let fileSizeBytes: Int64
}

/// Zero-copy Metal + Core Image hybrid compositor backed by `SafariumMetalContext.shared`.
/// Composites static plates, sequential video frames, spotlight vignettes, drop shadows, and transparent WebKit overlays
/// directly into IOSurface `CVPixelBuffer` targets without intermediate caching.
public final class SafariumHybridCompositor {
    public let context: SafariumMetalContext
    private var staticPlateTexture: MTLTexture?
    private var staticPlateImage: CIImage?
    private var staticPlateSize: (Int, Int) = (0, 0)

    public init(context: SafariumMetalContext? = SafariumMetalContext.shared) throws {
        guard let ctx = context else {
            throw SafariumError.encode("Metal GPU context unavailable for SafariumHybridCompositor")
        }
        self.context = ctx
    }

    deinit {
        staticPlateTexture = nil
        staticPlateImage = nil
        context.flushTextureCache()
    }

    @MainActor
    public func captureStaticPlate(page: Page, width: Int, height: Int, usePDF: Bool = false) async throws {
        let cgPlate: CGImage
        if usePDF {
            let pdfCfg = WKPDFConfiguration()
            pdfCfg.rect = CGRect(x: 0, y: 0, width: page.config.width, height: page.config.height)
            let pdfData = try await page.webView.pdf(configuration: pdfCfg)
            guard let provider = CGDataProvider(data: pdfData as CFData),
                  let doc = CGPDFDocument(provider),
                  let pdfPage = doc.page(at: 1) else {
                throw SafariumError.snapshot("failed to parse PDF plate")
            }
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            guard let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: Snapshot.colorSpace, bitmapInfo: Snapshot.bitmapInfo
            ) else {
                throw SafariumError.snapshot("failed to allocate PDF raster context")
            }
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(rect)
            let mediaBox = pdfPage.getBoxRect(.mediaBox)
            ctx.scaleBy(x: CGFloat(width) / max(1, mediaBox.width), y: CGFloat(height) / max(1, mediaBox.height))
            ctx.drawPDFPage(pdfPage)
            guard let img = ctx.makeImage() else { throw SafariumError.snapshot("PDF raster failed") }
            cgPlate = img
        } else {
            let snap = try await page.snapshot()
            cgPlate = snap.cgImage
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: cgPlate.width, height: cgPlate.height, mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let tex = context.device.makeTexture(descriptor: desc) else {
            throw SafariumError.encode("failed to allocate static plate Metal texture")
        }

        let w = cgPlate.width, h = cgPlate.height
        let bpr = w * 4
        var raw = Data(count: h * bpr)
        try raw.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                space: Snapshot.colorSpace, bitmapInfo: Snapshot.bitmapInfo
            ) else {
                throw SafariumError.snapshot("static plate CGContext alloc failed")
            }
            ctx.draw(cgPlate, in: CGRect(x: 0, y: 0, width: w, height: h))
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: buf.baseAddress!, bytesPerRow: bpr)
        }
        staticPlateTexture = tex
        staticPlateImage = CIImage(mtlTexture: tex, options: [.colorSpace: Snapshot.colorSpace])?.oriented(.downMirrored)
        staticPlateSize = (w, h)
    }

    public func compositeScene(
        params: HybridSceneParams,
        overlay: CGImage,
        into outputPB: CVPixelBuffer,
        outWidth: Int,
        outHeight: Int
    ) throws {
        guard let plateCI = staticPlateImage else {
            throw SafariumError.invalidState("captureStaticPlate must be called before compositeScene")
        }
        try autoreleasepool {
            let extent = CGRect(x: 0, y: 0, width: outWidth, height: outHeight)
            let plateExtent = CGRect(x: 0, y: 0, width: staticPlateSize.0, height: staticPlateSize.1)

            // 1. Background plate (with optional subpixel pan, clamped so edges never reveal black)
            let panned = plateCI.clampedToExtent()
                .transformed(by: CGAffineTransform(translationX: params.panX, y: -params.panY))
                .cropped(to: plateExtent)
            let plateScaleX = CGFloat(outWidth) / max(1, CGFloat(staticPlateSize.0))
            let plateScaleY = CGFloat(outHeight) / max(1, CGFloat(staticPlateSize.1))
            var scene: CIImage = (plateScaleX == 1 && plateScaleY == 1)
                ? panned.cropped(to: extent)
                : panned.transformed(by: CGAffineTransform(scaleX: plateScaleX, y: plateScaleY)).cropped(to: extent)

            // 2. Spotlight vignette if alpha > 0
            if params.spotTintRGBA.3 > 0.001,
               let grad = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: params.spotCenterCSS.x, y: CGFloat(outHeight) - params.spotCenterCSS.y),
                "inputRadius0": params.spotInnerR,
                "inputRadius1": params.spotOuterR,
                "inputColor0": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
                "inputColor1": CIColor(
                    red: params.spotTintRGBA.0, green: params.spotTintRGBA.1,
                    blue: params.spotTintRGBA.2, alpha: params.spotTintRGBA.3
                ),
               ])?.outputImage?.cropped(to: extent) {
                scene = grad.composited(over: scene)
            }

            // 3. Overlay + optional GPU drop shadow
            let ovCI = CIImage(cgImage: overlay)
            let ovScaled: CIImage = (overlay.width == outWidth && overlay.height == outHeight)
                ? ovCI
                : ovCI.transformed(by: CGAffineTransform(
                    scaleX: CGFloat(outWidth) / max(1, CGFloat(overlay.width)),
                    y: CGFloat(outHeight) / max(1, CGFloat(overlay.height))
                ))

            if params.shadowColorRGBA.3 > 0.001 && params.shadowSigma > 0.01,
               let shadow = shadowImage(for: ovScaled, params: params, extent: extent) {
                scene = shadow.composited(over: scene)
            }
            scene = ovScaled.composited(over: scene).cropped(to: extent)
            try render(scene: scene, extent: extent, into: outputPB)
        }
    }

    public func compositeVideoPlusOverlay(
        videoPB: CVPixelBuffer,
        overlay: CGImage?,
        into outputPB: CVPixelBuffer,
        outWidth: Int,
        outHeight: Int,
        transform: CGAffineTransform = .identity
    ) throws {
        try autoreleasepool {
            let extent = CGRect(x: 0, y: 0, width: outWidth, height: outHeight)
            let bgRaw = SafariumSequentialVideoReader.orientedCIImage(
                from: videoPB, transform: transform, targetWidth: outWidth, targetHeight: outHeight
            )
            let vw = max(1, bgRaw.extent.width)
            let vh = max(1, bgRaw.extent.height)
            var scene = (Int(vw.rounded()) == outWidth && Int(vh.rounded()) == outHeight)
                ? bgRaw.cropped(to: extent)
                : bgRaw.transformed(by: CGAffineTransform(scaleX: CGFloat(outWidth) / vw, y: CGFloat(outHeight) / vh)).cropped(to: extent)

            if let overlay {
                let ovRaw = CIImage(cgImage: overlay)
                let ovScaled = (overlay.width == outWidth && overlay.height == outHeight)
                    ? ovRaw
                    : ovRaw.transformed(by: CGAffineTransform(
                        scaleX: CGFloat(outWidth) / max(1, CGFloat(overlay.width)),
                        y: CGFloat(outHeight) / max(1, CGFloat(overlay.height))
                    ))
                scene = ovScaled.composited(over: scene).cropped(to: extent)
            }
            try render(scene: scene, extent: extent, into: outputPB)
        }
    }

    private func shadowImage(for overlay: CIImage, params: HybridSceneParams, extent: CGRect) -> CIImage? {
        guard let alphaMask = overlay.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: params.shadowColorRGBA.3),
            "inputBiasVector": CIVector(
                x: params.shadowColorRGBA.0, y: params.shadowColorRGBA.1,
                z: params.shadowColorRGBA.2, w: 0
            ),
        ]).cropped(to: extent) as CIImage? else { return nil }
        return alphaMask
            .clampedToExtent()
            .applyingGaussianBlur(sigma: params.shadowSigma)
            .transformed(by: CGAffineTransform(translationX: params.shadowOffsetCSS.x, y: -params.shadowOffsetCSS.y))
            .cropped(to: extent)
    }

    private func render(scene: CIImage, extent: CGRect, into outputPB: CVPixelBuffer) throws {
        let (_, mtlOut) = try context.bindBGRA8Texture(for: outputPB)
        guard let cmd = context.commandQueue.makeCommandBuffer() else {
            throw SafariumError.encode("missing Metal command buffer")
        }
        let dest = CIRenderDestination(mtlTexture: mtlOut, commandBuffer: cmd)
        dest.isFlipped = true
        dest.colorSpace = Snapshot.colorSpace
        try context.ciContext.startTask(toRender: scene, from: extent, to: dest, at: .zero)
        cmd.commit()
        cmd.waitUntilCompleted()
        context.flushTextureCache()
        if let err = cmd.error ?? (cmd.status != .completed ? SafariumError.encode("Metal render failed (status \(cmd.status.rawValue))") : nil) {
            throw err
        }
    }

    private static let observeHybridErrors = """
    (() => {
      let failure;
      const fail = text => { failure ??= String(text).slice(0, 300); };
      window.addEventListener('error', e => {
        if (e instanceof ErrorEvent) fail(e.message || 'page script failed');
        else if (e.target?.matches?.('script,link[rel~="stylesheet"],img'))
          fail('could not load local <' + e.target.localName + '> asset');
      }, true);
      window.addEventListener('unhandledrejection', e => fail(e.reason?.message || 'unhandled page promise rejection'));
      Object.defineProperty(window, '__safariumHybridCheck', { value: () => { if (failure) throw new Error(failure); } });
    })();
    """

    @MainActor
    public static func renderHybridVideo(
        htmlURL: URL?,
        videoURL: URL?,
        outputURL: URL,
        width: Int,
        height: Int,
        fps: Int,
        frames: Int,
        codec: VideoCodec = .h264,
        bitrate: Int = 20_000_000,
        quality: Double? = nil,
        startSeconds: Double = 0,
        overwrite: Bool = false,
        effect: Wave2EffectKind = .none,
        splitMetalFX: Bool = false
    ) async throws -> HybridRenderReport {
        guard htmlURL != nil || videoURL != nil else {
            throw SafariumError.invalidState("hybrid requires --html and/or --video")
        }
        guard width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 33_554_432,
              width % 2 == 0, height % 2 == 0 else {
            throw SafariumError.invalidState("width and height must be positive even integers <= 8192 (max 33554432 pixels)")
        }
        guard fps > 0, frames > 0 else {
            throw SafariumError.invalidState("fps and frames must be > 0")
        }
        guard bitrate > 0 else {
            throw SafariumError.invalidState("bitrate must be > 0")
        }
        if let q = quality {
            guard q.isFinite, q > 0, q <= 1.0 else {
                throw SafariumError.invalidState("quality must be finite in (0, 1]")
            }
        }
        guard startSeconds.isFinite, startSeconds >= 0 else {
            throw SafariumError.invalidState("startSeconds must be finite and >= 0")
        }
        guard outputURL.pathExtension.lowercased() == codec.fileExtension else {
            throw SafariumError.invalidState("\(codec) output must end with .\(codec.fileExtension)")
        }
        try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)
        HostApp.prepare()

        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }

        let comp = try SafariumHybridCompositor()
        var videoReader: SafariumSequentialVideoReader?
        if let videoURL {
            videoReader = try await SafariumSequentialVideoReader(
                url: videoURL, loop: true, startTimeOffset: 0,
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            )
        }
        defer { videoReader?.close() }

        var page: Page?
        var hasHybridHook = false
        if let htmlURL {
            try SafeFilePublisher.assertRegularReadableFile(htmlURL)
            let store = WKContentRuleListStore(url: staging.directory)
            let rules = """
            [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]
            """
            guard let rule = try await store?.compileContentRuleList(forIdentifier: "local-only", encodedContentRuleList: rules) else {
                throw SafariumError.invalidState("could not prepare WebKit local-asset rules")
            }
            let p = try await Page(config: PageConfig(
                width: width, height: height, scale: 1,
                transparent: true, deterministicClock: true, video: .none, snapshotQuality: .fast
            )) { wc in
                wc.websiteDataStore = .nonPersistent()
                wc.mediaTypesRequiringUserActionForPlayback = .all
                wc.userContentController.add(rule)
                wc.userContentController.addUserScript(WKUserScript(
                    source: observeHybridErrors, injectionTime: .atDocumentStart, forMainFrameOnly: true
                ))
            }
            try await p.load(.fileURL(htmlURL))
            try await p.waitFor(.fonts)
            try await p.evaluate("window.__safariumHybridCheck(); return true")
            page = p
        }
        defer { page?.close() }

        if videoReader == nil, let page {
            hasHybridHook = (try await page.evaluate("return typeof window.__setHybridLayer === 'function'") as? Bool) == true
            if hasHybridHook {
                _ = try await page.evaluate("window.__setHybridLayer('plate'); return true")
                try await comp.captureStaticPlate(page: page, width: width, height: height)
                _ = try await page.evaluate("window.__setHybridLayer('overlay'); return true")
            }
        }

        let tempURL = staging.fileURL("out.\(codec.fileExtension)")
        let sink = try AVAssetWriterSink(
            url: tempURL, width: width, height: height, fps: fps,
            codec: codec, bitrate: bitrate, quality: quality, pixelFormat: .bgra
        )
        let effectsEngine: Wave2MetalEffectsEngine? = (effect != .none || splitMetalFX)
            ? try Wave2MetalEffectsEngine()
            : nil
        let bgHalfW = max(2, (width / 2) & ~1)
        let bgHalfH = max(2, (height / 2) & ~1)
        let bgHalfPB: CVPixelBuffer? = splitMetalFX
            ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: bgHalfW, height: bgHalfH, pixelFormat: .bgra)
            : nil
        let ovPB: CVPixelBuffer? = splitMetalFX
            ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra)
            : nil
        let effectScratchPB: CVPixelBuffer? = (effect != .none)
            ? try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra)
            : nil

        func clearPB(_ pb: CVPixelBuffer, width w: Int, height h: Int) {
            CVPixelBufferLockBaseAddress(pb, [])
            defer { CVPixelBufferUnlockBaseAddress(pb, []) }
            if let base = CVPixelBufferGetBaseAddress(pb) {
                memset(base, 0, CVPixelBufferGetBytesPerRow(pb) * h)
            }
        }

        do {
            for i in 0..<frames {
                let t = startSeconds + Double(i) / Double(fps)
                var overlayCG: CGImage?
                if let page {
                    try await page.seek(t)
                    try await page.evaluate("window.__safariumHybridCheck(); return true")
                    overlayCG = try await page.snapshot().cgImage
                }
                if let videoReader {
                    guard let vPB = try videoReader.pixelBuffer(at: t) else {
                        throw SafariumError.snapshot("missing background video frame \(i)")
                    }
                    let videoTransform = videoReader.preferredTransform
                    let bgOriented = splitMetalFX ? videoReader.orientedCIImage(from: vPB) : nil
                    try await sink.append { outPB in
                        let renderTarget = effectScratchPB ?? outPB
                        if splitMetalFX, let fx = effectsEngine, let bgHalf = bgHalfPB, let ovBuf = ovPB, let ciImg = bgOriented {
                            let ciCtx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])
                            guard let cg = ciCtx.createCGImage(ciImg, from: ciImg.extent, format: .BGRA8, colorSpace: Snapshot.colorSpace) else {
                                throw SafariumError.snapshot("splitMetalFX background CI render failed")
                            }
                            try Snapshot(cgImage: cg).draw(into: bgHalf, width: bgHalfW, height: bgHalfH)
                            if let overlayCG {
                                try Snapshot(cgImage: overlayCG).draw(into: ovBuf, width: width, height: height)
                            } else {
                                clearPB(ovBuf, width: width, height: height)
                            }
                            try fx.applySplitMetalFX(backgroundHalfRes: bgHalf, overlay1x: ovBuf, into: renderTarget)
                        } else {
                            try comp.compositeVideoPlusOverlay(
                                videoPB: vPB, overlay: overlayCG, into: renderTarget, outWidth: width, outHeight: height, transform: videoTransform
                            )
                        }
                        if effect != .none, let fx = effectsEngine {
                            _ = try fx.applyEffect(effect, to: renderTarget, into: outPB)
                        }
                    }
                } else if let overlayCG {
                    if hasHybridHook {
                        try await sink.append { outPB in
                            let renderTarget = effectScratchPB ?? outPB
                            try comp.compositeScene(
                                params: HybridSceneParams(), overlay: overlayCG, into: renderTarget, outWidth: width, outHeight: height
                            )
                            if effect != .none, let fx = effectsEngine {
                                _ = try fx.applyEffect(effect, to: renderTarget, into: outPB)
                            }
                        }
                    } else {
                        try await sink.append { outPB in
                            let renderTarget = effectScratchPB ?? outPB
                            let snap = Snapshot(cgImage: overlayCG)
                            if splitMetalFX, let fx = effectsEngine, let bgHalf = bgHalfPB, let ovBuf = ovPB {
                                try snap.draw(into: bgHalf, width: bgHalfW, height: bgHalfH)
                                clearPB(ovBuf, width: width, height: height)
                                try fx.applySplitMetalFX(backgroundHalfRes: bgHalf, overlay1x: ovBuf, into: renderTarget)
                            } else {
                                try snap.draw(into: renderTarget, width: width, height: height)
                            }
                            if effect != .none, let fx = effectsEngine {
                                _ = try fx.applyEffect(effect, to: renderTarget, into: outPB)
                            }
                        }
                    }
                }
            }
            try await sink.finish()
            try SafeFilePublisher.publish(tempURL: tempURL, to: outputURL, overwrite: overwrite)
        } catch {
            sink.cancel()
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        let size = ((try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        return HybridRenderReport(
            htmlPath: htmlURL?.path,
            videoPath: videoURL?.path,
            outputPath: outputURL.path,
            width: width,
            height: height,
            fps: fps,
            frames: frames,
            codec: codec.rawValue,
            fileSizeBytes: size
        )
    }
}
