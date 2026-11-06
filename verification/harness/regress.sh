#!/usr/bin/env bash
# Regression check for the fuzz targets. Every input in regressions/<target>/F-NNN_* triggered
# finding F-NNN (FINDINGS.md) on the SDL sources it was found on.
#
# - A finding listed in regressions/OPEN is not fixed yet. Its inputs must pass by default (the
#   harness skips exactly that finding's trigger set) and fail with SDL_FUZZ_KNOWN=1 (it still
#   reproduces). An open finding that stops failing is reported STALE: fixed, or the harness
#   lost the check.
# - Every other finding is fixed in this fork. Its inputs must pass even with SDL_FUZZ_KNOWN=1
#   (no skips, no UBSan suppressions). A failure there is a REGRESSION.
#
# Then every committed corpus input must pass with SDL_FUZZ_KNOWN=1 as well.
# Run from the repo root inside the dev shell, after `fuzz.sh build`.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
here="$root/verification/harness"
bin="$root/build-fuzz/fuzz"
export ASAN_OPTIONS="${ASAN_OPTIONS:-abort_on_error=1:detect_leaks=0:allocator_may_return_null=1:max_allocation_size_mb=1024}"
ubsan="${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=1}"
open_ids=$(grep -oE '^F-[0-9]+' "$here/regressions/OPEN" 2>/dev/null || true)
status=0
for dir in "$here"/regressions/*/; do
  t=$(basename "$dir")
  for f in "$dir"F-*; do
    [ -f "$f" ] || continue
    name="$t/$(basename "$f")"
    id=$(basename "$f" | grep -oE '^F-[0-9]+')
    if echo "$open_ids" | grep -qx "$id"; then
      if ! UBSAN_OPTIONS="$ubsan:suppressions=$here/ubsan.supp" "$bin/$t" "$f" > /dev/null 2>&1; then
        echo "  FAIL     $name (open) fails even with its finding skipped"; status=1
      elif SDL_FUZZ_KNOWN=1 UBSAN_OPTIONS="$ubsan" "$bin/$t" "$f" > /dev/null 2>&1; then
        echo "  STALE    $name (open) no longer reproduces with SDL_FUZZ_KNOWN=1"; status=1
      else
        echo "  ok       $name (open: skipped by default, reproduces with SDL_FUZZ_KNOWN=1)"
      fi
    elif SDL_FUZZ_KNOWN=1 UBSAN_OPTIONS="$ubsan" "$bin/$t" "$f" > /dev/null 2>&1; then
      echo "  ok       $name (fixed: passes with no skips)"
    else
      echo "  REGRESSION $name: $id is marked fixed but this input fails with SDL_FUZZ_KNOWN=1"; status=1
    fi
  done
done
for dir in "$here"/corpus/*/; do
  t=$(basename "$dir")
  n=$(find "$dir" -type f | wc -l | tr -d ' ')
  if SDL_FUZZ_KNOWN=1 UBSAN_OPTIONS="$ubsan" "$bin/$t" -runs=0 "$dir" > "$root/build-fuzz/fuzz/$t.corpus.log" 2>&1; then
    echo "  ok       corpus/$t ($n inputs, no skips)"
  else
    echo "  FAIL     corpus/$t (see build-fuzz/fuzz/$t.corpus.log)"; status=1
  fi
done
exit $status
