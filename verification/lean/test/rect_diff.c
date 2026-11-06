/* Differential driver for the rect models (SDLVerif/Rect.lean, SDLVerif/RectLine.lean).
 *
 * Generates rect-function inputs from a fixed-seed PRNG: half the cases with every value in
 * [-20, 20] (so the rects overlap and the lines cross them), half weighted toward the boundaries
 * the guards care about (INT_MIN/MAX, SDL_MIN/MAX_SINT32 / 2 and their neighbours),
 * calls the real SDL functions, and prints one line per case: "<inputs> | <outputs>".
 * test/RectDiff.lean reads the same lines, recomputes the outputs from the inputs with the Lean
 * models, and prints them in the same format; test/rect_diff.sh diffs the two.
 *
 *   rect_diff [cases]
 */
#include <SDL3/SDL.h>
#include <stdio.h>
#include <stdlib.h>

static Uint64 rng = 0x9E3779B97F4A7C15ull;
static Uint32 next(void)
{
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return (Uint32)(rng >> 16);
}

/* Half the cases draw every value from [-20, 20], so rects overlap and lines cross them often
   (the interesting paths); the other half weight the guard boundaries. */
static int small_world;

static int val(void)
{
    if (small_world) {
        return (int)(next() % 41) - 20;
    }
    static const int boundary[] = {
        SDL_MIN_SINT32, SDL_MIN_SINT32 + 1, SDL_MIN_SINT32 / 2 - 1, SDL_MIN_SINT32 / 2,
        SDL_MIN_SINT32 / 2 + 1, -1000, -10, -2, -1, 0, 1, 2, 10, 1000, SDL_MAX_SINT32 / 2 - 1,
        SDL_MAX_SINT32 / 2, SDL_MAX_SINT32 / 2 + 1, SDL_MAX_SINT32 - 1, SDL_MAX_SINT32
    };
    const Uint32 r = next() % 10;
    if (r < 4) {
        return boundary[next() % SDL_arraysize(boundary)];
    } else if (r < 8) {
        return (int)(next() % 41) - 20;
    }
    return (int)next();
}

static void rect(SDL_Rect *r)
{
    r->x = val();
    r->y = val();
    r->w = val();
    r->h = val();
}

int main(int argc, char **argv)
{
    const int cases = argc > 1 ? atoi(argv[1]) : 100000;
    for (int i = 0; i < cases; i++) {
        small_world = (i & 1);
        SDL_Rect a, b, out = { 0, 0, 0, 0 };
        rect(&a);
        rect(&b);
        printf("R %d %d %d %d %d %d %d %d | ", a.x, a.y, a.w, a.h, b.x, b.y, b.w, b.h);
        printf("%d ", SDL_HasRectIntersection(&a, &b) ? 1 : 0);
        const bool ok = SDL_GetRectIntersection(&a, &b, &out);
        printf("%d %d %d %d %d ", ok ? 1 : 0, out.x, out.y, out.w, out.h);
        SDL_Rect u = { 0, 0, 0, 0 };
        if (SDL_GetRectUnion(&a, &b, &u)) {
            printf("1 %d %d %d %d\n", u.x, u.y, u.w, u.h);
        } else {
            printf("0\n");
        }

        SDL_Point pts[4];
        const int n = 1 + (int)(next() % 4);
        const bool with_clip = (next() & 1) != 0;
        SDL_Rect clip = { 0, 0, 0, 0 };
        if (with_clip) {
            rect(&clip);
        }
        printf("E %d %d %d %d %d %d", n, with_clip ? 1 : 0, clip.x, clip.y, clip.w, clip.h);
        for (int k = 0; k < n; k++) {
            pts[k].x = val();
            pts[k].y = val();
            printf(" %d %d", pts[k].x, pts[k].y);
        }
        SDL_Rect e = { 0, 0, 0, 0 };
        if (SDL_GetRectEnclosingPoints(pts, n, with_clip ? &clip : NULL, &e)) {
            printf(" | 1 %d %d %d %d\n", e.x, e.y, e.w, e.h);
        } else {
            printf(" | 0\n");
        }

        SDL_Rect lr;
        rect(&lr);
        int x1 = val(), y1 = val(), x2 = val(), y2 = val();
        printf("L %d %d %d %d %d %d %d %d | ", lr.x, lr.y, lr.w, lr.h, x1, y1, x2, y2);
        const bool hit = SDL_GetRectAndLineIntersection(&lr, &x1, &y1, &x2, &y2);
        printf("%d %d %d %d %d\n", hit ? 1 : 0, x1, y1, x2, y2);
    }
    return 0;
}
