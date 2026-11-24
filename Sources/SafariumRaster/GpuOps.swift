// SafariumRaster — opt-in GPU (Metal) C-ABI entry points. See GpuContext.swift for the design.
// Contract with cv2/_gpu.py: return 0 = done; any non-zero = nothing was written that the caller must keep, run the CPU
// path instead (the Python side does that silently). All matrices are f32 CoreMat descriptors (CoreTypes.swift).

import Foundation
import Metal

/// Layout of one f32 operand as the kernels see it.
private struct GpuOperand {
    let region: GpuContext.Region
    let rowStride: Int       // elements
}

/// `depth` 5 = f32 (elements of 4 bytes), 0 = u8 (elements of 1 byte); offsets and strides are in elements.
private func gpuOperand(_ m: CoreMat, write: Bool, depth: Int32 = 5) -> GpuOperand? {
    let e = depth == 5 ? 4 : 1
    guard m.isValid, m.depth == depth, m.rows > 0, m.cols > 0, m.step % e == 0,
          Int(bitPattern: m.data!) % e == 0, m.step / e <= Int(UInt32.max), m.n <= Int(UInt32.max) else { return nil }
    let span = (m.rows - 1) * m.step + m.n * e
    return GpuOperand(region: .init(ptr: m.data!, span: span, write: write), rowStride: m.step / e)
}

/// Shared launcher: all operands must have the same shape. Packed operands collapse to one long row.
private func gpuLaunch(kernel: String, op: Int32, ops: [GpuOperand], shape: CoreMat, mats: [CoreMat?], p: Float, flags: UInt32,
                       elem: Int = 4, perThread: Int = 4, extra: (Float, Float, Float) = (0, 0, 0)) -> Int32 {
    guard let ctx = GpuContext.shared else { return srFail(SRStatus.unsupported, "gpu: Metal unavailable") }
    let present = ops
    for r in present where r.region.span > ctx.device.maxBufferLength {
        return srFail(SRStatus.unsupported, "gpu: array larger than maxBufferLength")
    }
    var rowElems = shape.n, rows = shape.rows
    let allPacked = mats.compactMap { $0 }.allSatisfy { packed($0) }
    if allPacked, shape.n * shape.rows <= Int(UInt32.max) { rowElems = shape.n * shape.rows; rows = 1 }
    let strides = present.map { UInt32(rows == 1 ? 0 : $0.rowStride) }
    let gx = (rowElems + perThread - 1) / perThread
    return ctx.run(kernel: kernel, op: op, regions: present.map { $0.region },
                   params: { offs in
                       var g = GpuParams()
                       g.off0 = offs[0] / UInt64(elem)
                       if offs.count > 1 { g.off1 = offs[1] / UInt64(elem) }
                       if offs.count > 2 { g.off2 = offs[2] / UInt64(elem) }
                       if offs.count > 3 { g.off3 = offs[3] / UInt64(elem) }
                       g.st0 = strides[0]
                       if strides.count > 1 { g.st1 = strides[1] }
                       if strides.count > 2 { g.st2 = strides[2] }
                       if strides.count > 3 { g.st3 = strides[3] }
                       g.rowElems = UInt32(rowElems)
                       g.rows = UInt32(rows)
                       g.p = p
                       (g.p1, g.p2, g.p3) = extra
                       g.flags = flags
                       return g
                   }, gx: gx, rows: rows)
}

private func sameShape(_ a: CoreMat, _ b: CoreMat) -> Bool { a.rows == b.rows && a.cols == b.cols && a.cn == b.cn }

/// 1 when a Metal device, queue and the embedded shaders are available (creates the context on first use).
@_cdecl("sr_gpu_available")
public func sr_gpu_available() -> Int32 { GpuContext.shared == nil ? 0 : 1 }

/// Device name (UTF-8, NUL-terminated) into buf; returns its length (0 when Metal is unavailable).
@_cdecl("sr_gpu_device_name")
public func sr_gpu_device_name(_ buf: UnsafeMutablePointer<CChar>?, _ cap: Int32) -> Int32 {
    guard let ctx = GpuContext.shared else { return 0 }
    let utf8 = Array(ctx.device.name.utf8)
    if let buf, cap > 0 {
        let n = min(utf8.count, Int(cap) - 1)
        for i in 0..<n { buf[i] = CChar(bitPattern: utf8[i]) }
        buf[n] = 0
    }
    return Int32(utf8.count)
}

/// Number of successful GPU dispatches so far; with `copies` set, the number that needed the one-copy fallback.
@_cdecl("sr_gpu_dispatch_count")
public func sr_gpu_dispatch_count(_ copies: Int32) -> Int64 {
    guard let ctx = GpuContext.shared else { return 0 }
    return copies != 0 ? ctx.copies : ctx.dispatches
}

