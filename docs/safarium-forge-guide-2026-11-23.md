---
tags: [safarium, safarium-forge, guide, cli, sdk, zero-ffmpeg]
note_type: guide
project: "Safarium"
created: 2026-11-23
updated: 2026-11-23
---

# คู่มือใช้งาน & อ้างอิงนักพัฒนา `safarium-forge` (Apple Silicon Zero-Copy Media Engine)

> **สำหรับปิ๊ก (ภาษาคน):** `safarium-forge` คือเครื่องมือตัวเดียวจบของ Safarium ที่ใช้เฟรมเวิร์กของ Apple บน Mac ล้วน ๆ (`AVFoundation`, `VideoToolbox`, `AudioToolbox`, `Metal`, `MetalFX`, `Vision ANE`, `Accelerate vDSP`, `WKWebView`) เพื่อทำงานวิดีโอ เสียง รูปภาพ และข้อความไทย **แทน FFmpeg, ffprobe, libvmaf และ Chrome/Puppeteer/HyperFrames/Remotion ด้านเรนเดอร์** โดยรักษาภาพคม เสียงตรง เวลาไม่เพี้ยน และคุม RAM ให้ต่ำตามกฎ **SF-VIDEO-1**

---

## 1. ภาพรวมสำหรับปิ๊ก: `safarium-forge` ทำอะไรได้บ้าง?

| งานเดิมที่เคยใช้ FFmpeg / Chrome / Python RAM สูง | สิ่งที่ `safarium-forge` ทำแทนบน Mac (Zero-FFmpeg · Zero-Chrome) |
|---|---|
| แปลง/เปิด `.mkv`, `.webm`, `.ts` ที่ QuickTime/AVFoundation เปิดไม่ได้ | **Pure-Swift Container Engine (`SafariumContainers`):** ถอด/ประกอบ `.mkv`, `.webm`, `.ts` (รวม HEVC `0x24` ที่ macOS ปกติทำหาย) เป็น `.mp4`/`.mov` ตรงระดับแพ็กเก็ต + ซับไทย UTF-8 |
| แปลงรูป `.webp` (โปร่งใส/ขยับได้) และ `.avif` / `.heic` / `.heics` | **Pure-Swift Lossless `VP8L` WebP** (ภาพนิ่ง + ภาพเคลื่อนไหว) และ **Apple `ImageIO` AVIF** (`q < 1.0`) / **HEIC** / **HEICS** |
| เรนเดอร์ HTML/SVG/CSS/Canvas/WebGL + ซ้อนข้อความไทย | **Windowless `WKWebView` Mode C** + **1× Thai Shield** (วาดที่ความละเอียดจริง 1× หลังสเกลเสมอ เพื่อไม่ให้สระ/วรรณยุกต์ไทยเบลอ) |
| ฟิลเตอร์ `-filter_complex` (scale, crop, pad, deinterlace TFF/BFF, blur, Ken Burns, LUT 3D `.cube`, chroma key + despill, vignette, grain, paper-cutout, marker-texture, Split MetalFX) | **Metal Single-Init Shader Pipeline (`IOSurface` ≤ 4 slots):** คำนวณบน GPU/UMA ตรง ไม่ต้องคัดลอกเฟรมข้าม CPU ↔ GPU |
| ตัดพื้นหลังคน (`rembg`/ONNX) และครอปแนวตั้งอัตโนมัติ (`16:9 → 9:16`) | **Apple Neural Engine (`Vision` ANE):** `matte` (ตัดพื้นหลัง + EMA ลดขอบสั่น, ส่งออก `hevc-alpha`/`prores4444` หรือทับพื้นหลัง) และ `reframe` (ติดตามใบหน้า/จุดเด่น + ตัดฉากอัตโนมัติ) |
| วัดคุณภาพเทียบต้นฉบับ (`libvmaf` / `ffmpeg` SSIM/PSNR) | **`SafariumPQ` (ANE FeaturePrint + Metal 5-scale MS-SSIM + Sharma-2005 CIEDE2000 `mean/p95` + Vision Thai OCR)** |
| มิกซ์เสียง, EQ, `loudnorm`, `acrossfade`, สร้างเสียงสังเคราะห์, ตัดความเงียบ (`areverse` OOM), ดูรูปคลื่นเสียง, แบ่งไฟล์ `.mp3` | **`Accelerate vDSP` Streaming `O(4096)`:** ทำงานเป็นบล็อกสั้น 4096 เฟรมตลอดเพลง ไม่โหลด WAV/PCM ทั้งไฟล์เข้า RAM + `AudioFile` ตัด `.mp3` โดยไม่เข้ารหัสซ้ำ |
| ส่งพิกเซลดิบจาก Python/Node เข้า FFmpeg 2 รอบ (`ProRes 4444 + H.264`) | **`pipe-encode` Dual Tee:** ส่งเฟรมดิบทางท่อเดียว ออกทั้ง `.mov` (โปร่งใส `ProRes 4444`) และ `.mp4` (`H.264` พื้นหลังทึบ) ในรอบเดียว |
| ไฟล์บน an external ExFAT volume (ExFAT) ที่ค้าง/คัดลอกช้า | **`APFSAutoStage`:** ตรวจระบบไฟล์อัตโนมัติ ถ้าปลายทางเป็น ExFAT จะสร้างงานบน APFS ภายใน (`clonefile` CoW) แล้วค่อยเขียนออกปลายทางอย่างปลอดภัย |

