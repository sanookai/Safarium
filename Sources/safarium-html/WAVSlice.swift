import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// Preflight and pin the source file before doing expensive picture work. No PCM
/// samples are read or allocated until capture() has returned and muxing starts.
struct WAVRange {
    let file: AVAudioFile, rate: Int32, channels: UInt32, start: Int64, count: Int64
    let speakers: WAVSpeakers
    var aacBitrate: Int { channels == 1 ? 96_000 : 160_000 }
    var aacSettings: [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Int(rate),
         AVNumberOfChannelsKey: Int(channels), AVEncoderBitRateKey: aacBitrate,
         AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue]
    }

    init(url: URL, options o: Options) throws {
        speakers = try WAVSpeakers.read(url)
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        let src = file.fileFormat.streamDescription.pointee, fmt = file.processingFormat
        let float = src.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let rates: Set<Int32> = [8000, 11025, 12000, 16000, 22050, 24000, 32000, 44100, 48000, 64000, 88200, 96000]
        guard src.mFormatID == kAudioFormatLinearPCM, src.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              (float ? src.mBitsPerChannel == 32 : [8, 16, 24, 32].contains(src.mBitsPerChannel)),
              (1...2).contains(src.mChannelsPerFrame),
              let rate = Int32(exactly: src.mSampleRate), rates.contains(rate) else {
            throw WorkerError("unsupported WAV: expected mono/stereo integer or float32 PCM at an AAC-LC sample rate (see --help)")
        }
        guard src.mChannelsPerFrame == speakers.rawValue, fmt.sampleRate == src.mSampleRate, fmt.channelCount == src.mChannelsPerFrame,
              fmt.commonFormat == .pcmFormatFloat32, fmt.isInterleaved else {
            throw WorkerError("cannot read interleaved PCM without resampling or changing channels")
        }
        for layout in [file.fileFormat.channelLayout, fmt.channelLayout].compactMap({ $0 }) {
            guard speakers.matches(layout.layout) else { throw WorkerError("decoded WAV layout is not the declared canonical mono/front stereo") }
        }
        self.rate = rate; channels = fmt.channelCount
        guard let first = Int64(exactly: (o.audioStart * Double(rate)).rounded()),
              Double(first) / Double(rate) == o.audioStart else {
            throw WorkerError("audio start does not land on a \(rate) Hz PCM sample boundary")
        }
        // Both factors fit Int32. No Double rounding, skipped sample or tail padding.
        let ticks = Int64(o.frames) * Int64(rate)
        guard ticks.isMultiple(of: Int64(o.fps)) else { throw WorkerError("frames/fps duration does not land on a \(rate) Hz PCM sample boundary") }
        start = first; count = ticks / Int64(o.fps)
        guard first <= file.length, count <= file.length - first else {
            throw WorkerError("incomplete WAV range: need \(count) PCM frames starting at \(first), file contains \(file.length)")
        }
        // The codec's standard rate list is not this Mac's capabilities. Some combinations
        // otherwise pass AVAssetWriter.canApply and fail only *after* the whole picture render.
        guard let aac = AVAudioFormat(settings: aacSettings), let probe = AVAudioConverter(from: fmt, to: aac),
              probe.applicableEncodeBitRates?.contains(NSNumber(value: aacBitrate)) == true else {
            throw WorkerError("Apple AAC-LC cannot encode \(rate) Hz, \(channels) channel(s) at \(aacBitrate) bit/s; no resampling or bitrate fallback")
        }
    }
}

/// The single reusable read buffer holds at most 4096 frames. An outgoing sample
/// owns an independent copy of its bytes until AVAssetWriter consumes it.
final class PCMChunks {
    let source: WAVRange, buffer: AVAudioPCMBuffer
    private(set) var sent: Int64 = 0

    init(_ source: WAVRange) throws {
        self.source = source
        source.file.framePosition = source.start
        guard source.file.framePosition == source.start else { throw WorkerError("could not seek to WAV sample \(source.start)") }
        guard let buf = AVAudioPCMBuffer(pcmFormat: source.file.processingFormat, frameCapacity: 4096) else {
            throw WorkerError("could not allocate PCM chunk")
        }
        buffer = buf
    }

    func next() throws -> CMSampleBuffer {
        let n = Int(min(Int64(buffer.frameCapacity), source.count - sent))
        guard n > 0 else { throw WorkerError("no remaining PCM frames") }
        try source.file.read(into: buffer, frameCount: AVAudioFrameCount(n))
        let list = buffer.audioBufferList.pointee, bytes = n * Int(source.channels) * MemoryLayout<Float>.size
        guard buffer.frameLength == n, source.file.framePosition == source.start + sent + Int64(n),
              list.mNumberBuffers == 1, list.mBuffers.mDataByteSize == bytes, let data = list.mBuffers.mData else {
            throw WorkerError("incomplete WAV read at PCM frame \(source.start + sent)")
        }
        func check(_ status: OSStatus) throws {
            if status != noErr { throw WorkerError("could not construct PCM chunk: OSStatus \(status)") }
        }
        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block))
        guard let block else { throw WorkerError("missing PCM block") }
        try check(CMBlockBufferReplaceDataBytes(with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes))
        var sample: CMSampleBuffer?
        try check(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: buffer.format.formatDescription, sampleCount: n,
            presentationTimeStamp: CMTime(value: sent, timescale: source.rate), packetDescriptions: nil, sampleBufferOut: &sample))
        guard let sample else { throw WorkerError("missing PCM sample buffer") }
        sent += Int64(n)
        return sample
    }
}
