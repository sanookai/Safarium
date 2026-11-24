import CoreGraphics
import CoreText
import Darwin
import Foundation
import ImageIO
import SafariumCore
import UniformTypeIdentifiers
import WebKit

// MARK: - Sandboxed Loopback Font & Asset Server

/// Lightweight `127.0.0.1` ephemeral-port HTTP asset & font server.
/// Canonicalizes resolved symlinks via `realpath`, rejects `..` traversal, non-regular files,
/// and ExFAT `._*` AppleDouble sidecars, percent-decodes Thai/Unicode paths, injects CORS
/// headers, generates `@font-face` rules, and stops deterministically on teardown.
public final class ForgeLoopbackFontServer: @unchecked Sendable {
    public struct FontFaceEntry: Codable, Sendable, Equatable {
        public let filename: String
        public let relativePath: String
        public let familyName: String
        public let style: String
        public let weight: String
        public let format: String
        public let urlString: String
    }

    private enum ResolveError: Error {
        case malformed(String)
        case forbidden(String)
        case notFound(String)

        var safariumError: SafariumError {
            switch self {
            case .malformed(let m), .forbidden(let m), .notFound(let m):
                return SafariumError.invalidState(m)
            }
        }
    }

    public let fontDirURL: URL
    public let canonicalFontDirPath: String
    public let htmlDirURL: URL?
    public let canonicalHTMLDirPath: String?

    private let stateLock = NSLock()
    private var _port: UInt16 = 0
    private var _isRunning = false
    private var stopping = false
    private var listenFD: Int32 = -1
    private var wakeReadFD: Int32 = -1
    private var wakeWriteFD: Int32 = -1
    private var acceptStoppedSem: DispatchSemaphore?
    private let connGroup = DispatchGroup()
    private let connQueue = DispatchQueue(label: "safarium.loopback.font.http", attributes: .concurrent)

    public var port: UInt16 {
        stateLock.withLock { _port }
    }

    public var isRunning: Bool {
        stateLock.withLock { _isRunning }
    }

    public var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    public init(fontDirURL: URL, htmlDirURL: URL? = nil) throws {
        self.fontDirURL = fontDirURL
        self.canonicalFontDirPath = try Self.canonicalizeDirectory(fontDirURL, label: "fontDirURL")
        self.htmlDirURL = htmlDirURL
        if let htmlDirURL {
            self.canonicalHTMLDirPath = try Self.canonicalizeDirectory(htmlDirURL, label: "htmlDirURL")
        } else {
            self.canonicalHTMLDirPath = nil
        }
    }

    deinit {
        stop()
    }

