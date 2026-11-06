/* F-022: a gamepad mapping can bind a trigger to a joystick axis whose number does not fit in
 * an int. SDL_PrivateParseGamepadElement converts it with SDL_atoi (undefined on overflow; -1
 * here). SDL_PrivateLoadButtonMapping then zeroes trigger axes with
 * `if (axis < joystick->naxes) joystick->axes[axis]...`, which a negative index passes, so it
 * reads and writes joystick->axes[-1]. Found by fuzz_gamepad on the fixed tree, 2026-11-05. */
#include "gamepad.h"

int main(void)
{
    const int r = open_virtual_gamepad_with("lefttrigger:a99999999999999999999,a:b0,");
    if (r == 2) {
        return 2;
    }
    REPRO_OK("out-of-range axis number handled without indexing outside the axes (open %s)", r == 0 ? "succeeded" : "refused");
}
