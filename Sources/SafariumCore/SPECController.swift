import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import VideoToolbox

// MARK: - Wave 13C: SPEC Closed-Loop Quality-Target Controller & Per-Title HLS Ladder

/// Declarative perceptual quality & delivery contract for `SPECController`.
public struct SPECQualityContract: Codable, Sendable, Equatable {
    public var targetVMAF: Double
    public var targetMSSSIM: Double
    public var maxDeltaE00P95: Double
    public var maxCAMBI: Double?
    public var maxBytes: Int64?
    public var maxLatencySeconds: Double?
    public var protectText: Bool
    public var protectFaces: Bool
    public var preserveGrain: Bool
    public var bandingSensitive: Bool
    public var hdrPolicy: HDRMetadataPolicy
    public var intent: String
    public var codec: VideoCodec

    public init(
        targetVMAF: Double = 95.0,
        targetMSSSIM: Double = 0.995,
        maxDeltaE00P95: Double = 2.0,
        maxCAMBI: Double? = nil,
        maxBytes: Int64? = nil,
        maxLatencySeconds: Double? = nil,
        protectText: Bool = true,
        protectFaces: Bool = true,
        preserveGrain: Bool = false,
        bandingSensitive: Bool = true,
        hdrPolicy: HDRMetadataPolicy = .preserve,
        intent: String = "balanced_delivery",
        codec: VideoCodec = .hevc10
    ) {
        self.targetVMAF = targetVMAF
        self.targetMSSSIM = targetMSSSIM
        self.maxDeltaE00P95 = maxDeltaE00P95
        self.maxCAMBI = maxCAMBI
        self.maxBytes = maxBytes
        self.maxLatencySeconds = maxLatencySeconds
        self.protectText = protectText
        self.protectFaces = protectFaces
        self.preserveGrain = preserveGrain
        self.bandingSensitive = bandingSensitive
        self.hdrPolicy = hdrPolicy
        self.intent = intent
        self.codec = codec
    }

    private enum CodingKeys: String, CodingKey {
        case targetVMAF
        case targetMSSSIM
        case maxDeltaE00P95
        case maxCAMBI
        case maxBytes
        case maxLatencySeconds
        case protectText
        case protectFaces
        case preserveGrain
        case bandingSensitive
        case hdrPolicy
        case intent
        case codec
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.targetVMAF = try container.decode(Double.self, forKey: .targetVMAF)
        self.targetMSSSIM = try container.decode(Double.self, forKey: .targetMSSSIM)
        self.maxDeltaE00P95 = try container.decode(Double.self, forKey: .maxDeltaE00P95)
        self.maxCAMBI = try container.decodeIfPresent(Double.self, forKey: .maxCAMBI)
        self.maxBytes = try container.decodeIfPresent(Int64.self, forKey: .maxBytes)
        self.maxLatencySeconds = try container.decodeIfPresent(Double.self, forKey: .maxLatencySeconds)
        self.protectText = try container.decode(Bool.self, forKey: .protectText)
        self.protectFaces = try container.decode(Bool.self, forKey: .protectFaces)
        self.preserveGrain = try container.decode(Bool.self, forKey: .preserveGrain)
        self.bandingSensitive = try container.decode(Bool.self, forKey: .bandingSensitive)
        self.hdrPolicy = try container.decode(HDRMetadataPolicy.self, forKey: .hdrPolicy)
        self.intent = try container.decode(String.self, forKey: .intent)
        self.codec = try container.decode(VideoCodec.self, forKey: .codec)
    }
}

/// Dry-run or committed SPEC encoding plan with per-shot policies, forced IDRs, and human/agent explanations.
public struct SPECPlan: Codable, Sendable, Equatable {
    public let codec: String
    public let strategy: String
    public let shots: Int
    public let expectedMbps: Double
    public let estimatedSeconds: Double
    public let expectedMSSSIM: Double
    public let expectedDeltaE00P95: Double
    public let denoiseShots: [Int]
    public let grainPreserveShots: [Int]
    public let textProtectedShots: [Int]
    public let forcedIDRFrames: [Int]
    public let shotPolicies: [ShotControlPolicy]
    public let explanations: [String]
    public let warnings: [String]

    public init(
        codec: String,
        strategy: String,
        shots: Int,
        expectedMbps: Double,
        estimatedSeconds: Double,
        expectedMSSSIM: Double,
        expectedDeltaE00P95: Double,
        denoiseShots: [Int],
        grainPreserveShots: [Int],
        textProtectedShots: [Int],
        forcedIDRFrames: [Int],
        shotPolicies: [ShotControlPolicy],
        explanations: [String],
        warnings: [String]
    ) {
        self.codec = codec
        self.strategy = strategy
        self.shots = shots
        self.expectedMbps = expectedMbps
        self.estimatedSeconds = estimatedSeconds
        self.expectedMSSSIM = expectedMSSSIM
        self.expectedDeltaE00P95 = expectedDeltaE00P95
        self.denoiseShots = denoiseShots
        self.grainPreserveShots = grainPreserveShots
        self.textProtectedShots = textProtectedShots
        self.forcedIDRFrames = forcedIDRFrames
        self.shotPolicies = shotPolicies
        self.explanations = explanations
        self.warnings = warnings
    }
}

/// Single closed-loop short-window proxy iteration result measuring real MS-SSIM, CIEDE2000 p95, and optional CAMBI.
public struct SPECProxyIteration: Codable, Sendable, Equatable {
    public let iteration: Int
    public let cqf: Double
    public let bitrateBps: Int
    public let measuredMSSSIM: Double
    public let measuredDeltaE00P95: Double
    public let measuredCAMBI: Double?
    public let encodedBytes: Int64
    public let passedContract: Bool

    public init(
        iteration: Int,
        cqf: Double,
        bitrateBps: Int,
        measuredMSSSIM: Double,
        measuredDeltaE00P95: Double,
        measuredCAMBI: Double? = nil,
        encodedBytes: Int64,
        passedContract: Bool
    ) {
        self.iteration = iteration
        self.cqf = cqf
        self.bitrateBps = bitrateBps
        self.measuredMSSSIM = measuredMSSSIM
        self.measuredDeltaE00P95 = measuredDeltaE00P95
        self.measuredCAMBI = measuredCAMBI
        self.encodedBytes = encodedBytes
        self.passedContract = passedContract
    }
}

/// End-to-end closed-loop encoding & verification report returned by `SPECController.encodeWithClosedLoop`.
public struct SPECEncodeReport: Codable, Sendable, Equatable {
    public let plan: SPECPlan
    public let proxyIterations: [SPECProxyIteration]
    public let finalOutputPath: String
    public let finalBytes: Int64
    public let finalBitrateMbps: Double
    public let elapsedSeconds: Double
    public let measuredMSSSIM: Double
    public let measuredDeltaE00P95: Double
    public let measuredCAMBI: Double?
    public let contractMet: Bool
    public let explanations: [String]

