#!/usr/bin/env bash
# Regression check for the fuzz targets: every input in regressions/<target>/ reproduces a
# finding recorded in FINDINGS.md. Each must
#   - pass by default (the harness skips exactly the finding's trigger set), and
#   - fail with SDL_FUZZ_KNOWN=1 (the finding is still there; when one stops failing, the bug
#     was fixed or the harness lost the check, and FINDINGS.md needs updating).
# Then every committed corpus input must pass by default.
# Run from the repo root inside the dev shell, after `fuzz.sh build`.
set -uo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
here="$root/verification/harness"
bin="$root/build-fuzz/fuzz"
export ASAN_OPTIONS="${ASAN_OPTIONS:-abort_on_error=1:detect_leaks=0:allocator_may_return_null=1:max_allocation_size_mb=1024}"
ubsan="${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=1}"
# Default runs suppress the one site-level known finding (ubsan.supp); SDL_FUZZ_KNOWN=1 runs do not.
export UBSAN_OPTIONS="$ubsan:suppressions=$here/ubsan.supp"
status=0
for dir in "$here"/regressions/*/; do
  t=$(basename "$dir")
  for f in "$dir"*; do
    [ -f "$f" ] || continue
    name="$t/$(basename "$f")"
    if ! "$bin/$t" "$f" > /dev/null 2>&1; then
      echo "  FAIL     $name fails even with its finding skipped"; status=1
    elif SDL_FUZZ_KNOWN=1 UBSAN_OPTIONS="$ubsan" "$bin/$t" "$f" > /dev/null 2>&1; then
      echo "  STALE    $name no longer reproduces its finding with SDL_FUZZ_KNOWN=1"; status=1
    else
      echo "  ok       $name (skipped by default, reproduces with SDL_FUZZ_KNOWN=1)"
    fi
  done
done
for dir in "$here"/corpus/*/; do
  t=$(basename "$dir")
  n=$(find "$dir" -type f | wc -l | tr -d ' ')
  if "$bin/$t" -runs=0 "$dir" > "$root/build-fuzz/fuzz/$t.corpus.log" 2>&1; then
    echo "  ok       corpus/$t ($n inputs)"
  else
    echo "  FAIL     corpus/$t (see build-fuzz/fuzz/$t.corpus.log)"; status=1
  fi
done
exit $status
