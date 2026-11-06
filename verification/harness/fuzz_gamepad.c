/* Fuzz target: gamepad mapping strings (SDL_AddGamepadMapping and the element parser that runs
 * when a gamepad using the mapping is opened, src/joystick/SDL_gamepad.c).
 *
 * Input: byte 0 picks the mode, the rest (up to the first NUL) is text.
 *   mode even: "<guid of a virtual joystick>,fuzz," + text, then open that gamepad, so the
 *              element parser (SDL_PrivateParseGamepadConfigString) runs on the text
 *   mode odd:  the text is the whole mapping (GUID, name, platform parsing)
 *
 * Known findings, skipped unless SDL_FUZZ_KNOWN=1 (see hits_known):
 *   F-006  a 128-character joystick half overflows szJoystickButton (over-read in SDL_strlen)
 *   F-009  an empty joystick half ("a:,") makes the parser read szJoystickButton[-1]
 *   F-013  (mode 1) an empty mapping body makes CreateMappingString read mapping[-1]
 *   F-004  (via SDL_strcasecmp) truncated 3/4-byte UTF-8 sequences, see hits_f004
 * Mode-1 mappings are added and printed back with SDL_GetGamepadMappingForGUID; their elements
 * are parsed only when a matching device is opened, which the harness does not do for them.
 */
#include "fuzz_common.h"

static SDL_JoystickID vjoy;
static char guid[64];

static void setup(void)
{
    if (vjoy) {
        return;
    }
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "0"); /* no real devices: deterministic runs */
    if (!SDL_Init(SDL_INIT_GAMEPAD)) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        abort();
    }
    SDL_VirtualJoystickDesc desc;
    SDL_INIT_INTERFACE(&desc);
    desc.type = SDL_JOYSTICK_TYPE_GAMEPAD;
    desc.naxes = 6;
    desc.nbuttons = 16;
    desc.nhats = 1;
    desc.name = "fuzz virtual pad";
    vjoy = SDL_AttachVirtualJoystick(&desc);
    if (!vjoy) {
        fprintf(stderr, "SDL_AttachVirtualJoystick: %s\n", SDL_GetError());
        abort();
    }
    SDL_GUIDToString(SDL_GetJoystickGUIDForID(vjoy), guid, sizeof(guid));
}

/* The known findings' trigger sets, by the same rules as the C tokenizer
   (SDL_PrivateParseGamepadConfigString): ':' switches to the joystick half and restarts its
   index *without clearing the buffer*, ',' ends an element and clears both buffers, spaces are
   skipped, and an element is parsed at ',' and at the end of the string if either buffer is
   non-empty. Because ':' does not clear, the buffer's content length is the high-water mark
   `jmax` since the last ',', not the current index.
   F-006: the joystick buffer was filled to 128 characters (no room for the terminator).
   F-009: the game half is non-empty and the joystick buffer is empty after an optional '+'/'-'
          sign, so `szJoystickButton[SDL_strlen(szJoystickButton) - 1]` indexes -1. This is an
          over-approximation: the C reaches that line only if the game half names a real
          button or axis. */
static int hits_known(const char *s)
{
    char game[21], joy[129];
    int in_joy = 0, gi = 0, ji = 0, jmax = 0;
    for (;; s++) {
        if (*s == ':') {
            in_joy = 1;
            ji = 0;
        } else if (*s == ' ') {
        } else if (*s == ',' || *s == '\0') {
            if (*s == ',' || gi || jmax) {
                if (jmax == 128) {
                    return 1; /* F-006 */
                }
                const int sign = jmax > 0 && (joy[0] == '+' || joy[0] == '-');
                if (gi > 0 && jmax - sign == 0) {
                    return 1; /* F-009 */
                }
            }
            if (!*s) {
                return 0;
            }
            in_joy = 0;
            gi = ji = jmax = 0;
        } else if (in_joy) {
            if (ji >= 128) {
                return 0; /* the C stops with "name too large" before parsing further */
            }
            joy[ji++] = *s;
            jmax = SDL_max(jmax, ji);
        } else {
            if (gi >= 20) {
                return 0;
            }
            game[gi++] = *s;
        }
    }
}

/* The mapping body SDL stores for the virtual joystick, i.e. the string the element parser
   later sees, rebuilt from the text after "guid,name," exactly as SDL_PrivateAddGamepadMapping
   does it:
   - SDL_PrivateGetGamepadMappingFromMappingString (SDL_gamepad.c:2073-2104) skips leading and
     trims trailing SDL_isspace characters;
   - the GUID has a CRC, so :2138-2160 cut the body at the first "crc:" (dropping that field up
     to and including its comma) and append "[,]crc:%04x," plus the rest. */
static char *stored_body(const char *text)
{
    while (SDL_isspace((unsigned char)*text)) {
        text++;
    }
    char *body = SDL_strdup(text);
    size_t len = SDL_strlen(body);
    while (len > 0 && SDL_isspace((unsigned char)body[len - 1])) {
        len--;
    }
    body[len] = '\0';

    Uint16 crc = 0;
    SDL_GetJoystickGUIDInfo(SDL_GetJoystickGUIDForID(vjoy), NULL, NULL, NULL, &crc);
    if (!crc) {
        return body;
    }
    const char *crc_end = "";
    char *crc_string = SDL_strstr(body, "crc:");
    if (crc_string) {
        crc_end = SDL_strchr(crc_string, ',');
        crc_end = crc_end ? crc_end + 1 : "";
        *crc_string = '\0';
    }
    len = SDL_strlen(body);
    const char *comma = (len == 0 || body[len - 1] == ',') ? "" : ",";
    char *out = NULL;
    SDL_asprintf(&out, "%s%scrc:%.4x,%s", body, comma, crc, crc_end);
    SDL_free(body);
    return out;
}

