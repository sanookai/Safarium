import AVFoundation
import CoreMedia
import Darwin
import Foundation
import Metal
import VideoToolbox
import WebKit

/// Runtime snapshot of host OS, graphics, media hardware, and filesystem capabilities.
public struct SafariumPlatformCapabilitySnapshot: Codable, Sendable, Equatable {
    public let osName: String
    public let osVersion: String
    public let architecture: String
    public let isAppleSilicon: Bool
    public let hasMetalGPU: Bool
    public let metalDeviceName: String?
    public let metalUnifiedMemory: Bool
    public let supportsWindowlessWebKit: Bool
    public let supportsVideoToolbox: Bool
    public let supportsHardwareH264Encode: Bool
    public let supportsHardwareHEVCEncode: Bool
    public let supportsAudioToolbox: Bool
    public let supportsANE: Bool
    public let supportsAPFSClonefile: Bool

    public init(
        osName: String,
        osVersion: String,
        architecture: String,
        isAppleSilicon: Bool,
        hasMetalGPU: Bool,
        metalDeviceName: String?,
        metalUnifiedMemory: Bool,
        supportsWindowlessWebKit: Bool,
        supportsVideoToolbox: Bool,
        supportsHardwareH264Encode: Bool,
        supportsHardwareHEVCEncode: Bool,
        supportsAudioToolbox: Bool,
        supportsANE: Bool,
        supportsAPFSClonefile: Bool
    ) {
        self.osName = osName
        self.osVersion = osVersion
        self.architecture = architecture
        self.isAppleSilicon = isAppleSilicon
        self.hasMetalGPU = hasMetalGPU
        self.metalDeviceName = metalDeviceName
        self.metalUnifiedMemory = metalUnifiedMemory
        self.supportsWindowlessWebKit = supportsWindowlessWebKit
        self.supportsVideoToolbox = supportsVideoToolbox
        self.supportsHardwareH264Encode = supportsHardwareH264Encode
        self.supportsHardwareHEVCEncode = supportsHardwareHEVCEncode
        self.supportsAudioToolbox = supportsAudioToolbox
        self.supportsANE = supportsANE
        self.supportsAPFSClonefile = supportsAPFSClonefile
    }
}

/// Runtime capability discovery contract for macOS / Apple Silicon hardware probes (including cloud VM fallback checks).
public protocol SafariumPlatformCapabilities: Sendable {
    var osName: String { get }
    var osVersion: String { get }
    var architecture: String { get }
    var isAppleSilicon: Bool { get }
    var hasMetalGPU: Bool { get }
    var metalDeviceName: String? { get }
    var supportsWindowlessWebKit: Bool { get }
    var supportsVideoToolbox: Bool { get }
    var supportsAudioToolbox: Bool { get }
    var supportsANE: Bool { get }
    var supportsAPFSClonefile: Bool { get }
    func capabilitySnapshot(probePath: URL?) -> SafariumPlatformCapabilitySnapshot
}

/// Native macOS web-to-raster frame rendering backend backed by windowless `WKWebView`.
public protocol WebFrameRendererBackend: Sendable {
    @MainActor func makeWebPage(config: PageConfig) async throws -> Page
    @MainActor func renderWebFrame(source: PageSource, config: PageConfig, seekSeconds: Double?) async throws -> Snapshot
}

/// Native macOS hardware video encoding sink factory backed by `AVAssetWriter` / VideoToolbox.
public protocol VideoEncoderBackend: Sendable {
    func supportsCodec(_ codec: VideoCodec) -> Bool
    func makeFrameSink(
        url: URL,
        width: Int,
        height: Int,
        fps: Int,
        codec: VideoCodec,
        bitrate: Int?,
        quality: Double?,
        pixelFormat: SinkPixelFormat,
        profile: EncoderProfile
    ) throws -> AVAssetWriterSink
}

/// Native macOS APFS copy-on-write clone / fallback stream-copy filesystem backend.
public protocol FilesystemCloneBackend: Sendable {
    func supportsClonefile(at url: URL) -> Bool
    @discardableResult
    func cloneOrCopy(from src: URL, to dst: URL, overwrite: Bool) throws -> Bool
}

