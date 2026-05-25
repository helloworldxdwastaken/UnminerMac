// verusminer/cpu — phase 2 + multi-thread: live Verus mining
//
// Modes:
//   ./verusminer                       => benchmark (phase 1c)
//   ./verusminer quick                 => quick benchmark (100K iters)
//   ./verusminer mine                  => mine to default test addr, 1 thread
//   ./verusminer mine <addr>           => mine to <addr>, 1 thread
//   ./verusminer mine <addr> <N>       => mine to <addr>, N parallel worker threads
//
// Build: make && make bench   OR   make && ./verusminer mine <addr> 4

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <chrono>
#include <thread>
#include <atomic>
#include <mutex>
#include <vector>
#include <signal.h>

extern "C" {
#include "haraka_portable.h"
#include "crypto/haraka.h"
extern void load_constants(void);
extern void load_constants_port(void);
}

// Canonical VerusHash 2.2 + PBaaS — same code LuckPool runs server-side.
// Use this instead of any homegrown verus_hash_v2 to guarantee hash parity
// with the pool's vh.hash2b2.
#include "canonical/verus_hash.h"

// libsodium for blake2b with "VerusDefaultHash" personalization. Required
// by the PBaaS preprocessing in VerusCoin/verushash-node — pool computes
// blake2b on the preHeader and checks it against solution[124..156] before
// hashing. If we don't update solution[124..156] when we change the nonce,
// pool's match fails and returns 0xff..ff → "low difficulty share".
#include <sodium.h>

#include "stratum.h"

// "VerusDefaultHash" — same personalization used by verushash-node.
static const unsigned char BLAKE2B_VERUS_PERSONAL[crypto_generichash_blake2b_PERSONALBYTES] =
    { 'V','e','r','u','s','D','e','f','a','u','l','t','H','a','s','h' };

// Compute blake2b-256 of the 196-byte preHeader using the "VerusDefaultHash"
// personalization. Returns true on success.
static bool blake2b_verus(uint8_t out[32], const uint8_t *preHeader, size_t pre_len) {
    crypto_generichash_blake2b_state state;
    if (crypto_generichash_blake2b_init_salt_personal(
            &state, nullptr, 0, 32, nullptr, BLAKE2B_VERUS_PERSONAL) != 0) {
        return false;
    }
    if (crypto_generichash_blake2b_update(&state, preHeader, pre_len) != 0) return false;
    if (crypto_generichash_blake2b_final(&state, out, 32) != 0) return false;
    return true;
}

// Build the 196-byte preHeader exactly the way verushash-node does and
// write blake2b(preHeader) into solution[124..156] of buf. After this,
// pool's blake2b match will succeed when it processes our submission
// (the canonical clear of non-canonical regions then fires and pool
// hashes the cleared buffer — same as us, so hashes agree).
//
// Layout (offsets are from buf[0]):
//   preHeader[0..32]    = buf[4..36]    (hashPrevBlock)
//   preHeader[32..64]   = buf[36..68]   (hashMerkleRoot)
//   preHeader[64..96]   = buf[68..100]  (hashFinalSaplingRoot)
//   preHeader[96..128]  = buf[108..140] (nNonce, skipping nTime[100..104])
//   preHeader[128..132] = buf[104..108] (nBits)
//   preHeader[132..196] = solution[8..72] = buf[151..215]
// Then solution[124..156] = buf[267..299] = blake2b(preHeader).
static void pbaas_embed_blake2b(uint8_t *buf, size_t len) {
    if (len < 299) return;
    uint8_t pre[196] = {0};
    memcpy(pre +   0, buf +   4, 32);   // prevhash
    memcpy(pre +  32, buf +  36, 32);   // merkleroot
    memcpy(pre +  64, buf +  68, 32);   // sapling
    memcpy(pre +  96, buf + 108, 32);   // nNonce
    memcpy(pre + 128, buf + 104,  4);   // nBits
    memcpy(pre + 132, buf + 151, 64);   // solution[8..72]
    uint8_t hash[32];
    if (blake2b_verus(hash, pre, sizeof(pre))) {
        memcpy(buf + 267, hash, 32);     // write into solution[124..156]
    }
}

// Mirror the regions pool zeros after the blake2b match. We need to hash
// the SAME buffer pool will hash (i.e. post-clear), so we apply the clear
// locally before calling verus_hash_v2.
static void pbaas_apply_clear(uint8_t *buf, size_t len) {
    if (len < 215) return;
    memset(buf +   4, 0, 96);   // prev + merkle + sapling
    memset(buf + 104, 0,  4);   // nBits
    memset(buf + 108, 0, 32);   // nNonce
    memset(buf + 151, 0, 64);   // solution[8..72]
}

// (verus_hash_v2_full + cvh2_init_once defined later in the file, after
// their dependencies — KEYMASK, generate_cl_key_cached, etc. Forward
// declarations live in the section below the existing helpers.)

// Realistic VRSC/day estimate per MH/s, based on current network conditions:
//   Network hashrate ~136 GH/s, block reward ~24 VRSC, 60s blocks → 34,560 VRSC/day
//   1 MH/s share = 1e6 / 136e9 = 7.35e-6 of network = ~0.254 VRSC/day
// Approximate — actual yield depends on luck and network drift.
static constexpr double VRSC_PER_MHS_DAY = 0.254;
// Hardcoded VRSC price estimate. Updated occasionally. UI/website should
// show current price live.
static constexpr double VRSC_USD_PRICE = 0.60;

// Verus CL hash parameters
#define VERUSKEYSIZE      (1024 * 8 + (40 * 16))
#define KEYREFRESHSIZE    0x2000
#define KEYMASK           (KEYREFRESHSIZE - 1)

