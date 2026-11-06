/* Differential driver for the gamepad mapping model (SDLVerif/GamepadMapping.lean).
 *
 * For each mapping body it sets "<guid>,diff,<body>" on a virtual joystick, opens it as a
 * gamepad, and prints one line: "<mapping SDL stores> | <bindings SDL parsed>". The stored mapping
 * (SDL_GetGamepadMapping) is what SDL_PrivateParseGamepadConfigString actually parsed, after any
 * rewriting SDL does when it adds a mapping; test/GamepadDiff.lean recomputes the bindings from
 * it with the Lean model, and test/gamepad_diff.sh diffs the two.
 *
 * Bodies: every mapping in SDL's own database (SDL_GetGamepadMappings, with any platform field
 * removed so it applies here), then generated bodies built from real element names, real and
 * malformed bindings, signs, '~', spaces, extra ':' and over-long tokens.
 *
 *   gamepad_diff [generated cases]
 */
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static Uint64 rng = 0x2545F4914F6CDD1Dull;
static Uint32 next(void)
{
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return (Uint32)(rng >> 16);
}

static SDL_JoystickID id;
static char guid[33];

static void print_binding(const SDL_GamepadBinding *b)
{
    switch (b->input_type) {
    case SDL_GAMEPAD_BINDTYPE_AXIS:
        printf(" a%d,%d,%d", b->input.axis.axis, b->input.axis.axis_min, b->input.axis.axis_max);
        break;
    case SDL_GAMEPAD_BINDTYPE_BUTTON:
        printf(" b%d", b->input.button);
        break;
    case SDL_GAMEPAD_BINDTYPE_HAT:
        printf(" h%d.%d", b->input.hat.hat, b->input.hat.hat_mask);
        break;
    default:
        printf(" ?");
    }
    if (b->output_type == SDL_GAMEPAD_BINDTYPE_AXIS) {
        printf(">a%d,%d,%d", b->output.axis.axis, b->output.axis.axis_min, b->output.axis.axis_max);
    } else {
        printf(">b%d", b->output.button);
    }
}

static void run(const char *body)
{
    char *mapping = NULL;
    if (SDL_getenv("GAMEPAD_DIFF_TRACE")) {
        fprintf(stderr, "%s\n", body);
    }
    SDL_asprintf(&mapping, "%s,diff,%s", guid, body);
    if (!SDL_SetGamepadMapping(id, mapping) && SDL_getenv("GAMEPAD_DIFF_DEBUG")) {
        fprintf(stderr, "set failed (%s): %s\n", SDL_GetError(), mapping);
    }
    SDL_free(mapping);
    SDL_Gamepad *pad = SDL_OpenGamepad(id);
    if (!pad) {
        return;
    }
    char *stored = SDL_GetGamepadMapping(pad);
    int count = 0;
    SDL_GamepadBinding **binds = SDL_GetGamepadBindings(pad, &count);
    /* one line per case; the stored mapping never contains '|' or a newline here */
    if (stored && !strchr(stored, '|') && !strchr(stored, '\n')) {
        printf("%s |", stored);
        for (int i = 0; i < count; i++) {
            print_binding(binds[i]);
        }
        printf("\n");
    }
    SDL_free(binds);
    SDL_free(stored);
    SDL_CloseGamepad(pad);
}

static const char *pick(const char *const *list, size_t n) { return list[next() % n]; }

