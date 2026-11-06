/* Writes the generated seed corpora into <dir>/<target>/ (fuzz.sh seeds). The seeds are small,
 * valid examples of each format variant, so the fuzzer starts from inputs that pass the format
 * checks and reach the decoders. The text seeds come from SDL's own test cases where possible.
 */
#include <SDL3/SDL.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char root[1024];

static void put(const char *target, const char *name, const void *data, size_t len)
{
    char path[1200];
    SDL_snprintf(path, sizeof(path), "%s/%s", root, target);
    SDL_CreateDirectory(path);
    SDL_snprintf(path, sizeof(path), "%s/%s/%s", root, target, name);
    if (!SDL_SaveFile(path, data, len)) {
        fprintf(stderr, "write %s: %s\n", path, SDL_GetError());
        exit(1);
    }
}

/* ---- little-endian byte builder ---- */
typedef struct { Uint8 b[8192]; size_t n; } Buf;
static void u8(Buf *B, unsigned v) { B->b[B->n++] = (Uint8)v; }
static void u16(Buf *B, unsigned v) { u8(B, v & 0xFF); u8(B, (v >> 8) & 0xFF); }
static void u32(Buf *B, Uint32 v) { u16(B, v & 0xFFFF); u16(B, v >> 16); }
static void bytes(Buf *B, const void *p, size_t n) { memcpy(B->b + B->n, p, n); B->n += n; }
static void patch32(Buf *B, size_t at, Uint32 v) { for (int i = 0; i < 4; i++) B->b[at + i] = (Uint8)(v >> (8 * i)); }

/* ---- BMP ---- */
static void bmp_saved(const char *name, SDL_PixelFormat fmt)
{
    SDL_Surface *s = SDL_CreateSurface(5, 3, fmt);
    if (SDL_ISPIXELFORMAT_INDEXED(fmt)) {
        SDL_Palette *pal = SDL_CreateSurfacePalette(s);
        for (int i = 0; i < pal->ncolors; i++) {
            SDL_Color c = { (Uint8)(i * 37), (Uint8)(i * 11), (Uint8)(255 - i), 255 };
            SDL_SetPaletteColors(pal, &c, i, 1);
        }
    }
    for (int y = 0; y < s->h; y++) {
        for (int x = 0; x < s->pitch; x++) {
            ((Uint8 *)s->pixels)[y * s->pitch + x] = (Uint8)(x * 7 + y * 13);
        }
    }
    SDL_IOStream *io = SDL_IOFromDynamicMem();
    if (!SDL_SaveBMP_IO(s, io, false)) {
        fprintf(stderr, "SaveBMP %s: %s\n", name, SDL_GetError());
        exit(1);
    }
    const Sint64 len = SDL_GetIOSize(io);
    void *mem = SDL_GetPointerProperty(SDL_GetIOProperties(io), SDL_PROP_IOSTREAM_DYNAMIC_MEMORY_POINTER, NULL);
    put("fuzz_bmp", name, mem, (size_t)len);
    SDL_CloseIO(io);
    SDL_DestroySurface(s);
}

/* A classic BITMAPINFOHEADER file with a palette; `compression` 1 = RLE8, 2 = RLE4. */
static void bmp_classic(const char *name, int bpp, int compression, const Uint8 *pixels, size_t plen, int w, int h)
{
    Buf B = { { 0 }, 0 };
    const int ncolors = 1 << bpp;
    const Uint32 offbits = 14 + 40 + 4 * ncolors;
    u8(&B, 'B'); u8(&B, 'M'); u32(&B, (Uint32)(offbits + plen)); u32(&B, 0); u32(&B, offbits);
    u32(&B, 40); u32(&B, (Uint32)w); u32(&B, (Uint32)h); u16(&B, 1); u16(&B, (unsigned)bpp);
    u32(&B, (Uint32)compression); u32(&B, (Uint32)plen); u32(&B, 2835); u32(&B, 2835);
    u32(&B, (Uint32)ncolors); u32(&B, 0);
    for (int i = 0; i < ncolors; i++) {
        u8(&B, i * 255 / (ncolors - 1)); u8(&B, 255 - i * 255 / (ncolors - 1)); u8(&B, i * 17); u8(&B, 0);
    }
    bytes(&B, pixels, plen);
    put("fuzz_bmp", name, B.b, B.n);
}

