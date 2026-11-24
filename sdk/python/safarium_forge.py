#!/usr/bin/env python3
"""Zero-dependency Python SDK for `safarium-forge` routed strictly through `safarium-render forge` (SF-VIDEO-1)."""

from __future__ import annotations

import array
import contextlib
import json
import mmap
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple, Union

__all__ = [
    "SafariumForgeError",
    "ForgePipeline",
    "PipeEncodeSession",
    "ForgeRingSession",
    "ForgeWarmSession",
    "SafariumForge",
    "default_render_bin",
    "unwrap_esds_bytes",
    "html_overlay_recipe",
    "run_recipe",
    "validate_recipe",
    "remux",
    "inspect",
    "image",
    "audio_process",
    "crossfade",
    "silence_trim",
    "waveform",
    "synth",
    "split_mp3",
    "sheet",
    "compare",
    "pq",
    "qa",
    "reframe",
    "matte",
    "pipe_encode",
    "open_pipe_encode",
    "open_ring_encode",
    "open_warm_session",
    "cache_hash",
    "cache_store",
    "cache_lookup",
    "cache_stats",
    "cache_prune",
    "ab_gallery",
    "capabilities",
    "extract_frame_sheet",
    "prism_capabilities",
    "prism_sync_ir",
    "prism_preview_stills",
    "prism_render_web",
    "prism_render_blender",
    "prism_composite",
]


class SafariumForgeError(RuntimeError):
    """Raised when `safarium-render forge` exits non-zero or returns malformed output."""

    def __init__(self, message: str, returncode: int = 1, command: Optional[Sequence[str]] = None, stderr: str = "", stdout: str = ""):
        super().__init__(message)
        self.returncode = returncode
        self.command = list(command) if command else []
        self.stderr = stderr
        self.stdout = stdout


def default_render_bin() -> Path:
    """Returns the queue entrypoint honoring `SAFARIUM_RENDER_BIN`."""
    override = os.environ.get("SAFARIUM_RENDER_BIN", "").strip()
    if override:
        return Path(override)
    return Path.home() / ".local" / "bin" / "safarium-render"


def _read_expandable_length(data: bytes, idx: int) -> tuple[Optional[int], int]:
    val = 0
    for _ in range(4):
        if idx >= len(data):
            return None, idx
        b = data[idx]
        idx += 1
        val = (val << 7) | (b & 0x7F)
        if (b & 0x80) == 0:
            return val, idx
    return val, idx


def unwrap_esds_bytes(esds: bytes) -> Dict[str, Any]:
    """Recursively unwraps Safari Bug 302253 39B/76B ES_Descriptor (03->04->05) into raw AudioSpecificConfig."""
    if not esds:
        raise ValueError("ESDS payload is empty")
    cur = esds[4:] if len(esds) > 5 and esds[:4] == b"\x00\x00\x00\x00" and esds[4] == 0x03 else esds
    layers = 0
    first_len = 0
    while cur and cur[0] == 0x03:
        if layers == 0:
            first_len = len(cur)
        idx = 1
        es_len, idx = _read_expandable_length(cur, idx)
        if es_len is None or idx + 3 > len(cur):
            raise ValueError("malformed ES_Descriptor 0x03 header")
        es_end = min(len(cur), idx + es_len)
        flags = cur[idx + 2]
        idx += 3
        if flags & 0x80:
            idx += 2
        if flags & 0x40:
            if idx >= es_end:
                raise ValueError("truncated ES_Descriptor URL")
            idx += 1 + cur[idx]
        if flags & 0x20:
            idx += 2
        if idx >= es_end or cur[idx] != 0x04:
            raise ValueError("missing DecoderConfigDescriptor 0x04")
        idx += 1
        dc_len, idx = _read_expandable_length(cur, idx)
        if dc_len is None or idx + 13 > es_end:
            raise ValueError("malformed DecoderConfigDescriptor 0x04")
        dc_end = min(es_end, idx + dc_len)
        idx += 13
        if idx >= dc_end or cur[idx] != 0x05:
            raise ValueError("missing DecoderSpecificInfo 0x05")
        idx += 1
        dsi_len, idx = _read_expandable_length(cur, idx)
        if dsi_len is None or idx + dsi_len > dc_end:
            raise ValueError("truncated DecoderSpecificInfo 0x05")
        cur = cur[idx : idx + dsi_len]
        layers += 1
    return {
        "was_wrapped": layers > 0,
        "was_bug_302253": layers >= 2 or (layers == 1 and first_len == 39),
        "layers_unwrapped": layers,
        "audio_specific_config_hex": cur.hex(),
        "audio_specific_config": cur,
    }


def html_overlay_recipe(
    html_path: Union[str, Path],
    output_path: Union[str, Path],
    width: int,
    height: int,
    fps: int = 30,
    frames: Optional[int] = None,
    duration_seconds: Optional[float] = None,
    background_video: Optional[Union[str, Path]] = None,
    audio_path: Optional[Union[str, Path]] = None,
    subtitles_path: Optional[Union[str, Path]] = None,
    lang: str = "tha",
    codec: str = "h264",
    mode_c_dirty_hold: bool = True,
    overwrite: bool = False,
) -> "ForgePipeline":
    """Builds a declarative zero-copy recipe replacing HyperFrames/Puppeteer/Remotion headless Chrome."""
    pipe = ForgePipeline().set_timeline(
        width=width,
        height=height,
        fps=fps,
        frame_count=frames,
        duration_seconds=duration_seconds,
    )
    pipe.add_html_overlay("html", str(html_path), width=width, height=height, mode_c_dirty_hold=mode_c_dirty_hold)
    if background_video:
        pipe.add_video("bg", str(background_video))
        pipe.overlay("comp", base="bg", over="html", x="0", y="0", opacity="1.0")
        video_out = "comp"
    else:
        video_out = "html"

    audio_out = None
    if audio_path:
        pipe.add_audio("aud", str(audio_path))
        pipe.loudnorm("master_a", input_id="aud", target_lufs=-16.0, peak_ceiling_dbtp=-1.05)
        audio_out = "master_a"

    sub_spec = None
    if subtitles_path:
        pipe.add_subtitles("subs", str(subtitles_path), lang=lang)
        sub_spec = {"in": "subs", "format": "tx3g", "lang": lang}

    pipe.set_output(
        str(output_path),
        video_codec=codec,
        pixel_format="bgra" if codec in ("hevc-alpha", "prores4444") else "420v",
        video_out_node=video_out,
        audio_out_node=audio_out,
        subtitles=sub_spec,
        overwrite=overwrite,
    )
    return pipe