static void gen_token(char *out, size_t cap)
{
    static const char *const names[] = {
        "a", "b", "x", "y", "back", "guide", "start", "leftstick", "rightstick", "leftshoulder",
        "rightshoulder", "dpup", "dpdown", "dpleft", "dpright", "misc1", "paddle1", "touchpad",
        "leftx", "lefty", "rightx", "righty", "lefttrigger", "righttrigger", "LeftX", "A",
        "platform", "hint", "crc", "bogus", ""
    };
    static const char *const binds[] = {
        "b0", "b1", "b17", "a0", "a1", "a5", "a3~", "h0.1", "h0.4", "h1.8", "h9.15", "b",
        "a", "h0", "h.1", "hx.1", "a3xyz", "b12junk", "a2147483647", "a2147483648",
        "b99999999999999999999", "h0.2147483648", "", "~", "c3"
    };
    char name[64], bind[64];
    const Uint32 r = next() % 8;
    SDL_snprintf(name, sizeof(name), "%s%s", r == 0 ? "+" : (r == 1 ? "-" : (r == 2 ? "++" : "")),
                 pick(names, SDL_arraysize(names)));
    const Uint32 s = next() % 6;
    SDL_snprintf(bind, sizeof(bind), "%s%s", s == 0 ? "+" : (s == 1 ? "-" : ""), pick(binds, SDL_arraysize(binds)));
    switch (next() % 12) {
    case 0: SDL_snprintf(out, cap, "%s", name); break;                       /* no ':' */
    case 1: SDL_snprintf(out, cap, "%s:%s:%s", name, bind, pick(binds, SDL_arraysize(binds))); break;
    case 2: SDL_snprintf(out, cap, " %s : %s ", name, bind); break;          /* spaces */
    case 3: {                                                                /* long name */
        char longname[32];
        const int len = 18 + (int)(next() % 4);                              /* 18..21 */
        SDL_memset(longname, 'q', len);
        longname[len] = '\0';
        SDL_snprintf(out, cap, "%s:%s", longname, bind);
        break;
    }
    case 4: {                                                                /* long binding */
        char longbind[160];
        const int len = 125 + (int)(next() % 5);                             /* 125..129 */
        longbind[0] = 'b';
        SDL_memset(longbind + 1, '0', len - 1);
        longbind[len] = '\0';
        SDL_snprintf(out, cap, "%s:%s", name, longbind);
        break;
    }
    default: SDL_snprintf(out, cap, "%s:%s", name, bind); break;
    }
}

int main(int argc, char **argv)
{
    const int cases = argc > 1 ? atoi(argv[1]) : 20000;
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "0");
    if (!SDL_Init(SDL_INIT_GAMEPAD)) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 2;
    }
    SDL_VirtualJoystickDesc desc;
    SDL_INIT_INTERFACE(&desc);
    desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    desc.naxes = 6;
    desc.nbuttons = 32;
    desc.nhats = 4;
    desc.name = "diff pad";
    id = SDL_AttachVirtualJoystick(&desc);
    SDL_GUIDToString(SDL_GetJoystickGUIDForID(id), guid, sizeof(guid));

    /* SDL's own database */
    int n = 0;
    char **db = SDL_getenv("GAMEPAD_DIFF_NO_DB") ? NULL : SDL_GetGamepadMappings(&n);
    for (int i = 0; db && i < n; i++) {
        const char *body = db[i];
        for (int commas = 0; commas < 2 && body; commas++) {
            body = strchr(body, ',');
            if (body) {
                body++;
            }
        }
        if (!body) {
            continue;
        }
        /* drop a platform field so the mapping applies on this platform */
        char buf[2048];
        SDL_strlcpy(buf, body, sizeof(buf));
        char *p = strstr(buf, "platform:");
        if (p) {
            char *end = strchr(p, ',');
            if (end) {
                memmove(p, end + 1, strlen(end + 1) + 1);
            } else {
                *p = '\0';
            }
        }
        run(buf);
    }
    SDL_free(db);

    /* generated bodies */
    for (int c = 0; c < cases; c++) {
        char body[2048] = "";
        const int elems = 1 + (int)(next() % 8);
        for (int e = 0; e < elems; e++) {
            char tok[400];
            gen_token(tok, sizeof(tok));
            SDL_strlcat(body, tok, sizeof(body));
            if (e + 1 < elems || (next() & 1)) {
                SDL_strlcat(body, (next() % 10) ? "," : ",,", sizeof(body));
            }
        }
        run(body);
    }
    SDL_DetachVirtualJoystick(id);
    SDL_Quit();
    return 0;
}
