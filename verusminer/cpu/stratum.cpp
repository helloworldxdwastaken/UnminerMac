// stratum.cpp — Verus stratum v1 client implementation

#include "stratum.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>

// ---- Construction / Destruction ----

StratumClient::StratumClient(const StratumConfig &cfg) : cfg(cfg) {}

StratumClient::~StratumClient() { disconnect(); }

// ---- Socket I/O ----

bool StratumClient::connect() {
    sockfd = socket(AF_INET, SOCK_STREAM, 0);
    if (sockfd < 0) { perror("socket"); return false; }

    struct hostent *he = gethostbyname(cfg.host.c_str());
    if (!he) { fprintf(stderr, "DNS lookup failed for %s\n", cfg.host.c_str()); return false; }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(cfg.port);
    memcpy(&addr.sin_addr, he->h_addr_list[0], he->h_length);

    if (::connect(sockfd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect");
        close(sockfd);
        sockfd = -1;
        return false;
    }

    // Non-blocking for receive()
    int flags = fcntl(sockfd, F_GETFL, 0);
    fcntl(sockfd, F_SETFL, flags | O_NONBLOCK);

    printf("[STRATUM] Connected to %s:%d\n", cfg.host.c_str(), cfg.port);
    return true;
}

void StratumClient::disconnect() {
    if (sockfd >= 0) { close(sockfd); sockfd = -1; }
}

void StratumClient::send(const std::string &msg) {
    if (sockfd < 0) return;
    printf("[SEND] %s\n", msg.c_str());
    ::send(sockfd, msg.c_str(), msg.size(), 0);
}

// ---- Stratum protocol ----

void StratumClient::subscribe() {
    char buf[256];
    snprintf(buf, sizeof(buf),
        "{\"id\":%d,\"method\":\"mining.subscribe\",\"params\":[\"verusminer/1.0\"]}\n",
        msg_id++);
    send(buf);
}

void StratumClient::authorize() {
    char buf[512];
    snprintf(buf, sizeof(buf),
        "{\"id\":%d,\"method\":\"mining.authorize\",\"params\":[\"%s\",\"%s\"]}\n",
        msg_id++, cfg.worker.c_str(), cfg.password.c_str());
    send(buf);
}

void StratumClient::submit(const std::string &job_id, const std::string &extranonce2,
                           const std::string &ntime, const std::string &nonce_hex) {
    char buf[1024];
    snprintf(buf, sizeof(buf),
        "{\"id\":%d,\"method\":\"mining.submit\",\"params\":[\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"]}\n",
        msg_id++, cfg.worker.c_str(), job_id.c_str(),
        extranonce2.c_str(), ntime.c_str(), nonce_hex.c_str());
    send(buf);
}

// ---- Message receive + dispatch ----

bool StratumClient::receive() {
    if (sockfd < 0) return false;

    char buf[8192];
    int n = (int)recv(sockfd, buf, sizeof(buf) - 1, 0);
    if (n <= 0) return false;

    buf[n] = '\0';
    recv_buf += buf;

    // Process complete lines
    size_t pos;
    while ((pos = recv_buf.find('\n')) != std::string::npos) {
        std::string line = recv_buf.substr(0, pos);
        recv_buf.erase(0, pos + 1);
        if (!line.empty()) process_line(line);
    }
    return true;
}

