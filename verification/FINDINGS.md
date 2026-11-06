# Findings

Results from `verification/`, newest first. Each entry says how sure we are, how the bug was
reproduced, and whether it is fixed. Nothing here goes upstream (see `CLAUDE.md`).

Status values:
- **proved (bounded)**: TLC found no violation within the bounds in `TRUSTED_BASE.md`.
- **model counterexample**: TLC found a violating trace in the model.
- **lead**: seen on extracted code or by reading, and not yet reproduced on a real build.
- **reproduced**: a standalone program in `repro/` triggers it on a real ASan/UBSan build of the
  pre-fix tree (`mise run repro:verify`; the outcome it must show is its line in
  `repro/EXPECT`). There is no manual reproduction step in this fork.
- **fixed**: a `src/` commit removes it. The same program is clean on the current tree, and its
  fuzz regression input (if any) passes with `SDL_FUZZ_KNOWN=1`.

The 2026-11-05 run of `mise run repro:verify` (Apple M-series, macOS 27.3, Apple clang 21.0.0;
base `cb6224d2e`, fixed = this branch) matched `EXPECT` for all 21 programs on both trees. F-023 and F-024 (2026-11-06) added two
more; the current suite has 23.

---

## Summary of F-004 – F-024 (2026-11-05, F-023/F-024 on 2026-11-06)

Every finding below is **reproduced** on `cb6224d2e` and **fixed**: F-004 – F-020 in
`cce7d368b`, and F-021 – F-024 each in their own commit.

| ID | Where | What | Reproduction on `cb6224d2e` (`repro/`) | Severity |
|---|---|---|---|---|
| F-024 | `SDL_CreateSurface` | pitch above INT_MAX stored as a negative `int` | `f024_surface_pitch_overflow`: pitch -2147483648 | moderate |
| F-023 | `SDL_LoadBMP_IO` (and every `int` `h * pitch`) | surfaces ≥ 2 GiB overflow `h * pitch`; the load "succeeds" with uninitialized pixels | `f023_bmp_size_overflow`: UBSan signed overflow | moderate |
| F-022 | `SDL_PrivateParseGamepadElement` / `SDL_PrivateLoadButtonMapping`, joystick getters | mapping index too large for an int becomes -1; `axes[-1]` read and written | `f022_gamepad_axis_overflow`: ASan heap-buffer-overflow | low–moderate |
| F-021 | `SDL_FindPhysicalAudioDeviceByCallback`/`ByHandle` callers | backend find-then-disconnect races with the last unref: use after free | `f021_audio_find_by_handle`: ASan heap-use-after-free | moderate (UAF on hotplug) |
| F-020 | `ObtainPhysicalAudioDevice` | lookup by ID races with the last unref: use after free | `f020_audio_lookup_uaf`: ASan heap-use-after-free; model counterexample | moderate (UAF) |
| F-019 | `SDL_WaitEventTimeout_Device` | lost wakeup: an event pushed between the queue check and publishing `wakeup_window` is not signalled | `f019_lost_wakeup`: 6 of 300,000 waits time out with the event queued; model counterexample | moderate (`SDL_WaitEvent` can block indefinitely) |
| F-013 | `CreateMappingString` | empty mapping body: heap read at `mapping[-1]` | `f013_mapping_empty`: ASan heap-buffer-overflow | low–moderate |
| F-009 | `SDL_PrivateParseGamepadElement` | empty joystick half: stack read at `szJoystickButton[-1]` | `f009_gamepad_empty`: ASan stack-buffer-overflow | low–moderate |
| F-006 | `SDL_PrivateParseGamepadConfigString` | 128-character joystick binding left unterminated, then `strlen` | `f006_gamepad_joy128`: ASan stack-buffer-overflow | moderate |
| F-004 | `StepUTF8` (`SDL_StepUTF8(.., NULL)`, `SDL_strcasecmp`) | reads past the NUL | `f004_steputf8_null`, `f004_strcasecmp`: ASan heap-buffer-overflow | low–moderate |
| F-005 | `StepUTF8` | returns code points above U+10FFFF | `f005_utf8_range`: 3 of 3 accepted | low |
| F-007 | `SDL_utf8strlcpy` | keeps a truncated sequence when the cut falls in the first character | `f007_utf8strlcpy`; proved exact (Lean) | low |
| F-008 | `SDL_StepBackUTF8` | skips stray continuation bytes instead of returning U+FFFD | `f008_stepback`; proved exact (Lean) | low |
| F-010 | `SDL_LoadWAV_IO` | channel count truncated to `Uint8` | `f010_wav_channels`: 256 channels load as 0 | low |
| F-016 | `SDL_LoadWAV_IO` | block align smaller than a frame accepted; `audio_len` not whole frames | `f016_wav_blockalign` | low |
| F-011 | `SDL_iconv` | BOM lost when the first character hits E2BIG | `f011_iconv_bom` | low |
| F-012, F-014, F-015 | rect functions | signed overflow (UB) in enclosing points, line clipping, and with negative sizes or wide unions | `f012_rect_enclose`, `f014_rect_line`, `f015_rect_negative`, `f015_rect_union`: UBSan | low |
| F-017, F-018 | `SDL_LoadBMP_IO` | RLE row pointer leaves the buffer (UB); `-INT_MIN` height (UB) | `f017_bmp_rle`, `f018_bmp_int_min`: UBSan | low |

