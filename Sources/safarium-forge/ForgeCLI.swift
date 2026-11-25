import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO
import Metal
import SafariumContainers
import SafariumCore
import SafariumForgeCore
import SafariumPrism
import UniformTypeIdentifiers

// MARK: - CLI Error & Help Primitives

private struct CLIUsageError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { self.description = message }
}

private enum CLIDone: Error {
    case text(String)
}

private let globalHelp = """
Usage:
  safarium-forge <command> [options]
  safarium-render forge <command> [options]

Commands:
  run           --recipe <path.json|-> [--validate-only | --dry-run]
  validate      --recipe <path.json|->
  schema        [all|recipe|subcommands|errors]
  remux         <input> -o <output> [--to mp4|mov|mkv|webm|ts] [--subtitles <srt> --lang tha] [--overwrite]
  inspect       <file-or-volume-path> [--include-audio-packets]
  image         <input-image-or-video> -o <out.(webp|avif|heic|heics|png|jpg)> [--quality Q] [--fps N] [--frames N] [--loop N] [--overwrite]
  audio         <process|crossfade|silence-trim|waveform|synth|split-mp3> [options]
  sheet         <input> -o <out.(jpg|png|webp|avif|heic)> [--cols C --rows R --tile-width W --tile-height H --padding P --bg HEX --every-frames N | --every-sec S | --timestamps T1,T2] [--manifest out.json] [--overwrite]
  compare       <ref> <cand> -o <strip.(png|jpg|webp|avif|heic)> [--samples N] [--vertical] [--tile-width W] [--padding P] [--bg HEX] [--overwrite]
  pq            <ref> <cand> [--samples N] [--thai-ocr] [--expected-thai TEXT] [--min-score S] [--max-de00-p95 D] [--min-msssim M] [--strict]
  qa            <input> [--ref REF] [--contact-sheet OUT] [--cols C --rows R --tile-width W] [--scene-threshold F] [--silence-threshold-db DB] [--thai-ocr] [--min-score S] [--max-de00-p95 D] [--strict] [--overwrite]
  reframe       <input> -o <output> [--aspect 9:16] [--detector saliencyAndFace|faceOnly|saliencyOnly|upperBody] [--ema F] [--hysteresis F] [--scene-cut-threshold F] [--no-reset-on-cut] [--height N] [--codec h264|hevc] [--bitrate BPS] [--quality Q] [--overwrite]
  matte         <input> -o <output.(mov|mp4)> [--mode personFast|personBalanced|personAccurate|instance] [--ema F] [--bg HEX | --bg-image IMG] [--codec hevc-alpha|prores4444|h264] [--mask-only] [--bitrate BPS] [--quality Q] [--max-frames N] [--overwrite]
  pipe-encode   --width W --height H --fps N [--pix-fmt rgb24|bgr24|rgba|bgra] [--vflip] [--codec h264|hevc|hevc-alpha|prores4444] [--bitrate BPS] [--quality Q] -o <primary> [--primary-audio-codec aac|pcm_s16le|copy] [--inline-sheet <png> --sheet-cols C --sheet-rows R --tile-width W] [--secondary <sec> --secondary-codec h264 --secondary-bg '#000000'] [--audio <wav|m4a>] [--subtitles <srt> --lang tha] [--max-frames N] [--no-closed-gop] [--overwrite]
  seq-encode    [--dir <dir> | --glob <pattern> | --list <file>] -o <out.(mp4|mov)> [--fps 24] [--width W --height H] [--codec h264|hevc|hevc-alpha|prores4444] [--bitrate BPS] [--quality Q] [--audio <path>] [--inline-sheet <png> --sheet-cols 6 --sheet-rows 4 --tile-width 320] [--decode-ahead 3] [--overwrite]
  batch-dom     --manifest <manifest.json> [--font-dir <dir>] [--overwrite]
  transcode     <input> -o <out.(mp4|mov)> [--codec h264|hevc|hevc-alpha|prores4444] [--max-bytes N | --bitrate BPS | --quality Q] [--audio-bitrate 128000] [--width W --height H --fps N] [--overwrite]
  prism         <capabilities|sync-ir|preview-stills|render-web|render-blender|composite> [options]
  daemon        --socket <uds-path> [--idle-timeout 20] [--cache-root <dir>] [--no-pq-preload]
  ring-encode   --socket <uds-path> [--idle-timeout 30]
  cache         <hash|store|lookup|stats|prune> [options]
  ab-gallery    --manifest <manifest.json> -o <gallery.html> [--overwrite]
  capabilities  Report Apple Silicon VT/AudioToolbox/ImageIO/Metal/ANE/APFS capabilities and OS walls
  version       Print safarium-forge version

Run `safarium-forge <command> --help` for subcommand options.
"""

private let subcommandHelp: [String: String] = [
    "run": "Usage: safarium-forge run --recipe <path.json|-> [--validate-only | --dry-run] [--progress jsonl] [--json-errors]",
    "validate": "Usage: safarium-forge validate --recipe <path.json|->",
    "schema": "Usage: safarium-forge schema [all|recipe|subcommands|errors]",
    "remux": "Usage: safarium-forge remux <input> -o <output> [--to mp4|mov|mkv|webm|ts] [--subtitles <srt>] [--lang tha] [--overwrite]",
    "inspect": "Usage: safarium-forge inspect <file-or-volume-path> [--include-audio-packets]",
    "probe": "Usage: safarium-forge probe <file-or-volume-path> [--include-audio-packets]",
    "image": "Usage: safarium-forge image <input-image-or-video> -o <out.(webp|avif|heic|heics|png|jpg)> [--quality 0.80] [--fps N] [--frames N] [--loop N] [--start S] [--overwrite]",
    "audio": """
    Usage: safarium-forge audio <action> [options]
      process       <input> -o <out.(wav|m4a)> [--eq mode:freq[:q[:gainDB]] ...] [--comp-thresh DB] [--comp-ratio R] [--gain DB] [--lufs DB] [--peak-dbtp DB] [--sr N] [--channels 1|2] [--bitrate BPS] [--overwrite]
      crossfade     <first> <second> -o <out.(wav|m4a)> [--duration S] [--curve eqpower|tri] [--sr N] [--channels 1|2] [--overwrite]
      silence-trim  <input> -o <out.(wav|m4a)> [--threshold-db -42] [--padding 0.05] [--sr N] [--channels 1|2] [--overwrite]
      waveform      <input> [--bins 120] [--sr 8000] [-o <out.json>] [--overwrite]
      synth         -o <out.(wav|m4a)> [--waveform sine|pinkNoise|whiteNoise|amPad|sweep] [--freq 440] [--end-freq HZ] [--carriers H1,H2] [--mod-hz HZ] [--mod-depth D] [--amp 0.25] [--duration 1.0] [--sr 48000] [--channels 2] [--fade-in S] [--fade-out S] [--overwrite]
      split-mp3     <input.mp3> --out-dir <dir> [--chunk-seconds 1200] [--prefix chunk] [--overwrite]
    """,
    "sheet": "Usage: safarium-forge sheet <input> -o <out.(jpg|png|webp|avif|heic)> [--cols 6] [--rows 4] [--tile-width 270] [--tile-height N] [--padding 8] [--bg '#0F172A'] [--every-frames N | --every-sec S | --timestamps T1,T2] [--quality 0.88] [--manifest out.json] [--overwrite]",
    "compare": "Usage: safarium-forge compare <ref> <cand> -o <strip.(png|jpg|webp|avif|heic)> [--samples 4] [--vertical] [--tile-width 360] [--padding 8] [--bg '#0F172A'] [--overwrite]",
    "pq": "Usage: safarium-forge pq <ref> <cand> [--samples 12] [--thai-ocr] [--expected-thai TEXT] [--min-score 85] [--max-de00-p95 2.0] [--min-msssim 0.97] [--strict]",
    "qa": "Usage: safarium-forge qa <input> [--ref REF] [--contact-sheet OUT] [--cols C] [--rows R] [--tile-width W] [--scene-threshold 0.20] [--silence-threshold-db -50] [--thai-ocr] [--min-score 85] [--max-de00-p95 2.0] [--strict] [--overwrite]",
    "reframe": "Usage: safarium-forge reframe <input> -o <output> [--aspect 9:16] [--detector saliencyAndFace|faceOnly|saliencyOnly|upperBody] [--ema 0.14] [--hysteresis 0.02] [--scene-cut-threshold 0.20] [--no-reset-on-cut] [--height N] [--codec h264|hevc] [--bitrate BPS] [--quality Q] [--overwrite]",
    "matte": "Usage: safarium-forge matte <input> -o <output.(mov|mp4)> [--mode personFast|personBalanced|personAccurate|instance] [--ema 0.35] [--bg '#102030' | --bg-image IMG] [--codec hevc-alpha|prores4444|h264] [--mask-only] [--bitrate BPS] [--quality Q] [--max-frames N] [--overwrite]",
    "pipe-encode": "Usage: safarium-forge pipe-encode --width W --height H --fps N [--pix-fmt rgb24|bgr24|rgba|bgra] [--vflip] [--codec h264|hevc|hevc-alpha|prores4444] [--bitrate BPS] [--quality Q] -o <primary> [--primary-audio-codec aac|pcm_s16le|copy] [--inline-sheet <png> --sheet-cols 6 --sheet-rows 4 --tile-width 320] [--secondary <sec> --secondary-codec h264 --secondary-bg '#000000' --secondary-bitrate BPS --secondary-quality Q] [--audio <wav|m4a>] [--subtitles <srt> --lang tha] [--max-frames N] [--no-closed-gop] [--overwrite]",
    "seq-encode": "Usage: safarium-forge seq-encode [--dir <dir> | --glob <pattern> | --list <file>] -o <out.(mp4|mov)> [--fps 24] [--width W] [--height H] [--codec h264|hevc|hevc-alpha|prores4444] [--bitrate 8000000] [--quality Q] [--audio <path>] [--inline-sheet <png> --sheet-cols 6 --sheet-rows 4 --tile-width 320] [--decode-ahead 3] [--overwrite]",
    "batch-dom": "Usage: safarium-forge batch-dom --manifest <manifest.json> [--font-dir <dir>] [--overwrite]",
    "transcode": "Usage: safarium-forge transcode <input> -o <out.(mp4|mov)> [--codec h264|hevc|hevc-alpha|prores4444] [--max-bytes N | --bitrate BPS | --quality Q] [--audio-bitrate 128000] [--width W --height H --fps N] [--overwrite]",
    "prism": """
    Usage: safarium-forge prism <action> [options]
      capabilities
      sync-ir         <input.blend> --glb <out.glb> --ir <out.ir.json> [--frame 1] [--engine eevee|cycles] [--width W --height H] [--no-animations] [--overwrite]
      preview-stills  <input.(blend|glb|html|http://127.0.0.1:...)> [-o <sheet.png|dir>] [--still-dir <dir>] [--contact-sheet <sheet.png>] [--tier auto|webkitGLB|warmBlender] [--allow-loopback-http] [--width 1080 --height 1920] [--angles 0,45,90] [--frames 1,10,20] [--cols C --rows R --tile-width 360 --padding 8 --bg '#0F172A'] [--format png|jpg|webp|avif|heic] [--engine eevee|cycles] [--samples 16] [--shm-method bmp_mmap|gpu_offscreen] [--overwrite]
      render-web      <input.html|http://127.0.0.1:...> -o <out.(mp4|mov)> [--allow-loopback-http] [--width 1080 --height 1920 --fps 30 --output-fps N --frames 30 --start 0] [--ready-expr EXPR] [--init-js JS | --init-file PATH] [--seek-expr EXPR] [--font-dir DIR] [--no-inject-fonts] [--grain AMT --grain-size SZ] [--loudnorm LUFS --true-peak DBTP --apad] [--metal-svg-filters] [--no-sharp-text-1x] [--ready-timeout S] [--adaptive-workers 1 --budget-mb 700] [--codec h264|hevc|hevc-alpha|prores4444] [--bitrate 12000000 --quality Q] [--transparent] [--overlay-html <hud.html>] [--audio <wav|m4a>] [--subtitles <srt> --lang tha] [--secondary <sec> --secondary-codec h264] [--metalfx --scale 0.67 --no-auto-verify --verify-every 15 --min-pq 85 --thai-ocr --expected-thai TEXT] [--no-antilag] [--overwrite]
      render-blender  <input.blend> -o <out.(mp4|mov)> [--ir <ir.json>] [--engine eevee|cycles] [--shm-method bmp_mmap|gpu_offscreen] [--samples 16] [--width 1080 --height 1920 --fps 30 --start-frame 1 --frames 30] [--transparent] [--codec h264|hevc|hevc-alpha|prores4444] [--bitrate 12000000 --quality Q] [--overlay-html <hud.html>] [--audio <wav|m4a>] [--subtitles <srt> --lang tha] [--secondary <sec> --secondary-codec h264] [--metalfx --scale 0.67 --no-auto-verify --verify-every 15 --min-pq 85 --thai-ocr --expected-thai TEXT] [--no-antilag] [--overwrite]
      composite       <input.blend> [--bg-html <bg.html> | --bg-glb <bg.glb>] [--overlay-html <hud.html>] -o <out.mp4> [--secondary-mov <alpha.mov>] [--primary-codec h264|hevc] [--secondary-codec prores4444|hevc-alpha] [--width 1080 --height 1920 --fps 30 --start-frame 1 --frames 15] [--engine eevee|cycles] [--samples 16] [--shm-method bmp_mmap|gpu_offscreen] [--bitrate 12000000 --quality Q] [--audio <wav|m4a>] [--subtitles <srt> --lang tha] [--metalfx --scale 0.67 --no-auto-verify --verify-every 15 --min-pq 85 --thai-ocr --expected-thai TEXT] [--no-antilag] [--overwrite]
    """,
    "daemon": "Usage: safarium-forge daemon --socket <uds-path> [--idle-timeout 20] [--cache-root <dir>] [--no-pq-preload]",
    "ring-encode": "Usage: safarium-forge ring-encode --socket <uds-path> [--idle-timeout 30]",
    "cache": """
    Usage: safarium-forge cache <hash|store|lookup|stats|prune> [options]
      hash   --namespace <ns> [--params '<json>'] [--inputs path1,path2]
      store  --input <file> [--key <hex>] [--namespace <ns>] [--params '<json>'] [--root <dir>]
      lookup --key <hex> [-o <dest>] [--root <dir>] [--kind auto|scene|shot] [--overwrite]
      stats  [--root <dir>] [--kind auto|scene|shot]
      prune  --max-bytes <N> [--root <dir>] [--kind auto|scene|shot]
    """,
    "ab-gallery": "Usage: safarium-forge ab-gallery --manifest <manifest.json> -o <gallery.html> [--overwrite]",
    "capabilities": "Usage: safarium-forge capabilities",
]

// MARK: - Shared Argument & Serialization Helpers

private func nextValue(_ args: [String], index: inout Int, flag: String) throws -> String {
    guard index + 1 < args.count else {
        throw CLIUsageError("missing value for \(flag)")
    }
    index += 1
    return args[index]
}

private func parseInt(_ raw: String, flag: String) throws -> Int {
    guard let value = Int(raw) else {
        throw CLIUsageError("expected integer for \(flag), got '\(raw)'")
    }
    return value
}

private func parseDouble(_ raw: String, flag: String) throws -> Double {
    guard let value = Double(raw), value.isFinite else {
        throw CLIUsageError("expected finite number for \(flag), got '\(raw)'")
    }
    return value
}

private func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    return data
}

private func checkSubcommandHelp(_ args: [String], command: String) throws {
    if args.contains("--help") || args.contains("-h") {
        throw CLIDone.text((subcommandHelp[command] ?? globalHelp) + "\n")
    }
}

private func readExactBytes(from handle: FileHandle, count: Int) throws -> Data? {
    var collected = Data()
    collected.reserveCapacity(count)
    while collected.count < count {
        let chunk = try handle.read(upToCount: count - collected.count) ?? Data()
        if chunk.isEmpty { break }
        collected.append(chunk)
    }
    if collected.isEmpty { return nil }
    guard collected.count == count else {
        throw SafariumError.encode("rawPipe truncated frame: got \(collected.count)/\(count) bytes")
    }
    return collected
}

private func withPlayableVideoURL<T>(inputURL: URL, _ body: (URL) async throws -> T) async throws -> T {
    let ext = inputURL.pathExtension.lowercased()
    if ext == "mkv" || ext == "webm" || ext == "ts" || ext == "m2ts" {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safarium-forge-demux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let stagedMP4 = tempDir.appendingPathComponent("demuxed.mp4")
        if ext == "ts" || ext == "m2ts" {
            _ = try await MPEGTSCodec.demuxToMP4(inputURL: inputURL, outputURL: stagedMP4, overwrite: true)
        } else {
            _ = try await EBMLMatroskaCodec.demuxToMP4(inputURL: inputURL, outputURL: stagedMP4, overwrite: true)
        }
        return try await body(stagedMP4)
    }
    return try await body(inputURL)
}

private func parseCodec(_ raw: String, flag: String = "--codec") throws -> VideoCodec {
    guard let codec = VideoCodec.parseCLI(raw) else {
        throw CLIUsageError("unsupported \(flag) '\(raw)' (expected h264|hevc|hevc-alpha|prores422|prores4444)")
    }
    return codec
}

private func parseReframeDetector(_ raw: String) throws -> ForgeReframeDetector {
    switch raw.lowercased() {
    case "saliency", "saliencyonly", "saliency-only":
        return .saliency
    case "face", "faceonly", "face-only":
        return .face
    case "saliencyandface", "saliency+face", "saliency-and-face", "upperbody", "upper-body":
        return .saliencyAndFace
    default:
        throw CLIUsageError("unsupported --detector '\(raw)' (expected saliencyAndFace|faceOnly|saliencyOnly|upperBody)")
    }
}

private func parseMatteMode(_ raw: String) throws -> ForgeMatteMode {
    switch raw.lowercased() {
    case "personfast", "fast": return .personFast
    case "personbalanced", "balanced": return .personBalanced
    case "personaccurate", "accurate": return .personAccurate
    case "instance": return .instance
    default:
        throw CLIUsageError("unsupported --mode '\(raw)' (expected personFast|personBalanced|personAccurate|instance)")
    }
}

// MARK: - Subcommands: run & validate

