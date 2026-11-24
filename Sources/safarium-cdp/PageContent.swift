import AppKit
import Foundation
import SafariumCore
import WebKit

struct ExecContext {
    let id: Int
    let worldName: String?        // nil = the page's main world
    let uniqueId = newHexId()
}

private struct InjectedScript {
    let id: String
    let source: String
    let worldName: String?
}

/// One CDP "page" target backed by a SafariumCore `Page` (offscreen WKWebView).
@MainActor final class PageContent {
    unowned let target: Target
    unowned let server: Server
    let page: Page
    var webView: WKWebView { page.webView }
    let fetch: FetchDomain
    var fetchLoader: String { explicitLoader ?? loaderId }
    private let nav = NavDelegate()
    private let scriptHandler = ScriptHandler()

    private(set) var url = "about:blank"
    private(set) var title = "about:blank"
    private var loaderId = newHexId()
    private var reached: [String] = []
    private var loading = false
    private var silent = true
    private var blankWait: CheckedContinuation<Void, Never>?
    private var pendingNav: (loader: String, cont: CheckedContinuation<JSON, Error>)?
    private var navigation: WKNavigation?
    private var explicitLoader: String?
    private var lastResponse: (status: Int, mime: String, headers: [String: String])?
    private var simulatedResponse: URLResponse?
    private var dcl = false, loadFired = false

    private var dsf = 1.0
    private var viewportSize: (w: Int, h: Int)
    private var contexts: [Int: ExecContext] = [:]
    private var nextContextId = 1
    private var worldNames: [String] = []
    private var scripts: [InjectedScript] = []
    private var nextScriptId = 1
    private var bindings: [(name: String, world: String?)] = []

    var frameId: String { target.id }

    // MARK: creation

    static func create(target: Target, server: Server) async throws -> PageContent {
        let size = (server.options.width, server.options.height)
        let fetch = FetchDomain()
        let page = try await Page(config: PageConfig(width: size.0, height: size.1, scale: 1)) { config in
            config.websiteDataStore = .nonPersistent()
            config.setURLSchemeHandler(fetch, forURLScheme: FetchScope.scheme)
        }
        let c = PageContent(target: target, server: server, page: page, size: size, fetch: fetch)
        fetch.owner = c
        c.install()
        await withTaskCancellationHandler(operation: { if !Task.isCancelled { await c.loadBlank() } },
                                         onCancel: { Task { @MainActor in c.dispose() } })
        try Task.checkCancellation()
        return c
    }

    private init(target: Target, server: Server, page: Page, size: (Int, Int), fetch: FetchDomain) {
        self.target = target; self.server = server; self.page = page; self.viewportSize = (size.0, size.1)
        self.fetch = fetch
    }

    private func install() {
        nav.owner = self
        scriptHandler.owner = self
        webView.navigationDelegate = nav
        webView.configuration.userContentController.add(scriptHandler, contentWorld: .page, name: "sfEvents")
        rebuildScripts()
    }

    func dispose() {
        fetch.close()
        webView.navigationDelegate = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeAllUserScripts()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        if let c = blankWait { blankWait = nil; c.resume() }
        pendingNav?.cont.resume(throwing: CDPError.server("Target closed"))
        pendingNav = nil
    }

