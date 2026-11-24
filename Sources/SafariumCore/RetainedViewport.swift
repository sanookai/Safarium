import CoreGraphics
import Foundation

/// A caller-managed damage contract for one opaque SDR `Page` at scale 1 and `.fast` quality.
/// This does not detect DOM changes. Serialize page mutations, seeks and captures; pass no damage
/// after navigation, scrolling, or any change whose complete screen-space extent is unknown.
@MainActor
public final class RetainedViewport {
    public enum Verification: Sendable {
        /// Reject a byte difference on any patch, including late clip-dependent paint.
        case everyPatch
        /// Only check the first patch of each new rect. Use only for an independently verified input.
        case trustRect
    }

    /// CSS viewport pixels, origin at the top left. Covers `[x, x+width) × [y, y+height)`.
    /// Negative origins, nonpositive extents and partially out-of-bounds rectangles are errors.
    public struct Rect: Equatable, Sendable, Encodable {
        public let x: Int, y: Int, width: Int, height: Int

        public init(x: Int, y: Int, width: Int, height: Int) throws {
            guard x >= 0, y >= 0, width > 0, height > 0,
                  width <= Int.max - x, height <= Int.max - y else {
                throw SafariumError.invalidState("damage rect needs nonnegative x,y and positive, representable extents")
            }
            self.x = x; self.y = y; self.width = width; self.height = height
        }

        public func validate(viewportWidth w: Int, height h: Int) throws {
            guard x + width <= w, y + height <= h else {
                throw SafariumError.invalidState("damage rect \(x),\(y),\(width),\(height) exceeds \(w)×\(h) viewport")
            }
        }
    }

    private enum Storage {
        case full(Snapshot)       // no extra full-frame draw on the ordinary, no-hint path
        case bitmap(CGContext)    // allocated lazily on the first patch

        func matches(_ w: Int, _ h: Int) -> Bool {
            switch self {
            case .full(let s): return s.width == w && s.height == h
            case .bitmap(let b): return b.width == w && b.height == h
            }
        }
    }

    public private(set) var fullCaptures = 0
    public private(set) var rectCaptures = 0
    /// Extra full references, including the automatic check on the first patch of each new rect.
    public private(set) var verificationCaptures = 0
    /// Successful page-provided `__sfVideoSeek` calls made by `snapshot(at:...)`.
    public private(set) var videoSeeks = 0
    private let page: Page
    private var retained: Storage?
    private var checkedRect: Rect?
    private var capturing = false

    public init(page: Page) { self.page = page }

    /// Seek the deterministic clock, await any page video hook and sourced DOM images, then
    /// capture. This is the rendering entry point; `snapshot(damage:...)` samples an already
    /// settled page without advancing it. The video/DOM rendezvous has a native two-second limit.
    public func snapshot(at seconds: Double, damage: Rect? = nil, verification: Verification = .everyPatch) async throws -> Snapshot {
        try await capture(at: seconds, damage: damage, verification: verification)
    }

    /// Returns an immutable **full-sized** frame. `nil` always takes a fresh full snapshot.
    /// A rect asserts that *all* pixels changed since the preceding successful capture (including
    /// the old position, shadows, antialiasing, etc.) fit inside it. First frame and resize are full.
    /// By default every patch is checked against an independent full capture. Only `.trustRect`
    /// limits that check to the first patch of each new rect. A raw BGRA difference rejects the frame. Errors
    /// discard retained state; a failed frame must not be encoded. Partial captures need an even viewport.
    public func snapshot(damage: Rect? = nil, verification: Verification = .everyPatch) async throws -> Snapshot {
        try await capture(at: nil, damage: damage, verification: verification)
    }

