#!/usr/bin/env python3
"""Read-only SF-VIDEO-1 check. JSON on stdout; 0 checked, 1 drift, 2 review/incomplete.

Run by path from any cwd. --self-test exercises in-memory fixtures and the same
two installed read-only loader functions. Neither mode starts an agent.
"""
import sys
sys.dont_write_bytecode = True

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
from contextlib import ExitStack
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SOURCE = "Tools/rules/sf-video-1.txt"
HOME = Path.home()
BEGIN = b"<!-- safarium:SF-VIDEO-1:begin -->"
END = b"<!-- safarium:SF-VIDEO-1:end -->"
LIMIT = 512 * 1024
FLAGS = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
TARGETS = {
    "core": "AGENTS.md", "claude": ".claude/CLAUDE.md",
    "gemini": ".gemini/GEMINI.md", "hermes": ".hermes/SOUL.md",
    "shared": ".agents/AGENTS.md", "freebuff": ".agents.md",
    "mcode": ".minimax/AGENTS.md", "copilot": ".copilot/copilot-instructions.md",
    "omp": ".omp/agent/AGENTS.md",
}
OMP_NEIGHBOURS = ("AGENTS.override.md", "CLAUDE.md", "RULES.md", "SYSTEM.md",
                  "SYSTEM_TEMPLATE.md", "APPEND_SYSTEM.md")


def digest(b):
    return hashlib.sha256(b).hexdigest()


def normalized(b):
    return b.replace(b"\r\n", b"\n")


def block_status(data, body):
    if data is None:
        return "unread"
    text = normalized(data)
    counts = (text.count(BEGIN), text.count(END))
    if counts == (0, 0):
        return "missing"
    if counts != (1, 1):
        return "malformed"
    lines = text.split(b"\n")
    if BEGIN not in lines or END not in lines or lines.index(BEGIN) >= lines.index(END):
        return "malformed"
    inside = b"\n".join(lines[lines.index(BEGIN) + 1:lines.index(END)])
    return "match" if inside == body else "drift"


def inspect(base, rel, read=False):
    """Only explicitly named files. Do not traverse symlinked profile directories."""
    p = base / rel
    record = {"kind": "missing", "path": p, "data": None}
    try:
        parent = base
        for part in Path(rel).parts[:-1]:
            parent = parent / part
            mode = parent.lstat().st_mode
            if not stat.S_ISDIR(mode):
                record["kind"] = "parent_link_or_non_directory"
                return record
        s = p.lstat()
        record.update(size=s.st_size, identity=(s.st_dev, s.st_ino, s.st_mtime_ns, s.st_size))
        if stat.S_ISLNK(s.st_mode):
            record["kind"] = "symlink"
        elif stat.S_ISDIR(s.st_mode):
            record["kind"] = "directory"
        elif not stat.S_ISREG(s.st_mode):
            record["kind"] = "non_regular"
        else:
            record["kind"] = "file"
            if read and s.st_nlink != 1:
                record["kind"] = "hardlinked_file_not_read"
            elif read and s.st_size > LIMIT:
                record["kind"] = "over_read_limit"
            elif read:
                with os.fdopen(os.open(p, FLAGS), "rb") as f:
                    if identity(f.fileno()) != record["identity"]:
                        raise OSError("file changed")
                    b = f.read(LIMIT + 1)
                    if len(b) != s.st_size or identity(f.fileno()) != record["identity"]:
                        raise OSError("file changed")
                    record["data"] = b
    except FileNotFoundError:
        if "identity" in record:
            record["kind"] = "changed_during_read"
    except (OSError, ValueError):
        record["kind"] = "unreadable_or_changed"
    return record


def identity(fd):
    s = os.fstat(fd)
    return s.st_dev, s.st_ino, s.st_mtime_ns, s.st_size


def home(rel, read=False):
    return inspect(HOME, rel, read)


def present(record):
    return record["kind"] != "missing"


