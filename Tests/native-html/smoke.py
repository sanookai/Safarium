#!/usr/bin/env python3
"""Run under the shared labslot: python3 smoke.py /path/to/safarium-html /path/to/scratch.
Uses real WebKit/AVFoundation, synthetic local input and an independent Apple reader."""
import argparse
import array
import json
import math
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import time
import wave

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("worker", type=Path)
parser.add_argument("scratch", type=Path)
parser.add_argument("--review-fixtures", type=Path, help="use the independent reviewer's original synthetic inputs")
parser.add_argument("--gsap", type=Path, help="also exercise a locally supplied real paused GSAP timeline")
parser.add_argument("--native-deadline", action="store_true", help="also check the 30 s native evaluation deadline")
args = parser.parse_args()
worker = args.worker.resolve(strict=True)
root = Path(tempfile.mkdtemp(prefix="smoke-", dir=args.scratch.resolve(strict=True)))
quality_args = []
for flag, path in [("--review-fixtures", args.review_fixtures), ("--gsap", args.gsap)]:
    if path is not None: quality_args.extend([flag, path.resolve(strict=True)])
if args.native_deadline: quality_args.append("--native-deadline")
print(f"native-html smoke: {root}", flush=True)
inspect = root / "inspect"
subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-target", f"{platform.machine()}-apple-macosx14.0",
                "-module-cache-path", root / "modules",
                Path(__file__).with_name("Inspect.swift"), "-o", inspect], check=True)
page = root / "animation.html"
page.write_text("""<!doctype html><meta charset="utf-8"><style>
html,body{margin:0;width:100%;height:100%}#right{position:absolute;inset:0 0 0 50%}
</style><body><div id="right"></div><audio src="sound.wav"></audio><script>
const colors = ['#ff0000','#00ff00','#0000ff'];
window.__seek = async t => { await Promise.resolve(); document.body.style.background = colors[Math.round(t*25)%3] };
window.__timelines = { main: { pause() {}, seek(t) {
 document.querySelector('#right').style.background = colors[(Math.round(t*25)+1)%3] } } };
</script></body>""")
wav = root / "sound.wav"
rate = 48000
signal = array.array("h", (round(10000 * math.sin(2*math.pi*(400*t+850*t*t)) +
                                 6000 * math.sin(2*math.pi*(1500*t+1600*t*t)))
                           for t in (i / rate for i in range(2 * rate))))
with wave.open(str(wav), "wb") as f:
    f.setparams((1, 2, rate, 0, "NONE", "not compressed"))
    f.writeframes(signal.tobytes())

size = ["--width", "160", "--height", "96", "--fps", "25", "--frames", "11", "--bitrate", "1800000", "--start", "0.28"]
def run(args, failure=None):
    p = subprocess.run([worker, *args], cwd=root, text=True, capture_output=True, timeout=90)
    if failure is None:
        assert p.returncode == 0, (args, p.stderr)
    else:
        assert p.returncode != 0 and failure.lower() in p.stderr.lower(), (args, p.returncode, p.stderr)
    assert not list(root.glob(".safarium-html-*")), "staging directory was not cleaned"
    return p

report = {"synthetic": True, "width": 160, "height": 96, "fps": 25, "frames": 11, "audio": {}}
def correlation(x, y):
    mx, my = sum(x) / len(x), sum(y) / len(y)
    xx = [a - mx for a in x]
    yy = [b - my for b in y]
    return sum(a*b for a,b in zip(xx, yy)) / math.sqrt(sum(a*a for a in xx) * sum(b*b for b in yy))

for name, extra, first in [("independent", ["--audio-start", "0.4130625"], 19827), ("picture-start", [], 13440)]:
    out = root / f"{name}.mp4"
    p = run([page, "--output", out, *size, "--audio", wav, *extra])
    assert "using only the supplied WAV" in p.stderr
    raw = root / f"{name}.f32"
    subprocess.run([inspect, out, "160", "96", "25", "11", "7", raw], check=True)
    decoded = array.array("f"); decoded.frombytes(raw.read_bytes())
    assert len(decoded) == 21120
    edges = []
    for edge in (0, len(decoded) - 4096):
        window = decoded[edge:edge+4096]
        correlations = {k: correlation(window, signal[first+edge+k:first+edge+k+4096]) for k in range(-12, 13)}
        best = max(correlations, key=correlations.get)
        assert correlations[0] >= 0.95 and abs(best) <= 1, (name, edge, correlations[0], best)
        edges.append({"zero_lag_r": correlations[0], "best_lag_samples": best})
    report["audio"][name] = {"first_source_sample": first, "presented_samples": len(decoded), "edges": edges}

