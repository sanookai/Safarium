import Darwin
import Foundation
import SafariumCore

private struct CLIUsageError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}

private enum CLIDone: Error {
    case help(String)
}

private let globalHelp = """
Usage:
  safarium-render <command> [options]   (via queue) or safarium-media <command> [options]

Commands:
  extract-audio  INPUT --output OUT.(wav|m4a) [--start S] [--duration S] [--sample-rate N] [--channels 1|2] [--bitrate BPS] [--overwrite]
  mix-audio      --track PATH[:gainDB[:startSec[:loop]]] ... --output OUT.(wav|m4a) [--duration S] [--sample-rate N] [--channels 1|2] [--bitrate BPS] [--normalize-lufs DB] [--peak-ceiling DB] [--bit-depth 16|24] [--overwrite]
  extract-frames INPUT (--times T1,T2 | --every SEC | --fps N --gray-raw OUT.raw) [--out-dir DIR] [--width W] [--height H] [--format jpg|png] [--overwrite]
  gif            INPUT --output OUT.gif [--fps N] [--max-width N] [--start S] [--duration S] [--loop N] [--overwrite]
  cutout         INPUT --output OUT.(png|mov) [--codec hevc-alpha|prores4444] [--fps N] [--max-frames N] [--allow-empty-mask] [--overwrite]
  hybrid         [--html FILE.html] [--video FILE.mp4] --output OUT.(mp4|mov) --width W --height H --fps N --frames N [--codec h264|hevc|hevc-alpha|prores422|prores4444] [--bitrate BPS] [--quality Q] [--start S] [--overwrite]
  mux            VIDEO --output OUT.(mp4|mov) [--audio WAV [--audio-start S] [--audio-lang ISO639-2]] [--subtitles FILE.srt [--subtitle-lang ISO639-2]] [--bitrate BPS] [--overwrite]
  probe          INPUT [--include-audio-packets]
  qa             INPUT [--contact-sheet OUT.jpg] [--scene-threshold FLOAT] [--silence-threshold-db DB] [--overwrite]
  splice         --segment SEG1.mp4 [--segment SEG2.mp4 ...] --output OUT.(mp4|mov) [--audio WAV [--audio-start S] [--audio-lang ISO639-2]] [--subtitles FILE.srt [--subtitle-lang ISO639-2]] [--bitrate BPS] [--allow-mixed-stsd] [--overwrite]
  warm-worker    --socket PATH

Run `safarium-media <command> --help` for subcommand details.
"""

