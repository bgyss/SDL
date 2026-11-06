/* F-007: SDL_utf8strlcpy keeps a truncated sequence when the cut falls inside the first
 * character. The header: the result "does not end in a truncated multi-byte sequence". */
#include <SDL3/SDL.h>
#include "repro.h"

int main(void)
{
    char d[3];
    SDL_memset(d, 0x55, sizeof(d));
    SDL_utf8strlcpy(d, "\xE2\x82\xAC", sizeof(d)); /* U+20AC needs 3 bytes + NUL; only 2 fit */
    const size_t n = SDL_strlen(d);
    printf("dst: %d bytes:", (int)n);
    for (size_t i = 0; i < n; i++) {
        printf(" %02X", (unsigned char)d[i]);
    }
    printf("\n");
    if (n != 0) {
        REPRO_BUG("SDL_utf8strlcpy(dst, \"\\u20AC\", 3) left a truncated %d-byte sequence", (int)n);
    }
    REPRO_OK("a character that does not fit whole is not copied");
}
