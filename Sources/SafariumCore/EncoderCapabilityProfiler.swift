import CoreMedia
import CoreVideo
import Darwin
import Foundation
import VideoToolbox

// MARK: - Wave 11A: Live VideoToolbox Encoder Capability Profiler

/// An encoder entry enumerated directly from Apple VideoToolbox via `VTCopyVideoEncoderList`.
public struct EnumeratedVTEncoder: Codable, Sendable, Equatable {
    public let codecFourCC: String
    public let codecType: UInt32
    public let encoderID: String
    public let codecName: String
    public let encoderName: String
    public let displayName: String
    public let isHardwareAccelerated: Bool
    public let instanceLimit: Int?

    public init(
        codecFourCC: String,
        codecType: UInt32,
        encoderID: String,
        codecName: String,
        encoderName: String,
        displayName: String,
        isHardwareAccelerated: Bool,
        instanceLimit: Int? = nil
    ) {
        self.codecFourCC = codecFourCC
        self.codecType = codecType
        self.encoderID = encoderID
        self.codecName = codecName
        self.encoderName = encoderName
        self.displayName = displayName
        self.isHardwareAccelerated = isHardwareAccelerated
        self.instanceLimit = instanceLimit
    }
}

/// Live probe result for a single VideoToolbox session property key.
public struct VTPropertyProbeResult: Codable, Sendable, Equatable {
    public let key: String
    public let inSupportedDictionary: Bool
    public let setterOSStatus: Int32
    public let readbackSupported: Bool
    public let accepted: Bool

    public init(
        key: String,
        inSupportedDictionary: Bool,
        setterOSStatus: Int32,
        readbackSupported: Bool,
        accepted: Bool
    ) {
        self.key = key
        self.inSupportedDictionary = inSupportedDictionary
        self.setterOSStatus = setterOSStatus
        self.readbackSupported = readbackSupported
        self.accepted = accepted
    }
}

/// Verified runtime capability profile for a single video codec on the current Mac & macOS build.
public struct CodecCapabilityProfile: Codable, Sendable, Equatable {
    public let codecFourCC: String
    public let codecName: String
    public let encoderID: String?
    public let displayName: String?
    public let hardwareAccelerated: Bool
    public let isSoftwareFallback: Bool
    public let maxWidth: Int
    public let maxHeight: Int
    public let supportsMain10: Bool
    public let supports422: Bool
    public let supports444: Bool
    public let supportsAlpha: Bool
    public let supportsMultipass: Bool
    public let supportsSpatialAQ: Bool
    public let supportsBaseFrameQP: Bool
    public let supportsOpenGOP: Bool
    public let supportsLookAhead: Bool
    public let supportsVBV: Bool
    public let supportsCQF: Bool
    public let supportsPreserveDynamicHDR: Bool
    public let recommendedParallelizationLimit: Int?
    public let propertyProbes: [VTPropertyProbeResult]

    public init(
        codecFourCC: String,
        codecName: String,
        encoderID: String?,
        displayName: String?,
        hardwareAccelerated: Bool,
        isSoftwareFallback: Bool,
        maxWidth: Int,
        maxHeight: Int,
        supportsMain10: Bool,
        supports422: Bool,
        supports444: Bool,
        supportsAlpha: Bool,
        supportsMultipass: Bool,
        supportsSpatialAQ: Bool,
        supportsBaseFrameQP: Bool,
        supportsOpenGOP: Bool,
        supportsLookAhead: Bool,
        supportsVBV: Bool,
        supportsCQF: Bool,
        supportsPreserveDynamicHDR: Bool,
        recommendedParallelizationLimit: Int?,
        propertyProbes: [VTPropertyProbeResult]
    ) {
        self.codecFourCC = codecFourCC
        self.codecName = codecName
        self.encoderID = encoderID
        self.displayName = displayName
        self.hardwareAccelerated = hardwareAccelerated
        self.isSoftwareFallback = isSoftwareFallback
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.supportsMain10 = supportsMain10
        self.supports422 = supports422
        self.supports444 = supports444
        self.supportsAlpha = supportsAlpha
        self.supportsMultipass = supportsMultipass
        self.supportsSpatialAQ = supportsSpatialAQ
        self.supportsBaseFrameQP = supportsBaseFrameQP
        self.supportsOpenGOP = supportsOpenGOP
        self.supportsLookAhead = supportsLookAhead
        self.supportsVBV = supportsVBV
        self.supportsCQF = supportsCQF
        self.supportsPreserveDynamicHDR = supportsPreserveDynamicHDR
        self.recommendedParallelizationLimit = recommendedParallelizationLimit
        self.propertyProbes = propertyProbes
    }

