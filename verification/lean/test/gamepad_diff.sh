#!/usr/bin/env bash
# Differential test: the Lean gamepad mapping model against the bindings SDL parses
# (SDL_GetGamepadBindings) on its own mapping database and generated bodies.
# Needs an SDL build (mise run build). Run from
# verification/lean inside the dev shell:
#   test/gamepad_diff.sh [path/to/sdl/build] [cases]
set -euo pipefail
build=${1:-../../build}
cases=${2:-20000}
[ -e "$build/libSDL3.dylib" ] || [ -e "$build/libSDL3.so" ] || { echo "No SDL build in $build (run: mise run build)" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cc -O1 -I ../../include test/gamepad_diff.c -L "$build" -lSDL3 -Wl,-rpath,"$(cd "$build" && pwd)" -o "$tmp/gamepad_diff"
"$tmp/gamepad_diff" "$cases" > "$tmp/c.txt"
lake build -q gamepad-diff > "$tmp/build.log" 2>&1 || { cat "$tmp/build.log"; exit 1; }
.lake/build/bin/gamepad-diff < "$tmp/c.txt" > "$tmp/lean.txt"

lines=$(wc -l < "$tmp/c.txt" | tr -d ' ')
if diff -q "$tmp/c.txt" "$tmp/lean.txt" > /dev/null; then
  echo "gamepad differential: $lines mappings (SDL database + generated), C and Lean model agree on every binding"
else
  echo "gamepad differential: C and Lean model DISAGREE (first 20 differences, < C, > Lean):"
  diff "$tmp/c.txt" "$tmp/lean.txt" | head -20
  exit 1
fi
