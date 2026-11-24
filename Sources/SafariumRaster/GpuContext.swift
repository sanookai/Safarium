// SafariumRaster — opt-in GPU (Metal) paths (Pick 2026-11-24, docs/raster-roadmap.md section 5).
//
// One MTLDevice, one command queue, one serial dispatch lock (SF-VIDEO-1: a single worker, never many queues).
// Shaders are compiled at runtime from the embedded Metal source below, so Package.swift needs no change
// (`import Metal` auto-links the framework). Everything here is OFF unless Python calls an `sr_gpu_*` entry point
// (cv2/_gpu.py does that only after `cv2.safarium_set_gpu(True)` / SAFARIUM_GPU=1). Every failure returns a non-zero
// status and the Python side falls back to the exact CPU path; nothing here ever aborts the process.

import Foundation
import Metal

/// Parameter block shared with the Metal kernels (field order and sizes must match `struct GP` in the source).
struct GpuParams {
    var off0: UInt64 = 0, off1: UInt64 = 0, off2: UInt64 = 0, off3: UInt64 = 0   // element offsets from buffer base
    var st0: UInt32 = 0, st1: UInt32 = 0, st2: UInt32 = 0, st3: UInt32 = 0       // row strides in elements
    var rowElems: UInt32 = 0
    var rows: UInt32 = 0
    var p: Float = 0
    var flags: UInt32 = 0
    var p1: Float = 0, p2: Float = 0, p3: Float = 0, pad: UInt32 = 0
}

