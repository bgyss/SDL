# Findings

Results from `verification/`, newest first. Each entry says how sure we are, and whether a
human has reproduced it on a real SDL build. Upstream SDL does not accept AI-generated reports
(see `CLAUDE.md`). Nothing here goes upstream unless a human reproduces it and writes it up in
their own words.

Status values:
- **proved (bounded)**: TLC found no violation within the bounds in `TRUSTED_BASE.md`.
- **model counterexample**: TLC found a violating trace in the model. It has not been reproduced
  on real hardware.
- **lead**: seen on extracted code or by reading, and not yet reproduced on a real build.
- **reproduced (tooling)**: the reproduction tooling triggered it on a real SDL build
  (`mise run repro`). A human still has to check it and decide what to do with it.
- **confirmed**: a human reproduced it on a real build.

---

## F-006 · Gamepad mapping: 128-character joystick binding overflows a stack buffer (was L-3)

**Status:** reproduced (tooling), ASan on a real Debug build (`mise run repro -- gamepad-joy`).
Severity: moderate. It is an out-of-bounds stack read reachable from mapping strings, which can
come from `SDL_AddGamepadMapping`, the `SDL_GAMECONTROLLERCONFIG` hint/env var, or a
`gamecontrollerdb.txt` file.

**Code:** `SDL_PrivateParseGamepadConfigString` (`src/joystick/SDL_gamepad.c:1765-1811`). The
length guard `if (i >= sizeof(szJoystickButton))` runs *before* the write, so a value of exactly
128 characters fills `szJoystickButton[128]` with no terminator and passes the check. The next
`,` hands the buffer to `SDL_PrivateParseGamepadElement`. If the game-button half is valid (for
example `a`), that function calls `SDL_strlen(szJoystickButton)` at `:1706`.

**ASan:** `stack-buffer-overflow … READ of size 132`, in `strlen` ←
`SDL_PrivateParseGamepadElement SDL_gamepad.c:1706` ← `SDL_PrivateParseGamepadConfigString
:1785` ← `SDL_PrivateLoadButtonMapping :1985`. The memory access "at offset 224 overflows
'szJoystickButton' [96, 224)".

**Input:** `<guid>,name,a:b` followed by 127 `0` characters and then `,`. The repro uses a virtual
joystick so no hardware is needed.

**Game-button half (L-3a):** `szGameButton[20]` has the same off-by-one: a 20-character name is
left unterminated (`mise run repro -- gamepad`). Today it is only read by `SDL_strcasecmp`
against SDL's button and axis names, all shorter than 20 characters, so the comparison stops
inside the buffer and ASan stays quiet. It is a latent bug. Any future consumer that calls
`strlen` or copies the name would turn it into the same over-read.

## F-005 · `SDL_StepUTF8` returns code points above U+10FFFF (was L-2)

**Status:** reproduced (tooling) on a real build (`mise run repro -- utf8-range`), and proved
exactly in Lean. Severity: low (wrong output, no memory error).

The 4-byte branch of `StepUTF8` (`src/stdlib/SDL_string.c:238-251`, check at `:247`) checks
`result >= 0x10000` but has no upper bound. `F4 90 80 80` returns `0x110000`, `F5 80 80 80`
returns `0x140000` and `F7 BF BF BF` returns `0x1FFFFF`. RFC 3629 rejects all of them, and the
header says invalid sequences return `SDL_INVALID_UNICODE_CODEPOINT`.

**Lean** (`verification/lean/SDLVerif/Utf8.lean`):
- `out_of_range_iff`: the C returns a value above U+10FFFF *if and only if* the input is a
  4-byte sequence with lead F4–F7 that RFC 3629 rejects. There are no other wrong answers.
  `sound_in_range` and `complete` prove the C agrees with RFC 3629 on everything else.
- `fix_changes_only_out_of_range` covers the patch audit. Adding `&& result <= 0x10FFFF`
  changes the output only for exactly those inputs, which then return U+FFFD and advance one
  byte. `fixed_sound` and `fixed_complete` prove the patched model equals RFC 3629.
- The Lean model of the C agrees with the real `SDL_StepUTF8` on 3,096,576 differential cases
  (`mise run lean:diff`).

## F-004 · `SDL_StepUTF8(&p, NULL)` reads past the string's terminator (was L-1)

**Status:** reproduced (tooling), ASan on a real build (`mise run repro -- utf8-null`), and
proved in Lean. Severity: low to moderate. It is a heap/stack over-read of up to 2 bytes, for
any caller that passes `NULL` for `pslen` on untrusted text ending in a truncated multi-byte
sequence.

`SDL_StepUTF8` with `pslen == NULL` calls `StepUTF8(pstr, 4)` (`SDL_string.c:262`), which
tells it 4 bytes are available. The 3- and 4-byte branches load `str[1]`, `str[2]` and
`str[3]` *before* checking whether any of them is a continuation byte (`:225-226`, `:239-241`).
For the 2-byte heap string `"\xF0"` this reads `str[2]` and `str[3]` past the NUL. The header
promises the function "will blindly read until it sees the NULL char".