static = root / "static.html"
static.write_text("<!doctype html><style>html{background:#f00}</style>")
out = root / "static.mp4"
run([static, "--output", out, "--width", "104", "--height", "76", "--fps", "31", "--frames", "1", "--video-only"])
subprocess.run([inspect, out, "104", "76", "31", "1", "-1", "-"], check=True)
report["static"] = "one opaque frame at 104x76, duration 1/31, H.264/BT.709, no audio track"

bad = root / "bad.mp4"
base = [page, "--output", bad, *size]
rejections = [
    (base, "exactly one"),
    ([*base, "--video-only", "--audio", wav], "exactly one"),
    ([*base, "--video-only", "--audio-start", "0"], "requires --audio"),
    ([*base, "--video-only", "--engine", "other"], "unknown option"),
    ([*base, "--video-only", "--width", "120"], "duplicate"),
    ([*base, "--audio", wav, "--audio-start", "1.9"], "incomplete WAV range"),
    ([*base, "--audio", wav, "--audio-start", "0.00001"], "sample boundary"),
    ([page, "--output", bad, "--width", "100", "--height", "80", "--fps", "31", "--frames", "1", "--audio", wav], "sample boundary"),
    ([page, "--output", bad, "--width", "101", "--height", "80", "--fps", "30", "--frames", "1", "--video-only"], "must be even"),
    ([page, "--output", bad, "--width", "100", "--height", "80", "--fps", "29.97", "--frames", "1", "--video-only"], "positive 32-bit integer"),
    ([page, "--output", root/"bad.mov", *size, "--video-only"], ".mp4"),
    ([*base, "--audio", page], ".wav"),
    ([page, "--output", bad, *size, "--video-only", "--transparent"], "requires an alpha codec"),
    ([page, "--output", bad, *size, "--video-only", "--codec", "hevc-alpha"], ".mov"),
    ([page, "--output", root/"bad-nv12.mov", *size, "--video-only", "--codec", "hevc-alpha", "--transparent", "--pixel-format", "nv12-vimage"], "cannot be used with alpha"),
    ([*base, "--video-only", "--subtitle-lang", "pol"], "requires --subtitles"),
    ([page, "--output", bad, "--width", "160", "--height", "96", "--fps", "25", "--frames", "3", "--bitrate", "1000000", "--quality", "0.8", "--video-only"], "not both"),
]
fake = root / "fake.wav"; fake.write_bytes(b"this is not a RIFF WAVE file")
rejections.append(([*base, "--audio", fake], "RIFF/WAVE"))
low = root / "low.wav"
with wave.open(str(low), "wb") as f:
    f.setparams((1, 2, 8000, 0, "NONE", "not compressed")); f.writeframes(bytes(16000))
rejections.append(([*base, "--audio", low], "Apple AAC-LC cannot encode 8000 Hz"))
for args, message in rejections:
    run(args, message)
assert not bad.exists()
for name, body, fail in [
    ("embedded", "window.__seek = t => { if (t>.30) document.body.append(document.createElement('video')) }", "embedded video"),
    ("custom", "window.__sfVideoSeek = () => {}", "custom video"),
    ("thrown", "window.__timelines={main:{seek(){throw Error('bad timeline')}}}", "bad timeline"),
]:
    src = root / f"{name}.html"; src.write_text(f"<!doctype html><meta charset=utf-8><body><script>{body}</script>")
    run([src, "--output", bad, *size, "--video-only"], fail)
    assert not bad.exists()

sentinel = b"someone else's existing output\n"
bad.write_bytes(sentinel)
run([*base, "--video-only"], "already exists"); assert bad.read_bytes() == sentinel
dangling = root / "dangling.mp4"; dangling.symlink_to(root / "absent")
run([page, "--output", dangling, *size, "--video-only"], "already exists")
assert dangling.is_symlink() and not (root / "absent").exists()

