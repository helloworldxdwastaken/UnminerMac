// clhash_neon.cpp — VerusHash 2.2 CL hash using ARMv8 NEON via sse2neon.
//
// The portable path (pure-C emulated CLMUL) is ~100x slower than hardware.
// ARMv8 has vmull_p64 (polynomial multiply) which sse2neon maps to
// _mm_clmulepi64_si128. This file provides verusclhash_sv2_2_neon()
// that uses real NEON instructions for the CL hash core.
//
// Extracted from verus_clhash.cpp, stripped of VerusCoin wallet deps.

#include "crypto/sse2neon.h"
#include <cstdint>
#include <cstring>

// Access the haraka round constants (defined in haraka.c)
extern "C" {
#include "crypto/haraka.h"
}

// ---- CL hash helpers ----

static inline __m128i lazyLengthHash(uint64_t keylength, uint64_t length) {
    const __m128i lengthvector = _mm_set_epi64x(keylength, length);
    return _mm_clmulepi64_si128(lengthvector, lengthvector, 0x10);
}

static inline __m128i precompReduction64_si128(__m128i A) {
    const __m128i C = _mm_cvtsi64_si128((1U<<4)+(1U<<3)+(1U<<1)+(1U<<0));
    __m128i Q2 = _mm_clmulepi64_si128(A, C, 0x01);
    __m128i Q3 = _mm_shuffle_epi8(
        _mm_setr_epi8(0,27,54,45,108,119,90,65,
                      (char)216,(char)195,(char)238,(char)245,(char)180,(char)175,(char)130,(char)153),
        _mm_srli_si128(Q2, 8));
    __m128i Q4 = _mm_xor_si128(Q2, A);
    return _mm_xor_si128(Q3, Q4);
}

static inline uint64_t precompReduction64(__m128i A) {
    __m128i tmp = precompReduction64_si128(A);
    return _mm_cvtsi128_si64(tmp);
}

// CL hash helpers (AES2, MIX2, haraka256/512 functions from haraka.h) 