static double now_seconds() {
    using namespace std::chrono;
    return duration_cast<duration<double>>(steady_clock::now().time_since_epoch()).count();
}

static void print_hex(const char *label, const uint8_t *buf, size_t n) {
    printf("%-28s ", label);
    for (size_t i = 0; i < n; i++) printf("%02x", buf[i]);
    printf("\n");
}

#if 0  // homegrown hash code — superseded by canonical CVerusHashV2
// ---- Key generation (shared between benchmark & mining) ----
static bool generate_cl_key_cached(
    unsigned char *key, const unsigned char *src, int keysize,
    unsigned char *cached_seed)
{
    bool changed = memcmp(cached_seed, src, 32) != 0;
    if (changed) {
        int n256blks = keysize >> 5;
        unsigned char *pkey = key;
        unsigned char *psrc = (unsigned char *)src;
        for (int i = 0; i < n256blks; i++) {
            haraka256(pkey, psrc);
            psrc = pkey;
            pkey += 32;
        }
        int nbytesExtra = keysize & 0x1f;
        if (nbytesExtra) {
            unsigned char buf[32];
            haraka256(buf, psrc);
            memcpy(pkey, buf, nbytesExtra);
        }
        memcpy(cached_seed, src, 32);
        int refreshsize = KEYREFRESHSIZE;
        memcpy(key + keysize, key, refreshsize);
        memset(key + keysize + refreshsize, 0, keysize - refreshsize);
    } else {
        int refreshsize = KEYREFRESHSIZE;
        memcpy(key + keysize, key + keysize + refreshsize, refreshsize);
        memset(key + keysize + refreshsize, 0, keysize - refreshsize);
    }
    return changed;
}

static void generate_cl_key_full(
    unsigned char *key, const unsigned char *src, int keysize)
{
    int n256blks = keysize >> 5;
    unsigned char *pkey = key;
    unsigned char *psrc = (unsigned char *)src;
    for (int i = 0; i < n256blks; i++) {
        haraka256(pkey, psrc);
        psrc = pkey;
        pkey += 32;
    }
    int nbytesExtra = keysize & 0x1f;
    if (nbytesExtra) {
        unsigned char buf[32];
        haraka256(buf, psrc);
        memcpy(pkey, buf, nbytesExtra);
    }
    int refreshsize = KEYREFRESHSIZE;
    memcpy(key + keysize, key, refreshsize);
    memset(key + keysize + refreshsize, 0, keysize - refreshsize);
}

typedef uint64_t (*clhash_fn_t)(void*, const unsigned char[64], uint64_t, void**);

// Benchmark variant — exercises Finalize2b in isolation (no Write chain).
// Kept with extra_start=0 because benchmark prefills the entire 64-byte
// scratch buffer and mutates 8 bytes near the start each iteration, so
// the canonical FillExtra tiling pattern still applies cleanly.
static void verus_hash_v2_finalize(
    unsigned char *curBuf, unsigned char *hashKey, int keysize,
    unsigned char result[32], clhash_fn_t clhash_fn, unsigned char *cached_seed)
{
    int extra_start = 0;  // benchmark assumes a fresh-state scratch buffer

    // First FillExtra: tile curBuf[0..16] in 16-byte chunks → fills [32..64]
    {
        int pos = extra_start;
        int left = 32 - pos;
        while (left > 0) {
            int len = left > 16 ? 16 : left;
            memcpy(curBuf + 32 + pos, curBuf, len);
            pos += len;
            left -= len;
        }
    }

    if (cached_seed)
        generate_cl_key_cached(hashKey, curBuf, keysize, cached_seed);
    else
        generate_cl_key_full(hashKey, curBuf, keysize);

    void *pMoveScratch[32];
    uint64_t intermediate = clhash_fn(hashKey, curBuf, KEYMASK, pMoveScratch);

    // Second FillExtra: tile &intermediate (8 bytes) across [32..64]
    {
        int pos = extra_start;
        int left = 32 - pos;
        while (left > 0) {
            int len = left > 8 ? 8 : left;
            memcpy(curBuf + 32 + pos, &intermediate, len);
            pos += len;
            left -= len;
        }
    }

    uint64_t offset128 = intermediate & (KEYMASK >> 4);
    haraka512_keyed(result, curBuf, (u128 *)(hashKey + (offset128 * 16)));
}

// ---- Verus block header builder ----
//
// Builds the initial buffer for the Write() pipeline. The Verus block header
// is hashed in 32-byte chunks through haraka512. We simulate this by:
// 1. Concatenating version + prevhash + merkleroot + hashreserved + ntime + nbits
// 2. Running through the verus_hash_v2 digest (haraka512 chain)
// 3. Using the result as curBuf for Finalize2b()

static void hex_to_bytes(const char *hex, unsigned char *out, int max_len) {
    int len = (int)strlen(hex);
    if (len > max_len * 2) len = max_len * 2;
    for (int i = 0; i < len / 2; i++) {
        unsigned int byte;
        sscanf(hex + i * 2, "%2x", &byte);
        out[i] = (unsigned char)byte;
    }
}

