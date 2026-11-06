/* F-018: SDL_LoadBMP_IO flips a top-down image with biHeight = -biHeight, and only rejects
 * biHeight == 0 first, so biHeight == INT_MIN is negated: signed overflow. */
#include "bmp.h"
#include "repro.h"

int main(void)
{
    static Uint8 file[14 + 40 + 64];
    const Uint8 pixels[4] = { 0, 0, 0, 0 };
    const size_t size = make_bmp(file, 1, SDL_MIN_SINT32, 32, 0, 0, pixels, sizeof(pixels));
    REPRO_STEP("SDL_LoadBMP_IO with biHeight = INT_MIN");
    SDL_Surface *s = SDL_LoadBMP_IO(SDL_IOFromConstMem(file, size), true);
    if (s) {
        const int w = s->w, h = s->h;
        SDL_DestroySurface(s);
        REPRO_BUG("a BMP with height INT_MIN loaded as %dx%d", w, h);
    }
    REPRO_OK("refused: %s", SDL_GetError());
}
