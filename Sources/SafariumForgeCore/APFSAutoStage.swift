import Darwin
import Foundation
import SafariumCore

public struct ForgeVolumeCapabilities: Codable, Sendable, Equatable {
    public let path: String
    public let fsType: String
    public let mountPoint: String
    public let blockSize: UInt32
    public let isAPFS: Bool
    public let noPermissions: Bool
    public let supportsClonefile: Bool
    public let supportsRenameExcl: Bool
    public let supportsCaseSensitive: Bool

    public init(
        path: String,
        fsType: String,
        mountPoint: String,
        blockSize: UInt32,
        isAPFS: Bool,
        noPermissions: Bool,
        supportsClonefile: Bool,
        supportsRenameExcl: Bool,
        supportsCaseSensitive: Bool
    ) {
        self.path = path
        self.fsType = fsType
        self.mountPoint = mountPoint
        self.blockSize = blockSize
        self.isAPFS = isAPFS
        self.noPermissions = noPermissions
        self.supportsClonefile = supportsClonefile
        self.supportsRenameExcl = supportsRenameExcl
        self.supportsCaseSensitive = supportsCaseSensitive
    }
}

public struct ForgeCloneResult: Sendable {
    public let url: URL
    public let usedClonefile: Bool
    public let wallMs: Double
}

public enum APFSAutoStage {
    public static func defaultCacheRootURL() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.safarium.forge-stage", isDirectory: true)
    }

    public static func inspectVolume(at url: URL) throws -> ForgeVolumeCapabilities {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
        }

        var sfs = statfs()
        guard statfs(probe.path, &sfs) == 0 else {
            let err = errno
            throw SafariumError.invalidState("statfs(\(probe.path)) failed: \(String(cString: strerror(err)))")
        }
        let fsType = withUnsafePointer(to: &sfs.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
        }
        let mountPoint = withUnsafePointer(to: &sfs.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }

        var al = attrlist()
        al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        al.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_CAPABILITIES)
        struct CapBuf {
            var length: UInt32 = 0
            var caps: vol_capabilities_attr_t = vol_capabilities_attr_t()
        }
        var buf = CapBuf()
        guard getattrlist(mountPoint, &al, &buf, MemoryLayout<CapBuf>.size, 0) == 0 else {
            let err = errno
            throw SafariumError.invalidState("getattrlist(\(mountPoint)) failed: \(String(cString: strerror(err)))")
        }

        let fmtCaps = buf.caps.capabilities.0 & buf.caps.valid.0
        let intCaps = buf.caps.capabilities.1 & buf.caps.valid.1
        return ForgeVolumeCapabilities(
            path: url.path,
            fsType: fsType,
            mountPoint: mountPoint,
            blockSize: sfs.f_bsize,
            isAPFS: fsType.lowercased() == "apfs",
            noPermissions: (fmtCaps & UInt32(VOL_CAP_FMT_NO_PERMISSIONS)) != 0,
            supportsClonefile: (intCaps & UInt32(VOL_CAP_INT_CLONE)) != 0,
            supportsRenameExcl: (intCaps & UInt32(VOL_CAP_INT_RENAME_EXCL)) != 0,
            supportsCaseSensitive: (fmtCaps & UInt32(VOL_CAP_FMT_CASE_SENSITIVE)) != 0
        )
    }

    public static func makeSession(
        for outputURL: URL,
        cacheRoot: URL? = nil,
        overwrite: Bool = false
    ) throws -> APFSStageSession {
        try APFSStageSession(outputURL: outputURL, cacheRoot: cacheRoot, overwrite: overwrite)
    }

    /// Streams `sourceURL` to `destURL` using bounded 1 MiB chunk buffers so large ExFAT copies never spike RAM.
    public static func streamCopy(from sourceURL: URL, to destURL: URL) throws {
        let inFD = Darwin.open(sourceURL.path, O_RDONLY)
        guard inFD >= 0 else {
            let err = errno
            throw SafariumError.encode("open source for streamCopy failed: \(String(cString: strerror(err)))")
        }
        defer { _ = Darwin.close(inFD) }

        let outFD = Darwin.open(destURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard outFD >= 0 else {
            let err = errno
            throw SafariumError.encode("open destination for streamCopy failed: \(String(cString: strerror(err)))")
        }

        var completed = false
        defer {
            _ = Darwin.close(outFD)
            if !completed {
                _ = Darwin.unlink(destURL.path)
            }
        }

        let chunkSize = 1024 * 1024
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while true {
            let nRead = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(inFD, raw.baseAddress!, chunkSize)
            }
            if nRead == 0 { break }
            if nRead < 0 {
                if errno == EINTR { continue }
                let err = errno
                throw SafariumError.encode("read failed during streamCopy: \(String(cString: strerror(err)))")
            }
            var written = 0
            while written < nRead {
                let nWrite = buffer.withUnsafeBytes { raw in
                    Darwin.write(outFD, raw.baseAddress!.advanced(by: written), nRead - written)
                }
                if nWrite < 0 {
                    if errno == EINTR { continue }
                    let err = errno
                    throw SafariumError.encode("write failed during streamCopy: \(String(cString: strerror(err)))")
                }
                written += nWrite
            }
        }
        completed = true
    }
}

