/* Fuzz target: SDL's UTF-8 functions (SDL_StepUTF8, SDL_StepBackUTF8, SDL_utf8strlcpy,
 * SDL_utf8strlen/strnlen, SDL_UCS4ToUTF8).
 *
 * Input: byte 0 picks the SDL_utf8strlcpy destination size, bytes 1-4 are a code point for the
 * encoder, and the rest is the string.
 *
 * Besides "no sanitizer report", every result is checked against a reference RFC 3629 decoder
 * written here from the RFC grammar (the same grammar as `wfLen` in lean/SDLVerif/Utf8.lean).
 * The C may deviate from the reference only on these sets, each proved exact in Lean:
 *   F-005  StepUTF8 returns a value > U+10FFFF  (Utf8.lean: out_of_range_iff)
 *   F-007  utf8strlcpy cuts inside the first character  (Utf8String.lean: lcpy_c_vs_fixed)
 *   F-008  StepBackUTF8 skips stray continuation bytes  (Utf8String.lean: stepBack_skips_only_cont)
 *   F-004  the NULL-length path reads up to 2 bytes past the NUL. By default the NULL-length
 *          calls get NUL padding so ASan stays quiet; SDL_FUZZ_KNOWN=1 removes the padding.
 */
#include "fuzz_common.h"

/* RFC 3629 §4: length of the well-formed character at s[0..n), or 0 if there is none. */
static int rfc_len(const Uint8 *s, size_t n)
{
#define T(i) ((size_t)(i) < n && s[i] >= 0x80 && s[i] <= 0xBF)
#define R(i, lo, hi) ((size_t)(i) < n && s[i] >= (lo) && s[i] <= (hi))
    if (n == 0) return 0;
    const Uint8 b = s[0];
    if (b <= 0x7F) return 1;
    if (b >= 0xC2 && b <= 0xDF && T(1)) return 2;
    if (b == 0xE0 && R(1, 0xA0, 0xBF) && T(2)) return 3;
    if (((b >= 0xE1 && b <= 0xEC) || b == 0xEE || b == 0xEF) && T(1) && T(2)) return 3;
    if (b == 0xED && R(1, 0x80, 0x9F) && T(2)) return 3;
    if (b == 0xF0 && R(1, 0x90, 0xBF) && T(2) && T(3)) return 4;
    if (b >= 0xF1 && b <= 0xF3 && T(1) && T(2) && T(3)) return 4;
    if (b == 0xF4 && R(1, 0x80, 0x8F) && T(2) && T(3)) return 4;
    return 0;
#undef T
#undef R
}

static Uint32 rfc_value(const Uint8 *s, int len)
{
    switch (len) {
    case 1: return s[0];
    case 2: return ((Uint32)(s[0] & 0x1F) << 6) | (s[1] & 0x3F);
    case 3: return ((Uint32)(s[0] & 0x0F) << 12) | ((Uint32)(s[1] & 0x3F) << 6) | (s[2] & 0x3F);
    default: return ((Uint32)(s[0] & 0x07) << 18) | ((Uint32)(s[1] & 0x3F) << 12) |
                    ((Uint32)(s[2] & 0x3F) << 6) | (s[3] & 0x3F);
    }
}

static int is_cont(Uint8 b) { return (b & 0xC0) == 0x80; }

/* F-005's exact set (Utf8.lean out_of_range_iff): lead F4-F7, three continuation bytes, value
   above U+10FFFF, and slen >= 4. */
static int f005(const Uint8 *s, size_t n)
{
    return n >= 4 && s[0] >= 0xF4 && s[0] <= 0xF7 && is_cont(s[1]) && is_cont(s[2]) &&
           is_cont(s[3]) && rfc_value(s, 4) > 0x10FFFF;
}

/* What SDL_StepUTF8(&p, &n) must return per the header and RFC 3629. */
static Uint32 expect_step(const Uint8 *s, size_t n, size_t *adv)
{
    if (n == 0 || s[0] == 0) {
        *adv = 0;
        return 0;
    }
    const int len = rfc_len(s, n);
    if (len) {
        *adv = (size_t)len;
        return rfc_value(s, len);
    }
    *adv = 1;
    return SDL_INVALID_UNICODE_CODEPOINT;
}

