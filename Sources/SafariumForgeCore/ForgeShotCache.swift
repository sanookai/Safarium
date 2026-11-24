import CryptoKit
import Darwin
import Foundation
import SafariumCore

public struct ForgeShotCacheEntryMeta: Codable, Sendable {
    public let key: String
    public let namespace: String
    public let originalExt: String
    public let byteSize: Int64
    public let createdUnix: TimeInterval
    public var lastAccessedUnix: TimeInterval
    public let metadata: [String: String]
}

public struct ForgeShotCacheLookupReport: Codable, Sendable {
    public let key: String
    public let hit: Bool
    public let materializedPath: String?
    public let usedClonefile: Bool
    public let bytes: Int64
    public let wallMs: Double
}

public struct ForgeShotCacheStoreReport: Codable, Sendable {
    public let key: String
    public let cachedPath: String
    public let usedClonefile: Bool
    public let bytes: Int64
    public let wallMs: Double
}

public struct ForgeShotCacheStatsReport: Codable, Sendable {
    public let cacheRoot: String
    public let entryCount: Int
    public let totalBytes: Int64
}

public struct ForgeShotCachePruneReport: Codable, Sendable {
    public let cacheRoot: String
    public let maxBytes: Int64
    public let removedEntries: Int
    public let freedBytes: Int64
    public let remainingEntries: Int
    public let remainingBytes: Int64
}

/// Content-addressed APFS Shot & Render Cache (`clonefile` CoW at `0 B` extra same-volume disk; ExFAT-safe fallback; ignores `._*`).
public final class ForgeShotCache {
    public let rootURL: URL

