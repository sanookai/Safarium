import Darwin
import Foundation

/// Stage on the destination volume. The lock orders cancellation against the one publication point.
final class RenderOutput: @unchecked Sendable {
    private let destination: URL, directory: URL
    var movie: URL { directory.appendingPathComponent("video.mp4") }
    private let lock = NSLock()
    private var ownsDirectory = false, published = false
    private var stoppedBy: Int32?

    init(_ destination: URL) {
        self.destination = destination
        directory = destination.deletingLastPathComponent().appendingPathComponent(".safarium-regions-\(UUID().uuidString)")
    }

    static func requireNew(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 { throw CLIError("output already exists: \(url.path)") } // includes dangling links
        guard errno == ENOENT else { throw CLIError("cannot inspect output: \(String(cString: strerror(errno)))") }
    }

    func create() throws {
        lock.lock(); defer { lock.unlock() }
        guard stoppedBy == nil else { throw CancellationError() }
        guard mkdir(directory.path, 0o700) == 0 else { throw CLIError("cannot create staging directory: \(String(cString: strerror(errno)))") }
        ownsDirectory = true
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & 0o777 == 0o700 else {
            throw CLIError("output volume cannot provide a private mode-0700 staging directory")
        }
    }

    func publish() throws {
        lock.lock(); defer { lock.unlock() }
        guard stoppedBy == nil else { throw CancellationError() }
        // The initial lstat is diagnostic only. RENAME_EXCL enforces no replacement *at commit*,
        // including a symlink or another render that appeared while AVAssetWriter was running.
        guard renamex_np(movie.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw CLIError("cannot publish new output: \(String(cString: strerror(errno)))")
        }
        published = true
    }

    func cleanup() {
        lock.lock(); defer { lock.unlock() }
        guard ownsDirectory else { return }
        do {
            try FileManager.default.removeItem(at: directory)
            ownsDirectory = false
        } catch {
            var info = stat()
            if lstat(directory.path, &info) < 0 && errno == ENOENT {
                ownsDirectory = false
            } else {
                // Keep ownership so a later cleanup can retry. In particular, a
                // read-only destination volume must not be reported as cleaned.
                let warning = "safarium-regions: could not remove staging directory \(directory.path): \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(warning.utf8))
            }
        }
    }

    var signalNumber: Int32? {
        lock.lock(); defer { lock.unlock() }
        return stoppedBy
    }

    private func stop(_ sig: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !published, stoppedBy == nil else { return false }
        stoppedBy = sig
        return true
    }

    func handleSignals(cancel: @escaping @Sendable () -> Void) -> [DispatchSourceSignal] {
        let queue = DispatchQueue(label: "safarium.regions.interrupt")
        return [SIGINT, SIGTERM].map { sig in
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            source.setEventHandler { [self] in
                guard stop(sig) else { return }
                cancel()
                // Some AVFoundation/WebKit awaits are not cancellable. Give defers time to run,
                // then discard our private directory and exit; never publish from the watchdog.
                queue.asyncAfter(deadline: .now() + 3) { [self] in cleanup(); _exit(128 + sig) }
            }
            source.resume()
            return source
        }
    }
}
