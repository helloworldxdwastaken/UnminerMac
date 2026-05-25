// metal_bridge.mm — Objective-C++ bridge between the C++ miner and the
// Metal mining kernel in verus_hash_v2.metal. Exposes a C-compatible API
// so main.cpp can dispatch GPU batches without dragging in Foundation.
//
// Build (added to Makefile):
//   clang++ -std=c++17 -ObjC++ -fobjc-arc -c metal_bridge.mm -o metal_bridge.o
//   link with `-framework Metal -framework Foundation`
//
// Threading: caller must call gpu_mine_init() once at startup. Then any
// thread can call gpu_mine_dispatch(). Internally we serialize on a single
// command queue — each dispatch waits for its previous one to complete
// before submitting the next. Cheap; mining batches are large enough that
// queue overhead is irrelevant.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdint.h>
#include <string.h>
#include <stdio.h>

extern "C" {

// Per-thread key scratch (must match constant in verus_hash_v2.metal)
static const uint32_t MINE_KEY_SCRATCH_PER_THREAD = 24576;
static const uint32_t MINE_MAX_FOUND = 64;

static id<MTLDevice>              g_device      = nil;
static id<MTLCommandQueue>        g_queue       = nil;
static id<MTLComputePipelineState> g_pipeline   = nil;
static id<MTLBuffer>              g_input_buf   = nil;
static id<MTLBuffer>              g_key_buf     = nil;
static id<MTLBuffer>              g_target_buf  = nil;
static id<MTLBuffer>              g_params_buf  = nil;
static id<MTLBuffer>              g_found_count = nil;
static id<MTLBuffer>              g_found_nonces= nil;
static id<MTLBuffer>              g_found_hashes= nil;
static uint32_t                   g_batch_size  = 0;

// Initialize Metal. kernel_metal_path is the absolute path to
// verus_hash_v2.metal — the kernel source compiles at startup.
// batch_size is how many threads (= nonces) per dispatch. Reasonable
// values: 4096 .. 65536. Larger = better throughput, more memory.
//
// Returns 0 on success, -1 on failure.
int gpu_mine_init(const char *kernel_metal_path, uint32_t batch_size) {
    @autoreleasepool {
        if (g_device != nil) return 0;   // already initialized

        g_device = MTLCreateSystemDefaultDevice();
        if (g_device == nil) {
            fprintf(stderr, "[gpu] no Metal device\n");
            return -1;
        }
        g_queue = [g_device newCommandQueue];

        NSError *err = nil;
        NSString *path = [NSString stringWithUTF8String:kernel_metal_path];
        NSString *src = [NSString stringWithContentsOfFile:path
                                              encoding:NSUTF8StringEncoding
                                                 error:&err];
        if (src == nil) {
            fprintf(stderr, "[gpu] failed to load kernel from %s: %s\n",
                    kernel_metal_path, err.localizedDescription.UTF8String);
            return -1;
        }
        id<MTLLibrary> lib = [g_device newLibraryWithSource:src
                                                    options:nil
                                                      error:&err];
        if (lib == nil) {
            fprintf(stderr, "[gpu] kernel compile failed: %s\n",
                    err.localizedDescription.UTF8String);
            return -1;
        }
        id<MTLFunction> fn = [lib newFunctionWithName:@"verus_mine_kernel"];
        if (fn == nil) {
            fprintf(stderr, "[gpu] verus_mine_kernel not found in kernel source\n");
            return -1;
        }
        g_pipeline = [g_device newComputePipelineStateWithFunction:fn error:&err];
        if (g_pipeline == nil) {
            fprintf(stderr, "[gpu] pipeline creation failed: %s\n",
                    err.localizedDescription.UTF8String);
            return -1;
        }

        // Allocate persistent buffers
        g_batch_size = batch_size;
        // Verus scratch is ~1487 bytes worst case (140 header + 1347 max-soln).
        // Allocate 2048 for headroom.
        g_input_buf  = [g_device newBufferWithLength:2048
                                            options:MTLResourceStorageModeShared];
        g_key_buf    = [g_device newBufferWithLength:(NSUInteger)batch_size * MINE_KEY_SCRATCH_PER_THREAD
                                            options:MTLResourceStorageModeShared];
        g_target_buf = [g_device newBufferWithLength:32
                                            options:MTLResourceStorageModeShared];
        g_params_buf = [g_device newBufferWithLength:sizeof(uint64_t) * 5
                                            options:MTLResourceStorageModeShared];
        g_found_count  = [g_device newBufferWithLength:sizeof(uint32_t)
                                              options:MTLResourceStorageModeShared];
        g_found_nonces = [g_device newBufferWithLength:sizeof(uint64_t) * MINE_MAX_FOUND
                                              options:MTLResourceStorageModeShared];
        g_found_hashes = [g_device newBufferWithLength:32 * MINE_MAX_FOUND
                                              options:MTLResourceStorageModeShared];

        fprintf(stderr, "[gpu] %s initialized, batch_size=%u, key buf=%.1f MB\n",
                g_device.name.UTF8String, batch_size,
                ((double)batch_size * MINE_KEY_SCRATCH_PER_THREAD) / (1024*1024));
        return 0;
    }
}

// Dispatch one batch. Each of batch_size threads gets nonce = base_nonce + gid
// and computes the full VerusHash 2.2. Winners (hash < target) are written to
// out_nonces / out_hashes. Returns # winners (clamped to MINE_MAX_FOUND).
// Returns -1 on error.
int gpu_mine_dispatch(
    const uint8_t *input_template,
    uint32_t       input_len,
    uint32_t       body_tail_off,
    const uint8_t *target,
    uint64_t       base_nonce,
    uint64_t      *out_nonces,
    uint8_t       *out_hashes)
{
    if (g_pipeline == nil) {
        fprintf(stderr, "[gpu] not initialized\n");
        return -1;
    }
    if (input_len > 2048) {
        fprintf(stderr, "[gpu] input too large: %u (max 2048)\n", input_len);
        return -1;
    }

    @autoreleasepool {
        // Stage inputs
        memcpy(g_input_buf.contents, input_template, input_len);
        memcpy(g_target_buf.contents, target, 32);
        uint64_t *params = (uint64_t *)g_params_buf.contents;
        params[0] = input_len;
        params[1] = body_tail_off;
        params[2] = base_nonce;
        params[3] = 0;
        params[4] = MINE_MAX_FOUND;

        // Reset found_count atomic
        *((uint32_t *)g_found_count.contents) = 0;

        id<MTLCommandBuffer> cb = [g_queue commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:g_pipeline];
        [enc setBuffer:g_input_buf    offset:0 atIndex:0];
        [enc setBuffer:g_key_buf      offset:0 atIndex:1];
        [enc setBuffer:g_target_buf   offset:0 atIndex:2];
        [enc setBuffer:g_params_buf   offset:0 atIndex:3];
        [enc setBuffer:g_found_count  offset:0 atIndex:4];
        [enc setBuffer:g_found_nonces offset:0 atIndex:5];
        [enc setBuffer:g_found_hashes offset:0 atIndex:6];

        // Threadgroup sizing: max per-threadgroup or fewer if pipeline says so
        NSUInteger tpg = g_pipeline.maxTotalThreadsPerThreadgroup;
        if (tpg > 256) tpg = 256;   // reasonable cap for Apple GPUs
        if (tpg > g_batch_size) tpg = g_batch_size;
        [enc dispatchThreads:MTLSizeMake(g_batch_size, 1, 1)
       threadsPerThreadgroup:MTLSizeMake(tpg, 1, 1)];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];

        uint32_t found = *((uint32_t *)g_found_count.contents);
        if (found > MINE_MAX_FOUND) found = MINE_MAX_FOUND;
        memcpy(out_nonces, g_found_nonces.contents, found * sizeof(uint64_t));
        memcpy(out_hashes, g_found_hashes.contents, found * 32);
        return (int)found;
    }
}

void gpu_mine_shutdown(void) {
    g_device = nil; g_queue = nil; g_pipeline = nil;
    g_input_buf = nil; g_key_buf = nil; g_target_buf = nil; g_params_buf = nil;
    g_found_count = nil; g_found_nonces = nil; g_found_hashes = nil;
}

uint32_t gpu_mine_batch_size(void) { return g_batch_size; }

} // extern "C"
