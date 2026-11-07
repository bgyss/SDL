/* F-029: SDL_ltoa(LONG_MIN) and SDL_lltoa(LLONG_MIN) negate the most negative value, which is
 * signed overflow (UB); UBSan reports the negation. Found by the CBMC harness
 * verification/cbmc/harness/ltoa.c. SDL_ltoa/SDL_lltoa are SDL's own code on every platform
 * (POSIX has no _ltoa, and the Windows configs leave HAVE__LTOA unset). */
#include <SDL3/SDL.h>
#include <limits.h>
#include "repro.h"

int main(void)
{
    char buf[sizeof(long long) * 8 + 2];
    REPRO_STEP("SDL_ltoa(LONG_MIN, 10)");
    SDL_ltoa(LONG_MIN, buf, 10);
    char want[sizeof(buf)];
    SDL_snprintf(want, sizeof(want), "%ld", LONG_MIN);
    if (SDL_strcmp(buf, want) != 0) {
        REPRO_BUG("SDL_ltoa(LONG_MIN) gave \"%s\", expected \"%s\"", buf, want);
    }
    REPRO_STEP("SDL_lltoa(LLONG_MIN, 10)");
    SDL_lltoa(LLONG_MIN, buf, 10);
    SDL_snprintf(want, sizeof(want), "%lld", LLONG_MIN);
    if (SDL_strcmp(buf, want) != 0) {
        REPRO_BUG("SDL_lltoa(LLONG_MIN) gave \"%s\", expected \"%s\"", buf, want);
    }
    REPRO_OK("SDL_ltoa(LONG_MIN) and SDL_lltoa(LLONG_MIN) print the value without overflow");
}
