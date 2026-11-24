import CoreMedia
import Darwin
import Foundation
import SafariumCore

private struct HTMLRenderJSONReport: Encodable {
    let ok: Bool
    let output: String
    let width: Int
    let height: Int
    let fps: Int
    let frames: Int
    let codec: String
    let sha256: String?
    let wallMs: Double
    let footprintMB: Double
}

@main
private struct SafariumHTML {
    @MainActor static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] || args == ["-h"] { print(usage); return }
        let wantJSONErrors = args.contains("--json-errors") || ProcessInfo.processInfo.environment["SAFARIUM_JSON_ERRORS"] == "1"
        do {
            let t0 = DispatchTime.now().uptimeNanoseconds
            let o = try Options(args)
            let audio = try o.audio.map { try WAVRange(url: $0, options: o) }
            let subtitles: (CMFormatDescription, [CMSampleBuffer])? = try o.subtitles.map { url in
                let cues = try SafariumTX3G.parseSRT(url: url, offsetSeconds: o.start, duration: o.duration)
                return try SafariumTX3G.buildContiguousSamples(cues: cues, duration: o.duration, width: o.width, height: o.height)
            }
            let stage = try Staging(destination: o.output)
            // Cleanup and atomic commit both run on the main actor. An interrupt
            // while WebKit/AVFoundation is busy can discard only our private files.
            let signals = [SIGTERM, SIGINT].map { sig in
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler { stage.cleanup(); _exit(128 + sig) }
                source.resume()
                return source
            }
            defer { signals.forEach { $0.cancel() }; stage.cleanup() }
            let stagedOutput = stage.outputURL(extension: o.codec.fileExtension)
            let digest = try await captureAndEncode(o, audio: audio, subtitles: subtitles, into: stage, outputURL: stagedOutput)
            try await PublishedAssetCheck.verify(stagedOutput, options: o, audio: audio, hasSubtitles: subtitles != nil)
            try stage.publish(stagedOutput)
            if o.jsonOutput || o.hashFrames {
                let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                let report = HTMLRenderJSONReport(
                    ok: true,
                    output: o.output.path,
                    width: o.width,
                    height: o.height,
                    fps: o.fps,
                    frames: o.frames,
                    codec: o.codec.rawValue,
                    sha256: digest,
                    wallMs: (wallMs * 1000.0).rounded() / 1000.0,
                    footprintMB: (SafariumRuntimeTelemetry.currentFootprintMB() * 100.0).rounded() / 100.0
                )
                let enc = JSONEncoder()
                enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                var d = try enc.encode(report)
                d.append(0x0A)
                FileHandle.standardOutput.write(d)
            } else {
                print(o.output.path)
            }
        } catch {
            if wantJSONErrors {
                let code: SafariumErrorCode? = (error is WorkerError) ? .E_USAGE : nil
                FileHandle.standardError.write(SafariumStructuredErrorEnvelope.from(error, tool: "safarium-html", overrideCode: code).jsonLineData())
            } else {
                FileHandle.standardError.write(Data("safarium-html: \(error)\n".utf8))
            }
            exit(2)
        }
    }
}
