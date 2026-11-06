/* F-012: SDL_GetRectEnclosingPoints has no overflow guard. For points at INT_MIN and INT_MAX it
 * computes (maxx - minx) + 1 in int: signed overflow. Refusing the input is fine. */
#include <SDL3/SDL.h>
#include "repro.h"

int main(void)
{
    const SDL_Point pts[2] = { { SDL_MIN_SINT32, 0 }, { SDL_MAX_SINT32, 0 } };
    SDL_Rect r;
    REPRO_STEP("SDL_GetRectEnclosingPoints over x = INT_MIN and INT_MAX");
    const bool ok = SDL_GetRectEnclosingPoints(pts, 2, NULL, &r);
    if (ok && (r.w <= 0 || (Sint64)r.x + r.w < SDL_MAX_SINT32)) {
        REPRO_BUG("returned {%d,%d,%d,%d}, which does not enclose both points", r.x, r.y, r.w, r.h);
    }
    REPRO_OK("%s", ok ? "enclosing rect returned" : SDL_GetError());
}
