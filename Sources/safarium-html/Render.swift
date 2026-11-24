import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import SafariumCore
import WebKit

// Installed before the page's own code. clock.js reports errors from timers/rAF
// with ErrorEvent; MutationObserver marks asset/DOM dirty only when relevant nodes/attributes change.
private let observeErrors = """
(() => {
  let failure;
  let mediaDirty = true;
  let lastFontCount = -1;
  const fail = text => { failure ??= String(text).slice(0, 300); };
  window.addEventListener('error', e => {
    if (e instanceof ErrorEvent) fail(e.message || 'page script failed');
    else if (e.target?.matches?.('script,link[rel~="stylesheet"],img'))
      fail('could not load local <' + e.target.localName + '> asset');
  }, true);
  window.addEventListener('unhandledrejection', e => fail(e.reason?.message || 'unhandled page promise rejection'));
  const assetSelector = 'video, iframe, frame, embed, object, [data-composition-src], img, audio, script, link[rel~="stylesheet"]';
  const mo = new MutationObserver(records => {
    for (const r of records) {
      if (r.type === 'attributes') { mediaDirty = true; return; }
      for (const list of [r.addedNodes, r.removedNodes]) {
        for (const n of list) {
          if (n.nodeType === 1 && (n.matches?.(assetSelector) || n.querySelector?.(assetSelector))) {
            mediaDirty = true;
            return;
          }
        }
      }
    }
  });
  mo.observe(document, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ['src', 'srcset', 'data-composition-src', 'href', 'rel'],
  });
  Object.defineProperty(window, '__safariumHTMLCheck', { value: () => { if (failure) throw new Error(failure); } });
  Object.defineProperty(window, '__safariumHTMLShouldRescan', {
    value: () => mediaDirty || (document.fonts && document.fonts.size !== lastFontCount)
  });
  Object.defineProperty(window, '__safariumHTMLMarkClean', {
    value: () => {
      mediaDirty = false;
      if (document.fonts) lastFontCount = document.fonts.size;
    }
  });
})();
"""

// Fixed capability check; full DOM/font/image scan only executes on frame 0 or when MutationObserver flags changes.
private let checkDocument = """
window.__safariumHTMLCheck();
if (window.__sfVideoSeek != null || window.__sfClock.videoSeekHook != null)
  throw new Error('custom video seek hooks are unsupported');
if (window.__seek != null && typeof window.__seek !== 'function')
  throw new Error('window.__seek must be a function');
if (window.__timelines != null && (typeof window.__timelines !== 'object' ||
    Object.values(window.__timelines).some(tl => typeof tl?.seek !== 'function' && typeof tl?.time !== 'function')))
  throw new Error('registered timelines need seek(seconds) or time(seconds)');
if (!forceScan && !window.__safariumHTMLShouldRescan()) return cachedAudioCount;
const embed = document.querySelector('video, iframe, frame, embed, object, [data-composition-src]');
if (embed) throw new Error('embedded video/documents are unsupported: <' + embed.localName + '>');
await document.fonts.ready;
if (Array.from(document.fonts).some(f => f.status === 'error')) throw new Error('a page font failed to load');
await Promise.all(Array.from(document.images, async img => {
  if (!(img.currentSrc || img.getAttribute('src') || img.getAttribute('srcset'))) return;
  if (!img.complete) await img.decode();
  if (!img.naturalWidth) throw new Error('a page image failed to load');
}));
window.__safariumHTMLCheck();
window.__safariumHTMLMarkClean();
return document.querySelectorAll('audio').length;
"""

private func bcp47FromISO639_2(_ code: String) -> String {
    switch code.lowercased() {
    case "pol": return "pl"
    case "tha": return "th"
    case "eng": return "en"
    case "jpn": return "ja"
    case "kor": return "ko"
    case "zho": return "zh"
    default: return code.lowercased()
    }
}

private func mediaError(_ action: String, _ error: Error?) -> WorkerError {
    WorkerError("\(action): \(error?.localizedDescription ?? "media operation did not complete")")
}

