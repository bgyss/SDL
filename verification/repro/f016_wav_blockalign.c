/* F-016: SDL_LoadWAV_IO accepts a block align smaller than one sample frame. With 17 channels
 * of 8 bits (a 17-byte frame) and blockalign 1, audio_len is not a whole number of frames. */
#include "wav.h"
#include "repro.h"

int main(void)
{
    static Uint8 file[44 + 64];
    const size_t size = make_pcm_wav(file, 17, 8, 1, 64);
    SDL_AudioSpec spec;
    Uint8 *data = NULL;
    Uint32 len = 0;
    if (!SDL_LoadWAV_IO(SDL_IOFromConstMem(file, size), true, &spec, &data, &len)) {
        REPRO_OK("block align 1 for a 17-byte frame refused: %s", SDL_GetError());
    }
    SDL_free(data);
    const int frame = SDL_AUDIO_FRAMESIZE(spec);
    printf("loaded: channels=%d frame=%d bytes audio_len=%u\n", spec.channels, frame, (unsigned)len);
    if (frame == 0 || len % (Uint32)frame != 0) {
        REPRO_BUG("audio_len %u is not a whole number of %d-byte frames", (unsigned)len, frame);
    }
    REPRO_OK("audio_len is whole frames");
}
