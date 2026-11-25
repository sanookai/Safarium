import CoreMedia
import CoreVideo
import Foundation
import IOSurface
import Metal

// MARK: - Wave 11D: Zero-Copy IOSurface FrameLease & Color Metadata Preservation

/// Complete colorimetry and HDR mastering metadata attached to every `FrameLease`
/// so no pipeline stage can silently strip primaries, transfer, matrix, or mastering info.
public struct FrameColorMetadata: Codable, Equatable, Sendable {
    public let primaries: String
    public let transfer: String
    public let matrix: String
    public let fullRange: Bool
    public let chromaLocation: String
    public let bitDepth: Int
    public let masteringDisplayData: Data?
    public let contentLightLevelData: Data?
    public let ambientViewingData: Data?
    public let hasDynamicHDR: Bool
    public let edrHeadroom: Float?

    public init(
        primaries: String,
        transfer: String,
        matrix: String,
        fullRange: Bool = false,
        chromaLocation: String = kCVImageBufferChromaLocation_Left as String,
        bitDepth: Int = 8,
        masteringDisplayData: Data? = nil,
        contentLightLevelData: Data? = nil,
        ambientViewingData: Data? = nil,
        hasDynamicHDR: Bool = false,
        edrHeadroom: Float? = nil
    ) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.fullRange = fullRange
        self.chromaLocation = chromaLocation
        self.bitDepth = bitDepth
        self.masteringDisplayData = masteringDisplayData
        self.contentLightLevelData = contentLightLevelData
        self.ambientViewingData = ambientViewingData
        self.hasDynamicHDR = hasDynamicHDR
        self.edrHeadroom = edrHeadroom
    }

    // MARK: - Factory Presets

    public static func bt709SDR(
        fullRange: Bool = false,
        bitDepth: Int = 8
    ) -> FrameColorMetadata {
        FrameColorMetadata(
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
            transfer: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String,
            fullRange: fullRange,
            chromaLocation: kCVImageBufferChromaLocation_Left as String,
            bitDepth: bitDepth,
            masteringDisplayData: nil,
            contentLightLevelData: nil,
            ambientViewingData: nil,
            hasDynamicHDR: false,
            edrHeadroom: nil
        )
    }

    public static func bt2020PQ(
        bitDepth: Int = 10,
        fullRange: Bool = false,
        masteringDisplayData: Data? = nil,
        contentLightLevelData: Data? = nil,
        ambientViewingData: Data? = nil,
        hasDynamicHDR: Bool = false,
        edrHeadroom: Float? = nil
    ) -> FrameColorMetadata {
        FrameColorMetadata(
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020 as String,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020 as String,
            fullRange: fullRange,
            chromaLocation: kCVImageBufferChromaLocation_TopLeft as String,
            bitDepth: bitDepth,
            masteringDisplayData: masteringDisplayData,
            contentLightLevelData: contentLightLevelData,
            ambientViewingData: ambientViewingData,
            hasDynamicHDR: hasDynamicHDR,
            edrHeadroom: edrHeadroom
        )
    }

    public static func bt2020HLG(
        bitDepth: Int = 10,
        fullRange: Bool = false,
        masteringDisplayData: Data? = nil,
        contentLightLevelData: Data? = nil,
        ambientViewingData: Data? = nil,
        hasDynamicHDR: Bool = false,
        edrHeadroom: Float? = nil
    ) -> FrameColorMetadata {
        FrameColorMetadata(
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020 as String,
            transfer: kCVImageBufferTransferFunction_ITU_R_2100_HLG as String,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020 as String,
            fullRange: fullRange,
            chromaLocation: kCVImageBufferChromaLocation_TopLeft as String,
            bitDepth: bitDepth,
            masteringDisplayData: masteringDisplayData,
            contentLightLevelData: contentLightLevelData,
            ambientViewingData: ambientViewingData,
            hasDynamicHDR: hasDynamicHDR,
            edrHeadroom: edrHeadroom
        )
    }

    // MARK: - CoreVideo Attachment Round-Trip

    private static let dynamicHDRAttachmentKey = "SafariumHasDynamicHDR" as CFString
    private static let edrHeadroomAttachmentKey = "SafariumEDRHeadroom" as CFString
    private static let fullRangeAttachmentKey = "SafariumFullRange" as CFString
    private static let bitDepthAttachmentKey = "SafariumBitDepth" as CFString
    private static let hdrStatisticsFilteredKey = "HDRImageStatisticsInfo_Filtered" as CFString

    /// Reads colorimetry, mastering display, CLL, ambient viewing, and HDR tags from a `CVPixelBuffer`.
    public static func from(pixelBuffer: CVPixelBuffer) -> FrameColorMetadata {
        let primaries = copyStringAttachment(pixelBuffer, key: kCVImageBufferColorPrimariesKey)
            ?? (kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        let transfer = copyStringAttachment(pixelBuffer, key: kCVImageBufferTransferFunctionKey)
            ?? (kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        let matrix = copyStringAttachment(pixelBuffer, key: kCVImageBufferYCbCrMatrixKey)
            ?? (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        let chroma = copyStringAttachment(pixelBuffer, key: kCVImageBufferChromaLocationTopFieldKey)
            ?? (kCVImageBufferChromaLocation_Left as String)

        let mdcv = copyDataAttachment(pixelBuffer, key: kCVImageBufferMasteringDisplayColorVolumeKey)
        let clli = copyDataAttachment(pixelBuffer, key: kCVImageBufferContentLightLevelInfoKey)
        let amve = copyDataAttachment(pixelBuffer, key: kCVImageBufferAmbientViewingEnvironmentKey)

        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let inferredFullRange = inferFullRange(for: fmt)
        let inferredBitDepth = inferBitDepth(for: fmt)

        let fullRange = copyBoolAttachment(pixelBuffer, key: fullRangeAttachmentKey) ?? inferredFullRange
        let bitDepth = copyIntAttachment(pixelBuffer, key: bitDepthAttachmentKey) ?? inferredBitDepth

        let explicitDynamicHDR = copyBoolAttachment(pixelBuffer, key: dynamicHDRAttachmentKey)
        let hasFilteredStats = CVBufferCopyAttachment(pixelBuffer, hdrStatisticsFilteredKey, nil) != nil
        let hasDynamicHDR = explicitDynamicHDR ?? hasFilteredStats

        let edrHeadroom = copyFloatAttachment(pixelBuffer, key: edrHeadroomAttachmentKey)

        return FrameColorMetadata(
            primaries: primaries,
            transfer: transfer,
            matrix: matrix,
            fullRange: fullRange,
            chromaLocation: chroma,
            bitDepth: bitDepth,
            masteringDisplayData: mdcv,
            contentLightLevelData: clli,
            ambientViewingData: amve,
            hasDynamicHDR: hasDynamicHDR,
            edrHeadroom: edrHeadroom
        )
    }

    /// Propagates all colorimetry & HDR attachments onto `pixelBuffer`, clearing stale optional tags on pool reuse.
    public func apply(to pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            primaries as CFString,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            transfer as CFString,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            matrix as CFString,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferChromaLocationTopFieldKey,
            chromaLocation as CFString,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferChromaLocationBottomFieldKey,
            chromaLocation as CFString,
            .shouldPropagate
        )

        setOrRemoveData(masteringDisplayData, key: kCVImageBufferMasteringDisplayColorVolumeKey, on: pixelBuffer)
        setOrRemoveData(contentLightLevelData, key: kCVImageBufferContentLightLevelInfoKey, on: pixelBuffer)
        setOrRemoveData(ambientViewingData, key: kCVImageBufferAmbientViewingEnvironmentKey, on: pixelBuffer)

        CVBufferSetAttachment(
            pixelBuffer,
            Self.fullRangeAttachmentKey,
            (fullRange ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            Self.bitDepthAttachmentKey,
            NSNumber(value: bitDepth) as CFTypeRef,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            Self.dynamicHDRAttachmentKey,
            (hasDynamicHDR ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef,
            .shouldPropagate
        )
        if let headroom = edrHeadroom {
            CVBufferSetAttachment(
                pixelBuffer,
                Self.edrHeadroomAttachmentKey,
                NSNumber(value: headroom) as CFTypeRef,
                .shouldPropagate
            )
        } else {
            CVBufferRemoveAttachment(pixelBuffer, Self.edrHeadroomAttachmentKey)
        }
    }

    // MARK: - Attachment Helpers

    private func setOrRemoveData(_ data: Data?, key: CFString, on pixelBuffer: CVPixelBuffer) {
        if let data {
            CVBufferSetAttachment(pixelBuffer, key, data as CFData, .shouldPropagate)
        } else {
            CVBufferRemoveAttachment(pixelBuffer, key)
        }
    }

    private static func copyStringAttachment(_ buffer: CVPixelBuffer, key: CFString) -> String? {
        CVBufferCopyAttachment(buffer, key, nil) as? String
    }

    private static func copyDataAttachment(_ buffer: CVPixelBuffer, key: CFString) -> Data? {
        CVBufferCopyAttachment(buffer, key, nil) as? Data
    }

    private static func copyBoolAttachment(_ buffer: CVPixelBuffer, key: CFString) -> Bool? {
        (CVBufferCopyAttachment(buffer, key, nil) as? NSNumber)?.boolValue
    }

    private static func copyIntAttachment(_ buffer: CVPixelBuffer, key: CFString) -> Int? {
        (CVBufferCopyAttachment(buffer, key, nil) as? NSNumber)?.intValue
    }

    private static func copyFloatAttachment(_ buffer: CVPixelBuffer, key: CFString) -> Float? {
        (CVBufferCopyAttachment(buffer, key, nil) as? NSNumber)?.floatValue
    }

    private static func inferFullRange(for format: OSType) -> Bool {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_32BGRA,
             kCVPixelFormatType_64RGBAHalf:
            return true
        default:
            return false
        }
    }

    private static func inferBitDepth(for format: OSType) -> Int {
        switch format {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10,
             kCVPixelFormatType_444YpCbCr10:
            return 10
        case kCVPixelFormatType_64RGBAHalf,
             kCVPixelFormatType_422YpCbCr16,
             kCVPixelFormatType_4444AYpCbCr16:
            return 16
        default:
            return 8
        }
    }
}

// MARK: - Zero-Copy Telemetry & Budget Enforcement

/// Immutable snapshot of zero-copy pipeline telemetry counters.
public struct ZeroCopyCounters: Codable, Equatable, Sendable {
    public let cpuReadbacks: Int
    public let pixelBufferCopies: Int
    public let iosurfaceReallocations: Int
    public let poolMisses: Int
    public let leasesCreated: Int
    public let metalTexturesCreated: Int

    public init(
        cpuReadbacks: Int = 0,
        pixelBufferCopies: Int = 0,
        iosurfaceReallocations: Int = 0,
        poolMisses: Int = 0,
        leasesCreated: Int = 0,
        metalTexturesCreated: Int = 0
    ) {
        self.cpuReadbacks = cpuReadbacks
        self.pixelBufferCopies = pixelBufferCopies
        self.iosurfaceReallocations = iosurfaceReallocations
        self.poolMisses = poolMisses
        self.leasesCreated = leasesCreated
        self.metalTexturesCreated = metalTexturesCreated
    }
}

/// Error thrown when a pipeline violates its zero-copy CPU readback or pixel-copy budget.
public enum ZeroCopyBudgetError: Error, CustomStringConvertible, Equatable, Sendable {
    case cpuReadbackBudgetExceeded(actual: Int, maxAllowed: Int)
    case pixelBufferCopyBudgetExceeded(actual: Int, maxAllowed: Int)

    public var description: String {
        switch self {
        case .cpuReadbackBudgetExceeded(let actual, let maxAllowed):
            return "Zero-copy budget violated: \(actual) CPU readback(s) exceeded limit of \(maxAllowed)"
        case .pixelBufferCopyBudgetExceeded(let actual, let maxAllowed):
            return "Zero-copy budget violated: \(actual) pixel buffer copy(ies) exceeded limit of \(maxAllowed)"
        }
    }
}

/// Thread-safe lock-protected telemetry tracker for verifying zero-copy GPU/IOSurface frame flow.
public final class ZeroCopyTelemetry: @unchecked Sendable {
    private let lock = NSLock()
    private var _cpuReadbacks: Int = 0
    private var _pixelBufferCopies: Int = 0
    private var _iosurfaceReallocations: Int = 0
    private var _poolMisses: Int = 0
    private var _leasesCreated: Int = 0
    private var _metalTexturesCreated: Int = 0

    public init() {}

    public var cpuReadbacks: Int {
        lock.lock()
        defer { lock.unlock() }
        return _cpuReadbacks
    }

    public var pixelBufferCopies: Int {
        lock.lock()
        defer { lock.unlock() }
        return _pixelBufferCopies
    }

    public var iosurfaceReallocations: Int {
        lock.lock()
        defer { lock.unlock() }
        return _iosurfaceReallocations
    }

    public var poolMisses: Int {
        lock.lock()
        defer { lock.unlock() }
        return _poolMisses
    }

    public var leasesCreated: Int {
        lock.lock()
        defer { lock.unlock() }
        return _leasesCreated
    }

    public var metalTexturesCreated: Int {
        lock.lock()
        defer { lock.unlock() }
        return _metalTexturesCreated
    }

    public func recordCPUReadback(_ delta: Int = 1) {
        lock.lock()
        _cpuReadbacks += delta
        lock.unlock()
    }

    public func recordPixelBufferCopy(_ delta: Int = 1) {
        lock.lock()
        _pixelBufferCopies += delta
        lock.unlock()
    }

    public func recordIOSurfaceReallocation(_ delta: Int = 1) {
        lock.lock()
        _iosurfaceReallocations += delta
        lock.unlock()
    }

    public func recordPoolMiss(_ delta: Int = 1) {
        lock.lock()
        _poolMisses += delta
        lock.unlock()
    }

    public func recordLeaseCreated(_ delta: Int = 1) {
        lock.lock()
        _leasesCreated += delta
        lock.unlock()
    }

    public func recordMetalTextureCreated(_ delta: Int = 1) {
        lock.lock()
        _metalTexturesCreated += delta
        lock.unlock()
    }

    public func snapshot() -> ZeroCopyCounters {
        lock.lock()
        defer { lock.unlock() }
        return ZeroCopyCounters(
            cpuReadbacks: _cpuReadbacks,
            pixelBufferCopies: _pixelBufferCopies,
            iosurfaceReallocations: _iosurfaceReallocations,
            poolMisses: _poolMisses,
            leasesCreated: _leasesCreated,
            metalTexturesCreated: _metalTexturesCreated
        )
    }

    public func reset() {
        lock.lock()
        _cpuReadbacks = 0
        _pixelBufferCopies = 0
        _iosurfaceReallocations = 0
        _poolMisses = 0
        _leasesCreated = 0
        _metalTexturesCreated = 0
        lock.unlock()
    }

    public func assertBudget(maxCPUReadbacks: Int = 0, maxCopies: Int = 0) throws {
        let current = snapshot()
        if current.cpuReadbacks > maxCPUReadbacks {
            throw ZeroCopyBudgetError.cpuReadbackBudgetExceeded(
                actual: current.cpuReadbacks,
                maxAllowed: maxCPUReadbacks
            )
        }
        if current.pixelBufferCopies > maxCopies {
            throw ZeroCopyBudgetError.pixelBufferCopyBudgetExceeded(
                actual: current.pixelBufferCopies,
                maxAllowed: maxCopies
            )
        }
    }
}

// MARK: - FrameLease (Zero-Copy IOSurface + Lazy Metal Texture Binding)

/// Owns a leased IOSurface-backed `CVPixelBuffer`, its preserved `FrameColorMetadata`, timing,
/// and lazily bound zero-copy `MTLTexture` views via `CVMetalTextureCache`.
public final class FrameLease: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let iosurface: IOSurfaceRef?
    public let metadata: FrameColorMetadata
    public let pts: CMTime
    public let duration: CMTime
    public let width: Int
    public let height: Int
    public let pixelFormat: OSType

    private let telemetry: ZeroCopyTelemetry?
    private let textureLock = NSLock()
    private var cachedTextures: [TextureCacheKey: (CVMetalTexture, MTLTexture)] = [:]

    private struct TextureCacheKey: Hashable {
        let planeIndex: Int
        let rawPixelFormat: UInt
    }

    public var isIOSurfaceBacked: Bool {
        iosurface != nil
    }

    public init(
        pixelBuffer: CVPixelBuffer,
        metadata: FrameColorMetadata? = nil,
        pts: CMTime = .zero,
        duration: CMTime = .invalid,
        telemetry: ZeroCopyTelemetry? = nil,
        applyMetadataToBuffer: Bool = true
    ) {
        self.pixelBuffer = pixelBuffer
        self.iosurface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue()
        self.pts = pts
        self.duration = duration
        self.width = CVPixelBufferGetWidth(pixelBuffer)
        self.height = CVPixelBufferGetHeight(pixelBuffer)
        self.pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        self.telemetry = telemetry

        if let provided = metadata {
            self.metadata = provided
            if applyMetadataToBuffer {
                provided.apply(to: pixelBuffer)
            }
        } else {
            self.metadata = FrameColorMetadata.from(pixelBuffer: pixelBuffer)
        }

        telemetry?.recordLeaseCreated()
    }

    /// Lazily binds plane 0 (luma or packed BGRA/RGBA) as a zero-copy `MTLTexture` via `CVMetalTextureCache`.
    /// Never locks CPU base address or copies bytes.
    public func lumaTexture(
        cache: CVMetalTextureCache,
        pixelFormat overrideFormat: MTLPixelFormat? = nil
    ) throws -> MTLTexture {
        let resolved = overrideFormat ?? defaultLumaMetalFormat(for: pixelFormat)
        return try metalTexture(cache: cache, planeIndex: 0, pixelFormat: resolved)
    }

    /// Lazily binds plane 1 (bi-planar chroma CbCr) as a zero-copy `MTLTexture` via `CVMetalTextureCache`.
    /// Never locks CPU base address or copies bytes.
    public func chromaTexture(
        cache: CVMetalTextureCache,
        pixelFormat overrideFormat: MTLPixelFormat? = nil
    ) throws -> MTLTexture {
        guard CVPixelBufferIsPlanar(pixelBuffer), CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else {
            throw SafariumError.invalidState(
                "chromaTexture requires a multi-planar CVPixelBuffer (current format: \(pixelFormat))"
            )
        }
        let resolved = overrideFormat ?? defaultChromaMetalFormat(for: pixelFormat)
        return try metalTexture(cache: cache, planeIndex: 1, pixelFormat: resolved)
    }

    /// Binds an arbitrary plane as a zero-copy Metal texture, retaining the backing `CVMetalTexture`.
    public func metalTexture(
        cache: CVMetalTextureCache,
        planeIndex: Int,
        pixelFormat mtlFormat: MTLPixelFormat
    ) throws -> MTLTexture {
        let key = TextureCacheKey(planeIndex: planeIndex, rawPixelFormat: mtlFormat.rawValue)

        textureLock.lock()
        if let existing = cachedTextures[key] {
            textureLock.unlock()
            return existing.1
        }
        textureLock.unlock()

        let isPlanar = CVPixelBufferIsPlanar(pixelBuffer)
        let planeWidth: Int
        let planeHeight: Int
        if isPlanar {
            guard planeIndex >= 0 && planeIndex < CVPixelBufferGetPlaneCount(pixelBuffer) else {
                throw SafariumError.invalidState("Requested plane \(planeIndex) out of bounds")
            }
            planeWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, planeIndex)
            planeHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex)
        } else {
            guard planeIndex == 0 else {
                throw SafariumError.invalidState("Non-planar CVPixelBuffer only supports plane 0")
            }
            planeWidth = width
            planeHeight = height
        }

        var cvTexOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            mtlFormat,
            planeWidth,
            planeHeight,
            planeIndex,
            &cvTexOut
        )
        guard status == kCVReturnSuccess,
              let cvTex = cvTexOut,
              let mtlTex = CVMetalTextureGetTexture(cvTex) else {
            throw SafariumError.encode(
                "CVMetalTextureCacheCreateTextureFromImage failed for plane \(planeIndex) (CVReturn \(status))"
            )
        }

        textureLock.lock()
        cachedTextures[key] = (cvTex, mtlTex)
        textureLock.unlock()

        telemetry?.recordMetalTextureCreated()
        return mtlTex
    }

    private func defaultLumaMetalFormat(for cvFormat: OSType) -> MTLPixelFormat {
        switch cvFormat {
        case kCVPixelFormatType_32BGRA:
            return .bgra8Unorm
        case kCVPixelFormatType_64RGBAHalf:
            return .rgba16Float
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return .r16Unorm
        default:
            return .r8Unorm
        }
    }

    private func defaultChromaMetalFormat(for cvFormat: OSType) -> MTLPixelFormat {
        switch cvFormat {
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_422YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange,
             kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return .rg16Unorm
        default:
            return .rg8Unorm
        }
    }
}

