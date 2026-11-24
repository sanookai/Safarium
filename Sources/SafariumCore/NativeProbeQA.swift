import Accelerate
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct PacketRecord: Codable, Sendable {
    public let index: Int
    public let pts: String
    public let ptsSeconds: Double
    public let dts: String
    public let dtsSeconds: Double
    public let duration: String
    public let isFullSync: Bool
    public let mayReorderLaterDTS: Bool
    public let dataBytes: Int
    public let sha256: String
}

public struct FormatDescInfo: Codable, Sendable {
    public let mediaType: String
    public let codec: String
    public let width: Int?
    public let height: Int?
    public let avcParameterSetCount: Int?
    public let paramSetSHA256: String?
    public let primaries: String?
    public let transfer: String?
    public let matrix: String?
    public let chromaLocationTop: String?
    public let sampleRate: Double?
    public let channels: UInt32?
}

public struct ProbeTrackReport: Codable, Sendable {
    public let trackID: Int32
    public let mediaType: String
    public let timeScale: Int32
    public let nominalFrameRate: Float?
    public let languageCode: String?
    public let start: String
    public let duration: String
    public let durationSeconds: Double
    public let stsdCount: Int
    public let formats: [FormatDescInfo]
    public let packetCount: Int
    public let packets: [PacketRecord]
}

public struct ProbeReport: Codable, Sendable {
    public let file: String
    public let playable: Bool
    public let duration: String
    public let durationSeconds: Double
    public let tracks: [ProbeTrackReport]
}

public struct PacketCompareResult: Codable, Sendable {
    public let exactMatch: Bool
    public let diffCount: Int
    public let details: [String]
}

public enum PacketProbe {
    public static func fourCC(_ code: FourCharCode) -> String {
        String(decoding: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, as: UTF8.self)
    }

    public static func rational(_ t: CMTime) -> String {
        guard t.isNumeric, t.timescale > 0 else { return "invalid" }
        var a = abs(t.value)
        var b = Int64(t.timescale)
        while b != 0 { (a, b) = (b, a % b) }
        let d = max(1, a)
        return "\(t.value / d)/\(Int64(t.timescale) / d)"
    }

