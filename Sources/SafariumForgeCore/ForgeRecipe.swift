import Foundation
import SafariumCore

// MARK: - Declarative Graph Schema (safarium-forge/graph-v1)

public struct ForgeStagePolicy: Codable, Sendable, Equatable {
    public var apfsAutoStage: Bool
    public var cacheDir: String?
    public var allowClonefileCoW: Bool

    public init(
        apfsAutoStage: Bool = true,
        cacheDir: String? = nil,
        allowClonefileCoW: Bool = true
    ) {
        self.apfsAutoStage = apfsAutoStage
        self.cacheDir = cacheDir
        self.allowClonefileCoW = allowClonefileCoW
    }

    private enum CodingKeys: String, CodingKey {
        case apfsAutoStage, cacheDir, allowClonefileCoW
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.apfsAutoStage = try c.decodeIfPresent(Bool.self, forKey: .apfsAutoStage) ?? true
        self.cacheDir = try c.decodeIfPresent(String.self, forKey: .cacheDir)
        self.allowClonefileCoW = try c.decodeIfPresent(Bool.self, forKey: .allowClonefileCoW) ?? true
    }
}

public struct ForgeGovernorConfig: Codable, Sendable, Equatable {
    public var targetPeakRAMMiB: Double
    public var ringSlots: Int
    public var wkRecycleEveryFrames: Int
    public var thermalThrottlePolicy: String

    public init(
        targetPeakRAMMiB: Double = 220.0,
        ringSlots: Int = 4,
        wkRecycleEveryFrames: Int = 200,
        thermalThrottlePolicy: String = "paceWithoutQualityLoss"
    ) {
        self.targetPeakRAMMiB = targetPeakRAMMiB
        self.ringSlots = ringSlots
        self.wkRecycleEveryFrames = wkRecycleEveryFrames
        self.thermalThrottlePolicy = thermalThrottlePolicy
    }

    private enum CodingKeys: String, CodingKey {
        case targetPeakRAMMiB, ringSlots, wkRecycleEveryFrames, thermalThrottlePolicy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.targetPeakRAMMiB = try c.decodeIfPresent(Double.self, forKey: .targetPeakRAMMiB) ?? 220.0
        self.ringSlots = try c.decodeIfPresent(Int.self, forKey: .ringSlots) ?? 4
        self.wkRecycleEveryFrames = try c.decodeIfPresent(Int.self, forKey: .wkRecycleEveryFrames) ?? 200
        self.thermalThrottlePolicy = try c.decodeIfPresent(String.self, forKey: .thermalThrottlePolicy) ?? "paceWithoutQualityLoss"
    }
}

public struct ForgeJobConfig: Codable, Sendable, Equatable {
    public var stagePolicy: ForgeStagePolicy?
    public var governor: ForgeGovernorConfig?

    public init(stagePolicy: ForgeStagePolicy? = nil, governor: ForgeGovernorConfig? = nil) {
        self.stagePolicy = stagePolicy
        self.governor = governor
    }
}

public enum ForgeInputKind: String, Codable, Sendable {
    case video
    case audio
    case image
    case imageSequence
    case htmlOverlay
    case lut3d
    case subtitles
    case rawPipe
    case synthAudio
}

public struct ForgeAudioSynthSpec: Codable, Sendable, Equatable {
    public var waveform: String
    public var frequencyHz: Double?
    public var endFrequencyHz: Double?
    public var carrierFrequenciesHz: [Double]?
    public var modulationHz: Double?
    public var modulationDepth: Double?
    public var amplitude: Double?
    public var durationSeconds: Double
    public var sampleRate: Int?
    public var channels: Int?
    public var fadeInSeconds: Double?
    public var fadeOutSeconds: Double?

    public init(
        waveform: String,
        frequencyHz: Double? = nil,
        endFrequencyHz: Double? = nil,
        carrierFrequenciesHz: [Double]? = nil,
        modulationHz: Double? = nil,
        modulationDepth: Double? = nil,
        amplitude: Double? = 0.25,
        durationSeconds: Double,
        sampleRate: Int? = 48_000,
        channels: Int? = 2,
        fadeInSeconds: Double? = nil,
        fadeOutSeconds: Double? = nil
    ) {
        self.waveform = waveform
        self.frequencyHz = frequencyHz
        self.endFrequencyHz = endFrequencyHz
        self.carrierFrequenciesHz = carrierFrequenciesHz
        self.modulationHz = modulationHz
        self.modulationDepth = modulationDepth
        self.amplitude = amplitude
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.channels = channels
        self.fadeInSeconds = fadeInSeconds
        self.fadeOutSeconds = fadeOutSeconds
    }
}

public struct ForgeInputSpec: Codable, Sendable, Equatable {
    public var id: String
    public var kind: ForgeInputKind
    public var path: String?
    public var demux: String?
    public var trim: [Double]?
    public var loop: Bool?
    public var width: Int?
    public var height: Int?
    public var fps: Int?
    public var pixelFormat: String?
    public var modeCDirtyHold: Bool?
    public var colorSpace: String?
    public var lang: String?
    public var synth: ForgeAudioSynthSpec?
    public var sequenceDirectory: String?
    public var sequenceGlob: String?
    public var sequenceListFile: String?
    public var sequenceFps: Int?

    public init(
        id: String,
        kind: ForgeInputKind,
        path: String? = nil,
        demux: String? = nil,
        trim: [Double]? = nil,
        loop: Bool? = nil,
        width: Int? = nil,
        height: Int? = nil,
        fps: Int? = nil,
        pixelFormat: String? = nil,
        modeCDirtyHold: Bool? = nil,
        colorSpace: String? = nil,
        lang: String? = nil,
        synth: ForgeAudioSynthSpec? = nil,
        sequenceDirectory: String? = nil,
        sequenceGlob: String? = nil,
        sequenceListFile: String? = nil,
        sequenceFps: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.path = path
        self.demux = demux
        self.trim = trim
        self.loop = loop
        self.width = width
        self.height = height
        self.fps = fps
        self.pixelFormat = pixelFormat
        self.modeCDirtyHold = modeCDirtyHold
        self.colorSpace = colorSpace
        self.lang = lang
        self.synth = synth
        self.sequenceDirectory = sequenceDirectory
        self.sequenceGlob = sequenceGlob
        self.sequenceListFile = sequenceListFile
        self.sequenceFps = sequenceFps
    }
}

public struct ForgeTimelineSpec: Codable, Sendable, Equatable {
    public var fps: Int
    public var width: Int
    public var height: Int
    public var durationSeconds: Double?
    public var frameCount: Int?
    public var cutPolicy: String?
    public var closedGOPSceneCache: Bool?

    public init(
        fps: Int = 30,
        width: Int,
        height: Int,
        durationSeconds: Double? = nil,
        frameCount: Int? = nil,
        cutPolicy: String? = nil,
        closedGOPSceneCache: Bool? = nil
    ) {
        self.fps = fps
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
        self.frameCount = frameCount
        self.cutPolicy = cutPolicy
        self.closedGOPSceneCache = closedGOPSceneCache
    }
}

public enum ForgeVideoOpKind: String, Codable, Sendable {
    case geom
    case deinterlace
    case kenBurns
    case chromaKey
    case gblur
    case colorGrade
    case lut3d
    case vignette
    case grain
    case overlay
    case blend
    case xfade
    case hstack
    case vstack
    case paperCutout
    case markerTexture
    case splitMetalFX
    case autoReframe
    case personMatte
    case htmlOverlay
    case tmix
    case kGrief
    case setpts
    case tpad
    case llsr
}

public struct ForgeVideoOp: Codable, Sendable, Equatable {
    public var id: String
    public var op: ForgeVideoOpKind
    public var input: String?
    public var base: String?
    public var over: String?
    public var from: String?
    public var to: String?
    public var inputs: [String]?
    public var lowResIn: String?
    public var overlay1xIn: String?
    public var lut: String?
    public var mask: String?

    // Geometry
    public var width: Int?
    public var height: Int?
    public var scaleX: Double?
    public var scaleY: Double?
    public var scale: String?
    public var cropRect: [Double]?
    public var padWidth: Int?
    public var padHeight: Int?
    public var padColorHex: String?
    public var rotateDegrees: Double?
    public var hflip: Bool?
    public var vflip: Bool?

    // Deinterlace
    public var fieldOrder: String?
    public var motionThreshold: Double?

    // Ken Burns
    public var zoomStart: Double?
    public var zoomEnd: Double?
    public var panXStart: Double?
    public var panYStart: Double?
    public var panXEnd: Double?
    public var panYEnd: Double?
    public var zoomExpr: String?
    public var centerXExpr: String?
    public var centerYExpr: String?