private struct ForgeValidateReport: Codable {
    let valid: Bool
    let schema: String
    let outputPath: String
    let container: String
    let primaryCodec: String
    let secondaryCodec: String?
    let pixelFormat: String
    let colorimetry: String
    let ringSlots: Int
    let orderedVideoOps: [String]
    let orderedAudioOps: [String]
    let htmlInputIDs: [String]
    let finalVideoNodeID: String?
    let finalAudioNodeID: String?
    let warnings: [String]
}

private struct ForgeDryRunInputCheck: Codable {
    let id: String
    let kind: String
    let path: String?
    let exists: Bool?
    let bytes: Int64?
}

private struct ForgeDryRunPlanReport: Codable {
    let valid: Bool
    let dryRun: Bool
    let executes: Bool
    let schema: String
    let outputPath: String
    let secondaryOutputPath: String?
    let container: String
    let primaryCodec: String
    let secondaryCodec: String?
    let pixelFormat: String
    let colorimetry: String
    let estimatedPeakRAMMB: Double
    let hardwarePaths: [String]
    let inputs: [ForgeDryRunInputCheck]
    let orderedVideoOps: [String]
    let orderedAudioOps: [String]
    let warnings: [String]
}

@MainActor
private func runRecipeCommand(
    _ args: [String],
    forceValidateOnly: Bool = false,
    progressEmitter: SafariumProgressEmitter? = nil
) async throws -> Data {
    try checkSubcommandHelp(args, command: forceValidateOnly ? "validate" : "run")
    var recipePath: String?
    var validateOnly = forceValidateOnly
    var dryRun = false
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--recipe", "-r":
            recipePath = try nextValue(args, index: &i, flag: a)
        case "--validate-only":
            validateOnly = true
        case "--dry-run":
            dryRun = true
        default:
            if a.hasPrefix("-") && a != "-" {
                throw CLIUsageError("unknown option for run: \(a)")
            }
            if recipePath == nil {
                recipePath = a
            } else {
                throw CLIUsageError("unexpected positional argument for run: \(a)")
            }
        }
        i += 1
    }
    guard let recipePath, !recipePath.isEmpty else {
        throw CLIUsageError("run requires --recipe <path.json|->")
    }

    let recipeData: Data
    if recipePath == "-" {
        recipeData = try FileHandle.standardInput.readToEnd() ?? Data()
    } else {
        recipeData = try Data(contentsOf: URL(fileURLWithPath: recipePath))
    }
    let recipe = try JSONDecoder().decode(ForgeRecipe.self, from: recipeData)
    let plan = try ForgeRecipeValidator.validate(recipe)

    if dryRun {
        let fm = FileManager.default
        let inputChecks: [ForgeDryRunInputCheck] = recipe.inputs.map { inp in
            guard let p = inp.path else {
                return ForgeDryRunInputCheck(id: inp.id, kind: inp.kind.rawValue, path: nil, exists: nil, bytes: nil)
            }
            let exists = fm.fileExists(atPath: p)
            let bytes = ((try? fm.attributesOfItem(atPath: p)[.size]) as? NSNumber)?.int64Value
            return ForgeDryRunInputCheck(id: inp.id, kind: inp.kind.rawValue, path: p, exists: exists, bytes: bytes)
        }
        let ringMB = Double(plan.ringSlots * recipe.timeline.width * recipe.timeline.height * 4) / (1024.0 * 1024.0)
        let webMB = plan.htmlInputIDs.isEmpty ? 28.0 : Double(plan.htmlInputIDs.count) * 145.0
        let estRAM = ((ringMB * 2.0 + webMB) * 100.0).rounded() / 100.0
        var hw = ["VideoToolbox:\(plan.resolvedPrimaryCodec.rawValue)", "Accelerate:vDSP"]
        if !plan.orderedVideoOps.isEmpty { hw.append("Metal:MPS+Kernels") }
        if !plan.htmlInputIDs.isEmpty { hw.append("WindowlessWKWebView:ModeC") }
        if plan.orderedVideoOps.contains(where: { $0.op == .autoReframe || $0.op == .personMatte }) {
            hw.append("AppleNeuralEngine:Vision")
        }
        let dryReport = ForgeDryRunPlanReport(
            valid: true,
            dryRun: true,
            executes: false,
            schema: recipe.schema ?? "safarium-forge/graph-v1",
            outputPath: recipe.output.path,
            secondaryOutputPath: recipe.output.secondaryPath,
            container: plan.resolvedContainer,
            primaryCodec: plan.resolvedPrimaryCodec.rawValue,
            secondaryCodec: plan.resolvedSecondaryCodec?.rawValue,
            pixelFormat: plan.resolvedPixelFormat.rawValue,
            colorimetry: plan.resolvedColorimetry,
            estimatedPeakRAMMB: estRAM,
            hardwarePaths: hw,
            inputs: inputChecks,
            orderedVideoOps: plan.orderedVideoOps.map(\.id),
            orderedAudioOps: plan.orderedAudioOps.map(\.id),
            warnings: plan.warnings
        )
        return try encodeJSON(dryReport)
    }

    if validateOnly {
        let report = ForgeValidateReport(
            valid: true,
            schema: recipe.schema ?? "safarium-forge/graph-v1",
            outputPath: recipe.output.path,
            container: plan.resolvedContainer,
            primaryCodec: plan.resolvedPrimaryCodec.rawValue,
            secondaryCodec: plan.resolvedSecondaryCodec?.rawValue,
            pixelFormat: plan.resolvedPixelFormat.rawValue,
            colorimetry: plan.resolvedColorimetry,
            ringSlots: plan.ringSlots,
            orderedVideoOps: plan.orderedVideoOps.map(\.id),
            orderedAudioOps: plan.orderedAudioOps.map(\.id),
            htmlInputIDs: plan.htmlInputIDs.sorted(),
            finalVideoNodeID: plan.finalVideoNodeID,
            finalAudioNodeID: plan.finalAudioNodeID,
            warnings: plan.warnings
        )
        return try encodeJSON(report)
    }

    let hasRawPipe = recipe.inputs.contains { $0.kind == .rawPipe }
    if hasRawPipe && recipePath == "-" {
        throw CLIUsageError("cannot stream rawPipe frames from stdin when --recipe is '-'")
    }

    if !plan.htmlInputIDs.isEmpty {
        HostApp.prepare()
    }

    let provider: ForgeGraphExecutor.RawPipeFrameProvider? = hasRawPipe ? { _, _, expectedBytes in
        try readExactBytes(from: FileHandle.standardInput, count: expectedBytes)
    } : nil

    let report = try await ForgeGraphExecutor.execute(
        recipe: recipe,
        rawPipeProvider: provider,
        progressEmitter: progressEmitter
    )
    return try encodeJSON(report)
}

private struct ForgeSchemaReport: Codable {
    let schemaVersion: String
    let toolVersion: String
    let globalFlags: [String]
    let subcommands: [String: String]?
    let inputKinds: [String]?
    let videoOps: [String]?
    let audioOps: [String]?
    let errorCodes: [String: String]?
}

private func runSchemaCommand(_ args: [String]) throws -> Data {
    try checkSubcommandHelp(args, command: "schema")
    let target = (args.first ?? "all").lowercased()
    guard ["all", "recipe", "subcommands", "errors"].contains(target) else {
        throw CLIUsageError("unknown schema section '\(target)' (expected all|recipe|subcommands|errors)")
    }
    let showAll = target == "all"
    let errorMap = Dictionary(uniqueKeysWithValues: SafariumErrorCode.allCases.map { ($0.rawValue, $0.defaultHint) })
    let report = ForgeSchemaReport(
        schemaVersion: "safarium-forge/schema-v1",
        toolVersion: SafariumForgeModuleInfo.version,
        globalFlags: ["--progress jsonl", "--json-errors", "--help"],
        subcommands: (showAll || target == "subcommands") ? subcommandHelp : nil,
        inputKinds: (showAll || target == "recipe") ? ["video", "audio", "image", "imageSequence", "htmlOverlay", "lut3d", "subtitles", "rawPipe", "synthAudio"] : nil,
        videoOps: (showAll || target == "recipe") ? ["geom", "deinterlace", "kenBurns", "chromaKey", "gblur", "colorGrade", "lut3d", "vignette", "grain", "overlay", "blend", "xfade", "hstack", "vstack", "paperCutout", "markerTexture", "splitMetalFX", "autoReframe", "personMatte", "htmlOverlay", "tmix", "kGrief", "setpts", "tpad", "llsr"] : nil,
        audioOps: (showAll || target == "recipe") ? ["biquadEQ", "compressor", "gain", "acrossfade", "silenceTrim", "sidechainDuck", "mix", "loudnorm", "peakLimit", "synth", "waveform", "voiceIsolate", "fade", "afade", "trim", "atrim", "pad", "apad"] : nil,
        errorCodes: (showAll || target == "errors") ? errorMap : nil
    )
    return try encodeJSON(report)
}

// MARK: - Subcommand: remux

private func parseSRTCuesIfPresent(subtitlesURL: URL?, mediaURL: URL) async throws -> [SafariumSRTCue] {
    guard let subtitlesURL else { return [] }
    let asset = AVURLAsset(url: mediaURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let dur = try await asset.load(.duration)
    return try SafariumTX3G.parseSRT(url: subtitlesURL, offsetSeconds: 0, duration: dur)
}

private func runRemuxCommand(_ args: [String]) async throws -> Data {
    try checkSubcommandHelp(args, command: "remux")
    var inputPath: String?
    var outputPath: String?
    var toContainer: String?
    var subtitlesPath: String?
    var lang = "tha"
    var overwrite = false
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "-o", "--output", "--out":
            outputPath = try nextValue(args, index: &i, flag: a)
        case "--to":
            toContainer = try nextValue(args, index: &i, flag: a).lowercased()
        case "--subtitles":
            subtitlesPath = try nextValue(args, index: &i, flag: a)
        case "--lang", "--subtitle-lang":
            lang = try nextValue(args, index: &i, flag: a)
        case "--overwrite":
            overwrite = true
        default:
            if a.hasPrefix("-") {
                throw CLIUsageError("unknown option for remux: \(a)")
            }
            if inputPath == nil {
                inputPath = a
            } else {
                throw CLIUsageError("unexpected positional argument for remux: \(a)")
            }
        }
        i += 1
    }
    guard let inputPath, let outputPath else {
        throw CLIUsageError("remux requires <input> and -o <output>")
    }

    let inURL = URL(fileURLWithPath: inputPath)
    let outURL = URL(fileURLWithPath: outputPath)
    let srcExt = inURL.pathExtension.lowercased()
    let dstFmt = (toContainer ?? outURL.pathExtension).lowercased()
    guard ["mp4", "mov", "mkv", "webm", "ts"].contains(dstFmt) else {
        throw CLIUsageError("remux target format must be mp4|mov|mkv|webm|ts, got '\(dstFmt)'")
    }

    let subURL = subtitlesPath.map { URL(fileURLWithPath: $0) }
    let t0 = DispatchTime.now().uptimeNanoseconds

    let report: RemuxReport
    if srcExt == "mkv" || srcExt == "webm" {
        if dstFmt == "mp4" || dstFmt == "mov" {
            report = try await EBMLMatroskaCodec.demuxToMP4(inputURL: inURL, outputURL: outURL, overwrite: overwrite)
        } else {
            let stage = try APFSAutoStage.makeSession(for: outURL, overwrite: overwrite)
            defer { stage.cleanup() }
            let tmpMP4 = stage.fileURL("bridge.mp4")
            let demuxRep = try await EBMLMatroskaCodec.demuxToMP4(inputURL: inURL, outputURL: tmpMP4, overwrite: true)
            let stagedOut = stage.fileURL("out.\(dstFmt)")
            if dstFmt == "ts" {
                _ = try await MPEGTSCodec.muxFromMP4OrMOV(inputURL: tmpMP4, outputURL: stagedOut, overwrite: true)
            } else {
                let cues = try await parseSRTCuesIfPresent(subtitlesURL: subURL, mediaURL: tmpMP4)
                _ = try await EBMLMatroskaCodec.muxFromMP4OrMOV(
                    inputURL: tmpMP4, outputURL: stagedOut,
                    docType: dstFmt == "webm" ? "webm" : "matroska", subtitleCues: cues, overwrite: true
                )
            }
            try stage.commit(stagedFile: stagedOut, overwrite: overwrite)
            report = RemuxReport(
                inputPath: inURL.path, outputPath: outURL.path,
                sourceContainer: srcExt, targetContainer: dstFmt,
                videoPackets: demuxRep.videoPackets, audioPackets: demuxRep.audioPackets,
                subtitleCues: demuxRep.subtitleCues,
                wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            )
        }
    } else if srcExt == "ts" || srcExt == "m2ts" {
        if dstFmt == "mp4" || dstFmt == "mov" {
            report = try await MPEGTSCodec.demuxToMP4(inputURL: inURL, outputURL: outURL, overwrite: overwrite)
        } else {
            let stage = try APFSAutoStage.makeSession(for: outURL, overwrite: overwrite)
            defer { stage.cleanup() }
            let tmpMP4 = stage.fileURL("bridge.mp4")
            let demuxRep = try await MPEGTSCodec.demuxToMP4(inputURL: inURL, outputURL: tmpMP4, overwrite: true)
            let stagedOut = stage.fileURL("out.\(dstFmt)")
            if dstFmt == "ts" {
                _ = try await MPEGTSCodec.muxFromMP4OrMOV(inputURL: tmpMP4, outputURL: stagedOut, overwrite: true)
            } else {
                let cues = try await parseSRTCuesIfPresent(subtitlesURL: subURL, mediaURL: tmpMP4)
                _ = try await EBMLMatroskaCodec.muxFromMP4OrMOV(
                    inputURL: tmpMP4, outputURL: stagedOut,
                    docType: dstFmt == "webm" ? "webm" : "matroska", subtitleCues: cues, overwrite: true
                )
            }
            try stage.commit(stagedFile: stagedOut, overwrite: overwrite)
            report = RemuxReport(
                inputPath: inURL.path, outputPath: outURL.path,
                sourceContainer: "ts", targetContainer: dstFmt,
                videoPackets: demuxRep.videoPackets, audioPackets: demuxRep.audioPackets,
                subtitleCues: 0,
                wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            )
        }
    } else {
        if dstFmt == "mkv" || dstFmt == "webm" {
            let cues = try await parseSRTCuesIfPresent(subtitlesURL: subURL, mediaURL: inURL)
            report = try await EBMLMatroskaCodec.muxFromMP4OrMOV(
                inputURL: inURL, outputURL: outURL,
                docType: dstFmt == "webm" ? "webm" : "matroska", subtitleCues: cues, overwrite: overwrite
            )
        } else if dstFmt == "ts" {
            report = try await MPEGTSCodec.muxFromMP4OrMOV(inputURL: inURL, outputURL: outURL, overwrite: overwrite)
        } else {
            let muxRep = try await LosslessSoundtrackMux.mux(
                videoURL: inURL, subtitlesURL: subURL, subtitleLang: lang, outputURL: outURL, overwrite: overwrite
            )
            let probe = try await PacketProbe.inspect(url: outURL, includeAudioPackets: false)
            let vCount = probe.tracks.first(where: { $0.mediaType == "vide" })?.packetCount ?? 0
            let sCount = probe.tracks.first(where: { $0.mediaType == "sbtl" })?.packetCount ?? 0
            report = RemuxReport(
                inputPath: inURL.path, outputPath: muxRep.outputPath,
                sourceContainer: srcExt.isEmpty ? "mp4" : srcExt, targetContainer: dstFmt,
                videoPackets: vCount, audioPackets: 0, subtitleCues: sCount,
                wallMs: muxRep.wallMs
            )
        }
    }
    return try encodeJSON(report)
}

// MARK: - Subcommand: inspect / probe

private struct ImageInspectInfo: Codable {
    let uti: String?
    let width: Int
    let height: Int
    let frameCount: Int
    let hasAlpha: Bool
}

private struct AudioInspectInfo: Codable {
    let sampleRate: Double
    let channels: Int
    let frameCount: Int
    let sourceSampleRate: Double
    let sourceChannels: Int
    let durationSeconds: Double
}

private struct InspectCLIReport: Codable {
    let path: String
    let kind: String
    let bytes: Int64?
    let volume: ForgeVolumeCapabilities
    let mkv: MKVInspectReport?
    let mpegts: MPEGTSInspectReport?
    let mpeg2ps: MPEG2PSInspectReport?
    let ogg: OggInspectReport?
    let vorbis: OggAudioInfo?
    let media: ProbeReport?
    let audio: AudioInspectInfo?
    let image: ImageInspectInfo?

    init(
        path: String,
        kind: String,
        bytes: Int64?,
        volume: ForgeVolumeCapabilities,
        mkv: MKVInspectReport? = nil,
        mpegts: MPEGTSInspectReport? = nil,
        mpeg2ps: MPEG2PSInspectReport? = nil,
        ogg: OggInspectReport? = nil,
        vorbis: OggAudioInfo? = nil,
        media: ProbeReport? = nil,
        audio: AudioInspectInfo? = nil,
        image: ImageInspectInfo? = nil
    ) {
        self.path = path
        self.kind = kind
        self.bytes = bytes
        self.volume = volume
        self.mkv = mkv
        self.mpegts = mpegts
        self.mpeg2ps = mpeg2ps
        self.ogg = ogg
        self.vorbis = vorbis
        self.media = media
        self.audio = audio
        self.image = image
    }
}

private func detectContainerKind(url: URL, ext: String) -> String {
    if let handle = try? FileHandle(forReadingFrom: url) {
        defer { try? handle.close() }
        if let head = try? handle.read(upToCount: 256), !head.isEmpty {
            let b = [UInt8](head)
            if b.count >= 4 && b[0] == 0x1A && b[1] == 0x45 && b[2] == 0xDF && b[3] == 0xA3 {
                return ext == "webm" ? "webm" : "mkv"
            }
            if b.count >= 4 && b[0] == 0x4F && b[1] == 0x67 && b[2] == 0x67 && b[3] == 0x53 {
                return "ogg"
            }
            if b.count >= 4 && b[0] == 0x00 && b[1] == 0x00 && b[2] == 0x01 && b[3] == 0xBA {
                return "mpeg2ps"
            }
            if b.count >= 189 && b[0] == 0x47 && b[188] == 0x47 {
                return "ts"
            }
        }
    }
    if ext == "ogg" || ext == "oga" { return "ogg" }
    if ext == "mpeg" || ext == "mpg" { return "mpeg2ps" }
    return ext
}