/// Pull-driven AVAssetWriterInput feeder using `requestMediaDataWhenReady(on:)`.
/// Allows AVAssetWriter's multi-track interleaver to request audio/subtitle samples independently
/// of the video capture loop without deadlocking when video input pauses for interleaving.
private final class PullMediaFeeder: @unchecked Sendable {
    private let input: AVAssetWriterInput
    private let writer: AVAssetWriter
    private let queue: DispatchQueue
    private let action: String
    private let pull: () throws -> CMSampleBuffer?
    private let onFailure: @Sendable () -> Void
    private let lock = NSLock()
    private var finished = false
    private var cancelled = false
    private var storedError: Error?
    private var completionCont: CheckedContinuation<Void, Error>?

    init(
        label: String,
        action: String,
        input: AVAssetWriterInput,
        writer: AVAssetWriter,
        onFailure: @escaping @Sendable () -> Void,
        pull: @escaping () throws -> CMSampleBuffer?
    ) {
        self.action = action
        self.input = input
        self.writer = writer
        self.queue = DispatchQueue(label: label)
        self.onFailure = onFailure
        self.pull = pull
    }

    func start() {
        input.requestMediaDataWhenReady(on: queue) { [weak self] in
            self?.drain()
        }
    }

    func checkError() throws {
        if let err = lock.withLock({ storedError }) {
            throw err
        }
    }

    func cancel() {
        let cont: CheckedContinuation<Void, Error>? = lock.withLock {
            cancelled = true
            let c = completionCont
            completionCont = nil
            return c
        }
        cont?.resume(throwing: CancellationError())
    }

    func waitFinished() async throws {
        try Task.checkCancellation()
        let immediate: Result<Void, Error>? = lock.withLock {
            if let err = storedError { return .failure(err) }
            if finished { return .success(()) }
            if cancelled { return .failure(CancellationError()) }
            return nil
        }
        if let immediate {
            try immediate.get()
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let immediateLocked: Result<Void, Error>? = lock.withLock {
                    if let err = storedError { return .failure(err) }
                    if finished { return .success(()) }
                    if cancelled { return .failure(CancellationError()) }
                    completionCont = cont
                    return nil
                }
                if let immediateLocked {
                    cont.resume(with: immediateLocked)
                }
            }
        } onCancel: {
            cancel()
        }
    }

    private func drain() {
        while true {
            let state: (cancelled: Bool, finished: Bool, ready: Bool, status: AVAssetWriter.Status) = lock.withLock {
                (cancelled, finished, input.isReadyForMoreMediaData, writer.status)
            }
            if state.cancelled || state.finished { return }
            if state.status != .writing {
                fail(mediaError(action, writer.error))
                return
            }
            if !state.ready { return }
            do {
                let nextSample: CMSampleBuffer? = try autoreleasepool {
                    try pull()
                }
                guard let sample = nextSample else {
                    complete()
                    return
                }
                guard input.append(sample) else {
                    fail(mediaError(action, writer.error))
                    return
                }
            } catch {
                fail(error)
                return
            }
        }
    }

    private func complete() {
        input.markAsFinished()
        let cont: CheckedContinuation<Void, Error>? = lock.withLock {
            if finished { return nil }
            finished = true
            let c = completionCont
            completionCont = nil
            return c
        }
        cont?.resume()
    }

    private func fail(_ error: Error) {
        let (cont, shouldCancelWriter): (CheckedContinuation<Void, Error>?, Bool) = lock.withLock {
            if finished { return (nil, false) }
            finished = true
            storedError = error
            let c = completionCont
            completionCont = nil
            return (c, !cancelled)
        }
        if shouldCancelWriter {
            if writer.status == .writing { writer.cancelWriting() }
            onFailure()
        }
        cont?.resume(throwing: error)
    }
}

