import XCTest
import AppKit
import AVFoundation
import SafariumCore

/// Probe 5: a 300-frame render must not change the frontmost app, open/move Safari windows, or add a Dock icon.
@MainActor
final class FocusProbeTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare(); try Probe.requireHeavy() }

    nonisolated static func sh(_ exe: String, _ args: [String]) -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        let o = Pipe(); p.standardOutput = o; p.standardError = Pipe()
        do { try p.run() } catch { return "ERR \(error)" }
        let d = o.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    nonisolated static func osa(_ s: String) -> String { sh("/usr/bin/osascript", ["-e", s]) }
    nonisolated static func osaLines(_ lines: [String]) -> String { sh("/usr/bin/osascript", lines.flatMap { ["-e", $0] }) }

    struct State: Equatable, Sendable { var frontmost: String; var safariWindows: String; var dockApps: String; var lsFront: String }
    nonisolated static func state() -> State {
        State(frontmost: osa("tell application \"System Events\" to get name of first process whose frontmost is true"),
              safariWindows: osaLines(["tell application \"System Events\"", "if exists process \"Safari\" then", "return (count of windows of process \"Safari\") as text", "else", "return \"no-safari\"", "end if", "end tell"]),
              dockApps: osa("tell application \"System Events\" to get name of every process whose background only is false and name is not \"osascript\""),
              lsFront: sh("/usr/bin/lsappinfo", ["front"]))
    }

    func testRender300Frames_noFocusSteal_noWindow_noDockIcon() async throws {
        let before = Self.state()
        try XCTSkipIf(before.frontmost.hasPrefix("ERR") || before.frontmost.isEmpty, "osascript/System Events not permitted here: \(before.frontmost)")
        var samples: [State] = [], fast: [String] = []
        let lock = NSLock()
        let stop = ManagedFlag()
        // slow sampler: full System Events state (~1 s per sample); fast sampler: `lsappinfo front` every ~10 ms (the render only lasts seconds)
        let slow = Thread { while !stop.value { let s = Self.state(); lock.lock(); samples.append(s); lock.unlock() } }
        let quick = Thread { while !stop.value { let f = Self.sh("/usr/bin/lsappinfo", ["front"]); lock.lock(); fast.append(f); lock.unlock(); Thread.sleep(forTimeInterval: 0.01) } }
        slow.start(); quick.start()

        let dir = try makeTmp()
        let page = try await Page(config: PageConfig(width: 1080, height: 1920, deterministicClock: true))
        try await page.load(.fileURL(Fixtures.core("clock.html")))
        let sink = try AVAssetWriterSink(url: dir.appendingPathComponent("f.mp4"), width: 1080, height: 1920, fps: 30, codec: .h264, bitrate: 20_000_000)
        for i in 0..<300 { try await page.seek(Double(i) / 30); try await sink.append(try await page.snapshot()) }
        try await sink.finish()
        let policy = NSApplication.shared.activationPolicy()
        stop.value = true
        while slow.isExecuting || quick.isExecuting { try await Task.sleep(nanoseconds: 50_000_000) }
        let after = Self.state()

        lock.lock(); let during = samples; let quickDuring = fast; lock.unlock()
        let quickChanged = quickDuring.filter { $0 != before.lsFront }.count
        let changedFront = during.filter { $0.frontmost != before.frontmost }.count
        let changedWin = during.filter { $0.safariWindows != before.safariWindows }.count
        let changedDock = during.filter { $0.dockApps != before.dockApps }.count
        Probe.log("focus: frontmost before='\(before.frontmost)' after='\(after.frontmost)' ; \(during.count) System Events samples + \(quickDuring.count) lsappinfo samples during 300-frame render (lsappinfo front changed \(quickChanged)): frontmost changed \(changedFront), Safari windows (\(before.safariWindows)) changed \(changedWin), Dock-visible app list changed \(changedDock) ; activationPolicy=\(policy.rawValue) (2 = prohibited) ; lsappinfo front before=\(before.lsFront) after=\(after.lsFront)")
        XCTAssertGreaterThan(quickDuring.count, 20, "fast sampler barely ran")
        XCTAssertEqual(quickChanged, 0, "lsappinfo front changed during render")
        XCTAssertFalse(before.safariWindows.isEmpty, "could not read Safari window count (System Events automation denied?)")
        XCTAssertEqual(after.frontmost, before.frontmost)
        XCTAssertEqual(changedFront, 0, "frontmost app changed during render")
        XCTAssertEqual(after.safariWindows, before.safariWindows)
        XCTAssertEqual(changedWin, 0, "Safari window count changed during render")
        XCTAssertEqual(changedDock, 0, "a Dock-visible process appeared during render")
        XCTAssertEqual(after.dockApps, before.dockApps)
        XCTAssertEqual(policy, .prohibited)
    }

    /// Same observation as above, for the core's `.element` video mode: its hidden off-screen NSWindow (ordered back, never front/key)
    /// must not change the frontmost app, add Safari windows or a Dock icon, while 150 video seeks + snapshots run.
    func testElementVideoMode_hiddenWindow_noFocusSteal() async throws {
        let before = Self.state()
        try XCTSkipIf(before.frontmost.hasPrefix("ERR") || before.frontmost.isEmpty, "osascript/System Events not permitted here: \(before.frontmost)")
        let dir = try makeTmp(); defer { try? FileManager.default.removeItem(at: dir) }
        // 60-frame clip made by the core's own writer (no ffmpeg needed)
        let clip = dir.appendingPathComponent("c.mp4")
        let src = try await Page(config: PageConfig(width: 320, height: 180, deterministicClock: true))
        try await src.load(.html("<body style='margin:0;background:#246'><div style='font:60px sans-serif;color:#fff'>focus</div>"))
        let sink = try AVAssetWriterSink(url: clip, width: 320, height: 180, fps: 30, codec: .h264)
        for i in 0..<60 { try await src.seek(Double(i) / 30); try await sink.append(try await src.snapshot()) }
        try await sink.finish()
        // <meta charset> present: a file without one is loaded as data and its relative subresources (the clip) would not load
        try "<!doctype html><meta charset='utf-8'><body style='margin:0'><video id=v muted src='c.mp4' style='width:320px;height:180px'></video>".write(to: dir.appendingPathComponent("p.html"), atomically: true, encoding: .utf8)

        var samples: [State] = [], fast: [String] = []
        let lock = NSLock(); let stop = ManagedFlag()
        let slow = Thread { while !stop.value { let s = Self.state(); lock.lock(); samples.append(s); lock.unlock() } }
        let quick = Thread { while !stop.value { let f = Self.sh("/usr/bin/lsappinfo", ["front"]); lock.lock(); fast.append(f); lock.unlock(); Thread.sleep(forTimeInterval: 0.01) } }
        slow.start(); quick.start()

        let page = try await Page(config: PageConfig(width: 320, height: 180, deterministicClock: true, video: .element))
        defer { page.close() }
        XCTAssertNotNil(page.webView.window, "element mode must have its hidden window for this probe to mean anything")
        try await page.load(.fileURL(dir.appendingPathComponent("p.html"), readAccess: dir))
        for round in 0..<3 { for i in 0..<50 { try await page.seek(Double((i * 7 + round) % 60) / 30); _ = try await page.snapshot() } }
        let winVisible = page.webView.window?.isVisible ?? false, key = page.webView.window?.isKeyWindow ?? false
        let policy = NSApplication.shared.activationPolicy(), active = NSApplication.shared.isActive
        stop.value = true
        while slow.isExecuting || quick.isExecuting { try await Task.sleep(nanoseconds: 50_000_000) }
        let after = Self.state()

        lock.lock(); let during = samples; let quickDuring = fast; lock.unlock()
        let quickChanged = quickDuring.filter { $0 != before.lsFront }.count
        let changedFront = during.filter { $0.frontmost != before.frontmost }.count
        let changedWin = during.filter { $0.safariWindows != before.safariWindows }.count
        let changedDock = during.filter { $0.dockApps != before.dockApps }.count
        Probe.log("focus (.element video, hidden window): frontmost before='\(before.frontmost)' after='\(after.frontmost)' ; \(during.count) System Events + \(quickDuring.count) lsappinfo samples during 150 seeks (lsappinfo changed \(quickChanged), frontmost changed \(changedFront), Safari windows changed \(changedWin), Dock list changed \(changedDock)) ; window visible(orderBack)=\(winVisible) key=\(key) ; app active=\(active) policy=\(policy.rawValue)")
        XCTAssertGreaterThan(quickDuring.count, 10, "fast sampler barely ran")
        XCTAssertEqual(quickChanged, 0, "lsappinfo front changed while the hidden window existed")
        XCTAssertFalse(before.safariWindows.isEmpty, "could not read Safari window count")
        XCTAssertEqual(after.frontmost, before.frontmost)
        XCTAssertEqual(changedFront, 0); XCTAssertEqual(changedWin, 0); XCTAssertEqual(changedDock, 0)
        XCTAssertEqual(after.safariWindows, before.safariWindows); XCTAssertEqual(after.dockApps, before.dockApps)
        XCTAssertFalse(key, "hidden window must never be key"); XCTAssertFalse(active, "app must never become active")
        XCTAssertEqual(policy, .prohibited)
    }

    private func makeTmp() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("sfprobe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }
}

final class ManagedFlag: @unchecked Sendable {
    private let l = NSLock(); private var v = false
    var value: Bool { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } }
}

enum Fixtures {
    /// Fixtures shipped with the core tests (Tests/Fixtures/*.html).
    static func core(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
    }
}
