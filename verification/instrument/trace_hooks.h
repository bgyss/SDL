/* Definitions of the verif_trace.h hooks, for the trace programs. Include in exactly one file.
 * Lines are NDJSON: {"n":<seq>,"tid":<thread>,"role":"<role>","a":"<action>","id":<obj>,"v":<value>}
 * and go to the file named by $VERIF_TRACE_OUT (default: stdout). Logging is off until
 * trace_start(). */
#ifndef TRACE_HOOKS_H
#define TRACE_HOOKS_H

#include <SDL3/SDL.h>
#include <pthread.h>
#include <stdio.h>
#include "verif_trace.h"

static pthread_mutex_t trace_mutex = PTHREAD_MUTEX_INITIALIZER;
static FILE *trace_file;
static Sint64 trace_seq;
static volatile int trace_on;
static _Thread_local const char *trace_role;

void SDL_VerifTraceLock(void) { pthread_mutex_lock(&trace_mutex); }
void SDL_VerifTraceUnlock(void) { pthread_mutex_unlock(&trace_mutex); }
void SDL_VerifTraceRole(const char *role) { trace_role = role; }

void SDL_VerifTrace(const char *action, Uint32 obj, Sint64 value)
{
    if (!trace_on) {
        return;
    }
    fprintf(trace_file, "{\"n\":%lld,\"tid\":%llu,\"role\":\"%s\",\"a\":\"%s\",\"id\":%u,\"v\":%lld}\n",
            (long long)trace_seq++, (unsigned long long)SDL_GetCurrentThreadID(),
            trace_role ? trace_role : "", action, (unsigned)obj, (long long)value);
}

static void trace_start(void)
{
    const char *path = SDL_getenv("VERIF_TRACE_OUT");
    pthread_mutex_lock(&trace_mutex);
    trace_file = path ? fopen(path, "w") : stdout;
    if (!trace_file) {
        trace_file = stdout;
    }
    trace_on = 1;
    pthread_mutex_unlock(&trace_mutex);
}

static void trace_stop(void)
{
    pthread_mutex_lock(&trace_mutex);
    trace_on = 0;
    if (trace_file && trace_file != stdout) {
        fclose(trace_file);
    }
    trace_file = NULL;
    pthread_mutex_unlock(&trace_mutex);
}

#endif
