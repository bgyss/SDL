/*
 * SDL_ltoa / SDL_ultoa (src/stdlib/SDL_string.c, the !HAVE__LTOA / !HAVE__ULTOA code, which is
 * what every platform uses: POSIX has no _ltoa and the Windows configs leave HAVE__LTOA unset).
 *
 * Contract (include/SDL3/SDL_stdinc.h): the header suggests a buffer of sizeof(long) * 8 + 2
 * bytes ("-", 64 binary digits, NUL). It does not state a radix range.
 *
 * Checked, for every long value, on a buffer of exactly that size:
 *   - no undefined behaviour (LONG_MIN: F-029) and no write outside the buffer
 *   - the output is "-"? digit+ NUL, digits valid for the radix, no leading zero unless "0"
 *   - the digits spell |value| (reconstructed with unsigned arithmetic)
 *
 * The radix is a constant: 2, the longest output. A symbolic radix makes every one of the 64
 * loop iterations a full 64-bit divider (over 5 GB per run); radix 10 (20 divisions by a
 * constant) did not finish within the memory of the development machine either.
 *
 * CBMC-SOURCES: src/stdlib/SDL_string.c
 * CBMC-BOUND: all 64-bit long values, radix 2
 * CBMC-UNWIND: 67
 */
#include "cbmc_common.h"

#define LTOA_RADIX 2

#define BUFSIZE (sizeof(long) * 8 + 2)

static int digit_of(char c)
{
    if (c >= '0' && c <= '9') {
        return c - '0';
    } else if (c >= 'A' && c <= 'Z') {
        return c - 'A' + 10;
    }
    return 99;
}

void harness(void)
{
    const long value = nondet_long();
    const int radix = LTOA_RADIX;
    char *buf = (char *)malloc(BUFSIZE);
    ASSUME(buf != NULL);

    CHECK(SDL_ltoa(value, buf, radix) == buf, "ltoa: returns its buffer");

    size_t i = 0;
    const bool neg = (buf[0] == '-');
    CHECK(neg == (value < 0), "ltoa: a '-' exactly for negative values");
    if (neg) {
        i = 1;
    }
    const size_t first = i;
    unsigned long mag = 0;
    bool fits = true;
    while (buf[i] != '\0') {
        const int d = digit_of(buf[i]);
        CHECK(d < radix, "ltoa: every digit is valid for the radix");
        if (mag > (~0UL - (unsigned long)d) / (unsigned long)radix) {
            fits = false;
        }
        mag = mag * (unsigned long)radix + (unsigned long)d;
        ++i;
    }
    CHECK(i > first, "ltoa: at least one digit");
    CHECK(i == first + 1 || buf[first] != '0', "ltoa: no leading zero");
    const unsigned long want = (value < 0) ? 0UL - (unsigned long)value : (unsigned long)value;
    CHECK(fits && mag == want, "ltoa: the digits spell |value|");
}