# A competing publisher appears AFTER initial lstat, while our worker is rendering.
raced = root / "raced.mp4"
with subprocess.Popen([worker, page, "--output", raced, *size, "--video-only"], cwd=root,
                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as proc:
    end = time.monotonic() + 30
    while not list(root.glob(".safarium-html-*")):
        if proc.poll() is not None or time.monotonic() >= end:
            proc.kill(); raise AssertionError("worker did not create private staging")
        time.sleep(.005)
    with raced.open("xb") as f: f.write(sentinel)
    _, err = proc.communicate(timeout=90)
    assert proc.returncode != 0 and "publish new output" in err, err
assert raced.read_bytes() == sentinel and not list(root.glob(".safarium-html-*"))
report["rejections"] = len(rejections) + 3
report["no_replace"] = ["existing file", "dangling symlink", "file created during render"]

# Unified v2 flags: hevc-alpha --transparent, nv12-vimage, snapshot-quality sharp, tx3g Polish+Thai subtitles.
extra_inspect_src = root / "extra_inspect.swift"
extra_inspect_bin = root / "extra_inspect"
extra_inspect_src.write_text("""import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

@main struct ExtraInspect {
    static func main() async {
        do {
            let a = Array(CommandLine.arguments.dropFirst())
            let mode = a[0], path = a[1]
            let asset = AVURLAsset(url: URL(fileURLWithPath: path), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            let tracks = try await asset.load(.tracks)
            if mode == "alpha" {
                guard let vt = tracks.first(where: { $0.mediaType == .video }) else { throw NSError(domain: "E", code: 1) }
                let fd = try await vt.load(.formatDescriptions)[0]
                guard CMFormatDescriptionGetMediaSubType(fd) == kCMVideoCodecType_HEVC else { throw NSError(domain: "E", code: 2) }
                let exts = CMFormatDescriptionGetExtensions(fd) as? [String: Any]
                let chars = try await vt.load(.mediaCharacteristics)
                guard ((exts?[kCMFormatDescriptionExtension_ContainsAlphaChannel as String] as? Bool) ?? false) || chars.contains(.containsAlphaChannel) else {
                    throw NSError(domain: "E", code: 3)
                }
                let r = try AVAssetReader(asset: asset)
                let o = AVAssetReaderTrackOutput(track: vt, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                r.add(o); r.startReading()
                guard let s = o.copyNextSampleBuffer(), let pb = s.imageBuffer else { throw NSError(domain: "E", code: 4) }
                CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(pb)
                let h = CVPixelBufferGetHeight(pb), w = CVPixelBufferGetWidth(pb)
                let aTop = Int(base[10 * stride + (w / 2) * 4 + 3])
                let aMid = Int(base[(h / 2) * stride + (w / 2) * 4 + 3])
                let aBot = Int(base[(h - 10) * stride + (w / 2) * 4 + 3])
                guard aTop <= 8, abs(aMid - 128) <= 12, aBot >= 245 else {
                    throw NSError(domain: "E", code: 5, userInfo: [NSLocalizedDescriptionKey: "alpha \\(aTop)/\\(aMid)/\\(aBot)"])
                }
                print("alpha=\\(aTop)/\\(aMid)/\\(aBot)")
            } else if mode == "subtitles" {
                let vt = tracks.filter { $0.mediaType == .video }, st = tracks.filter { $0.mediaType == .subtitle }
                guard vt.count == 1, st.count == 1 else { throw NSError(domain: "E", code: 10) }
                let group = try await asset.loadMediaSelectionGroup(for: .legible)
                guard let opt = group?.options.first, opt.isPlayable, opt.extendedLanguageTag == "pl" else {
                    throw NSError(domain: "E", code: 11)
                }
                let r = try AVAssetReader(asset: asset)
                let o = AVAssetReaderTrackOutput(track: st[0], outputSettings: nil)
                r.add(o); r.startReading()
                var texts: [String] = []
                while let s = o.copyNextSampleBuffer() {
                    guard let bb = CMSampleBufferGetDataBuffer(s) else { continue }
                    let len = CMBlockBufferGetDataLength(bb)
                    if len >= 2 {
                        var bytes = [UInt8](repeating: 0, count: len)
                        CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &bytes)
                        let n = (Int(bytes[0]) << 8) | Int(bytes[1])
                        if n > 0 && 2 + n <= len { texts.append(String(decoding: bytes[2..<(2 + n)], as: UTF8.self)) }
                    }
                }
                guard texts.count == 2, texts[0].contains("Zażółć"), texts[1].contains("ประเทศโปแลนด์") else {
                    throw NSError(domain: "E", code: 12, userInfo: [NSLocalizedDescriptionKey: "texts=\\(texts)"])
                }
                print("subtitles=\\(texts.count)")
            }
        } catch {
            FileHandle.standardError.write(Data("extra_inspect: \\(error)\\n".utf8)); exit(1)
        }
    }
}
""")
subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-target", f"{platform.machine()}-apple-macosx14.0",
                "-module-cache-path", root / "modules", extra_inspect_src, "-o", extra_inspect_bin], check=True)

