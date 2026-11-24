---
tags: [safarium, benchmark, protocol, pre-registration]
note_type: protocol
project: "Safarium"
created: 2026-11-21
updated: 2026-11-21
status: locked
---

# Benchmark Protocol — Safarium

> **สถานะ: LOCKED ก่อนเก็บข้อมูล** (2026-11-21)
> ห้ามแก้เงื่อนไขด้านล่างหลังเห็นผล · ทุกการเปลี่ยนแปลงต้องเพิ่มใน §12 Deviation Log พร้อมเหตุผลและเวลา · ห้ามลบรายการเก่า
> ไฟล์นี้เป็นสัญญาระหว่าง "คนออกแบบการทดลอง" กับ "คนอ่านผล" — ถ้าตัวเลขออกมาไม่ตรงสมมติฐาน ต้องรายงานตามจริง

## 1. คำถามที่ต้องตอบ

| # | คำถาม |
|---|---|
| Q1 | framework ไหนเร็วที่สุดบน macOS ที่คุณภาพเท่ากัน? |
| Q2 | framework ไหนเบาที่สุด (พลังงาน, RAM, จำนวน process)? |
| Q3 | คุณภาพอยู่ในเกณฑ์ "ไม่ต่าง" จริงหรือไม่ (ไม่ใช่แค่มีแนวโน้ม)? |
| Q4 | ผลยังคงเดิมเมื่อใช้ 4 workers และ 4K หรือไม่? |
| Q5 | แต่ละชั้นของระบบควรใช้ภาษาอะไร? |
| Q6 | เร่งสุดแล้วเร็วกว่าสถาปัตยกรรมเดิมกี่เท่า (ช่วงความเชื่อมั่น)? |

## 2. สมมติฐาน (เขียนก่อนเห็นข้อมูล)

| # | สมมติฐาน | เกณฑ์ตัดสิน |
|---|---|---|
| H1 | capture + encode เป็นคอขวดหลัก ภาษาชั้นควบคุมมีผล < 2% ต่อ end-to-end | ถ้าภาษาต่าง > 5% → H1 ผิด |
| H2 | core ที่เรียก Apple API ตรง (Swift/ObjC++) มีความเสี่ยง bridge ต่ำที่สุด | เทียบ crash rate + LOC + snapshot latency |
| H3 | CLI ภาษา Go/Rust อยู่ใน ±10% ของ Swift CLI; Python ช้าสุดแต่ < 1% ของงบต่อเฟรม | L0/L1 |
| H4 | native engine เร็วกว่า WebKit ≥ 2× บนงานกราฟิกง่าย | Stage D |
| H5 | WebGPU ให้ผล ≥ 15% บนฉาก effect หรือไม่คุ้มใส่ MVP | W6 |
| H6 | Safarium เร็วกว่า HyperFrames ตัวจริง 3–5× ที่คุณภาพเท่ากัน | Real baseline |

## 3. นิยาม

| คำ | นิยามที่ใช้ |
|---|---|
| เร็ว | เวลารวมต่อคลิป, เวลา/เฟรม p50/p95, throughput (เฟรม/วินาที) |
| เบา | พลังงาน/เฟรม (J), CPU-seconds/เฟรม, peak RSS, จำนวน process |
| คุณภาพเท่า | TOST equivalence ภายใน δ ที่ล็อกไว้ (§9) ไม่ใช่ "วัดแล้วไม่เห็นต่าง" |
| Framework | สแตกเต็ม (วาดภาพ + จับภาพ + เข้ารหัส + mux) ไม่ใช่แค่ library |
| Baseline จริง | `Projects/ประเทศโปแลนด์/pipeline/produce_episode.py` (HyperFrames + Chromium) หนึ่งฉากสั้น |
| Baseline controlled | Chromium headless + ffmpeg ผ่าน harness เดียวกัน |
| คลิปหัวตาราง | 1080×1920, 30fps, 10 วินาที = 300 เฟรม |

## 4. Candidates — Stage A

