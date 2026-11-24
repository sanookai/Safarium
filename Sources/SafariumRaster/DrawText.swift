// SafariumRaster — putText / getTextSize the OpenCV 5.x way (Pick 2026-11-24: on-screen text must look like 5.1).
//
// OpenCV 5.1 maps FONT_HERSHEY_* to a built-in TrueType font ("Rubik for OpenCV", SIL OFL 1.1, see DrawFontRubik.swift)
// rendered with HarfBuzz: font scaled so the hhea ascender equals ceil-free `size = round(100*scale/sf)` pixels, wght
// axis = 400/600/800 by face and thickness, pen kept on integer pixels with each shaped advance rounded to the nearest
// whole pixel, glyphs rasterised once at integer origin into an A8 coverage mask and alpha-blended
// ((dst*(255-a) + c*a + 127)/255). Here: shaping/outlines from CoreText (same font data, same variation), coverage
// from our own scanline rasteriser. Logic re-implemented from drawing_text.cpp (Apache-2.0).

import Foundation
import CoreText
import CoreGraphics

// MARK: - face table (hersheyToTruetype)

private func faceParams(_ face: Int32, _ scale: Double, _ thickness: Int32) -> (size: Int, weight: Int)? {
    let thin = thickness <= 1
    var sf = 0.0, w = 0
    switch face & ~16 {
    case 1: sf = 6.6; w = thin ? 400 : 800
    case 0: sf = 3.7; w = thin ? 400 : 600
    case 2: sf = 3.7; w = thin ? 600 : 800
    case 3: sf = 3.7; w = thin ? 400 : 800
    case 4: sf = 3.7; w = thin ? 600 : 800
    case 5: sf = 4.6; w = thin ? 400 : 800
    case 7: sf = 4.0; w = thin ? 400 : 600
    case 6: sf = 4.0; w = thin ? 300 : 500
    default: return nil
    }
    let v = (100 * scale / sf).rounded(.toNearestOrEven)
    guard v.isFinite, abs(v) < 1e6 else { return nil }
    return (Int(v), w)
}

// MARK: - font

struct GlyphBitmap { var xOrigin: Int; var yOrigin: Int; var w: Int; var h: Int; var a: [UInt8] }

/// What the layout engine needs from a font: metrics in font units, HarfBuzz-style shaping, glyph coverage bitmaps.
protocol TextFace: AnyObject {
    var upem: Int { get }
    var ascUnits: Int { get }
    var descUnits: Int { get }        // positive
    var gapUnits: Int { get }
    var wghtRange: (min: Int, max: Int)? { get }
    var currentWeight: Int { get set }     // OpenCV keeps the last used wght as the font's instance; weight 0 means "use it"
    func shapeFull(_ text: [UInt32], weight: Int, hbScale: Int) -> [ShapedGlyph]
    func bitmap(glyph: CGGlyph, weight: Int, hbScale: Int) -> GlyphBitmap
}

struct ShapedGlyph { var glyph: CGGlyph; var adv64: Int; var dx64: Int = 0; var dy64: Int = 0 }

final class Rubik: TextFace {
    static let shared: Rubik? = Rubik()
    let cg: CGFont
    let upem: Int
    let ascUnits: Int
    let descUnits: Int
    let gapUnits: Int
    var wghtRange: (min: Int, max: Int)? { (300, 900) }
    var currentWeight = 300
    func shapeFull(_ text: [UInt32], weight: Int, hbScale: Int) -> [ShapedGlyph] {
        shape(text, weight: weight, hbScale: hbScale).map { ShapedGlyph(glyph: $0.glyph, adv64: $0.adv64) }
    }
    private var fonts: [Int: CTFont] = [:]
    private var cache: [UInt64: GlyphBitmap] = [:]
    private let lock = NSLock()

    init?() {
        guard let data = Data(base64Encoded: RubikFontData.base64, options: .ignoreUnknownCharacters),
              let prov = CGDataProvider(data: data as CFData), let cg = CGFont(prov) else { return nil }
        self.cg = cg
        func be16(_ o: Int) -> Int { Int(data[o]) << 8 | Int(data[o + 1]) }
        func s16(_ o: Int) -> Int { let v = be16(o); return v >= 0x8000 ? v - 0x10000 : v }
        var tables: [String: Int] = [:]
        let n = be16(4)
        for i in 0..<n {
            let o = 12 + 16 * i
            tables[String(decoding: data[o..<o + 4], as: UTF8.self)] = Int(data[o + 8]) << 24 | Int(data[o + 9]) << 16 | Int(data[o + 10]) << 8 | Int(data[o + 11])
        }
        guard let head = tables["head"], let hhea = tables["hhea"] else { return nil }
        upem = be16(head + 18)
        var asc = s16(hhea + 4), desc = -s16(hhea + 6), gap = s16(hhea + 8)
        if let os2 = tables["OS/2"] {
            let typo = s16(os2 + 68)
            if (be16(os2 + 62) & 128) != 0 && typo != 0 { asc = typo; desc = -s16(os2 + 70); gap = s16(os2 + 72) } else if asc == 0 { asc = typo }
        }
        ascUnits = asc; descUnits = desc; gapUnits = gap
    }

    func font(weight: Int) -> CTFont {
        lock.lock(); defer { lock.unlock() }
        if let f = fonts[weight] { return f }
        let attrs: [CFString: Any] = [kCTFontVariationAttribute: [NSNumber(value: 0x77676874): NSNumber(value: weight)]]
        let desc = CTFontDescriptorCreateWithAttributes(attrs as CFDictionary)
        let f = CTFontCreateWithGraphicsFont(cg, CGFloat(upem), nil, desc)
        fonts[weight] = f
        return f
    }

