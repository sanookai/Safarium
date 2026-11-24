---
tags: [safarium, rendering, queue, commands]
note_type: runbook
project: "Safarium"
created: 2026-11-21
updated: 2026-11-21
---
# คิวและตัวเรนเดอร์กลางบนเครื่องปิ๊ก

คำสั่งสาธารณะ: `~/.local/bin/safarium-render` · [มาตรฐานทุก AI](render-standard.md)

- **`status`** แสดง JSON เช่น `{"active":null,"waiting":[]}`; ตัวเลขคือตั๋ว ไม่บันทึกข้อความคำสั่งหรือเนื้อหางาน
- **`html INPUT.html --output NEW.(mp4|mov) --width W --height H --fps N --frames N [--start S] [--bitrate BPS | --quality 0..1] [--codec h264|hevc|hevc-alpha|prores4444] [--transparent] [--pixel-format bgra|nv12-vimage] [--snapshot-quality fast|sharp] [--subtitles FILE.srt [--subtitle-lang ISO639-2]] (--video-only | --audio FILE.wav [--audio-start S])`** วาด local HTML/GSAP แบบไม่มีหน้าต่างบน WebKit ด้วย single-pass `AVAssetWriter` (Metal `CIContext` `.sharp` + backpressure ก่อนจัดสรรบัฟเฟอร์ + `tx3g` subtitles) ขนาดภาพและจำนวนเฟรมต้องระบุเอง `--bitrate` ค่าเริ่มต้น 20,000,000 bits/s สำหรับ H.264/HEVC; ตั้งจากสเปกของงาน ไม่ลดเพื่อประหยัด RAM. เวลาในหน้าเริ่ม `S`; เฟรมในไฟล์เริ่ม `0` และห่างกัน `1/fps` วินาที
- **`extract-audio INPUT --output OUT.(wav|m4a) [--start S] [--duration S] [--sample-rate N] [--channels 1|2] [--bitrate BPS] [--overwrite]`** ถอดและเรนเดอร์เสียงออกเป็น WAV/M4A พร้อมวัด RMS/LUFS/peak (ผ่าน `safarium-media`)
- **`mix-audio --track PATH[:gainDB[:startSec[:loop]]] ... --output OUT.(wav|m4a) [--duration S] [--sample-rate N] [--channels 1|2] [--bitrate BPS] [--normalize-lufs DB] [--overwrite]`** มิกซ์เสียงหลายแทร็กพร้อม `vDSP` + ITU-R BS.1770 LUFS normalization (ผ่าน `safarium-media`)
- **`gif INPUT --output OUT.gif [--fps N] [--max-width N] [--start S] [--duration S] [--loop N] [--overwrite]`** แปลงวิดีโอเป็น animated GIF ด้วย `ImageIO` (ผ่าน `safarium-media`)
- **`cutout INPUT --output OUT.(png|mov) [--codec hevc-alpha|prores4444] [--fps N] [--max-frames N] [--allow-empty-mask] [--overwrite]`** แยกฉากหลังด้วย Vision (`VNGenerateForegroundInstanceMaskRequest`) ส่งออก PNG หรือ MOV โปร่งใส (ผ่าน `safarium-media`)
- **`hybrid [--html FILE.html] [--video FILE.mp4] --output OUT.(mp4|mov) --width W --height H --fps N --frames N [--codec h264|hevc|hevc-alpha|prores422|prores4444] [--bitrate BPS] [--quality Q] [--start S] [--overwrite]`** รวมภาพนิ่ง/วิดีโอพื้นหลังกับ HTML overlay แบบ Metal GPU compositing (ผ่าน `safarium-media`)
- **`verify REFERENCE.(mp4|mov) [CANDIDATE.(mp4|mov)]`** เปรียบเทียบ decoded NV12 (ทึบ) หรือ decoded 32-bit BGRA (alpha) ที่มองเห็นจริง (ไม่แฮช padding), PTS/ระยะ, ขนาด/การหมุน/แท็กสี, รูปแบบ/เวลาของแทร็ก, PCM ของเสียง AAC และ raw cues ของซับ `tx3g`; อ่านจนครบทีละไฟล์ ไม่เปิด decoder ของทั้งสองคลิปซ้อนกัน `0` = ตรง, `2` = อ่านได้แต่ต่าง, ค่าอื่นที่ไม่ใช่ศูนย์ = ไม่สามารถตรวจรับ. `verify FILE` ตรวจอ่านเพียงไฟล์เดียว ไม่ได้บอกว่าเท่ากับงานอ้างอิง
- **`run -- PROGRAM [ARG ...]`** รอตั๋วก่อนเริ่ม process จริง ส่ง arguments แยกตัวและคง working directory/stdin/stdout/stderr ไม่ใช่ shell parser ต้องเป็นคำสั่ง foreground ที่ตรวจว่าทำงานหนึ่ง worker และรอลูกทุกตัวจนจบ หากเป็น wrapper ภายนอก คิวยืนยันได้เพียงว่าไม่เปิด *คำสั่งระดับบน* สองตัวซ้อนกัน ไม่ได้สอดแทรกเข้าไปเปลี่ยนทุกโปรแกรมในเครื่อง

