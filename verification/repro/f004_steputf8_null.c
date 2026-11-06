/* F-004: SDL_StepUTF8(&p, NULL) reads past the string's terminator.
 * The header: with a NULL length the function "will blindly read until it sees the NULL char".
 * A 2-byte heap string, a 4-byte lead then NUL, must stop at the NUL. */
#include <SDL3/SDL.h>
#include <stdlib.h>
#include "repro.h"

int main(void)
{
    char *s = (char *)malloc(2);
    s[0] = (char)0xF0;
    s[1] = '\0';
    const char *p = s;
    REPRO_STEP("SDL_StepUTF8 over F0 00 (heap, exactly 2 bytes), length NULL");
    const Uint32 cp = SDL_StepUTF8(&p, NULL);
    const int adv = (int)(p - s);
    free(s);
    if (cp != SDL_INVALID_UNICODE_CODEPOINT || adv != 1) {
        REPRO_BUG("cp=0x%X advanced=%d, expected U+FFFD advancing 1", (unsigned)cp, adv);
    }
    REPRO_OK("cp=0x%X advanced=%d, no read past the NUL", (unsigned)cp, adv);
}
