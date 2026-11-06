/* Builds a BMP file in memory: a 14-byte file header and a 40-byte BITMAPINFOHEADER, then an
 * optional palette and the pixel data. */
#ifndef REPRO_BMP_H
#define REPRO_BMP_H

#include <SDL3/SDL.h>

static Uint8 *bmp_put16(Uint8 *p, Uint16 v) { p[0] = (Uint8)v; p[1] = (Uint8)(v >> 8); return p + 2; }
static Uint8 *bmp_put32(Uint8 *p, Uint32 v) { p = bmp_put16(p, (Uint16)v); return bmp_put16(p, (Uint16)(v >> 16)); }

/* compression: 0 = BI_RGB, 1 = BI_RLE8. Returns the file size. */
static size_t make_bmp(Uint8 *buf, Sint32 width, Sint32 height, Uint16 bpp, Uint32 compression,
                       Uint32 palette_colors, const Uint8 *pixels, Uint32 pixels_len)
{
    const Uint32 offbits = 14 + 40 + palette_colors * 4;
    Uint8 *p = buf;
    *p++ = 'B';
    *p++ = 'M';
    p = bmp_put32(p, offbits + pixels_len);
    p = bmp_put32(p, 0);
    p = bmp_put32(p, offbits);
    p = bmp_put32(p, 40);
    p = bmp_put32(p, (Uint32)width);
    p = bmp_put32(p, (Uint32)height);
    p = bmp_put16(p, 1);
    p = bmp_put16(p, bpp);
    p = bmp_put32(p, compression);
    p = bmp_put32(p, pixels_len);
    p = bmp_put32(p, 2835);
    p = bmp_put32(p, 2835);
    p = bmp_put32(p, palette_colors);
    p = bmp_put32(p, 0);
    for (Uint32 i = 0; i < palette_colors; i++) {
        p = bmp_put32(p, i * 0x010101u);
    }
    SDL_memcpy(p, pixels, pixels_len);
    return (size_t)(p - buf) + pixels_len;
}

#endif
