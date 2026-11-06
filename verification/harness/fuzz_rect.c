/* Fuzz target: the integer rect functions (src/video/SDL_rect_impl.h via SDL_rect.c).
 *
 * Input: a stream of big-endian 32-bit values: rect A, rect B, a line, a point count and points.
 * The interesting inputs are extreme coordinates. The functions guard rects with
 * SDL_RECT_CAN_OVERFLOW, but points and line endpoints are not guarded, so UBSan's
 * signed-overflow check is the main oracle.
 *
 * Algebraic properties (the ones Phase 5's Rect.lean will prove) are checked when the inputs
 * are inside the range the overflow guard accepts:
 * - intersection is commutative and contained in both inputs
 * - union contains both inputs
 * - clipped line endpoints lie inside the rect
 *
 * Known findings, skipped unless SDL_FUZZ_KNOWN=1:
 *   F-012  signed overflow in SDL_GetRectEnclosingPoints (exact set: enclose_overflows)
 *   F-014  signed overflow in SDL_GetRectAndLineIntersection (over-approximated: line_wild)
 *   F-015  negative w/h pass the overflow guard (over-approximated: any negative w/h)
 */
#include "fuzz_common.h"

static SDL_Rect rd_rect(Reader *r)
{
    SDL_Rect rc;
    rc.x = (int)rd_u32(r);
    rc.y = (int)rd_u32(r);
    rc.w = (int)rd_u32(r);
    rc.h = (int)rd_u32(r);
    return rc;
}

static int contains(const SDL_Rect *outer, const SDL_Rect *inner)
{
    /* Compare in 64 bits so the check itself cannot overflow. */
    return (Sint64)inner->x >= outer->x && (Sint64)inner->y >= outer->y &&
           (Sint64)inner->x + inner->w <= (Sint64)outer->x + outer->w &&
           (Sint64)inner->y + inner->h <= (Sint64)outer->y + outer->h;
}

static int inside(const SDL_Rect *rc, int x, int y)
{
    return x >= rc->x && (Sint64)x < (Sint64)rc->x + rc->w && y >= rc->y && (Sint64)y < (Sint64)rc->y + rc->h;
}

static int guarded(const SDL_Rect *rc)
{
    return rc->x > SDL_MIN_SINT32 / 2 && rc->x < SDL_MAX_SINT32 / 2 && rc->y > SDL_MIN_SINT32 / 2 &&
           rc->y < SDL_MAX_SINT32 / 2 && rc->w < SDL_MAX_SINT32 / 2 && rc->h < SDL_MAX_SINT32 / 2;
}

/* F-012's exact set: SDL_GetRectEnclosingPoints (SDL_rect_impl.h:196-295) has no overflow
   guard. With a clip it computes clip->x + clip->w - 1 (and the same for y) in int before
   anything else; then it computes (maxx - minx) + 1 over the points it keeps (all points, or
   the ones inside the clip). Returns 1 if any of those int operations overflows. */
static int enclose_overflows(const SDL_Point *pts, int count, const SDL_Rect *clip)
{
    Sint64 cx0 = 0, cy0 = 0, cx1 = 0, cy1 = 0;
    if (clip) {
        const Sint64 sx = (Sint64)clip->x + clip->w, sy = (Sint64)clip->y + clip->h;
        if (sx > SDL_MAX_SINT32 || sx < SDL_MIN_SINT32 || sx - 1 < SDL_MIN_SINT32 ||
            sy > SDL_MAX_SINT32 || sy < SDL_MIN_SINT32 || sy - 1 < SDL_MIN_SINT32) {
            return 1;
        }
        if (clip->w <= 0 || clip->h <= 0) {
            return 0; /* SDL_RECTEMPTY(clip): returns before touching the points */
        }
        cx0 = clip->x; cy0 = clip->y; cx1 = sx - 1; cy1 = sy - 1;
    }
    int any = 0;
    Sint64 minx = 0, maxx = 0, miny = 0, maxy = 0;
    for (int i = 0; i < count; i++) {
        const Sint64 x = pts[i].x, y = pts[i].y;
        if (clip && (x < cx0 || x > cx1 || y < cy0 || y > cy1)) {
            continue;
        }
        if (!any) {
            minx = maxx = x; miny = maxy = y; any = 1;
            continue;
        }
        minx = SDL_min(minx, x); maxx = SDL_max(maxx, x);
        miny = SDL_min(miny, y); maxy = SDL_max(maxy, y);
    }
    return any && (maxx - minx + 1 > SDL_MAX_SINT32 || maxy - miny + 1 > SDL_MAX_SINT32);
}

