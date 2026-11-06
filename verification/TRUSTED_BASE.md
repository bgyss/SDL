# Trusted base

A result in `verification/` is only as good as what it assumes. This file lists those assumptions.
Update it whenever a tool version, pinned commit or model bound changes.

## Pinned code

| Item | Value |
|---|---|
| Pre-fix SDL source (findings, line numbers, "pre-fix" configs) | `cb6224d2e` (fork). Its `src/` is identical to upstream `87f0e4a25`; the fork only changed docs and tooling. Also the base tree of `repro/run.sh`. |
| Current SDL source (`MC_fix.cfg` configs, Lean `*Fixed` models, trace validation) | the fixes in `cce7d368b` (F-004 – F-020) and the F-021 commit after it. |
| Re-check needed when | any file named in a spec header changes. `instrument/build.sh` fails when an instrumentation patch no longer applies, which flags the audio and events code. |

## Tools

| Tool | Version | Source | Notes |
|---|---|---|---|
| TLC | 2.19 (08 Aug 2024, rev 5a47802) | nixpkgs `tlaplus` 1.7.4, via `flake.lock` (nixpkgs `9d3b8db`, 2026-11-03) | Runs on the Azul JDK 1.8 x86_64 build that the package bundles. On Apple Silicon this runs under Rosetta. |
| Lean | 4.35.0 | `elan` (nixpkgs 4.2.4), pinned by `verification/lean/lean-toolchain` | No Mathlib. Proofs use `bv_decide` from core `Std`, whose SAT/LRAT certificates are checked natively and enter the proof as auxiliary axioms `*._native.bv_decide.ax_*`. That puts the Lean compiler and the bundled CaDiCaL/LRAT checker in the trusted base. `mise run lean` rejects any other axiom, including `sorryAx`. In a new git worktree, run `direnv allow` first (or use `direnv exec .`). Without the dev shell, another `lean` on `PATH` (4.26 on the dev machine) is used, and the UTF-8 `bv_decide` proofs fail under it. Check with `lake env lean --version`. |
| C compiler (models, differential tests) | nixpkgs clang 21.1.8 | `clangStdenv` | Used for `build/`, which the differential tests link against. |
| C compiler (sanitizers) | Apple clang 21.0.0 (clang-2100.4.1.1) | Xcode | On macOS 27 the nix clang 21 ASan runtime hangs at startup, even for a hello world, so `mise run asan:build` uses `/usr/bin/clang` with `DEVELOPER_DIR` and `SDKROOT` reset. |
| Fuzzer | libFuzzer from LLVM 21.1.8 | the nix clang's `libclang_rt.fuzzer_osx.a`, linked into Apple-clang objects | Apple clang ships no libFuzzer, and nix clang's ASan hangs. `harness/fuzz.sh` compiles SDL and the targets with Apple clang (ASan + UBSan + `-fsanitize-coverage=inline-8bit-counters,pc-table,trace-cmp`) and links nix's libFuzzer runtime (same LLVM major version). UBSan is non-recoverable except `pointer-overflow`, which is recoverable only so that `harness/ubsan.supp` can silence it at the one F-017 site. |

## Modelling assumptions (all TLA+ specs)

- **Sequentially consistent interleaving.** Each modelled step is atomic, and steps from different
  threads interleave arbitrarily. SDL's `SDL_AtomicInt` operations are sequentially consistent on
  all backends. Plain (non-atomic) fields are modelled only where they are accessed under a lock
  or by a single owner.
- **Fair scheduling.** The specs use weak fairness (InitState, EventsWait, AudioDevice) or strong
  fairness (GenericCond) per thread. That means a thread that can run eventually runs, and blocked
  semaphore or mutex waits are fair. Liveness results depend on this.
- **Bounded clients.** Each result holds for the stated numbers of threads and operations.
  "No error found" means "no error within these bounds".
- **Contracts from the headers.** Clients are modelled as following the documented usage in
  `include/SDL3/SDL_mutex.h`, for example that the owner calls `SDL_SetInitialized` exactly once and
  that the mutex is held when waiting. Behaviour outside the contract is not checked unless a spec
  says so.

## Per-spec bounds