    private static func canonicalizeDirectory(_ url: URL, label: String) throws -> String {
        guard url.isFileURL else {
            throw SafariumError.invalidState("\(label) must be a file URL: \(url.absoluteString)")
        }
        guard let resolvedPtr = Darwin.realpath(url.path, nil) else {
            throw SafariumError.invalidState("\(label) directory does not exist: \(url.path)")
        }
        defer { free(resolvedPtr) }
        let resolved = String(cString: resolvedPtr)
        var st = stat()
        guard stat(resolved, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else {
            throw SafariumError.invalidState("\(label) is not a readable directory: \(resolved)")
        }
        return resolved
    }

    @discardableResult
    public func start() throws -> UInt16 {
        try stateLock.withLock {
            if _isRunning { return _port }
            stopping = false

            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else {
                let err = errno
                throw SafariumError.encode("loopback font server socket() failed: \(String(cString: strerror(err)))")
            }
            _ = Darwin.fcntl(fd, F_SETFD, FD_CLOEXEC)

            var yes: Int32 = 1
            _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var sin = sockaddr_in()
            sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sin.sin_family = sa_family_t(AF_INET)
            sin.sin_addr.s_addr = inet_addr("127.0.0.1")
            sin.sin_port = 0

            let bindRes = withUnsafePointer(to: &sin) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindRes == 0 else {
                let err = errno
                Darwin.close(fd)
                throw SafariumError.encode("loopback font server bind() failed: \(String(cString: strerror(err)))")
            }

            guard Darwin.listen(fd, 64) == 0 else {
                let err = errno
                Darwin.close(fd)
                throw SafariumError.encode("loopback font server listen() failed: \(String(cString: strerror(err)))")
            }

            var bound = sockaddr_in()
            var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let nameRes = withUnsafeMutablePointer(to: &bound) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.getsockname(fd, sa, &boundLen)
                }
            }
            guard nameRes == 0 else {
                let err = errno
                Darwin.close(fd)
                throw SafariumError.encode("loopback font server getsockname() failed: \(String(cString: strerror(err)))")
            }

            var pipes: [Int32] = [-1, -1]
            guard Darwin.pipe(&pipes) == 0 else {
                let err = errno
                Darwin.close(fd)
                throw SafariumError.encode("loopback font server pipe() failed: \(String(cString: strerror(err)))")
            }
            _ = Darwin.fcntl(pipes[0], F_SETFD, FD_CLOEXEC)
            _ = Darwin.fcntl(pipes[1], F_SETFD, FD_CLOEXEC)
            _ = Darwin.fcntl(pipes[0], F_SETFL, O_NONBLOCK)
            _ = Darwin.fcntl(pipes[1], F_SETFL, O_NONBLOCK)

            let boundPort = UInt16(bigEndian: bound.sin_port)
            let sem = DispatchSemaphore(value: 0)
            self.listenFD = fd
            self.wakeReadFD = pipes[0]
            self.wakeWriteFD = pipes[1]
            self.acceptStoppedSem = sem
            self._port = boundPort
            self._isRunning = true

            let acceptThread = Thread { [weak self] in
                self?.acceptLoop(listenFD: fd, wakeFD: pipes[0], stoppedSem: sem)
            }
            acceptThread.name = "safarium.loopback.font.accept.\(boundPort)"
            acceptThread.qualityOfService = .userInitiated
            acceptThread.start()
            return boundPort
        }
    }

    public func stop() {
        let (sem, lfd, rfd, wfd): (DispatchSemaphore?, Int32, Int32, Int32) = stateLock.withLock {
            if !_isRunning && listenFD < 0 { return (nil, -1, -1, -1) }
            stopping = true
            _isRunning = false
            _port = 0
            let s = acceptStoppedSem
            acceptStoppedSem = nil
            let l = listenFD; listenFD = -1
            let r = wakeReadFD; wakeReadFD = -1
            let w = wakeWriteFD; wakeWriteFD = -1
            return (s, l, r, w)
        }
        if wfd >= 0 {
            var byte: UInt8 = 1
            _ = Darwin.write(wfd, &byte, 1)
        }
        sem?.wait()
        connGroup.wait()
        if lfd >= 0 { Darwin.close(lfd) }
        if rfd >= 0 { Darwin.close(rfd) }
        if wfd >= 0 { Darwin.close(wfd) }
    }

    private func acceptLoop(listenFD: Int32, wakeFD: Int32, stoppedSem: DispatchSemaphore) {
        defer { stoppedSem.signal() }
        while true {
            if stateLock.withLock({ stopping }) { break }
            var pfds = [
                pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeFD, events: Int16(POLLIN), revents: 0),
            ]
            let rc = Darwin.poll(&pfds, 2, -1)
            if rc < 0 {
                if errno == EINTR { continue }
                break
            }
            if (pfds[1].revents & Int16(POLLIN)) != 0 || (pfds[1].revents & Int16(POLLHUP)) != 0 {
                break
            }
            if (pfds[0].revents & Int16(POLLIN)) != 0 {
                let cfd = Darwin.accept(listenFD, nil, nil)
                if cfd < 0 {
                    if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                    break
                }
                _ = Darwin.fcntl(cfd, F_SETFD, FD_CLOEXEC)
                var noSigPipe: Int32 = 1
                _ = Darwin.setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                var tv = timeval(tv_sec: 2, tv_usec: 0)
                _ = Darwin.setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                _ = Darwin.setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

                let group = connGroup
                group.enter()
                connQueue.async { [weak self] in
                    defer {
                        Darwin.close(cfd)
                        group.leave()
                    }
                    self?.handleClient(fd: cfd)
                }
            } else if (pfds[0].revents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 {
                break
            }
        }
    }

    private func handleClient(fd: Int32) {
        var reqBytes = Data()
        reqBytes.reserveCapacity(1024)
        var buf = [UInt8](repeating: 0, count: 4096)
        var headerEnd: Data.Index?

        while reqBytes.count < 65_536 {
            let n = buf.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress!, raw.count)
            }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                break
            }
            reqBytes.append(buf, count: n)
            if let r = reqBytes.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = r.lowerBound
                break
            }
        }

        guard let end = headerEnd else {
            sendError(fd: fd, status: "400 Bad Request", message: "Malformed HTTP request")
            return
        }
        let headerStr = String(decoding: reqBytes[..<end], as: UTF8.self)
        let firstLine = headerStr.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendError(fd: fd, status: "400 Bad Request", message: "Invalid request line")
            return
        }
        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])

        if method == "OPTIONS" {
            let hdr = """
            HTTP/1.1 204 No Content\r
            Access-Control-Allow-Origin: *\r
            Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r
            Access-Control-Allow-Headers: *\r
            Cross-Origin-Resource-Policy: cross-origin\r
            Cache-Control: no-store\r
            Content-Length: 0\r
            Connection: close\r
            \r\n
            """
            Self.writeAll(fd: fd, data: Data(hdr.utf8))
            return
        }

        guard method == "GET" || method == "HEAD" else {
            sendError(fd: fd, status: "405 Method Not Allowed", message: "Method not allowed")
            return
        }

        do {
            let fileURL = try resolveSafeAssetURLInternal(requestPath: rawTarget)
            let inFD = Darwin.open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard inFD >= 0 else {
                let err = errno
                if err == ELOOP {
                    sendError(fd: fd, status: "403 Forbidden", message: "Symlink rejected")
                } else {
                    sendError(fd: fd, status: "404 Not Found", message: "Asset cannot be opened")
                }
                return
            }
            defer { Darwin.close(inFD) }
            var st = stat()
            guard Darwin.fstat(inFD, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
                sendError(fd: fd, status: "403 Forbidden", message: "Not a regular file")
                return
            }
            let fileSize = Int64(st.st_size)
            let mime = Self.mimeType(forExtension: fileURL.pathExtension)
            let hdr = """
            HTTP/1.1 200 OK\r
            Content-Type: \(mime)\r
            Content-Length: \(fileSize)\r
            Access-Control-Allow-Origin: *\r
            Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r
            Access-Control-Allow-Headers: *\r
            Cross-Origin-Resource-Policy: cross-origin\r
            Cache-Control: no-store\r
            Connection: close\r
            \r\n
            """
            guard Self.writeAll(fd: fd, data: Data(hdr.utf8)) else { return }
            if method == "GET" && fileSize > 0 {
                var chunk = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let r = chunk.withUnsafeMutableBytes { raw in
                        Darwin.read(inFD, raw.baseAddress!, raw.count)
                    }
                    if r <= 0 {
                        if r < 0 && errno == EINTR { continue }
                        break
                    }
                    let ok = chunk.withUnsafeBytes { raw -> Bool in
                        guard let base = raw.baseAddress else { return true }
                        return Self.writeAll(fd: fd, base: base, count: r)
                    }
                    if !ok { break }
                }
            }
        } catch let err as ResolveError {
            switch err {
            case .malformed(let m): sendError(fd: fd, status: "400 Bad Request", message: m)
            case .forbidden(let m): sendError(fd: fd, status: "403 Forbidden", message: m)
            case .notFound(let m): sendError(fd: fd, status: "404 Not Found", message: m)
            }
        } catch {
            sendError(fd: fd, status: "500 Internal Server Error", message: "Internal error")
        }
    }

    private func sendError(fd: Int32, status: String, message: String) {
        let body = Data((message + "\n").utf8)
        let hdr = """
        HTTP/1.1 \(status)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Length: \(body.count)\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r
        Access-Control-Allow-Headers: *\r
        Cross-Origin-Resource-Policy: cross-origin\r
        Connection: close\r
        \r\n
        """
        _ = Self.writeAll(fd: fd, data: Data(hdr.utf8))
        _ = Self.writeAll(fd: fd, data: body)
    }

    @discardableResult
    private static func writeAll(fd: Int32, data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            return writeAll(fd: fd, base: base, count: raw.count)
        }
    }

    @discardableResult
    private static func writeAll(fd: Int32, base: UnsafeRawPointer, count: Int) -> Bool {
        var sent = 0
        while sent < count {
            let n = Darwin.write(fd, base.advanced(by: sent), count - sent)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            if n == 0 { return false }
            sent += n
        }
        return true
    }

    public func resolveSafeAssetURL(requestPath: String) throws -> URL {
        do {
            return try resolveSafeAssetURLInternal(requestPath: requestPath)
        } catch let err as ResolveError {
            throw err.safariumError
        }
    }

    private func resolveSafeAssetURLInternal(requestPath: String) throws -> URL {
        var pathOnly = requestPath
        if let qIdx = pathOnly.firstIndex(of: "?") { pathOnly = String(pathOnly[..<qIdx]) }
        if let fIdx = pathOnly.firstIndex(of: "#") { pathOnly = String(pathOnly[..<fIdx]) }

        if pathOnly.contains("\0") || pathOnly.contains("\\") {
            throw ResolveError.forbidden("illegal control or backslash character in request path")
        }
        let lowerRaw = pathOnly.lowercased()
        if lowerRaw.contains("%00") || lowerRaw.contains("%5c") {
            throw ResolveError.forbidden("illegal encoded byte in request path")
        }

        // Check raw path segments prior to decoding
        let rawSegments = pathOnly.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for seg in rawSegments {
            if seg == "." || seg == ".." {
                throw ResolveError.forbidden("path traversal segment rejected: \(requestPath)")
            }
        }

        guard let decoded = pathOnly.removingPercentEncoding else {
            throw ResolveError.malformed("invalid UTF-8 percent-encoding in path: \(requestPath)")
        }
        if decoded.contains("\0") || decoded.contains("\\") {
            throw ResolveError.forbidden("illegal character after percent-decoding")
        }

        let segments = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !segments.isEmpty else {
            throw ResolveError.forbidden("directory index requests are not allowed")
        }
        for seg in segments {
            if seg == "." || seg == ".." {
                throw ResolveError.forbidden("path traversal rejected after percent-decoding: \(decoded)")
            }
            if seg.hasPrefix("._") {
                throw ResolveError.notFound("ExFAT AppleDouble sidecar skipped: \(seg)")
            }
        }

        if let htmlRoot = canonicalHTMLDirPath {
            if segments.first == "fonts" && segments.count >= 2 {
                return try resolveContainedFile(rootPath: canonicalFontDirPath, segments: Array(segments.dropFirst()))
            }
            return try resolveContainedFile(rootPath: htmlRoot, segments: segments)
        }

        // Only allow `/fonts/<rel>` convenience alias if `<fontDir>/fonts` does not exist at all on disk.
        if segments.first == "fonts" && segments.count >= 2 {
            let directFontsPath = canonicalFontDirPath + "/fonts"
            var lst = stat()
            if Darwin.lstat(directFontsPath, &lst) != 0 && errno == ENOENT {
                return try resolveContainedFile(rootPath: canonicalFontDirPath, segments: Array(segments.dropFirst()))
            }
        }
        return try resolveContainedFile(rootPath: canonicalFontDirPath, segments: segments)
    }

    private func resolveContainedFile(rootPath: String, segments: [String]) throws -> URL {
        var candidate = URL(fileURLWithPath: rootPath, isDirectory: true)
        for seg in segments {
            candidate.appendPathComponent(seg, isDirectory: false)
        }
        let candidatePath = candidate.path

        var lst = stat()
        let hasLstat = (Darwin.lstat(candidatePath, &lst) == 0)
        guard let resolvedPtr = Darwin.realpath(candidatePath, nil) else {
            if hasLstat && (lst.st_mode & S_IFMT) == S_IFLNK {
                throw ResolveError.forbidden("dangling or escaping symlink rejected: \(candidate.lastPathComponent)")
            }
            throw ResolveError.notFound("asset not found: \(candidate.lastPathComponent)")
        }
        defer { free(resolvedPtr) }
        let resolvedPath = String(cString: resolvedPtr)

        let rootPrefix = rootPath == "/" ? "/" : rootPath + "/"
        guard resolvedPath.hasPrefix(rootPrefix) else {
            throw ResolveError.forbidden("path resolved outside sandbox root: \(resolvedPath)")
        }
        if resolvedPath.split(separator: "/").contains(where: { $0.hasPrefix("._") }) {
            throw ResolveError.notFound("ExFAT AppleDouble sidecar skipped: \(candidate.lastPathComponent)")
        }

        var st = stat()
        guard stat(resolvedPath, &st) == 0 else {
            throw ResolveError.notFound("cannot stat resolved file: \(resolvedPath)")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw ResolveError.forbidden("non-regular file rejected: \(resolvedPath)")
        }
        return URL(fileURLWithPath: resolvedPath)
    }

    public func discoveredFontEntries() throws -> [FontFaceEntry] {
        let rootURL = URL(fileURLWithPath: canonicalFontDirPath, isDirectory: true)
        let rootPrefix = canonicalFontDirPath == "/" ? "/" : canonicalFontDirPath + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let fontExts: [String: String] = [
            "ttf": "truetype",
            "ttc": "truetype",
            "otf": "opentype",
            "woff": "woff",
            "woff2": "woff2",
        ]
        var entries: [FontFaceEntry] = []
        let activePort = port

        for case let itemURL as URL in enumerator {
            let name = itemURL.lastPathComponent
            if name.hasPrefix("._") || name == ".DS_Store" { continue }
            let ext = itemURL.pathExtension.lowercased()
            guard let fmt = fontExts[ext] else { continue }

            guard let resolvedPtr = Darwin.realpath(itemURL.path, nil) else { continue }
            let resolvedPath = String(cString: resolvedPtr)
            free(resolvedPtr)
            guard resolvedPath.hasPrefix(rootPrefix) else { continue }

            var st = stat()
            guard stat(resolvedPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }

            let relPath = String(resolvedPath.dropFirst(rootPrefix.count))
            let relSegments = relPath.split(separator: "/").map(String.init)
            guard !relSegments.contains(where: { $0.hasPrefix("._") }) else { continue }

            let encodedRel = relSegments.map(Self.percentEncodePathSegment).joined(separator: "/")
            let prefix = canonicalHTMLDirPath != nil ? "fonts/" : ""
            let urlString = activePort > 0
                ? "http://127.0.0.1:\(activePort)/\(prefix)\(encodedRel)"
                : "/\(prefix)\(encodedRel)"

            let meta = Self.extractFontMetadata(fileURL: URL(fileURLWithPath: resolvedPath))
            entries.append(FontFaceEntry(
                filename: name,
                relativePath: relPath,
                familyName: meta.familyName,
                style: meta.style,
                weight: meta.weight,
                format: fmt,
                urlString: urlString
            ))
        }
        entries.sort { $0.relativePath < $1.relativePath }
        return entries
    }

    public func fontFaceCSS() throws -> String {
        let entries = try discoveredFontEntries()
        if entries.isEmpty { return "" }
        var lines: [String] = []
        for entry in entries {
            let famEsc = Self.escapeCSSString(entry.familyName)
            lines.append("""
            @font-face {
              font-family: "\(famEsc)";
              src: url("\(entry.urlString)") format("\(entry.format)");
              font-weight: \(entry.weight);
              font-style: \(entry.style);
              font-display: block;
            }
            """)
            let stem = URL(fileURLWithPath: entry.filename).deletingPathExtension().lastPathComponent
            if !stem.isEmpty && stem != entry.familyName {
                let stemEsc = Self.escapeCSSString(stem)
                lines.append("""
                @font-face {
                  font-family: "\(stemEsc)";
                  src: url("\(entry.urlString)") format("\(entry.format)");
                  font-weight: \(entry.weight);
                  font-style: \(entry.style);
                  font-display: block;
                }
                """)
            }
        }
        return lines.joined(separator: "\n")
    }

    public func injectionScriptSource() throws -> String {
        let css = try fontFaceCSS()
        guard !css.isEmpty else { return "" }
        let jsonData = try JSONSerialization.data(withJSONObject: [css])
        let arrStr = String(decoding: jsonData, as: UTF8.self)
        let jsLiteral = String(arrStr.dropFirst().dropLast())
        return """
        (() => {
          const css = \(jsLiteral);
          const apply = () => {
            let el = document.getElementById('__safarium-font-face');
            if (!el) {
              el = document.createElement('style');
              el.id = '__safarium-font-face';
              (document.head || document.documentElement)?.appendChild(el);
            }
            if (el) el.textContent = css;
          };
          if (document.head || document.documentElement) apply();
          else document.addEventListener('DOMContentLoaded', apply, { once: true });
        })();
        """
    }

    private static func percentEncodePathSegment(_ seg: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return seg.addingPercentEncoding(withAllowedCharacters: allowed) ?? seg
    }

    private static func escapeCSSString(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\a "
            case "\r": out += "\\d "
            case "\0": out += "\\0 "
            case "<": out += "\\3c "
            case ">": out += "\\3e "
            default: out.append(ch)
            }
        }
        return out
    }

    private static func extractFontMetadata(fileURL: URL) -> (familyName: String, weight: String, style: String) {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let lowerStem = stem.lowercased()
        let guessedStyle = (lowerStem.contains("italic") || lowerStem.contains("oblique")) ? "italic" : "normal"
        let guessedWeight = Self.parseWeight(from: lowerStem) ?? "400"
        let guessedFamily = stem.split(separator: "-", maxSplits: 1).first.map(String.init) ?? stem

        if let descs = CTFontManagerCreateFontDescriptorsFromURL(fileURL as CFURL) as? [CTFontDescriptor],
           let desc = descs.first {
            let fam = (CTFontDescriptorCopyAttribute(desc, kCTFontFamilyNameAttribute) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let sty = (CTFontDescriptorCopyAttribute(desc, kCTFontStyleNameAttribute) as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let styLower = sty.lowercased()
            let style = (styLower.contains("italic") || styLower.contains("oblique")) ? "italic" : guessedStyle
            let weight = Self.parseWeight(from: styLower) ?? guessedWeight
            return (fam?.isEmpty == false ? fam! : guessedFamily, weight, style)
        }
        return (guessedFamily, guessedWeight, guessedStyle)
    }

    private static func parseWeight(from lower: String) -> String? {
        if lower.contains("thin") || lower.contains("hairline") { return "100" }
        if lower.contains("extralight") || lower.contains("ultralight") { return "200" }
        if lower.contains("light") { return "300" }
        if lower.contains("medium") { return "500" }
        if lower.contains("semibold") || lower.contains("demibold") { return "600" }
        if lower.contains("extrabold") || lower.contains("ultrabold") { return "800" }
        if lower.contains("black") || lower.contains("heavy") { return "900" }
        if lower.contains("bold") { return "700" }
        if lower.contains("regular") || lower.contains("normal") || lower.contains("book") { return "400" }
        return nil
    }

    private static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttc": return "font/collection"
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        default: return "application/octet-stream"
        }
    }
}

