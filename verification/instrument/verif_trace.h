/* Trace hooks for TLA+ trace validation (verification/PLAN.md, Phase 4).
 *
 * These are never compiled into the real SDL. verification/instrument/build.sh exports a copy
 * of the tree, applies <spec>.patch (which includes this header and calls the hooks), and
 * builds that copy. The trace program that links the instrumented SDL defines the hooks.
 *
 * Each traced step is performed and logged inside one SDL_VerifTraceLock() section, so the
 * order of the lines in the log is the order in which the steps took effect. The trace lock is
 * always the innermost lock. Holding it serializes the traced steps, which only narrows the
 * set of interleavings a run can show; every logged run is still a run of the real code.
 */
#ifndef SDL_VERIF_TRACE_H
#define SDL_VERIF_TRACE_H

#include <SDL3/SDL_stdinc.h>

extern void SDL_VerifTraceLock(void);
extern void SDL_VerifTraceUnlock(void);
/* Log one step. Call with the trace lock held. obj names the object the step acts on (an
   audio device instance ID, an event, ...); value is step-specific (a refcount, a count). */
extern void SDL_VerifTrace(const char *action, Uint32 obj, Sint64 value);
/* Mark the calling thread as running a named role (NULL to clear), e.g. the main-thread
   disconnect handler. The role is written with each of the thread's log lines. */
extern void SDL_VerifTraceRole(const char *role);

#endif