### ข้อจำกัดจริงของ macOS (รายงานตรงไปตรงมา ไม่แอบสลับเอนจิน)
1. **ไม่มีตัวเข้ารหัส (Encode) `AV1`, `VP9`, และ `MP3` ใน Apple stack:** ถอดรหัส (Decode) และตัดแบ่ง `.mp3` แบบไม่แปลงซ้ำทำได้ แต่หากต้องการส่งออกไฟล์ใหม่ต้องใช้ `h264`, `hevc`, `hevc-alpha`, `prores4444` (วิดีโอ) และ `aac` `.m4a` / `pcm` `.wav` (เสียง)
2. **ข้อจำกัดของ Apple `ImageIO` สำหรับ AVIF/HEIC:** `AVIF` รองรับเฉพาะแบบบีบอัด (`quality < 1.0`) และภาพนิ่งเดี่ยว (ไม่รองรับ `AVIF q=1.0` และไม่รองรับ AVIF เคลื่อนไหว — ใช้ `VP8L` `.webp` หรือ `.heics` แทน)
3. **`Ogg/Opus`:** Apple `AudioToolbox` อ่าน `.caf`/`.mp4` Opus ได้ แต่ปฏิเสธกล่อง `Ogg` (`'fmt?'`)
4. **Segmented HLS/CMAF `fMP4`:** ปฏิเสธแทร็กซับ `tx3g`/`wvtt` ในไฟล์ (`-11875`) ให้ใช้ file-based `fMP4` (`fragmentIntervalSeconds`) + `tx3g` หรือ `.vtt` แยก
5. **งานคลิกเบราว์เซอร์/ล็อกอิน/ดูดข้อมูลเว็บจริง:** ให้ใช้ **`cua-go` Safari** (`safarium-forge` ใช้เฉพาะเรนเดอร์ HTML/กราฟิกเป็นวิดีโอ/ภาพ)

---

## 2. กฎการเรียกใช้ (SF-VIDEO-1)

ทุกสคริปต์และ SDK ต้องเรียกผ่านตัวคิว **`safarium-render forge ...`** เท่านั้น (ค่าเริ่มต้น `"$HOME/.local/bin/safarium-render"`, ปรับผ่านตัวแปรสภาพแวดล้อม `SAFARIUM_RENDER_BIN` ได้สำหรับการทดสอบ):
- คิวรับประกัน **1 งาน foreground ต่อ 1 บัญชี Mac** (FIFO)
- **ห้ามซ้อนคิว:** อย่าห่อสคริปต์ที่เรียก SDK ไว้ใน `safarium-render run -- ...` มิฉะนั้นชั้นในจะถูกปฏิเสธด้วยรหัสออก `64` (`nested render refused`)

---

## 3. คู่มือคำสั่ง CLI (`safarium-forge` / `safarium-render forge`)

