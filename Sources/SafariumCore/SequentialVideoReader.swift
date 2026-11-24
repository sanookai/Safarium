import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Darwin
import Foundation
import ImageIO

/// Bounded-RAM sequential video decoder keeping at most two decoded `CMSampleBuffer` frames in flight.
/// Uses Apple `AVAssetReader` directly with `alwaysCopiesSampleData = false` and restarts on backward seeks or loop wraps.
public final class SafariumSequentialVideoReader: @unchecked Sendable {
    public let url: URL
    public let width: Int
    public let height: Int
    public let durationSeconds: Double
    public let nominalFPS: Double
    public let preferredTransform: CGAffineTransform
    public let loop: Bool
    public let startTimeOffset: Double

    private let lock = NSLock()
    private let asset: AVURLAsset
    private let videoTrack: AVAssetTrack
    private let pixelFormat: OSType
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var currentSample: CMSampleBuffer?
    private var nextSample: CMSampleBuffer?
    private var lastMappedTime: Double = -1.0

    public init(
        url: URL,
        loop: Bool = true,
        startTimeOffset: Double = 0.0,
        pixelFormat: OSType = kCVPixelFormatType_32BGRA
    ) async throws {
        var st = stat()
        guard stat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG,
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw SafariumError.invalidState("video file not readable: \(url.path)")
        }
        self.url = url
        self.loop = loop
        self.startTimeOffset = max(0.0, startTimeOffset)
        self.pixelFormat = pixelFormat
        self.asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true,
            AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue,
        ])

        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let vTrack = tracks.first else {
            throw SafariumError.invalidState("no video track in \(url.lastPathComponent)")
        }
        self.videoTrack = vTrack

        let (naturalSize, transform, timeRange, nominal) = try await vTrack.load(
            .naturalSize, .preferredTransform, .timeRange, .nominalFrameRate
        )
        let transformed = naturalSize.applying(transform)
        self.width = max(1, Int(abs(transformed.width).rounded()))
        self.height = max(1, Int(abs(transformed.height).rounded()))
        self.preferredTransform = transform
        self.durationSeconds = max(0.001, timeRange.duration.seconds)
        self.nominalFPS = nominal > 0 ? Double(nominal) : 30.0
    }

    deinit {
        close()
    }

    public func close() {
        lock.withLock { closeLocked() }
    }

    public func orientedCIImage(from pb: CVPixelBuffer) -> CIImage {
        Self.orientedCIImage(from: pb, transform: preferredTransform, targetWidth: width, targetHeight: height)
    }

    package static func orientedCIImage(
        from pb: CVPixelBuffer,
        transform: CGAffineTransform,
        targetWidth: Int? = nil,
        targetHeight: Int? = nil
    ) -> CIImage {
        let raw = CIImage(cvPixelBuffer: pb)
        if transform.isIdentity { return raw }
        if let exif = exifOrientation(for: transform) {
            return raw.oriented(exif)
        }
        let rawH = CGFloat(CVPixelBufferGetHeight(pb))
        let outH = CGFloat(targetHeight ?? Int(abs(CGRect(origin: .zero, size: raw.extent.size).applying(transform).height).rounded()))
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rawH)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: outH)
        let ciTransform = flipIn.concatenating(transform).concatenating(flipOut)
        let transformed = raw.transformed(by: ciTransform)
        return transformed.transformed(by: CGAffineTransform(translationX: -transformed.extent.origin.x, y: -transformed.extent.origin.y))
    }

    private static func exifOrientation(for t: CGAffineTransform) -> CGImagePropertyOrientation? {
        let tol: CGFloat = 0.01
        func eq(_ x: CGFloat, _ y: CGFloat) -> Bool { abs(x - y) < tol }
        if eq(t.a, 1) && eq(t.b, 0) && eq(t.c, 0) && eq(t.d, 1) { return .up }
        if eq(t.a, -1) && eq(t.b, 0) && eq(t.c, 0) && eq(t.d, 1) { return .upMirrored }
        if eq(t.a, -1) && eq(t.b, 0) && eq(t.c, 0) && eq(t.d, -1) { return .down }
        if eq(t.a, 1) && eq(t.b, 0) && eq(t.c, 0) && eq(t.d, -1) { return .downMirrored }
        if eq(t.a, 0) && eq(t.b, 1) && eq(t.c, 1) && eq(t.d, 0) { return .leftMirrored }
        if eq(t.a, 0) && eq(t.b, 1) && eq(t.c, -1) && eq(t.d, 0) { return .right }
        if eq(t.a, 0) && eq(t.b, -1) && eq(t.c, -1) && eq(t.d, 0) { return .rightMirrored }
        if eq(t.a, 0) && eq(t.b, -1) && eq(t.c, 1) && eq(t.d, 0) { return .left }
        return nil
    }

    private func closeLocked() {
        currentSample = nil
        nextSample = nil
        reader?.cancelReading()
        reader = nil
        output = nil
        lastMappedTime = -1.0
    }

    private func restartReaderLocked(at startSeconds: Double) throws {
        closeLocked()
        let r = try AVAssetReader(asset: asset)
        let clampedStart = durationSeconds > 0 ? max(0.0, min(startSeconds, max(0.0, durationSeconds - 0.0005))) : 0.0
        if clampedStart > 0.0005 {
            r.timeRange = CMTimeRange(
                start: CMTime(seconds: clampedStart, preferredTimescale: 600_000),
                duration: CMTime.positiveInfinity
            )
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let out = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: attrs)
        out.alwaysCopiesSampleData = false
        guard r.canAdd(out) else {
            throw SafariumError.snapshot("AVAssetReader cannot decode \(url.lastPathComponent)")
        }
        r.add(out)
        guard r.startReading() else {
            throw SafariumError.snapshot("AVAssetReader startReading failed: \(r.error?.localizedDescription ?? "?")")
        }
        self.reader = r
        self.output = out
        self.currentSample = pullValidSample(from: out)
        self.nextSample = pullValidSample(from: out)
    }

    private func pullValidSample(from out: AVAssetReaderTrackOutput) -> CMSampleBuffer? {
        while let s = out.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(s) != nil {
                return s
            }
        }
        return nil
    }

    private func mappedTime(for sceneTime: Double) -> Double {
        let shifted = sceneTime + startTimeOffset
        if loop && durationSeconds > 0 {
            let rem = shifted.truncatingRemainder(dividingBy: durationSeconds)
            return rem >= 0 ? rem : rem + durationSeconds
        }
        return max(0.0, min(shifted, max(0.0, durationSeconds - 1e-6)))
    }

    public func pixelBuffer(at sceneTime: Double) throws -> CVPixelBuffer? {
        try lock.withLock {
            let targetT = mappedTime(for: sceneTime)
            if reader == nil || currentSample == nil || (lastMappedTime >= 0 && targetT + 1e-4 < lastMappedTime) {
                // Start slightly ahead of targetT on large backward jumps so open-GOP leading frames decode cleanly.
                let rewindBase = targetT > 0.5 ? max(0.0, targetT - 0.5) : 0.0
                try restartReaderLocked(at: rewindBase)
            }
            lastMappedTime = targetT

            guard let out = output else { return nil }
            while let nxt = nextSample,
                  CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(nxt)) <= targetT + 1e-6 {
                currentSample = nxt
                nextSample = pullValidSample(from: out)
            }
            if reader?.status == .failed {
                throw SafariumError.snapshot("AVAssetReader failed: \(reader?.error?.localizedDescription ?? "?")")
            }
            guard let cur = currentSample else { return nil }
            return CMSampleBufferGetImageBuffer(cur)
        }
    }
}