private let subcommandHelp: [String: String] = [
    "extract-audio": """
    Usage: safarium-media extract-audio INPUT --output OUT.(wav|m4a) [options]
      --output PATH         Output .wav or .m4a path (required)
      --start SECONDS       Start offset in seconds (default: 0)
      --duration SECONDS    Duration limit in seconds
      --sample-rate HZ      Target sample rate (default: 48000)
      --channels 1|2        Channel count (default: 2)
      --bitrate BPS         AAC bitrate for .m4a output (default: 192000)
      --overwrite           Replace existing output file
    """,
    "mix-audio": """
    Usage: safarium-media mix-audio --track SPEC [--track SPEC ...] --output OUT.(wav|m4a) [options]
      --track SPEC          Track spec: PATH[:gainDB[:startSec[:loop]]] (repeatable, required)
                            Example: --track bed.m4a:-12:0:loop --track voice.wav:0:1.5
      --output PATH         Output .wav or .m4a path (required)
      --duration SECONDS    Output duration in seconds (default: max end of non-looped tracks)
      --sample-rate HZ      Target sample rate (default: 48000)
      --channels 1|2        Channel count (default: 2)
      --bitrate BPS         AAC bitrate for .m4a output (default: 192000)
      --normalize-lufs DB   Target ITU-R BS.1770 integrated loudness in [-60, 0] LUFS
      --peak-ceiling DB     True-peak limiter ceiling in [-24, 0] dBTP (default: -1.05)
      --bit-depth 16|24     WAV PCM bit depth (default: 16)
      --overwrite           Replace existing output file
    """,
    "extract-frames": """
    Usage: safarium-media extract-frames INPUT (--times T1,T2,... | --every SEC | --fps N --gray-raw OUT.raw) [options]
      --times CSV           Comma-separated timestamps in seconds -> f0001.(jpg|png), ...
      --every SECONDS       Extract mid-interval frame every N seconds -> f0001.(jpg|png), ...
      --fps N               Sample frames at N fps for --gray-raw output
      --gray-raw PATH       Write tightly packed uint8 Plane-0 grayscale stream (requires --fps, --width, --height)
      --out-dir DIR         Output directory for --times / --every image files
      --width PX            Target width (even positive integer; optional for --times/--every)
      --height PX           Target height (even positive integer; optional for --times/--every)
      --format jpg|png      Output image format for --times/--every (default: jpg)
      --quality 0..1        JPEG quality in (0, 1] (default: 0.90 for --times, 0.88 for --every)
      --overwrite           Replace existing output files
    """,
    "gif": """
    Usage: safarium-media gif INPUT --output OUT.gif [options]
      --output PATH         Output .gif path (required)
      --fps N               Frames per second in 1...60 (default: 15)
      --max-width PX        Scale down proportionally if wider than max-width
      --start SECONDS       Start offset in seconds (default: 0)
      --duration SECONDS    Duration limit in seconds
      --loop N              GIF loop count (0 = infinite loop, default: 0)
      --overwrite           Replace existing output file
    """,
    "cutout": """
    Usage: safarium-media cutout INPUT --output OUT.(png|mov) [options]
      --output PATH         Output .png (image cutout) or .mov (video cutout, required)
      --codec NAME          Video alpha codec: hevc-alpha (default) or prores4444
      --fps N               Override output FPS for video cutout
      --max-frames N        Maximum frames to process for video cutout
      --allow-empty-mask    Produce transparent frame instead of failing when no subject found
      --overwrite           Replace existing output file
    """,
    "hybrid": """
    Usage: safarium-media hybrid [options]
      --html PATH           HTML overlay/scene file
      --video PATH          Background video file (MP4/MOV)
      --output PATH         Output .mp4 or .mov matching codec extension (required)
      --width PX            Output width (positive even integer, required)
      --height PX           Output height (positive even integer, required)
      --fps N               Frames per second (required)
      --frames N            Total frame count (required)
      --codec NAME          h264 (default), hevc, hevc-alpha, prores422, prores4444
      --bitrate BPS         Target bitrate for H.264/HEVC (default: 20000000)
      --quality 0..1        Optional quality mode (0.0...1.0)
      --start SECONDS       Starting timeline offset for HTML/overlay (default: 0)
      --effect NAME         Optional GPU effect: paper-cutout | marker-texture
      --split-metalfx       Scale background at 0.5x via MTLFXSpatialScaler and composite 1x overlay
      --overwrite           Replace existing output file
    """,
    "mux": """
    Usage: safarium-media mux VIDEO --output OUT.(mp4|mov) [options]
      --output PATH         Output .mp4 or .mov path (required)
      --audio PATH          Soundtrack WAV file (mono or stereo)
      --audio-start SECONDS Start offset inside source WAV (default: 0)
      --audio-lang CODE     3-letter ISO 639-2 audio language code (optional, e.g. pol)
      --subtitles PATH      UTF-8 .srt subtitle file (muxed as tx3g)
      --subtitle-lang CODE  3-letter ISO 639-2 subtitle language code (default: pol)
      --bitrate BPS         AAC audio bitrate in bits/sec
      --overwrite           Replace existing output file
    """,
    "probe": """
    Usage: safarium-media probe INPUT [--include-audio-packets]
      --include-audio-packets  Include per-packet SHA-256 and timing entries for audio tracks
    """,
    "qa": """
    Usage: safarium-media qa INPUT [--contact-sheet OUT.jpg] [options]
      --contact-sheet PATH         Write optional 6x1 JPEG QA contact sheet strip
      --scene-threshold FLOAT      Normalized luma MAD threshold in (0, 1] for scene_cut (default: 0.20)
      --silence-threshold-db DB    Silence floor in [-120, 0] dBFS for silencedetect (default: -50.0)
      --overwrite                  Replace existing contact sheet file
    """,
    "splice": """
    Usage: safarium-media splice --segment PATH [--segment PATH ...] --output OUT.(mp4|mov) [options]
      --segment PATH        Ordered closed-GOP segment file (repeatable, positional paths also accepted)
      --output PATH         Output .mp4 or .mov path (required)
      --audio PATH          Optional soundtrack WAV file
      --audio-start SECONDS Start offset inside source WAV (default: 0)
      --audio-lang CODE     3-letter ISO 639-2 audio language code (optional, e.g. pol)
      --subtitles PATH      Optional UTF-8 .srt subtitle file
      --subtitle-lang CODE  3-letter ISO 639-2 subtitle language code (default: pol)
      --bitrate BPS         AAC audio bitrate in bits/sec
      --allow-mixed-stsd    Allow segments with differing stsd descriptions
      --overwrite           Replace existing output file
    """,
    "warm-worker": """
    Usage: safarium-media warm-worker --socket PATH
      --socket PATH         UNIX domain socket path (enforces 0700 dir + 0600 socket + SCM_RIGHTS mmap ring)
    """,
]

private func nextValue(_ args: [String], index: inout Int, flag: String) throws -> String {
    let next = index + 1
    guard next < args.count else {
        throw CLIUsageError("missing value for \(flag)")
    }
    index = next
    return args[next]
}