ทุกคำสั่งส่งผลลัพธ์เป็น **JSON** บน `stdout` (ยกเว้น `--help` / `version`) และคืนรหัสออก `0` เมื่อสำเร็จ / ไม่ใช่ `0` เมื่อผิดพลาด

| คำสั่งย่อย | รูปแบบคำสั่งหลัก | หน้าที่ & ผลลัพธ์ |
|---|---|---|
| `run` / `validate` | `safarium-render forge run --recipe graph.json [--validate-only]` | รันหรือตรวจ DAG JSON (`safarium-forge/graph-v1`), รองรับ `--recipe -` (stdin) และ `rawPipe` |
| `remux` | `safarium-render forge remux IN -o OUT [--to mp4\|mov\|mkv\|webm\|ts] [--subtitles sub.srt --lang tha] [--overwrite]` | แปลงกล่องไฟล์ไม่เข้ารหัสวิดีโอซ้ำ (รวม `.mkv`/`.webm`/`.ts` HEVC `0x24`) |
| `inspect` (`probe`) | `safarium-render forge inspect PATH [--include-audio-packets]` | ตรวจแทร็ก/แพ็กเก็ต/CRC และคุณสมบัติ Volume (`isAPFS`, `supportsClonefile`) |
| `image` | `safarium-render forge image IN -o OUT.(webp\|avif\|heic\|heics\|png\|jpg) [--quality 0.80] [--fps N] [--frames N] [--loop N] [--overwrite]` | แปลงภาพหรือคลิปสั้นเป็น WebP `VP8L` (นิ่ง/เคลื่อนไหว), `AVIF` (`q<1.0`), `HEIC`, `HEICS` |
| `audio process` | `safarium-render forge audio process IN -o OUT.(wav\|m4a) [--eq mode:freq[:q[:gain]]] [--comp-thresh DB] [--gain DB] [--lufs -16] [--peak-dbtp -1.05] [--overwrite]` | ประมวลผลเสียง streaming `O(4096)` ด้วย `vDSP_biquadD`, คอมเพรสเซอร์, BS.1770-4, `OfflinePeakLimiter` |
| `audio crossfade` | `safarium-render forge audio crossfade A B -o OUT.(wav\|m4a) [--duration 0.5] [--curve eqpower\|tri] [--overwrite]` | เชื่อม 2 แทร็กแบบ crossfade ต่อเนื่อง |
| `audio silence-trim` | `safarium-render forge audio silence-trim IN -o OUT.(wav\|m4a) [--threshold-db -42] [--padding 0.05] [--overwrite]` | ตัดความเงียบหัว–ท้ายแบบ **2-cursor `O(4096)`** (ไม่เกิด `areverse` OOM) |
| `audio waveform` | `safarium-render forge audio waveform IN [--bins 120] [--sr 8000] [-o OUT.json] [--overwrite]` | สกัดค่า peak/RMS `60..600` bins ในหน่วยความจำคงที่ |
| `audio synth` | `safarium-render forge audio synth -o OUT.(wav\|m4a) [--waveform sine\|pinkNoise\|whiteNoise\|amPad\|sweep] [--freq 440] [--carriers 110,220] [--duration 1.0] [--overwrite]` | สังเคราะห์เสียงด้วย `vDSP` แทน `aevalsrc` / `sine` |
| `audio split-mp3` | `safarium-render forge audio split-mp3 IN.mp3 --out-dir DIR [--chunk-seconds 1200] [--prefix chunk] [--overwrite]` | แบ่งไฟล์ `.mp3` ที่ขอบ MPEG frame ด้วย `AudioFile` ไม่เข้ารหัสซ้ำ |
| `sheet` | `safarium-render forge sheet IN -o OUT.(jpg\|png\|webp\|avif\|heic) [--cols 6 --rows 4 --tile-width 270 --padding 8 --bg '#0F172A' --every-frames N \| --every-sec S \| --timestamps T1,T2] [--manifest out.json] [--overwrite]` | สร้าง contact sheet พร้อมไฟล์ JSON ระบุ `ptsSeconds` จริงของแต่ละช่อง |
| `compare` | `safarium-render forge compare REF CAND -o STRIP.(png\|jpg\|webp\|avif) [--samples 4] [--vertical] [--tile-width 360] [--overwrite]` | สร้างภาพเทียบ ref vs candidate แบบแถว/คอลัมน์ |
| `pq` | `safarium-render forge pq REF CAND [--samples 12] [--thai-ocr] [--expected-thai TEXT] [--min-score 85] [--max-de00-p95 2.0] [--strict]` | คำนวณคะแนน `SafariumPQ` (`--strict` คืน exit non-zero เมื่อไม่ผ่าน) |
| `qa` | `safarium-render forge qa IN [--ref REF] [--contact-sheet OUT] [--thai-ocr] [--strict] [--overwrite]` | ตรวจ `black` / `freeze` / `scene` / `silence` / `SafariumPQ` |
| `reframe` | `safarium-render forge reframe IN -o OUT [--aspect 9:16] [--detector saliencyAndFace\|faceOnly\|saliencyOnly\|upperBody] [--ema 0.14] [--height N] [--codec h264\|hevc] [--overwrite]` | ครอปอัจฉริยะด้วย ANE Vision + EMA + รีเซ็ตเมื่อเปลี่ยนฉาก |
| `matte` | `safarium-render forge matte IN -o OUT.(mov\|mp4) [--mode personFast\|personBalanced\|personAccurate\|instance] [--bg HEX \| --bg-image IMG] [--codec hevc-alpha\|prores4444\|h264] [--mask-only] [--max-frames N] [--overwrite]` | ตัดพื้นหลังบุคคลด้วย ANE + Temporal EMA |
| `pipe-encode` | `safarium-render forge pipe-encode --width W --height H --fps N [--pix-fmt rgb24\|bgr24\|rgba\|bgra] [--codec h264\|hevc\|hevc-alpha\|prores4444] -o PRIMARY [--secondary SEC --secondary-codec h264 --secondary-bg '#000000'] [--audio WAV] [--subtitles SRT --lang tha] [--max-frames N] [--overwrite]` | รับเฟรมดิบจาก `stdin` เข้ารหัสเดี่ยวหรือคู่ (`ProRes 4444 + H.264`) ในรอบเดียว |
| `capabilities` | `safarium-render forge capabilities` | แสดงสถานะฮาร์ดแวร์ Metal/ANE/VideoToolbox/AudioToolbox/ImageIO, Volume และ OS walls |

