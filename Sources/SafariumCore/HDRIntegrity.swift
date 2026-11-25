import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// MARK: - Wave 12B: HDR Metadata Policy & Signal Integrity

/// Controls how dynamic and static HDR metadata are handled during transcode or pixel processing.
public enum HDRMetadataPolicy: String, Codable, Sendable, CaseIterable {
    /// Preserve source HDR metadata as-is (only valid when pixels are not modified or no stale dynamic metadata exists).
    case preserve = "preserve"
    /// Recompute per-frame dynamic HDR metadata (e.g., Dolby Vision RPU via `VTHDRPerFrameMetadataGenerationSession`).
    case recompute = "recompute"
    /// Tone-map HDR input to SDR BT.709 and strip HDR dynamic metadata.
    case toneMapToSDR = "tone-map-to-sdr"
    /// Strip dynamic HDR metadata (e.g., Dolby Vision RPU) while keeping static mastering metadata if appropriate.
    case stripDynamicMetadata = "strip-dynamic-metadata"
}

/// Concrete policy decision resolved by `HDRIntegrity.resolvePolicy(...)`.
public struct ResolvedHDRPolicy: Codable, Sendable, Equatable {
    public let requestedPolicy: HDRMetadataPolicy
    public let effectivePolicy: HDRMetadataPolicy
    public let preserveDynamicMetadata: Bool
    public let recomputeDynamicMetadata: Bool
    public let stripDynamicMetadata: Bool
    public let toneMapToSDR: Bool
    public let forcedOverride: Bool
    public let warnings: [String]

    public init(
        requestedPolicy: HDRMetadataPolicy,
        effectivePolicy: HDRMetadataPolicy,
        preserveDynamicMetadata: Bool,
        recomputeDynamicMetadata: Bool,
        stripDynamicMetadata: Bool,
        toneMapToSDR: Bool,
        forcedOverride: Bool,
        warnings: [String]
    ) {
        self.requestedPolicy = requestedPolicy
        self.effectivePolicy = effectivePolicy
        self.preserveDynamicMetadata = preserveDynamicMetadata
        self.recomputeDynamicMetadata = recomputeDynamicMetadata
        self.stripDynamicMetadata = stripDynamicMetadata
        self.toneMapToSDR = toneMapToSDR
        self.forcedOverride = forcedOverride
        self.warnings = warnings
    }
}

/// Comprehensive audit of an HDR video signal (pixel buffer, format description, or container track).
public struct HDRSignalAudit: Codable, Sendable, Equatable {
    public let is10Bit: Bool
    public let primaries: String?
    public let transfer: String?
    public let matrix: String?
    public let hasMasteringDisplay: Bool
    public let hasContentLightLevel: Bool
    public let hasAmbientViewing: Bool
    public let hasDolbyVisionConfig: Bool
    public let sampleEntryFourCC: String?
    public let issues: [String]
    public let passed: Bool

    public init(
        is10Bit: Bool,
        primaries: String?,
        transfer: String?,
        matrix: String?,
        hasMasteringDisplay: Bool,
        hasContentLightLevel: Bool,
        hasAmbientViewing: Bool,
        hasDolbyVisionConfig: Bool,
        sampleEntryFourCC: String?,
        issues: [String],
        passed: Bool
    ) {
        self.is10Bit = is10Bit
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.hasMasteringDisplay = hasMasteringDisplay
        self.hasContentLightLevel = hasContentLightLevel
        self.hasAmbientViewing = hasAmbientViewing
        self.hasDolbyVisionConfig = hasDolbyVisionConfig
        self.sampleEntryFourCC = sampleEntryFourCC
        self.issues = issues
        self.passed = passed
    }
}

