/* F-025: SDL_GetGamepadMapping does not report the mapping a gamepad uses when the mapping has
 * two "platform:" fields. CreateMappingString cuts the string at the second one, so every
 * element after it (here y:b2, and the crc field) is missing from the report, though the
 * gamepad still has those bindings. Setting the reported mapping back changes the gamepad.
 * Found by the gamepad differential test (verification/lean/test/gamepad_diff.sh). */
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include "repro.h"

static int count_bindings(SDL_JoystickID id)
{
    SDL_Gamepad *pad = SDL_OpenGamepad(id);
    int n = 0;
    SDL_free(SDL_GetGamepadBindings(pad, &n));
    SDL_CloseGamepad(pad);
    return n;
}

int main(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    if (!SDL_Init(SDL_INIT_GAMEPAD)) {
        printf("SDL_Init: %s\n", SDL_GetError());
        return 2;
    }
    SDL_VirtualJoystickDesc desc;
    SDL_INIT_INTERFACE(&desc);
    desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    desc.nbuttons = 4;
    desc.name = "repro pad";
    const SDL_JoystickID id = SDL_AttachVirtualJoystick(&desc);
    char guid[33], mapping[256];
    SDL_GUIDToString(SDL_GetJoystickGUIDForID(id), guid, sizeof(guid));
    SDL_snprintf(mapping, sizeof(mapping), "%s,repro pad,x:b1,platform:A,platform:B,y:b2,", guid);
    SDL_SetGamepadMapping(id, mapping);
    const int before = count_bindings(id);

    SDL_Gamepad *pad = SDL_OpenGamepad(id);
    char *reported = SDL_GetGamepadMapping(pad);
    SDL_CloseGamepad(pad);
    REPRO_STEP("set \"%s\" (%d bindings); SDL reports \"%s\"", mapping, before, reported);
    SDL_SetGamepadMapping(id, reported);
    const int after = count_bindings(id);
    SDL_free(reported);
    SDL_DetachVirtualJoystick(id);
    SDL_Quit();
    if (after != before) {
        REPRO_BUG("setting the reported mapping back changed the gamepad: %d bindings -> %d", before, after);
    }
    REPRO_OK("the reported mapping round-trips (%d bindings)", after);
}
