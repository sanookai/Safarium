import Foundation

// MARK: - Wave 13B: Adaptive Denoise & Per-Shot Rate-Control Auto-Tuner

/// Delivery latency and pass-structure regime used to resolve lookahead, GOP, and
/// VideoToolbox rate-control compatibility without API conflicts.
public enum DeliveryLatencyMode: String, Codable, Sendable, CaseIterable {
    case liveUltraLowLatency
    case liveQuality
    case vodFast
    case vodQuality
    case twoPass
    case screenContent
    case animation
}

/// Concrete per-shot encoding, denoising, lookahead, and IDR policy decided by `AdaptiveDenoiseController`.
public struct ShotControlPolicy: Codable, Sendable, Equatable {
    public let shotIndex: Int
    public let denoiseStrength: Float
    public let preserveGrain: Bool
    public let lookAheadFrames: Int?
    public let forceIDRAtStart: Bool
    public let recommendedBitrateMultiplier: Double
    public let recommendedCQF: Double
    public let reasons: [String]

    public init(
        shotIndex: Int,
        denoiseStrength: Float,
        preserveGrain: Bool,
        lookAheadFrames: Int?,
        forceIDRAtStart: Bool,
        recommendedBitrateMultiplier: Double,
        recommendedCQF: Double,
        reasons: [String]
    ) {
        self.shotIndex = shotIndex
        self.denoiseStrength = min(1.0, max(0.0, denoiseStrength))
        self.preserveGrain = preserveGrain
        self.lookAheadFrames = lookAheadFrames
        self.forceIDRAtStart = forceIDRAtStart
        self.recommendedBitrateMultiplier = recommendedBitrateMultiplier
        self.recommendedCQF = min(0.98, max(0.10, recommendedCQF))
        self.reasons = reasons
    }
}

/// Content-aware adaptive denoising, grain preservation, text/face protection, lookahead resolution,
/// and scene-cut IDR decision controller (Wave 13B).
public enum AdaptiveDenoiseController {

    /// Resolves the safe VideoToolbox `LookAheadFrames` count for the given delivery mode and pass count.
    ///
    /// - Strictly returns `nil` when `useTwoPass == true` or `mode == .twoPass` to avoid the VideoToolbox
    ///   `SuggestedLookAheadFrameCount` vs `VTMultiPassStorage` mutual-exclusion conflict.
    /// - Returns `0` for `.liveUltraLowLatency`.
    /// - Returns `2` for `.liveQuality`, `4` for `.vodFast`, `16` for `.vodQuality`/`.screenContent`, and `8` for `.animation`.
    public static func resolveLookAhead(mode: DeliveryLatencyMode, useTwoPass: Bool) -> Int? {
        if useTwoPass || mode == .twoPass {
            return nil
        }
        switch mode {
        case .liveUltraLowLatency:
            return 0
        case .liveQuality:
            return 2
        case .vodFast:
            return 4
        case .vodQuality, .screenContent:
            return 16
        case .animation:
            return 8
        case .twoPass:
            return nil
        }
    }

