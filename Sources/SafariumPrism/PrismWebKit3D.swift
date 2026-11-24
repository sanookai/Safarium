import Accelerate
import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import Metal
import MetalFX
import SafariumCore
import SafariumForgeCore
import WebKit

public struct PrismWebKitCapabilities: Codable, Sendable, Equatable {
    public let webgl2: Bool
    public let webgpu: Bool
    public let renderer: String?
    public let vendor: String?
    public let maxTextureSize: Int?
    public let maxSamples: Int?
}

public struct PrismMetalFXResult: @unchecked Sendable {
    public let outputPB: CVPixelBuffer
    public let pqReport: SafariumPQReport
    public let didFallbackTo1x: Bool
    public let upscaleWallMs: Double
}

/// Reusable MetalFX Spatial Scaler (`0.67x -> 1.0x`) + `SafariumPQEngine` Auto-Verify gate.
/// Automatically falls back to native `1.0x` whenever MS-SSIM, ΔE00 p95, ANE FeaturePrint score,
/// or optional Vision Thai OCR fails the configured `PrismQualityPolicy`.
public final class PrismMetalFXVerifier {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let textureCache: CVMetalTextureCache
    public let pqEngine: SafariumPQEngine

    private var scaler: MTLFXSpatialScaler?
    private var scalerInW = 0
    private var scalerInH = 0
    private var scalerOutW = 0
    private var scalerOutH = 0
    private var privOutTex: MTLTexture?

    public init() throws {
        guard let ctx = SafariumMetalContext.shared else {
            throw SafariumError.encode("SafariumMetalContext.shared unavailable for PrismMetalFXVerifier")
        }
        self.device = ctx.device
        self.commandQueue = ctx.commandQueue
        self.textureCache = ctx.textureCache
        self.pqEngine = try SafariumPQEngine()
    }

    public static func isSupported() -> Bool {
        guard let dev = SafariumMetalContext.shared?.device else { return false }
        return MTLFXSpatialScalerDescriptor.supportsDevice(dev)
    }

    private func ensureScaler(inW: Int, inH: Int, outW: Int, outH: Int) throws -> (MTLFXSpatialScaler, MTLTexture) {
        if let sc = scaler, let tex = privOutTex,
           scalerInW == inW, scalerInH == inH, scalerOutW == outW, scalerOutH == outH {
            return (sc, tex)
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
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: outW, height: outH, mipmapped: false)
        td.storageMode = .private
        td.usage = [.shaderRead, .shaderWrite, .renderTarget]
        guard let privTex = device.makeTexture(descriptor: td) else {
            throw SafariumError.encode("failed allocating MetalFX .private texture \(outW)x\(outH)")
        }
        scaler = sc
        privOutTex = privTex
        scalerInW = inW
        scalerInH = inH
        scalerOutW = outW
        scalerOutH = outH
        return (sc, privTex)
    }

    @discardableResult
    public func upscale(lowResPB: CVPixelBuffer, into outPB: CVPixelBuffer) throws -> Double {
        let inW = CVPixelBufferGetWidth(lowResPB)
        let inH = CVPixelBufferGetHeight(lowResPB)
        let outW = CVPixelBufferGetWidth(outPB)
        let outH = CVPixelBufferGetHeight(outPB)

        let t0 = DispatchTime.now().uptimeNanoseconds
        let (sc, privTex) = try ensureScaler(inW: inW, inH: inH, outW: outW, outH: outH)
        guard let ctx = SafariumMetalContext.shared else {
            throw SafariumError.encode("SafariumMetalContext.shared unavailable")
        }
        let (inCV, inTex) = try ctx.bindBGRA8Texture(for: lowResPB)
        let (outCV, outTex) = try ctx.bindBGRA8Texture(for: outPB)
        guard let cmd = commandQueue.makeCommandBuffer() else {
            throw SafariumError.encode("Metal command buffer unavailable for MetalFX")
        }

        sc.colorTexture = inTex
        sc.inputContentWidth = inW
        sc.inputContentHeight = inH
        sc.outputTexture = privTex
        sc.encode(commandBuffer: cmd)

        guard let blit = cmd.makeBlitCommandEncoder() else {
            throw SafariumError.encode("Metal blit encoder unavailable for MetalFX")
        }
        blit.copy(
            from: privTex,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: outW, height: outH, depth: 1),
            to: outTex,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        _ = (inCV, outCV)
        ctx.flushTextureCache()
        if let err = cmd.error {
            throw SafariumError.encode("MTLFXSpatialScaler execution failed: \(err)")
        }
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    public func evaluateAndUpscale(
        lowResPB: CVPixelBuffer,
        reference1xPB: CVPixelBuffer,
        overlay1xPB: CVPixelBuffer? = nil,
        policy: PrismQualityPolicy = PrismQualityPolicy()
    ) throws -> PrismMetalFXResult {
        let outW = CVPixelBufferGetWidth(reference1xPB)
        let outH = CVPixelBufferGetHeight(reference1xPB)
        let upscaledPB = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: outW, height: outH, pixelFormat: .bgra)
        let ms = try upscale(lowResPB: lowResPB, into: upscaledPB)

        if let ovPB = overlay1xPB, policy.thaiShield1xOverlay {
            try Self.blendPremultipliedOverlay(overlayPB: ovPB, onto: upscaledPB, width: outW, height: outH)
        }

        let pqReport = try pqEngine.evaluatePair(
            reference: reference1xPB,
            candidate: upscaledPB,
            checkThaiOCR: policy.checkThaiOCR,
            expectedThaiText: policy.expectedThaiText,
            minScore: policy.minPQScore,
            maxDeltaE00P95: policy.maxDeltaE00P95,
            minMSSSIM: policy.minMSSSIM
        )
        if !pqReport.passed {
            return PrismMetalFXResult(
                outputPB: reference1xPB,
                pqReport: pqReport,
                didFallbackTo1x: true,
                upscaleWallMs: ms
            )
        }
        return PrismMetalFXResult(
            outputPB: upscaledPB,
            pqReport: pqReport,
            didFallbackTo1x: false,
            upscaleWallMs: ms
        )
    }

    public static func blendPremultipliedOverlay(
        overlayPB: CVPixelBuffer,
        onto dstPB: CVPixelBuffer,
        width: Int,
        height: Int
    ) throws {
        CVPixelBufferLockBaseAddress(overlayPB, .readOnly)
        CVPixelBufferLockBaseAddress(dstPB, [])
        defer {
            CVPixelBufferUnlockBaseAddress(overlayPB, .readOnly)
            CVPixelBufferUnlockBaseAddress(dstPB, [])
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(overlayPB),
              let dstBase = CVPixelBufferGetBaseAddress(dstPB) else {
            throw SafariumError.encode("missing pixel buffer baseAddress for overlay blend")
        }
        try SafariumAccelerate.premultipliedAlphaBlendBGRA(
            src: srcBase,
            srcBytesPerRow: CVPixelBufferGetBytesPerRow(overlayPB),
            dst: dstBase,
            dstBytesPerRow: CVPixelBufferGetBytesPerRow(dstPB),
            width: width,
            height: height
        )
    }
}

public typealias PrismLoopbackFontServer = ForgeLoopbackFontServer

public struct PrismSVGSurgeryOp: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable {
        case dropShadow
        case gaussianBlur
        case paperCutout
        case markerTexture
    }

    public let targetIndex: Int
    public let kind: Kind
    public let stdDeviation: Double
    public let dx: Double
    public let dy: Double
    public let floodColorRGBA: [Double]
    public let mergeSourceGraphic: Bool

    public init(
        targetIndex: Int,
        kind: Kind,
        stdDeviation: Double = 4.0,
        dx: Double = 0.0,
        dy: Double = 0.0,
        floodColorRGBA: [Double] = [0.0, 0.0, 0.0, 0.5],
        mergeSourceGraphic: Bool = true
    ) {
        self.targetIndex = targetIndex
        self.kind = kind
        self.stdDeviation = stdDeviation
        self.dx = dx
        self.dy = dy
        self.floodColorRGBA = floodColorRGBA
        self.mergeSourceGraphic = mergeSourceGraphic
    }
}

public struct PrismSVGSurgeryPlan: Codable, Sendable, Equatable {
    public let ops: [PrismSVGSurgeryOp]
    public let hasSharpTextLayer: Bool
    public let sharpTextCount: Int

    public init(ops: [PrismSVGSurgeryOp] = [], hasSharpTextLayer: Bool = false, sharpTextCount: Int = 0) {
        self.ops = ops
        self.hasSharpTextLayer = hasSharpTextLayer
        self.sharpTextCount = sharpTextCount
    }
}