    public static func formatDescInfo(_ fmt: CMFormatDescription) -> FormatDescInfo {
        let mt = fourCC(CMFormatDescriptionGetMediaType(fmt))
        let sub = fourCC(CMFormatDescriptionGetMediaSubType(fmt))
        if mt == "vide" {
            let dim = CMVideoFormatDescriptionGetDimensions(fmt)
            var psCount: Int?
            var psHash: String?
            if sub == "avc1" {
                var count = 0
                var hasher = SHA256()
                let st0 = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
                )
                if st0 == noErr && count > 0 {
                    psCount = count
                    for i in 0..<count {
                        var ptr: UnsafePointer<UInt8>?
                        var sz = 0
                        if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                            fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                            parameterSetSizeOut: &sz, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                        ) == noErr, let ptr, sz > 0 {
                            hasher.update(bufferPointer: UnsafeRawBufferPointer(start: ptr, count: sz))
                        }
                    }
                    psHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                }
            }
            let p = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
            let tr = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            let mx = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String
            let chroma = CMFormatDescriptionGetExtension(fmt, extensionKey: kCVImageBufferChromaLocationTopFieldKey) as? String
            return FormatDescInfo(
                mediaType: mt, codec: sub, width: Int(dim.width), height: Int(dim.height),
                avcParameterSetCount: psCount, paramSetSHA256: psHash,
                primaries: p, transfer: tr, matrix: mx, chromaLocationTop: chroma,
                sampleRate: nil, channels: nil
            )
        } else if mt == "soun" {
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee
            return FormatDescInfo(
                mediaType: mt, codec: sub, width: nil, height: nil,
                avcParameterSetCount: nil, paramSetSHA256: nil,
                primaries: nil, transfer: nil, matrix: nil, chromaLocationTop: nil,
                sampleRate: asbd?.mSampleRate, channels: asbd?.mChannelsPerFrame
            )
        }
        return FormatDescInfo(
            mediaType: mt, codec: sub, width: nil, height: nil,
            avcParameterSetCount: nil, paramSetSHA256: nil,
            primaries: nil, transfer: nil, matrix: nil, chromaLocationTop: nil,
            sampleRate: nil, channels: nil
        )
    }

    public static func inspect(url: URL, includeAudioPackets: Bool = false) async throws -> ProbeReport {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SafariumError.invalidState("probe input does not exist: \(url.path)")
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let playable = try await asset.load(.isPlayable)
        let dur = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)
        var trackReports: [ProbeTrackReport] = []

        for t in tracks {
            let mt = t.mediaType.rawValue
            let ts = try await t.load(.naturalTimeScale)
            let range = try await t.load(.timeRange)
            let fmts = try await t.load(.formatDescriptions)
            let nomFPS = t.mediaType == .video ? try await t.load(.nominalFrameRate) : nil
            let lang = try await t.load(.languageCode)
            let fmtInfos = fmts.map { formatDescInfo($0) }

            var packets: [PacketRecord] = []
            if t.mediaType == .video || (includeAudioPackets && t.mediaType == .audio) || t.mediaType == .subtitle {
                var cursorSyncMap: [(pts: CMTime, dts: CMTime, isFullSync: Bool, mayReorder: Bool)] = []
                if let cursor = t.makeSampleCursorAtFirstSampleInDecodeOrder() {
                    var more = true
                    while more {
                        let sync = cursor.currentSampleSyncInfo
                        let pts = cursor.presentationTimeStamp
                        let dts = cursor.decodeTimeStamp
                        let mayReorder = cursor.maySamplesWithLaterDecodeTimeStampsHavePresentationTimeStamps(earlierThan: cursor)
                        cursorSyncMap.append((pts, dts, sync.sampleIsFullSync.boolValue, mayReorder))
                        more = cursor.stepInDecodeOrder(byCount: 1) == 1
                    }
                }

                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: t, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                reader.add(output)
                guard reader.startReading() else {
                    throw SafariumError.encode("AVAssetReader failed: \(reader.error?.localizedDescription ?? "?")")
                }
                defer { if reader.status == .reading { reader.cancelReading() } }
                var idx = 0
                var scratchBytes: [UInt8] = []
                while autoreleasepool(invoking: { () -> Bool in
                    guard let sb = output.copyNextSampleBuffer() else { return false }
                    if sb.numSamples == 0 { return true }
                    let len = sb.dataBuffer.map { CMBlockBufferGetDataLength($0) } ?? 0
                    var hashHex = ""
                    if let db = sb.dataBuffer, len > 0 {
                        if scratchBytes.count < len {
                            scratchBytes = [UInt8](repeating: 0, count: len)
                        }
                        scratchBytes.withUnsafeMutableBytes { raw in
                            _ = CMBlockBufferCopyDataBytes(db, atOffset: 0, dataLength: len, destination: raw.baseAddress!)
                            let slice = UnsafeRawBufferPointer(start: raw.baseAddress!, count: len)
                            hashHex = SHA256.hash(data: slice).map { String(format: "%02x", $0) }.joined()
                        }
                    }
                    let pts = sb.presentationTimeStamp
                    let dts = sb.decodeTimeStamp.isValid ? sb.decodeTimeStamp : pts
                    let isFullSync: Bool
                    let mayReorder: Bool
                    if idx < cursorSyncMap.count {
                        isFullSync = cursorSyncMap[idx].isFullSync
                        mayReorder = cursorSyncMap[idx].mayReorder
                    } else {
                        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
                        let notSync = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
                        isFullSync = !notSync
                        mayReorder = false
                    }
                    packets.append(PacketRecord(
                        index: idx,
                        pts: rational(pts),
                        ptsSeconds: CMTimeGetSeconds(pts),
                        dts: rational(dts),
                        dtsSeconds: CMTimeGetSeconds(dts),
                        duration: rational(sb.duration),
                        isFullSync: isFullSync,
                        mayReorderLaterDTS: mayReorder,
                        dataBytes: len,
                        sha256: hashHex
                    ))
                    idx += 1
                    return true
                }) {}
            }
            trackReports.append(ProbeTrackReport(
                trackID: t.trackID,
                mediaType: mt,
                timeScale: ts,
                nominalFrameRate: nomFPS,
                languageCode: lang,
                start: rational(range.start),
                duration: rational(range.duration),
                durationSeconds: CMTimeGetSeconds(range.duration),
                stsdCount: fmts.count,
                formats: fmtInfos,
                packetCount: packets.count,
                packets: packets
            ))
        }

        return ProbeReport(
            file: url.path,
            playable: playable,
            duration: rational(dur),
            durationSeconds: CMTimeGetSeconds(dur),
            tracks: trackReports
        )
    }

    public static func compareVideoPackets(ref: ProbeReport, cand: ProbeReport) -> PacketCompareResult {
        guard let rv = ref.tracks.first(where: { $0.mediaType == "vide" }),
              let cv = cand.tracks.first(where: { $0.mediaType == "vide" }) else {
            return PacketCompareResult(exactMatch: false, diffCount: 1, details: ["missing video track"])
        }
        var diffs: [String] = []
        if rv.packetCount != cv.packetCount {
            diffs.append("packetCount \(rv.packetCount) != \(cv.packetCount)")
        }
        let n = min(rv.packetCount, cv.packetCount)
        var mismatchCount = abs(rv.packetCount - cv.packetCount)
        for i in 0..<n {
            let a = rv.packets[i], b = cv.packets[i]
            if a.sha256 != b.sha256 || a.pts != b.pts || a.dts != b.dts || a.duration != b.duration {
                mismatchCount += 1
                if diffs.count < 10 {
                    diffs.append("pkt[\(i)] ref=(\(a.pts),\(a.dts),\(a.sha256.prefix(12))) vs cand=(\(b.pts),\(b.dts),\(b.sha256.prefix(12)))")
                }
            }
        }
        return PacketCompareResult(exactMatch: diffs.isEmpty && mismatchCount == 0, diffCount: mismatchCount, details: diffs)
    }
}

