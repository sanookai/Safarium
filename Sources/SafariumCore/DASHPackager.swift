import Foundation

// MARK: - Dual CMAF MPEG-DASH Packager & ISO/IEC 23009-1 Validator (Wave 17)

/// Conformance report produced by `DASHPackager.validate(manifestURL:)`.
public struct DASHValidationReport: Codable, Sendable, Equatable {
    public let passed: Bool
    public let adaptationSetCount: Int
    public let representationCount: Int
    public let totalReferencedSegments: Int
    public let missingFiles: [String]
    public let violations: [String]

    public init(
        passed: Bool,
        adaptationSetCount: Int,
        representationCount: Int,
        totalReferencedSegments: Int,
        missingFiles: [String],
        violations: [String]
    ) {
        self.passed = passed
        self.adaptationSetCount = adaptationSetCount
        self.representationCount = representationCount
        self.totalReferencedSegments = totalReferencedSegments
        self.missingFiles = missingFiles
        self.violations = violations
    }
}

/// Output summary for a generated MPEG-DASH CMAF manifest (`manifest.mpd`).
public struct DASHPackageResult: Codable, Sendable {
    public let manifestPath: String
    public let outputDirectory: String
    public let representations: Int
    public let sharedWithHLS: Bool
    public let validation: DASHValidationReport
    public let elapsedMs: Double

    public init(
        manifestPath: String,
        outputDirectory: String,
        representations: Int,
        sharedWithHLS: Bool,
        validation: DASHValidationReport,
        elapsedMs: Double
    ) {
        self.manifestPath = manifestPath
        self.outputDirectory = outputDirectory
        self.representations = representations
        self.sharedWithHLS = sharedWithHLS
        self.validation = validation
        self.elapsedMs = elapsedMs
    }
}

/// Standards-compliant ISO/IEC 23009-1 MPEG-DASH packager sharing CMAF segments with `HLSPackager`.
public enum DASHPackager {