let gpuKernelSource = """
#include <metal_stdlib>
using namespace metal;

struct GP {
    ulong off0, off1, off2, off3;
    uint st0, st1, st2, st3;
    uint rowElems;
    uint rows;
    float p;
    uint flags;
    float p1, p2, p3;
    uint pad;
};

constant int OP [[function_constant(0)]];

// ---- helpers (OpenCV 5.1 fastAtan2 polynomial, same constants and FMA order as core_neon.c src_phase32) ----
constant float RAD2DEG = (float)(180.0 / 3.14159265358979323846);
constant float AP1 = (float)0.9997878412794807 * RAD2DEG;
constant float AP3 = (float)-0.3258083974640975 * RAD2DEG;
constant float AP5 = (float)0.1555786518463281 * RAD2DEG;
constant float AP7 = (float)-0.04432655554792128 * RAD2DEG;

inline float4 atan2deg(float4 vy, float4 vx) {
    float4 ax = abs(vx), ay = abs(vy);
    bool4 big = ax >= ay;
    float4 num = select(ax, ay, big), den = select(ay, ax, big);
    float4 c = num / (den + 2.220446049250313e-16f);
    float4 c2 = c * c;
    float4 t = fma(float4(AP7), c2, float4(AP5));
    float4 u = fma(t, c2, float4(AP3));
    float4 a = fma(u, c2, float4(AP1)) * c;
    a = select(90.0f - a, a, big);
    a = select(a, 180.0f - a, vx < 0.0f);
    a = select(a, 360.0f - a, vy < 0.0f);
    return a;
}

// Walk one row in groups of 4 (tail handled lane by lane). `F` computes 4 results from 4 inputs.
#define GP_ROW_SETUP \\
    uint x = gid.x * 4; \\
    if (x >= g.rowElems || gid.y >= g.rows) return; \\
    bool full = (x + 4) <= g.rowElems; \\
    uint lanes = full ? 4 : (g.rowElems - x);

inline float4 ld4(device const float* p, bool full, uint lanes) {
    if (full) return float4(*(device const packed_float4*)p);
    float4 v = float4(0.0f);
    for (uint i = 0; i < lanes; ++i) v[i] = p[i];
    return v;
}
inline void st4(device float* p, float4 v, bool full, uint lanes) {
    if (full) { *(device packed_float4*)p = packed_float4(v); return; }
    for (uint i = 0; i < lanes; ++i) p[i] = v[i];
}

// buffer(0)=src, buffer(1)=dst. OP: 0 sqrt, 1 exp, 2 log, 3 pow(x, p)
kernel void k_unary(device const float* a [[buffer(0)]], device float* o [[buffer(1)]], constant GP& g [[buffer(4)]],
                    uint2 gid [[thread_position_in_grid]]) {
    GP_ROW_SETUP
    float4 v = ld4(a + g.off0 + (ulong)gid.y * g.st0 + x, full, lanes);
    float4 r;
    if (OP == 0) r = precise::sqrt(v);
    else if (OP == 1) r = precise::exp(v);
    else if (OP == 2) r = precise::log(v);
    else r = precise::pow(v, float4(g.p));
    st4(o + g.off1 + (ulong)gid.y * g.st1 + x, r, full, lanes);
}

// buffer(0)=x, (1)=y, (2)=out0, (3)=out1. OP: 0 magnitude, 1 phase, 2 cartToPolar (mag -> out0, angle -> out1)
// flags bit0: angle in degrees (else radians; p holds pi/180 for the radian scale).
kernel void k_binary(device const float* a [[buffer(0)]], device const float* b [[buffer(1)]],
                     device float* o0 [[buffer(2)]], device float* o1 [[buffer(3)]], constant GP& g [[buffer(4)]],
                     uint2 gid [[thread_position_in_grid]]) {
    GP_ROW_SETUP
    float4 vx = ld4(a + g.off0 + (ulong)gid.y * g.st0 + x, full, lanes);
    float4 vy = ld4(b + g.off1 + (ulong)gid.y * g.st1 + x, full, lanes);
    if (OP == 0 || OP == 2) {
        float4 m = precise::sqrt(vx * vx + vy * vy);
        st4(o0 + g.off2 + (ulong)gid.y * g.st2 + x, m, full, lanes);
    }
    if (OP == 1 || OP == 2) {
        float4 ang = atan2deg(vy, vx);
        if ((g.flags & 1u) == 0) ang = ang * g.p;
        device float* dst = (OP == 1) ? (o0 + g.off2 + (ulong)gid.y * g.st2 + x) : (o1 + g.off3 + (ulong)gid.y * g.st3 + x);
        st4(dst, ang, full, lanes);
    }
}

// polarToCart: buffer(0)=angle, (1)=magnitude (only when flags bit1), (2)=x out, (3)=y out. flags bit0: degrees (p = pi/180).
kernel void k_polar(device const float* ang [[buffer(0)]], device const float* mag [[buffer(1)]],
                    device float* ox [[buffer(2)]], device float* oy [[buffer(3)]], constant GP& g [[buffer(4)]],
                    uint2 gid [[thread_position_in_grid]]) {
    GP_ROW_SETUP
    float4 t = ld4(ang + g.off0 + (ulong)gid.y * g.st0 + x, full, lanes);
    if ((g.flags & 1u) != 0) t = t * g.p;
    float4 s = precise::sin(t), c = precise::cos(t);
    if ((g.flags & 2u) != 0) {
        float4 m = ld4(mag + g.off1 + (ulong)gid.y * g.st1 + x, full, lanes);
        s = s * m; c = c * m;
    }
    st4(ox + g.off2 + (ulong)gid.y * g.st2 + x, c, full, lanes);
    st4(oy + g.off3 + (ulong)gid.y * g.st3 + x, s, full, lanes);
}

// 8-bit kernels, 16 bytes per thread. Offsets and strides are in bytes. buffer(0)=a, (1)=b, (2)=dst.
// OP 0: addWeighted dst = sat(rint(a*p + b*p1 + p2)); OP 1: multiply dst = sat(rint(a*b*p))
inline uchar sat_u8(float v) { return uchar(clamp(rint(v), 0.0f, 255.0f)); }
inline uchar4 u8_op(uchar4 a, uchar4 b, constant GP& g) {
    float4 fa = float4(a), fb = float4(b);
    float4 r;
    if (OP == 0) r = fma(fa, float4(g.p), fma(fb, float4(g.p1), float4(g.p2)));
    else r = (fa * fb) * g.p;
    return uchar4(clamp(rint(r), 0.0f, 255.0f));
}
kernel void k_u8(device const uchar* a [[buffer(0)]], device const uchar* b [[buffer(1)]], device uchar* o [[buffer(2)]],
                 constant GP& g [[buffer(4)]], uint2 gid [[thread_position_in_grid]]) {
    uint x = gid.x * 16;
    if (x >= g.rowElems || gid.y >= g.rows) return;
    device const uchar* pa = a + g.off0 + (ulong)gid.y * g.st0 + x;
    device const uchar* pb = b + g.off1 + (ulong)gid.y * g.st1 + x;
    device uchar* po = o + g.off2 + (ulong)gid.y * g.st2 + x;
    if (x + 16 <= g.rowElems) {
        for (uint k = 0; k < 4; ++k) {
            uchar4 va = uchar4(*(device const packed_uchar4*)(pa + 4 * k));
            uchar4 vb = uchar4(*(device const packed_uchar4*)(pb + 4 * k));
            *(device packed_uchar4*)(po + 4 * k) = packed_uchar4(u8_op(va, vb, g));
        }
    } else {
        for (uint i = 0; x + i < g.rowElems; ++i) {
            uchar4 r = u8_op(uchar4(pa[i]), uchar4(pb[i]), g);
            po[i] = r[0];
        }
    }
}
"""

