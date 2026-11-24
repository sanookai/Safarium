import Accelerate
import AudioToolbox
import Foundation

/// Zero-distortion offline true-peak lookahead limiter powered by Apple's `kAudioUnitSubType_PeakLimiter`.
/// Supports 1 or 2 channels and arbitrary block lengths via bounded 4096-frame slicing.
public final class OfflinePeakLimiter {
    private var au: AudioUnit?
    public let sampleRate: Double
    public let channels: Int
    public let ceilingDBTP: Double
    public private(set) var latencyFrames: Int = 0

    private static let maxSliceFrames = 4096
    private var inputL = [Float](repeating: 0, count: maxSliceFrames)
    private var inputR = [Float](repeating: 0, count: maxSliceFrames)
    private var outL = [Float](repeating: 0, count: maxSliceFrames)
    private var outR = [Float](repeating: 0, count: maxSliceFrames)
    private var currentFrames = 0
    private var renderSamplePos: Int64 = 0
    private let preBoost: Float
    private let postTrim: Float
    public let oversampled4xTruePeak: Bool
    private let ceilingLinear: Float
    private let polyTaps: [[Float]]
    private var histOutL = [Float](repeating: 0, count: 11)
    private var histOutR = [Float](repeating: 0, count: 11)
    private var polyInScratch = [Float](repeating: 0, count: maxSliceFrames + 11)
    private var polyOutScratch = [Float](repeating: 0, count: maxSliceFrames)
    private var prev4xGain: Float = 1.0

