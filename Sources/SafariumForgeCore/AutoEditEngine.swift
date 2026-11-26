import Accelerate
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SafariumCore

// MARK: - Wave 15C: Auto-Highlight & Silence-Cut Engine

/// A time segment selected to keep in an auto-edited timeline.
public struct KeepSegment: Codable, Sendable, Equatable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let durationSeconds: Double
    public let reason: String
    public let score: Double

    public init(
        startSeconds: Double,
        endSeconds: Double,
        durationSeconds: Double,
        reason: String,
        score: Double
    ) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.durationSeconds = durationSeconds
        self.reason = reason
        self.score = score
    }
}

/// Configuration for silence detection and dead-air removal.
public struct AutoSilenceCutConfig: Codable, Sendable {
    public var silenceThresholdDB: Double
    public var minSilenceSeconds: Double
    public var paddingSeconds: Double
    public var crossfadeSeconds: Double
    public var bitrate: Int?

    public init(
        silenceThresholdDB: Double = -38.0,
        minSilenceSeconds: Double = 0.65,
        paddingSeconds: Double = 0.12,
        crossfadeSeconds: Double = 0.02,
        bitrate: Int? = nil
    ) {
        self.silenceThresholdDB = silenceThresholdDB
        self.minSilenceSeconds = minSilenceSeconds
        self.paddingSeconds = paddingSeconds
        self.crossfadeSeconds = crossfadeSeconds
        self.bitrate = bitrate
    }
}

/// Report returned by `AutoEditEngine` silence-cut and highlight operations.
public struct AutoEditReport: Codable, Sendable {
    public let mode: String
    public let inputPath: String
    public let outputPath: String?
    public let originalDurationSeconds: Double
    public let editedDurationSeconds: Double
    public let removedSeconds: Double
    public let segments: [KeepSegment]
    public let elapsedMs: Double

    public init(
        mode: String,
        inputPath: String,
        outputPath: String?,
        originalDurationSeconds: Double,
        editedDurationSeconds: Double,
        removedSeconds: Double,
        segments: [KeepSegment],
        elapsedMs: Double
    ) {
        self.mode = mode
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.originalDurationSeconds = originalDurationSeconds
        self.editedDurationSeconds = editedDurationSeconds
        self.removedSeconds = removedSeconds
        self.segments = segments
        self.elapsedMs = elapsedMs
    }
}

/// Configuration for multi-modal highlight planning and reel extraction.
public struct AutoHighlightConfig: Codable, Sendable {
    public var targetClipDurationSeconds: Double
    public var maxClips: Int
    public var windowStepSeconds: Double
    public var audioWeight: Double
    public var motionWeight: Double
    public var visualWeight: Double
    public var bitrate: Int?

    public init(
        targetClipDurationSeconds: Double = 15.0,
        maxClips: Int = 3,
        windowStepSeconds: Double = 1.0,
        audioWeight: Double = 0.45,
        motionWeight: Double = 0.35,
        visualWeight: Double = 0.20,
        bitrate: Int? = nil
    ) {
        self.targetClipDurationSeconds = targetClipDurationSeconds
        self.maxClips = maxClips
        self.windowStepSeconds = windowStepSeconds
        self.audioWeight = audioWeight
        self.motionWeight = motionWeight
        self.visualWeight = visualWeight
        self.bitrate = bitrate
    }
}

/// Native Apple Silicon Auto-Highlight & Silence-Cut editing engine
/// (`AVFoundation`, `Accelerate`, `CoreMedia`, `CoreVideo`, `SPECAnalyzer`).
public enum AutoEditEngine {

    private static let analysisSampleRate: Double = 48_000.0
    private static let editTimescale: CMTimeScale = 60_000

    // MARK: - 1. Speech / Silence Detection