`html`, `verify` และคำสั่ง `safarium-media` (`extract-audio`, `mix-audio`, `gif`, `cutout`, `hybrid`) ตรึงพาธของ worker ตั้งแต่รับคำขอ จึงไม่เปลี่ยนรุ่นระหว่างรอ. ถ้ายกเลิกขณะทำงาน คิวส่งสัญญาณให้กลุ่มงานโดยตรงและรอกลุ่มลูกที่ยังอยู่ใน session เดิม; แม้ตัวเฝ้าหาย คิวก็ไม่ปล่อยตั๋วจนยืนยันว่า session ของงานไม่เหลือโปรเซสทำงาน. `status` ไม่แสดง argv. กรณีเคอร์เนลยืนยันสถานะไม่ได้ ให้ตรวจ `status` อีกครั้ง ไม่ลบตั๋วด้วยมือ. คำสั่งภายนอกที่แยก session หรือส่งงานไปให้แอปอื่นไม่อยู่ในสัญญานี้

## ขอบเขตของ `html`

ต้องเป็นงานที่เชื่อถือและอยู่ในเครื่องทั้งหมด ภาพนิ่งหรือ timing ที่ใช้ `window.__seek`, `window.__hf.seek` หรือ timeline ที่ลงทะเบียนไว้ กลไกวาดต้องทำเสร็จก่อน resolve; start ที่ไม่ใช่ศูนย์เป็นการ seek ตรง ไม่จำลองทุก rAF ตั้งแต่ต้น ใช้สเกล 1 CSS pixel ต่อ output pixel ขนาดต้องเป็นเลขคู่ตามสเปก H.264/HEVC และ fps ต้องเป็นจำนวนเต็มบวก; งาน 30000/1001 หรือ VFR ต้องใช้ตัวสร้างที่รักษาเวลานั้นได้ ห้ามปัดเป็น 30. ไม่โหลดภาพ/สคริปต์จากเครือข่าย ไม่ถ่ายหน้าจอ และไม่ใช้หน้าต่าง Safari ของปิ๊ก

`--audio` รับ WAV/PCM ที่เตรียมเป็น soundtrack แล้ว รักษา sample rate และตัดตาม sample frame; ค่าเริ่มต้นของ `--audio-start` คือ `--start`. รับโมโนมาตรฐาน (กลาง) หรือสเตอริโอมาตรฐาน (หน้าซ้าย–ขวา); ถ้า WAV ระบุตำแหน่งลำโพงอื่นจะปฏิเสธก่อนเปิด WebKit ไม่แปลงเสียงหลังเป็นเสียงหน้า. ตัว worker อ่านเสียงแบบ pull-driven ต่อก้อน; เข้ารหัส AAC **96 kb/s mono** หรือ **160 kb/s stereo** ถ้าสเปกเสียง/codec/bitrate ของงานไม่ตรง ให้ใช้ backend อื่นที่ตรวจแล้วผ่านคิว ไม่อ้างว่า AAC เท่ากับ PCM แบบไร้การสูญเสีย ปิดส่วนจับภาพก่อนทำสิ่งนี้และคัดลอกแทร็กภาพเดิม ไม่ encode ภาพอีกรอบ

ไม่รองรับ embedded video/iframe หรือ arbitrary playback hooks ผ่าน `html` (กรณีต้องการรวมวิดีโอพื้นหลังกับ HTML overlay ให้ใช้ `hybrid`); `--subtitles` รองรับแทร็กซับ `tx3g` จากไฟล์ `.srt` พร้อม `--subtitle-lang` และ `--transparent` ใช้ร่วมกับ `--codec hevc-alpha|prores4444` ไฟล์ปลายทางต้องเป็นชื่อใหม่และโฟลเดอร์ต้องมีอยู่ก่อน