| รหัส | วาดภาพ | จับภาพ | เข้ารหัส | หมายเหตุ |
|---|---|---|---|---|
| A | WKWebView (SafariumWeb) | `takeSnapshot` 2× | AVAssetWriter | ตัวหลัก |
| B | Chromium headless | CDP `Page.captureScreenshot` | ffmpeg | baseline ที่นิยม |
| C | Playwright WebKit | CDP ของ Playwright | ffmpeg | เทียบ WebKit แพ็กเกจ |
| D | WKWebView + WebCodecs ในหน้า | canvas / `toDataURL` | WebCodecs/Mediabunny | เข้าเฉพาะเมื่อ W2 ผ่าน |
| E | SafariumNative (CARenderer/Metal + CoreText) | `CARenderer`/Metal offscreen | AVAssetWriter | เฉพาะ paired fixture |

**กฎ:** เซลล์ที่ทำไม่ได้ (เช่น E อ่าน HTML) = `N/A` · ห้ามเติมค่าแทน · รายงานแยก

## 5. Fixtures — paired design

ดีไซน์เดียวกัน 4 แบบ · แต่ละแบบมี `web.html` และ `native.json` ที่ให้ภาพใกล้เคียงกันที่สุด

| Fixture | สิ่งที่วัด | องค์ประกอบ |
|---|---|---|
| `text-card` | DOM + ข้อความไทย + CSS animation | headline, subhead, accent bar, counter |
| `webgl-scene` | GPU draw + shader | WebGL2 particles/gradient (native = Metal shader) |
| `video-embed` | video decode + seek | `<video>` 2 วินาที loop (native = AVPlayerLayer) |
| `alpha-overlay` | alpha + premultiplied | shapes/text บนพื้นโปร่งใส |

**สเปก:** 1080×1920 · 30fps · 10s · ไม่มี network · ฟอนต์ Thai ระบบ · สี sRGB
**Pairing rule:** layout, สี, ตำแหน่ง, เวลา keyframe ต้องตรงกัน ± 2 px / ± 1 เฟรม

## 6. ปัจจัยและจำนวน run

### Stage A — Framework bake-off
5 framework × 4 fixture × 2 resolution (1080×1920, 2160×3840) × 2 workers (1, 4)
= **80 cells × 3 reps = 240 runs**

### Stage B — Pipeline ablation (ภายในตัวชนะ)
sink (4: H.264, HEVC, ProRes 4444, JPEG→ffmpeg) × snapshot scale (1×, 2×) × workers (1, 2, 4, 8) × doubleBuffer (off, on)
= **64 cells × 3 = 192 runs**
*(capture ตรึงเป็น `takeSnapshot` เพราะเป็นเส้นทางเดียวที่แฟร์ภายใน Safarium)*

### Stage C — Quality ladder
3 framework × 4 fixture × 4 quality levels (CRF/QP) = **48 × 3 = 144 runs**

### Stage D — Native ceiling
4 fixture × 2 resolution × 2 workers = **16 × 3 = 48 runs**
+ ffmpeg `drawtext` reference 4 runs

### Stage E — Ceiling / scaling / thermal / energy
ceiling 2 × 3 = 6 · scaling 4 workers × 3 = 12 · thermal 2 conditions × 3 = 6 · energy 4 workers × 3 = 12
= **36 runs**

### Stage W — WebGPU
W1–W6 × 3 reps = **18–30 runs**

### Stage L — Language bake-off
L0 5 languages × 3 = 15 · L1 5 × 3 = 15 · L2 5 × 3 = 15 · L3 3 clients × 3 = 9
= **54 runs**

**รวมประมาณ 750 runs** · ทุก run สุ่มลำดับภายใน block · ทิ้ง warm-up 10 เฟรม · cooldown 60 วินาทีระหว่าง block

## 7. ตัวชี้วัดและสูตรอินทิกรัล

### 7.1 เวลา
```
T_clip = t_end - t_start
t_frame(i) = t_snapshot(i) + t_convert(i) + t_append_wait(i)
throughput = frames / T_clip
```

