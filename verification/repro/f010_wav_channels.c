/* F-010: SDL_LoadWAV_IO truncates the channel count to Uint8. A valid 256-channel 8-bit PCM
 * file loads with spec.channels == 0. Loading it with the right count, or refusing it, is fine. */
#include "wav.h"
#include "repro.h"

int main(void)
{
    static Uint8 file[44 + 512];
    const size_t size = make_pcm_wav(file, 256, 8, 256, 512);
    SDL_AudioSpec spec;
    Uint8 *data = NULL;
    Uint32 len = 0;
    if (!SDL_LoadWAV_IO(SDL_IOFromConstMem(file, size), true, &spec, &data, &len)) {
        REPRO_OK("256-channel file refused: %s", SDL_GetError());
    }
    SDL_free(data);
    printf("loaded: channels=%d freq=%d len=%u\n", spec.channels, spec.freq, (unsigned)len);
    if (spec.channels != 256) {
        REPRO_BUG("a 256-channel file loaded with spec.channels == %d", spec.channels);
    }
    REPRO_OK("spec.channels == 256");
}
