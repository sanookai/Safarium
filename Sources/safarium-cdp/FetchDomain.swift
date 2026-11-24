import Foundation
import WebKit

/// Request/response interception for renderer assets, per page, over the existing CDP pipe.
/// WKWebView reserves http(s)/file. Narrow localhost rules keep the native document origin;
/// intercepted documents and files use fresh, isolated WebKit origins. External assets can be
/// fulfilled offline; only the public, versioned JS files in FetchScope.publicGSAP may continue
/// upstream. CDP always reports the original URL. There is no proxy or TLS impersonation.
@MainActor final class FetchDomain: NSObject, WKURLSchemeHandler {
    weak var owner: PageContent?
    private(set) var scope: FetchScope?
    private(set) var mapped = false
    private var expectingMain = false
    private var nativeDocument = false
    private var epoch = newHexId()
    private var pendingTop: URL?, approvedTop: URL?
    private var issuingTop = false
    private var committedTop = false, allowedChild = false
    private var checking: [String: String] = [:]
    private var preparing: Task<FetchPayload, Error>?
    private var enabled: [String: [FetchPattern]] = [:]
    private var versions: [String: String] = [:]
    private var rules: [String: WKContentRuleList] = [:]
    private let network = FetchAssetNetwork()
    private var jobs: [ObjectIdentifier: Job] = [:]
    private var pauses: [String: Job] = [:]
    private var closed = false
    var active: Bool { !enabled.isEmpty }
    private var frameGate: Bool { active || mapped || !checking.isEmpty }
    private var patterns: [FetchPattern] { enabled.values.flatMap { $0 } }
    var routingScript: String? {
        guard let scope, active || mapped else { return nil }
        return FetchRouting.script(scope: scope, patterns: patterns)
    }

    private final class Job {
        let task: WKURLSchemeTask
        let key: ObjectIdentifier
        let original: URL, type: String, netID: String, loader: String
        let main: Bool
        var request: URLRequest
        var payload: FetchPayload?
        var answered = Set<String>()
        var pausedBy: String?, pauseID: String?
        var deadline: Task<Void, Never>?, worker: Task<Void, Never>?
        var forceResponse = Set<String>()
        init(_ t: WKURLSchemeTask, url: URL, type: String, main: Bool, loader: String) {
            task = t; key = ObjectIdentifier(t); original = url; self.type = type; self.main = main; self.loader = loader
            netID = main ? loader : newHexId(); request = t.request; request.url = url
            if main {
                // This one document request is initiated by the CDP driver, never by a frame.
                request.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
                request.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
            }
        }
    }

    /// Content blockers are the fail-closed backstop for built-in scheme loads that the WebKit
    /// parser/API did not translate (e.g. a computed CSS URL). They do not read or proxy traffic.
    private static let ruleStore: WKContentRuleListStore? = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("safarium-fetch-rules-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { return nil }
        return WKContentRuleListStore(url: dir)
    }()

