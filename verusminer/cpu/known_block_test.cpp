// known_block_test — verify CVerusHashV2 produces the correct hash for a
// REAL Verus block from the chain. Block 4080279, hash:
//   00000000000069f6d238c07844196157c11808c12239d8265a6afe70652993a0
//
// Try several input variations to identify the correct serialization.

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <sstream>
#include <vector>

extern "C" {
#include "haraka_portable.h"
#include "crypto/haraka.h"
extern void load_constants(void);
extern void load_constants_port(void);
}

#include "canonical/verus_hash.h"

static std::vector<uint8_t> hex_to_bytes(const std::string &hex) {
    std::vector<uint8_t> out;
    out.reserve(hex.size() / 2);
    for (size_t i = 0; i + 1 < hex.size(); i += 2) {
        unsigned v;
        sscanf(hex.c_str() + i, "%2x", &v);
        out.push_back((uint8_t)v);
    }
    return out;
}

static void print_hex(const char *label, const uint8_t *b, size_t n) {
    printf("  %-30s", label);
    for (size_t i = 0; i < n; i++) printf("%02x", b[i]);
    printf("\n");
}

static void print_hex_rev(const char *label, const uint8_t *b, size_t n) {
    printf("  %-30s", label);
    for (int i = n - 1; i >= 0; i--) printf("%02x", b[i]);
    printf("\n");
}

static bool try_variant(const char *label, const std::vector<uint8_t> &input,
                        const uint8_t *expected_le) {
    CVerusHashV2 vh2(SOLUTION_VERUSHHASH_V2_2);
    vh2.Reset();
    vh2.Write(input.data(), input.size());
    uint8_t out[32];
    vh2.Finalize2b(out);
    bool match = memcmp(out, expected_le, 32) == 0;
    printf("\n[%s — %zu bytes]\n", label, input.size());
    print_hex("output (raw LE):", out, 32);
    print_hex_rev("output (BE display):", out, 32);
    printf("  %s\n", match ? "✓ MATCH" : "✗ no");

    // Also try Hash() (one-shot)
    uint8_t out2[32];
    CVerusHashV2::Hash(out2, input.data(), input.size());
    match = memcmp(out2, expected_le, 32) == 0;
    print_hex("Hash() raw LE:", out2, 32);
    printf("  %s (one-shot Hash)\n", match ? "✓ MATCH" : "✗ no");
    return match;
}

int main() {
    load_constants();
    load_constants_port();
    CVerusHashV2::init();

    std::ifstream f("/tmp/known_block_hash_input.hex");
    std::stringstream ss; ss << f.rdbuf();
    std::string hex = ss.str();
    while (!hex.empty() && (hex.back() == '\n' || hex.back() == ' ')) hex.pop_back();
    auto full = hex_to_bytes(hex);
    printf("Total input from /tmp: %zu bytes\n", full.size());

    const char *expected_be = "00000000000069f6d238c07844196157c11808c12239d8265a6afe70652993a0";
    auto exp_be = hex_to_bytes(expected_be);
    std::vector<uint8_t> exp_le(exp_be.rbegin(), exp_be.rend());
    printf("Expected (BE display):  %s\n", expected_be);
    printf("Expected (LE storage):  ");
    for (auto b : exp_le) printf("%02x", b);
    printf("\n");

    // Variant A: full header + varint + solution (1487 bytes)
    try_variant("header+varint+full_soln", full, exp_le.data());

    // Variant B: header only (140 bytes)
    std::vector<uint8_t> header_only(full.begin(), full.begin() + 140);
    try_variant("header only", header_only, exp_le.data());

    // Variant C: header + soln (skip the 3-byte varint)
    std::vector<uint8_t> hdr_soln_noviarint;
    hdr_soln_noviarint.insert(hdr_soln_noviarint.end(), full.begin(), full.begin() + 140);
    hdr_soln_noviarint.insert(hdr_soln_noviarint.end(), full.begin() + 143, full.end());
    try_variant("header + soln (NO varint)", hdr_soln_noviarint, exp_le.data());

    // Variant D: header + ONLY the first byte of soln (just version byte 0x07)
    std::vector<uint8_t> hdr_v;
    hdr_v.insert(hdr_v.end(), full.begin(), full.begin() + 140);
    hdr_v.push_back(0x07);  // solution version
    try_variant("header + 0x07 version byte", hdr_v, exp_le.data());

    return 0;
}