    public init(
        sampleRate: Double = 48_000,
        channels: Int = 2,
        ceilingDBTP: Double = -1.05,
        oversampled4xTruePeak: Bool = false
    ) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw SafariumError.encode("OfflinePeakLimiter: invalid sampleRate \(sampleRate)")
        }
        guard (1...2).contains(channels) else {
            throw SafariumError.encode("OfflinePeakLimiter supports 1 or 2 channels, got \(channels)")
        }
        self.sampleRate = sampleRate
        self.channels = channels
        self.ceilingDBTP = ceilingDBTP
        self.oversampled4xTruePeak = oversampled4xTruePeak
        self.ceilingLinear = powf(10.0, Float(ceilingDBTP / 20.0))
        self.polyTaps = oversampled4xTruePeak ? Self.build48TapPolyphaseBranches(beta: 7.8) : []

        // AUPeakLimiter limits at 0.0 dBFS; apply +|ceiling| pre-boost and -|ceiling| post-trim.
        let boostDB = max(0.0, -ceilingDBTP)
        self.preBoost = powf(10.0, Float(boostDB / 20.0))
        self.postTrim = powf(10.0, Float(-boostDB / 20.0))

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw SafariumError.encode("kAudioUnitSubType_PeakLimiter not found")
        }
        var unit: AudioUnit?
        var st = AudioComponentInstanceNew(comp, &unit)
        guard st == noErr, let unit else {
            throw SafariumError.encode("AudioComponentInstanceNew failed (\(st))")
        }
        self.au = unit

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        st = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard st == noErr else { throw SafariumError.encode("PeakLimiter set input format failed (\(st))") }
        st = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard st == noErr else { throw SafariumError.encode("PeakLimiter set output format failed (\(st))") }

        var maxFrames = UInt32(Self.maxSliceFrames)
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))
        AudioUnitSetParameter(unit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.002, 0)
        AudioUnitSetParameter(unit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.050, 0)
        AudioUnitSetParameter(unit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0.0, 0)

        var cb = AURenderCallbackStruct(
            inputProc: { (inRefCon, _, _, _, inNumberFrames, ioData) -> OSStatus in
                let me = Unmanaged<OfflinePeakLimiter>.fromOpaque(inRefCon).takeUnretainedValue()
                guard let ioData else { return -50 }
                let abl = UnsafeMutableAudioBufferListPointer(ioData)
                let n = min(Int(inNumberFrames), me.currentFrames)
                if abl.count >= 1, let dst = abl[0].mData {
                    me.inputL.withUnsafeBufferPointer { src in
                        _ = memcpy(dst, src.baseAddress!, n * 4)
                    }
                    abl[0].mDataByteSize = UInt32(n * 4)
                }
                if abl.count >= 2, let dst = abl[1].mData {
                    me.inputR.withUnsafeBufferPointer { src in
                        _ = memcpy(dst, src.baseAddress!, n * 4)
                    }
                    abl[1].mDataByteSize = UInt32(n * 4)
                }
                return noErr
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        st = AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        guard st == noErr else { throw SafariumError.encode("PeakLimiter set render callback failed (\(st))") }

        st = AudioUnitInitialize(unit)
        guard st == noErr else { throw SafariumError.encode("PeakLimiter AudioUnitInitialize failed (\(st))") }

        var latSec: Float64 = 0
        var latSize = UInt32(MemoryLayout<Float64>.size)
        AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latSec, &latSize)
        self.latencyFrames = max(0, Int((latSec * sampleRate).rounded()))
    }

    deinit {
        if let au {
            AudioUnitUninitialize(au)
            AudioComponentInstanceDispose(au)
        }
    }

    /// Processes interleaved Float32 audio in place across arbitrarily sized blocks.
    public func processBlock(interleaved: UnsafeMutablePointer<Float>, frameCount: Int) throws {
        guard frameCount > 0 else { return }
        var offset = 0
        while offset < frameCount {
            let take = min(Self.maxSliceFrames, frameCount - offset)
            try processSlice(interleaved: interleaved.advanced(by: offset * channels), frameCount: take)
            offset += take
        }
    }

    /// Processes a whole interleaved array in place, flushing lookahead latency tail so output stays aligned.
    public func processBuffer(_ samples: inout [Float]) throws {
        let totalFrames = samples.count / channels
        guard totalFrames > 0 else { return }
        if latencyFrames == 0 {
            try samples.withUnsafeMutableBufferPointer { ptr in
                try processBlock(interleaved: ptr.baseAddress!, frameCount: totalFrames)
            }
            return
        }
        var padded = [Float](repeating: 0, count: (totalFrames + latencyFrames) * channels)
        padded.replaceSubrange(0..<(totalFrames * channels), with: samples)
        try padded.withUnsafeMutableBufferPointer { ptr in
            try processBlock(interleaved: ptr.baseAddress!, frameCount: totalFrames + latencyFrames)
        }
        let drop = latencyFrames * channels
        samples.withUnsafeMutableBufferPointer { dst in
            padded.withUnsafeBufferPointer { src in
                _ = memcpy(dst.baseAddress!, src.baseAddress!.advanced(by: drop), totalFrames * channels * 4)
            }
        }
    }

    private func processSlice(interleaved: UnsafeMutablePointer<Float>, frameCount: Int) throws {
        guard let au else { throw SafariumError.invalidState("PeakLimiter deinitialized") }
        currentFrames = frameCount
        if channels == 1 {
            for i in 0..<frameCount { inputL[i] = interleaved[i] * preBoost }
        } else {
            for i in 0..<frameCount {
                inputL[i] = interleaved[i * 2] * preBoost
                inputR[i] = interleaved[i * 2 + 1] * preBoost
            }
        }
        var flags: AudioUnitRenderActionFlags = []
        var ts = AudioTimeStamp()
        ts.mFlags = .sampleTimeValid
        ts.mSampleTime = Float64(renderSamplePos)
        renderSamplePos += Int64(frameCount)

        let bytesPerCh = UInt32(frameCount * 4)
        let status: OSStatus = outL.withUnsafeMutableBufferPointer { lPtr in
            outR.withUnsafeMutableBufferPointer { rPtr in
                let ablMem = AudioBufferList.allocate(maximumBuffers: channels)
                defer { ablMem.unsafeMutablePointer.deallocate() }
                ablMem[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytesPerCh, mData: lPtr.baseAddress)
                if channels == 2 {
                    ablMem[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytesPerCh, mData: rPtr.baseAddress)
                }
                return AudioUnitRender(au, &flags, &ts, 0, UInt32(frameCount), ablMem.unsafeMutablePointer)
            }
        }
        guard status == noErr else {
            throw SafariumError.encode("PeakLimiter AudioUnitRender failed (\(status))")
        }
        if channels == 1 {
            for i in 0..<frameCount { interleaved[i] = outL[i] * postTrim }
        } else {
            for i in 0..<frameCount {
                interleaved[i * 2] = outL[i] * postTrim
                interleaved[i * 2 + 1] = outR[i] * postTrim
            }
        }
        if oversampled4xTruePeak && frameCount > 0 {
            apply4xTruePeakGuard(interleaved: interleaved, frameCount: frameCount)
        }
    }

    private func measureChannel4xPeak(channelData: [Float], count: Int, history: inout [Float]) -> Float {
        var peak: Float = 0
        channelData.withUnsafeBufferPointer { ptr in
            vDSP_maxmgv(ptr.baseAddress!, 1, &peak, vDSP_Length(count))
        }
        peak *= postTrim
        for h in 0..<11 { polyInScratch[h] = history[h] }
        for i in 0..<count { polyInScratch[11 + i] = channelData[i] * postTrim }
        for branch in polyTaps {
            branch.withUnsafeBufferPointer { fPtr in
                polyInScratch.withUnsafeBufferPointer { aPtr in
                    polyOutScratch.withUnsafeMutableBufferPointer { cPtr in
                        vDSP_conv(aPtr.baseAddress!, 1, fPtr.baseAddress!, 1, cPtr.baseAddress!, 1, vDSP_Length(count), 12)
                        var bMax: Float = 0
                        vDSP_maxmgv(cPtr.baseAddress!, 1, &bMax, vDSP_Length(count))
                        if bMax > peak { peak = bMax }
                    }
                }
            }
        }
        if count >= 11 {
            for h in 0..<11 { history[h] = polyInScratch[11 + count - 11 + h] }
        } else {
            for h in 0..<(11 - count) { history[h] = history[h + count] }
            for h in 0..<count { history[11 - count + h] = polyInScratch[11 + h] }
        }
        return peak
    }

    private func apply4xTruePeakGuard(interleaved: UnsafeMutablePointer<Float>, frameCount: Int) {
        var max4x = measureChannel4xPeak(channelData: outL, count: frameCount, history: &histOutL)
        if channels == 2 {
            let maxR = measureChannel4xPeak(channelData: outR, count: frameCount, history: &histOutR)
            if maxR > max4x { max4x = maxR }
        }
        let targetGain: Float = max4x > ceilingLinear ? min(1.0, (ceilingLinear * 0.996) / max4x) : 1.0
        if abs(targetGain - 1.0) > 1e-6 || abs(prev4xGain - 1.0) > 1e-6 {
            let rampN = min(frameCount, 64)
            let g0 = prev4xGain
            let step = (targetGain - g0) / Float(max(1, rampN))
            for i in 0..<frameCount {
                let g = i < rampN ? (g0 + step * Float(i + 1)) : targetGain
                if channels == 1 {
                    interleaved[i] *= g
                } else {
                    interleaved[i * 2] *= g
                    interleaved[i * 2 + 1] *= g
                }
            }
            prev4xGain = targetGain
        }
    }

    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        let halfX = x * 0.5
        for k in 1...25 {
            term *= (halfX / Double(k)) * (halfX / Double(k))
            sum += term
            if term < 1e-16 * sum { break }
        }
        return sum
    }

    private static func build48TapPolyphaseBranches(beta: Double, cutoff: Double = 0.93) -> [[Float]] {
        let halfLen = 5.5
        let i0Beta = besselI0(beta)
        return (1...3).map { p in
            let frac = Double(p) / 4.0
            var taps = [Double](repeating: 0, count: 12)
            var sum = 0.0
            for k in 0..<12 {
                let dist = (Double(k) - 5.0) - frac
                let x = cutoff * dist
                let sincVal = abs(x) < 1e-12 ? 1.0 : sin(.pi * x) / (.pi * x)
                let normPos = dist / (halfLen + 0.5)
                let arg = max(0.0, 1.0 - normPos * normPos)
                let v = sincVal * (besselI0(beta * sqrt(arg)) / i0Beta)
                taps[k] = v
                sum += v
            }
            return taps.map { Float($0 / sum) }
        }
    }
}

