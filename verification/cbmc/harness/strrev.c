/*
 * SDL_strrev (src/stdlib/SDL_string.c, the !HAVE__STRREV code: every platform but Windows).
 * Reverses a NUL-terminated string in place, including the empty string.
 *
 * CBMC-SOURCES: src/stdlib/SDL_string.c
 * CBMC-BOUND: strlen < 7
 * CBMC-UNWIND: 9
 */
#include "cbmc_common.h"

#define MAX 7

void harness(void)
{
    size_t len;
    char *s = nondet_cstr(MAX, &len);
    char before[MAX];
    for (size_t i = 0; i <= len; ++i) {
        before[i] = s[i];
    }

    CHECK(SDL_strrev(s) == s, "strrev: returns its argument");

    for (size_t i = 0; i < len; ++i) {
        CHECK(s[i] == before[len - 1 - i], "strrev: reverses the string");
    }
    CHECK(s[len] == '\0', "strrev: keeps the terminator");
}
