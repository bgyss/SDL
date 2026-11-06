/* Fuzz target: SDL_LoadBMP_IO (src/video/SDL_bmp.c) on an in-memory stream.
 *
 * Property: no sanitizer report, and a returned surface is self-consistent: positive size,
 * pitch large enough for a row, and every pixel byte readable (the loop touches each one, so
 * ASan checks the allocation covers h * pitch).
 *
 * Known findings, skipped unless SDL_FUZZ_KNOWN=1:
 *   F-017  RLE row pointer moved outside the pixel buffer (UBSan pointer-overflow, suppressed
 *          at this one site by ubsan.supp)
 *   F-018  biHeight == INT_MIN is negated (exact set: hits_f018)
 */
#include "fuzz_common.h"

/* F-018: SDL_bmp.c:367 negates biHeight to flip a top-down image; INT_MIN overflows. Exact
   trigger: a 32-bit info header (biSize != 12) whose biHeight field is INT_MIN. */
static int hits_f018(const Uint8 *d, size_t n)
{
    if (n < 26) {
        return 0;
    }
    const Uint32 bisize = (Uint32)d[14] | ((Uint32)d[15] << 8) | ((Uint32)d[16] << 16) | ((Uint32)d[17] << 24);
    const Uint32 ht = (Uint32)d[22] | ((Uint32)d[23] << 8) | ((Uint32)d[24] << 16) | ((Uint32)d[25] << 24);
    return bisize != 12 && ht == 0x80000000u;
}

int LLVMFuzzerTestOneInput(const Uint8 *data, size_t size)
{
    if (!fuzz_known() && hits_f018(data, size)) {
        return -1;
    }
    Uint8 *copy = exact_copy(data, size);
    SDL_IOStream *io = SDL_IOFromConstMem(copy, size);
    SDL_Surface *s = SDL_LoadBMP_IO(io, true);
    if (s) {
        PROPERTY(s->w > 0 && s->h > 0, "surface %dx%d", s->w, s->h);
        /* Row size in bytes; 1- and 4-bit formats pack several pixels per byte. */
        const Sint64 bits = SDL_BITSPERPIXEL(s->format);
        const Sint64 row = ((Sint64)s->w * bits + 7) / 8;
        PROPERTY(bits > 0 && (Sint64)s->pitch >= row, "pitch %d < row %lld (%d px x %lld bits)", s->pitch, (long long)row, s->w, (long long)bits);
        volatile Uint8 sink = 0;
        const Uint8 *px = (const Uint8 *)s->pixels;
        for (int y = 0; y < s->h; y++) {
            for (Sint64 x = 0; x < row; x++) {
                sink ^= px[(size_t)y * (size_t)s->pitch + (size_t)x];
            }
        }
        (void)sink;
        SDL_DestroySurface(s);
    }
    free(copy);
    return 0;
}