| Spec | Config | Bounds | Fairness |
|---|---|---|---|
| `tla/initstate` | `MC.cfg` | 3 threads × 2 init/quit calls; init may fail | WF per thread |
| `tla/cond_generic` | `MC.cfg` | 3 consumers, 3 producers, tickets client, untimed waits, signal inside or outside the mutex, Signal or Broadcast | SF per thread |
| `tla/cond_generic` | `MC_timeouts.cfg` | 2 consumers, 2 producers, tickets client, any semaphore wait may time out | SF per thread |
| `tla/cond_generic` | `MC_flag.cfg` | 3 consumers, 1 producer, flag + Broadcast client, timeouts | SF per thread |
| `tla/events_wait` | `MC.cfg` | pre-fix code; 1 waiting thread, 3 producers × 1 event; timed waits (the app calls again after a timeout) | WF per thread |
| `tla/events_wait` | `MC_fix.cfg` | current code: publish-then-check order; 3 producers; untimed `SDL_WaitEvent` | WF per thread |
| `tla/events_wait` | `findings/*.cfg` | pre-fix code; 1 producer; untimed (deadlock) and timed (`NoLostWakeup`) | WF per thread |
| `tla/audio_device` | `MC.cfg` | pre-fix code; device held open by the app; main-thread disconnect + 2 lookup threads | WF per thread |
| `tla/audio_device` | `MC_fix.cfg` | current code: increment-if-nonzero under the read lock; device not open; 2 lookup threads | WF per thread |
| `tla/audio_device` | `findings/*.cfg` | pre-fix code and the naive ref-in-lock fix; device not open; 1 lookup thread | WF per thread |

Since 2026-11-05, `tla/events_wait` also models the entry pump and queue check that
`SDL_WaitEventTimeoutNS` does before the device loop, and the separate clear of
`wakeup_window` after a take in the fixed code. Trace validation found the first one missing.

## Trace validation (Phase 4)

`mise run trace` (`instrument/trace_check.sh`) links the models to the current code:

1. `instrument/build.sh` exports the working tree, applies `instrument/<spec>.patch` to the
   copy (never to `src/`), and builds it. The patch logs each modelled step as an NDJSON line.
   The step and its log line happen inside one global trace lock, so the log order is the order
   in which the steps took effect.
2. `trace_audio` / `trace_events` run the race workloads of `repro/f020` and `repro/f019`.
3. `trace2tla.py` maps each line to a model action: one model looker per lookup that found the
   device, one model producer per push. It refuses any line it has no mapping for.
4. TLC replays each trace in `tla/<spec>/Trace.tla`, with deadlock checking off. A trace passes
   if some behavior of the model takes exactly the logged steps, with the logged values. Each
   `trace/mutants/*.cfg` (the pre-fix model) must fail to replay the first trace.

What this trusts:
- the trace lock does not hide interleavings that matter. It serializes the logged steps,
  which only removes interleavings, so every log is still a real run.
- the patch's log points sit where the model's steps are.

What the log cannot show: the native event count, and why a backend wait returned. TLC infers
the first. For the second, either model step may match. Results on 2026-11-05: audio, 30 of 30
device lifetimes (60 of the lookups in them hit a device whose count was already 0). Events,
one 300-round run of 2,662 steps. Both pre-fix mutants were rejected.

## Reproductions (`repro/`)

`mise run repro:verify` builds 21 standalone programs against `cb6224d2e` and the current tree
(Apple clang 21.0.0, ASan + UBSan, static SDL) and checks each outcome against
`repro/EXPECT`. The races (`f019`–`f021`) are stress tests. A clean run on the fixed tree is
evidence, not proof.

## Lean models

