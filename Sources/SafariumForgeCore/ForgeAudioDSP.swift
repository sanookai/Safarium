import Accelerate
import AVFoundation
import CoreMedia
import Foundation
import SafariumContainers
import SafariumCore

// MARK: - Streaming vDSP_biquadD Double-Precision EQ

public enum ForgeBiquadMode: String, Codable, Sendable {
    case highpass, hpf
    case lowpass, lpf
    case bandpass, bpf
    case peaking
    case lowshelf
    case highshelf

    public static func parse(_ s: String?) -> ForgeBiquadMode {
        switch s?.lowercased() {
        case "highpass", "hpf": return .highpass
        case "lowpass", "lpf": return .lowpass
        case "bandpass", "bpf": return .bandpass
        case "lowshelf": return .lowshelf
        case "highshelf": return .highshelf
        default: return .peaking
        }
    }
}

public struct ForgeBiquadSection: Sendable, Equatable {
    public let mode: ForgeBiquadMode
    public let freqHz: Double
    public let q: Double
    public let gainDB: Double

    public init(mode: ForgeBiquadMode, freqHz: Double, q: Double = 0.70710678, gainDB: Double = 0.0) {
        self.mode = mode
        self.freqHz = freqHz
        self.q = q
        self.gainDB = gainDB
    }

    /// Robert Bristow-Johnson Audio EQ Cookbook coefficients formatted for `vDSP_biquadD`: `[b0, b1, b2, a1, a2]`.
    public func coefficients(sampleRate: Double) -> [Double] {
        let nyq = max(100.0, sampleRate * 0.49)
        let f0 = max(10.0, min(nyq, freqHz))
        let w0 = 2.0 * Double.pi * f0 / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let safeQ = max(0.05, q)
        let alpha = sinW0 / (2.0 * safeQ)
        let A = pow(10.0, gainDB / 40.0)

        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch mode {
        case .highpass, .hpf:
            b0 = (1.0 + cosW0) * 0.5
            b1 = -(1.0 + cosW0)
            b2 = (1.0 + cosW0) * 0.5
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha
        case .lowpass, .lpf:
            b0 = (1.0 - cosW0) * 0.5
            b1 = 1.0 - cosW0
            b2 = (1.0 - cosW0) * 0.5
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha
        case .bandpass, .bpf:
            b0 = alpha
            b1 = 0.0
            b2 = -alpha
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha
        case .peaking:
            b0 = 1.0 + alpha * A
            b1 = -2.0 * cosW0
            b2 = 1.0 - alpha * A
            a0 = 1.0 + alpha / A
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha / A
        case .lowshelf:
            let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha
            b0 = A * ((A + 1.0) - (A - 1.0) * cosW0 + twoSqrtAAlpha)
            b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosW0)
            b2 = A * ((A + 1.0) - (A - 1.0) * cosW0 - twoSqrtAAlpha)
            a0 = (A + 1.0) + (A - 1.0) * cosW0 + twoSqrtAAlpha
            a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosW0)
            a2 = (A + 1.0) + (A - 1.0) * cosW0 - twoSqrtAAlpha
        case .highshelf:
            let twoSqrtAAlpha = 2.0 * sqrt(A) * alpha
            b0 = A * ((A + 1.0) + (A - 1.0) * cosW0 + twoSqrtAAlpha)
            b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosW0)
            b2 = A * ((A + 1.0) + (A - 1.0) * cosW0 - twoSqrtAAlpha)
            a0 = (A + 1.0) - (A - 1.0) * cosW0 + twoSqrtAAlpha
            a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosW0)
            a2 = (A + 1.0) - (A - 1.0) * cosW0 - twoSqrtAAlpha
        }
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }
}

public final class StreamingBiquadFilter {
    public let sampleRate: Double
    public let channels: Int
    public let sectionCount: Int
    private let setup: vDSP_biquad_SetupD
    private var delays: [[Double]]
    private var inScratch = [Double](repeating: 0, count: 4096)
    private var outScratch = [Double](repeating: 0, count: 4096)
    private var chFloatScratch = [Float](repeating: 0, count: 4096)

    public init(sampleRate: Double = 48_000, channels: Int = 2, sections: [ForgeBiquadSection]) throws {
        guard sampleRate.isFinite, sampleRate > 0, (1...2).contains(channels), !sections.isEmpty else {
            throw SafariumError.encode("StreamingBiquadFilter requires valid sampleRate, 1..2 channels, and >= 1 section")
        }
        self.sampleRate = sampleRate
        self.channels = channels
        self.sectionCount = sections.count
        var allCoeffs: [Double] = []
        allCoeffs.reserveCapacity(sections.count * 5)
        for sec in sections {
            allCoeffs.append(contentsOf: sec.coefficients(sampleRate: sampleRate))
        }
        guard let setup = vDSP_biquad_CreateSetupD(allCoeffs, vDSP_Length(sections.count)) else {
            throw SafariumError.encode("vDSP_biquad_CreateSetupD failed")
        }
        self.setup = setup
        self.delays = Array(repeating: [Double](repeating: 0, count: 2 * sections.count + 2), count: channels)
    }

    deinit {
        vDSP_biquad_DestroySetupD(setup)
    }

    public func reset() {
        for ch in delays.indices {
            for i in delays[ch].indices { delays[ch][i] = 0 }
        }
    }

    public func processBlock(interleaved: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        var offset = 0
        while offset < frameCount {
            let take = min(4096, frameCount - offset)
            for ch in 0..<channels {
                let ptr = interleaved.advanced(by: offset * channels + ch)
                chFloatScratch.withUnsafeMutableBufferPointer { fBuf in
                    inScratch.withUnsafeMutableBufferPointer { dIn in
                        outScratch.withUnsafeMutableBufferPointer { dOut in
                            delays[ch].withUnsafeMutableBufferPointer { dly in
                                if channels == 1 {
                                    vDSP_vspdp(ptr, 1, dIn.baseAddress!, 1, vDSP_Length(take))
                                } else {
                                    vDSP_vspdp(ptr, vDSP_Stride(channels), dIn.baseAddress!, 1, vDSP_Length(take))
                                }
                                vDSP_biquadD(setup, dly.baseAddress!, dIn.baseAddress!, 1, dOut.baseAddress!, 1, vDSP_Length(take))
                                if channels == 1 {
                                    vDSP_vdpsp(dOut.baseAddress!, 1, ptr, 1, vDSP_Length(take))
                                } else {
                                    vDSP_vdpsp(dOut.baseAddress!, 1, ptr, vDSP_Stride(channels), vDSP_Length(take))
                                }
                            }
                        }
                    }
                }
            }
            offset += take
        }
    }
}

// MARK: - Streaming O(4096) RMS Compressor

public final class StreamingRMSCompressor {
    public let sampleRate: Double
    public let channels: Int
    public let thresholdDB: Double
    public let ratio: Double
    public let makeupLinear: Float

    private let alphaAtt: Double
    private let alphaRel: Double
    private var envPower: Double = 0
    private var currentGain: Float = 1.0

    public init(
        sampleRate: Double = 48_000,
        channels: Int = 2,
        thresholdDB: Double = -18.0,
        ratio: Double = 4.0,
        attackMs: Double = 10.0,
        releaseMs: Double = 120.0,
        makeupDB: Double = 0.0
    ) throws {
        guard sampleRate.isFinite, sampleRate > 0, (1...2).contains(channels), ratio >= 1.0 else {
            throw SafariumError.encode("invalid StreamingRMSCompressor config")
        }
        self.sampleRate = sampleRate
        self.channels = channels
        self.thresholdDB = thresholdDB
        self.ratio = ratio
        self.makeupLinear = powf(10.0, Float(makeupDB / 20.0))
        let hopSec = 32.0 / sampleRate
        self.alphaAtt = exp(-hopSec / max(0.0005, attackMs / 1000.0))
        self.alphaRel = exp(-hopSec / max(0.001, releaseMs / 1000.0))
    }