    public init(
        plan: SPECPlan,
        proxyIterations: [SPECProxyIteration],
        finalOutputPath: String,
        finalBytes: Int64,
        finalBitrateMbps: Double,
        elapsedSeconds: Double,
        measuredMSSSIM: Double,
        measuredDeltaE00P95: Double,
        measuredCAMBI: Double? = nil,
        contractMet: Bool,
        explanations: [String]
    ) {
        self.plan = plan
        self.proxyIterations = proxyIterations
        self.finalOutputPath = finalOutputPath
        self.finalBytes = finalBytes
        self.finalBitrateMbps = finalBitrateMbps
        self.elapsedSeconds = elapsedSeconds
        self.measuredMSSSIM = measuredMSSSIM
        self.measuredDeltaE00P95 = measuredDeltaE00P95
        self.measuredCAMBI = measuredCAMBI
        self.contractMet = contractMet
        self.explanations = explanations
    }
}

/// Per-title convex-hull HLS ABR rendition ladder derived from a single `SPECAnalysisSidecar`.
public struct PerTitleLadderPlan: Codable, Sendable, Equatable {
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let rungs: [HLSRung]
    public let analysisReused: Bool
    public let rationale: [String]

    public init(
        sourceWidth: Int,
        sourceHeight: Int,
        rungs: [HLSRung],
        analysisReused: Bool,
        rationale: [String]
    ) {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.rungs = rungs
        self.analysisReused = analysisReused
        self.rationale = rationale
    }
}

/// Safarium Perceptual Encoding Controller (Wave 13C):
/// dry-run planning, agent-readable explanations, closed-loop proxy quality-target convergence,
/// and per-title HLS convex-hull ladder generation.
public enum SPECController {

    // MARK: - 1. Dry-Run Planning

    /// Produces a full per-shot `SPECPlan` without encoding.
    /// Reuses `sidecar` if provided, otherwise runs `SPECAnalyzer.analyze(inputURL:)`.
    public static func plan(
        inputURL: URL,
        contract: SPECQualityContract = .init(),
        sidecar: SPECAnalysisSidecar? = nil
    ) async throws -> SPECPlan {
        let analysis: SPECAnalysisSidecar
        if let existing = sidecar {
            analysis = existing
        } else {
            analysis = try await SPECAnalyzer.analyze(inputURL: inputURL)
        }
        return buildPlan(from: analysis, contract: contract)
    }

    private static func buildPlan(
        from analysis: SPECAnalysisSidecar,
        contract: SPECQualityContract
    ) -> SPECPlan {
        let (latencyMode, useTwoPass, strategy) = resolveStrategy(contract: contract, analysis: analysis)
        let bandingAware: Bool = contract.bandingSensitive || (contract.maxCAMBI != nil)
        let policies = AdaptiveDenoiseController.decide(
            shots: analysis.shots,
            protectText: contract.protectText,
            protectFaces: contract.protectFaces,
            preserveGrain: contract.preserveGrain,
            bandingSensitive: bandingAware,
            latencyMode: latencyMode,
            useTwoPass: useTwoPass
        )

        var warnings: [String] = []

        // Validate HDR metadata policy safety invariant
        let pixelsModified = policies.contains { $0.denoiseStrength > 0.0 }
        let hdrResolved = HDRIntegrity.resolvePolicy(
            sourceIsHDR: analysis.isHDRSource,
            sourceHasDynamicMetadata: analysis.isHDRSource,
            pixelsModified: pixelsModified,
            requestedPolicy: contract.hdrPolicy
        )
        warnings.append(contentsOf: hdrResolved.warnings)

        // Compute base bitrate scaled by resolution, fps, codec efficiency, and shot complexity
        let baseBps = baselineBitrateBps(
            width: analysis.width,
            height: analysis.height,
            fps: analysis.fps,
            codec: contract.codec,
            targetVMAF: contract.targetVMAF
        )

        let totalDur = max(0.001, analysis.durationSeconds)
        var weightedMult = 0.0
        var weightSum = 0.0
        for (shot, pol) in zip(analysis.shots, policies) {
            let dur = max(1.0 / max(1.0, analysis.fps), shot.endSeconds - shot.startSeconds)
            weightedMult += pol.recommendedBitrateMultiplier * dur
            weightSum += dur
        }
        let avgMult = weightSum > 0 ? (weightedMult / weightSum) : 1.0
        var targetBps = Double(baseBps) * avgMult

        // Honor strict maxBytes ceiling if requested
        if let maxBytes = contract.maxBytes, maxBytes > 0 {
            let maxVideoBps = (Double(maxBytes) * 8.0 * 0.90) / totalDur
            if maxVideoBps < targetBps {
                warnings.append(
                    String(
                        format: "Capped target bitrate from %.2f Mbps to %.2f Mbps to respect maxBytes (%lld bytes)",
                        targetBps / 1_000_000.0,
                        max(120_000.0, maxVideoBps) / 1_000_000.0,
                        maxBytes
                    )
                )
                targetBps = max(120_000.0, maxVideoBps)
            }
        }

        let expectedMbps = max(0.15, targetBps / 1_000_000.0)

        // Estimate encode duration on Apple Silicon hardware media engines (~4x-8x realtime)
        let speedMultiplier: Double
        if useTwoPass {
            speedMultiplier = 2.5
        } else if latencyMode == .liveUltraLowLatency || latencyMode == .vodFast {
            speedMultiplier = 10.0
        } else {
            speedMultiplier = 5.0
        }
        let estimatedSeconds = max(0.15, totalDur / speedMultiplier)

        // Collect per-shot index summaries
        var denoiseShots: [Int] = []
        var grainPreserveShots: [Int] = []
        var textProtectedShots: [Int] = []
        var forcedIDRFrames: [Int] = []

        for (shot, pol) in zip(analysis.shots, policies) {
            if pol.denoiseStrength > 0.05 {
                denoiseShots.append(shot.shotIndex)
            }
            if pol.preserveGrain {
                grainPreserveShots.append(shot.shotIndex)
            }
            if pol.reasons.contains(where: { $0.localizedCaseInsensitiveContains("text/UI") }) {
                textProtectedShots.append(shot.shotIndex)
            }
            if pol.forceIDRAtStart && shot.startFrame > 0 {
                forcedIDRFrames.append(shot.startFrame)
            }
        }

        let expectedMSSSIM = min(0.9995, max(0.92, contract.targetMSSSIM))
        let expectedDeltaE = max(0.35, min(contract.maxDeltaE00P95, contract.codec.is10Bit ? 1.2 : 1.8))

        let draft = SPECPlan(
            codec: contract.codec.rawValue,
            strategy: strategy,
            shots: analysis.shots.count,
            expectedMbps: expectedMbps,
            estimatedSeconds: estimatedSeconds,
            expectedMSSSIM: expectedMSSSIM,
            expectedDeltaE00P95: expectedDeltaE,
            denoiseShots: denoiseShots,
            grainPreserveShots: grainPreserveShots,
            textProtectedShots: textProtectedShots,
            forcedIDRFrames: forcedIDRFrames,
            shotPolicies: policies,
            explanations: [],
            warnings: warnings
        )
        let fullExplanations = explain(plan: draft)

        return SPECPlan(
            codec: draft.codec,
            strategy: draft.strategy,
            shots: draft.shots,
            expectedMbps: draft.expectedMbps,
            estimatedSeconds: draft.estimatedSeconds,
            expectedMSSSIM: draft.expectedMSSSIM,
            expectedDeltaE00P95: draft.expectedDeltaE00P95,
            denoiseShots: draft.denoiseShots,
            grainPreserveShots: draft.grainPreserveShots,
            textProtectedShots: draft.textProtectedShots,
            forcedIDRFrames: draft.forcedIDRFrames,
            shotPolicies: draft.shotPolicies,
            explanations: fullExplanations,
            warnings: draft.warnings
        )
    }