    /// True if at least one encoder (hardware or software) was instantiated for this codec.
    public var isAvailable: Bool {
        hardwareAccelerated || isSoftwareFallback || encoderID != nil
    }
}

/// Complete machine + OS VideoToolbox encoder capability snapshot suitable for JSON caching & diagnostics.
public struct EncoderCapabilitySnapshot: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let probedAtISO8601: String
    public let machineModel: String
    public let chipName: String
    public let osVersion: String
    public let osBuild: String
    public let physicalMemoryBytes: UInt64
    public let cpuCount: Int
    public let availableEncoders: [EnumeratedVTEncoder]
    public let codecs: [CodecCapabilityProfile]

    public init(
        schemaVersion: Int,
        probedAtISO8601: String,
        machineModel: String,
        chipName: String,
        osVersion: String,
        osBuild: String,
        physicalMemoryBytes: UInt64,
        cpuCount: Int,
        availableEncoders: [EnumeratedVTEncoder],
        codecs: [CodecCapabilityProfile]
    ) {
        self.schemaVersion = schemaVersion
        self.probedAtISO8601 = probedAtISO8601
        self.machineModel = machineModel
        self.chipName = chipName
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.physicalMemoryBytes = physicalMemoryBytes
        self.cpuCount = cpuCount
        self.availableEncoders = availableEncoders
        self.codecs = codecs
    }

    /// Looks up a codec profile by FourCC (case-insensitive) or common alias (`h264`, `hevc`, `av1`).
    public func profile(for fourCC: String) -> CodecCapabilityProfile? {
        let normalized = EncoderCapabilityProfiler.canonicalFourCC(for: fourCC)
        return codecs.first { $0.codecFourCC.lowercased() == normalized }
    }
}

/// Fail-closed validation errors returned by `EncoderCapabilityProfiler.validateRequirement`.
public enum EncoderCapabilityError: Error, CustomStringConvertible, Equatable, Sendable {
    case codecUnavailable(codecFourCC: String, availableFourCCs: [String])
    case hardwareRequiredButUnavailable(codecFourCC: String, encoderID: String?, isSoftwareFallback: Bool)
    case multipassRequiredButUnsupported(codecFourCC: String, encoderID: String?)
    case tenBitRequiredButUnsupported(codecFourCC: String, encoderID: String?)

    public var description: String {
        switch self {
        case .codecUnavailable(let fourCC, let available):
            return "VideoToolbox encoder '\(fourCC)' is unavailable on this machine (available: \(available.joined(separator: ", ")))"
        case .hardwareRequiredButUnavailable(let fourCC, let encoderID, let isSW):
            let idStr = encoderID ?? "none"
            return "Hardware-accelerated '\(fourCC)' encoding is required but unavailable (encoderID: \(idStr), softwareFallback: \(isSW))"
        case .multipassRequiredButUnsupported(let fourCC, let encoderID):
            let idStr = encoderID ?? "none"
            return "Multi-pass encoding is required for '\(fourCC)' but unsupported by encoder '\(idStr)'"
        case .tenBitRequiredButUnsupported(let fourCC, let encoderID):
            let idStr = encoderID ?? "none"
            return "10-bit encoding is required for '\(fourCC)' but unsupported by encoder '\(idStr)'"
        }
    }
}

/// Live Apple VideoToolbox capability profiler with honest hardware/software reporting and per-machine caching.
public enum EncoderCapabilityProfiler {
    public static let currentSchemaVersion: Int = 1

    private struct TargetCodec {
        let fourCC: String
        let codecType: CMVideoCodecType
        let displayName: String
    }

    private static let av1CodecType: CMVideoCodecType = 0x61763031 // 'av01'

    private static let targetCodecs: [TargetCodec] = [
        TargetCodec(fourCC: "avc1", codecType: kCMVideoCodecType_H264, displayName: "H.264 / AVC"),
        TargetCodec(fourCC: "hvc1", codecType: kCMVideoCodecType_HEVC, displayName: "HEVC / H.265"),
        TargetCodec(fourCC: "muxa", codecType: kCMVideoCodecType_HEVCWithAlpha, displayName: "HEVC with Alpha"),
        TargetCodec(fourCC: "apcn", codecType: kCMVideoCodecType_AppleProRes422, displayName: "Apple ProRes 422"),
        TargetCodec(fourCC: "apch", codecType: kCMVideoCodecType_AppleProRes422HQ, displayName: "Apple ProRes 422 HQ"),
        TargetCodec(fourCC: "ap4h", codecType: kCMVideoCodecType_AppleProRes4444, displayName: "Apple ProRes 4444"),
        TargetCodec(fourCC: "av01", codecType: av1CodecType, displayName: "AV1"),
    ]