def core_alias(rel, core, allowed_links):
    """Never follow an arbitrary symlink to inspect its contents."""
    rec = home(rel)
    if rec["kind"] == "file":
        return "hardlink" if rec.get("identity", ())[:2] == core.get("identity", ())[:2] else "other_regular_file"
    if rec["kind"] != "symlink" or core["kind"] != "file":
        return rec["kind"]
    try:
        link = os.readlink(rec["path"])
        target = Path(os.path.normpath(os.path.join(rec["path"].parent, link)))
        if target not in {HOME / name for name in allowed_links}:
            return "other_link_not_followed"
        if target == HOME / ".codex/AGENTS.md" and core_alias(".codex/AGENTS.md", core, ["AGENTS.md"]) != "symlink_to_core":
            return "unverified_intermediate"
        return "symlink_to_core" if os.path.samefile(rec["path"], core["path"]) else "other_link"
    except OSError:
        return "unreadable_link"


def claude_import(data):
    # Recognize the existing standalone native import, not a mention in prose,
    # a fenced example, an indented code block or an HTML comment.
    cleaned = re.sub(rb"<!--.*?(?:-->|\Z)", b"", data or b"", flags=re.S)
    fence = None
    for raw in normalized(cleaned).lstrip(b"\xef\xbb\xbf").split(b"\n"):
        if raw.startswith((b"    ", b"\t")):
            continue
        line = raw.strip()
        mark = re.match(rb"(`{3,}|~{3,})", line)
        if mark:
            run = mark.group(1)
            if fence is None:
                fence = run
            elif run.startswith(fence) and line == run:
                fence = None
        elif fence is None and line == b"@~/AGENTS.md":
            return True
    return False


def selection(override):
    if not present(override):
        return "default"
    if override["kind"] != "file" or override["data"] is None:
        return "unknown_override"
    return "override" if override["data"].strip() else "default"


def scoped_override(var, default=None):
    value = os.environ.get(var)
    if not value:
        return False
    if default is None:
        return True
    # Compare paths without opening, enumerating or disclosing the other home.
    return os.path.normpath(os.path.expanduser(value)) != str(HOME / default)


def freebuff_names():
    # The native selector matches case-insensitively on the direct home names.
    # No stat/open of any other name; no recursive or profile enumeration.
    with os.scandir(HOME) as names:
        return [e.name for e in names if e.name.lower() in (".agents.md", ".claude.md")]


def hidden_risk(names, existing):
    high = [n for n in names if n.lower() == ".agents.md"]
    if len(high) > 1 or (high and not existing):
        return "competing_case_variant"
    if any(n.lower() == ".claude.md" for n in names):
        return "masks_existing_hidden_claude" if existing else "would_mask_existing_hidden_claude"
    return None


# Pinned *individual read functions* from the installed builds. Read only these
# byte ranges; do not load the native executable, large bundle or account config.
# An update/missing build fails closed to path-only evidence. Never evaluate
# unrecognized code. Offsets are just locators; SHA-256 is mandatory.
PINS = {
    "freebuff": (".config/manicode/freebuff", {
        "fn": (64609113, 520, "5c5a226e0b30a44c0b53fb9ccc54361977c63b3cf1d724271b884bafe4f018f9"),
        "names": (64225410, 60, "134aa8f6bed5a3a60cc57bb88334e5f46a6af0a6e036bbee3d6e0d97b1818e47"),
    }),
    "mcode": (".local/lib/node_modules/@minimax-ai/code/chunks/chunk-L2QPVMF4.js", {
        "ctor": (9090890, 63, "5dabd0b7f3b8b0cb47f985176ac5fe43e2f8b48d5367ea6190d513bc6191b513"),
        "read": (9091140, 185, "6ec3a7f71adf2e6b62b1ed902383abb2af8950c044474bfbcfc24442f074ab9e"),
        "limit": (9090755, 10, "80b9f8c0366cb52dac31a1137541878e02d9894cceeda8ca232fad0da17d7279"),
    }),
}


def installed_fragments():
    out = {}
    for client, (rel, regions) in PINS.items():
        r = home(rel)
        if r["kind"] != "file":
            continue
        try:
            with os.fdopen(os.open(r["path"], FLAGS), "rb") as f:
                if identity(f.fileno()) != r["identity"]:
                    continue
                parts = {}
                for key, (offset, size, expected) in regions.items():
                    f.seek(offset)
                    b = f.read(size)
                    if digest(b) != expected:
                        break
                    parts[key] = b.decode("ascii")
                else:
                    out[client] = parts
        except (ValueError, OSError):
            pass
    return out


