import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SafariumCore

// MARK: - Wave 11B: Zero-FFmpeg Independent ISOBMFF & MPEG-TS Bitstream Conformance

/// Decoded HEVC Decoder Configuration Record (`hvcC` box, ISO/IEC 14496-15).
public struct HEVCConfigInfo: Codable, Sendable, Equatable {
    public let configurationVersion: UInt8
    public let generalProfileSpace: UInt8
    public let generalTierFlag: Bool
    public let generalProfileIdc: UInt8
    public let generalLevelIdc: UInt8
    /// `0` = monochrome, `1` = 4:2:0, `2` = 4:2:2, `3` = 4:4:4.
    public let chromaFormatIdc: UInt8
    /// Actual luma bit depth (`bitDepthLumaMinus8 + 8`).
    public let bitDepthLuma: Int
    /// Actual chroma bit depth (`bitDepthChromaMinus8 + 8`).
    public let bitDepthChroma: Int
    public let lengthSizeMinusOne: UInt8
    public let numOfArrays: UInt8

    public var profileName: String {
        switch generalProfileIdc {
        case 1: return "Main"
        case 2: return "Main10"
        case 3: return "MainStillPicture"
        case 4: return "Rext"
        default: return "Profile_\(generalProfileIdc)"
        }
    }
}

/// Decoded AVC Decoder Configuration Record (`avcC` box, ISO/IEC 14496-15).
public struct AVCConfigInfo: Codable, Sendable, Equatable {
    public let configurationVersion: UInt8
    public let avcProfileIndication: UInt8
    public let profileCompatibility: UInt8
    public let avcLevelIndication: UInt8
    public let lengthSizeMinusOne: UInt8
    public let spsCount: Int
    public let ppsCount: Int

    public var profileName: String {
        switch avcProfileIndication {
        case 66: return "Baseline"
        case 77: return "Main"
        case 88: return "Extended"
        case 100: return "High"
        case 110: return "High10"
        case 122: return "High422"
        case 244: return "High444"
        default: return "Profile_\(avcProfileIndication)"
        }
    }
}

/// Decoded Dolby Vision Configuration Record (`dvcC` / `dvvC` box).
public struct DolbyVisionConfigInfo: Codable, Sendable, Equatable {
    public let boxType: String
    public let dvVersionMajor: UInt8
    public let dvVersionMinor: UInt8
    public let dvProfile: UInt8
    public let dvLevel: UInt8
    public let rpuPresentFlag: Bool
    public let elPresentFlag: Bool
    public let blPresentFlag: Bool
    public let blSignalCompatibilityId: UInt8
}

/// Decoded ISOBMFF / QuickTime `colr` color box (`nclx` or `nclc`).
public struct ColorBoxInfo: Codable, Sendable, Equatable {
    public let colorType: String
    public let colorPrimaries: UInt16
    public let transferCharacteristics: UInt16
    public let matrixCoefficients: UInt16
    public let fullRangeFlag: Bool?
}

/// Decoded Mastering Display Color Volume (`mdcv`, SMPTE ST 2086).
public struct MasteringDisplayInfo: Codable, Sendable, Equatable {
    public let displayPrimariesX: [UInt16]
    public let displayPrimariesY: [UInt16]
    public let whitePointX: UInt16
    public let whitePointY: UInt16
    public let maxDisplayMasteringLuminance: UInt32
    public let minDisplayMasteringLuminance: UInt32
}

/// Decoded Content Light Level Info (`clli` box).
public struct ContentLightLevelInfo: Codable, Sendable, Equatable {
    public let maxContentLightLevel: UInt16
    public let maxPicAverageLightLevel: UInt16
}

/// Parsed fragmented CMAF track fragment (`moof` -> `mfhd` + `traf` -> `tfhd` + `tfdt` + `trun`).
public struct FragmentRunInfo: Codable, Sendable, Equatable {
    public let sequenceNumber: UInt32
    public let trackID: UInt32
    public let baseMediaDecodeTime: UInt64?
    public let sampleCount: UInt32
    public let firstSampleIsSync: Bool
}

/// Pure-Swift binary ISOBMFF / MP4 / MOV / CMAF inspection result.
public struct ISOBMFFInspectionResult: Codable, Sendable, Equatable {
    public let majorBrand: String?
    public let minorVersion: UInt32?
    public let compatibleBrands: [String]
    public let topLevelBoxes: [String]
    public let hasFtyp: Bool
    public let hasMoov: Bool
    public let hasMoof: Bool
    public let hasMdat: Bool
    public let videoTrackIDs: [UInt32]
    public let audioTrackIDs: [UInt32]
    public let sampleEntries: [String]
    public let videoCodecFourCC: String?
    public let audioCodecFourCC: String?
    public let hevcConfig: HEVCConfigInfo?
    public let avcConfig: AVCConfigInfo?
    public let dolbyVisionConfig: DolbyVisionConfigInfo?
    public let colorInfo: ColorBoxInfo?
    public let masteringDisplay: MasteringDisplayInfo?
    public let contentLightLevel: ContentLightLevelInfo?
    public let hasAmbientViewingEnvironment: Bool
    public let fragments: [FragmentRunInfo]
    public let violations: [String]
    public let isValid: Bool
}

/// Elementary stream descriptor extracted from an MPEG-TS PMT.
public struct MPEGTSElementaryStream: Codable, Sendable, Equatable {
    public let pid: UInt16
    public let streamType: UInt8
    public let codecName: String
}

/// Pure-Swift 188-byte MPEG-TS conformance inspection result.
public struct MPEGTSInspectionResult: Codable, Sendable, Equatable {
    public let totalBytes: Int
    public let packetCount: Int
    public let isPacketAligned: Bool
    public let syncErrors: Int
    public let hasPAT: Bool
    public let pmtPID: UInt16?
    public let hasPMT: Bool
    public let pcrPID: UInt16?
    public let elementaryStreams: [MPEGTSElementaryStream]
    public let hasVideoStream: Bool
    public let hasAudioStream: Bool
    public let pcrCount: Int
    public let pesPacketCount: Int
    public let ptsCount: Int
    public let dtsCount: Int
    public let firstPTSSeconds: Double?
    public let lastPTSSeconds: Double?
    public let continuityErrors: Int
    public let violations: [String]
    public let isValid: Bool
}