    // ChromaKey
    public var keyColorHex: String?
    public var similarity: Double?
    public var smoothness: Double?
    public var despillStrength: Double?
    public var erodeRadius: Int?

    // GBlur
    public var sigma: Double?

    // ColorGrade
    public var brightness: Double?
    public var contrast: Double?
    public var saturation: Double?
    public var gamma: Double?
    public var grayscale: Double?

    // LUT3D & Vignette & Grain
    public var intensity: Double?
    public var radius: Double?
    public var softness: Double?
    public var amount: Double?
    public var grainSize: Double?
    public var seed: UInt32?

    // Overlay / Blend / Xfade / Stack
    public var x: String?
    public var y: String?
    public var opacity: String?
    public var enable: String?
    public var blendMode: String?
    public var transition: String?
    public var offsetSeconds: Double?
    public var durationSeconds: Double?
    public var padding: Int?
    public var bgColorHex: String?
    public var bypassScalers: Bool?

    // AutoReframe
    public var aspect: String?
    public var detector: String?
    public var emaAlpha: Double?
    public var hysteresis: Double?
    public var resetOnSceneCut: Bool?
    public var sceneCutThreshold: Double?

    // PersonMatte
    public var mode: String?
    public var temporalEMA: Double?
    public var replaceBgHex: String?
    public var replaceBgInput: String?
    public var outputMaskOnly: Bool?

    // Wave 6 Additions (aspectFill, setpts/tpad, tmix, K.grief, LLSR opt-in)
    public var aspectFill: Bool?
    public var ptsFactor: Double?
    public var holdTailSeconds: Double?
    public var tmixWeights: [Double]?
    public var kGriefTemporalWeight: Double?
    public var kGriefExposure: Double?
    public var kGriefContrast: Double?
    public var kGriefSaturation: Double?
    public var kGriefHudShield: Bool?
    public var llsrScaleFactor: Double?

    public init(
        id: String,
        op: ForgeVideoOpKind,
        input: String? = nil,
        base: String? = nil,
        over: String? = nil,
        from: String? = nil,
        to: String? = nil,
        inputs: [String]? = nil,
        lowResIn: String? = nil,
        overlay1xIn: String? = nil,
        lut: String? = nil,
        mask: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        scaleX: Double? = nil,
        scaleY: Double? = nil,
        scale: String? = nil,
        cropRect: [Double]? = nil,
        padWidth: Int? = nil,
        padHeight: Int? = nil,
        padColorHex: String? = nil,
        rotateDegrees: Double? = nil,
        hflip: Bool? = nil,
        vflip: Bool? = nil,
        fieldOrder: String? = nil,
        motionThreshold: Double? = nil,
        zoomStart: Double? = nil,
        zoomEnd: Double? = nil,
        panXStart: Double? = nil,
        panYStart: Double? = nil,
        panXEnd: Double? = nil,
        panYEnd: Double? = nil,
        zoomExpr: String? = nil,
        centerXExpr: String? = nil,
        centerYExpr: String? = nil,
        keyColorHex: String? = nil,
        similarity: Double? = nil,
        smoothness: Double? = nil,
        despillStrength: Double? = nil,
        erodeRadius: Int? = nil,
        sigma: Double? = nil,
        brightness: Double? = nil,
        contrast: Double? = nil,
        saturation: Double? = nil,
        gamma: Double? = nil,
        grayscale: Double? = nil,
        intensity: Double? = nil,
        radius: Double? = nil,
        softness: Double? = nil,
        amount: Double? = nil,
        grainSize: Double? = nil,
        seed: UInt32? = nil,
        x: String? = nil,
        y: String? = nil,
        opacity: String? = nil,
        enable: String? = nil,
        blendMode: String? = nil,
        transition: String? = nil,
        offsetSeconds: Double? = nil,
        durationSeconds: Double? = nil,
        padding: Int? = nil,
        bgColorHex: String? = nil,
        bypassScalers: Bool? = nil,
        aspect: String? = nil,
        detector: String? = nil,
        emaAlpha: Double? = nil,
        hysteresis: Double? = nil,
        resetOnSceneCut: Bool? = nil,
        sceneCutThreshold: Double? = nil,
        mode: String? = nil,
        temporalEMA: Double? = nil,
        replaceBgHex: String? = nil,
        replaceBgInput: String? = nil,
        outputMaskOnly: Bool? = nil,
        aspectFill: Bool? = nil,
        ptsFactor: Double? = nil,
        holdTailSeconds: Double? = nil,
        tmixWeights: [Double]? = nil,
        kGriefTemporalWeight: Double? = nil,
        kGriefExposure: Double? = nil,
        kGriefContrast: Double? = nil,
        kGriefSaturation: Double? = nil,
        kGriefHudShield: Bool? = nil,
        llsrScaleFactor: Double? = nil
    ) {
        self.id = id
        self.op = op
        self.input = input
        self.base = base
        self.over = over
        self.from = from
        self.to = to
        self.inputs = inputs
        self.lowResIn = lowResIn
        self.overlay1xIn = overlay1xIn
        self.lut = lut
        self.mask = mask
        self.width = width
        self.height = height
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.scale = scale
        self.cropRect = cropRect
        self.padWidth = padWidth
        self.padHeight = padHeight
        self.padColorHex = padColorHex
        self.rotateDegrees = rotateDegrees
        self.hflip = hflip
        self.vflip = vflip
        self.fieldOrder = fieldOrder
        self.motionThreshold = motionThreshold
        self.zoomStart = zoomStart
        self.zoomEnd = zoomEnd
        self.panXStart = panXStart
        self.panYStart = panYStart
        self.panXEnd = panXEnd
        self.panYEnd = panYEnd
        self.zoomExpr = zoomExpr
        self.centerXExpr = centerXExpr
        self.centerYExpr = centerYExpr
        self.keyColorHex = keyColorHex
        self.similarity = similarity
        self.smoothness = smoothness
        self.despillStrength = despillStrength
        self.erodeRadius = erodeRadius
        self.sigma = sigma
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.gamma = gamma
        self.grayscale = grayscale
        self.intensity = intensity
        self.radius = radius
        self.softness = softness
        self.amount = amount
        self.grainSize = grainSize
        self.seed = seed
        self.x = x
        self.y = y
        self.opacity = opacity
        self.enable = enable
        self.blendMode = blendMode
        self.transition = transition
        self.offsetSeconds = offsetSeconds
        self.durationSeconds = durationSeconds
        self.padding = padding
        self.bgColorHex = bgColorHex
        self.bypassScalers = bypassScalers
        self.aspect = aspect
        self.detector = detector
        self.emaAlpha = emaAlpha
        self.hysteresis = hysteresis
        self.resetOnSceneCut = resetOnSceneCut
        self.sceneCutThreshold = sceneCutThreshold
        self.mode = mode
        self.temporalEMA = temporalEMA
        self.replaceBgHex = replaceBgHex
        self.replaceBgInput = replaceBgInput
        self.outputMaskOnly = outputMaskOnly
        self.aspectFill = aspectFill
        self.ptsFactor = ptsFactor
        self.holdTailSeconds = holdTailSeconds
        self.tmixWeights = tmixWeights
        self.kGriefTemporalWeight = kGriefTemporalWeight
        self.kGriefExposure = kGriefExposure
        self.kGriefContrast = kGriefContrast
        self.kGriefSaturation = kGriefSaturation
        self.kGriefHudShield = kGriefHudShield
        self.llsrScaleFactor = llsrScaleFactor
    }

