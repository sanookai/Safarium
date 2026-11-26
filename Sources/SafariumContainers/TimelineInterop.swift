import Foundation
import SafariumCore

// MARK: - Canonical Timeline Intermediate Representation (Wave 17)

/// Exact rational timestamp / duration used across FCPXML 1.11 and OpenTimelineIO.
public struct RationalTime: Codable, Sendable, Equatable {
    public var value: Int64
    public var timescale: Int32

    public init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = max(1, timescale)
    }

    /// Time in seconds as a double-precision floating-point value.
    public var seconds: Double {
        let num = Double(value)
        let den = Double(max(1, timescale))
        return num / den
    }

    /// FCPXML 1.11 rational time string representation (e.g. `"1001/30000s"`, `"0s"`).
    public var fcpxmlString: String {
        if timescale == 1 {
            return "\(value)s"
        }
        return "\(value)/\(timescale)s"
    }

    /// Converts this rational time to a new timescale by rounding to the nearest integer tick.
    public func converted(toTimescale newScale: Int32) -> RationalTime {
        let safeNew = max(1, newScale)
        if safeNew == timescale {
            return self
        }
        let sec = seconds
        let scaled = (sec * Double(safeNew)).rounded()
        return RationalTime(value: Int64(scaled), timescale: safeNew)
    }

    /// Adds two rational times using a common timescale.
    public static func + (lhs: RationalTime, rhs: RationalTime) -> RationalTime {
        if lhs.timescale == rhs.timescale {
            return RationalTime(value: lhs.value + rhs.value, timescale: lhs.timescale)
        }
        let common = lcmInt64(Int64(lhs.timescale), Int64(rhs.timescale))
        if common <= Int64(Int32.max) && common > 0 {
            let lScale = common / Int64(lhs.timescale)
            let rScale = common / Int64(rhs.timescale)
            let sum = lhs.value * lScale + rhs.value * rScale
            return RationalTime(value: sum, timescale: Int32(common))
        }
        let combinedSec = lhs.seconds + rhs.seconds
        let targetScale = max(lhs.timescale, rhs.timescale)
        let ticks = Int64((combinedSec * Double(targetScale)).rounded())
        return RationalTime(value: ticks, timescale: targetScale)
    }

    /// Parses an FCPXML rational time string such as `"1001/30000s"`, `"0s"`, or `"2.5s"`.
    public static func parseFCPXML(_ raw: String) throws -> RationalTime {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SafariumError.invalidState("empty FCPXML rational time string")
        }
        let body = trimmed.hasSuffix("s") ? String(trimmed.dropLast()) : trimmed
        if let slashIdx = body.firstIndex(of: "/") {
            let numStr = String(body[..<slashIdx])
            let denStr = String(body[body.index(after: slashIdx)...])
            guard let num = Int64(numStr), let den = Int32(denStr), den > 0 else {
                throw SafariumError.invalidState("invalid FCPXML rational time: \(raw)")
            }
            return RationalTime(value: num, timescale: den)
        }
        if let intVal = Int64(body) {
            return RationalTime(value: intVal, timescale: 1)
        }
        if let doubleVal = Double(body), doubleVal.isFinite {
            let scale: Int32 = 60000
            let ticks = Int64((doubleVal * Double(scale)).rounded())
            return RationalTime(value: ticks, timescale: scale)
        }
        throw SafariumError.invalidState("unparseable FCPXML rational time: \(raw)")
    }

    private static func gcdInt64(_ a: Int64, _ b: Int64) -> Int64 {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let rem = x % y
            x = y
            y = rem
        }
        return max(1, x)
    }

    private static func lcmInt64(_ a: Int64, _ b: Int64) -> Int64 {
        let g = gcdInt64(a, b)
        let div = a / g
        let (res, overflow) = div.multipliedReportingOverflow(by: b)
        return overflow ? Int64(Int32.max) + 1 : res
    }
}

/// Marker attached to either a clip or the timeline sequence.
public struct TimelineMarker: Codable, Sendable, Equatable {
    public var name: String
    public var start: RationalTime
    public var duration: RationalTime
    public var note: String?

    public init(
        name: String,
        start: RationalTime,
        duration: RationalTime = RationalTime(value: 0, timescale: 1),
        note: String? = nil
    ) {
        self.name = name
        self.start = start
        self.duration = duration
        self.note = note
    }
}

