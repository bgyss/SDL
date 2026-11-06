/* F-024: SDL_CreateSurface computes the pitch in size_t and stores it as `(int)pitch` without
 * checking that it fits. A 536,870,912 x 1 ARGB8888 surface has a pitch of 2^31 bytes, which
 * becomes INT_MIN: a surface with a negative pitch over a 2 GiB buffer, which every blit and
 * fill then trusts. Creating it must fail, or give a pitch that matches the allocation. */
#include <SDL3/SDL.h>
#include "repro.h"

int main(void)
{
    const int width = 536870912; /* 2^29 pixels * 4 bytes = 2^31-byte pitch */
    REPRO_STEP("SDL_CreateSurface(%d, 1, ARGB8888)", width);
    SDL_Surface *s = SDL_CreateSurface(width, 1, SDL_PIXELFORMAT_ARGB8888);
    if (!s) {
        REPRO_OK("refused: %s", SDL_GetError());
    }
    const int pitch = s->pitch;
    SDL_DestroySurface(s);
    if (pitch < 0 || (Sint64)pitch < (Sint64)width * 4) {
        REPRO_BUG("surface created with pitch %d for a row of %lld bytes", pitch, (long long)width * 4);
    }
    REPRO_OK("pitch %d", pitch);
}