### 7.2 พลังงาน (อินทิกรัล)
```
E = ∫ P(t) dt  ≈  Σ (P_i + P_{i+1})/2 × Δt      [จูล]
E_frame = E / frames
P(t) = system power during run − idle baseline power
```
แหล่ง: `sudo powermetrics --show-process-energy -i 100` + sampling ระดับระบบ
ถ้า powermetrics ล้ม → ใช้ `CPU-seconds` เป็นตัวแทน และรายงานว่าตัวแทน

### 7.3 ภาระ CPU
```
W = ∫ CPU(t) dt  [CPU-seconds]
```

### 7.4 คุณภาพ (อินทิกรัลถ่วงเวลา)
```
Q̄ = (1/T) ∫ Q(t) dt  ≈  (1/N) Σ Q_i     [Q_i = SSIM หรือ VMAF ของเฟรม i]
```
- SSIM/PSNR ต่อเฟรมด้วย `ffmpeg -lavfi ssim`
- VMAF ด้วย `libvmaf` (ถ้ามีใน ffmpeg 9.0.2 บนเครื่อง)
- ΔE2000 เฉลี่ย + p95 (สี)
- Thai text: OCR + ตรวจด้วยตา 10 เฟรมสุ่ม
- Alpha: ตรวจ pixel (0,0) และ mux ของ ProRes 4444

### 7.5 Rate–Distortion (อินทิกรัลใต้กราฟ)
```
BD-rate = พื้นที่ใต้กราฟ log(bitrate) vs quality (piecewise-cubic)
```
รายงานเป็น % ประหยัด bitrate ที่คุณภาพเท่ากัน

### 7.6 คะแนนรวม
น้ำหนักที่ล็อก: **speed 40% · energy 30% · quality 20% · footprint 10%**
- normalize ด้วย min-max ภายใน Stage A
- รายงาน Pareto front เสมอ ไม่รายงานแค่คะแนนรวม
- sensitivity: สุ่มน้ำหนัก 10,000 ชุดจาก Dirichlet(1,1,1,1) → ดูว่าผู้ชนะเปลี่ยนกี่ %

## 8. สถิติ

1. **Transform:** `log(t)` และ `log(E)` เพราะข้อมูลเวลา/พลังงานเป็นบวกและคูณกัน (lognormal)
2. **Model:** `log(y) = μ + Framework + Fixture + Resolution + Workers + Framework×Fixture + (1|cell/run) + ε`
3. **ANOVA:** Type III, sum-to-zero contrasts, mixed model (run เป็น random effect)
4. **Effect size:** η²บางส่วน + bootstrap BCa 95% CI (10,000 resamples)
5. **Multiplicity:** Holm–Bonferroni ภายใน family เดียวกัน
6. **Equivalence:** TOST สำหรับคุณภาพ ที่ δ = SSIM 0.03 / VMAF 2 / ΔE p95 2
7. **Power:** pilot 5 reps → ประมาณ CV → กำหนด reps ให้ power ≥ 0.80 ที่ α = 0.05
8. **Missing cells:** N/A ไม่ถูก impute · วิเคราะห์เฉพาะ fully-crossed subset

## 9. เกณฑ์ผ่าน (ล็อกก่อนเห็นผล)

| ด้าน | เกณฑ์ |
|---|---|
| คุณภาพ | ขอบล่าง 95% CI ของ SSIM ≥ 0.97 · VMAF ≥ 93 · ΔE p95 ≤ 2 · ไทย OCR ผ่าน ≥ 90% · alpha ถูกต้อง |
| ความเร็ว | อยู่ Pareto front หรือชนะตามน้ำหนักที่ล็อก และชนะ ≥ 3/4 fixture |
| พลังงาน | J/เฟรม ≤ baseline (ขอบบน 95% CI ต้องไม่เกิน baseline) |
| หน่วยความจำ | peak RSS ≤ 50% ของ Chromium baseline |
| Determinism | 3/3 รอบ hash เท่ากัน |
| Integration | E2E 4 ตัวแทนผ่าน · ไม่มี Chrome ถูก spawn · ไม่แย่งโฟกัส |
| เสถียรภาพ | crash ≤ 1/1000 runs |

**ห้ามลดเกณฑ์เงียบ** — ถ้าตัวเลขจริงไม่ถึง ให้รายงานพร้อมเฟรมที่ต่างและให้ปิ๊กตัดสิน