    // MARK: - Encoder Enumeration

    /// Enumerates all video encoders registered with Apple VideoToolbox via `VTCopyVideoEncoderList`.
    public static func enumerateEncoders() -> [EnumeratedVTEncoder] {
        var listOut: CFArray?
        let status = VTCopyVideoEncoderList(nil, &listOut)
        guard status == noErr, let cfArray = listOut as? [[String: Any]] else {
            return []
        }

        var results: [EnumeratedVTEncoder] = []
        results.reserveCapacity(cfArray.count)

        let codecTypeKey = kVTVideoEncoderList_CodecType as String
        let encoderIDKey = kVTVideoEncoderList_EncoderID as String
        let codecNameKey = kVTVideoEncoderList_CodecName as String
        let encoderNameKey = kVTVideoEncoderList_EncoderName as String
        let displayNameKey = kVTVideoEncoderList_DisplayName as String

        for entry in cfArray {
            let codecNum: UInt32
            if let num = entry[codecTypeKey] as? NSNumber {
                codecNum = num.uint32Value
            } else if let rawInt = entry[codecTypeKey] as? Int {
                codecNum = UInt32(bitPattern: Int32(truncatingIfNeeded: rawInt))
            } else {
                continue
            }

            let fourCC = fourCCString(from: codecNum)
            let encoderID = (entry[encoderIDKey] as? String) ?? ""
            let codecName = (entry[codecNameKey] as? String) ?? fourCC
            let encoderName = (entry[encoderNameKey] as? String) ?? encoderID
            let displayName = (entry[displayNameKey] as? String) ?? encoderName

            let isHW: Bool
            if let hwBool = entry["IsHardwareAccelerated"] as? Bool {
                isHW = hwBool
            } else if let hwNum = entry["IsHardwareAccelerated"] as? NSNumber {
                isHW = hwNum.boolValue
            } else {
                isHW = false
            }

            let instanceLimit: Int?
            if let lim = entry["InstanceLimit"] as? NSNumber {
                instanceLimit = lim.intValue
            } else {
                instanceLimit = nil
            }

            results.append(
                EnumeratedVTEncoder(
                    codecFourCC: fourCC,
                    codecType: codecNum,
                    encoderID: encoderID,
                    codecName: codecName,
                    encoderName: encoderName,
                    displayName: displayName,
                    isHardwareAccelerated: isHW,
                    instanceLimit: instanceLimit
                )
            )
        }

        return results
    }

    // MARK: - Live Probing & Caching