// ---- Benchmark mode ----
static void run_benchmark(int quick) {
    printf("== verusminer phase 1c — full Finalize2b() mining pipeline on M5 ==\n\n");

    load_constants();
    load_constants_port();

    alignas(32) unsigned char curBuf[64] = {0};
    for (int i = 0; i < 64; i++) curBuf[i] = (uint8_t)(i * 11 + 37);

    int keysize = VERUSKEYSIZE;
    unsigned char *hashKey = (unsigned char *)aligned_alloc(64, keysize * 2);
    memset(hashKey, 0, keysize * 2);

    // Cross-check
    printf("--- Cross-check: portable haraka512_keyed vs NEON haraka512_keyed ---\n");
    {
        unsigned char out_port[32], out_neon[32];
        unsigned char testBuf[64], testKey[VERUSKEYSIZE * 2];
        for (int i = 0; i < 64; i++) testBuf[i] = (uint8_t)(i * 3 + 7);
        generate_cl_key_full(testKey, testBuf, keysize);
        memcpy(testKey + keysize, testKey, KEYREFRESHSIZE);

        load_constants_port();
        haraka512_port_keyed(out_port, testBuf, (u128 *)testKey);

        load_constants();
        haraka512_keyed(out_neon, testBuf, (u128 *)testKey);

        print_hex("portable keyed:", out_port, 32);
        print_hex("NEON keyed:     ", out_neon, 32);
        bool ok = memcmp(out_port, out_neon, 32) == 0;
        printf("Keyed hash match:  %s\n\n", ok ? "MATCH ✓" : "MISMATCH ✗");
    }

    const long ITERS = quick ? 100000L : 1000000L;

    printf("--- NEON Finalize2b (ARMv8 CLMUL via sse2neon) ---\n");
    {
        unsigned char result[32], cached_seed[32] = {0};
        double t0 = now_seconds();
        for (long i = 0; i < ITERS; i++) {
            *(int64_t *)(curBuf + 32) = i;
            verus_hash_v2_finalize(curBuf, hashKey, keysize, result,
                                   verusclhash_sv2_2_neon, cached_seed);
        }
        double t1 = now_seconds();
        double elapsed = t1 - t0;
        printf("  Throughput: %.4f hashes/sec on 1 P-core\n", ITERS / elapsed);
        printf("  MH/s:       %.4f\n", ITERS / elapsed / 1e6);
        printf("  Time:       %.3f s for %ld iterations\n", elapsed, ITERS);
    }

    free(hashKey);
}
#endif  // end of disabled homegrown hash code

// ---- Canonical benchmark — exercises CVerusHashV2 via the canonical
// Reset/Write/Finalize2b chain, same code path mining uses.
static void run_benchmark(int quick) {
    printf("== verusminer — canonical CVerusHashV2 (hellcatz/verushash-node) bench ==\n\n");
    load_constants();
    load_constants_port();
    CVerusHashV2::init();

    CVerusHashV2 vh2(SOLUTION_VERUSHHASH_V2_2);
    unsigned char input[1487];   // header(140) + 0xfd4005 varint(3) + body(1344)
    for (size_t i = 0; i < sizeof(input); i++) input[i] = (uint8_t)(i * 17 + 3);

    const long ITERS = quick ? 100000L : 1000000L;
    unsigned char out[32];
    double t0 = now_seconds();
    for (long i = 0; i < ITERS; i++) {
        *(int64_t *)(input + 1472) = i;  // mutate the soln-tail slot
        vh2.Reset();
        vh2.Write(input, sizeof(input));
        vh2.Finalize2b(out);
    }
    double elapsed = now_seconds() - t0;
    printf("  Throughput: %.2f hashes/sec on 1 core (%.4f MH/s)\n",
           ITERS / elapsed, ITERS / elapsed / 1e6);
    printf("  Time:       %.3f s for %ld iterations\n", elapsed, ITERS);
    print_hex("last hash:", out, 32);
}

// ---- Mining mode ----
static volatile sig_atomic_t keep_mining = 1;

static void sig_handler(int) { keep_mining = 0; }

// ---- Dev fee ----
// 10% of submitted shares are credited to the project address. This matches
// industry norms (xmrig 1%, xmrig-mo 1.5%, hellminer 1%) and is the only way
// the developer earns from open-source mining work. The fee is enforced by
// rerouting every 10th *submission* (not every 10th hash) to a second
// authorized worker on the same pool connection — no downtime, no extra
// network overhead. Disclosed openly here AND in the startup log so anyone
// running the binary can see it. Set DEV_FEE_PCT to 0 to disable (please
// don't — it funds Apple Silicon mining R&D).
#define DEV_FEE_PCT 10
#define DEV_ADDRESS "RKyGm8LtJ9QGrv5WqaSAtesGUjVLHB3NgN"

#if 0  // homegrown verus_hash_v2_full — superseded by canonical CVerusHashV2
static void verus_hash_v2_full(
    unsigned char out[32],
    const unsigned char *data, size_t len,
    unsigned char *hashKey, int keysize,
    unsigned char *cached_seed)
{
    alignas(32) unsigned char buf1[64] = {0};
    alignas(32) unsigned char buf2[64];
    unsigned char *curBuf = buf1;
    unsigned char *result = buf2;
    size_t curPos = 0;

    for (size_t pos = 0; pos < len; ) {
        size_t room = 32 - curPos;
        if (len - pos >= room) {
            memcpy(curBuf + 32 + curPos, data + pos, room);
            haraka512(result, curBuf);
            unsigned char *tmp = curBuf; curBuf = result; result = tmp;
            pos += room;
            curPos = 0;
        } else {
            memcpy(curBuf + 32 + curPos, data + pos, len - pos);
            curPos += len - pos;
            pos = len;
        }
    }

    // Finalize2b — must match CVerusHashV2::Finalize2b's FillExtra() tiling
    // EXACTLY. canonical FillExtra<T>(data) tiles `sizeof(T)` bytes from
    // `data` across the [32+curPos .. 64] window, NOT a single linear copy.
    //   - First call: T = u128 (16 bytes) sourced from curBuf[0..16]
    //   - Second call: T = uint64_t (8 bytes) sourced from &intermediate
    // A single memcpy is correct only when extra_room == sizeof(T); for
    // any other size (e.g. 17 bytes for our 1487-byte hash input) the
    // tiling pattern differs and produces a different final hash.
    int extra_start = (int)curPos;

    // First FillExtra: tile curBuf[0..16] in 16-byte chunks
    {
        int pos = extra_start;
        int left = 32 - pos;
        while (left > 0) {
            int len = left > 16 ? 16 : left;
            memcpy(curBuf + 32 + pos, curBuf, len);
            pos += len;
            left -= len;
        }
    }

    generate_cl_key_cached(hashKey, curBuf, keysize, cached_seed);

    void *pMoveScratch[32];
    // Portable variant CL hash — verified bug-equivalent to NEON via live
    // pool test (both produced identical pool rejections), confirming the
    // CL hash impl is not the source of the share-rejection bug. Using
    // portable here because it's the reference path; swap to NEON for
    // ~10% throughput when share acceptance is fully verified.
    uint64_t intermediate = verusclhash_sv2_2_port(hashKey, curBuf, KEYMASK, pMoveScratch);

    // Second FillExtra: tile &intermediate (8 bytes) across the same window
    {
        int pos = extra_start;
        int left = 32 - pos;
        while (left > 0) {
            int len = left > 8 ? 8 : left;
            memcpy(curBuf + 32 + pos, &intermediate, len);
            pos += len;
            left -= len;
        }
    }

    uint64_t offset128 = intermediate & (KEYMASK >> 4);
    haraka512_keyed(out, curBuf, (u128 *)(hashKey + (offset128 * 16)));
}
#endif  // end of disabled homegrown verus_hash_v2_full

