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
extern uint64_t verusclhash_sv2_2_port(void*, const unsigned char[64], uint64_t, void**);
extern uint64_t verusclhash_sv2_2_neon(void*, const unsigned char[64], uint64_t, void**);
}

#include "stratum.h"

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

static void verus_hash_v2_finalize(
    unsigned char *curBuf, unsigned char *hashKey, int keysize,
    unsigned char result[32], clhash_fn_t clhash_fn, unsigned char *cached_seed)
{
    int extra_size = 32;
    memcpy(curBuf + 32 + extra_size, curBuf, 32 - extra_size);

    if (cached_seed)
        generate_cl_key_cached(hashKey, curBuf, keysize, cached_seed);
    else
        generate_cl_key_full(hashKey, curBuf, keysize);

    void *pMoveScratch[32];
    uint64_t intermediate = clhash_fn(hashKey, curBuf, KEYMASK, pMoveScratch);

    memcpy(curBuf + 32 + extra_size, &intermediate, 8);

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

// ---- Mining mode ----
static volatile sig_atomic_t keep_mining = 1;

static void sig_handler(int) { keep_mining = 0; }

// Self-contained VerusHash 2.2 "full" hash. Mirrors what CVerusHashV2::Hash()
// from VerusCoin does, using the haraka funcs we already link (no boost /
// tinyformat / Bitcoin-Core deps). Two-pass:
//   1) Write chain — process input in 32-byte chunks, each step:
//      (*haraka512)(buf2, buf1) then swap.
//   2) Finalize2b — fill extra, gen clhash key, CL hash, then
//      haraka512_keyed with the offset key.
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

    // Finalize2b
    int extra_start = (int)curPos;
    int extra_room = 32 - extra_start;
    if (extra_room > 0) {
        memcpy(curBuf + 32 + extra_start, curBuf, extra_room);
    }

    generate_cl_key_cached(hashKey, curBuf, keysize, cached_seed);

    void *pMoveScratch[32];
    uint64_t intermediate = verusclhash_sv2_2_neon(hashKey, curBuf, KEYMASK, pMoveScratch);

    if (extra_room > 0) {
        memcpy(curBuf + 32 + extra_start, &intermediate,
               std::min((int)sizeof(intermediate), extra_room));
    }

    uint64_t offset128 = intermediate & (KEYMASK >> 4);
    haraka512_keyed(out, curBuf, (u128 *)(hashKey + (offset128 * 16)));
}

static void cvh2_init_once() {
    static bool inited = false;
    if (!inited) {
        load_constants();
        load_constants_port();
        inited = true;
    }
}

// ---- Worker shared state ----
struct MinerShared {
    StratumClient *stratum;
    std::atomic<uint64_t> total_hashes{0};
    std::atomic<bool> stop{false};
    std::mutex submit_mtx;
};

// Decode an arbitrary hex string into bytes, appending to dst.
static void append_hex(std::vector<uint8_t> &dst, const std::string &hex) {
    dst.reserve(dst.size() + hex.size() / 2);
    for (size_t i = 0; i + 1 < hex.size(); i += 2) {
        unsigned v; sscanf(hex.c_str() + i, "%2x", &v);
        dst.push_back((uint8_t)v);
    }
}

// 256-bit big-endian comparison: returns true if hash < target.
// Pool targets and hash outputs are both 32-byte BE numbers; first byte
// is most significant.
static bool hash_below_target(const uint8_t *hash, const uint8_t *target, size_t n) {
    for (size_t i = 0; i < n; i++) {
        if (hash[i] < target[i]) return true;
        if (hash[i] > target[i]) return false;
    }
    return false;  // equal → not strictly below
}