class ForgePipeline:
    """Fluent builder for `safarium-forge/graph-v1` declarative DAG recipes."""

    def __init__(self, schema: str = "safarium-forge/graph-v1"):
        self._recipe: Dict[str, Any] = {
            "$schema": schema,
            "inputs": [],
            "timeline": {"fps": 30, "width": 1080, "height": 1920},
            "videoOps": [],
            "audioOps": [],
            "output": {"path": ""},
        }

    def set_job(
        self,
        *,
        apfs_auto_stage: bool = True,
        cache_dir: Optional[str] = None,
        target_peak_ram_mib: float = 220.0,
        ring_slots: int = 4,
        wk_recycle_every_frames: int = 200,
    ) -> "ForgePipeline":
        self._recipe["job"] = {
            "stagePolicy": {
                "apfsAutoStage": apfs_auto_stage,
                **({"cacheDir": cache_dir} if cache_dir else {}),
                "allowClonefileCoW": True,
            },
            "governor": {
                "targetPeakRAMMiB": target_peak_ram_mib,
                "ringSlots": ring_slots,
                "wkRecycleEveryFrames": wk_recycle_every_frames,
                "thermalThrottlePolicy": "paceWithoutQualityLoss",
            },
        }
        return self

    def set_timeline(
        self,
        width: int,
        height: int,
        fps: int = 30,
        duration_seconds: Optional[float] = None,
        frame_count: Optional[int] = None,
    ) -> "ForgePipeline":
        tl: Dict[str, Any] = {"fps": fps, "width": width, "height": height}
        if duration_seconds is not None:
            tl["durationSeconds"] = duration_seconds
        if frame_count is not None:
            tl["frameCount"] = frame_count
        self._recipe["timeline"] = tl
        return self

    def add_input(self, spec: Dict[str, Any]) -> "ForgePipeline":
        self._recipe["inputs"].append(spec)
        return self

    def add_video(
        self,
        input_id: str,
        path: Union[str, Path],
        *,
        demux: Optional[str] = None,
        trim: Optional[List[float]] = None,
        loop: Optional[bool] = None,
    ) -> "ForgePipeline":
        item: Dict[str, Any] = {"id": input_id, "kind": "video", "path": str(path)}
        if demux is not None:
            item["demux"] = demux
        if trim is not None:
            item["trim"] = trim
        if loop is not None:
            item["loop"] = loop
        return self.add_input(item)

    def add_audio(self, input_id: str, path: Union[str, Path], *, trim: Optional[List[float]] = None, loop: Optional[bool] = None) -> "ForgePipeline":
        item: Dict[str, Any] = {"id": input_id, "kind": "audio", "path": str(path)}
        if trim is not None:
            item["trim"] = trim
        if loop is not None:
            item["loop"] = loop
        return self.add_input(item)

    def add_image(self, input_id: str, path: Union[str, Path]) -> "ForgePipeline":
        return self.add_input({"id": input_id, "kind": "image", "path": str(path)})

    def add_lut3d(self, input_id: str, path: Union[str, Path]) -> "ForgePipeline":
        return self.add_input({"id": input_id, "kind": "lut3d", "path": str(path)})

    def add_subtitles(self, input_id: str, path: Union[str, Path], lang: str = "tha") -> "ForgePipeline":
        return self.add_input({"id": input_id, "kind": "subtitles", "path": str(path), "lang": lang})

    def add_html_overlay(
        self,
        input_id: str,
        path: Union[str, Path],
        width: Optional[int] = None,
        height: Optional[int] = None,
        *,
        mode_c_dirty_hold: bool = True,
    ) -> "ForgePipeline":
        item: Dict[str, Any] = {"id": input_id, "kind": "htmlOverlay", "path": str(path), "modeCDirtyHold": mode_c_dirty_hold}
        if width is not None:
            item["width"] = width
        if height is not None:
            item["height"] = height
        return self.add_input(item)

    def add_raw_pipe(self, input_id: str, width: int, height: int, fps: int = 30, pixel_format: str = "bgra") -> "ForgePipeline":
        return self.add_input({"id": input_id, "kind": "rawPipe", "width": width, "height": height, "fps": fps, "pixelFormat": pixel_format})

    def add_synth_audio(
        self,
        input_id: str,
        waveform: str = "sine",
        *,
        duration_seconds: float = 1.0,
        frequency_hz: Optional[float] = 440.0,
        end_frequency_hz: Optional[float] = None,
        carrier_frequencies_hz: Optional[List[float]] = None,
        modulation_hz: Optional[float] = None,
        modulation_depth: Optional[float] = None,
        amplitude: float = 0.25,
        sample_rate: int = 48_000,
        channels: int = 2,
        fade_in_seconds: Optional[float] = None,
        fade_out_seconds: Optional[float] = None,
    ) -> "ForgePipeline":
        synth_spec: Dict[str, Any] = {
            "waveform": waveform,
            "durationSeconds": duration_seconds,
            "amplitude": amplitude,
            "sampleRate": sample_rate,
            "channels": channels,
        }
        if frequency_hz is not None:
            synth_spec["frequencyHz"] = frequency_hz
        if end_frequency_hz is not None:
            synth_spec["endFrequencyHz"] = end_frequency_hz
        if carrier_frequencies_hz is not None:
            synth_spec["carrierFrequenciesHz"] = carrier_frequencies_hz
        if modulation_hz is not None:
            synth_spec["modulationHz"] = modulation_hz
        if modulation_depth is not None:
            synth_spec["modulationDepth"] = modulation_depth
        if fade_in_seconds is not None:
            synth_spec["fadeInSeconds"] = fade_in_seconds
        if fade_out_seconds is not None:
            synth_spec["fadeOutSeconds"] = fade_out_seconds
        return self.add_input({"id": input_id, "kind": "synthAudio", "synth": synth_spec})

    def add_video_op(self, op: Dict[str, Any]) -> "ForgePipeline":
        self._recipe["videoOps"].append(op)
        return self

    def geom(self, op_id: str, input_id: str, **kwargs: Any) -> "ForgePipeline":
        return self.add_video_op({"id": op_id, "op": "geom", "in": input_id, **kwargs})

    def deinterlace(self, op_id: str, input_id: str, field_order: str = "tff", motion_threshold: float = 0.08) -> "ForgePipeline":
        return self.add_video_op({"id": op_id, "op": "deinterlace", "in": input_id, "fieldOrder": field_order, "motionThreshold": motion_threshold})

    def color_grade(self, op_id: str, input_id: str, **kwargs: Any) -> "ForgePipeline":
        return self.add_video_op({"id": op_id, "op": "colorGrade", "in": input_id, **kwargs})

    def lut3d(self, op_id: str, input_id: str, lut_id: str, intensity: float = 1.0) -> "ForgePipeline":
        return self.add_video_op({"id": op_id, "op": "lut3d", "in": input_id, "lut": lut_id, "intensity": intensity})

    def overlay(self, op_id: str, base: str, over: str, x: str = "0", y: str = "0", opacity: str = "1.0", **kwargs: Any) -> "ForgePipeline":
        return self.add_video_op({"id": op_id, "op": "overlay", "base": base, "over": over, "x": x, "y": y, "opacity": opacity, **kwargs})

    def split_metalfx(self, op_id: str, low_res_in: str, overlay_1x_in: str) -> "ForgePipeline":
        return self.add_video_op({"id": op_id, "op": "splitMetalFX", "lowResIn": low_res_in, "overlay1xIn": overlay_1x_in})

    def auto_reframe(self, op_id: str, input_id: str, aspect: str = "9:16", **kwargs: Any) -> "ForgePipeline":
        return self.add_video_op({"id": op_id, "op": "autoReframe", "in": input_id, "aspect": aspect, **kwargs})

    def person_matte(self, op_id: str, input_id: str, mode: str = "personBalanced", **kwargs: Any) -> "ForgePipeline":
        return self.add_video_op({"id": op_id, "op": "personMatte", "in": input_id, "mode": mode, **kwargs})

    def add_audio_op(self, op: Dict[str, Any]) -> "ForgePipeline":
        self._recipe["audioOps"].append(op)
        return self

    def biquad_eq(self, op_id: str, input_id: str, eq_mode: str = "highpass", freq_hz: float = 80.0, q: float = 0.7071, gain_db: float = 0.0) -> "ForgePipeline":
        return self.add_audio_op({"id": op_id, "op": "biquadEQ", "in": input_id, "eqMode": eq_mode, "freqHz": freq_hz, "q": q, "gainDB": gain_db})

    def loudnorm(self, op_id: str, input_id: str, target_lufs: float = -16.0, peak_ceiling_dbtp: float = -1.05) -> "ForgePipeline":
        return self.add_audio_op({"id": op_id, "op": "loudnorm", "in": input_id, "targetLUFS": target_lufs, "peakCeilingDBTP": peak_ceiling_dbtp})

    def sidechain_duck(self, op_id: str, carrier: str, sidechain: str, threshold_db: float = -26.0, duck_db: float = -10.0) -> "ForgePipeline":
        return self.add_audio_op({"id": op_id, "op": "sidechainDuck", "carrier": carrier, "sidechain": sidechain, "thresholdDB": threshold_db, "duckDB": duck_db})

    def mix(self, op_id: str, tracks: List[str], gains_db: Optional[List[float]] = None, normalize_lufs: Optional[float] = None, peak_ceiling_dbtp: float = -1.05) -> "ForgePipeline":
        item: Dict[str, Any] = {"id": op_id, "op": "mix", "tracks": tracks, "peakCeilingDBTP": peak_ceiling_dbtp}
        if gains_db is not None:
            item["gainsDB"] = gains_db
        if normalize_lufs is not None:
            item["normalizeLUFS"] = normalize_lufs
        return self.add_audio_op(item)

    def set_qa(
        self,
        *,
        safarium_pq_min: Optional[float] = 85.0,
        max_delta_e00_p95: Optional[float] = 2.0,
        min_ms_ssim: Optional[float] = None,
        reference_video_path: Optional[Union[str, Path]] = None,
        thai_ocr_langs: Optional[List[str]] = None,
        expected_thai_text: Optional[str] = None,
        fault_checks: Optional[List[str]] = None,
        fail_on_qa: bool = True,
    ) -> "ForgePipeline":
        qa: Dict[str, Any] = {"failOnQA": fail_on_qa}
        if safarium_pq_min is not None:
            qa["safariumPQMin"] = safarium_pq_min
        if max_delta_e00_p95 is not None:
            qa["maxDeltaE00P95"] = max_delta_e00_p95
        if min_ms_ssim is not None:
            qa["minMSSSIM"] = min_ms_ssim
        if reference_video_path is not None:
            qa["referenceVideoPath"] = str(reference_video_path)
        if thai_ocr_langs is not None:
            qa["thaiOCRLangs"] = thai_ocr_langs
        if expected_thai_text is not None:
            qa["expectedThaiText"] = expected_thai_text
        if fault_checks is not None:
            qa["faultChecks"] = fault_checks
        self._recipe["qaOps"] = qa
        return self

    def set_output(
        self,
        path: Union[str, Path],
        *,
        video_codec: str = "h264",
        pixel_format: str = "420v",
        container: Optional[str] = None,
        bitrate: Optional[int] = None,
        quality: Optional[float] = None,
        closed_gop: Optional[bool] = True,
        secondary_path: Optional[Union[str, Path]] = None,
        secondary_codec: Optional[str] = None,
        secondary_bg_hex: Optional[str] = None,
        video_out_node: Optional[str] = None,
        audio_out_node: Optional[str] = None,
        subtitles: Optional[Dict[str, Any]] = None,
        fragment_interval_seconds: Optional[float] = None,
        overwrite: bool = False,
    ) -> "ForgePipeline":
        out: Dict[str, Any] = {
            "path": str(path),
            "videoCodec": video_codec,
            "pixelFormat": pixel_format,
            "colorimetry": "bt709_left_1_1_1",
            "overwrite": overwrite,
        }
        if container is not None:
            out["container"] = container
        if bitrate is not None:
            out["bitrate"] = bitrate
        if quality is not None:
            out["quality"] = quality
        if closed_gop is not None:
            out["closedGOP"] = closed_gop
        if secondary_path is not None:
            out["secondaryPath"] = str(secondary_path)
        if secondary_codec is not None:
            out["secondaryCodec"] = secondary_codec
        if secondary_bg_hex is not None:
            out["secondaryBackgroundHex"] = secondary_bg_hex
        if video_out_node is not None:
            out["videoOutNode"] = video_out_node
        if audio_out_node is not None:
            out["audioOutNode"] = audio_out_node
        if subtitles is not None:
            out["subtitles"] = subtitles
        if fragment_interval_seconds is not None:
            out["fragmentIntervalSeconds"] = fragment_interval_seconds
        self._recipe["output"] = out
        return self

    def to_dict(self) -> Dict[str, Any]:
        return json.loads(json.dumps(self._recipe))

    def to_json(self, indent: int = 2) -> str:
        return json.dumps(self._recipe, indent=indent, ensure_ascii=False)

    def validate(self, client: Optional["SafariumForge"] = None) -> Dict[str, Any]:
        return (client or SafariumForge()).validate_recipe(self)

    def run(self, client: Optional["SafariumForge"] = None, *, stdin_bytes: Optional[bytes] = None) -> Dict[str, Any]:
        return (client or SafariumForge()).run_recipe(self, stdin_bytes=stdin_bytes)


