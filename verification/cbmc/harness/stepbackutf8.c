/*
 * SDL_StepBackUTF8(start, &p) (src/stdlib/SDL_string.c).
 *
 * The buffer [start, start + len) has arbitrary contents and p is any position in it, so this
 * proves the function never reads before start or at/after the original p. Functionally:
 *   - p == start: returns 0 and leaves p alone
 *   - otherwise p moves back by at least one byte, and either
 *       * the bytes stepped over are exactly one character: decoding forward from the new p
 *         gives the same value and lands on the old p, or
 *       * the result is U+FFFD and p moved back exactly one byte, or
 *       * the byte before p is NUL: returns 0, moved back one byte
 *   - on valid UTF-8 (no NUL) the first case always holds: stepping back is the inverse of
 *     stepping forward.
 * F-008 (stray trailing bytes were silently skipped) fails this on the base tree.
 *
 * CBMC-SOURCES: src/stdlib/SDL_string.c
 * CBMC-BOUND: buffer of 0..6 bytes, every byte value, every start position
 * CBMC-UNWIND: 8
 */
#include "cbmc_common.h"

#define MAX 6

void harness(void)
{
    size_t len = nondet_size_t();
    ASSUME(len <= MAX);
    const char *buf = nondet_buffer(len);
    size_t pos = nondet_size_t();
    ASSUME(pos <= len);
    const char *const old = buf + pos;
    const char *p = old;

    const Uint32 r = SDL_StepBackUTF8(buf, &p);

    if (pos == 0) {
        CHECK(r == 0 && p == old, "StepBackUTF8: does nothing at start");
        return;
    }
    CHECK(p >= buf && p < old, "StepBackUTF8: moves back at least one byte, not before start");

    const size_t back = (size_t)(old - p);
    const char *fwd = p;
    size_t left = back;
    const Uint32 again = SDL_StepUTF8(&fwd, &left);
    const bool one_char = (again == r && fwd == old && r != 0);
    const bool replaced = (r == SDL_INVALID_UNICODE_CODEPOINT && back == 1);
    const bool nul = (r == 0 && back == 1 && *p == '\0');
    CHECK(one_char || replaced || nul,
          "StepBackUTF8: steps over exactly one character, or returns U+FFFD for one byte");

    if (ref_utf8_valid_nonul((const unsigned char *)buf, pos)) {
        CHECK(one_char, "StepBackUTF8: on valid UTF-8 it inverts StepUTF8");
    }
}