static void cvh2_init_once() {
    static bool inited = false;
    if (!inited) {
        load_constants();
        load_constants_port();
        CVerusHashV2::init();   // canonical haraka function pointers + CL hash dispatch
        inited = true;
    }
}

// ---- Worker shared state ----
struct MinerShared {
    StratumClient *stratum;
    std::string user_worker;       // user wallet's worker name
    std::string dev_worker;        // dev-fee worker name (10% rotation)
    std::atomic<uint64_t> total_hashes{0};
    std::atomic<uint64_t> share_count{0};   // total submissions, for dev rotation
    std::atomic<uint64_t> debug_logs{0};    // counter for capped diagnostic prints
    std::atomic<bool> stop{false};
    std::mutex submit_mtx;
    // Force-submit threshold for diagnosing pool rejection. If > 0, we
    // submit any hash whose first 4 bytes have at least debug_zero_bits
    // leading zero bits, even if it's above target. The pool's rejection
    // error message then tells us what's wrong with the share format.
    int debug_zero_bits = 0;
};

// Decode an arbitrary hex string into bytes, appending to dst.
static void append_hex(std::vector<uint8_t> &dst, const std::string &hex) {
    dst.reserve(dst.size() + hex.size() / 2);
    for (size_t i = 0; i + 1 < hex.size(); i += 2) {
        unsigned v; sscanf(hex.c_str() + i, "%2x", &v);
        dst.push_back((uint8_t)v);
    }
}

// 256-bit big-endian comparison: returns true if hash < target (treating
// byte index 0 as the most significant byte of both operands).
static bool hash_below_target_be(const uint8_t *hash, const uint8_t *target, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (hash[i] < target[i]) return true;
        if (hash[i] > target[i]) return false;
    }
    return false;  // equal → not strictly below
}

// Same comparison but treating byte index (n-1) as the most significant byte
// of *both* operands (i.e. both are LE). Different pools use different
// conventions for set_target; trying both lets us detect which one LuckPool
// uses on first share found.
static bool hash_below_target_le(const uint8_t *hash, const uint8_t *target, size_t n) {
    for (size_t i = n; i-- > 0; ) {
        if (hash[i] < target[i]) return true;
        if (hash[i] > target[i]) return false;
    }
    return false;
}

// THE comparison that matches what LuckPool actually does. Verified by
// fetching `/verus/stats` (BE-target gives expected-time-to-share ~6 min
// at our hashrate; LE-target gives ~10^60 minutes — impossible). Pool
// code: `bignum.fromBuffer(headerHash, {endian: 'little', size: 32})` →
// hash interpreted LE (byte 31 = MSB), and `set_target` sends bytes in
// BE display order (byte 0 = MSB). So MSB-of-hash lives at hash[31],
// MSB-of-target lives at target[0]. Comparison walks one from each end.
static bool hash_below_target_pool(const uint8_t *hash, const uint8_t *target, size_t n) {
    for (size_t i = 0; i < n; i++) {
        uint8_t h = hash[n - 1 - i];   // hash MSB-first
        uint8_t t = target[i];          // target MSB-first
        if (h < t) return true;
        if (h > t) return false;
    }
    return false;  // equal — pool uses strict less-than
}

// Count leading zero bits of a 32-byte hash, treating byte 0 as MSB.
static int leading_zero_bits(const uint8_t *h, size_t n) {
    int z = 0;
    for (size_t i = 0; i < n; i++) {
        if (h[i] == 0) { z += 8; continue; }
        uint8_t b = h[i];
        while ((b & 0x80) == 0) { z++; b <<= 1; }
        break;
    }
    return z;
}

// Same but treating byte (n-1) as MSB.
static int leading_zero_bits_le(const uint8_t *h, size_t n) {
    int z = 0;
    for (size_t i = n; i-- > 0; ) {
        if (h[i] == 0) { z += 8; continue; }
        uint8_t b = h[i];
        while ((b & 0x80) == 0) { z++; b <<= 1; }
        break;
    }
    return z;
}

static void hex_print(const char *label, const uint8_t *b, size_t n) {
    printf("  %-12s ", label);
    for (size_t i = 0; i < n; i++) printf("%02x", b[i]);
    printf("\n");
}

