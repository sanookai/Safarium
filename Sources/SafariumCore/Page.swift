import AppKit
import WebKit

public enum PageSource {
    case url(URL)
    /// Local file; subresources readable under `readAccess` (default: file's folder).
    case fileURL(URL, readAccess: URL? = nil)
    /// HTML string, decoded as UTF-8 unless `encoding` says otherwise.
    case html(String, baseURL: URL? = nil)
}

public enum WaitCondition {
    case readyState                 // document.readyState === 'complete'
    case fonts                      // document.fonts.ready
    case images                     // every <img> complete
    case selector(String)
    case predicate(String)          // JS expression, polled until truthy
}

/// Snapshot rendering quality (see `PageConfig.snapshotQuality`).
public enum SnapshotQuality: Equatable, Sendable {
    /// Default: WebKit rasterises directly at the output size.
    case fast
    /// Rasterise at 2x the output size, then Lanczos-downscale (Core Image) to the exact output size: smoother edges on thin
    /// lines and small text, ~4x the pixels per snapshot.
    case sharp
}

public struct PageConfig {
    public var width: Int
    public var height: Int
    /// Device scale factor: output pixels = width*scale × height*scale.
    public var scale: Double
    /// drawsBackground = false → alpha channel preserved in snapshots.
    public var transparent: Bool
    /// Installs VirtualClock (clock.js) at document start; required for `seek`.
    public var deterministicClock: Bool
    /// How `<video>` elements are handled while seeking (see `VideoMode`); needs `deterministicClock`.
    public var video: VideoMode
    /// `.fast` (default) or `.sharp` (2x supersample + Lanczos). Output size is identical.
    public var snapshotQuality: SnapshotQuality
    public init(width: Int, height: Int, scale: Double = 1, transparent: Bool = false, deterministicClock: Bool = false,
                video: VideoMode = .none, snapshotQuality: SnapshotQuality = .fast) {
        self.width = width; self.height = height; self.scale = scale
        self.transparent = transparent; self.deterministicClock = deterministicClock
        self.video = video; self.snapshotQuality = snapshotQuality
    }
}

/// An offscreen WKWebView (no NSWindow, never activates the app). 1 Page = 1 WKWebView.
@MainActor
public final class Page {
    public private(set) var config: PageConfig
    public let webView: WKWebView
    private let nav = NavigationDelegate()
    private var hiddenWindow: HiddenWindow?
    private var backingScale: Double?          // calibrated: snapshot pixels per snapshotWidth point
    private var isClosed = false
    private let hasVideoBridge: Bool