    /// Probes real VideoToolbox capabilities on this machine, optionally reading/writing a per-machine/OS JSON cache.
    public static func probeLive(useCache: Bool = true, forceRefresh: Bool = false) -> EncoderCapabilitySnapshot {
        let host = currentHostIdentity()
        let cacheURL = cacheFileURL(for: host)

        if useCache && !forceRefresh, let cached = loadCachedSnapshot(from: cacheURL, expectedHost: host) {
            return cached
        }

        let enumerated = enumerateEncoders()
        var profiles: [CodecCapabilityProfile] = []
        profiles.reserveCapacity(targetCodecs.count)

        for target in targetCodecs {
            let profile = probeCodec(target: target, enumerated: enumerated, host: host)
            profiles.append(profile)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let snapshot = EncoderCapabilitySnapshot(
            schemaVersion: currentSchemaVersion,
            probedAtISO8601: formatter.string(from: Date()),
            machineModel: host.machineModel,
            chipName: host.chipName,
            osVersion: host.osVersion,
            osBuild: host.osBuild,
            physicalMemoryBytes: host.physicalMemoryBytes,
            cpuCount: host.cpuCount,
            availableEncoders: enumerated,
            codecs: profiles
        )

        if useCache {
            saveCachedSnapshot(snapshot, to: cacheURL)
        }

        return snapshot
    }

    // MARK: - Fail-Closed Requirement Validation

    /// Validates that a requested codec and feature requirements are genuinely supported by the probed snapshot.
    public static func validateRequirement(
        codecFourCC: String,
        requireHardware: Bool,
        requireMultipass: Bool,
        require10Bit: Bool,
        snapshot: EncoderCapabilitySnapshot
    ) throws -> CodecCapabilityProfile {
        let canonical = canonicalFourCC(for: codecFourCC)
        guard let profile = snapshot.codecs.first(where: { $0.codecFourCC.lowercased() == canonical }),
              profile.isAvailable else {
            let available = snapshot.codecs.filter { $0.isAvailable }.map { $0.codecFourCC }
            throw EncoderCapabilityError.codecUnavailable(codecFourCC: canonical, availableFourCCs: available)
        }

        if requireHardware && !profile.hardwareAccelerated {
            throw EncoderCapabilityError.hardwareRequiredButUnavailable(
                codecFourCC: profile.codecFourCC,
                encoderID: profile.encoderID,
                isSoftwareFallback: profile.isSoftwareFallback
            )
        }

        if requireMultipass && !profile.supportsMultipass {
            throw EncoderCapabilityError.multipassRequiredButUnsupported(
                codecFourCC: profile.codecFourCC,
                encoderID: profile.encoderID
            )
        }

        if require10Bit && !profile.supportsMain10 {
            throw EncoderCapabilityError.tenBitRequiredButUnsupported(
                codecFourCC: profile.codecFourCC,
                encoderID: profile.encoderID
            )
        }

        return profile
    }

    // MARK: - Canonical FourCC Helper

    public static func canonicalFourCC(for input: String) -> String {
        switch input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "h264", "h.264", "avc", "avc1":
            return "avc1"
        case "hevc", "h265", "h.265", "hvc1", "hev1":
            return "hvc1"
        case "hevc-alpha", "hevcalpha", "muxa":
            return "muxa"
        case "prores", "prores422", "apcn":
            return "apcn"
        case "prores422hq", "proreshq", "apch":
            return "apch"
        case "prores4444", "ap4h":
            return "ap4h"
        case "av1", "av01":
            return "av01"
        default:
            return input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    public static func fourCCString(from value: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
        let isPrintable = bytes.allSatisfy { $0 >= 0x20 && $0 <= 0x7E }
        if isPrintable {
            return String(decoding: bytes, as: UTF8.self)
        }
        return String(format: "0x%08x", value)
    }

    // MARK: - Internal Probing Logic

    private struct HostIdentity {
        let machineModel: String
        let chipName: String
        let osVersion: String
        let osBuild: String
        let physicalMemoryBytes: UInt64
        let cpuCount: Int
        let estimatedMediaEngines: Int

        var cacheKey: String {
            let raw = "\(machineModel)-\(osVersion)-\(osBuild)"
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
            return raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce("") { $0 + String($1) }
        }
    }

    private static func currentHostIdentity() -> HostIdentity {
        let model = readSysctlString("hw.model") ?? "UnknownMac"
        let chip = readSysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)"
        let osBuild = readSysctlString("kern.osversion") ?? "unknown"
        let memBytes = ProcessInfo.processInfo.physicalMemory
        let cpus = ProcessInfo.processInfo.processorCount

        let lowerChip = chip.lowercased()
        let engines: Int
        if lowerChip.contains("ultra") {
            engines = 4
        } else if lowerChip.contains("max") {
            engines = 2
        } else {
            engines = 1
        }

        return HostIdentity(
            machineModel: model,
            chipName: chip,
            osVersion: osVersion,
            osBuild: osBuild,
            physicalMemoryBytes: memBytes,
            cpuCount: cpus,
            estimatedMediaEngines: engines
        )
    }

    private static func probeCodec(
        target: TargetCodec,
        enumerated: [EnumeratedVTEncoder],
        host: HostIdentity
    ) -> CodecCapabilityProfile {
        let probeWidth: Int32 = 640
        let probeHeight: Int32 = 360

        let matchingEnumerated = enumerated.filter { $0.codecType == target.codecType }
        let preferredHW = matchingEnumerated.first { $0.isHardwareAccelerated }
        let preferredAny = preferredHW ?? matchingEnumerated.first

        // Step 1: Query VTCopySupportedPropertyDictionaryForEncoder (HW first, then general).
        let hwSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        let enableHWSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]

        var dictEncoderID: String?
        var supportedDictKeys = Set<String>()

        if let (encID, keys) = copySupportedPropertyDict(
            width: probeWidth,
            height: probeHeight,
            codecType: target.codecType,
            spec: hwSpec
        ) {
            dictEncoderID = encID
            supportedDictKeys.formUnion(keys)
        } else if let (encID, keys) = copySupportedPropertyDict(
            width: probeWidth,
            height: probeHeight,
            codecType: target.codecType,
            spec: enableHWSpec
        ) {
            dictEncoderID = encID
            supportedDictKeys.formUnion(keys)
        }

        // Step 2: Create a real live VTCompressionSession (require HW first, then allow SW fallback).
        var session: VTCompressionSession?
        var sessionCreatedWithHWRequirement = false

        if let hwSession = createSession(width: probeWidth, height: probeHeight, codecType: target.codecType, spec: hwSpec) {
            session = hwSession
            sessionCreatedWithHWRequirement = true
        } else if let fallbackSession = createSession(width: probeWidth, height: probeHeight, codecType: target.codecType, spec: enableHWSpec) {
            session = fallbackSession
        }

        guard let liveSession = session else {
            // Honest negative report: neither HW nor SW encoder session could be created (e.g. AV1 on chips without AV1 encode).
            return CodecCapabilityProfile(
                codecFourCC: target.fourCC,
                codecName: target.displayName,
                encoderID: dictEncoderID ?? preferredAny?.encoderID,
                displayName: preferredAny?.displayName,
                hardwareAccelerated: false,
                isSoftwareFallback: false,
                maxWidth: 0,
                maxHeight: 0,
                supportsMain10: false,
                supports422: false,
                supports444: false,
                supportsAlpha: false,
                supportsMultipass: false,
                supportsSpatialAQ: false,
                supportsBaseFrameQP: false,
                supportsOpenGOP: false,
                supportsLookAhead: false,
                supportsVBV: false,
                supportsCQF: false,
                supportsPreserveDynamicHDR: false,
                recommendedParallelizationLimit: nil,
                propertyProbes: []
            )
        }

        defer { VTCompressionSessionInvalidate(liveSession) }

        // Merge live session's supported property dictionary.
        var sessionDictCF: CFDictionary?
        if VTSessionCopySupportedPropertyDictionary(liveSession, supportedPropertyDictionaryOut: &sessionDictCF) == noErr,
           let map = sessionDictCF as? [String: Any] {
            supportedDictKeys.formUnion(map.keys)
        }

        // Step 3: Query actual runtime Hardware Accelerated flag and EncoderID from the live session.
        let usingHW: Bool = copyBoolProperty(
            session: liveSession,
            key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder
        ) ?? sessionCreatedWithHWRequirement

        let liveEncoderID: String? = copyStringProperty(
            session: liveSession,
            key: kVTCompressionPropertyKey_EncoderID
        ) ?? dictEncoderID ?? preferredAny?.encoderID

        let matchedByID = enumerated.first { $0.encoderID == liveEncoderID }
        let resolvedDisplayName = matchedByID?.displayName ?? preferredAny?.displayName ?? target.displayName
        let isSoftwareFallback = !usingHW

        // Step 4: Probe live property set + readback across key VideoToolbox knobs.
        let probes = runLivePropertyProbes(session: liveSession, supportedKeys: supportedDictKeys)
        let probeByKey = Dictionary(uniqueKeysWithValues: probes.map { ($0.key, $0) })

        let supportsMultipass = probeByKey["MultiPassStorage"]?.accepted ?? false
        let supportsSpatialAQ = probeByKey["SpatialAdaptiveQPLevel"]?.accepted ?? false
        let supportsBaseFrameQP = probeByKey["BaseFrameQP"]?.accepted ?? false
        let supportsOpenGOP = probeByKey["AllowOpenGOP"]?.accepted ?? false
        let supportsLookAhead = probeByKey["LookAheadFrames"]?.accepted
            ?? supportedDictKeys.contains("LookAheadFrames")
        let supportsVBV = (probeByKey["VBVMaxBitRate"]?.accepted ?? false)
            || (supportedDictKeys.contains("VariableBitRate") && supportedDictKeys.contains("VBVMaxBitRate"))
            || (probeByKey["DataRateLimits"]?.accepted ?? false)
        let supportsCQF = probeByKey["ConstantQualityFactor"]?.accepted
            ?? supportedDictKeys.contains("ConstantQualityFactor")
        let supportsPreserveDynamicHDR = probeByKey["PreserveDynamicHDRMetadata"]?.accepted ?? false

        // Step 5: Probe bit depth, chroma subsampling, and alpha capabilities honestly.
        let chromaAndDepth = probeChromaAndBitDepth(
            codecType: target.codecType,
            fourCC: target.fourCC,
            session: liveSession,
            supportedKeys: supportedDictKeys
        )

        // Step 6: Probe maximum accepted resolution ceiling cleanly via VTCopySupportedPropertyDictionaryForEncoder.
        let activeSpec = usingHW ? hwSpec : enableHWSpec
        let (maxW, maxH) = probeMaxResolution(codecType: target.codecType, spec: activeSpec)

        // Step 7: Compute recommended parallelization limit.
        let parallelLimit: Int
        if let vtInstanceLimit = matchedByID?.instanceLimit, vtInstanceLimit > 0 {
            parallelLimit = min(vtInstanceLimit, max(1, host.estimatedMediaEngines * 2))
        } else if usingHW {
            parallelLimit = max(1, min(4, host.estimatedMediaEngines))
        } else {
            parallelLimit = max(1, min(4, host.cpuCount / 2))
        }

        return CodecCapabilityProfile(
            codecFourCC: target.fourCC,
            codecName: target.displayName,
            encoderID: liveEncoderID,
            displayName: resolvedDisplayName,
            hardwareAccelerated: usingHW,
            isSoftwareFallback: isSoftwareFallback,
            maxWidth: maxW,
            maxHeight: maxH,
            supportsMain10: chromaAndDepth.supportsMain10,
            supports422: chromaAndDepth.supports422,
            supports444: chromaAndDepth.supports444,
            supportsAlpha: chromaAndDepth.supportsAlpha,
            supportsMultipass: supportsMultipass,
            supportsSpatialAQ: supportsSpatialAQ,
            supportsBaseFrameQP: supportsBaseFrameQP,
            supportsOpenGOP: supportsOpenGOP,
            supportsLookAhead: supportsLookAhead,
            supportsVBV: supportsVBV,
            supportsCQF: supportsCQF,
            supportsPreserveDynamicHDR: supportsPreserveDynamicHDR,
            recommendedParallelizationLimit: parallelLimit,
            propertyProbes: probes
        )
    }

