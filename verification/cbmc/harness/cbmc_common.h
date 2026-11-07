/*
 * Shared helpers for the CBMC harnesses in verification/cbmc/harness/.
 *
 * Each harness is a function `harness(void)` that CBMC explores symbolically: every input made
 * by a nondet_* helper takes every value at once, up to the bounds the harness states. A
 * result is "for all inputs within the bounds", and run.sh passes --unwinding-assertions so a
 * loop that would run past its unwind bound is itself reported as a failure instead of being
 * silently cut short.
 *
 * Harnesses include SDL_internal.h, exactly as the code under test does, so the dynapi renames
 * (SDL_strlcpy -> SDL_strlcpy_REAL, ...) apply on both sides.
 */
#ifndef CBMC_COMMON_H
#define CBMC_COMMON_H

#include "SDL_internal.h"

#include <stdlib.h>

#define CHECK(cond, what) __CPROVER_assert((cond), (what))
#define ASSUME(cond) __CPROVER_assume(cond)

size_t nondet_size_t(void);
int nondet_int(void);
long nondet_long(void);
unsigned long nondet_ulong(void);
long long nondet_llong(void);
unsigned long long nondet_ullong(void);
unsigned char nondet_uchar(void);
char nondet_char(void);

/* A heap buffer of exactly `size` bytes with arbitrary contents (no terminator implied). Its
 * size is exact, so CBMC reports any access one byte outside it. */
static char *nondet_buffer(size_t size)
{
    char *buf = (char *)malloc(size);
    ASSUME(buf != NULL);
    for (size_t i = 0; i < size; ++i) {
        buf[i] = nondet_char();
    }
    return buf;
}

/* A C string in a heap object of exactly strlen + 1 bytes: `*len` (< max_size) arbitrary non-NUL
 * bytes, then the terminator. Reading one byte past the terminator is out of bounds. */
static char *nondet_cstr(size_t max_size, size_t *len)
{
    size_t n = nondet_size_t();
    ASSUME(n < max_size);
    char *s = (char *)malloc(n + 1);
    ASSUME(s != NULL);
    for (size_t i = 0; i < n; ++i) {
        s[i] = nondet_char();
        ASSUME(s[i] != '\0');
    }
    s[n] = '\0';
    *len = n;
    return s;
}

/*
 * Reference UTF-8 decoder, written from the Unicode Standard's table of well-formed byte
 * sequences (Unicode 15, Table 3-7) rather than from SDL's code. It is the spec the UTF-8
 * harnesses compare SDL against.
 *
 * Returns the length (1..4) of the well-formed sequence at s[0..avail), storing its scalar
 * value in *cp, or 0 if s does not start with a well-formed sequence within avail bytes.
 * Reads only bytes it needs, stopping at the first byte that rules the sequence out.
 */
static int ref_utf8_decode(const unsigned char *s, size_t avail, Uint32 *cp)
{
    if (avail == 0) {
        return 0;
    }
    const unsigned char b0 = s[0];
    unsigned char lo = 0x80, hi = 0xBF;  /* the allowed range of the second byte */
    int n;
    Uint32 v;
    if (b0 <= 0x7F) {
        *cp = b0;
        return 1;
    } else if (b0 >= 0xC2 && b0 <= 0xDF) {
        n = 2; v = b0 & 0x1F;
    } else if (b0 == 0xE0) {
        n = 3; v = b0 & 0x0F; lo = 0xA0;
    } else if ((b0 >= 0xE1 && b0 <= 0xEC) || b0 == 0xEE || b0 == 0xEF) {
        n = 3; v = b0 & 0x0F;
    } else if (b0 == 0xED) {
        n = 3; v = b0 & 0x0F; hi = 0x9F;
    } else if (b0 == 0xF0) {
        n = 4; v = b0 & 0x07; lo = 0x90;
    } else if (b0 >= 0xF1 && b0 <= 0xF3) {
        n = 4; v = b0 & 0x07;
    } else if (b0 == 0xF4) {
        n = 4; v = b0 & 0x07; hi = 0x8F;
    } else {
        return 0;
    }
    for (int i = 1; i < n; ++i) {
        if ((size_t)i >= avail) {
            return 0;
        }
        const unsigned char b = s[i];
        if (i == 1 ? (b < lo || b > hi) : (b < 0x80 || b > 0xBF)) {
            return 0;
        }
        v = (v << 6) | (b & 0x3F);
    }
    *cp = v;
    return n;
}

/* True if s[0..len) is a sequence of well-formed UTF-8 characters, none of them U+0000. */
static bool ref_utf8_valid_nonul(const unsigned char *s, size_t len)
{
    size_t i = 0;
    while (i < len) {
        Uint32 cp;
        const int n = ref_utf8_decode(s + i, len - i, &cp);
        if (n == 0 || cp == 0) {
            return false;
        }
        i += (size_t)n;
    }
    return true;
}

#endif /* CBMC_COMMON_H */
