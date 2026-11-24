---
tags: [safarium, benchmark, experiment, native, metal, coretext]
note_type: experiment
project: "Safarium"
created: 2026-11-21
updated: 2026-11-21
---

# Native engine spike — คอขวดอยู่ที่ "การตีความฉาก" ไม่ใช่ "การวาด"

> **คำถาม:** ถ้าทิ้ง WebKit แล้วเขียนเรนเดอร์เอง (Metal + CoreText) จะเร็วกว่าไหม และคอขวดจะอยู่ที่ไหน
> **สถานะ:** exploratory spike (ไม่ใช่ส่วนของ protocol ที่ล็อก) · วัดบน M5 ขณะเครื่องมี load 8–10 (งานเรนเดอร์ของ session อื่น) → **ตัวเลขเป็นฝ่ายเพี้ยน (pessimistic)** เพราะรันบนเครื่องไม่ว่าง
> โค้ด: `bench/experiments/native-spike/main.swift` (คอมไพล์แยกด้วย swiftc ไม่แตะ `Package.swift`)

## 1. ทำอะไร

วาดฉากเดียวกับ `fixtures/pairs/text-card` (พื้นหลัง + เส้นทอง + ข้อความไทย 4 บรรทัด + ตัวเลข 220px) ที่ 1080×1920 แล้วเขียนเป็น H.264 ผ่าน `AVAssetWriter` เหมือน Safarium

| โหมด | ต่อเฟรมทำอะไร |
|---|---|
| `cpu` | CoreText raster ลงใน **memory ของ pixel buffer ตัวเดียวกับที่ encoder ใช้** → `adaptor.append` (เขียนทับตรง ไม่มี readback) |
| `gpu` | Metal วาดเฟรม (เต็มจอ) ลงใน texture ของ pixel buffer → `adaptor.append` |
| `both` | สลับสองโหมดเฟรมต่อเฟรม (A/B ในโปรเซสเดียว → เทียบกันได้แม้เครื่องไม่ว่าง) |

## 2. ผล (120 เฟรม, สลับ A/B)

| ขั้นตอน | โหมด CPU | โหมด GPU |
|---|---:|---:|
| render | **0.75 ms** (p05 0.58) | 1.08 ms (p05 0.68) |
| append (แรงดันจาก encoder) | 2.84 ms | 2.58 ms |
| **รวม** | **3.66 ms/เฟรม** | **3.66 ms/เฟรม** |

**เทียบกับ WebKit (snapshot ของ fixture เดียวกัน):**

| เส้นทาง | ms/เฟรม | หมายเหตุ |
|---|---:|---|
| WebKit + takeSnapshot (text-card) | **9.93** | pilot 2026-11-21 |
| WebKit + takeSnapshot (EP30 จริง) | **46.2** | งานจริงที่มี SVG หนัก |
| **Native CPU text (spike นี้)** | **3.66** | ~2.7× เร็วกว่า WebKit ที่ฉากข้อความ |
| Native GPU composite (spike นี้) | 3.66 | เร็วเท่ากัน — เพราะ encode คือคอขวด |

## 3. ข้อสรุปที่สำคัญที่สุด

1. **การ raster ไม่ใช่คอขวดของ native engine** — โหมด GPU (1.08 ms) แทบไม่เร็วกว่าโหมด CPU (0.75 ms) เพราะทั้งคู่ชนกับ **encoder** (append ~2.6–2.8 ms) และฉากนี้มีแค่ข้อความ
   → ถ้าจะได้ประโยชน์จาก GPU ต้องมีฉากที่ "วาดเยอะ" (เช่น SVG/แอนิเมชันเยอะ) ไม่ใช่แค่ข้อความ
2. **ข้อได้เปรียบเชิงโครงสร้างของ native path** = เขียนทับ memory ของ pixel buffer ตรง ๆ → **ไม่มี readback 8.3 MB/เฟรม** (WebKit ต้อง takeSnapshot → NSImage → CGImage → readback) — นี่คือข้อได้เปรียบที่โครงสร้าง ไม่ใช่เรื่องโชค
3. **คอขวดของ native engine คือ "การตีความฉาก"** — ต้องทำ layout (flex/grid/position), animation timeline (GSAP/WAAPI), SVG path, gradient, shadow, filter ให้เอง ซึ่ง WebKit ให้มาฟรี ตัวเลขข้างบนบอกว่า *ถ้า* ทำได้ การวาดจะไม่ใช่ปัญหา
4. **วิดีโอ:** WebKit โหลด `<video>` ไม่ได้ในโหมด offscreen (readyState 0) → native engine ชนะโดยค่าเริ่มต้น เพราะ decode ด้วย AVFoundation เอง

## 4. คุณภาพเทียบ (native vs WebKit, fixture เดียวกัน)

เรนเดอร์ native ออกมาเทียบกับเฟรม WebKit ที่สถานะ animation เดียวกัน (เฟรม 126 ของ 300) → **SSIM 0.944 / PSNR 18 dB** แต่ **ด้วยตาดูเหมือนกัน** — สาเหตุที่ SSIM ต่ำคือ (ก) ตัวเลข "42" ของฝั่ง native ชิดซ้าย 30 px (WebKit ชิดขวา) (ข) AA ของ glyph ต่างกัน (CoreText vs WebKit) (ค) เงา/leading ต่างกันเล็กน้อย
→ **ยังพิสูจน์ความเท่ากันระดับพิกเซลไม่ได้** ต้องมี layout engine จริงก่อน (spike นี้วางด้วย CTFrame ใส่กรอบกว้างตาม CSS เท่านั้น)

## 5. ข้อจำกัด

- วัดบนเครื่องที่ load 8–10 → ตัวเลขจะ **ดีขึ้น** เมื่อรันตอนเครื่องว่าง (ต้องรันซ้ำหลัง Stage A)
- ฉากนี้**ไม่มี animation** → engine จริงต้อง evaluate timeline ต่อเฟรม (WebKit ใช้ 1.24 ms/เฟรม สำหรับ EP30 → เล็กน้อยเมื่อเทียบกับ 46 ms)
- โหมด GPU วาด "gradient + สี่เหลี่ยม" เป็นตัวแทน ไม่ใช่ฉากจริง
- ยังไม่ครอบคลุม: SVG path, gradient, shadow, filter, `<video>`, WebGL

## 6. คำสั่ง

```sh
swiftc -O bench/experiments/native-spike/main.swift -o "$TMPDIR/native-spike"
"$TMPDIR/native-spike" --mode=both --frames=120 --out=/tmp/native.mp4
```