    public func processBlock(interleaved: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        var offset = 0
        let hop = 32
        while offset < frameCount {
            let take = min(hop, frameCount - offset)
            var meanSq: Float = 0
            vDSP_measqv(interleaved.advanced(by: offset * channels), 1, &meanSq, vDSP_Length(take * channels))
            let instPower = Double(meanSq)
            let alpha = instPower > envPower ? alphaAtt : alphaRel
            envPower = alpha * envPower + (1.0 - alpha) * instPower
            let envDB = envPower > 1e-12 ? 10.0 * log10(envPower) : -120.0
            let gainDB = envDB > thresholdDB ? -(envDB - thresholdDB) * (1.0 - 1.0 / ratio) : 0.0
            let targetGain = powf(10.0, Float(gainDB / 20.0)) * makeupLinear

            let g0 = currentGain
            let step = (targetGain - g0) / Float(max(1, take))
            if channels == 1 {
                for i in 0..<take {
                    interleaved[offset + i] *= (g0 + step * Float(i + 1))
                }
            } else {
                for i in 0..<take {
                    let g = g0 + step * Float(i + 1)
                    interleaved[(offset + i) * 2] *= g
                    interleaved[(offset + i) * 2 + 1] *= g
                }
            }
            currentGain = targetGain
            offset += take
        }
    }
}

// MARK: - Procedural vDSP Audio Synth (replacing aevalsrc/sine)

public final class ForgeProceduralSynth {
    public enum Kind: Sendable {
        case sine(freqHz: Double)
        case whiteNoise(seed: UInt64)
        case pinkNoise(seed: UInt64)
        case amPad(carrierFreqsHz: [Double], modFreqHz: Double, modDepth: Double)
        case sweep(startHz: Double, endHz: Double, durationSeconds: Double)
    }

    public let kind: Kind
    public let sampleRate: Double
    public let channels: Int
    public let amplitude: Double
    public let totalFrames: Int64
    public let fadeInFrames: Int64
    public let fadeOutFrames: Int64

    private var frameCursor: Int64 = 0
    private var phases: [Double]
    private var modPhase: Double = 0
    private var rngState: UInt64
    private var pinkB = [Double](repeating: 0, count: 7)
    private var phaseScratch = [Float](repeating: 0, count: 4096)
    private var sineScratch = [Float](repeating: 0, count: 4096)

    public init(spec: ForgeAudioSynthSpec) throws {
        let sr = Double(spec.sampleRate ?? 48_000)
        let ch = spec.channels ?? 2
        guard sr.isFinite, sr > 0, (1...2).contains(ch), spec.durationSeconds > 0 else {
            throw SafariumError.invalidState("invalid ForgeAudioSynthSpec")
        }
        self.sampleRate = sr
        self.channels = ch
        self.amplitude = max(0.0, min(1.0, spec.amplitude ?? 0.25))
        self.totalFrames = max(1, Int64((spec.durationSeconds * sr).rounded()))
        self.fadeInFrames = max(0, Int64(((spec.fadeInSeconds ?? 0) * sr).rounded()))
        self.fadeOutFrames = max(0, Int64(((spec.fadeOutSeconds ?? 0) * sr).rounded()))
        self.rngState = 0x9E3779B97F4A7C15

        switch spec.waveform.lowercased() {
        case "whitenoise", "white", "white_noise":
            self.kind = .whiteNoise(seed: 0x9E3779B97F4A7C15)
            self.phases = []
        case "pinknoise", "pink", "pink_noise":
            self.kind = .pinkNoise(seed: 0x9E3779B97F4A7C15)
            self.phases = []
        case "ampad", "am", "pad":
            let carriers = (spec.carrierFrequenciesHz?.isEmpty == false) ? spec.carrierFrequenciesHz! : [110.0, 165.0, 220.0]
            self.kind = .amPad(carrierFreqsHz: carriers, modFreqHz: spec.modulationHz ?? 0.35, modDepth: spec.modulationDepth ?? 0.45)
            self.phases = [Double](repeating: 0, count: carriers.count)
        case "sweep", "chirp":
            self.kind = .sweep(startHz: spec.frequencyHz ?? 440.0, endFrequencyHz: spec.endFrequencyHz ?? 880.0, durationSeconds: spec.durationSeconds)
            self.phases = [0.0]
        default:
            self.kind = .sine(freqHz: spec.frequencyHz ?? 440.0)
            self.phases = [0.0]
        }
    }

    private init(
        kind: Kind,
        sampleRate: Double,
        channels: Int,
        amplitude: Double,
        totalFrames: Int64,
        fadeInFrames: Int64,
        fadeOutFrames: Int64,
        phases: [Double],
        rngState: UInt64
    ) {
        self.kind = kind
        self.sampleRate = sampleRate
        self.channels = channels
        self.amplitude = amplitude
        self.totalFrames = totalFrames
        self.fadeInFrames = fadeInFrames
        self.fadeOutFrames = fadeOutFrames
        self.phases = phases
        self.rngState = rngState
    }

    private func nextWhite() -> Double {
        rngState ^= rngState >> 12
        rngState ^= rngState << 25
        rngState ^= rngState >> 27
        let v = rngState &* 0x2545F4914F6CDD1D
        return (Double(v >> 11) / Double(1 << 53)) * 2.0 - 1.0
    }

    /// Generates up to `maxFrames` (`<= 4096`) into `interleaved`, returning actual frames generated (`0` at EOF).
    public func renderNextBlock(into interleaved: UnsafeMutablePointer<Float>, maxFrames: Int = 4096) -> Int {
        let remaining = totalFrames - frameCursor
        if remaining <= 0 { return 0 }
        let n = min(min(4096, maxFrames), Int(remaining))
        let twoPi = 2.0 * Double.pi

        switch kind {
        case .sine(let freqHz):
            let step = twoPi * freqHz / sampleRate
            var p = phases[0]
            for i in 0..<n {
                phaseScratch[i] = Float(p)
                p += step
                if p >= twoPi { p -= twoPi }
            }
            phases[0] = p
            var count32 = Int32(n)
            vvsinf(&sineScratch, &phaseScratch, &count32)
            var amp = Float(amplitude)
            vDSP_vsmul(sineScratch, 1, &amp, &sineScratch, 1, vDSP_Length(n))

        case .whiteNoise:
            let ampF = Float(amplitude)
            for i in 0..<n {
                sineScratch[i] = Float(nextWhite()) * ampF
            }

        case .pinkNoise:
            // Paul Kellet refined pinking filter
            for i in 0..<n {
                let white = nextWhite()
                pinkB[0] = 0.99886 * pinkB[0] + white * 0.0555179
                pinkB[1] = 0.99332 * pinkB[1] + white * 0.0750759
                pinkB[2] = 0.96900 * pinkB[2] + white * 0.1538520
                pinkB[3] = 0.86650 * pinkB[3] + white * 0.3104856
                pinkB[4] = 0.55000 * pinkB[4] + white * 0.5329522
                pinkB[5] = -0.7616 * pinkB[5] - white * 0.0168980
                let pink = (pinkB[0] + pinkB[1] + pinkB[2] + pinkB[3] + pinkB[4] + pinkB[5] + pinkB[6] + white * 0.5362) * 0.11
                pinkB[6] = white * 0.115926
                sineScratch[i] = Float(max(-1.0, min(1.0, pink * amplitude)))
            }

        case .amPad(let carriers, let modHz, let modDepth):
            vDSP_vclr(&sineScratch, 1, vDSP_Length(n))
            let modStep = twoPi * modHz / sampleRate
            let invC = 1.0 / Double(max(1, carriers.count))
            for idx in 0..<carriers.count {
                let step = twoPi * carriers[idx] / sampleRate
                var p = phases[idx]
                for i in 0..<n {
                    phaseScratch[i] = Float(p)
                    p += step
                    if p >= twoPi { p -= twoPi }
                }
                phases[idx] = p
                var count32 = Int32(n)
                var tmp = [Float](repeating: 0, count: n)
                vvsinf(&tmp, &phaseScratch, &count32)
                var w = Float(invC)
                vDSP_vsma(tmp, 1, &w, sineScratch, 1, &sineScratch, 1, vDSP_Length(n))
            }
            for i in 0..<n {
                let env = (1.0 - modDepth * 0.5 * (1.0 - cos(modPhase))) * amplitude
                sineScratch[i] *= Float(env)
                modPhase += modStep
                if modPhase >= twoPi { modPhase -= twoPi }
            }

        case .sweep(let startHz, let endHz, _):
            var p = phases[0]
            for i in 0..<n {
                let u = Double(frameCursor + Int64(i)) / Double(max(1, totalFrames - 1))
                let instFreq = startHz + (endHz - startHz) * u
                phaseScratch[i] = Float(p)
                p += twoPi * instFreq / sampleRate
                if p >= twoPi { p -= twoPi }
            }
            phases[0] = p
            var count32 = Int32(n)
            vvsinf(&sineScratch, &phaseScratch, &count32)
            var amp = Float(amplitude)
            vDSP_vsmul(sineScratch, 1, &amp, &sineScratch, 1, vDSP_Length(n))
        }

        // Apply fade-in / fade-out and interleave
        for i in 0..<n {
            let pos = frameCursor + Int64(i)
            var env: Float = 1.0
            if fadeInFrames > 0 && pos < fadeInFrames {
                env *= Float(pos) / Float(fadeInFrames)
            }
            if fadeOutFrames > 0 && (totalFrames - pos) < fadeOutFrames {
                env *= Float(max(0, totalFrames - pos)) / Float(fadeOutFrames)
            }
            let sample = sineScratch[i] * env
            if channels == 1 {
                interleaved[i] = sample
            } else {
                interleaved[i * 2] = sample
                interleaved[i * 2 + 1] = sample
            }
        }
        frameCursor += Int64(n)
        return n
    }

