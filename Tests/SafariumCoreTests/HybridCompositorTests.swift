import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import SafariumCore
import XCTest

@MainActor
final class HybridCompositorTests: XCTestCase {
    override func setUp() async throws { HostApp.prepare() }

    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("safarium-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeColorPlateVideo(url: URL, width: Int, height: Int, fps: Int, frames: Int) async throws {
        let sink = try AVAssetWriterSink(url: url, width: width, height: height, fps: fps, codec: .h264, bitrate: 2_000_000)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        for i in 0..<frames {
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: sRGB, bitmapInfo: bitmapInfo)!
            // Encode frame index in bottom-left 16x16 blocks so exact frame ordering is verifiable
            ctx.setFillColor(CGColor(colorSpace: sRGB, components: [0.1, 0.2, 0.6, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for b in 0..<6 {
                let on = ((i >> b) & 1) == 1
                ctx.setFillColor(CGColor(colorSpace: sRGB, components: [on ? 1 : 0, on ? 1 : 0, on ? 1 : 0, 1])!)
                ctx.fill(CGRect(x: b * 24, y: height - 24, width: 24, height: 24))
            }
            try await sink.append(Snapshot(cgImage: ctx.makeImage()!))
        }
        try await sink.finish()
    }

    func testSequentialVideoReaderForwardWrapAndBackwardRestart() async throws {
        let dir = try makeTempDir("seq-reader")
        defer { try? FileManager.default.removeItem(at: dir) }

        let mp4 = dir.appendingPathComponent("clip.mp4")
        try await makeColorPlateVideo(url: mp4, width: 160, height: 120, fps: 30, frames: 20)

        let reader = try await SafariumSequentialVideoReader(url: mp4, loop: true, startTimeOffset: 0)
        defer { reader.close() }
        XCTAssertEqual(reader.width, 160)
        XCTAssertEqual(reader.height, 120)

        let ciCtx = SafariumMetalContext.shared?.ciContext ?? CIContext()
        func decodeBits(_ pb: CVPixelBuffer) throws -> Int {
            let ci = CIImage(cvPixelBuffer: pb)
            let cg = try XCTUnwrap(ciCtx.createCGImage(ci, from: ci.extent))
            let snap = Snapshot(cgImage: cg)
            var v = 0
            for b in 0..<6 {
                if snap.pixel(x: 12 + b * 24, y: 12).g > 128 { v |= (1 << b) }
            }
            return v
        }

        // Sequential forward
        for i in 0..<15 {
            let pb = try XCTUnwrap(try reader.pixelBuffer(at: (Double(i) + 0.5) / 30.0))
            let got = try decodeBits(pb)
            XCTAssertEqual(got, i, "forward frame \(i)")
        }
        // Backward seek restart
        let pbBack = try XCTUnwrap(try reader.pixelBuffer(at: 3.5 / 30.0))
        XCTAssertEqual(try decodeBits(pbBack), 3)

        // Loop wrap beyond duration (frame 22 mod 20 == 2)
        let pbWrap = try XCTUnwrap(try reader.pixelBuffer(at: 22.5 / 30.0))
        XCTAssertEqual(try decodeBits(pbWrap), 2)
    }

    func testHybridCompositorStaticPlateAndVideoOverlayRender() async throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let dir = try makeTempDir("hybrid-comp")
        defer { try? FileManager.default.removeItem(at: dir) }

        let bgHTML = dir.appendingPathComponent("bg.html")
        try """
        <!doctype html><meta charset="utf-8"><style>
        html,body{margin:0;width:100%;height:100%;background:#1e3a8a}
        #box{position:absolute;left:40px;top:40px;width:80px;height:80px;background:#f59e0b}
        </style><body><div id="box"></div></body>
        """.write(to: bgHTML, atomically: true, encoding: .utf8)

        let page = try await Page(config: PageConfig(width: 240, height: 180, deterministicClock: true))
        defer { page.close() }
        try await page.load(.fileURL(bgHTML))

        let comp = try SafariumHybridCompositor()
        try await comp.captureStaticPlate(page: page, width: 240, height: 180)

        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ovCtx = CGContext(data: nil, width: 240, height: 180, bitsPerComponent: 8, bytesPerRow: 240 * 4, space: sRGB, bitmapInfo: bitmapInfo)!
        ovCtx.clear(CGRect(x: 0, y: 0, width: 240, height: 180))
        ovCtx.setFillColor(CGColor(colorSpace: sRGB, components: [0.95, 0.25, 0.25, 1.0])!)
        ovCtx.fill(CGRect(x: 120, y: 60, width: 60, height: 60))
        let overlayCG = ovCtx.makeImage()!

        var outPBOpt: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 240, 180, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ] as CFDictionary, &outPBOpt)
        let outPB = try XCTUnwrap(outPBOpt)

