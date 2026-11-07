/* F-028: SDL_strrev("") computes &string[len - 1] with len == 0, a pointer one before the
 * string. Forming it is undefined behaviour (C11 6.5.6p8) even though it is never dereferenced;
 * UBSan reports the pointer overflow. Found by the CBMC harness verification/cbmc/harness/strrev.c.
 * SDL_strrev is SDL's own code everywhere but Windows (no HAVE__STRREV). */
#include <SDL3/SDL.h>
#include "repro.h"

int main(void)
{
    char empty[1] = { '\0' };
    char word[] = "abc";
    REPRO_STEP("SDL_strrev(\"\")");
    SDL_strrev(empty);
    SDL_strrev(word);
    if (empty[0] != '\0' || SDL_strcmp(word, "cba") != 0) {
        REPRO_BUG("SDL_strrev gave \"%s\" and \"%s\"", empty, word);
    }
    REPRO_OK("SDL_strrev reverses \"\" and \"abc\" without undefined behaviour");
}
