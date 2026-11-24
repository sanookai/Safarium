---
tags: [safarium, experiment, video, avfoundation]
note_type: experiment
project: "Safarium"
created: 2026-11-21
updated: 2026-11-21
---

# Hybrid video path — ถอดเฟรมวิดีโอแบบไหนถึงไหว

> **คำถาม:** WKWebView โหลด `<video>` ไม่ได้ในโหมด offscreen (readyState 0) → ฉากที่มีวิดีโอทำไม่ได้เลย ทางแก้คือถอดเฟรมด้วย AVFoundation แล้ว patch เข้าฉาก (`VideoMode .extract`) — **แต่ต้องถอดแบบไหนถึงจะไหว 30 fps**
> **สถานะ:** exploratory spike · วัดบน M5 ขณะเครื่องมี load 6–9 → ตัวเลขเป็นฝ่ายเพี้ยน (สัดส่วนใช้ได้)
> โค้ด: `bench/experiments/video-decode-spike/main.swift` · ไฟล์ทดสอบ: `fixtures/pairs/video-embed/assets/sample.mp4` (2 s, 1080×1920)

## 1. ผล

| วิธีถอดเฟรม | ms/เฟรม (median) | p95 | หมายเหตุ |
|---|---:|---:|---|
| **สุ่มเข้าถึง** `AVAssetImageGenerator.copyCGImage` (tolerance = 0, frame-exact) | **37.05** | 52.18 | seek ใหม่ทุกครั้ง + decode ใหม่จาก keyframe ใกล้สุด → **ช้าเกิน 30 fps ไป 3 เท่า** |
| **เรียงเวลา** `AVAssetReader` (อ่านครั้งเดียวตามลำดับ) | **1.14** | 4.35 | decode ต่อเนื่อง 1 พาส → **เร็วพอสำหรับ 30 fps (มี headroom ~8×)** |

(เครื่องมี load → ตัวเลขทั้งคู่สูงกว่าปกติ แต่ **อัตราส่วน 32× คือผลของโครงสร้าง ไม่ใช่ของ noise**)

## 2. ข้อสรุปสำหรับการลงมือ

1. **ต้องใช้ `AVAssetReader` (เรียงเวลา) ไม่ใช่ `AVAssetImageGenerator` (สุ่มเข้าถึง)** สำหรับ path ที่เรนเดอร์วิดีโอ — เพราะการเรนเดอร์เดินเวลาไปข้างหน้าอยู่แล้ว
2. ถ้าต้อง frame-exact ก็ยังทำได้ด้วย `AVAssetReader`: เดิน reader ถึงเฟรมที่ต้องการ (timestamp ของ sample buffer บอกเวลาได้) แล้วใช้เฟรมนั้น — ไม่ต้อง seek
3. **ข้อจำกัดของทางเลือกนี้**: ต้อง decode ทั้งไฟล์ตามลำดับ → ถ้าต้องการเฟรมสุ่ม (เช่น scrub) ต้องสร้าง index ของ timestamp → frame
4. ยังต้องวัด "ขี้เข้าฉาก" (อัปโหลดเฟรมเข้า `<canvas>` ในหน้า) ต่อ — spike นี้วัดแค่ส่วนถอดเฟรม

## 3. ผลกระทบต่อข้อเสนอใน `docs/native-engine-decision.md`

ทาง hybrid (WebKit วาดฉาก + AVFoundation ถอดวิดีโอ) แพงแค่ส่วนถอดเฟรม = **1.14 ms/เฟรม** ซึ่งเพิ่มกับคอขวดเดิมของ WebKit (46 ms/เฟรม สำหรับฉากหนัก) ได้ ≈ 47 ms → **ยังไม่ทำให้ฉากวิดีโอเร็วขึ้น แต่ทำให้ "ทำได้"** ซึ่งเป็นคุณค่าที่สำคัญกว่า (pipeline ปัจจุบันทำได้แต่ช้ากว่า 11.5×)

## 4. คำสั่ง

```sh
swiftc -O bench/experiments/video-decode-spike/main.swift -o "$TMPDIR/video-spike"
"$TMPDIR/video-spike" fixtures/pairs/video-embed/assets/sample.mp4 60
```
