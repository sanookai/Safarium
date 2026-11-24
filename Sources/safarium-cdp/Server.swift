import AppKit
import Foundation
import SafariumCore

/// One CDP flat session (browser-level sessions have no target).
@MainActor final class Session {
    let id: String
    let target: Target?
    let parentSessionId: String?
    var enabled = Set<String>()
    var lifecycleEvents = false
    var autoAttach = false
    init(id: String, target: Target?, parentSessionId: String?) { self.id = id; self.target = target; self.parentSessionId = parentSessionId }
}

@MainActor final class Target {
    enum Kind: String { case page, tab }
    let id = newHexId()
    let kind: Kind
    weak var tab: Target?         // for a page
    var child: Target?            // for a tab
    var sessions: [Session] = []
    var content: PageContent?
    var contentTask: Task<PageContent, Error>?
    var title = ""
    var url = ""
    init(kind: Kind) { self.kind = kind }
}

@MainActor final class Server {
    let transport: PipeTransport
    let options: Options
    let browserContextId = newHexId()
    var targets: [String: Target] = [:]
    var targetOrder: [String] = []
    var sessions: [String: Session] = [:]
    var discover = false
    var browserAutoAttach = false
    var exiting = false

    init(transport: PipeTransport, options: Options) {
        self.transport = transport
        self.options = options
        let tab = Target(kind: .tab), page = Target(kind: .page)
        tab.child = page; page.tab = tab
        tab.url = "about:blank"; page.url = "about:blank"; page.title = "about:blank"
        register(page); register(tab)
    }

    private func register(_ t: Target) { targets[t.id] = t; targetOrder.append(t.id) }

    // MARK: transport

    func send(event method: String, _ params: JSON, sessionId: String? = nil) {
        var m: JSON = ["method": method, "params": params]
        if let s = sessionId { m["sessionId"] = s }
        transport.send(m)
    }

    private func reply(id: Int, sessionId: String?, result: JSON?, error: CDPError?) {
        var m: JSON = ["id": id]
        if let e = error { m["error"] = ["code": e.code, "message": e.message] } else { m["result"] = result ?? [:] }
        if let s = sessionId { m["sessionId"] = s }
        transport.send(m)
    }

    func receive(_ m: JSON) {
        guard let id = m["id"] as? Int, let method = m["method"] as? String else { return }
        let sid = m["sessionId"] as? String
        let params = m["params"] as? JSON ?? [:]
        Task { @MainActor in
            do {
                var session: Session?
                if let sid = sid {
                    guard let s = sessions[sid] else { throw CDPError(code: -32001, message: "Session with given id not found.") }
                    session = s
                }
                let result = try await dispatch(session, method, params)
                reply(id: id, sessionId: sid, result: result, error: nil)
                if method == "Browser.close" { shutdown() }
            } catch let e as CDPError {
                if e.code == -32601 { Unsupported.record(method) }
                reply(id: id, sessionId: sid, result: nil, error: e)
            } catch {
                reply(id: id, sessionId: sid, result: nil, error: .server(String(describing: error)))
            }
        }
    }

    // MARK: target info / events

    func info(_ t: Target) -> JSON {
        [
            "targetId": t.id, "type": t.kind.rawValue,
            "title": t.kind == .tab ? (t.child?.title ?? "") : t.title,
            "url": t.url, "attached": !t.sessions.isEmpty, "canAccessOpener": false,
            "browserContextId": browserContextId,
        ]
    }

    func emitBrowser(_ method: String, _ params: JSON) { if discover { send(event: method, params) } }
    func emitCreated(_ t: Target) { emitBrowser("Target.targetCreated", ["targetInfo": info(t)]) }
    func emitInfoChanged(_ t: Target) { emitBrowser("Target.targetInfoChanged", ["targetInfo": info(t)]) }

    @discardableResult
    func attach(_ t: Target, parent: Session?) -> Session {
        let s = Session(id: newHexId(), target: t, parentSessionId: parent?.id)
        sessions[s.id] = s
        t.sessions.append(s)
        return s
    }

    /// Announce a new session on the parent's channel (browser level when `parent` is nil).
    func announce(_ s: Session, waitingForDebugger: Bool, parent: Session?) {
        guard let t = s.target else { return }
        emitInfoChanged(t)
        send(event: "Target.attachedToTarget",
             ["sessionId": s.id, "targetInfo": info(t), "waitingForDebugger": waitingForDebugger], sessionId: parent?.id)
    }

    @discardableResult
    func detach(_ s: Session, emit: Bool = true) -> [PageContent] {
        guard sessions[s.id] === s, let t = s.target else { return [] }
        var affected = [PageContent]()
        for child in sessions.values.filter({ $0.parentSessionId == s.id }) {
            affected += detach(child, emit: emit)
        }
        sessions[s.id] = nil
        t.sessions.removeAll { $0 === s }
        if let c = t.content {
            c.fetch.release(s.id)
            if c.fetch.scope != nil { affected.append(c) }
        }
        if emit { send(event: "Target.detachedFromTarget", ["sessionId": s.id, "targetId": t.id], sessionId: s.parentSessionId) }
        return affected
    }

    func destroy(_ t: Target) {
        guard targets.removeValue(forKey: t.id) != nil else { return }
        t.contentTask?.cancel(); t.contentTask = nil
        t.content?.dispose()
        for s in t.sessions { detach(s) }
        emitInfoChanged(t)
        emitBrowser("Target.targetDestroyed", ["targetId": t.id])
        t.content = nil
        targetOrder.removeAll { $0 == t.id }
    }

    func closeTarget(_ t: Target) {
        let page = t.kind == .page ? t : (t.child ?? t)
        let tab = page.tab
        destroy(page)
        if let tab = tab { destroy(tab) }
    }