private func parseDouble(_ raw: String, flag: String) throws -> Double {
    guard let v = Double(raw), v.isFinite else {
        throw CLIUsageError("invalid number for \(flag): \(raw)")
    }
    return v
}

private func parseInt(_ raw: String, flag: String) throws -> Int {
    guard let v = Int(raw) else {
        throw CLIUsageError("invalid integer for \(flag): \(raw)")
    }
    return v
}

private func parseMixTrack(_ spec: String) throws -> AudioMixTrack {
    let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
    guard !parts.isEmpty, (1...4).contains(parts.count) else {
        throw CLIUsageError("invalid --track spec (expected PATH[:gainDB[:startSec[:loop]]]): \(spec)")
    }
    let path = String(parts[0])
    guard !path.isEmpty else {
        throw CLIUsageError("missing track path in --track spec: \(spec)")
    }
    var gainDB = 0.0
    if parts.count >= 2 && !parts[1].isEmpty {
        gainDB = try parseDouble(String(parts[1]), flag: "--track gainDB")
    }
    var startSec = 0.0
    if parts.count >= 3 && !parts[2].isEmpty {
        startSec = try parseDouble(String(parts[2]), flag: "--track startSec")
        guard startSec >= 0 else {
            throw CLIUsageError("--track startSec must be >= 0: \(parts[2])")
        }
    }
    var loop = false
    if parts.count == 4 && !parts[3].isEmpty {
        switch parts[3].lowercased() {
        case "loop", "true", "1", "yes": loop = true
        case "false", "0", "no": loop = false
        default:
            throw CLIUsageError("invalid --track loop value (expected loop|true|false|1|0): \(parts[3])")
        }
    }
    return AudioMixTrack(url: URL(fileURLWithPath: path), gainDB: gainDB, startSeconds: startSec, loop: loop)
}

private func encodeJSON<T: Encodable>(_ report: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    encoder.nonConformingFloatEncodingStrategy = .convertToString(
        positiveInfinity: "+inf",
        negativeInfinity: "-inf",
        nan: "nan"
    )
    var data = try encoder.encode(report)
    data.append(0x0A)
    return data
}

private func runExtractAudio(_ args: [String]) async throws -> Data {
    if args.contains("--help") || args.contains("-h") {
        throw CLIDone.help(subcommandHelp["extract-audio"]!)
    }
    var inputPath: String?
    var outputPath: String?
    var start = 0.0
    var duration: Double?
    var sampleRate = 48_000.0
    var channels = 2
    var bitrate = 192_000
    var overwrite = false

    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--output", "-o":
            outputPath = try nextValue(args, index: &i, flag: a)
        case "--start":
            start = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--duration":
            duration = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--sample-rate":
            sampleRate = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--channels":
            channels = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--bitrate":
            bitrate = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--overwrite":
            overwrite = true
        default:
            if a.hasPrefix("-") {
                throw CLIUsageError("unknown flag for extract-audio: \(a)")
            }
            guard inputPath == nil else {
                throw CLIUsageError("unexpected extra positional argument: \(a)")
            }
            inputPath = a
        }
        i += 1
    }

    guard let inputPath else { throw CLIUsageError("extract-audio requires an INPUT path") }
    guard let outputPath else { throw CLIUsageError("extract-audio requires --output") }
    guard sampleRate > 0 else { throw CLIUsageError("--sample-rate must be > 0") }
    guard (1...2).contains(channels) else { throw CLIUsageError("--channels must be 1 or 2") }
    guard bitrate > 0 else { throw CLIUsageError("--bitrate must be > 0") }
    guard start >= 0 else { throw CLIUsageError("--start must be >= 0") }
    if let d = duration, d <= 0 { throw CLIUsageError("--duration must be > 0") }

    let report = try await AudioExtractor.extract(
        from: URL(fileURLWithPath: inputPath),
        to: URL(fileURLWithPath: outputPath),
        startSeconds: start,
        durationSeconds: duration,
        sampleRate: sampleRate,
        channels: channels,
        bitrate: bitrate,
        overwrite: overwrite
    )
    return try encodeJSON(report)
}