# Node is only a JS interpreter here. Production reads use inherited, parent-
# validated read-only descriptors. The extracted functions get no open-by-path,
# process, require, network, or write API. Only result labels leave the child.
JS_PROBES = r"""
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const p = JSON.parse(fs.readFileSync(0,'utf8')), out = {};
const size = x => x.fd === undefined ? Buffer.byteLength(x.text) : fs.fstatSync(x.fd).size;
function value(x) {
  if (x.fd === undefined) return x.text;
  const n = size(x); if (n !== x.size || n > p.cap) throw Error('changed');
  const b = Buffer.alloc(n); let at = 0;
  while (at < n) { const k = fs.readSync(x.fd,b,at,n-at,at); if (!k) throw Error('changed'); at += k; }
  return b.toString('utf8');
}
function check(s) {
  if (typeof s !== 'string') return 'no_content';
  if (p.fixture && s.replace(/\r\n/g,'\n').trim()===p.body) return 'canonical_unwrapped_fixture';
  const l = s.replace(/\r\n/g,'\n').split('\n'), i = l.indexOf(p.begin), j = l.indexOf(p.end);
  return i >= 0 && j > i && s.split(p.begin).length === 2 && s.split(p.end).length === 2 &&
    l.slice(i+1,j).join('\n') === p.body ? 'match' : 'nonmatching_content';
}
async function run(id, code, dir, names, entries) {
  function get(f) { if (!Object.hasOwn(entries,f)) throw Error('not in read view'); return entries[f]; }
  const read = async (f,enc) => { if (enc !== 'utf8') throw Error('encoding'); return value(get(f)); };
  const ctx = {STT:{join:path.join}, PGA:{homedir:()=>dir}, $N:()=> 'unreadable',
    G$s:path.resolve, W$s:async f=>({size:size(get(f))}), Jon:read, Buffer:{byteLength:Buffer.byteLength}};
  const load = s => vm.runInNewContext(s,ctx,{timeout:1000});
  if (id==='freebuff') {
    const fn = load(`(()=>{let cI,oU;${code.names};return (${code.fn});})()`);
    const results = await fn({homeDir:dir,fs:{readdir:async f=>{if(f!==dir)throw Error('dir');return names;},readFile:read}});
    const [item] = Object.entries(results);
    return {selected:item ? item[0] : null,returned:check(item?.[1])};
  }
  const Cls = load(`(()=>{let ${code.limit};return class{${code.ctor}${code.read}}})()`);
  const reader = new Cls(dir), t = await reader.readForPrompt();
  const candidate=reader.filePath===path.join(dir,'AGENTS.md') ? 'AGENTS.md' : null;
  return {candidate,selected:typeof t==='string' ? candidate : null,returned:check(t)};
}
(async () => {
  for (const [id,code] of Object.entries(p.codes)) {
    if (!p.fixture) {
      const v=p.live[id]; if(v)out[id]=await run(id,code,v.dir,v.names,v.entries);
    } else {
      const dir='/fixture', doc=[p.begin,p.body,p.end].join('\n');
      const sample=async map=>run(id,code,dir,Object.keys(map),Object.fromEntries(Object.entries(map).map(([n,text])=>[path.join(dir,n),{text}])));
      const tests={};
      if(id==='freebuff'){
        const a=await sample({'.CLAUDE.md':'old','.Agents.md':doc});
        tests.case_and_priority=a.selected==='~/.Agents.md'&&a.returned==='match';
        tests.fallback=(await sample({'.CLAUDE.md':doc})).selected==='~/.CLAUDE.md';
        tests.visible_core_ignored=(await sample({'AGENTS.md':doc})).selected===null;
      } else {
        tests.present=(await sample({'AGENTS.md':doc})).returned==='match';
        tests.missing=(await sample({})).returned==='no_content';
        tests.blank=(await sample({'AGENTS.md':' \n'})).returned==='no_content';
        tests.byte_limit=(await sample({'AGENTS.md':doc+' '.repeat(32769)})).returned==='no_content';
      }
      // Exercise the production descriptor adapter on actual, unwrapped rule
      // bytes, with a fixture pathname. This is not a real home-file selection.
      const name=id==='freebuff'?'.agents.md':'AGENTS.md';
      const real=await run(id,code,dir,[name],{[path.join(dir,name)]:p.fixtureFile});
      tests.read_only_source_descriptor=real.returned==='canonical_unwrapped_fixture' &&
        real.selected===(id==='freebuff'?'~/.agents.md':'AGENTS.md');
      out[id]=tests;
    }
  }
  process.stdout.write(JSON.stringify(out));
})().catch(()=>{process.exitCode=2;});
"""


