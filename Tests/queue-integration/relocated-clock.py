"""Relocated binary must actually use its sibling clock bundle, not a leftover build path."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def check(queue,scratch):
    w=Path(tempfile.mkdtemp(prefix="relocated-clock-",dir=scratch))
    production=queue.resolve().parents[1]/"libexec/safarium"
    source=production/"Safarium_SafariumCore.bundle"
    html=w/"check.html"
    html.write_text("""<!doctype html><meta charset=utf-8><body style="background:green">
        <script>window.__seek=()=>{if (window.__fixtureRelocatedClock !== true)
        throw Error("missing relocation fixture marker");};</script>""")
    reports={}
    for marked in (False,True):
        d=w/("marked" if marked else "stock");d.mkdir()
        worker=d/"safarium-html";shutil.copy2(production/"safarium-html",worker)
        placed=d/source.name;shutil.copytree(source,placed)
        if marked:
            with (placed/"Contents/Resources/clock.js").open("a") as f:f.write("\nwindow.__fixtureRelocatedClock = true;\n")
        movie=d/"fixture.mp4"
        cmd=[str(queue),"run","--",str(worker),str(html),"--width","104","--height","76","--fps","25",
             "--frames","1","--video-only","--output",str(movie)]
        r=subprocess.run(cmd,cwd=d,capture_output=True,timeout=40)
        assert (r.returncode==0)==marked and movie.is_file()==marked,(d.name,r.returncode,r.stderr[-300:])
        if not marked:assert b"missing relocation fixture marker" in r.stderr
        reports[d.name]={"exit":r.returncode,"output_published":movie.is_file()}
    result={"verified":True,"queue":str(queue),"source_bundle":str(source),"scratch":str(w),"cases":reports}
    (w/"summary.json").write_text(json.dumps(result,indent=2)+"\n")
    return result


if __name__=="__main__":
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--queue",type=Path,default=Path.home()/".local/bin/safarium-render")
    ap.add_argument("--scratch",type=Path,required=True)
    a=ap.parse_args();print(json.dumps(check(a.queue,a.scratch)))