/// Headless windowless system `WKWebView` 3D host (`NSApplication.shared.setActivationPolicy(.prohibited)`).
/// Supports Mode A (built-in pure WebGL2 offline binary `.glb` PBR previewer) and Mode B (any local Three.js HTML page).
@MainActor
public final class PrismWebKit3D {
    public private(set) var width: Int
    public private(set) var height: Int
    public let transparent: Bool
    public let allowLoopbackHTTP: Bool

    private var page: Page?
    private var stagingDir: URL?
    private var glbLoaded = false
    private var htmlLoaded = false
    private let fontFaceInjectionJS: String?

    private static let observeErrorsJS = """
    (() => {
      if (window.__safariumPrismCheck) return;
      let failure;
      const fail = text => { failure ??= String(text).slice(0, 300); };
      const isBlockedExternalStylesheet = el => {
        if (!el || !el.matches?.('link[rel~="stylesheet"]')) return false;
        const raw = String(el.href || el.getAttribute?.('href') || '').trim();
        try {
          const u = new URL(raw, window.location.href);
          if (u.protocol !== 'http:' && u.protocol !== 'https:') return false;
          const isLoopback = u.protocol === 'http:'
            && u.username === ''
            && u.password === ''
            && (u.hostname === '127.0.0.1' || u.hostname === 'localhost');
          return !isLoopback;
        } catch {
          return false;
        }
      };
      window.addEventListener('error', e => {
        if (e instanceof ErrorEvent) fail(e.message || 'page script failed');
        else if (e.target?.matches?.('script,link[rel~="stylesheet"],img')) {
          if (isBlockedExternalStylesheet(e.target)) return;
          fail('could not load local <' + e.target.localName + '> asset');
        }
      }, true);
      window.addEventListener('unhandledrejection', e => fail(e.reason?.message || 'unhandled page promise rejection'));
      Object.defineProperty(window, '__safariumPrismCheck', { value: () => { if (failure) throw new Error(failure); } });
    })();
    """

