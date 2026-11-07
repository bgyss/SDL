/*
 * SDL_strlcpy (src/stdlib/SDL_string.c, the !HAVE_STRLCPY implementation).
 * Contract (include/SDL3/SDL_stdinc.h): copies at most maxlen - 1 bytes, terminates dst when
 * maxlen > 0, returns strlen(src).
 *
 * CBMC-SOURCES: src/stdlib/SDL_string.c
 * CBMC-BOUND: strlen(src) < 6, dst buffer <= 6 bytes, maxlen <= dst buffer
 * CBMC-UNWIND: 8
 */
#include "cbmc_common.h"

#define MAX 6

void harness(void)
{
    size_t srclen;
    const char *src = nondet_cstr(MAX, &srclen);
    const size_t cap = nondet_size_t();
    ASSUME(cap <= MAX);
    char *dst = nondet_buffer(cap);
    char before[MAX];
    for (size_t i = 0; i < cap; ++i) {
        before[i] = dst[i];
    }
    const size_t maxlen = nondet_size_t();
    ASSUME(maxlen <= cap);

    const size_t r = SDL_strlcpy(dst, src, maxlen);

    CHECK(r == srclen, "strlcpy: returns strlen(src)");
    const size_t n = maxlen ? SDL_min(srclen, maxlen - 1) : 0;
    for (size_t i = 0; i < cap; ++i) {
        if (maxlen > 0 && i < n) {
            CHECK(dst[i] == src[i], "strlcpy: dst holds a prefix of src");
        } else if (maxlen > 0 && i == n) {
            CHECK(dst[i] == '\0', "strlcpy: dst is terminated after the copied prefix");
        } else {
            CHECK(dst[i] == before[i], "strlcpy: nothing written past the terminator");
        }
    }
}