public final class APFSStageSession {
    public let id: UUID
    public let outputURL: URL
    public let targetVolume: ForgeVolumeCapabilities
    public let stageVolume: ForgeVolumeCapabilities
    public let stagingDirectory: URL
    public let isCrossVolumeExFATOrExternal: Bool

    public init(outputURL: URL, cacheRoot: URL? = nil, overwrite: Bool = false) throws {
        try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)
        let targetCaps = try APFSAutoStage.inspectVolume(at: outputURL)

        let root = cacheRoot ?? APFSAutoStage.defaultCacheRootURL()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = chmod(root.path, 0o700)

        let sessionID = UUID()
        let dir = root.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        guard Darwin.mkdir(dir.path, 0o700) == 0 else {
            let err = errno
            throw SafariumError.encode("cannot create APFS stage directory \(dir.path): \(String(cString: strerror(err)))")
        }
        _ = chmod(dir.path, 0o700)

        var st = stat()
        guard lstat(dir.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid(),
              (st.st_mode & 0o777) == 0o700 else {
            try? FileManager.default.removeItem(at: dir)
            throw SafariumError.invalidState("APFS staging directory must be private (0700) on a POSIX-permission volume: \(dir.path)")
        }

        let stageCaps = try APFSAutoStage.inspectVolume(at: dir)
        guard stageCaps.supportsClonefile && stageCaps.supportsRenameExcl else {
            try? FileManager.default.removeItem(at: dir)
            throw SafariumError.invalidState("APFS cache root \(root.path) must support clonefile and RENAME_EXCL")
        }

        self.id = sessionID
        self.outputURL = outputURL
        self.targetVolume = targetCaps
        self.stageVolume = stageCaps
        self.stagingDirectory = dir
        self.isCrossVolumeExFATOrExternal = !(targetCaps.supportsClonefile && targetCaps.supportsRenameExcl)
    }

    deinit {
        cleanup()
    }

    public func fileURL(_ relativeName: String) -> URL {
        stagingDirectory.appendingPathComponent(relativeName)
    }

    /// Clones an existing local file into the APFS staging directory using `Darwin.clonefile(2)` when on APFS,
    /// falling back to bounded 1 MiB streaming copy across filesystems (`EXDEV`/`ENOTSUP`).
    public func stageCopyOrClone(from srcURL: URL, named dstName: String, overwrite: Bool = true) throws -> ForgeCloneResult {
        try SafeFilePublisher.assertRegularReadableFile(srcURL)
        let dstURL = fileURL(dstName)
        if FileManager.default.fileExists(atPath: dstURL.path) {
            if overwrite {
                try FileManager.default.removeItem(at: dstURL)
            } else {
                throw SafariumError.invalidState("staged file already exists: \(dstURL.path)")
            }
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        if Darwin.clonefile(srcURL.path, dstURL.path, 0) == 0 {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            return ForgeCloneResult(url: dstURL, usedClonefile: true, wallMs: ms)
        }
        let err = errno
        if err == EXDEV || err == ENOTSUP || err == EOPNOTSUPP {
            try APFSAutoStage.streamCopy(from: srcURL, to: dstURL)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            return ForgeCloneResult(url: dstURL, usedClonefile: false, wallMs: ms)
        }
        throw SafariumError.encode("clonefile(\(srcURL.lastPathComponent)) failed: \(String(cString: strerror(err)))")
    }

    /// Commits `stagedFile` to `destination` (default `self.outputURL`).
    /// On same-device APFS: atomic `SafeFilePublisher.publish` (`renamex_np`).
    /// On cross-device ExFAT/external volume: bounded 1 MiB stream-copy to sibling temp beside `destination`,
    /// then atomic/exclusive `SafeFilePublisher.publish`.
    public func commit(stagedFile: URL, to destination: URL? = nil, overwrite: Bool = false) throws {
        let destURL = destination ?? outputURL
        try SafeFilePublisher.preflight(outputURL: destURL, overwrite: overwrite)

        var srcSt = stat()
        var dstDirSt = stat()
        let dstParent = destURL.deletingLastPathComponent()
        guard stat(stagedFile.path, &srcSt) == 0,
              stat(dstParent.path, &dstDirSt) == 0 else {
            throw SafariumError.invalidState("missing staged file or destination parent for commit")
        }

        let destCaps = try APFSAutoStage.inspectVolume(at: destURL)
        if srcSt.st_dev == dstDirSt.st_dev && destCaps.supportsRenameExcl {
            try SafeFilePublisher.publish(tempURL: stagedFile, to: destURL, overwrite: overwrite)
            return
        }

        // Cross-device (e.g. APFS cache -> ExFAT external volume): single bounded sequential write + SafeFilePublisher commit.
        let siblingTemp = SafeFilePublisher.makeTempURL(beside: destURL)
        do {
            try APFSAutoStage.streamCopy(from: stagedFile, to: siblingTemp)
            try SafeFilePublisher.publish(tempURL: siblingTemp, to: destURL, overwrite: overwrite)
        } catch {
            try? FileManager.default.removeItem(at: siblingTemp)
            throw error
        }
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: stagingDirectory)
    }
}
