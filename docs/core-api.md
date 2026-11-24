---
tags: [safarium, reference, swift]
note_type: reference
project: "Safarium"
created: 2026-11-21
updated: 2026-11-21
---

# SafariumCore — Core API (P1 D+E)

Swift package `Projects/Safarium/` · library `SafariumCore` · macOS 14+ · ไม่มีหน้าต่าง ไม่แย่งโฟกัส (`HostApp.prepare()` = `.prohibited`; `Page.init` เรียกให้เอง)
ทดสอบ: `swift test` (default, ไม่ต้องมีเน็ต/ffmpeg) · probe หนัก opt-in `SAFARIUM_PROBES=1` (ดู probe-results.md) · `.build` เป็น symlink ไป `~/Library/Caches/Safarium/build`

## Page (`@MainActor`)
```swift
let page = try await Page(config: PageConfig(width: 1080, height: 1920, scale: 1, transparent: false, deterministicClock: true,
                                             video: .none, snapshotQuality: .fast))
try await page.load(.fileURL(url))            // .url(URL) | .fileURL(URL, readAccess:) | .html(String, baseURL:)
try await page.waitFor(.fonts)                // .readyState | .fonts | .images | .selector(css) | .predicate(jsExpr)
let v = try await page.evaluate("return a+b", arguments: ["a":1,"b":2])   // async function body
let w = try await page.evaluate(expression: "fetchSomething()")           // awaited expression
try await page.seek(1.5, step: 1.0/30)        // virtual clock (needs deterministicClock)
let snap = try await page.snapshot()          // exactly (w*scale)x(h*scale) px
page.setViewport(width:height:scale:)
page.close()                                  // ปล่อย hidden window (video: .element) — เรียกซ้ำได้
```
- ทุกคำสั่งมี `timeout` (load/evaluate default 30 s) → `SafariumError.timeout`; JS throw → `.javascript(msg)`
- **timeout ตัดจริง**: `withTimeout` เป็น continuation-based race (ไม่ใช่ task group) → `evaluate(timeout:)` กับ promise ที่ไม่เคย settle จะ throw `.timeout("evaluate")` ตรงเวลา, task เดิมถูก cancel แล้วปล่อยทิ้ง (ผลที่มาทีหลังถูกเมิน), Page ใช้งานต่อได้
- `load()` ที่ใช้ `deterministicClock` จะ flush timers ที่ due ที่เวลาเสมือน 0 (เช่น `setTimeout(fn, 0)` ของ lottie/loader) ก่อน return → `waitFor` ที่รอ event ของไลบรารีไม่ค้างอีก (timers ที่ due > 0 ยังไม่รันจนกว่าจะ `seek`)
- charset: `.html(String)` ส่งเป็น UTF-8 เสมอ · `.fileURL` ที่เป็น html ไม่มี `charset`/BOM → บังคับ UTF-8 (โหลดเป็น data + baseURL=ไฟล์ ; subresource แบบ relative ของไฟล์ที่ไม่มี meta ยังไม่ได้ทดสอบ) · ไฟล์มี `<meta charset>` ใช้ `loadFileURL` ตามปกติ
- `transparent: true` → `drawsBackground=false` (alpha ใน snapshot)
- **ข้อจำกัดที่เจอ**: `.fileURL` ของ html ที่ไม่มี `<meta charset>`/BOM ถูกโหลดเป็น data (บังคับ UTF-8) → subresource แบบ relative (รูป/วิดีโอ) **โหลดไม่ได้** (วิดีโอ NO_SOURCE) · ใส่ `<meta charset="utf-8">` ในไฟล์ที่มี subresource (ยังไม่ได้แก้ใน core)
- scale: pixel ออก = viewport × scale ; snapshot calibrate backing scale เองครั้งแรก แล้ว normalize เป็นขนาดเป๊ะ