/// Single clip or gap item on a timeline track.
public struct TimelineClip: Codable, Sendable, Equatable {
    public var name: String
    public var mediaURL: String?
    public var sourceStart: RationalTime
    public var duration: RationalTime
    public var isGap: Bool
    public var trackKind: String
    public var markers: [TimelineMarker]

    public init(
        name: String,
        mediaURL: String? = nil,
        sourceStart: RationalTime = RationalTime(value: 0, timescale: 1),
        duration: RationalTime,
        isGap: Bool = false,
        trackKind: String = "video",
        markers: [TimelineMarker] = []
    ) {
        self.name = name
        self.mediaURL = mediaURL
        self.sourceStart = sourceStart
        self.duration = duration
        self.isGap = isGap
        self.trackKind = trackKind
        self.markers = markers
    }
}

/// Ordered sequence of clips and gaps representing a single video or audio track.
public struct TimelineTrack: Codable, Sendable, Equatable {
    public var name: String
    public var kind: String
    public var clips: [TimelineClip]

    public init(
        name: String,
        kind: String = "video",
        clips: [TimelineClip] = []
    ) {
        self.name = name
        self.kind = kind
        self.clips = clips
    }
}

/// Canonical Safarium NLE timeline supporting FCPXML 1.11 and OpenTimelineIO interop.
public struct SafariumTimeline: Codable, Sendable, Equatable {
    public var name: String
    public var width: Int
    public var height: Int
    public var fpsNum: Int32
    public var fpsDen: Int32
    public var tracks: [TimelineTrack]
    public var markers: [TimelineMarker]

    public init(
        name: String,
        width: Int = 1920,
        height: Int = 1080,
        fpsNum: Int32 = 30,
        fpsDen: Int32 = 1,
        tracks: [TimelineTrack] = [],
        markers: [TimelineMarker] = []
    ) {
        self.name = name
        self.width = max(16, width)
        self.height = max(16, height)
        self.fpsNum = max(1, fpsNum)
        self.fpsDen = max(1, fpsDen)
        self.tracks = tracks
        self.markers = markers
    }

    /// Exact duration of a single frame as a rational time (`fpsDen/fpsNum`).
    public var frameDuration: RationalTime {
        RationalTime(value: Int64(fpsDen), timescale: fpsNum)
    }

    /// Effective frame rate in frames per second.
    public var frameRate: Double {
        Double(fpsNum) / Double(max(1, fpsDen))
    }
}

// MARK: - FCPXML 1.11 & OpenTimelineIO Interop Engine

public enum TimelineInterop {

    // MARK: FCPXML 1.11 Export