/* F-004 through SDL_strcasecmp, which calls StepUTF8 with a fixed length of 4
   (SDL_string.c:1494): a 3- or 4-byte lead byte whose sequence is cut short reads past the end
   of whatever heap string SDL copied the field into. Over-approximated trigger set: a lead
   byte E0-F7 not followed by 3 continuation bytes (for F0-F7) or 2 (for E0-EF). */
static int hits_f004(const Uint8 *s, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        if (s[i] >= 0xE0 && s[i] <= 0xF7) {
            const size_t need = s[i] >= 0xF0 ? 3 : 2;
            for (size_t k = 1; k <= need; k++) {
                if (i + k >= n || (s[i + k] & 0xC0) != 0x80) {
                    return 1;
                }
            }
        }
    }
    return 0;
}

int LLVMFuzzerTestOneInput(const Uint8 *data, size_t size)
{
    setup();
    Reader r = { data, size };
    const Uint8 mode = rd_u8(&r);
    const Uint8 *nul = (const Uint8 *)memchr(r.p, 0, r.left);
    const size_t n = nul ? (size_t)(nul - r.p) : r.left;
    if (!fuzz_known() && hits_f004(r.p, n)) {
        return -1;
    }

    if (mode & 1) {
        char *text = (char *)malloc(n + 1);
        memcpy(text, r.p, n);
        text[n] = '\0';
        /* F-013: nothing after "guid,name," is stored as an empty mapping, and printing it back
           (CreateMappingString) reads mapping[-1]. Over-approximated as "the text has two
           commas and nothing after the second". */
        const char *c1 = strchr(text, ',');
        const char *c2 = c1 ? strchr(c1 + 1, ',') : NULL;
        int f013 = c2 != NULL; /* SDL trims whitespace from the body (SDL_isspace) */
        for (const char *q = c2 ? c2 + 1 : ""; *q && f013; q++) {
            f013 = SDL_isspace((unsigned char)*q);
        }
        /* Mappings persist across runs, so an empty one must never be added at all: a later
           lookup of the same GUID would print it. */
        if (f013 && !fuzz_known()) {
            free(text);
            return -1;
        }
        if (SDL_AddGamepadMapping(text) >= 0) {
            char guidstr[33];
            SDL_strlcpy(guidstr, text, sizeof(guidstr));
            SDL_free(SDL_GetGamepadMappingForGUID(SDL_StringToGUID(guidstr)));
        }
        free(text);
        return 0;
    }

    const size_t len = strlen(guid) + 6 + n + 1;
    char *mapping = (char *)malloc(len);
    SDL_snprintf(mapping, len, "%s,fuzz,", guid);
    memcpy(mapping + strlen(guid) + 6, r.p, n);
    mapping[len - 1] = '\0';
    /* Check the known findings against the string SDL will parse (mapping->mapping), which is
       the input rewritten exactly as stored_body() does. This must happen *before* the add:
       mappings persist, and a later input whose hint: field makes SDL ignore it would open the
       gamepad with this one. */
    char *body = stored_body(mapping + strlen(guid) + 6);
    const int known = hits_known(body);
    if (getenv("SDL_FUZZ_DEBUG")) {
        fprintf(stderr, "stored body: [%s] known=%d\n", body, known);
    }
    SDL_free(body);
    if (known && !fuzz_known()) {
        free(mapping);
        return -1; /* F-006 or F-009; do not add to the corpus */
    }
    if (SDL_AddGamepadMapping(mapping) >= 0) {
        /* Opening also parses the mapping as CreateMappingString prints it, and that drops
           everything from a second "platform:" on: "platform:a,dpupplatform:ef" is parsed as
           "platform:a,dpup", whose "dpup" is F-009. So check SDL's printed form too, and on a
           hit put a benign mapping back so the bad one does not persist. */
        char *printed = SDL_GetGamepadMappingForGUID(SDL_GetJoystickGUIDForID(vjoy));
        const char *elems = printed ? strchr(printed, ',') : NULL;
        elems = elems ? strchr(elems + 1, ',') : NULL; /* the name is "fuzz": no commas */
        if (getenv("SDL_FUZZ_DEBUG")) {
            fprintf(stderr, "mapping for the device: %s\n", printed ? printed : "(none)");
        }
        const int printed_known = elems && hits_known(elems + 1);
        SDL_free(printed);
        if (printed_known && !fuzz_known()) {
            char reset[128];
            SDL_snprintf(reset, sizeof(reset), "%s,fuzz,a:b0,", guid);
            SDL_AddGamepadMapping(reset);
            free(mapping);
            return -1;
        }
        SDL_Gamepad *pad = SDL_OpenGamepad(vjoy);
        if (pad) {
            char *used = SDL_GetGamepadMapping(pad);
            PROPERTY(used != NULL, "open gamepad has no mapping");
            /* Round trip: the mapping SDL reports must itself be accepted. */
            PROPERTY(SDL_AddGamepadMapping(used) >= 0, "SDL rejects its own mapping string: %s", used);
            SDL_free(used);
            SDL_CloseGamepad(pad);
        }
    }
    free(mapping);
    return 0;
}
