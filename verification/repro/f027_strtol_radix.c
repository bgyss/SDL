/* F-027: SDL's own strtol family accepts digits that are not digits of the base, and base 0
 * skips the leading '0' of an octal number. Found by the CBMC harness
 * verification/cbmc/harness/strtol.c ("\v\v\v8" in base 8 gave 8; C11 strtol gives 0).
 *
 * The code is SDL_ScanUnsignedLongLongInternal(W), which only builds without a C library use
 * (SDL_LIBC=OFF, or a platform config without HAVE_STRTOL / HAVE_WCSTOL / HAVE_VSSCANF). On the
 * host SDL_strtol forwards to libc, so no public call reaches it. This program therefore
 * compiles src/stdlib/SDL_string.c itself, with the minimal (libc-less) build config the CBMC
 * harnesses use, and stubs the few SDL functions it calls. CMakeLists.txt builds it without
 * linking SDL; it is otherwise built and judged like every other reproduction.
 *
 * C11 7.22.1.4: strtol("19", &end, 2) is 1 with end after "1"; strtol("08", &end, 0) is 0 with
 * end after "0".
 */
#include "stdlib/SDL_string.c"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include "repro.h"

/* What SDL_string.c needs from the rest of SDL. None of it is on the strtol path. */
void *SDL_malloc(size_t size) { return malloc(size); }
void *SDL_calloc(size_t nmemb, size_t size) { return calloc(nmemb, size); }
void *SDL_realloc(void *mem, size_t size) { return realloc(mem, size); }
void SDL_free(void *mem) { free(mem); }
bool SDL_SetError(SDL_PRINTF_FORMAT_STRING const char *fmt, ...) { (void)fmt; return false; }
char *SDL_iconv_string(const char *tocode, const char *fromcode, const char *inbuf, size_t inbytesleft)
{
    (void)tocode; (void)fromcode; (void)inbuf; (void)inbytesleft;
    return NULL;
}
int SDL_isdigit(int x) { return x >= '0' && x <= '9'; }
int SDL_isspace(int x) { return x == ' ' || x == '\t' || x == '\r' || x == '\n' || x == '\f' || x == '\v'; }
int SDL_toupper(int x) { return (x >= 'a' && x <= 'z') ? x - 'a' + 'A' : x; }
int SDL_tolower(int x) { return (x >= 'A' && x <= 'Z') ? x - 'A' + 'a' : x; }
double SDL_modf(double x, double *y) { return modf(x, y); }
double SDL_round(double x) { return round(x); }
SDL_AssertState SDL_ReportAssertion(SDL_AssertData *data, const char *func, const char *file, int line)
{
    fprintf(stderr, "assertion '%s' failed at %s:%d (%s)\n", data->condition, file, line, func);
    abort();
}

int main(void)
{
    static const struct { const char *s; int base; long value; int end; } cases[] = {
        { "19", 2, 1, 1 },    /* '9' is not a binary digit */
        { "78", 8, 7, 1 },    /* '8' is not an octal digit */
        { "08", 0, 0, 1 },    /* octal "0", then '8' */
        { "0", 0, 0, 1 },
        { "0x1g", 0, 1, 3 },
    };
    int bad = 0;
    for (size_t i = 0; i < SDL_arraysize(cases); ++i) {
        char *end = NULL;
        const long v = SDL_strtol(cases[i].s, &end, cases[i].base);
        const int at = (int)(end - cases[i].s);
        printf("strtol(\"%s\", %d) = %ld, end at %d (C11: %ld, end at %d)\n", cases[i].s, cases[i].base, v, at,
               cases[i].value, cases[i].end);
        if (v != cases[i].value || at != cases[i].end) {
            ++bad;
        }
    }
    /* The wide-character copy of the scanner. */
    wchar_t *wend = NULL;
    static const wchar_t w19[] = { '1', '9', 0 };
    const long wv = SDL_wcstol(w19, &wend, 2);
    printf("wcstol(L\"19\", 2) = %ld, end at %d (C11: 1, end at 1)\n", wv, (int)(wend - w19));
    if (wv != 1 || wend != w19 + 1) {
        ++bad;
    }
    if (bad) {
        REPRO_BUG("%d of %d strtol/wcstol results differ from C11", bad, (int)SDL_arraysize(cases) + 1);
    }
    REPRO_OK("strtol and wcstol stop at the first character that is not a digit of the base");
}