private func runInspectCommand(_ args: [String]) async throws -> Data {
    try checkSubcommandHelp(args, command: "inspect")
    var targetPath: String?
    var includeAudioPackets = false
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--include-audio-packets":
            includeAudioPackets = true
        default:
            if a.hasPrefix("-") {
                throw CLIUsageError("unknown option for inspect: \(a)")
            }
            if targetPath == nil {
                targetPath = a
            } else {
                throw CLIUsageError("unexpected positional argument for inspect: \(a)")
            }
        }
        i += 1
    }
    guard let targetPath, !targetPath.isEmpty else {
        throw CLIUsageError("inspect requires <file-or-volume-path>")
    }

    let url = URL(fileURLWithPath: targetPath)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
        throw SafariumError.invalidState("inspect target does not exist: \(url.path)")
    }
    let vol = try APFSAutoStage.inspectVolume(at: url)
    if isDir.boolValue {
        return try encodeJSON(InspectCLIReport(
            path: url.path, kind: "volume", bytes: nil, volume: vol,
            mkv: nil, mpegts: nil, media: nil, audio: nil, image: nil
        ))
    }

    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    let fileBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    let ext = url.pathExtension.lowercased()
    let detected = detectContainerKind(url: url, ext: ext)

    if detected == "mkv" || detected == "webm" {
        let rep = try EBMLMatroskaCodec.inspect(url: url)
        return try encodeJSON(InspectCLIReport(
            path: url.path, kind: rep.docType, bytes: fileBytes, volume: vol,
            mkv: rep, mpegts: nil, media: nil, audio: nil, image: nil
        ))
    }
    if detected == "ts" || detected == "m2ts" {
        let rep = try MPEGTSCodec.inspect(url: url)
        return try encodeJSON(InspectCLIReport(
            path: url.path, kind: "ts", bytes: fileBytes, volume: vol,
            mkv: nil, mpegts: rep, media: nil, audio: nil, image: nil
        ))
    }
    if detected == "ogg" {
        let oggRep = try OggContainer.inspect(url: url)
        let vorbisInfo = (oggRep.streams.first?.codec == .vorbis) ? (try? OggVorbisDecoder.probe(url: url)) : nil
        return try encodeJSON(InspectCLIReport(
            path: url.path, kind: "ogg", bytes: fileBytes, volume: vol,
            ogg: oggRep, vorbis: vorbisInfo
        ))
    }
    if detected == "mpeg2ps" {
        let psRep = try MPEG2ProgramStream.inspect(url: url)
        return try encodeJSON(InspectCLIReport(
            path: url.path, kind: "mpeg2ps", bytes: fileBytes, volume: vol,
            mpeg2ps: psRep
        ))
    }

    let imageExts: Set<String> = ["webp", "avif", "heic", "heics", "png", "jpg", "jpeg", "gif", "tiff", "bmp"]
    if imageExts.contains(ext), let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
        let count = CGImageSourceGetCount(src)
        if count > 0, let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            let uti = CGImageSourceGetType(src) as String?
            let hasAlpha = cg.alphaInfo != .none && cg.alphaInfo != .noneSkipFirst && cg.alphaInfo != .noneSkipLast
            let imgInfo = ImageInspectInfo(uti: uti, width: cg.width, height: cg.height, frameCount: count, hasAlpha: hasAlpha)
            return try encodeJSON(InspectCLIReport(
                path: url.path, kind: "image", bytes: fileBytes, volume: vol,
                mkv: nil, mpegts: nil, media: nil, audio: nil, image: imgInfo
            ))
        }
    }

    do {
        let media = try await PacketProbe.inspect(url: url, includeAudioPackets: includeAudioPackets)
        if !media.tracks.isEmpty {
            return try encodeJSON(InspectCLIReport(
                path: url.path, kind: "media", bytes: fileBytes, volume: vol,
                mkv: nil, mpegts: nil, media: media, audio: nil, image: nil
            ))
        }
    } catch {
        // Fall through to AudioToolbox inspection when AVURLAsset cannot parse audio-only containers (e.g., FLAC/CAF).
    }

    var chunkFrames = 0
    let decInfo = try MediaCompatBridge.streamAudioToFloat32PCM(url: url, sampleRate: 48_000, channels: 2) { _, n in
        chunkFrames += n
    }
    let aInfo = AudioInspectInfo(
        sampleRate: decInfo.sampleRate,
        channels: decInfo.channels,
        frameCount: chunkFrames,
        sourceSampleRate: decInfo.sourceSampleRate,
        sourceChannels: decInfo.sourceChannels,
        durationSeconds: Double(chunkFrames) / decInfo.sampleRate
    )
    return try encodeJSON(InspectCLIReport(
        path: url.path, kind: "audio", bytes: fileBytes, volume: vol,
        mkv: nil, mpegts: nil, media: nil, audio: aInfo, image: nil
    ))
}

// MARK: - Subcommand: image

private func parseImageOutputFormat(_ ext: String) throws -> ContainerFormat {
    switch ext.lowercased() {
    case "webp": return .webp
    case "avif": return .avif
    case "heic": return .heic
    case "heics": return .heics
    case "png": return .png
    case "jpg", "jpeg": return .jpg
    default:
        throw CLIUsageError("unsupported image output format '\(ext)' (expected webp|avif|heic|heics|png|jpg)")
    }
}

private func runImageCommand(_ args: [String]) async throws -> Data {
    try checkSubcommandHelp(args, command: "image")
    var inputPath: String?
    var outputPath: String?
    var quality: Double?
    var fps: Int?
    var framesLimit: Int?
    var loopCount = 0
    var startSeconds = 0.0
    var overwrite = false
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "-o", "--output", "--out":
            outputPath = try nextValue(args, index: &i, flag: a)
        case "--quality":
            quality = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--fps":
            fps = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--frames":
            framesLimit = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--loop":
            loopCount = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--start":
            startSeconds = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--overwrite":
            overwrite = true
        default:
            if a.hasPrefix("-") {
                throw CLIUsageError("unknown option for image: \(a)")
            }
            if inputPath == nil {
                inputPath = a
            } else {
                throw CLIUsageError("unexpected positional argument for image: \(a)")
            }
        }
        i += 1
    }
    guard let inputPath, let outputPath else {
        throw CLIUsageError("image requires <input-image-or-video> and -o <output>")
    }

    let inURL = URL(fileURLWithPath: inputPath)
    let outURL = URL(fileURLWithPath: outputPath)
    let fmt = try parseImageOutputFormat(outURL.pathExtension)
    let videoExts: Set<String> = ["mp4", "mov", "m4v", "mkv", "webm", "ts", "m2ts"]
    let inExt = inURL.pathExtension.lowercased()

    if !videoExts.contains(inExt),
       let src = CGImageSourceCreateWithURL(inURL as CFURL, nil),
       let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        if fmt == .heics {
            let rep = try WebPAVIFEncoder.writeHEICSSequence(
                images: [cg], quality: quality ?? 0.85, loopCount: loopCount, to: outURL, overwrite: overwrite
            )
            return try encodeJSON(rep)
        }
        let rep = try WebPAVIFEncoder.writeStillImage(
            cgImage: cg, format: fmt, quality: quality, to: outURL, overwrite: overwrite
        )
        return try encodeJSON(rep)
    }

    // Video input -> still frame or animated lossless WebP / HEICS sequence
    return try await withPlayableVideoURL(inputURL: inURL) { playableURL in
        let reader = try await SafariumSequentialVideoReader(
            url: playableURL, loop: false, startTimeOffset: max(0, startSeconds), pixelFormat: kCVPixelFormatType_32BGRA
        )
        defer { reader.close() }

        let targetFPS = max(1, min(60, fps ?? max(1, Int(reader.nominalFPS.rounded()))))
        let isAnimatedTarget = (fmt == .webp || fmt == .heics)
        let defaultCount = isAnimatedTarget ? min(120, max(1, Int(((reader.durationSeconds - startSeconds) * Double(targetFPS)).rounded()))) : 1
        let count = max(1, framesLimit ?? defaultCount)
        if fmt == .avif && count > 1 {
            throw SafariumError.encode("animated AVIF is unsupported by macOS ImageIO; use animated lossless .webp or .heics")
        }

        let ciCtx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])
        var images: [CGImage] = []
        images.reserveCapacity(count)
        for idx in 0..<count {
            let t = Double(idx) / Double(targetFPS)
            guard let pb = try reader.pixelBuffer(at: t) else { break }
            let cg = try autoreleasepool { () -> CGImage in
                let ci = reader.orientedCIImage(from: pb)
                guard let rendered = ciCtx.createCGImage(ci, from: ci.extent, format: .BGRA8, colorSpace: Snapshot.colorSpace) else {
                    throw SafariumError.snapshot("failed rendering frame \(idx) to CGImage")
                }
                return rendered
            }
            images.append(cg)
        }
        guard let first = images.first else {
            throw SafariumError.snapshot("video produced 0 frames for image output")
        }

        let delayMs = max(10, Int((1000.0 / Double(targetFPS)).rounded()))
        let durations = Array(repeating: delayMs, count: images.count)
        switch fmt {
        case .webp:
            let rep = try WebPAVIFEncoder.writeLosslessWebP(
                images: images, to: outURL, loopCount: loopCount, overwrite: overwrite, frameDurationsMs: durations
            )
            return try encodeJSON(rep)
        case .heics:
            let rep = try WebPAVIFEncoder.writeHEICSSequence(
                images: images, quality: quality ?? 0.85, loopCount: loopCount, to: outURL, overwrite: overwrite, frameDurationsMs: durations
            )
            return try encodeJSON(rep)
        default:
            let rep = try WebPAVIFEncoder.writeStillImage(
                cgImage: first, format: fmt, quality: quality, to: outURL, overwrite: overwrite
            )
            return try encodeJSON(rep)
        }
    }
}

// MARK: - Subcommand: audio

private func parseEQSpec(_ spec: String) throws -> ForgeBiquadSection {
    let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2, let freq = Double(parts[1]), freq.isFinite, freq > 0 else {
        throw CLIUsageError("invalid --eq spec '\(spec)' (expected mode:freqHz[:q[:gainDB]])")
    }
    let q = (parts.count >= 3 && !parts[2].isEmpty) ? (Double(parts[2]) ?? 0.70710678) : 0.70710678
    let gain = (parts.count >= 4 && !parts[3].isEmpty) ? (Double(parts[3]) ?? 0.0) : 0.0
    return ForgeBiquadSection(mode: ForgeBiquadMode.parse(parts[0]), freqHz: freq, q: q, gainDB: gain)
}

private func runAudioCommand(_ args: [String], progressEmitter: SafariumProgressEmitter? = nil) async throws -> Data {
    try checkSubcommandHelp(args, command: "audio")
    guard let action = args.first else {
        throw CLIUsageError("audio requires action: process|crossfade|silence-trim|waveform|synth|split-mp3")
    }
    let rest = Array(args.dropFirst())
    progressEmitter?.emitStart(stage: "audio_\(action)")

    func executeAudioAction() async throws -> Data {
    switch action {
    case "process":
        var inputPath: String?
        var outputPath: String?
        var eqSections: [ForgeBiquadSection] = []
        var compThresh: Double?
        var compRatio = 4.0
        var gainDB = 0.0
        var lufs: Double?
        var peakDBTP = -1.05
        var sampleRate = 48_000.0
        var channels = 2
        var bitrate = 192_000
        var overwrite = false
        var i = 0
        while i < rest.count {
            let a = rest[i]
            switch a {
            case "-o", "--output", "--out": outputPath = try nextValue(rest, index: &i, flag: a)
            case "--eq": eqSections.append(try parseEQSpec(try nextValue(rest, index: &i, flag: a)))
            case "--comp-thresh": compThresh = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--comp-ratio": compRatio = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--gain": gainDB = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--lufs", "--target-lufs", "--normalize-lufs":
                lufs = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--peak-dbtp", "--peak-ceiling":
                peakDBTP = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--sr", "--sample-rate":
                sampleRate = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--channels":
                channels = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--bitrate":
                bitrate = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--overwrite": overwrite = true
            default:
                if a.hasPrefix("-") { throw CLIUsageError("unknown option for audio process: \(a)") }
                if inputPath == nil { inputPath = a } else { throw CLIUsageError("unexpected arg: \(a)") }
            }
            i += 1
        }
        guard let inputPath, let outputPath else {
            throw CLIUsageError("audio process requires <input> and -o <output>")
        }
        let rep = try await ForgeAudioDSP.processAudio(
            inputURL: URL(fileURLWithPath: inputPath),
            outputURL: URL(fileURLWithPath: outputPath),
            eqSections: eqSections,
            compressorThresholdDB: compThresh,
            compressorRatio: compRatio,
            gainDB: gainDB,
            normalizeLUFS: lufs,
            peakCeilingDBTP: peakDBTP,
            sampleRate: sampleRate,
            channels: channels,
            bitrate: bitrate,
            overwrite: overwrite
        )
        return try encodeJSON(rep)

    case "crossfade":
        var firstPath: String?
        var secondPath: String?
        var outputPath: String?
        var duration = 0.5
        var curve = "eqpower"
        var sampleRate = 48_000.0
        var channels = 2
        var overwrite = false
        var i = 0
        while i < rest.count {
            let a = rest[i]
            switch a {
            case "-o", "--output", "--out": outputPath = try nextValue(rest, index: &i, flag: a)
            case "--duration": duration = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--curve": curve = try nextValue(rest, index: &i, flag: a)
            case "--sr", "--sample-rate": sampleRate = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--channels": channels = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--overwrite": overwrite = true
            default:
                if a.hasPrefix("-") { throw CLIUsageError("unknown option for audio crossfade: \(a)") }
                if firstPath == nil { firstPath = a }
                else if secondPath == nil { secondPath = a }
                else { throw CLIUsageError("unexpected arg: \(a)") }
            }
            i += 1
        }
        guard let firstPath, let secondPath, let outputPath else {
            throw CLIUsageError("audio crossfade requires <first> <second> -o <output>")
        }
        let rep = try await ForgeAudioDSP.crossfadeAudio(
            firstURL: URL(fileURLWithPath: firstPath),
            secondURL: URL(fileURLWithPath: secondPath),
            durationSeconds: duration,
            curve: curve,
            sampleRate: sampleRate,
            channels: channels,
            outputURL: URL(fileURLWithPath: outputPath),
            overwrite: overwrite
        )
        return try encodeJSON(rep)

    case "silence-trim":
        var inputPath: String?
        var outputPath: String?
        var thresholdDB = -42.0
        var paddingSec = 0.05
        var sampleRate = 48_000.0
        var channels = 2
        var overwrite = false
        var i = 0
        while i < rest.count {
            let a = rest[i]
            switch a {
            case "-o", "--output", "--out": outputPath = try nextValue(rest, index: &i, flag: a)
            case "--threshold-db", "--threshold": thresholdDB = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--padding": paddingSec = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--sr", "--sample-rate": sampleRate = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--channels": channels = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--overwrite": overwrite = true
            default:
                if a.hasPrefix("-") { throw CLIUsageError("unknown option for audio silence-trim: \(a)") }
                if inputPath == nil { inputPath = a } else { throw CLIUsageError("unexpected arg: \(a)") }
            }
            i += 1
        }
        guard let inputPath, let outputPath else {
            throw CLIUsageError("audio silence-trim requires <input> and -o <output>")
        }
        let rep = try await ForgeAudioDSP.silenceTrim(
            inputURL: URL(fileURLWithPath: inputPath),
            outputURL: URL(fileURLWithPath: outputPath),
            thresholdDB: thresholdDB,
            paddingSeconds: paddingSec,
            sampleRate: sampleRate,
            channels: channels,
            overwrite: overwrite
        )
        return try encodeJSON(rep)

    case "waveform":
        var inputPath: String?
        var outputPath: String?
        var bins = 120
        var sampleRate = 8_000.0
        var overwrite = false
        var i = 0
        while i < rest.count {
            let a = rest[i]
            switch a {
            case "--bins", "--samples": bins = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--sr", "--sample-rate": sampleRate = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "-o", "--output", "--out": outputPath = try nextValue(rest, index: &i, flag: a)
            case "--overwrite": overwrite = true
            default:
                if a.hasPrefix("-") { throw CLIUsageError("unknown option for audio waveform: \(a)") }
                if inputPath == nil { inputPath = a } else { throw CLIUsageError("unexpected arg: \(a)") }
            }
            i += 1
        }
        guard let inputPath else {
            throw CLIUsageError("audio waveform requires <input>")
        }
        let rep = try await ForgeAudioDSP.extractWaveform(
            inputURL: URL(fileURLWithPath: inputPath), bins: bins, sampleRate: sampleRate
        )
        let data = try encodeJSON(rep)
        if let outputPath {
            let outURL = URL(fileURLWithPath: outputPath)
            let stage = try APFSAutoStage.makeSession(for: outURL, overwrite: overwrite)
            defer { stage.cleanup() }
            let staged = stage.fileURL("waveform.json")
            try data.write(to: staged)
            try stage.commit(stagedFile: staged, overwrite: overwrite)
        }
        return data

    case "synth":
        var outputPath: String?
        var waveform = "sine"
        var freq: Double? = 440.0
        var endFreq: Double?
        var carriers: [Double]?
        var modHz: Double?
        var modDepth: Double?
        var amp = 0.25
        var duration = 1.0
        var sampleRate = 48_000
        var channels = 2
        var fadeIn: Double?
        var fadeOut: Double?
        var overwrite = false
        var i = 0
        while i < rest.count {
            let a = rest[i]
            switch a {
            case "-o", "--output", "--out": outputPath = try nextValue(rest, index: &i, flag: a)
            case "--waveform": waveform = try nextValue(rest, index: &i, flag: a)
            case "--freq": freq = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--end-freq": endFreq = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--carriers":
                let raw = try nextValue(rest, index: &i, flag: a)
                carriers = try raw.split(separator: ",").map { s in
                    guard let v = Double(s.trimmingCharacters(in: .whitespaces)), v.isFinite else {
                        throw CLIUsageError("invalid carrier frequency '\(s)'")
                    }
                    return v
                }
            case "--mod-hz": modHz = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--mod-depth": modDepth = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--amp": amp = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--duration": duration = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--sr", "--sample-rate": sampleRate = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--channels": channels = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--fade-in": fadeIn = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--fade-out": fadeOut = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--overwrite": overwrite = true
            default:
                throw CLIUsageError("unknown option for audio synth: \(a)")
            }
            i += 1
        }
        guard let outputPath else {
            throw CLIUsageError("audio synth requires -o <output>")
        }
        let spec = ForgeAudioSynthSpec(
            waveform: waveform,
            frequencyHz: freq,
            endFrequencyHz: endFreq,
            carrierFrequenciesHz: carriers,
            modulationHz: modHz,
            modulationDepth: modDepth,
            amplitude: amp,
            durationSeconds: duration,
            sampleRate: sampleRate,
            channels: channels,
            fadeInSeconds: fadeIn,
            fadeOutSeconds: fadeOut
        )
        let rep = try await ForgeProceduralSynth.renderToFile(
            spec: spec, outputURL: URL(fileURLWithPath: outputPath), overwrite: overwrite
        )
        return try encodeJSON(rep)

    case "split-mp3":
        var inputPath: String?
        var outDirPath: String?
        var chunkSeconds = 1200.0
        var prefix = "chunk"
        var overwrite = false
        var i = 0
        while i < rest.count {
            let a = rest[i]
            switch a {
            case "--out-dir", "-o", "--output-dir", "--output":
                outDirPath = try nextValue(rest, index: &i, flag: a)
            case "--chunk-seconds", "--chunk-sec":
                chunkSeconds = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--prefix":
                prefix = try nextValue(rest, index: &i, flag: a)
            case "--overwrite":
                overwrite = true
            default:
                if a.hasPrefix("-") { throw CLIUsageError("unknown option for audio split-mp3: \(a)") }
                if inputPath == nil { inputPath = a } else { throw CLIUsageError("unexpected arg: \(a)") }
            }
            i += 1
        }
        guard let inputPath, let outDirPath else {
            throw CLIUsageError("audio split-mp3 requires <input.mp3> and --out-dir <dir>")
        }
        let rep = try MediaCompatBridge.splitMP3PacketsLosslessly(
            inputURL: URL(fileURLWithPath: inputPath),
            outputDir: URL(fileURLWithPath: outDirPath, isDirectory: true),
            chunkSeconds: chunkSeconds,
            prefix: prefix,
            overwrite: overwrite
        )
        return try encodeJSON(rep)

    default:
        throw CLIUsageError("unknown audio action '\(action)' (expected process|crossfade|silence-trim|waveform|synth|split-mp3)")
    }
    }
    let out = try await executeAudioAction()
    progressEmitter?.emitComplete(stage: "audio_\(action)")
    return out
}

