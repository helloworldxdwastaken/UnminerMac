// Metal compute throughput benchmark — Apple M5 GPU
//
// Apple GPU has NO hardware AES instructions exposed to MSL. So we measure
// raw GPU integer throughput (XOR + rotate, the primitives AES is built from)
// then extrapolate what a software AES kernel could hit. This tells us
// whether Metal compute is even worth pursuing for AES-heavy algos like
// VerusHash 2.2.
//
// Compile:
//   swiftc -O metal_aes_bench.swift -o metal_aes_bench \
//          -framework Metal -framework Foundation
// Run:
//   ./metal_aes_bench

import Foundation
import Metal

let kernelSrc = """
#include <metal_stdlib>
using namespace metal;

// Each thread does INNER_OPS chained XOR+rotate operations.
// These are the primitives AES is made of (XOR for AddRoundKey,
// rotates for ShiftRows, byte-level work for SubBytes/MixColumns).
// A real AES round on Apple GPU (no hw AES) would be ~10-15x more
// expensive than this minimal kernel because it needs S-box lookups
// and MixColumns matrix multiply — so divide the throughput by ~12
// to estimate software-AES rounds/sec.

kernel void xor_throughput(device atomic_uint *sentinel [[buffer(0)]],
                           constant uint &inner_ops [[buffer(1)]],
                           uint tid [[thread_position_in_grid]]) {
    uint a = tid * 0x9E3779B9u;
    uint b = tid ^ 0xDEADBEEFu;
    uint c = tid + 0x12345678u;
    uint d = tid * 7u;

    for (uint i = 0; i < inner_ops; i++) {
        a ^= b;
        a = (a << 1)  | (a >> 31);
        b ^= c;
        b = (b << 5)  | (b >> 27);
        c ^= d;
        c = (c << 7)  | (c >> 25);
        d ^= a;
        d = (d << 13) | (d >> 19);
    }

    // Anti-DCE: write to sentinel if we hit an impossible state.
    if ((a ^ b ^ c ^ d) == 0xAAAAAAAAu) {
        atomic_fetch_add_explicit(sentinel, 1u, memory_order_relaxed);
    }
}
"""

// 4 ops per inner iter (xor+rotate counted as 1 op each pair → 8 ops).
// Conservative: count each xor as 1 op.
let OPS_PER_INNER_ITER: UInt = 8

guard let device = MTLCreateSystemDefaultDevice() else {
    fatalError("no Metal device")
}
print("== Apple Silicon Metal compute bench ==")
print("device:           \(device.name)")
print("max threads/grp:  \(device.maxThreadsPerThreadgroup.width)")
print("max buffer len:   \(device.maxBufferLength / (1024*1024)) MB")
print("unified memory:   \(device.hasUnifiedMemory)")
print("")

guard let queue = device.makeCommandQueue() else {
    fatalError("no command queue")
}

let lib: MTLLibrary
do {
    lib = try device.makeLibrary(source: kernelSrc, options: nil)
} catch {
    fatalError("shader compile failed: \(error)")
}

guard let fn = lib.makeFunction(name: "xor_throughput") else {
    fatalError("kernel not found")
}

let pipeline: MTLComputePipelineState
do {
    pipeline = try device.makeComputePipelineState(function: fn)
} catch {
    fatalError("pipeline failed: \(error)")
}

let maxTPG = pipeline.maxTotalThreadsPerThreadgroup
print("kernel max threads/threadgroup: \(maxTPG)")
print("")

// Run configurations: vary thread count to find the sweet spot.
struct Run { let threads: Int; let innerOps: UInt }
let runs: [Run] = [
    Run(threads:    1024, innerOps: 10_000_000),  // tiny — sanity
    Run(threads:   10_240, innerOps:  1_000_000),  // 10× cores
    Run(threads:  102_400, innerOps:    100_000),  // saturate
    Run(threads: 1_024_000, innerOps:     10_000), // massive parallel
]

let sentinelBuf = device.makeBuffer(length: 4, options: .storageModeShared)!

for run in runs {
    // Reset sentinel
    sentinelBuf.contents().bindMemory(to: UInt32.self, capacity: 1)[0] = 0

    let cmdBuf = queue.makeCommandBuffer()!
    let encoder = cmdBuf.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(sentinelBuf, offset: 0, index: 0)
    var innerOpsVar = run.innerOps
    encoder.setBytes(&innerOpsVar, length: MemoryLayout<UInt>.size, index: 1)

    let tgSize = min(maxTPG, 256)
    let gridSize = MTLSize(width: run.threads, height: 1, depth: 1)
    let tgGroupSize = MTLSize(width: tgSize, height: 1, depth: 1)
    encoder.dispatchThreads(gridSize, threadsPerThreadgroup: tgGroupSize)
    encoder.endEncoding()

    let t0 = Date()
    cmdBuf.commit()
    cmdBuf.waitUntilCompleted()
    let elapsed = Date().timeIntervalSince(t0)

    let totalOps = Double(run.threads) * Double(run.innerOps) * Double(OPS_PER_INNER_ITER)
    let gops = totalOps / elapsed / 1e9
    let aes_equiv = gops / 12.0  // ~12x more cycles per AES round on software path
    let haraka_mhs = aes_equiv * 1000.0 / 12.0  // / 12 AES rounds per Haraka256
    let verus_mhs = haraka_mhs / 150.0

    let sentinelVal = sentinelBuf.contents().bindMemory(to: UInt32.self, capacity: 1)[0]

    print(String(format: "%10d threads × %8d ops    | %6.2fs  |  %7.2f G ops/sec  |  ~%6.2f G AES/sec  |  ~%6.2f MH/s VerusHash  | sentinel=%d",
                 run.threads, run.innerOps, elapsed, gops, aes_equiv, verus_mhs, sentinelVal))
}

print("")
print("interpretation:")
print("  Apple GPU has NO hardware AES → software path is ~12× slower")
print("  per op than CPU. CPU bench measured 16.6 G AES/sec across all cores.")
print("  Metal compute wins ONLY if GPU ops/sec is meaningfully larger than")
print("  CPU equivalent — and only for fully-parallel hash candidates.")
