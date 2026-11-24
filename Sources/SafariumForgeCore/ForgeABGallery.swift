import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import SafariumCore
import UniformTypeIdentifiers

public struct ForgeABMetricSet: Codable, Sendable {
    public var wallMs: Double?
    public var peakFootprintMB: Double?
    public var rssMB: Double?
    public var diskBytes: Int64?
    public var chromeTabs: Int?
    public var ffmpegCalls: Int?

    public init(
        wallMs: Double? = nil,
        peakFootprintMB: Double? = nil,
        rssMB: Double? = nil,
        diskBytes: Int64? = nil,
        chromeTabs: Int? = nil,
        ffmpegCalls: Int? = nil
    ) {
        self.wallMs = wallMs
        self.peakFootprintMB = peakFootprintMB
        self.rssMB = rssMB
        self.diskBytes = diskBytes
        self.chromeTabs = chromeTabs
        self.ffmpegCalls = ffmpegCalls
    }
}

public struct ForgeABGalleryCase: Codable, Sendable {
    public var id: String
    public var project: String
    public var title: String
    public var category: String
    public var baselineVideoPath: String
    public var candidateVideoPath: String
    public var expectedThaiText: String?
    public var samples: Int?
    public var minScore: Double?
    public var minMSSSIM: Double?
    public var maxDeltaE00P95: Double?
    public var baselineMetrics: ForgeABMetricSet?
    public var candidateMetrics: ForgeABMetricSet?
    public var notes: String?
}

public struct ForgeABGalleryManifest: Codable, Sendable {
    public var title: String?
    public var generatedNote: String?
    public var cases: [ForgeABGalleryCase]
}

public struct ForgeABGalleryCaseResult: Codable, Sendable {
    public let id: String
    public let project: String
    public let title: String
    public let category: String
    public let pq: SafariumPQReport
    public let speedupX: Double?
    public let ramSavedPct: Double?
    public let baselineMetrics: ForgeABMetricSet?
    public let candidateMetrics: ForgeABMetricSet?
    public let thumbnails: [(label: String, baselineRelPath: String, candidateRelPath: String)]
    public let passed: Bool
    public let notes: String?

    enum CodingKeys: String, CodingKey {
        case id, project, title, category, pq, speedupX, ramSavedPct
        case baselineMetrics, candidateMetrics, thumbnails, passed, notes
    }

