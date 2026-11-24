import XCTest
import AVFoundation
import SafariumCore

/// Probe 6: long render memory (RSS of our process + the WebKit helper processes it spawned) and parallel-worker throughput.
@MainActor
final class MemoryProbeTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare(); try Probe.requireHeavy() }

    struct Proc { var pid: Int; var rssKB: Int; var cmd: String }
    static func ps() -> [Proc] {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-axo", "pid=,rss=,command="]
        let o = Pipe(); p.standardOutput = o; try? p.run()
        let s = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
        return s.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = Int(f[0]), let rss = Int(f[1]) else { return nil }
            return Proc(pid: pid, rssKB: rss, cmd: String(f[2]))
        }
    }
    static func webkitPids() -> Set<Int> { Set(ps().filter { $0.cmd.contains("com.apple.WebKit.") }.map { $0.pid }) }

    /// MB of our process, and of WebKit helpers that did not exist at `baseline` (= ours), split WebContent vs GPU/Networking.
    static func rss(baseline: Set<Int>) -> (own: Double, web: Double, other: Double, nWeb: Int) {
        let all = ps(), me = Int(getpid())
        let own = Double(all.first { $0.pid == me }?.rssKB ?? 0) / 1024
        let mine = all.filter { $0.cmd.contains("com.apple.WebKit.") && !baseline.contains($0.pid) }
        let web = mine.filter { $0.cmd.contains("WebContent") }
        let other = mine.filter { !$0.cmd.contains("WebContent") }
        return (own, Double(web.reduce(0) { $0 + $1.rssKB }) / 1024, Double(other.reduce(0) { $0 + $1.rssKB }) / 1024, web.count)
    }

    func testMemory_3000frames_1080x1920_h264() async throws {
        let baseline = Self.webkitPids()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sfmem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = try await Page(config: PageConfig(width: 1080, height: 1920, deterministicClock: true))
        try await page.load(.fileURL(Fixtures.core("clock.html")))
        let sink = try AVAssetWriterSink(url: dir.appendingPathComponent("m.mp4"), width: 1080, height: 1920, fps: 30, codec: .h264, bitrate: 20_000_000)
        var series: [(Int, Double, Double, Double)] = []
        let t0 = CFAbsoluteTimeGetCurrent()
        let n = 3000
        for i in 0..<n {
            try await page.seek(Double(i) / 30)
            try await sink.append(try await page.snapshot())
            if i % 250 == 0 || i == n - 1 { let r = Self.rss(baseline: baseline); series.append((i, r.own, r.web, r.other)) }
        }
        try await sink.finish()
        let secs = CFAbsoluteTimeGetCurrent() - t0
        let text = series.map { "f\($0.0): own \(Int($0.1)) web \(Int($0.2)) gpu+net \(Int($0.3)) MB" }.joined(separator: " | ")
        let total = { (s: (Int, Double, Double, Double)) in s.1 + s.2 + s.3 }
        let early = total(series[2]), late = total(series[series.count - 1])
        Probe.log("memory 3000f 1080x1920 h264: \(String(format: "%.1f", secs)) s (\(String(format: "%.1f", Double(n) / secs)) fps) ; total RSS (own+WebContent+GPU/Net) f500=\(Int(early)) MB f2999=\(Int(late)) MB growth=\(Int(late - early)) MB ; \(text)")
        XCTAssertLessThan(late - early, 150, "RSS grew \(Int(late - early)) MB between frame 500 and the end — possible leak")
    }

    /// 1/2/4 concurrent Pages (in-process, one WebContent each) × 300 frames of 1080x1920 H.264.
    func testParallelWorkers_throughput() async throws {
        let frames = 300
        var results: [(Int, Double)] = []
        for workers in [1, 2, 4] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sfpar-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            var pages: [Page] = [], sinks: [AVAssetWriterSink] = []
            for w in 0..<workers {
                let p = try await Page(config: PageConfig(width: 1080, height: 1920, deterministicClock: true))
                try await p.load(.fileURL(Fixtures.core("clock.html")))
                try await p.seek(0); _ = try await p.snapshot()
                pages.append(p)
                sinks.append(try AVAssetWriterSink(url: dir.appendingPathComponent("w\(w).mp4"), width: 1080, height: 1920, fps: 30, codec: .h264, bitrate: 20_000_000))
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            try await withThrowingTaskGroup(of: Void.self) { g in
                for w in 0..<workers {
                    let page = pages[w], sink = sinks[w]
                    g.addTask { @MainActor in
                        for i in 0..<frames { try await page.seek(Double(i) / 30); try await sink.append(try await page.snapshot()) }
                        try await sink.finish()
                    }
                }
                try await g.waitForAll()
            }
            let secs = CFAbsoluteTimeGetCurrent() - t0
            results.append((workers, Double(frames * workers) / secs))
        }
        Probe.log("parallel workers (in-process Pages, 300 frames each, 1080x1920 h264): " + results.map { "\($0.0)w=\(String(format: "%.1f", $0.1)) fps total" }.joined(separator: ", "))
        // Finding (docs/probe-results.md): in-process Pages do not scale — everything funnels through the main thread. Only correctness is asserted here.
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0.1 > 20 }, "a worker configuration was unreasonably slow: \(results)")
    }

    // MARK: multi-process workers

    /// Worker body: only runs when launched by `testParallelProcesses_throughput` (SAFARIUM_WORKER=1).
    func testWorker_render1200frames() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SAFARIUM_WORKER"] == "1", "child of testParallelProcesses_throughput")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sfwrk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let page = try await Page(config: PageConfig(width: 1080, height: 1920, deterministicClock: true))
        try await page.load(.fileURL(Fixtures.core("clock.html")))
        try await page.seek(0); _ = try await page.snapshot()
        let sink = try AVAssetWriterSink(url: dir.appendingPathComponent("w.mp4"), width: 1080, height: 1920, fps: 30, codec: .h264, bitrate: 20_000_000)
        let frames = 1200
        let t0 = Date().timeIntervalSince1970
        for i in 0..<frames { try await page.seek(Double(i) / 30); try await sink.append(try await page.snapshot()) }
        try await sink.finish()
        let t1 = Date().timeIntervalSince1970
        print("WORKER_RESULT frames=\(frames) start=\(t0) end=\(t1)")
    }

    /// 1, 2, 4 separate xctest processes (one Page each) rendering 1200 frames; aggregate = total frames / (last end − first start).
    func testParallelProcesses_throughput() async throws {
        let bundle = Bundle(for: MemoryProbeTests.self).bundleURL.path
        var results: [(Int, Double)] = []
        for n in [1, 2, 4] {
            let procs: [(Process, Pipe)] = (0..<n).map { _ in
                let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
                p.arguments = ["xctest", "-XCTest", "SafariumProbeTests.MemoryProbeTests/testWorker_render1200frames", bundle]
                var env = ProcessInfo.processInfo.environment; env["SAFARIUM_WORKER"] = "1"; env["SAFARIUM_PROBES"] = "1"; p.environment = env
                let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
                return (p, o)
            }
            for (p, _) in procs { try p.run() }
            var starts: [Double] = [], ends: [Double] = []
            for (p, o) in procs {
                let out = String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
                guard let line = out.split(separator: "\n").first(where: { $0.hasPrefix("WORKER_RESULT") }) else { XCTFail("worker produced no result: \(out.suffix(400))"); return }
                for kv in line.split(separator: " ") {
                    if kv.hasPrefix("start=") { starts.append(Double(kv.dropFirst(6))!) }
                    if kv.hasPrefix("end=") { ends.append(Double(kv.dropFirst(4))!) }
                }
            }
            results.append((n, Double(1200 * n) / (ends.max()! - starts.min()!)))
        }
        Probe.log("parallel PROCESSES (1 Page each, 1200 frames each, 1080x1920 h264): " + results.map { "\($0.0)p=\(String(format: "%.1f", $0.1)) fps total" }.joined(separator: ", "))
        // Measured: throughput saturates at ~240 fps already with 1-2 workers (encoder/GPU bound), so extra workers give ~no gain.
        // Asserted instead: parallel workers must not make the aggregate meaningfully worse than a single worker.
        XCTAssertGreaterThanOrEqual(results[1].1, results[0].1 * 0.9, "2 processes slower than 1: \(results)")
        XCTAssertGreaterThanOrEqual(results[2].1, results[0].1 * 0.9, "4 processes slower than 1: \(results)")
    }
}
