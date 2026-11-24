import Accelerate
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import Metal
import SafariumContainers
import SafariumCore
import WebKit

// MARK: - Execution Report

public struct ForgeExecutionReport: Codable, Sendable {
    public let schema: String
    public let outputPath: String
    public let secondaryOutputPath: String?
    public let container: String
    public let width: Int
    public let height: Int
    public let fps: Int
    public let framesRendered: Int
    public let htmlFramesCaptured: Int
    public let htmlFramesReusedDirtyHold: Int
    public let wkWebViewRecycles: Int
    public let thermalCooldownEvents: Int
    public let audioDurationSeconds: Double?
    public let qaReport: ForgeQAReport?
    public let primaryBytes: Int64
    public let secondaryBytes: Int64?
    public let wallMs: Double
    public let monochromeOK: Bool?
    public let maxChromaDelta: Double?
    public let sceneCacheHit: Bool?
    public let inlineSheetPath: String?

    public init(
        schema: String,
        outputPath: String,
        secondaryOutputPath: String?,
        container: String,
        width: Int,
        height: Int,
        fps: Int,
        framesRendered: Int,
        htmlFramesCaptured: Int,
        htmlFramesReusedDirtyHold: Int,
        wkWebViewRecycles: Int,
        thermalCooldownEvents: Int,
        audioDurationSeconds: Double?,
        qaReport: ForgeQAReport?,
        primaryBytes: Int64,
        secondaryBytes: Int64?,
        wallMs: Double,
        monochromeOK: Bool? = nil,
        maxChromaDelta: Double? = nil,
        sceneCacheHit: Bool? = nil,
        inlineSheetPath: String? = nil
    ) {
        self.schema = schema
        self.outputPath = outputPath
        self.secondaryOutputPath = secondaryOutputPath
        self.container = container
        self.width = width
        self.height = height
        self.fps = fps
        self.framesRendered = framesRendered
        self.htmlFramesCaptured = htmlFramesCaptured
        self.htmlFramesReusedDirtyHold = htmlFramesReusedDirtyHold
        self.wkWebViewRecycles = wkWebViewRecycles
        self.thermalCooldownEvents = thermalCooldownEvents
        self.audioDurationSeconds = audioDurationSeconds
        self.qaReport = qaReport
        self.primaryBytes = primaryBytes
        self.secondaryBytes = secondaryBytes
        self.wallMs = wallMs
        self.monochromeOK = monochromeOK
        self.maxChromaDelta = maxChromaDelta
        self.sceneCacheHit = sceneCacheHit
        self.inlineSheetPath = inlineSheetPath
    }
}

// MARK: - Bounded IOSurface <= 4-Slot Ring Pool

private final class ForgeIOSurfaceRing {
    private struct Key: Hashable { let w: Int; let h: Int }
    private let capacity: Int
    private var rings: [Key: [CVPixelBuffer]] = [:]
    private var cursors: [Key: Int] = [:]

    init(capacity: Int = 4) {
        self.capacity = max(1, min(4, capacity))
    }

    func acquire(width: Int, height: Int, excluding: [CVPixelBuffer] = []) throws -> CVPixelBuffer {
        let key = Key(w: width, h: height)
        var ring = rings[key] ?? []
        let excludedIDs = Set(excluding.map { ObjectIdentifier($0) })
        if !ring.isEmpty {
            let start = cursors[key] ?? 0
            for step in 0..<ring.count {
                let idx = (start + step) % ring.count
                let cand = ring[idx]
                if !excludedIDs.contains(ObjectIdentifier(cand)) {
                    cursors[key] = (idx + 1) % max(1, ring.count)
                    return cand
                }
            }
        }
        let pb = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra)
        if ring.count < capacity {
            ring.append(pb)
            rings[key] = ring
            cursors[key] = 0
        }
        return pb
    }

    func clearAll() {
        rings.removeAll()
        cursors.removeAll()
    }
}

// MARK: - Windowless WKWebView Mode C + 200f Serial Recycle Manager

@MainActor
private final class ForgeHTMLOverlaySource {
    let inputID: String
    let htmlURL: URL
    let width: Int
    let height: Int
    let modeCDirtyHold: Bool
    let recycleEveryFrames: Int

    private var page: Page?
    private var stagingDir: URL?
    private var ruleList: WKContentRuleList?
    private var cachedTexture: MTLTexture?
    private var cachedPixelBuffer: CVPixelBuffer?
    private(set) var framesCaptured = 0
    private(set) var framesReusedDirtyHold = 0
    private(set) var recycleCount = 0

    private static let observeErrorsJS = """
    (() => {
      let failure;
      const fail = text => { failure ??= String(text).slice(0, 300); };
      window.addEventListener('error', e => {
        if (e instanceof ErrorEvent) fail(e.message || 'page script failed');
        else if (e.target?.matches?.('script,link[rel~="stylesheet"],img'))
          fail('could not load local <' + e.target.localName + '> asset');
      }, true);
      window.addEventListener('unhandledrejection', e => fail(e.reason?.message || 'unhandled page promise rejection'));
      Object.defineProperty(window, '__safariumForgeCheck', { value: () => { if (failure) throw new Error(failure); } });
    })();
    """

    init(
        inputID: String,
        htmlURL: URL,
        width: Int,
        height: Int,
        modeCDirtyHold: Bool,
        recycleEveryFrames: Int,
        stagingRoot: URL
    ) throws {
        try SafeFilePublisher.assertRegularReadableFile(htmlURL)
        self.inputID = inputID
        self.htmlURL = htmlURL
        self.width = width
        self.height = height
        self.modeCDirtyHold = modeCDirtyHold
        self.recycleEveryFrames = max(1, recycleEveryFrames)
        let dir = stagingRoot.appendingPathComponent("wk-\(inputID)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.stagingDir = dir
    }

    func prepare() async throws {
        HostApp.prepare()
        if ruleList == nil, let dir = stagingDir {
            let store = WKContentRuleListStore(url: dir)
            let rules = """
            [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
             {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]
            """
            guard let store,
                  let compiled = try await store.compileContentRuleList(forIdentifier: "local-only-\(inputID)", encodedContentRuleList: rules) else {
                throw SafariumError.invalidState("failed compiling WKContentRuleList for HTML overlay '\(inputID)'")
            }
            ruleList = compiled
        }
        try await createAndLoadPage()
    }

    private func createAndLoadPage() async throws {
        page?.close()
        page = nil
        guard let rule = self.ruleList else {
            throw SafariumError.invalidState("missing compiled WKContentRuleList for HTML overlay '\(inputID)'")
        }
        let useDirty = self.modeCDirtyHold
        let p = try await Page(config: PageConfig(
            width: width, height: height, scale: 1,
            transparent: true, deterministicClock: true, video: .none, snapshotQuality: .fast
        )) { wc in
            wc.websiteDataStore = .nonPersistent()
            wc.mediaTypesRequiringUserActionForPlayback = .all
            wc.userContentController.add(rule)
            if useDirty { wc.userContentController.addUserScript(StaticHoldProbe.userScript()) }
            wc.userContentController.addUserScript(WKUserScript(
                source: Self.observeErrorsJS, injectionTime: .atDocumentStart, forMainFrameOnly: true
            ))
        }
        try await p.load(.fileURL(htmlURL))
        try await p.waitFor(.fonts)
        try await p.waitFor(.images)
        _ = try await p.evaluate("window.__safariumForgeCheck(); return true")
        self.page = p
    }

    func captureFrame(at timeSeconds: Double, frameIndex: Int, engine: ForgeMetalFilterEngine) async throws -> (pb: CVPixelBuffer, tex: MTLTexture) {
        if frameIndex > 0 && frameIndex % recycleEveryFrames == 0 {
            try await createAndLoadPage()
            recycleCount += 1
            cachedTexture = nil
            cachedPixelBuffer = nil
        }
        guard let page else {
            throw SafariumError.invalidState("HTML overlay '\(inputID)' not prepared")
        }

        if modeCDirtyHold {
            _ = try? await page.evaluate("if (window.__sfDirtyProbe) window.__sfDirtyProbe.beginStep(); return true")
        }
        try await page.seek(timeSeconds)
        _ = try await page.evaluate("window.__safariumForgeCheck(); return true")

        var shouldReuse = false
        if modeCDirtyHold, cachedTexture != nil, cachedPixelBuffer != nil {
            if let res = try? await page.evaluate("return window.__sfDirtyProbe ? window.__sfDirtyProbe.consumeStep() : { dirty: true }") as? [String: Any],
               let dirty = res["dirty"] as? Bool, !dirty {
                shouldReuse = true
            }
        }

        if shouldReuse, let pb = cachedPixelBuffer, let tex = cachedTexture {
            framesReusedDirtyHold += 1
            return (pb, tex)
        }

        let snap = try await page.snapshot()
        let pb: CVPixelBuffer
        if let existing = cachedPixelBuffer {
            pb = existing
        } else {
            pb = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra)
            cachedPixelBuffer = pb
        }
        try snap.draw(into: pb, width: width, height: height)
        let tex = try engine.uploadCGImageToTexture(snap.cgImage)
        cachedTexture = tex
        framesCaptured += 1
        return (pb, tex)
    }

    func close() {
        page?.close()
        page = nil
        cachedTexture = nil
        cachedPixelBuffer = nil
        if let dir = stagingDir {
            try? FileManager.default.removeItem(at: dir)
            stagingDir = nil
        }
    }
}

private struct DeinterlaceHistoryRing {
    var buffers: [CVPixelBuffer] = []
    var width: Int = 0
    var height: Int = 0
    var cursor: Int = 0
    var filled: Int = 0

    func prevPB(fallback: CVPixelBuffer) -> CVPixelBuffer {
        if filled >= 2 { return buffers[(cursor - 2 + buffers.count) % buffers.count] }
        if filled >= 1 { return buffers[(cursor - 1 + buffers.count) % buffers.count] }
        return fallback
    }

    func currPB(fallback: CVPixelBuffer) -> CVPixelBuffer {
        if filled >= 1 { return buffers[(cursor - 1 + buffers.count) % buffers.count] }
        return fallback
    }

    mutating func push(_ src: CVPixelBuffer, width w: Int, height h: Int, filterEngine: ForgeMetalFilterEngine) throws {
        if buffers.count < 3 || width != w || height != h {
            buffers = try (0..<3).map { _ in
                try AVAssetWriterSink.allocateStandalonePixelBuffer(width: w, height: h, pixelFormat: .bgra)
            }
            width = w
            height = h
            cursor = 0
            filled = 0
        }
        try filterEngine.applyGeom(srcPB: src, into: buffers[cursor % buffers.count])
        cursor += 1
        filled = min(3, filled + 1)
    }
}

// MARK: - ForgeGraphExecutor

public enum ForgeGraphExecutor {
    public typealias RawPipeFrameProvider = (_ inputID: String, _ frameIndex: Int, _ expectedBytes: Int) throws -> Data?

    public static func execute(
        recipe: ForgeRecipe,
        rawPipeProvider: RawPipeFrameProvider? = nil,
        progressEmitter: SafariumProgressEmitter? = nil
    ) async throws -> ForgeExecutionReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let plan = try ForgeRecipeValidator.validate(recipe)
        MediaCompatBridge.registerSupplementalDecoders()

        let outURL = URL(fileURLWithPath: recipe.output.path)
        let overwrite = recipe.output.overwrite ?? false
        let stage = try APFSAutoStage.makeSession(
            for: outURL,
            cacheRoot: recipe.job?.stagePolicy?.cacheDir.map { URL(fileURLWithPath: $0, isDirectory: true) },
            overwrite: overwrite
        )
        defer { stage.cleanup() }

        let secOutURL = recipe.output.secondaryPath.map { URL(fileURLWithPath: $0) }
        let secStage: APFSStageSession? = try secOutURL.map {
            try APFSAutoStage.makeSession(for: $0, overwrite: overwrite)
        }
        defer { secStage?.cleanup() }

