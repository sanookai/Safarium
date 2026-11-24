// SafariumRaster — JPEG buffered entropy coding (Area C): optimised Huffman tables and progressive scans.
//
// Used when IMWRITE_JPEG_OPTIMIZE or IMWRITE_JPEG_PROGRESSIVE is set. All quantised coefficients are kept (zigzag order,
// Int16) so each scan can be coded twice: once to gather symbol statistics, once with the Huffman tables built from them
// (ITU T.81 Annex K.2). Progressive scans follow libjpeg's jpeg_simple_progression script and jcphuff.c's coding rules
// (EOB runs, correction bits). Rewritten in Swift from the public specification.

import Foundation

/// One component's coefficient store: `ptr[(row * stride + col) * 64 + zigzagIndex]`.
struct JPEGComp {
    let ptr: UnsafeMutablePointer<Int16>
    let stride: Int       // blocks per stored row (MCU padded)
    let hb: Int, vb: Int  // blocks per MCU (horizontal, vertical)
    let bw: Int, bh: Int  // real block grid (non-interleaved scans)
}

/// Symbol/bit sink: gathers Huffman statistics or writes the coded scan.
struct JPEGSink {
    let gather: Bool
    let freq: UnsafeMutablePointer<Int>       // 4 slots x 257
    var codes: UnsafeMutablePointer<UInt32>   // 4 slots x 256, code << 8 | length
    var bits: JPEGBits

    @inline(__always) mutating func sym(_ slot: Int, _ s: Int) {
        if gather { freq[slot * 257 + s] += 1 } else {
            let e = codes[slot * 256 + s]
            bits.put(e >> 8, Int(e & 0xFF))
        }
    }

    @inline(__always) mutating func raw(_ v: UInt32, _ n: Int) {
        if !gather && n > 0 { bits.put(v & ((1 << UInt32(n)) - 1), n) }
    }
}

/// End-of-band run state for progressive AC scans.
struct JPEGProgState {
    var eobrun = 0
    var be: [UInt8] = []   // correction bits buffered behind the pending EOB run
}

/// Annex K.2 optimal table (jpeg_gen_optimal_table): frequencies of symbols 0...255 -> (BITS[1...16], HUFFVAL).
func jpegOptimalTable(_ f: UnsafePointer<Int>) -> (bits: [UInt8], vals: [UInt8]) {
    var freq = [Int](repeating: 0, count: 257)
    var any = false
    for i in 0..<256 { freq[i] = f[i]; if f[i] > 0 { any = true } }
    if !any { freq[0] = 1 }
    freq[256] = 1  // reserved code point so that no real symbol gets the all-ones code
    var codesize = [Int](repeating: 0, count: 257)
    var others = [Int](repeating: -1, count: 257)
    while true {
        var c1 = -1, v = Int.max
        for i in 0...256 where freq[i] != 0 && freq[i] <= v { v = freq[i]; c1 = i }
        var c2 = -1
        v = Int.max
        for i in 0...256 where freq[i] != 0 && freq[i] <= v && i != c1 { v = freq[i]; c2 = i }
        if c2 < 0 { break }
        freq[c1] += freq[c2]
        freq[c2] = 0
        codesize[c1] += 1
        while others[c1] >= 0 { c1 = others[c1]; codesize[c1] += 1 }
        others[c1] = c2
        codesize[c2] += 1
        while others[c2] >= 0 { c2 = others[c2]; codesize[c2] += 1 }
    }
    var bits = [Int](repeating: 0, count: 34)
    for i in 0...256 where codesize[i] > 0 { bits[min(codesize[i], 33)] += 1 }
    var i = 32
    while i > 16 {
        while bits[i] > 0 {
            var j = i - 2
            while bits[j] == 0 { j -= 1 }
            bits[i] -= 2
            bits[i - 1] += 1
            bits[j + 1] += 2
            bits[j] -= 1
        }
        i -= 1
    }
    i = 16
    while bits[i] == 0 { i -= 1 }
    bits[i] -= 1  // drop the reserved code point
    var vals = [UInt8]()
    for len in 1...32 { for s in 0..<256 where codesize[s] == len { vals.append(UInt8(s)) } }
    return ((1...16).map { UInt8(bits[$0]) }, vals)
}

