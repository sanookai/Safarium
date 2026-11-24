---
tags: [safarium, cli, protocol, ai-control]
note_type: doc
project: "Safarium"
created: 2026-11-23
updated: 2026-11-23
---

# Safarium AI-First Terminal Control Protocol (Wave 6)

โปรโตคอลควบคุม `safarium-render` และ `safarium-forge` สำหรับ AI agents บน macOS โดยไม่ต้องเปิด Chrome, FFmpeg หรือเว็บ GUI หนัก

## 1. จุดเข้ากลางและ Read-Only FIFO Bypass

- จุดเข้าเดียว: `"$HOME/.local/bin/safarium-render"` (ติดตั้งจาก Release ที่ตรวจ `otool -L` Apple-only แล้ว)
- **คำสั่ง Read-Only (ผ่านทันทีโดยไม่เข้าคิว FIFO และไม่เปิด WebKit/Encoder):**
  - `safarium-render status [--json-detail | --verbose]`
  - `safarium-render doctor [--json]` (ตรวจ Release path, 4 worker `appleOnly`, queue/orphans, Metal `Apple M5`, ANE Vision, `Blender 5.2.2`, `/tmp` free GB, an external ExFAT volume mount, `shotCache`)
  - `safarium-render version`
  - `safarium-render capabilities` / `safarium-render schema [all|recipe|subcommands|errors]`
  - `safarium-render forge {inspect|probe|validate|schema|help|--help|--version}`
  - `safarium-render forge cache stats`
  - `safarium-render forge capabilities --fast` (คำสั่ง `forge capabilities` เปล่าคงเข้าคิวตามปกติ)
  - `safarium-render forge run --recipe <path.json> (--dry-run | --validate-only)`
- **คำสั่ง Queue-Gated (ใช้ FIFO ทีละ 1 งานตาม SF-VIDEO-1):**
  - `html`, `verify`, `media` modes (`extract-audio`, `mix-audio`, `extract-frames`, `gif`, `cutout`, `hybrid`, `mux`, `probe`, `qa`, `splice`, `warm-worker`), `run -- ...`, และคำสั่ง `forge` ที่เรนเดอร์/เทียบภาพ (`run`, `seq-encode`, `batch-dom`, `transcode`, `prism ...`, `pq`, `qa`, `compare`)

## 2. --progress jsonl & --json-errors

- **`--progress jsonl`**: เขียน progress JSON ทีละบรรทัดออก **stderr** (`event`, `stage`, `frame`, `total`, `progress`, `fps`, `etaSec`, `elapsedSec`, `footprintMB`, `thermal`) โดยคง JSON ผลลัพธ์สุดท้ายไว้บน **stdout** cleanly
- **`--json-errors`** (หรือ `SAFARIUM_JSON_ERRORS=1`): แปลง error ทั้งหมดของ `safarium-html`, `safarium-media`, และ `safarium-forge` เป็น JSON envelope:
  ```json
  {
    "ok": false,
    "tool": "safarium-forge",
    "error": {
      "code": "E_USAGE",
      "category": "e_usage",
      "message": "...",
      "hint": "Check command arguments or recipe schema via `safarium-forge schema`.",
      "recoverable": false
    }
  }
  ```
- **Error Code Taxonomy (`SafariumErrorCode`):** `E_USAGE`, `E_INPUT_MISSING`, `E_UNSUPPORTED_CODEC`, `E_QUEUE_BUSY`, `E_TIMEOUT`, `E_JS_EVAL`, `E_NAVIGATION`, `E_SNAPSHOT`, `E_ENCODE`, `E_VERIFY_FAIL`, `E_THERMAL_OR_MEM`, `E_INTERNAL`

## 3. คำสั่งใหม่และแฟล็กสำคัญใน Wave 6

1. `forge seq-encode`: เรนเดอร์ PNG/JPG/EXR sequence ด้วย bounded decode-ahead pool (`--dir` / `--glob` / `--list`) พร้อมสร้าง `--inline-sheet` (6x4) ในรอบเดียวโดยไม่ต้องเปิดไฟล์ MP4 ซ้ำ
2. `forge batch-dom`: โหลด WKWebView ไร้หน้าต่างครั้งเดียวแล้วถ่าย element cards (`selector`, `--font-dir`, `--transparent`) เป็น PNG อัลฟาต่อเนื่อง
3. `forge transcode`: แปลงไฟล์พร้อม 2-pass bit-budget (`--max-bytes`) ผ่าน VideoToolbox + `LosslessSoundtrackMux`
4. `forge prism render-web`:
   - Web hooks: `--ready-expr`, `--init-js` / `--init-file`, `--seek-expr`, `--ready-timeout`, `--allow-loopback-http`
   - Loopback Fonts & Visual DSP: `--font-dir`, `--output-fps`, `--grain` / `--grain-size`, `--metal-svg-filters`, `--no-sharp-text-1x`
   - Audio & Scaling: `--loudnorm` / `--true-peak` / `--apad`, `--adaptive-workers N --budget-mb M` (default `1` worker; scale ขึ้น/ถอยกลับอัตโนมัติตาม `ri_phys_footprint` และ thermal state), `--metalfx` พร้อม `1x` Thai OCR shield
5. `forge run --recipe` Wave 6 Graph Extensions:
   - Inputs: `imageSequence`, `audio` (รวม Pure-Swift `.ogg`/`.oga` Vorbis & FLAC และ `.mpeg`/`.mpg` MPEG-2 Program Stream)
   - Video ops: `geom(aspectFill: true)`, `tmix`, `kGrief`, `setpts(ptsFactor)`, `tpad(holdTailSeconds)`, `llsr`, expressions `lt`/`lte`/`gt`/`gte`/`eq`
   - Audio ops: `afade`, `atrim`, `apad`, `mix(startSeconds:)`, `loudnorm` พร้อม `OfflinePeakLimiter(oversampled4xTruePeak: true)`
   - Output / Cache / QA: `primaryAudioCodec: "pcm_s16le"`, `closedGOPSceneCache: true`, `qaOps.monochromeCheck: true`
6. `safarium-html --hash --json`: ส่ง SHA-256 checksum เฟรมต่อเฟรมเทียบ determinism ข้ามรันได้ทันที

## 4. ลิงก์อ้างอิง

- [SF-VIDEO-1 Standard](docs/render-standard.md)
- [render-command](docs/render-command.md)
- [SKILL.md](skills/safarium/SKILL.md)