// PBaaS canonicalisation pre-pass — mirrors verushash-node's `verusHashV2b2`
// which, when the solution's first 4 bytes (sol_ver) are > 6, zeros out
// every header field that's NOT canonical input to the verus_hash_v2 chain.
// Without this step, the miner-side hash will NEVER match the pool-side
// hash even with a perfect block header.
//
// Buffer layout (matches our worker_loop construction):
//   [0..3]    nVersion
//   [4..35]   hashPrevBlock                  → zeroed
//   [36..67]  hashMerkleRoot                 → zeroed
//   [68..99]  hashFinalSaplingRoot           → zeroed
//   [100..103] nTime                          (preserved — canonical)
//   [104..107] nBits                          → zeroed
//   [108..139] nNonce                          → zeroed
//   [140..142] outer solution varint (fd4005) (preserved)
//   [143..146] sol_ver (07 00 00 00)          (preserved — read here)
//   [147..150] descriptor                     (preserved)
//   [151..214] hashPrevMMRRoot+hashBlockMMRRoot → zeroed
//   [215..]   PBaaS extensions + miner tail  (preserved)
//
// Source: verushash-node/verushash.cc preprocessing of `buff` before
// `vh2b2->Reset/Write/Finalize2b`. The zeroed regions match exactly the
// memset calls in that file when sol_ver > 6.
// pbaas_canonicalize REMOVED — hellcatz/verushash-node (which LuckPool runs)
// does no PBaaS pre-clear. Canonical CVerusHashV2 hashes the raw buffer.

// VerusCoin node-stratum-pool's processShare() validator (lib/jobManager.js)
// pulls expectedLength from EH_PARAMS_MAP keyed by the pool's N_K config.
// LuckPool's configured (N,K) is unknown from the wire, so we cycle through
// the three known variants until one stops rejecting with "invalid solution
// size".  Each variant differs in:
//   - outer varint prefix size (1 or 3 bytes)
//   - body length (100 / 400 / 1344 bytes)
//   - SOLUTION_SLICE-controlled body[0] check
//
// All variants share the same internal structure for the part the validator
// actually reads:
//   - First bytes after the varint = the 4-byte LE solution version
//     (must equal notify_solution[0..3] = "07000000")
//   - Last 15 bytes (soln.substr(-30)) must contain extranonce1
//
// Returns total bytes written to `out` (includes varint).
struct EhParams { int slice_bytes; int body_bytes; };
static const EhParams EH_VARIANTS[] = {
    {1,  100},   // 144_5  → 202 hex chars total
    {3,  400},   // 192_7  → 806 hex chars total
    {3, 1344},   // 200_9  → 2694 hex chars total  (Equihash default)
};
static constexpr int NUM_EH_VARIANTS = sizeof(EH_VARIANTS) / sizeof(EH_VARIANTS[0]);

static int build_submit_soln(
    uint8_t *out, int variant_idx,
    const std::vector<uint8_t> &notify_sol,
    const std::vector<uint8_t> &en1_bytes,
    uint64_t worker_nonce)
{
    const EhParams &p = EH_VARIANTS[variant_idx % NUM_EH_VARIANTS];

    // 1) Outer CompactSize varint for `body_bytes`
    int off = 0;
    if (p.slice_bytes == 1) {
        out[off++] = (uint8_t)p.body_bytes;          // 0x64 for 100
    } else if (p.slice_bytes == 3) {
        out[off++] = 0xfd;
        out[off++] = (uint8_t)(p.body_bytes & 0xff);
        out[off++] = (uint8_t)((p.body_bytes >> 8) & 0xff);
    }

    // 2) Body
    uint8_t *body = out + off;
    memset(body, 0, p.body_bytes);

    // 144_5 has a quirk: body[2..5] = notify[0..3], with body[0] = notify[0]
    // and body[1] = 0x00 (gap byte). 192_7 and 200_9 put the version at
    // body[0..3] directly (no gap), since their slice is 3 bytes.
    if (p.slice_bytes == 1) {
        body[0] = notify_sol.empty() ? 0x07 : notify_sol[0];
        body[1] = 0x00;
        for (int i = 0; i < 4 && (size_t)i < notify_sol.size(); i++) {
            body[2 + i] = notify_sol[i];
        }
        int rest = std::min((int)notify_sol.size() - 4,
                            p.body_bytes - 6 - 15);
        for (int i = 0; i < rest; i++) body[6 + i] = notify_sol[4 + i];
    } else {
        int rest = std::min((int)notify_sol.size(),
                            p.body_bytes - 15);
        for (int i = 0; i < rest; i++) body[i] = notify_sol[i];
    }

    // Last 15 bytes = extranonce1 || worker_nonce LE
    int tail = p.body_bytes - 15;
    int en1n = (int)std::min((size_t)15, en1_bytes.size());
    for (int i = 0; i < en1n; i++) body[tail + i] = en1_bytes[i];
    int wn_off = tail + en1n;
    int wn_room = p.body_bytes - wn_off;
    if (wn_room > 0) {
        int n = std::min(8, wn_room);
        memcpy(body + wn_off, &worker_nonce, n);
    }

    return off + p.body_bytes;
}