class PipeEncodeSession:
    """Streaming frame writer pushing raw frames incrementally through `safarium-render forge pipe-encode`."""

    def __init__(self, command: List[str], width: int, height: int, bytes_per_pixel: int):
        self.command = command
        self.expected_frame_bytes = width * height * bytes_per_pixel
        self._proc = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self._finished = False
        self.report: Optional[Dict[str, Any]] = None

    def write_frame(self, frame_bytes: bytes) -> None:
        if self._finished:
            raise SafariumForgeError("cannot write frame to finished PipeEncodeSession", command=self.command)
        if len(frame_bytes) != self.expected_frame_bytes:
            raise ValueError(f"expected {self.expected_frame_bytes} raw bytes per frame, got {len(frame_bytes)}")
        assert self._proc.stdin is not None
        self._proc.stdin.write(frame_bytes)

    def finish(self) -> Dict[str, Any]:
        if self._finished:
            assert self.report is not None
            return self.report
        self._finished = True
        if self._proc.stdin is not None:
            self._proc.stdin.close()
            self._proc.stdin = None
        out_b, err_b = self._proc.communicate()
        out_s = out_b.decode("utf-8", errors="replace")
        err_s = err_b.decode("utf-8", errors="replace")
        if self._proc.returncode != 0:
            raise SafariumForgeError(
                f"safarium-render forge pipe-encode failed ({self._proc.returncode}): {err_s.strip()}",
                returncode=self._proc.returncode,
                command=self.command,
                stderr=err_s,
                stdout=out_s,
            )
        self.report = json.loads(out_s)
        return self.report

    def __enter__(self) -> "PipeEncodeSession":
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        if exc_type is not None:
            if not self._finished:
                self._finished = True
                with contextlib.suppress(OSError):
                    if self._proc.stdin:
                        self._proc.stdin.close()
                with contextlib.suppress(OSError):
                    self._proc.terminate()
                with contextlib.suppress(Exception):
                    self._proc.wait(timeout=5)
        elif not self._finished:
            self.finish()


def _make_private_apfs_runtime_dir(prefix: str) -> str:
    base = "/tmp" if os.path.isdir("/tmp") else tempfile.gettempdir()
    d = tempfile.mkdtemp(prefix=prefix, dir=base)
    os.chmod(d, 0o700)
    return d


def _read_json_line_sock(sock: socket.socket, rx_buf: bytearray) -> Dict[str, Any]:
    while True:
        nl = rx_buf.find(b"\n")
        if nl >= 0:
            line = bytes(rx_buf[:nl]).decode("utf-8", errors="replace").strip()
            del rx_buf[: nl + 1]
            if not line:
                continue
            return json.loads(line)
        chunk = sock.recv(65536)
        if not chunk:
            raise SafariumForgeError("unexpected EOF from safarium-forge UDS server")
        rx_buf.extend(chunk)


class ForgeRingSession:
    """Zero-copy shared-memory mmap ring session over UDS (`SCM_RIGHTS` unlinked FD)."""

    def __init__(
        self,
        *,
        render_bin: Union[str, Path],
        output_path: Union[str, Path],
        width: int,
        height: int,
        fps: int = 30,
        slots: int = 4,
        pix_fmt: str = "bgra",
        vflip: bool = False,
        codec: str = "h264",
        bitrate: int = 8_000_000,
        quality: Optional[float] = None,
        secondary: Optional[Union[str, Path]] = None,
        secondary_codec: Optional[str] = None,
        secondary_bg: str = "#000000",
        audio: Optional[Union[str, Path]] = None,
        subtitles: Optional[Union[str, Path]] = None,
        lang: str = "tha",
        closed_gop: bool = True,
        overwrite: bool = False,
        daemon_conn: Optional[Tuple[socket.socket, bytearray]] = None,
    ):
        bpp = 3 if pix_fmt in ("rgb24", "bgr24") else 4
        self.width = width
        self.height = height
        self.slots = slots
        self.slot_bytes = width * height * bpp
        self.total_bytes = self.slots * self.slot_bytes
        self._daemon_conn = daemon_conn
        self._runtime_dir: Optional[str] = None
        self._proc: Optional[subprocess.Popen[bytes]] = None
        self._sock: Optional[socket.socket] = None
        self._rx_buf = bytearray() if daemon_conn is None else daemon_conn[1]
        self._frame_idx = 0
        self._finished = False
        self.report: Optional[Dict[str, Any]] = None

        self._ring_file = tempfile.TemporaryFile(dir="/tmp" if os.path.isdir("/tmp") else None)
        os.ftruncate(self._ring_file.fileno(), self.total_bytes)
        self._mm = mmap.mmap(self._ring_file.fileno(), self.total_bytes, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE)

        spec: Dict[str, Any] = {
            "width": width,
            "height": height,
            "fps": fps,
            "slots": slots,
            "pixFmt": pix_fmt,
            "vflip": vflip,
            "codec": codec,
            "bitrate": bitrate,
            "outputPath": str(output_path),
            "secondaryBg": secondary_bg,
            "subtitleLang": lang,
            "closedGOP": closed_gop,
            "overwrite": overwrite,
        }
        if quality is not None:
            spec["quality"] = quality
        if secondary is not None:
            spec["secondaryPath"] = str(secondary)
        if secondary_codec is not None:
            spec["secondaryCodec"] = secondary_codec
        if audio is not None:
            spec["audioPath"] = str(audio)
        if subtitles is not None:
            spec["subtitlesPath"] = str(subtitles)

        try:
            if daemon_conn is not None:
                self._sock = daemon_conn[0]
                payload = json.dumps({"cmd": "ring_start", "spec": spec}).encode("utf-8") + b"\n"
                self._sock.sendmsg([payload], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [self._ring_file.fileno()]))])
                ack = _read_json_line_sock(self._sock, self._rx_buf)
            else:
                self._runtime_dir = _make_private_apfs_runtime_dir("sfring-")
                sock_path = os.path.join(self._runtime_dir, "ring.sock")
                self._proc = subprocess.Popen(
                    [str(render_bin), "forge", "ring-encode", "--socket", sock_path],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                ready = False
                assert self._proc.stderr is not None
                while True:
                    line_b = self._proc.stderr.readline()
                    if not line_b:
                        break
                    line_s = line_b.decode("utf-8", errors="replace").strip()
                    if line_s.startswith("RING_READY "):
                        ready = True
                        break
                if not ready:
                    err_rest = self._proc.stderr.read().decode("utf-8", errors="replace")
                    rc = self._proc.wait()
                    if rc == 64 and "nested render refused" in err_rest:
                        raise SafariumForgeError("SF-VIDEO-1 nested slot refusal (returncode 64)", returncode=rc, stderr=err_rest)
                    raise SafariumForgeError(f"ring-encode failed to become ready ({rc}): {err_rest}", returncode=rc, stderr=err_rest)
                self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self._sock.connect(sock_path)
                payload = b"RING_START " + json.dumps(spec).encode("utf-8") + b"\n"
                self._sock.sendmsg([payload], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [self._ring_file.fileno()]))])
                ack = _read_json_line_sock(self._sock, self._rx_buf)

            if not ack.get("ok"):
                raise SafariumForgeError(f"RING_START failed: {ack.get('error', ack)}")
        except Exception:
            self.close()
            raise

    def write_frame(self, frame_bytes: Union[bytes, bytearray, memoryview], slot: Optional[int] = None) -> int:
        if self._finished:
            raise SafariumForgeError("cannot write frame to finished ForgeRingSession")
        mv = memoryview(frame_bytes)
        if len(mv) != self.slot_bytes:
            raise ValueError(f"expected {self.slot_bytes} bytes per frame, got {len(mv)}")
        slot_idx = (self._frame_idx % self.slots) if slot is None else slot
        offset = slot_idx * self.slot_bytes
        self._mm[offset : offset + self.slot_bytes] = mv
        assert self._sock is not None
        idx = self._frame_idx
        self._sock.sendall(f"S {slot_idx} {idx}\n".encode("utf-8"))
        ack = _read_json_line_sock(self._sock, self._rx_buf)
        if not ack.get("ok"):
            raise SafariumForgeError(f"ring frame S {slot_idx} {idx} failed: {ack.get('error', ack)}")
        self._frame_idx += 1
        return idx

    def finish(self) -> Dict[str, Any]:
        if self._finished:
            assert self.report is not None
            return self.report
        self._finished = True
        assert self._sock is not None
        if self._daemon_conn is not None:
            self._sock.sendall(b'{"cmd":"ring_finish"}\n')
            ack = _read_json_line_sock(self._sock, self._rx_buf)
            if not ack.get("ok"):
                raise SafariumForgeError(f"ring_finish failed: {ack.get('error', ack)}")
            self.report = ack["result"]
        else:
            self._sock.sendall(b"RING_FINISH\n")
            ack = _read_json_line_sock(self._sock, self._rx_buf)
            if not ack.get("ok"):
                raise SafariumForgeError(f"RING_FINISH failed: {ack.get('error', ack)}")
            if self._proc is not None:
                out_b, err_b = self._proc.communicate()
                if self._proc.returncode != 0:
                    raise SafariumForgeError(
                        f"ring-encode failed ({self._proc.returncode}): {err_b.decode('utf-8', 'replace')}",
                        returncode=self._proc.returncode,
                        stderr=err_b.decode("utf-8", "replace"),
                        stdout=out_b.decode("utf-8", "replace"),
                    )
            self.report = ack.get("report", ack)
        self._cleanup_resources()
        return self.report

    def _cleanup_resources(self) -> None:
        with contextlib.suppress(Exception):
            self._mm.close()
        with contextlib.suppress(Exception):
            self._ring_file.close()
        if self._daemon_conn is None and self._sock is not None:
            with contextlib.suppress(OSError):
                self._sock.close()
        self._sock = None
        if self._runtime_dir is not None:
            shutil.rmtree(self._runtime_dir, ignore_errors=True)
            self._runtime_dir = None

    def close(self) -> None:
        if self._proc is not None and self._proc.poll() is None and not self._finished:
            with contextlib.suppress(Exception):
                self._proc.terminate()
                self._proc.wait(timeout=3)
        self._cleanup_resources()

    def __enter__(self) -> "ForgeRingSession":
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        if exc_type is not None:
            self.close()
        elif not self._finished:
            self.finish()


