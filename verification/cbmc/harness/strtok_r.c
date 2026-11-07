/*
 * SDL_strtok_r (src/stdlib/SDL_strtokr.c, the !HAVE_STRTOK_R code).
 *
 * Tokenises an arbitrary string with an arbitrary delimiter set until it returns NULL. Checked:
 *   - no read or write outside either string
 *   - every token is non-empty, lies inside s, contains no delimiter, and is bounded by a
 *     delimiter (now overwritten with NUL) or the end of s
 *   - tokens come in order, and every non-delimiter byte of s ends up in exactly one token
 *
 * CBMC-SOURCES: src/stdlib/SDL_strtokr.c
 * CBMC-BOUND: strlen(s) < 5, strlen(delims) < 3, up to 3 calls (enough to exhaust s)
 * CBMC-UNWIND: 7
 */
#include "cbmc_common.h"

#define MAX 4
#define DMAX 2

static bool is_delim(char c, const char *delims)
{
    for (const char *d = delims; *d; ++d) {
        if (*d == c) {
            return true;
        }
    }
    return false;
}

void harness(void)
{
    size_t len, dlen;
    char *s = nondet_cstr(MAX, &len);
    const char *delims = nondet_cstr(DMAX, &dlen);
    char orig[MAX];
    for (size_t i = 0; i <= len; ++i) {
        orig[i] = s[i];
    }

    char *save = NULL;
    size_t covered = 0;   /* bytes of s that ended up in tokens */
    size_t next = 0;      /* every later token starts at or after this offset */
    char *tok = SDL_strtok_r(s, delims, &save);
    for (int call = 0; call < MAX / 2 + 1 && tok; ++call) {
        CHECK(tok >= s && tok < s + len, "strtok_r: the token lies inside s");
        const size_t at = (size_t)(tok - s);
        CHECK(at >= next, "strtok_r: tokens come in order");
        CHECK(at == 0 || is_delim(orig[at - 1], delims), "strtok_r: a token starts after a delimiter");
        size_t tlen = 0;
        while (tok[tlen] != '\0') {
            CHECK(!is_delim(tok[tlen], delims), "strtok_r: no delimiter inside a token");
            ++tlen;
        }
        CHECK(tlen > 0, "strtok_r: tokens are not empty");
        CHECK(at + tlen == len || is_delim(orig[at + tlen], delims), "strtok_r: a token ends at a delimiter or the end");
        covered += tlen;
        next = at + tlen + 1;
        tok = SDL_strtok_r(NULL, delims, &save);
    }
    CHECK(tok == NULL, "strtok_r: returns NULL once s is exhausted");

    size_t want = 0;
    for (size_t i = 0; i < len; ++i) {
        if (!is_delim(orig[i], delims)) {
            ++want;
        }
    }
    CHECK(covered == want, "strtok_r: every non-delimiter byte is in a token");
}
