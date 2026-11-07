/*
 * SDL_strlcat (src/stdlib/SDL_string.c, the !HAVE_STRLCAT implementation).
 * Contract (include/SDL3/SDL_stdinc.h): dst already holds a NUL-terminated string; appends up to
 * maxlen - strlen(dst) - 1 bytes of src and terminates; returns strlen(dst) + strlen(src).
 *
 * dst is a buffer of `cap` bytes holding a string of length dstlen < cap; maxlen <= cap.
 *
 * CBMC-SOURCES: src/stdlib/SDL_string.c
 * CBMC-BOUND: strlen(src) < 5, dst buffer <= 6 bytes, maxlen <= dst buffer
 * CBMC-UNWIND: 8
 */
#include "cbmc_common.h"

#define SRCMAX 5
#define CAP 6

void harness(void)
{
    size_t srclen;
    const char *src = nondet_cstr(SRCMAX, &srclen);
    const size_t cap = nondet_size_t();
    ASSUME(cap >= 1 && cap <= CAP);
    char *dst = nondet_buffer(cap);
    const size_t dstlen = nondet_size_t();
    ASSUME(dstlen < cap);
    for (size_t i = 0; i < dstlen; ++i) {
        ASSUME(dst[i] != '\0');
    }
    dst[dstlen] = '\0';
    char before[CAP];
    for (size_t i = 0; i < cap; ++i) {
        before[i] = dst[i];
    }
    const size_t maxlen = nondet_size_t();
    ASSUME(maxlen <= cap);

    const size_t r = SDL_strlcat(dst, src, maxlen);

    CHECK(r == dstlen + srclen, "strlcat: returns strlen(dst) + strlen(src)");
    /* When dst is already at least maxlen long nothing is appended. */
    const size_t total = (dstlen < maxlen) ? SDL_min(dstlen + srclen, maxlen - 1) : dstlen;
    for (size_t i = 0; i < cap; ++i) {
        if (i < dstlen) {
            CHECK(dst[i] == before[i], "strlcat: the original string is kept");
        } else if (i < total) {
            CHECK(dst[i] == src[i - dstlen], "strlcat: src is appended");
        } else if (i == total) {
            CHECK(dst[i] == '\0', "strlcat: the result is terminated");
        } else {
            CHECK(dst[i] == before[i], "strlcat: nothing written past the terminator");
        }
    }
}