class ForgeWarmSession:
    """Slot-scoped warm UDS daemon keeping Metal/ANE/PQ/ShotCache hot across sequential calls."""

    def __init__(
        self,
        *,
        render_bin: Union[str, Path],
        idle_timeout: float = 20.0,
        cache_root: Optional[Union[str, Path]] = None,
        preload_pq: bool = True,
    ):
        self.render_bin = render_bin
        self._runtime_dir = _make_private_apfs_runtime_dir("sfwarm-")
        self.socket_path = os.path.join(self._runtime_dir, "warm.sock")
        cmd = [str(render_bin), "forge", "daemon", "--socket", self.socket_path, "--idle-timeout", str(idle_timeout)]
        if cache_root is not None:
            cmd.extend(["--cache-root", str(cache_root)])
        if not preload_pq:
            cmd.append("--no-pq-preload")
        self._proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self._rx_buf = bytearray()
        self._sock: Optional[socket.socket] = None
        self._closed = False
        try:
            ready = False
            assert self._proc.stderr is not None
            while True:
                line_b = self._proc.stderr.readline()
                if not line_b:
                    break
                line_s = line_b.decode("utf-8", errors="replace").strip()
                if line_s.startswith("DAEMON_READY "):
                    ready = True
                    break
            if not ready:
                err_rest = self._proc.stderr.read().decode("utf-8", errors="replace")
                rc = self._proc.wait()
                if rc == 64 and "nested render refused" in err_rest:
                    raise SafariumForgeError("SF-VIDEO-1 nested slot refusal (returncode 64)", returncode=rc, stderr=err_rest)
                raise SafariumForgeError(f"daemon failed to start ({rc}): {err_rest}", returncode=rc, stderr=err_rest)
            self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self._sock.connect(self.socket_path)
        except Exception:
            self.close()
            raise

    def call(self, cmd: str, **params: Any) -> Dict[str, Any]:
        if self._closed or self._sock is None:
            raise SafariumForgeError("ForgeWarmSession is closed")
        req = {"cmd": cmd, **params}
        self._sock.sendall((json.dumps(req) + "\n").encode("utf-8"))
        resp = _read_json_line_sock(self._sock, self._rx_buf)
        if not resp.get("ok"):
            raise SafariumForgeError(f"daemon '{cmd}' failed: {resp.get('error', resp)}")
        return resp

    def open_ring(self, output_path: Union[str, Path], width: int, height: int, fps: int = 30, **kwargs: Any) -> ForgeRingSession:
        if self._closed or self._sock is None:
            raise SafariumForgeError("ForgeWarmSession is closed")
        return ForgeRingSession(
            render_bin=self.render_bin,
            output_path=output_path,
            width=width,
            height=height,
            fps=fps,
            daemon_conn=(self._sock, self._rx_buf),
            **kwargs,
        )

    def shutdown(self) -> Optional[Dict[str, Any]]:
        if self._closed:
            return None
        self._closed = True
        ack: Optional[Dict[str, Any]] = None
        if self._sock is not None:
            with contextlib.suppress(Exception):
                self._sock.sendall(b'{"cmd":"shutdown"}\n')
                ack = _read_json_line_sock(self._sock, self._rx_buf)
            with contextlib.suppress(OSError):
                self._sock.close()
            self._sock = None
        with contextlib.suppress(Exception):
            out_b, _ = self._proc.communicate(timeout=5)
            if out_b:
                ack = json.loads(out_b.decode("utf-8", errors="replace"))
        shutil.rmtree(self._runtime_dir, ignore_errors=True)
        return ack

    def close(self) -> None:
        self.shutdown()

    def __enter__(self) -> "ForgeWarmSession":
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> None:
        self.shutdown()