@MainActor
@discardableResult
func captureAndEncode(
    _ o: Options,
    audio: WAVRange?,
    subtitles: (CMFormatDescription, [CMSampleBuffer])?,
    into stage: Staging,
    outputURL: URL
) async throws -> String? {
    HostApp.prepare()
    let store = WKContentRuleListStore(url: stage.directory)
    let rules = """
    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]
    """
    guard let rule = try await store?.compileContentRuleList(forIdentifier: "local-only", encodedContentRuleList: rules) else {
        throw WorkerError("could not prepare WebKit's local-asset rules")
    }
    let page = try await Page(
        config: PageConfig(
            width: o.width,
            height: o.height,
            scale: 1,
            transparent: o.transparent,
            deterministicClock: true,
            video: .none,
            snapshotQuality: o.snapshotQuality
        )
    ) { wc in
        wc.websiteDataStore = .nonPersistent()
        wc.mediaTypesRequiringUserActionForPlayback = .all
        wc.userContentController.add(rule)
        wc.userContentController.addUserScript(WKUserScript(source: observeErrors, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if o.staticHoldProbe {
            wc.userContentController.addUserScript(StaticHoldProbe.userScript())
        }
    }
    defer { page.close() }
    try await page.load(.fileURL(o.input))
    try await page.waitFor(.fonts)

    var notedAudio = false
    var cachedAudioCount = 0
    func checkPage(forceScan: Bool) async throws {
        guard let tracks = try await page.evaluate(
            checkDocument,
            arguments: ["forceScan": forceScan, "cachedAudioCount": cachedAudioCount]
        ) as? Int else {
            throw WorkerError("page check did not finish")
        }
        cachedAudioCount = tracks
        if tracks > 1, o.audio != nil {
            throw WorkerError("multiple DOM audio tracks are unsupported; provide one prepared soundtrack/visual composition")
        }
        if tracks > 0, !notedAudio {
            let choice = o.audio == nil ? "silent output requested" : "using only the supplied WAV"
            FileHandle.standardError.write(Data("safarium-html: \(choice); HTML audio playback/edits are not captured\n".utf8))
            notedAudio = true
        }
    }
    try await checkPage(forceScan: true)

    // Single-pass AVAssetWriter setup
    try? FileManager.default.removeItem(at: outputURL)
    let writer = try AVAssetWriter(url: outputURL, fileType: o.codec.fileType)
    guard let rate = Int32(exactly: o.fps) else { throw WorkerError("fps must fit Int32") }
    let exactScale = AVAssetWriterSink.exactTimeScale(fps: o.fps, fallback: rate)
    writer.movieTimeScale = exactScale

    let encProfile: EncoderProfile = o.lowRam ? .lowRamClosedGOP : .baseline
    let vSettings = AVAssetWriterSink.buildVideoSettings(
        width: o.width, height: o.height, fps: o.fps,
        codec: o.codec, bitrate: o.bitrate, quality: o.quality, profile: encProfile
    )
    let vi = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
    vi.mediaTimeScale = exactScale
    vi.expectsMediaDataInRealTime = false
    let pbAttrs = AVAssetWriterSink.pixelBufferAttributes(
        width: o.width, height: o.height, pixelFormat: o.pixelFormat,
        allocationThreshold: encProfile.poolAllocationThreshold
    )
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: pbAttrs)
    guard writer.canAdd(vi) else { throw WorkerError("cannot add \(o.codec) video input") }
    writer.add(vi)

    var nv12Info = o.pixelFormat == .nv12vImage ? try AVAssetWriterSink.makeNV12Info() : nil
    var bgraScratch: [UInt8] = []
    let scratchBand = (o.pixelFormat == .nv12Left) ? AVAssetWriterSink.makeScratchBandContext(width: o.width) : nil

    var chunks: PCMChunks?
    var ai: AVAssetWriterInput?
    if let audio {
        let pcmChunks = try PCMChunks(audio)
        let aSettings = audio.aacSettings
        guard writer.canApply(outputSettings: aSettings, forMediaType: .audio) else {
            throw WorkerError("Apple's AAC encoder cannot use this WAV format")
        }
        let aInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: aSettings,
            sourceFormatHint: pcmChunks.buffer.format.formatDescription
        )
        aInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(aInput) else { throw WorkerError("cannot add AAC track") }
        writer.add(aInput)
        chunks = pcmChunks
        ai = aInput
    }

    var si: AVAssetWriterInput?
    let subSamples: [CMSampleBuffer] = subtitles?.1 ?? []
    var subIdx = 0
    if let (subFmt, _) = subtitles {
        let sInput = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: subFmt)
        sInput.mediaTimeScale = SafariumTX3G.recommendedTimeScale(for: o.duration)
        sInput.languageCode = o.subtitleLang
        sInput.extendedLanguageTag = bcp47FromISO639_2(o.subtitleLang)
        sInput.marksOutputTrackAsEnabled = true
        sInput.expectsMediaDataInRealTime = false
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            sInput.mediaDataLocation = .sparselyInterleavedWithMainMediaData
        }
        #endif
        guard writer.canAdd(sInput) else { throw WorkerError("cannot add tx3g subtitle track") }
        writer.add(sInput)
        si = sInput
    }

    guard writer.startWriting() else { throw mediaError("starting single-pass writer", writer.error) }
    writer.startSession(atSourceTime: .zero)
    let videoGate = InputReadyGate(input: vi, writer: writer)

    let audioFeeder: PullMediaFeeder? = {
        guard let audio, let chunks, let ai else { return nil }
        return PullMediaFeeder(
            label: "safarium.audio.feeder",
            action: "encoding WAV as AAC",
            input: ai,
            writer: writer,
            onFailure: { videoGate.invalidate() }
        ) {
            chunks.sent < audio.count ? try chunks.next() : nil
        }
    }()
    let subFeeder: PullMediaFeeder? = {
        guard let si else { return nil }
        return PullMediaFeeder(
            label: "safarium.subtitle.feeder",
            action: "appending tx3g subtitle",
            input: si,
            writer: writer,
            onFailure: { videoGate.invalidate() }
        ) {
            guard subIdx < subSamples.count else { return nil }
            let s = subSamples[subIdx]
            subIdx += 1
            return s
        }
    }()

    var finished = false
    defer {
        audioFeeder?.cancel()
        subFeeder?.cancel()
        videoGate.invalidate()
        if !finished && writer.status == .writing { writer.cancelWriting() }
    }

    audioFeeder?.start()
    subFeeder?.start()

    func checkFeederErrors() throws {
        try audioFeeder?.checkError()
        try subFeeder?.checkError()
    }

    let frameDuration = CMTime(value: 1, timescale: rate)
    var cachedHoldPB: CVPixelBuffer? = nil
    var lastFrameDigest: String? = nil
    var rollingHasher: SHA256? = o.hashFrames ? SHA256() : nil
    let progress = SafariumProgressEmitter(enabled: o.progressJSONL)
    progress.emitStart(stage: "html_render", total: o.frames)
    for index in 0..<o.frames {
        do {
            try checkFeederErrors()
            // Backpressure BEFORE seeking/snapshotting so VideoToolbox paces WebKit without inflating IOSurfaces.
            try await videoGate.waitUntilReady()
            try checkFeederErrors()

            if o.staticHoldProbe, index > 0, cachedHoldPB != nil {
                _ = try await page.evaluate(expression: "window.__sfDirtyProbe && window.__sfDirtyProbe.beginStep()")
            }
            try await page.seek(o.pageTime(index))

            if o.staticHoldProbe, index > 0, let holdBuf = cachedHoldPB {
                let probeObj = try await page.evaluate(
                    expression: "window.__sfDirtyProbe ? window.__sfDirtyProbe.consumeStep() : {dirty: true}"
                ) as? [String: Any]
                let isDirty = (probeObj?["dirty"] as? Bool) ?? true
                if !isDirty {
                    let pts = CMTime(value: Int64(index), timescale: rate)
                    try autoreleasepool {
                        guard adaptor.append(holdBuf, withPresentationTime: pts) else {
                            throw mediaError("appending held frame \(index)", writer.error)
                        }
                    }
                    if o.hashFrames, let d = lastFrameDigest {
                        rollingHasher?.update(data: Data(d.utf8))
                    }
                    progress.emitFrame(stage: "html_render", completed: index + 1, total: o.frames)
                    continue
                }
            }

            try await checkPage(forceScan: false)
            let frame = try await page.snapshot()
            guard frame.width == o.width, frame.height == o.height else {
                throw WorkerError("unexpected snapshot dimensions")
            }
            if o.hashFrames {
                let rawBGRA = try frame.checkedBGRA()
                let fh = SHA256.hash(data: rawBGRA).map { String(format: "%02x", $0) }.joined()
                lastFrameDigest = fh
                rollingHasher?.update(data: Data(fh.utf8))
            }
            try checkFeederErrors()
            let buf: CVPixelBuffer
            if o.staticHoldProbe {
                buf = try AVAssetWriterSink.allocateStandalonePixelBuffer(
                    width: o.width, height: o.height, pixelFormat: o.pixelFormat
                )
            } else {
                guard let pool = adaptor.pixelBufferPool else { throw WorkerError("missing pixel buffer pool") }
                buf = try await AVAssetWriterSink.allocatePoolBuffer(
                    from: pool,
                    allocationThreshold: encProfile.poolAllocationThreshold,
                    waitReady: { try await videoGate.waitUntilReady() }
                )
            }
            try autoreleasepool {
                switch o.pixelFormat {
                case .nv12vImage:
                    guard var info = nv12Info else { throw WorkerError("missing NV12 converter") }
                    try AVAssetWriterSink.writeNV12(
                        frame, into: buf, width: o.width, height: o.height, info: &info, bgraScratch: &bgraScratch
                    )
                    nv12Info = info
                case .nv12Left:
                    try SafariumAccelerate.convertBGRAToNV12BT709LeftBanded(
                        snapshot: frame, scratchBand: scratchBand, into: buf, width: o.width, height: o.height
                    )
                case .bgra:
                    try frame.draw(into: buf, width: o.width, height: o.height)
                }
                let pts = CMTime(value: Int64(index), timescale: rate)
                let appended: Bool
                if index == 0 {
                    let timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
                    let sample = try CMSampleBuffer(
                        imageBuffer: buf,
                        formatDescription: CMVideoFormatDescription(imageBuffer: buf),
                        sampleTiming: timing
                    )
                    appended = vi.append(sample)
                } else {
                    appended = adaptor.append(buf, withPresentationTime: pts)
                }
                guard appended else { throw mediaError("appending frame \(index)", writer.error) }
                if o.staticHoldProbe {
                    cachedHoldPB = buf
                }
            }
            progress.emitFrame(stage: "html_render", completed: index + 1, total: o.frames)
        } catch let se as SafariumError {
            switch se {
            case .timeout(let m): throw SafariumError.timeout("frame \(index) (PTS \(index)/\(o.fps)): \(m)")
            case .javascript(let m): throw SafariumError.javascript("frame \(index) (PTS \(index)/\(o.fps)): \(m)")
            case .navigation(let m): throw SafariumError.navigation("frame \(index) (PTS \(index)/\(o.fps)): \(m)")
            case .snapshot(let m): throw SafariumError.snapshot("frame \(index) (PTS \(index)/\(o.fps)): \(m)")
            case .encode(let m): throw SafariumError.encode("frame \(index) (PTS \(index)/\(o.fps)): \(m)")
            case .invalidState(let m): throw SafariumError.invalidState("frame \(index) (PTS \(index)/\(o.fps)): \(m)")
            }
        } catch {
            throw WorkerError("frame \(index) (PTS \(index)/\(o.fps)): \(error)")
        }
    }
    vi.markAsFinished()
    try await audioFeeder?.waitFinished()
    try await subFeeder?.waitFinished()
    try checkFeederErrors()

    writer.endSession(atSourceTime: o.duration)
    await writer.finishWriting()
    guard writer.status == .completed else { throw mediaError("finishing single-pass movie", writer.error) }
    finished = true
    progress.emitComplete(stage: "html_render", total: o.frames)
    if let rollingHasher {
        return rollingHasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
    return nil
}