    private enum CodingKeys: String, CodingKey {
        case id, op
        case inKey = "in"
        case input
        case base, over, from, to, inputs, lowResIn, overlay1xIn, lut, mask
        case width, height, scaleX, scaleY, scale, cropRect, padWidth, padHeight, padColorHex, rotateDegrees, hflip, vflip
        case fieldOrder, motionThreshold
        case zoomStart, zoomEnd, panXStart, panYStart, panXEnd, panYEnd, zoomExpr, centerXExpr, centerYExpr
        case keyColorHex, similarity, smoothness, despillStrength, erodeRadius
        case sigma
        case brightness, contrast, saturation, gamma, grayscale
        case intensity, radius, softness, amount, grainSize, seed
        case x, y, opacity, enable, blendMode, transition, offsetSeconds, durationSeconds, padding, bgColorHex, bypassScalers
        case aspect, detector, emaAlpha, hysteresis, resetOnSceneCut, sceneCutThreshold
        case mode, temporalEMA, replaceBgHex, replaceBg, replaceBgInput, outputMaskOnly
        case aspectFill, ptsFactor, holdTailSeconds, tmixWeights
        case kGriefTemporalWeight, kGriefExposure, kGriefContrast, kGriefSaturation, kGriefHudShield, llsrScaleFactor
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        op = try c.decode(ForgeVideoOpKind.self, forKey: .op)
        input = try c.decodeIfPresent(String.self, forKey: .inKey) ?? c.decodeIfPresent(String.self, forKey: .input)
        base = try c.decodeIfPresent(String.self, forKey: .base)
        over = try c.decodeIfPresent(String.self, forKey: .over)
        from = try c.decodeIfPresent(String.self, forKey: .from)
        to = try c.decodeIfPresent(String.self, forKey: .to)
        inputs = try c.decodeIfPresent([String].self, forKey: .inputs)
        lowResIn = try c.decodeIfPresent(String.self, forKey: .lowResIn)
        overlay1xIn = try c.decodeIfPresent(String.self, forKey: .overlay1xIn)
        lut = try c.decodeIfPresent(String.self, forKey: .lut)
        mask = try c.decodeIfPresent(String.self, forKey: .mask)
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        scaleX = try c.decodeIfPresent(Double.self, forKey: .scaleX)
        scaleY = try c.decodeIfPresent(Double.self, forKey: .scaleY)
        scale = try c.decodeIfPresent(String.self, forKey: .scale)
        cropRect = try c.decodeIfPresent([Double].self, forKey: .cropRect)
        padWidth = try c.decodeIfPresent(Int.self, forKey: .padWidth)
        padHeight = try c.decodeIfPresent(Int.self, forKey: .padHeight)
        padColorHex = try c.decodeIfPresent(String.self, forKey: .padColorHex)
        rotateDegrees = try c.decodeIfPresent(Double.self, forKey: .rotateDegrees)
        hflip = try c.decodeIfPresent(Bool.self, forKey: .hflip)
        vflip = try c.decodeIfPresent(Bool.self, forKey: .vflip)
        fieldOrder = try c.decodeIfPresent(String.self, forKey: .fieldOrder)
        motionThreshold = try c.decodeIfPresent(Double.self, forKey: .motionThreshold)
        zoomStart = try c.decodeIfPresent(Double.self, forKey: .zoomStart)
        zoomEnd = try c.decodeIfPresent(Double.self, forKey: .zoomEnd)
        panXStart = try c.decodeIfPresent(Double.self, forKey: .panXStart)
        panYStart = try c.decodeIfPresent(Double.self, forKey: .panYStart)
        panXEnd = try c.decodeIfPresent(Double.self, forKey: .panXEnd)
        panYEnd = try c.decodeIfPresent(Double.self, forKey: .panYEnd)
        zoomExpr = try c.decodeIfPresent(String.self, forKey: .zoomExpr)
        centerXExpr = try c.decodeIfPresent(String.self, forKey: .centerXExpr)
        centerYExpr = try c.decodeIfPresent(String.self, forKey: .centerYExpr)
        keyColorHex = try c.decodeIfPresent(String.self, forKey: .keyColorHex)
        similarity = try c.decodeIfPresent(Double.self, forKey: .similarity)
        smoothness = try c.decodeIfPresent(Double.self, forKey: .smoothness)
        despillStrength = try c.decodeIfPresent(Double.self, forKey: .despillStrength)
        erodeRadius = try c.decodeIfPresent(Int.self, forKey: .erodeRadius)
        sigma = try c.decodeIfPresent(Double.self, forKey: .sigma)
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness)
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast)
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation)
        gamma = try c.decodeIfPresent(Double.self, forKey: .gamma)
        grayscale = try c.decodeIfPresent(Double.self, forKey: .grayscale)
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius)
        softness = try c.decodeIfPresent(Double.self, forKey: .softness)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount)
        grainSize = try c.decodeIfPresent(Double.self, forKey: .grainSize)
        seed = try c.decodeIfPresent(UInt32.self, forKey: .seed)
        x = try c.decodeIfPresent(String.self, forKey: .x)
        y = try c.decodeIfPresent(String.self, forKey: .y)
        opacity = try c.decodeIfPresent(String.self, forKey: .opacity)
        enable = try c.decodeIfPresent(String.self, forKey: .enable)
        blendMode = try c.decodeIfPresent(String.self, forKey: .blendMode)
        transition = try c.decodeIfPresent(String.self, forKey: .transition)
        offsetSeconds = try c.decodeIfPresent(Double.self, forKey: .offsetSeconds)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        padding = try c.decodeIfPresent(Int.self, forKey: .padding)
        bgColorHex = try c.decodeIfPresent(String.self, forKey: .bgColorHex)
        bypassScalers = try c.decodeIfPresent(Bool.self, forKey: .bypassScalers)
        aspect = try c.decodeIfPresent(String.self, forKey: .aspect)
        detector = try c.decodeIfPresent(String.self, forKey: .detector)
        emaAlpha = try c.decodeIfPresent(Double.self, forKey: .emaAlpha)
        hysteresis = try c.decodeIfPresent(Double.self, forKey: .hysteresis)
        resetOnSceneCut = try c.decodeIfPresent(Bool.self, forKey: .resetOnSceneCut)
        sceneCutThreshold = try c.decodeIfPresent(Double.self, forKey: .sceneCutThreshold)
        mode = try c.decodeIfPresent(String.self, forKey: .mode)
        temporalEMA = try c.decodeIfPresent(Double.self, forKey: .temporalEMA)
        replaceBgHex = try c.decodeIfPresent(String.self, forKey: .replaceBgHex) ?? c.decodeIfPresent(String.self, forKey: .replaceBg)
        replaceBgInput = try c.decodeIfPresent(String.self, forKey: .replaceBgInput)
        outputMaskOnly = try c.decodeIfPresent(Bool.self, forKey: .outputMaskOnly)
        aspectFill = try c.decodeIfPresent(Bool.self, forKey: .aspectFill)
        ptsFactor = try c.decodeIfPresent(Double.self, forKey: .ptsFactor)
        holdTailSeconds = try c.decodeIfPresent(Double.self, forKey: .holdTailSeconds)
        tmixWeights = try c.decodeIfPresent([Double].self, forKey: .tmixWeights)
        kGriefTemporalWeight = try c.decodeIfPresent(Double.self, forKey: .kGriefTemporalWeight)
        kGriefExposure = try c.decodeIfPresent(Double.self, forKey: .kGriefExposure)
        kGriefContrast = try c.decodeIfPresent(Double.self, forKey: .kGriefContrast)
        kGriefSaturation = try c.decodeIfPresent(Double.self, forKey: .kGriefSaturation)
        kGriefHudShield = try c.decodeIfPresent(Bool.self, forKey: .kGriefHudShield)
        llsrScaleFactor = try c.decodeIfPresent(Double.self, forKey: .llsrScaleFactor)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(op, forKey: .op)
        try c.encodeIfPresent(input, forKey: .inKey)
        try c.encodeIfPresent(base, forKey: .base)
        try c.encodeIfPresent(over, forKey: .over)
        try c.encodeIfPresent(from, forKey: .from)
        try c.encodeIfPresent(to, forKey: .to)
        try c.encodeIfPresent(inputs, forKey: .inputs)
        try c.encodeIfPresent(lowResIn, forKey: .lowResIn)
        try c.encodeIfPresent(overlay1xIn, forKey: .overlay1xIn)
        try c.encodeIfPresent(lut, forKey: .lut)
        try c.encodeIfPresent(mask, forKey: .mask)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(scaleX, forKey: .scaleX)
        try c.encodeIfPresent(scaleY, forKey: .scaleY)
        try c.encodeIfPresent(scale, forKey: .scale)
        try c.encodeIfPresent(cropRect, forKey: .cropRect)
        try c.encodeIfPresent(padWidth, forKey: .padWidth)
        try c.encodeIfPresent(padHeight, forKey: .padHeight)
        try c.encodeIfPresent(padColorHex, forKey: .padColorHex)
        try c.encodeIfPresent(rotateDegrees, forKey: .rotateDegrees)
        try c.encodeIfPresent(hflip, forKey: .hflip)
        try c.encodeIfPresent(vflip, forKey: .vflip)
        try c.encodeIfPresent(fieldOrder, forKey: .fieldOrder)
        try c.encodeIfPresent(motionThreshold, forKey: .motionThreshold)
        try c.encodeIfPresent(zoomStart, forKey: .zoomStart)
        try c.encodeIfPresent(zoomEnd, forKey: .zoomEnd)
        try c.encodeIfPresent(panXStart, forKey: .panXStart)
        try c.encodeIfPresent(panYStart, forKey: .panYStart)
        try c.encodeIfPresent(panXEnd, forKey: .panXEnd)
        try c.encodeIfPresent(panYEnd, forKey: .panYEnd)
        try c.encodeIfPresent(zoomExpr, forKey: .zoomExpr)
        try c.encodeIfPresent(centerXExpr, forKey: .centerXExpr)
        try c.encodeIfPresent(centerYExpr, forKey: .centerYExpr)
        try c.encodeIfPresent(keyColorHex, forKey: .keyColorHex)
        try c.encodeIfPresent(similarity, forKey: .similarity)
        try c.encodeIfPresent(smoothness, forKey: .smoothness)
        try c.encodeIfPresent(despillStrength, forKey: .despillStrength)
        try c.encodeIfPresent(erodeRadius, forKey: .erodeRadius)
        try c.encodeIfPresent(sigma, forKey: .sigma)
        try c.encodeIfPresent(brightness, forKey: .brightness)
        try c.encodeIfPresent(contrast, forKey: .contrast)
        try c.encodeIfPresent(saturation, forKey: .saturation)
        try c.encodeIfPresent(gamma, forKey: .gamma)
        try c.encodeIfPresent(grayscale, forKey: .grayscale)
        try c.encodeIfPresent(intensity, forKey: .intensity)
        try c.encodeIfPresent(radius, forKey: .radius)
        try c.encodeIfPresent(softness, forKey: .softness)
        try c.encodeIfPresent(amount, forKey: .amount)
        try c.encodeIfPresent(grainSize, forKey: .grainSize)
        try c.encodeIfPresent(seed, forKey: .seed)
        try c.encodeIfPresent(x, forKey: .x)
        try c.encodeIfPresent(y, forKey: .y)
        try c.encodeIfPresent(opacity, forKey: .opacity)
        try c.encodeIfPresent(enable, forKey: .enable)
        try c.encodeIfPresent(blendMode, forKey: .blendMode)
        try c.encodeIfPresent(transition, forKey: .transition)
        try c.encodeIfPresent(offsetSeconds, forKey: .offsetSeconds)
        try c.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try c.encodeIfPresent(padding, forKey: .padding)
        try c.encodeIfPresent(bgColorHex, forKey: .bgColorHex)
        try c.encodeIfPresent(bypassScalers, forKey: .bypassScalers)
        try c.encodeIfPresent(aspect, forKey: .aspect)
        try c.encodeIfPresent(detector, forKey: .detector)
        try c.encodeIfPresent(emaAlpha, forKey: .emaAlpha)
        try c.encodeIfPresent(hysteresis, forKey: .hysteresis)
        try c.encodeIfPresent(resetOnSceneCut, forKey: .resetOnSceneCut)
        try c.encodeIfPresent(sceneCutThreshold, forKey: .sceneCutThreshold)
        try c.encodeIfPresent(mode, forKey: .mode)
        try c.encodeIfPresent(temporalEMA, forKey: .temporalEMA)
        try c.encodeIfPresent(replaceBgHex, forKey: .replaceBgHex)
        try c.encodeIfPresent(replaceBgInput, forKey: .replaceBgInput)
        try c.encodeIfPresent(outputMaskOnly, forKey: .outputMaskOnly)
        try c.encodeIfPresent(aspectFill, forKey: .aspectFill)
        try c.encodeIfPresent(ptsFactor, forKey: .ptsFactor)
        try c.encodeIfPresent(holdTailSeconds, forKey: .holdTailSeconds)
        try c.encodeIfPresent(tmixWeights, forKey: .tmixWeights)
        try c.encodeIfPresent(kGriefTemporalWeight, forKey: .kGriefTemporalWeight)
        try c.encodeIfPresent(kGriefExposure, forKey: .kGriefExposure)
        try c.encodeIfPresent(kGriefContrast, forKey: .kGriefContrast)
        try c.encodeIfPresent(kGriefSaturation, forKey: .kGriefSaturation)
        try c.encodeIfPresent(kGriefHudShield, forKey: .kGriefHudShield)
        try c.encodeIfPresent(llsrScaleFactor, forKey: .llsrScaleFactor)
    }

    public func referencedNodeIDs() -> [String] {
        var refs: [String] = []
        for s in [input, base, over, from, to, lowResIn, overlay1xIn, lut, mask, replaceBgInput] {
            if let s, !s.isEmpty { refs.append(s) }
        }
        if let inputs {
            refs.append(contentsOf: inputs.filter { !$0.isEmpty })
        }
        return refs
    }
}