| Model | What is trusted | What ties it to the C |
|---|---|---|
| `lean/SDLVerif/Utf8.lean` `cStep` | that the transcription matches `StepUTF8` (`SDL_string.c:192-257`), with C integer widths as `BitVec`. The `reads` field is our accounting of dereferences. | the differential test against the real `SDL_StepUTF8` (3,096,576 cases, `mise run lean:diff`) and the ASan reproductions (`mise run repro`). The differential test checks `cp` and `adv`. It does not check `reads`, which ASan covers. |
| `wfLen` / `decodeVal` | that they transcribe RFC 3629 §4 and §3 | written from the RFC grammar, independently of SDL's bit tests. The `spec_f4_allows_9x` mutant shows the theorems depend on it. |
| `lean/SDLVerif/Utf8Encode.lean` `cEncode` | that it transcribes `SDL_UCS4ToUTF8` (`SDL_string.c:47-80`) | checked against RFC 3629 (`enc_wf`) and against `cStep` in both directions. No separate C differential yet; the corpus test exercises the decoders, not the encoder. `fuzz_utf8` round-trips the real encoder through the real decoder on every input. |
| `lean/SDLVerif/Utf8String.lean` `walkBack`/`cStepBack` | that it transcribes `SDL_StepBackUTF8` (`SDL_string.c:270-287`) | `mise run lean:diff` corpus test: the fuzz_utf8 corpora (2,493 strings, 675 KB on 2026-11-05), backward decode step by step against the real function |
| `lean/SDLVerif/Utf8String.lean` `cLcpy`/`scanC` | that it transcribes `SDL_utf8strlcpy` (`SDL_string.c:1045-1078`); strings are the bytes before the NUL | the same corpus test, with every `dst_bytes` from 1 to len + 2 |
| `lean/SDLVerif/Rect.lean` `hasInter`/`inter`/`union`/`enclose` | that they transcribe `SDL_HasRectIntersection`, `SDL_GetRectIntersection`, `SDL_GetRectUnion` and `SDL_GetRectEnclosingPoints` (`SDL_rect_impl.h`, int instantiation), with `int` as `BitVec 32` and every `int` `+`/`-` flagged by `saddOverflow`/`ssubOverflow`. `fixed := false` is `cb6224d2e`. `CHECK_PARAM` NULL checks are not modelled, because the arguments are never NULL there. | `test/rect_diff.sh` (part of `mise run lean:diff`): 200,000 generated cases (half in [-20, 20], half on the guard boundaries) through the real functions; the outputs match the model exactly. Against the pre-fix model it disagrees on the F-015 inputs, as it should. |
| `lean/SDLVerif/RectLine.lean` `clip`/`loop`/`step` | that they transcribe `SDL_GetRectAndLineIntersection` over `Int`, with `Int.tdiv` for C's `/` on `Sint64`. That is exact only because the theorems show every intermediate fits (`step_ok`, `products_fit`), so the two are proved together. | the same differential test (200,000 line cases, 4,310 of them clipped by the loop) |
| `lean/SDLVerif/Header.lean` `rgbPitch`/`surfaceOk` | that `rgbPitch` transcribes `SDL_CalculateRGBSize` (non-minimal pitch) and `surfaceOk` the F-023/F-024 check in `SDL_CalculateSurfaceSize`. `size_t`/`Sint64` quantities are `Nat` with explicit bounds (64-bit targets). The BMP row loop and the WAV decoders are summarized by their arithmetic, not transcribed step by step. | `repro/f023`, `repro/f024` and `testautomation` `surface_testIntSize` exercise the boundary on the real code; no differential test |
| strings as `List Byte` | reading past the end of the list gives 0. No theorem depends on that value: they either keep reads in range or use `reads_le_slen`/`adv_le_slen` | n/a |

## Abstractions

- `tla/cond_generic`: the three internal `SDL_Semaphore`s are atomic counting semaphores. That is
  true on the platforms where this code runs (native kernel semaphores on Vita, PSP, PS2, 3DS and
  DOS, and Win32 semaphores in the Windows fallback). A timeout is a nondeterministic choice, not
  a clock.
- `tla/events_wait`: the backend wakeup is a latched counter of native events. This holds for
  Cocoa (`postEvent`), X11 (`XSendEvent`) and Win32 (`PostMessage`), checked by reading each
  backend's `SendWakeupEvent`/`WaitEventTimeout`. Pumping drains every pending native event.
  Other OS events that could end a wait are not modelled. The queue lock is implicit in the
  atomic `w_peep`/`p_push` steps. Android takes a different path (`Android_PumpEvents`) and is
  not covered.
- `tla/audio_device`: one physical device. The hash table is one "in hash" bit. Refcount
  operations are atomic. The read lock is held only inside the atomic find step, which is
  exact for the real code: it unlocks before taking the reference. The device mutex and the
  logical-device bookkeeping are not modelled, since they do not affect the refcount race.

## Fuzz properties (Phase 3)

Each target's spec is "no crash, hang (10 s), ASan or UBSan report, or failed PROPERTY for inputs
of at most `-max_len` bytes", within the stated run time. That is evidence, not proof.

| Target | max_len | Extra properties |
|---|---|---|
| `fuzz_utf8` | 4096 | every `StepUTF8`/`StepBackUTF8`/`utf8strlcpy`/`UCS4ToUTF8` result checked against an RFC 3629 reference, deviations allowed only on the Lean-proved sets of F-005, F-007 and F-008 |
| `fuzz_iconv` | 4096 | cursor and count consistency, E2BIG only when the buffer cannot hold a character, BOM present |
| `fuzz_rect` | 1024 | intersection commutative and inside both inputs, union contains both, clipped endpoints inside, enclosing rect inside the clip |
| `fuzz_gamepad` | 2048 | a gamepad's own mapping string is accepted again |
| `fuzz_bmp` | 65536 | positive size, pitch covers a row, every pixel byte readable |
| `fuzz_wav` | 65536 | valid spec, channel count matches the file, `audio_len` a whole number of frames, every byte readable |

Known findings are skipped only on their trigger sets, which are written out in each target
(exact where possible, over-approximated and marked so otherwise). `SDL_FUZZ_KNOWN=1` turns every
skip off. `harness/regress.sh` checks that each regression input still reproduces its finding
with the skip off.
