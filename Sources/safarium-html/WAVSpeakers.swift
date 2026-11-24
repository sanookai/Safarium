import AudioToolbox
import Foundation

enum WAVSpeakers: UInt32 {
    case mono = 1, stereo = 2

    /// Read the original RIFF declaration: AVAudioFile may already have
    /// normalized a pair of back speakers to Stereo before exposing its format.
    /// Seek over sample data and ancillary chunks; never buffer their payloads.
    static func read(_ url: URL) throws -> Self {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        func bytes(at offset: UInt64, count: Int) throws -> Data {
            try file.seek(toOffset: offset)
            let d = try file.read(upToCount: count) ?? Data()
            guard d.count == count else { throw WorkerError("truncated PCM RIFF/WAVE header") }
            return d
        }
        func u16(_ d: Data, _ i: Int) -> UInt16 {
            UInt16(d[i]) | UInt16(d[i + 1]) << 8
        }
        func u32(_ d: Data, _ i: Int) -> UInt32 {
            UInt32(u16(d, i)) | UInt32(u16(d, i + 2)) << 16
        }
        let head = try bytes(at: 0, count: 12)
        guard head.prefix(4).elementsEqual("RIFF".utf8), head.suffix(4).elementsEqual("WAVE".utf8) else {
            throw WorkerError("--audio requires a little-endian PCM RIFF/WAVE file")
        }
        let end = UInt64(u32(head, 4)) + 8
        guard end >= 12, end <= length else { throw WorkerError("invalid RIFF/WAVE size") }
        var offset: UInt64 = 12, found: Self?
        while offset < end {
            guard end - offset >= 8 else { throw WorkerError("truncated RIFF/WAVE chunk header") }
            let chunk = try bytes(at: offset, count: 8), size = UInt64(u32(chunk, 4))
            let payload = offset + 8
            guard size <= end - payload else { throw WorkerError("RIFF/WAVE chunk exceeds its declared bounds") }
            switch String(decoding: chunk.prefix(4), as: UTF8.self) {
            case "fmt ":
                guard found == nil, size >= 16 else { throw WorkerError("ambiguous or incomplete WAV fmt chunk") }
                let fmt = try bytes(at: payload, count: Int(min(size, 40)))
                guard let layout = Self(rawValue: UInt32(u16(fmt, 2))) else { throw WorkerError("WAV must be mono or stereo") }
                switch u16(fmt, 0) {
                case 1, 3: break // Conventional unlabelled PCM/IEEE float: mono, or ordered front L/R.
                case 0xfffe: // WAVEFORMATEXTENSIBLE: cbSize, valid bits, speaker mask, subformat GUID.
                    guard size >= 40, u16(fmt, 16) >= 22, 18 + UInt64(u16(fmt, 16)) <= size else {
                        throw WorkerError("truncated WAVE_FORMAT_EXTENSIBLE declaration")
                    }
                    let mask = u32(fmt, 20), canonical: UInt32 = layout == .mono ? 0x04 : 0x03
                    guard mask == canonical else {
                        throw WorkerError(String(format: "unsupported WAV speaker mask 0x%08x; expected 0x%08x", mask, canonical))
                    }
                    // The remaining GUID bytes are identical for KSDATAFORMAT_SUBTYPE_PCM and IEEE_FLOAT.
                    guard [1, 3].contains(u32(fmt, 24)),
                          fmt[28..<40].elementsEqual([0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71]) else {
                        throw WorkerError("unsupported WAVE_FORMAT_EXTENSIBLE subformat; expected PCM or IEEE float")
                    }
                default: throw WorkerError("--audio requires PCM or IEEE float RIFF/WAVE")
                }
                found = layout
            case "chan", "chna":
                throw WorkerError("WAV with additional channel assignments is unsupported")
            default: break
            }
            offset = payload + size
            if offset < end { offset += size % 2 } // RIFF word padding between chunks
        }
        guard let found else { throw WorkerError("missing WAV fmt declaration") }
        return found
    }

    /// Core Audio compares both labels and their order, regardless of whether a
    /// layout is represented by a predefined tag, bitmap or channel descriptions.
    func matches(_ actual: UnsafePointer<AudioChannelLayout>) -> Bool {
        func equivalent(_ canonical: inout AudioChannelLayout) -> Bool {
            withUnsafePointer(to: &canonical) { expected in
                let pair = [expected, actual]
                var equal: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
                let status = pair.withUnsafeBytes {
                    AudioFormatGetProperty(kAudioFormatProperty_AreChannelLayoutsEquivalent, UInt32($0.count),
                                           $0.baseAddress, &size, &equal)
                }
                return status == noErr && equal == 1
            }
        }
        var canonical = AudioChannelLayout()
        canonical.mChannelLayoutTag = self == .mono ? kAudioChannelLayoutTag_MPEG_1_0 : kAudioChannelLayoutTag_MPEG_2_0
        if equivalent(&canonical) { return true }
        // Core Audio distinguishes its generic Mono label from a discrete Center
        // label. MPEG 1.0 is C; both representations are canonical for one channel.
        guard self == .mono else { return false }
        canonical.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelBitmap
        canonical.mChannelBitmap = AudioChannelBitmap(rawValue: 0x04)
        return equivalent(&canonical)
    }
}