    /// Generates `manifest.mpd` from an existing CMAF `HLSPackageResult`, sharing the exact
    /// same `init.mp4` and `seg_XXXX.m4s` files on disk when `outputDirectory` is omitted or matches HLS root.
    public static func generateFromHLS(
        hlsResult: HLSPackageResult,
        outputDirectory: URL? = nil
    ) throws -> DASHPackageResult {
        let t0 = DispatchTime.now().uptimeNanoseconds

        guard hlsResult.format == .fmp4CMAF else {
            throw SafariumError.invalidState("MPEG-DASH requires CMAF fMP4 segments (.fmp4CMAF), got \(hlsResult.format.rawValue)")
        }
        guard !hlsResult.variants.isEmpty else {
            throw SafariumError.invalidState("HLSPackageResult contains no variants to package for DASH")
        }

        let masterURL = URL(fileURLWithPath: hlsResult.masterPlaylistPath)
        let hlsRootDir = masterURL.deletingLastPathComponent().standardizedFileURL
        let targetDir = (outputDirectory ?? hlsRootDir).standardizedFileURL
        let sharedWithHLS = (targetDir.path == hlsRootDir.path)

        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        // If writing into a separate output directory, link/copy variant CMAF files so manifest.mpd resolves locally.
        if !sharedWithHLS {
            for variant in hlsResult.variants {
                let srcVarDir = hlsRootDir.appendingPathComponent(variant.name, isDirectory: true)
                let dstVarDir = targetDir.appendingPathComponent(variant.name, isDirectory: true)
                try FileManager.default.createDirectory(at: dstVarDir, withIntermediateDirectories: true)
                let entries = (try? FileManager.default.contentsOfDirectory(atPath: srcVarDir.path)) ?? []
                for entry in entries where entry == "init.mp4" || entry.hasSuffix(".m4s") {
                    let srcFile = srcVarDir.appendingPathComponent(entry)
                    let dstFile = dstVarDir.appendingPathComponent(entry)
                    if FileManager.default.fileExists(atPath: dstFile.path) {
                        try FileManager.default.removeItem(at: dstFile)
                    }
                    try FileManager.default.copyItem(at: srcFile, to: dstFile)
                }
            }
        }

        // Gather per-variant durations and verify on-disk CMAF layout.
        var maxTotalDuration: Double = 0.0
        var minSegmentDuration: Double = 2.0
        var maxWidth: Int = 0
        var maxHeight: Int = 0
        var variantTimelines: [(variant: HLSVariantResult, durations: [Double])] = []

        for variant in hlsResult.variants {
            let varDir = targetDir.appendingPathComponent(variant.name, isDirectory: true)
            let durations = resolveSegmentDurations(variant: variant, variantDir: varDir)
            let totalDur = durations.reduce(0.0, +)
            if totalDur > maxTotalDuration {
                maxTotalDuration = totalDur
            }
            for dur in durations where dur > 0.01 && dur < minSegmentDuration {
                minSegmentDuration = dur
            }
            if variant.width > maxWidth { maxWidth = variant.width }
            if variant.height > maxHeight { maxHeight = variant.height }
            variantTimelines.append((variant: variant, durations: durations))
        }

        let presentationDurationSec = max(0.001, maxTotalDuration)
        let bufferDurationSec = max(0.5, min(minSegmentDuration, presentationDurationSec))
        let timescale: Int64 = 90_000

        let parString = computePAR(width: max(1, maxWidth), height: max(1, maxHeight))

        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append(
            "<MPD xmlns=\"urn:mpeg:dash:schema:mpd:2011\" " +
            "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" " +
            "xsi:schemaLocation=\"urn:mpeg:dash:schema:mpd:2011 DASH-MPD.xsd\" " +
            "type=\"static\" " +
            "mediaPresentationDuration=\"\(formatISO8601Duration(presentationDurationSec))\" " +
            "minBufferTime=\"\(formatISO8601Duration(bufferDurationSec))\" " +
            "profiles=\"urn:mpeg:dash:profile:isoff-on-demand:2011,urn:mpeg:dash:profile:cmaf:2019\">"
        )
        lines.append("  <Period id=\"0\" start=\"PT0S\">")
        lines.append(
            "    <AdaptationSet id=\"0\" contentType=\"video\" mimeType=\"video/mp4\" " +
            "segmentAlignment=\"true\" startWithSAP=\"1\" " +
            "maxWidth=\"\(maxWidth)\" maxHeight=\"\(maxHeight)\" par=\"\(parString)\">"
        )

        for entry in variantTimelines {
            let v = entry.variant
            let bw = max(v.peakBandwidth, v.averageBitrate, v.bitrate, 1_000)
            let fpsStr = formatFrameRate(v.fps)
            let safeID = xmlEscape(v.name)
            let safeCodecs = xmlEscape(v.codecs.isEmpty ? "avc1.640028" : v.codecs)

            lines.append(
                "      <Representation id=\"\(safeID)\" bandwidth=\"\(bw)\" " +
                "width=\"\(v.width)\" height=\"\(v.height)\" " +
                "frameRate=\"\(fpsStr)\" codecs=\"\(safeCodecs)\">"
            )
            lines.append(
                "        <SegmentTemplate timescale=\"\(timescale)\" " +
                "initialization=\"$RepresentationID$/init.mp4\" " +
                "media=\"$RepresentationID$/seg_$Number%04d$.m4s\" " +
                "startNumber=\"0\">"
            )
            lines.append("          <SegmentTimeline>")
            var runningTicks: Int64 = 0
            for (segIdx, dur) in entry.durations.enumerated() {
                let scaled = (max(0.001, dur) * Double(timescale)).rounded()
                let ticks = max(Int64(1), Int64(scaled))
                if segIdx == 0 {
                    lines.append("            <S t=\"\(runningTicks)\" d=\"\(ticks)\"/>")
                } else {
                    lines.append("            <S d=\"\(ticks)\"/>")
                }
                runningTicks += ticks
            }
            lines.append("          </SegmentTimeline>")
            lines.append("        </SegmentTemplate>")
            lines.append("      </Representation>")
        }

        lines.append("    </AdaptationSet>")

        // Optional shared WebVTT subtitle AdaptationSet if present on disk
        if let subPlaylist = hlsResult.subtitlePlaylistPath {
            let subDir = URL(fileURLWithPath: subPlaylist).deletingLastPathComponent()
            let vttFile = subDir.appendingPathComponent("subtitles.vtt")
            let dstVtt = targetDir.appendingPathComponent("subtitles/subtitles.vtt")
            if !sharedWithHLS && FileManager.default.fileExists(atPath: vttFile.path) {
                try FileManager.default.createDirectory(at: dstVtt.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dstVtt.path) {
                    try FileManager.default.removeItem(at: dstVtt)
                }
                try FileManager.default.copyItem(at: vttFile, to: dstVtt)
            }
            if FileManager.default.fileExists(atPath: dstVtt.path) {
                lines.append("    <AdaptationSet id=\"1\" contentType=\"text\" mimeType=\"text/vtt\" lang=\"en\">")
                lines.append("      <Representation id=\"subtitles\" bandwidth=\"1000\">")
                lines.append("        <BaseURL>subtitles/subtitles.vtt</BaseURL>")
                lines.append("      </Representation>")
                lines.append("    </AdaptationSet>")
            }
        }

        lines.append("  </Period>")
        lines.append("</MPD>")
        lines.append("")

        let manifestURL = targetDir.appendingPathComponent("manifest.mpd")
        try Data(lines.joined(separator: "\n").utf8).write(to: manifestURL, options: .atomic)

        let report = validate(manifestURL: manifestURL)
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - t0
        let elapsedMs = (Double(elapsedNs) / 1_000_000.0 * 100.0).rounded() / 100.0

        return DASHPackageResult(
            manifestPath: manifestURL.path,
            outputDirectory: targetDir.path,
            representations: variantTimelines.count,
            sharedWithHLS: sharedWithHLS,
            validation: report,
            elapsedMs: elapsedMs
        )
    }