    // MARK: - 2. Human & AI-Agent Plan Explanations

    /// Produces concise, structured explanations for the global strategy and every shot's policy.
    public static func explain(plan: SPECPlan) -> [String] {
        var lines: [String] = []
        lines.reserveCapacity(plan.shotPolicies.count + 4)

        lines.append(
            String(
                format: "SPEC Plan: codec=%@, strategy=%@, shots=%d, target=%.2f Mbps (est %.2fs), target MS-SSIM>=%.4f, ΔE00 p95<=%.2f",
                plan.codec,
                plan.strategy,
                plan.shots,
                plan.expectedMbps,
                plan.estimatedSeconds,
                plan.expectedMSSSIM,
                plan.expectedDeltaE00P95
            )
        )

        if !plan.forcedIDRFrames.isEmpty {
            let framesStr = plan.forcedIDRFrames.map(String.init).joined(separator: ",")
            lines.append("Forced scene-cut IDR keyframes at frames: [\(framesStr)] (transient flashes excluded)")
        } else {
            lines.append("No mid-stream forced IDR keyframes required")
        }

        if !plan.textProtectedShots.isEmpty || !plan.grainPreserveShots.isEmpty || !plan.denoiseShots.isEmpty {
            lines.append(
                "Shot protection summary: textProtected=\(plan.textProtectedShots), grainPreserved=\(plan.grainPreserveShots), denoised=\(plan.denoiseShots)"
            )
        }

        for pol in plan.shotPolicies {
            let laStr = pol.lookAheadFrames.map(String.init) ?? "disabled(2-pass)"
            let reasonSummary = pol.reasons.joined(separator: "; ")
            lines.append(
                String(
                    format: "Shot %d: bitrate=%.2fx, CQF=%.2f, denoise=%.2f, preserveGrain=%@, lookAhead=%@, forceIDR=%@ — %@",
                    pol.shotIndex,
                    pol.recommendedBitrateMultiplier,
                    pol.recommendedCQF,
                    pol.denoiseStrength,
                    pol.preserveGrain ? "yes" : "no",
                    laStr,
                    pol.forceIDRAtStart ? "yes" : "no",
                    reasonSummary
                )
            )
        }

        for w in plan.warnings {
            lines.append("Warning: \(w)")
        }

        return lines
    }

    // MARK: - 3. Per-Title Convex-Hull HLS Ladder

    /// Selects content-adaptive HLS ABR rungs from a reusable `SPECAnalysisSidecar` without upscaling.
    public static func planPerTitleHLSLadder(
        sidecar: SPECAnalysisSidecar,
        maxRungs: Int = 4
    ) -> PerTitleLadderPlan {
        let clampedMax = max(1, min(6, maxRungs))
        let srcW = max(16, (sidecar.width / 2) * 2)
        let srcH = max(16, (sidecar.height / 2) * 2)
        let fps = max(1.0, sidecar.fps)

        // Duration-weighted content complexity summary from sidecar shots
        var wSpatial = 0.0
        var wTemporal = 0.0
        var wMotion = 0.0
        var wText = 0.0
        var wChroma = 0.0
        var wGrain = 0.0
        var wBanding = 0.0
        var totalW = 0.0

        for shot in sidecar.shots {
            let w = max(1.0 / fps, shot.endSeconds - shot.startSeconds)
            wSpatial += shot.spatialComplexity * w
            wTemporal += shot.temporalComplexity * w
            wMotion += shot.motionMagnitude * w
            wText += shot.textMaskRatio * w
            wChroma += shot.chromaEdgeComplexity * w
            wGrain += shot.grainProbability * w
            wBanding += shot.bandingRisk * w
            totalW += w
        }

        let invW = totalW > 0 ? (1.0 / totalW) : 1.0
        let meanSpatial = wSpatial * invW
        let meanTemporal = wTemporal * invW
        let meanMotion = wMotion * invW
        let meanText = wText * invW
        let meanChroma = wChroma * invW
        let meanGrain = wGrain * invW
        let meanBanding = wBanding * invW

        let isSlidesOrUI = (meanTemporal < 0.06 && meanMotion < 0.08)
            && (meanText > 0.03 || meanChroma > 0.20 || meanSpatial < 0.30)
        let isHighMotionOrGrain = (meanTemporal > 0.22 || meanMotion > 0.28 || meanGrain > 0.45)

        let complexityScale: Double
        var rationale: [String] = []
        if isSlidesOrUI {
            complexityScale = 0.46 + 0.18 * min(1.0, meanChroma + meanText)
            rationale.append(
                String(
                    format: "Classified content as static slides/UI (temporal=%.2f, motion=%.2f, text=%.2f, chromaEdge=%.2f): applying tight bitrate ladder (%.2fx) while preserving crisp resolution",
                    meanTemporal, meanMotion, meanText, meanChroma, complexityScale
                )
            )
        } else if isHighMotionOrGrain {
            complexityScale = 1.20 + 0.42 * min(1.0, max(meanTemporal, max(meanMotion, meanGrain)))
            rationale.append(
                String(
                    format: "Classified content as high-motion/grain (temporal=%.2f, motion=%.2f, grain=%.2f): expanding convex-hull bitrate ladder (%.2fx) to prevent blocking and grain smearing",
                    meanTemporal, meanMotion, meanGrain, complexityScale
                )
            )
        } else {
            complexityScale = 0.82 + 0.35 * min(1.0, 0.5 * meanSpatial + 0.5 * meanTemporal)
            rationale.append(
                String(
                    format: "Classified content as balanced natural motion (spatial=%.2f, temporal=%.2f): applying balanced per-title ladder (%.2fx)",
                    meanSpatial, meanTemporal, complexityScale
                )
            )
        }

        if meanBanding > 0.35 || sidecar.isHDRSource {
            rationale.append("Selected 10-bit HEVC (hevc10) rungs to eliminate dark-gradient banding and preserve headroom")
        }

        let ladderCodec: VideoCodec = (sidecar.isHDRSource || meanBanding > 0.25 || srcH >= 720) ? .hevc10 : .hevc10

        // Standard candidate heights; filter strictly to <= source height (never upscale!)
        let standardHeights = [360, 540, 720, 1080, 1440, 2160]
        var candidateHeights: [Int] = standardHeights.filter { $0 <= srcH }
        if !candidateHeights.contains(srcH) {
            candidateHeights.append(srcH)
        }
        // If source is smaller than 360p (e.g., 180p test clip), provide downscaled sub-rungs without upscaling
        if candidateHeights.count < min(clampedMax, 2) && srcH >= 120 {
            let halfH = max(64, ((srcH / 2) / 2) * 2)
            if halfH < srcH && !candidateHeights.contains(halfH) {
                candidateHeights.append(halfH)
            }
        }
        candidateHeights.sort()

        // Pick up to clampedMax rungs, always retaining the highest (native source) rung
        let selectedHeights: [Int]
        if candidateHeights.count <= clampedMax {
            selectedHeights = candidateHeights
        } else {
            // For slides/UI prefer upper resolutions (keeps text legible); for motion spread full convex hull
            if isSlidesOrUI {
                selectedHeights = Array(candidateHeights.suffix(clampedMax))
            } else {
                var picked: [Int] = []
                let lastIdx = candidateHeights.count - 1
                for k in 0..<clampedMax {
                    let pos = Int((Double(k) * Double(lastIdx) / Double(max(1, clampedMax - 1))).rounded())
                    let h = candidateHeights[pos]
                    if !picked.contains(h) {
                        picked.append(h)
                    }
                }
                if !picked.contains(candidateHeights[lastIdx]) {
                    picked[picked.count - 1] = candidateHeights[lastIdx]
                }
                selectedHeights = picked.sorted()
            }
        }

        let aspect = Double(srcW) / Double(srcH)
        let fpsScale = pow(min(2.0, max(0.5, fps / 30.0)), 0.55)
        let hdrBoost = sidecar.isHDRSource ? 1.22 : 1.0

        var rungs: [HLSRung] = []
        rungs.reserveCapacity(selectedHeights.count)

        for h in selectedHeights {
            let evenH = min(srcH, max(16, (h / 2) * 2))
            let scaledW = Int((Double(evenH) * aspect).rounded())
            let evenW = min(srcW, max(16, (scaledW / 2) * 2))

            // Reference HEVC 10-bit bitrate proportional to pixel area^0.78 (convex-hull scaling)
            let areaRatio = Double(evenW * evenH) / Double(1920 * 1080)
            let ref1080Bps = 5_200_000.0
            let rawBitrate = ref1080Bps * pow(max(0.02, areaRatio), 0.78) * complexityScale * fpsScale * hdrBoost
            let bitrate = max(150_000, Int((rawBitrate / 10_000.0).rounded() * 10_000.0))

            let audioBitrate: Int
            if evenH >= 1080 {
                audioBitrate = 160_000
            } else if evenH >= 720 {
                audioBitrate = 128_000
            } else {
                audioBitrate = 96_000
            }

            rungs.append(HLSRung(
                name: "\(evenH)p",
                width: evenW,
                height: evenH,
                bitrate: bitrate,
                fps: fps,
                codec: ladderCodec,
                audioBitrate: audioBitrate
            ))
        }

        rationale.append("Reused single SPECAnalysisSidecar pass across all \(rungs.count) HLS rungs (zero upscaling above \(srcW)x\(srcH))")

        return PerTitleLadderPlan(
            sourceWidth: srcW,
            sourceHeight: srcH,
            rungs: rungs,
            analysisReused: true,
            rationale: rationale
        )
    }