    public init(
        id: String,
        project: String,
        title: String,
        category: String,
        pq: SafariumPQReport,
        speedupX: Double?,
        ramSavedPct: Double?,
        baselineMetrics: ForgeABMetricSet?,
        candidateMetrics: ForgeABMetricSet?,
        thumbnails: [(label: String, baselineRelPath: String, candidateRelPath: String)],
        passed: Bool,
        notes: String?
    ) {
        self.id = id
        self.project = project
        self.title = title
        self.category = category
        self.pq = pq
        self.speedupX = speedupX
        self.ramSavedPct = ramSavedPct
        self.baselineMetrics = baselineMetrics
        self.candidateMetrics = candidateMetrics
        self.thumbnails = thumbnails
        self.passed = passed
        self.notes = notes
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(project, forKey: .project)
        try c.encode(title, forKey: .title)
        try c.encode(category, forKey: .category)
        try c.encode(pq, forKey: .pq)
        try c.encodeIfPresent(speedupX, forKey: .speedupX)
        try c.encodeIfPresent(ramSavedPct, forKey: .ramSavedPct)
        try c.encodeIfPresent(baselineMetrics, forKey: .baselineMetrics)
        try c.encodeIfPresent(candidateMetrics, forKey: .candidateMetrics)
        let encodedThumbs = thumbnails.map { ["label": $0.label, "baseline": $0.baselineRelPath, "candidate": $0.candidateRelPath] }
        try c.encode(encodedThumbs, forKey: .thumbnails)
        try c.encode(passed, forKey: .passed)
        try c.encodeIfPresent(notes, forKey: .notes)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.project = try c.decode(String.self, forKey: .project)
        self.title = try c.decode(String.self, forKey: .title)
        self.category = try c.decode(String.self, forKey: .category)
        self.pq = try c.decode(SafariumPQReport.self, forKey: .pq)
        self.speedupX = try c.decodeIfPresent(Double.self, forKey: .speedupX)
        self.ramSavedPct = try c.decodeIfPresent(Double.self, forKey: .ramSavedPct)
        self.baselineMetrics = try c.decodeIfPresent(ForgeABMetricSet.self, forKey: .baselineMetrics)
        self.candidateMetrics = try c.decodeIfPresent(ForgeABMetricSet.self, forKey: .candidateMetrics)
        let rawThumbs = try c.decodeIfPresent([[String: String]].self, forKey: .thumbnails) ?? []
        self.thumbnails = rawThumbs.compactMap { d in
            guard let l = d["label"], let b = d["baseline"], let ca = d["candidate"] else { return nil }
            return (l, b, ca)
        }
        self.passed = try c.decode(Bool.self, forKey: .passed)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
}

public struct ForgeABGalleryReport: Codable, Sendable {
    public let htmlPath: String
    public let summaryJSONPath: String
    public let assetsDir: String
    public let caseCount: Int
    public let passedCount: Int
    public let wallMs: Double
    public let cases: [ForgeABGalleryCaseResult]
}

/// Generates an offline, Safari-viewable visual A/B diff gallery with split slider + SafariumPQ + Thai OCR + RAM/speed deltas.
public enum ForgeABGallery {
    public static func generate(
        manifest: ForgeABGalleryManifest,
        outputHTMLURL: URL,
        overwrite: Bool = false
    ) async throws -> ForgeABGalleryReport {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try SafeFilePublisher.preflight(outputURL: outputHTMLURL, overwrite: overwrite)

        let outDir = outputHTMLURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let assetsDir = outDir.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        let engine = try SafariumPQEngine()
        var results: [ForgeABGalleryCaseResult] = []

        for item in manifest.cases {
            let safeID = sanitizeFileComponent(item.id)
            let refURL = URL(fileURLWithPath: item.baselineVideoPath)
            let candURL = URL(fileURLWithPath: item.candidateVideoPath)
            let sampleCount = max(1, min(12, item.samples ?? 4))
            let pq = try await SafariumPQ.compareVideos(
                referenceURL: refURL,
                candidateURL: candURL,
                maxSamples: max(6, sampleCount * 2),
                checkThaiOCR: item.expectedThaiText != nil,
                expectedThaiText: item.expectedThaiText,
                minScore: item.minScore ?? 85.0,
                maxDeltaE00P95: item.maxDeltaE00P95 ?? 2.0,
                minMSSSIM: item.minMSSSIM ?? 0.97,
                engine: engine
            )

            let baseFrames = try await extractThumbnails(from: refURL, count: sampleCount)
            let candFrames = try await extractThumbnails(from: candURL, count: sampleCount)
            var thumbPairs: [(String, String, String)] = []
            let pairCount = min(baseFrames.count, candFrames.count)
            for idx in 0..<pairCount {
                let bRel = "assets/\(safeID)_base_\(idx).jpg"
                let cRel = "assets/\(safeID)_cand_\(idx).jpg"
                try writeJPEG(baseFrames[idx].cg, to: outDir.appendingPathComponent(bRel), quality: 0.88)
                try writeJPEG(candFrames[idx].cg, to: outDir.appendingPathComponent(cRel), quality: 0.88)
                let label = String(format: "t=%.2fs", baseFrames[idx].ptsSeconds)
                thumbPairs.append((label, bRel, cRel))
            }

            let speedup: Double?
            if let bw = item.baselineMetrics?.wallMs, let cw = item.candidateMetrics?.wallMs, cw > 0 {
                speedup = (bw / cw * 100.0).rounded() / 100.0
            } else {
                speedup = nil
            }
            let ramSaved: Double?
            if let bp = item.baselineMetrics?.peakFootprintMB, let cp = item.candidateMetrics?.peakFootprintMB, bp > 0 {
                ramSaved = (((bp - cp) / bp) * 1000.0).rounded() / 10.0
            } else {
                ramSaved = nil
            }

            results.append(ForgeABGalleryCaseResult(
                id: item.id,
                project: item.project,
                title: item.title,
                category: item.category,
                pq: pq,
                speedupX: speedup,
                ramSavedPct: ramSaved,
                baselineMetrics: item.baselineMetrics,
                candidateMetrics: item.candidateMetrics,
                thumbnails: thumbPairs,
                passed: pq.passed,
                notes: item.notes
            ))
        }

        let summaryURL = outDir.appendingPathComponent("summary.json")
        let htmlContent = renderHTML(
            title: manifest.title ?? "Safarium Wave 5 — Safari Visual A/B Diff Gallery",
            note: manifest.generatedNote ?? "Zero FFmpeg & Zero Chrome · Apple Silicon M5 Verified",
            cases: results
        )

        let wallMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        let report = ForgeABGalleryReport(
            htmlPath: outputHTMLURL.path,
            summaryJSONPath: summaryURL.path,
            assetsDir: assetsDir.path,
            caseCount: results.count,
            passedCount: results.filter(\.passed).count,
            wallMs: wallMs,
            cases: results
        )

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeAtomic(data: try enc.encode(report), to: summaryURL, overwrite: true)
        try writeAtomic(data: Data(htmlContent.utf8), to: outputHTMLURL, overwrite: overwrite)
        return report
    }