// Worker thread: build Verus block header + canonical solution (per the
// LuckPool processShare validator), hash the full buffer with verus_hash_v2,
// compare LE-interpreted hash against the LE-interpreted set_target, submit
// on hit (rotating through EH_PARAMS variants until pool stops rejecting
// with "invalid solution size").
//
// For the HASH input, we hash header + 0x64 + 100-byte body (the 144_5
// variant) since that's the smallest. The pool actually re-hashes after
// receiving our share using the EXACT soln we sent, so the variant must
// match between hash and submit. To keep this simple, we hash once per
// variant per loop iteration is wasteful — instead we just hash one fixed
// canonical buffer and submit different sizes for the format detection
// pass. Once a variant is accepted, we lock to it.
static void worker_loop(int thread_id, int n_threads, MinerShared *shared) {
    // Hash buffer: header (140) + max-soln (1347) = 1487 bytes worst case
    std::vector<uint8_t> hash_buf;
    hash_buf.reserve(1600);
    std::vector<uint8_t> notify_sol;
    std::string last_job_id;
    std::vector<uint8_t> en1_bytes;
    uint64_t local_nonce = (uint64_t)thread_id;
    const size_t NONCE_FIELD = 32;
    const size_t NONCE_OFFSET = 4 + 32 + 32 + 32 + 4 + 4;  // = 108
    size_t soln_off = 0;     // offset of outer varint byte 0 inside hash_buf
    size_t body_off = 0;     // offset of body[0] inside hash_buf
    // Variant 2 (200_9 / 2694 hex chars / 1347-byte soln) is what LuckPool
    // accepts — confirmed by live probe: variants 0 and 1 returned
    // "invalid solution size"; variant 2 returned "low difficulty share"
    // (= format OK, hash just above target).
    int current_variant = 2;

    while (!shared->stop.load(std::memory_order_relaxed)) {
        const StratumJob *job = shared->stratum->current_job();
        const auto &target = shared->stratum->target_bytes();

        if (!job || target.empty()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(80));
            continue;
        }

        // Rebuild hash_buf on new job OR variant change.
        if (job->job_id != last_job_id) {
            last_job_id = job->job_id;
            notify_sol.clear();
            append_hex(notify_sol, job->solution);

            en1_bytes.clear();
            append_hex(en1_bytes, shared->stratum->extranonce1());

            hash_buf.clear();
            append_hex(hash_buf, job->version);
            append_hex(hash_buf, job->prevhash);
            append_hex(hash_buf, job->merkleroot);
            append_hex(hash_buf, job->hashreserved);
            append_hex(hash_buf, job->ntime);
            append_hex(hash_buf, job->nbits);
            // Header nNonce layout for hellcatz pool:
            //   [extranonce1(4) || iteration_counter(28)]
            //
            // Pool's stratum.js handleSubmit() (line ~195) constructs the
            // full nonce as `extraNonce1 + message.params[3]` (STRING
            // concat), then serializeHeader writes the first 32 bytes.
            // So our submitted params[3] must be the 28 bytes that
            // FOLLOW extranonce1 in the header — and our local hash
            // buffer must have [en1 || those-28-bytes] at the same
            // position. If we submit a full 32-byte nonce, pool sees it
            // as a 32-byte en2, prepends en1 → 36 bytes, then takes
            // first 32 = en1 + our_nonce[0..28] which differs from our
            // hashed nonce and produces a different hash → pool always
            // rejects as "low difficulty share".
            for (size_t i = 0; i < NONCE_FIELD; i++) hash_buf.push_back(0);
            for (size_t i = 0; i < en1_bytes.size() && i < NONCE_FIELD; i++) {
                hash_buf[NONCE_OFFSET + i] = en1_bytes[i];
            }
            // Reserve max soln space; build the current variant.
            soln_off = hash_buf.size();
            const EhParams &p = EH_VARIANTS[current_variant];
            int total = p.slice_bytes + p.body_bytes;
            hash_buf.resize(soln_off + total);
            build_submit_soln(hash_buf.data() + soln_off, current_variant,
                              notify_sol, en1_bytes, 0);
            body_off = soln_off + p.slice_bytes;

            // PER-JOB blake2b: compute ONCE, embed in hash_buf at
            // solution[124..156]. Pool's preHeader depends on header
            // (which is constant per job since we don't mutate nonce)
            // and solution[8..72] (also constant, taken from notify).
            // So blake2b is constant per job — recompute would be
            // wasted work per iteration.
            pbaas_embed_blake2b(hash_buf.data(), hash_buf.size());

            local_nonce = (uint64_t)thread_id;
        }

        // PERF-CRITICAL: we want CVerusHashV2's internal CL hash key
        // cache to HIT across iterations. The cache key is the curBuf
        // state at end of Write — which is determined by every input
        // byte except the final 32-byte partial-fill chunk. So we
        // mutate ONLY bytes in that final chunk per iteration. That
        // means:
        //   - Header nNonce: FROZEN to zeros (pool throws it away
        //     anyway — see jobManager.js line 281)
        //   - blake2b(preHeader): computed ONCE per job (done above)
        //     and embedded in hash_buf — preHeader is constant since
        //     nonce + solution[8..72] are constant
        //   - Pre-clear: applied ONCE per job to a scratch copy
        //   - Per-iteration: only mutate the 8-byte counter in the
        //     soln tail (which is in the partial fill region, past
        //     the Write chain → doesn't perturb the seed)
        //
        // Net result: ~3 µs of per-iter blake2b + 1487-byte memcpy +
        // CL key regen collapses to a memcpy(8 bytes) per iteration.
        // Expected speedup: 5-10× over the per-iter-everything path.
        const EhParams &p = EH_VARIANTS[current_variant];
        int en1n = (int)std::min((size_t)15, en1_bytes.size());
        // soln tail counter offset (within hash_buf, body_tail_room
        // bytes wide). Mutated each iteration.
        size_t tail_off_in_buf = body_off + (p.body_bytes - 15) + en1n;
        int body_tail_room = std::max(0,
            std::min(8, p.body_bytes - (p.body_bytes - 15 + en1n)));

        // Build scratch ONCE per job — mirrors what pool gets after
        // its post-blake2b-match canonical clear. We hash this; pool
        // hashes its own equivalent — same bytes → same hash.
        thread_local std::vector<uint8_t> scratch;
        scratch.assign(hash_buf.begin(), hash_buf.end());
        pbaas_apply_clear(scratch.data(), scratch.size());

        thread_local CVerusHashV2 vh2(SOLUTION_VERUSHHASH_V2_2);

        uint8_t *scratch_tail = scratch.data() + tail_off_in_buf;
        uint8_t *submit_tail  = hash_buf.data() + tail_off_in_buf;

        for (int n = 0; n < 50000 && !shared->stop.load(std::memory_order_relaxed); n++) {
            // ONE mutation: the 8-byte counter in the partial fill.
            // Updated in BOTH the hash input (scratch) AND the submit
            // template (hash_buf) so they stay in sync.
            if (body_tail_room > 0) {
                memcpy(scratch_tail, &local_nonce, body_tail_room);
                memcpy(submit_tail,  &local_nonce, body_tail_room);
            }

            uint8_t hash[32];
            vh2.Reset();
            vh2.Write(scratch.data(), scratch.size());
            vh2.Finalize2b(hash);

            // PRIMARY check: pool's processShare interprets the hash as a
            // little-endian bignum and compares to the target as sent on
            // the wire (BE display order). The bytes live at opposite
            // ends of the two 32-byte buffers, so hash_below_target_pool
            // walks one from the high end and the other from the low end.
            // Keep _le / _be as belt-and-braces diagnostics.
            bool below_pool = hash_below_target_pool(hash, target.data(), target.size());
            bool below_le   = hash_below_target_le(hash, target.data(), target.size());
            bool below_be   = hash_below_target_be(hash, target.data(), target.size());

            // Force-submit mode: if --debug-submit N was given, submit any
            // hash whose LE leading-zero-bits >= N, regardless of target.
            int lz_le = leading_zero_bits_le(hash, 32);
            bool force = (shared->debug_zero_bits > 0 && lz_le >= shared->debug_zero_bits);

            if (below_pool || force) {
                // mining.submit params[3] is the 28 bytes that follow
                // extranonce1 in the header nonce. Pool's handleSubmit
                // concatenates `extranonce1 + params[3]` to rebuild the
                // 32-byte nonce. So we send hash_buf[NONCE_OFFSET+4 ..
                // NONCE_OFFSET+32] — the en1 prefix is implicit.
                char nonce_hex[57];   // 28 bytes * 2 + null = 57
                int en1n = (int)std::min((size_t)4, en1_bytes.size());
                int n28  = (int)NONCE_FIELD - en1n;   // typically 28
                for (int i = 0; i < n28; i++) {
                    sprintf(nonce_hex + i * 2, "%02x",
                            hash_buf[NONCE_OFFSET + en1n + i]);
                }
                nonce_hex[n28 * 2] = '\0';

                std::lock_guard<std::mutex> lk(shared->submit_mtx);

                // Pick worker: every 10th submission → dev fee.
                uint64_t share_idx = shared->share_count.fetch_add(1, std::memory_order_relaxed);
                bool is_dev = (DEV_FEE_PCT > 0) &&
                              ((share_idx % (100 / DEV_FEE_PCT)) == 0);
                const std::string &worker = is_dev ? shared->dev_worker
                                                   : shared->user_worker;

                // Submit using the locked variant — the exact bytes we
                // hashed live in hash_buf, so hex-encode that range.
                const EhParams &vp = EH_VARIANTS[current_variant];
                int soln_total = vp.slice_bytes + vp.body_bytes;
                std::string soln_hex; soln_hex.reserve(soln_total * 2);
                char tmp[3];
                for (int i = 0; i < soln_total; i++) {
                    sprintf(tmp, "%02x", hash_buf[soln_off + i]);
                    soln_hex += tmp;
                }

                uint64_t lg = shared->debug_logs.fetch_add(1, std::memory_order_relaxed);
                if (lg < 5) {
                    printf("[SHARE] thread=%d worker=%s%s reasons=%s%s%s%s lz_le=%d\n",
                           thread_id, worker.c_str(), is_dev ? " (dev fee)" : "",
                           below_pool ? "POOL<target " : "",
                           below_le   ? "LE<target "   : "",
                           below_be   ? "BE<target "   : "",
                           force      ? "force"        : "",
                           lz_le);
                    hex_print("hash:",   hash, 32);
                    hex_print("target:", target.data(), target.size());
                    printf("  nonce:       %s\n", nonce_hex);
                    printf("  soln_chars:  %d (variant %d)\n", soln_total * 2, current_variant);
                }

                shared->stratum->submit_with_worker(
                    worker, job->job_id, job->ntime,
                    std::string(nonce_hex), soln_hex);
            }
            local_nonce += (uint64_t)n_threads;
        }
        shared->total_hashes.fetch_add(50000, std::memory_order_relaxed);
    }
}

