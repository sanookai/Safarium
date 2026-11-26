@preconcurrency import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import SafariumContainers
import SafariumCore

// MARK: - Wave 18B: Surgical Closed-GOP Shot Repair Engine (Zero-Reencode Bit-Exact Passthrough)

/// Specification for surgically replacing a single defective shot time range with a repaired clip.
public struct SurgicalRepairPatch: Codable, Sendable {
    public let shotIndex: Int
    public let startSeconds: Double
    public let endSeconds: Double
    public let replacementPath: String

    public init(
        shotIndex: Int,
        startSeconds: Double,
        endSeconds: Double,
        replacementPath: String
    ) {
        self.shotIndex = shotIndex
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.replacementPath = replacementPath
    }
}

/// Cryptographic bit-exactness, conformance, and post-repair QA report for `SurgicalRepairEngine`.
public struct SurgicalRepairReport: Codable, Sendable {
    public let originalPath: String
    public let outputPath: String
    public let repairedShotCount: Int
    public let untouchedShotsPreservedBitExact: Bool
    public let untouchedVideoPacketCount: Int
    public let repairedVideoPacketCount: Int
    public let untouchedVideoPacketHash: String
    public let repairedOutputUntouchedHash: String
    public let conformancePassed: Bool
    public let remainingDefectCount: Int?
    public let elapsedMs: Double

    public init(
        originalPath: String,
        outputPath: String,
        repairedShotCount: Int,
        untouchedShotsPreservedBitExact: Bool,
        untouchedVideoPacketCount: Int,
        repairedVideoPacketCount: Int,
        untouchedVideoPacketHash: String,
        repairedOutputUntouchedHash: String,
        conformancePassed: Bool,
        remainingDefectCount: Int?,
        elapsedMs: Double
    ) {
        self.originalPath = originalPath
        self.outputPath = outputPath
        self.repairedShotCount = repairedShotCount
        self.untouchedShotsPreservedBitExact = untouchedShotsPreservedBitExact
        self.untouchedVideoPacketCount = untouchedVideoPacketCount
        self.repairedVideoPacketCount = repairedVideoPacketCount
        self.untouchedVideoPacketHash = untouchedVideoPacketHash
        self.repairedOutputUntouchedHash = repairedOutputUntouchedHash
        self.conformancePassed = conformancePassed
        self.remainingDefectCount = remainingDefectCount
        self.elapsedMs = elapsedMs
    }
}

/// Zero-reencode Closed-GOP surgical shot repair engine.
///
/// Splices repaired compressed `CMSampleBuffer` streams into defective shot ranges while copying
/// all untouched shots bit-for-bit via `AVAssetReader`/`AVAssetWriter` passthrough (`outputSettings: nil`).
/// Hashes every untouched compressed video packet before and after atomic publish via SHA-256 to
/// cryptographically prove untouched shots were never re-encoded or modified.
public enum SurgicalRepairEngine {

    private struct ReplacementAssetData {
        let patch: SurgicalRepairPatch
        let videoSamples: [CMSampleBuffer]
        let videoDuration: CMTime
        let audioSamples: [CMSampleBuffer]
        let audioFormatDescription: CMFormatDescription?
    }

    private struct PatchOutputWindow {
        let startSeconds: Double
        let endSeconds: Double
        let origStart: CMTime
        let origEnd: CMTime
        let targetStart: CMTime
        let appliedDuration: CMTime
    }

    /// Surgically replaces specified shot time windows in `originalURL` without re-encoding untouched shots.
    public static func repair(
        originalURL: URL,
        outputURL: URL,
        patches: [SurgicalRepairPatch],
        verifyConformance: Bool = true,
        verifyDefects: Bool = true
    ) async throws -> SurgicalRepairReport {
        let t0 = DispatchTime.now().uptimeNanoseconds

        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            throw SafariumError.invalidState("original media file does not exist: \(originalURL.path)")
        }