## Snapshot
`SnapshotQuality`: `.fast` (default — WebKit rasterise ที่ขนาดออกเลย) · `.sharp` (render 2× แล้ว Lanczos ด้วย Core Image ลงเป็นขนาดเป๊ะ; ช้ากว่า ~9× บนเครื่องวัด: 5.3 → 49.8 ms/เฟรม 1080×1920 ดู probe-results) — ปิ๊กยังไม่เลือก จึงไม่เปลี่ยน default
`width/height` · `bgra()` (premultiplied BGRA, แถวบนสุดก่อน) · `pixel(x:y:)` · `pngData()` · `jpegData(quality:)` · `cgImage`

## FrameSink
```swift
protocol FrameSink { func append(_ frame: Snapshot) async throws; func finish() async throws }
AVAssetWriterSink(url:width:height:fps:codec:bitrate:quality:)   // codec: .h264 .hevc .hevcAlpha .proRes422 .proRes4444
ImageSequenceSink(directory:format: .png | .jpeg(quality:))      // frame_00000.png
```
- timestamp = index/fps · pixel-buffer pool ของ adaptor · backpressure รอ `isReadyForMoreMediaData` · ต้องเรียก `finish()` ครั้งเดียว
- h264/hevc → `.mp4` ; ที่เหลือ `.mov` · `bitrate` ใช้กับ h264/hevc ; `quality` (0–1) กับ hevc
- **ProRes 4444 alpha**: ผ่านเทสต์ (pixel (0,0) = 0,0,0,0) แต่ codec ปัดค่า alpha 255→254 ตอนถอดกลับ · **HEVC-alpha**: ยืนยันแล้ว (P1-F) — FourCC `hvc1`, `ContainsAlphaChannel`=true, track characteristic=true, มุมโปร่ง a=0, กล่อง 50% a≈128 (premultiplied)

## VirtualClock (`Resources/clock.js`, WKUserScript atDocumentStart, ทุก frame)
แทน `Date`/`Date.now`/`performance.now`/`document.timeline.currentTime`/rAF+cancel/setTimeout/setInterval/clear*/requestIdleCallback ; `queueMicrotask` ไม่แตะ ; เวลาเริ่ม = 2024-01-01T00:00:00Z (คงที่ → deterministic)
`seek(t)` ทำตามลำดับ: (seek แรกเท่านั้น: **pre-roll** rAF 1 รอบที่ +5 ms เสมือน แล้วเวลากลับมาที่ target — ticker แบบ GSAP ที่ dispatch เมื่อผ่าน ≥ 1/240 s จึง render ที่ `seek(0)` แล้ว; GSAP เองนับ tick แรกเป็น 33 ms (lag smoothing) → เฟรมแรกของ tween = 100 + 600/3×0.0333 ≈ 106.7 ไม่ใช่ 100) → timers ที่ถึงเวลา (เรียงตาม due, timer ที่สร้างใน timer ก็รันถ้า due ≤ t) → `getAnimations()` pause + `currentTime = (t − เวลาเริ่ม animation) × rate` → `window.__seek(t)` และ `window.__hf.seek(t)` ถ้ามี (await) → rAF callbacks (ได้ timestamp = t) → flush microtask → seek อีกรอบ → `<video>` (ดูหัวข้อ Video)
- เวลาเดินหน้าอย่างเดียวสำหรับ timers (seek ถอยหลัง = animation/page hook เท่านั้น) · pre-roll ทำให้ rAF callback ถูกเรียก 1 ครั้งเพิ่มที่ t=+5 ms ก่อน seek แรก
- ไลบรารีที่มี lag smoothing (GSAP: เกิน 500 ms นับเป็น 33 ms) → ใช้ `seek(t, step: 1/fps)` หรือ seek ทีละเฟรม
- timer วนไม่รู้จบใน 1 step (> 100,000) → throw
- iframe ได้ clock ของตัวเอง แต่ `seek` ขับเฉพาะ main frame

