import argparse
import hashlib
import json
import math
import mmap
import os
import resource
import signal
import socket
import struct
import sys
import tempfile
import time

import bpy
import gpu
import numpy as np
from mathutils import Quaternion, Vector


Q_B2T = (math.sqrt(0.5), -math.sqrt(0.5), 0.0, 0.0)  # (w, x, y, z) = R_x(-90 deg)
Q_T2B = (math.sqrt(0.5), math.sqrt(0.5), 0.0, 0.0)   # (w, x, y, z) = R_x(+90 deg)


def quat_mul(a, b):
    aw, ax, ay, az = a
    bw, bx, by, bz = b
    return (
        aw * bw - ax * bx - ay * by - az * bz,
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
    )


def quat_norm(q):
    n = math.sqrt(sum(c * c for c in q))
    if n <= 1e-15:
        return (1.0, 0.0, 0.0, 0.0)
    return tuple(c / n for c in q)


def blender_point_to_three(p):
    return (float(p[0]), float(p[2]), -float(p[1]))


def three_point_to_blender(p):
    return (float(p[0]), -float(p[2]), float(p[1]))


def blender_quat_to_three(q_wxyz):
    return quat_norm(quat_mul(Q_B2T, quat_norm(q_wxyz)))


def three_quat_to_blender(q_wxyz):
    return quat_norm(quat_mul(Q_T2B, quat_norm(q_wxyz)))


def effective_vertical_sensor(sensor_width, sensor_height, sensor_fit, width, height, px=1.0, py=1.0):
    aspect = (float(width) * float(px)) / max(1.0, float(height) * float(py))
    fit = str(sensor_fit or "AUTO").upper()
    if fit == "VERTICAL":
        return float(sensor_height), aspect
    if fit == "HORIZONTAL":
        return float(sensor_width) / aspect, aspect
    if aspect >= 1.0:
        return float(sensor_width) / aspect, aspect
    return float(sensor_width), aspect


def blender_to_three_fov(lens_mm, sensor_width, sensor_height, sensor_fit, width, height, px=1.0, py=1.0):
    s_v, aspect = effective_vertical_sensor(sensor_width, sensor_height, sensor_fit, width, height, px, py)
    fov_y_rad = 2.0 * math.atan(s_v / (2.0 * max(1e-6, float(lens_mm))))
    return math.degrees(fov_y_rad), aspect


def three_to_blender_lens(fov_y_deg, sensor_width, sensor_height, sensor_fit, width, height, px=1.0, py=1.0):
    s_v, _ = effective_vertical_sensor(sensor_width, sensor_height, sensor_fit, width, height, px, py)
    clamped = max(1.0, min(179.0, float(fov_y_deg)))
    return s_v / (2.0 * math.tan(math.radians(clamped) * 0.5))


def normalize_engine_name(raw):
    if not raw:
        return "BLENDER_EEVEE"
    u = str(raw).strip().upper()
    if u in ("EEVEE", "BLENDER_EEVEE", "BLENDER_EEVEE_NEXT"):
        return "BLENDER_EEVEE"
    if u == "CYCLES":
        return "CYCLES"
    return u


def get_ru_maxrss():
    return int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)


