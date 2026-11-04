# Formal verification of SDL3 with Lean 4 and TLA+: research notes

Status: research only, as of 2026-11-04. This is not a plan; `verification/PLAN.md` will hold the plan.
Scope: the fork `bgyss/SDL`. Under the upstream policy (§8), none of this goes upstream.

Conventions: `path:line` refers to this worktree (based on `ec5c575fc`). Each external claim links to
its source. "Confirmed" means I checked it myself. "Hypothesis" means a reading of the code that has
not been reproduced against a real SDL build.

---

## 0. Summary

* The article proves **no-crash properties of single-threaded binaries in Rocq**. Its proofs
  explicitly assume a single-threaded process, so they leave out the class of bugs where TLA+ is
  strongest. Lean and TLA+ are complements to its method, not reproductions of it.
* SDL has no coverage-guided fuzz targets and is not in OSS-Fuzz. Theorem's OSS Verify accepts
  projects outside OSS-Fuzz, but enrollment must come from a core maintainer, so a fork cannot use
  that path (§3).
* Reading the code and running small standalone extracts turned up three issues worth reporting.
  Two are **confirmed on extracted code under ASan**: a `SDL_StepUTF8` over-read and an accepted
  out-of-range codepoint. The third, an off-by-one that leaves a gamepad-mapping buffer
  unterminated, was confirmed with a stand-in consumer. Two concurrency **hypotheses** are best
  checked with TLA+: a lost wakeup in `SDL_WaitEventTimeout` and a find-then-ref window in
  `ObtainPhysicalAudioDevice`. Details are in §5 and §6. A human must confirm each one on a real
  build before it is reported anywhere.
* The highest-value targets are:
  * TLA+:
    1. event-wait/wakeup protocol
    2. audio device refcount/lookup
    3. generic semaphore-based condition variable
    4. `SDL_InitState`
  * Lean:
    1. UTF-8 decoding against RFC 3629
    2. integer rect math, including overflow
    3. gamepad mapping parser
    4. BMP/WAV header arithmetic

---

## 1. What the article actually says (re-read 2026-11-04)