// MARK: - Subcommands: sheet, compare, pq, qa

private func runSheetCommand(_ args: [String]) async throws -> Data {
    try checkSubcommandHelp(args, command: "sheet")
    var inputPath: String?
    var outputPath: String?
    var manifestPath: String?
    var cols = 6
    var rows = 4
    var tileWidth = 270
    var tileHeight: Int?
    var padding = 8
    var bgHex = "#0F172A"
    var quality = 0.88
    var everyFrames: Int?
    var everySec: Double?
    var timestamps: [Double]?
    var overwrite = false
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "-o", "--output", "--out": outputPath = try nextValue(args, index: &i, flag: a)
        case "--manifest": manifestPath = try nextValue(args, index: &i, flag: a)
        case "--cols": cols = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--rows": rows = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--tile-width": tileWidth = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--tile-height": tileHeight = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--padding": padding = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--bg": bgHex = try nextValue(args, index: &i, flag: a)
        case "--quality": quality = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--every-frames": everyFrames = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--every-sec": everySec = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--timestamps":
            let raw = try nextValue(args, index: &i, flag: a)
            timestamps = try raw.split(separator: ",").map { part in
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                guard let v = Double(trimmed), v.isFinite else {
                    throw CLIUsageError("invalid timestamp '\(trimmed)' in --timestamps")
                }
                return v
            }
        case "--overwrite": overwrite = true
        default:
            if a.hasPrefix("-") { throw CLIUsageError("unknown option for sheet: \(a)") }
            if inputPath == nil { inputPath = a } else { throw CLIUsageError("unexpected arg: \(a)") }
        }
        i += 1
    }
    guard let inputPath, let outputPath else {
        throw CLIUsageError("sheet requires <input> and -o <output>")
    }

    let sampling: ForgeSheetSampling
    if let ts = timestamps {
        sampling = .timestamps(ts)
    } else if let ef = everyFrames {
        sampling = .everyFrames(ef)
    } else if let es = everySec {
        sampling = .everySeconds(es)
    } else {
        sampling = .uniformCount(nil)
    }

    let outURL = URL(fileURLWithPath: outputPath)
    let cfg = ForgeContactSheetConfig(
        cols: cols,
        rows: rows,
        tileWidth: tileWidth,
        tileHeight: tileHeight,
        padding: padding,
        bgColorHex: bgHex,
        sampling: sampling,
        format: outURL.pathExtension.isEmpty ? "jpg" : outURL.pathExtension.lowercased(),
        quality: quality
    )

    let report = try await withPlayableVideoURL(inputURL: URL(fileURLWithPath: inputPath)) { playable in
        try await ForgeSheetAndQA.generateContactSheet(
            inputURL: playable,
            outputURL: outURL,
            manifestURL: manifestPath.map { URL(fileURLWithPath: $0) },
            config: cfg,
            overwrite: overwrite
        )
    }
    return try encodeJSON(report)
}

private func runCompareCommand(_ args: [String]) async throws -> Data {
    try checkSubcommandHelp(args, command: "compare")
    var refPath: String?
    var candPath: String?
    var outputPath: String?
    var samples = 4
    var vertical = false
    var tileWidth = 360
    var padding = 8
    var bgHex = "#0F172A"
    var overwrite = false
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "-o", "--output", "--out": outputPath = try nextValue(args, index: &i, flag: a)
        case "--samples": samples = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--vertical": vertical = true
        case "--tile-width": tileWidth = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--padding": padding = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--bg": bgHex = try nextValue(args, index: &i, flag: a)
        case "--overwrite": overwrite = true
        default:
            if a.hasPrefix("-") { throw CLIUsageError("unknown option for compare: \(a)") }
            if refPath == nil { refPath = a }
            else if candPath == nil { candPath = a }
            else { throw CLIUsageError("unexpected arg: \(a)") }
        }
        i += 1
    }
    guard let refPath, let candPath, let outputPath else {
        throw CLIUsageError("compare requires <ref> <cand> -o <strip>")
    }

    let report = try await withPlayableVideoURL(inputURL: URL(fileURLWithPath: refPath)) { pRef in
        try await withPlayableVideoURL(inputURL: URL(fileURLWithPath: candPath)) { pCand in
            try await ForgeSheetAndQA.makeComparisonStrip(
                referenceURL: pRef,
                candidateURL: pCand,
                outputURL: URL(fileURLWithPath: outputPath),
                samples: samples,
                vertical: vertical,
                tileWidth: tileWidth,
                padding: padding,
                bgColorHex: bgHex,
                overwrite: overwrite
            )
        }
    }
    return try encodeJSON(report)
}

private func runPQCommand(_ args: [String]) async throws -> (data: Data, exitCode: Int32) {
    try checkSubcommandHelp(args, command: "pq")
    var refPath: String?
    var candPath: String?
    var samples = 12
    var thaiOCR = false
    var expectedThai: String?
    var minScore = 85.0
    var maxDE00P95 = 2.0
    var minMSSSIM = 0.97
    var strict = false
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--samples": samples = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--thai-ocr": thaiOCR = true
        case "--expected-thai": expectedThai = try nextValue(args, index: &i, flag: a)
        case "--min-score": minScore = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--max-de00-p95": maxDE00P95 = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--min-msssim": minMSSSIM = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--strict": strict = true
        default:
            if a.hasPrefix("-") { throw CLIUsageError("unknown option for pq: \(a)") }
            if refPath == nil { refPath = a }
            else if candPath == nil { candPath = a }
            else { throw CLIUsageError("unexpected arg: \(a)") }
        }
        i += 1
    }
    guard let refPath, let candPath else {
        throw CLIUsageError("pq requires <ref> <cand>")
    }

    let report = try await withPlayableVideoURL(inputURL: URL(fileURLWithPath: refPath)) { pRef in
        try await withPlayableVideoURL(inputURL: URL(fileURLWithPath: candPath)) { pCand in
            try await SafariumPQ.compareVideos(
                referenceURL: pRef,
                candidateURL: pCand,
                maxSamples: samples,
                checkThaiOCR: thaiOCR || expectedThai != nil,
                expectedThaiText: expectedThai,
                minScore: minScore,
                maxDeltaE00P95: maxDE00P95,
                minMSSSIM: minMSSSIM
            )
        }
    }
    let json = try encodeJSON(report)
    let code: Int32 = (strict && !report.passed) ? 1 : 0
    return (json, code)
}

private func runQACommand(_ args: [String]) async throws -> (data: Data, exitCode: Int32) {
    try checkSubcommandHelp(args, command: "qa")
    var inputPath: String?
    var refPath: String?
    var sheetPath: String?
    var cols: Int?
    var rows: Int?
    var tileWidth: Int?
    var sceneThreshold = 0.20
    var silenceThresholdDB = -50.0
    var thaiOCR = false
    var minScore = 85.0
    var maxDE00P95 = 2.0
    var strict = false
    var overwrite = false
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--ref": refPath = try nextValue(args, index: &i, flag: a)
        case "--contact-sheet": sheetPath = try nextValue(args, index: &i, flag: a)
        case "--cols": cols = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--rows": rows = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--tile-width": tileWidth = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--scene-threshold": sceneThreshold = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--silence-threshold-db": silenceThresholdDB = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--thai-ocr": thaiOCR = true
        case "--min-score": minScore = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--max-de00-p95": maxDE00P95 = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--strict": strict = true
        case "--overwrite": overwrite = true
        default:
            if a.hasPrefix("-") { throw CLIUsageError("unknown option for qa: \(a)") }
            if inputPath == nil { inputPath = a } else { throw CLIUsageError("unexpected arg: \(a)") }
        }
        i += 1
    }
    guard let inputPath else {
        throw CLIUsageError("qa requires <input>")
    }

    let sheetURL = sheetPath.map { URL(fileURLWithPath: $0) }
    let sheetCfg: ForgeContactSheetConfig? = (cols != nil || rows != nil || tileWidth != nil || (sheetURL?.pathExtension.lowercased() ?? "jpg") != "jpg")
        ? ForgeContactSheetConfig(
            cols: cols ?? 6,
            rows: rows ?? 4,
            tileWidth: tileWidth ?? 270,
            format: sheetURL?.pathExtension.lowercased() ?? "jpg"
        )
        : nil

    let report = try await withPlayableVideoURL(inputURL: URL(fileURLWithPath: inputPath)) { playable in
        if let refPath {
            return try await withPlayableVideoURL(inputURL: URL(fileURLWithPath: refPath)) { pRef in
                try await ForgeSheetAndQA.runQA(
                    inputURL: playable,
                    referenceURL: pRef,
                    contactSheetURL: sheetURL,
                    sheetConfig: sheetCfg,
                    sceneThreshold: sceneThreshold,
                    silenceThresholdDB: silenceThresholdDB,
                    checkThaiOCR: thaiOCR,
                    minPQScore: minScore,
                    maxDeltaE00P95: maxDE00P95,
                    overwrite: overwrite
                )
            }
        }
        return try await ForgeSheetAndQA.runQA(
            inputURL: playable,
            referenceURL: nil,
            contactSheetURL: sheetURL,
            sheetConfig: sheetCfg,
            sceneThreshold: sceneThreshold,
            silenceThresholdDB: silenceThresholdDB,
            checkThaiOCR: thaiOCR,
            minPQScore: minScore,
            maxDeltaE00P95: maxDE00P95,
            overwrite: overwrite
        )
    }
    let json = try encodeJSON(report)
    return (json, (strict && !report.passed) ? 1 : 0)
}

// MARK: - Subcommands: reframe, matte, pipe-encode, capabilities

private func runReframeCommand(_ args: [String]) async throws -> Data {
    try checkSubcommandHelp(args, command: "reframe")
    var inputPath: String?
    var outputPath: String?
    var aspect = "9:16"
    var detector: ForgeReframeDetector = .saliencyAndFace
    var ema = 0.14
    var hysteresis = 0.02
    var sceneCutThreshold = 0.20
    var resetOnCut = true
    var outputHeight: Int?
    var codec: VideoCodec = .h264
    var bitrate = 8_000_000
    var quality: Double?
    var overwrite = false
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "-o", "--output", "--out": outputPath = try nextValue(args, index: &i, flag: a)
        case "--aspect": aspect = try nextValue(args, index: &i, flag: a)
        case "--detector": detector = try parseReframeDetector(try nextValue(args, index: &i, flag: a))
        case "--ema": ema = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--hysteresis": hysteresis = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--scene-cut-threshold": sceneCutThreshold = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--no-reset-on-cut": resetOnCut = false
        case "--height": outputHeight = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--codec": codec = try parseCodec(try nextValue(args, index: &i, flag: a))
        case "--bitrate": bitrate = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--quality": quality = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--overwrite": overwrite = true
        default:
            if a.hasPrefix("-") { throw CLIUsageError("unknown option for reframe: \(a)") }
            if inputPath == nil { inputPath = a } else { throw CLIUsageError("unexpected arg: \(a)") }
        }
        i += 1
    }
    guard let inputPath, let outputPath else {
        throw CLIUsageError("reframe requires <input> and -o <output>")
    }

    let report = try await withPlayableVideoURL(inputURL: URL(fileURLWithPath: inputPath)) { playable in
        try await ForgeAutoReframe.reframeVideo(
            inputURL: playable,
            aspect: aspect,
            detector: detector,
            emaAlpha: ema,
            hysteresis: hysteresis,
            sceneCutThreshold: sceneCutThreshold,
            resetOnSceneCut: resetOnCut,
            outputHeight: outputHeight,
            codec: codec,
            bitrate: bitrate,
            quality: quality,
            outputURL: URL(fileURLWithPath: outputPath),
            overwrite: overwrite
        )
    }
    return try encodeJSON(report)
}

private func runMatteCommand(_ args: [String]) async throws -> Data {
    try checkSubcommandHelp(args, command: "matte")
    var inputPath: String?
    var outputPath: String?
    var mode: ForgeMatteMode = .personBalanced
    var ema = 0.35
    var bgHex: String?
    var bgImagePath: String?
    var codec: VideoCodec = .hevcAlpha
    var maskOnly = false
    var bitrate = 10_000_000
    var quality: Double?
    var maxFrames: Int?
    var overwrite = false
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "-o", "--output", "--out": outputPath = try nextValue(args, index: &i, flag: a)
        case "--mode": mode = try parseMatteMode(try nextValue(args, index: &i, flag: a))
        case "--ema": ema = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--bg": bgHex = try nextValue(args, index: &i, flag: a)
        case "--bg-image": bgImagePath = try nextValue(args, index: &i, flag: a)
        case "--codec": codec = try parseCodec(try nextValue(args, index: &i, flag: a))
        case "--mask-only": maskOnly = true
        case "--bitrate": bitrate = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--quality": quality = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--max-frames": maxFrames = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--overwrite": overwrite = true
        default:
            if a.hasPrefix("-") { throw CLIUsageError("unknown option for matte: \(a)") }
            if inputPath == nil { inputPath = a } else { throw CLIUsageError("unexpected arg: \(a)") }
        }
        i += 1
    }
    guard let inputPath, let outputPath else {
        throw CLIUsageError("matte requires <input> and -o <output>")
    }

    let report = try await withPlayableVideoURL(inputURL: URL(fileURLWithPath: inputPath)) { playable in
        try await ForgePersonMatte.matteVideo(
            inputURL: playable,
            mode: mode,
            temporalEMA: ema,
            replaceBgHex: bgHex,
            replaceBgImageURL: bgImagePath.map { URL(fileURLWithPath: $0) },
            codec: codec,
            maskOnly: maskOnly,
            bitrate: bitrate,
            quality: quality,
            maxFrames: maxFrames,
            outputURL: URL(fileURLWithPath: outputPath),
            overwrite: overwrite
        )
    }
    return try encodeJSON(report)
}

private func runPipeEncodeCommand(_ args: [String], progressEmitter: SafariumProgressEmitter? = nil) async throws -> Data {
    try checkSubcommandHelp(args, command: "pipe-encode")
    var width: Int?
    var height: Int?
    var fps: Int?
    var pixFmt: ForgeRawPixelFormat = .bgra
    var vflip = false
    var primaryCodec: VideoCodec = .h264
    var primaryAudioCodec = "aac"
    var bitrate = 8_000_000
    var quality: Double?
    var outputPath: String?
    var secondaryPath: String?
    var secondaryCodec: VideoCodec?
    var secondaryBg = "#000000"
    var secondaryBitrate = 8_000_000
    var secondaryQuality: Double?
    var audioPath: String?
    var subtitlesPath: String?
    var subtitleLang = "tha"
    var maxFrames: Int?
    var closedGOP = true
    var inlineSheetPath: String?
    var inlineSheetCols = 6
    var inlineSheetRows = 4
    var inlineSheetTileWidth = 320
    var overwrite = false
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--width": width = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--height": height = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--fps": fps = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--pix-fmt": pixFmt = try ForgeRawPixelFormat.parse(try nextValue(args, index: &i, flag: a))
        case "--vflip": vflip = true
        case "--codec": primaryCodec = try parseCodec(try nextValue(args, index: &i, flag: a))
        case "--primary-audio-codec": primaryAudioCodec = try nextValue(args, index: &i, flag: a).lowercased()
        case "--bitrate": bitrate = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--quality": quality = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "-o", "--output", "--out": outputPath = try nextValue(args, index: &i, flag: a)
        case "--secondary": secondaryPath = try nextValue(args, index: &i, flag: a)
        case "--secondary-codec":
            secondaryCodec = try parseCodec(try nextValue(args, index: &i, flag: a), flag: "--secondary-codec")
        case "--secondary-bg": secondaryBg = try nextValue(args, index: &i, flag: a)
        case "--secondary-bitrate": secondaryBitrate = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--secondary-quality": secondaryQuality = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--audio": audioPath = try nextValue(args, index: &i, flag: a)
        case "--subtitles": subtitlesPath = try nextValue(args, index: &i, flag: a)
        case "--lang", "--subtitle-lang": subtitleLang = try nextValue(args, index: &i, flag: a)
        case "--max-frames": maxFrames = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--inline-sheet": inlineSheetPath = try nextValue(args, index: &i, flag: a)
        case "--sheet-cols", "--cols": inlineSheetCols = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--sheet-rows", "--rows": inlineSheetRows = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--tile-width": inlineSheetTileWidth = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--no-closed-gop": closedGOP = false
        case "--overwrite": overwrite = true
        default:
            throw CLIUsageError("unknown option for pipe-encode: \(a)")
        }
        i += 1
    }
    guard let width, let height, let fps, let outputPath else {
        throw CLIUsageError("pipe-encode requires --width, --height, --fps, and -o <primary>")
    }
    guard ["aac", "pcm_s16le", "copy"].contains(primaryAudioCodec) else {
        throw CLIUsageError("--primary-audio-codec must be aac|pcm_s16le|copy, got '\(primaryAudioCodec)'")
    }

    let secURL = secondaryPath.map { URL(fileURLWithPath: $0) }
    let resolvedSecCodec: VideoCodec? = secondaryCodec ?? secURL.map {
        $0.pathExtension.lowercased() == "mov" ? .proRes4444 : .h264
    }
    let sheetCfg: ForgeContactSheetConfig? = inlineSheetPath != nil
        ? ForgeContactSheetConfig(cols: inlineSheetCols, rows: inlineSheetRows, tileWidth: inlineSheetTileWidth)
        : nil
    let config = ForgePipeEncodeConfig(
        width: width,
        height: height,
        fps: fps,
        inputPixelFormat: pixFmt,
        primaryCodec: primaryCodec,
        primaryBitrate: bitrate,
        primaryQuality: quality,
        secondaryOutputURL: secURL,
        secondaryCodec: resolvedSecCodec,
        secondaryBitrate: secondaryBitrate,
        secondaryQuality: secondaryQuality,
        secondaryBackgroundHex: secondaryBg,
        audioURL: audioPath.map { URL(fileURLWithPath: $0) },
        subtitlesURL: subtitlesPath.map { URL(fileURLWithPath: $0) },
        subtitleLang: subtitleLang,
        closedGOP: closedGOP,
        maxFrames: maxFrames,
        vflip: vflip,
        overwrite: overwrite,
        primaryAudioCodec: primaryAudioCodec,
        inlineSheetConfig: sheetCfg,
        inlineSheetOutputURL: inlineSheetPath.map { URL(fileURLWithPath: $0) }
    )
    progressEmitter?.emitStart(stage: "pipe_encode", total: maxFrames ?? 0)
    let report = try await ForgeSheetAndQA.pipeEncode(
        from: FileHandle.standardInput,
        primaryOutputURL: URL(fileURLWithPath: outputPath),
        config: config
    )
    progressEmitter?.emitComplete(stage: "pipe_encode", total: report.frames)
    return try encodeJSON(report)
}

