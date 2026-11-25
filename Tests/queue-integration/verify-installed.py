"""Real two-client acceptance: unchanged EP30 inputs → queued native MP4s → exact readback."""
import argparse
import ctypes as C
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess as sp
import tempfile
import time

ROOT=Path(__file__).resolve().parents[2]
LOAD=lambda p:json.loads(p.read_text())
PROC=C.CDLL("/usr/lib/libproc.dylib")
PROC.proc_listpids.argtypes=[C.c_uint32,C.c_uint32,C.c_void_p,C.c_int]
PROC.proc_pidpath.argtypes=[C.c_int,C.c_void_p,C.c_uint32]


def workers(rootpid,unexpected):
    pending=[rootpid];seen=set();found=[]
    while pending:
        pid=pending.pop()
        if pid in seen:continue
        seen.add(pid)
        name=C.create_string_buffer(4096)
        if PROC.proc_pidpath(pid,name,len(name))>0:
            path=name.value.lower();leaf=path.rsplit(b"/",1)[-1]
            if leaf==b"safarium-html":found.append(pid)
            if (leaf in (b"ffmpeg",b"ffprobe",b"ffplay",b"avconv",b"avprobe",b"safari",b"chromium",b"chrome",b"headless_shell")
                    or any(s in path for s in (b"/google chrome",b"/chromium.app/",b"/safari.app/",b"/safari technology preview.app/"))):
                unexpected.add(leaf.decode(errors="replace"))
        buf=(C.c_int*256)()
        count=PROC.proc_listpids(6,pid,C.byref(buf),C.sizeof(buf))  # PROC_PPID_ONLY
        pending.extend(x for x in buf[:max(0,count)//C.sizeof(C.c_int)] if x>0)
    return sorted(found)


def sha(p):
    h=hashlib.sha256()
    with p.open("rb") as f:
        for b in iter(lambda:f.read(1024**2),b""):h.update(b)
    return h.hexdigest()


def foreground():
    r=sp.run(["/usr/bin/lsappinfo","front"],capture_output=True,text=True,timeout=4)
    value=r.stdout.strip()
    return value if r.returncode==0 and re.fullmatch(r"ASN:(?:0x[\da-fA-F]+-)?0x[\da-fA-F]+:",value) else None


def main(a):
    w=Path(tempfile.mkdtemp(prefix="installed-two-clients-",dir=a.scratch))
    print("evidence:",w,flush=True)
    old=ROOT/"bench/experiments/safari-only-audit/native/from-html"
    manifest=LOAD(old/"source-manifest.json")["files"];ref=LOAD(old/"summary.json")
    for m in manifest:
        dest=w/"stage"/m["relative"];dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(m["original"],dest)
        assert sha(dest)==m["original_sha256"]
    source=w/"stage/index.html";wav=w/"stage/assets/voice.wav"
    goldA=Path(a.reference or ref["final_mp4"])
    if a.reference:
        assert goldA.is_file() and sha(goldA)==ref["final_mp4_sha256"]
    if a.silent_reference:
        goldB=Path(a.silent_reference)
    else:
        live=LOAD(ROOT/"bench/experiments/ram-code-art/live/summary.json")
        goldB=Path(live["scratch_path"])/"runs/1-serial/B/ep30-B.mp4"
    evidence=LOAD(ROOT/"bench/experiments/ram-code-art/live/verification.json")["per_job"]
    prior=next(j for j in evidence if j["job"]=="B" and j["pair"]==1 and j["policy"]=="serial")
    assert prior["pass"] and a.queue.is_file()
    if a.silent_reference:
        assert goldB.is_file() and sha(goldB)==prior["mp4_sha256"]
    if goldA.is_file() and goldB.is_file():
        assert sha(goldA)==ref["final_mp4_sha256"]
        assert sha(goldB)==prior["mp4_sha256"]
        reference_mode="mp4_file"
        archA=archB=None
    else:
        archA_path=ROOT/"bench/experiments/render-standard/acceptance/ep30-a-with-audio.json"
        archB_path=ROOT/"bench/experiments/render-standard/acceptance/ep30-b-video.json"
        archA=LOAD(archA_path)["reference"]
        archB=LOAD(archB_path)["reference"]
        reference_mode="archived_verify_digest"
    for n in "AB":(w/n).mkdir()
    out={k:w/k/(k+" output.mp4") for k in "AB"}
    common=[str(a.queue),"html",str(source),"--width","1080","--height","1920","--fps","30","--frames","60","--bitrate","20000000"]
    cmd={"A":[*common,"--start","24","--output",str(out["A"]),"--audio",str(wav),"--audio-start","24"],
         "B":[*common,"--start","26","--output",str(out["B"]),"--video-only"]}
    logs=[];jobs={};samples=[];waiting=None;unexpected=set();last_status=0;front_before=foreground();t0=time.monotonic()
    def launch(k):
        f=(w/k/"render.log").open("xb");logs.append(f)
        jobs[k]=sp.Popen(cmd[k],cwd=w/k,stdout=f,stderr=sp.STDOUT)
    try:
        launch("A")
        while True:
            ra=workers(jobs["A"].pid,unexpected) if jobs["A"].poll() is None else []
            if ra and "B" not in jobs:launch("B")
            rb=workers(jobs["B"].pid,unexpected) if "B" in jobs and jobs["B"].poll() is None else []
            samples.append({"t":round(time.monotonic()-t0,5),"A":ra,"B":rb,"B_submitted":"B" in jobs})
            if ra and not rb and "B" in jobs and waiting is None and time.monotonic()-last_status>.12:
                last_status=time.monotonic()
                status=json.loads(sp.check_output([str(a.queue),"status"],timeout=7))
                if status["active"] is not None and status["waiting"]:waiting=status
            if "B" not in jobs and jobs["A"].poll() is not None:
                raise RuntimeError("A ended before a native worker was observed; see A/render.log")
            if "B" in jobs and all(p.poll() is not None for p in jobs.values()):break
            if time.monotonic()-t0>150:raise RuntimeError("timeout waiting for this test's two jobs")
            time.sleep(.035)
    finally:
        for p in jobs.values():
            if p.poll() is None:p.terminate()
        for p in jobs.values():
            try:p.wait(timeout=8)
            except sp.TimeoutExpired:pass
        for f in logs:f.close()
        (w/"worker-samples.json").write_text(json.dumps(samples,separators=(",",":"))+"\n")
    exits={k:p.returncode for k,p in jobs.items()};assert exits=={"A":0,"B":0},exits
    assert not unexpected,unexpected
    assert all(not(s["A"] and s["B"]) for s in samples),"simultaneous native workers"
    assert any(s["A"] and s["B_submitted"] and not s["B"] for s in samples)
    firstB=min(s["t"] for s in samples if s["B"]);lastA=max(s["t"] for s in samples if s["A"])
    assert firstB>lastA and waiting
    def run_verify(key,*paths,expect=0):
        r=sp.run([str(a.queue),"verify",*[str(p) for p in paths]],capture_output=True,timeout=95,check=False)
        (w/(key+"-quality.json")).write_bytes(r.stdout);(w/(key+"-quality.log")).write_bytes(r.stderr)
        assert r.returncode==expect,(key,r.returncode,r.stderr[-350:])
        return r,json.loads(r.stdout)

    checks={}
    if reference_mode=="mp4_file":
        for key,p,q,expect in [("A",goldA,out["A"],0),("B",goldB,out["B"],0),("different",goldA,out["B"],2)]:
            r,data=run_verify(key,p,q,expect=expect)
            assert data["exactMatch"]==(expect==0)
            checks[key]={"exit":r.returncode,"exact":data["exactMatch"],"sections":data["differingSections"],
                         "frames":data["candidate"]["video"]["frames"],"sample_count":(data["candidate"].get("audio") or {}).get("presentedSamples",0)}
    else:
        for key,arch in [("A",archA),("B",archB)]:
            r,data=run_verify(key,out[key],expect=0)
            cand=data["reference"];exact=(cand==arch)
            assert exact,f"archived {key} digest mismatch: cand={cand} arch={arch}"
            checks[key]={"exit":r.returncode,"exact":exact,"sections":[],
                         "frames":cand["video"]["frames"],"sample_count":(cand.get("audio") or {}).get("presentedSamples",0)}
        r,data=run_verify("different",out["A"],out["B"],expect=2)
        assert data["exactMatch"] is False
        checks["different"]={"exit":r.returncode,"exact":data["exactMatch"],"sections":data["differingSections"],
                             "frames":data["candidate"]["video"]["frames"],"sample_count":(data["candidate"].get("audio") or {}).get("presentedSamples",0)}
    assert checks["A"]["frames"]==checks["B"]["frames"]==60 and checks["A"]["sample_count"]==96000 and checks["B"]["sample_count"]==0
    assert set(checks["different"]["sections"])=={"video","audio"}
    # Exercise the revised async virtual clock in separate, freshly started WebKit sessions.
    # Compare media, not whole MP4 bytes which may include a creation timestamp.
    runs=[]
    for i in range(3):
        p=w/f"replay-{i}.mp4"
        render=[str(a.queue),"html",str(source),"--width","1080","--height","1920","--fps","30","--frames","3",
                "--bitrate","20000000","--start","24","--video-only","--output",str(p)]
        sp.run(render,cwd=w,check=True,capture_output=True,timeout=50)
        body=json.loads(sp.check_output([str(a.queue),"verify",str(p)],cwd=w,timeout=40))["reference"]
        assert body["video"]["frames"]==3 and body["video"]["firstPTS"]=="0/1" and body["video"]["lastPTS"]=="1/15"
        runs.append(body)
    assert runs.count(runs[0])==3,"clock replay changed decoded pixels, track properties or timing"
    front_after=foreground()
    assert all(sha(Path(m["original"]))==m["original_sha256"] for m in manifest)
    report={"status":"PASS","scope":"two independently started foreground AI-equivalent CLI clients from different cwd; no AI provider calls",
        "queue":str(a.queue),"queue_real":str(a.queue.resolve()),"same_source_files":len(manifest),"exit":exits,
        "native_worker_samples":len(samples),"max_distinct_native_workers":max(len(set(s["A"]+s["B"])) for s in samples),
        "second_submitted_while_first_active":True,"observed_queue":waiting,"last_A_sample_s":lastA,"first_B_sample_s":firstB,
        "frontmost_same_before_after":(front_before==front_after) if front_before and front_after else None,
        "original_inputs_unchanged_after":len(manifest),"reference_mode":reference_mode,"reference_file_sha256":{"A":ref["final_mp4_sha256"],"B":prior["mp4_sha256"]},
        "three_fresh_clock_replays":{"equal":True,"frames_per_replay":3,"activeNV12SHA256":runs[0]["video"]["activeNV12SHA256"],
            "ptsAndDurationsSHA256":runs[0]["video"]["ptsAndDurationsSHA256"]},
        "forbidden_executables_in_sampled_descendants":sorted(unexpected),
        "sampling_limitation":"PPID tree observations are sampled; launchd's independent XPC services are not covered here. Queue acceptance also checks exact critical-section events separately.",
        "quality":checks,"artifacts":{k:{"file":str(p),"bytes":p.stat().st_size,"sha256":sha(p)} for k,p in out.items()}}
    (w/"summary.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n")
    print(json.dumps(report,ensure_ascii=False,indent=2))


if __name__=="__main__":
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--queue",type=Path,default=Path.home()/".local/bin/safarium-render")
    ap.add_argument("--scratch",type=Path,required=True)
    ap.add_argument("--reference");ap.add_argument("--silent-reference")
    main(ap.parse_args())