@inline(__always) private func bitLen(_ v: Int) -> Int { Int.bitWidth - v.leadingZeroBitCount }

private func dcSlot(_ ci: Int) -> Int { ci == 0 ? 0 : 2 }
private func acSlot(_ ci: Int) -> Int { ci == 0 ? 1 : 3 }

private func restartSink(_ s: inout JPEGSink, _ rstNum: inout Int) {
    if !s.gather {
        s.bits.finish()
        s.bits.marker(UInt8(0xD0 + rstNum))
    }
    rstNum = (rstNum + 1) & 7
}

private func emitEOBRun(_ s: inout JPEGSink, _ st: inout JPEGProgState, _ slot: Int) {
    guard st.eobrun > 0 else { return }
    let nb = bitLen(st.eobrun) - 1
    s.sym(slot, nb << 4)
    if nb > 0 { s.raw(UInt32(st.eobrun) & ((1 << UInt32(nb)) - 1), nb) }
    st.eobrun = 0
    for b in st.be { s.raw(UInt32(b), 1) }
    st.be.removeAll(keepingCapacity: true)
}

// MARK: - Scan coders

/// Baseline sequential scan, every component interleaved.
private func scanSequential(_ s: inout JPEGSink, _ comps: [JPEGComp], _ g: JPEGGeometry, rst: Int) {
    var pred = [Int](repeating: 0, count: 3)
    var count = 0, rstNum = 0
    for my in 0..<g.mcuRows {
        for mx in 0..<g.mcuCols {
            if rst > 0 {
                if count > 0 && count % rst == 0 { restartSink(&s, &rstNum); pred = [0, 0, 0] }
                count += 1
            }
            if !s.gather { s.bits.reserve(8192) }
            for (ci, c) in comps.enumerated() {
                for by in 0..<c.vb {
                    for bx in 0..<c.hb {
                        let b = c.ptr + ((my * c.vb + by) * c.stride + mx * c.hb + bx) * 64
                        let dcs = dcSlot(ci), acs = acSlot(ci)
                        let diff = Int(b[0]) - pred[ci]
                        pred[ci] = Int(b[0])
                        let nb = bitLen(abs(diff))
                        s.sym(dcs, nb)
                        s.raw(UInt32(truncatingIfNeeded: diff < 0 ? diff - 1 : diff), nb)
                        var r = 0
                        for k in 1..<64 {
                            let v = Int(b[k])
                            if v == 0 { r += 1; continue }
                            while r > 15 { s.sym(acs, 0xF0); r -= 16 }
                            let n = bitLen(abs(v))
                            s.sym(acs, r << 4 | n)
                            s.raw(UInt32(truncatingIfNeeded: v < 0 ? v - 1 : v), n)
                            r = 0
                        }
                        if r > 0 { s.sym(acs, 0) }
                    }
                }
            }
        }
    }
    if !s.gather { s.bits.finish() }
}

private struct JPEGScanSpec {
    var comps: [Int]
    var ss: Int, se: Int, ah: Int, al: Int
}

