/* Trace program for tla/audio_device: the same workload as verification/repro/f020 (a device
 * nobody has open is disconnected while LOOKERS threads look it up by ID), on the instrumented
 * SDL, for a few rounds. Each round's device gives one trace, which trace_check.sh replays
 * against tla/audio_device/Trace.tla.
 *
 *   VERIF_TRACE_OUT=audio.ndjson trace_audio [rounds]
 */
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <stdlib.h>
#include "trace_hooks.h"

typedef struct SDL_AudioDevice SDL_AudioDevice;
extern SDL_AudioDevice *SDL_AddAudioDevice(bool recording, const char *name, const char *unique_id, const SDL_AudioSpec *inspec, void *handle);
extern void SDL_AudioDeviceDisconnected(SDL_AudioDevice *device);

#define LOOKERS 4

static SDL_AtomicInt target;
static SDL_AtomicInt done;
static SDL_AtomicInt lookups;

static int SDLCALL looker(void *unused)
{
    (void)unused;
    while (!SDL_GetAtomicInt(&done)) {
        const SDL_AudioDeviceID id = (SDL_AudioDeviceID)SDL_GetAtomicInt(&target);
        if (id) {
            SDL_AudioSpec spec;
            (void)SDL_GetAudioDeviceFormat(id, &spec, NULL);
            SDL_AddAtomicInt(&lookups, 1);
        }
    }
    return 0;
}

static SDL_AudioDeviceID find_by_name(const char *name)
{
    int n = 0;
    SDL_AudioDeviceID *ids = SDL_GetAudioPlaybackDevices(&n);
    SDL_AudioDeviceID found = 0;
    for (int i = 0; ids && i < n; i++) {
        const char *s = SDL_GetAudioDeviceName(ids[i]);
        if (s && SDL_strcmp(s, name) == 0) {
            found = ids[i];
        }
    }
    SDL_free(ids);
    return found;
}

int main(int argc, char **argv)
{
    const int rounds = argc > 1 ? atoi(argv[1]) : 50;
    SDL_SetHint(SDL_HINT_AUDIO_DRIVER, "dummy");
    if (!SDL_Init(SDL_INIT_AUDIO)) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 2;
    }
    SDL_Thread *threads[LOOKERS];
    for (int i = 0; i < LOOKERS; i++) {
        threads[i] = SDL_CreateThread(looker, "looker", NULL);
    }
    trace_start();
    for (int r = 1; r <= rounds; r++) {
        SDL_AudioDevice *dev = SDL_AddAudioDevice(false, "trace victim", NULL, NULL, (void *)(uintptr_t)(0x10000 + r));
        const SDL_AudioDeviceID id = dev ? find_by_name("trace victim") : 0;
        if (!id) {
            fprintf(stderr, "round %d: could not add the device\n", r);
            return 2;
        }
        SDL_SetAtomicInt(&target, (int)id);
        const int before = SDL_GetAtomicInt(&lookups);
        while (SDL_GetAtomicInt(&lookups) - before < LOOKERS) {
        }
        SDL_AudioDeviceDisconnected(dev);
        /* keep the lookers going for a moment after the free, so the traces also show
           lookups that find nothing */
        const int after = SDL_GetAtomicInt(&lookups);
        while (SDL_GetAtomicInt(&lookups) - after < LOOKERS) {
        }
        SDL_SetAtomicInt(&target, 0);
        SDL_PumpEvents();
        SDL_FlushEvents(SDL_EVENT_FIRST, SDL_EVENT_LAST);
    }
    SDL_SetAtomicInt(&done, 1);
    for (int i = 0; i < LOOKERS; i++) {
        SDL_WaitThread(threads[i], NULL);
    }
    trace_stop();
    SDL_Quit();
    fprintf(stderr, "trace_audio: %d rounds, %d lookups\n", rounds, SDL_GetAtomicInt(&lookups));
    return 0;
}