public enum ForgeAudioOpKind: String, Codable, Sendable {
    case biquadEQ
    case compressor
    case gain
    case acrossfade
    case silenceTrim
    case sidechainDuck
    case mix
    case loudnorm
    case peakLimit
    case synth
    case waveform
    case voiceIsolate
    case fade
    case trim
    case pad
    case afade
    case atrim
    case apad
}

public struct ForgeAudioOp: Codable, Sendable, Equatable {
    public var id: String
    public var op: ForgeAudioOpKind
    public var input: String?
    public var inA: String?
    public var inB: String?
    public var carrier: String?
    public var sidechain: String?
    public var tracks: [String]?
    public var gainsDB: [Double]?
    public var startSeconds: [Double]?

    public var eqMode: String?
    public var freqHz: Double?
    public var q: Double?
    public var gainDB: Double?

    public var thresholdDB: Double?
    public var ratio: Double?
    public var duckDB: Double?
    public var attackMs: Double?
    public var releaseMs: Double?
    public var makeupDB: Double?

    public var durationSeconds: Double?
    public var curve: String?
    public var minSilenceSeconds: Double?
    public var paddingSeconds: Double?
    public var fadeInSeconds: Double?
    public var fadeOutSeconds: Double?
    public var trimStartSeconds: Double?
    public var trimEndSeconds: Double?
    public var padToDurationSeconds: Double?

    public var normalizeLUFS: Double?
    public var targetLUFS: Double?
    public var peakCeilingDBTP: Double?

    public var synth: ForgeAudioSynthSpec?
    public var bins: Int?
    public var outputJSONPath: String?

    public init(
        id: String,
        op: ForgeAudioOpKind,
        input: String? = nil,
        inA: String? = nil,
        inB: String? = nil,
        carrier: String? = nil,
        sidechain: String? = nil,
        tracks: [String]? = nil,
        gainsDB: [Double]? = nil,
        startSeconds: [Double]? = nil,
        eqMode: String? = nil,
        freqHz: Double? = nil,
        q: Double? = nil,
        gainDB: Double? = nil,
        thresholdDB: Double? = nil,
        ratio: Double? = nil,
        duckDB: Double? = nil,
        attackMs: Double? = nil,
        releaseMs: Double? = nil,
        makeupDB: Double? = nil,
        durationSeconds: Double? = nil,
        curve: String? = nil,
        minSilenceSeconds: Double? = nil,
        paddingSeconds: Double? = nil,
        fadeInSeconds: Double? = nil,
        fadeOutSeconds: Double? = nil,
        trimStartSeconds: Double? = nil,
        trimEndSeconds: Double? = nil,
        padToDurationSeconds: Double? = nil,
        normalizeLUFS: Double? = nil,
        targetLUFS: Double? = nil,
        peakCeilingDBTP: Double? = nil,
        synth: ForgeAudioSynthSpec? = nil,
        bins: Int? = nil,
        outputJSONPath: String? = nil
    ) {
        self.id = id
        self.op = op
        self.input = input
        self.inA = inA
        self.inB = inB
        self.carrier = carrier
        self.sidechain = sidechain
        self.tracks = tracks
        self.gainsDB = gainsDB
        self.startSeconds = startSeconds
        self.eqMode = eqMode
        self.freqHz = freqHz
        self.q = q
        self.gainDB = gainDB
        self.thresholdDB = thresholdDB
        self.ratio = ratio
        self.duckDB = duckDB
        self.attackMs = attackMs
        self.releaseMs = releaseMs
        self.makeupDB = makeupDB
        self.durationSeconds = durationSeconds
        self.curve = curve
        self.minSilenceSeconds = minSilenceSeconds
        self.paddingSeconds = paddingSeconds
        self.fadeInSeconds = fadeInSeconds
        self.fadeOutSeconds = fadeOutSeconds
        self.trimStartSeconds = trimStartSeconds
        self.trimEndSeconds = trimEndSeconds
        self.padToDurationSeconds = padToDurationSeconds
        self.normalizeLUFS = normalizeLUFS
        self.targetLUFS = targetLUFS
        self.peakCeilingDBTP = peakCeilingDBTP
        self.synth = synth
        self.bins = bins
        self.outputJSONPath = outputJSONPath
    }

