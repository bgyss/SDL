/* F-019: lost wakeup in SDL_WaitEventTimeout. The waiter checks SDL's queue and only then
 * publishes wakeup_window. An event pushed from another thread in between finds no window to
 * wake, so the wait runs to its timeout although the event is already queued.
 *
 * The main thread waits with a 1 s timeout on a hidden window. A second thread pushes one user
 * event per round, at a random delay of 0-20 us after the main thread starts waiting. A wait
 * that times out while that round's event is in the queue (checked with SDL_PEEKEVENT) is a
 * lost wakeup. The race window is a few instructions wide, so this is a stress test:
 * REPRO_ROUNDS (default 300000) rounds. A clean run is evidence, not proof; the TLA+ model
 * (verification/tla/events_wait) covers every interleaving. */
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <stdlib.h>
#include "repro.h"

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
    (void)argc;
    (void)argv;
    const char *env = SDL_getenv("REPRO_ROUNDS");
    const int rounds = env ? SDL_atoi(env) : 300000;
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        printf("SDL_Init: %s\n", SDL_GetError());
        return 2;
    }
    SDL_Window *win = SDL_CreateWindow("repro", 64, 64, SDL_WINDOW_HIDDEN);
    if (!win) {
        printf("SDL_CreateWindow: %s\n", SDL_GetError());
        return 2;
    }
    user_type = SDL_RegisterEvents(1);
    SDL_Event e;
    while (SDL_PollEvent(&e)) {
    }
    SDL_Thread *t = SDL_CreateThread(pusher, "pusher", NULL);
    int lost = 0;
    for (int r = 1; r <= rounds; r++) {
        SDL_SetAtomicInt(&round_no, r);
        for (;;) {
            if (!SDL_WaitEventTimeout(&e, 1000)) {
                SDL_Event peek;
                if (SDL_PeepEvents(&peek, 1, SDL_PEEKEVENT, user_type, user_type) > 0 && peek.user.code == r) {
                    lost++;
                    printf("round %d: timed out with the event already queued\n", r);
                    fflush(stdout);
                }
                continue;
            }
            if (e.type == user_type && e.user.code == r) {
                break;
            }
        }
    }
    SDL_SetAtomicInt(&done, 1);
    SDL_WaitThread(t, NULL);
    SDL_DestroyWindow(win);
    SDL_Quit();
    if (lost) {
        REPRO_BUG("%d of %d waits timed out with their event already queued (lost wakeup)", lost, rounds);
    }
    REPRO_OK("no lost wakeup in %d rounds", rounds);
}
