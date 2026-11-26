@preconcurrency import AVFoundation
import Accelerate
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import SafariumContainers
import SafariumCore
import Vision

// MARK: - Wave 18A: Self-Healing AI Video QA Defect Inspector (100% Native Apple Silicon)

/// Structured defect categories detected by `VideoDefectInspector`.
public enum VideoDefectType: String, Codable, Sendable, CaseIterable {
    case blackFrames
    case frozenFrames
    case textEdgeClipping
    case bandingSpike
    case colorShift
    case audioLoudnessViolation
    case audioClipping
    case audioDeadAir
}

/// Severity classification for detected media QA defects.
public enum VideoDefectSeverity: String, Codable, Sendable {
    case warning
    case error
    case critical
}

/// Single localized media defect with exact frame/time bounds, measured metric, and actionable fix.
public struct VideoDefect: Codable, Sendable, Equatable {
    public let type: VideoDefectType
    public let severity: VideoDefectSeverity
    public let startFrame: Int
    public let endFrame: Int
    public let startSeconds: Double
    public let endSeconds: Double
    public let shotIndex: Int?
    /// Normalized `[x, y, w, h]` in top-left origin `0...1` coordinates when spatially localized.
    public let boundingBox: [Double]?
    public let measuredValue: Double
    public let threshold: Double
    public let suggestedFix: String

    public init(
        type: VideoDefectType,
        severity: VideoDefectSeverity,
        startFrame: Int,
        endFrame: Int,
        startSeconds: Double,
        endSeconds: Double,
        shotIndex: Int? = nil,
        boundingBox: [Double]? = nil,
        measuredValue: Double,
        threshold: Double,
        suggestedFix: String
    ) {
        self.type = type
        self.severity = severity
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.shotIndex = shotIndex
        self.boundingBox = boundingBox
        self.measuredValue = measuredValue
        self.threshold = threshold
        self.suggestedFix = suggestedFix
    }
}

/// Configurable thresholds and toggles for `VideoDefectInspector`.
public struct VideoDefectInspectorConfig: Codable, Sendable {
    public var blackLumaThreshold: Double
    public var freezeMADThreshold: Double
    public var minFrozenFrames: Int
    public var textEdgeMarginRatio: Double
    public var maxCAMBI: Double
    public var checkAudio: Bool
    public var loudnessStandard: BroadcastLoudnessStandard
    public var checkTextClipping: Bool
    public var maxAnalyzeFrames: Int

    public init(
        blackLumaThreshold: Double = 8.0,
        freezeMADThreshold: Double = 0.25,
        minFrozenFrames: Int = 5,
        textEdgeMarginRatio: Double = 0.025,
        maxCAMBI: Double = 8.0,
        checkAudio: Bool = true,
        loudnessStandard: BroadcastLoudnessStandard = .streaming,
        checkTextClipping: Bool = true,
        maxAnalyzeFrames: Int = 240
    ) {
        self.blackLumaThreshold = blackLumaThreshold
        self.freezeMADThreshold = freezeMADThreshold
        self.minFrozenFrames = minFrozenFrames
        self.textEdgeMarginRatio = textEdgeMarginRatio
        self.maxCAMBI = maxCAMBI
        self.checkAudio = checkAudio
        self.loudnessStandard = loudnessStandard
        self.checkTextClipping = checkTextClipping
        self.maxAnalyzeFrames = maxAnalyzeFrames
    }
}

/// Complete QA inspection report produced by `VideoDefectInspector`.
public struct VideoDefectReport: Codable, Sendable {
    public let inputPath: String
    public let passed: Bool
    public let totalFrames: Int
    public let fps: Double
    public let defectCount: Int
    public let defects: [VideoDefect]
    public let meanCAMBI: Double
    public let maxCAMBI: Double
    public let broadcastLoudness: BroadcastLoudnessReport?
    public let elapsedMs: Double

    public init(
        inputPath: String,
        passed: Bool,
        totalFrames: Int,
        fps: Double,
        defectCount: Int,
        defects: [VideoDefect],
        meanCAMBI: Double,
        maxCAMBI: Double,
        broadcastLoudness: BroadcastLoudnessReport?,
        elapsedMs: Double
    ) {
        self.inputPath = inputPath
        self.passed = passed
        self.totalFrames = totalFrames
        self.fps = fps
        self.defectCount = defectCount
        self.defects = defects
        self.meanCAMBI = meanCAMBI
        self.maxCAMBI = maxCAMBI
        self.broadcastLoudness = broadcastLoudness
        self.elapsedMs = elapsedMs
    }
}

/// Pure-Apple-Silicon video and audio QA defect inspector.
///
/// Decodes video via `AVAssetReader`, evaluates luma black runs, Accelerate-backed frame-to-frame
/// freeze runs, `NativeCAMBI` banding spikes, Vision OCR (`th-TH`, `en-US`) + deterministic
/// edge-margin text-band clipping, intra-shot color-space corruption, and ITU-R BS.1770-4 audio
/// loudness/clipping/dead-air via `BroadcastLoudnessAuditor`.
public enum VideoDefectInspector {