    private enum CodingKeys: String, CodingKey {
        case id, op
        case inKey = "in"
        case input
        case inA, inB, carrier, sidechain, tracks, gainsDB, startSeconds
        case eqMode, freqHz, q, gainDB
        case thresholdDB, ratio, duckDB, attackMs, releaseMs, makeupDB
        case durationSeconds, curve, minSilenceSeconds, paddingSeconds
        case fadeInSeconds, fadeOutSeconds, trimStartSeconds, trimEndSeconds, padToDurationSeconds
        case normalizeLUFS, targetLUFS, peakCeilingDBTP
        case synth, bins, outputJSONPath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        op = try c.decode(ForgeAudioOpKind.self, forKey: .op)
        input = try c.decodeIfPresent(String.self, forKey: .inKey) ?? c.decodeIfPresent(String.self, forKey: .input)
        inA = try c.decodeIfPresent(String.self, forKey: .inA)
        inB = try c.decodeIfPresent(String.self, forKey: .inB)
        carrier = try c.decodeIfPresent(String.self, forKey: .carrier)
        sidechain = try c.decodeIfPresent(String.self, forKey: .sidechain)
        tracks = try c.decodeIfPresent([String].self, forKey: .tracks)
        gainsDB = try c.decodeIfPresent([Double].self, forKey: .gainsDB)
        startSeconds = try c.decodeIfPresent([Double].self, forKey: .startSeconds)
        eqMode = try c.decodeIfPresent(String.self, forKey: .eqMode)
        freqHz = try c.decodeIfPresent(Double.self, forKey: .freqHz)
        q = try c.decodeIfPresent(Double.self, forKey: .q)
        gainDB = try c.decodeIfPresent(Double.self, forKey: .gainDB)
        thresholdDB = try c.decodeIfPresent(Double.self, forKey: .thresholdDB)
        ratio = try c.decodeIfPresent(Double.self, forKey: .ratio)
        duckDB = try c.decodeIfPresent(Double.self, forKey: .duckDB)
        attackMs = try c.decodeIfPresent(Double.self, forKey: .attackMs)
        releaseMs = try c.decodeIfPresent(Double.self, forKey: .releaseMs)
        makeupDB = try c.decodeIfPresent(Double.self, forKey: .makeupDB)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        curve = try c.decodeIfPresent(String.self, forKey: .curve)
        minSilenceSeconds = try c.decodeIfPresent(Double.self, forKey: .minSilenceSeconds)
        paddingSeconds = try c.decodeIfPresent(Double.self, forKey: .paddingSeconds)
        fadeInSeconds = try c.decodeIfPresent(Double.self, forKey: .fadeInSeconds)
        fadeOutSeconds = try c.decodeIfPresent(Double.self, forKey: .fadeOutSeconds)
        trimStartSeconds = try c.decodeIfPresent(Double.self, forKey: .trimStartSeconds)
        trimEndSeconds = try c.decodeIfPresent(Double.self, forKey: .trimEndSeconds)
        padToDurationSeconds = try c.decodeIfPresent(Double.self, forKey: .padToDurationSeconds)
        normalizeLUFS = try c.decodeIfPresent(Double.self, forKey: .normalizeLUFS)
        targetLUFS = try c.decodeIfPresent(Double.self, forKey: .targetLUFS)
        peakCeilingDBTP = try c.decodeIfPresent(Double.self, forKey: .peakCeilingDBTP)
        synth = try c.decodeIfPresent(ForgeAudioSynthSpec.self, forKey: .synth)
        bins = try c.decodeIfPresent(Int.self, forKey: .bins)
        outputJSONPath = try c.decodeIfPresent(String.self, forKey: .outputJSONPath)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(op, forKey: .op)
        try c.encodeIfPresent(input, forKey: .inKey)
        try c.encodeIfPresent(inA, forKey: .inA)
        try c.encodeIfPresent(inB, forKey: .inB)
        try c.encodeIfPresent(carrier, forKey: .carrier)
        try c.encodeIfPresent(sidechain, forKey: .sidechain)
        try c.encodeIfPresent(tracks, forKey: .tracks)
        try c.encodeIfPresent(gainsDB, forKey: .gainsDB)
        try c.encodeIfPresent(startSeconds, forKey: .startSeconds)
        try c.encodeIfPresent(eqMode, forKey: .eqMode)
        try c.encodeIfPresent(freqHz, forKey: .freqHz)
        try c.encodeIfPresent(q, forKey: .q)
        try c.encodeIfPresent(gainDB, forKey: .gainDB)
        try c.encodeIfPresent(thresholdDB, forKey: .thresholdDB)
        try c.encodeIfPresent(ratio, forKey: .ratio)
        try c.encodeIfPresent(duckDB, forKey: .duckDB)
        try c.encodeIfPresent(attackMs, forKey: .attackMs)
        try c.encodeIfPresent(releaseMs, forKey: .releaseMs)
        try c.encodeIfPresent(makeupDB, forKey: .makeupDB)
        try c.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try c.encodeIfPresent(curve, forKey: .curve)
        try c.encodeIfPresent(minSilenceSeconds, forKey: .minSilenceSeconds)
        try c.encodeIfPresent(paddingSeconds, forKey: .paddingSeconds)
        try c.encodeIfPresent(fadeInSeconds, forKey: .fadeInSeconds)
        try c.encodeIfPresent(fadeOutSeconds, forKey: .fadeOutSeconds)
        try c.encodeIfPresent(trimStartSeconds, forKey: .trimStartSeconds)
        try c.encodeIfPresent(trimEndSeconds, forKey: .trimEndSeconds)
        try c.encodeIfPresent(padToDurationSeconds, forKey: .padToDurationSeconds)
        try c.encodeIfPresent(normalizeLUFS, forKey: .normalizeLUFS)
        try c.encodeIfPresent(targetLUFS, forKey: .targetLUFS)
        try c.encodeIfPresent(peakCeilingDBTP, forKey: .peakCeilingDBTP)
        try c.encodeIfPresent(synth, forKey: .synth)
        try c.encodeIfPresent(bins, forKey: .bins)
        try c.encodeIfPresent(outputJSONPath, forKey: .outputJSONPath)
    }

    public func referencedNodeIDs() -> [String] {
        var refs: [String] = []
        for s in [input, inA, inB, carrier, sidechain] {
            if let s, !s.isEmpty { refs.append(s) }
        }
        if let tracks {
            refs.append(contentsOf: tracks.filter { !$0.isEmpty })
        }
        return refs
    }
}

public struct ForgeQASpec: Codable, Sendable, Equatable {
    public var safariumPQMin: Double?
    public var maxDeltaE00P95: Double?
    public var minMSSSIM: Double?
    public var referenceVideoPath: String?
    public var pqMaxSamples: Int?
    public var thaiOCRLangs: [String]?
    public var expectedThaiText: String?
    public var faultChecks: [String]?
    public var contactSheetPath: String?
    public var contactSheetCols: Int?
    public var contactSheetRows: Int?
    public var monochromeCheck: Bool?
    public var maxChromaDelta: Double?
    public var failOnQA: Bool?

    public init(
        safariumPQMin: Double? = nil,
        maxDeltaE00P95: Double? = nil,
        minMSSSIM: Double? = nil,
        referenceVideoPath: String? = nil,
        pqMaxSamples: Int? = nil,
        thaiOCRLangs: [String]? = nil,
        expectedThaiText: String? = nil,
        faultChecks: [String]? = nil,
        contactSheetPath: String? = nil,
        contactSheetCols: Int? = nil,
        contactSheetRows: Int? = nil,
        monochromeCheck: Bool? = nil,
        maxChromaDelta: Double? = nil,
        failOnQA: Bool? = nil
    ) {
        self.safariumPQMin = safariumPQMin
        self.maxDeltaE00P95 = maxDeltaE00P95
        self.minMSSSIM = minMSSSIM
        self.referenceVideoPath = referenceVideoPath
        self.pqMaxSamples = pqMaxSamples
        self.thaiOCRLangs = thaiOCRLangs
        self.expectedThaiText = expectedThaiText
        self.faultChecks = faultChecks
        self.contactSheetPath = contactSheetPath
        self.contactSheetCols = contactSheetCols
        self.contactSheetRows = contactSheetRows
        self.monochromeCheck = monochromeCheck
        self.maxChromaDelta = maxChromaDelta
        self.failOnQA = failOnQA
    }
}

public struct ForgeSubtitleOutputSpec: Codable, Sendable, Equatable {
    public var input: String?
    public var path: String?
    public var format: String?
    public var lang: String?

    public init(input: String? = nil, path: String? = nil, format: String? = "tx3g", lang: String? = "tha") {
        self.input = input
        self.path = path
        self.format = format
        self.lang = lang
    }

