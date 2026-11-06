/* F-006: a joystick binding of exactly 128 characters fills szJoystickButton[128] with no
 * terminator, and SDL_PrivateParseGamepadElement then calls SDL_strlen on it. */
#include <string.h>
#include "gamepad.h"

int main(void)
{
    char body[200];
    char joy[129];
    joy[0] = 'b';
    memset(joy + 1, '0', 127);
    joy[128] = '\0'; /* exactly 128 characters */
    SDL_snprintf(body, sizeof(body), "a:%s,b:b1,", joy);
    const int r = open_virtual_gamepad_with(body);
    if (r == 2) {
        return 2;
    }
    REPRO_OK("128-character binding handled without reading past the buffer (open %s)", r == 0 ? "succeeded" : "refused");
}