    /// Glyph ids and HarfBuzz-style 26.6 advances (scaled+rounded advance plus scaled+rounded kerning).
    func shape(_ text: [UInt32], weight: Int, hbScale: Int) -> [(glyph: CGGlyph, adv64: Int)] {
        let font = self.font(weight: weight)
        if let exact = shapeExact(text, font: font, weight: weight, hbScale: hbScale) { return exact }
        var u16: [UniChar] = []
        for c in text {
            var cc = c
            var g = [CGGlyph](repeating: 0, count: 2)
            var ch: [UniChar] = cc < 0x10000 ? [UniChar(cc)] : [UniChar(0x3F)]
            if !CTFontGetGlyphsForCharacters(font, &ch, &g, 1) || g[0] == 0 { cc = 0x3F }
            u16.append(UniChar(cc < 0x10000 ? cc : 0x3F))
        }
        if u16.isEmpty { return [] }
        let astr = CFAttributedStringCreate(nil, String(utf16CodeUnits: u16, count: u16.count) as CFString,
                                            [kCTFontAttributeName: font] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(astr)
        var glyphs: [CGGlyph] = []
        var xs: [Double] = []
        for run in (CTLineGetGlyphRuns(line) as! [CTRun]) {
            let n = CTRunGetGlyphCount(run)
            var g = [CGGlyph](repeating: 0, count: n)
            var p = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRangeMake(0, 0), &g)
            CTRunGetPositions(run, CFRangeMake(0, 0), &p)
            glyphs += g
            xs += p.map { Double($0.x) }
        }
        var raw = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &raw, glyphs.count)
        let k = Double(hbScale) / Double(upem)
        var out: [(CGGlyph, Int)] = []
        for i in 0..<glyphs.count {
            let a = Double(raw[i].width).rounded(.toNearestOrEven)   // HarfBuzz works on whole font units after HVAR
            let full = i + 1 < glyphs.count ? xs[i + 1] - xs[i] : a
            let kern = full - Double(raw[i].width)   // GPOS kerning (+ variation delta), scaled below without unit rounding
            out.append((glyphs[i], Int((a * k).rounded(.toNearestOrEven)) + Int((kern * k).rounded(.toNearestOrEven))))
        }
        return out
    }

    private var kernTables: [Int: [UInt32: Int]] = [:]   // c1<<8|c2 -> 1/10000 font unit

    /// ASCII text without ffi/ffl/ff ligatures: advances and kerning straight from the HarfBuzz-generated tables.
    private func shapeExact(_ text: [UInt32], font: CTFont, weight: Int, hbScale: Int) -> [(glyph: CGGlyph, adv64: Int)]? {
        guard let wi = RubikMetrics.weights.firstIndex(of: weight), !text.isEmpty else { return nil }
        for (i, c) in text.enumerated() {
            if c < 32 || c > 126 { return nil }
            if i + 1 < text.count, RubikMetrics.ligaturePairs.contains(UInt32(c << 8 | text[i + 1])) { return nil }
        }
        lock.lock()
        if kernTables[wi] == nil {
            var t: [UInt32: Int] = [:]
            let flat = RubikMetrics.kerning[wi]
            var j = 0
            while j + 1 < flat.count { t[UInt32(flat[j])] = Int(flat[j + 1]); j += 2 }
            kernTables[wi] = t
        }
        if kernTables[0] == nil {
            var t: [UInt32: Int] = [:]
            let flat = RubikMetrics.kerning[0]
            var j = 0
            while j + 1 < flat.count { t[UInt32(flat[j])] = Int(flat[j + 1]); j += 2 }
            kernTables[0] = t
        }
        let kt = kernTables[wi]!
        lock.unlock()
        var ch = text.map { UniChar($0) }
        var gl = [CGGlyph](repeating: 0, count: ch.count)
        guard CTFontGetGlyphsForCharacters(font, &ch, &gl, ch.count) else { return nil }
        // HarfBuzz em_mult with unrounded variation-adjusted units: (floor(v * mult) + 0x8000) >> 16, mult = (scale << 16) / upem
        let mult = Double((Int(hbScale) << 16) / upem)
        func em(_ v10k: Int) -> Int { (Int((Double(v10k) / 10000.0 * mult).rounded(.down)) + 0x8000) >> 16 }
        var out: [(CGGlyph, Int)] = []
        for i in 0..<text.count {
            var a = em(Int(RubikMetrics.advance[wi][Int(text[i]) - 32]))
            if i + 1 < text.count, let k = kt[(text[i] << 8) | text[i + 1]] {
                // HarfBuzz: the default-master value is scaled with em_mult, the variation delta separately in float and rounded
                let base = kernTables[0]?[(text[i] << 8) | text[i + 1]] ?? 0
                let baseUnits = Double(base) / 10000.0
                let delta = Double(k - base) / 10000.0
                a += (Int((baseUnits * mult).rounded(.down)) + 0x8000) >> 16
                a += Int((delta * Double(hbScale) / Double(upem)).rounded(.toNearestOrAwayFromZero))
            }
            out.append((gl[i], a))
        }
        return out
    }

    func bitmap(glyph: CGGlyph, weight: Int, hbScale: Int) -> GlyphBitmap {
        let key = UInt64(glyph) << 40 | UInt64(weight & 0xFFFF) << 24 | UInt64(hbScale & 0xFFFFFF)
        lock.lock()
        if let b = cache[key] { lock.unlock(); return b }
        lock.unlock()
        let b = renderGlyph(glyph, weight: weight, hbScale: hbScale)
        lock.lock()
        if cache.count > 4096 { cache.removeAll() }
        cache[key] = b
        lock.unlock()
        return b
    }

    private func renderGlyph(_ glyph: CGGlyph, weight: Int, hbScale: Int) -> GlyphBitmap {
        renderGlyphBitmap(font: font(weight: weight), glyph: glyph, hbScale: hbScale, upem: upem)
    }
}