private func runMixAudio(_ args: [String]) async throws -> Data {
    if args.contains("--help") || args.contains("-h") {
        throw CLIDone.help(subcommandHelp["mix-audio"]!)
    }
    var tracks: [AudioMixTrack] = []
    var outputPath: String?
    var duration: Double?
    var sampleRate = 48_000.0
    var channels = 2
    var bitrate = 192_000
    var normalizeLUFS: Double?
    var peakCeilingDBTP = -1.05
    var wavBitDepth = 16
    var overwrite = false

    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--track":
            tracks.append(try parseMixTrack(try nextValue(args, index: &i, flag: a)))
        case "--output", "-o":
            outputPath = try nextValue(args, index: &i, flag: a)
        case "--duration":
            duration = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--sample-rate":
            sampleRate = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--channels":
            channels = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--bitrate":
            bitrate = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--normalize-lufs":
            normalizeLUFS = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--peak-ceiling":
            peakCeilingDBTP = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--bit-depth":
            wavBitDepth = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--overwrite":
            overwrite = true
        default:
            throw CLIUsageError("unknown argument for mix-audio: \(a)")
        }
        i += 1
    }

    guard !tracks.isEmpty else { throw CLIUsageError("mix-audio requires at least one --track") }
    guard let outputPath else { throw CLIUsageError("mix-audio requires --output") }
    guard sampleRate > 0 else { throw CLIUsageError("--sample-rate must be > 0") }
    guard (1...2).contains(channels) else { throw CLIUsageError("--channels must be 1 or 2") }
    guard bitrate > 0 else { throw CLIUsageError("--bitrate must be > 0") }
    if let d = duration, d <= 0 { throw CLIUsageError("--duration must be > 0") }
    if let n = normalizeLUFS, !(-60.0...0.0).contains(n) {
        throw CLIUsageError("--normalize-lufs must be between -60 and 0")
    }
    guard (-24.0...0.0).contains(peakCeilingDBTP) else {
        throw CLIUsageError("--peak-ceiling must be between -24 and 0")
    }
    guard wavBitDepth == 16 || wavBitDepth == 24 else {
        throw CLIUsageError("--bit-depth must be 16 or 24")
    }

    let report = try await AudioMixer.mix(
        tracks: tracks,
        to: URL(fileURLWithPath: outputPath),
        durationSeconds: duration,
        sampleRate: sampleRate,
        channels: channels,
        bitrate: bitrate,
        normalizeLUFS: normalizeLUFS,
        peakCeilingDBTP: peakCeilingDBTP,
        wavBitDepth: wavBitDepth,
        overwrite: overwrite
    )
    return try encodeJSON(report)
}

private func runExtractFrames(_ args: [String]) async throws -> Data {
    if args.contains("--help") || args.contains("-h") {
        throw CLIDone.help(subcommandHelp["extract-frames"]! + "\n")
    }
    var inputPath: String?
    var timesCSV: String?
    var everySec: Double?
    var fps: Double?
    var grayRawPath: String?
    var outDirPath: String?
    var width: Int?
    var height: Int?
    var format = "jpg"
    var quality: Double?
    var overwrite = false

    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--times": timesCSV = try nextValue(args, index: &i, flag: a)
        case "--every": everySec = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--fps": fps = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--gray-raw": grayRawPath = try nextValue(args, index: &i, flag: a)
        case "--out-dir": outDirPath = try nextValue(args, index: &i, flag: a)
        case "--width": width = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--height": height = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--format": format = try nextValue(args, index: &i, flag: a).lowercased()
        case "--quality": quality = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--overwrite": overwrite = true
        default:
            if a.hasPrefix("-") {
                throw CLIUsageError("unknown argument for extract-frames: \(a)")
            }
            guard inputPath == nil else {
                throw CLIUsageError("unexpected extra positional argument for extract-frames: \(a)")
            }
            inputPath = a
        }
        i += 1
    }

    guard let inputPath else { throw CLIUsageError("extract-frames requires an INPUT path") }
    if let q = quality, !(q > 0 && q <= 1.0) {
        throw CLIUsageError("--quality must be in (0, 1]")
    }
    let modeCount = (timesCSV != nil ? 1 : 0) + (everySec != nil ? 1 : 0) + (fps != nil ? 1 : 0)
    guard modeCount == 1 else {
        throw CLIUsageError("extract-frames requires exactly one of --times, --every, or --fps")
    }

    let inURL = URL(fileURLWithPath: inputPath)
    if let fps {
        guard let grayRawPath else {
            throw CLIUsageError("extract-frames --fps requires --gray-raw OUT.raw")
        }
        guard let width, let height else {
            throw CLIUsageError("extract-frames --gray-raw requires --width W and --height H")
        }
        let report = try await FrameExtractor.extractGrayRaw(
            url: inURL,
            fps: fps,
            width: width,
            height: height,
            outputURL: URL(fileURLWithPath: grayRawPath),
            overwrite: overwrite
        )
        return try encodeJSON(report)
    }

    guard grayRawPath == nil else {
        throw CLIUsageError("--gray-raw can only be combined with --fps")
    }
    guard let outDirPath else {
        throw CLIUsageError("extract-frames --times / --every requires --out-dir DIR")
    }
    let outDir = URL(fileURLWithPath: outDirPath)
    if let everySec {
        let report = try await FrameExtractor.extractEvery(
            url: inURL,
            everySeconds: everySec,
            outDir: outDir,
            width: width,
            height: height,
            format: format,
            jpegQuality: quality ?? 0.88,
            overwrite: overwrite
        )
        return try encodeJSON(report)
    }

    let rawParts = (timesCSV ?? "").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !rawParts.isEmpty else {
        throw CLIUsageError("--times requires at least one numeric timestamp")
    }
    var parsedTimes: [Double] = []
    for tok in rawParts {
        let t = try parseDouble(tok, flag: "--times")
        guard t >= 0 else { throw CLIUsageError("--times entries must be >= 0 (got \(tok))") }
        parsedTimes.append(t)
    }
    let report = try await FrameExtractor.extractAtTimestamps(
        url: inURL,
        times: parsedTimes,
        outDir: outDir,
        width: width,
        height: height,
        format: format,
        jpegQuality: quality ?? 0.90,
        overwrite: overwrite
    )
    return try encodeJSON(report)
}

