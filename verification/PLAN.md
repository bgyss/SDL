# Formal verification of SDL3 with Lean 4 and TLA+: plan

Companion to [RESEARCH.md](RESEARCH.md), which holds the evidence, citations and `path:line`
references for everything below. This file is the order of work, the deliverables, and the rules.

## Scope and stance

**Goal.** Get machine-checked assurance for the parts of SDL where bugs are likeliest and most
costly:
- untrusted-input parsing
- small pure functions that every app uses
- cross-thread protocols

**The two tools have different jobs:**
- **TLA+** models the concurrency protocols (event wait/wakeup, audio device lifetime,
  condition variables, init/quit). The Anthropic article's proofs assume "a single-threaded static
  binary", so this is the class of bugs its method cannot reach.
- **Lean 4** writes reference models of pure C functions, proves properties of those models
  against the governing standard or header docs, and checks the C against the model by
  differential testing. Lean has no mature route from C or binaries yet: Clift is WIP, LNSym is
  stale and Arm-only, and sail-riscv's Lean model is experimental (RESEARCH §2.2). So proving
  things about the C code itself is out of scope unless the Phase 6 experiment pays off.

**The article's conclusions, applied here** (detail in RESEARCH §7):
1. **Specs come from tests.** SDL has no fuzz targets, so writing harnesses is part of the work
   (Phase 3). Each harness doubles as the no-crash spec and the differential driver.
2. **Generic properties scale.** Parsers aim for "no crash, hang, or sanitizer report".
   Protocols aim for deadlock freedom, no use-after-free on refcounted objects, and no lost
   wakeups. Functional specs are reserved for small pure code.
3. **Guard against spec gaming.** See the rules below. They are not optional.
4. **"Formally verified" ≠ bug-free.** Each model is tied back to the C, by differential testing
   (Lean) and by trace validation (TLA+).
5. **The trusted base is explicit.** It lives in `verification/TRUSTED_BASE.md`.
6. **Reuse.** There is one shared Lean library and one shared TLA+ module set. New specs build
   on them rather than starting fresh.

## Ground rules

- **Fork only.** Upstream policy forbids AI-generated contributions (RESEARCH §8). All of this
  stays under `verification/` in `bgyss/SDL`. A finding goes upstream only if a human reproduces
  it on a real build and writes the report or fix in their own words.
- **No `src/` edits in a proof change.** Proofs and specs refer to a pinned SDL commit, recorded
  in `TRUSTED_BASE.md`. A C change that a proof needs is a separate, human-reviewed patch that
  states which inputs change behaviour.
- **Every property must be able to fail.** For each TLA+ invariant or temporal property, commit a
  seeded mutant spec that violates it. TLC coverage must show every action enabled. For each Lean
  theorem about the C, keep a differential test that fails on a mutated C build.
- **No `sorry`, `admit` or new `axiom` on the main branch.** CI checks with
  `#print axioms` on every exported theorem and allows only the standard three plus
  `Lean.ofReduceBool` where `bv_decide` is used.
- **Bounds are part of the claim.** A TLC result is reported together with its constants
  (threads, queue length, events). "No error found" without the bounds is not a result.
- **Instrumentation is an overlay.** Trace macros live in `verification/instrument/` and are
  enabled only by a fork-only CMake option. They are never written into `src/`.

## Layout

```
verification/
  RESEARCH.md  PLAN.md  TRUSTED_BASE.md  FINDINGS.md
  tla/
    common/            Mutex.tla Semaphore.tla RWLock.tla AtomicRef.tla
    <spec>/            <Spec>.tla  MC.tla  MC.cfg  mutants/  (Trace.tla for trace validation)
  lean/                lake project: lean-toolchain, lakefile.toml, SDLVerif/…, test/
  harness/             libFuzzer targets + differential shims linking libSDL3
  instrument/          VERIF_TRACE macros (compiled out unless SDL_VERIF_TRACE)
```

The tools come from the repo `flake.nix`: `tlaplus` 1.7.4 for `tlc`, and `elan` for Lean. Lean
itself is pinned by `verification/lean/lean-toolchain`, because elan honours that file. The
`mise run tla` task model-checks every spec. `mise run lean` runs `lake build`.

