#!/usr/bin/env bash
# Corpus differential test: the string-level Lean models (StepBack, utf8strlcpy, forward decode)
# against the real SDL functions, on every input in the fuzz_utf8 corpora (the committed seeds
# plus build-fuzz/fuzz/work/fuzz_utf8 if a fuzz run produced one). Each input is cut the way
# fuzz_utf8.c cuts it: skip the 5 parameter bytes, stop at the first NUL.
# Run from verification/lean inside the dev shell: test/utf8_corpus.sh [path/to/sdl/build]
set -euo pipefail
build=${1:-../../build}
[ -e "$build/libSDL3.dylib" ] || [ -e "$build/libSDL3.so" ] || { echo "No SDL build in $build (run: mise run build)" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

for dir in ../harness/corpus/fuzz_utf8 ../../build-fuzz/fuzz/work/fuzz_utf8; do
  [ -d "$dir" ] || continue
  find "$dir" -type f -exec sh -c 'tail -c +6 "$1" | tr "\000" "\n" | head -n 1 | head -c 4096 | xxd -p | tr -d "\n"; echo' _ {} \;
done | sort -u > "$tmp/inputs.hex"

cc -O1 -I ../../include test/utf8_corpus.c -L "$build" -lSDL3 -Wl,-rpath,"$(cd "$build" && pwd)" -o "$tmp/utf8_corpus"
"$tmp/utf8_corpus" < "$tmp/inputs.hex" > "$tmp/c.txt"
lake build -q utf8-corpus > "$tmp/build.log" 2>&1 || { cat "$tmp/build.log"; exit 1; }
.lake/build/bin/utf8-corpus < "$tmp/inputs.hex" > "$tmp/lean.txt"

cases=$(wc -l < "$tmp/inputs.hex" | tr -d ' ')
bytes=$(($(tr -d '\n' < "$tmp/inputs.hex" | wc -c) / 2))
if diff -q "$tmp/c.txt" "$tmp/lean.txt" > /dev/null; then
  echo "utf8 corpus differential: $cases strings ($bytes bytes), C and Lean models agree on Step, StepBack and utf8strlcpy"
else
  echo "utf8 corpus differential: C and Lean models DISAGREE (first 20 differences):"
  diff "$tmp/c.txt" "$tmp/lean.txt" | head -20
  exit 1
fi