int LLVMFuzzerTestOneInput(const Uint8 *data, size_t size)
{
    Reader r = { data, size };
    const SDL_Rect a = rd_rect(&r), b = rd_rect(&r);
    SDL_Rect res, res2;

    /* F-015: SDL_RECT_CAN_OVERFLOW bounds w and h only from above, so a negative width or height
       passes the guard; x + w, then (x + w) - 1 or Amax - Amin, can overflow before any
       emptiness check. Over-approximated trigger set: a negative w or h in either rect. */
    const int neg_wild = a.w < 0 || a.h < 0 || b.w < 0 || b.h < 0;
    if (neg_wild && !fuzz_known()) {
        return -1;
    }
    const bool has = SDL_HasRectIntersection(&a, &b);
    const bool got = SDL_GetRectIntersection(&a, &b, &res);
    const bool got2 = SDL_GetRectIntersection(&b, &a, &res2);
    if (guarded(&a) && guarded(&b)) {
        PROPERTY(has == got && got == got2, "HasRectIntersection %d, GetRectIntersection %d/%d", has, got, got2);
        if (got) {
            PROPERTY(SDL_RectsEqual(&res, &res2), "intersection is not commutative");
            PROPERTY(contains(&a, &res) && contains(&b, &res), "intersection not inside both inputs");
        }
    }
    /* F-015 also covers valid rects: the guard allows x, y in (INT_MIN/2, INT_MAX/2) and w, h up
       to INT_MAX/2, so the union of two non-empty rects can span up to ~3 * 2^30 and
       `result->w = Amax - Amin` (SDL_rect_impl.h:176, :192) overflows. Exact set, computed in
       64 bits. */
    const int both = a.w > 0 && a.h > 0 && b.w > 0 && b.h > 0;
    const Sint64 ux = SDL_max((Sint64)a.x + a.w, (Sint64)b.x + b.w) - SDL_min(a.x, b.x);
    const Sint64 uy = SDL_max((Sint64)a.y + a.h, (Sint64)b.y + b.h) - SDL_min(a.y, b.y);
    const int union_wild = both && (ux > SDL_MAX_SINT32 || uy > SDL_MAX_SINT32);
    if ((fuzz_known() || !union_wild) && SDL_GetRectUnion(&a, &b, &res) && guarded(&a) && guarded(&b)) {
        PROPERTY(SDL_RectEmpty(&a) || contains(&res, &a), "union does not contain A");
        PROPERTY(SDL_RectEmpty(&b) || contains(&res, &b), "union does not contain B");
    }

    int x1 = (int)rd_u32(&r), y1 = (int)rd_u32(&r), x2 = (int)rd_u32(&r), y2 = (int)rd_u32(&r);
    /* F-014: the Cohen-Sutherland loop computes x2 - x1, y - y1, ... in int before widening
       (SDL_rect_impl.h:411-425); endpoints are not range-checked. Over-approximated trigger set:
       any endpoint coordinate outside (INT_MIN/2, INT_MAX/2). Inside it, and with the rect
       guarded, every such difference fits in an int. */
    const int line_wild = !(guarded(&(SDL_Rect){ x1, y1, 0, 0 }) && guarded(&(SDL_Rect){ x2, y2, 0, 0 }));
    if ((fuzz_known() || !line_wild) && SDL_GetRectAndLineIntersection(&a, &x1, &y1, &x2, &y2)) {
        PROPERTY(inside(&a, x1, y1) && inside(&a, x2, y2), "clipped line (%d,%d)-(%d,%d) outside rect", x1, y1, x2, y2);
    }

    const int count = 1 + rd_u8(&r) % 64;
    SDL_Point *pts = (SDL_Point *)malloc(sizeof(SDL_Point) * (size_t)count);
    for (int i = 0; i < count; i++) {
        pts[i].x = (int)rd_u32(&r);
        pts[i].y = (int)rd_u32(&r);
    }
    if (fuzz_known() || !enclose_overflows(pts, count, NULL)) {
        SDL_GetRectEnclosingPoints(pts, count, NULL, &res);
    }
    if ((fuzz_known() || !enclose_overflows(pts, count, &b)) &&
        SDL_GetRectEnclosingPoints(pts, count, &b, &res) && guarded(&b)) {
        PROPERTY(contains(&b, &res), "enclosing rect of clipped points is outside the clip");
    }
    free(pts);
    return 0;
}
