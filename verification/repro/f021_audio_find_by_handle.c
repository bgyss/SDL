/* F-021: a backend's find-by-handle lookup races with the device's last unref.
 *
 * Backends remove a device with SDL_AudioDeviceDisconnected(SDL_FindPhysicalAudioDeviceByHandle(h))
 * (ALSA, PipeWire, Android; PulseAudio and IMMDevice do the same through the callback form,
 * and several backends pass a found device to SDL_DefaultAudioDeviceChanged). The find holds
 * the subsystem read lock only while it searches, and returns a pointer without a reference.
 * SDL_AudioDeviceDisconnected then takes its reference. If the device's last reference goes away
 * in between, that reference lands on freed memory: the same window as F-020, in a different
 * function.
 *
 * This program plays such a backend: HOTPLUG threads repeatedly report "device h is gone" while
 * the main thread processes the disconnects (SDL_AudioDeviceDisconnected defers the work to
 * the main thread). It calls the backend-facing entry points from src/audio/SDL_sysaudio.h, so it
 * needs a static SDL.
 *
 * The trees differ in what a backend is supposed to call. Before the fix there is only the
 * unreferenced find, so that is what backends called. After it, backends call
 * SDL_FindAndRefPhysicalAudioDeviceByHandle and release the reference afterwards. CMake
 * defines REPRO_HAVE_FIND_AND_REF when the tree's SDL_sysaudio.h declares it, and the program
 * then uses the fixed backend code. REPRO_ROUNDS sets the round count. */
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include "repro.h"

typedef struct SDL_AudioDevice SDL_AudioDevice;
extern SDL_AudioDevice *SDL_AddAudioDevice(bool recording, const char *name, const char *unique_id, const SDL_AudioSpec *inspec, void *handle);
extern void SDL_AudioDeviceDisconnected(SDL_AudioDevice *device);
extern SDL_AudioDevice *SDL_FindPhysicalAudioDeviceByHandle(void *handle);
#ifdef REPRO_HAVE_FIND_AND_REF
extern SDL_AudioDevice *SDL_FindAndRefPhysicalAudioDeviceByHandle(void *handle);
extern void UnrefPhysicalAudioDevice(SDL_AudioDevice *device);
#endif

#define HOTPLUG 4

static void *target_handle; /* only accessed with SDL_Get/SetAtomicPointer */
static SDL_AtomicInt done;
static SDL_AtomicInt reports;

/* What a backend's hotplug thread does when the OS says the device with this handle is gone. */
static void backend_device_removed(void *handle)
{
#ifdef REPRO_HAVE_FIND_AND_REF
    SDL_AudioDevice *device = SDL_FindAndRefPhysicalAudioDeviceByHandle(handle);
    SDL_AudioDeviceDisconnected(device);
    UnrefPhysicalAudioDevice(device);
#else
    SDL_AudioDeviceDisconnected(SDL_FindPhysicalAudioDeviceByHandle(handle));
#endif
}

static int SDLCALL hotplug(void *unused)
{
    (void)unused;
    while (!SDL_GetAtomicInt(&done)) {
        void *h = SDL_GetAtomicPointer(&target_handle);
        if (h) {
            backend_device_removed(h);
            SDL_AddAtomicInt(&reports, 1);
        }
    }
    return 0;
}

int main(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    const char *env = SDL_getenv("REPRO_ROUNDS");
    const int rounds = env ? SDL_atoi(env) : 50000;
    SDL_SetHint(SDL_HINT_AUDIO_DRIVER, "dummy");
    if (!SDL_Init(SDL_INIT_AUDIO)) {
        printf("SDL_Init: %s\n", SDL_GetError());
        return 2;
    }
    SDL_Thread *threads[HOTPLUG];
    for (int i = 0; i < HOTPLUG; i++) {
        threads[i] = SDL_CreateThread(hotplug, "hotplug", NULL);
    }
    REPRO_STEP("%d rounds of add + concurrent removal reports, %d hotplug threads (%s backend code)", rounds, HOTPLUG,
#ifdef REPRO_HAVE_FIND_AND_REF
               "find-and-ref"
#else
               "unreferenced find"
#endif
    );
    for (int r = 1; r <= rounds; r++) {
        void *h = (void *)(uintptr_t)(0x10000 + r);
        if (!SDL_AddAudioDevice(false, "repro victim", NULL, NULL, h)) {
            REPRO_BUG("setup: could not add the device: %s", SDL_GetError());
        }
        SDL_SetAtomicPointer(&target_handle, h);
        const int before = SDL_GetAtomicInt(&reports);
        while (SDL_GetAtomicInt(&reports) - before < HOTPLUG) {
        }
        /* Process the queued disconnects while the hotplug threads keep reporting; the first one
           drops the device's last references. */
        const Uint64 until = SDL_GetTicksNS() + SDL_US_TO_NS(200);
        while (SDL_GetTicksNS() < until) {
            SDL_PumpEvents();
        }
        SDL_SetAtomicPointer(&target_handle, NULL);
        for (int i = 0; i < 1000 && SDL_FindPhysicalAudioDeviceByHandle(h); i++) {
            SDL_PumpEvents();
        }
        SDL_PumpEvents();
        SDL_FlushEvents(SDL_EVENT_FIRST, SDL_EVENT_LAST);
        if (r % 10000 == 0) {
            REPRO_STEP("round %d, %d removal reports so far", r, SDL_GetAtomicInt(&reports));
        }
    }
    SDL_SetAtomicInt(&done, 1);
    for (int i = 0; i < HOTPLUG; i++) {
        SDL_WaitThread(threads[i], NULL);
    }
    SDL_PumpEvents();
    SDL_Quit();
    REPRO_OK("%d rounds, %d removal reports, no use after free", rounds, SDL_GetAtomicInt(&reports));
}
