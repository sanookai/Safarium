#!/usr/bin/env python3
"""Export and/or audit a clean standalone public repository for Safarium (Apache-2.0).

Usage:
  python3 Tools/export-public-repo.py --output /tmp/safarium-public-export --clean --json
  python3 Tools/export-public-repo.py --audit-dir /tmp/safarium-public-export --json
  python3 Tools/export-public-repo.py --output /tmp/safarium-public-export --clean --build-test --json
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Callable


REPO_ROOT = Path(__file__).resolve().parents[1]

# Explicitly excluded private/personal docs that audit private Vault projects or dotfiles.
EXCLUDED_DOCS = {
    "docs/49-projects-deep-dissection-2026-11-23.md",
    "docs/vault-render-audit-2026-11-22.md",
    "docs/mac-native-innovations-wave2-2026-11-22.md",
    "docs/render-rule-coverage.md",
    "docs/inventory.md",
    "docs/pilot-results-2026-11-21.md",
    "docs/x9-headline.md",
    "docs/snapshot-anatomy-2026-11-21.md",
}

EXPORTED_BIN_FILES = (
    "bin/safarium",
    "bin/safarium-render",
    "bin/safarium-mcp",
    "bin/safarium-hf",
    "bin/safarium-soundtrack",
)

EXPORTED_TOOL_FILES = (
    "Tools/install-render.py",
    "Tools/safarium-verify.swift",
    "Tools/prism-blender-worker.py",
    "Tools/sync-render-rules.py",
    "Tools/check-render-rule-loaders.py",
    "Tools/export-public-repo.py",
)

FORBIDDEN_FILENAMES = {".DS_Store", ".env"}
FORBIDDEN_DIRNAMES = {"__pycache__", ".pytest_cache", ".build", ".git", ".swiftpm"}
FORBIDDEN_SUFFIXES = (".pyc", ".pyo", ".o", ".so", ".dylib", ".mp4", ".mov", ".wav", ".m4a", ".mpeg", ".ogg", ".blend")

PERSONAL_PATH_PATTERNS = (
    (re.compile(r"/Volumes/Main"), "hardcoded /Volumes/Main path"),
    (re.compile(r"/Users/chawakornbuasontorn"), "hardcoded personal home path"),
    (re.compile(r"/private/tmp/claude-501"), "hardcoded personal scratchpad path"),
    (re.compile(r"My second brain", re.IGNORECASE), "personal vault name"),
    (re.compile(r"\[\[Projects/Safarium"), "Obsidian Vault wikilink"),
    (re.compile(r"file:///Volumes/"), "file:///Volumes/ URL"),
)

SECRET_PATTERNS = (
    (re.compile(r"gh[pousr]_[A-Za-z0-9_]{20,}"), "GitHub token"),
    (re.compile(r"sk-(?:proj-|ant-|live-)?[A-Za-z0-9_-]{20,}"), "API secret key"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "AWS access key"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "private key block"),
    (re.compile(r"AIza[0-9A-Za-z_-]{35}"), "Google API key"),
    (re.compile(r"Authorization:\s*Bearer\s+[A-Za-z0-9._-]{16,}", re.IGNORECASE), "Bearer token"),
)

# Production directories checked for zero FFmpeg / Chrome / OpenCV runtime invocation.
PRODUCTION_DIRS = ("Sources", "bin", "sdk/python/safarium_cv2", "sdk/python/safarium_sci", "sdk/node", "sdk/shell")

# Lines allowed to mention ffmpeg/chrome/opencv strictly as policy denials, docs/comments, or error messages.
ALLOWED_PRODUCTION_MENTION = re.compile(
    r"(no\s+ffmpeg|zero\s+ffmpeg|0%\s*ffmpeg|without\s+ffmpeg|no\s+opencv|zero\s+opencv|"
    r"no\s+chrome|zero\s+chrome|refused|blocked|not\s+a\s+.*ffmpeg|replaces\s+opencv|"
    r"porting\s+small|from\s+opencv|mirror\s+opencv|opencv\s+5\.1|opencv's|like\s+opencv|"
    r"alternative\s+to\s+ffmpeg|instead\s+of\s+ffmpeg|ffmpegcalls|ffmpeg_?path\s*=\s*nil|"
    r"chromeTabs|puppeteer|hyperframes|^\s*(?://|#|\"\"\"|\*)|\bDIRECT_REFUSAL\b|"
    r"\br\".*(?:ffmpeg|ffprobe|chromium|chrome)|\"(?:ffmpeg|ffprobe|ffplay|avconv|avprobe))",
    re.IGNORECASE,
)

FORBIDDEN_PROD_CALL = re.compile(
    r"""(?:\bsubprocess\.(?:run|Popen|check_output|check_call)\s*\(\s*\[?\s*["'](?:ffmpeg|ffprobe|google-chrome|chromium)"""
    r"""|\bexecFileSync\s*\(\s*["'](?:ffmpeg|ffprobe|google-chrome|chromium)"""
    r"""|\bProcess\b.*(?:ffmpeg|ffprobe|google-chrome|chromium)"""
    r"""|^\s*(?:import\s+cv2\b|from\s+cv2\s+import\b))""",
    re.IGNORECASE,
)


def _should_skip_rel(rel: Path) -> bool:
    for part in rel.parts:
        if part.startswith("._") or part in FORBIDDEN_DIRNAMES or part in FORBIDDEN_FILENAMES or part.startswith(".env"):
            return True
    name = rel.name
    if name.startswith("._") or name in FORBIDDEN_FILENAMES or name.endswith(".pre-webkit"):
        return True
    if any(name.endswith(sfx) for sfx in FORBIDDEN_SUFFIXES):
        return True
    return False


def _strip_obsidian_boilerplate(text: str) -> str:
    # Remove `parent: "[[Projects/Safarium/_Index]]"` from YAML frontmatter and trailing `up:: [[Projects/Safarium/_Index]]`.
    lines = text.splitlines(keepends=True)
    out = []
    for line in lines:
        stripped = line.strip()
        if re.match(r'^parent:\s*"?\[\[Projects/Safarium/_Index\]\]"?$', stripped):
            continue
        if stripped == "up:: [[Projects/Safarium/_Index]]":
            continue
        out.append(line)
    cleaned = "".join(out)

    # Convert file:///Volumes/Main/My second brain/Projects/Safarium/... links to relative/repo paths.
    cleaned = re.sub(
        r"file:///Volumes/Main/My%20second%20brain/Projects/Safarium/",
        "",
        cleaned,
    )
    cleaned = re.sub(
        r"/private/tmp/claude-501/[^\s`)\"']+",
        "<scratch>",
        cleaned,
    )

    def _wiki_repl(m: re.Match[str]) -> str:
        target = m.group(1).strip()
        alias = m.group(2).strip() if m.group(2) else Path(target).name
        if target.startswith("Projects/Safarium/"):
            rel_target = target[len("Projects/Safarium/"):]
            if not rel_target.endswith(".md") and "/" in rel_target:
                rel_target += ".md"
            return f"[{alias}]({rel_target})"
        return alias

    cleaned = re.sub(r"\[\[([^\]|]+?)(?:\|([^\]]+?))?\]\]", _wiki_repl, cleaned)
    cleaned = cleaned.replace("/Volumes/Main (ExFAT)", "external ExFAT volume")
    cleaned = cleaned.replace("ExFAT `/Volumes/Main`", "external ExFAT volume")
    cleaned = cleaned.replace("`/Volumes/Main`", "an external ExFAT volume")
    cleaned = cleaned.replace("/Volumes/Main", "external ExFAT volume")
    cleaned = cleaned.replace("/Users/chawakornbuasontorn", "$HOME")
    cleaned = cleaned.replace("My second brain", "workspace")
    return cleaned


def _sanitize_swift_forge_main(text: str) -> str:
    old_block = (
        '    if FileManager.default.fileExists(atPath: "/Volumes/Main") {\n'
        '        volumePaths.append("/Volumes/Main")\n'
        "    }"
    )
    new_block = (
        '    if let extraVol = ProcessInfo.processInfo.environment["SAFARIUM_EXTRA_VOLUME"],\n'
        "       !extraVol.isEmpty,\n"
        "       FileManager.default.fileExists(atPath: extraVol) {\n"
        "        volumePaths.append(extraVol)\n"
        "    }"
    )
    text = text.replace(old_block, new_block)
    text = text.replace(
        '"ExFAT volumes (e.g. /Volumes/Main) lack clonefile/RENAME_EXCL; handled via APFSAutoStage + SafeFilePublisher"',
        '"ExFAT external volumes lack clonefile/RENAME_EXCL; handled via APFSAutoStage + SafeFilePublisher"',
    )
    return text


def _sanitize_apfs_autostage(text: str) -> str:
    return text.replace(
        "// Cross-device (e.g. APFS cache -> ExFAT /Volumes/Main):",
        "// Cross-device (e.g. APFS cache -> ExFAT external volume):",
    )


def _sanitize_bin_render(text: str) -> str:
    return text.replace(
        '    main_vol_mounted = os.path.exists("/Volumes/Main")',
        '    extra_vol = os.environ.get("SAFARIUM_EXTRA_VOLUME", "")\n    main_vol_mounted = bool(extra_vol and os.path.exists(extra_vol))',
    )


def _sanitize_legacy_vorbis_tests(text: str) -> str:
    replacement = (
        '    private static let projectsRoot = ProcessInfo.processInfo.environment["SAFARIUM_LEGACY_ASSETS_ROOT"] ?? ""\n'
        '    private static let pianoOgg = projectsRoot + "/piano.ogg"\n'
        '    private static let pianoWav = projectsRoot + "/piano.wav"\n'
        '    private static let howtoMPEG = projectsRoot + "/HowtoUse1927.mpeg"\n'
        '    private static let curiousBach = projectsRoot + "/curious-bach-wtc-prelude-c-major.ogg"\n'
        '    private static let calmSatie = projectsRoot + "/calm-satie-gymnopedie-1.ogg"\n'
        '    private static let footstepSnow = projectsRoot + "/footstep_snow_002.ogg"'
    )
    pattern = re.compile(
        r'    private static let projectsRoot = "/Volumes/Main/[^\n]*\n(?:    private static let [^\n]*\n){5}    private static let footstepSnow = [^\n]*',
    )
    text, count = pattern.subn(replacement, text, count=1)
    assert count == 1, "expected projectsRoot block in LegacyContainerVorbisTests.swift"
    text = text.replace(
        "guard FileManager.default.fileExists(atPath: Self.projectsRoot) else {",
        "guard !Self.projectsRoot.isEmpty, FileManager.default.fileExists(atPath: Self.projectsRoot) else {",
    )
    text = text.replace(
        "if FileManager.default.fileExists(atPath: Self.projectsRoot) {",
        "if !Self.projectsRoot.isEmpty, FileManager.default.fileExists(atPath: Self.projectsRoot) {",
    )
    return text


def _sanitize_forge_engine_tests(text: str) -> str:
    old = (
        "        // /Volumes/Main is ExFAT on this host (if mounted)\n"
        '        if FileManager.default.fileExists(atPath: "/Volumes/Main") {\n'
        '            let exfatCaps = try APFSAutoStage.inspectVolume(at: URL(fileURLWithPath: "/Volumes/Main"))'
    )
    new = (
        "        // Optional ExFAT mount check when SAFARIUM_TEST_EXFAT_PATH is provided\n"
        '        if let exfatPath = ProcessInfo.processInfo.environment["SAFARIUM_TEST_EXFAT_PATH"],\n'
        "           !exfatPath.isEmpty,\n"
        "           FileManager.default.fileExists(atPath: exfatPath) {\n"
        "            let exfatCaps = try APFSAutoStage.inspectVolume(at: URL(fileURLWithPath: exfatPath))"
    )
    return text.replace(old, new)


def _sanitize_wave6_apple_tests(text: str) -> str:
    old = (
        "        // ExFAT cache root rejection (when /Volumes/Main is mounted and ExFAT)\n"
        '        if FileManager.default.fileExists(atPath: "/Volumes/Main") {\n'
        '            let mainCaps = try APFSAutoStage.inspectVolume(at: URL(fileURLWithPath: "/Volumes/Main"))\n'
        "            if !mainCaps.isAPFS {\n"
        '                let badRoot = URL(fileURLWithPath: "/Volumes/Main/.test-invalid-cache-\\(UUID().uuidString.prefix(8))", isDirectory: true)'
    )
    new = (
        "        // ExFAT cache root rejection (when SAFARIUM_TEST_EXFAT_PATH points to an ExFAT mount)\n"
        '        if let exfatPath = ProcessInfo.processInfo.environment["SAFARIUM_TEST_EXFAT_PATH"],\n'
        "           !exfatPath.isEmpty,\n"
        "           FileManager.default.fileExists(atPath: exfatPath) {\n"
        "            let mainCaps = try APFSAutoStage.inspectVolume(at: URL(fileURLWithPath: exfatPath))\n"
        "            if !mainCaps.isAPFS {\n"
        '                let badRoot = URL(fileURLWithPath: "\\(exfatPath)/.test-invalid-cache-\\(UUID().uuidString.prefix(8))", isDirectory: true)'
    )
    return text.replace(old, new)


def _sanitize_sci_parity_tests(text: str) -> str:
    text = re.sub(
        r'SOMPONG = Path\("/Volumes/Main/[^\n]*\)',
        'SOMPONG = Path(os.environ.get("SAFARIUM_EXTERNAL_ASSETS_DIR", "/nonexistent-safarium-assets"))',
        text,
    )
    text = text.replace("Sompong ETOPO pack file not on this machine", "External ETOPO pack file not on this machine")
    return text


def _sanitize_bench_common(text: str) -> str:
    return re.sub(
        r'SOMPONG = Path\(os\.environ\.get\("BENCH_SOMPONG_DIR"\) or Path\(__file__\)\.resolve\(\)\.parents\[5\] / "[^"]+"\)',
        'SOMPONG = Path(os.environ.get("BENCH_SOMPONG_DIR") or os.environ.get("SAFARIUM_BENCH_ASSETS_DIR", "/nonexistent-safarium-bench-assets"))',
        text,
    )


def _sanitize_bench_raster(text: str) -> str:
    text = text.replace(', \'parent: "[[Projects/Safarium/_Index]]"\'', "")
    text = text.replace('"up:: [[Projects/Safarium/_Index]]"', '"Generated by SafariumRaster acceptance harness."')
    return text


def _sanitize_test_bench_raster(text: str) -> str:
    text = text.replace(',\n                \'parent: "[[Projects/Safarium/_Index]]"\'', "")
    text = text.replace('"up:: [[Projects/Safarium/_Index]]"', '"Generated by SafariumRaster acceptance harness."')
    return text


def _sanitize_mac_default_targets(text: str) -> str:
    data = json.loads(text)
    targets = [
        t for t in data.get("targets", [])
        if "/Volumes/" not in t.get("path", "") and "My second brain" not in t.get("path", "")
    ]
    data["targets"] = targets
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


SANITIZERS: dict[str, Callable[[str], str]] = {
    "Sources/safarium-forge/ForgeCLI.swift": _sanitize_swift_forge_main,
    "Sources/SafariumForgeCore/APFSAutoStage.swift": _sanitize_apfs_autostage,
    "bin/safarium-render": _sanitize_bin_render,
    "Tests/SafariumContainersTests/LegacyContainerVorbisTests.swift": _sanitize_legacy_vorbis_tests,
    "Tests/SafariumForgeTests/ForgeEngineTests.swift": _sanitize_forge_engine_tests,
    "Tests/SafariumForgeTests/Wave6AppleSiliconTests.swift": _sanitize_wave6_apple_tests,
    "sdk/python/tests/test_parity_sci.py": _sanitize_sci_parity_tests,
    "sdk/python/tests/bench_cases/_common.py": _sanitize_bench_common,
    "sdk/python/tests/bench_raster.py": _sanitize_bench_raster,
    "sdk/python/tests/test_bench_raster.py": _sanitize_test_bench_raster,
    "Tools/rules/mac-default-targets.json": _sanitize_mac_default_targets,
}


def _collect_export_pairs(source: Path) -> tuple[list[tuple[Path, str]], list[str]]:
    pairs: list[tuple[Path, str]] = []
    excluded: list[str] = []

    def add_file(src: Path, rel_str: str) -> None:
        rel = Path(rel_str)
        if _should_skip_rel(rel):
            excluded.append(rel_str)
            return
        if not src.is_file() or src.is_symlink():
            excluded.append(rel_str)
            return
        pairs.append((src, rel_str))

    def add_tree(root_rel: str, skip_pred: Callable[[str], bool] | None = None) -> None:
        base = source / root_rel
        if not base.is_dir():
            return
        for dirpath, dirnames, filenames in os.walk(base, followlinks=False):
            # Prune excluded directories in place
            dirnames[:] = sorted(
                d for d in dirnames
                if not d.startswith("._") and d not in FORBIDDEN_DIRNAMES and not (Path(dirpath) / d).is_symlink()
            )
            for fname in sorted(filenames):
                full = Path(dirpath) / fname
                rel_str = str(full.relative_to(source))
                if skip_pred and skip_pred(rel_str):
                    excluded.append(rel_str)
                    continue
                add_file(full, rel_str)

    # 1. Root package + exported GitHub templates + CI workflow
    add_file(source / "Package.swift", "Package.swift")
    for name in ("LICENSE", "README.md", "CONTRIBUTING.md", ".gitignore"):
        add_file(source / "Tools" / "github-export" / name, name)

    ci_src = source / ".github" / "workflows" / "ci-macos.yml"
    pairs.append((ci_src, ".github/workflows/ci-macos.yml"))

    # 2. Swift & C Sources, Tests, SDK, Skills
    add_tree("Sources")
    add_tree("Tests")
    add_tree("sdk")
    add_tree("skills/safarium")

    # 3. Binaries & Tools (allowlist only)
    for rel_str in EXPORTED_BIN_FILES:
        add_file(source / rel_str, rel_str)
    for rel_str in EXPORTED_TOOL_FILES:
        add_file(source / rel_str, rel_str)
    add_tree("Tools/rules")

    # 4. Public docs (exclude private Vault audit/draft notes) & published benchmark JSON
    add_tree("docs", skip_pred=lambda r: r in EXCLUDED_DOCS)
    add_file(
        source / "bench/experiments/2026-11-25-wave9-supremacy/results.json",
        "bench/experiments/2026-11-25-wave9-supremacy/results.json",
    )
    add_file(
        source / "bench/experiments/2026-11-25-wave10-complete/results.json",
        "bench/experiments/2026-11-25-wave10-complete/results.json",
    )

    return pairs, sorted(set(excluded))


def export_repo(source: Path, output: Path, clean: bool = False) -> dict:
    source = source.resolve()
    output = output.resolve()
    if output == source or source in output.parents:
        raise ValueError(f"refusing to export inside source repository: {output}")

    if output.exists():
        if not clean:
            raise FileExistsError(f"output directory already exists (pass --clean): {output}")
        if not str(output).startswith(("/tmp/", "/private/tmp/", "/var/folders/")):
            raise ValueError(f"refusing --clean outside /tmp or /var/folders: {output}")
        shutil.rmtree(output)

    output.mkdir(parents=True, exist_ok=True)
    pairs, excluded = _collect_export_pairs(source)

    sanitized_files: list[str] = []
    exported_files = 0
    for src, rel_str in pairs:
        dst = output / rel_str
        dst.parent.mkdir(parents=True, exist_ok=True)
        src_mode = src.stat().st_mode

        is_markdown = rel_str.endswith(".md") and (
            rel_str.startswith(("docs/", "skills/", "sdk/")) or rel_str in ("README.md", "CONTRIBUTING.md")
        )
        sanitizer = SANITIZERS.get(rel_str)

        if sanitizer is not None or is_markdown:
            raw_text = src.read_text(encoding="utf-8")
            new_text = raw_text
            if sanitizer is not None:
                new_text = sanitizer(new_text)
            if is_markdown and rel_str not in ("README.md", "CONTRIBUTING.md"):
                new_text = _strip_obsidian_boilerplate(new_text)
            if new_text != raw_text:
                sanitized_files.append(rel_str)
            dst.write_text(new_text, encoding="utf-8")
            raw_head = new_text[:4].encode("utf-8", errors="ignore")
        else:
            shutil.copyfile(src, dst)
            with src.open("rb") as fh:
                raw_head = fh.read(4)

        # /Volumes/Main (ExFAT) marks every file 0755; assign executable bits cleanly by path/extension/shebang.
        if rel_str.startswith("bin/") or rel_str.endswith(".sh") or raw_head.startswith(b"#!"):
            dst.chmod(0o755)
        else:
            dst.chmod(0o644)
        exported_files += 1

    return {
        "source": str(source),
        "output": str(output),
        "exportedFiles": exported_files,
        "excludedCount": len(excluded),
        "sanitizedFiles": sorted(sanitized_files),
    }


def audit_directory(root: Path) -> dict:
    root = root.resolve()
    violations: list[dict] = []
    scanned_files = 0

    if not (root / "LICENSE").is_file() or "Apache License" not in (root / "LICENSE").read_text(encoding="utf-8", errors="replace"):
        violations.append({"type": "license", "path": "LICENSE", "detail": "missing or invalid Apache-2.0 LICENSE"})
    for req in ("README.md", "CONTRIBUTING.md", ".gitignore", ".github/workflows/ci-macos.yml", "Package.swift"):
        if not (root / req).is_file():
            violations.append({"type": "missing_required", "path": req, "detail": "required public repo file missing"})

    # Keep .github/workflows/ci-macos.yml and Tools/github-export/.github/workflows/ci-macos.yml identical if both exist.
    wf_main = root / ".github/workflows/ci-macos.yml"
    wf_copy = root / "Tools/github-export/.github/workflows/ci-macos.yml"
    if wf_main.is_file() and wf_copy.is_file() and wf_main.read_bytes() != wf_copy.read_bytes():
        violations.append({"type": "workflow_drift", "path": ".github/workflows/ci-macos.yml", "detail": "workflow out of sync with Tools/github-export copy"})

    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        rel_dir = Path(dirpath).relative_to(root)
        # Skip .git metadata if --init-git was run, while still flagging any non-.git forbidden dirs.
        if rel_dir.parts and rel_dir.parts[0] == ".git":
            continue
        for d in list(dirnames):
            full_d = Path(dirpath) / d
            rel_d = str(full_d.relative_to(root))
            if full_d.is_symlink():
                violations.append({"type": "symlink", "path": rel_d, "detail": "unexpected symlink"})
                dirnames.remove(d)
                continue
            if d.startswith("._") or (d in FORBIDDEN_DIRNAMES and d != ".git"):
                violations.append({"type": "forbidden_dir", "path": rel_d, "detail": f"forbidden directory {d}"})
                dirnames.remove(d)
                continue
        if ".git" in dirnames:
            dirnames.remove(".git")

        for fname in sorted(filenames):
            full = Path(dirpath) / fname
            rel_str = str(full.relative_to(root))
            if full.is_symlink():
                violations.append({"type": "symlink", "path": rel_str, "detail": "unexpected symlink"})
                continue
            if fname.startswith("._") or fname in FORBIDDEN_FILENAMES or fname.startswith(".env"):
                violations.append({"type": "forbidden_file", "path": rel_str, "detail": f"forbidden file {fname}"})
                continue
            if any(fname.endswith(sfx) for sfx in FORBIDDEN_SUFFIXES) or fname.endswith(".pre-webkit"):
                violations.append({"type": "forbidden_artifact", "path": rel_str, "detail": f"forbidden binary/artifact {fname}"})
                continue

            scanned_files += 1
            raw = full.read_bytes()
            if b"\x00" in raw:
                continue  # non-text binary (e.g., PNG test fixture)
            text = raw.decode("utf-8", errors="replace")

            # Do not flag regex definitions inside Tools/export-public-repo.py itself!
            is_exporter = rel_str == "Tools/export-public-repo.py"

            if not is_exporter:
                for pat, desc in PERSONAL_PATH_PATTERNS:
                    m = pat.search(text)
                    if m:
                        violations.append({"type": "personal_path", "path": rel_str, "detail": f"{desc}: {m.group(0)}"})
                for pat, desc in SECRET_PATTERNS:
                    m = pat.search(text)
                    if m:
                        violations.append({"type": "secret", "path": rel_str, "detail": f"{desc} match"})

            if any(rel_str == p or rel_str.startswith(p + "/") for p in PRODUCTION_DIRS) and not is_exporter:
                for lineno, line in enumerate(text.splitlines(), 1):
                    if FORBIDDEN_PROD_CALL.search(line) and not ALLOWED_PRODUCTION_MENTION.search(line):
                        violations.append({
                            "type": "production_forbidden_dep",
                            "path": f"{rel_str}:{lineno}",
                            "detail": line.strip()[:160],
                        })

    return {
        "root": str(root),
        "scannedFiles": scanned_files,
        "violationCount": len(violations),
        "violations": violations,
        "passed": len(violations) == 0,
    }


def run_standalone_build(root: Path, scratch_path: Path) -> dict:
    cmd = [
        "/usr/bin/xcrun", "swift", "build",
        "--package-path", str(root),
        "--scratch-path", str(scratch_path),
        "--jobs", "2",
    ]
    proc = subprocess.run(cmd, cwd=root, capture_output=True, text=True, timeout=600)
    return {
        "command": " ".join(cmd),
        "returncode": proc.returncode,
        "passed": proc.returncode == 0,
        "stderrTail": proc.stderr[-1500:] if proc.returncode != 0 else "",
    }


def init_standalone_git(root: Path) -> dict:
    subprocess.run(["/usr/bin/git", "init", "-b", "main"], cwd=root, check=True, capture_output=True)
    subprocess.run(["/usr/bin/git", "add", "-A"], cwd=root, check=True, capture_output=True)
    status = subprocess.check_output(["/usr/bin/git", "status", "--short"], cwd=root, text=True)
    staged_appledouble = [ln for ln in status.splitlines() if "/._" in ln or ln.strip().endswith("._") or " ._" in ln]
    return {
        "initialized": True,
        "stagedCount": len(status.splitlines()),
        "stagedAppleDouble": staged_appledouble,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", type=Path, default=REPO_ROOT)
    ap.add_argument("--output", type=Path, default=Path("/tmp/safarium-public-export"))
    ap.add_argument("--audit-dir", type=Path, help="audit an existing directory instead of exporting")
    ap.add_argument("--clean", action="store_true", help="remove existing --output directory under /tmp before export")
    ap.add_argument("--build-test", action="store_true", help="run standalone swift build in the exported directory")
    ap.add_argument("--scratch-path", type=Path, default=Path("/tmp/safarium-export-build"))
    ap.add_argument("--init-git", action="store_true", help="initialize standalone git repo in --output")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    result: dict = {}
    target = args.audit_dir.resolve() if args.audit_dir else args.output.resolve()

    if not args.audit_dir:
        result["export"] = export_repo(args.source, target, clean=args.clean)

    audit = audit_directory(target)
    result["audit"] = audit

    ok = audit["passed"]
    if args.init_git and not args.audit_dir:
        result["git"] = init_standalone_git(target)
        if result["git"]["stagedAppleDouble"]:
            ok = False

    if args.build_test:
        build_res = run_standalone_build(target, args.scratch_path.resolve())
        result["buildTest"] = build_res
        ok = ok and build_res["passed"]

    result["ok"] = ok
    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
