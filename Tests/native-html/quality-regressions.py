"""Called once by smoke.py under the lab slot. All inputs here are small synthetic fixtures."""
import argparse
import array
import hashlib
import json
import math
from pathlib import Path
import shutil
import struct
import subprocess
import time

ap = argparse.ArgumentParser()
for name in ("worker", "inspect", "root"):
    ap.add_argument(name, type=Path)
ap.add_argument("--review-fixtures", type=Path)
ap.add_argument("--gsap", type=Path)
ap.add_argument("--native-deadline", action="store_true")
a = ap.parse_args()
root = a.root
report = {"fixtures": {}, "timelines": {}, "layouts": {}}

def source(name, default):
    path = root / name
    if a.review_fixtures:
        shutil.copyfile(a.review_fixtures / name, path)
    else:
        path.write_bytes(default)
    report["fixtures"][name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return path

def render(page, name, count, *, wav=None, start="0", error=None):
    out = root / (name + ".mp4")
    cmd = [a.worker, page, "--output", out, "--width", "160", "--height", "96", "--fps", "25",
           "--frames", str(count), "--bitrate", "1800000"]
    cmd += ["--audio", wav, "--audio-start", start] if wav else ["--video-only"]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=50)
    if error:
        assert p.returncode != 0 and error in p.stderr and not out.exists(), (name, p.returncode, p.stderr)
    else:
        assert p.returncode == 0 and out.exists(), (name, p.returncode, p.stderr)
    assert not list(root.glob(".safarium-html-*"))
    return out

def inspect(movie, count, phase, rate=None, channels=None):
    raw = movie.with_suffix(".f32")
    cmd = [a.inspect, movie, "160", "96", "25", str(count), str(phase), raw if rate else "-"]
    if rate: cmd += [str(rate), str(channels)]
    return json.loads(subprocess.check_output(cmd)), raw

# Promise resolves after real time, not merely one microtask after seek.
dom = """<!doctype html><meta charset=utf-8><style>html,body{inset:0;margin:0;width:100%;height:100%;background:#222}#r{position:absolute;inset:0 0 0 50%}</style><body><div id=r></div><script>
const c=['#f00','#0f0','#00f'];function draw(t){const i=Math.round(t*25)%3;document.body.style.background=c[i];r.style.background=c[(i+1)%3];}
const asyncDraw=t=>new Promise(resolve=>window.__sfClock.realSetTimeout(()=>{draw(t);resolve()},350));
"""
for name, hook in [("direct", "window.__seek=asyncDraw"), ("registered", "window.__timelines={main:{seek:asyncDraw}}")]:
    page = source(name + ".html", (dom + hook + "</script>").encode())
    report["timelines"][name], _ = inspect(render(page, name, 3), 3, 0)
reference = report["timelines"]["direct"]["bgra_sha256"]
assert report["timelines"]["registered"]["bgra_sha256"] == reference

ordered = root / "order.html"
ordered.write_text(dom + """
let phase;const expect=p=>{if(phase!==p)throw Error('wrong hook order: '+phase+' vs '+p)};
window.__seek=t=>{phase='direct';requestAnimationFrame(()=>expect('done'))};
window.__hf={seek(){expect('direct');phase='hf'}};
window.__timelines={
 chain:{pause(){expect('hf');phase='paused';return this},seek(t,s){expect('paused');if(s!==false)throw Error('seek flags');phase='chain';return this},then(){throw Error('awaited playback')}},
 drawing:{pause(){expect('chain');return new Promise(r=>__sfClock.realSetTimeout(()=>{phase='ready';r()},5))},
          async time(t,s){expect('ready');if(s!==false)throw Error('time flags');await asyncDraw(t);phase='drawn'}},
 last:{seek(){expect('drawn');phase='done'}}
};</script>""")
report["timelines"]["ordered_time_and_self_chain"], _ = inspect(render(ordered, "ordered", 3), 3, 0)
assert report["timelines"]["ordered_time_and_self_chain"]["bgra_sha256"] == reference
if a.gsap:
    shutil.copyfile(a.gsap, root / "gsap.min.js")
    page = root / "real-gsap.html"
    page.write_text(dom + """</script><script src="gsap.min.js"></script><script>
    const obj={v:0},tl=gsap.timeline({paused:true});draw(0);
    tl.to(obj,{v:25,duration:1,ease:'none',onUpdate(){draw(obj.v/25)}});
    if(tl.seek(0)!==tl || typeof tl.then!=='function') throw Error('expected a thenable GSAP chain');
    window.__timelines={main:tl};</script>""")
    report["timelines"]["real_gsap"], _ = inspect(render(page, "real-gsap", 3), 3, 0)
    assert report["timelines"]["real_gsap"]["bgra_sha256"] == reference
