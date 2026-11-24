import AppKit
import AVFoundation
import CoreImage
import WebKit

/// How `<video>` elements are rendered while the virtual clock is driven (WKWebView's takeSnapshot never contains the video layer).
public enum VideoMode: Equatable, Sendable {
    /// Videos are left alone (default; they render blank in snapshots).
    case none
    /// The page's own `<video>` decodes. Needs the WKWebView inside an NSWindow (media does not load otherwise), so the Page
    /// owns a borderless window far off-screen that is never ordered front, never key, never activates the (`.prohibited`) app.
    /// Each seek sets `currentTime` to the centre of the target frame, waits for `seeked` (real-time deadline) and copies the frame
    /// into an overlay `<canvas>`. Frame accuracy depends on WebKit's decoder: H.264 measured exact, HEVC can show stale frames.
    case element
    /// Frame extraction (the HyperFrames `hf-seek-video` idea, native): the frame is decoded outside the page with
    /// AVAssetImageGenerator (zero tolerance) and painted as an image into the overlay `<canvas>`. Frame-exact for every codec
    /// AVFoundation reads, needs no window, local file sources only (`file:` URLs).
    case extract
}

/// Native side of the video hook: `window.webkit.messageHandlers.sfVideo.postMessage({op, src, t})` (async, with reply).
@MainActor
final class VideoBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "sfVideo"

    private struct Source {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let generator: AVAssetImageGenerator
        let fps: Double
        let frameCount: Int
        /// Presentation time of the first frame (not always 0: some encoders leave a half-frame offset).
        let t0: Double
        func time(ofFrame k: Int) -> Double { t0 + Double(k) / fps }
    }
    private struct SeqState {
        let reader: SafariumSequentialVideoReader
        var lastK: Int = -1
    }
    private var sources: [String: Source] = [:]
    private var seqStates: [String: SeqState] = [:]
    private var lastFrame: (key: String, url: String)?

    private func source(for src: String) async throws -> Source {
        if let s = sources[src] { return s }
        guard let url = URL(string: src), url.isFileURL else {
            throw SafariumError.invalidState("video source must be a file: URL, got \(src)")
        }
        var st = stat()
        guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw SafariumError.invalidState("video file not readable: \(url.path)")
        }
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        ])
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SafariumError.invalidState("no video track in \(url.lastPathComponent)")
        }
        let (nominal, range) = try await track.load(.nominalFrameRate, .timeRange)
        let fps = Self.snapFPS(nominal > 0 ? Double(nominal) : 30)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.appliesPreferredTrackTransform = true
        let count = max(1, Int(((range.duration.seconds - 0) * fps).rounded()))
        let t0 = try await Self.firstFrameTime(asset, track)
        let s = Source(asset: asset, track: track, generator: gen, fps: fps, frameCount: count, t0: t0)
        sources[src] = s
        return s
    }

    /// PTS of the first sample in presentation order (reads the first output frame).
    nonisolated static func firstFrameTime(_ asset: AVURLAsset, _ track: AVAssetTrack) async throws -> Double {
        try await Task.detached {
            let r = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            guard r.canAdd(out) else { return 0 }
            r.add(out)
            guard r.startReading() else { return 0 }
            defer { r.cancelReading() }
            while let sb = out.copyNextSampleBuffer() {
                if CMSampleBufferGetImageBuffer(sb) != nil { return max(0, CMSampleBufferGetPresentationTimeStamp(sb).seconds) }
            }
            return 0
        }.value
    }

    /// Frame `k` via a sequential decode that starts a few frames *before* it, so the decoder begins at a sync sample earlier than
    /// the frame's GOP and open-GOP leading pictures are decoded rather than dropped.
    nonisolated private static func readFrame(_ s: Source, _ k: Int) async throws -> CGImage {
        try await Task.detached {
            let back = 16.0 / s.fps
            let start = max(0, s.time(ofFrame: k) - back)
            let end = s.time(ofFrame: k) + 1.0 / s.fps
            let r = try AVAssetReader(asset: s.asset)
            r.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600_000),
                                      end: CMTime(seconds: end, preferredTimescale: 600_000))
            let out = AVAssetReaderTrackOutput(track: s.track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            guard r.canAdd(out) else { throw SafariumError.snapshot("cannot read video frame \(k)") }
            r.add(out)
            guard r.startReading() else { throw SafariumError.snapshot("reader failed for frame \(k): \(r.error?.localizedDescription ?? "?")") }
            defer { r.cancelReading() }
            let target = s.time(ofFrame: k)
            var best: (dist: Double, pb: CVPixelBuffer)?
            while let sb = out.copyNextSampleBuffer() {
                guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
                let d = abs(CMSampleBufferGetPresentationTimeStamp(sb).seconds - target)
                if best == nil || d < best!.dist { best = (d, pb) }
            }
            guard let hit = best, hit.dist < 0.5 / s.fps else { throw SafariumError.snapshot("video frame \(k) not decodable (reader found no frame at \(target) s)") }
            let ci = CIImage(cvPixelBuffer: hit.pb)
            guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { throw SafariumError.snapshot("CGImage from frame \(k) failed") }
            return cg
        }.value
    }

    nonisolated private static func readSequentialCGImage(
        _ reader: SafariumSequentialVideoReader, at targetT: Double
    ) async throws -> CGImage? {
        try await Task.detached(priority: .userInitiated) {
            guard let pb = try reader.pixelBuffer(at: targetT) else { return nil }
            let ci = CIImage(cvPixelBuffer: pb)
            let ctx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])
            defer { SafariumMetalContext.shared?.flushTextureCache() }
            return ctx.createCGImage(ci, from: ci.extent, format: .BGRA8, colorSpace: Snapshot.colorSpace)
        }.value
    }

    /// `nominalFrameRate` is a Float (29.999998 for "30"): snap to integer and NTSC rates so n/fps maps to frame n.
    static func snapFPS(_ f: Double) -> Double {
        for ntsc in [24000.0 / 1001, 30000.0 / 1001, 60000.0 / 1001] where abs(f - ntsc) < 0.005 { return ntsc }
        return abs(f - f.rounded()) < 0.01 ? f.rounded() : f
    }

    nonisolated func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage,
                                           replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        let body = message.body as? [String: Any]
        Task { @MainActor in
            do { replyHandler(try await self.handle(body ?? [:]), nil) }
            catch { replyHandler(nil, "video: \(error)") }
        }
    }

    private func handle(_ m: [String: Any]) async throws -> [String: Any] {
        guard let src = m["src"] as? String else { throw SafariumError.invalidState("video message without src") }
        let s = try await source(for: src)
        let t = (m["t"] as? NSNumber)?.doubleValue ?? 0
        let k = min(max(0, Int((t * s.fps + 1e-3).rounded(.down))), s.frameCount - 1)
        var out: [String: Any] = ["fps": s.fps, "frames": s.frameCount, "k": k, "t0": s.t0]
        if (m["op"] as? String) == "frame" {
            let key = "\(src)#\(k)"
            if let last = lastFrame, last.key == key { out["url"] = last.url; return out }

            // Sequential forward fast-path via SafariumSequentialVideoReader when orientation is identity
            // and the requested frame advances monotonically (or restarts cleanly near frame 0).
            var cgOpt: CGImage?
            if seqStates[src] == nil, let url = URL(string: src), url.isFileURL {
                if let reader = try? await SafariumSequentialVideoReader(url: url, loop: false, startTimeOffset: 0, pixelFormat: kCVPixelFormatType_32BGRA),
                   reader.preferredTransform.isIdentity {
                    seqStates[src] = SeqState(reader: reader, lastK: -1)
                }
            }
            if var st = seqStates[src] {
                let sequentialHit = (st.lastK >= 0 && k >= st.lastK && k - st.lastK <= 16) || (k <= 4)
                if sequentialHit {
                    let targetT = s.time(ofFrame: k) + 0.5 / s.fps
                    if let cg = try? await Self.readSequentialCGImage(st.reader, at: targetT) {
                        st.lastK = k
                        seqStates[src] = st
                        cgOpt = cg
                    }
                } else {
                    st.lastK = -1
                    seqStates[src] = st
                }
            }

            // Fallback / random-access path: AVAssetImageGenerator zero-tolerance or open-GOP AVAssetReader.
            let cg: CGImage
            if let fastCG = cgOpt {
                cg = fastCG
            } else {
                do { (cg, _) = try await s.generator.image(at: CMTime(seconds: s.time(ofFrame: k) + 0.5 / s.fps, preferredTimescale: 600_000)) }
                catch {
                    // AVAssetImageGenerator cannot decode some frames after a random access (open-GOP HEVC: the RASL leading pictures
                    // before a CRA, "Cannot Decode -11821"). Decode forward from the previous GOP with AVAssetReader instead.
                    cg = try await Self.readFrame(s, k)
                }
            }
            let png = Snapshot(cgImage: cg).pngData()
            guard !png.isEmpty else { throw SafariumError.snapshot("PNG encode of video frame \(k) failed") }
            let url = "data:image/png;base64," + png.base64EncodedString()
            lastFrame = (key, url)
            out["url"] = url; out["w"] = cg.width; out["h"] = cg.height
        }
        return out
    }
}

/// Off-screen borderless window that gives a WKWebView the "in a window" state media loading requires.
@MainActor
final class HiddenWindow {
    let window: NSWindow
    init(webView: WKWebView) {
        let size = webView.frame.size
        window = NSWindow(contentRect: NSRect(x: -20000 - size.width, y: -20000 - size.height, width: size.width, height: size.height),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.canHide = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .transient]
        window.contentView = webView
        window.orderBack(nil)           // never orderFront / makeKey: the app is .prohibited and must never take focus
    }
    func detach() {
        window.orderOut(nil)
        window.contentView = nil
    }
}