static void bmp_seeds(void)
{
    bmp_saved("index8.bmp", SDL_PIXELFORMAT_INDEX8);
    bmp_saved("rgb24.bmp", SDL_PIXELFORMAT_BGR24);
    bmp_saved("xrgb8888.bmp", SDL_PIXELFORMAT_XRGB8888);
    bmp_saved("argb8888.bmp", SDL_PIXELFORMAT_ARGB8888); /* V4/V5 header with masks */
    bmp_saved("rgb565.bmp", SDL_PIXELFORMAT_RGB565);
    /* 4x2 RLE8: encoded runs, an absolute run, end of line, delta, end of bitmap. */
    static const Uint8 rle8[] = { 2, 1, 2, 7, 0, 0, 0, 3, 4, 5, 6, 0, 0, 2, 1, 0, 0, 1 };
    bmp_classic("rle8.bmp", 8, 1, rle8, sizeof(rle8), 4, 2);
    static const Uint8 rle4[] = { 4, 0x12, 0, 0, 0, 4, 0x34, 0x56, 0, 1 };
    bmp_classic("rle4.bmp", 4, 2, rle4, sizeof(rle4), 4, 2);
    static const Uint8 bits1[] = { 0xA0, 0, 0, 0, 0x50, 0, 0, 0 };
    bmp_classic("bits1.bmp", 1, 0, bits1, sizeof(bits1), 4, 2);
    static const Uint8 bits4[] = { 0x01, 0x23, 0, 0, 0x45, 0x67, 0, 0 };
    bmp_classic("bits4.bmp", 4, 0, bits4, sizeof(bits4), 4, 2);
}

/* ---- WAV ---- */
/* fmt fields, then optional extra bytes after cbSize. */
static void wav(const char *name, unsigned tag, unsigned ch, Uint32 rate, unsigned bits, unsigned align,
                const Uint8 *ext, unsigned extlen, const Uint8 *pcm, size_t plen)
{
    Buf B = { { 0 }, 0 };
    bytes(&B, "RIFF", 4); u32(&B, 0); bytes(&B, "WAVE", 4);
    bytes(&B, "fmt ", 4); u32(&B, 16 + (ext ? 2 + extlen : 0));
    u16(&B, tag); u16(&B, ch); u32(&B, rate); u32(&B, rate * align); u16(&B, align); u16(&B, bits);
    if (ext) { u16(&B, extlen); bytes(&B, ext, extlen); }
    bytes(&B, "data", 4); u32(&B, (Uint32)plen); bytes(&B, pcm, plen);
    if (plen & 1) u8(&B, 0);
    patch32(&B, 4, (Uint32)(B.n - 8));
    put("fuzz_wav", name, B.b, B.n);
}

static void wav_seeds(void)
{
    Uint8 pcm[1024];
    for (size_t i = 0; i < sizeof(pcm); i++) pcm[i] = (Uint8)(i * 31);
    wav("u8_mono.wav", 1, 1, 8000, 8, 1, NULL, 0, pcm, 64);
    wav("s16_stereo.wav", 1, 2, 22050, 16, 4, NULL, 0, pcm, 128);
    wav("s24_mono.wav", 1, 1, 44100, 24, 3, NULL, 0, pcm, 96);
    wav("s32_mono.wav", 1, 1, 48000, 32, 4, NULL, 0, pcm, 128);
    wav("f32_stereo.wav", 3, 2, 48000, 32, 8, NULL, 0, pcm, 128);
    wav("alaw.wav", 6, 1, 8000, 8, 1, NULL, 0, pcm, 64);
    wav("mulaw.wav", 7, 1, 8000, 8, 1, NULL, 0, pcm, 64);
    /* WAVE_FORMAT_EXTENSIBLE: valid bits, channel mask, PCM sub-format GUID. */
    static const Uint8 extensible[22] = { 16, 0, 3, 0, 0, 0, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
                                          0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71 };
    wav("extensible_s16.wav", 0xFFFE, 2, 44100, 16, 4, extensible, sizeof(extensible), pcm, 128);
    /* MS ADPCM, mono, 256-byte blocks: samplesPerBlock = (256 - 7) * 2 + 2 = 500, 7 standard
       coefficient pairs. Block header: predictor 0, delta 16, two int16 samples. */
    static const Sint16 coef[14] = { 256, 0, 512, -256, 0, 0, 192, 64, 240, 0, 460, -208, 392, -232 };
    Uint8 msext[32];
    msext[0] = 500 & 0xFF; msext[1] = 500 >> 8; msext[2] = 7; msext[3] = 0;
    for (int i = 0; i < 14; i++) { msext[4 + 2 * i] = (Uint8)(coef[i] & 0xFF); msext[5 + 2 * i] = (Uint8)((Uint16)coef[i] >> 8); }
    Uint8 block[256];
    memcpy(block, pcm, sizeof(block));
    block[0] = 0; block[1] = 16; block[2] = 0;
    wav("msadpcm.wav", 2, 1, 22050, 4, 256, msext, sizeof(msext), block, sizeof(block));
    /* IMA ADPCM, mono, 256-byte blocks: samplesPerBlock = (256 - 4) * 2 + 1 = 505. Block
       header: int16 sample, step index 0..88, reserved 0. */
    static const Uint8 imaext[2] = { 505 & 0xFF, 505 >> 8 };
    block[0] = 0; block[1] = 0; block[2] = 10; block[3] = 0;
    wav("imaadpcm.wav", 0x11, 1, 22050, 4, 256, imaext, sizeof(imaext), block, sizeof(block));
}