public struct FaultEvent: Codable, Sendable {
    public let kind: String
    public let startFrame: Int
    public let endFrame: Int
    public let startSeconds: Double
    public let endSeconds: Double
    public let durationSeconds: Double
}

public struct NativeQAReport: Codable, Sendable {
    public let inputPath: String
    public let totalVideoFrames: Int
    public let hasAudioTrack: Bool
    public let blackEvents: [FaultEvent]
    public let freezeEvents: [FaultEvent]
    public let sceneCutEvents: [FaultEvent]
    public let silenceEvents: [FaultEvent]
    public let contactSheetPath: String?
    public let contactSheetWidth: Int?
    public let contactSheetHeight: Int?
    public let contactSheetBytes: Int?
    public let audioLoudnessLUFS: Double?
    public let audioLoudnessRangeLU: Double?
    public let audioTruePeakDBTP: Double?
    public let qaWallMs: Double
    public let clean: Bool
}

public enum NativeQAAnalyzer {
    public static func analyze(
        url: URL,
        contactSheetURL: URL? = nil,
        overwrite: Bool = false,
        sceneThreshold: Double = 0.20,
        silenceThresholdDB: Double = -50.0
    ) async throws -> NativeQAReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SafariumError.invalidState("qa input does not exist: \(url.path)")
        }
        guard sceneThreshold.isFinite, sceneThreshold > 0, sceneThreshold <= 1.0 else {
            throw SafariumError.invalidState("sceneThreshold must be in (0, 1]")
        }
        guard silenceThresholdDB.isFinite, silenceThresholdDB >= -120.0, silenceThresholdDB <= 0.0 else {
            throw SafariumError.invalidState("silenceThresholdDB must be in [-120, 0]")
        }
        if let sheetURL = contactSheetURL {
            try SafeFilePublisher.preflight(outputURL: sheetURL, overwrite: overwrite)
        }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let vTracks = try await asset.loadTracks(withMediaType: .video)
        let aTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !vTracks.isEmpty || !aTracks.isEmpty else {
            throw SafariumError.invalidState("qa input has no video or audio track: \(url.path)")
        }

        var frameIdx = 0
        var effectiveFPS = 30.0
        var blackEvents: [FaultEvent] = []
        var freezeEvents: [FaultEvent] = []
        var sceneEvents: [FaultEvent] = []
        var writtenSheetBytes: Int?
        var writtenSheetPath: String?
        var sheetW = 0
        var sheetH = 0

        if let vt = vTracks.first {
            let nomFPS = Double(try await vt.load(.nominalFrameRate))
            effectiveFPS = nomFPS > 0 ? nomFPS : 30.0
            let natSize = try await vt.load(.naturalSize)
            let prefTx = try await vt.load(.preferredTransform)
            let dispRect = CGRect(origin: .zero, size: natSize).applying(prefTx)
            let dispW = abs(Double(dispRect.width))
            let dispH = abs(Double(dispRect.height))
            let estimatedDur = CMTimeGetSeconds(try await asset.load(.duration))
            let approxFrames = max(1, Int((estimatedDur * effectiveFPS).rounded()))

            // 1. Video QA: decode directly to 420v so Plane 0 gives native luma without BGRA round-trip.
            let vReader = try AVAssetReader(asset: asset)
            let vOut = AVAssetReaderTrackOutput(track: vt, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            vOut.alwaysCopiesSampleData = false
            vReader.add(vOut)
            guard vReader.startReading() else {
                throw SafariumError.encode("qa video reader failed: \(vReader.error?.localizedDescription ?? "?")")
            }
            defer { if vReader.status == .reading { vReader.cancelReading() } }

            var currLuma: [Float] = []
            var prevLuma: [Float] = []
            var diffLuma: [Float] = []
            var prevPTS = 0.0
            var prevDuration = 1.0 / effectiveFPS
            var prevIsBlack = false

            var blackRunStart: Int?
            var blackRunStartSec = 0.0
            var freezeRunStart: Int?
            var freezeRunStartSec = 0.0

            var sheetTargets = Set<Int>()
            for slot in 0..<6 {
                let idx = min(max(0, approxFrames - 1), (approxFrames * (2 * slot + 1)) / 12)
                sheetTargets.insert(idx)
            }
            let tileW = 270
            let rawTileH = dispW > 0 ? Int((Double(tileW) * dispH / dispW).rounded()) : 480
            let tileH = max(2, rawTileH & ~1)
            sheetW = tileW * 6
            sheetH = tileH
            let sheetCtx: CGContext? = contactSheetURL == nil ? nil : CGContext(
                data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: sheetW * 4,
                space: Snapshot.colorSpace, bitmapInfo: Snapshot.bitmapInfo
            )
            let ciCtx = contactSheetURL != nil ? (SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])) : nil
            var sheetSlot = 0

            while autoreleasepool(invoking: { () -> Bool in
                guard let sb = vOut.copyNextSampleBuffer() else { return false }
                if sb.numSamples == 0 { return true }
                guard let pb = sb.imageBuffer else { return true }
                let ptsSec = CMTimeGetSeconds(sb.presentationTimeStamp)
                let durSec = sb.duration.isNumeric && CMTimeGetSeconds(sb.duration) > 0 ? CMTimeGetSeconds(sb.duration) : (1.0 / effectiveFPS)
                let w = CVPixelBufferGetWidthOfPlane(pb, 0)
                let h = CVPixelBufferGetHeightOfPlane(pb, 0)
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
                let count = w * h

                if currLuma.count != count {
                    currLuma = [Float](repeating: 0, count: count)
                    prevLuma = [Float](repeating: 0, count: count)
                    diffLuma = [Float](repeating: 0, count: count)
                }

                guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return true }
                if let rawBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
                    let base = rawBase.assumingMemoryBound(to: UInt8.self)
                    currLuma.withUnsafeMutableBufferPointer { dst in
                        if stride == w {
                            vDSP_vfltu8(base, 1, dst.baseAddress!, 1, vDSP_Length(count))
                        } else {
                            for y in 0..<h {
                                vDSP_vfltu8(base.advanced(by: y * stride), 1, dst.baseAddress!.advanced(by: y * w), 1, vDSP_Length(w))
                            }
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)

                var meanY: Float = 0
                currLuma.withUnsafeBufferPointer { ptr in
                    vDSP_meanv(ptr.baseAddress!, 1, &meanY, vDSP_Length(count))
                }
                let isBlack = meanY < 20.0
                if isBlack {
                    if blackRunStart == nil {
                        blackRunStart = frameIdx
                        blackRunStartSec = ptsSec
                    }
                } else if let bStart = blackRunStart {
                    if frameIdx - bStart >= 3 {
                        blackEvents.append(FaultEvent(
                            kind: "blackdetect", startFrame: bStart, endFrame: frameIdx,
                            startSeconds: blackRunStartSec, endSeconds: ptsSec,
                            durationSeconds: max(0, ptsSec - blackRunStartSec)
                        ))
                    }
                    blackRunStart = nil
                }

                if frameIdx > 0 {
                    var mad: Float = 0
                    prevLuma.withUnsafeBufferPointer { pPtr in
                        currLuma.withUnsafeBufferPointer { cPtr in
                            diffLuma.withUnsafeMutableBufferPointer { dPtr in
                                vDSP_vsub(pPtr.baseAddress!, 1, cPtr.baseAddress!, 1, dPtr.baseAddress!, 1, vDSP_Length(count))
                                vDSP_vabs(dPtr.baseAddress!, 1, dPtr.baseAddress!, 1, vDSP_Length(count))
                                vDSP_meanv(dPtr.baseAddress!, 1, &mad, vDSP_Length(count))
                            }
                        }
                    }
                    let normMAD = mad / 255.0
                    if !isBlack && !prevIsBlack && normMAD > Float(sceneThreshold) {
                        sceneEvents.append(FaultEvent(
                            kind: "scene_cut", startFrame: frameIdx, endFrame: frameIdx,
                            startSeconds: ptsSec, endSeconds: ptsSec, durationSeconds: 0
                        ))
                    }
                    let isFrozenFrame = !isBlack && mad < 0.6
                    if isFrozenFrame {
                        if freezeRunStart == nil {
                            freezeRunStart = frameIdx - 1
                            freezeRunStartSec = prevPTS
                        }
                    } else if let fStart = freezeRunStart {
                        if frameIdx - fStart >= 5 {
                            freezeEvents.append(FaultEvent(
                                kind: "freezedetect", startFrame: fStart, endFrame: frameIdx,
                                startSeconds: freezeRunStartSec, endSeconds: ptsSec,
                                durationSeconds: max(0, ptsSec - freezeRunStartSec)
                            ))
                        }
                        freezeRunStart = nil
                    }
                }

                if let sheetCtx, let ciCtx, sheetSlot < 6, (sheetTargets.contains(frameIdx) || frameIdx == 0 && sheetSlot == 0) {
                    let ciImg = SafariumSequentialVideoReader.orientedCIImage(from: pb, transform: prefTx)
                    let sx = CGFloat(tileW) / max(1.0, ciImg.extent.width)
                    let sy = CGFloat(tileH) / max(1.0, ciImg.extent.height)
                    let scaled = ciImg.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
                    if let cg = ciCtx.createCGImage(scaled, from: CGRect(x: scaled.extent.origin.x, y: scaled.extent.origin.y, width: CGFloat(tileW), height: CGFloat(tileH))) {
                        sheetCtx.draw(cg, in: CGRect(x: sheetSlot * tileW, y: 0, width: tileW, height: tileH))
                        sheetSlot += 1
                    }
                }

                swap(&prevLuma, &currLuma)
                prevPTS = ptsSec
                prevDuration = durSec
                prevIsBlack = isBlack
                frameIdx += 1
                return true
            }) {}

            guard frameIdx > 0 else {
                throw SafariumError.invalidState("qa input yielded 0 decodable video frames: \(url.path)")
            }

            let videoEndSec = prevPTS + prevDuration
            if let bStart = blackRunStart, frameIdx - bStart >= 3 {
                blackEvents.append(FaultEvent(
                    kind: "blackdetect", startFrame: bStart, endFrame: frameIdx,
                    startSeconds: blackRunStartSec, endSeconds: videoEndSec,
                    durationSeconds: max(0, videoEndSec - blackRunStartSec)
                ))
            }
            if let fStart = freezeRunStart, frameIdx - fStart >= 5 {
                freezeEvents.append(FaultEvent(
                    kind: "freezedetect", startFrame: fStart, endFrame: frameIdx,
                    startSeconds: freezeRunStartSec, endSeconds: videoEndSec,
                    durationSeconds: max(0, videoEndSec - freezeRunStartSec)
                ))
            }

            if let sheetURL = contactSheetURL, let sheetCtx, let sheetImg = sheetCtx.makeImage() {
                let staging = try SafeFilePublisher.Staging(beside: sheetURL)
                defer { staging.cleanup() }
                let tempSheet = staging.fileURL("sheet.jpg")
                guard let dest = CGImageDestinationCreateWithURL(tempSheet as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw SafariumError.encode("cannot create JPEG destination for contact sheet")
                }
                CGImageDestinationAddImage(dest, sheetImg, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
                guard CGImageDestinationFinalize(dest) else {
                    throw SafariumError.encode("CGImageDestinationFinalize failed for contact sheet")
                }
                let sz = (try? FileManager.default.attributesOfItem(atPath: tempSheet.path)[.size] as? Int) ?? 0
                try SafeFilePublisher.publish(tempURL: tempSheet, to: sheetURL, overwrite: overwrite)
                writtenSheetBytes = sz
                writtenSheetPath = sheetURL.path
            }
        } else if contactSheetURL != nil {
            throw SafariumError.invalidState("cannot write contact sheet for audio-only input: \(url.path)")
        }

        // 2. Audio QA: silencedetect (10 ms RMS hops via vDSP_rmsqv) + BS.1770-4 gated loudness, LRA & true peak.
        var silenceEvents: [FaultEvent] = []
        var audioLUFS: Double?
        var audioLRA: Double?
        var audioTP: Double?
        let hasAudio = !aTracks.isEmpty
        if let at = aTracks.first {
            let fs = 48_000.0
            let aReader = try AVAssetReader(asset: asset)
            let aOut = AVAssetReaderTrackOutput(track: at, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: fs,
                AVNumberOfChannelsKey: 1,
            ])
            aOut.alwaysCopiesSampleData = false
            aReader.add(aOut)
            guard aReader.startReading() else {
                throw SafariumError.encode("qa audio reader failed: \(aReader.error?.localizedDescription ?? "?")")
            }
            defer { if aReader.status == .reading { aReader.cancelReading() } }

            let meter = try LoudnessMeter(sampleRate: fs, channels: 1)
            var audioBuf: [Float] = []
            audioBuf.reserveCapacity(8192)
            let hop = 480 // 10 ms @ 48 kHz
            var hopIdx = 0
            var silStartSec: Double?

            while autoreleasepool(invoking: { () -> Bool in
                guard let sb = aOut.copyNextSampleBuffer() else { return false }
                if sb.numSamples == 0 { return true }
                guard let bb = sb.dataBuffer else { return true }
                let bytes = CMBlockBufferGetDataLength(bb)
                let count = bytes / 4
                guard count > 0 else { return true }
                let oldCount = audioBuf.count
                audioBuf.append(contentsOf: repeatElement(Float(0), count: count))
                audioBuf.withUnsafeMutableBytes { raw in
                    _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: bytes, destination: raw.baseAddress!.advanced(by: oldCount * 4))
                }
                audioBuf.withUnsafeBufferPointer { ptr in
                    meter.processMonoBlock(UnsafeBufferPointer(start: ptr.baseAddress! + oldCount, count: count))
                }

                var off = 0
                while off + hop <= audioBuf.count {
                    var rms: Float = 0
                    audioBuf.withUnsafeBufferPointer { ptr in
                        vDSP_rmsqv(ptr.baseAddress! + off, 1, &rms, vDSP_Length(hop))
                    }
                    let db = rms > 1e-8 ? 20.0 * log10(Double(rms)) : -160.0
                    let tSec = Double(hopIdx) * 0.010
                    if db < silenceThresholdDB {
                        if silStartSec == nil { silStartSec = tSec }
                    } else if let ss = silStartSec {
                        if tSec - ss >= 0.20 {
                            silenceEvents.append(FaultEvent(
                                kind: "silencedetect",
                                startFrame: Int((ss * effectiveFPS).rounded()),
                                endFrame: Int((tSec * effectiveFPS).rounded()),
                                startSeconds: ss, endSeconds: tSec,
                                durationSeconds: tSec - ss
                            ))
                        }
                        silStartSec = nil
                    }
                    hopIdx += 1
                    off += hop
                }
                if off > 0 { audioBuf.removeFirst(off) }
                return true
            }) {}
            let audioEndSec = Double(hopIdx) * 0.010
            if let ss = silStartSec, audioEndSec - ss >= 0.20 {
                silenceEvents.append(FaultEvent(
                    kind: "silencedetect",
                    startFrame: Int((ss * effectiveFPS).rounded()),
                    endFrame: Int((audioEndSec * effectiveFPS).rounded()),
                    startSeconds: ss, endSeconds: audioEndSec,
                    durationSeconds: audioEndSec - ss
                ))
            }
            if meter.processedFrames > 0 {
                audioLUFS = meter.gatedLUFS.isFinite ? meter.gatedLUFS : nil
                audioLRA = meter.loudnessRangeLU.isFinite ? meter.loudnessRangeLU : nil
                audioTP = meter.truePeakDBTP.isFinite ? meter.truePeakDBTP : nil
            }
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let isClean = blackEvents.isEmpty && freezeEvents.isEmpty && silenceEvents.isEmpty
        return NativeQAReport(
            inputPath: url.path,
            totalVideoFrames: frameIdx,
            hasAudioTrack: hasAudio,
            blackEvents: blackEvents,
            freezeEvents: freezeEvents,
            sceneCutEvents: sceneEvents,
            silenceEvents: silenceEvents,
            contactSheetPath: writtenSheetPath,
            contactSheetWidth: writtenSheetPath != nil ? sheetW : nil,
            contactSheetHeight: writtenSheetPath != nil ? sheetH : nil,
            contactSheetBytes: writtenSheetBytes,
            audioLoudnessLUFS: audioLUFS,
            audioLoudnessRangeLU: audioLRA,
            audioTruePeakDBTP: audioTP,
            qaWallMs: elapsedMs,
            clean: isClean
        )
    }
}