        // 1. Demux any MKV/WebM/TS/MPEG-PS inputs into APFS stage
        var resolvedPaths: [String: URL] = [:]
        var audioSourceURLs: [String: URL] = [:]
        var mpeg2PreTrimmedInputs: Set<String> = []
        for inp in recipe.inputs {
            if inp.kind == .imageSequence {
                if let p = inp.path {
                    resolvedPaths[inp.id] = URL(fileURLWithPath: p)
                }
                continue
            }
            guard let p = inp.path else { continue }
            let srcURL = URL(fileURLWithPath: p)
            if inp.kind == .video || inp.kind == .audio {
                try SafeFilePublisher.assertRegularReadableFile(srcURL)
                audioSourceURLs[inp.id] = srcURL
                let demuxMode = (inp.demux ?? srcURL.pathExtension).lowercased()
                if demuxMode == "mkv" || demuxMode == "webm" {
                    let demuxOut = stage.fileURL("demux_\(inp.id).mp4")
                    _ = try await EBMLMatroskaCodec.demuxToMP4(inputURL: srcURL, outputURL: demuxOut, overwrite: true)
                    resolvedPaths[inp.id] = demuxOut
                } else if demuxMode == "ts" || demuxMode == "m2ts" {
                    let demuxOut = stage.fileURL("demux_\(inp.id).mp4")
                    _ = try await MPEGTSCodec.demuxToMP4(inputURL: srcURL, outputURL: demuxOut, overwrite: true)
                    resolvedPaths[inp.id] = demuxOut
                } else if inp.kind == .video && (demuxMode == "mpeg" || demuxMode == "mpg") {
                    let psInfo = try MPEG2ProgramStream.inspect(url: srcURL)
                    guard let seq = psInfo.sequence else {
                        throw SafariumError.encode("MPEG-2 Program Stream missing sequence header: \(srcURL.lastPathComponent)")
                    }
                    let trimS = max(0.0, inp.trim?.first ?? 0.0)
                    let targetDur = ((inp.trim?.count ?? 0) >= 2 ? max(0.05, inp.trim![1] - trimS) : nil)
                        ?? recipe.timeline.durationSeconds
                        ?? max(0.05, psInfo.durationSeconds - trimS)
                    let psFPS = max(1, Int(seq.framesPerSecond.rounded()))
                    let neededOutFrames = max(1, Int((targetDur * Double(psFPS)).rounded(.up)) + 4)
                    let maxScanFrames = max(neededOutFrames, Int(((trimS + targetDur + 1.0) * seq.framesPerSecond).rounded(.up)) + 4)
                    let stagedMP4 = stage.fileURL("demux_mpeg2_\(inp.id).mp4")
                    try await decodeMPEG2WindowToMP4(
                        sourceURL: srcURL,
                        outputURL: stagedMP4,
                        width: seq.width,
                        height: seq.height,
                        fps: psFPS,
                        trimStartSeconds: trimS,
                        maxOutputFrames: neededOutFrames,
                        maxDecodeFrames: maxScanFrames
                    )
                    resolvedPaths[inp.id] = stagedMP4
                    mpeg2PreTrimmedInputs.insert(inp.id)
                } else {
                    resolvedPaths[inp.id] = srcURL
                }
            } else {
                try SafeFilePublisher.assertRegularReadableFile(srcURL)
                resolvedPaths[inp.id] = srcURL
            }
        }

        // 2. Execute Audio Graph (O(4096) streaming)
        let audioResult = try await executeAudioGraph(
            plan: plan,
            resolvedPaths: resolvedPaths,
            audioSourceURLs: audioSourceURLs,
            stage: stage
        )

        // Check audio-only output shortcut
        let container = plan.resolvedContainer
        if ["wav", "m4a", "mp3", "flac", "caf"].contains(container) {
            guard let finalAudioURL = audioResult.finalURL else {
                throw SafariumError.invalidState("audio-only output '\(outURL.lastPathComponent)' produced no audio")
            }
            let finalStaged: URL
            if finalAudioURL.pathExtension.lowercased() == container {
                finalStaged = finalAudioURL
            } else if container == "wav" || container == "m4a" {
                let converted = stage.fileURL("audio_final.\(container)")
                _ = try await ForgeAudioDSP.processAudio(
                    inputURL: finalAudioURL,
                    outputURL: converted,
                    sampleRate: Double(recipe.output.audioSampleRate ?? 48_000),
                    channels: recipe.output.audioChannels ?? 2,
                    bitrate: recipe.output.audioBitrateBps ?? 192_000,
                    overwrite: true
                )
                finalStaged = converted
            } else {
                throw SafariumError.invalidState("unsupported audio encode container '\(container)' (Apple stack supports .wav / .m4a)")
            }
            try stage.commit(stagedFile: finalStaged, overwrite: overwrite)
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
            return ForgeExecutionReport(
                schema: recipe.schema ?? "safarium-forge/graph-v1",
                outputPath: outURL.path,
                secondaryOutputPath: nil,
                container: container,
                width: recipe.timeline.width,
                height: recipe.timeline.height,
                fps: recipe.timeline.fps,
                framesRendered: 0,
                htmlFramesCaptured: 0,
                htmlFramesReusedDirtyHold: 0,
                wkWebViewRecycles: 0,
                thermalCooldownEvents: 0,
                audioDurationSeconds: audioResult.durationSeconds,
                qaReport: nil,
                primaryBytes: bytes,
                secondaryBytes: nil,
                wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            )
        }

        // 3. Prepare Video / Image / ImageSequence / LUT / HTML Inputs
        let filterEngine = try ForgeMetalFilterEngine()
        var videoReaders: [String: (reader: SafariumSequentialVideoReader, trimStart: Double, trimEnd: Double?)] = [:]
        var imageInputs: [String: (pb: CVPixelBuffer, tex: MTLTexture)] = [:]
        var sequenceInputs: [String: (frames: [URL], fps: Int, loop: Bool)] = [:]
        var sequenceLastCache: [String: (idx: Int, pb: CVPixelBuffer)] = [:]
        var lutInputs: [String: (lut: ForgeCubeLUT, tex: MTLTexture)] = [:]
        var htmlManagers: [String: ForgeHTMLOverlaySource] = [:]
        var rawPipeInputs: [String: ForgeInputSpec] = [:]

        defer {
            for (_, v) in videoReaders { v.reader.close() }
        }

