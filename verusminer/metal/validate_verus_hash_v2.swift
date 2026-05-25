// validate_verus_hash_v2.swift — end-to-end CPU↔GPU diff of CVerusHashV2
// (Reset + Write + Finalize2b). This is the FULL hash mining uses, not just
// the verusclhash piece. If this passes, the GPU produces shareable hashes.
//
// Compile:
//   cd verusminer/metal
//   clang++ -c -std=c++17 -O2 -I../cpu/canonical -I../cpu \
//       ../cpu/canonical/clmul_shim.cpp -o ../cpu/canonical/clmul_shim.o
//   swiftc -O validate_verus_hash_v2.swift -o validate_verus_hash_v2 \
//       -framework Metal -framework Foundation \
//       ../cpu/canonical/clmul_shim.o \
//       ../cpu/canonical/verus_hash.o \
//       ../cpu/canonical/verus_clhash.o \
//       ../cpu/canonical/verus_clhash_portable.o \
//       ../cpu/haraka_portable.o ../cpu/haraka.o \
//       -Xlinker -lc++ -Xlinker -lm

import Foundation
import Metal

@_silgen_name("verus_hash_v2_2b_wrap")
func verus_hash_v2_2b_wrap(_ out: UnsafeMutablePointer<UInt8>,
                           _ data: UnsafePointer<UInt8>,
                           _ len: UInt64)

@_silgen_name("verus_hash_v2_2b_wrap_traced")
func verus_hash_v2_2b_wrap_traced(_ out: UnsafeMutablePointer<UInt8>,
                                  _ data: UnsafePointer<UInt8>,
                                  _ len: UInt64,
                                  _ trace: UnsafeMutablePointer<UInt8>)

let kernelFile = "verus_hash_v2.metal"
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
guard let fn = lib.makeFunction(name: "verus_hash_v2_kernel") else {
    fatalError("Kernel not found")
}
let ps = try! device.makeComputePipelineState(function: fn)

let KEY_SCRATCH: Int = 24576

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
func hex(_ b: [UInt8]) -> String {
    return b.map { String(format: "%02x", $0) }.joined()
}

