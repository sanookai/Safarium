---
tags: [safarium, webkit, capability, research]
note_type: reference
project: "Safarium"
created: 2026-11-21
updated: 2026-11-21
---

# Safari / WebKit Max-Out Map

> เป้าหมาย: รีดความสามารถของ WebKit บน macOS ให้สุด โดยไม่แตะหน้าต่าง Safari ของปิ๊ก และไม่ใช้ private API
> สถานะ: ✅ วัดแล้วในโค้ดโปรเจกต์ · 🟡 มีเอกสาร/ยังไม่ทดสอบ · ❓ ไม่รู้ · ❌ ใช้ไม่ได้

## 1. ตารางความสามารถ

| # | ความสามารถ | สถานะ | ใช้ยังไง | ผล/หลักฐาน | งานทดสอบ |
|---|---|---|---|---|---|
| 1 | `takeSnapshot` + `snapshotWidth` (point = 2×) | ✅ | จับภาพความละเอียดเต็มโดยไม่ encode | `docs/core-api.md` · PerfTests | P1-D |
| 2 | ไม่มีหน้าต่าง (`NSApplication .prohibited`) | ✅ | ไม่แย่งโฟกัส | `Host.swift` | P1-F `lsappinfo front` |
| 3 | `drawsBackground=false` (alpha) | ✅ | พื้นโปร่งใส | CoreTests | P1-F |
| 4 | VirtualClock (Date/perf/rAF/timers/WAAPI) | ✅ | seek ตรงเวลา deterministic | `clock.js` · ClockTests | P1-E |
| 5 | WebGL2 บน Apple GPU | ✅ | Pixi/three เดิม | probe tests | P1-F |
| 6 | CoreText ไทย (Thonburi) | ✅ | ข้อความคม ไม่ fallback | probe | P1-F |
| 7 | AVAssetWriter H.264/HEVC | ✅ | เข้ารหัสฮาร์ดแวร์ | PerfTests | P1-D |
| 8 | ProRes 4444 + alpha | ✅ | มาสเตอร์โปร่งใส | CoreTests (`yuva444p12le`) | P1-F ตรวจ decode |
| 9 | HEVC with alpha | ✅ | ไฟล์เล็กกว่า alpha มาก | XCTest `containsAlphaChannel=true`, มุม a=0, กลาง a=128; finish 0.030 s vs ProRes 4444 52–69 s | P1-F (2026-11-21) |
| 10 | WebGPU (Safari 26+) | 🟡 | compute/effect หนัก | ยังไม่ทดสอบใน WKWebView | W1–W6 |
| 11 | WebCodecs VideoDecoder | 🟡 | ถอดวิดีโอแม่นเฟรม | docs | W4 |
| 12 | WebCodecs VideoEncoder (hw) | ❓ | อาจแทน ffmpeg | ไม่ยืนยัน | W1 |
| 13 | OffscreenCanvas | 🟡 | วาดนอก main thread | docs | W3 |
| 14 | `WKURLSchemeHandler` | 🟡 | เสิร์ฟ asset จาก memory | ยังไม่ใช้ | P1-F |
| 15 | Pre-warm WKWebView pool | 🟡 | ลด cold start | ยังไม่วัด | P2 |
| 16 | AVAudioEngine offline render | 🟡 | mix เสียงไม่ใช้ ffmpeg | ยังไม่ทดสอบ | P2 |
| 17 | Metal / CARenderer offscreen | 🟡 | native engine | spike | R1 |
| 18 | `os_signpost` + `powermetrics` | ✅/🟡 | วัดเวลา/พลังงาน | ยังไม่ผูกใน harness | R1 |
| 19 | `<video>` seek (`requestVideoFrameCallback`) | ❌ | วิดีโอในฉาก | **โหลดไม่ได้เลย** ใน WKWebView ไม่มีหน้าต่าง: `readyState 0`, `networkState 3 (NO_SOURCE)`, `duration -1` → hook ค้าง ต้องมี timeout | P1-F (2026-11-21) |
| 20 | HLS/CMAF segment writer | 🟡 | output ซับซ้อน | docs macOS 11+ | P4 |
| 21 | `<video>` decode แบบ offscreen | ❌ | — | ต้องมี window หรือใช้ WebCodecs/AVPlayer แทน | W4 / native engine |

## 2. สิ่งที่ห้ามใช้ / ไม่คุ้ม

| วิธี | ทำไม |
|---|---|
| `CGWindowListCreateImage` | obsolete macOS 15 |
| ScreenCaptureKit | ต้อง TCC + ต้องมี window · ช้ากว่า snapshot |
| Playwright WebKit เป็น core | แพ็กเกจ WebKit ของเขา ไม่ใช่ของระบบ |
| private API / KVC เปิด feature | เสี่ยงพังเมื่อ macOS อัปเดต |
| `drawHierarchy(in:)` | ช้ากว่า `takeSnapshot` |
| JPEG/PNG intermediate | วัดแล้วแพง ~10 ms |
| เปิดหน้าต่าง Safari จริง | ผิดกฎโปรเจกต์ |

## 3. ลำดับการรีด (ตามผลที่คาด)

1. **ตัด intermediate codec** — snapshot → CVPixelBuffer → AVAssetWriter (ได้แล้ว)
2. **Pipeline คู่** — snapshot เฟรม N+1 ทับ encode เฟรม N
3. **หลาย worker** — N WKWebView คนละ process
4. **Zero-copy/format** — BGRA ตรง, pool, ไม่แปลงสี
5. **Native engine** — งานกราฟิกง่ายไม่ต้อง parse HTML
6. **WebGPU** — เฉพาะฉาก effect ถ้า W6 ผ่าน 15%

## 4. ความเสี่ยงที่ต้องจับตา

- WebGPU ใน WKWebView อาจต้องเปิด feature flag ที่ไม่ public → ถ้าไม่ผ่าน ให้ตัดออก
- WebCodecs VideoEncoder อาจไม่มี hardware → ห้ามอ้างจนวัด
- offscreen WKWebView อาจหยุด repaint ในบาง macOS build → ทดสอบทุก beta
- 4 workers อาจชน GPU/encoder → หาจุดอิ่มตัว ไม่ใช่ยิ่งมากยิ่งดี