## Phases

Each phase ends with a commit to the fork and an entry in `FINDINGS.md`. Phases 1 and 2 can run
in parallel.

### Phase 0: Foundations and reproducing the leads

- [x] Write `TRUSTED_BASE.md`. It records:
  - the pinned SDL commit
  - Lean, TLC and clang versions
  - per-spec bounds and backend abstractions
  - the memory-model assumption (sequentially consistent interleaving)
- [x] Get a sanitizer toolchain working in the dev shell. Configure SDL with
  `-fsanitize=address,undefined` using the flake's clang. If nix clang can't link the ASan
  runtime on macOS, add `llvmPackages.compiler-rt` or document `/usr/bin/clang` as the
  sanitizer compiler. *Done: nix clang's ASan hangs on macOS 27, so `mise run asan:build`
  uses Apple clang (TRUSTED_BASE.md).*
- [x] Tooling reproduction: `mise run repro` reproduces all three leads on a real ASan build.
  The gamepad lead turned out to be live only on the 128-character joystick side; the
  20-character game-button side is latent. See F-004, F-005 and F-006.
- [ ] **Human step.** (Kit ready: `HUMAN_REPRO.md` has short standalone programs for each,
  with expected ASan output, all checked on 2026-11-05. The step itself is still yours.)
  Reproduce the three leads from RESEARCH §10 on a real sanitizer build:
  - the `SDL_StepUTF8(…, NULL)` over-read
  - `StepUTF8` accepting codepoints above U+10FFFF
  - the unterminated buffer for a 20-character gamepad mapping element name

  Record the results in `FINDINGS.md`. Decide personally whether to report any of them upstream.
- [ ] Settle RESEARCH open question 3: find where SDL documents its threading contracts for
  `SDL_Quit*` and for event and audio calls. The specs encode those contracts, not guesses.

**Exit:** a sanitizer build of SDL with tests passes, `TRUSTED_BASE.md` exists, and the three
leads are confirmed or dismissed.

### Phase 1: TLA+ pilot (`SDL_InitState`, then the generic condition variable)

These two are small and fully readable, so they are cheap pilots for the method itself: shared
modules, mutants, coverage checks and the `mise run tla` loop.

**Status (2026-11-04):** both specs are done. Results are in FINDINGS.md: F-001 (InitState
proved within bounds), F-002 (correction: the generic condition variable is not used on macOS)
and F-003 (a stale-token spurious wakeup in the generic condition variable).
`tla/common/` was deferred. Both specs are self-contained, so the shared modules will be
extracted when Phase 4 needs them.

- [ ] `tla/common/`: `Mutex`, `Semaphore` and `AtomicRef` (compare-and-swap) operators.
- [x] `tla/initstate/`: model `SDL_ShouldInit`, `SDL_ShouldQuit` and `SDL_SetInitialized`
  (`src/thread/SDL_thread.c:556`) with N threads. Check:
  - at most one thread in INITIALIZING or UNINITIALIZING
  - init and quit bodies never overlap
  - every caller eventually returns, assuming the initializing thread eventually calls
    `SetInitialized`
  - include failed init (`SetInitialized(false)`).
- [x] `tla/cond_generic/`: write a model of `src/thread/generic/SDL_syscond.c` over the
  generic semaphore. Check:
  - no lost signal: a waiter that is waiting when `Signal` is called gets woken
  - `Broadcast` wakes all current waiters
  - no deadlock under timeouts
  - (correction: this backend is not used on macOS/iOS; see FINDINGS F-002)
- [x] Commit at least one mutant per property, and record the coverage output.
- [ ] Make module lookup for `common/` work: either set `-DTLA-Library` through the `tlc`
  wrapper's Java options or use per-spec symlinks. Update the `mise` task to match.

**Exit:** `mise run tla` checks both specs with the bounds stated. Each mutant fails. Results go
in `FINDINGS.md`.

### Phase 2: Lean pilot (UTF-8)

**Status (2026-11-05): done.** StepBack, utf8strlcpy and the encoder were added on 2026-11-05
(`Utf8Encode.lean`, `Utf8String.lean`, 56 theorems). They found F-007 and F-008. `mise run lean`
checks 12 proof mutants. `mise run lean:diff` adds a corpus differential: the new string-level
models against the real C on the fuzz_utf8 corpora.