void StratumClient::process_line(const std::string &line) {
    printf("[RECV] %s\n", line.c_str());

    // Check for "method" → server push (notify, set_difficulty)
    std::string method = json_get_string(line, "\"method\"");
    if (!method.empty()) {
        if (method == "mining.notify") {
            // Parse notify params
            job.job_id        = json_get_string(line, "\"params\"");
            job.version       = json_get_string(line, "\"params\"");
            job.prevhash      = json_get_string(line, "\"params\"");
            // Skip coinbase1/coinbase2, they come after merkle branches in some formats
            // Try to extract from the raw line
            {
                auto arr = json_get_array(line, "\"params\"");
                if (arr.size() >= 10) {
                    job.job_id   = arr[0];
                    job.version  = arr[1];
                    job.prevhash = arr[2];
                    // arr[3] = transactions (array of hex strings)
                    job.coinbase1 = arr[4];
                    job.coinbase2 = arr[5];
                    // arr[6] = merkle branches (JSON array)
                    job.ntime    = arr[8];
                    job.nbits    = arr[9];
                    job.clean_jobs = (arr.size() > 10) && (arr[10] == "true" || arr[10] == "1");
                }
                // Extract merkle branches from raw
                size_t mb_start = line.find("\"params\"");
                if (mb_start != std::string::npos) {
                    // Find the 7th element (index 6) in the params array
                    // Simple approach: find the 6th comma after "params":[
                    int bracket_depth = 0;
                    int param_idx = 0;
                    for (size_t i = line.find("[\"", mb_start); i < line.size(); i++) {
                        if (line[i] == '[') bracket_depth++;
                        else if (line[i] == ']') bracket_depth--;
                        else if (line[i] == ',' && bracket_depth == 0) param_idx++;
                        // Hard to parse generically without a real parser
                    }
                }
            }
            has_job = true;
            en2_counter = 0;  // reset extranonce2 on new job
            printf("[JOB] id=%s prev=%s... ntime=%s nbits=%s clean=%d\n",
                   job.job_id.c_str(), job.prevhash.substr(0, 16).c_str(),
                   job.ntime.c_str(), job.nbits.c_str(), job.clean_jobs);

        } else if (method == "mining.set_difficulty") {
            // params: [difficulty]
            std::string d_str = json_get_string(line, "\"params\"");
            if (d_str.empty()) {
                d_str = json_get_string(line, "params");
            }
            // Try to parse as number from raw
            size_t dp = line.find("\"params\"");
            if (dp != std::string::npos) {
                dp = line.find('[', dp);
                if (dp != std::string::npos) {
                    diff = (uint64_t)strtoull(line.c_str() + dp + 1, nullptr, 10);
                }
            }
            printf("[DIFF] set to %llu\n", (unsigned long long)diff);

        } else if (method == "mining.set_extranonce") {
            printf("[ENONCE] extranonce update received\n");
        }
        return;
    }

    // Check for "result" → response to our request
    std::string result = json_get_string(line, "\"result\"");
    if (!result.empty() && result != "null") {
        // mining.subscribe response: [["mining.notify","mining.set_difficulty"], "EXTRA1", EXTRA2SIZE]
        if (result[0] == '[') {
            // Extract extranonce1 (3rd element in result array)
            size_t p1 = result.find(',');
            if (p1 != std::string::npos) {
                size_t p2 = result.find(',', p1 + 1);
                if (p2 != std::string::npos) {
                    size_t q1 = result.find('"', p1 + 1);
                    size_t q2 = result.find('"', q1 + 1);
                    if (q1 != std::string::npos && q2 != std::string::npos) {
                        en1 = result.substr(q1 + 1, q2 - q1 - 1);
                    }
                    // extranonce2 size
                    size_t e2_start = result.find_first_of("0123456789", p2 + 1);
                    if (e2_start != std::string::npos) {
                        en2_size = (int)strtol(result.c_str() + e2_start, nullptr, 10);
                    }
                    printf("[SUBSCRIBE] extranonce1=%s en2_size=%d\n", en1.c_str(), en2_size);
                }
            }
        }
        // mining.authorize response
        else if (result == "true") {
            printf("[AUTH] Authorized!\n");
            authorized = true;
        }
        return;
    }

    // Check for "error"
    std::string error = json_get_string(line, "\"error\"");
    if (!error.empty() && error != "null") {
        printf("[ERROR] %s\n", error.c_str());
    }
}

// ---- Simple JSON helpers (no library — just regex-free string search) ----

std::string StratumClient::json_get_string(const std::string &json, const std::string &key) {
    // Find "key": in the JSON string
    std::string search = key + "\"";
    size_t pos = json.find(search);
    if (pos == std::string::npos) {
        // Try without quotes: key:
        search = key + ":";
        pos = json.find(search);
        if (pos == std::string::npos) return "";
    }

    // Skip past '"key":' or 'key:'
    pos = json.find(':', pos);
    if (pos == std::string::npos) return "";
    pos++;

    // Skip whitespace
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t')) pos++;

    if (pos >= json.size()) return "";

    // If quote-delimited string
    if (json[pos] == '"') {
        pos++;
        size_t end = json.find('"', pos);
        if (end == std::string::npos) return "";
        // Handle escaped quotes
        while (end > 0 && json[end - 1] == '\\') end = json.find('"', end + 1);
        return json.substr(pos, end - pos);
    }

    // If array or object
    if (json[pos] == '[' || json[pos] == '{') {
        char open = json[pos];
        char close = (open == '[') ? ']' : '}';
        int depth = 1;
        size_t end = pos + 1;
        while (end < json.size() && depth > 0) {
            if (json[end] == open) depth++;
            else if (json[end] == close) depth--;
            end++;
        }
        return json.substr(pos, end - pos);
    }

    // If number or bool
    size_t end = pos;
    while (end < json.size() && json[end] != ',' && json[end] != '}' && json[end] != ']'
           && json[end] != '\n' && json[end] != '\r') end++;
    return json.substr(pos, end - pos);
}

int64_t StratumClient::json_get_int(const std::string &json, const std::string &key) {
    std::string s = json_get_string(json, key);
    if (s.empty()) return 0;
    return strtoll(s.c_str(), nullptr, 10);
}

bool StratumClient::json_get_bool(const std::string &json, const std::string &key) {
    std::string s = json_get_string(json, key);
    return s == "true";
}

std::vector<std::string> StratumClient::json_get_array(const std::string &json, const std::string &key) {
    std::vector<std::string> result;
    std::string arr_str = json_get_string(json, key);
    if (arr_str.empty() || arr_str[0] != '[') return result;

    int depth = 0;
    size_t start = 1;  // skip opening [
    for (size_t i = 1; i < arr_str.size() - 1; i++) {
        if (arr_str[i] == '[' || arr_str[i] == '{') depth++;
        else if (arr_str[i] == ']' || arr_str[i] == '}') depth--;
        else if (arr_str[i] == ',' && depth == 0) {
            std::string elem = arr_str.substr(start, i - start);
            // Strip quotes
            if (elem.size() >= 2 && elem.front() == '"' && elem.back() == '"')
                elem = elem.substr(1, elem.size() - 2);
            result.push_back(elem);
            start = i + 1;
        }
    }
    // Last element
    std::string last = arr_str.substr(start, arr_str.size() - start - 1);
    if (last.size() >= 2 && last.front() == '"' && last.back() == '"')
        last = last.substr(1, last.size() - 2);
    if (!last.empty()) result.push_back(last);

    return result;
}
