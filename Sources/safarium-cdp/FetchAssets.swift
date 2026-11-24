import Darwin
import Foundation
import UniformTypeIdentifiers

/// An origin grant is minted only by a CDP navigation to a renderer input. A URL from page JS
/// is never itself a grant. The random WebKit origins are different for every target/navigation
/// and for every external asset origin. There is no listening socket, global URLProtocol or proxy.
struct FetchScope {
    static let scheme = "safarium-asset"
    let document: URL
    private(set) var host = newHexId().lowercased()
    private let documentPath: [String]?
    let directory: FileHandle?
    private let singleFile: Bool
    private(set) var external: [String: URL] = [:] // virtual host -> original origin

    init?(_ url: URL) {
        guard url.user == nil, url.password == nil else { return nil }
        if url.isFileURL {
            guard Self.localFile(url), !url.hasDirectoryPath, let path = Self.pathParts(url), !path.isEmpty else { return nil }
            let root = url.deletingLastPathComponent()
            guard Self.pathParts(root) == Array(path.dropLast()), let (handle, isRoot) = Self.openRoot(root) else { return nil }
            documentPath = path
            directory = handle; singleFile = isRoot
        } else {
            guard url.scheme == "http", Self.isRendererHost(url.host) else { return nil }
            documentPath = nil; directory = nil; singleFile = false
        }
        document = url
    }

    private static func localFile(_ u: URL) -> Bool {
        u.isFileURL && u.user == nil && u.password == nil && u.port == nil &&
            ["", "localhost"].contains(u.host?.lowercased() ?? "")
    }

    // A URL namespace is lexical. Do not re-resolve it against the live filesystem
    // after acquiring the directory descriptor (including on a project move/reload).
    private static func pathParts(_ url: URL) -> [String]? {
        guard let raw = URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath, raw.hasPrefix("/") else { return nil }
        var parts: [String] = []
        for encoded in raw.split(separator: "/") {
            guard let name = String(encoded).removingPercentEncoding, !name.contains("/"), !name.utf8.contains(0) else { return nil }
            if name == "." { continue }
            if name == ".." { guard !parts.isEmpty else { return nil }; parts.removeLast() }
            else { parts.append(name) }
        }
        return parts
    }

    private static func openRoot(_ root: URL) -> (FileHandle, Bool)? {
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        guard !root.path.utf8.contains(0), let canonical = realpath(root.path, nil) else { return nil }
        defer { free(canonical) }
        let rootFD = open("/", flags)
        guard rootFD >= 0 else { return nil }
        var fd = rootFD, filesystem = stat(), selected = stat()
        defer { close(fd) }
        guard fstat(fd, &filesystem) == 0 else { return nil }
        // Resolve ordinary platform aliases (e.g. /var), then walk that canonical path
        // without following a replacement link at any depth, including during bootstrap.
        for name in (String(cString: canonical) as NSString).pathComponents.dropFirst() {
            guard name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { return nil }
            let next = openat(fd, name, flags)
            guard next >= 0 else { return nil }
            close(fd); fd = next
        }
        guard fstat(fd, &selected) == 0 else { return nil }
        let copy = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { return nil }
        return (FileHandle(fileDescriptor: copy, closeOnDealloc: true),
                filesystem.st_dev == selected.st_dev && filesystem.st_ino == selected.st_ino)
    }

    static func isVirtualRenderer(_ url: URL) -> Bool { url.host?.lowercased().hasSuffix(".localhost") == true }

    static func isRendererHost(_ name: String?) -> Bool {
        guard let h = name?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "[::1]", "::1"].contains(h) ||
            h.range(of: #"^hyperframes-[0-9]+\.localhost$"#, options: .regularExpression) != nil
    }