func renderGlyphBitmap(font f: CTFont, glyph: CGGlyph, hbScale: Int, upem: Int) -> GlyphBitmap {
    let empty = GlyphBitmap(xOrigin: 0, yOrigin: 0, w: 0, h: 0, a: [])
    guard let path = CTFontCreatePathForGlyph(f, glyph, nil) else { return empty }
    let s = Double(hbScale) / 64.0 / Double(upem)  // px per font unit
    var contours: [[P]] = []   // y-up px
    var cur: [P] = []
    var last = P(x: 0, y: 0)
    func pt(_ p: CGPoint) -> P { P(x: Double(p.x) * s, y: Double(p.y) * s) }
    func appendQuad(from start: P, control c: P, to end: P) {
        let len1: Double = abs(c.x - start.x) + abs(c.y - start.y)
        let len2: Double = abs(end.x - c.x) + abs(end.y - c.y)
        let n: Int = max(4, min(32, Int(((len1 + len2) / 0.8).rounded(.up))))
        for i in 1...n {
            let t: Double = Double(i) / Double(n)
            let u: Double = 1 - t
            let w0: Double = u * u
            let w1: Double = 2 * u * t
            let w2: Double = t * t
            let px: Double = w0 * start.x + w1 * c.x + w2 * end.x
            let py: Double = w0 * start.y + w1 * c.y + w2 * end.y
            cur.append(P(x: px, y: py))
        }
    }
    func appendCubic(from start: P, c1: P, c2: P, to end: P) {
        let len1: Double = abs(c1.x - start.x) + abs(c1.y - start.y)
        let len2: Double = abs(c2.x - c1.x) + abs(c2.y - c1.y)
        let len3: Double = abs(end.x - c2.x) + abs(end.y - c2.y)
        let n: Int = max(4, min(40, Int(((len1 + len2 + len3) / 0.8).rounded(.up))))
        for i in 1...n {
            let t: Double = Double(i) / Double(n)
            let u: Double = 1 - t
            let a: Double = u * u * u
            let b: Double = 3 * u * u * t
            let c: Double = 3 * u * t * t
            let d: Double = t * t * t
            let px: Double = a * start.x + b * c1.x + c * c2.x + d * end.x
            let py: Double = a * start.y + b * c1.y + c * c2.y + d * end.y
            cur.append(P(x: px, y: py))
        }
    }
    path.applyWithBlock { (e: UnsafePointer<CGPathElement>) -> Void in
        let el: CGPathElement = e.pointee
        switch el.type {
        case .moveToPoint:
            if cur.count > 2 { contours.append(cur) }
            last = pt(el.points[0])
            cur = [last]
        case .addLineToPoint:
            last = pt(el.points[0])
            cur.append(last)
        case .addQuadCurveToPoint:
            let c: P = pt(el.points[0])
            let e1: P = pt(el.points[1])
            appendQuad(from: last, control: c, to: e1)
            last = e1
        case .addCurveToPoint:
            let c1: P = pt(el.points[0])
            let c2: P = pt(el.points[1])
            let e1: P = pt(el.points[2])
            appendCubic(from: last, c1: c1, c2: c2, to: e1)
            last = e1
        case .closeSubpath:
            if cur.count > 2 { contours.append(cur) }
            cur = []
        @unknown default: break
        }
    }
    if cur.count > 2 { contours.append(cur) }
    if contours.isEmpty { return empty }
    var xmin = Double.infinity, ymin = Double.infinity, xmax = -Double.infinity, ymax = -Double.infinity
    for c in contours { for p in c { xmin = min(xmin, p.x); xmax = max(xmax, p.x); ymin = min(ymin, p.y); ymax = max(ymax, p.y) } }
    let xo = Int(xmin.rounded(.down)), yo = Int(ymin.rounded(.down))
    let w = Int(xmax.rounded(.up)) - xo, h = Int(ymax.rounded(.up)) - yo
    if w <= 0 || h <= 0 || w > 4096 || h > 4096 { return empty }
    // bitmap space: x right, y down, pixel (i,j) covers [i,i+1) x [j,j+1)
    var es = EdgeSet(evenOdd: false)
    for c in contours {
        es.addPoly(c.map { P(x: $0.x - Double(xo), y: Double(yo + h) - $0.y) }, normalize: false, shift: 0)
    }
    return GlyphBitmap(xOrigin: xo, yOrigin: yo, w: w, h: h, a: coverageBitmap(es, w, h))
}

