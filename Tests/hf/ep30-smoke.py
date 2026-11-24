#!/usr/bin/env python3
"""Use real HF + the selected Safarium shim on EP30, 24–26 s (native range or local composition)."""
import argparse
import fcntl
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess as sp
import sys
import tempfile
import time

import numpy as np

ROOT = Path(__file__).resolve().parents[2]


def pcm(path, excerpt=False):
    data = sp.check_output(["ffmpeg", "-nostdin", "-v", "error", *(["-ss", "24"] if excerpt else []),
                            "-i", str(path), "-map", "0:a:0", "-t", "2", "-ac", "1", "-ar", "16000",
                            "-f", "f32le", "-"])
    return np.frombuffer(data, dtype="<f4").astype(np.float64)


def audio_alignment(video, voice):
    a, b = pcm(video), pcm(voice, True)
    n = min(len(a),len(b))
    if n < 31_500:
        return {"matched": False, "samples": n}
    # Exclude container-edge padding; compare normalized waveforms ± one frame.
    limit = 16000 // 30
    src = b[limit:n-limit]
    src = src - src.mean()
    waves = np.lib.stride_tricks.sliding_window_view(a[:n], len(src))
    dots = np.einsum("ij,j->i", waves, src, optimize=False)
    sums = np.concatenate(([0],np.cumsum(a[:n])))
    squares = np.concatenate(([0],np.cumsum(a[:n]**2)))
    length = len(src)
    energy = squares[length:]-squares[:-length] - (sums[length:]-sums[:-length])**2/length
    corr = dots / np.maximum(np.sqrt(np.maximum(energy,0)*np.dot(src,src)),1e-12)
    j = int(np.argmax(corr))
    return {"matched": bool(corr[j]>=.98), "samples":n, "zero_lag_correlation":round(float(corr[limit]),6),
            "best_correlation":round(float(corr[j]),6), "lag_ms":round((j-limit)*1000/16000,3)}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    for name in ("episode","shim","scratch","lock","reference"):
        ap.add_argument("--"+name, type=Path, required=True)
    ap.add_argument("--observer", type=Path, help="compiled observe-desktop.swift")
    ap.add_argument("--local-excerpt", action="store_true", help="ordinary HF whole-composition render of a rebased scratch scene")
    ap.add_argument("--chroma", choices=["420","444"], default="420", help="444 also requests HF's PNG capture mode")
    args = ap.parse_args()
    work = Path(tempfile.mkdtemp(prefix="hf-ep30-",dir=args.scratch.resolve()))
    print("evidence:",work,flush=True)
    scene = work/"scene"
    scene.mkdir()
    for f in ("index.html","kit.js","kit.css","gsap.min.js","hyperframes.json","assets/voice.wav"):
        dest = scene/f
        dest.parent.mkdir(exist_ok=True)
        shutil.copyfile(args.episode/f,dest)
    shutil.copytree(args.episode/"fonts",scene/"fonts",ignore=shutil.ignore_patterns(".*"))
    original = (scene/"index.html").read_bytes()
    if args.local_excerpt:
        html = original.decode("utf-8")
        duration = 'data-duration="664.02"'
        voice = '<audio id="voice"'
        timeline = 'window.__timelines["main"] = tl;'
        if html.count(duration)!=2 or html.count(voice)!=1 or html.count(timeline)!=1:
            raise ValueError("different EP30 authoring structure; cannot rebase this composition")
        html = html.replace(duration, 'data-duration="2"').replace(voice, voice+' data-media-start="24"')
        html = html.replace(timeline, '''tl.time(24, false).pause();
  const excerpt = gsap.timeline({paused:true});
  excerpt.fromTo(tl, {time:24}, {time:26, duration:2, ease:"none", immediateRender:true}, 0);
  window.__timelines["main"] = excerpt;''')
        (scene/"index.html").write_text(html)
    movie = work/"ep30-hf-webkit.mp4"
    cmd = [str(ROOT/"bin/safarium-hf"), "render", str(scene), *([] if args.local_excerpt else ["--start","24","--end","26"]), "--fps","30",
           "--quality","looks","--chroma-subsampling",args.chroma,"-w","1","--frames-cache-dir=off","--no-wait","-o",str(movie)]
    if args.observer:
        cmd = [str(args.observer.resolve()), str(work/"desktop.json"), *cmd]
    env = {**os.environ,"SAFARIUM_CDP":str(args.shim.resolve()),"SAFARIUM_HF_VERSION":"0.9.72",
           "DO_NOT_TRACK":"1","HYPERFRAMES_RENDER_LOCK_DIR":str(work/"locks")}
    with args.lock.open("a+") as lock, (work/"render.log").open("wb") as log:
        fcntl.flock(lock,fcntl.LOCK_EX)
        t = time.monotonic()
        child = sp.Popen(cmd,cwd=scene,env=env,stdout=log,stderr=log,start_new_session=True)
        try:
            rc = child.wait(timeout=150)
        except sp.TimeoutExpired:
            os.killpg(child.pid,signal.SIGTERM)
            try:
                child.wait(timeout=6)
            except sp.TimeoutExpired:
                os.killpg(child.pid,signal.SIGKILL)
                child.wait()
            rc = 124
        wall = time.monotonic()-t
    report = {"hf":"0.9.72","range_s":[24,26],"mode":"local-excerpt" if args.local_excerpt else "HF-distributed-range",
              "rc":rc,"chroma":args.chroma,"elapsed_s":round(wall,3),"original_html_sha256":hashlib.sha256(original).hexdigest(),
              "rendered_html_sha256":hashlib.sha256((scene/"index.html").read_bytes()).hexdigest(),
              "media":str(movie),"render_ok":False,"native_picture_parity":False}
    if (work/"desktop.json").exists():
        report["desktop"] = json.loads((work/"desktop.json").read_text())
    actual_rc = report.get("desktop",{}).get("test_exit",rc)
    if actual_rc != 0:
        lines = (work/"render.log").read_text(errors="replace").splitlines()
        report["diagnostic"] = next((l.strip() for l in lines if l.strip().startswith("[Parallel] Capture failed:")),
                                    next((l.strip() for l in reversed(lines) if "failed" in l.lower()), "see render.log"))
    if actual_rc == 0 and movie.is_file():
        streams = json.loads(sp.check_output(["ffprobe","-v","error","-show_entries",
                             "stream=codec_name,codec_type,pix_fmt,width,height,time_base,avg_frame_rate,duration,color_range,color_space,color_transfer,color_primaries",
                             "-of","json",str(movie)]))["streams"]
        report["streams"] = streams
        v = next(s for s in streams if s["codec_type"]=="video")
        audio = next((s for s in streams if s["codec_type"]=="audio"),{})
        frames = json.loads(sp.check_output(["ffprobe","-v","error","-select_streams","v:0","-show_entries",
                             "frame=best_effort_timestamp","-of","json",str(movie)]))["frames"]
        pts = [Fraction(v["time_base"])*int(f["best_effort_timestamp"]) for f in frames]
        report["exact_pts"] = pts==[Fraction(i,30) for i in range(60)]
        md5 = sp.check_output(["ffmpeg","-v","error","-i",str(movie),"-map","0:v:0","-vf","scale=108:192",
                               "-fps_mode","passthrough","-f","framemd5","-"],text=True)
        report["distinct_frames"] = len({x.rsplit(",",1)[-1].strip() for x in md5.splitlines() if x and x[0]!="#"})
        report["audio"] = audio_alignment(movie,scene/"assets/voice.wav") if audio else {"matched":False}
        report["render_ok"] = bool(report["exact_pts"] and report["distinct_frames"]==60 and v["width"]==1080
            and v["height"]==1920 and v["codec_name"]=="h264" and audio.get("codec_name")=="aac"
            and abs(float(audio["duration"])-2)<=1/30 and report["audio"]["matched"])
        ref_tags = json.loads(sp.check_output(["ffprobe","-v","error","-select_streams","v:0","-show_entries",
                            "stream=color_range,color_space,color_transfer,color_primaries","-of","json",str(args.reference)]))["streams"][0]
        tags = {"color_range":"tv","color_space":"bt709","color_transfer":"bt709","color_primaries":"bt709"}
        report["matched_color_tags"] = all(v.get(k)==ref_tags.get(k)==val for k,val in tags.items())
        qfile = work/"quality.json"
        sp.run([sys.executable,str(ROOT/"bench/quality.py"),"--ref",str(args.reference),"--test",str(movie),
                "--out",str(qfile),"--delta-e","--assume-matrix","bt709"],check=True)
        q = json.loads(qfile.read_text())
        report["quality"] = {"ssim_mean":q["ssim"]["mean"],"ssim_min":q["ssim"]["min"],
                             "psnr_mean":q["psnr"].get("mean"),"psnr_min":q["psnr"].get("min"),
                             "delta_e_p95":q["delta_e"]["p95"],"all_frames":q["ssim"]["n"]==q["delta_e"]["n"]==60}
        report["native_picture_parity"] = bool(report["matched_color_tags"] and report["quality"]["all_frames"] and q["ssim"]["min"]>=.97
                and q["psnr"].get("min",float("inf"))>=30 and q["delta_e"]["p95"]<=2)
    (work/"summary.json").write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps(report,indent=2),flush=True)
    return 0 if rc == 0 and report["render_ok"] and report["native_picture_parity"] else 1


if __name__=="__main__":
    raise SystemExit(main())
