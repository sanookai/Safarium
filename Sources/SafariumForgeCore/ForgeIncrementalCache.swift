import AVFoundation
import CoreMedia
import CryptoKit
import Darwin
import Foundation
import SafariumCore

public struct ForgeSceneSpec: Codable, Sendable, Equatable {
    public var sceneId: String
    public var inputs: [String]
    public var opsHash: String
    public var durationSeconds: Double
    public var fps: Int
    public var width: Int
    public var height: Int
    public var codec: String

    public init(
        sceneId: String,
        inputs: [String] = [],
        opsHash: String,
        durationSeconds: Double,
        fps: Int,
        width: Int,
        height: Int,
        codec: String = "h264"
    ) {
        self.sceneId = sceneId
        self.inputs = inputs
        self.opsHash = opsHash
        self.durationSeconds = durationSeconds
        self.fps = fps
        self.width = width
        self.height = height
        self.codec = codec
    }
}

public struct ForgeSceneCacheEntryMeta: Codable, Sendable {
    public let key: String
    public let spec: ForgeSceneSpec?
    public let byteSize: Int64
    public let segmentSHA256: String
    public let createdUnix: TimeInterval
    public var lastAccessedUnix: TimeInterval
}

public struct ForgeSceneCacheLookupReport: Codable, Sendable {
    public let key: String
    public let hit: Bool
    public let cachedPath: String?
    public let materializedPath: String?
    public let usedClonefile: Bool
    public let bytes: Int64
    public let sha256: String?
    public let wallMs: Double
}

public struct ForgeSceneCacheStoreReport: Codable, Sendable {
    public let key: String
    public let cachedPath: String
    public let usedClonefile: Bool
    public let bytes: Int64
    public let sha256: String
    public let wallMs: Double
}

public struct ForgeSceneCacheStatsReport: Codable, Sendable {
    public let cacheRoot: String
    public let fsType: String
    public let isAPFS: Bool
    public let supportsClonefile: Bool
    public let entryCount: Int
    public let totalBytes: Int64
}

public struct ForgeSceneCachePruneReport: Codable, Sendable {
    public let cacheRoot: String
    public let maxBytes: Int64
    public let removedEntries: Int
    public let freedBytes: Int64
    public let remainingEntries: Int
    public let remainingBytes: Int64
}

/// Releases freed malloc blocks back to macOS VM and drains any thread-local Objective-C autorelease pool.
public func safariumMemFlush() {
    autoreleasepool {
        _ = Darwin.malloc_zone_pressure_relief(nil, 0)
    }
}

