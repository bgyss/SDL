/* F-013: a mapping with nothing after "guid,name," is stored with an empty body, and
 * CreateMappingString reads mapping[strlen - 1], that is mapping[-1]. */
#include <SDL3/SDL.h>
#include "repro.h"

int main(void)
{
    if (!SDL_Init(SDL_INIT_GAMEPAD)) {
        printf("SDL_Init: %s\n", SDL_GetError());
        return 2;
    }
    const char *guid = "05000000aabbccdd0000000000000000"; /* no CRC field */
    char mapping[64];
    SDL_snprintf(mapping, sizeof(mapping), "%s,x,", guid);
    REPRO_STEP("SDL_AddGamepadMapping(\"%s\") -> %d", mapping, SDL_AddGamepadMapping(mapping));
    REPRO_STEP("SDL_GetGamepadMappingForGUID prints it back");
    char *back = SDL_GetGamepadMappingForGUID(SDL_StringToGUID(guid));
    printf("mapping: \"%s\"\n", back ? back : "(null)");
    SDL_free(back);
    SDL_Quit();
    REPRO_OK("empty mapping body printed without reading before the allocation");
}