## 10. Fairness protocol

- เครื่องเดียว (M5, macOS 27.2) · ต่อไฟบ้าน · ปิด Low Power Mode · ปิดแอปหนัก
- ตรวจ `pmset -g therm` ก่อน/หลังทุก block · cooldown 60 วินาที
- สุ่มลำดับ run ภายใน block · warm-up 10 เฟรมทิ้ง
- output สเปกเดียวกัน (codec, fps, bitrate/quality target, color space)
- ใช้ asset/ฟอนต์ชุดเดียวกัน · ไม่มี network
- เรนเดอร์ลง scratch เท่านั้น (`/private/var/folders/.../opencode` หรือ temp)
- รายงาน **burst** และ **sustained 10 นาที** แยกกัน
- เก็บ raw JSONL ทั้งหมดไว้ตรวจซ้ำ

## 11. Language decision framework

น้ำหนักต่างตามชั้น (ดู `docs/language-decision.md`):

| เกณฑ์ | Core | CLI | Client | Bench |
|---|---|---|---|---|
| API access / bridge risk | 35% | 5% | 10% | 0% |
| End-to-end impact | 25% | 25% | 25% | 10% |
| Startup + RSS | 10% | 20% | 15% | 10% |
| Dev velocity | 15% | 20% | 25% | 40% |
| Ecosystem | 5% | 15% | 20% | 40% |
| Deploy simplicity | 10% | 15% | 5% | 0% |

**Tie-breaker:** ถ้าคะแนนต่าง < 2% (ใน noise) → เลือกภาษาที่ลดจำนวนภาษาในระบบ

## 12. Deviation Log

