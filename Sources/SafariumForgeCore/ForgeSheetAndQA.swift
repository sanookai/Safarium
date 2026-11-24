import Accelerate
@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import SafariumContainers
import SafariumCore
import UniformTypeIdentifiers

// MARK: - Contact Sheet & Comparison Strips

public enum ForgeSheetSampling: Sendable, Equatable {
    case uniformCount(Int?)
    case everyFrames(Int)
    case everySeconds(Double)
    case timestamps([Double])
}

public struct ForgeContactSheetConfig: Sendable, Equatable {
    public var cols: Int
    public var rows: Int
    public var tileWidth: Int
    public var tileHeight: Int?
    public var padding: Int
    public var bgColorHex: String
    public var sampling: ForgeSheetSampling
    public var format: String
    public var quality: Double

    public init(
        cols: Int = 6,
        rows: Int = 4,
        tileWidth: Int = 270,
        tileHeight: Int? = nil,
        padding: Int = 8,
        bgColorHex: String = "#0F172A",
        sampling: ForgeSheetSampling = .uniformCount(nil),
        format: String = "jpg",
        quality: Double = 0.88
    ) {
        self.cols = cols
        self.rows = rows
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.padding = padding
        self.bgColorHex = bgColorHex
        self.sampling = sampling
        self.format = format
        self.quality = quality
    }
}

public struct ForgeContactSheetTile: Codable, Sendable {
    public let tileIndex: Int
    public let row: Int
    public let col: Int
    public let frameIndex: Int
    public let ptsSeconds: Double
    public let ptsRational: String
    public let tileX: Int
    public let tileY: Int
    public let tileWidth: Int
    public let tileHeight: Int
}

public struct ForgeContactSheetReport: Codable, Sendable {
    public let inputPath: String
    public let outputPath: String
    public let manifestPath: String?
    public let cols: Int
    public let rows: Int
    public let tileCount: Int
    public let width: Int
    public let height: Int
    public let padding: Int
    public let bytes: Int
    public let tiles: [ForgeContactSheetTile]
    public let wallMs: Double
    public let isInlineZeroRedecode: Bool?

    public init(
        inputPath: String,
        outputPath: String,
        manifestPath: String?,
        cols: Int,
        rows: Int,
        tileCount: Int,
        width: Int,
        height: Int,
        padding: Int,
        bytes: Int,
        tiles: [ForgeContactSheetTile],
        wallMs: Double,
        isInlineZeroRedecode: Bool? = nil
    ) {
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.manifestPath = manifestPath
        self.cols = cols
        self.rows = rows
        self.tileCount = tileCount
        self.width = width
        self.height = height
        self.padding = padding
        self.bytes = bytes
        self.tiles = tiles
        self.wallMs = wallMs
        self.isInlineZeroRedecode = isInlineZeroRedecode
    }
}

public struct ForgeQAReport: Codable, Sendable {
    public let nativeQA: NativeQAReport
    public let pq: SafariumPQReport?
    public let contactSheet: ForgeContactSheetReport?
    public let passed: Bool
    public let failureReasons: [String]
}

// MARK: - Pipe Encode Config & Report

public enum ForgeRawPixelFormat: String, Codable, Sendable {
    case rgb24
    case bgr24
    case rgba
    case bgra

    public var bytesPerPixel: Int {
        switch self {
        case .rgb24, .bgr24: return 3
        case .rgba, .bgra: return 4
        }
    }

    public static func parse(_ s: String) throws -> ForgeRawPixelFormat {
        switch s.lowercased() {
        case "rgb24", "rgb": return .rgb24
        case "bgr24", "bgr": return .bgr24
        case "rgba", "rgba8": return .rgba
        case "bgra", "bgra8", "32bgra": return .bgra
        default: throw SafariumError.invalidState("unsupported raw pixel format '\(s)' (expected rgb24|bgr24|rgba|bgra)")
        }
    }
}

public struct ForgePipeEncodeConfig: Sendable {
    public var width: Int
    public var height: Int
    public var fps: Int
    public var inputPixelFormat: ForgeRawPixelFormat
    public var primaryCodec: VideoCodec
    public var primaryBitrate: Int?
    public var primaryQuality: Double?
    public var primaryPixelFormat: SinkPixelFormat
    public var secondaryOutputURL: URL?
    public var secondaryCodec: VideoCodec?
    public var secondaryBitrate: Int?
    public var secondaryQuality: Double?
    public var secondaryBackgroundHex: String
    public var audioURL: URL?
    public var subtitlesURL: URL?
    public var subtitleLang: String
    public var closedGOP: Bool
    public var maxFrames: Int?
    public var vflip: Bool
    public var overwrite: Bool
    public var primaryAudioCodec: String
    public var inlineSheetConfig: ForgeContactSheetConfig?
    public var inlineSheetOutputURL: URL?

    public init(
        width: Int,
        height: Int,
        fps: Int = 30,
        inputPixelFormat: ForgeRawPixelFormat = .bgra,
        primaryCodec: VideoCodec = .h264,
        primaryBitrate: Int? = 8_000_000,
        primaryQuality: Double? = nil,
        primaryPixelFormat: SinkPixelFormat? = nil,
        secondaryOutputURL: URL? = nil,
        secondaryCodec: VideoCodec? = nil,
        secondaryBitrate: Int? = 8_000_000,
        secondaryQuality: Double? = nil,
        secondaryBackgroundHex: String = "#000000",
        audioURL: URL? = nil,
        subtitlesURL: URL? = nil,
        subtitleLang: String = "tha",
        closedGOP: Bool = true,
        maxFrames: Int? = nil,
        vflip: Bool = false,
        overwrite: Bool = false,
        primaryAudioCodec: String = "aac",
        inlineSheetConfig: ForgeContactSheetConfig? = nil,
        inlineSheetOutputURL: URL? = nil
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.inputPixelFormat = inputPixelFormat
        self.primaryCodec = primaryCodec
        self.primaryBitrate = primaryBitrate
        self.primaryQuality = primaryQuality
        self.primaryPixelFormat = primaryPixelFormat ?? (primaryCodec.hasAlpha ? .bgra : .nv12Left)
        self.secondaryOutputURL = secondaryOutputURL
        self.secondaryCodec = secondaryCodec ?? (secondaryOutputURL != nil ? .h264 : nil)
        self.secondaryBitrate = secondaryBitrate
        self.secondaryQuality = secondaryQuality
        self.secondaryBackgroundHex = secondaryBackgroundHex
        self.audioURL = audioURL
        self.subtitlesURL = subtitlesURL
        self.subtitleLang = subtitleLang
        self.closedGOP = closedGOP
        self.maxFrames = maxFrames
        self.vflip = vflip
        self.overwrite = overwrite
        self.primaryAudioCodec = primaryAudioCodec
        self.inlineSheetConfig = inlineSheetConfig
        self.inlineSheetOutputURL = inlineSheetOutputURL
    }
}

public struct ForgePipeEncodeReport: Codable, Sendable {
    public let primaryOutputPath: String
    public let secondaryOutputPath: String?
    public let width: Int
    public let height: Int
    public let fps: Int
    public let frames: Int
    public let primaryCodec: String
    public let secondaryCodec: String?
    public let primaryBytes: Int64
    public let secondaryBytes: Int64?
    public let wallMs: Double
    public let inlineSheetReport: ForgeContactSheetReport?

    public init(
        primaryOutputPath: String,
        secondaryOutputPath: String?,
        width: Int,
        height: Int,
        fps: Int,
        frames: Int,
        primaryCodec: String,
        secondaryCodec: String?,
        primaryBytes: Int64,
        secondaryBytes: Int64?,
        wallMs: Double,
        inlineSheetReport: ForgeContactSheetReport? = nil
    ) {
        self.primaryOutputPath = primaryOutputPath
        self.secondaryOutputPath = secondaryOutputPath
        self.width = width
        self.height = height
        self.fps = fps
        self.frames = frames
        self.primaryCodec = primaryCodec
        self.secondaryCodec = secondaryCodec
        self.primaryBytes = primaryBytes
        self.secondaryBytes = secondaryBytes
        self.wallMs = wallMs
        self.inlineSheetReport = inlineSheetReport
    }
}

// MARK: - ForgeSheetAndQA Implementation

public enum ForgeSheetAndQA {
    fileprivate static func writeSheetImage(
        _ img: CGImage,
        format: String,
        quality: Double,
        stage: APFSStageSession,
        prefix: String,
        overwrite: Bool
    ) throws -> Int {
        let fmt = format.lowercased()
        if fmt == "webp" {
            let stagedWebP = stage.fileURL("\(prefix).webp")
            let webpRep = try WebPAVIFEncoder.writeLosslessWebP(images: [img], to: stagedWebP, loopCount: 0, overwrite: true)
            try stage.commit(stagedFile: stagedWebP, overwrite: overwrite)
            return webpRep.bytes
        }
        let encoded = try encodeCGImage(img, format: fmt, quality: quality)
        let staged = stage.fileURL("\(prefix).\(fmt)")
        try encoded.write(to: staged)
        try stage.commit(stagedFile: staged, overwrite: overwrite)
        return encoded.count
    }

