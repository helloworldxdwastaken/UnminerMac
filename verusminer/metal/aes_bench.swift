// Phase 4.0 — AES strategy microbenchmark for M5 GPU (minimal)
import Foundation
import Metal

guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no Metal") }
print("== Phase 4.0 — AES strategy on M5 GPU ==\n")

let queue = device.makeCommandQueue()!

// ---- Table-based kernel ----
let tableSrc = """
#include <metal_stdlib>
using namespace metal;
constant uint T0[256] = {0xc66363a5,0xf87c7c84,0xee777799,0xf67b7b8d,0xfff2f20d,0xd66b6bbd,0xde6f6fb1,0x91c5c554,0x60303050,0x02010103,0xce6767a9,0x562b2b7d,0xe7fefe19,0xb5d7d762,0x4dababe6,0xec76769a,0x8fcaca45,0x1f82829d,0x89c9c940,0xfa7d7d87,0xeffafa15,0xb25959eb,0x8e4747c9,0xfbf0f00b,0x41adadec,0xb3d4d467,0x5fa2a2fd,0x45afafea,0x239c9cbf,0x53a4a4f7,0xe4727296,0x9bc0c05b,0x75b7b7c2,0xe1fdfd1c,0x3d9393ae,0x4c26266a,0x6c36365a,0x7e3f3f41,0xf5f7f702,0x83cccc4f,0x6834345c,0x51a5a5f4,0xd1e5e534,0xf9f1f108,0xe2717193,0xabd8d873,0x62313153,0x2a15153f,0x0804040c,0x95c7c752,0x46232365,0x9dc3c35e,0x30181828,0x379696a1,0x0a05050f,0x2f9a9ab5,0x0e070709,0x24121236,0x1b80809b,0xdfe2e23d,0xcdebeb26,0x4e272769,0x7fb2b2cd,0xea75759f,0x1209091b,0x1d83839e,0x582c2c74,0x341a1a2e,0x361b1b2d,0xdc6e6eb2,0xb45a5aee,0x5ba0a0fb,0xa45252f6,0x763b3b4d,0xb7d6d661,0x7db3b3ce,0x5229297b,0xdde3e33e,0x5e2f2f71,0x13848497,0xa65353f5,0xb9d1d168,0x00000000,0xc1eded2c,0x40202060,0xe3fcfc1f,0x79b1b1c8,0xb65b5bed,0xd46a6abe,0x8dcbcb46,0x67bebed9,0x7239394b,0x944a4ade,0x984c4cd4,0xb05858e8,0x85cfcf4a,0xbbd0d06b,0xc5efef2a,0x4faaaae5,0xedfbfb16,0x864343c5,0x9a4d4dd7,0x66333355,0x11858594,0x8a4545cf,0xe9f9f910,0x04020206,0xfe7f7f81,0xa05050f0,0x783c3c44,0x259f9fba,0x4ba8a8e3,0xa25151f3,0x5da3a3fe,0x804040c0,0x058f8f8a,0x3f9292ad,0x219d9dbc,0x70383848,0xf1f5f504,0x63bcbcdf,0x77b6b6c1,0xafdada75,0x42212163,0x20101030,0xe5ffff1a,0xfdf3f30e,0xbfd2d26d,0x81cdcd4c,0x180c0c14,0x26131335,0xc3ecec2f,0xbe5f5fe1,0x359797a2,0x884444cc,0x2e171739,0x93c4c457,0x55a7a7f2,0xfc7e7e82,0x7a3d3d47,0xc86464ac,0xba5d5de7,0x3219192b,0xe6737395,0xc06060a0,0x19818198,0x9e4f4fd1,0xa3dcdc7f,0x44222266,0x542a2a7e,0x3b9090ab,0x0b888883,0x8c4646ca,0xc7eeee29,0x6bb8b8d3,0x2814143c,0xa7dede79,0xbc5e5ee2,0x160b0b1d,0xaddbdb76,0xdbe0e03b,0x64323256,0x743a3a4e,0x140a0a1e,0x924949db,0x0c06060a,0x4824246c,0xb85c5ce4,0x9fc2c25d,0xbdd3d36e,0x43acacef,0xc46262a6,0x399191a8,0x319595a4,0xd3e4e437,0xf279798b,0xd5e7e732,0x8bc8c843,0x6e373759,0xda6d6db7,0x018d8d8c,0xb1d5d564,0x9c4e4ed2,0x49a9a9e0,0xd86c6cb4,0xac5656fa,0xf3f4f407,0xcfeaea25,0xca6565af,0xf47a7a8e,0x47aeaee9,0x10080818,0x6fbabad5,0xf0787888,0x4a25256f,0x5c2e2e72,0x381c1c24,0x57a6a6f1,0x73b4b4c7,0x97c6c651,0xcbe8e823,0xa1dddd7c,0xe874749c,0x3e1f1f21,0x964b4bdd,0x61bdbddc,0x0d8b8b86,0x0f8a8a85,0xe0707090,0x7c3e3e42,0x71b5b5c4,0xcc6666aa,0x904848d8,0x06030305,0xf7f6f601,0x1c0e0e12,0xc26161a3,0x6a35355f,0xae5757f9,0x69b9b9d0,0x17868691,0x99c1c158,0x3a1d1d27,0x279e9eb9,0xd9e1e138,0xebf8f813,0x2b9898b3,0x22111133,0xd26969bb,0xa9d9d970,0x078e8e89,0x339494a7,0x2d9b9bb6,0x3c1e1e22,0x15878792,0xc9e9e920,0x87cece49,0xaa5555ff,0x50282878,0xa5dfdf7a,0x038c8c8f,0x59a1a1f8,0x09898980,0x1a0d0d17,0x65bfbfda,0xd7e6e631,0x844242c6,0xd06868b8,0x824141c3,0x299999b0,0x5a2d2d77,0x1e0f0f11,0x7bb0b0cb,0xa85454fc,0x6dbbbbd6,0x2c16163a};
kernel void table_aes_rounds(device uchar *states [[buffer(0)]], constant uint &num_rounds [[buffer(1)]], device atomic_uint *count [[buffer(2)]], uint gid [[thread_position_in_grid]]) {
    uint b=gid*16;
    uchar s0=states[b+0],s1=states[b+1],s2=states[b+2],s3=states[b+3],s4=states[b+4],s5=states[b+5],s6=states[b+6],s7=states[b+7],s8=states[b+8],s9=states[b+9],s10=states[b+10],s11=states[b+11],s12=states[b+12],s13=states[b+13],s14=states[b+14],s15=states[b+15];
    for(uint r=0;r<num_rounds;r++){
        uint c0=T0[s0]^(T0[s5]>>8)^(T0[s10]>>16)^(T0[s15]>>24),c1=T0[s4]^(T0[s9]>>8)^(T0[s14]>>16)^(T0[s3]>>24),c2=T0[s8]^(T0[s13]>>8)^(T0[s2]>>16)^(T0[s7]>>24),c3=T0[s12]^(T0[s1]>>8)^(T0[s6]>>16)^(T0[s11]>>24);
        s0=(c0&0xff)^s0;s1=((c0>>8)&0xff)^s1;s2=((c0>>16)&0xff)^s2;s3=((c0>>24)&0xff)^s3;
        s4=(c1&0xff)^s4;s5=((c1>>8)&0xff)^s5;s6=((c1>>16)&0xff)^s6;s7=((c1>>24)&0xff)^s7;
        s8=(c2&0xff)^s8;s9=((c2>>8)&0xff)^s9;s10=((c2>>16)&0xff)^s10;s11=((c2>>24)&0xff)^s11;
        s12=(c3&0xff)^s12;s13=((c3>>8)&0xff)^s13;s14=((c3>>16)&0xff)^s14;s15=((c3>>24)&0xff)^s15;
    }
    states[b+0]=s0;states[b+1]=s1;states[b+2]=s2;states[b+3]=s3;states[b+4]=s4;states[b+5]=s5;states[b+6]=s6;states[b+7]=s7;states[b+8]=s8;states[b+9]=s9;states[b+10]=s10;states[b+11]=s11;states[b+12]=s12;states[b+13]=s13;states[b+14]=s14;states[b+15]=s15;
    atomic_fetch_add_explicit(count, num_rounds, memory_order_relaxed);
}
"""