    private enum CodingKeys: String, CodingKey {
        case inKey = "in"
        case input
        case path, format, lang
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(String.self, forKey: .inKey) ?? c.decodeIfPresent(String.self, forKey: .input)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        format = try c.decodeIfPresent(String.self, forKey: .format)
        lang = try c.decodeIfPresent(String.self, forKey: .lang)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(input, forKey: .inKey)
        try c.encodeIfPresent(path, forKey: .path)
        try c.encodeIfPresent(format, forKey: .format)
        try c.encodeIfPresent(lang, forKey: .lang)
    }
}

public struct ForgeRateControlSpec: Codable, Sendable, Equatable {
    public var mode: String?
    public var cqf: Double?
    public var bitrateBps: Int?

    public init(mode: String? = nil, cqf: Double? = nil, bitrateBps: Int? = nil) {
        self.mode = mode
        self.cqf = cqf
        self.bitrateBps = bitrateBps
    }
}

public struct ForgeOutputSpec: Codable, Sendable, Equatable {
    public var path: String
    public var secondaryPath: String?
    public var secondaryCodec: String?
    public var secondaryBackgroundHex: String?
    public var videoOutNode: String?
    public var audioOutNode: String?
    public var container: String?
    public var videoCodec: String?
    public var tag: String?
    public var pixelFormat: String?
    public var colorimetry: String?
    public var rateControl: ForgeRateControlSpec?
    public var bitrate: Int?
    public var quality: Double?
    public var closedGOP: Bool?
    public var audioCodec: String?
    public var audioBitrateBps: Int?
    public var audioSampleRate: Int?
    public var audioChannels: Int?
    public var subtitles: ForgeSubtitleOutputSpec?
    public var fastStart: Bool?
    public var fragmentIntervalSeconds: Double?
    public var primaryAudioCodec: String?
    public var inlineSheetPath: String?
    public var inlineSheetCols: Int?
    public var inlineSheetRows: Int?
    public var inlineSheetTileWidth: Int?
    public var overwrite: Bool?

    public init(
        path: String,
        secondaryPath: String? = nil,
        secondaryCodec: String? = nil,
        secondaryBackgroundHex: String? = nil,
        videoOutNode: String? = nil,
        audioOutNode: String? = nil,
        container: String? = nil,
        videoCodec: String? = "h264",
        tag: String? = nil,
        pixelFormat: String? = "nv12Left",
        colorimetry: String? = "bt709_left_1_1_1",
        rateControl: ForgeRateControlSpec? = nil,
        bitrate: Int? = nil,
        quality: Double? = nil,
        closedGOP: Bool? = nil,
        audioCodec: String? = "aac",
        audioBitrateBps: Int? = 192_000,
        audioSampleRate: Int? = 48_000,
        audioChannels: Int? = 2,
        subtitles: ForgeSubtitleOutputSpec? = nil,
        fastStart: Bool? = true,
        fragmentIntervalSeconds: Double? = nil,
        primaryAudioCodec: String? = nil,
        inlineSheetPath: String? = nil,
        inlineSheetCols: Int? = nil,
        inlineSheetRows: Int? = nil,
        inlineSheetTileWidth: Int? = nil,
        overwrite: Bool? = false
    ) {
        self.path = path
        self.secondaryPath = secondaryPath
        self.secondaryCodec = secondaryCodec
        self.secondaryBackgroundHex = secondaryBackgroundHex
        self.videoOutNode = videoOutNode
        self.audioOutNode = audioOutNode
        self.container = container
        self.videoCodec = videoCodec
        self.tag = tag
        self.pixelFormat = pixelFormat
        self.colorimetry = colorimetry
        self.rateControl = rateControl
        self.bitrate = bitrate
        self.quality = quality
        self.closedGOP = closedGOP
        self.audioCodec = audioCodec
        self.audioBitrateBps = audioBitrateBps
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
        self.subtitles = subtitles
        self.fastStart = fastStart
        self.fragmentIntervalSeconds = fragmentIntervalSeconds
        self.primaryAudioCodec = primaryAudioCodec
        self.inlineSheetPath = inlineSheetPath
        self.inlineSheetCols = inlineSheetCols
        self.inlineSheetRows = inlineSheetRows
        self.inlineSheetTileWidth = inlineSheetTileWidth
        self.overwrite = overwrite
    }
}

public struct ForgeRecipe: Codable, Sendable, Equatable {
    public var schema: String?
    public var job: ForgeJobConfig?
    public var inputs: [ForgeInputSpec]
    public var timeline: ForgeTimelineSpec
    public var videoOps: [ForgeVideoOp]
    public var audioOps: [ForgeAudioOp]
    public var qaOps: ForgeQASpec?
    public var output: ForgeOutputSpec

    public init(
        schema: String? = "safarium-forge/graph-v1",
        job: ForgeJobConfig? = nil,
        inputs: [ForgeInputSpec],
        timeline: ForgeTimelineSpec,
        videoOps: [ForgeVideoOp] = [],
        audioOps: [ForgeAudioOp] = [],
        qaOps: ForgeQASpec? = nil,
        output: ForgeOutputSpec
    ) {
        self.schema = schema
        self.job = job
        self.inputs = inputs
        self.timeline = timeline
        self.videoOps = videoOps
        self.audioOps = audioOps
        self.qaOps = qaOps
        self.output = output
    }

    private enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case job
        case inputs
        case timeline
        case videoOps, videoGraph
        case audioOps, audioGraph
        case qaOps, verify
        case output
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decodeIfPresent(String.self, forKey: .schema)
        job = try c.decodeIfPresent(ForgeJobConfig.self, forKey: .job)
        inputs = try c.decodeIfPresent([ForgeInputSpec].self, forKey: .inputs) ?? []
        timeline = try c.decode(ForgeTimelineSpec.self, forKey: .timeline)
        videoOps = try c.decodeIfPresent([ForgeVideoOp].self, forKey: .videoOps)
            ?? c.decodeIfPresent([ForgeVideoOp].self, forKey: .videoGraph)
            ?? []
        audioOps = try c.decodeIfPresent([ForgeAudioOp].self, forKey: .audioOps)
            ?? c.decodeIfPresent([ForgeAudioOp].self, forKey: .audioGraph)
            ?? []
        qaOps = try c.decodeIfPresent(ForgeQASpec.self, forKey: .qaOps)
            ?? c.decodeIfPresent(ForgeQASpec.self, forKey: .verify)
        output = try c.decode(ForgeOutputSpec.self, forKey: .output)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(schema, forKey: .schema)
        try c.encodeIfPresent(job, forKey: .job)
        try c.encode(inputs, forKey: .inputs)
        try c.encode(timeline, forKey: .timeline)
        try c.encode(videoOps, forKey: .videoOps)
        try c.encode(audioOps, forKey: .audioOps)
        try c.encodeIfPresent(qaOps, forKey: .qaOps)
        try c.encode(output, forKey: .output)
    }
}

// MARK: - Compiled / Validated Plan

public struct ForgeValidatedPlan: Sendable {
    public let recipe: ForgeRecipe
    public let orderedVideoOps: [ForgeVideoOp]
    public let orderedAudioOps: [ForgeAudioOp]
    public let resolvedPrimaryCodec: VideoCodec
    public let resolvedSecondaryCodec: VideoCodec?
    public let resolvedPixelFormat: SinkPixelFormat
    public let resolvedContainer: String
    public let resolvedColorimetry: String
    public let ringSlots: Int
    public let htmlInputIDs: Set<String>
    public let finalVideoNodeID: String?
    public let finalAudioNodeID: String?
    public let warnings: [String]
}

// MARK: - Upfront Graph Compiler & Validator

public enum ForgeRecipeValidator {
    private static let allowedColorimetry: Set<String> = [
        "bt709_left_1_1_1", "1-1-1", "bt709", "itu_r_709_2", "bt709_left"
    ]

