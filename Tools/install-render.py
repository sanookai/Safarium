#!/usr/bin/env python3
"""Install a coherent, user-owned Safarium release on the internal disk; no daemon or network."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
FORMAT="safarium.personal-render-release/1"
LINKS={"bin/safarium":"../share/safarium/current/bin/safarium",
       "bin/safarium-render":"../share/safarium/current/bin/safarium-render",
       "bin/safarium-mcp":"../share/safarium/current/bin/safarium-mcp",
       "libexec/safarium":"../share/safarium/current/libexec/safarium",
       "share/safarium/render-standard.md":"current/share/safarium/render-standard.md",
       "share/safarium/project-video-rule.md":"current/share/safarium/project-video-rule.md"}


def sha(p):
    h=hashlib.sha256()
    with p.open("rb") as f:
        for block in iter(lambda:f.read(1024*1024),b""):
            h.update(block)
    return h.hexdigest()


def own_dir(p,create=False):
    if create:
        try:p.mkdir(mode=0o700)
        except FileExistsError:pass
    s=p.lstat()
    if not stat.S_ISDIR(s.st_mode) or s.st_uid!=os.getuid() or s.st_mode & 0o022:
        raise ValueError(f"expected a user-owned directory not writable by others: {p}")


def current_release(base,allow_legacy=False):
    cur=base/"current"
    if not os.path.lexists(cur):return None
    if not cur.is_symlink():raise ValueError(f"refusing to replace an unrelated path: {cur}")
    target=os.readlink(cur)
    if not re.fullmatch(r"releases/[0-9a-f]{64}",target):
        raise ValueError(f"unrecognized current release link: {cur}")
    p=base/target;verify(p,require_media=not allow_legacy,require_unified=not allow_legacy,require_mcp=not allow_legacy)
    return p


def verify(dest,require_media=True,require_unified=True,require_mcp=True):
    own_dir(dest)
    dest_real=dest.resolve()
    receipt=dest/"manifest.json"
    if receipt.is_symlink() or not receipt.is_file():raise ValueError(f"missing local release receipt: {dest}")
    m=json.loads(receipt.read_text())
    files=m.get("files",{});required={"bin/safarium-render","libexec/safarium/safarium-html",
        "libexec/safarium/safarium-verify",
        "libexec/safarium/Safarium_SafariumCore.bundle/Contents/Resources/clock.js",
        "share/safarium/render-standard.md"}
    if require_unified:
        required.add("bin/safarium")
    if require_mcp:
        required.add("bin/safarium-mcp")
    if require_media:
        required.add("libexec/safarium/safarium-media")
        required.add("libexec/safarium/safarium-forge")
        required.add("libexec/safarium/prism-blender-worker.py")
    if m.get("format")!=FORMAT or not required<=files.keys():
        raise ValueError(f"bad release receipt: {dest}")
    reference=hashlib.sha256(json.dumps(files,sort_keys=True,separators=(",",":")).encode()).hexdigest()
    if reference!=dest.name:raise ValueError("release ID does not match its content manifest")
    expected=set(files.keys())|{"manifest.json"}
    for p in dest_real.rglob("*"):
        rel=str(p.relative_to(dest_real))
        if p.is_symlink():raise ValueError(f"unexpected symlink in release: {rel}")
        if p.is_file() and rel not in expected:raise ValueError(f"unexpected extra file in release: {rel}")
    for name,item in files.items():
        p=dest_real/name
        if not p.is_relative_to(dest_real) or p.resolve()!=p or p.is_symlink() or not p.is_file():
            raise ValueError(f"unrecognized payload path: {name}")
        if sha(p)!=item["sha256"] or stat.S_IMODE(p.stat().st_mode)!=item["mode"]:
            raise ValueError(f"installed payload modified: {name}")
    return m


def payload(release,verifier):
    mapping={"bin/safarium":(ROOT/"bin/safarium",0o700),
             "bin/safarium-render":(ROOT/"bin/safarium-render",0o700),
             "bin/safarium-mcp":(ROOT/"bin/safarium-mcp",0o700),
             "libexec/safarium/safarium-html":(release/"safarium-html",0o700),
             "libexec/safarium/safarium-media":(release/"safarium-media",0o700),
             "libexec/safarium/safarium-forge":(release/"safarium-forge",0o700),
             "libexec/safarium/prism-blender-worker.py":(ROOT/"Tools/prism-blender-worker.py",0o600),
             "libexec/safarium/safarium-verify":(verifier,0o700),
             "share/safarium/render-standard.md":(ROOT/"docs/render-standard.md",0o600),
             "share/safarium/project-video-rule.md":(ROOT/"Tools/rules/sf-video-1.txt",0o600)}
    raster_lib=release/"libSafariumRaster.dylib"
    macho_checks=[release/"safarium-html",release/"safarium-media",release/"safarium-forge",verifier]
    if not raster_lib.is_symlink() and raster_lib.is_file():
        mapping["libexec/safarium/libSafariumRaster.dylib"]=(raster_lib,0o700)
        macho_checks.append(raster_lib)
    bundle=release/"Safarium_SafariumCore.bundle"
    if bundle.is_symlink() or not bundle.is_dir():raise ValueError("missing real SwiftPM clock resource bundle")
    for p in bundle.rglob("*"):
        if p.name.startswith("._"):continue
        if p.is_symlink():raise ValueError("unexpected symlink in input resource bundle")
        if p.is_file():mapping["libexec/safarium/"+str(p.relative_to(release))]=(p,0o600)
    clock="libexec/safarium/Safarium_SafariumCore.bundle/Contents/Resources/clock.js"
    if clock not in mapping or sha(mapping[clock][0])!=sha(ROOT/"Sources/SafariumCore/Resources/clock.js"):
        raise ValueError("build contains a different or missing virtual clock")
    for p,_ in mapping.values():
        if p.is_symlink() or not p.is_file():raise ValueError(f"missing regular input file: {p}")
    for p in macho_checks:
        with p.open("rb") as f:magic=f.read(4)
        if magic not in (b"\xcf\xfa\xed\xfe",b"\xfe\xed\xfa\xcf",b"\xca\xfe\xba\xbe",b"\xca\xfe\xba\xbf"):
            raise ValueError(f"expected a native macOS executable: {p}")
        id_res=subprocess.run(["/usr/bin/otool","-D",str(p)],check=True,capture_output=True,text=True,timeout=15)
        self_ids={ln.strip() for ln in id_res.stdout.splitlines()[1:] if ln.strip()}
        output=subprocess.run(["/usr/bin/otool","-L",str(p)],check=True,capture_output=True,text=True,timeout=15)
        deps=[line.strip().split(" (compatibility version ",1)[0] for line in output.stdout.splitlines() if line.startswith(("\t"," "))]
        checked=[s for s in deps if s not in self_ids]
        if not checked or any(not s.startswith(("/usr/lib/","/System/Library/","/Library/Apple/System/","/System/Volumes/Preboot/Cryptexes/OS/")) for s in checked):
            raise ValueError(f"{p.name}: not a self-contained worker linked only against Apple system libraries")
    return mapping


def validate_entrypoints(prefix,allow_missing):
    for name,target in LINKS.items():
        p=prefix/name
        if allow_missing and not os.path.lexists(p):continue
        if not p.is_symlink() or os.readlink(p)!=target:
            raise ValueError(f"refusing unrelated entry point: {p}")


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--prefix",type=Path,default=Path.home()/".local")
    ap.add_argument("--release",type=Path,help="built SwiftPM release directory containing safarium-html and its bundle")
    ap.add_argument("--verifier",type=Path,help="compiled Tools/safarium-verify.swift")
    ap.add_argument("--check",action="store_true")
    args=ap.parse_args()
    prefix=args.prefix.absolute();base=prefix/"share/safarium";releases=base/"releases"
    if args.check:
        for p in (prefix,prefix/"bin",prefix/"libexec",prefix/"share",base,releases):own_dir(p)
        validate_entrypoints(prefix,False);live=current_release(base)
        if live is None:raise ValueError("no installed current release")
        if not (prefix/"share/safarium/project-video-rule.md").is_file():raise ValueError("missing portable project rule")
        return {"status":"verified","release":live.name,"entry":str(prefix/"bin/safarium-render"),
                "unified_entry":str(prefix/"bin/safarium"),
                "standard":str(prefix/"share/safarium/render-standard.md"),"project_rule":str(prefix/"share/safarium/project-video-rule.md")}
    if args.release is None or args.verifier is None:ap.error("--release and --verifier are required to install")
    mapping=payload(args.release.resolve(),args.verifier.absolute())
    files={n:{"sha256":sha(p),"mode":m} for n,(p,m) in mapping.items()}
    tag=hashlib.sha256(json.dumps(files,sort_keys=True,separators=(",",":")).encode()).hexdigest()
    for p in (prefix,prefix/"share",base,releases,prefix/"bin",prefix/"libexec"):own_dir(p,True)
    fd=os.open(base/"install.lock",os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,"rb") as lock:
        s=os.fstat(lock.fileno())
        if not stat.S_ISREG(s.st_mode) or s.st_uid!=os.getuid() or s.st_nlink!=1:raise ValueError("unexpected installer lock")
        fcntl.flock(lock,fcntl.LOCK_EX)
        validate_entrypoints(prefix,True);old=current_release(base,allow_legacy=True)
        dest=releases/tag
        if not os.path.lexists(dest):
            stage=Path(tempfile.mkdtemp(prefix=".staging-",dir=releases))
            try:
                for name,(source,mode) in mapping.items():
                    p=stage/name;p.parent.mkdir(parents=True,exist_ok=True)
                    shutil.copyfile(source,p);p.chmod(mode)
                    if sha(p)!=files[name]["sha256"]:raise ValueError(f"source changed during install: {source}")
                (stage/"manifest.json").write_text(json.dumps({"format":FORMAT,"files":files},indent=2,sort_keys=True)+"\n")
                stage.rename(dest)
            finally:
                if stage.exists():shutil.rmtree(stage)  # only our private, uniquely created staging directory
        verify(dest)
        created=[]
        try:
            for name,target in LINKS.items():
                p=prefix/name
                if not os.path.lexists(p):p.symlink_to(target);created.append((p,target))
            if old!=dest:
                tmp=base/(".current-"+secrets.token_hex(12))
                try:
                    tmp.symlink_to("releases/"+tag)
                    os.replace(tmp,base/"current")  # one switch for all public entry points
                finally:
                    with contextlib.suppress(FileNotFoundError):tmp.unlink()
        except BaseException:
            for p,target in reversed(created):
                if p.is_symlink() and os.readlink(p)==target:p.unlink()
            raise
    return {"status":"unchanged" if old==dest else "installed","release":tag,
            "previous_release":old.name if old else None,"entry":str(prefix/"bin/safarium-render"),
            "unified_entry":str(prefix/"bin/safarium"),
            "standard":str(prefix/"share/safarium/render-standard.md"),"payload_files":len(files)}


if __name__=="__main__":
    try:print(json.dumps(main(),ensure_ascii=False))
    except (OSError,ValueError,KeyError,TypeError,subprocess.SubprocessError) as e:sys.exit("install-render: "+str(e))
