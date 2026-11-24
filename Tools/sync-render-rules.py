#!/usr/bin/env python3
"""Install the SF-VIDEO-1 block into individually reviewed local instruction files, not app databases."""
import argparse
import ctypes as C
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
VAULT=ROOT.parent.parent
BEGIN=b"<!-- safarium:SF-VIDEO-1:begin -->"
END=b"<!-- safarium:SF-VIDEO-1:end -->"
SECRET=re.compile(rb"(?:-----BEGIN (?:[A-Z ]*PRIVATE) KEY-----|(?:sk-(?:proj-|ant-|live-|)[A-Za-z0-9_-]{20,}|gh[pou]_[A-Za-z0-9]{28,}|AIza[0-9A-Za-z_-]{35}))")


def digest(b):return hashlib.sha256(b).hexdigest()


def copy_metadata(src,dest):
    """Darwin's COPYFILE_METADATA: ACL + stat + extended attributes. Never copy DATA."""
    if sys.platform!="darwin":raise ValueError("this installer requires macOS file metadata semantics")
    native=C.CDLL(None,use_errno=True).fcopyfile
    native.argtypes=[C.c_int,C.c_int,C.c_void_p,C.c_uint32];native.restype=C.c_int
    with os.fdopen(os.open(src,os.O_RDONLY|os.O_NOFOLLOW),"rb") as origin, \
         os.fdopen(os.open(dest,os.O_RDWR|os.O_NOFOLLOW),"r+b") as staged:
        if native(origin.fileno(),staged.fileno(),None,0x07)!=0:
            e=C.get_errno();raise OSError(e,"could not preserve macOS file metadata",str(src))
        os.fsync(staged.fileno())


def writable_target(p):
    flags=stat.UF_IMMUTABLE|stat.UF_APPEND|stat.SF_IMMUTABLE|stat.SF_APPEND
    if p.lstat().st_flags & flags:raise ValueError(f"protected instruction file; left untouched: {p}")


def rule_history(home):
    # The binary installer creates ~/.local, but a fresh account need not have ~/.local/state.
    prefix=home/".local";parent=prefix/"state";history=parent/"safarium-standard"
    for d in (prefix,parent,history):
        if d!=prefix:
            try:d.mkdir(mode=0o700)
            except FileExistsError:pass
        st=d.lstat()
        mask=0o077 if d==history else 0o022
        if d.resolve()!=d or not stat.S_ISDIR(st.st_mode) or st.st_uid!=os.getuid() or st.st_mode&mask:
            raise ValueError(f"unexpected file permissions on rule history path: {d}")
    return history


def safepath(s):
    p=Path(s).expanduser().absolute()
    if not (p.is_relative_to(Path.home()) or p==VAULT/"AGENTS.md"):
        raise ValueError(f"target is not a personal instruction file: {p}")
    if p.suffix.lower() not in (".md",".mdc") or p==Path.home():
        raise ValueError(f"no account/config databases or non-Markdown targets: {p}")
    if p.resolve(strict=False)!=p:
        raise ValueError(f"plan must point to the reviewed physical target, not a symlink: {p}")
    d=p.parent.stat()
    if d.st_uid!=os.getuid() or d.st_mode&0o022:raise ValueError(f"parent not privately managed: {p.parent}")
    return p


