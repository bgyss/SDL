/*
 * SDL_StepUTF8(&p, &len) with an explicit length (src/stdlib/SDL_string.c StepUTF8).
 *
 * The buffer is exactly `len` bytes with arbitrary contents and no terminator, so this proves the
 * decoder never reads outside [p, p + len). Functionally, it checks SDL against the reference
 * decoder in cbmc_common.h (Unicode Table 3-7), for every byte sequence up to the bound:
 *   - a well-formed sequence of n bytes: returns its scalar value, advances n, len -= n
 *   - a NUL first byte, or len == 0: returns 0, does not advance
 *   - anything else: returns U+FFFD and advances exactly one byte
 * This is the CBMC counterpart of the Lean model in verification/lean (Phase 2), checked on the
 * C itself rather than by differential testing. F-005 (code points above U+10FFFF) fails it on
 * the base tree.
 *
 * CBMC-SOURCES: src/stdlib/SDL_string.c
 * CBMC-BOUND: buffer of 0..5 bytes, every byte value
 * CBMC-UNWIND: 7
 */
#include "cbmc_common.h"

#define MAX 5

void harness(void)
{
    size_t len = nondet_size_t();
    ASSUME(len <= MAX);
    const char *buf = nondet_buffer(len);
    const char *p = buf;
    size_t left = len;

    const Uint32 r = SDL_StepUTF8(&p, &left);

    const size_t advanced = (size_t)(p - buf);
    CHECK(advanced <= len, "StepUTF8: never advances past the length");
    CHECK(left == len - advanced, "StepUTF8: len shrinks by exactly the bytes consumed");

    Uint32 cp = 0;
    const int n = ref_utf8_decode((const unsigned char *)buf, len, &cp);
    if (len == 0 || buf[0] == '\0') {
        CHECK(r == 0 && advanced == 0, "StepUTF8: stops at a NUL or at len == 0");
    } else if (n > 0) {
        CHECK(r == cp, "StepUTF8: decodes a well-formed sequence to its scalar value");
        CHECK(advanced == (size_t)n, "StepUTF8: consumes a whole well-formed sequence");
    } else {
        CHECK(r == SDL_INVALID_UNICODE_CODEPOINT, "StepUTF8: ill-formed input gives U+FFFD");
        CHECK(advanced == 1, "StepUTF8: ill-formed input advances one byte");
    }
}