// ---- Bit-sliced kernel (pure ALU, no memory lookups) ----
let bitSliceSrc = """
#include <metal_stdlib>
using namespace metal;
kernel void bitslice_aes_rounds(device uint4 *states [[buffer(0)]], constant uint &num_rounds [[buffer(1)]], device atomic_uint *count [[buffer(2)]], uint gid [[thread_position_in_grid]]) {
    uint base=gid*8;
    uint4 r0=states[base],r1=states[base+1],r2=states[base+2],r3=states[base+3],r4=states[base+4],r5=states[base+5],r6=states[base+6],r7=states[base+7];
    for(uint round=0;round<num_rounds;round++){
        uint4 U0=r0^r4^r6,U1=r1^r5,U2=r2^r6^r7,U3=r3,U4=r0^r4,U5=r1^r5^r7,U6=r2,U7=r3^r7;
        uint4 T0=U0&U4,T1=U1&U5,T2=U2&U6,T3=U3&U7;
        uint4 V0=U0^T0,V1=U1^T1,V2=U2^T2,V3=U3^T3;
        uint4 T4=V0&V3,T5=V1&V2;
        r0=V0^T4^U4^U6;r1=V1^T5^U5;
        r2=V2^T5^U6^U7;r3=V3^T4^U7;
        r4=U0^T0^U7;r5=U1^T1^U5^U6^U7;
        r6=U2^T2^U6;r7=U3^T3;
    }
    states[base]=r0;states[base+1]=r1;states[base+2]=r2;states[base+3]=r3;states[base+4]=r4;states[base+5]=r5;states[base+6]=r6;states[base+7]=r7;
    atomic_fetch_add_explicit(count, num_rounds*8, memory_order_relaxed);
}
"""

