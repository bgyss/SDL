# Reproductions

Every finding in `../FINDINGS.md` has a short standalone program here. Each program is built
twice, once against the pre-fix sources and once against the current tree, and must show the
bug on the first and not on the second. This replaces the earlier plan for a person to
reproduce the leads by hand (`HUMAN_REPRO.md`, removed 2026-11-05). This fork has no manual
reproduction step.

```sh
mise run repro:verify                 # all programs, both trees; writes build-repro/REPORT.md
mise run repro:verify -- f020_audio_lookup_uaf f021_audio_find_by_handle
REPRO_ROUNDS=1000000 mise run repro:verify -- f019_lost_wakeup   # longer stress run
```

## How it works

`run.sh`:

1. Exports the pre-fix tree with `git archive` (`REPRO_BASE`, default `cb6224d2e`, the commit the
   findings were made on; its `src/` equals upstream `87f0e4a25`). The export is never edited.
2. Builds SDL from each tree as a static library, with ASan and UBSan, plus every `f*.c` program
   in this directory (`CMakeLists.txt`). On macOS it uses Apple clang (see `TRUSTED_BASE.md`).
   Every UBSan check aborts, except pointer-overflow: it is reported, and the program goes on so
   that ASan can catch the read that follows.
3. Runs each program on both trees and compares the outcome with its line in `EXPECT`.

An outcome is one of these:

- a sanitizer report, matched by kind and by a function or file in the stack
- `BUG:` with exit status 1, for wrong results that are not memory errors
- `OK:` with exit status 0

## Independence

The programs share nothing with the fuzz targets or `../harness/repro_leads.c`. They include
only `<SDL3/SDL.h>` and the small helpers here (`repro.h`, `gamepad.h`, `wav.h`, `bmp.h`). Each one
builds its input in code. The exception is F-017's file, which is built by a loop because it
needs 70,000 RLE escapes.

All of them use only the public API, except the two audio races. `f020` and `f021` play an
audio backend, since no shipped backend disconnects a device on demand. To do that they call
the backend entry points `SDL_AddAudioDevice` and `SDL_AudioDeviceDisconnected` (and, in
`f021`, the find functions) from `src/audio/SDL_sysaudio.h`. That is why the library is static.
`f021` follows the backend calling convention of each tree. The pre-fix tree has only the
unreferenced find. The fixed tree has `SDL_FindAndRefPhysicalAudioDeviceByHandle`, and
CMake defines `REPRO_HAVE_FIND_AND_REF` when the tree's header declares it.

## Races

`f019`, `f020` and `f021` are stress tests. On the pre-fix tree, `f019` hits the lost wakeup a few
times in 300,000 rounds (6 in the 2026-11-05 run). `f020` and `f021` reach ASan's
use-after-free report well inside their round counts. A clean run on the fixed tree is
evidence, not proof. The TLA+ models in `../tla/` cover every interleaving within their
bounds, and trace validation (`mise run trace`) checks that real runs of the fixed code are
behaviors of those models.

## Adding a finding

Write `fNNN_<what>.c` so that it prints `BUG:`/`OK:` or triggers a sanitizer report. Add its
`EXPECT` line, then run `mise run repro:verify -- fNNN_<what>`. The base expectation must hold
on the pre-fix tree. If the bug is newer than `cb6224d2e`, set `REPRO_BASE` to a commit that
has it, and record that commit in the finding.