// MARK: - ForgeBatchDOM Models & Warm Auto-BBox PNG Batcher

public struct ForgeBatchDOMItem: Codable, Sendable, Equatable {
    public var id: String?
    public var htmlPath: String?
    public var htmlContent: String?
    public var selector: String?
    public var padding: Int?
    public var width: Int?
    public var height: Int?
    public var transparent: Bool?
    public var outputPath: String
    public var readyExpr: String?
    public var waitMs: Int?
    public var scaleFactor: Double?

    public init(
        id: String? = nil,
        htmlPath: String? = nil,
        htmlContent: String? = nil,
        selector: String? = nil,
        padding: Int? = 8,
        width: Int? = nil,
        height: Int? = nil,
        transparent: Bool? = true,
        outputPath: String,
        readyExpr: String? = nil,
        waitMs: Int? = nil,
        scaleFactor: Double? = nil
    ) {
        self.id = id
        self.htmlPath = htmlPath
        self.htmlContent = htmlContent
        self.selector = selector
        self.padding = padding
        self.width = width
        self.height = height
        self.transparent = transparent
        self.outputPath = outputPath
        self.readyExpr = readyExpr
        self.waitMs = waitMs
        self.scaleFactor = scaleFactor
    }
}

public struct ForgeBatchDOMReport: Codable, Sendable, Equatable {
    public struct ItemResult: Codable, Sendable, Equatable {
        public let id: String?
        public let outputPath: String
        public let ok: Bool
        public let width: Int
        public let height: Int
        public let bytes: Int64
        public let cropRect: [Double]?
        public let wallMs: Double
        public let error: String?