    public init(config: PageConfig, configureWebView: ((WKWebViewConfiguration) -> Void)? = nil) async throws {
        HostApp.prepare()
        self.config = config
        self.hasVideoBridge = config.video != .none
        let wc = WKWebViewConfiguration()
        if config.deterministicClock { wc.userContentController.addUserScript(VirtualClock.userScript(video: config.video)) }
        if config.video == .element {
            // The off-screen window is occluded, i.e. the page is "inactive": WebKit would throttle/suspend it and the <video> stops
            // presenting new frames after a few seconds of seeking (measured: frame frozen after ~235 seeks).
            wc.preferences.inactiveSchedulingPolicy = .none
            wc.mediaTypesRequiringUserActionForPlayback = []
        }
        if config.video != .none {
            guard config.deterministicClock else { throw SafariumError.invalidState("PageConfig.video requires deterministicClock = true") }
            wc.userContentController.addScriptMessageHandler(VideoBridge(), contentWorld: .page, name: VideoBridge.name)
        }
        // WebKit accepts custom URL scheme handlers only before WKWebView is constructed.
        configureWebView?(wc)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: config.width, height: config.height), configuration: wc)
        if config.transparent { webView.setValue(false, forKey: "drawsBackground") }
        webView.navigationDelegate = nav
        if config.video == .element { hiddenWindow = HiddenWindow(webView: webView) }
    }

    deinit {
        let hw = hiddenWindow
        let wv = webView
        let removeBridge = hasVideoBridge
        Task { @MainActor in
            hw?.detach()
            Page.tearDownWebView(wv, removeVideoBridge: removeBridge)
        }
    }

    /// Releases the hidden window (`.element` video mode). Safe to call more than once; other modes: no-op.
    public func close() {
        hiddenWindow?.detach(); hiddenWindow = nil
        guard !isClosed else { return }
        isClosed = true
        Page.tearDownWebView(webView, removeVideoBridge: config.video != .none)
    }

    private static func tearDownWebView(_ wv: WKWebView, removeVideoBridge: Bool) {
        wv.stopLoading()
        wv.navigationDelegate = nil
        if removeVideoBridge {
            wv.configuration.userContentController.removeScriptMessageHandler(forName: VideoBridge.name, contentWorld: .page)
        }
    }

    // MARK: load

    @discardableResult
    private func startNavigation(_ source: PageSource) -> WKNavigation? {
        nav.didCommit = false
        switch source {
        case .url(let u): return webView.load(URLRequest(url: u))
        case .fileURL(let f, let access):
            let root = access ?? f.deletingLastPathComponent()
            if Page.needsCharsetOverride(f), let data = try? Data(contentsOf: f) {
                // No charset declared: WebKit would guess Latin-1 and garble Thai. Force UTF-8.
                return webView.load(data, mimeType: "text/html", characterEncodingName: "utf-8", baseURL: f)
            } else { return webView.loadFileURL(f, allowingReadAccessTo: root) }
        case .html(let s, let base):
            return webView.load(Data(s.utf8), mimeType: "text/html", characterEncodingName: "utf-8",
                                baseURL: base ?? URL(string: "about:blank")!)
        }
    }

    private func nudgeElementVideosAndMaybeFinish() async {
        let readyStateComplete = (try? await webView.callAsyncJavaScript("""
            for (const v of document.querySelectorAll('video')) {
                if (v.readyState < 2 && typeof v.load === 'function') { v.load(); }
            }
            return document.readyState === 'complete';
            """, arguments: [:], in: nil, contentWorld: .page)) as? Bool ?? false
        if readyStateComplete && nav.pending != nil {
            let elapsed = await sleepWithoutThrowing(nanoseconds: 250_000_000)
            if elapsed && !Task.isCancelled && nav.pending != nil {
                nav.finishExternalSuccess()
            }
        }
    }

    public func load(_ source: PageSource, timeout: TimeInterval = 30) async throws {
        nav.didCommit = false
        nav.currentNavigation = nil
        nav.ignoredNavigations.removeAll()
        let deadline = Date().addingTimeInterval(timeout)
        let watchdog = Task { @MainActor [weak self] in
            _ = await sleepWithoutThrowing(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self, self.nav.pending != nil else { return }
            if self.nav.didCommit {
                if self.config.video == .element && deadline.timeIntervalSinceNow >= 6 {
                    await self.nudgeElementVideosAndMaybeFinish()
                }
                return
            }
            _ = await sleepWithoutThrowing(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled, self.nav.pending != nil, !self.nav.didCommit else {
                if !Task.isCancelled, self.nav.pending != nil, self.nav.didCommit,
                   self.config.video == .element && deadline.timeIntervalSinceNow >= 6 {
                    await self.nudgeElementVideosAndMaybeFinish()
                }
                return
            }
            guard deadline.timeIntervalSinceNow >= 8 else { return }
            if let stale = self.nav.currentNavigation {
                self.nav.ignoredNavigations.insert(ObjectIdentifier(stale))
            }
            self.webView.stopLoading()
            self.nav.currentNavigation = self.startNavigation(source)
            _ = await sleepWithoutThrowing(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, self.nav.pending != nil, self.nav.didCommit else { return }
            if self.config.video == .element && deadline.timeIntervalSinceNow >= 4 {
                await self.nudgeElementVideosAndMaybeFinish()
            }
        }
        defer { watchdog.cancel() }
        do {
            try await withTimeout(timeout, what: "load") { [self] in
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                    nav.pending = c
                    nav.currentNavigation = startNavigation(source)
                }
            }
        } catch {
            webView.stopLoading()
            nav.cancelPending()
            throw error
        }
        try await flushDueTimers()
    }

    /// Runs timers due at virtual time 0 (e.g. `setTimeout(fn, 0)` bootstraps) so the page is settled after `load`.
    private func flushDueTimers() async throws {
        guard config.deterministicClock else { return }
        try await evaluate("if (window.__sfClock) window.__sfClock.flush(); return true", timeout: 10)
    }

    static func needsCharsetOverride(_ file: URL) -> Bool {
        guard ["html", "htm"].contains(file.pathExtension.lowercased()),
              let data = try? Data(contentsOf: file) else { return false }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return false }                 // UTF-8 BOM
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        return !head.contains("charset")
    }

    // MARK: evaluate

    /// Runs `body` as an async function body (use `return`), with `arguments` as named variables.
    @discardableResult
    public func evaluate(_ body: String, arguments: [String: Any] = [:], timeout: TimeInterval = 30) async throws -> Any? {
        let wv = self.webView
        return try await withTimeout(timeout, what: "evaluate") {
            do { return try await wv.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page) }
            catch { throw Page.mapJSError(error) }
        }
    }

    /// Evaluates a JS expression (awaited if it is a Promise).
    @discardableResult
    public func evaluate(expression: String, timeout: TimeInterval = 30) async throws -> Any? {
        try await evaluate("return await (\(expression))", timeout: timeout)
    }

    static func mapJSError(_ e: Error) -> SafariumError {
        let ns = e as NSError
        if let m = ns.userInfo["WKJavaScriptExceptionMessage"] as? String { return .javascript(m) }
        return .javascript(ns.localizedDescription)
    }

    // MARK: waiting

    public func waitFor(_ cond: WaitCondition, timeout: TimeInterval = 30, pollInterval: TimeInterval = 0.02) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        switch cond {
        case .fonts:
            try await evaluate("await document.fonts.ready; return true", timeout: timeout)
        case .readyState:
            try await poll("document.readyState === 'complete'", deadline, pollInterval, "readyState")
        case .images:
            try await poll("Array.from(document.images).every(i => i.complete)", deadline, pollInterval, "images")
        case .selector(let s):
            try await poll("!!document.querySelector(\(Page.jsString(s)))", deadline, pollInterval, "selector \(s)")
        case .predicate(let js):
            try await poll("!!(\(js))", deadline, pollInterval, "predicate \(js)")
        }
    }

    private func poll(_ expr: String, _ deadline: Date, _ interval: TimeInterval, _ what: String) async throws {
        while true {
            if let ok = try await evaluate("return \(expr)") as? Bool, ok { return }
            if Date() >= deadline { throw SafariumError.timeout("waitFor \(what)") }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        let arr = String(decoding: data, as: UTF8.self)
        return String(arr.dropFirst().dropLast())
    }

    // MARK: viewport

    public func setViewport(width: Int, height: Int, scale: Double? = nil) {
        config.width = width; config.height = height
        if let s = scale { config.scale = s }
        webView.frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    // MARK: clock

    /// Advances the virtual clock to `t` seconds and resolves once timers, rAF, animations and page hooks have run.
    /// `step` (seconds) steps through intermediate frames, needed by libraries with lag smoothing (GSAP).
    public func seek(_ t: Double, step: Double? = nil) async throws {
        guard config.deterministicClock else {
            throw SafariumError.invalidState("seek requires PageConfig.deterministicClock = true")
        }
        let r = try await evaluate("""
            if (!window.__sfClock) return false;
            await window.__sfClock.seek(t, step); return true
            """, arguments: ["t": t, "step": step ?? 0])
        if (r as? Bool) != true { throw SafariumError.invalidState("virtual clock not installed in this document") }
    }

    // MARK: snapshot

    /// Captures the viewport (or `clip`, in CSS px) at exactly (w*scale)×(h*scale) pixels.
    public func snapshot(clip: CGRect? = nil) async throws -> Snapshot {
        let rect = clip ?? CGRect(x: 0, y: 0, width: config.width, height: config.height)
        let outW = Int((rect.width * config.scale).rounded()), outH = Int((rect.height * config.scale).rounded())
        switch config.snapshotQuality {
        case .fast:
            return Snapshot(cgImage: try await capture(rect, pixelWidth: outW, outW: outW, outH: outH))
        case .sharp:
            // Rasterise at 2x, then a high-quality Lanczos downscale to exactly the requested size.
            let big = try await capture(rect, pixelWidth: outW * 2, outW: outW * 2, outH: outH * 2)
            guard let small = Snapshot.lanczosDownscale(big, width: outW, height: outH) else {
                throw SafariumError.snapshot("Lanczos downscale to \(outW)x\(outH) failed")
            }
            return Snapshot(cgImage: small)
        }
    }

    /// One WKWebView snapshot of `rect` (CSS px) that is exactly `outW`×`outH` pixels, `pixelWidth` wide as rasterised.
    private func capture(_ rect: CGRect, pixelWidth: Int, outW: Int, outH: Int) async throws -> CGImage {
        for attempt in 0..<2 {
            let backing = backingScale ?? (NSScreen.main?.backingScaleFactor ?? 2)
            let cfgWidth = Double(pixelWidth) / backing
            let cg = try await withTimeout(30, what: "snapshot") { [self] in
                let c = WKSnapshotConfiguration()
                c.rect = rect
                c.snapshotWidth = NSNumber(value: cfgWidth)
                c.afterScreenUpdates = true
                let image: NSImage
                do { image = try await self.webView.takeSnapshot(configuration: c) }
                catch { throw SafariumError.snapshot(error.localizedDescription) }
                guard let raw = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    throw SafariumError.snapshot("no CGImage")
                }
                return raw
            }
            if cg.width != pixelWidth && attempt == 0 {
                backingScale = Double(cg.width) / (Double(pixelWidth) / backing)   // recalibrate, retry once
                continue
            }
            backingScale = backing
            guard let exact = Snapshot.normalized(cg, width: outW, height: outH) else {
                throw SafariumError.snapshot("resize to \(outW)x\(outH) failed")
            }
            return exact
        }
        throw SafariumError.snapshot("unreachable")
    }
}

