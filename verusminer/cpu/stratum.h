// stratum.h — Verus stratum v1 client for LuckPool
//
// Handles: TCP connect, mining.subscribe, mining.authorize,
// mining.notify (job parsing), mining.submit, mining.set_difficulty,
// mining.set_target, accepted/rejected share counting.
//
// No external JSON library — simple string parsing since stratum
// messages are well-structured single-line JSON.
#pragma once

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

// Verus stratum mining.notify format (9 fields, header-direct):
// [job_id, version, prevhash, merkleroot, hashreserved (finalsaplingroot),
//  ntime, nbits, clean_jobs, solution]
// All hex except clean_jobs (bool). Bytes are sent in wire-LE order ready
// for direct concatenation into the block header.
struct StratumJob {
    std::string job_id;        // opaque pool-side ID
    std::string version;       // 4 bytes (hex)
    std::string prevhash;      // 32 bytes (hex)
    std::string merkleroot;    // 32 bytes (hex)
    std::string hashreserved;  // 32 bytes (hex) — final sapling root
    std::string ntime;         // 4 bytes (hex)
    std::string nbits;         // 4 bytes (hex)
    std::string solution;      // variable (hex) — includes PBaaS extensions
    bool clean_jobs = false;
};

struct StratumConfig {
    std::string host;
    int port;
    std::string worker;   // wallet.workername
    std::string password;
};

class StratumClient {
public:
    StratumClient(const StratumConfig &cfg);
    ~StratumClient();

    bool connect();
    void disconnect();
    void subscribe();
    void authorize();
    // Authorize an extra worker (used for the dev-fee address — pool supports
    // multiple authorized workers per session).
    void authorize_extra(const std::string &worker, const std::string &password);
    // Verus mining.submit: [worker, job_id, ntime, nonce, solution] (5 params)
    void submit(const std::string &job_id, const std::string &ntime,
                const std::string &nonce_hex, const std::string &solution_hex);
    // Same as submit() but lets the caller override which authorized worker
    // gets credited (dev-fee rotation routes to a different worker name).
    void submit_with_worker(const std::string &worker,
                            const std::string &job_id, const std::string &ntime,
                            const std::string &nonce_hex, const std::string &solution_hex);
    bool receive();  // returns true if new data arrived

    const StratumJob *current_job() const { return has_job ? &job : nullptr; }
    bool is_authorized() const { return authorized; }
    uint64_t difficulty() const { return diff; }
    // 32-byte target (big-endian). Empty until first mining.set_target.
    const std::vector<uint8_t> &target_bytes() const { return target; }
    const std::string &extranonce1() const { return en1; }
    int extranonce2_size() const { return en2_size; }
    uint64_t accepted() const { return accepted_count; }
    uint64_t rejected() const { return rejected_count; }

private:
    void process_line(const std::string &line);
    void send(const std::string &msg);
    std::string json_get_string(const std::string &json, const std::string &key);
    int64_t json_get_int(const std::string &json, const std::string &key);
    bool json_get_bool(const std::string &json, const std::string &key);
    std::vector<std::string> json_get_array(const std::string &json, const std::string &key);

    StratumConfig cfg;
    int sockfd = -1;
    int msg_id = 1;
    std::string recv_buf;

    std::string en1;
    int en2_size = 8;
    uint64_t en2_counter = 0;
    uint64_t diff = 1;
    std::vector<uint8_t> target;  // 32 bytes BE; empty until first set_target
    bool authorized = false;
    bool has_job = false;
    StratumJob job;
    // Outstanding submit IDs → for matching response back to accepted/rejected
    std::vector<int> pending_submits;
    uint64_t accepted_count = 0;
    uint64_t rejected_count = 0;
};