        public init(
            id: String?,
            outputPath: String,
            ok: Bool,
            width: Int,
            height: Int,
            bytes: Int64,
            cropRect: [Double]?,
            wallMs: Double,
            error: String?
        ) {
            self.id = id
            self.outputPath = outputPath
            self.ok = ok
            self.width = width
            self.height = height
            self.bytes = bytes
            self.cropRect = cropRect
            self.wallMs = wallMs
            self.error = error
        }
    }

    public let items: [ItemResult]
    public let totalItems: Int
    public let succeeded: Int
    public let wallMs: Double
    public let peakRSSMB: Double

    public init(
        items: [ItemResult],
        totalItems: Int,
        succeeded: Int,
        wallMs: Double,
        peakRSSMB: Double
    ) {
        self.items = items
        self.totalItems = totalItems
        self.succeeded = succeeded
        self.wallMs = wallMs
        self.peakRSSMB = peakRSSMB
    }
}

public enum ForgeBatchDOM {
    private struct ManifestWrapper: Codable {
        let items: [ForgeBatchDOMItem]
    }

    private static let observeErrorsJS = """
    (() => {
      if (window.__safariumBatchCheck) return;
      let failure;
      const fail = text => { failure ??= String(text).slice(0, 300); };
      window.addEventListener('error', e => {
        if (e instanceof ErrorEvent) fail(e.message || 'page script failed');
        else if (e.target?.matches?.('script,link[rel~="stylesheet"],img'))
          fail('could not load local <' + e.target.localName + '> asset');
      }, true);
      window.addEventListener('unhandledrejection', e => fail(e.reason?.message || 'unhandled page promise rejection'));
      Object.defineProperty(window, '__safariumBatchCheck', { value: () => { if (failure) throw new Error(failure); } });
    })();
    """