class SafariumForge:
    """High-level zero-dependency client routing every invocation via `safarium-render forge`."""

    def __init__(self, render_bin: Optional[Union[str, Path]] = None):
        self.render_bin = Path(render_bin) if render_bin else default_render_bin()

    def _invoke(
        self,
        forge_args: Sequence[str],
        *,
        stdin_bytes: Optional[bytes] = None,
        parse_json: bool = True,
        allow_nonzero_json: bool = False,
    ) -> Any:
        cmd = [str(self.render_bin), "forge", *forge_args]
        proc = subprocess.run(
            cmd,
            input=stdin_bytes,
            capture_output=True,
            check=False,
        )
        stdout = proc.stdout.decode("utf-8", errors="replace")
        stderr = proc.stderr.decode("utf-8", errors="replace")

        if proc.returncode != 0:
            if proc.returncode == 64 and "nested render refused" in stderr:
                raise SafariumForgeError(
                    "SF-VIDEO-1 nested slot refusal (returncode 64): do not wrap scripts using the SDK inside `safarium-render run`",
                    returncode=proc.returncode,
                    command=cmd,
                    stderr=stderr,
                    stdout=stdout,
                )
            if allow_nonzero_json and parse_json and stdout.strip().startswith("{"):
                data = json.loads(stdout)
                data["_returncode"] = proc.returncode
                return data
            raise SafariumForgeError(
                f"command failed ({proc.returncode}): {stderr.strip() or stdout.strip()}",
                returncode=proc.returncode,
                command=cmd,
                stderr=stderr,
                stdout=stdout,
            )
        if not parse_json:
            return stdout
        try:
            return json.loads(stdout)
        except json.JSONDecodeError as exc:
            raise SafariumForgeError(
                f"invalid JSON from `{' '.join(cmd)}`: {exc}",
                returncode=proc.returncode,
                command=cmd,
                stderr=stderr,
                stdout=stdout,
            ) from exc

    def capabilities(self) -> Dict[str, Any]:
        return self._invoke(["capabilities"])

    def version(self) -> str:
        return self._invoke(["version"], parse_json=False).strip()

    def run_recipe(
        self,
        recipe: Union[ForgePipeline, Dict[str, Any], str, Path],
        *,
        validate_only: bool = False,
        stdin_bytes: Optional[bytes] = None,
    ) -> Dict[str, Any]:
        if isinstance(recipe, (str, Path)):
            args = ["run", "--recipe", str(recipe)]
            if validate_only:
                args.append("--validate-only")
            return self._invoke(args, stdin_bytes=stdin_bytes)

        payload = recipe.to_dict() if isinstance(recipe, ForgePipeline) else recipe
        with tempfile.TemporaryDirectory(prefix="safarium-forge-recipe-") as td:
            rpath = Path(td) / "recipe.json"
            rpath.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
            args = ["run", "--recipe", str(rpath)]
            if validate_only:
                args.append("--validate-only")
            return self._invoke(args, stdin_bytes=stdin_bytes)

    def validate_recipe(self, recipe: Union[ForgePipeline, Dict[str, Any], str, Path]) -> Dict[str, Any]:
        return self.run_recipe(recipe, validate_only=True)

    def remux(
        self,
        input_path: Union[str, Path],
        output_path: Union[str, Path],
        *,
        to: Optional[str] = None,
        subtitles: Optional[Union[str, Path]] = None,
        lang: str = "tha",
        overwrite: bool = False,
    ) -> Dict[str, Any]:
        args = ["remux", str(input_path), "-o", str(output_path)]
        if to:
            args += ["--to", to]
        if subtitles:
            args += ["--subtitles", str(subtitles), "--lang", lang]
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args)

    def inspect(self, path: Union[str, Path], *, include_audio_packets: bool = False) -> Dict[str, Any]:
        args = ["inspect", str(path)]
        if include_audio_packets:
            args.append("--include-audio-packets")
        return self._invoke(args)

    def image(
        self,
        input_path: Union[str, Path],
        output_path: Union[str, Path],
        *,
        quality: Optional[float] = None,
        fps: Optional[int] = None,
        frames: Optional[int] = None,
        loop: int = 0,
        start: float = 0.0,
        overwrite: bool = False,
    ) -> Dict[str, Any]:
        args = ["image", str(input_path), "-o", str(output_path), "--loop", str(loop)]
        if quality is not None:
            args += ["--quality", str(quality)]
        if fps is not None:
            args += ["--fps", str(fps)]
        if frames is not None:
            args += ["--frames", str(frames)]
        if start > 0:
            args += ["--start", str(start)]
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args)

    def audio_process(
        self,
        input_path: Union[str, Path],
        output_path: Union[str, Path],
        *,
        eq: Optional[Iterable[str]] = None,
        comp_thresh: Optional[float] = None,
        comp_ratio: float = 4.0,
        gain: float = 0.0,
        lufs: Optional[float] = None,
        peak_dbtp: float = -1.05,
        sr: int = 48_000,
        channels: int = 2,
        bitrate: int = 192_000,
        overwrite: bool = False,
    ) -> Dict[str, Any]:
        args = ["audio", "process", str(input_path), "-o", str(output_path), "--sr", str(sr), "--channels", str(channels), "--bitrate", str(bitrate)]
        for spec in eq or ():
            args += ["--eq", spec]
        if comp_thresh is not None:
            args += ["--comp-thresh", str(comp_thresh), "--comp-ratio", str(comp_ratio)]
        if gain != 0.0:
            args += ["--gain", str(gain)]
        if lufs is not None:
            args += ["--lufs", str(lufs)]
        args += ["--peak-dbtp", str(peak_dbtp)]
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args)

    def crossfade(
        self,
        first_path: Union[str, Path],
        second_path: Union[str, Path],
        output_path: Union[str, Path],
        *,
        duration: float = 0.5,
        curve: str = "eqpower",
        sr: int = 48_000,
        channels: int = 2,
        overwrite: bool = False,
    ) -> Dict[str, Any]:
        args = ["audio", "crossfade", str(first_path), str(second_path), "-o", str(output_path), "--duration", str(duration), "--curve", curve, "--sr", str(sr), "--channels", str(channels)]
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args)

    def silence_trim(
        self,
        input_path: Union[str, Path],
        output_path: Union[str, Path],
        *,
        threshold_db: float = -42.0,
        padding: float = 0.05,
        sr: int = 48_000,
        channels: int = 2,
        overwrite: bool = False,
    ) -> Dict[str, Any]:
        args = ["audio", "silence-trim", str(input_path), "-o", str(output_path), "--threshold-db", str(threshold_db), "--padding", str(padding), "--sr", str(sr), "--channels", str(channels)]
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args)

    def waveform(
        self,
        input_path: Union[str, Path],
        *,
        bins: int = 120,
        sr: int = 8_000,
        output_path: Optional[Union[str, Path]] = None,
        overwrite: bool = False,
    ) -> Dict[str, Any]:
        args = ["audio", "waveform", str(input_path), "--bins", str(bins), "--sr", str(sr)]
        if output_path is not None:
            args += ["-o", str(output_path)]
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args)

    def synth(
        self,
        output_path: Union[str, Path],
        *,
        waveform: str = "sine",
        freq: Optional[float] = 440.0,
        end_freq: Optional[float] = None,
        carriers: Optional[Sequence[float]] = None,
        mod_hz: Optional[float] = None,
        mod_depth: Optional[float] = None,
        amp: float = 0.25,
        duration: float = 1.0,
        sr: int = 48_000,
        channels: int = 2,
        fade_in: Optional[float] = None,
        fade_out: Optional[float] = None,
        overwrite: bool = False,
    ) -> Dict[str, Any]:
        args = ["audio", "synth", "-o", str(output_path), "--waveform", waveform, "--amp", str(amp), "--duration", str(duration), "--sr", str(sr), "--channels", str(channels)]
        if freq is not None:
            args += ["--freq", str(freq)]
        if end_freq is not None:
            args += ["--end-freq", str(end_freq)]
        if carriers:
            args += ["--carriers", ",".join(str(x) for x in carriers)]
        if mod_hz is not None:
            args += ["--mod-hz", str(mod_hz)]
        if mod_depth is not None:
            args += ["--mod-depth", str(mod_depth)]
        if fade_in is not None:
            args += ["--fade-in", str(fade_in)]
        if fade_out is not None:
            args += ["--fade-out", str(fade_out)]
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args)

    def split_mp3(
        self,
        input_path: Union[str, Path],
        out_dir: Union[str, Path],
        *,
        chunk_seconds: float = 1200.0,
        prefix: str = "chunk",
        overwrite: bool = False,
    ) -> Dict[str, Any]:
        args = ["audio", "split-mp3", str(input_path), "--out-dir", str(out_dir), "--chunk-seconds", str(chunk_seconds), "--prefix", prefix]
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args)

    def sheet(
        self,
        input_path: Union[str, Path],
        output_path: Union[str, Path],
        *,
        cols: int = 6,
        rows: int = 4,
        tile_width: int = 270,
        tile_height: Optional[int] = None,
        padding: int = 8,
        bg: str = "#0F172A",
        every_frames: Optional[int] = None,
        every_sec: Optional[float] = None,
        timestamps: Optional[Sequence[float]] = None,
        quality: float = 0.88,
        manifest: Optional[Union[str, Path]] = None,
        overwrite: bool = False,
    ) -> Dict[str, Any]:
        args = ["sheet", str(input_path), "-o", str(output_path), "--cols", str(cols), "--rows", str(rows), "--tile-width", str(tile_width), "--padding", str(padding), "--bg", bg, "--quality", str(quality)]
        if tile_height is not None:
            args += ["--tile-height", str(tile_height)]
        if every_frames is not None:
            args += ["--every-frames", str(every_frames)]
        elif every_sec is not None:
            args += ["--every-sec", str(every_sec)]
        elif timestamps is not None:
            args += ["--timestamps", ",".join(str(t) for t in timestamps)]
        if manifest is not None:
            args += ["--manifest", str(manifest)]
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args)

    def compare(
        self,
        ref_path: Union[str, Path],
        cand_path: Union[str, Path],
        output_path: Union[str, Path],
        *,
        samples: int = 4,
        vertical: bool = False,
        tile_width: int = 360,
        padding: int = 8,
        bg: str = "#0F172A",
        overwrite: bool = False,
    ) -> Dict[str, Any]:
        args = ["compare", str(ref_path), str(cand_path), "-o", str(output_path), "--samples", str(samples), "--tile-width", str(tile_width), "--padding", str(padding), "--bg", bg]
        if vertical:
            args.append("--vertical")
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args)

    def pq(
        self,
        ref_path: Union[str, Path],
        cand_path: Union[str, Path],
        *,
        samples: int = 12,
        thai_ocr: bool = False,
        expected_thai: Optional[str] = None,
        min_score: float = 85.0,
        max_de00_p95: float = 2.0,
        min_msssim: float = 0.97,
        strict: bool = False,
    ) -> Dict[str, Any]:
        args = ["pq", str(ref_path), str(cand_path), "--samples", str(samples), "--min-score", str(min_score), "--max-de00-p95", str(max_de00_p95), "--min-msssim", str(min_msssim)]
        if thai_ocr:
            args.append("--thai-ocr")
        if expected_thai is not None:
            args += ["--expected-thai", expected_thai]
        if strict:
            args.append("--strict")
        return self._invoke(args, allow_nonzero_json=not strict)

    def qa(
        self,
        input_path: Union[str, Path],
        *,
        ref: Optional[Union[str, Path]] = None,
        contact_sheet: Optional[Union[str, Path]] = None,
        cols: Optional[int] = None,
        rows: Optional[int] = None,
        tile_width: Optional[int] = None,
        scene_threshold: float = 0.20,
        silence_threshold_db: float = -50.0,
        thai_ocr: bool = False,
        strict: bool = False,
        overwrite: bool = False,
    ) -> Dict[str, Any]:
        args = ["qa", str(input_path), "--scene-threshold", str(scene_threshold), "--silence-threshold-db", str(silence_threshold_db)]
        if ref is not None:
            args += ["--ref", str(ref)]
        if contact_sheet is not None:
            args += ["--contact-sheet", str(contact_sheet)]
        if cols is not None:
            args += ["--cols", str(cols)]
        if rows is not None:
            args += ["--rows", str(rows)]
        if tile_width is not None:
            args += ["--tile-width", str(tile_width)]
        if thai_ocr:
            args.append("--thai-ocr")
        if strict:
            args.append("--strict")
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args, allow_nonzero_json=not strict)

    def reframe(
        self,
        input_path: Union[str, Path],
        output_path: Union[str, Path],
        *,
        aspect: str = "9:16",
        detector: str = "saliencyAndFace",
        ema: float = 0.14,
        height: Optional[int] = None,
        codec: str = "h264",
        overwrite: bool = False,
    ) -> Dict[str, Any]:
        args = ["reframe", str(input_path), "-o", str(output_path), "--aspect", aspect, "--detector", detector, "--ema", str(ema), "--codec", codec]
        if height is not None:
            args += ["--height", str(height)]
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args)

    def matte(
        self,
        input_path: Union[str, Path],
        output_path: Union[str, Path],
        *,
        mode: str = "personBalanced",
        ema: float = 0.35,
        bg: Optional[str] = None,
        bg_image: Optional[Union[str, Path]] = None,
        codec: str = "hevc-alpha",
        mask_only: bool = False,
        max_frames: Optional[int] = None,
        overwrite: bool = False,
    ) -> Dict[str, Any]:
        args = ["matte", str(input_path), "-o", str(output_path), "--mode", mode, "--ema", str(ema), "--codec", codec]
        if bg is not None:
            args += ["--bg", bg]
        if bg_image is not None:
            args += ["--bg-image", str(bg_image)]
        if mask_only:
            args.append("--mask-only")
        if max_frames is not None:
            args += ["--max-frames", str(max_frames)]
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args)

    def _pipe_encode_args(
        self,
        output_path: Union[str, Path],
        width: int,
        height: int,
        fps: int,
        *,
        pix_fmt: str = "bgra",
        vflip: bool = False,
        codec: str = "h264",
        bitrate: int = 8_000_000,
        quality: Optional[float] = None,
        secondary: Optional[Union[str, Path]] = None,
        secondary_codec: Optional[str] = None,
        secondary_bg: str = "#000000",
        audio: Optional[Union[str, Path]] = None,
        subtitles: Optional[Union[str, Path]] = None,
        lang: str = "tha",
        max_frames: Optional[int] = None,
        overwrite: bool = False,
    ) -> List[str]:
        args = ["pipe-encode", "--width", str(width), "--height", str(height), "--fps", str(fps), "--pix-fmt", pix_fmt, "--codec", codec, "--bitrate", str(bitrate), "-o", str(output_path)]
        if vflip:
            args.append("--vflip")
        if quality is not None:
            args += ["--quality", str(quality)]
        if secondary is not None:
            args += ["--secondary", str(secondary), "--secondary-bg", secondary_bg]
            if secondary_codec is not None:
                args += ["--secondary-codec", secondary_codec]
        if audio is not None:
            args += ["--audio", str(audio)]
        if subtitles is not None:
            args += ["--subtitles", str(subtitles), "--lang", lang]
        if max_frames is not None:
            args += ["--max-frames", str(max_frames)]
        if overwrite:
            args.append("--overwrite")
        return args

    def open_pipe_encode(
        self,
        output_path: Union[str, Path],
        width: int,
        height: int,
        fps: int = 30,
        *,
        pix_fmt: str = "bgra",
        vflip: bool = False,
        codec: str = "h264",
        bitrate: int = 8_000_000,
        quality: Optional[float] = None,
        secondary: Optional[Union[str, Path]] = None,
        secondary_codec: Optional[str] = None,
        secondary_bg: str = "#000000",
        audio: Optional[Union[str, Path]] = None,
        subtitles: Optional[Union[str, Path]] = None,
        lang: str = "tha",
        max_frames: Optional[int] = None,
        overwrite: bool = False,
    ) -> PipeEncodeSession:
        bpp = 3 if pix_fmt in ("rgb24", "bgr24") else 4
        args = self._pipe_encode_args(
            output_path, width, height, fps,
            pix_fmt=pix_fmt, vflip=vflip, codec=codec, bitrate=bitrate, quality=quality,
            secondary=secondary, secondary_codec=secondary_codec, secondary_bg=secondary_bg,
            audio=audio, subtitles=subtitles, lang=lang, max_frames=max_frames, overwrite=overwrite,
        )
        return PipeEncodeSession([str(self.render_bin), "forge", *args], width, height, bpp)

    def open_ring_encode(
        self,
        output_path: Union[str, Path],
        width: int,
        height: int,
        fps: int = 30,
        *,
        slots: int = 4,
        pix_fmt: str = "bgra",
        vflip: bool = False,
        codec: str = "h264",
        bitrate: int = 8_000_000,
        quality: Optional[float] = None,
        secondary: Optional[Union[str, Path]] = None,
        secondary_codec: Optional[str] = None,
        secondary_bg: str = "#000000",
        audio: Optional[Union[str, Path]] = None,
        subtitles: Optional[Union[str, Path]] = None,
        lang: str = "tha",
        closed_gop: bool = True,
        overwrite: bool = False,
    ) -> ForgeRingSession:
        return ForgeRingSession(
            render_bin=self.render_bin,
            output_path=output_path,
            width=width,
            height=height,
            fps=fps,
            slots=slots,
            pix_fmt=pix_fmt,
            vflip=vflip,
            codec=codec,
            bitrate=bitrate,
            quality=quality,
            secondary=secondary,
            secondary_codec=secondary_codec,
            secondary_bg=secondary_bg,
            audio=audio,
            subtitles=subtitles,
            lang=lang,
            closed_gop=closed_gop,
            overwrite=overwrite,
        )

    def open_warm_session(
        self,
        *,
        idle_timeout: float = 20.0,
        cache_root: Optional[Union[str, Path]] = None,
        preload_pq: bool = True,
    ) -> ForgeWarmSession:
        return ForgeWarmSession(
            render_bin=self.render_bin,
            idle_timeout=idle_timeout,
            cache_root=cache_root,
            preload_pq=preload_pq,
        )

    def cache_hash(self, namespace: str = "default", params: Optional[Dict[str, Any]] = None, inputs: Sequence[Union[str, Path]] = ()) -> Dict[str, Any]:
        args = ["cache", "hash", "--namespace", namespace, "--params", json.dumps(params or {}, sort_keys=True)]
        if inputs:
            args.extend(["--inputs", ",".join(str(p) for p in inputs)])
        return self._invoke(args)

    def cache_store(self, input_path: Union[str, Path], *, key: Optional[str] = None, namespace: str = "default", params: Optional[Dict[str, Any]] = None, root: Optional[Union[str, Path]] = None) -> Dict[str, Any]:
        args = ["cache", "store", "--input", str(input_path), "--namespace", namespace]
        if key is not None:
            args.extend(["--key", key])
        if params is not None:
            args.extend(["--params", json.dumps(params, sort_keys=True)])
        if root is not None:
            args.extend(["--root", str(root)])
        return self._invoke(args)

    def cache_lookup(self, key: str, dest_path: Optional[Union[str, Path]] = None, *, root: Optional[Union[str, Path]] = None, overwrite: bool = False) -> Dict[str, Any]:
        args = ["cache", "lookup", "--key", key]
        if dest_path is not None:
            args.extend(["-o", str(dest_path)])
        if root is not None:
            args.extend(["--root", str(root)])
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args)

    def cache_stats(self, *, root: Optional[Union[str, Path]] = None) -> Dict[str, Any]:
        args = ["cache", "stats"]
        if root is not None:
            args.extend(["--root", str(root)])
        return self._invoke(args)

    def cache_prune(self, max_bytes: int, *, root: Optional[Union[str, Path]] = None) -> Dict[str, Any]:
        args = ["cache", "prune", "--max-bytes", str(max_bytes)]
        if root is not None:
            args.extend(["--root", str(root)])
        return self._invoke(args)

    def ab_gallery(self, manifest_path: Union[str, Path], output_html: Union[str, Path], *, overwrite: bool = False) -> Dict[str, Any]:
        args = ["ab-gallery", "--manifest", str(manifest_path), "-o", str(output_html)]
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args)

    def pipe_encode(
        self,
        frames: Union[bytes, Iterable[bytes]],
        output_path: Union[str, Path],
        width: int,
        height: int,
        fps: int = 30,
        **kwargs: Any,
    ) -> Dict[str, Any]:
        if isinstance(frames, (bytes, bytearray, memoryview)):
            args = self._pipe_encode_args(output_path, width, height, fps, **kwargs)
            return self._invoke(args, stdin_bytes=bytes(frames))
        with self.open_pipe_encode(output_path, width, height, fps, **kwargs) as session:
            for f in frames:
                session.write_frame(f)
            return session.finish()

    def extract_frame_sheet(
        self,
        video_path: Union[str, Path],
        output_image: Union[str, Path],
        *,
        cols: int = 6,
        rows: int = 4,
        tile_width: int = 270,
        every_frames: Optional[int] = None,
        every_sec: Optional[float] = None,
        timestamps: Optional[Sequence[float]] = None,
        manifest_path: Optional[Union[str, Path]] = None,
        overwrite: bool = False,
    ) -> Dict[str, Any]:
        """Replaces cv2.VideoCapture / multi-seek ffmpeg extraction with single-pass contact sheet + PTS JSON."""
        return self.sheet(
            video_path, output_image,
            cols=cols, rows=rows, tile_width=tile_width,
            every_frames=every_frames, every_sec=every_sec, timestamps=timestamps,
            manifest=manifest_path, overwrite=overwrite,
        )

    @staticmethod
    def _append_prism_policy_args(
        args: List[str],
        *,
        metalfx: bool = False,
        scale: Optional[float] = None,
        auto_verify: bool = True,
        verify_every: Optional[int] = None,
        min_pq: Optional[float] = None,
        min_msssim: Optional[float] = None,
        max_de00_p95: Optional[float] = None,
        thai_ocr: bool = False,
        expected_thai: Optional[str] = None,
        thai_shield: bool = True,
        antilag: bool = True,
    ) -> None:
        if metalfx:
            args.append("--metalfx")
        if scale is not None:
            args.extend(["--scale", str(scale)])
        if not auto_verify:
            args.append("--no-auto-verify")
        if verify_every is not None:
            args.extend(["--verify-every", str(verify_every)])
        if min_pq is not None:
            args.extend(["--min-pq", str(min_pq)])
        if min_msssim is not None:
            args.extend(["--min-msssim", str(min_msssim)])
        if max_de00_p95 is not None:
            args.extend(["--max-de00-p95", str(max_de00_p95)])
        if thai_ocr:
            args.append("--thai-ocr")
        if expected_thai is not None:
            args.extend(["--expected-thai", expected_thai])
        if not thai_shield:
            args.append("--no-thai-shield")
        if not antilag:
            args.append("--no-antilag")

    def prism_capabilities(self) -> Dict[str, Any]:
        return self._invoke(["prism", "capabilities"])

    def prism_sync_ir(
        self,
        blend_path: Union[str, os.PathLike[str]],
        glb_path: Union[str, os.PathLike[str]],
        ir_path: Union[str, os.PathLike[str]],
        *,
        frame: int = 1,
        engine: str = "eevee",
        width: Optional[int] = None,
        height: Optional[int] = None,
        export_animations: bool = True,
        overwrite: bool = False,
    ) -> Dict[str, Any]:
        args = [
            "prism", "sync-ir", str(blend_path),
            "--glb", str(glb_path),
            "--ir", str(ir_path),
            "--frame", str(frame),
            "--engine", engine,
        ]
        if width is not None:
            args.extend(["--width", str(width)])
        if height is not None:
            args.extend(["--height", str(height)])
        if not export_animations:
            args.append("--no-animations")
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args)

    def prism_preview_stills(
        self,
        input_path: Union[str, os.PathLike[str]],
        output_path: Optional[Union[str, os.PathLike[str]]] = None,
        *,
        still_dir: Optional[Union[str, os.PathLike[str]]] = None,
        contact_sheet: Optional[Union[str, os.PathLike[str]]] = None,
        tier: str = "auto",
        width: int = 1080,
        height: int = 1920,
        angles: Optional[Sequence[float]] = None,
        frames: Optional[Sequence[int]] = None,
        cols: Optional[int] = None,
        rows: Optional[int] = None,
        tile_width: int = 360,
        padding: int = 8,
        bg: str = "#0F172A",
        still_format: str = "png",
        engine: str = "eevee",
        samples: int = 16,
        shm_method: str = "bmp_mmap",
        allow_loopback_http: bool = False,
        overwrite: bool = False,
    ) -> Dict[str, Any]:
        args = [
            "prism", "preview-stills", str(input_path),
            "--tier", tier,
            "--width", str(width),
            "--height", str(height),
            "--tile-width", str(tile_width),
            "--padding", str(padding),
            "--bg", bg,
            "--format", still_format,
            "--engine", engine,
            "--samples", str(samples),
            "--shm-method", shm_method,
        ]
        if output_path is not None:
            args.extend(["-o", str(output_path)])
        if still_dir is not None:
            args.extend(["--still-dir", str(still_dir)])
        if contact_sheet is not None:
            args.extend(["--contact-sheet", str(contact_sheet)])
        if angles is not None:
            args.extend(["--angles", ",".join(str(x) for x in angles)])
        if frames is not None:
            args.extend(["--frames", ",".join(str(x) for x in frames)])
        if cols is not None:
            args.extend(["--cols", str(cols)])
        if rows is not None:
            args.extend(["--rows", str(rows)])
        if allow_loopback_http:
            args.append("--allow-loopback-http")
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args)

    def prism_render_web(
        self,
        html_path: Union[str, os.PathLike[str]],
        output_path: Union[str, os.PathLike[str]],
        *,
        width: int = 1080,
        height: int = 1920,
        fps: int = 30,
        frames: int = 30,
        start: float = 0.0,
        codec: str = "h264",
        bitrate: int = 12_000_000,
        quality: Optional[float] = None,
        transparent: bool = False,
        overlay_html: Optional[Union[str, os.PathLike[str]]] = None,
        audio: Optional[Union[str, os.PathLike[str]]] = None,
        subtitles: Optional[Union[str, os.PathLike[str]]] = None,
        lang: str = "tha",
        secondary: Optional[Union[str, os.PathLike[str]]] = None,
        secondary_codec: Optional[str] = None,
        metalfx: bool = False,
        scale: Optional[float] = None,
        auto_verify: bool = True,
        verify_every: Optional[int] = None,
        min_pq: Optional[float] = None,
        min_msssim: Optional[float] = None,
        max_de00_p95: Optional[float] = None,
        thai_ocr: bool = False,
        expected_thai: Optional[str] = None,
        thai_shield: bool = True,
        antilag: bool = True,
        allow_loopback_http: bool = False,
        overwrite: bool = False,
    ) -> Dict[str, Any]:
        args = [
            "prism", "render-web", str(html_path), "-o", str(output_path),
            "--width", str(width), "--height", str(height),
            "--fps", str(fps), "--frames", str(frames), "--start", str(start),
            "--codec", codec, "--bitrate", str(bitrate),
        ]
        if quality is not None:
            args.extend(["--quality", str(quality)])
        if transparent:
            args.append("--transparent")
        if overlay_html is not None:
            args.extend(["--overlay-html", str(overlay_html)])
        if audio is not None:
            args.extend(["--audio", str(audio)])
        if subtitles is not None:
            args.extend(["--subtitles", str(subtitles), "--lang", lang])
        if secondary is not None:
            args.extend(["--secondary", str(secondary)])
        if secondary_codec is not None:
            args.extend(["--secondary-codec", secondary_codec])
        self._append_prism_policy_args(
            args, metalfx=metalfx, scale=scale, auto_verify=auto_verify,
            verify_every=verify_every, min_pq=min_pq, min_msssim=min_msssim,
            max_de00_p95=max_de00_p95, thai_ocr=thai_ocr, expected_thai=expected_thai,
            thai_shield=thai_shield, antilag=antilag,
        )
        if allow_loopback_http:
            args.append("--allow-loopback-http")
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args)

    def prism_render_blender(
        self,
        blend_path: Union[str, os.PathLike[str]],
        output_path: Union[str, os.PathLike[str]],
        *,
        ir: Optional[Union[str, os.PathLike[str]]] = None,
        engine: str = "eevee",
        shm_method: str = "bmp_mmap",
        samples: int = 16,
        width: int = 1080,
        height: int = 1920,
        fps: int = 30,
        start_frame: int = 1,
        frames: int = 30,
        transparent: bool = False,
        codec: str = "h264",
        bitrate: int = 12_000_000,
        quality: Optional[float] = None,
        overlay_html: Optional[Union[str, os.PathLike[str]]] = None,
        audio: Optional[Union[str, os.PathLike[str]]] = None,
        subtitles: Optional[Union[str, os.PathLike[str]]] = None,
        lang: str = "tha",
        secondary: Optional[Union[str, os.PathLike[str]]] = None,
        secondary_codec: Optional[str] = None,
        metalfx: bool = False,
        scale: Optional[float] = None,
        auto_verify: bool = True,
        verify_every: Optional[int] = None,
        min_pq: Optional[float] = None,
        min_msssim: Optional[float] = None,
        max_de00_p95: Optional[float] = None,
        thai_ocr: bool = False,
        expected_thai: Optional[str] = None,
        thai_shield: bool = True,
        antilag: bool = True,
        overwrite: bool = False,
    ) -> Dict[str, Any]:
        args = [
            "prism", "render-blender", str(blend_path), "-o", str(output_path),
            "--engine", engine, "--shm-method", shm_method, "--samples", str(samples),
            "--width", str(width), "--height", str(height),
            "--fps", str(fps), "--start-frame", str(start_frame), "--frames", str(frames),
            "--codec", codec, "--bitrate", str(bitrate),
        ]
        if ir is not None:
            args.extend(["--ir", str(ir)])
        if quality is not None:
            args.extend(["--quality", str(quality)])
        if transparent:
            args.append("--transparent")
        if overlay_html is not None:
            args.extend(["--overlay-html", str(overlay_html)])
        if audio is not None:
            args.extend(["--audio", str(audio)])
        if subtitles is not None:
            args.extend(["--subtitles", str(subtitles), "--lang", lang])
        if secondary is not None:
            args.extend(["--secondary", str(secondary)])
        if secondary_codec is not None:
            args.extend(["--secondary-codec", secondary_codec])
        self._append_prism_policy_args(
            args, metalfx=metalfx, scale=scale, auto_verify=auto_verify,
            verify_every=verify_every, min_pq=min_pq, min_msssim=min_msssim,
            max_de00_p95=max_de00_p95, thai_ocr=thai_ocr, expected_thai=expected_thai,
            thai_shield=thai_shield, antilag=antilag,
        )
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args)

    def prism_composite(
        self,
        blend_path: Union[str, os.PathLike[str]],
        output_path: Union[str, os.PathLike[str]],
        *,
        bg_html: Optional[Union[str, os.PathLike[str]]] = None,
        bg_glb: Optional[Union[str, os.PathLike[str]]] = None,
        overlay_html: Optional[Union[str, os.PathLike[str]]] = None,
        secondary_mov: Optional[Union[str, os.PathLike[str]]] = None,
        primary_codec: str = "h264",
        secondary_codec: str = "prores4444",
        width: int = 1080,
        height: int = 1920,
        fps: int = 30,
        start_frame: int = 1,
        frames: int = 15,
        engine: str = "eevee",
        samples: int = 16,
        shm_method: str = "bmp_mmap",
        bitrate: int = 12_000_000,
        quality: Optional[float] = None,
        audio: Optional[Union[str, os.PathLike[str]]] = None,
        subtitles: Optional[Union[str, os.PathLike[str]]] = None,
        lang: str = "tha",
        metalfx: bool = False,
        scale: Optional[float] = None,
        auto_verify: bool = True,
        verify_every: Optional[int] = None,
        min_pq: Optional[float] = None,
        min_msssim: Optional[float] = None,
        max_de00_p95: Optional[float] = None,
        thai_ocr: bool = False,
        expected_thai: Optional[str] = None,
        thai_shield: bool = True,
        antilag: bool = True,
        overwrite: bool = False,
    ) -> Dict[str, Any]:
        args = [
            "prism", "composite", str(blend_path), "-o", str(output_path),
            "--primary-codec", primary_codec,
            "--secondary-codec", secondary_codec,
            "--width", str(width), "--height", str(height),
            "--fps", str(fps), "--start-frame", str(start_frame), "--frames", str(frames),
            "--engine", engine, "--samples", str(samples), "--shm-method", shm_method,
            "--bitrate", str(bitrate),
        ]
        if bg_html is not None:
            args.extend(["--bg-html", str(bg_html)])
        if bg_glb is not None:
            args.extend(["--bg-glb", str(bg_glb)])
        if overlay_html is not None:
            args.extend(["--overlay-html", str(overlay_html)])
        if secondary_mov is not None:
            args.extend(["--secondary-mov", str(secondary_mov)])
        if quality is not None:
            args.extend(["--quality", str(quality)])
        if audio is not None:
            args.extend(["--audio", str(audio)])
        if subtitles is not None:
            args.extend(["--subtitles", str(subtitles), "--lang", lang])
        self._append_prism_policy_args(
            args, metalfx=metalfx, scale=scale, auto_verify=auto_verify,
            verify_every=verify_every, min_pq=min_pq, min_msssim=min_msssim,
            max_de00_p95=max_de00_p95, thai_ocr=thai_ocr, expected_thai=expected_thai,
            thai_shield=thai_shield, antilag=antilag,
        )
        if overwrite:
            args.append("--overwrite")
        return self._invoke(args)


