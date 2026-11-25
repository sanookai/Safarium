@preconcurrency import AVFoundation
import CoreMedia
import Darwin
import Foundation

public struct LosslessMuxReport: Codable, Sendable {
    public let inputVideoPath: String
    public let inputAudioPath: String?
    public let inputSubtitlesPath: String?
    public let outputPath: String
    public let audioStartSeconds: Double
    public let durationSeconds: Double
    public let hasAudioTrack: Bool
    public let hasSubtitleTrack: Bool
    public let videoPacketCount: Int
    public let videoPacketsExactMatch: Bool
    public let videoDiffCount: Int
    public let wallMs: Double
}

public struct StitchReport: Codable, Sendable {
    public let segmentCount: Int
    public let stsdUniform: Bool
    public let hasAudioTrack: Bool
    public let hasSubtitleTrack: Bool
    public let durationSeconds: Double
    public let outputVideoPacketCount: Int
    public let outputPath: String
    public let wallMs: Double
}

public enum LosslessSoundtrackMux {
    /// Clones via APFS `clonefile` when same-filesystem APFS allows, falling back cleanly to file copy on ExFAT/EXDEV.
    @discardableResult
    public static func cloneOrCopy(from src: URL, to dst: URL, overwrite: Bool = true) throws -> Bool {
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw SafariumError.invalidState("cloneOrCopy source missing: \(src.path)")
        }
        if FileManager.default.fileExists(atPath: dst.path) {
            if overwrite {
                try FileManager.default.removeItem(at: dst)
            } else {
                throw SafariumError.invalidState("destination already exists: \(dst.path)")
            }
        }
        if Darwin.clonefile(src.path, dst.path, 0) == 0 {
            return true
        }
        let err = errno
        if err == EXDEV || err == ENOTSUP || err == EOPNOTSUPP {
            try FileManager.default.copyItem(at: src, to: dst)
            return false
        }
        throw SafariumError.encode("cloneOrCopy(\(src.lastPathComponent)) failed errno=\(err) (\(String(cString: strerror(err))))")
    }

    package static func bcp47FromISO639_2(_ code: String) -> String {
        switch code.lowercased() {
        case "pol": return "pl"
        case "tha": return "th"
        case "eng": return "en"
        case "jpn": return "ja"
        case "kor": return "ko"
        case "zho", "chi": return "zh"
        default: return code.lowercased()
        }
    }

    package static func validatedSubtitleLanguage(_ code: String) throws -> String {
        let clean = code.lowercased()
        guard clean.count == 3, clean.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            throw SafariumError.encode("--subtitle-lang must be a 3-letter ISO 639-2 code (e.g. pol, tha, eng): \(code)")
        }
        return clean
    }

    package static func makeShiftSampleBuffer(_ sb: CMSampleBuffer, delta: CMTime) throws -> CMSampleBuffer {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(1, count))
        let st1 = CMSampleBufferGetSampleTimingInfoArray(sb, entryCount: timings.count, arrayToFill: &timings, entriesNeededOut: &count)
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
        guard st2 == noErr, let out = copy else {
            throw SafariumError.encode("CMSampleBufferCreateCopyWithNewTiming failed (\(st2))")
        }
        return out
    }

    public static func mux(
        videoURL: URL,
        wavURL: URL? = nil,
        audioStartSeconds: Double = 0,
        audioLang: String? = nil,
        subtitlesURL: URL? = nil,
        subtitleLang: String = "pol",
        outputURL: URL,
        aacBitrate: Int? = nil,
        overwrite: Bool = false
    ) async throws -> LosslessMuxReport {
        try await ClosedGOPStitcher.spliceInternal(
            segments: [videoURL],
            wavURL: wavURL,
            audioStartSeconds: audioStartSeconds,
            audioLang: audioLang,
            subtitlesURL: subtitlesURL,
            subtitleLang: subtitleLang,
            outputURL: outputURL,
            aacBitrate: aacBitrate,
            requireUniformFormatDescription: true,
            overwrite: overwrite
        ).muxReport(
            inputVideoURL: videoURL,
            wavURL: wavURL,
            subtitlesURL: subtitlesURL,
            audioStartSeconds: audioStartSeconds
        )
    }
}

private struct InternalStitchSummary {
    let report: StitchReport
    let referenceProbe: ProbeReport?
    let candidateProbe: ProbeReport?