    @MainActor
    public static func run(
        manifestURL: URL,
        fontDirURL: URL? = nil,
        overwrite: Bool = false,
        progress: SafariumProgressEmitter? = nil
    ) async throws -> ForgeBatchDOMReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        HostApp.prepare()

        try SafeFilePublisher.assertRegularReadableFile(manifestURL)
        let manifestData = try Data(contentsOf: manifestURL)
        let items: [ForgeBatchDOMItem]
        if let arr = try? JSONDecoder().decode([ForgeBatchDOMItem].self, from: manifestData) {
            items = arr
        } else if let wrapped = try? JSONDecoder().decode(ManifestWrapper.self, from: manifestData) {
            items = wrapped.items
        } else {
            throw SafariumError.invalidState("invalid batch-dom manifest JSON at \(manifestURL.path)")
        }

        guard !items.isEmpty else {
            throw SafariumError.invalidState("batch-dom manifest is empty (0 items)")
        }

        let manifestDir = manifestURL.deletingLastPathComponent()
        var resolvedInputs: [(item: ForgeBatchDOMItem, htmlURL: URL?, htmlContent: String?, outURL: URL)] = []
        resolvedInputs.reserveCapacity(items.count)

        for item in items {
            let trimmedOut = item.outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedOut.isEmpty else {
                throw SafariumError.invalidState("batch-dom item missing outputPath")
            }
            let outURL = URL(fileURLWithPath: trimmedOut)
            try SafeFilePublisher.preflight(outputURL: outURL, overwrite: overwrite)

            var htmlFileURL: URL?
            if let rawHTMLPath = item.htmlPath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawHTMLPath.isEmpty {
                let candidate = rawHTMLPath.hasPrefix("/")
                    ? URL(fileURLWithPath: rawHTMLPath)
                    : (FileManager.default.fileExists(atPath: rawHTMLPath)
                        ? URL(fileURLWithPath: rawHTMLPath)
                        : manifestDir.appendingPathComponent(rawHTMLPath))
                try SafeFilePublisher.assertRegularReadableFile(candidate)
                htmlFileURL = candidate
            }
            let rawContent = item.htmlContent
            guard htmlFileURL != nil || (rawContent?.isEmpty == false) else {
                throw SafariumError.invalidState("batch-dom item requires htmlPath or non-empty htmlContent")
            }
            resolvedInputs.append((item, htmlFileURL, rawContent, outURL))
        }

