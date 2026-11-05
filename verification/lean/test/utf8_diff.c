/* Differential test driver: prints the real SDL_StepUTF8 on the same input grid as
 * test/Utf8Diff.lean prints the Lean model `cStep`. test/utf8_diff.sh diffs the two.
 *
 * Output line: "b0 b1 b2 b3 slen cp adv". slen 0..5 passes &slen; the extra "N" rows call
 * SDL_StepUTF8(&p, NULL), which SDL implements as StepUTF8(&p, 4); the Lean side prints those
 * rows from cStep with slen = 4.
 */
#include <SDL3/SDL.h>
#include <stdio.h>
#include <string.h>

static const unsigned char interesting[] = {
    0x00, 0x01, 0x3F, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xFF
};
#define NI (sizeof(interesting) / sizeof(interesting[0]))

int main(void)
{
    /* 4 input bytes, then padding so the slen 5 rows and over-reads stay in bounds here.
       (Over-reads themselves are covered by the Lean `reads` theorems and by ASan runs.) */
    char buf[16];
    for (unsigned b0 = 0; b0 < 256; b0++)
    for (unsigned i1 = 0; i1 < NI; i1++)
    for (unsigned i2 = 0; i2 < NI; i2++)
    for (unsigned i3 = 0; i3 < NI; i3++) {
        const unsigned b1 = interesting[i1], b2 = interesting[i2], b3 = interesting[i3];
        memset(buf, 0, sizeof(buf));
        buf[0] = (char)b0; buf[1] = (char)b1; buf[2] = (char)b2; buf[3] = (char)b3;
        for (size_t slen0 = 0; slen0 < 6; slen0++) {
            const char *p = buf;
            size_t slen = slen0;
            const Uint32 cp = SDL_StepUTF8(&p, &slen);
            printf("%u %u %u %u %zu %u %u\n", b0, b1, b2, b3, slen0, (unsigned)cp, (unsigned)(p - buf));
        }
        {
            const char *p = buf;
            const Uint32 cp = SDL_StepUTF8(&p, NULL);
            printf("%u %u %u %u N %u %u\n", b0, b1, b2, b3, (unsigned)cp, (unsigned)(p - buf));
        }
    }
    return 0;
}
