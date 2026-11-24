import AVFoundation
import CoreAudio
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
@testable import SafariumCore
@testable import SafariumForgeCore
import UniformTypeIdentifiers
import XCTest

final class Wave6SequenceAndSheetTests: XCTestCase {
    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safarium-w6-2a-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeSolidPNG(
        to url: URL,
        width: Int,
        height: Int,
        topRGB: (CGFloat, CGFloat, CGFloat),
        bottomRGB: (CGFloat, CGFloat, CGFloat)
    ) throws {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw SafariumError.encode("failed to allocate CGContext for PNG")
        }
        // CoreGraphics origin is bottom-left: fill bottom half first, then top half.
        let halfH = height / 2
        ctx.setFillColor(CGColor(srgbRed: bottomRGB.0, green: bottomRGB.1, blue: bottomRGB.2, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: halfH))
        ctx.setFillColor(CGColor(srgbRed: topRGB.0, green: topRGB.1, blue: topRGB.2, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: halfH, width: width, height: height - halfH))
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SafariumError.encode("failed to create PNG destination at \(url.path)")
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw SafariumError.encode("failed to finalize PNG at \(url.path)")
        }
    }

    private func makeBGRAPixelBuffer(
        width: Int,
        height: Int,
        topBGR: (UInt8, UInt8, UInt8),
        bottomBGR: (UInt8, UInt8, UInt8)
    ) throws -> CVPixelBuffer {
        let pb = try AVAssetWriterSink.allocateStandalonePixelBuffer(width: width, height: height, pixelFormat: .bgra)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else {
            throw SafariumError.encode("missing BGRA base address")
        }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<height {
            let color = (y < height / 2) ? topBGR : bottomBGR
            let row = base.advanced(by: y * stride)
            for x in 0..<width {
                let off = x * 4
                row[off] = color.0
                row[off + 1] = color.1
                row[off + 2] = color.2
                row[off + 3] = 255
            }
        }
        return pb
    }

    private func writeWavTone(to url: URL, durationSeconds: Double = 0.5, sampleRate: Double = 48_000, freqHz: Double = 440.0) throws {
        let channels = 2
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels), interleaved: false)!
        let total = AVAudioFrameCount(max(1, Int((durationSeconds * sampleRate).rounded())))
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: total)!
        buf.frameLength = total
        for ch in 0..<channels {
            let ptr = buf.floatChannelData![ch]
            for i in 0..<Int(total) {
                ptr[i] = Float(0.25 * sin(2.0 * .pi * freqHz * Double(i) / sampleRate))
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buf)
    }

    private func decodeCGImage(at url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw SafariumError.snapshot("failed to decode image at \(url.path)")
        }
        return img
    }

    private func samplePixelRGBA(_ img: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        var px = [UInt8](repeating: 0, count: 4)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: &px,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return (px[0], px[1], px[2], px[3])
    }

    // MARK: - 1. Discovery, Natural Numeric Sort & AppleDouble Filtering

    func testDiscoverSequenceFramesNaturalSortSkipsAppleDoubleAndErrorsOnEmptyOrMissing() throws {
        let root = try makeTempDir("discover")
        defer { try? FileManager.default.removeItem(at: root) }

        let thaiDir = root.appendingPathComponent("ทดสอบเฟรม", isDirectory: true)
        try FileManager.default.createDirectory(at: thaiDir, withIntermediateDirectories: true)

        let names = ["frame_10.png", "frame_2.png", "frame_0001.png", "frame_20.png"]
        for n in names {
            try writeSolidPNG(to: thaiDir.appendingPathComponent(n), width: 32, height: 32, topRGB: (1, 0, 0), bottomRGB: (0, 0, 1))
        }

        // ExFAT AppleDouble sidecars, dotfiles, non-images, and a directory disguised with .png extension.
        try Data("appledouble-junk".utf8).write(to: thaiDir.appendingPathComponent("._frame_0001.png"))
        try Data("appledouble-junk".utf8).write(to: thaiDir.appendingPathComponent("._frame_2.png"))
        try Data("dotfile".utf8).write(to: thaiDir.appendingPathComponent(".hidden.png"))
        try Data("dsstore".utf8).write(to: thaiDir.appendingPathComponent(".DS_Store"))
        try Data("not-an-image".utf8).write(to: thaiDir.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(at: thaiDir.appendingPathComponent("subdir.png", isDirectory: true), withIntermediateDirectories: true)

        let discovered = try ForgeSequenceIngest.discoverSequenceFrames(
            directoryURL: thaiDir,
            globPattern: nil,
            listFileURL: nil
        )
        XCTAssertEqual(
            discovered.map(\.lastPathComponent),
            ["frame_0001.png", "frame_2.png", "frame_10.png", "frame_20.png"]
        )

        // Standalone globPattern without directoryURL
        let globDiscovered = try ForgeSequenceIngest.discoverSequenceFrames(
            directoryURL: nil,
            globPattern: thaiDir.appendingPathComponent("frame_*.png").path,
            listFileURL: nil
        )
        XCTAssertEqual(
            globDiscovered.map(\.lastPathComponent),
            ["frame_0001.png", "frame_2.png", "frame_10.png", "frame_20.png"]
        )

        // List file mode (respects list order, skips comments/blank/._*, rejects missing file)
        let listURL = root.appendingPathComponent("frames.txt")
        try """
        # comment line
        frame_2.png

        ._frame_0001.png
        frame_10.png
        """.write(to: listURL, atomically: true, encoding: .utf8)
        let listDiscovered = try ForgeSequenceIngest.discoverSequenceFrames(
            directoryURL: thaiDir,
            globPattern: nil,
            listFileURL: listURL
        )
        XCTAssertEqual(listDiscovered.map(\.lastPathComponent), ["frame_2.png", "frame_10.png"])

        let badListURL = root.appendingPathComponent("missing_frames.txt")
        try "does_not_exist.png\n".write(to: badListURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(
            try ForgeSequenceIngest.discoverSequenceFrames(directoryURL: thaiDir, globPattern: nil, listFileURL: badListURL)
        )

        // Empty directory (containing only ._ sidecars) must throw SafariumError
        let onlyJunkDir = root.appendingPathComponent("junk_only", isDirectory: true)
        try FileManager.default.createDirectory(at: onlyJunkDir, withIntermediateDirectories: true)
        try Data("appledouble".utf8).write(to: onlyJunkDir.appendingPathComponent("._frame_0001.png"))
        XCTAssertThrowsError(
            try ForgeSequenceIngest.discoverSequenceFrames(directoryURL: onlyJunkDir, globPattern: nil, listFileURL: nil)
        )

        // Missing directory & all-nil inputs must throw SafariumError
        XCTAssertThrowsError(
            try ForgeSequenceIngest.discoverSequenceFrames(directoryURL: root.appendingPathComponent("nope"), globPattern: nil, listFileURL: nil)
        )
        XCTAssertThrowsError(
            try ForgeSequenceIngest.discoverSequenceFrames(directoryURL: nil, globPattern: nil, listFileURL: nil)
        )
    }

    // MARK: - 2. End-to-End Sequence Ingest (Even, Odd, Thai Path, Audio, Inline 3x2 Sheet)

    func testSequenceIngestEndToEndThaiPathEvenAndOddDimensionsWithInlineSheetAndAudio() async throws {
        let root = try makeTempDir("ingest")
        defer { try? FileManager.default.removeItem(at: root) }

        let seqDir = root.appendingPathComponent("ทดสอบเฟรม", isDirectory: true)
        try FileManager.default.createDirectory(at: seqDir, withIntermediateDirectories: true)

        // 12 even-sized PNG frames (128x96): top half varies from red->blue, bottom half bright green.
        let frameCount = 12
        for i in 0..<frameCount {
            let t = CGFloat(i) / CGFloat(frameCount - 1)
            let p = seqDir.appendingPathComponent(String(format: "frame_%04d.png", i + 1))
            try writeSolidPNG(
                to: p,
                width: 128,
                height: 96,
                topRGB: (1.0 - t, 0.1, t),
                bottomRGB: (0.05, 0.9, 0.15)
            )
        }
        try Data("appledouble".utf8).write(to: seqDir.appendingPathComponent("._frame_0001.png"))

        let wavURL = root.appendingPathComponent("audio.wav")
        try writeWavTone(to: wavURL, durationSeconds: 0.6)

        let frames = try ForgeSequenceIngest.discoverSequenceFrames(directoryURL: seqDir, globPattern: nil, listFileURL: nil)
        XCTAssertEqual(frames.count, frameCount)

        let outMP4 = root.appendingPathComponent("seq_even.mp4")
        let sheetPNG = root.appendingPathComponent("seq_sheet.png")
        let sheetCfg = ForgeContactSheetConfig(
            cols: 3,
            rows: 2,
            tileWidth: 64,
            padding: 4,
            bgColorHex: "#0F172A",
            sampling: .uniformCount(nil),
            format: "png"
        )
        let cfg = ForgeSequenceIngestConfig(
            framePaths: frames,
            fps: 24,
            width: nil,
            height: nil,
            codec: .h264,
            bitrate: 2_000_000,
            quality: nil,
            pixelFormat: .nv12Left,
            closedGOP: true,
            audioURL: wavURL,
            inlineSheetConfig: sheetCfg,
            inlineSheetOutputURL: sheetPNG,
            overwrite: true,
            decodeAheadSlots: 3
        )
        let rep = try await ForgeSequenceIngest.run(config: cfg, outputURL: outMP4, progress: nil)
        XCTAssertEqual(rep.width, 128)
        XCTAssertEqual(rep.height, 96)
        XCTAssertEqual(rep.fps, 24)
        XCTAssertEqual(rep.frames, frameCount)
        XCTAssertEqual(rep.codec, "h264")
        XCTAssertGreaterThan(rep.bytes, 0)
        XCTAssertEqual(rep.sheetPath, sheetPNG.path)
        XCTAssertEqual(rep.sheetCols, 3)
        XCTAssertEqual(rep.sheetRows, 2)
        XCTAssertGreaterThan(rep.peakRSSMB, 0)

        let probe = try await PacketProbe.inspect(url: outMP4, includeAudioPackets: false)
        XCTAssertTrue(probe.playable)
        let vTrack = try XCTUnwrap(probe.tracks.first(where: { $0.mediaType == "vide" }))
        XCTAssertEqual(vTrack.packetCount, frameCount)
        XCTAssertEqual(vTrack.formats.first?.width, 128)
        XCTAssertEqual(vTrack.formats.first?.height, 96)
        XCTAssertTrue(probe.tracks.contains(where: { $0.mediaType == "soun" }), "muxed MP4 should include audio track")

        // Verify inline 3x2 PNG sheet dimensions and upright tile orientation.
        XCTAssertTrue(FileManager.default.fileExists(atPath: sheetPNG.path))
        let sheetCG = try decodeCGImage(at: sheetPNG)
        XCTAssertEqual(sheetCG.width, 3 * 64 + 4 * 4)
        XCTAssertEqual(sheetCG.height, 2 * 48 + 3 * 4)
        // Tile 0 (top-left): early frame -> top half red, bottom half green.
        let tile0Top = samplePixelRGBA(sheetCG, x: 4 + 32, y: 4 + 10)
        let tile0Bot = samplePixelRGBA(sheetCG, x: 4 + 32, y: 4 + 38)
        XCTAssertGreaterThan(Int(tile0Top.r), Int(tile0Top.b) + 120)
        XCTAssertGreaterThan(Int(tile0Bot.g), Int(tile0Bot.r) + 120)

        // Odd-sized source PNGs (99x65) with auto dimensions should pad cleanly to even (100x66) for H.264 MP4.
        let oddDir = root.appendingPathComponent("odd_frames", isDirectory: true)
        try FileManager.default.createDirectory(at: oddDir, withIntermediateDirectories: true)
        var oddPaths: [URL] = []
        for i in 0..<10 {
            let p = oddDir.appendingPathComponent("img_\(i).png")
            try writeSolidPNG(to: p, width: 99, height: 65, topRGB: (0.1, 0.85, 0.2), bottomRGB: (0.1, 0.85, 0.2))
            oddPaths.append(p)
        }
        let oddOutMP4 = root.appendingPathComponent("odd_padded.mp4")
        let oddSheet = root.appendingPathComponent("odd_sheet.png")
        let oddCfg = ForgeSequenceIngestConfig(
            framePaths: oddPaths,
            fps: 24,
            width: nil,
            height: nil,
            codec: .h264,
            pixelFormat: .nv12Left,
            inlineSheetConfig: ForgeContactSheetConfig(cols: 3, rows: 2, tileWidth: 50, padding: 4, format: "png"),
            inlineSheetOutputURL: oddSheet,
            overwrite: true,
            decodeAheadSlots: 99
        )
        XCTAssertEqual(oddCfg.decodeAheadSlots, 4)
        XCTAssertEqual(ForgeSequenceIngestConfig(framePaths: oddPaths, decodeAheadSlots: 0).decodeAheadSlots, 1)
        let emitter = SafariumProgressEmitter(enabled: false)
        let oddRep = try await ForgeSequenceIngest.run(config: oddCfg, outputURL: oddOutMP4, progress: emitter)
        XCTAssertEqual(oddRep.width, 100)
        XCTAssertEqual(oddRep.height, 66)
        XCTAssertEqual(oddRep.frames, 10)
        let oddProbe = try await PacketProbe.inspect(url: oddOutMP4, includeAudioPackets: false)
        XCTAssertTrue(oddProbe.playable)
        XCTAssertEqual(oddProbe.tracks.first(where: { $0.mediaType == "vide" })?.packetCount, 10)

        let oddAsset = AVURLAsset(url: oddOutMP4)
        let oddGen = AVAssetImageGenerator(asset: oddAsset)
        oddGen.appliesPreferredTrackTransform = true
        let oddFrame0 = try oddGen.copyCGImage(at: .zero, actualTime: nil)
        let oddPx = samplePixelRGBA(oddFrame0, x: 20, y: 20)
        XCTAssertGreaterThan(Int(oddPx.g), Int(oddPx.r) + 120)

        // Explicit odd dimensions for H.264/NV12 must fail cleanly with descriptive SafariumError.
        let explicitOddOut = root.appendingPathComponent("explicit_odd_fail.mp4")
        let badOddCfg = ForgeSequenceIngestConfig(
            framePaths: oddPaths,
            fps: 24,
            width: 99,
            height: 65,
            codec: .h264,
            pixelFormat: .nv12Left,
            overwrite: true
        )
        do {
            _ = try await ForgeSequenceIngest.run(config: badOddCfg, outputURL: explicitOddOut, progress: nil)
            XCTFail("explicit odd dimensions on H.264/NV12 must throw SafariumError")
        } catch {
            XCTAssertTrue("\(error)".lowercased().contains("even"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: explicitOddOut.path))
        }
    }

    // MARK: - 3. ForgeInlineSheetCollector Zero-Redecode Tests

    func testInlineSheetCollectorZeroRedecodeStreamingAndKnownTotal() throws {
        let root = try makeTempDir("inline-sheet")
        defer { try? FileManager.default.removeItem(at: root) }

        // Streaming mode: totalFrames = nil (no video file exists or is ever read!)
        let streamCfg = ForgeContactSheetConfig(
            cols: 3,
            rows: 2,
            tileWidth: 64,
            tileHeight: 48,
            padding: 6,
            bgColorHex: "#1E293B",
            sampling: .uniformCount(nil),
            format: "png"
        )
        let collector = try ForgeInlineSheetCollector(totalFrames: nil, fps: 24, config: streamCfg)
        XCTAssertTrue(collector.isInlineZeroRedecode)

        for idx in 0..<24 {
            let bVal = UInt8(min(255, idx * 10))
            let rVal = UInt8(max(0, 255 - idx * 10))
            let pb = try makeBGRAPixelBuffer(
                width: 128,
                height: 96,
                topBGR: (bVal, 20, rVal),
                bottomBGR: (240, 180, 10)
            )
            try collector.ingest(frameIndex: idx, pixelBuffer: pb)
        }

        let streamSheetURL = root.appendingPathComponent("stream_sheet.png")
        let report = try collector.finalize(to: streamSheetURL, overwrite: true)
        XCTAssertEqual(report.isInlineZeroRedecode, true)
        XCTAssertEqual(report.cols, 3)
        XCTAssertEqual(report.rows, 2)
        XCTAssertEqual(report.tileCount, 6)
        XCTAssertEqual(report.width, 3 * 64 + 4 * 6)
        XCTAssertEqual(report.height, 2 * 48 + 3 * 6)
        XCTAssertEqual(report.tiles.count, 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: streamSheetURL.path))

        // Verify strictly increasing sampled frame indices across stream
        for i in 1..<report.tiles.count {
            XCTAssertGreaterThan(report.tiles[i].frameIndex, report.tiles[i - 1].frameIndex)
        }

        let img = try decodeCGImage(at: streamSheetURL)
        XCTAssertEqual(img.width, report.width)
        XCTAssertEqual(img.height, report.height)
        // First tile top should be mostly red (rVal=255), bottom should be cyan/blue (b=240, g=180, r=10).
        let t0Top = samplePixelRGBA(img, x: 6 + 32, y: 6 + 10)
        let t0Bot = samplePixelRGBA(img, x: 6 + 32, y: 6 + 38)
        XCTAssertGreaterThan(Int(t0Top.r), Int(t0Top.b) + 150)
        XCTAssertGreaterThan(Int(t0Bot.b), Int(t0Bot.r) + 150)

        // Known totalFrames mode + timestamps mode
        let tsCfg = ForgeContactSheetConfig(
            cols: 2,
            rows: 2,
            tileWidth: 48,
            padding: 4,
            sampling: .timestamps([0.0, 0.25, 0.5, 0.75]),
            format: "png"
        )
        let tsCollector = try ForgeInlineSheetCollector(totalFrames: 12, fps: 12, config: tsCfg)
        for idx in 0..<12 {
            let pb = try makeBGRAPixelBuffer(width: 96, height: 64, topBGR: (10, 220, 10), bottomBGR: (10, 10, 220))
            try tsCollector.ingest(frameIndex: idx, pixelBuffer: pb)
        }
        let tsSheetURL = root.appendingPathComponent("ts_sheet.png")
        let tsRep = try tsCollector.finalize(to: tsSheetURL, overwrite: true)
        XCTAssertEqual(tsRep.tileCount, 4)
        XCTAssertEqual(tsRep.tiles.map(\.frameIndex), [0, 3, 6, 9])

        // 0 ingested frames must throw cleanly on finalize
        let emptyCollector = try ForgeInlineSheetCollector(totalFrames: nil, fps: 24, config: streamCfg)
        XCTAssertThrowsError(try emptyCollector.finalize(to: root.appendingPathComponent("empty.png"), overwrite: true))
    }

    // MARK: - 4. ForgeDualTeeSession primaryAudioCodec (pcm_s16le / copy) & Inline Sheet

    func testDualTeeSessionPrimaryPCMAndCopyAndInlineSheet() async throws {
        let root = try makeTempDir("dual-pcm")
        defer { try? FileManager.default.removeItem(at: root) }

        let wavURL = root.appendingPathComponent("sound.wav")
        try writeWavTone(to: wavURL, durationSeconds: 0.4, sampleRate: 48_000, freqHz: 520.0)

        let priMOV = root.appendingPathComponent("master_prores.mov")
        let secMP4 = root.appendingPathComponent("preview.mp4")
        let sheetPNG = root.appendingPathComponent("pipe_sheet.png")

        let w = 64, h = 64, frames = 8
        let cfg = ForgePipeEncodeConfig(
            width: w,
            height: h,
            fps: 24,
            inputPixelFormat: .bgra,
            primaryCodec: .proRes4444,
            primaryPixelFormat: .bgra,
            secondaryOutputURL: secMP4,
            secondaryCodec: .h264,
            secondaryBackgroundHex: "#102030",
            audioURL: wavURL,
            overwrite: true,
            primaryAudioCodec: "pcm_s16le",
            inlineSheetConfig: ForgeContactSheetConfig(cols: 3, rows: 2, tileWidth: 48, padding: 4, format: "png"),
            inlineSheetOutputURL: sheetPNG
        )
        let session = try ForgeDualTeeSession(primaryOutputURL: priMOV, config: cfg)
        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        for f in 0..<frames {
            for y in 0..<h {
                for x in 0..<w {
                    let off = (y * w + x) * 4
                    let alpha: UInt8 = (x < w / 2) ? 255 : 0
                    bgra[off] = UInt8((40 + f * 20) & 0xFF)
                    bgra[off + 1] = (alpha > 0) ? 190 : 0
                    bgra[off + 2] = (alpha > 0) ? 30 : 0
                    bgra[off + 3] = alpha
                }
            }
            try await session.appendBGRAFrame(bgra)
        }
        let report = try await session.finishAndCommit()
        XCTAssertEqual(report.frames, frames)
        XCTAssertTrue(FileManager.default.fileExists(atPath: priMOV.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secMP4.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sheetPNG.path))
        XCTAssertEqual(report.inlineSheetReport?.isInlineZeroRedecode, true)
        XCTAssertEqual(report.inlineSheetReport?.tileCount, 6)

        // Primary ProRes .mov must contain uncompressed pcm_s16le (lpcm, 16-bit signed LE)
        let priProbe = try await PacketProbe.inspect(url: priMOV, includeAudioPackets: false)
        XCTAssertTrue(priProbe.playable)
        let priAudio = try XCTUnwrap(priProbe.tracks.first(where: { $0.mediaType == "soun" }))
        XCTAssertEqual(priAudio.formats.first?.codec, "lpcm")

        let movAsset = AVURLAsset(url: priMOV)
        let movTracks = try await movAsset.loadTracks(withMediaType: .audio)
        let movATrack = try XCTUnwrap(movTracks.first)
        let movFmts = try await movATrack.load(.formatDescriptions)
        let asbdPtr = try XCTUnwrap(CMAudioFormatDescriptionGetStreamBasicDescription(movFmts[0]))
        let asbd = asbdPtr.pointee
        XCTAssertEqual(asbd.mFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(asbd.mBitsPerChannel, 16)
        XCTAssertEqual(asbd.mFormatFlags & kAudioFormatFlagIsBigEndian, 0)
        XCTAssertNotEqual(asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger, 0)

        // Secondary .mp4 must keep AAC audio
        let secProbe = try await PacketProbe.inspect(url: secMP4, includeAudioPackets: false)
        XCTAssertTrue(secProbe.playable)
        let secAudio = try XCTUnwrap(secProbe.tracks.first(where: { $0.mediaType == "soun" }))
        XCTAssertEqual(secAudio.formats.first?.codec.trimmingCharacters(in: .whitespaces), "aac")

        // Copy audio codec test: M4A (AAC) passthrough into primary MP4
        let m4aURL = root.appendingPathComponent("audio.m4a")
        _ = try await AudioMixer.mix(tracks: [AudioMixTrack(url: wavURL)], to: m4aURL, overwrite: true)
        let copyMP4 = root.appendingPathComponent("copy_audio.mp4")
        let copyCfg = ForgePipeEncodeConfig(
            width: 64,
            height: 64,
            fps: 24,
            inputPixelFormat: .bgra,
            primaryCodec: .h264,
            audioURL: m4aURL,
            overwrite: true,
            primaryAudioCodec: "copy"
        )
        let copySession = try ForgeDualTeeSession(primaryOutputURL: copyMP4, config: copyCfg)
        for _ in 0..<6 {
            try await copySession.appendBGRAFrame(bgra)
        }
        _ = try await copySession.finishAndCommit()
        let copyProbe = try await PacketProbe.inspect(url: copyMP4, includeAudioPackets: false)
        XCTAssertTrue(copyProbe.playable)
        XCTAssertEqual(copyProbe.tracks.first(where: { $0.mediaType == "soun" })?.formats.first?.codec.trimmingCharacters(in: .whitespaces), "aac")

        // Validation errors: unsupported primaryAudioCodec & pcm_s16le on MP4
        XCTAssertThrowsError(try ForgeDualTeeSession(
            primaryOutputURL: root.appendingPathComponent("bad_codec.mov"),
            config: ForgePipeEncodeConfig(
                width: 64, height: 64, fps: 24, primaryCodec: .proRes4444,
                audioURL: wavURL, overwrite: true, primaryAudioCodec: "opus"
            )
        ))
        XCTAssertThrowsError(try ForgeDualTeeSession(
            primaryOutputURL: root.appendingPathComponent("bad_mp4_pcm.mp4"),
            config: ForgePipeEncodeConfig(
                width: 64, height: 64, fps: 24, primaryCodec: .h264,
                audioURL: wavURL, overwrite: true, primaryAudioCodec: "pcm_s16le"
            )
        ))
    }
}
