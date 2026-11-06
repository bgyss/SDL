/* F-014: SDL_GetRectAndLineIntersection guards the rect but not the line. Clipping a line from
 * x = -2e9 to x = 2e9 computes x2 - x1 in int: signed overflow. */
#include <SDL3/SDL.h>
#include "repro.h"

int main(void)
{
    const SDL_Rect rect = { 0, 0, 10, 10 };
    int x1 = -2000000000, y1 = -1, x2 = 2000000000, y2 = 11;
    REPRO_STEP("SDL_GetRectAndLineIntersection, line (-2e9,-1)-(2e9,11) through {0,0,10,10}");
    const bool hit = SDL_GetRectAndLineIntersection(&rect, &x1, &y1, &x2, &y2);
    REPRO_OK("%s", hit ? "clipped" : "no intersection or refused");
}