#define MAXCP 4096

static void check_forward(const Uint8 *s, size_t n, Uint32 *cps, size_t *offs, size_t *count, int *wellformed)
{
    const char *p = (const char *)s;
    size_t left = n;
    *count = 0;
    *wellformed = 1;
    for (;;) {
        const size_t at = (size_t)((const Uint8 *)p - s);
        size_t eadv;
        const Uint32 ecp = expect_step(s + at, left, &eadv);
        const Uint32 cp = SDL_StepUTF8(&p, &left);
        const size_t adv = (size_t)((const Uint8 *)p - s) - at;
        if (cp != ecp || adv != eadv) {
            const int known = f005(s + at, n - at) && cp == rfc_value(s + at, 4) && adv == 4;
            PROPERTY(known && !fuzz_known(), "StepUTF8 at %zu: got U+%X adv %zu, RFC 3629 says U+%X adv %zu%s",
                     at, (unsigned)cp, adv, (unsigned)ecp, eadv, known ? " (F-005)" : "");
            *wellformed = 0;
        }
        PROPERTY(left == n - (at + adv), "StepUTF8 slen bookkeeping: %zu != %zu", left, n - (at + adv));
        if (cp == 0) {
            break;
        }
        if (!rfc_len(s + at, n - at)) {
            *wellformed = 0;
        }
        if (*count < MAXCP) {
            cps[*count] = cp;
            offs[*count] = at;
        }
        (*count)++;
    }
    PROPERTY(*count <= n, "more code points (%zu) than bytes (%zu)", *count, n);
}

static void check_backward(const Uint8 *s, size_t n, const Uint32 *cps, const size_t *offs, size_t count, int wellformed)
{
    const char *start = (const char *)s;
    const char *p = start + n;
    size_t k = count;
    for (;;) {
        const char *before = p;
        const Uint32 cp = SDL_StepBackUTF8(start, &p);
        if (before == start) {
            PROPERTY(cp == 0 && p == start, "StepBackUTF8 at start returned U+%X", (unsigned)cp);
            break;
        }
        PROPERTY(p < before && p >= start, "StepBackUTF8 moved from %td to %td", before - start, p - start);
        const size_t q = (size_t)(p - start), end = (size_t)(before - start);
        /* It decodes one character from q with length end - q. */
        size_t adv;
        const Uint32 ecp = expect_step(s + q, end - q, &adv);
        const int f005_here = f005(s + q, end - q);
        PROPERTY(cp == ecp || (f005_here && !fuzz_known()),
                 "StepBackUTF8 [%zu,%zu): got U+%X, decoding from %zu gives U+%X", q, end, (unsigned)cp, q, (unsigned)ecp);
        if (f005_here) {
            adv = 4;
        }
        /* Contract: an invalid sequence gives U+FFFD. F-008: the bytes it skips beyond the
           decoded character are only ever continuation bytes (proved exact in Lean). */
        if (cp != 0 && adv != end - q) {
            for (size_t i = q + adv; i < end; i++) {
                PROPERTY(is_cont(s[i]), "StepBackUTF8 skipped non-continuation byte %02X at %zu", s[i], i);
            }
            PROPERTY(!fuzz_known(), "F-008: StepBackUTF8 [%zu,%zu) returned U+%X and skipped %zu stray continuation bytes",
                     q, end, (unsigned)cp, end - q - adv);
        }
        if (cp == 0) {
            break; /* an embedded NUL (outside the string contract) */
        }
        /* On well-formed text StepBack is the exact inverse of Step. */
        if (wellformed && count <= MAXCP) {
            PROPERTY(k > 0 && cps[k - 1] == cp && offs[k - 1] == q,
                     "StepBack/Step mismatch at %zu: back U+%X, forward U+%X at %zu", q, (unsigned)cp,
                     k ? (unsigned)cps[k - 1] : 0, k ? offs[k - 1] : 0);
            k--;
        }
    }
    if (wellformed && count <= MAXCP) {
        PROPERTY(k == 0, "StepBack produced %zu fewer code points than Step", k);
    }
}

