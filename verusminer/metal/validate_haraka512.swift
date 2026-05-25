// validate_haraka512.swift — compute haraka512 on GPU + CPU for the same
// input, byte-diff. CPU reference is haraka_portable.c's `haraka512_port`,
// linked via the same .o files validate_haraka256 uses.
//
// Compile:
//   cd verusminer/metal
//   swiftc -O validate_haraka512.swift -o validate_haraka512 \
//       -framework Metal -framework Foundation \
//       ../cpu/haraka_portable.o ../cpu/haraka.o \
//       -Xlinker -lm
// Run:
//   ./validate_haraka512

import Foundation
import Metal

// ---- CPU reference: haraka_portable.c's haraka512_port ----
@_silgen_name("haraka512_port")
func haraka512_port(_ out: UnsafeMutablePointer<UInt8>,
                    _ inp: UnsafePointer<UInt8>)

@_silgen_name("load_constants_port")
func load_constants_port()

// ---- GPU dispatch ----
let kernelFile = "haraka512_v2.metal"
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
guard let fn = lib.makeFunction(name: "haraka512_kernel") else { fatalError("Kernel not found") }
let ps = try! device.makeComputePipelineState(function: fn)

// ---- Test vectors ----
// Canonical Haraka v2 test vector from haraka.c testvector512:
//   input  = 0x00, 0x01, ..., 0x3f (64 bytes counting up)
//   output = 0xbe, 0x7f, 0x72, 0x3b, ...
let inputs: [[UInt8]] = [
    (0..<64).map { UInt8($0) },                                  // canonical counting-up
    Array(repeating: UInt8(0), count: 64),                       // all zeros
    Array(repeating: UInt8(0xff), count: 64),                    // all ones — stresses GF MixColumns
    (0..<64).map { UInt8(($0 * 31 + 7) & 0xff) },                // pseudo-random pattern
]

load_constants_port()

func runCPU(_ inp: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 32)
    inp.withUnsafeBufferPointer { ip in
        out.withUnsafeMutableBufferPointer { op in
            haraka512_port(op.baseAddress!, ip.baseAddress!)
        }
    }
    return out
}

func runGPU(_ inp: [UInt8]) -> [UInt8] {
    let inBuf  = device.makeBuffer(bytes: inp,
                                   length: 64,
                                   options: .storageModeShared)!
    let outBuf = device.makeBuffer(length: 32, options: .storageModeShared)!
    let cnt    = device.makeBuffer(length: MemoryLayout<UInt32>.size,
                                   options: .storageModeShared)!
    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeComputeCommandEncoder()!
    enc.setComputePipelineState(ps)
    enc.setBuffer(inBuf,  offset: 0, index: 0)
    enc.setBuffer(outBuf, offset: 0, index: 1)
    enc.setBuffer(cnt,    offset: 0, index: 2)
    enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    let ptr = outBuf.contents().bindMemory(to: UInt8.self, capacity: 32)
    return Array(UnsafeBufferPointer(start: ptr, count: 32))
}

func hex(_ b: [UInt8]) -> String {
    return b.map { String(format: "%02x", $0) }.joined()
}

// Known-good for vector 0 — direct from haraka.c testvector512.
let expectedCountup: [UInt8] = [
    0xbe, 0x7f, 0x72, 0x3b, 0x4e, 0x80, 0xa9, 0x98,
    0x13, 0xb2, 0x92, 0x28, 0x7f, 0x30, 0x6f, 0x62,
    0x5a, 0x6d, 0x57, 0x33, 0x1c, 0xae, 0x5f, 0x34,
    0xdd, 0x92, 0x77, 0xb0, 0x94, 0x5b, 0xe2, 0xaa,
]

var anyFail = false
for (i, inp) in inputs.enumerated() {
    let cpu = runCPU(inp)
    let gpu = runGPU(inp)
    let ok = cpu == gpu
    let label = ["countup", "zeros", "ones", "pattern"][i]
    print("[\(label)] input(\(inp.count)B): \(hex(Array(inp.prefix(16))))…")
    print("  CPU: \(hex(cpu))")
    print("  GPU: \(hex(gpu))")
    print("  \(ok ? "✓ MATCH" : "✗ MISMATCH")")
    if i == 0 {
        let goldenOK = cpu == expectedCountup
        print("  vs paper vector: \(goldenOK ? "✓ MATCH" : "✗ CPU REF DIVERGES — \(hex(expectedCountup))")")
        if !goldenOK { anyFail = true }
    }
    if !ok { anyFail = true }
}

print("")
print(anyFail ? "FAIL — GPU haraka512 still has a bug" : "PASS — GPU haraka512 matches CPU on all vectors")
exit(anyFail ? 1 : 0)