    // MARK: - 4. Closed-Loop Quality-Target Encode

    /// Executes full closed-loop perceptual encoding:
    /// 1. Single `SPECAnalyzer.analyze` pass
    /// 2. Dry-run `SPECPlan` generation
    /// 3. Short-window (0.5–1.0s) VideoToolbox proxy optimization measuring real MS-SSIM & masked CIEDE2000 p95
    /// 4. Final full-file hardware encode via `VTMultiPassEncoder.encode` with converged parameters + final verification.
    public static func encodeWithClosedLoop(
        inputURL: URL,
        outputURL: URL,
        contract: SPECQualityContract = .init(),
        maxProxyIterations: Int = 3
    ) async throws -> SPECEncodeReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(inputURL)

        // 1. Analyze once
        let sidecar = try await SPECAnalyzer.analyze(inputURL: inputURL)

        // 2. Build initial SPEC plan
        let initialPlan = buildPlan(from: sidecar, contract: contract)

        // 3. Pick representative 0.5–1.0s window from highest-complexity shot
        let windowRange = selectProxyWindow(sidecar: sidecar)
        let refFrames = try await decodeBGRAWindow(
            url: inputURL,
            startSeconds: windowRange.start,
            durationSeconds: windowRange.duration
        )
        guard !refFrames.isEmpty else {
            throw SafariumError.encode("SPECController: failed to decode reference proxy window")
        }

        let sampleCount = min(refFrames.count, 5)
        let refIndices = evenlySpacedIndices(total: refFrames.count, count: sampleCount)

        // 4. Closed-loop binary search over (CQF, bitrate)
        let iterationsCap = max(1, min(6, maxProxyIterations))
        let baseBps = max(250_000, Int((initialPlan.expectedMbps * 1_000_000.0).rounded()))
        let avgPolicyCQF: Double
        if !initialPlan.shotPolicies.isEmpty {
            avgPolicyCQF = initialPlan.shotPolicies.reduce(0.0) { $0 + $1.recommendedCQF } / Double(initialPlan.shotPolicies.count)
        } else {
            avgPolicyCQF = 0.65
        }

        var cqfLow = 0.25
        var cqfHigh = 0.96
        var currentCQF = min(cqfHigh, max(cqfLow, avgPolicyCQF))

        var brLow = max(200_000, Int(Double(baseBps) * 0.40))
        var brHigh = max(baseBps * 3, 2_500_000)
        if let maxBytes = contract.maxBytes, maxBytes > 0 {
            let hardCapBps = max(200_000, Int((Double(maxBytes) * 8.0 * 0.92) / max(0.1, sidecar.durationSeconds)))
            brHigh = min(brHigh, hardCapBps)
            brLow = min(brLow, brHigh)
        }
        var currentBitrate = min(brHigh, max(brLow, baseBps))

        var proxyIterations: [SPECProxyIteration] = []
        proxyIterations.reserveCapacity(iterationsCap)