static __m128i verusclmul_sv2_2_neon(
    __m128i *randomsource, const __m128i buf[4],
    uint64_t keyMask, __m128i **pMoveScratch)
{
    const __m128i pbuf_copy[4] = {
        _mm_xor_si128(buf[0], buf[2]),
        _mm_xor_si128(buf[1], buf[3]),
        buf[2], buf[3]
    };
    const __m128i *pbuf;

    keyMask >>= 4;

    __m128i acc = _mm_load_si128(randomsource + (keyMask + 2));

    for (int64_t i = 0; i < 32; i++) {
        const uint64_t selector = (uint64_t)_mm_cvtsi128_si64(acc);
        __m128i *prand = randomsource + ((selector >> 5) & keyMask);
        __m128i *prandex = randomsource + ((selector >> 32) & keyMask);

        *pMoveScratch++ = prand;
        *pMoveScratch++ = prandex;

        pbuf = pbuf_copy + (selector & 3);

        switch (selector & 0x1c) {
            case 0: {
                __m128i temp1 = _mm_load_si128(prandex);
                __m128i temp2 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
                __m128i add1 = _mm_xor_si128(temp1, temp2);
                __m128i clprod1 = _mm_clmulepi64_si128(add1, add1, 0x10);
                acc = _mm_xor_si128(clprod1, acc);

                __m128i tempa1 = _mm_mulhrs_epi16(acc, temp1);
                __m128i tempa2 = _mm_xor_si128(tempa1, temp1);

                __m128i temp12 = _mm_load_si128(prand);
                _mm_store_si128(prand, tempa2);

                __m128i temp22 = _mm_load_si128(pbuf);
                __m128i add12 = _mm_xor_si128(temp12, temp22);
                __m128i clprod12 = _mm_clmulepi64_si128(add12, add12, 0x10);
                acc = _mm_xor_si128(clprod12, acc);

                __m128i tempb1 = _mm_mulhrs_epi16(acc, temp12);
                __m128i tempb2 = _mm_xor_si128(tempb1, temp12);
                _mm_store_si128(prandex, tempb2);
                break;
            }
            case 4: {
                __m128i temp1 = _mm_load_si128(prand);
                __m128i temp2 = _mm_load_si128(pbuf);
                __m128i add1 = _mm_xor_si128(temp1, temp2);
                __m128i clprod1 = _mm_clmulepi64_si128(add1, add1, 0x10);
                acc = _mm_xor_si128(clprod1, acc);
                __m128i clprod2 = _mm_clmulepi64_si128(temp2, temp2, 0x10);
                acc = _mm_xor_si128(clprod2, acc);

                __m128i tempa1 = _mm_mulhrs_epi16(acc, temp1);
                __m128i tempa2 = _mm_xor_si128(tempa1, temp1);

                __m128i temp12 = _mm_load_si128(prandex);
                _mm_store_si128(prandex, tempa2);

                __m128i temp22 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
                __m128i add12 = _mm_xor_si128(temp12, temp22);
                acc = _mm_xor_si128(add12, acc);

                __m128i tempb1 = _mm_mulhrs_epi16(acc, temp12);
                __m128i tempb2 = _mm_xor_si128(tempb1, temp12);
                _mm_store_si128(prand, tempb2);
                break;
            }
            case 8: {
                __m128i temp1 = _mm_load_si128(prandex);
                __m128i temp2 = _mm_load_si128(pbuf);
                __m128i add1 = _mm_xor_si128(temp1, temp2);
                acc = _mm_xor_si128(add1, acc);

                __m128i tempa1 = _mm_mulhrs_epi16(acc, temp1);
                __m128i tempa2 = _mm_xor_si128(tempa1, temp1);

                __m128i temp12 = _mm_load_si128(prand);
                _mm_store_si128(prand, tempa2);

                __m128i temp22 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
                __m128i add12 = _mm_xor_si128(temp12, temp22);
                __m128i clprod12 = _mm_clmulepi64_si128(add12, add12, 0x10);
                acc = _mm_xor_si128(clprod12, acc);
                __m128i clprod22 = _mm_clmulepi64_si128(temp22, temp22, 0x10);
                acc = _mm_xor_si128(clprod22, acc);

                __m128i tempb1 = _mm_mulhrs_epi16(acc, temp12);
                __m128i tempb2 = _mm_xor_si128(tempb1, temp12);
                _mm_store_si128(prandex, tempb2);
                break;
            }
            case 0xc: {
                __m128i temp1 = _mm_load_si128(prand);
                __m128i temp2 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
                __m128i add1 = _mm_xor_si128(temp1, temp2);

                int32_t divisor = (int32_t)(uint32_t)selector;
                acc = _mm_xor_si128(add1, acc);

                int64_t dividend = _mm_cvtsi128_si64(acc);
                __m128i modulo = _mm_cvtsi32_si128((uint32_t)(dividend % divisor));
                acc = _mm_xor_si128(modulo, acc);

                __m128i tempa1 = _mm_mulhrs_epi16(acc, temp1);
                __m128i tempa2 = _mm_xor_si128(tempa1, temp1);

                if (dividend & 1) {
                    __m128i temp12 = _mm_load_si128(prandex);
                    _mm_store_si128(prandex, tempa2);

                    __m128i temp22 = _mm_load_si128(pbuf);
                    __m128i add12 = _mm_xor_si128(temp12, temp22);
                    __m128i clprod12 = _mm_clmulepi64_si128(add12, add12, 0x10);
                    acc = _mm_xor_si128(clprod12, acc);
                    __m128i clprod22 = _mm_clmulepi64_si128(temp22, temp22, 0x10);
                    acc = _mm_xor_si128(clprod22, acc);

                    __m128i tempb1 = _mm_mulhrs_epi16(acc, temp12);
                    __m128i tempb2 = _mm_xor_si128(tempb1, temp12);
                    _mm_store_si128(prand, tempb2);
                } else {
                    __m128i tempb3 = _mm_load_si128(prandex);
                    _mm_store_si128(prandex, tempa2);
                    _mm_store_si128(prand, tempb3);
                    __m128i tempb4 = _mm_load_si128(pbuf);
                    acc = _mm_xor_si128(tempb4, acc);
                }
                break;
            }
            case 0x10: {
                const __m128i *rcp = prand;
                __m128i tmp;

                __m128i temp1 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
                __m128i temp2 = _mm_load_si128(pbuf);

                AES2(temp1, temp2, 0);
                MIX2(temp1, temp2);

                AES2(temp1, temp2, 4);
                MIX2(temp1, temp2);

                AES2(temp1, temp2, 8);
                MIX2(temp1, temp2);

                acc = _mm_xor_si128(temp1, acc);
                acc = _mm_xor_si128(temp2, acc);

                __m128i tempa1 = _mm_load_si128(prand);
                __m128i tempa2 = _mm_mulhrs_epi16(acc, tempa1);
                __m128i tempa3 = _mm_xor_si128(tempa1, tempa2);

                __m128i tempa4 = _mm_load_si128(prandex);
                _mm_store_si128(prandex, tempa3);
                _mm_store_si128(prand, tempa4);
                break;
            }
            case 0x14: {
                const __m128i *buftmp = pbuf - (((selector & 1) << 1) - 1);
                __m128i tmp;

                uint64_t rounds = selector >> 61;
                __m128i *rcp = prand;
                uint64_t aesround = 0;
                __m128i onekey;

                do {
                    if (selector & (((uint64_t)0x10000000) << rounds)) {
                        onekey = _mm_load_si128(rcp++);
                        __m128i temp2 = _mm_load_si128(rounds & 1 ? pbuf : buftmp);
                        __m128i add1 = _mm_xor_si128(onekey, temp2);
                        __m128i clprod1 = _mm_clmulepi64_si128(add1, add1, 0x10);
                        acc = _mm_xor_si128(clprod1, acc);
                    } else {
                        onekey = _mm_load_si128(rcp++);
                        __m128i temp2 = _mm_load_si128(rounds & 1 ? buftmp : pbuf);
                        uint64_t roundidx = aesround++ << 2;
                        AES2(onekey, temp2, (int)roundidx);

                        MIX2(onekey, temp2);

                        acc = _mm_xor_si128(onekey, acc);
                        acc = _mm_xor_si128(temp2, acc);
                    }
                } while (rounds--);

                __m128i tempa1 = _mm_load_si128(prand);
                __m128i tempa2 = _mm_mulhrs_epi16(acc, tempa1);
                __m128i tempa3 = _mm_xor_si128(tempa1, tempa2);

                __m128i tempa4 = _mm_load_si128(prandex);
                _mm_store_si128(prandex, tempa3);
                _mm_store_si128(prand, tempa4);
                break;
            }
            case 0x18: {
                const __m128i *buftmp = pbuf - (((selector & 1) << 1) - 1);
                __m128i tmp;

                uint64_t rounds = selector >> 61;
                __m128i *rcp = prand;
                __m128i onekey;

                do {
                    if (selector & (((uint64_t)0x10000000) << rounds)) {
                        onekey = _mm_load_si128(rcp++);
                        __m128i temp2 = _mm_load_si128(rounds & 1 ? pbuf : buftmp);
                        onekey = _mm_xor_si128(onekey, temp2);
                        int32_t divisor = (int32_t)(uint32_t)selector;
                        int64_t dividend = _mm_cvtsi128_si64(onekey);
                        __m128i modulo = _mm_cvtsi32_si128((uint32_t)(dividend % divisor));
                        acc = _mm_xor_si128(modulo, acc);
                    } else {
                        onekey = _mm_load_si128(rcp++);
                        __m128i temp2 = _mm_load_si128(rounds & 1 ? buftmp : pbuf);
                        __m128i add1 = _mm_xor_si128(onekey, temp2);
                        onekey = _mm_clmulepi64_si128(add1, add1, 0x10);
                        __m128i clprod2 = _mm_mulhrs_epi16(acc, onekey);
                        acc = _mm_xor_si128(clprod2, acc);
                    }
                } while (rounds--);

                __m128i tempa3 = _mm_load_si128(prandex);
                __m128i tempa4 = _mm_xor_si128(tempa3, acc);
                _mm_store_si128(prandex, onekey);
                _mm_store_si128(prand, tempa4);
                break;
            }
            case 0x1c: {
                __m128i temp1 = _mm_load_si128(pbuf);
                __m128i temp2 = _mm_load_si128(prandex);
                __m128i add1 = _mm_xor_si128(temp1, temp2);
                __m128i clprod1 = _mm_clmulepi64_si128(add1, add1, 0x10);
                acc = _mm_xor_si128(clprod1, acc);

                __m128i tempa1 = _mm_mulhrs_epi16(acc, temp2);
                __m128i tempa2 = _mm_xor_si128(tempa1, temp2);

                __m128i tempa3 = _mm_load_si128(prand);
                _mm_store_si128(prand, tempa2);

                acc = _mm_xor_si128(tempa3, acc);
                __m128i temp4 = _mm_load_si128(pbuf - (((selector & 1) << 1) - 1));
                acc = _mm_xor_si128(temp4, acc);
                __m128i tempb1 = _mm_mulhrs_epi16(acc, tempa3);
                __m128i tempb2 = _mm_xor_si128(tempb1, tempa3);
                _mm_store_si128(prandex, tempb2);
                break;
            }
        }
    }
    return acc;
}

// ---- Public API ----

extern "C"
uint64_t verusclhash_sv2_2_neon(
    void *random, const unsigned char buf[64],
    uint64_t keyMask, void **pMoveScratch_out)
{
    __m128i *rs64 = (__m128i *)random;
    const __m128i *string = (const __m128i *)buf;

    __m128i acc = verusclmul_sv2_2_neon(rs64, string, keyMask, (__m128i **)pMoveScratch_out);
    acc = _mm_xor_si128(acc, lazyLengthHash(1024, 64));
    return precompReduction64(acc);
}
