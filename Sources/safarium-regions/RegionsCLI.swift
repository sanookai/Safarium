import CryptoKit
import Darwin
import Foundation
import SafariumCore

private let usage = """
Usage: safarium-regions INPUT.html OUTPUT.mp4 [options]
  --rect x,y,width,height  Author guarantees ALL changed pixels are in this fixed CSS viewport
                           rect (top-left origin, right/bottom exclusive). Default: full capture.
                           Every patch is checked against a full raw reference; reject mismatch.
  --verify                 Explicitly request that default every-patch check (requires --rect).
  --trust-rect             Fast opt-in for preverified input: check only the first patch per rect.
  --hashes                 Include one SHA-256 of tightly packed top-down sRGB BGRA8 per frame in stdout JSON.
  --width N --height N     Even H.264 dimensions (default 1080×1920); opaque SDR, scale 1.
  --frames N --fps N       Default 60 frames at 30 fps; presentation time = frame index / fps.
  --bitrate N              Target H.264 bits/second (default 20000000).
Output must be new. Parent directories must exist. No audio.
"""

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private struct Options {
    let input: URL, output: URL
    var width = 1080, height = 1920, fps = 30, frames = 60, bitrate = 20_000_000
    var rect: RetainedViewport.Rect?
    var verify = false, trustRect = false, hashes = false

    init(_ args: [String]) throws {
        guard args.count >= 2, !args[0].hasPrefix("--"), !args[1].hasPrefix("--") else { throw CLIError(usage) }
        input = URL(fileURLWithPath: args[0]).standardizedFileURL
        output = URL(fileURLWithPath: args[1]) // preserve the final component for lstat/RENAME_EXCL
        var i = 2, seen = Set<String>()
        while i < args.count {
            let flag = args[i]; i += 1
            guard seen.insert(flag).inserted else { throw CLIError("duplicate option \(flag)") }
            func value() throws -> String {
                guard i < args.count else { throw CLIError("missing value for \(flag)") }
                defer { i += 1 }
                return args[i]
            }
            func positive() throws -> Int {
                guard let n = Int(try value()), n > 0 else { throw CLIError("\(flag) needs a positive integer") }
                return n
            }
            switch flag {
            case "--rect":
                let parts = try value().split(separator: ",", omittingEmptySubsequences: false)
                let n = parts.compactMap { Int($0) }
                guard parts.count == 4, n.count == 4 else { throw CLIError("--rect needs four signed integers: x,y,width,height") }
                rect = try RetainedViewport.Rect(x: n[0], y: n[1], width: n[2], height: n[3])
            case "--verify": verify = true
            case "--trust-rect": trustRect = true
            case "--hashes": hashes = true
            case "--width": width = try positive()
            case "--height": height = try positive()
            case "--fps": fps = try positive()
            case "--frames": frames = try positive()
            case "--bitrate": bitrate = try positive()
            default: throw CLIError("unknown option \(flag); see --help")
            }
        }
        guard width <= 8192, height <= 8192, width * height <= 33_554_432,
              width.isMultiple(of: 2), height.isMultiple(of: 2) else {
            throw CLIError("H.264 dimensions must be even, at most 8192 per side and 33554432 pixels")
        }
        guard fps <= Int32.max, bitrate <= Int32.max else { throw CLIError("fps and bitrate must fit in Int32") }
        try rect?.validate(viewportWidth: width, height: height)
        guard !(verify && trustRect) else { throw CLIError("--verify and --trust-rect conflict") }
        guard !(verify || trustRect) || rect != nil else { throw CLIError("--verify/--trust-rect require --rect") }
        guard output.pathExtension.lowercased() == "mp4" else { throw CLIError("output must have .mp4 extension") }
        var dir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: input.path, isDirectory: &dir), !dir.boolValue else {
            throw CLIError("input file not found: \(input.path)")
        }
        try RenderOutput.requireNew(output)
    }
}

private struct Summary: Encodable {
    let schema = "safarium.regions/1"
    let width, height, fps, frames, bitrate: Int
    let rect: RetainedViewport.Rect?
    let verificationMode: String
    let videoSeeks: Int
    let fullCaptures, rectCaptures, verificationCaptures: Int
    let rawBGRASHA256: [String]?
}

@main
private struct SafariumRegions {
    @MainActor static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] || args == ["-h"] { print(usage); return }
        do {
            let options = try Options(args), output = RenderOutput(options.output)
            let work = Task { try await render(options, output: output) }
            // Both the caller and the work task are MainActor-isolated. Install handlers before
            // yielding to the task (and therefore before it can create a file).
            let signals = output.handleSignals { work.cancel() }
            defer { signals.forEach { $0.cancel() } }
            let summary: Summary
            do { summary = try await work.value }
            catch {
                if let sig = output.signalNumber {
                    FileHandle.standardError.write(Data("safarium-regions: interrupted by signal \(sig)\n".utf8))
                    exit(128 + sig)
                }
                throw error
            }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var data = try encoder.encode(summary); data.append(0x0a)
            FileHandle.standardOutput.write(data)
        } catch {
            FileHandle.standardError.write(Data("safarium-regions: \(error)\n".utf8))
            exit(2)
        }
    }

    @MainActor
    private static func render(_ o: Options, output: RenderOutput) async throws -> Summary {
        defer { output.cleanup() }
        try Task.checkCancellation()
        let page = try await Page(config: PageConfig(width: o.width, height: o.height, deterministicClock: true))
        defer { page.close() }
        try await page.load(.fileURL(o.input))
        try await page.waitFor(.fonts)
        let retained = RetainedViewport(page: page)
        try await retained.checkInitialImages()
        try output.create()
        let sink = try AVAssetWriterSink(url: output.movie, width: o.width, height: o.height, fps: o.fps, codec: .h264, bitrate: o.bitrate)
        var finished = false
        defer { if !finished { sink.cancel() } }
        var hashes: [String]? = o.hashes ? [] : nil
        for index in 0..<o.frames {
            do {
                try Task.checkCancellation()
                let t = Double(index) / Double(o.fps)
                let frame = try await retained.snapshot(at: t, damage: o.rect, verification: o.trustRect ? .trustRect : .everyPatch)
                if o.hashes {
                    hashes?.append(SHA256.hash(data: try frame.checkedBGRA()).map { String(format: "%02x", $0) }.joined())
                }
                try await sink.append(frame)
            } catch {
                throw CLIError("frame \(index) (PTS \(index)/\(o.fps)): \(error)")
            }
        }
        try await sink.finish()
        finished = true
        try Task.checkCancellation()
        try output.publish()
        return Summary(width: o.width, height: o.height, fps: o.fps, frames: o.frames, bitrate: o.bitrate, rect: o.rect,
                       verificationMode: o.rect == nil ? "full" : o.trustRect ? "trusted" : "everyPatch", videoSeeks: retained.videoSeeks,
                       fullCaptures: retained.fullCaptures, rectCaptures: retained.rectCaptures,
                       verificationCaptures: retained.verificationCaptures, rawBGRASHA256: hashes)
    }

}