def offline_probes(body, records=None, hidden=None):
    codes = installed_fragments()
    result = {k: {"evidence": "unavailable", "reason": "unrecognized_or_missing_installed_build"} for k in PINS}
    node = next((p for p in ("/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node")
                 if os.path.isfile(p) and os.access(p, os.X_OK)), None)
    if not node:
        return {k: {"evidence": "unavailable", "reason": "no_system_node"} for k in PINS}
    fixture = records is None
    with ExitStack() as stack:
        live, fds = {}, []
        fixture_file = None
        if fixture:
            try:
                src = inspect(ROOT, SOURCE, True)
                if src["kind"] != "file" or normalized(src["data"]).strip() != body:
                    raise OSError("source changed")
                f = stack.enter_context(os.fdopen(os.open(src["path"], FLAGS), "rb"))
                if identity(f.fileno()) != src["identity"]:
                    raise OSError("source changed")
                fds.append(f.fileno())
                fixture_file = {"fd": f.fileno(), "size": src["size"]}
            except OSError:
                return {k: {"evidence": "unavailable", "reason": "source_descriptor_changed"} for k in PINS}
        for key in codes:
            if fixture:
                continue
            entries = hidden if key == "freebuff" else {"AGENTS.md": records["mcode"]}
            if entries is None:
                result[key]["reason"] = "candidate_names_unavailable"
                continue
            view = {}
            try:
                for name, rec in entries.items():
                    if not present(rec):
                        continue
                    if rec["kind"] != "file" or rec["data"] is None:
                        raise OSError("not approved")
                    f = stack.enter_context(os.fdopen(os.open(rec["path"], FLAGS), "rb"))
                    if identity(f.fileno()) != rec["identity"]:
                        raise OSError("changed")
                    view[str(rec["path"])] = {"fd": f.fileno(), "size": rec["size"]}
                    fds.append(f.fileno())
                live[key] = {"dir": str(HOME if key == "freebuff" else HOME / ".minimax"),
                             "names": list(entries), "entries": view}
            except OSError:
                result[key]["reason"] = "unreadable_link_or_changed_candidate"
        if not codes or (not fixture and not live):
            return result
        payload = dict(codes=codes, fixture=fixture, fixtureFile=fixture_file, live=live, cap=LIMIT, body=body.decode("utf8"),
                       begin=BEGIN.decode(), end=END.decode())
        try:
            proc = subprocess.run([node, "-e", JS_PROBES], input=json.dumps(payload).encode(),
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=6,
                                  pass_fds=tuple(fds), cwd="/",
                                  env={"PATH": "/usr/bin:/bin", "LC_ALL": "C", "NODE_DISABLE_COMPILE_CACHE": "1"})
            if proc.returncode or len(proc.stdout) > 8192:
                raise ValueError("interpreter error")
            for key, item in json.loads(proc.stdout).items():
                result[key] = dict(evidence="installed_function_on_fixture" if fixture else "installed_function_on_local_files", **item)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            for key in codes if fixture else live:
                result[key] = {"evidence": "unavailable", "reason": "isolated_probe_failed"}
    return result


def installed(commands=(), apps=()):
    bins = (HOME / ".local/bin", Path("/opt/homebrew/bin"), Path("/usr/local/bin"))
    return any(shutil.which(c) or any((d / c).is_file() and os.access(d / c, os.X_OK) for d in bins)
               for c in commands) or any(
        (base / (app + ".app")).is_dir() for base in (Path("/Applications"), HOME / "Applications") for app in apps)