    public static func encodeCGImage(_ img: CGImage, format: String, quality: Double) throws -> Data {
        let fmt = format.lowercased()
        let utType: UTType
        switch fmt {
        case "jpg", "jpeg": utType = .jpeg
        case "png": utType = .png
        case "heic": utType = .heic
        case "avif":
            guard quality < 1.0 else {
                throw SafariumError.invalidState("AVIF quality=1.0 lossless is unsupported by macOS ImageIO; use quality < 1.0 or PNG/WebP")
            }
            utType = UTType("public.avif") ?? .heic
        default:
            throw SafariumError.invalidState("unsupported sheet image format '\(format)' (expected jpg|png|heic|avif)")
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, utType.identifier as CFString, 1, nil) else {
            throw SafariumError.encode("CGImageDestinationCreateWithData failed for \(fmt)")
        }
        var props: [CFString: Any] = [:]
        if utType != .png {
            props[kCGImageDestinationLossyCompressionQuality] = max(0.05, min(0.99, quality))
        }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw SafariumError.encode("CGImageDestinationFinalize failed for \(fmt)")
        }
        return data as Data
    }

    public static func generateContactSheet(
        inputURL: URL,
        outputURL: URL,
        manifestURL: URL? = nil,
        config: ForgeContactSheetConfig = ForgeContactSheetConfig(),
        overwrite: Bool = false
    ) async throws -> ForgeContactSheetReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(inputURL)
        guard config.cols >= 1, config.rows >= 1, config.tileWidth >= 16, config.padding >= 0 else {
            throw SafariumError.invalidState("invalid contact sheet grid or padding")
        }
        let stage = try APFSAutoStage.makeSession(for: outputURL, overwrite: overwrite)
        defer { stage.cleanup() }
        if let manifestURL {
            try SafeFilePublisher.preflight(outputURL: manifestURL, overwrite: overwrite)
        }

        let asset = AVURLAsset(url: inputURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let vt = try await asset.loadTracks(withMediaType: .video).first else {
            throw SafariumError.invalidState("contact sheet input has no video track: \(inputURL.lastPathComponent)")
        }
        let natSize = try await vt.load(.naturalSize)
        let prefTx = try await vt.load(.preferredTransform)
        let dispRect = CGRect(origin: .zero, size: natSize).applying(prefTx)
        let dispW = max(1.0, abs(Double(dispRect.width)))
        let dispH = max(1.0, abs(Double(dispRect.height)))
        let nomFPS = Double(try await vt.load(.nominalFrameRate))
        let effFPS = nomFPS > 0 ? nomFPS : 30.0
        let durSec = max(0.001, CMTimeGetSeconds(try await asset.load(.duration)))
        let maxSlots = config.cols * config.rows

        let tileW = config.tileWidth
        let tileH = max(16, (config.tileHeight ?? Int((Double(tileW) * dispH / dispW).rounded())) & ~1)
        let pad = config.padding
        let sheetW = config.cols * tileW + (config.cols + 1) * pad
        let sheetH = config.rows * tileH + (config.rows + 1) * pad
        guard sheetW <= 16384, sheetH <= 16384 else {
            throw SafariumError.invalidState("contact sheet dimensions \(sheetW)x\(sheetH) exceed 16384 limit")
        }

        let bgRGBA = ForgeColorHex.parseRGBA(config.bgColorHex)
        guard let ctx = CGContext(
            data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: sheetW * 4,
            space: Snapshot.colorSpace, bitmapInfo: Snapshot.bitmapInfo
        ) else {
            throw SafariumError.encode("failed to allocate \(sheetW)x\(sheetH) contact sheet CGContext")
        }
        ctx.setFillColor(CGColor(srgbRed: CGFloat(bgRGBA.x), green: CGFloat(bgRGBA.y), blue: CGFloat(bgRGBA.z), alpha: CGFloat(bgRGBA.w)))
        ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))

        let ciCtx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])
        var tiles: [ForgeContactSheetTile] = []

        func drawTile(cg: CGImage, slotIdx: Int, frameIdx: Int, pts: CMTime) {
            let row = slotIdx / config.cols
            let col = slotIdx % config.cols
            let tileX = pad + col * (tileW + pad)
            let tileYTop = pad + row * (tileH + pad)
            let cgY = sheetH - tileYTop - tileH
            ctx.draw(cg, in: CGRect(x: tileX, y: cgY, width: tileW, height: tileH))
            tiles.append(ForgeContactSheetTile(
                tileIndex: slotIdx,
                row: row,
                col: col,
                frameIndex: frameIdx,
                ptsSeconds: CMTimeGetSeconds(pts),
                ptsRational: PacketProbe.rational(pts),
                tileX: tileX,
                tileY: tileYTop,
                tileWidth: tileW,
                tileHeight: tileH
            ))
        }

        switch config.sampling {
        case .timestamps(let times):
            guard !times.isEmpty else {
                throw SafariumError.invalidState("contact sheet timestamps list cannot be empty")
            }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            for (slot, reqT) in times.prefix(maxSlots).enumerated() {
                let clamped = max(0.0, min(durSec - 0.001, reqT))
                let target = CMTime(seconds: clamped, preferredTimescale: 600_000)
                let (cg, actual) = try await gen.image(at: target)
                let fIdx = max(0, Int((CMTimeGetSeconds(actual) * effFPS).rounded()))
                drawTile(cg: cg, slotIdx: slot, frameIdx: fIdx, pts: actual)
            }

        case .everyFrames, .everySeconds, .uniformCount:
            let reader = try AVAssetReader(asset: asset)
            let out = AVAssetReaderTrackOutput(track: vt, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            out.alwaysCopiesSampleData = false
            reader.add(out)
            guard reader.startReading() else {
                throw SafariumError.encode("contact sheet reader failed: \(reader.error?.localizedDescription ?? "?")")
            }
            defer { if reader.status == .reading { reader.cancelReading() } }

            let targetTimes: [Double]?
            let frameStride: Int?
            switch config.sampling {
            case .everyFrames(let step):
                frameStride = max(1, step)
                targetTimes = nil
            case .everySeconds(let stepSec):
                frameStride = nil
                let step = max(0.01, stepSec)
                var arr: [Double] = []
                var t = 0.0
                while t < durSec && arr.count < maxSlots {
                    arr.append(t)
                    t += step
                }
                if arr.isEmpty { arr.append(0.0) }
                targetTimes = arr
            case .uniformCount(let reqCount):
                frameStride = nil
                let cnt = max(1, min(maxSlots, reqCount ?? maxSlots))
                targetTimes = (0..<cnt).map { slot in
                    (Double(slot) + 0.5) * durSec / Double(cnt)
                }
            case .timestamps:
                frameStride = nil; targetTimes = nil
            }

            var frameIdx = 0
            var nextSlot = 0
            var lastCG: CGImage?
            var lastPTS = CMTime.zero
            var lastFrameIdx = 0

            while nextSlot < maxSlots {
                guard let sb = autoreleasepool(invoking: { out.copyNextSampleBuffer() }) else { break }
                if sb.numSamples == 0 { continue }
                guard let pb = sb.imageBuffer else { continue }
                let pts = sb.presentationTimeStamp
                let ptsSec = CMTimeGetSeconds(pts)

                func rasterTileCG() -> CGImage? {
                    autoreleasepool {
                        let ci = SafariumSequentialVideoReader.orientedCIImage(from: pb, transform: prefTx)
                        let sx = CGFloat(tileW) / max(1.0, ci.extent.width)
                        let sy = CGFloat(tileH) / max(1.0, ci.extent.height)
                        let scaled = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                        return ciCtx.createCGImage(
                            scaled,
                            from: CGRect(x: scaled.extent.origin.x, y: scaled.extent.origin.y, width: CGFloat(tileW), height: CGFloat(tileH)),
                            format: .BGRA8,
                            colorSpace: Snapshot.colorSpace
                        )
                    }
                }

                if let strideN = frameStride {
                    if frameIdx % strideN == 0 {
                        if let cg = rasterTileCG() {
                            drawTile(cg: cg, slotIdx: nextSlot, frameIdx: frameIdx, pts: pts)
                            nextSlot += 1
                        }
                    }
                } else if let targets = targetTimes {
                    if nextSlot < targets.count && (ptsSec + 1e-6 >= targets[nextSlot] || frameIdx == 0) {
                        if let cg = rasterTileCG() {
                            lastCG = cg; lastPTS = pts; lastFrameIdx = frameIdx
                        }
                    }
                    while nextSlot < targets.count && nextSlot < maxSlots && ptsSec + 1e-6 >= targets[nextSlot], let cg = lastCG {
                        drawTile(cg: cg, slotIdx: nextSlot, frameIdx: lastFrameIdx, pts: lastPTS)
                        nextSlot += 1
                    }
                }
                frameIdx += 1
            }

            if let targets = targetTimes, let cg = lastCG {
                while nextSlot < targets.count && nextSlot < maxSlots {
                    drawTile(cg: cg, slotIdx: nextSlot, frameIdx: lastFrameIdx, pts: lastPTS)
                    nextSlot += 1
                }
            }
        }

        guard !tiles.isEmpty, let sheetImg = ctx.makeImage() else {
            throw SafariumError.invalidState("contact sheet produced 0 tiles from \(inputURL.lastPathComponent)")
        }

        let ext = outputURL.pathExtension.lowercased()
        let chosenFmt = ext.isEmpty ? config.format : ext
        let sheetBytes = try writeSheetImage(sheetImg, format: chosenFmt, quality: config.quality, stage: stage, prefix: "sheet", overwrite: overwrite)

        let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let report = ForgeContactSheetReport(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            manifestPath: manifestURL?.path,
            cols: config.cols,
            rows: config.rows,
            tileCount: tiles.count,
            width: sheetW,
            height: sheetH,
            padding: pad,
            bytes: sheetBytes,
            tiles: tiles,
            wallMs: wallMs,
            isInlineZeroRedecode: false
        )

        if let manifestURL {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let mData = try encoder.encode(report)
            let stagedMan = stage.fileURL("manifest.json")
            try mData.write(to: stagedMan)
            try stage.commit(stagedFile: stagedMan, to: manifestURL, overwrite: overwrite)
        }
        return report
    }

    public static func makeComparisonStrip(
        referenceURL: URL,
        candidateURL: URL,
        outputURL: URL,
        samples: Int = 4,
        vertical: Bool = false,
        tileWidth: Int = 360,
        padding: Int = 8,
        bgColorHex: String = "#0F172A",
        overwrite: Bool = false
    ) async throws -> ForgeContactSheetReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(referenceURL)
        try SafeFilePublisher.assertRegularReadableFile(candidateURL)
        let stage = try APFSAutoStage.makeSession(for: outputURL, overwrite: overwrite)
        defer { stage.cleanup() }

        let rReader = try await SafariumSequentialVideoReader(url: referenceURL, loop: false, pixelFormat: kCVPixelFormatType_32BGRA)
        let cReader = try await SafariumSequentialVideoReader(url: candidateURL, loop: false, pixelFormat: kCVPixelFormatType_32BGRA)
        defer { rReader.close(); cReader.close() }

        let count = max(1, min(16, samples))
        let dur = min(rReader.durationSeconds, cReader.durationSeconds)
        let tileH = max(16, Int((Double(tileWidth) * Double(rReader.height) / Double(max(1, rReader.width))).rounded()) & ~1)
        let cols = vertical ? 2 : count
        let rows = vertical ? count : 2
        let sheetW = cols * tileWidth + (cols + 1) * padding
        let sheetH = rows * tileH + (rows + 1) * padding

        let bgRGBA = ForgeColorHex.parseRGBA(bgColorHex)
        guard let ctx = CGContext(
            data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: sheetW * 4,
            space: Snapshot.colorSpace, bitmapInfo: Snapshot.bitmapInfo
        ) else {
            throw SafariumError.encode("comparison strip CGContext failed")
        }
        ctx.setFillColor(CGColor(srgbRed: CGFloat(bgRGBA.x), green: CGFloat(bgRGBA.y), blue: CGFloat(bgRGBA.z), alpha: CGFloat(bgRGBA.w)))
        ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))

        let ciCtx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])
        var tiles: [ForgeContactSheetTile] = []

        for i in 0..<count {
            let t = (Double(i) + 0.5) * dur / Double(count)
            guard let rPB = try rReader.pixelBuffer(at: t),
                  let cPB = try cReader.pixelBuffer(at: t) else {
                throw SafariumError.snapshot("comparison strip missing frame at t=\(t)s")
            }
            let rCI = rReader.orientedCIImage(from: rPB)
            let cCI = cReader.orientedCIImage(from: cPB)
            guard let rCG = ciCtx.createCGImage(rCI, from: rCI.extent, format: .BGRA8, colorSpace: Snapshot.colorSpace),
                  let cCG = ciCtx.createCGImage(cCI, from: cCI.extent, format: .BGRA8, colorSpace: Snapshot.colorSpace) else {
                throw SafariumError.snapshot("comparison strip render failed")
            }

            let pairs: [(CGImage, Int, Int)] = vertical
                ? [(rCG, i, 0), (cCG, i, 1)]
                : [(rCG, 0, i), (cCG, 1, i)]
            for (img, row, col) in pairs {
                let tx = padding + col * (tileWidth + padding)
                let tyTop = padding + row * (tileH + padding)
                let cgY = sheetH - tyTop - tileH
                ctx.draw(img, in: CGRect(x: tx, y: cgY, width: tileWidth, height: tileH))
                let pts = CMTime(seconds: t, preferredTimescale: 600_000)
                tiles.append(ForgeContactSheetTile(
                    tileIndex: tiles.count,
                    row: row,
                    col: col,
                    frameIndex: Int((t * rReader.nominalFPS).rounded()),
                    ptsSeconds: t,
                    ptsRational: PacketProbe.rational(pts),
                    tileX: tx,
                    tileY: tyTop,
                    tileWidth: tileWidth,
                    tileHeight: tileH
                ))
            }
        }

        guard let outImg = ctx.makeImage() else {
            throw SafariumError.encode("comparison strip makeImage failed")
        }
        let ext = outputURL.pathExtension.lowercased()
        let fmt = ext.isEmpty ? "jpg" : ext
        let bytesWritten = try writeSheetImage(outImg, format: fmt, quality: 0.90, stage: stage, prefix: "compare", overwrite: overwrite)

        return ForgeContactSheetReport(
            inputPath: "\(referenceURL.path) vs \(candidateURL.path)",
            outputPath: outputURL.path,
            manifestPath: nil,
            cols: cols,
            rows: rows,
            tileCount: tiles.count,
            width: sheetW,
            height: sheetH,
            padding: padding,
            bytes: bytesWritten,
            tiles: tiles,
            wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6,
            isInlineZeroRedecode: false
        )
    }

    public static func runQA(
        inputURL: URL,
        referenceURL: URL? = nil,
        contactSheetURL: URL? = nil,
        sheetConfig: ForgeContactSheetConfig? = nil,
        sceneThreshold: Double = 0.20,
        silenceThresholdDB: Double = -50.0,
        checkThaiOCR: Bool = false,
        minPQScore: Double = 85.0,
        maxDeltaE00P95: Double = 2.0,
        overwrite: Bool = false
    ) async throws -> ForgeQAReport {
        let native = try await NativeQAAnalyzer.analyze(
            url: inputURL,
            contactSheetURL: (sheetConfig == nil ? contactSheetURL : nil),
            overwrite: overwrite,
            sceneThreshold: sceneThreshold,
            silenceThresholdDB: silenceThresholdDB
        )

        var customSheet: ForgeContactSheetReport?
        if let sheetURL = contactSheetURL, let cfg = sheetConfig {
            customSheet = try await generateContactSheet(inputURL: inputURL, outputURL: sheetURL, config: cfg, overwrite: overwrite)
        }

        var pqRep: SafariumPQReport?
        if let refURL = referenceURL {
            pqRep = try await SafariumPQ.compareVideos(
                referenceURL: refURL,
                candidateURL: inputURL,
                maxSamples: 12,
                checkThaiOCR: checkThaiOCR,
                minScore: minPQScore,
                maxDeltaE00P95: maxDeltaE00P95
            )
        }

        var failures: [String] = []
        if !native.blackEvents.isEmpty { failures.append("blackdetect(\(native.blackEvents.count))") }
        if !native.freezeEvents.isEmpty { failures.append("freezedetect(\(native.freezeEvents.count))") }
        if !native.silenceEvents.isEmpty { failures.append("silencedetect(\(native.silenceEvents.count))") }
        if let pq = pqRep, !pq.passed {
            failures.append(contentsOf: pq.notes)
        }

        return ForgeQAReport(
            nativeQA: native,
            pq: pqRep,
            contactSheet: customSheet,
            passed: failures.isEmpty,
            failureReasons: failures
        )
    }

    // MARK: - Raw Binary Pipe Encode (Single & Dual ProRes 4444 + H.264 Tee)

    public static func pipeEncode(
        from inputHandle: FileHandle,
        primaryOutputURL: URL,
        config: ForgePipeEncodeConfig
    ) async throws -> ForgePipeEncodeReport {
        try await pipeEncodeChunkSource(
            nextFrameData: { frameBytes in
                var collected = Data()
                collected.reserveCapacity(frameBytes)
                while collected.count < frameBytes {
                    let chunk = try inputHandle.read(upToCount: frameBytes - collected.count) ?? Data()
                    if chunk.isEmpty { break }
                    collected.append(chunk)
                }
                if collected.isEmpty { return nil }
                guard collected.count == frameBytes else {
                    throw SafariumError.encode("pipe-encode truncated frame: got \(collected.count)/\(frameBytes) bytes")
                }
                return collected
            },
            primaryOutputURL: primaryOutputURL,
            config: config
        )
    }

    public static func convertRawPointerToBGRA(
        srcPtr: UnsafeRawPointer,
        byteCount: Int,
        format: ForgeRawPixelFormat,
        width w: Int,
        height h: Int,
        destination dstPtr: UnsafeMutableRawPointer,
        dstStride: Int,
        vflip: Bool = false
    ) throws {
        let frameByteCount = w * h * format.bytesPerPixel
        guard byteCount >= frameByteCount else {
            throw SafariumError.encode("raw frame expected \(frameByteCount) bytes, got \(byteCount)")
        }
        let mutSrc = UnsafeMutableRawPointer(mutating: srcPtr)
        switch format {
        case .bgra:
            let rowBytes = w * 4
            if !vflip && dstStride == rowBytes {
                memcpy(dstPtr, mutSrc, frameByteCount)
            } else {
                for y in 0..<h {
                    let srcRow = vflip ? (h - 1 - y) : y
                    memcpy(dstPtr.advanced(by: y * dstStride), mutSrc.advanced(by: srcRow * rowBytes), rowBytes)
                }
            }
        case .rgb24:
            var sBuf = vImage_Buffer(data: mutSrc, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 3)
            var dBuf = vImage_Buffer(data: dstPtr, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: dstStride)
            let err = vImageConvert_RGB888toBGRA8888(&sBuf, nil, 255, &dBuf, false, vImage_Flags(kvImageNoFlags))
            guard err == kvImageNoError else { throw SafariumError.encode("vImage rgb24->bgra failed (\(err))") }
        case .bgr24:
            var sBuf = vImage_Buffer(data: mutSrc, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 3)
            var dBuf = vImage_Buffer(data: dstPtr, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: dstStride)
            let err = vImageConvert_RGB888toRGBA8888(&sBuf, nil, 255, &dBuf, false, vImage_Flags(kvImageNoFlags))
            guard err == kvImageNoError else { throw SafariumError.encode("vImage bgr24->bgra failed (\(err))") }
        case .rgba:
            var sBuf = vImage_Buffer(data: mutSrc, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
            var dBuf = vImage_Buffer(data: dstPtr, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: dstStride)
            var map: [UInt8] = [2, 1, 0, 3]
            let e1 = vImagePermuteChannels_ARGB8888(&sBuf, &dBuf, &map, vImage_Flags(kvImageNoFlags))
            guard e1 == kvImageNoError else { throw SafariumError.encode("vImage permute rgba->bgra failed (\(e1))") }
            let e2 = vImagePremultiplyData_RGBA8888(&dBuf, &dBuf, vImage_Flags(kvImageNoFlags))
            guard e2 == kvImageNoError else { throw SafariumError.encode("vImage premultiply failed (\(e2))") }
        }
        if vflip && format != .bgra && h > 1 {
            let rowBytes = w * 4
            var tmpRow = [UInt8](repeating: 0, count: rowBytes)
            tmpRow.withUnsafeMutableBytes { tmpRaw in
                let tmpBase = tmpRaw.baseAddress!
                for y in 0..<(h / 2) {
                    let topPtr = dstPtr.advanced(by: y * dstStride)
                    let botPtr = dstPtr.advanced(by: (h - 1 - y) * dstStride)
                    memcpy(tmpBase, topPtr, rowBytes)
                    memcpy(topPtr, botPtr, rowBytes)
                    memcpy(botPtr, tmpBase, rowBytes)
                }
            }
        }
    }

    public static func convertRawFrameToBGRA(
        _ frameData: Data,
        format: ForgeRawPixelFormat,
        width w: Int,
        height h: Int,
        destination dstPtr: UnsafeMutableRawPointer,
        dstStride: Int,
        vflip: Bool = false
    ) throws {
        try frameData.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) in
            guard let base = srcRaw.baseAddress else {
                throw SafariumError.encode("empty raw frame buffer")
            }
            try convertRawPointerToBGRA(
                srcPtr: base,
                byteCount: frameData.count,
                format: format,
                width: w,
                height: h,
                destination: dstPtr,
                dstStride: dstStride,
                vflip: vflip
            )
        }
    }

    public static func pipeEncodeChunkSource(
        nextFrameData: (Int) throws -> Data?,
        primaryOutputURL: URL,
        config: ForgePipeEncodeConfig
    ) async throws -> ForgePipeEncodeReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let session = try ForgeDualTeeSession(primaryOutputURL: primaryOutputURL, config: config)
        let bpp = config.inputPixelFormat.bytesPerPixel
        let frameByteCount = config.width * config.height * bpp
        var bgraScratch = [UInt8](repeating: 0, count: config.width * config.height * 4)
        let bgraStride = config.width * 4
        do {
            while config.maxFrames == nil || session.framesWritten < config.maxFrames! {
                guard let frameData = try nextFrameData(frameByteCount) else { break }
                try bgraScratch.withUnsafeMutableBytes { dstRaw in
                    try convertRawFrameToBGRA(
                        frameData,
                        format: config.inputPixelFormat,
                        width: config.width,
                        height: config.height,
                        destination: dstRaw.baseAddress!,
                        dstStride: bgraStride,
                        vflip: config.vflip
                    )
                }
                try await session.appendBGRAFrame(bgraScratch)
            }
            return try await session.finishAndCommit(startedUptimeNs: t0)
        } catch {
            session.cancel()
            throw error
        }
    }
    /// Muxes passthrough video with either uncompressed `pcm_s16le` (for QuickTime `.mov`) or passthrough `copy` audio
    /// (plus optional tx3g subtitles), preserving exact video packets without video re-encoding.
    package static func muxPrimaryAudioLossless(
        videoURL: URL,
        audioURL: URL,
        audioCodec: String,
        subtitlesURL: URL?,
        subtitleLang: String,
        outputURL: URL
    ) async throws {
        try SafeFilePublisher.assertRegularReadableFile(videoURL)
        try SafeFilePublisher.assertRegularReadableFile(audioURL)
        let cleanLang = try LosslessSoundtrackMux.validatedSubtitleLanguage(subtitleLang)
        let ext = outputURL.pathExtension.lowercased()
        let fileType: AVFileType = (ext == "mov") ? .mov : .mp4
        guard ext == "mov" || ext == "mp4" else {
            throw SafariumError.invalidState("primary mux output must end with .mov or .mp4: \(outputURL.lastPathComponent)")
        }

        let videoAsset = AVURLAsset(url: videoURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let vTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw SafariumError.invalidState("primary mux video has no video track: \(videoURL.lastPathComponent)")
        }
        let vFmts = try await vTrack.load(.formatDescriptions)
        guard let firstVFmt = vFmts.first else {
            throw SafariumError.invalidState("primary mux video missing format description")
        }
        let videoDims = CMVideoFormatDescriptionGetDimensions(firstVFmt)
        let vTimeScale = try await vTrack.load(.naturalTimeScale)
        let totalDur = try await videoAsset.load(.duration)
        guard totalDur.isNumeric, CMTimeCompare(totalDur, .zero) > 0 else {
            throw SafariumError.invalidState("primary mux video has non-positive duration")
        }

        var subSetup: (CMFormatDescription, [CMSampleBuffer])?
        if let subtitlesURL {
            try SafeFilePublisher.assertRegularReadableFile(subtitlesURL)
            let rawBytes = try Data(contentsOf: subtitlesURL)
            guard Int64(rawBytes.count) <= SafariumTX3G.maxSRTFileBytes,
                  let srtText = String(data: rawBytes, encoding: .utf8) else {
                throw SafariumError.encode("SRT must be valid UTF-8 and <= 16 MiB: \(subtitlesURL.path)")
            }
            let cues = try SafariumTX3G.parseSRT(text: srtText, offsetSeconds: 0.0, duration: totalDur)
            subSetup = try SafariumTX3G.buildContiguousSamples(
                cues: cues,
                duration: totalDur,
                width: Int(videoDims.width),
                height: Int(videoDims.height)
            )
        }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(url: outputURL, fileType: fileType)
        writer.movieTimeScale = vTimeScale > 0 ? vTimeScale : 600
        writer.shouldOptimizeForNetworkUse = true

        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: firstVFmt)
        vi.mediaTimeScale = writer.movieTimeScale
        vi.expectsMediaDataInRealTime = false
        guard writer.canAdd(vi) else {
            throw SafariumError.encode("writer cannot add passthrough video input for \(ext)")
        }
        writer.add(vi)

        var wavFile: AVAudioFile?
        var fileFmt: AVAudioFormat?
        var pcmInterleavedFmt: AVAudioFormat?
        var totalAudioFrames: AVAudioFramePosition = 0
        var copyAudioReader: AVAssetReader?
        var copyAudioOut: AVAssetReaderTrackOutput?

        let ai: AVAssetWriterInput
        if audioCodec == "pcm_s16le" {
            guard fileType == .mov else {
                throw SafariumError.invalidState("primaryAudioCodec 'pcm_s16le' requires .mov container, got .\(ext)")
            }
            let wf = try AVAudioFile(forReading: audioURL)
            let ff = wf.processingFormat
            let ch = Int(ff.channelCount)
            guard (1...2).contains(ch) else {
                throw SafariumError.invalidState("PCM mux supports mono or stereo audio, got \(ch) channels")
            }
            let fs = ff.sampleRate
            let reqFrames = AVAudioFramePosition((CMTimeGetSeconds(totalDur) * fs).rounded())
            totalAudioFrames = min(reqFrames, wf.length)
            guard totalAudioFrames > 0 else {
                throw SafariumError.invalidState("audio file has 0 frames: \(audioURL.lastPathComponent)")
            }
            let pcmFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fs, channels: ff.channelCount, interleaved: true)!
            let aSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Int(fs.rounded()),
                AVNumberOfChannelsKey: ch,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            guard writer.canApply(outputSettings: aSettings, forMediaType: .audio) else {
                throw SafariumError.encode("writer cannot apply pcm_s16le settings (\(fs) Hz \(ch) ch)")
            }
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings, sourceFormatHint: pcmFmt.formatDescription)
            aIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(aIn) else {
                throw SafariumError.encode("writer cannot add pcm_s16le audio input")
            }
            writer.add(aIn)
            ai = aIn
            wavFile = wf
            fileFmt = ff
            pcmInterleavedFmt = pcmFmt
        } else {
            // audioCodec == "copy"
            let aAsset = AVURLAsset(url: audioURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let aTrack = try await aAsset.loadTracks(withMediaType: .audio).first else {
                throw SafariumError.invalidState("audio copy input has no audio track: \(audioURL.lastPathComponent)")
            }
            let aFmts = try await aTrack.load(.formatDescriptions)
            guard let firstAFmt = aFmts.first else {
                throw SafariumError.invalidState("audio copy track missing format description: \(audioURL.lastPathComponent)")
            }
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: firstAFmt)
            aIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(aIn) else {
                throw SafariumError.invalidState("container .\(ext) cannot passthrough-copy audio codec from \(audioURL.lastPathComponent)")
            }
            writer.add(aIn)
            let ar = try AVAssetReader(asset: aAsset)
            ar.timeRange = CMTimeRange(start: .zero, duration: totalDur)
            let ao = AVAssetReaderTrackOutput(track: aTrack, outputSettings: nil)
            ao.alwaysCopiesSampleData = false
            guard ar.canAdd(ao) else {
                throw SafariumError.encode("cannot attach audio reader output for copy")
            }
            ar.add(ao)
            guard ar.startReading() else {
                throw SafariumError.encode("audio copy reader failed: \(ar.error?.localizedDescription ?? "?")")
            }
            ai = aIn
            copyAudioReader = ar
            copyAudioOut = ao
        }

        var si: AVAssetWriterInput?
        let subSamples = subSetup?.1 ?? []
        if let (subFmt, _) = subSetup {
            let sIn = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: subFmt)
            sIn.mediaTimeScale = SafariumTX3G.recommendedTimeScale(for: totalDur)
            sIn.languageCode = cleanLang
            sIn.extendedLanguageTag = LosslessSoundtrackMux.bcp47FromISO639_2(cleanLang)
            sIn.marksOutputTrackAsEnabled = true
            sIn.expectsMediaDataInRealTime = false
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                sIn.mediaDataLocation = .sparselyInterleavedWithMainMediaData
            }
            #endif
            guard writer.canAdd(sIn) else {
                throw SafariumError.encode("writer cannot add tx3g subtitle input")
            }
            writer.add(sIn)
            si = sIn
        }

        let vReader = try AVAssetReader(asset: videoAsset)
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        vOut.alwaysCopiesSampleData = false
        guard vReader.canAdd(vOut) else {
            throw SafariumError.encode("cannot attach video reader output")
        }
        vReader.add(vOut)
        guard vReader.startReading() else {
            throw SafariumError.encode("video reader failed: \(vReader.error?.localizedDescription ?? "?")")
        }

        guard writer.startWriting() else {
            vReader.cancelReading()
            copyAudioReader?.cancelReading()
            throw SafariumError.encode("primary mux startWriting failed: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)

        let vQueue = DispatchQueue(label: "safarium.forge.mux.video")
        let aQueue = DispatchQueue(label: "safarium.forge.mux.audio")
        let sQueue = DispatchQueue(label: "safarium.forge.mux.subtitle")

        final class UncheckedBox<T>: @unchecked Sendable {
            let value: T
            init(_ value: T) { self.value = value }
        }
        let writerBox = UncheckedBox(writer)
        let viBox = UncheckedBox(vi)
        let vReaderBox = UncheckedBox(vReader)
        let vOutBox = UncheckedBox(vOut)
        let aiBox = UncheckedBox(ai)
        let siBox = UncheckedBox(si)
        let subSamplesBox = UncheckedBox(subSamples)
        let wavBox = UncheckedBox(wavFile)
        let fileFmtBox = UncheckedBox(fileFmt)
        let pcmFmtBox = UncheckedBox(pcmInterleavedFmt)
        let copyReaderBox = UncheckedBox(copyAudioReader)
        let copyOutBox = UncheckedBox(copyAudioOut)

        final class MuxCoordinator: @unchecked Sendable {
            private let lock = NSLock()
            private var vDone = false
            private var aDone = false
            private var sDone: Bool
            private var failed: Error?
            private var completed = false
            private let cont: CheckedContinuation<Void, Error>

            init(hasSubtitles: Bool, continuation: CheckedContinuation<Void, Error>) {
                self.sDone = !hasSubtitles
                self.cont = continuation
            }

            func isAborted(video: Bool = false, audio: Bool = false, subtitle: Bool = false) -> Bool {
                lock.withLock {
                    if failed != nil { return true }
                    if video && vDone { return true }
                    if audio && aDone { return true }
                    if subtitle && sDone { return true }
                    return false
                }
            }

            func markVideoDone() {
                let resume = lock.withLock { () -> Result<Void, Error>? in
                    vDone = true
                    return checkCompletedLocked()
                }
                if let resume { cont.resume(with: resume) }
            }

            func markAudioDone() {
                let resume = lock.withLock { () -> Result<Void, Error>? in
                    aDone = true
                    return checkCompletedLocked()
                }
                if let resume { cont.resume(with: resume) }
            }

            func markSubtitleDone() {
                let resume = lock.withLock { () -> Result<Void, Error>? in
                    sDone = true
                    return checkCompletedLocked()
                }
                if let resume { cont.resume(with: resume) }
            }

            func fail(_ err: Error) -> Bool {
                let (shouldCancel, resume) = lock.withLock { () -> (Bool, Result<Void, Error>?) in
                    let firstFailure = (failed == nil)
                    if firstFailure { failed = err }
                    vDone = true
                    aDone = true
                    sDone = true
                    return (firstFailure, checkCompletedLocked())
                }
                if let resume { cont.resume(with: resume) }
                return shouldCancel
            }

            private func checkCompletedLocked() -> Result<Void, Error>? {
                guard !completed else { return nil }
                if let err = failed {
                    completed = true
                    return .failure(err)
                }
                if vDone && aDone && sDone {
                    completed = true
                    return .success(())
                }
                return nil
            }
        }

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let coord = MuxCoordinator(hasSubtitles: siBox.value != nil, continuation: cont)

                @Sendable func failAll(_ err: Error) {
                    if coord.fail(err) {
                        viBox.value.markAsFinished()
                        aiBox.value.markAsFinished()
                        siBox.value?.markAsFinished()
                        vReaderBox.value.cancelReading()
                        copyReaderBox.value?.cancelReading()
                    }
                }

                viBox.value.requestMediaDataWhenReady(on: vQueue) {
                    let vIn = viBox.value
                    let vOut = vOutBox.value
                    let vRdr = vReaderBox.value
                    let wr = writerBox.value
                    while vIn.isReadyForMoreMediaData {
                        if coord.isAborted(video: true) { break }
                        var shouldBreak = false
                        autoreleasepool {
                            if let sb = vOut.copyNextSampleBuffer() {
                                if sb.numSamples == 0 { return }
                                if !vIn.append(sb) {
                                    failAll(SafariumError.encode("primary mux video append failed: \(wr.error?.localizedDescription ?? "?")"))
                                    shouldBreak = true
                                }
                            } else if vRdr.status == .failed {
                                failAll(SafariumError.encode("primary mux video read failed: \(vRdr.error?.localizedDescription ?? "?")"))
                                shouldBreak = true
                            } else {
                                vIn.markAsFinished()
                                coord.markVideoDone()
                                shouldBreak = true
                            }
                        }
                        if shouldBreak { break }
                    }
                }

                if let wavFile = wavBox.value, let ff = fileFmtBox.value, let pcmFmt = pcmFmtBox.value {
                    let readBuf = AVAudioPCMBuffer(pcmFormat: ff, frameCapacity: 4096)!
                    let readBufBox = UncheckedBox(readBuf)
                    let chCount = Int(ff.channelCount)
                    let interleavedBox = UncheckedBox([Float](repeating: 0, count: 4096 * chCount))
                    let sentFramesBox = UncheckedBox(UnsafeMutablePointer<AVAudioFramePosition>.allocate(capacity: 1))
                    sentFramesBox.value.initialize(to: 0)
                    let wavSend = UncheckedBox(wavFile)
                    let ffSend = UncheckedBox(ff)
                    let pcmSend = UncheckedBox(pcmFmt)

                    final class FloatBufferHolder: @unchecked Sendable {
                        var data: [Float]
                        var sentFrames: AVAudioFramePosition = 0
                        init(count: Int) { self.data = [Float](repeating: 0, count: count) }
                    }
                    sentFramesBox.value.deinitialize(count: 1)
                    sentFramesBox.value.deallocate()
                    _ = interleavedBox
                    let audioState = FloatBufferHolder(count: 4096 * chCount)

                    aiBox.value.requestMediaDataWhenReady(on: aQueue) {
                        let aIn = aiBox.value
                        let wr = writerBox.value
                        let rBuf = readBufBox.value
                        let wf = wavSend.value
                        let fmt = ffSend.value
                        let pFmt = pcmSend.value
                        while aIn.isReadyForMoreMediaData {
                            if coord.isAborted(audio: true) { break }
                            let rem = totalAudioFrames - audioState.sentFrames
                            if rem <= 0 {
                                aIn.markAsFinished()
                                coord.markAudioDone()
                                break
                            }
                            let take = AVAudioFrameCount(min(4096, Int(rem)))
                            var shouldBreak = false
                            autoreleasepool {
                                do {
                                    try wf.read(into: rBuf, frameCount: take)
                                    let got = Int(rBuf.frameLength)
                                    if got == 0 {
                                        aIn.markAsFinished()
                                        coord.markAudioDone()
                                        shouldBreak = true
                                        return
                                    }
                                    if let chData = rBuf.floatChannelData {
                                        if chCount == 1 {
                                            audioState.data.withUnsafeMutableBufferPointer { dst in
                                                _ = memcpy(dst.baseAddress!, chData[0], got * 4)
                                            }
                                        } else {
                                            for f in 0..<got {
                                                for c in 0..<chCount {
                                                    audioState.data[f * chCount + c] = chData[c][f]
                                                }
                                            }
                                        }
                                    }
                                    let bytes = got * chCount * 4
                                    var bb: CMBlockBuffer?
                                    let bbStatus = CMBlockBufferCreateWithMemoryBlock(
                                        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                        blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                        offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &bb
                                    )
                                    guard bbStatus == noErr, let blockBuf = bb else {
                                        throw SafariumError.encode("CMBlockBufferCreateWithMemoryBlock failed (\(bbStatus))")
                                    }
                                    let repStatus = audioState.data.withUnsafeBufferPointer { p in
                                        CMBlockBufferReplaceDataBytes(with: p.baseAddress!, blockBuffer: blockBuf, offsetIntoDestination: 0, dataLength: bytes)
                                    }
                                    guard repStatus == noErr else {
                                        throw SafariumError.encode("CMBlockBufferReplaceDataBytes failed (\(repStatus))")
                                    }
                                    var sb: CMSampleBuffer?
                                    let sbStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                                        allocator: kCFAllocatorDefault, dataBuffer: blockBuf, formatDescription: pFmt.formatDescription,
                                        sampleCount: got, presentationTimeStamp: CMTime(value: Int64(audioState.sentFrames), timescale: Int32(fmt.sampleRate.rounded())),
                                        packetDescriptions: nil, sampleBufferOut: &sb
                                    )
                                    guard sbStatus == noErr, let audioSample = sb, aIn.append(audioSample) else {
                                        failAll(SafariumError.encode("pcm_s16le audio append failed: \(wr.error?.localizedDescription ?? "?")"))
                                        shouldBreak = true
                                        return
                                    }
                                    audioState.sentFrames += AVAudioFramePosition(got)
                                } catch {
                                    failAll(error)
                                    shouldBreak = true
                                }
                            }
                            if shouldBreak { break }
                        }
                    }
                } else if copyReaderBox.value != nil, copyOutBox.value != nil {
                    aiBox.value.requestMediaDataWhenReady(on: aQueue) {
                        let aIn = aiBox.value
                        let cRdr = copyReaderBox.value!
                        let cOut = copyOutBox.value!
                        let wr = writerBox.value
                        while aIn.isReadyForMoreMediaData {
                            if coord.isAborted(audio: true) { break }
                            var shouldBreak = false
                            autoreleasepool {
                                if let sb = cOut.copyNextSampleBuffer() {
                                    if sb.numSamples == 0 { return }
                                    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                                    if pts.isValid && CMTimeCompare(pts, totalDur) >= 0 {
                                        aIn.markAsFinished()
                                        coord.markAudioDone()
                                        shouldBreak = true
                                        return
                                    }
                                    if !aIn.append(sb) {
                                        failAll(SafariumError.encode("copy audio append failed: \(wr.error?.localizedDescription ?? "?")"))
                                        shouldBreak = true
                                    }
                                } else if cRdr.status == .failed {
                                    failAll(SafariumError.encode("copy audio read failed: \(cRdr.error?.localizedDescription ?? "?")"))
                                    shouldBreak = true
                                } else {
                                    aIn.markAsFinished()
                                    coord.markAudioDone()
                                    shouldBreak = true
                                }
                            }
                            if shouldBreak { break }
                        }
                    }
                }

                if let sInInit = siBox.value {
                    final class SubCursor: @unchecked Sendable { var index = 0 }
                    let subCursor = SubCursor()
                    sInInit.requestMediaDataWhenReady(on: sQueue) {
                        let sIn = siBox.value!
                        let samples = subSamplesBox.value
                        let wr = writerBox.value
                        while sIn.isReadyForMoreMediaData {
                            if coord.isAborted(subtitle: true) { break }
                            if subCursor.index >= samples.count {
                                sIn.markAsFinished()
                                coord.markSubtitleDone()
                                break
                            }
                            guard sIn.append(samples[subCursor.index]) else {
                                failAll(SafariumError.encode("primary mux subtitle append failed: \(wr.error?.localizedDescription ?? "?")"))
                                break
                            }
                            subCursor.index += 1
                        }
                    }
                }
            }
        } catch {
            vReader.cancelReading()
            copyAudioReader?.cancelReading()
            writer.cancelWriting()
            throw error
        }

        writer.endSession(atSourceTime: totalDur)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw SafariumError.encode("primary mux finishWriting failed: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")")
        }
    }
}

