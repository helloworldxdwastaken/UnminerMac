// verusminer/cpu — phase 1 prototype: Haraka256 portable vs NEON on M5
//
// Measures both the portable-C path and the SSE-intrinsic path (translated
// to ARM NEON via sse2neon.h, which maps onto Apple Silicon's ARMv8 AES
// hardware extensions). The delta tells us how much speed our hardware AES
// is actually delivering for Haraka.

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <chrono>

extern "C" {
#include "haraka_portable.h"
#include "haraka.h"  // NEON-via-sse2neon path
extern void load_constants(void);  // initialize round constants for haraka.c
}

static double now_seconds() {
    using namespace std::chrono;
    return duration_cast<duration<double>>(steady_clock::now().time_since_epoch()).count();
}

static void print_hex(const char* label, const uint8_t* buf, size_t n) {
    printf("%-24s ", label);
    for (size_t i = 0; i < n; i++) printf("%02x", buf[i]);
    printf("\n");
}

int main(int argc, char** argv) {
    printf("== verusminer phase 1 — Haraka256 portable vs NEON on M5 ==\n\n");

    // Round constants are needed for the NEON haraka.c path.
    load_constants();

    uint8_t in[32];
    for (int i = 0; i < 32; i++) in[i] = (uint8_t)i;

    // 1) Cross-check: both implementations should produce the same hash
    uint8_t out_portable[32], out_neon[32];
    haraka256_port(out_portable, in);
    haraka256(out_neon, in);

    print_hex("input:           ", in, 32);
    print_hex("portable output: ", out_portable, 32);
    print_hex("NEON output:     ", out_neon, 32);
    bool consistent = memcmp(out_portable, out_neon, 32) == 0;
    printf("Self-consistency:  %s\n\n", consistent ? "PASS ✓ (impls agree)" : "FAIL ✗ (mismatch!)");

    // 2) Benchmark portable path
    const long ITERS = (argc > 1 && argv[1][0] == 'q') ? 500000L : 10000000L;
    {
        uint8_t scratch[32];
        memcpy(scratch, in, 32);
        double t0 = now_seconds();
        for (long i = 0; i < ITERS; i++) haraka256_port(scratch, scratch);
        double t1 = now_seconds();
        double mhs = ITERS / (t1 - t0) / 1e6;
        printf("Portable C (lookup tables, no hardware AES):\n");
        printf("  Throughput: %.2f MH/s on 1 P-core\n", mhs);
        printf("  Time: %.3f s for %ld iterations\n\n", t1 - t0, ITERS);
    }

    // 3) Benchmark NEON path (sse2neon → ARMv8 AES instructions)
    {
        uint8_t scratch[32];
        memcpy(scratch, in, 32);
        double t0 = now_seconds();
        for (long i = 0; i < ITERS; i++) haraka256(scratch, scratch);
        double t1 = now_seconds();
        double mhs = ITERS / (t1 - t0) / 1e6;
        printf("NEON via sse2neon (hardware AES via ARMv8 crypto extensions):\n");
        printf("  Throughput: %.2f MH/s on 1 P-core\n", mhs);
        printf("  Time: %.3f s for %ld iterations\n\n", t1 - t0, ITERS);
    }

    // 4) VerusHash 2.x estimate
    //
    // VerusHash 2.2 per final hash invokes Haraka roughly 150x (plus SHA256D,
    // clhash, key generation). So the rough VerusHash hashrate is the Haraka
    // hashrate divided by ~150.
    printf("Implied VerusHash 2.2 hashrate (= Haraka NEON / 150):\n");
    {
        uint8_t scratch[32];
        memcpy(scratch, in, 32);
        double t0 = now_seconds();
        for (long i = 0; i < ITERS; i++) haraka256(scratch, scratch);
        double t1 = now_seconds();
        double haraka_mhs = ITERS / (t1 - t0) / 1e6;
        printf("  ~%.2f MH/s on 1 P-core\n", haraka_mhs / 150.0);
        printf("  ~%.2f MH/s on 4 P-cores (assumes linear scaling)\n",
               (haraka_mhs * 4.0) / 150.0);
    }
    printf("\n");
    printf("Compare to Rosetta'd verus-cli on M-series: ~1 MH/s\n");

    return consistent ? 0 : 2;
}