---

## 4. โครงสร้าง Recipe Graph (`safarium-forge/graph-v1`) & กฎ `1× Thai Shield`

`ForgeRecipeValidator` ตรวจสอบกราฟทั้งหมดก่อนประมวลผลเฟรมที่ 0:
- ความกว้าง/สูงต้องเป็นเลขคู่บวกสำหรับ YUV (`420v` / `nv12Left`)
- Colorimetry ต้องเป็น BT.709 Left (`bt709_left_1_1_1` / `1-1-1`)
- **1× Thai/HTML Shield:** ห้ามวางตัวปรับขนาด (`geom` resize, `kenBurns`, `autoReframe`) หรือป้อน `htmlOverlay` เข้าช่อง `lowResIn` ของ `splitMetalFX` — ต้องส่ง `htmlOverlay` เข้า `overlay` (`scale: "1"`) หรือ `splitMetalFX.overlay1xIn` หลังปรับขนาดพื้นหลังแล้วเท่านั้น

```json
{
  "$schema": "safarium-forge/graph-v1",
  "inputs": [
    { "id": "bg", "kind": "video", "path": "/path/to/bg.mp4" },
    { "id": "hud", "kind": "htmlOverlay", "path": "/path/to/thai_hud.html", "width": 1080, "height": 1920, "modeCDirtyHold": true },
    { "id": "pad", "kind": "synthAudio", "synth": { "waveform": "amPad", "carrierFrequenciesHz": [110, 220], "modulationHz": 0.5, "durationSeconds": 2.0 } }
  ],
  "timeline": { "fps": 30, "width": 1080, "height": 1920, "frameCount": 60 },
  "videoOps": [
    { "id": "graded", "op": "colorGrade", "in": "bg", "contrast": 1.05 },
    { "id": "comp", "op": "overlay", "base": "graded", "over": "hud", "x": "0", "y": "0", "opacity": "min(1.0, t/0.3)" }
  ],
  "audioOps": [
    { "id": "master", "op": "loudnorm", "in": "pad", "targetLUFS": -16.0, "peakCeilingDBTP": -1.05 }
  ],
  "output": {
    "path": "/tmp/out.mp4",
    "videoCodec": "h264",
    "pixelFormat": "420v",
    "colorimetry": "bt709_left_1_1_1",
    "overwrite": true
  }
}
```

