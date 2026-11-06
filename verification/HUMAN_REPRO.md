# Reproducing the three original leads yourself

PLAN.md Phase 0 has a step that tooling cannot do for you. A person reproduces the leads on a
real sanitizer build, independently of the tooling, and decides what to do with them. This
guide makes that quick. Each program below is short enough to read in full. Each uses only the
public API, and none of them use `verification/harness/`. Type them in, or at least read them
before running them, rather than trusting the repro harness.

Record what you see in the "Human reproduction" line of each finding in `FINDINGS.md` (F-004,
F-005 and F-006), with the date, the machine and the SDL commit.

## 0. A sanitizer build

From the repo root, in the dev shell:

```sh
mise run asan:build          # ASan + UBSan SDL in ./build-asan (Apple clang on macOS)
git rev-parse --short HEAD   # note the commit; src/ should be unchanged from TRUSTED_BASE.md
```

Compile each program below the same way. On macOS, Apple clang is used because the nix clang's
ASan runtime hangs (see TRUSTED_BASE.md):

```sh
env -u SDKROOT -u DEVELOPER_DIR /usr/bin/clang -g -fsanitize=address,undefined \
  -I include prog.c -L build-asan -lSDL3 -Wl,-rpath,"$PWD/build-asan" -o prog && ./prog
```

On Linux, use `clang` with the same flags.

## 1. F-004: `SDL_StepUTF8(&p, NULL)` reads past the terminator

The header says that with a NULL length the function "will blindly read until it sees the NULL
char". So a string that ends inside a multi-byte sequence should stop at the NUL.

```c
#include <SDL3/SDL.h>
#include <stdio.h>
#include <stdlib.h>
int main(void) {
    char *s = malloc(2);            /* exactly 2 bytes: a 4-byte lead, then NUL */
    s[0] = (char)0xF0; s[1] = 0;
    const char *p = s;
    Uint32 cp = SDL_StepUTF8(&p, NULL);
    printf("cp=0x%X advanced=%d\n", (unsigned)cp, (int)(p - s));
    free(s);
    return 0;
}
```

**Expected:** ASan reports `heap-buffer-overflow ... READ of size 1 ... 0 bytes after 2-byte
region` in `StepUTF8` (`SDL_string.c:240`).

**Also check** (found while fuzzing): the same code path is reachable through `SDL_utf8strlen(s)`
and through `SDL_strcasecmp`, which calls `StepUTF8(&str, 4)` for every character
(`SDL_string.c:1494`). To see the second, replace the body with `SDL_strcasecmp(s, "x");`.

## 2. F-005: `SDL_StepUTF8` returns values above U+10FFFF

```c
#include <SDL3/SDL.h>
#include <stdio.h>
int main(void) {
    const unsigned char seqs[][4] = { {0xF4,0x90,0x80,0x80}, {0xF7,0xBF,0xBF,0xBF}, {0xF4,0x8F,0xBF,0xBF} };
    for (int i = 0; i < 3; i++) {
        const char *p = (const char *)seqs[i];
        size_t len = 4;
        printf("%02X %02X %02X %02X -> 0x%X\n", seqs[i][0], seqs[i][1], seqs[i][2], seqs[i][3],
               (unsigned)SDL_StepUTF8(&p, &len));
    }
    return 0;
}
```

**Expected:** `0x110000` and `0x1FFFFF` for the first two inputs. Both are above U+10FFFF, so
RFC 3629 rejects them, and the header says invalid input gives `0xFFFD`. The third input is
U+10FFFF, the largest valid code point, as a control.

## 3. F-006: a 128-character gamepad joystick binding

```c
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    SDL_Init(SDL_INIT_GAMEPAD);
    SDL_VirtualJoystickDesc d;
    SDL_INIT_INTERFACE(&d);
    d.type = SDL_JOYSTICK_TYPE_GAMEPAD; d.nbuttons = 4; d.name = "pad";
    SDL_JoystickID id = SDL_AttachVirtualJoystick(&d);
    char guid[33], joy[129], map[512];
    SDL_GUIDToString(SDL_GetJoystickGUIDForID(id), guid, sizeof(guid));
    joy[0] = 'b'; memset(joy + 1, '0', 127); joy[128] = 0;   /* exactly 128 characters */
    SDL_snprintf(map, sizeof(map), "%s,pad,a:%s,", guid, joy);
    SDL_AddGamepadMapping(map);
    SDL_Gamepad *g = SDL_OpenGamepad(id);                     /* parses the mapping */
    printf("opened: %p\n", (void *)g);
    SDL_CloseGamepad(g);
    SDL_Quit();
    return 0;
}
```

**Expected:** ASan reports `stack-buffer-overflow ... READ` in `strlen`, called from
`SDL_PrivateParseGamepadElement` (`SDL_gamepad.c:1706`), on the variable `szJoystickButton`.
With 127 characters instead of 128 there should be no report.

**The 20-character game-button side** (RESEARCH §10's original lead) is latent. Change the
mapping to `"%s,pad,abcdefghijklmnopqrst:b0,"` (20 characters before the `:`). The buffer is left
unterminated, but nothing reads past it today, so ASan stays quiet. If you can make ASan report
on that side, F-006 needs updating.

## 4. Optional: the new findings

These have tooling reproductions (see each entry in FINDINGS.md) and no human one yet. Below is
the shortest check for each:

| Finding | One-line check |
|---|---|
| F-007 | `char d[3]; SDL_utf8strlcpy(d, "\xE2\x82\xAC", 3);` leaves `E2 82`, a truncated sequence |
| F-008 | `SDL_StepBackUTF8` over `"a\x80"` from the end returns `'a'`, not U+FFFD |
| F-009 | gamepad mapping element `a:,`: ASan stack-buffer-overflow in `SDL_PrivateParseGamepadElement` |
| F-010 | WAV with 256 channels loads with `spec.channels == 0` |
| F-011 | `SDL_iconv_string("UTF-32", "UTF-8", "x", 1)` has no BOM, though 8 bytes of input do |
| F-013 | `SDL_AddGamepadMapping("05000000aabbccdd0000000000000000,x,")` then `SDL_GetGamepadMappingForGUID` on that GUID: ASan heap-buffer-overflow at `SDL_gamepad.c:2737` |
| F-019 | `mise run repro:wakeup`: count of waits that timed out with an event already queued |

`mise run repro -- <mode>` runs the harness versions (`gamepad-empty`, `mapping-empty`, …).

## 5. Then decide

PLAN.md's first open decision is yours: whether any finding goes upstream, and in whose words.
Upstream does not accept AI-written reports (CLAUDE.md, RESEARCH §8). A report would have to be
your own reproduction and your own write-up.
