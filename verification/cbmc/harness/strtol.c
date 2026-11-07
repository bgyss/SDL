/*
 * SDL_strtol (src/stdlib/SDL_string.c: SDL_ScanLong over SDL_ScanUnsignedLongLongInternal, the
 * !HAVE_STRTOL implementation used by builds without a C library).
 *
 * Contract (include/SDL3/SDL_stdinc.h): skips leading whitespace; base is 0 or 2..36, and 0
 * infers the base from a 0x / 0 prefix; out-of-range results are clamped to LONG_MIN/LONG_MAX;
 * endp points just past the parsed number; 0 if no number could be parsed. The reference below
 * is written from C11 7.22.1.4 (strtol), which the contract follows: the subject sequence is the
 * longest run of characters that are digits *of the given base*.
 *
 * CBMC-SOURCES: src/stdlib/SDL_string.c src/stdlib/SDL_stdlib.c
 * CBMC-BOUND: strlen < 5, base in {0, 2..36}
 * CBMC-UNWIND: 7
 */
#include "cbmc_common.h"

#include <limits.h>

#define MAX 5

static bool ref_space(char c)
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r';
}

/* The value of c as a digit, or 99 if it is not a digit or letter. */
static int ref_digit(char c)
{
    if (c >= '0' && c <= '9') {
        return c - '0';
    } else if (c >= 'a' && c <= 'z') {
        return c - 'a' + 10;
    } else if (c >= 'A' && c <= 'Z') {
        return c - 'A' + 10;
    }
    return 99;
}

/* Returns the length of the parsed prefix (0 if no subject sequence), the sign, the magnitude
 * and whether it overflowed unsigned long long. */
static size_t ref_scan(const char *s, int base, bool *neg, unsigned long long *mag, bool *ovf)
{
    size_t i = 0;
    while (ref_space(s[i])) {
        ++i;
    }
    *neg = false;
    if (s[i] == '-' || s[i] == '+') {
        *neg = (s[i] == '-');
        ++i;
    }
    /* "0x" is a prefix only if a hex digit follows; otherwise the subject sequence is "0". */
    if ((base == 0 || base == 16) && s[i] == '0' && (s[i + 1] == 'x' || s[i + 1] == 'X') &&
        ref_digit(s[i + 2]) < 16) {
        i += 2;
        base = 16;
    } else if (base == 0) {
        base = (s[i] == '0') ? 8 : 10;
    }
    const size_t start = i;
    unsigned long long v = 0;
    *ovf = false;
    while (ref_digit(s[i]) < base) {
        const unsigned long long d = (unsigned long long)ref_digit(s[i]);
        if (v > (ULLONG_MAX - d) / (unsigned long long)base) {
            *ovf = true;
        } else {
            v = v * (unsigned long long)base + d;
        }
        ++i;
    }
    *mag = v;
    return (i == start) ? 0 : i;
}

void harness(void)
{
    size_t len;
    const char *s = nondet_cstr(MAX, &len);
    const int base = nondet_int();
    ASSUME(base == 0 || (base >= 2 && base <= 36));

    char *end = NULL;
    const long r = SDL_strtol(s, &end, base);

    CHECK(end >= s && end <= s + len, "strtol: endp stays inside the string");

    bool neg, ovf;
    unsigned long long mag;
    const size_t n = ref_scan(s, base, &neg, &mag, &ovf);
    CHECK(end == s + n, "strtol: endp is just past the longest valid number (C11 7.22.1.4)");
    long want;
    if (n == 0) {
        want = 0;
    } else if (neg) {
        want = (ovf || mag > (unsigned long long)LONG_MAX + 1) ? LONG_MIN : (long)(0ULL - mag);
    } else {
        want = (ovf || mag > (unsigned long long)LONG_MAX) ? LONG_MAX : (long)mag;
    }
    CHECK(r == want, "strtol: value matches C11 strtol, clamped to the range of long");
}
