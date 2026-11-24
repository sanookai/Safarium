import XCTest
import CryptoKit
import AVFoundation
import SafariumCore

enum Fixtures {
    static let dir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    static func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
}

func makeTempDir(_ label: String = "safarium") throws -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

/// Reads frame `index` of a video back as BGRA (premultiplied) via AVAssetReader.
func readBackFrame(_ url: URL, index: Int = 0) async throws -> (w: Int, h: Int, bgra: [UInt8]) {
    let asset = AVURLAsset(url: url)
    let track = try await asset.loadTracks(withMediaType: .video).first!
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