    private func blocker(_ specs: [FetchPattern], id: String) async throws -> WKContentRuleList? {
        var entries: [JSON] = []
        for p in specs {
            let filters: [String]
            if p.origin != nil { filters = [p.expression] }
            else if p.expression.hasPrefix("^.*") {
                filters = ["^https?://.*" + String(p.expression.dropFirst(3)), "^file://.*" + String(p.expression.dropFirst(3))]
            } else { throw CDPError.invalidParams("Use an absolute URL or a renderer URL glob beginning with '*'") }
            for filter in filters {
                var trigger: JSON = ["url-filter": filter, "url-filter-is-case-sensitive": true]
                if let t = p.resource {
                    let dest = ["Document":"document","Stylesheet":"style-sheet","Image":"image","Media":"media","Font":"font",
                                "Script":"script","Fetch":"fetch","XHR":"raw","TextTrack":"media","Manifest":"raw","Other":"other"]
                    if let d = dest[t] { trigger["resource-type"] = [d] }
                }
                entries.append(["trigger": trigger, "action": ["type":"block"]])
            }
        }
        guard !entries.isEmpty else { return nil }
        guard let store = Self.ruleStore else { throw CDPError.server("Cannot create renderer content-rule store") }
        let data = try JSONSerialization.data(withJSONObject: entries)
        do { return try await store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: String(decoding: data, as: UTF8.self)) }
        catch { throw CDPError.invalidParams("WebKit cannot enforce this Fetch URL pattern: \(error.localizedDescription)") }
    }

    private func refreshOrigins() {
        scope?.updateOrigins(patterns.compactMap(\.origin))
    }

    private func validateRoutes(_ specs: [FetchPattern], in grant: FetchScope) throws {
        for p in specs {
            guard let origin = p.origin, !origin.isFileURL,
                  FetchScope.origin(origin) != FetchScope.origin(grant.document) else { continue }
            if p.resource == "Document" { throw CDPError.invalidParams("Foreign document interception is not supported") }
            let canReadExactAsset = URL(string: p.glob).map(FetchScope.publicGSAP) == true &&
                ProcessInfo.processInfo.environment["SAFARIUM_FETCH_OFFLINE"] != "1"
            if p.response && !canReadExactAsset &&
                !specs.contains(where: { !$0.response && ($0.origin == nil || $0.origin.flatMap(FetchScope.origin) == FetchScope.origin(origin)) }) {
                throw CDPError.invalidParams("A synthetic-only origin needs a request-stage fulfillment before a response pause")
            }
        }
    }

    func beginNavigation(_ u: URL, reloading: Bool = false) throws -> URL {
        guard !closed, u.scheme != FetchScope.scheme else { throw CDPError.invalidParams("Navigate to the original renderer URL on a live target") }
        var next: FetchScope?
        if reloading {
            guard var pinned = scope, committedTop, sameTop(u, pinned.document) else { throw CDPError.server("Renderer reload superseded") }
            pinned.rotateHosts() // Keep the already-open project directory, even if its pathname has changed.
            next = pinned
        } else { next = FetchScope(u) }
        if active && next == nil && !["about", "data"].contains(u.scheme) {
            throw CDPError.server("Active Fetch only supports CDP navigation to a project file or localhost HTTP; disable it for native remote navigation")
        }
        if let next { try validateRoutes(patterns, in: next) }
        next?.updateOrigins(patterns.compactMap(\.origin))
        // For narrow routes a local HTTP page can keep its *actual* origin. WebKit loads all
        // nonmatching assets (especially AVFoundation media/Range) directly; only matched parser
        // attributes change. Never install a simulated response at an arbitrary remote origin.
        let native = active && next != nil && u.scheme == "http" && !FetchScope.isVirtualRenderer(u) &&
            !patterns.isEmpty && patterns.allSatisfy { $0.origin != nil && !$0.matches(u, "Document") }
        let useMapping = next != nil && !native && (active || (reloading && mapped))
        let destination: URL
        if useMapping {
            guard let virtual = next?.map(u) else { throw CDPError.server("Cannot grant this renderer document") }
            destination = virtual
        } else { destination = u }
        invalidateNavigation()
        scope = next; mapped = useMapping; nativeDocument = native
        expectingMain = mapped
        pendingTop = destination
        return destination
    }

    func prepareNativeDocument(_ u: URL) async throws -> (URLResponse, Data)? {
        guard nativeDocument, let grant = scope else { return nil }
        let current = epoch
        let work = Task { @MainActor in try await network.read(URLRequest(url: u), scope: grant, main: true) }
        preparing = work
        let r = try await work.value
        guard !closed, epoch == current, scope?.host == grant.host, !work.isCancelled else { throw URLError(.cancelled) }
        preparing = nil
        let body: Data
        if r.mime == "text/html" || r.mime == "application/xhtml+xml" {
            guard FetchRouting.safeCSP(r.header("Content-Security-Policy") ?? ""), !FetchRouting.unsafeMetaPolicy(r.body) else {
                throw CDPError.server("Cannot safely remap assets under this document's Content-Security-Policy")
            }
            body = FetchRouting.html(r.body, at: u, scope: grant, patterns: patterns, virtualDocument: false)
        } else { body = r.body }
        var headers = r.headers.filter { !["content-length","content-encoding","transfer-encoding","connection"].contains($0.key.lowercased()) }
        if r.mime == "text/html" || r.mime == "application/xhtml+xml" { headers = FetchRouting.singleFrameHeaders(headers) }
        headers["Content-Length"] = "\(body.count)"
        guard let response = HTTPURLResponse(url: u, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: headers) else { throw URLError(.badServerResponse) }
        return (response, body)
    }

    func original(_ u: URL?) -> URL? { guard let u else { return nil }; return scope?.unmap(u) ?? u }
    private func sameTop(_ u: URL?, _ selected: URL?) -> Bool {
        FetchScope.sameNavigation(u, selected)
    }

    // WebKit supplies actual frame information here, not to WKURLSchemeHandler. Start
    // policing frames before a hot enable awaits JS or rule compilation. For an existing
    // page we also require a clean frame history and an isolated-world frame census.
    func permitsNavigation(_ action: WKNavigationAction) -> Bool {
        guard !closed, let u = action.request.url else { return false }
        guard action.targetFrame?.isMainFrame == true else {
            if frameGate || u.scheme == FetchScope.scheme { return false }
            if action.targetFrame != nil { allowedChild = true }
            return true
        }
        // App-initiated WKWebView.load actions have no initiating web frame; WebKit
        // reports sourceFrame.isMainFrame == false. The one-use grant is armed at
        // the actual CDP load call, not when a possibly asynchronous prefetch starts.
        if issuingTop, sameTop(u, pendingTop), action.navigationType == .other,
           action.request.httpMethod == nil || action.request.httpMethod == "GET" {
            approvedTop = pendingTop; pendingTop = nil; issuingTop = false
            return true
        }
        if committedTop, u.fragment != nil, sameTop(u, approvedTop), action.sourceFrame.isMainFrame { return true }
        guard !active, checking.isEmpty, u.scheme != FetchScope.scheme else { return false }
        // Following a native link after disable is fine, but never carries a file/network grant.
        invalidateNavigation()
        return true
    }
    func permitsNavigationResponse(_ response: WKNavigationResponse) -> Bool {
        guard !closed else { return false }
        guard response.isForMainFrame else {
            if frameGate { return false }
            allowedChild = true; return true
        }
        if frameGate { return sameTop(response.response.url, approvedTop) }
        if !sameTop(response.response.url, approvedTop) { invalidateNavigation() }
        return true
    }
    func committed(_ u: URL?) {
        if sameTop(u, approvedTop) { committedTop = true }
        else { invalidateNavigation() }
    }
    func reloadDocument(_ current: URL?) throws -> URL {
        guard committedTop, sameTop(current, approvedTop), let scope, scope.grants(current) else {
            throw CDPError.server("Fetch reload requires the original CDP-selected document")
        }
        return scope.document
    }
    func armNavigation(_ destination: URL) throws {
        guard !closed, sameTop(destination, pendingTop) else { throw CDPError.server("Navigation superseded") }
        issuingTop = true
    }
    private func invalidateNavigation() {
        epoch = newHexId(); checking.removeAll()
        pendingTop = nil; approvedTop = nil; issuingTop = false; committedTop = false; allowedChild = false
        expectingMain = false; nativeDocument = false; mapped = false; scope = nil
        cancelAll()
    }
    func navigationFailed() { invalidateNavigation() }

    func handle(_ session: Session, _ method: String, _ p: JSON) async throws -> JSON {
        switch method {
        case "Fetch.enable":
            guard let owner, !closed else { throw CDPError.server("Target closed") }
            guard p["handleAuthRequests"] == nil || p["handleAuthRequests"] as? Bool == false else {
                throw CDPError.invalidParams("Renderer Fetch does not handle authentication challenges")
            }
            guard scope != nil || (owner.webView.url?.absoluteString == "about:blank" && pendingTop == nil &&
                  (approvedTop == nil || (committedTop && approvedTop?.absoluteString == "about:blank"))) else {
                throw CDPError.server("Fetch needs a renderer project file or localhost document")
            }
            guard p["patterns"] == nil || p["patterns"] is [JSON] else { throw CDPError.invalidParams("patterns must be an array") }
            let input = p["patterns"] as? [JSON] ?? [[:]]
            guard (1...64).contains(input.count) else { throw CDPError.invalidParams("Specify 1...64 Fetch patterns") }
            let specs = try input.map(FetchPattern.init)
            if !mapped, scope != nil, specs.contains(where: { $0.origin == nil && $0.resource == nil }) {
                throw CDPError.server("Enable all-request Fetch before local navigation; a loaded native page needs a literal origin or resource type")
            }
            let revision = newHexId(), current = epoch
            versions[session.id] = revision; checking[session.id] = revision
            defer { if checking[session.id] == revision { checking[session.id] = nil } }
            func currentEnable() -> Bool {
                !closed && current == epoch && versions[session.id] == revision &&
                    owner.target.sessions.contains { $0 === session }
            }
            if let scope {
                try validateRoutes(enabled.filter { $0.key != session.id }.values.flatMap { $0 } + specs, in: scope)
                guard committedTop, sameTop(owner.webView.url, approvedTop), !allowedChild,
                      try await owner.fetchSingleMainFrame() else {
                    throw CDPError.server("Hot Fetch needs a committed renderer document without child frames; enable before navigation")
                }
                if !mapped, try await owner.fetchHasCSP() {
                    throw CDPError.server("This native page has CSP; its requests cannot safely be remapped")
                }
            }
            guard currentEnable() else { throw CDPError.server("Fetch enable superseded") }
            let list = try await blocker(specs, id: revision)
            guard currentEnable() else {
                if let list { removeStored(list) }
                throw CDPError.server("Fetch enable superseded")
            }
            if let list { owner.webView.configuration.userContentController.add(list) }
            let replacing = enabled[session.id] != nil
            dropRules(session.id)
            rules[session.id] = list; enabled[session.id] = specs
            refreshOrigins()
            for j in Array(jobs.values) {
                if !authorized(j) { fail(j, URLError(.cancelled)); continue }
                if replacing {
                    j.forceResponse.remove(session.id)
                    if j.pausedBy == session.id { unpause(j); advance(j) }
                }
            }
            do { try await owner.refreshFetchScripts() }
            catch { if versions[session.id] == revision { release(session.id) }; throw error }
            // After installation it is an ordinary session subscription, retained across
            // explicit CDP navigation. Disable/detach/replacement still invalidates it.
            guard !closed, versions[session.id] == revision else { throw CDPError.server("Fetch enable superseded") }
            if specs.contains(where: { $0.origin == nil }) {
                FileHandle.standardError.write(Data("[safarium-cdp] Fetch wildcard is scoped to renderer inputs; unmatched WebKit paths covered by the wildcard are blocked. External main navigation requires Fetch.disable.\n".utf8))
            }
            return [:]
        case "Fetch.disable":
            release(session.id)
            if let owner { try await owner.refreshFetchScripts() }
            return [:]
        case "Fetch.continueRequest", "Fetch.continueResponse", "Fetch.fulfillRequest", "Fetch.failRequest", "Fetch.getResponseBody":
            guard let id = p["requestId"] as? String, let j = pauses[id], j.pausedBy == session.id else {
                throw CDPError.invalidParams("Invalid or already resolved Fetch requestId for this session")
            }
            if method == "Fetch.getResponseBody" {
                guard let payload = j.payload else { throw CDPError.server("Response body is not available at request stage") }
                return ["body": payload.body.base64EncodedString(), "base64Encoded": true]
            }
            switch method {
            case "Fetch.failRequest":
                let reasons = ["Failed","Aborted","TimedOut","AccessDenied","ConnectionClosed","ConnectionReset","ConnectionRefused",
                               "ConnectionAborted","ConnectionFailed","NameNotResolved","InternetDisconnected","AddressUnreachable",
                               "BlockedByClient","BlockedByResponse"]
                guard let reason = p["errorReason"] as? String, reasons.contains(reason) else { throw CDPError.invalidParams("Invalid network errorReason") }
                fail(j, URLError(reason == "Aborted" ? .cancelled : reason == "TimedOut" ? .timedOut : .cannotLoadFromNetwork),
                     text: "net::ERR_" + reason.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1_$2", options: .regularExpression).uppercased())
            case "Fetch.fulfillRequest":
                var result = try response(p, base: j.payload, url: j.original, fulfill: true)
                if let body = p["body"] as? String {
                    guard body.utf8.count <= (FetchPayload.limit + 2) / 3 * 4, let bytes = Data(base64Encoded: body),
                          bytes.count <= FetchPayload.limit else {
                        throw CDPError.invalidParams("Invalid or oversized base64 response body")
                    }
                    result.body = bytes
                } else if p["body"] != nil { throw CDPError.invalidParams("body must be base64") }
                let wasRequest = j.payload == nil
                unpause(j); j.payload = result
                if wasRequest { j.answered.removeAll() }
                advance(j)
            case "Fetch.continueResponse":
                guard let existing = j.payload else { throw CDPError.invalidParams("Request is not paused at response stage") }
                j.payload = try response(p, base: existing, url: j.original, fulfill: false)
                unpause(j); advance(j)
            default:
                guard p["interceptResponse"] == nil || (j.payload == nil && p["interceptResponse"] is Bool),
                      p["url"] == nil || p["url"] is String, p["method"] == nil || p["method"] is String else {
                    throw CDPError.invalidParams("Invalid request overrides")
                }
                if p["url"] != nil || p["method"] != nil || p["headers"] != nil || p["postData"] != nil {
                    guard j.payload == nil, p["postData"] == nil else { throw CDPError.invalidParams("Request-body/response-stage overrides are not supported") }
                    var req = j.request
                    if let text = p["url"] as? String {
                        guard let u = URL(string: text), scope?.map(u) != nil,
                              (u.isFileURL && j.original.isFileURL) || (!u.isFileURL && FetchScope.origin(u) == FetchScope.origin(j.original)) else {
                            throw CDPError.invalidParams("URL override must stay inside the original renderer origin")
                        }
                        req.url = u
                    }
                    if let m = p["method"] as? String {
                        guard ["GET","HEAD"].contains(m) else { throw CDPError.invalidParams("Only GET/HEAD asset continuation is supported") }; req.httpMethod = m
                    }
                    if let h = p["headers"] {
                        let fields = try headers(h)
                        let local = scope.map { !$0.document.isFileURL && FetchScope.origin($0.document) == FetchScope.origin(j.original) } == true
                        guard fields.keys.allSatisfy({ FetchAssetNetwork.permitsHeader($0, local: local) }) else {
                            throw CDPError.invalidParams("Unsupported or credential-bearing request header override")
                        }
                        req.allHTTPHeaderFields = fields
                    }
                    j.request = req
                }
                if p["interceptResponse"] as? Bool == true { j.forceResponse.insert(session.id) }
                unpause(j); advance(j)
            }
            return [:]
        default: throw CDPError.methodNotFound(method)
        }
    }

    private func headers(_ raw: Any) throws -> [String: String] {
        guard let entries = raw as? [JSON], entries.count <= 256 else { throw CDPError.invalidParams("Invalid Fetch header list") }
        var result: [String: String] = [:], total = 0
        for e in entries {
            guard let k = e["name"] as? String, let v = e["value"] as? String,
                  !k.isEmpty, k.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                      (48...57).contains($0) || "!#$%&'*+.^_`|~-".utf8.contains($0) }),
                  !v.utf8.contains(where: { $0 == 127 || ($0 < 32 && $0 != 9) }) else { throw CDPError.invalidParams("Invalid HTTP header") }
            total += k.utf8.count + v.utf8.count; guard total <= 65536 else { throw CDPError.invalidParams("Too many header bytes") }
            let key = result.keys.first(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) ?? k
            result[key] = result[key].map { $0 + ", " + v } ?? v
        }
        return result
    }
    private func response(_ p: JSON, base: FetchPayload?, url: URL, fulfill: Bool) throws -> FetchPayload {
        guard p["binaryResponseHeaders"] == nil else { throw CDPError.invalidParams("Use UTF-8 responseHeaders") }
        guard let code = p["responseCode"] as? Int ?? (fulfill ? nil : base?.status), (200...599).contains(code),
              !(300...399).contains(code) || code == 304 else { throw CDPError.invalidParams("Unsupported responseCode (redirects cannot be replayed safely)") }
        let reusing = base != nil && p["body"] == nil
        guard !reusing || code == base?.status else { throw CDPError.invalidParams("Reused response bytes retain their native status") }
        var result = FetchPayload(status: code, headers: base?.headers ?? [:], body: base?.body ?? Data(), reason: p["responsePhrase"] as? String ?? base?.reason ?? "")
        if let h = p["responseHeaders"] {
            let supplied = try headers(h)
            for (name, value) in supplied {
                let key = name.lowercased()
                if let base, base.header(key) == value { continue }
                // Reusing actual bytes is a continuation, not a new policy authority.
                // Preserve *all* original fields, even security fields not known to this build.
                if reusing { throw CDPError.invalidParams("Cannot change native headers while reusing response bytes") }
                guard !Self.transportHeaders.contains(key) else { throw CDPError.invalidParams("Unsupported response header: \(name)") }
                if base != nil, Self.isPolicyHeader(key) { throw CDPError.invalidParams("Cannot replace the original response policy: \(name)") }
                if let old = result.headers.keys.first(where: { $0.lowercased() == key }) { result.headers.removeValue(forKey: old) }
                result.headers[name] = value
            }
        }
        if !reusing && result.header("Content-Type") == nil { result.headers["Content-Type"] = FetchPayload.mime(url) }
        return result
    }

    private static let transportHeaders: Set<String> = ["set-cookie", "set-cookie2", "www-authenticate", "proxy-authenticate",
        "authentication-info", "proxy-authentication-info", "connection", "proxy-connection", "transfer-encoding",
        "content-encoding", "upgrade", "trailer", "refresh", "location", "link", "clear-site-data"]
    private static func isPolicyHeader(_ key: String) -> Bool {
        key.hasPrefix("access-control-") || key.hasPrefix("cross-origin-") || key.hasPrefix("content-security-") ||
            ["x-content-security-policy", "x-webkit-csp", "x-content-type-options", "x-frame-options", "referrer-policy",
             "permissions-policy", "document-policy", "feature-policy", "origin-agent-cluster", "timing-allow-origin",
             "service-worker-allowed", "content-type", "content-location", "content-disposition"].contains(key)
    }

    private func removeStored(_ list: WKContentRuleList) {
        Self.ruleStore?.removeContentRuleList(forIdentifier: list.identifier) { _ in }
    }
    private func dropRules(_ sid: String) {
        if let list = rules.removeValue(forKey: sid) { owner?.webView.configuration.userContentController.remove(list); removeStored(list) }
    }
    func release(_ sid: String) {
        versions[sid] = nil; checking[sid] = nil
        guard enabled.removeValue(forKey: sid) != nil else { return }
        dropRules(sid); refreshOrigins()
        if !active && !mapped { preparing?.cancel(); preparing = nil; scope?.rotateHosts() }
        for j in Array(jobs.values) {
            j.forceResponse.remove(sid)
            if !authorized(j) { fail(j, URLError(.cancelled)) }
            else if j.pausedBy == sid { unpause(j); advance(j) }
        }
    }
    func cancelAll() {
        preparing?.cancel(); preparing = nil
        for j in Array(jobs.values) { fail(j, URLError(.cancelled)) }
    }
    func close() {
        closed = true; invalidateNavigation()
        for sid in Array(rules.keys) { dropRules(sid) }
        enabled.removeAll(); versions.removeAll(); scope = nil; network.close()
    }

    func webView(_ webView: WKWebView, start t: WKURLSchemeTask) {
        guard !closed, active || mapped, let owner, let scope, let virtual = t.request.url, let u = scope.unmap(virtual),
              scope.grants(t.request.mainDocumentURL), sameTop(t.request.mainDocumentURL, approvedTop),
              !allowedChild, jobs.count < 256 else { t.didFailWithError(URLError(.noPermissionsToReadFile)); return }
        let main = expectingMain && scope.grants(virtual) && virtual.host == scope.host
        if !main && ["iframe","frame","document","object","embed"].contains(t.request.value(forHTTPHeaderField: "Sec-Fetch-Dest") ?? "") {
            t.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }
        let hint = scope.typeHint(virtual)
        let type = main ? "Document" : hint.flatMap { FetchPattern.types.contains($0) ? $0 : nil } ?? FetchRouting.type(u, request: t.request)
        guard main || type != "Document",
              main || virtual.host != scope.host || scope.permitsLocalRead(t.request, isolatedMain: approvedTop != nil && !allowedChild),
              (mapped && virtual.host == scope.host) || patterns.contains(where: { $0.matches(u, type) }) else {
            t.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }
        if main { expectingMain = false }
        let j = Job(t, url: u, type: type, main: main, loader: owner.fetchLoader)
        jobs[j.key] = j
        owner.emit("Network","Network.requestWillBeSent", ["requestId": j.netID, "loaderId": j.loader, "documentURL": scope.document.absoluteString,
                  "request": requestJSON(j), "timestamp": monotonicSeconds(), "wallTime": Date().timeIntervalSince1970,
                  "initiator": ["type": main ? "other" : "parser"], "redirectHasExtraInfo": false, "type": type, "frameId": owner.frameId, "hasUserGesture": false])
        advance(j)
    }

    func webView(_ webView: WKWebView, stop t: WKURLSchemeTask) {
        // WebKit will raise an Objective-C exception on *any* further callback for this task.
        if let j = jobs[ObjectIdentifier(t)] { fail(j, URLError(.cancelled), stopped: true) }
    }
    private func requestJSON(_ j: Job) -> JSON {
        let h = (j.request.allHTTPHeaderFields ?? [:]).filter {
            FetchAssetNetwork.permitsHeader($0.key, local: true) ||
                ["content-type","sec-fetch-site","sec-fetch-mode","sec-fetch-dest","sec-fetch-user"].contains($0.key.lowercased())
        }
        return ["url": j.original.absoluteString, "method": j.request.httpMethod ?? "GET", "headers": h,
                "initialPriority": j.main ? "VeryHigh" : "Medium", "referrerPolicy": "no-referrer"]
    }
    private func unpause(_ j: Job) {
        if let id = j.pauseID { pauses[id] = nil }
        j.deadline?.cancel(); j.deadline = nil; j.pauseID = nil; j.pausedBy = nil
    }
    private func authorized(_ j: Job) -> Bool {
        guard !closed, !allowedChild, active || mapped, let scope, let v = j.task.request.url,
              sameTop(j.task.request.mainDocumentURL, approvedTop), scope.unmap(v) == j.original else { return false }
        return (mapped && v.host == scope.host) || patterns.contains { $0.matches(j.original, j.type) }
    }
    private func advance(_ j: Job) {
        guard jobs[j.key] === j, let owner, let scope else { return }
        guard authorized(j) else { fail(j, URLError(.cancelled)); return }
        let atResponse = j.payload != nil
        if let s = owner.target.sessions.first(where: { s in
            guard !j.answered.contains(s.id), let pp = enabled[s.id] else { return false }
            return (atResponse && j.forceResponse.contains(s.id)) || pp.contains { $0.response == atResponse && $0.matches(j.original, j.type) }
        }) {
            let id = "interception-" + newHexId()
            j.answered.insert(s.id); j.pausedBy = s.id; j.pauseID = id; pauses[id] = j
            var event: JSON = ["requestId": id, "networkId": j.netID, "frameId": owner.frameId, "resourceType": j.type, "request": requestJSON(j)]
            if let r = j.payload {
                event["responseStatusCode"] = r.status; event["responseStatusText"] = r.reason
                event["responseHeaders"] = r.headers.map { ["name": $0.key,"value": $0.value] }
            }
            owner.server.send(event: "Fetch.requestPaused", event, sessionId: s.id)
            j.deadline = Task { @MainActor [weak self, weak j] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                if let j, j.pauseID == id { self?.fail(j, URLError(.timedOut)) }
            }
        } else if let r = j.payload { deliver(j, r) }
        else {
            if let u = j.request.url, !u.isFileURL, FetchScope.origin(u) != FetchScope.origin(scope.document),
               !(FetchScope.publicGSAP(j.original) && FetchScope.publicGSAP(u)) {
                fail(j, URLError(.unsupportedURL), text: "net::ERR_BLOCKED_BY_CLIENT")
                return
            }
            j.worker = Task { @MainActor [weak self, weak j] in
                guard let self, let j, self.jobs[j.key] === j, self.authorized(j), !Task.isCancelled else { return }
                do {
                    let r = try await self.network.read(j.request, scope: scope, main: j.main)
                    guard self.jobs[j.key] === j else { return }
                    j.worker = nil; j.payload = r; j.answered.removeAll(); self.advance(j)
                } catch { if self.jobs[j.key] === j { self.fail(j, error) } }
            }
        }
    }
    private func remove(_ j: Job) {
        unpause(j); j.worker?.cancel(); j.worker = nil; jobs[j.key] = nil
    }
    private func fail(_ j: Job, _ error: Error, text: String? = nil, stopped: Bool = false) {
        guard jobs[j.key] === j else { return }
        remove(j)
        owner?.emit("Network","Network.loadingFailed", ["requestId": j.netID, "timestamp": monotonicSeconds(), "type": j.type,
                    "errorText": text ?? PageContent.netError(error), "canceled": (error as NSError).code == NSURLErrorCancelled])
        if !stopped { j.task.didFailWithError(error) }
    }

    private func deliver(_ j: Job, _ data: FetchPayload) {
        guard jobs[j.key] === j, let scope, let owner, let virtual = j.task.request.url else { return }
        var r = data
        if r.mime == "text/html" || r.mime == "application/xhtml+xml" {
            // A remapped origin cannot promise equivalence for arbitrary host/scheme CSP source
            // expressions. Fail closed instead of weakening policy or rewriting a remote document.
            guard virtual.host == scope.host, FetchRouting.safeCSP(r.header("Content-Security-Policy") ?? ""),
                  !FetchRouting.unsafeMetaPolicy(r.body) else {
                fail(j, URLError(.noPermissionsToReadFile)); return
            }
            r.body = FetchRouting.html(r.body, at: j.request.url ?? j.original, scope: scope, patterns: patterns)
        }
        var h = r.headers.filter { !Self.transportHeaders.contains($0.key.lowercased()) && !["content-length","referrer-policy"].contains($0.key.lowercased()) }
        if j.main && (r.mime == "text/html" || r.mime == "application/xhtml+xml") { h = FetchRouting.singleFrameHeaders(h) }
        h["Content-Length"] = j.request.httpMethod == "HEAD" ? (r.header("Content-Length") ?? "0") : "\(r.body.count)"
        h["Referrer-Policy"] = "no-referrer"
        if !mapped, virtual.host == scope.host, !scope.document.isFileURL,
           let origin = j.task.request.value(forHTTPHeaderField: "Origin"), let o = URL(string: origin),
           FetchScope.origin(o) == FetchScope.origin(scope.document), r.header("Access-Control-Allow-Origin") == nil {
            // It was a same-origin request on this already-loaded native document. Expose its
            // normal response headers only to that exact, non-opaque origin, never "*" / "null".
            h["Access-Control-Allow-Origin"] = origin
            if r.header("Access-Control-Expose-Headers") == nil {
                h["Access-Control-Expose-Headers"] = h.keys.filter { !$0.lowercased().hasPrefix("access-control-") }.joined(separator: ",")
            }
        }
        guard let resp = HTTPURLResponse(url: virtual, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: h) else {
            fail(j, URLError(.badServerResponse)); return
        }
        owner.emit("Network","Network.responseReceived", ["requestId": j.netID, "loaderId": j.loader, "timestamp": monotonicSeconds(),
                   "type": j.type, "frameId": owner.frameId, "hasExtraInfo": false,
                   "response": ["url": j.original.absoluteString, "status": r.status, "statusText": r.reason, "headers": r.headers,
                                "mimeType": r.mime, "connectionReused": false, "connectionId": 0, "encodedDataLength": r.body.count, "securityState": "unknown"] as JSON])
        j.task.didReceive(resp)
        if jobs[j.key] === j, j.request.httpMethod != "HEAD", !r.body.isEmpty { j.task.didReceive(r.body) }
        guard jobs[j.key] === j else { return }
        remove(j); j.task.didFinish()
        owner.emit("Network","Network.loadingFinished", ["requestId": j.netID, "timestamp": monotonicSeconds(), "encodedDataLength": r.body.count])
    }

}