    private func loadBlank() async {
        silent = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            blankWait = c
            webView.load(URLRequest(url: URL(string: "about:blank")!))
        }
        silent = false
        reached = ["commit", "DOMContentLoaded", "load", "networkAlmostIdle", "networkIdle"]
        dcl = true; loadFired = true; loading = false
    }

    // MARK: scripts / worlds

    /// Every CDP execution context, named worlds included, runs in WebKit's page world. puppeteer hands objects of the
    /// main world to code in its "utility world" (callFunctionOn arguments, DOM.resolveNode); WKContentWorlds cannot share
    /// objects, so real isolation would break `$eval`, `waitForSelector` and friends. Context ids/names stay distinct.
    private func world(_ name: String?) -> WKContentWorld { .page }

    private func rebuildScripts() {
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        if let source = fetch.routingScript {
            ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
        ucc.addUserScript(WKUserScript(source: JSRuntime.boot, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        for b in bindings {
            ucc.addUserScript(WKUserScript(source: JSRuntime.bindingScript(name: b.name), injectionTime: .atDocumentStart,
                                           forMainFrameOnly: false, in: world(b.world)))
        }
        for s in scripts {
            ucc.addUserScript(WKUserScript(source: s.source, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world(s.worldName)))
        }
    }

    func refreshFetchScripts() async throws {
        rebuildScripts()
        if let scope = fetch.scope, scope.grants(webView.url) {
            // Also update (or deactivate) routing in the currently committed page.
            let source = fetch.routingScript ?? FetchRouting.script(scope: scope, patterns: [])
            _ = try await webView.evaluateJavaScript(source)
        }
    }

    func fetchHasCSP() async throws -> Bool {
        if let policy = lastResponse?.headers.first(where: { $0.key.lowercased() == "content-security-policy" })?.value,
           !FetchRouting.safeCSP(policy) { return true }
        return try await webView.callAsyncJavaScript("return !!document.querySelector('meta[http-equiv=\"content-security-policy\" i]')",
            arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool != false
    }

    func fetchSingleMainFrame() async throws -> Bool {
        try await webView.callAsyncJavaScript("return window.length === 0 && !document.querySelector('iframe, frame, object, embed')",
            arguments: [:], in: nil, contentWorld: .defaultClient) as? Bool == true
    }

    // MARK: events

    func emit(_ domain: String, _ method: String, _ params: JSON, to only: Session? = nil) {
        for s in target.sessions where s.enabled.contains(domain) && (only == nil || only === s) {
            server.send(event: method, params, sessionId: s.id)
        }
    }

    private func lifecycle(_ name: String, to only: Session? = nil) {
        if only == nil { reached.append(name) }
        for s in target.sessions where s.lifecycleEvents && s.enabled.contains("Page") && (only == nil || only === s) {
            server.send(event: "Page.lifecycleEvent",
                        ["frameId": frameId, "loaderId": loaderId, "name": name, "timestamp": monotonicSeconds()], sessionId: s.id)
        }
    }

    private var securityOrigin: String {
        if fetch.mapped, let scope = fetch.scope { return "\(FetchScope.scheme)://\(scope.host)" }
        guard let u = URL(string: url), let scheme = u.scheme else { return "://" }
        if scheme == "http" || scheme == "https", let host = u.host {
            return "\(scheme)://\(host)" + (u.port.map { ":\($0)" } ?? "")
        }
        return scheme == "file" ? "file://" : "://"
    }

    private func frameJSON() -> JSON {
        [
            "id": frameId, "loaderId": loaderId, "url": url, "domainAndRegistry": "",
            "securityOrigin": securityOrigin, "securityOriginDetails": ["isLocalhost": false],
            "mimeType": lastResponse?.mime ?? "text/html",
            "adFrameStatus": ["adFrameType": "none"],
            "secureContextType": url.hasPrefix("https") || url.hasPrefix("http://localhost") ? "Secure" : "InsecureScripts",
            "crossOriginIsolatedContextType": "NotIsolated", "gatedAPIFeatures": [String](),
        ]
    }

    private func contextJSON(_ c: ExecContext) -> JSON {
        [
            "id": c.id, "origin": securityOrigin, "name": c.worldName ?? "", "uniqueId": c.uniqueId,
            "auxData": ["isDefault": c.worldName == nil, "type": c.worldName == nil ? "default" : "isolated", "frameId": frameId],
        ]
    }

    private func createContext(world name: String?, announce: Bool) {
        let c = ExecContext(id: nextContextId, worldName: name)
        nextContextId += 1
        contexts[c.id] = c
        if announce { emit("Runtime", "Runtime.executionContextCreated", ["context": contextJSON(c)]) }
    }

    private func resetContexts() {
        contexts.removeAll()
        if !silent { emit("Runtime", "Runtime.executionContextsCleared", [:]) }
        createContext(world: nil, announce: !silent)
        for n in worldNames { createContext(world: n, announce: !silent) }
    }

    private var defaultContextId: Int { contexts.values.first { $0.worldName == nil }?.id ?? 1 }

    // MARK: navigation callbacks (from NavDelegate)

    fileprivate func isCurrent(_ n: WKNavigation?) -> Bool { n == nil || navigation == nil || navigation === n }

    fileprivate func didStartProvisional(_ n: WKNavigation?) {
        if pendingNav != nil && !isCurrent(n) { return }
        navigation = n
        if silent { return }
        loaderId = explicitLoader ?? newHexId()
        explicitLoader = nil
        loading = true; dcl = false; loadFired = false; reached = []; lastResponse = nil
        // loadSimulatedRequest need not call decidePolicyForNavigationResponse. Retain the
        // real response/MIME/CSP from the local server for this navigation as well.
        if let response = simulatedResponse { simulatedResponse = nil; didReceiveResponse(response) }
        let u = fetch.original(webView.url)?.absoluteString ?? url
        emit("Page", "Page.frameStartedNavigating", ["frameId": frameId, "url": u, "loaderId": loaderId, "navigationType": "differentDocument"])
        emit("Page", "Page.frameStartedLoading", ["frameId": frameId])
    }

    fileprivate func didReceiveResponse(_ r: URLResponse) {
        let http = r as? HTTPURLResponse
        var headers: [String: String] = [:]
        http?.allHeaderFields.forEach {
            let key = "\($0.key)"
            if !FetchAssetNetwork.privateHeaders.contains(key.lowercased()) { headers[key] = "\($0.value)" }
        }
        lastResponse = (http?.statusCode ?? 200, r.mimeType ?? "text/html", headers)
    }

    fileprivate func didCommit() {
        fetch.committed(webView.url)
        url = fetch.original(webView.url)?.absoluteString ?? "about:blank"
        if silent { resetContexts(); return }
        resetContexts()
        lifecycle("init")
        reached = []
        emit("Page", "Page.frameNavigated", ["frame": frameJSON(), "type": "Navigation"])
        lifecycle("commit")
        target.url = url; target.tab?.url = url
        server.emitInfoChanged(target)
        if !fetch.mapped {
            let ts = monotonicSeconds()
            let resp = lastResponse ?? (200, "text/html", [:])
            emit("Network", "Network.requestWillBeSent", [
                "requestId": loaderId, "loaderId": loaderId, "documentURL": url,
                "request": ["url": url, "method": "GET", "headers": JSON(), "initialPriority": "VeryHigh", "referrerPolicy": "strict-origin-when-cross-origin"],
                "timestamp": ts, "wallTime": Date().timeIntervalSince1970, "initiator": ["type": "other"],
                "redirectHasExtraInfo": false, "type": "Document", "frameId": frameId, "hasUserGesture": false,
            ])
            emit("Network", "Network.responseReceived", [
                "requestId": loaderId, "loaderId": loaderId, "timestamp": ts, "type": "Document", "frameId": frameId, "hasExtraInfo": false,
                "response": ["url": url, "status": resp.status, "statusText": "", "headers": resp.headers, "mimeType": resp.mime,
                             "connectionReused": false, "connectionId": 0, "encodedDataLength": 0, "securityState": "unknown"],
            ])
        }
        if let p = pendingNav, p.loader == loaderId {
            pendingNav = nil
            p.cont.resume(returning: ["frameId": frameId, "loaderId": loaderId, "isDownload": false])
        }
    }

    fileprivate func domContentLoaded() {
        guard !silent, !dcl else { return }
        dcl = true
        if fetch.active || fetch.mapped, let scope = fetch.scope, let document = webView.url,
           scope.grants(document), let response = lastResponse, response.mime == "text/html",
           FetchRouting.safeCSP(response.headers.first { $0.key.lowercased() == "content-security-policy" }?.value ?? "") {
            WindowlessAudioMetadata.measure(in: webView, document: document)
        }
        emit("Page", "Page.domContentEventFired", ["timestamp": monotonicSeconds()])
        lifecycle("DOMContentLoaded")
    }

    fileprivate func loadEvent() {
        domContentLoaded()
        guard !silent, !loadFired else { return }
        loadFired = true
        emit("Page", "Page.loadEventFired", ["timestamp": monotonicSeconds()])
        lifecycle("load")
    }

    fileprivate func didFinish() {
        if silent, let c = blankWait { blankWait = nil; c.resume(); return }
        guard loading else { return }
        loadEvent()
        loading = false
        title = webView.title ?? ""
        target.title = title
        if !fetch.mapped { emit("Network", "Network.loadingFinished", ["requestId": loaderId, "timestamp": monotonicSeconds(), "encodedDataLength": 0]) }
        emit("Page", "Page.frameStoppedLoading", ["frameId": frameId])
        lifecycle("networkAlmostIdle"); lifecycle("networkIdle")
        server.emitInfoChanged(target)
    }

    fileprivate func didFail(_ error: Error, provisional: Bool) {
        if provisional && pendingNav != nil { fetch.navigationFailed() }
        if silent, let c = blankWait { blankWait = nil; c.resume(); return }
        let text = PageContent.netError(error)
        loading = false
        if let p = pendingNav {
            pendingNav = nil
            p.cont.resume(returning: ["frameId": frameId, "loaderId": p.loader, "isDownload": false, "errorText": text])
        }
        emit("Page", "Page.frameStoppedLoading", ["frameId": frameId])
    }

    fileprivate func processTerminated() {
        fetch.navigationFailed()
        didFail(CDPError.server("WebContent process terminated"), provisional: false)
    }

    static func netError(_ e: Error) -> String {
        let ns = e as NSError
        guard ns.domain == NSURLErrorDomain else { return "net::ERR_FAILED" }
        switch ns.code {
        case NSURLErrorCancelled: return "net::ERR_ABORTED"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "net::ERR_NAME_NOT_RESOLVED"
        case NSURLErrorCannotConnectToHost: return "net::ERR_CONNECTION_REFUSED"
        case NSURLErrorFileDoesNotExist, NSURLErrorFileIsDirectory: return "net::ERR_FILE_NOT_FOUND"
        case NSURLErrorTimedOut: return "net::ERR_TIMED_OUT"
        case NSURLErrorNotConnectedToInternet: return "net::ERR_INTERNET_DISCONNECTED"
        case NSURLErrorNetworkConnectionLost: return "net::ERR_CONNECTION_RESET"
        case NSURLErrorBadURL, NSURLErrorUnsupportedURL: return "net::ERR_INVALID_URL"
        default: return "net::ERR_FAILED"
        }
    }

    fileprivate func scriptMessage(_ body: JSON, world: WKContentWorld) {
        switch body["k"] as? String {
        case "dcl": domContentLoaded()
        case "load": loadEvent()
        case "console":
            emit("Runtime", "Runtime.consoleAPICalled", [
                "type": body["t"] as? String ?? "log", "args": body["a"] as? [Any] ?? [],
                "executionContextId": defaultContextId, "timestamp": Date().timeIntervalSince1970 * 1000,
                "stackTrace": ["callFrames": [JSON]()],
            ])
        case "exc":
            let msg = body["m"] as? String ?? ""
            emit("Runtime", "Runtime.exceptionThrown", [
                "timestamp": Date().timeIntervalSince1970 * 1000,
                "exceptionDetails": [
                    "exceptionId": Int.random(in: 1...1_000_000), "text": "Uncaught", "lineNumber": (body["l"] as? Int ?? 1) - 1,
                    "columnNumber": (body["c"] as? Int ?? 1) - 1, "url": body["u"] as? String ?? "",
                    "exception": ["type": "object", "subtype": "error", "className": body["n"] as? String ?? "Error", "description": "\(body["n"] as? String ?? "Error"): \(msg)"],
                ] as JSON,
            ])
        case "binding":
            guard !silent, let n = body["n"] as? String else { return }
            let wn = bindings.first { $0.name == n }?.world
            let ctx = contexts.values.first { $0.worldName == wn }?.id ?? defaultContextId
            emit("Runtime", "Runtime.bindingCalled", ["name": n, "payload": body["p"] as? String ?? "", "executionContextId": ctx])
        default: break
        }
    }

    // MARK: navigate

    func navigate(_ urlString: String, reloading: Bool = false) async throws -> JSON {
        guard let u = URL(string: urlString), u.scheme != nil else { throw CDPError.server("Cannot navigate to invalid URL") }
        let destination = try fetch.beginNavigation(u, reloading: reloading)
        rebuildScripts()
        if let old = pendingNav { pendingNav = nil; old.cont.resume(throwing: CDPError.server("Navigation superseded")) }
        let loader = newHexId()
        explicitLoader = loader
        let prepared: (URLResponse, Data)?
        do { prepared = try await fetch.prepareNativeDocument(u) }
        catch let e as CDPError { if explicitLoader == loader { explicitLoader = nil; fetch.navigationFailed() }; throw e }
        catch {
            if explicitLoader == loader { explicitLoader = nil; fetch.navigationFailed() }
            return ["frameId": frameId, "loaderId": loader, "isDownload": false, "errorText": Self.netError(error)]
        }
        guard explicitLoader == loader else { throw CDPError.server("Navigation superseded") }
        try fetch.armNavigation(destination)
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSON, Error>) in
            pendingNav = (loader, c)
            simulatedResponse = prepared?.0
            if let (response, bytes) = prepared {
                navigation = webView.loadSimulatedRequest(URLRequest(url: u), response: response, responseData: bytes)
            } else if destination.isFileURL {
                navigation = webView.loadFileURL(destination, allowingReadAccessTo: destination.deletingLastPathComponent())
            } else {
                navigation = webView.load(URLRequest(url: destination))
            }
            if navigation == nil { pendingNav = nil; fetch.navigationFailed(); c.resume(throwing: CDPError.server("WebKit declined the navigation")) }
        }
    }

    // MARK: runtime

    private func context(_ id: Int?) throws -> ExecContext {
        if let id = id {
            guard let c = contexts[id] else { throw CDPError.server("Cannot find context with specified id") }
            return c
        }
        guard let c = contexts[defaultContextId] else { throw CDPError.server("Cannot find context with specified id") }
        return c
    }

    private func run(_ ctx: ExecContext, _ body: String, _ args: [String: Any]) async throws -> JSON {
        var a = args
        a["ctx"] = ctx.id
        let out: Any?
        do {
            out = try await webView.callAsyncJavaScript(body, arguments: a, in: nil, contentWorld: world(ctx.worldName))
        } catch {
            let ns = error as NSError
            if let m = ns.userInfo["WKJavaScriptExceptionMessage"] as? String {
                let exc: JSON = ["type": "object", "subtype": "error", "className": "Error", "description": "Error: \(m)"]
                return ["result": exc, "exceptionDetails": ["exceptionId": 1, "text": "Uncaught", "lineNumber": 0, "columnNumber": 0, "exception": exc] as JSON]
            }
            throw CDPError.server("Execution context was destroyed, most likely because of a navigation. (\(ns.localizedDescription))")
        }
        guard let s = out as? String, let obj = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? JSON else { return ["result": ["type": "undefined"]] }
        return obj
    }

    private func contextOf(objectId: String) throws -> ExecContext {
        guard let first = objectId.split(separator: ".").first, let id = Int(first) else { throw CDPError.invalidParams("Invalid remote object id") }
        return try context(id)
    }

    // MARK: handle

    func handle(_ s: Session, _ method: String, _ p: JSON) async throws -> JSON {
        if method.hasPrefix("Fetch.") { return try await fetch.handle(s, method, p) }
        switch method {
        case "Runtime.runIfWaitingForDebugger", "Network.disable", "Page.disable", "Runtime.disable", "Log.disable",
             "Audits.disable", "Performance.disable", "Page.bringToFront", "Emulation.setTouchEmulationEnabled",
             "Emulation.setFocusEmulationEnabled", "Runtime.discardConsoleEntries", "Runtime.releaseObjectGroup",
             "Network.setCacheDisabled":
            return [:]
        case "Page.stopLoading":
            fetch.cancelAll(); webView.stopLoading()
            if pendingNav != nil { didFail(URLError(.cancelled), provisional: true) }
            return [:]
        case "Network.enable": s.enabled.insert("Network"); return [:]
        case "Audits.enable", "Performance.enable", "Log.enable", "WebMCP.enable": return [:]
        case "Page.enable":
            s.enabled.insert("Page")
            if !loading { emit("Page", "Page.frameStoppedLoading", ["frameId": frameId], to: s) }
            return [:]
        case "Page.setLifecycleEventsEnabled":
            s.lifecycleEvents = (p["enabled"] as? Bool) ?? false
            if s.lifecycleEvents { for n in reached { lifecycle(n, to: s) } }
            return [:]
        case "Page.getFrameTree": return ["frameTree": ["frame": frameJSON()]]
        case "Runtime.enable":
            s.enabled.insert("Runtime")
            for c in contexts.values.sorted(by: { $0.id < $1.id }) { emit("Runtime", "Runtime.executionContextCreated", ["context": contextJSON(c)], to: s) }
            return [:]
        case "Page.addScriptToEvaluateOnNewDocument":
            let src = p["source"] as? String ?? ""
            let wn = p["worldName"] as? String
            let id = String(nextScriptId); nextScriptId += 1
            scripts.append(InjectedScript(id: id, source: src, worldName: wn))
            if let wn = wn { ensureWorld(wn) }
            webView.configuration.userContentController.addUserScript(
                WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world(wn)))
            if (p["runImmediately"] as? Bool) == true, let c = try? context(wn == nil ? nil : contexts.values.first { $0.worldName == wn }?.id) {
                _ = try? await run(c, "try { (0, eval)(src); } catch (e) {} return '{}';", ["src": src, "byValue": true, "awaitP": false])
            }
            return ["identifier": id]
        case "Page.removeScriptToEvaluateOnNewDocument":
            scripts.removeAll { $0.id == (p["identifier"] as? String) }
            rebuildScripts()
            return [:]
        case "Page.createIsolatedWorld":
            let name = (p["worldName"] as? String) ?? ""
            ensureWorld(name)
            if let c = contexts.values.first(where: { $0.worldName == name }) { return ["executionContextId": c.id] }
            createContext(world: name, announce: true)
            return ["executionContextId": nextContextId - 1]
        case "Runtime.addBinding":
            guard let name = p["name"] as? String else { throw CDPError.invalidParams("name required") }
            let wn = p["executionContextName"] as? String
            bindings.append((name, wn))
            if let wn = wn { ensureWorld(wn) }
            rebuildScripts()
            if let c = try? context(wn == nil ? nil : contexts.values.first { $0.worldName == wn }?.id) {
                _ = try? await run(c, "(0, eval)(src); return '{}';", ["src": JSRuntime.bindingScript(name: name), "byValue": true, "awaitP": false])
            }
            return [:]
        case "Runtime.removeBinding":
            bindings.removeAll { $0.name == (p["name"] as? String) }
            rebuildScripts()
            return [:]
        case "Emulation.setDeviceMetricsOverride":
            let w = (p["width"] as? Int) ?? 0, h = (p["height"] as? Int) ?? 0
            if w > 0 && h > 0 { viewportSize = (w, h) }
            let f = (p["deviceScaleFactor"] as? Double) ?? 0
            dsf = f > 0 ? f : 1
            page.setViewport(width: viewportSize.w, height: viewportSize.h, scale: dsf)
            return [:]
        case "Emulation.clearDeviceMetricsOverride":
            dsf = 1
            page.setViewport(width: server.options.width, height: server.options.height, scale: 1)
            return [:]
        case "Emulation.setDefaultBackgroundColorOverride":
            let transparent: Bool
            if let c = p["color"] as? JSON, let a = (c["a"] as? Double) ?? (c["a"] as? Int).map(Double.init) { transparent = a == 0 } else { transparent = false }
            webView.setValue(!transparent, forKey: "drawsBackground")
            return [:]
        case "Emulation.setUserAgentOverride", "Network.setUserAgentOverride":
            webView.customUserAgent = p["userAgent"] as? String
            return [:]
        case "Page.navigate":
            guard let u = p["url"] as? String else { throw CDPError.invalidParams("url required") }
            return try await navigate(u)
        case "Page.setDocumentContent":
            guard let html = p["html"] as? String else { throw CDPError.invalidParams("html required") }
            let c = try context(nil)
            let r = try await run(c, JSRuntime.preamble + "document.open(); document.write(html); document.close(); return '{}';",
                                  ["html": html, "byValue": true, "awaitP": false])
            if r["exceptionDetails"] != nil { throw CDPError.server("Failed to set document content") }
            // document.open() drops the page's own load listeners, so announce the "new" document ourselves.
            reached = []; dcl = false; loadFired = false
            lifecycle("init")
            reached = []
            domContentLoaded(); loadEvent()
            lifecycle("networkAlmostIdle"); lifecycle("networkIdle")
            return [:]
        case "Page.reload":
            if fetch.active || fetch.mapped { _ = try await navigate(fetch.reloadDocument(webView.url).absoluteString, reloading: true) } else { webView.reload() }
            return [:]
        case "Page.close":
            let t = target
            Task { @MainActor in self.server.closeTarget(t) }
            return [:]
        case "Runtime.evaluate":
            guard let expr = p["expression"] as? String else { throw CDPError.invalidParams("expression required") }
            let c = try context(p["contextId"] as? Int)
            return try await run(c, JSRuntime.evaluate, ["expression": expr, "byValue": (p["returnByValue"] as? Bool) ?? false,
                                                         "awaitP": (p["awaitPromise"] as? Bool) ?? false])
        case "Runtime.callFunctionOn":
            guard let decl = p["functionDeclaration"] as? String else { throw CDPError.invalidParams("functionDeclaration required") }
            let objectId = p["objectId"] as? String
            let c = try objectId != nil ? contextOf(objectId: objectId!) : context(p["executionContextId"] as? Int)
            let argv = (p["arguments"] as? [Any]) ?? []
            return try await run(c, JSRuntime.callFunctionOn, [
                "decl": decl, "argv": argv, "thisId": objectId ?? NSNull(),
                "byValue": (p["returnByValue"] as? Bool) ?? false, "awaitP": (p["awaitPromise"] as? Bool) ?? false,
            ])
        case "DOM.describeNode":
            guard let oid = p["objectId"] as? String else { throw CDPError.invalidParams("objectId required") }
            let c = try contextOf(objectId: oid)
            let r = try await run(c, JSRuntime.describeNode, ["objectId": oid, "base": 1000 * c.id + 1, "byValue": true, "awaitP": false])
            if let e = r["error"] as? String { throw CDPError.server(e) }
            return r
        case "DOM.resolveNode":
            guard let bid = p["backendNodeId"] as? Int else { throw CDPError.invalidParams("backendNodeId required") }
            // backendNodeId = 1000*<context that described it> + n. Nodes live in per-world registries and WebKit cannot move
            // a wrapper between worlds, so resolve in the origin world (the objectId routes later calls there).
            let c = try context(max(1, bid / 1000))
            let r = try await run(c, JSRuntime.resolveNode, ["backendNodeId": bid, "byValue": true, "awaitP": false])
            if let e = r["error"] as? String { throw CDPError.server(e) }
            return r
        case "Runtime.releaseObject":
            guard let oid = p["objectId"] as? String, let c = try? contextOf(objectId: oid), let n = Int(oid.split(separator: ".").last ?? "") else { return [:] }
            _ = try? await run(c, JSRuntime.release, ["n": n])
            return [:]
        case "Page.captureScreenshot":
            return try await screenshot(p)
        default:
            throw CDPError.methodNotFound(method)
        }
    }

    private func ensureWorld(_ name: String) {
        if !worldNames.contains(name) { worldNames.append(name) }
    }

    // MARK: screenshot

    private func screenshot(_ p: JSON) async throws -> JSON {
        let format = (p["format"] as? String) ?? "png"
        guard format == "png" || format == "jpeg" else { throw CDPError.server("Unsupported screenshot format: \(format)") }
        let quality = ((p["quality"] as? Double) ?? (p["quality"] as? Int).map(Double.init) ?? 80) / 100
        var rect = CGRect(x: 0, y: 0, width: viewportSize.w, height: viewportSize.h)
        var clipScale = 1.0
        if let c = p["clip"] as? JSON {
            func n(_ k: String) -> Double { (c[k] as? Double) ?? (c[k] as? Int).map(Double.init) ?? 0 }
            rect = CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height"))
            clipScale = n("scale") > 0 ? n("scale") : 1
        }
        guard rect.width >= 1, rect.height >= 1 else { throw CDPError.server("Cannot take screenshot with 0 width or height.") }
        let beyond = (p["captureBeyondViewport"] as? Bool) ?? false
        var w = viewportSize.w, h = viewportSize.h
        var resized = false
        if beyond && (Int(rect.maxX.rounded(.up)) > w || Int(rect.maxY.rounded(.up)) > h) {
            w = max(w, Int(rect.maxX.rounded(.up))); h = max(h, Int(rect.maxY.rounded(.up))); resized = true
        }
        page.setViewport(width: w, height: h, scale: dsf * clipScale)
        if resized { try await Task.sleep(nanoseconds: 50_000_000) }
        defer { page.setViewport(width: viewportSize.w, height: viewportSize.h, scale: dsf) }
        let snap: Snapshot
        do { snap = try await page.snapshot(clip: rect) } catch { throw CDPError.server("Failed to capture screenshot: \(error)") }
        let data = format == "png" ? snap.pngData() : snap.jpegData(quality: quality)
        guard !data.isEmpty else { throw CDPError.server("Failed to encode screenshot") }
        return ["data": data.base64EncodedString()]
    }
}