private func runGIF(_ args: [String]) async throws -> Data {
    if args.contains("--help") || args.contains("-h") {
        throw CLIDone.help(subcommandHelp["gif"]!)
    }
    var inputPath: String?
    var outputPath: String?
    var fps = 15
    var maxWidth: Int?
    var start = 0.0
    var duration: Double?
    var loopCount = 0
    var overwrite = false

    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--output", "-o":
            outputPath = try nextValue(args, index: &i, flag: a)
        case "--fps":
            fps = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--max-width":
            maxWidth = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--start":
            start = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--duration":
            duration = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--loop":
            loopCount = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--overwrite":
            overwrite = true
        default:
            if a.hasPrefix("-") {
                throw CLIUsageError("unknown flag for gif: \(a)")
            }
            guard inputPath == nil else {
                throw CLIUsageError("unexpected extra positional argument: \(a)")
            }
            inputPath = a
        }
        i += 1
    }

    guard let inputPath else { throw CLIUsageError("gif requires an INPUT path") }
    guard let outputPath else { throw CLIUsageError("gif requires --output") }
    guard (1...60).contains(fps) else { throw CLIUsageError("gif --fps must be in 1...60") }
    if let mw = maxWidth, !(1...8192).contains(mw) { throw CLIUsageError("gif --max-width must be in 1...8192") }
    guard start >= 0 else { throw CLIUsageError("gif --start must be >= 0") }
    if let d = duration, d <= 0 { throw CLIUsageError("gif --duration must be > 0") }
    guard loopCount >= 0 else { throw CLIUsageError("gif --loop must be >= 0") }

    let report = try await GIFWriter.convert(
        from: URL(fileURLWithPath: inputPath),
        to: URL(fileURLWithPath: outputPath),
        fps: fps,
        maxWidth: maxWidth,
        startSeconds: start,
        durationSeconds: duration,
        loopCount: loopCount,
        overwrite: overwrite
    )
    return try encodeJSON(report)
}

private func runCutout(_ args: [String]) async throws -> Data {
    if args.contains("--help") || args.contains("-h") {
        throw CLIDone.help(subcommandHelp["cutout"]!)
    }
    var inputPath: String?
    var outputPath: String?
    var codecName: String?
    var fps: Int?
    var maxFrames: Int?
    var allowEmptyMask = false
    var overwrite = false

    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--output", "-o":
            outputPath = try nextValue(args, index: &i, flag: a)
        case "--codec":
            codecName = try nextValue(args, index: &i, flag: a)
        case "--fps":
            fps = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--max-frames":
            maxFrames = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--allow-empty-mask":
            allowEmptyMask = true
        case "--overwrite":
            overwrite = true
        default:
            if a.hasPrefix("-") {
                throw CLIUsageError("unknown flag for cutout: \(a)")
            }
            guard inputPath == nil else {
                throw CLIUsageError("unexpected extra positional argument: \(a)")
            }
            inputPath = a
        }
        i += 1
    }

    guard let inputPath else { throw CLIUsageError("cutout requires an INPUT path") }
    guard let outputPath else { throw CLIUsageError("cutout requires --output") }

    let inURL = URL(fileURLWithPath: inputPath)
    let outURL = URL(fileURLWithPath: outputPath)
    let ext = outURL.pathExtension.lowercased()

    let report: SubjectCutoutReport
    switch ext {
    case "png":
        if codecName != nil || fps != nil || maxFrames != nil {
            throw CLIUsageError("--codec, --fps, and --max-frames apply only to .mov video cutouts")
        }
        report = try await SubjectCutout.cutoutImage(
            from: inURL,
            to: outURL,
            allowEmptyMask: allowEmptyMask,
            overwrite: overwrite
        )
    case "mov":
        let codec: VideoCodec
        if let codecName {
            guard let parsed = VideoCodec.parseCLI(codecName), parsed.hasAlpha else {
                throw CLIUsageError("video cutout --codec must be hevc-alpha or prores4444 (got \(codecName))")
            }
            codec = parsed
        } else {
            codec = .hevcAlpha
        }
        if let fps, fps <= 0 { throw CLIUsageError("cutout --fps must be > 0") }
        if let maxFrames, maxFrames <= 0 { throw CLIUsageError("cutout --max-frames must be > 0") }
        report = try await SubjectCutout.cutoutVideo(
            from: inURL,
            to: outURL,
            codec: codec,
            fps: fps,
            maxFrames: maxFrames,
            allowEmptyMask: allowEmptyMask,
            overwrite: overwrite
        )
    default:
        throw CLIUsageError("cutout output must end with .png or .mov (got \(outURL.lastPathComponent))")
    }
    return try encodeJSON(report)
}