    func shutdown() {
        exiting = true
        for id in targetOrder.reversed() { if let t = targets[id], t.kind == .page { closeTarget(t) } }
        transport.flush()
        exit(0)
    }

    func target(_ id: String?) throws -> Target {
        guard let id = id, let t = targets[id] else { throw CDPError.server("No target with given id found") }
        return t
    }

    func ensureContent(_ page: Target) async throws -> PageContent {
        guard targets[page.id] === page else { throw CDPError.server("Target closed") }
        if let c = page.content { return c }
        if page.contentTask == nil {
            page.contentTask = Task { @MainActor in
                let c = try await PageContent.create(target: page, server: self)
                guard !Task.isCancelled, self.targets[page.id] === page else { c.dispose(); throw CDPError.server("Target closed") }
                page.content = c
                return c
            }
        }
        let content = try await page.contentTask!.value
        guard targets[page.id] === page else { throw CDPError.server("Target closed") }
        return content
    }

    // MARK: dispatch

    func dispatch(_ session: Session?, _ method: String, _ p: JSON) async throws -> JSON {
        switch method {
        case "Browser.getVersion":
            return ["protocolVersion": "1.3", "product": "Safarium/\(shimVersion)", "revision": "webkit",
                    "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Safarium/\(shimVersion)",
                    "jsVersion": "JavaScriptCore"]
        case "Browser.close": return [:]
        case "Target.setDiscoverTargets":
            discover = (p["discover"] as? Bool) ?? false
            if discover {
                for id in targetOrder { if let t = targets[id], t.kind == .page { emitCreated(t) } }
                for id in targetOrder { if let t = targets[id], t.kind == .tab { emitCreated(t) } }
            }
            return [:]
        case "Target.setAutoAttach":
            let on = (p["autoAttach"] as? Bool) ?? false
            if let s = session {
                s.autoAttach = on
                if on, let t = s.target, t.kind == .tab, let page = t.child, page.sessions.allSatisfy({ $0.parentSessionId != s.id }) {
                    let ps = attach(page, parent: s)
                    announce(ps, waitingForDebugger: true, parent: s)
                }
            } else {
                browserAutoAttach = on
                if on {
                    for id in targetOrder {
                        if let t = targets[id], t.kind == .tab, t.sessions.isEmpty {
                            announce(attach(t, parent: nil), waitingForDebugger: true, parent: nil)
                        }
                    }
                }
            }
            return [:]
        case "Runtime.runIfWaitingForDebugger" where session?.target?.kind == .tab: return [:]
        case "Target.createTarget":
            let tab = Target(kind: .tab), page = Target(kind: .page)
            tab.child = page; page.tab = tab
            tab.url = ""; page.url = ""
            register(tab); register(page)
            emitCreated(tab)
            if browserAutoAttach { announce(attach(tab, parent: nil), waitingForDebugger: true, parent: nil) }
            emitCreated(page)
            let content = try await ensureContent(page)
            page.url = content.url; page.title = content.title
            tab.url = content.url
            emitInfoChanged(page)
            let url = (p["url"] as? String) ?? "about:blank"
            if url != "about:blank" && !url.isEmpty { _ = try await content.navigate(url) }
            guard targets[page.id] === page else { throw CDPError.server("Target closed") }
            return ["targetId": page.id]
        case "Target.attachToTarget":
            let t = try target(p["targetId"] as? String)
            let s = attach(t, parent: nil)
            send(event: "Target.attachedToTarget", ["sessionId": s.id, "targetInfo": info(t), "waitingForDebugger": false])
            return ["sessionId": s.id]
        case "Target.detachFromTarget":
            let sid = (p["sessionId"] as? String) ?? session?.id
            guard let sid = sid, let s = sessions[sid] else { throw CDPError.server("Session with given id not found.") }
            for c in detach(s) { try await c.refreshFetchScripts() }
            return [:]
        case "Target.closeTarget":
            closeTarget(try target(p["targetId"] as? String))
            return ["success": true]
        case "Target.getTargets":
            return ["targetInfos": targetOrder.compactMap { targets[$0] }.map { info($0) }]
        case "Target.getTargetInfo":
            let t = p["targetId"] == nil ? session?.target : (p["targetId"] as? String).flatMap { targets[$0] }
            guard let tt = t else { throw CDPError.server("No target with given id found") }
            return ["targetInfo": info(tt)]
        case "Target.activateTarget": return [:]
        case "SystemInfo.getProcessInfo":
            return ["processInfo": [["type": "browser", "id": Int(getpid()), "cpuTime": 0.0]]]
        default: break
        }
        guard let s = session, let t = s.target, t.kind == .page else { throw CDPError.methodNotFound(method) }
        let content = try await ensureContent(t)
        guard sessions[s.id] === s, targets[t.id] === t else { throw CDPError.server("Session or target closed") }
        return try await content.handle(s, method, p)
    }
}

// MARK: unsupported-method log

enum Unsupported {
    nonisolated(unsafe) private static var seen = Set<String>()
    static func record(_ method: String) {
        guard seen.insert(method).inserted else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) pid=\(getpid()) unsupported CDP method: \(method)\n"
        FileHandle.standardError.write(Data("[safarium-cdp] \(line)".utf8))
        let path = ProcessInfo.processInfo.environment["SAFARIUM_CDP_LOG"]
            ?? (NSHomeDirectory() + "/Library/Logs/Safarium/cdp-unsupported.log")
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let h = FileHandle(forWritingAtPath: path) ?? { FileManager.default.createFile(atPath: path, contents: nil); return FileHandle(forWritingAtPath: path) }() {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        }
    }
}
