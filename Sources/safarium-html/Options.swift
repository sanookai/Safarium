import CoreMedia
import Foundation
import SafariumCore

let usage = """
Usage: safarium-html INPUT.html --output FILE.(mp4|mov) --width W --height H --fps N --frames N
                    [--start SECONDS] [--bitrate BPS | --quality 0..1 | --cqf 0..1]
                    [--codec h264|hevc|hevc-10bit|hevc-422-10bit|hevc-444-10bit|hevc-alpha|prores422-proxy|prores422-lt|prores422|prores422-hq|prores4444|prores4444-xq]
                    [--transparent] [--hdr sdr|hdr10|hlg|dv84|apple-log|apple-log2]
                    [--pixel-format bgra|nv12-vimage|nv12-left|p010|p210|p410] [--snapshot-quality fast|sharp]
                    [--low-ram | --high-quality] [--spatial-aq] [--static-hold-probe] [--hash] [--json]
                    [--progress jsonl] [--json-errors]
                    [--subtitles FILE.srt [--subtitle-lang ISO639-2]]
                    (--video-only | --audio WAV [--audio-start SECONDS])

Render one trusted, local .html/.htm page with local assets in a single-pass AVAssetWriter.
BT.709 (or BT.2020 HDR) colorimetry, one CSS pixel per output pixel. Even dimensions (max 8192 per side,
33554432 pixels); positive integer fps/frame count. --bitrate is the average bitrate target
(default 20000000 for h264/hevc). Use .mp4 for h264/hevc/hevc-10bit, .mov for 4:2:2/4:4:4/alpha/ProRes.
Output must be new and its parent directory must exist.

Page time is start + i/fps (default start 0); output PTS is i/fps. Static HTML,
window.__seek(seconds), window.__hf.seek(seconds), and registered window.__timelines
are supported by the Safarium clock. Hooks must finish drawing before they resolve.
Nonzero starts seek directly; previous requestAnimationFrame ticks are not replayed.
Embedded video/documents, custom video hooks and network assets are unsupported.

Choose --video-only for an intentionally silent movie, or --audio for one authoritative
soundtrack. HTML/Web Audio playback, clip edits, gain and effects are never mixed.
Use a prepared PCM RIFF/WAVE (8/16/24/32-bit integer or 32-bit float). AAC-LC uses
AVAudioQuality.max and keeps the source rate and channels. Legacy unlabelled PCM means centered mono or ordered
front L/R stereo. Extensible WAV must declare front center (0x04) or front L/R
(0x03); other/unspecified speaker assignments are rejected. The AAC output layout
is checked before publication. AAC targets 96000 bit/s mono or 160000 bit/s stereo;
the Apple encoder must support that combination (typically 32, 44.1 or 48 kHz).
--audio-start is a position in that WAV, defaulting to --start. For audio, the start
and frames/fps duration must land on PCM sample boundaries. No padding or resampling.
"""

struct WorkerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Options {
    let input: URL, output: URL
    let width: Int, height: Int, fps: Int, frames: Int
    let bitrate: Int?, quality: Double?, cqf: Double?
    let codec: VideoCodec
    let transparent: Bool
    let pixelFormat: SinkPixelFormat
    let colorMastering: ColorMasteringProfile
    let snapshotQuality: SnapshotQuality
    let lowRam: Bool
    let highQuality: Bool
    let spatialAQ: Bool
    let staticHoldProbe: Bool
    let hashFrames: Bool
    let jsonOutput: Bool
    let jsonErrors: Bool
    let progressJSONL: Bool
    let start: Double, audioStart: Double
    let audio: URL?
    let subtitles: URL?
    let subtitleLang: String

    var duration: CMTime { CMTime(value: Int64(frames), timescale: Int32(fps)) }
    func pageTime(_ index: Int) -> Double { start + Double(index) / Double(fps) }