---

## 5. ตัวอย่างการใช้งาน SDK 3 ภาษา (Zero Third-Party Dependencies)

ดูรายละเอียดเพิ่มเติมใน [`sdk/README.md`](../sdk/README.md):

- **Python (`sdk/python/safarium_forge.py`):**
  ```python
  from sdk.python.safarium_forge import SafariumForge, ForgePipeline
  forge = SafariumForge()
  caps = forge.capabilities()
  ```
- **Node ESM (`sdk/node/safarium-forge.mjs`):**
  ```js
  import { SafariumForge, unwrapWebCodecsESDS } from './sdk/node/safarium-forge.mjs';
  const forge = new SafariumForge();
  const report = await forge.inspect('/tmp/clip.ts');
  ```
- **Shell (`sdk/shell/safarium-forge.sh`):**
  ```sh
  . sdk/shell/safarium-forge.sh
  forge_capabilities
  forge_audio split-mp3 episode.mp3 --out-dir /tmp/chunks --chunk-seconds 1200
  ```

---

## 6. Safarium Prism — งาน 3D ลูกผสม (Blender 5.2 + Three.js WebKit + HID Anti-Lag + MetalFX Auto-Verify)

คำสั่งชุด `safarium-render forge prism ...` เชื่อม **Blender 5.2 LTS** (ทั้ง `BLENDER_EEVEE` และ `CYCLES`) เข้ากับ **Three.js / WebGL2 / WebGPU ใน WKWebView** และเลเยอร์ข้อความไทย 1x ใน Metal pass เดียว ผ่านเวิร์กเกอร์แบบ Warm-Blender SHM (`Tools/prism-blender-worker.py`):

| คำสั่งย่อย (`prism <action>`) | SDK (Python / Node) | หน้าที่หลัก |
|---|---|---|
| `prism capabilities` | `prism_capabilities()` / `prismCapabilities()` | ตรวจ Blender 5.2 LTS, worker script, WebKit WebGL2/WebGPU, MetalFX, IOKit HID, Thermal State |
| `prism sync-ir <in.blend> --glb <out.glb> --ir <out.ir.json>` | `prism_sync_ir(...)` / `prismSyncIr(...)` | สกัด Scene IR (`safarium-prism/scene-v1`) + โมเดล `.glb` ให้กล้อง Three.js ตรงกับ Blender |
| `prism preview-stills <in.(blend\|glb\|html)> -o <sheet.png>` | `prism_preview_stills(...)` / `prismPreviewStills(...)` | สร้างภาพตัวอย่างหลายมุม + contact sheet (`webkitGLB` ทันทีโดยไม่ปลุก Blender, `warmBlender` ผ่าน SHM, หรือ `auto`) |
| `prism render-web <in.html> -o <out.mp4>` | `prism_render_web(...)` / `prismRenderWeb(...)` | เรนเดอร์ฉาก Three.js / HTML 3D บน WKWebView + เลเยอร์ HUD 1x |
| `prism render-blender <in.blend> -o <out.mp4>` | `prism_render_blender(...)` / `prismRenderBlender(...)` | เรนเดอร์ Blender แบบปรับตามระบบ HID Anti-Lag + คุมอุณหภูมิ + วาง HUD 1x |
| `prism composite <hero.blend> --bg-html <bg.html> --overlay-html <hud.html> -o <out.mp4>` | `prism_composite(...)` / `prismComposite(...)` | รวมพื้นหลัง Three.js WebKit + ตัวละคร Blender พื้นใส (`filmTransparent`) + ข้อความไทย 1x ใน Metal pass เดียว (รองรับ `--secondary-mov alpha.mov` พร้อมกัน) |