/// Native macOS Apple Silicon backend backed by WebKit, Metal, VideoToolbox, AudioToolbox, Accelerate, and APFS `clonefile(2)`.
public struct AppleMacOSBackend:
    SafariumPlatformCapabilities,
    WebFrameRendererBackend,
    VideoEncoderBackend,
    FilesystemCloneBackend
{
    public static let current = AppleMacOSBackend()

    public init() {}

    public var osName: String { "macOS" }

    public var osVersion: String {
        ProcessInfo.processInfo.operatingSystemVersionString
    }

    public var architecture: String {
        var uts = utsname()
        guard uname(&uts) == 0 else { return "unknown" }
        return withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) {
                String(cString: $0)
            }
        }
    }

    public var isAppleSilicon: Bool {
        architecture == "arm64"
    }

    public var isRunningInVM: Bool {
        var vmm: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.hv_vmm_present", &vmm, &size, nil, 0) == 0 {
            return vmm != 0
        }
        return false
    }

    public var hasMetalGPU: Bool {
        SafariumMetalContext.shared != nil
    }

    public var metalDeviceName: String? {
        SafariumMetalContext.shared?.device.name
    }

    public var supportsWindowlessWebKit: Bool { true }
    public var supportsVideoToolbox: Bool { true }
    public var supportsAudioToolbox: Bool { true }

    public var supportsANE: Bool {
        isAppleSilicon && !isRunningInVM
    }

    public var supportsAPFSClonefile: Bool {
        supportsClonefile(at: URL(fileURLWithPath: "/tmp", isDirectory: true))
    }

    private static func hasHardwareEncoder(codecType: CMVideoCodecType) -> Bool {
        var encListCF: CFArray?
        guard VTCopyVideoEncoderList(nil, &encListCF) == noErr,
              let list = encListCF as? [[String: Any]] else {
            return false
        }
        return list.contains { entry in
            let ct = entry[kVTVideoEncoderList_CodecType as String] as? UInt32
            let isHW = (entry[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) ?? false
            return ct == codecType && isHW
        }
    }

    public func capabilitySnapshot(probePath: URL? = nil) -> SafariumPlatformCapabilitySnapshot {
        let metal = SafariumMetalContext.shared
        let cloneTarget = probePath ?? URL(fileURLWithPath: "/tmp", isDirectory: true)
        return SafariumPlatformCapabilitySnapshot(
            osName: osName,
            osVersion: osVersion,
            architecture: architecture,
            isAppleSilicon: isAppleSilicon,
            hasMetalGPU: metal != nil,
            metalDeviceName: metal?.device.name,
            metalUnifiedMemory: metal?.device.hasUnifiedMemory ?? false,
            supportsWindowlessWebKit: supportsWindowlessWebKit,
            supportsVideoToolbox: supportsVideoToolbox,
            supportsHardwareH264Encode: Self.hasHardwareEncoder(codecType: kCMVideoCodecType_H264),
            supportsHardwareHEVCEncode: Self.hasHardwareEncoder(codecType: kCMVideoCodecType_HEVC),
            supportsAudioToolbox: supportsAudioToolbox,
            supportsANE: supportsANE,
            supportsAPFSClonefile: supportsClonefile(at: cloneTarget)
        )
    }

    // MARK: - WebFrameRendererBackend

    @MainActor
    public func makeWebPage(config: PageConfig) async throws -> Page {
        try await Page(config: config)
    }

    @MainActor
    public func renderWebFrame(source: PageSource, config: PageConfig, seekSeconds: Double? = nil) async throws -> Snapshot {
        let page = try await makeWebPage(config: config)
        defer { page.close() }
        try await page.load(source)
        try await page.waitFor(.readyState)
        try await page.waitFor(.fonts)
        if let seekSeconds {
            try await page.seek(seekSeconds)
        }
        return try await page.snapshot()
    }

    // MARK: - VideoEncoderBackend

    public func supportsCodec(_ codec: VideoCodec) -> Bool {
        switch codec {
        case .h264, .hevc, .hevc10, .hevc42210, .hevc44410, .hevcAlpha,
             .proRes422Proxy, .proRes422LT, .proRes422, .proRes422HQ, .proRes4444, .proRes4444XQ:
            return true
        }
    }

    public func makeFrameSink(
        url: URL,
        width: Int,
        height: Int,
        fps: Int,
        codec: VideoCodec,
        bitrate: Int? = nil,
        quality: Double? = nil,
        pixelFormat: SinkPixelFormat = .bgra,
        profile: EncoderProfile = .baseline
    ) throws -> AVAssetWriterSink {
        try AVAssetWriterSink(
            url: url,
            width: width,
            height: height,
            fps: fps,
            codec: codec,
            bitrate: bitrate,
            quality: quality,
            pixelFormat: pixelFormat,
            profile: profile
        )
    }

    // MARK: - FilesystemCloneBackend

    public func supportsClonefile(at url: URL) -> Bool {
        var probe = url.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent.path == probe.path { break }
            probe = parent
        }
        var sfs = statfs()
        guard statfs(probe.path, &sfs) == 0 else { return false }
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
            return false
        }
        let intCaps = buf.caps.capabilities.1 & buf.caps.valid.1
        return (intCaps & UInt32(VOL_CAP_INT_CLONE)) != 0
    }

    @discardableResult
    public func cloneOrCopy(from src: URL, to dst: URL, overwrite: Bool = true) throws -> Bool {
        try LosslessSoundtrackMux.cloneOrCopy(from: src, to: dst, overwrite: overwrite)
    }
}
