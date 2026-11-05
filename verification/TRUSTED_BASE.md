# Trusted base

A result in `verification/` is only as good as what it assumes. This file lists those assumptions.
Update it whenever a tool version, pinned commit or model bound changes.

## Pinned code

| Item | Value |
|---|---|
| SDL source the models describe | `cb6224d2e` (fork). Its `src/` is identical to upstream `87f0e4a25`; the fork only changed docs and tooling. |
| Re-check needed when | any file named in a spec header changes upstream. |

## Tools

| Tool | Version | Source | Notes |
|---|---|---|---|
| TLC | 2.19 (08 Aug 2024, rev 5a47802) | nixpkgs `tlaplus` 1.7.4, via `flake.lock` (nixpkgs `9d3b8db`, 2026-11-03) | Runs on the Azul JDK 1.8 x86_64 build that the package bundles. On Apple Silicon this runs under Rosetta. |
| Lean | 4.35.0 | `elan` (nixpkgs 4.2.4), pinned by `verification/lean/lean-toolchain` | No Mathlib. Proofs use `bv_decide` from core `Std`, whose SAT/LRAT certificates are checked natively and enter the proof as auxiliary axioms `*._native.bv_decide.ax_*`. That puts the Lean compiler and the bundled CaDiCaL/LRAT checker in the trusted base. `mise run lean` rejects any other axiom, including `sorryAx`. |
| C compiler (models, differential tests) | nixpkgs clang 21.1.8 | `clangStdenv` | Used for `build/`, which the differential tests link against. |
| C compiler (sanitizers) | Apple clang 21.0.0 (clang-2100.4.1.1) | Xcode | On macOS 27 the nix clang 21 ASan runtime hangs at startup, even for a hello world, so `mise run asan:build` uses `/usr/bin/clang` with `DEVELOPER_DIR` and `SDKROOT` reset. |

## Modelling assumptions (all TLA+ specs)

- **Sequentially consistent interleaving.** Each modelled step is atomic, and steps from different
  threads interleave arbitrarily. SDL's `SDL_AtomicInt` operations are sequentially consistent on
  all backends. Plain (non-atomic) fields are modelled only where they are accessed under a lock
  or by a single owner.
- **Fair scheduling.** The specs use weak fairness (InitState) or strong fairness
  (GenericCond) per thread. That means a thread that can run eventually runs, and blocked
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

## Lean models

| Model | What is trusted | What ties it to the C |
|---|---|---|
| `lean/SDLVerif/Utf8.lean` `cStep` | that the transcription matches `StepUTF8` (`SDL_string.c:192-257`), with C integer widths as `BitVec`. The `reads` field is our accounting of dereferences. | the differential test against the real `SDL_StepUTF8` (3,096,576 cases, `mise run lean:diff`) and the ASan reproductions (`mise run repro`). The differential test checks `cp` and `adv`. It does not check `reads`, which ASan covers. |
| `wfLen` / `decodeVal` | that they transcribe RFC 3629 §4 and §3 | written from the RFC grammar, independently of SDL's bit tests. The `spec_f4_allows_9x` mutant shows the theorems depend on it. |

## Abstractions

- `tla/cond_generic`: the three internal `SDL_Semaphore`s are atomic counting semaphores. That is
  true on the platforms where this code runs (native kernel semaphores on Vita, PSP, PS2, 3DS and
  DOS, and Win32 semaphores in the Windows fallback). A timeout is a nondeterministic choice, not
  a clock.
