/* F-015 (wide union): two rects that each pass the overflow guard can be ~3 * 2^30 apart, and
 * SDL_GetRectUnion computes w = Amax - Amin in int: signed overflow. Refusing is fine. */
#include <SDL3/SDL.h>
#include "repro.h"

int main(void)
{
    const SDL_Rect a = { -1073741800, 0, 10, 10 };
    const SDL_Rect b = { 1073741800, 0, 1073741800, 10 };
    SDL_Rect r;
    REPRO_STEP("SDL_GetRectUnion of {-1073741800,0,10,10} and {1073741800,0,1073741800,10}");
    const bool ok = SDL_GetRectUnion(&a, &b, &r);
    if (ok && r.w <= 0) {
        REPRO_BUG("union has width %d", r.w);
    }
    REPRO_OK("%s", ok ? "union returned" : SDL_GetError());
}
