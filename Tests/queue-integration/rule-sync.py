"""Regression for Mac metadata, first-run state, defaults and idempotence; scratch account only."""
import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[2]


def test(base):
    work=Path(tempfile.mkdtemp(dir=base,prefix="rule-sync-"));home=work/"account";home.mkdir()
    prefix=home/".local";(prefix/"bin").mkdir(parents=True)
    # Only the rule sync prerequisites are needed; no executable is invoked by this test.
    cmd=prefix/"bin/safarium-render";cmd.write_text("#!/bin/sh\nexit 0\n");cmd.chmod(0o700)
    share=prefix/"share/safarium";share.mkdir(parents=True)
    (share/"render-standard.md").write_bytes((ROOT/"docs/render-standard.md").read_bytes())
    (share/"project-video-rule.md").write_bytes((ROOT/"Tools/rules/sf-video-1.txt").read_bytes())
    rule=home/"AGENTS.md";original=b"# My rules\r\n\r\nKeep existing instructions.\r\n"
    rule.write_bytes(original);rule.chmod(0o640)
    attr="org.safarium.test-rule-metadata"
    subprocess.run(["/usr/bin/xattr","-w",attr,"preserve this",str(rule)],check=True)
    other=home/"Other.md"
    plan=work/"plan.json";plan.write_text(json.dumps({"schema":"safarium.reviewed-rule-targets/1","targets":[
        {"path":str(rule),"before":"Keep existing instructions."},{"path":str(other),"new_header":"# Test rules\n"}]}))
    def run(mode):
        return json.loads(subprocess.check_output([sys.executable,str(ROOT/"Tools/sync-render-rules.py"),mode,
            "--plan",str(plan)],cwd=work,env={**os.environ,"HOME":str(home)},timeout=15))
    assert not (prefix/"state").exists()
    assert len(run("plan")["targets"])==2 and not (prefix/"state").exists()
    change=run("apply");assert change["mode"]=="applied" and change["changed"]==2
    journal=Path(change["receipt"]);orig=Path(json.loads(journal.read_text())[0]["backup"])
    assert orig.read_bytes()==original and stat.S_IMODE(journal.parent.stat().st_mode)==0o700
    for p in (rule,orig):
        assert stat.S_IMODE(p.stat().st_mode)==0o640
        assert subprocess.check_output(["/usr/bin/xattr","-p",attr,str(p)]).strip()==b"preserve this"
    b=rule.read_bytes()
    assert b.startswith(b"# My rules\r\n") and b.endswith(b"Keep existing instructions.\r\n")
    assert b"\n" not in b.replace(b"\r\n",b"") and b.count(b"<!-- safarium:SF-VIDEO-1:begin -->")==1
    assert run("apply")["mode"]=="unchanged" and all(t["active"] for t in run("check")["targets"])
    r={"status":"PASS","scratch":str(work),"fresh_state_created":True,"xattrs_and_mode_preserved_in_file_and_backup":True,
       "old_rules_and_crlf_preserved":True,"second_apply_unchanged":True}
    (work/"summary.json").write_text(json.dumps(r,indent=2)+"\n");return r


if __name__=="__main__":
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument("--scratch",required=True,type=Path)
    print(json.dumps(test(ap.parse_args().scratch)))
