/*
 * SDL_strcasecmp / SDL_strncasecmp (src/stdlib/SDL_string.c, the UNICODE_STRCASECMP macro). Both
 * decode with StepUTF8, strcasecmp with slen = 4: the second path F-004 was found on.
 *
 * Checked on arbitrary NUL-terminated strings, each in a heap object of exactly strlen + 1
 * bytes:
 *   - no read past either terminator (F-004 fails this on the base tree)
 *   - a string compares equal to itself; swapping the arguments flips the sign
 *   - strncasecmp with maxlen >= both lengths agrees in sign with strcasecmp
 *   - strncasecmp with maxlen 0 compares equal
 *
 * Case folding is replaced by the model below (CBMC-REPLACE). SDL_CaseFoldUnicode looks the code
 * point up in 256-bucket hash tables of pointers (SDL_casefolding.h); with a symbolic code point
 * CBMC's symbolic execution did not finish in 100 s. The model is deterministic and, like the
 * tables, folds some code points to two or three, so the macro's folded-character queue is
 * exercised. The tables themselves are not checked here.
 *
 * CBMC-SOURCES: src/stdlib/SDL_string.c src/stdlib/SDL_stdlib.c
 * CBMC-REPLACE: SDL_CaseFoldUnicode:cbmc_casefold
 * CBMC-BOUND: strlen < 4 each, every byte value, maxlen <= 4; case folding modelled
 * CBMC-UNWIND: 6
 */
#include "cbmc_common.h"

#define MAX 4

int cbmc_casefold(Uint32 from, Uint32 *to)
{
    if (from >= 'A' && from <= 'Z') {
        to[0] = from + ('a' - 'A');
        return 1;
    } else if (from == 0xDF) { /* U+00DF SHARP S -> "ss" */
        to[0] = 's';
        to[1] = 's';
        return 2;
    } else if (from == 0xFB03) { /* U+FB03 LATIN SMALL LIGATURE FFI -> "ffi" */
        to[0] = 'f';
        to[1] = 'f';
        to[2] = 'i';
        return 3;
    }
    to[0] = from;
    return 1;
}

static int sign(int x)
{
    return (x > 0) - (x < 0);
}

void harness(void)
{
    size_t la, lb;
    const char *a = nondet_cstr(MAX, &la);
    const char *b = nondet_cstr(MAX, &lb);

    const int ab = SDL_strcasecmp(a, b);
    const int ba = SDL_strcasecmp(b, a);
    CHECK(sign(ab) == -sign(ba), "strcasecmp: swapping the arguments flips the sign");
    CHECK(SDL_strcasecmp(a, a) == 0, "strcasecmp: a string equals itself");

    const size_t maxlen = nondet_size_t();
    ASSUME(maxlen <= MAX);
    const int n = SDL_strncasecmp(a, b, maxlen);
    if (maxlen >= la && maxlen >= lb) {
        CHECK(sign(n) == sign(ab), "strncasecmp: agrees with strcasecmp when maxlen covers both");
    }
    if (maxlen == 0) {
        CHECK(n == 0, "strncasecmp: maxlen 0 compares equal");
    }
}
