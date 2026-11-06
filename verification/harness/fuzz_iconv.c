/* Fuzz target: SDL's built-in character-set converter (src/stdlib/SDL_iconv.c; the fork's
 * macOS build has no HAVE_ICONV, so this is SDL's own code, not the system libiconv).
 *
 * Input: byte 0 picks the source encoding, byte 1 the target, byte 2 the size of the output
 * chunk for the streaming API, the rest is the text.
 *
 * Properties, from the SDL_iconv header docs:
 * - the in/out cursors stay inside their buffers and the byte counts match the cursor moves
 * - E2BIG with no progress happens only when the output buffer is smaller than one character
 *   (at most 4 bytes in every supported encoding)
 * - a success return consumed all of the input
 * - output to the generic "UTF-16"/"UTF-32" targets starts with a byte order mark
 *
 * Known finding F-011 (the BOM is lost when the first character hits E2BIG) is skipped on its
 * exact trigger unless SDL_FUZZ_KNOWN=1.
 */
#include "fuzz_common.h"

static const char *const encodings[] = {
    "ASCII", "ISO-8859-1", "UTF-8", "UTF-16", "UTF-16BE", "UTF-16LE", "UTF-32", "UTF-32BE",
    "UTF-32LE", "UCS-2", "UCS-2LE", "UCS-2BE", "UCS-2-INTERNAL", "UCS-4", "UCS-4LE", "UCS-4BE",
    "UCS-4-INTERNAL", "WCHAR_T"
};
#define NENC (sizeof(encodings) / sizeof(encodings[0]))

int LLVMFuzzerTestOneInput(const Uint8 *data, size_t size)
{
    Reader r = { data, size };
    const char *from = encodings[rd_u8(&r) % NENC];
    const char *to = encodings[rd_u8(&r) % NENC];
    const size_t chunk = 1 + rd_u8(&r) % 16;
    const size_t n = r.left;
    Uint8 *in = exact_copy(r.p, n);

    /* One-shot helper. Its result is NUL-terminated; its length is not reported, so only check
       that it can be freed (ASan checks the writes). */
    char *whole = SDL_iconv_string(to, from, (const char *)in, n);
    SDL_free(whole);

    /* Streaming API through an exact-size output buffer of `chunk` bytes. */
    SDL_iconv_t cd = SDL_iconv_open(to, from);
    PROPERTY(cd != (SDL_iconv_t)-1, "iconv_open(%s, %s) failed for a built-in pair", to, from);
    const char *ip = (const char *)in;
    size_t ileft = n;
    char *out = (char *)malloc(chunk);
    size_t stalls = 0;
    /* The generic "UTF-16"/"UTF-32" targets start their output with a host-order BOM. */
    const size_t bom = !strcmp(to, "UTF-16") ? 2 : !strcmp(to, "UTF-32") ? 4 : 0;
    Uint8 head[4];
    size_t headn = 0, calls = 0;
    int bom_lost = 0; /* F-011's trigger: the first call wrote the BOM, then hit E2BIG */
    while (ileft > 0) {
        char *op = out;
        size_t oleft = chunk;
        const char *ip0 = ip;
        const size_t ileft0 = ileft;
        const size_t rc = SDL_iconv(cd, &ip, &ileft, &op, &oleft);
        PROPERTY(ip >= (const char *)in && ip <= (const char *)in + n, "in cursor left the buffer");
        PROPERTY(op >= out && op <= out + chunk, "out cursor left the buffer");
        PROPERTY((size_t)(ip - ip0) == ileft0 - ileft, "inbytesleft does not match the cursor move");
        PROPERTY((size_t)(op - out) == chunk - oleft, "outbytesleft does not match the cursor move");
        for (char *q = out; q < op && headn < sizeof(head); q++) {
            head[headn++] = (Uint8)*q;
        }
        const int first = calls++ == 0;
        if (rc == SDL_ICONV_E2BIG) {
            /* Progress, or the output really was too small for one character (at most 4 bytes,
               plus the BOM on the first call). */
            if (ip == ip0) {
                PROPERTY(chunk < 4 + (first ? bom : 0) || op != out, "E2BIG with an empty %zu-byte output buffer", chunk);
                if (first && bom && chunk >= bom) {
                    bom_lost = 1;
                }
                if (++stalls > 1) {
                    break; /* this chunk size can never hold the next character */
                }
            } else {
                stalls = 0;
            }
            continue;
        }
        if (rc == SDL_ICONV_EILSEQ || rc == SDL_ICONV_EINVAL || rc == SDL_ICONV_ERROR) {
            break;
        }
        PROPERTY(ileft == 0, "success with %zu input bytes left", ileft);
    }
    /* The stream must start with the BOM whenever anything was written. F-011: if the first
       call wrote the BOM and then returned E2BIG, SDL had already switched to native order
       without reporting the BOM bytes, so the BOM is lost. */
    if (bom && headn >= bom) {
        const Uint32 want = 0xFEFF;
        const int has = bom == 2 ? SDL_memcmp(head, &want, 2) == 0 : SDL_memcmp(head, &want, 4) == 0;
        PROPERTY(has || (bom_lost && !fuzz_known()), "%s output does not start with a BOM%s", to,
                 bom_lost ? " (F-011)" : "");
    }
    free(out);
    SDL_iconv_close(cd);
    free(in);
    return 0;
}