### กลไกความปลอดภัยและคุณภาพของ Prism
- **HID Anti-Lag Governor (เปิดเป็นค่าเริ่มต้น, ปิดได้ด้วย `--no-antilag`):** ตรวจ IOKit HID Idle Time หากปิ๊กกำลังพิมพ์/เลื่อนเมาส์ จะหน่วงรอบงานเบื้องหลังให้อัตโนมัติ, ลด `taskpolicy -b` และ `PRIO_DARWIN_BG` ของ Blender worker, และพักเพิ่มเมื่อเครื่องร้อน (`serious` / `critical`) เพื่อไม่ให้ Mac กระตุก
- **MetalFX Auto-Verify (`--metalfx --scale 0.67`):** เรนเดอร์ฉาก 3D พื้นหลังที่ `0.67x` แล้วอัปสเกลด้วย `MetalFX Spatial` จากนั้นเทียบกับเฟรมอ้างอิง `1x` ด้วย `SafariumPQ` ทุกๆ `--verify-every N` เฟรม (ค่าเริ่มต้น `15`) และตรวจสอบ `--thai-ocr` หากคุณภาพต่ำกว่าเกณฑ์ (`--min-pq 85`, `--min-msssim 0.97`, `--max-de00-p95 2.0`) จะสลับกลับเป็น `1x` เต็มความละเอียดให้อัตโนมัติ ส่วน `--overlay-html` จะถูก Shield ไว้ที่ `1x` ตลอดเสมอ
- **Loopback HTTP Local ES Modules (`--allow-loopback-http`):** ใช้ได้เฉพาะ `http://127.0.0.1:<port>/...` และ `http://localhost:<port>/...` บน `prism preview-stills` และ `prism render-web` สำหรับโปรเจกต์ที่ใช้ `<script type="module">` จากเซิร์ฟเวอร์ในเครื่อง โดยยังคงบล็อกเน็ตภายนอกทุกโดเมน

---

## 7. Wave 5 — Slot-Scoped Warm Daemon, Zero-Copy mmap Ring, APFS Shot Cache และ Safari A/B Visual Diff Gallery

| คำสั่ง (`safarium-render forge ...`) | SDK (`python` / `node` / `shell`) | จุดเด่นเฉพาะ Apple Silicon / APFS |
|---|---|---|
| `daemon --socket <uds> [--idle-timeout 20]` | `open_warm_session()` / `openWarmSession()` / `forge_daemon` | เปิด Slot-Scoped Warm Session ภายใต้คิว FIFO เดียว อุ่น Metal/SafariumPQEngine/ShotCache ข้ามคำสั่งต่อเนื่อง และปิดตัวเองคืน RAM เป็น 0 MB เมื่อว่างเกินเวลาที่กำหนด |
| `ring-encode --socket <uds>` | `open_ring_encode()` / `openRingEncode()` / `forge_ring_encode` | ส่งเฟรมดิบข้ามโปรเซสแบบ Zero-Copy ผ่าน `mmap` (`SCM_RIGHTS` unlinked FD บน Python / private `0600` APFS file บน Node), รองรับ `--vflip`, dual tee, audio mux, subtitles |
| `pipe-encode ... --vflip` | `pipe_encode(..., vflip=True)` / `pipeEncode({ vflip: true })` | พลิกเฟรม WebGL bottom-up (`gl.readPixels`) ในความจำต่อเนื่องได้ทันที |
| `cache <hash\|store\|lookup\|stats\|prune>` | `cache_*` / `cache*` / `forge_cache` | แคชแบบ Content-Addressed บน APFS (`clonefile` CoW `0 B` ดิสก์ซ้ำในวอลุ่มเดียวกัน), ข้ามไฟล์ `._*` ของ ExFAT อัตโนมัติ, เผื่อตกไป `streamCopy` เมื่อเผยแพร่ข้าม ExFAT |
| `ab-gallery --manifest <json> -o gallery.html` | `ab_gallery()` / `abGallery()` / `forge_ab_gallery` | สร้างหน้าเว็บออฟไลน์เปิดใน Safari เพื่อเทียบภาพก่อน/หลังแบบเลื่อนแบ่งซ้าย-ขวา พร้อม `SafariumPQ`, OCR ภาษาไทย, ความเร็ว และกราฟเปรียบเทียบ RAM |