/// 128-sample `vDSP_rmsqv` sidechain envelope follower that ducks a background target under active speech.
public final class SidechainDucker {
    public let sampleRate: Double
    public let channels: Int
    public let threshold: Float
    public let duckGainLinear: Float
    public let hopFrames: Int

    private let alphaAtt: Double
    private let alphaRel: Double
    private var env: Double = 0
    private var prevGain: Float = 1.0
    private var rampScratch: [Float]

    public init(
        sampleRate: Double = 48_000,
        channels: Int = 2,
        threshold: Float = 0.015,
        duckGainLinear: Float = 0.31622777,
        attackMs: Double = 10,
        releaseMs: Double = 150,
        hopFrames: Int = 128
    ) throws {
        guard sampleRate.isFinite, sampleRate > 0, (1...2).contains(channels), hopFrames > 0 else {
            throw SafariumError.encode("invalid SidechainDucker configuration")
        }
        self.sampleRate = sampleRate
        self.channels = channels
        self.threshold = threshold
        self.duckGainLinear = duckGainLinear
        self.hopFrames = hopFrames
        let stepSec = Double(hopFrames) / sampleRate
        self.alphaAtt = exp(-stepSec / max(0.0005, attackMs / 1000.0))
        self.alphaRel = exp(-stepSec / max(0.001, releaseMs / 1000.0))
        self.rampScratch = [Float](repeating: 1.0, count: hopFrames)
    }