**ASan:** `heap-buffer-overflow … READ of size 1 … 0 bytes after 2-byte region`, in `StepUTF8
SDL_string.c:240` ← `SDL_StepUTF8_REAL :262`.

**Lean:** `null_len_reads_past_nul` is the concrete case. `reads_le_slen` proves that *with* a
real length the C never reads past it, so the bug is specific to the `NULL` path.
`fixed_stops_at_nul` proves that checking each continuation byte before reading the next one
never reads past a NUL. The same model fix (`cFixed`) covers F-005, and the patch audit theorem
shows that reordering the reads changes no outputs.

## F-003 · `cond_generic`: stale token after a timed-out wait (spurious "signalled" return)

**Status:** model counterexample (`tla/cond_generic/findings/stale_token.cfg`). Severity: low.

**Code:** `src/thread/generic/SDL_syscond.c`, `SDL_WaitConditionTimeoutNS_generic` and
`SDL_SignalCondition_generic`.

**Trace (14 states):**
1. Waiter A registers (`num_waiting = 1`), releases the user mutex, and its
   `SDL_WaitSemaphoreTimeoutNS(cond->sem)` times out.
2. Before A gets `signal_sem` back, a producer calls `SDL_SignalCondition`. It sees
   `num_waiting (1) > num_signals (0)`, sets `num_signals = 1`, posts `cond->sem`, and waits for the
   handshake.
3. A takes `signal_sem`, sees `num_signals > 0`, posts the handshake, and decrements both
   counters. A returns `false` (timed out).

Afterwards `cond->sem` holds one token with `num_signals == 0`. The next thread that waits on this
condition variable takes that token at once and returns `true` ("signalled"), even though nobody
signalled it. Stale tokens can build up, one per occurrence of this race.

**Impact:** clients that use the documented loop (`while (!pred) SDL_WaitCondition(...)`) are not
affected. `MC_timeouts.cfg` and `MC_flag.cfg` show that every consumer terminates and no wakeup is
lost. The behaviour contradicts the header docs ("returns true if the condition variable is
signaled"). Code that treats a `true` return as proof of a signal, without re-checking a
predicate, would misbehave. This only affects platforms that use the generic condition variable
(see F-002).

**Next step:** search SDL for `SDL_WaitCondition*` callers that branch on the return value without
re-checking a predicate. Decide whether this is worth a human-written doc note ("spurious wakeups
are possible") rather than a code change. The fix-free reading is that SDL condition variables,
like pthreads ones, may wake spuriously.

## F-002 · Correction: where the generic condition variable runs

**Status:** checked by reading the code.

RESEARCH.md §5 T3 said the semaphore-based condition variable is live on macOS/iOS. That is wrong.
macOS/iOS compile the generic *semaphore* (`src/thread/pthread/SDL_syssem.c:31-33`), which is
built on pthread condition variables. The generic *condition variable*
(`src/thread/generic/SDL_syscond.c`) is compiled for Windows, Vita, PSP, PS2, 3DS and DOS
(`CMakeLists.txt` branches at 2427, 3220, 3394, 3474, 3536 and 3615). On Windows it is only selected
when `WakeConditionVariable` and the other native condition-variable entry points are missing
(`src/thread/windows/SDL_syscond_cv.c:173-186`).

## F-001 · `SDL_InitState` is correct under its documented contract

**Status:** proved (bounded): 3 threads × 2 calls, 22,479 distinct states, with termination under
weak fairness. Spec: `tla/initstate/InitState.tla`.

Properties:
- at most one thread is in an init or quit body at a time
- init and quit never overlap
- the `SDL_assert(state->thread == SDL_GetCurrentThreadID())` in `SDL_SetInitialized` always holds
- a transitional status always has an owner that will finish it
- every call returns

Each property has a mutant that breaks it. TLC coverage shows every real-code action fires.

The model assumes, and therefore does not check:
- **Re-entrancy.** An owner that calls `SDL_ShouldInit` or `SDL_ShouldQuit` on the same state from
  inside its own init or quit spins forever. The header contract rules this out. Every in-tree
  user checked follows it: `SDL_properties.c:109`, `SDL_pixels.c:791`, `SDL_utils.c:188` and
  `SDL_log.c:150`.
- **Starvation.** With unbounded clients, a spinning caller can starve while others repeatedly
  init and quit. This is expected of a spin-wait. It is not modelled because the client bound
  makes every run finite.
- **Use-after-quit.** The header says `SDL_InitState` "doesn't protect any resources created
  during initialization". A thread that got `false` ("initialized") from `SDL_ShouldInit` can
  still race with a concurrent quit.

---

## Leads carried over from RESEARCH.md (not yet reproduced on a real build)

L-1, L-2 and L-3 have become F-004, F-005 and F-006 above.

| ID | Lead | Source |
|---|---|---|
| L-4 | Lost wakeup in `SDL_WaitEventTimeout_Device` (queue check `:1646` before `wakeup_window` set `:1671`) | hypothesis, Phase 4 |
| L-5 | Find-then-ref window in `ObtainPhysicalAudioDevice` (`SDL_audio.c:493`) | hypothesis, Phase 4 |