    func muxReport(inputVideoURL: URL, wavURL: URL?, subtitlesURL: URL?, audioStartSeconds: Double) -> LosslessMuxReport {
        let cmp: PacketCompareResult
        if let ref = referenceProbe, let cand = candidateProbe {
            cmp = PacketProbe.compareVideoPackets(ref: ref, cand: cand)
        } else {
            cmp = PacketCompareResult(exactMatch: false, diffCount: 1, details: ["probe skipped"])
        }
        return LosslessMuxReport(
            inputVideoPath: inputVideoURL.path,
            inputAudioPath: wavURL?.path,
            inputSubtitlesPath: subtitlesURL?.path,
            outputPath: report.outputPath,
            audioStartSeconds: audioStartSeconds,
            durationSeconds: report.durationSeconds,
            hasAudioTrack: report.hasAudioTrack,
            hasSubtitleTrack: report.hasSubtitleTrack,
            videoPacketCount: report.outputVideoPacketCount,
            videoPacketsExactMatch: cmp.exactMatch,
            videoDiffCount: cmp.diffCount,
            wallMs: report.wallMs
        )
    }
}

public enum ClosedGOPStitcher {
    public static func splice(
        segments: [URL],
        wavURL: URL? = nil,
        audioStartSeconds: Double = 0,
        audioLang: String? = nil,
        subtitlesURL: URL? = nil,
        subtitleLang: String = "pol",
        outputURL: URL,
        aacBitrate: Int? = nil,
        requireUniformFormatDescription: Bool = true,
        overwrite: Bool = false
    ) async throws -> StitchReport {
        try await spliceInternal(
            segments: segments,
            wavURL: wavURL,
            audioStartSeconds: audioStartSeconds,
            audioLang: audioLang,
            subtitlesURL: subtitlesURL,
            subtitleLang: subtitleLang,
            outputURL: outputURL,
            aacBitrate: aacBitrate,
            requireUniformFormatDescription: requireUniformFormatDescription,
            overwrite: overwrite
        ).report
    }

