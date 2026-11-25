import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import VideoToolbox

// MARK: - Wave 14B: Apple ProRes Zero-4:2:0 Production Pipeline

/// Apple ProRes encoding tiers mapped directly to their canonical QuickTime FourCCs.
public enum ProResTier: String, CaseIterable, Codable, Sendable {
    case proxy
    case lt
    case standard
    case hq
    case fourFourFourFour
    case fourFourFourFourXQ

    /// Canonical 4-character QuickTime codec FourCC.
    public var fourCC: String {
        switch self {
        case .proxy: return "apco"
        case .lt: return "apcs"
        case .standard: return "apcn"
        case .hq: return "apch"
        case .fourFourFourFour: return "ap4h"
        case .fourFourFourFourXQ: return "ap4x"
        }
    }

    /// Corresponding `AVVideoCodecType` for `AVAssetWriter`.
    public var avVideoCodecType: AVVideoCodecType {
        switch self {
        case .proxy: return .proRes422Proxy
        case .lt: return .proRes422LT
        case .standard: return .proRes422
        case .hq: return .proRes422HQ
        case .fourFourFourFour: return .proRes4444
        case .fourFourFourFourXQ: return AVVideoCodecType(rawValue: "ap4x")
        }
    }

    /// Corresponding `CMVideoCodecType` for VideoToolbox / CoreMedia.
    public var cmCodecType: CMVideoCodecType {
        switch self {
        case .proxy: return kCMVideoCodecType_AppleProRes422Proxy
        case .lt: return kCMVideoCodecType_AppleProRes422LT
        case .standard: return kCMVideoCodecType_AppleProRes422
        case .hq: return kCMVideoCodecType_AppleProRes422HQ
        case .fourFourFourFour: return kCMVideoCodecType_AppleProRes4444
        case .fourFourFourFourXQ: return kCMVideoCodecType_AppleProRes4444XQ
        }
    }

    /// True for 4:4:4:4 tiers (`.fourFourFourFour`, `.fourFourFourFourXQ`).
    public var is4444: Bool {
        switch self {
        case .fourFourFourFour, .fourFourFourFourXQ:
            return true
        case .proxy, .lt, .standard, .hq:
            return false
        }
    }

    /// True if this ProRes tier natively encodes an alpha channel.
    public var supportsAlpha: Bool {
        is4444
    }
}

/// Configuration for encoding a sequence of frames via `ProResPipeline`.
public struct ProResEncodeOptions: Sendable, Equatable {
    public let tier: ProResTier
    public let width: Int
    public let height: Int
    public let fps: Double
    public let preserveAlpha: Bool
    public let colorMetadata: FrameColorMetadata

    public init(
        tier: ProResTier,
        width: Int,
        height: Int,
        fps: Double = 30.0,
        preserveAlpha: Bool = false,
        colorMetadata: FrameColorMetadata = .bt709SDR()
    ) {
        self.tier = tier
        self.width = width
        self.height = height
        self.fps = fps
        self.preserveAlpha = preserveAlpha
        self.colorMetadata = colorMetadata
    }
}

/// Telemetry and invariant verification result produced by `ProResPipeline.encodeFrames`.
public struct ProResEncodeResult: Codable, Sendable, Equatable {
    public let outputPath: String
    public let tier: String
    public let fourCC: String
    public let pixelFormatUsed: String
    public let zero420Downconversion: Bool
    public let preservesAlpha: Bool
    public let framesEncoded: Int
    public let bytesWritten: Int64
    public let elapsedMs: Double

    public init(
        outputPath: String,
        tier: String,
        fourCC: String,
        pixelFormatUsed: String,
        zero420Downconversion: Bool,
        preservesAlpha: Bool,
        framesEncoded: Int,
        bytesWritten: Int64,
        elapsedMs: Double
    ) {
        self.outputPath = outputPath
        self.tier = tier
        self.fourCC = fourCC
        self.pixelFormatUsed = pixelFormatUsed
        self.zero420Downconversion = zero420Downconversion
        self.preservesAlpha = preservesAlpha
        self.framesEncoded = framesEncoded
        self.bytesWritten = bytesWritten
        self.elapsedMs = elapsedMs
    }
}