    public static func validate(_ recipe: ForgeRecipe) throws -> ForgeValidatedPlan {
        // 1. Validate governor / ring slots
        let ringSlots = recipe.job?.governor?.ringSlots ?? 4
        guard (1...4).contains(ringSlots) else {
            throw SafariumError.invalidState("governor.ringSlots must be in 1...4, got \(ringSlots)")
        }
        if let recycle = recipe.job?.governor?.wkRecycleEveryFrames, recycle < 1 {
            throw SafariumError.invalidState("governor.wkRecycleEveryFrames must be >= 1")
        }

        // 2. Validate timeline dimensions & fps
        let w = recipe.timeline.width
        let h = recipe.timeline.height
        let fps = recipe.timeline.fps
        guard fps > 0, fps <= 240 else {
            throw SafariumError.invalidState("timeline.fps must be in 1...240, got \(fps)")
        }
        guard w > 0, h > 0, w <= 8192, h <= 8192, w * h <= 33_554_432 else {
            throw SafariumError.invalidState("timeline dimensions must be in 1...8192 (<= 33554432 px), got \(w)x\(h)")
        }
        if let dur = recipe.timeline.durationSeconds, (!dur.isFinite || dur <= 0) {
            throw SafariumError.invalidState("timeline.durationSeconds must be finite and > 0")
        }
        if let fc = recipe.timeline.frameCount, fc <= 0 {
            throw SafariumError.invalidState("timeline.frameCount must be > 0")
        }

        // 3. Validate output container, codec, pixel format & colorimetry
        let container = (recipe.output.container ?? URL(fileURLWithPath: recipe.output.path).pathExtension).lowercased()
        let isAudioOnlyOutput = ["wav", "m4a", "mp3", "flac", "caf"].contains(container)
        let isStillImageOutput = ["webp", "avif", "heic", "heics", "png", "jpg", "jpeg"].contains(container)

        let codecStr = (recipe.output.videoCodec ?? "h264").lowercased()
        let resolvedCodec: VideoCodec
        if let c = VideoCodec.parseCLI(codecStr) {
            resolvedCodec = c
        } else {
            switch codecStr {
            case "av1", "av01", "vp9", "vp09":
                throw SafariumError.invalidState("unsupported video encode codec '\(codecStr)': macOS VideoToolbox provides no hardware/stream \(codecStr) encoder; use h264, hevc, hevc-alpha, or prores4444")
            default:
                throw SafariumError.invalidState("unknown videoCodec '\(codecStr)'")
            }
        }

        let secCodec: VideoCodec?
        if let secName = recipe.output.secondaryCodec {
            guard let parsed = VideoCodec.parseCLI(secName) else {
                throw SafariumError.invalidState("unsupported secondaryCodec '\(secName)'")
            }
            secCodec = parsed
        } else if let secPath = recipe.output.secondaryPath {
            let ext = URL(fileURLWithPath: secPath).pathExtension.lowercased()
            secCodec = (ext == "mov") ? .proRes4444 : .h264
        } else {
            secCodec = nil
        }

        let pfRaw = (recipe.output.pixelFormat ?? (resolvedCodec.hasAlpha ? "bgra" : "nv12Left")).lowercased()
        let resolvedPixelFormat: SinkPixelFormat
        switch pfRaw {
        case "420v", "nv12", "nv12left", "yuv420p":
            resolvedPixelFormat = .nv12Left
        case "nv12vimage":
            resolvedPixelFormat = .nv12vImage
        case "bgra", "32bgra", "rgba":
            resolvedPixelFormat = .bgra
        default:
            throw SafariumError.invalidState("unsupported output.pixelFormat '\(pfRaw)'")
        }

        if !isAudioOnlyOutput && (resolvedPixelFormat == .nv12Left || resolvedPixelFormat == .nv12vImage) {
            if resolvedCodec.hasAlpha {
                throw SafariumError.invalidState("alpha codec \(resolvedCodec) cannot use \(resolvedPixelFormat.rawValue); use bgra")
            }
            guard w % 2 == 0 && h % 2 == 0 else {
                throw SafariumError.invalidState("YUV/NV12 output requires positive even dimensions, got \(w)x\(h)")
            }
        }

        let colorRaw = (recipe.output.colorimetry ?? "bt709_left_1_1_1").lowercased()
        guard allowedColorimetry.contains(colorRaw) else {
            throw SafariumError.invalidState("output.colorimetry must be BT.709 Left (1-1-1, e.g. 'bt709_left_1_1_1'), got '\(colorRaw)'")
        }

        // Probe 7: fMP4 HLS/CMAF subtitle compatibility check
        if let sub = recipe.output.subtitles {
            let fmt = (sub.format ?? "tx3g").lowercased()
            if (container == "fmp4_hls" || container == "fmp4_cmaf" || container == "hls" || container == "cmaf") && (fmt == "tx3g" || fmt == "wvtt") {
                throw SafariumError.invalidState("segmented HLS/CMAF fMP4 rejects embedded '\(fmt)' subtitle tracks (-11875); emit sidecar .vtt or use file-based fMP4 with fragmentIntervalSeconds + tx3g")
            }
        }

        // 4. Validate unique input IDs and basic input invariants
        var inputMap: [String: ForgeInputSpec] = [:]
        var htmlInputIDs: Set<String> = []
        var audioInputIDs: Set<String> = []
        var videoCapableInputIDs: Set<String> = []
        var lutInputIDs: Set<String> = []

        for inp in recipe.inputs {
            guard !inp.id.isEmpty else {
                throw SafariumError.invalidState("input id cannot be empty")
            }
            guard inputMap[inp.id] == nil else {
                throw SafariumError.invalidState("duplicate input id '\(inp.id)'")
            }
            inputMap[inp.id] = inp
            switch inp.kind {
            case .htmlOverlay:
                htmlInputIDs.insert(inp.id)
                videoCapableInputIDs.insert(inp.id)
            case .video:
                videoCapableInputIDs.insert(inp.id)
                audioInputIDs.insert(inp.id) // video files may carry .audio
            case .image, .rawPipe:
                videoCapableInputIDs.insert(inp.id)
            case .imageSequence:
                let hasSource = [inp.sequenceDirectory, inp.sequenceGlob, inp.sequenceListFile, inp.path]
                    .contains { $0.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false }
                guard hasSource else {
                    throw SafariumError.invalidState("imageSequence input '\(inp.id)' requires sequenceDirectory, sequenceGlob, sequenceListFile, or path")
                }
                if let sfps = inp.sequenceFps, sfps <= 0 {
                    throw SafariumError.invalidState("imageSequence input '\(inp.id)' sequenceFps must be > 0, got \(sfps)")
                }
                videoCapableInputIDs.insert(inp.id)
            case .audio, .synthAudio:
                audioInputIDs.insert(inp.id)
            case .lut3d:
                lutInputIDs.insert(inp.id)
            case .subtitles:
                break
            }
            if let trim = inp.trim, trim.count == 2 {
                guard trim[0].isFinite, trim[1].isFinite, trim[0] >= 0, trim[1] > trim[0] else {
                    throw SafariumError.invalidState("invalid trim range on input '\(inp.id)'")
                }
            } else if let trim = inp.trim, !trim.isEmpty {
                throw SafariumError.invalidState("input '\(inp.id)' trim must have [startSeconds, endSeconds]")
            }
        }

        // 5. Topological sort & 1x Thai/HTML Shield verification for videoOps
        var videoOpMap: [String: ForgeVideoOp] = [:]
        for op in recipe.videoOps {
            guard !op.id.isEmpty else {
                throw SafariumError.invalidState("videoOp id cannot be empty")
            }
            guard inputMap[op.id] == nil && videoOpMap[op.id] == nil else {
                throw SafariumError.invalidState("duplicate videoOp/input id '\(op.id)'")
            }
            videoOpMap[op.id] = op
        }

        let orderedVideoOps = try topologicalSortVideoOps(recipe.videoOps, inputs: videoCapableInputIDs, lutInputs: lutInputIDs)
        var warnings: [String] = []
        try validateVideoGraphRules(
            orderedVideoOps: orderedVideoOps,
            htmlInputIDs: htmlInputIDs,
            lutInputIDs: lutInputIDs,
            requiresEvenYUV: !isAudioOnlyOutput && !isStillImageOutput && (resolvedPixelFormat == .nv12Left || resolvedPixelFormat == .nv12vImage),
            warnings: &warnings
        )

        // 6. Topological sort for audioOps
        var audioOpMap: [String: ForgeAudioOp] = [:]
        for op in recipe.audioOps {
            guard !op.id.isEmpty else {
                throw SafariumError.invalidState("audioOp id cannot be empty")
            }
            guard inputMap[op.id] == nil && audioOpMap[op.id] == nil else {
                throw SafariumError.invalidState("duplicate audioOp/input id '\(op.id)'")
            }
            audioOpMap[op.id] = op
        }
        let orderedAudioOps = try topologicalSortAudioOps(recipe.audioOps, audioInputs: audioInputIDs)

        let finalVideoNodeID = recipe.output.videoOutNode ?? orderedVideoOps.last?.id ?? recipe.inputs.first(where: { $0.kind == .video || $0.kind == .htmlOverlay || $0.kind == .image || $0.kind == .imageSequence || $0.kind == .rawPipe })?.id
        let finalAudioNodeID = recipe.output.audioOutNode ?? orderedAudioOps.last?.id

        return ForgeValidatedPlan(
            recipe: recipe,
            orderedVideoOps: orderedVideoOps,
            orderedAudioOps: orderedAudioOps,
            resolvedPrimaryCodec: resolvedCodec,
            resolvedSecondaryCodec: secCodec,
            resolvedPixelFormat: resolvedPixelFormat,
            resolvedContainer: container.isEmpty ? resolvedCodec.fileExtension : container,
            resolvedColorimetry: "bt709_left_1_1_1",
            ringSlots: ringSlots,
            htmlInputIDs: htmlInputIDs,
            finalVideoNodeID: finalVideoNodeID,
            finalAudioNodeID: finalAudioNodeID,
            warnings: warnings
        )
    }