    public func apply(
        voiceInterleaved: UnsafePointer<Float>,
        targetInterleaved: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }
        var offset = 0
        while offset < frameCount {
            let take = min(hopFrames, frameCount - offset)
            var rms: Float = 0
            vDSP_rmsqv(voiceInterleaved.advanced(by: offset * channels), vDSP_Stride(channels), &rms, vDSP_Length(take))
            if channels == 2 {
                var rmsR: Float = 0
                vDSP_rmsqv(voiceInterleaved.advanced(by: offset * channels + 1), vDSP_Stride(channels), &rmsR, vDSP_Length(take))
                rms = max(rms, rmsR)
            }
            let alpha = Double(rms) > env ? alphaAtt : alphaRel
            env = alpha * env + (1.0 - alpha) * Double(rms)
            let targetDuck: Float = Float(env) > threshold ? duckGainLinear : 1.0
            var startG = prevGain
            var endG = targetDuck
            rampScratch.withUnsafeMutableBufferPointer { rPtr in
                if take == 1 {
                    rPtr[0] = endG
                } else {
                    vDSP_vgen(&startG, &endG, rPtr.baseAddress!, 1, vDSP_Length(take))
                }
                if channels == 1 {
                    vDSP_vmul(targetInterleaved.advanced(by: offset), 1, rPtr.baseAddress!, 1, targetInterleaved.advanced(by: offset), 1, vDSP_Length(take))
                } else {
                    for i in 0..<take {
                        let g = rPtr[i]
                        targetInterleaved[(offset + i) * 2] *= g
                        targetInterleaved[(offset + i) * 2 + 1] *= g
                    }
                }
            }
            prevGain = targetDuck
            offset += take
        }
    }
}
