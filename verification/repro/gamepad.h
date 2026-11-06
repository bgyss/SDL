/* Opens a virtual gamepad with a given mapping body, so a gamepad-mapping bug can be reached
 * without hardware. SDL parses the mapping when the gamepad is opened. */
#ifndef REPRO_GAMEPAD_H
#define REPRO_GAMEPAD_H

#include <SDL3/SDL.h>
#include "repro.h"

/* Returns 0 if the mapping was added and the gamepad opened and closed, 1 otherwise (SDL may
   reject a bad mapping, which is fine). Returns 2 if SDL could not be set up. */
static int open_virtual_gamepad_with(const char *body)
{
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
    if (!id) {
        printf("SDL_AttachVirtualJoystick: %s\n", SDL_GetError());
        return 2;
    }
    char guid[33];
    SDL_GUIDToString(SDL_GetJoystickGUIDForID(id), guid, sizeof(guid));
    char mapping[600];
    SDL_snprintf(mapping, sizeof(mapping), "%s,repro pad,%s", guid, body);
    REPRO_STEP("SDL_AddGamepadMapping(\"%s\")", mapping);
    const int added = SDL_AddGamepadMapping(mapping);
    REPRO_STEP("added -> %d; SDL_OpenGamepad parses it", added);
    SDL_Gamepad *pad = SDL_OpenGamepad(id);
    if (pad) {
        SDL_CloseGamepad(pad);
    } else {
        printf("SDL_OpenGamepad: %s\n", SDL_GetError());
    }
    SDL_DetachVirtualJoystick(id);
    SDL_Quit();
    return pad ? 0 : 1;
}

#endif