    private static func stripAudioSuffix(_ ref: String) -> String {
        ref.hasSuffix(".audio") ? String(ref.dropLast(".audio".count)) : ref
    }

    private static func topologicalSortVideoOps(
        _ ops: [ForgeVideoOp],
        inputs: Set<String>,
        lutInputs: Set<String>
    ) throws -> [ForgeVideoOp] {
        let byID = Dictionary(uniqueKeysWithValues: ops.map { ($0.id, $0) })
        var state: [String: Int] = [:] // 0=unvisited, 1=visiting, 2=done
        var result: [ForgeVideoOp] = []

        func visit(_ id: String) throws {
            let st = state[id] ?? 0
            if st == 2 { return }
            if st == 1 {
                throw SafariumError.invalidState("cycle detected in videoOps at '\(id)'")
            }
            guard let node = byID[id] else {
                throw SafariumError.invalidState("unknown videoOp reference '\(id)'")
            }
            state[id] = 1
            for ref in node.referencedNodeIDs() {
                if inputs.contains(ref) || lutInputs.contains(ref) { continue }
                if byID[ref] != nil {
                    try visit(ref)
                } else {
                    throw SafariumError.invalidState("videoOp '\(id)' references unknown input/node '\(ref)'")
                }
            }
            state[id] = 2
            result.append(node)
        }

        for op in ops {
            try visit(op.id)
        }
        return result
    }

    private static func topologicalSortAudioOps(
        _ ops: [ForgeAudioOp],
        audioInputs: Set<String>
    ) throws -> [ForgeAudioOp] {
        let byID = Dictionary(uniqueKeysWithValues: ops.map { ($0.id, $0) })
        var state: [String: Int] = [:]
        var result: [ForgeAudioOp] = []

        func visit(_ id: String) throws {
            let st = state[id] ?? 0
            if st == 2 { return }
            if st == 1 {
                throw SafariumError.invalidState("cycle detected in audioOps at '\(id)'")
            }
            guard let node = byID[id] else {
                throw SafariumError.invalidState("unknown audioOp reference '\(id)'")
            }
            state[id] = 1
            for rawRef in node.referencedNodeIDs() {
                let ref = stripAudioSuffix(rawRef)
                if audioInputs.contains(ref) { continue }
                if byID[ref] != nil {
                    try visit(ref)
                } else {
                    throw SafariumError.invalidState("audioOp '\(id)' references unknown audio input/node '\(rawRef)'")
                }
            }
            state[id] = 2
            result.append(node)
        }

        for op in ops {
            try visit(op.id)
        }
        return result
    }

    private static func isSpatialScalerOp(_ op: ForgeVideoOp) -> Bool {
        switch op.op {
        case .autoReframe, .kenBurns, .llsr:
            return true
        case .geom:
            let hasResize = op.width != nil || op.height != nil ||
                (op.scaleX != nil && op.scaleX != 1.0) ||
                (op.scaleY != nil && op.scaleY != 1.0) ||
                (op.scale != nil && op.scale != "1" && op.scale != "1.0")
            let hasNonRightRotate = op.rotateDegrees.map { abs($0.truncatingRemainder(dividingBy: 90.0)) > 1e-4 } ?? false
            return hasResize || hasNonRightRotate
        default:
            return false
        }
    }

    private static func validateVideoGraphRules(
        orderedVideoOps: [ForgeVideoOp],
        htmlInputIDs: Set<String>,
        lutInputIDs: Set<String>,
        requiresEvenYUV: Bool,
        warnings: inout [String]
    ) throws {
        var carriesHTML: [String: Bool] = [:]
        for id in htmlInputIDs { carriesHTML[id] = true }

        for op in orderedVideoOps {
            if let f = op.ptsFactor, (!f.isFinite || f <= 0) {
                throw SafariumError.invalidState("videoOp '\(op.id)' ptsFactor must be finite and > 0, got \(f)")
            }
            if let h = op.holdTailSeconds, (!h.isFinite || h < 0) {
                throw SafariumError.invalidState("videoOp '\(op.id)' holdTailSeconds must be finite and >= 0, got \(h)")
            }
            if op.op == .tmix, let w = op.tmixWeights {
                guard !w.isEmpty, w.allSatisfy({ $0.isFinite }) else {
                    throw SafariumError.invalidState("tmix '\(op.id)' tmixWeights must be non-empty finite values")
                }
            }
            // Validate required inputs per op kind
            switch op.op {
            case .splitMetalFX:
                guard let lr = op.lowResIn, let ov = op.overlay1xIn else {
                    throw SafariumError.invalidState("splitMetalFX '\(op.id)' requires lowResIn and overlay1xIn")
                }
                if carriesHTML[lr] == true {
                    throw SafariumError.invalidState("1x Thai/HTML Shield violation: htmlOverlay cannot be passed into splitMetalFX.lowResIn ('\(op.id)'); pass it into overlay1xIn instead")
                }
                // overlay1xIn is composited at native 1x without spatial scaling
                carriesHTML[op.id] = (carriesHTML[ov] == true)

            case .overlay, .blend:
                guard let b = op.base, let ov = op.over else {
                    throw SafariumError.invalidState("\(op.op.rawValue) '\(op.id)' requires base and over")
                }
                let overHasHTML = carriesHTML[ov] == true
                if overHasHTML, let sc = op.scale?.trimmingCharacters(in: .whitespacesAndNewlines), !sc.isEmpty {
                    let isUnit = (Double(sc).map { abs($0 - 1.0) < 1e-6 }) ?? false
                    if !isUnit {
                        throw SafariumError.invalidState("1x Thai/HTML Shield violation: overlay '\(op.id)' cannot scale htmlOverlay '\(ov)' (scale='\(sc)')")
                    }
                }
                carriesHTML[op.id] = (carriesHTML[b] == true) || overHasHTML

            case .htmlOverlay:
                let src = op.over ?? op.input
                guard src != nil else {
                    throw SafariumError.invalidState("htmlOverlay '\(op.id)' requires input/over")
                }
                carriesHTML[op.id] = true

            case .lut3d:
                guard let lutRef = op.lut else {
                    throw SafariumError.invalidState("lut3d '\(op.id)' requires lut input reference")
                }
                if !lutInputIDs.contains(lutRef) {
                    warnings.append("lut3d '\(op.id)' references '\(lutRef)' not declared as kind=lut3d")
                }
                let srcHasHTML = op.input.map { carriesHTML[$0] == true } ?? false
                carriesHTML[op.id] = srcHasHTML

            case .hstack, .vstack:
                guard let list = op.inputs, list.count >= 2 else {
                    throw SafariumError.invalidState("\(op.op.rawValue) '\(op.id)' requires >= 2 inputs")
                }
                carriesHTML[op.id] = list.contains { carriesHTML[$0] == true }

            case .xfade:
                guard let f = op.from, let t = op.to else {
                    throw SafariumError.invalidState("xfade '\(op.id)' requires from and to")
                }
                carriesHTML[op.id] = (carriesHTML[f] == true) || (carriesHTML[t] == true)

            default:
                let refs = op.referencedNodeIDs()
                let upstreamHasHTML = refs.contains { carriesHTML[$0] == true }
                if upstreamHasHTML && isSpatialScalerOp(op) {
                    throw SafariumError.invalidState("1x Thai/HTML Shield violation: '\(op.id)' (\(op.op.rawValue)) cannot scale/reframe downstream of htmlOverlay")
                }
                carriesHTML[op.id] = upstreamHasHTML
            }

            if requiresEvenYUV {
                if let tw = op.width, tw % 2 != 0 {
                    throw SafariumError.invalidState("YUV/NV12 requires even width on '\(op.id)', got \(tw)")
                }
                if let th = op.height, th % 2 != 0 {
                    throw SafariumError.invalidState("YUV/NV12 requires even height on '\(op.id)', got \(th)")
                }
            }
        }
    }
}