func runTest(label: String, seed: UInt64, len: Int, traced: Bool = false) -> Bool {
    rngState = seed
    let input = randBytes(len)

    // CPU
    var cpuHash = [UInt8](repeating: 0, count: 32)
    var cpuTrace = [UInt8](repeating: 0, count: 256)
    if traced {
        input.withUnsafeBufferPointer { ip in
            cpuHash.withUnsafeMutableBufferPointer { op in
                cpuTrace.withUnsafeMutableBufferPointer { tp in
                    verus_hash_v2_2b_wrap_traced(op.baseAddress!, ip.baseAddress!,
                                                 UInt64(len), tp.baseAddress!)
                }
            }
        }
    } else {
        input.withUnsafeBufferPointer { ip in
            cpuHash.withUnsafeMutableBufferPointer { op in
                verus_hash_v2_2b_wrap(op.baseAddress!, ip.baseAddress!, UInt64(len))
            }
        }
    }

    // GPU
    let inBuf = input.withUnsafeBufferPointer {
        device.makeBuffer(bytes: $0.baseAddress!, length: len, options: .storageModeShared)!
    }
    let keyBuf = device.makeBuffer(length: KEY_SCRATCH, options: .storageModeShared)!
    let outBuf = device.makeBuffer(length: 32, options: .storageModeShared)!
    let params: [UInt64] = [UInt64(len), traced ? 1 : 0]
    let paramsBuf = params.withUnsafeBufferPointer {
        device.makeBuffer(bytes: $0.baseAddress!, length: MemoryLayout<UInt64>.size * 2,
                          options: .storageModeShared)!
    }
    let traceBuf = device.makeBuffer(length: 256, options: .storageModeShared)!
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(ps)
    enc.setBuffer(inBuf,     offset: 0, index: 0)
    enc.setBuffer(keyBuf,    offset: 0, index: 1)
    enc.setBuffer(outBuf,    offset: 0, index: 2)
    enc.setBuffer(paramsBuf, offset: 0, index: 3)
    enc.setBuffer(traceBuf,  offset: 0, index: 4)
    enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    let gpuPtr = outBuf.contents().bindMemory(to: UInt8.self, capacity: 32)
    let gpuHash = Array(UnsafeBufferPointer(start: gpuPtr, count: 32))
    let gpuTracePtr = traceBuf.contents().bindMemory(to: UInt8.self, capacity: 256)
    let gpuTrace = Array(UnsafeBufferPointer(start: gpuTracePtr, count: 256))

    let ok = (cpuHash == gpuHash)
    print(String(format: "  [%@ len=%d] CPU=%@  GPU=%@  %@",
                 label as NSString, len, hex(cpuHash), hex(gpuHash), ok ? "✓" : "✗"))
    if traced && !ok {
        let cpuCB = Array(cpuTrace[0..<32])
        let gpuCB = Array(gpuTrace[0..<32])
        let cpuKey0 = Array(cpuTrace[64..<96])
        let gpuKey0 = Array(gpuTrace[64..<96])
        let cpuKeyN = Array(cpuTrace[96..<128])    // last 32 bytes of key
        let gpuKeyN = Array(gpuTrace[96..<128])
        let cpuInt = Array(cpuTrace[160..<168])
        let gpuInt = Array(gpuTrace[160..<168])
        let cpuFinalCB = Array(cpuTrace[168..<232])
        let gpuFinalCB = Array(gpuTrace[168..<232])
        print("    curPos:        CPU=\(cpuTrace[240]) GPU=\(gpuTrace[240])  (len%32=\(len % 32))")
        print("    curBuf[0..32]: \(cpuCB == gpuCB ? "✓" : "✗")  CPU=\(hex(cpuCB))")
        print("                                   GPU=\(hex(gpuCB))")
        print("    key[0..32]:    \(cpuKey0 == gpuKey0 ? "✓" : "✗")  CPU=\(hex(cpuKey0))")
        print("                                   GPU=\(hex(gpuKey0))")
        print("    key[8800..]:   \(cpuKeyN == gpuKeyN ? "✓" : "✗")  CPU=\(hex(cpuKeyN))")
        print("                                   GPU=\(hex(gpuKeyN))")
        let portInt = Array(cpuTrace[200..<208])
        let cfInt = Array(cpuTrace[232..<240])
        let cfHashMatch = cpuTrace[241] == 1
        print("    intermediate (Finalize2b):    \(cpuInt == gpuInt ? "✓" : "✗")  \(hex(cpuInt))")
        print("    intermediate (custom_finalize): \(cfInt == cpuInt ? "✓ matches Finalize2b" : "✗ DIFFERS from Finalize2b — custom buggy")  \(hex(cfInt))  (faithful: \(cfHashMatch))")
        print("    intermediate (portable):      \(portInt == gpuInt ? "✓ matches GPU" : "✗")  \(hex(portInt))")
        print("    intermediate (GPU):                       \(hex(gpuInt))")
        print("    pre-verusclhash curBuf[0..32]:   \(Array(cpuFinalCB.prefix(32)) == Array(gpuFinalCB.prefix(32)) ? "✓" : "✗")")
        print("       CPU=\(hex(Array(cpuFinalCB.prefix(32))))")
        print("       GPU=\(hex(Array(gpuFinalCB.prefix(32))))")
        let cpuTail = Array(cpuFinalCB[32..<64])
        let gpuTail = Array(gpuFinalCB[32..<64])
        print("    pre-verusclhash curBuf[32..64]:  \(cpuTail == gpuTail ? "✓" : "✗")")
        print("       CPU=\(hex(cpuTail))")
        print("       GPU=\(hex(gpuTail))")
    }
    return ok
}

print("\n=== CVerusHashV2 (Reset+Write+Finalize2b) — GPU vs CPU ===\n")
let tests: [(String, UInt64, Int)] = [
    ("seed-A-32",   0x1111_1111_1111_1111, 32),    // single haraka512 chunk
    ("seed-A-64",   0x1111_1111_1111_1111, 64),    // 2 chunks exactly
    ("seed-A-100",  0x1111_1111_1111_1111, 100),   // 3 chunks + partial
    ("seed-B-299",  0xDEAD_BEEF_CAFE_BABE, 299),   // typical Verus block buffer
    ("seed-C-512",  0x9E37_79B9_7F4A_7C15, 512),   // larger
    ("seed-D-1",    0xCAFE_BEEF_DEAD_F00D, 1),     // partial single byte
]
var passes = 0
for (n, s, l) in tests {
    if runTest(label: n, seed: s, len: l, traced: true) { passes += 1 }
}
print("")
if passes == tests.count {
    print("PASS — \(passes)/\(tests.count) GPU verus_hash_v2 == CPU")
    exit(0)
} else {
    print("FAIL — \(passes)/\(tests.count)")
    exit(1)
}