def audit(body):
    rec = {k: home(v, True) for k, v in TARGETS.items()}
    checks = {k: block_status(r["data"], body) for k, r in rec.items()}
    targets = {k: {"path": "~/" + TARGETS[k], "kind": r["kind"], "block": checks[k]} for k, r in rec.items()}
    review, notes = [], []
    risk = None
    try:
        names = freebuff_names()
        hidden = {n: home(n, True) for n in names}
        risk = hidden_risk(names, present(rec["freebuff"]))
        if risk:
            review.append("freebuff:" + risk)
    except OSError:
        hidden = None
        risk = "cannot_check_hidden_rule_names"
        review.append("freebuff:" + risk)
    neighbours = [name for name in OMP_NEIGHBOURS if present(home(".omp/agent/" + name))]
    omp = installed(("omp",))
    if neighbours:
        # These are not all precedence overrides. Separate rule/prompt slots
        # can legitimately coexist; an automated checker cannot judge conflict.
        notes.append({"omp_companion_files": neighbours})
        review.append("omp:inspect_existing_native_companion_before_claiming_no_conflict")
    required = set(TARGETS) - ({"omp"} if not omp else set())
    for key, value in rec.items():
        if key in required and value["kind"] not in ("missing", "file"):
            review.append(key + ":physical_target_not_a_readable_regular_file")
    for key in ("freebuff", "mcode", "copilot", "omp"):
        kind = rec[key]["kind"]
        if kind not in ("missing", "file"):
            guard = "review_nonregular_target"
        elif key == "freebuff" and risk:
            guard = risk
        elif key == "omp" and neighbours:
            guard = "review_companion_files"
        elif key == "omp" and not omp:
            guard = "not_applicable_no_local_omp"
        elif kind == "file":
            guard = "preserve_existing_regular_file"
        else:
            guard = "no_known_default_fallback_would_be_shadowed"
        targets[key]["placement_guard"] = guard
    alias = core_alias(".codex/AGENTS.md", rec["core"], ["AGENTS.md"])
    override = selection(home(".codex/AGENTS.override.md", True))
    imported = claude_import(rec["claude"]["data"])
    native_oc = home(".config/opencode/AGENTS.md")
    if alias != "symlink_to_core" or override != "default":
        review.append("codex:core_alias_changed_or_override_selected")
    if not imported:
        review.append("claude:expected_native_core_import_not_confirmed")
    if present(native_oc):
        review.append("opencode:existing_native_global_shadows_claude_fallback")
    oc_disabled = any(os.environ.get(k, "").lower() in ("1", "true", "yes", "on") for k in
                      ("OPENCODE_DISABLE_CLAUDE_CODE", "OPENCODE_DISABLE_CLAUDE_CODE_PROMPT"))
    probes = offline_probes(body, rec, hidden)
    chains = []

    def add(client, evidence, selected=None, rule=None, overrides=(), note=None):
        item = {"client": client, "evidence": evidence}
        if selected:
            item["default_source"] = selected
        if rule is not None:
            item["block"] = rule
        if overrides:
            item["nondefault_process_selectors"] = list(overrides)
            item["effective_nondefault_source"] = "not_inspected"
        if note:
            item["limit"] = note
        chains.append(item)

    def flags(*pairs):
        return [var for var, default in pairs if scoped_override(var, default)]

    def direct(client, key, evidence="configured_path", overrides=(), note=None):
        add(client, evidence, "~/" + TARGETS[key], checks[key], overrides, note)

    direct("Claude Code (local)", "claude", "native_import_syntax_and_filesystem",
           flags(("CLAUDE_CONFIG_DIR", ".claude")), "Core import retained: " + str(imported).lower() + "; no Claude parser/session started.")
    add("Codex (local CLI/desktop)", "filesystem_resolution",
        "~/.codex/AGENTS.md" if override == "default" else "~/.codex/AGENTS.override.md",
        checks["core"] if alias == "symlink_to_core" and override == "default" else "unverified",
        flags(("CODEX_HOME", ".codex")), "default_alias=" + alias + "; override_selection=" + override)
    add("OpenCode", "filesystem_resolution",
        "~/.config/opencode/AGENTS.md" if present(native_oc) else "~/.claude/CLAUDE.md",
        checks["claude"] if not present(native_oc) and not oc_disabled else "unverified",
        flags(("XDG_CONFIG_HOME", ".config"), ("OPENCODE_CONFIG_DIR", ".config/opencode")),
        "Claude fallback disabled in inspecting process." if oc_disabled else
        "Default fallback resolution only; no server settings read and no Claude @ expansion assumed.")
    if oc_disabled:
        notes.append("OpenCode inspecting process disables Claude fallback; the running service may have a different environment.")
    direct("Gemini CLI", "gemini", overrides=flags(("GEMINI_CLI_HOME", None)),
           note="Default context filename; no settings inspected.")
    direct("Antigravity App / agy / IDE", "gemini",
           note="Common documented file. Independent ~/.gemini/config/GEMINI.md is " +
           home(".gemini/config/GEMINI.md")["kind"] + "; source selection across modes not exercised.")
    direct("Hermes default", "hermes", overrides=flags(("HERMES_HOME", ".hermes"), ("HERMES_DATA_DIR_SUFFIX", None)),
           note="No identity loader called: the installed function can initialize the home and inspect profile state.")
    add("Hermes named/other profiles", "conditional", note="Each effective HERMES_HOME/SOUL.md is independent; no profiles enumerated.")
    direct("Cline", "shared", note="Default global source; rule toggles not inspected.")
    direct("Kimi Code", "shared", overrides=flags(("KIMI_CODE_HOME", ".kimi-code")),
           note="Generic real-home file; independent branded AGENTS.md is not required to contain a second block.")
    direct("DeepSeek Harness", "shared", overrides=flags(("DSH_AGENTS_HOME", ".agents"), ("DSH_HOME", ".dsh")),
           note="Documented default instructions plugin; profiles and plugin settings not inspected.")
    direct("GitHub Copilot CLI", "copilot", overrides=flags(("COPILOT_HOME", ".copilot")),
           note="Default user source; per-file toggles not inspected.")
    direct("Oh My Pi (OMP)", "omp", "configured_path" if omp else "not_detected",
           flags(("PI_CONFIG_DIR", None), ("PI_CODING_AGENT_DIR", ".omp/agent"), ("OMP_PROFILE", None)),
           "Native slot; do not rely on the optional Codex provider. Companion files are review signals, not proof of precedence.")
    for key, name in (("freebuff", "Freebuff"), ("mcode", "MiniMax Code v2")):
        probe = probes[key]
        add(name, probe["evidence"], probe.get("selected") if key == "freebuff" else "~/.minimax/AGENTS.md",
            probe.get("returned", "unverified"),
            flags(("MINIMAX_DATA_DIR", ".minimax"), ("MAVIS_DATA_DIR", ".minimax"),
                  ("MINIMAX_PROFILE", None), ("MAVIS_PROFILE", None)) if key == "mcode" else (),
            probe.get("reason", "Isolated installed read function; not a full client ingest."))
    runtime = "Library/Application Support/Orca/codex-runtime-home/home/"
    managed = core_alias(runtime + "AGENTS.md", rec["core"], ["AGENTS.md", ".codex/AGENTS.md"])
    add("Orca", "conditional", note="Selected backend/host governs. Known default Codex runtime entry=" + managed +
        "; override=" + home(runtime + "AGENTS.override.md")["kind"] + "; managed/named homes not enumerated.")
    add("OpenFilm built-in Pi", "project_only", "<actual Studio cwd>/<selected AGENTS or CLAUDE file>",
        note="Installed app filter retains only the cwd rule. Its external adapters use their own selected backends.")
    add("Muse Code", "conditional", note="May use a live foreign source, a native copy, or neither; /rules can disambiguate in an existing session.")
    add("Cursor IDE/CLI", "conditional" if installed(("cursor", "cursor-agent", "agent"), ("Cursor",)) else "not_detected",
        note="User Rules UI or selected project; ~/.cursor is not the Codex home.")
    add("Pi standalone", "conditional" if installed(("pi",)) else "not_detected", note="Pi extensions or an embedded SDK do not establish a standalone launch.")
    add("Grok Build CLI", "conditional" if installed(("grok",)) else "not_detected", note="A retained profile/dangling launcher is not a runnable CLI.")
    add("Grok Bot / Manus / consumer chat or cloud jobs", "external_ui", note="No host-global loading demonstrated.")
    projects = {"this_project_AGENTS": inspect(ROOT, "AGENTS.md")["kind"],
                "this_project_override": inspect(ROOT, "AGENTS.override.md")["kind"],
                "this_project_CLAUDE": inspect(ROOT, "CLAUDE.md")["kind"]}
    if ROOT.parent.name == "Projects":
        projects["vault_root_AGENTS"] = inspect(ROOT.parent.parent, "AGENTS.md")["kind"]
    missing = sorted(k for k in required if checks[k] != "match")
    ran = [k for k, v in probes.items() if v["evidence"] == "installed_function_on_local_files"]
    wrong = [k for k in ran if probes[k]["returned"] != "match"]
    if review:
        status, code = "review", 2
    elif missing or wrong:
        status, code = "needs_sync_or_loader_mismatch", 1
    elif len(ran) != len(PINS):
        status, code = "matching_files_incomplete_loader_evidence", 2
    else:
        status, code = "default_files_and_two_isolated_reads_match", 0
    counts = {"required": len(required), "matching_required": len(required) - len(missing),
              "isolated_functions_exercised": len(ran), "isolated_reads_with_rule": len(ran) - len(wrong)}
    return code, dict(status=status, counts=counts, physical_targets=targets, required_mismatches=missing,
                      review=review, notes=notes, offline_loaders=probes, client_chains=chains,
                      project_reference_metadata=projects, scope="Default paths only. No live app/model ingest or render measured.")


