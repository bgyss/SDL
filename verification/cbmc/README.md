# CBMC pilot: bounded model checking of `src/stdlib/`

The Lean models in `verification/lean/` prove properties of hand transcriptions of the C, and
differential tests tie the transcriptions back to the code. CBMC skips the transcription. It
compiles the C itself (`goto-cc`), unrolls every loop up to a bound, and asks a SAT solver
whether any input within the bounds can break a memory-safety check, cause undefined behaviour
or fail an assertion. Within its bounds the answer covers every input, not a sample. Outside them
it says nothing. `--unwinding-assertions` makes a loop that would run past its bound a failure
in its own right, so a bound that is too small shows up as a failure instead of a silent cut.

This pilot targets SDL's own C library, `src/stdlib/`. The code is small, pure and used
everywhere, and the UTF-8 functions already have Lean models and fuzz harnesses to compare
against.

```sh
mise run cbmc                      # every harness, on the current tree, the base tree and the mutants
mise run cbmc -- strtol ltoa       # just these harnesses (and their mutants)
```

`cbmc` comes from the dev shell (`flake.nix`, nixpkgs `cbmc`). Logs go to `build-cbmc/logs/`,
a summary to `build-cbmc/REPORT.md`.

## Layout

```
cbmc/
  run.sh                 builds and checks every harness, compares outcomes with EXPECT
  EXPECT                 the outcome each harness must have on the base and the fixed tree
  MUTANTS                seeded bugs (one sed expression each); each must make its harness fail
  include/               SDL_build_config.h: the minimal config, so no HAVE_* libc forwarding
  harness/cbmc_common.h  nondet buffers and strings; a reference UTF-8 decoder (Unicode Table 3-7)
  harness/<name>.c       one harness per function family
```

Each harness states its bounds in its header (`CBMC-BOUND`), along with the sources it links
(`CBMC-SOURCES`), the unwind bound (`CBMC-UNWIND`) and, optionally, calls it replaces with a
model (`CBMC-REPLACE: f:g`, applied with `goto-instrument --replace-calls`). The bound is part of
the claim:
"`strlcpy` passes" means "for every `src` shorter than 6 bytes, every buffer up to 6 bytes and
every `maxlen` up to the buffer".

### Three kinds of run

- **fixed** is this tree. Every harness must pass.
- **base** is `cb6224d2e`, the commit the findings were made on. It answers the question "would
  CBMC have found the bugs we already know about?" A harness that covers a finding must fail
  there, on the property that describes that finding.
- **mutant** applies each line of `MUTANTS` (a `sed -E` expression on one file) to a copy of
  this tree and runs the one harness it names. That harness must fail on the property the line's
  expectation names, and a line whose expression no longer changes the file is an error. As
  with the TLA+ mutants and the Lean proof mutants, this shows the property can fail at all.
  A property that is not killed by a base-tree finding needs a mutant.

### How SDL is compiled for CBMC

- `include/SDL_build_config.h` selects `SDL_build_config_minimal.h`, which defines no `HAVE_*`
  libc macros. Without it, `SDL_strlcpy` would compile to a call to the platform `strlcpy` and
  CBMC would check CBMC's own libc model. With it, the harnesses check the code SDL ships for
  libc-less builds. That code is also what every build uses for the functions that have no libc
  counterpart (`SDL_StepUTF8`, `SDL_utf8strlcpy`, `SDL_strcasecmp`, the hashes), for `SDL_ltoa`
  family on every platform, and for `SDL_strrev` everywhere but Windows.
- `-DSDL_DISABLE_NEON` and friends keep `SDL_intrin.h` from including compiler intrinsic headers
  that CBMC's C front end cannot parse.
- Harnesses include `SDL_internal.h` too, so the dynapi `_REAL` renames match on both sides.

### Checks

`--bounds-check --pointer-check --pointer-overflow-check --pointer-primitive-check
--signed-overflow-check --undefined-shift-check --div-by-zero-check --unwinding-assertions`.
Unsigned wrap-around is defined behaviour and SDL depends on it (`0ULL - value`), so
`--unsigned-overflow-check` and `--conversion-check` are off. CBMC does not check alignment or
strict aliasing, so murmur3's aligned `*(const Uint32 *)` read is not checked for those.

Memory: `utf8strlcpy` needs about 6 GB and several others a few GB, so `run.sh` runs two checks
at a time by default (`CBMC_JOBS=n` to change it). `CBMC_JOBS=1` is the safe choice when other
work is running.

## Results (2026-11-06, CBMC 6.11.0, Apple M-series, 64 GB)

Every harness passes on the current tree. Every harness that covers a finding fails on the base
tree, and all 11 mutants are killed. The suite was run in four batches (the full run does not fit
the agent session's 10-minute command limit); each batch matched `EXPECT`.

| Harness | Bound | Base tree `cb6224d2e` | Current tree |
|---|---|---|---|
| `strlcpy` | `src` < 6, buffer ≤ 6 | pass | pass |
| `strlcat` | `src` < 5, buffer ≤ 6 | pass | pass |
| `steputf8_len` | 0–5 arbitrary bytes, no terminator | **F-005**: disagrees with Table 3-7 | pass |
| `steputf8_null` | C string < 5 | **F-004**: reads `str[2]`, `str[3]` past the NUL | pass |
| `stepbackutf8` | 0–6 bytes, every position | **F-008** | pass, after **F-026** |
| `utf8strlcpy` | `src` < 6, buffer ≤ 6 | **F-007**: output not valid UTF-8 | pass |
| `strcasecmp` | strings < 4, folding modelled | **F-004** via `strcasecmp` | pass |
| `strtol` | string < 5, base 0 or 2–36 | **F-027** | pass, after F-027 |
| `ltoa` | every 64-bit `long`, radix 2 | **F-029**: `-LONG_MIN` | pass, after F-029 |
| `strrev` | string < 7 | **F-028**: `&string[-1]` | pass, after F-028 |
| `hashes` | `len` ≤ 9, offset 0–3 | pass | pass |

F-026 – F-029 were new (FINDINGS.md, "CBMC pilot"). F-026 is a gap in the F-008 fix that the
Lean theorem about that fix also missed, because the theorem exempted a result of 0.

## Open

- **`strtok_r`** (`harness/strtok_r.c`, commented out of `EXPECT`): CBMC grows past 10 GB within
  seconds of starting the SAT stage, even at `--unwind 3` and with either solver, and the run is
  killed. Not yet understood; the harness's tokens are pointers into `s` derived through
  `char **`, which may blow up CBMC's pointer encoding.
- **Larger bounds** for `strtol`: strings under 5 bytes never overflow, so the clamping to
  `LONG_MIN`/`LONG_MAX` is covered by `testautomation` but not here. A harness restricted to
  long digit strings would cover it.
- **`ltoa` in other radices**: radix 10 did not finish within the memory available.
- **Case folding tables**: `strcasecmp` replaces `SDL_CaseFoldUnicode` with a model; the tables
  are unchecked.
- **Widening** to `SDL_vsnprintf`, `SDL_iconv`, `SDL_qsort`, and the WAV/BMP header readers with
  stubbed I/O (PLAN.md).