/// Zero-redecode incremental contact sheet collector that samples and downscales frames directly
/// from in-flight `CVPixelBuffer` or BGRA frame buffers during encode using bounded thumbnail memory.
public final class ForgeInlineSheetCollector {
    public let totalFrames: Int?
    public let fps: Int
    public let config: ForgeContactSheetConfig
    public let isInlineZeroRedecode: Bool = true

    private struct ThumbnailTile {
        let frameIndex: Int
        let bgraData: Data
    }

    private let lock = NSLock()
    private let maxSlots: Int
    private let tileW: Int
    private var resolvedTileH: Int?
    private let ciCtx: CIContext
    private var finalized = false

    // Sampling state
    private var uniformTargets: [Int] = []
    private var uniformCursor = 0
    private var reservoirState: UInt64 = 0x9E37_79B9_7F4A_7C15
    private var streamFramesSeen = 0
    private var collected: [ThumbnailTile] = []
    private var timestampTargets: [Double] = []
    private var timestampSlots: [ThumbnailTile?] = []
    private var lastSeenTile: ThumbnailTile?
    private var fallbackFirstTile: ThumbnailTile?
    private var inputLabel = "inline-stream"

    public init(totalFrames: Int?, fps: Int, config: ForgeContactSheetConfig = ForgeContactSheetConfig()) throws {
        guard fps > 0 else {
            throw SafariumError.invalidState("inline contact sheet requires positive fps")
        }
        guard config.cols >= 1, config.rows >= 1, config.tileWidth >= 16, config.padding >= 0 else {
            throw SafariumError.invalidState("invalid inline contact sheet grid or padding")
        }
        if let tf = totalFrames, tf < 0 {
            throw SafariumError.invalidState("inline contact sheet totalFrames cannot be negative")
        }
        self.totalFrames = totalFrames
        self.fps = fps
        self.config = config
        self.maxSlots = config.cols * config.rows
        self.tileW = config.tileWidth
        self.resolvedTileH = config.tileHeight.map { max(16, $0 & ~1) }
        self.ciCtx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])

        switch config.sampling {
        case .uniformCount(let reqCount):
            let cnt = max(1, min(maxSlots, reqCount ?? maxSlots))
            if let knownTotal = totalFrames, knownTotal > 0 {
                let effective = min(cnt, knownTotal)
                var targets: [Int] = []
                targets.reserveCapacity(effective)
                for slot in 0..<effective {
                    let idx = min(knownTotal - 1, Int(((Double(slot) + 0.5) * Double(knownTotal) / Double(effective)).rounded(.down)))
                    if targets.last != idx { targets.append(idx) }
                }
                self.uniformTargets = targets
            }
        case .timestamps(let times):
            guard !times.isEmpty else {
                throw SafariumError.invalidState("inline contact sheet timestamps list cannot be empty")
            }
            let capped = Array(times.prefix(maxSlots))
            self.timestampTargets = capped
            self.timestampSlots = Array(repeating: nil, count: capped.count)
        case .everyFrames, .everySeconds:
            break
        }
    }

    public func setInputLabel(_ label: String) {
        lock.withLock { self.inputLabel = label }
    }

    public func ingest(frameIndex: Int, pixelBuffer: CVPixelBuffer) throws {
        guard frameIndex >= 0 else {
            throw SafariumError.invalidState("inline contact sheet frameIndex must be >= 0")
        }
        let srcW = CVPixelBufferGetWidth(pixelBuffer)
        let srcH = CVPixelBufferGetHeight(pixelBuffer)
        guard srcW > 0, srcH > 0 else { return }

        if CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA {
            guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
                throw SafariumError.encode("inline contact sheet failed to lock BGRA pixelBuffer")
            }
            defer { _ = CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                throw SafariumError.encode("inline contact sheet missing BGRA pixelBuffer baseAddress")
            }
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            try ingestFrameLocked(frameIndex: frameIndex, srcW: srcW, srcH: srcH) { tileH in
                try Self.scaleBGRAToTileData(
                    baseAddress: base,
                    bytesPerRow: stride,
                    srcWidth: srcW,
                    srcHeight: srcH,
                    dstWidth: tileW,
                    dstHeight: tileH
                )
            }
        } else {
            try ingestFrameLocked(frameIndex: frameIndex, srcW: srcW, srcH: srcH) { tileH in
                try autoreleasepool {
                    let ci = CIImage(cvPixelBuffer: pixelBuffer)
                    let sx = CGFloat(tileW) / CGFloat(srcW)
                    let sy = CGFloat(tileH) / CGFloat(srcH)
                    let scaled = ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                    guard let cg = ciCtx.createCGImage(
                        scaled,
                        from: CGRect(x: scaled.extent.origin.x, y: scaled.extent.origin.y, width: CGFloat(tileW), height: CGFloat(tileH)),
                        format: .BGRA8,
                        colorSpace: Snapshot.colorSpace
                    ) else {
                        throw SafariumError.encode("inline contact sheet CI scale failed")
                    }
                    return try Snapshot(cgImage: cg).checkedBGRA()
                }
            }
        }
    }

    public func ingestBGRA(frameIndex: Int, baseAddress: UnsafeRawPointer, bytesPerRow: Int, width: Int, height: Int) throws {
        guard frameIndex >= 0, width > 0, height > 0, bytesPerRow >= width * 4 else {
            throw SafariumError.invalidState("invalid BGRA frame dimensions for inline sheet")
        }
        try ingestFrameLocked(frameIndex: frameIndex, srcW: width, srcH: height) { tileH in
            try Self.scaleBGRAToTileData(
                baseAddress: baseAddress,
                bytesPerRow: bytesPerRow,
                srcWidth: width,
                srcHeight: height,
                dstWidth: tileW,
                dstHeight: tileH
            )
        }
    }

    private func ingestFrameLocked(
        frameIndex: Int,
        srcW: Int,
        srcH: Int,
        makeTileData: (Int) throws -> Data
    ) throws {
        try lock.withLock {
            guard !finalized else {
                throw SafariumError.invalidState("cannot ingest into finalized ForgeInlineSheetCollector")
            }
            let tileH: Int
            if let existing = resolvedTileH {
                tileH = existing
            } else {
                let computed = config.tileHeight ?? Int((Double(tileW) * Double(srcH) / Double(max(1, srcW))).rounded())
                let clamped = max(16, computed & ~1)
                resolvedTileH = clamped
                tileH = clamped
            }

            switch config.sampling {
            case .everyFrames(let step):
                let s = max(1, step)
                if collected.count < maxSlots && frameIndex % s == 0 {
                    collected.append(ThumbnailTile(frameIndex: frameIndex, bgraData: try makeTileData(tileH)))
                }

            case .everySeconds(let stepSec):
                let s = max(0.01, stepSec)
                let ptsSec = Double(frameIndex) / Double(fps)
                if collected.count < maxSlots && ptsSec + 1e-6 >= Double(collected.count) * s {
                    collected.append(ThumbnailTile(frameIndex: frameIndex, bgraData: try makeTileData(tileH)))
                }

            case .timestamps:
                let ptsSec = Double(frameIndex) / Double(fps)
                var matchedIndices: [Int] = []
                var hasUnfilled = false
                for slot in 0..<timestampTargets.count {
                    if timestampSlots[slot] == nil {
                        if ptsSec + 1e-6 >= timestampTargets[slot] {
                            matchedIndices.append(slot)
                        } else {
                            hasUnfilled = true
                        }
                    }
                }
                if !matchedIndices.isEmpty || hasUnfilled {
                    let tile = ThumbnailTile(frameIndex: frameIndex, bgraData: try makeTileData(tileH))
                    for slot in matchedIndices {
                        timestampSlots[slot] = tile
                    }
                    lastSeenTile = hasUnfilled ? tile : nil
                }

            case .uniformCount(let reqCount):
                let targetCount = max(1, min(maxSlots, reqCount ?? maxSlots))
                if !uniformTargets.isEmpty {
                    if uniformCursor < uniformTargets.count && frameIndex == uniformTargets[uniformCursor] {
                        let tile = ThumbnailTile(frameIndex: frameIndex, bgraData: try makeTileData(tileH))
                        collected.append(tile)
                        uniformCursor += 1
                        fallbackFirstTile = nil
                    } else if frameIndex == 0 && collected.isEmpty && fallbackFirstTile == nil {
                        fallbackFirstTile = ThumbnailTile(frameIndex: frameIndex, bgraData: try makeTileData(tileH))
                    }
                } else {
                    // Streaming mode (totalFrames == nil): bounded <= targetCount deterministic reservoir
                    // keeping frame 0 pinned so short and long streams always fill min(seen, targetCount) slots.
                    streamFramesSeen += 1
                    if collected.count < targetCount {
                        collected.append(ThumbnailTile(frameIndex: frameIndex, bgraData: try makeTileData(tileH)))
                    } else if targetCount >= 2 {
                        reservoirState ^= reservoirState << 13
                        reservoirState ^= reservoirState >> 7
                        reservoirState ^= reservoirState << 17
                        let j = Int(reservoirState % UInt64(max(1, streamFramesSeen - 1)))
                        if j < targetCount - 1 {
                            collected[1 + j] = ThumbnailTile(frameIndex: frameIndex, bgraData: try makeTileData(tileH))
                        }
                    }
                }
            }
        }
    }

    private static func scaleBGRAToTileData(
        baseAddress: UnsafeRawPointer,
        bytesPerRow: Int,
        srcWidth: Int,
        srcHeight: Int,
        dstWidth: Int,
        dstHeight: Int
    ) throws -> Data {
        var srcBuf = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: baseAddress),
            height: vImagePixelCount(srcHeight),
            width: vImagePixelCount(srcWidth),
            rowBytes: bytesPerRow
        )
        var dstData = Data(count: dstWidth * dstHeight * 4)
        let err = dstData.withUnsafeMutableBytes { raw -> vImage_Error in
            var dstBuf = vImage_Buffer(
                data: raw.baseAddress!,
                height: vImagePixelCount(dstHeight),
                width: vImagePixelCount(dstWidth),
                rowBytes: dstWidth * 4
            )
            return vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageNoFlags))
        }
        guard err == kvImageNoError else {
            throw SafariumError.encode("vImageScale_ARGB8888 inline thumbnail scale failed (\(err))")
        }
        return dstData
    }

    public func finalize(to outputURL: URL, overwrite: Bool = false) throws -> ForgeContactSheetReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let (finalTiles, tileH, label): ([ThumbnailTile], Int, String) = try lock.withLock {
            guard !finalized else {
                throw SafariumError.invalidState("ForgeInlineSheetCollector already finalized")
            }
            finalized = true
            let h = resolvedTileH ?? max(16, (config.tileHeight ?? (tileW * 9 / 16)) & ~1)
            let resolved: [ThumbnailTile]
            switch config.sampling {
            case .timestamps:
                var out: [ThumbnailTile] = []
                out.reserveCapacity(timestampSlots.count)
                for slot in timestampSlots {
                    if let t = slot ?? lastSeenTile {
                        out.append(t)
                    }
                }
                resolved = out
            default:
                if collected.isEmpty, let fb = fallbackFirstTile {
                    resolved = [fb]
                } else {
                    resolved = collected.sorted { $0.frameIndex < $1.frameIndex }
                }
            }
            collected.removeAll(keepingCapacity: false)
            timestampSlots.removeAll(keepingCapacity: false)
            lastSeenTile = nil
            fallbackFirstTile = nil
            return (resolved, h, inputLabel)
        }

        guard !finalTiles.isEmpty else {
            throw SafariumError.invalidState("inline contact sheet produced 0 tiles")
        }

        let pad = config.padding
        let sheetW = config.cols * tileW + (config.cols + 1) * pad
        let sheetH = config.rows * tileH + (config.rows + 1) * pad
        guard sheetW <= 16384, sheetH <= 16384 else {
            throw SafariumError.invalidState("inline contact sheet dimensions \(sheetW)x\(sheetH) exceed 16384 limit")
        }

        let stage = try APFSAutoStage.makeSession(for: outputURL, overwrite: overwrite)
        defer { stage.cleanup() }

        let bgRGBA = ForgeColorHex.parseRGBA(config.bgColorHex)
        guard let ctx = CGContext(
            data: nil,
            width: sheetW,
            height: sheetH,
            bitsPerComponent: 8,
            bytesPerRow: sheetW * 4,
            space: Snapshot.colorSpace,
            bitmapInfo: Snapshot.bitmapInfo
        ) else {
            throw SafariumError.encode("failed to allocate \(sheetW)x\(sheetH) inline contact sheet CGContext")
        }
        ctx.setFillColor(CGColor(srgbRed: CGFloat(bgRGBA.x), green: CGFloat(bgRGBA.y), blue: CGFloat(bgRGBA.z), alpha: CGFloat(bgRGBA.w)))
        ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))

        var reportTiles: [ForgeContactSheetTile] = []
        reportTiles.reserveCapacity(finalTiles.count)
        for (slotIdx, tile) in finalTiles.prefix(maxSlots).enumerated() {
            guard let provider = CGDataProvider(data: tile.bgraData as CFData),
                  let tileCG = CGImage(
                      width: tileW,
                      height: tileH,
                      bitsPerComponent: 8,
                      bitsPerPixel: 32,
                      bytesPerRow: tileW * 4,
                      space: Snapshot.colorSpace,
                      bitmapInfo: CGBitmapInfo(rawValue: Snapshot.bitmapInfo),
                      provider: provider,
                      decode: nil,
                      shouldInterpolate: false,
                      intent: .defaultIntent
                  ) else {
                throw SafariumError.encode("failed to create CGImage for inline contact sheet tile \(slotIdx)")
            }
            let row = slotIdx / config.cols
            let col = slotIdx % config.cols
            let tileX = pad + col * (tileW + pad)
            let tileYTop = pad + row * (tileH + pad)
            let cgY = sheetH - tileYTop - tileH
            ctx.draw(tileCG, in: CGRect(x: tileX, y: cgY, width: tileW, height: tileH))

            let pts = CMTime(value: Int64(tile.frameIndex), timescale: Int32(fps))
            reportTiles.append(ForgeContactSheetTile(
                tileIndex: slotIdx,
                row: row,
                col: col,
                frameIndex: tile.frameIndex,
                ptsSeconds: CMTimeGetSeconds(pts),
                ptsRational: PacketProbe.rational(pts),
                tileX: tileX,
                tileY: tileYTop,
                tileWidth: tileW,
                tileHeight: tileH
            ))
        }

        guard let sheetImg = ctx.makeImage() else {
            throw SafariumError.encode("inline contact sheet makeImage failed")
        }
        let ext = outputURL.pathExtension.lowercased()
        let chosenFmt = ext.isEmpty ? config.format : ext
        let sheetBytes = try ForgeSheetAndQA.writeSheetImage(
            sheetImg,
            format: chosenFmt,
            quality: config.quality,
            stage: stage,
            prefix: "sheet",
            overwrite: overwrite
        )

        let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        return ForgeContactSheetReport(
            inputPath: label,
            outputPath: outputURL.path,
            manifestPath: nil,
            cols: config.cols,
            rows: config.rows,
            tileCount: reportTiles.count,
            width: sheetW,
            height: sheetH,
            padding: pad,
            bytes: sheetBytes,
            tiles: reportTiles,
            wallMs: wallMs,
            isInlineZeroRedecode: true
        )
    }
}

