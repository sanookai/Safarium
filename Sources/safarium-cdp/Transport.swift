import Foundation

typealias JSON = [String: Any]

/// NUL-delimited JSON over two file descriptors (what puppeteer's `pipe: true` uses).
final class PipeTransport: @unchecked Sendable {
    private let readFd: Int32, writeFd: Int32
    private let out = DispatchQueue(label: "safarium.cdp.out")
    /// Debug aid: SAFARIUM_CDP_TRACE=<file> appends every message in both directions (JSON lines, long strings trimmed).
    private let trace: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["SAFARIUM_CDP_TRACE"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()
    private let traceLock = NSLock()
    private func log(_ dir: String, _ obj: JSON) {
        guard let t = trace, let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        var s = String(decoding: d, as: UTF8.self)
        if s.count > 600 { s = String(s.prefix(600)) + "...(\(s.count) chars)" }
        traceLock.lock(); t.seekToEndOfFile(); t.write(Data("\(dir) \(s)\n".utf8)); traceLock.unlock()
    }

    init(readFd: Int32, writeFd: Int32) { self.readFd = readFd; self.writeFd = writeFd }

    /// Reads on a background thread; `onMessage` is invoked on the main queue, in order. EOF on the input exits the process.
    func start(onMessage: @escaping @Sendable (JSON) -> Void) {
        let fd = readFd
        let t = Thread {
            var pending = Data()
            var buf = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let n = read(fd, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                pending.append(buf, count: n)
                while let nul = pending.firstIndex(of: 0) {
                    let chunk = pending[pending.startIndex..<nul]
                    pending = Data(pending[(nul + 1)...])
                    guard !chunk.isEmpty, let obj = (try? JSONSerialization.jsonObject(with: Data(chunk))) as? JSON else { continue }
                    self.log("<-", obj)
                    DispatchQueue.main.async { onMessage(obj) }
                }
            }
            DispatchQueue.main.async { exit(0) }   // client closed the pipe
        }
        t.name = "safarium.cdp.in"
        t.start()
    }

    func send(_ obj: JSON) {
        log("->", obj)
        guard var data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        data.append(0)
        let fd = writeFd
        out.async {
            data.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    if n < 0 { if errno == EINTR { continue }; return }
                    off += n
                }
            }
        }
    }

    /// Waits until everything queued has been written.
    func flush() { out.sync {} }
}

struct CDPError: Error {
    var code: Int
    var message: String
    static func methodNotFound(_ m: String) -> CDPError { CDPError(code: -32601, message: "'\(m)' wasn't found") }
    static func server(_ m: String) -> CDPError { CDPError(code: -32000, message: m) }
    static func invalidParams(_ m: String) -> CDPError { CDPError(code: -32602, message: m) }
}

func newHexId() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }

func monotonicSeconds() -> Double { ProcessInfo.processInfo.systemUptime }