    private func capture(at seconds: Double?, damage: Rect?, verification: Verification) async throws -> Snapshot {
        guard !capturing else { throw SafariumError.invalidState("overlapping retained viewport captures") }
        capturing = true
        defer { capturing = false }
        do {
            let c = page.config, w = c.width, h = c.height
            guard c.scale == 1, !c.transparent, c.snapshotQuality == .fast,
                  w > 0, h > 0, w <= Int.max / 4 / h else {
                throw SafariumError.invalidState("retained viewport requires an opaque, positive-sized 1× .fast page")
            }
            try damage?.validate(viewportWidth: w, height: h)  // even when the first capture will be full
            if let r = damage, (r.width != w || r.height != h), (!w.isMultiple(of: 2) || !h.isMultiple(of: 2)) {
                throw SafariumError.invalidState("partial capture requires even viewport dimensions; use a full snapshot")
            }
            if let t = seconds {
                guard t.isFinite, t >= 0 else { throw SafariumError.invalidState("frame time must be finite and nonnegative") }
                try await page.seek(t)
                if try await ready(seconds: t) { videoSeeks += 1 }
            }
            guard let r = damage, let previous = retained, previous.matches(w, h),
                  r.width != w || r.height != h else {
                let full = try await page.snapshot()
                try Self.check(full, width: w, height: h)
                fullCaptures += 1
                retained = .full(full)
                checkedRect = nil
                return full
            }

            let tile = try await captureTile(r)
            rectCaptures += 1
            let bitmap: CGContext
            switch previous {
            case .full(let full):
                guard let b = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                        bytesPerRow: w * 4, space: Snapshot.colorSpace, bitmapInfo: Snapshot.bitmapInfo) else {
                    throw SafariumError.snapshot("cannot allocate retained BGRA bitmap")
                }
                b.setBlendMode(.copy)
                b.setShouldAntialias(false)
                b.interpolationQuality = .none
                b.draw(full.cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
                bitmap = b
            case .bitmap(let b): bitmap = b
            }
            // WebKit accepts a top-left view rect. Quartz's unflipped drawing coordinates are
            // bottom-left. Integer 1:1 .copy replaces the pixels; no overlay blending or codec.
            bitmap.draw(tile, in: CGRect(x: r.x, y: h - r.y - r.height, width: r.width, height: r.height))
            guard let image = bitmap.makeImage() else { throw SafariumError.snapshot("cannot publish retained bitmap") }
            let result = Snapshot(cgImage: image)    // makeImage() is immutable even after subsequent draws
            if verification == .everyPatch || checkedRect != r {
                // A truthful damage contract is necessary but not sufficient: WebKit can rasterize
                // clipped effects (e.g. CSS gradients) differently. Reject, never publish the probe.
                let reference = try await page.snapshot()
                try Self.check(reference, width: w, height: h)
                verificationCaptures += 1
                if let byte = try result.firstDifferentBGRAByte(from: reference) {
                    let pixel = byte / 4
                    throw SafariumError.snapshot("retained pixels differ from full capture at x=\(pixel % w), y=\(pixel / w)")
                }
                checkedRect = r
            }
            retained = .bitmap(bitmap)
            return result
        } catch {
            retained = nil
            checkedRect = nil
            throw error
        }
    }

    /// Legacy verification requests remain checked. Trust must be selected explicitly by name.
    @available(*, deprecated, message: "Use snapshot(damage:verification:); .everyPatch is the default")
    public func snapshot(damage: Rect? = nil, verify: Bool) async throws -> Snapshot {
        try await snapshot(damage: damage, verification: .everyPatch)
    }

    package func checkInitialImages() async throws { _ = try await ready(seconds: nil) }

    private func ready(seconds: Double?) async throws -> Bool {
        // Page.evaluate uses a native monotonic timer; a lost `seeked` event or frozen page
        // timer cannot be reported as success. Look up the hook *after* each virtual seek.
        do {
            let result = try await page.evaluate("""
                let invoked = false;
                if (seek && window.__sfVideoSeek != null) {
                  if (typeof window.__sfVideoSeek !== 'function') throw new Error('invalid __sfVideoSeek hook');
                  const result = await window.__sfVideoSeek(t);
                  if (result !== undefined && result !== true) throw new Error('__sfVideoSeek did not report success');
                  invoked = true;
                }
                for (const im of Array.from(document.images)) {
                  const source = im.currentSrc || (im.getAttribute('src') || '').trim() || (im.getAttribute('srcset') || '').trim();
                  if (!source) continue;
                  if (!im.complete) {
                    try { await im.decode(); } catch (_) { throw new Error('broken image: ' + source.slice(0, 160)); }
                  }
                  if (!im.complete || im.naturalWidth === 0) throw new Error('broken image: ' + source.slice(0, 160));
                }
                return invoked;
                """, arguments: ["seek": seconds != nil, "t": seconds ?? 0], timeout: seconds == nil ? 10 : 2)
            guard let invoked = result as? Bool else { throw SafariumError.invalidState("invalid page readiness response") }
            return invoked
        } catch SafariumError.timeout {
            throw SafariumError.timeout("video seek / image readiness")
        } catch {
            throw SafariumError.invalidState("video seek / image readiness: \(error)")
        }
    }

    private func captureTile(_ r: Rect) async throws -> CGImage {
        // WKSnapshotConfiguration.snapshotWidth is in points: on a 2× backing, 22.5 points
        // produced 44, not 45 pixels, and normalizing that blurred the entire tile. Enclose odd
        // edges on the even pixel grid, then crop exactly (CGImage uses top-left image coordinates).
        let x = r.x - r.x % 2, y = r.y - r.y % 2
        let right = r.x + r.width, bottom = r.y + r.height
        let w = right + right % 2 - x, h = bottom + bottom % 2 - y
        let snap = try await page.snapshot(clip: CGRect(x: x, y: y, width: w, height: h))
        try Self.check(snap, width: w, height: h)
        if w == r.width, h == r.height { return snap.cgImage }
        guard let tile = snap.cgImage.cropping(to: CGRect(x: r.x - x, y: r.y - y, width: r.width, height: r.height)) else {
            throw SafariumError.snapshot("cannot crop padded damage tile")
        }
        return tile
    }

    private static func check(_ s: Snapshot, width w: Int, height h: Int) throws {
        let image = s.cgImage
        guard s.width == w, s.height == h else { throw SafariumError.snapshot("unexpected capture size; expected \(w)×\(h)") }
        guard image.bitsPerComponent == 8, let space = image.colorSpace, space.model == .rgb,
              !CGColorSpaceUsesITUR_2100TF(space), !CGColorSpaceUsesExtendedRange(space) else {
            throw SafariumError.snapshot("retained viewport requires 8-bit SDR RGB captures")
        }
    }
}
