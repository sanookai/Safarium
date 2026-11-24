---
tags: [safarium, wave5, implementation-plan]
note_type: plan
project: "Safarium"
created: 2026-11-23
updated: 2026-11-23
---

# Safarium Wave 5 Implementation Plan

> **Spec:** [`docs/superpowers/specs/2026-11-23-safarium-wave5-design.md`](../specs/2026-11-23-safarium-wave5-design.md)
> **Rule:** `SF-VIDEO-1` (`~/.local/bin/safarium-render` serialized slot, `otool -L` `non_apple=[]`, `0%` FFmpeg/Chrome in migrated paths, zero edits to `cua-go` or existing test assertions).

## Edge Cases Covered Explicitly
- **Empty input / 0 frames:** `ring-encode` (`RING_FINISH` before any `S`), `cache` lookup missing key, `ab-gallery` empty case list, and `daemon` idle exit with 0 requests all fail loudly or return valid empty structured reports cleanly without crashes/zombie processes.
- **Thai / Unicode paths & text:** Paths containing Thai folder names (`เอาตัวรอดกับแสงมณี`), spaces (`Why Stickman?`, `Cut Something`), single quotes (`ep'quote`), Thai captions (`วันที่ 50`, `'ซาฟาเรียม'`), and `ab-gallery` HTML/JS escaping (incl. `</script>`, `<`, `>`, `&`).
- **Timezone & timestamps:** ISO-8601 / local `CUT_NOW` deterministic naming preserved in `Cut Something`; `ForgeShotCache` hashes file content/mtime deterministically independent of TZ.
- **Large input & memory caps:** Ring buffer reuses `2..8` bounded `mmap` slots (`flushPool()` every 60 frames); `ForgeShotCache` `prune` respects `maxBytes` safely without loading cached media into Swift RAM; `ForgeABGallery` extracts bounded thumbnail stills rather than inline full-clip base64.
- **Concurrency & slot safety:** `ForgeWarmDaemon` runs strictly inside `safarium-render`'s single FIFO slot (`poll(2)` idle timeout `20s`, synchronous abort on client EOF, UID verified via `getpeereid`); multi-file ExFAT `._*` AppleDouble sidecars skipped everywhere in `ForgeShotCache` & `ForgeABGallery`.
- **Error paths:** Short ring backing file (`SIGBUS` prevention via `fstat` size check), wrong pixel format/non-even dimensions, `overwrite=false` existing target protection (incl. external ExFAT volume), external `https://` requests blocked even under `--allow-loopback-http`.

## Phased Execution Order
1. **Phase 5A — Core Wave 5 Modules, CLI, SDKs & TDD (`Projects/Safarium/`):**
   - Expose `SocketLineReader` cleanly (`package`) in `Sources/SafariumCore/WarmWorker.swift` (or reuse clean `package` reader) so `SafariumForgeCore` can consume it cleanly without duplicating `recvmsg(SCM_RIGHTS)`.
   - Implement `ForgeSharedRingEncoder.swift`, `ForgeShotCache.swift`, `ForgeABGallery.swift`, `ForgeWarmDaemon.swift` in `Sources/SafariumForgeCore/`.
   - Extend `PrismWebKit3D.swift` & `PrismHybridEngine.swift` with `allowLoopbackHTTP` & optional audio mux on `render-web`.
   - Wire `daemon`, `ring-encode`, `cache`, `ab-gallery` + `--allow-loopback-http`/`--audio` into `Sources/safarium-forge/main.swift` and update `sdk/{python,node,shell}` + `docs/safarium-forge-guide-2026-11-23.md`.
   - Write & run `Tests/SafariumForgeTests/Wave5InnovationTests.swift` via TDD + rebuild Release + reinstall (`install-render.py`) + verify `otool -L` + pass `Tests/verify-shared-standard.py --swift --rules` (`9/9`).
2. **Phase 5B — Sequential Real-Project Scratch A/B + Visual Diff Gallery:**
   - Run baseline vs Safarium A/B sequentially under `/tmp/safarium-wave5-ab/` across all 5 real projects (`Why Stickman?`, `เอาตัวรอดกับแสงมณี`, `Buildology`, `Cut Something`, `GEOSong`), measuring wall-clock, process-tree peak `ri_phys_footprint`, RSS, disk bytes, `SafariumPQ`, and Thai OCR.
   - Generate interactive Safari gallery at `bench/experiments/2026-11-23-wave5-real-ab/gallery.html` + `results.json`.
3. **Phase 5C — Verified Real-Project Migrations:**
   - Migrate each project passing Phase 5B quality gates (`safarium` default + `*_BACKEND=legacy` fallback + `.pre-webkit` backup outside `cutlib/` for `Cut Something`), then verify 100% of each project's native test suite + Safarium backend test.
4. **Phase 5D — Final Release Gate, Hygiene, Vault Sync & Report:**
   - Re-verify `verify-shared-standard.py --swift --rules`, queue/process/ExFAT/focus hygiene, update `current-state.md`, `checklist.md`, `_Index.md`, write Session Log, run `project_registry.py log`, deliver plain-Thai report + gallery link.