private func runHybrid(_ args: [String]) async throws -> Data {
    if args.contains("--help") || args.contains("-h") {
        throw CLIDone.help(subcommandHelp["hybrid"]!)
    }
    var htmlPath: String?
    var videoPath: String?
    var outputPath: String?
    var width: Int?
    var height: Int?
    var fps: Int?
    var frames: Int?
    var codec: VideoCodec = .h264
    var bitrate = 20_000_000
    var quality: Double?
    var start = 0.0
    var effect: Wave2EffectKind = .none
    var splitMetalFX = false
    var overwrite = false

    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--html":
            htmlPath = try nextValue(args, index: &i, flag: a)
        case "--video":
            videoPath = try nextValue(args, index: &i, flag: a)
        case "--output", "-o":
            outputPath = try nextValue(args, index: &i, flag: a)
        case "--width":
            width = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--height":
            height = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--fps":
            fps = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--frames":
            frames = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--codec":
            let raw = try nextValue(args, index: &i, flag: a)
            guard let parsed = VideoCodec.parseCLI(raw) else {
                throw CLIUsageError("unknown codec: \(raw) (expected h264|hevc|hevc-alpha|prores422|prores4444)")
            }
            codec = parsed
        case "--bitrate":
            bitrate = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--quality":
            quality = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--start":
            start = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--effect":
            let raw = try nextValue(args, index: &i, flag: a).lowercased()
            switch raw {
            case "none": effect = .none
            case "paper-cutout": effect = .paperCutout
            case "marker-texture": effect = .markerTexture
            default: throw CLIUsageError("unknown --effect '\(raw)' (expected paper-cutout|marker-texture)")
            }
        case "--split-metalfx":
            splitMetalFX = true
        case "--overwrite":
            overwrite = true
        default:
            throw CLIUsageError("unknown argument for hybrid: \(a)")
        }
        i += 1
    }

    guard htmlPath != nil || videoPath != nil else {
        throw CLIUsageError("hybrid requires --html and/or --video")
    }
    guard let outputPath else { throw CLIUsageError("hybrid requires --output") }
    guard let width, let height else { throw CLIUsageError("hybrid requires --width and --height") }
    guard width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 33_554_432,
          width.isMultiple(of: 2), height.isMultiple(of: 2) else {
        throw CLIUsageError("hybrid --width and --height must be positive even integers <= 8192 (max 33554432 pixels)")
    }
    guard let fps, let frames else { throw CLIUsageError("hybrid requires --fps and --frames") }
    guard fps > 0, frames > 0, bitrate > 0, start >= 0 else {
        throw CLIUsageError("hybrid --fps, --frames, and --bitrate must be > 0; --start must be >= 0")
    }
    if let q = quality, !(q > 0 && q <= 1.0) {
        throw CLIUsageError("--quality must be in (0, 1]")
    }

    let report = try await SafariumHybridCompositor.renderHybridVideo(
        htmlURL: htmlPath.map { URL(fileURLWithPath: $0) },
        videoURL: videoPath.map { URL(fileURLWithPath: $0) },
        outputURL: URL(fileURLWithPath: outputPath),
        width: width,
        height: height,
        fps: fps,
        frames: frames,
        codec: codec,
        bitrate: bitrate,
        quality: quality,
        startSeconds: start,
        overwrite: overwrite,
        effect: effect,
        splitMetalFX: splitMetalFX
    )
    return try encodeJSON(report)
}