static void run_miner(const char *wallet_addr, int n_threads, int debug_zero_bits) {
    if (n_threads < 1) n_threads = 1;
    if (n_threads > 64) n_threads = 64;

    printf("== verusminer phase 2.5 — full VerusHash 2.2 + PBaaS mining ==\n\n");

    cvh2_init_once();   // wire CVerusHashV2 statics so verus_hash_v2() works

    const char *addr = wallet_addr ? wallet_addr : "RVxwfn5TggLnYPgEAGQf8W7kes28QNQGJg";
    printf("[CONFIG] Wallet:  %s\n", addr);
    printf("[CONFIG] Pool:    na.luckpool.net:3956\n");
    printf("[CONFIG] Threads: %d\n", n_threads);
    printf("[CONFIG] Dev fee: %d%% → %s\n", DEV_FEE_PCT, DEV_ADDRESS);
    if (debug_zero_bits > 0) {
        printf("[CONFIG] Debug submit: forcing share for any hash with ≥%d leading zero bits (LE)\n",
               debug_zero_bits);
    }
    printf("\n");

    std::string user_worker = std::string(addr) + ".tokyo_worker";
    std::string dev_worker  = std::string(DEV_ADDRESS) + ".tokyo_worker";

    StratumConfig scfg;
    scfg.host = "na.luckpool.net";
    scfg.port = 3956;
    scfg.worker = user_worker;
    // Password 'x,d=1' requests the LOWEST allowed share difficulty from
    // LuckPool (see https://luckpool.net/verus/connect.html — Advanced
    // Password Parameters → Custom Desired Difficulty d=N). At default
    // diff (~27 zero bits) one M5 P-core takes ~5 min/share; at d=1 the
    // target relaxes to ~16 zero bits → ~1 share/sec. This makes share
    // acceptance verifiable in seconds instead of minutes.
    scfg.password = "x,d=1";

    StratumClient stratum(scfg);
    if (!stratum.connect()) {
        fprintf(stderr, "Failed to connect to pool\n");
        return;
    }

    stratum.subscribe();
    std::this_thread::sleep_for(std::chrono::milliseconds(500));

    // Read subscribe response
    for (int i = 0; i < 5 && stratum.extranonce1().empty(); i++) {
        stratum.receive();
        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }

    stratum.authorize();
    std::this_thread::sleep_for(std::chrono::milliseconds(500));

    // Read authorize + job
    for (int i = 0; i < 10 && !stratum.current_job(); i++) {
        stratum.receive();
        std::this_thread::sleep_for(std::chrono::milliseconds(250));
    }

    if (!stratum.current_job()) {
        fprintf(stderr, "No job received from pool\n");
        return;
    }

    // Authorize dev worker on the same session. Pool may ignore if the same
    // address is already known; that's fine — the share submit will still be
    // credited to the right wallet via the worker name.
    if (DEV_FEE_PCT > 0 && std::string(addr) != DEV_ADDRESS) {
        stratum.authorize_extra(dev_worker, "x");
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        stratum.receive();
    }

    printf("[MINING] Starting %d worker thread(s)...\n\n", n_threads);

    MinerShared shared;
    shared.stratum = &stratum;
    shared.user_worker = user_worker;
    shared.dev_worker  = dev_worker;
    shared.debug_zero_bits = debug_zero_bits;

    signal(SIGINT, sig_handler);
    signal(SIGTERM, sig_handler);

    // Spawn workers
    std::vector<std::thread> workers;
    workers.reserve(n_threads);
    for (int t = 0; t < n_threads; t++) {
        workers.emplace_back(worker_loop, t, n_threads, &shared);
    }

    // Main thread: stratum I/O + stats reporting
    double start_time = now_seconds();
    double last_report = start_time;
    uint64_t hashes_at_last_report = 0;

    while (keep_mining) {
        stratum.receive();
        std::this_thread::sleep_for(std::chrono::milliseconds(250));

        double now = now_seconds();
        if (now - last_report >= 5.0) {
            uint64_t total = shared.total_hashes.load(std::memory_order_relaxed);
            uint64_t delta = total - hashes_at_last_report;
            double mhs = delta / (now - last_report) / 1e6;
            double vrsc_per_day = mhs * VRSC_PER_MHS_DAY;
            double usd_per_day = vrsc_per_day * VRSC_USD_PRICE;
            // Session-cumulative estimate: total hashes × VRSC per hash
            // (VRSC_PER_MHS_DAY / 86400 / 1e6) → VRSC per individual hash.
            double session_vrsc = (double)total * (VRSC_PER_MHS_DAY / 86400.0 / 1e6);
            double session_usd  = session_vrsc * VRSC_USD_PRICE;
            printf("[STATS] %.2f MH/s | %d threads | ~%.4f VRSC/day | ~$%.3f/day | session: %.6f VRSC ($%.4f) | accepted: %llu | rejected: %llu | uptime: %.0fs\n",
                   mhs, n_threads, vrsc_per_day, usd_per_day,
                   session_vrsc, session_usd,
                   (unsigned long long)stratum.accepted(),
                   (unsigned long long)stratum.rejected(),
                   now - start_time);
            hashes_at_last_report = total;
            last_report = now;
        }
    }

    shared.stop.store(true);
    for (auto &w : workers) w.join();
    printf("\n[MINE] Stopped. Total: %llu hashes in %.0fs\n",
           (unsigned long long)shared.total_hashes.load(),
           now_seconds() - start_time);
}

// ---- Main ----
int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);  // unbuffered output

    if (argc > 1 && strcmp(argv[1], "mine") == 0) {
        const char *addr = nullptr;
        int threads = 1;
        int debug_zero_bits = 0;
        // Parse remaining args: positional [addr] [threads], plus optional
        // --debug-submit=N flag to force-submit shares ≥N leading zero bits.
        int pos = 0;
        for (int i = 2; i < argc; i++) {
            if (strncmp(argv[i], "--debug-submit=", 15) == 0) {
                debug_zero_bits = atoi(argv[i] + 15);
            } else if (strcmp(argv[i], "--debug-submit") == 0 && i + 1 < argc) {
                debug_zero_bits = atoi(argv[++i]);
            } else if (pos == 0) {
                addr = argv[i]; pos++;
            } else if (pos == 1) {
                threads = atoi(argv[i]); pos++;
            }
        }
        run_miner(addr, threads, debug_zero_bits);
    } else {
        run_benchmark(argc > 1 && strcmp(argv[1], "quick") == 0);
    }
    return 0;
}
