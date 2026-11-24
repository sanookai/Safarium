import Darwin
import Foundation
import SafariumCore

/// Every AVAssetWriter sees only a fresh path inside this private directory.
/// The only user-visible commit is RENAME_EXCL (with O_CREAT|O_EXCL reservation fallback on ExFAT).
final class Staging {
    let directory: URL, destination: URL

    func outputURL(extension ext: String) -> URL {
        directory.appendingPathComponent("output.\(ext)")
    }

    static func requireNew(_ url: URL) throws {
        var st = stat()
        if lstat(url.path, &st) == 0 { throw WorkerError("output already exists: \(url.path)") }
        guard errno == ENOENT else { throw WorkerError("cannot inspect output: \(String(cString: strerror(errno)))") }
    }

    init(destination: URL) throws {
        self.destination = destination
        let parent = destination.deletingLastPathComponent()
        directory = parent.appendingPathComponent(".safarium-html-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else {
            throw WorkerError("cannot create staging directory beside output: \(String(cString: strerror(errno)))")
        }
        _ = chmod(directory.path, 0o700)
        var st = stat()
        guard lstat(directory.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid(),
              ((st.st_mode & 0o777) == 0o700 || SafeFilePublisher.volumeHasNoPermissions(at: parent.path)) else {
            try? FileManager.default.removeItem(at: directory)
            throw WorkerError("output volume must support a private (0700) staging directory")
        }
    }

    func publish(_ completed: URL) throws {
        let err = SafeFilePublisher.exclusiveOrAtomicPublish(tempURL: completed, to: destination, overwrite: false)
        guard err == 0 else {
            throw WorkerError("cannot publish new output: \(String(cString: strerror(err)))")
        }
    }

    func cleanup() {
        do { try FileManager.default.removeItem(at: directory) }
        catch { FileHandle.standardError.write(Data("safarium-html: could not clean \(directory.path): \(error.localizedDescription)\n".utf8)) }
    }
}