F-004 also gained reach: `SDL_strcasecmp` and `SDL_utf8strlen` hit the same over-read (see F-004).

## F-024 · Surfaces: a pitch above INT_MAX was stored as a negative `int`

**Status:** reproduced and fixed. Found while stating the BMP header theorems (Phase 5).
Severity: moderate. It needs a surface at least 2^31 bytes wide, but it is reachable from the
public API and from every image loader.

**Code:** `SDL_CreateSurface` computes the pitch in `size_t` (`SDL_CalculateRGBSize`) and stores
it as `(int)pitch` with no range check (`SDL_surface.c:226` at `cb6224d2e`). A 536,870,912 × 1
ARGB8888 surface gets `pitch == INT_MIN` over a 2 GiB buffer, and every blit, fill and loader
trusts that pitch.

**Reproduction:** `repro/f024_surface_pitch_overflow`: on `cb6224d2e`, `BUG: surface created with
pitch -2147483648 for a row of 2147483648 bytes`.

**Fix:** `SDL_CalculateSurfaceSize` rejects a pitch above `INT_MAX` ("Surface too large"). Test:
`testautomation` `surface_testIntSize`. Model: `pitch_prefix_overflow` in `lean/SDLVerif/Header.lean`.

## F-023 · BMP: `surface->h * surface->pitch` in `int` overflows for surfaces of 2 GiB or more

**Status:** reproduced and fixed. Found by trying to prove that the BMP loader's buffer
arithmetic cannot overflow (Phase 5). Severity: moderate. The input is a 54-byte header plus one
row (4 MiB). The load then "succeeds" with 2 GiB of uninitialized memory as its pixels.

**Code:** nothing limited `h * pitch` to an `int`. `SDL_CreateSurface` checked only `size_t`
overflow, and SDL computes `h * pitch` in `int` in many places (85 such expressions in
`src/video`, including RLE acceleration, cursors and icons). `SDL_LoadBMP_IO` sets
`end = pixels + surface->h * surface->pitch` (`SDL_bmp.c:525` at `cb6224d2e`). For a 1,048,576 × 512
32-bpp image that is `512 * 4194304 = 2^31`: signed overflow. In an unsanitized build it wraps
to `INT_MIN`, `end` falls before `pixels`, the row loop never runs, and the function returns
success with a 2 GiB surface whose pixels were never read from the file.

**Reproduction:** `repro/f023_bmp_size_overflow`: on `cb6224d2e`, UBSan reports `signed integer
overflow: 512 * 4194304 cannot be represented in type 'int'` in `SDL_bmp.c`. In a plain build
the same program prints `OK: loaded`, from a file with one row of pixels.

**Fix:**
- `SDL_CalculateSurfaceSize` rejects a total size above `INT_MAX`.
- `SDL_CreateSurfaceFrom` rejects a caller pitch with `height * pitch > INT_MAX`.
- The BMP loader computes its end-of-pixels pointers in `size_t`.

This is a public behavior change: surfaces of 2 GiB or more can no longer be created. They
were unsafe before (see the 85 sites above). It is documented on `SDL_CreateSurface` and
`SDL_CreateSurfaceFrom`. Test: `testautomation` `surface_testIntSize`.

**Model:** `lean/SDLVerif/Header.lean`.
- `bmp_rows_in_buffer`: on a surface that passes the new check, the `int` product is exact and
  every row the loader reads is inside the buffer.
- `bmp_prefix_overflow`: the old code admitted this case.
- `height_times_pitch_can_exceed_size_t`: SDL's existing `size_t` check on `height * pitch` is
  needed too, not redundant.

## Observation O-2 · The BMP row loop forms a pointer before the buffer

