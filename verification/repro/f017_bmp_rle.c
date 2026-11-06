/* F-017: readRlePixels moves its row pointer with `bits -= ch * pitch` on every RLE delta
 * escape, with no bound. Writes are checked against the buffer, but forming a pointer outside
 * the allocation is undefined behaviour. UBSan only sees it once the address wraps below 0, so
 * this file walks far enough to guarantee the wrap: 70,000 deltas of 255 rows of 8 MiB each
 * is ~1.5e14 bytes, more than the 47-bit user address space.
 *
 * The image is 8,388,608 x 1 at 8 bits (an 8 MiB surface). 255 * 8 MiB still fits in an int, so
 * the multiplication itself does not overflow; only the pointer does. */
#include <stdlib.h>
#include "bmp.h"
#include "repro.h"

#define WIDTH (8 * 1024 * 1024)
#define DELTAS 70000

int main(void)
{
    const Uint32 rle_len = DELTAS * 4 + 2;
    Uint8 *rle = (Uint8 *)malloc(rle_len);
    for (Uint32 i = 0; i < DELTAS; i++) {
        rle[i * 4 + 0] = 0;   /* escape */
        rle[i * 4 + 1] = 2;   /* delta */
        rle[i * 4 + 2] = 0;   /* dx */
        rle[i * 4 + 3] = 255; /* dy: 255 rows */
    }
    rle[DELTAS * 4 + 0] = 0;
    rle[DELTAS * 4 + 1] = 1; /* end of bitmap */
    const size_t cap = 14 + 40 + 256 * 4 + rle_len;
    Uint8 *file = (Uint8 *)malloc(cap);
    const size_t size = make_bmp(file, WIDTH, 1, 8, 1 /* BI_RLE8 */, 256, rle, rle_len);
    free(rle);
    REPRO_STEP("SDL_LoadBMP_IO: RLE8, %d delta escapes of 255 rows", DELTAS);
    SDL_Surface *s = SDL_LoadBMP_IO(SDL_IOFromConstMem(file, size), true);
    free(file);
    if (!s) {
        REPRO_OK("refused: %s", SDL_GetError());
    }
    SDL_DestroySurface(s);
    REPRO_OK("loaded; the row position never left the buffer as a pointer");
}
