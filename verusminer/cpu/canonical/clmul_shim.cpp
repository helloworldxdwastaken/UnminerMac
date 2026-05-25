// clmul_shim.cpp — extern "C" wrapper around the C++-name-mangled
// clmul64() in verus_clhash_portable.cpp, so Swift can call it via
// @_silgen_name without dealing with Itanium mangling.

#include <stdint.h>

extern void clmul64(uint64_t a, uint64_t b, uint64_t *r);

extern "C" {

// Wrap: writes r[0] = low 64 bits of (a ⊗ b), r[1] = high 64 bits,
// where ⊗ is GF(2)[x] carryless multiplication (i.e. _mm_clmulepi64).
void clmul64_wrap(uint64_t a, uint64_t b, uint64_t *r) {
    clmul64(a, b, r);
}

} // extern "C"
