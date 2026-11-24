import CoreGraphics
import Foundation
import SafariumCore

public enum ContainerFormat: String, Codable, Sendable {
    case mp4, mov, mkv, webm, ts, m4a, wav, mp3, flac, caf, ogg, opus, mpeg, mpg, webp, avif, heic, heics, gif, png, jpg
}

public enum ContainerTrackKind: String, Codable, Sendable {
    case video, audio, subtitle
}

public struct ContainerTrackInfo: Codable, Sendable {
    public let trackNumber: Int
    public let kind: ContainerTrackKind
    public let codecID: String
    public let width: Int?
    public let height: Int?
    public let sampleRate: Int?
    public let channels: Int?
    public let language: String?
    public let codecPrivate: Data

    public init(
        trackNumber: Int,
        kind: ContainerTrackKind,
        codecID: String,
        width: Int? = nil,
        height: Int? = nil,
        sampleRate: Int? = nil,
        channels: Int? = nil,
        language: String? = nil,
        codecPrivate: Data = Data()
    ) {
        self.trackNumber = trackNumber
        self.kind = kind
        self.codecID = codecID
        self.width = width
        self.height = height
        self.sampleRate = sampleRate
        self.channels = channels
        self.language = language
        self.codecPrivate = codecPrivate
    }
}

public struct DemuxedPacket: Sendable {
    public let trackNumber: Int
    public let kind: ContainerTrackKind
    public let pts90k: Int64
    public let dts90k: Int64
    public let duration90k: Int64
    public let isKeyframe: Bool
    public let data: Data

    public init(
        trackNumber: Int,
        kind: ContainerTrackKind,
        pts90k: Int64,
        dts90k: Int64,
        duration90k: Int64,
        isKeyframe: Bool,
        data: Data
    ) {
        self.trackNumber = trackNumber
        self.kind = kind
        self.pts90k = pts90k
        self.dts90k = dts90k
        self.duration90k = duration90k
        self.isKeyframe = isKeyframe
        self.data = data
    }
}

public struct RemuxReport: Codable, Sendable {
    public let inputPath: String
    public let outputPath: String
    public let sourceContainer: String
    public let targetContainer: String
    public let videoPackets: Int
    public let audioPackets: Int
    public let subtitleCues: Int
    public let wallMs: Double

    public init(
        inputPath: String,
        outputPath: String,
        sourceContainer: String,
        targetContainer: String,
        videoPackets: Int,
        audioPackets: Int,
        subtitleCues: Int,
        wallMs: Double
    ) {
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.sourceContainer = sourceContainer
        self.targetContainer = targetContainer
        self.videoPackets = videoPackets
        self.audioPackets = audioPackets
        self.subtitleCues = subtitleCues
        self.wallMs = wallMs
    }
}

public struct WebPEncodeReport: Codable, Sendable {
    public let outputPath: String
    public let width: Int
    public let height: Int
    public let frameCount: Int
    public let animated: Bool
    public let bytes: Int
    public let wallMs: Double

    public init(
        outputPath: String,
        width: Int,
        height: Int,
        frameCount: Int,
        animated: Bool,
        bytes: Int,
        wallMs: Double
    ) {
        self.outputPath = outputPath
        self.width = width
        self.height = height
        self.frameCount = frameCount
        self.animated = animated
        self.bytes = bytes
        self.wallMs = wallMs
    }
}

public struct SplitAudioReport: Codable, Sendable {
    public let inputPath: String
    public let outputDir: String
    public let chunkSeconds: Double
    public let chunks: [String]
    public let wallMs: Double

    public init(
        inputPath: String,
        outputDir: String,
        chunkSeconds: Double,
        chunks: [String],
        wallMs: Double
    ) {
        self.inputPath = inputPath
        self.outputDir = outputDir
        self.chunkSeconds = chunkSeconds
        self.chunks = chunks
        self.wallMs = wallMs
    }
}
