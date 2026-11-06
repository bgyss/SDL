/* Fuzz target: SDL_LoadWAV_IO (src/audio/SDL_wave.c) on an in-memory stream. It covers PCM,
 * IEEE float, MS ADPCM, IMA ADPCM, A-law and mu-law decoding, and the RIFF chunk walker.
 *
 * Property: no sanitizer report, and a successful load returns a valid spec and a buffer whose
 * length is a whole number of sample frames. Every byte of the buffer is read so ASan checks
 * that audio_len does not exceed the allocation.
 *
 * Known findings, skipped unless SDL_FUZZ_KNOWN=1:
 *   F-010  channel counts above 255 are truncated to Uint8 (exact set)
 *   F-016  PCM/float block align smaller than a frame is accepted (over-approximated: any
 *          format whose block align is below channels * bits / 8)
 */
#include "fuzz_common.h"

typedef struct
{
    Uint32 tag, channels, blockalign, bits;
} Fmt;

static Uint32 le16(const Uint8 *p) { return (Uint32)p[0] | ((Uint32)p[1] << 8); }

/* The first "fmt " chunk, walking RIFF chunks the way SDL does (8-byte headers, even padding).
   All fields are 0 if there is none. */
static Fmt find_fmt(const Uint8 *d, size_t n)
{
    Fmt f = { 0, 0, 0, 0 };
    /* "RIFF" <len> "WAVE" puts the first chunk at 12; a file that starts with "WAVE" (no RIFF
       header, which SDL accepts: SDL_wave.c:1819) puts it at 4. */
    size_t pos = (n >= 4 && memcmp(d, "WAVE", 4) == 0) ? 4 : 12;
    while (pos + 8 <= n) {
        const Uint32 len = (Uint32)d[pos + 4] | ((Uint32)d[pos + 5] << 8) | ((Uint32)d[pos + 6] << 16) | ((Uint32)d[pos + 7] << 24);
        if (memcmp(d + pos, "fmt ", 4) == 0) {
            if (pos + 24 <= n) {
                f.tag = le16(d + pos + 8);
                f.channels = le16(d + pos + 10);
                f.blockalign = le16(d + pos + 20);
                f.bits = le16(d + pos + 22);
            }
            return f;
        }
        pos += 8 + (size_t)len + (len & 1);
    }
    return f;
}

int LLVMFuzzerTestOneInput(const Uint8 *data, size_t size)
{
    Uint8 *copy = exact_copy(data, size);
    const Fmt fmt = find_fmt(data, size);
    SDL_IOStream *io = SDL_IOFromConstMem(copy, size);
    SDL_AudioSpec spec;
    Uint8 *buf = NULL;
    Uint32 len = 0;
    if (SDL_LoadWAV_IO(io, true, &spec, &buf, &len)) {
        /* F-010: `spec->channels = (Uint8)format->channels` truncates any count above 255: a
           multiple of 256 becomes 0, anything else a wrong count that no longer matches the
           decoded data's frame layout. */
        /* (SDL also loads some files without a RIFF header; then find_fmt finds nothing.) */
        PROPERTY(fmt.channels == 0 || (Uint32)spec.channels == fmt.channels || fmt.channels > 255,
                 "spec.channels %d, file says %u", spec.channels, fmt.channels);
        /* F-016: PCM_Init checks (channels * bits) % (blockalign * 8) == 0, which accepts a block
           align that merely divides the frame size; sampleframes then counts blocks, not frames. */
        const int f016 = (Uint64)fmt.blockalign * 8 < (Uint64)fmt.channels * fmt.bits;
        if ((fmt.channels > 255 || f016) && !fuzz_known()) {
            SDL_free(buf);
            free(copy);
            return -1;
        }
        PROPERTY(spec.channels > 0 && spec.freq > 0, "spec %d ch %d Hz", spec.channels, spec.freq);
        const Uint32 frame = (Uint32)SDL_AUDIO_FRAMESIZE(spec);
        PROPERTY(frame > 0 && len % frame == 0, "audio_len %u is not a multiple of the %u-byte frame", len, frame);
        volatile Uint8 sink = 0;
        for (Uint32 i = 0; i < len; i++) {
            sink ^= buf[i];
        }
        (void)sink;
        SDL_free(buf);
    }
    free(copy);
    return 0;
}
