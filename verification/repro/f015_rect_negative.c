/* F-015 (negative size): SDL_RECT_CAN_OVERFLOW bounds w and h only from above, so w = INT_MIN
 * passes, and SDL_GetRectIntersection computes x + w in int: signed overflow. */
#include <SDL3/SDL.h>
#include "repro.h"

int main(void)
{
    const SDL_Rect a = { -1, 0, SDL_MIN_SINT32, 1 };
    const SDL_Rect b = { 0, 0, 10, 10 };
    SDL_Rect r;
    REPRO_STEP("SDL_GetRectIntersection with A = {-1, 0, INT_MIN, 1}");
    const bool hit = SDL_GetRectIntersection(&a, &b, &r);
    if (hit) {
        REPRO_BUG("an empty rect intersected: {%d,%d,%d,%d}", r.x, r.y, r.w, r.h);
    }
    REPRO_OK("no intersection (%s)", SDL_GetError());
}
