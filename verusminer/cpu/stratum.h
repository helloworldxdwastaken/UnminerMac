// stratum.h — Verus stratum v1 client for LuckPool
//
// Handles: TCP connect, mining.subscribe, mining.authorize,
// mining.notify (job parsing), mining.submit, set_difficulty.
// No external JSON library — simple string parsing since stratum
// messages are well-structured single-line JSON.
#pragma once

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

struct StratumJob {
    std::string job_id;
    std::string version;
    std::string prevhash;
    std::string coinbase1;
    std::string coinbase2;
    std::vector<std::string> merkle_branches;
    std::string ntime;
    std::string nbits;
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
    void submit(const std::string &job_id, const std::string &extranonce2,
                const std::string &ntime, const std::string &nonce_hex);
    void submit_with_worker(const std::string &worker,
                const std::string &job_id, const std::string &extranonce2,
                const std::string &ntime, const std::string &nonce_hex);
    bool receive();  // returns true if new data arrived

    const StratumJob *current_job() const { return has_job ? &job : nullptr; }
    bool is_authorized() const { return authorized; }
    uint64_t difficulty() const { return diff; }
    const std::string &extranonce1() const { return en1; }
    int extranonce2_size() const { return en2_size; }

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
    bool authorized = false;
    bool has_job = false;
    StratumJob job;
};