reject = root / "registered-rejection.html"
reject.write_text(dom + """window.__timelines={main:{seek(t){
    if(t===0){draw(t);return} return new Promise((r,j)=>__sfClock.realSetTimeout(()=>j(Error('registered draw rejected')),15))
}}};</script>""")
render(reject, "registered-rejection", 3, error="registered draw rejected")
report["timelines"]["async_rejection"] = "nonzero; no output"
def chunk(kind, data):
    return kind + struct.pack("<I", len(data)) + data + bytes(len(data) % 2)

def make_wav(ch, rate, bits, pcm, mask=None, odd_junk=False):
    stride = ch * (bits // 8)
    fmt = struct.pack("<HHIIHH", 1 if mask is None else 0xfffe, ch, rate, rate * stride, stride, bits)
    if mask is not None:
        fmt += struct.pack("<HHI", 22, bits, mask) + bytes.fromhex("0100000000001000800000aa00389b71")
    body = b"WAVE" + (chunk(b"JUNK", b"odd") if odd_junk else b"") + chunk(b"fmt ", fmt) + chunk(b"data", pcm)
    return b"RIFF" + struct.pack("<I", len(body)) + body

static = root / "quality-static.html"
static.write_text("<!doctype html><meta charset=utf-8><style>html{background:#f00}</style>")
rate = 44100
channels = [[round(12500*math.sin(2*math.pi*(hz*t/rate + k*(t/rate)**2)) +
                   3800*math.sin(2*math.pi*(hf*t/rate + v*(t/rate)**2))) for t in range(rate)]
            for hz, k, hf, v in [(314, 799, 1481, 691), (719, 1301, 3053, 431)]]
pcm = array.array("h", (v for frame in zip(*channels) for v in frame)).tobytes()
front = source("stereo-3.wav", make_wav(2, rate, 16, pcm, 3))
back = source("stereo-48.wav", make_wav(2, rate, 16, pcm, 48))
legacy = root / "stereo-legacy.wav"
# Derive the unlabelled control from the exact sample words of the review fixture.
front_bytes = front.read_bytes()
offset = front_bytes.index(b"data") + 8
legacy.write_bytes(make_wav(2, rate, 16, front_bytes[offset:offset+rate*4]))
outputs = []
for wav in (front, legacy):
    movie = render(static, wav.stem, 11, wav=wav, start="0.2")
    row, raw = inspect(movie, 11, -1, rate, 2)
    outputs.append(raw.read_bytes()); row["pcm_sha256"] = hashlib.sha256(outputs[-1]).hexdigest()
    report["layouts"][wav.name] = row
assert outputs[0] == outputs[1]
if a.review_fixtures:
    assert outputs[0] == (a.review_fixtures / "stereo-3.f32").read_bytes()
    report["layouts"]["review_front_stereo_pcm_exact"] = True

# Same explicit front-center/24-bit shape as EP30; no episode media is rendered.
mono_pcm = b"".join((v << 8).to_bytes(3, "little", signed=True) for v in channels[0][:4800])
outputs = []
for name, mask in [("mono-center", 4), ("mono-legacy", None)]:
    wav = root / (name + ".wav"); wav.write_bytes(make_wav(1, 48000, 24, mono_pcm, mask, odd_junk=True))
    row, raw = inspect(render(static, name, 2, wav=wav), 2, -1, 48000, 1)
    outputs.append(raw.read_bytes()); row["pcm_sha256"] = hashlib.sha256(outputs[-1]).hexdigest()
    report["layouts"][wav.name] = row
assert outputs[0] == outputs[1]

broken_page = root / "must-not-open.html"
broken_page.write_text("<!doctype html><script>throw Error('picture started before audio preflight')</script>")
for wav, mask in [(back, 48), (root / "stereo-unspecified.wav", 0), (root / "mono-left.wav", 1)]:
    if wav != back:
        wav.write_bytes(make_wav(1, 48000, 24, mono_pcm, mask) if mask else make_wav(2, rate, 16, pcm, mask))
    render(broken_page, wav.stem, 1, wav=wav, error=f"unsupported WAV speaker mask 0x{mask:08x}")
    report["layouts"][wav.name] = "rejected at WAV preflight; no output"
if a.native_deadline:
    page = root / "registered-deadline.html"
    # An unreachable pending Promise can be rejected earlier by WebKit's GC.
    # Keep the continuation reachable across the actual native 30 s deadline.
    page.write_text(dom + """window.__timelines={main:{seek(){
      return window.pendingDraw = new Promise(resolve=>__sfClock.realSetTimeout(resolve,90000))
    }}};</script>""")
    t0 = time.monotonic()
    render(page, "registered-deadline", 1, error="timeout: evaluate")
    report["timelines"]["native_timeout_seconds"] = round(time.monotonic() - t0, 2)
(root / "quality.json").write_text(json.dumps(report, indent=2) + "\n")