    public static func renderToFile(spec: ForgeAudioSynthSpec, outputURL: URL, overwrite: Bool = false) async throws -> ForgeAudioProcessReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let stage = try APFSAutoStage.makeSession(for: outputURL, overwrite: overwrite)
        defer { stage.cleanup() }
        let synth = try ForgeProceduralSynth(spec: spec)
        let ext = outputURL.pathExtension.lowercased()
        let staged = stage.fileURL("synth.\(ext.isEmpty ? "wav" : ext)")
        let sink = try ForgeStreamingAudioSink(url: staged, sampleRate: Int(synth.sampleRate), channels: synth.channels)
        let meter = try LoudnessMeter(sampleRate: synth.sampleRate, channels: synth.channels)
        var buf = [Float](repeating: 0, count: 4096 * synth.channels)

        do {
            while true {
                let n = buf.withUnsafeMutableBufferPointer { ptr in
                    synth.renderNextBlock(into: ptr.baseAddress!, maxFrames: 4096)
                }
                if n == 0 { break }
                buf.withUnsafeBufferPointer { ptr in
                    meter.processInterleaved(UnsafeBufferPointer(start: ptr.baseAddress, count: n * synth.channels))
                }
                try await sink.append(interleavedFrames: buf, frameCount: n)
            }
            try await sink.finish()
            try stage.commit(stagedFile: staged, overwrite: overwrite)
        } catch {
            sink.cancel()
            throw error
        }

        return ForgeAudioProcessReport(
            outputPath: outputURL.path,
            sampleRate: Int(synth.sampleRate),
            channels: synth.channels,
            durationSeconds: Double(meter.processedFrames) / synth.sampleRate,
            integratedLUFS: meter.gatedLUFS.isFinite ? meter.gatedLUFS : nil,
            truePeakDBTP: meter.truePeakDBTP.isFinite ? meter.truePeakDBTP : nil,
            wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        )
    }
}

private extension ForgeProceduralSynth.Kind {
    static func sweep(startHz: Double, endFrequencyHz: Double, durationSeconds: Double) -> Self {
        .sweep(startHz: startHz, endHz: endFrequencyHz, durationSeconds: durationSeconds)
    }
}

// MARK: - Bounded Streaming Audio Reader & Writer (O(4096) RAM)

public final class ForgeStreamingAudioReader {
    public let url: URL
    public let sampleRate: Double
    public let channels: Int
    public let durationSeconds: Double

    private var assetReader: AVAssetReader?
    private var assetOutput: AVAssetReaderTrackOutput?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat
    private var sourceBuffer: AVAudioPCMBuffer?
    private var convertedBuffer: AVAudioPCMBuffer?
    private var residual: [Float] = []
    private var residualOffset = 0
    private var eofReached = false
    private var totalSourceFrames: AVAudioFramePosition = 0
    private var readSourceFrames: AVAudioFramePosition = 0

    private var tempCleanupURL: URL?

    public init(
        url: URL,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        startSeconds: Double = 0,
        endSeconds: Double? = nil
    ) async throws {
        try SafeFilePublisher.assertRegularReadableFile(url)
        MediaCompatBridge.registerSupplementalDecoders()
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        guard let dstFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            throw SafariumError.encode("unsupported target PCM format")
        }
        self.targetFormat = dstFmt

        var resolvedURL = url
        let ext = url.pathExtension.lowercased()
        if ext == "mkv" || ext == "webm" {
            let tmpMP4 = FileManager.default.temporaryDirectory.appendingPathComponent("forge-aud-\(UUID().uuidString).mp4")
            _ = try await EBMLMatroskaCodec.demuxToMP4(inputURL: url, outputURL: tmpMP4, overwrite: true)
            resolvedURL = tmpMP4
            self.tempCleanupURL = tmpMP4
        } else if ext == "ts" || ext == "m2ts" {
            let tmpMP4 = FileManager.default.temporaryDirectory.appendingPathComponent("forge-aud-\(UUID().uuidString).mp4")
            _ = try await MPEGTSCodec.demuxToMP4(inputURL: url, outputURL: tmpMP4, overwrite: true)
            resolvedURL = tmpMP4
            self.tempCleanupURL = tmpMP4
        }