/// Native Apple Silicon HDR signal integrity, metadata policy enforcement, and synthetic P010 test harness.
public enum HDRIntegrity {
    /// Returns `true` when macOS 15+ `VTHDRPerFrameMetadataGenerationSession` dynamic HDR recompute is available.
    public static var isDynamicMetadataRecomputeAvailable: Bool {
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) {
            return true
        }
        #endif
        return false
    }

    /// Resolves the effective HDR metadata handling policy.
    ///
    /// Enforces the strict safety invariant: when `pixelsModified == true` and `sourceHasDynamicMetadata == true`,
    /// stale Dolby Vision / dynamic HDR metadata MUST NOT be inherited blindly. The policy is forced to
    /// `.recompute` (when live metadata recomputation is available) or `.stripDynamicMetadata` (fallback),
    /// with an explicit warning logged in `warnings`.
    public static func resolvePolicy(
        sourceIsHDR: Bool,
        sourceHasDynamicMetadata: Bool,
        pixelsModified: Bool,
        requestedPolicy: HDRMetadataPolicy,
        dynamicRecomputeAvailable: Bool = HDRIntegrity.isDynamicMetadataRecomputeAvailable
    ) -> ResolvedHDRPolicy {
        if !sourceIsHDR {
            var warnings: [String] = []
            if requestedPolicy == .toneMapToSDR {
                warnings.append("Source is already SDR; toneMapToSDR is a no-op.")
            } else if requestedPolicy == .recompute {
                warnings.append("Source is SDR; ignoring HDR dynamic metadata recompute request.")
            }
            let effective: HDRMetadataPolicy = (requestedPolicy == .toneMapToSDR) ? .toneMapToSDR : .preserve
            return ResolvedHDRPolicy(
                requestedPolicy: requestedPolicy,
                effectivePolicy: effective,
                preserveDynamicMetadata: false,
                recomputeDynamicMetadata: false,
                stripDynamicMetadata: false,
                toneMapToSDR: false,
                forcedOverride: effective != requestedPolicy,
                warnings: warnings
            )
        }

        // Strict invariant: NEVER blindly preserve stale dynamic HDR metadata when pixels were modified.
        if pixelsModified && sourceHasDynamicMetadata && requestedPolicy == .preserve {
            if dynamicRecomputeAvailable {
                return ResolvedHDRPolicy(
                    requestedPolicy: requestedPolicy,
                    effectivePolicy: .recompute,
                    preserveDynamicMetadata: false,
                    recomputeDynamicMetadata: true,
                    stripDynamicMetadata: false,
                    toneMapToSDR: false,
                    forcedOverride: true,
                    warnings: [
                        "Pixels were modified on an HDR source containing dynamic metadata (e.g., Dolby Vision RPU). Refusing to blindly preserve stale dynamic metadata; forcing .recompute.",
                    ]
                )
            } else {
                return ResolvedHDRPolicy(
                    requestedPolicy: requestedPolicy,
                    effectivePolicy: .stripDynamicMetadata,
                    preserveDynamicMetadata: false,
                    recomputeDynamicMetadata: false,
                    stripDynamicMetadata: true,
                    toneMapToSDR: false,
                    forcedOverride: true,
                    warnings: [
                        "Pixels were modified on an HDR source containing dynamic metadata and live recompute is unavailable. Refusing to blindly preserve stale dynamic metadata; forcing .stripDynamicMetadata.",
                    ]
                )
            }
        }

        switch requestedPolicy {
        case .preserve:
            return ResolvedHDRPolicy(
                requestedPolicy: .preserve,
                effectivePolicy: .preserve,
                preserveDynamicMetadata: sourceHasDynamicMetadata,
                recomputeDynamicMetadata: false,
                stripDynamicMetadata: false,
                toneMapToSDR: false,
                forcedOverride: false,
                warnings: []
            )

        case .recompute:
            if dynamicRecomputeAvailable {
                return ResolvedHDRPolicy(
                    requestedPolicy: .recompute,
                    effectivePolicy: .recompute,
                    preserveDynamicMetadata: false,
                    recomputeDynamicMetadata: true,
                    stripDynamicMetadata: false,
                    toneMapToSDR: false,
                    forcedOverride: false,
                    warnings: []
                )
            } else {
                return ResolvedHDRPolicy(
                    requestedPolicy: .recompute,
                    effectivePolicy: .stripDynamicMetadata,
                    preserveDynamicMetadata: false,
                    recomputeDynamicMetadata: false,
                    stripDynamicMetadata: true,
                    toneMapToSDR: false,
                    forcedOverride: true,
                    warnings: [
                        "Dynamic HDR metadata recompute requested, but VTHDRPerFrameMetadataGenerationSession is unavailable on this OS; falling back to .stripDynamicMetadata.",
                    ]
                )
            }

        case .toneMapToSDR:
            return ResolvedHDRPolicy(
                requestedPolicy: .toneMapToSDR,
                effectivePolicy: .toneMapToSDR,
                preserveDynamicMetadata: false,
                recomputeDynamicMetadata: false,
                stripDynamicMetadata: true,
                toneMapToSDR: true,
                forcedOverride: false,
                warnings: []
            )

        case .stripDynamicMetadata:
            return ResolvedHDRPolicy(
                requestedPolicy: .stripDynamicMetadata,
                effectivePolicy: .stripDynamicMetadata,
                preserveDynamicMetadata: false,
                recomputeDynamicMetadata: false,
                stripDynamicMetadata: true,
                toneMapToSDR: false,
                forcedOverride: false,
                warnings: []
            )
        }
    }

    /// Applies the resolved HDR dynamic metadata preservation policy to a VideoToolbox compression session.
    public static func applySessionMetadataPolicy(
        _ session: VTCompressionSession,
        policy: ResolvedHDRPolicy
    ) {
        let preserveValue: CFBoolean = policy.preserveDynamicMetadata ? kCFBooleanTrue : kCFBooleanFalse
        _ = VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_PreserveDynamicHDRMetadata,
            value: preserveValue
        )
    }

    /// Generates a deterministic 10-bit `P010` (`kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`) color-chart buffer
    /// tagged with BT.2020 + PQ/HLG + `mdcv` (Mastering Display Color Volume) + `clli` (Content Light Level Info).
    public static func createSyntheticHDRTestBuffer(
        width: Int,
        height: Int,
        transfer: HDRMode
    ) throws -> CVPixelBuffer {
        let evenW = max(16, (width / 2) * 2)
        let evenH = max(16, (height / 2) * 2)

        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pbOpt: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            evenW,
            evenH,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            attrs as CFDictionary,
            &pbOpt
        )
        guard status == kCVReturnSuccess, let pb = pbOpt else {
            throw SafariumError.encode("CVPixelBufferCreate failed for synthetic 10-bit HDR P010 buffer (status \(status))")
        }

        // Fill deterministic 10-bit SMPTE-style color bars (top 65%) + luminance ramp (bottom 35%)
        // P010 stores 10-bit video-range samples in the most significant 10 bits of each UInt16 (val10 << 6).
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        // 8 bars in 10-bit YCbCr video range (Y: 64..940, Cb/Cr: 64..960)
        let barY: [UInt16]  = [880, 780, 660, 560, 440, 340, 220, 110]
        let barCb: [UInt16] = [512, 220, 680, 320, 720, 360, 820, 512]
        let barCr: [UInt16] = [512, 560, 260, 290, 760, 810, 450, 512]
        let splitY = (evenH * 65) / 100

        if let yPtr = CVPixelBufferGetBaseAddressOfPlane(pb, 0)?.assumingMemoryBound(to: UInt16.self) {
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0) / MemoryLayout<UInt16>.size
            for y in 0..<evenH {
                let row = yPtr.advanced(by: y * yStride)
                if y < splitY {
                    for x in 0..<evenW {
                        let bar = min(7, (x * 8) / evenW)
                        row[x] = barY[bar] << 6
                    }
                } else {
                    for x in 0..<evenW {
                        let ramp10 = UInt16(64 + ((x * 876) / max(1, evenW - 1)))
                        row[x] = ramp10 << 6
                    }
                }
            }
        }

        if let uvPtr = CVPixelBufferGetBaseAddressOfPlane(pb, 1)?.assumingMemoryBound(to: UInt16.self) {
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1) / MemoryLayout<UInt16>.size
            let uvW = CVPixelBufferGetWidthOfPlane(pb, 1)
            let uvH = CVPixelBufferGetHeightOfPlane(pb, 1)
            let uvSplitY = splitY / 2
            for y in 0..<uvH {
                let row = uvPtr.advanced(by: y * uvStride)
                if y < uvSplitY {
                    for x in 0..<uvW {
                        let bar = min(7, (x * 8) / max(1, uvW))
                        row[x * 2 + 0] = barCb[bar] << 6
                        row[x * 2 + 1] = barCr[bar] << 6
                    }
                } else {
                    for x in 0..<uvW {
                        row[x * 2 + 0] = UInt16(512) << 6
                        row[x * 2 + 1] = UInt16(512) << 6
                    }
                }
            }
        }

        // Tag colorimetry attachments
        transfer.tagPixelBuffer(pb)

        // Attach standard 1000-nit Display P3-in-BT.2020 SMPTE ST 2086 Mastering Display Color Volume (`mdcv`, 24 bytes BE)
        // Order per ISO/IEC 14496-12 & SMPTE ST 2086: G(x,y), B(x,y), R(x,y), WP(x,y), maxLum (0.0001 cd/m2), minLum (0.0001 cd/m2)
        if transfer.isHDR {
            let mdcvData = makeMasteringDisplayData(
                greenX: 13250, greenY: 34500,
                blueX: 7500, blueY: 3000,
                redX: 34000, redY: 16000,
                whiteX: 15635, whiteY: 16450,
                maxLuminance: 10_000_000, // 1000.0 nits
                minLuminance: 50          // 0.0050 nits
            )
            CVBufferSetAttachment(
                pb,
                kCVImageBufferMasteringDisplayColorVolumeKey,
                mdcvData as CFData,
                .shouldPropagate
            )

            // Attach Content Light Level Info (`clli`, 4 bytes BE): MaxCLL = 1000 nits, MaxFALL = 400 nits
            let clliData = makeContentLightLevelData(maxCLL: 1000, maxFALL: 400)
            CVBufferSetAttachment(
                pb,
                kCVImageBufferContentLightLevelInfoKey,
                clliData as CFData,
                .shouldPropagate
            )
        }

        return pb
    }

    /// Inspects a `CMSampleBuffer` (format description, image buffer attachments, and timing) for native
    /// `AVSampleBufferDisplayLayer` presentation readiness. Returns an empty array when fully valid.
    public static func validateDisplayAttachment(sampleBuffer: CMSampleBuffer) -> [String] {
        var issues: [String] = []

        guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return ["CMSampleBuffer is missing a CMFormatDescription"]
        }

        let mediaType = CMFormatDescriptionGetMediaType(fmt)
        if mediaType != kCMMediaType_Video {
            issues.append("CMFormatDescription mediaType is not video")
            return issues
        }

        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        if dims.width <= 0 || dims.height <= 0 {
            issues.append("Invalid video dimensions (\(dims.width)x\(dims.height))")
        }

        // Check timing or DisplayImmediately attachment required by AVSampleBufferDisplayLayer
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hasValidPTS = pts.isValid && pts.isNumeric
        var displayImmediately = false
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
           let first = arr.first,
           let flag = first[kCMSampleAttachmentKey_DisplayImmediately] as? Bool {
            displayImmediately = flag
        }
        if !hasValidPTS && !displayImmediately {
            issues.append("CMSampleBuffer has invalid PTS and kCMSampleAttachmentKey_DisplayImmediately is not set")
        }

        let pb = CMSampleBufferGetImageBuffer(sampleBuffer)
        let extensions = CMFormatDescriptionGetExtensions(fmt) as? [CFString: Any] ?? [:]

        func lookupAttachment(_ key: CFString) -> Any? {
            if let v = extensions[key] { return v }
            if let pb, let v = CVBufferCopyAttachment(pb, key, nil) { return v }
            return nil
        }

        let primariesObj = lookupAttachment(kCVImageBufferColorPrimariesKey)
        let transferObj = lookupAttachment(kCVImageBufferTransferFunctionKey)
        let matrixObj = lookupAttachment(kCVImageBufferYCbCrMatrixKey)

        if primariesObj == nil {
            issues.append("Missing ColorPrimaries attachment on sample buffer / format description")
        }
        if transferObj == nil {
            issues.append("Missing TransferFunction attachment on sample buffer / format description")
        }
        if matrixObj == nil {
            issues.append("Missing YCbCrMatrix attachment on sample buffer / format description")
        }

        let primariesStr = primariesObj.map { String(describing: $0) } ?? ""
        let transferStr = transferObj.map { String(describing: $0) } ?? ""
        let isPQ = transferStr.contains("2084") || transferStr.contains("PQ")
        let isHLG = transferStr.contains("HLG") || transferStr.contains("2100")
        let isHDR = isPQ || isHLG

        if isHDR {
            // Wide gamut primaries check
            let wideGamut = primariesStr.contains("2020") || primariesStr.contains("P3")
            if !wideGamut {
                issues.append("HDR transfer (\(transferStr)) requires wide-gamut primaries (BT.2020 or P3), found '\(primariesStr)'")
            }

            // 10-bit+ pixel format check when uncompressed CVPixelBuffer is attached
            if let pb {
                let pf = CVPixelBufferGetPixelFormatType(pb)
                if !isHighBitDepthPixelFormat(pf) {
                    issues.append("HDR uncompressed CVPixelBuffer uses 8-bit pixel format (\(fourCCString(pf))); expected 10-bit+ format (e.g., P010)")
                }
            }

            // PQ (HDR10) static mastering metadata checks
            if isPQ {
                if let mdcv = lookupAttachment(kCVImageBufferMasteringDisplayColorVolumeKey) as? Data {
                    if mdcv.count != 24 {
                        issues.append("MasteringDisplayColorVolume (mdcv) must be 24 bytes, found \(mdcv.count)")
                    }
                } else {
                    issues.append("HDR10 PQ sample buffer is missing MasteringDisplayColorVolume (mdcv) attachment")
                }

                if let clli = lookupAttachment(kCVImageBufferContentLightLevelInfoKey) as? Data {
                    if clli.count != 4 {
                        issues.append("ContentLightLevelInfo (clli) must be 4 bytes, found \(clli.count)")
                    }
                } else {
                    issues.append("HDR10 PQ sample buffer is missing ContentLightLevelInfo (clli) attachment")
                }
            }
        }

        return issues
    }

    /// Audits an uncompressed `CVPixelBuffer` for HDR signal completeness.
    public static func auditPixelBuffer(
        _ pb: CVPixelBuffer,
        sampleEntryFourCC: String? = nil
    ) -> HDRSignalAudit {
        let pf = CVPixelBufferGetPixelFormatType(pb)
        let is10 = isHighBitDepthPixelFormat(pf)
        let primaries = CVBufferCopyAttachment(pb, kCVImageBufferColorPrimariesKey, nil).map { String(describing: $0) }
        let transfer = CVBufferCopyAttachment(pb, kCVImageBufferTransferFunctionKey, nil).map { String(describing: $0) }
        let matrix = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nil).map { String(describing: $0) }
        let hasMDCV = (CVBufferCopyAttachment(pb, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data)?.count == 24
        let hasCLLI = (CVBufferCopyAttachment(pb, kCVImageBufferContentLightLevelInfoKey, nil) as? Data)?.count == 4
        let hasAMVE = CVBufferCopyAttachment(pb, "AmbientViewingEnvironment" as CFString, nil) != nil
        let hasDV = CVBufferCopyAttachment(pb, "DolbyVisionRPUData" as CFString, nil) != nil

        var issues: [String] = []
        if primaries == nil { issues.append("Missing ColorPrimaries attachment") }
        if transfer == nil { issues.append("Missing TransferFunction attachment") }
        if matrix == nil { issues.append("Missing YCbCrMatrix attachment") }

        let tfStr = transfer ?? ""
        let isPQ = tfStr.contains("2084") || tfStr.contains("PQ")
        let isHLG = tfStr.contains("HLG") || tfStr.contains("2100")
        if isPQ || isHLG {
            if !is10 {
                issues.append("HDR buffer is not 10-bit+ (\(fourCCString(pf)))")
            }
            if let p = primaries, !p.contains("2020") && !p.contains("P3") {
                issues.append("HDR buffer uses narrow primaries (\(p))")
            }
            if isPQ && !hasMDCV {
                issues.append("PQ HDR10 buffer missing 24-byte mdcv")
            }
            if isPQ && !hasCLLI {
                issues.append("PQ HDR10 buffer missing 4-byte clli")
            }
        }

        return HDRSignalAudit(
            is10Bit: is10,
            primaries: primaries,
            transfer: transfer,
            matrix: matrix,
            hasMasteringDisplay: hasMDCV,
            hasContentLightLevel: hasCLLI,
            hasAmbientViewing: hasAMVE,
            hasDolbyVisionConfig: hasDV,
            sampleEntryFourCC: sampleEntryFourCC,
            issues: issues,
            passed: issues.isEmpty
        )
    }

    // MARK: - Private Binary Metadata Helpers

    private static func makeMasteringDisplayData(
        greenX: UInt16, greenY: UInt16,
        blueX: UInt16, blueY: UInt16,
        redX: UInt16, redY: UInt16,
        whiteX: UInt16, whiteY: UInt16,
        maxLuminance: UInt32,
        minLuminance: UInt32
    ) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(24)
        func appendU16(_ v: UInt16) {
            bytes.append(UInt8((v >> 8) & 0xFF))
            bytes.append(UInt8(v & 0xFF))
        }
        func appendU32(_ v: UInt32) {
            bytes.append(UInt8((v >> 24) & 0xFF))
            bytes.append(UInt8((v >> 16) & 0xFF))
            bytes.append(UInt8((v >> 8) & 0xFF))
            bytes.append(UInt8(v & 0xFF))
        }
        appendU16(greenX); appendU16(greenY)
        appendU16(blueX); appendU16(blueY)
        appendU16(redX); appendU16(redY)
        appendU16(whiteX); appendU16(whiteY)
        appendU32(maxLuminance)
        appendU32(minLuminance)
        return Data(bytes)
    }

    private static func makeContentLightLevelData(maxCLL: UInt16, maxFALL: UInt16) -> Data {
        Data([
            UInt8((maxCLL >> 8) & 0xFF),
            UInt8(maxCLL & 0xFF),
            UInt8((maxFALL >> 8) & 0xFF),
            UInt8(maxFALL & 0xFF),
        ])
    }

    private static func isHighBitDepthPixelFormat(_ pf: OSType) -> Bool {
        switch pf {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_64RGBAHalf,
             kCVPixelFormatType_422YpCbCr10,
             kCVPixelFormatType_444YpCbCr10,
             kCVPixelFormatType_422YpCbCr16:
            return true
        default:
            return false
        }
    }

    private static func fourCCString(_ code: OSType) -> String {
        let chars: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(bytes: chars, encoding: .ascii) ?? String(format: "0x%08X", code)
    }
}
