import Foundation
import CoreGraphics
import CoreMedia
import CryptoKit
import Darwin
import SafariumCore

// safarium-bench — R1 measurement harness (research tool, not the product CLI).
// One process = one worker. The Python harness spawns N processes for scaling tests.

struct Options {
    var fixture: URL
    var engine = "web"
    var width = 1080
    var height = 1920
    var fps = 30
    var frames = 300
    var warmup = 10
    var codec = "h264"
    var bitrate = 20_000_000
    var quality: Double? = nil
    var transparent = false
    var outDir: URL
    var jsonPath: URL? = nil
    var jsonlPath: URL? = nil
    var hash = false
    var scale = 1.0
    var step: Double? = nil
    var start: Double = 0
    var label = "run"
    var holdPlan: URL? = nil

    static func parse(_ args: [String]) throws -> Options {
        var a = Array(args.dropFirst())
        func next(_ name: String) throws -> String {
            guard !a.isEmpty else { throw BenchError.args("missing value for \(name)") }
            return a.removeFirst()
        }
        // Fixture may be positional or passed as --fixture (bench/run.py uses the flag).
        var fixtureArg: String
        if let i = a.firstIndex(of: "--fixture") {
            guard i + 1 < a.count else { throw BenchError.args("missing value for --fixture") }
            fixtureArg = a[i + 1]
            a.removeSubrange(i...(i + 1))
        } else if let first = a.first, !first.hasPrefix("--") {
            fixtureArg = first
            a.removeFirst()
        } else {
            throw BenchError.args("usage: safarium-bench <fixture> --out <dir> [options]")
        }
        if fixtureArg == "--fixture" { throw BenchError.args("missing fixture path") }
        var o = Options(fixture: URL(fileURLWithPath: fixtureArg),
                        outDir: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        while !a.isEmpty {
            let flag = a.removeFirst()
            switch flag {
            case "--engine": o.engine = try next(flag)
            case "--width": o.width = Int(try next(flag)) ?? o.width
            case "--height": o.height = Int(try next(flag)) ?? o.height
            case "--fps":
                guard let fps = Int(try next(flag)), fps > 0, Int32(exactly: fps) != nil else {
                    throw BenchError.args("--fps must be a positive Int32")
                }
                o.fps = fps
            case "--frames": o.frames = Int(try next(flag)) ?? o.frames
            case "--warmup": o.warmup = Int(try next(flag)) ?? o.warmup
            case "--codec": o.codec = try next(flag)
            case "--bitrate": o.bitrate = Int(try next(flag)) ?? o.bitrate
            case "--quality": o.quality = Double(try next(flag))
            case "--transparent": o.transparent = true
            case "--out": o.outDir = URL(fileURLWithPath: try next(flag))
            case "--json": o.jsonPath = URL(fileURLWithPath: try next(flag))
            case "--jsonl": o.jsonlPath = URL(fileURLWithPath: try next(flag))
            case "--hash": o.hash = true
            case "--scale": o.scale = Double(try next(flag)) ?? o.scale
            case "--step": o.step = Double(try next(flag))
            case "--start":
                guard let start = Double(try next(flag)), start.isFinite else {
                    throw BenchError.args("--start must be finite seconds")
                }
                o.start = start
            case "--label": o.label = try next(flag)
            case "--hold-plan": o.holdPlan = URL(fileURLWithPath: try next(flag))
            default: throw BenchError.args("unknown flag \(flag)")
            }
        }
        return o
    }
}

/// Preserve the legacy Double JS seeks, but determine hold membership on an exact frame grid.
private struct HoldFrameGrid {
    let origin: CMTime
    let fps: Int32

    init(_ o: Options, plan: FrameHoldPlan) throws {
        guard let fps = Int32(exactly: o.fps), fps > 0, o.start >= 0, o.frames > 0, o.warmup >= 0 else {
            throw BenchError.args("hold capture needs positive fps/frames and nonnegative start/warmup")
        }
        self.fps = fps
        // Accept origins on the frame grid, plan ticks, or a decimal seconds grid (down to ns)
        // only when they round-trip. Don't quietly move the page across a hold boundary.
        let scales: [Int32] = [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000, 10_000_000,
                               100_000_000, 1_000_000_000, fps, plan.timescale]
        guard let origin = scales.sorted().lazy.compactMap({ scale -> CMTime? in
            guard let ticks = Int64(exactly: (o.start * Double(scale)).rounded()) else { return nil }
            let t = CMTime(value: ticks, timescale: scale)
            return t.seconds == o.start ? t : nil
        }).first else { throw BenchError.args("--start is not representable on an exact hold time grid") }
        self.origin = origin
        _ = try time(at: min(1, o.frames - 1))
        _ = try time(at: o.frames - 1)
    }

