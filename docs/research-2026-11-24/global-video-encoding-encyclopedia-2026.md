# Global Video Encoding Encyclopedia (2025–2026) vs. Safarium

> **Scope:** Complete worldwide survey of **every major video & paired-audio encoding family on Earth** (Software/OSS, Next-Gen Standards, Commercial CAE, Discrete GPU & Datacenter ASICs, Cinema/Mezzanine/Lossless/Live-VJ/RAW, Neural/AI Video Codecs, Audio & Streaming Pipelines) compared honestly against **Safarium** — a **100% macOS / Apple Silicon native** rendering & media engine (`WKWebView` + `Metal` + `VideoToolbox` + `AudioToolbox` + `Accelerate` + `Vision`/ANE + `APFS`, **0% FFmpeg / 0% Chrome / 0% OpenCV**).
>
> **Primary R&D Objective:** Map where Safarium wins, where every rival on Earth genuinely wins, and extract **concrete, actionable macOS 15–27 / Apple Silicon native upgrades** (with exact Apple framework APIs) to close compression efficiency (BD-Rate) and pro-feature gaps without ever adding FFmpeg or GPL bloat.
>
> **Companion Docs:** [World Ecosystem Matrix (47 Tools)](world-video-ecosystem-matrix.md) · [Empirical Benchmarks (`H1–H7`)](experiment-results.md) · [MCP Server (`safarium-mcp`)](../mcp-server.md)

---

## 0. Safarium's Apple Silicon Baseline (M1–M5 · macOS 14–27)

Apple Silicon's **Media Engine + VideoToolbox** is a fixed-function silicon ASIC integrated on the same Unified Memory Architecture (UMA) as the GPU, CPU, and Neural Engine.

| Apple Silicon Tier | Video Decode Engines (H.264/HEVC) | Video Encode Engines (H.264/HEVC) | ProRes / ProRes RAW Engines | HEVC 4:2:2 10-bit HW | AV1 HW Decode | VVC (H.266) HW Decode | AV1 / VVC HW Encode |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **M1** | 1 | 1 | 0 *(None)* | Dec & Enc | No | No | **No** |
| **M1 Pro** | 1 | 1 | 1 | Dec & Enc | No | No | **No** |
| **M2 / M2 Pro** | 1 | 1 | 1 | Dec & Enc | No | No | **No** |
| **M3 / M3 Pro** | 1 | 1 | 1 | Dec & Enc | **Yes** | macOS 26+ | **No** |
| **M4 / M4 Pro** | 1 | 1 | 1 | Dec & Enc | **Yes** | macOS 26+ | **No** |
| **M5 / M5 Pro** | 1 | 1 | 1 | Dec & Enc | **Yes** | macOS 26+ | **No** |
| **M1–M5 Max** | 1 | **2** | **2** | Dec & Enc | M3 Max+ | M3 Max+ (macOS 26+) | **No** |
| **M1/M2/M3/M5 Ultra** | **2** | **4** | **4** | Dec & Enc | M3/M5 Ultra | M3/M5 Ultra (macOS 26+) | **No** |

**What Safarium Already Uses Today vs. Untapped Apple Silicon Potential:**
- **Already active in Safarium:** Windowless `WKWebView` + Metal DAG + `AVAssetWriterSink` (H.264, HEVC, `HEVCWithAlpha` `'muxa'`, ProRes 422/4444), `SuggestedLookAheadFrameCount` (macOS 15+), `AllowOpenGOP = false` (Closed-GOP APFS `clonefile` cache), `VTFrameProcessor` Low-Latency Super Resolution (`LLSR`), and AudioToolbox AAC-LC / LPCM.
- **Honest Baseline Reality (Wave 7 `H3` + 2025–2026 Industry Benchmarks):**
  - **Speed & RAM Dominance:** Single-pass VideoToolbox encodes **2×–12× faster** than CPU software encoders (`~200 fps` 1080p HEVC 10-bit; `~68–256 fps` 4K GPU pipelines) at **3×–10× lower Peak RAM** (`72–302 MiB` vs. `356–12,000 MiB`) and a fraction of CPU power/heat.
  - **Honest BD-Rate Gap:** Default 1-pass VideoToolbox HEVC needs **~20–35% more bitrate** than slow CPU `x265 4.3` at tight bitrates, **~35–55% more** than `SVT-AV1 4.3 / SVT-AV1-HDR`, and **~50–65% more** than `VVenC 1.14` / `AV2 (avm 1.0)`. Default 1-pass VideoToolbox H.264 trails `x264` by **~25–40%**.
  - **Key Finding:** Almost every major quality lever Apple shipped in **macOS 15 → 26 → 27** (`SpatialAdaptiveQPLevel`, `HighQuality` presets, `VariableBitRate` + VBV, `ConstantQualityFactor`, true 2-pass `VTMultiPassStorage`, multi-engine chunking, `VTTemporalNoiseFilter`, 10-bit `Main10` default, 4:2:2/4:4:4, Dolby Vision 8.4 `VTHDRPerFrameMetadataGenerationSession`, MV-HEVC, APAC spatial audio) is **not yet unlocked in Safarium** — representing a massive zero-FFmpeg upgrade path (Section 8).

---

## 1. Software & Open-Source Video Encoders Worldwide

### 1.1 H.264 / AVC Family

| Encoder | Latest (2025–2026) | License & Patents | BD-Rate Efficiency | Apple Silicon Speed & Peak RAM | Key Strengths |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`x264` (8 / 10-bit)** | Rolling Git (2025–2026) | **GPLv2+** / commercial (patents separate) | **Baseline (0%)**. 10-bit Hi10P saves **5–12%** (up to 20% on animation/gradients). Beats 1-pass VT H.264 by **~25–40%**. | Native AArch64 NEON. Base M4: **55.9 fps (1080p)**, **13.0 fps (4K)**. RAM: **0.3–1.0 GB (1080p)** / **1.5–2.5 GB (4K)**. | Gold-standard H.264 psychovisual tuning (`psy-rd`, AQ, MB-tree), 4:2:2/4:4:4, lossless, universal decode (8-bit). |
| **Cisco `OpenH264`** | **v2.7.0** (Oct 2026) | **BSD-2-Clause** (Cisco indemnifies royalties *only* for official Cisco binaries) | **+25–40%+ worse** than `x264` (Constrained Baseline, no B-frames in RTC). | Fast CPU SIMD; **<0.3 GB** RAM. | WebRTC ultra-low-latency, 4-layer temporal SVC, simulcast. |
| **MainConcept AVC** | **Codec SDK 16.2** (Apr–May 2026) | Commercial proprietary | Matches/beats `x264` in broadcast; **SDK 16.2 added CTQ** closed-loop quality via AI **VMAF-E** (10× faster than CPU VMAF). | CPU + unified **EVA** GPU/VPU offload (up to 2× OSS). | Broadcast 10-bit 4:2:2, AVC-Intra, SABET multi-rendition ladders. |
| **Beamr 4 / 4x (CABR)** | Active 2025–2026 (SDK / NVENC / Cloud) | Proprietary (~53 patents; Cloud $0.006–$0.024/min) | **−30% to −50% bitrate** vs. standard `x264`/NVENC at perceptual parity (BQM closed-loop). | Xeon CPU or NVIDIA NVENC/Holoscan (up to 4Kp60). Not Apple Silicon native. | Frame-level ITU-R BT.500 validated perceptual rate control. |