_DEFAULT = SafariumForge()
run_recipe = _DEFAULT.run_recipe
validate_recipe = _DEFAULT.validate_recipe
remux = _DEFAULT.remux
inspect = _DEFAULT.inspect
image = _DEFAULT.image
audio_process = _DEFAULT.audio_process
crossfade = _DEFAULT.crossfade
silence_trim = _DEFAULT.silence_trim
waveform = _DEFAULT.waveform
synth = _DEFAULT.synth
split_mp3 = _DEFAULT.split_mp3
sheet = _DEFAULT.sheet
compare = _DEFAULT.compare
pq = _DEFAULT.pq
qa = _DEFAULT.qa
reframe = _DEFAULT.reframe
matte = _DEFAULT.matte
pipe_encode = _DEFAULT.pipe_encode
open_pipe_encode = _DEFAULT.open_pipe_encode
open_ring_encode = _DEFAULT.open_ring_encode
open_warm_session = _DEFAULT.open_warm_session
cache_hash = _DEFAULT.cache_hash
cache_store = _DEFAULT.cache_store
cache_lookup = _DEFAULT.cache_lookup
cache_stats = _DEFAULT.cache_stats
cache_prune = _DEFAULT.cache_prune
ab_gallery = _DEFAULT.ab_gallery
capabilities = _DEFAULT.capabilities
extract_frame_sheet = _DEFAULT.extract_frame_sheet
prism_capabilities = _DEFAULT.prism_capabilities
prism_sync_ir = _DEFAULT.prism_sync_ir
prism_preview_stills = _DEFAULT.prism_preview_stills
prism_render_web = _DEFAULT.prism_render_web
prism_render_blender = _DEFAULT.prism_render_blender
prism_composite = _DEFAULT.prism_composite