    /// Reads mono PCM audio via `AVAssetReader`, computes 20ms RMS dBFS windows via `vDSP`,
    /// detects silent spans `>= minSilenceSeconds`, and returns merged padded speech segments.
    public static func detectSpeechSegments(
        inputURL: URL,
        config: AutoSilenceCutConfig = AutoSilenceCutConfig()
    ) async throws -> (totalDuration: Double, keep: [KeepSegment]) {
        try SafeFilePublisher.assertRegularReadableFile(inputURL)
        let asset = AVURLAsset(url: inputURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let cmDuration = try await asset.load(.duration)
        let totalDuration = max(0.0, CMTimeGetSeconds(cmDuration))
        guard totalDuration > 0.01 else {
            return (0.0, [])
        }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            let full = KeepSegment(
                startSeconds: 0.0,
                endSeconds: totalDuration,
                durationSeconds: totalDuration,
                reason: "no_audio_track",
                score: 1.0
            )
            return (totalDuration, [full])
        }

        let windowSec = 0.020
        let windowDBs = try readAudioWindowDBFS(
            asset: asset,
            audioTrack: audioTrack,
            windowSeconds: windowSec
        )
        guard !windowDBs.isEmpty else {
            let full = KeepSegment(
                startSeconds: 0.0,
                endSeconds: totalDuration,
                durationSeconds: totalDuration,
                reason: "empty_audio_pcm",
                score: 1.0
            )
            return (totalDuration, [full])
        }

        let thresholdDB = config.silenceThresholdDB
        let minSilence = max(0.05, config.minSilenceSeconds)
        let padding = max(0.0, config.paddingSeconds)

        // Identify all long silent runs (>= minSilenceSeconds)
        var longSilences: [(start: Double, end: Double)] = []
        var runStartIdx: Int?
        for idx in 0..<windowDBs.count {
            let isSilent = windowDBs[idx] < thresholdDB
            if isSilent {
                if runStartIdx == nil {
                    runStartIdx = idx
                }
            } else if let sIdx = runStartIdx {
                let sTime = Double(sIdx) * windowSec
                let eTime = min(totalDuration, Double(idx) * windowSec)
                if (eTime - sTime) >= minSilence {
                    longSilences.append((start: sTime, end: eTime))
                }
                runStartIdx = nil
            }
        }
        if let sIdx = runStartIdx {
            let sTime = Double(sIdx) * windowSec
            let eTime = totalDuration
            if (eTime - sTime) >= minSilence {
                longSilences.append((start: sTime, end: eTime))
            }
        }

        // Speech islands are the complements of long silent spans
        var rawSpeech: [(start: Double, end: Double)] = []
        var cursor = 0.0
        for sil in longSilences {
            if sil.start > cursor + 0.01 {
                rawSpeech.append((start: cursor, end: sil.start))
            }
            cursor = max(cursor, sil.end)
        }
        if totalDuration > cursor + 0.01 {
            rawSpeech.append((start: cursor, end: totalDuration))
        }

        if rawSpeech.isEmpty {
            return (totalDuration, [])
        }

        // Expand each speech island by paddingSeconds and merge overlaps
        var padded: [(start: Double, end: Double)] = []
        padded.reserveCapacity(rawSpeech.count)
        for seg in rawSpeech {
            let s = max(0.0, seg.start - padding)
            let e = min(totalDuration, seg.end + padding)
            if e > s + 0.01 {
                padded.append((start: s, end: e))
            }
        }

        var merged: [(start: Double, end: Double)] = []
        for seg in padded {
            if let last = merged.last, seg.start <= last.end + 0.005 {
                let updatedEnd = max(last.end, seg.end)
                merged[merged.count - 1] = (start: last.start, end: updatedEnd)
            } else {
                merged.append(seg)
            }
        }

        // Convert merged ranges into scored KeepSegments
        var keepSegments: [KeepSegment] = []
        keepSegments.reserveCapacity(merged.count)
        for seg in merged {
            let startIdx = max(0, min(windowDBs.count - 1, Int((seg.start / windowSec).rounded(.down))))
            let endIdx = max(startIdx + 1, min(windowDBs.count, Int((seg.end / windowSec).rounded(.up))))
            var sumDB = 0.0
            var count = 0
            for i in startIdx..<endIdx {
                sumDB += max(-90.0, windowDBs[i])
                count += 1
            }
            let avgDB = count > 0 ? (sumDB / Double(count)) : -60.0
            let normScore = clamp01((avgDB + 60.0) / 54.0)
            let dur = max(0.0, seg.end - seg.start)
            keepSegments.append(KeepSegment(
                startSeconds: seg.start,
                endSeconds: seg.end,
                durationSeconds: dur,
                reason: "speech_active",
                score: normScore
            ))
        }

        return (totalDuration, keepSegments)
    }

    // MARK: - 2. Auto Silence-Cut

    /// Detects dead-air silence spans and, if `outputURL` is provided, exports a tightened MP4
    /// using `AVMutableComposition` + smooth audio volume ramps + native `AVAssetWriter` (0% FFmpeg).
    public static func cutSilence(
        inputURL: URL,
        outputURL: URL?,
        config: AutoSilenceCutConfig = AutoSilenceCutConfig()
    ) async throws -> AutoEditReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let detected = try await detectSpeechSegments(inputURL: inputURL, config: config)
        let originalDuration = detected.totalDuration
        let keep = detected.keep

        let plannedEditedDuration = keep.reduce(0.0) { $0 + $1.durationSeconds }
        let removedSeconds = max(0.0, originalDuration - plannedEditedDuration)

        if let outURL = outputURL {
            guard !keep.isEmpty else {
                throw SafariumError.invalidState("AutoEditEngine.cutSilence: entire input is silent (0 keep segments)")
            }
            let actualEditedDuration = try await exportSegments(
                inputURL: inputURL,
                outputURL: outURL,
                segments: keep,
                crossfadeSeconds: config.crossfadeSeconds,
                bitrate: config.bitrate
            )
            let finalEdited = actualEditedDuration > 0.01 ? actualEditedDuration : plannedEditedDuration
            let finalRemoved = max(0.0, originalDuration - finalEdited)
            let t1 = DispatchTime.now().uptimeNanoseconds
            let elapsedMs = Double(t1 - t0) / 1_000_000.0
            return AutoEditReport(
                mode: "silence_cut_export",
                inputPath: inputURL.path,
                outputPath: outURL.path,
                originalDurationSeconds: originalDuration,
                editedDurationSeconds: finalEdited,
                removedSeconds: finalRemoved,
                segments: keep,
                elapsedMs: elapsedMs
            )
        }