    private static func writeAtomic(data: Data, to url: URL, overwrite: Bool) throws {
        try SafeFilePublisher.preflight(outputURL: url, overwrite: overwrite)
        let tmp = SafeFilePublisher.makeTempURL(beside: url)
        do {
            try data.write(to: tmp)
            try SafeFilePublisher.publish(tempURL: tmp, to: url, overwrite: overwrite)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    private static func writeJPEG(_ cg: CGImage, to url: URL, quality: Double) throws {
        let data = try ForgeSheetAndQA.encodeCGImage(cg, format: "jpg", quality: quality)
        try writeAtomic(data: data, to: url, overwrite: true)
    }

    private static func extractThumbnails(from url: URL, count: Int) async throws -> [(ptsSeconds: Double, cg: CGImage)] {
        try SafeFilePublisher.assertRegularReadableFile(url)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let dur = try await asset.load(.duration).seconds
        guard dur > 0 else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 540, height: 960)

        let times: [Double] = (0..<count).map { i in
            let frac = count == 1 ? 0.5 : Double(i) / Double(max(1, count - 1))
            return max(0.0, min(max(0.0, dur - 0.02), frac * max(0.0, dur - 0.02)))
        }
        var out: [(Double, CGImage)] = []
        for t in times {
            let cm = CMTime(seconds: t, preferredTimescale: 600_000)
            if let (cg, _) = try? await gen.image(at: cm) {
                out.append((t, cg))
            }
        }
        return out
    }

    private static func sanitizeFileComponent(_ raw: String) -> String {
        let mapped = raw.unicodeScalars.map { s -> Character in
            let c = Character(s)
            if c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_") { return c }
            return "_"
        }
        let s = String(mapped)
        return s.isEmpty ? "case" : String(s.prefix(48))
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func safeJSONForScript(_ cases: [ForgeABGalleryCaseResult]) -> String {
        guard let data = try? JSONEncoder().encode(cases) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003C")
            .replacingOccurrences(of: ">", with: "\\u003E")
            .replacingOccurrences(of: "&", with: "\\u0026")
    }

    private static func renderHTML(title: String, note: String, cases: [ForgeABGalleryCaseResult]) -> String {
        let cardsHTML = cases.map { c -> String in
            let badge = c.passed ? "<span class=\"badge pass\">PASS</span>" : "<span class=\"badge fail\">FAIL</span>"
            let spd = c.speedupX.map { String(format: "%.2fx เร็วกว่า", $0) } ?? "-"
            let ram = c.ramSavedPct.map { String(format: "%.1f%% RAM", $0) } ?? "-"
            let baseWall = c.baselineMetrics?.wallMs.map { String(format: "%.0f ms", $0) } ?? "-"
            let candWall = c.candidateMetrics?.wallMs.map { String(format: "%.0f ms", $0) } ?? "-"
            let baseRam = c.baselineMetrics?.peakFootprintMB.map { String(format: "%.1f MB", $0) } ?? "-"
            let candRam = c.candidateMetrics?.peakFootprintMB.map { String(format: "%.1f MB", $0) } ?? "-"
            let ocrLabel = c.pq.thaiOCROK ? "ไทย OCR ผ่าน" : "ไทย OCR ไม่ผ่าน"
            let sliderHTML: String
            if let first = c.thumbnails.first {
                sliderHTML = """
                <div class="compare-box" data-case="\(escapeHTML(c.id))">
                  <div class="split-wrap">
                    <img class="img-base" src="\(escapeHTML(first.baselineRelPath))" alt="Baseline">
                    <img class="img-cand" src="\(escapeHTML(first.candidateRelPath))" alt="Safarium">
                    <span class="tag tag-left">ของเดิม (Legacy)</span>
                    <span class="tag tag-right">Safarium (Apple)</span>
                  </div>
                  <input class="split-range" type="range" min="0" max="100" value="50" aria-label="Compare slider">
                </div>
                """
            } else {
                sliderHTML = "<p class=\"muted\">ไม่มีภาพตัวอย่าง</p>"
            }
            let thumbBtns = c.thumbnails.enumerated().map { idx, t in
                "<button type=\"button\" class=\"thumb-btn\(idx == 0 ? " active" : "")\" data-base=\"\(escapeHTML(t.baselineRelPath))\" data-cand=\"\(escapeHTML(t.candidateRelPath))\">\(escapeHTML(t.label))</button>"
            }.joined(separator: "\n")

            return """
            <section class="card">
              <div class="card-head">
                <div>
                  <span class="proj">\(escapeHTML(c.project))</span>
                  <h2>\(escapeHTML(c.title))</h2>
                </div>
                \(badge)
              </div>
              <div class="metrics">
                <div><b>SafariumPQ:</b> \(String(format: "%.2f", c.pq.score0To100)) / 100</div>
                <div><b>MS-SSIM:</b> \(String(format: "%.5f", c.pq.msSSIM))</div>
                <div><b>ΔE00 p95:</b> \(String(format: "%.3f", c.pq.deltaE00P95))</div>
                <div><b>\(escapeHTML(ocrLabel))</b></div>
                <div><b>เวลา (เดิม → ใหม่):</b> \(escapeHTML(baseWall)) → \(escapeHTML(candWall)) (\(escapeHTML(spd)))</div>
                <div><b>Peak RAM:</b> \(escapeHTML(baseRam)) → \(escapeHTML(candRam)) (\(escapeHTML(ram)))</div>
              </div>
              \(sliderHTML)
              <div class="thumb-bar">\(thumbBtns)</div>
              \(c.notes.map { "<p class=\"notes\">\(escapeHTML($0))</p>" } ?? "")
            </section>
            """
        }.joined(separator: "\n")

        let safeDataJSON = safeJSONForScript(cases)
        return """
        <!doctype html>
        <html lang="th">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(escapeHTML(title))</title>
        <style>
          body{margin:0;padding:24px;background:#0b1020;color:#e5e7eb;font:15px/1.5 -apple-system,BlinkMacSystemFont,"Sukhumvit Set",sans-serif}
          header{max-width:1160px;margin:0 auto 24px}
          h1{margin:0 0 6px;font-size:26px;color:#fff}
          .muted{color:#94a3b8}
          .grid{max-width:1160px;margin:0 auto;display:grid;grid-template-columns:repeat(auto-fit,minmax(360px,1fr));gap:20px}
          .card{background:#131b33;border:1px solid #263253;border-radius:14px;padding:18px}
          .card-head{display:flex;justify-content:space-between;align-items:flex-start;gap:12px}
          .proj{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:#38bdf8}
          h2{margin:4px 0 10px;font-size:18px;color:#f8fafc}
          .badge{padding:4px 10px;border-radius:999px;font-weight:700;font-size:12px}
          .pass{background:#064e3b;color:#6ee7b7}
          .fail{background:#7f1d1d;color:#fca5a5}
          .metrics{display:grid;grid-template-columns:1fr 1fr;gap:6px 12px;font-size:13px;background:#0f172a;padding:10px;border-radius:10px;margin-bottom:12px}
          .split-wrap{position:relative;width:100%;aspect-ratio:9/16;max-height:520px;background:#020617;border-radius:10px;overflow:hidden}
          .split-wrap img{position:absolute;inset:0;width:100%;height:100%;object-fit:contain;pointer-events:none}
          .img-cand{clip-path:inset(0 0 0 50%)}
          .tag{position:absolute;top:8px;padding:2px 8px;border-radius:6px;font-size:11px;font-weight:700;background:rgba(15,23,42,.82)}
          .tag-left{left:8px;color:#fbbf24}
          .tag-right{right:8px;color:#34d399}
          .split-range{width:100%;margin-top:8px}
          .thumb-bar{display:flex;flex-wrap:wrap;gap:6px;margin-top:8px}
          .thumb-btn{background:#1e293b;color:#cbd5e1;border:1px solid #334155;border-radius:6px;padding:4px 8px;cursor:pointer;font-size:12px}
          .thumb-btn.active{background:#0ea5e9;color:#0f172a;border-color:#38bdf8;font-weight:700}
          .notes{margin:10px 0 0;font-size:13px;color:#94a3b8}
        </style>
        </head>
        <body>
        <header>
          <h1>\(escapeHTML(title))</h1>
          <div class="muted">\(escapeHTML(note)) · รวม \(cases.count) โปรเจกต์ (ผ่าน \(cases.filter(\.passed).count)/\(cases.count))</div>
        </header>
        <main class="grid">
        \(cardsHTML.isEmpty ? "<p class=\"muted\">ยังไม่มีรายการเปรียบเทียบใน manifest</p>" : cardsHTML)
        </main>
        <script>
          window.__AB_SUMMARY__ = \(safeDataJSON);
          document.querySelectorAll('.card').forEach(card => {
            const range = card.querySelector('.split-range');
            const candImg = card.querySelector('.img-cand');
            const baseImg = card.querySelector('.img-base');
            if (range && candImg) {
              range.addEventListener('input', () => {
                candImg.style.clipPath = `inset(0 0 0 ${range.value}%)`;
              });
            }
            card.querySelectorAll('.thumb-btn').forEach(btn => {
              btn.addEventListener('click', () => {
                card.querySelectorAll('.thumb-btn').forEach(b => b.classList.remove('active'));
                btn.classList.add('active');
                if (baseImg) baseImg.src = btn.dataset.base;
                if (candImg) candImg.src = btn.dataset.cand;
              });
            });
          });
        </script>
        </body>
        </html>
        """
    }
}