/// Process-wide Metal state. Created lazily on the first GPU request; `nil` forever if Metal is unavailable.
final class GpuContext: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let pageSize: Int
    private let lock = NSLock()                    // single worker: one dispatch at a time
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private(set) var dispatches: Int64 = 0
    private(set) var copies: Int64 = 0             // dispatches that needed the one-copy fallback
    private(set) var broken = false
    /// Timings of the last dispatch in ns: [wrap buffers, encode+commit+wait, GPU kernel (device clock)].
    private(set) var lastNs: [Int64] = [0, 0, 0]

    nonisolated(unsafe) static var shared: GpuContext? = {
        if ProcessInfo.processInfo.environment["SAFARIUM_GPU_DISABLE"] == "1" { return nil }
        return GpuContext()
    }()

    private init?() {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else { return nil }
        let opts = MTLCompileOptions()
        // IEEE-style math: sqrt is correctly rounded and exp/log/pow/sin/cos use the precise variants, not the
        // relaxed fast-math ones (those are several ulp worse).
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) {
            opts.mathMode = .safe
            opts.mathFloatingPointFunctions = .precise
        } else {
            opts.fastMathEnabled = false
        }
        #else
        opts.fastMathEnabled = false
        #endif
        guard let lib = try? dev.makeLibrary(source: gpuKernelSource, options: opts) else { return nil }
        device = dev
        queue = q
        library = lib
        pageSize = Int(getpagesize())
    }

    func pipeline(_ kernel: String, op: Int32) -> MTLComputePipelineState? {
        let key = "\(kernel)#\(op)"
        if let p = pipelines[key] { return p }
        let cv = MTLFunctionConstantValues()
        var o = op
        cv.setConstantValue(&o, type: .int, index: 0)
        guard let fn = try? library.makeFunction(name: kernel, constantValues: cv),
              let ps = try? device.makeComputePipelineState(function: fn) else { return nil }
        pipelines[key] = ps
        return ps
    }

    /// A caller-owned region the kernels read or write: base pointer, byte span of the data, and whether it is written.
    struct Region {
        let ptr: UnsafeMutableRawPointer
        let span: Int
        let write: Bool
    }

    /// Runs `kernel` over `regions` (bound to buffer indices 0...n-1), `gx` x `rows` threads. Zero-copy via
    /// `bytesNoCopy` over the page range that contains each array (every such page is mapped, the kernels only touch
    /// array bytes); when Metal refuses a range the region is copied through a private buffer instead.
    /// Returns 0 on success, a negative SRStatus otherwise.
    func run(kernel: String, op: Int32, regions: [Region], params: ([UInt64]) -> GpuParams, gx: Int, rows: Int) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let t0 = DispatchTime.now().uptimeNanoseconds
        if broken { return srFail(SRStatus.unsupported, "gpu: disabled after an earlier failure") }
        guard let ps = pipeline(kernel, op: op) else { return srFail(SRStatus.unsupported, "gpu: pipeline \(kernel) failed") }
        // Wrap each region; identical page ranges share one MTLBuffer (in-place ops).
        var bufs: [MTLBuffer] = []
        var offsets: [UInt64] = []                  // byte offset of the array inside its buffer
        var copied: [(MTLBuffer, Region)] = []      // regions that went through the private-buffer fallback
        var seen: [(Int, Int, MTLBuffer)] = []
        for r in regions {
            let addr = Int(bitPattern: r.ptr)
            let base = addr & ~(pageSize - 1)
            let off = addr - base
            let len = (off + r.span + pageSize - 1) & ~(pageSize - 1)
            if let s = seen.first(where: { $0.0 == base && $0.1 == len }) {
                bufs.append(s.2); offsets.append(UInt64(off)); continue
            }
            var buf = device.makeBuffer(bytesNoCopy: UnsafeMutableRawPointer(bitPattern: base)!, length: len,
                                        options: .storageModeShared, deallocator: nil)
            var o = off
            if buf == nil {
                guard r.span > 0, let b = device.makeBuffer(length: r.span, options: .storageModeShared) else {
                    return srFail(SRStatus.unsupported, "gpu: cannot create buffer")
                }
                memcpy(b.contents(), r.ptr, r.span)    // one copy in (also for write-only: dst may be partly read-modify)
                copied.append((b, r))
                buf = b
                o = 0
            } else {
                seen.append((base, len, buf!))
            }
            bufs.append(buf!)
            offsets.append(UInt64(o))
        }
        let t1 = DispatchTime.now().uptimeNanoseconds
        var gp = params(offsets)                      // callee converts byte offsets to element offsets
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else {
            return srFail(SRStatus.unsupported, "gpu: no command buffer")
        }
        enc.setComputePipelineState(ps)
        for (i, b) in bufs.enumerated() { enc.setBuffer(b, offset: 0, index: i) }
        for i in bufs.count..<4 { enc.setBuffer(bufs[0], offset: 0, index: i) }
        enc.setBytes(&gp, length: MemoryLayout<GpuParams>.stride, index: 4)
        let tw = min(256, max(1, ps.maxTotalThreadsPerThreadgroup), gx)
        enc.dispatchThreads(MTLSize(width: gx, height: rows, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        let t2 = DispatchTime.now().uptimeNanoseconds
        if cb.status != .completed {
            broken = true
            return srFail(SRStatus.internalError, "gpu: command buffer failed (\(cb.error?.localizedDescription ?? "unknown"))")
        }
        for (b, r) in copied where r.write { memcpy(r.ptr, b.contents(), r.span) }
        lastNs = [Int64(t1 - t0), Int64(t2 - t1), Int64((cb.gpuEndTime - cb.gpuStartTime) * 1e9)]
        dispatches += 1
        if !copied.isEmpty { copies += 1 }
        return 0
    }
}