Source: [Anthropic, "Formal verification" (Frontier Red Team with Theorem, published Oct 22 2026)](https://www.anthropic.com/research/formal-verification).
The quotes below are verbatim from the page. I did not read the appendix PDF linked from the article.

| Topic | What the article says |
|---|---|
| Scope | 239 entry points across 123 OSS-Fuzz libraries, proved at the **RISC-V binary** level in **Rocq**, covering every input under 64 MB. About 180M lines of Rocq in total. A typical proof is about 600k lines, for binaries with a median of 18k RISC-V instructions. The work took "a few weeks". |
| Spec source | "we take the approach of automatically converting their preexisting compilable test suites into a spec". The property is that the fuzz target does not crash for any input below the bound. |
| Concurrency | "these proofs currently assume that the program runs as a single-threaded static binary". The article says nothing else about concurrency. |
| Spec gaming (footnote) | "Claude could make any theorem provable by rewriting the program into one that trivially never crashes." The mitigation: "we penalized any patch and offered extra credit for proving which inputs it changes and how few they are." Also: "We also logged and audited the patches for these failure modes." |
| Limits of proof | "“Formally verified” does not mean “bug-free.”" "a proof checker can't tell you whether your spec matches reality." "When bugs show up in verified code, it's because the spec, or the assumed semantics of the machine, differs from reality." |
| Trusted base | "The formal models of RISC-V and of Linux processes;", the exact theorem statements, and the Rocq checker. Footnote: "This technically also means we have to trust the hardware, OS, OCaml compiler that the Rocq proof checker relies on." |
| Proof reuse | "When given access to this shared workspace, agents needed 17% fewer tokens than when they worked alone". Mathlib is cited as the model for this kind of reuse. |
| Cost | "the proofs can take hundreds of millions of tokens to produce." |
| Model progress | On 36 small tasks, Opus 5.5 proved half of them using about 40% fewer tokens than Opus 5 (paraphrase of the article). |
| Bugs found | Hundreds of bugs. Examples include a counter underflow that needs about 20 MB of input, an out-of-bounds read that needs a 64 MB input, and CVE-2026-56132 in libexpat. The article notes that fuzzers usually cap inputs at about 1 MB. |
| zlib case | Claude wrote a formal spec of RFC 1950, then proved "that the zlib implementation in the Linux kernel correctly implements that spec". This was done at the x86 binary level with Claude-generated x86 semantics, then repeated for "half a dozen" other libraries. |
| Verus case | A Rust interpreter for a Python subset, verified in Verus. In "over 1.7 million randomly generated Python programs", its behavior was "identical ... with CPython in 99.95% of tests". |
| Lean / TLA+ | Lean appears only as the home of Mathlib ("a shared library of formal mathematics in Lean"). TLA+ does not appear. |
| Released artifacts | [oss-verify-proofs](https://github.com/theorem-labs/oss-verify-proofs), [rocq-linux-process-semantics](https://github.com/theorem-labs/rocq-linux-process-semantics), the [OSS Verify skill](https://github.com/theorem-labs/oss-verify/blob/main/.claude/skills/add-project/SKILL.md), and [theorem.dev/oss-verify](https://theorem.dev/oss-verify/). |
| Conclusion | Developers should try LLM-assisted verification, starting with their most critical dependencies. Anthropic expects verification to become "an essential part of secure software development." |

### Corrections to the brief

* **Verus / 1.7M:** the article reports agreement with CPython on **99.95%** of 1.7M random programs.
  It is not a clean pass, and the article frames it as a measure of spec fidelity.
* **zlib:** the code verified was the **Linux kernel's** zlib, against an RFC 1950 spec. The x86
  semantics were generated by Claude, which enlarges the trusted base.
* **Single-threaded assumption:** the brief does not mention it, but it is central to this project.
  It is the main reason to add TLA+.
* **Theorem's skill:** it exists, but it is an *enrollment* skill for submitting a project to
  Theorem, not a proof skill (§3).

---

## 2. Tools

### 2.1 Local environment (checked)

* `lean`: **4.26.0**. `lake`: **5.0.0-src+v4.26.0**. Both come from the nix profile
  (`/nix/store/…-lean4-4.26.0`). `elan` is **not** installed.
* `java`: OpenJDK **17.0.12** (Zulu).
* `tlc`, `tla2tools.jar` and `apalache-mc` are not installed.
* The nix-profile `cc` (gcc) could not link ASan. `/usr/bin/clang` (Apple) could.
* The repository has no `flake.nix`, `.envrc` or `mise.toml` yet.

### 2.2 Lean routes to C code

| Option | What it is | Maturity, from its repo | Fit for SDL |
|---|---|---|---|
| **(a) Lean reference model + differential testing** | Write the algorithm in Lean, prove properties, then compare it with the C code on many inputs. For SAT-friendly fixed-width goals, use `bv_decide`. | The tactic ships with Lean itself. In the v4.26.0 source, `src/lean/Init/Tactics.lean:1793` says: "`bv_decide` uses `ofReduceBool` and thus trusts the correctness of the code generator." | **Best option today.** The proofs are about the model, not the C code. To connect them to the C, use differential testing, as the article's Verus case did. |
| (a′) Lean FFI to call the C code directly | `@[extern]` binds a Lean declaration to a C symbol ([Lean reference, FFI](https://lean-lang.org/doc/reference/latest/Run-Time-Code/Foreign-Function-Interface/)). | The reference says: "The current interface was designed for internal use in Lean and should be considered unstable." Passing structs by value is not supported. | Workable for scalar APIs such as `SDL_StepUTF8`. For anything else, a C harness that reads JSON and is driven by a Lean or Python test generator is simpler. |
| **(b) Clift** (C to Lean, AutoCorres-style) | [eisbaw/Clift](https://github.com/eisbaw/Clift): runs `clang -ast-dump=json`, imports to CSimpl, then lifts the result through five stages (L1–L5). | Its About line reads "WIP! Parse and lift C code to LEAN 4, AutoCorres2-inspired". README: "17 sorry remaining in example proofs". Created 2026-04-10, last push 2026-04-15, 1 star (GitHub API). It pins `leanprover/lean4:v4.30.0-rc1`, which differs from the local 4.26.0. It handles the StrictC subset only: no floating point, no `goto`, and no taking the address of locals. | **Experimental.** It might handle small integer-only leaf functions (`StepUTF8`, integer rect, `utf8strlcpy`) if you pin it to a commit. Not usable for float rect, or for code that takes the address of locals (`SDL_StepUTF8(&p, …)` callers). Treat its soundness as unverified. Its "proving False failed" checks are a smoke test, not evidence of soundness. |
| (c1) **LNSym** (Armv8 binaries) | [leanprover/LNSym](https://github.com/leanprover/LNSym): "Armv8 Native Code Symbolic Simulator in Lean". | 120 stars, last push 2026-07-08, but `lean-toolchain` = `leanprover/lean4:nightly-2024-10-07`. No releases. It is aimed at AWS-LC crypto kernels. | AArch64 matches Apple Silicon, but LNSym loads ELF, not Mach-O. It is a research tool for small straight-line kernels, not for parsers with loops and allocation. **Not realistic for SDL now.** |
| (c2) **sail-riscv Lean** | [riscv/sail-riscv](https://github.com/riscv/sail-riscv): Sail can emit Lean definitions. The repo contains a `lean_emulator` that "is experimental". | The README gives no maturity statement for the Lean model. It is validated only by running `riscv-tests`. There is no Linux-process or syscall model, which is the part Theorem built for Rocq. | **Not realistic.** It would mean rebuilding Theorem's whole stack in Lean. If binary-level no-crash proofs are wanted, Theorem's Rocq stack is the existing path (§3). |

Conclusion: in Lean, do **(a)** for everything. Run **(b)** only as a time-boxed experiment on one or
two leaf functions. Do not attempt **(c)** at all.

### 2.3 TLA+ and trace validation

* **TLC.** The latest tagged release of [tlaplus/tlaplus](https://github.com/tlaplus/tlaplus/releases)
  is `v1.7.4` (2024-08-05), which ships `tla2tools.jar`. I did not check whether the project now
  recommends its rolling nightly builds over that tag.
* **Apalache.** The latest is [`v0.62.4`](https://github.com/apalache-mc/apalache/releases) (2026-10-12).
  It is a symbolic (SMT) checker, useful for bounded checks with large integer domains. I did not
  verify its JVM requirement.
* **Trace validation.** [Cirstea, Kuppe, Loillier, Merz, arXiv:2404.16075](https://arxiv.org/abs/2404.16075)
  (v2, Sept 2024) turns trace validation into constrained model checking with **TLC**. The
  implementation logs only updates to specification variables. Its instrumentation API is for
  **Java**. The authors report finding spec/implementation discrepancies in every system they
  tried.
* **The same approach on C/C++:** [Howard, Kuppe et al., "Smart Casual Verification of CCF", NSDI '25](https://www.usenix.org/conference/nsdi25/presentation/howard)
  ([arXiv:2406.17455](https://arxiv.org/abs/2406.17455)) used traces from CCF's existing C++ tests
  and ran the validation in CI. The paper names mismatched grains of atomicity between the trace
  and the spec as the main difficulty.
* **Helper modules.** [tlaplus/CommunityModules](https://github.com/tlaplus/CommunityModules) provides
  `Json`, `IOUtils` and `TLCExt` ("Assertion operators and experimental TLC features"). I did not
  verify the exact operator names for NDJSON trace loading.

**Applicability to SDL.** This is a good fit. SDL's primitives are small, and SDL already has
multithreaded test programs that could produce traces: `test/testsem.c`, `test/testlock.c`,
`test/testrwlock.c`, `test/testatomic.c`, `test/testtimer.c` and `test/testthread.c`. The
instrumentation would be a `VERIF_TRACE(...)` macro that compiles to nothing by default. It would
append NDJSON records under a global lock, or with a per-thread buffer and a sequence number taken
from an atomic counter, so records can be merged in order.

The main risk is the same one CCF hit. The C code's atomic steps are finer than the spec's actions,
for example `num_waiting++` inside a semaphore-protected region. Log only at points where the
spec's action actually takes effect.

Trace validation shows that **observed** behaviors are allowed by the spec. It does not show that
**all** behaviors are, so it narrows the spec-to-reality gap without closing it. On weakly ordered
hardware, TLA+ models with interleaving semantics also say nothing about C11 memory-model effects.

---

## 3. Where SDL starts

* **No OSS-Fuzz project (confirmed).** The GitHub API returns 404 for
  `google/oss-fuzz/contents/projects/{sdl,sdl2,sdl3}`. The same query returns the directory listing
  for `projects/zlib`.
* **No libFuzzer harnesses (confirmed).** `grep -r LLVMFuzzerTestOneInput` finds nothing.
  `src/test/SDL_test_fuzzer.c:24` describes itself as "Data generators for fuzzing test data in a
  reproducible way". It is a seeded random-value helper for `testautomation`, not a coverage-guided
  fuzzer.
* **Existing oracles.** These are the closest thing to the article's "tests → spec" starting point:
  * `test/testautomation_rect.c` (2420 lines; overflow cases at `:203-212`)
  * `test/testautomation_pixels.c`
  * `test/testautomation_surface.c` (BMP)
  * `test/testautomation_joystick.c` (mappings)

  No testautomation file calls `SDL_StepUTF8` or `SDL_utf8strlcpy`.
* **OSS Verify.** According to [theorem-labs/oss-verify](https://github.com/theorem-labs/oss-verify),
  a project does **not** need to be in OSS-Fuzz. It needs "at least one fuzz target: its own, its
  OSS-Fuzz fuzz targets, or new ones", and the theorem is "that no input makes a fuzz target crash,
  hang or fail a sanitizer check". However, enrollment must be done by **a core maintainer**, and
  Theorem runs the proofs.
* **The OSS Verify skill** ([SKILL.md](https://github.com/theorem-labs/oss-verify/blob/main/.claude/skills/add-project/SKILL.md))
  covers enrollment and harness-writing. It targets "a formal model of a riscv64 Linux process".
  It requires:
  * harness properties checked with `abort()`, not `assert()` ("Many builds define `NDEBUG`")
  * a coverage witness and a mutant ("breakage") for each property
  * harnesses that start no threads, read no clocks, and use no network or signal handlers

  It warns: "A proof is only as strong as its fuzz target. A weak fuzz target makes the theorems
  vacuous."
* **What this means here:** SDL cannot be enrolled from a fork, and upstream policy rules out a
  maintainer-driven, AI-assisted enrollment. The harness rules are still a good standard for any
  `verification/fuzz/` harnesses written here. Those harnesses would also serve as the "spec" for
  the Lean models and the differential tests.

---

## 4. Ranking method

Candidates are scored on two things:

* **Risk:** whether the code is reachable from untrusted input or from multithreaded use, and how
  subtle it is.
* **Tractability:** how big the model or proof is, whether an oracle or test already exists, and
  whether it is in the fragment the tools handle.

---

## 5. TLA+ candidates, ranked

### T1. Event-wait / wakeup protocol (high risk, high tractability)

**Code:**
* `src/events/SDL_events.c:1631` `SDL_WaitEventTimeout_Device`
  * empty `SDL_PeepEvents` at `:1646`
  * then `SDL_SetAtomicPointer(&_this->wakeup_window, wakeup_window)` at `:1671`
  * then a blocking `_this->WaitEventTimeout` at `:1672`
* The producer side: `SDL_PeepEventsInternal` (`:1185`) calls `SDL_SendWakeupEvent` (`:1166-1182`)
  after it unlocks, and that function atomically takes `wakeup_window` (`:1177`).

**Hypothesis (lost wakeup):** The bad interleaving is:
1. The waiter's Peep finds the queue empty.
2. Another thread pushes an event. `wakeup_window` is still NULL, so no OS wakeup is sent.
3. The waiter publishes `wakeup_window` and blocks in the OS wait.

With `timeoutNS == -1` and no polling interval, the queued event then waits for some unrelated OS
event. Nothing re-checks the queue between `:1646` and `:1672`.

This is a textbook check-then-block race. A model with two to three threads would find it, or
refute it, in seconds. The backend `WaitEventTimeout` implementations (X11, Wayland, Cocoa, Win32)
might happen to mitigate it, and I did not check that. Model the backend wait as "blocks until an
OS event or a `SendWakeupEvent`".

**Properties:**
* Safety: the queue invariants listed below.
* Liveness under weak fairness: `[](QueueNonEmpty /\ WaiterBlocked => <>WaiterReturns)`.

**Also model:**
* the sentinel accounting invariant `SDL_sentinel_pending = #sentinels in queue`
  (`:1107`, `:1157`, `:1237`)
* the head/tail/free-list invariants of `SDL_AddEvent` and `SDL_CutEvent` (`:1080`, `:1136`)
* the shutdown race: `SDL_StopEventLoop` (`:993`) sets `SDL_EventQ.lock = NULL`, then unlocks and
  destroys the mutex (`:1038-1041`). A concurrent caller that already loaded the old pointer would
  then block on a freed mutex. This may be outside the API contract. Model it and record whether
  the documentation forbids the situation.

**Trace source:** `testautomation_events.c`, plus a small custom test that pushes from a second
thread while the main thread calls `SDL_WaitEvent`.

### T2. Audio device lifetime: hash lookup, refcount, disconnect (high risk, medium tractability)

**Code:**
* `src/audio/SDL_audio.c:481` `ObtainPhysicalAudioDevice` (physical-ID path)
  * finds the device in the hash under the subsystem read lock (`:490-492`)
  * **releases the lock** (`:493`)
  * only then calls `RefPhysicalAudioDevice` through `ObtainPhysicalAudioDeviceObj` (`:410-415`)
* By contrast, the logical path refs the device *while it still holds* the rwlock (`:447`).
* Teardown: `UnrefPhysicalAudioDevice` (`:628-639`). When the count reaches 0, it takes the write
  lock, removes the device from the hash, and calls `DestroyPhysicalAudioDevice` (`:596`), which
  frees it.
* The device's base reference is taken at creation (`:718`, "unref'd on device disconnect"). It is
  dropped on the main thread (`:792`, `:855-861`) after `SDL_AudioDeviceDisconnected` (`:864`) is
  called from a backend thread.

**Hypothesis (find-then-ref window):** An app thread calls a physical-ID API, for example
`SDL_GetAudioDeviceFormat` (`:1669`, which goes through `…DefaultAllowed`). Concurrently, the main
thread processes a disconnect of a non-default device. The app thread could then ref and lock freed
memory.

The safety property is: no `Ref` or `Lock` is applied to a device whose state is `freed`.

The model needs the following:
* rwlock (readers and writer)
* hash membership
* atomic refcount
* the per-device mutex
* the main-thread disconnect job
* the "default device migrates" retry loop (`:451-467`)

**Also:** a lock-order deadlock-freedom check. The comment at `:452` explains that the subsystem
rwlock is released before the device lock is taken, to avoid deadlock. TLC can check that ordering
directly.

**Trace source:** `test/testaudiohotplug.c`, and `testautomation_audio.c` with the dummy or disk
driver.

### T3. Generic condition variable built from semaphores (medium risk, very high tractability)

**Code:** `src/thread/generic/SDL_syscond.c`:
* Signal `:90-111`
* Broadcast `:114-143`
* Wait/timeout `:166-209`

This is the BeOS-derived "handshake" algorithm. It is the **only** condition variable on Vita, PSP,
PS2, N3DS and DOS, and the fallback on Windows when the CV APIs are missing
(`CMakeLists.txt:2600,3271,3428,3502,3572,3651`; `src/thread/windows/SDL_syscond_cv.c:173-189`).

**Properties:**
* `num_signals <= num_waiting`
* no lost signal: a signal issued while a waiter is blocked releases at least one waiter that was
  blocked at that point
* no deadlock between Signal's `handshake_sem` wait and a waiter that **timed out**

**Specific question:** a waiter times out at `:188`, and a signaler then increments `num_signals`
and posts `sem` before the waiter re-enters `:196`. The waiter then posts `handshake`, so the
signaler is not stuck. However, `sem` keeps a stale count, which causes a later spurious wakeup.
Spurious wakeups are allowed for condition variables, but check whether the **count can grow
without bound**, using a state-constraint counterexample.

This model is about 60 lines of PlusCal. It is the best first model for learning the toolchain.

**Companions:**
* **Generic semaphore** `src/thread/generic/SDL_syssem.c` (wait `:106-154`, signal `:169-181`).
  This one matters on the user's own machine: `src/thread/pthread/SDL_syssem.c:31-33` uses the
  generic semaphore on macOS and iOS. `SDL_DestroySemaphore` (`:88-104`) reads `waiters_count`
  without a lock. That is documented as "cannot call … when another thread is using the semaphore".
* **Generic rwlock** `SDL_sysrwlock.c:95-200`. Check mutual exclusion, and show writer starvation
  as a liveness counterexample. Starvation is probably acceptable, but it should be documented.

### T4. `SDL_InitState` (medium risk, very high tractability)

**Code:** `src/thread/SDL_thread.c:556` (`SDL_ShouldInit`), `:570` (`SDL_ShouldQuit`) and `:584`
(`SDL_SetInitialized`). The states are declared at `include/SDL3/SDL_mutex.h:975-981`. It is used in
about 8 places, including `SDL_pixels.c:791`, `SDL_properties.c:109`, `SDL_log.c:150` and the dbus
code.

**Properties:**
* at most one thread is in `INITIALIZING` or `UNINITIALIZING`
* a failed init (`SetInitialized(false)`) lets waiters retry
* liveness, assuming the initializing thread eventually calls `SetInitialized`

**Known limit worth stating in the spec:** the pattern serializes transitions, but it does **not**
keep users from racing with quit. One example: `SDL_GetPixelFormatDetails` reads
`SDL_format_details` after `ShouldInit` returns false (`SDL_pixels.c:800`), while
`SDL_QuitPixelFormatDetails` (`:829-833`) destroys it.

Also, a reentrant `ShouldInit` on the same state from the initializing thread spins forever
(`:557-566`).

These cases are safe only if the API contract excludes them. That is a spec-reality question, not a
proof question.

### T5 (lower priority). Timer thread

**Code:** `src/timer/SDL_timer.c`:
* thread loop `:100`
* cancel check `:162`
* `SDL_CreateTimer` freelist reuse `:313-323`
* `SDL_RemoveTimer` `:371-411`

**What to model:** pending and free-list handoff under a spinlock, timer reuse, and ID-map removal.

**Expected finding:** `SDL_RemoveTimer` returning true does **not** mean the callback will not run
again. The cancel flag is read at `:162`, then the callback runs. The docs
(`include/SDL3/SDL_timer.h:434-446`) promise nothing either way, so this is a documentation gap
rather than a bug.

**Lower priority** because the risk is mostly "callback runs once more" semantics.

**Not recommended for TLA+:**
* `src/atomic/SDL_spinlock.c` and `SDL_atomic.c`. Their correctness depends on the C11 / hardware
  memory model, which interleaving TLA+ cannot express. A memory-model checker such as GenMC is
  the right tool, and I did not evaluate one.
* `SDL_audioqueue.c` and `SDL_audiocvt.c`. Streams take `stream->lock` around every public
  operation (`SDL_audiocvt.c:482…1503`), so the data structure is effectively sequential. These
  are Lean/C targets, not TLA+ targets.

---

## 6. Lean candidates, ranked

Approach key: **(a)** Lean model, proofs and differential testing; **(b)** Clift lifting;
**(c)** binary-level.

### L1. UTF-8: `StepUTF8` / `SDL_StepUTF8` / `SDL_StepBackUTF8` / `SDL_utf8strlcpy`. Approach (a), optionally a (b) experiment.

**Code:** `src/stdlib/SDL_string.c`:
* `StepUTF8` `:192`
* `SDL_StepUTF8` `:259`
* `SDL_StepBackUTF8` `:270`
* `SDL_utf8strlcpy` `:1045`

**Spec:** RFC 3629's table (quoted in the code at `:194-205`) and the header contract at
`include/SDL3/SDL_stdinc.h:4204-4247`.

**Findings, confirmed on a standalone copy of `StepUTF8` (`:192-257`) compiled with Apple clang
and `-fsanitize=address`:**
1. **Codepoints above U+10FFFF are accepted.** Input `F5 80 80 80` returns `0x140000`. The
   four-byte branch (`:238-252`) checks only `result >= 0x10000` (`:247`), and its lead-byte mask
   `(octet & 0xF8) == 0xF0` accepts F5–F7. RFC 3629 bans these values, and the header cites RFC
   3629.
2. **Read past the NUL when `pslen == NULL`.** In that case `SDL_StepUTF8` passes `slen = 4`
   (`:262`). The three-byte and four-byte branches read `str[1..3]` unconditionally (`:225-226`,
   `:239-241`) before they check continuation bytes. The input `"\xF0"` followed by a NUL at the
   end of a 2-byte heap allocation gives an **ASan heap-buffer-overflow READ** at the `str[2]`
   load.

   The header says the function "will blindly read until it sees the NULL char", which implies it
   stops at the NUL. It does not.

   Not yet checked: which of the 7 in-tree `SDL_StepUTF8(…, NULL)` callers could reach the end of
   an allocation.

**Lean statements:**
* the decoder is equal to an RFC 3629 grammar decoder
* `decode` never reads index ≥ the minimum of `slen` and (the NUL index + 1)
* decode/encode round-trips for valid scalar values
* `utf8strlcpy` output:
  * is a prefix of `src`
  * has length ≤ `dst_bytes - 1`
  * never ends inside a multi-byte sequence when the input is valid

**Proof tool:** `bv_decide` handles the bit-twiddling cases outright.

**Linking proof to C:** run all 2^32 four-byte windows, or a stratified sample, through the C code
and the Lean model and compare the results.

### L2. Integer rect math. Approach (a), with (b) worth trying because `int` is in Clift's subset.

**Code:** `src/video/SDL_rect_impl.h`, instantiated as `int`/`Sint64` and as `float`/`double`
(`src/video/SDL_rect.c:92-116`). The functions are:
* `SDL_HASINTERSECTION` `:37`
* `SDL_INTERSECTRECT` `:85`
* `SDL_UNIONRECT` `:137`
* `SDL_ENCLOSEPOINTS` `:196`
* `SDL_INTERSECTRECTANDLINE` `:313`

All of them gate on `SDL_RECT_CAN_OVERFLOW` (`:24-35`).

**Properties:**
* intersection and union are equal to set semantics over ℤ² whenever the inputs pass the overflow
  guard
* commutativity
* clipping returns a sub-segment that lies inside the rect
* **absence of signed overflow (C UB)**

**Places where the overflow guard does not cover the arithmetic (by reading; confirm with UBSan):**
* `SDL_ENCLOSEPOINTS` with `clip`: `clip->x + clip->w - 1` (`:218-219`) runs with no
  `SDL_RECT_CAN_OVERFLOW(clip)`.
* `SDL_ENCLOSEPOINTS`: `(maxx - minx) + 1` (`:290-291`) can overflow `int` when the points span
  roughly the whole 32-bit range.
* `SDL_INTERSECTRECTANDLINE`: checks the rect but not the line endpoints. `(BIGSCALARTYPE)(x2 - x1)`
  (`:414-448`) does the subtraction in `int` *before* widening, and `(y2 - y1)` is an `int` divisor.

The existing overflow test (`testautomation_rect.c:203-212`) uses endpoints at INT_MIN/INT_MAX
with a rect that *fails* the guard, so it never reaches that code.

**Floats:** the float instantiation needs an IEEE model. Lean core has `Float`, but proofs about it
are hard. Treat floats with differential testing only.

### L3. Gamepad mapping parser. Approach (a) for the grammar plus C harnesses; this is a good no-crash target.

**Code:** `src/joystick/SDL_gamepad.c`:
* `SDL_PrivateParseGamepadConfigString` `:1765-1811`
* `SDL_PrivateParseGamepadElement` `:1645`
* GUID/name/mapping extraction `:2009`, `:2046`, `:2073`

**Input sources:** `SDL_AddGamepadMapping`, mapping files, and the `SDL_GAMECONTROLLERCONFIG` hint
(`:2916`).

**Finding (off-by-one).** The length check is `if (i >= sizeof(szGameButton))` *before* each write
(`:1790-1794`). A 20-character element name therefore fills `szGameButton[20]` completely, with no
NUL. If a `:` comes next, the code switches to the joystick half, and the next `,` passes the
unterminated buffer to `SDL_PrivateParseGamepadElement`. That function calls
`SDL_GetGamepadAxisFromString(szGameButton)` and `SDL_PrivateGetGamepadButtonFromString` (`:1676-1677`).
`szJoystickButton[128]` has the same problem with 128 characters (`:1797-1801`).

**Confirmed** on an extract of `:1765-1811` with a `strlen` stand-in for the element parser. ASan
reports a **stack-buffer-overflow READ of size 21**. **Not yet** reproduced through the public API
on a real build.

**Spec:** a Lean grammar of the mapping string format, plus the property "the parser terminates and
every buffer handed to a string function is NUL-terminated within bounds".

### L4. BMP and WAV loaders. These are the article's pipeline; approach (a) only for header arithmetic.

**Code:**
* BMP: `SDL_LoadBMP_IO` (`src/video/SDL_bmp.c:210`) and `readRlePixels` (`:66`).
* WAV: `SDL_LoadWAV_IO` (`src/audio/SDL_wave.c:2088`), `WaveLoad` (`:1773`), `WaveCheckFormat`
  (`:1670`), `MS_ADPCM_Init` (`:376`), `IMA_ADPCM_Init` (`:789`) and `WaveReadPartialChunkData`
  (`:1538`).

These parse untrusted input and are exactly the kind of target the article handles: a libFuzzer
harness gives a property of the form "no crash, hang, or sanitizer report".

**Do here:**
1. Write the harnesses, following the OSS Verify rules in §3.
2. Run them under ASan and UBSan with libFuzzer.
3. In Lean, model and prove only the **size arithmetic**: header fields → `pitch × height`,
   block-align and sample-count computations, `SIZE_MAX` checks.

Note on the BMP RLE decoder: `readRlePixels` builds pointers outside the pixel buffer
(`bits -= pitch` at `:116` and `bits -= (ch * pitch)` at `:131`) and only checks `spot >= start`
before writing. At the machine level this is safe, so a binary-level proof would accept it. Under C
semantics, forming those pointers is UB, so a Clift-style C-semantics proof would reject it. This is
a concrete example of how the choice of verification level changes the trusted base.

Whole-loader proofs at type (b) or (c) are not realistic with today's Lean tools.

### L5. Pixel formats, sample conversion, hash table. Approach (a) for each.

* **`SDL_pixels.c`:** the format and masks bijection (`SDL_GetMasksForPixelFormat` /
  `SDL_GetPixelFormatForMasks`) and the `SDL_PIXELFORMAT` bit-field encode/decode. These are pure
  and finite, so exhaustive checking or `bv_decide` works.
  `testautomation_pixels.c` is the oracle.
* **`SDL_audiotypecvt.c`:** the integer-to-float scaling bounds and channel-conversion matrices.
  These involve floats, so differential testing is the better fit.
* **`SDL_hashtable.c`:** Robin Hood open addressing (`insert_item` `:158`, comment at `:191`,
  `delete_item` `:218`, `resize` `:248`, `MAX_HASHTABLE_SIZE` `:38`). Properties:
  * a probe-length invariant
  * after any sequence of operations, the table agrees with a finite map
  * no overflow of the index computations

  This is a medium-size Lean model. The same table is also reached concurrently via its optional
  rwlock (`:42`), but the lock is coarse, so it adds no value as a TLA+ target.
* **`SDL_iconv.c`:** a good target, but its large encoding table makes it lower priority than
  StepUTF8.

---

## 7. How the article's conclusions map onto this project

| Article conclusion | Applied to SDL |
|---|---|
| **Derive specs from tests.** | No fuzz targets exist, so write them first (BMP, WAV, mapping, UTF-8, rect). Mine `testautomation_*` for expected values. Each harness becomes both the no-crash spec and the differential-test driver for the Lean models. |
| **Generic properties (no-crash) scale.** | For parsers, aim for "no crash, hang or sanitizer report", as OSS Verify does. Keep functional specs for small pure code (UTF-8, rect, pixels). For concurrency, the matching generic properties are deadlock freedom, no use-after-free on objects with a refcount or lifecycle, and no lost wakeups. |
| **Spec gaming: "Claude could make any theorem provable by rewriting the program…"** | Rules: <ul><li>Never edit `src/` in the same change as a proof.</li><li>Proofs refer to a pinned SDL commit.</li><li>Any C change needed to make a proof go through goes in its own reviewed patch, which states the inputs whose behavior changes.</li><li>Use OSS Verify's rule that every property needs a coverage witness and a mutant that breaks it.</li><li>For TLA+, check for vacuity: every invariant must be violated by at least one seeded mutant spec, and every action must be enabled in some reachable state (TLC coverage).</li></ul> |
| **"Formally verified" ≠ bug-free; the spec-to-reality gap.** | The Lean model is not the C code, and the TLA+ spec is not the C code. Close the gap with:<ul><li>(1) differential testing between the Lean model and the C, as in the article's Verus case</li><li>(2) TLA+ trace validation from instrumented SDL test runs</li><li>(3) writing each spec against the **header documentation**, so spec-to-doc mismatches show up (the StepUTF8 NUL-read case)</li></ul> |
| **The trusted base must be explicit.** | Record it in each spec's README:<ul><li>Lean kernel 4.26.0</li><li>`bv_decide` adds the code generator, via `ofReduceBool`, and the SAT/LRAT path</li><li>TLC version and the model's bounds (thread count, queue length)</li><li>the abstraction of the OS/backend (e.g., "backend `WaitEventTimeout` wakes on `SendWakeupEvent`")</li><li>the compiler, for differential tests</li><li>the C memory model being ignored (sequentially consistent interleaving assumed)</li></ul> |
| **Proof reuse cut tokens by about 17%.** | Keep one Lean library (`SDLVerif`) with shared bit-vector lemmas, an RFC 3629 model and a rect algebra. Keep one TLA+ module library with `Mutex`, `Semaphore`, `AtomicRef` and `RWLock` operators. Each new spec composes these instead of starting from scratch. |
| **Cost: "hundreds of millions of tokens".** | That figure is for binary-level proofs. The model-level work proposed here is orders of magnitude cheaper, and it covers concurrency, which the article's binary proofs exclude. If binary-level no-crash proofs are wanted later, Theorem's Rocq stack is the existing route. It needs maintainer enrollment, and the trust profile is different. |
| **Start with the most critical dependencies.** | For SDL, that means untrusted-input parsers and the cross-thread protocols that every application uses: event wait, audio hotplug, and init/quit. |

---

## 8. Upstream policy constraints

From upstream [`AGENTS.md`](https://github.com/libsdl-org/SDL/blob/main/AGENTS.md): "Generative AI,
including large language models (LLMs), should not be used in any way when contributing to SDL." It
also says AI-generated comments and code must not be submitted in bug reports or pull requests, and
PR authors must confirm they wrote their changes and license them under zlib. The fork's
`CLAUDE.md:5-11` repeats this.

What follows from the policy:
* All specs, proofs, harnesses and trace instrumentation stay in the fork, under `verification/`.
  Nothing from this work goes into an upstream PR.
* A finding such as §6 L1, L3 or §5 T1 is upstream-relevant only after **a human** reproduces it on
  a real build, understands it, and writes the report and any fix **in their own words**. No
  AI-written text, patch, or proof should be attached. Whether a human-written report of an
  AI-assisted finding meets the policy is for that human to judge against its wording ("should not
  be used in any way"). This document does not resolve it.
* Keep `verification/` isolated so `src/` stays mergeable with upstream:
  * no edits to `src/`
  * trace macros live in a `verification/instrument/` overlay header, injected with a CMake option
    or `-include` only in fork builds
* Theorem's OSS Verify is closed to the fork: it needs a core maintainer, and its findings are
  AI-generated.

---

## 9. Suggested layout and version pinning

> **Update (same day):** the repo `flake.nix` now provides `tlaplus` 1.7.4 (`tlc`, checked with
> `nix develop`) and `elan`, so `verification/lean/lean-toolchain` is enforced rather than just
> documenting the version. Apalache was not found in nixpkgs. The pinning notes below predate
> this change.

```
verification/
  RESEARCH.md            # this file
  PLAN.md                # (user)
  TRUSTED_BASE.md        # tool versions, assumptions, model bounds — one table
  tla/
    common/              # Mutex.tla, Semaphore.tla, RWLock.tla, AtomicRef.tla
    initstate/           # InitState.tla + MC.cfg
    cond_generic/        # GenericCond.tla (PlusCal) + MC.cfg
    events_wait/         # EventWait.tla, Trace.tla, MC.cfg
    audio_device/        # AudioDevice.tla
    traces/              # NDJSON from instrumented runs (gitignored or small fixtures)
  lean/                  # lake project
    lakefile.toml
    lean-toolchain       # leanprover/lean4:v4.26.0 (match the nix-provided lean)
    SDLVerif/Utf8.lean, Rect.lean, GamepadMapping.lean, Common/BitVec.lean
    test/                # differential drivers (JSON in/out)
  harness/               # C: libFuzzer targets + differential shims linking libSDL3
  instrument/            # VERIF_TRACE macros, compiled out unless -DSDL_VERIF_TRACE
```

**Pinning** (fits the user's convention that `.envrc` contains only `use flake` and environment
variables live in `mise.toml [env]`):
* **Lean.** Add a repo `flake.nix` dev shell that provides `lean4`, pinned through `flake.lock`.
  Write the same version into `verification/lean/lean-toolchain`. Without elan, that file is only
  documentation, so add a CI check that `lean --version` matches it.
  If Clift is tried, it needs `v4.30.0-rc1`. Either give it its own nix input or install elan in
  that shell only. Do not move the main project.
* **TLA+.** Pin `tla2tools.jar` by version and sha256 as a fixed-output derivation in the flake.
  Java 17 is already present. I did not check whether nixpkgs packages `tlaplus` or `apalache`, or
  at which versions; check with `nix search` before writing your own derivation.
  Apalache: pin `v0.62.4` from its release tarball, verified against the release's `sha256sum.txt`.
* **mise.** Use it only for `[env]` values, e.g. `TLA2TOOLS_JAR`, `SDL_VERIF_TRACE_DIR`.
* **Sanitizers.** The nix gcc could not link ASan here, and Apple clang could. The flake shell
  should provide an LLVM clang with compiler-rt for libFuzzer and ASan/UBSan.

---

## 10. Reproduction notes for the confirmed items

The extracts live in the session scratchpad, not in the repo:
* `utf8.c` includes `SDL_string.c:192-257` verbatim.
* `gp.c` includes `SDL_gamepad.c:1765-1811` verbatim, with a stub `SDL_PrivateParseGamepadElement`
  that calls `strlen` on both arguments.

Commands:
* `/usr/bin/clang -g -fsanitize=address utf8.c && ./a.out` reports a heap-buffer-overflow READ in
  `StepUTF8`.
* The same program without ASan prints `F5 80 80 80 -> 0x140000`.
* `gp.c` under ASan reports a stack-buffer-overflow READ of size 21 for the input
  `"abcdefghijklmnopqrst:b0,"`.

To redo these on a real build: build SDL with `-fsanitize=address,undefined`, then
* call `SDL_StepUTF8(&p, NULL)` on `malloc`'d `"\xF0"` (with its NUL)
* call `SDL_AddGamepadMapping()` with a valid GUID and name and a 20-character element name
  followed by `:b0`, then open a matching virtual joystick (`SDL_AttachVirtualJoystick`) so the
  mapping string is parsed

---

## 11. Open questions

1. **T1 lost wakeup.** Do the backend `WaitEventTimeout` implementations (Cocoa, X11, Wayland,
   Win32) re-check SDL's queue, or rely on an OS primitive that latches a wakeup posted before the
   wait, such as a pipe or eventfd? The answer decides between "real bug" and "benign, document the
   assumption". Read the backends before modeling.
2. **T2 audio.** Can the base reference of a non-default device actually drop to 0 while an app
   thread is between `:493` and `:413`? Other references, such as an open logical device or a
   pending disconnect job, may keep it alive in practice.
3. **Contracts.** Is calling `SDL_Quit*` concurrently with use (T4, `SDL_StopEventLoop`) outside the
   documented contract? Where is that written? Specs should encode the contract, not guesses.
4. **Clift.** Is it worth one time-boxed experiment on `StepUTF8`, given the toolchain mismatch
   (`v4.30.0-rc1`) and its WIP status? Would a lifted proof add anything over differential testing
   of a Lean model?
5. **Theorem's semantics.** Are `rocq-linux-process-semantics` and `oss-verify-proofs` usable
   *without* Theorem's service, to run binary-level no-crash proofs locally on SDL's leaf parsers?
   I did not read those repos' READMEs or licenses.
6. **Appendix.** I did not read the article's appendix PDF. It may contain spec-gaming metrics or
   method details that matter for §7.
7. **Reporting.** For findings that hold up, does the user want to report them upstream personally,
   given §8? If so, the human-reproduction step in §10 comes first.
8. **Tool versions.** Should the project pin TLA+ to the tagged `v1.7.4` or to a dated nightly? Does
   nixpkgs provide either?