    /// Generates per-shot adaptive denoise, grain preservation, bitrate multiplier, CQF, lookahead,
    /// and IDR policies from `SPECShotMetrics`.
    public static func decide(
        shots: [SPECShotMetrics],
        protectText: Bool = true,
        protectFaces: Bool = true,
        preserveGrain: Bool = false,
        bandingSensitive: Bool = true,
        latencyMode: DeliveryLatencyMode = .vodQuality,
        useTwoPass: Bool = false
    ) -> [ShotControlPolicy] {
        let resolvedLookAhead = resolveLookAhead(mode: latencyMode, useTwoPass: useTwoPass)
        var policies: [ShotControlPolicy] = []
        policies.reserveCapacity(shots.count)

        for shot in shots {
            var denoiseStrength: Float = 0.0
            var effectivePreserveGrain = preserveGrain || (shot.grainProbability > 0.55)
            var bitrateMult = 1.0
            var cqf = 0.62
            var reasons: [String] = []

            // 1. Scene-transition IDR policy
            let forceIDR: Bool
            switch shot.cutType {
            case .hardCut:
                forceIDR = true
                reasons.append("Forced IDR keyframe at hard scene cut")
            case .uiTransition:
                forceIDR = true
                reasons.append("Forced IDR keyframe at sharp UI transition")
            case .flash:
                forceIDR = false
                reasons.append("Skipped forced IDR on transient flash frame")
            case .fade:
                forceIDR = false
                bitrateMult *= 1.06
                cqf += 0.03
                reasons.append("Avoided mid-fade IDR and boosted fade transition budget")
            case .pan:
                forceIDR = false
                bitrateMult *= 1.12
                cqf += 0.04
                reasons.append("Allocated extra motion budget for coherent camera pan")
            case .steady:
                forceIDR = false
            }

            // 2. Baseline complexity & motion budget
            let isStaticLowDetail = shot.temporalComplexity < 0.06
                && shot.spatialComplexity < 0.25
                && shot.chromaEdgeComplexity <= 0.30
                && shot.textMaskRatio <= 0.05
            let isHighMotionComplex = shot.temporalComplexity > 0.28
                || shot.motionMagnitude > 0.38
                || shot.spatialComplexity > 0.55

            if isStaticLowDetail {
                bitrateMult *= 0.72
                cqf -= 0.04
                reasons.append("Reduced bitrate budget for low-motion static shot")
            } else if isHighMotionComplex {
                let complexityPeak = max(shot.temporalComplexity, max(shot.motionMagnitude, shot.spatialComplexity))
                let boost = min(0.32, 0.12 + 0.22 * complexityPeak)
                bitrateMult *= (1.0 + boost)
                cqf += 0.07
                reasons.append("Boosted bitrate for high-motion/high-detail shot")
            }

            // 3. Evaluate text / saturated chroma edge protection
            let needsTextProtection = (protectText && shot.textMaskRatio > 0.05)
                || (shot.chromaEdgeComplexity > 0.45)

            // 4. Adaptive low-light noise denoising (before text/grain/face caps)
            let isNoisyCandidate = shot.noiseSigma > 0.25
                && !effectivePreserveGrain
                && !needsTextProtection
                && shot.textMaskRatio < 0.05

            if isNoisyCandidate {
                let norm = min(1.0, max(0.0, (shot.noiseSigma - 0.25) / 0.65))
                denoiseStrength = Float(0.20 + 0.40 * norm)
                reasons.append("Applied adaptive temporal denoise for low-light noise")
                // Denoising removes high-frequency entropy, modestly improving compression efficiency
                bitrateMult *= 0.94
            }

            // 5. Film grain preservation (strictly disables denoise & boosts bitrate +10%..+20%)
            if effectivePreserveGrain {
                denoiseStrength = 0.0
                effectivePreserveGrain = true
                let grainBoost = 0.10 + 0.10 * min(1.0, max(0.0, shot.grainProbability))
                bitrateMult *= (1.0 + grainBoost)
                cqf += 0.06
                reasons.append("Preserved film grain (denoise disabled, bitrate boosted)")
            }

            // 6. Text / UI sharp chroma-edge protection (caps denoise <= 0.05, boosts bitrate +15%..+25%)
            if needsTextProtection {
                denoiseStrength = min(denoiseStrength, 0.05)
                let edgeSeverity = min(1.0, max(shot.textMaskRatio * 2.0, shot.chromaEdgeComplexity))
                let textBoost = 0.15 + 0.10 * edgeSeverity
                bitrateMult *= (1.0 + textBoost)
                cqf += 0.07
                reasons.append("Protected sharp text/UI chroma edges")
            }

            // 7. Face protection (prevents waxy skin smoothing)
            if protectFaces && shot.faceMaskRatio > 0.02 {
                if denoiseStrength > 0.12 {
                    denoiseStrength = 0.12
                }
                bitrateMult *= 1.08
                cqf += 0.04
                reasons.append("Protected facial texture detail from over-smoothing")
            }

            // 8. Dark-gradient banding protection
            if bandingSensitive && shot.bandingRisk > 0.35 {
                bitrateMult *= 1.08
                cqf += 0.05
                reasons.append("Boosted dark-gradient precision to prevent banding")
            }

            // 9. Latency / mode-specific notes
            if useTwoPass || latencyMode == .twoPass {
                reasons.append("Disabled LookAhead for VTMultiPassStorage 2-pass compatibility")
            } else if latencyMode == .liveUltraLowLatency {
                reasons.append("Zero-frame LookAhead enforced for ultra-low-latency live delivery")
            }

            if reasons.isEmpty {
                reasons.append("Balanced perceptual rate control")
            }

            let clampedBitrateMult = min(2.25, max(0.45, bitrateMult))
            let clampedCQF = min(0.95, max(0.20, cqf))

            policies.append(ShotControlPolicy(
                shotIndex: shot.shotIndex,
                denoiseStrength: denoiseStrength,
                preserveGrain: effectivePreserveGrain,
                lookAheadFrames: resolvedLookAhead,
                forceIDRAtStart: forceIDR,
                recommendedBitrateMultiplier: clampedBitrateMult,
                recommendedCQF: clampedCQF,
                reasons: reasons
            ))
        }

        return policies
    }
}