Earlier status (2026-11-04), for the record:
- `SDLVerif/Utf8.lean` has 12 theorems about `StepUTF8`. They cover bounds, progress, end of
  string, RFC 3629 completeness and soundness, and an exact characterization of the out-of-range
  bug. They also cover a model fix with a patch audit.
- `mise run lean` checks the theorems, the axioms and seven proof mutants.
- `mise run lean:diff` compares against the real C on 3,096,576 cases: every lead byte, times
  12 boundary values for each continuation byte, times `slen` 0–5 and `NULL`. That is a
  boundary grid, not all 2^32 sequences. All cases agree.
- (Done 2026-11-05) `SDL_StepBackUTF8`, `SDL_utf8strlcpy`, and an encoder with round-trip proofs.
- Findings: F-004 and F-005, plus F-006 from the Phase 0 reproduction.

- [x] Create the `lean/` lake project with a `lean-toolchain` file. Add Mathlib only if a proof
  needs it, because it is expensive to build.
- [x] `SDLVerif/Utf8.lean`, `Utf8Encode.lean`, `Utf8String.lean`:
  - Write an executable RFC 3629 decoder model.
  - Write a model of SDL's documented `SDL_StepUTF8` / `SDL_StepBackUTF8` / `SDL_utf8strlcpy`
    contract, taken from `include/SDL3/SDL_stdinc.h`.
  - Prove that the model accepts exactly the well-formed sequences, never reads past
    `slen`/NUL, round-trips with an encoder, and that `StepBack` inverts `Step`.
  - Use `bv_decide` / `decide` for the byte-level lemmas.
- [x] (boundary grid, plus the fuzz_utf8 corpora since 2026-11-05: `test/utf8_corpus.sh`)
  `lean/test/utf8_diff.c` plus `lean/test/`: run SDL's C and the Lean executable on the same
  inputs: exhaustive over all ≤4-byte sequences plus fuzzer-generated longer strings. Report
  every disagreement. Expected disagreements, such as codepoints above U+10FFFF if confirmed in
  Phase 0, are listed explicitly in `FINDINGS.md`, never silenced in the harness.

**Exit:** the theorems check with no `sorry` and pass the axioms check. The differential run is
clean except for documented, human-triaged disagreements.

### Phase 3: Fuzz harnesses as specs (the article's "tests to specs" step)

**Status (2026-11-05): done for this round.** Six targets are in `harness/` (README.md there),
built by `mise run fuzz:build` with no CMake or `src/` changes. Five 5-minute runs per target
found F-009 to F-018. The targets stop again only when they hit something new: each known
finding is skipped on its own trigger set, and `mise run fuzz:regress` keeps each one
reproducible. utf8 and iconv have run more than 10M inputs each with nothing new.

- [x] Add libFuzzer targets in `verification/harness/` (built by `harness/fuzz.sh` rather than
  a CMake option, so no CMake file changes), for:
  - `SDL_StepUTF8` / `SDL_iconv`
  - integer rect functions
  - `SDL_AddGamepadMapping`
  - `SDL_LoadBMP_IO`
  - `SDL_LoadWAV_IO`
- [x] Seed the corpora from `test/` resources and `testautomation_*` cases (`seedgen.c`, plus
  `test/sample.wav` and `test/sword.wav` heads; `test/` has no BMPs any more, so BMP seeds are
  generated, including RLE4/RLE8/1-bit/4-bit).
- [x] Run each target under ASan and UBSan. Any crash goes into `FINDINGS.md`, gets human
  triage, and gets a regression input. (Tooling triage done; human triage open.)
- [x] Write down the "no crash, hang or sanitizer report for inputs ≤ N bytes" property for each
  target (TRUSTED_BASE.md, "Fuzz properties"). That property is the spec a later binary-level
  proof (Phase 6) would discharge.

**Exit:** all five targets run for a fixed budget with no untriaged crashes, and the corpora are
committed (or stored) with sizes recorded.

### Phase 4: The high-value TLA+ targets, with trace validation