        let resolvedExt = resolvedURL.pathExtension.lowercased()
        let directAudioExts: Set<String> = ["wav", "mp3", "flac", "caf", "aiff", "aif"]
        let legacyContainerExts: Set<String> = ["ogg", "oga", "opus", "mpeg", "mpg"]
        if directAudioExts.contains(resolvedExt), let file = try? AVAudioFile(forReading: resolvedURL) {
            let srcRate = file.fileFormat.sampleRate
            let fileDur = Double(file.length) / max(1.0, srcRate)
            let startPos = max(0, min(file.length, AVAudioFramePosition((startSeconds * srcRate).rounded())))
            let endPos = endSeconds.map { min(file.length, max(startPos, AVAudioFramePosition(($0 * srcRate).rounded()))) } ?? file.length
            file.framePosition = startPos
            self.audioFile = file
            self.totalSourceFrames = endPos - startPos
            self.durationSeconds = Double(self.totalSourceFrames) / max(1.0, srcRate)
            if file.processingFormat.sampleRate != sampleRate ||
               Int(file.processingFormat.channelCount) != channels ||
               !file.processingFormat.isInterleaved ||
               file.processingFormat.commonFormat != .pcmFormatFloat32 {
                guard let conv = AVAudioConverter(from: file.processingFormat, to: dstFmt) else {
                    throw SafariumError.encode("AVAudioConverter unavailable for \(resolvedURL.lastPathComponent)")
                }
                self.converter = conv
            }
            self.sourceBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)
            self.convertedBuffer = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: 8192)
            _ = fileDur
            return
        }

        if !legacyContainerExts.contains(resolvedExt) {
            let asset = AVURLAsset(url: resolvedURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            if let track = tracks.first {
                let assetDur = try await asset.load(.duration).seconds
                let sSec = max(0.0, startSeconds)
                let eSec = endSeconds.map { min(assetDur, max(sSec, $0)) } ?? assetDur
                self.durationSeconds = max(0.0, eSec - sSec)

                let reader = try AVAssetReader(asset: asset)
                if sSec > 0 || endSeconds != nil {
                    reader.timeRange = CMTimeRange(
                        start: CMTime(seconds: sSec, preferredTimescale: 600_000),
                        duration: CMTime(seconds: max(0.001, eSec - sSec), preferredTimescale: 600_000)
                    )
                }
                let outSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVLinearPCMIsFloatKey: true,
                    AVLinearPCMBitDepthKey: 32,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
                let out = AVAssetReaderTrackOutput(track: track, outputSettings: outSettings)
                out.alwaysCopiesSampleData = false
                guard reader.canAdd(out) else {
                    throw SafariumError.encode("AVAssetReader cannot read audio from \(resolvedURL.lastPathComponent)")
                }
                reader.add(out)
                guard reader.startReading() else {
                    throw SafariumError.encode("AVAssetReader audio failed: \(reader.error?.localizedDescription ?? "?")")
                }
                self.assetReader = reader
                self.assetOutput = out
                return
            }
        }

        // Fallback via SafariumContainers.MediaCompatBridge (Ogg Vorbis / Ogg FLAC / MPEG-2 PS audio / ExtAudioFile -> bounded Float32 WAV)
        let bridgedWAV = FileManager.default.temporaryDirectory.appendingPathComponent("forge-bridge-\(UUID().uuidString).wav")
        if let existingTmp = self.tempCleanupURL { try? FileManager.default.removeItem(at: existingTmp) }
        self.tempCleanupURL = bridgedWAV
        let wavFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: true)!
        do {
            let outFile = try AVAudioFile(forWriting: bridgedWAV, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: true)
            let capFrames = 4096
            let writeBuf = AVAudioPCMBuffer(pcmFormat: wavFmt, frameCapacity: AVAudioFrameCount(capFrames))!
            _ = try MediaCompatBridge.streamAudioToFloat32PCM(url: resolvedURL, sampleRate: sampleRate, channels: channels, chunkFrames: capFrames) { chunk, n in
                guard n > 0, let srcBase = chunk.baseAddress, let dstBase = writeBuf.audioBufferList.pointee.mBuffers.mData else { return }
                var offset = 0
                while offset < n {
                    let take = min(capFrames, n - offset)
                    writeBuf.frameLength = AVAudioFrameCount(take)
                    _ = memcpy(dstBase, srcBase + offset * channels, take * channels * 4)
                    try outFile.write(from: writeBuf)
                    offset += take
                }
            }
            #if compiler(>=6.0)
            if #available(macOS 15.0, *) { outFile.close() }
            #endif
        }

        let file = try AVAudioFile(forReading: bridgedWAV)
        let startPos = max(0, min(file.length, AVAudioFramePosition((startSeconds * sampleRate).rounded())))
        let endPos = endSeconds.map { min(file.length, max(startPos, AVAudioFramePosition(($0 * sampleRate).rounded()))) } ?? file.length
        file.framePosition = startPos
        self.audioFile = file
        self.totalSourceFrames = endPos - startPos
        self.durationSeconds = Double(self.totalSourceFrames) / sampleRate
        self.sourceBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)
        self.convertedBuffer = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: 8192)
    }

    deinit {
        close()
    }

    public func close() {
        assetReader?.cancelReading()
        assetReader = nil
        assetOutput = nil
        audioFile = nil
        if let tmp = tempCleanupURL {
            try? FileManager.default.removeItem(at: tmp)
            tempCleanupURL = nil
        }
    }

    private func pumpNextChunk() throws -> Bool {
        if residualOffset * 2 > residual.count && residualOffset > 0 {
            residual.removeFirst(residualOffset)
            residualOffset = 0
        }
        if let file = audioFile, let srcBuf = sourceBuffer {
            let remaining = Int(totalSourceFrames - readSourceFrames)
            if remaining <= 0 {
                eofReached = true
                return false
            }
            let want = min(4096, remaining)
            srcBuf.frameLength = 0
            try file.read(into: srcBuf, frameCount: AVAudioFrameCount(want))
            let got = Int(srcBuf.frameLength)
            if got == 0 {
                eofReached = true
                return false
            }
            readSourceFrames += AVAudioFramePosition(got)

            if let conv = converter, let outBuf = convertedBuffer {
                outBuf.frameLength = 0
                var fed = false
                var convErr: NSError?
                let st = conv.convert(to: outBuf, error: &convErr) { _, outStatus in
                    if fed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    fed = true
                    outStatus.pointee = .haveData
                    return srcBuf
                }
                if st == .error, let convErr {
                    throw SafariumError.encode("AVAudioConverter failed: \(convErr.localizedDescription)")
                }
                let outFrames = Int(outBuf.frameLength)
                if outFrames > 0, let mData = outBuf.audioBufferList.pointee.mBuffers.mData {
                    let fPtr = mData.assumingMemoryBound(to: Float.self)
                    residual.append(contentsOf: UnsafeBufferPointer(start: fPtr, count: outFrames * channels))
                    return true
                }
                return try pumpNextChunk()
            } else if let mData = srcBuf.audioBufferList.pointee.mBuffers.mData {
                let fPtr = mData.assumingMemoryBound(to: Float.self)
                residual.append(contentsOf: UnsafeBufferPointer(start: fPtr, count: got * channels))
                return true
            }
            return false
        }

        if let out = assetOutput {
            guard let sb = autoreleasepool(invoking: { out.copyNextSampleBuffer() }) else {
                if assetReader?.status == .failed {
                    throw SafariumError.encode("audio read failed: \(assetReader?.error?.localizedDescription ?? "?")")
                }
                eofReached = true
                return false
            }
            guard CMSampleBufferGetNumSamples(sb) > 0, let bb = CMSampleBufferGetDataBuffer(sb) else {
                return try pumpNextChunk()
            }
            let bytes = CMBlockBufferGetDataLength(bb)
            let floats = bytes / 4
            if floats > 0 {
                let old = residual.count
                residual.append(contentsOf: repeatElement(Float(0), count: floats))
                _ = residual.withUnsafeMutableBytes { raw in
                    CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: bytes, destination: raw.baseAddress!.advanced(by: old * 4))
                }
                return true
            }
            return try pumpNextChunk()
        }

        eofReached = true
        return false
    }

    public func readNextBlock(into dst: UnsafeMutablePointer<Float>, maxFrames: Int = 4096) throws -> Int {
        var written = 0
        while written < maxFrames {
            let availFloats = residual.count - residualOffset
            let availFrames = availFloats / channels
            if availFrames == 0 {
                if eofReached { break }
                if try !pumpNextChunk() { break }
                continue
            }
            let take = min(maxFrames - written, availFrames)
            let takeFloats = take * channels
            residual.withUnsafeBufferPointer { src in
                _ = memcpy(dst.advanced(by: written * channels), src.baseAddress! + residualOffset, takeFloats * 4)
            }
            residualOffset += takeFloats
            written += take
        }
        return written
    }
}

