---
tags: [safarium, benchmark, methods, energy]
note_type: methods
project: "Safarium"
created: 2026-11-21
updated: 2026-11-21
---

# Energy methods — วัด "เบา" อย่างไรให้เชื่อได้

> พลังงาน = 30% ของคะแนน (protocol §9) · เอกสารนี้อธิบายวิธีวัด ข้อจำกัด และตัวเลข smoke test จริง
> เครื่อง: M5 (Mac17,3) · macOS 27.2 (26B123) · ต่อไฟบ้าน

## 1. สองแหล่งข้อมูล (ใช้คู่กันตามที่ปิ๊กเลือก)

| backend | ที่มา | ต้อง root | ให้อะไร | ข้อจำกัด |
|---|---|---|---|---|
| `powermetrics` | Apple-signed, ช่องพลังงานจริงของ SoC | **ใช่** (ครั้งเดียวผ่าน `bench/power-daemon.sh`) | CPU/GPU/ANE/Combined power ต่อ 200 ms | Apple เองเตือนว่าเป็น "estimated" และห้ามใช้เทียบข้ามเครื่อง |
| `macmon` 0.12.0 | อ่าน IOReport/CLPC แบบ sudoless | ไม่ | cpu/gpu/ane/ram/chip/**sys_power** + per-process | บน macOS 27 + M5 ค่า CPU เป็นการประมาณ (bias ได้ถึง +1.5 W ตอนโหลดเบา) |

**กติกา:** ตัวเลขหลักในรายงานใช้ `powermetrics` · `macmon` ใช้เป็นตัวตรวจสอบและดู `sys_power` (ทั้งเครื่อง) เพราะต่อให้ channel หนึ่งเพี้ยน อีกตัวจะฟ้อง

## 2. วิธีคำนวณ

1.  sampler เก็บทุก 200 ms → แต่ละบรรทัดมี epoch นำหน้า (`bench/power-inner.sh` ผ่าน perl)
2. วัด idle baseline 3–5 s ก่อนรัน
3. รันงาน → จำ `t0, t1` (wall clock)
4. `E = ∫P dt` ด้วย trapezoid เฉพาะ samples ใน [t0, t1] · `E_net = E − idle_W × (t1−t0)` · `J/เฟรม = E_net / frames`
5. รายงานคู่กับ `CPU-seconds` จาก `getrusage(RUSAGE_CHILDREN)` — ตัวนี้ไม่ขึ้นกับ sampling และจับ "งานที่โปรเซสเราทำจริง" (ไม่รวม WebKit XPC)

## 3. Smoke test จริง (2026-11-21, X9 60 เฟรม, เครื่องมี load)

```
python3 bench/energy.py --backend log --log /tmp/safarium-power/power.log --idle-seconds 3 -- \
  safarium-bench --fixture <EP30>/index.html --frames 60 --warmup 5 --start 20 --codec h264 ...
```

| ค่า | ผล |
|---|---:|
| samples ในหน้าต่างรัน | 41 |
| wall | 8.82 s |
| E (ทั้งเครื่องตามช่อง SoC) | 29.42 J |
| idle baseline | 2.70 W |
| **E_net** | **5.57 J** (0.093 J/เฟรม) |
| CPU mean | 3.35 W |
| GPU mean | 0.069 W |
| ANE mean | 0.000 W |
| CPU-seconds (host) | 0.805 s (13.4 ms/เฟรม) |

ตัวเลขนี้ยัง **ไม่ใช่ตัวเลขสรุป** (เครื่องมี load จากงานอื่น) — เป็นการยืนยันว่าท่อวัดทำงานครบ: sampler → integrate → J/เฟรม

## 4. ข้อควรระวัง

1. **อย่าเปิด sampler ระหว่างวัดเวลา** — powermetrics กิน CPU ~1–2% และรบกวน p95 → วัดเวลาให้เสร็จก่อน แล้ววัดพลังงานแยก pass (แมทริกซ์เล็ก: 4 ฉาก × 2 เอนจิน × 3 reps)
2. **run สั้นกว่า ~2 s ได้ samples ไม่พอ** → ใช้ ≥ 10 s (300 เฟรม) ต่อ run
3. **idle baseline ต้องวัดตอนเครื่อง状態เดียวกัน** — ถ้ามี Chrome ค้างหรือ HF render อยู่ baseline จะสูงและทำให้ E_net ต่ำผิด
4. **`sys_power` ≠ chip power** — รวมจอและอุปกรณ์ต่อพ่วง ใช้ `chip_power` เมื่อพูดถึง "เอนจิน" และ `sys_power` เมื่อพูดถึง "เครื่องทั้งเครื่อง"
5. **root อ่านไฟล์บนไดรฟ์ `Main` ไม่ได้** (mounted ด้วย unknown ownership) → helper + log อยู่ `/tmp/safarium-power/` แล้ว `power-daemon.sh copy` คัดลอกเข้า `bench/results/`
6. **หยุด daemon ได้โดยไม่ต้องรหัสผ่าน** — `power-daemon.sh stop` สร้างไฟล์ `stop` ให้ root shell ปิด powermetrics เอง

## 5. คำสั่ง

```sh
bench/power-daemon.sh start     # ขอรหัสผ่าน 1 ครั้ง
bench/power-daemon.sh status
python3 bench/energy.py --backend log --log /tmp/safarium-power/power.log \
  --label x9-r1 --idle-seconds 5 -- <command...>
bench/power-daemon.sh stop
bench/power-daemon.sh copy      # เก็บ log ไว้กับผล
```
