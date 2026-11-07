/*
 * SDL_StepUTF8(&p, NULL) on a C string (src/stdlib/SDL_string.c StepUTF8 with slen = 4).
 *
 * The header says the function "will blindly read until it sees the NULL char". The string sits
 * in a heap object of exactly strlen + 1 bytes, so reading past the terminator is out of bounds.
 * F-004 (the 3- and 4-byte branches read str[1..3] before checking them) fails this on the base
 * tree. It also checks the result against the reference decoder, as steputf8_len does.
 *
 * CBMC-SOURCES: src/stdlib/SDL_string.c
 * CBMC-BOUND: strlen < 5, every byte value
 * CBMC-UNWIND: 7
 */
#include "cbmc_common.h"

#define MAX 5

void harness(void)
{
    size_t len;
    const char *s = nondet_cstr(MAX, &len);
    const char *p = s;

    const Uint32 r = SDL_StepUTF8(&p, NULL);

    const size_t advanced = (size_t)(p - s);
    Uint32 cp = 0;
    /* The terminator is never part of a multi-byte sequence, so this sees the same input. */
    const int n = ref_utf8_decode((const unsigned char *)s, len + 1, &cp);
    if (len == 0) {
        CHECK(r == 0 && advanced == 0, "StepUTF8(NULL): stops at the terminator");
    } else if (n > 0) {
        CHECK(r == cp && advanced == (size_t)n, "StepUTF8(NULL): decodes a well-formed sequence");
    } else {
        CHECK(r == SDL_INVALID_UNICODE_CODEPOINT && advanced == 1,
              "StepUTF8(NULL): ill-formed input gives U+FFFD and advances one byte");
    }
}
