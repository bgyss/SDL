/* F-020: a lookup by audio device ID races with the device's last unref.
 *
 * ObtainPhysicalAudioDevice finds the device under the subsystem read lock, unlocks, and only
 * then takes a reference. UnrefPhysicalAudioDevice drops the count to 0 *before* it takes the
 * write lock to remove the device. So a lookup can find a device whose count is already 0,
 * resurrect it to 1, and touch it after the disconnect path frees it (or free it a second time
 * on its own unref). Model: verification/tla/audio_device/findings/find_then_ref.cfg.
 *
 * No real backend disconnects on demand, so this program plays the backend: it calls the two
 * internal hotplug entry points that every backend uses, SDL_AddAudioDevice and
 * SDL_AudioDeviceDisconnected. That needs a static SDL (they are not exported from the shared
 * library). Everything else is public API: the lookups are SDL_GetAudioDeviceFormat, which
 * goes through ObtainPhysicalAudioDevice.
 *
 * Each round adds a playback device nobody has open, publishes its ID to LOOKERS threads that
 * look it up in a loop, then disconnects it on the main thread. ASan reports the use after
 * free or double free if a lookup wins the race. REPRO_ROUNDS sets the round count. */
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include "repro.h"

/* Internal SDL entry points (src/audio/SDL_sysaudio.h). */
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
    (void)argc;
    (void)argv;
    const char *env = SDL_getenv("REPRO_ROUNDS");
    const int rounds = env ? SDL_atoi(env) : 200000;
    SDL_SetHint(SDL_HINT_AUDIO_DRIVER, "dummy");
    if (!SDL_Init(SDL_INIT_AUDIO)) {
        printf("SDL_Init: %s\n", SDL_GetError());
        return 2;
    }
    SDL_Thread *threads[LOOKERS];
    for (int i = 0; i < LOOKERS; i++) {
        threads[i] = SDL_CreateThread(looker, "looker", NULL);
    }
    REPRO_STEP("%d rounds of add + concurrent lookups + disconnect, %d lookup threads", rounds, LOOKERS);
    int missing = 0;
    for (int r = 1; r <= rounds; r++) {
        SDL_AudioDevice *dev = SDL_AddAudioDevice(false, "repro victim", NULL, NULL, (void *)(uintptr_t)(0x10000 + r));
        const SDL_AudioDeviceID id = dev ? find_by_name("repro victim") : 0;
        if (!id) {
            missing++;
            continue;
        }
        SDL_SetAtomicInt(&target, (int)id);
        const int before = SDL_GetAtomicInt(&lookups);
        while (SDL_GetAtomicInt(&lookups) - before < LOOKERS) {
            /* let every looker get going on this device */
        }
        SDL_AudioDeviceDisconnected(dev); /* on the main thread this runs the disconnect now */
        SDL_PumpEvents();                 /* deliver the pending added/removed events */
        SDL_FlushEvents(SDL_EVENT_FIRST, SDL_EVENT_LAST);
        if (r % 20000 == 0) {
            REPRO_STEP("round %d, %d lookups so far", r, SDL_GetAtomicInt(&lookups));
        }
    }
    SDL_SetAtomicInt(&done, 1);
    for (int i = 0; i < LOOKERS; i++) {
        SDL_WaitThread(threads[i], NULL);
    }
    SDL_Quit();
    if (missing) {
        REPRO_BUG("setup: %d rounds could not add the device", missing);
    }
    REPRO_OK("%d rounds, %d lookups, no use after free", rounds, SDL_GetAtomicInt(&lookups));
}
