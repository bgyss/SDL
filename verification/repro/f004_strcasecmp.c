/* F-004 via SDL_strcasecmp, which steps each string as if 4 bytes were always available. */
#include <SDL3/SDL.h>
#include <stdlib.h>
#include "repro.h"

int main(void)
{
    char *s = (char *)malloc(2);
    s[0] = (char)0xF0;
    s[1] = '\0';
    REPRO_STEP("SDL_strcasecmp(\"\\xF0\", \"x\") on a 2-byte heap string");
    const int r = SDL_strcasecmp(s, "x");
    free(s);
    REPRO_OK("SDL_strcasecmp -> %d, no read past the NUL", r);
}