/// Independent `AVAssetReader` full-frame decode verification summary.
public struct IndependentDecodeResult: Codable, Sendable, Equatable {
    public let decodedVideoFrames: Int
    public let monotonicPTS: Bool
    public let nonZeroPixelVariance: Bool
    public let pixelVariance: Double
    public let hasAudioTrack: Bool
    public let decodedAudioBuffers: Int
    public let durationSeconds: Double
    public let width: Int
    public let height: Int
}

/// Complete media file bitstream & decode conformance report.
public struct BitstreamConformanceReport: Codable, Sendable, Equatable {
    public let filePath: String
    public let fileSizeBytes: Int64
    public let containerKind: String
    public let isobmff: ISOBMFFInspectionResult?
    public let mpegts: MPEGTSInspectionResult?
    public let detectedVideoCodec: String?
    public let detectedAudioCodec: String?
    public let detectedBitDepth: Int?
    public let detectedChromaFormat: Int?
    public let detectedPrimaries: UInt16?
    public let independentDecode: IndependentDecodeResult?
    public let violations: [String]
    public let passed: Bool
}

// MARK: - BitstreamConformance Parser & Verifier

/// Zero-FFmpeg independent binary ISOBMFF/CMAF/MPEG-TS parser and `AVAssetReader` conformance verifier.
public enum BitstreamConformance {

    private static let knownVideoFourCCs: Set<String> = [
        "avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe",
        "apch", "apcn", "ap4h", "ap4x", "apcs", "apco",
        "muxa", "vp09", "av01", "mp4v",
    ]

    private static let knownAudioFourCCs: Set<String> = [
        "mp4a", "alac", "Opus", "lpcm", "sowt", "twos",
        "fl32", "fl64", "in24", "in32", "ec-3", "ac-3", "apac",
    ]

    // MARK: - 1. Pure-Swift ISOBMFF / MP4 / MOV / CMAF Box Walker

    public static func inspectISOBMFF(url: URL) throws -> ISOBMFFInspectionResult {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return inspectISOBMFF(data: data)
    }

    public static func inspectISOBMFF(data: Data) -> ISOBMFFInspectionResult {
        var ctx = ISOBMFFParseContext()
        if data.count < 8 {
            ctx.violations.append("ISOBMFF data too small (\(data.count) bytes)")
            return ctx.buildResult()
        }

        data.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            walkBoxes(ptr: ptr, start: 0, end: raw.count, depth: 0, ctx: &ctx)
        }