alpha_html = root / "alpha.html"
alpha_html.write_text("""<!doctype html><meta charset="utf-8"><style>
html,body{margin:0;width:100%;height:100%;background:rgba(0,0,0,0);}
#mid{position:absolute;left:0;right:0;top:35%;height:30%;background:rgba(50,140,240,0.5);}
#bot{position:absolute;left:0;right:0;bottom:0;height:30%;background:#e8b34b;}
</style><body><div id="mid"></div><div id="bot"></div></body>""")
alpha_mov = root / "alpha.mov"
run([alpha_html, "--output", alpha_mov, "--width", "160", "--height", "120", "--fps", "25", "--frames", "4", "--codec", "hevc-alpha", "--transparent", "--video-only"])
subprocess.run([extra_inspect_bin, "alpha", alpha_mov], check=True)

nv12_mp4 = root / "nv12.mp4"
run([static, "--output", nv12_mp4, "--width", "104", "--height", "76", "--fps", "31", "--frames", "1", "--pixel-format", "nv12-vimage", "--video-only"])
subprocess.run([inspect, nv12_mp4, "104", "76", "31", "1", "-1", "-"], check=True)

sharp_mp4 = root / "sharp.mp4"
run([static, "--output", sharp_mp4, "--width", "104", "--height", "76", "--fps", "31", "--frames", "1", "--snapshot-quality", "sharp", "--video-only"])
subprocess.run([inspect, sharp_mp4, "104", "76", "31", "1", "-1", "-"], check=True)

srt = root / "pol_tha.srt"
srt.write_text("1\n00:00:00,000 --> 00:00:00,200\nZażółć gęślą jaźń — ą ć ę ł ń ó ś ź ż\n\n2\n00:00:00,240 --> 00:00:00,440\nประเทศโปแลนด์ — กำ ปิ๊ก แสงมณี\n", encoding="utf-8")
sub_mp4 = root / "subbed.mp4"
run([static, "--output", sub_mp4, "--width", "104", "--height", "76", "--fps", "25", "--frames", "15", "--subtitles", srt, "--subtitle-lang", "pol", "--video-only"])
subprocess.run([extra_inspect_bin, "subtitles", sub_mp4], check=True)

# Multi-chunk audio+video interleaving regression (>=60 frames @ 30fps with 2.0s WAV)
interleave_mp4 = root / "interleave60.mp4"
run([static, "--output", interleave_mp4, "--width", "320", "--height", "240", "--fps", "30", "--frames", "60", "--bitrate", "4000000", "--audio", wav])
subprocess.run([inspect, interleave_mp4, "320", "240", "30", "60", "-1", root / "interleave60.f32"], check=True)
report["v2_flags"] = ["hevc-alpha+transparent", "nv12-vimage", "snapshot-quality-sharp", "tx3g-pol-tha", "interleave-60f-av"]

subprocess.run([sys.executable, Path(__file__).with_name("quality-regressions.py"), worker, inspect, root, *quality_args], check=True)
report["quality_regressions"] = json.loads((root / "quality.json").read_text())
(root / "result.json").write_text(json.dumps(report, indent=2) + "\n")
print(f"PASS: {root / 'result.json'}")
