---
tags: [safarium, reference, probes, p1]
note_type: reference
project: "Safarium"
created: 2026-11-21
updated: 2026-11-21 (แก้ core + probe ใหม่ ดู "อัปเดตหลังแก้ core")
---

# Safarium P1-F — probe results (core vs real-world content)

เครื่อง: macOS 27 (Darwin 27.2), WKWebView offscreen, `HostApp` = `.prohibited` · โค้ด probe: `Tests/SafariumProbeTests/**` · fixtures: `Tests/Fixtures/probes/**`
Evidence (frames, `measurements.log`, `hevc-alpha.mov`): `<scratch>` (scratch — หายได้เมื่อ reboot; รัน probe ใหม่ได้ ดู "รันซ้ำ")

## สรุป

| # | Probe | ผล | ตัวเลข | Evidence | Core ต้องแก้ |
|---|---|---|---|---|---|
| 1a | GSAP 3 paused timeline + seek | **PASS** | ซ้าย-กล่อง x = 100/400/700 ที่ t=0/1.5/3 (คาด 100/400/700) · 10,000 px ไม่ว่าง · 2 รอบ hash เหมือนกัน | `gsap-paused-t*.png` | ไม่ |
| 1b | GSAP ticker เล่นเอง (ไม่ใช้ hook) | **PASS (แก้แล้ว)** | t=0.1/1.5/3 → 120/400/700 · ที่ t=0 ตอนนี้ render แล้ว x=107 (GSAP นับ tick แรก = 33 ms → 106.7 เหมือนเบราว์เซอร์จริง; ก่อนแก้ค้างที่ 0) | `gsap-ticker-*.png` | แก้แล้ว (#2 pre-roll) |
| 1c | anime.js 4 (`seek`) | **PASS** | 100/400/700 · hash 2 รอบเหมือนกัน (และเท่ากับ GSAP/Pixi ทุกเฟรม) | `anime-*.png` | ไม่ |
| 1d | lottie-web (svg, `goToAndStop`) | **PASS** | 100/400/700 · deterministic · (ต้อง `op` = last frame+1 มิฉะนั้น t=3.0 ว่าง) | `lottie-*.png` | แก้แล้ว (#3 flush หลัง load) |
| 1e | PixiJS 8 (WebGL) | **PASS** | 100/400/700 · พิกเซล WebGL 10,000 ไม่ว่าง · hash 2 รอบเหมือนกัน | `pixi-*.png` | ไม่ |
| 1f | three.js 0.187 (WebGL, lights+texture) | **PASS** | 100/400/700 · 10,000 px · hash เหมือนกัน 2 รอบ · `toDataURL` ในเฟรมเดียวกับ draw ใช้ได้ (ไม่ต้อง preserveDrawingBuffer) | `three-*.png` | ไม่ |
| 2 | `<video>` seek (H.264 long-GOP, intra-only, HEVC) | **PASS (แก้แล้ว)** | ผ่าน core `VideoMode`: H.264 element 60/60 ทุกชุด · `.extract` 60/60 ทุกชุดทั้ง H.264 + HEVC (0 seek error) · HEVC element 56–57/60 = named gap (open-GOP) | `video-*.png` | แก้แล้ว (#4 `.element`, #5 `.extract`) |
| 3 | HEVC + alpha → AVAssetReader | **PASS** | FourCC `hvc1` · `ContainsAlphaChannel`=true · track characteristic=true · มุมโปร่ง a=0 · กล่อง 50% a=128 (r=115 premultiplied) | `hevc-alpha.mov` | ไม่ (อัปเดตเอกสาร core: ยืนยันแล้ว) |
| 4 | Snapshot 1× vs 2× downsample | **FAIL (วัดได้ต่าง)** | 1× เทียบ reference (2160×3840 box-down) PSNR = **21.97 dB** · CG-downscale 2× เทียบ reference 29.93 dB · sharpness 1×=13.43 vs ref=11.81 (1× คมแต่ alias กว่า) · snapshotWidth=W/2→1080×1920 จริง, =W→2160×3840 | `quality-*.png` | **รอปิ๊กตัดสิน (#5)** |
| 5 | ไม่แย่งโฟกัส / ไม่มีหน้าต่าง | **PASS** | 300 เฟรม 1080×1920: frontmost เดิม ("Google Chrome") ก่อน/ระหว่าง/หลัง · `lsappinfo front` 176 ตัวอย่างไม่เปลี่ยน · System Events 7 ตัวอย่าง (frontmost/Safari windows=0/Dock apps) ไม่เปลี่ยน · activationPolicy=prohibited | `measurements.log` | ไม่ |
| 6a | Memory 3,000 เฟรม 1080×1920 H.264 | **PASS** | 12.0 s (251 fps) · RSS รวม (เรา + WebContent) f500=168 MB → f2999=160 MB (−8 MB, ไม่รั่ว) · ของเรา ~131–137 MB, WebContent ~30 MB | `measurements.log` | ไม่ |
| 6b | Parallel workers | **PASS (ไม่เร็วขึ้น)** | ตันที่ ~250 fps รวม: ใน process เดียว 1/2/4 Page = 247/254/253 fps · แยก 1/2/4 process = 257/255/255 fps → คอขวดเป็นฮาร์ดแวร์/encoder ไม่ใช่เธรด main | `measurements.log` | ไม่ (แต่ไม่ควรเขียนแผนที่คาดว่า worker เพิ่มแล้วเร็วขึ้น) |
| 7 | Fonts (Inter + Noto Sans Thai, @font-face ไฟล์ local) | **PASS** | 12 โหลดใหม่ (สลับมี/ไม่มี VirtualClock) ที่ `waitFor(.fonts)` อย่างเดียว: ต่างจาก reference (โหลดครบ+รอ 1 s) **0/12** · ไม่รอเลย 0/5 ต่าง (โหลด local เร็วมาก) · fallback ต่างจากฟอนต์จริงชัด (sanity) | `fonts-*.png` | ไม่ |
| — | (เจอระหว่างทาง) `Page.evaluate(timeout:)` | **PASS (แก้แล้ว)** | throw `.timeout` ตรงเวลา (1.2–1.4 s สำหรับ timeout 1 s) | test `ClockGapTests` (core) + `CoreGapProbeTests` | แก้แล้ว (#1) |

## อัปเดตหลังแก้ core (2026-11-21)

ผล `SAFARIUM_PROBES=1 swift test --filter SafariumProbeTests`: **27 tests, 1 skipped (helper ของ worker), 0 failures, exit 0** (228 s ตอนเครื่องโหลดสูง, load avg 1 นาที ~19/10 core) · default `swift test` (ไม่มี env): exit 0, ~32 s, ไม่ใช้เน็ต

Seek accuracy วัดผ่าน `page.seek()` ของ core (60 seek ต่อชุด; clip 640×360 30 fps 150 เฟรม):

| คลิป | โหมด | mid-frame seq | mid-frame rand | boundary t=n/30 seq | boundary rand | +0.25 rand | seek error | ms/seek+snapshot |
|---|---|---|---|---|---|---|---|---|
| H.264 intra | `.element` | 60/60 | 60/60 | 60/60 | 60/60 | 60/60 | 0 | 11.5 |
| H.264 intra | `.extract` | 60/60 | 60/60 | 60/60 | 60/60 | 60/60 | 0 | 24.2 |
| H.264 GOP 250 | `.element` | 60/60 | 60/60 | 60/60 | 60/60 | 60/60 | 0 | 12.9 |
| H.264 GOP 250 | `.extract` | 60/60 | 60/60 | 60/60 | 60/60 | 60/60 | 0 | 58.5 |
| HEVC GOP 60 | `.extract` | 60/60 | 60/60 | 60/60 | 60/60 | 60/60 | 0 | 37.2 |
| HEVC GOP 60 | `.element` | 56/60 | 57/60 | 56/60 | 57/60 | 57/60 | 0 | 11.9 |

(ms ขึ้นกับโหลดเครื่อง; รอบเบากว่าเคยได้ element ~6.6, extract ~20–28)

**Root cause ที่เจอระหว่างแก้ (แทนสมมติฐานเดิมว่า "stale frame หลัง seeked"):**
1. **HEVC 3–4 เฟรมผิดใน 60** = เฟรม leading (RASL) 4 เฟรมก่อน CRA ของ open-GOP (x265 ของ ffmpeg: เฟรม 56–59, 116–119) ถอดไม่ได้หลัง random access — `<video>` ค้างเฟรมก่อนหน้า และ `AVAssetImageGenerator` ตอบ "Cannot Decode −11821" (ตัว `AVAssetReader` เริ่มที่ CRA แล้วทิ้ง RASL). แก้ใน `.extract`: ถ้า generator ล้ม → reader เริ่มอ่านถอยหลัง 16 เฟรมแล้ววนไปถึงเฟรม → 60/60. `.element` แก้ไม่ได้ → named gap **`element-hevc-open-gop`** = `XCTExpectFailure` แบบ strict ใน `testVideo_hevc_element_seekAccuracy` (จะ fail เมื่อ gap หาย)
2. **H.264 GOP 250 เพี้ยนทั้งชุดหลัง ~235 seek** = หน้าที่อยู่ใน window นอกจอถูก WebKit มองว่า inactive (`document.hidden`=true, occlusion ไม่ visible) แล้ว suspend → video ค้างเฟรมเดียว. แก้: `WKPreferences.inactiveSchedulingPolicy = .none` → 400 seek สุ่ม 0 ผิด (ก่อนแก้ 155–168 ผิด)
3. **`n/30` ตรงๆ ได้ n−1** (raw path: 11/30) → core seek ไป "กลางเฟรม" `t0 + (k+0.5)/fps` และ snap fps (nominalFrameRate เป็น Float: 29.999998)
4. **`.fileURL` ของ html ที่ไม่มี `<meta charset>`** โหลดเป็น data → video/รูป relative โหลดไม่ได้ (NO_SOURCE) — เจอตอนทำ focus probe; ยังไม่แก้ใน core (บันทึกใน core-api.md)

Focus (`.element` + window นอกจอ, 150 seek): lsappinfo front เปลี่ยน 0/51 ตัวอย่าง · frontmost/Safari windows/Dock ไม่เปลี่ยน · window key=false, app active=false, policy=2 (prohibited) — System Events ได้เพียง 2 ตัวอย่างในรอบสั้น (หลักฐานหลักคือ lsappinfo)

**แก้ probe (Part 2):**
- A. ถอด `XCTExpectFailure` ครอบทั้งลูป · ทุกชุดใช้ assert เข้ม (`seekErrors == 0` + ไม่มีเฟรมผิดเลย) · `testVideo_clockHook_seekDrivesVideo` มาตรฐานเดียวกัน (ทั้ง 2 โหมด, mid + boundary) · warm-up ที่ n=100 ไม่ใช่เวลาที่วัด · ที่เหลือเป็น strict expected failure เดียว (`element-hevc-open-gop`) · `testGSAP_playingTicker_firstFrameAtT0` ถอด expectation แล้ว assert 106.7±2 (GSAP tick แรก = 33 ms, ดูตาราง 1b) — **จุดนี้เป็นการเปลี่ยนค่าคาดหวังจาก 100±2 เพราะค่าเดิมขัดกับพฤติกรรมของ GSAP เอง; ปิ๊ก/main chat ตรวจได้**
- B. `run()` ใช้ pipe เดียว (stdout+stderr) · `videoPage` ไม่ถือ NSWindow เองแล้ว (Page เป็นเจ้าของ, `defer { page.close() }`, ถ้า setup throw จะ `close()` ก่อน) · เช็ก encoder แบบ whole-word (`libx264` ≠ `libx264rgb`) · `Probe.scratch` default = `SAFARIUM_PROBE_SCRATCH` หรือ `<tmp>/safarium-probe-scratch` · comment boundary เป็น "likely" · Focus probe: `osascript` ที่ตัว sampler รันเอง โผล่ในรายการ Dock-visible เป็นครั้งคราว (เจอ 1 ครั้ง → test เดิม fail) จึงกรองชื่อ `osascript` ออกจาก `dockApps` (ไม่ลดความไวต่อโปรเซสอื่น)
- Snapshot quality เทียบ `.fast` vs `.sharp`: `QualityCompareProbeTests` → ดูหัวข้อถัดไป

### Snapshot quality: `.fast` (1×) vs `.sharp` (2× + Lanczos)
90 เฟรม 1080×1920 H.264 20 Mbps (seek + snapshot + encode), หน้า `Fixtures/probes/quality-compare.html` (ไทย+อังกฤษ 14/24/48 px, เส้น 1 px, วงกลม/เส้นทแยง, รูป):
| รอบ | load avg 1 นาที | `.fast` | `.sharp` |
|---|---|---|---|
| เบา | 6.0 / 10 core | 5.3 ms/เฟรม (snapshot 2.8) | 49.8 ms/เฟรม (snapshot 46.9) |
| หนัก | 19.0 / 10 core | 6.2 ms/เฟรม (snapshot 3.3) | 68.5 ms/เฟรม (snapshot 64.1) |
PSNR(fast, sharp) = 30.2 dB · `.sharp` ช้ากว่า ~9–11× · default ยังเป็น `.fast` (รอปิ๊กเลือก) · ไฟล์เทียบ: ดู `quality-compare/` ใน scratch (`fast-1x-…png`, `sharp-2x-lanczos-…png`, `compare-4x-small-thai-text.png`, `compare-4x-thin-lines-circle.png`, `results.txt`)

## Core ต้องแก้ / ตัดสินใจ — บันทึกตอนค้นพบ (ข้อ 1–4 แก้แล้ว ดูหัวข้อด้านบน; ข้อ 5 รอปิ๊ก)

1. **`withTimeout` ไม่ตัดจริง** (`Page.swift`): ใช้ task group — `group.cancelAll()` ไม่ทำให้ `callAsyncJavaScript` ที่ค้างหยุด และ task group รอ child จบก่อนคืนค่า → `evaluate(timeout:)` / `load` / `waitFor` ค้างตลอดถ้า JS promise ไม่ resolve (เจอจริงตอน `<video>` ไม่โหลด; ข้อความ error ที่ได้เป็น `InvalidTransition … failed(deinit)` ตอนปล่อย Page). แก้: race ด้วย continuation (resume ครั้งเดียวจาก timer หรือจากผลจริง) แล้วปล่อย task เดิมค้างได้
2. **Clock ไม่ dispatch rAF ที่ t=0**: ticker ของ GSAP จะ dispatch ต่อเมื่อเวลาผ่าน ≥ 1/240 s → `seek(0)` ครั้งแรกได้หน้าที่ยัง *ไม่ render* (กล่องที่ x=0 ไม่ใช่ 100). แก้: ครั้งแรกหลัง load ให้ pre-roll rAF หนึ่งรอบที่ vt ≈ 5 ms (หรือ seek(0) รัน tick ซ้ำที่ vt เล็กน้อยแล้วย้อน) · ตอนนี้เป็น `XCTExpectFailure` ใน `testGSAP_playingTicker_firstFrameAtT0` (จะกลายเป็น error เมื่อแก้แล้ว)
3. **timers ที่ due=0 ไม่รันก่อน seek ครั้งแรก**: lottie โหลดผ่าน `setTimeout(0)` → `DOMLoaded`/`waitFor(.predicate)` ที่พึ่ง event นั้นจะไม่มีวันจริงก่อน `seek` (poll ค้างจนหมดเวลา) · workaround ใน fixture: อย่ารอ event ของไลบรารี ให้ `seek(0)` ก่อน · ข้อเสนอ: ให้ `load()` flush timers ที่ due ≤ 0 หลัง `didFinish` หรือจดใน `core-api.md`
4. **`<video>` + `videoSeekHook`** (ยังเป็น placeholder ใน `clock.js`):
   - `<video>` **ไม่โหลดเลย** ถ้า WKWebView ไม่ได้อยู่ใน NSWindow (`networkState=NO_SOURCE`, ไม่มี `loadstart`). ใช้ `NSWindow` borderless นอกจอ (`x=-20000`) + `orderBack(nil)` ใต้ policy `.prohibited` → โหลดได้, **ไม่แย่งโฟกัส** (ผ่าน probe 5 แบบไม่มีหน้าต่าง; หน้าต่างนี้เพิ่มเฉพาะ probe video — ต้องเช็กโฟกัสซ้ำถ้าจะใส่ใน core) → ควรมี option เช่น `PageConfig.attachHiddenWindow`
   - เลเยอร์ `<video>` **ไม่อยู่ใน `takeSnapshot`** (ได้พื้นขาว) → hook ต้อง `drawImage(video)` ลง `<canvas>` ที่มองเห็นในทุกเฟรม (ทำใน fixture แล้ว ได้เฟรมถูก)
   - Hook ที่ใช้ได้: `currentTime = t` → รอ `seeked` (ต้อง deadline ด้วย timer จริง เช่น `AbortSignal.timeout`, เพราะ `setTimeout` เป็นของเสมือน) → วาดลง canvas. ผ่าน `page.seek()` ครบ 8 เป้าหมายใน `testVideo_clockHook_seekDrivesVideo`
   - ความแม่น: ใช้ **t = (n+0.5)/fps** ไม่ใช่ n/fps — ที่ n/30 เป๊ะ 2/3 ของเฟรมได้ n−1 เพราะ n/30 ในเลขทศนิยมต่ำกว่า pts นิดเดียว (H.264 ทั้งสองแบบ: 20/60 ถูก ที่เหลือ −1) → เพิ่ม bias +0.25..0.5 เฟรมใน hook (ทดสอบ +0.25: 60/60)
   - **HEVC ไม่น่าไว้ใจ**: mid-frame 56–57/60 มีเฟรมเก่าค้าง (−13, −56, −107) แม้ H.264 เองก็เจอเฟรมเก่าค้างได้เป็นช่วงๆ เมื่อเครื่องโหลด (รอบแรกๆ ที่รันระหว่างงานอื่น random ผิดเกือบหมด) · รอ rVFC หลัง `seeked` ใช้ไม่ได้ (ไม่ยิงใน page ที่ไม่เห็น, 0–3/20) · settle 40 ms ไม่ช่วย (แย่กว่า) → **สรุป: ไม่รับประกัน frame-accurate; ใช้ทางของ HF (`hf-seek-video`: ffmpeg ถอดเฟรม → วางเป็นภาพ) ตามแผน** · assertion เป็น `XCTExpectFailure(isStrict:false)` เพราะผลแกว่งตามโหลดเครื่อง
5. **Snapshot 1× ต่างจาก supersample 2×** (PSNR 22 dB; ตัวอักษร/เส้นบาง 1× คมกว่าแต่ขอบหยาบกว่า): ถ้าเกณฑ์คือ "ใกล้ Chromium ที่ DPR2→ย่อ" ให้ render scale 2 แล้ว box-downsample (ราคา: snapshot 4× พิกเซล — **ยังไม่ได้วัดเวลา**) · ถ้า 1× ยอมรับได้ ไม่ต้องแก้ · **ปิ๊กต้องเลือกเกณฑ์** (แผนข้อ "ถามตอนจบ P1") · ตอนนี้ `XCTExpectFailure` (strict) ที่ PSNR≥30

## รายละเอียด Probe 2 (ตัวเลขรอบเต็มสุดท้าย, `SAFARIUM_PROBES=1`)

คลิป 640×360 30 fps 150 เฟรม เลขเฟรมเข้ารหัสเป็นบล็อก 16 บิต (กันบีบอัด) · วัดเฟรมที่เห็นจริงหลัง seek+drawImage+snapshot

| คลิป | mid-frame seq | mid-frame random | boundary t=n/30 seq | boundary random | +0.25 เฟรม random | ms/seek |
|---|---|---|---|---|---|---|
| H.264 intra-only | 60/60 | 60/60 | 20/60 (ที่เหลือ −1) | 18/60 (ที่เหลือ −1) | 60/60 | 5.1 |
| H.264 GOP 250 | 60/60 | 60/60 | 20/60 (ที่เหลือ −1) | 18/60 (ที่เหลือ −1) | 60/60 | 4.4 |
| HEVC GOP 60 | 56/60 | 57/60 | 19/60 | 17/60 | 57/60 | 4.5 |

Info-only (ไม่ assert): รอ settle 40 ms หลัง `seeked` แย่ลงทุกคลิป · รอ rVFC 0/20 ยิง

## รันซ้ำ

```bash
# Setup (ครั้งเดียว, ต้องมีเน็ต — ใช้ scratch ไม่ใส่ใน vault; MIT/OFL ยกเว้น GSAP "no charge" license จึงไม่ vendor)
S=<scratch>; mkdir -p $S/npm && cd $S/npm && npm i --prefix . gsap animejs lottie-web pixi.js three @fontsource/inter @fontsource/noto-sans-thai esbuild
# three.js ไม่มี UMD → bundle IIFE: esbuild three-entry.js --bundle --format=iife --minify --outfile=three.iife.js   (entry: import * as THREE from 'three'; window.THREE = THREE)
# คัดลอกไปที่ $S/probe-libs/: gsap.min.js anime.umd.min.js lottie.min.js pixi.min.js three.iife.js + inter-latin-{400,700}-normal.woff2 + noto-sans-thai-thai-{400,700}-normal.woff2
swift test                                                              # default: ~32 s, probe หนักถูก skip (.build เป็น symlink ไป ~/Library/Caches/Safarium/build)
SAFARIUM_PROBES=1 swift test --filter SafariumProbeTests               # เต็ม ~5 นาที (ต้อง ffmpeg + libx265 สำหรับ probe video)
```
ตัวแปร: `SAFARIUM_PROBE_SCRATCH` (path scratch; ไม่ตั้ง = `<tmp>/safarium-probe-scratch` ซึ่งไม่มี libs → probe library จะ skip), `SAFARIUM_FFMPEG` (path ffmpeg), `SAFARIUM_QUALITY_OUT` (โฟลเดอร์ผลเทียบ quality) · เวอร์ชัน: gsap 3.15.1, animejs 4.5.0, lottie-web 5.13.0, pixi.js 8.23.0, three 0.187.0

## หมายเหตุ

- ผลวัดความเร็ว (251 fps) ขึ้นกับเครื่องว่าง; ระหว่างวัดมี agent อื่นรันงานอยู่ด้วยบางช่วง → ใช้เป็นลำดับขนาด ไม่ใช่ benchmark
- Probe 5 ใช้ System Events (ต้องได้สิทธิ์ Automation; ถ้าอ่านไม่ได้ test จะ skip/ fail ด้วยข้อความชัด)
- ไม่ได้วัด `powermetrics`/พลังงาน (ต้อง sudo → ถามปิ๊กก่อน)