/// op: 0 sqrt, 1 exp, 2 log, 3 pow(x, power) for non-integer powers. f32 only. In place (src == dst) is fine.
@_cdecl("sr_gpu_unary_f32")
public func sr_gpu_unary_f32(_ op: Int32, _ src: MatP?, _ dst: MatP?, _ power: Double) -> Int32 {
    guard let s = mat(src), let d = mat(dst), op >= 0, op <= 3, sameShape(s, d),
          let so = gpuOperand(s, write: false), let dO = gpuOperand(d, write: true) else {
        return srFail(SRStatus.unsupported, "gpu unary: unsupported operands")
    }
    return gpuLaunch(kernel: "k_unary", op: op, ops: [so, dO], shape: s, mats: [s, d], p: Float(power), flags: 0)
}

/// op: 0 magnitude (out0), 1 phase (out0), 2 cartToPolar (magnitude -> out0, angle -> out1). degrees != 0: angle in degrees.
@_cdecl("sr_gpu_binary_f32")
public func sr_gpu_binary_f32(_ op: Int32, _ x: MatP?, _ y: MatP?, _ out0: MatP?, _ out1: MatP?, _ degrees: Int32) -> Int32 {
    guard let a = mat(x), let b = mat(y), let o0 = mat(out0), op >= 0, op <= 2, sameShape(a, b), sameShape(a, o0),
          let ao = gpuOperand(a, write: false), let bo = gpuOperand(b, write: false), let o0o = gpuOperand(o0, write: true) else {
        return srFail(SRStatus.unsupported, "gpu binary: unsupported operands")
    }
    var ops: [GpuOperand] = [ao, bo, o0o]
    var mats: [CoreMat?] = [a, b, o0]
    if op == 2 {
        guard let o1 = mat(out1), sameShape(a, o1), let o1o = gpuOperand(o1, write: true) else {
            return srFail(SRStatus.unsupported, "gpu binary: unsupported angle output")
        }
        ops.append(o1o); mats.append(o1)
    }
    return gpuLaunch(kernel: "k_binary", op: op, ops: ops, shape: a, mats: mats, p: Float(Double.pi / 180.0), flags: degrees != 0 ? 1 : 0)
}

/// x = mag * cos(angle), y = mag * sin(angle); mag may be NULL. degrees != 0: angle in degrees.
@_cdecl("sr_gpu_polar2cart_f32")
public func sr_gpu_polar2cart_f32(_ mag: MatP?, _ angle: MatP?, _ x: MatP?, _ y: MatP?, _ degrees: Int32) -> Int32 {
    guard let an = mat(angle), let xo = mat(x), let yo = mat(y), sameShape(an, xo), sameShape(an, yo),
          let ano = gpuOperand(an, write: false), let xop = gpuOperand(xo, write: true), let yop = gpuOperand(yo, write: true) else {
        return srFail(SRStatus.unsupported, "gpu polarToCart: unsupported operands")
    }
    var flags: UInt32 = degrees != 0 ? 1 : 0
    var mm: CoreMat = an
    var mo: GpuOperand = ano          // placeholder when there is no magnitude (binds the angle buffer twice)
    if let m = mat(mag) {
        guard sameShape(an, m), let mop = gpuOperand(m, write: false) else {
            return srFail(SRStatus.unsupported, "gpu polarToCart: unsupported magnitude")
        }
        flags |= 2; mm = m; mo = mop
    }
    return gpuLaunch(kernel: "k_polar", op: 0, ops: [ano, mo, xop, yop], shape: an, mats: [an, mm, xo, yo],
                     p: Float(Double.pi / 180.0), flags: flags)
}

/// Timings of the most recent dispatch in ns: which 0 = wrapping buffers, 1 = encode+commit+wait, 2 = GPU kernel time.
@_cdecl("sr_gpu_last_ns")
public func sr_gpu_last_ns(_ which: Int32) -> Int64 {
    guard let ctx = GpuContext.shared, which >= 0, which < 3 else { return 0 }
    return ctx.lastNs[Int(which)]
}

/// 8-bit fused arithmetic on two same-shape u8 arrays (any channel count, rows may be strided).
/// op 0: dst = saturate(rint(a * p0 + b * p1 + p2))  (addWeighted)    op 1: dst = saturate(rint(a * b * p0))  (multiply)
/// Differs from the CPU path by at most 1 LSB (float32 arithmetic, ties to even).
@_cdecl("sr_gpu_u8_arith")
public func sr_gpu_u8_arith(_ op: Int32, _ a: MatP?, _ b: MatP?, _ dst: MatP?, _ p0: Double, _ p1: Double, _ p2: Double) -> Int32 {
    guard let x = mat(a), let y = mat(b), let d = mat(dst), op >= 0, op <= 1, sameShape(x, y), sameShape(x, d),
          let xo = gpuOperand(x, write: false, depth: 0), let yo = gpuOperand(y, write: false, depth: 0),
          let dO = gpuOperand(d, write: true, depth: 0) else {
        return srFail(SRStatus.unsupported, "gpu u8: unsupported operands")
    }
    return gpuLaunch(kernel: "k_u8", op: op, ops: [xo, yo, dO], shape: x, mats: [x, y, d], p: Float(p0), flags: 0,
                     elem: 1, perThread: 16, extra: (Float(p1), Float(p2), 0))
}