/// Fail-closed validation and encoding errors thrown by `ProResPipeline`.
public enum ProResPipelineError: Error, CustomStringConvertible, Equatable, Sendable {
    case forbidden420Subsampling(pixelFormat: String, tier: String)
    case incompatiblePixelFormat(pixelFormat: String, tier: String, reason: String)
    case emptyFrameSequence
    case invalidDimensions(width: Int, height: Int)
    case invalidFrameRate(fps: Double)
    case writerInitializationFailed(String)
    case encodeFailed(String)

    public var description: String {
        switch self {
        case .forbidden420Subsampling(let pixelFormat, let tier):
            return "ProResPipeline forbids 4:2:0 subsampled pixel format '\(pixelFormat)' for tier '\(tier)' (zero-4:2:0 invariant)"
        case .incompatiblePixelFormat(let pixelFormat, let tier, let reason):
            return "Incompatible pixel format '\(pixelFormat)' for ProRes tier '\(tier)': \(reason)"
        case .emptyFrameSequence:
            return "ProResPipeline requires at least one CVPixelBuffer frame to encode"
        case .invalidDimensions(let width, let height):
            return "Invalid ProRes dimensions: \(width)x\(height)"
        case .invalidFrameRate(let fps):
            return "Invalid ProRes frame rate: \(fps)"
        case .writerInitializationFailed(let detail):
            return "AVAssetWriter initialization failed for ProRes output: \(detail)"
        case .encodeFailed(let detail):
            return "ProRes encode failed: \(detail)"
        }
    }
}

/// Zero-4:2:0 Apple ProRes encoding pipeline built exclusively on macOS VideoToolbox & AVFoundation.
///
/// Strict Invariant:
/// - NEVER accepts or converts through any 4:2:0 pixel format (`NV12`, `420v`, `420f`, `P010`, `x420`, `xf20`, `y420`, `f420`).
/// - ProRes 422 tiers (`.proxy`, `.lt`, `.standard`, `.hq`) accept IOSurface-backed 4:2:2 (`v210`, `2vuy`, `yuvs`, `x422`, `422v`, `v216`)
///   or 4:4:4 (`32BGRA`, `64RGBAHalf`, `64ARGB`, `32ARGB`) pixel buffers directly.
/// - ProRes 4444 / 4444 XQ tiers (`.fourFourFourFour`, `.fourFourFourFourXQ`) strictly require
///   alpha-preserving 4:4:4:4 (`32BGRA`, `64RGBAHalf`, `64ARGB`, `32ARGB`, `y416`) pixel buffers.
public enum ProResPipeline {

    /// One-time registration of Apple professional video workflow encoders and decoders.
    private static let professionalCodecsRegistered: Bool = {
        VTRegisterProfessionalVideoWorkflowVideoEncoders()
        VTRegisterProfessionalVideoWorkflowVideoDecoders()
        return true
    }()

