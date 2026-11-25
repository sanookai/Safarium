import Accelerate
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import SafariumCore
import UniformTypeIdentifiers

public struct ForgeSequenceIngestConfig: Sendable {
    public var framePaths: [URL]
    public var fps: Int
    public var width: Int?
    public var height: Int?
    public var codec: VideoCodec
    public var bitrate: Int?
    public var quality: Double?
    public var pixelFormat: SinkPixelFormat
    public var closedGOP: Bool
    public var audioURL: URL?
    public var inlineSheetConfig: ForgeContactSheetConfig?
    public var inlineSheetOutputURL: URL?
    public var overwrite: Bool
    public var decodeAheadSlots: Int

    public init(
        framePaths: [URL],
        fps: Int = 24,
        width: Int? = nil,
        height: Int? = nil,
        codec: VideoCodec = .h264,
        bitrate: Int? = 8_000_000,
        quality: Double? = nil,
        pixelFormat: SinkPixelFormat? = nil,
        closedGOP: Bool = true,
        audioURL: URL? = nil,
        inlineSheetConfig: ForgeContactSheetConfig? = nil,
        inlineSheetOutputURL: URL? = nil,
        overwrite: Bool = false,
        decodeAheadSlots: Int = 3
    ) {
        self.framePaths = framePaths
        self.fps = fps
        self.width = width
        self.height = height
        self.codec = codec
        self.bitrate = bitrate
        self.quality = quality
        self.pixelFormat = pixelFormat ?? (codec.hasAlpha ? .bgra : .nv12Left)
        self.closedGOP = closedGOP
        self.audioURL = audioURL
        self.inlineSheetConfig = inlineSheetConfig
        self.inlineSheetOutputURL = inlineSheetOutputURL
        self.overwrite = overwrite
        self.decodeAheadSlots = max(1, min(4, decodeAheadSlots))
    }
}

public struct ForgeSequenceIngestReport: Codable, Sendable {
    public let outputPath: String
    public let width: Int
    public let height: Int
    public let fps: Int
    public let frames: Int
    public let codec: String
    public let bytes: Int64
    public let wallMs: Double
    public let sheetPath: String?
    public let sheetCols: Int?
    public let sheetRows: Int?
    public let peakRSSMB: Double
}