/// Closed-GOP APFS `clonefile` Incremental Scene Cache (`~/Library/Caches/com.safarium.scene-cache` by default).
public enum ForgeIncrementalCache {
    public static func defaultCacheRootURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/com.safarium.scene-cache", isDirectory: true)
    }

    /// Validates that `url` resides on internal APFS supporting `clonefile(2)` + `RENAME_EXCL` and POSIX permissions.
    @discardableResult
    public static func validateAPFSCacheRoot(_ url: URL) throws -> URL {
        let root = url.standardizedFileURL
        let caps = try APFSAutoStage.inspectVolume(at: root)
        guard caps.isAPFS, caps.supportsClonefile, caps.supportsRenameExcl, !caps.noPermissions else {
            throw SafariumError.invalidState(
                "incremental scene cache root must reside on internal APFS with clonefile support (got fsType=\(caps.fsType), noPermissions=\(caps.noPermissions) at \(root.path)); stage cache on \(defaultCacheRootURL().path)"
            )
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = chmod(root.path, 0o700)

        var st = stat()
        guard lstat(root.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid(),
              (st.st_mode & 0o777) == 0o700 else {
            throw SafariumError.invalidState("incremental scene cache root must be 0700 owned by current user: \(root.path)")
        }
        return root
    }

    /// Resolves cache storage on internal APFS. Rejects ExFAT/external volumes unless `fallbackToInternalAPFS` is explicitly enabled.
    public static func resolveCacheRoot(_ customRoot: URL? = nil, fallbackToInternalAPFS: Bool = false) throws -> URL {
        guard let customRoot else {
            return try validateAPFSCacheRoot(defaultCacheRootURL())
        }
        do {
            return try validateAPFSCacheRoot(customRoot)
        } catch {
            if fallbackToInternalAPFS {
                return try validateAPFSCacheRoot(defaultCacheRootURL())
            }
            throw error
        }
    }

    private struct DirectoryFileID: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    private struct DirectoryInputEntry {
        let relPath: String
        let byteSize: Int64
        let filePath: String
    }

    private static func isExistingDirectory(path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    private static func streamSHA256Hex(filePath: String) throws -> String {
        let fd = Darwin.open(filePath, O_RDONLY)
        guard fd >= 0 else {
            let err = errno
            throw SafariumError.invalidState("cannot open scene input \(filePath): \(String(cString: strerror(err)))")
        }
        defer { _ = Darwin.close(fd) }
        var fileHasher = SHA256()
        let chunkSize = 1024 * 1024
        var buf = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let n = buf.withUnsafeMutableBytes { raw in Darwin.read(fd, raw.baseAddress!, chunkSize) }
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                let err = errno
                throw SafariumError.invalidState("read error hashing \(filePath): \(String(cString: strerror(err)))")
            }
            buf.withUnsafeBytes { raw in
                fileHasher.update(bufferPointer: UnsafeRawBufferPointer(start: raw.baseAddress, count: n))
            }
        }
        return fileHasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func hashDirectoryInput(at dirURL: URL, into hasher: inout SHA256) throws {
        var rootStat = stat()
        guard Darwin.lstat(dirURL.path, &rootStat) == 0,
              (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw SafariumError.invalidState("directory scene input is not a real directory: \(dirURL.path)")
        }
        guard let rootRealPtr = Darwin.realpath(dirURL.path, nil) else {
            let err = errno
            throw SafariumError.invalidState("cannot resolve directory scene input \(dirURL.path): \(String(cString: strerror(err)))")
        }
        let canonicalRoot = String(cString: rootRealPtr)
        Darwin.free(rootRealPtr)

        var visitedDirs = Set<DirectoryFileID>()
        visitedDirs.insert(DirectoryFileID(dev: rootStat.st_dev, ino: rootStat.st_ino))
        var entries: [DirectoryInputEntry] = []

        func walk(dirPath: String, relPrefix: String) throws {
            guard let dp = Darwin.opendir(dirPath) else {
                let err = errno
                throw SafariumError.invalidState("cannot open directory input \(dirPath): \(String(cString: strerror(err)))")
            }
            defer { _ = Darwin.closedir(dp) }

            while let dent = Darwin.readdir(dp) {
                let name = withUnsafePointer(to: &dent.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
                }
                if name == "." || name == ".." || name.hasPrefix("._") {
                    continue
                }
                let fullPath = dirPath + "/" + name
                let relPath = relPrefix.isEmpty ? name : "\(relPrefix)/\(name)"
                var st = stat()
                guard Darwin.lstat(fullPath, &st) == 0 else {
                    let err = errno
                    throw SafariumError.invalidState("cannot stat directory entry \(relPath): \(String(cString: strerror(err)))")
                }

                switch st.st_mode & S_IFMT {
                case S_IFREG:
                    entries.append(DirectoryInputEntry(relPath: relPath, byteSize: Int64(st.st_size), filePath: fullPath))
                case S_IFDIR:
                    let fid = DirectoryFileID(dev: st.st_dev, ino: st.st_ino)
                    if visitedDirs.insert(fid).inserted {
                        try walk(dirPath: fullPath, relPrefix: relPath)
                    }
                case S_IFLNK:
                    guard let resolvedPtr = Darwin.realpath(fullPath, nil) else {
                        throw SafariumError.invalidState("broken symlink in directory input: \(relPath)")
                    }
                    let resolved = String(cString: resolvedPtr)
                    Darwin.free(resolvedPtr)
                    guard resolved == canonicalRoot || resolved.hasPrefix(canonicalRoot + "/") else {
                        throw SafariumError.invalidState("symlink escapes directory input: \(relPath) -> \(resolved)")
                    }
                    var targetSt = stat()
                    guard stat(resolved, &targetSt) == 0 else {
                        let err = errno
                        throw SafariumError.invalidState("cannot stat symlink target \(relPath): \(String(cString: strerror(err)))")
                    }
                    switch targetSt.st_mode & S_IFMT {
                    case S_IFREG:
                        entries.append(DirectoryInputEntry(relPath: relPath, byteSize: Int64(targetSt.st_size), filePath: resolved))
                    case S_IFDIR:
                        let fid = DirectoryFileID(dev: targetSt.st_dev, ino: targetSt.st_ino)
                        if visitedDirs.insert(fid).inserted {
                            try walk(dirPath: resolved, relPrefix: relPath)
                        }
                    default:
                        throw SafariumError.invalidState("non-regular symlink target in directory input: \(relPath)")
                    }
                default:
                    throw SafariumError.invalidState("non-regular entry in directory input: \(relPath)")
                }
            }
        }

        try walk(dirPath: canonicalRoot, relPrefix: "")
        entries.sort { $0.relPath.utf8.lexicographicallyPrecedes($1.relPath.utf8) }

        hasher.update(data: Data("dir_entries:\(entries.count)\n".utf8))
        for entry in entries {
            let fileDigest = try streamSHA256Hex(filePath: entry.filePath)
            hasher.update(data: Data("entry:\(entry.relPath)|size:\(entry.byteSize)|sha256:\(fileDigest)\n".utf8))
        }
    }

    private static func updateBaseSpecHash(for spec: ForgeSceneSpec, into hasher: inout SHA256) {
        hasher.update(data: Data("safarium-scene-cache-v1\n".utf8))
        hasher.update(data: Data("sceneId:\(spec.sceneId)\n".utf8))
        hasher.update(data: Data("opsHash:\(spec.opsHash)\n".utf8))
        hasher.update(data: Data("dur:\(String(format: "%.9f", spec.durationSeconds))\n".utf8))
        hasher.update(data: Data("fps:\(spec.fps)\n".utf8))
        hasher.update(data: Data("dims:\(spec.width)x\(spec.height)\n".utf8))
        hasher.update(data: Data("codec:\(spec.codec)\n".utf8))
        hasher.update(data: Data("inputs:\(spec.inputs.count)\n".utf8))
        for inp in spec.inputs {
            hasher.update(data: Data("in:\(inp)\n".utf8))
        }
    }

    public static func cacheKey(for spec: ForgeSceneSpec) -> String {
        var hasher = SHA256()
        updateBaseSpecHash(for: spec, into: &hasher)
        for inp in spec.inputs where isExistingDirectory(path: inp) {
            do {
                try hashDirectoryInput(at: URL(fileURLWithPath: inp, isDirectory: true), into: &hasher)
            } catch {
                hasher.update(data: Data("dir_error:\(inp):\(error)\n".utf8))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func cacheKey(for spec: ForgeSceneSpec, hashingInputFiles fileURLs: [URL]) throws -> String {
        var hasher = SHA256()
        updateBaseSpecHash(for: spec, into: &hasher)
        for inp in spec.inputs where isExistingDirectory(path: inp) {
            try hashDirectoryInput(at: URL(fileURLWithPath: inp, isDirectory: true), into: &hasher)
        }
        hasher.update(data: Data("\nfiles:\(fileURLs.count)\n".utf8))
        for url in fileURLs.sorted(by: { $0.path < $1.path }) {
            if isExistingDirectory(path: url.path) {
                hasher.update(data: Data("dir:\(url.lastPathComponent)\n".utf8))
                try hashDirectoryInput(at: url, into: &hasher)
            } else {
                try SafeFilePublisher.assertRegularReadableFile(url)
                let digest = try streamSHA256Hex(filePath: url.path)
                var st = stat()
                let size: Int64 = (stat(url.path, &st) == 0) ? Int64(st.st_size) : 0
                hasher.update(data: Data("file:\(url.lastPathComponent)|size:\(size)|sha256:\(digest)\n".utf8))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sanitizeKey(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowed = CharacterSet(charactersIn: "0123456789abcdef_-")
        guard !trimmed.isEmpty, trimmed.count <= 128,
              trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw SafariumError.invalidState("invalid scene cache key '\(raw)'")
        }
        return trimmed
    }

    private static func segmentFileURL(root: URL, key: String) -> URL {
        root.appendingPathComponent("\(key).mp4")
    }

    private static func metaFileURL(root: URL, key: String) -> URL {
        root.appendingPathComponent("\(key).meta.json")
    }

    /// Validates ISO BMFF (`ftyp` + `moov` + non-empty `mdat`) framing and streaming SHA-256 integrity.
    @discardableResult
    public static func validateSegmentFile(
        at url: URL,
        expectedSHA256: String? = nil,
        expectedByteSize: Int64? = nil
    ) throws -> (bytes: Int64, sha256: String) {
        try SafeFilePublisher.assertRegularReadableFile(url)
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        let fileSize = Int64(try fh.seekToEnd())
        guard fileSize >= 24 else {
            throw SafariumError.invalidState("empty or truncated scene segment (\(fileSize) bytes): \(url.path)")
        }
        if let expectedByteSize, fileSize != expectedByteSize {
            throw SafariumError.invalidState("corrupt scene segment byte size \(fileSize) != expected \(expectedByteSize): \(url.path)")
        }

        // Walk top-level ISO BMFF atoms strictly within file bounds.
        var offset: Int64 = 0
        var hasFtyp = false
        var hasMoov = false
        var hasMdat = false
        var isFirst = true

        while offset < fileSize {
            guard fileSize - offset >= 8 else {
                throw SafariumError.invalidState("corrupt ISO BMFF trailing header at offset \(offset): \(url.path)")
            }
            try fh.seek(toOffset: UInt64(offset))
            guard let hdr = try fh.read(upToCount: 8), hdr.count == 8 else {
                throw SafariumError.invalidState("unreadable ISO BMFF box header at offset \(offset): \(url.path)")
            }
            let size32 = hdr.withUnsafeBytes { raw -> UInt32 in
                UInt32(bigEndian: raw.load(fromByteOffset: 0, as: UInt32.self))
            }
            let fourCC = String(decoding: hdr[4..<8], as: UTF8.self)
            var boxSize: Int64
            if size32 == 1 {
                guard fileSize - offset >= 16, let extData = try fh.read(upToCount: 8), extData.count == 8 else {
                    throw SafariumError.invalidState("truncated 64-bit ISO BMFF box size at offset \(offset): \(url.path)")
                }
                let size64 = extData.withUnsafeBytes { raw -> UInt64 in
                    UInt64(bigEndian: raw.load(fromByteOffset: 0, as: UInt64.self))
                }
                guard size64 >= 16, size64 <= UInt64(fileSize - offset) else {
                    throw SafariumError.invalidState("corrupt 64-bit ISO BMFF box size \(size64) at offset \(offset): \(url.path)")
                }
                boxSize = Int64(size64)
            } else if size32 == 0 {
                boxSize = fileSize - offset
            } else {
                guard size32 >= 8 else {
                    throw SafariumError.invalidState("corrupt ISO BMFF box size \(size32) at offset \(offset): \(url.path)")
                }
                boxSize = Int64(size32)
            }
            guard boxSize <= fileSize - offset else {
                throw SafariumError.invalidState("corrupt ISO BMFF box '\(fourCC)' extends past EOF: \(url.path)")
            }

            if isFirst {
                guard fourCC == "ftyp" else {
                    throw SafariumError.invalidState("corrupt scene segment missing leading 'ftyp' atom (found '\(fourCC)'): \(url.path)")
                }
                hasFtyp = true
                isFirst = false
            }
            if fourCC == "moov" { hasMoov = true }
            if fourCC == "mdat", boxSize > 8 { hasMdat = true }

            offset += boxSize
        }

        guard hasFtyp, hasMoov, hasMdat else {
            throw SafariumError.invalidState("corrupt scene segment missing required MP4/MOV atoms (ftyp=\(hasFtyp), moov=\(hasMoov), mdat=\(hasMdat)): \(url.path)")
        }

        // Stream-compute SHA-256 with bounded 1 MiB buffer.
        try fh.seek(toOffset: 0)
        var hasher = SHA256()
        while true {
            guard let chunk = try fh.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let expectedSHA256, digest != expectedSHA256 {
            throw SafariumError.invalidState("corrupt cached scene segment SHA-256 mismatch (\(digest) != \(expectedSHA256)): \(url.path)")
        }
        return (fileSize, digest)
    }

    public static func storeScene(
        key rawKey: String,
        segmentURL: URL,
        spec: ForgeSceneSpec? = nil,
        cacheRoot: URL? = nil
    ) throws -> ForgeSceneCacheStoreReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let key = try sanitizeKey(rawKey)
        let root = try resolveCacheRoot(cacheRoot)
        let (byteSize, sha256) = try validateSegmentFile(at: segmentURL)

        let dstSeg = segmentFileURL(root: root, key: key)
        let tmpSeg = SafeFilePublisher.makeTempURL(beside: dstSeg)
        var usedClone = false
        do {
            if Darwin.clonefile(segmentURL.path, tmpSeg.path, 0) == 0 {
                usedClone = true
            } else {
                let err = errno
                if err == EXDEV || err == ENOTSUP || err == EOPNOTSUPP {
                    try APFSAutoStage.streamCopy(from: segmentURL, to: tmpSeg)
                } else {
                    throw SafariumError.encode("clonefile into scene cache failed: \(String(cString: strerror(err)))")
                }
            }
            try SafeFilePublisher.publish(tempURL: tmpSeg, to: dstSeg, overwrite: true)
        } catch {
            try? FileManager.default.removeItem(at: tmpSeg)
            throw error
        }

        let now = Date().timeIntervalSince1970
        let entry = ForgeSceneCacheEntryMeta(
            key: key,
            spec: spec,
            byteSize: byteSize,
            segmentSHA256: sha256,
            createdUnix: now,
            lastAccessedUnix: now
        )
        let dstMeta = metaFileURL(root: root, key: key)
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

        return ForgeSceneCacheStoreReport(
            key: key,
            cachedPath: dstSeg.path,
            usedClonefile: usedClone,
            bytes: byteSize,
            sha256: sha256,
            wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        )
    }

    public static func lookupScene(
        key rawKey: String,
        destinationURL: URL? = nil,
        cacheRoot: URL? = nil,
        overwrite: Bool = true,
        rejectCorrupt: Bool = true
    ) throws -> ForgeSceneCacheLookupReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let key = try sanitizeKey(rawKey)
        let root = try resolveCacheRoot(cacheRoot)
        let cachedSeg = segmentFileURL(root: root, key: key)
        let mURL = metaFileURL(root: root, key: key)

        guard FileManager.default.fileExists(atPath: cachedSeg.path) else {
            return ForgeSceneCacheLookupReport(
                key: key, hit: false, cachedPath: nil, materializedPath: nil,
                usedClonefile: false, bytes: 0, sha256: nil,
                wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            )
        }

        let meta = (try? Data(contentsOf: mURL)).flatMap { try? JSONDecoder().decode(ForgeSceneCacheEntryMeta.self, from: $0) }
        let validated: (bytes: Int64, sha256: String)
        do {
            validated = try validateSegmentFile(
                at: cachedSeg,
                expectedSHA256: meta?.segmentSHA256,
                expectedByteSize: meta?.byteSize
            )
        } catch {
            try? FileManager.default.removeItem(at: cachedSeg)
            try? FileManager.default.removeItem(at: mURL)
            if rejectCorrupt { throw error }
            return ForgeSceneCacheLookupReport(
                key: key, hit: false, cachedPath: nil, materializedPath: nil,
                usedClonefile: false, bytes: 0, sha256: nil,
                wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            )
        }

        var usedClone = false
        if let dest = destinationURL {
            try SafeFilePublisher.preflight(outputURL: dest, overwrite: overwrite)
            let destCaps = try APFSAutoStage.inspectVolume(at: dest)
            let siblingTemp = SafeFilePublisher.makeTempURL(beside: dest)
            do {
                if destCaps.supportsClonefile && destCaps.supportsRenameExcl,
                   Darwin.clonefile(cachedSeg.path, siblingTemp.path, 0) == 0 {
                    usedClone = true
                } else {
                    try APFSAutoStage.streamCopy(from: cachedSeg, to: siblingTemp)
                }
                try SafeFilePublisher.publish(tempURL: siblingTemp, to: dest, overwrite: overwrite)
            } catch {
                try? FileManager.default.removeItem(at: siblingTemp)
                throw error
            }
        }

        if var updatedMeta = meta {
            updatedMeta.lastAccessedUnix = Date().timeIntervalSince1970
            let tmp = SafeFilePublisher.makeTempURL(beside: mURL)
            if (try? JSONEncoder().encode(updatedMeta).write(to: tmp)) != nil {
                try? SafeFilePublisher.publish(tempURL: tmp, to: mURL, overwrite: true)
            }
        }

        return ForgeSceneCacheLookupReport(
            key: key,
            hit: true,
            cachedPath: cachedSeg.path,
            materializedPath: destinationURL?.path ?? cachedSeg.path,
            usedClonefile: usedClone,
            bytes: validated.bytes,
            sha256: validated.sha256,
            wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        )
    }

    private static func scanEntries(root: URL) throws -> [(key: String, segURL: URL, metaURL: URL, bytes: Int64, lastAccess: TimeInterval)] {
        let items = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        var out: [(String, URL, URL, Int64, TimeInterval)] = []
        for url in items {
            let name = url.lastPathComponent
            if name.hasPrefix("._") || name.hasPrefix(".") || !name.hasSuffix(".mp4") { continue }
            let key = String(name.dropLast(4))
            let mURL = metaFileURL(root: root, key: key)
            let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            var size = Int64(vals?.fileSize ?? 0)
            var access = vals?.contentModificationDate?.timeIntervalSince1970 ?? 0
            if let data = try? Data(contentsOf: mURL),
               let meta = try? JSONDecoder().decode(ForgeSceneCacheEntryMeta.self, from: data) {
                size = max(size, meta.byteSize)
                access = meta.lastAccessedUnix
            }
            out.append((key, url, mURL, size, access))
        }
        return out
    }

    public static func cacheStats(cacheRoot: URL? = nil) throws -> ForgeSceneCacheStatsReport {
        let root = try resolveCacheRoot(cacheRoot)
        let caps = try APFSAutoStage.inspectVolume(at: root)
        let entries = try scanEntries(root: root)
        let total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        return ForgeSceneCacheStatsReport(
            cacheRoot: root.path,
            fsType: caps.fsType,
            isAPFS: caps.isAPFS,
            supportsClonefile: caps.supportsClonefile,
            entryCount: entries.count,
            totalBytes: total
        )
    }

    public static func pruneLRU(cacheRoot: URL? = nil, maxBytes: Int64) throws -> ForgeSceneCachePruneReport {
        let root = try resolveCacheRoot(cacheRoot)
        let targetMax = max(0, maxBytes)
        var entries = try scanEntries(root: root).sorted { $0.lastAccess < $1.lastAccess }
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        var removed = 0
        var freed: Int64 = 0

        while total > targetMax, !entries.isEmpty {
            let victim = entries.removeFirst()
            try? FileManager.default.removeItem(at: victim.segURL)
            try? FileManager.default.removeItem(at: victim.metaURL)
            total -= victim.bytes
            freed += victim.bytes
            removed += 1
        }
        return ForgeSceneCachePruneReport(
            cacheRoot: root.path,
            maxBytes: targetMax,
            removedEntries: removed,
            freedBytes: freed,
            remainingEntries: entries.count,
            remainingBytes: max(0, total)
        )
    }
}

public struct ForgeSegmentStitchReport: Codable, Sendable, Equatable {
    public let segmentCount: Int
    public let stsdUniform: Bool
    public let hasAudioTrack: Bool
    public let hasSubtitleTrack: Bool
    public let durationSeconds: Double
    public let outputVideoPacketCount: Int
    public let outputPath: String
    public let usedClonefileSingleSegment: Bool
    public let wallMs: Double

    public init(
        segmentCount: Int,
        stsdUniform: Bool,
        hasAudioTrack: Bool,
        hasSubtitleTrack: Bool,
        durationSeconds: Double,
        outputVideoPacketCount: Int,
        outputPath: String,
        usedClonefileSingleSegment: Bool = false,
        wallMs: Double
    ) {
        self.segmentCount = segmentCount
        self.stsdUniform = stsdUniform
        self.hasAudioTrack = hasAudioTrack
        self.hasSubtitleTrack = hasSubtitleTrack
        self.durationSeconds = durationSeconds
        self.outputVideoPacketCount = outputVideoPacketCount
        self.outputPath = outputPath
        self.usedClonefileSingleSegment = usedClonefileSingleSegment
        self.wallMs = wallMs
    }

    public init(from report: StitchReport) {
        self.init(
            segmentCount: report.segmentCount,
            stsdUniform: report.stsdUniform,
            hasAudioTrack: report.hasAudioTrack,
            hasSubtitleTrack: report.hasSubtitleTrack,
            durationSeconds: report.durationSeconds,
            outputVideoPacketCount: report.outputVideoPacketCount,
            outputPath: report.outputPath,
            usedClonefileSingleSegment: false,
            wallMs: report.wallMs
        )
    }
}

/// Lossless closed-GOP MP4/MOV segment stitcher wrapping `SafariumCore.ClosedGOPStitcher`
/// (pure `CMSampleBuffer` passthrough remux without video re-encoding, plus single-segment CoW passthrough).
public enum ClosedGOPSegmentStitcher {
    public static func splice(
        segments: [URL],
        wavURL: URL? = nil,
        audioStartSeconds: Double = 0,
        audioLang: String? = nil,
        subtitlesURL: URL? = nil,
        subtitleLang: String = "pol",
        outputURL: URL,
        aacBitrate: Int? = nil,
        requireUniformFormatDescription: Bool = true,
        overwrite: Bool = false
    ) async throws -> ForgeSegmentStitchReport {
        guard !segments.isEmpty else {
            throw SafariumError.invalidState("ClosedGOPSegmentStitcher requires at least 1 segment")
        }
        for seg in segments {
            _ = try ForgeIncrementalCache.validateSegmentFile(at: seg)
        }

        if segments.count == 1, wavURL == nil, subtitlesURL == nil {
            let t0 = DispatchTime.now().uptimeNanoseconds
            try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)
            let probe = try await PacketProbe.inspect(url: segments[0], includeAudioPackets: false)
            guard let vTrack = probe.tracks.first(where: { $0.mediaType == "vide" }) else {
                throw SafariumError.invalidState("segment has no video track: \(segments[0].path)")
            }
            let siblingTemp = SafeFilePublisher.makeTempURL(beside: outputURL)
            let usedClone: Bool
            do {
                usedClone = try LosslessSoundtrackMux.cloneOrCopy(from: segments[0], to: siblingTemp, overwrite: true)
                try SafeFilePublisher.publish(tempURL: siblingTemp, to: outputURL, overwrite: overwrite)
            } catch {
                try? FileManager.default.removeItem(at: siblingTemp)
                throw error
            }
            return ForgeSegmentStitchReport(
                segmentCount: 1,
                stsdUniform: true,
                hasAudioTrack: probe.tracks.contains(where: { $0.mediaType == "soun" }),
                hasSubtitleTrack: probe.tracks.contains(where: { $0.mediaType == "sbtl" }),
                durationSeconds: probe.durationSeconds,
                outputVideoPacketCount: vTrack.packetCount,
                outputPath: outputURL.path,
                usedClonefileSingleSegment: usedClone,
                wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            )
        }

        let report = try await SafariumCore.ClosedGOPStitcher.splice(
            segments: segments,
            wavURL: wavURL,
            audioStartSeconds: audioStartSeconds,
            audioLang: audioLang,
            subtitlesURL: subtitlesURL,
            subtitleLang: subtitleLang,
            outputURL: outputURL,
            aacBitrate: aacBitrate,
            requireUniformFormatDescription: requireUniformFormatDescription,
            overwrite: overwrite
        )
        return ForgeSegmentStitchReport(from: report)
    }
}
