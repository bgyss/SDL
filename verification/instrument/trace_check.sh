#!/usr/bin/env bash
# Trace validation: run a trace program on the instrumented SDL, convert its log, and replay
# every trace against the spec's Trace.tla with TLC.
#
#   verification/instrument/trace_check.sh <spec> [program args...]
#
# <spec> is audio_device (program trace_audio) or events_wait (program trace_events). Builds
# with build.sh first. A trace passes when some behavior of the model replays all of it (TLC
# reports Trace.tla's TraceIncomplete invariant violated, which is the success signal).
set -euo pipefail

spec=$1; shift
root=$(git rev-parse --show-toplevel)
here="$root/verification/instrument"
tla="$root/verification/tla/$spec"
out="$root/build-trace/$spec"
case "$spec" in
  audio_device) prog=trace_audio ;;
  events_wait)  prog=trace_events ;;
  *) echo "unknown spec $spec"; exit 2 ;;
esac

"$here/build.sh"
mkdir -p "$out"
log="$out/trace.ndjson"
VERIF_TRACE_OUT="$log" "$root/build-trace/build/$prog" "$@"
traces="$out/traces.$$"
count=$(python3 "$here/trace2tla.py" "$spec" "$log" "$traces")
echo "$(wc -l < "$log" | tr -d ' ') log lines, $count traces"

# Deadlock checking is off: where the log underdetermines a step (why a backend wait
# returned), some of TLC's branches dead-end, and that is not a failure. The trace passes if
# any branch replays all of it, which TLC reports as TraceIncomplete violated. If TLC
# finishes without that, no behavior of the model produces the log.
replay() { # <dir> <cfg name> <out>
  (cd "$1" && tlc -deadlock -config "$2.cfg" -workers 1 -metadir "meta-$2" Trace.tla) > "$3" 2>&1
}

pass=0; fail=0
for d in "$traces"/*/; do
  cp "$tla"/*.tla "$tla/trace/Trace.cfg" "$d"
  steps=$(grep -c '\[t |->' "$d/TraceData.tla" || true)
  replay "$d" Trace "$d/tlc.out" || true
  if grep -q "Invariant TraceIncomplete is violated" "$d/tlc.out"; then
    pass=$((pass + 1))
  elif grep -q "is violated" "$d/tlc.out"; then
    echo "  FAIL  $(basename "$d") ($steps steps): a safety invariant breaks on the trace:"
    grep -E "is violated" "$d/tlc.out" | head -2; fail=$((fail + 1))
  else
    echo "  FAIL  $(basename "$d") ($steps steps): no behavior of the model replays the whole log"
    grep -E "^Error" "$d/tlc.out" | head -2; fail=$((fail + 1))
  fi
done
echo "$spec: $pass of $count traces replay in the model, $fail fail (traces kept in $traces)"

# Each trace/mutants/*.cfg is a wrong model that must not be able to replay the first trace,
# showing the replay can fail.
first=$(ls -d "$traces"/*/ | head -1)
for m in "$tla"/trace/mutants/*.cfg; do
  [ -e "$m" ] || continue
  name=$(basename "$m" .cfg)
  cp "$m" "$first/$name.cfg"
  replay "$first" "$name" "$first/$name.out" || true
  if grep -q "Invariant TraceIncomplete is violated" "$first/$name.out"; then
    echo "  MISSED mutant $name replays the trace"; fail=$((fail + 1))
  elif grep -q "No error has been found" "$first/$name.out"; then
    echo "  ok    mutant $name cannot replay the trace"
  else
    echo "  WRONG mutant $name:"; grep -E "^Error" "$first/$name.out" | head -2; fail=$((fail + 1))
  fi
done
[ "$fail" = 0 ]
