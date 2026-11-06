/* F-009: an empty joystick binding ("a:,") makes SDL_PrivateParseGamepadElement read
 * szJoystickButton[-1]. */
#include "gamepad.h"

int main(void)
{
    const int r = open_virtual_gamepad_with("a:,b:b1,");
    if (r == 2) {
        return 2;
    }
    REPRO_OK("empty binding handled without reading before the buffer (open %s)", r == 0 ? "succeeded" : "refused");
}