    static func origin(_ url: URL) -> String? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: true), let s = c.scheme?.lowercased(),
              let h = c.host?.lowercased(), !h.isEmpty, c.user == nil, c.password == nil else { return nil }
        let port = c.port ?? (s == "http" ? 80 : 443)
        return "\(s)://\(h):\(port)"
    }

    static func sameNavigation(_ first: URL?, _ second: URL?) -> Bool {
        func normalized(_ u: URL?) -> URL? {
            guard let u, var c = URLComponents(url: u, resolvingAgainstBaseURL: true) else { return nil }
            c.fragment = nil
            if ["http", "https", scheme].contains(c.scheme?.lowercased() ?? "") {
                c.host = c.host?.lowercased()
                if c.percentEncodedPath.isEmpty { c.percentEncodedPath = "/" }
                if (c.scheme == "http" && c.port == 80) || (c.scheme == "https" && c.port == 443) { c.port = nil }
            }
            return c.url
        }
        guard let a = normalized(first), let b = normalized(second) else { return false }
        return a == b
    }

    mutating func updateOrigins(_ origins: [URL]) {
        let wanted = Set(origins.compactMap(Self.origin))
        external = external.filter { Self.origin($0.value).map(wanted.contains) == true }
        for u in origins { addExternal(u) }
    }

    mutating func rotateHosts() { host = newHexId().lowercased(); external.removeAll() }

    private mutating func addExternal(_ u: URL) {
        // This map grants a separate virtual origin for synthetic fulfill/fail
        // responses only. A second localhost port is just as foreign as a CDN.
        // Reads in FetchAssetNetwork independently require the original document
        // origin (or the specific public GSAP asset); this map cannot grant them.
        guard ["https", "http"].contains(u.scheme), let key = Self.origin(u),
              key != Self.origin(document),
              !external.values.contains(where: { Self.origin($0) == key }) else { return }
        var c = URLComponents(url: u, resolvingAgainstBaseURL: true)!
        c.path = "/"; c.query = nil; c.fragment = nil
        external[newHexId().lowercased()] = c.url
    }

    func fileComponents(_ u: URL) -> [String]? {
        guard let documentPath, Self.localFile(u), let path = Self.pathParts(u) else { return nil }
        let base = documentPath.dropLast()
        guard path.count > base.count, path.starts(with: base),
              !singleFile || path == documentPath else { return nil }
        return Array(path.dropFirst(base.count))
    }

    var typeKey: String { "__sf_" + host }
    func map(_ real: URL, type: String? = nil) -> URL? {
        guard real.user == nil, real.password == nil, var c = URLComponents(url: real, resolvingAgainstBaseURL: true) else { return nil }
        let destination: String
        if real.isFileURL {
            guard fileComponents(real) != nil else { return nil }; destination = host
        } else if Self.origin(real) == Self.origin(document), !document.isFileURL {
            destination = host
        } else if let k = external.first(where: { Self.origin($0.value) == Self.origin(real) })?.key {
            destination = k
        } else { return nil }
        c.scheme = Self.scheme; c.host = destination; c.port = nil
        if let type { c.percentEncodedQuery = (c.percentEncodedQuery.map { $0 + "&" } ?? "") + "\(typeKey)=\(type)" }
        return c.url
    }

    func unmap(_ mapped: URL) -> URL? {
        guard mapped.scheme == Self.scheme, mapped.user == nil, mapped.password == nil, mapped.port == nil,
              let h = mapped.host, let base = h == host ? document : external[h],
              var c = URLComponents(url: base, resolvingAgainstBaseURL: true),
              let m = URLComponents(url: mapped, resolvingAgainstBaseURL: true) else { return nil }
        c.percentEncodedPath = m.percentEncodedPath; c.percentEncodedFragment = m.percentEncodedFragment
        var query = m.percentEncodedQuery?.components(separatedBy: "&") ?? []
        if query.last?.hasPrefix(typeKey + "=") == true { query.removeLast() }
        c.percentEncodedQuery = query.isEmpty ? nil : query.joined(separator: "&")
        guard let url = c.url, !url.isFileURL || fileComponents(url) != nil else { return nil }
        return url
    }

    func typeHint(_ mapped: URL) -> String? {
        let last = URLComponents(url: mapped, resolvingAgainstBaseURL: true)?.percentEncodedQuery?.components(separatedBy: "&").last
        return last?.hasPrefix(typeKey + "=") == true ? String(last!.dropFirst(typeKey.count + 1)) : nil
    }

    /// Only the local document selected by CDP (or its mapped counterpart) may use this page's handler.
    func grants(_ main: URL?) -> Bool {
        guard let main else { return false }
        let actual = unmap(main) ?? main
        if actual.isFileURL, document.isFileURL {
            guard Self.localFile(actual), let documentPath, Self.pathParts(actual) == documentPath,
                  let a = URLComponents(url: actual, resolvingAgainstBaseURL: true),
                  let b = URLComponents(url: document, resolvingAgainstBaseURL: true) else { return false }
            return a.percentEncodedQuery == b.percentEncodedQuery
        }
        return Self.sameNavigation(actual, document)
    }

    /// The main-document field and capability are checked separately. If WebKit also identifies
    /// an initiator, don't let a foreign/opaque frame turn an embedded resource into a local read.
    func permitsLocalRead(_ r: URLRequest, isolatedMain: Bool) -> Bool {
        // Parser loads often carry neither header. Only the navigation delegate's single-frame
        // boundary can authorize that case; mainDocumentURL alone is not an initiator.
        guard isolatedMain else { return false }
        for key in ["Origin", "Referer"] {
            guard let value = r.value(forHTTPHeaderField: key), !value.isEmpty else { continue }
            guard let u = URL(string: value), value != "null" else { return false }
            if u.scheme == Self.scheme && u.host == host && u.port == nil && u.user == nil && u.password == nil { continue }
            if document.isFileURL && u.isFileURL && grants(u) { continue }
            if !document.isFileURL && Self.origin(u) == Self.origin(document) { continue }
            return false
        }
        return true
    }

    /// A narrow public-network continuation for HyperFrames' bundled GSAP fallback. All other
    /// explicitly named external assets are fulfill/fail only. No arbitrary remote URLSession.
    static func publicGSAP(_ u: URL) -> Bool {
        guard u.scheme == "https", u.host?.lowercased() == "cdn.jsdelivr.net", (u.port ?? 443) == 443,
              u.user == nil, u.password == nil, u.query == nil,
              let path = URLComponents(url: u, resolvingAgainstBaseURL: false)?.percentEncodedPath else { return false }
        return path.range(of: #"^/npm/gsap@[0-9]+\.[0-9]+\.[0-9]+/dist/[A-Za-z0-9_-]+(\.min)?\.js(\.map)?$"#,
                          options: .regularExpression) != nil
    }
}

