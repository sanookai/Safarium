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
if args[:2] == ["forge", "analyze-shots"]:
    print(json.dumps({"shotCount": 3, "shots": [], "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "transcode"]:
    sys.stderr.write(json.dumps({"event": "progress", "frame": 15, "totalFrames": 30, "stage": "encode"}) + "\\n")
    sys.stderr.flush()
    print(json.dumps({"ok": True, "mode": "mini-cae", "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "scenarios"]:
    print(json.dumps({"count": 19, "scenarios": [], "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "hls"]:
    print(json.dumps({"masterPlaylistPath": "/tmp/master.m3u8", "variants": [], "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "clip"]:
    print(json.dumps({"format": "webp", "frameCount": 12, "argv": args}))
    sys.exit(0)
if args[:3] == ["forge", "audio", "encode"]:
    print(json.dumps({"ok": True, "codec": "alac", "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "probe-capabilities"]:
    print(json.dumps({"schemaVersion": 1, "codecs": [{"codecFourCC": "hvc1", "hardwareAccelerated": True}], "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "conformance"]:
    print(json.dumps({"passed": True, "containerKind": "isobmff", "violations": [], "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "spec-plan"]:
    print(json.dumps({"sidecarReused": False, "plan": {"codec": "hevc-10bit", "shots": 2, "expectedMbps": 4.2}, "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "spec-encode"]:
    print(json.dumps({"atomicPublished": True, "powerBudget": "balanced", "report": {"contractMet": True, "measuredMSSSIM": 0.996}, "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "spec-ladder"]:
    print(json.dumps({"plan": {"rungs": [{"name": "720p"}, {"name": "1080p"}], "analysisReused": True}, "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "auto-reframe"]:
    print(json.dumps({"outputWidth": 1080, "outputHeight": 1920, "textClippingAvoidedCount": 2, "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "auto-edit"]:
    print(json.dumps({"mode": "silence-cut", "segments": [{"startSeconds": 0.0, "endSeconds": 1.5}], "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "enhance"]:
    if "--probe-av1" in args:
        print(json.dumps({"av1HardwareEncodeSupported": False, "av1HardwareDecodeSupported": True, "argv": args}))
        sys.exit(0)
    print(json.dumps({"beforeCAMBI": 6.2, "afterCAMBI": 1.1, "usedMetalDeband": True, "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "ll-hls"]:
    print(json.dumps({"packaged": {"parts": [{"uri": "part_0000.m4s"}]}, "validation": {"passed": True}, "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "dash"]:
    print(json.dumps({"dash": {"manifestPath": "/tmp/manifest.mpd", "sharedWithHLS": True, "validation": {"passed": True}}, "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "timeline"]:
    print(json.dumps({"action": args[2], "timeline": {"name": "Demo", "tracks": []}, "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "qa-defects"]:
    print(json.dumps({"passed": True, "defectCount": 0, "defects": [], "argv": args}))
    sys.exit(0)
if args[:2] == ["forge", "repair-shot"]:
    print(json.dumps({"repairedShotCount": 1, "untouchedShotsPreservedBitExact": True, "conformancePassed": True, "argv": args}))
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
        self.fcpxml_file = self.tmp / "demo.fcpxml"
        self.fcpxml_file.write_text("<fcpxml version='1.11'></fcpxml>", encoding="utf-8")

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
            self.assertEqual(resps[0]["result"]["serverInfo"]["version"], "3.0.0")
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
                "analyze_shots",
                "transcode_supremacy",
                "list_scenarios",
                "package_hls",
                "export_animated_clip",
                "audio_encode",
                "verify_media",
                "qa_inspect",
                "encoding_capabilities",
                "encoding_conformance",
                "encoding_plan",
                "encoding_encode",
                "encoding_ladder",
                "ai_reframe_vertical",
                "ai_auto_edit",
                "ai_enhance_video",
                "stream_package_llhls_dash",
                "timeline_interop",
                "qa_detect_defects",
                "qa_surgical_repair",
            },
        )
        self.assertEqual(len(tools), 30)
        self.assertGreaterEqual(len(resps[2]["result"]["resources"]), 5)
        self.assertEqual(resps[3]["result"]["resourceTemplates"], [])
        self.assertEqual(len(resps[4]["result"]["prompts"]), 3)
        self.assertIn("doctor", resps[5]["result"]["messages"][0]["content"]["text"])

    def test_readonly_and_queue_tools_and_progress_bridge(self):
        out_mp4 = str(self.tmp / "out.mp4")
        out_sup = str(self.tmp / "out-sup.mp4")
        out_m4a = str(self.tmp / "out.m4a")
        out_hls = str(self.tmp / "hls-out")
        out_webp = str(self.tmp / "clip.webp")
        out_sc = str(self.tmp / "out-scenario.mp4")
        out_spec = str(self.tmp / "out-spec.mp4")
        out_spec_hls = str(self.tmp / "spec-hls-out")
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
                        "codec": "hevc-10bit",
                        "pixel_format": "p010",
                        "high_quality": True,
                        "hdr": "dv84",
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
            {
                "jsonrpc": "2.0",
                "id": 14,
                "method": "tools/call",
                "params": {"name": "analyze_shots", "arguments": {"input_path": str(self.media_file), "scene_threshold": 0.3}},
            },
            {
                "jsonrpc": "2.0",
                "id": 15,
                "method": "tools/call",
                "params": {
                    "name": "transcode_supremacy",
                    "arguments": {
                        "input_path": str(self.media_file),
                        "output_path": out_sup,
                        "codec": "hevc-10bit",
                        "mode": "mini-cae",
                        "engines": 2,
                        "denoise": True,
                        "audio_codec": "aac-max",
                    },
                    "_meta": {"progressToken": "tok-sup"},
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 16,
                "method": "tools/call",
                "params": {
                    "name": "audio_encode",
                    "arguments": {
                        "input_path": str(self.media_file),
                        "output_path": out_m4a,
                        "codec": "alac",
                        "sample_rate": 48000,
                    },
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 17,
                "method": "tools/call",
                "params": {"name": "list_scenarios", "arguments": {"scenario": "youtube-4k"}},
            },
            {
                "jsonrpc": "2.0",
                "id": 18,
                "method": "tools/call",
                "params": {
                    "name": "package_hls",
                    "arguments": {
                        "input_path": str(self.media_file),
                        "output_dir": out_hls,
                        "format": "fmp4",
                        "rungs": ["360p", "720p"],
                    },
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 19,
                "method": "tools/call",
                "params": {
                    "name": "export_animated_clip",
                    "arguments": {
                        "input_path": str(self.media_file),
                        "output_path": out_webp,
                        "format": "webp",
                        "fps": 12,
                        "max_width": 480,
                    },
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 20,
                "method": "tools/call",
                "params": {
                    "name": "transcode_supremacy",
                    "arguments": {
                        "input_path": str(self.media_file),
                        "output_path": out_sc,
                        "scenario": "youtube-4k",
                        "tonemap_sdr": True,
                    },
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 21,
                "method": "tools/call",
                "params": {"name": "encoding_capabilities", "arguments": {"refresh": True}},
            },
            {
                "jsonrpc": "2.0",
                "id": 22,
                "method": "tools/call",
                "params": {
                    "name": "encoding_conformance",
                    "arguments": {"path": str(self.media_file), "expected_codec": "hvc1", "expected_bit_depth": 10},
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 23,
                "method": "tools/call",
                "params": {
                    "name": "encoding_plan",
                    "arguments": {
                        "input_path": str(self.media_file),
                        "target_vmaf": 96.0,
                        "max_deltae_p95": 1.5,
                        "protect_text": True,
                        "codec": "hevc-10bit",
                    },
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 24,
                "method": "tools/call",
                "params": {
                    "name": "encoding_encode",
                    "arguments": {
                        "input_path": str(self.media_file),
                        "output_path": out_spec,
                        "target_ms_ssim": 0.995,
                        "max_proxy_iters": 2,
                        "power_budget": "balanced",
                    },
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 25,
                "method": "tools/call",
                "params": {
                    "name": "encoding_ladder",
                    "arguments": {
                        "input_path": str(self.media_file),
                        "output_dir": out_spec_hls,
                        "max_rungs": 3,
                        "format": "fmp4",
                    },
                },
            },
        ])

        by_id = {r["id"]: r for r in resps if "id" in r}
        notifs = [r for r in resps if "method" in r and r["method"] == "notifications/progress"]
        self.assertEqual(len(notifs), 3)
        self.assertEqual(notifs[0]["params"]["progressToken"], "tok-forge")
        self.assertEqual(notifs[1]["params"]["progressToken"], "tok-html")
        self.assertEqual(notifs[2]["params"]["progressToken"], "tok-sup")

        self.assertFalse(by_id[2]["result"]["isError"])
        self.assertTrue(by_id[2]["result"]["structuredContent"]["healthy"])
        self.assertEqual(by_id[5]["result"]["structuredContent"]["abi"]["symbolCount"], 371)
        self.assertTrue(by_id[7]["result"]["structuredContent"]["valid"])
        self.assertFalse(by_id[12]["result"]["isError"])
        self.assertFalse(by_id[12]["result"]["structuredContent"]["exactMatch"])

        # Structured worker error envelope is surfaced cleanly with isError=True
        self.assertTrue(by_id[13]["result"]["isError"])
        self.assertEqual(by_id[13]["result"]["structuredContent"]["error"]["code"], "E_UNSUPPORTED_CODEC")

        # Wave 9 Supremacy MCP tools
        self.assertFalse(by_id[14]["result"]["isError"])
        self.assertEqual(by_id[14]["result"]["structuredContent"]["shotCount"], 3)
        self.assertFalse(by_id[15]["result"]["isError"])
        self.assertIn("--engines", by_id[15]["result"]["structuredContent"]["argv"])
        self.assertIn("--denoise", by_id[15]["result"]["structuredContent"]["argv"])
        # Wave 10 Scenarios / HLS / Animated Clip MCP tools
        self.assertFalse(by_id[17]["result"]["isError"])
        self.assertEqual(by_id[17]["result"]["structuredContent"]["count"], 19)
        self.assertIn("--scenario", by_id[17]["result"]["structuredContent"]["argv"])
        self.assertFalse(by_id[18]["result"]["isError"])
        self.assertIn("--rungs", by_id[18]["result"]["structuredContent"]["argv"])
        self.assertIn("360p,720p", by_id[18]["result"]["structuredContent"]["argv"])
        self.assertFalse(by_id[19]["result"]["isError"])
        self.assertIn("--max-width", by_id[19]["result"]["structuredContent"]["argv"])
        self.assertFalse(by_id[20]["result"]["isError"])
        self.assertIn("--scenario", by_id[20]["result"]["structuredContent"]["argv"])
        self.assertIn("youtube-4k", by_id[20]["result"]["structuredContent"]["argv"])
        self.assertIn("--tonemap-sdr", by_id[20]["result"]["structuredContent"]["argv"])
        self.assertFalse(by_id[16]["result"]["isError"])
        self.assertIn("alac", by_id[16]["result"]["structuredContent"]["argv"])
        # Wave 11-14 Intent-Level MCP v2 tools
        self.assertFalse(by_id[21]["result"]["isError"])
        self.assertIn("--refresh", by_id[21]["result"]["structuredContent"]["argv"])
        self.assertFalse(by_id[22]["result"]["isError"])
        self.assertTrue(by_id[22]["result"]["structuredContent"]["passed"])
        self.assertIn("--expected-codec", by_id[22]["result"]["structuredContent"]["argv"])
        self.assertFalse(by_id[23]["result"]["isError"])
        self.assertIn("--target-vmaf", by_id[23]["result"]["structuredContent"]["argv"])
        self.assertFalse(by_id[24]["result"]["isError"])
        self.assertTrue(by_id[24]["result"]["structuredContent"]["atomicPublished"])
        self.assertIn("--power-budget", by_id[24]["result"]["structuredContent"]["argv"])
        self.assertFalse(by_id[25]["result"]["isError"])
        self.assertTrue(by_id[25]["result"]["structuredContent"]["plan"]["analysisReused"])
        self.assertIn("--max-rungs", by_id[25]["result"]["structuredContent"]["argv"])

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

    def test_wave15_18_mcp_v3_tools(self):
        out_reframe = str(self.tmp / "reframed.mp4")
        out_enh = str(self.tmp / "enhanced.mp4")
        out_llhls = str(self.tmp / "llhls-out")
        out_dash = str(self.tmp / "dash-out")
        out_otio = str(self.tmp / "out.otio")
        out_repaired = str(self.tmp / "repaired.mp4")
        resps = self._rpc_session([
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18"}},
            {
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/call",
                "params": {"name": "encoding_plan", "arguments": {"input_path": str(self.media_file), "max_cambi": 4.5}},
            },
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {
                    "name": "ai_reframe_vertical",
                    "arguments": {"input_path": str(self.media_file), "output_path": out_reframe, "aspect": "9:16", "protect_thai_text": True},
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 4,
                "method": "tools/call",
                "params": {
                    "name": "ai_auto_edit",
                    "arguments": {"input_path": str(self.media_file), "mode": "silence-cut", "plan_only": True},
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 5,
                "method": "tools/call",
                "params": {"name": "ai_enhance_video", "arguments": {"probe_av1": True}},
            },
            {
                "jsonrpc": "2.0",
                "id": 6,
                "method": "tools/call",
                "params": {
                    "name": "ai_enhance_video",
                    "arguments": {"input_path": str(self.media_file), "output_path": out_enh, "deband": True, "upscale_width": 1920, "upscale_height": 1080},
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 7,
                "method": "tools/call",
                "params": {
                    "name": "stream_package_llhls_dash",
                    "arguments": {"input_path": str(self.media_file), "output_dir": out_llhls, "mode": "ll-hls", "part_sec": 0.34},
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 8,
                "method": "tools/call",
                "params": {
                    "name": "stream_package_llhls_dash",
                    "arguments": {"input_path": str(self.media_file), "output_dir": out_dash, "mode": "dual-dash", "rungs": "360p,720p"},
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 9,
                "method": "tools/call",
                "params": {
                    "name": "timeline_interop",
                    "arguments": {"action": "fcpxml-to-otio", "input_path": str(self.fcpxml_file), "output_path": out_otio},
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 10,
                "method": "tools/call",
                "params": {
                    "name": "qa_detect_defects",
                    "arguments": {"input_path": str(self.media_file), "max_cambi": 6.0, "standard": "ebu-r128"},
                },
            },
            {
                "jsonrpc": "2.0",
                "id": 11,
                "method": "tools/call",
                "params": {
                    "name": "qa_surgical_repair",
                    "arguments": {
                        "original_path": str(self.media_file),
                        "output_path": out_repaired,
                        "patches": [{"shot_index": 1, "start_sec": 1.0, "end_sec": 2.0, "replacement_path": str(self.diff_file)}],
                    },
                },
            },
        ])
        by_id = {r["id"]: r for r in resps if "id" in r}
        self.assertFalse(by_id[2]["result"]["isError"])
        self.assertIn("--max-cambi", by_id[2]["result"]["structuredContent"]["argv"])
        self.assertFalse(by_id[3]["result"]["isError"])
        self.assertEqual(by_id[3]["result"]["structuredContent"]["textClippingAvoidedCount"], 2)
        self.assertFalse(by_id[4]["result"]["isError"])
        self.assertIn("--plan-only", by_id[4]["result"]["structuredContent"]["argv"])
        self.assertFalse(by_id[5]["result"]["isError"])
        self.assertFalse(by_id[5]["result"]["structuredContent"]["av1HardwareEncodeSupported"])
        self.assertFalse(by_id[6]["result"]["isError"])
        self.assertTrue(by_id[6]["result"]["structuredContent"]["usedMetalDeband"])
        self.assertFalse(by_id[7]["result"]["isError"])
        self.assertTrue(by_id[7]["result"]["structuredContent"]["validation"]["passed"])
        self.assertFalse(by_id[8]["result"]["isError"])
        self.assertTrue(by_id[8]["result"]["structuredContent"]["dash"]["sharedWithHLS"])
        self.assertFalse(by_id[9]["result"]["isError"])
        self.assertEqual(by_id[9]["result"]["structuredContent"]["action"], "fcpxml-to-otio")
        self.assertFalse(by_id[10]["result"]["isError"])
        self.assertTrue(by_id[10]["result"]["structuredContent"]["passed"])
        self.assertFalse(by_id[11]["result"]["isError"])
        self.assertTrue(by_id[11]["result"]["structuredContent"]["untouchedShotsPreservedBitExact"])


if __name__ == "__main__":
    unittest.main()