/// Exact-in-x, 32 sub-scanline coverage of a non-zero filled edge set into an A8 buffer.
func coverageBitmap(_ set: EdgeSet, _ w: Int, _ h: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: w * h)
    var sw = Sweeper(set)
    let S = 32, inv = 1.0 / Double(S)
    var acc = [Float](repeating: 0, count: w + 2), diff = [Float](repeating: 0, count: w + 2)
    let fw = Double(w)
    for j in 0..<h {
        for i in 0..<(w + 2) { acc[i] = 0; diff[i] = 0 }
        for k in 0..<S {
            let ys = Double(j) + (Double(k) + 0.5) * inv
            sw.spans(ys) { xa0, xb0 in
                let xa = min(max(xa0, 0), fw), xb = min(max(xb0, 0), fw)
                if xb <= xa { return }
                let ia = Int(xa), ib = Int(xb)
                if ia == ib { acc[ia] += Float(xb - xa) }
                else {
                    acc[ia] += Float(Double(ia + 1) - xa)
                    if ib > ia + 1 { diff[ia + 1] += 1; diff[ib] -= 1 }
                    acc[ib] += Float(xb - Double(ib))
                }
            }
        }
        var run: Float = 0
        for i in 0..<w {
            run += diff[i]
            let v = (acc[i] + run) * Float(inv)
            out[j * w + i] = UInt8(max(0, min(255, (v * 255).rounded())))
        }
    }
    return out
}

// MARK: - layout

func utf32(_ p: UnsafePointer<UInt8>, _ n: Int) -> [UInt32] {
    var out: [UInt32] = []
    var i = 0
    func cont(_ k: Int) -> Bool { k < n && (p[k] & 0xC0) == 0x80 }
    while i < n {
        let ch = p[i]
        if ch <= 127 { out.append(UInt32(ch)) }
        else if ch <= 223 && cont(i + 1) { out.append(UInt32(ch & 31) << 6 | UInt32(p[i + 1] & 63)); i += 1 }
        else if ch <= 239 && cont(i + 1) && cont(i + 2) { out.append(UInt32(ch & 15) << 12 | UInt32(p[i + 1] & 63) << 6 | UInt32(p[i + 2] & 63)); i += 2 }
        else if ch <= 247 && cont(i + 1) && cont(i + 2) && cont(i + 3) {
            let v = UInt32(ch & 15) << 18 | UInt32(p[i + 1] & 63) << 12 | UInt32(p[i + 2] & 63) << 6 | UInt32(p[i + 3] & 63)
            out.append(v > 1114111 ? 65533 : v); i += 3
        } else {
            out.append(65533)
            while cont(i + 1) { i += 1 }
        }
        i += 1
    }
    return out
}

/// hb round-to-nearest of 26.6 fixed point (ties to even).
@inline(__always) func roundFix(_ v: Int) -> Int {
    let half = 1 << 5
    let delta = half - 1 + ((v >> 6) & 1)
    return (v + delta) >> 6
}

/// putText flags of the FontFace overload (cv::PUT_TEXT_*).
let putTextAlignMask: Int32 = 3, putTextAlignRight: Int32 = 2, putTextOriginBL: Int32 = 32, putTextWrap: Int32 = 128

struct PlacedGlyph { var bmp: GlyphBitmap; var x: Int }              // x = pen + offset, relative to the line origin
struct TextLine { var glyphs: [PlacedGlyph]; var width: Int; var x0: Int; var baseline: Int; var ext: Int }

struct TextLayout {
    var lines: [TextLine] = []
    var retX = 0, retY = 0
    var ascent = 0
    var rectX = 0, rectY = 0, rectW = 0, rectH = 0
    var bottom = 0                                  // lowest ink below the last baseline (cv2's getTextSize baseline term)
}