        let fontServer = try fontDirURL.map { try ForgeLoopbackFontServer(fontDirURL: $0) }
        _ = try fontServer?.start()
        defer { fontServer?.stop() }

        let fontInjectJS = try fontServer?.injectionScriptSource() ?? ""

        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safarium-batch-dom-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stagingDir) }

        let store = WKContentRuleListStore(url: stagingDir)
        let ruleID = fontServer != nil ? "batch-dom-loopback" : "batch-dom-local"
        let ruleJSON = fontServer != nil
            ? """
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
            : """
              [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
               {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
               {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}]
              """
        guard let store,
              let ruleList = try await store.compileContentRuleList(forIdentifier: ruleID, encodedContentRuleList: ruleJSON) else {
            throw SafariumError.invalidState("failed compiling WKContentRuleList for batch-dom sandbox")
        }

        let page = try await Page(config: PageConfig(
            width: 1600,
            height: 1600,
            scale: 1.0,
            transparent: true,
            deterministicClock: false,
            video: .none,
            snapshotQuality: .fast
        )) { wc in
            wc.websiteDataStore = .nonPersistent()
            wc.mediaTypesRequiringUserActionForPlayback = .all
            wc.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
            wc.userContentController.add(ruleList)
            wc.userContentController.addUserScript(WKUserScript(
                source: Self.observeErrorsJS,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            if !fontInjectJS.isEmpty {
                wc.userContentController.addUserScript(WKUserScript(
                    source: fontInjectJS,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true
                ))
            }
        }
        defer { page.close() }

        progress?.emitStart(stage: "batch-dom", total: resolvedInputs.count)
        var results: [ForgeBatchDOMReport.ItemResult] = []
        results.reserveCapacity(resolvedInputs.count)
        var succeeded = 0
        var peakRSSMB = SafariumRuntimeTelemetry.currentFootprintMB()

        for (idx, entry) in resolvedInputs.enumerated() {
            let itemT0 = DispatchTime.now().uptimeNanoseconds
            let item = entry.item
            let scale = max(0.5, min(4.0, item.scaleFactor ?? 1.0))
            var vpW = max(16, min(8192, item.width ?? 1600))
            var vpH = max(16, min(8192, item.height ?? 1600))
            let isTransparent = item.transparent ?? true
            let pad = max(0, item.padding ?? 8)

            page.setViewport(width: vpW, height: vpH, scale: scale)
            page.webView.setValue(!isTransparent, forKey: "drawsBackground")

            if let htmlURL = entry.htmlURL {
                try await page.load(.fileURL(htmlURL, readAccess: htmlURL.deletingLastPathComponent()), timeout: 30.0)
            } else if let htmlContent = entry.htmlContent {
                try await page.load(.html(htmlContent, baseURL: manifestDir), timeout: 30.0)
            }

            try await page.waitFor(.readyState, timeout: 30.0)
            if !fontInjectJS.isEmpty {
                _ = try await page.evaluate(fontInjectJS + "\n;return true;")
            }
            try await page.waitFor(.fonts, timeout: 30.0)
            try await page.waitFor(.images, timeout: 30.0)
            _ = try await page.evaluate("window.__safariumBatchCheck(); return true;")

            if let readyExpr = item.readyExpr?.trimmingCharacters(in: .whitespacesAndNewlines), !readyExpr.isEmpty {
                let cleanExpr = readyExpr.hasSuffix(";") ? String(readyExpr.dropLast()) : readyExpr
                try await page.waitFor(.predicate(cleanExpr), timeout: 30.0)
            }
            if let waitMs = item.waitMs, waitMs > 0 {
                try await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)
            }

            var bbox = try await Self.measureDOMBounds(page: page, selector: item.selector)
            if item.width == nil || item.height == nil {
                let neededW = item.width ?? min(4096, max(vpW, Int(ceil(bbox.maxX)) + pad + 4))
                let neededH = item.height ?? min(4096, max(vpH, Int(ceil(bbox.maxY)) + pad + 4))
                if neededW > vpW || neededH > vpH {
                    vpW = neededW
                    vpH = neededH
                    page.setViewport(width: vpW, height: vpH, scale: scale)
                    bbox = try await Self.measureDOMBounds(page: page, selector: item.selector)
                }
            }

            let left = max(0.0, floor(bbox.minX) - Double(pad))
            let top = max(0.0, floor(bbox.minY) - Double(pad))
            let right = min(Double(vpW), ceil(bbox.maxX) + Double(pad))
            let bottom = min(Double(vpH), ceil(bbox.maxY) + Double(pad))
            let cropRect = CGRect(
                x: left,
                y: top,
                width: max(2.0, right - left),
                height: max(2.0, bottom - top)
            )

            let snap = try await page.snapshot(clip: cropRect)
            _ = try await page.evaluate("window.__safariumBatchCheck(); return true;")

            let outBytes = try Self.writePNGAtomic(
                cgImage: snap.cgImage,
                to: entry.outURL,
                transparent: isTransparent,
                overwrite: overwrite
            )

            let itemWallMs = Double(DispatchTime.now().uptimeNanoseconds - itemT0) / 1e6
            succeeded += 1
            peakRSSMB = max(peakRSSMB, SafariumRuntimeTelemetry.currentFootprintMB())
            progress?.emitFrame(stage: "batch-dom", completed: idx + 1, total: resolvedInputs.count)

            results.append(ForgeBatchDOMReport.ItemResult(
                id: item.id,
                outputPath: entry.outURL.path,
                ok: true,
                width: snap.width,
                height: snap.height,
                bytes: outBytes,
                cropRect: [cropRect.origin.x, cropRect.origin.y, cropRect.size.width, cropRect.size.height],
                wallMs: itemWallMs,
                error: nil
            ))
        }

        progress?.emitComplete(stage: "batch-dom", total: resolvedInputs.count)
        let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return ForgeBatchDOMReport(
            items: results,
            totalItems: resolvedInputs.count,
            succeeded: succeeded,
            wallMs: wallMs,
            peakRSSMB: peakRSSMB
        )
    }

    @MainActor
    private static func measureDOMBounds(
        page: Page,
        selector: String?
    ) async throws -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let js = """
        const sel = selectorArg;
        let targets = [];
        if (sel && sel.length > 0) {
          const el = document.querySelector(sel);
          if (!el) throw new Error('batch-dom selector not found: ' + sel);
          targets = [el];
        } else {
          const body = document.body;
          if (!body) throw new Error('document.body missing');
          const cs = getComputedStyle(body);
          const bg = (cs.backgroundColor || '').replace(/\\s+/g, '');
          const hasBg = bg && bg !== 'rgba(0,0,0,0)' && bg !== 'transparent';
          const hasBorder = (parseFloat(cs.borderTopWidth) || 0) > 0 || (parseFloat(cs.borderLeftWidth) || 0) > 0;
          const kids = Array.from(body.children).filter(el => {
            const tag = (el.tagName || '').toUpperCase();
            if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'LINK' || tag === 'META') return false;
            const st = getComputedStyle(el);
            if (st.display === 'none' || st.visibility === 'hidden') return false;
            const r = el.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          });
          if (kids.length > 0 && (!hasBg && !hasBorder)) {
            targets = kids;
          } else {
            targets = [body];
          }
        }
        let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
        const expand = (r) => {
          if (!r || r.width <= 0 || r.height <= 0) return;
          if (r.left < minX) minX = r.left;
          if (r.top < minY) minY = r.top;
          if (r.right > maxX) maxX = r.right;
          if (r.bottom > maxY) maxY = r.bottom;
        };
        for (const t of targets) {
          expand(t.getBoundingClientRect());
          for (const d of t.querySelectorAll('*')) {
            const st = getComputedStyle(d);
            if (st.display === 'none' || st.visibility === 'hidden') continue;
            expand(d.getBoundingClientRect());
          }
          const tw = document.createTreeWalker(t, NodeFilter.SHOW_TEXT);
          let node;
          while ((node = tw.nextNode())) {
            if (!node.nodeValue || !node.nodeValue.trim()) continue;
            const range = document.createRange();
            range.selectNodeContents(node);
            for (const rr of range.getClientRects()) expand(rr);
            expand(range.getBoundingClientRect());
          }
        }
        if (!Number.isFinite(minX)) {
          return { minX: 0, minY: 0, maxX: window.innerWidth, maxY: window.innerHeight };
        }
        return { minX, minY, maxX, maxY };
        """
        let raw = try await page.evaluate(js, arguments: ["selectorArg": selector ?? ""])
        guard let dict = raw as? [String: Any],
              let minX = (dict["minX"] as? NSNumber)?.doubleValue,
              let minY = (dict["minY"] as? NSNumber)?.doubleValue,
              let maxX = (dict["maxX"] as? NSNumber)?.doubleValue,
              let maxY = (dict["maxY"] as? NSNumber)?.doubleValue else {
            throw SafariumError.snapshot("batch-dom failed reading getBoundingClientRect()")
        }
        return (minX, minY, maxX, maxY)
    }

    private static func writePNGAtomic(
        cgImage: CGImage,
        to outURL: URL,
        transparent: Bool,
        overwrite: Bool
    ) throws -> Int64 {
        let w = cgImage.width
        let h = cgImage.height
        guard w > 0, h > 0 else {
            throw SafariumError.snapshot("batch-dom captured empty image")
        }
        let finalCG: CGImage
        if transparent && Snapshot.isCanonicalSRGBBGRA8(cgImage) {
            finalCG = cgImage
        } else {
            guard let ctx = CGContext(
                data: nil,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: Snapshot.colorSpace,
                bitmapInfo: Snapshot.bitmapInfo
            ) else {
                throw SafariumError.snapshot("batch-dom failed creating BGRA8 CGContext")
            }
            if transparent {
                ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            } else {
                ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let made = ctx.makeImage() else {
                throw SafariumError.snapshot("batch-dom makeImage failed")
            }
            finalCG = made
        }

        let stage = try APFSAutoStage.makeSession(for: outURL, overwrite: overwrite)
        defer { stage.cleanup() }
        let stagedPNG = stage.fileURL("card.png")
        guard let dest = CGImageDestinationCreateWithURL(stagedPNG as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SafariumError.encode("CGImageDestinationCreateWithURL failed for \(stagedPNG.path)")
        }
        CGImageDestinationAddImage(dest, finalCG, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw SafariumError.encode("CGImageDestinationFinalize failed for PNG")
        }
        try stage.commit(stagedFile: stagedPNG, to: outURL, overwrite: overwrite)
        return ((try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }
}
