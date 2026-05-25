// validate_clmul.swift — batch-validate GPU clmul64 vs CPU clmul64.
// The GPU version is the heart of verusclhash: every other primitive
// (mulhrs, reduction, the 32-iter loop) is straight translation. If
// clmul64 is right, the rest of the kernel port is mechanical.
//
// Test methodology:
//   - 8 hand-picked edge cases that stress different branches:
//       (0,0), (1,1), (max,max), alternating bits, sparse a, sparse b,
//       a-with-low-bits, b-with-high-bits.
//   - 1024 pseudo-random (a, b) pairs derived from a deterministic LCG
//     so failures are reproducible.
//   - All 1032 pairs dispatched in one GPU batch, byte-diffed vs CPU.
//
// Compile:
//   cd verusminer/metal
//   clang++ -c -std=c++17 -O2 -I../cpu \
//       ../cpu/canonical/clmul_shim.cpp -o ../cpu/canonical/clmul_shim.o
//   swiftc -O validate_clmul.swift -o validate_clmul \
//       -framework Metal -framework Foundation \
//       ../cpu/canonical/clmul_shim.o \
//       ../cpu/canonical/verus_clhash_portable.o \
//       -Xlinker -lc++ -Xlinker -lm
// Run:
//   ./validate_clmul

import Foundation
import Metal

// ---- CPU reference (via clmul_shim.cpp) ----
@_silgen_name("clmul64_wrap")
func clmul64_wrap(_ a: UInt64, _ b: UInt64,
                  _ r: UnsafeMutablePointer<UInt64>)

// ---- GPU dispatch ----
let kernelFile = "clmul64.metal"
let kernelPath = FileManager.default.currentDirectoryPath + "/" + kernelFile
print("Loading kernel: \(kernelFile)")
guard let kernelSrc = try? String(contentsOfFile: kernelPath, encoding: .utf8) else {
    fatalError("Cannot load \(kernelFile) from cwd")
}
guard let device = MTLCreateSystemDefaultDevice() else { fatalError("No Metal device") }
guard let queue = device.makeCommandQueue() else { fatalError("No queue") }
print("GPU: \(device.name)")

let lib: MTLLibrary
do { lib = try device.makeLibrary(source: kernelSrc, options: nil) }
catch { fatalError("Kernel compile failed: \(error)") }
guard let fn = lib.makeFunction(name: "clmul64_kernel") else { fatalError("Kernel not found") }
let ps = try! device.makeComputePipelineState(function: fn)

// ---- Build test pairs ----
struct Pair { let a: UInt64; let b: UInt64; let label: String }

var pairs: [Pair] = [
    Pair(a: 0,                  b: 0,                  label: "zero × zero"),
    Pair(a: 1,                  b: 1,                  label: "1 × 1"),
    Pair(a: UInt64.max,         b: UInt64.max,         label: "max × max"),
    Pair(a: 0xAAAAAAAAAAAAAAAA, b: 0x5555555555555555, label: "alt-hi × alt-lo"),
    Pair(a: 0x0000000000000001, b: 0xFFFFFFFFFFFFFFFF, label: "lsb × all-ones"),
    Pair(a: 0x8000000000000000, b: 0x8000000000000000, label: "msb × msb"),
    Pair(a: 0x123456789ABCDEF0, b: 0x0FEDCBA987654321, label: "ascending × descending"),
    Pair(a: 0xDEADBEEFCAFEBABE, b: 0xFEEDFACEBADDCAFE, label: "hex words"),
]

// 1024 pseudo-random pairs from xorshift64* (deterministic, repeatable)
var state: UInt64 = 0x9E3779B97F4A7C15
func xs64() -> UInt64 {
    state ^= state >> 12
    state ^= state &<< 25
    state ^= state >> 27
    return state &* 0x2545F4914F6CDD1D
}

for i in 0..<1024 {
    let a = xs64()
    let b = xs64()
    pairs.append(Pair(a: a, b: b, label: "rand[\(i)]"))
}

// ---- CPU reference batch ----
var cpuOut = [UInt64](repeating: 0, count: pairs.count * 2)
for (i, p) in pairs.enumerated() {
    var r: [UInt64] = [0, 0]
    r.withUnsafeMutableBufferPointer { rp in
        clmul64_wrap(p.a, p.b, rp.baseAddress!)
    }
    cpuOut[i * 2 + 0] = r[0]
    cpuOut[i * 2 + 1] = r[1]
}

// ---- GPU batch ----
var inputs = [UInt64](repeating: 0, count: pairs.count * 2)
for (i, p) in pairs.enumerated() {
    inputs[i * 2 + 0] = p.a
    inputs[i * 2 + 1] = p.b
}

let inBytes = inputs.count * MemoryLayout<UInt64>.size
let outBytes = inBytes
let inBuf = inputs.withUnsafeBufferPointer { ptr in
    device.makeBuffer(bytes: ptr.baseAddress!, length: inBytes, options: .storageModeShared)!
}
let outBuf = device.makeBuffer(length: outBytes, options: .storageModeShared)!

let cb = queue.makeCommandBuffer()!
let enc = cb.makeComputeCommandEncoder()!
enc.setComputePipelineState(ps)
enc.setBuffer(inBuf,  offset: 0, index: 0)
enc.setBuffer(outBuf, offset: 0, index: 1)
let tpg = min(ps.maxTotalThreadsPerThreadgroup, 256)
enc.dispatchThreads(MTLSize(width: pairs.count, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: tpg, height: 1, depth: 1))
enc.endEncoding()
cb.commit()
cb.waitUntilCompleted()

let gpuPtr = outBuf.contents().bindMemory(to: UInt64.self, capacity: pairs.count * 2)
let gpuOut = Array(UnsafeBufferPointer(start: gpuPtr, count: pairs.count * 2))

// ---- Diff ----
var failures = 0
var firstFailures: [String] = []
for (i, p) in pairs.enumerated() {
    let cLo = cpuOut[i*2+0], cHi = cpuOut[i*2+1]
    let gLo = gpuOut[i*2+0], gHi = gpuOut[i*2+1]
    if cLo != gLo || cHi != gHi {
        failures += 1
        if firstFailures.count < 5 {
            firstFailures.append(String(format:
                "  [%@]\n    a=%016llx b=%016llx\n    CPU: lo=%016llx hi=%016llx\n    GPU: lo=%016llx hi=%016llx",
                p.label as NSString, p.a, p.b, cLo, cHi, gLo, gHi))
        }
    }
}

// Print first 8 (the named edges) so the user can see them
print("\nFirst 8 (edge cases):")
for i in 0..<8 {
    let p = pairs[i]
    let cLo = cpuOut[i*2+0], cHi = cpuOut[i*2+1]
    let gLo = gpuOut[i*2+0], gHi = gpuOut[i*2+1]
    let ok = (cLo == gLo && cHi == gHi)
    print(String(format: "  [%@] a=%016llx b=%016llx", p.label as NSString, p.a, p.b))
    print(String(format: "      CPU lo=%016llx hi=%016llx", cLo, cHi))
    print(String(format: "      GPU lo=%016llx hi=%016llx  %@", gLo, gHi, ok ? "✓" : "✗"))
}

print("")
if failures == 0 {
    print("PASS — all \(pairs.count) (a, b) pairs: GPU clmul64 == CPU clmul64 byte-for-byte")
    exit(0)
} else {
    print("FAIL — \(failures)/\(pairs.count) pairs mismatched")
    for f in firstFailures { print(f) }
    exit(1)
}
