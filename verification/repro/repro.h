/* Shared verdict helpers for the reproduction programs in verification/repro/.
 *
 * Each program reproduces one finding from verification/FINDINGS.md through SDL's public API
 * (F-020 also needs two internal entry points; see its file). It does not use
 * verification/harness/. run.sh builds every program against two SDL trees, the pre-fix
 * commit and the current one, and checks the outcome against the expectations in
 * verification/repro/EXPECT.
 *
 * A program reports one of:
 *   - a sanitizer report (ASan/UBSan abort the process; run.sh matches the report text)
 *   - "BUG: ..." and exit status 1, for wrong results that are not memory errors
 *   - "OK: ..." and exit status 0, when SDL behaved as its header documents
 */
#ifndef REPRO_H
#define REPRO_H

#include <stdio.h>

#define REPRO_BUG(...)            \
    do {                          \
        printf("BUG: ");          \
        printf(__VA_ARGS__);      \
        printf("\n");             \
        fflush(stdout);           \
        return 1;                 \
    } while (0)

#define REPRO_OK(...)             \
    do {                          \
        printf("OK: ");           \
        printf(__VA_ARGS__);      \
        printf("\n");             \
        fflush(stdout);           \
        return 0;                 \
    } while (0)

/* Print progress before a call that may trigger a sanitizer report, so the log shows how far
   the program got. */
#define REPRO_STEP(...)           \
    do {                          \
        printf("step: ");         \
        printf(__VA_ARGS__);      \
        printf("\n");             \
        fflush(stdout);           \
    } while (0)

#endif