private struct CodecSupportEntry: Codable {
    let name: String
    let fourCC: String
    let hardwareDecode: Bool
    let hardwareEncode: Bool
    let notes: String?
}

private struct AudioSupportEntry: Codable {
    let format: String
    let decode: Bool
    let encode: Bool
    let notes: String
}

private struct ImageIOSupportSummary: Codable {
    let avifWrite: Bool
    let heicWrite: Bool
    let heicsWrite: Bool
    let webpImageIOWrite: Bool
    let webpPureSwiftVP8LWrite: Bool
    let pngWrite: Bool
    let jpgWrite: Bool
    let notes: [String]
}

private struct MetalCapabilitySummary: Codable {
    let available: Bool
    let deviceName: String?
    let hasUnifiedMemory: Bool
    let recommendedMaxWorkingSetMiB: Double?
}

private struct CapabilitiesReport: Codable {
    let version: String
    let osVersion: String
    let videoToolbox: [CodecSupportEntry]
    let audioToolbox: [AudioSupportEntry]
    let imageIO: ImageIOSupportSummary
    let metal: MetalCapabilitySummary
    let aneVisionAvailable: Bool
    let volumes: [ForgeVolumeCapabilities]
    let osWalls: [String]
}

private func runCapabilitiesCommand(_ args: [String]) throws -> Data {
    try checkSubcommandHelp(args, command: "capabilities")
    MediaCompatBridge.registerSupplementalDecoders()

    let vtEntries: [(String, String, String?)] = [
        ("h264", "avc1", "Hardware decode & encode"),
        ("hevc", "hvc1", "Hardware decode & encode"),
        ("hevc-alpha", "muxa", "Premultiplied alpha HEVC in .mov"),
        ("prores4444", "ap4h", "ProRes 4444 straight alpha in .mov (fourCC ap4h / pr44)"),
        ("vp9", "vp09", "Hardware decode unlocked via VTRegisterSupplementalVideoDecoderIfAvailable + 12B vpcC FullBox; no VT encode"),
        ("av1", "av01", "Hardware decode on Apple Silicon; no VT stream encode"),
    ]
    let videoToolbox = vtEntries.map { name, fourCC, note in
        CodecSupportEntry(
            name: name,
            fourCC: fourCC,
            hardwareDecode: MediaCompatBridge.supportsHardwareDecode(fourCC: fourCC),
            hardwareEncode: MediaCompatBridge.supportsHardwareEncode(fourCC: fourCC),
            notes: note
        )
    }

    let audioToolbox: [AudioSupportEntry] = [
        AudioSupportEntry(format: "aac", decode: true, encode: true, notes: "AudioToolbox AAC LC in .mp4/.m4a/.mov/.ts/.mkv"),
        AudioSupportEntry(format: "pcm_wav", decode: true, encode: true, notes: "16/24-bit integer & Float32 PCM"),
        AudioSupportEntry(format: "mp3", decode: true, encode: false, notes: "AudioToolbox decode + lossless AudioFile packet split; no MP3 encoder"),
        AudioSupportEntry(format: "flac", decode: true, encode: false, notes: "ExtAudioFile/AVAudioFile decode to Float32 PCM"),
        AudioSupportEntry(format: "caf_opus", decode: true, encode: false, notes: "ExtAudioFile decode .caf/.mp4 Opus to Float32 PCM"),
        AudioSupportEntry(format: "ogg_vorbis", decode: true, encode: false, notes: "Pure-Swift + vDSP Ogg Vorbis I streaming decode in SafariumContainers"),
        AudioSupportEntry(format: "ogg_flac", decode: true, encode: false, notes: "Pure-Swift Ogg page unwrap + AudioToolbox FLAC decode"),
        AudioSupportEntry(format: "ogg_opus", decode: false, encode: false, notes: "Unsupported container by Apple AudioToolbox (OSStatus 'fmt?')"),
        AudioSupportEntry(format: "mpeg2_ps", decode: true, encode: false, notes: "Pure-Swift ISO/IEC 13818-1 PS demux + VideoToolbox MPEG-1/2 decode"),
    ]

    let destUTIs = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
    let imageIO = ImageIOSupportSummary(
        avifWrite: destUTIs.contains("public.avif"),
        heicWrite: destUTIs.contains(UTType.heic.identifier),
        heicsWrite: destUTIs.contains("public.heics"),
        webpImageIOWrite: destUTIs.contains("org.webmproject.webp"),
        webpPureSwiftVP8LWrite: true,
        pngWrite: destUTIs.contains(UTType.png.identifier),
        jpgWrite: destUTIs.contains(UTType.jpeg.identifier),
        notes: [
            "ImageIO public.avif supports q < 1.0 (opaque & alpha); q == 1.0 lossless and multi-frame animated AVIF fail on macOS",
            "ImageIO WebP is read-only; SafariumContainers writes static VP8L and animated VP8X+ANIM+ANMF losslessly",
            "HEIC q == 1.0 is near-lossless (maxAbsDiff <= 2)",
        ]
    )

    let metalCtx = SafariumMetalContext.shared
    let metal = MetalCapabilitySummary(
        available: metalCtx != nil,
        deviceName: metalCtx?.device.name,
        hasUnifiedMemory: metalCtx?.device.hasUnifiedMemory ?? false,
        recommendedMaxWorkingSetMiB: metalCtx.map { Double($0.device.recommendedMaxWorkingSetSize) / (1024.0 * 1024.0) }
    )

    var volumePaths = [FileManager.default.currentDirectoryPath, "/tmp"]
    if let extraVol = ProcessInfo.processInfo.environment["SAFARIUM_EXTRA_VOLUME"],
       !extraVol.isEmpty,
       FileManager.default.fileExists(atPath: extraVol) {
        volumePaths.append(extraVol)
    }
    var volumes: [ForgeVolumeCapabilities] = []
    for path in volumePaths {
        if let caps = try? APFSAutoStage.inspectVolume(at: URL(fileURLWithPath: path)) {
            volumes.append(caps)
        }
    }

    let osWalls = [
        "No VideoToolbox stream encoders for AV1 (av01) or VP9 (vp09)",
        "No AudioToolbox MP3 encoder (decode & lossless packet splitting supported)",
        "ImageIO rejects AVIF quality == 1.0 lossless and animated multi-frame AVIF",
        "ExtAudioFile rejects Ogg/Opus containers ('fmt?')",
        "Segmented HLS/CMAF fMP4 rejects embedded tx3g/wvtt (-11875); use file-based fMP4 + tx3g or sidecar .vtt",
        "ExFAT external volumes lack clonefile/RENAME_EXCL; handled via APFSAutoStage + SafeFilePublisher",
        "Safari WebCodecs AudioEncoder emits 39B/76B ESDS (Bug 302253); unwrap via MediaCompatBridge.unwrapWebCodecsESDS",
    ]

    let report = CapabilitiesReport(
        version: SafariumForgeModuleInfo.version,
        osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        videoToolbox: videoToolbox,
        audioToolbox: audioToolbox,
        imageIO: imageIO,
        metal: metal,
        aneVisionAvailable: AppleMacOSBackend.current.supportsANE,
        volumes: volumes,
        osWalls: osWalls
    )
    return try encodeJSON(report)
}

// MARK: - Subcommand: prism (Blender 5.2 + WebKit 3D + MetalFX + Anti-Lag)

private func parseDoubleCSV(_ raw: String, flag: String) throws -> [Double] {
    let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard !parts.isEmpty else {
        throw CLIUsageError("expected comma-separated numbers for \(flag)")
    }
    return try parts.map { try parseDouble($0, flag: flag) }
}

private func parseIntCSV(_ raw: String, flag: String) throws -> [Int] {
    let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard !parts.isEmpty else {
        throw CLIUsageError("expected comma-separated integers for \(flag)")
    }
    return try parts.map { try parseInt($0, flag: flag) }
}

private func tryConsumePrismPolicyAndGovernorFlag(
    _ flag: String,
    args: [String],
    index: inout Int,
    qualityPolicy: inout PrismQualityPolicy,
    governorConfig: inout PrismAntiLagConfig
) throws -> Bool {
    switch flag {
    case "--metalfx":
        qualityPolicy.useMetalFX = true
    case "--no-metalfx":
        qualityPolicy.useMetalFX = false
    case "--scale":
        qualityPolicy.scaleFactor = max(0.25, min(1.0, try parseDouble(try nextValue(args, index: &index, flag: flag), flag: flag)))
    case "--no-auto-verify":
        qualityPolicy.autoVerifyMetalFX = false
    case "--verify-every":
        qualityPolicy.verifyEveryNFrames = max(1, try parseInt(try nextValue(args, index: &index, flag: flag), flag: flag))
    case "--min-pq":
        qualityPolicy.minPQScore = try parseDouble(try nextValue(args, index: &index, flag: flag), flag: flag)
    case "--min-msssim":
        qualityPolicy.minMSSSIM = try parseDouble(try nextValue(args, index: &index, flag: flag), flag: flag)
    case "--max-de00-p95":
        qualityPolicy.maxDeltaE00P95 = try parseDouble(try nextValue(args, index: &index, flag: flag), flag: flag)
    case "--thai-ocr":
        qualityPolicy.checkThaiOCR = true
    case "--expected-thai":
        qualityPolicy.expectedThaiText = try nextValue(args, index: &index, flag: flag)
        qualityPolicy.checkThaiOCR = true
    case "--no-thai-shield":
        qualityPolicy.thaiShield1xOverlay = false
    case "--no-antilag":
        governorConfig.enabled = false
    default:
        return false
    }
    return true
}