struct FetchPayload {
    static let limit = 64 * 1024 * 1024
    var status: Int
    var headers: [String: String]
    var body: Data
    var reason = ""
    func header(_ name: String) -> String? { headers.first { $0.key.lowercased() == name.lowercased() }?.value }
    var mime: String { header("Content-Type")?.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "application/octet-stream" }

    static func mime(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "js", "mjs", "cjs": return "text/javascript"
        case "css": return "text/css"
        case "html", "htm": return "text/html; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    static func file(scope: FetchScope, request: URLRequest) throws -> Self {
        try Task.checkCancellation()
        guard let u = request.url, let directory = scope.directory, let names = scope.fileComponents(u), !names.isEmpty,
              ["GET", "HEAD"].contains(request.httpMethod ?? "GET") else { throw URLError(.noPermissionsToReadFile) }
        // openat + O_NOFOLLOW for *every* component: even a symlink swap during a request cannot
        // escape the selected folder. Never read from a directory, named pipe or device.
        var fd = fcntl(directory.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard fd >= 0 else { throw URLError(.fileDoesNotExist) }
        defer { close(fd) }
        for (i, name) in names.enumerated() {
            try Task.checkCancellation()
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else { throw URLError(.noPermissionsToReadFile) }
            let next = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC | (i == names.count - 1 ? 0 : O_DIRECTORY))
            guard next >= 0 else { throw URLError(errno == ENOENT ? .fileDoesNotExist : .noPermissionsToReadFile) }
            close(fd); fd = next
        }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw URLError(.noPermissionsToReadFile) }
        let size = Int(st.st_size)
        var head = ["Content-Type": mime(u), "Accept-Ranges": "bytes", "Content-Length": "\(size)"]
        var start = 0, length = size, code = 200
        if let range = request.value(forHTTPHeaderField: "Range") {
            guard let r = byteRange(range, size: size) else {
                head["Content-Range"] = "bytes */\(size)"; head["Content-Length"] = "0"
                return Self(status: 416, headers: head, body: Data())
            }
            start = r.lowerBound; length = r.count; code = 206
            head["Content-Range"] = "bytes \(start)-\(r.upperBound - 1)/\(size)"; head["Content-Length"] = "\(length)"
        }
        if request.httpMethod == "HEAD" { return Self(status: code, headers: head, body: Data()) }
        guard length <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.seek(toOffset: UInt64(start))
        var bytes = Data()
        while bytes.count < length {
            try Task.checkCancellation()
            guard let part = try handle.read(upToCount: min(length - bytes.count, 256 * 1024)), !part.isEmpty else {
                throw URLError(.cannotDecodeContentData)
            }
            bytes.append(part)
        }
        return Self(status: code, headers: head, body: bytes)
    }

    private static func byteRange(_ s: String, size: Int) -> Range<Int>? {
        guard s.hasPrefix("bytes="), size > 0 else { return nil }
        let p = s.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 2, p.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        if p[0].isEmpty { guard let n = Int(p[1]), n > 0 else { return nil }; return max(0, size - n)..<size }
        guard let lo = Int(p[0]), lo >= 0, lo < size else { return nil }
        if p[1].isEmpty { return lo..<size }
        guard let hi = Int(p[1]), hi >= lo else { return nil }
        return lo..<(min(hi, size - 1) + 1)
    }
}