/// Layout of (possibly multi-line, wrapped, right aligned) text, OpenCV 5.1 style: integer pen, advances rounded per glyph,
/// '\n' starts a new line (leading/trailing newlines are dropped), line pitch = rounded (ascent + descent + gap).
func layoutTextUncached(_ textIn: [UInt32], face: TextFace, size: Int, weight: Int, flags: Int32, wrap: (Int, Int)?, orgX: Int, orgY: Int,
                imgW: Int) -> TextLayout? {
    guard size > 0, face.ascUnits > 0 else { return nil }
    let hbScale = Int((Double(size) * 64.0 * Double(face.upem) / Double(face.ascUnits)).rounded(.toNearestOrEven))
    var out = TextLayout()
    let asc = Int((Double(face.ascUnits) * Double(hbScale) / Double(face.upem)).rounded(.toNearestOrEven))
    out.ascent = Int((Double(asc) / 64.0).rounded(.toNearestOrEven))
    // OpenCV: a font with a line gap uses only the gap as pitch (Arial: ~1 px), otherwise ascent + descent
    let pitchUnits = face.gapUnits > 0 ? face.gapUnits : face.ascUnits + face.descUnits
    let pitch = Int((Double(pitchUnits) * Double(hbScale) / Double(face.upem) / 64.0).rounded())
    var text = textIn
    while let f = text.first, f == 10 { text.removeFirst() }
    if let l = text.last, l == 10 { text.removeLast() }          // only one trailing newline is dropped
    let right = (flags & putTextAlignMask) == putTextAlignRight
    let doWrap = (flags & putTextWrap) != 0
    var wa = orgX, wb = imgW
    if right { wa = 0; wb = orgX }
    if let w = wrap { wa = min(w.0, w.1); wb = max(w.0, w.1) }
    // control characters other than '\n' are not renderable
    let cleaned = text.map { ($0 < 32 && $0 != 10) || $0 == 127 || ($0 >= 0x80 && $0 < 0xA0) || $0 == 0x2028 || $0 == 0x2029 ? UInt32(0x3F) : $0 }
    var logical: [[UInt32]] = [[]]
    for c in cleaned { if c == 10 { logical.append([]) } else { logical[logical.count - 1].append(c) } }
    if cleaned.isEmpty { out.retX = orgX; out.retY = orgY; out.rectX = orgX; out.rectY = orgY; out.rectW = 1; return out }
    struct G { var g: ShapedGlyph; var adv: Int; var off: Int }
    var lineIndex = 0
    var minX = Int.max, maxX = Int.min
    var maxExt = 0
    for (li, lg) in logical.enumerated() {
        let shaped = lg.isEmpty ? [] : face.shapeFull(lg, weight: weight, hbScale: hbScale)
        let gl = shaped.map { G(g: $0, adv: roundFix($0.adv64), off: roundFix($0.dx64)) }
        // break into visual lines
        var visual: [[G]] = [[]]
        var w = 0
        let fullLimit = wb - wa
        var limitPen = doWrap ? (li == 0 ? (right ? orgX - wa : wb - orgX) : fullLimit) : Int.max
        for (k, g) in gl.enumerated() {
            let reach = g.adv
            if doWrap, w + reach > limitPen, !visual[visual.count - 1].isEmpty {
                visual.append([]); w = 0
                limitPen = fullLimit
                if lg.count == gl.count && lg[k] == 32 { continue }      // a space that would start a wrapped line is dropped
            }
            visual[visual.count - 1].append(g); w += g.adv
        }
        for (vi, vg) in visual.enumerated() {
            let width = vg.reduce(0) { $0 + $1.adv }
            var x0: Int
            let cont = doWrap && (vi > 0 || li > 0)
            if right { x0 = (cont ? wb : orgX) - width } else { x0 = cont ? wa : orgX }
            _ = vi
            var pen = 0
            var placed: [PlacedGlyph] = []
            var ext = 0
            for g in vg {
                let b = face.bitmap(glyph: g.g.glyph, weight: weight, hbScale: hbScale)
                if b.w > 0 {
                    ext = max(ext, -b.yOrigin)
                    placed.append(PlacedGlyph(bmp: b, x: pen + g.off))
                }
                pen += g.adv
            }
            let base = orgY + lineIndex * pitch * ((flags & putTextOriginBL) != 0 ? 1 : 1)
            out.lines.append(TextLine(glyphs: placed, width: width, x0: x0, baseline: base, ext: ext))
            minX = min(minX, x0); maxX = max(maxX, x0 + width)
            maxExt = max(maxExt, ext)
            out.retX = right ? x0 : x0 + width
            out.retY = base
            lineIndex += 1
        }
    }
    let n = lineIndex
    let bottomMax = (n - 1) * pitch + maxExt
    out.bottom = bottomMax
    out.rectX = minX; out.rectW = maxX - minX + 1
    if (flags & putTextOriginBL) != 0 {
        out.rectY = orgY - maxExt
        out.rectH = (n - 1) * pitch + out.ascent + maxExt
    } else {
        out.rectY = orgY - out.ascent
        out.rectH = out.ascent + bottomMax
    }
    return out
}


// MARK: - layout cache (the same labels are drawn every frame)

private struct LayoutKey: Hashable {
    var text: [UInt32]; var face: ObjectIdentifier
    var size: Int, weight: Int, flags: Int32, wa: Int, wb: Int, orgX: Int, imgW: Int
}
nonisolated(unsafe) private var layoutCache: [LayoutKey: TextLayout] = [:]
private let layoutCacheLock = NSLock()

/// Layout is computed once per (text, font, size, weight, flags, ...) at origin (0, 0) and translated to the requested origin.
func layoutText(_ text: [UInt32], face: TextFace, size: Int, weight: Int, flags: Int32, wrap: (Int, Int)?, orgX: Int, orgY: Int,
                imgW: Int) -> TextLayout? {
    let right = (flags & putTextAlignMask) == putTextAlignRight
    let doWrap = (flags & putTextWrap) != 0
    let ox = (right || doWrap) ? orgX : 0
    let key = LayoutKey(text: text, face: ObjectIdentifier(face), size: size, weight: weight, flags: flags,
                        wa: wrap?.0 ?? Int.min, wb: wrap?.1 ?? Int.min, orgX: ox, imgW: (doWrap && !right && wrap == nil) ? imgW : 0)
    layoutCacheLock.lock()
    var lay = layoutCache[key]
    layoutCacheLock.unlock()
    if lay == nil {
        guard let l = layoutTextUncached(text, face: face, size: size, weight: weight, flags: flags, wrap: wrap, orgX: ox, orgY: 0, imgW: imgW) else { return nil }
        layoutCacheLock.lock()
        if layoutCache.count > 512 { layoutCache.removeAll() }
        layoutCache[key] = l
        layoutCacheLock.unlock()
        lay = l
    }
    var l = lay!
    let dx = orgX - ox, dy = orgY
    if dx != 0 || dy != 0 {
        for i in 0..<l.lines.count { l.lines[i].x0 += dx; l.lines[i].baseline += dy }
        l.retX += dx; l.retY += dy; l.rectX += dx; l.rectY += dy
    }
    return l
}

@inline(__always) private func div255r(_ x: Int) -> Int { let t = x + 127; return (t + 1 + (t >> 8)) >> 8 }   // (x + 127) / 255