    fileprivate static func spliceInternal(
        segments: [URL],
        wavURL: URL?,
        audioStartSeconds: Double,
        audioLang: String?,
        subtitlesURL: URL?,
        subtitleLang: String,
        outputURL: URL,
        aacBitrate: Int?,
        requireUniformFormatDescription: Bool,
        overwrite: Bool
    ) async throws -> InternalStitchSummary {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard !segments.isEmpty else {
            throw SafariumError.invalidState("no input segments supplied")
        }
        guard wavURL != nil || subtitlesURL != nil || segments.count > 1 else {
            throw SafariumError.invalidState("supply --audio, --subtitles, or >= 2 segments to mux/splice")
        }
        guard audioStartSeconds.isFinite, audioStartSeconds >= 0 else {
            throw SafariumError.invalidState("audioStartSeconds must be finite and >= 0")
        }
        let cleanAudioLang: String? = try audioLang.map { try LosslessSoundtrackMux.validatedSubtitleLanguage($0) }
        let cleanLang = try LosslessSoundtrackMux.validatedSubtitleLanguage(subtitleLang)
        try SafeFilePublisher.preflight(outputURL: outputURL, overwrite: overwrite)

        let ext = outputURL.pathExtension.lowercased()
        let fileType: AVFileType = (ext == "mov") ? .mov : .mp4
        guard ext == "mp4" || ext == "mov" else {
            throw SafariumError.invalidState("output must end with .mp4 or .mov: \(outputURL.lastPathComponent)")
        }

        // Probe first segment and validate stsd uniformity across all segments.
        for s in segments {
            guard FileManager.default.fileExists(atPath: s.path) else {
                throw SafariumError.invalidState("segment missing: \(s.path)")
            }
        }
        let firstAsset = AVURLAsset(url: segments[0], options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let firstTrack = try await firstAsset.loadTracks(withMediaType: .video).first else {
            throw SafariumError.invalidState("input has no video track: \(segments[0].path)")
        }
        let firstFmts = try await firstTrack.load(.formatDescriptions)
        guard firstFmts.count == 1, let firstFmt = firstFmts.first else {
            throw SafariumError.invalidState("expected single video format description in \(segments[0].lastPathComponent)")
        }
        let videoDims = CMVideoFormatDescriptionGetDimensions(firstFmt)
        let firstTimeScale = try await firstTrack.load(.naturalTimeScale)

        var stsdUniform = true
        var segMeta: [(url: URL, asset: AVURLAsset, track: AVAssetTrack, duration: CMTime)] = []
        var totalDur = CMTime.zero
        for u in segments {
            let a = AVURLAsset(url: u, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let t = try await a.loadTracks(withMediaType: .video).first else {
                throw SafariumError.invalidState("segment has no video track: \(u.path)")
            }
            let d = try await a.load(.duration)
            guard d.isNumeric, CMTimeCompare(d, .zero) > 0 else {
                throw SafariumError.invalidState("segment has non-positive duration: \(u.path)")
            }
            let fmts = try await t.load(.formatDescriptions)
            if fmts.count != 1 || !CMFormatDescriptionEqual(fmts[0], otherFormatDescription: firstFmt) {
                stsdUniform = false
            }
            segMeta.append((u, a, t, d))
            totalDur = CMTimeAdd(totalDur, d)
        }
        if requireUniformFormatDescription && !stsdUniform {
            throw SafariumError.invalidState("segment video format descriptions (stsd) differ; closed-GOP passthrough requires matching encoder parameters")
        }

        // Validate WAV slice before opening writer.
        var wavFile: AVAudioFile?
        var fileFmt: AVAudioFormat?
        var pcmInterleavedFmt: AVAudioFormat?
        var totalAudioFrames: AVAudioFramePosition = 0
        if let wavURL {
            guard FileManager.default.fileExists(atPath: wavURL.path) else {
                throw SafariumError.invalidState("WAV file missing: \(wavURL.path)")
            }
            let wf = try AVAudioFile(forReading: wavURL)
            let ff = wf.processingFormat
            let ch = Int(ff.channelCount)
            guard (1...2).contains(ch) else {
                throw SafariumError.invalidState("AAC mux supports mono or stereo WAV, got \(ch) channels")
            }
            let fs = ff.sampleRate
            let startFrame = AVAudioFramePosition((audioStartSeconds * fs).rounded())
            let requestedAudioFrames = AVAudioFramePosition((CMTimeGetSeconds(totalDur) * fs).rounded())
            guard startFrame >= 0, startFrame < wf.length else {
                throw SafariumError.invalidState("WAV startFrame \(startFrame) out of bounds [0..<\(wf.length))")
            }
            let available = wf.length - startFrame
            guard available > 0 else {
                throw SafariumError.invalidState("WAV slice empty at startFrame \(startFrame)")
            }
            if audioStartSeconds > 0 {
                guard requestedAudioFrames <= available else {
                    throw SafariumError.invalidState("WAV slice [\(startFrame)..<\(startFrame + requestedAudioFrames)] exceeds length \(wf.length)")
                }
                totalAudioFrames = requestedAudioFrames
            } else {
                totalAudioFrames = min(requestedAudioFrames, available)
            }
            wf.framePosition = startFrame
            wavFile = wf
            fileFmt = ff
            pcmInterleavedFmt = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: fs, channels: ff.channelCount, interleaved: true
            )
        }

        // Validate subtitles before opening writer.
        var subSetup: (CMFormatDescription, [CMSampleBuffer])?
        if let subtitlesURL {
            guard FileManager.default.fileExists(atPath: subtitlesURL.path) else {
                throw SafariumError.invalidState("SRT file missing: \(subtitlesURL.path)")
            }
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

        let staging = try SafeFilePublisher.Staging(beside: outputURL)
        defer { staging.cleanup() }
        let tempURL = staging.fileURL("mux.\(ext)")

        let writer = try AVAssetWriter(url: tempURL, fileType: fileType)
        writer.movieTimeScale = firstTimeScale > 0 ? firstTimeScale : 600
        writer.shouldOptimizeForNetworkUse = true

        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: firstFmt)
        vi.mediaTimeScale = writer.movieTimeScale
        vi.expectsMediaDataInRealTime = false
        guard writer.canAdd(vi) else { throw SafariumError.encode("writer cannot add passthrough video input") }
        writer.add(vi)

        var ai: AVAssetWriterInput?
        if let ff = fileFmt, let pcmFmt = pcmInterleavedFmt {
            let ch = Int(ff.channelCount)
            let defaultRate = ch == 1 ? 96_000 : 160_000
            let aSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Int(ff.sampleRate.rounded()),
                AVNumberOfChannelsKey: ch,
                AVEncoderBitRateKey: aacBitrate ?? defaultRate,
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
            ]
            guard writer.canApply(outputSettings: aSettings, forMediaType: .audio) else {
                throw SafariumError.encode("Apple AAC encoder cannot encode WAV format \(ff.sampleRate) Hz \(ch) ch")
            }
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: aSettings, sourceFormatHint: pcmFmt.formatDescription)
            aIn.expectsMediaDataInRealTime = false
            if let cleanAudioLang {
                aIn.languageCode = cleanAudioLang
                aIn.extendedLanguageTag = LosslessSoundtrackMux.bcp47FromISO639_2(cleanAudioLang)
            }
            guard writer.canAdd(aIn) else { throw SafariumError.encode("writer cannot add AAC audio input") }
            writer.add(aIn)
            ai = aIn
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
            guard writer.canAdd(sIn) else { throw SafariumError.encode("writer cannot add tx3g subtitle input") }
            writer.add(sIn)
            si = sIn
        }

