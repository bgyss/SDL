/* F-008: SDL_StepBackUTF8 skips stray continuation bytes instead of returning U+FFFD.
 * Stepping forward over "a\x80" gives 'a', U+FFFD; stepping back from the end must see the
 * invalid 0x80 first. */
#include <SDL3/SDL.h>
#include "repro.h"

int main(void)
{
    const char *s = "a\x80";
    const char *p = s + 2;
    const Uint32 cp = SDL_StepBackUTF8(s, &p);
    printf("StepBack from the end of 61 80 -> 0x%X at offset %d\n", (unsigned)cp, (int)(p - s));
    if (cp != SDL_INVALID_UNICODE_CODEPOINT || p != s + 1) {
        REPRO_BUG("returned 0x%X at offset %d, expected U+FFFD at offset 1", (unsigned)cp, (int)(p - s));
    }
    REPRO_OK("the stray continuation byte is reported as U+FFFD");
}
