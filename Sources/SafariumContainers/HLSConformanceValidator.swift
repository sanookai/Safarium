import Foundation
import SafariumCore

// MARK: - Wave 11C: Independent RFC 8216 + Apple HLS Authoring Conformance Validator

/// Validation report for a single HLS variant stream rendition.
public struct HLSVariantValidationReport: Codable, Sendable, Equatable {
    public let name: String
    public let playlistURI: String
    public let declaredBandwidth: Int
    public let declaredAverageBandwidth: Int?
    public let resolution: String?
    public let codecs: String?
    public let frameRate: Double?
    public let version: Int?
    public let targetDuration: Int?
    public let hasEndList: Bool
    public let playlistType: String?
    public let initMapURI: String?
    public let segmentCount: Int
    public let segmentDurations: [Double]
    public let totalDurationSeconds: Double
    public let totalMediaBytes: Int64
    public let actualAverageBitrate: Int
    public let actualPeakSegmentBitrate: Int
    public let segmentContainerKind: String
    public let initInspection: ISOBMFFInspectionResult?
    public let violations: [String]
}

/// Validation report for an optional WebVTT subtitle rendition declared via `#EXT-X-MEDIA:TYPE=SUBTITLES`.
public struct HLSSubtitleValidationReport: Codable, Sendable, Equatable {
    public let groupID: String
    public let name: String
    public let language: String?
    public let playlistURI: String
    public let vttFileURI: String?
    public let hasWebVTTHeader: Bool
    public let violations: [String]
}

/// Complete RFC 8216 + Apple HLS Authoring conformance validation report for a packaged HLS directory.
public struct HLSConformanceReport: Codable, Sendable, Equatable {
    public let directoryPath: String
    public let masterPlaylistPath: String
    public let masterVersion: Int?
    public let hasIndependentSegments: Bool
    public let variants: [HLSVariantValidationReport]
    public let subtitles: [HLSSubtitleValidationReport]
    public let crossRungSegmentCountAligned: Bool
    public let crossRungDurationMaxDeltaSeconds: Double
    public let appleValidatorAvailable: Bool
    public let appleValidatorSummary: String?
    public let violations: [String]
    public let passed: Bool
}

/// Zero-FFmpeg independent RFC 8216 + Apple HLS Authoring validator for CMAF fMP4 and MPEG-TS streams.
public enum HLSConformanceValidator {

    /// Validates a packaged HLS directory containing `master.m3u8` and all referenced variant/subtitle playlists and segments.
    public static func validate(directory: URL) async throws -> HLSConformanceReport {
        let masterURL = directory.appendingPathComponent("master.m3u8")
        var violations: [String] = []

        guard FileManager.default.fileExists(atPath: masterURL.path) else {
            return HLSConformanceReport(
                directoryPath: directory.path,
                masterPlaylistPath: masterURL.path,
                masterVersion: nil,
                hasIndependentSegments: false,
                variants: [],
                subtitles: [],
                crossRungSegmentCountAligned: false,
                crossRungDurationMaxDeltaSeconds: 0.0,
                appleValidatorAvailable: false,
                appleValidatorSummary: nil,
                violations: ["master.m3u8 does not exist at \(masterURL.path)"],
                passed: false
            )
        }

        let masterText = try String(contentsOf: masterURL, encoding: .utf8)
        let masterLines = masterText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if masterLines.first != "#EXTM3U" {
            violations.append("master.m3u8 does not start with #EXTM3U")
        }

        var masterVersion: Int?
        var hasIndependentSegments = false

        struct ParsedStreamInf {
            let attrs: [String: String]
            let uri: String
        }
        var streamInfs: [ParsedStreamInf] = []
        var subtitleMediaTags: [[String: String]] = []

        var i = 0
        while i < masterLines.count {
            let line = masterLines[i]
            if line.hasPrefix("#EXT-X-VERSION:") {
                let valStr = String(line.dropFirst("#EXT-X-VERSION:".count))
                masterVersion = Int(valStr)
            } else if line == "#EXT-X-INDEPENDENT-SEGMENTS" {
                hasIndependentSegments = true
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let rawAttrs = String(line.dropFirst("#EXT-X-MEDIA:".count))
                let attrs = parseAttributeList(rawAttrs)
                if attrs["TYPE"] == "SUBTITLES" {
                    subtitleMediaTags.append(attrs)
                }
            } else if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let rawAttrs = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
                let attrs = parseAttributeList(rawAttrs)
                if i + 1 < masterLines.count && !masterLines[i + 1].hasPrefix("#") {
                    streamInfs.append(ParsedStreamInf(attrs: attrs, uri: masterLines[i + 1]))
                    i += 1
                } else {
                    violations.append("master.m3u8 has #EXT-X-STREAM-INF without following variant playlist URI")
                }
            }
            i += 1
        }

