#!/usr/bin/env python3
"""Build Safarium and check its local render contract with already-installed dependencies."""
import argparse
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import signal
import subprocess as sp
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch", type=Path, required=True)
    parser.add_argument("--puppeteer-root", type=Path, required=True, help="directory containing node_modules/puppeteer-core")
    parser.add_argument("--gsap", type=Path, required=True, help="local gsap.min.js")
    parser.add_argument("--voice", type=Path, help="real local PCM WAV for the optional large-file oracle")
    args = parser.parse_args()
    gsap = args.gsap.resolve(strict=True)
    pptr = args.puppeteer_root.resolve(strict=True)
    if not (pptr/"node_modules"/"puppeteer-core"/"package.json").is_file():
        parser.error("puppeteer-core is not installed at the specified root")
    work = Path(tempfile.mkdtemp(prefix="verified-stack-", dir=args.scratch.resolve()))
    build = work/"swiftpm"
    env = {**os.environ, "PPTR_DIR":str(pptr), "SCRATCH_DIR":str(work),
           "SAFARIUM_SCRATCH":str(work), "SAFARIUM_PROBE_SCRATCH":str(work/"probes"),
           "SAFARIUM_CDP_LOG":str(work/"unsupported.log"),
           "DO_NOT_TRACK":"1","npm_config_offline":"true", "PYTHONDONTWRITEBYTECODE":"1"}
    # The optional long-running head-to-head and expensive probes have their own opt-in.
    env.pop("SAFARIUM_PROBES", None)
    env.pop("SAFARIUM_PERF", None)
    env.pop("SAFARIUM_CDP_TRACE", None)
    env.pop("SAFARIUM_WAV_FIXTURE", None)
    if args.voice:
        env["SAFARIUM_WAV_FIXTURE"] = str(args.voice.resolve(strict=True))
    package = json.loads((pptr/"node_modules/puppeteer-core/package.json").read_text())
    summary = {"project":"Safarium","scratch":str(work),"puppeteer_core":package["version"],
               "checks":{},"all_required_passed":False}
    print("evidence:",work,flush=True)

    def step(name, cmd, *, timeout=120):
        logfile = work/(name+".log")
        t = time.monotonic()
        with logfile.open("wb") as output:
            proc = sp.Popen(list(map(str,cmd)), cwd=ROOT, env=env, stdout=output, stderr=output, start_new_session=True)
            try:
                rc = proc.wait(timeout=timeout)
            except sp.TimeoutExpired:
                os.killpg(proc.pid,signal.SIGTERM)
                try:
                    proc.wait(timeout=5)
                except sp.TimeoutExpired:
                    os.killpg(proc.pid,signal.SIGKILL)
                    proc.wait()
                rc = 124
        text = logfile.read_text(errors="replace")
        record = {"rc":rc,"wall_s":round(time.monotonic()-t,2),"log":logfile.name}
        loc = re.search(r"^evidence: (.+)$", text, re.M)
        if loc:
            record["artifacts"] = loc.group(1).strip()
        summary["checks"][name] = record
        (work/"summary.json").write_text(json.dumps(summary,indent=2)+"\n")
        print(name,rc,record["wall_s"],flush=True)
        if rc:
            raise RuntimeError(f"{name} failed; see {logfile}\n{text[-1400:]}")
        return text

    step("swift-release", ["swift","build","--scratch-path",build,"-c","release","-j","3"], timeout=210)
    bindir = Path(sp.check_output(["swift","build","--scratch-path",str(build),"-c","release","--show-bin-path"],
                                  cwd=ROOT,text=True).strip())
    shim = bindir/"safarium-cdp"
    env["SAFARIUM_CDP"] = str(shim)
    summary["shim"] = str(shim)
    summary["shim_sha256"] = hashlib.sha256(shim.read_bytes()).hexdigest()
    swift = step("swift-test", ["swift","test","--scratch-path",build,"-j","3"],timeout=260)
    bundles = re.findall(r"Test Suite 'All tests' passed[^\n]*\n\s*Executed (\d+) tests?, with "
                         r"(?:(\d+) tests? skipped and )?(\d+) failures?",swift)
    if not bundles:
        raise RuntimeError("Cannot read XCTest bundle totals")
    total = sum(int(n) for n,_,_ in bundles)
    skipped = sum(int(s or 0) for _,s,_ in bundles)
    failures = sum(int(f) for _,_,f in bundles)
    summary["swift_totals"] = {"tests":total,"passed":total-skipped-failures,"skipped":skipped,"failures":failures}
    summary["swift_optional_skipped"] = re.findall(r"Test Case '([^']+)' skipped", swift)
    unexpected = [s for s in summary["swift_optional_skipped"] if "SafariumProbeTests" not in s and "PerfTests" not in s]
    if unexpected:
        raise RuntimeError(f"Unexpected skipped Swift tests: {unexpected}")
    js = sorted(f for f in (ROOT/"Tests/cdp").glob("*.test.mjs") if not f.name.startswith("."))
    node = step("cdp", ["node","--test","--test-reporter=tap","--test-concurrency=1",*js], timeout=150)
    summary["node_totals"] = {key:int(m.group(1)) for key in ("tests","pass","fail","skipped")
                             if (m:=re.search(r"(?m)^[ℹ# ]+"+key+r"\s+(\d+)",node))}
    n = summary["node_totals"]
    if n.get("tests",0) < 23 or n.get("pass") != n.get("tests") or n.get("skipped") != 0:
        raise RuntimeError(f"CDP tests incomplete: {n}")
    wav = step("wav-duration",["node","--test","--test-reporter=tap","Tests/hf/wav-metadata.test.mjs"],timeout=85)
    oracle = "EP30 duration matches ffprobe"
    required_wav = {"Strong ETag and PCM layout","Bad ranges and ignored ranges","Malformed and reselected sources",
                    "Validator transitions on same-size replacements","Unversioned HF static asset uses one representation",
                    "Cookie, Referer and foreign redirect isolation"}
    cases = [(m.group(1), m.group(2) is not None) for m in re.finditer(r"(?m)^ok \d+ - (.*?)(?:\s+(# SKIP.*))?$",wav)]
    summary["wav_cases"] = [{"name":name,"skipped":skipped} for name,skipped in cases]
    if (not any(name==oracle and skipped == (not bool(args.voice)) for name,skipped in cases)
            or not required_wav.issubset({name for name,skipped in cases if not skipped})
            or any(skipped and name!=oracle for name,skipped in cases)):
        raise RuntimeError(f"WAV validation cases incomplete: {cases}")
    scopes = step("asset-scopes",["node","Tests/cdp/fetch-scopes.mjs"],timeout=100)
    capabilities = json.JSONDecoder().raw_decode(scopes[scopes.index('{\n  "counts"'):])[0]
    summary["scope_counts"] = capabilities["counts"]
    shapes = {"file-project":["script","image","fetch"], "loopback-same":["fetch"],
              "loopback-cross":["classic-script","display-image","cors-image-allow","cors-image-deny","fetch-allow","fetch-deny"]}
    expected = {(s,name,phase) for s,names in shapes.items() for name in names for phase in ("origin","synthetic")}
    expected.update({("loopback-same","response-stage","synthetic"),("offline-https-invalid",None,"synthetic")})
    allowed_exclusions = {("file-project",name,phase) for name in ("image","fetch") for phase in ("origin","synthetic")}
    observations = capabilities["rows"]
    by_key = {(r["scope"],r.get("name"),r["phase"]):r for r in observations}
    summary["scope_exclusions"] = [{"scope":r["scope"],"case":r.get("name"),"phase":r["phase"],"reason":r["reason"]}
                                   for r in observations if r["verdict"]=="unsupported"]
    unresolved = [k for k in expected if (k not in by_key or
                  not (by_key[k]["verdict"]=="verified" or (k in allowed_exclusions and
                       by_key[k]["verdict"]=="unsupported" and by_key[k].get("reason"))))]
    if unresolved or len(by_key) != len(observations):
        raise RuntimeError(f"Mandatory scope cases missing, duplicated or unverified: {unresolved}")
    ocr = work/"vision-ocr"
    step("ocr-build",["swiftc","-O","bench/ocr/main.swift","-o",ocr])
    env["SAFARIUM_OCR"] = str(ocr)
    step("thai-pixels",["node","Tests/cdp/fetch-thai-ocr.mjs"])
    for version in ("0.9.65","0.9.72"):
        options = ["--shim",shim,"--scratch",work,"--hf-version",version]
        step("hf-cdn-"+version,[sys.executable,"Tests/hf/check-bundled.py",*options],timeout=85)
        step("hf-media-"+version,[sys.executable,"Tests/hf/fetch-smoke.py",*options,"--gsap",gsap],timeout=150)
    media_run = Path(summary["checks"]["hf-media-0.9.72"]["artifacts"])
    source, finished = media_run/"transport.mp4", work/"finished-with-tone.mp4"
    step("finish-mp4",[ROOT/"bin/safarium-soundtrack",source,media_run/"scene/assets/tone.wav",finished])
    def packets(path):
        info = json.loads(sp.check_output(["ffprobe","-v","error","-select_streams","v:0","-show_packets",
                          "-show_data_hash","sha256","-show_entries","stream=time_base:packet=pts,duration,data_hash",
                          "-of","json",str(path)]))
        unit = Fraction(info["streams"][0]["time_base"])
        return [(unit*int(p["pts"]),unit*int(p["duration"]),p["data_hash"]) for p in info["packets"]]
    original = packets(source)
    media = runpy.run_path(str(ROOT/"Tests/hf/fetch-smoke.py"))["verify"](finished)
    summary["finishing"] = {"packet_count":len(original),"packet_and_timing_identity":original==packets(finished),
                            "decoded_frames_and_audio_pass":media["pass"]}
    if len(original) != 30 or not summary["finishing"]["packet_and_timing_identity"] or not media["pass"]:
        raise RuntimeError("Soundtrack output did not preserve the video and expected audio")
    summary["all_required_passed"] = True
    (work/"summary.json").write_text(json.dumps(summary,indent=2)+"\n")
    print(json.dumps(summary,indent=2))


if __name__=="__main__":
    main()