        let referenceProbe: ProbeReport? = segments.count == 1 ? try await PacketProbe.inspect(url: segments[0]) : nil

        guard writer.startWriting() else {
            throw SafariumError.encode("startWriting failed: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)

        let vQueue = DispatchQueue(label: "safarium.mux.video")
        let aQueue = DispatchQueue(label: "safarium.mux.audio")
        let sQueue = DispatchQueue(label: "safarium.mux.subtitle")

        var outVideoPackets = 0
        let readerLock = NSLock()
        var activeReader: AVAssetReader?
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let lock = NSLock()
                var vDone = false
                var aDone = (ai == nil)
                var sDone = (si == nil)
                var failed: Error?
                var completed = false

                func maybeResume() {
                    var errToThrow: Error?
                    var shouldResume = false
                    lock.lock()
                    if !completed {
                        if let err = failed {
                            completed = true
                            errToThrow = err
                            shouldResume = true
                        } else if vDone && aDone && sDone {
                            completed = true
                            shouldResume = true
                        }
                    }
                    lock.unlock()
                    if shouldResume {
                        if let err = errToThrow { cont.resume(throwing: err) }
                        else { cont.resume() }
                    }
                }

                func failAll(_ err: Error) {
                    lock.lock()
                    if failed == nil { failed = err }
                    vDone = true; aDone = true; sDone = true
                    lock.unlock()
                    vi.markAsFinished()
                    ai?.markAsFinished()
                    si?.markAsFinished()
                    readerLock.withLock {
                        activeReader?.cancelReading()
                        activeReader = nil
                    }
                    maybeResume()
                }

                var activeOut: AVAssetReaderTrackOutput?
                var segIdx = 0
                var cursorOffset = CMTime.zero
                var localVideoPackets = 0

                func openNextSegment() throws -> Bool {
                    readerLock.withLock {
                        activeReader?.cancelReading()
                        activeReader = nil
                    }
                    activeOut = nil
                    guard segIdx < segMeta.count else { return false }
                    let seg = segMeta[segIdx]
                    if segIdx > 0 {
                        cursorOffset = CMTimeAdd(cursorOffset, segMeta[segIdx - 1].duration)
                    }
                    let r = try AVAssetReader(asset: seg.asset)
                    let out = AVAssetReaderTrackOutput(track: seg.track, outputSettings: nil)
                    out.alwaysCopiesSampleData = false
                    r.add(out)
                    guard r.startReading() else {
                        throw SafariumError.encode("segment reader failed (\(seg.url.lastPathComponent)): \(r.error?.localizedDescription ?? "?")")
                    }
                    readerLock.withLock { activeReader = r }
                    activeOut = out
                    segIdx += 1
                    return true
                }

                vi.requestMediaDataWhenReady(on: vQueue) {
                    while vi.isReadyForMoreMediaData {
                        if lock.withLock({ failed != nil || vDone }) { break }
                        var shouldBreak = false
                        autoreleasepool {
                            do {
                                if activeOut == nil {
                                    if try !openNextSegment() {
                                        vi.markAsFinished()
                                        lock.withLock {
                                            outVideoPackets = localVideoPackets
                                            vDone = true
                                        }
                                        maybeResume()
                                        shouldBreak = true
                                        return
                                    }
                                }
                                if let sb = activeOut?.copyNextSampleBuffer() {
                                    if sb.numSamples == 0 { return }
                                    let shifted = (CMTimeCompare(cursorOffset, .zero) == 0)
                                        ? sb
                                        : try LosslessSoundtrackMux.makeShiftSampleBuffer(sb, delta: cursorOffset)
                                    guard vi.append(shifted) else {
                                        failAll(SafariumError.encode("mux video append failed: \(writer.error?.localizedDescription ?? "?")"))
                                        shouldBreak = true
                                        return
                                    }
                                    localVideoPackets += 1
                                } else {
                                    let readerErr: String? = readerLock.withLock {
                                        activeReader?.status == .failed ? (activeReader?.error?.localizedDescription ?? "?") : nil
                                    }
                                    if let readerErr {
                                        throw SafariumError.encode("segment read failed: \(readerErr)")
                                    }
                                    activeOut = nil
                                }
                            } catch {
                                failAll(error)
                                shouldBreak = true
                            }
                        }
                        if shouldBreak { break }
                    }
                }

                if let ai, let wavFile, let ff = fileFmt, let pcmFmt = pcmInterleavedFmt {
                    let readBuf = AVAudioPCMBuffer(pcmFormat: ff, frameCapacity: 4096)!
                    let chCount = Int(ff.channelCount)
                    var interleaved = [Float](repeating: 0, count: 4096 * chCount)
                    var sentFrames: AVAudioFramePosition = 0
                    ai.requestMediaDataWhenReady(on: aQueue) {
                        while ai.isReadyForMoreMediaData {
                            if lock.withLock({ failed != nil || aDone }) { break }
                            let rem = totalAudioFrames - sentFrames
                            if rem <= 0 {
                                ai.markAsFinished()
                                lock.withLock { aDone = true }
                                maybeResume()
                                break
                            }
                            let take = AVAudioFrameCount(min(4096, Int(rem)))
                            var shouldBreak = false
                            autoreleasepool {
                                do {
                                    try wavFile.read(into: readBuf, frameCount: take)
                                    let got = Int(readBuf.frameLength)
                                    if got == 0 {
                                        ai.markAsFinished()
                                        lock.withLock { aDone = true }
                                        maybeResume()
                                        shouldBreak = true
                                        return
                                    }
                                    if let chData = readBuf.floatChannelData {
                                        if chCount == 1 {
                                            interleaved.withUnsafeMutableBufferPointer { dst in
                                                _ = memcpy(dst.baseAddress!, chData[0], got * 4)
                                            }
                                        } else {
                                            for f in 0..<got {
                                                for c in 0..<chCount {
                                                    interleaved[f * chCount + c] = chData[c][f]
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
                                    let repStatus = interleaved.withUnsafeBufferPointer { p in
                                        CMBlockBufferReplaceDataBytes(with: p.baseAddress!, blockBuffer: blockBuf, offsetIntoDestination: 0, dataLength: bytes)
                                    }
                                    guard repStatus == noErr else {
                                        throw SafariumError.encode("CMBlockBufferReplaceDataBytes failed (\(repStatus))")
                                    }
                                    var sb: CMSampleBuffer?
                                    let sbStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                                        allocator: kCFAllocatorDefault, dataBuffer: blockBuf, formatDescription: pcmFmt.formatDescription,
                                        sampleCount: got, presentationTimeStamp: CMTime(value: Int64(sentFrames), timescale: Int32(ff.sampleRate.rounded())),
                                        packetDescriptions: nil, sampleBufferOut: &sb
                                    )
                                    guard sbStatus == noErr, let audioSample = sb, ai.append(audioSample) else {
                                        failAll(SafariumError.encode("mux audio append failed: \(writer.error?.localizedDescription ?? "?")"))
                                        shouldBreak = true
                                        return
                                    }
                                    sentFrames += AVAudioFramePosition(got)
                                } catch {
                                    failAll(error)
                                    shouldBreak = true
                                }
                            }
                            if shouldBreak { break }
                        }
                    }
                }

                if let si {
                    var subIdx = 0
                    si.requestMediaDataWhenReady(on: sQueue) {
                        while si.isReadyForMoreMediaData {
                            if lock.withLock({ failed != nil || sDone }) { break }
                            if subIdx >= subSamples.count {
                                si.markAsFinished()
                                lock.withLock { sDone = true }
                                maybeResume()
                                break
                            }
                            guard si.append(subSamples[subIdx]) else {
                                failAll(SafariumError.encode("mux subtitle append failed: \(writer.error?.localizedDescription ?? "?")"))
                                break
                            }
                            subIdx += 1
                        }
                    }
                }
            }
        } catch {
            readerLock.withLock {
                activeReader?.cancelReading()
                activeReader = nil
            }
            writer.cancelWriting()
            throw error
        }

        writer.endSession(atSourceTime: totalDur)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw SafariumError.encode("mux finishWriting failed: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")")
        }

        let candProbe: ProbeReport? = segments.count == 1 ? try await PacketProbe.inspect(url: tempURL) : nil
        try SafeFilePublisher.publish(tempURL: tempURL, to: outputURL, overwrite: overwrite)

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let report = StitchReport(
            segmentCount: segments.count,
            stsdUniform: stsdUniform,
            hasAudioTrack: ai != nil,
            hasSubtitleTrack: si != nil,
            durationSeconds: CMTimeGetSeconds(totalDur),
            outputVideoPacketCount: outVideoPackets,
            outputPath: outputURL.path,
            wallMs: elapsedMs
        )
        return InternalStitchSummary(report: report, referenceProbe: referenceProbe, candidateProbe: candProbe)
    }
}