/// DC scan (first or refinement), all listed components interleaved per MCU.
private func scanDC(_ s: inout JPEGSink, _ comps: [JPEGComp], _ g: JPEGGeometry, _ spec: JPEGScanSpec, rst: Int) {
    var pred = [Int](repeating: 0, count: 3)
    var count = 0, rstNum = 0
    let mcuCols = spec.comps.count == 1 ? comps[spec.comps[0]].bw : g.mcuCols
    let mcuRows = spec.comps.count == 1 ? comps[spec.comps[0]].bh : g.mcuRows
    for my in 0..<mcuRows {
        for mx in 0..<mcuCols {
            if rst > 0 {
                if count > 0 && count % rst == 0 { restartSink(&s, &rstNum); pred = [0, 0, 0] }
                count += 1
            }
            if !s.gather { s.bits.reserve(1024) }
            for ci in spec.comps {
                let c = comps[ci]
                let (vb, hb) = spec.comps.count == 1 ? (1, 1) : (c.vb, c.hb)
                for by in 0..<vb {
                    for bx in 0..<hb {
                        let b = c.ptr + ((my * vb + by) * c.stride + mx * hb + bx) * 64
                        if spec.ah == 0 {
                            let t = Int(b[0]) >> spec.al
                            let diff = t - pred[ci]
                            pred[ci] = t
                            let nb = bitLen(abs(diff))
                            s.sym(dcSlot(ci), nb)
                            s.raw(UInt32(truncatingIfNeeded: diff < 0 ? diff - 1 : diff), nb)
                        } else {
                            s.raw(UInt32((Int(b[0]) >> spec.al) & 1), 1)
                        }
                    }
                }
            }
        }
    }
    if !s.gather { s.bits.finish() }
}

/// AC scan of one component (first pass or refinement), jcphuff.c encode_mcu_AC_first / encode_mcu_AC_refine.
private func scanAC(_ s: inout JPEGSink, _ c: JPEGComp, _ ci: Int, _ spec: JPEGScanSpec, rst: Int) {
    var st = JPEGProgState()
    let slot = acSlot(ci)
    let ss = spec.ss, se = spec.se, al = spec.al
    var count = 0, rstNum = 0
    var absv = [Int](repeating: 0, count: 64)
    var br: [UInt8] = []
    for by in 0..<c.bh {
        for bx in 0..<c.bw {
            if rst > 0 {
                if count > 0 && count % rst == 0 { emitEOBRun(&s, &st, slot); restartSink(&s, &rstNum) }
                count += 1
            }
            if !s.gather { s.bits.reserve(8192) }
            let b = c.ptr + (by * c.stride + bx) * 64
            if spec.ah == 0 {
                var r = 0
                for k in ss...se {
                    var t = Int(b[k])
                    if t == 0 { r += 1; continue }
                    let t2: Int
                    if t < 0 { t = -t; t >>= al; t2 = ~t } else { t >>= al; t2 = t }
                    if t == 0 { r += 1; continue }
                    if st.eobrun > 0 { emitEOBRun(&s, &st, slot) }
                    while r > 15 { s.sym(slot, 0xF0); r -= 16 }
                    let nb = bitLen(t)
                    s.sym(slot, r << 4 | nb)
                    s.raw(UInt32(truncatingIfNeeded: t2), nb)
                    r = 0
                }
                if r > 0 {
                    st.eobrun += 1
                    if st.eobrun == 0x7FFF { emitEOBRun(&s, &st, slot) }
                }
            } else {
                var eob = 0
                for k in ss...se {
                    let t = abs(Int(b[k])) >> al
                    absv[k] = t
                    if t == 1 { eob = k }
                }
                var r = 0
                br.removeAll(keepingCapacity: true)
                for k in ss...se {
                    let t = absv[k]
                    if t == 0 { r += 1; continue }
                    while r > 15 && k <= eob {
                        emitEOBRun(&s, &st, slot)
                        s.sym(slot, 0xF0)
                        r -= 16
                        for x in br { s.raw(UInt32(x), 1) }
                        br.removeAll(keepingCapacity: true)
                    }
                    if t > 1 { br.append(UInt8(t & 1)); continue }
                    emitEOBRun(&s, &st, slot)
                    s.sym(slot, r << 4 | 1)
                    s.raw(b[k] < 0 ? 0 : 1, 1)
                    for x in br { s.raw(UInt32(x), 1) }
                    br.removeAll(keepingCapacity: true)
                    r = 0
                }
                if r > 0 || !br.isEmpty {
                    st.eobrun += 1
                    st.be += br
                    if st.eobrun == 0x7FFF || st.be.count > 1000 - 64 + 1 { emitEOBRun(&s, &st, slot) }
                }
            }
        }
    }
    emitEOBRun(&s, &st, slot)
    if !s.gather { s.bits.finish() }
}

// MARK: - Driver

