---
tags: [safarium, decision, native, engine, roadmap]
note_type: proposal
project: "Safarium"
created: 2026-11-21
updated: 2026-11-21
---

# Native engine — ลงทุนไหม? (memo สำหรับปิ๊ก)

> **คำถาม:** หลังพิสูจน์แล้วว่า WebKit แบบ offscreen ใช้ CPU ล้วนและไม่มีทางให้ GPU (ดู `docs/snapshot-anatomy-2026-11-21.md`) จะตัดสินใจลงทุนเขียนเรนเดอร์เอง (Metal + CoreText) หรือไม่
> **สถานะ:** ข้อเสนอ (ยังไม่ตัดสิน) · ตัวเลขมาจาก `docs/native-engine-spike.md` (spike 120 เฟรม, A/B ในโปรเซสเดียว, เครื่องมี load 8–10 → ตัวเลขเป็นฝ่ายเพี้ยน) และ `docs/x9-headline.md`

## 1. ตัวเลขที่ตัดสินใจ

| เส้นทาง | ms/เฟรม (1080×1920) | หมายเหตุ |
|---|---:|---|
| WebKit + takeSnapshot (text-card) | 9.93 | pilot |
| WebKit + takeSnapshot (EP30 จริง, SVG หนัก) | 46.2 | งานจริงของปิ๊ก |
| **Native CPU text (spike)** | **3.66** | CoreText 0.75 + encoder 2.84 |
| Native GPU composite (spike) | 3.66 | GPU 1.08 — ไม่ชนะโหมด CPU ตอนนี้ |

เทียบกับ pipeline ปัจจุบัน (HyperFrames + Chromium + ffmpeg): **184 s ต่อ 300 เฟรม = 613 ms/เฟรม** → WebKit ชนะ 11.5× แล้ว

## 2. ตัวเลขพิสูจน์ "เร็วพอ" แต่ไม่ได้พิสูจน์ "คุ้ม"

### 2.1 ขนาดงานจริง: native engine ต้องทำอะไรบ้าง (วัดจากคอมโพสิชันจริง 30 ตอน)

`bench/features.py` สแกนคอมโพสิชันจริงทั้งหมด (ประเทศโปแลนด์ 30 ตอน + kit.css + kit.js) ได้:

| ฟีเจอร์ | จำนวนครั้งที่ใช้ | ผลต่อ native engine |
|---|---:|---|
| `position: absolute/fixed` | 1,350 | ต้องมี layout แบบ absolute |
| **flex** (display:flex + ตัวคุม) | 1,020 | **ต้องเขียน flexbox layout** |
| **SVG path** | 1,302 | **ต้อง raster เส้น SVG** (คอขวด 55% ของ WebKit ด้วย) |
| SVG circle/ellipse + `<use>`/`<g>` | 451 + 593 | ต้องมี shape ทั้งหมด |
| SVG text | 246 | ต้องทำ text ใน SVG |
| opacity / transform | 780 / 390 | ต้องมี layer + composite |
| CSS variables / `calc()` | 750 / 570 | **ต้องมีตัวแก้ CSS variables + calc** |
| box-shadow / border-radius | 570 / 420 | ต้องทำเงา + มุมโค้ง |
| linear/radial gradient | 90 / 180 | ต้องทำ gradient |
| clip-path | 210 | ต้องทำ clip path |
| CSS filter | 30 | ต้องทำ filter (แพงมากบน CPU — §2.2 ของ anatomy) |
| `@font-face` (เว็บฟอนต์) | 120 | ต้องโหลดฟอนต์ + shaping ไทย |
| GSAP (`kit.js` + `gsap.min.js`) | ทุกตอน | **ต้องมี animation runtime** (หรือแปลง timeline เป็นคำสั่งของเราเอง) |

**ไม่มีในคอมโพสิชันเหล่านี้เลย:** `<video>`, `<canvas>`, WebGL → **คอมโพสิชันหลักของปิ๊ก (ประเทศโปแลนด์) ไม่ต้องการ hybrid video path**
→ ต้องเขียน: flexbox + absolute layout + SVG (path/circle/use/text) + gradient + shadow + clip-path + filter + CSS variables/calc + เว็บฟอนต์ + shaping ไทย + animation runtime = **mini browser** ล้วน ๆ (ไม่ใช่ "แค่ Metal")

### 2.2 แล้วความเร็วที่เหลือต้องการจริงไหม

สำหรับคอมโพสิชันหลัก: WebKit ใช้ 46 ms/เฟรม = 1.4× เวลาจริง (เรนเดอร์แบบ offline) เทียบกับ pipeline ปัจจุบัน 18× เวลาจริง → **เร็วพอแล้วสำหรับงาน 30 ตอน**
ที่ native engine จะมีค่าคือ (ก) คอมโพสิชันที่มีวิดีโอ (โปรเจกต์อื่น X1–X10) (ข) 4K/60fps (ค) เรนเดอร์จำนวนมากพร้อมกัน