    /// Explicit set of 4:2:0 pixel formats strictly forbidden in the ProRes path.
    private static let forbidden420Formats: Set<OSType> = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_420YpCbCr8Planar,
        kCVPixelFormatType_420YpCbCr8PlanarFullRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
    ]

    /// Valid 4:2:2 pixel formats for ProRes 422 tiers.
    private static let allowed422Formats: Set<OSType> = [
        kCVPixelFormatType_422YpCbCr10, // 'v210'
        kCVPixelFormatType_422YpCbCr8, // '2vuy'
        kCVPixelFormatType_422YpCbCr8_yuvs, // 'yuvs'
        kCVPixelFormatType_422YpCbCr16, // 'v216'
        kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
        kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_422YpCbCr16BiPlanarVideoRange,
    ]

    /// Valid 4:4:4:4 alpha-capable pixel formats for ProRes 4444 / 4444 XQ (and accepted by 422 tiers without 4:2:0).
    private static let allowed4444Formats: Set<OSType> = [
        kCVPixelFormatType_32BGRA,
        kCVPixelFormatType_64RGBAHalf,
        kCVPixelFormatType_64ARGB,
        kCVPixelFormatType_32ARGB,
        kCVPixelFormatType_4444AYpCbCr16,
    ]

    /// Ensures Apple professional ProRes encoders and decoders are registered with VideoToolbox.
    public static func ensureProfessionalVideoWorkflowRegistered() {
        _ = professionalCodecsRegistered
    }

    /// Returns true if `pixelFormat` is a 4:2:0 subsampled format (strictly forbidden for ProRes).
    public static func isForbidden420Format(_ pixelFormat: OSType) -> Bool {
        if forbidden420Formats.contains(pixelFormat) {
            return true
        }
        let fourCC = pixelFormatFourCC(pixelFormat).lowercased()
        return fourCC.contains("420") || fourCC == "nv12" || fourCC == "p010"
    }

    /// Validates that `pixelFormat` obeys the zero-4:2:0 invariant and satisfies `tier` chroma/alpha requirements.
    public static func validatePixelFormat(_ pixelFormat: OSType, for tier: ProResTier) throws {
        let formatName = pixelFormatFourCC(pixelFormat)

        if isForbidden420Format(pixelFormat) {
            throw ProResPipelineError.forbidden420Subsampling(
                pixelFormat: formatName,
                tier: tier.rawValue
            )
        }

        if tier.is4444 {
            guard allowed4444Formats.contains(pixelFormat) else {
                throw ProResPipelineError.incompatiblePixelFormat(
                    pixelFormat: formatName,
                    tier: tier.rawValue,
                    reason: "ProRes 4444/4444 XQ requires alpha-preserving 4:4:4:4 buffers (32BGRA or 64RGBAHalf)"
                )
            }
        } else {
            let valid422 = allowed422Formats.contains(pixelFormat)
            let valid444 = allowed4444Formats.contains(pixelFormat)
            guard valid422 || valid444 else {
                throw ProResPipelineError.incompatiblePixelFormat(
                    pixelFormat: formatName,
                    tier: tier.rawValue,
                    reason: "ProRes 422 tiers require 4:2:2 (v210 / 422YpCbCr10 / 422YpCbCr8) or 4:4:4 (32BGRA / 64RGBAHalf) buffers"
                )
            }
        }
    }

    /// Allocates an IOSurface-backed `CVPixelBuffer` compatible with ProRes (never 4:2:0) and attaches color metadata.
    public static func makeIOSurfacePixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        colorMetadata: FrameColorMetadata = .bt709SDR()
    ) throws -> CVPixelBuffer {
        guard width >= 2, height >= 2 else {
            throw ProResPipelineError.invalidDimensions(width: width, height: height)
        }
        if isForbidden420Format(pixelFormat) {
            throw ProResPipelineError.forbidden420Subsampling(
                pixelFormat: pixelFormatFourCC(pixelFormat),
                tier: "prores"
            )
        }

        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
        ]

        var pbOut: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attrs as CFDictionary,
            &pbOut
        )
        guard status == kCVReturnSuccess, let buffer = pbOut else {
            throw ProResPipelineError.encodeFailed(
                "CVPixelBufferCreate failed (status=\(status)) for \(pixelFormatFourCC(pixelFormat)) \(width)x\(height)"
            )
        }
        colorMetadata.apply(to: buffer)
        return buffer
    }

    /// Encodes `buffers` into a QuickTime `.mov` file using native `AVAssetWriter` ProRes encoding,
    /// strictly enforcing the zero-4:2:0 invariant on every single frame.
    public static func encodeFrames(
        _ buffers: [CVPixelBuffer],
        to outputURL: URL,
        options: ProResEncodeOptions
    ) throws -> ProResEncodeResult {
        ensureProfessionalVideoWorkflowRegistered()

        guard !buffers.isEmpty else {
            throw ProResPipelineError.emptyFrameSequence
        }
        guard options.width >= 2, options.height >= 2 else {
            throw ProResPipelineError.invalidDimensions(width: options.width, height: options.height)
        }
        guard options.fps.isFinite && options.fps > 0.0 else {
            throw ProResPipelineError.invalidFrameRate(fps: options.fps)
        }

        // Fail-closed validation on ALL input buffers BEFORE opening the writer.
        let primaryFormat = CVPixelBufferGetPixelFormatType(buffers[0])
        for buffer in buffers {
            let fmt = CVPixelBufferGetPixelFormatType(buffer)
            try validatePixelFormat(fmt, for: options.tier)
        }

        let startTime = DispatchTime.now().uptimeNanoseconds

        // Prepare output destination cleanly.
        let fm = FileManager.default
        let parentDir = outputURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parentDir.path) {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: outputURL.path) {
            try fm.removeItem(at: outputURL)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw ProResPipelineError.writerInitializationFailed(error.localizedDescription)
        }

        let colorProperties = avColorProperties(from: options.colorMetadata)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: options.tier.avVideoCodecType,
            AVVideoWidthKey: options.width,
            AVVideoHeightKey: options.height,
            AVVideoColorPropertiesKey: colorProperties,
        ]

        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false

        // Source pixel buffer attributes MUST mirror the validated non-4:2:0 format + IOSurface backing.
        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(primaryFormat),
            kCVPixelBufferWidthKey as String: options.width,
            kCVPixelBufferHeightKey as String: options.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: sourceAttributes
        )

        guard writer.canAdd(writerInput) else {
            throw ProResPipelineError.writerInitializationFailed(
                "AVAssetWriter rejected ProRes input for tier \(options.tier.fourCC)"
            )
        }
        writer.add(writerInput)

        guard writer.startWriting() else {
            let reason = writer.error?.localizedDescription ?? "unknown startWriting failure"
            throw ProResPipelineError.writerInitializationFailed(reason)
        }

        let timescale: CMTimeScale = 60_000
        let frameTicks = max(1, Int64((Double(timescale) / options.fps).rounded()))
        writer.startSession(atSourceTime: .zero)

        var encodedCount = 0
        for (index, rawBuffer) in buffers.enumerated() {
            // Ensure IOSurface backing without ever changing pixel format or touching 4:2:0.
            let bufferToEncode = try ensureIOSurfaceBacked(
                rawBuffer,
                colorMetadata: options.colorMetadata
            )
            options.colorMetadata.apply(to: bufferToEncode)

            while !writerInput.isReadyForMoreMediaData {
                if writer.status == .failed || writer.status == .cancelled {
                    let detail = writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)"
                    throw ProResPipelineError.encodeFailed(detail)
                }
                Thread.sleep(forTimeInterval: 0.001)
            }

            let pts = CMTime(value: CMTimeValue(Int64(index) * frameTicks), timescale: timescale)
            guard adaptor.append(bufferToEncode, withPresentationTime: pts) else {
                let detail = writer.error?.localizedDescription ?? "adaptor.append returned false at frame \(index)"
                throw ProResPipelineError.encodeFailed(detail)
            }
            encodedCount += 1
        }

        writerInput.markAsFinished()
        let endTime = CMTime(value: CMTimeValue(Int64(encodedCount) * frameTicks), timescale: timescale)
        writer.endSession(atSourceTime: endTime)

        let finishSemaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            finishSemaphore.signal()
        }
        finishSemaphore.wait()

        guard writer.status == .completed else {
            let detail = writer.error?.localizedDescription ?? "finishWriting ended with status \(writer.status.rawValue)"
            throw ProResPipelineError.encodeFailed(detail)
        }

        let endNanos = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = Double(endNanos &- startTime) / 1_000_000.0

        let attrs = try fm.attributesOfItem(atPath: outputURL.path)
        let bytesWritten = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let preservesAlpha = options.tier.supportsAlpha && options.preserveAlpha && allowed4444Formats.contains(primaryFormat)

        return ProResEncodeResult(
            outputPath: outputURL.path,
            tier: options.tier.rawValue,
            fourCC: options.tier.fourCC,
            pixelFormatUsed: pixelFormatFourCC(primaryFormat),
            zero420Downconversion: true,
            preservesAlpha: preservesAlpha,
            framesEncoded: encodedCount,
            bytesWritten: bytesWritten,
            elapsedMs: elapsedMs
        )
    }

    // MARK: - Internal Helpers

    private static func ensureIOSurfaceBacked(
        _ buffer: CVPixelBuffer,
        colorMetadata: FrameColorMetadata
    ) throws -> CVPixelBuffer {
        if CVPixelBufferGetIOSurface(buffer) != nil {
            return buffer
        }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let ioBacked = try makeIOSurfacePixelBuffer(
            width: width,
            height: height,
            pixelFormat: format,
            colorMetadata: colorMetadata
        )

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        CVPixelBufferLockBaseAddress(ioBacked, [])
        defer {
            CVPixelBufferUnlockBaseAddress(ioBacked, [])
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }

        if CVPixelBufferIsPlanar(buffer) {
            let planes = CVPixelBufferGetPlaneCount(buffer)
            for plane in 0..<planes {
                guard let srcBase = CVPixelBufferGetBaseAddressOfPlane(buffer, plane),
                      let dstBase = CVPixelBufferGetBaseAddressOfPlane(ioBacked, plane)
                else {
                    continue
                }
                let srcBPR = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
                let dstBPR = CVPixelBufferGetBytesPerRowOfPlane(ioBacked, plane)
                let copyBytes = min(srcBPR, dstBPR)
                let planeHeight = min(
                    CVPixelBufferGetHeightOfPlane(buffer, plane),
                    CVPixelBufferGetHeightOfPlane(ioBacked, plane)
                )
                for row in 0..<planeHeight {
                    memcpy(
                        dstBase.advanced(by: row * dstBPR),
                        srcBase.advanced(by: row * srcBPR),
                        copyBytes
                    )
                }
            }
        } else if let srcBase = CVPixelBufferGetBaseAddress(buffer),
                  let dstBase = CVPixelBufferGetBaseAddress(ioBacked)
        {
            let srcBPR = CVPixelBufferGetBytesPerRow(buffer)
            let dstBPR = CVPixelBufferGetBytesPerRow(ioBacked)
            let copyBytes = min(srcBPR, dstBPR)
            for row in 0..<height {
                memcpy(
                    dstBase.advanced(by: row * dstBPR),
                    srcBase.advanced(by: row * srcBPR),
                    copyBytes
                )
            }
        }

        return ioBacked
    }

    private static func avColorProperties(from metadata: FrameColorMetadata) -> [String: Any] {
        let primaries: String
        if metadata.primaries == (kCVImageBufferColorPrimaries_ITU_R_2020 as String) {
            primaries = AVVideoColorPrimaries_ITU_R_2020
        } else if metadata.primaries == (kCVImageBufferColorPrimaries_P3_D65 as String) {
            primaries = AVVideoColorPrimaries_P3_D65
        } else {
            primaries = AVVideoColorPrimaries_ITU_R_709_2
        }

        let transfer: String
        if metadata.transfer == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String) {
            transfer = AVVideoTransferFunction_SMPTE_ST_2084_PQ
        } else if metadata.transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String) {
            transfer = AVVideoTransferFunction_ITU_R_2100_HLG
        } else {
            transfer = AVVideoTransferFunction_ITU_R_709_2
        }

        let matrix: String
        if metadata.matrix == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) {
            matrix = AVVideoYCbCrMatrix_ITU_R_2020
        } else {
            matrix = AVVideoYCbCrMatrix_ITU_R_709_2
        }

        return [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: matrix,
        ]
    }

    public static func pixelFormatFourCC(_ format: OSType) -> String {
        switch format {
        case kCVPixelFormatType_32BGRA:
            return "BGRA"
        case kCVPixelFormatType_32ARGB:
            return "ARGB"
        case kCVPixelFormatType_64RGBAHalf:
            return "RGhA"
        case kCVPixelFormatType_64ARGB:
            return "b64a"
        default:
            let bytes: [UInt8] = [
                UInt8((format >> 24) & 0xFF),
                UInt8((format >> 16) & 0xFF),
                UInt8((format >> 8) & 0xFF),
                UInt8(format & 0xFF),
            ]
            if bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }),
               let str = String(bytes: bytes, encoding: .ascii)
            {
                return str
            }
            return String(format: "0x%08x", format)
        }
    }
}