func jpegEncodeBuffered(_ img: SRImage, _ o: JPEGOptions, _ g: JPEGGeometry, _ strip: JPEGStripper,
                        _ qLuma: [Int], _ qChroma: [Int], _ recipL: [Int32], _ recipC: [Int32]) -> [UInt8]? {
    // 1. all quantised coefficients
    var comps: [JPEGComp] = []
    var owned: [UnsafeMutablePointer<Int16>] = []
    defer { for p in owned { p.deallocate() } }
    func makeComp(hb: Int, vb: Int, bw: Int, bh: Int) -> JPEGComp {
        let stride = g.mcuCols * hb
        let n = stride * g.mcuRows * vb * 64
        let p = UnsafeMutablePointer<Int16>.allocate(capacity: n)
        p.initialize(repeating: 0, count: n)
        owned.append(p)
        return JPEGComp(ptr: p, stride: stride, hb: hb, vb: vb, bw: bw, bh: bh)
    }
    let yBW = (g.w + 7) / 8, yBH = (g.h + 7) / 8
    comps.append(makeComp(hb: g.hs, vb: g.vs, bw: yBW, bh: yBH))
    if g.colour {
        let cbw = (g.w + 8 * g.hs - 1) / (8 * g.hs), cbh = (g.h + 8 * g.vs - 1) / (8 * g.vs)
        comps.append(makeComp(hb: 1, vb: 1, bw: cbw, bh: cbh))
        comps.append(makeComp(hb: 1, vb: 1, bw: cbw, bh: cbh))
    }
    let zzSrcT = UnsafePointer(jpegZZTables.src)
    recipL.withUnsafeBufferPointer { rL in
        recipC.withUnsafeBufferPointer { rC in
            /// zigzag-order copy of one quantised block (flat blocks carry only their DC).
            @inline(__always) func store(_ src: UnsafePointer<Int16>, _ mask: UInt64, _ dst: UnsafeMutablePointer<Int16>) {
                dst[0] = src[0]
                if mask != 0 { for i in 1..<64 { dst[i] = src[zzSrcT[i]] } }
            }
            let nbx = strip.yBlocksPerRow
            for my in 0..<g.mcuRows {
                strip.fill(my * strip.stripRows)
                strip.transform(rL.baseAddress!, rC.baseAddress!)
                for mx in 0..<g.mcuCols {
                    let y = comps[0]
                    for by in 0..<g.vs {
                        for bx in 0..<g.hs {
                            let idx = by * nbx + mx * g.hs + bx
                            store(strip.yCoef + idx * 64, strip.yMask[idx], y.ptr + ((my * g.vs + by) * y.stride + mx * g.hs + bx) * 64)
                        }
                    }
                    if g.colour {
                        store(strip.ccCoef + mx * 128, strip.ccMask[mx * 2], comps[1].ptr + (my * comps[1].stride + mx) * 64)
                        store(strip.ccCoef + mx * 128 + 64, strip.ccMask[mx * 2 + 1], comps[2].ptr + (my * comps[2].stride + mx) * 64)
                    }
                }
            }
        }
    }

    // 2. scans
    var out = jpegHeader(g, qLuma, qChroma, progressive: o.progressive)
    if o.rstInterval > 0 { out += jpegDRI(o.rstInterval) }
    let freq = UnsafeMutablePointer<Int>.allocate(capacity: 4 * 257)
    let codes = UnsafeMutablePointer<UInt32>.allocate(capacity: 4 * 256)
    defer { freq.deallocate(); codes.deallocate() }
    let ncomp = g.ncomp
    let rst = o.rstInterval

    /// Run one scan: pass 1 gathers statistics for `slots`, pass 2 writes with tables built from them.
    func runScan(_ slots: [Int], _ sos: [UInt8], _ body: (inout JPEGSink) -> Void) {
        freq.initialize(repeating: 0, count: 4 * 257)
        var gs = JPEGSink(gather: true, freq: freq, codes: codes, bits: JPEGBits(capacity: 1024))
        body(&gs)
        gs.bits.free()
        codes.initialize(repeating: 0, count: 4 * 256)
        for slot in slots {
            let (bits, vals) = jpegOptimalTable(freq + slot * 257)
            out += jpegDHT(slot % 2, slot / 2, bits: bits, vals: vals)   // slot -> (class, id): 0 DC0, 1 AC0, 2 DC1, 3 AC1
            let t = JPEGCodeTable(bits: bits, vals: vals)
            for sy in 0..<256 { codes[slot * 256 + sy] = (t.code[sy] << 8) | UInt32(t.size[sy]) }
        }
        out += sos
        var ws = JPEGSink(gather: false, freq: freq, codes: codes, bits: JPEGBits(capacity: 1 << 16))
        body(&ws)
        out.append(contentsOf: UnsafeBufferPointer(start: ws.bits.out, count: ws.bits.pos))
        ws.bits.free()
    }

    func dhtSlots(_ slotOf: [Int]) -> [Int] { Array(Set(slotOf)).sorted() }

    if !o.progressive {
        let slots = ncomp == 3 ? [0, 1, 2, 3] : [0, 1]
        let sos = jpegSOS(ncomp == 3 ? [(1, 0, 0), (2, 1, 1), (3, 1, 1)] : [(1, 0, 0)], ss: 0, se: 63, ah: 0, al: 0)
        runScan(slots, sos) { scanSequential(&$0, comps, g, rst: rst) }
    } else {
        var script: [JPEGScanSpec]
        let all = Array(0..<ncomp)
        if ncomp == 3 {
            script = [
                JPEGScanSpec(comps: all, ss: 0, se: 0, ah: 0, al: 1),
                JPEGScanSpec(comps: [0], ss: 1, se: 5, ah: 0, al: 2),
                JPEGScanSpec(comps: [2], ss: 1, se: 63, ah: 0, al: 1),
                JPEGScanSpec(comps: [1], ss: 1, se: 63, ah: 0, al: 1),
                JPEGScanSpec(comps: [0], ss: 6, se: 63, ah: 0, al: 2),
                JPEGScanSpec(comps: [0], ss: 1, se: 63, ah: 2, al: 1),
                JPEGScanSpec(comps: all, ss: 0, se: 0, ah: 1, al: 0),
                JPEGScanSpec(comps: [2], ss: 1, se: 63, ah: 1, al: 0),
                JPEGScanSpec(comps: [1], ss: 1, se: 63, ah: 1, al: 0),
                JPEGScanSpec(comps: [0], ss: 1, se: 63, ah: 1, al: 0),
            ]
        } else {
            script = [
                JPEGScanSpec(comps: [0], ss: 0, se: 0, ah: 0, al: 1),
                JPEGScanSpec(comps: [0], ss: 1, se: 5, ah: 0, al: 2),
                JPEGScanSpec(comps: [0], ss: 6, se: 63, ah: 0, al: 2),
                JPEGScanSpec(comps: [0], ss: 1, se: 63, ah: 2, al: 1),
                JPEGScanSpec(comps: [0], ss: 0, se: 0, ah: 1, al: 0),
                JPEGScanSpec(comps: [0], ss: 1, se: 63, ah: 1, al: 0),
            ]
        }
        for spec in script {
            if spec.ss == 0 {
                let sos = jpegSOS(spec.comps.map { (id: $0 + 1, dcTable: $0 == 0 ? 0 : 1, acTable: 0) }, ss: 0, se: 0, ah: spec.ah, al: spec.al)
                let slots = spec.ah == 0 ? dhtSlots(spec.comps.map { dcSlot($0) }) : []
                runScan(slots, sos) { scanDC(&$0, comps, g, spec, rst: rst) }
            } else {
                let ci = spec.comps[0]
                let sos = jpegSOS([(id: ci + 1, dcTable: 0, acTable: ci == 0 ? 0 : 1)], ss: spec.ss, se: spec.se, ah: spec.ah, al: spec.al)
                runScan([acSlot(ci)], sos) { scanAC(&$0, comps[ci], ci, spec, rst: rst) }
            }
        }
    }
    out += [0xFF, 0xD9]
    return out
}