    private static func copySupportedPropertyDict(
        width: Int32,
        height: Int32,
        codecType: CMVideoCodecType,
        spec: [CFString: Any]
    ) -> (String?, Set<String>)? {
        var encoderIDCF: CFString?
        var propsCF: CFDictionary?
        let status = VTCopySupportedPropertyDictionaryForEncoder(
            width: width,
            height: height,
            codecType: codecType,
            encoderSpecification: spec as CFDictionary,
            encoderIDOut: &encoderIDCF,
            supportedPropertiesOut: &propsCF
        )
        guard status == noErr else { return nil }
        let encID = encoderIDCF as String?
        let keys: Set<String>
        if let map = propsCF as? [String: Any] {
            keys = Set(map.keys)
        } else {
            keys = []
        }
        return (encID, keys)
    }

    private static func createSession(
        width: Int32,
        height: Int32,
        codecType: CMVideoCodecType,
        spec: [CFString: Any]
    ) -> VTCompressionSession? {
        var sessionOpt: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: codecType,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &sessionOpt
        )
        guard status == noErr else { return nil }
        return sessionOpt
    }

    private static func runLivePropertyProbes(
        session: VTCompressionSession,
        supportedKeys: Set<String>
    ) -> [VTPropertyProbeResult] {
        var results: [VTPropertyProbeResult] = []

        // 1. MultiPassStorage (uses an ephemeral VTMultiPassStorage handle that is closed right after probing).
        results.append(probeMultiPassStorage(session: session, supportedKeys: supportedKeys))

        // 2. SpatialAdaptiveQPLevel
        results.append(
            probeProperty(
                session: session,
                keyName: "SpatialAdaptiveQPLevel",
                keyCF: "SpatialAdaptiveQPLevel" as CFString,
                value: NSNumber(value: -1),
                supportedKeys: supportedKeys
            )
        )

        // 3. BaseFrameQP
        results.append(
            probeProperty(
                session: session,
                keyName: "BaseFrameQP",
                keyCF: "BaseFrameQP" as CFString,
                value: NSNumber(value: 24),
                supportedKeys: supportedKeys
            )
        )

        // 4. AllowOpenGOP
        results.append(
            probeProperty(
                session: session,
                keyName: "AllowOpenGOP",
                keyCF: kVTCompressionPropertyKey_AllowOpenGOP,
                value: kCFBooleanTrue,
                supportedKeys: supportedKeys
            )
        )

        // 5. MaxKeyFrameInterval
        results.append(
            probeProperty(
                session: session,
                keyName: "MaxKeyFrameInterval",
                keyCF: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                value: NSNumber(value: 60),
                supportedKeys: supportedKeys
            )
        )

        // 6. DataRateLimits
        let rateLimits: CFArray = [NSNumber(value: 2_000_000), NSNumber(value: 1)] as CFArray
        results.append(
            probeProperty(
                session: session,
                keyName: "DataRateLimits",
                keyCF: kVTCompressionPropertyKey_DataRateLimits,
                value: rateLimits,
                supportedKeys: supportedKeys
            )
        )

        // 7. Quality
        results.append(
            probeProperty(
                session: session,
                keyName: "Quality",
                keyCF: kVTCompressionPropertyKey_Quality,
                value: NSNumber(value: 0.75),
                supportedKeys: supportedKeys
            )
        )

        // 8. PreserveDynamicHDRMetadata
        results.append(
            probeProperty(
                session: session,
                keyName: "PreserveDynamicHDRMetadata",
                keyCF: "PreserveDynamicHDRMetadata" as CFString,
                value: kCFBooleanTrue,
                supportedKeys: supportedKeys
            )
        )

        // 9. ConstantQualityFactor
        results.append(
            probeProperty(
                session: session,
                keyName: "ConstantQualityFactor",
                keyCF: "ConstantQualityFactor" as CFString,
                value: NSNumber(value: 0.65),
                supportedKeys: supportedKeys
            )
        )

        // 10. LookAheadFrames
        results.append(
            probeProperty(
                session: session,
                keyName: "LookAheadFrames",
                keyCF: "LookAheadFrames" as CFString,
                value: NSNumber(value: 20),
                supportedKeys: supportedKeys
            )
        )

        // 11. VBVMaxBitRate
        results.append(
            probeProperty(
                session: session,
                keyName: "VBVMaxBitRate",
                keyCF: "VBVMaxBitRate" as CFString,
                value: NSNumber(value: 8_000_000),
                supportedKeys: supportedKeys
            )
        )

        return results
    }

    private static func probeMultiPassStorage(
        session: VTCompressionSession,
        supportedKeys: Set<String>
    ) -> VTPropertyProbeResult {
        let keyName = "MultiPassStorage"
        let inDict = supportedKeys.contains(keyName)

        var storageOut: VTMultiPassStorage?
        let createStatus = VTMultiPassStorageCreate(
            allocator: kCFAllocatorDefault,
            fileURL: nil,
            timeRange: .invalid,
            options: nil,
            multiPassStorageOut: &storageOut
        )

        guard createStatus == noErr, let storage = storageOut else {
            return VTPropertyProbeResult(
                key: keyName,
                inSupportedDictionary: inDict,
                setterOSStatus: createStatus,
                readbackSupported: false,
                accepted: false
            )
        }
        defer {
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MultiPassStorage, value: nil)
            VTMultiPassStorageClose(storage)
        }

        let setStatus = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MultiPassStorage,
            value: storage
        )
        let (getStatus, _) = copyVTProperty(
            session: session,
            key: kVTCompressionPropertyKey_MultiPassStorage
        )

        return VTPropertyProbeResult(
            key: keyName,
            inSupportedDictionary: inDict,
            setterOSStatus: setStatus,
            readbackSupported: getStatus == noErr,
            accepted: setStatus == noErr
        )
    }

    private static func probeProperty(
        session: VTCompressionSession,
        keyName: String,
        keyCF: CFString,
        value: CFTypeRef,
        supportedKeys: Set<String>
    ) -> VTPropertyProbeResult {
        let inDict = supportedKeys.contains(keyName)
        let setStatus = VTSessionSetProperty(session, key: keyCF, value: value)
        let (getStatus, _) = copyVTProperty(session: session, key: keyCF)
        return VTPropertyProbeResult(
            key: keyName,
            inSupportedDictionary: inDict,
            setterOSStatus: setStatus,
            readbackSupported: getStatus == noErr,
            accepted: setStatus == noErr
        )
    }

    private struct ChromaDepthCapabilities {
        let supportsMain10: Bool
        let supports422: Bool
        let supports444: Bool
        let supportsAlpha: Bool
    }

    private static func probeChromaAndBitDepth(
        codecType: CMVideoCodecType,
        fourCC: String,
        session: VTCompressionSession,
        supportedKeys: Set<String>
    ) -> ChromaDepthCapabilities {
        switch codecType {
        case kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVCWithAlpha:
            let main10 = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ProfileLevel,
                value: kVTProfileLevel_HEVC_Main10_AutoLevel
            ) == noErr
            let p422 = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ProfileLevel,
                value: "HEVC_Main42210_AutoLevel" as CFString
            ) == noErr
            let p444 = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ProfileLevel,
                value: "HEVC_Main44410_AutoLevel" as CFString
            ) == noErr
            let alpha = (codecType == kCMVideoCodecType_HEVCWithAlpha)
                || supportedKeys.contains("TargetQualityForAlpha")
            return ChromaDepthCapabilities(
                supportsMain10: main10,
                supports422: p422,
                supports444: p444,
                supportsAlpha: alpha
            )

        case kCMVideoCodecType_H264:
            let high10 = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ProfileLevel,
                value: "H264_High10_AutoLevel" as CFString
            ) == noErr
            let high422 = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ProfileLevel,
                value: "H264_High422_AutoLevel" as CFString
            ) == noErr
            let high444 = VTSessionSetProperty(
                session,
                key: kVTCompressionPropertyKey_ProfileLevel,
                value: "H264_High444Predictive_AutoLevel" as CFString
            ) == noErr
            return ChromaDepthCapabilities(
                supportsMain10: high10,
                supports422: high422,
                supports444: high444,
                supportsAlpha: false
            )

        case kCMVideoCodecType_AppleProRes422, kCMVideoCodecType_AppleProRes422HQ:
            return ChromaDepthCapabilities(
                supportsMain10: true,
                supports422: true,
                supports444: false,
                supportsAlpha: false
            )

        case kCMVideoCodecType_AppleProRes4444:
            return ChromaDepthCapabilities(
                supportsMain10: true,
                supports422: true,
                supports444: true,
                supportsAlpha: true
            )

        default:
            if fourCC == "av01" {
                let main10 = VTSessionSetProperty(
                    session,
                    key: kVTCompressionPropertyKey_ProfileLevel,
                    value: "AV1_Main_AutoLevel" as CFString
                ) == noErr
                return ChromaDepthCapabilities(
                    supportsMain10: main10,
                    supports422: false,
                    supports444: false,
                    supportsAlpha: false
                )
            }
            return ChromaDepthCapabilities(
                supportsMain10: false,
                supports422: false,
                supports444: false,
                supportsAlpha: false
            )
        }
    }

    private static func probeMaxResolution(
        codecType: CMVideoCodecType,
        spec: [CFString: Any]
    ) -> (Int, Int) {
        let tiers: [(Int32, Int32)] = [
            (8192, 4320),
            (7680, 4320),
            (4096, 2160),
            (3840, 2160),
            (1920, 1080),
            (640, 360),
        ]
        for (w, h) in tiers {
            if copySupportedPropertyDict(width: w, height: h, codecType: codecType, spec: spec) != nil {
                return (Int(w), Int(h))
            }
        }
        return (640, 360)
    }

    private static func copyVTProperty(
        session: VTCompressionSession,
        key: CFString
    ) -> (OSStatus, CFTypeRef?) {
        var rawOut: Unmanaged<CFTypeRef>?
        let status = withUnsafeMutablePointer(to: &rawOut) { ptr in
            VTSessionCopyProperty(
                session,
                key: key,
                allocator: kCFAllocatorDefault,
                valueOut: UnsafeMutableRawPointer(ptr)
            )
        }
        guard status == noErr else {
            return (status, nil)
        }
        return (status, rawOut?.takeRetainedValue())
    }

    private static func copyBoolProperty(session: VTCompressionSession, key: CFString) -> Bool? {
        let (status, val) = copyVTProperty(session: session, key: key)
        guard status == noErr, let num = val as? NSNumber else {
            return nil
        }
        return num.boolValue
    }

    private static func copyStringProperty(session: VTCompressionSession, key: CFString) -> String? {
        let (status, val) = copyVTProperty(session: session, key: key)
        guard status == noErr, let str = val as? String else {
            return nil
        }
        return str
    }

    // MARK: - Cache Storage

    private static func cacheFileURL(for host: HostIdentity) -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("Safarium", isDirectory: true)
            .appendingPathComponent("EncoderCapabilities", isDirectory: true)
        return base.appendingPathComponent("\(host.cacheKey).json", isDirectory: false)
    }

    private static func loadCachedSnapshot(from url: URL, expectedHost: HostIdentity) -> EncoderCapabilitySnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let decoded = try? JSONDecoder().decode(EncoderCapabilitySnapshot.self, from: data) else {
            return nil
        }
        guard decoded.schemaVersion == currentSchemaVersion,
              decoded.machineModel == expectedHost.machineModel,
              decoded.osVersion == expectedHost.osVersion,
              decoded.osBuild == expectedHost.osBuild else {
            return nil
        }
        return decoded
    }

    private static func saveCachedSnapshot(_ snapshot: EncoderCapabilitySnapshot, to url: URL) {
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            // Gracefully skip cache write when directory is unwritable or sandboxed.
        }
    }

    // MARK: - Sysctl Helpers

    private static func readSysctlString(_ name: String) -> String? {
        var size: Int = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