        if !ctx.hasFtyp && !ctx.hasMoof {
            ctx.violations.append("Missing both ftyp and moof top-level boxes")
        }
        if !ctx.hasMoov && !ctx.hasMoof {
            ctx.violations.append("Missing both moov and moof boxes")
        }
        return ctx.buildResult()
    }

    private struct ISOBMFFParseContext {
        var majorBrand: String?
        var minorVersion: UInt32?
        var compatibleBrands: [String] = []
        var topLevelBoxes: [String] = []
        var hasFtyp = false
        var hasMoov = false
        var hasMoof = false
        var hasMdat = false
        var videoTrackIDs: [UInt32] = []
        var audioTrackIDs: [UInt32] = []
        var sampleEntries: [String] = []
        var videoCodecFourCC: String?
        var audioCodecFourCC: String?
        var hevcConfig: HEVCConfigInfo?
        var avcConfig: AVCConfigInfo?
        var dolbyVisionConfig: DolbyVisionConfigInfo?
        var colorInfo: ColorBoxInfo?
        var masteringDisplay: MasteringDisplayInfo?
        var contentLightLevel: ContentLightLevelInfo?
        var hasAmbientViewingEnvironment = false
        var fragments: [FragmentRunInfo] = []
        var violations: [String] = []

        // Transient per-trak and per-moof state
        var currentTrackID: UInt32?
        var currentTrackHandler: String?
        var currentMoofSequence: UInt32 = 0
        var currentTrafTrackID: UInt32 = 0
        var currentTrafDefaultFlags: UInt32?
        var currentTrafBaseDecodeTime: UInt64?

        func buildResult() -> ISOBMFFInspectionResult {
            ISOBMFFInspectionResult(
                majorBrand: majorBrand,
                minorVersion: minorVersion,
                compatibleBrands: compatibleBrands,
                topLevelBoxes: topLevelBoxes,
                hasFtyp: hasFtyp,
                hasMoov: hasMoov,
                hasMoof: hasMoof,
                hasMdat: hasMdat,
                videoTrackIDs: videoTrackIDs,
                audioTrackIDs: audioTrackIDs,
                sampleEntries: sampleEntries,
                videoCodecFourCC: videoCodecFourCC,
                audioCodecFourCC: audioCodecFourCC,
                hevcConfig: hevcConfig,
                avcConfig: avcConfig,
                dolbyVisionConfig: dolbyVisionConfig,
                colorInfo: colorInfo,
                masteringDisplay: masteringDisplay,
                contentLightLevel: contentLightLevel,
                hasAmbientViewingEnvironment: hasAmbientViewingEnvironment,
                fragments: fragments,
                violations: violations,
                isValid: violations.isEmpty
            )
        }
    }

    private static let containerBoxTypes: Set<String> = [
        "moov", "trak", "mdia", "minf", "stbl", "edts", "dinf", "mvex", "moof", "traf", "udta",
    ]

    private static func walkBoxes(
        ptr: UnsafePointer<UInt8>,
        start: Int,
        end: Int,
        depth: Int,
        ctx: inout ISOBMFFParseContext
    ) {
        guard depth < 16 else { return }
        var offset = start
        while offset + 8 <= end {
            let size32 = readUInt32BE(ptr, offset)
            let boxType = readFourCC(ptr, offset + 4)

            var headerSize = 8
            var boxSize64: UInt64
            if size32 == 1 {
                guard offset + 16 <= end else {
                    ctx.violations.append("Truncated extended-size box '\(boxType)' at offset \(offset)")
                    return
                }
                boxSize64 = readUInt64BE(ptr, offset + 8)
                headerSize = 16
            } else if size32 == 0 {
                boxSize64 = UInt64(end - offset)
            } else {
                boxSize64 = UInt64(size32)
            }

            if boxType == "uuid" {
                headerSize += 16
            }

            guard boxSize64 >= UInt64(headerSize), boxSize64 <= UInt64(end - offset) else {
                ctx.violations.append("Invalid box size \(boxSize64) for '\(boxType)' at offset \(offset)")
                return
            }

            let boxEnd = offset + Int(boxSize64)
            let payloadStart = offset + headerSize
            let payloadLen = boxEnd - payloadStart

            if depth == 0 {
                ctx.topLevelBoxes.append(boxType)
            }

            switch boxType {
            case "ftyp":
                ctx.hasFtyp = true
                parseFtyp(ptr: ptr, start: payloadStart, length: payloadLen, ctx: &ctx)

            case "moov":
                ctx.hasMoov = true
                walkBoxes(ptr: ptr, start: payloadStart, end: boxEnd, depth: depth + 1, ctx: &ctx)

            case "trak":
                ctx.currentTrackID = nil
                ctx.currentTrackHandler = nil
                walkBoxes(ptr: ptr, start: payloadStart, end: boxEnd, depth: depth + 1, ctx: &ctx)
                if let tid = ctx.currentTrackID {
                    if ctx.currentTrackHandler == "vide" {
                        ctx.videoTrackIDs.append(tid)
                    } else if ctx.currentTrackHandler == "soun" {
                        ctx.audioTrackIDs.append(tid)
                    }
                }
                ctx.currentTrackID = nil
                ctx.currentTrackHandler = nil

            case "tkhd":
                parseTkhd(ptr: ptr, start: payloadStart, length: payloadLen, ctx: &ctx)

            case "hdlr":
                parseHdlr(ptr: ptr, start: payloadStart, length: payloadLen, ctx: &ctx)

            case "stsd":
                parseStsd(ptr: ptr, start: payloadStart, end: boxEnd, depth: depth + 1, ctx: &ctx)

            case "hvcC":
                if let info = parseHvcC(ptr: ptr, start: payloadStart, length: payloadLen) {
                    ctx.hevcConfig = info
                }

            case "avcC":
                if let info = parseAvcC(ptr: ptr, start: payloadStart, length: payloadLen) {
                    ctx.avcConfig = info
                }

            case "dvcC", "dvvC":
                if let info = parseDolbyVisionConfig(boxType: boxType, ptr: ptr, start: payloadStart, length: payloadLen) {
                    ctx.dolbyVisionConfig = info
                }

            case "colr":
                if let info = parseColr(ptr: ptr, start: payloadStart, length: payloadLen) {
                    ctx.colorInfo = info
                }

            case "mdcv":
                if let info = parseMdcv(ptr: ptr, start: payloadStart, length: payloadLen) {
                    ctx.masteringDisplay = info
                }

            case "clli":
                if let info = parseClli(ptr: ptr, start: payloadStart, length: payloadLen) {
                    ctx.contentLightLevel = info
                }

            case "amve":
                ctx.hasAmbientViewingEnvironment = true

            case "moof":
                ctx.hasMoof = true
                ctx.currentMoofSequence = 0
                walkBoxes(ptr: ptr, start: payloadStart, end: boxEnd, depth: depth + 1, ctx: &ctx)

            case "mfhd":
                if payloadLen >= 8 {
                    ctx.currentMoofSequence = readUInt32BE(ptr, payloadStart + 4)
                }

            case "traf":
                ctx.currentTrafTrackID = 0
                ctx.currentTrafDefaultFlags = nil
                ctx.currentTrafBaseDecodeTime = nil
                walkBoxes(ptr: ptr, start: payloadStart, end: boxEnd, depth: depth + 1, ctx: &ctx)

            case "tfhd":
                parseTfhd(ptr: ptr, start: payloadStart, length: payloadLen, ctx: &ctx)

            case "tfdt":
                parseTfdt(ptr: ptr, start: payloadStart, length: payloadLen, ctx: &ctx)

            case "trun":
                parseTrun(ptr: ptr, start: payloadStart, length: payloadLen, ctx: &ctx)

            case "mdat":
                ctx.hasMdat = true

            default:
                if containerBoxTypes.contains(boxType) {
                    walkBoxes(ptr: ptr, start: payloadStart, end: boxEnd, depth: depth + 1, ctx: &ctx)
                }
            }

            offset = boxEnd
        }
    }

    private static func parseFtyp(ptr: UnsafePointer<UInt8>, start: Int, length: Int, ctx: inout ISOBMFFParseContext) {
        guard length >= 8 else {
            ctx.violations.append("ftyp box shorter than 8 bytes")
            return
        }
        ctx.majorBrand = readFourCC(ptr, start)
        ctx.minorVersion = readUInt32BE(ptr, start + 4)
        var off = start + 8
        let end = start + length
        while off + 4 <= end {
            ctx.compatibleBrands.append(readFourCC(ptr, off))
            off += 4
        }
    }

    private static func parseTkhd(ptr: UnsafePointer<UInt8>, start: Int, length: Int, ctx: inout ISOBMFFParseContext) {
        guard length >= 16 else { return }
        let version = ptr[start]
        if version == 0 && length >= 16 {
            ctx.currentTrackID = readUInt32BE(ptr, start + 12)
        } else if version == 1 && length >= 24 {
            ctx.currentTrackID = readUInt32BE(ptr, start + 20)
        }
    }

    private static func parseHdlr(ptr: UnsafePointer<UInt8>, start: Int, length: Int, ctx: inout ISOBMFFParseContext) {
        guard length >= 12 else { return }
        ctx.currentTrackHandler = readFourCC(ptr, start + 8)
    }

    private static func parseStsd(
        ptr: UnsafePointer<UInt8>,
        start: Int,
        end: Int,
        depth: Int,
        ctx: inout ISOBMFFParseContext
    ) {
        guard end - start >= 8 else { return }
        let entryCount = readUInt32BE(ptr, start + 4)
        var offset = start + 8
        let maxEntries = min(Int(entryCount), 32)

        for _ in 0..<maxEntries {
            guard offset + 8 <= end else { break }
            let entrySize = Int(readUInt32BE(ptr, offset))
            let fourCC = readFourCC(ptr, offset + 4)
            guard entrySize >= 8, offset + entrySize <= end else { break }

            ctx.sampleEntries.append(fourCC)
            if knownVideoFourCCs.contains(fourCC) && ctx.videoCodecFourCC == nil {
                ctx.videoCodecFourCC = fourCC
            } else if knownAudioFourCCs.contains(fourCC) && ctx.audioCodecFourCC == nil {
                ctx.audioCodecFourCC = fourCC
            }

            // VisualSampleEntry fixed header is 78 bytes after the 8-byte box header (total 86 bytes).
            let entryEnd = offset + entrySize
            let isVisual = knownVideoFourCCs.contains(fourCC) || ctx.currentTrackHandler == "vide"
            if isVisual && entrySize > 86 {
                walkBoxes(ptr: ptr, start: offset + 86, end: entryEnd, depth: depth + 1, ctx: &ctx)
            }
            offset = entryEnd
        }
    }

    private static func parseHvcC(ptr: UnsafePointer<UInt8>, start: Int, length: Int) -> HEVCConfigInfo? {
        guard length >= 23 else { return nil }
        let version = ptr[start + 0]
        let b1 = ptr[start + 1]
        let profileSpace = (b1 >> 6) & 0x03
        let tierFlag = ((b1 >> 5) & 0x01) != 0
        let profileIdc = b1 & 0x1F
        let levelIdc = ptr[start + 12]
        let chromaFormatIdc = ptr[start + 16] & 0x03
        let bitDepthLuma = Int(ptr[start + 17] & 0x07) + 8
        let bitDepthChroma = Int(ptr[start + 18] & 0x07) + 8
        let lengthSizeMinusOne = ptr[start + 21] & 0x03
        let numOfArrays = ptr[start + 22]

        return HEVCConfigInfo(
            configurationVersion: version,
            generalProfileSpace: profileSpace,
            generalTierFlag: tierFlag,
            generalProfileIdc: profileIdc,
            generalLevelIdc: levelIdc,
            chromaFormatIdc: chromaFormatIdc,
            bitDepthLuma: bitDepthLuma,
            bitDepthChroma: bitDepthChroma,
            lengthSizeMinusOne: lengthSizeMinusOne,
            numOfArrays: numOfArrays
        )
    }

    private static func parseAvcC(ptr: UnsafePointer<UInt8>, start: Int, length: Int) -> AVCConfigInfo? {
        guard length >= 7 else { return nil }
        let version = ptr[start + 0]
        let profile = ptr[start + 1]
        let compat = ptr[start + 2]
        let level = ptr[start + 3]
        let lengthSizeMinusOne = ptr[start + 4] & 0x03
        let spsCount = Int(ptr[start + 5] & 0x1F)

        var off = start + 6
        let end = start + length
        for _ in 0..<spsCount {
            guard off + 2 <= end else { break }
            let spsLen = Int(readUInt16BE(ptr, off))
            off += 2 + spsLen
        }
        let ppsCount: Int
        if off < end {
            ppsCount = Int(ptr[off])
        } else {
            ppsCount = 0
        }

        return AVCConfigInfo(
            configurationVersion: version,
            avcProfileIndication: profile,
            profileCompatibility: compat,
            avcLevelIndication: level,
            lengthSizeMinusOne: lengthSizeMinusOne,
            spsCount: spsCount,
            ppsCount: ppsCount
        )
    }

    private static func parseDolbyVisionConfig(
        boxType: String,
        ptr: UnsafePointer<UInt8>,
        start: Int,
        length: Int
    ) -> DolbyVisionConfigInfo? {
        guard length >= 5 else { return nil }
        let major = ptr[start + 0]
        let minor = ptr[start + 1]
        let b2 = ptr[start + 2]
        let b3 = ptr[start + 3]
        let b4 = ptr[start + 4]
        let profile = (b2 >> 1) & 0x7F
        let level = ((b2 & 0x01) << 5) | ((b3 >> 3) & 0x1F)
        let rpuPresent = ((b3 >> 2) & 0x01) != 0
        let elPresent = ((b3 >> 1) & 0x01) != 0
        let blPresent = (b3 & 0x01) != 0
        let blCompat = (b4 >> 4) & 0x0F

        return DolbyVisionConfigInfo(
            boxType: boxType,
            dvVersionMajor: major,
            dvVersionMinor: minor,
            dvProfile: profile,
            dvLevel: level,
            rpuPresentFlag: rpuPresent,
            elPresentFlag: elPresent,
            blPresentFlag: blPresent,
            blSignalCompatibilityId: blCompat
        )
    }

    private static func parseColr(ptr: UnsafePointer<UInt8>, start: Int, length: Int) -> ColorBoxInfo? {
        guard length >= 10 else { return nil }
        let colorType = readFourCC(ptr, start)
        guard colorType == "nclx" || colorType == "nclc" else { return nil }
        let primaries = readUInt16BE(ptr, start + 4)
        let transfer = readUInt16BE(ptr, start + 6)
        let matrix = readUInt16BE(ptr, start + 8)
        let fullRange: Bool? = (colorType == "nclx" && length >= 11) ? ((ptr[start + 10] & 0x80) != 0) : nil
        return ColorBoxInfo(
            colorType: colorType,
            colorPrimaries: primaries,
            transferCharacteristics: transfer,
            matrixCoefficients: matrix,
            fullRangeFlag: fullRange
        )
    }

    private static func parseMdcv(ptr: UnsafePointer<UInt8>, start: Int, length: Int) -> MasteringDisplayInfo? {
        guard length >= 24 else { return nil }
        let px0 = readUInt16BE(ptr, start + 0)
        let py0 = readUInt16BE(ptr, start + 2)
        let px1 = readUInt16BE(ptr, start + 4)
        let py1 = readUInt16BE(ptr, start + 6)
        let px2 = readUInt16BE(ptr, start + 8)
        let py2 = readUInt16BE(ptr, start + 10)
        let wx = readUInt16BE(ptr, start + 12)
        let wy = readUInt16BE(ptr, start + 14)
        let maxLum = readUInt32BE(ptr, start + 16)
        let minLum = readUInt32BE(ptr, start + 20)
        return MasteringDisplayInfo(
            displayPrimariesX: [px0, px1, px2],
            displayPrimariesY: [py0, py1, py2],
            whitePointX: wx,
            whitePointY: wy,
            maxDisplayMasteringLuminance: maxLum,
            minDisplayMasteringLuminance: minLum
        )
    }

    private static func parseClli(ptr: UnsafePointer<UInt8>, start: Int, length: Int) -> ContentLightLevelInfo? {
        guard length >= 4 else { return nil }
        let maxCLL = readUInt16BE(ptr, start + 0)
        let maxFALL = readUInt16BE(ptr, start + 2)
        return ContentLightLevelInfo(maxContentLightLevel: maxCLL, maxPicAverageLightLevel: maxFALL)
    }

    private static func parseTfhd(ptr: UnsafePointer<UInt8>, start: Int, length: Int, ctx: inout ISOBMFFParseContext) {
        guard length >= 8 else { return }
        let flags = (UInt32(ptr[start + 1]) << 16) | (UInt32(ptr[start + 2]) << 8) | UInt32(ptr[start + 3])
        ctx.currentTrafTrackID = readUInt32BE(ptr, start + 4)
        var off = start + 8
        let end = start + length
        if (flags & 0x000001) != 0 { off += 8 } // base_data_offset
        if (flags & 0x000002) != 0 { off += 4 } // sample_description_index
        if (flags & 0x000008) != 0 { off += 4 } // default_sample_duration
        if (flags & 0x000010) != 0 { off += 4 } // default_sample_size
        if (flags & 0x000020) != 0 && off + 4 <= end {
            ctx.currentTrafDefaultFlags = readUInt32BE(ptr, off)
        }
    }

    private static func parseTfdt(ptr: UnsafePointer<UInt8>, start: Int, length: Int, ctx: inout ISOBMFFParseContext) {
        guard length >= 8 else { return }
        let version = ptr[start]
        if version == 1 && length >= 12 {
            ctx.currentTrafBaseDecodeTime = readUInt64BE(ptr, start + 4)
        } else {
            ctx.currentTrafBaseDecodeTime = UInt64(readUInt32BE(ptr, start + 4))
        }
    }

    private static func parseTrun(ptr: UnsafePointer<UInt8>, start: Int, length: Int, ctx: inout ISOBMFFParseContext) {
        guard length >= 8 else { return }
        let flags = (UInt32(ptr[start + 1]) << 16) | (UInt32(ptr[start + 2]) << 8) | UInt32(ptr[start + 3])
        let sampleCount = readUInt32BE(ptr, start + 4)
        var off = start + 8
        let end = start + length

        if (flags & 0x000001) != 0 { off += 4 } // data_offset

        var firstSampleFlags: UInt32?
        if (flags & 0x000004) != 0 && off + 4 <= end {
            firstSampleFlags = readUInt32BE(ptr, off)
            off += 4
        }

        if firstSampleFlags == nil && sampleCount > 0 && (flags & 0x000400) != 0 {
            var sample0Off = off
            if (flags & 0x000100) != 0 { sample0Off += 4 } // sample_duration
            if (flags & 0x000200) != 0 { sample0Off += 4 } // sample_size
            if sample0Off + 4 <= end {
                firstSampleFlags = readUInt32BE(ptr, sample0Off)
            }
        }

        let effectiveFlags = firstSampleFlags ?? ctx.currentTrafDefaultFlags
        // ISO/IEC 14496-12 §8.8.3.1: bit 16 (0x0001_0000) is sample_is_non_sync_sample.
        let firstIsSync: Bool
        if let f = effectiveFlags {
            firstIsSync = (f & 0x0001_0000) == 0
        } else {
            firstIsSync = true
        }

        ctx.fragments.append(
            FragmentRunInfo(
                sequenceNumber: ctx.currentMoofSequence,
                trackID: ctx.currentTrafTrackID,
                baseMediaDecodeTime: ctx.currentTrafBaseDecodeTime,
                sampleCount: sampleCount,
                firstSampleIsSync: firstIsSync
            )
        )
    }

    // MARK: - 2. Pure-Swift 188-byte MPEG-TS Conformance Inspector

    public static func inspectMPEGTS(url: URL) throws -> MPEGTSInspectionResult {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return inspectMPEGTS(data: data)
    }

    public static func inspectMPEGTS(data: Data) -> MPEGTSInspectionResult {
        let totalBytes = data.count
        let packetSize = 188
        let isAligned = totalBytes >= packetSize && (totalBytes % packetSize) == 0
        let packetCount = totalBytes / packetSize

        var violations: [String] = []
        if totalBytes == 0 {
            violations.append("MPEG-TS data is empty")
        } else if !isAligned {
            violations.append("MPEG-TS byte size \(totalBytes) is not a non-zero multiple of 188 bytes")
        }

        var syncErrors = 0
        var hasPAT = false
        var pmtPID: UInt16?
        var hasPMT = false
        var pcrPID: UInt16?
        var esByPID: [UInt16: MPEGTSElementaryStream] = [:]
        var pcrCount = 0
        var pesPacketCount = 0
        var ptsCount = 0
        var dtsCount = 0
        var firstPTS: Double?
        var lastPTS: Double?
        var continuityErrors = 0
        var lastCCByPID: [UInt16: UInt8] = [:]

        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }

            for pktIdx in 0..<packetCount {
                let off = pktIdx * packetSize
                let pkt = base.advanced(by: off)

                if pkt[0] != 0x47 {
                    syncErrors += 1
                    continue
                }

                let pusi = (pkt[1] & 0x40) != 0
                let pid = (UInt16(pkt[1] & 0x1F) << 8) | UInt16(pkt[2])
                let afc = (pkt[3] >> 4) & 0x03
                let cc = pkt[3] & 0x0F
                let hasAdaptation = (afc == 2 || afc == 3)
                let hasPayload = (afc == 1 || afc == 3)

                var payloadStart = 4
                var discontinuityFlag = false

                if hasAdaptation {
                    let afLen = Int(pkt[4])
                    if 5 + afLen > packetSize {
                        violations.append("TS packet \(pktIdx) has out-of-bounds adaptation_field_length \(afLen)")
                        continue
                    }
                    if afLen >= 1 {
                        let afFlags = pkt[5]
                        discontinuityFlag = (afFlags & 0x80) != 0
                        let hasPCR = (afFlags & 0x10) != 0
                        if hasPCR && afLen >= 7 {
                            pcrCount += 1
                        }
                    }
                    payloadStart = 5 + afLen
                }

                // Continuity counter check for non-null PIDs carrying payload
                if pid != 0x1FFF && hasPayload {
                    if let prev = lastCCByPID[pid], !discontinuityFlag {
                        let expected = (prev &+ 1) & 0x0F
                        if cc != expected {
                            continuityErrors += 1
                        }
                    }
                    lastCCByPID[pid] = cc
                }

                guard hasPayload && payloadStart < packetSize else { continue }
                let payloadLen = packetSize - payloadStart

                // PAT (PID 0x0000)
                if pid == 0x0000 && pusi {
                    let pointer = Int(pkt[payloadStart])
                    let secStart = payloadStart + 1 + pointer
                    if secStart + 12 <= packetSize && pkt[secStart] == 0x00 {
                        let sectionLength = (Int(pkt[secStart + 1] & 0x0F) << 8) | Int(pkt[secStart + 2])
                        let secEnd = min(packetSize, secStart + 3 + sectionLength)
                        if secEnd >= secStart + 12 {
                            hasPAT = true
                            let loopEnd = max(secStart + 8, secEnd - 4)
                            var pOff = secStart + 8
                            while pOff + 4 <= loopEnd {
                                let programNumber = readUInt16BE(pkt, pOff)
                                let progPID = (UInt16(pkt[pOff + 2] & 0x1F) << 8) | UInt16(pkt[pOff + 3])
                                if programNumber != 0 && pmtPID == nil {
                                    pmtPID = progPID
                                }
                                pOff += 4
                            }
                        }
                    }
                    continue
                }

                // PMT
                if let expectedPMT = pmtPID, pid == expectedPMT && pusi {
                    let pointer = Int(pkt[payloadStart])
                    let secStart = payloadStart + 1 + pointer
                    if secStart + 12 <= packetSize && pkt[secStart] == 0x02 {
                        let sectionLength = (Int(pkt[secStart + 1] & 0x0F) << 8) | Int(pkt[secStart + 2])
                        let secEnd = min(packetSize, secStart + 3 + sectionLength)
                        if secEnd >= secStart + 16 {
                            hasPMT = true
                            pcrPID = (UInt16(pkt[secStart + 8] & 0x1F) << 8) | UInt16(pkt[secStart + 9])
                            let progInfoLen = (Int(pkt[secStart + 10] & 0x0F) << 8) | Int(pkt[secStart + 11])
                            let loopEnd = max(secStart + 12 + progInfoLen, secEnd - 4)
                            var esOff = secStart + 12 + progInfoLen
                            while esOff + 5 <= loopEnd {
                                let st = pkt[esOff]
                                let esPID = (UInt16(pkt[esOff + 1] & 0x1F) << 8) | UInt16(pkt[esOff + 2])
                                let esInfoLen = (Int(pkt[esOff + 3] & 0x0F) << 8) | Int(pkt[esOff + 4])
                                esByPID[esPID] = MPEGTSElementaryStream(
                                    pid: esPID,
                                    streamType: st,
                                    codecName: tsStreamTypeName(st)
                                )
                                esOff += 5 + esInfoLen
                            }
                        }
                    }
                    continue
                }

                // PES start code + PTS / DTS on elementary stream packets with PUSI=1
                if pusi && payloadLen >= 9 {
                    if pkt[payloadStart] == 0x00 && pkt[payloadStart + 1] == 0x00 && pkt[payloadStart + 2] == 0x01 {
                        let streamID = pkt[payloadStart + 3]
                        let isMediaStream = (streamID >= 0xC0 && streamID <= 0xEF)
                        if isMediaStream {
                            pesPacketCount += 1
                            let ptsDtsFlags = (pkt[payloadStart + 7] >> 6) & 0x03
                            if (ptsDtsFlags == 0x02 || ptsDtsFlags == 0x03) && payloadLen >= 14 {
                                let pts90k = decodeMPEGTimestamp33(pkt, payloadStart + 9)
                                let ptsSec = Double(pts90k) / 90_000.0
                                ptsCount += 1
                                if firstPTS == nil || ptsSec < (firstPTS ?? ptsSec) {
                                    firstPTS = ptsSec
                                }
                                if lastPTS == nil || ptsSec > (lastPTS ?? ptsSec) {
                                    lastPTS = ptsSec
                                }
                            }
                            if ptsDtsFlags == 0x03 && payloadLen >= 19 {
                                _ = decodeMPEGTimestamp33(pkt, payloadStart + 14)
                                dtsCount += 1
                            }
                        }
                    }
                }
            }
        }

        let streams = esByPID.values.sorted { $0.pid < $1.pid }
        let hasVideo = streams.contains { $0.streamType == 0x1B || $0.streamType == 0x24 || $0.streamType == 0x02 }
        let hasAudio = streams.contains { $0.streamType == 0x0F || $0.streamType == 0x11 || $0.streamType == 0x03 || $0.streamType == 0x04 || $0.streamType == 0x81 }

        if syncErrors > 0 {
            violations.append("Detected \(syncErrors) MPEG-TS packet(s) missing 0x47 sync byte")
        }
        if !hasPAT {
            violations.append("Missing PAT (PID 0x0000)")
        }
        if !hasPMT {
            violations.append("Missing PMT")
        }
        if streams.isEmpty {
            violations.append("PMT declares no elementary streams")
        }
        if continuityErrors > 0 {
            violations.append("Detected \(continuityErrors) MPEG-TS continuity counter error(s)")
        }
        if pesPacketCount == 0 {
            violations.append("No PES packets found")
        }
        if ptsCount == 0 {
            violations.append("No PTS timestamps found in PES headers")
        }
        if hasVideo && pcrCount == 0 {
            violations.append("No PCR timestamps found for video transport stream")
        }

        return MPEGTSInspectionResult(
            totalBytes: totalBytes,
            packetCount: packetCount,
            isPacketAligned: isAligned,
            syncErrors: syncErrors,
            hasPAT: hasPAT,
            pmtPID: pmtPID,
            hasPMT: hasPMT,
            pcrPID: pcrPID,
            elementaryStreams: streams,
            hasVideoStream: hasVideo,
            hasAudioStream: hasAudio,
            pcrCount: pcrCount,
            pesPacketCount: pesPacketCount,
            ptsCount: ptsCount,
            dtsCount: dtsCount,
            firstPTSSeconds: firstPTS,
            lastPTSSeconds: lastPTS,
            continuityErrors: continuityErrors,
            violations: violations,
            isValid: violations.isEmpty
        )
    }

    // MARK: - 3. Full Media File Bitstream + Independent AVAssetReader Verification

    public static func verifyMediaFile(
        url: URL,
        expectedCodec: String? = nil,
        expectedBitDepth: Int? = nil,
        expectedChroma: Int? = nil,
        expectedPrimaries: UInt16? = nil,
        requireIndependentDecode: Bool = true
    ) async throws -> BitstreamConformanceReport {
        try SafeFilePublisher.assertRegularReadableFile(url)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let fileSizeBytes = Int64(data.count)
        let ext = url.pathExtension.lowercased()

        let looksLikeTS = (ext == "ts" || ext == "m2ts") || (data.count >= 376 && data[0] == 0x47 && data[188] == 0x47)
        var violations: [String] = []
        var isobmffRes: ISOBMFFInspectionResult?
        var mpegtsRes: MPEGTSInspectionResult?
        let containerKind: String
        var detectedVideoCodec: String?
        var detectedAudioCodec: String?
        var detectedBitDepth: Int?
        var detectedChroma: Int?
        var detectedPrimaries: UInt16?

        if looksLikeTS {
            containerKind = "mpegts"
            let ts = inspectMPEGTS(data: data)
            mpegtsRes = ts
            violations.append(contentsOf: ts.violations)
            if let vStream = ts.elementaryStreams.first(where: { $0.streamType == 0x1B || $0.streamType == 0x24 }) {
                detectedVideoCodec = (vStream.streamType == 0x1B) ? "avc1" : "hvc1"
            }
            if let aStream = ts.elementaryStreams.first(where: { $0.streamType == 0x0F || $0.streamType == 0x11 }) {
                detectedAudioCodec = (aStream.streamType == 0x0F || aStream.streamType == 0x11) ? "mp4a" : aStream.codecName
            }
        } else {
            containerKind = "isobmff"
            let iso = inspectISOBMFF(data: data)
            isobmffRes = iso
            violations.append(contentsOf: iso.violations)
            detectedVideoCodec = iso.videoCodecFourCC
            detectedAudioCodec = iso.audioCodecFourCC
            detectedPrimaries = iso.colorInfo?.colorPrimaries

            if let hevc = iso.hevcConfig {
                detectedBitDepth = hevc.bitDepthLuma
                detectedChroma = Int(hevc.chromaFormatIdc)
            } else if let avc = iso.avcConfig {
                detectedBitDepth = (avc.avcProfileIndication == 110) ? 10 : 8
                detectedChroma = (avc.avcProfileIndication == 122) ? 2 : (avc.avcProfileIndication == 244 ? 3 : 1)
            } else if let fourCC = iso.videoCodecFourCC {
                switch fourCC {
                case "apch", "apcn", "apcs", "apco":
                    detectedBitDepth = 10
                    detectedChroma = 2
                case "ap4h", "ap4x":
                    detectedBitDepth = 12
                    detectedChroma = 3
                default:
                    break
                }
            }
        }

        // Check caller expectations
        if let expectedCodec {
            if !codecMatches(detected: detectedVideoCodec, expected: expectedCodec) {
                violations.append("Expected video codec '\(expectedCodec)', detected '\(detectedVideoCodec ?? "nil")'")
            }
        }
        if let expectedBitDepth {
            if detectedBitDepth != expectedBitDepth {
                violations.append("Expected bit depth \(expectedBitDepth), detected \(detectedBitDepth.map(String.init) ?? "nil")")
            }
        }
        if let expectedChroma {
            if detectedChroma != expectedChroma {
                violations.append("Expected chroma format \(expectedChroma), detected \(detectedChroma.map(String.init) ?? "nil")")
            }
        }
        if let expectedPrimaries {
            if detectedPrimaries != expectedPrimaries {
                violations.append("Expected color primaries \(expectedPrimaries), detected \(detectedPrimaries.map(String.init) ?? "nil")")
            }
        }

        // Independent AVAssetReader full-frame decode check
        var decodeRes: IndependentDecodeResult?
        if requireIndependentDecode && containerKind == "isobmff" {
            let dec = try await runIndependentDecode(url: url)
            decodeRes = dec
            if dec.decodedVideoFrames <= 0 {
                violations.append("Independent AVAssetReader decoded 0 video frames")
            }
            if !dec.monotonicPTS {
                violations.append("Decoded video presentation timestamps are not monotonic")
            }
            if !dec.nonZeroPixelVariance {
                violations.append("Decoded video frames have zero pixel variance (blank/solid output)")
            }
            if dec.hasAudioTrack && dec.decodedAudioBuffers <= 0 {
                violations.append("File declares an audio track, but AVAssetReader decoded 0 audio buffers")
            }
        }

        return BitstreamConformanceReport(
            filePath: url.path,
            fileSizeBytes: fileSizeBytes,
            containerKind: containerKind,
            isobmff: isobmffRes,
            mpegts: mpegtsRes,
            detectedVideoCodec: detectedVideoCodec,
            detectedAudioCodec: detectedAudioCodec,
            detectedBitDepth: detectedBitDepth,
            detectedChromaFormat: detectedChroma,
            detectedPrimaries: detectedPrimaries,
            independentDecode: decodeRes,
            violations: violations,
            passed: violations.isEmpty
        )
    }

    private static func runIndependentDecode(url: URL) async throws -> IndependentDecodeResult {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
        ])
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw SafariumError.invalidState("No video track found in \(url.lastPathComponent)")
        }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let durCM = try await asset.load(.duration)
        let durationSec = (durCM.isNumeric && durCM.seconds.isFinite) ? durCM.seconds : 0.0

        let reader = try AVAssetReader(asset: asset)
        let vOut = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        vOut.alwaysCopiesSampleData = false
        guard reader.canAdd(vOut) else {
            throw SafariumError.encode("AVAssetReader cannot add video track output for \(url.lastPathComponent)")
        }
        reader.add(vOut)

        var aOut: AVAssetReaderTrackOutput?
        if let audioTrack = audioTracks.first {
            let pcmSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcmSettings)
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) {
                reader.add(out)
                aOut = out
            }
        }

        guard reader.startReading() else {
            throw SafariumError.encode("Independent AVAssetReader failed to start: \(reader.error?.localizedDescription ?? "?")")
        }

        var decodedFrames = 0
        var monotonicPTS = true
        var lastPTS: CMTime?
        var maxVariance = 0.0
        var decodedWidth = Int(abs(naturalSize.width).rounded())
        var decodedHeight = Int(abs(naturalSize.height).rounded())

        while let sb = autoreleasepool(invoking: { vOut.copyNextSampleBuffer() }) {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            if let prev = lastPTS, pts.isValid && prev.isValid {
                if CMTimeCompare(pts, prev) < 0 {
                    monotonicPTS = false
                }
            }
            if pts.isValid { lastPTS = pts }

            if let pb = CMSampleBufferGetImageBuffer(sb) {
                if decodedFrames == 0 {
                    decodedWidth = CVPixelBufferGetWidth(pb)
                    decodedHeight = CVPixelBufferGetHeight(pb)
                }
                // Sample variance across early and periodic frames
                if decodedFrames < 8 || (decodedFrames % 15 == 0) {
                    let v = computeBGRAPixelVariance(pb)
                    if v > maxVariance { maxVariance = v }
                }
            }
            decodedFrames += 1
        }

        var decodedAudioBuffers = 0
        if let aOut {
            while autoreleasepool(invoking: { aOut.copyNextSampleBuffer() }) != nil {
                decodedAudioBuffers += 1
            }
        }
        reader.cancelReading()

        return IndependentDecodeResult(
            decodedVideoFrames: decodedFrames,
            monotonicPTS: monotonicPTS,
            nonZeroPixelVariance: maxVariance > 1.0,
            pixelVariance: (maxVariance * 100.0).rounded() / 100.0,
            hasAudioTrack: !audioTracks.isEmpty,
            decodedAudioBuffers: decodedAudioBuffers,
            durationSeconds: (durationSec * 1000.0).rounded() / 1000.0,
            width: decodedWidth,
            height: decodedHeight
        )
    }

    private static func computeBGRAPixelVariance(_ pb: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else {
            return 0.0
        }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        guard w > 0, h > 0 else { return 0.0 }

        let stepX = max(1, w / 32)
        let stepY = max(1, h / 32)
        var sum = 0.0
        var sumSq = 0.0
        var count = 0

        var y = 0
        while y < h {
            let row = base.advanced(by: y * bpr)
            var x = 0
            while x < w {
                let off = x * 4
                let luma = 0.114 * Double(row[off]) + 0.587 * Double(row[off + 1]) + 0.299 * Double(row[off + 2])
                sum += luma
                sumSq += luma * luma
                count += 1
                x += stepX
            }
            y += stepY
        }
        guard count > 1 else { return 0.0 }
        let mean = sum / Double(count)
        return max(0.0, (sumSq / Double(count)) - (mean * mean))
    }

    // MARK: - Private Binary Helpers

    private static func codecMatches(detected: String?, expected: String) -> Bool {
        guard let detected else { return false }
        let d = detected.lowercased()
        let e = expected.lowercased()
        if d == e { return true }
        switch e {
        case "h264", "avc":
            return d == "avc1" || d == "avc3"
        case "hevc", "h265", "hevc10":
            return d == "hvc1" || d == "hev1" || d == "dvh1" || d == "dvhe"
        case "prores422hq", "prores-hq":
            return d == "apch"
        case "prores422":
            return d == "apcn"
        case "prores4444":
            return d == "ap4h"
        case "prores4444xq":
            return d == "ap4x"
        default:
            return false
        }
    }

    private static func tsStreamTypeName(_ st: UInt8) -> String {
        switch st {
        case 0x02: return "MPEG-2 Video"
        case 0x03, 0x04: return "MPEG-Audio"
        case 0x0F: return "AAC-ADTS"
        case 0x11: return "AAC-LATM"
        case 0x1B: return "H.264"
        case 0x24: return "HEVC"
        case 0x81: return "AC-3"
        default: return String(format: "0x%02X", st)
        }
    }

    private static func decodeMPEGTimestamp33(_ ptr: UnsafePointer<UInt8>, _ offset: Int) -> UInt64 {
        let b0 = UInt64(ptr[offset + 0] & 0x0E) << 29
        let b1 = UInt64(ptr[offset + 1]) << 22
        let b2 = UInt64(ptr[offset + 2] & 0xFE) << 14
        let b3 = UInt64(ptr[offset + 3]) << 7
        let b4 = UInt64(ptr[offset + 4]) >> 1
        return b0 | b1 | b2 | b3 | b4
    }

    private static func readUInt16BE(_ ptr: UnsafePointer<UInt8>, _ offset: Int) -> UInt16 {
        (UInt16(ptr[offset]) << 8) | UInt16(ptr[offset + 1])
    }

    private static func readUInt32BE(_ ptr: UnsafePointer<UInt8>, _ offset: Int) -> UInt32 {
        let b0 = UInt32(ptr[offset + 0]) << 24
        let b1 = UInt32(ptr[offset + 1]) << 16
        let b2 = UInt32(ptr[offset + 2]) << 8
        let b3 = UInt32(ptr[offset + 3])
        return b0 | b1 | b2 | b3
    }

    private static func readUInt64BE(_ ptr: UnsafePointer<UInt8>, _ offset: Int) -> UInt64 {
        let hi = UInt64(readUInt32BE(ptr, offset)) << 32
        let lo = UInt64(readUInt32BE(ptr, offset + 4))
        return hi | lo
    }

    private static func readFourCC(_ ptr: UnsafePointer<UInt8>, _ offset: Int) -> String {
        let bytes = [ptr[offset], ptr[offset + 1], ptr[offset + 2], ptr[offset + 3]]
        return String(bytes: bytes, encoding: .isoLatin1) ?? "????"
    }
}