/* ---- text targets ---- */
static void text(const char *target, const char *name, Uint8 b0, const char *s)
{
    Buf B = { { 0 }, 0 };
    u8(&B, b0);
    bytes(&B, s, strlen(s));
    put(target, name, B.b, B.n);
}

static void utf8_seeds(void)
{
    /* byte 0: strlcpy size selector; bytes 1-4: encoder code point (big-endian); then text. */
    static const struct { const char *name; Uint8 sel; Uint32 cp; const char *s; } seeds[] = {
        { "ascii", 5, 'A', "Hello, world" },
        { "mixed", 3, 0x20AC, "a\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80z" },
        { "first_char_cut", 3, 0x1F600, "\xE2\x82\xAC\xE2\x82\xAC" },
        { "invalid", 9, 0xD800, "\x80\xC0\xAF\xE0\x80\x80\xED\xA0\x80\xF8\x88\x80\x80\x80\xFF" },
        { "out_of_range", 4, 0x110000, "\xF4\x90\x80\x80\xF7\xBF\xBF\xBF" },
        { "stray_cont", 2, 0x10FFFF, "a\x80\xC3\xA9\x80\x80" },
        { "truncated_tail", 7, 0x7FF, "ok\xF0\x9F\x98" },
        /* From test/testautomation_stdlib.c's UTF-8 cases. */
        { "testautomation", 12, 0xFFFF, "\xe5\xa4\xa9\xe6\xb0\x94\xe5\xa5\xbd\xe3\x80\x82" },
    };
    for (size_t i = 0; i < SDL_arraysize(seeds); i++) {
        Buf B = { { 0 }, 0 };
        u8(&B, seeds[i].sel);
        u8(&B, seeds[i].cp >> 24); u8(&B, (seeds[i].cp >> 16) & 0xFF); u8(&B, (seeds[i].cp >> 8) & 0xFF); u8(&B, seeds[i].cp & 0xFF);
        bytes(&B, seeds[i].s, strlen(seeds[i].s));
        put("fuzz_utf8", seeds[i].name, B.b, B.n);
    }
}

static void iconv_seeds(void)
{
    /* encodings[] indices in fuzz_iconv.c: 2 UTF-8, 3 UTF-16, 4 UTF-16BE, 5 UTF-16LE, 6 UTF-32,
       0 ASCII, 1 ISO-8859-1, 9 UCS-2, 13 UCS-4. */
    static const struct { const char *name; Uint8 from, to, chunk; const char *s; size_t n; } seeds[] = {
        { "utf8_to_utf16", 2, 3, 3, "a\xC3\xA9\xE2\x82\xAC\xF0\x9F\x98\x80", 10 },
        { "utf8_to_utf32", 2, 6, 5, "x\xF4\x8F\xBF\xBF", 5 },
        { "utf16le_to_utf8", 5, 2, 1, "\x3D\xD8\x00\xDE\x41\x00", 6 },
        { "utf16be_lone_surrogate", 4, 2, 4, "\xD8\x3D\x00\x41", 4 },
        { "latin1_to_utf8", 1, 2, 2, "caf\xE9", 4 },
        { "utf8_to_ascii", 2, 0, 7, "na\xC3\xAFve", 6 },
        { "ucs4_to_utf8", 13, 2, 3, "\x00\x01\xF6\x00\x00\x11\x00\x00", 8 },
        { "utf16_bom", 3, 2, 2, "\xFF\xFE\x41\x00\x42\x00", 6 },
    };
    for (size_t i = 0; i < SDL_arraysize(seeds); i++) {
        Buf B = { { 0 }, 0 };
        u8(&B, seeds[i].from); u8(&B, seeds[i].to); u8(&B, seeds[i].chunk);
        bytes(&B, seeds[i].s, seeds[i].n);
        put("fuzz_iconv", seeds[i].name, B.b, B.n);
    }
}