// MARK: - FrameLeasePool

/// IOSurface-backed, Metal-compatible `CVPixelBufferPool` wrapper that emits `FrameLease`s
/// and tracks steady-state surface reuse, pool misses, and IOSurface reallocations.
public final class FrameLeasePool: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let pixelFormat: OSType
    public let minimumBufferCount: Int
    public let telemetry: ZeroCopyTelemetry

    private let pool: CVPixelBufferPool
    private let lock = NSLock()
    private var knownSurfaceIDs: Set<IOSurfaceID> = []

    public var knownSurfaceCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return knownSurfaceIDs.count
    }

    public init(
        width: Int,
        height: Int,
        pixelFormat: OSType = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        minimumBufferCount: Int = 4,
        maximumBufferAge: TimeInterval = 5.0,
        telemetry: ZeroCopyTelemetry = ZeroCopyTelemetry()
    ) throws {
        guard width > 0, height > 0 else {
            throw SafariumError.invalidState("FrameLeasePool dimensions must be positive (\(width)x\(height))")
        }

        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.minimumBufferCount = max(1, minimumBufferCount)
        self.telemetry = telemetry

        let poolAttrs: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: self.minimumBufferCount,
            kCVPixelBufferPoolMaximumBufferAgeKey: maximumBufferAge,
        ]
        let pixelBufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: pixelFormat,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey: true,
        ]

        var poolOut: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttrs as CFDictionary,
            pixelBufferAttrs as CFDictionary,
            &poolOut
        )
        guard status == kCVReturnSuccess, let createdPool = poolOut else {
            throw SafariumError.encode("CVPixelBufferPoolCreate failed (CVReturn \(status))")
        }
        self.pool = createdPool
    }

    /// Leases an IOSurface-backed `CVPixelBuffer` from the pool, applies `metadata`, and tracks reuse telemetry.
    public func lease(
        metadata: FrameColorMetadata,
        pts: CMTime = .zero,
        duration: CMTime = .invalid
    ) throws -> FrameLease {
        var bufferOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &bufferOut)
        guard status == kCVReturnSuccess, let buffer = bufferOut else {
            telemetry.recordPoolMiss()
            throw SafariumError.encode("CVPixelBufferPoolCreatePixelBuffer failed (CVReturn \(status))")
        }

        if let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
            let sid = IOSurfaceGetID(surface)
            lock.lock()
            let wasKnown = knownSurfaceIDs.contains(sid)
            let alreadyWarmed = knownSurfaceIDs.count >= minimumBufferCount
            if !wasKnown {
                knownSurfaceIDs.insert(sid)
            }
            lock.unlock()

            if !wasKnown && alreadyWarmed {
                telemetry.recordPoolMiss()
                telemetry.recordIOSurfaceReallocation()
            }
        } else {
            telemetry.recordPoolMiss()
            telemetry.recordIOSurfaceReallocation()
        }

        return FrameLease(
            pixelBuffer: buffer,
            metadata: metadata,
            pts: pts,
            duration: duration,
            telemetry: telemetry,
            applyMetadataToBuffer: true
        )
    }

    /// Flushes idle buffers in the underlying `CVPixelBufferPool`.
    public func flush(excessOnly: Bool = false) {
        let flags: CVPixelBufferPoolFlushFlags = excessOnly ? .excessBuffers : []
        CVPixelBufferPoolFlush(pool, flags)
    }
}