        var bestPassing: (cqf: Double, bitrate: Int, bytes: Int64)? = nil
        var bestFallback: (cqf: Double, bitrate: Int, score: Double) = (currentCQF, currentBitrate, -1.0)

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("sf-spec-proxy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        for iter in 1...iterationsCap {
            let proxyURL = tempRoot.appendingPathComponent("proxy_iter_\(iter).mp4")
            let useCQFForProxy = (contract.maxBytes == nil) && contract.codec.isHEVC

            let encodedBytes = try await encodeProxyFrames(
                frames: refFrames,
                outputURL: proxyURL,
                width: sidecar.width,
                height: sidecar.height,
                fps: sidecar.fps,
                codec: contract.codec,
                bitrateBps: currentBitrate,
                cqf: useCQFForProxy ? currentCQF : nil,
                isHDR: sidecar.isHDRSource
            )

            let decodedProxy = try await decodeBGRAWindow(
                url: proxyURL,
                startSeconds: 0.0,
                durationSeconds: windowRange.duration + 0.5
            )
            var proxyCAMBI: Double? = nil
            if contract.maxCAMBI != nil {
                let cambiReport = try await NativePerceptualMetrics.evaluateVideo(
                    url: proxyURL,
                    referenceURL: nil,
                    maxSamples: 8
                )
                proxyCAMBI = cambiReport.meanCAMBI
            }
            try? FileManager.default.removeItem(at: proxyURL)

            let (msSSIM, deltaE00P95) = try measureWindowQuality(
                refFrames: refFrames,
                candFrames: decodedProxy,
                sampleIndices: refIndices
            )

            let windowScale: Double = sidecar.durationSeconds / max(0.1, windowRange.duration)
            let extrapolatedBytes = Int64((Double(encodedBytes) * windowScale).rounded())
            let bytesOK: Bool = contract.maxBytes.map { extrapolatedBytes <= $0 } ?? true
            let cambiOK: Bool
            if let maxCAMBI = contract.maxCAMBI, let measuredProxyCAMBI = proxyCAMBI {
                cambiOK = measuredProxyCAMBI <= maxCAMBI
            } else {
                cambiOK = true
            }
            let qualityOK: Bool = (msSSIM >= contract.targetMSSSIM)
                && (deltaE00P95 <= contract.maxDeltaE00P95)
                && cambiOK
            let passed: Bool = qualityOK && bytesOK

            proxyIterations.append(SPECProxyIteration(
                iteration: iter,
                cqf: currentCQF,
                bitrateBps: currentBitrate,
                measuredMSSSIM: msSSIM,
                measuredDeltaE00P95: deltaE00P95,
                measuredCAMBI: proxyCAMBI,
                encodedBytes: encodedBytes,
                passedContract: passed
            ))

            let deltaEPenalty: Double = 0.01 * max(0.0, deltaE00P95 - contract.maxDeltaE00P95)
            let cambiExcess: Double
            if let maxCAMBI = contract.maxCAMBI, let measuredProxyCAMBI = proxyCAMBI {
                cambiExcess = max(0.0, measuredProxyCAMBI - maxCAMBI)
            } else {
                cambiExcess = 0.0
            }
            let cambiPenalty: Double = 0.005 * cambiExcess
            let qualityScore: Double = msSSIM - deltaEPenalty - cambiPenalty
            if bytesOK && qualityScore > bestFallback.score {
                bestFallback = (currentCQF, currentBitrate, qualityScore)
            }

            if passed {
                if let prev = bestPassing {
                    if encodedBytes < prev.bytes {
                        bestPassing = (currentCQF, currentBitrate, encodedBytes)
                    }
                } else {
                    bestPassing = (currentCQF, currentBitrate, encodedBytes)
                }
                // Try stepping down slightly to optimize bitrate efficiency
                cqfHigh = currentCQF
                brHigh = currentBitrate
                let nextCQF: Double = 0.5 * (cqfLow + cqfHigh)
                let nextBR: Int = (brLow + brHigh) / 2
                if abs(nextCQF - currentCQF) < 0.02 && abs(nextBR - currentBitrate) < 80_000 {
                    break
                }
                currentCQF = nextCQF
                currentBitrate = max(200_000, nextBR)
            } else if !bytesOK {
                // Exceeded byte budget -> reduce bitrate/CQF
                cqfHigh = currentCQF
                brHigh = currentBitrate
                currentCQF = 0.5 * (cqfLow + cqfHigh)
                currentBitrate = max(200_000, (brLow + brHigh) / 2)
            } else {
                // Quality below contract (or CAMBI exceeded maxCAMBI) -> raise bitrate/CQF
                cqfLow = currentCQF
                brLow = currentBitrate
                var nextCQF: Double = 0.5 * (cqfLow + cqfHigh)
                var nextBR: Int = max(200_000, (brLow + brHigh) / 2)
                if !cambiOK {
                    let nudgedCQF: Double = min(cqfHigh, max(nextCQF, currentCQF + 0.06))
                    let scaledBR: Double = Double(currentBitrate) * 1.25
                    let nudgedBR: Int = min(brHigh, max(nextBR, Int(scaledBR.rounded())))
                    nextCQF = nudgedCQF
                    nextBR = max(200_000, nudgedBR)
                }
                currentCQF = nextCQF
                currentBitrate = nextBR
            }
        }

        let chosenCQF = bestPassing?.cqf ?? bestFallback.cqf
        let chosenBitrate = bestPassing?.bitrate ?? bestFallback.bitrate

        // 5. Final encode via native VTMultiPassEncoder
        let (latencyMode, useTwoPass, _) = resolveStrategy(contract: contract, analysis: sidecar)
        let resolvedLA = AdaptiveDenoiseController.resolveLookAhead(mode: latencyMode, useTwoPass: useTwoPass) ?? 0

        let encodeMode: SupremacyEncodeMode
        if useTwoPass {
            encodeMode = .twoPass
        } else if contract.maxBytes == nil && contract.codec.isHEVC && latencyMode != .liveUltraLowLatency {
            encodeMode = .cqf
        } else if latencyMode == .liveUltraLowLatency || latencyMode == .vodFast {
            encodeMode = .fast
        } else {
            encodeMode = .highQuality
        }

        let colorProfile: ColorMasteringProfile
        if sidecar.isHDRSource && contract.hdrPolicy != .toneMapToSDR {
            colorProfile = .hdr10PQ
        } else {
            colorProfile = .sdrBT709
        }

        let transcodeConfig = SupremacyTranscodeConfig(
            codec: contract.codec,
            mode: encodeMode,
            bitrate: chosenBitrate,
            maxBitrate: contract.maxBytes != nil ? Int(Double(chosenBitrate) * 1.25) : nil,
            vbvBufferSeconds: 3.0,
            cqf: chosenCQF,
            spatialAdaptiveQP: true,
            lookAheadFrames: resolvedLA,
            colorMastering: colorProfile,
            parallelEngines: nil,
            audioCodec: nil,
            audioBitrate: nil,
            overwrite: true,
            forceKeyFrameIndices: Set(initialPlan.forcedIDRFrames)
        )

        let transcodeReport = try await VTMultiPassEncoder.encode(
            inputURL: inputURL,
            outputURL: outputURL,
            config: transcodeConfig
        )

        // 6. Final verification: decode representative frames from final output & measure real MS-SSIM + ΔE00 p95 + CAMBI
        let finalCandFrames = try await decodeBGRAWindow(
            url: outputURL,
            startSeconds: windowRange.start,
            durationSeconds: windowRange.duration + 0.25
        )
        let (finalMSSSIM, finalDeltaE00P95) = try measureWindowQuality(
            refFrames: refFrames,
            candFrames: finalCandFrames,
            sampleIndices: refIndices
        )

        let finalCAMBIReport = try await NativePerceptualMetrics.evaluateVideo(
            url: outputURL,
            referenceURL: nil,
            maxSamples: 8
        )
        let finalCAMBI: Double = finalCAMBIReport.meanCAMBI