/// Shared single-pass Primary + optional Secondary Dual-Output Tee session used by both
/// `ForgeSheetAndQA.pipeEncode` and `ForgeSharedRingServer` (zero-copy `mmap` ring).
public final class ForgeDualTeeSession {
    public let primaryOutputURL: URL
    public let config: ForgePipeEncodeConfig
    public private(set) var framesWritten = 0

    private let primaryStage: APFSStageSession
    private let secondaryStage: APFSStageSession?
    private let primarySink: AVAssetWriterSink
    private let secondarySink: AVAssetWriterSink?
    private let stagedPrimaryVideo: URL
    private let stagedSecondaryVideo: URL?
    private var secCompositeScratch: [UInt8]
    private let bgPlate: [UInt8]
    private let primaryAudioCodec: String
    private let inlineCollector: ForgeInlineSheetCollector?
    private let inlineSheetOutputURL: URL?

    public init(primaryOutputURL: URL, config: ForgePipeEncodeConfig) throws {
        guard config.width > 0, config.height > 0, config.fps > 0 else {
            throw SafariumError.invalidState("pipe-encode requires positive width, height, and fps")
        }
        if config.primaryPixelFormat != .bgra || (config.secondaryOutputURL != nil && !(config.secondaryCodec?.hasAlpha ?? false)) {
            guard config.width % 2 == 0, config.height % 2 == 0 else {
                throw SafariumError.invalidState("YUV/H.264 pipe-encode requires even dimensions, got \(config.width)x\(config.height)")
            }
        }

        let cleanAudioCodec = config.primaryAudioCodec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleanAudioCodec == "aac" || cleanAudioCodec == "pcm_s16le" || cleanAudioCodec == "copy" else {
            throw SafariumError.invalidState("unsupported primaryAudioCodec '\(config.primaryAudioCodec)' (expected aac|pcm_s16le|copy)")
        }
        if cleanAudioCodec == "pcm_s16le" && config.audioURL != nil && config.primaryCodec.fileType != .mov {
            throw SafariumError.invalidState("primaryAudioCodec 'pcm_s16le' requires QuickTime .mov primary container, got .\(config.primaryCodec.fileExtension)")
        }
        if config.inlineSheetConfig != nil && config.inlineSheetOutputURL == nil {
            throw SafariumError.invalidState("inlineSheetConfig requires inlineSheetOutputURL")
        }
        let collector: ForgeInlineSheetCollector?
        if let sheetOutURL = config.inlineSheetOutputURL {
            try SafeFilePublisher.preflight(outputURL: sheetOutURL, overwrite: config.overwrite)
            let sheetCfg = config.inlineSheetConfig ?? ForgeContactSheetConfig()
            let c = try ForgeInlineSheetCollector(totalFrames: config.maxFrames, fps: config.fps, config: sheetCfg)
            c.setInputLabel(primaryOutputURL.path)
            collector = c
        } else {
            collector = nil
        }

        self.primaryOutputURL = primaryOutputURL
        self.config = config
        self.primaryAudioCodec = cleanAudioCodec
        self.inlineCollector = collector
        self.inlineSheetOutputURL = config.inlineSheetOutputURL

        let priStage = try APFSAutoStage.makeSession(for: primaryOutputURL, overwrite: config.overwrite)
        var secStage: APFSStageSession?
        do {
            secStage = try config.secondaryOutputURL.map {
                try APFSAutoStage.makeSession(for: $0, overwrite: config.overwrite)
            }
            let profile: EncoderProfile = config.closedGOP ? .lowRamClosedGOP : .baseline
            let sPri = priStage.fileURL("primary.\(config.primaryCodec.fileExtension)")
            let priSink = try AVAssetWriterSink(
                url: sPri,
                width: config.width,
                height: config.height,
                fps: config.fps,
                codec: config.primaryCodec,
                bitrate: config.primaryBitrate,
                quality: config.primaryQuality,
                pixelFormat: config.primaryPixelFormat,
                profile: profile
            )

            var secSink: AVAssetWriterSink?
            var secURL: URL?
            if let secCodec = config.secondaryCodec, config.secondaryOutputURL != nil {
                let sURL = (secStage ?? priStage).fileURL("secondary.\(secCodec.fileExtension)")
                secURL = sURL
                secSink = try AVAssetWriterSink(
                    url: sURL,
                    width: config.width,
                    height: config.height,
                    fps: config.fps,
                    codec: secCodec,
                    bitrate: config.secondaryBitrate,
                    quality: config.secondaryQuality,
                    pixelFormat: secCodec.hasAlpha ? .bgra : .nv12Left,
                    profile: profile
                )
            }

            let w = config.width
            let h = config.height
            let byteCount = w * h * 4
            let secScratch: [UInt8]
            let plate: [UInt8]
            if secSink != nil {
                secScratch = [UInt8](repeating: 0, count: byteCount)
                var tmpPlate = [UInt8](repeating: 0, count: byteCount)
                let bgRGBA = ForgeColorHex.parseRGBA(config.secondaryBackgroundHex)
                let bU8 = UInt8((max(0, min(1, bgRGBA.z)) * 255.0).rounded())
                let gU8 = UInt8((max(0, min(1, bgRGBA.y)) * 255.0).rounded())
                let rU8 = UInt8((max(0, min(1, bgRGBA.x)) * 255.0).rounded())
                for px in 0..<(w * h) {
                    tmpPlate[px * 4] = bU8
                    tmpPlate[px * 4 + 1] = gU8
                    tmpPlate[px * 4 + 2] = rU8
                    tmpPlate[px * 4 + 3] = 255
                }
                plate = tmpPlate
            } else {
                secScratch = []
                plate = []
            }

            self.primaryStage = priStage
            self.secondaryStage = secStage
            self.stagedPrimaryVideo = sPri
            self.primarySink = priSink
            self.secondarySink = secSink
            self.stagedSecondaryVideo = secURL
            self.secCompositeScratch = secScratch
            self.bgPlate = plate
        } catch {
            secStage?.cleanup()
            priStage.cleanup()
            throw error
        }
    }

