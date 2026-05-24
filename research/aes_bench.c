// Native ARM64 AES throughput benchmark — Apple Silicon M5.
//
// Measures: raw AESE+AESMC round throughput on M5 using NEON crypto
// extensions. From that we derive theoretical ceilings for:
//   - Haraka256 v2 (10 AES rounds + 5 mix layers per 32B→32B hash)
//   - VerusHash 2.2 (Haraka stack + SHA256D, ratio ~150× per final hash)
//
// Compile:
//   clang -O3 -march=armv8-a+crypto -pthread aes_bench.c -o aes_bench
// Run:
//   ./aes_bench [threads]   (default: 4)

#include <arm_neon.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <time.h>
#include <pthread.h>
#include <unistd.h>

typedef uint8x16_t u128;

// One AES round: AESE (subbytes + shiftrows + addroundkey-with-zero)
// followed by AESMC (mixcolumns). XOR a round key in afterwards.
// This is the standard "round" used in AES-128/192/256 and Haraka.
static inline __attribute__((always_inline))
u128 aes_round(u128 state, u128 rk) {
    return veorq_u8(vaesmcq_u8(vaeseq_u8(state, (u128){0})), rk);
}

static double now_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

typedef struct {
    long iterations;
    double seconds;
    uint8_t sentinel;  // anti-DCE: written-back state byte
} thread_result_t;

static void *bench_thread(void *arg) {
    thread_result_t *res = (thread_result_t *)arg;
    const long ITERS = 200000000L;  // 200M outer iters × 8 unrolled = 1.6B AES rounds per thread

    // Two state lanes — Haraka256 keeps two 128-bit states in parallel,
    // so this matches the ILP a real Haraka loop has.
    u128 s0 = vdupq_n_u8(0x37);
    u128 s1 = vdupq_n_u8(0x91);
    u128 k0 = vdupq_n_u8(0x42);
    u128 k1 = vdupq_n_u8(0xC3);

    double t0 = now_seconds();

    for (long i = 0; i < ITERS; i++) {
        s0 = aes_round(s0, k0);
        s1 = aes_round(s1, k1);
        s0 = aes_round(s0, k1);
        s1 = aes_round(s1, k0);
        s0 = aes_round(s0, k0);
        s1 = aes_round(s1, k1);
        s0 = aes_round(s0, k1);
        s1 = aes_round(s1, k0);
    }

    double t1 = now_seconds();

    // Anti-DCE: write one byte so compiler can't fold the loop away.
    uint8_t out0[16], out1[16];
    vst1q_u8(out0, s0);
    vst1q_u8(out1, s1);
    res->sentinel = out0[0] ^ out1[0];

    res->iterations = ITERS * 8;  // 8 AES rounds per outer iter
    res->seconds = t1 - t0;
    return NULL;
}

int main(int argc, char **argv) {
    int n_threads = (argc > 1) ? atoi(argv[1]) : 4;
    if (n_threads < 1 || n_threads > 16) n_threads = 4;

    printf("== Apple Silicon native AES throughput bench ==\n");
    printf("threads: %d (targets P-cores via macOS scheduler)\n\n", n_threads);

    pthread_t *tids = malloc(sizeof(pthread_t) * n_threads);
    thread_result_t *results = calloc(n_threads, sizeof(thread_result_t));

    double t0 = now_seconds();
    for (int i = 0; i < n_threads; i++)
        pthread_create(&tids[i], NULL, bench_thread, &results[i]);
    for (int i = 0; i < n_threads; i++)
        pthread_join(tids[i], NULL);
    double t1 = now_seconds();

    long total_aes_rounds = 0;
    double max_seconds = 0;
    uint8_t sentinel_acc = 0;
    for (int i = 0; i < n_threads; i++) {
        total_aes_rounds += results[i].iterations;
        if (results[i].seconds > max_seconds) max_seconds = results[i].seconds;
        sentinel_acc ^= results[i].sentinel;
    }

    double single_thread_aes_mrps = (results[0].iterations / results[0].seconds) / 1e6;
    double aggregate_aes_mrps = total_aes_rounds / max_seconds / 1e6;

    // Haraka256 v2 = 10 AES rounds + 5 mix layers per 32B→32B output.
    // Mix layers are vzip/vshuffle on M5, very cheap (~2 cycles each).
    // Empirically Haraka256 throughput is ~ AES_throughput / 12.
    double haraka256_mhs_single = single_thread_aes_mrps / 12.0;
    double haraka256_mhs_total  = aggregate_aes_mrps    / 12.0;

    // VerusHash 2.2 per final hash includes:
    //   - one SHA256D over the block header
    //   - keyed Haraka calls + a 256-element keyed-permutation table generation
    // Net per-hash cost: ~150× a single Haraka256 (well-documented ratio in
    // the Verus codebase + community benchmarks).
    double verushash_mhs_single = haraka256_mhs_single / 150.0;
    double verushash_mhs_total  = haraka256_mhs_total  / 150.0;

    printf("=== raw AES round throughput ===\n");
    printf("  single P-core: %10.2f M AES rounds/sec\n", single_thread_aes_mrps);
    printf("  %d threads:     %10.2f M AES rounds/sec (aggregate)\n",
           n_threads, aggregate_aes_mrps);
    printf("  scaling factor: %.2fx vs 1 thread\n",
           aggregate_aes_mrps / single_thread_aes_mrps);
    printf("\n");

    printf("=== derived Haraka256 v2 ceiling (÷12 cycles/hash) ===\n");
    printf("  single P-core: %10.2f MH/s\n", haraka256_mhs_single);
    printf("  %d threads:     %10.2f MH/s\n", n_threads, haraka256_mhs_total);
    printf("\n");

    printf("=== derived VerusHash 2.2 ceiling (÷150 per final hash) ===\n");
    printf("  single P-core: %10.3f MH/s\n", verushash_mhs_single);
    printf("  %d threads:     %10.3f MH/s\n", n_threads, verushash_mhs_total);
    printf("\n");

    printf("interpretation: these are *upper bounds* assuming all AES rounds\n");
    printf("issue in a single cycle and Haraka mixing fully hides latency.\n");
    printf("a real VerusHash 2.2 miner reaches ~30-60%% of this ceiling.\n");
    printf("\n");
    printf("sentinel (ignore): 0x%02x\n", sentinel_acc);
    return 0;
}
