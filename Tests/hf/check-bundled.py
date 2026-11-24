#!/usr/bin/env python3
"""Verify HF's own CDN-script fulfillment without giving the shim an upstream CDN fallback."""
import argparse
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--shim", type=Path, required=True)
    ap.add_argument("--scratch", type=Path, required=True)
    ap.add_argument("--hf-version", default="0.9.72")
    a = ap.parse_args()
    work = Path(tempfile.mkdtemp(prefix="hf-gsap-", dir=a.scratch.resolve()))
    scene = work/"scene"
    scene.mkdir()
    shutil.copyfile(HERE/"gsap-check.html", scene/"index.html")
    # The producer starts a browser with a sanitized environment. Set the
    # test-specific offline policy and trace at the actual child boundary.
    child = work/"webkit-only"
    child.write_text("#!/bin/sh\nexport SAFARIUM_FETCH_OFFLINE=1\nexport SAFARIUM_CDP_TRACE=" +
                     shlex.quote(str(work)) + "/trace-$$.log\nexport SAFARIUM_CDP_LOG=" +
                     shlex.quote(str(work/"unsupported.log")) + "\nexec " + shlex.quote(str(a.shim.resolve())) + ' "$@"\n')
    child.chmod(0o700)
    env = {**os.environ, "SAFARIUM_CDP":str(child), "SAFARIUM_HF_VERSION":a.hf_version,
           "DO_NOT_TRACK":"1", "HYPERFRAMES_RENDER_LOCK_DIR":str(work/"locks")}
    print("evidence:", work, flush=True)
    hf_bin = ROOT / "bin/safarium-hf"
    hf_cmd = [str(hf_bin)] if os.access(hf_bin, os.X_OK) else ["/bin/sh", str(hf_bin)]
    with (work/"check.log").open("wb") as output:
        proc = subprocess.Popen([*hf_cmd, "check", str(scene), "--no-cache",
                                "--samples","2","--budget","30s","--json"],cwd=scene,env=env,
                               stdout=output,stderr=output,start_new_session=True)
        try:
            rc = proc.wait(timeout=65)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid,signal.SIGTERM)
            try:
                proc.wait(timeout=4)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid,signal.SIGKILL)
                proc.wait()
            rc = 124
    log = (work/"check.log").read_text(errors="replace")
    files = list((scene/".hyperframes/artifacts/checks").glob("*.json"))
    report = json.loads(files[0].read_text()) if len(files) == 1 else {}
    if "browserSkipped" not in report:  # Older releases may only print the report.
        at = log.find('{\n  "ok"')
        if at >= 0:
            report = json.JSONDecoder().raw_decode(log[at:])[0]
    lines = [l for p in work.glob("trace-*.log") for l in p.read_text(errors="replace").splitlines()]
    paused = sum("Fetch.requestPaused" in l and "cdn.jsdelivr.net" in l for l in lines)
    result = {"version":a.hf_version,"exit":rc,"browserSkipped":report.get("browserSkipped"),
              "samples":report.get("layout",{}).get("samples"),"paused_CDN":paused,
              "pass":bool(not rc and report.get("ok") and report.get("browserSkipped") is False and paused)}
    (work/"summary.json").write_text(json.dumps(result,indent=2)+"\n")
    print(json.dumps(result,indent=2))
    return 0 if result["pass"] else 1


if __name__=="__main__":
    raise SystemExit(main())