        try comp.compositeScene(
            params: HybridSceneParams(
                panX: 0, panY: 0,
                spotCenterCSS: CGPoint(x: 80, y: 80), spotInnerR: 120, spotOuterR: 260,
                spotTintRGBA: (0, 0, 0, 0.4),
                shadowOffsetCSS: CGPoint(x: 6, y: 6), shadowSigma: 4,
                shadowColorRGBA: (0, 0, 0, 0.5)
            ),
            overlay: overlayCG,
            into: outPB,
            outWidth: 240,
            outHeight: 180
        )

        let ciCtx = comp.context.ciContext
        let outCG = try XCTUnwrap(ciCtx.createCGImage(CIImage(cvPixelBuffer: outPB), from: CGRect(x: 0, y: 0, width: 240, height: 180)))
        let snap = Snapshot(cgImage: outCG)
        // Overlay red rectangle at CSS (150, 90)
        let ovPx = snap.pixel(x: 150, y: 90)
        XCTAssertGreaterThan(ovPx.r, 200)
        // Static plate orange box at CSS (60, 60)
        let platePx = snap.pixel(x: 60, y: 60)
        XCTAssertGreaterThan(platePx.r, 200)
        XCTAssertGreaterThan(platePx.g, 130)

        // End-to-end hybrid video + transparent HTML overlay render
        let plateVideo = dir.appendingPathComponent("plate.mp4")
        try await makeColorPlateVideo(url: plateVideo, width: 160, height: 120, fps: 15, frames: 8)
        let overlayHTML = dir.appendingPathComponent("overlay.html")
        try """
        <!doctype html><meta charset="utf-8"><style>
        html,body{margin:0;width:100%;height:100%;background:rgba(0,0,0,0);}
        #badge{position:absolute;right:10px;bottom:10px;width:40px;height:40px;background:#ef4444;}
        </style><body><div id="badge"></div></body>
        """.write(to: overlayHTML, atomically: true, encoding: .utf8)