static void rect_seeds(void)
{
    /* Big-endian int32 stream: A(x,y,w,h) B(x,y,w,h) line(x1,y1,x2,y2) count points... ;
       cases modelled on test/testautomation_rect.c. */
    static const Sint32 seeds[][17] = {
        { 0, 0, 10, 10, 5, 5, 10, 10, -5, 3, 20, 7, 4, 1, 1, 9, 9 },
        { 0, 0, 10, 10, 20, 20, 5, 5, 0, 0, 9, 9, 2, -3, 4, 15, 2 },
        { -100, -100, 50, 50, -80, -90, 0, 10, -200, -75, 200, -75, 3, 0, 0, -100, -100 },
        { 1073741822, 0, 1, 1, 0, 1073741822, 1, 1, 2147483647, 0, -2147483647 - 1, 0, 2, 2147483647, -2147483647 - 1, -2147483647 - 1, 2147483647 },
    };
    for (size_t i = 0; i < SDL_arraysize(seeds); i++) {
        Buf B = { { 0 }, 0 };
        for (int k = 0; k < 17; k++) {
            const Uint32 v = (Uint32)seeds[i][k];
            if (k == 12) { u8(&B, v); continue; } /* the count is one byte */
            u8(&B, v >> 24); u8(&B, (v >> 16) & 0xFF); u8(&B, (v >> 8) & 0xFF); u8(&B, v & 0xFF);
        }
        char name[32];
        SDL_snprintf(name, sizeof(name), "case%zu", i);
        put("fuzz_rect", name, B.b, B.n);
    }
}

static void gamepad_seeds(void)
{
    /* Mode 0: element list only (appended to "<guid>,fuzz,"). Styles from SDL_gamepad_db.h. */
    text("fuzz_gamepad", "elements_basic", 0,
         "a:b0,b:b1,back:b6,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b8,leftshoulder:b4,"
         "leftstick:b9,lefttrigger:a2,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b10,"
         "righttrigger:a5,rightx:a3,righty:a4,start:b7,x:b2,y:b3,");
    text("fuzz_gamepad", "elements_halfaxes", 0,
         "leftx:-a0~,lefty:+a1,-rightx:b3,+rightx:b4,righttrigger:a5~,dpup:-a2,dpdown:+a2,"
         "misc1:b11,paddle1:b12,touchpad:b13,crc:abcd,hint:!SDL_GAMECONTROLLER_USE_BUTTON_LABELS:=1,");
    text("fuzz_gamepad", "elements_platform", 0, "a:b0,b:b1,platform:Mac OS X,face:abxy,type:ps5,");
    /* Mode 1: whole mappings, GUID and name parsing. */
    text("fuzz_gamepad", "mapping_full", 1,
         "030000005e0400008e02000014010000,Xbox 360 Controller,a:b0,b:b1,x:b2,y:b3,platform:Linux,");
    text("fuzz_gamepad", "mapping_xinput", 1, "xinput,XInput Controller,a:b0,b:b1,leftx:a0,lefty:a1,");
    text("fuzz_gamepad", "mapping_quoted", 1, "03000000,\"Name, with comma\",a:b0,");
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <corpus dir>\n", argv[0]);
        return 2;
    }
    SDL_strlcpy(root, argv[1], sizeof(root));
    SDL_CreateDirectory(root);
    bmp_seeds();
    wav_seeds();
    utf8_seeds();
    iconv_seeds();
    rect_seeds();
    gamepad_seeds();
    printf("seeds written to %s\n", root);
    return 0;
}
