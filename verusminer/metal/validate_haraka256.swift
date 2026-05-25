// validate_haraka256.swift — compute haraka256 on GPU + CPU for the same
// input, byte-diff. CPU reference comes from the cpu/haraka_portable.c
// binary linked at the bottom (via dlopen). If they match, the GPU kernel
// is correct.
//
// Compile:
//   cd verusminer/metal
//   swiftc -O validate_haraka256.swift -o validate_haraka256 \
//       -framework Metal -framework Foundation \
//       ../cpu/haraka_portable.o ../cpu/haraka.o \
//       -Xlinker -lm
// Run:
//   ./validate_haraka256

import Foundation
import Metal

// ---- CPU reference: link haraka_portable.c's `haraka256_port` ----
@_silgen_name("haraka256_port")
func haraka256_port(_ out: UnsafeMutablePointer<UInt8>,
                    _ inp: UnsafePointer<UInt8>)

@_silgen_name("load_constants_port")
func load_constants_port()

// ---- GPU dispatch ----
// Swap to the v2 file by passing argv[1]="v2" — defaults to original
let kernelFile = (CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "v2")
    ? "haraka256_v2.metal" : "haraka256.metal"
let kernelPath = FileManager.default.currentDirectoryPath + "/" + kernelFile
print("Loading kernel: \(kernelFile)")
guard let kernelSrc = try? String(contentsOfFile: kernelPath, encoding: .utf8) else {
    fatalError("Cannot load haraka256.metal from cwd")
}
guard let device = MTLCreateSystemDefaultDevice() else { fatalError("No Metal device") }
guard let queue = device.makeCommandQueue() else { fatalError("No queue") }
print("GPU: \(device.name)")

let lib: MTLLibrary
do { lib = try device.makeLibrary(source: kernelSrc, options: nil) }
catch { fatalError("Kernel compile failed: \(error)") }
guard let fn = lib.makeFunction(name: "haraka256_kernel") else { fatalError("Kernel not found") }
let ps = try! device.makeComputePipelineState(function: fn)

// ---- Test vectors ----
// Standard Haraka v2 test vector from the paper:
//   input  = 0x00, 0x01, 0x02, ..., 0x1f (32 bytes counting up)
//   output = 0x80, 0x27, 0xcc, 0xb8, ... (per haraka.c testvector256)
let inputs: [[UInt8]] = [
    (0..<32).map { UInt8($0) },                                  // counting-up test vector
    Array(repeating: UInt8(0), count: 32),                       // all zeros
    Array(repeating: UInt8(0xff), count: 32),                    // all ones (stresses GF MixColumns)
    (0..<32).map { UInt8(($0 * 17 + 3) & 0xff) },                // pseudo-random pattern
]

load_constants_port()

func runCPU(_ inp: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 32)
    inp.withUnsafeBufferPointer { ip in
        out.withUnsafeMutableBufferPointer { op in
            haraka256_port(op.baseAddress!, ip.baseAddress!)
        }
    }
    return out
}

func runGPU(_ inp: [UInt8]) -> [UInt8] {
    let inBuf  = device.makeBuffer(bytes: inp,
                                   length: 32,
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

var anyFail = false
for (i, inp) in inputs.enumerated() {
    let cpu = runCPU(inp)
    let gpu = runGPU(inp)
    let ok = cpu == gpu
    let label = ["countup", "zeros", "ones", "pattern"][i]
    print("[\(label)] input: \(hex(inp))")
    print("  CPU: \(hex(cpu))")
    print("  GPU: \(hex(gpu))")
    print("  \(ok ? "✓ MATCH" : "✗ MISMATCH")")
    if !ok { anyFail = true }
}

print("")
print(anyFail ? "FAIL — GPU haraka256 still has a bug" : "PASS — GPU haraka256 matches CPU on all vectors")
exit(anyFail ? 1 : 0)