    /// Single-pass dual CMAF packager that encodes once via `HLSPackager` and emits both
    /// `master.m3u8` (HLS v7) and `manifest.mpd` (ISO/IEC 23009-1 MPEG-DASH) sharing identical `.m4s` files.
    public static func packageDualHLSAndDASH(
        inputURL: URL,
        outputDirectory: URL,
        options: HLSPackageOptions = HLSPackageOptions()
    ) async throws -> (hls: HLSPackageResult, dash: DASHPackageResult) {
        var cmafOptions = options
        cmafOptions.format = .fmp4CMAF
        let hls = try await HLSPackager.package(
            inputURL: inputURL,
            outputDirectory: outputDirectory,
            options: cmafOptions
        )
        let dash = try generateFromHLS(hlsResult: hls, outputDirectory: outputDirectory)
        return (hls: hls, dash: dash)
    }

    /// Parses an MPEG-DASH `manifest.mpd` using `Foundation.XMLParser`, validates required
    /// ISO/IEC 23009-1 elements/attributes, and checks that every referenced `init.mp4` and `.m4s` exists and is non-empty.
    public static func validate(manifestURL: URL) -> DASHValidationReport {
        guard FileManager.default.fileExists(atPath: manifestURL.path),
              let data = try? Data(contentsOf: manifestURL),
              !data.isEmpty else {
            return DASHValidationReport(
                passed: false,
                adaptationSetCount: 0,
                representationCount: 0,
                totalReferencedSegments: 0,
                missingFiles: [manifestURL.lastPathComponent],
                violations: ["manifest file missing or empty: \(manifestURL.path)"]
            )
        }

        let delegate = MPDValidatorDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        let ok = parser.parse()

        var violations = delegate.violations
        if !ok {
            let msg = parser.parserError?.localizedDescription ?? "malformed XML"
            violations.append("XML parse error: \(msg)")
        }

        if !delegate.sawMPD {
            violations.append("missing <MPD> root element")
        }
        if delegate.periodCount == 0 {
            violations.append("missing <Period> element")
        }
        if delegate.adaptationSetCount == 0 {
            violations.append("missing <AdaptationSet> element")
        }
        if delegate.representations.isEmpty {
            violations.append("missing <Representation> element")
        }

        let baseDir = manifestURL.deletingLastPathComponent()
        var missingFiles: [String] = []
        var totalSegments = 0

        for rep in delegate.representations {
            if let template = rep.segmentTemplate {
                if let initTpl = template.initialization, !initTpl.isEmpty {
                    let relPath = substituteTemplate(initTpl, representationID: rep.id, number: nil)
                    let fullURL = baseDir.appendingPathComponent(relPath)
                    if !isNonEmptyFile(fullURL) {
                        missingFiles.append(relPath)
                    }
                } else {
                    violations.append("Representation '\(rep.id)' SegmentTemplate missing initialization attribute")
                }

                if let mediaTpl = template.media, !mediaTpl.isEmpty {
                    if template.segmentCount <= 0 {
                        violations.append("Representation '\(rep.id)' SegmentTimeline has 0 segments")
                    } else {
                        for idx in 0..<template.segmentCount {
                            let segNum = template.startNumber + idx
                            let relPath = substituteTemplate(mediaTpl, representationID: rep.id, number: segNum)
                            let fullURL = baseDir.appendingPathComponent(relPath)
                            totalSegments += 1
                            if !isNonEmptyFile(fullURL) {
                                missingFiles.append(relPath)
                            }
                        }
                    }
                } else {
                    violations.append("Representation '\(rep.id)' SegmentTemplate missing media attribute")
                }
            } else if let baseURLRef = rep.baseURL, !baseURLRef.isEmpty {
                let fullURL = baseDir.appendingPathComponent(baseURLRef)
                totalSegments += 1
                if !isNonEmptyFile(fullURL) {
                    missingFiles.append(baseURLRef)
                }
            } else {
                violations.append("Representation '\(rep.id)' has neither SegmentTemplate nor BaseURL")
            }
        }

        if !missingFiles.isEmpty {
            violations.append("\(missingFiles.count) referenced segment/init file(s) missing or empty")
        }

        let passed = violations.isEmpty && missingFiles.isEmpty
        return DASHValidationReport(
            passed: passed,
            adaptationSetCount: delegate.adaptationSetCount,
            representationCount: delegate.representations.count,
            totalReferencedSegments: totalSegments,
            missingFiles: missingFiles,
            violations: violations
        )
    }

