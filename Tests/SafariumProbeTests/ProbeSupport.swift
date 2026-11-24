import XCTest
import CryptoKit
import AVFoundation
import SafariumCore

/// Paths + helpers shared by the P1-F probes. Libraries (npm) and fonts live in the scratch dir, never in the vault.
enum Probe {
    /// `SAFARIUM_PROBE_SCRATCH` if set, else a stable folder under the system temp dir (never a hard-coded session path).
    static let scratch: URL = {
        if let e = ProcessInfo.processInfo.environment["SAFARIUM_PROBE_SCRATCH"], !e.isEmpty { return URL(fileURLWithPath: e) }
        return FileManager.default.temporaryDirectory.appendingPathComponent("safarium-probe-scratch")
    }()
    static var libs: URL { scratch.appendingPathComponent("probe-libs") }
    /// One site dir per test process (sibling of probe-libs so `../probe-libs/...` resolves): concurrent `swift test` runs must not delete each other's fixtures.
    static var site: URL { scratch.appendingPathComponent("probe-site-\(ProcessInfo.processInfo.processIdentifier)") }
    static var evidence: URL { scratch.appendingPathComponent("probe-evidence") }
    static let fixturesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/probes")

    /// Copies fixtures/probes/* into scratch/probe-site (next to ../probe-libs) and returns the page URL.
    static func siteURL(_ name: String) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: site, withIntermediateDirectories: true)
        try fm.createDirectory(at: evidence, withIntermediateDirectories: true)
        for f in try fm.contentsOfDirectory(atPath: fixturesDir.path) {
            let dst = site.appendingPathComponent(f)
            try? fm.removeItem(at: dst)
            try fm.copyItem(at: fixturesDir.appendingPathComponent(f), to: dst)
        }
        let u = site.appendingPathComponent(name)
        guard fm.fileExists(atPath: u.path) else { throw SafariumError.invalidState("missing fixture \(name)") }
        return u
    }

    static func requireLibs() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: libs.appendingPathComponent("gsap.min.js").path),
                          "npm libs missing in \(libs.path) (see docs/probe-results.md, 'Setup')")
    }

    /// Heavy probes (long renders, many libs, parallel workers) are opt-in: SAFARIUM_PROBES=1 (default run must stay < 300 s).
    static func requireHeavy() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SAFARIUM_PROBES"] == "1",
                          "heavy probe is opt-in: run with SAFARIUM_PROBES=1")
    }

    static func save(_ s: Snapshot, _ name: String) {
        try? FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try? s.pngData().write(to: evidence.appendingPathComponent(name + ".png"))
    }

    static func hash(_ s: Snapshot) -> String { sha(s.bgra()) }
    static func sha(_ d: Data) -> String { SHA256.hash(data: d).prefix(8).map { String(format: "%02x", $0) }.joined() }

    /// Bounding box of pixels that differ from white by more than `tol` (sum of RGB deltas), plus count.
    static func bbox(_ s: Snapshot, tol: Int = 60) -> (minX: Int, maxX: Int, minY: Int, maxY: Int, count: Int)? {
        let w = s.width, h = s.height
        let d = s.bgra()
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1, n = 0
        d.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            let b = p.bindMemory(to: UInt8.self)
            for y in 0..<h { for x in 0..<w {
                let o = (y * w + x) * 4
                let diff = (255 - Int(b[o])) + (255 - Int(b[o + 1])) + (255 - Int(b[o + 2]))
                if diff > tol { n += 1; if x < minX { minX = x }; if x > maxX { maxX = x }; if y < minY { minY = y }; if y > maxY { maxY = y } }
            } }
        }
        return n == 0 ? nil : (minX, maxX, minY, maxY, n)
    }

    /// Appends a measured line to scratch/probe-evidence/measurements.log (also printed as `PROBE ...`).
    static func log(_ line: String) {
        print("PROBE \(line)")
        let u = evidence.appendingPathComponent("measurements.log")
        try? FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try? h.close() }
        else { try? Data((line + "\n").utf8).write(to: u) }
    }
}

/// Reads frame `index` of a video back as premultiplied BGRA via AVAssetReader.
func readBackFrame(_ url: URL, index: Int = 0) async throws -> (w: Int, h: Int, bgra: [UInt8]) {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw SafariumError.invalidState("no video track") }
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(out); reader.startReading()
    var i = 0
    while let sb = out.copyNextSampleBuffer() {
        if i == index, let pb = CMSampleBufferGetImageBuffer(sb) {
            CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h { for x in 0..<(w * 4) { px[y * w * 4 + x] = base[y * bpr + x] } }
            return (w, h, px)
        }
        i += 1
    }
    throw SafariumError.invalidState("frame \(index) not found (read \(i))")
}