- **Safarium Wins:** Speed, RAM, battery/thermals, zero GPL entanglement, Apple patent indemnification.
- **Rivals Win:** `x264` wins decisively on H.264 compression efficiency at low/medium bitrates; `Beamr 4x` & `MainConcept CTQ` win on automated perceptual closed-loop H.264 optimization.

### 1.2 H.265 / HEVC Family

| Encoder | Latest (2025–2026) | License & Patents | BD-Rate Efficiency | Apple Silicon Speed & Peak RAM | Key Strengths |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`x265` (8 / 10 / 12-bit)** | **v4.3** (Jul 2026); v4.2 (Apr 2026) | **GPLv2+** / commercial (patents separate) | **−40% to −50% vs. `x264`**. 10-bit saves **5–7%** vs. 8-bit. Beats 1-pass VT HEVC by **~20–35%** at tight bitrates. | Major NEON/SVE2 overhauls in v4.0–4.3. Base M4: **82.0 fps (1080p)**, **17.4 fps (4K)**. RAM: **0.5–1.2 GB (1080p)** / **1.5–3.5 GB (4K)**. | 8/10/12-bit, HDR10/HDR10+/Dolby Vision, Alpha (`--alpha`), SCC (`--scc`), MV-HEVC, AOM FGS SEI, foveated encoding (v4.3). |
| **`Kvazaar`** | **v2.3.2** (Late 2025 — maintenance mode) | **BSD-3-Clause** (patents separate) | Trails `x265` on slow VOD; strong on many-core fast presets. | **Weak on ARM64:** x86 AVX-focused; base M4 hits only **3.5 fps (4K Slow)**. | Non-GPL permissive license, x86 many-core scalability. |
| **`SVT-HEVC`** | **v1.5.1 — Archived / Discontinued** (Jul 2024) | BSD-2-Clause-Patent | Trails `x265` on VOD. | **x86-64 only (no ARM64)**; obsolete on macOS. | Legacy Xeon live HEVC only. |
| **MainConcept HEVC** | **Codec SDK 16.1 / 16.2** (2026) | Commercial proprietary | **−12% to −24% BD-rate vs. `x265`** (10-bit tests); **CTQ (VMAF-E)** closed-loop single-pass. | Fast CPU + EVA GPU/Arm/NETINT offload. | 10-bit HDR, MV-HEVC SDK (`delta_qp_multiview`), broadcast 4:2:2. |
| **Beamr 5 / 5x (CABR)** | Active 2025–2026 | Commercial / SaaS | **−30% to −50%** vs. standard `x265`/NVENC (41–57% vs. default NVENC in May 2026 tests). | 2×–6× faster than `x265` on Xeon; 4Kp60 via NVENC. | Perceptual BQM, ML-safe compression for AI/AV pipelines. |

- **Safarium Wins:** Hardware 10-bit `Main10`, 10-bit `4:2:2`, `HEVCWithAlpha`, and `MV-HEVC` at **5–10× `x265` speed** and **~10× lower RAM**, zero GPL, native Apple patent coverage.
- **Rivals Win:** `x265 4.3` wins by **~20–35% BD-rate** at tight bitrates and offers 12-bit + granular psychovisual/grain controls; `Beamr 5x` & `MainConcept` win on enterprise closed-loop perceptual quality.

### 1.3 AV1 Encoder Family

> **Hard Apple Silicon Reality (Late 2026):** M3/M4/M5 decode AV1 in hardware, but **no Apple Silicon chip has a hardware AV1 encoder**. AV1 encoding on macOS is CPU-only today.

| Encoder | Latest (2025–2026) | License | BD-Rate Efficiency | Apple Silicon Speed & Peak RAM | Key Strengths |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`SVT-AV1` (Mainline)** | **v4.3.0** (Nov 2026); v4.0 (Jan 2026) | **BSD-3-Clause-Clear** (AOM Royalty-Free) | **−20% to −30% vs. `x265`** (**−35–55% vs. VT HEVC**). v4.2 `TUNE-VMAF` (+15% VMAF BD); v4.0 upstreamed `--tune vq` & AC Bias. | Massive ARM64 NEON gains (+6× over C, +10–11% MT in v4.3). Base M4: **~38 fps (1080p 10-bit P6)**. RAM: **1.3–4.0 GB (1080p)** / **4–12 GB (4K)**. | Production OSS AV1 king: 10-bit HDR, Film Grain Synthesis (`--fgs-table`), `--fast-decode`, `--rtc`, fast `--avif`. |
| **`SVT-AV1-HDR` / `-Essential`** *(succeeded archived `-PSY`)* | **`-PSY` archived** (Feb 2026); **`SVT-AV1-HDR` v4.3.0** & **`-Essential` v4.3.1** (Nov 2026) | **BSD-3-Clause-Clear** (AOM Royalty-Free) | `-HDR` Tune 6 matched mainline visual quality on grainy 4K HDR at **56.6% of the bitrate** (6 vs. 10.6 Mbps). | Same ARM64 NEON speed as mainline 4.3; `-Essential` adds `--low-memory`. | PQ Variance Boost for HDR10, **High Profile 4:4:4** (crisp UI/text/screen content), complex-HVS, quality-first defaults. |
| **`libaom` (`aomenc`)** | **v3.15.3** (Oct 2026); v3.14 (Jul 2026) | **BSD-2-Clause** (AOM Royalty-Free) | Highest OSS AV1 ceiling. v3.14 cut speed 0–1 runtime **~40%** while lifting VMAF **+7–8%**. `TUNE_IQ`/SSIMULACRA2 gained **12–17%** on AVIF. | Heavy ARM NEON + Armv8.6 I8MM (+15–25%). Slow single-instance scaling. RAM: **1.0–2.5 GB (1080p)** / **3.0–5.0 GB (4K)**. | Best AVIF quality, anti-aliased text/screen coding (`--screen-detection-mode=2`), low-complexity HD decode. |
| **`rav1e`** | **v0.8.1** (Jun 2025) | **BSD-2-Clause** (Rust, RF) | Trails `SVT-AV1` and `libaom` in 2026 BD-rate and energy efficiency. | Native `aarch64` NEON, but **~5× slower than `SVT-AV1`**. RAM: **1–3 GB (1080p)** / **4–8+ GB (4K)**. | Pure Rust memory safety, odd dimensions & **>16K resolutions**. |
| **Visionular `Aurora1`** | **SDK Jun 2026** & **RTC v1.5.1** | Commercial proprietary | Vendor claims: **−5–10% vs. `libaom`** (VOD), up to **−30% vs. `SVT-AV1`**, **−54.75% VMAF vs. `libaom` RT**. *(Note: `Tencent_TXAV1` led public MSU 2025 AV1.)* | Dedicated ARM NEON passes; single-core 1080p screen coding & mobile RTC. | AI-assisted VOD + ultra-low-latency RTC AV1, keyframe-free resolution switching. |