@MainActor
private func runPrismCommand(_ args: [String], progressEmitter: SafariumProgressEmitter? = nil) async throws -> Data {
    guard let action = args.first else {
        throw CLIUsageError("prism requires <capabilities|sync-ir|preview-stills|render-web|render-blender|composite>")
    }
    if action == "--help" || action == "-h" || action == "help" {
        throw CLIDone.text((subcommandHelp["prism"] ?? globalHelp) + "\n")
    }
    let rest = Array(args.dropFirst())
    try checkSubcommandHelp(rest, command: "prism")
    HostApp.prepare()

    switch action {
    case "capabilities":
        guard rest.isEmpty else {
            throw CLIUsageError("prism capabilities takes no positional options")
        }
        let report = try await PrismHybridEngine.inspectCapabilities()
        return try encodeJSON(report)

    case "sync-ir":
        var blendPath: String?
        var glbPath: String?
        var irPath: String?
        var frame = 1
        var engine: PrismBlenderEngine = .eevee
        var exportAnimations = true
        var width: Int?
        var height: Int?
        var overwrite = false
        var i = 0
        while i < rest.count {
            let a = rest[i]
            switch a {
            case "--glb": glbPath = try nextValue(rest, index: &i, flag: a)
            case "--ir": irPath = try nextValue(rest, index: &i, flag: a)
            case "--frame": frame = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--engine": engine = try PrismBlenderEngine.parse(try nextValue(rest, index: &i, flag: a))
            case "--width": width = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--height": height = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--no-animations": exportAnimations = false
            case "--overwrite": overwrite = true
            default:
                if a.hasPrefix("-") { throw CLIUsageError("unknown option for prism sync-ir: \(a)") }
                if blendPath == nil { blendPath = a } else { throw CLIUsageError("unexpected arg: \(a)") }
            }
            i += 1
        }
        guard let blendPath, let glbPath, let irPath else {
            throw CLIUsageError("prism sync-ir requires <input.blend>, --glb <out.glb>, and --ir <out.ir.json>")
        }
        let report = try await PrismHybridEngine.syncFromBlender(
            blendURL: URL(fileURLWithPath: blendPath),
            outputGLBURL: URL(fileURLWithPath: glbPath),
            outputIRURL: URL(fileURLWithPath: irPath),
            frame: frame,
            engine: engine,
            exportAnimations: exportAnimations,
            width: width,
            height: height,
            overwrite: overwrite
        )
        return try encodeJSON(report)

    case "preview-stills":
        var inputPath: String?
        var outPath: String?
        var stillDirPath: String?
        var contactSheetPath: String?
        var tier: PrismPreviewTier = .auto
        var width = 1080
        var height = 1920
        var angles: [Double] = [0.0, 45.0, 90.0]
        var frames: [Int]?
        var cols: Int?
        var rows: Int?
        var tileWidth = 360
        var padding = 8
        var bgHex = "#0F172A"
        var stillFormat = "png"
        var engine: PrismBlenderEngine = .eevee
        var samples = 16
        var shmMethod: PrismSHMMethod = .bmpMmap
        var allowLoopbackHTTP = false
        var overwrite = false
        var i = 0
        while i < rest.count {
            let a = rest[i]
            switch a {
            case "-o", "--output", "--out": outPath = try nextValue(rest, index: &i, flag: a)
            case "--still-dir": stillDirPath = try nextValue(rest, index: &i, flag: a)
            case "--contact-sheet": contactSheetPath = try nextValue(rest, index: &i, flag: a)
            case "--tier": tier = try PrismPreviewTier.parse(try nextValue(rest, index: &i, flag: a))
            case "--width": width = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--height": height = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--angles": angles = try parseDoubleCSV(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--frames": frames = try parseIntCSV(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--cols": cols = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--rows": rows = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--tile-width": tileWidth = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--padding": padding = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--bg": bgHex = try nextValue(rest, index: &i, flag: a)
            case "--format": stillFormat = try nextValue(rest, index: &i, flag: a).lowercased()
            case "--engine": engine = try PrismBlenderEngine.parse(try nextValue(rest, index: &i, flag: a))
            case "--samples": samples = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--shm-method": shmMethod = try PrismSHMMethod.parse(try nextValue(rest, index: &i, flag: a))
            case "--allow-loopback-http": allowLoopbackHTTP = true
            case "--overwrite": overwrite = true
            default:
                if a.hasPrefix("-") { throw CLIUsageError("unknown option for prism preview-stills: \(a)") }
                if inputPath == nil { inputPath = a } else { throw CLIUsageError("unexpected arg: \(a)") }
            }
            i += 1
        }
        guard let inputPath else {
            throw CLIUsageError("prism preview-stills requires <input.(blend|glb|html)>")
        }
        if let outPath {
            let ext = URL(fileURLWithPath: outPath).pathExtension.lowercased()
            let sheetExts: Set<String> = ["png", "jpg", "jpeg", "webp", "avif", "heic"]
            if sheetExts.contains(ext) {
                if contactSheetPath == nil { contactSheetPath = outPath }
            } else if stillDirPath == nil {
                stillDirPath = outPath
            }
        }
        guard stillDirPath != nil || contactSheetPath != nil else {
            throw CLIUsageError("prism preview-stills requires -o <sheet.png|dir>, --still-dir, or --contact-sheet")
        }
        let resolvedInputURL = parseWebOrFileURL(inputPath)
        let report = try await PrismHybridEngine.previewStills(
            inputURL: resolvedInputURL,
            outputDir: stillDirPath.map { URL(fileURLWithPath: $0, isDirectory: true) },
            contactSheetURL: contactSheetPath.map { URL(fileURLWithPath: $0) },
            tier: tier,
            width: width,
            height: height,
            angles: angles,
            frames: frames,
            cols: cols,
            rows: rows,
            tileWidth: tileWidth,
            padding: padding,
            bgColorHex: bgHex,
            stillFormat: stillFormat,
            engine: engine,
            samples: samples,
            shmMethod: shmMethod,
            allowLoopbackHTTP: allowLoopbackHTTP,
            overwrite: overwrite
        )
        return try encodeJSON(report)

    case "render-web":
        var htmlPath: String?
        var outputPath: String?
        var width = 1080
        var height = 1920
        var fps = 30
        var outputFPS: Int?
        var frames = 30
        var startSeconds = 0.0
        var codec: VideoCodec = .h264
        var bitrate = 12_000_000
        var quality: Double?
        var transparent = false
        var overlayHTMLPath: String?
        var audioPath: String?
        var subtitlesPath: String?
        var subtitleLang = "tha"
        var secondaryPath: String?
        var secondaryCodec: VideoCodec?
        var qualityPolicy = PrismQualityPolicy()
        var governorConfig = PrismAntiLagConfig()
        var allowLoopbackHTTP = false
        var readyExpr: String?
        var initJS: String?
        var initFilePath: String?
        var seekExpr: String?
        var fontDirPath: String?
        var injectFontFaceCSS = true
        var grainIntensity: Double?
        var grainSize = 1.0
        var loudnormTargetI: Double?
        var loudnormTruePeak: Double?
        var audioPadToVideo = false
        var metalSVGFilters = false
        var preserveSharpText1x = true
        var readyTimeoutSeconds = 30.0
        var adaptiveWorkers = 1
        var budgetMB = 700.0
        var overwrite = false
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if try tryConsumePrismPolicyAndGovernorFlag(
                a, args: rest, index: &i, qualityPolicy: &qualityPolicy, governorConfig: &governorConfig
            ) {
                i += 1
                continue
            }
            switch a {
            case "-o", "--output", "--out": outputPath = try nextValue(rest, index: &i, flag: a)
            case "--width": width = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--height": height = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--fps": fps = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--output-fps": outputFPS = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--frames": frames = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--start": startSeconds = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--codec": codec = try parseCodec(try nextValue(rest, index: &i, flag: a))
            case "--bitrate": bitrate = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--quality": quality = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--transparent": transparent = true
            case "--overlay-html": overlayHTMLPath = try nextValue(rest, index: &i, flag: a)
            case "--audio": audioPath = try nextValue(rest, index: &i, flag: a)
            case "--subtitles": subtitlesPath = try nextValue(rest, index: &i, flag: a)
            case "--lang": subtitleLang = try nextValue(rest, index: &i, flag: a)
            case "--secondary": secondaryPath = try nextValue(rest, index: &i, flag: a)
            case "--secondary-codec": secondaryCodec = try parseCodec(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--allow-loopback-http": allowLoopbackHTTP = true
            case "--ready-expr": readyExpr = try nextValue(rest, index: &i, flag: a)
            case "--init-js": initJS = try nextValue(rest, index: &i, flag: a)
            case "--init-file": initFilePath = try nextValue(rest, index: &i, flag: a)
            case "--seek-expr": seekExpr = try nextValue(rest, index: &i, flag: a)
            case "--font-dir": fontDirPath = try nextValue(rest, index: &i, flag: a)
            case "--no-inject-fonts": injectFontFaceCSS = false
            case "--grain": grainIntensity = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--grain-size": grainSize = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--loudnorm": loudnormTargetI = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--true-peak": loudnormTruePeak = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--apad": audioPadToVideo = true
            case "--metal-svg-filters": metalSVGFilters = true
            case "--no-sharp-text-1x": preserveSharpText1x = false
            case "--ready-timeout": readyTimeoutSeconds = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--adaptive-workers": adaptiveWorkers = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--budget-mb": budgetMB = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--overwrite": overwrite = true
            default:
                if a.hasPrefix("-") { throw CLIUsageError("unknown option for prism render-web: \(a)") }
                if htmlPath == nil { htmlPath = a } else { throw CLIUsageError("unexpected arg: \(a)") }
            }
            i += 1
        }
        guard let htmlPath, let outputPath else {
            throw CLIUsageError("prism render-web requires <input.html> and -o <output>")
        }
        guard adaptiveWorkers >= 1 else {
            throw CLIUsageError("--adaptive-workers must be >= 1")
        }
        guard budgetMB >= 128 else {
            throw CLIUsageError("--budget-mb must be >= 128")
        }
        let webOptions = PrismWebRenderOptions(
            readyExpr: readyExpr,
            initJS: initJS,
            initFileURL: initFilePath.map { URL(fileURLWithPath: $0) },
            seekExpr: seekExpr,
            outputFPS: outputFPS,
            grainIntensity: grainIntensity,
            grainSize: grainSize,
            loudnormTargetI: loudnormTargetI,
            loudnormTruePeak: loudnormTruePeak,
            audioPadToVideo: audioPadToVideo,
            fontDirURL: fontDirPath.map { URL(fileURLWithPath: $0, isDirectory: true) },
            injectFontFaceCSS: injectFontFaceCSS,
            metalSVGFilters: metalSVGFilters,
            preserveSharpText1x: preserveSharpText1x,
            readyTimeoutSeconds: readyTimeoutSeconds
        )
        progressEmitter?.emitStart(stage: "prism_render_web", total: frames)
        if adaptiveWorkers > 1 {
            guard secondaryPath == nil else {
                throw CLIUsageError("prism render-web --adaptive-workers > 1 does not support dual --secondary output yet; use workers=1")
            }
            let outURL = URL(fileURLWithPath: outputPath)
            let targetFPS = outputFPS ?? fps
            let totalOutDur = Double(max(1, Int((Double(frames) * Double(targetFPS) / Double(max(1, fps))).rounded()))) / Double(max(1, targetFPS))
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("prism-adaptive-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmpDir) }

            var preparedAudioURL: URL?
            if let audioPath {
                let rawAudio = URL(fileURLWithPath: audioPath)
                try SafeFilePublisher.assertRegularReadableFile(rawAudio)
                if loudnormTargetI != nil || loudnormTruePeak != nil || audioPadToVideo {
                    let normWAV = tmpDir.appendingPathComponent("norm_audio.wav")
                    let mixTrack = AudioMixTrack(url: rawAudio, gainDB: 0.0, startSeconds: 0.0, loop: false)
                    let mixedWAV = tmpDir.appendingPathComponent("mixed_audio.wav")
                    _ = try await AudioMixer.mix(
                        tracks: [mixTrack],
                        to: mixedWAV,
                        durationSeconds: audioPadToVideo ? totalOutDur : nil,
                        sampleRate: 48_000,
                        channels: 2,
                        normalizeLUFS: loudnormTargetI,
                        peakCeilingDBTP: loudnormTruePeak ?? -1.5,
                        overwrite: true
                    )
                    if audioPadToVideo {
                        _ = try await ForgeAudioDSP.padOrTrim(
                            inputURL: mixedWAV,
                            outputURL: normWAV,
                            padToDurationSeconds: totalOutDur,
                            sampleRate: 48_000,
                            channels: 2,
                            overwrite: true
                        )
                        preparedAudioURL = normWAV
                    } else {
                        preparedAudioURL = mixedWAV
                    }
                } else {
                    preparedAudioURL = rawAudio
                }
            }

            let poolCfg = ForgeAdaptivePoolConfig(
                requestedWorkers: adaptiveWorkers,
                budgetMB: budgetMB,
                maxWorkersCeiling: 4,
                totalFrames: frames,
                fps: fps,
                chunkFrames: max(15, min(60, frames / max(1, adaptiveWorkers)))
            )
            let pool = try ForgeAdaptiveWebKitPool(config: poolCfg)
            let exePath = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "safarium-forge"
            let baseStart = startSeconds
            let fpsVal = max(1, fps)
            var sharedChildFlags: [String] = [
                "--width", String(width),
                "--height", String(height),
                "--fps", String(fps),
                "--codec", codec.cliName,
                "--bitrate", String(bitrate),
                "--adaptive-workers", "1",
                "--ready-timeout", String(readyTimeoutSeconds),
                "--overwrite",
            ]
            if let outputFPS { sharedChildFlags += ["--output-fps", String(outputFPS)] }
            if let quality { sharedChildFlags += ["--quality", String(quality)] }
            if transparent { sharedChildFlags.append("--transparent") }
            if let overlayHTMLPath { sharedChildFlags += ["--overlay-html", overlayHTMLPath] }
            if allowLoopbackHTTP { sharedChildFlags.append("--allow-loopback-http") }
            if let readyExpr { sharedChildFlags += ["--ready-expr", readyExpr] }
            if let initJS { sharedChildFlags += ["--init-js", initJS] }
            if let initFilePath { sharedChildFlags += ["--init-file", initFilePath] }
            if let seekExpr { sharedChildFlags += ["--seek-expr", seekExpr] }
            if let fontDirPath { sharedChildFlags += ["--font-dir", fontDirPath] }
            if !injectFontFaceCSS { sharedChildFlags.append("--no-inject-fonts") }
            if let grainIntensity {
                sharedChildFlags += ["--grain", String(grainIntensity), "--grain-size", String(grainSize)]
            }
            if metalSVGFilters { sharedChildFlags.append("--metal-svg-filters") }
            if !preserveSharpText1x { sharedChildFlags.append("--no-sharp-text-1x") }
            if qualityPolicy.useMetalFX {
                sharedChildFlags += ["--metalfx", "--scale", String(qualityPolicy.scaleFactor), "--verify-every", String(qualityPolicy.verifyEveryNFrames), "--min-pq", String(qualityPolicy.minPQScore)]
                if !qualityPolicy.autoVerifyMetalFX { sharedChildFlags.append("--no-auto-verify") }
                if qualityPolicy.checkThaiOCR { sharedChildFlags.append("--thai-ocr") }
                if let txt = qualityPolicy.expectedThaiText { sharedChildFlags += ["--expected-thai", txt] }
                if !qualityPolicy.thaiShield1xOverlay { sharedChildFlags.append("--no-thai-shield") }
            }
            if !governorConfig.enabled { sharedChildFlags.append("--no-antilag") }
            let frozenChildFlags = sharedChildFlags
            let htmlPathFrozen = htmlPath
            let poolReport = try await pool.runChunks(
                finalOutputURL: outURL,
                wavURL: preparedAudioURL,
                subtitlesURL: subtitlesPath.map { URL(fileURLWithPath: $0) },
                subtitleLang: subtitleLang,
                overwrite: overwrite
            ) { chunk, _, segURL in
                var childArgs = [
                    "prism", "render-web", htmlPathFrozen,
                    "-o", segURL.path,
                    "--start", String(format: "%.6f", baseStart + Double(chunk.startFrame) / Double(fpsVal)),
                    "--frames", String(chunk.frameCount),
                ]
                childArgs += frozenChildFlags
                try await runAdaptiveRenderChild(executablePath: exePath, arguments: childArgs, pool: pool)
            }
            progressEmitter?.emitComplete(stage: "prism_render_web", total: frames)
            return try encodeJSON(poolReport)
        }

        let report = try await PrismHybridEngine.renderWeb3D(
            htmlURL: parseWebOrFileURL(htmlPath),
            outputURL: URL(fileURLWithPath: outputPath),
            width: width,
            height: height,
            fps: fps,
            frames: frames,
            startSeconds: startSeconds,
            codec: codec,
            bitrate: bitrate,
            quality: quality,
            transparent: transparent,
            overlayHTMLURL: overlayHTMLPath.map { URL(fileURLWithPath: $0) },
            audioURL: audioPath.map { URL(fileURLWithPath: $0) },
            subtitlesURL: subtitlesPath.map { URL(fileURLWithPath: $0) },
            subtitleLang: subtitleLang,
            secondaryOutputURL: secondaryPath.map { URL(fileURLWithPath: $0) },
            secondaryCodec: secondaryCodec,
            qualityPolicy: qualityPolicy,
            governorConfig: governorConfig,
            allowLoopbackHTTP: allowLoopbackHTTP,
            overwrite: overwrite,
            options: webOptions
        )
        progressEmitter?.emitComplete(stage: "prism_render_web", total: report.frames)
        return try encodeJSON(report)

    case "render-blender":
        var blendPath: String?
        var outputPath: String?
        var irPath: String?
        var engine: PrismBlenderEngine = .eevee
        var shmMethod: PrismSHMMethod = .bmpMmap
        var samples = 16
        var width = 1080
        var height = 1920
        var fps = 30
        var startFrame = 1
        var frames = 30
        var filmTransparent = false
        var codec: VideoCodec = .h264
        var bitrate = 12_000_000
        var quality: Double?
        var overlayHTMLPath: String?
        var audioPath: String?
        var subtitlesPath: String?
        var subtitleLang = "tha"
        var secondaryPath: String?
        var secondaryCodec: VideoCodec?
        var qualityPolicy = PrismQualityPolicy()
        var governorConfig = PrismAntiLagConfig()
        var overwrite = false
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if try tryConsumePrismPolicyAndGovernorFlag(
                a, args: rest, index: &i, qualityPolicy: &qualityPolicy, governorConfig: &governorConfig
            ) {
                i += 1
                continue
            }
            switch a {
            case "-o", "--output", "--out": outputPath = try nextValue(rest, index: &i, flag: a)
            case "--ir": irPath = try nextValue(rest, index: &i, flag: a)
            case "--engine": engine = try PrismBlenderEngine.parse(try nextValue(rest, index: &i, flag: a))
            case "--shm-method": shmMethod = try PrismSHMMethod.parse(try nextValue(rest, index: &i, flag: a))
            case "--samples": samples = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--width": width = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--height": height = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--fps": fps = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--start-frame": startFrame = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--frames": frames = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--transparent": filmTransparent = true
            case "--codec": codec = try parseCodec(try nextValue(rest, index: &i, flag: a))
            case "--bitrate": bitrate = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--quality": quality = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--overlay-html": overlayHTMLPath = try nextValue(rest, index: &i, flag: a)
            case "--audio": audioPath = try nextValue(rest, index: &i, flag: a)
            case "--subtitles": subtitlesPath = try nextValue(rest, index: &i, flag: a)
            case "--lang": subtitleLang = try nextValue(rest, index: &i, flag: a)
            case "--secondary": secondaryPath = try nextValue(rest, index: &i, flag: a)
            case "--secondary-codec": secondaryCodec = try parseCodec(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--overwrite": overwrite = true
            default:
                if a.hasPrefix("-") { throw CLIUsageError("unknown option for prism render-blender: \(a)") }
                if blendPath == nil { blendPath = a } else { throw CLIUsageError("unexpected arg: \(a)") }
            }
            i += 1
        }
        guard let blendPath, let outputPath else {
            throw CLIUsageError("prism render-blender requires <input.blend> and -o <output>")
        }
        let report = try await PrismHybridEngine.renderBlenderAdaptive(
            blendURL: URL(fileURLWithPath: blendPath),
            outputURL: URL(fileURLWithPath: outputPath),
            irURL: irPath.map { URL(fileURLWithPath: $0) },
            engine: engine,
            shmMethod: shmMethod,
            samples: samples,
            width: width,
            height: height,
            fps: fps,
            startFrame: startFrame,
            frames: frames,
            filmTransparent: filmTransparent,
            codec: codec,
            bitrate: bitrate,
            quality: quality,
            overlayHTMLURL: overlayHTMLPath.map { URL(fileURLWithPath: $0) },
            audioURL: audioPath.map { URL(fileURLWithPath: $0) },
            subtitlesURL: subtitlesPath.map { URL(fileURLWithPath: $0) },
            subtitleLang: subtitleLang,
            secondaryOutputURL: secondaryPath.map { URL(fileURLWithPath: $0) },
            secondaryCodec: secondaryCodec,
            qualityPolicy: qualityPolicy,
            governorConfig: governorConfig,
            overwrite: overwrite
        )
        return try encodeJSON(report)

    case "composite":
        var blendPath: String?
        var bgHTMLPath: String?
        var bgGLBPath: String?
        var overlayHTMLPath: String?
        var outputPath: String?
        var secondaryMOVPath: String?
        var primaryCodec: VideoCodec = .h264
        var secondaryCodec: VideoCodec? = .proRes4444
        var width = 1080
        var height = 1920
        var fps = 30
        var startFrame = 1
        var frames = 15
        var blenderEngine: PrismBlenderEngine = .eevee
        var samples = 16
        var shmMethod: PrismSHMMethod = .bmpMmap
        var bitrate = 12_000_000
        var quality: Double?
        var audioPath: String?
        var subtitlesPath: String?
        var subtitleLang = "tha"
        var qualityPolicy = PrismQualityPolicy()
        var governorConfig = PrismAntiLagConfig()
        var overwrite = false
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if try tryConsumePrismPolicyAndGovernorFlag(
                a, args: rest, index: &i, qualityPolicy: &qualityPolicy, governorConfig: &governorConfig
            ) {
                i += 1
                continue
            }
            switch a {
            case "--bg-html": bgHTMLPath = try nextValue(rest, index: &i, flag: a)
            case "--bg-glb": bgGLBPath = try nextValue(rest, index: &i, flag: a)
            case "--overlay-html": overlayHTMLPath = try nextValue(rest, index: &i, flag: a)
            case "-o", "--output", "--out": outputPath = try nextValue(rest, index: &i, flag: a)
            case "--secondary-mov", "--secondary": secondaryMOVPath = try nextValue(rest, index: &i, flag: a)
            case "--primary-codec", "--codec": primaryCodec = try parseCodec(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--secondary-codec": secondaryCodec = try parseCodec(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--width": width = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--height": height = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--fps": fps = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--start-frame": startFrame = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--frames": frames = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--engine": blenderEngine = try PrismBlenderEngine.parse(try nextValue(rest, index: &i, flag: a))
            case "--samples": samples = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--shm-method": shmMethod = try PrismSHMMethod.parse(try nextValue(rest, index: &i, flag: a))
            case "--bitrate": bitrate = try parseInt(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--quality": quality = try parseDouble(try nextValue(rest, index: &i, flag: a), flag: a)
            case "--audio": audioPath = try nextValue(rest, index: &i, flag: a)
            case "--subtitles": subtitlesPath = try nextValue(rest, index: &i, flag: a)
            case "--lang": subtitleLang = try nextValue(rest, index: &i, flag: a)
            case "--overwrite": overwrite = true
            default:
                if a.hasPrefix("-") { throw CLIUsageError("unknown option for prism composite: \(a)") }
                if blendPath == nil { blendPath = a } else { throw CLIUsageError("unexpected arg: \(a)") }
            }
            i += 1
        }
        guard let blendPath, let outputPath else {
            throw CLIUsageError("prism composite requires <input.blend> and -o <output.mp4>")
        }
        let report = try await PrismHybridEngine.compositeHybrid(
            blendURL: URL(fileURLWithPath: blendPath),
            backgroundHTMLURL: bgHTMLPath.map { URL(fileURLWithPath: $0) },
            backgroundGLBURL: bgGLBPath.map { URL(fileURLWithPath: $0) },
            overlayHTMLURL: overlayHTMLPath.map { URL(fileURLWithPath: $0) },
            outputURL: URL(fileURLWithPath: outputPath),
            secondaryMOVURL: secondaryMOVPath.map { URL(fileURLWithPath: $0) },
            primaryCodec: primaryCodec,
            secondaryCodec: secondaryCodec,
            width: width,
            height: height,
            fps: fps,
            startFrame: startFrame,
            frames: frames,
            blenderEngine: blenderEngine,
            samples: samples,
            shmMethod: shmMethod,
            bitrate: bitrate,
            quality: quality,
            audioURL: audioPath.map { URL(fileURLWithPath: $0) },
            subtitlesURL: subtitlesPath.map { URL(fileURLWithPath: $0) },
            subtitleLang: subtitleLang,
            qualityPolicy: qualityPolicy,
            governorConfig: governorConfig,
            overwrite: overwrite
        )
        return try encodeJSON(report)

    default:
        throw CLIUsageError("unknown prism action '\(action)' (expected capabilities|sync-ir|preview-stills|render-web|render-blender|composite)")
    }
}

private func parseWebOrFileURL(_ raw: String) -> URL {
    if raw.hasPrefix("http://") || raw.hasPrefix("https://"), let url = URL(string: raw) {
        return url
    }
    return URL(fileURLWithPath: raw)
}

@MainActor
private func runDaemonCommand(_ args: [String]) async throws -> Data {
    try checkSubcommandHelp(args, command: "daemon")
    var socketPath: String?
    var idleTimeout = 20.0
    var cacheRootPath: String?
    var preloadPQ = true
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--socket": socketPath = try nextValue(args, index: &i, flag: a)
        case "--idle-timeout": idleTimeout = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--cache-root": cacheRootPath = try nextValue(args, index: &i, flag: a)
        case "--no-pq-preload": preloadPQ = false
        default:
            throw CLIUsageError("unknown option for daemon: \(a)")
        }
        i += 1
    }
    guard let socketPath else {
        throw CLIUsageError("daemon requires --socket <uds-path>")
    }
    let report = try await ForgeWarmDaemon.serve(
        socketPath: socketPath,
        idleTimeoutSeconds: idleTimeout,
        cacheRootURL: cacheRootPath.map { URL(fileURLWithPath: $0, isDirectory: true) },
        preloadPQEngine: preloadPQ
    )
    return try encodeJSON(report)
}

private func runRingEncodeCommand(_ args: [String]) async throws -> Data {
    try checkSubcommandHelp(args, command: "ring-encode")
    var socketPath: String?
    var idleTimeout = 30.0
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--socket": socketPath = try nextValue(args, index: &i, flag: a)
        case "--idle-timeout": idleTimeout = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        default:
            throw CLIUsageError("unknown option for ring-encode: \(a)")
        }
        i += 1
    }
    guard let socketPath else {
        throw CLIUsageError("ring-encode requires --socket <uds-path>")
    }
    let report = try await ForgeSharedRingServer.serve(
        socketPath: socketPath,
        idleTimeoutSeconds: idleTimeout
    )
    return try encodeJSON(report)
}