| วันที่ | เปลี่ยนอะไร | เพราะอะไร | ใครอนุมัติ |
|---|---|---|---|
| 2026-11-21 | ก่อนเก็บข้อมูล: ระบุ Stage B ให้ชัดเป็น sink(4) × scale(2) × workers(4) × doubleBuffer(2) | "capture 2" ไม่มีคู่ที่แฟร์ภายใน Safarium — capture ตรึงเป็น takeSnapshot | ยังไม่มีข้อมูลถูกเก็บ |
| 2026-11-21 | หลัง pilot: แยกความหมาย "คุณภาพ" เป็น (a) fidelity ต่อ lossless ของเอนจินเดียวกัน ใช้ SSIM/PSNR/VMAF และ (b) ความเหมือนข้ามเอนจิน ใช้ SSIM + ΔE + Thai OCR **ไม่ใช้ VMAF** | VMAF ข้ามเอนจินให้ 68.5 กับ text-card ทั้งที่ภาพเหมือนกันด้วยตา — เป็นคนละ raster ไม่ใช่คุณภาพเอนโค้ด | ยังไม่มีข้อมูล Stage A |
| 2026-11-21 | เพิ่ม HEVC-alpha เป็น exploratory sink (ไม่อยู่ใน 4 sink ที่ล็อก) | วัดได้ finish 0.030 s vs ProRes 4444 52–69 s, alpha ผ่าน XCTest; ใช้เป็น alpha master ในอนาคต | ยังไม่มีข้อมูล Stage A |
| 2026-11-21 | Stage A ของ `safarium-web` + `video-embed` = N/A | WKWebView ไม่มีหน้าต่างโหลด `<video>` ไม่ได้ (readyState 0/networkState 3) | ยังไม่มีข้อมูล Stage A |
| 2026-11-21 | **ยังไม่เปลี่ยน:** จำนวน reps ของ Stage A (ล็อกไว้ 3) | pilot power: sd(log)=0.193 → 3 reps ตรวจได้แค่ effect ≥ ~40%; ต้อง 12 reps สำหรับ 25%, 18 สำหรับ 20% | **ปิ๊กอนุมัติ 18 reps (2026-11-21)** |
| 2026-11-21 | Stage A รอบ headline = 1080×1920, workers 1 และ 4, 18 reps (4 ฉาก × 2 framework × 2 workers × 18 = 288 runs) · 4K แยกภายหลังด้วย 3 reps | 4K × 18 reps ใช้เวลา > 1 วัน และยังไม่ใช่คำถาม headline | ปิ๊กอนุมัติ "ทำให้ผลดีที่สุด" |
| 2026-11-21 | X9 headline = EP30 `index.html` slice 20–30 s (300 เฟรม) ทั้งสองเอนจิน · HF CLI 0.9.72 `--quality looks -w 1 --start 20 --end 30 --resolution portrait` · Safarium `safarium-bench --start 20 --frames 300 --codec h264` | ให้ composition เดียวกัน ช่วงเวลาเดียวกัน — แฟร์กว่าเทียบคนละฉาก · HF เปิด static-dedup ตามจริงของมัน · HF มี audio ในไฟล์, Safarium ไม่มี (บันทึกเป็นข้อจำกัด) | ยังไม่เห็นผล 3 reps ตอนลงทะเบียน (มีเพียง 1 run สำรวจ: Saf 15.97 s vs HF 184 s) |
| 2026-11-21 | เพิ่ม condition gate ก่อนทุกรอบวัด: 1-min load ≤ 3 **และ** ไม่มี `swift-test`/`xctest`/`xcodebuild`/`ffmpeg`/`plugin-cli.mjs`/`chrome-headless-shell` รันอยู่ (หรือมี lock file `bench/results/.measure.lock`) | รอบ 3 reps แรกของ X9 ตัวเลขแกว่ง 59→75 ms/เฟรม เพราะ HF ทิ้ง Chrome 5 ตัว + session อื่นรัน swift test/ffmpeg → ต้องไม่ให้เกิดซ้ำกับ 288 runs | ยังไม่มีข้อมูล Stage A (ยกเลิกรอบที่ปนเปื้อน ไม่ใช้ตัวเลข) |
| 2026-11-21 | ทิ้ง 3-rep X9 รอบแรกทั้งรอบ (Safarium 3 reps ไม่มี HF reps) และไม่ใช้ตัวเลขในการสรุป | เครื่องปนเปื้อนตลอดรอบ (load 8–16 จาก EP25/EP26 pipeline ของอีก session + Chrome ค้าง) — rep 3 ยังช้ากว่า run สะอาด 28% | ยังไม่มีข้อมูล Stage A · ตัวเลขสะอาด 1 run อยู่ใน `docs/x9-headline.md` |
| 2026-11-21 | เพิ่ม exploratory experiment "snapshot anatomy" (ไม่อยู่ใน factorial): probe blank/solid/text-card, A/B hidden window, A/B `afterScreenUpdates`, CPU%/GPU power | อธิบายว่าทำไม 46 ms/เฟรม: snapshot = 92% และ raster เกิดบน CPU ใน WebKit GPU process → กำหนดทิศทางจูนต่อ | ไม่กระทบเงื่อนไข Stage A · บันทึกที่ `docs/snapshot-anatomy-2026-11-21.md` |
| 2026-11-21 | เพิ่ม exploratory experiment "raster scale + ablation" (ไม่อยู่ใน factorial): ทดสอบ `WKSnapshotConfiguration.snapshotWidth` ที่ 270/540/1080/2160 pt + วัดพิกเซลเส้น 1 CSS px + ตัดองค์ประกอบ EP30 (svg/ข้อความ/gradient/shadow/animation ทีละชนิด) | ปิดสมมติฐาน "เรนเดอร์เกินพิกเซล 4 เท่า" (ยืนยัน 1:1) และชี้ว่า SVG ≈ 55% ของเวลา snapshot บน composition จริง → ปิดทางแก้ด้านความละเอียด และกำหนดข้อกำหนดสำหรับ native engine | ไม่กระทบเงื่อนไข Stage A (รันบนเครื่องที่มี load 8–13 อยู่ → ตัวเลข absolute สูงกว่าปกติ ~2× แต่สัดส่วนใช้ได้) · บันทึกที่ `docs/snapshot-anatomy-2026-11-21.md` §2.1–2.3 |
| 2026-11-21 | **ปรับแผน Stage A เป็น "บล็อก"**: `bench/plan.py --block-size 3` → 18 rep ของ cell เดียวกันแบ่งเป็นบล็อกละ 3 · สุ่มลำดับบล็อกทั้งหมด (ทุก cell กระจายทั่ว session → thermal drift ตกชั่วกัน) · สุ่มลำดับในบล็อก · **cooldown 60 วิ ทำกับระหว่างบล็อก** (116 ครั้ง แทน 360) → ระยะเวลารวม ~4 ชม. แทน ~8.5 ชม. · แก้ `run.py` ให้ resume ด้วยคีย์ **(cell, rep)** แทน run_id (กันรู้หายข้อมูลเมื่อแผนถูกจัดใหม่) | protocol §10 ระบุ "สุ่มลำดับ run ภายใน block" — แผนเดิมสุ่มทุกเฟรมจึงกลายเป็นบล็อกใหม่ทุก run และจึงหลับ 60 วิ × 360 ครั้ง (ผิดเจตนาของ protocol) · **ยังไม่มีข้อมูล Stage A ที่ใช้ได้** (รอบแรกเพิ่งเริ่ม) |
| 2026-11-21 | **เกณฑ์ความเงียบของ gate**: เพิ่ม `--max-cpu` (default 150% ของหนึ่ง core) เป็นเกณฑ์รองข้าง `load ≤ 3` — ยอมรับ noise ของเดสก์ท็อป (WindowServer + Orca + Chrome ≈ 1.2 core ตลอด) ซึ่งกระทบทั้งสองเอนจินเท่ากัน แต่ **ยังปฏิเสธงานแข่งขันจริง** (render/compiler/HF) ตามชื่อ process เหมือนเดิม | เครื่องเป็นเครื่องที่ปิ๊กใช้งานอยู่ (Orca/Chrome เปิด) → ปิดไม่ได้ · ตัวเลข absolute จะสูงกว่าเครื่องเปล่า แต่เปรียบเทียบระหว่างเอนจินยังยุติธรรม |
| 2026-11-21 | **ปิดงานเรนเดอร์ของ session อื่นระหว่างวัด** (ปิ๊กสั่ง 2026-11-21): `bench/stop-conflicts.py --watch` ฆ่า process เรนเดอร์ที่ไม่ใช่ของเรา (ตรวจด้วยสายบรรพบุรุษ: ไม่แตะ `safarium-bench` / `chromium-baseline.mjs` / `bench/run.py`) และ **พัก (SIGSTOP) agent อีกเซสชัน** pid 13084 (ทำต่อได้ด้วย `kill -CONT 13084` — งานไม่หาย) | session อื่นสั่งเรนเดอร์คลิปซ้ำทุก ~90 วิ → ทำให้วัดไม่ได้ (load 8–27) และ logd กิน CPU 85% จากการฆ่า process ถี่ |
| 2026-11-21 | เพิ่ม `bench/selftest-analysis.py` — ยิงข้อมูลจำลอง (schema จริง + effect ที่ฉีดไว้) เข้า `analyze.py` แล้วเช็กว่ากู้ค่ากลับมาได้ (4.00× ± 15%, ANOVA p « 0.001, n ถูกต้องหลังตัด cell ที่ไม่ครบ) | ป้องกันบั๊กใน pipeline วิเคราะห์ที่จะได้ใช้กับ 288 runs — ถ้าพังจะเห็นหลังเก็บข้อมูลเสร็จ | ตรวจผ่าน 2026-11-21 |
| 2026-11-21 | **เพิ่ม fixture `svg-map` เข้า Stage A** (58 paths + 90 circles + ข้อความไทย) → plan เดิม 16 cells/288 runs กลายเป็น **20 cells/360 runs** (seed เดิม 20261121, เรียงใหม่แบบสุ่ม) · ไฟล์ plan เดิมเก็บไว้ที่ `bench/plan/runs-stageA-headline-288runs.bak.jsonl` | ablation ของ EP30 ชี้ว่า SVG ≈ 55% ของเวลา snapshot แต่ fixture 4 ตัวเดิมไม่มี SVG เลย → ต้องพิสูจน์ใน factorial ไม่ใช่แค่ exploratory · **ยังไม่มีข้อมูล Stage A เลยแม้แต่ run เดียว** (ตอนนี้ยังรอเครื่องว่าง) → แก้ก่อนเก็บข้อมูลได้ตามกฎ "pre-register ก่อนรัน" | **ปิ๊กอนุมัติ 2026-11-21** ("เอาวิธีไหนก็ได้ เพื่อพิสูจน์") |
| 2026-11-21 | ทดลอง "หน้าต่าง NSWindow ที่ถูกสั่ง order-on-screen" (โหมด 1 = นอกทุกจอ, โหมด 2 = บนจอจริงแต่ alphaValue=0) บนสำเนาแช่แข็ง → **ไม่มีผล** (median snapshot 85.02 vs 85.27 ms) | ปิดสมมติฐานว่า "ต้องมีหน้าต่างที่แสดงจริงจึงจะได้ GPU path" (WebKit bug 221662) → ต้นทุนเป็นของ snapshot path โดยตรง · ปิ๊กอนุมัติให้รัน 2026-11-21 (หน้าต่างโปร่งใสบนจอ แอป `.prohibited` ไม่มี Dock icon ไม่แย่งโฟกัส) | บันทึกที่ `docs/snapshot-anatomy-2026-11-21.md` §2.2.2 |
| 2026-11-21 | **แก้ gate ความเงียบของ `bench/run.py`**: นับ process ที่ "กำลังใช้ CPU จริง" (ผลต่างของ CPU time สะสมในช่วง 0.8 s) แทนการเช็คแค่ "มี process อยู่" | HyperFrames ทิ้ง `chrome-headless-shell` ค้างทุกครั้งที่เรนเดอร์ → gate ที่เดิมรอไม่จบเพราะเจอ process ที่ไม่ได้ทำอะไร (ค้างมานานหลายชั่วโมง) · ตอนนี้ตัวที่ "ยังทำงานอยู่" ยังถูกจับเหมือนเดิม (ตรวจแล้ว: รอบที่ render จริง ยังขึ้น 5–15% ตามเวลาจริง) · **ยังไม่มีข้อมูล Stage A** (รอบแรกยังไม่เริ่ม) |
| 2026-11-21 | **แก้ harness ฝั่ง Chromium ให้ผลิตสเปกสีเดียวกับ Safarium**: เพิ่ม `-vf scale=out_color_matrix=bt709:out_range=tv` + `-color_range tv -colorspace bt709 …` ใน `chromium-baseline.mjs` (เดิมได้ yuvj420p/BT.601 full-range ขณะที่ Safarium เขียน BT.709 limited) + เพิ่ม `--stride` ใน `bench/quality.py` เพื่อสุ่มเฟรมแทนการดูทั้ง 300 เฟรม | เดิมการเทียบข้ามเอนจินวัด "ความต่างของเมทริกซ์สี" ไม่ใช่ความต่างของการเรนเดอร์ (หลักฐาน: ffprobe ไฟล์ Chromium = bt470bg/full-range, ไฟล์ Safarium = unknown) → **ยังไม่มีข้อมูล Stage A** แก้ก่อนเก็บข้อมูลได้ตามกฎ · ผลหลังแก้: ทั้งสองฝั่งประกาศ bt709/tv เหมือนกัน | บันทึกที่ `docs/x9-headline.md` §2.1 |

## 13. Open items (ยังไม่ล็อกจนถึงวันเริ่ม Stage A)

- เกณฑ์ SSIM ของ native engine (CoreText/Metal raster ต่างจาก Chromium) — จะวัด pilot แล้วเสนอปิ๊กพร้อมตัวเลข
- native compositor: CARenderer vs Metal — ตัดสินหลัง spike
- WebCodecs บน WebKit มี hardware encode จริงหรือไม่ — W1/W2
- VMAF มีใน ffmpeg 9.0.2 ของเครื่องหรือไม่ — **มีแล้ว** (`libvmaf` ใช้งานได้, ทดสอบใน pilot)
- จำนวน reps ของ Stage A — pilot บอกว่า 3 ไม่พอ (ดู §12 แถวสุดท้าย)