**Status (2026-11-05): both models are done; trace validation is not.**
- `tla/events_wait` confirmed L-4 as F-019 with an 8-state counterexample. A stress program
  then reproduced it on the real macOS build (`mise run repro:wakeup`).
- `tla/audio_device` confirmed L-5 as F-020 (12 states), and showed that the obvious fix is
  not enough.
- Both have passing real-code and model-fix configs, and four or three mutants each.
- Trace validation (`instrument/`, `Trace.tla`) is still open. For F-019, the stress repro
  stands in as the link to the real code. F-020 has no real-code link yet.

- [x] **Read before modeling.** (Cocoa, X11, Win32 latch the wakeup and none re-checks SDL's
  queue; Wayland not read. See TRUSTED_BASE.md, Abstractions.) Check whether the Cocoa, X11, Wayland and Win32
  `WaitEventTimeout` backends latch a wakeup that is posted before the wait begins (RESEARCH
  open question 1). That answer decides how the backend is abstracted.
- [x] `tla/events_wait/`: model `SDL_WaitEventTimeout_Device` (`src/events/SDL_events.c:1631`),
  `SDL_SendWakeupEvent` and the queue lock. Check that there is no lost wakeup when an event is
  pushed between the queue check (`:1646`) and setting `wakeup_window` (`:1671`).
- [x] `tla/audio_device/`: model device lookup, refcounting and disconnect
  (`src/audio/SDL_audio.c:481`). Check that a device is never freed while it is between lookup
  (`:493`) and taking its reference, given the other references that exist in practice (open
  question 2).
- [ ] **Trace validation** (Cirstea, Kuppe, Loillier and Merz 2024):
  - Add `VERIF_TRACE` NDJSON logging in `instrument/`.
  - Run real SDL test programs (`testautomation`, `testaudiohotplug`, event stress) with it.
  - Check the traces with a `Trace.tla` per spec.
  - This connects each model to the real code.

**Exit:** both specs check with stated bounds, and each has mutants. At least one real trace per
spec validates. Each hypothesis is marked confirmed (with a counterexample trace) or refuted
(with the reason) in `FINDINGS.md`.

### Phase 5: Expanding the Lean models

- [ ] `Rect.lean`: model the integer rect operations in `src/video/SDL_rect_impl.h` (intersect,
  union, enclose points, line clipping) using 32-bit two's-complement arithmetic. Prove the
  algebraic properties (intersection is commutative and contained in both inputs, union contains
  both inputs, clipped line endpoints lie inside the rect). Characterize the inputs where the C
  overflows (`SDL_ENCLOSEPOINTS`, `SDL_INTERSECTRECTANDLINE`), and cross-check against UBSan runs
  of the Phase 3 rect harness. Also use `testautomation_rect.c` expectations as an oracle.
- [ ] `GamepadMapping.lean`: write a grammar and parser model for mapping strings, plus a
  round-trip property against SDL's mapping-to-string output. Run it differentially against the
  Phase 3 harness.
- [ ] BMP and WAV header arithmetic: prove that the size and offset computations
  cannot overflow or exceed the stream length, for the field ranges the C code accepts.
- [ ] Extend the shared bit-vector and arithmetic lemmas in `SDLVerif/Common/` as they come up.

### Phase 6 (optional, time-boxed): routes to the C code itself

Only do this after Phases 1–5 have produced results. Each item gets a fixed time budget and a
go/no-go write-up.

- [ ] **Clift experiment.** Lift `StepUTF8` into Lean, using its own Lean pin in a separate
  shell, and prove that it refines the Phase 2 model. Decide whether a proof about the lifted C
  adds enough over differential testing to justify the extra work.
- [ ] **Binary-level no-crash proofs.** Check whether Theorem's `rocq-linux-process-semantics` /
  `oss-verify-proofs` can be used locally without their service, and what the licence allows
  (open question 5). Their main route, OSS Verify, needs enrollment by a core maintainer, so it
  is closed to this fork.

## Open decisions for the user

1. Whether any confirmed finding is reported upstream, and by whom (RESEARCH §8, open question 7).
2. Whether to add Apalache for symbolic checking with larger bounds than TLC can handle. It
   isn't in nixpkgs as far as checked, so it would need a pinned fetch in the flake.
3. Whether Phase 6 is in scope at all.
