#!/usr/bin/env bash
# Builds the trace-instrumented SDL and the trace programs into build-trace/.
#
# The instrumentation never touches src/: this exports a snapshot of the working tree
# (committed and uncommitted changes) to build-trace/src, applies every
# verification/instrument/*.patch to that copy, and builds it. If a patch no longer applies,
# the code it instruments has changed: update the patch, and check that the TLA+ model still
# describes the code.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
here="$root/verification/instrument"
out="$root/build-trace"
mkdir -p "$out"

snap=$(git -C "$root" stash create)   # a commit of the working tree; touches no stash list
snap=${snap:-$(git -C "$root" rev-parse HEAD)}
marker="$snap $(cat "$here"/*.patch | git hash-object --stdin)"
if [ "$(cat "$out/src/.snapshot" 2>/dev/null || true)" != "$marker" ]; then
  if [ -d "$out/src" ]; then mv "$out/src" "$out/src.old.$$"; fi
  mkdir -p "$out/src"
  git -C "$root" archive "$snap" | tar -x -C "$out/src"
  for p in "$here"/*.patch; do
    patch -s -p1 -d "$out/src" < "$p" || { echo "$(basename "$p") does not apply to the current tree"; exit 1; }
  done
  echo "$marker" > "$out/src/.snapshot"
fi

if [ "$(uname -s)" = Darwin ]; then
  dev=$(env -u DEVELOPER_DIR xcode-select -p)
  tool() { env -u SDKROOT DEVELOPER_DIR="$dev" "$@"; }
  cc=(-DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_OBJC_COMPILER=/usr/bin/clang)
else
  tool() { "$@"; }
  cc=()
fi
tool cmake -S "$here" -B "$out/build" -G Ninja "${cc[@]}" -DCMAKE_BUILD_TYPE=Debug \
  -DSDL_SOURCE="$out/src" > "$out/configure.log" 2>&1 || { tail -30 "$out/configure.log"; exit 1; }
tool cmake --build "$out/build" -j 8 > "$out/build.log" 2>&1 || { grep -E "error" "$out/build.log" | head -30; exit 1; }
echo "built $out/build/trace_* (snapshot ${snap:0:9})"