- การ **วาด** ไม่ใช่คอขวด (0.75 ms) → ถ้ามี layout engine แล้ว ความเร็วจะได้จริง
- แต่สิ่งที่ต้องเขียนเองคือ **การตีความฉาก**: layout (flex/grid/position), animation timeline (GSAP/WAAPI/rAF), SVG path, gradient, shadow, filter, blend mode, ฟอนต์ไทย + shaping
- ค่าใช้จ่ายที่แท้จริงอยู่ที่นั้น ไม่ใช่ที่ Metal
- โครงการนี้ต้องเรนเดอร์ **composition ของ HyperFrames จริง** (GSAP + SVG + gradient + filter + ฟอนต์ไทย) → "เขียน mini browser" = งานใหญ่กว่าที่ตัวเลขชี้

## 3. ทางเลือก

| ทาง | ได้อะไร | เสียอะไร | ขนาดงาน |
|---|---|---|---|
| **A. อยู่กับ WebKit + จูน** | workers ขนาน (Stage A จะวัด) · ลด SVG/filter · คำแนะนำการเขียน composition · เพดาน ~15–20 ms/เฟรม (สมมติว่า scale ได้) | ไม่มี GPU · **โหลด `<video>` ไม่ได้** เลย (N/A) | ต่ำ (ทำไปครึ่งทางแล้ว) |
| **B. Native engine เต็ม** | เร็วมาก (~4–8 ms) · GPU จริง · decode วิดีโอเอง · alpha ง่าย | ต้องเขียน layout/animation/SVG เอง = mini browser | สูงมาก |
| **C. Hybrid: ใช้ AVFoundation ถอดวิดีโอ + WebKit วาดฉาก** | **แก้ช่องว่างที่ทำให้ฉากวิดีโอ N/A** โดยไม่ต้องเขียน layout | ต้อง patch เฟรมวิดีโอเข้าฉาก (ต้นแบบมีแล้ว: `VideoMode .extract`) · **ต้องใช้ `AVAssetReader` ไม่ใช่ `AVAssetImageGenerator`** (1.14 vs 37.05 ms/เฟรม) | กลาง |
| **D. เปลี่ยนไปใช้ Chromium** | ได้ความสามารถทั้งหมดของเบราว์เซอร์ | **ผิดข้อตกลงของโปรเจกต์** (ห้ามใช้ Chrome) และช้ากว่า 11.5× | — |

## 4. ข้อเสนอ

**ทำ C ก่อน แล้วค่อยตัดสินเรื่อง B** เหตุผล:

1. **ช่องว่างที่ทำให้คุณค่าต่ำที่สุดตอนนี้คือ "ความสามารถ" ไม่ใช่ "ความเร็ว"** — pipeline ปัจจุบันช้ากว่า Safarium 11.5× แล้ว และ 46 ms/เฟรม = 1.4× เวลาจริง (พอสำหรับเรนเดอร์ offline) · แต่ฉากที่มีวิดีโอยังทำไม่ได้เลย → งานที่ให้คุณค่าคือทำให้ฉากวิดีโอได้ ไม่ใช่ทำให้เร็วกว่า 46 ms
   *(หมายเหตุ: §2.1 พบว่าคอมโพสิชันหลักของปิ๊กไม่มีวิดีโอเลย → hybrid video path สำคัญกับโปรเจกต์อื่น X1–X10 มากกว่า)*
2. **C ใช้ของที่มีอยู่แล้ว**: `AVAssetImageGenerator` (decode นอกหน้าเว็บ, frame-exact, ทุก codec ที่ AVFoundation อ่านได้) + overlay `<canvas>` ในหน้า → ไม่ต้องแตะ layout
3. **B ยังไม่คุ้มเพราะต้นทุนอยู่ที่การตีความฉาก ไม่ใช่ที่การวาด** และตัวเลขที่วัดได้วันนี้ไม่ได้บอกว่า mini browser จะเสียเวลากี่เดือน
4. เมื่อ **C เสร็จและฉากวิดีโอทำได้** แล้ว ถ้าความเร็วยังเป็นคอขวดของงานจริง (EP30 = 46 ms) → ค่อยตัดสิน B โดยมีตัวเลข: native ~4–8 ms vs WebKit ~15–46 ms

## 5. เงื่อนไขที่จะทำให้ข้อเสนอนี้กลับด้าน

- ถ้า Stage A ชี้ว่า **workers ไม่ scale** (ทุก worker แย่ง core เดียวกัน) → เพดานคงที่ที่ ~46 ms → B น่าสนใจขึ้นมาก
- ถ้างานจริงของปิ๊กต้องเรนเดอร์ที่ **≥ 4K หรือ 60 fps** → 46 ms ไม่พอ → B จำเป็น
- ถ้าต้องการ **เรนเดอร์ฉากที่มี WebGL/canvas ซับซ้อน** → B หรือ C+WebGPU

## 6. สิ่งที่ต้องวัดต่อ (ยังไม่มีตัวเลข)

| คำถาม | วัดที่ไหน |
|---|---|
| workers=4 scale จริงไหม | Stage A (cells workers 1/4) |
| ฉากวิดีโอทำได้เร็วแค่ไหน | C (โหมด .extract) |
| native spike ตอนเครื่องว่าง | รันซ้ำหลัง Stage A |
| คะแนนรวม (speed/energy/quality/footprint) | `bench/poststage.sh` → `analyze.py score` |