// MARK: - navigation delegate

private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    var pending: CheckedContinuation<Void, Error>?
    var didCommit = false
    var currentNavigation: WKNavigation?
    var ignoredNavigations: Set<ObjectIdentifier> = []

    private func shouldHandle(_ navigation: WKNavigation?) -> Bool {
        if let n = navigation, ignoredNavigations.contains(ObjectIdentifier(n)) { return false }
        guard let cur = currentNavigation, let n = navigation else { return true }
        return n === cur
    }

    private func finish(_ e: Error?) {
        guard let c = pending else { return }
        pending = nil
        currentNavigation = nil
        if let e = e { c.resume(throwing: SafariumError.navigation(e.localizedDescription)) } else { c.resume() }
    }

    func cancelPending() {
        guard let c = pending else { return }
        pending = nil
        currentNavigation = nil
        c.resume(throwing: CancellationError())
    }

    func finishExternalSuccess() {
        finish(nil)
    }

    func webView(_ w: WKWebView, didCommit n: WKNavigation!) {
        guard shouldHandle(n) else { return }
        didCommit = true
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        guard shouldHandle(n) else { return }
        finish(nil)
    }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        guard shouldHandle(n) else { return }
        finish(e)
    }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        guard shouldHandle(n) else { return }
        finish(e)
    }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
        finish(SafariumError.navigation("WebContent process terminated"))
    }
}