/// The URLSession API exposes the raw network only for a granted read. Never follow redirects,
/// load a credential/cookie jar, or give client pages a way to supply proxy/authentication headers.
final class FetchAssetNetwork: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let requestHeaders: Set<String> = ["accept", "accept-language", "range", "if-range", "if-none-match", "if-modified-since", "cache-control"]
    static func permitsHeader(_ name: String, local: Bool) -> Bool {
        // This diagnostic has a checked round trip in the renderer fixture; do not
        // generalize it to arbitrary X-* authentication or routing headers.
        requestHeaders.contains(name.lowercased()) || (local && name.lowercased() == "x-fixture-probe")
    }
    static let privateHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie", "cookie2",
        "set-cookie", "set-cookie2", "www-authenticate", "proxy-authenticate", "authentication-info", "proxy-authentication-info"]
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCredentialStorage = nil; c.urlCache = nil
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForRequest = 12; c.timeoutIntervalForResource = 20
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    @MainActor func close() { session.invalidateAndCancel() }
    @MainActor func read(_ request: URLRequest, scope: FetchScope, main: Bool) async throws -> FetchPayload {
        try Task.checkCancellation()
        guard let url = request.url, ["GET", "HEAD"].contains(request.httpMethod ?? "GET"),
              url.user == nil, url.password == nil else { throw URLError(.unsupportedURL) }
        if url.isFileURL {
            let work = Task.detached { try FetchPayload.file(scope: scope, request: request) }
            return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
        }
        let local = !scope.document.isFileURL && FetchScope.origin(url) == FetchScope.origin(scope.document)
        let mayReadCDN = ProcessInfo.processInfo.environment["SAFARIUM_FETCH_OFFLINE"] != "1" && FetchScope.publicGSAP(url)
        guard local || mayReadCDN else { throw URLError(.unsupportedURL) }
        // .localhost virtual origins are answered by the debugger, never resolved through DNS.
        guard !FetchScope.isVirtualRenderer(url) else { throw URLError(.cannotFindHost) }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        r.httpMethod = request.httpMethod; r.httpShouldHandleCookies = false
        if main && local {
            r.setValue("none", forHTTPHeaderField: "Sec-Fetch-Site")
            r.setValue("document", forHTTPHeaderField: "Sec-Fetch-Dest")
        }
        for (k, v) in request.allHTTPHeaderFields ?? [:] {
            if Self.permitsHeader(k, local: local) {
                r.setValue(v, forHTTPHeaderField: k)
            }
        }
        let (tmp, response) = try await session.download(for: r, delegate: self)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let h = response as? HTTPURLResponse, !(300...399).contains(h.statusCode) || h.statusCode == 304 else { throw URLError(.httpTooManyRedirects) }
        var headers = [String: String]()
        for (k, v) in h.allHeaderFields {
            let key = String(describing: k)
            guard !Self.privateHeaders.contains(key.lowercased()), !["connection", "transfer-encoding", "content-encoding"].contains(key.lowercased()) else { continue }
            headers[key] = String(describing: v)
        }
        guard (try tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= FetchPayload.limit else { throw URLError(.dataLengthExceedsMaximum) }
        let body = try Data(contentsOf: tmp, options: .mappedIfSafe)
        return FetchPayload(status: h.statusCode, headers: headers, body: body)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if max(totalBytesWritten, totalBytesExpectedToWrite) > FetchPayload.limit { downloadTask.cancel() }
    }
}
