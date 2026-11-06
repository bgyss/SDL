/* Builds a minimal PCM WAV file in memory: RIFF header, a 16-byte "fmt " chunk, a "data"
 * chunk of datalen bytes. */
#ifndef REPRO_WAV_H
#define REPRO_WAV_H

#include <SDL3/SDL.h>

static Uint8 *put16(Uint8 *p, Uint16 v) { p[0] = (Uint8)v; p[1] = (Uint8)(v >> 8); return p + 2; }
static Uint8 *put32(Uint8 *p, Uint32 v) { p = put16(p, (Uint16)v); return put16(p, (Uint16)(v >> 16)); }
static Uint8 *put4cc(Uint8 *p, const char *s) { SDL_memcpy(p, s, 4); return p + 4; }

/* Returns the file size. buf must hold 44 + datalen bytes. */
static size_t make_pcm_wav(Uint8 *buf, Uint16 channels, Uint16 bits, Uint16 blockalign, Uint32 datalen)
{
    const Uint32 rate = 8000;
    Uint8 *p = buf;
    p = put4cc(p, "RIFF");
    p = put32(p, 36 + datalen);
    p = put4cc(p, "WAVE");
    p = put4cc(p, "fmt ");
    p = put32(p, 16);
    p = put16(p, 1); /* WAVE_FORMAT_PCM */
    p = put16(p, channels);
    p = put32(p, rate);
    p = put32(p, rate * blockalign);
    p = put16(p, blockalign);
    p = put16(p, bits);
    p = put4cc(p, "data");
    p = put32(p, datalen);
    SDL_memset(p, 0x80, datalen);
    return (size_t)(p - buf) + datalen;
}

#endif
