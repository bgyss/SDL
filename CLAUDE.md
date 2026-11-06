# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is (read first)

This is `bgyss/SDL`, an independent fork of SDL3. It is a test bed for agent-driven
engineering: formal verification (Lean 4, TLA+), fuzzing, bug fixing, and later optimization
work, done mostly by LLM agents. It has no expectation of staying in sync with upstream or of
sending anything back.

- **Changes to `src/` are welcome.** Fix bugs, harden code, and optimize. A fix for a finding in
  `verification/FINDINGS.md` cites the finding ID, adds a test (`test/testautomation_*.c`, or a
  fuzz regression input), and updates the finding's status. Where a Lean or TLA+ model covers
  the code, update the model so it describes the code as it now is (`verification/PLAN.md`,
  "Fork policy").
- **Keep SDL building and its tests passing** (`mise run test`). Public API and ABI changes are
  allowed, but call them out in the commit message and run `python3 src/dynapi/gendynapi.py`.
- **Nothing goes upstream.** Upstream SDL's `AGENTS.md` says generative AI must not be used to
  contribute to SDL, and that AI-generated code or text must not appear in its bug reports or
  pull requests. So never open upstream issues or PRs, and never frame changes as upstream
  submissions. If a human maintainer of this fork wants to report something upstream, they
  reproduce it and write it up themselves. `verification/HUMAN_REPRO.md` is the starting
  point for that.
- Code stays under SDL's zlib license (`LICENSE.txt`).

## Build

CMake is the primary build system. The Xcode, VisualC, VisualC-GDK, Android.mk, and
android-project files are maintained in parallel, so a new source file must also be added there
(`build-scripts/add-source-to-projects.pl` helps).

```sh
cmake -S . -B build -DSDL_TESTS=ON -DSDL_EXAMPLES=ON   # SDL_TESTS defaults ON when SDL is the top-level project
cmake --build build -j
```

Useful options: `-DSDL_SHARED=` / `-DSDL_STATIC=`, `-DSDL_WERROR=ON`, `-DSDL_FRAMEWORK=ON` (Apple),
and `-DSDL_<SUBSYSTEM>=OFF` / `-DSDL_<BACKEND>=OFF` to disable individual subsystems or backends.
Platform build notes are in `docs/README-<platform>.md` and `docs/INTRO-*.md`.

## Tests

The tests are standalone programs in `test/`, registered with `add_sdl_test_executable()` in
`test/CMakeLists.txt`. Only programs marked `NONINTERACTIVE` become CTest tests (named after the
target). Most of the others are interactive demos you run manually.

```sh
ctest --test-dir build -j4 --output-on-failure         # all non-interactive tests
ctest --test-dir build -R testautomation -V            # one CTest test
```

`testautomation` is the main unit-test suite. Suites live in `test/testautomation_*.c` and are
registered in `test/testautomation_suites.h`. The harness (`src/test/SDL_test_harness.c`) can run
a single suite or a single test case:

```sh
cd build/test && ./testautomation --filter video        # one suite (case-insensitive name)
./testautomation --filter video_getWindowFlags          # one test case (also force-runs disabled tests)
./testautomation --seed <seed> --filter <name>          # reproduce a failure printed by the harness
```

CTest runs with `--trackmem` and fails a test that leaks allocations ("Total: N Kb in M allocations").

## Formatting and checks

- `.clang-format` defines the style. `build-scripts/clang-format-src.sh` formats the sources.
- `build-scripts/check_stdlib_usage.py` (run in CI) flags direct C stdlib calls inside `src/`. SDL
  code must use the `SDL_` equivalents (`SDL_malloc`, `SDL_memcpy`, `SDL_strlcpy`, `SDL_snprintf`, ...).
- `build-scripts/check_android_jni.py` checks Java/C JNI signature consistency for Android.

## Architecture

**Public API vs. internals.** Public headers are in `include/SDL3/`. Their doc comments are the
source for the wiki (`build-scripts/wikiheaders.pl`), so they follow a strict Doxygen-like format
that includes `\since` tags. Every file in `src/` includes `src/SDL_internal.h` first. That header
pulls in the per-platform build configuration (`include/build_config/SDL_build_config*.h`, or the
CMake-generated one) and the dynapi overrides.

**Dynamic API (`src/dynapi/`).** Every public function is called through a jump table. That lets a
newer SDL3 be swapped in at runtime, even into statically linked apps, via the `SDL3_DYNAMIC_API`
environment variable. **When you add or change a public function, run
`python3 src/dynapi/gendynapi.py`.** It regenerates `SDL_dynapi_procs.h`, `SDL_dynapi_overrides.h`,
`SDL_dynapi.sym`, and `SDL_dynapi.exports`. New entries are appended, never reordered (ABI). See
`docs/README-dynapi.md`.

**Subsystems with pluggable backends.** Each major subsystem in `src/<subsystem>/` has a generic
front end plus platform backends in subdirectories. The front end chooses a backend from a
static bootstrap/driver table, ordered by priority and selectable via hints:

- Video: `src/video/SDL_video.c` `bootstrap[]` → `src/video/<platform>/` (cocoa, windows, wayland, x11, kmsdrm, ...). Backends fill in an `SDL_VideoDevice` vtable (`SDL_sysvideo.h`).
- Audio: `src/audio/SDL_audio.c` `bootstrap[]` (`SDL_sysaudio.h`)
- Camera: `src/camera/SDL_camera.c` `bootstrap[]`
- Render (2D): `src/render/SDL_render.c` `render_drivers[]` (`SDL_sysrender.h`), with backends for D3D, Metal, OpenGL/GLES, Vulkan, the SDL_GPU API, and a software renderer
- GPU: `src/gpu/SDL_gpu.c` `backends[]` (Vulkan, Metal, D3D12)
- Joystick: `src/joystick/SDL_joystick.c` `SDL_joystick_drivers[]`. HIDAPI drivers for specific controllers are in `src/joystick/hidapi/`. Gamepad mappings are in `SDL_gamepad_db.h`.

The usual pattern for new platform behavior is a new `#ifdef SDL_<SUBSYS>_DRIVER_<NAME>` backend
plus a matching entry in the bootstrap table and in the build-config headers and CMake. Avoid
`#ifdef`s in the front-end code.

**Other key pieces:**
- `src/core/<platform>/`: platform glue shared across subsystems, such as Android JNI (`SDL_android.c`, which pairs with `android-project/app/src/main/java/org/libsdl/app/*.java`), Windows, and Linux D-Bus/udev.
- `src/events/`: the central event queue that every backend posts into.
- `src/stdlib/`: SDL's own libc replacements, so SDL can build without a C runtime.
- `src/SDL_hints.c` and `src/SDL_properties.c`: the hint system and property bags. Many APIs take an `SDL_PropertiesID` for extensible options instead of adding new parameters.
- `src/main/`: `SDL_main` and the main-callbacks (`SDL_AppInit`/`SDL_AppIterate`/...) entry-point machinery.
- `src/test/`: the `SDL3_test` helper library (test harness, common CLI parsing, memory tracking) used by `test/`.
- `examples/`: small example programs, published at examples.libsdl.org.