- **Safarium Wins:** **4–10× faster** real-world export, **10× lower RAM**, cool/silent laptop operation, native ProRes/alpha/MV-HEVC.
- **Rivals Win:** **~35–55% smaller files** at matched visual quality, **100% royalty-free web distribution**, native **Film Grain Synthesis**, and **4:4:4 screen-content fidelity** (`SVT-AV1-HDR`).

### 1.4 Next-Gen & Emerging Standards (2025–2026)

| Standard / Encoder | Latest (2025–2026) | License & Patents | BD-Rate Efficiency | Speed & RAM (ARM64) | Ecosystem & Safarium Relevance |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **AOMedia AV2 (`avm`)** | **FINALIZED! Spec & AVM v1.0.0 published May 28, 2026** (announced Jun 9, 2026) | **AOMedia Royalty-Free** (`BSD-3-Clause-Clear`) | **−29.81% PSNR / −33.79% VMAF vs. AV1** (May 2026 Meta/Apple/Amazon CTC paper); **>40% gain on screen content**! | Reference `avm` is **~33× slower to encode** & 3.86× slower to decode than AV1. Early **`dav2d`** & **`SVT-AV2`** prototypes demoed late 2026. | **Future king of royalty-free web & screen-content video.** YouTube initial rollout ~2027; consumer HW decode ~2027–2028. Huge future fit for `WKWebView` rendering! |
| **H.266/VVC — Fraunhofer `VVenC`** | **v1.14.0** (Jan 2026); v1.15-dev | `BSD-3-Clause-Clear` (VVC patent pools separate: Access Advance / Via LA) | **−50–55% vs. H.264**, **−35–39% vs. `x265`**, **−10–15% vs. AV1**. | v1.14 added ARM NEON/SVE (+35% 4K `fast`). ~4–25+ fps 1080p on Apple Silicon. RAM: **1.5–3 GB (1080p)** / **4–8+ GB (4K)**. | Production broadcast VVC (**Brazil TV 3.0 / DTV+**, Android 17 SW decode, Apple macOS 26 M3+ HW decode). **Zero browser support** as of Nov 2026. |
| **H.266/VVC — JVET `VTM`** | **VTM-24.0** (Apr 2026) | `BSD-3-Clause` (no patents) | **−37.7% inter** vs. HEVC HM. *(Beyond-VVC **ECM** adds another −17–28% in R&D.)* | Research-only reference software (minutes per second of 4K). | Standards verification only; not for production. |
| **H.266/VVC — `uvg266`** | **v0.8.1+** (active 2026) | `BSD-3-Clause` (patents separate) | Trails `VVenC` in VOD; strong fast All-Intra live VVC. | Only OSS VVC encoder in MSU 2025 Fast (30 fps) tier; ARM NEON added late 2026. | Live low-latency 4K30p VVC research (`uvgRTP` + `OpenVVC`). |
| **MPEG-5 Part 1 EVC (`XEVE`)** | **v0.7.0** (Aug 2026) | `BSD-3` (RF Baseline / Paid Main) | Baseline: −30–40% vs. H.264; Main: −26–41% vs. HEVC. | Slower than `SVT-AV1`. | **Commercially stalled** — squeezed out between AV1/AV2 and VVC. |
| **MPEG-5 Part 2 LCEVC (V-Nova)** | **`LCEVCdec` v4** (2025, Clear BSD + Vulkan decode) | Commercial ($0.20–$0.70/dev after free OEM tier ended Aug 2025; FTA free) | Adds **−28–46% vs. H.264** and **−22–31% vs. HEVC** on top of any base codec. | **2×–3× faster encoding** (base encodes at ¼ pixels + lightweight residual layer). | **Mandated in Brazil TV 3.0 (DTV+)** (Jun 2026 World Cup). Limited general OTT due to royalties; strong architectural inspiration. |
| **AVS3 (`uAVS3e`)** | Active China ecosystem | `BSD-4-Clause` + AVS pool | **−20–34% vs. HEVC** (~−8.85% vs. AV1). | 30–50× faster than HPM ref; x86/ARM. | China 4K/8K broadcast (CCTV 8K, HDR/Audio Vivid). Inactive outside China / macOS. |

### 1.5 Web / Open Legacy & Niche Codecs

