// validate_verusclhash.swift — end-to-end CPU↔GPU diff of the full
// verusclhash_sv2_2 algorithm (the 32-iter selector loop + lazyLengthHash
// XOR + precompReduction64). 6 deterministic seeds.
//
// Compile:
//   cd verusminer/metal
//   clang++ -c -std=c++17 -O2 -I../cpu/canonical -I../cpu \
//       ../cpu/canonical/clmul_shim.cpp -o ../cpu/canonical/clmul_shim.o
//   clang++ -c -std=c++17 -O2 -I../cpu/canonical -I../cpu \
//       ../cpu/canonical/verus_clhash_portable.cpp -o ../cpu/canonical/verus_clhash_portable.o
//   swiftc -O validate_verusclhash.swift -o validate_verusclhash \
//       -framework Metal -framework Foundation \
//       ../cpu/canonical/clmul_shim.o \
//       ../cpu/canonical/verus_clhash_portable.o \
//       ../cpu/haraka_portable.o \
//       -Xlinker -lc++ -Xlinker -lm

import Foundation
import Metal

@_silgen_name("verusclhash_sv2_2_wrap")
func verusclhash_sv2_2_wrap(_ key: UnsafeMutablePointer<UInt8>,
                            _ input: UnsafePointer<UInt8>,
                            _ keyMask: UInt64) -> UInt64

let kernelFile = "verusclhash_sv2_2.metal"
let kernelPath = FileManager.default.currentDirectoryPath + "/" + kernelFile
print("Loading kernel: \(kernelFile)")
guard let kernelSrc = try? String(contentsOfFile: kernelPath, encoding: .utf8) else {
    fatalError("Cannot load \(kernelFile)")
}
guard let device = MTLCreateSystemDefaultDevice() else { fatalError("No Metal device") }
guard let queue = device.makeCommandQueue() else { fatalError("No queue") }
print("GPU: \(device.name)")

let lib: MTLLibrary
do { lib = try device.makeLibrary(source: kernelSrc, options: nil) }
catch { fatalError("Kernel compile failed: \(error)") }
guard let fn = lib.makeFunction(name: "verusclhash_sv2_2_kernel") else {
    fatalError("Kernel not found")
}
let ps = try! device.makeComputePipelineState(function: fn)

// VERUSKEYSIZE = 8832; we allocate 16384 for safety (cases 0x10/0x14 read
// past prand by up to 12 round keys = 192 bytes).
let KEY_BYTES = 16384
let KEYMASK: UInt64 = 8191   // = (1 << 13) - 1, what verusclhasher::keymask(8832) returns

// xorshift64* deterministic PRNG so any failure is bit-reproducible.
var rngState: UInt64 = 0
func xs64() -> UInt64 {
    rngState ^= rngState >> 12
    rngState ^= rngState &<< 25
    rngState ^= rngState >> 27
    return rngState &* 0x2545F4914F6CDD1D
}
func randBytes(_ n: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: n)
    var i = 0
    while i < n {
        let v = xs64()
        let take = min(8, n - i)
        for j in 0..<take { out[i + j] = UInt8((v >> (8 * j)) & 0xff) }
        i += take
    }
    return out
}

func runTest(label: String, keySeed: UInt64, inputSeed: UInt64) -> Bool {
    rngState = keySeed
    let masterKey = randBytes(KEY_BYTES)
    rngState = inputSeed
    let input = randBytes(64)

    // CPU pass — algo mutates key, so we copy
    var cpuKey = masterKey
    let cpuHash = cpuKey.withUnsafeMutableBufferPointer { kp in
        input.withUnsafeBufferPointer { ip in
            verusclhash_sv2_2_wrap(kp.baseAddress!, ip.baseAddress!, KEYMASK)
        }
    }

    // GPU pass — its own copy of the key
    let inBuf = input.withUnsafeBufferPointer {
        device.makeBuffer(bytes: $0.baseAddress!, length: 64, options: .storageModeShared)!
    }
    let keyBuf = masterKey.withUnsafeBufferPointer {
        device.makeBuffer(bytes: $0.baseAddress!, length: KEY_BYTES, options: .storageModeShared)!
    }
    let outBuf = device.makeBuffer(length: MemoryLayout<UInt64>.size, options: .storageModeShared)!
    let params: [UInt64] = [KEYMASK]
    let paramsBuf = params.withUnsafeBufferPointer {
        device.makeBuffer(bytes: $0.baseAddress!, length: MemoryLayout<UInt64>.size,
                          options: .storageModeShared)!
    }

    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(ps)
    enc.setBuffer(inBuf,     offset: 0, index: 0)
    enc.setBuffer(keyBuf,    offset: 0, index: 1)
    enc.setBuffer(outBuf,    offset: 0, index: 2)
    enc.setBuffer(paramsBuf, offset: 0, index: 3)
    enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    let gpuHash = outBuf.contents().bindMemory(to: UInt64.self, capacity: 1).pointee

    let ok = (cpuHash == gpuHash)
    print(String(format: "  [%@] CPU=%016llx  GPU=%016llx  %@",
                 label as NSString, cpuHash, gpuHash, ok ? "✓" : "✗"))
    return ok
}

print("\n=== verusclhash_sv2_2 end-to-end CPU↔GPU validation ===\n")
let seeds: [(String, UInt64, UInt64)] = [
    ("seed-A", 0x1111_1111_1111_1111, 0x2222_2222_2222_2222),
    ("seed-B", 0xDEAD_BEEF_CAFE_BABE, 0xFEED_FACE_BADD_CAFE),
    ("seed-C", 0x0000_0000_0000_0001, 0xFFFF_FFFF_FFFF_FFFF),
    ("seed-D", 0x9E37_79B9_7F4A_7C15, 0x0123_4567_89AB_CDEF),
    ("seed-E", 0xA5A5_A5A5_A5A5_A5A5, 0x5A5A_5A5A_5A5A_5A5A),
    ("seed-F", 0xCAFE_BEEF_DEAD_F00D, 0xBAAA_AAAD_DEAD_DEAD),
]
var passes = 0
for (n, ks, ins) in seeds {
    if runTest(label: n, keySeed: ks, inputSeed: ins) { passes += 1 }
}

print("")
if passes == seeds.count {
    print("PASS — \(passes)/\(seeds.count) verusclhash_sv2_2: GPU matches CPU on all seeds")
    exit(0)
} else {
    print("FAIL — \(passes)/\(seeds.count) passed")
    exit(1)
}