    public static func defaultRootURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.safarium.forge-shot-cache", isDirectory: true)
    }

    public init(rootURL: URL? = nil) throws {
        let root = (rootURL ?? Self.defaultRootURL()).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = chmod(root.path, 0o700)

        var st = stat()
        guard lstat(root.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid(),
              (st.st_mode & 0o777) == 0o700 else {
            throw SafariumError.invalidState("Shot cache root must be 0700 owned by current user: \(root.path)")
        }
        let caps = try APFSAutoStage.inspectVolume(at: root)
        guard caps.supportsClonefile && caps.supportsRenameExcl else {
            throw SafariumError.invalidState("Shot cache root must support APFS clonefile + RENAME_EXCL: \(root.path)")
        }
        self.rootURL = root
    }

    public static func computeKey(
        namespace: String,
        paramsJSON: String = "{}",
        inputURLs: [URL] = []
    ) throws -> String {
        var hasher = SHA256()
        hasher.update(data: Data("safarium-shot-cache-v1\n".utf8))
        hasher.update(data: Data(namespace.utf8))
        hasher.update(data: Data("\n".utf8))
        hasher.update(data: Data(paramsJSON.utf8))
        hasher.update(data: Data("\n".utf8))

        let chunkSize = 1024 * 1024
        var buf = [UInt8](repeating: 0, count: chunkSize)
        for url in inputURLs.sorted(by: { $0.path < $1.path }) {
            try SafeFilePublisher.assertRegularReadableFile(url)
            let fd = Darwin.open(url.path, O_RDONLY)
            guard fd >= 0 else {
                let err = errno
                throw SafariumError.invalidState("cannot read cache key input \(url.path): \(String(cString: strerror(err)))")
            }
            defer { Darwin.close(fd) }
            hasher.update(data: Data(url.lastPathComponent.utf8))
            hasher.update(data: Data(":".utf8))
            while true {
                let n = buf.withUnsafeMutableBytes { raw in Darwin.read(fd, raw.baseAddress!, chunkSize) }
                if n == 0 { break }
                if n < 0 {
                    if errno == EINTR { continue }
                    let err = errno
                    throw SafariumError.invalidState("read error hashing \(url.path): \(String(cString: strerror(err)))")
                }
                buf.withUnsafeBytes { raw in
                    hasher.update(bufferPointer: UnsafeRawBufferPointer(start: raw.baseAddress, count: n))
                }
            }
            hasher.update(data: Data("\n".utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizeKey(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet(charactersIn: "0123456789abcdef_-")
        guard !trimmed.isEmpty, trimmed.count <= 128,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw SafariumError.invalidState("invalid shot cache key '\(raw)'")
        }
        return trimmed
    }

    private func binURL(for key: String) -> URL {
        rootURL.appendingPathComponent("\(key).bin")
    }

    private func metaURL(for key: String) -> URL {
        rootURL.appendingPathComponent("\(key).meta.json")
    }

    public func store(
        key rawKey: String,
        sourceURL: URL,
        namespace: String = "default",
        metadata: [String: String] = [:]
    ) throws -> ForgeShotCacheStoreReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let key = try Self.sanitizeKey(rawKey)
        try SafeFilePublisher.assertRegularReadableFile(sourceURL)

        let dstBin = binURL(for: key)
        let tmpBin = SafeFilePublisher.makeTempURL(beside: dstBin)
        var usedClone = false
        do {
            if Darwin.clonefile(sourceURL.path, tmpBin.path, 0) == 0 {
                usedClone = true
            } else {
                let err = errno
                if err == EXDEV || err == ENOTSUP || err == EOPNOTSUPP {
                    try APFSAutoStage.streamCopy(from: sourceURL, to: tmpBin)
                } else {
                    throw SafariumError.encode("clonefile into cache failed: \(String(cString: strerror(err)))")
                }
            }
            try SafeFilePublisher.publish(tempURL: tmpBin, to: dstBin, overwrite: true)
        } catch {
            try? FileManager.default.removeItem(at: tmpBin)
            throw error
        }

        let size = ((try? FileManager.default.attributesOfItem(atPath: dstBin.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let now = Date().timeIntervalSince1970
        let entry = ForgeShotCacheEntryMeta(
            key: key,
            namespace: namespace,
            originalExt: sourceURL.pathExtension,
            byteSize: size,
            createdUnix: now,
            lastAccessedUnix: now,
            metadata: metadata
        )
        let dstMeta = metaURL(for: key)
        let tmpMeta = SafeFilePublisher.makeTempURL(beside: dstMeta)
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(entry).write(to: tmpMeta)
            try SafeFilePublisher.publish(tempURL: tmpMeta, to: dstMeta, overwrite: true)
        } catch {
            try? FileManager.default.removeItem(at: tmpMeta)
            throw error
        }

        return ForgeShotCacheStoreReport(
            key: key,
            cachedPath: dstBin.path,
            usedClonefile: usedClone,
            bytes: size,
            wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        )
    }

    public func lookup(
        key rawKey: String,
        destinationURL: URL?,
        overwrite: Bool = false
    ) throws -> ForgeShotCacheLookupReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let key = try Self.sanitizeKey(rawKey)
        let cachedBin = binURL(for: key)
        guard FileManager.default.fileExists(atPath: cachedBin.path) else {
            return ForgeShotCacheLookupReport(
                key: key, hit: false, materializedPath: nil, usedClonefile: false, bytes: 0,
                wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            )
        }

        let size = ((try? FileManager.default.attributesOfItem(atPath: cachedBin.path)[.size]) as? NSNumber)?.int64Value ?? 0
        var usedClone = false
        if let dest = destinationURL {
            try SafeFilePublisher.preflight(outputURL: dest, overwrite: overwrite)
            let destCaps = try APFSAutoStage.inspectVolume(at: dest)
            let siblingTemp = SafeFilePublisher.makeTempURL(beside: dest)
            do {
                if destCaps.supportsClonefile && destCaps.supportsRenameExcl,
                   Darwin.clonefile(cachedBin.path, siblingTemp.path, 0) == 0 {
                    usedClone = true
                } else {
                    try APFSAutoStage.streamCopy(from: cachedBin, to: siblingTemp)
                }
                try SafeFilePublisher.publish(tempURL: siblingTemp, to: dest, overwrite: overwrite)
            } catch {
                try? FileManager.default.removeItem(at: siblingTemp)
                throw error
            }
        }

        // Update access timestamp best-effort.
        let mURL = metaURL(for: key)
        if let data = try? Data(contentsOf: mURL),
           var meta = try? JSONDecoder().decode(ForgeShotCacheEntryMeta.self, from: data) {
            meta.lastAccessedUnix = Date().timeIntervalSince1970
            let tmp = SafeFilePublisher.makeTempURL(beside: mURL)
            if (try? JSONEncoder().encode(meta).write(to: tmp)) != nil {
                try? SafeFilePublisher.publish(tempURL: tmp, to: mURL, overwrite: true)
            }
        }

        return ForgeShotCacheLookupReport(
            key: key,
            hit: true,
            materializedPath: destinationURL?.path ?? cachedBin.path,
            usedClonefile: usedClone,
            bytes: size,
            wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        )
    }

    private func scanEntries() throws -> [(key: String, binURL: URL, metaURL: URL, bytes: Int64, lastAccess: TimeInterval)] {
        let items = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var out: [(String, URL, URL, Int64, TimeInterval)] = []
        for url in items {
            let name = url.lastPathComponent
            if name.hasPrefix("._") || name.hasPrefix(".") || !name.hasSuffix(".bin") { continue }
            let key = String(name.dropLast(4))
            let mURL = metaURL(for: key)
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            var size = Int64(vals?.fileSize ?? 0)
            var access = vals?.contentModificationDate?.timeIntervalSince1970 ?? 0
            if let data = try? Data(contentsOf: mURL),
               let meta = try? JSONDecoder().decode(ForgeShotCacheEntryMeta.self, from: data) {
                size = max(size, meta.byteSize)
                access = meta.lastAccessedUnix
            }
            out.append((key, url, mURL, size, access))
        }
        return out
    }

    public func stats() throws -> ForgeShotCacheStatsReport {
        let entries = try scanEntries()
        let total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        return ForgeShotCacheStatsReport(cacheRoot: rootURL.path, entryCount: entries.count, totalBytes: total)
    }

    public func prune(maxBytes: Int64) throws -> ForgeShotCachePruneReport {
        let targetMax = max(0, maxBytes)
        var entries = try scanEntries().sorted { $0.lastAccess < $1.lastAccess }
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        var removed = 0
        var freed: Int64 = 0

        while total > targetMax, !entries.isEmpty {
            let victim = entries.removeFirst()
            try? FileManager.default.removeItem(at: victim.binURL)
            try? FileManager.default.removeItem(at: victim.metaURL)
            total -= victim.bytes
            freed += victim.bytes
            removed += 1
        }
        return ForgeShotCachePruneReport(
            cacheRoot: rootURL.path,
            maxBytes: targetMax,
            removedEntries: removed,
            freedBytes: freed,
            remainingEntries: entries.count,
            remainingBytes: max(0, total)
        )
    }
}
