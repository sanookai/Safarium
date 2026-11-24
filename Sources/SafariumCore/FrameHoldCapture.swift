import CoreMedia

/// Author promise: the final composited pixels are identical throughout each half-open span.
/// Times are absolute on the page's virtual timeline, in ticks of `1 / timescale` seconds.
/// This includes video, canvas, animations, fonts and asynchronously loaded assets.
public struct FrameHoldPlan: Decodable, Sendable {
    public struct Span: Decodable, Sendable {
        public let start: Int64
        public let end: Int64

        public init(start: Int64, end: Int64) {
            self.start = start
            self.end = end
        }
    }

    public let timescale: Int32
    public let holds: [Span]

    public init(timescale: Int32, holds: [Span]) throws {
        guard timescale > 0 else { throw SafariumError.invalidState("hold timescale must be positive") }
        var previousEnd: Int64 = 0
        for (i, span) in holds.enumerated() {
            guard span.start >= previousEnd, span.end > span.start else {
                throw SafariumError.invalidState("hold \(i) must be nonnegative, nonempty, sorted and nonoverlapping")
            }
            previousEnd = span.end
        }
        self.timescale = timescale
        self.holds = holds
    }

    private enum CodingKeys: String, CodingKey { case timescale, holds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(timescale: c.decode(Int32.self, forKey: .timescale),
                      holds: c.decode([Span].self, forKey: .holds))
    }

    fileprivate func index(at time: CMTime, pageSeconds: Double) throws -> Int? {
        guard time.isNumeric, !time.hasBeenRounded, time.epoch == 0, time.timescale > 0, time.value >= 0,
              pageSeconds.isFinite, pageSeconds >= 0 else {
            throw SafariumError.invalidState("hold capture needs an exact nonnegative virtual timestamp")
        }
        var lo = 0, hi = holds.count
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if CMTime(value: holds[mid].end, timescale: timescale) <= time { lo = mid + 1 }
            else { hi = mid }
        }
        guard lo < holds.count else { return nil }
        let start = CMTime(value: holds[lo].start, timescale: timescale)
        let end = CMTime(value: holds[lo].end, timescale: timescale)
        // The external media hook receives the caller's Double. clock.js stores milliseconds
        // and calls page hooks with vt/1000, which can differ by one ULP (e.g. 57/31).
        // If either clock lands outside the rational span, this image must not seed the cache.
        let hookSeconds = (pageSeconds * 1000) / 1000
        return start <= time && start.seconds <= min(pageSeconds, hookSeconds)
            && max(pageSeconds, hookSeconds) < end.seconds ? lo : nil
    }
}

/// Use one instance per sequential render of one page/viewport. Start a new instance after
/// navigation, viewport changes or edits. Only the current explicitly declared span is cached.
@MainActor
public struct FrameHoldCapture {
    private let page: Page
    private let plan: FrameHoldPlan
    private var cached: (span: Int, image: Snapshot)?
    public private(set) var snapshotCalls = 0
    public private(set) var reusedFrames = 0

    public init(page: Page, plan: FrameHoldPlan) {
        self.page = page
        self.plan = plan
    }

    /// Call *after* advancing the page and any media hooks on **each** requested frame.
    /// `time` is absolute (not the encoder PTS); pass `pageSeconds` if the JS seek was
    /// computed differently from `time.seconds`. Append every returned image to the sink.
    public mutating func snapshot(afterSeekingTo time: CMTime, pageSeconds: Double? = nil) async throws -> Snapshot {
        let span = try plan.index(at: time, pageSeconds: pageSeconds ?? time.seconds)
        if let span, let cached, cached.span == span {
            reusedFrames += 1
            return cached.image
        }
        cached = nil
        snapshotCalls += 1
        let image = try await page.snapshot()
        if let span { cached = (span, image) }
        return image
    }
}