// Worker thread: build the real Verus block header from the current
// stratum job, hash it via the official verus_hash_v2 (which runs the
// full Write() haraka512-chain + Finalize2b), compare against the pool
// target, submit on hit. Iterates nonce by mutating the last 8 bytes of
// the 32-byte nonce field — extranonce1 fills the first bytes (assigned
// by pool, never collides between miners on the same pool).
static void worker_loop(int thread_id, int n_threads, MinerShared *shared) {
    std::vector<uint8_t> header;
    header.reserve(2048);
    std::string last_job_id;
    std::vector<uint8_t> en1_bytes;
    uint64_t local_nonce = (uint64_t)thread_id;
    const size_t NONCE_FIELD = 32;  // Verus nonce is 32 bytes

    while (!shared->stop.load(std::memory_order_relaxed)) {
        const StratumJob *job = shared->stratum->current_job();
        const auto &target = shared->stratum->target_bytes();

        if (!job || target.empty()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(80));
            continue;
        }

        // Rebuild header on new job (or first iteration).
        if (job->job_id != last_job_id) {
            last_job_id = job->job_id;
            header.clear();
            append_hex(header, job->version);       // 4 bytes
            append_hex(header, job->prevhash);      // 32 bytes
            append_hex(header, job->merkleroot);    // 32 bytes
            append_hex(header, job->hashreserved);  // 32 bytes
            append_hex(header, job->ntime);         // 4 bytes
            append_hex(header, job->nbits);         // 4 bytes
            // 32-byte nonce slot — fill first bytes with extranonce1, leave rest zero
            en1_bytes.clear();
            append_hex(en1_bytes, shared->stratum->extranonce1());
            size_t nonce_off = header.size();
            for (size_t i = 0; i < NONCE_FIELD; i++) header.push_back(0);
            for (size_t i = 0; i < en1_bytes.size() && i < NONCE_FIELD; i++) {
                header[nonce_off + i] = en1_bytes[i];
            }
            // Solution data (PBaaS extension bytes) — fixed, pool-provided
            append_hex(header, job->solution);
            local_nonce = (uint64_t)thread_id;  // restart counter on new job
        }

        // Nonce slot location is after the 108-byte header prefix
        // (4+32+32+32+4+4 = 108), so nonce is bytes [108 .. 140).
        // We mutate the last 8 bytes of the 32-byte nonce field.
        const size_t NONCE_OFFSET = 4 + 32 + 32 + 32 + 4 + 4;  // = 108
        uint8_t *nonce_iter_ptr = header.data() + NONCE_OFFSET + (NONCE_FIELD - 8);

        // Per-worker key buffer for CL hash + cached seed for incremental refresh
        thread_local std::vector<uint8_t> hashKey_storage;
        thread_local std::vector<uint8_t> cached_seed_storage;
        if (hashKey_storage.empty()) {
            hashKey_storage.assign(VERUSKEYSIZE * 2, 0);
            cached_seed_storage.assign(32, 0);
        }

        for (int n = 0; n < 50000 && !shared->stop.load(std::memory_order_relaxed); n++) {
            memcpy(nonce_iter_ptr, &local_nonce, 8);

            uint8_t hash[32];
            verus_hash_v2_full(hash, header.data(), header.size(),
                              hashKey_storage.data(), VERUSKEYSIZE,
                              cached_seed_storage.data());

            // Verus pools compare hash AS-IS against a big-endian target.
            // If our hash (also BE) is strictly less, it's a valid share.
            if (hash_below_target(hash, target.data(), target.size())) {
                // Format nonce as 32-byte hex (BE).
                char nonce_hex[65];
                for (size_t i = 0; i < NONCE_FIELD; i++) {
                    sprintf(nonce_hex + i * 2, "%02x",
                            header[NONCE_OFFSET + i]);
                }
                nonce_hex[64] = '\0';

                std::lock_guard<std::mutex> lk(shared->submit_mtx);
                printf("[SHARE] thread=%d submitting nonce_tail=%016llx\n",
                       thread_id, (unsigned long long)local_nonce);
                shared->stratum->submit(job->job_id, job->ntime,
                                        std::string(nonce_hex),
                                        job->solution);
            }
            local_nonce += (uint64_t)n_threads;
        }
        shared->total_hashes.fetch_add(50000, std::memory_order_relaxed);
    }
}

static void run_miner(const char *wallet_addr, int n_threads) {
    if (n_threads < 1) n_threads = 1;
    if (n_threads > 64) n_threads = 64;

    printf("== verusminer phase 2.5 — full VerusHash 2.2 + PBaaS mining ==\n\n");

    cvh2_init_once();   // wire CVerusHashV2 statics so verus_hash_v2() works

    const char *addr = wallet_addr ? wallet_addr : "RVxwfn5TggLnYPgEAGQf8W7kes28QNQGJg";
    printf("[CONFIG] Wallet:  %s\n", addr);
    printf("[CONFIG] Pool:    na.luckpool.net:3956\n");
    printf("[CONFIG] Threads: %d\n\n", n_threads);

    StratumConfig scfg;
    scfg.host = "na.luckpool.net";
    scfg.port = 3956;
    scfg.worker = std::string(addr) + ".m5miner";
    scfg.password = "x";

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

    printf("[MINING] Starting %d worker thread(s)...\n\n", n_threads);

    MinerShared shared;
    shared.stratum = &stratum;

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
        const char *addr = (argc > 2) ? argv[2] : nullptr;
        int threads = (argc > 3) ? atoi(argv[3]) : 1;
        run_miner(addr, threads);
    } else {
        run_benchmark(argc > 1 && strcmp(argv[1], "quick") == 0);
    }
    return 0;
}