class PrismBlenderWorker:
    def __init__(self, sock_path, shm_path, idle_timeout=300.0, gpu_recycle_every=100):
        self.sock_path = sock_path
        self.shm_path = shm_path
        self.idle_timeout = float(idle_timeout) if idle_timeout > 0 else None
        self.gpu_recycle_every = max(1, int(gpu_recycle_every))
        self.fd = None
        self.mm = None
        self.width = 0
        self.height = 0
        self.engine = "BLENDER_EEVEE"
        self.blend_path = None
        self.gpu_off = None
        self.gpu_inited = False
        self.gpu_frame_counter = 0
        self.stop_requested = False

    def ensure_shm(self, w, h):
        need = int(w) * int(h) * 4
        if self.mm is not None and self.width == w and self.height == h:
            return False
        if self.mm is not None:
            self.mm.close()
            self.mm = None
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        self.fd = os.open(self.shm_path, os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o600)
        os.ftruncate(self.fd, need)
        # Explicit access=mmap.ACCESS_WRITE keyword (never positional flags!).
        self.mm = mmap.mmap(self.fd, need, access=mmap.ACCESS_WRITE)
        self.width = int(w)
        self.height = int(h)
        return True

    def free_gpu_offscreen(self):
        if self.gpu_off is not None:
            try:
                self.gpu_off.free()
            except Exception:
                pass
            self.gpu_off = None

    def ensure_gpu_offscreen(self, w, h):
        if not self.gpu_inited:
            gpu.init()
            self.gpu_inited = True
        if self.gpu_off is not None:
            if (self.gpu_off.width != w or self.gpu_off.height != h) or (self.gpu_frame_counter >= self.gpu_recycle_every):
                self.free_gpu_offscreen()
                self.gpu_frame_counter = 0
        if self.gpu_off is None:
            self.gpu_off = gpu.types.GPUOffScreen(w, h)
        return self.gpu_off

    def configure_engine(self, engine_name, samples=16, film_transparent=None):
        sc = bpy.context.scene
        eng = normalize_engine_name(engine_name)
        self.engine = eng
        if eng == "CYCLES":
            sc.render.engine = "CYCLES"
            cp = bpy.context.preferences.addons["cycles"].preferences
            cp.compute_device_type = "METAL"
            cp.get_devices()
            for dev in cp.devices:
                dev.use = (dev.type == "METAL")
            sc.cycles.device = "GPU"
            sc.cycles.samples = max(1, int(samples))
            sc.cycles.use_denoising = True
            sc.cycles.denoiser = "OPENIMAGEDENOISE"
            sc.cycles.denoising_use_gpu = True
        else:
            sc.render.engine = "BLENDER_EEVEE"
            if hasattr(sc, "eevee") and hasattr(sc.eevee, "taa_render_samples"):
                sc.eevee.taa_render_samples = max(1, int(samples))
        if film_transparent is not None:
            sc.render.film_transparent = bool(film_transparent)

    def build_scene_ir_dict(self, glb_path=None):
        sc = bpy.context.scene
        cam = sc.camera
        if cam is None:
            raise RuntimeError("scene has no active camera")
        w = int(sc.render.resolution_x)
        h = int(sc.render.resolution_y)
        px = float(sc.render.pixel_aspect_x)
        py = float(sc.render.pixel_aspect_y)

        mw = cam.matrix_world
        pos_b = tuple(mw.translation)
        q_b = tuple(mw.to_quaternion())  # (w, x, y, z)
        pos_t = blender_point_to_three(pos_b)
        q_t = blender_quat_to_three(q_b)

        cdata = cam.data
        fit = str(getattr(cdata, "sensor_fit", "AUTO"))
        lens = float(cdata.lens)
        sw = float(cdata.sensor_width)
        sh = float(cdata.sensor_height)
        fov_y, aspect = blender_to_three_fov(lens, sw, sh, fit, w, h, px, py)

        fps = float(sc.render.fps) / max(1e-6, float(sc.render.fps_base))
        f_start = int(sc.frame_start)
        f_end = max(f_start, int(sc.frame_end))
        duration_sec = float(max(1, f_end - f_start + 1)) / max(1.0, fps)

        dof_obj = getattr(cdata, "dof", None)
        dof_dict = None
        if dof_obj is not None:
            dof_dict = {
                "enabled": bool(dof_obj.use_dof),
                "focusDistance": float(dof_obj.focus_distance),
                "fstop": float(dof_obj.aperture_fstop),
            }

        return {
            "schema": "safarium-prism/scene-v1",
            "sceneName": sc.name,
            "blendFilePath": self.blend_path,
            "glbFilePath": glb_path,
            "engine": self.engine,
            "frame": int(sc.frame_current),
            "camera": {
                "name": cam.name,
                "positionThree": {"x": pos_t[0], "y": pos_t[1], "z": pos_t[2]},
                "quaternionThree": {"w": q_t[0], "x": q_t[1], "y": q_t[2], "z": q_t[3]},
                "lensMM": lens,
                "sensorWidthMM": sw,
                "sensorHeightMM": sh,
                "sensorFit": fit,
                "width": w,
                "height": h,
                "pixelAspectX": px,
                "pixelAspectY": py,
                "fovYDeg": fov_y,
                "aspect": aspect,
                "near": float(cdata.clip_start),
                "far": float(cdata.clip_end),
                "shiftX": float(cdata.shift_x),
                "shiftY": float(cdata.shift_y),
                "dof": dof_dict,
                "match2DZoom": None,
            },
            "timeline": {
                "fps": fps,
                "frameStart": f_start,
                "frameEnd": f_end,
                "durationSeconds": duration_sec,
                "cuts": [],
                "hitstopFrames": [],
                "storyToVideoTimeScale": 1.0,
            },
            "anchors": [],
            "composite": None,
            "qualityPolicy": {
                "useMetalFX": False,
                "scaleFactor": 0.67,
                "autoVerifyMetalFX": True,
                "verifyEveryNFrames": 15,
                "minPQScore": 85.0,
                "minMSSSIM": 0.97,
                "maxDeltaE00P95": 2.0,
                "checkThaiOCR": False,
                "expectedThaiText": None,
                "thaiShield1xOverlay": True,
            },
        }

    def apply_delta(self, delta):
        sc = bpy.context.scene
        if not delta:
            return
        if "frame" in delta and delta["frame"] is not None:
            sc.frame_set(int(delta["frame"]))
        cam = sc.camera
        if cam is not None:
            if "cameraPositionThree" in delta and delta["cameraPositionThree"] is not None:
                p = delta["cameraPositionThree"]
                cam.location = Vector(three_point_to_blender((p["x"], p["y"], p["z"])))
            if "cameraPositionDeltaBlender" in delta and delta["cameraPositionDeltaBlender"] is not None:
                dp = delta["cameraPositionDeltaBlender"]
                loc = cam.location.copy()
                loc.x += float(dp.get("x", 0.0))
                loc.y += float(dp.get("y", 0.0))
                loc.z += float(dp.get("z", 0.0))
                cam.location = loc
            if "dx" in delta or "dy" in delta or "dz" in delta:
                loc = cam.location.copy()
                loc.x += float(delta.get("dx", 0.0))
                loc.y += float(delta.get("dy", 0.0))
                loc.z += float(delta.get("dz", 0.0))
                cam.location = loc
            if "cameraQuaternionThree" in delta and delta["cameraQuaternionThree"] is not None:
                q = delta["cameraQuaternionThree"]
                qb = three_quat_to_blender((q["w"], q["x"], q["y"], q["z"]))
                cam.rotation_mode = "QUATERNION"
                cam.rotation_quaternion = Quaternion(qb)
            if "lensMM" in delta and delta["lensMM"] is not None:
                cam.data.lens = float(delta["lensMM"])
            elif "fovYDeg" in delta and delta["fovYDeg"] is not None:
                cam.data.lens = three_to_blender_lens(
                    float(delta["fovYDeg"]),
                    cam.data.sensor_width,
                    cam.data.sensor_height,
                    cam.data.sensor_fit,
                    sc.render.resolution_x,
                    sc.render.resolution_y,
                    sc.render.pixel_aspect_x,
                    sc.render.pixel_aspect_y,
                )
            if "shiftX" in delta and delta["shiftX"] is not None:
                cam.data.shift_x = float(delta["shiftX"])
            if "shiftY" in delta and delta["shiftY"] is not None:
                cam.data.shift_y = float(delta["shiftY"])
            if "focusDistance" in delta and delta["focusDistance"] is not None and hasattr(cam.data, "dof"):
                cam.data.dof.use_dof = True
                cam.data.dof.focus_distance = float(delta["focusDistance"])
            if "fstop" in delta and delta["fstop"] is not None and hasattr(cam.data, "dof"):
                cam.data.dof.use_dof = True
                cam.data.dof.aperture_fstop = float(delta["fstop"])
        if "filmTransparent" in delta and delta["filmTransparent"] is not None:
            sc.render.film_transparent = bool(delta["filmTransparent"])
        if "samples" in delta and delta["samples"] is not None:
            self.configure_engine(self.engine, samples=int(delta["samples"]))
        bpy.context.view_layer.update()

    def handle(self, req):
        cmd = req.get("cmd")
        if cmd == "ping":
            return {
                "ok": True,
                "cmd": "ping",
                "pid": os.getpid(),
                "blender_version": bpy.app.version_string,
                "ru_maxrss_bytes": get_ru_maxrss(),
            }

        if cmd == "load_blend":
            t0 = time.perf_counter()
            self.free_gpu_offscreen()
            path = req["path"]
            bpy.ops.wm.open_mainfile(filepath=path)
            self.blend_path = path
            sc = bpy.context.scene
            w = int(req.get("width") or sc.render.resolution_x)
            h = int(req.get("height") or sc.render.resolution_y)
            samples = int(req.get("samples") or 16)
            film_t = req.get("film_transparent")
            sc.render.resolution_x = w
            sc.render.resolution_y = h
            sc.render.resolution_percentage = 100
            self.configure_engine(req.get("engine") or sc.render.engine, samples=samples, film_transparent=film_t)
            self.ensure_shm(w, h)
            fps = float(sc.render.fps) / max(1e-6, float(sc.render.fps_base))
            dt = (time.perf_counter() - t0) * 1000.0
            return {
                "ok": True,
                "cmd": "load_blend",
                "width": w,
                "height": h,
                "fps": fps,
                "frame_start": int(sc.frame_start),
                "frame_end": int(sc.frame_end),
                "engine": self.engine,
                "load_ms": round(dt, 2),
                "ru_maxrss_bytes": get_ru_maxrss(),
            }

        if cmd == "export_glb_and_ir":
            sc = bpy.context.scene
            if req.get("width") is not None:
                sc.render.resolution_x = int(req["width"])
            if req.get("height") is not None:
                sc.render.resolution_y = int(req["height"])
            sc.render.resolution_percentage = 100
            if req.get("frame") is not None:
                sc.frame_set(int(req["frame"]))
            bpy.context.view_layer.update()

            glb_path = req["glb_path"]
            export_anim = bool(req.get("export_animations", True))
            t0 = time.perf_counter()
            bpy.ops.export_scene.gltf(
                filepath=glb_path,
                export_format="GLB",
                export_animations=export_anim,
                export_cameras=True,
                export_lights=True,
            )
            ir_dict = self.build_scene_ir_dict(glb_path=glb_path)
            ir_path = req.get("ir_path")
            if ir_path:
                tmp_ir = f"{ir_path}.tmp.{os.getpid()}"
                with open(tmp_ir, "w", encoding="utf-8") as fh:
                    json.dump(ir_dict, fh, indent=2, sort_keys=True)
                    fh.write("\n")
                os.replace(tmp_ir, ir_path)
            dt = (time.perf_counter() - t0) * 1000.0
            return {
                "ok": True,
                "cmd": "export_glb_and_ir",
                "glb_path": glb_path,
                "ir_path": ir_path,
                "ir": ir_dict,
                "export_ms": round(dt, 2),
                "ru_maxrss_bytes": get_ru_maxrss(),
            }

        if cmd == "apply_ir_delta":
            delta = req.get("delta") or req
            self.apply_delta(delta)
            return {
                "ok": True,
                "cmd": "apply_ir_delta",
                "frame": int(bpy.context.scene.frame_current),
                "ru_maxrss_bytes": get_ru_maxrss(),
            }

        if cmd == "render_frame_shm":
            sc = bpy.context.scene
            t_upd0 = time.perf_counter()
            if req.get("width") is not None:
                sc.render.resolution_x = int(req["width"])
            if req.get("height") is not None:
                sc.render.resolution_y = int(req["height"])
            sc.render.resolution_percentage = 100
            w = int(sc.render.resolution_x)
            h = int(sc.render.resolution_y)
            shm_resized = self.ensure_shm(w, h)

            frame = int(req.get("frame", sc.frame_current))
            sc.frame_set(frame)
            if req.get("film_transparent") is not None:
                sc.render.film_transparent = bool(req["film_transparent"])
            if req.get("samples") is not None:
                self.configure_engine(self.engine, samples=int(req["samples"]))
            if req.get("delta"):
                self.apply_delta(req["delta"])
            else:
                bpy.context.view_layer.update()

            method = req.get("method", "bmp_mmap")
            t0 = time.perf_counter()

            if method == "gpu_offscreen":
                if self.engine == "CYCLES":
                    raise ValueError("gpu_offscreen is only supported with BLENDER_EEVEE (use bmp_mmap for CYCLES)")
                win = bpy.context.window_manager.windows[0]
                v3d = next(a for a in win.screen.areas if a.type == "VIEW_3D")
                sp = v3d.spaces.active
                reg = next(r for r in v3d.regions if r.type == "WINDOW")
                sp.shading.type = "RENDERED"
                off = self.ensure_gpu_offscreen(w, h)
                cam = sc.camera
                dg = bpy.context.evaluated_depsgraph_get()
                vmat = cam.matrix_world.inverted()
                pmat = cam.calc_matrix_camera(dg, x=w, y=h)
                off.draw_view3d(sc, bpy.context.view_layer, sp, reg, vmat, pmat, do_color_management=True)
                t1 = time.perf_counter()
                with off.bind():
                    rb = gpu.state.active_framebuffer_get().read_color(0, 0, w, h, 4, 0, "UBYTE")
                arr_bu = np.asarray(rb, dtype=np.uint8)
                # Flip vertically + RGBA -> top-down BGRA8
                bgra_td = np.ascontiguousarray(arr_bu[::-1, :, [2, 1, 0, 3]])
                self.gpu_frame_counter += 1
            elif method == "bmp_mmap":
                tmp_dir = os.path.dirname(self.shm_path) or tempfile.gettempdir()
                tmp_bmp = os.path.join(tmp_dir, f"_prism_frame_{os.getpid()}.bmp")
                sc.render.image_settings.file_format = "BMP"
                sc.render.image_settings.color_mode = "RGBA"
                bpy.ops.render.render(write_still=False)
                t1 = time.perf_counter()
                try:
                    bpy.data.images["Render Result"].save_render(tmp_bmp, scene=sc)
                    with open(tmp_bmp, "rb") as fh:
                        raw = fh.read()
                finally:
                    if os.path.exists(tmp_bmp):
                        os.remove(tmp_bmp)

                data_offset = struct.unpack_from("<I", raw, 10)[0]
                bmp_w, bmp_h = struct.unpack_from("<ii", raw, 18)
                bpp = struct.unpack_from("<H", raw, 28)[0]
                if bmp_w != w or abs(bmp_h) != h:
                    raise RuntimeError(f"BMP dimensions {bmp_w}x{bmp_h} != expected {w}x{h}")
                if bpp == 32:
                    bgra_rows = np.frombuffer(raw, dtype=np.uint8, offset=data_offset, count=w * h * 4).reshape(h, w, 4)
                    bgra_td = np.ascontiguousarray(bgra_rows[::-1] if bmp_h > 0 else bgra_rows)
                elif bpp == 24:
                    row_stride = (w * 3 + 3) & ~3
                    bgr_rows = np.frombuffer(raw, dtype=np.uint8, offset=data_offset, count=h * row_stride).reshape(h, row_stride)[:, : w * 3].reshape(h, w, 3)
                    bgr_td = bgr_rows[::-1] if bmp_h > 0 else bgr_rows
                    bgra_td = np.empty((h, w, 4), dtype=np.uint8)
                    bgra_td[..., :3] = bgr_td
                    bgra_td[..., 3] = 255
                else:
                    raise RuntimeError(f"Unsupported BMP bit depth {bpp}")
            else:
                raise ValueError(f"Unknown SHM render method '{method}'")

            self.mm.seek(0)
            self.mm.write(bgra_td.data)
            t2 = time.perf_counter()
            mean_rgb = float(bgra_td[..., :3].mean())
            transparent_px = int((bgra_td[..., 3] == 0).sum())
            sha16 = hashlib.sha256(bgra_td.data).hexdigest()[:16]

            return {
                "ok": True,
                "cmd": "render_frame_shm",
                "frame": frame,
                "method": method,
                "width": w,
                "height": h,
                "byte_count": w * h * 4,
                "shm_resized": shm_resized,
                "sha256_prefix": sha16,
                "mean_rgb": round(mean_rgb, 3),
                "transparent_pixels": transparent_px,
                "render_ms": round((t1 - t0) * 1000.0, 2),
                "extract_ms": round((t2 - t1) * 1000.0, 2),
                "total_ms": round((t2 - t_upd0) * 1000.0, 2),
                "ru_maxrss_bytes": get_ru_maxrss(),
            }

        if cmd == "shutdown":
            self.stop_requested = True
            return {"ok": True, "cmd": "shutdown", "ru_maxrss_bytes": get_ru_maxrss()}

        return {"ok": False, "error": f"unknown command '{cmd}'"}

    def serve(self):
        if os.path.exists(self.sock_path):
            os.unlink(self.sock_path)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(self.sock_path)
        os.chmod(self.sock_path, 0o600)
        srv.listen(4)
        if self.idle_timeout is not None:
            srv.settimeout(self.idle_timeout)

        def on_sig(_signum, _frame):
            self.stop_requested = True

        signal.signal(signal.SIGTERM, on_sig)
        signal.signal(signal.SIGINT, on_sig)

        print(f"WARM_READY {self.sock_path}", flush=True)
        try:
            while not self.stop_requested:
                try:
                    conn, _ = srv.accept()
                except socket.timeout:
                    break
                except OSError:
                    break
                with conn:
                    conn.settimeout(None)
                    f_in = conn.makefile("r", encoding="utf-8")
                    for line in f_in:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            req = json.loads(line)
                            resp = self.handle(req)
                        except Exception as exc:
                            resp = {"ok": False, "error": repr(exc)}
                        conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
                        if self.stop_requested:
                            break
        finally:
            self.free_gpu_offscreen()
            if self.mm is not None:
                self.mm.close()
                self.mm = None
            if self.fd is not None:
                os.close(self.fd)
                self.fd = None
            try:
                srv.close()
            except Exception:
                pass
            if os.path.exists(self.sock_path):
                try:
                    os.unlink(self.sock_path)
                except OSError:
                    pass


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    ap = argparse.ArgumentParser(description="Safarium Prism Warm Blender 5.2 Worker")
    ap.add_argument("--socket", required=True)
    ap.add_argument("--shm", required=True)
    ap.add_argument("--idle-timeout", type=float, default=300.0)
    ap.add_argument("--gpu-recycle-every", type=int, default=100)
    args = ap.parse_args(argv)
    PrismBlenderWorker(
        sock_path=args.socket,
        shm_path=args.shm,
        idle_timeout=args.idle_timeout,
        gpu_recycle_every=args.gpu_recycle_every,
    ).serve()


if __name__ == "__main__":
    main()
