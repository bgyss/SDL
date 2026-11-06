/* Tries to reproduce the lost wakeup in SDL_WaitEventTimeout_Device on a real build (FINDINGS
 * F-019, model: tla/events_wait/findings/lost_wakeup.cfg).
 *
 * The main thread opens a hidden window (so the device wait path with SendWakeupEvent is used)
 * and waits for events with a 1 s timeout. A worker thread pushes one user event per round, at
 * a randomized delay after the main thread signals that it is about to wait again. If the push
 * lands between the waiter's queue check and its store to wakeup_window, no wakeup is posted
 * and the wait only ends at the timeout (or on an unrelated OS event): a "stall".
 *
 *   repro_wakeup [rounds] [max_delay_us]
 *
 * Prints the number of stalls: waits that took >= 900 ms although an event had been pushed.
 */
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <stdio.h>
#include <stdlib.h>

static SDL_AtomicInt round_started; /* main -> worker: round number now waiting */
static SDL_AtomicInt quit;
static Uint32 user_type;
static int max_delay_us = 200;

static int SDLCALL worker(void *arg)
{
    (void)arg;
    int last = 0;
    Uint64 seed = 0x9E3779B97F4A7C15ull;
    while (!SDL_GetAtomicInt(&quit)) {
        const int r = SDL_GetAtomicInt(&round_started);
        if (r == last) {
            continue; /* spin: keeps the timing tight */
        }
        last = r;
        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17;
        const Uint64 delay = SDL_US_TO_NS(seed % (Uint64)(max_delay_us + 1));
        const Uint64 until = SDL_GetTicksNS() + delay;
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
    const int rounds = argc > 1 ? atoi(argv[1]) : 20000;
    if (argc > 2) {
        max_delay_us = atoi(argv[2]);
    }
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        printf("SDL_Init: %s\n", SDL_GetError());
        return 2;
    }
    SDL_Window *win = SDL_CreateWindow("repro_wakeup", 64, 64, SDL_WINDOW_HIDDEN);
    if (!win) {
        printf("SDL_CreateWindow: %s\n", SDL_GetError());
        return 2;
    }
    user_type = SDL_RegisterEvents(1);
    /* drain startup events */
    SDL_Event e;
    while (SDL_PollEvent(&e)) {
    }
    SDL_Thread *t = SDL_CreateThread(worker, "pusher", NULL);

    int stalls = 0, timeouts = 0, other_timeouts = 0;
    Uint64 worst = 0;
    for (int r = 1; r <= rounds; r++) {
        SDL_SetAtomicInt(&round_started, r);
        for (;;) {
            const Uint64 t0 = SDL_GetTicksNS();
            const bool got = SDL_WaitEventTimeout(&e, 1000);
            const Uint64 dt = SDL_GetTicksNS() - t0;
            if (!got) {
                /* Timed out. Confirm the round's event was sitting in SDL's queue during the
                   wait (it was pushed within max_delay_us): that is a lost wakeup. */
                SDL_Event peek;
                if (SDL_PeepEvents(&peek, 1, SDL_PEEKEVENT, user_type, user_type) > 0 &&
                    peek.user.code == r) {
                    timeouts++;
                } else {
                    other_timeouts++;
                }
                continue;
            }
            if (e.type == user_type && e.user.code == r) {
                if (dt >= SDL_MS_TO_NS(900)) {
                    stalls++;
                }
                if (dt > worst) {
                    worst = dt;
                }
                break;
            }
        }
    }
    SDL_SetAtomicInt(&quit, 1);
    SDL_WaitThread(t, NULL);
    printf("repro_wakeup: %d rounds, max delay %d us: %d waits timed out with the event queued, "
           "%d other timeouts, %d stalls >= 900 ms, worst delivery %.3f ms\n",
           rounds, max_delay_us, timeouts, other_timeouts, stalls, (double)worst / 1e6);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return (timeouts || stalls) ? 1 : 0;
}
