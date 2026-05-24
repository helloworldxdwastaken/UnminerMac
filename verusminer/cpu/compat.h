// compat.h — minimal stubs so verus_clhash code compiles without
// VerusCoin's wallet-level dependencies (hash.h, primitives/block.h, boost, tinyformat).
#pragma once

#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <cassert>

// 256-bit integer (32 bytes). VerusCoin's uint256 has comparison/arithmetic;
// we only need equality and assignment for seed tracking.
struct uint256 {
    alignas(32) unsigned char data[32];
    uint256() { memset(data, 0, 32); }
    bool operator!=(const uint256 &o) const { return memcmp(data, o.data, 32) != 0; }
    bool operator==(const uint256 &o) const { return memcmp(data, o.data, 32) == 0; }
};

// Alias — arith_uint256 is used by mine_verus_v2_port. We don't need arithmetic.
using arith_uint256 = uint256;
static inline arith_uint256 UintToArith256(const uint256 &x) { return x; }

// thread_specific_ptr — no Boost. For a single-threaded benchmark, a simple
// pointer wrapper is sufficient. VerusHash uses thread_local storage for
// the CL hash key buffer.
struct thread_specific_ptr {
    void *ptr = nullptr;
    void reset(void *newptr = nullptr) {
        if (ptr && ptr != newptr) free(ptr);
        ptr = newptr;
    }
    void *get() { return ptr; }
    ~thread_specific_ptr() { reset(); }
};

// Allocate aligned buffer for CL hash keys
static inline void *alloc_aligned_buffer(uint64_t bufSize) {
    void *p = nullptr;
    posix_memalign(&p, 64, bufSize);
    return p;
}

// Global thread_local key storage (declared extern in verus_clhash.h)
extern thread_local thread_specific_ptr verusclhasher_key;
extern thread_local thread_specific_ptr verusclhasher_descr;
extern int __cpuverusoptimized;

// Unused but required by verus_clhash_portable.cpp includes
#define VERUSKEYSIZE (1024 * 8 + (40 * 16))
#define SOLUTION_VERUSHHASH_V2    1
#define SOLUTION_VERUSHHASH_V2_1  3
#define SOLUTION_VERUSHHASH_V2_2  4

// Minimal CBlockHeader stub — just enough for the hash builder
struct CBlockHeader {
    unsigned char data[188];  // typical Verus block header size
    int nSolution = 0;
    CBlockHeader() { memset(data, 0, sizeof(data)); }
};

// Tinyformat/strprintf stub (not used in portable path)
namespace tinyformat { }