def load_target(p):
    try:s=p.lstat()
    except FileNotFoundError:return None
    if not stat.S_ISREG(s.st_mode) or s.st_uid!=os.getuid() or s.st_nlink!=1 or s.st_size>2_000_000:
        raise ValueError(f"unsafe or non-text instruction target: {p}")
    fd=os.open(p,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(fd,"rb") as f:
        s2=os.fstat(f.fileno())
        if (s.st_dev,s.st_ino)!=(s2.st_dev,s2.st_ino):raise ValueError(f"target changed: {p}")
        b=f.read()
    b.decode("utf-8")
    if SECRET.search(b):raise ValueError(f"possible credential in instruction file; did not copy or print it: {p}")
    return b


def make_after(t,old,body):
    if old is None:
        if "new_header" not in t:raise ValueError(f"required existing instructions missing: {t['path']}")
        source=t["new_header"].encode()
    else:source=old
    nl=b"\r\n" if b"\r\n" in source and b"\n" not in source.replace(b"\r\n",b"") else b"\n"
    block=BEGIN+nl+body.strip().replace(b"\n",nl)+nl+END
    n,e=source.count(BEGIN),source.count(END)
    if n or e:
        if (n,e)!=(1,1) or source.index(END)<source.index(BEGIN):raise ValueError(f"malformed existing managed block: {t['path']}")
        return source[:source.index(BEGIN)]+block+source[source.index(END)+len(END):]
    if "before" in t:
        anchor=t["before"].encode()
        if source.count(anchor)!=1:raise ValueError(f"unique anchor missing: {t['path']}")
        idx=source.index(anchor)
    elif "after" in t:
        anchor=t["after"].encode()
        if source.count(anchor)!=1:raise ValueError(f"unique anchor missing: {t['path']}")
        idx=source.index(anchor)+len(anchor)
    else:
        # Keep frontmatter, any instruction import and all unmanaged bytes intact.
        idx=source.find(b"\nup::")
        if idx<0:idx=len(source)
    return source[:idx]+nl+nl+block+nl+nl+source[idx:]


def put(p,expected,new):
    """Compare before publishing; preserve existing file mode & extended metadata."""
    if load_target(p)!=expected:raise ValueError(f"changed since preflight; left untouched: {p}")
    fd,tmp=tempfile.mkstemp(prefix=".safarium-rule-",dir=p.parent);tmp=Path(tmp)
    try:
        with os.fdopen(fd,"wb") as f:f.write(new);f.flush();os.fsync(f.fileno())
        if expected is not None:
            writable_target(p)
            copy_metadata(p,tmp)
            if tmp.read_bytes()!=new:raise ValueError(f"could not preserve contents and native metadata: {p}")
            os.utime(tmp,None)  # keep mode/xattrs, announce the new instruction to file watchers
        if load_target(p)!=expected:raise ValueError(f"concurrent edit; left untouched: {p}")
        if expected is None:os.link(tmp,p)  # fail if somebody created the target
        else:os.replace(tmp,p)
    finally:
        if tmp.exists():tmp.unlink()


def run(a):
    plan=json.loads(a.plan.read_text())
    if plan.get("schema")!="safarium.reviewed-rule-targets/1":raise ValueError("unsupported plan")
    if not plan.get("targets"):raise ValueError("empty instruction-file plan")
    home=Path.home();body=(ROOT/"Tools/rules/sf-video-1.txt").read_bytes()
    if a.mode=="apply":
        cmd=home/".local/bin/safarium-render";policy=home/".local/share/safarium/render-standard.md"
        if (not os.access(cmd,os.X_OK) or policy.read_bytes()!=(ROOT/"docs/render-standard.md").read_bytes()
                or policy.with_name("project-video-rule.md").read_bytes()!=body):
            raise ValueError("install and verify this release and standard before enabling global rules")
    entries=[];seen=set()
    for t in plan["targets"]:
        p=safepath(t["path"])
        if p in seen:raise ValueError(f"duplicate canonical target: {p}")
        seen.add(p);old=load_target(p);new=make_after(t,old,body)
        entries.append((t,p,old,new))
    stats=[{"path":str(p),"active":new==old,"before_sha256":digest(old) if old is not None else None,"after_sha256":digest(new)} for _,p,old,new in entries]
    if a.mode!="apply":
        if a.mode=="check" and not all(s["active"] for s in stats):raise ValueError("missing or outdated managed rule")
        return {"mode":a.mode,"targets":stats}
    state=rule_history(home)
    fd=os.open(state/"rules.lock",os.O_RDWR|os.O_CREAT|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,"rb") as lock:
        st=os.fstat(lock.fileno())
        if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.getuid() or st.st_nlink!=1 or stat.S_IMODE(st.st_mode)!=0o600:
            raise ValueError("unexpected rule history lock")
        fcntl.flock(lock,fcntl.LOCK_EX)
        if all(s["active"] for s in stats):return {"mode":"unchanged","count":len(entries)}
        bdir=Path(tempfile.mkdtemp(prefix=dt.datetime.now().strftime("%Y%m%d-%H%M%S-"),dir=state))
        for i,(_,p,old,new) in enumerate(entries):
            if load_target(p)!=old:raise ValueError(f"changed during preflight: {p}")
            if old is not None and old!=new:
                writable_target(p)
                b=bdir/f"before-{i}.md";b.write_bytes(old);copy_metadata(p,b)
                if b.read_bytes()!=old:raise ValueError(f"could not verify original backup for: {p}")
                stats[i]["backup"]=str(b)  # The containing history and unique backup directories are 0700.
        receipt=bdir/"manifest.json";receipt.write_text(json.dumps(stats,indent=2,ensure_ascii=False)+"\n");receipt.chmod(0o600)
        changed=[]
        try:
            for _,p,old,new in entries:
                if old!=new:put(p,old,new);changed.append((p,old,new))
            for _,p,_,new in entries:
                if load_target(p)!=new:raise ValueError(f"post-write verification failed: {p}")
        except BaseException:
            for p,old,new in reversed(changed):
                if load_target(p)==new:
                    if old is None:p.unlink()
                    else:put(p,new,old)
            raise
        return {"mode":"applied","count":len(entries),"changed":len(changed),"receipt":str(receipt),"block_sha256":digest(body)}


if __name__=="__main__":
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument("mode",choices=["plan","apply","check"])
    ap.add_argument("--plan",required=True,type=Path)
    try:print(json.dumps(run(ap.parse_args()),ensure_ascii=False,indent=2))
    except (OSError,ValueError,TypeError,KeyError) as e:sys.exit("sync-render-rules: "+str(e))
