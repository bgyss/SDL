# Harnesses

Two kinds of program live here:
- reproductions of findings on a real build (`repro_leads.c`, `repro_wakeup.c`)
- the Phase 3 libFuzzer targets, whose properties are the "tests as specs" step of
  `PLAN.md`

Nothing here changes `src/` or the upstream CMake files.

## Reproductions

The reproduction suite of record is `../repro/` (`mise run repro:verify`). It covers every
finding, builds against both the pre-fix tree and the current tree, and checks expected
outcomes. The programs below are the earlier exploratory versions, kept for poking at one
case on `build-asan`.

| Command | What |
|---|---|
| `mise run repro` | builds `build-asan` (ASan + UBSan) and runs every `repro_leads` mode: F-004 (direct and via `SDL_strcasecmp`), F-005, F-006, F-009, F-013 |
| `mise run repro -- <mode>` | one mode; `repro_leads` with no arguments lists them |
| `mise run repro:wakeup -- [rounds] [max_delay_us]` | F-019 stress test: counts `SDL_WaitEventTimeout` calls that time out while the event is already queued |

## Fuzz targets

| Target | API | Seeds |
|---|---|---|
| `fuzz_utf8` | `SDL_StepUTF8` (with and without a length), `SDL_StepBackUTF8`, `SDL_utf8strlcpy`, `SDL_utf8strlen`/`strnlen`, `SDL_UCS4ToUTF8` | hand-written edge cases plus `testautomation_stdlib` text |
| `fuzz_iconv` | `SDL_iconv_string`, and streaming `SDL_iconv` through a 1–16-byte output buffer, for all 18 built-in encodings | pair/encoding examples |
| `fuzz_rect` | integer rect intersection, union, line clipping, enclosing points | `testautomation_rect`-style cases plus extremes |
| `fuzz_gamepad` | `SDL_AddGamepadMapping`, element parsing on open, `SDL_GetGamepadMapping*` | element lists and whole mappings in `SDL_gamepad_db.h` style |
| `fuzz_bmp` | `SDL_LoadBMP_IO` | `SDL_SaveBMP` output (8/24/32-bit, V4/V5 masks) plus hand-built 1-bit, 4-bit, RLE4, RLE8 |
| `fuzz_wav` | `SDL_LoadWAV_IO` | generated PCM u8/s16/s24/s32, float, A-law, µ-law, extensible, MS ADPCM, IMA ADPCM; heads of `test/*.wav` |

The properties each target checks, and the input-size bound N in "no report for inputs of at
most N bytes", are listed in `TRUSTED_BASE.md` under "Fuzz properties". Each target's header
comment explains its input layout.

### Running

```sh
mise run fuzz:build            # build-fuzz/: SDL + targets (Apple clang ASan/UBSan + nix libFuzzer)
verification/harness/fuzz.sh seeds   # regenerate the generated seeds in corpus/
mise run fuzz -- 300           # every target, 300 s each; new inputs go to build-fuzz/fuzz/work/
verification/harness/fuzz.sh run fuzz_wav 600
mise run fuzz:regress          # regression inputs + corpora (run after any change)
```

A crash or PROPERTY failure is written to `build-fuzz/fuzz/crashes/<target>/`. Replay it with
`fuzz.sh replay <target> <file>`, and use `SDL_FUZZ_KNOWN=1` to switch off the known-finding
skips.

### Known findings

When a target hits a recorded finding, its trigger set is skipped from then on, so the target can
keep exploring. That set is written as code in the target. It is exact wherever possible, for
example F-005's set is the Lean theorem `out_of_range_iff`. Where it is wider than the real
trigger set, the target's comment says so. Nothing is silenced by site or by sanitizer
category, with one exception: F-017's UBSan `pointer-overflow` in `readRlePixels`
(`ubsan.supp`), whose trigger depends on where the buffer was allocated.

`regressions/<target>/F-NNN_*` holds one input per finding. `regress.sh` checks two things for
each. By default the input passes, which shows the skip covers it. With `SDL_FUZZ_KNOWN=1` it
fails, which shows the finding is still there. When a finding is fixed, its regression goes
STALE, and FINDINGS.md should be updated.

### Results before the fixes (2026-11-05, SDL `cb6224d2e` sources)

There were a 60-second smoke run and five 300-second runs per target, on an Apple M-series Mac
under macOS 27. A run stops at its first unskipped report, so for targets that kept finding
things, the input counts are per run, not totals.

| Target | Inputs executed | Findings | Committed corpus |
|---|---|---|---|
| `fuzz_utf8` | ~14.1M (all runs clean) | none new: every result matched RFC 3629 outside the Lean-proved F-005/F-007/F-008 sets | 398 files, 36 KB |
| `fuzz_iconv` | ~13.5M | F-011 (first run) | 595 files, 26 KB |
| `fuzz_rect` | 5.0M clean in run 5 | F-012, F-014, F-015 (three forms) | 156 files, 8 KB |
| `fuzz_gamepad` | up to 127k per run | F-009, F-013, F-004 via `SDL_strcasecmp`, F-006 again; still stops at F-009 variants, see below | 446 files, 34 KB |
| `fuzz_bmp` | 74k and 17k clean in runs 4–5 | F-017, F-018, O-1 | 165 files, 45 KB |
| `fuzz_wav` | 1.34M clean in run 5 | F-010 (two forms), F-016 | 260 files, 216 KB |

The corpora are minimized merges (`-merge=1`) of everything the runs found.

`fuzz_gamepad` never ran clean before the fixes. Its skip for F-009 kept missing variants,
because the string SDL parses goes through several rewrites: trimming, the `crc:` cut, and
`CreateMappingString` cutting at a second `platform:`. Mirroring all of them exactly was not worth
it for a bug about to be fixed. The F-009 fix makes the skip unnecessary. See the post-fix
results below.

### Results after the fixes (2026-11-05, this branch)

One 300-second run per target with `SDL_FUZZ_KNOWN=1`, so no known-finding skip and no UBSan
suppression is active: the fixed code runs with nothing hidden. Same machine as above.

| Target | Inputs executed | Result |
|---|---|---|
| `fuzz_utf8` | 2.20M | clean |
| `fuzz_iconv` | 2.72M | clean |
| `fuzz_rect` | 3.66M | clean |
| `fuzz_gamepad` | 360k, then **F-022** (new: `axes[-1]`). After the F-022 fix, a second run: 527k clean | F-022, fixed |
| `fuzz_bmp` | 13.7k, then a 10 s timeout on an 822-megapixel header (O-1). A second run: 34k clean | O-1 only |
| `fuzz_wav` | 1.11M | clean |

`mise run fuzz:regress`: all 21 regression inputs, F-022's included, pass with no skips.