## การติดตั้งและตรวจบนเครื่อง

ใช้ macOS กับ Apple SDK; build ลง scratch ไม่ใช่ในโฟลเดอร์วิดีโอ ผู้ติดตั้งทำงานเฉพาะใน prefix ส่วนตัว ตรวจว่า native binaries ลิงก์กับระบบ Apple, ตรวจ clock resource และ SHA ทุกไฟล์ เป็น release บนดิสก์ภายในพร้อม symlink ภายใน prefix เดียว ไม่ต้องมี daemon หรือเสียบไดรฟ์ Main เพื่อเรียกคิว เมื่อต้องใช้ไฟล์ฉากบน Main ไดรฟ์นั้นต้องอยู่ตามปกติ

```sh
LAB="$(mktemp -d "${TMPDIR%/}/safarium-build.XXXXXXXX")"
swift build -c release --jobs 2 --product safarium-html --scratch-path "$LAB/build"
swift build -c release --jobs 2 --product safarium-media --scratch-path "$LAB/build"
RELEASE="$(swift build -c release --scratch-path "$LAB/build" --show-bin-path)"
xcrun swiftc -parse-as-library -O Tools/safarium-verify.swift -o "$LAB/safarium-verify"
python3 Tools/install-render.py --release "$RELEASE" --verifier "$LAB/safarium-verify"
python3 Tools/install-render.py --check
"$HOME/.local/bin/safarium-render" status
```

การติดตั้งซ้ำจากไฟล์เดิมไม่เปลี่ยน release; หากอัปเดต จะสลับลิงก์ `~/.local/share/safarium/current` ชุดเดียวและเก็บ release เก่าไว้ ไม่แทนไฟล์หรือลิงก์ชื่อเดียวกันที่ผู้ใช้ติดตั้งเอง งานที่กำลังถือคิวหรืองานที่รออยู่ยังใช้คิวระดับบัญชีเดียวกัน

หาก AI ในแอปอ่านเฉพาะกฎของโปรเจกต์ เช่น OpenFilm/Pi โหมดในตัว เมื่อสร้าง **โปรเจกต์วิดีโอใหม่** ให้เพิ่มข้อความจาก `~/.local/share/safarium/project-video-rule.md` ในไฟล์คำสั่งที่แอปเลือกจริง ณ โฟลเดอร์งาน ถ้าเป็นโปรเจกต์ใหม่ที่ไม่มีไฟล์คำสั่งอื่นเลย ใช้ข้อความนี้ใน `AGENTS.md` ได้ อย่าสร้างไฟล์ที่มีลำดับสูงกว่าไปบังกฎเดิม และอย่าแก้ app bundle หรือสคริปต์เปิดงานของทุกโปรเจกต์ แอปแชตบนคลาวด์ไม่ได้อ่านไฟล์บน Mac โดยอัตโนมัติ

## ตรวจจากหลักฐานจริง

ชุดทดสอบ queue ใช้ worker เล็กใน scratch; ชุด `Tests/queue-integration/verify-installed.py --scratch "$LAB"` ใช้สองโฟลเดอร์เรียกจุดเข้าเดียวกัน สั่งวาด EP30 สองช่วง ตรวจการไม่ซ้อน และตรวจภาพ/เสียงกับไฟล์ทองอ้างอิงเดิม (golden) ด้วย `verify` การจะรันซ้ำต้องมี EP30 เดิมและ golden หรือระบุ `--reference` กับ `--silent-reference` ที่ตรงกับช่วงนั้น ข้อมูลตัวอย่างและไฟล์ที่ทดสอบอยู่ใน scratch; คำสั่งทดสอบไม่เปลี่ยนค่าเริ่มต้นของโปรเจกต์ต้นทาง

ตรวจชุดส่งมอบ SF-VIDEO-1 ทั้งหมดบน Mac นี้ (หลังติดตั้งและลงกฎแล้ว): `python3 Tests/verify-shared-standard.py --scratch "$LAB" --swift --rules` ทำงานเบื้องหลังด้วย Apple stack และเก็บ `summary.json` พร้อม log แยกแต่ละด่าน. ด่านนี้ไม่ใช้ `Tests/verify-render-stack.py` เดิมซึ่งมีส่วน FFmpeg. ผลการกระจายกฎ: [render-rule-coverage](docs/render-rule-coverage.md)

