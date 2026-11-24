---
tags: [safarium, language, benchmark, decision]
note_type: research
project: "Safarium"
created: 2026-11-21
updated: 2026-11-21
status: method-locked
---

# Language Decision — Safarium

> **สถานะ: ล็อกวิธีแล้ว ยังไม่มีผลวัด** · ภาษาถูกเลือก **แยกตามชั้น** ด้วยคะแนนถ่วงน้ำหนัก ไม่ได้ล็อกภาษาตายตัว
> กติกา: ถ้าคะแนนต่างกัน < 2% (ใน noise) → เลือกภาษาที่ลดจำนวนภาษาในระบบ · ห้ามแก้หลังเห็นผล

## 1. ชั้นของระบบ

| ชั้น | หน้าที่ | Candidate |
|---|---|---|
| Core | WKWebView, snapshot, AVAssetWriter, clock | Swift · ObjC++ · Rust (objc2) · Go (cgo) |
| CLI / JSON-lines | รับคำสั่ง, จัดการ payload | Go · Rust · Swift · Node/TS · Python |
| Orchestrator / pool | spawn, worker, retry, timeout | Go · Rust · Node · Python |
| CDP shim | เลียน Chrome ให้ puppeteer/HF | Go · Rust · Swift · Node |
| Client | API ให้ pipeline เดิม | TS/Node · Python · Go |
| Bench / analysis | รัน experiment, สถิติ, กราฟ | Python · Go · Node |

**ข้อจำกัดจริง:** Node/TS และ Python ตัดออกไม่ได้จาก client เพราะ HyperFrames = Node และ pipeline หลายตัวของปิ๊ก = Python · แต่จะวัดว่าใช้เป็น thin client ได้โดยไม่ทำให้ช้าแค่ไหน

## 2. น้ำหนักคะแนน (ล็อกก่อนวัด)

| เกณฑ์ | Core | CLI | Client | Bench | วัดยังไง |
|---|---|---|---|---|---|
| API access / bridge risk | 35% | 5% | 10% | 0% | spike ผ่าน/ไม่ผ่าน, จำนวน unsafe, LOC |
| End-to-end impact | 25% | 25% | 25% | 10% | L2 delta vs best (%) |
| Startup + RSS | 10% | 20% | 15% | 10% | cold start ms, idle RSS MB |
| Dev velocity | 15% | 20% | 25% | 40% | LOC, build time, time-to-first-working |
| Ecosystem | 5% | 15% | 20% | 40% | JSON/video/CLI/stats libraries |
| Deploy simplicity | 10% | 15% | 5% | 0% | single binary, runtime deps |

**Score = Σ (normalized criterion × weight)** · normalize min-max ภายในชั้น · รายงานตารางคะแนนดิบด้วย

## 3. Spikes

| Spike | ภาษา | งาน | Timebox | ผ่านเมื่อ |
|---|---|---|---|---|
| S-L1 | Go + cgo | WKWebView offscreen → load → snapshot → PNG | 3 วัน | crash ≤ 1/1000 · snapshot ≤ 10 ms |
| S-L2 | Rust + objc2 | งานเดียวกัน | 2 วัน | เหมือน S-L1 |
| S-L3 | ObjC++ | งานเดียวกัน | 0.5 วัน | baseline native |
| S-L4 | Swift | งานเดียวกัน | 0.5 วัน | อ้างอิง (มีอยู่แล้ว) |

**วัดเพิ่ม:** build time, LOC, จำนวน `unsafe`/`msg_send`, RSS idle, ความยากในการจัด CFRunLoop/thread affinity

## 4. การทดลอง

| สนาม | งาน | ตัวอย่างตัวชี้วัด |
|---|---|---|
| L0 | Null renderer (`sleep 8.5 ms`) 5 ภาษา | overhead บริสุทธิ์, cmd latency p95 |
| L1 | CLI จริงต่อ core เดียวกัน | spawn, JSON parse, dispatch, RSS |
| L2 | End-to-end 4 workers ทุกภาษา | x-factor เปลี่ยนไหม, crash |
| L3 | Client TS/Python/Go ต่อ core เดียวกัน | overhead %, payload ใหญ่ |

## 5. Decision gates

| ผล | ข้อสรุป |
|---|---|
| Go core ผ่าน spike + end-to-end ต่าง ≤ 2% | Go core เป็นไปได้ |
| Go core crash > 1/1000 หรือ snapshot ช้ากว่า Swift > 10% | Core = Swift |
| ภาษา CLI ต่าง < 2% | tie-breaker → ภาษาที่ลดจำนวนภาษา |
| Python client overhead > 2% | production client = ภาษาที่เร็วกว่า, Python = scripting |
| Rust objc2 ยังไม่成熟 | ตัด Rust core ออก |

## 6. สภาพเครื่องมือบนเครื่องนี้ (2026-11-21)

| เครื่องมือ | เวอร์ชัน |
|---|---|
| Swift | 6.4.2 (arm64-apple-macosx27.2.0) |
| Go | 1.26.5 darwin/arm64 |
| Rust | 1.97.1 |
| Node | 24.16.0 |
| Python | 3.9.6 (ระบบ) |
| ffmpeg | 9.0.2 |
| macOS | 27.2 (26B123) |

## 7. ผลวัด (เติมเมื่อรัน)

| ชั้น | ผู้สมัคร | คะแนน | หมายเหตุ |
|---|---|---|---|
| Core | — | — | รอ S-L1/S-L2 |
| CLI | — | — | รอ L0/L1 |
| Orchestrator | — | — | รอ L2 |
| Shim | — | — | รอ L1 |
| Client | — | — | รอ L3 |
| Bench | — | — | รอ L3 |