    public init(
        width: Int = 1080,
        height: Int = 1920,
        transparent: Bool = false,
        deterministicClock: Bool = true,
        allowLoopbackHTTP: Bool = false,
        fontFaceInjectionJS: String? = nil
    ) async throws {
        HostApp.prepare()
        self.width = max(2, width)
        self.height = max(2, height)
        self.transparent = transparent
        self.allowLoopbackHTTP = allowLoopbackHTTP
        self.fontFaceInjectionJS = fontFaceInjectionJS

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safarium-prism-wk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.stagingDir = dir

        let store = WKContentRuleListStore(url: dir)
        let rules: String
        let ruleID: String
        if allowLoopbackHTTP {
            ruleID = "prism-loopback-only"
            rules = """
            [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"^http://127\\\\.0\\\\.0\\\\.1:[0-9]+/"},"action":{"type":"ignore-previous-rules"}},
             {"trigger":{"url-filter":"^http://127\\\\.0\\\\.0\\\\.1:[0-9]+$"},"action":{"type":"ignore-previous-rules"}},
             {"trigger":{"url-filter":"^http://127\\\\.0\\\\.0\\\\.1/"},"action":{"type":"ignore-previous-rules"}},
             {"trigger":{"url-filter":"^http://127\\\\.0\\\\.0\\\\.1$"},"action":{"type":"ignore-previous-rules"}},
             {"trigger":{"url-filter":"^http://localhost:[0-9]+/"},"action":{"type":"ignore-previous-rules"}},
             {"trigger":{"url-filter":"^http://localhost:[0-9]+$"},"action":{"type":"ignore-previous-rules"}},
             {"trigger":{"url-filter":"^http://localhost/"},"action":{"type":"ignore-previous-rules"}},
             {"trigger":{"url-filter":"^http://localhost$"},"action":{"type":"ignore-previous-rules"}},
             {"trigger":{"url-filter":"^https?://[^/]*@"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]
            """
        } else {
            ruleID = "prism-local-only"
            rules = """
            [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]
            """
        }
        guard let store,
              let ruleList = try await store.compileContentRuleList(forIdentifier: ruleID, encodedContentRuleList: rules) else {
            throw SafariumError.invalidState("failed compiling WKContentRuleList for PrismWebKit3D sandbox")
        }

        let cfg = PageConfig(
            width: self.width,
            height: self.height,
            scale: 1,
            transparent: transparent,
            deterministicClock: deterministicClock,
            video: .none,
            snapshotQuality: .fast
        )
        let p = try await Page(config: cfg) { wc in
            wc.websiteDataStore = .nonPersistent()
            wc.mediaTypesRequiringUserActionForPlayback = .all
            wc.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
            wc.userContentController.add(ruleList)
            wc.userContentController.addUserScript(WKUserScript(
                source: Self.observeErrorsJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            if let fontJS = fontFaceInjectionJS, !fontJS.isEmpty {
                wc.userContentController.addUserScript(WKUserScript(
                    source: fontJS,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                ))
            }
        }
        self.page = p
    }

    deinit {
        let p = page
        let dir = stagingDir
        Task { @MainActor in p?.close() }
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    public func close() {
        page?.close()
        page = nil
        if let dir = stagingDir {
            try? FileManager.default.removeItem(at: dir)
            stagingDir = nil
        }
    }

    public func resize(width newWidth: Int, height newHeight: Int) async throws {
        let w = max(2, newWidth)
        let h = max(2, newHeight)
        self.width = w
        self.height = h
        guard let page else { throw SafariumError.invalidState("PrismWebKit3D closed") }
        page.setViewport(width: w, height: h)
        if glbLoaded {
            _ = try await page.evaluate("window.__PRISM.setResolution(w, h); return true;", arguments: ["w": w, "h": h])
        } else if htmlLoaded {
            _ = try await page.evaluate("""
                if (typeof window.setResolution === 'function') window.setResolution(w, h);
                window.dispatchEvent(new Event('resize'));
                return true;
                """, arguments: ["w": w, "h": h])
        }
    }

    // MARK: - Mode A: Built-in Pure WebGL2 Offline Binary GLB Viewer

    public func loadBuiltinViewer() async throws {
        guard let page else { throw SafariumError.invalidState("PrismWebKit3D closed") }
        let html = Self.builtinGLBViewerHTML(width: width, height: height, transparent: transparent)
        try await page.load(.html(html, baseURL: nil))
        try await page.waitFor(.readyState)
        glbLoaded = true
        htmlLoaded = false
    }

    public func checkCapabilities() async throws -> PrismWebKitCapabilities {
        if !glbLoaded && !htmlLoaded {
            try await loadBuiltinViewer()
        }
        guard let page else { throw SafariumError.invalidState("PrismWebKit3D closed") }
        let raw = try await page.evaluate("""
            if (window.__PRISM && typeof window.__PRISM.checkCapabilities === 'function') {
              return await window.__PRISM.checkCapabilities();
            }
            return { webgl2: !!document.createElement('canvas').getContext('webgl2'), webgpu: ('gpu' in navigator) };
            """)
        let dict = raw as? [String: Any] ?? [:]
        return PrismWebKitCapabilities(
            webgl2: (dict["webgl2"] as? Bool) ?? false,
            webgpu: (dict["webgpu"] as? Bool) ?? false,
            renderer: dict["webgl2Renderer"] as? String,
            vendor: dict["webgl2Vendor"] as? String,
            maxTextureSize: (dict["maxTextureSize"] as? NSNumber)?.intValue,
            maxSamples: (dict["maxSamples"] as? NSNumber)?.intValue
        )
    }

    @discardableResult
    public func loadBuiltinGLB(glbURL: URL) async throws -> [String: Any] {
        try SafeFilePublisher.assertRegularReadableFile(glbURL)
        if !glbLoaded {
            try await loadBuiltinViewer()
        }
        guard let page else { throw SafariumError.invalidState("PrismWebKit3D closed") }
        let data = try Data(contentsOf: glbURL)
        let b64 = data.base64EncodedString()
        let res = try await page.evaluate("return window.__PRISM.loadGLB(b64);", arguments: ["b64": b64])
        _ = try await page.evaluate("window.__safariumPrismCheck(); return true;")
        return (res as? [String: Any]) ?? [:]
    }

    @discardableResult
    public func renderGLBAngle(_ angleDeg: Double) async throws -> Double {
        guard glbLoaded, let page else {
            throw SafariumError.invalidState("loadBuiltinGLB must be called before renderGLBAngle")
        }
        let res = try await page.evaluate("return window.__PRISM.renderAngle(deg);", arguments: ["deg": angleDeg])
        return (res as? NSNumber)?.doubleValue ?? 0.0
    }

    @discardableResult
    public func renderGLB(camera: PrismCameraIR) async throws -> Double {
        guard glbLoaded, let page else {
            throw SafariumError.invalidState("loadBuiltinGLB must be called before renderGLB(camera:)")
        }
        let args: [String: Any] = [
            "pos": camera.positionThree.array,
            "q": camera.quaternionThree.xyzwArray,
            "fov": camera.fovYDeg,
            "aspect": camera.aspect,
            "near": camera.near,
            "far": camera.far,
            "shiftX": camera.shiftX,
            "shiftY": camera.shiftY,
            "fit": camera.sensorFit.rawValue,
        ]
        let res = try await page.evaluate(
            "return window.__PRISM.renderWithCamera(pos, q, fov, aspect, near, far, shiftX, shiftY, fit);",
            arguments: args
        )
        return (res as? NSNumber)?.doubleValue ?? 0.0
    }

    // MARK: - Mode B: Arbitrary Local Three.js / WebGL HTML Page

    private func finishPageLoad(waitReadyTimeout: TimeInterval, readyExpr: String? = nil) async throws {
        guard let page else { throw SafariumError.invalidState("PrismWebKit3D closed") }
        try await page.waitFor(.readyState, timeout: waitReadyTimeout)
        if let fontJS = fontFaceInjectionJS, !fontJS.isEmpty {
            _ = try await page.evaluate(fontJS)
        }
        try await page.waitFor(.fonts, timeout: waitReadyTimeout)
        try await page.waitFor(.images, timeout: waitReadyTimeout)

        if let rawReady = readyExpr?.trimmingCharacters(in: .whitespacesAndNewlines), !rawReady.isEmpty {
            try await waitForReadyExpression(rawReady, timeout: waitReadyTimeout)
        } else {
            // Honor lemo-opuscar / Three.js `window.READY === true` contract when present.
            let hasReadyProp = (try await page.evaluate("return (typeof window.READY !== 'undefined');") as? Bool) ?? false
            if hasReadyProp {
                try await page.waitFor(.predicate("window.READY === true"), timeout: waitReadyTimeout)
            }
        }
        _ = try await page.evaluate("window.__safariumPrismCheck(); return true;")
        htmlLoaded = true
        glbLoaded = false
    }

    private func waitForReadyExpression(_ expr: String, timeout: TimeInterval) async throws {
        guard let page else { throw SafariumError.invalidState("PrismWebKit3D closed") }
        let trimmed = Self.stripTrailingSemicolonIfSingleExpression(expr)
        let isStatements = trimmed.contains(";") || trimmed.contains("\n")
            || trimmed.hasPrefix("return ") || trimmed.hasPrefix("if ")
            || trimmed.hasPrefix("for ") || trimmed.hasPrefix("const ")
            || trimmed.hasPrefix("let ") || trimmed.hasPrefix("var ")
        let evalScript: String
        if isStatements {
            evalScript = """
            const __sfReadyVal = await (async () => { \(trimmed) })();
            window.__safariumPrismCheck();
            return Boolean(__sfReadyVal);
            """
        } else {
            evalScript = """
            const __sfReadyVal = await Promise.resolve(\(trimmed));
            window.__safariumPrismCheck();
            return Boolean(__sfReadyVal);
            """
        }

        let deadline = Date().addingTimeInterval(max(0.1, timeout))
        var didFlushVirtualZero = false
        while true {
            try Task.checkCancellation()
            let res = try await page.evaluate(evalScript, timeout: min(max(1.0, timeout), 15.0))
            if (res as? Bool) == true {
                return
            }
            if Date() >= deadline {
                throw SafariumError.timeout("readyExpr timed out after \(String(format: "%.1f", timeout))s: \(expr)")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            if !didFlushVirtualZero {
                didFlushVirtualZero = true
                _ = try await page.evaluate("if (window.__sfClock && typeof window.__sfClock.flush === 'function') { window.__sfClock.flush(); } window.__safariumPrismCheck(); return true;")
            } else {
                _ = try await page.evaluate("""
                    if (window.__sfClock && typeof window.__sfClock.seek === 'function') {
                      await window.__sfClock.seek(((Number(window.__sfClock.now) || 0) / 1000.0) + 0.02);
                    }
                    window.__safariumPrismCheck();
                    return true;
                    """)
            }
        }
    }

    private static func stripTrailingSemicolonIfSingleExpression(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(";"), !trimmed.contains("\n") else { return trimmed }
        let withoutTrailing = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        if !withoutTrailing.contains(";") {
            return withoutTrailing
        }
        return trimmed
    }

    public func loadHTMLFile(
        _ url: URL,
        readAccessDir: URL? = nil,
        waitReadyTimeout: TimeInterval = 30.0,
        readyExpr: String? = nil
    ) async throws {
        try SafeFilePublisher.assertRegularReadableFile(url)
        guard let page else { throw SafariumError.invalidState("PrismWebKit3D closed") }
        try await page.load(.fileURL(url, readAccess: readAccessDir ?? url.deletingLastPathComponent()), timeout: waitReadyTimeout)
        try await finishPageLoad(waitReadyTimeout: waitReadyTimeout, readyExpr: readyExpr)
    }

    public func loadURL(
        _ url: URL,
        waitReadyTimeout: TimeInterval = 30.0,
        readyExpr: String? = nil
    ) async throws {
        guard allowLoopbackHTTP else {
            throw SafariumError.invalidState("loadURL requires PrismWebKit3D(allowLoopbackHTTP: true)")
        }
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        guard scheme == "http" && url.user == nil && url.password == nil && (host == "127.0.0.1" || host == "localhost") else {
            throw SafariumError.invalidState("PrismWebKit3D only permits local http://127.0.0.1|localhost loopback URLs without userinfo, got \(url.absoluteString)")
        }
        guard let page else { throw SafariumError.invalidState("PrismWebKit3D closed") }
        try await page.load(.url(url), timeout: waitReadyTimeout)
        try await finishPageLoad(waitReadyTimeout: waitReadyTimeout, readyExpr: readyExpr)
    }

    public func runInitScript(js: String? = nil, fileURL: URL? = nil, timeout: TimeInterval = 30.0) async throws {
        guard let page else { throw SafariumError.invalidState("PrismWebKit3D closed") }
        var chunks: [String] = []
        if let fileURL {
            try SafeFilePublisher.assertRegularReadableFile(fileURL)
            let fileText = try String(contentsOf: fileURL, encoding: .utf8)
            if !fileText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(fileText)
            }
        }
        if let js, !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(js)
        }
        guard !chunks.isEmpty else { return }

        for chunk in chunks {
            let mode = try await page.evaluate("""
                try {
                  const __r = (0, eval)(src);
                  if (__r && typeof __r.then === 'function') await __r;
                  window.__safariumPrismCheck();
                  return 'ok';
                } catch (e) {
                  if (e instanceof SyntaxError) return 'async-fn';
                  throw e;
                }
                """, arguments: ["src": chunk], timeout: timeout) as? String
            if mode == "async-fn" {
                _ = try await page.evaluate(chunk, timeout: timeout)
                _ = try await page.evaluate("window.__safariumPrismCheck(); return true;", timeout: timeout)
            }
        }
    }

    public func evaluate(_ body: String, arguments: [String: Any] = [:], timeout: TimeInterval = 30.0) async throws -> Any? {
        guard let page else { throw SafariumError.invalidState("PrismWebKit3D closed") }
        return try await page.evaluate(body, arguments: arguments, timeout: timeout)
    }

    public func seekHTML(timeSeconds: Double, advanceVirtualClock: Bool = true) async throws {
        try await seekHTML(
            timeSeconds: timeSeconds,
            frameIndex: 0,
            fps: 30.0,
            durationSeconds: 0.0,
            seekExpr: nil,
            advanceVirtualClock: advanceVirtualClock
        )
    }

    public func seekHTML(
        timeSeconds: Double,
        frameIndex: Int,
        fps: Double,
        durationSeconds: Double,
        seekExpr: String?,
        advanceVirtualClock: Bool = true
    ) async throws {
        guard htmlLoaded, let page else {
            throw SafariumError.invalidState("loadHTMLFile must be called before seekHTML")
        }
        if advanceVirtualClock && page.config.deterministicClock {
            try await page.seek(timeSeconds)
        }
        let args: [String: Any] = [
            "t": timeSeconds,
            "frame": frameIndex,
            "fps": fps,
            "duration": durationSeconds,
        ]
        if let rawSeek = seekExpr?.trimmingCharacters(in: .whitespacesAndNewlines), !rawSeek.isEmpty {
            let expanded = rawSeek
                .replacingOccurrences(of: "{t}", with: String(timeSeconds))
                .replacingOccurrences(of: "{frame}", with: String(frameIndex))
                .replacingOccurrences(of: "{fps}", with: String(fps))
                .replacingOccurrences(of: "{duration}", with: String(durationSeconds))
            let cleaned = Self.stripTrailingSemicolonIfSingleExpression(expanded)
            let isStatements = cleaned.contains(";") || cleaned.contains("\n")
                || cleaned.hasPrefix("return ") || cleaned.hasPrefix("if ")
                || cleaned.hasPrefix("for ") || cleaned.hasPrefix("while ")
                || cleaned.hasPrefix("const ") || cleaned.hasPrefix("let ")
                || cleaned.hasPrefix("var ") || cleaned.hasPrefix("await ")
            let jsBody: String = isStatements
                ? """
                  \(cleaned)
                  window.__safariumPrismCheck();
                  return true;
                  """
                : """
                  await Promise.resolve(\(cleaned));
                  window.__safariumPrismCheck();
                  return true;
                  """
            _ = try await page.evaluate(jsBody, arguments: args)
            return
        }
        _ = try await page.evaluate("""
            if (typeof window.__safariumSeek === 'function') {
              await window.__safariumSeek(t, frame, fps, duration);
            } else if (typeof window.render === 'function') {
              await window.render(t);
            } else if (window.gsap && window.gsap.globalTimeline && typeof window.gsap.globalTimeline.time === 'function') {
              if (typeof window.gsap.globalTimeline.pause === 'function') window.gsap.globalTimeline.pause();
              window.gsap.globalTimeline.time(t, false);
            }
            window.__safariumPrismCheck();
            return true;
            """, arguments: args)
    }

    public func applySVGFilterSurgery(preserveSharpText1x: Bool = true) async throws -> PrismSVGSurgeryPlan {
        guard htmlLoaded, let page else {
            throw SafariumError.invalidState("loadHTMLFile must be called before applySVGFilterSurgery")
        }
        let raw = try await page.evaluate("""
            const keepSharpText = Boolean(preserveSharpText1x);

            const prevStyle = document.getElementById('safarium-svg-surgery-style');
            if (prevStyle) prevStyle.remove();
            for (const el of document.querySelectorAll('[data-sf-svg-target]')) el.removeAttribute('data-sf-svg-target');
            for (const el of document.querySelectorAll('[data-sf-active-target]')) el.removeAttribute('data-sf-active-target');
            for (const el of document.querySelectorAll('[data-sf-sharp-text]')) el.removeAttribute('data-sf-sharp-text');
            delete document.documentElement.dataset.safariumSvgPass;
            delete document.documentElement.dataset.safariumHasSharpText;

            const styleEl = document.createElement('style');
            styleEl.id = 'safarium-svg-surgery-style';
            styleEl.textContent = `
              html[data-safarium-svg-pass="base"] [data-sf-svg-target] { visibility: hidden !important; }
              html[data-safarium-svg-pass="base"][data-safarium-has-sharp-text="1"] [data-sf-sharp-text="1"] { visibility: hidden !important; }
              html[data-safarium-svg-pass="svg-target"],
              html[data-safarium-svg-pass="svg-target"] body { background: transparent !important; background-image: none !important; }
              html[data-safarium-svg-pass="svg-target"] body,
              html[data-safarium-svg-pass="svg-target"] body * { visibility: hidden !important; }
              html[data-safarium-svg-pass="svg-target"] [data-sf-active-target="1"],
              html[data-safarium-svg-pass="svg-target"] [data-sf-active-target="1"] * { visibility: visible !important; }
              html[data-safarium-svg-pass="sharp-text"],
              html[data-safarium-svg-pass="sharp-text"] body { background: transparent !important; background-image: none !important; }
              html[data-safarium-svg-pass="sharp-text"] body,
              html[data-safarium-svg-pass="sharp-text"] body * { visibility: hidden !important; }
              html[data-safarium-svg-pass="sharp-text"] [data-sf-sharp-text="1"],
              html[data-safarium-svg-pass="sharp-text"] [data-sf-sharp-text="1"] * { visibility: visible !important; }
            `;
            (document.head || document.documentElement).appendChild(styleEl);

            const colorCanvas = document.createElement('canvas');
            colorCanvas.width = 1;
            colorCanvas.height = 1;
            const colorCtx = colorCanvas.getContext('2d');
            function parseColorRGBA(colorStr, alphaScale) {
              const scale = (Number.isFinite(alphaScale) ? alphaScale : 1.0);
              let rgba = [0.0, 0.0, 0.0, 0.5];
              if (colorCtx && colorStr) {
                try {
                  colorCtx.fillStyle = '#000000';
                  colorCtx.fillStyle = String(colorStr).trim();
                  const norm = colorCtx.fillStyle;
                  if (norm.startsWith('#') && norm.length === 7) {
                    rgba = [
                      parseInt(norm.slice(1, 3), 16) / 255.0,
                      parseInt(norm.slice(3, 5), 16) / 255.0,
                      parseInt(norm.slice(5, 7), 16) / 255.0,
                      1.0
                    ];
                  } else {
                    const m = norm.match(/rgba?\\(\\s*([\\d.]+)\\s*,\\s*([\\d.]+)\\s*,\\s*([\\d.]+)(?:\\s*,\\s*([\\d.]+))?\\s*\\)/i);
                    if (m) {
                      rgba = [
                        Math.min(1, Math.max(0, Number(m[1]) / 255.0)),
                        Math.min(1, Math.max(0, Number(m[2]) / 255.0)),
                        Math.min(1, Math.max(0, Number(m[3]) / 255.0)),
                        m[4] !== undefined ? Math.min(1, Math.max(0, Number(m[4]))) : 1.0
                      ];
                    }
                  }
                } catch (_) {}
              }
              rgba[3] = Math.min(1.0, Math.max(0.0, rgba[3] * scale));
              return rgba;
            }

            function isOptedOut(el) {
              const holder = el.closest('[data-safarium-keep-filter]');
              if (!holder) return false;
              const val = (holder.getAttribute('data-safarium-keep-filter') || '').trim().toLowerCase();
              return val !== '0' && val !== 'false';
            }

            function extractUrlId(val) {
              if (!val) return null;
              const m = String(val).match(/url\\(\\s*["']?#([^"')\\s]+)["']?\\s*\\)/i);
              return m ? m[1] : null;
            }

            function inspectSVGFilterById(id) {
              if (!id) return null;
              const f = document.getElementById(id);
              if (!f || f.localName !== 'filter') return null;
              const ds = f.querySelector('feDropShadow');
              if (ds) {
                const sdRaw = (ds.getAttribute('stdDeviation') || '3').trim().split(/[\\s,]+/)[0];
                const sdParsed = Number(sdRaw);
                const stdDev = Math.max(0, Number.isFinite(sdParsed) ? sdParsed : 3.0);
                const dxParsed = Number(ds.getAttribute('dx') || '0');
                const dyParsed = Number(ds.getAttribute('dy') || '0');
                const dx = Number.isFinite(dxParsed) ? dxParsed : 0.0;
                const dy = Number.isFinite(dyParsed) ? dyParsed : 0.0;
                const fc = ds.getAttribute('flood-color') || '#000000';
                const foAttr = ds.getAttribute('flood-opacity');
                const foParsed = foAttr !== null ? Number(foAttr) : 1.0;
                const fo = Number.isFinite(foParsed) ? foParsed : 1.0;
                return {
                  kind: 'dropShadow',
                  stdDeviation: stdDev,
                  dx,
                  dy,
                  floodColorRGBA: parseColorRGBA(fc, fo),
                  mergeSourceGraphic: true
                };
              }
              const gb = f.querySelector('feGaussianBlur');
              if (gb) {
                const sdRaw = (gb.getAttribute('stdDeviation') || '4').trim().split(/[\\s,]+/)[0];
                const sdParsed = Number(sdRaw);
                const stdDev = Math.max(0, Number.isFinite(sdParsed) ? sdParsed : 4.0);
                const hasMergeSource = Boolean(
                  f.querySelector('feMergeNode[in="SourceGraphic"]')
                  || f.querySelector('feComposite[in="SourceGraphic"]')
                  || f.querySelector('feBlend[in="SourceGraphic"]')
                );
                return {
                  kind: 'gaussianBlur',
                  stdDeviation: stdDev,
                  dx: 0.0,
                  dy: 0.0,
                  floodColorRGBA: [0.0, 0.0, 0.0, 0.0],
                  mergeSourceGraphic: hasMergeSource
                };
              }
              return null;
            }

            function inspectCSSFilter(cssFilter) {
              if (!cssFilter || cssFilter === 'none') return null;
              const urlId = extractUrlId(cssFilter);
              if (urlId) {
                const spec = inspectSVGFilterById(urlId);
                if (spec) return spec;
              }
              const dsMatch = cssFilter.match(/drop-shadow\\(([^)]+)\\)/i);
              if (dsMatch) {
                const inner = dsMatch[1].trim();
                const lens = [...inner.matchAll(/(-?[\\d.]+)px/gi)].map(m => Number(m[1]));
                const dx = lens[0] || 0.0;
                const dy = lens[1] || 0.0;
                const stdDev = Math.max(0, (lens[2] || 4.0) * 0.5);
                const colorPart = inner.replace(/-?[\\d.]+px/gi, '').trim() || 'rgba(0,0,0,0.5)';
                return {
                  kind: 'dropShadow',
                  stdDeviation: stdDev,
                  dx,
                  dy,
                  floodColorRGBA: parseColorRGBA(colorPart, 1.0),
                  mergeSourceGraphic: true
                };
              }
              const blurMatch = cssFilter.match(/blur\\(\\s*([\\d.]+)px\\s*\\)/i);
              if (blurMatch) {
                return {
                  kind: 'gaussianBlur',
                  stdDeviation: Math.max(0, Number(blurMatch[1]) || 2.0),
                  dx: 0.0,
                  dy: 0.0,
                  floodColorRGBA: [0.0, 0.0, 0.0, 0.0],
                  mergeSourceGraphic: false
                };
              }
              return null;
            }

            const ops = [];
            let nextIdx = 0;
            const candidates = [...document.querySelectorAll('svg [filter], svg[filter], [data-safarium-effect], *')];
            const seenEls = new Set();

            for (const el of candidates) {
              if (seenEls.has(el)) continue;
              seenEls.add(el);
              if (!el || el.nodeType !== 1) continue;
              const tag = el.localName;
              if (tag === 'html' || tag === 'head' || tag === 'body' || tag === 'script' || tag === 'style' || tag === 'defs' || tag === 'filter') continue;
              if (isOptedOut(el)) continue;

              let spec = null;
              const effectAttr = (el.getAttribute('data-safarium-effect') || '').trim().toLowerCase();
              if (effectAttr === 'paper-cutout') {
                spec = { kind: 'paperCutout', stdDeviation: 0.0, dx: 0.0, dy: 0.0, floodColorRGBA: [0,0,0,0], mergeSourceGraphic: false };
              } else if (effectAttr === 'marker-texture') {
                spec = { kind: 'markerTexture', stdDeviation: 0.0, dx: 0.0, dy: 0.0, floodColorRGBA: [0,0,0,0], mergeSourceGraphic: false };
              }

              const attrFilter = el.getAttribute('filter');
              if (!spec && attrFilter) {
                const id = extractUrlId(attrFilter);
                spec = inspectSVGFilterById(id) || inspectCSSFilter(attrFilter);
              }

              const computedFilter = getComputedStyle(el).filter || getComputedStyle(el).webkitFilter || el.style.filter;
              if (!spec && computedFilter && computedFilter !== 'none') {
                spec = inspectCSSFilter(computedFilter);
              }

              if (!spec) continue;

              const idx = nextIdx++;
              if (attrFilter !== null) {
                el.setAttribute('data-sf-orig-attr-filter', attrFilter);
                el.removeAttribute('filter');
              }
              if (el.style.filter) el.setAttribute('data-sf-orig-style-filter', el.style.filter);
              el.style.setProperty('filter', 'none', 'important');
              el.style.setProperty('-webkit-filter', 'none', 'important');
              el.setAttribute('data-sf-svg-target', String(idx));
              el.setAttribute('data-safarium-svg-surgery', spec.kind);

              ops.push({
                targetIndex: idx,
                kind: spec.kind,
                stdDeviation: spec.stdDeviation,
                dx: spec.dx,
                dy: spec.dy,
                floodColorRGBA: spec.floodColorRGBA,
                mergeSourceGraphic: spec.mergeSourceGraphic
              });
            }

            let sharpCount = 0;
            if (keepSharpText) {
              const thaiRe = /[\\u0E00-\\u0E7F]/;
              const sharpFontRe = /(Kanit|Mali|Trirong|Sarabun|Prompt|Noto Sans Thai|Noto Serif Thai|Thonburi|Ayuthaya)/i;
              const allTextCandidates = [...document.querySelectorAll('svg text, [data-safarium-sharp-text], body *')];
              for (const el of allTextCandidates) {
                const tag = el.localName;
                if (!el || tag === 'script' || tag === 'style' || tag === 'defs' || tag === 'filter' || tag === 'svg' || tag === 'canvas' || tag === 'img' || tag === 'tspan') continue;
                if (el.closest('[data-sf-sharp-text="1"]')) continue;
                if (el.hasAttribute('data-sf-svg-target')) continue;
                const explicit = el.hasAttribute('data-safarium-sharp-text');
                const isSvgText = (el.namespaceURI === 'http://www.w3.org/2000/svg' && tag === 'text');
                let hasDirectText = false;
                let directText = '';
                for (const child of el.childNodes) {
                  if (child.nodeType === 3 && child.nodeValue && child.nodeValue.trim().length > 0) {
                    hasDirectText = true;
                    directText += child.nodeValue;
                  }
                }
                const fullText = isSvgText ? (el.textContent || '') : directText;
                const fontFamily = getComputedStyle(el).fontFamily || '';
                const hasThai = thaiRe.test(fullText);
                const hasSharpFont = sharpFontRe.test(fontFamily);
                const containsGraphicChild = !isSvgText && Boolean(el.querySelector('svg, canvas, img, video'));
                if (explicit || (isSvgText && (hasThai || hasSharpFont)) || (hasDirectText && !containsGraphicChild && (hasThai || hasSharpFont))) {
                  el.setAttribute('data-sf-sharp-text', '1');
                  sharpCount++;
                }
              }
            }

            if (sharpCount > 0) {
              document.documentElement.dataset.safariumHasSharpText = '1';
            }
            document.documentElement.dataset.safariumSvgPass = 'all';
            window.__safariumPrismCheck();
            return {
              ops,
              hasSharpTextLayer: sharpCount > 0,
              sharpTextCount: sharpCount
            };
            """, arguments: ["preserveSharpText1x": preserveSharpText1x])

        guard let dict = raw as? [String: Any] else {
            return PrismSVGSurgeryPlan()
        }
        let rawOps = (dict["ops"] as? [[String: Any]]) ?? []
        var parsedOps: [PrismSVGSurgeryOp] = []
        parsedOps.reserveCapacity(rawOps.count)
        for entry in rawOps {
            guard let idx = (entry["targetIndex"] as? NSNumber)?.intValue,
                  let kindStr = entry["kind"] as? String,
                  let kind = PrismSVGSurgeryOp.Kind(rawValue: kindStr)
            else { continue }
            let stdDev = (entry["stdDeviation"] as? NSNumber)?.doubleValue ?? 4.0
            let dx = (entry["dx"] as? NSNumber)?.doubleValue ?? 0.0
            let dy = (entry["dy"] as? NSNumber)?.doubleValue ?? 0.0
            let rgba = ((entry["floodColorRGBA"] as? [NSNumber])?.map { $0.doubleValue }) ?? [0.0, 0.0, 0.0, 0.5]
            let mergeSG = (entry["mergeSourceGraphic"] as? Bool) ?? true
            parsedOps.append(PrismSVGSurgeryOp(
                targetIndex: idx,
                kind: kind,
                stdDeviation: stdDev,
                dx: dx,
                dy: dy,
                floodColorRGBA: rgba,
                mergeSourceGraphic: mergeSG
            ))
        }
        let hasSharp = (dict["hasSharpTextLayer"] as? Bool) ?? false
        let sharpCount = (dict["sharpTextCount"] as? NSNumber)?.intValue ?? 0
        return PrismSVGSurgeryPlan(ops: parsedOps, hasSharpTextLayer: hasSharp, sharpTextCount: sharpCount)
    }

    public func setSVGPassVisibilityMode(_ mode: String, targetIndex: Int? = nil) async throws {
        guard htmlLoaded, let page else {
            throw SafariumError.invalidState("loadHTMLFile must be called before setSVGPassVisibilityMode")
        }
        _ = try await page.evaluate("""
            for (const prev of document.querySelectorAll('[data-sf-active-target="1"]')) {
              prev.removeAttribute('data-sf-active-target');
            }
            if (mode === 'svg-target' && targetIndex !== null && targetIndex !== undefined) {
              const target = document.querySelector(`[data-sf-svg-target="${targetIndex}"]`);
              if (target) target.setAttribute('data-sf-active-target', '1');
            }
            document.documentElement.dataset.safariumSvgPass = mode;
            window.__safariumPrismCheck();
            return true;
            """, arguments: [
                "mode": mode,
                "targetIndex": targetIndex as Any,
            ])
    }

    public func readPageAnchors() async throws -> [PrismAnchor2D] {
        guard let page else { return [] }
        let raw = try await page.evaluate("""
            if (!window.__anchors) return [];
            if (Array.isArray(window.__anchors)) return window.__anchors;
            if (typeof window.__anchors === 'object') {
              return Object.entries(window.__anchors).map(([k, v]) => {
                if (Array.isArray(v)) return { name: k, pixelX: Number(v[0]||0), pixelY: Number(v[1]||0), visible: Boolean(v[2] ?? true) };
                return Object.assign({ name: k }, v);
              });
            }
            return [];
            """)
        guard let list = raw as? [[String: Any]] else { return [] }
        var out: [PrismAnchor2D] = []
        for item in list {
            let name = (item["name"] as? String) ?? "anchor"
            let px = (item["pixelX"] as? NSNumber)?.doubleValue ?? (item["x"] as? NSNumber)?.doubleValue ?? 0
            let py = (item["pixelY"] as? NSNumber)?.doubleValue ?? (item["y"] as? NSNumber)?.doubleValue ?? 0
            let vis = (item["visible"] as? Bool) ?? true
            let ndcX = (px / Double(max(1, width))) * 2.0 - 1.0
            let ndcY = 1.0 - (py / Double(max(1, height))) * 2.0
            out.append(PrismAnchor2D(
                name: name,
                worldPositionThree: PrismVec3(),
                ndcX: ndcX,
                ndcY: ndcY,
                ndcZ: 0,
                pixelX: px,
                pixelY: py,
                visible: vis
            ))
        }
        return out
    }

    // MARK: - Snapshot Capture

    public func snapshot() async throws -> Snapshot {
        guard let page else { throw SafariumError.invalidState("PrismWebKit3D closed") }
        let snap = try await page.snapshot()
        _ = try await page.evaluate("window.__safariumPrismCheck(); return true;")
        return snap
    }

    public func snapshotPixelBuffer(into reusablePB: CVPixelBuffer? = nil) async throws -> CVPixelBuffer {
        let snap = try await snapshot()
        let pb: CVPixelBuffer
        if let reusablePB,
           CVPixelBufferGetWidth(reusablePB) == width,
           CVPixelBufferGetHeight(reusablePB) == height,
           CVPixelBufferGetPixelFormatType(reusablePB) == kCVPixelFormatType_32BGRA {
            pb = reusablePB
        } else {
            pb = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra)
        }
        try snap.draw(into: pb, width: width, height: height)
        return pb
    }

    // MARK: - Embedded Pure WebGL2 Offline GLB Parser + Linear-to-sRGB PBR Renderer

    private static func builtinGLBViewerHTML(width: Int, height: Int, transparent: Bool) -> String {
        let bodyBg = transparent ? "transparent" : "#000000"
        let clearColorJS = transparent
            ? "gl.clearColor(0.0, 0.0, 0.0, 0.0);"
            : "gl.clearColor(0.2235, 0.3490, 0.5294, 1.0);"
        let alphaOpt = transparent ? "true" : "false"
        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          html, body { margin: 0; padding: 0; background: \(bodyBg); overflow: hidden; }
          canvas { display: block; width: 100vw; height: 100vh; }
        </style>
        </head>
        <body>
        <canvas id="c" width="\(width)" height="\(height)"></canvas>
        <script>
        (() => {
          const canvas = document.getElementById('c');
          const gl = canvas.getContext('webgl2', {
            alpha: \(alphaOpt),
            antialias: true,
            depth: true,
            premultipliedAlpha: true,
            preserveDrawingBuffer: true,
            powerPreference: 'high-performance'
          });

          function m4Identity() {
            const m = new Float32Array(16);
            m[0] = m[5] = m[10] = m[15] = 1;
            return m;
          }
          function m4Mul(a, b) {
            const out = new Float32Array(16);
            for (let c = 0; c < 4; c++) {
              for (let r = 0; r < 4; r++) {
                out[c*4 + r] = a[0*4+r]*b[c*4+0] + a[1*4+r]*b[c*4+1] + a[2*4+r]*b[c*4+2] + a[3*4+r]*b[c*4+3];
              }
            }
            return out;
          }
          function m4TRS(t, q, s) {
            const x = q[0], y = q[1], z = q[2], w = q[3];
            const x2 = x+x, y2 = y+y, z2 = z+z;
            const xx = x*x2, xy = x*y2, xz = x*z2;
            const yy = y*y2, yz = y*z2, zz = z*z2;
            const wx = w*x2, wy = w*y2, wz = w*z2;
            const sx = s[0], sy = s[1], sz = s[2];
            const out = new Float32Array(16);
            out[0] = (1 - (yy + zz)) * sx; out[1] = (xy + wz) * sx;       out[2] = (xz - wy) * sx;       out[3] = 0;
            out[4] = (xy - wz) * sy;       out[5] = (1 - (xx + zz)) * sy; out[6] = (yz + wx) * sy;       out[7] = 0;
            out[8] = (xz + wy) * sz;       out[9] = (yz - wx) * sz;       out[10] = (1 - (xx + yy)) * sz; out[11] = 0;
            out[12] = t[0];                out[13] = t[1];                out[14] = t[2];                out[15] = 1;
            return out;
          }
          function m4InvertRigid(m) {
            const r00 = m[0], r01 = m[4], r02 = m[8];
            const r10 = m[1], r11 = m[5], r12 = m[9];
            const r20 = m[2], r21 = m[6], r22 = m[10];
            const tx = m[12], ty = m[13], tz = m[14];
            const out = new Float32Array(16);
            out[0] = r00; out[4] = r10; out[8]  = r20; out[12] = -(r00*tx + r10*ty + r20*tz);
            out[1] = r01; out[5] = r11; out[9]  = r21; out[13] = -(r01*tx + r11*ty + r21*tz);
            out[2] = r02; out[6] = r12; out[10] = r22; out[14] = -(r02*tx + r12*ty + r22*tz);
            out[3] = 0;   out[7] = 0;   out[11] = 0;   out[15] = 1;
            return out;
          }
          function m4Perspective(fovYDeg, aspect, near, far, shiftX = 0, shiftY = 0, fit = 'AUTO') {
            const f = 1.0 / Math.tan((fovYDeg * Math.PI / 180.0) * 0.5);
            const nf = 1.0 / (near - far);
            const fitToW = (fit === 'HORIZONTAL') || (fit === 'AUTO' && aspect >= 1.0);
            const p02 = fitToW ? (2.0 * shiftX) : (2.0 * shiftX / Math.max(1e-6, aspect));
            const p12 = fitToW ? (2.0 * shiftY * aspect) : (2.0 * shiftY);
            const out = new Float32Array(16);
            out[0] = f / Math.max(1e-6, aspect);
            out[5] = f;
            out[8] = p02;
            out[9] = p12;
            out[10] = (far + near) * nf;
            out[11] = -1.0;
            out[14] = 2.0 * far * near * nf;
            return out;
          }
          function m4LookAt(eye, target, up) {
            let zx = eye[0]-target[0], zy = eye[1]-target[1], zz = eye[2]-target[2];
            let zn = Math.hypot(zx, zy, zz) || 1; zx /= zn; zy /= zn; zz /= zn;
            let xx = up[1]*zz - up[2]*zy, xy = up[2]*zx - up[0]*zz, xz = up[0]*zy - up[1]*zx;
            let xn = Math.hypot(xx, xy, xz) || 1; xx /= xn; xy /= xn; xz /= xn;
            let yx = zy*xz - zz*xy, yy = zz*xx - zx*xz, yz = zx*xy - zy*xx;
            const out = new Float32Array(16);
            out[0]=xx; out[4]=xy; out[8]=xz;  out[12]=-(xx*eye[0]+xy*eye[1]+xz*eye[2]);
            out[1]=yx; out[5]=yy; out[9]=yz;  out[13]=-(yx*eye[0]+yy*eye[1]+yz*eye[2]);
            out[2]=zx; out[6]=zy; out[10]=zz; out[14]=-(zx*eye[0]+zy*eye[1]+zz*eye[2]);
            out[3]=0;  out[7]=0;  out[11]=0;  out[15]=1;
            return out;
          }
          function m4NormalMat3(m) {
            const a00=m[0], a01=m[1], a02=m[2];
            const a10=m[4], a11=m[5], a12=m[6];
            const a20=m[8], a21=m[9], a22=m[10];
            const b01 = a22*a11 - a12*a21, b11 = -a22*a10 + a12*a20, b21 = a21*a10 - a11*a20;
            const det = a00*b01 + a01*b11 + a02*b21 || 1.0;
            const inv = 1.0 / det;
            return new Float32Array([
              b01*inv, (-a22*a01 + a02*a21)*inv, (a12*a01 - a02*a11)*inv,
              b11*inv, (a22*a00 - a02*a20)*inv, (-a12*a00 + a02*a10)*inv,
              b21*inv, (-a21*a00 + a01*a20)*inv, (a11*a00 - a01*a10)*inv
            ]);
          }

          const VS = `#version 300 es
          precision highp float;
          layout(location=0) in vec3 aPos;
          layout(location=1) in vec3 aNorm;
          uniform mat4 uModel;
          uniform mat4 uViewProj;
          uniform mat3 uNormalMat;
          out vec3 vWorldPos;
          out vec3 vWorldNorm;
          void main() {
            vec4 wp = uModel * vec4(aPos, 1.0);
            vWorldPos = wp.xyz;
            vWorldNorm = normalize(uNormalMat * aNorm);
            gl_Position = uViewProj * wp;
          }`;

          const FS = `#version 300 es
          precision highp float;
          in vec3 vWorldPos;
          in vec3 vWorldNorm;
          uniform vec4 uBaseColor;
          uniform float uMetallic;
          uniform float uRoughness;
          uniform vec3 uCamPos;
          out vec4 outColor;

          vec3 linearToSrgb(vec3 c) {
            c = clamp(c, 0.0, 1.0);
            return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
          }

          void main() {
            vec3 N = normalize(vWorldNorm);
            vec3 V = normalize(uCamPos - vWorldPos);
            vec3 L1 = normalize(vec3(0.55, 0.72, 0.42));
            vec3 L2 = normalize(vec3(-0.6, 0.5, -0.4));
            vec3 base = uBaseColor.rgb;
            vec3 F0 = mix(vec3(0.04), base, uMetallic);
            vec3 H1 = normalize(L1 + V);
            float ndl1 = max(dot(N, L1), 0.0);
            float ndh1 = max(dot(N, H1), 0.0);
            float ndv = max(dot(N, V), 0.001);
            float rough = clamp(uRoughness, 0.08, 1.0);
            float shininess = mix(128.0, 6.0, rough * rough);
            float spec1 = pow(ndh1, shininess) * (0.25 + 1.5 * (1.0 - rough));
            vec3 fresnel = F0 + (1.0 - F0) * pow(1.0 - ndv, 4.0);
            vec3 diff1 = base * (1.0 - uMetallic) * ndl1 * vec3(1.0, 0.97, 0.92) * 1.1;
            vec3 specCol = mix(vec3(1.0), base, uMetallic) * spec1 * fresnel * ndl1;
            float ndl2 = max(dot(N, L2), 0.0);
            vec3 fill = base * (1.0 - uMetallic) * ndl2 * vec3(0.45, 0.55, 0.72) * 0.45;
            vec3 ambient = base * vec3(0.18, 0.22, 0.30);
            vec3 lin = ambient + diff1 + specCol + fill;
            vec3 srgb = linearToSrgb(lin);
            outColor = vec4(srgb * uBaseColor.a, uBaseColor.a);
          }`;

          function compileShader(type, src) {
            const s = gl.createShader(type);
            gl.shaderSource(s, src);
            gl.compileShader(s);
            if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
              throw new Error('Shader compile: ' + gl.getShaderInfoLog(s));
            }
            return s;
          }

          let prog = null, locs = {};
          if (gl) {
            prog = gl.createProgram();
            gl.attachShader(prog, compileShader(gl.VERTEX_SHADER, VS));
            gl.attachShader(prog, compileShader(gl.FRAGMENT_SHADER, FS));
            gl.linkProgram(prog);
            if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) {
              throw new Error('Program link: ' + gl.getProgramInfoLog(prog));
            }
            locs = {
              uModel: gl.getUniformLocation(prog, 'uModel'),
              uViewProj: gl.getUniformLocation(prog, 'uViewProj'),
              uNormalMat: gl.getUniformLocation(prog, 'uNormalMat'),
              uBaseColor: gl.getUniformLocation(prog, 'uBaseColor'),
              uMetallic: gl.getUniformLocation(prog, 'uMetallic'),
              uRoughness: gl.getUniformLocation(prog, 'uRoughness'),
              uCamPos: gl.getUniformLocation(prog, 'uCamPos'),
            };
          }

          const COMP_ARRAY = { 5120: Int8Array, 5121: Uint8Array, 5122: Int16Array, 5123: Uint16Array, 5125: Uint32Array, 5126: Float32Array };
          const TYPE_COUNT = { SCALAR: 1, VEC2: 2, VEC3: 3, VEC4: 4, MAT4: 16 };
          let drawList = [];
          let loadedCam = null;
          let boundsCenter = [0, 0.85, 0];
          let boundsRadius = 1.6;

          function readAccessor(gltf, binBuf, accIdx) {
            const acc = gltf.accessors[accIdx];
            const bv = gltf.bufferViews[acc.bufferView];
            const Ctor = COMP_ARRAY[acc.componentType];
            const nComp = TYPE_COUNT[acc.type];
            const byteOff = (bv.byteOffset || 0) + (acc.byteOffset || 0);
            const stride = bv.byteStride || (Ctor.BYTES_PER_ELEMENT * nComp);
            if (stride === Ctor.BYTES_PER_ELEMENT * nComp) {
              return new Ctor(binBuf, byteOff, acc.count * nComp);
            }
            const out = new Ctor(acc.count * nComp);
            const dv = new DataView(binBuf);
            for (let i = 0; i < acc.count; i++) {
              const base = byteOff + i * stride;
              for (let k = 0; k < nComp; k++) {
                const p = base + k * Ctor.BYTES_PER_ELEMENT;
                if (Ctor === Float32Array) out[i*nComp+k] = dv.getFloat32(p, true);
                else if (Ctor === Uint16Array) out[i*nComp+k] = dv.getUint16(p, true);
                else if (Ctor === Uint32Array) out[i*nComp+k] = dv.getUint32(p, true);
              }
            }
            return out;
          }

          function loadGLBBase64(b64) {
            const rawStr = atob(b64);
            const bytes = new Uint8Array(rawStr.length);
            for (let i = 0; i < rawStr.length; i++) bytes[i] = rawStr.charCodeAt(i);
            const dv = new DataView(bytes.buffer);
            const magic = dv.getUint32(0, true);
            if (magic !== 0x46546C67) throw new Error('Invalid GLB magic');
            const jsonLen = dv.getUint32(12, true);
            const gltf = JSON.parse(new TextDecoder().decode(bytes.subarray(20, 20 + jsonLen)));
            const binOff = 20 + jsonLen;
            const binLen = dv.getUint32(binOff, true);
            const binBuf = bytes.buffer.slice(binOff + 8, binOff + 8 + binLen);

            drawList = [];
            loadedCam = null;
            const bMin = [Infinity, Infinity, Infinity];
            const bMax = [-Infinity, -Infinity, -Infinity];
            const sceneIdx = gltf.scene ?? 0;
            const roots = (gltf.scenes && gltf.scenes[sceneIdx] && gltf.scenes[sceneIdx].nodes) || [];

            function visit(nodeIdx, parentMat) {
              const node = gltf.nodes[nodeIdx];
              let local;
              if (node.matrix) {
                local = new Float32Array(node.matrix);
              } else {
                const t = node.translation || [0, 0, 0];
                const r = node.rotation || [0, 0, 0, 1];
                const s = node.scale || [1, 1, 1];
                local = m4TRS(t, r, s);
              }
              const world = m4Mul(parentMat, local);
              if (node.camera !== undefined && gltf.cameras) {
                const cdef = gltf.cameras[node.camera];
                if (cdef && cdef.perspective) {
                  loadedCam = {
                    worldMat: world,
                    pos: [world[12], world[13], world[14]],
                    fovYDeg: cdef.perspective.yfov * 180 / Math.PI,
                    aspect: cdef.perspective.aspectRatio || (canvas.width / canvas.height),
                    near: cdef.perspective.znear || 0.1,
                    far: cdef.perspective.zfar || 100.0
                  };
                }
              }
              if (node.mesh !== undefined) {
                const mesh = gltf.meshes[node.mesh];
                for (const prim of mesh.primitives) {
                  const pos = readAccessor(gltf, binBuf, prim.attributes.POSITION);
                  for (let i = 0; i < pos.length; i += 3) {
                    const x = pos[i], y = pos[i+1], z = pos[i+2];
                    const wx = world[0]*x + world[4]*y + world[8]*z + world[12];
                    const wy = world[1]*x + world[5]*y + world[9]*z + world[13];
                    const wz = world[2]*x + world[6]*y + world[10]*z + world[14];
                    if (wx < bMin[0]) bMin[0] = wx; if (wx > bMax[0]) bMax[0] = wx;
                    if (wy < bMin[1]) bMin[1] = wy; if (wy > bMax[1]) bMax[1] = wy;
                    if (wz < bMin[2]) bMin[2] = wz; if (wz > bMax[2]) bMax[2] = wz;
                  }
                  const norm = prim.attributes.NORMAL !== undefined
                    ? readAccessor(gltf, binBuf, prim.attributes.NORMAL)
                    : new Float32Array(pos.length);
                  const idx = prim.indices !== undefined ? readAccessor(gltf, binBuf, prim.indices) : null;
                  const vao = gl.createVertexArray();
                  gl.bindVertexArray(vao);
                  const vbPos = gl.createBuffer();
                  gl.bindBuffer(gl.ARRAY_BUFFER, vbPos);
                  gl.bufferData(gl.ARRAY_BUFFER, pos, gl.STATIC_DRAW);
                  gl.enableVertexAttribArray(0);
                  gl.vertexAttribPointer(0, 3, gl.FLOAT, false, 0, 0);

                  const vbNorm = gl.createBuffer();
                  gl.bindBuffer(gl.ARRAY_BUFFER, vbNorm);
                  gl.bufferData(gl.ARRAY_BUFFER, norm, gl.STATIC_DRAW);
                  gl.enableVertexAttribArray(1);
                  gl.vertexAttribPointer(1, 3, gl.FLOAT, false, 0, 0);

                  let idxType = gl.UNSIGNED_SHORT, count = pos.length / 3;
                  if (idx) {
                    const eb = gl.createBuffer();
                    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, eb);
                    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, idx, gl.STATIC_DRAW);
                    idxType = idx instanceof Uint32Array ? gl.UNSIGNED_INT : gl.UNSIGNED_SHORT;
                    count = idx.length;
                  }
                  gl.bindVertexArray(null);

                  const matObj = prim.material !== undefined && gltf.materials ? gltf.materials[prim.material] : null;
                  const pbr = (matObj && matObj.pbrMetallicRoughness) || {};
                  drawList.push({
                    vao, hasIdx: !!idx, idxType, count,
                    modelMat: world,
                    normalMat: m4NormalMat3(world),
                    baseColor: pbr.baseColorFactor || [0.85, 0.35, 0.25, 1.0],
                    metallic: pbr.metallicFactor ?? 0.15,
                    roughness: pbr.roughnessFactor ?? 0.4,
                  });
                }
              }
              for (const ch of (node.children || [])) visit(ch, world);
            }

            const I = m4Identity();
            for (const r of roots) visit(r, I);
            if (Number.isFinite(bMin[0])) {
              boundsCenter = [(bMin[0]+bMax[0])*0.5, (bMin[1]+bMax[1])*0.5, (bMin[2]+bMax[2])*0.5];
              boundsRadius = Math.max(0.5, Math.hypot(bMax[0]-bMin[0], bMax[1]-bMin[1], bMax[2]-bMin[2]) * 0.5);
            }
            return { primitives: drawList.length, hasCamera: !!loadedCam };
          }

