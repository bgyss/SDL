/* Corpus differential driver: prints the real SDL_StepUTF8 / SDL_StepBackUTF8 /
 * SDL_utf8strlcpy on one hex string per stdin line, in the format test/Utf8Corpus.lean prints
 * the Lean models. test/utf8_corpus.sh diffs the two. */
#include <SDL3/SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int hexval(int c)
{
    return c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10;
}

int main(void)
{
    static char line[1 << 16];
    static unsigned char s[1 << 15];
    static char dst[1 << 15];
    while (fgets(line, sizeof(line), stdin)) {
        size_t n = 0;
        for (const char *p = line; p[0] && p[1] && p[0] != '\n'; p += 2) {
            s[n++] = (unsigned char)(hexval(p[0]) * 16 + hexval(p[1]));
        }
        s[n] = 0;
        const char *str = (const char *)s;

        printf("F");
        const char *p = str;
        size_t left = n;
        for (;;) {
            const size_t at = (size_t)(p - str);
            const Uint32 cp = SDL_StepUTF8(&p, &left);
            if (!cp) break;
            printf(" %u@%zu", (unsigned)cp, at);
        }
        printf("\nB");
        p = str + n;
        for (;;) {
            const Uint32 cp = SDL_StepBackUTF8(str, &p);
            if (!cp) break;
            printf(" %u@%zu", (unsigned)cp, (size_t)(p - str));
        }
        printf("\nL");
        for (size_t d = 1; d <= n + 2; d++) {
            printf(" %zu", SDL_utf8strlcpy(dst, str, d));
        }
        printf("\n");
    }
    return 0;
}
