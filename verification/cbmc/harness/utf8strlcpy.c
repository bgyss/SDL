/*
 * SDL_utf8strlcpy (src/stdlib/SDL_string.c).
 *
 * Contract (include/SDL3/SDL_stdinc.h): like SDL_strlcpy, but never splits a UTF-8 character;
 * returns the number of bytes written, not counting the terminator. Checked:
 *   - memory safety for any src and any dst_bytes up to the buffer size
 *   - dst_bytes == 0 writes nothing and returns 0
 *   - dst = src[0..r) followed by NUL, r < dst_bytes, nothing written past dst[r]
 *   - if src is valid UTF-8 (no NUL inside, by the reference decoder), dst is valid UTF-8 and
 *     maximal: either all of src was copied or the next character does not fit.
 * F-007 (a truncated first character was kept) fails this on the base tree.
 *
 * CBMC-SOURCES: src/stdlib/SDL_string.c
 * CBMC-BOUND: strlen(src) < 6, dst buffer <= 6 bytes
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
    const size_t dst_bytes = nondet_size_t();
    ASSUME(dst_bytes <= cap);

    const size_t r = SDL_utf8strlcpy(dst, src, dst_bytes);

    if (dst_bytes == 0) {
        CHECK(r == 0, "utf8strlcpy: dst_bytes == 0 returns 0");
    } else {
        CHECK(r < dst_bytes && r <= srclen, "utf8strlcpy: result fits and is no longer than src");
    }
    for (size_t i = 0; i < cap; ++i) {
        if (dst_bytes > 0 && i < r) {
            CHECK(dst[i] == src[i], "utf8strlcpy: dst holds a prefix of src");
        } else if (dst_bytes > 0 && i == r) {
            CHECK(dst[i] == '\0', "utf8strlcpy: dst is terminated");
        } else {
            CHECK(dst[i] == before[i], "utf8strlcpy: nothing written past the terminator");
        }
    }

    if (dst_bytes > 0 && ref_utf8_valid_nonul((const unsigned char *)src, srclen)) {
        CHECK(ref_utf8_valid_nonul((const unsigned char *)dst, r),
              "utf8strlcpy: valid input gives valid output (no split character)");
        Uint32 cp;
        const int next = (r < srclen) ? ref_utf8_decode((const unsigned char *)src + r, srclen - r, &cp) : 0;
        CHECK(r == srclen || r + (size_t)next > dst_bytes - 1,
              "utf8strlcpy: copies as many whole characters as fit");
    }
}