        let outMP4 = dir.appendingPathComponent("hybrid.mp4")
        let report = try await SafariumHybridCompositor.renderHybridVideo(
            htmlURL: overlayHTML,
            videoURL: plateVideo,
            outputURL: outMP4,
            width: 160,
            height: 120,
            fps: 15,
            frames: 8,
            codec: .h264,
            bitrate: 2_000_000
        )
        XCTAssertEqual(report.frames, 8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outMP4.path))
    }

    func testStaticPlateOrientationNotFlippedVertically() async throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let dir = try makeTempDir("hybrid-orient")
        defer { try? FileManager.default.removeItem(at: dir) }

        let bgHTML = dir.appendingPathComponent("asymmetric.html")
        try """
        <!doctype html><meta charset="utf-8"><style>
        html,body{margin:0;width:100%;height:100%;position:relative;}
        #top{position:absolute;left:0;top:0;width:240px;height:60px;background:#ff0000;}
        #bot{position:absolute;left:0;top:120px;width:240px;height:60px;background:#0000ff;}
        </style><body><div id="top"></div><div id="bot"></div></body>
        """.write(to: bgHTML, atomically: true, encoding: .utf8)

        let page = try await Page(config: PageConfig(width: 240, height: 180, deterministicClock: true))
        defer { page.close() }
        try await page.load(.fileURL(bgHTML))

        let comp = try SafariumHybridCompositor()
        try await comp.captureStaticPlate(page: page, width: 240, height: 180)

        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ovCtx = CGContext(data: nil, width: 240, height: 180, bitsPerComponent: 8, bytesPerRow: 240 * 4, space: sRGB, bitmapInfo: bitmapInfo)!
        ovCtx.clear(CGRect(x: 0, y: 0, width: 240, height: 180))
        let clearOverlay = ovCtx.makeImage()!

        var outPBOpt: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 240, 180, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ] as CFDictionary, &outPBOpt)
        let outPB = try XCTUnwrap(outPBOpt)

        try comp.compositeScene(
            params: HybridSceneParams(),
            overlay: clearOverlay,
            into: outPB,
            outWidth: 240,
            outHeight: 180
        )

        let outCG = try XCTUnwrap(comp.context.ciContext.createCGImage(CIImage(cvPixelBuffer: outPB), from: CGRect(x: 0, y: 0, width: 240, height: 180)))
        let snap = Snapshot(cgImage: outCG)
        let topPx = snap.pixel(x: 120, y: 30)
        let botPx = snap.pixel(x: 120, y: 150)
        XCTAssertGreaterThan(topPx.r, 230, "top band must remain red")
        XCTAssertLessThan(topPx.b, 20)
        XCTAssertGreaterThan(botPx.b, 230, "bottom band must remain blue")
        XCTAssertLessThan(botPx.r, 20)
    }

    func testRenderHybridVideoAnimatedHTMLWithoutHybridHookUpdatesEveryFrame() async throws {
        let dir = try makeTempDir("hybrid-no-hook")
        defer { try? FileManager.default.removeItem(at: dir) }

        let animHTML = dir.appendingPathComponent("anim.html")
        try """
        <!doctype html><meta charset="utf-8"><style>
        html,body{margin:0;width:100%;height:100%;background:rgba(0,0,0,0);}
        #box{position:absolute;left:10px;top:10px;width:60px;height:100px;background:#ff0000;}
        </style><body><div id="box"></div><script>
        window.__seek = function(t) {
            const box = document.getElementById('box');
            if (t >= 0.05) {
                box.style.left = '80px';
                box.style.background = '#00ff00';
            } else {
                box.style.left = '10px';
                box.style.background = '#ff0000';
            }
        };
        </script></body>
        """.write(to: animHTML, atomically: true, encoding: .utf8)

        let outMOV = dir.appendingPathComponent("anim.mov")
        _ = try await SafariumHybridCompositor.renderHybridVideo(
            htmlURL: animHTML,
            videoURL: nil,
            outputURL: outMOV,
            width: 160,
            height: 120,
            fps: 30,
            frames: 4,
            codec: .hevcAlpha
        )
        let f0 = try await readBackFrame(outMOV, index: 0)
        let f3 = try await readBackFrame(outMOV, index: 3)
        func px(_ f: (w: Int, h: Int, bgra: [UInt8]), _ x: Int, _ y: Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
            let o = (y * f.w + x) * 4
            return (f.bgra[o], f.bgra[o + 1], f.bgra[o + 2], f.bgra[o + 3])
        }
        XCTAssertGreaterThan(px(f0, 35, 60).r, 200)
        XCTAssertLessThan(px(f3, 35, 60).a, 20, "frame 0 red box must not stay frozen underneath frame 3")
        XCTAssertGreaterThan(px(f3, 105, 60).g, 200)
    }

    func testRotatedPreferredTransformVideoInReaderAndHybrid() async throws {
        let dir = try makeTempDir("hybrid-rot")
        defer { try? FileManager.default.removeItem(at: dir) }

        let rotMP4 = dir.appendingPathComponent("rotated.mp4")
        let writer = try AVAssetWriter(url: rotMP4, fileType: .mp4)
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: AVAssetWriterSink.buildVideoSettings(
            width: 160, height: 120, fps: 15, codec: .h264, bitrate: 1_500_000, quality: nil
        ))
        vi.transform = CGAffineTransform(rotationAngle: .pi / 2)
        vi.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vi,
            sourcePixelBufferAttributes: AVAssetWriterSink.pixelBufferAttributes(width: 160, height: 120, pixelFormat: .bgra)
        )
        writer.add(vi)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        for i in 0..<4 {
            while !vi.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            let buf = pb!
            CVPixelBufferLockBaseAddress(buf, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf)!, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: sRGB, bitmapInfo: info)!
            // Top half in raw coded buffer (CG y=60..120) = red; bottom half (CG y=0..60) = blue.
            // Rotated 90 deg CW -> displayed 120x160 portrait: right half = red, left half = blue.
            ctx.setFillColor(CGColor(colorSpace: sRGB, components: [0, 0, 1, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 60))
            ctx.setFillColor(CGColor(colorSpace: sRGB, components: [1, 0, 0, 1])!)
            ctx.fill(CGRect(x: 0, y: 60, width: 160, height: 60))
            CVPixelBufferUnlockBaseAddress(buf, [])
            XCTAssertTrue(adaptor.append(buf, withPresentationTime: CMTime(value: Int64(i), timescale: 15)))
        }
        vi.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 4, timescale: 15))
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)

        let reader = try await SafariumSequentialVideoReader(url: rotMP4, loop: true)
        defer { reader.close() }
        XCTAssertEqual(reader.width, 120)
        XCTAssertEqual(reader.height, 160)

        let outMP4 = dir.appendingPathComponent("rot-hybrid.mp4")
        let rep = try await SafariumHybridCompositor.renderHybridVideo(
            htmlURL: nil, videoURL: rotMP4, outputURL: outMP4,
            width: 120, height: 160, fps: 15, frames: 3
        )
        XCTAssertEqual(rep.width, 120)
        XCTAssertEqual(rep.height, 160)
        let f = try await readBackFrame(outMP4, index: 1)
        let leftOff = (80 * f.w + 30) * 4
        let rightOff = (80 * f.w + 90) * 4
        XCTAssertGreaterThan(f.bgra[leftOff], 200, "left half of 90-CW portrait must be blue")
        XCTAssertLessThan(f.bgra[leftOff + 2], 40)
        XCTAssertGreaterThan(f.bgra[rightOff + 2], 200, "right half of 90-CW portrait must be red")
        XCTAssertLessThan(f.bgra[rightOff], 40)
    }

    func testRenderHybridVideoSurfacesJSErrorAndBlocksRemoteFetch() async throws {
        let dir = try makeTempDir("hybrid-sec")
        defer { try? FileManager.default.removeItem(at: dir) }

        let errHTML = dir.appendingPathComponent("err.html")
        try """
        <!doctype html><meta charset="utf-8"><body><script>
        window.__seek = function() { throw new Error("boom-hybrid"); };
        </script></body>
        """.write(to: errHTML, atomically: true, encoding: .utf8)

        do {
            _ = try await SafariumHybridCompositor.renderHybridVideo(
                htmlURL: errHTML, videoURL: nil,
                outputURL: dir.appendingPathComponent("err.mp4"),
                width: 120, height: 120, fps: 15, frames: 2
            )
            XCTFail("Expected JS error to fail renderHybridVideo")
        } catch {
            XCTAssertTrue("\(error)".contains("boom-hybrid"), "unexpected error: \(error)")
        }

        let netHTML = dir.appendingPathComponent("net.html")
        try """
        <!doctype html><meta charset="utf-8"><body><script>
        window.__blocked = false;
        fetch("https://example.invalid/ping").catch(() => { window.__blocked = true; });
        window.__seek = function() {
            if (!window.__blocked) { throw new Error("network request was not blocked by local-only rule list"); }
        };
        </script></body>
        """.write(to: netHTML, atomically: true, encoding: .utf8)

        let outMP4 = dir.appendingPathComponent("net.mp4")
        let report = try await SafariumHybridCompositor.renderHybridVideo(
            htmlURL: netHTML, videoURL: nil, outputURL: outMP4,
            width: 120, height: 120, fps: 15, frames: 2
        )
        XCTAssertEqual(report.frames, 2)
    }

    func testWave2MetalEffectsPaperCutoutAndMarkerTextureProduceValidOutput() async throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let dir = try makeTempDir("w2-effects")
        defer { try? FileManager.default.removeItem(at: dir) }
        let archiveURL = dir.appendingPathComponent("effects.metallib-archive")

        let engine = try Wave2MetalEffectsEngine(binaryArchiveURL: archiveURL, bakeArchive: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path), "MTLBinaryArchive cache should serialize cleanly without xcrun metal")

        let w = 160, h = 120
        func makeBGRA(drawSticker: Bool) throws -> CVPixelBuffer {
            var pb: CVPixelBuffer?
            let st = CVPixelBufferCreate(
                kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                [
                    kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                ] as CFDictionary,
                &pb
            )
            XCTAssertEqual(st, kCVReturnSuccess)
            let buf = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buf, [])
            defer { CVPixelBufferUnlockBaseAddress(buf, []) }
            let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(buf), width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buf),
                space: Snapshot.colorSpace, bitmapInfo: Snapshot.bitmapInfo
            )!
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.setFillColor(red: 0.85, green: 0.25, blue: 0.2, alpha: 1.0)
            if drawSticker {
                ctx.fill(CGRect(x: 40, y: 30, width: 80, height: 60))
            } else {
                ctx.fill(CGRect(x: 30, y: 20, width: 100, height: 80))
            }
            return buf
        }

        // Paper cutout adds bright off-white border pixels immediately outside the opaque sticker box
        let stickerPB = try makeBGRA(drawSticker: true)
        let cutoutOut = try engine.applyEffect(.paperCutout, to: stickerPB)
        CVPixelBufferLockBaseAddress(cutoutOut, .readOnly)
        let cutoutBytes = CVPixelBufferGetBaseAddress(cutoutOut)!.assumingMemoryBound(to: UInt8.self)
        let cutoutStride = CVPixelBufferGetBytesPerRow(cutoutOut)
        // Row y=25 (5px above sticker at y=30) was transparent before and should now have border alpha > 0
        let borderPixelAlpha = cutoutBytes[25 * cutoutStride + 80 * 4 + 3]
        CVPixelBufferUnlockBaseAddress(cutoutOut, .readOnly)
        XCTAssertGreaterThan(borderPixelAlpha, 100)

        // Marker texture (linearFilter = 0) produces crisp non-trivial output
        let markerPB = try makeBGRA(drawSticker: false)
        let markerOut = try engine.applyEffect(.markerTexture, to: markerPB)
        CVPixelBufferLockBaseAddress(markerOut, .readOnly)
        let markerBytes = CVPixelBufferGetBaseAddress(markerOut)!.assumingMemoryBound(to: UInt8.self)
        let markerStride = CVPixelBufferGetBytesPerRow(markerOut)
        let centerR = markerBytes[60 * markerStride + 80 * 4 + 2]
        CVPixelBufferUnlockBaseAddress(markerOut, .readOnly)
        XCTAssertGreaterThan(centerR, 80)
    }

    func testSplitMetalFXScalerPreserves1xOverlay() async throws {
        try XCTSkipIf(SafariumMetalContext.shared == nil, "Metal GPU unavailable on headless CI VM")
        let dir = try makeTempDir("w2-metalfx-split")
        defer { try? FileManager.default.removeItem(at: dir) }

        let bgHTML = dir.appendingPathComponent("bg.html")
        try """
        <!doctype html><html><body style="margin:0;width:160px;height:120px;background:linear-gradient(135deg,#0b7285,#364fc7);font-family:sans-serif;color:#fff;padding:12px;">
        <div style="font-size:20px;font-weight:700;">โปแลนด์ EP30</div>
        </body></html>
        """.write(to: bgHTML, atomically: true, encoding: .utf8)

        let outMP4 = dir.appendingPathComponent("split-metalfx.mp4")
        let report = try await SafariumHybridCompositor.renderHybridVideo(
            htmlURL: bgHTML, videoURL: nil, outputURL: outMP4,
            width: 160, height: 120, fps: 15, frames: 3,
            effect: .paperCutout, splitMetalFX: true
        )
        XCTAssertEqual(report.frames, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outMP4.path))
    }
}