public enum ForgeSequenceIngest {
    private static let supportedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "heic", "heif", "tif", "tiff", "bmp", "gif", "avif",
    ]

    private struct SendablePixelBufferPool: @unchecked Sendable {
        let raw: CVPixelBufferPool
    }

    private struct SendablePixelBuffer: @unchecked Sendable {
        let raw: CVPixelBuffer
    }

    private static func isSidecarOrHidden(_ name: String) -> Bool {
        name.hasPrefix(".") || name.hasPrefix("._")
    }

    private static func isSupportedImageFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if isSidecarOrHidden(name) { return false }
        var st = stat()
        guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              FileManager.default.isReadableFile(atPath: url.path) else {
            return false
        }
        return supportedImageExtensions.contains(url.pathExtension.lowercased())
    }

    /// Locale-independent natural numeric comparison (`frame_0001.png` < `frame_2.png` < `frame_10.png`).
    private static func naturalNumericCompare(_ a: String, _ b: String) -> ComparisonResult {
        let ua = Array(a.unicodeScalars)
        let ub = Array(b.unicodeScalars)
        var ia = 0
        var ib = 0

        func isASCIIDigit(_ s: UnicodeScalar) -> Bool {
            s.value >= 0x30 && s.value <= 0x39
        }

        while ia < ua.count && ib < ub.count {
            let da = isASCIIDigit(ua[ia])
            let db = isASCIIDigit(ub[ib])
            if da && db {
                var ja = ia
                while ja < ua.count && isASCIIDigit(ua[ja]) { ja += 1 }
                var jb = ib
                while jb < ub.count && isASCIIDigit(ub[jb]) { jb += 1 }

                var sa = ia
                while sa < ja && ua[sa].value == 0x30 { sa += 1 }
                var sb = ib
                while sb < jb && ub[sb].value == 0x30 { sb += 1 }

                let lenA = ja - sa
                let lenB = jb - sb
                if lenA != lenB {
                    return lenA < lenB ? .orderedAscending : .orderedDescending
                }
                for k in 0..<lenA {
                    let va = ua[sa + k].value
                    let vb = ub[sb + k].value
                    if va != vb {
                        return va < vb ? .orderedAscending : .orderedDescending
                    }
                }
                let rawLenA = ja - ia
                let rawLenB = jb - ib
                if rawLenA != rawLenB {
                    return rawLenA > rawLenB ? .orderedAscending : .orderedDescending
                }
                ia = ja
                ib = jb
            } else {
                let sa = ua[ia].value
                let sb = ub[ib].value
                if sa != sb {
                    return sa < sb ? .orderedAscending : .orderedDescending
                }
                ia += 1
                ib += 1
            }
        }
        if ua.count != ub.count {
            return ua.count < ub.count ? .orderedAscending : .orderedDescending
        }
        return .orderedSame
    }

    private static func sortedNaturally(_ urls: [URL]) -> [URL] {
        urls.sorted { lhs, rhs in
            let nameCmp = naturalNumericCompare(lhs.lastPathComponent, rhs.lastPathComponent)
            if nameCmp != .orderedSame {
                return nameCmp == .orderedAscending
            }
            return lhs.path < rhs.path
        }
    }

    private static func matchesGlob(_ pattern: String, candidate: String) -> Bool {
        pattern.withCString { pPtr in
            candidate.withCString { cPtr in
                fnmatch(pPtr, cPtr, 0) == 0
            }
        }
    }

    private static func parseListLinePath(_ rawLine: String, baseDirectory: URL) -> URL? {
        var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") { return nil }
        if line.hasPrefix("file ") {
            line = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if (line.hasPrefix("'") && line.hasSuffix("'")) || (line.hasPrefix("\"") && line.hasSuffix("\"")),
               line.count >= 2 {
                line = String(line.dropFirst().dropLast())
            }
        }
        if line.isEmpty { return nil }
        if line.hasPrefix("/") {
            return URL(fileURLWithPath: line)
        }
        return baseDirectory.appendingPathComponent(line)
    }

    /// Discovers image sequence frames from a directory, glob pattern, or list file.
    /// Applies natural numeric sorting (`frame_0001.png` < `frame_2.png` < `frame_10.png`) for directory/glob discovery
    /// and strictly skips dotfiles and ExFAT AppleDouble sidecars (`._*`).
    public static func discoverSequenceFrames(
        directoryURL: URL? = nil,
        globPattern: String? = nil,
        listFileURL: URL? = nil
    ) throws -> [URL] {
        if directoryURL == nil && globPattern == nil && listFileURL == nil {
            throw SafariumError.invalidState("missing sequence input: supply directoryURL, globPattern, or listFileURL")
        }

        if let listURL = listFileURL {
            try SafeFilePublisher.assertRegularReadableFile(listURL)
            let content = try String(contentsOf: listURL, encoding: .utf8)
            let baseDir = directoryURL ?? listURL.deletingLastPathComponent()
            var urls: [URL] = []
            for rawLine in content.components(separatedBy: .newlines) {
                guard let resolved = parseListLinePath(rawLine, baseDirectory: baseDir) else { continue }
                let name = resolved.lastPathComponent
                if isSidecarOrHidden(name) { continue }
                if let glob = globPattern {
                    let target = glob.contains("/") ? resolved.path : name
                    if !matchesGlob(glob, candidate: target) { continue }
                }
                try SafeFilePublisher.assertRegularReadableFile(resolved)
                guard supportedImageExtensions.contains(resolved.pathExtension.lowercased()) else {
                    throw SafariumError.invalidState("unsupported image extension in sequence list: \(resolved.lastPathComponent)")
                }
                urls.append(resolved)
            }
            guard !urls.isEmpty else {
                throw SafariumError.invalidState("sequence list contained 0 valid image frames: \(listURL.path)")
            }
            return urls
        }

        if let dirURL = directoryURL {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else {
                throw SafariumError.invalidState("sequence directory missing or not a directory: \(dirURL.path)")
            }
            let entries = try FileManager.default.contentsOfDirectory(
                at: dirURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            var filtered: [URL] = []
            for u in entries where isSupportedImageFile(u) {
                if let glob = globPattern {
                    let target = glob.contains("/") ? u.path : u.lastPathComponent
                    if !matchesGlob(glob, candidate: target) { continue }
                }
                filtered.append(u)
            }
            let sorted = sortedNaturally(filtered)
            guard !sorted.isEmpty else {
                throw SafariumError.invalidState("sequence directory contained 0 valid image frames: \(dirURL.path)")
            }
            return sorted
        }

        if let glob = globPattern?.trimmingCharacters(in: .whitespacesAndNewlines), !glob.isEmpty {
            var gt = glob_t()
            let rc = glob.withCString { cPat in
                Darwin.glob(cPat, GLOB_BRACE | GLOB_TILDE, nil, &gt)
            }
            defer { Darwin.globfree(&gt) }
            guard rc == 0 else {
                throw SafariumError.invalidState("sequence glob matched 0 valid image frames: \(glob)")
            }
            var matched: [URL] = []
            for i in 0..<Int(gt.gl_matchc) {
                if let ptr = gt.gl_pathv[i] {
                    let u = URL(fileURLWithPath: String(cString: ptr))
                    if isSupportedImageFile(u) {
                        matched.append(u)
                    }
                }
            }
            let sorted = sortedNaturally(matched)
            guard !sorted.isEmpty else {
                throw SafariumError.invalidState("sequence glob matched 0 valid image frames: \(glob)")
            }
            return sorted
        }

        throw SafariumError.invalidState("sequence discovery found 0 valid image frames")
    }

    private static func probeImageDimensions(at url: URL) throws -> (width: Int, height: Int, orientation: UInt32) {
        try autoreleasepool {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw SafariumError.invalidState("cannot open image via ImageIO: \(url.path)")
            }
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let rawW: Int
            let rawH: Int
            if let w = props?[kCGImagePropertyPixelWidth] as? Int,
               let h = props?[kCGImagePropertyPixelHeight] as? Int,
               w > 0, h > 0 {
                rawW = w
                rawH = h
            } else {
                guard let img = CGImageSourceCreateImageAtIndex(src, 0, [
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceShouldCache: false,
                ] as CFDictionary) else {
                    throw SafariumError.invalidState("cannot decode image properties: \(url.path)")
                }
                rawW = img.width
                rawH = img.height
            }
            let orient = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
            let swapsAxes = (5...8).contains(orient)
            return swapsAxes ? (rawH, rawW, orient) : (rawW, rawH, orient)
        }
    }

    private static func decodeFrameIntoPool(
        url: URL,
        targetW: Int,
        targetH: Int,
        preserveLeftTopOnOddPad: Bool,
        hasAlpha: Bool,
        pool: CVPixelBufferPool
    ) throws -> CVPixelBuffer {
        try autoreleasepool {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                throw SafariumError.invalidState("ImageIO failed to open frame: \(url.path)")
            }
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            let orientRaw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
            let opts: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: false,
            ]
            guard let rawCG = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) else {
                throw SafariumError.snapshot("ImageIO failed to decode frame: \(url.path)")
            }

            var pbOpt: CVPixelBuffer?
            let pbStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pbOpt)
            guard pbStatus == kCVReturnSuccess, let pb = pbOpt else {
                throw SafariumError.encode("sequence CVPixelBufferPoolCreatePixelBuffer failed (\(pbStatus))")
            }

            CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)

            let colorSafeCG = Snapshot.reinterpretingVideo709AsSRGB(rawCG)
            if orientRaw == 1 && colorSafeCG.width == targetW && colorSafeCG.height == targetH {
                try Snapshot(cgImage: colorSafeCG).draw(into: pb, width: targetW, height: targetH)
                return pb
            }

            guard CVPixelBufferLockBaseAddress(pb, []) == kCVReturnSuccess else {
                throw SafariumError.encode("cannot lock sequence decode CVPixelBuffer")
            }
            defer { _ = CVPixelBufferUnlockBaseAddress(pb, []) }
            guard let base = CVPixelBufferGetBaseAddress(pb) else {
                throw SafariumError.encode("missing sequence decode CVPixelBuffer base address")
            }
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            guard let ctx = CGContext(
                data: base,
                width: targetW,
                height: targetH,
                bitsPerComponent: 8,
                bytesPerRow: bpr,
                space: Snapshot.colorSpace,
                bitmapInfo: Snapshot.bitmapInfo
            ) else {
                throw SafariumError.snapshot("cannot create sequence BGRA CGContext \(targetW)x\(targetH)")
            }

            if hasAlpha {
                ctx.clear(CGRect(x: 0, y: 0, width: targetW, height: targetH))
            } else {
                ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: targetW, height: targetH))
            }

            if orientRaw != 1, let exifOrient = CGImagePropertyOrientation(rawValue: orientRaw) {
                let ci = CIImage(cgImage: colorSafeCG).oriented(exifOrient)
                let ciCtx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [
                    .workingColorSpace: Snapshot.colorSpace,
                    .outputColorSpace: Snapshot.colorSpace,
                    .cacheIntermediates: false,
                ])
                if let orientedCG = ciCtx.createCGImage(ci, from: ci.extent, format: .BGRA8, colorSpace: Snapshot.colorSpace) {
                    drawOrientedImage(orientedCG, into: ctx, targetW: targetW, targetH: targetH, preserveLeftTopOnOddPad: preserveLeftTopOnOddPad)
                    return pb
                }
            }

            drawOrientedImage(colorSafeCG, into: ctx, targetW: targetW, targetH: targetH, preserveLeftTopOnOddPad: preserveLeftTopOnOddPad)
            return pb
        }
    }

    private static func drawOrientedImage(
        _ img: CGImage,
        into ctx: CGContext,
        targetW: Int,
        targetH: Int,
        preserveLeftTopOnOddPad: Bool
    ) {
        let srcW = img.width
        let srcH = img.height
        if preserveLeftTopOnOddPad && srcW <= targetW && srcH <= targetH && (targetW - srcW) <= 1 && (targetH - srcH) <= 1 {
            // CoreGraphics origin is bottom-left: y = targetH - srcH puts image flush with top-left.
            ctx.draw(img, in: CGRect(x: 0, y: targetH - srcH, width: srcW, height: srcH))
        } else {
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        }
    }

    private static func appendDecodedBGRAPixelBuffer(
        _ pb: CVPixelBuffer,
        into sink: AVAssetWriterSink,
        pixelFormat: SinkPixelFormat,
        width: Int,
        height: Int,
        nv12Info: inout vImage_ARGBToYpCbCr?
    ) async throws {
        if pixelFormat == .bgra {
            try await sink.appendPixelBuffer(pb)
            return
        }
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else {
            throw SafariumError.encode("failed to lock decoded BGRA pixel buffer")
        }
        defer { _ = CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let srcBase = CVPixelBufferGetBaseAddress(pb) else {
            throw SafariumError.encode("missing decoded BGRA base address")
        }
        let srcStride = CVPixelBufferGetBytesPerRow(pb)
        switch pixelFormat {
        case .nv12Left:
            try await sink.append { dstPB in
                try SafariumAccelerate.convertRawBGRAToNV12BT709Left(
                    bgra: srcBase,
                    bgraBytesPerRow: srcStride,
                    into: dstPB,
                    width: width,
                    height: height
                )
            }
        case .nv12vImage:
            guard var info = nv12Info else {
                throw SafariumError.invalidState("missing vImage NV12 converter")
            }
            try await sink.append { dstPB in
                try SafariumAccelerate.convertBGRAToNV12BT709(
                    bgra: srcBase,
                    bgraBytesPerRow: srcStride,
                    into: dstPB,
                    width: width,
                    height: height,
                    info: &info
                )
            }
            nv12Info = info
        case .bgra:
            break
        case .p010, .p210, .p410:
            try await sink.append { dstPB in
                try AVAssetWriterSink.convertBGRATo10BitBiPlanar(
                    bgra: srcBase,
                    bgraBytesPerRow: srcStride,
                    into: dstPB,
                    width: width,
                    height: height,
                    pixelFormat: pixelFormat
                )
            }
        }
    }

    public static func run(
        config: ForgeSequenceIngestConfig,
        outputURL: URL,
        progress: SafariumProgressEmitter? = nil
    ) async throws -> ForgeSequenceIngestReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard !config.framePaths.isEmpty else {
            throw SafariumError.invalidState("sequence ingest requires at least 1 frame (received 0)")
        }
        guard config.fps > 0 else {
            throw SafariumError.invalidState("sequence ingest fps must be > 0")
        }
        if config.inlineSheetConfig != nil && config.inlineSheetOutputURL == nil {
            throw SafariumError.invalidState("inlineSheetConfig requires inlineSheetOutputURL")
        }

        var cleanPaths: [URL] = []
        cleanPaths.reserveCapacity(config.framePaths.count)
        for p in config.framePaths {
            if isSidecarOrHidden(p.lastPathComponent) {
                throw SafariumError.invalidState("AppleDouble/hidden file cannot be ingested as a frame: \(p.path)")
            }
            try SafeFilePublisher.assertRegularReadableFile(p)
            cleanPaths.append(p)
        }
        if let audioURL = config.audioURL {
            try SafeFilePublisher.assertRegularReadableFile(audioURL)
        }
        if let sheetOutURL = config.inlineSheetOutputURL {
            try SafeFilePublisher.preflight(outputURL: sheetOutURL, overwrite: config.overwrite)
        }

        let firstDim = try probeImageDimensions(at: cleanPaths[0])
        let requiresEvenW = (config.pixelFormat == .nv12Left || config.pixelFormat == .nv12vImage ||
            config.codec == .h264 || config.codec == .hevc || config.codec == .hevcAlpha || config.codec == .proRes422)
        let requiresEvenH = (config.pixelFormat == .nv12Left || config.pixelFormat == .nv12vImage ||
            config.codec == .h264 || config.codec == .hevc || config.codec == .hevcAlpha)

        let targetW: Int
        if let explicitW = config.width {
            guard explicitW > 0 else { throw SafariumError.invalidState("sequence width must be > 0") }
            if requiresEvenW && explicitW % 2 != 0 {
                throw SafariumError.invalidState("\(config.codec.rawValue)/\(config.pixelFormat.rawValue) requires even width, got \(explicitW)")
            }
            targetW = explicitW
        } else {
            targetW = requiresEvenW ? ((firstDim.width + 1) & ~1) : firstDim.width
        }

        let targetH: Int
        if let explicitH = config.height {
            guard explicitH > 0 else { throw SafariumError.invalidState("sequence height must be > 0") }
            if requiresEvenH && explicitH % 2 != 0 {
                throw SafariumError.invalidState("\(config.codec.rawValue)/\(config.pixelFormat.rawValue) requires even height, got \(explicitH)")
            }
            targetH = explicitH
        } else {
            targetH = requiresEvenH ? ((firstDim.height + 1) & ~1) : firstDim.height
        }

        guard targetW > 0, targetH > 0, targetW <= 8192, targetH <= 8192, targetW * targetH <= 33_554_432 else {
            throw SafariumError.encode("sequence dimensions must be <= 8192 per side and 33554432 pixels, got \(targetW)x\(targetH)")
        }

        let preserveOddPad = (config.width == nil && config.height == nil) &&
            (targetW != firstDim.width || targetH != firstDim.height)
        let slots = max(1, min(4, config.decodeAheadSlots))
        let total = cleanPaths.count

        let stage = try APFSAutoStage.makeSession(for: outputURL, overwrite: config.overwrite)
        defer { stage.cleanup() }

        let poolAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: slots + 1,
        ]
        let pbAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: targetW,
            kCVPixelBufferHeightKey as String: targetH,
            kCVPixelBufferBytesPerRowAlignmentKey as String: 64,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var poolOpt: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttrs as CFDictionary, pbAttrs as CFDictionary, &poolOpt)
        guard poolStatus == kCVReturnSuccess, let decodePool = poolOpt else {
            throw SafariumError.encode("CVPixelBufferPoolCreate failed (\(poolStatus))")
        }
        let sendablePool = SendablePixelBufferPool(raw: decodePool)

        let stagedVideo = stage.fileURL("sequence.\(config.codec.fileExtension)")
        let profile: EncoderProfile = config.closedGOP ? .lowRamClosedGOP : .baseline
        let sink = try AVAssetWriterSink(
            url: stagedVideo,
            width: targetW,
            height: targetH,
            fps: config.fps,
            codec: config.codec,
            bitrate: config.bitrate,
            quality: config.quality,
            pixelFormat: config.pixelFormat,
            profile: profile
        )

        let sheetCollector: ForgeInlineSheetCollector?
        if config.inlineSheetOutputURL != nil {
            let sCfg = config.inlineSheetConfig ?? ForgeContactSheetConfig()
            let collector = try ForgeInlineSheetCollector(totalFrames: total, fps: config.fps, config: sCfg)
            collector.setInputLabel(cleanPaths[0].deletingLastPathComponent().path)
            sheetCollector = collector
        } else {
            sheetCollector = nil
        }

        var nv12Info: vImage_ARGBToYpCbCr? = (config.pixelFormat == .nv12vImage) ? try AVAssetWriterSink.makeNV12Info() : nil
        var peakRSSMB = SafariumRuntimeTelemetry.currentFootprintMB()
        progress?.emitStart(stage: "sequence_ingest", total: total)

        let hasAlpha = config.codec.hasAlpha
        do {
            try await withThrowingTaskGroup(of: (Int, SendablePixelBuffer).self) { group in
                var nextToSubmit = 0
                var nextToEncode = 0
                var readyBuffers: [Int: SendablePixelBuffer] = [:]
                readyBuffers.reserveCapacity(slots)

                func replenishWindow() {
                    while nextToSubmit < total && (nextToSubmit - nextToEncode) < slots {
                        let idx = nextToSubmit
                        let frameURL = cleanPaths[idx]
                        group.addTask {
                            let pb = try decodeFrameIntoPool(
                                url: frameURL,
                                targetW: targetW,
                                targetH: targetH,
                                preserveLeftTopOnOddPad: preserveOddPad,
                                hasAlpha: hasAlpha,
                                pool: sendablePool.raw
                            )
                            return (idx, SendablePixelBuffer(raw: pb))
                        }
                        nextToSubmit += 1
                    }
                }

                replenishWindow()

                while nextToEncode < total {
                    guard let (doneIdx, doneBuf) = try await group.next() else {
                        throw SafariumError.encode("sequence decode task group ended prematurely at frame \(nextToEncode)/\(total)")
                    }
                    readyBuffers[doneIdx] = doneBuf

                    while let ready = readyBuffers.removeValue(forKey: nextToEncode) {
                        let pb = ready.raw
                        try await appendDecodedBGRAPixelBuffer(
                            pb,
                            into: sink,
                            pixelFormat: config.pixelFormat,
                            width: targetW,
                            height: targetH,
                            nv12Info: &nv12Info
                        )

                        if let collector = sheetCollector {
                            try collector.ingest(frameIndex: nextToEncode, pixelBuffer: pb)
                        }

                        nextToEncode += 1
                        progress?.emitFrame(stage: "sequence_ingest", completed: nextToEncode, total: total)

                        if nextToEncode % 30 == 0 || nextToEncode == total {
                            peakRSSMB = max(peakRSSMB, SafariumRuntimeTelemetry.currentFootprintMB())
                        }
                        if nextToEncode % 60 == 0 {
                            sink.flushPool()
                            CVPixelBufferPoolFlush(decodePool, .excessBuffers)
                        }
                    }

                    replenishWindow()
                }
            }

            try await sink.finish()
        } catch {
            sink.cancel()
            throw error
        }

        var finalStaged = stagedVideo
        if let audioURL = config.audioURL {
            let muxed = stage.fileURL("sequence_muxed.\(config.codec.fileExtension)")
            _ = try await LosslessSoundtrackMux.mux(
                videoURL: stagedVideo,
                wavURL: audioURL,
                outputURL: muxed,
                overwrite: true
            )
            finalStaged = muxed
        }
        try stage.commit(stagedFile: finalStaged, overwrite: config.overwrite)

        var sheetReport: ForgeContactSheetReport?
        if let collector = sheetCollector, let sheetOutURL = config.inlineSheetOutputURL {
            sheetReport = try collector.finalize(to: sheetOutURL, overwrite: config.overwrite)
        }

        peakRSSMB = max(peakRSSMB, SafariumRuntimeTelemetry.currentFootprintMB())
        let outBytes = ((try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        progress?.emitComplete(stage: "sequence_ingest", total: total)

        return ForgeSequenceIngestReport(
            outputPath: outputURL.path,
            width: targetW,
            height: targetH,
            fps: config.fps,
            frames: total,
            codec: config.codec.rawValue,
            bytes: outBytes,
            wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6,
            sheetPath: sheetReport?.outputPath,
            sheetCols: sheetReport?.cols,
            sheetRows: sheetReport?.rows,
            peakRSSMB: (peakRSSMB * 100.0).rounded() / 100.0
        )
    }
}