        let t1 = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = Double(t1 - t0) / 1_000_000.0
        return AutoEditReport(
            mode: "silence_cut_plan",
            inputPath: inputURL.path,
            outputPath: nil,
            originalDurationSeconds: originalDuration,
            editedDurationSeconds: plannedEditedDuration,
            removedSeconds: removedSeconds,
            segments: keep,
            elapsedMs: elapsedMs
        )
    }

    // MARK: - 3. Multi-Modal Highlight Planning & Extraction

    private struct CandidateWindow: Sendable {
        let start: Double
        let end: Double
        let score: Double
        let audioScore: Double
        let motionScore: Double
        let visualScore: Double
    }

    /// Fuses per-window audio RMS energy + `SPECAnalyzer` / frame-diff motion energy +
    /// brightness/contrast visual energy to pick the top non-overlapping `maxClips` highlight windows.
    public static func planHighlights(
        inputURL: URL,
        config: AutoHighlightConfig = AutoHighlightConfig()
    ) async throws -> AutoEditReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(inputURL)

        let asset = AVURLAsset(url: inputURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let cmDuration = try await asset.load(.duration)
        let totalDuration = max(0.0, CMTimeGetSeconds(cmDuration))
        guard totalDuration > 0.05 else {
            throw SafariumError.invalidState("AutoEditEngine.planHighlights: input duration too short (\(totalDuration)s)")
        }

        let binSec = 0.25
        let binCount = max(1, Int((totalDuration / binSec).rounded(.up)))

        // 1. Audio energy per bin
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        var audioEnergy = [Double](repeating: 0.0, count: binCount)
        if let aTrack = audioTrack {
            let dbBins = try readAudioWindowDBFS(
                asset: asset,
                audioTrack: aTrack,
                windowSeconds: binSec
            )
            var rawAbs = [Double](repeating: 0.0, count: binCount)
            var maxAbs = 0.0
            for i in 0..<min(binCount, dbBins.count) {
                let v = clamp01((dbBins[i] + 60.0) / 54.0)
                rawAbs[i] = v
                if v > maxAbs { maxAbs = v }
            }
            for i in 0..<binCount {
                let rel = maxAbs > 1e-6 ? (rawAbs[i] / maxAbs) : 0.0
                audioEnergy[i] = clamp01(0.70 * rawAbs[i] + 0.30 * rel)
            }
        }

        // 2. Video motion (frame-diff MAD) & visual (contrast + exposure) per bin
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        var motionEnergy = [Double](repeating: 0.0, count: binCount)
        var visualEnergy = [Double](repeating: 0.0, count: binCount)
        if let vTrack = videoTrack {
            let videoMetrics = try computeVideoBinEnergies(
                asset: asset,
                videoTrack: vTrack,
                binSeconds: binSec,
                binCount: binCount
            )
            motionEnergy = videoMetrics.motion
            visualEnergy = videoMetrics.visual

            // Blend shot-level SPECAnalyzer perceptual complexity when available
            if let sidecar = try? await SPECAnalyzer.analyze(
                inputURL: inputURL,
                enableVisionMasks: false,
                maxSampleFrames: 120
            ) {
                for shot in sidecar.shots {
                    let sBin = max(0, min(binCount - 1, Int((shot.startSeconds / binSec).rounded(.down))))
                    let eBin = max(sBin + 1, min(binCount, Int((shot.endSeconds / binSec).rounded(.up))))
                    let specMotion = clamp01(0.5 * shot.temporalComplexity + 0.5 * shot.motionMagnitude)
                    let specVisual = clamp01(shot.spatialComplexity)
                    for b in sBin..<eBin {
                        motionEnergy[b] = clamp01(0.85 * motionEnergy[b] + 0.15 * specMotion)
                        visualEnergy[b] = clamp01(0.85 * visualEnergy[b] + 0.15 * specVisual)
                    }
                }
            }
        }

        // Normalize weights
        let wA = max(0.0, config.audioWeight)
        let wM = max(0.0, config.motionWeight)
        let wV = max(0.0, config.visualWeight)
        let wSum = wA + wM + wV
        let normA = wSum > 1e-6 ? (wA / wSum) : 0.45
        let normM = wSum > 1e-6 ? (wM / wSum) : 0.35
        let normV = wSum > 1e-6 ? (wV / wSum) : 0.20

        let clipDur = min(max(0.25, config.targetClipDurationSeconds), totalDuration)
        let stepSec = max(0.1, config.windowStepSeconds)
        let maxClips = max(1, config.maxClips)

        // Generate candidate sliding windows
        var candidateStarts: [Double] = []
        var curStart = 0.0
        while curStart + clipDur <= totalDuration + 1e-4 {
            candidateStarts.append(curStart)
            curStart += stepSec
            if candidateStarts.count > 10_000 { break }
        }
        let tailStart = max(0.0, totalDuration - clipDur)
        if let lastStart = candidateStarts.last {
            if abs(tailStart - lastStart) > 0.05 {
                candidateStarts.append(tailStart)
            }
        } else {
            candidateStarts.append(0.0)
        }

        var candidates: [CandidateWindow] = []
        candidates.reserveCapacity(candidateStarts.count)
        for start in candidateStarts {
            let end = min(totalDuration, start + clipDur)
            let sBin = max(0, min(binCount - 1, Int((start / binSec).rounded(.down))))
            let eBin = max(sBin + 1, min(binCount, Int((end / binSec).rounded(.up))))
            var sumA = 0.0
            var sumM = 0.0
            var sumV = 0.0
            var cnt = 0
            for b in sBin..<eBin {
                sumA += audioEnergy[b]
                sumM += motionEnergy[b]
                sumV += visualEnergy[b]
                cnt += 1
            }
            let denom = Double(max(1, cnt))
            let avgA = sumA / denom
            let avgM = sumM / denom
            let avgV = sumV / denom
            let fused = normA * avgA + normM * avgM + normV * avgV
            candidates.append(CandidateWindow(
                start: start,
                end: end,
                score: fused,
                audioScore: avgA,
                motionScore: avgM,
                visualScore: avgV
            ))
        }

        // Greedy non-overlapping top-K selection
        let ranked = candidates.sorted { lhs, rhs in
            if abs(lhs.score - rhs.score) > 1e-9 {
                return lhs.score > rhs.score
            }
            return lhs.start < rhs.start
        }

        var picked: [(rank: Int, window: CandidateWindow)] = []
        for cand in ranked {
            if picked.count >= maxClips { break }
            let overlaps = picked.contains { existing in
                let w = existing.window
                return !(cand.end <= w.start + 1e-4 || cand.start >= w.end - 1e-4)
            }
            if !overlaps {
                picked.append((rank: picked.count + 1, window: cand))
            }
        }

        // Order selected highlights chronologically for smooth reel playback
        let chronological = picked.sorted { $0.window.start < $1.window.start }
        let segments: [KeepSegment] = chronological.map { item in
            let w = item.window
            let aStr = String(format: "%.2f", w.audioScore)
            let mStr = String(format: "%.2f", w.motionScore)
            let vStr = String(format: "%.2f", w.visualScore)
            let reason = "highlight_rank_\(item.rank) audio=\(aStr) motion=\(mStr) visual=\(vStr)"
            return KeepSegment(
                startSeconds: w.start,
                endSeconds: w.end,
                durationSeconds: max(0.0, w.end - w.start),
                reason: reason,
                score: w.score
            )
        }

        let editedDuration = segments.reduce(0.0) { $0 + $1.durationSeconds }
        let removedSeconds = max(0.0, totalDuration - editedDuration)
        let t1 = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = Double(t1 - t0) / 1_000_000.0

        return AutoEditReport(
            mode: "highlights_plan",
            inputPath: inputURL.path,
            outputPath: nil,
            originalDurationSeconds: totalDuration,
            editedDurationSeconds: editedDuration,
            removedSeconds: removedSeconds,
            segments: segments,
            elapsedMs: elapsedMs
        )
    }

    /// Plans top highlight windows and exports a concatenated highlight reel MP4 cleanly.
    public static func extractHighlights(
        inputURL: URL,
        outputURL: URL,
        config: AutoHighlightConfig = AutoHighlightConfig()
    ) async throws -> AutoEditReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let plan = try await planHighlights(inputURL: inputURL, config: config)
        guard !plan.segments.isEmpty else {
            throw SafariumError.invalidState("AutoEditEngine.extractHighlights: no highlight segments found")
        }

        let actualEdited = try await exportSegments(
            inputURL: inputURL,
            outputURL: outputURL,
            segments: plan.segments,
            crossfadeSeconds: 0.02,
            bitrate: config.bitrate
        )

        let editedDuration = actualEdited > 0.01 ? actualEdited : plan.editedDurationSeconds
        let removedSeconds = max(0.0, plan.originalDurationSeconds - editedDuration)
        let t1 = DispatchTime.now().uptimeNanoseconds
        let elapsedMs = Double(t1 - t0) / 1_000_000.0

        return AutoEditReport(
            mode: "highlights_export",
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            originalDurationSeconds: plan.originalDurationSeconds,
            editedDurationSeconds: editedDuration,
            removedSeconds: removedSeconds,
            segments: plan.segments,
            elapsedMs: elapsedMs
        )
    }

    // MARK: - Audio PCM Analysis Helpers

    private static func clamp01(_ v: Double) -> Double {
        if !v.isFinite { return 0.0 }
        if v < 0.0 { return 0.0 }
        if v > 1.0 { return 1.0 }
        return v
    }

    private static func readAudioWindowDBFS(
        asset: AVURLAsset,
        audioTrack: AVAssetTrack,
        windowSeconds: Double
    ) throws -> [Double] {
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: analysisSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw SafariumError.encode("AutoEditEngine: cannot add audio reader output")
        }
        reader.add(output)
        guard reader.startReading() else {
            let msg = reader.error?.localizedDescription ?? "unknown"
            throw SafariumError.encode("AutoEditEngine: audio reader start failed: \(msg)")
        }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }

        let samplesPerWindow = max(64, Int((analysisSampleRate * windowSeconds).rounded()))
        var pending: [Float] = []
        pending.reserveCapacity(samplesPerWindow * 4)
        var results: [Double] = []
        var scratchBytes: [UInt8] = []

        while let sb = autoreleasepool(invoking: { output.copyNextSampleBuffer() }) {
            guard let blockBuf = CMSampleBufferGetDataBuffer(sb) else { continue }
            let byteCount = CMBlockBufferGetDataLength(blockBuf)
            if byteCount <= 0 { continue }

            let floatCount = byteCount / MemoryLayout<Float>.size
            if floatCount <= 0 { continue }

            if CMBlockBufferIsRangeContiguous(blockBuf, atOffset: 0, length: byteCount) {
                var lengthAtOffset = 0
                var totalLength = 0
                var dataPtr: UnsafeMutablePointer<CChar>?
                let status = CMBlockBufferGetDataPointer(
                    blockBuf,
                    atOffset: 0,
                    lengthAtOffsetOut: &lengthAtOffset,
                    totalLengthOut: &totalLength,
                    dataPointerOut: &dataPtr
                )
                if status == kCMBlockBufferNoErr, let ptr = dataPtr {
                    ptr.withMemoryRebound(to: Float.self, capacity: floatCount) { fPtr in
                        let buf = UnsafeBufferPointer(start: fPtr, count: floatCount)
                        pending.append(contentsOf: buf)
                    }
                }
            } else {
                if scratchBytes.count < byteCount {
                    scratchBytes = [UInt8](repeating: 0, count: byteCount)
                }
                let copyStatus = scratchBytes.withUnsafeMutableBytes { raw -> OSStatus in
                    guard let base = raw.baseAddress else { return -1 }
                    return CMBlockBufferCopyDataBytes(blockBuf, atOffset: 0, dataLength: byteCount, destination: base)
                }
                if copyStatus == kCMBlockBufferNoErr {
                    scratchBytes.withUnsafeBytes { raw in
                        let fBuf = raw.bindMemory(to: Float.self)
                        pending.append(contentsOf: fBuf.prefix(floatCount))
                    }
                }
            }

            var consumed = 0
            while pending.count - consumed >= samplesPerWindow {
                let db = computeRMSdBFS(samples: pending, offset: consumed, count: samplesPerWindow)
                results.append(db)
                consumed += samplesPerWindow
            }
            if consumed > 0 {
                pending.removeFirst(consumed)
            }
        }

        if !pending.isEmpty {
            let db = computeRMSdBFS(samples: pending, offset: 0, count: pending.count)
            results.append(db)
        }

        return results
    }

    private static func computeRMSdBFS(samples: [Float], offset: Int, count: Int) -> Double {
        guard count > 0 else { return -120.0 }
        var rms: Float = 0.0
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            vDSP_rmsqv(base.advanced(by: offset), 1, &rms, vDSP_Length(count))
        }
        let rmsD = Double(rms)
        if !rmsD.isFinite || rmsD <= 1e-6 {
            return -120.0
        }
        return 20.0 * log10(rmsD)
    }

    // MARK: - Video Motion & Visual Energy Analysis

    private struct VideoBinEnergies: Sendable {
        let motion: [Double]
        let visual: [Double]
    }

    private static func computeVideoBinEnergies(
        asset: AVURLAsset,
        videoTrack: AVAssetTrack,
        binSeconds: Double,
        binCount: Int
    ) throws -> VideoBinEnergies {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw SafariumError.encode("AutoEditEngine: cannot add video reader output")
        }
        reader.add(output)
        guard reader.startReading() else {
            let msg = reader.error?.localizedDescription ?? "unknown"
            throw SafariumError.encode("AutoEditEngine: video reader start failed: \(msg)")
        }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }

        var motionSum = [Double](repeating: 0.0, count: binCount)
        var motionCnt = [Int](repeating: 0, count: binCount)
        var visualSum = [Double](repeating: 0.0, count: binCount)
        var visualCnt = [Int](repeating: 0, count: binCount)

        var prevLuma: [Float] = []
        var currLuma: [Float] = []
        var diffLuma: [Float] = []
        var frameIdx = 0

        while let sb = autoreleasepool(invoking: { output.copyNextSampleBuffer() }) {
            if CMSampleBufferGetNumSamples(sb) == 0 { continue }
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            let timeSec = pts.isNumeric ? max(0.0, CMTimeGetSeconds(pts)) : 0.0
            let bin = max(0, min(binCount - 1, Int((timeSec / binSeconds).rounded(.down))))

            // Sample every 2nd frame for fast analysis while preserving sub-second motion detail
            let shouldAnalyze = (frameIdx % 2 == 0)
            frameIdx += 1
            if !shouldAnalyze { continue }

            guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { continue }
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }

            let w = CVPixelBufferGetWidthOfPlane(pb, 0)
            let h = CVPixelBufferGetHeightOfPlane(pb, 0)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            guard w >= 8, h >= 8, let rawBase = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { continue }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)

            let step = max(1, min(w, h) / 64)
            let sw = (w + step - 1) / step
            let sh = (h + step - 1) / step
            let sampleCount = sw * sh

            if currLuma.count != sampleCount {
                currLuma = [Float](repeating: 0.0, count: sampleCount)
                prevLuma = []
                diffLuma = [Float](repeating: 0.0, count: sampleCount)
            }

            var idx = 0
            var y = 0
            while y < h {
                let row = base.advanced(by: y * stride)
                var x = 0
                while x < w {
                    currLuma[idx] = Float(row[x])
                    idx += 1
                    x += step
                }
                y += step
            }

            // Visual energy: luma contrast (stdDev) + exposure balance
            var meanLuma: Float = 0.0
            var meanSqLuma: Float = 0.0
            currLuma.withUnsafeBufferPointer { cBuf in
                guard let cPtr = cBuf.baseAddress else { return }
                vDSP_meanv(cPtr, 1, &meanLuma, vDSP_Length(sampleCount))
                vDSP_measqv(cPtr, 1, &meanSqLuma, vDSP_Length(sampleCount))
            }
            let variance = max(0.0, Double(meanSqLuma) - Double(meanLuma) * Double(meanLuma))
            let stdDev = sqrt(variance)
            let contrastScore = clamp01(stdDev / 56.0)
            let exposureScore = 1.0 - clamp01(abs(Double(meanLuma) - 128.0) / 128.0)
            let visualScore = clamp01(0.72 * contrastScore + 0.28 * exposureScore)
            visualSum[bin] += visualScore
            visualCnt[bin] += 1

            // Motion energy: mean absolute luma difference against previous sampled frame
            if prevLuma.count == sampleCount {
                var mad: Float = 0.0
                prevLuma.withUnsafeBufferPointer { pBuf in
                    currLuma.withUnsafeBufferPointer { cBuf in
                        diffLuma.withUnsafeMutableBufferPointer { dBuf in
                            guard let pPtr = pBuf.baseAddress,
                                  let cPtr = cBuf.baseAddress,
                                  let dPtr = dBuf.baseAddress else { return }
                            vDSP_vsub(pPtr, 1, cPtr, 1, dPtr, 1, vDSP_Length(sampleCount))
                            vDSP_vabs(dPtr, 1, dPtr, 1, vDSP_Length(sampleCount))
                            vDSP_meanv(dPtr, 1, &mad, vDSP_Length(sampleCount))
                        }
                    }
                }
                let madNorm = Double(mad) / 255.0
                let motionScore = clamp01(madNorm * 14.0)
                motionSum[bin] += motionScore
                motionCnt[bin] += 1
            }

            prevLuma = currLuma
        }

        var motionOut = [Double](repeating: 0.0, count: binCount)
        var visualOut = [Double](repeating: 0.0, count: binCount)
        for b in 0..<binCount {
            if motionCnt[b] > 0 {
                motionOut[b] = motionSum[b] / Double(motionCnt[b])
            }
            if visualCnt[b] > 0 {
                visualOut[b] = visualSum[b] / Double(visualCnt[b])
            }
        }

        return VideoBinEnergies(motion: motionOut, visual: visualOut)
    }

    // MARK: - Native Composition + Smooth Audio Ramp MP4 Export (Zero FFmpeg)

    private struct ExportAudioParams: Sendable {
        let sampleRate: Double
        let channels: Int
    }

    private static func exportSegments(
        inputURL: URL,
        outputURL: URL,
        segments: [KeepSegment],
        crossfadeSeconds: Double,
        bitrate: Int?
    ) async throws -> Double {
        let asset = AVURLAsset(url: inputURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let srcDuration = try await asset.load(.duration)
        let srcVideoTrack = try await asset.loadTracks(withMediaType: .video).first
        let srcAudioTrack = try await asset.loadTracks(withMediaType: .audio).first

        guard srcVideoTrack != nil || srcAudioTrack != nil else {
            throw SafariumError.invalidState("AutoEditEngine: input has neither video nor audio track")
        }

        let composition = AVMutableComposition()
        let compVideoTrack = srcVideoTrack != nil
            ? composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil
        let compAudioTrack = srcAudioTrack != nil
            ? composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            : nil

        var preferredTransform = CGAffineTransform.identity
        var videoNaturalW = 0
        var videoNaturalH = 0
        var videoFPS = 30.0
        var videoTrackRangeEnd = srcDuration

        if let vTrack = srcVideoTrack {
            preferredTransform = try await vTrack.load(.preferredTransform)
            let natSize = try await vTrack.load(.naturalSize)
            videoNaturalW = max(2, Int(abs(natSize.width).rounded()) & ~1)
            videoNaturalH = max(2, Int(abs(natSize.height).rounded()) & ~1)
            let nomFPS = Double(try await vTrack.load(.nominalFrameRate))
            if nomFPS.isFinite && nomFPS > 0.1 { videoFPS = nomFPS }
            let tr = try await vTrack.load(.timeRange)
            videoTrackRangeEnd = tr.end
            compVideoTrack?.preferredTransform = preferredTransform
        }

        var audioParams: ExportAudioParams?
        var audioTrackRangeEnd = srcDuration
        if let aTrack = srcAudioTrack {
            let tr = try await aTrack.load(.timeRange)
            audioTrackRangeEnd = tr.end
            let descs = try await aTrack.load(.formatDescriptions)
            var sr = 48_000.0
            var ch = 2
            if let first = descs.first,
               let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(first) {
                let asbd = asbdPtr.pointee
                if asbd.mSampleRate >= 8_000.0 && asbd.mSampleRate <= 192_000.0 {
                    sr = asbd.mSampleRate
                }
                if asbd.mChannelsPerFrame >= 1 && asbd.mChannelsPerFrame <= 8 {
                    ch = Int(asbd.mChannelsPerFrame)
                }
            }
            audioParams = ExportAudioParams(sampleRate: sr, channels: ch)
        }

        var insertCursor = CMTime.zero
        var insertedOutputRanges: [(start: CMTime, end: CMTime, durSec: Double)] = []

        for seg in segments {
            let startSec = max(0.0, seg.startSeconds)
            let endSec = min(CMTimeGetSeconds(srcDuration), seg.endSeconds)
            let durSec = endSec - startSec
            if durSec <= 0.01 { continue }

            let cmStart = CMTime(seconds: startSec, preferredTimescale: editTimescale)
            let cmDur = CMTime(seconds: durSec, preferredTimescale: editTimescale)

            if let vTrack = srcVideoTrack, let cvTrack = compVideoTrack {
                let clampedEnd = CMTimeMinimum(CMTimeAdd(cmStart, cmDur), videoTrackRangeEnd)
                let vDur = CMTimeSubtract(clampedEnd, cmStart)
                if CMTimeGetSeconds(vDur) > 0.005 {
                    try cvTrack.insertTimeRange(CMTimeRange(start: cmStart, duration: vDur), of: vTrack, at: insertCursor)
                }
            }

            if let aTrack = srcAudioTrack, let caTrack = compAudioTrack {
                let clampedEnd = CMTimeMinimum(CMTimeAdd(cmStart, cmDur), audioTrackRangeEnd)
                let aDur = CMTimeSubtract(clampedEnd, cmStart)
                if CMTimeGetSeconds(aDur) > 0.005 {
                    try caTrack.insertTimeRange(CMTimeRange(start: cmStart, duration: aDur), of: aTrack, at: insertCursor)
                }
            }

            let outStart = insertCursor
            let outEnd = CMTimeAdd(insertCursor, cmDur)
            insertedOutputRanges.append((start: outStart, end: outEnd, durSec: durSec))
            insertCursor = outEnd
        }

        guard !insertedOutputRanges.isEmpty else {
            throw SafariumError.invalidState("AutoEditEngine: no valid segments inserted into composition")
        }

        // Configure smooth audio volume ramps at internal cut boundaries to eliminate clicks/pops
        var audioMix: AVMutableAudioMix?
        if let caTrack = compAudioTrack, crossfadeSeconds > 0.001, insertedOutputRanges.count > 1 {
            let params = AVMutableAudioMixInputParameters(track: caTrack)
            for idx in 0..<insertedOutputRanges.count {
                let segRange = insertedOutputRanges[idx]
                let fadeSec = min(crossfadeSeconds, segRange.durSec * 0.25)
                if fadeSec < 0.002 { continue }
                let fadeCM = CMTime(seconds: fadeSec, preferredTimescale: editTimescale)

                if idx > 0 {
                    let inRange = CMTimeRange(start: segRange.start, duration: fadeCM)
                    params.setVolumeRamp(fromStartVolume: 0.0, toEndVolume: 1.0, timeRange: inRange)
                }
                if idx < insertedOutputRanges.count - 1 {
                    let outStart = CMTimeSubtract(segRange.end, fadeCM)
                    let outRange = CMTimeRange(start: outStart, duration: fadeCM)
                    params.setVolumeRamp(fromStartVolume: 1.0, toEndVolume: 0.0, timeRange: outRange)
                }
            }
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            audioMix = mix
        }

        let parentDir = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        let tempURL = parentDir.appendingPathComponent(".autoedit-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await writeComposition(
            composition: composition,
            compVideoTrack: compVideoTrack,
            compAudioTrack: compAudioTrack,
            audioMix: audioMix,
            videoNaturalW: videoNaturalW,
            videoNaturalH: videoNaturalH,
            videoFPS: videoFPS,
            preferredTransform: preferredTransform,
            audioParams: audioParams,
            bitrate: bitrate,
            outputURL: tempURL
        )

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: outputURL)

        let outAsset = AVURLAsset(url: outputURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let outDuration = try await outAsset.load(.duration)
        return max(0.0, CMTimeGetSeconds(outDuration))
    }

    private static func writeComposition(
        composition: AVMutableComposition,
        compVideoTrack: AVMutableCompositionTrack?,
        compAudioTrack: AVMutableCompositionTrack?,
        audioMix: AVMutableAudioMix?,
        videoNaturalW: Int,
        videoNaturalH: Int,
        videoFPS: Double,
        preferredTransform: CGAffineTransform,
        audioParams: ExportAudioParams?,
        bitrate: Int?,
        outputURL: URL
    ) async throws {
        let reader = try AVAssetReader(asset: composition)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        var videoOutput: AVAssetReaderTrackOutput?
        var videoInput: AVAssetWriterInput?
        var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?

        if let cvTrack = compVideoTrack, videoNaturalW >= 2, videoNaturalH >= 2 {
            let vReadSettings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ]
            let vOut = AVAssetReaderTrackOutput(track: cvTrack, outputSettings: vReadSettings)
            vOut.alwaysCopiesSampleData = false
            guard reader.canAdd(vOut) else {
                throw SafariumError.encode("AutoEditEngine: cannot add composition video reader output")
            }
            reader.add(vOut)
            videoOutput = vOut

            let defaultBits = max(
                1_200_000,
                min(25_000_000, Int((Double(videoNaturalW * videoNaturalH) * max(15.0, videoFPS) * 0.14).rounded()))
            )
            let targetBitrate = bitrate ?? defaultBits
            let vWriteSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: videoNaturalW,
                AVVideoHeightKey: videoNaturalH,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: targetBitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ] as [String: Any],
            ]
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vWriteSettings)
            vIn.expectsMediaDataInRealTime = false
            vIn.transform = preferredTransform

            let adaptorAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: videoNaturalW,
                kCVPixelBufferHeightKey as String: videoNaturalH,
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: vIn,
                sourcePixelBufferAttributes: adaptorAttrs
            )
            guard writer.canAdd(vIn) else {
                throw SafariumError.encode("AutoEditEngine: cannot add video writer input")
            }
            writer.add(vIn)
            videoInput = vIn
            videoAdaptor = adaptor
        }

        var audioOutput: AVAssetReaderOutput?
        var audioInput: AVAssetWriterInput?

        if let caTrack = compAudioTrack, let aParams = audioParams {
            let pcmSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: aParams.sampleRate,
                AVNumberOfChannelsKey: aParams.channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let aOut: AVAssetReaderOutput
            if let mix = audioMix {
                let mixOut = AVAssetReaderAudioMixOutput(audioTracks: [caTrack], audioSettings: pcmSettings)
                mixOut.audioMix = mix
                mixOut.alwaysCopiesSampleData = false
                aOut = mixOut
            } else {
                let trackOut = AVAssetReaderTrackOutput(track: caTrack, outputSettings: pcmSettings)
                trackOut.alwaysCopiesSampleData = false
                aOut = trackOut
            }
            guard reader.canAdd(aOut) else {
                throw SafariumError.encode("AutoEditEngine: cannot add audio reader output")
            }
            reader.add(aOut)
            audioOutput = aOut

            let aWriteSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: aParams.sampleRate,
                AVNumberOfChannelsKey: aParams.channels,
                AVEncoderBitRateKey: aParams.channels == 1 ? 96_000 : 160_000,
            ]
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aWriteSettings)
            aIn.expectsMediaDataInRealTime = false
            guard writer.canAdd(aIn) else {
                throw SafariumError.encode("AutoEditEngine: cannot add audio writer input")
            }
            writer.add(aIn)
            audioInput = aIn
        }

        guard reader.startReading() else {
            let msg = reader.error?.localizedDescription ?? "unknown"
            throw SafariumError.encode("AutoEditEngine: composition reader failed: \(msg)")
        }
        defer {
            if reader.status == .reading {
                reader.cancelReading()
            }
        }

        guard writer.startWriting() else {
            let msg = writer.error?.localizedDescription ?? "unknown"
            throw SafariumError.encode("AutoEditEngine: writer failed to start: \(msg)")
        }

        try pumpInterleavedComposition(
            reader: reader,
            videoOutput: videoOutput,
            audioOutput: audioOutput,
            writer: writer,
            videoInput: videoInput,
            videoAdaptor: videoAdaptor,
            audioInput: audioInput
        )

        await writer.finishWriting()
        guard writer.status == .completed else {
            let msg = writer.error?.localizedDescription ?? "status=\(writer.status.rawValue)"
            throw SafariumError.encode("AutoEditEngine: writer finish failed: \(msg)")
        }
    }

    private static func pumpInterleavedComposition(
        reader: AVAssetReader,
        videoOutput: AVAssetReaderTrackOutput?,
        audioOutput: AVAssetReaderOutput?,
        writer: AVAssetWriter,
        videoInput: AVAssetWriterInput?,
        videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?,
        audioInput: AVAssetWriterInput?
    ) throws {
        var nextVideoSB = videoOutput != nil
            ? autoreleasepool { videoOutput?.copyNextSampleBuffer() }
            : nil
        var nextAudioSB = audioOutput != nil
            ? autoreleasepool { audioOutput?.copyNextSampleBuffer() }
            : nil

        var sessionStart = CMTime.zero
        if let vSB = nextVideoSB {
            let pts = CMSampleBufferGetPresentationTimeStamp(vSB)
            if pts.isNumeric { sessionStart = pts }
        }
        if let aSB = nextAudioSB {
            let pts = CMSampleBufferGetPresentationTimeStamp(aSB)
            if pts.isNumeric && (nextVideoSB == nil || CMTimeCompare(pts, sessionStart) < 0) {
                sessionStart = pts
            }
        }
        writer.startSession(atSourceTime: sessionStart)

        var lastVideoPTS = CMTime.invalid
        var videoMarkedFinished = (videoInput == nil || videoOutput == nil)
        var audioMarkedFinished = (audioInput == nil || audioOutput == nil)
        if nextVideoSB == nil && !videoMarkedFinished {
            videoInput?.markAsFinished()
            videoMarkedFinished = true
        }
        if nextAudioSB == nil && !audioMarkedFinished {
            audioInput?.markAsFinished()
            audioMarkedFinished = true
        }

        while nextVideoSB != nil || nextAudioSB != nil {
            if writer.status != .writing {
                let msg = writer.error?.localizedDescription ?? "writer stopped unexpectedly"
                throw SafariumError.encode("AutoEditEngine: \(msg)")
            }

            let vReady = (nextVideoSB != nil) && (videoInput?.isReadyForMoreMediaData ?? false)
            let aReady = (nextAudioSB != nil) && (audioInput?.isReadyForMoreMediaData ?? false)

            if !vReady && !aReady {
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }

            let pushVideo: Bool
            if vReady && aReady, let vSB = nextVideoSB, let aSB = nextAudioSB {
                let vTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(vSB))
                let aTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(aSB))
                pushVideo = vTime <= aTime
            } else {
                pushVideo = vReady
            }

            if pushVideo, let vSB = nextVideoSB, let adaptor = videoAdaptor, let vOut = videoOutput {
                if CMSampleBufferGetNumSamples(vSB) > 0, let pb = CMSampleBufferGetImageBuffer(vSB) {
                    let pts = CMSampleBufferGetPresentationTimeStamp(vSB)
                    let isMonotonic = !lastVideoPTS.isValid || CMTimeCompare(pts, lastVideoPTS) > 0
                    if pts.isNumeric && isMonotonic {
                        if adaptor.append(pb, withPresentationTime: pts) {
                            lastVideoPTS = pts
                        }
                    }
                }
                nextVideoSB = autoreleasepool { vOut.copyNextSampleBuffer() }
                if nextVideoSB == nil && !videoMarkedFinished {
                    videoInput?.markAsFinished()
                    videoMarkedFinished = true
                }
            } else if let aSB = nextAudioSB, let aIn = audioInput, let aOut = audioOutput {
                _ = aIn.append(aSB)
                nextAudioSB = autoreleasepool { aOut.copyNextSampleBuffer() }
                if nextAudioSB == nil && !audioMarkedFinished {
                    aIn.markAsFinished()
                    audioMarkedFinished = true
                }
            } else {
                break
            }
        }

        if !videoMarkedFinished {
            videoInput?.markAsFinished()
        }
        if !audioMarkedFinished {
            audioInput?.markAsFinished()
        }

        if reader.status == .failed {
            let msg = reader.error?.localizedDescription ?? "reader failed"
            throw SafariumError.encode("AutoEditEngine: \(msg)")
        }
    }
}