| Codec / Encoder | Latest (2025–2026) | License | Efficiency & Speed | Current Status vs. Safarium |
| :--- | :--- | :--- | :--- | :--- |
| **VP9 (`libvpx-vp9`)** | **v1.17.0** (Aug 2026) | `BSD-3-Clause` (RF) | −23% to −44% vs. `x264`; ~30–34% worse than AV1; slow single-instance (0.5–2 GB RAM). | Only remaining edge over Safarium: **cross-browser WebM VP9 + Alpha** (Chrome/Firefox/Android), whereas Apple `HEVCWithAlpha` plays natively only on Apple platforms. |
| **`SVT-VP9`** | v0.3.1 (Dec 2025) | BSD-2-Patent | 8-bit only, **x86-64 only** (no ARM64). | Irrelevant on Apple Silicon. |
| **VP8 (`libvpx`)** | v1.17.0 (Aug 2026) | `BSD-3-Clause` | +20–30% worse than `x264`. | Legacy WebRTC fallback only. |
| **Theora (`libtheora`)** | v1.2.0 (Mar 2025) | `BSD-3-Clause` | MPEG-4 ASP era; removed from Chrome & Firefox. | Archival / historical only. |
| **Dirac / VC-2** | SMPTE ST 2042-1:2022 | Royalty-free | Intra wavelet mezzanine, ultra-low latency. | Broadcast mezzanine; Safarium replaces this natively via hardware **ProRes**. |
| **Daala** | Inactive / Superseded | `BSD-2-Clause` | Donated CfL & CDEF tools to AV1. | Historic R&D predecessor to AV1/AV2. |

### 1.6 Perceptual & Content-Adaptive Cloud Encoders (CAE)

| Platform | Core Optimization Technique | 2025–2026 Verified Milestones | What Safarium Learns From It |
| :--- | :--- | :--- | :--- |
| **Netflix CAE (Dynamic Optimizer)** | **Shot-based encoding** sweeping `(resolution, QP)` using **VMAF + CAMBI (banding)** to pick Pareto convex hull + AV1 Film Grain Synthesis. | AV1 hit **~30% of Netflix traffic (Dec 2025)**; FGS deployed at scale (Jul 2025). | **Shot-cut detection + per-shot quality steering + banding prevention** directly inside Metal before VideoToolbox! |
| **Beamr CABR** | Frame-level closed-loop **BQM** perceptual rate control across AVC/HEVC/AV1 + RTX VSR. | **30–50% bitrate savings** (41–57% vs. default NVENC in May 2026 tests). | Combining **pre-encode enhancement (`VTFrameProcessor`) + closed-loop perceptual quality** (`SafariumPQ`). |
| **Bitmovin Encoder V3** | Fast complexity lookahead + Per-Title/Per-Shot convex hull + RT-VMAF. | **Sep 2026 V3:** −15.5% HEVC, −30.6% AV1, 3× faster AV1, **MCP server**. | Validates **`safarium-mcp`** + complexity lookahead (`SuggestedLookAheadFrameCount`). |
| **MediaKind (ex-Harmonic) EyeQ** | Real-time ML Human Visual System (HVS) quality modeling. | Acquired by MediaKind (Jun 2026, ~$145M); up to **50% live bitrate savings**; VVC/LCEVC/DTV+. | Perceptual spatial AQ (`SpatialAdaptiveQPLevel`) & constant quality (`ConstantQualityFactor`). |
| **Ateme TITAN** | Real-time CAE, Smart Constant Quality (SCQ), Audience-Aware Encoding. | Cut UEFA live CDN traffic **>33%**; Apr 2026 live **Apple Immersive Video (MV-HEVC)**; IBC 2026 **MCP** & MoQ. | Validates local **MV-HEVC** & AI/MCP agent control with zero cloud bills. |

---

## 2. Hardware, GPU & Datacenter ASIC Encoders Worldwide

### 2.1 Discrete GPU & PC SoC Encoders

| Vendor / Architecture | Media Engines | Key 2025–2026 Capabilities | Limitations vs. Apple Silicon / Safarium |
| :--- | :--- | :--- | :--- |
| **NVIDIA Blackwell** (RTX 50 / PRO 6000) | **9th-Gen NVENC** (up to **3×** RTX 5090, **4×** PRO 6000) | **AV1 UHQ** (+15% total BD-BR vs. Ada at ~3× SW AV1 speed), **AV1 hierarchical B-frames (up to 31)** in SDK 13.1, **native 4:2:2 8/10-bit** (H.264/HEVC), **MV-HEVC**, H.264 10-bit, 3–4-way Split-Frame Encoding. | Requires discrete 200–600W PCIe GPU + proprietary CUDA/NVENC; no ProRes ASIC; not available on macOS. |
| **NVIDIA Ada Lovelace** (RTX 40) | 8th-Gen NVENC (1–3×) | AV1/HEVC 8/10-bit 4:2:0 & 4:4:4; AV1 UHQ (SDK 13.0); 2–3-way SFE. | No 4:2:2 HW acceleration; H.264 8-bit progressive only. |
| **Intel Arc Battlemage / Alchemist** (Arc B580 Xe2) | **Xe2 Quick Sync Video** (Dual MFX + Deep Link) | Broadest codec matrix on PC: **AV1** (8/10-bit w/ B-pyramid & EncTools lookahead), **HEVC** (8/10-bit **4:2:0, 4:2:2, 4:4:4**, up to 16 B-frames), **H.264**, **VP9 hardware encode** (~330 fps 1080p / ~85 fps 4K AV1 at ~47W). | Discrete BMG-G21 omits VVC HW decode (Lunar Lake Xe2 iGPU only); no macOS support; no ProRes ASIC. |
| **AMD RDNA 4 / RDNA 3** (RX 9070 XT) | **Dual VCN 5.0** (AMF SDK v1.4.36+) | Up to 8K75 AV1/HEVC, split-frame encode, **AV1 B-frames newly added** (up to 3 consecutive), +25% low-latency H.264 quality. | **No HEVC B-frames** even on VCN 5.0; **4:2:0 only** (no 4:2:2/4:4:4); no VP9 encode. |
| **Qualcomm Snapdragon 8 Elite Gen 5 / X2 Elite** | Mobile / PC Adreno VPU | **8 Elite Gen 5 (mobile):** first SoC with **HW APV encode/decode** (8K30, Galaxy S26 Ultra / Android 16) + HEVC 10-bit (AV1 decode only). **X2 Elite (PC):** Dual 8K30 AVC/HEVC + **AV1 HW encode (4K60 / 8K15)**. | Windows MF 10-bit API caveats on X2; no APV HW on X2; no macOS support. |

### 2.2 Datacenter Dedicated Video ASICs

*(NETINT, AMD, Google, and Meta jointly won the 75th Technology & Engineering Emmy Award for cloud hardware video accelerators.)*