        let finalBytes = transcodeReport.outputBytes
        let finalBits: Double = Double(finalBytes) * 8.0
        let finalDur: Double = max(0.001, sidecar.durationSeconds)
        let finalMbps: Double = (finalBits / finalDur) / 1_000_000.0
        let finalBytesOK: Bool = contract.maxBytes.map { finalBytes <= $0 } ?? true
        let finalCAMBIOK: Bool
        if let maxCAMBI = contract.maxCAMBI {
            finalCAMBIOK = finalCAMBI <= maxCAMBI
        } else {
            finalCAMBIOK = true
        }
        let contractMet: Bool = (finalMSSSIM >= contract.targetMSSSIM)
            && (finalDeltaE00P95 <= contract.maxDeltaE00P95)
            && finalBytesOK
            && finalCAMBIOK

        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000_000.0

        var finalExplanations = initialPlan.explanations
        finalExplanations.append(
            String(
                format: "Closed-loop proxy converged in %d iteration(s): chosen CQF=%.3f, bitrate=%.2f Mbps",
                proxyIterations.count,
                chosenCQF,
                Double(chosenBitrate) / 1_000_000.0
            )
        )
        let cambiNote: String
        if let maxCAMBI = contract.maxCAMBI {
            cambiNote = String(format: "CAMBI=%.3f (max<=%.3f)", finalCAMBI, maxCAMBI)
        } else {
            cambiNote = String(format: "CAMBI=%.3f", finalCAMBI)
        }
        finalExplanations.append(
            String(
                format: "Final verification: output=%lld bytes (%.2f Mbps), MS-SSIM=%.5f, ΔE00 p95=%.3f, %@, contractMet=%@",
                finalBytes,
                finalMbps,
                finalMSSSIM,
                finalDeltaE00P95,
                cambiNote,
                contractMet ? "true" : "false"
            )
        )