private enum CacheKindOption: String {
    case auto
    case scene
    case shot
}

private struct UnifiedCacheLookupReport: Codable {
    let key: String
    let hit: Bool
    let kind: String
    let cachedPath: String?
    let materializedPath: String?
    let usedClonefile: Bool
    let bytes: Int64
    let sha256: String?
    let wallMs: Double
}

private struct UnifiedCacheStatsReport: Codable {
    let cacheRoot: String
    let kind: String
    let entryCount: Int
    let totalBytes: Int64
    let shotEntryCount: Int
    let shotTotalBytes: Int64
    let sceneEntryCount: Int
    let sceneTotalBytes: Int64
}

private struct UnifiedCachePruneReport: Codable {
    let cacheRoot: String
    let kind: String
    let maxBytes: Int64
    let removedEntries: Int
    let freedBytes: Int64
    let remainingEntries: Int
    let remainingBytes: Int64
    let removedShotEntries: Int
    let removedSceneEntries: Int
}

private func runCacheCommand(_ args: [String]) throws -> Data {
    try checkSubcommandHelp(args, command: "cache")
    guard let sub = args.first else {
        throw CLIUsageError("cache requires <hash|store|lookup|stats|prune>")
    }
    let rest = Array(args.dropFirst())
    var namespace = "default"
    var paramsJSON = "{}"
    var inputCSV: String?
    var singleInputPath: String?
    var key: String?
    var destPath: String?
    var cacheRootPath: String?
    var maxBytes: Int64?
    var overwrite = false
    var cacheKind: CacheKindOption = .auto
    var i = 0
    while i < rest.count {
        let a = rest[i]
        switch a {
        case "--namespace": namespace = try nextValue(rest, index: &i, flag: a)
        case "--params": paramsJSON = try nextValue(rest, index: &i, flag: a)
        case "--inputs": inputCSV = try nextValue(rest, index: &i, flag: a)
        case "--input", "-i": singleInputPath = try nextValue(rest, index: &i, flag: a)
        case "--key": key = try nextValue(rest, index: &i, flag: a)
        case "-o", "--output", "--out": destPath = try nextValue(rest, index: &i, flag: a)
        case "--root": cacheRootPath = try nextValue(rest, index: &i, flag: a)
        case "--kind":
            let raw = try nextValue(rest, index: &i, flag: a).lowercased()
            guard let parsed = CacheKindOption(rawValue: raw) else {
                throw CLIUsageError("invalid --kind '\(raw)'; expected auto, scene, or shot")
            }
            cacheKind = parsed
        case "--max-bytes":
            let raw = try nextValue(rest, index: &i, flag: a)
            guard let v = Int64(raw) else { throw CLIUsageError("invalid integer for --max-bytes: \(raw)") }
            maxBytes = v
        case "--overwrite": overwrite = true
        default:
            throw CLIUsageError("unknown option for cache \(sub): \(a)")
        }
        i += 1
    }

    let rootURL = cacheRootPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
    switch sub {
    case "hash":
        var urls: [URL] = []
        if let singleInputPath { urls.append(URL(fileURLWithPath: singleInputPath)) }
        if let inputCSV {
            for p in inputCSV.split(separator: ",").map(String.init) where !p.isEmpty {
                urls.append(URL(fileURLWithPath: p))
            }
        }
        let digest = try ForgeShotCache.computeKey(namespace: namespace, paramsJSON: paramsJSON, inputURLs: urls)
        return try encodeJSON(["key": digest, "namespace": namespace])

    case "store":
        guard let singleInputPath else {
            throw CLIUsageError("cache store requires --input <file>")
        }
        let srcURL = URL(fileURLWithPath: singleInputPath)
        let resolvedKey: String
        if let key {
            resolvedKey = key
        } else {
            resolvedKey = try ForgeShotCache.computeKey(namespace: namespace, paramsJSON: paramsJSON, inputURLs: [srcURL])
        }
        let cache = try ForgeShotCache(rootURL: rootURL)
        let report = try cache.store(key: resolvedKey, sourceURL: srcURL, namespace: namespace)
        return try encodeJSON(report)

    case "lookup":
        guard let key else {
            throw CLIUsageError("cache lookup requires --key <hex>")
        }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let destURL = destPath.map { URL(fileURLWithPath: $0) }
        if cacheKind == .shot || cacheKind == .auto {
            let shotRoot = rootURL ?? ForgeShotCache.defaultRootURL()
            if cacheKind == .shot || FileManager.default.fileExists(atPath: shotRoot.path) {
                let cache = try ForgeShotCache(rootURL: rootURL)
                let report = try cache.lookup(key: key, destinationURL: destURL, overwrite: overwrite)
                if report.hit || cacheKind == .shot {
                    return try encodeJSON(UnifiedCacheLookupReport(
                        key: report.key,
                        hit: report.hit,
                        kind: report.hit ? "shot" : CacheKindOption.shot.rawValue,
                        cachedPath: report.hit ? shotRoot.appendingPathComponent("\(report.key).bin").path : nil,
                        materializedPath: report.materializedPath,
                        usedClonefile: report.usedClonefile,
                        bytes: report.bytes,
                        sha256: nil,
                        wallMs: report.wallMs
                    ))
                }
            }
        }
        if cacheKind == .scene || cacheKind == .auto {
            let sceneRoot = rootURL ?? ForgeIncrementalCache.defaultCacheRootURL()
            if cacheKind == .scene || rootURL != nil || FileManager.default.fileExists(atPath: sceneRoot.path) {
                let sceneReport = try ForgeIncrementalCache.lookupScene(
                    key: key,
                    destinationURL: destURL,
                    cacheRoot: rootURL,
                    overwrite: overwrite,
                    rejectCorrupt: true
                )
                return try encodeJSON(UnifiedCacheLookupReport(
                    key: sceneReport.key,
                    hit: sceneReport.hit,
                    kind: sceneReport.hit ? "scene" : cacheKind.rawValue,
                    cachedPath: sceneReport.cachedPath,
                    materializedPath: sceneReport.materializedPath,
                    usedClonefile: sceneReport.usedClonefile,
                    bytes: sceneReport.bytes,
                    sha256: sceneReport.sha256,
                    wallMs: sceneReport.wallMs
                ))
            }
        }
        return try encodeJSON(UnifiedCacheLookupReport(
            key: key,
            hit: false,
            kind: cacheKind.rawValue,
            cachedPath: nil,
            materializedPath: nil,
            usedClonefile: false,
            bytes: 0,
            sha256: nil,
            wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        ))

    case "stats":
        let shotRoot = rootURL ?? ForgeShotCache.defaultRootURL()
        let sceneRoot = rootURL ?? ForgeIncrementalCache.defaultCacheRootURL()
        let includeShot = (cacheKind == .auto || cacheKind == .shot)
        let includeScene = (cacheKind == .auto || cacheKind == .scene)
        let shotEntries = includeShot ? try ForgeShotCache.scanShotEntries(at: shotRoot) : []
        let sceneEntries = includeScene ? try ForgeIncrementalCache.scanSceneEntries(at: sceneRoot) : []
        let shotBytes = shotEntries.reduce(Int64(0)) { $0 + $1.bytes }
        let sceneBytes = sceneEntries.reduce(Int64(0)) { $0 + $1.bytes }
        let displayRoot = rootURL?.path ?? (cacheKind == .scene ? sceneRoot.path : shotRoot.path)
        return try encodeJSON(UnifiedCacheStatsReport(
            cacheRoot: displayRoot,
            kind: cacheKind.rawValue,
            entryCount: shotEntries.count + sceneEntries.count,
            totalBytes: shotBytes + sceneBytes,
            shotEntryCount: shotEntries.count,
            shotTotalBytes: shotBytes,
            sceneEntryCount: sceneEntries.count,
            sceneTotalBytes: sceneBytes
        ))

    case "prune":
        guard let maxBytes else {
            throw CLIUsageError("cache prune requires --max-bytes <N>")
        }
        let targetMax = max(0, maxBytes)
        let shotRoot = rootURL ?? ForgeShotCache.defaultRootURL()
        let sceneRoot = rootURL ?? ForgeIncrementalCache.defaultCacheRootURL()
        let includeShot = (cacheKind == .auto || cacheKind == .shot)
        let includeScene = (cacheKind == .auto || cacheKind == .scene)

        struct UnifiedVictim {
            let isShot: Bool
            let dataURL: URL
            let metaURL: URL
            let bytes: Int64
            let lastAccess: TimeInterval
        }

        var items: [UnifiedVictim] = []
        if includeShot {
            for e in try ForgeShotCache.scanShotEntries(at: shotRoot) {
                items.append(UnifiedVictim(isShot: true, dataURL: e.binURL, metaURL: e.metaURL, bytes: e.bytes, lastAccess: e.lastAccess))
            }
        }
        if includeScene {
            for e in try ForgeIncrementalCache.scanSceneEntries(at: sceneRoot) {
                items.append(UnifiedVictim(isShot: false, dataURL: e.segURL, metaURL: e.metaURL, bytes: e.bytes, lastAccess: e.lastAccess))
            }
        }
        items.sort { $0.lastAccess < $1.lastAccess }
        var total = items.reduce(Int64(0)) { $0 + $1.bytes }
        var removedShot = 0
        var removedScene = 0
        var freed: Int64 = 0
        while total > targetMax, !items.isEmpty {
            let victim = items.removeFirst()
            try? FileManager.default.removeItem(at: victim.dataURL)
            try? FileManager.default.removeItem(at: victim.metaURL)
            total -= victim.bytes
            freed += victim.bytes
            if victim.isShot {
                removedShot += 1
            } else {
                removedScene += 1
            }
        }
        let displayRoot = rootURL?.path ?? (cacheKind == .scene ? sceneRoot.path : shotRoot.path)
        return try encodeJSON(UnifiedCachePruneReport(
            cacheRoot: displayRoot,
            kind: cacheKind.rawValue,
            maxBytes: targetMax,
            removedEntries: removedShot + removedScene,
            freedBytes: freed,
            remainingEntries: items.count,
            remainingBytes: max(0, total),
            removedShotEntries: removedShot,
            removedSceneEntries: removedScene
        ))

    default:
        throw CLIUsageError("unknown cache subcommand '\(sub)'")
    }
}

// MARK: - Subcommands: seq-encode, batch-dom, transcode & Adaptive Worker Helper

private func runAdaptiveRenderChild(
    executablePath: String,
    arguments: [String],
    pool: ForgeAdaptiveWebKitPool
) async throws {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = arguments
        let stderrPipe = Pipe()
        proc.standardError = stderrPipe
        proc.standardOutput = FileHandle.nullDevice

        let errLock = NSLock()
        var errBuf = Data()
        let maxErrBytes = 65_536
        let readHandle = stderrPipe.fileHandleForReading
        readHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            errLock.withLock {
                if errBuf.count < maxErrBytes {
                    let take = min(chunk.count, maxErrBytes - errBuf.count)
                    errBuf.append(chunk.prefix(take))
                }
            }
        }

        proc.terminationHandler = { finished in
            readHandle.readabilityHandler = nil
            let tail = readHandle.readDataToEndOfFile()
            if !tail.isEmpty {
                errLock.withLock {
                    if errBuf.count < maxErrBytes {
                        let take = min(tail.count, maxErrBytes - errBuf.count)
                        errBuf.append(tail.prefix(take))
                    }
                }
            }
            pool.untrackChildProcess(finished)
            if finished.terminationStatus == 0 {
                cont.resume()
            } else {
                let captured = errLock.withLock { errBuf }
                let errText = String(data: captured, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                cont.resume(throwing: SafariumError.encode(
                    "adaptive child worker failed (status \(finished.terminationStatus)): \(errText.suffix(400))"
                ))
            }
        }
        do {
            pool.trackChildProcess(proc)
            try proc.run()
        } catch {
            readHandle.readabilityHandler = nil
            pool.untrackChildProcess(proc)
            cont.resume(throwing: SafariumError.encode("failed spawning adaptive WebKit worker: \(error.localizedDescription)"))
        }
    }
}

private func runSeqEncodeCommand(_ args: [String], progressEmitter: SafariumProgressEmitter? = nil) async throws -> Data {
    try checkSubcommandHelp(args, command: "seq-encode")
    var dirPath: String?
    var globPattern: String?
    var listPath: String?
    var outputPath: String?
    var fps = 24
    var width: Int?
    var height: Int?
    var codec: VideoCodec = .h264
    var bitrate = 8_000_000
    var quality: Double?
    var closedGOP = true
    var audioPath: String?
    var inlineSheetPath: String?
    var sheetCols = 6
    var sheetRows = 4
    var tileWidth = 320
    var decodeAhead = 3
    var overwrite = false
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--dir": dirPath = try nextValue(args, index: &i, flag: a)
        case "--glob": globPattern = try nextValue(args, index: &i, flag: a)
        case "--list": listPath = try nextValue(args, index: &i, flag: a)
        case "-o", "--output", "--out": outputPath = try nextValue(args, index: &i, flag: a)
        case "--fps": fps = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--width": width = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--height": height = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--codec": codec = try parseCodec(try nextValue(args, index: &i, flag: a))
        case "--bitrate": bitrate = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--quality": quality = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--audio": audioPath = try nextValue(args, index: &i, flag: a)
        case "--inline-sheet": inlineSheetPath = try nextValue(args, index: &i, flag: a)
        case "--sheet-cols", "--cols": sheetCols = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--sheet-rows", "--rows": sheetRows = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--tile-width": tileWidth = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--decode-ahead": decodeAhead = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--no-closed-gop": closedGOP = false
        case "--overwrite": overwrite = true
        default:
            if a.hasPrefix("-") { throw CLIUsageError("unknown option for seq-encode: \(a)") }
            if dirPath == nil { dirPath = a } else { throw CLIUsageError("unexpected positional argument for seq-encode: \(a)") }
        }
        i += 1
    }
    guard let outputPath else {
        throw CLIUsageError("seq-encode requires (--dir | --glob | --list) and -o <output>")
    }
    guard dirPath != nil || globPattern != nil || listPath != nil else {
        throw CLIUsageError("seq-encode requires --dir, --glob, or --list")
    }
    let frames = try ForgeSequenceIngest.discoverSequenceFrames(
        directoryURL: dirPath.map { URL(fileURLWithPath: $0, isDirectory: true) },
        globPattern: globPattern,
        listFileURL: listPath.map { URL(fileURLWithPath: $0) }
    )
    let sheetCfg: ForgeContactSheetConfig? = inlineSheetPath != nil
        ? ForgeContactSheetConfig(cols: sheetCols, rows: sheetRows, tileWidth: tileWidth)
        : nil
    let config = ForgeSequenceIngestConfig(
        framePaths: frames,
        fps: fps,
        width: width,
        height: height,
        codec: codec,
        bitrate: bitrate,
        quality: quality,
        closedGOP: closedGOP,
        audioURL: audioPath.map { URL(fileURLWithPath: $0) },
        inlineSheetConfig: sheetCfg,
        inlineSheetOutputURL: inlineSheetPath.map { URL(fileURLWithPath: $0) },
        overwrite: overwrite,
        decodeAheadSlots: decodeAhead
    )
    let report = try await ForgeSequenceIngest.run(
        config: config,
        outputURL: URL(fileURLWithPath: outputPath),
        progress: progressEmitter
    )
    return try encodeJSON(report)
}

@MainActor
private func runBatchDOMCommand(_ args: [String], progressEmitter: SafariumProgressEmitter? = nil) async throws -> Data {
    try checkSubcommandHelp(args, command: "batch-dom")
    HostApp.prepare()
    var manifestPath: String?
    var fontDirPath: String?
    var overwrite = false
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--manifest", "-m": manifestPath = try nextValue(args, index: &i, flag: a)
        case "--font-dir": fontDirPath = try nextValue(args, index: &i, flag: a)
        case "--overwrite": overwrite = true
        default:
            if a.hasPrefix("-") { throw CLIUsageError("unknown option for batch-dom: \(a)") }
            if manifestPath == nil { manifestPath = a } else { throw CLIUsageError("unexpected positional argument for batch-dom: \(a)") }
        }
        i += 1
    }
    guard let manifestPath else {
        throw CLIUsageError("batch-dom requires --manifest <manifest.json>")
    }
    let report = try await ForgeBatchDOM.run(
        manifestURL: URL(fileURLWithPath: manifestPath),
        fontDirURL: fontDirPath.map { URL(fileURLWithPath: $0, isDirectory: true) },
        overwrite: overwrite,
        progress: progressEmitter
    )
    return try encodeJSON(report)
}