private func runMux(_ args: [String]) async throws -> Data {
    if args.contains("--help") || args.contains("-h") {
        throw CLIDone.help(subcommandHelp["mux"]! + "\n")
    }
    var videoPath: String?
    var outputPath: String?
    var audioPath: String?
    var audioStart = 0.0
    var audioLang: String?
    var subtitlesPath: String?
    var subtitleLang = "pol"
    var bitrate: Int?
    var overwrite = false

    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--output": outputPath = try nextValue(args, index: &i, flag: a)
        case "--audio": audioPath = try nextValue(args, index: &i, flag: a)
        case "--audio-start": audioStart = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--audio-lang": audioLang = try nextValue(args, index: &i, flag: a)
        case "--subtitles": subtitlesPath = try nextValue(args, index: &i, flag: a)
        case "--subtitle-lang": subtitleLang = try nextValue(args, index: &i, flag: a)
        case "--bitrate": bitrate = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--overwrite": overwrite = true
        default:
            if a.hasPrefix("-") {
                throw CLIUsageError("unknown option for mux: \(a)")
            }
            if videoPath == nil {
                videoPath = a
            } else {
                throw CLIUsageError("unexpected positional argument for mux: \(a)")
            }
        }
        i += 1
    }
    guard let videoPath, let outputPath else {
        throw CLIUsageError("mux requires VIDEO and --output OUT.(mp4|mov)")
    }
    if let b = bitrate, b <= 0 { throw CLIUsageError("--bitrate must be positive") }

    let report = try await LosslessSoundtrackMux.mux(
        videoURL: URL(fileURLWithPath: videoPath),
        wavURL: audioPath.map { URL(fileURLWithPath: $0) },
        audioStartSeconds: audioStart,
        audioLang: audioLang,
        subtitlesURL: subtitlesPath.map { URL(fileURLWithPath: $0) },
        subtitleLang: subtitleLang,
        outputURL: URL(fileURLWithPath: outputPath),
        aacBitrate: bitrate,
        overwrite: overwrite
    )
    return try encodeJSON(report)
}

private func runProbe(_ args: [String]) async throws -> Data {
    if args.contains("--help") || args.contains("-h") {
        throw CLIDone.help(subcommandHelp["probe"]! + "\n")
    }
    var inputPath: String?
    var includeAudio = false
    for a in args {
        switch a {
        case "--include-audio-packets": includeAudio = true
        default:
            if a.hasPrefix("-") {
                throw CLIUsageError("unknown option for probe: \(a)")
            }
            if inputPath == nil {
                inputPath = a
            } else {
                throw CLIUsageError("unexpected positional argument for probe: \(a)")
            }
        }
    }
    guard let inputPath else {
        throw CLIUsageError("probe requires INPUT")
    }
    let report = try await PacketProbe.inspect(
        url: URL(fileURLWithPath: inputPath),
        includeAudioPackets: includeAudio
    )
    return try encodeJSON(report)
}

private func runQA(_ args: [String]) async throws -> Data {
    if args.contains("--help") || args.contains("-h") {
        throw CLIDone.help(subcommandHelp["qa"]! + "\n")
    }
    var inputPath: String?
    var contactSheetPath: String?
    var sceneThreshold = 0.20
    var silenceThresholdDB = -50.0
    var overwrite = false
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--contact-sheet": contactSheetPath = try nextValue(args, index: &i, flag: a)
        case "--scene-threshold": sceneThreshold = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--silence-threshold-db": silenceThresholdDB = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--overwrite": overwrite = true
        default:
            if a.hasPrefix("-") {
                throw CLIUsageError("unknown option for qa: \(a)")
            }
            if inputPath == nil {
                inputPath = a
            } else {
                throw CLIUsageError("unexpected positional argument for qa: \(a)")
            }
        }
        i += 1
    }
    guard let inputPath else {
        throw CLIUsageError("qa requires INPUT")
    }
    guard sceneThreshold > 0, sceneThreshold <= 1.0 else {
        throw CLIUsageError("--scene-threshold must be in (0, 1]")
    }
    guard (-120.0...0.0).contains(silenceThresholdDB) else {
        throw CLIUsageError("--silence-threshold-db must be in [-120, 0]")
    }
    let report = try await NativeQAAnalyzer.analyze(
        url: URL(fileURLWithPath: inputPath),
        contactSheetURL: contactSheetPath.map { URL(fileURLWithPath: $0) },
        overwrite: overwrite,
        sceneThreshold: sceneThreshold,
        silenceThresholdDB: silenceThresholdDB
    )
    return try encodeJSON(report)
}

