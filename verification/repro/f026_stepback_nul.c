/* F-026: SDL_StepBackUTF8 still skips stray continuation bytes when the walk back stops on a NUL.
 * Found by the CBMC harness verification/cbmc/harness/stepbackutf8.c. Bytes 00 BF BF: stepping
 * back from the end must report the stray 0xBF as U+FFFD and move back one byte, as F-008's fix
 * does for any other lead byte. Before the fix it returns 0 ("at the start") and jumps back over
 * both continuation bytes to the NUL. */
#include <SDL3/SDL.h>
#include "repro.h"

int main(void)
{
    static const char s[] = { '\0', '\xBF', '\xBF' };
    const char *p = s + sizeof(s);
    const Uint32 cp = SDL_StepBackUTF8(s, &p);
    printf("StepBack from the end of 00 BF BF -> 0x%X at offset %d\n", (unsigned)cp, (int)(p - s));
    if (cp != SDL_INVALID_UNICODE_CODEPOINT || p != s + 2) {
        REPRO_BUG("returned 0x%X at offset %d, expected U+FFFD at offset 2", (unsigned)cp, (int)(p - s));
    }
    REPRO_OK("the stray continuation byte before a NUL is reported as U+FFFD");
}