public final class ForgeStreamingAudioSink {
    private enum Kind { case wav, m4a, rawS16LE }
    private let kind: Kind
    private let sampleRate: Int
    private let channels: Int
    private let pcmFormat: AVAudioFormat
    private var wavFile: AVAudioFile?
    private var wavBuf: AVAudioPCMBuffer?
    private var rawHandle: FileHandle?
    private var s16Scratch: [Int16] = []
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var gate: InputReadyGate?
    private var writtenFrames: Int64 = 0

    public init(url: URL, sampleRate: Int = 48_000, channels: Int = 2, bitrate: Int = 192_000, wavBitDepth: Int = 16) throws {
        self.sampleRate = sampleRate
        self.channels = channels
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else {
            throw SafariumError.encode("invalid sink audio format")
        }
        self.pcmFormat = fmt
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "wav":
            self.kind = .wav
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Double(sampleRate),
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: wavBitDepth,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            self.wavFile = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: true)
            self.wavBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096)
        case "s16le", "pcm", "raw":
            self.kind = .rawS16LE
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self.rawHandle = try FileHandle(forWritingTo: url)
        case "m4a", "aac", "mp4":
            self.kind = .m4a
            let w = try AVAssetWriter(url: url, fileType: ext == "mp4" ? .mp4 : .m4a)
            let aac: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: bitrate,
            ]
            let inp = AVAssetWriterInput(mediaType: .audio, outputSettings: aac, sourceFormatHint: fmt.formatDescription)
            inp.expectsMediaDataInRealTime = false
            guard w.canAdd(inp) else { throw SafariumError.encode("cannot add AAC writer input") }
            w.add(inp)
            guard w.startWriting() else { throw SafariumError.encode("audio writer failed: \(w.error?.localizedDescription ?? "?")") }
            w.startSession(atSourceTime: .zero)
            self.writer = w
            self.input = inp
            self.gate = InputReadyGate(input: inp, writer: w)
        default:
            throw SafariumError.invalidState("unsupported audio sink extension '.\(ext)' (expected wav|m4a|s16le)")
        }
    }

    public func append(interleavedFrames frames: [Float], frameOffset: Int = 0, frameCount: Int) async throws {
        guard frameCount > 0 else { return }
        switch kind {
        case .wav:
            guard let wavFile, let wavBuf else { return }
            var off = 0
            while off < frameCount {
                let take = min(Int(wavBuf.frameCapacity), frameCount - off)
                wavBuf.frameLength = AVAudioFrameCount(take)
                if let dst = wavBuf.audioBufferList.pointee.mBuffers.mData {
                    frames.withUnsafeBufferPointer { src in
                        _ = memcpy(dst, src.baseAddress!.advanced(by: (frameOffset + off) * channels), take * channels * 4)
                    }
                }
                try wavFile.write(from: wavBuf)
                off += take
            }
            writtenFrames += Int64(frameCount)
        case .rawS16LE:
            guard let rawHandle else { return }
            let startSample = frameOffset * channels
            let total = frameCount * channels
            if s16Scratch.count < total { s16Scratch = [Int16](repeating: 0, count: total) }
            for i in 0..<total {
                let clamped = max(-1.0, min(1.0, frames[startSample + i]))
                s16Scratch[i] = Int16((clamped * 32767.0).rounded())
            }
            let sliceData = s16Scratch.withUnsafeBytes { raw in
                Data(bytes: raw.baseAddress!, count: total * 2)
            }
            try rawHandle.write(contentsOf: sliceData)
            writtenFrames += Int64(frameCount)
        case .m4a:
            guard let writer, let input, let gate else { return }
            try await gate.waitUntilReady()
            let bytes = frameCount * channels * 4
            var bb: CMBlockBuffer?
            let st1 = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &bb)
            guard st1 == noErr, let bb else { throw SafariumError.encode("CMBlockBuffer failed (\(st1))") }
            let st2 = frames.withUnsafeBufferPointer { src in
                CMBlockBufferReplaceDataBytes(with: src.baseAddress!.advanced(by: frameOffset * channels), blockBuffer: bb, offsetIntoDestination: 0, dataLength: bytes)
            }
            guard st2 == noErr else { throw SafariumError.encode("CMBlockBuffer copy failed (\(st2))") }
            var sb: CMSampleBuffer?
            let pts = CMTime(value: writtenFrames, timescale: Int32(sampleRate))
            let st3 = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: pcmFormat.formatDescription, sampleCount: frameCount, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sb)
            guard st3 == noErr, let sb else { throw SafariumError.encode("CMAudioSampleBuffer failed (\(st3))") }
            guard input.append(sb) else {
                throw SafariumError.encode("audio append failed: \(writer.error?.localizedDescription ?? "?")")
            }
            writtenFrames += Int64(frameCount)
        }
    }

    public func finish() async throws {
        switch kind {
        case .wav:
            #if compiler(>=6.0)
            if #available(macOS 15.0, *) { wavFile?.close() }
            #endif
            wavFile = nil; wavBuf = nil
        case .rawS16LE:
            try? rawHandle?.close()
            rawHandle = nil
        case .m4a:
            gate?.invalidate()
            input?.markAsFinished()
            writer?.endSession(atSourceTime: CMTime(value: writtenFrames, timescale: Int32(sampleRate)))
            await writer?.finishWriting()
            if writer?.status != .completed {
                throw SafariumError.encode("audio finish failed: \(writer?.error?.localizedDescription ?? "?")")
            }
        }
    }

    public func cancel() {
        wavFile = nil; wavBuf = nil
        try? rawHandle?.close(); rawHandle = nil
        gate?.invalidate()
        if writer?.status == .writing { writer?.cancelWriting() }
    }
}

// MARK: - Reports & High-Level Audio DSP Operations

public struct ForgeAudioProcessReport: Codable, Sendable {
    public let outputPath: String
    public let sampleRate: Int
    public let channels: Int
    public let durationSeconds: Double
    public let integratedLUFS: Double?
    public let truePeakDBTP: Double?
    public let wallMs: Double
}

public struct ForgeSilenceTrimReport: Codable, Sendable {
    public let inputPath: String
    public let outputPath: String
    public let originalDurationSeconds: Double
    public let trimmedStartSeconds: Double
    public let trimmedEndSeconds: Double
    public let trimmedDurationSeconds: Double
    public let mode: String
    public let wallMs: Double
}

public struct ForgeWaveformReport: Codable, Sendable {
    public let inputPath: String
    public let sampleRate: Int
    public let channels: Int
    public let durationSeconds: Double
    public let binCount: Int
    public let peaks: [Float]
    public let rmsLevels: [Float]
    public let wallMs: Double
}