func drawLayout(_ lay: TextLayout, _ img: SRImage, _ col: (Double, Double, Double, Double), bottomLeft bl: Bool) {
    let cb = Int(srSatU8(col.0)), cg = Int(srSatU8(col.1)), cr = Int(srSatU8(col.2))
    let nch = img.channels, W = img.width, H = img.height
    for line in lay.lines {
        for g in line.glyphs {
            let b = g.bmp
            let x0 = line.x0 + g.x + b.xOrigin
            let dxLo = max(0, -x0), dxHi = min(b.w, W - x0)
            if dxLo >= dxHi { continue }
            let yTop = bl ? line.baseline + (b.yOrigin + b.h) : line.baseline - (b.yOrigin + b.h)
            b.a.withUnsafeBufferPointer { ap in
                for dy in 0..<b.h {
                    let y = yTop + dy * (bl ? -1 : 1)
                    if y < 0 || y >= H { continue }
                    let row = img.row(y).assumingMemoryBound(to: UInt8.self) + x0 * nch
                    let src = ap.baseAddress! + dy * b.w
                    for dx in dxLo..<dxHi {
                        let a = Int(src[dx])
                        if a == 0 { continue }
                        let p = row + dx * nch
                        let ia = 255 - a
                        p[0] = UInt8(truncatingIfNeeded: div255r(Int(p[0]) * ia + cb * a))
                        if nch >= 3 {
                            p[1] = UInt8(truncatingIfNeeded: div255r(Int(p[1]) * ia + cg * a))
                            p[2] = UInt8(truncatingIfNeeded: div255r(Int(p[2]) * ia + cr * a))
                            if nch == 4 { p[3] = UInt8(a) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - fonts registry (FontFace)

/// A font loaded from a TTF / OTF / TTC file (FontFace(path)). Shaping through CoreText, outlines from the same CTFont.
final class FileFace: TextFace {
    let upem: Int, ascUnits: Int, descUnits: Int, gapUnits: Int
    let wghtRange: (min: Int, max: Int)?
    var currentWeight: Int
    private let base: CTFont
    private let cg: CGFont
    private var fonts: [Int: CTFont] = [:]
    private var cache: [UInt64: GlyphBitmap] = [:]
    private let lock = NSLock()

    init?(path: String) {
        let url = URL(fileURLWithPath: path)
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor], let d = descs.first else { return nil }
        let probe = CTFontCreateWithFontDescriptor(d, 1000, nil)
        let u = Int(CTFontGetUnitsPerEm(probe))
        guard u > 0 else { return nil }
        let f = CTFontCreateWithFontDescriptor(d, CGFloat(u), nil)      // size = units per em, so points == font units
        base = f
        guard let cgf = CTFontCopyGraphicsFont(f, nil) as CGFont? else { return nil }
        cg = cgf
        upem = u
        ascUnits = Int(CTFontGetAscent(f).rounded())
        descUnits = Int(CTFontGetDescent(f).rounded())
        gapUnits = Int(CTFontGetLeading(f).rounded())
        var range: (Int, Int)? = nil
        if let axes = CTFontCopyVariationAxes(f) as? [[CFString: Any]] {
            for ax in axes {
                if let id = ax[kCTFontVariationAxisIdentifierKey] as? Int, id == 0x77676874,
                   let mn = ax[kCTFontVariationAxisMinimumValueKey] as? Double, let mx = ax[kCTFontVariationAxisMaximumValueKey] as? Double {
                    range = (Int(mn), Int(mx))
                }
            }
        }
        wghtRange = range
        currentWeight = range?.0 ?? 0
        guard ascUnits > 0 else { return nil }
    }

    private func font(weight: Int) -> CTFont {
        guard wghtRange != nil else { return base }
        lock.lock(); defer { lock.unlock() }
        if let f = fonts[weight] { return f }
        let attrs: [CFString: Any] = [kCTFontVariationAttribute: [NSNumber(value: 0x77676874): NSNumber(value: weight)]]
        let f = CTFontCreateWithGraphicsFont(cg, CGFloat(upem), nil, CTFontDescriptorCreateWithAttributes(attrs as CFDictionary))
        fonts[weight] = f
        return f
    }

    func shapeFull(_ text: [UInt32], weight: Int, hbScale: Int) -> [ShapedGlyph] {
        let font = self.font(weight: weight)
        var u16: [UniChar] = []
        for c in text {
            var cc = c
            if cc >= 0x10000 {
                let v = cc - 0x10000
                u16.append(UniChar(0xD800 + (v >> 10))); u16.append(UniChar(0xDC00 + (v & 0x3FF)))
                continue
            }
            var ch: [UniChar] = [UniChar(cc)], g = [CGGlyph](repeating: 0, count: 1)
            if !CTFontGetGlyphsForCharacters(font, &ch, &g, 1) || g[0] == 0 { cc = 0x3F }    // not in this font: '?'
            u16.append(UniChar(cc))
        }
        if u16.isEmpty { return [] }
        let astr = CFAttributedStringCreate(nil, String(utf16CodeUnits: u16, count: u16.count) as CFString,
                                            [kCTFontAttributeName: font] as CFDictionary)!
        let line = CTLineCreateWithAttributedString(astr)
        var glyphs: [CGGlyph] = [], pos: [CGPoint] = []
        for run in (CTLineGetGlyphRuns(line) as! [CTRun]) {
            let rf = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            let n = CTRunGetGlyphCount(run)
            var g = [CGGlyph](repeating: 0, count: n), p = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRangeMake(0, 0), &g)
            CTRunGetPositions(run, CFRangeMake(0, 0), &p)
            if !CFEqual(rf, font) {      // CoreText substituted another font for some characters: draw '?' of our font instead
                var q: [UniChar] = [0x3F], qg = [CGGlyph](repeating: 0, count: 1)
                _ = CTFontGetGlyphsForCharacters(font, &q, &qg, 1)
                g = [CGGlyph](repeating: qg[0], count: n)
            }
            glyphs += g; pos += p
        }
        var raw = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &raw, glyphs.count)
        let k = Double(hbScale) / Double(upem)
        var out: [ShapedGlyph] = []
        var cum = 0.0
        for i in 0..<glyphs.count {
            let a = Double(raw[i].width)
            let full = i + 1 < glyphs.count ? Double(pos[i + 1].x - pos[i].x) : a
            let offX = Double(pos[i].x) - cum
            out.append(ShapedGlyph(glyph: glyphs[i], adv64: Int((full * k).rounded(.toNearestOrEven)),
                                   dx64: Int((offX * k).rounded(.toNearestOrEven)), dy64: Int((Double(pos[i].y) * k).rounded(.toNearestOrEven))))
            cum += a
        }
        // marks (zero raw advance) keep their offset but do not move the pen: fold the pen movement into advances
        return out
    }

    func bitmap(glyph: CGGlyph, weight: Int, hbScale: Int) -> GlyphBitmap {
        let key = UInt64(glyph) << 40 | UInt64(weight & 0xFFFF) << 24 | UInt64(hbScale & 0xFFFFFF)
        lock.lock()
        if let b = cache[key] { lock.unlock(); return b }
        lock.unlock()
        let b = renderGlyphBitmap(font: font(weight: weight), glyph: glyph, hbScale: hbScale, upem: upem)
        lock.lock()
        if cache.count > 4096 { cache.removeAll() }
        cache[key] = b
        lock.unlock()
        return b
    }
}

nonisolated(unsafe) private var faceRegistry: [Int32: FileFace] = [:]
nonisolated(unsafe) private var nextFaceId: Int32 = 1
private let faceLock = NSLock()

@_cdecl("sr_font_load")
public func sr_font_load(_ path: UnsafePointer<UInt8>?, _ len: Int32) -> Int32 {
    guard let path, len > 0 else { return srFail(SRStatus.badArgument, "font: empty path") }
    let p = String(decoding: UnsafeBufferPointer(start: path, count: Int(len)), as: UTF8.self)
    guard FileManager.default.fileExists(atPath: p), let f = FileFace(path: p) else { return srFail(SRStatus.ioFailure, "font: cannot load \(p)") }
    faceLock.lock(); defer { faceLock.unlock() }
    let id = nextFaceId; nextFaceId += 1
    faceRegistry[id] = f
    return id
}

@_cdecl("sr_font_free")
public func sr_font_free(_ id: Int32) {
    faceLock.lock(); faceRegistry[id] = nil; faceLock.unlock()
    layoutCacheLock.lock(); layoutCache.removeAll(); layoutCacheLock.unlock()      // a new face may reuse the freed object's address
}

/// out[0] = has a wght axis, out[1] = min, out[2] = max (builtin id 0 = Rubik 300...900).
@_cdecl("sr_font_axis")
public func sr_font_axis(_ id: Int32, _ out: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let out, let f = lookupFace(id), let r = f.wghtRange else { out?[0] = 0; out?[1] = 0; out?[2] = 0; return SRStatus.ok }
    out[0] = 1; out[1] = Int32(r.min); out[2] = Int32(r.max)
    return SRStatus.ok
}

func lookupFace(_ id: Int32) -> TextFace? {
    if id <= 0 { return Rubik.shared }
    faceLock.lock(); defer { faceLock.unlock() }
    return faceRegistry[id]
}

private let weightLock = NSLock()

/// Weight actually used for a call: 0 = the font's current instance; anything else is clamped to the axis and becomes the new
/// current instance (a FontFace remembers its last weight, and the built-in font is shared by all FontFace("sans") objects).
func effectiveWeight(_ face: TextFace, _ weight: Int) -> Int {
    guard let r = face.wghtRange else { return 0 }
    weightLock.lock(); defer { weightLock.unlock() }
    if weight <= 0 { return face.currentWeight }
    let w = max(r.min, min(r.max, weight))
    face.currentWeight = w
    return w
}

/// sr_font_weight(id, set, value): returns the font's current wght (0 if the font has no weight axis); set != 0 stores `value`.
@_cdecl("sr_font_weight")
public func sr_font_weight(_ id: Int32, _ set: Int32, _ value: Int32) -> Int32 {
    guard let f = lookupFace(id), let r = f.wghtRange else { return 0 }
    weightLock.lock(); defer { weightLock.unlock() }
    if set != 0 { f.currentWeight = max(r.min, min(r.max, Int(value))) }
    return Int32(f.currentWeight)
}

// MARK: - C ABI

@_cdecl("sr_draw_puttext")
public func sr_draw_puttext(_ data: UnsafeMutableRawPointer?, _ w: Int32, _ h: Int32, _ stride: Int32, _ ch: Int32, _ depth: Int32,
                            _ text: UnsafePointer<UInt8>?, _ textLen: Int32, _ orgX: Int32, _ orgY: Int32,
                            _ font: Int32, _ scale: Double, _ color: UnsafePointer<Double>?,
                            _ thickness: Int32, _ lineType: Int32, _ bottomLeft: Int32) -> Int32 {
    guard let img = SRImage(data, w, h, stride, ch, depth) else { return srFail(SRStatus.badArgument, "putText: bad image") }
    guard img.depth == .u8, img.channels != 2 else { return srFail(SRStatus.unsupported, "putText: img.depth() == CV_8U and 1, 3 or 4 channels required") }
    guard let fp = faceParams(font, scale, thickness) else { return srFail(SRStatus.badArgument, "putText: unknown font or bad scale") }
    guard let text, textLen > 0, let rubik = Rubik.shared else { return SRStatus.ok }
    let flags: Int32 = bottomLeft != 0 ? putTextOriginBL : 0
    guard let lay = layoutText(utf32(text, Int(textLen)), face: rubik, size: fp.size, weight: effectiveWeight(rubik, fp.weight), flags: flags, wrap: nil,
                               orgX: Int(orgX), orgY: Int(orgY), imgW: img.width) else { return SRStatus.ok }
    drawLayout(lay, img, srColor(color), bottomLeft: bottomLeft != 0)
    return SRStatus.ok
}

/// out[0]=width, out[1]=height, out[2]=baseline (cv2 5.x getTextSize).
@_cdecl("sr_text_size")
public func sr_text_size(_ text: UnsafePointer<UInt8>?, _ textLen: Int32, _ font: Int32, _ scale: Double,
                         _ thickness: Int32, _ out: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let out else { return srFail(SRStatus.badArgument, "getTextSize: null output") }
    guard let fp = faceParams(font, scale, thickness) else { return srFail(SRStatus.badArgument, "getTextSize: unknown font or bad scale") }
    out[0] = 0; out[1] = 0; out[2] = 0
    guard let text, textLen > 0, let rubik = Rubik.shared,
          let lay = layoutText(utf32(text, Int(textLen)), face: rubik, size: fp.size, weight: effectiveWeight(rubik, fp.weight), flags: 0, wrap: nil, orgX: 0, orgY: 0, imgW: 0),
          !lay.lines.isEmpty else { return SRStatus.ok }
    out[0] = Int32(lay.rectW); out[1] = Int32(lay.ascent); out[2] = Int32(lay.bottom)
    return SRStatus.ok
}

/// putText(img, text, org, color, fface, size, weight, flags, wrap): out[0], out[1] = where the text can be continued.
@_cdecl("sr_draw_puttext_face")
public func sr_draw_puttext_face(_ data: UnsafeMutableRawPointer?, _ w: Int32, _ h: Int32, _ stride: Int32, _ ch: Int32, _ depth: Int32,
                                 _ text: UnsafePointer<UInt8>?, _ textLen: Int32, _ orgX: Int32, _ orgY: Int32, _ color: UnsafePointer<Double>?,
                                 _ fontId: Int32, _ size: Int32, _ weight: Int32, _ flags: Int32,
                                 _ hasWrap: Int32, _ wrapA: Int32, _ wrapB: Int32, _ out: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let img = SRImage(data, w, h, stride, ch, depth) else { return srFail(SRStatus.badArgument, "putText: bad image") }
    guard img.depth == .u8, img.channels != 2 else { return srFail(SRStatus.unsupported, "putText: img.depth() == CV_8U and 1, 3 or 4 channels required") }
    guard let face = lookupFace(fontId) else { return srFail(SRStatus.badArgument, "putText: font is not available") }
    out?[0] = orgX; out?[1] = orgY
    guard let text, textLen > 0 else { return SRStatus.ok }
    guard size > 0 else { return SRStatus.ok }
    guard let lay = layoutText(utf32(text, Int(textLen)), face: face, size: Int(size), weight: effectiveWeight(face, Int(weight)), flags: flags,
                               wrap: hasWrap != 0 ? (Int(wrapA), Int(wrapB)) : nil, orgX: Int(orgX), orgY: Int(orgY), imgW: img.width) else { return SRStatus.ok }
    out?[0] = Int32(truncatingIfNeeded: lay.retX); out?[1] = Int32(truncatingIfNeeded: lay.retY)
    drawLayout(lay, img, srColor(color), bottomLeft: (flags & putTextOriginBL) != 0)
    return SRStatus.ok
}

/// getTextSize(imgsize, text, org, fface, size, weight, flags, wrap) -> Rect in out[0...3].
@_cdecl("sr_text_rect_face")
public func sr_text_rect_face(_ imgW: Int32, _ text: UnsafePointer<UInt8>?, _ textLen: Int32, _ orgX: Int32, _ orgY: Int32,
                              _ fontId: Int32, _ size: Int32, _ weight: Int32, _ flags: Int32,
                              _ hasWrap: Int32, _ wrapA: Int32, _ wrapB: Int32, _ out: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let out else { return srFail(SRStatus.badArgument, "getTextSize: null output") }
    guard let face = lookupFace(fontId) else { return srFail(SRStatus.badArgument, "getTextSize: font is not available") }
    out[0] = orgX; out[1] = orgY; out[2] = textLen > 0 ? 1 : 0; out[3] = 0
    guard let text, textLen > 0, size > 0 else { return SRStatus.ok }
    guard let lay = layoutText(utf32(text, Int(textLen)), face: face, size: Int(size), weight: effectiveWeight(face, Int(weight)), flags: flags,
                               wrap: hasWrap != 0 ? (Int(wrapA), Int(wrapB)) : nil, orgX: Int(orgX), orgY: Int(orgY), imgW: Int(imgW)) else { return SRStatus.ok }
    out[0] = Int32(truncatingIfNeeded: lay.rectX); out[1] = Int32(truncatingIfNeeded: lay.rectY)
    out[2] = Int32(truncatingIfNeeded: lay.rectW); out[3] = Int32(truncatingIfNeeded: lay.rectH)
    return SRStatus.ok
}
