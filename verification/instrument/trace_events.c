/* Trace program for tla/events_wait: the workload of verification/repro/f019 (the main thread
 * waits with SDL_WaitEventTimeout on a hidden window while another thread pushes one event per
 * round), on the instrumented SDL. The whole run is one trace, which trace_check.sh replays
 * against tla/events_wait/Trace.tla.
 *
 *   VERIF_TRACE_OUT=events.ndjson trace_events [rounds]
 *
 * SDL_EVENT_POLL_SENTINEL is disabled. The pump would otherwise add a sentinel that a later
 * GET removes without returning it, a queue change the model does not have. Waits never use
 * timeout 0, the only case where sentinels matter.
 */
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <stdlib.h>
#include "trace_hooks.h"

static SDL_AtomicInt round_no;
static SDL_AtomicInt done;
static Uint32 user_type;

static int SDLCALL pusher(void *unused)
{
    (void)unused;
    int seen = 0;
    Uint32 rng = 2463534242u;
    while (!SDL_GetAtomicInt(&done)) {
        const int r = SDL_GetAtomicInt(&round_no);
        if (r == seen) {
            continue;
        }
        seen = r;
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        const Uint64 until = SDL_GetTicksNS() + SDL_US_TO_NS(rng % 21);
        while (SDL_GetTicksNS() < until) {
        }
        SDL_Event e;
        SDL_zero(e);
        e.type = user_type;
        e.user.code = r;
        SDL_PushEvent(&e);
    }
    return 0;
}

int main(int argc, char **argv)
{
    const int rounds = argc > 1 ? atoi(argv[1]) : 200;
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 2;
    }
    SDL_SetEventEnabled(SDL_EVENT_POLL_SENTINEL, false);
    SDL_Window *win = SDL_CreateWindow("trace", 64, 64, SDL_WINDOW_HIDDEN);
    if (!win) {
        fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError());
        return 2;
    }
    user_type = SDL_RegisterEvents(1);
    SDL_Event e;
    for (int i = 0; i < 10; i++) { /* let startup events arrive, then drop them */
        SDL_PumpEvents();
        SDL_Delay(10);
    }
    SDL_FlushEvents(SDL_EVENT_FIRST, SDL_EVENT_LAST);
    SDL_Thread *t = SDL_CreateThread(pusher, "pusher", NULL);
    trace_start();
    int timeouts = 0;
    for (int r = 1; r <= rounds; r++) {
        SDL_SetAtomicInt(&round_no, r);
        for (;;) {
            if (!SDL_WaitEventTimeout(&e, 1000)) {
                timeouts++;
                continue;
            }
            if (e.type == user_type && e.user.code == r) {
                break;
            }
        }
    }
    trace_stop();
    SDL_SetAtomicInt(&done, 1);
    SDL_WaitThread(t, NULL);
    SDL_DestroyWindow(win);
    SDL_Quit();
    fprintf(stderr, "trace_events: %d rounds, %d timeouts\n", rounds, timeouts);
    return 0;
}