| ASIC Platform | Silicon / Form Factor | Encode Codecs & Stream Density | Power / Latency / 2025–2026 Status |
| :--- | :--- | :--- | :--- |
| **NETINT Quadra T1U / T2A** | 14nm Codensity G5 (U.2 / HHHL PCIe) + 15–36 TOPS AI ROI | H.264, HEVC, **AV1 8/10-bit**, JPEG/AVIF; **32× 1080p30 (T1U) / 64× 1080p30 (T2A)**. *(No AV1 decode.)* | **17W / 40W**, <5 ms 1080p, driverless NVMe protocol, GPU P2P DMA; **225k+ VPUs deployed** (Sep 2026); Akamai Cloud 8-card nodes. |
| **AMD / Xilinx Alveo MA35D** | 5nm Dual-VPU PCIe Gen4 x8 (~$1,595) | **AV1** (32× 1080p60 / 8× 4Kp60), H.264/HEVC; **includes AV1 HW decode**. | **35W**, 8 ms 4Kp60 AV1; Azure `NMads MA35D` VMs; AMA SDK 1.5 on FFmpeg 8.0. |
| **Google Argos VCU** | Internal hyperscaler dual-chip PCIe VCU | Gen 1: H.264/VP9; Gen 2: **AV1** (20× 4Kp60/card) w/ hybrid HW/SW RC. | 20–33× efficiency vs. CPU; **>75% of YouTube playback is AV1**; researching AV2 (~2027 rollout). |
| **Meta MSVP** | Internal hyperscaler PCIe-DMA ASIC | Gen 1: H.264 & VP9 (~9× `libx264`); H.264/HEVC/VP9/AV1 decode. | Powers VOD & Live; AV1 >70% of Meta playback via optimized stacks. |

- **Safarium's Honest Position vs. Hardware/ASIC World:** On macOS laptops/desktops, Apple Silicon's **UMA zero-copy Media Engine + ProRes ASIC + WebKit + Metal** is unmatched for **all-in-one local creation** (HTML/3D/ProRes/HEVC-Alpha/MV-HEVC at ultra-low watts & RAM). Discrete Blackwell NVENC, Intel Battlemage QSV, and NETINT/Alveo ASICs win decisively on **hardware AV1 encoding** and multi-dozen-stream datacenter transcode farms.

---

## 3. Cinema, Mezzanine, Lossless, Live-VJ & Camera RAW Codecs