        let recycleEvery = recipe.job?.governor?.wkRecycleEveryFrames ?? 200
        for inp in recipe.inputs {
            switch inp.kind {
            case .video:
                guard let u = resolvedPaths[inp.id] else { continue }
                let trimS = mpeg2PreTrimmedInputs.contains(inp.id) ? 0.0 : (inp.trim?.first ?? 0.0)
                let trimE: Double? = mpeg2PreTrimmedInputs.contains(inp.id)
                    ? nil
                    : ((inp.trim?.count ?? 0) >= 2 ? inp.trim![1] : nil)
                let reader = try await SafariumSequentialVideoReader(
                    url: u, loop: inp.loop ?? false, startTimeOffset: trimS, pixelFormat: kCVPixelFormatType_32BGRA
                )
                videoReaders[inp.id] = (reader, trimS, trimE)
            case .image:
                guard let u = resolvedPaths[inp.id],
                      let src = CGImageSourceCreateWithURL(u as CFURL, nil),
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                    throw SafariumError.snapshot("failed to decode image input '\(inp.id)'")
                }
                let pb = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: cg.width, height: cg.height, pixelFormat: .bgra)
                try Snapshot(cgImage: cg).draw(into: pb, width: cg.width, height: cg.height)
                let tex = try filterEngine.uploadCGImageToTexture(cg)
                filterEngine.textureLRU.insert(inp.id, texture: tex)
                imageInputs[inp.id] = (pb, tex)
            case .imageSequence:
                let dirURL: URL? = (inp.sequenceDirectory ?? inp.path).map { URL(fileURLWithPath: $0, isDirectory: true) }
                let listURL = inp.sequenceListFile.map { URL(fileURLWithPath: $0) }
                let frames = try ForgeSequenceIngest.discoverSequenceFrames(
                    directoryURL: inp.sequenceGlob == nil ? dirURL : nil,
                    globPattern: inp.sequenceGlob,
                    listFileURL: listURL
                )
                let sfps = inp.sequenceFps ?? inp.fps ?? recipe.timeline.fps
                sequenceInputs[inp.id] = (frames, max(1, sfps), inp.loop ?? false)
            case .lut3d:
                guard let u = resolvedPaths[inp.id] else { continue }
                let lut = try ForgeCubeLUT.parse(url: u)
                let tex = try lut.makeMTLTexture3D(device: filterEngine.device)
                lutInputs[inp.id] = (lut, tex)
            case .htmlOverlay:
                guard let u = resolvedPaths[inp.id] else { continue }
                let hw = inp.width ?? recipe.timeline.width
                let hh = inp.height ?? recipe.timeline.height
                let mgr = try await MainActor.run {
                    try ForgeHTMLOverlaySource(
                        inputID: inp.id,
                        htmlURL: u,
                        width: hw,
                        height: hh,
                        modeCDirtyHold: inp.modeCDirtyHold ?? true,
                        recycleEveryFrames: recycleEvery,
                        stagingRoot: stage.stagingDirectory
                    )
                }
                try await mgr.prepare()
                htmlManagers[inp.id] = mgr
            case .rawPipe:
                rawPipeInputs[inp.id] = inp
            case .audio, .synthAudio, .subtitles:
                break
            }
        }

        // Ensure HTML managers are cleaned up cleanly on exit/error
        let frozenHTMLManagers = Array(htmlManagers.values)
        let cleanupHTML: @MainActor () -> Void = {
            for mgr in frozenHTMLManagers { mgr.close() }
        }

        do {
            // Determine total frame count (supporting sequence durations, ptsFactor & tpad tail hold)
            let fps = recipe.timeline.fps
            let firstVideoDur = videoReaders.values.first.map { v -> Double in
                if let te = v.trimEnd { return max(0.05, te - v.trimStart) }
                return max(0.05, v.reader.durationSeconds - v.trimStart)
            }
            let firstSeqDur = sequenceInputs.values.first.map { s -> Double in
                Double(s.frames.count) / Double(max(1, s.fps))
            }
            var effectivePTSFactor = 1.0
            var effectiveHoldTail = 0.0
            for op in plan.orderedVideoOps {
                if let f = op.ptsFactor, f > 0 { effectivePTSFactor *= f }
                if let h = op.holdTailSeconds, h > 0 { effectiveHoldTail += h }
            }
            let baseResolvedDur = recipe.timeline.durationSeconds ?? firstVideoDur ?? firstSeqDur ?? audioResult.durationSeconds ?? 1.0
            let scaledBaseDur = baseResolvedDur * effectivePTSFactor
            let baseFrames = recipe.timeline.frameCount ?? max(1, Int((scaledBaseDur * Double(fps)).rounded()))
            let holdTailFrames = effectiveHoldTail > 0 ? Int(ceil(effectiveHoldTail * Double(fps))) : 0
            let totalFrames = baseFrames + holdTailFrames
            let resolvedDur = Double(totalFrames) / Double(fps)
            let outW = recipe.timeline.width
            let outH = recipe.timeline.height

            let isStillImageContainer = ["webp", "avif", "heic", "heics", "png", "jpg", "jpeg"].contains(container)
            if isStillImageContainer {
                try enforceAnimatedImageBudget(frameCount: totalFrames, width: outW, height: outH)
            }

            let primaryCodec = plan.resolvedPrimaryCodec
            let rateBitrate = recipe.output.rateControl?.bitrateBps ?? recipe.output.bitrate ?? 8_000_000
            let rateQuality = recipe.output.rateControl?.cqf ?? recipe.output.quality
            let profile: EncoderProfile = (recipe.output.closedGOP ?? true) ? .lowRamClosedGOP : .baseline

            let stagedVideoOnly = stage.fileURL("video_primary.\(primaryCodec.fileExtension)")
            let inlineSheetURL = recipe.output.inlineSheetPath.map { URL(fileURLWithPath: $0) }
            var sceneCacheKey: String?
            var sceneCacheSpec: ForgeSceneSpec?
            var sceneCacheRoot: URL?
            var sceneCacheHit = false

            if recipe.timeline.closedGOPSceneCache == true && !isStillImageContainer && rawPipeProvider == nil {
                let opsEnc = JSONEncoder()
                opsEnc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                let opsPayload = (try? opsEnc.encode(plan.orderedVideoOps)) ?? Data()
                let opsHash = SHA256.hash(data: opsPayload).map { String(format: "%02x", $0) }.joined()
                let inputHashes = recipe.inputs.compactMap { inp -> URL? in
                    (audioSourceURLs[inp.id] ?? resolvedPaths[inp.id]).flatMap {
                        var isDir: ObjCBool = false
                        return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir) && !isDir.boolValue ? $0 : nil
                    }
                }
                let spec = ForgeSceneSpec(
                    sceneId: recipe.inputs.map(\.id).joined(separator: "+"),
                    inputs: recipe.inputs.map { "\($0.id):\($0.kind.rawValue):\($0.path ?? $0.sequenceDirectory ?? ""):\($0.trim?.map { String($0) }.joined(separator: "-") ?? "")" },
                    opsHash: "\(opsHash):ptsf=\(effectivePTSFactor):hold=\(effectiveHoldTail):br=\(rateBitrate):q=\(rateQuality ?? -1)",
                    durationSeconds: resolvedDur,
                    fps: fps,
                    width: outW,
                    height: outH,
                    codec: primaryCodec.rawValue
                )
                let root = try ForgeIncrementalCache.resolveCacheRoot(
                    recipe.job?.stagePolicy?.cacheDir.map { URL(fileURLWithPath: $0, isDirectory: true) },
                    fallbackToInternalAPFS: true
                )
                let key = try ForgeIncrementalCache.cacheKey(for: spec, hashingInputFiles: inputHashes)
                sceneCacheKey = key
                sceneCacheSpec = spec
                sceneCacheRoot = root
                let canUseHit = (secOutURL == nil) && inlineSheetURL == nil && (recipe.qaOps?.monochromeCheck != true)
                if canUseHit,
                   let hit = try? ForgeIncrementalCache.lookupScene(
                       key: key,
                       destinationURL: stagedVideoOnly,
                       cacheRoot: root,
                       overwrite: true,
                       rejectCorrupt: false
                   ),
                   hit.hit {
                    sceneCacheHit = true
                }
            }

            var stillCapturedFrames: [CGImage] = []
            var thermalCooldowns = 0
            var htmlCaptured = 0
            var htmlReused = 0
            var htmlRecycles = 0
            var inlineSheetResultPath: String?
            var observedMaxChroma = 0.0
            var monochromeChecked = false
            var secondaryPendingCommit: (url: URL, stage: APFSStageSession, videoURL: URL, codec: VideoCodec)?

            if !sceneCacheHit {
                let primarySink: AVAssetWriterSink? = isStillImageContainer ? nil : try AVAssetWriterSink(
                    url: stagedVideoOnly,
                    width: outW,
                    height: outH,
                    fps: fps,
                    codec: primaryCodec,
                    bitrate: rateBitrate,
                    quality: rateQuality,
                    pixelFormat: plan.resolvedPixelFormat,
                    profile: profile
                )

                let stagedSecOnly: URL?
                let secondarySink: AVAssetWriterSink?
                if !isStillImageContainer, let secCodec = plan.resolvedSecondaryCodec, secOutURL != nil {
                    let su = stage.fileURL("video_secondary.\(secCodec.fileExtension)")
                    stagedSecOnly = su
                    secondarySink = try AVAssetWriterSink(
                        url: su,
                        width: outW,
                        height: outH,
                        fps: fps,
                        codec: secCodec,
                        bitrate: rateBitrate,
                        quality: rateQuality,
                        pixelFormat: secCodec.hasAlpha ? .bgra : .nv12Left,
                        profile: profile
                    )
                } else {
                    stagedSecOnly = nil
                    secondarySink = nil
                }

                let inlineCollector: ForgeInlineSheetCollector? = try inlineSheetURL.map { _ in
                    try ForgeInlineSheetCollector(
                        totalFrames: totalFrames,
                        fps: fps,
                        config: ForgeContactSheetConfig(
                            cols: recipe.output.inlineSheetCols ?? 6,
                            rows: recipe.output.inlineSheetRows ?? 4,
                            tileWidth: recipe.output.inlineSheetTileWidth ?? 320
                        )
                    )
                }

                // Compile math expressions & stateful per-op processors upfront
                let ring = ForgeIOSurfaceRing(capacity: plan.ringSlots)
                var reframeTrackers: [String: ForgeReframeTracker] = [:]
                var matteProcessors: [String: ForgePersonMatteProcessor] = [:]
                var deinterlaceHistory: [String: DeinterlaceHistoryRing] = [:]
                var tmixHistory: [String: [CVPixelBuffer]] = [:]
                var kgriefHistory: [String: CVPixelBuffer] = [:]
                var llsrScalers: [String: ForgeLLSRUpscaler] = [:]
                var compiledExprs: [String: (x: ForgeExprNode?, y: ForgeExprNode?, scale: ForgeExprNode?, opacity: ForgeExprNode?, enable: ForgeExprNode?, zoom: ForgeExprNode?, cx: ForgeExprNode?, cy: ForgeExprNode?)] = [:]

                for op in plan.orderedVideoOps {
                    switch op.op {
                    case .autoReframe:
                        reframeTrackers[op.id] = ForgeReframeTracker(
                            detector: ForgeReframeDetector.parse(op.detector),
                            emaAlpha: op.emaAlpha ?? 0.14,
                            hysteresis: op.hysteresis ?? 0.02,
                            sceneCutThreshold: op.sceneCutThreshold ?? 0.20,
                            resetOnSceneCut: op.resetOnSceneCut ?? true
                        )
                    case .personMatte:
                        matteProcessors[op.id] = ForgePersonMatteProcessor(
                            mode: ForgeMatteMode.parse(op.mode),
                            temporalEMA: op.temporalEMA ?? 0.35,
                            filterEngine: filterEngine
                        )
                    case .llsr:
                        llsrScalers[op.id] = try ForgeLLSRUpscaler(engine: filterEngine)
                    default:
                        break
                    }
                    compiledExprs[op.id] = (
                        x: try op.x.map(ForgeTimeExprParser.compile),
                        y: try op.y.map(ForgeTimeExprParser.compile),
                        scale: try op.scale.map(ForgeTimeExprParser.compile),
                        opacity: try op.opacity.map(ForgeTimeExprParser.compile),
                        enable: try op.enable.map(ForgeTimeExprParser.compile),
                        zoom: try op.zoomExpr.map(ForgeTimeExprParser.compile),
                        cx: try op.centerXExpr.map(ForgeTimeExprParser.compile),
                        cy: try op.centerYExpr.map(ForgeTimeExprParser.compile)
                    )
                }

                let ciCtx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])
                var secBgPlatePB: CVPixelBuffer?
                if secondarySink != nil {
                    let p = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: outW, height: outH, pixelFormat: .bgra)
                    try filterEngine.fillSolid(colorRGBA: ForgeColorHex.parseRGBA(recipe.output.secondaryBackgroundHex ?? "#000000"), into: p)
                    secBgPlatePB = p
                }

                let checkMonochrome = (recipe.qaOps?.monochromeCheck == true)
                let monoStep = max(1, totalFrames / 30)

                // 4. Single Bounded Execution Loop
                progressEmitter?.emitStart(stage: "video_graph", total: totalFrames)
                var prevPTS = CMTime.invalid
                for frameIdx in 0..<totalFrames {
                    let thermal = ProcessInfo.processInfo.thermalState
                    if thermal == .serious {
                        thermalCooldowns += 1
                        try await Task.sleep(nanoseconds: 10_000_000)
                    } else if thermal == .critical {
                        thermalCooldowns += 1
                        try await Task.sleep(nanoseconds: 35_000_000)
                    }

                    let clampedSrcIdx = min(frameIdx, max(0, baseFrames - 1))
                    let t = Double(frameIdx) / Double(fps)
                    let sourceT = (Double(clampedSrcIdx) / Double(fps)) / max(1e-6, effectivePTSFactor)

                    var htmlFrameMap: [String: (pb: CVPixelBuffer, tex: MTLTexture)] = [:]
                    for (id, mgr) in htmlManagers {
                        htmlFrameMap[id] = try await mgr.captureFrame(at: sourceT, frameIndex: clampedSrcIdx, engine: filterEngine)
                    }

                    var nodeBuffers: [String: CVPixelBuffer] = [:]
                    try autoreleasepool {
                        // Populate video/image/sequence/html/rawPipe inputs for this frame
                        for (id, vr) in videoReaders {
                            let localT = vr.trimEnd.map { min($0 - vr.trimStart, sourceT) } ?? sourceT
                            guard let rawPB = try vr.reader.pixelBuffer(at: localT) else {
                                throw SafariumError.snapshot("missing frame \(frameIdx) from video input '\(id)'")
                            }
                            if vr.reader.preferredTransform.isIdentity {
                                nodeBuffers[id] = rawPB
                            } else {
                                let upright = try ring.acquire(width: vr.reader.width, height: vr.reader.height, excluding: Array(nodeBuffers.values))
                                let ci = vr.reader.orientedCIImage(from: rawPB)
                                ciCtx.render(ci, to: upright, bounds: CGRect(x: 0, y: 0, width: vr.reader.width, height: vr.reader.height), colorSpace: Snapshot.colorSpace)
                                nodeBuffers[id] = upright
                            }
                        }
                        for (id, imgPair) in imageInputs {
                            nodeBuffers[id] = imgPair.pb
                        }
                        for (id, seq) in sequenceInputs {
                            let seqIdxRaw = Int((sourceT * Double(seq.fps)).rounded(.down))
                            let seqIdx = seq.loop ? (seqIdxRaw % max(1, seq.frames.count)) : min(max(0, seqIdxRaw), seq.frames.count - 1)
                            if let cached = sequenceLastCache[id], cached.idx == seqIdx {
                                nodeBuffers[id] = cached.pb
                            } else {
                                let imgURL = seq.frames[seqIdx]
                                guard let src = CGImageSourceCreateWithURL(imgURL as CFURL, nil),
                                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                                    throw SafariumError.snapshot("failed to decode sequence frame '\(imgURL.lastPathComponent)' for '\(id)'")
                                }
                                let pb = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: cg.width, height: cg.height, pixelFormat: .bgra)
                                try Snapshot(cgImage: cg).draw(into: pb, width: cg.width, height: cg.height)
                                sequenceLastCache[id] = (seqIdx, pb)
                                nodeBuffers[id] = pb
                            }
                        }
                        for (id, htmlPair) in htmlFrameMap {
                            nodeBuffers[id] = htmlPair.pb
                        }
                        for (id, spec) in rawPipeInputs {
                            let rw = spec.width ?? outW
                            let rh = spec.height ?? outH
                            let fmt = try ForgeRawPixelFormat.parse(spec.pixelFormat ?? "bgra")
                            guard let provider = rawPipeProvider,
                                  let data = try provider(id, clampedSrcIdx, rw * rh * fmt.bytesPerPixel) else {
                                throw SafariumError.invalidState("rawPipe input '\(id)' yielded no frame \(frameIdx)")
                            }
                            let pb = try ring.acquire(width: rw, height: rh, excluding: Array(nodeBuffers.values))
                            try writeRawData(data, format: fmt, width: rw, height: rh, intoBGRA: pb)
                            nodeBuffers[id] = pb
                        }

                        // Evaluate video DAG nodes in topological order
                        for op in plan.orderedVideoOps {
                            let outPB = try evaluateVideoOp(
                                op: op,
                                frameIdx: frameIdx,
                                t: t,
                                fps: fps,
                                duration: resolvedDur,
                                outWidth: outW,
                                outHeight: outH,
                                nodeBuffers: nodeBuffers,
                                htmlTextures: htmlFrameMap.mapValues(\.tex),
                                imageTextures: imageInputs.mapValues(\.tex),
                                lutInputs: lutInputs,
                                compiledExpr: compiledExprs[op.id]!,
                                reframeTrackers: reframeTrackers,
                                matteProcessors: matteProcessors,
                                deinterlaceHistory: &deinterlaceHistory,
                                tmixHistory: &tmixHistory,
                                kgriefHistory: &kgriefHistory,
                                llsrScalers: llsrScalers,
                                filterEngine: filterEngine,
                                ring: ring
                            )
                            nodeBuffers[op.id] = outPB
                        }

                        guard let finalID = plan.finalVideoNodeID, let finalBGRA = nodeBuffers[finalID] else {
                            throw SafariumError.invalidState("video graph yielded no final pixel buffer")
                        }

                        if let collector = inlineCollector {
                            try collector.ingest(frameIndex: frameIdx, pixelBuffer: finalBGRA)
                        }
                        if checkMonochrome && (frameIdx % monoStep == 0 || frameIdx == totalFrames - 1) {
                            monochromeChecked = true
                            observedMaxChroma = max(observedMaxChroma, try measureMaxChromaDelta(finalBGRA))
                        }

                        if isStillImageContainer {
                            let ci = CIImage(cvPixelBuffer: finalBGRA)
                            guard let cg = ciCtx.createCGImage(ci, from: CGRect(x: 0, y: 0, width: outW, height: outH), format: .BGRA8, colorSpace: Snapshot.colorSpace) else {
                                throw SafariumError.snapshot("failed rendering still/animated image frame \(frameIdx)")
                            }
                            stillCapturedFrames.append(cg)
                        }
                    }

                    // Append outside autoreleasepool because AVAssetWriterSink.append is async
                    let outPTS = CMTime(value: Int64(frameIdx), timescale: Int32(fps))
                    if prevPTS.isValid && CMTimeCompare(outPTS, prevPTS) <= 0 {
                        throw SafariumError.encode("non-monotonic output frame PTS at index \(frameIdx)")
                    }
                    prevPTS = outPTS

                    if !isStillImageContainer, let finalID = plan.finalVideoNodeID, let finalBGRA = nodeBuffers[finalID] {
                        if let pSink = primarySink {
                            try await pSink.append(presentationTime: outPTS) { dstPB in
                                try copyOrConvertBGRA(finalBGRA, into: dstPB, pixelFormat: plan.resolvedPixelFormat, width: outW, height: outH, filterEngine: filterEngine)
                            }
                        }
                        if let sSink = secondarySink, let secCodec = plan.resolvedSecondaryCodec, let bgPlate = secBgPlatePB {
                            let secCompPB = try ring.acquire(width: outW, height: outH, excluding: [finalBGRA, bgPlate])
                            if secCodec.hasAlpha {
                                try filterEngine.applyGeom(srcPB: finalBGRA, into: secCompPB)
                            } else {
                                try filterEngine.applyOverlay(basePB: bgPlate, overPB: finalBGRA, into: secCompPB)
                            }
                            try await sSink.append(presentationTime: outPTS) { dstPB in
                                try copyOrConvertBGRA(secCompPB, into: dstPB, pixelFormat: secCodec.hasAlpha ? .bgra : .nv12Left, width: outW, height: outH, filterEngine: filterEngine)
                            }
                        }
                    }

                    if frameIdx > 0 && frameIdx % 60 == 0 {
                        primarySink?.flushPool()
                        secondarySink?.flushPool()
                        filterEngine.flushCaches()
                    }
                    progressEmitter?.emitFrame(stage: "video_graph", completed: frameIdx + 1, total: totalFrames)
                }
                progressEmitter?.emitComplete(stage: "video_graph", total: totalFrames)

                if let collector = inlineCollector, let sheetURL = inlineSheetURL {
                    let rep = try collector.finalize(to: sheetURL, overwrite: overwrite)
                    inlineSheetResultPath = rep.outputPath
                }

                (htmlCaptured, htmlReused, htmlRecycles) = await MainActor.run {
                    let c = frozenHTMLManagers.reduce(0) { $0 + $1.framesCaptured }
                    let r = frozenHTMLManagers.reduce(0) { $0 + $1.framesReusedDirtyHold }
                    let k = frozenHTMLManagers.reduce(0) { $0 + $1.recycleCount }
                    cleanupHTML()
                    return (c, r, k)
                }

                // 5. Handle Still / Animated Image Output (.webp / .heics / .avif / .heic / .png / .jpg)
                if isStillImageContainer {
                    guard !stillCapturedFrames.isEmpty else {
                        throw SafariumError.invalidState("no frames captured for \(container) output")
                    }
                    let stagedImg = stage.fileURL("out.\(container)")
                    let delayMs = max(10, Int((1000.0 / Double(fps)).rounded()))
                    if container == "webp" {
                        let delays = Array(repeating: delayMs, count: stillCapturedFrames.count)
                        _ = try WebPAVIFEncoder.writeLosslessWebP(images: stillCapturedFrames, to: stagedImg, loopCount: 0, overwrite: true, frameDurationsMs: delays)
                    } else if container == "heics" {
                        let delays = Array(repeating: delayMs, count: stillCapturedFrames.count)
                        _ = try WebPAVIFEncoder.writeHEICSSequence(images: stillCapturedFrames, quality: recipe.output.quality ?? 0.85, loopCount: 0, to: stagedImg, overwrite: true, frameDurationsMs: delays)
                    } else {
                        let fmt = ContainerFormat(rawValue: container) ?? .png
                        _ = try WebPAVIFEncoder.writeStillImage(cgImage: stillCapturedFrames[0], format: fmt, quality: recipe.output.quality, to: stagedImg, overwrite: true)
                    }
                    try stage.commit(stagedFile: stagedImg, overwrite: overwrite)
                    safariumMemFlush()
                    let bytes = ((try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
                    return ForgeExecutionReport(
                        schema: recipe.schema ?? "safarium-forge/graph-v1",
                        outputPath: outURL.path,
                        secondaryOutputPath: nil,
                        container: container,
                        width: outW,
                        height: outH,
                        fps: fps,
                        framesRendered: stillCapturedFrames.count,
                        htmlFramesCaptured: htmlCaptured,
                        htmlFramesReusedDirtyHold: htmlReused,
                        wkWebViewRecycles: htmlRecycles,
                        thermalCooldownEvents: thermalCooldowns,
                        audioDurationSeconds: nil,
                        qaReport: nil,
                        primaryBytes: bytes,
                        secondaryBytes: nil,
                        wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6,
                        inlineSheetPath: inlineSheetResultPath
                    )
                }

                // 6. Finish Video Sink(s)
                try await primarySink?.finish()
                try await secondarySink?.finish()

                if let key = sceneCacheKey, let spec = sceneCacheSpec, let root = sceneCacheRoot {
                    _ = try? ForgeIncrementalCache.storeScene(key: key, segmentURL: stagedVideoOnly, spec: spec, cacheRoot: root)
                }

                let secURLCommit = secOutURL
                let secSCommit = secStage
                let stagedSecCommit = stagedSecOnly
                let priCodec = primaryCodec
                if checkMonochrome {
                    let threshold = recipe.qaOps?.maxChromaDelta ?? 0.02
                    if (recipe.qaOps?.failOnQA ?? true) && observedMaxChroma > threshold {
                        throw SafariumError.invalidState("monochromeCheck failed: observed chroma delta \(String(format: "%.4f", observedMaxChroma)) > max \(threshold)")
                    }
                }
                _ = (secURLCommit, secSCommit, stagedSecCommit, priCodec)
                // Rebind stagedSecOnly via outer tuple below for unified step 6b/7
                if let sURL = secOutURL, let sStage = secStage, let sVid = stagedSecOnly, let sCodec = plan.resolvedSecondaryCodec {
                    secondaryPendingCommit = (sURL, sStage, sVid, sCodec)
                }
            } else {
                await MainActor.run { cleanupHTML() }
            }

            let subInfo = resolveSubtitleInput(recipe: recipe, resolvedPaths: resolvedPaths)
            let stagedAssembledPrimary = try await assembleFinalVideoContainer(
                videoOnlyURL: stagedVideoOnly,
                audioURL: audioResult.finalURL,
                subtitleURL: subInfo?.url,
                subtitleFormat: subInfo?.format ?? "tx3g",
                subtitleLang: subInfo?.lang ?? "tha",
                container: container,
                primaryCodec: primaryCodec,
                primaryAudioCodec: recipe.output.primaryAudioCodec,
                fragmentIntervalSeconds: recipe.output.fragmentIntervalSeconds,
                width: outW,
                height: outH,
                stage: stage,
                prefix: "primary"
            )

            // 7. Inline QA / SafariumPQ Verification before committing!
            var finalQA: ForgeQAReport?
            let monoAllowedDelta = recipe.qaOps?.maxChromaDelta ?? 0.02
            let monoOK: Bool? = monochromeChecked ? (observedMaxChroma <= monoAllowedDelta) : nil
            if let qaSpec = recipe.qaOps, (container == "mp4" || container == "mov" || container == "fmp4") {
                let hasExtraQA = qaSpec.referenceVideoPath != nil
                    || qaSpec.contactSheetPath != nil
                    || (qaSpec.thaiOCRLangs?.isEmpty == false)
                    || qaSpec.expectedThaiText != nil
                    || (qaSpec.faultChecks?.isEmpty == false)
                if hasExtraQA {
                    let sheetURL = qaSpec.contactSheetPath.map { URL(fileURLWithPath: $0) }
                    let sheetCfg = (qaSpec.contactSheetCols != nil || qaSpec.contactSheetRows != nil)
                        ? ForgeContactSheetConfig(cols: qaSpec.contactSheetCols ?? 6, rows: qaSpec.contactSheetRows ?? 4)
                        : nil
                    let refURL = qaSpec.referenceVideoPath.map { URL(fileURLWithPath: $0) }
                    let qaRep = try await ForgeSheetAndQA.runQA(
                        inputURL: stagedAssembledPrimary,
                        referenceURL: refURL,
                        contactSheetURL: sheetURL,
                        sheetConfig: sheetCfg,
                        checkThaiOCR: (qaSpec.thaiOCRLangs?.isEmpty == false) || (qaSpec.expectedThaiText != nil),
                        minPQScore: qaSpec.safariumPQMin ?? 85.0,
                        maxDeltaE00P95: qaSpec.maxDeltaE00P95 ?? 2.0,
                        overwrite: overwrite
                    )
                    finalQA = qaRep
                    if (qaSpec.failOnQA ?? true) && !qaRep.passed {
                        throw SafariumError.invalidState("ForgeGraph QA failed: \(qaRep.failureReasons.joined(separator: "; "))")
                    }
                }
            }

            try stage.commit(stagedFile: stagedAssembledPrimary, overwrite: overwrite)

            var secBytes: Int64?
            if let sec = secondaryPendingCommit {
                let secExt = sec.url.pathExtension.lowercased()
                let assembledSec = try await assembleFinalVideoContainer(
                    videoOnlyURL: sec.videoURL,
                    audioURL: audioResult.finalURL,
                    subtitleURL: subInfo?.url,
                    subtitleFormat: subInfo?.format ?? "tx3g",
                    subtitleLang: subInfo?.lang ?? "tha",
                    container: secExt.isEmpty ? sec.codec.fileExtension : secExt,
                    primaryCodec: sec.codec,
                    primaryAudioCodec: nil,
                    fragmentIntervalSeconds: nil,
                    width: outW,
                    height: outH,
                    stage: stage,
                    prefix: "secondary"
                )
                try sec.stage.commit(stagedFile: assembledSec, to: sec.url, overwrite: overwrite)
                secBytes = ((try? FileManager.default.attributesOfItem(atPath: sec.url.path)[.size]) as? NSNumber)?.int64Value
            }

            safariumMemFlush()
            let priBytes = ((try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
            return ForgeExecutionReport(
                schema: recipe.schema ?? "safarium-forge/graph-v1",
                outputPath: outURL.path,
                secondaryOutputPath: secOutURL?.path,
                container: container,
                width: outW,
                height: outH,
                fps: fps,
                framesRendered: sceneCacheHit ? 0 : totalFrames,
                htmlFramesCaptured: htmlCaptured,
                htmlFramesReusedDirtyHold: htmlReused,
                wkWebViewRecycles: htmlRecycles,
                thermalCooldownEvents: thermalCooldowns,
                audioDurationSeconds: audioResult.durationSeconds,
                qaReport: finalQA,
                primaryBytes: priBytes,
                secondaryBytes: secBytes,
                wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6,
                monochromeOK: monoOK,
                maxChromaDelta: monochromeChecked ? observedMaxChroma : nil,
                sceneCacheHit: recipe.timeline.closedGOPSceneCache == true ? sceneCacheHit : nil,
                inlineSheetPath: inlineSheetResultPath
            )
        } catch {
            await MainActor.run { cleanupHTML() }
            throw error
        }
    }

    // MARK: - Helpers

    private static func resolveSubtitleInput(recipe: ForgeRecipe, resolvedPaths: [String: URL]) -> (url: URL, format: String, lang: String)? {
        guard let sub = recipe.output.subtitles else { return nil }
        let url: URL?
        if let inpID = sub.input, let u = resolvedPaths[inpID] {
            url = u
        } else if let p = sub.path {
            url = URL(fileURLWithPath: p)
        } else {
            url = nil
        }
        guard let finalURL = url else { return nil }
        let lang = sub.lang ?? recipe.inputs.first(where: { $0.id == sub.input })?.lang ?? "tha"
        return (finalURL, (sub.format ?? "tx3g").lowercased(), lang)
    }

    private static func assembleFinalVideoContainer(
        videoOnlyURL: URL,
        audioURL: URL?,
        subtitleURL: URL?,
        subtitleFormat: String,
        subtitleLang: String,
        container: String,
        primaryCodec: VideoCodec,
        primaryAudioCodec: String?,
        fragmentIntervalSeconds: Double?,
        width: Int,
        height: Int,
        stage: APFSStageSession,
        prefix: String
    ) async throws -> URL {
        // Build MP4/MOV intermediate with audio + tx3g if needed
        let baseExt = (primaryCodec == .proRes422 || primaryCodec == .proRes4444 || container == "mov") ? "mov" : "mp4"
        var mp4OrMov = videoOnlyURL

        if let fragSec = fragmentIntervalSeconds, fragSec > 0, (container == "mp4" || container == "fmp4") {
            let fragURL = stage.fileURL("\(prefix)_fmp4.mp4")
            try await writeFileBasedFMP4(
                videoURL: videoOnlyURL,
                audioURL: audioURL,
                subtitleURL: subtitleFormat == "tx3g" ? subtitleURL : nil,
                subtitleLang: subtitleLang,
                fragmentIntervalSeconds: fragSec,
                width: width,
                height: height,
                outputURL: fragURL
            )
            mp4OrMov = fragURL
        } else if let audioURL, let pAC = primaryAudioCodec?.lowercased(), pAC == "pcm_s16le" || pAC == "copy" {
            let muxURL = stage.fileURL("\(prefix)_mux.\(baseExt)")
            try await ForgeSheetAndQA.muxPrimaryAudioLossless(
                videoURL: videoOnlyURL,
                audioURL: audioURL,
                audioCodec: pAC,
                subtitlesURL: (subtitleFormat == "tx3g") ? subtitleURL : nil,
                subtitleLang: subtitleLang,
                outputURL: muxURL
            )
            mp4OrMov = muxURL
        } else if audioURL != nil || (subtitleURL != nil && subtitleFormat == "tx3g" && (container == "mp4" || container == "mov")) {
            let muxURL = stage.fileURL("\(prefix)_mux.\(baseExt)")
            _ = try await LosslessSoundtrackMux.mux(
                videoURL: videoOnlyURL,
                wavURL: audioURL,
                subtitlesURL: (subtitleFormat == "tx3g") ? subtitleURL : nil,
                subtitleLang: subtitleLang,
                outputURL: muxURL,
                overwrite: true
            )
            mp4OrMov = muxURL
        }

        switch container {
        case "mkv", "webm":
            var cues: [SafariumSRTCue] = []
            if let subURL = subtitleURL {
                let asset = AVURLAsset(url: mp4OrMov)
                let dur = try await asset.load(.duration)
                cues = (try? SafariumTX3G.parseSRT(url: subURL, offsetSeconds: 0, duration: dur)) ?? []
            }
            let mkvURL = stage.fileURL("\(prefix).\(container)")
            _ = try await EBMLMatroskaCodec.muxFromMP4OrMOV(
                inputURL: mp4OrMov,
                outputURL: mkvURL,
                docType: container == "webm" ? "webm" : "matroska",
                subtitleCues: cues,
                overwrite: true
            )
            return mkvURL
        case "ts":
            let tsURL = stage.fileURL("\(prefix).ts")
            _ = try await MPEGTSCodec.muxFromMP4OrMOV(inputURL: mp4OrMov, outputURL: tsURL, overwrite: true)
            return tsURL
        default:
            return mp4OrMov
        }
    }

    private static func writeFileBasedFMP4(
        videoURL: URL,
        audioURL: URL?,
        subtitleURL: URL?,
        subtitleLang: String,
        fragmentIntervalSeconds: Double,
        width: Int,
        height: Int,
        outputURL: URL
    ) async throws {
        // First ensure audio (if provided) is AAC inside an intermediate mp4 via LosslessSoundtrackMux,
        // then passthrough packets into AVAssetWriter(fileType: .mp4) with movieFragmentInterval + tx3g!
        var muxedSource = videoURL
        var tempMux: URL?
        if let audioURL {
            let tmp = outputURL.deletingLastPathComponent().appendingPathComponent("fmp4_pre_\(UUID().uuidString).mp4")
            _ = try await LosslessSoundtrackMux.mux(videoURL: videoURL, wavURL: audioURL, outputURL: tmp, overwrite: true)
            muxedSource = tmp
            tempMux = tmp
        }
        defer { if let tempMux { try? FileManager.default.removeItem(at: tempMux) } }

        let asset = AVURLAsset(url: muxedSource, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw SafariumError.encode("file-based fMP4 source contains no video track")
        }
        let aTrack = try await asset.loadTracks(withMediaType: .audio).first
        let dur = try await asset.load(.duration)
        guard let vFmt = try await vTrack.load(.formatDescriptions).first else {
            throw SafariumError.encode("file-based fMP4 source video track has no format description")
        }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: fragmentIntervalSeconds, preferredTimescale: 600)
        writer.shouldOptimizeForNetworkUse = false

        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vFmt)
        vi.expectsMediaDataInRealTime = false
        writer.add(vi)

        var ai: AVAssetWriterInput?
        if let aTrack, let aFmt = try await aTrack.load(.formatDescriptions).first {
            let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: aFmt)
            inp.expectsMediaDataInRealTime = false
            if writer.canAdd(inp) { writer.add(inp); ai = inp }
        }

        var si: AVAssetWriterInput?
        var subSamples: [CMSampleBuffer] = []
        if let subtitleURL {
            let cues = try SafariumTX3G.parseSRT(url: subtitleURL, offsetSeconds: 0, duration: dur)
            let (sFmt, sSamples) = try SafariumTX3G.buildContiguousSamples(cues: cues, duration: dur, width: width, height: height)
            let sInp = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: sFmt)
            sInp.languageCode = subtitleLang
            sInp.expectsMediaDataInRealTime = false
            if writer.canAdd(sInp) {
                writer.add(sInp)
                si = sInp
                subSamples = sSamples
            }
        }

        let reader = try AVAssetReader(asset: asset)
        let vo = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        vo.alwaysCopiesSampleData = false
        reader.add(vo)
        var ao: AVAssetReaderTrackOutput?
        if let aTrack, ai != nil {
            let out = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            reader.add(out)
            ao = out
        }

        guard reader.startReading(), writer.startWriting() else {
            throw SafariumError.encode("fMP4 reader/writer failed to start")
        }
        writer.startSession(atSourceTime: .zero)

        func nextValidSample(from out: AVAssetReaderTrackOutput) -> CMSampleBuffer? {
            while let s = out.copyNextSampleBuffer() {
                if s.numSamples > 0 { return s }
            }
            return nil
        }

        func safePTSSeconds(_ sb: CMSampleBuffer) -> Double {
            let t = CMSampleBufferGetPresentationTimeStamp(sb)
            let sec = t.isNumeric ? CMTimeGetSeconds(t) : 0.0
            return sec.isFinite ? sec : 0.0
        }

        func waitUntilReady(_ inp: AVAssetWriterInput) async throws {
            while !inp.isReadyForMoreMediaData {
                if writer.status != .writing {
                    throw SafariumError.encode("fMP4 writer stopped (\(writer.status.rawValue)): \(writer.error?.localizedDescription ?? "?")")
                }
                try await Task.sleep(nanoseconds: 500_000)
            }
        }

        var nextV = nextValidSample(from: vo)
        var nextA = ao.flatMap { nextValidSample(from: $0) }
        var subIdx = 0

        while nextV != nil || nextA != nil || (si != nil && subIdx < subSamples.count) {
            let vPTS = nextV.map(safePTSSeconds) ?? Double.infinity
            let aPTS = nextA.map(safePTSSeconds) ?? Double.infinity
            let sPTS = (si != nil && subIdx < subSamples.count) ? safePTSSeconds(subSamples[subIdx]) : Double.infinity

            if let sb = nextV, vPTS <= aPTS && vPTS <= sPTS {
                try await waitUntilReady(vi)
                guard vi.append(sb) else {
                    throw SafariumError.encode("fMP4 video append failed: \(writer.error?.localizedDescription ?? "?")")
                }
                nextV = nextValidSample(from: vo)
            } else if let ai, let ao, let sb = nextA, aPTS <= sPTS {
                try await waitUntilReady(ai)
                guard ai.append(sb) else {
                    throw SafariumError.encode("fMP4 audio append failed: \(writer.error?.localizedDescription ?? "?")")
                }
                nextA = nextValidSample(from: ao)
            } else if let si, subIdx < subSamples.count {
                try await waitUntilReady(si)
                guard si.append(subSamples[subIdx]) else {
                    throw SafariumError.encode("fMP4 subtitle append failed: \(writer.error?.localizedDescription ?? "?")")
                }
                subIdx += 1
            } else {
                break
            }
        }
        vi.markAsFinished()
        ai?.markAsFinished()
        si?.markAsFinished()
        guard reader.status != .failed else {
            writer.cancelWriting()
            throw SafariumError.encode("file-based fMP4 reader failed: \(reader.error?.localizedDescription ?? "?")")
        }

        writer.endSession(atSourceTime: dur)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw SafariumError.encode("file-based fMP4 finishWriting failed: \(writer.error?.localizedDescription ?? "?")")
        }
    }

    private static func materializeLegacyAudioIfNeeded(
        url: URL,
        tag: String,
        sampleRate: Double,
        channels: Int,
        stage: APFSStageSession
    ) throws -> URL {
        let ext = url.pathExtension.lowercased()
        let isLegacyAudioContainer = (ext == "ogg" || ext == "oga" || ext == "opus" || ext == "mpeg" || ext == "mpg")
        guard isLegacyAudioContainer else { return url }
        let outWAV = stage.fileURL("compat_aud_\(tag).wav")
        if FileManager.default.fileExists(atPath: outWAV.path) { return outWAV }
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            throw SafariumError.encode("failed to create PCM format for \(tag)")
        }
        let outFile = try AVAudioFile(forWriting: outWAV, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: true)
        let capFrames = 4096
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(capFrames)) else {
            throw SafariumError.encode("failed to allocate buffer for \(tag)")
        }
        _ = try MediaCompatBridge.streamAudioToFloat32PCM(url: url, sampleRate: sampleRate, channels: channels, chunkFrames: capFrames) { chunk, n in
            guard n > 0, let src = chunk.baseAddress, let dst = buf.audioBufferList.pointee.mBuffers.mData else { return }
            var off = 0
            while off < n {
                let take = min(capFrames, n - off)
                buf.frameLength = AVAudioFrameCount(take)
                _ = memcpy(dst, src + off * channels, take * channels * 4)
                try outFile.write(from: buf)
                off += take
            }
        }
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) { outFile.close() }
        #endif
        return outWAV
    }

    private static func executeAudioGraph(
        plan: ForgeValidatedPlan,
        resolvedPaths: [String: URL],
        audioSourceURLs: [String: URL],
        stage: APFSStageSession
    ) async throws -> (finalURL: URL?, durationSeconds: Double?) {
        let recipe = plan.recipe
        var audioNodes: [String: URL] = [:]
        let sr = Double(recipe.output.audioSampleRate ?? 48_000)
        let ch = recipe.output.audioChannels ?? 2

        // Map audio & synthAudio inputs
        for inp in recipe.inputs {
            switch inp.kind {
            case .synthAudio:
                guard let spec = inp.synth else {
                    throw SafariumError.invalidState("synthAudio input '\(inp.id)' missing synth spec")
                }
                let staged = stage.fileURL("in_synth_\(inp.id).wav")
                _ = try await ForgeProceduralSynth.renderToFile(spec: spec, outputURL: staged, overwrite: true)
                audioNodes[inp.id] = staged
            case .audio:
                if let origURL = audioSourceURLs[inp.id] ?? resolvedPaths[inp.id] {
                    if let trim = inp.trim, trim.count == 2 {
                        let trimmed = stage.fileURL("in_trim_\(inp.id).wav")
                        try await trimAudioFile(inputURL: origURL, startSeconds: trim[0], endSeconds: trim[1], outputURL: trimmed)
                        audioNodes[inp.id] = trimmed
                    } else {
                        audioNodes[inp.id] = try materializeLegacyAudioIfNeeded(url: origURL, tag: inp.id, sampleRate: sr, channels: ch, stage: stage)
                    }
                }
            case .video:
                let origURL = audioSourceURLs[inp.id] ?? resolvedPaths[inp.id]
                if let u = origURL {
                    let ext = u.pathExtension.lowercased()
                    var hasAudio = false
                    if ext == "mpeg" || ext == "mpg" {
                        let ps = try? MPEG2ProgramStream.inspect(url: u)
                        hasAudio = ps?.streams.contains(where: { (0xC0...0xDF).contains($0.streamID) && $0.payloadBytes > 0 }) ?? false
                    } else {
                        let asset = AVURLAsset(url: u)
                        hasAudio = ((try? await asset.loadTracks(withMediaType: .audio).first) != nil)
                    }
                    if hasAudio {
                        if let trim = inp.trim, trim.count == 2 {
                            let trimmed = stage.fileURL("in_vid_aud_\(inp.id).wav")
                            try await trimAudioFile(inputURL: u, startSeconds: trim[0], endSeconds: trim[1], outputURL: trimmed)
                            audioNodes["\(inp.id).audio"] = trimmed
                            audioNodes[inp.id] = trimmed
                        } else {
                            let mat = try materializeLegacyAudioIfNeeded(url: u, tag: "vid_\(inp.id)", sampleRate: sr, channels: ch, stage: stage)
                            audioNodes["\(inp.id).audio"] = mat
                            audioNodes[inp.id] = mat
                        }
                    }
                }
            default:
                break
            }
        }

        if plan.orderedAudioOps.isEmpty {
            if (recipe.output.audioCodec ?? "aac").lowercased() == "none" {
                return (nil, nil)
            }
            if let vidAud = recipe.inputs.first(where: { $0.kind == .video || $0.kind == .audio }).flatMap({ audioNodes["\($0.id).audio"] ?? audioNodes[$0.id] }) {
                let asset = AVURLAsset(url: vidAud)
                let dur = (try? await asset.load(.duration).seconds) ?? nil
                return (vidAud, dur)
            }
            return (nil, nil)
        }

        for op in plan.orderedAudioOps {
            let outWAV = stage.fileURL("aud_\(op.id).wav")
            switch op.op {
            case .synth:
                guard let spec = op.synth else {
                    throw SafariumError.invalidState("audioOp '\(op.id)' synth missing spec")
                }
                _ = try await ForgeProceduralSynth.renderToFile(spec: spec, outputURL: outWAV, overwrite: true)
                audioNodes[op.id] = outWAV

            case .biquadEQ, .compressor, .gain, .loudnorm, .peakLimit, .voiceIsolate:
                guard let ref = op.input, let inURL = audioNodes[ref] else {
                    throw SafariumError.invalidState("audioOp '\(op.id)' missing input '\(op.input ?? "")'")
                }
                var sections: [ForgeBiquadSection] = []
                if op.op == .biquadEQ {
                    sections.append(ForgeBiquadSection(
                        mode: ForgeBiquadMode.parse(op.eqMode),
                        freqHz: op.freqHz ?? 100.0,
                        q: op.q ?? 0.7071,
                        gainDB: op.gainDB ?? 0.0
                    ))
                } else if op.op == .voiceIsolate {
                    sections.append(ForgeBiquadSection(mode: .highpass, freqHz: 85.0))
                    sections.append(ForgeBiquadSection(mode: .peaking, freqHz: 3200.0, q: 1.2, gainDB: 2.5))
                }
                let compThresh = (op.op == .compressor) ? (op.thresholdDB ?? -18.0) : (op.op == .voiceIsolate ? -22.0 : nil)
                _ = try await ForgeAudioDSP.processAudio(
                    inputURL: inURL,
                    outputURL: outWAV,
                    eqSections: sections,
                    compressorThresholdDB: compThresh,
                    compressorRatio: op.ratio ?? 4.0,
                    gainDB: (op.op == .gain ? (op.gainDB ?? 0.0) : 0.0),
                    normalizeLUFS: op.targetLUFS ?? op.normalizeLUFS,
                    peakCeilingDBTP: op.peakCeilingDBTP ?? -1.05,
                    sampleRate: sr,
                    channels: ch,
                    overwrite: true
                )
                audioNodes[op.id] = outWAV

            case .acrossfade:
                guard let aRef = op.inA, let bRef = op.inB,
                      let urlA = audioNodes[aRef], let urlB = audioNodes[bRef] else {
                    throw SafariumError.invalidState("acrossfade '\(op.id)' requires inA and inB")
                }
                _ = try await ForgeAudioDSP.crossfadeAudio(
                    firstURL: urlA,
                    secondURL: urlB,
                    durationSeconds: op.durationSeconds ?? 0.5,
                    curve: op.curve ?? "eqpower",
                    sampleRate: sr,
                    channels: ch,
                    outputURL: outWAV,
                    overwrite: true
                )
                audioNodes[op.id] = outWAV

            case .silenceTrim:
                guard let ref = op.input, let inURL = audioNodes[ref] else {
                    throw SafariumError.invalidState("silenceTrim '\(op.id)' missing input")
                }
                _ = try await ForgeAudioDSP.silenceTrim(
                    inputURL: inURL,
                    outputURL: outWAV,
                    thresholdDB: op.thresholdDB ?? -42.0,
                    paddingSeconds: op.paddingSeconds ?? 0.05,
                    sampleRate: sr,
                    channels: ch,
                    overwrite: true
                )
                audioNodes[op.id] = outWAV

            case .waveform:
                guard let ref = op.input, let inURL = audioNodes[ref] else {
                    throw SafariumError.invalidState("waveform '\(op.id)' missing input")
                }
                let wf = try await ForgeAudioDSP.extractWaveform(inputURL: inURL, bins: op.bins ?? 120)
                if let jsonPath = op.outputJSONPath {
                    let enc = JSONEncoder()
                    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try enc.encode(wf)
                    let jURL = URL(fileURLWithPath: jsonPath)
                    try SafeFilePublisher.preflight(outputURL: jURL, overwrite: recipe.output.overwrite ?? false)
                    try data.write(to: jURL)
                }
                audioNodes[op.id] = inURL

            case .sidechainDuck:
                guard let cRef = op.carrier, let sRef = op.sidechain,
                      let cURL = audioNodes[cRef], let sURL = audioNodes[sRef] else {
                    throw SafariumError.invalidState("sidechainDuck '\(op.id)' requires carrier and sidechain")
                }
                try await applySidechainDuckStreaming(
                    carrierURL: cURL,
                    sidechainURL: sURL,
                    thresholdDB: op.thresholdDB ?? -26.0,
                    duckDB: op.duckDB ?? -10.0,
                    attackMs: op.attackMs ?? 15.0,
                    releaseMs: op.releaseMs ?? 200.0,
                    sampleRate: sr,
                    channels: ch,
                    outputURL: outWAV
                )
                audioNodes[op.id] = outWAV

            case .mix:
                let refs = op.tracks ?? []
                guard !refs.isEmpty else {
                    throw SafariumError.invalidState("mix '\(op.id)' requires tracks")
                }
                var mixTracks: [AudioMixTrack] = []
                for (i, r) in refs.enumerated() {
                    guard let u = audioNodes[r] else {
                        throw SafariumError.invalidState("mix '\(op.id)' missing track '\(r)'")
                    }
                    let gain = (op.gainsDB != nil && i < op.gainsDB!.count) ? op.gainsDB![i] : 0.0
                    let startSec = (op.startSeconds != nil && i < op.startSeconds!.count) ? op.startSeconds![i] : 0.0
                    let isLoop = recipe.inputs.first(where: { $0.id == r })?.loop ?? false
                    mixTracks.append(AudioMixTrack(url: u, gainDB: gain, startSeconds: startSec, loop: isLoop))
                }
                _ = try await AudioMixer.mix(
                    tracks: mixTracks,
                    to: outWAV,
                    durationSeconds: op.durationSeconds ?? recipe.timeline.durationSeconds,
                    sampleRate: sr,
                    channels: ch,
                    normalizeLUFS: op.normalizeLUFS ?? op.targetLUFS,
                    peakCeilingDBTP: op.peakCeilingDBTP ?? -1.05,
                    overwrite: true
                )
                audioNodes[op.id] = outWAV

            case .fade, .afade:
                guard let ref = op.input, let inURL = audioNodes[ref] else {
                    throw SafariumError.invalidState("\(op.op.rawValue) '\(op.id)' missing input")
                }
                _ = try await ForgeAudioDSP.applyFade(
                    inputURL: inURL,
                    outputURL: outWAV,
                    fadeInSeconds: op.fadeInSeconds ?? 0.0,
                    fadeOutSeconds: op.fadeOutSeconds ?? 0.0,
                    sampleRate: sr,
                    channels: ch,
                    overwrite: true
                )
                audioNodes[op.id] = outWAV

            case .trim, .atrim, .pad, .apad:
                guard let ref = op.input, let inURL = audioNodes[ref] else {
                    throw SafariumError.invalidState("\(op.op.rawValue) '\(op.id)' missing input")
                }
                _ = try await ForgeAudioDSP.padOrTrim(
                    inputURL: inURL,
                    outputURL: outWAV,
                    trimStartSeconds: op.trimStartSeconds ?? 0.0,
                    trimEndSeconds: op.trimEndSeconds,
                    padToDurationSeconds: op.padToDurationSeconds ?? op.durationSeconds,
                    sampleRate: sr,
                    channels: ch,
                    overwrite: true
                )
                audioNodes[op.id] = outWAV
            }
        }

        if let finalID = plan.finalAudioNodeID, let u = audioNodes[finalID] {
            let r = try await ForgeStreamingAudioReader(url: u, sampleRate: sr, channels: ch)
            let d = r.durationSeconds
            r.close()
            return (u, d)
        }
        return (nil, nil)
    }

    private static func trimAudioFile(inputURL: URL, startSeconds: Double, endSeconds: Double, outputURL: URL) async throws {
        let r = try await ForgeStreamingAudioReader(url: inputURL, sampleRate: 48_000, channels: 2, startSeconds: startSeconds, endSeconds: endSeconds)
        defer { r.close() }
        let sink = try ForgeStreamingAudioSink(url: outputURL, sampleRate: 48_000, channels: 2)
        var buf = [Float](repeating: 0, count: 4096 * 2)
        do {
            while true {
                let n = try buf.withUnsafeMutableBufferPointer { try r.readNextBlock(into: $0.baseAddress!, maxFrames: 4096) }
                if n == 0 { break }
                try await sink.append(interleavedFrames: buf, frameCount: n)
            }
            try await sink.finish()
        } catch {
            sink.cancel()
            throw error
        }
    }

    private static func applySidechainDuckStreaming(
        carrierURL: URL,
        sidechainURL: URL,
        thresholdDB: Double,
        duckDB: Double,
        attackMs: Double,
        releaseMs: Double,
        sampleRate: Double,
        channels: Int,
        outputURL: URL
    ) async throws {
        let cReader = try await ForgeStreamingAudioReader(url: carrierURL, sampleRate: sampleRate, channels: channels)
        let sReader = try await ForgeStreamingAudioReader(url: sidechainURL, sampleRate: sampleRate, channels: channels)
        defer { cReader.close(); sReader.close() }
        let threshLin = powf(10.0, Float(thresholdDB / 20.0))
        let duckLin = powf(10.0, Float(duckDB / 20.0))
        let ducker = try SidechainDucker(
            sampleRate: sampleRate, channels: channels, threshold: threshLin, duckGainLinear: duckLin,
            attackMs: attackMs, releaseMs: releaseMs
        )
        let sink = try ForgeStreamingAudioSink(url: outputURL, sampleRate: Int(sampleRate), channels: channels)
        var cBuf = [Float](repeating: 0, count: 4096 * channels)
        var sBuf = [Float](repeating: 0, count: 4096 * channels)
        do {
            while true {
                let nC = try cBuf.withUnsafeMutableBufferPointer { try cReader.readNextBlock(into: $0.baseAddress!, maxFrames: 4096) }
                if nC == 0 { break }
                let nS = try sBuf.withUnsafeMutableBufferPointer { try sReader.readNextBlock(into: $0.baseAddress!, maxFrames: nC) }
                if nS < nC {
                    for i in (nS * channels)..<(nC * channels) { sBuf[i] = 0 }
                }
                sBuf.withUnsafeBufferPointer { sPtr in
                    cBuf.withUnsafeMutableBufferPointer { cPtr in
                        ducker.apply(voiceInterleaved: sPtr.baseAddress!, targetInterleaved: cPtr.baseAddress!, frameCount: nC)
                    }
                }
                try await sink.append(interleavedFrames: cBuf, frameCount: nC)
            }
            try await sink.finish()
        } catch {
            sink.cancel()
            throw error
        }
    }

    private static func evaluateVideoOp(
        op: ForgeVideoOp,
        frameIdx: Int,
        t: Double,
        fps: Int,
        duration: Double,
        outWidth: Int,
        outHeight: Int,
        nodeBuffers: [String: CVPixelBuffer],
        htmlTextures: [String: MTLTexture],
        imageTextures: [String: MTLTexture],
        lutInputs: [String: (lut: ForgeCubeLUT, tex: MTLTexture)],
        compiledExpr: (x: ForgeExprNode?, y: ForgeExprNode?, scale: ForgeExprNode?, opacity: ForgeExprNode?, enable: ForgeExprNode?, zoom: ForgeExprNode?, cx: ForgeExprNode?, cy: ForgeExprNode?),
        reframeTrackers: [String: ForgeReframeTracker],
        matteProcessors: [String: ForgePersonMatteProcessor],
        deinterlaceHistory: inout [String: DeinterlaceHistoryRing],
        tmixHistory: inout [String: [CVPixelBuffer]],
        kgriefHistory: inout [String: CVPixelBuffer],
        llsrScalers: [String: ForgeLLSRUpscaler],
        filterEngine: ForgeMetalFilterEngine,
        ring: ForgeIOSurfaceRing
    ) throws -> CVPixelBuffer {
        func requirePB(_ id: String?) throws -> CVPixelBuffer {
            guard let id, let pb = nodeBuffers[id] else {
                throw SafariumError.invalidState("videoOp '\(op.id)' missing buffer '\(id ?? "")'")
            }
            return pb
        }
        let liveExcluded = Array(nodeBuffers.values)
        func acquireDst(width w: Int, height h: Int) throws -> CVPixelBuffer {
            try ring.acquire(width: w, height: h, excluding: liveExcluded)
        }

        switch op.op {
        case .geom:
            let src = try requirePB(op.input)
            let sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src)
            let tw = op.padWidth ?? op.width ?? (op.scaleX.map { max(2, Int((Double(sw) * $0).rounded())) }) ?? outWidth
            let th = op.padHeight ?? op.height ?? (op.scaleY.map { max(2, Int((Double(sh) * $0).rounded())) }) ?? outHeight
            let dst = try acquireDst(width: tw, height: th)
            var crop: CGRect? = op.cropRect.flatMap { r in
                r.count == 4 ? CGRect(x: r[0], y: r[1], width: r[2], height: r[3]) : nil
            }
            if op.aspectFill == true && crop == nil {
                let targetScale = max(Double(tw) / Double(max(1, sw)), Double(th) / Double(max(1, sh)))
                let cw = min(Double(sw), Double(tw) / targetScale)
                let ch = min(Double(sh), Double(th) / targetScale)
                let cx = max(0.0, (Double(sw) - cw) * 0.5)
                let cy = max(0.0, (Double(sh) - ch) * 0.5)
                crop = CGRect(x: cx, y: cy, width: cw, height: ch)
            }
            let padRect: CGRect?
            if let pw = op.padWidth, let ph = op.padHeight {
                let cw = min(pw, op.width ?? sw)
                let ch = min(ph, op.height ?? sh)
                padRect = CGRect(x: (pw - cw) / 2, y: (ph - ch) / 2, width: cw, height: ch)
            } else {
                padRect = nil
            }
            try filterEngine.applyGeom(
                srcPB: src,
                into: dst,
                cropRect: crop,
                dstRect: padRect,
                rotateDegrees: op.rotateDegrees ?? 0.0,
                hflip: op.hflip ?? false,
                vflip: op.vflip ?? false,
                bgColor: ForgeColorHex.parseRGBA(op.padColorHex ?? op.bgColorHex)
            )
            return dst

        case .deinterlace:
            let src = try requirePB(op.input)
            let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
            let dst = try acquireDst(width: w, height: h)
            var hist = deinterlaceHistory[op.id] ?? DeinterlaceHistoryRing()
            let prev = hist.prevPB(fallback: src)
            let curr = hist.currPB(fallback: src)
            try filterEngine.applyDeinterlace(
                prevPB: prev,
                currPB: curr,
                nextPB: src,
                into: dst,
                fieldOrder: ForgeFieldOrder.parse(op.fieldOrder),
                parity: frameIdx & 1,
                motionThreshold: Float(op.motionThreshold ?? 0.08)
            )
            try hist.push(src, width: w, height: h, filterEngine: filterEngine)
            deinterlaceHistory[op.id] = hist
            return dst

        case .kenBurns:
            let src = try requirePB(op.input)
            let tw = op.width ?? outWidth, th = op.height ?? outHeight
            let dst = try acquireDst(width: tw, height: th)
            let progress = duration > 0 ? min(1.0, max(0.0, t / duration)) : 0.0
            let ctx = ForgeExprContext(t: t, frame: Double(frameIdx), fps: Double(fps), duration: duration, canvasWidth: Double(tw), canvasHeight: Double(th), overlayWidth: Double(CVPixelBufferGetWidth(src)), overlayHeight: Double(CVPixelBufferGetHeight(src)))
            let z = compiledExpr.zoom?.evaluate(ctx) ?? ((op.zoomStart ?? 1.0) + ((op.zoomEnd ?? 1.15) - (op.zoomStart ?? 1.0)) * progress)
            let cx = compiledExpr.cx?.evaluate(ctx) ?? ((op.panXStart ?? 0.5) + ((op.panXEnd ?? 0.5) - (op.panXStart ?? 0.5)) * progress)
            let cy = compiledExpr.cy?.evaluate(ctx) ?? ((op.panYStart ?? 0.5) + ((op.panYEnd ?? 0.5) - (op.panYStart ?? 0.5)) * progress)
            try filterEngine.applyKenBurns(srcPB: src, into: dst, centerNorm: SIMD2<Float>(Float(cx), Float(cy)), zoom: Float(z), bicubic: true)
            return dst

        case .chromaKey:
            let src = try requirePB(op.input)
            let dst = try acquireDst(width: CVPixelBufferGetWidth(src), height: CVPixelBufferGetHeight(src))
            let rgba = ForgeColorHex.parseRGBA(op.keyColorHex ?? "#00FF00")
            try filterEngine.applyChromaKey(
                srcPB: src,
                into: dst,
                keyRGB: SIMD3<Float>(rgba.x, rgba.y, rgba.z),
                similarity: Float(op.similarity ?? 0.14),
                smoothness: Float(op.smoothness ?? 0.08),
                despillStrength: Float(op.despillStrength ?? 0.85),
                erodeRadius: op.erodeRadius ?? 1
            )
            return dst

        case .gblur:
            let src = try requirePB(op.input)
            let dst = try acquireDst(width: CVPixelBufferGetWidth(src), height: CVPixelBufferGetHeight(src))
            try filterEngine.applyGaussianBlur(srcPB: src, into: dst, sigma: Float(op.sigma ?? 4.0))
            return dst

        case .colorGrade:
            let src = try requirePB(op.input)
            let dst = try acquireDst(width: CVPixelBufferGetWidth(src), height: CVPixelBufferGetHeight(src))
            try filterEngine.applyColorGrade(
                srcPB: src,
                into: dst,
                brightness: Float(op.brightness ?? 0.0),
                contrast: Float(op.contrast ?? 1.0),
                saturation: Float(op.saturation ?? 1.0),
                gamma: Float(op.gamma ?? 1.0),
                grayscale: Float(op.grayscale ?? 0.0)
            )
            return dst

        case .lut3d:
            let src = try requirePB(op.input)
            guard let lutRef = op.lut, let lutPair = lutInputs[lutRef] else {
                throw SafariumError.invalidState("lut3d '\(op.id)' missing LUT '\(op.lut ?? "")'")
            }
            let dst = try acquireDst(width: CVPixelBufferGetWidth(src), height: CVPixelBufferGetHeight(src))
            try filterEngine.applyLUT3D(srcPB: src, into: dst, lutTexture: lutPair.tex, lut: lutPair.lut, intensity: Float(op.intensity ?? 1.0))
            return dst

        case .vignette:
            let src = try requirePB(op.input)
            let dst = try acquireDst(width: CVPixelBufferGetWidth(src), height: CVPixelBufferGetHeight(src))
            try filterEngine.applyVignette(srcPB: src, into: dst, intensity: Float(op.intensity ?? 0.5), radius: Float(op.radius ?? 0.75), softness: Float(op.softness ?? 0.55))
            return dst

        case .grain:
            let src = try requirePB(op.input)
            let dst = try acquireDst(width: CVPixelBufferGetWidth(src), height: CVPixelBufferGetHeight(src))
            try filterEngine.applyGrain(srcPB: src, into: dst, amount: Float(op.amount ?? 0.04), grainSize: Float(op.grainSize ?? 1.0), frameSeed: (op.seed ?? 1337) &+ UInt32(frameIdx))
            return dst

        case .overlay, .blend, .htmlOverlay:
            let baseID = op.base ?? op.input
            let overID = op.over ?? op.input
            let basePB = try requirePB(baseID)
            let overPB = try requirePB(overID)
            let bw = CVPixelBufferGetWidth(basePB), bh = CVPixelBufferGetHeight(basePB)
            let ow = CVPixelBufferGetWidth(overPB), oh = CVPixelBufferGetHeight(overPB)
            let ctx = ForgeExprContext(t: t, frame: Double(frameIdx), fps: Double(fps), duration: duration, canvasWidth: Double(bw), canvasHeight: Double(bh), overlayWidth: Double(ow), overlayHeight: Double(oh))
            if let en = compiledExpr.enable, en.evaluate(ctx) == 0 {
                return basePB
            }
            let px = compiledExpr.x?.evaluate(ctx) ?? 0.0
            let py = compiledExpr.y?.evaluate(ctx) ?? 0.0
            let sc = compiledExpr.scale?.evaluate(ctx) ?? 1.0
            let opa = compiledExpr.opacity?.evaluate(ctx) ?? 1.0
            let dst = try acquireDst(width: bw, height: bh)
            if let cachedTex = overID.flatMap({ htmlTextures[$0] ?? imageTextures[$0] }) {
                try filterEngine.applyOverlay(
                    basePB: basePB, overTex: cachedTex, into: dst,
                    origin: SIMD2<Float>(Float(px), Float(py)), scale: Float(sc), opacity: Float(opa),
                    blendMode: ForgeBlendMode.parse(op.blendMode)
                )
            } else {
                try filterEngine.applyOverlay(
                    basePB: basePB, overPB: overPB, into: dst,
                    origin: SIMD2<Float>(Float(px), Float(py)), scale: Float(sc), opacity: Float(opa),
                    blendMode: ForgeBlendMode.parse(op.blendMode)
                )
            }
            return dst

        case .xfade:
            let pbA = try requirePB(op.from)
            let pbB = try requirePB(op.to)
            let off = op.offsetSeconds ?? 0.0
            let xDur = max(0.001, op.durationSeconds ?? 1.0)
            let progress = Float(min(1.0, max(0.0, (t - off) / xDur)))
            let dst = try acquireDst(width: CVPixelBufferGetWidth(pbA), height: CVPixelBufferGetHeight(pbA))
            try filterEngine.applyXfade(pbA: pbA, pbB: pbB, into: dst, progress: progress, transition: ForgeXfadeTransition.parse(op.transition))
            return dst

        case .hstack, .vstack:
            let list = op.inputs ?? []
            let pbs = try list.map { try requirePB($0) }
            let tw = op.width ?? outWidth, th = op.height ?? outHeight
            let dst = try acquireDst(width: tw, height: th)
            try filterEngine.applyStack(inputs: pbs, into: dst, horizontal: op.op == .hstack, padding: op.padding ?? 0, bgColor: ForgeColorHex.parseRGBA(op.bgColorHex))
            return dst

        case .paperCutout:
            let src = try requirePB(op.input)
            let dst = try acquireDst(width: CVPixelBufferGetWidth(src), height: CVPixelBufferGetHeight(src))
            try filterEngine.applyWave2Effect(.paperCutout, srcPB: src, into: dst)
            return dst

        case .markerTexture:
            let src = try requirePB(op.input)
            let dst = try acquireDst(width: CVPixelBufferGetWidth(src), height: CVPixelBufferGetHeight(src))
            try filterEngine.applyWave2Effect(.markerTexture, srcPB: src, into: dst)
            return dst

        case .splitMetalFX:
            let lr = try requirePB(op.lowResIn)
            let ov = try requirePB(op.overlay1xIn)
            let dst = try acquireDst(width: CVPixelBufferGetWidth(ov), height: CVPixelBufferGetHeight(ov))
            try filterEngine.applySplitMetalFX(backgroundLowResPB: lr, overlay1xPB: ov, into: dst)
            return dst

        case .autoReframe:
            let src = try requirePB(op.input)
            guard let tracker = reframeTrackers[op.id] else {
                throw SafariumError.invalidState("missing reframe tracker '\(op.id)'")
            }
            let sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src)
            let targetAspect = try ForgeReframeTracker.parseAspect(op.aspect ?? "9:16")
            let normCrop = tracker.nextCropRectNormalized(visionPB: src, luma420vPB: nil, targetAspect: targetAspect, sourceWidth: sw, sourceHeight: sh)
            let th = op.height ?? outHeight
            let tw = op.width ?? max(2, Int((Double(th) * targetAspect).rounded()) & ~1)
            let dst = try acquireDst(width: tw, height: th)
            let cropPx = CGRect(x: normCrop.origin.x * Double(sw), y: normCrop.origin.y * Double(sh), width: normCrop.width * Double(sw), height: normCrop.height * Double(sh))
            try filterEngine.applyGeom(srcPB: src, into: dst, cropRect: cropPx)
            return dst

        case .personMatte:
            let src = try requirePB(op.input)
            guard let proc = matteProcessors[op.id] else {
                throw SafariumError.invalidState("missing matte processor '\(op.id)'")
            }
            let sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src)
            let dst = try acquireDst(width: sw, height: sh)
            let bgTex = op.replaceBgInput.flatMap { imageTextures[$0] ?? htmlTextures[$0] }
            let bgColor = op.replaceBgHex.map { ForgeColorHex.parseRGBA($0) } ?? SIMD4<Float>(0, 0, 0, 0)
            try proc.processFrame(srcPB: src, bgTex: bgTex, bgColor: bgColor, maskOnly: op.outputMaskOnly ?? false, into: dst)
            return dst

        case .tmix:
            let src = try requirePB(op.input)
            let sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src)
            let rawWeights = (op.tmixWeights?.isEmpty == false) ? op.tmixWeights! : [1.0, 1.0, 1.0]
            let window = max(1, rawWeights.count)
            var hist = tmixHistory[op.id] ?? []
            if let first = hist.first, CVPixelBufferGetWidth(first) != sw || CVPixelBufferGetHeight(first) != sh {
                hist.removeAll()
            }
            let copyPB: CVPixelBuffer
            if hist.count < window {
                copyPB = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: sw, height: sh, pixelFormat: .bgra)
                hist.append(copyPB)
            } else {
                let oldest = hist.removeFirst()
                copyPB = oldest
                hist.append(copyPB)
            }
            try filterEngine.applyGeom(srcPB: src, into: copyPB)
            tmixHistory[op.id] = hist
            let usedWeights = rawWeights.suffix(hist.count).map { Float($0) }
            let dst = try acquireDst(width: sw, height: sh)
            try filterEngine.applyTMix(frames: hist, weights: usedWeights, normalizeWeights: true, into: dst)
            return dst

        case .kGrief:
            let src = try requirePB(op.input)
            let sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src)
            let prev = kgriefHistory[op.id]
            let prevMatching = (prev != nil && CVPixelBufferGetWidth(prev!) == sw && CVPixelBufferGetHeight(prev!) == sh) ? prev : nil
            let hudPB = (op.kGriefHudShield == true) ? op.overlay1xIn.flatMap { nodeBuffers[$0] } : nil
            let cfg = ForgeKGriefConfig(
                saturation: Float(op.kGriefSaturation ?? op.saturation ?? 0.10),
                brightness: Float(op.kGriefExposure ?? op.brightness ?? 0.92),
                temporalBlend: Float(op.kGriefTemporalWeight ?? 0.25)
            )
            let dst = try acquireDst(width: sw, height: sh)
            try filterEngine.applyKGrief(currPB: src, prevPB: prevMatching, flowPB: nil, hudOverlayPB: hudPB, config: cfg, into: dst)
            let nextPrev: CVPixelBuffer
            if let existing = prevMatching {
                nextPrev = existing
            } else {
                nextPrev = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: sw, height: sh, pixelFormat: .bgra)
            }
            try filterEngine.applyGeom(srcPB: src, into: nextPrev)
            kgriefHistory[op.id] = nextPrev
            return dst

        case .llsr:
            let src = try requirePB(op.input)
            let sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src)
            let sf = op.llsrScaleFactor ?? 2.0
            let tw = op.width ?? max(2, (Int((Double(sw) * sf).rounded()) + 1) & ~1)
            let th = op.height ?? max(2, (Int((Double(sh) * sf).rounded()) + 1) & ~1)
            guard let scaler = llsrScalers[op.id] else {
                throw SafariumError.invalidState("missing LLSR scaler '\(op.id)'")
            }
            let hudPB = op.overlay1xIn.flatMap { nodeBuffers[$0] }
            let res = try scaler.upscale(
                lowResPB: src,
                targetWidth: tw,
                targetHeight: th,
                reference1xPB: nil,
                overlay1xPB: hudPB,
                policy: ForgeLLSRPolicy(enabled: true)
            )
            let rw = CVPixelBufferGetWidth(res.outputPB), rh = CVPixelBufferGetHeight(res.outputPB)
            let dst = try acquireDst(width: rw, height: rh)
            try filterEngine.applyGeom(srcPB: res.outputPB, into: dst)
            return dst

        case .setpts, .tpad:
            let src = try requirePB(op.input)
            let sw = CVPixelBufferGetWidth(src), sh = CVPixelBufferGetHeight(src)
            let dst = try acquireDst(width: sw, height: sh)
            try filterEngine.applyGeom(srcPB: src, into: dst)
            return dst
        }
    }

    private static func decodeMPEG2WindowToMP4(
        sourceURL: URL,
        outputURL: URL,
        width: Int,
        height: Int,
        fps: Int,
        trimStartSeconds: Double,
        maxOutputFrames: Int,
        maxDecodeFrames: Int
    ) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(url: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 24_000_000,
                AVVideoMaxKeyFrameIntervalKey: max(1, fps),
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else {
            throw SafariumError.encode("cannot configure MPEG-2 intermediate AVAssetWriter")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw SafariumError.encode("failed starting MPEG-2 intermediate writer: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)

        var firstKeptTime: Double?
        var outIdx = 0
        var prevPTS = CMTime.invalid
        let targetFPS = max(1, fps)
        _ = try MPEG2ProgramStream.decodeVideoFrames(url: sourceURL, maxFrames: maxDecodeFrames) { pb, pts, _ in
            guard outIdx < maxOutputFrames else { return }
            let sec = pts.isValid ? pts.seconds : (Double(outIdx) / Double(targetFPS))
            if trimStartSeconds > 0 && sec + (0.5 / Double(targetFPS)) < trimStartSeconds { return }
            if firstKeptTime == nil { firstKeptTime = sec }
            var framePTS = CMTime(value: Int64(outIdx), timescale: Int32(targetFPS))
            if prevPTS.isValid && CMTimeCompare(framePTS, prevPTS) <= 0 {
                framePTS = CMTimeAdd(prevPTS, CMTime(value: 1, timescale: Int32(targetFPS)))
            }
            var waitLoops = 0
            while !input.isReadyForMoreMediaData && waitLoops < 2000 {
                Thread.sleep(forTimeInterval: 0.001)
                waitLoops += 1
            }
            if adaptor.append(pb, withPresentationTime: framePTS) {
                prevPTS = framePTS
                outIdx += 1
            } else {
                throw SafariumError.encode("MPEG-2 intermediate append failed: \(writer.error?.localizedDescription ?? "?")")
            }
        }
        guard outIdx > 0 else {
            writer.cancelWriting()
            throw SafariumError.encode("MPEG-2 Program Stream yielded 0 frames in range for \(sourceURL.lastPathComponent)")
        }
        input.markAsFinished()
        await withCheckedContinuation { cont in
            writer.finishWriting { cont.resume() }
        }
        if writer.status != .completed {
            throw SafariumError.encode("MPEG-2 intermediate finish failed: \(writer.error?.localizedDescription ?? "?")")
        }
    }

    private static func measureMaxChromaDelta(_ pb: CVPixelBuffer) throws -> Double {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        guard fmt == kCVPixelFormatType_32BGRA else { return 0.0 }
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else {
            throw SafariumError.encode("monochromeCheck failed to lock pixel buffer")
        }
        defer { _ = CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return 0.0 }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let strideY = max(1, h / 120)
        let strideX = max(1, w / 160)
        var maxDelta = 0
        for y in stride(from: 0, to: h, by: strideY) {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt8.self)
            for x in stride(from: 0, to: w, by: strideX) {
                let b = Int(row[x * 4])
                let g = Int(row[x * 4 + 1])
                let r = Int(row[x * 4 + 2])
                let d = max(abs(r - g), max(abs(g - b), abs(r - b)))
                if d > maxDelta { maxDelta = d }
            }
        }
        return Double(maxDelta) / 255.0
    }

    private static func writeRawData(
        _ data: Data,
        format: ForgeRawPixelFormat,
        width: Int,
        height: Int,
        intoBGRA pb: CVPixelBuffer
    ) throws {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let dstBase = CVPixelBufferGetBaseAddress(pb) else {
            throw SafariumError.encode("missing rawPipe destination base")
        }
        try ForgeSheetAndQA.convertRawFrameToBGRA(
            data,
            format: format,
            width: width,
            height: height,
            destination: dstBase,
            dstStride: CVPixelBufferGetBytesPerRow(pb)
        )
    }

    private static func copyOrConvertBGRA(
        _ srcBGRA: CVPixelBuffer,
        into dstPB: CVPixelBuffer,
        pixelFormat: SinkPixelFormat,
        width: Int,
        height: Int,
        filterEngine: ForgeMetalFilterEngine
    ) throws {
        switch pixelFormat {
        case .bgra:
            try filterEngine.applyGeom(srcPB: srcBGRA, into: dstPB)
        case .nv12Left, .nv12vImage:
            CVPixelBufferLockBaseAddress(srcBGRA, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(srcBGRA, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(srcBGRA) else {
                throw SafariumError.encode("missing final BGRA base address")
            }
            let stride = CVPixelBufferGetBytesPerRow(srcBGRA)
            try SafariumAccelerate.convertRawBGRAToNV12BT709Left(
                bgra: base, bgraBytesPerRow: stride, into: dstPB, width: width, height: height
            )
        }
    }
}