    func time(at frame: Int) throws -> CMTime {
        let t = CMTimeAdd(origin, CMTime(value: Int64(frame), timescale: fps))
        guard t.isNumeric, !t.hasBeenRounded else { throw BenchError.args("hold timestamp overflow or rounding") }
        return t
    }
}

enum BenchError: Error, CustomStringConvertible {
    case args(String)
    case unsupported(String)
    var description: String {
        switch self {
        case .args(let m): return m
        case .unsupported(let m): return m
        }
    }
}

@main
struct SafariumBench {
    static func main() async {
        do {
            let o = try Options.parse(CommandLine.arguments)
            try await run(o)
        } catch {
            FileHandle.standardError.write(Data("safarium-bench: \(error)\n".utf8))
            exit(2)
        }
    }

    @MainActor
    static func run(_ o: Options) async throws {
        guard o.engine == "web" else {
            throw BenchError.unsupported("engine '\(o.engine)' is not implemented yet (native = R2)")
        }
        guard FileManager.default.fileExists(atPath: o.fixture.path) else {
            throw BenchError.args("fixture not found: \(o.fixture.path)")
        }
        let plan = try o.holdPlan.map { try JSONDecoder().decode(FrameHoldPlan.self, from: Data(contentsOf: $0)) }
        let grid = try plan.map { try HoldFrameGrid(o, plan: $0) }
        try FileManager.default.createDirectory(at: o.outDir, withIntermediateDirectories: true)

        HostApp.prepare()
        var stage = "init"
        do {
            stage = "page"
            let page = try await Page(config: PageConfig(
                width: o.width, height: o.height, scale: o.scale,
                transparent: o.transparent, deterministicClock: true))

            stage = "load"
            let tLoad0 = CFAbsoluteTimeGetCurrent()
            try await page.load(.fileURL(o.fixture))
            try await page.waitFor(.fonts)
            let tLoad = CFAbsoluteTimeGetCurrent() - tLoad0

            stage = "probe"
            var hasVideoSeek = (try? await page.evaluate(
                expression: "typeof window.__sfVideoSeek === 'function'")) as? Bool ?? false
            let videoProbe = (try? await page.evaluate(expression: """
                (() => { const v = document.querySelector('video'); if (!v) return null;
                  return { readyState: v.readyState, networkState: v.networkState,
                           duration: Number.isFinite(v.duration) ? v.duration : -1,
                           error: v.error ? v.error.code : 0, currentTime: v.currentTime }; })()
                """)) as? [String: Any] ?? [:]
            var videoSeekTimeouts = 0

            // The page's seek hook can wait forever when WKWebView never fires `seeked`
            // (no window / no media decode). Race it against a real wall-clock timer and
            // disable the hook after 3 timeouts so a fixture can never hang the run.
            func seekVideo(_ t: Double) async {
                guard hasVideoSeek else { return }
                let expr = """
                (async () => {
                  try {
                    const p = window.__sfVideoSeek(\(t));
                    const guard = new Promise(r => window.__sfClock.realSetTimeout(() => r('timeout'), 1500));
                    return await Promise.race([p, guard]);
                  } catch (e) { return 'error:' + String(e); }
                })()
                """
                let r = (try? await page.evaluate(expression: expr)) as? String ?? "error"
                if r == "timeout" || r.hasPrefix("error") {
                    videoSeekTimeouts += 1
                    if videoSeekTimeouts >= 3 { hasVideoSeek = false }
                }
            }

            stage = "sink"
            let sink: FrameSink?
            let outputURL: URL?
            switch o.codec {
            case "none":
                sink = nil; outputURL = nil
            case "h264", "hevc":
                let u = o.outDir.appendingPathComponent("\(o.label).mp4")
                sink = try AVAssetWriterSink(url: u, width: o.width, height: o.height, fps: o.fps,
                                             codec: o.codec == "h264" ? .h264 : .hevc,
                                             bitrate: o.bitrate, quality: o.quality)
                outputURL = u
            case "prores4444":
                let u = o.outDir.appendingPathComponent("\(o.label).mov")
                sink = try AVAssetWriterSink(url: u, width: o.width, height: o.height, fps: o.fps,
                                             codec: .proRes4444)
                outputURL = u
            case "prores422":
                let u = o.outDir.appendingPathComponent("\(o.label).mov")
                sink = try AVAssetWriterSink(url: u, width: o.width, height: o.height, fps: o.fps,
                                             codec: .proRes422)
                outputURL = u
            case "hevc-alpha":
                let u = o.outDir.appendingPathComponent("\(o.label).mov")
                sink = try AVAssetWriterSink(url: u, width: o.width, height: o.height, fps: o.fps,
                                             codec: .hevcAlpha)
                outputURL = u
            default:
                throw BenchError.args("unknown codec \(o.codec)")
            }

            stage = "warmup"
            for i in 0..<o.warmup {
                let t = o.start + Double(i) / Double(o.fps)
                try await page.seek(t, step: o.step)
                await seekVideo(t)
                _ = try await page.snapshot()
            }

            stage = "frames"
            var seekMs = [Double](), snapMs = [Double](), appendMs = [Double](), totalMs = [Double]()
            var hasher = SHA256()
            let jsonl = o.jsonlPath ?? o.outDir.appendingPathComponent("frames.jsonl")
            FileManager.default.createFile(atPath: jsonl.path, contents: nil)
            let fh = try FileHandle(forWritingTo: jsonl)
            defer { try? fh.close() }

            var holds = plan.map { FrameHoldCapture(page: page, plan: $0) }
            var appended = 0
            let t0 = CFAbsoluteTimeGetCurrent()
            for i in 0..<o.frames {
                let t = o.start + Double(i) / Double(o.fps)
                let a0 = CFAbsoluteTimeGetCurrent()
                try await page.seek(t, step: o.step)
                await seekVideo(t)
                let a1 = CFAbsoluteTimeGetCurrent()
                let previousReuse = holds?.reusedFrames
                let snap: Snapshot
                if let grid, let image = try await holds?.snapshot(afterSeekingTo: grid.time(at: i), pageSeconds: t) {
                    snap = image
                } else {
                    snap = try await page.snapshot()
                }
                let a2 = CFAbsoluteTimeGetCurrent()
                if let sink { try await sink.append(snap); appended += 1 }
                let a3 = CFAbsoluteTimeGetCurrent()

                let s = (a1 - a0) * 1000, sn = (a2 - a1) * 1000, ap = (a3 - a2) * 1000
                seekMs.append(s); snapMs.append(sn); appendMs.append(ap); totalMs.append((a3 - a0) * 1000)
                if o.hash { hasher.update(data: snap.bgra()) }

                var row: [String: Any] = [
                    "i": i, "t": t,
                    "seek_ms": round3(s), "snapshot_ms": round3(sn),
                    "append_ms": round3(ap), "total_ms": round3((a3 - a0) * 1000),
                    "rss_host_mb": round3(residentMB()),
                ]
                if let previousReuse { row["reused"] = previousReuse != holds?.reusedFrames }
                let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
                fh.write(data); fh.write(Data("\n".utf8))
            }
            let total = CFAbsoluteTimeGetCurrent() - t0

            stage = "finish"
            let f0 = CFAbsoluteTimeGetCurrent()
            try await sink?.finish()
            let finish = CFAbsoluteTimeGetCurrent() - f0

            let outputBytes = outputURL.flatMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? nil
            } ?? 0
            let hash = o.hash ? hasher.finalize().map { String(format: "%02x", $0) }.joined() : ""

            var summary: [String: Any] = [
                "schema": "safarium.bench/1",
                "label": o.label,
                "engine": o.engine,
                "fixture": o.fixture.path,
                "width": o.width, "height": o.height, "scale": o.scale,
                "fps": o.fps, "frames": o.frames, "warmup": o.warmup, "start": o.start,
                "snapshot_calls": holds?.snapshotCalls ?? o.frames, "reused_frames": holds?.reusedFrames ?? 0,
                "warmup_snapshot_calls": o.warmup, "appended_frames": appended,
                "codec": o.codec, "transparent": o.transparent,
                "load_ms": round3(tLoad * 1000),
                "total_ms": round3(total * 1000),
                "ms_per_frame": round3(total * 1000 / Double(o.frames)),
                "p50_ms": round3(percentile(totalMs, 0.50)),
                "p95_ms": round3(percentile(totalMs, 0.95)),
                "seek_avg_ms": round3(avg(seekMs)),
                "snapshot_avg_ms": round3(avg(snapMs)),
                "append_avg_ms": round3(avg(appendMs)),
                "fps_effective": round3(Double(o.frames) / total),
                "finish_ms": round3(finish * 1000),
                "rss_host_mb": round3(residentMB()),
                "has_video_seek": hasVideoSeek,
                "video_probe": videoProbe,
                "video_seek_timeouts": videoSeekTimeouts,
                "output": outputURL?.path ?? "",
                "output_bytes": outputBytes,
                "hash": hash,
                "macos": ProcessInfo.processInfo.operatingSystemVersionString,
            ]
            if let url = o.holdPlan { summary["hold_plan"] = url.path }
            if let q = o.quality { summary["quality"] = q }
            if let s = o.step { summary["step"] = s }
            let jsonPath = o.jsonPath ?? o.outDir.appendingPathComponent("summary.json")
            let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: jsonPath)
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
            // Skip AppKit/WebKit teardown: the snapshot and the movie are already on disk,
            // and waiting for the WebContent XPC to die costs seconds per run (pilot: 5.8–17.2 s).
            // No synchronizeFile() here: on a redirected stdout (/dev/null) it raises an
            // uncatchable NSException; run.py reads summary.json from disk anyway.
            _exit(0)
        } catch {
            FileHandle.standardError.write(Data("safarium-bench: stage=\(stage) error=\(error)\n".utf8))
            throw error
        }
    }
}

// MARK: - helpers

func round3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }

func avg(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }

func percentile(_ xs: [Double], _ p: Double) -> Double {
    guard !xs.isEmpty else { return 0 }
    let s = xs.sorted()
    if s.count == 1 { return s[0] }
    let pos = p * Double(s.count - 1)
    let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
    if lo == hi { return s[lo] }
    return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
}

func residentMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}