          let currentViewProj = m4Identity();

          function renderWithViewProj(viewMat, projMat, camPos) {
            currentViewProj = m4Mul(projMat, viewMat);
            gl.viewport(0, 0, canvas.width, canvas.height);
            gl.enable(gl.DEPTH_TEST);
            gl.enable(gl.CULL_FACE);
            \(clearColorJS)
            gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
            gl.useProgram(prog);
            gl.uniformMatrix4fv(locs.uViewProj, false, currentViewProj);
            gl.uniform3fv(locs.uCamPos, camPos);
            for (const d of drawList) {
              gl.uniformMatrix4fv(locs.uModel, false, d.modelMat);
              gl.uniformMatrix3fv(locs.uNormalMat, false, d.normalMat);
              gl.uniform4fv(locs.uBaseColor, d.baseColor);
              gl.uniform1f(locs.uMetallic, d.metallic);
              gl.uniform1f(locs.uRoughness, d.roughness);
              gl.bindVertexArray(d.vao);
              if (d.hasIdx) gl.drawElements(gl.TRIANGLES, d.count, d.idxType, 0);
              else gl.drawArrays(gl.TRIANGLES, 0, d.count);
            }
            gl.bindVertexArray(null);
            gl.finish();
          }

          window.__PRISM = {
            setResolution(w, h) {
              canvas.width = w;
              canvas.height = h;
            },
            async checkCapabilities() {
              const out = { webgl2: false, webgpu: false };
              if (gl) {
                const dbg = gl.getExtension('WEBGL_debug_renderer_info');
                out.webgl2 = true;
                out.webgl2Renderer = dbg ? gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER);
                out.webgl2Vendor = dbg ? gl.getParameter(dbg.UNMASKED_VENDOR_WEBGL) : gl.getParameter(gl.VENDOR);
                out.maxTextureSize = gl.getParameter(gl.MAX_TEXTURE_SIZE);
                out.maxSamples = gl.getParameter(gl.MAX_SAMPLES);
              }
              if (navigator.gpu) {
                try {
                  const adapter = await navigator.gpu.requestAdapter();
                  if (adapter) {
                    const device = await adapter.requestDevice();
                    if (device) {
                      out.webgpu = true;
                      device.destroy?.();
                    }
                  }
                } catch (_) {}
              }
              return out;
            },
            loadGLB(b64) {
              return loadGLBBase64(b64);
            },
            renderWithCamera(pos, quatXYZW, fovYDeg, aspect, near, far, shiftX = 0, shiftY = 0, fit = 'AUTO') {
              const t0 = performance.now();
              const camWorld = m4TRS(pos, quatXYZW, [1, 1, 1]);
              const view = m4InvertRigid(camWorld);
              const proj = m4Perspective(fovYDeg, aspect, near, far, shiftX, shiftY, fit);
              renderWithViewProj(view, proj, pos);
              return performance.now() - t0;
            },
            renderAngle(deg) {
              const t0 = performance.now();
              const rad = deg * Math.PI / 180.0;
              const dist = Math.max(3.6, boundsRadius * 2.6);
              const pos = [
                boundsCenter[0] + dist * Math.sin(rad),
                boundsCenter[1] + dist * 0.35,
                boundsCenter[2] + dist * Math.cos(rad)
              ];
              const view = m4LookAt(pos, boundsCenter, [0, 1, 0]);
              const proj = m4Perspective(49.134, canvas.width / canvas.height, 0.1, 200.0);
              renderWithViewProj(view, proj, pos);
              return performance.now() - t0;
            },
            projectPoints(pts) {
              return pts.map(([x, y, z]) => {
                const m = currentViewProj;
                const cx = m[0]*x + m[4]*y + m[8]*z  + m[12];
                const cy = m[1]*x + m[5]*y + m[9]*z  + m[13];
                const cz = m[2]*x + m[6]*y + m[10]*z + m[14];
                const cw = m[3]*x + m[7]*y + m[11]*z + m[15];
                return [cx / cw, cy / cw, cz / cw];
              });
            }
          };
        })();
        </script>
        </body>
        </html>
        """
    }
}