// MARK: - delegates

private final class NavDelegate: NSObject, WKNavigationDelegate {
    weak var owner: PageContent?
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction) async -> WKNavigationActionPolicy {
        owner?.fetch.permitsNavigation(a) == true ? .allow : .cancel
    }
    func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { MainActor.assumeIsolated { owner?.didStartProvisional(n) } }
    func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        guard let owner, owner.fetch.permitsNavigationResponse(r) else { return .cancel }
        if r.isForMainFrame { owner.didReceiveResponse(r.response) }
        return .allow
    }
    func webView(_ w: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func webView(_ w: WKWebView, didCommit n: WKNavigation!) { MainActor.assumeIsolated { if owner?.isCurrent(n) == true { owner?.didCommit() } } }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { MainActor.assumeIsolated { if owner?.isCurrent(n) == true { owner?.didFinish() } } }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        MainActor.assumeIsolated { if owner?.isCurrent(n) == true { owner?.didFail(e, provisional: false) } }
    }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        MainActor.assumeIsolated { if owner?.isCurrent(n) == true { owner?.didFail(e, provisional: true) } }
    }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { MainActor.assumeIsolated { owner?.processTerminated() } }
}

private final class ScriptHandler: NSObject, WKScriptMessageHandler {
    weak var owner: PageContent?
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? JSON else { return }
        let world = m.world
        MainActor.assumeIsolated {
            guard let owner, m.frameInfo.isMainFrame || !(owner.fetch.active || owner.fetch.mapped) else { return }
            owner.scriptMessage(body, world: world)
        }
    }
}