    deinit {
        primaryStage.cleanup()
        secondaryStage?.cleanup()
    }

    public func appendBGRAFrame(_ bgraScratch: [UInt8]) async throws {
        let w = config.width
        let h = config.height
        let bgraStride = w * 4
        guard bgraScratch.count >= bgraStride * h else {
            throw SafariumError.encode("BGRA scratch buffer too small")
        }

        if let collector = inlineCollector {
            try bgraScratch.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    try collector.ingestBGRA(frameIndex: framesWritten, baseAddress: base, bytesPerRow: bgraStride, width: w, height: h)
                }
            }
        }

        try await primarySink.append { pb in
            switch config.primaryPixelFormat {
            case .bgra:
                CVPixelBufferLockBaseAddress(pb, [])
                defer { CVPixelBufferUnlockBaseAddress(pb, []) }
                guard let dstBase = CVPixelBufferGetBaseAddress(pb) else {
                    throw SafariumError.encode("missing primary BGRA base address")
                }
                let dstStride = CVPixelBufferGetBytesPerRow(pb)
                bgraScratch.withUnsafeBytes { raw in
                    let srcBase = raw.baseAddress!
                    if dstStride == bgraStride {
                        memcpy(dstBase, srcBase, bgraStride * h)
                    } else {
                        for y in 0..<h {
                            memcpy(dstBase.advanced(by: y * dstStride), srcBase.advanced(by: y * bgraStride), bgraStride)
                        }
                    }
                }
            case .nv12Left, .nv12vImage:
                try bgraScratch.withUnsafeBytes { raw in
                    try SafariumAccelerate.convertRawBGRAToNV12BT709Left(
                        bgra: raw.baseAddress!, bgraBytesPerRow: bgraStride, into: pb, width: w, height: h
                    )
                }
            }
        }

        if let secSink = secondarySink {
            secCompositeScratch.replaceSubrange(0..<bgPlate.count, with: bgPlate)
            try bgraScratch.withUnsafeBytes { fgRaw in
                try secCompositeScratch.withUnsafeMutableBytes { dstRaw in
                    try SafariumAccelerate.premultipliedAlphaBlendBGRA(
                        src: fgRaw.baseAddress!, srcBytesPerRow: bgraStride,
                        dst: dstRaw.baseAddress!, dstBytesPerRow: bgraStride,
                        width: w, height: h
                    )
                }
            }
            try await secSink.append { pb in
                let secAlpha = config.secondaryCodec?.hasAlpha ?? false
                if secAlpha {
                    CVPixelBufferLockBaseAddress(pb, [])
                    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
                    let dstBase = CVPixelBufferGetBaseAddress(pb)!
                    let dstStride = CVPixelBufferGetBytesPerRow(pb)
                    secCompositeScratch.withUnsafeBytes { raw in
                        for y in 0..<h {
                            memcpy(dstBase.advanced(by: y * dstStride), raw.baseAddress!.advanced(by: y * bgraStride), bgraStride)
                        }
                    }
                } else {
                    try secCompositeScratch.withUnsafeBytes { raw in
                        try SafariumAccelerate.convertRawBGRAToNV12BT709Left(
                            bgra: raw.baseAddress!, bgraBytesPerRow: bgraStride, into: pb, width: w, height: h
                        )
                    }
                }
            }
        }

        framesWritten += 1
        if framesWritten % 60 == 0 {
            primarySink.flushPool()
            secondarySink?.flushPool()
        }
    }

    public func finishAndCommit(startedUptimeNs t0: UInt64 = DispatchTime.now().uptimeNanoseconds) async throws -> ForgePipeEncodeReport {
        guard framesWritten > 0 else {
            throw SafariumError.invalidState("pipe-encode received 0 frames")
        }
        try await primarySink.finish()
        try await secondarySink?.finish()

        var finalPrimaryStaged = stagedPrimaryVideo
        if config.audioURL != nil || config.subtitlesURL != nil {
            let muxedPrimary = primaryStage.fileURL("primary_muxed.\(config.primaryCodec.fileExtension)")
            if let audioURL = config.audioURL, (primaryAudioCodec == "pcm_s16le" || primaryAudioCodec == "copy") {
                try await ForgeSheetAndQA.muxPrimaryAudioLossless(
                    videoURL: stagedPrimaryVideo,
                    audioURL: audioURL,
                    audioCodec: primaryAudioCodec,
                    subtitlesURL: config.subtitlesURL,
                    subtitleLang: config.subtitleLang,
                    outputURL: muxedPrimary
                )
            } else {
                _ = try await LosslessSoundtrackMux.mux(
                    videoURL: stagedPrimaryVideo,
                    wavURL: config.audioURL,
                    subtitlesURL: config.subtitlesURL,
                    subtitleLang: config.subtitleLang,
                    outputURL: muxedPrimary,
                    overwrite: true
                )
            }
            finalPrimaryStaged = muxedPrimary
        }
        try primaryStage.commit(stagedFile: finalPrimaryStaged, overwrite: config.overwrite)

        var secBytes: Int64?
        if let secOutURL = config.secondaryOutputURL, let secStage = secondaryStage, let sVid = stagedSecondaryVideo {
            var finalSecStaged = sVid
            if config.audioURL != nil || config.subtitlesURL != nil {
                let muxedSec = secStage.fileURL("secondary_muxed.\((config.secondaryCodec ?? .h264).fileExtension)")
                _ = try await LosslessSoundtrackMux.mux(
                    videoURL: sVid,
                    wavURL: config.audioURL,
                    subtitlesURL: config.subtitlesURL,
                    subtitleLang: config.subtitleLang,
                    outputURL: muxedSec,
                    overwrite: true
                )
                finalSecStaged = muxedSec
            }
            try secStage.commit(stagedFile: finalSecStaged, to: secOutURL, overwrite: config.overwrite)
            secBytes = ((try? FileManager.default.attributesOfItem(atPath: secOutURL.path)[.size]) as? NSNumber)?.int64Value
        }

        var sheetReport: ForgeContactSheetReport?
        if let collector = inlineCollector, let sheetOutURL = inlineSheetOutputURL {
            sheetReport = try collector.finalize(to: sheetOutURL, overwrite: config.overwrite)
        }

        let priBytes = ((try? FileManager.default.attributesOfItem(atPath: primaryOutputURL.path)[.size]) as? NSNumber)?.int64Value ?? 0
        return ForgePipeEncodeReport(
            primaryOutputPath: primaryOutputURL.path,
            secondaryOutputPath: config.secondaryOutputURL?.path,
            width: config.width,
            height: config.height,
            fps: config.fps,
            frames: framesWritten,
            primaryCodec: config.primaryCodec.rawValue,
            secondaryCodec: config.secondaryCodec?.rawValue,
            primaryBytes: priBytes,
            secondaryBytes: secBytes,
            wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6,
            inlineSheetReport: sheetReport
        )
    }

    public func cancel() {
        primarySink.cancel()
        secondarySink?.cancel()
        primaryStage.cleanup()
        secondaryStage?.cleanup()
    }
}
