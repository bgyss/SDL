/* F-011: SDL_iconv_string to the generic "UTF-32" target writes a byte order mark only when
 * the input is long enough. For a 1-byte input the BOM is lost. */
#include <SDL3/SDL.h>
#include "repro.h"

int main(void)
{
    Uint32 *out = (Uint32 *)SDL_iconv_string("UTF-32", "UTF-8", "x", 1);
    if (!out) {
        REPRO_BUG("SDL_iconv_string failed: %s", SDL_GetError());
    }
    const Uint32 first = out[0];
    SDL_free(out);
    printf("first UTF-32 unit: 0x%08X\n", (unsigned)first);
    if (first != 0xFEFF) {
        REPRO_BUG("no BOM: output starts with 0x%08X", (unsigned)first);
    }
    REPRO_OK("output starts with the BOM");
}