A bottom-up BMP (the usual kind) is read from the last row up with `bits -= pitch`. After row 0
the loop computes `top - pitch` and only then sees `bits < top`. Forming a pointer outside the
array is undefined in C even if it is never dereferenced. It is the same class as F-017, but no
sanitizer can observe it (UBSan's pointer-overflow check only fires when the address wraps).
Following this fork's rule that a fix needs a reproduction, it is recorded here and not
changed. A row-index loop, as F-017's fix did for RLE, would remove it.

## R-1 · The integer rect functions are free of undefined behavior and compute what they claim (Lean)

**Status:** proved (all inputs, no bounds) in `lean/SDLVerif/Rect.lean` and
`lean/SDLVerif/RectLine.lean`, for the code since `cce7d368b`. The model is tied to the real C
by `test/rect_diff.sh`: 200,000 cases, the outputs match exactly. 9 proof mutants are all caught.

- **No signed overflow anywhere** (`has_no_ub`, `inter_no_ub`, `union_no_ub`, `enclose_noclip`,
  `enclose_clip`, and for line clipping `step_ok`/`loop_ok`/`rect_box_ok`). This covers every
  `int` `+`/`-`, and for line clipping every `Sint64` product (each below 2^62 in magnitude).
- **Line clipping never divides by zero, and always terminates.** The `SDL_assert(y2 != y1)`
  and `SDL_assert(x2 != x1)` in the Cohen–Sutherland loop can never fire. A zero divisor would
  need both outcodes to share a bit, which the loop exits on first. Every clipped point lands
  inside the segment's bounding box, so all coordinates stay within the endpoint guard. The loop
  ends within `|x2-x1| + |y2-y1| + 1` iterations, and when it returns true both endpoints are
  inside the rect.
- **What the functions compute** on guarded inputs:
  - The intersection is exact: `inter_sound` (its points are in both rects) and `inter_complete`
    (every common point is in it). It is commutative (`inter_comm`) and agrees with
    `SDL_HasRectIntersection` (`has_iff_inter`).
  - The union contains both non-empty rects and is the tightest such rect (`union_contains`,
    `union_tight`). It fails exactly when the result would be wider or taller than `INT_MAX`
    (`union_fails_iff_too_wide`).
  - The enclosing rect contains every point (inside the clip, if given) and lies inside the
    clip.
- **The record of F-012/F-014/F-015** (pre-fix model, `fixed := false`):
  - `has_prefix_ub_only_unguarded`: the old `SDL_HasRectIntersection` overflowed only on inputs
    the new guard rejects.
  - `inter_prefix_ub_under_fixed_guard`: the old `SDL_GetRectIntersection` could overflow even on
    rects that pass the *new* guard, which is why the fix also computes the size in 64 bits.
  - `inter_fix_audit`, `union_fix_audit`: wherever the old code was defined and the new guard
    accepts, the fixed functions return exactly what the old ones did.

## F-022 · Gamepad: a joystick index too large for an int indexes `axes[-1]`

**Status:** reproduced and fixed. Found by `fuzz_gamepad` on the *fixed* tree in the fresh
2026-11-05 fuzz pass, with every known-finding skip off. It was there at `cb6224d2e` too.
Severity: low to moderate, a 16-byte heap read and write just before `joystick->axes`, from a
mapping string.

**Code:** `SDL_PrivateParseGamepadElement` converted the number in `a<N>`, `b<N>` and the hat
mask with `SDL_atoi`. That is undefined when the number doesn't fit in an int, and on macOS it
gives -1 for `a99999999999999999999`. `SDL_PrivateLoadButtonMapping` then zeroes trigger axes
with `if (axis < joystick->naxes) joystick->axes[axis].value = ...zero = ...` (`SDL_gamepad.c:2000` at
`cb6224d2e`), which -1 passes. The public getters had the same one-sided check:
`SDL_GetJoystickAxis`, `SDL_GetJoystickAxisInitialState`, `SDL_GetJoystickHat`,
`SDL_GetJoystickBall` and `SDL_GetJoystickButton` all read index -1 if asked.

**Reproduction:** `repro/f022_gamepad_axis_overflow` maps `lefttrigger:a99999999999999999999` on a
two-axis virtual pad. On `cb6224d2e`, ASan reports `heap-buffer-overflow` in
`SDL_PrivateLoadButtonMapping`. With no axes, UBSan reports the offset applied to NULL
instead. Fuzz input: `harness/regressions/fuzz_gamepad/F-022_axis_overflow`.

**Fix:** `SDL_PrivateParseJoystickIndex` parses the digits itself and rejects anything above
`INT_MAX`, which makes the binding invalid. The trigger loop and the five getters reject
negative indices. Test: `testautomation` `joystick_testIndexRange` (negative indices on every
getter, and 20-digit and 2^32 numbers in a mapping).

## Observation O-1 (again): BMP header sizes drive allocation and time

The fresh fuzz pass stopped `fuzz_bmp` on a 10-second timeout after 13,691 inputs. The input
(174 bytes) declares an RLE4 image 822,083,588 pixels wide and 2 high. SDL allocates the
~822 MB surface, and the target then touches every byte (9.7 s replayed). This is not a hang
or a memory error. It is O-1 again, and not a fix target for now. An app that loads
untrusted BMPs should cap dimensions itself.

## F-021 · Audio: backends look a device up without a reference, then disconnect it

**Status:** reproduced and fixed. Found while reviewing the F-020 fix: the same window exists
in a second lookup function. Severity: moderate, a use after free on hotplug.

**Code** (`src/audio/SDL_audio.c`, pre-fix): `SDL_FindPhysicalAudioDeviceByCallback` and
`SDL_FindPhysicalAudioDeviceByHandle` search the device hash under the read lock and return the
device *without a reference*. Backends pass the result straight on:
- `SDL_AudioDeviceDisconnected(SDL_FindPhysicalAudioDeviceByHandle(h))`: ALSA, PipeWire,
  Android, and IMMDevice (Windows) through its callback.
- the callback form: PulseAudio.
- `SDL_DefaultAudioDeviceChanged(...)`: PulseAudio, PipeWire, CoreAudio, IMMDevice.

Both of those functions take their own reference only after the find has dropped the lock. If
a concurrent disconnect drops the device's last reference in between, the reference lands on
freed memory.

**Reproduction:** `repro/f021_audio_find_by_handle` plays a backend. Four hotplug threads
report "device h is gone" in a loop while the main thread processes the queued disconnects.
On `cb6224d2e`, ASan reports `heap-use-after-free … WRITE of size 4` in
`RefPhysicalAudioDevice` ← `SDL_AudioDeviceDisconnected` ← the backend's call. The device
was freed by `SDL_AudioDeviceDisconnected_OnMainThread`. With the fixed code (and the backend
convention below), 50,000 rounds and 26 million reports are clean.

**Fix:** new internal functions `SDL_FindAndRefPhysicalAudioDeviceByCallback` and
`SDL_FindAndRefPhysicalAudioDeviceByHandle` take the reference under the same read lock, using
F-020's increment-if-nonzero (`TryRefPhysicalAudioDevice`). A device whose count is already 0
is not found. `UnrefPhysicalAudioDevice` now accepts NULL. Every backend call site that
uses the device after the lookup now finds with a reference and unrefs afterwards: ALSA
(`ALSA_DisconnectDevice`), PipeWire (2), PulseAudio (2), CoreAudio (default-device
notification), Android, and IMMDevice (3). The unreferenced finds remain for NULL checks,
for `DetectDevices` (where nothing can disconnect yet), and for callbacks that do their work
under the lock (AAudio, OHAudio and CoreAudio pause/resume/count). Only CoreAudio, the dummy
driver and the core were compiled and tested here (macOS). The ALSA, PipeWire, PulseAudio,
Android and Windows changes are mechanical, but they have not been compiled.

**Model:** `tla/audio_device` covers it. Its `l_find`/`l_ref` steps are the find and the
reference, whichever function takes it, and `MC_fix.cfg` is the fixed protocol.

---

## F-020 · Audio: a lookup by device ID can touch a device freed by a concurrent disconnect (was L-5)

**Status:** model counterexample (`tla/audio_device/findings/find_then_ref.cfg`, 12 states),
**reproduced** on a real build, and **fixed** in `cce7d368b`. Severity: moderate, a use after
free. It needs a physical device that nobody has open to be disconnected while another
thread looks it up by instance ID.

**Reproduction (2026-11-05):** `repro/f020_audio_lookup_uaf` adds a device, starts four
threads calling `SDL_GetAudioDeviceFormat(id)` in a loop, and disconnects the device through
the backend entry point `SDL_AudioDeviceDisconnected`. On `cb6224d2e`, ASan reports
`heap-use-after-free … READ of size 4` in `UnrefPhysicalAudioDevice` ← `ReleaseAudioDevice` ←
`SDL_GetAudioDeviceFormat` on one lookup thread. The device was **freed by another lookup
thread** in the same function. That is the model's resurrection trace exactly: a lookup found
the device after the count reached 0, took it back to 1, and freed it on release, while the
disconnect path freed it as well. On the fixed tree, 200,000 rounds (15.6 million lookups) are
clean.

**Trace validation:** `mise run trace` records real runs of the fixed code with an
instrumented SDL and replays them in `tla/audio_device/Trace.tla` (FIX = `try_ref_in_lock`).
On 2026-11-05, 30 of 30 device lifetimes replayed, and in 60 of the recorded lookups the device
had been found with count 0 and was turned away. The pre-fix model cannot replay them.

**Code** (`src/audio/SDL_audio.c`):
- `ObtainPhysicalAudioDevice` (`:481-504`) finds the device in `device_hash_physical` under
  the read lock and drops the lock (`:497`). Only then does `ObtainPhysicalAudioDeviceObj` take
  a reference (`RefPhysicalAudioDevice`, `:413`).
- The disconnect handler `SDL_AudioDeviceDisconnected_OnMainThread` (`:792-862`) drops the
  device list's reference and the disconnect reference.
- `UnrefPhysicalAudioDevice` (`:628-639`) decrements to 0 *outside* the lock, then takes the
  write lock to remove the hash entry, then frees the device.

**Trace:** main obtains and releases the device, and drops both references (count 0). The
lookup's find then runs *between the decrement and the removal*, so it still finds the device.
Main removes the entry and frees the device. The lookup's `RefPhysicalAudioDevice` writes to
freed memory, and its later unref frees the device again.

**The obvious fix is not enough.** Taking the reference inside the read-locked find
(`findings/ref_in_lock.cfg`) still fails. The decrement happens before the write lock, so the
lookup can resurrect a device whose count is already 0. What passes (`MC_fix.cfg`, 2 lookers)
is "inside the read lock, take a reference only if the count is not already 0", which is a
compare-and-swap increment-if-nonzero.

**What holds:** with the device open (`MC.cfg`), the logical device's reference keeps it alive,
and no use after free occurs. This answers RESEARCH open question 2 for this path: open
handles protect it, closed devices do not.

**Fix (`cce7d368b`):** `ObtainPhysicalAudioDevice` takes the reference inside the read lock with
`TryRefPhysicalAudioDevice` (increment only if non-zero), which is `MC_fix.cfg`'s protocol.
F-021 is the same window in the find-by-callback/handle functions.

## F-019 · Events: lost wakeup in `SDL_WaitEventTimeout_Device` (was L-4)

**Status:** model counterexample (`tla/events_wait/findings/lost_wakeup.cfg`), **reproduced**
on macOS 27/Cocoa, and **fixed** in `cce7d368b` (publish `wakeup_window` before the last queue
check, the order `MC_fix.cfg` verifies). `repro/f019_lost_wakeup` on 2026-11-05: 6 of 300,000
waits on `cb6224d2e` timed out with their event already queued, and 0 of 300,000 on the fixed
tree. Trace validation (`mise run trace`): a 300-round run of the fixed code replays in
`tla/events_wait/Trace.tla`. Making it replay needed one model change. The model lacked the
pump and queue check that `SDL_WaitEventTimeoutNS` does before entering the device loop, so it
now has them (`w_epump`/`w_epeep`). It also now clears `wakeup_window` after a take as a
separate step (`w_untake`), as the fixed code does. All configs and mutants still give their
results.

Earlier stress runs (`mise run repro:wakeup`, the harness version): in 300,000 rounds, 13 waits
ran their full 1-second timeout while the round's event was already in SDL's queue, which the
program confirms with `SDL_PeepEvents(PEEK)` after the timeout. Earlier runs gave 12, 9 and 5 hits
in 200,000 rounds each, with push delays of 0–20, 0–50 and 0–100 µs. Severity: moderate.
`SDL_WaitEvent` (no timeout) can block until some unrelated OS event arrives. With a hidden or
unfocused window that can take a very long time.

**Code** (`src/events/SDL_events.c`): the waiter checks the queue (`SDL_PeepEvents`, `:1646`)
and only then publishes `wakeup_window` (`:1671`) before blocking in the backend. A producer
(`SDL_PushEvent` from another thread, or `SDL_RunOnMainThread`) pushes and then calls
`SDL_SendWakeupEvent` (`:1166-1182`). That function swaps `wakeup_window` with NULL and posts a
native event only if the old value was set. A push between `:1646` and `:1671` swaps NULL, so
no wakeup is posted.

**Backends** (RESEARCH open question 1, now answered): Cocoa (`postEvent`), X11 (`XSendEvent`)
and Win32 (`PostMessage`) all latch the wakeup in the OS queue. None of them re-checks SDL's
queue before blocking. So the bug is the missing wakeup, not a lost one. The model's `no_latch`
mutant shows that the fix depends on this latching.

**What the model proves** (bounds in TRUSTED_BASE.md):
- Real code with timed waits (`MC.cfg`, 3 producers): every event is delivered exactly once.
  The lost wakeup only delays delivery to the timeout.
- Publish-then-check (`MC_fix.cfg`): set `wakeup_window` *before* the last queue check, and
  clear it when an event is found. With 3 producers and an untimed wait, no wakeup is lost and
  every event is delivered.

## F-013 · Gamepad: an empty mapping body makes `CreateMappingString` read `mapping[-1]`

**Status:** reproduced: `mise run repro -- mapping-empty` gives ASan
`heap-buffer-overflow ... READ of size 1` at `SDL_gamepad.c:2737` ←
`SDL_GetGamepadMappingForGUID`. Found by reading the code next to the F-009 report, then
confirmed. Severity: low to moderate, a 1-byte heap read before an allocation.

**Reproduced and fixed:** `repro/f013_mapping_empty` on `cb6224d2e`: ASan heap-buffer-overflow in `CreateMappingString` (`SDL_gamepad.c:2737`). Fixed in `cce7d368b`; the program is clean on the current tree (2026-11-05).

**Code:** `SDL_AddGamepadMapping("<guid>,<name>,")`, for a GUID without a CRC, stores the body
`""`. `CreateMappingString` (`:2737`, again at `:2752`) checks
`mapping->mapping[SDL_strlen(mapping->mapping) - 1] != ','`, which reads index −1. It is
reachable from `SDL_GetGamepadMappingForGUID`, `SDL_GetGamepadMapping` and
`SDL_GetGamepadMappings`. Mapping strings come from apps, from `SDL_GAMECONTROLLERCONFIG` and
from `gamecontrollerdb.txt` files.

## F-009 · Gamepad: an empty joystick binding reads `szJoystickButton[-1]`

**Status:** reproduced: `mise run repro -- gamepad-empty` gives ASan
`stack-buffer-overflow ... READ of size 1` at `SDL_gamepad.c:1706`. Found by `fuzz_gamepad`
after 208 inputs. Severity: low to moderate, a 1-byte stack read before the buffer whose value
decides `invert_input`.

**Reproduced and fixed:** `repro/f009_gamepad_empty` on `cb6224d2e`: UBSan pointer-overflow, then ASan stack-buffer-overflow, in `SDL_PrivateParseGamepadElement` (`SDL_gamepad.c:1706`). Fixed in `cce7d368b`; the program is clean on the current tree (2026-11-05).

**Code:** `SDL_PrivateParseGamepadElement` does
`szJoystickButton[SDL_strlen(szJoystickButton) - 1] == '~'` with no length check. That reads
index −1 for an empty binding (`a:,`, or `a,` with no colon), and also after stripping a lone
sign (`a:+,`). With a sign the read lands on the sign itself, so ASan stays quiet, but the
pointer arithmetic is still UB (UBSan `pointer-overflow`).

**Parser detail the harness had to mirror:** `:` resets the index but does not clear
`szJoystickButton`. `a:<128 chars>:''` therefore reaches F-006 even though the last part is 2
characters. SDL also rewrites the mapping before parsing it: it trims whitespace, cuts any
`crc:` field up to the next comma, and appends its own. So `a:+crc:12,` becomes `a:+,`.

## F-007 · `SDL_utf8strlcpy` keeps a truncated sequence when the cut is inside the first character

**Status:** proved exact in Lean (`lcpy_c_vs_fixed` in `lean/SDLVerif/Utf8String.lean`), checked
against the real function on 2,493 fuzz-corpus strings (`mise run lean:diff`), and seen
directly. `SDL_utf8strlcpy(dst, "€", 3)` writes `E2 82`, and `("😀", 4)` writes `F0 9F 98`.
Severity: low. The output is not valid UTF-8, against the header's promise that the result
"does not end in a truncated multi-byte sequence". No memory error.

**Reproduced and fixed:** `repro/f007_utf8strlcpy` on `cb6224d2e`: `BUG: ... left a truncated 2-byte sequence`. Fixed in `cce7d368b`; the program is clean on the current tree (2026-11-05).

**Code** (`src/stdlib/SDL_string.c:1060`): the backward scan for the lead byte is
`for (i = bytes - 1; i != 0; --i)`, so it never examines `src[0]`.

**Lean:**
- `lcpy_c_vs_fixed`: on well-formed input, the C differs from a fixed scan (one that also
  examines index 0) *if and only if* `b = min(strlen, dst_bytes − 1)` falls inside the first
  character, at least 2 bytes in.
- `fixLcpy_wf`: the fixed version copies exactly the longest prefix of whole characters that
  fits.
- `lcpy_bounds`: on any input, the C writes at most `dst_bytes` bytes including the NUL.

There are no tests for `SDL_utf8strlcpy` in `test/`.

## F-008 · `SDL_StepBackUTF8` skips stray continuation bytes instead of returning U+FFFD

**Status:** proved exact in Lean (`stepBack_skips_only_cont`), checked against the real function
on the fuzz corpus, and seen directly. Stepping back over `"a\x80"` returns `'a'` and lands at 0.
Stepping forward over the same bytes gives `'a'`, U+FFFD. Severity: low.

**Reproduced and fixed:** `repro/f008_stepback` on `cb6224d2e`: `BUG: returned 0x61 at offset 0, expected U+FFFD at offset 1`. Fixed in `cce7d368b`; the program is clean on the current tree (2026-11-05).

**Code** (`SDL_string.c:270-287`): the walk back stops at the first non-continuation byte, then
decodes one character from there with the whole span as its length. Bytes past that character
are skipped silently. The header says invalid sequences return `SDL_INVALID_UNICODE_CODEPOINT`.

**Lean:**
- `stepBack_skips_only_cont`: the skipped bytes are always continuation bytes, never anything
  else.
- `stepBack_inverts_step`: on any well-formed character, whatever precedes it, `StepBack`
  exactly undoes `Step`.
- `decodeFwd_encodeAll` and `decodeBack_encodeAll`: forward and backward decoding of
  well-formed strings agree.

No memory error. The walk stays within `[start, *pstr)`, and `StepUTF8` is given exactly that
length (`reads_le_slen`).

## F-010 · WAV: channel counts above 255 are truncated to `Uint8`

**Status:** reproduced, `fuzz_wav`. Severity: low. `WaveCheckFormat`
(`src/audio/SDL_wave.c:1676`) rejects only `channels == 0`, but `:2043` does
`spec->channels = (Uint8)format->channels`. With 256 channels the load succeeds with
`spec.channels == 0`. With 1336 it reports 56 channels for data laid out for 1336.
`SDL_AudioSpec.channels` is an `int`, so the cast looks like an SDL2 leftover. Downstream code
that divides by the frame size, or trusts the channel count, gets the wrong layout.

**Reproduced and fixed:** `repro/f010_wav_channels` on `cb6224d2e`: `BUG: a 256-channel file loaded with spec.channels == 0`. Fixed in `cce7d368b`; the program is clean on the current tree (2026-11-05).

## F-016 · WAV: a block align smaller than one frame is accepted

**Status:** reproduced, `fuzz_wav`. Severity: low. `PCM_Init` (`SDL_wave.c:1329`)
checks `(channels * bits) % (blockalign * 8) == 0`, which accepts any block align that
*divides* the frame size. With 17 channels, 8 bits and `blockalign = 1`, `sampleframes` counts
1-byte blocks, and `audio_len` (64) is not a multiple of the 17-byte frame.
`SDL_PutAudioStreamData` and similar consumers expect whole frames.

**Reproduced and fixed:** `repro/f016_wav_blockalign` on `cb6224d2e`: `BUG: audio_len 64 is not a whole number of 17-byte frames`. Fixed in `cce7d368b`; the program is clean on the current tree (2026-11-05).

## F-011 · `SDL_iconv`: the byte order mark is lost when the first character hits E2BIG

**Status:** reproduced, `fuzz_iconv` and a direct check. Severity: low.
`SDL_iconv_string("UTF-32", "UTF-8", s, n)` starts its output with a BOM only for inputs of at
least 8 bytes. For `"UTF-16"` the threshold is 4 bytes. Whether the BOM appears depends on the
input length.

**Reproduced and fixed:** `repro/f011_iconv_bom` on `cb6224d2e`: `BUG: no BOM: output starts with 0x00000078`. Fixed in `cce7d368b`; the program is clean on the current tree (2026-11-05).

**Code** (`src/stdlib/SDL_iconv.c:309-330`, `:767-771`): for the generic `UTF-16`/`UTF-32`
targets, `SDL_iconv` writes the BOM and switches `cd->dst_fmt` to native order before converting
the first character. `*outbuf` and `*outbytesleft` are updated only after each complete
character. If that first character returns E2BIG, the caller is told nothing was written. The
converter has already switched, though, so the retry writes no BOM. `SDL_iconv_string` starts
with an output buffer the size of the input and doubles it on E2BIG, so short inputs hit this.

(Not a finding: for generic `UTF-16`/`UTF-32` *input*, SDL picks the byte order from a BOM
anywhere in the input but does not consume it, so U+FEFF appears in the output. That is a
design choice, not a contract violation.)

## F-012 · Rect: signed overflow in `SDL_GetRectEnclosingPoints`

**Status:** reproduced, UBSan, `fuzz_rect`. Severity: low (UB; in practice a wrong
result). Unlike the other rect functions, `SDL_GetRectEnclosingPoints`
(`src/video/SDL_rect_impl.h:196-295`) has no overflow guard. It computes
`clip->x + clip->w - 1` and `(maxx - minx) + 1` in `int`, which overflows for far-apart points
or a clip rect near `INT_MAX`.

**Reproduced and fixed:** `repro/f012_rect_enclose` on `cb6224d2e`: UBSan signed integer overflow at `SDL_rect_impl.h:290`. Fixed in `cce7d368b`; the program is clean on the current tree (2026-11-05).

## F-014 · Rect: signed overflow in `SDL_GetRectAndLineIntersection`

**Status:** reproduced, UBSan at `SDL_rect_impl.h:417`. Severity: low. The rect is
guarded, but the line's endpoints are not. The Cohen–Sutherland step computes `x2 - x1` in
`int` *before* the cast to the wide type (`(BIGSCALARTYPE)(x2 - x1)`, `:411-425`).

**Reproduced and fixed:** `repro/f014_rect_line` on `cb6224d2e`: UBSan signed integer overflow at `SDL_rect_impl.h:414`. Fixed in `cce7d368b`; the program is clean on the current tree (2026-11-05).

## F-015 · Rect: `SDL_RECT_CAN_OVERFLOW` does not bound what the functions compute

**Status:** reproduced, UBSan at `SDL_rect_impl.h:65`, `:118` and `:192`. Severity:
low. The guard (`:24-35`) checks x and y against ±`INT_MAX/2`, and w and h only from above.
- A negative w or h passes the guard. Then `x + w` and `(x + w) - 1`
  (`SDL_HasRectIntersection`) or `Amax - Amin` (`SDL_GetRectIntersection`) overflow, before
  any emptiness check.
- Two valid, positive rects can be up to ~3·2^30 apart, so `SDL_GetRectUnion`'s
  `result->w = Amax - Amin` overflows as well.

**Reproduced and fixed:** `repro/f015_rect_negative`, `f015_rect_union` on `cb6224d2e`: UBSan signed integer overflow at `SDL_rect_impl.h:108` and `:178`. Fixed in `cce7d368b`; the program is clean on the current tree (2026-11-05).

Phase 5's `Rect.lean` should characterize exactly the inputs the guard lets through and where
they overflow.

## F-017 · BMP: the RLE decoder moves its row pointer outside the pixel buffer

**Status:** reproduced, UBSan `pointer-overflow` at `src/video/SDL_bmp.c:116`.
Severity: low. In `readRlePixels`, end-of-line and delta escapes (`bits -= pitch`,
`bits -= ch * pitch`) can move `bits` far below `start`. Every write goes through `COPY_PIXEL`,
which checks `spot >= start && spot < end`, so no out-of-bounds write was seen. Forming and
comparing such pointers is UB, though, and UBSan only notices when the address wraps, which
depends on where the buffer was allocated. The fuzz build suppresses this one site
(`harness/ubsan.supp`) so the target can keep exploring.

**Reproduced and fixed:** `repro/f017_bmp_rle` on `cb6224d2e`: UBSan pointer-overflow at `SDL_bmp.c:131` (70,000 RLE deltas, so the address wraps on any allocation). Fixed in `cce7d368b`; the program is clean on the current tree (2026-11-05).

## F-018 · BMP: `biHeight == INT_MIN` is negated

**Status:** reproduced, UBSan at `SDL_bmp.c:367`. Severity: low. A top-down BMP is
flipped with `biHeight = -biHeight`, and the check above it only rejects `biHeight == 0`.

**Reproduced and fixed:** `repro/f018_bmp_int_min` on `cb6224d2e`: UBSan negation of -2147483648 at `SDL_bmp.c:367`. Fixed in `cce7d368b`; the program is clean on the current tree (2026-11-05).

## Observation O-1 · BMP and WAV allocations scale with header fields

A 100-byte BMP asked for an 8 GB pixel buffer: SDL allocates `w × h` from the header before
reading any pixels. That is not memory corruption. It is a resource issue for apps that load
untrusted images. The fuzz runs cap allocations at 1 GB through ASan
(`max_allocation_size_mb`), so SDL sees the allocation fail and handles it.

---

## F-006 · Gamepad mapping: 128-character joystick binding overflows a stack buffer (was L-3)

**Status:** reproduced, ASan on a real Debug build (`mise run repro -- gamepad-joy`).
Severity: moderate. It is an out-of-bounds stack read reachable from mapping strings, which can
come from `SDL_AddGamepadMapping`, the `SDL_GAMECONTROLLERCONFIG` hint/env var, or a
`gamecontrollerdb.txt` file.

**Reproduced and fixed:** `repro/f006_gamepad_joy128` on `cb6224d2e`: ASan stack-buffer-overflow in `SDL_PrivateParseGamepadElement` (`SDL_gamepad.c:1706`). Fixed in `cce7d368b`; the program is clean on the current tree (2026-11-05).

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

**Status:** reproduced on a real build (`mise run repro -- utf8-range`), and proved
exactly in Lean. Severity: low (wrong output, no memory error).

**Reproduced and fixed:** `repro/f005_utf8_range` on `cb6224d2e`: `BUG: 3 of 3 sequences above U+10FFFF were returned as code points`. Fixed in `cce7d368b`; the program is clean on the current tree (2026-11-05).

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

**Status:** reproduced, ASan on a real build (`mise run repro -- utf8-null`), and
proved in Lean. Severity: low to moderate. It is a heap/stack over-read of up to 2 bytes, for
any caller that passes `NULL` for `pslen` on untrusted text ending in a truncated multi-byte
sequence.

**Reproduced and fixed:** `repro/f004_steputf8_null`, `f004_strcasecmp` on `cb6224d2e`: ASan heap-buffer-overflow in `StepUTF8` (`SDL_string.c:240`) and in `SDL_strcasecmp` (`:1494`). Fixed in `cce7d368b`; the program is clean on the current tree (2026-11-05).

`SDL_StepUTF8` with `pslen == NULL` calls `StepUTF8(pstr, 4)` (`SDL_string.c:262`), which
tells it 4 bytes are available. The 3- and 4-byte branches load `str[1]`, `str[2]` and
`str[3]` *before* checking whether any of them is a continuation byte (`:225-226`, `:239-241`).
For the 2-byte heap string `"\xF0"` this reads `str[2]` and `str[3]` past the NUL. The header
promises the function "will blindly read until it sees the NULL char".

**ASan:** `heap-buffer-overflow … READ of size 1 … 0 bytes after 2-byte region`, in `StepUTF8
SDL_string.c:240` ← `SDL_StepUTF8_REAL :262`.

**More callers (found 2026-11-05):** the same `StepUTF8(&str, 4)` assumption sits in
`SDL_strcasecmp` (`SDL_string.c:1494`, commented "always NULL-terminated, no need to adjust
lengths") and in `SDL_utf8strlen` (`:1083`). Both over-read the same way under ASan
(`mise run repro -- utf8-strcasecmp`). `fuzz_gamepad` hit it through `SDL_AddGamepadMapping` →
`SDL_strcasecmp`. That is a much wider reach than direct `SDL_StepUTF8` callers:
`SDL_strcasecmp` compares hint names, mapping fields and many other strings.

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
re-checking a predicate. Decide whether this is worth a doc note ("spurious wakeups
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

L-1, L-2 and L-3 have become F-004, F-005 and F-006 above; L-4 and L-5 have become F-019 and F-020.

| ID | Lead | Source |
|---|---|---|
| L-4 | Lost wakeup in `SDL_WaitEventTimeout_Device` | now F-019 (model counterexample, reproduced) |
| L-5 | Find-then-ref window in `ObtainPhysicalAudioDevice` | now F-020 (model counterexample) |