def self_test(body):
    good = b"\n".join((BEGIN, body, END))
    tests = {
        "exact": block_status(good, body) == "match",
        "crlf": block_status(good.replace(b"\n", b"\r\n"), body) == "match",
        "duplicate": block_status(good + b"\n" + good, body) == "malformed",
        "reversed": block_status(END + b"\n" + BEGIN, body) == "malformed",
        "inline_marker": block_status(b"example: " + good, body) == "malformed",
        "drift": block_status(BEGIN + b"\nchanged\n" + END, body) == "drift",
        "unmarked_reference": block_status(b"See SF-VIDEO-1", body) == "missing",
        "claude_import": claude_import(b"@~/AGENTS.md\n"),
        "example_is_not_import": not claude_import(b"```\n@~/AGENTS.md\n```\n<!--\n@~/AGENTS.md\n-->"),
        "codex_empty_override": selection({"kind": "file", "data": b" \n"}) == "default",
        "codex_real_override": selection({"kind": "file", "data": b"other"}) == "override",
        "freebuff_prior_fallback": hidden_risk([".CLAUDE.md"], False) == "would_mask_existing_hidden_claude",
        "freebuff_duplicate_case": hidden_risk([".AGENTS.md", ".agents.md"], True) == "competing_case_variant",
    }
    probes = offline_probes(body)
    ran = all(v["evidence"] == "installed_function_on_fixture" for v in probes.values())
    passed = all(tests.values()) and ran and all(all(x is True for k, x in v.items() if k != "evidence") for v in probes.values())
    return 0 if passed else 2, dict(status="passed" if passed else "failed_or_incomplete", checks=tests,
                                   offline_loaders=probes, scope="In-memory cases plus real read-only canonical source descriptors at fixture paths; no files created.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true", help="Run offline, in-memory validation cases")
    args = parser.parse_args()
    source = inspect(ROOT, SOURCE, True)
    raw = source["data"]
    body = normalized(raw).strip() if raw else b""
    if not body or BEGIN in body or END in body:
        code, report = 2, {"status": "invalid_or_missing_unwrapped_source"}
    else:
        try:
            body.decode("utf8")
            code, report = self_test(body) if args.self_test else audit(body)
        except UnicodeDecodeError:
            code, report = 2, {"status": "source_not_utf8"}
    print(json.dumps(dict(schema=1, rule="SF-VIDEO-1", source=SOURCE,
                          source_sha256=digest(raw) if raw else None, **report),
                     ensure_ascii=False, separators=(",", ":")))
    return code


if __name__ == "__main__":
    sys.exit(main())