// ---- Run benchmark ----
func runBench(name: String, lib: MTLLibrary, fnName: String, blockMultiplier: Int, stateBytesPerThread: Int, numThreads: Int, numRounds: UInt32) -> Double {
    let fn = lib.makeFunction(name: fnName)!
    let ps = try! device.makeComputePipelineState(function: fn)
    let stateBuf = device.makeBuffer(length: numThreads * stateBytesPerThread, options: .storageModeShared)!
    let countBuf = device.makeBuffer(length: 4, options: .storageModeShared)!

    var bufPtr = stateBuf.contents().bindMemory(to: UInt32.self, capacity: numThreads * stateBytesPerThread / 4)
    for i in 0..<(numThreads * stateBytesPerThread / 4) { bufPtr[i] = UInt32(i) }

    memset(countBuf.contents(), 0, 4)
    var r = numRounds

    let cmdBuf = queue.makeCommandBuffer()!
    let enc = cmdBuf.makeComputeCommandEncoder()!
    enc.setComputePipelineState(ps)
    enc.setBuffer(stateBuf, offset: 0, index: 0)
    enc.setBytes(&r, length: 4, index: 1)
    enc.setBuffer(countBuf, offset: 0, index: 2)

    let tgSize = min(256, ps.maxTotalThreadsPerThreadgroup)
    enc.dispatchThreads(MTLSize(width: numThreads, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: tgSize, height: 1, depth: 1))
    enc.endEncoding()

    let t0 = Date()
    cmdBuf.commit()
    cmdBuf.waitUntilCompleted()
    let elapsed = Date().timeIntervalSince(t0)

    let totalOps = Double(numThreads) * Double(numRounds) * Double(blockMultiplier)
    let mrps = totalOps / elapsed / 1e6
    print(String(format: "  %@: %8d threads × %4d rounds × %d blocks = %8.2f M rounds/sec (%6.2f ms)",
                 name, numThreads, numRounds, blockMultiplier, mrps, elapsed * 1000))
    return mrps
}

// Compile both libraries
let tableLib = try! device.makeLibrary(source: tableSrc, options: nil)
let bsLib = try! device.makeLibrary(source: bitSliceSrc, options: nil)

print("--- Table-based AES (T-table lookups, 16 bytes state/thread) ---")
for threads in [4096, 16384, 65536, 262144] {
    _ = runBench(name: "TABLE", lib: tableLib, fnName: "table_aes_rounds",
                 blockMultiplier: 1, stateBytesPerThread: 16,
                 numThreads: threads, numRounds: 1000)
}

print("")
print("--- Bit-sliced AES (pure ALU, 8 blocks × 128-bit registers/thread) ---")
for threads in [1024, 4096, 16384, 65536] {
    _ = runBench(name: "BSLICE", lib: bsLib, fnName: "bitslice_aes_rounds",
                 blockMultiplier: 8, stateBytesPerThread: 128,
                 numThreads: threads, numRounds: 200)
}

print("")
print("--- CPU baseline ---")
print("  CPU NEON (1 P-core, hw AES):  ~2,625 M AES rounds/sec")
print("  CPU NEON (10 cores total):    ~16,642 M AES rounds/sec")
print("")
print("Decision gate: GPU must exceed 5× single-core CPU = 13,125 M AES rounds/sec")
print("(Measures raw AES throughput — actual mining adds CL hash + key gen overhead)")
