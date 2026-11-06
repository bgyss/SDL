#!/usr/bin/env bash
# Differential test: the Lean rect models against the real SDL_HasRectIntersection,
# SDL_GetRectIntersection, SDL_GetRectUnion, SDL_GetRectEnclosingPoints and
# SDL_GetRectAndLineIntersection. Needs an SDL build (mise run build). Run from
# verification/lean inside the dev shell:
#   test/rect_diff.sh [path/to/sdl/build] [cases]
set -euo pipefail
build=${1:-../../build}
cases=${2:-100000}
[ -e "$build/libSDL3.dylib" ] || [ -e "$build/libSDL3.so" ] || { echo "No SDL build in $build (run: mise run build)" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cc -O1 -I ../../include test/rect_diff.c -L "$build" -lSDL3 -Wl,-rpath,"$(cd "$build" && pwd)" -o "$tmp/rect_diff"
"$tmp/rect_diff" "$cases" > "$tmp/c.txt"
lake build -q rect-diff > "$tmp/build.log" 2>&1 || { cat "$tmp/build.log"; exit 1; }
.lake/build/bin/rect-diff < "$tmp/c.txt" > "$tmp/lean.txt"

lines=$(wc -l < "$tmp/c.txt" | tr -d ' ')
if diff -q "$tmp/c.txt" "$tmp/lean.txt" > /dev/null; then
  echo "rect differential: $lines lines ($cases cases x 3 functions groups), C and Lean model agree"
else
  echo "rect differential: C and Lean model DISAGREE (first 20 differences, < C, > Lean):"
  diff "$tmp/c.txt" "$tmp/lean.txt" | head -20
  exit 1
fi