static void check_strlcpy(const Uint8 *s, size_t n, size_t dst_bytes, int wellformed)
{
    char *src = (char *)malloc(n + 1);
    memcpy(src, s, n);
    src[n] = '\0';
    char *dst = (char *)malloc(dst_bytes);
    const size_t r = SDL_utf8strlcpy(dst, src, dst_bytes);
    PROPERTY(r <= dst_bytes - 1 && r <= n, "utf8strlcpy wrote %zu bytes (dst_bytes %zu, len %zu)", r, dst_bytes, n);
    PROPERTY(dst[r] == '\0' && memcmp(dst, src, r) == 0, "utf8strlcpy output is not a terminated prefix");
    if (wellformed) {
        /* Expected: the longest prefix of whole characters within b = min(n, dst_bytes-1). */
        const size_t b = SDL_min(n, dst_bytes - 1);
        size_t boundary = 0, first_len = 0;
        while (boundary < n) {
            const size_t len = (size_t)rfc_len(s + boundary, n - boundary);
            if (!first_len) {
                first_len = len;
            }
            if (boundary + len > b) {
                break;
            }
            boundary += len;
        }
        /* F-007's exact set (lcpy_c_vs_fixed): the cut is inside the first character, at least
           two bytes in; the C then keeps all b bytes. */
        const int f007 = boundary == 0 && b >= 2 && b < first_len && r == b;
        PROPERTY(r == boundary || (f007 && !fuzz_known()),
                 "utf8strlcpy kept %zu bytes, the last whole character ends at %zu%s", r, boundary, f007 ? " (F-007)" : "");
    }
    free(dst);
    free(src);
}

static void check_null_len(const Uint8 *s, size_t n, size_t count)
{
    /* SDL_StepUTF8(&p, NULL) and SDL_utf8strlen read up to 2 bytes past the NUL (F-004). */
    const size_t pad = fuzz_known() ? 1 : 4;
    char *z = (char *)calloc(n + pad, 1);
    memcpy(z, s, n);
    const size_t len = SDL_utf8strlen(z);
    const size_t nlen = SDL_utf8strnlen(z, n);
    PROPERTY(nlen == count, "utf8strnlen %zu != forward count %zu", nlen, count);
    PROPERTY(len == count, "utf8strlen %zu != forward count %zu", len, count);
    free(z);
}

static void check_encoder(Uint32 cp)
{
    char *buf = (char *)malloc(4); /* the header asks for exactly 4 bytes */
    char *end = SDL_UCS4ToUTF8(cp, buf);
    const size_t len = (size_t)(end - buf);
    PROPERTY(len >= 1 && len <= 4, "UCS4ToUTF8 wrote %zu bytes", len);
    const Uint32 want = (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) ? SDL_INVALID_UNICODE_CODEPOINT : cp;
    PROPERTY(want == 0 || rfc_len((const Uint8 *)buf, len) == (int)len, "UCS4ToUTF8(U+%X) is not well-formed", (unsigned)cp);
    const char *p = buf;
    size_t left = len;
    const Uint32 back = SDL_StepUTF8(&p, &left);
    PROPERTY(back == want && (want == 0 || left == 0), "UCS4ToUTF8(U+%X) decodes to U+%X", (unsigned)cp, (unsigned)back);
    free(buf);
}

int LLVMFuzzerTestOneInput(const Uint8 *data, size_t size)
{
    static Uint32 cps[MAXCP];
    static size_t offs[MAXCP];
    Reader r = { data, size };
    const Uint8 dsel = rd_u8(&r);
    check_encoder(rd_u32(&r));

    /* The string is everything after the parameters, up to the first NUL. */
    const Uint8 *nul = (const Uint8 *)memchr(r.p, 0, r.left);
    const size_t n = nul ? (size_t)(nul - r.p) : r.left;
    Uint8 *s = exact_copy(r.p, n);

    size_t count;
    int wellformed;
    check_forward(s, n, cps, offs, &count, &wellformed);
    check_backward(s, n, cps, offs, count, wellformed);
    check_strlcpy(s, n, 1 + (size_t)dsel % (n + 2), wellformed);
    check_null_len(s, n, count);
    free(s);
    return 0;
}