    // MARK: - Internal State Helpers

    private struct TextClipHit {
        let edge: String
        let box: [Double]
        let minMargin: Double
        let snippet: String?
    }

    private struct ActiveTextClipRun {
        let edge: String
        var startFrame: Int
        var endFrame: Int
        var startSeconds: Double
        var endSeconds: Double
        var bestBox: [Double]
        var worstMargin: Double
        var snippet: String?
    }

    private struct FrameLumaSummary {
        let luma: [Float]
        let meanLuma: Double
        let meanCb: Double
        let meanCr: Double
        let sampledWidth: Int
        let sampledHeight: Int
    }

    // MARK: - Public Entry Point

    /// Inspects a video/media file for visual and audio QA defects.
    public static func inspect(
        url: URL,
        config: VideoDefectInspectorConfig = VideoDefectInspectorConfig()
    ) async throws -> VideoDefectReport {
        let t0 = DispatchTime.now().uptimeNanoseconds

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SafariumError.invalidState("input media file does not exist: \(url.path)")
        }

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
        ])
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw SafariumError.invalidState("no video track found in \(url.lastPathComponent)")
        }

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let assetDuration = try await asset.load(.duration)
        let loadedFPS = Double(try await videoTrack.load(.nominalFrameRate))
        let fps: Double = (loadedFPS.isFinite && loadedFPS > 0.1) ? loadedFPS : 30.0
        let frameDurSec: Double = 1.0 / fps

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(trackOutput) else {
            throw SafariumError.invalidState("AVAssetReader cannot add BGRA video output")
        }
        reader.add(trackOutput)
        guard reader.startReading() else {
            let msg = reader.error?.localizedDescription ?? "AVAssetReader failed to start"
            throw SafariumError.encode("VideoDefectInspector decode start failed: \(msg)")
        }

        var defects: [VideoDefect] = []

        // Black run tracking
        var inBlackRun = false
        var blackStartFrame = 0
        var blackStartSec = 0.0
        var blackEndFrame = 0
        var blackEndSec = 0.0
        var blackLumaSum = 0.0
        var blackFrameCount = 0

        // Frozen run tracking (excludes black frames)
        var inFreezeRun = false
        var freezeStartFrame = 0
        var freezeStartSec = 0.0
        var freezeEndFrame = 0
        var freezeEndSec = 0.0
        var freezeMADSum = 0.0
        var freezePairCount = 0

        // Color shift run tracking (identical luma, abrupt chroma inversion)
        var inColorShift = false
        var colorShiftStartFrame = 0
        var colorShiftStartSec = 0.0
        var colorShiftEndFrame = 0
        var colorShiftEndSec = 0.0
        var colorShiftPeak = 0.0

        // Banding (CAMBI) tracking
        let cambiStride = max(1, Int((fps / 3.0).rounded()))
        var cambiScores: [Double] = []
        var inBandingRun = false
        var bandingStartFrame = 0
        var bandingStartSec = 0.0
        var bandingEndFrame = 0
        var bandingEndSec = 0.0
        var bandingPeakScore = 0.0

        // Text edge clipping tracking
        let textStride = max(1, Int((fps / 2.0).rounded()))
        var activeTextRuns: [String: ActiveTextClipRun] = [:]

        var prevSummary: FrameLumaSummary?
        var prevFrameIndex = -1
        var prevFramePTS = 0.0
        var prevWasBlack = false

        var frameIndex = 0
        var lastEndSeconds = 0.0
        let frameLimit = config.maxAnalyzeFrames > 0 ? config.maxAnalyzeFrames : Int.max

        func flushBlackRun() {
            guard inBlackRun else { return }
            let count = max(1, blackFrameCount)
            let avgLuma = blackLumaSum / Double(count)
            let criticalThreshold = max(3, Int((fps * 0.25).rounded()))
            let sev: VideoDefectSeverity = (count >= criticalThreshold) ? .critical : .error
            let startStr = String(format: "%.2f", blackStartSec)
            let endStr = String(format: "%.2f", blackEndSec)
            defects.append(VideoDefect(
                type: .blackFrames,
                severity: sev,
                startFrame: blackStartFrame,
                endFrame: blackEndFrame,
                startSeconds: round4(blackStartSec),
                endSeconds: round4(blackEndSec),
                shotIndex: nil,
                boundingBox: nil,
                measuredValue: round4(avgLuma),
                threshold: config.blackLumaThreshold,
                suggestedFix: "Re-render or surgically replace black frames [\(blackStartFrame)..\(blackEndFrame)] (\(startStr)s-\(endStr)s); verify source clip exposure, alpha compositing, and Closed-GOP keyframes."
            ))
            inBlackRun = false
            blackLumaSum = 0.0
            blackFrameCount = 0
        }

        func flushFreezeRun() {
            guard inFreezeRun else { return }
            let spanFrames = freezeEndFrame - freezeStartFrame + 1
            if spanFrames >= config.minFrozenFrames {
                let pairs = max(1, freezePairCount)
                let avgMAD = freezeMADSum / Double(pairs)
                let criticalLen = max(10, Int(fps.rounded()))
                let sev: VideoDefectSeverity = (spanFrames >= criticalLen) ? .critical : .error
                let startStr = String(format: "%.2f", freezeStartSec)
                let endStr = String(format: "%.2f", freezeEndSec)
                defects.append(VideoDefect(
                    type: .frozenFrames,
                    severity: sev,
                    startFrame: freezeStartFrame,
                    endFrame: freezeEndFrame,
                    startSeconds: round4(freezeStartSec),
                    endSeconds: round4(freezeEndSec),
                    shotIndex: nil,
                    boundingBox: nil,
                    measuredValue: round4(avgMAD),
                    threshold: config.freezeMADThreshold,
                    suggestedFix: "Inspect stalled source/decoder and surgically replace frozen frames [\(freezeStartFrame)..\(freezeEndFrame)] (\(startStr)s-\(endStr)s) with active motion frames."
                ))
            }
            inFreezeRun = false
            freezeMADSum = 0.0
            freezePairCount = 0
        }

        func flushBandingRun() {
            guard inBandingRun else { return }
            let sev: VideoDefectSeverity = (bandingPeakScore > config.maxCAMBI * 1.5) ? .error : .warning
            let startStr = String(format: "%.2f", bandingStartSec)
            let endStr = String(format: "%.2f", bandingEndSec)
            let maxStr = String(format: "%.1f", config.maxCAMBI)
            defects.append(VideoDefect(
                type: .bandingSpike,
                severity: sev,
                startFrame: bandingStartFrame,
                endFrame: bandingEndFrame,
                startSeconds: round4(bandingStartSec),
                endSeconds: round4(bandingEndSec),
                shotIndex: nil,
                boundingBox: nil,
                measuredValue: round4(bandingPeakScore),
                threshold: config.maxCAMBI,
                suggestedFix: "Re-encode segment [\(bandingStartFrame)..\(bandingEndFrame)] (\(startStr)s-\(endStr)s) with 10-bit HEVC/ProRes, higher bitrate, or subtle debanding/dither to keep CAMBI <= \(maxStr)."
            ))
            inBandingRun = false
            bandingPeakScore = 0.0
        }

        func flushColorShiftRun() {
            guard inColorShift else { return }
            let startStr = String(format: "%.2f", colorShiftStartSec)
            let endStr = String(format: "%.2f", colorShiftEndSec)
            defects.append(VideoDefect(
                type: .colorShift,
                severity: .error,
                startFrame: colorShiftStartFrame,
                endFrame: colorShiftEndFrame,
                startSeconds: round4(colorShiftStartSec),
                endSeconds: round4(colorShiftEndSec),
                shotIndex: nil,
                boundingBox: nil,
                measuredValue: round4(colorShiftPeak),
                threshold: 60.0,
                suggestedFix: "Verify color matrix / transfer tags (Rec.709/Rec.2020) and re-render frames [\(colorShiftStartFrame)..\(colorShiftEndFrame)] (\(startStr)s-\(endStr)s) to eliminate abrupt chroma shift."
            ))
            inColorShift = false
            colorShiftPeak = 0.0
        }

        func flushTextRun(for edge: String) {
            guard let run = activeTextRuns.removeValue(forKey: edge) else { return }
            let sev: VideoDefectSeverity = (run.worstMargin < config.textEdgeMarginRatio * 0.5) ? .error : .warning
            let pctStr = String(format: "%.1f", config.textEdgeMarginRatio * 100.0)
            let snippetNote: String
            if let snippet = run.snippet, !snippet.isEmpty {
                snippetNote = " ('\(snippet)')"
            } else {
                snippetNote = ""
            }
            defects.append(VideoDefect(
                type: .textEdgeClipping,
                severity: sev,
                startFrame: run.startFrame,
                endFrame: run.endFrame,
                startSeconds: round4(run.startSeconds),
                endSeconds: round4(run.endSeconds),
                shotIndex: nil,
                boundingBox: run.bestBox.map { round4($0) },
                measuredValue: round4(run.worstMargin),
                threshold: config.textEdgeMarginRatio,
                suggestedFix: "Inset or re-wrap text/UI overlay\(snippetNote) by at least \(pctStr)% title-safe margin away from the \(run.edge) border."
            ))
        }

        while frameIndex < frameLimit {
            guard let sampleBuffer = trackOutput.copyNextSampleBuffer() else {
                break
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            let rawPTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let ptsSec: Double
            if rawPTS.isValid && rawPTS.isNumeric {
                ptsSec = max(0.0, CMTimeGetSeconds(rawPTS))
            } else {
                ptsSec = Double(frameIndex) * frameDurSec
            }
            let rawDur = CMSampleBufferGetDuration(sampleBuffer)
            let thisDur: Double
            if rawDur.isValid && rawDur.isNumeric && CMTimeGetSeconds(rawDur) > 0.0001 {
                thisDur = CMTimeGetSeconds(rawDur)
            } else {
                thisDur = frameDurSec
            }
            let endSec = ptsSec + thisDur
            if endSec > lastEndSeconds {
                lastEndSeconds = endSec
            }

            let summary = extractLumaSummary(pixelBuffer: pixelBuffer)
            let isBlack = summary.meanLuma < config.blackLumaThreshold

            // 1. Black frame run detection
            if isBlack {
                if !inBlackRun {
                    inBlackRun = true
                    blackStartFrame = frameIndex
                    blackStartSec = ptsSec
                    blackLumaSum = 0.0
                    blackFrameCount = 0
                }
                blackEndFrame = frameIndex
                blackEndSec = endSec
                blackLumaSum += summary.meanLuma
                blackFrameCount += 1
            } else {
                flushBlackRun()
            }

            // 2. Frozen frame run detection (ignoring black frames) & intra-shot color-shift check
            if let prev = prevSummary, !isBlack, !prevWasBlack, prev.luma.count == summary.luma.count {
                let mad = computeMAD(prev.luma, summary.luma)
                if mad < config.freezeMADThreshold {
                    if !inFreezeRun {
                        inFreezeRun = true
                        freezeStartFrame = prevFrameIndex
                        freezeStartSec = prevFramePTS
                        freezeMADSum = 0.0
                        freezePairCount = 0
                    }
                    freezeEndFrame = frameIndex
                    freezeEndSec = endSec
                    freezeMADSum += mad
                    freezePairCount += 1
                } else {
                    flushFreezeRun()
                }

                // Intra-shot color-matrix corruption: near-identical luma but huge chroma jump
                let dCb = abs(summary.meanCb - prev.meanCb)
                let dCr = abs(summary.meanCr - prev.meanCr)
                let chromaDelta = max(dCb, dCr)
                if mad < 1.0 && chromaDelta > 60.0 {
                    if !inColorShift {
                        inColorShift = true
                        colorShiftStartFrame = frameIndex
                        colorShiftStartSec = ptsSec
                        colorShiftPeak = chromaDelta
                    } else if chromaDelta > colorShiftPeak {
                        colorShiftPeak = chromaDelta
                    }
                    colorShiftEndFrame = frameIndex
                    colorShiftEndSec = endSec
                } else {
                    flushColorShiftRun()
                }
            } else {
                flushFreezeRun()
                flushColorShiftRun()
            }

            // 3. NativeCAMBI banding check on sampled non-black frames
            if !isBlack && (frameIndex == 0 || frameIndex % cambiStride == 0) {
                let cambi = NativeCAMBI.measure(pixelBuffer: pixelBuffer)
                let score = cambi.cambiScore
                cambiScores.append(score)
                if score > config.maxCAMBI {
                    if !inBandingRun {
                        inBandingRun = true
                        bandingStartFrame = frameIndex
                        bandingStartSec = ptsSec
                        bandingPeakScore = score
                    } else if score > bandingPeakScore {
                        bandingPeakScore = score
                    }
                    bandingEndFrame = frameIndex
                    bandingEndSec = endSec
                } else {
                    flushBandingRun()
                }
            } else if isBlack {
                flushBandingRun()
            }

            // 4. Text/UI edge clipping via Vision OCR + deterministic edge-margin text-band detector
            if config.checkTextClipping && !isBlack && (frameIndex == 0 || frameIndex % textStride == 0) {
                let hits = detectTextEdgeClipping(
                    pixelBuffer: pixelBuffer,
                    marginRatio: config.textEdgeMarginRatio
                )
                var seenEdges = Set<String>()
                for hit in hits {
                    seenEdges.insert(hit.edge)
                    if var existing = activeTextRuns[hit.edge] {
                        existing.endFrame = frameIndex
                        existing.endSeconds = endSec
                        if hit.minMargin < existing.worstMargin {
                            existing.worstMargin = hit.minMargin
                            existing.bestBox = hit.box
                        }
                        if existing.snippet == nil, let s = hit.snippet {
                            existing.snippet = s
                        }
                        activeTextRuns[hit.edge] = existing
                    } else {
                        activeTextRuns[hit.edge] = ActiveTextClipRun(
                            edge: hit.edge,
                            startFrame: frameIndex,
                            endFrame: frameIndex,
                            startSeconds: ptsSec,
                            endSeconds: endSec,
                            bestBox: hit.box,
                            worstMargin: hit.minMargin,
                            snippet: hit.snippet
                        )
                    }
                }
                let staleEdges = activeTextRuns.keys.filter { !seenEdges.contains($0) }
                for edge in staleEdges {
                    flushTextRun(for: edge)
                }
            } else if isBlack {
                for edge in Array(activeTextRuns.keys) {
                    flushTextRun(for: edge)
                }
            }

            prevSummary = summary
            prevFrameIndex = frameIndex
            prevFramePTS = ptsSec
            prevWasBlack = isBlack
            frameIndex += 1
        }

        // Flush any open defect runs at EOF
        flushBlackRun()
        flushFreezeRun()
        flushBandingRun()
        flushColorShiftRun()
        for edge in activeTextRuns.keys.sorted() {
            flushTextRun(for: edge)
        }

        if reader.status == .reading {
            reader.cancelReading()
        } else if reader.status == .failed {
            let msg = reader.error?.localizedDescription ?? "AVAssetReader failed mid-stream"
            throw SafariumError.encode("VideoDefectInspector decode error: \(msg)")
        }

        let totalFrames = frameIndex
        let meanCAMBI: Double
        let maxCAMBI: Double
        if cambiScores.isEmpty {
            meanCAMBI = 0.0
            maxCAMBI = 0.0
        } else {
            var sum = 0.0
            var peak = 0.0
            for s in cambiScores {
                sum += s
                if s > peak { peak = s }
            }
            meanCAMBI = sum / Double(cambiScores.count)
            maxCAMBI = peak
        }

        // 5. Audio broadcast loudness, clipping & dead-air audit
        var loudnessReport: BroadcastLoudnessReport?
        if config.checkAudio && !audioTracks.isEmpty {
            let report = try await BroadcastLoudnessAuditor.analyze(
                url: url,
                standard: config.loudnessStandard
            )
            loudnessReport = report

            let durSec: Double
            if assetDuration.isValid && assetDuration.isNumeric && CMTimeGetSeconds(assetDuration) > 0 {
                durSec = CMTimeGetSeconds(assetDuration)
            } else {
                durSec = lastEndSeconds
            }
            let lastFrameIdx = max(0, totalFrames - 1)

            if report.integratedLUFS < -60.0 {
                let lufsStr = String(format: "%.1f", report.integratedLUFS)
                defects.append(VideoDefect(
                    type: .audioDeadAir,
                    severity: .critical,
                    startFrame: 0,
                    endFrame: lastFrameIdx,
                    startSeconds: 0.0,
                    endSeconds: round4(durSec),
                    shotIndex: nil,
                    boundingBox: nil,
                    measuredValue: round4(report.integratedLUFS),
                    threshold: -60.0,
                    suggestedFix: "Audio track is silent or near-silent (\(lufsStr) LUFS); verify audio routing/mix and remux an active soundtrack."
                ))
            } else {
                let std = config.loudnessStandard
                let lufsDiff = abs(report.integratedLUFS - std.targetLUFS)
                if lufsDiff > std.toleranceLU {
                    let gainStr = String(format: "%+.2f", report.recommendedGainDB)
                    let targetStr = String(format: "%.1f", std.targetLUFS)
                    defects.append(VideoDefect(
                        type: .audioLoudnessViolation,
                        severity: .error,
                        startFrame: 0,
                        endFrame: lastFrameIdx,
                        startSeconds: 0.0,
                        endSeconds: round4(durSec),
                        shotIndex: nil,
                        boundingBox: nil,
                        measuredValue: round4(report.integratedLUFS),
                        threshold: std.targetLUFS,
                        suggestedFix: "Apply \(gainStr) dB loudness normalization with true-peak limiting to meet \(std.rawValue) target (\(targetStr) LUFS)."
                    ))
                } else if !report.compliant && report.truePeakDBTP <= -0.1 && report.truePeakDBTP > std.maxTruePeakDBTP {
                    let peakStr = String(format: "%.2f", report.truePeakDBTP)
                    let ceilStr = String(format: "%.1f", std.maxTruePeakDBTP)
                    defects.append(VideoDefect(
                        type: .audioLoudnessViolation,
                        severity: .warning,
                        startFrame: 0,
                        endFrame: lastFrameIdx,
                        startSeconds: 0.0,
                        endSeconds: round4(durSec),
                        shotIndex: nil,
                        boundingBox: nil,
                        measuredValue: round4(report.truePeakDBTP),
                        threshold: std.maxTruePeakDBTP,
                        suggestedFix: "Apply true-peak limiter to reduce peak from \(peakStr) dBTP below \(std.rawValue) ceiling (\(ceilStr) dBTP)."
                    ))
                }
            }

            if report.truePeakDBTP > -0.1 {
                let peakStr = String(format: "%.2f", report.truePeakDBTP)
                let ceilStr = String(format: "%.1f", config.loudnessStandard.maxTruePeakDBTP)
                defects.append(VideoDefect(
                    type: .audioClipping,
                    severity: .critical,
                    startFrame: 0,
                    endFrame: lastFrameIdx,
                    startSeconds: 0.0,
                    endSeconds: round4(durSec),
                    shotIndex: nil,
                    boundingBox: nil,
                    measuredValue: round4(report.truePeakDBTP),
                    threshold: -0.1,
                    suggestedFix: "Audio true peak (\(peakStr) dBTP) exceeds -0.1 dBTP clipping ceiling; apply brickwall true-peak limiter at \(ceilStr) dBTP."
                ))
            }
        }

        // Sort defects deterministically by startFrame then type
        defects.sort { a, b in
            if a.startFrame != b.startFrame {
                return a.startFrame < b.startFrame
            }
            return a.type.rawValue < b.type.rawValue
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0
        return VideoDefectReport(
            inputPath: url.path,
            passed: defects.isEmpty,
            totalFrames: totalFrames,
            fps: round4(fps),
            defectCount: defects.count,
            defects: defects,
            meanCAMBI: round4(meanCAMBI),
            maxCAMBI: round4(maxCAMBI),
            broadcastLoudness: loudnessReport,
            elapsedMs: round4(elapsedMs)
        )
    }

    // MARK: - Luma & Accelerate MAD Extraction

    private static func extractLumaSummary(pixelBuffer: CVPixelBuffer) -> FrameLumaSummary {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0,
              let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return FrameLumaSummary(
                luma: [],
                meanLuma: 0.0,
                meanCb: 128.0,
                meanCr: 128.0,
                sampledWidth: 0,
                sampledHeight: 0
            )
        }

        let step: Int = (width * height > 640 * 480) ? 2 : 1
        let sampledW = (width + step - 1) / step
        let sampledH = (height + step - 1) / step
        let totalSamples = sampledW * sampledH
        var lumaPlane = [Float](repeating: 0.0, count: totalSamples)

        let ptr = baseAddr.assumingMemoryBound(to: UInt8.self)
        var cbSum = 0.0
        var crSum = 0.0
        var outIdx = 0

        var y = 0
        while y < height {
            let rowOff = y * bytesPerRow
            var x = 0
            while x < width {
                let pOff = rowOff + x * 4
                let b = Float(ptr[pOff])
                let g = Float(ptr[pOff + 1])
                let r = Float(ptr[pOff + 2])

                // Rec.709 luma in [0...255]
                let yR: Float = 0.2126 * r
                let yG: Float = 0.7152 * g
                let yB: Float = 0.0722 * b
                let yVal: Float = yR + yG + yB
                lumaPlane[outIdx] = yVal

                // Approximate Cb/Cr centered at 128 for intra-shot color shift detection
                let cbVal = 128.0 + 0.5389 * Double(b - yVal)
                let crVal = 128.0 + 0.6350 * Double(r - yVal)
                cbSum += cbVal
                crSum += crVal

                outIdx += 1
                x += step
            }
            y += step
        }

        var meanY: Float = 0.0
        if totalSamples > 0 {
            vDSP_meanv(lumaPlane, 1, &meanY, vDSP_Length(totalSamples))
        }
        let invCount = totalSamples > 0 ? (1.0 / Double(totalSamples)) : 0.0
        return FrameLumaSummary(
            luma: lumaPlane,
            meanLuma: Double(meanY),
            meanCb: cbSum * invCount,
            meanCr: crSum * invCount,
            sampledWidth: sampledW,
            sampledHeight: sampledH
        )
    }

    /// Computes Mean Absolute Difference between two equal-length luma vectors using Accelerate (`vDSP`).
    private static func computeMAD(_ a: [Float], _ b: [Float]) -> Double {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0.0 }
        var diff = [Float](repeating: 0.0, count: count)
        var absDiff = [Float](repeating: 0.0, count: count)
        let n = vDSP_Length(count)
        vDSP_vsub(b, 1, a, 1, &diff, 1, n)
        vDSP_vabs(diff, 1, &absDiff, 1, n)
        var mean: Float = 0.0
        vDSP_meanv(absDiff, 1, &mean, n)
        return Double(mean)
    }

    // MARK: - Text/UI Edge Clipping Detection (Vision OCR + Deterministic Edge-Band Detector)

    private static func detectTextEdgeClipping(
        pixelBuffer: CVPixelBuffer,
        marginRatio: Double
    ) -> [TextClipHit] {
        var hitsByEdge: [String: TextClipHit] = [:]

        // 1. Vision VNRecognizeTextRequest (Thai + English)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["th-TH", "en-US"]
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        if (try? handler.perform([request])) != nil,
           let observations = request.results {
            for obs in observations {
                let bb = obs.boundingBox
                let x = max(0.0, min(1.0, Double(bb.minX)))
                let y = max(0.0, min(1.0, 1.0 - Double(bb.maxY)))
                let w = max(0.0, min(1.0 - x, Double(bb.width)))
                let h = max(0.0, min(1.0 - y, Double(bb.height)))
                guard w > 0.005, h > 0.005 else { continue }

                let leftMargin = x
                let rightMargin = max(0.0, 1.0 - (x + w))
                let topMargin = y
                let bottomMargin = max(0.0, 1.0 - (y + h))

                let edgeMargins: [(String, Double)] = [
                    ("left", leftMargin),
                    ("right", rightMargin),
                    ("top", topMargin),
                    ("bottom", bottomMargin),
                ]
                var worstEdge = "left"
                var minM = leftMargin
                for (name, m) in edgeMargins {
                    if m < minM {
                        minM = m
                        worstEdge = name
                    }
                }

                if minM < marginRatio {
                    let rawSnippet = obs.topCandidates(1).first?.string
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let snippet = rawSnippet.map { String($0.prefix(32)) }
                    let candidate = TextClipHit(
                        edge: worstEdge,
                        box: [x, y, w, h],
                        minMargin: minM,
                        snippet: snippet
                    )
                    if let prev = hitsByEdge[worstEdge] {
                        if candidate.minMargin < prev.minMargin {
                            hitsByEdge[worstEdge] = candidate
                        }
                    } else {
                        hitsByEdge[worstEdge] = candidate
                    }
                }
            }
        }

        // 2. Deterministic high-contrast edge-margin text-band detector
        let detHits = detectDeterministicEdgeTextBands(
            pixelBuffer: pixelBuffer,
            marginRatio: marginRatio
        )
        for hit in detHits {
            if hitsByEdge[hit.edge] == nil {
                hitsByEdge[hit.edge] = hit
            }
        }

        return Array(hitsByEdge.values)
    }

    /// Deterministically identifies high-contrast glyph-stroke bands intruding into any border margin strip.
    /// Rejects solid shapes and smooth gradients by requiring repeated high-contrast stroke transitions.
    private static func detectDeterministicEdgeTextBands(
        pixelBuffer: CVPixelBuffer,
        marginRatio: Double
    ) -> [TextClipHit] {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width >= 64, height >= 64,
              let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return []
        }

        let ptr = baseAddr.assumingMemoryBound(to: UInt8.self)
        let lumaCount = width * height
        var luma8 = [UInt8](repeating: 0, count: lumaCount)
        for y in 0..<height {
            let rowOff = y * bytesPerRow
            let outRow = y * width
            for x in 0..<width {
                let pOff = rowOff + x * 4
                let b = Int(ptr[pOff])
                let g = Int(ptr[pOff + 1])
                let r = Int(ptr[pOff + 2])
                let yInt = (54 * r + 183 * g + 19 * b) >> 8
                luma8[outRow + x] = UInt8(max(0, min(255, yInt)))
            }
        }

        let marginX = max(4, Int(ceil(Double(width) * marginRatio)))
        let marginY = max(4, Int(ceil(Double(height) * marginRatio)))
        let strokeGradThreshold = 50
        var hits: [TextClipHit] = []

        // Helper for top / bottom horizontal margin strips
        func checkHorizontalStrip(edge: String, yStart: Int, yEnd: Int) {
            guard yEnd > yStart else { return }
            let corridorYStart = (edge == "top") ? 0 : max(0, height - marginY * 4)
            let corridorYEnd = (edge == "top") ? min(height, marginY * 4) : height

            var stripTransitions = 0
            var activeRowsInStrip = 0
            var minX = width
            var maxX = 0
            var closestRowDist = marginY

            for y in yStart..<yEnd {
                let rowOff = y * width
                var rowTransitions = 0
                var rowMinX = width
                var rowMaxX = 0
                for x in 1..<width {
                    let diff = abs(Int(luma8[rowOff + x]) - Int(luma8[rowOff + x - 1]))
                    if diff >= strokeGradThreshold {
                        rowTransitions += 1
                        if x < rowMinX { rowMinX = x }
                        if x > rowMaxX { rowMaxX = x }
                    }
                }
                if rowTransitions >= 6 {
                    activeRowsInStrip += 1
                    stripTransitions += rowTransitions
                    if rowMinX < minX { minX = rowMinX }
                    if rowMaxX > maxX { maxX = rowMaxX }
                    let dist = (edge == "top") ? y : (height - 1 - y)
                    if dist < closestRowDist { closestRowDist = dist }
                }
            }

            guard activeRowsInStrip >= 2, stripTransitions >= 14, maxX > minX else { return }

            // Confirm localized text corridor density immediately inward
            var corridorTextRows = 0
            for y in corridorYStart..<corridorYEnd {
                let rowOff = y * width
                var trans = 0
                let x0 = max(1, minX)
                let x1 = min(width - 1, maxX)
                if x1 > x0 {
                    for x in x0...x1 {
                        let diff = abs(Int(luma8[rowOff + x]) - Int(luma8[rowOff + x - 1]))
                        if diff >= strokeGradThreshold {
                            trans += 1
                        }
                    }
                }
                if trans >= 6 {
                    corridorTextRows += 1
                }
            }

            if corridorTextRows >= 4 {
                let bx = Double(minX) / Double(width)
                let by = Double(corridorYStart) / Double(height)
                let bw = Double(maxX - minX + 1) / Double(width)
                let bh = Double(corridorYEnd - corridorYStart) / Double(height)
                let normMargin = Double(closestRowDist) / Double(height)
                hits.append(TextClipHit(
                    edge: edge,
                    box: [bx, by, bw, bh],
                    minMargin: normMargin,
                    snippet: nil
                ))
            }
        }

        // Helper for left / right vertical margin strips
        func checkVerticalStrip(edge: String, xStart: Int, xEnd: Int) {
            guard xEnd > xStart else { return }
            let corridorXStart = (edge == "left") ? 0 : max(0, width - marginX * 6)
            let corridorXEnd = (edge == "left") ? min(width, marginX * 6) : width

            var activeStripRows: [Int] = []
            var closestColDist = marginX

            for y in 1..<(height - 1) {
                let rowOff = y * width
                let upOff = (y - 1) * width
                var rowStripEdges = 0
                let xs = max(1, xStart)
                let xe = min(width - 1, xEnd - 1)
                if xe >= xs {
                    for x in xs...xe {
                        let gx = abs(Int(luma8[rowOff + x]) - Int(luma8[rowOff + x - 1]))
                        let gy = abs(Int(luma8[rowOff + x]) - Int(luma8[upOff + x]))
                        if gx >= strokeGradThreshold || gy >= strokeGradThreshold {
                            rowStripEdges += 1
                            let dist = (edge == "left") ? x : (width - 1 - x)
                            if dist < closestColDist { closestColDist = dist }
                        }
                    }
                }
                if rowStripEdges >= 2 {
                    activeStripRows.append(y)
                }
            }

            guard activeStripRows.count >= 4 else { return }

            // Cluster active rows into contiguous vertical bands
            let maxGap = max(8, height / 30)
            var bandStart = activeStripRows[0]
            var bandEnd = activeStripRows[0]
            var bands: [(Int, Int)] = []

            for i in 1..<activeStripRows.count {
                let r = activeStripRows[i]
                if r - bandEnd <= maxGap {
                    bandEnd = r
                } else {
                    bands.append((bandStart, bandEnd))
                    bandStart = r
                    bandEnd = r
                }
            }
            bands.append((bandStart, bandEnd))

            for (y0, y1) in bands {
                let bandH = y1 - y0 + 1
                let maxBandH = Int(Double(height) * 0.5)
                guard bandH >= 6, bandH <= maxBandH else { continue }

                var corridorStrokeRows = 0
                for y in y0...y1 {
                    let rowOff = y * width
                    var hTrans = 0
                    let cStart = max(1, corridorXStart)
                    let cEnd = min(width - 1, corridorXEnd - 1)
                    if cEnd >= cStart {
                        for x in cStart...cEnd {
                            let gx = abs(Int(luma8[rowOff + x]) - Int(luma8[rowOff + x - 1]))
                            if gx >= strokeGradThreshold {
                                hTrans += 1
                            }
                        }
                    }
                    if hTrans >= 6 {
                        corridorStrokeRows += 1
                    }
                }

                if corridorStrokeRows >= 4 {
                    let bx = Double(corridorXStart) / Double(width)
                    let by = Double(y0) / Double(height)
                    let bw = Double(corridorXEnd - corridorXStart) / Double(width)
                    let bh = Double(bandH) / Double(height)
                    let normMargin = Double(closestColDist) / Double(width)
                    hits.append(TextClipHit(
                        edge: edge,
                        box: [bx, by, bw, bh],
                        minMargin: normMargin,
                        snippet: nil
                    ))
                    return
                }
            }
        }

        checkHorizontalStrip(edge: "top", yStart: 0, yEnd: min(height, marginY))
        checkHorizontalStrip(edge: "bottom", yStart: max(0, height - marginY), yEnd: height)
        checkVerticalStrip(edge: "left", xStart: 0, xEnd: min(width, marginX))
        checkVerticalStrip(edge: "right", xStart: max(0, width - marginX), xEnd: width)

        return hits
    }

    private static func round4(_ value: Double) -> Double {
        guard value.isFinite else { return 0.0 }
        return (value * 10_000.0).rounded() / 10_000.0
    }
}