private func runSplice(_ args: [String]) async throws -> Data {
    if args.contains("--help") || args.contains("-h") {
        throw CLIDone.help(subcommandHelp["splice"]! + "\n")
    }
    var segments: [URL] = []
    var outputPath: String?
    var audioPath: String?
    var audioStart = 0.0
    var audioLang: String?
    var subtitlesPath: String?
    var subtitleLang = "pol"
    var bitrate: Int?
    var allowMixedSTSD = false
    var overwrite = false

    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--segment": segments.append(URL(fileURLWithPath: try nextValue(args, index: &i, flag: a)))
        case "--output": outputPath = try nextValue(args, index: &i, flag: a)
        case "--audio": audioPath = try nextValue(args, index: &i, flag: a)
        case "--audio-start": audioStart = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--audio-lang": audioLang = try nextValue(args, index: &i, flag: a)
        case "--subtitles": subtitlesPath = try nextValue(args, index: &i, flag: a)
        case "--subtitle-lang": subtitleLang = try nextValue(args, index: &i, flag: a)
        case "--bitrate": bitrate = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--allow-mixed-stsd": allowMixedSTSD = true
        case "--overwrite": overwrite = true
        default:
            if a.hasPrefix("-") {
                throw CLIUsageError("unknown option for splice: \(a)")
            }
            segments.append(URL(fileURLWithPath: a))
        }
        i += 1
    }
    guard !segments.isEmpty, let outputPath else {
        throw CLIUsageError("splice requires at least one --segment PATH and --output OUT.(mp4|mov)")
    }
    if let b = bitrate, b <= 0 { throw CLIUsageError("--bitrate must be positive") }

    let report = try await ClosedGOPStitcher.splice(
        segments: segments,
        wavURL: audioPath.map { URL(fileURLWithPath: $0) },
        audioStartSeconds: audioStart,
        audioLang: audioLang,
        subtitlesURL: subtitlesPath.map { URL(fileURLWithPath: $0) },
        subtitleLang: subtitleLang,
        outputURL: URL(fileURLWithPath: outputPath),
        aacBitrate: bitrate,
        requireUniformFormatDescription: !allowMixedSTSD,
        overwrite: overwrite
    )
    return try encodeJSON(report)
}

private func runWarmWorker(_ args: [String]) async throws -> Data {
    if args.contains("--help") || args.contains("-h") {
        throw CLIDone.help(subcommandHelp["warm-worker"]! + "\n")
    }
    var socketPath: String?
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--socket":
            socketPath = try nextValue(args, index: &i, flag: a)
        default:
            throw CLIUsageError("unknown argument for warm-worker: \(a)")
        }
        i += 1
    }
    guard let socketPath, !socketPath.isEmpty else {
        throw CLIUsageError("warm-worker requires --socket PATH")
    }
    try await WarmWorkerServer.serve(socketPath: socketPath)
    struct WarmWorkerExitReport: Encodable { let ok: Bool; let socket: String }
    return try encodeJSON(WarmWorkerExitReport(ok: true, socket: socketPath))
}

@main
struct SafariumMediaCLI {
    static func main() async {
        let rawArgs = Array(CommandLine.arguments.dropFirst())
        let wantJSONErrors = rawArgs.contains("--json-errors") || ProcessInfo.processInfo.environment["SAFARIUM_JSON_ERRORS"] == "1"
        let args = rawArgs.filter { $0 != "--json-errors" }
        guard let sub = args.first else {
            if wantJSONErrors {
                let err = CLIUsageError("missing subcommand; see --help")
                FileHandle.standardError.write(SafariumStructuredErrorEnvelope.from(err, tool: "safarium-media", overrideCode: .E_USAGE).jsonLineData())
            } else {
                FileHandle.standardError.write(Data(globalHelp.utf8))
            }
            exit(64)
        }
        if sub == "--help" || sub == "-h" {
            FileHandle.standardOutput.write(Data((globalHelp + "\n").utf8))
            return
        }

        let rest = Array(args.dropFirst())
        do {
            let output: Data
            switch sub {
            case "extract-audio":
                output = try await runExtractAudio(rest)
            case "mix-audio":
                output = try await runMixAudio(rest)
            case "extract-frames":
                output = try await runExtractFrames(rest)
            case "gif":
                output = try await runGIF(rest)
            case "cutout":
                output = try await runCutout(rest)
            case "hybrid":
                output = try await runHybrid(rest)
            case "mux":
                output = try await runMux(rest)
            case "probe":
                output = try await runProbe(rest)
            case "qa":
                output = try await runQA(rest)
            case "splice":
                output = try await runSplice(rest)
            case "warm-worker":
                output = try await runWarmWorker(rest)
            default:
                throw CLIUsageError("unknown subcommand '\(sub)' (see --help)")
            }
            FileHandle.standardOutput.write(output)
        } catch CLIDone.help(let text) {
            FileHandle.standardOutput.write(Data(text.utf8))
        } catch let err as CLIUsageError {
            if wantJSONErrors {
                FileHandle.standardError.write(SafariumStructuredErrorEnvelope.from(err, tool: "safarium-media", overrideCode: .E_USAGE).jsonLineData())
            } else {
                FileHandle.standardError.write(Data("safarium-media: \(err)\n".utf8))
            }
            exit(64)
        } catch {
            if wantJSONErrors {
                FileHandle.standardError.write(SafariumStructuredErrorEnvelope.from(error, tool: "safarium-media").jsonLineData())
            } else {
                FileHandle.standardError.write(Data("safarium-media: \(error)\n".utf8))
            }
            exit(1)
        }
    }
}