    /// Exports a `SafariumTimeline` to standards-compliant Final Cut Pro XML v1.11.
    public static func exportFCPXML(_ timeline: SafariumTimeline) -> String {
        let frameDur = timeline.frameDuration
        let formatName = fcpxmlFormatName(width: timeline.width, height: timeline.height, fps: timeline.frameRate)

        // Collect unique media assets across all non-gap clips
        var assetIDByKey: [String: String] = [:]
        var assetEntries: [(id: String, name: String, url: String, hasVideo: Bool, hasAudio: Bool, duration: RationalTime)] = []
        var nextResourceIndex = 2

        for track in timeline.tracks {
            for clip in track.clips where !clip.isGap {
                let resolvedURL = clip.mediaURL ?? ""
                let key = "\(clip.name)||\(resolvedURL)||\(clip.trackKind)"
                if assetIDByKey[key] == nil {
                    let assetID = "r\(nextResourceIndex)"
                    nextResourceIndex += 1
                    assetIDByKey[key] = assetID
                    let isAudio = (clip.trackKind.lowercased() == "audio" || track.kind.lowercased() == "audio")
                    let totalDur = clip.sourceStart + clip.duration
                    assetEntries.append((
                        id: assetID,
                        name: clip.name,
                        url: resolvedURL,
                        hasVideo: !isAudio,
                        hasAudio: isAudio,
                        duration: totalDur
                    ))
                }
            }
        }

        // Compute overall sequence duration as the maximum track duration
        var maxDuration = RationalTime(value: 0, timescale: timeline.fpsNum)
        for track in timeline.tracks {
            var trackDur = RationalTime(value: 0, timescale: timeline.fpsNum)
            for clip in track.clips {
                trackDur = trackDur + clip.duration
            }
            if trackDur.seconds > maxDuration.seconds {
                maxDuration = trackDur
            }
        }

        let tcStart = RationalTime(value: 0, timescale: timeline.fpsNum)
        var lines: [String] = []
        lines.append(#"<?xml version="1.0" encoding="UTF-8"?>"#)
        lines.append(#"<!DOCTYPE fcpxml>"#)
        lines.append(#"<fcpxml version="1.11">"#)
        lines.append("    <resources>")
        lines.append(
            "        <format id=\"r1\" name=\"\(xmlEscape(formatName))\" frameDuration=\"\(frameDur.fcpxmlString)\" width=\"\(timeline.width)\" height=\"\(timeline.height)\"/>"
        )

        for asset in assetEntries {
            let hv = asset.hasVideo ? "1" : "0"
            let ha = asset.hasAudio ? "1" : "0"
            let startStr = RationalTime(value: 0, timescale: asset.duration.timescale).fcpxmlString
            if asset.url.isEmpty {
                lines.append(
                    "        <asset id=\"\(asset.id)\" name=\"\(xmlEscape(asset.name))\" start=\"\(startStr)\" duration=\"\(asset.duration.fcpxmlString)\" hasVideo=\"\(hv)\" hasAudio=\"\(ha)\" format=\"r1\"/>"
                )
            } else {
                lines.append(
                    "        <asset id=\"\(asset.id)\" name=\"\(xmlEscape(asset.name))\" start=\"\(startStr)\" duration=\"\(asset.duration.fcpxmlString)\" hasVideo=\"\(hv)\" hasAudio=\"\(ha)\" format=\"r1\">"
                )
                lines.append(
                    "            <media-rep kind=\"original-media\" src=\"\(xmlEscape(asset.url))\"/>"
                )
                lines.append("        </asset>")
            }
        }
        lines.append("    </resources>")

        lines.append("    <library>")
        lines.append("        <event name=\"Safarium\">")
        lines.append("            <project name=\"\(xmlEscape(timeline.name))\">")
        lines.append(
            "                <sequence format=\"r1\" duration=\"\(maxDuration.fcpxmlString)\" tcStart=\"\(tcStart.fcpxmlString)\" tcFormat=\"NDF\">"
        )

        // Emit timeline-level markers directly under <sequence>
        for marker in timeline.markers {
            lines.append(formatMarkerXML(marker, indent: "                    "))
        }

        lines.append("                    <spine>")

        let primaryTrackIndex = timeline.tracks.firstIndex(where: { $0.kind.lowercased() == "video" }) ?? 0

        // Prepare connected track snippets for tracks other than primaryTrackIndex
        var connectedXMLByLane: [String] = []
        var nextVideoLane = 1
        var nextAudioLane = -1
        for (idx, track) in timeline.tracks.enumerated() where idx != primaryTrackIndex {
            let isAudioTrack = track.kind.lowercased() == "audio"
            let lane: Int
            if isAudioTrack {
                lane = nextAudioLane
                nextAudioLane -= 1
            } else {
                lane = nextVideoLane
                nextVideoLane += 1
            }
            var offset = RationalTime(value: 0, timescale: timeline.fpsNum)
            for clip in track.clips {
                let clipLines = formatClipXML(
                    clip: clip,
                    trackName: track.name,
                    trackKind: track.kind,
                    lane: lane,
                    offset: offset,
                    assetIDByKey: assetIDByKey,
                    indent: "                            ",
                    connectedChildren: []
                )
                connectedXMLByLane.append(contentsOf: clipLines)
                offset = offset + clip.duration
            }
        }

        if timeline.tracks.indices.contains(primaryTrackIndex) {
            let primaryTrack = timeline.tracks[primaryTrackIndex]
            var offset = RationalTime(value: 0, timescale: timeline.fpsNum)
            if primaryTrack.clips.isEmpty && !connectedXMLByLane.isEmpty {
                let wrapperGap = TimelineClip(
                    name: "Gap",
                    mediaURL: nil,
                    sourceStart: tcStart,
                    duration: maxDuration,
                    isGap: true,
                    trackKind: primaryTrack.kind,
                    markers: []
                )
                lines.append(contentsOf: formatClipXML(
                    clip: wrapperGap,
                    trackName: primaryTrack.name,
                    trackKind: primaryTrack.kind,
                    lane: nil,
                    offset: tcStart,
                    assetIDByKey: assetIDByKey,
                    indent: "                        ",
                    connectedChildren: connectedXMLByLane
                ))
            } else {
                for (clipIdx, clip) in primaryTrack.clips.enumerated() {
                    let attached = (clipIdx == 0) ? connectedXMLByLane : []
                    lines.append(contentsOf: formatClipXML(
                        clip: clip,
                        trackName: primaryTrack.name,
                        trackKind: primaryTrack.kind,
                        lane: nil,
                        offset: offset,
                        assetIDByKey: assetIDByKey,
                        indent: "                        ",
                        connectedChildren: attached
                    ))
                    offset = offset + clip.duration
                }
            }
        }

        lines.append("                    </spine>")
        lines.append("                </sequence>")
        lines.append("            </project>")
        lines.append("        </event>")
        lines.append("    </library>")
        lines.append("</fcpxml>")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func formatMarkerXML(_ marker: TimelineMarker, indent: String) -> String {
        var attrs = "start=\"\(marker.start.fcpxmlString)\" duration=\"\(marker.duration.fcpxmlString)\" value=\"\(xmlEscape(marker.name))\""
        if let note = marker.note, !note.isEmpty {
            attrs += " note=\"\(xmlEscape(note))\""
        }
        return "\(indent)<marker \(attrs)/>"
    }

    private static func formatClipXML(
        clip: TimelineClip,
        trackName: String,
        trackKind: String,
        lane: Int?,
        offset: RationalTime,
        assetIDByKey: [String: String],
        indent: String,
        connectedChildren: [String]
    ) -> [String] {
        var result: [String] = []
        let laneAttr = lane.map { " lane=\"\($0)\"" } ?? ""
        let roleAttr = (trackKind.lowercased() == "audio") ? " role=\"dialogue\"" : ""

        var innerLines: [String] = []
        for marker in clip.markers {
            innerLines.append(formatMarkerXML(marker, indent: indent + "    "))
        }
        if !trackName.isEmpty {
            innerLines.append("\(indent)    <metadata>")
            innerLines.append("\(indent)        <md key=\"com.safarium.trackName\" value=\"\(xmlEscape(trackName))\"/>")
            innerLines.append("\(indent)        <md key=\"com.safarium.trackKind\" value=\"\(xmlEscape(trackKind))\"/>")
            innerLines.append("\(indent)    </metadata>")
        }
        innerLines.append(contentsOf: connectedChildren)

        if clip.isGap {
            let openTag = "\(indent)<gap name=\"\(xmlEscape(clip.name))\"\(laneAttr) offset=\"\(offset.fcpxmlString)\" start=\"\(clip.sourceStart.fcpxmlString)\" duration=\"\(clip.duration.fcpxmlString)\""
            if innerLines.isEmpty {
                result.append("\(openTag)/>")
            } else {
                result.append("\(openTag)>")
                result.append(contentsOf: innerLines)
                result.append("\(indent)</gap>")
            }
        } else {
            let resolvedURL = clip.mediaURL ?? ""
            let key = "\(clip.name)||\(resolvedURL)||\(clip.trackKind)"
            let refID = assetIDByKey[key] ?? "r2"
            let openTag = "\(indent)<asset-clip ref=\"\(refID)\" name=\"\(xmlEscape(clip.name))\"\(laneAttr) offset=\"\(offset.fcpxmlString)\" start=\"\(clip.sourceStart.fcpxmlString)\" duration=\"\(clip.duration.fcpxmlString)\" format=\"r1\"\(roleAttr)"
            if innerLines.isEmpty {
                result.append("\(openTag)/>")
            } else {
                result.append("\(openTag)>")
                result.append(contentsOf: innerLines)
                result.append("\(indent)</asset-clip>")
            }
        }
        return result
    }

    private static func fcpxmlFormatName(width: Int, height: Int, fps: Double) -> String {
        let fpsTag: String
        if abs(fps - 23.976) < 0.05 {
            fpsTag = "2398"
        } else if abs(fps - 29.97) < 0.05 {
            fpsTag = "2997"
        } else if abs(fps - 59.94) < 0.1 {
            fpsTag = "5994"
        } else {
            fpsTag = "\(Int(fps.rounded()))"
        }
        return "FFVideoFormat\(height)p\(fpsTag)"
    }

    private static func xmlEscape(_ text: String) -> String {
        var out = text.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }

    // MARK: FCPXML 1.11 Parser (Pure-Swift Foundation.XMLParser)

    /// Parses an FCPXML v1.10 / v1.11 document into a `SafariumTimeline`.
    public static func parseFCPXML(_ xml: String) throws -> SafariumTimeline {
        guard let data = xml.data(using: .utf8) else {
            throw SafariumError.invalidState("FCPXML input is not valid UTF-8")
        }
        let delegate = FCPXMLParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        let ok = parser.parse()
        if let err = delegate.parseError {
            throw err
        }
        if !ok {
            let reason = parser.parserError?.localizedDescription ?? "malformed XML"
            throw SafariumError.invalidState("FCPXML parse failed: \(reason)")
        }
        return try delegate.buildTimeline()
    }

    private final class FCPXMLParserDelegate: NSObject, XMLParserDelegate {
        struct FormatResource {
            var width: Int
            var height: Int
            var fpsNum: Int32
            var fpsDen: Int32
        }

        struct AssetResource {
            var name: String
            var src: String?
            var hasVideo: Bool
            var hasAudio: Bool
        }

        struct ClipFrame {
            var clip: TimelineClip
            var lane: Int
            var trackName: String?
            var trackKindOverride: String?
            var insertionOrder: Int
        }

        var parseError: Error?
        var sawFCPXMLRoot = false
        var projectName: String = "Untitled"
        var formats: [String: FormatResource] = [:]
        var assets: [String: AssetResource] = [:]
        var activeAssetID: String?
        var sequenceFormatID: String?
        var timelineMarkers: [TimelineMarker] = []

        private var clipStack: [ClipFrame] = []
        private var finishedClips: [ClipFrame] = []
        private var nextInsertionOrder = 0
        private var insideSequence = false

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            if parseError != nil { return }

            switch elementName {
            case "fcpxml":
                sawFCPXMLRoot = true

            case "format":
                if let id = attributeDict["id"] {
                    let width = Int(attributeDict["width"] ?? "") ?? 1920
                    let height = Int(attributeDict["height"] ?? "") ?? 1080
                    var fpsNum: Int32 = 30
                    var fpsDen: Int32 = 1
                    if let fdStr = attributeDict["frameDuration"],
                       let fd = try? RationalTime.parseFCPXML(fdStr),
                       fd.value > 0 {
                        fpsNum = fd.timescale
                        fpsDen = Int32(clamping: fd.value)
                    }
                    formats[id] = FormatResource(width: width, height: height, fpsNum: fpsNum, fpsDen: fpsDen)
                }

            case "asset":
                if let id = attributeDict["id"] {
                    let name = attributeDict["name"] ?? id
                    let src = attributeDict["src"]
                    let hasVideo = (attributeDict["hasVideo"] ?? "1") != "0"
                    let hasAudio = (attributeDict["hasAudio"] ?? "0") != "0"
                    assets[id] = AssetResource(name: name, src: src, hasVideo: hasVideo, hasAudio: hasAudio)
                    activeAssetID = id
                }

            case "media-rep":
                if let aid = activeAssetID, var existing = assets[aid], let src = attributeDict["src"] {
                    existing.src = src
                    assets[aid] = existing
                }

            case "project":
                if let name = attributeDict["name"], !name.isEmpty {
                    projectName = name
                }

            case "sequence":
                insideSequence = true
                sequenceFormatID = attributeDict["format"]

            case "asset-clip", "clip", "gap":
                let isGap = (elementName == "gap")
                let refID = attributeDict["ref"]
                let asset = refID.flatMap { assets[$0] }
                let name = attributeDict["name"] ?? asset?.name ?? (isGap ? "Gap" : "Clip")
                let lane = Int(attributeDict["lane"] ?? "0") ?? 0

                let sourceStart: RationalTime
                if let startStr = attributeDict["start"], let parsed = try? RationalTime.parseFCPXML(startStr) {
                    sourceStart = parsed
                } else {
                    sourceStart = RationalTime(value: 0, timescale: 1)
                }

                let duration: RationalTime
                if let durStr = attributeDict["duration"], let parsed = try? RationalTime.parseFCPXML(durStr) {
                    duration = parsed
                } else {
                    duration = RationalTime(value: 0, timescale: 1)
                }

                let role = attributeDict["role"]?.lowercased() ?? ""
                let inferredKind: String
                if lane < 0 || role.contains("audio") || role.contains("dialogue") || role.contains("music") || role.contains("effects") {
                    inferredKind = "audio"
                } else if let a = asset, !a.hasVideo && a.hasAudio {
                    inferredKind = "audio"
                } else {
                    inferredKind = "video"
                }

                let clip = TimelineClip(
                    name: name,
                    mediaURL: isGap ? nil : asset?.src,
                    sourceStart: sourceStart,
                    duration: duration,
                    isGap: isGap,
                    trackKind: inferredKind,
                    markers: []
                )
                let frame = ClipFrame(
                    clip: clip,
                    lane: lane,
                    trackName: nil,
                    trackKindOverride: nil,
                    insertionOrder: nextInsertionOrder
                )
                nextInsertionOrder += 1
                clipStack.append(frame)

            case "marker":
                let name = attributeDict["value"] ?? attributeDict["name"] ?? "Marker"
                let note = attributeDict["note"]
                let start = (attributeDict["start"].flatMap { try? RationalTime.parseFCPXML($0) })
                    ?? RationalTime(value: 0, timescale: 1)
                let duration = (attributeDict["duration"].flatMap { try? RationalTime.parseFCPXML($0) })
                    ?? RationalTime(value: 0, timescale: 1)
                let marker = TimelineMarker(name: name, start: start, duration: duration, note: note)
                if !clipStack.isEmpty {
                    clipStack[clipStack.count - 1].clip.markers.append(marker)
                } else if insideSequence {
                    timelineMarkers.append(marker)
                }

            case "md":
                if !clipStack.isEmpty, let key = attributeDict["key"], let value = attributeDict["value"] {
                    if key == "com.safarium.trackName" {
                        clipStack[clipStack.count - 1].trackName = value
                    } else if key == "com.safarium.trackKind" {
                        clipStack[clipStack.count - 1].trackKindOverride = value
                        clipStack[clipStack.count - 1].clip.trackKind = value
                    }
                }

            default:
                break
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            switch elementName {
            case "asset":
                activeAssetID = nil
            case "sequence":
                insideSequence = false
            case "asset-clip", "clip", "gap":
                if let frame = clipStack.popLast() {
                    finishedClips.append(frame)
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            self.parseError = SafariumError.invalidState("FCPXML XML error: \(parseError.localizedDescription)")
        }

        func buildTimeline() throws -> SafariumTimeline {
            guard sawFCPXMLRoot else {
                throw SafariumError.invalidState("missing <fcpxml> root element")
            }

            let fmt: FormatResource
            if let fid = sequenceFormatID, let found = formats[fid] {
                fmt = found
            } else if let first = formats.values.first {
                fmt = first
            } else {
                fmt = FormatResource(width: 1920, height: 1080, fpsNum: 30, fpsDen: 1)
            }

            // Group clips by lane while preserving insertion order within each lane.
            let ordered = finishedClips.sorted { $0.insertionOrder < $1.insertionOrder }
            var clipsByLane: [Int: [ClipFrame]] = [:]
            var laneOrder: [Int] = []
            for item in ordered {
                if clipsByLane[item.lane] == nil {
                    laneOrder.append(item.lane)
                }
                clipsByLane[item.lane, default: []].append(item)
            }

            var tracks: [TimelineTrack] = []
            for lane in laneOrder {
                guard let frames = clipsByLane[lane], !frames.isEmpty else { continue }
                let resolvedKind = frames.first?.trackKindOverride
                    ?? frames.first?.clip.trackKind
                    ?? (lane < 0 ? "audio" : "video")
                let defaultTrackName = (resolvedKind == "audio") ? "A\(-lane)" : "V\(lane + 1)"
                let resolvedName = frames.compactMap { $0.trackName }.first ?? defaultTrackName
                let clips = frames.map { frame -> TimelineClip in
                    var c = frame.clip
                    c.trackKind = resolvedKind
                    return c
                }
                tracks.append(TimelineTrack(name: resolvedName, kind: resolvedKind, clips: clips))
            }

            return SafariumTimeline(
                name: projectName,
                width: fmt.width,
                height: fmt.height,
                fpsNum: fmt.fpsNum,
                fpsDen: fmt.fpsDen,
                tracks: tracks,
                markers: timelineMarkers
            )
        }
    }

    // MARK: OpenTimelineIO (OTIO) JSON Export & Import

    /// Exports a `SafariumTimeline` to OpenTimelineIO JSON (`Timeline.1` schema).
    public static func exportOTIO(_ timeline: SafariumTimeline) throws -> Data {
        let trackObjects: [[String: Any]] = timeline.tracks.map { track in
            let childObjects: [[String: Any]] = track.clips.map { clip in
                let sourceRange = otioTimeRange(start: clip.sourceStart, duration: clip.duration)
                let markerObjects = clip.markers.map { otioMarker($0) }
                if clip.isGap {
                    return [
                        "OTIO_SCHEMA": "Gap.1",
                        "name": clip.name,
                        "source_range": sourceRange,
                        "markers": markerObjects,
                        "effects": [],
                        "metadata": [:],
                    ]
                } else {
                    let mediaRef: [String: Any]
                    if let url = clip.mediaURL, !url.isEmpty {
                        mediaRef = [
                            "OTIO_SCHEMA": "ExternalReference.1",
                            "target_url": url,
                            "metadata": [:],
                        ]
                    } else {
                        mediaRef = [
                            "OTIO_SCHEMA": "MissingReference.1",
                            "metadata": [:],
                        ]
                    }
                    return [
                        "OTIO_SCHEMA": "Clip.2",
                        "name": clip.name,
                        "source_range": sourceRange,
                        "media_reference": mediaRef,
                        "markers": markerObjects,
                        "effects": [],
                        "metadata": [:],
                    ]
                }
            }

            let otioKind = (track.kind.lowercased() == "audio") ? "Audio" : "Video"
            return [
                "OTIO_SCHEMA": "Track.1",
                "name": track.name,
                "kind": otioKind,
                "children": childObjects,
                "markers": [],
                "effects": [],
                "metadata": [:],
            ]
        }

        let stackMarkers = timeline.markers.map { otioMarker($0) }
        let stack: [String: Any] = [
            "OTIO_SCHEMA": "Stack.1",
            "name": "tracks",
            "children": trackObjects,
            "markers": stackMarkers,
            "effects": [],
            "metadata": [:],
        ]

        let root: [String: Any] = [
            "OTIO_SCHEMA": "Timeline.1",
            "name": timeline.name,
            "global_start_time": otioRationalTime(RationalTime(value: 0, timescale: timeline.fpsNum)),
            "metadata": [
                "safarium": [
                    "width": timeline.width,
                    "height": timeline.height,
                    "fpsNum": Int(timeline.fpsNum),
                    "fpsDen": Int(timeline.fpsDen),
                ],
            ],
            "tracks": stack,
        ]

        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    /// Parses OpenTimelineIO JSON (`Timeline.1`) into a `SafariumTimeline`.
    public static func parseOTIO(_ data: Data) throws -> SafariumTimeline {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SafariumError.invalidState("OTIO JSON root is not an object")
        }
        guard let schema = root["OTIO_SCHEMA"] as? String, schema.hasPrefix("Timeline.") else {
            throw SafariumError.invalidState("expected OTIO_SCHEMA Timeline.1")
        }

        let name = (root["name"] as? String) ?? "Untitled"

        var width = 1920
        var height = 1080
        var fpsNum: Int32 = 30
        var fpsDen: Int32 = 1

        if let meta = root["metadata"] as? [String: Any],
           let sf = meta["safarium"] as? [String: Any] {
            if let w = sf["width"] as? Int { width = w }
            if let h = sf["height"] as? Int { height = h }
            if let num = sf["fpsNum"] as? Int { fpsNum = Int32(num) }
            if let den = sf["fpsDen"] as? Int { fpsDen = Int32(den) }
        } else if let gst = root["global_start_time"] as? [String: Any],
                  let rate = gst["rate"] as? Double, rate > 0 {
            let inferred = inferRationalFPS(rate)
            fpsNum = inferred.num
            fpsDen = inferred.den
        }

        var tracks: [TimelineTrack] = []
        var timelineMarkers: [TimelineMarker] = []

        if let stack = root["tracks"] as? [String: Any] {
            if let rawMarkers = stack["markers"] as? [[String: Any]] {
                timelineMarkers = rawMarkers.compactMap { parseOTIOMarker($0) }
            }
            if let rawTracks = stack["children"] as? [[String: Any]] {
                for rawTrack in rawTracks {
                    let trackName = (rawTrack["name"] as? String) ?? "Track"
                    let rawKind = (rawTrack["kind"] as? String) ?? "Video"
                    let normalizedKind = rawKind.lowercased() == "audio" ? "audio" : "video"

                    var clips: [TimelineClip] = []
                    if let rawChildren = rawTrack["children"] as? [[String: Any]] {
                        for child in rawChildren {
                            let childSchema = (child["OTIO_SCHEMA"] as? String) ?? ""
                            let childName = (child["name"] as? String) ?? ""
                            let (start, duration) = parseOTIOTimeRange(child["source_range"] as? [String: Any])
                            let markers = ((child["markers"] as? [[String: Any]]) ?? []).compactMap { parseOTIOMarker($0) }

                            if childSchema.hasPrefix("Gap.") {
                                clips.append(TimelineClip(
                                    name: childName.isEmpty ? "Gap" : childName,
                                    mediaURL: nil,
                                    sourceStart: start,
                                    duration: duration,
                                    isGap: true,
                                    trackKind: normalizedKind,
                                    markers: markers
                                ))
                            } else if childSchema.hasPrefix("Clip.") {
                                var mediaURL: String? = nil
                                if let ref = child["media_reference"] as? [String: Any],
                                   let targetURL = ref["target_url"] as? String,
                                   !targetURL.isEmpty {
                                    mediaURL = targetURL
                                }
                                clips.append(TimelineClip(
                                    name: childName.isEmpty ? "Clip" : childName,
                                    mediaURL: mediaURL,
                                    sourceStart: start,
                                    duration: duration,
                                    isGap: false,
                                    trackKind: normalizedKind,
                                    markers: markers
                                ))
                            }
                        }
                    }

                    tracks.append(TimelineTrack(name: trackName, kind: normalizedKind, clips: clips))
                }
            }
        }

        return SafariumTimeline(
            name: name,
            width: width,
            height: height,
            fpsNum: fpsNum,
            fpsDen: fpsDen,
            tracks: tracks,
            markers: timelineMarkers
        )
    }

    private static func otioRationalTime(_ rt: RationalTime) -> [String: Any] {
        [
            "OTIO_SCHEMA": "RationalTime.1",
            "rate": Double(rt.timescale),
            "value": Double(rt.value),
        ]
    }

    private static func otioTimeRange(start: RationalTime, duration: RationalTime) -> [String: Any] {
        [
            "OTIO_SCHEMA": "TimeRange.1",
            "start_time": otioRationalTime(start),
            "duration": otioRationalTime(duration),
        ]
    }

    private static func otioMarker(_ marker: TimelineMarker) -> [String: Any] {
        var obj: [String: Any] = [
            "OTIO_SCHEMA": "Marker.2",
            "name": marker.name,
            "marked_range": otioTimeRange(start: marker.start, duration: marker.duration),
            "color": "GREEN",
            "metadata": [:],
        ]
        if let note = marker.note {
            obj["comment"] = note
        }
        return obj
    }

    private static func parseOTIORationalTime(_ dict: [String: Any]?) -> RationalTime {
        guard let dict = dict else {
            return RationalTime(value: 0, timescale: 1)
        }
        let rateNum = (dict["rate"] as? NSNumber)?.doubleValue ?? 1.0
        let valNum = (dict["value"] as? NSNumber)?.doubleValue ?? 0.0
        let scale = Int32(max(1, Int(rateNum.rounded())))
        let val = Int64(valNum.rounded())
        return RationalTime(value: val, timescale: scale)
    }

    private static func parseOTIOTimeRange(_ dict: [String: Any]?) -> (RationalTime, RationalTime) {
        let start = parseOTIORationalTime(dict?["start_time"] as? [String: Any])
        let duration = parseOTIORationalTime(dict?["duration"] as? [String: Any])
        return (start, duration)
    }

    private static func parseOTIOMarker(_ dict: [String: Any]) -> TimelineMarker? {
        guard let name = dict["name"] as? String else { return nil }
        let (start, duration) = parseOTIOTimeRange(dict["marked_range"] as? [String: Any])
        let comment = dict["comment"] as? String
        return TimelineMarker(name: name, start: start, duration: duration, note: comment)
    }

    private static func inferRationalFPS(_ rate: Double) -> (num: Int32, den: Int32) {
        if abs(rate - 23.976) < 0.05 { return (24000, 1001) }
        if abs(rate - 29.97) < 0.05 { return (30000, 1001) }
        if abs(rate - 59.94) < 0.1 { return (60000, 1001) }
        return (Int32(max(1, Int(rate.rounded()))), 1)
    }
}