        let sortedPatches = patches.sorted { $0.startSeconds < $1.startSeconds }
        for (idx, patch) in sortedPatches.enumerated() {
            guard patch.startSeconds.isFinite, patch.endSeconds.isFinite,
                  patch.startSeconds >= 0.0, patch.endSeconds > patch.startSeconds else {
                throw SafariumError.invalidState(
                    "invalid patch range [\(patch.startSeconds), \(patch.endSeconds)) for shot \(patch.shotIndex)"
                )
            }
            if idx > 0 {
                let prevEnd = sortedPatches[idx - 1].endSeconds
                guard patch.startSeconds >= prevEnd - 0.0001 else {
                    throw SafariumError.invalidState(
                        "overlapping surgical repair patches at shot \(patch.shotIndex): \(patch.startSeconds) < \(prevEnd)"
                    )
                }
            }
            guard FileManager.default.fileExists(atPath: patch.replacementPath) else {
                throw SafariumError.invalidState("replacement clip does not exist: \(patch.replacementPath)")
            }
        }

        let outExt = outputURL.pathExtension.lowercased()
        let fileType: AVFileType = (outExt == "mov") ? .mov : .mp4

        // 1. Load original asset tracks & compressed packets (outputSettings: nil)
        let origAsset = AVURLAsset(url: originalURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
        ])
        guard let origVideoTrack = try await origAsset.loadTracks(withMediaType: .video).first else {
            throw SafariumError.invalidState("original media has no video track: \(originalURL.path)")
        }
        let origAudioTrack = try await origAsset.loadTracks(withMediaType: .audio).first

        let origVideoFmts = try await origVideoTrack.load(.formatDescriptions)
        guard let origVideoFmt = origVideoFmts.first else {
            throw SafariumError.invalidState("original video track missing format description")
        }
        let origTimeScale = try await origVideoTrack.load(.naturalTimeScale)
        let movieTimeScale: CMTimeScale = origTimeScale > 0 ? origTimeScale : 600
        let origPreferredTransform = try await origVideoTrack.load(.preferredTransform)

        let origVideoPackets = try readCompressedPackets(asset: origAsset, track: origVideoTrack)
        guard !origVideoPackets.isEmpty else {
            throw SafariumError.invalidState("original video track contains 0 packets")
        }

        var origAudioFmt: CMFormatDescription?
        var origAudioPackets: [CMSampleBuffer] = []
        if let aTrack = origAudioTrack {
            let aFmts = try await aTrack.load(.formatDescriptions)
            origAudioFmt = aFmts.first
            origAudioPackets = try readCompressedPackets(asset: origAsset, track: aTrack)
        }

        // 2. Load each replacement clip's compressed packets (outputSettings: nil)
        var replacements: [ReplacementAssetData] = []
        replacements.reserveCapacity(sortedPatches.count)
        for patch in sortedPatches {
            let repURL = URL(fileURLWithPath: patch.replacementPath)
            let repAsset = AVURLAsset(url: repURL, options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true,
            ])
            guard let repVTrack = try await repAsset.loadTracks(withMediaType: .video).first else {
                throw SafariumError.invalidState("replacement clip has no video track: \(patch.replacementPath)")
            }
            let repVPackets = try readCompressedPackets(asset: repAsset, track: repVTrack)
            guard !repVPackets.isEmpty else {
                throw SafariumError.invalidState("replacement clip contains 0 video packets: \(patch.replacementPath)")
            }
            let repAssetDur = try await repAsset.load(.duration)
            let computedDur = computePacketSpan(packets: repVPackets, fallback: repAssetDur, timescale: movieTimeScale)

            var repAPackets: [CMSampleBuffer] = []
            var repAFmt: CMFormatDescription?
            if let repATrack = try await repAsset.loadTracks(withMediaType: .audio).first {
                let fmts = try await repATrack.load(.formatDescriptions)
                repAFmt = fmts.first
                repAPackets = try readCompressedPackets(asset: repAsset, track: repATrack)
            }

            replacements.append(ReplacementAssetData(
                patch: patch,
                videoSamples: repVPackets,
                videoDuration: computedDur,
                audioSamples: repAPackets,
                audioFormatDescription: repAFmt
            ))
        }

        // 3. Splice video timeline & compute pre-write SHA-256 hash of untouched original packets
        let boundaryEps: Double = 0.002
        var untouchedHasher = SHA256()
        var untouchedVideoCount = 0
        var repairedVideoCount = 0
        var outputVideoPackets: [CMSampleBuffer] = []
        outputVideoPackets.reserveCapacity(origVideoPackets.count + 64)

        var patchWindows: [PatchOutputWindow] = []
        patchWindows.reserveCapacity(replacements.count)

        var origIdx = 0
        var cumulativeShift = CMTime.zero
        var lastVideoDTS: CMTime?
        let minVideoStep = CMTime(value: 1, timescale: max(1, movieTimeScale))

        for rep in replacements {
            let patchStartSec = rep.patch.startSeconds
            let patchEndSec = rep.patch.endSeconds

            // Emit untouched original packets strictly before this patch
            while origIdx < origVideoPackets.count {
                let pkt = origVideoPackets[origIdx]
                let ptsSec = samplePTSSeconds(pkt)
                if ptsSec >= (patchStartSec - boundaryEps) {
                    break
                }
                try updatePacketHash(pkt, hasher: &untouchedHasher)
                untouchedVideoCount += 1

                let emitted: CMSampleBuffer
                if CMTimeCompare(cumulativeShift, .zero) == 0 {
                    emitted = pkt
                } else {
                    emitted = try shiftSampleBuffer(pkt, delta: cumulativeShift)
                }
                outputVideoPackets.append(emitted)
                lastVideoDTS = effectiveDTS(emitted)
                origIdx += 1
            }

            // Consume original packets belonging to this patch window
            var firstReplacedPTS: CMTime?
            while origIdx < origVideoPackets.count {
                let pkt = origVideoPackets[origIdx]
                let ptsSec = samplePTSSeconds(pkt)
                if ptsSec >= (patchEndSec - boundaryEps) {
                    break
                }
                if firstReplacedPTS == nil {
                    firstReplacedPTS = CMSampleBufferGetPresentationTimeStamp(pkt)
                }
                origIdx += 1
            }

            let origWindowStart: CMTime
            if let firstPTS = firstReplacedPTS, firstPTS.isValid && firstPTS.isNumeric {
                origWindowStart = firstPTS
            } else {
                origWindowStart = CMTime(seconds: patchStartSec, preferredTimescale: movieTimeScale)
            }

            let origWindowEnd: CMTime
            if origIdx < origVideoPackets.count {
                let nextPTS = CMSampleBufferGetPresentationTimeStamp(origVideoPackets[origIdx])
                if nextPTS.isValid && nextPTS.isNumeric {
                    origWindowEnd = nextPTS
                } else {
                    origWindowEnd = CMTime(seconds: patchEndSec, preferredTimescale: movieTimeScale)
                }
            } else {
                origWindowEnd = CMTime(seconds: patchEndSec, preferredTimescale: movieTimeScale)
            }

            let origWindowDur = CMTimeSubtract(origWindowEnd, origWindowStart)
            var targetStart = CMTimeAdd(origWindowStart, cumulativeShift)

            // Retime and splice replacement compressed packets seamlessly while preserving strictly monotonic DTS
            let repFirstRaw = CMSampleBufferGetPresentationTimeStamp(rep.videoSamples[0])
            let repFirstPTS: CMTime = (repFirstRaw.isValid && repFirstRaw.isNumeric) ? repFirstRaw : .zero
            var repDelta = CMTimeSubtract(targetStart, repFirstPTS)

            let repFirstDTS = effectiveDTS(rep.videoSamples[0])
            if let prevDTS = lastVideoDTS {
                let candidateFirstDTS = CMTimeAdd(repFirstDTS, repDelta)
                if CMTimeCompare(candidateFirstDTS, prevDTS) <= 0 {
                    let nudge = CMTimeAdd(CMTimeSubtract(prevDTS, candidateFirstDTS), minVideoStep)
                    repDelta = CMTimeAdd(repDelta, nudge)
                    targetStart = CMTimeAdd(targetStart, nudge)
                }
            }

            var repLastDTS: CMTime?
            for repPkt in rep.videoSamples {
                let emitted: CMSampleBuffer
                if CMTimeCompare(repDelta, .zero) == 0 {
                    emitted = repPkt
                } else {
                    emitted = try shiftSampleBuffer(repPkt, delta: repDelta)
                }
                outputVideoPackets.append(emitted)
                let dts = effectiveDTS(emitted)
                lastVideoDTS = dts
                repLastDTS = dts
                repairedVideoCount += 1
            }

            let durDiff = CMTimeSubtract(rep.videoDuration, origWindowDur)
            let appliedDuration: CMTime
            if abs(CMTimeGetSeconds(durDiff)) > 0.005 {
                cumulativeShift = CMTimeAdd(cumulativeShift, durDiff)
                appliedDuration = rep.videoDuration
            } else {
                appliedDuration = origWindowDur
            }

            // Guarantee the first untouched packet after the patch has DTS strictly > last replacement DTS
            if origIdx < origVideoPackets.count, let prevDTS = repLastDTS {
                let nextOrigDTS = CMTimeAdd(effectiveDTS(origVideoPackets[origIdx]), cumulativeShift)
                if CMTimeCompare(nextOrigDTS, prevDTS) <= 0 {
                    let nudge = CMTimeAdd(CMTimeSubtract(prevDTS, nextOrigDTS), minVideoStep)
                    cumulativeShift = CMTimeAdd(cumulativeShift, nudge)
                }
            }

            let outStartSec = CMTimeGetSeconds(targetStart)
            let outEndSec = outStartSec + max(0.0, CMTimeGetSeconds(appliedDuration))
            patchWindows.append(PatchOutputWindow(
                startSeconds: outStartSec,
                endSeconds: outEndSec,
                origStart: origWindowStart,
                origEnd: origWindowEnd,
                targetStart: targetStart,
                appliedDuration: appliedDuration
            ))
        }

        // Emit remaining untouched original packets after the final patch
        while origIdx < origVideoPackets.count {
            let pkt = origVideoPackets[origIdx]
            try updatePacketHash(pkt, hasher: &untouchedHasher)
            untouchedVideoCount += 1

            let emitted: CMSampleBuffer
            if CMTimeCompare(cumulativeShift, .zero) == 0 {
                emitted = pkt
            } else {
                emitted = try shiftSampleBuffer(pkt, delta: cumulativeShift)
            }
            outputVideoPackets.append(emitted)
            lastVideoDTS = effectiveDTS(emitted)
            origIdx += 1
        }

        let untouchedHashHex = sha256Hex(untouchedHasher.finalize())

        // 4. Build passthrough audio timeline (if original has an audio track)
        var outputAudioPackets: [CMSampleBuffer] = []
        if let aFmt = origAudioFmt, !origAudioPackets.isEmpty {
            outputAudioPackets = try buildSplicedAudioPackets(
                originalPackets: origAudioPackets,
                originalFormat: aFmt,
                replacements: replacements,
                patchWindows: patchWindows,
                boundaryEps: boundaryEps
            )
        }

        // 5. Write passthrough MP4/MOV to AtomicOutputPublisher staging path and publish atomically
        let stateMachine = PipelineStateMachine(initialPhase: .idle)
        let publisher = AtomicOutputPublisher(destinationURL: outputURL, overwrite: true)

        do {
            try stateMachine.transition(to: .muxing, note: "Surgical Closed-GOP passthrough repair")
            let staging = try publisher.prepareStaging(stateMachine: stateMachine)

            let writer = try AVAssetWriter(outputURL: staging.tempURL, fileType: fileType)
            writer.movieTimeScale = movieTimeScale
            writer.shouldOptimizeForNetworkUse = true

            let videoInput = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: nil,
                sourceFormatHint: origVideoFmt
            )
            videoInput.mediaTimeScale = movieTimeScale
            videoInput.expectsMediaDataInRealTime = false
            videoInput.transform = origPreferredTransform
            guard writer.canAdd(videoInput) else {
                throw SafariumError.encode("AVAssetWriter cannot add video passthrough input")
            }
            writer.add(videoInput)

            var audioInput: AVAssetWriterInput?
            if let aFmt = origAudioFmt, !outputAudioPackets.isEmpty {
                let aIn = AVAssetWriterInput(
                    mediaType: .audio,
                    outputSettings: nil,
                    sourceFormatHint: aFmt
                )
                aIn.expectsMediaDataInRealTime = false
                if writer.canAdd(aIn) {
                    writer.add(aIn)
                    audioInput = aIn
                }
            }

            guard writer.startWriting() else {
                let msg = describeWriterError(writer)
                throw SafariumError.encode("SurgicalRepairEngine AVAssetWriter failed to start: \(msg)")
            }

            var sessionStart = CMTime.zero
            if let firstOut = outputVideoPackets.first {
                let firstDTS = effectiveDTS(firstOut)
                let firstPTS = CMSampleBufferGetPresentationTimeStamp(firstOut)
                if firstPTS.isValid && firstPTS.isNumeric {
                    sessionStart = firstPTS
                }
                if firstDTS.isValid && firstDTS.isNumeric && CMTimeCompare(firstDTS, sessionStart) < 0 {
                    sessionStart = firstDTS
                }
            }
            if let firstAudio = outputAudioPackets.first {
                let aPTS = CMSampleBufferGetPresentationTimeStamp(firstAudio)
                if aPTS.isValid && aPTS.isNumeric && CMTimeCompare(aPTS, sessionStart) < 0 {
                    sessionStart = aPTS
                }
            }
            writer.startSession(atSourceTime: sessionStart)

            // Interleaved Swift 6 Sendable-clean pump
            var vPos = 0
            var aPos = 0
            var vFinished = false
            var aFinished = (audioInput == nil)

            while !vFinished || !aFinished {
                var progressed = false

                if !vFinished && videoInput.isReadyForMoreMediaData {
                    if vPos < outputVideoPackets.count {
                        let ok = videoInput.append(outputVideoPackets[vPos])
                        guard ok else {
                            let msg = describeWriterError(writer)
                            throw SafariumError.encode("SurgicalRepairEngine video append failed at packet \(vPos): \(msg)")
                        }
                        vPos += 1
                        progressed = true
                    } else {
                        videoInput.markAsFinished()
                        vFinished = true
                        progressed = true
                    }
                }

                if !aFinished, let aIn = audioInput, aIn.isReadyForMoreMediaData {
                    if aPos < outputAudioPackets.count {
                        let ok = aIn.append(outputAudioPackets[aPos])
                        guard ok else {
                            let msg = describeWriterError(writer)
                            throw SafariumError.encode("SurgicalRepairEngine audio append failed at packet \(aPos): \(msg)")
                        }
                        aPos += 1
                        progressed = true
                    } else {
                        aIn.markAsFinished()
                        aFinished = true
                        progressed = true
                    }
                }

                if !progressed {
                    try await Task.sleep(nanoseconds: 1_000_000)
                }
            }

            await writer.finishWriting()
            guard writer.status == .completed else {
                let msg = describeWriterError(writer)
                throw SafariumError.encode("SurgicalRepairEngine AVAssetWriter finish failed: \(msg)")
            }

            try stateMachine.transition(to: .publishing, note: "AtomicOutputPublisher commit")
            _ = try publisher.commit(staging, stateMachine: stateMachine)
            try stateMachine.complete(note: "Surgical repair published")
        } catch {
            stateMachine.fail(reason: error.localizedDescription)
            throw error
        }

        // 6. Re-read published outputURL compressed packets to cryptographically prove bit-exact untouched shots
        let outAsset = AVURLAsset(url: outputURL, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
        ])
        guard let outVideoTrack = try await outAsset.loadTracks(withMediaType: .video).first else {
            throw SafariumError.encode("repaired output missing video track")
        }
        let outVideoReadBack = try readCompressedPackets(asset: outAsset, track: outVideoTrack)

        var outputUntouchedHasher = SHA256()
        var outputUntouchedCount = 0
        for pkt in outVideoReadBack {
            let ptsSec = samplePTSSeconds(pkt)
            let isInRepairedRange = patchWindows.contains { win in
                ptsSec >= (win.startSeconds - boundaryEps) && ptsSec < (win.endSeconds - boundaryEps)
            }
            if !isInRepairedRange {
                try updatePacketHash(pkt, hasher: &outputUntouchedHasher)
                outputUntouchedCount += 1
            }
        }
        let repairedOutputUntouchedHashHex = sha256Hex(outputUntouchedHasher.finalize())
        let bitExact = (outputUntouchedCount == untouchedVideoCount)
            && (untouchedHashHex == repairedOutputUntouchedHashHex)

        // 7. Optional bitstream conformance verification
        let conformancePassed: Bool
        if verifyConformance {
            let conf = try await BitstreamConformance.verifyMediaFile(
                url: outputURL,
                requireIndependentDecode: true
            )
            conformancePassed = conf.passed
        } else {
            conformancePassed = true
        }

        // 8. Optional post-repair QA defect inspection
        let remainingDefectCount: Int?
        if verifyDefects {
            let qa = try await VideoDefectInspector.inspect(url: outputURL)
            remainingDefectCount = qa.defectCount
        } else {
            remainingDefectCount = nil
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0
        return SurgicalRepairReport(
            originalPath: originalURL.path,
            outputPath: outputURL.path,
            repairedShotCount: sortedPatches.count,
            untouchedShotsPreservedBitExact: bitExact,
            untouchedVideoPacketCount: untouchedVideoCount,
            repairedVideoPacketCount: repairedVideoCount,
            untouchedVideoPacketHash: untouchedHashHex,
            repairedOutputUntouchedHash: repairedOutputUntouchedHashHex,
            conformancePassed: conformancePassed,
            remainingDefectCount: remainingDefectCount,
            elapsedMs: round4(elapsedMs)
        )
    }

    // MARK: - Compressed Packet Helpers

    private static func readCompressedPackets(
        asset: AVURLAsset,
        track: AVAssetTrack
    ) throws -> [CMSampleBuffer] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else {
            throw SafariumError.invalidState("AVAssetReader cannot add passthrough track output")
        }
        reader.add(output)
        guard reader.startReading() else {
            let msg = reader.error?.localizedDescription ?? "reader start failed"
            throw SafariumError.encode("AVAssetReader compressed read start failed: \(msg)")
        }

        var packets: [CMSampleBuffer] = []
        while let sb = output.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sb) == 0 {
                continue
            }
            packets.append(sb)
        }

        if reader.status == .failed {
            let msg = reader.error?.localizedDescription ?? "reader failed"
            throw SafariumError.encode("AVAssetReader compressed read failed: \(msg)")
        }
        return packets
    }

    private static func buildSplicedAudioPackets(
        originalPackets: [CMSampleBuffer],
        originalFormat: CMFormatDescription,
        replacements: [ReplacementAssetData],
        patchWindows: [PatchOutputWindow],
        boundaryEps: Double
    ) throws -> [CMSampleBuffer] {
        var out: [CMSampleBuffer] = []
        out.reserveCapacity(originalPackets.count)

        var origIdx = 0
        var audioShift = CMTime.zero
        var lastAudioPTS: CMTime?

        func appendIfMonotonic(_ sb: CMSampleBuffer) {
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            if let prev = lastAudioPTS, pts.isValid && pts.isNumeric {
                if CMTimeCompare(pts, prev) <= 0 {
                    return
                }
            }
            out.append(sb)
            if pts.isValid && pts.isNumeric {
                lastAudioPTS = pts
            }
        }

        for (i, rep) in replacements.enumerated() {
            let win = patchWindows[i]
            let patchStartSec = rep.patch.startSeconds
            let patchEndSec = rep.patch.endSeconds

            // Copy original audio before patch
            while origIdx < originalPackets.count {
                let pkt = originalPackets[origIdx]
                let ptsSec = samplePTSSeconds(pkt)
                if ptsSec >= (patchStartSec - boundaryEps) {
                    break
                }
                let emitted: CMSampleBuffer
                if CMTimeCompare(audioShift, .zero) == 0 {
                    emitted = pkt
                } else {
                    emitted = try shiftSampleBuffer(pkt, delta: audioShift)
                }
                appendIfMonotonic(emitted)
                origIdx += 1
            }

            let hasMatchingRepAudio: Bool
            if let repAFmt = rep.audioFormatDescription, !rep.audioSamples.isEmpty {
                hasMatchingRepAudio = CMFormatDescriptionEqual(repAFmt, otherFormatDescription: originalFormat)
            } else {
                hasMatchingRepAudio = false
            }

            if hasMatchingRepAudio {
                // Skip replaced original audio packets
                while origIdx < originalPackets.count {
                    let pkt = originalPackets[origIdx]
                    let ptsSec = samplePTSSeconds(pkt)
                    if ptsSec >= (patchEndSec - boundaryEps) {
                        break
                    }
                    origIdx += 1
                }
                // Splice replacement audio packets clamped strictly within the patch window
                let repFirstRaw = CMSampleBufferGetPresentationTimeStamp(rep.audioSamples[0])
                let repFirstPTS: CMTime = (repFirstRaw.isValid && repFirstRaw.isNumeric) ? repFirstRaw : .zero
                let repDelta = CMTimeSubtract(win.targetStart, repFirstPTS)
                let windowEndLimit = CMTimeAdd(win.targetStart, win.appliedDuration)
                for aPkt in rep.audioSamples {
                    let emitted: CMSampleBuffer
                    if CMTimeCompare(repDelta, .zero) == 0 {
                        emitted = aPkt
                    } else {
                        emitted = try shiftSampleBuffer(aPkt, delta: repDelta)
                    }
                    let ePTS = CMSampleBufferGetPresentationTimeStamp(emitted)
                    if ePTS.isValid && ePTS.isNumeric && CMTimeCompare(ePTS, windowEndLimit) >= 0 {
                        continue
                    }
                    appendIfMonotonic(emitted)
                }
            } else {
                // Keep original continuous audio bed through the video-only patch
                while origIdx < originalPackets.count {
                    let pkt = originalPackets[origIdx]
                    let ptsSec = samplePTSSeconds(pkt)
                    if ptsSec >= (patchEndSec - boundaryEps) {
                        break
                    }
                    let emitted: CMSampleBuffer
                    if CMTimeCompare(audioShift, .zero) == 0 {
                        emitted = pkt
                    } else {
                        emitted = try shiftSampleBuffer(pkt, delta: audioShift)
                    }
                    appendIfMonotonic(emitted)
                    origIdx += 1
                }
            }

            let origDur = CMTimeSubtract(win.origEnd, win.origStart)
            let diff = CMTimeSubtract(win.appliedDuration, origDur)
            if abs(CMTimeGetSeconds(diff)) > 0.005 {
                audioShift = CMTimeAdd(audioShift, diff)
            }
        }

        while origIdx < originalPackets.count {
            let pkt = originalPackets[origIdx]
            let emitted: CMSampleBuffer
            if CMTimeCompare(audioShift, .zero) == 0 {
                emitted = pkt
            } else {
                emitted = try shiftSampleBuffer(pkt, delta: audioShift)
            }
            appendIfMonotonic(emitted)
            origIdx += 1
        }

        return out
    }

    private static func effectiveDTS(_ sb: CMSampleBuffer) -> CMTime {
        let dts = CMSampleBufferGetDecodeTimeStamp(sb)
        if dts.isValid && dts.isNumeric {
            return dts
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if pts.isValid && pts.isNumeric {
            return pts
        }
        return .zero
    }

    private static func describeWriterError(_ writer: AVAssetWriter) -> String {
        guard let err = writer.error as NSError? else {
            return "status=\(writer.status.rawValue)"
        }
        var parts = ["\(err.domain)(\(err.code)): \(err.localizedDescription)"]
        if let reason = err.localizedFailureReason, !reason.isEmpty {
            parts.append("reason=\(reason)")
        }
        if let underlying = err.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying=\(underlying.domain)(\(underlying.code)): \(underlying.localizedDescription)")
        }
        return parts.joined(separator: " | ")
    }

    private static func samplePTSSeconds(_ sb: CMSampleBuffer) -> Double {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        if pts.isValid && pts.isNumeric {
            return CMTimeGetSeconds(pts)
        }
        return 0.0
    }

    private static func computePacketSpan(
        packets: [CMSampleBuffer],
        fallback: CMTime,
        timescale: CMTimeScale
    ) -> CMTime {
        guard let first = packets.first, let last = packets.last else {
            return fallback
        }
        let firstPTS = CMSampleBufferGetPresentationTimeStamp(first)
        let lastPTS = CMSampleBufferGetPresentationTimeStamp(last)
        let lastDur = CMSampleBufferGetDuration(last)
        if firstPTS.isValid && firstPTS.isNumeric && lastPTS.isValid && lastPTS.isNumeric {
            let tailDur: CMTime
            if lastDur.isValid && lastDur.isNumeric && CMTimeGetSeconds(lastDur) > 0.0 {
                tailDur = lastDur
            } else if packets.count >= 2 {
                let prevPTS = CMSampleBufferGetPresentationTimeStamp(packets[packets.count - 2])
                let step = CMTimeSubtract(lastPTS, prevPTS)
                tailDur = (step.isValid && CMTimeGetSeconds(step) > 0.0)
                    ? step
                    : CMTime(value: 1, timescale: max(1, timescale))
            } else {
                tailDur = fallback
            }
            let endTime = CMTimeAdd(lastPTS, tailDur)
            let span = CMTimeSubtract(endTime, firstPTS)
            if span.isValid && span.isNumeric && CMTimeGetSeconds(span) > 0.0 {
                return span
            }
        }
        return fallback
    }

    private static func shiftSampleBuffer(_ sb: CMSampleBuffer, delta: CMTime) throws -> CMSampleBuffer {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(1, count))
        let st1 = CMSampleBufferGetSampleTimingInfoArray(
            sb,
            entryCount: timings.count,
            arrayToFill: &timings,
            entriesNeededOut: &count
        )
        guard st1 == noErr else {
            throw SafariumError.encode("CMSampleBufferGetSampleTimingInfoArray failed (\(st1))")
        }
        for i in 0..<count {
            if timings[i].presentationTimeStamp.isValid {
                timings[i].presentationTimeStamp = CMTimeAdd(timings[i].presentationTimeStamp, delta)
            }
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp = CMTimeAdd(timings[i].decodeTimeStamp, delta)
            }
        }
        var copy: CMSampleBuffer?
        let st2 = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sb,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &copy
        )
        guard st2 == noErr, let shifted = copy else {
            throw SafariumError.encode("CMSampleBufferCreateCopyWithNewTiming failed (\(st2))")
        }
        return shifted
    }

    /// Updates `hasher` with an 8-byte big-endian length prefix followed by the exact compressed packet payload bytes.
    private static func updatePacketHash(_ sb: CMSampleBuffer, hasher: inout SHA256) throws {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sb) else {
            var zeroLen = UInt64(0).bigEndian
            withUnsafeBytes(of: &zeroLen) { raw in
                hasher.update(bufferPointer: raw)
            }
            return
        }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        var lenBE = UInt64(length).bigEndian
        withUnsafeBytes(of: &lenBE) { raw in
            hasher.update(bufferPointer: raw)
        }
        guard length > 0 else { return }

        var payload = [UInt8](repeating: 0, count: length)
        let status = payload.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: base
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw SafariumError.encode("CMBlockBufferCopyDataBytes failed (\(status))")
        }
        payload.withUnsafeBytes { raw in
            hasher.update(bufferPointer: raw)
        }
    }

    private static func sha256Hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func round4(_ value: Double) -> Double {
        guard value.isFinite else { return 0.0 }
        return (value * 10_000.0).rounded() / 10_000.0
    }
}
