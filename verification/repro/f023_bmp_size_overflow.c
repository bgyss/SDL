/* F-023: SDL_LoadBMP_IO computes the end of the pixel buffer as
 * `surface->pixels + surface->h * surface->pitch` in int. SDL_CreateSurface accepts any size
 * that fits in size_t, so a 1,048,576 x 512 image at 32 bpp (pitch 4 MiB, 2^31 bytes in all)
 * overflows that int multiplication. In practice it wraps to INT_MIN, putting the row pointer
 * 2 GiB before the buffer, where the loader then reads file data.
 *
 * The header is 54 bytes plus one row of pixels (4 MiB). The surface allocation is 2 GiB of
 * address space; the loader fails on the second row (short read), so little of it is touched. */
#include <stdlib.h>
#include "bmp.h"
#include "repro.h"

#define WIDTH (1024 * 1024)
#define HEIGHT 512

int main(void)
{
    const Uint32 row = WIDTH * 4;
    Uint8 *pixels = (Uint8 *)calloc(1, row);
    Uint8 *file = (Uint8 *)malloc(14 + 40 + row);
    const size_t size = make_bmp(file, WIDTH, HEIGHT, 32, 0 /* BI_RGB */, 0, pixels, row);
    free(pixels);
    REPRO_STEP("SDL_LoadBMP_IO: %d x %d at 32 bpp (%llu bytes of pixels)", WIDTH, HEIGHT,
               (unsigned long long)row * HEIGHT);
    SDL_Surface *s = SDL_LoadBMP_IO(SDL_IOFromConstMem(file, size), true);
    free(file);
    if (s) {
        SDL_DestroySurface(s);
        REPRO_OK("loaded (the file has only one row, so this is unexpected but not UB)");
    }
    REPRO_OK("refused without overflowing: %s", SDL_GetError());
}