    // MARK: - Private Helpers

    private static func resolveSegmentDurations(variant: HLSVariantResult, variantDir: URL) -> [Double] {
        if !variant.segmentDurations.isEmpty {
            return variant.segmentDurations
        }
        // Fallback: parse #EXTINF durations from variant playlist.m3u8
        let playlistURL = URL(fileURLWithPath: variant.playlistPath)
        if let text = try? String(contentsOf: playlistURL, encoding: .utf8) {
            var parsed: [Double] = []
            for rawLine in text.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#EXTINF:") {
                    let body = line.dropFirst("#EXTINF:".count)
                    let numPart = body.split(separator: ",").first.map(String.init) ?? ""
                    if let val = Double(numPart), val.isFinite, val > 0 {
                        parsed.append(val)
                    }
                }
            }
            if !parsed.isEmpty {
                return parsed
            }
        }
        // Second fallback: count seg_XXXX.m4s files on disk
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: variantDir.path)) ?? [])
            .filter { $0.hasPrefix("seg_") && $0.hasSuffix(".m4s") }
            .sorted()
        let count = max(variant.segmentCount, entries.count)
        return Array(repeating: 2.0, count: count)
    }

    private static func formatISO8601Duration(_ seconds: Double) -> String {
        let clamped = max(0.0, seconds)
        let hours = Int(clamped / 3600.0)
        let remAfterHours = clamped - Double(hours) * 3600.0
        let minutes = Int(remAfterHours / 60.0)
        let secs = remAfterHours - Double(minutes) * 60.0
        var out = "PT"
        if hours > 0 { out += "\(hours)H" }
        if minutes > 0 { out += "\(minutes)M" }
        out += String(format: "%.3fS", secs)
        return out
    }

    private static func formatFrameRate(_ fps: Double) -> String {
        if abs(fps - 23.976) < 0.05 { return "24000/1001" }
        if abs(fps - 29.97) < 0.05 { return "30000/1001" }
        if abs(fps - 59.94) < 0.1 { return "60000/1001" }
        let rounded = fps.rounded()
        if abs(fps - rounded) < 0.01 {
            return "\(Int(rounded))"
        }
        return String(format: "%.3f", fps)
    }

    private static func computePAR(width: Int, height: Int) -> String {
        var a = max(1, width)
        var b = max(1, height)
        while b != 0 {
            let r = a % b
            a = b
            b = r
        }
        let g = max(1, a)
        return "\(width / g):\(height / g)"
    }

    private static func xmlEscape(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }

    private static func isNonEmptyFile(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.int64Value > 0
    }

    private static func substituteTemplate(_ template: String, representationID: String, number: Int?) -> String {
        var result = template.replacingOccurrences(of: "$RepresentationID$", with: representationID)
        guard let num = number else {
            return result
        }
        result = result.replacingOccurrences(of: "$Number$", with: "\(num)")
        // Handle printf-style zero-padded width: $Number%0Nd$
        while let startRange = result.range(of: "$Number%"),
              let endDollar = result[startRange.upperBound...].firstIndex(of: "$") {
            let fmtSpec = String(result[startRange.upperBound..<endDollar])
            let formatted: String
            if fmtSpec.hasSuffix("d") {
                let digits = fmtSpec.dropLast()
                let width = Int(digits) ?? 1
                formatted = String(format: "%0\(max(1, width))d", num)
            } else {
                formatted = "\(num)"
            }
            let fullRange = startRange.lowerBound...endDollar
            result.replaceSubrange(fullRange, with: formatted)
        }
        return result
    }

    // MARK: - MPD XMLParser Delegate

    private final class MPDValidatorDelegate: NSObject, XMLParserDelegate {
        struct ParsedSegmentTemplate {
            var initialization: String?
            var media: String?
            var timescale: Int64
            var startNumber: Int
            var segmentCount: Int
        }

        struct ParsedRepresentation {
            var id: String
            var mimeType: String
            var bandwidth: Int
            var width: Int?
            var height: Int?
            var codecs: String?
            var segmentTemplate: ParsedSegmentTemplate?
            var baseURL: String?
        }

        var sawMPD = false
        var periodCount = 0
        var adaptationSetCount = 0
        var representations: [ParsedRepresentation] = []
        var violations: [String] = []

        private var currentAdaptationMimeType: String = ""
        private var currentAdaptationTemplate: ParsedSegmentTemplate?
        private var currentRepresentation: ParsedRepresentation?
        private var activeTemplateTargetIsRep = false
        private var collectingBaseURL = false
        private var baseURLBuffer = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "MPD":
                sawMPD = true
                let mpdType = attributeDict["type"] ?? ""
                if mpdType != "static" && mpdType != "dynamic" {
                    violations.append("MPD missing valid 'type' attribute ('static' or 'dynamic')")
                }
                let profiles = attributeDict["profiles"] ?? ""
                if profiles.isEmpty {
                    violations.append("MPD missing 'profiles' attribute")
                }
                if mpdType == "static" {
                    let dur = attributeDict["mediaPresentationDuration"] ?? ""
                    if !dur.hasPrefix("PT") {
                        violations.append("static MPD missing valid ISO 8601 'mediaPresentationDuration'")
                    }
                }
                let minBuf = attributeDict["minBufferTime"] ?? ""
                if !minBuf.hasPrefix("PT") {
                    violations.append("MPD missing valid ISO 8601 'minBufferTime'")
                }

            case "Period":
                periodCount += 1

            case "AdaptationSet":
                adaptationSetCount += 1
                currentAdaptationMimeType = attributeDict["mimeType"] ?? ""
                currentAdaptationTemplate = nil
                if currentAdaptationMimeType.isEmpty {
                    violations.append("AdaptationSet #\(adaptationSetCount) missing 'mimeType' attribute")
                }

            case "Representation":
                let id = attributeDict["id"] ?? ""
                let bw = Int(attributeDict["bandwidth"] ?? "") ?? 0
                let width = attributeDict["width"].flatMap(Int.init)
                let height = attributeDict["height"].flatMap(Int.init)
                let codecs = attributeDict["codecs"]
                let mime = attributeDict["mimeType"] ?? currentAdaptationMimeType

                if id.isEmpty {
                    violations.append("Representation missing 'id' attribute")
                }
                if bw <= 0 {
                    violations.append("Representation '\(id)' has invalid or missing 'bandwidth'")
                }
                if mime.hasPrefix("video/") {
                    if (width ?? 0) <= 0 || (height ?? 0) <= 0 {
                        violations.append("Video Representation '\(id)' missing positive 'width'/'height'")
                    }
                    if (codecs ?? "").isEmpty {
                        violations.append("Video Representation '\(id)' missing 'codecs' attribute")
                    }
                }

                currentRepresentation = ParsedRepresentation(
                    id: id,
                    mimeType: mime,
                    bandwidth: bw,
                    width: width,
                    height: height,
                    codecs: codecs,
                    segmentTemplate: currentAdaptationTemplate,
                    baseURL: nil
                )

            case "SegmentTemplate":
                let ts = Int64(attributeDict["timescale"] ?? "1") ?? 1
                let startNum = Int(attributeDict["startNumber"] ?? "0") ?? 0
                if ts <= 0 {
                    violations.append("SegmentTemplate has non-positive timescale")
                }
                let tpl = ParsedSegmentTemplate(
                    initialization: attributeDict["initialization"],
                    media: attributeDict["media"],
                    timescale: ts,
                    startNumber: startNum,
                    segmentCount: 0
                )
                if currentRepresentation != nil {
                    currentRepresentation?.segmentTemplate = tpl
                    activeTemplateTargetIsRep = true
                } else {
                    currentAdaptationTemplate = tpl
                    activeTemplateTargetIsRep = false
                }

            case "S":
                let dVal = Int64(attributeDict["d"] ?? "0") ?? 0
                let rVal = Int(attributeDict["r"] ?? "0") ?? 0
                if dVal <= 0 {
                    violations.append("SegmentTimeline <S> element has non-positive duration 'd'")
                }
                let count = 1 + max(0, rVal)
                if activeTemplateTargetIsRep {
                    currentRepresentation?.segmentTemplate?.segmentCount += count
                } else {
                    currentAdaptationTemplate?.segmentCount += count
                }

            case "BaseURL":
                if currentRepresentation != nil {
                    collectingBaseURL = true
                    baseURLBuffer = ""
                }

            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if collectingBaseURL {
                baseURLBuffer += string
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            switch elementName {
            case "BaseURL":
                if collectingBaseURL {
                    currentRepresentation?.baseURL = baseURLBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
                    collectingBaseURL = false
                    baseURLBuffer = ""
                }
            case "Representation":
                if let rep = currentRepresentation {
                    representations.append(rep)
                    currentRepresentation = nil
                }
                activeTemplateTargetIsRep = false
            case "AdaptationSet":
                currentAdaptationTemplate = nil
                currentAdaptationMimeType = ""
            default:
                break
            }
        }
    }
}
