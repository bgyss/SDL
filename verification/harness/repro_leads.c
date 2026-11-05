/* Reproduces leads L-1, L-2 and L-3 (verification/FINDINGS.md) against a real SDL build.
 * Build SDL with -fsanitize=address,undefined (see verification/harness/README.md), then:
 *
 *   repro_leads utf8-null   L-1: SDL_StepUTF8(&p, NULL) over-reads a heap string past its NUL
 *   repro_leads utf8-range  L-2: SDL_StepUTF8 returns code points above U+10FFFF
 *   repro_leads gamepad     L-3a: a 20-character game-button name is left unterminated
 *                           (only read by early-exiting comparisons, so ASan stays quiet)
 *   repro_leads gamepad-joy L-3b: a 128-character joystick binding is left unterminated and
 *                           then passed to SDL_strlen
 *
 * Each mode exercises exactly one lead, so an ASan report can be attributed to it.
 */
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int utf8_null(void)
{
    /* Exactly 2 bytes on the heap: a 4-byte lead, then the terminator. The header says that
       with pslen == NULL the function "will blindly read until it sees the NULL char". */
    char *s = (char *)malloc(2);
    s[0] = (char)0xF0;
    s[1] = '\0';
    const char *p = s;
    const Uint32 cp = SDL_StepUTF8(&p, NULL); /* ASan: heap-buffer-overflow READ expected here */
    printf("utf8-null: cp=0x%X advanced=%d (no ASan report means L-1 did not reproduce)\n",
           (unsigned)cp, (int)(p - s));
    free(s);
    return 0;
}

static int utf8_range(void)
{
    static const unsigned char cases[][4] = {
        { 0xF4, 0x90, 0x80, 0x80 }, /* would be U+110000 */
        { 0xF5, 0x80, 0x80, 0x80 }, /* would be U+140000 */
        { 0xF7, 0xBF, 0xBF, 0xBF }, /* would be U+1FFFFF */
        { 0xF4, 0x8F, 0xBF, 0xBF }, /* U+10FFFF, the largest valid code point (control) */
    };
    int bad = 0;
    for (size_t i = 0; i < SDL_arraysize(cases); i++) {
        const char *p = (const char *)cases[i];
        size_t len = 4;
        const Uint32 cp = SDL_StepUTF8(&p, &len);
        const int out_of_range = cp > 0x10FFFF;
        bad += out_of_range;
        printf("utf8-range: %02X %02X %02X %02X -> 0x%X%s\n", cases[i][0], cases[i][1],
               cases[i][2], cases[i][3], (unsigned)cp, out_of_range ? "  <-- above U+10FFFF" : "");
    }
    return bad ? 1 : 0;
}

static int gamepad(int joystick_side)
{
    if (!SDL_Init(SDL_INIT_GAMEPAD)) {
        printf("gamepad: SDL_Init failed: %s\n", SDL_GetError());
        return 2;
    }
    SDL_VirtualJoystickDesc desc;
    SDL_INIT_INTERFACE(&desc);
    desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    desc.nbuttons = 4;
    desc.name = "repro virtual pad";
    const SDL_JoystickID id = SDL_AttachVirtualJoystick(&desc);
    if (!id) {
        printf("gamepad: SDL_AttachVirtualJoystick failed: %s\n", SDL_GetError());
        return 2;
    }
    char guid[64];
    SDL_GUIDToString(SDL_GetJoystickGUIDForID(id), guid, sizeof(guid));

    char mapping[512];
    if (!joystick_side) {
        /* "abcdefghijklmnopqrst" is exactly 20 characters = sizeof(szGameButton). */
        SDL_snprintf(mapping, sizeof(mapping), "%s,repro,abcdefghijklmnopqrst:b0,a:b1,", guid);
    } else {
        /* "b" + 127 digits is exactly 128 characters = sizeof(szJoystickButton); "a" is a
           valid game button, so SDL_PrivateParseGamepadElement reaches its SDL_strlen. */
        char joy[129];
        joy[0] = 'b';
        memset(joy + 1, '0', 127);
        joy[128] = '\0';
        SDL_snprintf(mapping, sizeof(mapping), "%s,repro,a:%s,b:b1,", guid, joy);
    }
    printf("gamepad: adding mapping \"%s\"\n", mapping);
    if (SDL_AddGamepadMapping(mapping) < 0) {
        printf("gamepad: SDL_AddGamepadMapping failed: %s\n", SDL_GetError());
    }
    SDL_Gamepad *pad = SDL_OpenGamepad(id); /* parses the mapping: ASan report expected here */
    printf("gamepad: SDL_OpenGamepad -> %p (no ASan report means L-3 did not reproduce)\n", (void *)pad);
    if (pad) {
        char *used = SDL_GetGamepadMapping(pad);
        printf("gamepad: mapping in use: \"%s\"\n", used ? used : "(null)");
        SDL_free(used);
        SDL_CloseGamepad(pad);
    }
    SDL_DetachVirtualJoystick(id);
    SDL_Quit();
    return 0;
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "";
    if (strcmp(mode, "utf8-null") == 0) return utf8_null();
    if (strcmp(mode, "utf8-range") == 0) return utf8_range();
    if (strcmp(mode, "gamepad") == 0) return gamepad(0);
    if (strcmp(mode, "gamepad-joy") == 0) return gamepad(1);
    fprintf(stderr, "usage: %s utf8-null|utf8-range|gamepad|gamepad-joy\n", argv[0]);
    return 2;
}