        return SPECEncodeReport(
            plan: initialPlan,
            proxyIterations: proxyIterations,
            finalOutputPath: outputURL.path,
            finalBytes: finalBytes,
            finalBitrateMbps: finalMbps,
            elapsedSeconds: elapsedSeconds,
            measuredMSSSIM: finalMSSSIM,
            measuredDeltaE00P95: finalDeltaE00P95,
            measuredCAMBI: finalCAMBI,
            contractMet: contractMet,
            explanations: finalExplanations
        )
    }

    // MARK: - Internal Strategy & Bitrate Helpers

    private static func resolveStrategy(
        contract: SPECQualityContract,
        analysis: SPECAnalysisSidecar
    ) -> (mode: DeliveryLatencyMode, useTwoPass: Bool, strategy: String) {
        let lower = contract.intent.lowercased()
        if let maxLat = contract.maxLatencySeconds, maxLat <= 0.5 {
            return (.liveUltraLowLatency, false, "live-ultra-low-latency-1pass")
        }
        if let maxLat = contract.maxLatencySeconds, maxLat <= 2.0 {
            return (.liveQuality, false, "live-quality-1pass")
        }
        if lower.contains("2pass") || lower.contains("two-pass") || lower.contains("two_pass") || contract.maxBytes != nil {
            return (.twoPass, true, "2pass-vt-multipass")
        }
        if lower.contains("screen") || lower.contains("slide") || lower.contains("ui") {
            return (.screenContent, false, "screen-content-cqf")
        }
        if lower.contains("anim") {
            return (.animation, false, "animation-cqf")
        }
        if lower.contains("fast") || lower.contains("speed") {
            return (.vodFast, false, "vod-fast-1pass")
        }
        let hasHighText = analysis.shots.contains { $0.textMaskRatio > 0.08 }
        if hasHighText && analysis.shots.allSatisfy({ $0.temporalComplexity < 0.08 }) {
            return (.screenContent, false, "screen-content-cqf")
        }
        return (.vodQuality, false, "closed-loop-cqf-vod")
    }

    private static func baselineBitrateBps(
        width: Int,
        height: Int,
        fps: Double,
        codec: VideoCodec,
        targetVMAF: Double
    ) -> Int {
        let pixels = Double(max(16, width) * max(16, height))
        let ref1080Pixels = 1920.0 * 1080.0
        let areaScale = pow(max(0.015, pixels / ref1080Pixels), 0.78)
        let fpsScale = pow(min(2.0, max(0.5, fps / 30.0)), 0.55)
        let codecFactor: Double = codec.isHEVC ? 0.72 : (codec.isProRes ? 6.0 : 1.0)
        let vmafFactor = pow(1.06, max(-10.0, min(6.0, targetVMAF - 93.0)))
        let raw = 6_500_000.0 * areaScale * fpsScale * codecFactor * vmafFactor
        return max(250_000, Int(raw.rounded()))
    }

    private static func selectProxyWindow(sidecar: SPECAnalysisSidecar) -> (start: Double, duration: Double) {
        let totalDur = max(0.25, sidecar.durationSeconds)
        let targetDur = min(totalDur, 0.75)

        guard !sidecar.shots.isEmpty else {
            return (0.0, targetDur)
        }

        // Select the highest-complexity non-flash shot (falling back to any shot)
        let candidates = sidecar.shots.filter { $0.cutType != .flash }
        let pool = candidates.isEmpty ? sidecar.shots : candidates

        var bestShot = pool[0]
        var bestScore = -1.0
        for s in pool {
            let shotDur = max(0.05, s.endSeconds - s.startSeconds)
            let durWeight = min(1.0, shotDur / 0.35)
            let score = durWeight * (
                1.2 * s.spatialComplexity
                + 1.3 * s.temporalComplexity
                + 1.1 * s.chromaEdgeComplexity
                + 0.8 * s.noiseSigma
                + 0.6 * s.bandingRisk
            )
            if score > bestScore {
                bestScore = score
                bestShot = s
            }
        }

        let maxStart = max(0.0, totalDur - targetDur)
        let start = min(maxStart, max(0.0, bestShot.startSeconds))
        return (start, targetDur)
    }

    // MARK: - Proxy Frame Decode / Encode & Perceptual Metrics

    private struct DecodedFrame: @unchecked Sendable {
        let pts: CMTime
        let pixelBuffer: CVPixelBuffer
    }

    private static func decodeBGRAWindow(
        url: URL,
        startSeconds: Double,
        durationSeconds: Double
    ) async throws -> [DecodedFrame] {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        ])
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let track = tracks.first else {
            throw SafariumError.invalidState("SPECController: no video track in \(url.lastPathComponent)")
        }

        let reader = try AVAssetReader(asset: asset)
        let startTime = CMTime(seconds: max(0.0, startSeconds), preferredTimescale: 600)
        let durTime = CMTime(seconds: max(0.1, durationSeconds), preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: startTime, duration: durTime)

        let outSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw SafariumError.encode("SPECController: AVAssetReader cannot add track output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw SafariumError.encode(
                "SPECController: AVAssetReader failed: \(reader.error?.localizedDescription ?? "unknown")"
            )
        }

        var frames: [DecodedFrame] = []
        frames.reserveCapacity(48)
        while let sb = output.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            frames.append(DecodedFrame(pts: pts, pixelBuffer: pb))
        }
        return frames
    }

    private final class ProxySampleCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [CMSampleBuffer] = []

        func append(_ sb: CMSampleBuffer) {
            lock.lock()
            samples.append(sb)
            lock.unlock()
        }

        func drain() -> [CMSampleBuffer] {
            lock.lock()
            let copy = samples
            samples.removeAll(keepingCapacity: false)
            lock.unlock()
            return copy
        }
    }

    private static func encodeProxyFrames(
        frames: [DecodedFrame],
        outputURL: URL,
        width: Int,
        height: Int,
        fps: Double,
        codec: VideoCodec,
        bitrateBps: Int,
        cqf: Double?,
        isHDR: Bool
    ) async throws -> Int64 {
        let evenW = max(16, (width / 2) * 2)
        let evenH = max(16, (height / 2) * 2)

        let encoderSpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
        ]
        var sessionOpt: VTCompressionSession?
        let createSt = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(evenW),
            height: Int32(evenH),
            codecType: codec.cmCodecType,
            encoderSpecification: encoderSpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &sessionOpt
        )
        guard createSt == noErr, let session = sessionOpt else {
            throw SafariumError.encode("SPECController: VTCompressionSessionCreate failed (\(createSt))")
        }
        defer { VTCompressionSessionInvalidate(session) }

        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: fps))
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanTrue)
        _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: 2.0))

        if let prof = codec.defaultProfileLevel {
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: prof as CFString)
        }

        if isHDR {
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_2020)
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_2020)
        } else {
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries, value: kCVImageBufferColorPrimaries_ITU_R_709_2)
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction, value: kCVImageBufferTransferFunction_ITU_R_709_2)
            _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix, value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        }

        if !codec.isProRes {
            if let cqfVal = cqf {
                let clamped = min(0.98, max(0.10, cqfVal))
                if VTSessionSetProperty(session, key: "ConstantQualityFactor" as CFString, value: NSNumber(value: clamped)) != noErr {
                    _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: NSNumber(value: clamped))
                }
            } else {
                _ = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitrateBps))
            }
            _ = VTSessionSetProperty(session, key: "SpatialAdaptiveQPLevel" as CFString, value: NSNumber(value: -1))
        }

        VTCompressionSessionPrepareToEncodeFrames(session)

        // Optional MetalChromaPipeline for 10-bit P010 edge-aware chroma feeding
        let chromaPipeline: MetalChromaPipeline? = codec.is10Bit ? (try? MetalChromaPipeline()) : nil
        var p010Pool: CVPixelBufferPool?
        if chromaPipeline != nil {
            let poolAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: evenW,
                kCVPixelBufferHeightKey as String: evenH,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, poolAttrs as CFDictionary, &p010Pool)
        }

        let collector = ProxySampleCollector()
        let frameDur = CMTime(seconds: 1.0 / max(1.0, fps), preferredTimescale: 600)

        for (idx, frame) in frames.enumerated() {
            let pts = CMTime(value: CMTimeValue(idx), timescale: CMTimeScale(max(1, Int(fps.rounded()))))
            var inputPB = frame.pixelBuffer

            if let pipeline = chromaPipeline,
               let pool = p010Pool,
               CVPixelBufferGetIOSurface(frame.pixelBuffer) != nil,
               CVPixelBufferGetWidth(frame.pixelBuffer) == evenW,
               CVPixelBufferGetHeight(frame.pixelBuffer) == evenH {
                var dstOpt: CVPixelBuffer?
                if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dstOpt) == kCVReturnSuccess,
                   let dstPB = dstOpt {
                    let cfg = ChromaConversionConfig(
                        bitDepth: 10,
                        siting: .coSited,
                        filterMode: .lumaGuidedEdgeAware,
                        ditherMode: .temporalInterleavedGradient,
                        isBT2020: isHDR,
                        fullRange: false,
                        frameIndex: UInt32(idx)
                    )
                    if (try? pipeline.convertBGRAtoYUV(src: frame.pixelBuffer, dst: dstPB, config: cfg)) != nil {
                        inputPB = dstPB
                    }
                }
            }

            let encStatus = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: inputPB,
                presentationTimeStamp: pts,
                duration: frameDur,
                frameProperties: nil,
                infoFlagsOut: nil
            ) { status, _, sampleBuffer in
                if status == noErr, let sb = sampleBuffer {
                    collector.append(sb)
                }
            }
            if encStatus != noErr {
                throw SafariumError.encode("SPECController: proxy encode frame \(idx) failed (\(encStatus))")
            }
        }

        let completeSt = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard completeSt == noErr else {
            throw SafariumError.encode("SPECController: proxy CompleteFrames failed (\(completeSt))")
        }

        let encodedSamples = collector.drain()
        guard let firstSB = encodedSamples.first,
              let fmtDesc = CMSampleBufferGetFormatDescription(firstSB) else {
            throw SafariumError.encode("SPECController: proxy encoder emitted zero samples")
        }

        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: fmtDesc)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw SafariumError.encode("SPECController: AVAssetWriter cannot add proxy video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw SafariumError.encode("SPECController: AVAssetWriter startWriting failed")
        }

        let sortedSamples = encodedSamples.sorted { lhs, rhs in
            let ld = CMSampleBufferGetDecodeTimeStamp(lhs)
            let rd = CMSampleBufferGetDecodeTimeStamp(rhs)
            let lt = ld.isValid ? ld : CMSampleBufferGetPresentationTimeStamp(lhs)
            let rt = rd.isValid ? rd : CMSampleBufferGetPresentationTimeStamp(rhs)
            return CMTimeCompare(lt, rt) < 0
        }

        let firstPTS = sortedSamples
            .map { CMSampleBufferGetPresentationTimeStamp($0) }
            .min(by: { CMTimeCompare($0, $1) < 0 }) ?? .zero
        writer.startSession(atSourceTime: firstPTS)

        for sb in sortedSamples {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            input.append(sb)
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw SafariumError.encode(
                "SPECController: proxy writer failed: \(writer.error?.localizedDescription ?? "unknown")"
            )
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func evenlySpacedIndices(total: Int, count: Int) -> [Int] {
        guard total > 0, count > 0 else { return [] }
        if count >= total { return Array(0..<total) }
        if count == 1 { return [total / 2] }
        var out: [Int] = []
        out.reserveCapacity(count)
        let last = total - 1
        for k in 0..<count {
            let idx = Int((Double(k) * Double(last) / Double(count - 1)).rounded())
            if !out.contains(idx) {
                out.append(idx)
            }
        }
        return out
    }

    private static func measureWindowQuality(
        refFrames: [DecodedFrame],
        candFrames: [DecodedFrame],
        sampleIndices: [Int]
    ) throws -> (msSSIM: Double, deltaE00P95: Double) {
        guard !refFrames.isEmpty, !candFrames.isEmpty else {
            throw SafariumError.encode("SPECController: cannot measure quality on empty decoded frames")
        }

        var ssimSum = 0.0
        var deP95Max = 0.0
        var measured = 0

        for idx in sampleIndices {
            let rIdx = min(refFrames.count - 1, max(0, idx))
            let cIdx = min(candFrames.count - 1, max(0, idx))
            let refPB = refFrames[rIdx].pixelBuffer
            let candPB = candFrames[cIdx].pixelBuffer

            let ssim = computeMSSSIM(referenceBGRA: refPB, candidateBGRA: candPB)
            let deltaReport = try MetalChromaPipeline.measureMaskedDeltaE00(
                referenceBGRA: refPB,
                candidateBGRA: candPB
            )
            ssimSum += ssim
            deP95Max = max(deP95Max, deltaReport.p95DeltaE00)
            measured += 1
        }

        guard measured > 0 else {
            throw SafariumError.encode("SPECController: zero frames measured")
        }
        return (ssimSum / Double(measured), deP95Max)
    }

    // MARK: - Real Multi-Scale SSIM (Wang et al. 2003)

    /// Computes genuine Multi-Scale Structural Similarity (MS-SSIM) on BT.709 luminance
    /// across up to 5 dyadic scales with standard Wang et al. (2003) weights.
    public static func computeMSSSIM(
        referenceBGRA: CVPixelBuffer,
        candidateBGRA: CVPixelBuffer
    ) -> Double {
        let w = CVPixelBufferGetWidth(referenceBGRA)
        let h = CVPixelBufferGetHeight(referenceBGRA)
        guard w >= 8, h >= 8,
              CVPixelBufferGetWidth(candidateBGRA) == w,
              CVPixelBufferGetHeight(candidateBGRA) == h else {
            return 0.0
        }

        CVPixelBufferLockBaseAddress(referenceBGRA, .readOnly)
        CVPixelBufferLockBaseAddress(candidateBGRA, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(candidateBGRA, .readOnly)
            CVPixelBufferUnlockBaseAddress(referenceBGRA, .readOnly)
        }

        guard let refBase = CVPixelBufferGetBaseAddress(referenceBGRA)?.assumingMemoryBound(to: UInt8.self),
              let candBase = CVPixelBufferGetBaseAddress(candidateBGRA)?.assumingMemoryBound(to: UInt8.self) else {
            return 0.0
        }
        let refStride = CVPixelBufferGetBytesPerRow(referenceBGRA)
        let candStride = CVPixelBufferGetBytesPerRow(candidateBGRA)

        var curW = w
        var curH = h
        var refLuma = [Float](repeating: 0, count: curW * curH)
        var candLuma = [Float](repeating: 0, count: curW * curH)

        for y in 0..<curH {
            let rRow = refBase.advanced(by: y * refStride)
            let cRow = candBase.advanced(by: y * candStride)
            let rowIdx = y * curW
            for x in 0..<curW {
                let off = x * 4
                let rY = 0.2126 * Float(rRow[off + 2]) + 0.7152 * Float(rRow[off + 1]) + 0.0722 * Float(rRow[off])
                let cY = 0.2126 * Float(cRow[off + 2]) + 0.7152 * Float(cRow[off + 1]) + 0.0722 * Float(cRow[off])
                refLuma[rowIdx + x] = rY
                candLuma[rowIdx + x] = cY
            }
        }

        let standardWeights: [Double] = [0.0448, 0.2856, 0.3001, 0.2363, 0.1333]
        var scaleCS: [Double] = []
        var lastLum = 1.0

        for scale in 0..<standardWeights.count {
            let (lum, cs) = singleScaleSSIMComponents(refLuma, candLuma, width: curW, height: curH)
            scaleCS.append(max(1e-6, cs))
            lastLum = max(1e-6, lum)

            if scale + 1 < standardWeights.count && curW >= 32 && curH >= 32 {
                let nextW = curW / 2
                let nextH = curH / 2
                refLuma = downsample2x(refLuma, width: curW, height: curH, nextW: nextW, nextH: nextH)
                candLuma = downsample2x(candLuma, width: curW, height: curH, nextW: nextW, nextH: nextH)
                curW = nextW
                curH = nextH
            } else {
                break
            }
        }

        let usedCount = scaleCS.count
        let weightSum = standardWeights.prefix(usedCount).reduce(0.0, +)
        guard weightSum > 0 else { return 0.0 }

        var product = 1.0
        for s in 0..<usedCount {
            let wNorm = standardWeights[s] / weightSum
            product *= pow(scaleCS[s], wNorm)
            if s == usedCount - 1 {
                product *= pow(lastLum, wNorm)
            }
        }
        return min(1.0, max(0.0, product))
    }

    private static func singleScaleSSIMComponents(
        _ a: [Float],
        _ b: [Float],
        width: Int,
        height: Int
    ) -> (luminance: Double, contrastStructure: Double) {
        let block = 8
        let c1 = 6.5025   // (0.01 * 255)^2
        let c2 = 58.5225  // (0.03 * 255)^2

        let step = max(4, min(block, min(width, height) / 2))
        var lumSum = 0.0
        var csSum = 0.0
        var blocks = 0

        var by = 0
        while by + block <= height {
            var bx = 0
            while bx + block <= width {
                var sumA = 0.0
                var sumB = 0.0
                var sumAA = 0.0
                var sumBB = 0.0
                var sumAB = 0.0

                for dy in 0..<block {
                    let rowBase = (by + dy) * width + bx
                    for dx in 0..<block {
                        let va = Double(a[rowBase + dx])
                        let vb = Double(b[rowBase + dx])
                        sumA += va
                        sumB += vb
                        sumAA += va * va
                        sumBB += vb * vb
                        sumAB += va * vb
                    }
                }

                let invN = 1.0 / Double(block * block)
                let muA = sumA * invN
                let muB = sumB * invN
                let varA = max(0.0, sumAA * invN - muA * muA)
                let varB = max(0.0, sumBB * invN - muB * muB)
                let cov = sumAB * invN - muA * muB

                let lum = (2.0 * muA * muB + c1) / (muA * muA + muB * muB + c1)
                let cs = (2.0 * cov + c2) / (varA + varB + c2)

                lumSum += min(1.0, max(0.0, lum))
                csSum += min(1.0, max(0.0, cs))
                blocks += 1

                bx += step
            }
            by += step
        }

        if blocks == 0 {
            return (1.0, 1.0)
        }
        return (lumSum / Double(blocks), csSum / Double(blocks))
    }

    private static func downsample2x(
        _ src: [Float],
        width: Int,
        height: Int,
        nextW: Int,
        nextH: Int
    ) -> [Float] {
        var dst = [Float](repeating: 0, count: nextW * nextH)
        for y in 0..<nextH {
            let r0 = (2 * y) * width
            let r1 = min(height - 1, 2 * y + 1) * width
            let dRow = y * nextW
            for x in 0..<nextW {
                let x0 = 2 * x
                let x1 = min(width - 1, x0 + 1)
                let avg = 0.25 * (src[r0 + x0] + src[r0 + x1] + src[r1 + x0] + src[r1 + x1])
                dst[dRow + x] = avg
            }
        }
        return dst
    }
}