    init(_ args: [String]) throws {
        guard let first = args.first, !first.isEmpty, !first.hasPrefix("-") else {
            throw WorkerError("expected a local INPUT.html; see --help")
        }
        var i = 1, seen = Set<String>()
        var w: Int?, h: Int?, rate: Int?, count: Int?, bps: Int?, qual: Double?, cqfVal: Double?
        var out: String?, wav: String?, srt: String?, srtLang: String?
        var selectedCodec: VideoCodec = .h264
        var isTransparent = false
        var pixFmt: SinkPixelFormat? = nil
        var mastering: ColorMasteringProfile = .sdrBT709
        var snapQual: SnapshotQuality = .fast
        var isLowRam = false
        var isHighQuality = false
        var isSpatialAQ = false
        var isStaticHoldProbe = false
        var isHashFrames = false
        var isJsonOutput = false
        var isJsonErrors = (ProcessInfo.processInfo.environment["SAFARIUM_JSON_ERRORS"] == "1")
        var isProgressJSONL = false
        var t: Double = 0, at: Double?, silent = false
        while i < args.count {
            let flag = args[i]; i += 1
            guard seen.insert(flag).inserted else { throw WorkerError("duplicate option \(flag)") }
            func value() throws -> String {
                guard i < args.count, !args[i].isEmpty, !args[i].hasPrefix("--") else {
                    throw WorkerError("missing value for \(flag)")
                }
                defer { i += 1 }
                return args[i]
            }
            func positive() throws -> Int {
                guard let n = Int32(try value()), n > 0 else { throw WorkerError("\(flag) needs a positive 32-bit integer") }
                return Int(n)
            }
            func seconds() throws -> Double {
                guard let n = Double(try value()), n.isFinite, n >= 0 else {
                    throw WorkerError("\(flag) needs finite, nonnegative seconds")
                }
                return n
            }
            switch flag {
            case "--output": out = try value()
            case "--width": w = try positive()
            case "--height": h = try positive()
            case "--fps": rate = try positive()
            case "--frames": count = try positive()
            case "--bitrate": bps = try positive()
            case "--quality":
                guard let q = Double(try value()), q.isFinite, q > 0, q <= 1.0 else {
                    throw WorkerError("--quality needs a finite number in (0, 1]")
                }
                qual = q
            case "--cqf":
                guard let c = Double(try value()), c.isFinite, c > 0, c <= 1.0 else {
                    throw WorkerError("--cqf needs a finite number in (0, 1]")
                }
                cqfVal = c
            case "--codec":
                let raw = try value()
                guard let c = VideoCodec.parseCLI(raw) else {
                    throw WorkerError("unknown --codec '\(raw)'; expected h264, hevc, hevc-10bit, hevc-422-10bit, hevc-444-10bit, hevc-alpha, or prores*")
                }
                selectedCodec = c
            case "--hdr":
                let raw = try value()
                guard let m = ColorMasteringProfile.parseCLI(raw) else {
                    throw WorkerError("unknown --hdr '\(raw)'; expected sdr, hdr10, hlg, dv84, apple-log, or apple-log2")
                }
                mastering = m
            case "--transparent":
                isTransparent = true
            case "--pixel-format":
                let raw = try value()
                switch raw.lowercased() {
                case "bgra": pixFmt = .bgra
                case "nv12-vimage": pixFmt = .nv12vImage
                case "nv12-left": pixFmt = .nv12Left
                case "p010": pixFmt = .p010
                case "p210": pixFmt = .p210
                case "p410": pixFmt = .p410
                default: throw WorkerError("unknown --pixel-format '\(raw)'; expected bgra, nv12-vimage, nv12-left, p010, p210, or p410")
                }
            case "--low-ram":
                isLowRam = true
            case "--high-quality":
                isHighQuality = true
            case "--spatial-aq":
                isSpatialAQ = true
            case "--static-hold-probe":
                isStaticHoldProbe = true
            case "--hash":
                isHashFrames = true
            case "--json":
                isJsonOutput = true
            case "--json-errors":
                isJsonErrors = true
            case "--progress":
                let raw = try value().lowercased()
                guard raw == "jsonl" else {
                    throw WorkerError("unknown --progress format '\(raw)'; expected jsonl")
                }
                isProgressJSONL = true
            case "--snapshot-quality":
                let raw = try value()
                switch raw.lowercased() {
                case "fast": snapQual = .fast
                case "sharp": snapQual = .sharp
                default: throw WorkerError("unknown --snapshot-quality '\(raw)'; expected fast or sharp")
                }
            case "--subtitles": srt = try value()
            case "--subtitle-lang": srtLang = try value()
            case "--start": t = try seconds()
            case "--audio": wav = try value()
            case "--audio-start": at = try seconds()
            case "--video-only": silent = true
            default: throw WorkerError("unknown option \(flag); see --help")
            }
        }
        guard let out, let w, let h, let rate, let count else {
            throw WorkerError("--output, --width, --height, --fps and --frames are required")
        }
        guard w <= 8192, h <= 8192, w * h <= 33_554_432, w.isMultiple(of: 2), h.isMultiple(of: 2) else {
            throw WorkerError("H.264/HEVC dimensions must be even, at most 8192 per side and 33554432 pixels")
        }
        guard silent != (wav != nil) else { throw WorkerError("choose exactly one of --video-only or --audio WAV") }
        guard at == nil || wav != nil else { throw WorkerError("--audio-start requires --audio WAV") }
        let rateModes = (bps != nil ? 1 : 0) + (qual != nil ? 1 : 0) + (cqfVal != nil ? 1 : 0)
        guard rateModes <= 1 else { throw WorkerError("use only one of --bitrate, --quality, or --cqf") }
        if isTransparent && !selectedCodec.hasAlpha {
            throw WorkerError("--transparent requires an alpha codec (hevc-alpha, prores4444, or prores4444-xq)")
        }
        let resolvedPixFmt = pixFmt ?? ((isTransparent || selectedCodec.hasAlpha) ? .bgra : selectedCodec.defaultPixelFormat)
        if resolvedPixFmt != .bgra && (isTransparent || selectedCodec.hasAlpha) {
            throw WorkerError("--pixel-format \(resolvedPixFmt.rawValue) cannot be used with alpha/transparent output")
        }
        if srtLang != nil && srt == nil {
            throw WorkerError("--subtitle-lang requires --subtitles FILE.srt")
        }
        let dt = 1 / Double(rate), last = t + Double(count - 1) / Double(rate)
        guard (last * 1000).isFinite, last + dt > last else { throw WorkerError("--start is too large for the page clock at this fps") }

        func file(_ path: String, _ extensions: [String]) throws -> URL {
            let u = URL(fileURLWithPath: path)
            guard extensions.contains(u.pathExtension.lowercased()) else {
                throw WorkerError("expected a local \(extensions.map { "." + $0 }.joined(separator: "/")) file: \(path)")
            }
            return u
        }
        func readable(_ url: URL) throws {
            let real = url.resolvingSymlinksInPath()
            guard (try? real.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  FileManager.default.isReadableFile(atPath: real.path) else {
                throw WorkerError("input is not a readable regular file: \(url.path)")
            }
        }
        input = try file(first, ["html", "htm"])
        output = try file(out, selectedCodec.fileExtension == "mp4" ? ["mp4", "mov"] : ["mov"])
        audio = try wav.map { try file($0, ["wav"]) }
        subtitles = try srt.map { try file($0, ["srt"]) }
        if let lang = srtLang {
            let clean = lang.lowercased()
            guard clean.count == 3, clean.allSatisfy({ $0.isASCII && $0.isLetter }) else {
                throw WorkerError("--subtitle-lang must be a 3-letter ISO 639-2 code (e.g. pol, tha, eng): \(lang)")
            }
            subtitleLang = clean
        } else {
            subtitleLang = "pol"
        }
        width = w; height = h; fps = rate; frames = count
        codec = selectedCodec; transparent = isTransparent
        pixelFormat = resolvedPixFmt; colorMastering = mastering
        snapshotQuality = snapQual
        lowRam = isLowRam; highQuality = isHighQuality; spatialAQ = isSpatialAQ
        staticHoldProbe = isStaticHoldProbe
        hashFrames = isHashFrames; jsonOutput = isJsonOutput
        jsonErrors = isJsonErrors; progressJSONL = isProgressJSONL
        quality = qual; cqf = cqfVal
        bitrate = bps ?? (qual == nil && cqfVal == nil && !selectedCodec.isProRes ? 20_000_000 : nil)
        start = t; audioStart = at ?? t
        try readable(input)
        if let audio { try readable(audio) }
        if let subtitles {
            try readable(subtitles)
            let size = (try? subtitles.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard Int64(size) <= SafariumTX3G.maxSRTFileBytes else {
                throw WorkerError("SRT subtitles exceed 16 MiB limit")
            }
        }
        try Staging.requireNew(output)
    }
}