private struct TranscodeReport: Codable {
    let inputPath: String
    let outputPath: String
    let codec: String
    let width: Int
    let height: Int
    let fps: Int
    let frames: Int
    let durationSeconds: Double
    let videoBitrateBps: Int
    let audioBitrateBps: Int
    let targetMaxBytes: Int64?
    let bytes: Int64
    let passes: Int
    let wallMs: Double
}

private func runTranscodeCommand(_ args: [String], progressEmitter: SafariumProgressEmitter? = nil) async throws -> Data {
    try checkSubcommandHelp(args, command: "transcode")
    let t0 = DispatchTime.now().uptimeNanoseconds
    var inputPath: String?
    var outputPath: String?
    var codec: VideoCodec = .h264
    var maxBytes: Int64?
    var explicitBitrate: Int?
    var quality: Double?
    var audioBitrate = 128_000
    var targetWidth: Int?
    var targetHeight: Int?
    var targetFPS: Int?
    var overwrite = false
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "-o", "--output", "--out": outputPath = try nextValue(args, index: &i, flag: a)
        case "--codec": codec = try parseCodec(try nextValue(args, index: &i, flag: a))
        case "--max-bytes":
            let raw = try nextValue(args, index: &i, flag: a)
            guard let v = Int64(raw), v > 0 else {
                throw CLIUsageError("--max-bytes must be a positive integer, got '\(raw)'")
            }
            maxBytes = v
        case "--bitrate": explicitBitrate = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--quality": quality = try parseDouble(try nextValue(args, index: &i, flag: a), flag: a)
        case "--audio-bitrate": audioBitrate = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--width": targetWidth = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--height": targetHeight = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--fps": targetFPS = try parseInt(try nextValue(args, index: &i, flag: a), flag: a)
        case "--overwrite": overwrite = true
        default:
            if a.hasPrefix("-") { throw CLIUsageError("unknown option for transcode: \(a)") }
            if inputPath == nil { inputPath = a } else { throw CLIUsageError("unexpected positional argument for transcode: \(a)") }
        }
        i += 1
    }
    guard let inputPath, let outputPath else {
        throw CLIUsageError("transcode requires <input> and -o <output>")
    }
    let inURL = URL(fileURLWithPath: inputPath)
    let outURL = URL(fileURLWithPath: outputPath)
    try SafeFilePublisher.assertRegularReadableFile(inURL)

    return try await withPlayableVideoURL(inputURL: inURL) { playableURL in
        let stage = try APFSAutoStage.makeSession(for: outURL, overwrite: overwrite)
        defer { stage.cleanup() }

        let asset = AVURLAsset(url: playableURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let hasAudio = !audioTracks.isEmpty

        let readerProbe = try await SafariumSequentialVideoReader(url: playableURL, loop: false, startTimeOffset: 0, pixelFormat: kCVPixelFormatType_32BGRA)
        let dur = readerProbe.durationSeconds
        let outW = (targetWidth ?? readerProbe.width) & ~1
        let outH = (targetHeight ?? readerProbe.height) & ~1
        let outFPS = max(1, targetFPS ?? Int(readerProbe.nominalFPS.rounded()))
        readerProbe.close()

        guard dur.isFinite, dur > 0, outW >= 2, outH >= 2 else {
            throw SafariumError.invalidState("transcode source has invalid duration/dimensions (\(dur)s \(outW)x\(outH))")
        }
        let frameCount = max(1, Int((dur * Double(outFPS)).rounded()))
        let usedAudioBps = hasAudio ? max(32_000, audioBitrate) : 0
        var videoBitrate: Int
        if let explicitBitrate {
            videoBitrate = max(64_000, explicitBitrate)
        } else if let maxBytes {
            let totalBitsBudget = Double(maxBytes) * 8.0 * 0.90
            let audioBits = Double(usedAudioBps) * dur
            let rawVideoBps = (totalBitsBudget - audioBits) / dur
            guard rawVideoBps >= 32_000 else {
                throw SafariumError.invalidState("--max-bytes \(maxBytes) is too small for \(String(format: "%.2f", dur))s video + audio")
            }
            videoBitrate = Int(rawVideoBps.rounded(.down))
        } else {
            videoBitrate = 8_000_000
        }

        let needsResize = outW != readerProbe.width || outH != readerProbe.height || !readerProbe.preferredTransform.isIdentity
        let metalEngine = needsResize ? (try? ForgeMetalFilterEngine()) : nil
        let ciCtx = SafariumMetalContext.shared?.ciContext ?? CIContext(options: [.cacheIntermediates: false])

        func runPass(passIndex: Int, bps: Int) async throws -> (url: URL, bytes: Int64) {
            let stagedVid = stage.fileURL("transcode_p\(passIndex).\(codec.fileExtension)")
            try? FileManager.default.removeItem(at: stagedVid)
            let seqReader = try await SafariumSequentialVideoReader(url: playableURL, loop: false, startTimeOffset: 0, pixelFormat: kCVPixelFormatType_32BGRA)
            defer { seqReader.close() }
            let sink = try AVAssetWriterSink(
                url: stagedVid,
                width: outW,
                height: outH,
                fps: outFPS,
                codec: codec,
                bitrate: quality == nil ? bps : nil,
                quality: quality,
                pixelFormat: codec.hasAlpha ? .bgra : .nv12Left,
                profile: .lowRamClosedGOP
            )
            progressEmitter?.emitStart(stage: "transcode_pass_\(passIndex)", total: frameCount)
            for f in 0..<frameCount {
                let t = Double(f) / Double(outFPS)
                guard let rawPB = try seqReader.pixelBuffer(at: t) else { break }
                try await sink.append(presentationTime: CMTime(value: Int64(f), timescale: Int32(outFPS))) { dstPB in
                    var srcBGRA = rawPB
                    if needsResize {
                        let tmpBGRA = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: outW, height: outH, pixelFormat: .bgra)
                        if seqReader.preferredTransform.isIdentity, let eng = metalEngine {
                            try eng.applyGeom(srcPB: rawPB, into: tmpBGRA)
                        } else {
                            let ci = seqReader.orientedCIImage(from: rawPB)
                            let sx = CGFloat(outW) / CGFloat(max(1, seqReader.width))
                            let sy = CGFloat(outH) / CGFloat(max(1, seqReader.height))
                            ciCtx.render(ci.transformed(by: CGAffineTransform(scaleX: sx, y: sy)), to: tmpBGRA, bounds: CGRect(x: 0, y: 0, width: outW, height: outH), colorSpace: Snapshot.colorSpace)
                        }
                        srcBGRA = tmpBGRA
                    }
                    if codec.hasAlpha {
                        CVPixelBufferLockBaseAddress(srcBGRA, .readOnly)
                        CVPixelBufferLockBaseAddress(dstPB, [])
                        defer {
                            _ = CVPixelBufferUnlockBaseAddress(dstPB, [])
                            _ = CVPixelBufferUnlockBaseAddress(srcBGRA, .readOnly)
                        }
                        if let sb = CVPixelBufferGetBaseAddress(srcBGRA), let db = CVPixelBufferGetBaseAddress(dstPB) {
                            let sr = CVPixelBufferGetBytesPerRow(srcBGRA), dr = CVPixelBufferGetBytesPerRow(dstPB)
                            let copyBytes = min(sr, dr)
                            for y in 0..<outH {
                                _ = memcpy(db.advanced(by: y * dr), sb.advanced(by: y * sr), copyBytes)
                            }
                        }
                    } else {
                        CVPixelBufferLockBaseAddress(srcBGRA, .readOnly)
                        defer { _ = CVPixelBufferUnlockBaseAddress(srcBGRA, .readOnly) }
                        guard let base = CVPixelBufferGetBaseAddress(srcBGRA) else {
                            throw SafariumError.encode("transcode missing BGRA base")
                        }
                        try SafariumAccelerate.convertRawBGRAToNV12BT709Left(
                            bgra: base,
                            bgraBytesPerRow: CVPixelBufferGetBytesPerRow(srcBGRA),
                            into: dstPB,
                            width: outW,
                            height: outH
                        )
                    }
                }
                progressEmitter?.emitFrame(stage: "transcode_pass_\(passIndex)", completed: f + 1, total: frameCount)
            }
            try await sink.finish()
            progressEmitter?.emitComplete(stage: "transcode_pass_\(passIndex)", total: frameCount)

            let finalStaged: URL
            if hasAudio {
                let stagedMux = stage.fileURL("transcode_mux_p\(passIndex).\(codec.fileExtension)")
                _ = try await LosslessSoundtrackMux.mux(
                    videoURL: stagedVid,
                    wavURL: playableURL,
                    outputURL: stagedMux,
                    overwrite: true
                )
                finalStaged = stagedMux
            } else {
                finalStaged = stagedVid
            }
            let sz = ((try? FileManager.default.attributesOfItem(atPath: finalStaged.path)[.size]) as? NSNumber)?.int64Value ?? 0
            return (finalStaged, sz)
        }

        var passes = 1
        var result = try await runPass(passIndex: 1, bps: videoBitrate)
        if let maxBytes, result.bytes > maxBytes, quality == nil {
            passes = 2
            let ratio = Double(maxBytes) / Double(max(1, result.bytes))
            let nextBps = max(32_000, Int((Double(videoBitrate) * ratio * 0.85).rounded(.down)))
            videoBitrate = nextBps
            result = try await runPass(passIndex: 2, bps: videoBitrate)
            if result.bytes > maxBytes {
                throw SafariumError.encode("transcode exceeded --max-bytes (\(result.bytes) > \(maxBytes)) after \(passes) passes at \(videoBitrate) bps")
            }
        }
        try stage.commit(stagedFile: result.url, overwrite: overwrite)
        let finalBytes = ((try? FileManager.default.attributesOfItem(atPath: outURL.path)[.size]) as? NSNumber)?.int64Value ?? result.bytes
        return try encodeJSON(TranscodeReport(
            inputPath: inURL.path,
            outputPath: outURL.path,
            codec: codec.cliName,
            width: outW,
            height: outH,
            fps: outFPS,
            frames: frameCount,
            durationSeconds: dur,
            videoBitrateBps: videoBitrate,
            audioBitrateBps: usedAudioBps,
            targetMaxBytes: maxBytes,
            bytes: finalBytes,
            passes: passes,
            wallMs: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        ))
    }
}

private func runABGalleryCommand(_ args: [String]) async throws -> Data {
    try checkSubcommandHelp(args, command: "ab-gallery")
    var manifestPath: String?
    var outputPath: String?
    var overwrite = false
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--manifest", "-m": manifestPath = try nextValue(args, index: &i, flag: a)
        case "-o", "--output", "--out": outputPath = try nextValue(args, index: &i, flag: a)
        case "--overwrite": overwrite = true
        default:
            if a.hasPrefix("-") { throw CLIUsageError("unknown option for ab-gallery: \(a)") }
            if manifestPath == nil { manifestPath = a } else { throw CLIUsageError("unexpected arg: \(a)") }
        }
        i += 1
    }
    guard let manifestPath, let outputPath else {
        throw CLIUsageError("ab-gallery requires --manifest <manifest.json> and -o <gallery.html>")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
    let manifest = try JSONDecoder().decode(ForgeABGalleryManifest.self, from: data)
    let report = try await ForgeABGallery.generate(
        manifest: manifest,
        outputHTMLURL: URL(fileURLWithPath: outputPath),
        overwrite: overwrite
    )
    return try encodeJSON(report)
}

// MARK: - CLI Entry Point

@main
private struct SafariumForgeCLI {
    private static func extractGlobalFlags(_ args: [String]) throws -> (clean: [String], jsonErrors: Bool, progressJSONL: Bool) {
        var clean: [String] = []
        var jsonErrors = (ProcessInfo.processInfo.environment["SAFARIUM_JSON_ERRORS"] == "1")
        var progressJSONL = false
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--json-errors" {
                jsonErrors = true
            } else if a == "--progress" {
                guard i + 1 < args.count else {
                    throw CLIUsageError("missing value for --progress (expected jsonl)")
                }
                i += 1
                let fmt = args[i].lowercased()
                guard fmt == "jsonl" else {
                    throw CLIUsageError("unsupported --progress format '\(fmt)' (expected jsonl)")
                }
                progressJSONL = true
            } else if a.hasPrefix("--progress=") {
                let fmt = String(a.dropFirst("--progress=".count)).lowercased()
                guard fmt == "jsonl" else {
                    throw CLIUsageError("unsupported --progress format '\(fmt)' (expected jsonl)")
                }
                progressJSONL = true
            } else {
                clean.append(a)
            }
            i += 1
        }
        return (clean, jsonErrors, progressJSONL)
    }

    @MainActor
    static func main() async {
        let rawArgs = Array(CommandLine.arguments.dropFirst())
        let wantJSONErrorsFallback = rawArgs.contains("--json-errors") || ProcessInfo.processInfo.environment["SAFARIUM_JSON_ERRORS"] == "1"
        do {
            let parsed = try extractGlobalFlags(rawArgs)
            let args = parsed.clean
            let progressEmitter = SafariumProgressEmitter(enabled: parsed.progressJSONL)
            guard let sub = args.first else {
                if parsed.jsonErrors {
                    let err = CLIUsageError("missing subcommand; see --help")
                    FileHandle.standardError.write(SafariumStructuredErrorEnvelope.from(err, tool: "safarium-forge", overrideCode: .E_USAGE).jsonLineData())
                } else {
                    FileHandle.standardError.write(Data((globalHelp + "\n").utf8))
                }
                exit(64)
            }
            if sub == "--help" || sub == "-h" || sub == "help" {
                FileHandle.standardOutput.write(Data((globalHelp + "\n").utf8))
                return
            }
            if sub == "--version" || sub == "-v" || sub == "version" {
                FileHandle.standardOutput.write(Data("safarium-forge \(SafariumForgeModuleInfo.version)\n".utf8))
                return
            }

            let rest = Array(args.dropFirst())
            switch sub {
            case "run":
                let out = try await runRecipeCommand(rest, forceValidateOnly: false, progressEmitter: progressEmitter)
                FileHandle.standardOutput.write(out)
            case "validate":
                let out = try await runRecipeCommand(rest, forceValidateOnly: true, progressEmitter: progressEmitter)
                FileHandle.standardOutput.write(out)
            case "schema":
                let out = try runSchemaCommand(rest)
                FileHandle.standardOutput.write(out)
            case "remux":
                let out = try await runRemuxCommand(rest)
                FileHandle.standardOutput.write(out)
            case "inspect", "probe":
                let out = try await runInspectCommand(rest)
                FileHandle.standardOutput.write(out)
            case "image":
                let out = try await runImageCommand(rest)
                FileHandle.standardOutput.write(out)
            case "audio":
                let out = try await runAudioCommand(rest, progressEmitter: progressEmitter)
                FileHandle.standardOutput.write(out)
            case "sheet":
                let out = try await runSheetCommand(rest)
                FileHandle.standardOutput.write(out)
            case "compare":
                let out = try await runCompareCommand(rest)
                FileHandle.standardOutput.write(out)
            case "pq":
                let res = try await runPQCommand(rest)
                FileHandle.standardOutput.write(res.data)
                if res.exitCode != 0 { exit(res.exitCode) }
            case "qa":
                let res = try await runQACommand(rest)
                FileHandle.standardOutput.write(res.data)
                if res.exitCode != 0 { exit(res.exitCode) }
            case "reframe":
                let out = try await runReframeCommand(rest)
                FileHandle.standardOutput.write(out)
            case "matte":
                let out = try await runMatteCommand(rest)
                FileHandle.standardOutput.write(out)
            case "pipe-encode":
                let out = try await runPipeEncodeCommand(rest, progressEmitter: progressEmitter)
                FileHandle.standardOutput.write(out)
            case "seq-encode":
                let out = try await runSeqEncodeCommand(rest, progressEmitter: progressEmitter)
                FileHandle.standardOutput.write(out)
            case "batch-dom":
                let out = try await runBatchDOMCommand(rest, progressEmitter: progressEmitter)
                FileHandle.standardOutput.write(out)
            case "transcode":
                let out = try await runTranscodeCommand(rest, progressEmitter: progressEmitter)
                FileHandle.standardOutput.write(out)
            case "prism":
                let out = try await runPrismCommand(rest, progressEmitter: progressEmitter)
                FileHandle.standardOutput.write(out)
            case "daemon":
                let out = try await runDaemonCommand(rest)
                FileHandle.standardOutput.write(out)
            case "ring-encode":
                let out = try await runRingEncodeCommand(rest)
                FileHandle.standardOutput.write(out)
            case "cache":
                let out = try runCacheCommand(rest)
                FileHandle.standardOutput.write(out)
            case "ab-gallery":
                let out = try await runABGalleryCommand(rest)
                FileHandle.standardOutput.write(out)
            case "capabilities":
                let out = try runCapabilitiesCommand(rest)
                FileHandle.standardOutput.write(out)
            default:
                throw CLIUsageError("unknown subcommand '\(sub)' (see --help)")
            }
        } catch CLIDone.text(let text) {
            FileHandle.standardOutput.write(Data(text.utf8))
        } catch let err as CLIUsageError {
            if wantJSONErrorsFallback {
                FileHandle.standardError.write(SafariumStructuredErrorEnvelope.from(err, tool: "safarium-forge", overrideCode: .E_USAGE).jsonLineData())
            } else {
                FileHandle.standardError.write(Data("safarium-forge: \(err)\n".utf8))
            }
            exit(64)
        } catch {
            if wantJSONErrorsFallback {
                FileHandle.standardError.write(SafariumStructuredErrorEnvelope.from(error, tool: "safarium-forge").jsonLineData())
            } else {
                FileHandle.standardError.write(Data("safarium-forge: \(error)\n".utf8))
            }
            exit(1)
        }
    }
}

private extension VideoCodec {
    var cliName: String {
        switch self {
        case .h264: return "h264"
        case .hevc: return "hevc"
        case .hevcAlpha: return "hevc-alpha"
        case .proRes422: return "prores422"
        case .proRes4444: return "prores4444"
        }
    }
}