| Category | Codec | 2025–2026 Status & Key Specs | Safarium Comparison |
| :--- | :--- | :--- | :--- |
| **Mezzanine** | **Apple ProRes** (`apco`, `apcs`, `apcn`, `apch`, `ap4h`, `ap4x`) | 10-bit 4:2:2 & 12-bit 4:4:4:4 (+ alpha); dedicated hardware ASIC on M1 Pro+ and M2–M5. | **Safarium native strength** — currently exposes 422/4444; easy upgrade to expose all 6 ProRes tiers cleanly. |
| **Mezzanine** | **Samsung / IETF APV** (**RFC 9924**, Feb 2026) | Open-source, **royalty-free** DCT+VLC intra mezzanine (10–16-bit, 4:2:2/4:4:4/alpha, ~10–20% smaller than ProRes). Adopted in **Android 16**, Galaxy S26 Ultra HW, ASWF **OpenAPV 1.1.3**, DaVinci Resolve 20.2+, FFmpeg 9.1 Vulkan encode. | Major cross-platform open rival to ProRes; worth tracking via zero-FFmpeg `liboapv` (BSD-3) if Android/Linux mezzanine exchange is needed. |
| **Mezzanine** | **Avid DNx** (SMPTE ST 2019-1 / VC-3) | Rebranded unified **Avid DNx** (IBC 2025); 8–16-bit + RGB HQ/SQ tiers; macOS ARM SDK. | Studio Avid Media Composer standard; ProRes covers macOS/FCP/Resolve natively with HW ASIC. |
| **Mezzanine** | **GoPro CineForm** | Official `gopro/cineform-sdk` **archived Apr 2025** (maintenance/legacy mode). | Legacy; superseded by ProRes and APV. |
| **IP Broadcast** | **JPEG XS** (ISO/IEC 21122) | Sub-frame latency (**1–32 lines / <10 ms**), 2:1–10:1 visually lossless; standard for SMPTE ST 2110 / IPMX. RAND patent-licensed. | Ultra-low-latency live broadcast IP transport (different domain from Safarium's offline/programmable renderer). |
| **Cinema DCP** | **JPEG 2000 & HTJ2K** (ISO/IEC 15444-15) | **HTJ2K is 10–30× faster** than J2K-1 (mathematically reversible); DCP/IMF/archival MXF; open-source **OpenJPH** (now inside OpenEXR 3.4+). | Cinema mastering / archival; `SafariumRaster` can inspect/interoperate via OpenEXR / ImageIO. |
| **Lossless / Archival** | **FFV1** (IETF RFC 9043) | Library of Congress / FADGI archival gold standard. **Breakthrough:** FFmpeg 8.0/8.1 added **Vulkan GPU compute FFV1** (~500 fps 4K 10-bit). | Mathematically lossless archival; Safarium offers ProRes 4444 XQ visually lossless or lossless PNG/EXR sequences today. |
| **Lossless / VFX** | **UtVideo** (v23.2), **MagicYUV** (v2.4.2), **HuffYUV**, **OpenEXR** (v3.4 HTJ2K / v3.5 ZSTD) | Fast intra lossless AVI/MOV capture & VFX linear EXR (`ZSTD` + `HTJ2K` in OpenEXR 3.4–3.5). | `SafariumRaster` already supports scanline OpenEXR natively; ProRes 4444 covers intermediate capture on macOS. |
| **Live GPU / VJ** | **HAP** (HAP / Q / Alpha / R BC7 / HDR BC6) & **NotchLC** | GPU-decompressed DXT/BC texture codecs for Resolume/TouchDesigner/VJ servers. Both gained **macOS 15+ `MediaExtension`** native AVFoundation decoders in 2026! | Specialized real-time multi-layer VJ playback; `MediaExtension` means Safarium's AVFoundation reader can ingest them natively when installed. |
| **Camera RAW** | **ProRes RAW**, **Blackmagic RAW (v6.0)**, **RED R3D (R3D NE)**, **ARRI ARRIRAW / ARRICORE (RDD 61:2025)**, **Canon `.CRM`** | 2025–2026 breakthroughs: ProRes RAW on iPhone 17/18 Pro + DaVinci Resolve 20.2 + FFmpeg 8 Vulkan; BRAW 6.0 Gen 6; ARRICORE (~50% lower data rate); `.CRM` Apple Silicon GPU accel. | Apple Silicon decodes **ProRes RAW** in hardware natively via VideoToolbox/AVFoundation. |

---

## 4. Neural / AI Video Codecs (2024–2026)

| Codec / Lineage | Paradigm | Verified 2025–2026 Performance | Practical Status & Apple Silicon Outlook |
| :--- | :--- | :--- | :--- |
| **Microsoft `DCVC-FM` → `DCVC-RT` → `DCVC-UF`** | Conditional autoencoder NVC (implicit temporal → 8-frame chunk latents) | **`DCVC-RT` (CVPR 2025):** 125 fps enc / 113 fps dec (1080p A100), **−21% BD-rate vs. VVC/VTM**. **`DCVC-UF` (CVPR 2026):** **371–656 fps** on RTX 4090 (1,415 fps B200) with **−42.2% BD-rate vs. VTM-17.0**! | Massive research breakthrough proving neural codecs now beat VVC *and* run >300 fps on GPUs — still non-standard bitstream (no universal player). |
| **Microsoft `MLVC`** *(MIT License, Jul 2026)* | Edge NPU neural codec | **~100 fps @ 540p** natively on **Apple CoreML (ANE)**, OpenVINO & QNN; **>70% MOS BD-rate savings vs. HW HEVC**. | Proof that Apple Silicon's **Neural Engine (ANE)** can run real-time neural video coding! Worth watching for specialized AI-to-AI / RTC transport. |
| **Orange `Cool-Chic` v3 → v5** | Overfitted INR (tiny per-clip weights shipped in bitstream) | **~800–2,000 MACs/pixel decoder** (2–3 orders of magnitude lighter than autoencoders!). **v5.0 (May 2026):** **10× faster encoding**, **−11% bitrate vs. VVC**. | Ultra-cheap CPU/shader decoding, but iterative encode optimization is still too slow for interactive renders. |
| **NVIDIA Maxine / Cosmos** | Semantic face re-animation + video tokenizers | Talking-head keypoint codec (~0.12 KB/frame, **1/10th H.264**); Cosmos discrete/continuous tokenizers. | Domain-specific (talking heads / AI world models); NVIDIA GPU ecosystem. |
| **Diffusion / Tokenized Codecs** (`TVC`, `InfoTok`, `S²VC`, `GNVC-VD`, `DiffVC-ONE`) | Visual tokens & 1-step Video DiT flow-matching | `S²VC` (CVPR 2026): **−51.6% bitrate** vs. prior perceptual; `DiffVC-ONE` (Aug 2026) fixes temporal flicker at ultra-low bitrates. | Generative reconstruction (plausible detail rather than pixel-faithful; unsuitable for exact UI/Thai text/data graphics where Safarium excels). |

---

## 5. Paired Audio & Web / Streaming Pipelines (2025–2026)

### 5.1 Audio Codecs & Apple AudioToolbox

| Audio Codec / Engine | 2025–2026 Highlights | Native macOS / Safarium Status |
| :--- | :--- | :--- |
| **Apple AudioToolbox AAC (`aac_at`)** | **AAC-LC (`'aac '`)**, **HE-AAC v1 (`'aach'`)**, **HE-AAC v2 (`'aacp'`)**. Apple's `aac_at` consistently ranks **#1 in AAC-LC listening tests** (ahead of Fraunhofer `libfdk-aac`) with zero GPL/non-free issues. | **Built into macOS!** Upgrade Safarium to explicitly set `kAudioConverterCodecQuality = kAudioConverterQuality_Max` and expose HE-AAC v1/v2 (verifying `AudioSpecificConfig` to prevent silent fallback). |
| **Apple ALAC (`'alac'`) & FLAC (`'flac'`)** | Native lossless audio in `.mov`/`.m4a`/`.mp4`. ALAC is 100% native encode+decode; FLAC is 100% native decode + partial `afconvert` encode. | Ready to expose directly via AudioToolbox with 0 external libs. |
| **Apple APAC (`'apac'`) / ASAF (Spatial Audio)** | **New in macOS 26 (WWDC 2025)!** Ambisonics up to 3rd order / 64 channels, 64–768 kbps, mandatory loudness + DRC (`AVEncoderContentSourceKey`, `AVEncoderDynamicRangeControlConfigurationKey`, `AVEncoderASPFrequencyKey = 75`, `AUAudioMix`). | Zero-FFmpeg Apple Spatial Audio mastering pair for **MV-HEVC Spatial Video**! |
| **`Opus` (`'opus'` / `libopus` 1.6.1)** | Native AudioToolbox encode/decode since macOS 10.13. Upstream **`libopus` 1.6.1 (Jan 2026)** added ML **DRED** packet-loss recovery, **LACE/NoLACE** speech post-filter, **9 kbps fullband ML BWE**, and experimental **Opus HD** (96 kHz / 24-bit). | Native `'opus'` already available via `AudioConverter` (and `SafariumContainers` MKV/WebM muxer already supports Opus tracks!). |
| **Dolby E-AC-3 / AC-4** | Apple natively decodes/renders Dolby Atmos via **E-AC-3 JOC** (Dolby MAT). **AC-4** (~50% bitrate of E-AC-3) powers ATSC 3.0 & Peacock's FIFA World Cup 2026 (still no mainline FFmpeg AC-4 decoder). | Proprietary Dolby encoding SDK required for authoring; native decode on macOS. |
| **AOMedia IAMF v2.0 / Eclipsa Audio** | Royalty-free immersive audio container (Opus/AAC/FLAC/LPCM); v2.0 (Jan 2026) added object-based audio (YouTube/Samsung). | No native macOS AudioToolbox support yet; requires `libiamf` if authoring for YouTube Eclipsa. |

### 5.2 Web & Streaming Delivery Protocols (2026)

- **WebCodecs + WebTransport:** **Baseline across all 4 browsers** since **Safari 26.0** (`AudioEncoder`/`AudioDecoder`) and **Safari 26.4** (March 2026, WebTransport default-enabled).
- **WHIP / WHEP:** **WHIP** is now **IETF RFC 9725** (Mar 2025); **WHEP** is in IESG review (Nov 2026) and deployed across CDNs.
- **SRT vs. RIST:** **SRT** leads open-internet contribution (~78% broadcast share); **RIST** leads multi-vendor RTP/multicast/ST 2110 WAN links.
- **CMAF (LL-HLS / LL-DASH):** Mature 2–5s low-latency fMP4 delivery with DRM/SSAI.
- **Media over QUIC (MoQ):** Reached `draft-ietf-moq-transport-23` (Nov 2026), unifying <500 ms latency with CDN scale over WebTransport + WebCodecs.

---

## 6. Master Worldwide Quick-Reference Matrix (Late 2026)

| Category | Encoder / Technology | License | Efficiency vs. VT HEVC 10-bit | Apple Silicon Speed | Peak RAM (1080p / 4K) | Honest Verdict vs. Safarium |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Apple Native** | **Safarium (`VideoToolbox` + `Metal`)** | Apple Native (Apache-2.0, **0% FFmpeg**) | **Baseline (0%)** *(major gains via Wave 9 upgrades below)* | **~200 fps (1080p) / 68–256 fps (4K)** | **0.1–0.3 GB / 0.3–0.6 GB** | **Unmatched local all-in-one speed, low RAM, zero-copy WebKit/Metal/ANE & Apple Pro formats** |
| **SW H.264** | `x264` (8/10-bit) | GPLv2+ | −25–40% vs. VT H.264; trails VT HEVC 10-bit | 56 fps / 13 fps (M4) | 0.3–1 GB / 1.5–2.5 GB | Beats VT H.264 efficiency; slower & GPL |
| **SW HEVC** | `x265` 4.3 (8/10/12-bit) | GPLv2+ | **~20–35% better** (tight bitrates) | 82 fps / 17 fps (M4) | 0.5–1.2 GB / 1.5–3.5 GB | Best OSS HEVC density; 5–10× slower & GPL |
| **SW AV1** | `SVT-AV1` 4.3 / `-HDR` | BSD-3-Clear (RF) | **~35–55% better** (4:4:4 & FGS in `-HDR`) | ~38 fps 1080p P6 (M4) | 1.3–4 GB / 4–12 GB | Strongest OSS web/archival rival; optional pure-C add-on |
| **SW AV1** | `libaom` 3.15 / `rav1e` 0.8 | BSD-2 (RF) | **~40–55% better** (`libaom`) | 1–10 fps high-Q | 1–3 GB / 3–8 GB | Best AVIF / ultra-slow VOD |
| **Next-Gen** | **AOMedia AV2 (`avm` 1.0)** | AOM RF (Final May 2026) | **~55–65%+ better** (**>40% over AV1 screen!**) | ~33× slower than AV1 | Very High | **#1 future standard (2027–2028) for WebKit/UI video** |
| **Next-Gen** | Fraunhofer `VVenC` 1.14 / `uvg266` | BSD-3 (+ VVC patents) | **~50–60% better** | 4–25+ fps 1080p (NEON) | 1.5–3 GB / 4–8 GB | Broadcast VVC frontier; zero browser playback |
| **Next-Gen** | `LCEVC` / `EVC` / `AVS3` | Mixed / Commercial | +22–46% enhancement (`LCEVC`) | 2–3× faster (`LCEVC`) | Low–Moderate | Regional broadcast (Brazil DTV+ / China 8K); royalty friction |
| **Web Legacy** | `libvpx-vp9` 1.17 | BSD-3 (RF) | ~15–25% better (1080p) | Slow single-instance | 0.5–2 GB | Only niche edge: cross-browser WebM+Alpha |
| **Cloud CAE** | Netflix / Beamr / Bitmovin V3 / MediaKind / Ateme | Proprietary / SaaS | **~30–55% better** (Per-Shot / BQM / VMAF) | Cloud GPU clusters | Cloud-scale | **Primary architectural blueprint for Safarium Mini-CAE** |
| **Discrete GPU** | NVIDIA Blackwell NVENC / Intel Arc QSV / AMD VCN 5 | Proprietary HW | **HW AV1 UHQ** beats VT HEVC by ~20–35% | 300–600+ fps (multi-engine) | GPU VRAM | Wins HW AV1 encode on PC/Linux; requires 50–600W dGPU |
| **Cloud ASIC** | NETINT Quadra / AMD Alveo MA35D / Google Argos / Meta MSVP | Commercial / Internal ASIC | HW AV1 at 17–40W per card | 32–64× 1080p streams/card | Dedicated ASIC | Hyperscaler transcode farms (not local creator workstations) |
| **Mezzanine** | Apple ProRes / IETF APV (RFC 9924) / Avid DNx / HTJ2K / JPEG XS | Mixed (APV RF) | Intra-frame visually lossless | ProRes ASIC: 100s fps | Low | Safarium owns native ProRes HW; track APV for Android/Linux |
| **Lossless** | FFV1 (Vulkan) / OpenEXR 3.5 / HAP / NotchLC | OSS / Mixed | Mathematically lossless / GPU DXT | ~500 fps 4K (Vulkan FFV1) | Moderate–High | Archival & live VJ niches |
| **Neural AI** | Microsoft `DCVC-UF` / `MLVC` (CoreML) / Orange `Cool-Chic` v5 | MIT / Research | **−42% vs. VVC** (`DCVC-UF`); **−70% MOS vs. HW HEVC** (`MLVC`) | 100–656 fps (GPU/ANE) | GPU/ANE | Non-standard bitstreams today; `MLVC` proves ANE viability |

---

## 7. Actionable macOS Apple Silicon Upgrade Roadmap for Safarium (Wave 9 — 0% FFmpeg!)

Based on auditing Safarium's actual Swift codebase (`Sources/SafariumCore/FrameSink.swift`, `Sources/SafariumForgeCore/ForgeMetalFilters.swift`, `Sources/SafariumForgeCore/ForgeAudioDSP.swift`) against the 2025–2026 global state of the art, here are **6 high-ROI, 100% Apple-native upgrades** we can build to close the BD-Rate gap and give Safarium capabilities even FFmpeg's `*_videotoolbox` wrappers lack:

### Tier 1 — Immediate BD-Rate & Quality Leap (Closes Major Gap vs. `x264` / `x265`)

1. **Modern VideoToolbox Rate-Control Stack (macOS 15 → 26 → 27) in `FrameSink.swift`:**
   - **macOS 15+:** Enable `kVTCompressionPropertyKey_SpatialAdaptiveQPLevel = kVTQPModulationLevel_Default` (disable only in low-latency mode) and default `kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality = false` for offline renders.
   - **macOS 26+:** Query `kVTCompressionPropertyKey_SupportedPresetDictionaries` and apply `kVTCompressionPreset_HighQuality` (plus `Balanced`/`HighSpeed` profiles); add true **Constrained VBR** (`kVTCompressionPropertyKey_VariableBitRate` + `VBVMaxBitRate` + `VBVBufferDuration`).
   - **macOS 27+:** Route quality-mode exports to **`kVTCompressionPropertyKey_ConstantQualityFactor`** (`0.0–1.0`) + **`kVTCompressionPreset_ConsistentQuality`** (replacing legacy `kVTCompressionPropertyKey_Quality` to eliminate medium/high-Q softness).
   - **Default 10-bit HEVC (`Main10`) even for 8-bit SDR:** Free 5–7% BD-Rate savings and eliminates gradient banding on CSS/WebKit/SVG animations.

2. **True Native Two-Pass VideoToolbox (`VTMultiPassStorage`):**
   - Unlike FFmpeg's `hevc_videotoolbox` (stuck on 1-pass only), Safarium calls VideoToolbox directly and can unlock **`VTMultiPassStorageCreate` → `VTCompressionSessionBeginPass` / `EndPass` / `GetTimeRangesForNextPass` + `VTFrameSilo`** (or `AVAssetWriterInput.performsMultiPassEncodingIfSupported = true`) backed by an APFS sparse temp file.
   - *Rule:* Automatically disable `SuggestedLookAheadFrameCount` when `MultiPassStorage` is attached (they are mutually exclusive in VideoToolbox).

### Tier 2 — Apple Silicon Exclusive Speed & Perceptual Superpowers

3. **"Safarium Mini-CAE" (Metal Shot-Adaptive Encoding + Multi-Engine Max/Ultra Parallelism):**
   - Run a tiny zero-copy Metal compute shader during frame capture/composite (luma histogram diff + spatial variance + temporal SAD, or macOS 26 `VTMotionEstimationSession`) to detect exact **shot cuts** and classify shot complexity (Static UI / Text / Smooth Gradient / High-Motion / Grain).
   - Inject exact keyframes at scene cuts (`kVTEncodeFrameOptionKey_ForceKeyFrame`) and adapt per-shot quality/VBR parameters — bringing **Netflix Dynamic Optimizer / Beamr CABR** principles locally onto Apple Silicon with zero cloud cost!
   - On **Max (2 engines)** and **Ultra (4 engines)** Macs, split long jobs across parallel `VTCompressionSession` workers using **`kVTCompressionPropertyKey_MoreFramesBeforeStart`** and **`kVTCompressionPropertyKey_MoreFramesAfterEnd`** for seamless VBV-compliant boundary stitching (**2×–4× faster export**, matching Apple Compressor).

4. **Zero-Copy Pre-Encode `VTFrameProcessor` Pipeline (`ForgeMetalFilters.swift`):**
   - Safarium already uses `VTFrameProcessor` for `LLSR`; expand it directly in the Metal command buffer (`process(commandBuffer:parameters:)`) with:
     - **`VTTemporalNoiseFilterConfiguration` (macOS 26+):** Pre-encode temporal denoising with `hasDiscontinuity` on scene cuts — huge BD-Rate win on noisy/grainy footage.
     - **`VTSuperResolutionScalerConfiguration` (macOS 26+):** High-quality offline ANE/GPU upscaling (checking `configurationModelStatus`).
     - **`VTOpticalFlowConfiguration` + `VTFrameRateConversionConfiguration` + `VTMotionBlurConfiguration` (macOS 15.4+):** Smooth 24→60 fps retiming & shutter motion blur reusing precomputed optical flow.

### Tier 3 — Pro Mastering Formats & Best-in-Class Native Audio

5. **Pro Video Formats (4:2:2 / 4:4:4 / HDR10 / Dolby Vision 8.4 / MV-HEVC / Full ProRes):**
   - **10-bit HEVC 4:2:2** (`kVTProfileLevel_HEVC_Main42210_AutoLevel`, all M1–M5) + opt-in runtime-probed **10-bit 4:4:4** (`"HEVC_Main44410_AutoLevel"` via `VTSessionCopySupportedPropertyDictionary`) for razor-sharp HTML/UI chroma.
   - **HDR10 / HLG + Dynamic Dolby Vision Profile 8.4:** Wire **`VTHDRPerFrameMetadataGenerationSession([.dolbyVision])`** (macOS 15+) + `kVTHDRMetadataInsertionMode_RequestSDRRangePreservation` (macOS 26+) + `kVTCompressionPropertyKey_LogTransferFunction` (macOS 27+).
   - **MV-HEVC Spatial Video** (`VTIsStereoMVHEVCEncodeSupported()` + `CMTaggedBufferGroupRef` + `VTCompressionSessionEncodeMultiImageFrame`) and **all 6 ProRes tiers** (`apco`, `apcs`, `apcn`, `apch`, `ap4h`, `ap4x`).

6. **Native `AudioToolbox` Upgrades (`ForgeAudioDSP.swift` & `MediaTools.swift`):**
   - Explicitly lock AAC exports to `kAudioConverterCodecQuality = kAudioConverterQuality_Max` (world-leading AAC-LC quality).
   - Expose **ALAC (`'alac'`)**, **HE-AAC v1/v2** (with `AudioSpecificConfig` guard), native **Opus (`'opus'`)**, and **Apple Spatial Audio APAC (`kAudioFormatAPAC`, macOS 26+)** for MV-HEVC Spatial Video deliverables.

### Strategic Watchlist (2027–2028)
- **Optional Zero-FFmpeg Archival AV1 Tier:** If ultra-small royalty-free web distribution is ever needed *before* Apple ships hardware AV1/AV2 encoding, standalone `libSvtAv1Enc` (`BSD-3-Clause-Clear`, 0% FFmpeg / 0% GPL) is the cleanest C library candidate.
- **AV2 Hardware Readiness:** Track AOMedia AV2 (`avm` 1.0, >40% screen-content gain over AV1) so Safarium adopts VideoToolbox HW AV2 the day Apple Silicon exposes it (~2027–2028).