## Video (`PageConfig.video: VideoMode`, ต้องใช้ `deterministicClock`)
`takeSnapshot` **ไม่มี layer ของ `<video>`** → ทุก seek core วาดเฟรมลง `<canvas>` ซ้อนบน video (ก๊อป style/ตำแหน่ง/transform/object-fit; `data-sf-video-overlay`). กฎเวลา: เฟรมที่แสดง = เฟรม k = `floor(t × fps + 0.001)` ของวิดีโอ แล้ว seek ไปกลางเฟรม `t0 + (k+0.5)/fps` (t0 = pts เฟรมแรก; fps snap เป็นจำนวนเต็ม/NTSC) → `seek(n/fps)` ได้เฟรม n เป๊ะ (เดิมที่ `n/30` ตรงๆ ~2/3 ได้ n−1 เพราะทศนิยม)

| โหมด | ทำงานยังไง | ใช้เมื่อ | ข้อจำกัด |
|---|---|---|---|
| `.none` (default) | ไม่ทำอะไร (วิดีโอว่างใน snapshot) | ไม่มี `<video>` | — |
| `.element` | Page สร้าง NSWindow borderless **นอกจอ** (x,y ≈ −20000, `orderBack` ไม่เคย front/key, app `.prohibited` ไม่ active) เพราะ `<video>` ไม่โหลดถ้าไม่อยู่ใน window; `inactiveSchedulingPolicy = .none` (ไม่งั้น WebKit suspend หน้าที่ occluded แล้ว video ค้างเฟรมเดียวหลัง ~235 seek); `currentTime` → รอ `seeked` (deadline เวลาจริง 3 s) → `drawImage` | วิดีโอ H.264 ที่ไม่อยากถอดเฟรมนอก page | H.264 วัดแล้วเป๊ะ (intra + GOP 250 ใน probe) แต่ **ขึ้นกับโหลดเครื่อง**: ตอนโหลดสูงเคยเจอเฟรมเก่า 2 จาก 450 seek สุ่ม (ไม่รับประกัน — ต้องเป๊ะแน่นอนใช้ `.extract`) · **HEVC open-GOP: 4 เฟรม leading ก่อน CRA (เช่น 56–59, 116–119) แสดงไม่ได้หลัง seek → ใช้ `.extract`** (named gap `element-hevc-open-gop`, strict expected failure ใน probe) · ต้องเรียก `page.close()` |
| `.extract` | ถอดเฟรมใน Swift (`AVAssetImageGenerator` zero tolerance; ถ้า "Cannot Decode" → `AVAssetReader` เริ่มอ่านถอยหลัง 16 เฟรมแล้ววนไปถึงเฟรม) ส่งกลับเป็น PNG data URL ผ่าน `WKScriptMessageHandlerWithReply` (`sfVideo`) แล้ววาดลง canvas | HEVC / ต้องการเป๊ะทุก codec / ไม่ต้องมีหน้าต่าง | แหล่งต้องเป็น `file:` URL · ช้ากว่า (≈ 20–40 ms/seek ที่ 640×360; PNG 1080p หนักกว่านั้น) · ไม่รองรับ loop/playbackRate/offset ของ element (core ถือ `<video>` เป็น "แสดงเฟรมที่เวลา t") |

- error ไม่เงียบ: โหลดไม่ได้/เฟรมถอดไม่ได้ → `page.seek` throw `.javascript("video: …")`
- page เขียน hook เองได้: `window.__sfClock.videoSeekHook = async (video, tSec) => {}` (ถ้าตั้ง จะแทนที่ built-in)
- โฟกัส: probe `testElementVideoMode_hiddenWindow_noFocusSteal` (150 seek, window จริง): lsappinfo front ไม่เปลี่ยน, window key=false, app active=false, policy=prohibited (System Events ได้แค่ 2 ตัวอย่างในรอบสั้นนี้ — หลักฐานหลักคือ lsappinfo 51 ตัวอย่าง + ผล probe 5 เดิม)

## ตัวเลข (เครื่องนี้, 1080×1920 H.264 20 Mbps, 90 เฟรม, หน้า clock.html)
ดู log ของงาน / `PerfTests` — ข้อความ `PERF ...` ถูก print ทุกครั้งที่รัน