// MARK: - timeout helper

/// Resumes its continuation exactly once; later results (e.g. a JS promise that settles after the deadline) are dropped.
@MainActor
private final class OnceResolver<T>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private var tasks: [Task<Void, Never>] = []
    func attach(_ c: CheckedContinuation<T, Error>) { continuation = c }
    func track(_ t: Task<Void, Never>) { tasks.append(t) }
    func resolve(_ r: Result<T, Error>) {
        guard let c = continuation else { return }
        continuation = nil
        tasks.forEach { $0.cancel() }; tasks = []
        c.resume(with: r)
    }
}

/// Races `op` against a real-time deadline with a continuation, not a task group: a task group would wait for the
/// loser (a `callAsyncJavaScript` that never settles cannot be cancelled), so the timeout would never return.
/// On timeout (or caller cancellation) `op`'s task is cancelled and abandoned; whatever it produces later is ignored.
@MainActor
func withTimeout<T>(_ seconds: TimeInterval, what: String, _ op: @escaping @MainActor () async throws -> T) async throws -> T {
    let once = OnceResolver<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            once.attach(c)
            once.track(Task { @MainActor in
                do { once.resolve(.success(try await op())) } catch { once.resolve(.failure(error)) }
            })
            once.track(Task { @MainActor in
                guard await sleepWithoutThrowing(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) else { return }
                once.resolve(.failure(SafariumError.timeout(what)))
            })
        }
    } onCancel: {
        Task { @MainActor in once.resolve(.failure(CancellationError())) }
    }
}

// MARK: - non-throwing sleep

/// One-shot state shared by `sleepWithoutThrowing`'s timer and its cancellation handler.
private final class SleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var outcome: Bool?
    private var timer: DispatchWorkItem?

    func install(_ c: CheckedContinuation<Bool, Never>, timer: DispatchWorkItem) {
        lock.lock()
        if let done = outcome { lock.unlock(); c.resume(returning: done); return }
        continuation = c; self.timer = timer
        lock.unlock()
    }
    func finish(_ elapsed: Bool) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = elapsed
        let c = continuation, t = timer
        continuation = nil; timer = nil
        lock.unlock()
        if !elapsed { t?.cancel() }
        c?.resume(returning: elapsed)
    }
}

/// Sleeps like `Task.sleep` but reports cancellation as `false` instead of throwing `CancellationError`.
/// Why: a helper task that is cancelled on purpose (the navigation watchdog, the timeout timer) must not throw at all.
/// Even a swallowed `try?` throw is recorded by XCTest's willThrow hook, which then reports that stale
/// `CancellationError` in place of the real error the caller propagates. Returns `true` when the time elapsed.
func sleepWithoutThrowing(nanoseconds: UInt64) async -> Bool {
    let gate = SleepGate()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let item = DispatchWorkItem { gate.finish(true) }
            gate.install(c, timer: item)
            DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(min(nanoseconds, UInt64(Int.max)))), execute: item)
        }
    } onCancel: { gate.finish(false) }
}
