/* Shared helpers for the Phase 3 fuzz targets (verification/harness/README.md).
 *
 * Each target is a libFuzzer entry point. Its spec is "no crash, hang, ASan or UBSan report for
 * inputs of at most -max_len bytes", plus the PROPERTY checks it makes. A failed PROPERTY
 * calls abort(), so libFuzzer saves the input exactly like a sanitizer report.
 *
 * Known findings: a check that would fire on an already-recorded finding (FINDINGS.md) is not
 * dropped. It is written as "the C may deviate only on the exact input set that finding
 * characterizes". Each of those sets is a proved Lean theorem, so any deviation outside the
 * proved set still aborts. Set SDL_FUZZ_KNOWN=1 to make the known deviations abort too.
 */
#ifndef FUZZ_COMMON_H
#define FUZZ_COMMON_H

#include <SDL3/SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int LLVMFuzzerTestOneInput(const Uint8 *data, size_t size);

#define PROPERTY(cond, ...)                                                    \
    do {                                                                       \
        if (!(cond)) {                                                         \
            fprintf(stderr, "PROPERTY FAILED %s:%d: %s\n  ", __FILE__, __LINE__, #cond); \
            fprintf(stderr, __VA_ARGS__);                                      \
            fprintf(stderr, "\n");                                             \
            abort();                                                           \
        }                                                                      \
    } while (0)

/* Whether known findings should abort as well (SDL_FUZZ_KNOWN=1). */
static int fuzz_known(void)
{
    static int v = -1;
    if (v < 0) {
        const char *e = getenv("SDL_FUZZ_KNOWN");
        v = (e && *e == '1');
    }
    return v;
}

/* A cursor over the input, for targets that carve parameters off the front. */
typedef struct
{
    const Uint8 *p;
    size_t left;
} Reader;

static Uint8 rd_u8(Reader *r)
{
    if (!r->left) {
        return 0;
    }
    r->left--;
    return *r->p++;
}

static Uint32 rd_u32(Reader *r)
{
    Uint32 v = 0;
    for (int i = 0; i < 4; i++) {
        v = (v << 8) | rd_u8(r);
    }
    return v;
}

/* A heap copy of exactly n bytes (no slack), so ASan sees any read past the end. */
static Uint8 *exact_copy(const Uint8 *data, size_t n)
{
    Uint8 *p = (Uint8 *)malloc(n ? n : 1);
    if (n) {
        memcpy(p, data, n);
    }
    return p;
}

#endif
