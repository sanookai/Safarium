"""Apple-only release gate for SF-VIDEO-1 on this Mac. Runs from any cwd; never installs anything."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess as sp
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]


def main(a):
    a.scratch.mkdir(parents=True, exist_ok=True)
    w=Path(tempfile.mkdtemp(dir=a.scratch.resolve(),prefix="standard-qa-"))
    prefix=a.prefix.expanduser().absolute();queue=prefix/"bin/safarium-render"
    worker=prefix/"libexec/safarium/safarium-html";py=sys.executable
    for d in ("native","queue","probes"):(w/d).mkdir()
    env={k:v for k,v in os.environ.items() if not k.startswith("SAFARIUM_")}
    env.update(SAFARIUM_PROBES="0",SAFARIUM_PROBE_SCRATCH=str(w/"probes"),PYTHONDONTWRITEBYTECODE="1")
    report={"pipeline_status":"INCOMPLETE","scratch":str(w),"entry":str(queue),"steps":[]}
    def save():
        (w/"summary.json").write_text(json.dumps(report,indent=2,ensure_ascii=False)+"\n")
    def step(name,cmd,timeout):
        path=w/(name+".log");start=time.monotonic()
        with path.open("xb") as f:
            try:r=sp.run([str(x) for x in cmd],cwd=ROOT,env=env,stdin=sp.DEVNULL,stdout=f,stderr=sp.STDOUT,timeout=timeout)
            except sp.TimeoutExpired:code="timeout"
            else:code=r.returncode
        record={"name":name,"exit":code,"seconds":round(time.monotonic()-start,3),"log":str(path)}
        report["steps"].append(record);save()
        if code!=0:raise RuntimeError(f"{name}: {code}; see {path}")
        print(f"{name}: PASS",flush=True)
        return path.read_text(errors="replace"),record
    print(f"evidence: {w}",flush=True)
    try:
        text,_=step("release", [py,ROOT/"Tools/install-render.py","--prefix",prefix,"--check"],30)
        report["installed_release"]=json.loads(text)["release"]
        t,rec=step("fifo",["/usr/bin/python3","-ISB",ROOT/"Tests/queue/test_queue.py","--scratch",w/"queue","-v"],150)
        matched=re.search(r"Ran (\d+) tests? in [\d.]+s",t)
        if not matched or "\nOK" not in t:raise RuntimeError("missing queue test summary")
        rec["tests"]=int(matched[1])
        if a.swift:
            t,rec=step("swift",[queue,"run","--","/usr/bin/xcrun","swift","test","-c","release","--jobs","2",
                "--scratch-path",a.swift_build or w/"swift"],420)
            # XCTest also prints per-suite totals and Swift Testing can print a separate 0 tests.
            bundles=re.findall(r"Test Suite 'All tests' passed[^\n]*\n\s*Executed (\d+) tests?, with "
                               r"(?:(\d+) tests? skipped and )?(\d+) failures?",t)
            count=sum(int(n) for n,_,_ in bundles);skips=sum(int(s or 0) for _,s,_ in bundles)
            failures=sum(int(f) for _,_,f in bundles)
            ignored=re.findall(r"Test Case '([^']+)' skipped",t)
            if not count or failures or any("SafariumProbeTests" not in s and "PerfTests" not in s for s in ignored):
                raise RuntimeError("could not confirm XCTest result or a nonoptional test was skipped")
            rec.update(executed=count,passed=count-skips,optional_skips=skips,failures=failures)
        step("worker",[queue,"run","--",py,ROOT/"Tests/native-html/smoke.py",worker,w/"native"],160)
        native,=(w/"native").glob("smoke-*/result.json")
        report["worker_regression"]=json.loads(native.read_text())
        text,_=step("relocation",[py,ROOT/"Tests/queue-integration/relocated-clock.py","--queue",queue,"--scratch",w],100)
        report["relocation"]=json.loads(text)
        step("two-client-EP30",[py,ROOT/"Tests/queue-integration/verify-installed.py","--queue",queue,"--scratch",w],190)
        ep30,=w.glob("installed-two-clients-*/summary.json")
        report["ep30"]=json.loads(ep30.read_text())
        text,_=step("mac-rule-metadata",[py,ROOT/"Tests/queue-integration/rule-sync.py","--scratch",w],60)
        report["metadata_regression"]=json.loads(text)
        if a.rules:
            if prefix!=Path.home()/".local":raise ValueError("--rules verifies the default personal installation only")
            text,_=step("active-rules",[py,ROOT/"Tools/sync-render-rules.py","check",
                        "--plan",ROOT/"Tools/rules/mac-default-targets.json"],40)
            report["configured_physical_files"]=sum(x["active"] for x in json.loads(text)["targets"])
            step("loader-discovery",[py,ROOT/"Tools/check-render-rule-loaders.py"],70)
        report["pipeline_status"]="ALL_PASSED";save()
    except (OSError,ValueError,RuntimeError) as e:
        report["pipeline_status"]="FAILED";report["reason"]=str(e);save();raise
    print(f"PIPELINE_STATUS: ALL_PASSED ({len(report['steps'])} steps) · {w/'summary.json'}")


if __name__=="__main__":
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument("--prefix",type=Path,default=Path.home()/".local")
    ap.add_argument("--scratch",type=Path,required=True)
    ap.add_argument("--swift",action="store_true",help="also build and run XCTest, opt-in heavy probes disabled")
    ap.add_argument("--swift-build",type=Path,help="reuse your scratch Release build for the XCTest step")
    ap.add_argument("--rules",action="store_true",help="also check the live default Mac rule paths and local loader discovery")
    main(ap.parse_args())