public enum ForgeAudioDSP {
    public static func crossfadeAudio(
        firstURL: URL,
        secondURL: URL,
        durationSeconds: Double,
        curve: String = "eqpower",
        sampleRate: Double = 48_000,
        channels: Int = 2,
        outputURL: URL,
        overwrite: Bool = false
    ) async throws -> ForgeAudioProcessReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw SafariumError.invalidState("acrossfade durationSeconds must be > 0")
        }
        let stage = try APFSAutoStage.makeSession(for: outputURL, overwrite: overwrite)
        defer { stage.cleanup() }

        let rA = try await ForgeStreamingAudioReader(url: firstURL, sampleRate: sampleRate, channels: channels)
        let rB = try await ForgeStreamingAudioReader(url: secondURL, sampleRate: sampleRate, channels: channels)
        defer { rA.close(); rB.close() }

        let totalFramesA = max(1, Int64((rA.durationSeconds * sampleRate).rounded()))
        let fadeFrames = min(totalFramesA, max(1, Int64((durationSeconds * sampleRate).rounded())))
        let fadeStartFrame = totalFramesA - fadeFrames
        let equalPower = curve.lowercased() != "tri"

        let ext = outputURL.pathExtension.lowercased()
        let staged = stage.fileURL("crossfade.\(ext.isEmpty ? "wav" : ext)")
        let sink = try ForgeStreamingAudioSink(url: staged, sampleRate: Int(sampleRate), channels: channels)
        let meter = try LoudnessMeter(sampleRate: sampleRate, channels: channels)

        var bufA = [Float](repeating: 0, count: 4096 * channels)
        var bufB = [Float](repeating: 0, count: 4096 * channels)
        var outBuf = [Float](repeating: 0, count: 4096 * channels)
        var cursorA: Int64 = 0
        var fadePos: Int64 = 0

        do {
            while true {
                let gotA = try bufA.withUnsafeMutableBufferPointer { try rA.readNextBlock(into: $0.baseAddress!, maxFrames: 4096) }
                if gotA == 0 { break }
                let blockStart = cursorA
                let blockEnd = cursorA + Int64(gotA)

                if blockEnd <= fadeStartFrame {
                    bufA.withUnsafeBufferPointer {
                        meter.processInterleaved(UnsafeBufferPointer(start: $0.baseAddress, count: gotA * channels))
                    }
                    try await sink.append(interleavedFrames: bufA, frameCount: gotA)
                } else {
                    let preCount = Int(max(0, fadeStartFrame - blockStart))
                    if preCount > 0 {
                        bufA.withUnsafeBufferPointer {
                            meter.processInterleaved(UnsafeBufferPointer(start: $0.baseAddress, count: preCount * channels))
                        }
                        try await sink.append(interleavedFrames: bufA, frameCount: preCount)
                    }
                    let overlapInBlock = gotA - preCount
                    if overlapInBlock > 0 {
                        let gotB = try bufB.withUnsafeMutableBufferPointer { try rB.readNextBlock(into: $0.baseAddress!, maxFrames: overlapInBlock) }
                        for i in 0..<overlapInBlock {
                            let u = Double(min(fadeFrames, fadePos + Int64(i))) / Double(max(1, fadeFrames))
                            let gA: Float = equalPower ? Float(cos(u * Double.pi * 0.5)) : Float(1.0 - u)
                            let gB: Float = equalPower ? Float(sin(u * Double.pi * 0.5)) : Float(u)
                            for c in 0..<channels {
                                let aVal = bufA[(preCount + i) * channels + c]
                                let bVal = i < gotB ? bufB[i * channels + c] : 0.0
                                outBuf[i * channels + c] = aVal * gA + bVal * gB
                            }
                        }
                        fadePos += Int64(overlapInBlock)
                        outBuf.withUnsafeBufferPointer {
                            meter.processInterleaved(UnsafeBufferPointer(start: $0.baseAddress, count: overlapInBlock * channels))
                        }
                        try await sink.append(interleavedFrames: outBuf, frameCount: overlapInBlock)
                    }
                }
                cursorA = blockEnd
            }

            while true {
                let gotB = try bufB.withUnsafeMutableBufferPointer { try rB.readNextBlock(into: $0.baseAddress!, maxFrames: 4096) }
                if gotB == 0 { break }
                bufB.withUnsafeBufferPointer {
                    meter.processInterleaved(UnsafeBufferPointer(start: $0.baseAddress, count: gotB * channels))
                }
                try await sink.append(interleavedFrames: bufB, frameCount: gotB)
            }
            try await sink.finish()
            try stage.commit(stagedFile: staged, overwrite: overwrite)
        } catch {
            sink.cancel()
            throw error
        }

        return ForgeAudioProcessReport(
            outputPath: outputURL.path,
            sampleRate: Int(sampleRate),
            channels: channels,
            durationSeconds: Double(meter.processedFrames) / sampleRate,
            integratedLUFS: meter.gatedLUFS.isFinite ? meter.gatedLUFS : nil,
            truePeakDBTP: meter.truePeakDBTP.isFinite ? meter.truePeakDBTP : nil,
            wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        )
    }

    /// Two-cursor O(4096) silence trim avoiding `areverse` full-file RAM OOM!
    public static func silenceTrim(
        inputURL: URL,
        outputURL: URL,
        thresholdDB: Double = -42.0,
        paddingSeconds: Double = 0.05,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        overwrite: Bool = false
    ) async throws -> ForgeSilenceTrimReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.assertRegularReadableFile(inputURL)
        let stage = try APFSAutoStage.makeSession(for: outputURL, overwrite: overwrite)
        defer { stage.cleanup() }

        // Pass 1: O(4096) streaming energy envelope scan recording ONLY scalar start/end bounds.
        let scanReader = try await ForgeStreamingAudioReader(url: inputURL, sampleRate: sampleRate, channels: channels)
        let origDur = scanReader.durationSeconds
        var buf = [Float](repeating: 0, count: 4096 * channels)
        let hopFrames = 480 // 10 ms @ 48 kHz
        var framePos: Int64 = 0
        var firstActiveFrame: Int64?
        var lastActiveFrame: Int64?
        let threshLinearSq = pow(10.0, thresholdDB / 10.0)

        while true {
            let n = try buf.withUnsafeMutableBufferPointer { try scanReader.readNextBlock(into: $0.baseAddress!, maxFrames: 4096) }
            if n == 0 { break }
            var off = 0
            while off < n {
                let take = min(hopFrames, n - off)
                var msq: Float = 0
                buf.withUnsafeBufferPointer { ptr in
                    vDSP_measqv(ptr.baseAddress!.advanced(by: off * channels), 1, &msq, vDSP_Length(take * channels))
                }
                if Double(msq) >= threshLinearSq {
                    if firstActiveFrame == nil { firstActiveFrame = framePos + Int64(off) }
                    lastActiveFrame = framePos + Int64(off + take)
                }
                off += take
            }
            framePos += Int64(n)
        }
        scanReader.close()

        guard let startF = firstActiveFrame, let endF = lastActiveFrame, endF > startF else {
            throw SafariumError.invalidState("silenceTrim found no audio above \(thresholdDB) dBFS in \(inputURL.lastPathComponent)")
        }

        let padFrames = Int64((max(0.0, paddingSeconds) * sampleRate).rounded())
        let trimStartSec = max(0.0, Double(max(0, startF - padFrames)) / sampleRate)
        let trimEndSec = min(max(origDur, Double(framePos) / sampleRate), Double(min(framePos, endF + padFrames)) / sampleRate)

        // Pass 2: Stream ONLY [trimStartSec, trimEndSec] in O(4096) blocks.
        let copyReader = try await ForgeStreamingAudioReader(
            url: inputURL, sampleRate: sampleRate, channels: channels, startSeconds: trimStartSec, endSeconds: trimEndSec
        )
        defer { copyReader.close() }
        let ext = outputURL.pathExtension.lowercased()
        let staged = stage.fileURL("trimmed.\(ext.isEmpty ? "wav" : ext)")
        let sink = try ForgeStreamingAudioSink(url: staged, sampleRate: Int(sampleRate), channels: channels)
        var written: Int64 = 0

        do {
            while true {
                let n = try buf.withUnsafeMutableBufferPointer { try copyReader.readNextBlock(into: $0.baseAddress!, maxFrames: 4096) }
                if n == 0 { break }
                try await sink.append(interleavedFrames: buf, frameCount: n)
                written += Int64(n)
            }
            try await sink.finish()
            try stage.commit(stagedFile: staged, overwrite: overwrite)
        } catch {
            sink.cancel()
            throw error
        }

        return ForgeSilenceTrimReport(
            inputPath: inputURL.path,
            outputPath: outputURL.path,
            originalDurationSeconds: origDur,
            trimmedStartSeconds: trimStartSec,
            trimmedEndSeconds: trimEndSec,
            trimmedDurationSeconds: Double(written) / sampleRate,
            mode: "two_cursor_O4096",
            wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        )
    }

    /// Streams input audio in O(4096) blocks to extract `60...600` peak and RMS bins (zero full-file RAM buffer).
    public static func extractWaveform(
        inputURL: URL,
        bins: Int = 120,
        sampleRate: Double = 8_000
    ) async throws -> ForgeWaveformReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard (60...600).contains(bins) else {
            throw SafariumError.invalidState("waveform bins must be in 60...600, got \(bins)")
        }
        let reader = try await ForgeStreamingAudioReader(url: inputURL, sampleRate: sampleRate, channels: 1)
        defer { reader.close() }

        let estFrames = max(bins, Int((reader.durationSeconds * sampleRate).rounded()))
        let framesPerBin = max(1, estFrames / bins)
        var peaks = [Float](repeating: 0, count: bins)
        var sumSq = [Double](repeating: 0, count: bins)
        var counts = [Int](repeating: 0, count: bins)

        var buf = [Float](repeating: 0, count: 4096)
        var totalFrames: Int64 = 0

        while true {
            let n = try buf.withUnsafeMutableBufferPointer { try reader.readNextBlock(into: $0.baseAddress!, maxFrames: 4096) }
            if n == 0 { break }
            var off = 0
            while off < n {
                let bIdx = min(bins - 1, Int(totalFrames / Int64(framesPerBin)))
                let binEndFrame = Int64((bIdx + 1) * framesPerBin)
                let availInBin = bIdx == bins - 1 ? (n - off) : max(1, min(n - off, Int(binEndFrame - totalFrames)))
                var blkPeak: Float = 0
                var blkSq: Float = 0
                buf.withUnsafeBufferPointer { ptr in
                    let p = ptr.baseAddress! + off
                    vDSP_maxmgv(p, 1, &blkPeak, vDSP_Length(availInBin))
                    vDSP_svesq(p, 1, &blkSq, vDSP_Length(availInBin))
                }
                if blkPeak > peaks[bIdx] { peaks[bIdx] = blkPeak }
                sumSq[bIdx] += Double(blkSq)
                counts[bIdx] += availInBin
                off += availInBin
                totalFrames += Int64(availInBin)
            }
        }

        let rmsLevels = (0..<bins).map { i -> Float in
            counts[i] > 0 ? Float(sqrt(sumSq[i] / Double(counts[i]))) : 0.0
        }
        return ForgeWaveformReport(
            inputPath: inputURL.path,
            sampleRate: Int(sampleRate),
            channels: 1,
            durationSeconds: Double(totalFrames) / sampleRate,
            binCount: bins,
            peaks: peaks,
            rmsLevels: rmsLevels,
            wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        )
    }

    /// Streams audio through EQ (`vDSP_biquadD`), compressor, gain, 2-pass BS.1770-4 loudnorm, and `OfflinePeakLimiter`.
    public static func processAudio(
        inputURL: URL,
        outputURL: URL,
        eqSections: [ForgeBiquadSection] = [],
        compressorThresholdDB: Double? = nil,
        compressorRatio: Double = 4.0,
        gainDB: Double = 0.0,
        normalizeLUFS: Double? = nil,
        peakCeilingDBTP: Double = -1.05,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        bitrate: Int = 192_000,
        overwrite: Bool = false
    ) async throws -> ForgeAudioProcessReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let stage = try APFSAutoStage.makeSession(for: outputURL, overwrite: overwrite)
        defer { stage.cleanup() }

        func buildChain() throws -> (StreamingBiquadFilter?, StreamingRMSCompressor?) {
            let eq = eqSections.isEmpty ? nil : try StreamingBiquadFilter(sampleRate: sampleRate, channels: channels, sections: eqSections)
            let comp = try compressorThresholdDB.map {
                try StreamingRMSCompressor(sampleRate: sampleRate, channels: channels, thresholdDB: $0, ratio: compressorRatio)
            }
            return (eq, comp)
        }

        var normGainLinear: Float = powf(10.0, Float(gainDB / 20.0))
        var buf = [Float](repeating: 0, count: 4096 * channels)

        if let targetLUFS = normalizeLUFS {
            let reader1 = try await ForgeStreamingAudioReader(url: inputURL, sampleRate: sampleRate, channels: channels)
            defer { reader1.close() }
            let (eq1, comp1) = try buildChain()
            let meter1 = try LoudnessMeter(sampleRate: sampleRate, channels: channels)
            var g = normGainLinear
            while true {
                let n = try buf.withUnsafeMutableBufferPointer { try reader1.readNextBlock(into: $0.baseAddress!, maxFrames: 4096) }
                if n == 0 { break }
                buf.withUnsafeMutableBufferPointer { ptr in
                    eq1?.processBlock(interleaved: ptr.baseAddress!, frameCount: n)
                    comp1?.processBlock(interleaved: ptr.baseAddress!, frameCount: n)
                    if abs(g - 1.0) > 1e-5 {
                        vDSP_vsmul(ptr.baseAddress!, 1, &g, ptr.baseAddress!, 1, vDSP_Length(n * channels))
                    }
                    meter1.processInterleaved(UnsafeBufferPointer(start: ptr.baseAddress, count: n * channels))
                }
            }
            if meter1.gatedLUFS.isFinite {
                normGainLinear *= powf(10.0, Float((targetLUFS - meter1.gatedLUFS) / 20.0))
            }
        }

        let reader2 = try await ForgeStreamingAudioReader(url: inputURL, sampleRate: sampleRate, channels: channels)
        defer { reader2.close() }
        let (eq2, comp2) = try buildChain()
        let limiter = try OfflinePeakLimiter(sampleRate: sampleRate, channels: channels, ceilingDBTP: peakCeilingDBTP, oversampled4xTruePeak: true)
        let meter2 = try LoudnessMeter(sampleRate: sampleRate, channels: channels)
        let ext = outputURL.pathExtension.lowercased()
        let staged = stage.fileURL("processed.\(ext.isEmpty ? "wav" : ext)")
        let sink = try ForgeStreamingAudioSink(url: staged, sampleRate: Int(sampleRate), channels: channels, bitrate: bitrate)

        let latency = limiter.latencyFrames
        var discardedLatency = 0
        var g = normGainLinear

        do {
            while true {
                let n = try buf.withUnsafeMutableBufferPointer { try reader2.readNextBlock(into: $0.baseAddress!, maxFrames: 4096) }
                if n == 0 { break }
                try buf.withUnsafeMutableBufferPointer { ptr in
                    eq2?.processBlock(interleaved: ptr.baseAddress!, frameCount: n)
                    comp2?.processBlock(interleaved: ptr.baseAddress!, frameCount: n)
                    if abs(g - 1.0) > 1e-5 {
                        vDSP_vsmul(ptr.baseAddress!, 1, &g, ptr.baseAddress!, 1, vDSP_Length(n * channels))
                    }
                    try limiter.processBlock(interleaved: ptr.baseAddress!, frameCount: n)
                }
                let drop = min(n, max(0, latency - discardedLatency))
                discardedLatency += drop
                let valid = n - drop
                if valid > 0 {
                    buf.withUnsafeBufferPointer { ptr in
                        let startPtr = ptr.baseAddress!.advanced(by: drop * channels)
                        meter2.processInterleaved(UnsafeBufferPointer(start: startPtr, count: valid * channels))
                    }
                    try await sink.append(interleavedFrames: buf, frameOffset: drop, frameCount: valid)
                }
            }
            if latency > 0 {
                var pad = [Float](repeating: 0, count: latency * channels)
                try pad.withUnsafeMutableBufferPointer { ptr in
                    try limiter.processBlock(interleaved: ptr.baseAddress!, frameCount: latency)
                }
                let drop = min(latency, max(0, latency - discardedLatency))
                let valid = latency - drop
                if valid > 0 {
                    pad.withUnsafeBufferPointer { ptr in
                        let startPtr = ptr.baseAddress!.advanced(by: drop * channels)
                        meter2.processInterleaved(UnsafeBufferPointer(start: startPtr, count: valid * channels))
                    }
                    try await sink.append(interleavedFrames: pad, frameOffset: drop, frameCount: valid)
                }
            }
            try await sink.finish()
            try stage.commit(stagedFile: staged, overwrite: overwrite)
        } catch {
            sink.cancel()
            throw error
        }

        return ForgeAudioProcessReport(
            outputPath: outputURL.path,
            sampleRate: Int(sampleRate),
            channels: channels,
            durationSeconds: Double(meter2.processedFrames) / sampleRate,
            integratedLUFS: meter2.gatedLUFS.isFinite ? meter2.gatedLUFS : nil,
            truePeakDBTP: meter2.truePeakDBTP.isFinite ? meter2.truePeakDBTP : nil,
            wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        )
    }

    /// Streams input audio in O(4096) blocks with linear fade-in / fade-out envelopes.
    public static func applyFade(
        inputURL: URL,
        outputURL: URL,
        fadeInSeconds: Double = 0,
        fadeOutSeconds: Double = 0,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        bitrate: Int = 192_000,
        overwrite: Bool = false
    ) async throws -> ForgeAudioProcessReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard fadeInSeconds.isFinite, fadeInSeconds >= 0, fadeOutSeconds.isFinite, fadeOutSeconds >= 0 else {
            throw SafariumError.invalidState("fade durations must be finite and >= 0")
        }
        let stage = try APFSAutoStage.makeSession(for: outputURL, overwrite: overwrite)
        defer { stage.cleanup() }
        let reader = try await ForgeStreamingAudioReader(url: inputURL, sampleRate: sampleRate, channels: channels)
        defer { reader.close() }
        let totalFrames = max(0, Int64((reader.durationSeconds * sampleRate).rounded()))
        let fadeInFrames = Int64((fadeInSeconds * sampleRate).rounded())
        let fadeOutFrames = Int64((fadeOutSeconds * sampleRate).rounded())
        let ext = outputURL.pathExtension.lowercased()
        let staged = stage.fileURL("faded.\(ext.isEmpty ? "wav" : ext)")
        let sink = try ForgeStreamingAudioSink(url: staged, sampleRate: Int(sampleRate), channels: channels, bitrate: bitrate)
        let meter = try LoudnessMeter(sampleRate: sampleRate, channels: channels)
        var buf = [Float](repeating: 0, count: 4096 * channels)
        var cursor: Int64 = 0
        do {
            while true {
                let n = try buf.withUnsafeMutableBufferPointer { try reader.readNextBlock(into: $0.baseAddress!, maxFrames: 4096) }
                if n == 0 { break }
                for i in 0..<n {
                    let pos = cursor + Int64(i)
                    var env: Float = 1.0
                    if fadeInFrames > 0 && pos < fadeInFrames {
                        env *= Float(pos) / Float(fadeInFrames)
                    }
                    if fadeOutFrames > 0 && totalFrames > 0 && (totalFrames - pos) <= fadeOutFrames {
                        env *= Float(max(0, totalFrames - pos)) / Float(fadeOutFrames)
                    }
                    if env < 1.0 {
                        for ch in 0..<channels { buf[i * channels + ch] *= env }
                    }
                }
                buf.withUnsafeBufferPointer {
                    meter.processInterleaved(UnsafeBufferPointer(start: $0.baseAddress, count: n * channels))
                }
                try await sink.append(interleavedFrames: buf, frameCount: n)
                cursor += Int64(n)
            }
            try await sink.finish()
            try stage.commit(stagedFile: staged, overwrite: overwrite)
        } catch {
            sink.cancel()
            throw error
        }
        return ForgeAudioProcessReport(
            outputPath: outputURL.path,
            sampleRate: Int(sampleRate),
            channels: channels,
            durationSeconds: Double(meter.processedFrames) / sampleRate,
            integratedLUFS: meter.gatedLUFS.isFinite ? meter.gatedLUFS : nil,
            truePeakDBTP: meter.truePeakDBTP.isFinite ? meter.truePeakDBTP : nil,
            wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        )
    }

    /// Streams input audio with optional `[trimStart, trimEnd]` clamp and trailing silence pad (`padToDurationSeconds`).
    public static func padOrTrim(
        inputURL: URL,
        outputURL: URL,
        trimStartSeconds: Double = 0,
        trimEndSeconds: Double? = nil,
        padToDurationSeconds: Double? = nil,
        sampleRate: Double = 48_000,
        channels: Int = 2,
        bitrate: Int = 192_000,
        overwrite: Bool = false
    ) async throws -> ForgeAudioProcessReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard trimStartSeconds.isFinite, trimStartSeconds >= 0 else {
            throw SafariumError.invalidState("trimStartSeconds must be >= 0")
        }
        if let end = trimEndSeconds {
            guard end.isFinite, end > trimStartSeconds else {
                throw SafariumError.invalidState("trimEndSeconds must be > trimStartSeconds")
            }
        }
        if let padDur = padToDurationSeconds {
            guard padDur.isFinite, padDur > 0 else {
                throw SafariumError.invalidState("padToDurationSeconds must be > 0")
            }
        }
        let stage = try APFSAutoStage.makeSession(for: outputURL, overwrite: overwrite)
        defer { stage.cleanup() }
        let reader = try await ForgeStreamingAudioReader(
            url: inputURL, sampleRate: sampleRate, channels: channels,
            startSeconds: trimStartSeconds, endSeconds: trimEndSeconds
        )
        defer { reader.close() }
        let ext = outputURL.pathExtension.lowercased()
        let staged = stage.fileURL("padtrim.\(ext.isEmpty ? "wav" : ext)")
        let sink = try ForgeStreamingAudioSink(url: staged, sampleRate: Int(sampleRate), channels: channels, bitrate: bitrate)
        let meter = try LoudnessMeter(sampleRate: sampleRate, channels: channels)
        let targetFrames = padToDurationSeconds.map { Int64(($0 * sampleRate).rounded()) }
        var buf = [Float](repeating: 0, count: 4096 * channels)
        var written: Int64 = 0
        do {
            while true {
                if let limit = targetFrames, written >= limit { break }
                let want = targetFrames.map { Int(min(Int64(4096), $0 - written)) } ?? 4096
                let n = try buf.withUnsafeMutableBufferPointer { try reader.readNextBlock(into: $0.baseAddress!, maxFrames: want) }
                if n == 0 { break }
                buf.withUnsafeBufferPointer {
                    meter.processInterleaved(UnsafeBufferPointer(start: $0.baseAddress, count: n * channels))
                }
                try await sink.append(interleavedFrames: buf, frameCount: n)
                written += Int64(n)
            }
            if let limit = targetFrames, written < limit {
                let silence = [Float](repeating: 0, count: 4096 * channels)
                while written < limit {
                    let take = Int(min(Int64(4096), limit - written))
                    silence.withUnsafeBufferPointer {
                        meter.processInterleaved(UnsafeBufferPointer(start: $0.baseAddress, count: take * channels))
                    }
                    try await sink.append(interleavedFrames: silence, frameCount: take)
                    written += Int64(take)
                }
            }
            try await sink.finish()
            try stage.commit(stagedFile: staged, overwrite: overwrite)
        } catch {
            sink.cancel()
            throw error
        }
        return ForgeAudioProcessReport(
            outputPath: outputURL.path,
            sampleRate: Int(sampleRate),
            channels: channels,
            durationSeconds: Double(meter.processedFrames) / sampleRate,
            integratedLUFS: meter.gatedLUFS.isFinite ? meter.gatedLUFS : nil,
            truePeakDBTP: meter.truePeakDBTP.isFinite ? meter.truePeakDBTP : nil,
            wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        )
    }
}