def _self_check() -> None:
    assert "safarium-render" in str(default_render_bin())
    wrapped_39 = bytes([
        0x03, 0x80, 0x80, 0x80, 0x22,
        0x00, 0x00, 0x00,
        0x04, 0x80, 0x80, 0x80, 0x14,
        0x40, 0x14, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x05, 0x80, 0x80, 0x80, 0x02, 0x11, 0x90,
        0x06, 0x80, 0x80, 0x80, 0x01, 0x02,
    ])
    res_39 = unwrap_esds_bytes(wrapped_39)
    assert res_39["was_bug_302253"] and res_39["audio_specific_config"] == b"\x11\x90"
    pipe = html_overlay_recipe("/tmp/hud.html", "/tmp/out.mp4", 1080, 1920, fps=30, frames=30)
    d = pipe.to_dict()
    assert d["$schema"] == "safarium-forge/graph-v1"
    assert d["inputs"][0]["kind"] == "htmlOverlay"
    for fn in (prism_capabilities, prism_sync_ir, prism_preview_stills, prism_render_web, prism_render_blender, prism_composite, open_ring_encode, open_warm_session, cache_hash, cache_store, cache_lookup, cache_stats, cache_prune, ab_gallery):
        assert callable(fn)
    print(json.dumps({"self_check": "ok", "esds_asc_hex": res_39["audio_specific_config_hex"], "prism_helpers": 6, "wave5_helpers": 8, "render_bin": str(default_render_bin())}))


if __name__ == "__main__":
    if "--self-check" in sys.argv:
        _self_check()
    else:
        print("SafariumForge Python SDK ready (render_bin=%s)" % default_render_bin())
