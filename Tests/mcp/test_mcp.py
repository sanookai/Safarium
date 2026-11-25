#!/usr/bin/env python3
"""Offline unit & protocol test suite for bin/safarium-mcp (MCP stdio JSON-RPC 2.0)."""

import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
MCP_SOURCE = REPO_ROOT / "bin" / "safarium-mcp"


def _write_exec(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(0o700)


class SafariumMCPTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="safarium-mcp-test-"))
        self.bin_dir = self.tmp / "bin"
        self.bin_dir.mkdir(mode=0o700)
        self.mcp_bin = self.bin_dir / "safarium-mcp"
        shutil.copyfile(MCP_SOURCE, self.mcp_bin)
        self.mcp_bin.chmod(0o700)

        # Trusted sibling stubs so tests are 100% isolated from live ~/.safarium-render-queue
        _write_exec(
            self.bin_dir / "safarium-render",
            """#!/usr/bin/python3 -ISB
import json, sys, time
args = sys.argv[1:]
if args[:2] == ["doctor", "--json"]:
    print(json.dumps({"healthy": True, "issues": [], "workers": {"ok": True}}))
    sys.exit(0)
if args[:1] == ["status"]:
    print(json.dumps({"active": None, "waiting": [], "detail": "--json-detail" in args}))
    sys.exit(0)
if args[:1] == ["capabilities"] or args[:2] == ["forge", "capabilities"]:
    print(json.dumps({"osName": "macOS", "isAppleSilicon": True, "args": args}))
    sys.exit(0)
if args[:1] == ["schema"]:
    print(json.dumps({"schema": args[1] if len(args) > 1 else "all"}))
    sys.exit(0)
if args[:2] == ["forge", "validate"]:
    raw = sys.stdin.read() if "-" in args else "{}"
    print(json.dumps({"valid": True, "stdinBytes": len(raw), "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "inspect"]:
    print(json.dumps({"path": args[2], "video": {"codec": "h264"}, "argv": args}))
    sys.exit(0)
if args[:3] == ["forge", "cache", "stats"]:
    print(json.dumps({"entries": 3, "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "run"]:
    sys.stderr.write(json.dumps({"event": "progress", "frame": 1, "totalFrames": 2, "stage": "encode"}) + "\\n")
    sys.stderr.flush()
    print(json.dumps({"ok": True, "argv": args}))
    sys.exit(0)
if args[:1] == ["html"]:
    sys.stderr.write(json.dumps({"event": "progress", "frame": 10, "totalFrames": 10, "stage": "done"}) + "\\n")
    sys.stderr.flush()
    print(json.dumps({"ok": True, "argv": args}))
    sys.exit(0)
if args[:1] == ["verify"]:
    if "diff" in args[-1]:
        print(json.dumps({"exactMatch": False, "diff": ["frame 0"]}))
        sys.exit(2)
    print(json.dumps({"exactMatch": True, "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "qa"]:
    if "fail-envelope" in args[2]:
        sys.stderr.write(json.dumps({
            "ok": False,
            "tool": "safarium-forge",
            "error": {"code": "E_UNSUPPORTED_CODEC", "message": "AV1 encode unsupported on macOS", "hint": "Use hevc or h264"}
        }) + "\\n")
        sys.exit(1)
    print(json.dumps({"ok": True, "argv": args}))
    sys.exit(0)
sys.stderr.write("unexpected args: " + repr(args) + "\\n")
sys.exit(2)
""",
        )

        _write_exec(
            self.bin_dir / "safarium",
            """#!/usr/bin/python3 -ISB
import json, sys
print(json.dumps({"present": True, "appleOnly": True, "abi": {"version": 1, "symbolCount": 371}, "argv": sys.argv[1:]}))
""",
        )

        # Sample local test fixtures
        self.html_file = self.tmp / "scene.html"
        self.html_file.write_text("<html><body>hi</body></html>", encoding="utf-8")
        self.recipe_file = self.tmp / "recipe.json"
        self.recipe_file.write_text('{"version":"safarium-forge/graph-v1"}', encoding="utf-8")
        self.media_file = self.tmp / "clip.mp4"
        self.media_file.write_bytes(b"fake-mp4")
        self.diff_file = self.tmp / "diff.mp4"
        self.diff_file.write_bytes(b"fake-diff-mp4")
        self.fail_file = self.tmp / "fail-envelope.mp4"
        self.fail_file.write_bytes(b"fake-fail-mp4")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def _rpc_session(self, messages):
        payload = "\n".join(m if isinstance(m, str) else json.dumps(m) for m in messages) + "\n"
        proc = subprocess.run(
            [str(self.mcp_bin)],
            input=payload.encode("utf-8"),
            capture_output=True,
            timeout=15,
            check=False,
        )
        self.assertEqual(proc.returncode, 0, f"stderr={proc.stderr.decode()}")
        lines = [ln for ln in proc.stdout.decode("utf-8").splitlines() if ln.strip()]
        return [json.loads(ln) for ln in lines]

    def test_initialize_version_negotiation_and_lifecycle(self):
        for req_ver, expected in (
            ("2024-11-05", "2024-11-05"),
            ("2025-03-26", "2025-03-26"),
            ("2025-06-18", "2025-06-18"),
            ("1999-01-01", "2025-03-26"),
        ):
            resps = self._rpc_session([
                {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": req_ver}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "ping"},
            ])
            self.assertEqual(len(resps), 2)
            self.assertEqual(resps[0]["result"]["protocolVersion"], expected)
            self.assertEqual(resps[0]["result"]["serverInfo"]["name"], "safarium-mcp")
            self.assertEqual(resps[1]["result"], {})

    def test_tools_resources_prompts_discovery(self):
        resps = self._rpc_session([
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26"}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
            {"jsonrpc": "2.0", "id": 3, "method": "resources/list"},
            {"jsonrpc": "2.0", "id": 4, "method": "resources/templates/list"},
            {"jsonrpc": "2.0", "id": 5, "method": "prompts/list"},
            {"jsonrpc": "2.0", "id": 6, "method": "prompts/get", "params": {"name": "preflight_check"}},
        ])
        tools = resps[1]["result"]["tools"]
        names = {t["name"] for t in tools}
        self.assertEqual(
            names,
            {
                "doctor",
                "status",
                "capabilities",
                "raster_info",
                "forge_schema",
                "forge_validate",
                "probe_media",
                "cache_stats",
                "forge_run",
                "html_render",
                "verify_media",
                "qa_inspect",
            },
        )
        self.assertGreaterEqual(len(resps[2]["result"]["resources"]), 5)
        self.assertEqual(resps[3]["result"]["resourceTemplates"], [])
        self.assertEqual(len(resps[4]["result"]["prompts"]), 3)
        self.assertIn("doctor", resps[5]["result"]["messages"][0]["content"]["text"])

    def test_readonly_and_queue_tools_and_progress_bridge(self):
        out_mp4 = str(self.tmp / "out.mp4")
        resps = self._rpc_session([
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "doctor", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "status", "arguments": {"detail": True}}},
            {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "capabilities", "arguments": {"fast": True}}},
            {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "raster_info", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "forge_schema", "arguments": {"target": "errors"}}},
            {
                "jsonrpc": "2.0",
                "id": 7,
                "method": "tools/call",
                "params": {"name": "forge_validate", "arguments": {"recipe": {"version": "safarium-forge/graph-v1"}}},
            },
            {"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "probe_media", "arguments": {"path": str(self.media_file)}}},
            {"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "cache_stats", "arguments": {"kind": "scene"}}},
            {
                "jsonrpc": "2.0",
                "id": 10,
                "method": "tools/call",
                "params": {
                    "name": "forge_run",
                    "arguments": {"recipe_path": str(self.recipe_file)},
                    "_meta": {"progressToken": "tok-forge"},
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 11,
                "method": "tools/call",
                "params": {
                    "name": "html_render",
                    "arguments": {
                        "input_html": str(self.html_file),
                        "output_path": out_mp4,
                        "width": 1080,
                        "height": 1920,
                        "fps": 30,
                        "frames": 10,
                        "video_only": True,
                    },
                    "_meta": {"progressToken": "tok-html"},
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 12,
                "method": "tools/call",
                "params": {
                    "name": "verify_media",
                    "arguments": {"reference_path": str(self.media_file), "candidate_path": str(self.diff_file)},
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 13,
                "method": "tools/call",
                "params": {"name": "qa_inspect", "arguments": {"input_path": str(self.fail_file)}},
            },
        ])

        by_id = {r["id"]: r for r in resps if "id" in r}
        notifs = [r for r in resps if "method" in r and r["method"] == "notifications/progress"]
        self.assertEqual(len(notifs), 2)
        self.assertEqual(notifs[0]["params"]["progressToken"], "tok-forge")
        self.assertEqual(notifs[1]["params"]["progressToken"], "tok-html")

        self.assertFalse(by_id[2]["result"]["isError"])
        self.assertTrue(by_id[2]["result"]["structuredContent"]["healthy"])
        self.assertEqual(by_id[5]["result"]["structuredContent"]["abi"]["symbolCount"], 371)
        self.assertTrue(by_id[7]["result"]["structuredContent"]["valid"])
        self.assertFalse(by_id[12]["result"]["isError"])
        self.assertFalse(by_id[12]["result"]["structuredContent"]["exactMatch"])

        # Structured worker error envelope is surfaced cleanly with isError=True
        self.assertTrue(by_id[13]["result"]["isError"])
        self.assertEqual(by_id[13]["result"]["structuredContent"]["error"]["code"], "E_UNSUPPORTED_CODEC")

    def test_error_codes_and_strict_validation(self):
        resps = self._rpc_session([
            "{broken-json",
            {"jsonrpc": "2.0", "id": 1, "method": "unknown/method"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "nonexistent", "arguments": {}}},
            {"jsonrpc": "2.0", "id": 3, "method": "resources/read", "params": {"uri": "safarium://does-not-exist"}},
            # Batch with initialize must be rejected
            [{"jsonrpc": "2.0", "id": 4, "method": "initialize", "params": {}}],
            # Invalid odd width + missing video_only/audio_path -> isError=True without spawning worker
            {
                "jsonrpc": "2.0",
                "id": 5,
                "method": "tools/call",
                "params": {
                    "name": "html_render",
                    "arguments": {
                        "input_html": str(self.html_file),
                        "output_path": str(self.tmp / "bad.mp4"),
                        "width": 1081,
                        "height": 1920,
                        "fps": 30,
                        "frames": 10,
                        "video_only": True,
                    },
                },
            },
            # AppleDouble rejection
            {
                "jsonrpc": "2.0",
                "id": 6,
                "method": "tools/call",
                "params": {"name": "probe_media", "arguments": {"path": str(self.tmp / "._clip.mp4")}},
            },
            # Overwrite refusal
            {
                "jsonrpc": "2.0",
                "id": 7,
                "method": "tools/call",
                "params": {
                    "name": "html_render",
                    "arguments": {
                        "input_html": str(self.html_file),
                        "output_path": str(self.media_file),
                        "width": 1080,
                        "height": 1920,
                        "fps": 30,
                        "frames": 10,
                        "video_only": True,
                    },
                },
            },
        ])
        self.assertEqual(resps[0]["error"]["code"], -32700)
        self.assertEqual(resps[1]["error"]["code"], -32601)
        self.assertEqual(resps[2]["error"]["code"], -32602)
        self.assertEqual(resps[3]["error"]["code"], -32002)
        self.assertEqual(resps[4][0]["error"]["code"], -32600)
        self.assertTrue(resps[5]["result"]["isError"])
        self.assertIn("even", resps[5]["result"]["content"][0]["text"])
        self.assertTrue(resps[6]["result"]["isError"])
        self.assertIn("AppleDouble", resps[6]["result"]["content"][0]["text"])
        self.assertTrue(resps[7]["result"]["isError"])
        self.assertIn("already exists", resps[7]["result"]["content"][0]["text"])


if __name__ == "__main__":
    unittest.main()
