/* F-005: SDL_StepUTF8 returns values above U+10FFFF. RFC 3629 rejects them, and the header says
 * invalid input gives SDL_INVALID_UNICODE_CODEPOINT. */
#include <SDL3/SDL.h>
#include "repro.h"

int main(void)
{
    static const unsigned char seqs[][4] = {
        { 0xF4, 0x90, 0x80, 0x80 }, /* would be U+110000 */
        { 0xF5, 0x80, 0x80, 0x80 }, /* would be U+140000 */
        { 0xF7, 0xBF, 0xBF, 0xBF }, /* would be U+1FFFFF */
    };
    int bad = 0;
    for (int i = 0; i < 3; i++) {
        const char *p = (const char *)seqs[i];
        size_t len = 4;
        const Uint32 cp = SDL_StepUTF8(&p, &len);
        printf("%02X %02X %02X %02X -> 0x%X\n", seqs[i][0], seqs[i][1], seqs[i][2], seqs[i][3], (unsigned)cp);
        bad += cp != SDL_INVALID_UNICODE_CODEPOINT;
    }
    /* control: U+10FFFF, the largest code point, still decodes */
    const unsigned char max[4] = { 0xF4, 0x8F, 0xBF, 0xBF };
    const char *p = (const char *)max;
    size_t len = 4;
    const Uint32 cp = SDL_StepUTF8(&p, &len);
    if (cp != 0x10FFFF) {
        REPRO_BUG("control F4 8F BF BF -> 0x%X, expected 0x10FFFF", (unsigned)cp);
    }
    if (bad) {
        REPRO_BUG("%d of 3 sequences above U+10FFFF were returned as code points", bad);
    }
    REPRO_OK("all 3 rejected with U+FFFD; U+10FFFF still decodes");
}
