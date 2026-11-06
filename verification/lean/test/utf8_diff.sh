#!/usr/bin/env bash
# Differential test: the Lean model `cStep` against the real SDL_StepUTF8.
# Needs an SDL build (mise run build). Run from verification/lean inside the dev shell:
#   test/utf8_diff.sh [path/to/sdl/build]
set -euo pipefail
build=${1:-../../build}
[ -e "$build/libSDL3.dylib" ] || [ -e "$build/libSDL3.so" ] || { echo "No SDL build in $build (run: mise run build)" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cc -O1 -I ../../include test/utf8_diff.c -L "$build" -lSDL3 -Wl,-rpath,"$(cd "$build" && pwd)" -o "$tmp/utf8_diff"
"$tmp/utf8_diff" > "$tmp/c.txt"
# Build quietly (the toolchain's bundled libgmp/libuv trigger harmless macOS
# deployment-target linker warnings), then run the binary directly.
lake build -q utf8-diff > "$tmp/build.log" 2>&1 || { cat "$tmp/build.log"; exit 1; }
.lake/build/bin/utf8-diff > "$tmp/lean.txt"

cases=$(wc -l < "$tmp/c.txt" | tr -d ' ')
if diff -q "$tmp/c.txt" "$tmp/lean.txt" > /dev/null; then
  echo "utf8 differential: $cases cases, C and Lean model agree"
else
  echo "utf8 differential: C and Lean model DISAGREE (first 20 differences):"
  diff "$tmp/c.txt" "$tmp/lean.txt" | head -20
  exit 1
fi