        if masterVersion == nil {
            violations.append("master.m3u8 missing #EXT-X-VERSION")
        }
        if !hasIndependentSegments {
            violations.append("master.m3u8 missing #EXT-X-INDEPENDENT-SEGMENTS")
        }
        if streamInfs.isEmpty {
            violations.append("master.m3u8 declares no #EXT-X-STREAM-INF variant playlists")
        }

        // Validate optional subtitle renditions
        var subtitleReports: [HLSSubtitleValidationReport] = []
        for subAttrs in subtitleMediaTags {
            let subRep = validateSubtitleRendition(directory: directory, attrs: subAttrs)
            subtitleReports.append(subRep)
            violations.append(contentsOf: subRep.violations)
        }

        // Validate every variant rendition
        var variantReports: [HLSVariantValidationReport] = []
        for streamInf in streamInfs {
            let rep = validateVariantRendition(
                directory: directory,
                attrs: streamInf.attrs,
                playlistURI: streamInf.uri
            )
            variantReports.append(rep)
            violations.append(contentsOf: rep.violations)
        }

        // Cross-rung segment count and duration alignment (shared-IDR cadence verification)
        var crossRungAligned = true
        var maxDurationDelta = 0.0
        if variantReports.count >= 2 {
            let ref = variantReports[0]
            for other in variantReports.dropFirst() {
                if other.segmentCount != ref.segmentCount {
                    crossRungAligned = false
                    violations.append(
                        "Cross-rung segment count mismatch: '\(ref.name)' has \(ref.segmentCount) segments vs '\(other.name)' has \(other.segmentCount)"
                    )
                } else {
                    for segIdx in 0..<ref.segmentDurations.count {
                        let delta = abs(ref.segmentDurations[segIdx] - other.segmentDurations[segIdx])
                        if delta > maxDurationDelta {
                            maxDurationDelta = delta
                        }
                    }
                }
            }
            if crossRungAligned && maxDurationDelta > 0.25 {
                violations.append(
                    String(
                        format: "Cross-rung segment duration drift %.3fs exceeds 0.250s shared-IDR tolerance",
                        maxDurationDelta
                    )
                )
            }
        }

        // Optional Apple mediastreamvalidator probe (never fails report when tool is unavailable)
        let appleCheck = runOptionalAppleValidator(masterURL: masterURL)

        return HLSConformanceReport(
            directoryPath: directory.path,
            masterPlaylistPath: masterURL.path,
            masterVersion: masterVersion,
            hasIndependentSegments: hasIndependentSegments,
            variants: variantReports,
            subtitles: subtitleReports,
            crossRungSegmentCountAligned: crossRungAligned,
            crossRungDurationMaxDeltaSeconds: (maxDurationDelta * 1000.0).rounded() / 1000.0,
            appleValidatorAvailable: appleCheck.available,
            appleValidatorSummary: appleCheck.summary,
            violations: violations,
            passed: violations.isEmpty
        )
    }

    // MARK: - Variant Playlist & Segment Validation

    private static func validateVariantRendition(
        directory: URL,
        attrs: [String: String],
        playlistURI: String
    ) -> HLSVariantValidationReport {
        var violations: [String] = []
        let variantName = URL(fileURLWithPath: playlistURI).deletingLastPathComponent().lastPathComponent
        let label = variantName.isEmpty || variantName == "." ? playlistURI : variantName

        let declaredBandwidth = attrs["BANDWIDTH"].flatMap(Int.init) ?? 0
        let declaredAvgBandwidth = attrs["AVERAGE-BANDWIDTH"].flatMap(Int.init)
        let resolution = attrs["RESOLUTION"]
        let codecs = attrs["CODECS"]
        let frameRate = attrs["FRAME-RATE"].flatMap(Double.init)

        if declaredBandwidth <= 0 {
            violations.append("[\(label)] Missing or non-positive BANDWIDTH in #EXT-X-STREAM-INF")
        }
        if let avg = declaredAvgBandwidth {
            if avg <= 0 {
                violations.append("[\(label)] Non-positive AVERAGE-BANDWIDTH in #EXT-X-STREAM-INF")
            } else if declaredBandwidth > 0 && avg > declaredBandwidth {
                violations.append("[\(label)] AVERAGE-BANDWIDTH (\(avg)) exceeds BANDWIDTH (\(declaredBandwidth))")
            }
        } else {
            violations.append("[\(label)] Missing AVERAGE-BANDWIDTH in #EXT-X-STREAM-INF")
        }
        if resolution == nil || !(resolution?.contains("x") ?? false) {
            violations.append("[\(label)] Missing or malformed RESOLUTION in #EXT-X-STREAM-INF")
        }
        if codecs == nil || (codecs?.isEmpty ?? true) {
            violations.append("[\(label)] Missing CODECS in #EXT-X-STREAM-INF")
        }
        if frameRate == nil || (frameRate ?? 0) <= 0 {
            violations.append("[\(label)] Missing or non-positive FRAME-RATE in #EXT-X-STREAM-INF")
        }

        let playlistURL = directory.appendingPathComponent(playlistURI)
        let variantDir = playlistURL.deletingLastPathComponent()

        guard FileManager.default.fileExists(atPath: playlistURL.path),
              let playlistText = try? String(contentsOf: playlistURL, encoding: .utf8) else {
            violations.append("[\(label)] Variant playlist not found: \(playlistURI)")
            return HLSVariantValidationReport(
                name: label,
                playlistURI: playlistURI,
                declaredBandwidth: declaredBandwidth,
                declaredAverageBandwidth: declaredAvgBandwidth,
                resolution: resolution,
                codecs: codecs,
                frameRate: frameRate,
                version: nil,
                targetDuration: nil,
                hasEndList: false,
                playlistType: nil,
                initMapURI: nil,
                segmentCount: 0,
                segmentDurations: [],
                totalDurationSeconds: 0.0,
                totalMediaBytes: 0,
                actualAverageBitrate: 0,
                actualPeakSegmentBitrate: 0,
                segmentContainerKind: "unknown",
                initInspection: nil,
                violations: violations
            )
        }

        let lines = playlistText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.first != "#EXTM3U" {
            violations.append("[\(label)] Variant playlist does not start with #EXTM3U")
        }

        var version: Int?
        var targetDuration: Int?
        var playlistType: String?
        var hasEndList = false
        var initMapURI: String?

        struct MediaSegEntry {
            let duration: Double
            let uri: String
        }
        var entries: [MediaSegEntry] = []

        var idx = 0
        while idx < lines.count {
            let line = lines[idx]
            if line.hasPrefix("#EXT-X-VERSION:") {
                version = Int(String(line.dropFirst("#EXT-X-VERSION:".count)))
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Int(String(line.dropFirst("#EXT-X-TARGETDURATION:".count)))
            } else if line.hasPrefix("#EXT-X-PLAYLIST-TYPE:") {
                playlistType = String(line.dropFirst("#EXT-X-PLAYLIST-TYPE:".count))
            } else if line == "#EXT-X-ENDLIST" {
                hasEndList = true
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let mapAttrs = parseAttributeList(String(line.dropFirst("#EXT-X-MAP:".count)))
                initMapURI = mapAttrs["URI"]
            } else if line.hasPrefix("#EXTINF:") {
                let raw = String(line.dropFirst("#EXTINF:".count))
                let durToken = raw.split(separator: ",", maxSplits: 1).first.map(String.init) ?? raw
                let dur = Double(durToken.trimmingCharacters(in: .whitespaces)) ?? 0.0
                if idx + 1 < lines.count && !lines[idx + 1].hasPrefix("#") {
                    entries.append(MediaSegEntry(duration: dur, uri: lines[idx + 1]))
                    idx += 1
                } else {
                    violations.append("[\(label)] #EXTINF without following segment URI")
                }
            }
            idx += 1
        }

        if playlistType != "VOD" {
            violations.append("[\(label)] Expected #EXT-X-PLAYLIST-TYPE:VOD, found '\(playlistType ?? "nil")'")
        }
        if !hasEndList {
            violations.append("[\(label)] Missing #EXT-X-ENDLIST in VOD playlist")
        }
        if entries.isEmpty {
            violations.append("[\(label)] Variant playlist has 0 media segments")
        }

        let durations = entries.map(\.duration)
        let maxSegDur = durations.max() ?? 0.0
        let totalDur = durations.reduce(0.0, +)
        if let td = targetDuration {
            let minRequiredTargetDur = max(1, Int(ceil(maxSegDur - 1e-4)))
            if td < minRequiredTargetDur {
                violations.append(
                    "[\(label)] #EXT-X-TARGETDURATION (\(td)) < ceil(max EXTINF \(String(format: "%.3f", maxSegDur))) (\(minRequiredTargetDur))"
                )
            }
        } else {
            violations.append("[\(label)] Missing #EXT-X-TARGETDURATION")
        }

        let isCMAF = (initMapURI != nil) || (entries.first?.uri.lowercased().hasSuffix(".m4s") ?? false)
        let containerKind = isCMAF ? "cmaf" : "mpegts"

        var initInspection: ISOBMFFInspectionResult?
        var videoTrackIDs: Set<UInt32> = []

        if isCMAF {
            if let mapURI = initMapURI {
                let initURL = variantDir.appendingPathComponent(mapURI)
                if let initData = try? Data(contentsOf: initURL), !initData.isEmpty {
                    let parsed = BitstreamConformance.inspectISOBMFF(data: initData)
                    initInspection = parsed
                    videoTrackIDs = Set(parsed.videoTrackIDs)
                    if !parsed.hasFtyp {
                        violations.append("[\(label)] CMAF init segment '\(mapURI)' missing ftyp box")
                    }
                    if !parsed.hasMoov {
                        violations.append("[\(label)] CMAF init segment '\(mapURI)' missing moov box")
                    }
                    if parsed.sampleEntries.isEmpty {
                        violations.append("[\(label)] CMAF init segment '\(mapURI)' has no stsd sample entries")
                    }
                    if !parsed.isValid {
                        for v in parsed.violations {
                            violations.append("[\(label)] init.mp4: \(v)")
                        }
                    }
                } else {
                    violations.append("[\(label)] CMAF #EXT-X-MAP '\(mapURI)' missing or empty")
                }
            } else {
                violations.append("[\(label)] CMAF variant missing #EXT-X-MAP")
            }
        }

        var totalMediaBytes: Int64 = 0
        var peakSegmentBitrate = 0.0
        var prevFirstDecodeTimeByTrack: [UInt32: UInt64] = [:]
        var prevDecodeTimeByTrack: [UInt32: UInt64] = [:]

        for (segIdx, entry) in entries.enumerated() {
            let segURL = variantDir.appendingPathComponent(entry.uri)
            guard let segData = try? Data(contentsOf: segURL), !segData.isEmpty else {
                violations.append("[\(label)] Segment '\(entry.uri)' missing or 0 bytes")
                continue
            }

            let segBytes = Int64(segData.count)
            totalMediaBytes += segBytes
            if entry.duration > 0.05 {
                let segBW = (Double(segBytes) * 8.0) / entry.duration
                if segBW > peakSegmentBitrate {
                    peakSegmentBitrate = segBW
                }
            }

            if isCMAF {
                let segInfo = BitstreamConformance.inspectISOBMFF(data: segData)
                if !segInfo.hasMoof {
                    violations.append("[\(label)] CMAF segment '\(entry.uri)' missing moof box")
                }
                if !segInfo.hasMdat {
                    violations.append("[\(label)] CMAF segment '\(entry.uri)' missing mdat box")
                }
                if segInfo.fragments.isEmpty {
                    violations.append("[\(label)] CMAF segment '\(entry.uri)' has no trun fragments")
                }
                if !segInfo.isValid {
                    for v in segInfo.violations {
                        violations.append("[\(label)] \(entry.uri): \(v)")
                    }
                }

                // Check IDR sync on the first video fragment of each CMAF segment
                let firstVideoFrag: FragmentRunInfo?
                if !videoTrackIDs.isEmpty {
                    firstVideoFrag = segInfo.fragments.first { videoTrackIDs.contains($0.trackID) }
                } else {
                    firstVideoFrag = segInfo.fragments.first
                }
                if let vf = firstVideoFrag, !vf.firstSampleIsSync {
                    violations.append("[\(label)] CMAF segment '\(entry.uri)' first video sample is not an IDR sync sample")
                }

                // Verify monotonic tfdt baseMediaDecodeTime per track within and across segments
                var seenTrackInSeg: Set<UInt32> = []
                for frag in segInfo.fragments {
                    guard let bmdt = frag.baseMediaDecodeTime else { continue }
                    if let prev = prevDecodeTimeByTrack[frag.trackID], bmdt < prev {
                        violations.append(
                            "[\(label)] Non-monotonic tfdt on track \(frag.trackID) in '\(entry.uri)': \(bmdt) < \(prev)"
                        )
                    }
                    prevDecodeTimeByTrack[frag.trackID] = bmdt

                    if !seenTrackInSeg.contains(frag.trackID) {
                        seenTrackInSeg.insert(frag.trackID)
                        if segIdx > 0, let prevFirst = prevFirstDecodeTimeByTrack[frag.trackID], bmdt <= prevFirst {
                            violations.append(
                                "[\(label)] Segment '\(entry.uri)' track \(frag.trackID) decode time (\(bmdt)) did not advance past previous segment (\(prevFirst))"
                            )
                        }
                        prevFirstDecodeTimeByTrack[frag.trackID] = bmdt
                    }
                }
            } else {
                let tsInfo = BitstreamConformance.inspectMPEGTS(data: segData)
                if !tsInfo.isValid {
                    for v in tsInfo.violations {
                        violations.append("[\(label)] \(entry.uri): \(v)")
                    }
                }
            }
        }

        let actualAvgBW = totalDur > 0.05
            ? Int((Double(totalMediaBytes) * 8.0 / totalDur).rounded())
            : 0
        let actualPeakBW = Int(ceil(peakSegmentBitrate))

        if actualPeakBW > 0 && Double(declaredBandwidth) < Double(actualPeakBW) * 0.90 {
            violations.append(
                "[\(label)] Declared BANDWIDTH (\(declaredBandwidth)) < 90% of actual peak segment bitrate (\(actualPeakBW))"
            )
        }

        return HLSVariantValidationReport(
            name: label,
            playlistURI: playlistURI,
            declaredBandwidth: declaredBandwidth,
            declaredAverageBandwidth: declaredAvgBandwidth,
            resolution: resolution,
            codecs: codecs,
            frameRate: frameRate,
            version: version,
            targetDuration: targetDuration,
            hasEndList: hasEndList,
            playlistType: playlistType,
            initMapURI: initMapURI,
            segmentCount: entries.count,
            segmentDurations: durations,
            totalDurationSeconds: (totalDur * 1000.0).rounded() / 1000.0,
            totalMediaBytes: totalMediaBytes,
            actualAverageBitrate: actualAvgBW,
            actualPeakSegmentBitrate: actualPeakBW,
            segmentContainerKind: containerKind,
            initInspection: initInspection,
            violations: violations
        )
    }

    // MARK: - Subtitle Rendition Validation

    private static func validateSubtitleRendition(
        directory: URL,
        attrs: [String: String]
    ) -> HLSSubtitleValidationReport {
        var violations: [String] = []
        let groupID = attrs["GROUP-ID"] ?? ""
        let name = attrs["NAME"] ?? ""
        let lang = attrs["LANGUAGE"]
        let uri = attrs["URI"] ?? ""

        if groupID.isEmpty { violations.append("Subtitle #EXT-X-MEDIA missing GROUP-ID") }
        if name.isEmpty { violations.append("Subtitle #EXT-X-MEDIA missing NAME") }
        if uri.isEmpty {
            violations.append("Subtitle #EXT-X-MEDIA missing URI")
            return HLSSubtitleValidationReport(
                groupID: groupID,
                name: name,
                language: lang,
                playlistURI: uri,
                vttFileURI: nil,
                hasWebVTTHeader: false,
                violations: violations
            )
        }

        let subPlaylistURL = directory.appendingPathComponent(uri)
        guard let subText = try? String(contentsOf: subPlaylistURL, encoding: .utf8) else {
            violations.append("Subtitle playlist not found: \(uri)")
            return HLSSubtitleValidationReport(
                groupID: groupID,
                name: name,
                language: lang,
                playlistURI: uri,
                vttFileURI: nil,
                hasWebVTTHeader: false,
                violations: violations
            )
        }

        let lines = subText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.first != "#EXTM3U" {
            violations.append("Subtitle playlist '\(uri)' missing #EXTM3U")
        }
        if !lines.contains("#EXT-X-ENDLIST") {
            violations.append("Subtitle playlist '\(uri)' missing #EXT-X-ENDLIST")
        }

        let vttURI = lines.first(where: { !$0.hasPrefix("#") })
        var hasWebVTT = false
        if let vttURI {
            let vttURL = subPlaylistURL.deletingLastPathComponent().appendingPathComponent(vttURI)
            if let vttText = try? String(contentsOf: vttURL, encoding: .utf8) {
                let trimmed = vttText.trimmingCharacters(in: .whitespacesAndNewlines)
                hasWebVTT = trimmed.hasPrefix("WEBVTT")
                if !hasWebVTT {
                    violations.append("Subtitle WebVTT file '\(vttURI)' does not start with WEBVTT header")
                }
            } else {
                violations.append("Subtitle WebVTT file not found: \(vttURI)")
            }
        } else {
            violations.append("Subtitle playlist '\(uri)' declares no WebVTT segment URI")
        }

        return HLSSubtitleValidationReport(
            groupID: groupID,
            name: name,
            language: lang,
            playlistURI: uri,
            vttFileURI: vttURI,
            hasWebVTTHeader: hasWebVTT,
            violations: violations
        )
    }

    // MARK: - Optional Apple mediastreamvalidator Probe

    private static func runOptionalAppleValidator(masterURL: URL) -> (available: Bool, summary: String?) {
        let candidates = [
            "/usr/local/bin/mediastreamvalidator",
            "/opt/homebrew/bin/mediastreamvalidator",
            "/usr/bin/mediastreamvalidator",
        ]
        guard let binPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return (false, nil)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binPath)
        proc.arguments = ["--no-validation-data", masterURL.path]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
            let outStr = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let combined = [outStr, errStr]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let clipped = combined.count > 1000 ? String(combined.prefix(1000)) + "..." : combined
            return (true, "exit=\(proc.terminationStatus) \(clipped)".trimmingCharacters(in: .whitespaces))
        } catch {
            return (true, "failed to launch mediastreamvalidator: \(error.localizedDescription)")
        }
    }

    // MARK: - RFC 8216 Attribute List Parser

    /// Parses comma-separated `KEY=VALUE` attributes, respecting quoted values that contain commas (e.g., `CODECS="hvc1...,mp4a.40.2"`).
    internal static func parseAttributeList(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var inKey = true
        var inQuotes = false

        for ch in raw {
            if inKey {
                if ch == "=" {
                    inKey = false
                } else if ch != "," {
                    key.append(ch)
                }
            } else {
                if ch == "\"" {
                    inQuotes.toggle()
                } else if ch == "," && !inQuotes {
                    let k = key.trimmingCharacters(in: .whitespaces)
                    if !k.isEmpty {
                        result[k] = value.trimmingCharacters(in: .whitespaces)
                    }
                    key = ""
                    value = ""
                    inKey = true
                } else {
                    value.append(ch)
                }
            }
        }
        let finalKey = key.trimmingCharacters(in: .whitespaces)
        if !finalKey.isEmpty {
            result[finalKey] = value.trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
